#!/bin/bash
# The verify re-run (spec: verify-flake). A round whose worker said done and whose harness
# verify then reds may meet a flaky suite, not broken work: the harness re-runs the same
# command up to N extra times (default 1); a passing re-run closes the round `done` and the
# flake is recorded — report.json's verify_flaky, a VERIFY FLAKE line in report.md, the
# failed run kept as verify-1.log, and one 0600 line in $DELEGATE_STATE/flakes.jsonl.
# Only a done round is re-run; every other outcome is the old single verify.
# No docker, no model, no network: the lifecycle is stubbed at the function boundary (the
# test_ledger_round pattern); the verify command, report.py and flakes.py really run.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
export DELEGATE_CONFIG=$T/none.env DELEGATE_HOME=$here DELEGATE_RUNNER=native
export DELEGATE_VERIFY_TIMEOUT=60 DELEGATE_STATE=$T/state
S=$T/state; mkdir -p "$S"; FL=$S/flakes.jsonl
extract() {
  awk -v fn="$1" '
    !infn && index($0, fn "() {") == 1 { infn=1 }
    infn { print }
    infn && /^\}/ && index($0, fn "()") != 1 { exit }
    infn && index($0, fn "() {") == 1 && /\}[[:space:]]*$/ { exit }
  ' "$here/bin/delegate"
}
{
  cat <<'STUBS'
die()  { echo "delegate: $*" >&2; exit 1; }
warn() { echo "delegate: $*" >&2; }
note() { echo "delegate: $*" >&2; }
phase() { :; }
aborted() { return 1; }
untrusted() { return 1; }
snapshot() { echo deadbeef; }
wgit() { case "$1" in
           diff) echo ' 1 file changed' ;;
           rev-parse) echo deadbeef ;;
         esac; return 0; }
check_gitlink() { return 0; }
grant_unlock() { return 0; }
grants_py() { echo ""; }
grants_file() { echo /dev/null; }
reap_leftovers() { return 0; }
ledger_record_round() { return 0; }
progress_stop() { return 0; }
# the worker sandbox boundary: run the verify command for real (as the native runner
# would) and count the calls through the file the fixture scripts read
run_limited() { local n=$(( $(cat "$DELEGATE_T/runs") + 1 )); echo "$n" > "$DELEGATE_T/runs"; shift 4; "$@"; }
STUBS
  for f in flakes_py verify_shown verify_wrapped verify_keep_note finalize_round; do extract "$f"; done
} > "$T/driver.sh"
grep -q 'finalize_round() {' "$T/driver.sh" || { echo "FAIL extraction found no finalize_round"; exit 1; }
grep -q 'flakes_py() {' "$T/driver.sh" || { echo "FAIL extraction found no flakes_py"; exit 1; }

task() { # ID WORKER-STATUS — a round fixture: meta.env, events, run counter
  local id=$1 wstat=$2
  TD=$S/$id; export TD
  mkdir -p "$TD/rounds/1"
  { printf 'ID=%q\nSLUG=%q\nREPO=%q\nWORKTREE=%q\nBRANCH=%q\n' "$id" "$id" "$T/repo-$id" "$T/wt-$id" "delegate/$id"
    printf 'BASE_REF=%q\nBASE_SHA=%q\nGIT_COMMON=\nMODEL=%q\nVERIFY=\n' main abc "$id-model"
    printf 'SERVICE=\nCOPIED=\nSESSION=\nCREATED=x\nWT_GITDIR=\n'
    printf 'READS=\nGITHUB=0\nEGRESS=filtered\nHERE=1\nRUNNER=native\nRAW=0\n'
    printf 'GRANTS=\nALLOW=\n'; } > "$TD/meta.env"
  printf '{"type":"text","timestamp":9000,"part":{"type":"text","text":"STATUS: %s\\n\\nthe work"}}\n' "$wstat" > "$TD/rounds/1/events.jsonl"
  : > "$TD/rounds/1/stderr.log"; echo 0 > "$T/runs"
}
verify_round() { # VERIFY-CMD — one finalize_round for the task just built, retries from env
  ( export DELEGATE_T=$T TASK_DIR=$TD ID="${TD##*/}" REPO="$T/repo-${TD##*/}" VERIFY_RETRIES="${VERIFY_RETRIES:-1}"
    . "$T/driver.sh" >/dev/null 2>&1
    set -a; . "$TD/meta.env"; set +a   # what load_task does for a live round
    finalize_round 1 "$TD/rounds/1" "$1" 0 1 2 >>"${VR_NOTE:-$T/note.log}" 2>&1 )
}

# ---------------------------------------------------- flaky: red, green, done ----
task v-flake done
cat > "$T/flaky.sh" <<'FIX'
#!/bin/bash
echo "attempt $(cat "$DELEGATE_T/runs") running"
echo "--- FAIL: TestFlaky (0.01s)"
[ "$(cat "$DELEGATE_T/runs")" -ge 2 ]
FIX
verify_round "bash $T/flaky.sh"; rc=$?
J=$TD/rounds/1/report.json
check "a flaky verify: the round closes done (finalize rc $rc)" '[ "$rc" = 0 ] && grep -q "\"status\": \"done\"" "$J"'
check "…report.json carries verify_flaky with the failed-run count and the first rc" \
  'python3 -c "import json,sys;r=json.load(open(sys.argv[1]));assert r[\"status\"]==\"done\" and r[\"verify_rc\"]==0 and r[\"verify_flaky\"]=={\"failed_runs\":1,\"first_rc\":1}" "$J"'
check "…the verify section says VERIFY FLAKE with the run numbers" \
  'grep -q "VERIFY FLAKE: run 1 failed (exit 1), run 2 passed" "$TD/rounds/1/report.md"'
check "…the failed run is kept beside the final log" \
  'grep -q "attempt 1" "$TD/rounds/1/verify-1.log" && grep -q "attempt 2" "$TD/rounds/1/verify.log"'
check "…exactly two verify runs happened" '[ "$(cat $T/runs)" = 2 ]'
check "…one flake line reached the ledger" '[ "$(grep -c "" "$FL")" = 1 ]'
check "…the line has the contract keys (at repo task round verify_sha256 failed_rc tail)" \
  'python3 -c "import json,sys;r=json.load(open(sys.argv[1]));assert set(r)=={\"at\",\"repo\",\"task\",\"round\",\"verify_sha256\",\"failed_rc\",\"tail\"};assert r[\"task\"]==\"v-flake\" and r[\"round\"]==1 and r[\"failed_rc\"]==1 and \"TestFlaky\" in r[\"tail\"]" "$FL"'
check "…the ledger file is 0600" '[ "$(stat -c %a "$FL")" = 600 ]'
check "…the round keeps the flake summary line" 'grep -q "TestFlaky" "$TD/rounds/1/flake.line"'

# ------------------------------------------------ all runs red: as plain failed ---
task v-always done
printf 'echo "boom $(cat \"$DELEGATE_T/runs\")"; exit 7\n' > "$T/always.sh"
verify_round "bash $T/always.sh"
check "an always-red verify: done-but-verify-failed, the old outcome" \
  'grep -q "\"status\": \"done-but-verify-failed\"" "$TD/rounds/1/report.json" && ! grep -q verify_flaky "$TD/rounds/1/report.json"'
check "…two runs, the first kept, verify.log the last run" \
  '[ "$(cat $T/runs)" = 2 ] && grep -q "boom 1" "$TD/rounds/1/verify-1.log" && grep -q "boom 2" "$TD/rounds/1/verify.log"'
check "…no flake ledger line for an all-fail round, and no VERIFY FLAKE report line" \
  '[ "$(grep -c "" "$FL")" = 1 ] && ! grep -q "VERIFY FLAKE" "$TD/rounds/1/report.md"'

# ----------------------------------------------------- retries: 0, and partial ---
task v-zero done
VERIFY_RETRIES=0 verify_round "bash $T/always.sh"
check "--verify-retries 0: one run, no re-run, the old behaviour" \
  '[ "$(cat $T/runs)" = 1 ] && [ ! -f "$TD/rounds/1/verify-1.log" ]'
task v-partial partial
VERIFY_RETRIES=3 verify_round "bash $T/always.sh"
check "a worker that said partial is never re-run, whatever the budget" \
  '[ "$(cat $T/runs)" = 1 ] && grep -q "\"status\": \"partial\"" "$TD/rounds/1/report.json"'

# ---------------------------------------------- retries: 2 buys three real runs --
task v-two done
printf 'echo "take $(cat \"$DELEGATE_T/runs\")"; [ "$(cat \"$DELEGATE_T/runs\")" -ge 3 ]\n' > "$T/twice.sh"
VERIFY_RETRIES=2 verify_round "bash $T/twice.sh"
check "retries=2: red, red, green is still done, both failed runs kept" \
  'grep -q "\"status\": \"done\"" "$TD/rounds/1/report.json" && grep -q "take 1" "$TD/rounds/1/verify-1.log" && grep -q "take 2" "$TD/rounds/1/verify-2.log" && grep -q verify_flaky "$TD/rounds/1/report.json"'

# ------------------------------------------------------------- flakes.py modes ---
python3 "$here/lib/flakes.py" plan-retries --plan-json '{"verify_retries":3,"steps":[{"name":"a"}]}' > "$T/pr1"
check "plan-retries: the plan key, printed bare" '[ "$(cat $T/pr1)" = 3 ]'
python3 "$here/lib/flakes.py" plan-retries --plan-json '{"verify_retries":3,"steps":[{"name":"a"},{"name":"b","verify_retries":0}]}' > "$T/pr2"
check "plan-retries: a step key overrides the plan key" '[ "$(cat $T/pr2)" = 0 ]'
python3 "$here/lib/flakes.py" plan-retries --plan-json '{"steps":[{"name":"a"}]}' > "$T/pr3"
check "plan-retries: no key prints nothing (the caller falls back)" '[ ! -s "$T/pr3" ]'
check "chain: the plan/step key reaches run and continue" \
  'grep -q "step_verify_retries(plan, s)" "$here/lib/chain.py" && grep -q -- "\"--verify-retries\"" "$here/lib/chain.py"'

# ------------------------------------------------------ delegate flakes output ---
python3 "$here/lib/flakes.py" append --file "$FL" --repo /x/beta --task b-1 --round 4 \
  --verify "make test" --rc 2 --log /dev/null >/dev/null
printf 'panic: test timed out after 10 minutes\n' > "$T/tail.log"
task v-flake2 done
python3 "$here/lib/flakes.py" append --file "$FL" --repo "$T/repo-v-flake2" --task v-flake2 --round 9 \
  --verify "make test" --rc 2 --log "$T/tail.log" >/dev/null
out=$(python3 "$here/lib/flakes.py" list --file "$FL")
check "list: newest first, grouped by repo with counts" \
  'printf "%s\n" "$out" | grep -q "v-flake2 round 9" && printf "%s\n" "$out" | grep -qE "repo-v-flake2  \(1 flake\)|beta  \(1 flake\)"'
check "…a row names the first failing line of its tail" 'printf "%s\n" "$out" | grep -q "panic: test timed out"'
check "--repo filters to that repo" \
  'python3 "$here/lib/flakes.py" list --file "$FL" --repo "$T/repo-v-flake2" | grep -q v-flake2 && ! python3 "$here/lib/flakes.py" list --file "$FL" --repo "$T/repo-v-flake2" | grep -q beta'
check "--json prints the rows, newest first, tail intact" \
  'python3 "$here/lib/flakes.py" list --file "$FL" --json > "$T/l.json" && python3 -c "import json,sys;r=json.load(open(sys.argv[1]));assert r[0][\"task\"]==\"v-flake2\" and r[0][\"round\"]==9 and len(r)==4 and [x[\"task\"] for x in r]==[\"v-flake2\",\"b-1\",\"v-two\",\"v-flake\"]" "$T/l.json"'
check "the ledger stayed 0600 across appends" '[ "$(stat -c %a "$FL")" = 600 ]'

exit $fail

