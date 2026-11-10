#!/usr/bin/env python3
"""Grants: named access profiles for a delegate task (docs/grants.md).

  grants.py resolve --dir D [--grant N]... [--allow G]... [--orb-file F] [--egress E] [--runner R]
                                   -> resolved JSON on stdout (the task keeps it as grants.json)
  grants.py docker-args FILE       -> docker run arguments, one per line
  grants.py env FILE               -> KEY=VALUE lines for the worker's environment
  grants.py ro FILE | rw FILE      -> extra read-only / read-write paths, one per line
  grants.py guards FILE            -> active guards as JSON lines {name, commands, args, note}
  grants.py locks FILE             -> exclusive lock keys, one per line
  grants.py net FILE               -> "<mode>\\t<allow entries, space-separated>\\t<reason>"
  grants.py prompt FILE            -> the round prompt's "Access this task has" lines (probes run now)
  grants.py summary FILE           -> one line for the report and the dashboard
  grants.py list --dir D           -> each grant in the folder and whether it is valid
  grants.py show --dir D NAME [--allow G]... [--runner R]   -> what a grant would do (runs nothing)

The trust rule: a grant is read ONLY from the grants folder, which the user owns and nobody
else can write. Never from a repo, a worktree, a spec or a chain plan's folder, because a
worker can write those, and a worker must never be able to grant itself access.
Grant files are parsed with tomllib, never executed; unknown keys are an error.
"""
import argparse
import grp
import ipaddress
import json
import os
import re
import shlex
import stat
import subprocess
import sys

NAME_RE = re.compile(r"[a-z0-9][a-z0-9._-]{0,47}")
ENV_KEY_RE = re.compile(r"[A-Z_][A-Z0-9_]*")
CMD_RE = re.compile(r"[A-Za-z0-9._+-]{1,64}")
# guard argument patterns end up in a generated shell `case`: shell-safe glob characters only
ARG_RE = re.compile(r"[A-Za-z0-9._+*?-]{1,64}")
LOCK_RE = re.compile(r"[A-Za-z0-9._:-]{1,96}")
HOST_RE = re.compile(r"[A-Za-z0-9]([A-Za-z0-9-]{0,62})(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}))*")
# environment names a grant may never set: the harness's own, and what would change how
# the worker's tools resolve or authenticate
ENV_RESERVED = re.compile(r"(DELEGATE_.*|PATH|HOME|USER|SHELL|LD_.*|PYTHON.*|NODE_OPTIONS|"
                          r"HTTPS?_PROXY|https?_proxy|NO_PROXY|no_proxy|XDG_.*|DATABASE_URL|"
                          r"GIT_.*|SSH_.*|OPENCODE_.*)")
MODES = ("filtered", "allow", "open", "host")          # narrowest first: the widest asked for wins
TOP_KEYS = {"brief", "lock", "kind", "target", "network", "devices", "mounts", "env", "guards", "probe"}
SECTION_KEYS = {
    "network": {"mode", "allow"},
    "devices": {"paths", "reenumerate"},
    "mounts": {"ro", "rw"},
    "probe": {"serial", "http"},
}
GUARD_KEYS = {"commands", "args", "note"}
# serial character-device majors a `reenumerate` device may widen to (ttyACM, ttyUSB)
SERIAL_MAJOR_BY_NAME = (("ttyACM", 166), ("ttyUSB", 188))

# the built-in orb grant's flash guard: today's shim, word for word (bin/delegate before grants)
ORB_FLASH_ARGS = ["write_flash", "write-flash", "erase_flash", "erase-flash", "erase_region",
                  "erase-region", "flash", "app-flash", "bootloader-flash", "partition-table-flash",
                  "erase-otadata", "erase_otadata", "burn*", "dfu-flash"]
ORB_FLASH_NOTE = ("Flashing is BLOCKED for this task by the harness: esptool, esptool.py and idf.py "
                  "refuse any write, erase or flash (the attempt is logged). Talk to the device over "
                  "its HTTP API. If the board is blank, will not boot, or only a flash would fix it, "
                  "do not look for another way: finish with STATUS: blocked and say what you found.")


class GrantError(Exception):
    pass


def fail(msg):
    raise GrantError(msg)


# ---------------------------------------------------------------- trust ------------
def check_owned(path, what):
    """Owned by us, not a symlink, and writable by nobody else."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        fail(f"{what} {path} does not exist")
    if stat.S_ISLNK(st.st_mode):
        fail(f"{what} {path} is a symlink; grants must be plain files in the grants folder")
    if st.st_uid != os.getuid():
        fail(f"{what} {path} is not owned by you (uid {st.st_uid})")
    if st.st_mode & 0o022:
        fail(f"{what} {path} is writable by group or others (mode {stat.S_IMODE(st.st_mode):o}); chmod go-w it")
    return st


def grant_path(gdir, name):
    if not NAME_RE.fullmatch(name or ""):
        fail(f"grant name {name!r}: use 1-48 chars of a-z 0-9 . _ - starting with a letter or digit")
    gdir = os.path.abspath(os.path.expanduser(gdir))
    st = check_owned(gdir, "grants folder")
    if not stat.S_ISDIR(st.st_mode):
        fail(f"grants folder {gdir} is not a folder")
    p = os.path.join(gdir, name + ".toml")
    if not os.path.lexists(p):
        fail(f"no grant {name!r}: expected {p}")
    check_owned(p, "grant file")
    return p


# ---------------------------------------------------------------- parsing ----------
def as_list(v, what, item=str):
    if v is None:
        return []
    if isinstance(v, item):
        return [v]
    if isinstance(v, list) and all(isinstance(x, item) for x in v):
        return list(v)
    fail(f"{what}: expected a {item.__name__} or a list of them")


def check_allow_entry(e, where):
    hostpart, port = e, None
    if re.fullmatch(r".+:\d{1,5}", e) and not e.count(":") > 1:
        hostpart, port = e.rsplit(":", 1)
        if not 0 < int(port) < 65536:
            fail(f"{where}: bad port in {e!r}")
    try:
        net = ipaddress.ip_network(hostpart, strict=False)
        if "/" in hostpart and port is not None:
            fail(f"{where}: a CIDR takes no port: {e!r}")
        return {"entry": e, "kind": "net", "value": str(net), "port": port}
    except ValueError:
        pass
    if HOST_RE.fullmatch(hostpart) and len(hostpart) <= 253:
        return {"entry": e, "kind": "host", "value": hostpart.lower(), "port": port}
    fail(f"{where}: {e!r} is not a host, host:port, ip, ip:port or cidr")


def parse_grant(name, doc, where):
    unknown = set(doc) - TOP_KEYS
    if unknown:
        fail(f"{where}: unknown key(s) {', '.join(sorted(unknown))}")
    for sec, keys in SECTION_KEYS.items():
        if sec in doc:
            if not isinstance(doc[sec], dict):
                fail(f"{where}: [{sec}] must be a table")
            bad = set(doc[sec]) - keys
            if bad:
                fail(f"{where}: unknown key(s) in [{sec}]: {', '.join(sorted(bad))}")
    g = {"name": name, "source": where, "builtin": False}
    kind = doc.get("kind", "generic")
    if kind not in ("generic", "orb"):
        fail(f"{where}: kind must be \"generic\" or \"orb\"")
    if kind == "orb":
        if set(doc) - {"kind", "target", "brief", "lock"}:
            fail(f"{where}: a kind = \"orb\" grant takes only target (and optionally brief, lock); "
                 "its access is the built-in orb grant's")
        target = doc.get("target")
        if not isinstance(target, str) or not os.path.isabs(os.path.expanduser(target)):
            fail(f"{where}: kind = \"orb\" needs target = \"<absolute path to an .orb-target>\"")
        target = os.path.expanduser(target)
        check_owned(target, "orb target")
        o = orb_builtin(target, name=name, source=where)
        if isinstance(doc.get("brief"), str):
            o["brief"] = doc["brief"]
        if isinstance(doc.get("lock"), str):
            o["locks"] = [check_lock(doc["lock"], where)]
        return o
    if "target" in doc:
        fail(f"{where}: target belongs to kind = \"orb\" grants only")
    brief = doc.get("brief", "")
    if not isinstance(brief, str):
        fail(f"{where}: brief must be a string")
    g["brief"] = brief.strip()
    g["locks"] = [check_lock(doc["lock"], where)] if "lock" in doc else []
    net = doc.get("network", {})
    mode = net.get("mode", "filtered")
    if mode not in MODES:
        fail(f"{where}: network.mode must be one of {', '.join(MODES)}")
    allow = [check_allow_entry(e, where) for e in as_list(net.get("allow"), f"{where}: network.allow")]
    if allow and mode != "allow":
        fail(f"{where}: network.allow only applies with mode = \"allow\"")
    if mode == "allow" and not allow:
        fail(f"{where}: mode = \"allow\" needs at least one network.allow entry")
    g["network"] = {"mode": mode, "allow": allow}
    dev = doc.get("devices", {})
    re_en = dev.get("reenumerate", False)
    if not isinstance(re_en, bool):
        fail(f"{where}: devices.reenumerate must be true or false")
    paths = as_list(dev.get("paths"), f"{where}: devices.paths")
    for p in paths:
        if not p.startswith("/dev/") or ".." in p.split("/"):
            fail(f"{where}: device path {p!r} must be under /dev/")
    g["devices"] = {"paths": paths, "reenumerate": re_en}
    mnt = doc.get("mounts", {})
    g["mounts"] = {}
    for k in ("ro", "rw"):
        ps = [os.path.expanduser(p) for p in as_list(mnt.get(k), f"{where}: mounts.{k}")]
        for p in ps:
            if not os.path.isabs(p):
                fail(f"{where}: mounts.{k} path {p!r} must be absolute")
            if any(c.isspace() for c in p) or ":" in p:
                fail(f"{where}: mounts.{k} path {p!r}: spaces and ':' are not supported")
        g["mounts"][k] = ps
    env = doc.get("env", {})
    if not isinstance(env, dict):
        fail(f"{where}: [env] must be a table")
    clean = {}
    for k, v in env.items():
        if not ENV_KEY_RE.fullmatch(k):
            fail(f"{where}: env name {k!r} must be UPPER_CASE")
        if ENV_RESERVED.fullmatch(k):
            fail(f"{where}: env {k} is reserved for the harness")
        if not isinstance(v, (str, int, bool)):
            fail(f"{where}: env {k} must be a plain value")
        v = str(v).lower() if isinstance(v, bool) else str(v)
        if "\n" in v or "\0" in v:
            fail(f"{where}: env {k} may not contain a newline")
        clean[k] = v
    g["env"] = clean
    guards = doc.get("guards", {})
    if not isinstance(guards, dict):
        fail(f"{where}: [guards] must hold named tables, e.g. [guards.flash]")
    g["guards"] = {}
    for gname, gd in guards.items():
        if not NAME_RE.fullmatch(gname) or not isinstance(gd, dict):
            fail(f"{where}: guard {gname!r} must be a named table like [guards.flash]")
        bad = set(gd) - GUARD_KEYS
        if bad:
            fail(f"{where}: unknown key(s) in [guards.{gname}]: {', '.join(sorted(bad))}")
        cmds = as_list(gd.get("commands"), f"{where}: guards.{gname}.commands")
        if not cmds or not all(CMD_RE.fullmatch(c) for c in cmds):
            fail(f"{where}: guards.{gname}.commands must be plain command names")
        args = as_list(gd.get("args"), f"{where}: guards.{gname}.args")
        if not all(ARG_RE.fullmatch(x) for x in args):
            fail(f"{where}: guards.{gname}.args are glob patterns of letters, digits and . _ + * ? -")
        note = gd.get("note", "")
        if not isinstance(note, str):
            fail(f"{where}: guards.{gname}.note must be a string")
        g["guards"][gname] = {"commands": cmds, "args": args, "note": note.strip()}
    pr = doc.get("probe", {})
    g["probe"] = {"serial": as_list(pr.get("serial"), f"{where}: probe.serial"),
                  "http": as_list(pr.get("http"), f"{where}: probe.http")}
    for u in g["probe"]["http"]:
        if not re.fullmatch(r"https?://[^\s'\"]+", u):
            fail(f"{where}: probe.http {u!r} must be an http(s) URL")
    return g


def check_lock(v, where):
    if not isinstance(v, str) or not LOCK_RE.fullmatch(v):
        fail(f"{where}: lock must be a short key of letters, digits and . _ : -")
    return v


def load_grant(gdir, name):
    p = grant_path(gdir, name)
    try:
        import tomllib          # Python 3.11+; only needed when a grant file is read
    except ModuleNotFoundError:
        fail(f"reading grant files needs Python 3.11 or newer (tomllib); this is {sys.version.split()[0]}")
    try:
        with open(p, "rb") as f:
            doc = tomllib.load(f)
    except tomllib.TOMLDecodeError as e:
        fail(f"{p}: {e}")
    return parse_grant(name, doc, p)


def read_orb_target(path):
    """The .orb-target's ORB_* values, parsed the way lib/orbtarget.py does (never sourced)."""
    here = os.path.dirname(os.path.abspath(__file__))
    out = subprocess.run([sys.executable, os.path.join(here, "orbtarget.py"), path],
                         capture_output=True, text=True)
    if out.returncode != 0:
        fail(f"orb target {path} has neither ORB_SERIAL nor ORB_IP")
    vals = {}
    for line in out.stdout.splitlines():
        k, _, v = line.partition("=")
        vals[k] = (shlex.split(v) or [""])[0]
    return vals


def orb_builtin(target, name="orb", source=None):
    """--orb FILE as a grant: today's access, except devices narrowed to the orb's own major."""
    v = read_orb_target(target)
    key = re.sub(r"[^A-Za-z0-9]", "", v.get("ORB_BASE_MAC") or v.get("ORB_SERIAL") or "").lower()
    label = v.get("ORB_LABEL") or v.get("ORB_BASE_MAC") or v.get("ORB_SERIAL") or "the orb"
    serial = v.get("ORB_SERIAL", "")
    return {
        "name": name, "source": source or f"--orb {target}", "builtin": True, "kind": "orb",
        "target": target,
        "brief": "",
        "locks": [f"orb-{key}"] if key else [],
        "lock_label": f"orb {label}",
        "network": {"mode": "host", "allow": []},
        "devices": {"paths": [serial] if serial else [], "reenumerate": True},
        "mounts": {"ro": [], "rw": []},
        "env": {k: v.get(k, "") for k in ("ORB_LABEL", "ORB_BASE_MAC", "ORB_SERIAL", "ORB_IP")},
        "guards": {"flash": {"commands": ["esptool", "esptool.py", "idf.py"], "args": ORB_FLASH_ARGS,
                             "note": ORB_FLASH_NOTE}},
        "probe": {"serial": [serial] if serial else [], "http": []},
    }


# ---------------------------------------------------------------- resolve ----------
def serial_major(path):
    base = os.path.basename(os.path.realpath(path))
    for prefix, major in SERIAL_MAJOR_BY_NAME:
        if base.startswith(prefix):
            return major
    return None


def resolve_device(p):
    real = os.path.realpath(p)
    d = {"path": p, "real": real, "present": False, "major": None, "minor": None, "gid": None}
    try:
        st = os.stat(real)
    except OSError:
        d["major"] = serial_major(p)
        return d
    if not stat.S_ISCHR(st.st_mode):
        fail(f"device {p} ({real}) is not a character device")
    d.update(present=True, major=os.major(st.st_rdev), minor=os.minor(st.st_rdev), gid=st.st_gid)
    return d


def resolve(gdir, names, allows, orb_file=None, egress="filtered", runner="docker"):
    grants = []
    if orb_file:
        grants.append(orb_builtin(orb_file))
    seen = set()
    for n in names:
        if n in seen:
            continue
        seen.add(n)
        grants.append(load_grant(gdir, n))
    # network: the widest asked for wins, and the report says who asked
    mode, reason = (egress if egress in MODES else "filtered"), (f"--egress {egress}" if egress != "filtered" else "default")
    allow = []
    for g in grants:
        m = g["network"]["mode"]
        if MODES.index(m) > MODES.index(mode):
            mode, reason = m, f"grant {g['name']}"
        for e in g["network"]["allow"]:
            if e["entry"] not in [a["entry"] for a in allow]:
                allow.append(e)
    if mode != "allow":
        allow = [] if mode in ("open", "host") else allow
    devices, env, ro, rw, locks, guards, probes = [], {}, [], [], [], {}, {"serial": [], "http": []}
    for g in grants:
        for p in g["devices"]["paths"]:
            d = resolve_device(p)
            d["reenumerate"] = g["devices"]["reenumerate"]
            d["grant"] = g["name"]
            devices.append(d)
        for k, v in g["env"].items():
            if k in env and env[k] != v:
                fail(f"env {k}: grants disagree ({env[k]!r} vs {v!r} from {g['name']})")
            env[k] = v
        for p in g["mounts"]["ro"]:
            if not os.path.exists(p):
                fail(f"grant {g['name']}: mounts.ro {p} does not exist")
            ro.append(os.path.realpath(p))
        for p in g["mounts"]["rw"]:
            if not os.path.exists(p):
                fail(f"grant {g['name']}: mounts.rw {p} does not exist")
            rw.append(os.path.realpath(p))
        for k in g["locks"]:
            if k not in [x["key"] for x in locks]:
                locks.append({"key": k, "label": g.get("lock_label") or g["name"]})
        for gname, gd in g["guards"].items():
            cur = guards.setdefault(gname, {"name": gname, "commands": [], "args": [], "note": "", "from": []})
            cur["commands"] += [c for c in gd["commands"] if c not in cur["commands"]]
            cur["args"] += [a for a in gd["args"] if a not in cur["args"]]
            cur["note"] = cur["note"] or gd["note"]
            cur["from"].append(g["name"])
        probes["serial"] += [p for p in g["probe"]["serial"] if p not in probes["serial"]]
        probes["http"] += [u for u in g["probe"]["http"] if u not in probes["http"]]
    for a in allows:
        if a not in guards:
            fail(f"--allow {a}: no granted guard is named {a!r}" +
                 (f" (granted guards: {', '.join(sorted(guards))})" if guards else ""))
    lifted = [g for g in guards if g in allows]
    active = [guards[g] for g in guards if g not in allows]
    return {
        "format": 1, "runner": runner,
        "grants": [{"name": g["name"], "source": g["source"], "builtin": g["builtin"],
                    "brief": g["brief"], "env": g["env"]} for g in grants],
        "network": {"mode": mode, "reason": reason, "allow": allow},
        "devices": devices, "env": env, "ro": ro, "rw": rw, "locks": locks,
        "guards": active, "lifted": lifted, "probe": probes,
        "orb": next((g["env"].get("ORB_LABEL") or "orb" for g in grants if g.get("kind") == "orb"), ""),
    }


# ---------------------------------------------------------------- outputs ----------
def docker_args(r):
    """Arguments for `docker run`. Network args are the bash's (it owns networks and proxies)."""
    out = []
    devs = r["devices"]
    widen = {d["major"] for d in devs if d["reenumerate"] and d["major"] is not None}
    if any(d["reenumerate"] and d["major"] is None for d in devs):
        # not attached at start and not named for its type: both serial majors, as before grants
        widen |= {m for _, m in SERIAL_MAJOR_BY_NAME}
    widen = sorted(widen)
    if widen:
        # a board that re-enumerates on reset: /dev live so its by-id link keeps resolving, and
        # that device type only (never another major)
        out += ["-v", "/dev:/dev"]
        for m in widen:
            out += ["--device-cgroup-rule", f"c {m}:* rmw"]
    for d in devs:
        if d["reenumerate"]:
            continue
        if not d["present"]:
            continue                      # not attached: the probe tells the worker
        out += ["--device", f"{d['real']}:{d['path']}"]
    gids = {d["gid"] for d in devs if d["gid"] is not None}
    if any(not d["present"] for d in devs):
        try:
            gids.add(grp.getgrnam("dialout").gr_gid)   # a serial port plugged in later is usually dialout's
        except KeyError:
            pass
    gids = sorted(gids)
    for g in gids:
        out += ["--group-add", str(g)]
    for p in r["rw"]:
        out += ["-v", f"{p}:{p}"]
    for k, v in r["env"].items():
        out += ["-e", f"{k}={v}"]
    return out


def expand(text, env):
    return re.sub(r"\$\{([A-Z_][A-Z0-9_]*)\}|\$([A-Z_][A-Z0-9_]*)",
                  lambda m: env.get(m.group(1) or m.group(2), m.group(0)), text)


def serial_status(p):
    real = os.path.realpath(p)
    if not os.path.exists(real):
        return (f"- Device status at round start: serial port {p} is NOT attached on this machine right "
                "now. Do not guess another port; if the task needs serial, finish with STATUS: blocked.")
    who = ""
    try:
        out = subprocess.run(["fuser", real], capture_output=True, text=True, timeout=5).stdout
        for pid in out.split():
            pid = pid.strip().rstrip("cefFrm")
            if not pid.isdigit():
                continue
            comm = subprocess.run(["ps", "-o", "comm=", "-p", pid], capture_output=True, text=True).stdout.strip()
            who += f" {pid}({comm})"
    except (OSError, subprocess.SubprocessError):
        pass
    if who:
        return (f"- Device status at round start: the serial port {p} ({real}) is HELD by another process:{who}. "
                "It is in use by someone else: do not kill or signal it. Work on what does not need the port; "
                "if the task needs it, finish with STATUS: blocked and name the process.")
    return f"- Device status at round start: serial port {p} is attached ({real}) and free."


def http_status(u):
    try:
        out = subprocess.run(["curl", "-s", "-o", "/dev/null", "-m", "4", "-w", "%{http_code}", u],
                             capture_output=True, text=True, timeout=8).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        out = ""
    if out and out != "000":
        return f"- Service status at round start: {u} answered HTTP {out}."
    return f"- Service status at round start: {u} did NOT answer. If the task needs it, finish with STATUS: blocked."


def prompt_lines(r):
    lines = []
    names = [g["name"] for g in r["grants"]]
    if not names:
        return lines
    net = r["network"]
    lines.append(f"- Access granted by the harness for this task: {', '.join(names)} "
                 f"(network: {net['mode']}" + (f", reachable on the LAN: {', '.join(a['entry'] for a in net['allow'])}" if net["allow"] else "") + ").")
    for g in r["grants"]:
        if g["brief"]:
            lines.append("- " + expand(g["brief"], r["env"]).replace("\n", " "))
    for gd in r["guards"]:
        note = gd["note"] or f"{', '.join(gd['commands'])} refuse to run for this task (guard {gd['name']})."
        lines.append("- " + note + " (These commands are guarded by the harness; a guard is not a sandbox, "
                     "so do not look for another way around it.)")
    for p in r["probe"]["serial"]:
        lines.append(serial_status(p))
    for u in r["probe"]["http"]:
        lines.append(http_status(u))
    return lines


def summary(r):
    parts = []
    if r["grants"]:
        parts.append("grants " + ", ".join(g["name"] for g in r["grants"]))
    net = r["network"]
    parts.append(f"network {net['mode']} ({net['reason']})" +
                 (f": {' '.join(a['entry'] for a in net['allow'])}" if net["allow"] else ""))
    if r["devices"]:
        ds = []
        for d in r["devices"]:
            scope = (f"major {d['major']} (re-enumerates)" if d["reenumerate"] else
                     (f"{d['major']}:{d['minor']}" if d["present"] else "not attached"))
            ds.append(f"{d['path']} [{scope}]")
        parts.append("devices " + "; ".join(ds))
    if r["rw"]:
        parts.append("rw mounts " + " ".join(r["rw"]))
    if r["lifted"]:
        parts.append("guards lifted " + ", ".join(r["lifted"]))
    if r["guards"]:
        parts.append("guarded " + ", ".join(g["name"] for g in r["guards"]))
    return "; ".join(parts)


def load_resolved(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main(argv):
    ap = argparse.ArgumentParser(prog="grants.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    rs = sub.add_parser("resolve")
    rs.add_argument("--dir", required=True)
    rs.add_argument("--grant", action="append", default=[])
    rs.add_argument("--allow", action="append", default=[])
    rs.add_argument("--orb-file", default="")
    rs.add_argument("--egress", default="filtered")
    rs.add_argument("--runner", default="docker")
    for c in ("docker-args", "env", "ro", "rw", "guards", "locks", "net", "prompt", "summary"):
        sub.add_parser(c).add_argument("file")
    ls = sub.add_parser("list")
    ls.add_argument("--dir", required=True)
    sh = sub.add_parser("show")
    sh.add_argument("--dir", required=True)
    sh.add_argument("name")
    sh.add_argument("--allow", action="append", default=[])
    sh.add_argument("--runner", default="docker")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "resolve":
            json.dump(resolve(a.dir, a.grant, a.allow, a.orb_file or None, a.egress, a.runner), sys.stdout, indent=1)
            print()
        elif a.cmd == "list":
            gdir = os.path.abspath(os.path.expanduser(a.dir))
            if not os.path.isdir(gdir):
                print(f"no grants folder ({gdir})")
                return 0
            names = sorted(f[:-5] for f in os.listdir(gdir) if f.endswith(".toml"))
            if not names:
                print(f"no grants in {gdir}")
            for n in names:
                try:
                    g = load_grant(gdir, n)
                    print(f"{n:24} ok      network {g['network']['mode']}, {len(g['devices']['paths'])} device(s), "
                          f"guards: {', '.join(g['guards']) or 'none'}")
                except GrantError as e:
                    print(f"{n:24} INVALID {e}")
        elif a.cmd == "show":
            r = resolve(a.dir, [a.name], a.allow, None, "filtered", a.runner)
            print("summary:   " + summary(r))
            print("docker:    " + " ".join(shlex.quote(x) for x in docker_args(r)))
            print("read-only: " + (" ".join(r["ro"]) or "none"))
            print("locks:     " + (", ".join(l["key"] for l in r["locks"]) or "none"))
            print("prompt:")
            for line in prompt_lines(r):
                print("  " + line)
        else:
            r = load_resolved(a.file)
            def lines(xs):
                if xs:
                    print("\n".join(xs))
            if a.cmd == "docker-args":
                lines(docker_args(r))
            elif a.cmd == "env":
                for k, v in r["env"].items():
                    print(f"{k}={v}")
            elif a.cmd in ("ro", "rw"):
                lines(r[a.cmd])
            elif a.cmd == "guards":
                for gd in r["guards"]:
                    print(json.dumps(gd))
            elif a.cmd == "locks":
                for l in r["locks"]:
                    print(f"{l['key']}\t{l['label']}")
            elif a.cmd == "net":
                # allow entries as kind|value|port for the proxy (kind: net = ip/cidr, host = a name)
                ent = " ".join(f"{x['kind']}|{x['value']}|{x['port'] or ''}" for x in r["network"]["allow"])
                print(f"{r['network']['mode']}\t{ent}\t{r['network']['reason']}")
            elif a.cmd == "prompt":
                lines(prompt_lines(r))
            elif a.cmd == "summary":
                print(summary(r))
    except GrantError as e:
        print(f"grants: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
