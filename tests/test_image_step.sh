#!/bin/bash
# Exercises lib/chain.py's image steps ("image": true): the two --check rules, the UNTRUSTED
# refusal, the build-and-re-verify contract (once per round, in both verdict directions), the
# pin the rebuild leaves on every later step, the image-refused stop, and the acceptance guard
# for a step without the key that touched .delegate/ anyway. The fake `delegate` scripts each
# command's answer from files under $DELEGATE_STATE.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DELEGATE_STATE=$T/state DELEGATE_CHAIN_BIN=$T/fake-delegate
mkdir -p $DELEGATE_STATE $T/repo/docs && git -C $T/repo init -q -b main && touch $T/repo/docs/a.md $T/repo/docs/b.md && git -C $T/repo add -A && git -C $T/repo -c user.name=t -c user.email=t commit -qm i
cat > $T/fake-delegate <<'F'
#!/bin/bash
# fake: run/continue script statuses from $SCRIPT/<name>; build/_layer-stamp/_image-name/
# _base-image/verify/_round-diff script their answers from $DELEGATE_STATE (see test file).
# run and continue fall through to writing the next round's report.
cmd=$1; shift
calls() { printf '%s %s\n' "$cmd" "$*" >> "$DELEGATE_STATE/calls"; }
envlog() { printf '%s\n' "${DELEGATE_IMAGE:-none}" >> "$DELEGATE_STATE/run-env"; }
if [ "$cmd" = run ]; then
  while [ $# -gt 0 ]; do case "$1" in --name) name=$2; shift 2;; --base) echo "$2" >> "$DELEGATE_STATE/bases"; shift 2;; *) shift;; esac; done
  id="repo-$name"; calls; envlog
elif [ "$cmd" = continue ]; then
  id=$1; name=${id#repo-}; cp "$2" "$DELEGATE_STATE/last-retry-$name"; calls "$id"; envlog
elif [ "$cmd" = build ]; then
  [ "$1" = --repo ] && calls --repo "$2"
  if [ "$(cat "$DELEGATE_STATE/build-rc" 2>/dev/null)" = 2 ]; then
    echo "delegate: pin-lint: line 4: RUN pip install rich: unpinned" >&2; exit 2
  fi
  echo "#9 [2/2] RUN apt-get install -y cmake"; echo "delegate: built delegate-worker-repo:local"
  exit "$(cat "$DELEGATE_STATE/build-rc" 2>/dev/null || echo 0)"
elif [ "$cmd" = verify ]; then
  id=$1; name=${id#repo-}; calls "$id"; envlog
  n=$(( $(cat "$DELEGATE_STATE/rvn-$name" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$DELEGATE_STATE/rvn-$name"
  rv=$(sed -n "${n}p" "$SCRIPTRV/$name" 2>/dev/null); rv=${rv:-0}
  [ "$rv" = 1 ] && echo "rebuild boom: cmake not in the new image" >&2
  exit "$rv"
elif [ "$cmd" = _layer-stamp ]; then
  calls "$1"; printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n'
elif [ "$cmd" = _image-name ]; then
  calls "$1"; echo "delegate-worker-$(basename "$1"):local"
elif [ "$cmd" = _base-image ]; then
  calls; echo delegate-worker:local
elif [ "$cmd" = _round-diff ]; then
  f=$DELEGATE_STATE/round-diff
  [ -f "$f" ] || exit 1        # no recorded commit: the best-effort answer
  calls "$1"; cat "$f"
else exit 0; fi
d=$DELEGATE_STATE/$id/rounds; mkdir -p $d; n=$(( $(ls $d | wc -l) + 1 )); mkdir $d/$n
st=$(sed -n "${n}p" "$SCRIPT/$name"); st=${st:-done}
printf '{"status":"%s","verify_rc":%s}\n' "$st" "$([ "$st" = done-but-verify-failed ] && echo 1 || echo 0)" > $d/$n/report.json
echo "boom: assertion failed in test_x" > $d/$n/verify.log
F
chmod +x $T/fake-delegate
export SCRIPT=$T/script SCRIPTRV=$T/rv; mkdir -p $SCRIPT $SCRIPTRV
# a: the step under test; b: an ordinary later step. $2 adds keys to a's step object.
plan() { printf '{"name":"%s","repo":"%s","base":"main","retries":%s,"steps":[{"name":"a","spec":"docs/a.md","verify":"true"%s},{"name":"b","spec":"docs/b.md","verify":"true"}]}' \
  "$1" "$T/repo" "${3:-2}" "$2" > $T/plan-$1.json; }
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
st(){ python3 -c "import json,sys; print(json.load(open('$DELEGATE_STATE/chains/$1.json'))$2)"; }

# 1. --check: "image": true without "hard": true is refused, naming the step
plan img-hard ',"image":true'
python3 $here/lib/chain.py $T/plan-img-hard.json --check >$T/out 2>&1; rc=$?
check "--check refuses image without hard" '[ $rc = 2 ] && grep -q "step a:.*\"hard\": true" $T/out'

# 2. --check: a scope reaching .delegate/ without the image key is refused, naming the step
plan img-scope ',"scope":[".delegate/","docs/"]'
python3 $here/lib/chain.py $T/plan-img-scope.json --check >$T/out 2>&1; rc=$?
check "--check refuses a .delegate/ scope without the image key" \
  '[ $rc = 2 ] && grep -q "step a:.*must carry" $T/out && grep -q "\"image\": true" $T/out'

# 3. --check: a legal image step passes and is marked
plan img-ok ',"image":true,"hard":true,"scope":[".delegate/","docs/"]'
python3 $here/lib/chain.py $T/plan-img-ok.json --check >$T/out 2>&1; rc=$?
check "--check passes a legal image step and marks it" '[ $rc = 0 ] && grep -q "\[image:" $T/out'

# 4. untrusted: a plan with an image step is refused at load, before anything else
DELEGATE_UNTRUSTED_REPO=1 python3 $here/lib/chain.py $T/plan-img-ok.json >$T/out 2>&1; rc=$?
check "untrusted refuses an image plan at load" \
  '[ $rc = 2 ] && grep -q "DELEGATE_UNTRUSTED_REPO=1.*builds the repository" $T/out && [ ! -d $DELEGATE_STATE/repo-a ]'

# 5. happy path: done round -> build, pin, re-verify in the new image -> accepted; b runs pinned
printf 'done\n' > $SCRIPT/a; printf 'done\n' > $SCRIPT/b
python3 $here/lib/chain.py $T/plan-img-ok.json >$T/out 2>&1; rc=$?
check "image step accepted after the rebuild" '[ $rc = 0 ] && [ -d $DELEGATE_STATE/repo-b/rounds/1 ]'
check "…build ran once, against the step's tree" \
  '[ "$(grep -c "build --repo $T/repo" $DELEGATE_STATE/calls)" = 1 ]'
check "…and the order was run, build, stamps, base, verify" \
  '[ "$(grep -E "^(run|build|_layer-stamp|_image-name|_base-image|verify)" $DELEGATE_STATE/calls | head -6 | cut -d" " -f1 | tr "\n" ,)" = "run,build,_layer-stamp,_image-name,_base-image,verify," ]'
check "…re-verify rc and pinlint are in the report" \
  'd=$DELEGATE_STATE/repo-a/rounds/1/report.json; grep -qF "\"status\": \"done\"" $d && grep -qF "\"pinlint\": \"clean\"" $d && grep -qF "\"reverify_rc\": 0" $d'
check "…the pin is in the chain state" \
  '[ "$(st img-ok "[\"image_tag\"]")" = delegate-worker-repo:local ] && [ "$(st img-ok "[\"image_base\"]")" = delegate-worker:local ]'
check "…the IMAGE section and build log landed in the round" \
  'grep -q "## IMAGE" $DELEGATE_STATE/repo-a/rounds/1/report.md && grep -q "delegate build --repo" $DELEGATE_STATE/repo-a/rounds/1/image-build.log'
check "…the re-verify already ran in the pinned image" '[ "$(sed -n 2p $DELEGATE_STATE/run-env)" = delegate-worker-repo:local ]'
check "…and so does the later step" '[ "$(sed -n 3p $DELEGATE_STATE/run-env)" = delegate-worker-repo:local ]'

# 6. re-verify fails a done round: normal retry whose message is the image-build.log tail, then
#    round 2 passes its own image pass and is accepted; the report says what the pass decided
rm -rf $DELEGATE_STATE; mkdir -p $DELEGATE_STATE
printf 'done\ndone\n' > $SCRIPT/a; printf '1\n0\n' > $SCRIPTRV/a; printf 'done\n' > $SCRIPT/b
python3 $here/lib/chain.py $T/plan-img-ok.json >$T/out 2>&1; rc=$?
check "re-verify failure takes the retry path and the next round is accepted" \
  '[ $rc = 0 ] && [ -d $DELEGATE_STATE/repo-a/rounds/2 ]'
check "…the done round now reads done-but-verify-failed, with what it said kept" \
  'd=$DELEGATE_STATE/repo-a/rounds/1/report.json; grep -qF "\"status\": \"done-but-verify-failed\"" $d && grep -qF "\"status_before_image\": \"done\"" $d'
check "…the retry message carries the image-build.log tail, not the old verify.log" \
  'grep -q "rebuild boom" $DELEGATE_STATE/last-retry-a && grep -q "rebuilt the project" $DELEGATE_STATE/last-retry-a'
check "…one image pass per round: the build ran twice" \
  '[ "$(grep -c "^build" $DELEGATE_STATE/calls)" = 2 ]'
check "…the retry itself ran in the pinned image" '[ "$(sed -n 3p $DELEGATE_STATE/run-env)" = delegate-worker-repo:local ]'

# 7. pin-lint refusal stops the chain: status image-refused, findings in the report, exit 3
rm -rf $DELEGATE_STATE; mkdir -p $DELEGATE_STATE; echo 2 > $DELEGATE_STATE/build-rc
printf 'done\n' > $SCRIPT/a; printf 'done\n' > $SCRIPT/b
python3 $here/lib/chain.py $T/plan-img-ok.json >$T/out 2>&1; rc=$?
check "refused rebuild stops the chain with exit 3" \
  '[ $rc = 3 ] && grep -q "REFUSED" $T/out && [ ! -d $DELEGATE_STATE/repo-b ]'
check "…the step reports image-refused, in state and in the round" \
  '[ "$(st img-ok "[\"steps\"][\"a\"][\"status\"]")" = image-refused ] \
   && grep -qF "\"status\": \"image-refused\"" $DELEGATE_STATE/repo-a/rounds/1/report.json'
check "…the pin-lint findings are in the report" 'grep -q "unpinned" $DELEGATE_STATE/repo-a/rounds/1/report.md'
check "…and nothing was pinned" '! grep -q image_tag $DELEGATE_STATE/chains/img-ok.json'

# 8. acceptance guard: a step WITHOUT the key whose round touched .delegate/ is refused,
#    and the chain does not branch the next step from it
rm -rf $DELEGATE_STATE; mkdir -p $DELEGATE_STATE
plan plain ',"scope":["docs/"]'
printf 'done\n' > $SCRIPT/a; printf 'done\n' > $SCRIPT/b; echo ".delegate/Dockerfile" > $DELEGATE_STATE/round-diff
python3 $here/lib/chain.py $T/plan-plain.json >$T/out 2>&1; rc=$?
check "a non-image step that touched .delegate/ is refused at acceptance" \
  '[ $rc = 3 ] && grep -q "delegate/ is the" $T/out && grep -q "\"image\": true" $T/out && [ ! -d $DELEGATE_STATE/repo-b ]'
check "…and no build was run for it" '! grep -q "^build" $DELEGATE_STATE/calls'

# 9. the guard is best-effort: _round-diff that cannot answer (exit 1) does not refuse on a guess
rm -rf $DELEGATE_STATE; mkdir -p $DELEGATE_STATE
printf 'done\n' > $SCRIPT/a; printf 'done\n' > $SCRIPT/b
python3 $here/lib/chain.py $T/plan-plain.json >$T/out 2>&1; rc=$?
check "a round the binary cannot read is not refused on a guess" '[ $rc = 0 ]'

# 10. resume re-exports the pin: a chain restarted after a stop runs its calls pinned
rm -rf $DELEGATE_STATE; mkdir -p $DELEGATE_STATE
printf 'done\n' > $SCRIPT/a; printf 'partial\npartial\npartial\npartial\ndone\n' > $SCRIPT/b
python3 $here/lib/chain.py $T/plan-img-ok.json >$T/out 2>&1; rc=$?
check "first run pins the image and stops on the failed step" \
  '[ $rc = 3 ] && [ "$(st img-ok "[\"image_tag\"]")" = delegate-worker-repo:local ]'
python3 $here/lib/chain.py $T/plan-img-ok.json >$T/out 2>&1; rc=$?
check "…a resumed run re-exports the pin (its continue sees it)" \
  '[ $rc = 0 ] && [ "$(tail -1 $DELEGATE_STATE/run-env)" = delegate-worker-repo:local ]'

echo; [ $fail = 0 ] && echo "PASS" || echo "FAIL"; exit $fail
