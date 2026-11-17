#!/bin/bash
# t-3 (position): `python3 lib/report.py position EVENTS` answers `<N> <T>` — the count of
# step_finish parts seen and the context size of the last closed step (input + cache.read +
# cache.write) — the line `delegate run` echoes into stderr.log when it nudges the worker.
# A file with no steps, no file at all, or garbage is "0 0", never a traceback: a nudge must
# still be written when the position is unknown. The nudge-line grammar lives in lib/ledger.py
# (NUDGE_LINE): the new format parses to (kind, N, T); the old format — no pair — parses to
# (kind, None, None) and stays a nudge of that kind; a `nudge:` line with half a pair is not
# a nudge at all. And bin/delegate echoes exactly that shape. No model, no docker.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
pos() { python3 "$here/lib/report.py" position "$1" 2>"$T/err"; }

check "position of a file that does not exist is 0 0" \
  'test "$(pos "$T/never.jsonl")" = "0 0"'
: > "$T/empty.jsonl"
check "an empty event file is 0 0" \
  'test "$(pos "$T/empty.jsonl")" = "0 0"'

# three closed steps; ctx = input + cache.read + cache.write, last step wins
cat > "$T/events.jsonl" <<'FIX'
{"type":"step_start","timestamp":100,"part":{"type":"step-start"}}
{"type":"text","timestamp":200,"part":{"type":"text","text":"STATUS: done"}}
{"type":"step_finish","timestamp":300,"part":{"type":"step-finish","tokens":{"input":100,"output":5,"reasoning":1,"cache":{"read":7,"write":3}},"reason":"tool-calls"}}
{"type":"tool_use","timestamp":400,"part":{"type":"tool","tool":"bash","callID":"c1","state":{"status":"completed","output":"fine"}}}
not-json line, skipped like any reader here skips it
{"type":"step_finish","timestamp":500,"part":{"type":"step-finish","tokens":{"input":1,"output":2,"reasoning":0,"cache":{"read":39,"write":0}},"reason":"tool-calls"}}
{"type":"step_finish","timestamp":600,"part":{"type":"step-finish","tokens":{"input":10,"output":1},"reason":"end-turn"}}
{"type":"step_finish","timestamp":700,"part":"not even an object"}
FIX
check "the step count is every step_finish seen, the ctx the last one's whole context (no cache: 10)" \
  'test "$(pos "$T/events.jsonl")" = "3 10"'
check "the count is every step_finish, and a finish with no cache tokens still counts as a step" \
  'test "$(pos "$T/events.jsonl" | cut -d" " -f1)" = "3"'
check "reading the position wrote nothing to stderr" \
  'test "$(grep -c "" "$T/err")" = 0'

# the grammar, straight off the echo shape bin/delegate writes
python3 - "$here" "$T" <<'PY'
import importlib.util, sys
here, T = sys.argv[1], sys.argv[2]
open(T + "/echo.txt", "w").write(
    "nudge: malformed step=2 ctx=100\nsome other harness noise\n"
    "nudge: api-error\nnudge: no-status step=7 ctx=12345\n"
    "nudge: half step=3\nnudge:\nnudge: weird thing extra\n")
PY
check "parse_nudge_lines reads new and old formats alike, and rejects half a pair and noise" \
  'python3 - "$here" "$T" <<PY
import importlib.util, sys
here, T = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("ledger", here + "/lib/ledger.py")
ledger = importlib.util.module_from_spec(spec); spec.loader.exec_module(ledger)
got = ledger.parse_nudge_lines(open(T + "/echo.txt").read())
want = [("nudge:malformed", 2, 100), ("nudge:api-error", None, None),
        ("nudge:no-status", 7, 12345)]
kinds = [k for k, n, t in ledger.parse_nudge_lines("nudge: malformed\nnudge: malformed step=1 ctx=2\n")]
sys.exit(0 if got == want and kinds == ["nudge:malformed", "nudge:malformed"] else 1)
PY
'
check "timeline_events carries a positioned nudge verbatim, and an unpositioned one at null/unknown" \
  'python3 - "$here" <<PY
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1] + "/lib/ledger.py")
ledger = importlib.util.module_from_spec(spec); spec.loader.exec_module(ledger)
a = ledger.timeline_events(None, "nudge: api-error step=1 ctx=2") == [
        {"kind": "nudge:api-error", "step": 1, "ctx": 2}]
lb = ledger.timeline_events(None, "nudge: api-error")
b = lb == [{"kind": "nudge:api-error", "step": None, "ctx": None}]
c = ledger.timeline_events(None, "nudge: api-error", fallback=(3, 12345)) == [
        {"kind": "nudge:api-error", "step": None, "ctx": None}]
d = ledger.ctx_bucket(lb[0]["ctx"]) == "unknown"
sys.exit(0 if a and b and c and d else 1)
PY
'

# the echo itself: exactly `nudge: <kind> step=<N> ctx=<T>` into the round's stderr.log,
# its position taken from report.py position, an unparseable answer degrading to 0 0
check "bin/delegate echoes the nudge with its step and ctx, positioned by report.py" \
  'grep -qF "echo \"nudge: \$kind step=\${pos% *} ctx=\${pos#* }\" >> \"\$rd/stderr.log\"" "$here/bin/delegate"'
check "the position comes from report.py position on this round's events, defaulting to 0 0" \
  'grep -qF "report.py\" position \"\$rd/events.jsonl\"" "$here/bin/delegate" \
   && grep -qF "|| echo \"0 0\"" "$here/bin/delegate"'

# an echoed line lands in ledger-side parsing exactly as written: the full round echo shape
printf 'nudge: no-status step=3 ctx=10\n' > "$T/round-stderr.log"
check "an echoed line parses back to the kind and position it carries" \
  'python3 - "$here" "$T/round-stderr.log" <<PY
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1] + "/lib/ledger.py")
ledger = importlib.util.module_from_spec(spec); spec.loader.exec_module(ledger)
sys.exit(0 if ledger.parse_nudge_lines(open(sys.argv[2]).read()) == [
    ("nudge:no-status", 3, 10)] else 1)
PY
'

echo
if [ "$fail" -eq 0 ]; then echo "PASS: test_position"; else echo "FAIL: test_position"; fi
exit $fail
