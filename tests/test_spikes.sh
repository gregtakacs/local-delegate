#!/bin/bash
# tests/test_spikes.sh — contract test for the O1b hook spike (docs/specs/o1b-1-hook-spike.md):
# the probe files exist and parse; run.sh --dry-run prints one command group per probe without
# executing a model; every probe refuses to run under --help; no probe names the machine's real
# login dir; the design doc's §6.1 table carries no TODO row after step 1; and S5 — the OpenCode
# probe — actually runs in this sandbox and prints a parseable verdict. Live-Claude probes
# self-report NOT-RUN-HERE where no `claude` login exists; that is their contract, not a skip.
set -u
cd "$(dirname "$0")/.."
fail=0
check() { # $1 name, $2 command (eval'd)
  if eval "$2"; then echo "ok - $1"; else echo "FAIL - $1"; fail=1; fi
}
S=claude/spikes
PROBES="probe-s1-posttooluse probe-s2-notes probe-s3-permission-request
probe-s4-permissions-syntax probe-s5-opencode-reach probe-s6-clinerules probe-s7-rules-load"

for p in $PROBES; do
  check "$p exists" "[ -f '$S/$p.sh' ]"
  check "$p is bash -n clean" "bash -n '$S/$p.sh'"
done
check "run.sh exists and is bash -n clean" "[ -f '$S/run.sh' ] && bash -n '$S/run.sh'"

dout="$(bash "$S/run.sh" --dry-run 2>&1)"; drc=$?
check "run.sh --dry-run exits 0" "[ $drc -eq 0 ]"
groups=$(printf '%s\n' "$dout" | grep -cE '^SPIKE S[0-9]+ commands:')
check "dry-run prints >=7 SPIKE command groups (got $groups)" "[ $groups -ge 7 ]"
check "dry-run executes no probe (no verdict lines)" "! printf '%s\n' \"\$dout\" | grep -qE '^SPIKE S[0-9]+: (PASS|FAIL|NOT-RUN-HERE)'"
check "run.sh --help exits 0" "bash '$S/run.sh' --help >/dev/null 2>&1"
check "run.sh --only rejects an unknown id (exit 2)" "[ \$(bash '$S/run.sh' --only nosuch-probe >/dev/null 2>&1; echo \$?) -eq 2 ]"

for p in $PROBES; do
  h="$(bash "$S/$p.sh" --help 2>&1)"; hrc=$?
  check "$p --help exits 0" "[ $hrc -eq 0 ]"
  check "$p --help shows usage, refuses to run" "printf '%s' \"\$h\" | grep -qi '^usage:' && ! printf '%s' \"\$h\" | grep -q '^SPIKE '"
done

for p in "$S/run.sh" "$S"/probe-*.sh; do
  if grep -qE '(\$HOME|\$\{HOME\})/\.claude|~/\.claude' "$p"; then
    echo "FAIL - $p names the machine's real login dir"; fail=1
  else
    echo "ok - $p never names the real login dir (temp dirs only)"
  fi
done

if sed -n '/^### 6.1/,/^## 7[. ]/p' docs/specs/o1b-design.md | grep -q 'TODO'; then
  echo "FAIL - design doc §6.1 still carries a TODO row"; fail=1
else
  echo "ok - design doc §6.1 has no TODO row left"
fi

# S5 must RUN here (the worker ships opencode + the self-hosted endpoint); gate the assertion on
# exactly those facts so the test stays honest wherever it runs.
if command -v opencode >/dev/null 2>&1 && [ -n "${DELEGATE_BASE_URL:-}" ] && [ -n "${DELEGATE_MODEL:-}" ] && [ -r "${DELEGATE_API_KEY_FILE:-/nonexistent}" ]; then
  s5="$(bash "$S/probe-s5-opencode-reach.sh" 2>&1)"; s5rc=$?
  line="$(printf '%s\n' "$s5" | grep -E '^SPIKE S5: ' | tail -1)"
  st="${line#SPIKE S5: }"; st="${st%% *}"
  check "S5 prints a parseable SPIKE line" "case \"\$line\" in 'SPIKE S5: PASS '*|'SPIKE S5: FAIL '*|'SPIKE S5: NOT-RUN-HERE '*) true;; *) false;; esac"
  check "S5 does not abstain while opencode+endpoint are present" "[ \"\$st\" != NOT-RUN-HERE ]"
  check "S5 exit code matches its verdict" "{ [ \"\$st\" = PASS ] && [ $s5rc -eq 0 ]; } || { [ \"\$st\" = FAIL ] && [ $s5rc -eq 1 ]; }"
  if [ "$st" = FAIL ]; then
    echo "note - S5 recorded a FAIL finding (design §6.1 must carry it): $(printf '%s\n' "$line" | head -c 300)"
  fi
else
  echo "ok - S5 live-run skipped: no opencode or no endpoint env here (offline self-skip)"
fi

[ $fail -eq 0 ] && echo "PASS"
exit "$fail"
