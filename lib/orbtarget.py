#!/usr/bin/env python3
"""Read an .orb-target file WITHOUT executing it; print shell-safe ORB_* assignments.

  orbtarget.py FILE   ->  ORB_LABEL=... ORB_BASE_MAC=... ORB_SERIAL=... ORB_IP=... (one per line)

The file is bash syntax (KEY=VALUE, comments, quotes). It lives in a repository, so it is
parsed, never sourced. Exit 2 if ORB_SERIAL and ORB_IP are both missing.
"""
import re
import shlex
import sys

KEYS = ("ORB_LABEL", "ORB_BASE_MAC", "ORB_SERIAL", "ORB_IP")
vals = {}
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    m = re.match(r"\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)$", line)
    if not m or m.group(1) not in KEYS:
        continue
    raw = m.group(2).strip()
    try:
        parts = shlex.split(raw, comments=True)
    except ValueError:
        parts = [raw.strip("'\"")]
    vals[m.group(1)] = parts[0] if parts else ""
if not (vals.get("ORB_SERIAL") or vals.get("ORB_IP")):
    sys.exit(2)
for k in KEYS:
    print(f"{k}={shlex.quote(vals.get(k, ''))}")
