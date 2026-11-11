#!/bin/bash
# What `delegate top` (lib/taskstate.py) says about fabricated state dirs: the states a round can
# be in, the frame it prints, the command it names to resume an interrupted one, and the Claude
# leads above it. No docker, no model, no network.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DELEGATE_STATE=$T/state XDG_CACHE_HOME=$T/cache DELEGATE_CONFIG=$T/none.env
mkdir -p $DELEGATE_STATE $XDG_CACHE_HOME/claude-agent-progress
ts() { python3 "$here/lib/taskstate.py" "$@"; }
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# one round's events.jsonl: 2 steps, 3 tool calls (one failed), a plan, 1200 tokens out,
# 1400 input + 400 cached, last action a failed `make test`
cat > $T/ev.py <<'PY'
import json
E = [{"type": "step_finish", "part": {"tokens": {"output": 700, "input": 1200, "cache": {"read": 300}}, "reason": "stop"}},
     {"type": "tool_use", "part": {"id": "a", "tool": "read", "state": {"status": "completed", "input": {"filePath": "/tmp/x"}}}},
     {"type": "tool_use", "part": {"id": "p", "tool": "todowrite", "state": {"status": "completed", "input":
        {"todos": [{"content": "write the parser", "status": "completed"},
                  {"content": "wire the CLI", "status": "in_progress"},
                  {"content": "test it", "status": "pending"}]}}}},
     {"type": "tool_use", "part": {"id": "c", "tool": "bash", "state": {"status": "error", "error": "boom", "input": {"command": "make test"}}}},
     {"type": "step_finish", "part": {"tokens": {"output": 500, "input": 200, "cache": {"read": 100}}, "reason": "stop"}}]
print("\n".join(json.dumps(e) for e in E))
PY

mk() { # ID KIND   kind: lock | verify | none | report | report-old
  local id=$1 kind=$2 d=$DELEGATE_STATE/$1
  mkdir -p "$d/rounds/1"
  printf 'ID=%s\nSLUG=%s\nREPO=%s\nWORKTREE=/tmp/wt/%s\nBRANCH=delegate/%s\nMODEL=m\nRUNNER=docker\nEGRESS=filtered\nVERIFY=true\nGRANTS=lan-print\nALLOW=flash\nHERE=0\nRAW=0\n' \
    "$id" "$id" "$T/repo" "$id" "$id" > "$d/meta.env"
  echo spec > "$d/rounds/1/prompt.md"
  python3 $T/ev.py > "$d/rounds/1/events.jsonl"
  case "$kind" in
    lock)   mkdir -p "$d/lock" ;;
    verify) mkdir -p "$d/lock"; echo '$ true' > "$d/rounds/1/verify.log" ;;
    report|report-old)
      printf '{"status":"done","steps":2,"tool_calls":4,"tool_errors":["bash: boom"],"output_tokens":1200,"final_context_tokens":1600,"duration_s":423}\n' \
        > "$d/rounds/1/report.json"
      echo '$ true' > "$d/rounds/1/verify.log"
      [ "$kind" = report-old ] && touch -d '3 days ago' "$d/rounds/1/events.jsonl" "$d/rounds/1/verify.log" "$d/rounds/1/report.json" ;;
  esac
}
mk t-run lock; mk t-ver verify; mk t-int none; mk t-done report; mk t-old report-old
mkdir -p $DELEGATE_STATE/chains
printf '{"name":"w4","plan":"%s/plan.json","steps":{"w4a":{"status":"partial","rounds":1}}}\n' "$T" > $DELEGATE_STATE/chains/w4.json
mk repo-w4a none

# ------------------------------------------------------------------ the states ----------
check "a locked round with no report is running"        '[ "$(ts status t-run)" = running ]'
check "a newer verify.log makes it verifying"           '[ "$(ts status t-ver)" = verifying ]'
check "no lock and no report is interrupted"            '[ "$(ts status t-int)" = interrupted ]'
check "a finished round shows its report status"        '[ "$(ts status t-done)" = done ]'
check "a task with no rounds is new"                    'mkdir -p $DELEGATE_STATE/t-new; touch $DELEGATE_STATE/t-new/meta.env; [ "$(ts status t-new)" = new ]'
check "delegate list says the same states"             '"$here/bin/delegate" list > $T/list && grep -q interrupted $T/list && grep -q verifying $T/list && grep -q running $T/list'
check "statuses TSV carries id, round, state, worktree" 'ts statuses | grep -q "^t-int	1	interrupted	/tmp/wt/t-int$"'
# ---------------------------------------------------------------- the numbers it shows ----
j() { ts json "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1]))' "$2"; }
check "steps, tool calls and failures from the events"  '[ "$(j t-run steps)" = 2 ] && [ "$(j t-run tool_calls)" = 3 ] && [ "$(j t-run tool_errors)" = 1 ]'
check "tokens out, and in (fresh plus cache reads)"     '[ "$(j t-run output_tokens)" = 1200 ] && [ "$(j t-run input_tokens)" = 1800 ]'
check "from the report once the round is over"          '[ "$(j t-done steps)" = 2 ] && [ "$(j t-done input_tokens)" = 1600 ] && [ "$(j t-done tool_errors)" = 1 ]'
check "the current todo item is the in-progress one"    '[ "$(j t-run todo)" = "wire the CLI" ]'
check "last action, one line, failed marked"            'j t-run last_action | grep -q "make test"'
check "the mode label: runner, egress, grants, allow"   'j t-run mode | grep -q "docker/filtered +lan-print !flash"'
check "elapsed for a finished round is its duration"    '[ "$(j t-done elapsed)" = 423.0 ]'
check "an interrupted round has a finish command"       '[ "$(j t-int resume)" = "delegate finish t-int" ]'
check "a chained step resumes with its chain's plan"    '[ "$(j repo-w4a chain)" = w4 ] && [ "$(j repo-w4a resume)" = "delegate chain $T/plan.json" ]'
# --------------------------------------------------------- the frame one --once prints ------
E=$(printf '\033')                                # one escape byte, for the colour checks
out=$(COLUMNS=120 "$here/bin/delegate" top --once 2>&1); rc=$?
check "top --once exits 0"                              '[ $rc = 0 ]'
check "it names every visible task"                     'for i in t-run t-ver t-int t-done repo-w4a; do grep -q "$i" <<<"$out" || exit 1; done'
check "a task finished 3 days ago is hidden"            '! grep -q t-old <<<"$out"'
check "and the header says one was hidden"              'grep -q "1 finished >24h hidden" <<<"$out"'
check "--all shows it anyway"                           'COLUMNS=120 "$here/bin/delegate" top --once --all | grep -q t-old'
check "running, verifying and interrupted are counted"  'grep -q "1 running" <<<"$out" && grep -q "1 verifying" <<<"$out" && grep -q "2 interrupted" <<<"$out"'
check "an interrupted task prints its finish command"   'grep -q "interrupted: t-int -> delegate finish t-int" <<<"$out"'
check "a chained one prints its chain plan instead"     'grep -q "interrupted: repo-w4a -> delegate chain $T/plan.json" <<<"$out"'
check "chained steps group under the chain"             'grep -q "^  w4 (0/1 done) $T/plan.json" <<<"$out"'
check "colour is off by default when piped"             '! grep -q "$E" <<<"$out"'
maxw() { python3 -c 'import sys, unicodedata
print(max(sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in l)
          for l in open(sys.argv[1]).read().splitlines()))' "$1"; }
for w in 60 80 200; do
  check "nothing runs past a ${w} column terminal" \
    "COLUMNS=$w \"$here/bin/delegate\" top --once > $T/w$w; [ \"\$(maxw $T/w$w)\" -le $w ]"
done
timeout 25 "$here/bin/delegate" top 2>&1 | cat > $T/pipe         # a pipe, no --once: it must end
check "piped without --once prints one frame and exits" '[ -s $T/pipe ] && ! grep -qF "${E}[2J" $T/pipe'
check "no cursor-hiding escape without a tty"           '! grep -qF "${E}[?25l" $T/pipe'
"$here/bin/delegate" top --interval bogus --once >/dev/null 2>$T/e; rc=$?
check "a bad --interval is refused with exit 2"         '[ $rc = 2 ] && grep -q number $T/e'
"$here/bin/delegate" top NOSUCH --once >/dev/null 2>$T/e; rc=$?
check "an unknown id is an error, not an empty screen"  '[ $rc = 1 ] && grep -q "no such task" $T/e'

# ----------------------------------------------------------------------- colour -------------
COLUMNS=120 "$here/bin/delegate" top --once --color > $T/c1
NO_COLOR=1 COLUMNS=120 "$here/bin/delegate" top --once --color > $T/c2
check "--color forces colour onto a pipe"               'grep -q "$E\[" $T/c1'
check "NO_COLOR beats --color"                          '! grep -q "$E" $T/c2'

# ------------------------------------------- the Claude leads, and what is nested under them -
python3 - "$XDG_CACHE_HOME/claude-agent-progress/aaaa.json" <<'PY'
import json, sys, time
json.dump({"desc": "spec writer", "phase": "delegating", "started_at": time.time() - 900,
           "last_post": time.time(), "tool_calls": 9, "tool_errors": 0, "todos": [], "recent": [],
           "children": ["task:t-run", "task:t-done"],
           "usage": {"input": 5000, "cache_read": 60000, "output": 4100}}, open(sys.argv[1], "w"))
PY
check "the lead is named, with its own tokens"          'ts top --once | grep -q "spec writer" && ts top --once | grep -q "4.1k out / 65.0k in"'
check "its workers are matched by task id"              'ts leads | awk -F"\t" "{exit (\$6==2400 && \$7==2) ? 0 : 1}"'
check "which is what the frame shows too"               'ts top --once | grep -q "2 task(s) 2.4k out"'
check "top ID peeks at that one task"                   '"$here/bin/delegate" top t-run --once | grep -q "t-run"'
check "and names the Claude lead that started it"       '"$here/bin/delegate" top t-run --once | grep -q "started by Claude agent spec writer"'
check "and its chain, for a chain step"                 '"$here/bin/delegate" top repo-w4a --once | grep -q "chain w4"'
check "and says how to resume it when it was cut off"   '"$here/bin/delegate" top t-int --once | grep -q "delegate finish t-int"'
check "quarantined tasks are not listed"                'mkdir -p $DELEGATE_STATE/quarantine && mv $DELEGATE_STATE/t-ver $DELEGATE_STATE/quarantine/ && ! ts statuses | grep -q t-ver'
check "nor is the chains dir itself a task"             '! ts statuses | grep -qE "^(chains|locks|quarantine)	"'
check "a CHAIN in meta.env names the chain and its plan" \
  'printf "CHAIN=w4\n" >> $DELEGATE_STATE/t-run/meta.env && [ "$(j t-run chain)" = w4 ] && [ "$(j t-run chain_plan)" = "$T/plan.json" ]'

leadchk() { # NAME OUT IN NTASKS: one line of `leads`, the numeric fields compared
  ts leads | python3 -c '
import sys
name, out, inp, n = sys.argv[1:]
rows = [l.split("\t") for l in sys.stdin.read().splitlines()]
r = [x for x in rows if x[0] == name]
sys.exit(0 if r and (int(r[0][3]), int(r[0][4]), int(r[0][6])) == (int(out), int(inp), int(n)) else 1)
' "$1" "$2" "$3" "$4"
}

# ------------------------------------------------------------------ the tree ----------------
# A second lead, which started a chain rather than single tasks: its steps belong under IT, not in
# a flat Chains section, and the work no lead claimed has to be visibly somebody else's.
printf '{"name":"w9","plan":"%s/plan9.json","steps":{}}\n' "$T" > $DELEGATE_STATE/chains/w9.json
python3 - "$T/plan9.json" <<'PY'
import json, sys
json.dump({"repo": "/srv/repos/api", "steps": [{"name": "add-auth", "spec": "specs/auth.md", "verify": "make test"}]},
          open(sys.argv[1], "w"))
PY
mk api-add-auth none                                     # and its meta.env says nothing about w9
python3 - "$XDG_CACHE_HOME/claude-agent-progress/cccc.json" <<'PY'
import json, sys, time
json.dump({"desc": "chain driver", "phase": "working", "started_at": time.time() - 130,
           "last_post": time.time(), "children": ["chain:w9"],
           "usage": {"output_tokens": 3000000, "input_tokens": 900000,
                     "cache_read_input_tokens": 8700000}}, open(sys.argv[1], "w"))
PY
ts top --once > $T/tree
ln_() { grep -n -- "$1" $T/tree | head -1 | cut -d: -f1; }
check "a step of a lead's chain is placed from its plan, with no CHAIN in meta.env" \
  '[ "$(j api-add-auth chain)" = w9 ] && [ "$(j api-add-auth chain_plan)" = "$T/plan9.json" ]'
check "the lead's row comes before its chain"           '[ "$(ln_ "chain driver")" -lt "$(ln_ "  w9 (")" ]'
check "and the step is indented under the chain"        '[ "$(ln_ "  w9 (")" -lt "$(ln_ "^    .*api-add-auth")" ]'
check "a chain step is shown once: not again directly under its lead" \
  '! grep -q "^  [a-z-]* *api-add-auth" $T/tree && grep -q "^    .*api-add-auth" $T/tree'
check "and its lead counts it once"                     'grep -A1 "chain driver" $T/tree | grep -q "1 task(s) 1.2k out"'
check "a lead's own tasks are indented under its row"   '[ "$(ln_ "spec writer")" -lt "$(ln_ "  t-run")" ]'
check "work no lead claimed sits under its own heading" \
  '[ "$(ln_ "chain driver")" -lt "$(ln_ "Not started by a lead")" ] && [ "$(ln_ "Not started by a lead")" -lt "$(ln_ "  t-int")" ]'
check "the frame says how many leads there are"         'grep -qE "2 lead\(s\) ·" $T/tree'
check "a lead header line shares the task rows' columns" \
  'python3 - $T/tree "spec writer" "t-run" <<P
import sys
path, name, tid = sys.argv[1:]
ls = open(path).read().splitlines()
lead = next(l for l in ls if name in l)
task = next(l for l in ls if l.startswith("  ") and tid in l.split()[:3])
sys.exit(0 if lead.index(name) + len(task) - len(task.lstrip(" ")) == task.index(tid) and lead == lead.lstrip(" ") else 1)
P'

# ---------------------------------------------- a lead's tokens, in whatever shape it wrote -
check "the raw API names, with cache reads counted as input" 'leadchk "chain driver" 3000000 9600000 1'
check "millions print as M and not as 9600k"            'ts top --once | grep -q "3.0M out / 9.6M in"'
python3 - "$XDG_CACHE_HOME/claude-agent-progress/dddd.json" <<'PY'
import json, sys, time
json.dump({"desc": "flat tokens", "phase": "waiting", "started_at": time.time() - 60,
           "last_post": time.time(), "children": [],
           "output": 812, "input": 1900, "cache_read": 900}, open(sys.argv[1], "w"))
PY
check "or flat on the state file itself, with no usage dict" 'leadchk "flat tokens" 812 2800 0'
check "a lead with nothing under it still gets a row"   'ts top --once | grep -q "flat tokens" && ts top --once | grep -q "0 task(s) 0 out"'

# ------------------------------------------------------- a lead that stopped posting to it ---
python3 - "$XDG_CACHE_HOME/claude-agent-progress/eeee.json" <<'PY'
import json, sys, time
now = time.time()
json.dump({"desc": "gone quiet", "phase": "working", "started_at": now - 5000,
           "last_post": now - 2400, "children": ["task:t-int"]}, open(sys.argv[1], "w"))
PY
python3 - "$XDG_CACHE_HOME/claude-agent-progress/ffff.json" <<'PY'
import json, sys, time
json.dump({"desc": "wrapped up", "phase": "finished", "started_at": time.time() - 9000,
           "last_post": time.time() - 5000, "usage": {"output": 1200}}, open(sys.argv[1], "w"))
PY
touch -d '40 minutes ago' $XDG_CACHE_HOME/claude-agent-progress/eeee.json     # a dead process writes nothing
touch -d '83 minutes ago' $XDG_CACHE_HOME/claude-agent-progress/ffff.json
COLUMNS=200 ts top --once > $T/stale
check "a working lead silent 40 min reads stale, not working" \
  'grep -q "stale? *gone quiet" $T/stale && ! grep -q "working *gone quiet" $T/stale'
check "and says how long since it last posted"          'grep -q "quiet 40m" $T/stale'
check "a lead finished an hour ago is not shown"        '! grep -q "wrapped up" $T/stale'
check "the count line says a lead was hidden"           'grep -q "1 finished lead(s) hidden" $T/stale'
check "--all shows the finished lead too"               'COLUMNS=200 ts top --once --all | grep -q "wrapped up"'
mv $DELEGATE_STATE/t-int $DELEGATE_STATE/quarantine/
check "the stale lead is still shown after its task went" 'ts top --once | grep -q "stale? *gone quiet"'
check "with nothing left under it, and a hint why"      \
  'COLUMNS=200 ts top --once > $T/gone; grep -q "0 task(s) 0 out · quiet 40m" $T/gone && grep -q "may have died" $T/gone'
python3 - "$XDG_CACHE_HOME/claude-agent-progress/eeee.json" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1])); d["last_post"] = time.time() - 90000; json.dump(d, open(sys.argv[1], "w"))
PY
touch -d '25 hours ago' $XDG_CACHE_HOME/claude-agent-progress/eeee.json
check "and one silent for a day is gone from the view"  '! ts leads | grep -q "gone quiet"'
python3 - "$XDG_CACHE_HOME/claude-agent-progress/gggg.json" <<'PY'
import json, sys, time
json.dump({"desc": "second claim", "phase": "waiting", "started_at": time.time() - 30,
           "last_post": time.time(), "children": ["task:t-run", "task:nosuch-here"]}, open(sys.argv[1], "w"))
PY
check "a task already shown under another lead is not shown twice" \
  'COLUMNS=200 ts top --once > $T/claim; [ "$(grep -c "  t-run" $T/claim)" = 1 ]'
check "and its own row says what is actually under it, not what it once started" \
  'grep -A1 "second claim" $T/claim | grep -q "0 task(s) 0 out"'

# ------------------------------------------------------------------ broken inputs ----------
b=$DELEGATE_STATE/t-broken; mkdir -p $b/rounds/1; : > $b/meta.env          # meta.env with nothing in it
echo 'not json at all' > $b/rounds/1/events.jsonl
echo '{"status": cor' > $b/rounds/1/report.json
check "an unreadable meta.env and events still give a state" '[ -n "$(ts status t-broken)" ]'
big=$DELEGATE_STATE/t-big; mkdir -p $big/rounds/1
{ python3 -c 'print("{\"type\":\"text\",\"part\":{\"text\":\"x\"}}" * 400)'; \
  head -c 9000000 /dev/zero | tr "\0" " "; echo; \
  python3 /dev/stdin <<'PY'
import json
print(json.dumps({"type": "tool_use", "part": {"id": "z", "tool": "bash", "state": {"status": "completed", "input": {"command": "tail of the log"}}}}))
PY
} > $big/rounds/1/events.jsonl
printf 'ID=t-big\nWORKTREE=/tmp\n' > $big/meta.env; mkdir -p $big/lock
check "a 9 MB event log is read from its tail, not all of it" \
  '[ "$(ts status t-big)" = running ] && j t-big last_action | grep -q "tail of the log"'
check "a missing state dir is an empty view, not a crash" \
  'DELEGATE_STATE=$T/nowhere ts top --once | grep -q "0 task(s)"'
check "a lead file that is not JSON is skipped" \
  'echo "{oops" > $XDG_CACHE_HOME/claude-agent-progress/bbbb.json && ts leads | grep -q "spec writer" && ! ts leads | grep -q bbbb'
check "empty NO_COLOR does not turn colour off"  'NO_COLOR= COLUMNS=120 "$here/bin/delegate" top --once --color | grep -q "$E\["'
check "a task with no rounds peeks as such"      'mkdir -p $DELEGATE_STATE/t-norounds && touch $DELEGATE_STATE/t-norounds/meta.env && "$here/bin/delegate" top t-norounds --once | grep -q "no rounds yet"'

# wide glyphs: a worker's plan in CJK must not overflow the frame (the width is measured in terminal columns, not characters)
w=$DELEGATE_STATE/t-cjk; mkdir -p $w/rounds/1
printf 'ID=t-cjk\nWORKTREE=/tmp/wt/t-cjk\nRUNNER=docker\n' > $w/meta.env; echo s > $w/rounds/1/prompt.md
python3 -c 'import json;print(json.dumps({"type":"tool_use","part":{"id":"t","tool":"todowrite","state":
  {"status":"completed","input":{"todos":[{"content":"实现登录页面并加测试 🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉","status":"in_progress"}]}}}}))' \
  > $w/rounds/1/events.jsonl
COLUMNS=80 "$here/bin/delegate" top --once > $T/wide
check "a wide-glyph plan stays inside the frame" \
  'python3 - "$T/wide" <<P
import sys, unicodedata
w = lambda s: sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
bad = [l for l in open(sys.argv[1]).read().splitlines() if w(l.replace("\x1b[0m","").replace("\x1b[31m","").replace("\x1b[32m","").replace("\x1b[36m","").replace("\x1b[2m","")) > 80]
sys.exit(1 if bad else 0)
P'
check "and at a wider terminal it is shown, clipped not dropped" \
  'COLUMNS=120 "$here/bin/delegate" top --once > $T/wide2; grep -q "实现登录" $T/wide2 && [ "$(maxw $T/wide2)" -le 120 ]'

exit $fail
