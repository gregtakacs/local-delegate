#!/bin/bash
# Exercises lib/chain.py's control flow against a fake `delegate` that plays back scripted
# round statuses: accept on done, retry in-session on verify failure, stop on blocked, stop
# after the retry budget, and resume from the failed step.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DELEGATE_STATE=$T/state DELEGATE_CHAIN_BIN=$T/fake-delegate
mkdir -p $DELEGATE_STATE $T/repo/docs && git -C $T/repo init -q -b main && touch $T/repo/docs/a.md $T/repo/docs/b.md && git -C $T/repo add -A && git -C $T/repo -c user.name=t -c user.email=t@t commit -qm i
cat > $T/fake-delegate <<'F'
#!/bin/bash
# fake: run SPEC --repo R --name N ... | continue ID FILE | finish ID ; statuses from $SCRIPT/<name> (one per round)
cmd=$1; shift
if [ "$cmd" = run ]; then
  while [ $# -gt 0 ]; do case "$1" in --name) name=$2; shift 2;; --base) echo "$2" >> "$DELEGATE_STATE/bases"; shift 2;; --here) touch "$DELEGATE_STATE/saw-here"; shift;; *) shift;; esac; done
  id="repo-$name"
  [ -n "${EDIT:-}" ] && echo "$name" >> "$EDIT"     # in-place tests: the "worker" edits the checkout
elif [ "$cmd" = continue ]; then id=$1; name=${id#repo-}; cp "$2" "$DELEGATE_STATE/last-retry-$name"
  [ "${3:-}" = --verify ] && printf '%s\n' "$4" >> "$DELEGATE_STATE/retry-verify-$name"
elif [ "$cmd" = finish ]; then id=$1; name=${id#repo-}; echo "$id" >> "$DELEGATE_STATE/finished"
  # plays `delegate finish`: the round dir already exists; write the report the dead harness owes
  d=$DELEGATE_STATE/$id/rounds; n=$(ls $d 2>/dev/null | sort -n | tail -1); [ -n "$n" ] || exit 0
  st=$(sed -n "${n}p" "$SCRIPT/$name"); st=${st:-done}
  [ "$st" = no-report ] && exit 0
  printf '{"status":"%s","verify_rc":%s}\n' "$st" "$([ "$st" = done-but-verify-failed ] && echo 1 || echo 0)" > $d/$n/report.json
  exit 0
else exit 0; fi
d=$DELEGATE_STATE/$id/rounds; mkdir -p $d; n=$(( $(ls $d | wc -l) + 1 )); mkdir $d/$n
st=$(sed -n "${n}p" "$SCRIPT/$name"); st=${st:-done}
printf '{"status":"%s","verify_rc":%s}\n' "$st" "$([ "$st" = done-but-verify-failed ] && echo 1 || echo 0)" > $d/$n/report.json
echo "boom: assertion failed in test_x" > $d/$n/verify.log
F
chmod +x $T/fake-delegate
plan() { printf '{"name":"t","repo":"%s","base":"main","retries":%s,"steps":[{"name":"a","spec":"docs/a.md","verify":"true"},{"name":"b","spec":"docs/b.md","verify":"true"}]}' "$T/repo" "$1" > $T/plan.json; }
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
export SCRIPT=$T/script; mkdir -p $SCRIPT

# 1. happy path: both done first round, step b starts from step a's branch
printf 'done\n' > $SCRIPT/a; printf 'done\n' > $SCRIPT/b; plan 2
python3 $here/lib/chain.py $T/plan.json >/dev/null 2>&1; rc=$?
check "happy path exits 0" '[ $rc = 0 ]'
check "step b based on delegate/a" '[ "$(sed -n 2p $DELEGATE_STATE/bases)" = delegate/a ]'

# 2. verify failure is retried in-session with the verify tail, then accepted
rm -rf $DELEGATE_STATE; mkdir -p $DELEGATE_STATE
printf 'done-but-verify-failed\ndone\n' > $SCRIPT/a; printf 'done\n' > $SCRIPT/b
python3 $here/lib/chain.py $T/plan.json >/dev/null 2>&1; rc=$?
check "verify failure retried then accepted" '[ $rc = 0 ] && [ -d $DELEGATE_STATE/repo-a/rounds/2 ]'
check "retry message carries the verify output" 'grep -q "boom: assertion failed" $DELEGATE_STATE/last-retry-a'

# 3. blocked stops at once (no retry), exit 3, step b never starts
rm -rf $DELEGATE_STATE; mkdir -p $DELEGATE_STATE
printf 'blocked\n' > $SCRIPT/a
python3 $here/lib/chain.py $T/plan.json >/dev/null 2>&1; rc=$?
check "blocked stops with exit 3" '[ $rc = 3 ] && [ ! -d $DELEGATE_STATE/repo-a/rounds/2 ] && [ ! -d $DELEGATE_STATE/repo-b ]'

# 4. still failing after the retry budget: stop with exit 3 after 1 + retries rounds
rm -rf $DELEGATE_STATE; mkdir -p $DELEGATE_STATE
printf 'partial\npartial\npartial\npartial\n' > $SCRIPT/a; plan 2
python3 $here/lib/chain.py $T/plan.json >/dev/null 2>&1; rc=$?
check "gives up after 1+2 rounds" '[ $rc = 3 ] && [ -d $DELEGATE_STATE/repo-a/rounds/3 ] && [ ! -d $DELEGATE_STATE/repo-a/rounds/4 ]'

# 5. resume: after the orchestrator fixes things, a re-run continues the failed step, keeps done ones
printf 'partial\npartial\npartial\ndone\n' > $SCRIPT/a; printf 'done\n' > $SCRIPT/b
python3 $here/lib/chain.py $T/plan.json >/dev/null 2>&1; rc=$?
check "resume finishes the chain" '[ $rc = 0 ] && [ -d $DELEGATE_STATE/repo-b/rounds/1 ]'
python3 $here/lib/chain.py $T/plan.json >/dev/null 2>&1; rc=$?
check "re-run of a finished chain is a no-op" '[ $rc = 0 ] && [ ! -d $DELEGATE_STATE/repo-b/rounds/2 ]'
# 6. in place: refuses a dirty checkout; otherwise --here, no --base, one commit per accepted step
rm -rf $DELEGATE_STATE; mkdir -p $DELEGATE_STATE
printf '{"name":"h","repo":"%s","here":true,"retries":1,"steps":[{"name":"a","spec":"docs/a.md","verify":"true"},{"name":"b","spec":"docs/b.md","verify":"true"}]}' "$T/repo" > $T/hplan.json
printf 'done\n' > $SCRIPT/a; printf 'done-but-verify-failed\ndone\n' > $SCRIPT/b
echo dirty > $T/repo/stray
python3 $here/lib/chain.py $T/hplan.json >/dev/null 2>&1; rc=$?
check "in place refuses a dirty checkout" '[ $rc = 2 ] && [ ! -d $DELEGATE_STATE/repo-a ]'
rm $T/repo/stray; head0=$(git -C $T/repo rev-parse HEAD)
EDIT=$T/repo/work.txt GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  python3 $here/lib/chain.py $T/hplan.json >/dev/null 2>&1; rc=$?
check "in place passes --here and never --base" '[ $rc = 0 ] && [ -f $DELEGATE_STATE/saw-here ] && [ ! -f $DELEGATE_STATE/bases ]'
check "in place commits one per accepted step" '[ "$(git -C $T/repo log --format=%s $head0..HEAD | tr "\n" ,)" = "h: b,h: a," ] && [ -z "$(git -C $T/repo status --porcelain)" ]'

# 7. a retry runs the plan's verify as it is now, not the one the task started with (an edited plan takes effect)
rm -rf $DELEGATE_STATE; mkdir -p $DELEGATE_STATE
printf 'done-but-verify-failed\ndone-but-verify-failed\ndone\n' > $SCRIPT/a; printf 'done\n' > $SCRIPT/b
printf '{"name":"t","repo":"%s","base":"main","retries":1,"steps":[{"name":"a","spec":"docs/a.md","verify":"old-check"},{"name":"b","spec":"docs/b.md","verify":"true"}]}' "$T/repo" > $T/plan.json
python3 $here/lib/chain.py $T/plan.json >/dev/null 2>&1
sed -i 's/old-check/new-check/' $T/plan.json
python3 $here/lib/chain.py $T/plan.json >/dev/null 2>&1; rc=$?
check "an edited plan's verify reaches the retry" '[ "$(head -1 $DELEGATE_STATE/retry-verify-a)" = old-check ] && [ "$(tail -1 $DELEGATE_STATE/retry-verify-a)" = new-check ] && [ $rc = 0 ]'

# 8. a step whose last round was interrupted (its harness died before writing a report): the chain
#    finishes that round rather than abandoning it, and goes on with the chain
rm -rf $DELEGATE_STATE; mkdir -p $DELEGATE_STATE
printf 'done\ndone\n' > $SCRIPT/a; printf 'done\n' > $SCRIPT/b; plan 2
mkdir -p $DELEGATE_STATE/repo-a/rounds/2          # round 1 already accepted; round 2 has no report
python3 $here/lib/chain.py $T/plan.json > $T/o8 2>&1; rc=$?
check "an interrupted step is finished, not skipped" '[ $rc = 0 ] && grep -q "was interrupted" $T/o8'
check "finish was the command run"                   '[ "$(cat $DELEGATE_STATE/finished)" = repo-a ] && [ -f $DELEGATE_STATE/repo-a/rounds/2/report.json ]'
check "it did not start another round of that step"  '[ ! -d $DELEGATE_STATE/repo-a/rounds/3 ] && [ -d $DELEGATE_STATE/repo-b/rounds/1 ]'

# 9. `delegate finish` failing (still no report) stops the chain with the command to run by hand
rm -rf $DELEGATE_STATE; mkdir -p $DELEGATE_STATE
printf 'done\nno-report\n' > $SCRIPT/a; printf 'done\n' > $SCRIPT/b
mkdir -p $DELEGATE_STATE/repo-a/rounds/2
python3 $here/lib/chain.py $T/plan.json --status > $T/s9 2>&1
check "chain --status calls the round interrupted" 'grep -q interrupted $T/s9'
python3 $here/lib/chain.py $T/plan.json > $T/o9 2>&1; rc=$?
check "a round that cannot be finished stops the chain" '[ $rc = 2 ] && grep -q "no report" $T/o9 && grep -q "delegate finish repo-a" $T/o9'
check "and the next step never starts"                  '[ ! -d $DELEGATE_STATE/repo-b ]'

# 10. --wait: returns 0 on a finished chain, 3 on a blocked one, and holds while the runner lives
rm -rf $DELEGATE_STATE; mkdir -p $DELEGATE_STATE
printf 'done\n' > $SCRIPT/a; printf 'done\n' > $SCRIPT/b; plan 2
python3 $here/lib/chain.py $T/plan.json >/dev/null 2>&1
python3 $here/lib/chain.py $T/plan.json --wait --interval 0.1 > $T/w10 2>&1; rc=$?
check "wait on a finished chain exits 0 with the status" '[ $rc = 0 ] && grep -q "chain t" $T/w10'
check "the run recorded its pid for wait"               'grep -q pid $DELEGATE_STATE/chains/t.json'
rm -rf $DELEGATE_STATE; mkdir -p $DELEGATE_STATE
printf 'blocked\n' > $SCRIPT/a
python3 $here/lib/chain.py $T/plan.json >/dev/null 2>&1
python3 $here/lib/chain.py $T/plan.json --wait --interval 0.1 >/dev/null 2>&1; rc=$?
check "wait on a blocked chain exits 3" '[ $rc = 3 ]'
# a live runner (a process whose command line names chain.py) holds wait until its timeout
cp $here/lib/chain.py $T/chain.py; ( exec -a python3 python3 -c 'import time; time.sleep(30)' $T/chain.py ) & live=$!
python3 - "$DELEGATE_STATE/chains/t.json" "$live" <<'P'
import json, sys
p, pid = sys.argv[1], int(sys.argv[2]); d = json.load(open(p)); d["pid"] = pid; json.dump(d, open(p, "w"))
P
python3 $here/lib/chain.py $T/plan.json --wait --interval 0.1 --timeout 0.5 >/dev/null 2>&1; rc=$?
check "a live runner holds wait until its timeout (124)" '[ $rc = 124 ]'
kill $live 2>/dev/null; wait $live 2>/dev/null
python3 $here/lib/chain.py $T/plan.json --wait --interval 0.1 --timeout 5 >/dev/null 2>&1; rc=$?
check "once the runner is gone, wait returns the chain's state" '[ $rc = 3 ]'
# a pid reused by an unrelated process is not a runner
sleep 30 & other=$!
python3 - "$DELEGATE_STATE/chains/t.json" "$other" <<'P'
import json, sys
p, pid = sys.argv[1], int(sys.argv[2]); d = json.load(open(p)); d["pid"] = pid; json.dump(d, open(p, "w"))
P
python3 $here/lib/chain.py $T/plan.json --wait --interval 0.1 --timeout 2 >/dev/null 2>&1; rc=$?
check "a reused pid (not chain.py) does not hold wait" '[ $rc = 3 ]'
kill $other 2>/dev/null; wait $other 2>/dev/null

exit $fail
