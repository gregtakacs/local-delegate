#!/bin/bash
# t-3 (reliability events): the ONE merge (R8). `append_round_and_timeline` — the live round's
# door and, through `import_state`, the import's too — folds a round's three reliability
# sources into the timeline row's `events`: the event walk's tool errors (split into
# `tool-error:invalid-args` and `tool-error` by the marker text, one record per call, an error
# whose call later completes washing out — and a washout never disturbing another call's
# open error), the round's stderr.log nudge lines (new format at its position, old format at
# null — a position nobody recorded is never invented), and a `verify-fail` when the round's
# verify exit code is non-zero — `verify_rc`, never a status string. Events come out in step
# order (nulls first), kind/step/ctx only, never an error message (R4), and the import lands
# them byte-identical. No docker.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# ------------------------------------------------------------- the live-shaped round ----
# Four closed steps (ctx 100 / 30000 / 40000 / 40000). Failed calls, each with a story:
# call_c3 twice the same invalid-args (one event), call_d4 a generic failure (step 3),
# call_e5 erroring then completing (washout), call_f6 erroring near the tail (step 4).
# The round's status is a plain "failed" but its verify_rc is 2: the event follows the rc.
TD=$T/tasks/t-live; RD=$TD/rounds/1; mkdir -p "$RD"
cat > "$RD/events.jsonl" <<'FIX'
{"type":"step_start","timestamp":1000,"part":{"type":"step-start"}}
{"type":"step_finish","timestamp":1500,"part":{"type":"step-finish","tokens":{"input":90,"output":5,"reasoning":2,"cache":{"read":8,"write":2}},"reason":"tool-calls"}}
{"type":"tool_use","timestamp":2000,"part":{"type":"tool","tool":"edit","callID":"call_c3","id":"call_c3","state":{"status":"error","error":"The arguments provided to the tool are invalid: SECRET-ARGS-MARKER says hello","time":{"start":1900,"end":2000}}}}
{"type":"tool_use","timestamp":2100,"part":{"type":"tool","tool":"edit","callID":"call_c3","id":"call_c3","state":{"status":"error","error":"The arguments provided to the tool are invalid again SECRET-ARGS-MARKER"}}}
{"type":"step_finish","timestamp":3000,"part":{"type":"step-finish","tokens":{"input":200,"output":20,"reasoning":0,"cache":{"read":29800,"write":0}},"reason":"tool-calls"}}
{"type":"tool_use","timestamp":3500,"part":{"type":"tool","tool":"bash","callID":"call_d4","id":"call_d4","state":{"status":"error","error":"SECRET-GENERIC-FAILURE line one","time":{"start":3400,"end":3500}}}}
{"type":"tool_use","timestamp":3700,"part":{"type":"tool","tool":"bash","callID":"call_e5","id":"call_e5","state":{"status":"pending","input":"echo hush","time":{"start":3650}}}}
{"type":"step_finish","timestamp":4000,"part":{"type":"step-finish","tokens":{"input":10,"output":3,"reasoning":0,"cache":{"read":39990,"write":0}},"reason":"tool-calls"}}
{"type":"tool_use","timestamp":4400,"part":{"type":"tool","tool":"bash","callID":"call_e5","id":"call_e5","state":{"status":"error","error":"SECRET-WASHOUT-FAILURE then retried","time":{"start":3650,"end":4400}}}}
{"type":"tool_use","timestamp":4500,"part":{"type":"tool","tool":"bash","callID":"call_e5","id":"call_e5","state":{"status":"completed","input":"echo","output":"it worked","time":{"start":3650,"end":4500}}}}
{"type":"tool_use","timestamp":5000,"part":{"type":"tool","tool":"grep","callID":"call_f6","id":"call_f6","state":{"status":"error","error":"SECRET-TAIL-FAILURE on the tail step","time":{"start":4900,"end":5000}}}}
{"type":"step_finish","timestamp":6000,"part":{"type":"step-finish","tokens":{"input":10,"output":1,"reasoning":0,"cache":{"read":39990,"write":0}},"reason":"end-turn"}}
FIX
printf 'worker noise before\nnudge: malformed step=2 ctx=30000\nnudge:\nsome grep: nudge: not-this\nnudge: no-status\nafter\n' > "$RD/stderr.log"
cat > "$RD/report.json" <<'FIX'
{"id":"t-live","round":1,"status":"failed","verify_rc":2,"model":"m1","steps":4,
 "final_context_tokens":40000,"nudges":{"malformed":1,"no-status":1},
 "started_at":"2026-11-16T10:00:00Z","finished_at":"2026-11-16T10:09:00Z"}
FIX
printf 'REPO=t\nSLUG=t-live\n' > "$TD/meta.env"

# ------------------------------------------------------------------ run the merge -----
python3 - "$here" "$RD" "$T/live.jsonl" <<'PY' > "$T/run.txt" 2>&1
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1] + "/lib/ledger.py")
ledger = importlib.util.module_from_spec(spec); spec.loader.exec_module(ledger)
rd, out = sys.argv[2], sys.argv[3]
n = ledger.append_round_and_timeline(out, rd + "/report.json", rd + "/events.jsonl",
                                     {"task_id": "t-live", "run_id": "t-live", "round": 1})
rows = [json.loads(l) for l in open(out)]
print("rows=%d kind=%s" % (n, rows[1]["kind"]))
print("events=" + json.dumps(rows[1]["events"]))
print("ctxs=" + json.dumps([s["ctx"] for s in rows[1]["steps"]]))
PY
check "the live-shaped append wrote a round row then a timeline row" \
  'grep -q "^rows=2 kind=timeline$" "$T/run.txt"'
want='events=[{"kind": "nudge:no-status", "step": null, "ctx": null}, {"kind": "tool-error:invalid-args", "step": 2, "ctx": 30000}, {"kind": "nudge:malformed", "step": 2, "ctx": 30000}, {"kind": "tool-error", "step": 3, "ctx": 40000}, {"kind": "tool-error", "step": 4, "ctx": 40000}, {"kind": "verify-fail", "step": 4, "ctx": 40000}]'
check "exact merged events: one invalid-args, no washout survivor, old-format nudge at null/unknown, verify-fail from verify_rc=2 though status says only failed, nulls first" \
  "grep -qF '$want' \"\$T/run.txt\""
check "every step carries its own ctx, cache included" \
  'grep -q "^ctxs=\[100, 30000, 40000, 40000\]$" "$T/run.txt"'
check "R4: no error text, planted marker, call id or stderr noise reached the ledger file" \
  '! grep -qE "SECRET-ARGS-MARKER|SECRET-GENERIC-FAILURE|SECRET-WASHOUT-FAILURE|SECRET-TAIL-FAILURE|hush|it worked|call_c3|call_d4|call_e5|call_f6|not-this" "$T/live.jsonl"'

# ------------------------------------------------------- the same round, re-imported ----
# R8: import_state walks state dirs and reaches the merge through this very function, so the
# timeline row it lands must equal the live one field for field, source and ts aside.
SD=$T/state; mkdir -p "$SD/t-live/rounds"; mv "$RD" "$SD/t-live/rounds/1"; mv "$TD/meta.env" "$SD/t-live/meta.env"
python3 - "$here" "$SD" "$T" <<'PY' > "$T/imp.txt" 2>&1
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1] + "/lib/ledger.py")
ledger = importlib.util.module_from_spec(spec); spec.loader.exec_module(ledger)
res = ledger.import_state(sys.argv[3] + "/imported.jsonl", sys.argv[2])
live = [json.loads(l) for l in open(sys.argv[3] + "/live.jsonl")][1]
imp = [json.loads(l) for l in open(sys.argv[3] + "/imported.jsonl")][1]
same = all(imp[k] == live[k] for k in live if k not in ("ts", "source"))
print("imported=%d same=%s" % (res["imported"], same))
PY
check "R8: importing the round writes the same events (verify_rc-triggered verify-fail included) and step ctx the live path wrote, source imported" \
  'grep -q "^imported=1 same=True$" "$T/imp.txt" \
   && grep -q "\"source\":\"import\"" "$T/imported.jsonl"'

# ---------------------------------------------------- an errored call that washes out ----
# Two calls error in the same step, then A completes: A's record goes. B is then seen in
# error again: it must update its OWN record, not one shifted by A's removal — the washout
# never disturbs another open error. One event remains, closed by the step that ends over it.
AB=$T/ab.jsonl
cat > "$AB" <<'FIX'
{"type":"step_start","timestamp":100,"part":{"type":"step-start"}}
{"type":"tool_use","timestamp":110,"part":{"type":"tool","tool":"bash","id":"A","state":{"status":"error","error":"SECRET-A","time":{"start":105,"end":110}}}}
{"type":"tool_use","timestamp":112,"part":{"type":"tool","tool":"bash","id":"B","state":{"status":"error","error":"SECRET-B","time":{"start":108,"end":112}}}}
{"type":"tool_use","timestamp":118,"part":{"type":"tool","tool":"bash","id":"A","state":{"status":"completed","time":{"start":105,"end":118}}}}
{"type":"tool_use","timestamp":119,"part":{"type":"tool","tool":"bash","id":"B","state":{"status":"error","error":"SECRET-B again","time":{"start":108,"end":119}}}}
{"type":"step_finish","timestamp":120,"part":{"type":"step-finish","tokens":{"input":400,"output":100,"reasoning":0,"cache":{"read":0,"write":0}},"reason":"tool-calls"}}
FIX
check "A washes out, B re-errores: B's single record stands at its place, no shifted index" \
  'python3 - "$here" "'"$AB"'" <<PY
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1] + "/lib/ledger.py")
ledger = importlib.util.module_from_spec(spec); spec.loader.exec_module(ledger)
d = ledger.derive_timeline(sys.argv[2])   # the old index arithmetic raised or misplaced here
sys.exit(0 if d["events"] == [{"kind": "tool-error", "step": 1, "ctx": 400}] else 1)
PY
'
# and when B completes too after A was already dropped, both wash out.
cat > "$AB" <<'FIX'
{"type":"step_start","timestamp":100,"part":{"type":"step-start"}}
{"type":"tool_use","timestamp":110,"part":{"type":"tool","tool":"bash","id":"A","state":{"status":"error","error":"SECRET-A","time":{"start":105,"end":110}}}}
{"type":"tool_use","timestamp":112,"part":{"type":"tool","tool":"bash","id":"B","state":{"status":"error","error":"SECRET-B","time":{"start":108,"end":112}}}}
{"type":"tool_use","timestamp":118,"part":{"type":"tool","tool":"bash","id":"A","state":{"status":"completed","time":{"start":105,"end":118}}}}
{"type":"tool_use","timestamp":119,"part":{"type":"tool","tool":"bash","id":"B","state":{"status":"completed","time":{"start":108,"end":119}}}}
{"type":"step_finish","timestamp":120,"part":{"type":"step-finish","tokens":{"input":400,"output":100,"reasoning":0,"cache":{"read":0,"write":0}},"reason":"tool-calls"}}
FIX
check "B completing after A was dropped washes both away: no events" \
  'python3 - "$here" "'"$AB"'" <<PY
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1] + "/lib/ledger.py")
ledger = importlib.util.module_from_spec(spec); spec.loader.exec_module(ledger)
sys.exit(0 if ledger.derive_timeline(sys.argv[2])["events"] == [] else 1)
PY
'

# ------------------------------------------------ the verify_rc matrix, live and import --
# verify-fail follows the exit code: 1 writes the event through the live door, 0 and a
# missing verify_rc write none; importing the rc=1 round gives the live path's exact row.
mkround() { mkdir -p "$2"; printf 'nudge: stalled\n' > "$2/stderr.log"; printf '%s\n' \
  '{"type":"step_start","timestamp":100,"part":{"type":"step-start"}}' \
  '{"type":"step_finish","timestamp":120,"part":{"type":"step-finish","tokens":{"input":100,"output":20,"reasoning":0,"cache":{"read":0,"write":0}},"reason":"end-turn"}}' \
  > "$2/events.jsonl"; }
for rc in one zero none; do
  mkround x "$T/rc-$rc"
  case $rc in one)  extra='"verify_rc": 1,';; zero) extra='"verify_rc": 0,';; none) extra='';; esac
  printf '{"id":"t-rc-%s","round":1,"status":"done",%s"model":"m1","steps":1,"final_context_tokens":100}' \
    "$rc" "$extra" > "$T/rc-$rc/report.json"
done
python3 - "$here" "$T" <<'PY' > "$T/rc.txt" 2>&1
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1] + "/lib/ledger.py")
ledger = importlib.util.module_from_spec(spec); spec.loader.exec_module(ledger)
for rc in ("one", "zero", "none"):
    rd = sys.argv[2] + "/rc-" + rc
    out = rd + "/live.jsonl"
    ledger.append_round_and_timeline(out, rd + "/report.json", rd + "/events.jsonl",
                                     {"task_id": "t-rc-" + rc, "run_id": "t-rc-" + rc, "round": 1})
    tl = [json.loads(l) for l in open(out)][1]
    print(rc, json.dumps(tl["events"]))
PY
check "verify_rc=1 writes the verify-fail at the round's final position, status notwithstanding" \
  'grep -qF "one [{\"kind\": \"nudge:stalled\", \"step\": null, \"ctx\": null}, {\"kind\": \"verify-fail\", \"step\": 1, \"ctx\": 100}]" "$T/rc.txt"'
check "verify_rc=0 writes no verify-fail event" \
  'grep -qF "zero [{\"kind\": \"nudge:stalled\", \"step\": null, \"ctx\": null}]" "$T/rc.txt"'
check "a round with no verify_rc recorded writes no verify-fail event" \
  'grep -qF "none [{\"kind\": \"nudge:stalled\", \"step\": null, \"ctx\": null}]" "$T/rc.txt"'
mkdir -p "$T/istate/t-rc-one/rounds/1" && cp -r "$T/rc-one/." "$T/istate/t-rc-one/rounds/1/" \
  && rm "$T/istate/t-rc-one/rounds/1/live.jsonl"
printf 'REPO=t\nSLUG=t-rc-one\n' > "$T/istate/t-rc-one/meta.env"
check "R8 again: importing the verify_rc=1 round gives the live path's exact events and steps" \
  'python3 - "$here" "$T" <<PY
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1] + "/lib/ledger.py")
ledger = importlib.util.module_from_spec(spec); spec.loader.exec_module(ledger)
ledger.import_state(sys.argv[2] + "/imp-rc.jsonl", sys.argv[2] + "/istate")
live = [json.loads(l) for l in open(sys.argv[2] + "/rc-one/live.jsonl")][1]
imp = [r for r in (json.loads(l) for l in open(sys.argv[2] + "/imp-rc.jsonl")) if r.get("kind") == "timeline"]
sys.exit(0 if len(imp) == 1 and imp[0]["events"] == live["events"] and imp[0]["steps"] == live["steps"] else 1)
PY
'

# --------------------------------------------- an events file with no closed steps ------
# A killed-early round: the walk saw no step_finish. Its old-format nudge still records at
# null (report.json's steps and final context do NOT lend it a position), while its
# verify-fail — a property of the finished round, keyed off verify_rc — does take that
# fallback pair, nulls sorting before it. The row still goes out, unclosed step and all.
RD2=$T/state/t-dead/rounds/1; mkdir -p "$RD2"
printf 'REPO=t\nSLUG=t-dead\n' > "$T/state/t-dead/meta.env"
printf 'text only, no steps\nnudge: malformed\n' > "$RD2/stderr.log"
cat > "$RD2/events.jsonl" <<'FIX'
{"type":"text","timestamp":500,"part":{"type":"text","text":"STATUS: partial"}}
{"type":"step_start","timestamp":700,"part":{"type":"step-start"}}
FIX
printf '{"id":"t-dead","round":1,"status":"failed","verify_rc":3,"model":"m1","steps":7,"final_context_tokens":12345}\n' > "$RD2/report.json"
python3 - "$here" "$T" <<'PY' > "$T/fb.txt" 2>&1
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1] + "/lib/ledger.py")
ledger = importlib.util.module_from_spec(spec); spec.loader.exec_module(ledger)
out = sys.argv[2] + "/fb.jsonl"
ledger.import_state(out, sys.argv[2] + "/state")
rows = [r for r in (json.loads(l) for l in open(out)) if r["kind"] == "timeline" and r["task_id"] == "t-dead"]
rows = rows[-1]
print("events=" + json.dumps(rows["events"]))
print("ctx=" + json.dumps(rows["steps"][-1]["ctx"]))
PY
check "no closed step: the old-format nudge records at null even though report.json knows a final position" \
  'grep -qF "events=[{\"kind\": \"nudge:malformed\", \"step\": null, \"ctx\": null}" "$T/fb.txt"'
check "the killed round's verify-fail takes report.json's step count and final context, sorted after the null" \
  'grep -qF "{\"kind\": \"verify-fail\", \"step\": 7, \"ctx\": 12345}]" "$T/fb.txt"'
check "the unclosed step itself carries a null ctx (the unknown bucket)" \
  'grep -q "^ctx=null$" "$T/fb.txt"'

echo
if [ "$fail" -eq 0 ]; then echo "PASS: test_reliability"; else echo "FAIL: test_reliability"; fi
exit $fail
