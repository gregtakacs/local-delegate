#!/usr/bin/env python3
"""merge-opencode-permissions.py — the opencode-config merge for a delegate install.

install.sh runs this so a fresh delegate install doesn't cost the orchestrator a permission
prompt for its own skill, loads the delegate rules, and carries the harness permission policy.
It only ever ADDS entries it needs and are still absent; it never rewrites a value you set
(policy `deny` rows excepted: those are refused, not shadowed); and it refuses to touch a config
that is not valid JSON. What is ours is recorded under the top-level `_delegate` key (opencode's
loader ignores unknown keys — verified against 1.18.30; if a later validator ever objects the
marker moves to a sibling delegate-managed.json, design §8.1).

  --config PATH        default: $XDG_CONFIG_HOME|~/.config /opencode/opencode.json
  --skill-dir PATH     the skills dir entry that was linked (for external_directory)
  --real-dir PATH      the same directory after symlinks (rules may see either)
  --instructions PATH  (repeatable) rule files to ensure in `instructions`; ours are recorded,
                       re-runs replace ours and keep yours; the `.clinerules/*.md` route
                       (spike S5) rides along as a machine entry of this helper
  --permission-policy FILE --render
                       render FILE via translate-permissions.py --render opencode and merge the
                       pattern maps; delegate-owned keys are updated in place on re-run
  --check [AREA...]    verify the entries are present; write nothing. Areas: machine, instructions,
                       permissions. Prints `check <area>: <ok|warn|fail> …`; exit 1 on any FAIL,
                       2 when only WARNs (a config merged before this existed is WARN, not FAIL)
  --uninstall          remove every `_delegate`-recorded entry, and the machine entries when they
                       carry exactly our value; everything else is left with a NOTE
"""
import hashlib
import json
import os
import re
import subprocess
import sys
from collections import OrderedDict

POLICY_VERSION = 1
CLINERULES_ENTRY = ".clinerules/*.md"   # spike S5 PASS: the relative glob resolves per project


def config_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~")
    return os.path.join(base, "opencode", "opencode.json")


def glob_re(pattern):
    """opencode's permission wildcard: '*' (and so '**') is any run of characters, '?' one."""
    out = []
    for ch in os.path.expanduser(pattern):
        out.append(".*" if ch == "*" else "." if ch == "?" else re.escape(ch))
    return re.compile("^" + "".join(out) + "$", re.S)


def covered(rules, pattern, val):
    """True when the rule opencode applies to a file under `pattern`'s directory is `val`.

    opencode evaluates a pattern map in order and the LAST matching rule wins (which is why
    configs start with "*" and list the specific rules after it), so the decision for a sample
    path inside the directory is the value of the last key whose wildcard matches it.
    """
    if not pattern.endswith("/**"):
        return False
    sample = pattern[:-3] + "/SKILL.md"
    decision = None
    for key, value in rules.items():
        if isinstance(key, str) and glob_re(key).match(sample):
            decision = value
    return decision == val


def parse(argv):
    args, opts = list(argv), {"instructions": []}
    while args:
        a = args.pop(0)
        if a in ("--config", "--skill-dir", "--real-dir", "--permission-policy"):
            opts[a[2:].replace("-", "_")] = os.path.expanduser(args.pop(0))
        elif a == "--instructions":
            opts["instructions"].append(os.path.expanduser(args.pop(0)))
        elif a == "--render":
            opts["render"] = True
        elif a == "--check":
            opts["check"] = True
            opts["check_areas"] = []
            while args and not args[0].startswith("--"):
                opts["check_areas"].append(args.pop(0))
        elif a == "--uninstall":
            opts["uninstall"] = True
        else:
            sys.exit(f"merge-opencode-permissions: unknown option {a}")
    opts.setdefault("config", config_path())
    return opts


def load(cfg, check=False):
    if os.path.exists(cfg):
        try:
            return json.load(open(cfg), object_pairs_hook=OrderedDict)
        except (json.JSONDecodeError, ValueError) as e:
            print(f"merge-opencode-permissions: {cfg} is not valid JSON ({e}); "
                  "file left untouched", file=sys.stderr)
            raise SystemExit(1)
    if check:
        print(f"merge-opencode-permissions: no opencode config at {cfg}; "
              "fix: re-run install.sh", file=sys.stderr)
        raise SystemExit(1)
    return OrderedDict([("$schema", "https://opencode.ai/config.json")])


def save(cfg, doc):
    tmp = cfg + ".tmp"
    os.makedirs(os.path.dirname(cfg), exist_ok=True)
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    os.replace(tmp, cfg)


def render_opencode(policy_path, home):
    """The policy's opencode rendering, via the translator (subprocess: one honest renderer)."""
    lib = os.path.dirname(os.path.abspath(__file__))
    r = subprocess.run(
        [sys.executable, os.path.join(lib, "translate-permissions.py"),
         "--policy", policy_path, "--render", "opencode", "--home", home],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip() or "renderer exited %d" % r.returncode)
    return json.loads(r.stdout, object_pairs_hook=OrderedDict)


def machine_want(o):
    want = [("skill", "delegate", "allow")]
    for d in (o.get("skill_dir"), o.get("real_dir")):
        if d:
            want.append(("external_directory", os.path.join(d, "**"), "allow"))
    return want


def merge_machine(doc, o, check=False):
    """Today's contract, unchanged: add-if-absent, covered() counts as present, a foreign value
    is kept (never rewritten). Returns (missing, ours, kept) or None for the array-form refusal."""
    perm = doc.setdefault("permission", OrderedDict())
    if not isinstance(perm, dict):  # e.g. the array form; leave it alone
        return None
    missing, ours, kept = [], [], 0
    for section, pattern, val in machine_want(o):
        cur = perm.get(section)
        if cur is None and not check:
            cur = perm[section] = OrderedDict()
        if not isinstance(cur, dict):
            if cur is not None:
                print(f"merge-opencode-permissions: permission.{section} is not a "
                      f"pattern map in {o['config']}; add '{pattern}' by hand", file=sys.stderr)
            missing.append(f"{section}/{pattern}")
            continue
        if pattern in cur:
            if cur[pattern] != val:
                kept += 1
            else:
                ours.append([section, pattern])
            continue
        if section == "external_directory" and covered(cur, pattern, val):
            # A broader rule the user wrote (e.g. "~/Projects/**": "allow") already lets the
            # skill load; adding the literal entry would be clutter, and calling it missing
            # was a false doctor WARN (2026-11-14).
            continue
        missing.append(f"{section}/{pattern}")
        if not check:
            cur[pattern] = val
            ours.append([section, pattern])
    return missing, ours, kept


def _in_arr(arr, e):
    """An entry is present when it matches literally, or resolves to the same file: a release
    install records paths through `current`, and the same file reached through the version dir
    it points at is the same rule."""
    if e in arr:
        return True
    r = os.path.realpath(e)
    return any(os.path.realpath(x) == r for x in arr if isinstance(x, str))


def want_instructions(o, record):
    """The entries we ensure; None when instructions were never part of this install."""
    if not o["instructions"] and "instructions" not in record:
        return None
    want = list(o["instructions"] or record.get("instructions", []))
    if CLINERULES_ENTRY not in want:
        want.append(CLINERULES_ENTRY)
    return want


def merge_instructions(doc, o, record, check=False):
    """`instructions` is an array; ours are recorded so a re-run replaces ours and keeps yours.
    Returns a detail string (None when satisfied)."""
    want = want_instructions(o, record)
    if want is None:
        return None
    arr = doc.get("instructions")
    if arr is None:
        if check:
            return "missing " + ", ".join(want[:3])      # absent key: a gap, judged warn/fail by caller
        arr = doc["instructions"] = []
    if not isinstance(arr, list):
        return ("instructions is not an array in " + o["config"]
                + "; add " + ", ".join(want) + " by hand")
    missing = [e for e in want if not _in_arr(arr, e)]
    stale = [e for e in record.get("instructions", []) if not _in_arr(want, e)]
    if not check:
        for e in stale:
            if e in arr:
                arr.remove(e)
        for e in want:
            if not _in_arr(arr, e):
                arr.append(e)
        record["instructions"] = want
    if missing:
        return "missing " + ", ".join(missing[:3])
    if stale and check:
        return "stale " + ", ".join(stale[:3])
    return None


def merge_policy_permissions(doc, o, record, check=False):
    """The rendered policy maps: ours updated in place on re-run, foreign entries add-if-absent
    with today's never-rewrite care, and a foreign value shadowing a deny row refused — a deny
    that stops denying is a broken install, not drift. Returns a detail string or None."""
    want = o.get("policy_render")
    if want is None:
        return None
    perm = doc.setdefault("permission", OrderedDict())
    if not isinstance(perm, dict):
        return "permission is an array in " + o["config"] + "; merge the policy by hand"
    recorded = {tuple(p) for p in record.get("permissions", [])}
    problems = []
    for section, rules in want.items():
        cur = perm.get(section)
        if cur is None and not check:
            cur = perm[section] = OrderedDict()
        if not isinstance(cur, dict):
            problems.append("%s is not a pattern map in %s" % (section, o["config"]))
            continue
        for pattern, effect in rules.items():
            if pattern in cur:
                if cur[pattern] == effect:
                    continue                     # satisfied: ours or an identical foreign rule
                if (section, pattern) in recorded and not check:
                    cur[pattern] = effect            # ours: update in place
                    continue
                if effect == "deny":
                    problems.append(
                        "%s/%s is a deny row the config sets to %r; a deny answering something "
                        "else is not drift — remove or fix your entry"
                        % (section, pattern, cur[pattern]))
                    continue
            elif check:
                problems.append("missing %s/%s" % (section, pattern))
                continue
            else:
                cur[pattern] = effect
            recorded.add((section, pattern))
    stale = [k for k in sorted(recorded) if k[0] not in want or k[1] not in want[k[0]]]
    if not check:
        for s, p in stale:
            if isinstance(perm.get(s), dict):
                perm[s].pop(p, None)
        record["permissions"] = sorted([list(k) for k in recorded if k not in stale])
    if problems:
        return "; ".join(problems[:3])
    return None


def cmd_uninstall(o):
    cfg = o["config"]
    if not os.path.exists(cfg):
        return 0
    doc = load(cfg)
    record = doc.get("_delegate")
    if isinstance(record, dict):
        perm = doc.get("permission")
        for section, pattern in record.get("permissions", []) + record.get("machine", []):
            if isinstance(perm, dict) and isinstance(perm.get(section), dict):
                perm[section].pop(pattern, None)
        for e in record.get("instructions", []):
            if isinstance(doc.get("instructions"), list) and e in doc["instructions"]:
                doc["instructions"].remove(e)
        doc.pop("_delegate", None)
    else:
        # pre-marker config: machine entries can only be ours if they carry exactly our value
        print("NOTE: no _delegate record; removing machine entries by value only", file=sys.stderr)
        perm = doc.get("permission")
        for section, pattern, val in machine_want(o):
            if isinstance(perm, dict) and isinstance(perm.get(section), dict) \
                    and perm[section].get(pattern) == val:
                perm[section].pop(pattern)
        if isinstance(doc.get("instructions"), list):
            doc["instructions"] = [e for e in doc["instructions"] if e != CLINERULES_ENTRY]
    perm = doc.get("permission")
    if isinstance(perm, dict):
        for s in list(perm):
            if perm[s] == {}:
                del perm[s]
        if not perm:
            doc.pop("permission", None)
    if isinstance(doc.get("instructions"), list) and not doc["instructions"]:
        doc.pop("instructions", None)
    save(cfg, doc)
    print("opencode permissions: removed delegate entries from " + cfg)
    return 0


def cmd_check(o, doc):
    # A bare --check is today's contract: the machine entries only, exit 0/1 as before. The
    # newer areas are judged only when named (doctor names them), so an already-merged config
    # predating instructions still checks clean.
    areas = o.get("check_areas") or ["machine"]
    record = doc.get("_delegate") if isinstance(doc.get("_delegate"), dict) else None
    state = {"rc": 0}

    def emit(area, status, detail=""):
        print(("check %s: %s %s" % (area, status, detail)).rstrip())
        state["rc"] = max(state["rc"], {"ok": 0, "warn": 2, "fail": 1}[status])

    if "machine" in areas:
        r = merge_machine(doc, o, check=True)
        if r is None:
            emit("machine", "fail", "permission is an array; merge by hand")
        else:
            missing, _ours, kept = r
            if missing:
                emit("machine", "fail", "missing in " + o["config"] + ": "
                     + ", ".join(sorted(set(missing))) + "; fix: re-run install.sh")
            elif kept:
                emit("machine", "warn", "%d entry(ies) you set to another value; "
                     "opencode may prompt for the delegate skill" % kept)
            else:
                emit("machine", "ok", "skill entries present")
    if "instructions" in areas:
        detail = merge_instructions(doc, o, dict(record or {}), check=True)
        if detail is None:
            emit("instructions", "ok", "delegate rules entries present")
        elif record is None or "instructions" not in record:
            # never part of this install (or no marker at all): a gap to close, not drift
            emit("instructions", "warn", detail + "; fix: re-run install.sh")
        else:
            emit("instructions", "fail", detail + "; fix: re-run install.sh")
    if "permissions" in areas:
        if record is None or "permissions" not in (record or {}):
            emit("permissions", "warn", "policy not merged by delegate; fix: re-run install.sh")
        elif o.get("policy_render") is None:
            emit("permissions", "fail", "recorded rows but no policy given to compare against; "
                 "fix: re-run install.sh")
        else:
            detail = merge_policy_permissions(doc, o, dict(record), check=True)
            if detail:
                emit("permissions", "fail", detail + "; fix: re-run install.sh")
            else:
                emit("permissions", "ok", "policy rows in sync")
    return state["rc"]


def do_render(o, doc):
    """Render the policy when asked (--render) or when --check must compare recorded rows."""
    # A bare --check is today's contract: the machine entries only, exit 0/1 as before. The
    # newer areas are judged only when named (doctor names them), so an already-merged config
    # predating instructions still checks clean.
    areas = o.get("check_areas") or ["machine"]
    rec = doc.get("_delegate")
    need = bool(o.get("render")) or ("permissions" in areas and o.get("permission_policy")
        and isinstance(rec, dict) and "permissions" in rec)
    if not need or o.get("policy_render") is not None:
        return None
    path = o.get("permission_policy")
    if not path or not os.path.isfile(path):
        return "policy file not found: " + str(path)
    try:
        o["policy_render"] = render_opencode(path, os.path.expanduser("~"))
    except (RuntimeError, OSError, ValueError) as e:
        return "cannot render policy (%s)" % e
    return None


def main(argv):
    o = parse(argv)
    if o.get("uninstall"):
        return cmd_uninstall(o)
    cfg = o["config"]
    doc = load(cfg, check=bool(o.get("check")))
    err = do_render(o, doc)
    if err:
        print(f"merge-opencode-permissions: {err}; config left untouched", file=sys.stderr)
        return 1
    if o.get("check"):
        return cmd_check(o, doc)

    record = doc.get("_delegate") if isinstance(doc.get("_delegate"), dict) else OrderedDict()
    r = merge_machine(doc, o)
    if r is None:
        print(f"merge-opencode-permissions: permission is an array in {cfg}; "
              "add the entries by hand", file=sys.stderr)
        return 1 if o.get("check") else 0
    _missing, ours, kept = r
    record["machine"] = ours
    detail = merge_instructions(doc, o, record)
    if detail and detail.startswith("instructions is"):
        print(f"merge-opencode-permissions: {detail}; the rest was merged", file=sys.stderr)
    detail = merge_policy_permissions(doc, o, record)
    if detail:
        print(f"merge-opencode-permissions: {detail}; file left untouched", file=sys.stderr)
        return 1
    doc["_delegate"] = record
    save(cfg, doc)
    print(f"opencode permissions: merged delegate entries into {cfg}"
          + (f" (kept {kept} value(s) you had set)" if kept else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
