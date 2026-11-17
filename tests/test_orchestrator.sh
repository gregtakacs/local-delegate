#!/bin/bash
# The delegating session (round:2): `delegate run` records which harness session started a
# task (meta.env ORCH/ORCH_SESSION) and every round row carries it, so delegated work can be
# grouped under the session that asked for it. The function is run from bin/delegate's own
# text, with the harness environment set per case; the row side is in test_ledger_round.sh.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

fn=$(sed -n '/^orchestrator_of() {/,/^}/p' "$here/bin/delegate")
check "orchestrator_of is defined in bin/delegate" '[ -n "$fn" ]'
orch() { env -i PATH="$PATH" "$@" bash -c "$fn"'
orchestrator_of'; }

check "Claude Code's session id, named claude-code" \
  '[ "$(orch CLAUDE_CODE_SESSION_ID=1e061308-50b0-409a)" = "claude-code 1e061308-50b0-409a" ]'
check "OpenCode's session id, named opencode" \
  '[ "$(orch OPENCODE_SESSION_ID=ses_AbC123)" = "opencode ses_AbC123" ]'
check "both set: Claude Code, the inner caller, wins" \
  '[ "$(orch OPENCODE_SESSION_ID=ses_AbC123 CLAUDE_CODE_SESSION_ID=cc-1)" = "claude-code cc-1" ]'
check "no harness: nothing" '[ -z "$(orch)" ]'
check "an empty id is no id" '[ -z "$(orch CLAUDE_CODE_SESSION_ID=)" ]'
for bad in 'a b' 'x;rm -rf /' '$(id)' "$(printf 'x%.0s' $(seq 1 129))" 'tab	x' 'new
line'; do
  check "an id outside the token shape is not recorded: ${bad:0:12}" \
    "[ -z \"\$(orch CLAUDE_CODE_SESSION_ID='$bad')\" ]"
done

check "cmd_run writes ORCH and ORCH_SESSION in the same meta.env write" \
  "grep -q \"printf 'ORCH=%q\\\\\\\\nORCH_SESSION=%q\" $here/bin/delegate"
check "the meta reader passes both to the row" \
  "grep -q 'emit orchestrator \"\${ORCH:-}\"; emit orchestrator_session \"\${ORCH_SESSION:-}\"' $here/bin/delegate"
check "the import reads both from meta.env" \
  "grep -q 'meta.get(\"ORCH_SESSION\")' $here/lib/ledger.py"
exit $fail
