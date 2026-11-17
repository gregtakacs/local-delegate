#!/bin/bash
# T4: `delegate stats` — R6's per-project totals, read off the ledger's `round` and `review`
# rows. Fixture rows are seeded through `delegate ledger append` / `delegate ledger review` into
# a ledger under mktemp -d, and every figure stats prints is checked against those same rows by
# hand: rounds, the ok% rate and the source it labelled, retries as `sum(max(round)-1)`, the
# cache mean, wall time and its mean, the findings and failures tables, the import label,
# --since, the two filters, and --json — plus the t-3 reliability figures: the timeline rows
# join their groups by (task_id, round), and rates come out per 100 model requests and per
# context bucket. Stats is a reader: it writes nothing, and it reads no reliability payload
# beyond kinds, counts and positions. No docker, no model, no network, no repository.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DELEGATE_CONFIG=$T/none.env
export DELEGATE_STATE=$T/state                 # a private state dir: stats must not touch it
export DELEGATE_LEDGER=$T/led/events.jsonl
L=$DELEGATE_LEDGER
mkdir -p "$T/led" "$DELEGATE_STATE"
printf 'sentinel\n' > "$DELEGATE_STATE/sentinel"
lg()    { "$here/bin/delegate" ledger "$@"; }
stats() { "$here/bin/delegate" stats "$@"; }
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
st()  { OUT="$OUT" python3 -c 'import json,os,sys
d = json.loads(os.environ["OUT"])
print(eval("d" + sys.argv[1], {"d": d, "json": json}))' "$1"; }
grpf(){ OUT="$OUT" python3 -c 'import json,os,sys
want = sys.argv[1]
for g in json.loads(os.environ["OUT"])["groups"]:
    if (g["repo"] or "-") + "/" + (g["chain"] or "-") == want:
        print(eval("g" + sys.argv[2], {"g": g}))
        break
else:
    sys.exit("no group " + want)' "$1" "$2"; }

# ------------------------------------------------------------------ the fixtures -------
# Four groups over R6's four axes, all dated 2026-11-10 except one from 2020 (that is what
# --since is for):
#   acme/widgets/t-1     m1  hard    5 rounds + 4 review rows   (the exact-number group)
#   acme/widgets/t-2     m2  normal  2 rounds, no review rows   (ok% must come from statuses)
#   old/project/t-9      m1  normal  1 round, source:"import"   (labelled; statuses for ok%)
#   acme/old/t-0         m1  hard    1 round, ts 2020-06-01     (--since drops it)
# Plus one review row for a task with no round rows at all (t-ghost): it counts as read and
# belongs to no group. `rnd` writes one round row; FIELDS is the rest of the row, comma-joined.
TS=2026-11-10T00:00:00Z
rnd() { # TASK REPO CHAIN MODEL EFFORT STATUS TS FIELDS
  lg append --kind round --task "$1" --fields "repo=$2,chain=$3,model=$4,effort=$5,status=$6,ts=$7,$8"
}
A=acme/widgets; B=acme/widgets; C=old/project; O=acme/old
rnd t-a1 $A t-1 m1 hard worker-error            $TS 'round=1,duration_s=100,input_tokens=100,output_tokens=10,reasoning_tokens=1,cache_read=300,cache_write=0,tool_errors=0,errors=0'
rnd t-a1 $A t-1 m1 hard done                    $TS 'round=2,duration_s=200,input_tokens=300,output_tokens=20,reasoning_tokens=2,cache_read=100,cache_write=0,tool_errors=2,errors=1'
rnd t-a1 $A t-1 m1 hard done                    $TS 'round=3,duration_s=300,input_tokens=200,output_tokens=30,reasoning_tokens=3,cache_read=200,cache_write=0,tool_errors=1,errors=0'
rnd t-a1 $A t-1 m1 hard done-but-verify-failed  $TS 'round=5,duration_s=400,input_tokens=400,output_tokens=40,reasoning_tokens=4,cache_read=400,cache_write=0,tool_errors=0,errors=0,verify_rc=1'
rnd t-a2 $A t-1 m1 hard timeout                 $TS 'round=1,duration_s=50,input_tokens=50,output_tokens=5,reasoning_tokens=0,cache_read=150,cache_write=0,tool_errors=3,errors=2'
rnd t-b1 $B t-2 m2 normal done                  $TS 'round=1,duration_s=60,input_tokens=500,output_tokens=50,reasoning_tokens=5,cache_read=500,cache_write=0,tool_errors=0,errors=0'
rnd t-b1 $B t-2 m2 normal partial               $TS 'round=2,duration_s=120,input_tokens=500,output_tokens=50,reasoning_tokens=5,cache_read=500,cache_write=0,tool_errors=0,errors=0'
rnd t-c1 $C t-9 m1 normal done                  $TS 'round=1,duration_s=1000,input_tokens=0,output_tokens=0,reasoning_tokens=0,cache_read=0,cache_write=0,tool_errors=0,errors=0,source=import'
rnd t-old $O t-0 m1 hard done                   '2020-06-01T00:00:00Z' 'round=1,duration_s=10,input_tokens=10,output_tokens=1,reasoning_tokens=0,cache_read=0,cache_write=0,tool_errors=0,errors=0'
lg review t-a1 --verdict accepted --round 1 --lines-changed 0                       >/dev/null
lg review t-a1 --verdict fixed    --round 3 --bugs high=1,medium=1 --lines-changed 40 --note 'NOTE-SECRET-MARKER' >/dev/null
lg review t-a1 --verdict fixed    --round 5 --bugs high=2,low=1 --lines-changed 15  >/dev/null
lg review t-a1 --verdict rejected --round 5 --bugs low=2                            >/dev/null
lg review t-ghost --verdict accepted --round 1                                      >/dev/null

# A timeline row (schema 1: no positions, its step can only count as an unpositioned
# request) and a slice-B `benchmark` row, both written by hand because the CLI would rather
# die than invent one. The benchmark row is dropped at the line level, unread; the timeline
# row is read and joins the group of its (task_id, round). Neither note may ever reach an
# output line (R4). A v2 row with positions and events follows below.
printf '%s\n' '{"kind":"timeline","schema":1,"task_id":"t-a1","run_id":"t-a1","round":3,"steps":[{"start":1,"end":2,"input":7,"output":7,"reasoning":0,"cache_read":0,"cache_write":0,"reason":"tool-calls"}],"tools":[{"tool":"bash","status":"completed","start":1,"end":2}],"source":"","ts":"2026-11-10T00:00:00Z","note":"TIMELINE-SECRET-MARKER"}' >> "$L"
printf '%s\n' '{"kind":"benchmark","schema":1,"task_id":"bench-1","ts":"2026-11-10T00:00:00Z","note":"BENCHMARK-SECRET-MARKER"}' >> "$L"
printf '%s\n' '{"schema":2,"kind":"timeline","task_id":"t-a1","run_id":"t-a1","round":2,"steps":[{"start":1000,"end":5000,"input":200,"output":20,"reasoning":3,"cache_read":39800,"cache_write":0,"reason":"tool-calls","ctx":40000},{"start":6000,"end":9500,"input":100,"output":10,"reasoning":0,"cache_read":0,"cache_write":300100,"reason":"end-turn","ctx":300200}],"tools":{"bash":2,"edit":1,"read":3},"events":[{"kind":"nudge:malformed","step":1,"ctx":40000},{"kind":"tool-error:invalid-args","step":2,"ctx":300200},{"kind":"verify-fail","step":2,"ctx":300200}],"source":"live","ts":"2026-11-10T00:10:00Z"}' >> "$L"
# Four lines this build cannot use at all — malformed, an unknown kind, a schema from the
# future, and JSON that is no object — which stats counts on exactly one warning line.
printf '%s\n' 'not json at all, and stats counts it rather than choking on it' >> "$L"
printf '%s\n' '{"kind":"teleport","schema":1,"task_id":"t-a1"}' >> "$L"
printf '%s\n' '{"kind":"round","schema":99,"task_id":"t-a1","ts":"2026-11-10T00:00:00Z"}' >> "$L"
printf '%s\n' '[1,2,3]' >> "$L"
CKSUM=$(cksum < "$L")
check "the fixture ledger holds 9 round, 5 review, 2 timeline, 1 foreign and 4 junk lines" \
  'test "$(grep -c "" "$L")" = 21'

# ------------------------------------------------------------------ the text run -------
# One table per concern, all three over the same rows: the per-project groups, the review
# findings, the failures. `block` cuts one table out of stdout by its header line.
block() { printf '%s\n' "$2" | awk -v t="$1" 'index($0,t)==1{f=1;next} f&&!NF{exit} f'; }
OUT=$(stats 2>"$T/err.txt"); rc=$?
check "stats over a populated ledger exits 0" '[ "$rc" = 0 ]'
GRP=$(block "delegate stats" "$OUT")
FND=$(block "findings (review rows)" "$OUT")
FAI=$(block "failures (round rows)" "$OUT")
check "the group table carries R6's column names, in the spec's order" \
  'printf "%s\n" "$GRP" | head -1 | grep -q "repo/chain.*model.*effort.*rounds.*ok%.*wall.*tok(in/out/r).*cache%.*retries"'
check "one group line per repo/chain/model/effort combination, four of them" \
  'test "$(printf "%s" "$GRP" | grep -c "")" = 5'
check "the partly reviewed group: 5 rounds, ok 0% per task (t-a1 latest review rejected, t-a2 unreviewed timeout), mixed, wall 17m30s avg 3m30s" \
  'printf "%s\n" "$GRP" | grep "^acme/widgets/t-1 " | grep -q " 5 " && printf "%s\n" "$GRP" | grep "^acme/widgets/t-1 " | grep -qE " 0% mixed" && printf "%s\n" "$GRP" | grep "^acme/widgets/t-1 " | grep -q "17m30s avg 3m30s"'
check "the same line: tokens 1050/105/10, cache mean 55%, retries 4 (max round 5 minus 1, and 0)" \
  'printf "%s\n" "$GRP" | grep "^acme/widgets/t-1 " | grep -q "1050/105/10" && printf "%s\n" "$GRP" | grep "^acme/widgets/t-1 " | grep -qE " 55% +4 "'
check "a group with no review rows labels ok% from statuses: its one task ended partial, 0%" \
  'printf "%s\n" "$GRP" | grep "^acme/widgets/t-2 " | grep -qE " 0% status"'
check "that same group: 2 rounds, retries 1 (max round 2 minus 1), cache 50%" \
  'printf "%s\n" "$GRP" | grep "^acme/widgets/t-2 " | grep -qE " 2 +0% status " && printf "%s\n" "$GRP" | grep "^acme/widgets/t-2 " | grep -q "3m00s avg 1m30s" && printf "%s\n" "$GRP" | grep "^acme/widgets/t-2 " | grep -qE "50% +1 "'
check "the import-sourced group is labelled source:\"import\", and its ok% comes from statuses" \
  'printf "%s\n" "$GRP" | grep "^old/project/t-9 " | grep -q "100% status" && printf "%s\n" "$GRP" | grep "^old/project/t-9 " | grep -q "import"'
check "the 2020 group reads like any other group when no filter is given" \
  'printf "%s\n" "$GRP" | grep -q "^acme/old/t-0 "'
check "findings table: reviewed group has 4 rows, 1 accepted, 2 fixed, 1 rejected, bugs 3/1/3, 55 lines" \
  'printf "%s\n" "$FND" | grep "^acme/widgets/t-1 " | grep -qE " 4 +1 +2 +1 +3/1/3 +55"'
check "findings table: a group with no review rows reads as a zero row, never as a missing row" \
  'printf "%s\n" "$FND" | grep "^acme/widgets/t-2 " | grep -qE " 0 +0 +0 +0 +0/0/0 +0"'
check "failures table: tool errors, errors, and the four statuses R6 names, at their zeroes" \
  'printf "%s\n" "$FAI" | grep "^acme/widgets/t-1 " | grep -qE " 6 +3 " && printf "%s\n" "$FAI" | grep "^acme/widgets/t-1 " | grep -q "worker-error=1 timeout=1 truncated=0 done-but-verify-failed=1"'
check "failures table: the no-failure group says so in figures, not in prose" \
  'printf "%s\n" "$FAI" | grep "^acme/old/t-0 " | grep -qE " 0 +0 " && printf "%s\n" "$FAI" | grep "^acme/old/t-0 " | grep -q "worker-error=0 timeout=0 truncated=0 done-but-verify-failed=0"'
check "failures table: a group whose timeline holds a verify-fail event surfaces it in figures" \
  'printf "%s\n" "$FAI" | grep "^acme/widgets/t-1 " | grep -q "verify-fail=1"'

# t-3: the reliability table. t-1's two timeline rows carry 3 model requests (the v1 row's
# one unpositioned step, the v2 row's two positioned steps) and three events: one nudge and
# one invalid-args tool-error rate each per 100 requests, verify-fail not as a rate but as
# 1 fail per 5 rounds. Every other group has rounds and no timeline row: dash, not zero.
REL=$(block "reliability (per 100 model requests)" "$OUT")
check "the reliability table names its unit in its header, per 100 model requests" \
  'printf "%s\n" "$REL" | head -1 | grep -q "repo/chain.*model.*effort.*requests.*nudge:malformed.*tool-error:invalid-args.*verify-fail/100rds"'
check "verify-fail gets no per-request column: its only home is the /100-rounds column" \
  '! printf "%s\n" "$REL" | head -1 | grep -qE "requests.*verify-fail.*nudge"'
check "the joined group: 3 requests, nudge:malformed and tool-error:invalid-args at 33.33, verify at 20 per 100 rounds" \
  'printf "%s\n" "$REL" | grep "^acme/widgets/t-1 " | grep -qE " +3 +33\.33 +33\.33 +20( |\$)"'
check "a group with rounds but no timeline row: 0 requests, dash rates, and a true 0 verify per 100 rounds" \
  'printf "%s\n" "$REL" | grep "^acme/widgets/t-2 " | grep -qE " +0 +- +- +0( |\$)"'
check "the (total) line: 3 requests, the same two rates, verify 1 of 9 rounds at 11.11" \
  'printf "%s\n" "$REL" | grep "^(total)" | grep -qE " +3 +33\.33 +33\.33 +11\.11( |\$)"'
check "R4 again: the reliability table spells no task id, no note, no step or event text" \
  '! printf "%s\n%s" "$REL" "$(cat "$T/err.txt")" | grep -qE "t-a1|TIMELINE-SECRET-MARKER|call_"'
check "the total line sums the groups: 9 rounds, 5 retries, wall 37m20s, tokens 2060/206/20" \
  'printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "rounds 9" && printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "retries 5" && printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "37m20s" && printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "2060/206/20"'
check "the total names the ok% source it used, and counts the import rows separately" \
  'printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "40% (mixed)" && printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "import 1"'
check "one warning line for the four unusable lines, counted and no more" \
  'grep -q "^delegate: warn: ledger stats: skipped 4 line(s) (malformed or unknown kind)$" "$T/err.txt"'
check "and it is the only thing on stderr: known kinds are filtered, not mourned" \
  'test "$(grep -c "" "$T/err.txt")" = 1'
check "R4: no output line carries tool, timeline or note text, and none invents a cost" \
  '! printf "%s\n%s" "$OUT" "$(cat "$T/err.txt")" | grep -qE "TIMELINE-SECRET-MARKER|NOTE-SECRET-MARKER|BENCHMARK-SECRET-MARKER|tool-calls|teleport"'
check "R6: no prices and no dollar amounts anywhere in the output" \
  '! printf "%s\n" "$OUT" | grep -qE "\\\$|USD|price|cost|\\u00a3"'

# ------------------------------------------------------------------ filters -------
# --since compares the row's own ts, date-first; --chain and --repo match the row's axis
# fields exactly; the three combine. A filter that keeps nothing is a zero, not an error.

OUT=$(stats --since 2026-11-01 2>"$T/err.txt"); rc=$?
check "--since exits 0 and keeps counting what it could not read" \
  '[ "$rc" = 0 ] && grep -q "^delegate: warn: ledger stats: skipped 4 line(s)" "$T/err.txt"'
check "--since drops the 2020 group from the table entirely" \
  '! printf "%s\n" "$OUT" | grep -qE "^acme/old/t-0 "'
check "--since: the header and the total agree on what is left: 3 of 8, 37m10s" \
  'printf "%s\n" "$OUT" | grep -q "3 of 8 round rows" && printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "rounds 8" && printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "37m10s"'
check "--since: the import count survives with its group, at 1" \
  'printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "import 1"'
check "--since keeps reliability with its rounds: 3 requests, and verify 1 of the surviving 8 rounds at 12.5" \
  'printf "%s\n" "$OUT" | grep "^(total)" | grep -qE " +3 +33\.33 +33\.33 +12\.5( |\$)"'

OUT=$(stats --since 2020-01-01 2>/dev/null)
check "--since on or before every row reads the whole ledger: 9 rounds again" \
  'printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "rounds 9" && printf "%s\n" "$OUT" | grep -q "^acme/old/t-0 "'

OUT=$(stats --since 2030-01-01 2>/dev/null); rc=$?
check "a date nobody has reached is an honest zero, not an error" \
  '[ "$rc" = 0 ] && printf "%s\n" "$OUT" | grep -q "0 of 0 round rows" && printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "rounds 0"'

OUT=$(stats --chain t-2 2>/dev/null); rc=$?
check "--chain keeps exactly t-2's line and nothing else's rounds" \
  '[ "$rc" = 0 ] && printf "%s\n" "$OUT" | grep -q "^acme/widgets/t-2 " && ! printf "%s\n" "$OUT" | grep -qE "^acme/widgets/t-1 |^old/project/t-9 |^acme/old/t-0 "'
check "--chain's total counts only the surviving rounds: 2, all from one group" \
  'printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "rounds 2" && printf "%s\n" "$OUT" | grep -q "1 of 2 round rows"'

OUT=$(stats --repo acme/widgets 2>/dev/null)
check "--repo keeps both widgets chains and nothing from the other repos: 7 rounds" \
  'printf "%s\n" "$OUT" | grep -q "^acme/widgets/t-1 " && printf "%s\n" "$OUT" | grep -q "^acme/widgets/t-2 " && ! printf "%s\n" "$OUT" | grep -qE "^old/project|^acme/old" && printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "rounds 7"'

OUT=$(stats --chain t-1 --repo acme/widgets 2>/dev/null)
check "--chain and --repo combine: the surviving group is t-1 whole, 5 rounds, 17m30s" \
  'printf "%s\n" "$OUT" | grep -q "^acme/widgets/t-1 " && printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "rounds 5" && printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "17m30s"'

OUT=$(stats --chain nosuch 2>/dev/null); rc=$?
check "a filter that names no group is the same honest zero: exit 0, rounds 0" \
  '[ "$rc" = 0 ] && printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "rounds 0"'

# ------------------------------------------------------------------ --json -------
# The same facts, as one document: groups/findings/failures as lists in table order,
# totals, counts, the filters echo, and the two line counts. Numbers are numbers.

OUT=$(stats --json 2>"$T/err.txt"); rc=$?
check "--json exits 0 and stdout is one parseable JSON document" \
  '[ "$rc" = 0 ] && printf "%s\n" "$OUT" | python3 -c "import json,sys; json.loads(sys.stdin.read())"'
check "--json: stderr stays silent, the skipped count lives in the document not in prose" \
  'test "$(grep -c "" "$T/err.txt")" = 0'
check "--json: counts are the rows as read: 9 round, 5 review, 2 timeline-joined, 4 groups" \
  'test "$(st "[\"counts\"][\"round_rows\"]")" = 9 && test "$(st "[\"counts\"][\"review_rows\"]")" = 5 && test "$(st "[\"counts\"][\"timeline_rows\"]")" = 2 && test "$(st "[\"counts\"][\"groups\"]")" = 4'
check "--json: skipped and filtered counted at the line level, 4 and 1 (the benchmark line)" \
  'test "$(st "[\"skipped\"]")" = 4 && test "$(st "[\"filtered\"]")" = 1'
check "--json: groups is four, sorted, each with all four axes" \
  'test "$(printf "%s\n" "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d[\"groups\"]))")" = 4 && test "$(st "[\"groups\"][1][\"repo\"]")/$(st "[\"groups\"][1][\"chain\"]")" = acme/widgets/t-1'
check "--json: a group's figures are the printed ones, as numbers: rounds, ok, wall, retries" \
  'test "$(grpf "acme/widgets/t-1" "[\"rounds\"]")" = 5 && test "$(grpf "acme/widgets/t-1" "[\"ok_pct\"]")" = 0.0 && test "$(grpf "acme/widgets/t-1" "[\"wall_s\"]")" = 1050.0 && test "$(grpf "acme/widgets/t-1" "[\"retries\"]")" = 4'
check "--json: ok% names its source, and sources name the import" \
  'test "$(grpf "acme/widgets/t-1" "[\"ok_source\"]")" = mixed && test "$(grpf "acme/widgets/t-2" "[\"ok_source\"]")" = status && test "$(grpf "old/project/t-9" "[\"import_rounds\"]")" = 1 && test "$(grpf "acme/widgets/t-1" "[\"import_rounds\"]")" = 0'
check "--json: tokens carry in/out/reasoning and the cache mean" \
  'test "$(grpf "acme/widgets/t-1" "[\"tokens\"][\"input_tokens\"]")" = 1050 && test "$(grpf "acme/widgets/t-1" "[\"cache_pct\"]")" = 55.0'
check "--json reliability: t-1 saw 3 model requests, 1 nudge and 1 invalid-args per 100 of them (2 sig figs), verify-fail not among the rates" \
  'test "$(grpf "acme/widgets/t-1" "[\"requests\"]")" = 3 && test "$(grpf "acme/widgets/t-1" "[\"rates_per_100_requests\"][\"nudge:malformed\"]")" = 33.33 && test "$(grpf "acme/widgets/t-1" "[\"rates_per_100_requests\"][\"tool-error:invalid-args\"]")" = 33.33 && test "$(grpf "acme/widgets/t-1" "[\"rates_per_100_requests\"].get(\"verify-fail\")")" = None'
check "--json reliability: t-1 verify_fails 1, per 100 rounds 20.0 of its 5 rounds" \
  'test "$(grpf "acme/widgets/t-1" "[\"verify_fails\"]")" = 1 && test "$(grpf "acme/widgets/t-1" "[\"verify_fail_per_100_rounds\"]")" = 20.0'
check "--json reliability: t-1's buckets: the v1 step lands in unknown, the nudge in 32-64k at 100.0, the two events in 256-512k" \
  'test "$(grpf "acme/widgets/t-1" "[\"by_context\"][\"unknown\"][\"requests\"]")" = 1 && test "$(grpf "acme/widgets/t-1" "[\"by_context\"][\"32-64k\"][\"requests\"]")" = 1 && test "$(grpf "acme/widgets/t-1" "[\"by_context\"][\"32-64k\"][\"events\"][\"nudge:malformed\"]")" = 1 && test "$(grpf "acme/widgets/t-1" "[\"by_context\"][\"32-64k\"][\"rates_per_100_requests\"][\"nudge:malformed\"]")" = 100.0 && test "$(grpf "acme/widgets/t-1" "[\"by_context\"][\"256-512k\"][\"events\"][\"verify-fail\"]")" = 1 && test "$(grpf "acme/widgets/t-1" "[\"by_context\"][\"256-512k\"][\"rates_per_100_requests\"][\"tool-error:invalid-args\"]")" = 100.0'
check "--json reliability: only buckets that exist get cells; a clean group has no by_context cells and null rates" \
  'test "$(grpf "acme/widgets/t-1" "[\"by_context\"].get(\"64-128k\")")" = None && test "$(grpf "acme/widgets/t-1" "[\"by_context\"].get(\"0-32k\")")" = None && test "$(grpf "acme/widgets/t-2" "[\"requests\"]")" = 0 && test "$(grpf "acme/widgets/t-2" "[\"rates_per_100_requests\"]")" = None && test "$(grpf "acme/widgets/t-2" "[\"by_context\"]")" = "{}"'
check "--json: findings keyed by the same order, t-1 with 4 reviews and 55 lines" \
  'test "$(st "[\"findings\"][1][\"rows\"]")" = 4 && test "$(st "[\"findings\"][1][\"lines_changed\"]")" = 55 && test "$(st "[\"findings\"][1][\"bugs_high\"]")" = 3'
check "--json: the group without reviews still has a zero findings row" \
  'test "$(st "[\"findings\"][0][\"rows\"]")" = 0 && test "$(st "[\"findings\"][0][\"lines_changed\"]")" = 0'
check "--json: failures spell every status the table spells, at their zeroes" \
  'test "$(st "[\"failures\"][1][\"tool_errors\"]")" = 6 && test "$(st "[\"failures\"][1][\"statuses\"][\"worker-error\"]")" = 1 && test "$(st "[\"failures\"][0][\"statuses\"][\"truncated\"]")" = 0'
check "--json: a failures row carries verify_fails from its timeline events, 0 without one" \
  'test "$(st "[\"failures\"][1][\"verify_fails\"]")" = 1 && test "$(st "[\"failures\"][0][\"verify_fails\"]")" = 0'
check "--json: totals agree with the total line, plus how many groups they span" \
  'test "$(st "[\"totals\"][\"rounds\"]")" = 9 && test "$(st "[\"totals\"][\"wall_s\"]")" = 2240.0 && test "$(st "[\"totals\"][\"retries\"]")" = 5 && test "$(st "[\"totals\"][\"groups\"]")" = 4'
check "--json reliability totals: 3 requests, the same two rates, 1 verify-fail over 9 rounds at 11.11" \
  'test "$(st "[\"totals\"][\"requests\"]")" = 3 && test "$(st "[\"totals\"][\"rates_per_100_requests\"][\"nudge:malformed\"]")" = 33.33 && test "$(st "[\"totals\"][\"verify_fails\"]")" = 1 && test "$(st "[\"totals\"][\"verify_fail_per_100_rounds\"]")" = 11.11'
check "--json: the document echoes the filters it applied, null for those it did not" \
  'test "$(st "[\"filters\"][\"chain\"]")" = None && test "$(st "[\"filters\"][\"since\"]")" = None'

OUT=$(stats --chain t-2 --json 2>/dev/null)
check "--json with a filter: one group, the filter echoed, other chains gone" \
  'test "$(st "[\"filters\"][\"chain\"]")" = t-2 && test "$(printf "%s\n" "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d[\"groups\"]), d[\"groups\"][0][\"chain\"])")" = "1 t-2"'

# ok% is per task, never a mix of units: a task with a review counts by its latest verdict, even
# when its last round's status says otherwise; every task reviewed makes the source `review`.
R=$T/reviewed.jsonl
DELEGATE_LEDGER=$R rnd t-r1 acme/rev t-r m1 hard partial $TS 'round=1,duration_s=5'
DELEGATE_LEDGER=$R lg review t-r1 --verdict fixed --round 1 >/dev/null
DELEGATE_LEDGER=$R rnd t-r2 acme/rev t-r m1 hard done $TS 'round=1,duration_s=5'
DELEGATE_LEDGER=$R lg review t-r2 --verdict rejected --round 1 >/dev/null
OUT=$(DELEGATE_LEDGER=$R stats --json 2>/dev/null)
check "every task reviewed: ok% is the verdicts' (1 fixed of 2), source review, over tasks not reviews" \
  'test "$(grpf "acme/rev/t-r" "[\"ok_pct\"]")" = 50.0 && test "$(grpf "acme/rev/t-r" "[\"ok_source\"]")" = review && test "$(grpf "acme/rev/t-r" "[\"ok_den\"]")" = 2'

# a round run from a linked worktree groups under its main checkout (the project), not the worktree
W=$T/worktree.jsonl
DELEGATE_LEDGER=$W rnd t-w1 /work/trees/proj-x t-w m1 hard done $TS 'round=1,project=/src/proj'
DELEGATE_LEDGER=$W rnd t-w2 /src/proj t-w m1 hard done $TS 'round=1,project=/src/proj'
OUT=$(DELEGATE_LEDGER=$W stats --json 2>/dev/null)
check "the project axis joins a worktree's rounds to their main checkout" \
  'test "$(printf "%s\n" "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d[\"groups\"]), d[\"groups\"][0][\"repo\"], d[\"groups\"][0][\"rounds\"])")" = "1 /src/proj 2"'

# ------------------------------------------------------------------ the empty ends -------
# Stats is a reader, and readers answer zero rather than throw: a ledger that is not there,
# is empty, or cannot be read all get the same empty tables at exit 0.

: > "$T/empty.jsonl"
OUT=$(DELEGATE_LEDGER=$T/empty.jsonl stats 2>"$T/err.txt"); rc=$?
check "an empty ledger exits 0 with the tables and a zero total" \
  '[ "$rc" = 0 ] && printf "%s\n" "$OUT" | grep -q "0 of 0 round rows" && printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "rounds 0"'
check "an empty ledger earns no warning: nothing was skipped" \
  'test "$(grep -c "" "$T/err.txt")" = 0'

OUT=$(DELEGATE_LEDGER=$T/never-written.jsonl stats 2>/dev/null); rc=$?
check "a ledger path that was never written is the same zero answer" \
  '[ "$rc" = 0 ] && printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "rounds 0"'

: > "$T/locked.jsonl" && printf '%s\n' '{"kind":"round","schema":1}' >> "$T/locked.jsonl" && chmod 000 "$T/locked.jsonl"
OUT=$(DELEGATE_LEDGER=$T/locked.jsonl stats 2>/dev/null); rc=$?
chmod 644 "$T/locked.jsonl"
check "a ledger this user cannot read is an empty table at exit 0, not a stack trace" \
  '[ "$rc" = 0 ] && printf "%s\n" "$OUT" | grep -A1 "^total$" | grep -q "rounds 0"'

OUT=$(DELEGATE_LEDGER=off stats 2>"$T/err.txt"); rc=$?
check "DELEGATE_LEDGER=off says so once on stderr and shows empty tables at exit 0" \
  '[ "$rc" = 0 ] && grep -q "^delegate: warn: ledger stats: the ledger is off (DELEGATE_LEDGER=off): empty tables$" "$T/err.txt" && printf "%s\n" "$OUT" | grep -q "0 of 0 round rows"'

# ------------------------------------------------------------------ usage and misuse -------

OUT=$(stats --since 11-01 2>&1 1>/dev/null); rc=$?
check "--since that is not a YYYY-MM-DD date dies with rc 1 and says what it wanted" \
  '[ "$rc" = 1 ] && printf "%s\n" "$OUT" | grep -q "YYYY-MM-DD"'
stats --since >/dev/null 2>&1; rc=$?
check "--since with no value dies" '[ "$rc" = 1 ]'
OUT=$(stats --wat 2>&1 1>/dev/null); rc=$?
check "an unknown flag dies, and its usage line names the flags that do exist" \
  '[ "$rc" = 1 ] && printf "%s\n" "$OUT" | grep -q "usage: delegate stats" && printf "%s\n" "$OUT" | grep -q -- "--json"'
OUT=$(stats --help 2>&1); rc=$?
check "stats --help prints the usage at exit 0" \
  '[ "$rc" = 0 ] && printf "%s\n" "$OUT" | grep -q "usage: delegate stats \[--chain NAME\] \[--repo R\]"'

# ------------------------------------------------------------------ read-only, by contract -------
# The whole command must not move a byte: the ledger it read is bit-identical, and the state
# dir gained nothing while stats ran.

touch "$T/marker"
stats --json >/dev/null 2>&1
stats --since 2020-01-01 --chain t-1 >/dev/null 2>&1
check "the ledger file is bit-identical after every run: stats writes nothing there" \
  'test "$(cksum < "$L")" = "$CKSUM"'
check "stats touched nothing in the state dir: no db, no run dirs, no new files" \
  'test -z "$(find "$DELEGATE_STATE" -newer "$T/marker")"'
check "and it did not so much as create the state dir when pointed elsewhere" \
  'test ! -e "$T/elsewhere" && DELEGATE_LEDGER=$T/never-written.jsonl DELEGATE_STATE=$T/elsewhere stats >/dev/null 2>&1; test ! -e "$T/elsewhere"'

# ------------------------------------------------------------------ static, in the repo -------

"$here/bin/delegate" help > "$T/help.txt" 2>&1
check "delegate help advertises the stats command" \
  'grep -q "stats" "$T/help.txt"'
check "bin/delegate dispatches stats to cmd_stats" \
  'grep -qE "^\s*stats\) cmd_stats" "$here/bin/delegate"'
check "docs/reference.md documents delegate stats" \
  'grep -q "delegate stats" "$here/docs/reference.md"'

# Failed verifies count off the round rows' verify_rc, so a round recorded before timeline
# schema 2 (a v1 timeline row: no events) still counts: 1 of these 2 rounds failed its verify.
V=$T/led/verify.jsonl
DELEGATE_LEDGER=$V rnd t-v1 acme/ver t-v m1 hard done-but-verify-failed $TS 'round=1,duration_s=5,verify_rc=1'
DELEGATE_LEDGER=$V rnd t-v1 acme/ver t-v m1 hard done $TS 'round=2,duration_s=5,verify_rc=0'
printf '%s\n' '{"schema":1,"kind":"timeline","task_id":"t-v1","run_id":"t-v1","round":1,"steps":[],"tools":[],"source":"live","ts":"2026-11-10T00:00:00Z"}' >> "$V"
OUT=$(DELEGATE_LEDGER=$V stats --json 2>/dev/null)
check "verify-fail per 100 rounds comes from verify_rc: an old round with no events still counts (1 of 2 = 50)" \
  'test "$(st "[\"totals\"][\"verify_fails\"]")" = 1 && test "$(st "[\"totals\"][\"verify_fail_per_100_rounds\"]")" = 50.0'

# ------------------------------------------------------------------ verdict -------

echo
if [ "$fail" -eq 0 ]; then echo "PASS: test_stats"; else echo "FAIL: test_stats"; fi
exit $fail
