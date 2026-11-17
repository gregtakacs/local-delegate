#!/bin/bash
# Row 4 of the untrusted-mode design (docs/specs/sg-design.md §2): an inline `python3 -c` /
# `python3 -` helper puts the caller's cwd first on sys.path, so a `json.py` planted in the
# directory `delegate` is started from would be imported by it. Every inline helper therefore
# runs with -I. Static, like tests/test_round_commit.sh, plus one behavioural run of
# `delegate accept` from a cwd holding the plant: accept uses both helper forms (it reads a
# round's report.json and writes accept.json) and needs neither worker,
# docker nor network. Task state fabricated the way tests/test_top.sh does it, in a temp
# DELEGATE_STATE; the real $HOME is never read or written.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# ------------------------------------------------------------------- 1. static -------------
# A helper that lost its -I shows up in this grep: `-I` before the flag means the pattern does
# not match the line at all. Script calls (`python3 "$DELEGATE_HOME/lib/x.py"`) are not inline
# helpers and are not supposed to match.
plain=$(grep -nE 'python3 +(-c|-)( |$)' "$here/bin/delegate" || true)
check "no inline python helper without -I" '[ -z "$plain" ]'
has() { grep -qE "$1" "$here/bin/delegate"; }
check "the -I forms are the ones the grep would have caught" \
  'has "python3 -I -c" && has "python3 -I - "'

# ----------------------------------------------------- 2. the plant, and accept over it ------
plant=$T/plant; mkdir -p "$plant"
cat > "$plant/json.py" <<'PY'
# a module planted by whoever owns the directory delegate is run from
import os
open("planted-json-imported", "w").write(os.getcwd())
PY
MARK="$plant/planted-json-imported"

# Pin every place delegate could write, so an ambient DELEGATE_* from the caller's own install
# cannot send a file to the real $HOME (what tests/test_worktree_layout.sh does).
export HOME=$T/home XDG_CONFIG_HOME=$T/xdg-config XDG_CACHE_HOME=$T/cache
export DELEGATE_STATE=$T/state DELEGATE_CONFIG=/dev/null DELEGATE_PROGRESS=0
export DELEGATE_LEDGER=$T/led/events.jsonl DELEGATE_WORKTREES=$T/wtrees
mkdir -p "$HOME" "$DELEGATE_STATE/t-iso/rounds/1"
printf 'ID=t-iso\nSLUG=t-iso\nREPO=%s\nWORKTREE=%s/wt\nBRANCH=delegate/t-iso\nHERE=0\n' \
  "$T/repo" "$T" > "$DELEGATE_STATE/t-iso/meta.env"
printf '{"status":"failed"}\n' > "$DELEGATE_STATE/t-iso/rounds/1/report.json"

# First prove the plant works, for both helper forms: without -I a plain helper in that cwd
# imports it. If these two fail, the plant is inert and the -I assertions below say nothing.
(cd "$plant" && python3 -c 'import json') >/dev/null 2>&1 || true
check "the plant is imported by a plain python3 -c from that cwd" '[ -f "$MARK" ]'
rm -f "$MARK"
(cd "$plant" && python3 - <<'PY'
import json
PY
) >/dev/null 2>&1 || true
check "the plant is imported by a plain python3 - (stdin script) from that cwd" '[ -f "$MARK" ]'
rm -f "$MARK"

# The command itself, from the planted cwd: accept reads the report with `python3 -I -c` and
# writes accept.json with `python3 -I - <<PY`, so it exercises both helper forms.
( cd "$plant" && "$here/bin/delegate" accept t-iso -m "verified by hand: the report lies" ) >"$T/accept.out" 2>&1
rc=$?
check "delegate accept succeeded from the planted cwd" '[ "$rc" = 0 ]'
check "accept reported the round accepted" 'grep -q "accepted t-iso round 1" "$T/accept.out"'
check "accept.json was written" '[ -f "$DELEGATE_STATE/t-iso/accept.json" ]'
check "the planted json.py was NOT imported by accept" '[ ! -e "$MARK" ]'

exit $fail
