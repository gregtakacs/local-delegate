#!/bin/bash
# T2-F: what the ledger keeps of finished work (docs/specs/t2-forensics.md). Round rows at
# schema 3 carry `todos` (the plan's items from the final todo write) and `worker_report`
# (the worker's §13 closing block, parsed); every `delegate chain` RUN ends with one
# kind:"chain" row, written by lib/chain.py, whatever the outcome and even under SIGTERM.
# Neither row may carry tool payloads, commands or diffs; a failing append never changes an
# outcome. No docker, no model, no network: the round lifecycle is stubbed at the function
# boundary like test_ledger_round.sh does, and the chain's steps run on test_chain.sh's fake
# delegate. Everything lands in a temp DELEGATE_STATE / ledger — never the real ones.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DELEGATE_CONFIG=$T/none.env
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
VERSION=$(sed -n 's/^VERSION=//p' "$here/bin/delegate" | head -1)

# ------------------------------------------------------------- the round fixture ----
S=$T/state; TD=$S/task; L=$T/led/events.jsonl
mkdir -p "$S" "$TD/rounds" "$T/led" "$T/repo"
export DELEGATE_STATE=$S DELEGATE_LEDGER=$L
printf '# fixture spec\nwrite forensic rows\n' > "$TD/spec.md"
{ printf 'ID=%q\nSLUG=%q\nREPO=%q\nWORKTREE=%q\nBRANCH=%q\n' \
    task-f task-f "$T/repo" "$T/wt" delegate/task-f
  printf 'BASE_REF=%q\nBASE_SHA=%q\nGIT_COMMON=\nMODEL=%q\nVERIFY=\n' main abc1234 stub-model
  printf 'SERVICE=\nCOPIED=\nSESSION=\nCREATED=%q\nWT_GITDIR=\n' 2026-01-01T00:00:00+00:00
  printf 'READS=\nGITHUB=0\nEGRESS=%q\nHERE=0\nRUNNER=native\nRAW=0\n' filtered
  printf 'ORB_FILE=\nORB_LABEL=\nORB_BASE_MAC=\nORB_SERIAL=\nORB_IP=\nORB_FLASH=0\n'
  printf 'GRANTS=\nALLOW=\nCHAIN=\nEFFORT=hard\n'
  printf 'ORCH=opencode\nORCH_SESSION=ses_forensic\n'; } > "$TD/meta.env"
RL=$T/rules; mkdir -p "$RL/rules" "$RL/plugins"
printf 'rule one\n' > "$RL/rules/one.md"
printf '// plugin\n' > "$RL/plugins/two.js"
printf 'core rules\n' > "$RL/delegate-rules.md"
export DELEGATE_RULES_DIR=$RL DELEGATE_HOME=$here
export DELEGATE_CHUNK_CAP=8000 DELEGATE_TIMEOUT=5400 DELEGATE_RUNNER=native
export DELEGATE_IMAGE=delegate-worker:fixture DELEGATE_T=$T
export ID=task-f SLUG=task-f REPO=$T/repo WORKTREE=$T/wt BRANCH=delegate/task-f
export BASE_REF=main BASE_SHA=abc1234 MODEL=stub-model RUNNER=native HERE=1 RAW=0
export BASE_URL=https://gw.example.internal/v1 TASK_DIR=$TD

# the functions under test, extracted whole from bin/delegate (test_ledger_round.sh's set)
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
ledger_warn() { warn "warn: ledger $1: $2"; }
phase() { :; }
aborted() { return 1; }
snapshot() { echo deadbeef; }
wgit() { case "$1" in
           diff) echo ' 2 files changed, 10 insertions(+), 2 deletions(-)' ;;
           rev-parse) echo deadbeef ;;
         esac; return 0; }
check_gitlink() { return 0; }
grant_unlock() { return 0; }
grants_file() { printf '%s/grants.json' "$TASK_DIR"; }
grants_py() { return 0; }
reap_leftovers() { return 0; }
run_limited() { return 0; }
progress_stop() { echo PROGRESS-STOP >> "$DELEGATE_T/stop.log" 2>/dev/null; return 7; }
STUBS
  for f in ledger_resolve ledger_meta_fields ledger_append ledger_rules_hash \
           ledger_parallel_rounds ledger_record_round finalize_round; do
    extract "$f"
  done
} > "$T/driver.sh"
grep -q 'finalize_round() {' "$T/driver.sh" || { echo "FAIL extraction found no finalize_round"; exit 1; }

# the five fixture rounds' events, written by one generator that check.py re-reads, so the
# expectations and the stream cannot drift apart. Every canary below must stay out of the
# rows: SECRET* markers sit in tool inputs/outputs (R4), and canaryFILES/VERIFIED/EVIDENCE
# text sits in the closing block's two unpreserved sections plus the EVIDENCE heading.
cat > "$T/gen.py" <<'GEN'
import json, os, sys
rd = os.path.join(os.environ["TASK_DIR"], "rounds")
todos2 = [{"content": "implement the parser", "status": "completed"},
          {"content": "write the suite", "status": "in_progress"}]
text1 = ("Work is done.\n\nSTATUS: done\n\n"
         "FILES: canaryFILEStaskf-py, canaryFILESmore\n"
         "VERIFIED: canaryVERIFIEDpytest -q\n"
         "NOT VERIFIED:\n- first unverified item\n- second unverified item\n"
         "EVIDENCE: canaryEVIDENCEnoise.png\n"
         "DEVIATIONS: one inline clause deviation\n"
         "DECISIONS:\n- caps live in the schema owner\n"
         "OMISSIONS: none\nSUGGESTIONS:\nnone\nQUESTIONS: none\n")

def ev(fn, st):
    return {"type": "tool_use", "timestamp": 3500,
            "part": {"type": "tool", "tool": fn, "callID": "c1", "id": "c1",
                     "state": {"status": "completed", "input": "SECRETINPUT",
                               "output": "SECRETOUTPUT", "time": {"start": 3400, "end": 4800}}}}

def write(n, events):
    d = os.path.join(rd, str(n)); os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "events.jsonl"), "w") as f:
        for e in events:
            f.write(json.dumps(e) + "\n")
    open(os.path.join(d, "verify.log"), "w").close()
    open(os.path.join(d, "stderr.log"), "w").close()

def text(t, ts=9000):
    return {"type": "text", "timestamp": ts, "part": {"type": "text", "text": t}}

def todo(todos, ts=3000):
    return {"type": "tool_use", "timestamp": ts,
            "part": {"type": "tool", "tool": "todowrite", "callID": "t1", "id": "t1",
                     "state": {"status": "completed", "input": {"todos": todos},
                               "time": {"start": ts, "end": ts}}}}

def finish(ts=9500):
    return {"type": "step_finish", "timestamp": ts,
            "part": {"type": "step-finish",
                     "tokens": {"input": 10, "output": 5, "reasoning": 0,
                                "cache": {"read": 0, "write": 0}}, "reason": "end-turn"}}

# round 1: the full §13 block, a two-item todo write, planted payload markers
write(1, [{"type": "step_start", "timestamp": 1000, "part": {"type": "step-start"}},
          finish(3000), todo(todos2), ev("bash", "run"), text(text1), finish()])
# round 2: no STATUS line at all -> worker_report null; todos present
write(2, [todo([{"content": "only item", "status": "pending"}]),
          text("All shipped, I think. No closing block this round."), finish()])
# round 3: a STATUS block, no todo write -> todos null
write(3, [text("STATUS: blocked\n\nQUESTIONS: need the owner to pick a schema\n"), finish()])
# round 4: 60 todos, one 500 chars long -> the row keeps 50, cut to 200
big = "L" * 500
todos4 = [{"content": ("big item " + big) if i == 3 else f"todo item number {i}",
           "status": "completed" if i % 3 == 0 else "pending"} for i in range(60)]
write(4, [todo(todos4), text("STATUS: done\n\nFILES: none\n"), finish()])
# round 5: 25 omission lines and a 400-char deviation -> the row keeps 20, cut to 300
omits = "\n".join(f"- omission number {i}" for i in range(1, 26))
write(5, [text("STATUS: partial\n\nDEVIATIONS: " + "D" * 400 + "\nOMISSIONS:\n" + omits + "\n"),
          finish()])
json.dump({"todos2": todos2, "todos4": todos4, "text1": text1},
          open(os.path.join(os.environ["DELEGATE_T"], "expect.json"), "w"))
GEN
python3 "$T/gen.py" || { echo "FAIL fixture events could not be generated"; exit 1; }

finish() { . "$T/driver.sh"; finalize_round "$1" "$TD/rounds/$1" "" 0 \
             "$(( $(date +%s) - 60 ))" "$(( $(date +%s) - 6 ))"; }
for n in 1 2 3 4 5; do finish "$n" >/dev/null 2>"$T/err$n"; check "round $n returns the sentinel 7" '[ "$?" = 7 ]'; done
check "five rounds wrote ten rows, no warnings" \
  '[ "$(grep -c "" "$L")" = 10 ] && ! grep -q "warn: ledger" "$T"/err[1-5]'
# ------------------------------------------------------------------ the checks ----
cat > "$T/check.py" <<'CHK'
# Every forensic field of the five round rows, against the same fixture data gen.py wrote.
import json, os, sys
exp = json.load(open(os.path.join(os.environ["DELEGATE_T"], "expect.json")))
lines = [l for l in open(os.environ["DELEGATE_LEDGER"], encoding="utf-8").read().splitlines() if l.strip()]
row = {n: json.loads(lines[2 * n - 2]) for n in range(1, 6)}
out = []
def want(cond, name): out.append(("ok" if cond else "fail") + "|" + name)

want(all(r["kind"] == "round" and r["schema"] == 3 for r in row.values()),
     "every round row written by this build is kind round at schema 3")
want(all(list(r) == ["kind", "schema"] + json.loads(
     sys.argv[1])["round_keys"] for r in row.values()),
     "the row keys are kind, schema, then ROUND_KEYS in order (todos and worker_report after todos_total)")
want(row[1]["todos"] == [{"text": "implement the parser", "status": "completed"},
                         {"text": "write the suite", "status": "in_progress"}],
     "todos: the final todo write, item content as text, status as written")
want(row[1]["worker_report"] == {"status": "done",
     "not_verified": ["first unverified item", "second unverified item"],
     "deviations": ["one inline clause deviation"],
     "decisions": ["caps live in the schema owner"],
     "omissions": [], "suggestions": [], "questions": []},
     "worker_report: status, multi-line items, one-line heading, and none read as empty")
want(row[2]["worker_report"] is None, "a final message with no STATUS line -> worker_report null")
want(len(row[2]["todos"]) == 1, "worker_report null does not suppress todos")
want(row[3]["todos"] is None, "no todo write -> todos null")
want(row[3]["worker_report"]["status"] == "blocked"
     and row[3]["worker_report"]["questions"] == ["need the owner to pick a schema"],
     "a one-line QUESTIONS heading is one item, and the status comes through")
t4 = row[4]["todos"]
want(len(t4) == 50, "60 todos -> the row keeps 50")
want(t4[3]["text"] == ("big item " + "L" * 500)[:200], "a 500-character item is cut to 200")
want(t4[-1]["text"] == "todo item number 49", "the kept items are the first 50, in order")
want(row[4]["todos_total"] == 60 and row[4]["todos_done"] == 20,
     "todos_total/todos_done still count the raw write, not the clipped row field")
r5 = row[5]["worker_report"]
want(r5["status"] == "partial" and len(r5["omissions"]) == 20,
     "25 omission lines -> the row keeps 20")
want(r5["omissions"][0] == "omission number 1" and r5["omissions"][-1] == "omission number 20",
     "the kept section lines are the first 20, in order")
want(r5["deviations"] == ["D" * 300], "a 400-character deviation is cut to 300")
whole = "\n".join(lines)
want("canary" not in whole, "no FILES/VERIFIED/EVIDENCE text reached any row")
want("SECRET" not in whole, "no planted tool-input or tool-output marker reached any row")
for line in out:
    print(line)
CHK
syskeys=$(python3 -c 'import json,os,sys; sys.path.insert(0, os.environ["DELEGATE_HOME"]+"/lib"); import ledger; print(json.dumps({"round_keys": list(ledger.ROUND_KEYS)}))')
while IFS='|' read -r st name; do check "$name" "[ \"$st\" = ok ]"; done < <(python3 "$T/check.py" "$syskeys")

# ---------------------------------------------- a failing append changes nothing ----
mkdir -p "$TD/rounds/6"
printf '%s\n' '{"type":"text","timestamp":100,"part":{"type":"text","text":"STATUS: done"}}' > "$TD/rounds/6/events.jsonl"
: > "$TD/rounds/6/verify.log"; : > "$TD/rounds/6/stderr.log"
chmod 400 "$L"
finish 6 >/dev/null 2>"$T/err6"; rc6=$?
lines6=$(grep -c "" "$L")
chmod 600 "$L"
check "a read-only ledger: finalize_round still returns the sentinel 7" '[ "$rc6" = 7 ]'
check "a read-only ledger: no row was written" '[ "$lines6" = 10 ]'
check "a read-only ledger: exactly one warn line on stderr" \
  '[ "$(grep -c "warn: ledger append" "$T/err6")" = 1 ] && [ "$(grep -c "warn:" "$T/err6")" = 1 ]'

# ------------------------------------------- old rows still read; chains not stats-able ----
printf '{"kind":"round","schema":1,"task_id":"old-1","repo":"acme/gadgets","model":"m1","status":"done","exit":0,"round":1,"ts":"2026-11-01T00:00:00Z"}\n' >> "$L"
printf '{"kind":"round","schema":2,"task_id":"old-2","repo":"acme/gadgets","model":"m1","status":"done","exit":0,"round":2,"orchestrator":"claude-code","orchestrator_session":"s1","ts":"2026-11-02T00:00:00Z"}\n' >> "$L"
printf '{"chain":"planted","repo":"/srv/x","outcome":"failed","exit":2,"steps":[]}\n' > "$T/planted-chain.json"
"$here/bin/delegate" ledger append --kind chain --file "$T/planted-chain.json" 2>"$T/errp"; rcp=$?
check "the ledger CLI appends a chain row (the kind is registered)" '[ "$rcp" = 0 ]'
cat > "$T/oldrows.py" <<'OLD'
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["DELEGATE_HOME"], "lib"))
import ledger
acc = {"round": 0, "timeline": 0, "chain": 0}
out = []
for _n, _raw, r in ledger.read_rows(os.environ["DELEGATE_LEDGER"]):
    if r is None:
        out.append("fail|read_rows refused a line it must accept")
        continue
    acc[r["kind"]] = acc.get(r["kind"], 0) + 1
out.append(("ok" if acc["round"] == 7 else "fail")
           + f"|schema 1 and 2 round rows read beside the schema 3 ones (7 accepted, got {acc['round']})")
out.append(("ok" if acc["chain"] == 1 else "fail") + "|the planted chain row reads back through read_rows")
olds = [r for _n, _raw, r in ledger.read_rows(os.environ["DELEGATE_LEDGER"])
        if r and r.get("kind") == "round" and r.get("schema") == 1]
out.append(("ok" if olds and all(r.get("todos", "x") in (None, "x") and r.get("worker_report", "x") in (None, "x")
                                 for r in olds) else "fail")
           + "|a schema 1 row reads with the forensic fields absent, which is null to a reader")
stats = ledger.read_stats_rows(os.environ["DELEGATE_LEDGER"])
rounds = [r for r in stats["rows"] if r["kind"] == "round"]
out.append(("ok" if len(rounds) == 7 and stats["skipped"] == 0 else "fail")
           + f"|stats counts the seven round rows and skips nothing (got {len(rounds)}, skipped {stats['skipped']})")
out.append(("ok" if not any(r["kind"] == "chain" for r in stats["rows"]) else "fail")
           + "|stats never hands out a chain row: it is not a round")
for line in out:
    print(line)
OLD
while IFS='|' read -r st name; do check "$name" "[ \"$st\" = ok ]"; done < <(python3 "$T/oldrows.py")
OUT=$("$here/bin/delegate" stats 2>"$T/errst"); rcs=$?
check "delegate stats keeps working with a chain row in the ledger" '[ "$rcs" = 0 ]'
check "the stats footer counts 7 round rows, chain row included or not" \
  'printf "%s" "$OUT" | grep -q "7 round rows, 0 review rows"'
check "stats did not count the chain row as skipped rubbish either" '! grep -q "warn: ledger stats" "$T/errst"'
check "ledger show --kind round prints the seven round rows" \
  '[ "$("$here/bin/delegate" ledger show --kind round 2>/dev/null | grep -c "")" = 7 ]'
# =========================================================== the chain rows ====
# test_chain.sh's fake delegate, plus one scripted status `sleep` that lets a SIGTERM land
# mid-round. A separate state dir and ledger; the plan lives in a real git repo, so `repo`
# and `project` have their real shapes.
S2=$T/cstate; CL=$T/cled/events.jsonl; CL2=$T/cled/ro.jsonl; CR=$T/crepo
mkdir -p "$S2" "$T/cled" "$CR/docs" "$T/cscript"
# the orchestrator fields must come only from what a scenario sets, never from this shell
unset CLAUDE_CODE_SESSION_ID OPENCODE_SESSION_ID
export DELEGATE_STATE=$S2 DELEGATE_CHAIN_BIN=$T/fake-delegate DELEGATE_LEDGER=$CL SCRIPT=$T/cscript
git -C "$CR" init -q -b main
touch "$CR/docs/a.md" "$CR/docs/b.md"
git -C "$CR" add -A && git -C "$CR" -c user.name=t -c user.email=t@t commit -qm i
cat > "$T/fake-delegate" <<'F'
#!/bin/bash
# fake: run SPEC --name N... | continue ID F | finish ID | rm ID; statuses from $SCRIPT/<name>
cmd=$1; shift
if [ "$cmd" = run ]; then
  while [ $# -gt 0 ]; do case "$1" in --name) name=$2; shift 2;; *) shift;; esac; done
  id="crepo-$name"
elif [ "$cmd" = continue ]; then id=$1; name=${id#crepo-}
elif [ "$cmd" = finish ]; then id=$1; name=${id#crepo-}
  d=$DELEGATE_STATE/$id/rounds; n=$(ls $d 2>/dev/null | sort -n | tail -1); [ -n "$n" ] || exit 0
  st=$(sed -n "${n}p" "$SCRIPT/$name"); st=${st:-done}
  printf '{"status":"%s","verify_rc":0}\n' "$st" > "$d/$n/report.json"; exit 0
else exit 0; fi
d=$DELEGATE_STATE/$id/rounds; mkdir -p "$d"; n=$(( $(ls "$d" | wc -l) + 1 )); mkdir -p "$d/$n"
st=$(sed -n "${n}p" "$SCRIPT/$name"); st=${st:-done}
if [ "$st" = sleep ]; then                    # an unreporting round a signal can catch
  echo $$ > "$DELEGATE_STATE/fake.pid"; sleep 30 & echo $! > "$DELEGATE_STATE/fake-child.pid"; wait; exit 0
fi
printf '{"status":"%s","verify_rc":0}\n' "$st" > "$d/$n/report.json"
F
chmod +x "$T/fake-delegate"
cplan() { # NAME STEPSSPEC FILE — steps like {"a":"done","b":"done"} over the two fixture docs
  printf '{"name":"%s","repo":"%s","base":"main","retries":1,"steps":[
    {"name":"a","spec":"docs/a.md","verify":"true"},
    {"name":"b","spec":"docs/b.md","verify":"true","hard":true}]}' "$1" "$CR" > "$3"; }
printf '{"name":"fc3","repo":"%s","base":"main","retries":1,"steps":[
  {"name":"a","spec":"docs/a.md","verify":"true"}]}' "$CR" > "$T/cplan3.json"

# 1. a done run, then --status, --wait and --clean: exactly one row, for the run
printf 'done\n' > "$SCRIPT/a"; printf 'done\n' > "$SCRIPT/b"; cplan fc '{"a":"done","b":"done"}' "$T/cplan.json"
CLAUDE_CODE_SESSION_ID=forensics.1 python3 "$here/lib/chain.py" "$T/cplan.json" >"$T/co1" 2>&1; rc1=$?
CLAUDE_CODE_SESSION_ID=forensics.1 python3 "$here/lib/chain.py" "$T/cplan.json" --status >/dev/null 2>&1
CLAUDE_CODE_SESSION_ID=forensics.1 python3 "$here/lib/chain.py" "$T/cplan.json" --wait --interval 0.1 >/dev/null 2>&1
CLAUDE_CODE_SESSION_ID=forensics.1 python3 "$here/lib/chain.py" "$T/cplan.json" --clean >/dev/null 2>&1
check "a done chain exits 0" '[ "$rc1" = 0 ]'
check "one run wrote one chain row; status, wait and clean wrote none" '[ "$(grep -c "" "$CL")" = 1 ]'

# 2. a blocked run, from an orchestrator id that is not a plain token: exit 3, its own row
rm -rf "$S2"; mkdir -p "$S2"
printf 'blocked\n' > "$SCRIPT/a"; cplan fcb '{}' "$T/cplanb.json"
CLAUDE_CODE_SESSION_ID='bad id/slash' python3 "$here/lib/chain.py" "$T/cplanb.json" >/dev/null 2>&1; rc2=$?
check "a blocked chain exits 3" '[ "$rc2" = 3 ]'
check "the blocked run wrote its own chain row" '[ "$(grep -c "" "$CL")" = 2 ]'

# 3. SIGTERM between two bytes of work: the run dies by the signal, its row says interrupted
rm -rf "$S2"; mkdir -p "$S2"; printf 'sleep\n' > "$SCRIPT/a"
env -u CLAUDE_CODE_SESSION_ID python3 "$here/lib/chain.py" "$T/cplan3.json" >"$T/co3" 2>&1 &
cpid=$!; sleep 1; kill -TERM "$cpid" 2>/dev/null; wait "$cpid"; rc3=$?
[ -f "$S2/fake.pid" ] && kill "$(cat "$S2/fake.pid")" 2>/dev/null
[ -f "$S2/fake-child.pid" ] && kill "$(cat "$S2/fake-child.pid")" 2>/dev/null
true
check "a SIGTERM'd chain dies by the signal (143), as it did without the row" '[ "$rc3" = 143 ]'
check "the interrupted run wrote its chain row" '[ "$(grep -c "" "$CL")" = 3 ]'

# 4. an unwritable ledger: one warning, and a result exactly as if no ledger existed
touch "$CL2"; chmod 400 "$CL2"
printf 'done\n' > "$SCRIPT/a"; printf 'done\n' > "$SCRIPT/b"; cplan fcr '{}' "$T/cplanr.json"
rm -rf "$S2"; mkdir -p "$S2"
DELEGATE_LEDGER="$CL2" python3 "$here/lib/chain.py" "$T/cplanr.json" >/dev/null 2>"$T/co4"; rc4=$?
check "a read-only ledger: the chain still exits 0" '[ "$rc4" = 0 ]'
check "a read-only ledger: exactly one warning about the chain row" \
  '[ "$(grep -c "chain row:" "$T/co4")" = 1 ] && [ "$(wc -c < "$CL2")" = 0 ]'
chmod 600 "$CL2"

# the three rows, field by field
cat > "$T/check2.py" <<'CHK'
import hashlib, json, os, sys
sys.path.insert(0, os.path.join(os.environ["DELEGATE_HOME"], "lib"))
import ledger
lines = [l for l in open(os.environ["DELEGATE_LEDGER"], encoding="utf-8").read().splitlines() if l.strip()]
rows = [json.loads(l) for l in lines]
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
out = []
def want(cond, name): out.append(("ok" if cond else "fail") + "|" + name)
keys = ["kind", "schema"] + list(ledger.CHAIN_KEYS)
want(all(list(r) == keys for r in rows),
     "every chain row is kind, schema, then the design's chain fields in order")
want(all(r["kind"] == "chain" and r["schema"] == ledger.KINDS["chain"] for r in rows),
     "kind is chain at the registered schema")
d, b, i = rows
CR = os.environ["CREPO"]
want(d["chain"] == "fc" and d["repo"] == CR and d["project"] == CR,
     "the done row names the chain, the absolute repo and the project of its git common dir")
want(d["plan_hash"] == sha(os.environ["CPLAN"]),
     "plan_hash is sha256 of the plan file's bytes")
want(all(str(r.get("ts", "")).endswith("Z") and "T" in str(r.get("ts", "")) for r in rows)
     and all("T" in str(r["started_at"]) and str(r["started_at"]) <= str(r["ended_at"]) for r in rows),
     "ts, started_at and ended_at are ISO-8601 UTC, and the run ended after it started")
want(d["outcome"] == "done" and d["exit"] == 0, "the done row: outcome done, exit 0")
want(d["steps"] == [{"step": "a", "task_id": "crepo-a", "status": "done",
                     "rounds": 1, "retries": 0, "hard": False},
                    {"step": "b", "task_id": "crepo-b", "status": "done",
                     "rounds": 1, "retries": 0, "hard": True}],
     "steps are the plan's, in plan order, with task id, status, rounds, retries and the hard flag")
want(d["orchestrator"] == "claude-code" and d["orchestrator_session"] == "forensics.1",
     "the orchestrator comes from the same environment meta.env's ORCH pair reads")
want(b["outcome"] == "blocked" and b["exit"] == 3, "the blocked row: outcome blocked, exit 3")
want(b["steps"][0]["status"] == "blocked" and b["steps"][0]["rounds"] == 1
     and b["steps"][1]["status"] == "not started" and b["steps"][1]["rounds"] is None
     and b["steps"][1]["retries"] is None,
     "the blocked row: the dead step with its round, the later step not started, its counts null")
want(b["orchestrator"] is None and b["orchestrator_session"] is None,
     "an orchestrator id outside the token shape is recorded as null")
want(i["outcome"] == "interrupted" and i["exit"] == 143, "the interrupted row: outcome interrupted, exit 143")
want(len(i["steps"]) == 1 and i["steps"][0]["step"] == "a"
     and i["steps"][0]["status"] in ("interrupted", "running")
     and i["steps"][0]["rounds"] in (None, 1),
     "the interrupted row: the one running step as the state files had it, counts as far as known")
want(i["orchestrator"] is None, "a chain started from a plain shell records no orchestrator")
for line in out:
    print(line)
CHK
export CREPO=$CR CPLAN=$T/cplan.json
while IFS='|' read -r st name; do check "$name" "[ \"$st\" = ok ]"; done < <(python3 "$T/check2.py")

[ "$fail" = 0 ] || exit 1
echo "PASS: test_ledger_forensics"
