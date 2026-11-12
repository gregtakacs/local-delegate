#!/usr/bin/env python3
"""merge-opencode-permissions.py — make the delegate skill loadable from opencode.

install.sh runs this so a fresh delegate install doesn't cost the orchestrator a permission
prompt for its own skill. It only ever ADDS entries it needs and are still absent; it never
rewrites a value you set, and refuses to touch a config that is not valid JSON.

  --config PATH        default: $XDG_CONFIG_HOME|~/.config /opencode/opencode.json
  --skill-dir PATH     the skills dir entry that was linked (for external_directory)
  --real-dir PATH      the same directory after symlinks (rules may see either)
  --check              verify the entries are present; write nothing, exit 1 with the fix
"""
import json
import os
import sys
from collections import OrderedDict


def config_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "opencode", "opencode.json")


def parse(argv):
    args, opts = list(argv), {}
    while args:
        a = args.pop(0)
        if a in ("--config", "--skill-dir", "--real-dir"):
            opts[a[2:].replace("-", "_")] = os.path.expanduser(args.pop(0))
        elif a == "--check":
            opts["check"] = True
        else:
            sys.exit(f"merge-opencode-permissions: unknown option {a}")
    opts.setdefault("config", config_path())
    return opts


def main(argv):
    o = parse(argv)
    cfg, missing = o["config"], []
    if os.path.exists(cfg):
        try:
            doc = json.load(open(cfg), object_pairs_hook=OrderedDict)
        except (json.JSONDecodeError, ValueError) as e:
            print(f"merge-opencode-permissions: {cfg} is not valid JSON ({e}); "
                  "file left untouched", file=sys.stderr)
            return 1
    elif o.get("check"):
        print(f"merge-opencode-permissions: no opencode config at {cfg}; "
              "fix: re-run install.sh", file=sys.stderr)
        return 1
    else:
        doc = OrderedDict([("$schema", "https://opencode.ai/config.json")])

    want = [("skill", "delegate", "allow")]
    for d in (o.get("skill_dir"), o.get("real_dir")):
        if d:
            want.append(("external_directory", os.path.join(d, "**"), "allow"))

    perm = doc.setdefault("permission", OrderedDict())
    if not isinstance(perm, dict):  # e.g. the array form; leave it alone
        print(f"merge-opencode-permissions: permission is an array in {cfg}; "
              "add the entries by hand", file=sys.stderr)
        return 1 if o.get("check") else 0

    # --check never mutates: an entry the user deliberately set to something else is
    # their choice and passes; only absent entries fail the check.
    changed = kept = 0
    for section, pattern, val in want:
        cur = perm.get(section)
        if cur is None and not o.get("check"):
            cur = perm[section] = OrderedDict()
        if not isinstance(cur, dict):
            if cur is not None:
                print(f"merge-opencode-permissions: permission.{section} is not a "
                      f"pattern map in {cfg}; add '{pattern}' by hand", file=sys.stderr)
            missing.append(f"{section}/{pattern}")
            continue
        if pattern in cur:
            if cur[pattern] != val:
                kept += 1
            continue
        missing.append(f"{section}/{pattern}")
        if not o.get("check"):
            cur[pattern] = val
            changed += 1

    if o.get("check"):
        if missing:
            print("merge-opencode-permissions: missing in " + cfg + ": "
                  + ", ".join(sorted(set(missing))) + "; fix: re-run install.sh",
                  file=sys.stderr)
            return 1
        if kept:
            print(f"merge-opencode-permissions: {kept} entr(y/ies) set by you to a "
                  f"different value; opencode may prompt for the delegate skill")
        return 0
    if changed:
        tmp = cfg + ".tmp"
        os.makedirs(os.path.dirname(cfg), exist_ok=True)
        with open(tmp, "w") as f:
            json.dump(doc, f, indent=2)
            f.write("\n")
        os.replace(tmp, cfg)
        print(f"opencode permissions: added {changed} delegate entries to {cfg}"
              + (f" (kept {kept} value(s) you had set)" if kept else ""))
    else:
        print(f"opencode permissions: {cfg} already set"
              + (f" (kept {kept} value(s) you had set)" if kept else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
