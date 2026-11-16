# Task T3: `delegate ledger review` and `delegate ledger import`

## The one move
Add the review-row command (R5) and the one-time import (R8): review as flags, import
through the same code path a live round uses, deduplicated by task id + round. All of it
in `lib/ledger.py` plus one dispatch case each in `bin/delegate`. Tests extend
`tests/test_ledger.sh` in place.

## Why
R5: the orchestrator records verdicts as rows, linked to round rows by task id — a
verdict is data it supplies, not a document to parse. R8: every task record that still
exists becomes real `round` + `timeline` rows, once, marked as imported, so the ledger
covers history without a second schema. Design: `docs/specs/t-design.md` (§Review row,
§Import).

## What you may touch
- `lib/ledger.py` — the review row builder, the import walk, dedupe.
- `bin/delegate` — the `ledger review` and `ledger import` cases, `usage()`.
- `config.example.env`, `docs/reference.md` — the two commands.
- `tests/test_ledger.sh` — extend in place (do not create another ledger test file).

Nothing else; no other test changes; `finalize_round`'s T2 append points stay exactly as
T2 wrote them.

## Specification
1. **`delegate ledger review TASK_ID [--round N] --verdict accepted|fixed|rejected
   --bugs high=N,medium=N,low=N --lines-changed N [--note TEXT]`** — one `review` row
   per call, fields in the design's order (`task_id`, `round`, `verdict`,
   `bugs_high`/`bugs_medium`/`bugs_low`, `lines_changed`, `note`, `ts`). `--round`
   defaults to the highest `round`-kind row for that task already in the ledger (empty
   when none). Missing `--verdict` or a value outside the three: `die` — this command
   takes the orchestrator's judgement as input, so refusing bad input is correct (the
   never-fatal rule is about the *file*). A ledger-write failure is the usual one
   `warn:` line, exit 0.
2. **`delegate ledger import [--state DIR]`** — walks directories under the state dir
   that contain `meta.env` (the scan lib/taskstate.py uses, ~353). For each round dir
   with a `report.json`: build the `round` row and `timeline` row through the same
   builders T2 uses live, fed from `report.json` + `meta.env` + the files on disk
   (`spec.md` hash; `diffstat`; `derive_timeline` over the round's `events.jsonl`),
   `source: "import"`. Recovery table — design §Import — fields that cannot be
   recovered stay empty. Effort inference: `hard` iff the round's `report.json` `model`
   equals the configured `DELEGATE_MODEL_HARD` and that differs from `DELEGATE_MODEL`,
   else `normal`, with `effort_source: "inferred"` on the row. Idempotent: a
   `(task_id, round)` that already has a `round`-kind row (any source) is skipped; the
   command prints one summary line (`imported N, skipped M, tasks K`). Never exits
   non-zero because a task dir was unreadable — that task is counted skipped with a
   `warn:` line.
3. **Isolation tests (R2)** — with the default path and with `LEDGER` (via
   `DELEGATE_LEDGER`) pointed *inside* `$DELEGATE_STATE` beside the task dirs: after
   `delegate prune` of an imported-everything state and after `delegate rm` of a task,
   the ledger file and all its rows survive.
4. **Docs** — both commands in `docs/reference.md`, `usage()`, and the example config
   note that `delegate ledger import` is run once by the owner.

## Report
Write your diff; then answer, in order: (1) for every `grep -n '^function ' bin/delegate`
function your diff touches — did you change it? (2) did `finalize_round` change at all?
(3) could `delegate ledger import` run twice and double any count? (4) is any new code
path unexercised by the tests?

## Boundaries
- Read-only over the task records: import never writes, moves or deletes anything under
  `$DELEGATE_STATE` except appending to the ledger (R8 is an import, not a migration).
- No git at all in `lib/ledger.py` (R2).
- Review rows carry no diff content, no file lists, no prose beyond `--note` (R4/R5).
- Don't add features: no stats (T4), no export, no "undo import".

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check will blame your untracked
deliverables ("stray untracked files") — that check only passes once the files are
committed, which the harness does at round end, before the chain's verify runs
(bin/delegate `finalize_round`: commit ~730, verify ~743). Run the full gate; if that
one check is the only failure, it is this known interaction — report it, don't edit
the test.

```bash
set -o pipefail && bash -n bin/delegate && python3 -m py_compile lib/*.py && [ -f tests/test_ledger.sh ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && ! git diff --name-only delegate/t-2-round-row | grep -qvE '^docs/specs/(t-brief|t-design|t-chain\.json|t-1-ledger-core\.md|t-2-round-row\.md|t-3-review-import\.md)$|^bin/delegate$|^lib/ledger\.py$|^config\.example\.env$|^docs/reference\.md$|^tests/test_ledger(_round)?\.sh$' && echo GATE-OK
```

## Report format
```text
STATUS: done|partial|blocked
SUMMARY: <=3 sentences
TESTS: <counts; which suites ran; gate result>
RISKS: <what might still be wrong>
DEVIATIONS: <departures from this spec and why, or none>
DIFF: <the diff you wrote>
```
