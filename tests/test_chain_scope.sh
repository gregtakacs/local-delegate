#!/bin/bash
# Chain step scopes (lib/chain.py): the scope regex (and that Python and grep -E agree on it), the
# entry and base validation, what a spec owns, the load-time lint and `--check`, the scope gate as
# bash really runs it in a git repo, how the chain composes a scoped step's verify, and what the
# chain does when the gate refuses a path. No docker, no network, temp dirs only.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DELEGATE_STATE=$T/state DELEGATE_CHAIN_BIN=$T/fake-delegate
mkdir -p $DELEGATE_STATE $T/repo/docs/specs
git -C $T/repo init -q -b main
for f in a b c d; do printf '# step %s\n\n## Read first\n\n- read-only: `lib/chain.py`\n' $f > $T/repo/docs/specs/$f.md; done
git -C $T/repo add -A && git -C $T/repo -c user.name=t -c user.email=t@t commit -qm i

fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# python helpers: probe the regex, and list what a spec owns
cat > $T/probe.py <<'P'
import re, sys
sys.path.insert(0, sys.argv[1] + "/lib")
from chain import scope_regex
rx = scope_regex(sys.argv[2].split("|"))
if sys.argv[3] == "--rx":
    print(rx); raise SystemExit
print("\n".join(("yes " if re.fullmatch(rx, p) else "no  ") + p for p in sys.argv[3].split("|")))
P
cat > $T/owned.py <<'P'
import sys
sys.path.insert(0, sys.argv[1] + "/lib")
from chain import owned_paths
for p, n in owned_paths(open(sys.argv[2]).read()):
    print(f"{p}@{n}")
P
pyprobe(){ python3 $T/probe.py "$here" "$1" "$2"; }

# 1. the regex: entry forms, exactly as the contract says
check "an exact path admits itself and nothing else" \
  '[ "$(pyprobe "hub/app.py" "hub/app.py|hub/app.pyy|hub/app.py/x|src/app.py")" = "yes hub/app.py
no  hub/app.pyy
no  hub/app.py/x
no  src/app.py" ]'
check "a dir entry admits anything under it, at any depth, not a sibling" \
  '[ "$(pyprobe "hub/tests/" "hub/tests/x.py|hub/tests/deep/y.py|hub/testsX|hub/x.py")" = "yes hub/tests/x.py
yes hub/tests/deep/y.py
no  hub/testsX
no  hub/x.py" ]'
check "* never crosses a /" \
  '[ "$(pyprobe "lib/*.py" "lib/x.py|lib/a.b.py|lib/a/y.py|libxpy")" = "yes lib/x.py
yes lib/a.b.py
no  lib/a/y.py
no  libxpy" ]'
check "? is one character and never a /" \
  '[ "$(pyprobe "a?c.py" "abc.py|a.c.py|a/c.py")" = "yes abc.py
yes a.c.py
no  a/c.py" ]'
check "** spans zero, one and many segments" \
  '[ "$(pyprobe "a/**/b.py" "a/b.py|a/x/b.py|a/x/y/b.py|a/x/y/c.py|b.py")" = "yes a/b.py
yes a/x/b.py
yes a/x/y/b.py
no  a/x/y/c.py
no  b.py" ]'
check "dir/** is everything under dir, and ** alone is every path" \
  '[ "$(pyprobe "src/**" "src/a|src/a/b|lib/a")" = "yes src/a
yes src/a/b
no  lib/a" ] && [ "$(pyprobe "**" "a|a/b/c.py")" = "yes a
yes a/b/c.py" ]'
check "** may lead an entry too (**/b.py is any b.py)" \
  '[ "$(pyprobe "**/b.py" "b.py|a/b.py|a/x/b.py|a/x/c.py")" = "yes b.py
yes a/b.py
yes a/x/b.py
no  a/x/c.py" ]'
check "a . and a + in an entry are literal, not regex" \
  '[ "$(pyprobe "a.py|x+y" "a.py|aXpy|aXpyy|x+y|x.y")" = "yes a.py
no  aXpy
no  aXpyy
yes x+y
no  x.y" ]'
check "several entries union, and each is anchored at both ends" \
  '[ "$(pyprobe "hub/app.py|hub/tests/" "hub/app.py|hub/tests/t.py|other.md|hub/app.py.bak")" = "yes hub/app.py
yes hub/tests/t.py
no  other.md
no  hub/app.py.bak" ]'

# 2. the same matcher on both sides: grep -E (the gate) decides every probe exactly as re.fullmatch
#    (the lint) does — the two must never disagree about what a scope admits
ENTRIES='hub/app.py|hub/tests/|src/**/*.py|lib/*.py|docs/specs/notes+todo.md|tmp/a?c/x.py|one/**/two/x.py'
cat > $T/paths.txt <<'EOF'
hub/app.py
hub/app.pyx
hub/appXpy
hub/tests/t.py
hub/tests/a/b.py
hub/testing/t.py
src/x.py
src/a/b.py
src/a/b/c.py
src/a/c.pyx
lib/x.py
lib/a/x.py
lib/x.pyy
docs/specs/notes+todo.md
docs/specs/notesXtodo.md
docs/specs/notes.todo.md
tmp/a2c/x.py
tmp/ac/x.py
one/two/x.py
one/a/b/two/x.py
one/two/y.py
other.md
hub/app.py/x
README.md
EOF
python3 $T/probe.py "$here" "$ENTRIES" --rx > $T/rx
while IFS= read -r p; do
  if printf '%s\n' "$p" | grep -Eq "$(cat $T/rx)"; then echo "yes $p"; else echo "no  $p"; fi
done < $T/paths.txt > $T/grep.out
python3 $T/probe.py "$here" "$ENTRIES" "$(paste -sd'|' $T/paths.txt)" > $T/py.out
check "grep -E and re.fullmatch decide all 24 probes the same way" \
  '[ "$(wc -l < $T/paths.txt)" = 24 ] && cmp -s $T/grep.out $T/py.out'
check "…and the two sides are not both trivially refusing" 'grep -q "^yes " $T/grep.out && grep -q "^no  " $T/grep.out'
# the gate itself matches with bash's [[ =~ ]] (no pipe, so no SIGPIPE under pipefail): same verdicts
rx=$(cat $T/rx)
while IFS= read -r p; do
  if [[ $p =~ $rx ]]; then echo "yes $p"; else echo "no  $p"; fi
done < $T/paths.txt > $T/bash.out
check "bash [[ =~ ]] (what the gate runs) decides all 24 probes as re.fullmatch does" 'cmp -s $T/bash.out $T/py.out'
# a refused path counts as "named by the spec" only as that exact path, not inside a longer one
python3 -c "
import sys; sys.path.insert(0, sys.argv[1] + '/lib'); import chain
t = 'modify \`daemon/data.py\`; also x/a.py and b.pyc; see c.py.'
print(chain.names_path(t, 'a.py'), chain.names_path(t, 'data.py'), chain.names_path(t, 'b.py'),
      chain.names_path(t, 'c.py'), chain.names_path(t, 'daemon/data.py'))" "$here" > $T/np.out
check "names_path: a.py, data.py, b.py are not named by x/a.py, daemon/data.py, b.pyc; c.py and daemon/data.py are" \
  'grep -qx "False False False True True" $T/np.out'

# 3. a scope entry that cannot be trusted in a shell, or is not a list of them: refused at load
cat > $T/fake-delegate <<'F'
#!/bin/bash
# fake: run SPEC --name N --verify V --base B | continue ID MSG --verify V. It records every call,
# keeps the verify it was handed, and plays back the round statuses in $SCRIPT/<name>.
cmd=$1; shift; name=""; id=""; ver=""; base=""; msg=""
if [ "$cmd" = run ]; then
  while [ $# -gt 0 ]; do case "$1" in --name) name=$2; id="repo-$name"; shift 2;; --verify) ver=$2; shift 2;;
    --base) base=$2; shift 2;; *) shift;; esac; done
  echo "$cmd" >> "$DELEGATE_STATE/calls"; printf '%s' "$ver" > "$DELEGATE_STATE/run-verify-$name"
  [ -n "$base" ] && echo "$base" >> "$DELEGATE_STATE/bases"
elif [ "$cmd" = continue ]; then
  id=$1; msg=$2; name=${id#repo-}; shift 2
  while [ $# -gt 0 ]; do case "$1" in --verify) ver=$2; shift 2;; *) shift;; esac; done
  echo "$cmd" >> "$DELEGATE_STATE/calls"; cp "$msg" "$DELEGATE_STATE/last-retry-$name"
  printf '%s\n' "$ver" >> "$DELEGATE_STATE/continue-verify-$name"
else echo "$cmd" >> "$DELEGATE_STATE/calls"; exit 0; fi
d=$DELEGATE_STATE/$id/rounds; mkdir -p "$d"; n=$(( $(ls "$d" | wc -l) + 1 )); mkdir "$d/$n"
st=$(sed -n "${n}p" "$SCRIPT/$name"); st=${st:-done}
printf '{"status":"%s","verify_rc":%s}\n' "$st" "$([ "$st" = done-but-verify-failed ] && echo 1 || echo 0)" \
  > "$d/$n/report.json"
if [ -f "$SCRIPT/$name.log" ]; then cp "$SCRIPT/$name.log" "$d/$n/verify.log"
else echo "boom: assertion failed in test_x" > "$d/$n/verify.log"; fi
F
chmod +x $T/fake-delegate
export SCRIPT=$T/script; mkdir -p $SCRIPT
scope_plan() { # scope_plan '{"scope":[...] }' extra-plan-keys
  printf '{"name":"%s","repo":"%s","base":"main","retries":2,"steps":[{"name":"a","spec":"docs/specs/a.md","verify":"true"%s}]%s}\n' \
    "$1" "$T/repo" "$2" "$3" > $T/plan.json; }
refused() { # refused LABEL '<step json>' — the plan is refused at load, before anything runs
  scope_plan refuse "$2" ''
  python3 $here/lib/chain.py $T/plan.json --check > $T/r3 2>&1; local rc=$?
  check "$1 exits 2 and names the entry" "[ \$rc = 2 ] && grep -q 'step a' $T/r3"
  check "$1: nothing ran, no chain state written" \
    "[ ! -e \$DELEGATE_STATE/calls ] && [ ! -e \$DELEGATE_STATE/chains/refuse.json ]"
  rm -f $DELEGATE_STATE/calls; }
refused "a non-string entry"        ',"scope":[7]'
refused "an empty entry"            ',"scope":[""]'
refused "an empty list"             ',"scope":[]'
refused "a bare string, not a list" ',"scope":"hub/app.py"'
refused "an absolute entry"         ',"scope":["/etc/passwd"]'
refused "a .. segment"              ',"scope":["lib/../lib/x.py"]'
refused "a space"                   ',"scope":["a b"]'
refused "a single quote"            ',"scope":["a'"'"'b"]'
refused "a double quote"            ',"scope":["a\"b"]'
refused "a dollar sign"             ',"scope":["$x"]'
refused "brackets"                  ',"scope":["[]"]'
refused "a backslash"               ',"scope":["a\\\\b"]'
refused "a newline"                 ',"scope":["a\nb"]'
refused "a backtick"                ',"scope":["`x`"]'
scope_plan refuse '' ',"scope":["hub/app.py"]'
python3 $here/lib/chain.py $T/plan.json --check > $T/r3 2>&1; rc=$?
check "a plan-level scope is refused: it belongs on each step" \
  '[ $rc = 2 ] && grep -q "plan-level" $T/r3 && grep -q "put it on each step" $T/r3'
check "…and nothing ran, no chain state written" \
  '[ ! -e $DELEGATE_STATE/calls ] && [ ! -e $DELEGATE_STATE/chains/refuse.json ]'
rm -f $DELEGATE_STATE/calls

# the plan's base is single-quoted into the gate, so a scoped plan may not carry a wild one
printf '{"name":"badbase","repo":"%s","base":"main; rm -rf /","steps":[{"name":"a","spec":"docs/specs/a.md","verify":"true","scope":["hub/app.py"]}]}' "$T/repo" > $T/plan.json
python3 $here/lib/chain.py $T/plan.json --check > $T/r3 2>&1; rc=$?
check "a scoped plan refuses a base that is not a plain ref" '[ $rc = 2 ] && grep -q "plan base" $T/r3'
printf '{"name":"badbase","repo":"%s","base":"main; rm -rf /","steps":[{"name":"a","spec":"docs/specs/a.md","verify":"true"}]}' "$T/repo" > $T/plan.json
python3 $here/lib/chain.py $T/plan.json --check > $T/r3 2>&1; rc=$?
check "a plan with no scope is left as it was, base and all" '[ $rc = 0 ] && grep -q "no scope" $T/r3'

# the plan's "gate": the repo's own gate command, named once; every verify must run it verbatim,
# and --check prints each verify as stored. (A generated verify once turned PYTHON into PYTHO2 in
# four steps: each still ran, weaker, and no review read the stored text.)
gate_plan() { # gate_plan GATE VERIFY_A VERIFY_B
  printf '{"name":"gate","repo":"%s","base":"main","gate":%s,"steps":[{"name":"a","spec":"docs/specs/a.md","verify":"%s"},{"name":"b","spec":"docs/specs/b.md","verify":"%s"}]}\n' \
    "$T/repo" "$1" "$2" "$3" > $T/plan.json; }
gate_plan '"make check-sandbox"' 'python3 tools/a_test.py && make check-sandbox' 'set -o pipefail; python3 tools/b_test.py && make check-sandbox'
python3 $here/lib/chain.py $T/plan.json --check > $T/r3 2>&1; rc=$?
check "every verify runs the plan's gate: the plan passes" '[ $rc = 0 ]'
check "--check names the gate" 'grep -q "gate: make check-sandbox" $T/r3'
check "--check prints each step's verify as stored" \
  'grep -qx "       verify: python3 tools/a_test.py && make check-sandbox" $T/r3 && grep -qx "       verify: set -o pipefail; python3 tools/b_test.py && make check-sandbox" $T/r3'
gate_plan '"make check-sandbox"' 'python3 tools/a_test.py && make check-sandbox' 'python3 tools/b_test.py && make check-host PYTHO2=/usr/bin/python3'
python3 $here/lib/chain.py $T/plan.json --check > $T/r3 2>&1; rc=$?
check "a step whose verify skips the gate is refused, and named" '[ $rc = 2 ] && grep -q "does not run the plan.s gate" $T/r3 && grep -q ": b$" $T/r3'
check "…and nothing ran, no chain state written" '[ ! -e $DELEGATE_STATE/calls ] && [ ! -e $DELEGATE_STATE/chains/gate.json ]'
gate_plan '"make check-sandbox"' 'make check-sandbo' 'make check-sandbox'
python3 $here/lib/chain.py $T/plan.json --check > $T/r3 2>&1; rc=$?
check "the gate must appear character for character" '[ $rc = 2 ] && grep -q ": a$" $T/r3'
gate_plan '""' 'true' 'true'
python3 $here/lib/chain.py $T/plan.json --check > $T/r3 2>&1; rc=$?
check "an empty gate is refused" '[ $rc = 2 ] && grep -q "non-empty" $T/r3'
gate_plan '7' 'true' 'true'
python3 $here/lib/chain.py $T/plan.json --check > $T/r3 2>&1; rc=$?
check "a non-string gate is refused" '[ $rc = 2 ]'
rm -f $DELEGATE_STATE/calls

# 4. what a spec owns: the bullets that name files the step will change, and only those
FIX=$here/tests/fixtures/chain-scope
python3 $T/owned.py "$here" $FIX/spec-owned.md > $T/o4
check "owned_paths reads every owned path, with the line it is named on" \
  '[ "$(cat $T/o4)" = "hub/app.py@9
lib/router.py@10
lib/params.py@10
hub/tests/test_routing.py@11
hub/tests/test_gate_order.py@11
hub/tests/test_origin.py@11
legacy/old_worker.py@13
docs/specs/@14
tmp/cache/@15
src/fixtures/new/@17
lib/contract_item.md@22" ]'
check "…including a bare filename under the directory of the path before it" \
  'grep -qx "hub/tests/test_gate_order.py@11" $T/o4'
check "…and a dir/** token as that directory" 'grep -qx "docs/specs/@14" $T/o4'
check "a backticked token that is not a path is not owned" '! grep -qi "ROUTE_PARAMS" $T/o4'
check "a bullet under Read first is not owned (it is not an edit)" '! grep -q not_an_edit $T/o4'
check "a read-only bullet is not owned" '! grep -q egress-entrypoint $T/o4'
check "only the path list at the head of a bullet is owned: after a later sentence, a dash or in parentheses it is prose" \
  '! grep -q "src/fixtures/old" $T/o4 && ! grep -q "lib/prose.py" $T/o4 && ! grep -q "in/parens.py" $T/o4'
check "a :LINE suffix is dropped (test_origin.py:40 owns test_origin.py)" 'grep -qx "hub/tests/test_origin.py@11" $T/o4'

# 5. the lint: a step's scope must cover the files its own spec owns (refused before anything runs)
cp $FIX/spec-owned.md $T/repo/docs/specs/owned.md
ALL='["hub/app.py","lib/router.py","lib/params.py","hub/tests/","legacy/old_worker.py","docs/specs/","tmp/cache/","src/fixtures/new/","lib/contract_item.md"]'
lplan() { # lplan NAME '<scope json>'  ('' = no scope at all)
  local extra=""
  [ -n "${2:-}" ] && extra=',"scope":'"$2"
  printf '{"name":"%s","repo":"%s","base":"main","retries":2,"steps":[{"name":"a","spec":"docs/specs/owned.md","verify":"true"%s}]}\n' \
    "$1" "$T/repo" "$extra" > $T/plan.json; }
lplan lintmiss "[\"hub/app.py\",\"lib/router.py\",\"lib/params.py\",\"hub/tests/\",\"docs/specs/\",\"tmp/cache/\",\"src/fixtures/new/\",\"lib/contract_item.md\"]"
python3 $here/lib/chain.py $T/plan.json --check > $T/l5 2>&1; rc=$?
check "a scope that misses one owned file exits 2" '[ $rc = 2 ]'
check "…and names the file, the spec and the line" \
  'grep -q "step a: the spec owns legacy/old_worker.py (docs/specs/owned.md:13) but" $T/l5'
check "…and nothing started: no delegate call, no chain state" \
  '[ ! -e $DELEGATE_STATE/calls ] && [ ! -e $DELEGATE_STATE/chains/lintmiss.json ]'
python3 $here/lib/chain.py $T/plan.json > $T/l5b 2>&1; rc=$?
check "a run refuses the same plan, before any step starts" \
  "[ \$rc = 2 ] && grep -q 'legacy/old_worker.py' \$T/l5b && [ ! -e \$DELEGATE_STATE/calls ]"
lplan ldir "[\"hub/app.py\",\"lib/router.py\",\"lib/params.py\",\"hub/tests/\",\"legacy/old_worker.py\",\"tmp/cache/\",\"src/fixtures/new/\",\"lib/contract_item.md\"]"
python3 $here/lib/chain.py $T/plan.json --check > $T/l5c 2>&1; rc=$?
check "an owned directory its scope does not enter is a miss too" \
  "[ \$rc = 2 ] && grep -q 'the spec owns docs/specs/' \$T/l5c"
lplan lintok "$ALL"
python3 $here/lib/chain.py $T/plan.json --check > $T/l5d 2>&1; rc=$?
check "--check on a covered plan exits 0 and says so, per step" \
  "[ \$rc = 0 ] && grep -qx '  1. a  scope: 9 entries, owned: 11 (all covered)' \$T/l5d"
check "…and --check starts nothing and writes no chain state" \
  '[ ! -e $DELEGATE_STATE/calls ] && [ ! -e $DELEGATE_STATE/chains/lintok.json ]'
lplan nolint ''
python3 $here/lib/chain.py $T/plan.json --check > $T/l5e 2>&1; rc=$?
check "--check on a step without a scope says no scope, exit 0" \
  "[ \$rc = 0 ] && grep -qx '  1. a  no scope' \$T/l5e"

# 6. the scope gate itself: bash, run for real in a git repo, before the verify it guards
cat > $T/gen.py <<'P'
import json, sys
sys.path.insert(0, sys.argv[1] + "/lib")
from chain import scope_gate
print(scope_gate(json.loads(sys.argv[2]), None if sys.argv[3] == "-" else sys.argv[3]))
print('touch "$MARKER"; echo REAL-VERIFY-RAN')
P
export MARKER=$T/marker
gen() { python3 $T/gen.py "$here" "$1" "$2" > $T/gate.sh; }        # '-' = in place (diff HEAD)
run_gate() {                                                       # run_gate [caller prefix]
  { [ -n "${1:-}" ] && printf '%s\n' "$1"; cat $T/gate.sh; } > $T/run.sh
  rm -f $MARKER; GATE_OUT=$(cd $G && bash $T/run.sh 2>&1); GATE_RC=$?; }
G=$T/gate-repo; mkdir -p $G/hub/tests $G/src; git -C $G init -q -b main
for f in hub/app.py hub/tests/t.py outside.md to-delete.md; do echo v1 > $G/$f; done
echo v1 > "$G/sp ace.md"; git -C $G add -A
git -C $G -c user.name=t -c user.email=t commit -qm i; git -C $G branch base; git -C $G checkout -qb step-2
gen '["hub/app.py","hub/tests/"]' base
echo changed >> $G/hub/app.py; echo new > $G/hub/tests/n.py
run_gate
check "in-scope changes pass the gate, count reported, and the verify after it runs" \
  '[ $GATE_RC = 0 ] && echo "$GATE_OUT" | grep -qx "DELEGATE-SCOPE: ok (2 changed paths)" \
   && [ -f $MARKER ] && echo "$GATE_OUT" | grep -q REAL-VERIFY-RAN'
echo changed >> $G/outside.md
run_gate
check "a modified file outside the scope: exit 1, listed, and the verify after it never started" \
  '[ $GATE_RC = 1 ] && echo "$GATE_OUT" | grep -q "^DELEGATE-SCOPE: outside this step.s scope:$" \
   && echo "$GATE_OUT" | grep -qx "DELEGATE-SCOPE:   outside.md" && [ ! -e $MARKER ]'
echo new > $G/untracked.md; git -C $G rm -q to-delete.md
run_gate
check "an untracked file is a violation" '[ $GATE_RC = 1 ] && echo "$GATE_OUT" | grep -qx "DELEGATE-SCOPE:   untracked.md"'
check "a deleted file is a violation" '[ $GATE_RC = 1 ] && echo "$GATE_OUT" | grep -qx "DELEGATE-SCOPE:   to-delete.md"'
check "a committed change on the step branch is a violation" \
  '[ $GATE_RC = 1 ] && echo "$GATE_OUT" | grep -qx "DELEGATE-SCOPE:   outside.md"'
echo new > "$G/sp ace.md"
run_gate
check "a path with a space is listed whole, not split" '[ $GATE_RC = 1 ] && echo "$GATE_OUT" | grep -qx "DELEGATE-SCOPE:   sp ace.md"'
run_gate 'set -euo pipefail'
check "the same gate under set -euo pipefail in the caller: same refusal, same exit" \
  '[ $GATE_RC = 1 ] && echo "$GATE_OUT" | grep -qx "DELEGATE-SCOPE:   outside.md" && [ ! -e $MARKER ]'
git -C $G checkout -q HEAD -- outside.md to-delete.md "sp ace.md"; rm -f $G/untracked.md
run_gate 'set -euo pipefail'
check "…and in scope under pipefail, the verify runs" \
  '[ $GATE_RC = 0 ] && echo "$GATE_OUT" | grep -q "^DELEGATE-SCOPE: ok (" && [ -f $MARKER ]'
echo new > "$G/hub/tests/ünï.py"
run_gate
check "a non-ASCII file name inside the scope passes (git's quoting is off, so it matches as named)" \
  '[ $GATE_RC = 0 ] && [ -f $MARKER ]'
rm -f "$G/hub/tests/ünï.py"
gen '["hub/app.py","hub/tests/","outside.md"]' -
echo changed >> $G/outside.md
run_gate
check "in place, with no base: it diffs HEAD, so the step's uncommitted work is what counts" \
  '[ $GATE_RC = 0 ] && echo "$GATE_OUT" | grep -qx "DELEGATE-SCOPE: ok (3 changed paths)" && [ -f $MARKER ]'
git -C $G add -A && git -C $G -c user.name=t -c user.email=t commit -qm "work so far"
run_gate
check "…and a change already committed on top (an accepted in-place step) is not a violation" \
  '[ $GATE_RC = 0 ] && echo "$GATE_OUT" | grep -qx "DELEGATE-SCOPE: ok (0 changed paths)"'
gen '["hub/app.py","hub/tests/"]' no-such-base
run_gate
check "a base the repo does not have: it says so and exits 1, without running the verify" \
  '[ $GATE_RC = 1 ] && echo "$GATE_OUT" | grep -qx "DELEGATE-SCOPE: cannot find the base no-such-base" \
   && [ ! -e $MARKER ]'

# step 2's gate compares against the branch step 1 landed on, not against the chain base
git -C $G branch -f delegate/step-1 HEAD
echo "step 1 wrote this" > $G/src/step1.py; echo "and this" >> $G/hub/app.py
git -C $G add -A && git -C $G -c user.name=t -c user.email=t commit -qm "step 1" \
  && git -C $G branch -f delegate/step-1
git -C $G checkout -qb step-3 delegate/step-1; echo "step 2 changed this" >> $G/hub/tests/t.py
gen '["hub/tests/"]' delegate/step-1
run_gate
check "step 2's own change passes against its own base; step 1's files are not violations" \
  '[ $GATE_RC = 0 ] && echo "$GATE_OUT" | grep -qx "DELEGATE-SCOPE: ok (1 changed paths)" && [ -f $MARKER ]'
GATE_MB=$(cd $G && mb=$(git merge-base HEAD delegate/step-1) \
  && { git diff --name-only --no-renames "$mb"; git ls-files --others --exclude-standard; } | sort -u)
check "…and the changed set is that merge-base diff, which is what makes it true" \
  '[ "$GATE_MB" = "hub/tests/t.py" ]'

# 7. composition: what a scoped step's --verify looks like when the chain hands it over, and what
#    an unscoped step still gets (the plan's verify, byte for byte)
step_json() { # step_json NAME SPEC '<scope json>' → one step object ('' = no scope)
  local extra=""; [ -n "${3:-}" ] && extra=',"scope":'"$3"
  printf '{"name":"%s","spec":"%s","verify":"true"%s}' "$1" "$2" "$extra"; }
cplan() { # cplan '<steps json>' [retries]   (budget tests: no hard-model escalation round)
  printf '{"name":"c","repo":"%s","base":"main","retries":%s,"escalate":false,"steps":[%s]}\n' "$T/repo" "${2:-2}" "$1" > $T/plan.json; }
fresh() { rm -rf $DELEGATE_STATE; mkdir -p $DELEGATE_STATE; rm -f $SCRIPT/*.log; }
fresh; printf 'done\n' > $SCRIPT/a; printf 'done\n' > $SCRIPT/b
cplan "$(step_json a docs/specs/a.md '["hub/app.py"]'),$(step_json b docs/specs/b.md '')"
python3 $here/lib/chain.py $T/plan.json > $T/c7 2>&1; rc=$?
check "a scoped chain runs to the end" '[ $rc = 0 ] && [ -d $DELEGATE_STATE/repo-b/rounds/1 ]'
check "the --verify the run receives starts with the scope gate" \
  '[ "$(head -1 $DELEGATE_STATE/run-verify-a)" = "# delegate chain: this step'"'"'s scope gate (runs before the verify; it takes a second)" ] \
   && grep -q "^__dsc_re=" $DELEGATE_STATE/run-verify-a'
check "…and ends with the plan's verify" '[ "$(tail -1 $DELEGATE_STATE/run-verify-a)" = true ]'
check "…diffing the branch this step starts from (the plan base for step 1)" \
  "grep -q \"merge-base HEAD 'main'\" $DELEGATE_STATE/run-verify-a"
check "an unscoped step gets the plan's verify, unchanged and alone" \
  '[ "$(cat $DELEGATE_STATE/run-verify-b)" = "true" ]'
fresh; printf 'done\n' > $SCRIPT/a; printf 'done\n' > $SCRIPT/b
cplan "$(step_json a docs/specs/a.md '["hub/app.py"]'),$(step_json b docs/specs/b.md '["hub/"]')"
python3 $here/lib/chain.py $T/plan.json >/dev/null 2>&1
check "step 2's gate diffs the branch step 1 landed on, not the chain base" \
  "grep -q \"merge-base HEAD 'delegate/a'\" $DELEGATE_STATE/run-verify-b"
fresh; printf 'done-but-verify-failed\ndone\n' > $SCRIPT/a; printf 'done\n' > $SCRIPT/b
cplan "$(step_json a docs/specs/a.md '["hub/app.py"]')"
python3 $here/lib/chain.py $T/plan.json >/dev/null 2>&1; rc=$?
check "a retry continues with the same composed verify (gate first, plan's verify last)" \
  "[ $rc = 0 ] && grep -q '^__dsc_re=' $DELEGATE_STATE/continue-verify-a \
   && [ \"\$(tail -1 \$DELEGATE_STATE/continue-verify-a)\" = true ]"
check "and the plain verify failure still tells the worker to end blocked, not keep trying" \
  'grep -q "STATUS: blocked and state the contradiction" $DELEGATE_STATE/last-retry-a'
fresh; printf 'partial\ndone\n' > $SCRIPT/a; printf 'done\n' > $SCRIPT/b
cplan "$(step_json a docs/specs/a.md '')"
python3 $here/lib/chain.py $T/plan.json >/dev/null 2>&1
check "a partial retry message carries the same sentence" \
  'grep -q "STATUS: blocked and state the contradiction" $DELEGATE_STATE/last-retry-a'

# 8. the retry policy once the gate has refused: a plan bug stops at once, anything else gets one
#    targeted round, and the verify command behind it never ran
printf '# step a\n\n## Contract\n\nChange hub/missed.py, the module that pins the gate order.\n' > $T/repo/docs/specs/bug.md
plangate() { # the first step owns hub/app.py; its spec speaks of hub/missed.py without an owned bullet
  fresh; printf 'done-but-verify-failed\ndone\n' > $SCRIPT/a; printf 'done\n' > $SCRIPT/b
  printf '%s\n' 'DELEGATE-SCOPE: outside this step'"'"'s scope:' "DELEGATE-SCOPE:   $1" > $SCRIPT/a.log
  cplan "$(step_json a docs/specs/bug.md '["hub/app.py"]')"; }
plangate hub/missed.py
python3 $here/lib/chain.py $T/plan.json > $T/c8 2>&1; rc=$?
check "a gate failure on a path the spec names is a plan bug: exit 3, one round, no retry" \
  "[ \$rc = 3 ] && [ \$(grep -c . \$DELEGATE_STATE/calls) = 1 ] && ! grep -q continue \$DELEGATE_STATE/calls \
   && [ ! -d \$DELEGATE_STATE/repo-a/rounds/2 ]"
check "…and the message says the plan's scope is wrong and how to check it" \
  'grep -q "the plan.s scope is wrong" $T/c8 && grep -q "delegate chain .* --check" $T/c8'
check "…naming the path the gate refused" 'grep -q "the scope gate refused hub/missed.py" $T/c8'
plangate hub/other.py
python3 $here/lib/chain.py $T/plan.json > $T/c8b 2>&1; rc=$?
check "a gate failure on a path the spec does not name is retried in-session, once" \
  '[ $rc = 0 ] && [ "$(grep -c continue $DELEGATE_STATE/calls)" = 1 ]'
check "…and that message names the path, says it is outside scope, and to revert it" \
  'grep -q "hub/other.py" $DELEGATE_STATE/last-retry-a && grep -q "outside this step.s scope:" $DELEGATE_STATE/last-retry-a \
   && grep -q "Revert them" $DELEGATE_STATE/last-retry-a'
check "…and tells the worker to end blocked if the spec does require that file" \
  'grep -q "if it does, end with STATUS: blocked" $DELEGATE_STATE/last-retry-a'
check "…which counts against the retry budget: the rounds after it are not unlimited" \
  '[ -d $DELEGATE_STATE/repo-a/rounds/2 ] && [ ! -d $DELEGATE_STATE/repo-a/rounds/3 ]'
plangate hub/other.py
printf 'done-but-verify-failed\ndone-but-verify-failed\ndone-but-verify-failed\n' > $SCRIPT/a
python3 $here/lib/chain.py $T/plan.json > $T/c8c 2>&1; rc=$?
check "the gate does not excuse a step that keeps failing: the budget ends it, exit 3" \
  '[ $rc = 3 ] && [ -d $DELEGATE_STATE/repo-a/rounds/3 ] && [ ! -d $DELEGATE_STATE/repo-a/rounds/4 ] \
   && ! grep -q "scope is wrong" $T/c8c'

# 9. --check lints and stops there; --status, --clean and --wait do not lint at all
fresh; lplan lintmiss "[\"hub/app.py\",\"lib/router.py\",\"lib/params.py\",\"hub/tests/\",\"docs/specs/\",\"tmp/cache/\",\"src/fixtures/new/\",\"lib/contract_item.md\"]"
python3 $here/lib/chain.py $T/plan.json --check --on-step 'touch /step-ran' --on-done 'touch /done-ran' > $T/l9 2>&1; rc=$?
check "--check fires no hook, even when one is given" "[ $rc = 2 ] && [ ! -e /step-ran ] && [ ! -e /done-ran ]"
python3 $here/lib/chain.py $T/plan.json --status > $T/l9b 2>&1; rc=$?
check "--status reads a plan whose lint misses, as before" \
  '[ $rc = 0 ] && grep -q "^chain lintmiss" $T/l9b && grep -q "not started" $T/l9b'
python3 $here/lib/chain.py $T/plan.json --clean > $T/l9c 2>&1; rc=$?
check "…and so does --clean" '[ $rc = 0 ]'
python3 $here/lib/chain.py $T/plan.json --wait --interval 0.1 --timeout 0.2 > $T/l9d 2>&1; rc=$?
check "…and so does --wait (it reports the chain, it does not lint it)" '[ $rc = 3 ] && grep -q "chain lintmiss" $T/l9d'

# 10. in place: the gate diffs the step's own HEAD (its changes are uncommitted by design)
fresh; printf 'done\n' > $SCRIPT/a; printf 'done\n' > $SCRIPT/b
git -C $T/repo add -A && git -C $T/repo -c user.name=t -c user.email=t commit -qm "specs"   # in place starts clean
printf '{"name":"h","repo":"%s","here":true,"retries":1,"steps":[{"name":"a","spec":"docs/specs/a.md","verify":"true","scope":["hub/app.py"]}]}' "$T/repo" > $T/hplan.json
EDIT=$T/repo/work.txt python3 $here/lib/chain.py $T/hplan.json > $T/h10 2>&1; rc=$?
check "an in-place scoped step gets the gate too" \
  "[ \$rc = 0 ] && grep -q '^__dsc_re=' \$DELEGATE_STATE/run-verify-a && [ \"\$(tail -1 \$DELEGATE_STATE/run-verify-a)\" = true ]"
check "…and it diffs HEAD, with no merge-base and no --base" \
  'grep -q "^__dsc_from=HEAD$" $DELEGATE_STATE/run-verify-a && ! grep -q merge-base $DELEGATE_STATE/run-verify-a \
   && ! grep -q delegate/step-1 $DELEGATE_STATE/run-verify-a'

# 11. reports and logs show the gate as "[scope gate]", the plan's verify as written
fresh; printf 'done\n' > $SCRIPT/a
cplan "$(step_json a docs/specs/a.md '["hub/app.py"]')"
python3 $here/lib/chain.py $T/plan.json >/dev/null 2>&1
check "the gate's last line is the end marker, right before the plan's verify" \
  '[ "$(tail -2 $DELEGATE_STATE/run-verify-a | head -1)" = "# delegate chain: end of the scope gate" ]'
shown_py=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/lib"); import report; print(report.shown_verify(open(sys.argv[2]).read()))' "$here" $DELEGATE_STATE/run-verify-a)
check "report: a gated verify is shown as [scope gate] plus the plan's verify" '[ "$shown_py" = "[scope gate] true" ]'
check "report: a verify without a gate is shown unchanged" \
  '[ "$(python3 -c "import sys; sys.path.insert(0, \"$here/lib\"); import report; print(report.shown_verify(\"make test\"))")" = "make test" ]'
check "report: a user verify that merely contains the marker text is left alone" \
  '[ "$(python3 -c "import sys; sys.path.insert(0, \"$here/lib\"); import report; print(report.shown_verify(\"echo hi\n# delegate chain: end of the scope gate\nmake\"))" | head -1)" = "echo hi" ]'
eval "$(sed -n '/^verify_shown()/,/^}/p' $here/bin/delegate)"
check "bin/delegate: notes and verify.log show the same short form" \
  '[ "$(verify_shown "$(cat $DELEGATE_STATE/run-verify-a)")" = "[scope gate] true" ] && [ "$(verify_shown "make test")" = "make test" ]'
# 12. `delegate continue` on a chain step takes the plan's current verify (scope edits included),
#     the same one a chain retry passes with --verify; without a chain or a step it keeps its own
eval "$(sed -n '/^chain_step_verify()/,/^}/p' $here/bin/delegate)"
DELEGATE_HOME=$here CHAIN=c SLUG=a BASE_REF=main HERE=0
now=$(chain_step_verify); rc=$?
check "continue: a chain step's verify is the one the chain handed it" \
  '[ $rc = 0 ] && [ "$now" = "$(cat $DELEGATE_STATE/run-verify-a)" ]'
cplan "$(step_json a docs/specs/a.md '["hub/app.py","hub/tests/test_install.py"]')"
now=$(chain_step_verify); rc=$?
check "continue: a scope edited in the plan reaches the next continue" \
  '[ $rc = 0 ] && printf "%s\n" "$now" | grep -q "hub/tests/test_install" && [ "$now" != "$(cat $DELEGATE_STATE/run-verify-a)" ]'
check "…and diffs from the base the task was started on" 'printf "%s\n" "$now" | grep -q "merge-base HEAD '"'"'main'"'"'"'
now=$(HERE=1 chain_step_verify)
check "…or from HEAD for an in-place step" 'printf "%s\n" "$now" | grep -q "^__dsc_from=HEAD$"'
now=$(SLUG=gone chain_step_verify); rc=$?
check "continue: a step the plan no longer has keeps the recorded verify (fails, prints nothing)" '[ $rc != 0 ] && [ -z "$now" ]'
now=$(CHAIN=nochain chain_step_verify); rc=$?
check "continue: no chain state keeps the recorded verify" '[ $rc != 0 ] && [ -z "$now" ]'
cont=$(sed -n '/^cmd_continue()/,/^}/p' $here/bin/delegate)
check "continue: an explicit --verify still wins (the refresh is only in the no---verify branch)" \
  'printf "%s\n" "$cont" | awk "/verify_set\" = 1/{a=1} a&&/else/{b=1} b&&/chain_step_verify/{print; exit}" | grep -q chain_step_verify'
exit $fail
