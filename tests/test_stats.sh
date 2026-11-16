#!/bin/bash
# T4: `delegate stats` — R6's per-project totals, read off the ledger's `round` and `review`
# rows. Fixture rows are seeded through `delegate ledger append` / `delegate ledger review` into
# a ledger under mktemp -d, and every figure stats prints is checked against those same rows by
# hand: rounds, the ok% rate and the source it labelled, retries as `sum(max(round)-1)`, the
# cache mean, wall time and its mean, the findings and failures tables, the import label,
# --since, the two filters, and --json. Stats is a reader: it writes nothing, and it parses no
# kind it has no use for. No docker, no model, no network, no repository.
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
rnd t-a1 $A t-1 m1 hard done-but-verify-failed  $TS 'round=5,duration_s=400,input_tokens=400,output_tokens=40,reasoning_tokens=4,cache_read=400,cache_write=0,tool_errors=0,errors=0'
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

# A timeline row and a slice-B `benchmark` row, both written by hand because the CLI would
# rather die than invent one: stats must drop both at the line level, without parsing them, and
# without a word about it. Their markers must never reach an output line.
printf '%s\n' '{"kind":"timeline","schema":1,"task_id":"t-a1","run_id":"t-a1","round":3,"steps":[{"start":1,"end":2,"input":7,"output":7,"reasoning":0,"cache_read":0,"cache_write":0,"reason":"tool-calls"}],"tools":[{"tool":"bash","status":"completed","start":1,"end":2}],"source":"","ts":"2026-11-10T00:00:00Z","note":"TIMELINE-SECRET-MARKER"}' >> "$L"
printf '%s\n' '{"kind":"benchmark","schema":1,"task_id":"bench-1","ts":"2026-11-10T00:00:00Z","note":"BENCHMARK-SECRET-MARKER"}' >> "$L"
# Four lines this build cannot use at all — malformed, an unknown kind, a schema from the
# future, and JSON that is no object — which stats counts on exactly one warning line.
printf '%s\n' 'not json at all, and stats counts it rather than choking on it' >> "$L"
printf '%s\n' '{"kind":"teleport","schema":1,"task_id":"t-a1"}' >> "$L"
printf '%s\n' '{"kind":"round","schema":99,"task_id":"t-a1","ts":"2026-11-10T00:00:00Z"}' >> "$L"
printf '%s\n' '[1,2,3]' >> "$L"
CKSUM=$(cksum < "$L")
check "the fixture ledger holds 9 round, 5 review, 2 foreign and 4 junk lines" \
  'test "$(grep -c "" "$L")" = 20'

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
check "--json: counts are the rows as read: 9 round, 5 review, 4 groups" \
  'test "$(st "[\"counts\"][\"round_rows\"]")" = 9 && test "$(st "[\"counts\"][\"review_rows\"]")" = 5 && test "$(st "[\"counts\"][\"groups\"]")" = 4'
check "--json: skipped and filtered counted at the line level, 4 and 2" \
  'test "$(st "[\"skipped\"]")" = 4 && test "$(st "[\"filtered\"]")" = 2'
check "--json: groups is four, sorted, each with all four axes" \
  'test "$(printf "%s\n" "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d[\"groups\"]))")" = 4 && test "$(st "[\"groups\"][1][\"repo\"]")/$(st "[\"groups\"][1][\"chain\"]")" = acme/widgets/t-1'
check "--json: a group's figures are the printed ones, as numbers: rounds, ok, wall, retries" \
  'test "$(grpf "acme/widgets/t-1" "[\"rounds\"]")" = 5 && test "$(grpf "acme/widgets/t-1" "[\"ok_pct\"]")" = 0.0 && test "$(grpf "acme/widgets/t-1" "[\"wall_s\"]")" = 1050.0 && test "$(grpf "acme/widgets/t-1" "[\"retries\"]")" = 4'
check "--json: ok% names its source, and sources name the import" \
  'test "$(grpf "acme/widgets/t-1" "[\"ok_source\"]")" = mixed && test "$(grpf "acme/widgets/t-2" "[\"ok_source\"]")" = status && test "$(grpf "old/project/t-9" "[\"import_rounds\"]")" = 1 && test "$(grpf "acme/widgets/t-1" "[\"import_rounds\"]")" = 0'
check "--json: tokens carry in/out/reasoning and the cache mean" \
  'test "$(grpf "acme/widgets/t-1" "[\"tokens\"][\"input_tokens\"]")" = 1050 && test "$(grpf "acme/widgets/t-1" "[\"cache_pct\"]")" = 55.0'
check "--json: findings keyed by the same order, t-1 with 4 reviews and 55 lines" \
  'test "$(st "[\"findings\"][1][\"rows\"]")" = 4 && test "$(st "[\"findings\"][1][\"lines_changed\"]")" = 55 && test "$(st "[\"findings\"][1][\"bugs_high\"]")" = 3'
check "--json: the group without reviews still has a zero findings row" \
  'test "$(st "[\"findings\"][0][\"rows\"]")" = 0 && test "$(st "[\"findings\"][0][\"lines_changed\"]")" = 0'
check "--json: failures spell every status the table spells, at their zeroes" \
  'test "$(st "[\"failures\"][1][\"tool_errors\"]")" = 6 && test "$(st "[\"failures\"][1][\"statuses\"][\"worker-error\"]")" = 1 && test "$(st "[\"failures\"][0][\"statuses\"][\"truncated\"]")" = 0'
check "--json: totals agree with the total line, plus how many groups they span" \
  'test "$(st "[\"totals\"][\"rounds\"]")" = 9 && test "$(st "[\"totals\"][\"wall_s\"]")" = 2240.0 && test "$(st "[\"totals\"][\"retries\"]")" = 5 && test "$(st "[\"totals\"][\"groups\"]")" = 4'
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

# ------------------------------------------------------------------ verdict -------

echo
if [ "$fail" -eq 0 ]; then echo "PASS: test_stats"; else echo "FAIL: test_stats"; fi
exit $fail
