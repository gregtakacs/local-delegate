#!/bin/bash
# Chain step gates (lib/chain.py): a plan may name a quick "step_gate" beside its full "gate", and
# then an ordinary step's verify may run either one — while a "hard" step and the plan's LAST step
# must still run the gate, character for character. `--check` lints both levels, prints both, and a
# refusal says which of the two a step is missing. A plan with no "step_gate" is refused, worded
# and behaved exactly as before. `--check` also WARNS, without refusing, when a plan of 2+ steps
# marks every step hard — and the skill and the design template must carry the hard-rule sentence
# that warning quotes. No docker, no network, temp dirs only.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DELEGATE_STATE=$T/state DELEGATE_CHAIN_BIN=$T/fake-delegate
mkdir -p $DELEGATE_STATE $T/repo/docs/specs
git -C $T/repo init -q -b main
for f in a b c; do printf '# step %s\n\n## Read first\n\n- read-only: `lib/chain.py`\n' $f > $T/repo/docs/specs/$f.md; done
git -C $T/repo add -A && git -C $T/repo -c user.name=t -c user.email=t commit -qm i

fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# the fake worker: records what --verify each step was handed, and plays back $SCRIPT/<name>
cat > $T/fake-delegate <<'F'
#!/bin/bash
# fake: run SPEC --name N --verify V --base B | continue ID MSG --verify V | anything else
cmd=$1; shift; name=""; id=""; ver=""; base=""
if [ "$cmd" = run ]; then
  while [ $# -gt 0 ]; do case "$1" in --name) name=$2; id="repo-$name"; shift 2;; --verify) ver=$2; shift 2;;
    --base) base=$2; shift 2;; *) shift;; esac; done
  echo "$cmd" >> "$DELEGATE_STATE/calls"; printf '%s' "$ver" > "$DELEGATE_STATE/run-verify-$name"
  [ -n "$base" ] && echo "$base" >> "$DELEGATE_STATE/bases"
elif [ "$cmd" = continue ]; then
  id=$1; name=${id#repo-}; echo "$cmd" >> "$DELEGATE_STATE/calls"
else echo "$cmd" >> "$DELEGATE_STATE/calls"; exit 0; fi
d=$DELEGATE_STATE/$id/rounds; mkdir -p "$d"; n=$(( $(ls "$d" | wc -l) + 1 )); mkdir "$d/$n"
st=$(sed -n "${n}p" "$SCRIPT/$name"); st=${st:-done}
printf '{"status":"%s","verify_rc":%s}\n' "$st" "$([ "$st" = done-but-verify-failed ] && echo 1 || echo 0)" \
  > "$d/$n/report.json"
echo "ok" > "$d/$n/verify.log"
F
chmod +x $T/fake-delegate
export SCRIPT=$T/script; mkdir -p $SCRIPT
for f in a b c; do printf 'done\n' > $SCRIPT/$f; done

GATE='make check-sandbox'
SGATE='python3 tools/a_test.py && git diff --check HEAD'
splan() { # splan '<plan keys, e.g. ,"gate":"…">' '<steps json>'
  printf '{"name":"sg","repo":"%s","base":"main","retries":2%s,"steps":[%s]}\n' "$T/repo" "$1" "$2" > $T/plan.json; }
st() { # st NAME SPEC VERIFY '<step keys, e.g. ,"hard":true>'
  printf '{"name":"%s","spec":"docs/specs/%s.md","verify":"%s"%s}' "$1" "$2" "$3" "$4"; }
gk()  { printf ',"gate":"%s"' "$GATE"; }
gsk() { printf ',"gate":"%s","step_gate":"%s"' "$GATE" "$SGATE"; }
chk() { python3 $here/lib/chain.py $T/plan.json --check > $T/o 2>&1; RC=$?; }
fresh() { rm -rf $DELEGATE_STATE; mkdir -p $DELEGATE_STATE; }
quiet() { [ ! -e $DELEGATE_STATE/calls ] && [ ! -e $DELEGATE_STATE/chains/sg.json ]; }

# 1. A plan with no step_gate: unchanged, in both directions
splan "$(gk)" "$(st a a "$GATE" ''),$(st b b "$GATE" '')"
chk
check "no step_gate, every verify runs the gate: --check passes" '[ $RC = 0 ]'
check "…and --check still says every step runs it, as before" \
  'grep -qx "  gate: make check-sandbox  (every step runs it)" $T/o'
check "…and names no step_gate it does not have" '! grep -q step_gate $T/o'
splan "$(gk)" "$(st a a "python3 tools/a_test.py" ''),$(st b b "$GATE" ''),$(st c c "$GATE" '')"
chk
check "no step_gate: an ordinary step that skips the gate is refused, as today" \
  '[ $RC = 2 ] && grep -q "does not run the plan'"'"'s gate (make check-sandbox) exactly as written: a" $T/o'
check "…with the same wording, and no step_gate named" '! grep -q step_gate $T/o'
check "…and nothing ran, no chain state written" 'quiet'

# 2. The two levels: an ordinary step may run the quick check instead of the whole suite
splan "$(gsk)" "$(st a a "$SGATE" ''),$(st b b "$GATE" ''),$(st c c "$GATE" '')"
chk
check "with a step_gate, an ordinary step that runs only it passes" '[ $RC = 0 ]'
check "--check prints both commands, and what each one is for" \
  "grep -qxF '  gate: make check-sandbox  (every hard step and the last one run it)' \$T/o && grep -qxF '  step_gate: $SGATE  (every other step runs the gate or this)' \$T/o"
check "…and each step's verify is still printed exactly as stored" \
  "grep -qxF '       verify: $SGATE' \$T/o"
check "…and --check starts nothing, writes no chain state" 'quiet'
splan "$(gsk)" "$(st a a "$SGATE && $GATE" ''),$(st b b "$SGATE" ',"hard":false'),$(st c c "$GATE" '')"
chk
check "an ordinary step that runs both levels passes (the gate wins), and \"hard\": false is ordinary" \
  '[ $RC = 0 ]'
splan "$(gsk)" "$(st a a 'python3 tools/a_test.py && git dif --check HEAD' ''),$(st b b "$GATE" ''),$(st c c "$GATE" '')"
chk
check "a mutated step_gate (one dropped character) is refused like a mutated gate" \
  '[ $RC = 2 ] && grep -q ": a$" $T/o'
check "…and the refusal names both commands that step could have run" \
  'grep -q "or its step_gate" $T/o'

# 3. Where the full gate stays: a "hard" step, and the plan's last step
splan "$(gsk)" "$(st a a "$SGATE" ''),$(st b b "$SGATE" ',"hard":true'),$(st c c "$GATE" '')"
chk
check "a hard step running only the step_gate is refused" '[ $RC = 2 ]'
check "…and its message names the plan's GATE, not the quick check it did run" \
  'grep -q "does not run the plan'"'"'s gate (make check-sandbox) exactly as written: b" $T/o \
   && ! grep -q "or its step_gate" $T/o'
splan "$(gsk)" "$(st a a "$SGATE" ''),$(st b b "$SGATE" ''),$(st c c "$SGATE" '')"
chk
check "the last step running only the step_gate is refused" '[ $RC = 2 ]'
check "…and its message names the plan's GATE and that step" \
  'grep -q "does not run the plan'"'"'s gate (make check-sandbox) exactly as written: c" $T/o'
splan "$(gsk)" "$(st a a "$SGATE" ''),$(st b b "$SGATE" ''),$(st c c "$SGATE" ',"hard":true')"
chk
check "a step that is both last and hard is refused once, under the gate's sentence" \
  '[ $RC = 2 ] && grep -q "exactly as written: c" $T/o && [ "$(grep -c "does not run" $T/o)" = 1 ]'
splan "$(gsk)" "$(st a a "$SGATE" '')"
chk
check "a one-step plan is its own last step: the gate is not optional there" \
  '[ $RC = 2 ] && grep -q "exactly as written: a" $T/o'

# 4. An ordinary step that runs neither command: the refusal names both
splan "$(gsk)" "$(st a a "true" ''),$(st b b "$SGATE" ''),$(st c c "$GATE" '')"
chk
check "an ordinary step running neither is refused" '[ $RC = 2 ]'
check "…and the message names the step_gate as well as the gate" \
  'grep -qF "or its step_gate (python3 tools/a_test.py && git diff --check HEAD) exactly as written: a" $T/o'
splan "$(gsk)" "$(st a a "true" ''),$(st b b "$SGATE" ',"hard":true'),$(st c c "$GATE" '')"
chk
check "one plan can refuse two ways: the hard step by the gate alone, the ordinary one by both" \
  '[ $RC = 2 ] && grep -q "gate (make check-sandbox) exactly as written: b" $T/o \
   && grep -qF "or its step_gate" $T/o && grep -q ": a$" $T/o'
check "…and a refusal writes no chain state and starts no step" 'quiet'

# 5. The step_gate's own shape
splan "$(gk),\"step_gate\":\"\"" "$(st a a "$GATE" ''),$(st b b "$GATE" '')"
chk
check "an empty step_gate is refused, and says it must be non-empty" \
  '[ $RC = 2 ] && grep -q "step_gate" $T/o && grep -q "non-empty" $T/o'
splan "$(gk),\"step_gate\":7" "$(st a a "$GATE" ''),$(st b b "$GATE" '')"
chk
check "a non-string step_gate is refused" '[ $RC = 2 ] && grep -q "step_gate" $T/o'
splan ",\"step_gate\":\"$SGATE\"" "$(st a a "true" ''),$(st b b "true" '')"
chk
check "a plan with no gate is not gate-linted at all, step_gate or not" \
  '[ $RC = 0 ] && ! grep -q "^  gate:" $T/o'
splan ',"step_gate":["make check-step"]' "$(st a a "true" ''),$(st b b "true" '')"
chk
check "…but a malformed step_gate is refused even there" '[ $RC = 2 ] && grep -q "step_gate" $T/o'

# 6. The same lint guards a run; and a run hands each step the verify exactly as stored
fresh
splan "$(gsk)" "$(st a a "$SGATE" ''),$(st b b "$GATE" ',"hard":true'),$(st c c "$GATE" '')"
python3 $here/lib/chain.py $T/plan.json > $T/r6 2>&1; rc=$?
check "a two-level plan runs to the end, every step accepted" \
  "[ \$rc = 0 ] && [ -d \$DELEGATE_STATE/repo-a/rounds/1 ] && [ -d \$DELEGATE_STATE/repo-c/rounds/1 ]"
check "the ordinary step is handed the quick check it names, byte for byte" \
  '[ "$(cat $DELEGATE_STATE/run-verify-a)" = "'"$SGATE"'" ]'
check "the hard step is handed the full gate, byte for byte" \
  '[ "$(cat $DELEGATE_STATE/run-verify-b)" = "'"$GATE"'" ]'
fresh
splan "$(gsk)" "$(st a a "$SGATE" ''),$(st b b "$SGATE" ',"hard":true'),$(st c c "$GATE" '')"
python3 $here/lib/chain.py $T/plan.json > $T/r6b 2>&1; rc=$?
check "a run refuses the plan --check refuses, before any step starts" \
  "[ \$rc = 2 ] && grep -q \"exactly as written: b\" \$T/r6b && quiet"
python3 $here/lib/chain.py $T/plan.json --status > $T/r6c 2>&1; rc=$?
check "--status reads such a plan without linting it, as before" \
  "[ \$rc = 0 ] && grep -q '^chain sg' \$T/r6c && grep -q 'not started' \$T/r6c"
python3 $here/lib/chain.py $T/plan.json --clean > $T/r6d 2>&1; rc=$?
check "…and so does --clean" '[ $rc = 0 ]'

# 7. containment stays the rule it was: a verify that runs the gate satisfies it, whatever else it runs
splan ',"gate":"make check","step_gate":"make check-sandbox"' \
     "$(st a a "make check-sandbox" ''),$(st b b "make check" '')"
chk
check "a step_gate that already runs the gate is a full-gate verify, not a refusal" '[ $RC = 0 ]'

# 8. --check warns when a 2+-step plan marks EVERY step hard (a warning: never a refusal)
splan "$(gsk)" "$(st a a "$GATE" ',"hard":true'),$(st b b "$GATE" ',"hard":true'),$(st c c "$GATE" ',"hard":true')"
chk
check "every step hard in a 3-step plan: --check still exits 0" '[ $RC = 0 ]'
check "…and prints the warning, worded as the skill words it" \
  'grep -q "^  warning: every step is marked hard: hard is for steps that guard a boundary or carry real algorithmic difficulty; routine steps (UI plumbing, tests, docs, pattern-following) run on the normal model$" $T/o'
check "…and the warning does not hide the rest of --check" \
  'grep -q "^  gate: make check-sandbox" $T/o && grep -q "^  3. c  no scope" $T/o'
check "…and --check still starts nothing and writes no chain state" 'quiet'
splan "$(gsk)" "$(st a a "$GATE" ',"hard":true'),$(st b b "$GATE" ',"hard":true')"
chk
check "two steps, both hard: the warning fires at the smallest plan it can" '[ $RC = 0 ] && grep -q "every step is marked hard" $T/o'
splan "$(gsk)" "$(st a a "$GATE" ',"hard":true'),$(st b b "$GATE" ',"hard":false'),$(st c c "$GATE" ',"hard":true')"
chk
check "one step that is not hard: no warning" '[ $RC = 0 ] && ! grep -q "every step is marked hard" $T/o'
splan "$(gsk)" "$(st a a "$GATE" ',"hard":true'),$(st b b "$GATE" ''),$(st c c "$GATE" '')"
chk
check "…nor when steps simply carry no hard key at all" '[ $RC = 0 ] && ! grep -q "every step is marked hard" $T/o'
splan "$(gsk)" "$(st a a "$GATE" ',"hard":true')"
chk
check "a 1-step plan marked hard: no warning (a single risky step is not a plan of only hard work)" \
  '[ $RC = 0 ] && ! grep -q "every step is marked hard" $T/o'
splan '' "$(st a a "true" ',"hard":true'),$(st b b "true" ',"hard":true')"
chk
check "the warning is about the plan's marking, not the gate: no gate, same warning, same exit 0" \
  '[ $RC = 0 ] && grep -q "every step is marked hard" $T/o && ! grep -q "^  gate:" $T/o'
fresh
splan "$(gsk)" "$(st a a "$SGATE" ''),$(st b b "$GATE" ',"hard":true')"
python3 $here/lib/chain.py $T/plan.json > $T/r8 2>&1; rc=$?
check "a run says nothing about hard marking: the warning is --check's" \
  "[ \$rc = 0 ] && ! grep -q 'every step is marked hard' \$T/r8"

# 9. the method carries the same rule the warning speaks: one sentence, in the skill (Phase 2's
#    hard bullet) and in the design template (where it asks the design to mark hard steps). The
#    files wrap prose at ~80 columns, so match the sentence with its line folds folded back.
SENT='Everything else runs on the normal model: UI plumbing, tests, docs and pattern-following steps are not hard. When in doubt about a boundary, mark it hard; when in doubt about difficulty, don'"'"'t.'
flat() { tr -s '[:space:]' ' ' < "$1"; }
flat "$here/claude/skills/delegate/SKILL.md" > $T/skill.flat
flat "$here/claude/skills/delegate/design-template.md" > $T/template.flat
check "SKILL.md says it, in Phase 2's bullet about steps that guard a boundary" \
  'grep -qF "$SENT" $T/skill.flat && awk "/Every step that guards a boundary/{f=1} f&&/runs on the normal model/{print}" '"$here"'/claude/skills/delegate/SKILL.md | grep -q "Everything else"'
check "…and the design template says it where it asks the design to mark hard steps" \
  'grep -qF "$SENT" $T/template.flat && awk "/A step gets/{f=1} f&&/runs on the normal model/{print}" '"$here"'/claude/skills/delegate/design-template.md | grep -q "Everything else"'

exit $fail
