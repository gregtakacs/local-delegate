#!/bin/bash
# The telemetry ledger's file protocol and its timeline derivation: lib/ledger.py's five names,
# and `delegate ledger append|show` over a real file. Path precedence, the kind registry, malformed
# and truncated lines, concurrent and signal-interrupted appends, merge precedence for the row
# flags, and what derive_timeline must never read out of a round's events (R4).
# No docker, no model, no network, no repository.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DELEGATE_CONFIG=$T/none.env
# DELEGATE_STATE is deliberately NOT exported: the ledger has to resolve without it, and this
# suite must never read or write a real state dir.
unset DELEGATE_STATE
export DELEGATE_LEDGER=$T/ledger/events.jsonl
L=$DELEGATE_LEDGER
mkdir -p "$T/ledger"
lg() { "$here/bin/delegate" ledger "$@"; }
pylib() { DELEGATE_LIB_DIR=$here/lib python3 "$@"; }
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
# A command substitution strips the trailing newline, so `wc -l` reads a one-line captured
# warning as zero lines. grep -c '' counts the last line whether or not it ends in a newline.
nlines() { printf '%s' "$1" | grep -c '' || true; }

# ------------------------------------------------------------------ the path ----------
cat > $T/resolve.py <<'PY'
# resolve_ledger's precedence, and what it must not do: create anything.
import os, sys
sys.path.insert(0, os.environ["DELEGATE_LIB_DIR"])
import ledger

env0 = {"HOME": "/home/t"}
def show(label, overrides, env):
    print(f"{label}={ledger.resolve_ledger(overrides, env)}")

print("kinds=" + ",".join(f"{k}:{v}" for k, v in sorted(ledger.KINDS.items())))
show("override", {"LEDGER": "/o/led.jsonl"}, dict(env0, DELEGATE_LEDGER="/e/led.jsonl"))
show("env", {"LEDGER": ""}, dict(env0, DELEGATE_LEDGER="/e/led.jsonl"))
show("state-override", {"DELEGATE_STATE": "/s"}, env0)
show("state-env", {}, dict(env0, DELEGATE_STATE="/s2"))
show("xdg", {}, dict(env0, XDG_STATE_HOME="/x"))
show("home", {}, env0)
show("tilde", {"LEDGER": "~/led.jsonl"}, env0)
show("blank-override", {"LEDGER": "", "DELEGATE_STATE": ""}, dict(env0, XDG_STATE_HOME="/x"))

sandbox = sys.argv[1]
ledger.resolve_ledger({}, {"HOME": sandbox})
ledger.resolve_ledger({"DELEGATE_STATE": sandbox + "/state"}, {"HOME": sandbox})
print("creates=" + (",".join(sorted(os.listdir(sandbox))) or "nothing"))
PY
mkdir -p $T/sandbox
ROUT=$(pylib $T/resolve.py $T/sandbox); RV() { printf '%s\n' "$ROUT" | sed -n "s/^$1=//p"; }
check "KINDS: slice T's three kinds, slice B's two, and the chain kind, registered so readers skip cleanly" \
  '[ "$(RV kinds)" = "benchmark:1,chain:1,review:1,round:3,timeline:2,verdict:1" ]'
check "resolve_ledger: a CLI/config override wins over DELEGATE_LEDGER" \
  '[ "$(RV override)" = /o/led.jsonl ]'
check "resolve_ledger: DELEGATE_LEDGER is used when no override is given" \
  '[ "$(RV env)" = /e/led.jsonl ]'
check "resolve_ledger: an override state dir holds even without a ledger key" \
  '[ "$(RV state-override)" = /s/ledger/events.jsonl ]'
check "resolve_ledger: DELEGATE_STATE in the environment is the next step down" \
  '[ "$(RV state-env)" = /s2/ledger/events.jsonl ]'
check "resolve_ledger: \$XDG_STATE_HOME/delegate/ledger/events.jsonl by default" \
  '[ "$(RV xdg)" = /x/delegate/ledger/events.jsonl ]'
check "resolve_ledger: HOME/.local/state/delegate when XDG says nothing" \
  '[ "$(RV home)" = /home/t/.local/state/delegate/ledger/events.jsonl ]'
check "resolve_ledger: an empty override is no override" \
  '[ "$(RV blank-override)" = /x/delegate/ledger/events.jsonl ]'
check "resolve_ledger: ~ in a configured path expands against HOME" \
  '[ "$(RV tilde)" = /home/t/led.jsonl ]'
check "resolve_ledger: resolving creates no directory, and nothing else either" \
  '[ "$(RV creates)" = nothing ]'

# ---------------------------------------------------------------- append refuses ------
cat > $T/refuse.py <<'PY'
# What append() must refuse with ValueError, before it touches the file: an unknown kind, a
# schema above the registered one, and a schema that is not the int the schema is defined to be.
import os, sys
sys.path.insert(0, os.environ["DELEGATE_LIB_DIR"])
import ledger

path = sys.argv[1]
rows = {"unknown-kind": {"kind": "telemetry-x", "schema": 1},
        "schema-high": {"kind": "round", "schema": 4},
        "schema-zero": {"kind": "round", "schema": 0},
        "schema-missing": {"kind": "round"},
        "schema-string": {"kind": "round", "schema": "1"},
        "schema-bool": {"kind": "round", "schema": True},
        "kind-missing": {"schema": 1, "task_id": "t"},
        "not-a-mapping": ["kind", "round"]}
for label, row in rows.items():
    try:
        ledger.append(path, row); verdict = "accepted"
    except ValueError:
        verdict = "ValueError"
    except Exception as exc:                                    # noqa: BLE001 - the test reports it
        verdict = f"{type(exc).__name__}"
    print(f"{label}={verdict}")
print("file=" + ("created" if os.path.exists(path) else "absent"))
PY
REF=$(pylib $T/refuse.py $T/refuse/events.jsonl); WV() { printf '%s\n' "$REF" | sed -n "s/^$1=//p"; }
for what in unknown-kind schema-high schema-zero schema-missing schema-string schema-bool kind-missing not-a-mapping; do
  check "append: $what raises ValueError" '[ "$(WV '"$what"')" = ValueError ]'
done
check "append: refusing every row leaves no file behind" '[ "$(WV file)" = absent ]'

# ------------------------------------------------- one row, written and read back -----
out=$(lg append --kind round --task t-one --status done --exit 0 --fields 'n=3,label=one' 2>$T/err); rc=$?
check "append: exits 0" '[ "$rc" = 0 ]'
check "append: prints nothing on success" '[ -z "$out" ]'
check "append: wrote one line" '[ "$(wc -l < "$L")" = 1 ]'
row1=$(sed -n 1p "$L")
cat > $T/shape.py <<'PY'
# The shape of a written line: the first two keys (so a reader can filter before parsing), that
# the JSON is compact, and that ts is there in UTC.
import json, sys

line = open(sys.argv[1]).read().splitlines()[int(sys.argv[2])]
row = json.loads(line)
print("keys=" + ",".join(list(row)[:2]))
print("compact=" + ("no" if (", " in line or '": ' in line) else "yes"))
print("ts=" + ("utc" if str(row.get("ts", "")).endswith("Z") and "T" in str(row.get("ts", "")) else "missing"))
print("fields=" + json.dumps([row.get("task_id"), row.get("status"), row.get("exit"), row.get("n")]))
PY
SH=$(pylib $T/shape.py "$L" 0); SF() { printf '%s\n' "$SH" | sed -n "s/^$1=//p"; }
check "append: kind and schema are the first two keys written" '[ "$(SF keys)" = "kind,schema" ]'
check "append: compact JSON, no space after a separator" '[ "$(SF compact)" = yes ]'
check "append: every row carries ts, ISO-8601 UTC" '[ "$(SF ts)" = utc ]'
check "append: the --kind/--task/--status/--exit scalars and --fields are in the row" \
  '[ "$(SF fields)" = "[\"t-one\", \"done\", 0, 3]" ]'
check "append: the lock sidecar is what serialized the write" '[ -f "$L.lock" ]'
check "append: the file ends in a newline" '[ -z "$(tail -c1 "$L" | tr -d "\n")" ]'
lg append --kind review --task t-two --fields 'note=café' >/dev/null 2>&1
check "append: ensure_ascii, so the file stays 7-bit" \
  'sed -n 2p "$L" | grep -q "caf\\\\u00e9" && ! sed -n 2p "$L" | LC_ALL=C grep -q "[^ -~]"'
check "show: the accepted rows, oldest first, byte for byte as stored" \
  '[ "$(lg show)" = "$(printf %s\\n "$row1" "$(sed -n 2p "$L")")" ]'
check "show: --kind filters without touching the file" \
  '[ "$(lg show --kind review | wc -l)" = 1 ]'

# ----------------------------------------- rows this build must not hand out ----------
{ printf '{"kind":"telemetry","schema":1,"note":"a future build"}\n'      # a kind not in KINDS
  printf '{"kind":"round","schema":4,"note":"a newer schema"}\n'          # above the registered one
  printf 'not json at all\n'                                              # malformed
  printf '{"kind":"review","schema":1,"task_id":"trunc' ; } >> "$L"        # killed mid-write: no newline
before=$(awk 'END{print NR}' "$L")          # the partial tail is a line too, unlike wc -l
shown=$(lg show 2>$T/warn); rc=$?
check "show: an unknown kind is not listed" '! printf %s "$shown" | grep -q future-build'
check "show: a schema above the registered one is not listed" '! printf %s "$shown" | grep -q newer-schema'
check "show: a malformed line is not listed" '! printf %s "$shown" | grep -q "^not json"'
check "show: a truncated trailing line is not listed" '! printf %s "$shown" | grep -q trunc'
check "show: still exits 0 on a ledger with rubbish in it" '[ "$rc" = 0 ]'
check "show: what it skipped is counted on one warning line to stderr" \
  '[ "$(wc -l < "$T/warn")" = 1 ] && grep -qE "warn:.*skipped 4 line" "$T/warn"'
check "show: --kind still prints the rows it accepts" \
  '[ "$(lg show --kind round 2>/dev/null)" = "$row1" ]'
cat > $T/rawrows.py <<'PY'
# read_rows is the raw view: every line, with None where a row could not be accepted. Skipping
# a line has to stay explainable from the text alone, so this is where malformed (not JSON) and
# unknown (valid JSON, refused kind/schema) are told apart.
import json, os, sys
sys.path.insert(0, os.environ["DELEGATE_LIB_DIR"])
import ledger

lines = list(ledger.read_rows(sys.argv[1]))
print(f"count={len(lines)}")
print("none=" + ",".join(str(n) for n, raw, row in lines if row is None))
print("kinds=" + ",".join(str(row["kind"]) for _, raw, row in lines if row))
trunc = [raw for n, raw, row in lines if row is None and "trunc" in raw]
print("truncated-is-own-line=" + ("yes" if len(trunc) == 1 and trunc[0].endswith("trunc") else "no"))
print("line5=" + json.dumps(lines[4][2] if len(lines) > 4 else None))
PY
RAW=$(pylib $T/rawrows.py "$L"); RW() { printf '%s\n' "$RAW" | sed -n "s/^$1=//p"; }
check "read_rows: sees every line, including the ones show skips" '[ "$(RW count)" = "$before" ]'
check "read_rows: the unknown kind, the newer schema and the rubbish are None" \
  '[ "$(RW none)" = "3,4,5,6" ]'
check "read_rows: the accepted rows come through parsed" '[ "$(RW kinds)" = "round,review" ]'
check "read_rows: a partial trailing line is one line, and nothing else's prefix" \
  '[ "$(RW truncated-is-own-line)" = yes ]'
out=$(lg append --kind round --task after-trunc 2>$T/err); rc=$?
check "append: a partial trailing line does not cost the next row" \
  '[ "$rc" = 0 ] && [ "$(awk "END{print NR}" "$L")" = "$((before + 1))" ]'
check "append: the row after a partial line is itself well-formed" \
  '[ "$(pylib $T/shape.py "$L" $before | sed -n "s/^keys=//p")" = "kind,schema" ]'
check "show: lists it, oldest first, with the earlier rows intact" \
  '[ "$(lg show 2>/dev/null | sed -n 1p)" = "$row1" ] && lg show 2>/dev/null | tail -n 1 | grep -q after-trunc'

# --------------------------------------------------------- how a row gets built -------
cat > $T/facts.py <<'PY'
# The row as written, field by field: what --file, the scalars and --fields each contributed.
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    row = json.loads(f.readlines()[int(sys.argv[2])])
for key in sys.argv[3].split(","):
    print(f"{key}={json.dumps(row.get(key))}")
PY
F() { pylib $T/facts.py "$1" "${3:-0}" "$2"; }                 # FILE KEYS [LINE]
with_ledger() { local p=$1; shift; ( export DELEGATE_LEDGER=$p; "$here/bin/delegate" ledger "$@" ); }
M=$T/merge/ev.jsonl
printf '{"task_id":"from-body","status":"blocked","keep":"body-value","round":2}\n' > $T/body.json
out=$(with_ledger $M append --kind round --task from-cli --status done --file $T/body.json --fields 'status=fielded,n=7,ids=[1,2],todos=1,2'); rc=$?
check "append --file: exits 0 and prints nothing" '[ "$rc" = 0 ] && [ -z "$out" ]'
check "append --file: a body field nothing overrides is kept" '[ "$(F $M keep)" = "keep=\"body-value\"" ]'
check "append --file: a body field the body cannot name is kept too" '[ "$(F $M round)" = "round=2" ]'
check "merge: a scalar wins over the file body" '[ "$(F $M task_id)" = "task_id=\"from-cli\"" ]'
check "merge: --fields wins over the scalar" '[ "$(F $M status)" = "status=\"fielded\"" ]'
check "merge: kind is always the flag, and schema comes from KINDS" '[ "$(F $M kind,schema)" = "$(printf %s\\n "kind=\"round\"" "schema=3")" ]'
check "--fields: a JSON value keeps its type" '[ "$(F $M ids)" = "ids=[1, 2]" ]'
check "--fields: an int keeps its type, not a string" '[ "$(F $M n)" = "n=7" ]'
check "--fields: one key, several values, comma-joined" '[ "$(F $M todos)" = "todos=\"1,2\"" ]'
printf '{"note":"from-stdin"}' | with_ledger $M append --kind review --file -
check "append --file -: the row body comes from stdin" \
  '[ "$(F $M note 1)" = "note=\"from-stdin\"" ]'
check "append --file -: --kind still decides the kind" '[ "$(F $M kind 1)" = "kind=\"review\"" ]'
printf '[1,2]\n' > $T/notobj.json
out=$(with_ledger $M append --kind round --file $T/notobj.json 2>&1); rc=$?
check "append --file: a JSON array body is refused, one warn line, exit 0" \
  '[ "$rc" = 0 ] && [ "$(nlines "$out")" = 1 ] && printf %s "$out" | grep -q "warn: ledger append"'
printf 'not json\n' > $T/notjson.json
out=$(with_ledger $M append --kind round --file $T/notjson.json 2>&1); rc=$?
check "append --file: unparsable JSON is refused the same way" \
  '[ "$rc" = 0 ] && [ "$(nlines "$out")" = 1 ] && printf %s "$out" | grep -q "warn: ledger append"'

mkdir -p $T/task
printf 'ID=%s\nSLUG=%s\nREPO=%s\nCHAIN=%s\nBASE_REF=bench\nBASE_SHA=%s\nVERIFY=%q\nRUNNER=docker\nMODEL=m\n' \
  'repo-ledger-x' 'x' '/repo/x' 'slice-t' 'deadbeef' 'bash -c "echo hi"' > $T/task/meta.env
with_ledger $T/meta/ev.jsonl append --kind timeline --task-dir $T/task
check "--task-dir: the identity comes from meta.env, quoted values intact" \
  '[ "$(F $T/meta/ev.jsonl task_id,slug,step,repo,chain,base_ref,base_sha,verify,runner)" = "$(printf %s\\n \
      "task_id=\"repo-ledger-x\"" "slug=\"x\"" "step=\"x\"" "repo=\"/repo/x\"" "chain=\"slice-t\"" \
      "base_ref=\"bench\"" "base_sha=\"deadbeef\"" "verify=\"bash -c \\\"echo hi\\\"\"" "runner=\"docker\"")" ]'
check "--task-dir: it is a default, not an override: --task wins" \
  '[ "$(with_ledger $T/meta2/ev.jsonl append --kind round --task cli-id --task-dir $T/task; F $T/meta2/ev.jsonl task_id)" = "task_id=\"cli-id\"" ]'
out=$(with_ledger $M append --kind round --task-dir $T/nosuchtask 2>&1); rc=$?
check "--task-dir: a task dir without meta.env is one warn line, exit 0, no row" \
  '[ "$rc" = 0 ] && [ "$(nlines "$out")" = 1 ] && printf %s "$out" | grep -q "no meta.env"'

# --------------------------------------------------- append never costs anything ------
before=$(awk 'END{print NR}' "$L")
for bad in '--kind nosuchkind --task t' '--task t' '--kind round --bogus-flag' '--kind round --status' \
           '--kind round --file /no/such/file.json' '--kind round --exit not-a-number'; do
  out=$(lg append $bad 2>&1); rc=$?
  check "append $bad: one warn line, exit 0" \
    '[ "$rc" = 0 ] && [ "$(nlines "$out")" = 1 ] && printf %s "$out" | grep -q "^delegate: warn: ledger append: "'
done
check "append: the refused calls added nothing to the ledger" \
  '[ "$(awk "END{print NR}" "$L")" = "$before" ]'
touch $T/plain
out=$( ( export DELEGATE_LEDGER=$T/plain/ev.jsonl; "$here/bin/delegate" ledger append --kind round --task t ) 2>&1 ); rc=$?
check "append: a ledger path whose parent cannot exist is one warn line, exit 0" \
  '[ "$rc" = 0 ] && [ "$(nlines "$out")" = 1 ] && printf %s "$out" | grep -q "warn: ledger append"'
( export DELEGATE_LEDGER=$T/adir; mkdir -p $T/adir
  out=$( "$here/bin/delegate" ledger show 2>$T/adir.err ); rc=$?
  check "show: an unreadable ledger is an empty listing, exit 0" '[ "$rc" = 0 ] && [ -z "$out" ]'
  check "show: and it stays silent about it: no rows, no fuss" '[ ! -s $T/adir.err ]' )
out=$( ( export DELEGATE_LEDGER=$T/gone/ev.jsonl; "$here/bin/delegate" ledger show ) 2>$T/gone.err ); rc=$?
check "show: a missing ledger is an empty listing, not an error" \
  '[ "$rc" = 0 ] && [ -z "$out" ] && [ ! -s $T/gone.err ] && [ ! -e $T/gone ]'

# --------------------------------------------------- many writers, whole rows -------
C=$T/conc/ev.jsonl
for i in 1 2 3 4 5 6 7 8; do
  ( with_ledger $C append --kind round --task "w$i" --fields "worker=$i"
    with_ledger $C append --kind round --task "w${i}-b" --fields "worker=$i" ) &
done
wait
check "concurrency: 8 processes x 2 appends land as 16 lines" '[ "$(wc -l < "$C")" = 16 ]'
pylib - "$C" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["DELEGATE_LIB_DIR"])
seen, torn = set(), 0
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        row = json.loads(line)
        assert row["kind"] == "round" and row["schema"] == 3 and isinstance(row["task_id"], str)
        seen.add(row["task_id"])
    except Exception:
        torn += 1
print(f"torn={torn} distinct={len(seen)}")
sys.exit(0 if torn == 0 and len(seen) == 16 else 1)
PY
rc=$?
check "concurrency: every line is one whole row, none interleaved or torn" "[ $rc -eq 0 ]"

# ------------------------------------------------ SIGINT mid-append, then recovery --
S=$T/sigint/ev.jsonl
mkdir -p "$T/sigint"
printf '{"kind":"round","schema":1,"task_id":"before-signal"}\n' > "$S"
pylib - "$S" <<'PY'
import fcntl, os, signal, sys
path = sys.argv[1]
f = open(path, "a", encoding="utf-8")
lock = open(path + ".lock", "w")
fcntl.flock(lock, fcntl.LOCK_EX)
f.write('{"kind":"round","schema":1,"task_id":"interrupted","text":"' + "x" * 20000)
f.flush()                                       # bytes on the file, the line still open
signal.signal(signal.SIGINT, signal.SIG_DFL)    # as a killed shell leaves it: signal default
os.kill(os.getpid(), signal.SIGINT)
PY
sig_rc=$?
check "SIGINT mid-append: the writer died of SIGINT, not of a clean exit" '[ "$sig_rc" = 130 ]'
check "SIGINT mid-append: it left a torn tail, no newline" '[ -n "$(tail -c1 "$S" | tr -d "\n")" ]'
out=$(with_ledger $S append --kind round --task after-signal 2>&1); rc=$?
check "SIGINT mid-append: the next append still succeeds, exit 0, silently" \
  '[ "$rc" = 0 ] && [ -z "$out" ] && [ "$(awk "END{print NR}" "$S")" = 3 ]'
check "SIGINT mid-append: the rows before and after survive, the torn one reads as nothing" \
  '[ "$(pylib $T/rawrows.py "$S" | sed -n "s/^kinds=//p")" = "round,round" ]'

# ------------------------------------------- derive_timeline: the R4 derivation -----
# A round's raw events file, as the OpenCode server streams it. The payloads below must never
# reach the derivation; the times, token counts and reasons must; and repeated tool_use lines
# for one call are one entry.
cat > $T/events.jsonl <<'FIX'
{"type":"step_start","timestamp":1000,"part":{"type":"step-start"}}
not json at all
{"type":"step_finish","timestamp":3000,"part":{"type":"step-finish","tokens":{"input":100,"output":50,"reasoning":10,"cache":{"read":7,"write":3}},"reason":"tool-calls"}}
{"type":"tool_use","timestamp":3500,"part":{"type":"tool","tool":"bash","callID":"call_a1","id":"call_a1","state":{"status":"completed","input":"SECRETINPUT","output":"SECRETOUTPUT","title":"SECRET-TITLE","metadata":{"k":"SECRET-META"},"time":{"start":3400,"end":4800}}}}
{"type":"step_start","timestamp":5000,"part":{"type":"step-start"}}
{"type":"tool_use","timestamp":6000,"part":{"type":"tool","tool":"grep","callID":"call_b2","id":"call_b2","state":{"status":"pending","input":"hush","time":{"start":5800}}}}
{"type":"tool_use","timestamp":8000,"part":{"type":"tool","tool":"grep","callID":"call_b2","id":"call_b2","state":{"status":"completed","input":"hush2","output":"hush3","time":{"start":5800,"end":8100}}}}
{"type":"text","timestamp":9000,"part":{"type":"text","text":"SECRETTEXT foobarbaz"}}
{"type":"step_finish","timestamp":9500,"part":{"type":"step-finish","tokens":{"input":1,"output":2,"reasoning":0,"cache":{"read":0,"write":0}},"reason":"end-turn"}}
{"type":"step_start","timestamp":10000,"part":{"type":"step-start"}}
FIX
pylib - "$T" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["DELEGATE_LIB_DIR"])
import ledger

tl = ledger.derive_timeline(os.path.join(sys.argv[1], "events.jsonl"))
s0, s1, s2 = tl["steps"]
g = {t["tool"]: t for t in tl["tools"]}
blob = json.dumps(tl)
cases = [
    (len(tl["steps"]) == 3, "one entry per step, unparsable lines skipped"),
    (s0["start"] == 1000 and s0["end"] == 3000, "a step spans start event to finish event"),
    (s0["reason"] == "tool-calls" and s1["reason"] == "end-turn", "step_finish carries the reason"),
    ((s0["input"], s0["output"], s0["reasoning"], s0["cache_read"], s0["cache_write"])
        == (100, 50, 10, 7, 3), "tokens split cache read/write"),
    (s0["ctx"] == 110 and s1["ctx"] == 1,
        "every step carries its context size: input + cache.read + cache.write"),
    (s2["ctx"] is None, "an unclosed step has no context size to record"),
    (tl["events"] == [], "no failed tool call, no reliability event"),
    ((s1["input"], s1["output"]) == (1, 2), "each step keeps its own tokens"),
    (s1["start"] == 5000 and s1["end"] == 9500, "step 2 boundaries"),
    (s2["start"] == 10000 and s2["end"] == 10000 and s2["reason"] is None,
        "an unclosed step closes at the last timestamp, reason null"),
    ((s2["input"], s2["output"], s2["reasoning"], s2["cache_read"], s2["cache_write"])
        == (0, 0, 0, 0, 0), "an unclosed step has no tokens (they arrive only on finish)"),
    (len(tl["tools"]) == 2 and list(g) == ["bash", "grep"],
        "one entry per tool call: the repeated pending+completed grep merged in place"),
    (g["grep"]["status"] == "completed" and g["grep"]["start"] == 5800 and g["grep"]["end"] == 8100,
        "the merged entry keeps first start, last end and last status"),
    (g["bash"]["start"] == 3400 and g["bash"]["end"] == 4800 and g["bash"]["status"] == "completed",
        "tool name, status and times, and nothing else"),
    (tl["totals"] == {"input": 101, "output": 52, "reasoning": 10,
        "cache_read": 7, "cache_write": 3}, "totals sum the step_finish tokens"),
    (all(sum(s[k] for s in tl["steps"]) == tl["totals"][k]
         for k in ("input", "output", "reasoning", "cache_read", "cache_write")),
        "totals equal the sum over steps"),
    (not any(w in blob for w in ("SECRETINPUT", "SECRETOUTPUT", "SECRETTEXT", "SECRET-TITLE",
        "SECRET-META", "foobarbaz", "hush", "call_a1", "call_b2", "callID", "metadata", "text")),
        "R4: no tool input/output/text/title/metadata and no call ids in the derivation"),
]
bad = [m for ok, m in cases if not ok]
for m in bad:
    print("assert FAIL: " + m)

orph = ledger.derive_timeline(os.path.join(sys.argv[1], "nosuch.jsonl"))
if orph != {"steps": [], "tools": [], "events": [],
            "totals": {"input": 0, "output": 0, "reasoning": 0, "cache_read": 0, "cache_write": 0}}:
    print("assert FAIL: a missing events file derives to empty, got " + json.dumps(orph))

open(os.path.join(sys.argv[1], "orphan.jsonl"), "w").write(
    '{"type":"step_finish","timestamp":7000,"part":{"type":"step-finish",'
    '"tokens":{"input":5},"reason":"stop"}}\n')
o = ledger.derive_timeline(os.path.join(sys.argv[1], "orphan.jsonl"))
if not (len(o["steps"]) == 1 and o["steps"][0]["start"] == 7000 and o["steps"][0]["end"] == 7000
        and o["steps"][0]["input"] == 5 and o["totals"]["input"] == 5):
    print("assert FAIL: a finish whose start never made the log still counts, at its own instant")

# timeline schema 2: the reliability events — the two tool-error kinds split by marker,
# a planted secret in each error text that must not reach the record
open(os.path.join(sys.argv[1], "errs.jsonl"), "w").write(
    '{"type":"step_start","timestamp":100,"part":{"type":"step-start"}}\n'
    '{"type":"tool_use","timestamp":110,"part":{"type":"tool","tool":"edit","id":"x1",'
    '"state":{"status":"error","error":"The arguments provided to the tool are invalid: SECRET-BADARGS",'
    '"time":{"start":105,"end":110}}}}\n'
    '{"type":"step_finish","timestamp":120,"part":{"type":"step-finish",'
    '"tokens":{"input":40000,"cache":{"read":1,"write":1}},"reason":"tool-calls"}}\n'
    '{"type":"step_start","timestamp":130,"part":{"type":"step-start"}}\n'
    '{"type":"tool_use","timestamp":140,"part":{"type":"tool","tool":"bash","id":"x2",'
    '"state":{"status":"error","error":"SECRET-BOOM","time":{"start":135,"end":140}}}}\n'
    '{"type":"step_finish","timestamp":150,"part":{"type":"step-finish",'
    '"tokens":{"input":999,"reasoning":1},"reason":"tool-calls"}}\n')
e = ledger.derive_timeline(os.path.join(sys.argv[1], "errs.jsonl"))
eblob = json.dumps(e)
cases2 = [
    (e["events"] == [{"kind": "tool-error:invalid-args", "step": 1, "ctx": 40002},
                     {"kind": "tool-error", "step": 2, "ctx": 999}],
     "events: one record per failed call, the invalid-args marker splits the kind, step and ctx name the place"),
    (not any(w in eblob for w in ("SECRET-BADARGS", "SECRET-BOOM", "x1", "x2")),
     "R4: the error text never reaches the record"),
]

# timeline schema 2: the shared events merge — new-format nudges at their recorded
# position, an old-format line at null/unknown, a verify-fail from a non-zero verify_rc
merged = ledger.timeline_events(e, "nudge: malformed step=1 ctx=40002\n"
                                "nudge: no-status\n"
                                "nudge: something-else entirely\n", 1)
cases2 += [
    (merged == [{"kind": "nudge:no-status", "step": None, "ctx": None},
                {"kind": "nudge:something-else", "step": None, "ctx": None},
                {"kind": "nudge:malformed", "step": 1, "ctx": 40002},
                {"kind": "tool-error:invalid-args", "step": 1, "ctx": 40002},
                {"kind": "tool-error", "step": 2, "ctx": 999},
                {"kind": "verify-fail", "step": 2, "ctx": 999}],
     "timeline_events merges the walk, the nudges (old format recorded at null, never a "
     "position nobody wrote) and the verify-fail from verify_rc, in step order, nulls first"),
    (ledger.timeline_events(e, "nudge: malformed step=1 ctx=40002", 0,
                            fallback=(57, 123456)) [0] ==
     {"kind": "nudge:malformed", "step": 1, "ctx": 40002},
     "a recorded position is kept as written, and verify_rc 0 writes no verify-fail"),
    (ledger._final_position({"steps": []}, (57, 123456)) == (57, 123456),
     "with no closed step the fallback pair from the round row is used"),
    (ledger._final_position(None) == (0, 0), "and with neither, position zero"),
]
cases += cases2
bad = [m for ok, m in cases if not ok]
PY
rc=$?
check 'derive_timeline: all shape, rollup and R4-redaction assertions' "[ $rc -eq 0 ]"

# =============================================== T3: the review row (R5) =========
# One row per `delegate ledger review`, in the design's field order, from flags the orchestrator
# typed: its verdict is data, never a document to parse (R5). Bad verdict input is refused with
# die; a ledger that cannot be written is one warn line and exit 0.
RV=$T/review/ev.jsonl
out=$(with_ledger $RV review t-a --verdict accepted --bugs high=1,low=2 --lines-changed 40 \
      --note 'landed as is, café' 2>&1); rc=$?
check "review: exits 0 and says nothing" '[ "$rc" = 0 ] && [ -z "$out" ]'
check "review: exactly one row" '[ "$(wc -l < "$RV")" = 1 ]'
cat > $T/review.py <<'PY'
# The row as written: the design's key order, the flags typed into the right fields, ts UTC.
import json, os, sys
sys.path.insert(0, os.environ["DELEGATE_LIB_DIR"])
import ledger

line = open(sys.argv[1], encoding="utf-8").read().splitlines()[int(sys.argv[2])]
row = json.loads(line)
print("keys_ok=" + ("yes" if list(row) == ["kind", "schema"] + list(ledger.REVIEW_KEYS) else "no " + ",".join(row)))
print("row=" + json.dumps({k: row.get(k) for k in ledger.REVIEW_KEYS if k != "ts"}))
print("note=" + json.dumps(row.get("note")))
print("ts=" + ("utc" if str(row.get("ts", "")).endswith("Z") and "T" in str(row.get("ts", "")) else "missing"))
PY
RS=$(pylib $T/review.py "$RV" 0); RVV() { printf '%s\n' "$RS" | sed -n "s/^$1=//p"; }
check "review: kind, schema then the design's review fields, in order" \
  '[ "$(RVV keys_ok)" = yes ]'
check "review: the flags land in the design's fields, typed" \
  '[ "$(RVV row)" = "{\"task_id\": \"t-a\", \"round\": null, \"verdict\": \"accepted\", \"bugs_high\": 1, \"bugs_medium\": 0, \"bugs_low\": 2, \"lines_changed\": 40, \"note\": \"landed as is, caf\\u00e9\"}" ]'
check "review: a row without --round links to nothing, and says so with null" \
  '[ "$(F $RV round)" = "round=null" ]'
check "review: --note is the only prose the row carries" '[ "$(RVV note)" = "\"landed as is, caf\\u00e9\"" ]'
check "review: ts is there, ISO-8601 UTC" '[ "$(RVV ts)" = utc ]'
check "review: show --kind review lists it" \
  '[ "$(with_ledger $RV show --kind review | wc -l)" = 1 ]'

# --round defaults to the task's highest round row already in the ledger (R5's link).
RD=$T/rnd/ev.jsonl
with_ledger $RD append --kind round --task t-r --fields round=3 >/dev/null 2>&1
with_ledger $RD append --kind round --task t-r --fields round=1 >/dev/null 2>&1
with_ledger $RD append --kind round --task other --fields round=9 >/dev/null 2>&1
with_ledger $RD review t-r --verdict fixed --lines-changed 0 >/dev/null 2>&1
check "review: no --round takes the task's highest round row, not its newest line" \
  '[ "$(F $RD round 3)" = "round=3" ]'
with_ledger $RD review t-none --verdict rejected >/dev/null 2>&1
check "review: a task with no round row is recorded with round null" \
  '[ "$(F $RD round 4)" = "round=null" ]'
with_ledger $RD review t-r --verdict accepted --round 6 >/dev/null 2>&1
check "review: --round given is --round taken" \
  '[ "$(F $RD round 5)" = "round=6" ]'
check "review: three calls, three rows (one per call)" '[ "$(wc -l < "$RD")" = 6 ]'

# Bad input is refused: this command takes the orchestrator's judgement as input.
for bad in 't --verdict maybe' 't --bugs high=1' 't --verdict accepted --bugs high=x' \
           't --verdict accepted --bugs colour=1' 't --verdict accepted --lines-changed many' \
           't --verdict accepted --round 1.5' 't --verdict accepted --bogus-flag x' \
           '--verdict accepted'; do
  out=$(with_ledger $RV review $bad 2>&1); rc=$?
  check "review $bad: refused, non-zero, no row" \
    '[ "$rc" != 0 ] && [ "$(wc -l < "$RV")" = 1 ] && printf %s "$out" | grep -q "ledger review"'
done
out=$(with_ledger $RV review --verdict accepted --bugs high=1 t 2>&1); rc=$?
check "review: the task id comes first, or it is refused" \
  '[ "$rc" != 0 ] && [ "$(wc -l < "$RV")" = 1 ]'

# A ledger this cannot write costs one warn line and nothing else (never-fatal is about the file).
out=$(with_ledger $T/plain/ev.jsonl review t-a --verdict accepted 2>&1); rc=$?
check "review: an unwritable ledger is one warn line, exit 0" \
  '[ "$rc" = 0 ] && [ "$(nlines "$out")" = 1 ] && printf %s "$out" | grep -q "^delegate: warn: ledger review: "'
out=$(with_ledger off review t-a --verdict accepted 2>&1); rc=$?
check "review: DELEGATE_LEDGER=off says so once, exits 0, and writes no file called off" \
  '[ "$rc" = 0 ] && printf %s "$out" | grep -q "warn: ledger review" && [ ! -e "$here/off" ]'

u=$(DELEGATE_LIB_DIR=$here/lib python3 - <<'PY'
# lib/ledger.py's review contract, without the CLI: the builder's order, what it refuses, and
# parse_bugs' zeros; latest_round on a ledger that is not there.
import os, sys
sys.path.insert(0, os.environ["DELEGATE_LIB_DIR"])
import ledger

def raises(fn):
    try:
        fn(); return "accepted"
    except ValueError:
        return "ValueError"

r = ledger.build_review_row({"task_id": "t", "round": "2", "verdict": "fixed",
                             "bugs": "high=2,medium=1", "lines_changed": "9", "note": "n"})
cases = [
    (list(r) == list(ledger.REVIEW_KEYS), "build_review_row: the design's keys, in order"),
    ((r["round"], r["lines_changed"], r["bugs_high"], r["bugs_medium"], r["bugs_low"])
        == (2, 9, 2, 1, 0), "build_review_row: the numbers are numbers, an absent severity 0"),
    (r["note"] == "n" and r["ts"].endswith("Z"), "build_review_row: note and ts"),
    (ledger.build_review_row({"task_id": "t", "verdict": "accepted"})["round"] is None,
     "build_review_row: no round means no link, not round 0"),
    (raises(lambda: ledger.build_review_row({"task_id": "t"})) == "ValueError",
     "build_review_row: no verdict raises"),
    (raises(lambda: ledger.build_review_row({"task_id": "t", "verdict": "maybe"})) == "ValueError",
     "build_review_row: an unknown verdict raises"),
    (raises(lambda: ledger.parse_bugs("high=x")) == "ValueError",
     "parse_bugs: a non-number raises instead of filing a silent zero"),
    (ledger.parse_bugs("") == {"bugs_high": 0, "bugs_medium": 0, "bugs_low": 0},
     "parse_bugs: nothing named is nothing found"),
    (ledger.parse_bugs({"high": 2, "low": 1})["bugs_high"] == 2
        and ledger.parse_bugs({"high": 2})["bugs_medium"] == 0,
     "parse_bugs: a Mapping of severities comes through this same door, zeros and all"),
    (ledger.parse_bugs({"bugs_low": 3})["bugs_low"] == 3,
     "parse_bugs: a Mapping keyed by the row's own field names works too"),
    (raises(lambda: ledger.parse_bugs({"colour": 1})) == "ValueError",
     "parse_bugs: an unknown severity raises whatever way it arrives"),
    (ledger.latest_round("/no/such/ledger.jsonl", "t") is None,
     "latest_round: a ledger that is not there holds no round"),
]
bad = [m for ok, m in cases if not ok]
for m in bad:
    print("MISMATCH " + m)
print(f"checked={len(cases)} bad={len(bad)}")
PY
)
printf '%s\n' "$u" | grep '^MISMATCH' || true
check "the review builder and bug parser hold their contracts (12 checks)" \
  'printf "%s\n" "$u" | grep -qE "^checked=12 bad=0$"'

# ============================================ T3: the one-time import (R8) ========
# Every task record that still exists becomes the rows a live round would have written, through
# the same builders, marked source:"import"; what the record no longer carries stays empty. Then
# idempotent, then read-only over the records. Fixtures are written the way `delegate run` leaves
# them: meta.env as `printf %q`, spec.md, rounds/ with report.json + events.jsonl + diffstat.
ST=$T/state
REPO_FIX=$T/repo
imp_task() { # ID MODEL CHAIN ROUND...
  local id=$1 model=$2 chain=$3; shift 3
  mkdir -p "$ST/$id/rounds"
  printf '# the stored spec\nsecond line\n' > "$ST/$id/spec.md"
  { printf 'ID=%q\nSLUG=%q\nREPO=%q\nWORKTREE=%q\nBRANCH=%q\n' "$id" "${id#repo-}" "$REPO_FIX" "$ST/$id/wt" "delegate/${id#repo-}"
    printf 'BASE_REF=%q\nBASE_SHA=%q\nGIT_COMMON=\nMODEL=%q\nVERIFY=%q\n' main abc1234 "$model" 'bash -c "echo hi"'
    printf 'SERVICE=\nCOPIED=\nSESSION=\nCREATED=\nWT_GITDIR=\n'
    printf 'READS=\nGITHUB=0\nEGRESS=filtered\nHERE=0\nRUNNER=native\nRAW=0\n'
    printf 'ORB_FILE=\nGRANTS=\nALLOW=\nCHAIN=%q\n' "$chain"; } > "$ST/$id/meta.env"   # no EFFORT: an older record
  local n
  for n in "$@"; do
    mkdir -p "$ST/$id/rounds/$n"
    printf ' 1 file changed, 4 insertions(+), 1 deletion(-)\n' > "$ST/$id/rounds/$n/diffstat"
    cat > "$ST/$id/rounds/$n/events.jsonl" <<'EV'
{"type":"step_start","timestamp":2000,"part":{"type":"step-start"}}
{"type":"tool_use","timestamp":3000,"part":{"type":"tool","tool":"bash","id":"c1","state":{"status":"completed","input":"SECRETINPUT","output":"SECRETOUTPUT","time":{"start":2500,"end":3000}}}}
{"type":"step_finish","timestamp":4000,"part":{"type":"step-finish","tokens":{"input":7,"output":3,"reasoning":1,"cache":{"read":1,"write":0}},"reason":"end-turn"}}
EV
    python3 -c 'import json, sys
json.dump({"round": int(sys.argv[1]), "status": "done", "worker_status": "done", "exit": 0,
           "verify_rc": None, "duration_s": 30, "steps": 1, "tool_calls": 1, "tool_errors": [],
           "errors": [], "todos": [], "nudges": {"no-status": 1}, "final_context_tokens": 8,
           "model": sys.argv[2], "commit": "cafe"}, open(sys.argv[3], "w"))' \
      "$n" "$model" "$ST/$id/rounds/$n/report.json"
  done
}
mkdir -p "$ST/plain-dir-no-meta"                     # not a task: no meta.env
imp_task repo-imp-a hard-model chain-x 1 2
imp_task repo-imp-b soft-model "" 1
rm "$ST/repo-imp-b/rounds/1/events.jsonl" "$ST/repo-imp-b/rounds/1/diffstat"  # its events are pruned
mkdir -p "$ST/repo-imp-c/rounds/1"                   # a round that never reported
LI=$ST/ledger/events.jsonl            # the default path: inside the state dir, beside task dirs
runimport() { ( export DELEGATE_STATE=$ST DELEGATE_MODEL=soft-model DELEGATE_MODEL_HARD=hard-model
                [ $# -gt 0 ] && export DELEGATE_LEDGER=$1
                "$here/bin/delegate" ledger import "${@:2}" ); }
out=$(runimport '' 2>$T/imp.err); rc=$?
check "import: exits 0 and prints one summary line, in the spec's words" \
  '[ "$rc" = 0 ] && [ "$(nlines "$out")" = 1 ] && [ "$out" = "imported 3, skipped 0, tasks 2" ]'
check "import: it said nothing on stderr" '[ ! -s $T/imp.err ]'
check "import: three reported rounds became five rows — a pruned round writes its round row alone" \
  '[ "$(wc -l < "$LI")" = 5 ]'
check "import: with no override its file is \$DELEGATE_STATE/ledger/events.jsonl, beside the task dirs" \
  '[ -f "$ST/ledger/events.jsonl" ]'
check "R4: no tool input or output text reached the imported rows" \
  '! grep -qE "SECRETINPUT|SECRETOUTPUT" "$LI"'
cat > $T/tlshape.py <<'PY'
# R4 on an imported timeline row: a tool entry is name, status, start, end. Nothing else — no
# call id, no input, no output — whatever the events file held.
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if '"kind":"timeline"' in l]
tools = [t for r in rows for t in r["tools"]]
sys.exit(0 if tools and all(list(t) == ["tool", "status", "start", "end"] for t in tools) else 1)
PY
check "R4: an imported timeline row carries only the four tool fields, never a call id" \
  'pylib $T/tlshape.py "$LI"'
out=$(runimport $LI 2>$T/imp2.err); rc=$?
check "import: run twice, the second adds nothing to the counts or the file" \
  '[ "$rc" = 0 ] && [ "$out" = "imported 0, skipped 3, tasks 2" ] && [ "$(wc -l < "$LI")" = 5 ]'
before=$(sed -n '1,2p' "$LI" | sha256sum)
runimport $LI >/dev/null 2>&1
check "import: the rows already written are untouched, byte for byte" \
  '[ "$(sed -n "1,2p" "$LI" | sha256sum)" = "$before" ]'
# A (task id, round) the ledger holds from a LIVE round is deduped too — the key is the pair, not
# the pair plus provenance.
LV=$T/implive/events.jsonl
( export DELEGATE_LEDGER=$LV; "$here/bin/delegate" ledger append --kind round \
    --task repo-imp-b --fields round=1 >/dev/null 2>&1 )
out=$(runimport $LV 2>&1); rc=$?
check "import: deduped against any round row, whoever wrote it: one live round skipped" \
  '[ "$rc" = 0 ] && [ "$out" = "imported 2, skipped 1, tasks 2" ]'
check "import: and the live row's pair gained no imported twin" \
  '[ "$(grep -c "repo-imp-b" "$LV")" = 1 ]'
check "import: the summary counts the round rows it wrote as three rounds, five rows" \
  '[ "$(grep -c "\"kind\":\"round\"" "$LV")" = 3 ] && [ "$(grep -c "\"kind\":\"timeline\"" "$LV")" = 2 ]'
out=$(runimport $T/nope/events.jsonl --state $T/nostate 2>$T/imp3.err); rc=$?
check "import: a state dir that is not there is one warn line, a zero summary, exit 0" \
  '[ "$rc" = 0 ] && [ "$out" = "imported 0, skipped 0, tasks 0" ] \
     && printf %s "$(cat "$T/imp3.err")" | grep -q "warn: ledger import"'
out=$( ( export DELEGATE_STATE=$T/nostate DELEGATE_LEDGER=$T/late3/events.jsonl \
         DELEGATE_MODEL=soft-model DELEGATE_MODEL_HARD=hard-model
         "$here/bin/delegate" ledger import --state "$ST" ) 2>&1 ); rc=$?
check "import: --state names the records to walk, over DELEGATE_STATE" \
  '[ "$rc" = 0 ] && [ "$out" = "imported 3, skipped 0, tasks 2" ]'
out=$( ( export DELEGATE_STATE=$ST; "$here/bin/delegate" ledger import --no-such-flag ) 2>&1 ); rc=$?
check "import: an unknown flag is refused with the usage, non-zero" \
  '[ "$rc" != 0 ] && printf %s "$out" | grep -q "usage: delegate ledger import"'
out=$(with_ledger off import --state $ST 2>&1); rc=$?
check "import: DELEGATE_LEDGER=off imports nothing, says so once, exit 0" \
  '[ "$rc" = 0 ] && printf %s "$out" | grep -q "warn: ledger import" && [ ! -e "$here/off" ]'
# R8 is an import, not a migration: the records it read are exactly as they were.
tree=$(find "$ST" -type f -printf '%p %s %T@\n' | LC_ALL=C sort | sha256sum)
runimport $T/late2/events.jsonl >/dev/null 2>&1
check "import: read-only over the task records — no file added, touched or moved" \
  '[ "$(find "$ST" -type f -printf "%p %s %T@\n" | LC_ALL=C sort | sha256sum)" = "$tree" ]'

# The recovery table, field by field (§Import): what meta.env + report.json + the files on disk
# still say, and what an import must leave null instead of guessing.
cat > $T/imported.py <<'PY'
import hashlib, json, os, re, sys
from datetime import datetime, timezone
sys.path.insert(0, os.environ["DELEGATE_LIB_DIR"])
import ledger

L, st = os.environ["DELEGATE_LEDGER"], os.environ["DELEGATE_STATE"]
rows = [r for _n, _r, r in ledger.read_rows(L) if r]
rounds = [r for r in rows if r["kind"] == "round"]
tls = [r for r in rows if r["kind"] == "timeline"]
by = {(r["task_id"], r["round"]): r for r in rounds}
a1, a2, b1 = by[("repo-imp-a", 1)], by[("repo-imp-a", 2)], by[("repo-imp-b", 1)]
iso = lambda s: datetime.fromtimestamp(int(s), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
spec_hash = hashlib.sha256(open(os.path.join(st, "repo-imp-a", "spec.md"), "rb").read()).hexdigest()
derived = ledger.derive_timeline(os.path.join(st, "repo-imp-a", "rounds", "1", "events.jsonl"))
mtime = int(os.path.getmtime(os.path.join(st, "repo-imp-a", "rounds", "1", "report.json")))
cases = [
    (len(rounds) == 3 and len(tls) == 2, "one round row per reported round; a timeline only where events survive"),
    (all(list(r) == ["kind", "schema"] + list(ledger.ROUND_KEYS) for r in rounds),
     "round rows keep the design's key order"),
    (all(r["source"] == "import" for r in rows), "every imported row says source:import"),
    (a1["task_id"] == "repo-imp-a" and a1["run_id"] == "repo-imp-a" and a1["slug"] == "imp-a"
     and a1["step"] == "imp-a" and a1["repo"] == os.environ["EXPECT_REPO"] and a1["chain"] == "chain-x",
     "identity from meta.env, %q-unquoted; step is the slug, run_id the task id"),
    (b1["chain"] is None, "an empty CHAIN is null on the row, not an empty string"),
    (a1["base_ref"] == "main" and a1["base_sha"] == "abc1234"
     and a1["verify"] == 'bash -c "echo hi"' and a1["runner"] == "native",
     "base ref/sha, verify and runner from meta.env"),
    (a1["spec_hash"] == spec_hash, "spec_hash: sha256 of the dir's spec.md"),
    (a1["model"] == "hard-model" and b1["model"] == "soft-model",
     "model from each round's own report.json"),
    (a1["effort"] == "hard" and b1["effort"] == "normal",
     "effort inferred: hard iff the round's model is the configured hard model, and that differs from the model"),
    (a1["effort_source"] == "inferred" and b1["effort_source"] == "inferred",
     "an inferred effort is labelled inferred on the row"),
    (all(a1[k] is None for k in ("endpoint", "delegate_version", "rules_hash", "timeout_s",
                                 "edit_cap", "parallel_rounds")),
     "per-round conditions no longer recoverable are null — never guessed (R7)"),
    (a1["image_stamp"] == "", "image_stamp empty rather than null, as the native runner writes it"),
    (a1["diff_lines"] == 5, "diff_lines parsed from the round's captured diffstat"),
    (b1["diff_lines"] is None and b1["input_tokens"] is None,
     "a round with no diffstat and no events knows neither"),
    (a1["round"] == 1 and a1["retries"] == 0 and a2["round"] == 2 and a2["retries"] == 1,
     "retries is round minus one, as on a live row"),
    (a1["status"] == "done" and a1["worker_status"] == "done" and a1["exit"] == 0
     and a1["verify_rc"] is None and a1["nudges"] == {"no-status": 1}
     and a1["final_context_tokens"] == 8 and a1["duration_s"] == 30 and a1["steps"] == 1,
     "outcome and counters straight from report.json"),
    (a1["round_start"] == iso(2) and a1["round_end"] == iso(mtime),
     "round_start is the first step's start; round_end the report's own mtime"),
    (a1["input_tokens"] == derived["totals"]["input"]
     and a1["output_tokens"] == derived["totals"]["output"]
     and a1["reasoning_tokens"] == derived["totals"]["reasoning"]
     and a1["cache_read"] == derived["totals"]["cache_read"]
     and a1["cache_write"] == derived["totals"]["cache_write"],
     "token sums come from the timeline derivation over the round's events, as live"),
    (tls[0]["task_id"] == a1["task_id"] and tls[0]["round"] == a1["round"]
     and tls[0]["ts"] == a1["ts"], "the timeline row joins its round row on identity and shares its ts"),
    (tls[0]["steps"] == derived["steps"] and tls[0]["tools"] == derived["tools"],
     "the imported timeline is the same derivation the live path writes (R8: one code path)"),
    (list(tls[0]) == ["kind", "schema", "task_id", "run_id", "round", "steps", "tools",
                      "events", "source", "ts"],
     "the timeline row's keys, in order, source included"),
    (all("ctx" in s for r in tls for s in r["steps"]),
     "every imported step carries a ctx key (timeline schema 2)"),
    (a2["ts"] == b1["ts"] and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", a1["ts"]),
     "ts is one append-time stamp, ISO-8601 UTC"),
]
bad = [m for ok, m in cases if not ok]
for m in bad:
    print("MISMATCH " + m)
print(f"checked={len(cases)} bad={len(bad)}")
PY
chk=$(EXPECT_REPO=$REPO_FIX DELEGATE_LEDGER=$LI DELEGATE_STATE=$ST pylib $T/imported.py 2>&1)
printf '%s\n' "$chk" | grep '^MISMATCH' || true
check "the imported rows answer to §Import's recovery table (23 checks)" \
  'printf "%s\n" "$chk" | grep -qE "^checked=23 bad=0$"'

# A record this build cannot read is a skipped task and one warn line, never a failure.
mkdir -p $T/state2 && cp -a "$ST/repo-imp-a" $T/state2/
chmod 000 $T/state2/repo-imp-a/meta.env
out=$( ( export DELEGATE_STATE=$T/state2 DELEGATE_LEDGER=$T/bad/events.jsonl \
         DELEGATE_MODEL=soft-model DELEGATE_MODEL_HARD=hard-model
         "$here/bin/delegate" ledger import ) 2>$T/bad.err ); rc=$?
chmod 644 $T/state2/repo-imp-a/meta.env
check "import: an unreadable record exits 0 and says imported 0" \
  '[ "$rc" = 0 ] && [ "$out" = "imported 0, skipped 1, tasks 1" ]'
check "import: and names the task it could not read, on one warn line" \
  '[ "$(nlines "$(cat "$T/bad.err")")" = 1 ] && grep -q "warn: ledger import: repo-imp-a" "$T/bad.err"'

# The two writer-side failures, distinguished on purpose: bad input is fatal, an unwritable file
# and a broken record are not (the spec's never-fatal rule is about the ledger, not the verdict).
RO=$T/ro/ev.jsonl; mkdir -p "$T/ro"; : > "$RO"; chmod 400 "$RO"
out=$(with_ledger $RO review t-a --verdict accepted 2>&1); rc=$?
chmod 644 "$RO"
check "review: a ledger file that refuses writes is one warn line, exit 0, not a die" \
  '[ "$rc" = 0 ] && [ "$(nlines "$out")" = 1 ] && printf %s "$out" | grep -q "^delegate: warn: ledger review: "'

S3=$T/state3; rm -rf "$S3"; mkdir -p "$S3"; cp -a "$ST/repo-imp-a" "$S3/"
printf 'this was a report once' > "$S3/repo-imp-a/rounds/2/report.json"
out=$( ( export DELEGATE_STATE=$S3 DELEGATE_LEDGER=$T/corrupt/events.jsonl \
         DELEGATE_MODEL=soft-model DELEGATE_MODEL_HARD=hard-model
         "$here/bin/delegate" ledger import ) 2>$T/corrupt.err ); rc=$?
check "import: a round whose report.json will not parse is one warn line, skipped, exit 0" \
  '[ "$rc" = 0 ] && [ "$out" = "imported 1, skipped 1, tasks 1" ]'
check "import: and the warn line names the task and round it gave up on" \
  'grep -q "warn: ledger import: repo-imp-a round 2" "$T/corrupt.err"'
check "import: the round it could read still became its rows" \
  '[ "$(grep -c "\"kind\":\"round\"" "$T/corrupt/events.jsonl")" = 1 ]'
printf '[]\n' > "$S3/repo-imp-a/rounds/2/report.json"        # parses, but is no report
out=$( ( export DELEGATE_STATE=$S3 DELEGATE_LEDGER=$T/fatal/events.jsonl \
         DELEGATE_MODEL=soft-model DELEGATE_MODEL_HARD=hard-model
         "$here/bin/delegate" ledger import ) 2>$T/fatal.err ); rc=$?
check "import: a record shaped wrong enough to crash the walk is one warn line and exit 0" \
  '[ "$rc" = 0 ] && [ -z "$out" ] && grep -q "warn: ledger import" "$T/fatal.err"'
check "import: and it never prints a traceback" \
  '! grep -q Traceback "$T/fatal.err"'

# ================================================= T3: isolation (R2) ============
# The ledger outlives the records it was built from. Neither prune nor rm may reach it — at the
# default path (inside the state dir, beside the task dirs) or with a configured LEDGER there.
git init -q "$REPO_FIX" 2>/dev/null                      # `delegate rm` runs git in the task's repo
iso_run() { # STATE LEDGER ARGS...  (env, not export: a prefix, so the command really runs)
  local st=$1 led=$2; shift 2
  local -a ev=(DELEGATE_STATE="$st" DELEGATE_MODEL=soft-model DELEGATE_MODEL_HARD=hard-model)
  [ -n "$led" ] && ev+=(DELEGATE_LEDGER="$led")
  env "${ev[@]}" "$here/bin/delegate" "$@"
}
iso_mk() { local d=$1; rm -rf "$d"; mkdir -p "$d"
           cp -a "$ST/repo-imp-a" "$ST/repo-imp-b" "$d/"; }
for led in "" "$T/iso/telemetry.jsonl"; do                # the default path, and inside the state dir
  S1=$T/iso1 S2=$T/iso2
  [ -n "$led" ] && S1=$T/iso3 S2=$T/iso4
  iso_mk "$S1"; iso_run "$S1" "$led" ledger import >/dev/null
  file=${led:-$S1/ledger/events.jsonl}
  rows=$(grep -c '' "$file"); sum=$(sha256sum "$file")
  iso_run "$S1" "$led" prune --days 0 >"$T/prune.log" 2>&1
  check "R2: prune --days 0 removed the task records${led:+ it was pointed inside the state dir}" \
    '[ ! -d "$S1/repo-imp-a" ] && [ ! -d "$S1/repo-imp-b" ]'
  check "R2: and the ledger file it read survived prune, row for row and byte for byte" \
    '[ "$(grep -c "" "$file")" = "$rows" ] && [ "$(sha256sum "$file")" = "$sum" ]'
  iso_mk "$S2"; iso_run "$S2" "$led" ledger import >/dev/null
  file2=${led:-$S2/ledger/events.jsonl}
  rows2=$(grep -c '' "$file2"); sum2=$(sha256sum "$file2")
  iso_run "$S2" "$led" rm repo-imp-a >"$T/rm.log" 2>&1
  check "R2: delegate rm removed one task record${led:+ with the ledger living beside it}" \
    '[ ! -d "$S2/repo-imp-a" ] && [ -d "$S2/repo-imp-b" ]'
  check "R2: and the ledger survived it, every row still there" \
    '[ "$(grep -c "" "$file2")" = "$rows2" ] && [ "$(sha256sum "$file2")" = "$sum2" ]'
done

# ==================================================== T3: the docs ===============
# The commands a human is meant to run are documented where a human looks, and the module keeps
# saying what it does. Checked as text, not by reading prose aloud: the names, the flags, and the
# two things the docs must not let anyone forget (an import is once, and idempotent).
cat > $T/static.py <<'PY'
import os, re, sys

home = sys.argv[1]
def read(p): return open(os.path.join(home, p), encoding="utf-8").read()
def body(src, name):                      # a bash function's text, `name() {` to the `}` at col 0
    m = re.search(r"(?m)^" + re.escape(name) + r"\(\) \{.*?^\}", src, re.S)
    return m.group(0) if m else ""

ref, ex = read("docs/reference.md"), read("config.example.env")
bin_src, lib = read("bin/delegate"), read("lib/ledger.py")
usage, dispatch = body(bin_src, "usage"), body(bin_src, "cmd_ledger")
imp_doc = ref[ref.index("delegate ledger import"):]
cases = [
    ("delegate ledger review" in ref and "--verdict" in ref and "--bugs" in ref,
     "reference.md shows review with the flags it takes"),
    ("delegate ledger import" in ref and "source:\"import\"" in ref,
     "reference.md shows the import and the mark it leaves on the rows"),
    ("idempotent" in imp_doc and "skipped" in imp_doc and ("empty" in imp_doc or "null" in imp_doc),
     "reference.md says the import is idempotent and leaves what it cannot recover empty"),
    ("effort_source:\"inferred\"" in imp_doc,
     "reference.md says an imported effort is labelled as inferred"),
    ("delegate ledger import" in ex,
     "config.example.env points the owner at the one-time import"),
    ("delegate ledger review" in usage and "delegate ledger import" in usage,
     "usage() lists both new commands"),
    ("--verdict accepted|fixed|rejected" in usage,
     "usage() names the verdicts it takes"),
    ('review) ledger_review "$@"' in dispatch and 'import) ledger_import "$@"' in dispatch,
     "cmd_ledger dispatches review and import"),
    ("build_review_row" in lib and "import_state" in lib and "latest_round" in lib,
     "lib/ledger.py names its new entry points in its own docstring"),
    (not re.search(r"(?m)^import subprocess\b|\bos\.(system|popen)\b|\bsubprocess\.", lib),
     "R2/R8: lib/ledger.py shells out nowhere — no subprocess, no os.system, no popen"),
]
bad = [m for ok, m in cases if not ok]
for m in bad:
    print("MISMATCH " + m)
print(f"checked={len(cases)} bad={len(bad)}")
PY
u=$(pylib $T/static.py "$here" 2>&1)
printf '%s\n' "$u" | grep '^MISMATCH' || true
check "the docs, usage and module hold their side of the two commands (10 checks)" \
  'printf "%s\n" "$u" | grep -qE "^checked=10 bad=0$"'

echo
if [ "$fail" -eq 0 ]; then echo "PASS: test_ledger"; else echo "FAIL: test_ledger"; fi
exit $fail