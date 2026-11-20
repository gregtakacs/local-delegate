#!/bin/bash
# spec: new-tests-check. A round that ADDED OR CHANGED a test file its harness verify never ran
# gets a warning line, nowhere else: report.json's "new_or_changed_tests_unrun", the same line
# ("TESTS NOT IN VERIFY (added or changed): …") in report.md's verify section — so in the
# round's printed summary — and the chain's line for the step. lib/newtests.py answers the list:
# covered by the path, the dotted module, the file name, a path or dotted package prefix token,
# a Go package dir or `./...` run from an ancestor, or a bare runner (one invoked with no
# file/module argument at all); non-test changed files never appear; the status and the exit
# code never move. No docker, no model, no network: the rules run through the module CLI; the
# report through report.py directly and through one fake real round (the test_verify_retry
# pattern: finalize_round extracted, git and report.py real); the chain print through a fake
# delegate (the test_step_gate pattern).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
export DELEGATE_CONFIG=$T/none.env DELEGATE_STATE=$T/state DELEGATE_RUNNER=native DELEGATE_HOME=$here
export DELEGATE_VERIFY_TIMEOUT=60
mkdir -p $DELEGATE_STATE

# ---------------------------------------------------------------- 1. the rules -------------
# uncovered(paths, cmd, log): the module CLI is the test seam; the answer lands in $T/unc.out.
# A path is one the round added OR changed — the rules do not care which, only its shape and
# whether the verify reached it.
unc() { # unc <verify-cmd> <log (a $'..' string, "-" for none)> <changed paths...>
  local cmd=$1 log=$2 logf=/dev/null
  if [ "$log" != "-" ]; then printf '%s\n' "$log" > "$T/vlog"; logf="$T/vlog"; fi
  shift 2
  : > "$T/added"; for p in "$@"; do printf '%s\n' "$p" >> "$T/added"; done
  python3 "$here/lib/newtests.py" uncovered --added-or-changed "$T/added" --verify-cmd "$cmd" --verify-log "$logf" > "$T/unc.out"
}
cov() { local p=$2; unc "$1" - "$p"; check "covered: $p by [$1]" '[ ! -s "$T/unc.out" ]'; }
unr() { local p=$2; unc "$1" - "$p"; check "uncovered: $p by [$1]" "[ \"\$(cat '$T/unc.out')\" = '$p' ]"; }

cov "pytest hub/tests/test_wv43_page.py" hub/tests/test_wv43_page.py     # the repo path
cov "pytest test_wv43_page.py" hub/tests/test_wv43_page.py               # the file name
cov "python3 -m unittest hub.tests.test_wv43_page" hub/tests/test_wv43_page.py   # dotted module
cov "pytest hub/tests" hub/tests/test_wv43_page.py                       # path prefix token
cov "pytest hub/" hub/tests/test_wv43_page.py                             # dir token, trailing /
cov "pytest hub.tests" hub/tests/test_wv43_page.py                        # dotted package prefix
cov "pytest ." hub/tests/test_wv43_page.py                                # (dot: the run dir)
cov "cd app && go test ./..." app/pkg/x_test.go                           # Go ./... from an ancestor
cov "go test ./..." app/pkg/x_test.go                                     # Go ./... from the root
cov "go test ./app/pkg/" app/pkg/x_test.go                                # Go package dir
cov "npm test" ui/button.test.ts
cov "pnpm test --silent" ui/button.test.mjs
cov "yarn test" ui/button.spec.ts
cov "pytest -q" tests/test_gate.sh                                        # bare pytest runs everything
cov "python3 tools/run_tests.py" tests/test_gate.sh                       # bare script runner
cov "python3 -I tools/run_tests.py" tests/test_gate.sh                    # flags before the script
cov "bash -c 'pytest -q'" tests/test_gate.sh                              # runner inside quotes
cov "make test" tests/test_gate.sh
cov "cargo test -q" rust/crate/tests/x_test.rs                            # (not a shape: ignored anyway)
cov "go test ./..." cmd/srv/x_test.go
unr "pytest hub/tests/test_old.py" hub/tests/test_wv43_page.py            # the measured miss (added)
unr "pytest hub/tests/test_other.py" hub/tests/test_c1a1_browser.py        # the second shape (changed)
unr "cd app/cmd/api && go test ./..." app/pkg/x_test.go                   # ./... from a SIBLING
unr "pytest tests/test_other.sh" tests/test_gate.sh                       # a different shell test
unr "python3 tools/run_tests.py tests/test_gate.sh" docs/x_test.py        # scoped script run (token `tests`)
unr "pytest ui/button.test.js" ui/other.spec.ts
unr "bash scripts/run_all.sh" tests/test_gate.sh                          # unknown script: no free pass
unr "make check-sandbox" tests/test_gate.sh                               # make target: not a runner word
unc "pytest hub/tests/test_old.py" $'collected 1 item\nhub/tests/test_wv43_page.py PASSED' hub/tests/test_wv43_page.py
check "the log covers too" '[ ! -s "$T/unc.out" ]'
unc "pytest hub/tests/test_old.py" $'collected 1 item\n1 passed in 0.02s' hub/tests/test_new.py
check "log and cmd both silent: uncovered" '[ "$(cat "$T/unc.out")" = hub/tests/test_new.py ]'

# non-test added files are never listed, whatever the verify ran
unc "pytest tests/test_other.sh" - README.md src/main.py scripts/test_pkg.sh hub/tests/conftest.py ui/button.test.tsx docs/test_plan.md
check "non-test added files ignored" '[ ! -s "$T/unc.out" ]'
check "tests/test_*.sh is a test shape" '[ "$(unc "pytest test_other.sh" - tests/test_gate.sh; cat "$T/unc.out")" = tests/test_gate.sh ]'
check "test/ counts as a test dir" '[ "$(unc "pytest test_other.sh" - test/test_api.sh; cat "$T/unc.out")" = test/test_api.sh ]'
unc "pytest hub/tests/test_old.py" $'collected 1 item\n.                    [100%]\n1 passed in 0.02s' hub/tests/test_new.py
check "log dots are not a run receipt" '[ "$(cat "$T/unc.out")" = hub/tests/test_new.py ]'

# ------------------------------------------------- 2. the report: key and line -------------
# report.py stands on its own: one fake round's events, verify cmd/log and changed-path list.
run_report() { # run_report <verify-cmd> <changed path>... — sets RC; writes $T/r.md/.json/.out
  local cmd=$1; shift
  printf '%s\n' "$@" > "$T/changed"
  local nl=$'\n' hdr=${cmd#*'# delegate chain: end of the scope gate'}   # the real verify.log header is stripped
  if [ "$hdr" != "$cmd" ]; then hdr="[scope gate] ${hdr#$nl}"; fi
  printf '$ %s\nRESULT ok\n' "$hdr" > "$T/v.log"
  printf '{"type":"text","timestamp":9000,"part":{"type":"text","text":"STATUS: done\\n\\nthe work"}}\n' > "$T/ev.jsonl"
  : > "$T/err"
  python3 "$here/lib/report.py" report --id t-nt --round 1 --events "$T/ev.jsonl" --stderr "$T/err" \
    --exit 0 --duration 5 --model m --worktree /wt --branch b --base main --base-sha abc \
    --commit deadbeef --diffstat /dev/null --evidence "$T/ev" --verify-cmd "$cmd" --verify-rc 0 \
    --verify-log "$T/v.log" --added-or-changed "$T/changed" --out-md "$T/r.md" --out-json "$T/r.json" \
    > "$T/r.out" 2>&1
  RC=$?
}
LINE='TESTS NOT IN VERIFY (added or changed): hub/tests/test_new.py — the verify never ran them'
run_report "pytest hub/tests/test_old.py" hub/tests/test_new.py
check "the warning never changes the exit code (report.py still exits $RC)" '[ "$RC" = 0 ]'
check "report.json gains new_or_changed_tests_unrun" 'grep -q "\"new_or_changed_tests_unrun\"" "$T/r.json" && grep -q "\"hub/tests/test_new.py\"" "$T/r.json"'
check "report.md verify section gains the line" 'grep -qxF "$LINE" "$T/r.md"'
check "the printed summary carries the line" 'grep -qxF "$LINE" "$T/r.out"'
check "the line sits in the verify section, under its heading" \
  'awk "/^## Verify/{v=1} v && /^TESTS NOT IN VERIFY/{f=1} END{exit !f}" "$T/r.md"'
check "status stays done despite the warning" 'grep -q "\"status\": \"done\"" "$T/r.json" && grep -q "STATUS (harness): \*\*done\*\*" "$T/r.md"'
# the second miss shape: a CHANGED test module the verify never ran (a new method inside it)
LINE2='TESTS NOT IN VERIFY (added or changed): hub/tests/test_c1a1_browser.py — the verify never ran them'
run_report "pytest hub/tests/test_other.py" hub/tests/test_c1a1_browser.py
check "a changed test module the verify skipped is listed" 'grep -q "\"new_or_changed_tests_unrun\"" "$T/r.json"'
check "…and its line reads the same" 'grep -qxF "$LINE2" "$T/r.md"'
run_report "pytest -q hub/tests/test_c1a1_browser.py" hub/tests/test_c1a1_browser.py
check "a changed module the verify DID run: no key, no line" \
  '! grep -q new_or_changed "$T/r.json" && ! grep -q "TESTS NOT IN VERIFY" "$T/r.md"'
run_report "pytest hub/tests" hub/tests/test_new.py
check "a covering verify: no key in report.json" '! grep -q new_or_changed "$T/r.json"'
check "a covering verify: no line in report.md" '! grep -q "TESTS NOT IN VERIFY" "$T/r.md"'
run_report "pytest hub/tests/test_old.py" docs/plan.md
check "a non-test changed file: no key, no line" '! grep -q new_or_changed "$T/r.json" && ! grep -q "TESTS NOT IN VERIFY" "$T/r.md"'
# a chain step's verify: the scope gate carries the step's paths — listing them is not running them
SGATE_FAKE=$(printf '# delegate chain: this step scope gate\n__dsc_re='\''^(hub/tests/test_new.py|hub/tests/test_old.py)$'\''\n# delegate chain: end of the scope gate\npytest hub/tests/test_old.py')
run_report "$SGATE_FAKE" hub/tests/test_new.py
check "a scope gate naming the file does not fake coverage" 'grep -q new_or_changed "$T/r.json"'
SGATE_BARE=$(printf '# delegate chain: this step scope gate\n__dsc_re='\''^(hub/tests/test_new.py)$'\''\n# delegate chain: end of the scope gate\npytest -q')
run_report "$SGATE_BARE" hub/tests/test_new.py
check "a bare runner behind the gate covers (marker stripped)" '! grep -q new_or_changed "$T/r.json"'

# ------------------------------------------- 3. the round end: a fake real round ------------
# finalize_round extracted (the test_verify_retry pattern): the added list, the verify, the
# commit and report.py all run for real; only the worker sandbox and the side ledgers are stubs.
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
wgit() { git -C "$DELEGATE_WT" "$@"; }
check_gitlink() { return 0; }
grant_unlock() { return 0; }
grants_py() { echo ""; }
grants_file() { echo /dev/null; }
reap_leftovers() { return 0; }
ledger_record_round() { return 0; }
progress_stop() { return 0; }
run_limited() { shift 4; "$@"; }
STUBS
  for f in flakes_py verify_shown verify_wrapped verify_keep_note finalize_round; do extract "$f"; done
} > "$T/driver.sh"
grep -q 'finalize_round() {' "$T/driver.sh" || { echo "FAIL extraction found no finalize_round"; exit 1; }

R=$T/repo; mkdir -p $R/hub/tests; export DELEGATE_WT=$R
git -C $R init -q -b main
printf 'base\n' > $R/README.md
printf 'def test_old_a(): assert True\n' > $R/hub/tests/test_old.py
git -C $R add -A; git -C $R -c user.name=t -c user.email=t commit -qm initial
BASE_SHA=$(git -C $R rev-parse HEAD)
# what the round does: ADDS one test file and CHANGES another (the two measured miss shapes)
printf 'def test_page(): assert True\n' > $R/hub/tests/test_new.py
printf 'def test_old_a(): assert True\ndef test_old_b(): assert True\n' > $R/hub/tests/test_old.py
git -C $R add -A; git -C $R -c user.name=t -c user.email=t commit -qm round
TD=$T/state/t-round; mkdir -p "$TD/rounds/1"
{ printf 'ID=%q\nSLUG=%q\nREPO=%q\nWORKTREE=%q\nBRANCH=%q\n' t-round t-round "$R" "$R" delegate/t-round
  printf 'BASE_REF=%q\nBASE_SHA=%q\nGIT_COMMON=\nMODEL=%q\nVERIFY=\n' main "$BASE_SHA" m
  printf 'SERVICE=\nCOPIED=\nSESSION=\nCREATED=x\nWT_GITDIR=\n'
  printf 'READS=\nGITHUB=0\nEGRESS=filtered\nHERE=0\nRUNNER=native\nRAW=0\n'
  printf 'GRANTS=\nALLOW=\n'; } > "$TD/meta.env"
printf '{"type":"text","timestamp":9000,"part":{"type":"text","text":"STATUS: done\\n\\nthe work"}}\n' > "$TD/rounds/1/events.jsonl"
: > "$TD/rounds/1/stderr.log"
round_over() { # round_over <verify-cmd> — one finalize_round over the fixture repo
  ( cd $R && export TASK_DIR=$TD
    . "$T/driver.sh" >/dev/null 2>&1
    set -a; . "$TD/meta.env"; set +a
    finalize_round 1 "$TD/rounds/1" "$1" 0 1 2 > "$T/finalize.out" 2>&1 )
  FR=$?
}
LINE3='TESTS NOT IN VERIFY (added or changed): hub/tests/test_new.py, hub/tests/test_old.py — the verify never ran them'
round_over "test -f README.md && echo RESULT ok"          # touches neither test file
check "the round ends 0 with the warning present" '[ "$FR" = 0 ]'
check "the round records its added AND changed paths" \
  'grep -qx hub/tests/test_new.py "$TD/rounds/1/added_or_changed" && grep -qx hub/tests/test_old.py "$TD/rounds/1/added_or_changed"'
check "a file the round did not touch is not listed" '! grep -qx README.md "$TD/rounds/1/added_or_changed"'
check "the live report.json carries new_or_changed_tests_unrun" \
  'grep -q "\"new_or_changed_tests_unrun\"" "$TD/rounds/1/report.json"'
check "the live report.md lists both shapes on one line" 'grep -qxF "$LINE3" "$TD/rounds/1/report.md"'
check "the line reaches the printed round summary" 'grep -qxF "$LINE3" "$T/finalize.out"'
check "the round's status stayed done" 'grep -q "\"status\": \"done\"" "$TD/rounds/1/report.json"'
round_over "pytest hub/tests/test_new.py hub/tests/test_old.py && echo RESULT ok"
check "a verify naming both modules: live report has no key" '! grep -q new_or_changed "$TD/rounds/1/report.json"'
check "…and no line" '! grep -q "TESTS NOT IN VERIFY" "$TD/rounds/1/report.md"'

# ------------------------------------------------------- 4. the chain prints the line -------
# The test_step_gate pattern: a fake delegate answers run/_round-diff and writes each step's
# report.json; lib/chain.py runs for real over it.
cat > $T/fake-delegate <<'F'
#!/bin/bash
cmd=$1; shift
case "$cmd" in
  run)
    name=""
    while [ $# -gt 0 ]; do case "$1" in --name) name=$2; shift 2;; *) shift;; esac; done
    d=$DELEGATE_STATE/repo-nt-$name/rounds/1; mkdir -p "$d"
    printf '{"status":"done","verify_rc":0,"new_or_changed_tests_unrun":["hub/tests/test_new.py"]}\n' > "$d/report.json" ;;
  _round-diff) exit 0 ;;
esac
exit 0
F
chmod +x $T/fake-delegate
R2=$T/repo-nt; mkdir -p $R2/docs/specs; git -C $R2 init -q -b main
printf '# nt step\n\n## Read first\n\n- read-only: `lib/newtests.py`\n' > $R2/docs/specs/s1.md
git -C $R2 add -A; git -C $R2 -c user.name=t -c user.email=t commit -qm i
printf '{"name":"nt","repo":"%s","base":"main","gate":"make check","steps":[{"name":"s1","spec":"docs/specs/s1.md","verify":"make check"}]}\n' "$R2" > $T/plan-nt.json
rm -rf $DELEGATE_STATE/repo-nt-s1 "$DELEGATE_STATE/chains"
DELEGATE_CHAIN_BIN=$T/fake-delegate python3 "$here/lib/chain.py" $T/plan-nt.json > $T/chain.out 2>&1
CRC=$?
check "the chain accepts the step (exit $CRC)" '[ "$CRC" = 0 ]'
check "the chain prints the step line for the accepted round" \
  'grep -qF "step 1/1 s1: TESTS NOT IN VERIFY (added or changed): hub/tests/test_new.py — the verify never ran them" $T/chain.out'
DELEGATE_CHAIN_BIN=$T/fake-delegate python3 "$here/lib/chain.py" $T/plan-nt.json > $T/chain2.out 2>&1
check "a resumed chain prints it on the already-done step too" \
  'grep -qF "already done, skipping" $T/chain2.out && grep -qF "TESTS NOT IN VERIFY (added or changed)" $T/chain2.out'
# the same step with no key in the report: no line anywhere
cat > $T/fake-delegate2 <<'F'
#!/bin/bash
case "$1" in
  run) d=$DELEGATE_STATE/repo-nt-s1/rounds/1; mkdir -p "$d"
       printf '{"status":"done","verify_rc":0}\n' > "$d/report.json" ;;
  _round-diff) exit 0 ;;
esac
exit 0
F
chmod +x $T/fake-delegate2
rm -rf $DELEGATE_STATE/repo-nt-s1 "$DELEGATE_STATE/chains"
DELEGATE_CHAIN_BIN=$T/fake-delegate2 python3 "$here/lib/chain.py" $T/plan-nt.json > $T/chain3.out 2>&1
check "a step without the key prints no line" '! grep -q "TESTS NOT IN VERIFY" $T/chain3.out'

echo
[ "$fail" = 0 ] && echo PASS || echo FAIL
exit $fail

