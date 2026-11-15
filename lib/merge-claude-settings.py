#!/usr/bin/env python3
"""merge-claude-settings.py — install the delegate harness profile into ~/.claude (O1b step 5).

The Claude Code half of the installer's merge contract (design §8.2): keep everything the user
has, add only what delegate needs, mark what is ours under the top-level `_delegate` key, and
refuse (exit 1, file untouched) a settings.json that is not valid JSON. Mirrors
merge-opencode-permissions.py's discipline; settings.json tolerates the unknown `_delegate` key.

  --settings PATH    the settings file (default: $HOME/.claude/settings.json; tests pass this)
  --home PATH        home whose .claude dir is the target (overridable for tests)
  --install PATH     the install tree commands/links point THROUGH (release mode: .../current)
  --real-dir PATH    the same tree after symlinks (rule sources are read from here)
  --permissions      merge the rendered permission arrays (the --claude-permissions decision)
  --agent-progress   add the dashboard hook entries (the old install.sh --claude-hook behaviour)
  --check [AREA...]  verify and write nothing; AREA in {hooks,permissions,rules,exempt};
                     prints `check <area>: <ok|warn|fail> <detail>`; exit 1 on any fail, 2 on warn
  --uninstall        remove every _delegate-recorded entry (and the rules file when it is ours),
                     leaving everything else; a hand-edited managed entry is left with a NOTE

Data-picked constants (design §6.1; flip ONLY when a re-run of claude/spikes/run.sh says so):
  RULES_MODE: S7 NOT-RUN + owner decision 3 -> copy the combined rules file, record its sha256.
  CLINERULES_ROUTE: S6 PASS -> a file `@import` line reaches .clinerules; the alternative (a
  read-the-dir rule sentence) failed the spike, so the sentence branch ships but is not picked.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
from collections import OrderedDict

RULES_MODE = "copy"                # "copy" | "symlink" (spike S7 decides; NOT-RUN -> copy)
CLINERULES_ROUTE = "import"        # "import" | "rule"   (spike S6 decided -> import)
POLICY_VERSION = 1
RULE_HEAD = "<!-- installed by delegate (lib/merge-claude-settings.py); re-run install.sh -->"
CLINERULES_IMPORT = "@.clinerules"
CLINERULES_RULE = ("If the project has a `.clinerules` directory, read every `*.md` file under it "
                   "before starting work there.")


def die(msg):
    print("merge-claude-settings: " + msg, file=sys.stderr)
    return 1


def expand(p):
    return os.path.expanduser(p) if p else p


class Target:
    """Paths derived from the chosen HOME or an explicit --settings file (overridable for tests)."""

    def __init__(self, settings=None, home=None):
        home = expand(home or os.environ.get("HOME") or os.path.expanduser("~"))
        if settings:
            self.settings = expand(settings)
            self.claude_dir = os.path.dirname(self.settings)
        else:
            self.claude_dir = os.path.join(home, ".claude")
            self.settings = os.path.join(self.claude_dir, "settings.json")
        self.rules_file = os.path.join(self.claude_dir, "rules", "delegate-harness.md")


def hook_specs(install, with_agent_progress):
    """The managed hook entries: id -> list of (event, matcher_or_None, hook_object).

    Every harness.py entry shares one command string (design §8.2's one-command discipline);
    agent-progress keeps its own command so the dashboard hook stays portable apart from the rest.
    Matchers mirror the shapes the spikes recorded working (S1/S2/S3), one entry per matcher value
    for the non-tool events rather than an unproven `a|b` alternation.
    """
    harness = "python3 " + os.path.join(install, "claude", "hooks", "harness.py")
    ap = "python3 " + os.path.join(install, "claude", "hooks", "agent-progress.py")

    def sync(cmd):
        return {"type": "command", "command": cmd, "timeout": 10}

    def dash(cmd):
        return {"type": "command", "command": cmd, "async": True, "timeout": 10}

    specs = OrderedDict()
    specs["todo-loop"] = [("PostToolUse", "*", sync(harness))]
    specs["verify-loop"] = [("PostToolUse", "Edit|Write", sync(harness))]
    specs["notes-loop"] = [("SessionStart", "startup", sync(harness)),
                           ("SessionStart", "resume", sync(harness)),
                           ("PreCompact", "auto", sync(harness)),
                           ("PreCompact", "manual", sync(harness))]
    specs["permission-guard"] = [("PermissionRequest", None, sync(harness))]
    if with_agent_progress:
        specs["agent-progress"] = [(ev, "*", dash(ap))
                                   for ev in ("PostToolUse", "PostToolUseFailure", "SubagentStop")]
    return specs


def render_permissions(policy_path, home):
    """The Claude rendering via translate-permissions.py (subprocess, so the two stay honest)."""
    lib = os.path.dirname(os.path.abspath(__file__))
    r = subprocess.run(
        [sys.executable, os.path.join(lib, "translate-permissions.py"),
         "--policy", policy_path, "--render", "claude", "--home", home],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip() or "renderer exited %d" % r.returncode)
    return json.loads(r.stdout, object_pairs_hook=OrderedDict)["permissions"]


def rules_content(real_dir):
    """The combined rules file body: header, core, claude adapter, the .clinerules route."""
    parts = [RULE_HEAD, ""]
    for rel in (os.path.join("opencode", "rules", "harness-core.md"),
                os.path.join("opencode", "rules", "adapter-claude-code.md")):
        src = os.path.join(real_dir, rel)
        if not os.path.isfile(src):
            raise RuntimeError("rule source missing: " + src)
        parts.append(open(src).read().strip("\n"))
        parts.append("")
    parts.append("## .clinerules\n")
    parts.append(CLINERULES_IMPORT if CLINERULES_ROUTE == "import" else CLINERULES_RULE)
    parts.append("")
    return "\n".join(parts)


def sha256_file(path):
    try:
        return hashlib.sha256(open(path, "rb").read()).hexdigest()
    except OSError:
        return None


def load(target):
    """(doc, existed). Raises ValueError on invalid JSON; {} when absent."""
    if not os.path.exists(target.settings):
        return OrderedDict(), False
    return json.load(open(target.settings), object_pairs_hook=OrderedDict), True


def save(target, doc):
    os.makedirs(os.path.dirname(target.settings), exist_ok=True)
    tmp = target.settings + ".tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    os.replace(tmp, target.settings)


def entry_command(group):
    """The first command string in a hook group, if it carries one."""
    hooks = group.get("hooks")
    if not isinstance(hooks, list):
        return None
    for h in hooks:
        if isinstance(h, dict) and isinstance(h.get("command"), str):
            return h["command"].strip()
    return None


def _norm_cmd(cmd):
    """A hook command with its script path resolved, so a `current`-through spelling and the
    version-dir spelling it points at are the same command (release installs link through current)."""
    parts = str(cmd).split()
    if len(parts) == 2 and os.path.exists(parts[1]):
        return parts[0] + " " + os.path.realpath(parts[1])
    return str(cmd)


def merge_hooks(doc, specs, check=False):
    """Add-if-absent our entries; identical ones are adopted. An entry is SATISFIED when the
    file carries our command for that event at exactly this matcher, or at the catch-all matcher
    (`*`, or no matcher key — the hook reference treats both as every tool/source): a hand-written
    catch-all covers the whole event, so we adopt it and never duplicate the specific entries it
    already fires. The same rule serves check and install, which makes re-runs byte-stable.
    Returns (missing, adopted_ids)."""
    hooks = doc.setdefault("hooks", OrderedDict())
    if not isinstance(hooks, dict):
        raise RuntimeError("hooks is not an object in settings.json; merge by hand")
    wanted = {_norm_cmd(h["command"]) for entries in specs.values() for ev, m, h in entries}
    present = set()   # (event, normalized matcher, command) as FOUND in the file
    for ev, groups in list(hooks.items()):
        if isinstance(groups, list):
            for g in groups:
                if isinstance(g, dict) and _norm_cmd(entry_command(g)) in wanted:
                    present.add((ev, g.get("matcher") or "*", _norm_cmd(entry_command(g))))
    missing, adopted = [], []
    for sid, entries in specs.items():
        for ev, matcher, hobj in entries:
            cmd, m = hobj["command"], (matcher or "*")
            if (ev, m, _norm_cmd(cmd)) in present or (ev, "*", _norm_cmd(cmd)) in present:
                adopted.append(sid)
                continue
            missing.append("%s[%s]" % (ev, matcher or "-"))
            if check:
                continue
            groups = hooks.setdefault(ev, [])
            if not isinstance(groups, list):
                raise RuntimeError("hooks.%s is not a list in settings.json" % ev)
            entry = OrderedDict([("hooks", [OrderedDict(hobj)])])
            if matcher is not None:
                entry = OrderedDict([("matcher", matcher), ("hooks", [OrderedDict(hobj)])])
            groups.append(entry)
            present.add((ev, m, cmd))
    return missing, sorted(set(adopted))


def merge_permissions(doc, rendered, check=False):
    """Add-if-absent into the three arrays; identical strings (foreign or ours) are adopted.
    Returns (added, adopted) rule strings; foreign entries are never removed or claimed."""
    perms = doc.setdefault("permissions", OrderedDict())
    if not isinstance(perms, dict):
        raise RuntimeError("permissions is not an object in settings.json; merge by hand")
    added, adopted = [], []
    for bucket in ("allow", "ask", "deny"):
        cur = perms.get(bucket)
        if cur is None and not check:
            cur = perms[bucket] = []
        if not isinstance(cur, list):
            raise RuntimeError("permissions.%s is not a list in settings.json" % bucket)
        for s in rendered.get(bucket, []):
            if s in cur:
                adopted.append(s)
            else:
                added.append(s)
                if not check:
                    cur.append(s)
    return added, adopted


def remove_permissions(doc, recorded):
    """Drop recorded strings from the arrays; strings not found were edited away or by hand.
    Returns the strings that could not be found (the NOTE list)."""
    perms = doc.get("permissions")
    if not isinstance(perms, dict) or not recorded:
        return []
    found = set()
    for s in recorded:
        for b in ("allow", "ask", "deny"):
            if isinstance(perms.get(b), list) and s in perms[b]:
                perms[b].remove(s)
                found.add(s)
    return [s for s in recorded if s not in found]


def write_rules(target, content, recorded_sha=None):
    """Install the combined rules file. copy (the S7-picked default, owner decision 3).

    An existing file is replaced when it is what we wrote last time (its sha256 equals the
    recorded one) or already equals the new content; anything else was edited by the owner and
    is refused. Comparing against the NEW content alone would refuse every update whose rule
    text changed."""
    digest = hashlib.sha256(content.encode()).hexdigest()
    if os.path.islink(target.rules_file):
        t = os.path.realpath(target.rules_file)
        print("NOTE: %s is a symlink to %s; left alone, replace it to take the installed rules"
              % (target.rules_file, t))
        return "copy", digest
    if os.path.lexists(target.rules_file) and \
            sha256_file(target.rules_file) not in (digest, recorded_sha):
        raise RuntimeError("rules file exists and differs from what we would write (edited by "
                           "you?): " + target.rules_file + "; fix: remove it, re-run install.sh")
    os.makedirs(os.path.dirname(target.rules_file), exist_ok=True)
    tmp = target.rules_file + ".tmp"
    with open(tmp, "w") as f:
        f.write(content)
    os.replace(tmp, target.rules_file)
    return "copy", digest


def record_of(doc):
    r = doc.get("_delegate")
    return r if isinstance(r, dict) else None


def _present_in(perms, s):
    return isinstance(perms, dict) and any(isinstance(perms.get(b), list) and s in perms[b]
                                           for b in ("allow", "ask", "deny"))


def cmd_install(o):
    target = o["target"]
    if os.path.isfile(target.claude_dir):
        return die("%s is a regular file, not a directory; fix: remove it, then re-run install.sh"
                   % target.claude_dir)
    try:
        doc, _ = load(target)
    except ValueError as e:
        return die("%s is not valid JSON (%s); file left untouched" % (target.settings, e))
    if not isinstance(doc, dict):
        return die("%s is not a JSON object; file left untouched" % target.settings)
    specs = hook_specs(o["install"], o["agent_progress"])
    try:
        record = record_of(doc) or OrderedDict([("version", POLICY_VERSION)])
        missing, adopted = merge_hooks(doc, specs)
        record["hooks"] = sorted(set(record.get("hooks", [])) | set(adopted) | set(specs.keys()))
        doc["_delegate"] = record
        if o["permissions"]:
            rendered = render_permissions(o["policy"], os.path.dirname(target.claude_dir))
            added, adopted_p = merge_permissions(doc, rendered)
            # Only strings WE placed go into the record: an identical one that was already the
            # user's stays foreign (never claimed, never removed), just always satisfied.
            record["permissions"] = sorted(set(record.get("permissions", [])) | set(added))
        kind, sha = write_rules(target, rules_content(o["real_dir"]), record.get("rules_sha256"))
        # The tree the hook commands point through, so an uninstall run from another tree
        # (a checkout, a different release spelling) still recognises our entries.
        record["install"] = o["install"]
        record["rules_sha256"] = sha
        record["rules_target"] = target.rules_file if kind == "copy" else o["real_dir"]
    except (RuntimeError, subprocess.SubprocessError) as e:
        return die(str(e))
    save(target, doc)
    print("claude settings: merged hooks into %s (%d entries)%s"
          % (target.settings, sum(len(v) for v in specs.values()),
             ", adopted yours: " + ", ".join(adopted) if adopted else ""))
    return 0


def cmd_check(o):
    target = o["target"]
    areas = o["check"] or ["hooks", "permissions", "rules", "exempt"]
    if os.path.isfile(target.claude_dir):
        print("check rules: fail %s is a regular file; fix: remove it and re-run install.sh"
              % target.claude_dir)
        return 1
    if not os.path.exists(target.settings):
        for a in areas:
            print("check %s: warn no settings.json at %s; fix: re-run install.sh" % (a, target.settings))
        return 2
    try:
        doc, _ = load(target)
    except ValueError as e:
        print("check hooks: fail %s is not valid JSON (%s); fix: repair it and re-run install.sh"
              % (target.settings, e))
        return 1
    if not isinstance(doc, dict):
        print("check hooks: fail %s is not a JSON object; fix: re-run install.sh" % target.settings)
        return 1
    record = record_of(doc)
    rc = 0
    specs = hook_specs(o["install"], "agent-progress" in ((record or {}).get("hooks") or []))
    if "hooks" in areas:
        if record is None:
            print("check hooks: warn settings.json never merged by delegate; fix: re-run install.sh")
            rc = max(rc, 2)
        else:
            missing, adopted = merge_hooks(doc, specs, check=True)
            ids = [s for s in specs if s in (record.get("hooks") or [])]
            if missing:
                print("check hooks: fail missing %s; fix: re-run install.sh" % ", ".join(missing))
                rc = max(rc, 1)
            elif len(ids) < 4:
                print("check hooks: warn only %s recorded; fix: re-run install.sh"
                      % (", ".join(ids) or "none"))
                rc = max(rc, 2)
            else:
                print("check hooks: ok %s" % ", ".join(ids))
    if "permissions" in areas:
        perms = doc.get("permissions")
        rec_p = (record or {}).get("permissions")
        if rec_p is None:
            print("check permissions: warn permissions block not delegate-recorded; "
                  "fix: re-run install.sh --claude-permissions")
            rc = max(rc, 2)
        else:
            try:
                rendered = render_permissions(o["policy"], os.path.dirname(target.claude_dir))
            except (RuntimeError, subprocess.SubprocessError, ValueError) as e:
                print("check permissions: fail cannot render policy (%s); fix: re-run install.sh" % e)
                return 1
            want = set(rendered.get("allow", [])) | set(rendered.get("ask", [])) | set(rendered.get("deny", []))
            drift = ["stale:" + s for s in rec_p if s not in want] \
                    + ["absent:" + s for s in sorted(want) if not _present_in(perms, s)]
            if drift:
                print("check permissions: fail %s; fix: re-run install.sh --claude-permissions"
                      % ", ".join(sorted(drift)[:6]))
                rc = max(rc, 1)
            else:
                print("check permissions: ok %d rules match the policy render" % len(want))
    if "rules" in areas:
        if record is None or "rules_sha256" not in record:
            print("check rules: warn rules never installed; fix: re-run install.sh")
            rc = max(rc, 2)
        elif not os.path.isfile(target.rules_file):
            print("check rules: fail rules file missing at %s; fix: re-run install.sh"
                  % target.rules_file)
            rc = max(rc, 1)
        else:
            try:
                want = hashlib.sha256(rules_content(o["real_dir"]).encode()).hexdigest()
            except (RuntimeError, OSError) as e:
                print("check rules: fail rule sources unreadable (%s); fix: re-run install.sh" % e)
                return 1
            got, rec = sha256_file(target.rules_file), record["rules_sha256"]
            if got == want:
                print("check rules: ok %s" % target.rules_file)
            elif got != rec:
                print("check rules: fail edited since install; fix: re-run install.sh "
                      "(your edit survives until then)")
                rc = max(rc, 1)
            else:
                print("check rules: fail stale (the install tree changed); fix: re-run install.sh")
                rc = max(rc, 1)
    if "exempt" in areas:
        bad = [str(h.get("command", "")) for groups in (doc.get("hooks") or {}).values()
               if isinstance(groups, list) for g in groups
               if isinstance(g, dict) and isinstance(g.get("hooks"), list) for h in g["hooks"]
               if isinstance(h, dict) and re.search(r"chunk[-_]?cap", str(h.get("command", "")))]
        if bad:
            print("check exempt: fail a chunk-cap-shaped hook entered settings.json (%s); fix: "
                  "remove it, Claude Code is exempt from the cap (design §5.3)" % ", ".join(bad[:2]))
            rc = max(rc, 1)
        else:
            print("check exempt: ok no cap-shaped hook in settings.json")
    return rc


def cmd_uninstall(o):
    target = o["target"]
    if not os.path.exists(target.settings):
        return 0
    try:
        doc, _ = load(target)
    except ValueError as e:
        return die("%s is not valid JSON (%s); nothing removed" % (target.settings, e))
    if not isinstance(doc, dict):
        return die("%s is not a JSON object; nothing removed" % target.settings)
    record = record_of(doc)
    if record is None:
        print("claude settings: no _delegate record; nothing of ours to remove")
    else:
        hooks = doc.get("hooks")
        if isinstance(hooks, dict):
            ap = "agent-progress" in (record.get("hooks") or [])
            roots = [o["install"]]
            if isinstance(record.get("install"), str) and record["install"] not in roots:
                roots.append(record["install"])
            exact = {}   # command -> set of group shapes we would have written
            for entries in [e for r in roots for e in hook_specs(r, ap).values()]:
                for ev, matcher, hobj in entries:
                    g = OrderedDict([("hooks", [OrderedDict(hobj)])])
                    if matcher is not None:
                        g = OrderedDict([("matcher", matcher), ("hooks", [OrderedDict(hobj)])])
                    exact.setdefault(hobj["command"], set()).add(json.dumps(g, sort_keys=True))
            wanted = set(exact)
            for ev in list(hooks.keys()):
                groups = hooks[ev]
                if not isinstance(groups, list):
                    continue
                kept, ours, edited = [], 0, []
                for g in groups:
                    cmd = entry_command(g) if isinstance(g, dict) else None
                    if cmd in wanted and json.dumps(g, sort_keys=True) in exact[cmd]:
                        ours += 1               # exactly our shape: ours to remove
                    else:
                        if cmd in wanted:
                            edited.append(g)    # carries our command but hand-edited: leave it
                        kept.append(g)
                hooks[ev] = kept
                if edited:
                    print("NOTE: %s carries a delegate command we did not write; left alone" % ev)
                if not hooks[ev]:
                    del hooks[ev]
        leftover = remove_permissions(doc, record.get("permissions") or [])
        if leftover:
            print("NOTE: permission entries not found (edited by you?): %s; left alone"
                  % ", ".join(leftover[:4]))
        perms = doc.get("permissions")
        if isinstance(perms, dict):
            for b in ("allow", "ask", "deny"):
                if perms.get(b) == []:
                    del perms[b]
            if not perms:
                del doc["permissions"]
        if isinstance(doc.get("hooks"), dict) and not doc["hooks"]:
            del doc["hooks"]
        doc.pop("_delegate", None)
        save(target, doc)
        print("claude settings: removed delegate entries from %s" % target.settings)
    sha = (record or {}).get("rules_sha256")
    if os.path.lexists(target.rules_file):
        if os.path.islink(target.rules_file):
            t = os.path.realpath(target.rules_file)
            if t.startswith(o["real_dir"].rstrip(os.sep) + os.sep):
                os.unlink(target.rules_file)
                print("removed " + target.rules_file)
            else:
                print("NOTE: %s is a symlink to %s, not ours; left alone" % (target.rules_file, t))
        elif sha and sha256_file(target.rules_file) == sha:
            os.unlink(target.rules_file)
            print("removed " + target.rules_file)
        else:
            print("NOTE: %s was edited after install; left alone" % target.rules_file)
    return 0


def parse(argv):
    o = {"install": None, "real_dir": None, "policy": None, "permissions": False,
         "agent_progress": False, "check": None, "uninstall": False,
         "settings": None, "home": None}
    args = list(argv)
    while args:
        a = args.pop(0)
        if a in ("--settings", "--home", "--install", "--real-dir", "--policy"):
            o[a[2:].replace("-", "_")] = args.pop(0)
        elif a == "--permissions":
            o["permissions"] = True
        elif a == "--agent-progress":
            o["agent_progress"] = True
        elif a == "--check":
            o["check"] = []
            while args and not args[0].startswith("--"):
                o["check"].append(args.pop(0))
        elif a == "--uninstall":
            o["uninstall"] = True
        else:
            sys.exit("merge-claude-settings: unknown option " + a)
    o["target"] = Target(o["settings"], o["home"])
    if o["install"] is None:
        o["install"] = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if o["real_dir"] is None:
        o["real_dir"] = os.path.realpath(o["install"])
    if o["policy"] is None:
        o["policy"] = os.path.join(o["real_dir"], "policy", "harness-permissions.json")
    return o


def main(argv):
    o = parse(argv)
    if o["uninstall"]:
        return cmd_uninstall(o)
    if o["check"] is not None:
        return cmd_check(o)
    return cmd_install(o)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
