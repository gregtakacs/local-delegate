#!/bin/bash
# T2: the round row and its timeline. `finalize_round` writes both rows through
# `delegate ledger append` after report.json exists — in the design's field order, from
# report.json + meta.env + the round's own files — and can never change the round's
# outcome: a disabled ledger is silent, a failed append is one warn line, and the return
# value the callers see is byte-identical either way (proved with a sentinel stub).
# EFFORT is stored in meta.env where MODEL is. R4/R7: no payloads, no keys, ever.
# No docker, no model, no network: the worker half of the lifecycle is stubbed at the
# function boundary; everything from finalize_round on runs for real.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DELEGATE_CONFIG=$T/none.env
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

VERSION=$(sed -n 's/^VERSION=//p' "$here/bin/delegate" | head -1)

# ------------------------------------------------------------- EFFORT, static ----
check "cmd_run stores EFFORT in meta.env at the same write that stores the rest" \
  "grep -q \"printf 'EFFORT=%q\" $here/bin/delegate"
check "run and continue both record effort=hard on --hard" \
  "[ \"$(grep -c 'effort=hard; shift' $here/bin/delegate)\" = 2 ]"
check "continue: --hard upgrades the stored EFFORT via meta_set" \
  "grep -q 'meta_set EFFORT hard' $here/bin/delegate"
check "the ledger CLI's warn helper has not drifted from the stubbed line" \
  "grep -qF 'ledger_warn() { warn \"warn: ledger \$1: \$2\"; }' $here/bin/delegate"

# ------------------------------------------------------------------- fixtures ----
S=$T/state                                   # a private DELEGATE_STATE, with locks in it
TD=$S/task                                   # the task dir itself: its lock must not count
L=$T/led/events.jsonl                        # the ledger, via DELEGATE_LEDGER
mkdir -p "$S/ledger" "$S/sib-9/lock" "$TD/lock" "$TD/rounds/1" "$T/led"
export DELEGATE_STATE=$S DELEGATE_LEDGER=$L
printf '# fixture spec\nthe task is to write a row\n' > "$TD/spec.md"
{ printf 'ID=%q\nSLUG=%q\nREPO=%q\nWORKTREE=%q\nBRANCH=%q\n' \
    task-x task-x "$T/repo" "$T/wt" delegate/task-x
  printf 'BASE_REF=%q\nBASE_SHA=%q\nGIT_COMMON=\nMODEL=%q\nVERIFY=\n' main abc1234 stub-model
  printf 'SERVICE=\nCOPIED=\nSESSION=\nCREATED=%q\nWT_GITDIR=\n' 2026-01-01T00:00:00+00:00
  printf 'READS=\nGITHUB=0\nEGRESS=%q\nHERE=0\nRUNNER=native\nRAW=0\n' filtered
  printf 'ORB_FILE=\nORB_LABEL=\nORB_BASE_MAC=\nORB_SERIAL=\nORB_IP=\nORB_FLASH=0\n'
  printf 'GRANTS=\nALLOW=\nCHAIN=\nEFFORT=hard\n'
  printf 'ORCH=claude-code\nORCH_SESSION=1e061308-50b0\n'; } > "$TD/meta.env"
# the round's raw events, in the shape opencode streams them. Every SECRET/hush marker
# below sits in a payload (input/output/title/meta/text) and must never reach the ledger.
RD=$TD/rounds/1
cat > "$RD/events.jsonl" <<FIX
{"type":"step_start","timestamp":1000,"part":{"type":"step-start"}}
{"type":"step_finish","timestamp":3000,"part":{"type":"step-finish","tokens":{"input":100,"output":50,"reasoning":10,"cache":{"read":7,"write":3}},"reason":"tool-calls"}}
{"type":"tool_use","timestamp":3500,"part":{"type":"tool","tool":"bash","callID":"call_a1","id":"call_a1","state":{"status":"completed","input":"SECRETINPUT","output":"SECRETOUTPUT","title":"SECRET-TITLE","metadata":{"k":"SECRET-META"},"time":{"start":3400,"end":4800}}}}
{"type":"step_start","timestamp":5000,"part":{"type":"step-start"}}
{"type":"tool_use","timestamp":6000,"part":{"type":"tool","tool":"grep","callID":"call_b2","id":"call_b2","state":{"status":"pending","input":"hush","time":{"start":5800}}}}
{"type":"tool_use","timestamp":8000,"part":{"type":"tool","tool":"grep","callID":"call_b2","id":"call_b2","state":{"status":"completed","input":"hush2","output":"hush3","time":{"start":5800,"end":8100}}}}
{"type":"tool_use","timestamp":8500,"part":{"type":"tool","tool":"write","callID":"call_c3","id":"call_c3","state":{"status":"error","error":"The arguments provided to the tool are invalid: SECRET-ARGS-MARKER","time":{"start":8400,"end":8500}}}}
{"type":"text","timestamp":9000,"part":{"type":"text","text":"STATUS: done\n\nSECRETTEXT foobarbaz\nkey SECRET-KEY-VALUE"}}
{"type":"tool_use","timestamp":9300,"part":{"type":"tool","tool":"bash","callID":"call_d4","id":"call_d4","state":{"status":"error","error":"SECRET-GENERIC-FAILURE","time":{"start":9200,"end":9300}}}}
{"type":"step_finish","timestamp":9500,"part":{"type":"step-finish","tokens":{"input":1,"output":2,"reasoning":0,"cache":{"read":0,"write":0}},"reason":"end-turn"}}
FIX
printf 'nudge: malformed step=1 ctx=110\nnudge: api-error step=2 ctx=1\nnudge: no-status\n' > "$RD/stderr.log"
: > "$RD/verify.log"
# $DELEGATE_RULES_DIR: a fixture tree with exactly the three sources the hash covers
RL=$T/rules; mkdir -p "$RL/rules" "$RL/plugins"
printf 'rule one\n' > "$RL/rules/one.md"
printf '// plugin\n' > "$RL/plugins/two.js"
printf 'core rules\n' > "$RL/delegate-rules.md"
export DELEGATE_RULES_DIR=$RL
export DELEGATE_HOME=$here
export DELEGATE_CHUNK_CAP=8000 DELEGATE_TIMEOUT=5400 DELEGATE_RUNNER=native
export DELEGATE_IMAGE=delegate-worker:fixture   # never consulted: the runner is native

# The functions under test, extracted whole from bin/delegate (all multi-line, closed by a
# lone `}`). The lifecycle half the round was run with is stubbed at that boundary; the
# sentinel in progress_stop is what proves the append cannot shift the return the callers
# see. warn/note/die/ledger_warn/phase are stubbed line-identical — the static check above
# pins ledger_warn's source line against drift.
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
grep -q 'append_round_and_timeline' "$T/driver.sh" || { echo "FAIL extracted ledger_append lost round mode"; exit 1; }

export DELEGATE_T=$T
export ID=task-x SLUG=task-x REPO=$T/repo WORKTREE=$T/wt BRANCH=delegate/task-x
export BASE_REF=main BASE_SHA=abc1234 MODEL=stub-model RUNNER=native HERE=1 RAW=0
export BASE_URL=https://gw.example.internal/v1 DELEGATE_API_KEY_FILE=$T/never-read
export TASK_DIR=$TD
START=$(( $(date +%s) - 120 )); END=$(( $(date +%s) - 12 ))
finish() { . "$T/driver.sh"; finalize_round "$1" "$2" "" 0 "$START" "$END"; }
ledger_line() { sed -n "$1p" "$L"; }


# ------------------------------------------------------------ round 1, live -------
out1=$(finish 1 "$RD" 2>"$T/err1"); rc1=$?
check "finalize_round returns the sentinel 7 to its caller with the append in place" \
  '[ "$rc1" = 7 ]'
check "the append wrote no warning: stderr holds only the report path chatter" \
  '! grep -q "warn: ledger" "$T/err1"'
check "the round report still reached stdout" 'printf "%s" "$out1" | grep -q "round 1"'
check "the ledger holds exactly two rows" '[ "$(grep -c "" "$L")" = 2 ]'
check "row order: round first, its timeline immediately after" \
  'ledger_line 1 | grep -qF "{\"kind\":\"round\"" && ledger_line 2 | grep -qF "{\"kind\":\"timeline\""'
check "the timeline row is derived from the round's own events (steps present, no totals)" \
  'ledger_line 2 | grep -q "\"steps\"" && ! ledger_line 2 | grep -q "totals"'

cat > "$T/check.py" <<'PY'
# Every field of both rows against the design's values for this fixture round.
import hashlib, json, os, re, sys
from datetime import datetime, timezone
sys.path.insert(0, os.path.join(os.environ["DELEGATE_HOME"], "lib"))
import ledger

L = os.environ["DELEGATE_LEDGER"]
lines = [l for l in open(L, encoding="utf-8").read().splitlines() if l.strip()]
round_row = json.loads(lines[0])
tl_row = json.loads(lines[1])
report = json.load(open(sys.argv[1], encoding="utf-8"))

def sha(b): return hashlib.sha256(b).hexdigest()

spec_hash = sha(open(os.path.join(os.environ["TASK_DIR"], "spec.md"), "rb").read())[:64]
root = os.environ["DELEGATE_RULES_DIR"]
files = []                                             # the same three sources ledger_rules_hash
for d in ("rules", "plugins"):                         # walks, in the same order it sorts them
    dp = os.path.join(root, d)
    if os.path.isdir(dp):
        files += [os.path.join(d, f) for f in sorted(os.listdir(dp))]
if os.path.isfile(os.path.join(root, "delegate-rules.md")):
    files.append("delegate-rules.md")
blob = b""
for rel in sorted(files):
    with open(os.path.join(root, rel), "rb") as f:
        blob += (sha(f.read()) + "  " + rel + "\n").encode()
rules_hash = sha(blob)[:64]
iso = lambda s: datetime.fromtimestamp(int(s), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
derived = ledger.derive_timeline(os.path.join(os.path.dirname(sys.argv[1]), "events.jsonl"))

cases = [
    (list(round_row) == ["kind", "schema"] + list(ledger.ROUND_KEYS),
     "round row carries the design's keys, in the design's order"),
    (round_row["kind"] == "round" and round_row["schema"] == ledger.KINDS["round"],
     "round row kind and schema"),
    (round_row["task_id"] == "task-x" and round_row["run_id"] == "task-x"
     and round_row["slug"] == "task-x" and round_row["repo"] == os.environ["REPO"],
     "identity fields come from meta.env"),
    (round_row["chain"] is None and round_row["step"] == "task-x",
     "chain null outside a chain; step names the task"),
    (round_row["round"] == 1 and round_row["retries"] == 0, "round 1, no retries"),
    (round_row["spec_hash"] == spec_hash, "spec_hash is sha256 of the round's spec.md"),
    (round_row["base_ref"] == "main" and round_row["base_sha"] == "abc1234", "base ids"),
    (round_row["verify"] is None, "no verify command: null, not empty"),
    (round_row["endpoint"] == os.environ["BASE_URL"],
     "endpoint is the full configured URL, verbatim"),
    (round_row["model"] == "stub-model" and round_row["effort"] == "hard"
     and round_row["effort_source"] == "cli",
     "model/effort/effort_source: hard from the meta.env record, not the CLI"),
    (round_row["delegate_version"] == os.environ["EXPECT_VERSION"], "delegate_version"),
    (round_row["rules_hash"] == rules_hash, "rules_hash matches the context_stamp construction"),
    (round_row["image_stamp"] == "", "image_stamp empty on the native runner, with docker absent"),
    (round_row["runner"] == "native", "runner from meta.env"),
    (round_row["orchestrator"] == "claude-code"
     and round_row["orchestrator_session"] == "1e061308-50b0",
     "the delegating session from meta.env (round:2)"),
    (round_row["schema"] == 3, "a round row with the orchestrator fields is schema 3"),
    (round_row["timeout_s"] == 5400 and round_row["edit_cap"] == 8000,
     "timeout and edit cap in force"),
    (round_row["parallel_rounds"] == 1,
     "one sibling lock; the task's own lock excluded"),
    (round_row["status"] == report["status"] == "done"
     and round_row["worker_status"] == "done" and round_row["exit"] == 0,
     "outcome fields mirror report.json"),
    (round_row["verify_rc"] is None and round_row["nudges"] == report["nudges"],
     "verify_rc null, nudges dict kept"),
    (round_row["tool_calls"] == report["tool_calls"]
     and round_row["tool_errors"] == len(report["tool_errors"])
     and round_row["errors"] == len(report["errors"]),
     "tool call count, and error lists stored as counts (R4)"),
    (round_row["todos_done"] == 0 and round_row["todos_total"] == len(report["todos"] or []),
     "todo counts"),
    (round_row["round_start"] == iso(os.environ["EXPECT_START"])
     and round_row["round_end"] == iso(os.environ["EXPECT_END"]),
     "round_start/round_end are the finalize_round arguments as ISO"),
    (round_row["duration_s"] == report["duration_s"] and round_row["steps"] == report["steps"],
     "duration and step count from the report"),
    (round_row["input_tokens"] == derived["totals"]["input"]
     and round_row["output_tokens"] == derived["totals"]["output"]
     and round_row["reasoning_tokens"] == derived["totals"]["reasoning"]
     and round_row["cache_read"] == derived["totals"]["cache_read"]
     and round_row["cache_write"] == derived["totals"]["cache_write"],
     "token sums come from the derivation totals: one parse feeds both rows"),
    (round_row["final_context_tokens"] == report["final_context_tokens"],
     "final context from the report"),
    (round_row["diff_lines"] == 12, "diff_lines parsed from the round's captured diffstat"),
    (round_row["source"] == "", "live rows carry an empty source"),
    (re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", round_row["ts"])
     and tl_row["ts"] == round_row["ts"],
     "both rows close with one ISO timestamp"),
    (list(tl_row) == ["kind", "schema", "task_id", "run_id", "round",
                      "steps", "tools", "events", "source", "ts"],
     "timeline row: identity + derivation, nothing else, in order"),
    (tl_row["kind"] == "timeline" and tl_row["schema"] == ledger.KINDS["timeline"],
     "timeline kind and schema"),
    (tl_row["task_id"] == round_row["task_id"] and tl_row["run_id"] == round_row["run_id"]
     and tl_row["round"] == round_row["round"], "timeline joins on the same identity"),
    (tl_row["steps"] == derived["steps"] and tl_row["tools"] == derived["tools"],
     "timeline body is the derivation itself"),
    ([s["ctx"] for s in tl_row["steps"]] == [110, 1],
     "every step carries its context size (input+cache.read+cache.write)"),
    (tl_row["events"] == [
        {"kind": "nudge:no-status", "step": None, "ctx": None},
        {"kind": "nudge:malformed", "step": 1, "ctx": 110},
        {"kind": "tool-error:invalid-args", "step": 2, "ctx": 1},
        {"kind": "tool-error", "step": 2, "ctx": 1},
        {"kind": "nudge:api-error", "step": 2, "ctx": 1}],
     "events: the walk's two tool errors (the invalid-args one split out by its marker), "
     "the three nudges at their recorded positions — the old-format line at null, sorted "
     "first, no verify-fail with verify_rc absent — in step order"),
    (tl_row["ts"] == round_row["ts"], "the pair shares one ts"),
]
bad = [msg for ok, msg in cases if not ok]
for msg in bad:
    print("MISMATCH " + msg)
print(f"checked={len(cases)} bad={len(bad)}")
PY
chk=$(EXPECT_VERSION=$VERSION EXPECT_START=$START EXPECT_END=$END \
     python3 "$T/check.py" "$RD/report.json" 2>&1)
printf '%s\n' "$chk" | grep '^MISMATCH' || true
check "every field of both rows matches the design's fixture values (36 checks)" \
  'printf "%s\n" "$chk" | grep -qE "^checked=36 bad=0$"'
check "R4/R7: no payload text, call id or key material reached the ledger" \
  '! grep -qE "SECRETINPUT|SECRETOUTPUT|SECRET-TITLE|SECRET-META|SECRETTEXT|SECRET-KEY-VALUE|foobarbaz|hush|call_a1|call_b2|never-read|SECRET-ARGS-MARKER|SECRET-GENERIC-FAILURE|call_c3|call_d4" "$L"'
check "R7: the key file path is not recorded anywhere in the rows" \
  '! grep -q "DELEGATE_API_KEY_FILE" "$L"'


# ------------------------------------------------------- round 2: counters move ----
RD2=$TD/rounds/2; mkdir -p "$RD2"; cp "$RD/events.jsonl" "$RD2/events.jsonl"
out2=$(finish 2 "$RD2" 2>"$T/err2"); rc2=$?
check "round 2 also returns the sentinel" '[ "$rc2" = 7 ] && [ "$out2" != "$out1" ]'
check "round 2's pair appended adjacent: four rows, round then timeline" \
  '[ "$(grep -c "" "$L")" = 4 ]' \
     '&& ledger_line 3 | grep -qF "{\"kind\":\"round\"" && ledger_line 4 | grep -qF "{\"kind\":\"timeline\"" '
check "round 2 row: round=2 and retries=1" \
  'ledger_line 3 | python3 -c "import json,sys;r=json.load(sys.stdin);sys.exit(0 if r[\"round\"]==2 and r[\"retries\"]==1 else 1)"'
check "effort still read from the record for a later round" \
  'ledger_line 3 | grep -q "\"effort\":\"hard\""'

# --------------------------------------------------- disabled ledger is silent -----
RD3=$TD/rounds/3; mkdir -p "$RD3"; cp "$RD/events.jsonl" "$RD3/events.jsonl"
out3=$(DELEGATE_LEDGER=off finish 3 "$RD3" 2>"$T/err3"); rc3=$?
check "DELEGATE_LEDGER=off: the round returns 7 exactly as before" '[ "$rc3" = 7 ]'
check "DELEGATE_LEDGER=off: no warning is printed at all" \
  '! grep -q "warn" "$T/err3"'
check "DELEGATE_LEDGER=off: nothing was appended" '[ "$(grep -c "" "$L")" = 4 ]'

# ------------------------------------------------- a failing append: one warn ------
mkdir -p "$T/ro"; chmod 555 "$T/ro"
out4=$(DELEGATE_LEDGER=$T/ro/deep/events.jsonl finish 3 "$TD/rounds/3" 2>"$T/err4"); rc4=$?
chmod 755 "$T/ro"
check "unwritable ledger: the round still returns its sentinel 7" '[ "$rc4" = 7 ]'
check "unwritable ledger: exactly one warn line names the ledger append" \
  '[ "$(grep -c "warn: ledger append" "$T/err4")" = 1 ]'
check "unwritable ledger: the round report itself was still written" \
  'grep -q "\"round\": 3" "$TD/rounds/3/report.json"'

# --------------------------------------------- pruned events: round row alone -----
RD5=$TD/rounds/5; mkdir -p "$RD5"          # report regenerates over a missing events file
out5=$(finish 5 "$RD5" 2>"$T/err5"); rc5=$?
check "pruned round: the round still returns 7" '[ "$rc5" = 7 ]'
check "pruned round: exactly one more row, and it is a round row" \
  '[ "$(grep -c "" "$L")" = 5 ] && ledger_line 5 | grep -qF "{\"kind\":\"round\""'
check "pruned round: no timeline row was fabricated" \
  '! grep -q "\"kind\":\"timeline\"" <(tail -n 1 "$L")'
check "pruned round: the derived sums are null — one parse, and it could not run" \
  'ledger_line 5 | python3 -c "import json,sys;r=json.load(sys.stdin);sys.exit(0 if r[\"input_tokens\"] is None and r[\"cache_read\"] is None else 1)"'


# ---------------------------------------------- the CLI guards and stays additive ---
delegate() { "$here/bin/delegate" "$@"; }
g=$(delegate ledger append --kind timeline --round-from-report "$RD/report.json" 2>&1); grc=$?
check "round mode refuses a non-round kind: one warn, exit 0, no row" \
  '[ "$grc" = 0 ] && printf "%s\n" "$g" | grep -qF "round-from-report writes a round row"'
check "the refusal appended nothing" '[ "$(grep -c "" "$L")" = 5 ]'
delegate ledger append --kind verdict --task r11 --status done --fields n=3 >/dev/null 2>&1
check "the T1 scalar mode still appends, untouched by the round flags" \
  '[ "$(grep -c "" "$L")" = 6 ] && tail -n 1 "$L" | grep -qF "{\"kind\":\"verdict\""'
delegate ledger append --kind round --no-such-flag x >/dev/null 2>&1
check "an unknown flag is still one warn and no row" \
  '[ "$(grep -c "" "$L")" = 6 ]'

# ------------------------------------------------------------- schema units --------
u=$(DELEGATE_LIB_DIR=$here/lib python3 - "$L" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["DELEGATE_LIB_DIR"])
import ledger

r = ledger.build_round_row({"round": 3, "status": "done", "tool_calls": 2,
                            "tool_errors": ["a"], "errors": ["b", "c"],
                            "nudges": {"no-status": 1}})
e = ledger.build_round_row({})
d = ledger.parse_diffstat
cases = [
    (list(r) == list(ledger.ROUND_KEYS), "keys come out in ROUND_KEYS order"),
    (r["effort"] == "normal" and r["image_stamp"] == "" and r["source"] == "",
     "an absent effort reads normal; image_stamp and source read empty"),
    (r["retries"] == 2 and r["tool_errors"] == 1 and r["errors"] == 2,
     "retries is round minus one; error lists are stored as counts"),
    (all(r[k] is None for k in ("task_id", "endpoint", "verify", "diff_lines",
                                "verify_rc", "input_tokens")),
     "unknown fields are null"),
    (e["round"] is None and e["retries"] == 0, "a row without a round has no retry count"),
    (d(" 2 files changed, 10 insertions(+), 2 deletions(-)") == 12,
     "diff_lines: the diffstat summary line"),
    (d("a.py | 5 +--\nb.py | 3 +") == 8, "diff_lines: per-file columns without a summary"),
    (d("not a diffstat at all") is None and d("") is None,
     "diff_lines: nothing knowable stays None"),
]
bad = [m for ok, m in cases if not ok]
for m in bad:
    print("MISMATCH " + m)
print(f"checked={len(cases)} bad={len(bad)}")
PY
)
printf '%s\n' "$u" | grep '^MISMATCH' || true
check "the row builder and diffstat parser hold their contracts (8 checks)" \
  'printf "%s\n" "$u" | grep -qE "^checked=8 bad=0$"'

# ------------------------------------------------------- rules hash is content ----
h1=$(. "$T/driver.sh"; ledger_rules_hash)
check "the rules hash is a bare sha256" 'printf "%s" "$h1" | grep -qE "^[0-9a-f]{64}$"'
printf 'rule one changed\n' >> "$RL/rules/one.md"
h2=$(. "$T/driver.sh"; ledger_rules_hash)
check "editing a rule moves the hash" '[ "$h1" != "$h2" ]'
printf 'rule one\n' > "$RL/rules/one.md"
h3=$(. "$T/driver.sh"; ledger_rules_hash)
check "restoring the tree restores the hash" '[ "$h1" = "$h3" ]'

# ------------------------------------------- a task from before EFFORT existed -----
# A task created by a delegate older than the ledger has no EFFORT in meta.env. Its later rounds
# infer effort the way the import does (hard iff its model is the configured hard model) and say
# so, rather than claiming a CLI-given `normal`.
TD2=$T/task-legacy; cp -r "$TD" "$TD2"; sed -i '/^EFFORT=/d' "$TD2/meta.env"
L2=$T/legacy.jsonl
legacy() { ( unset EFFORT; export TASK_DIR=$TD2 DELEGATE_LEDGER=$L2 MODEL=$1 \
             DELEGATE_MODEL=med-m DELEGATE_MODEL_HARD=hard-m
             . "$T/driver.sh"; finalize_round 1 "$TD2/rounds/1" "" 0 "$START" "$END" ) >/dev/null 2>&1; }
legacy hard-m; legacy med-m
check "a pre-EFFORT task's round infers hard from its model, labelled inferred" \
  'sed -n 1p "$L2" | grep -q "\"effort\":\"hard\",\"effort_source\":\"inferred\""'
check "and infers normal for the other model, labelled inferred" \
  'grep "\"kind\":\"round\"" "$L2" | sed -n 2p | grep -q "\"effort\":\"normal\",\"effort_source\":\"inferred\""'

exit $fail
