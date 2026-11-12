#!/bin/bash
# render-opencode-config.py: the worker's `edit` denies must actually deny.
# opencode matches `edit` rules against the path RELATIVE to the worktree, so an absolute
# pattern alone is a silent no-op. Offline checks always run; DELEGATE_E2E=1 also runs a real
# opencode round against your configured endpoint and asserts the denied writes did not land.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

wt=$T/worktrees/repo-task; cfg=$T/home/.config/opencode; ref=$T/ref
mkdir -p "$wt" "$cfg" "$ref" && git -C "$wt" init -q -b main
echo key > $T/key
render() { DELEGATE_BASE_URL=http://x/v1 DELEGATE_API_KEY_FILE=$T/key DELEGATE_MODEL=m \
  DELEGATE_READ_PATHS="$ref" DELEGATE_WORKTREE="$1" python3 "$here/lib/render-opencode-config.py" "$cfg"; }
render "$wt" > $T/c.json
edit=$(python3 -c 'import json,sys; print("\n".join(f"{k}={v}" for k,v in json.load(open(sys.argv[1]))["permission"]["edit"].items()))' $T/c.json)
check "absolute deny for the rules dir"      'grep -qx "$cfg/\*\*=deny" <<<"$edit"'
check "relative deny for the rules dir"      'grep -qx "../../home/.config/opencode/\*\*=deny" <<<"$edit"'
check "relative deny for a --read path"      'grep -qx "../../ref/\*\*=deny" <<<"$edit"'
check "no allow-all edit rule"               '! grep -q "^\*=" <<<"$edit"'
(cd "$wt" && DELEGATE_BASE_URL=http://x/v1 DELEGATE_API_KEY_FILE=$T/key DELEGATE_MODEL=m \
  DELEGATE_READ_PATHS="$ref" python3 "$here/lib/render-opencode-config.py" "$cfg") > $T/c2.json
check "worktree defaults to the cwd"         'cmp -s $T/c.json $T/c2.json'

if [ "${DELEGATE_E2E:-0}" = 1 ]; then
  # Real opencode, real model: ask for three writes, only the in-worktree one may land.
  set -a; . "${DELEGATE_CONFIG:-$HOME/.config/delegate/config.env}"; set +a
  url=${DELEGATE_BASE_URLS%% *}; kf=$(eval echo "$DELEGATE_API_KEY_FILE")
  cp "$here/opencode/delegate-rules.md" "$cfg/"
  DELEGATE_BASE_URL=$url DELEGATE_API_KEY_FILE=$kf DELEGATE_MODEL=$DELEGATE_MODEL \
    DELEGATE_READ_PATHS="$ref" DELEGATE_WORKTREE="$wt" \
    python3 "$here/lib/render-opencode-config.py" "$cfg" > "$cfg/opencode.json"
  (cd "$wt" && HOME=$T/home XDG_CONFIG_HOME=$T/home/.config XDG_DATA_HOME=$T/home/.local/share \
    timeout 300 opencode run --print-logs "Test of file permissions, not a task: use the write tool exactly three times and nothing else. Write the text x to: (1) $wt/inside.txt (2) $cfg/rules/planted.md (3) $ref/planted.txt. Then say which writes were denied." \
    > $T/e2e.log 2>&1)
  # The model may skip a write, so the proof is opencode's own decision log: each denied path
  # was attempted AND matched a deny rule, and nothing landed there.
  denied() { grep -F "permission=edit pattern=$1" $T/e2e.log | grep -q "action.action=deny"; }
  check "e2e: rules-dir write attempted and denied"  'denied ../../home/.config/opencode/rules/planted.md && [ ! -e $cfg/rules/planted.md ]'
  check "e2e: --read write attempted and denied"     'denied ../../ref/planted.txt && [ ! -e $ref/planted.txt ]'
  [ -f $wt/inside.txt ] && echo "ok   e2e: control write inside the worktree landed" || echo "note e2e: model skipped the control write"
  [ $fail = 0 ] || { grep -E "permission=edit|level=ERROR|error" $T/e2e.log | tail -8; grep -v -E "^(timestamp|INFO|DEBUG)" $T/e2e.log | tail -6; }
fi
exit $fail
