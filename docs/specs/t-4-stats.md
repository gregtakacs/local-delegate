# Task T4: `delegate stats` — the slice's only consumer

## The one move
Add `delegate stats` (R6): per-project totals over `round` and `review` rows, grouped by
repo / chain / model / effort, plus `--json`; add the backlog section to
`docs/reference.md`. New behaviour in `tests/test_stats.sh`.

## Why
R6 is the point of the ledger: rounds, wall time, tokens, retries and review findings per
project, from the rows — not from task dirs, not from chain state (which `--clean`
removes). Design: `docs/specs/t-design.md` §Stats.

## What you may touch
- `bin/delegate` — dispatch + usage.
- `lib/ledger.py` — aggregation.
- `docs/reference.md` — the stats section and the post-T backlog section (§What comes
  after T below, verbatim).
- `tests/test_stats.sh` — create.

Nothing else; no other test changes. `lib/report.py` stays untouched — stats reads rows,
never reports.

## Specification
1. **Command** — `delegate stats [--chain NAME] [--repo R] [--since YYYY-MM-DD]
   [--json]`. Reads `round` and `review` rows only (timeline rows filtered by `kind`
   before parsing; unknown kinds and malformed lines skipped, counted on one warning
   line). Default output, per project grouped by repo / chain / model / effort (R6's
   four axes):
   ```text
   repo/chain      model        effort  rounds  ok%  wall     tok(in/out/r)  cache%  retries
   ```
   where `ok%` is accepted-or-fixed over the groups' review rows when any exist, else
   `done` over round statuses (labelled which source it used); then one findings table
   (verdict counts, bugs by severity, reviewer lines changed — review rows only); then
   one failures table (`tool_errors`, `errors`, status counts incl. `worker-error`,
   `timeout`, `truncated`, `done-but-verify-failed`). Import-sourced rows are labelled
   (`source:"import"`). `--json` prints the same facts as one object. Empty or unreadable
   ledger: empty tables, exit 0; `--since` filters on `ts`.
2. **Derivations** — retries per group = `sum(max(round) − 1)` over the group's task
   ids; cache % per round = `cache_read / (cache_read + input_tokens)`, mean over rounds
   with tokens > 0; wall = `duration_s` sum and mean; tokens = the row fields summed.
   No prices, no dollar amounts anywhere (R6 asks for counts).
3. **Docs** — the stats section, plus a post-T backlog section in `docs/reference.md`
   carrying, verbatim, this design's §What comes after T.
4. **Tests** — `tests/test_stats.sh`: fixture `round`/`review` rows seeded through
   `delegate ledger append`; exact-number assertions for one group (rounds, ok%, retries
   via `sum(max(round)-1)`, cache mean, findings table), a group with review rows and one
   without (the ok% source label differs), import-labelled rows counted separately, the
   empty ledger (empty tables, exit 0), `--since` filtering, unknown-kind lines ignored
   with the warning count, and `--json` parsed: every table present as data.

## Report
Write your diff; then answer, in order: (1) for every `grep -n '^function ' bin/delegate`
function your diff touches — did you change it? (2) can stats exit non-zero on an empty
or unreadable ledger? (3) does any output line contain tool input/output text or a key?
(4) is any new code path unexercised by the tests?

## Boundaries
- Read-only: the ledger is never opened for writing by stats; nothing under
  `$DELEGATE_STATE` is touched. The ledger stays append-only — no delete, edit or rotate
  path appears here (R2). Tests work on a fixture ledger under `mktemp -d`.
- Don't widen the product: no charts, no HTML, no `bench` (slice B's).

## What comes after T (docs only, this step)

Slice B (benchmarks) will add `benchmark` and `verdict` rows to the same ledger under
rulings R9–R17: fixed bundles extended from `evals/cases/` (R9), several runs per
condition with medians and spread (R10), delegate mode and own-harness mode (R11/R13),
hidden checks never in the sandbox (R12), sandbox-only auto-approval with owner-written
grants (R14), blind review with verdicts recorded before matching (R15), pluggable and
benchmarked reviewers (R16), lost history accepted (R17). The `KINDS` registry from T1
reserves both kind names; slice B defines the fields.

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check will blame your untracked
deliverables ("stray untracked files") — that check only passes once the files are
committed, which the harness does at round end, before the chain's verify runs
(bin/delegate `finalize_round`: commit ~730, verify ~743). Run the full gate; if that
one check is the only failure, it is this known interaction — report it, don't edit
the test.

```bash
set -o pipefail && bash -n bin/delegate && python3 -m py_compile lib/*.py && [ -f tests/test_stats.sh ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && ! git diff --name-only delegate/t-3-review-import | grep -qvE '^docs/specs/(t-brief|t-design|t-chain\.json|t-1-ledger-core\.md|t-2-round-row\.md|t-3-review-import\.md|t-4-stats\.md)$|^bin/delegate$|^lib/ledger\.py$|^docs/reference\.md$|^tests/test_stats\.sh$' && echo GATE-OK
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
