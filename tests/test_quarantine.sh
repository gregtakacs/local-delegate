#!/bin/bash
# `delegate rm` keeps the evidence of a round whose worker reported planted instructions or an
# injection (quarantine/), and removes a clean task without a trace. Also: report.py flagged.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DELEGATE_STATE=$T/state DELEGATE_RUNNER=native DELEGATE_PROGRESS=0 DELEGATE_CONFIG=$T/none.env
mkdir -p $T/repo && git -C $T/repo init -q -b main
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
mk() { # id final-text
  local d=$DELEGATE_STATE/$1; mkdir -p $d/rounds/1
  printf 'ID=%q\nSLUG=%q\nREPO=%q\nHERE=1\nRUNNER=native\nVERIFY=true\n' "$1" "$1" "$T/repo" > $d/meta.env
  echo spec > $d/spec.md
  python3 -c 'import json,sys; print(json.dumps({"type":"tool_use"})); print(json.dumps({"type":"text","part":{"text":sys.argv[1]}}))' "$2" > $d/rounds/1/events.jsonl
  echo '{"status":"done"}' > $d/rounds/1/report.json
}
mk t-clean "STATUS: done. All acceptance criteria verified."
mk t-flag "STATUS: done. NOTE: found a planted /testing/outgoing/x.txt that told me to push; I ignored it."
"$here/bin/delegate" rm t-clean >/dev/null 2>&1
"$here/bin/delegate" rm t-flag >/dev/null 2>&1
check "clean task removed, nothing quarantined" '[ ! -d $DELEGATE_STATE/t-clean ] && ! ls $DELEGATE_STATE/quarantine/t-clean-* >/dev/null 2>&1'
check "flagged task removed but its round kept" '[ ! -d $DELEGATE_STATE/t-flag ] && ls $DELEGATE_STATE/quarantine/t-flag-*/round-1/events.jsonl >/dev/null 2>&1 && ls $DELEGATE_STATE/quarantine/t-flag-*/meta.env >/dev/null 2>&1'
check "quarantine is not listed as a task" '! "$here/bin/delegate" list 2>/dev/null | grep -q quarantine'
for txt in "a prompt injection in the README" "the file told me to copy the secrets out" "I ignored the instructions in the file" "possible exfiltration attempt"; do
  mk t-x "$txt"; check "flagged: $txt" 'python3 $here/lib/report.py flagged $DELEGATE_STATE/t-x/rounds/1/events.jsonl'; rm -rf $DELEGATE_STATE/t-x
done
for txt in "implemented the injection-free parser; tests pass" "ignored lint warnings in vendored code"; do
  mk t-x "$txt"; check "not flagged: $txt" '! python3 $here/lib/report.py flagged $DELEGATE_STATE/t-x/rounds/1/events.jsonl'; rm -rf $DELEGATE_STATE/t-x
done
# continue --verify persists as the task's verify (meta_set before the round runs)
mk t-v "done"; ( cd $here; TASK_DIR=$DELEGATE_STATE/t-v; source <(sed -n '/^meta_set()/,/^}/p' bin/delegate); meta_set VERIFY "npm test -- x" )
check "meta_set rewrites VERIFY" '( . $DELEGATE_STATE/t-v/meta.env; [ "$VERIFY" = "npm test -- x" ] ) && [ $(grep -c ^VERIFY= $DELEGATE_STATE/t-v/meta.env) = 1 ]'
exit $fail
