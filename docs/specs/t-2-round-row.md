# Task T2: the round row and its timeline — record every finished round

## The one move
In `bin/delegate`: write the `round` row and the `timeline` row at `finalize_round`
(R3/R4/R5), record effort (R3), and make the whole ledger path unable to change a
round's outcome. Add `tests/test_ledger_round.sh`.

## Why
T1 built the file protocol and `derive_timeline`. This task fills the ledger with real
data: one row per round from `report.json` + `meta.env` + the on-disk values the design
names, and the timeline row derived from the round's own `events.jsonl` before the 14-day
prune can take it (R2/R4). Field-by-field: `docs/specs/t-design.md` §Row schemas.

## What you may touch
- `bin/delegate` — the `cmd_run`/`cmd_continue` meta.env write (`EFFORT`),
  `finalize_round` (append after the report),
  `usage()` and the `ledger` case (its flags); `lib/taskstate.py` and `bin/delegate`'s `status` view only if you need the effort line (see Spec 1).
- `lib/ledger.py` — only where the row schemas demand it (field order, a row builder).
- `config.example.env`, `docs/reference.md` — the `EFFORT` meta key, ledger sections.
- `tests/test_ledger_round.sh` — create.

Nothing else. Existing tests must not change.

## Definitions
- **Round row** — `kind:"round"`, `schema:1`, the design's field list and order:
  identity (`task_id`, `slug`, `repo`, `chain`, `step`, `run_id`, `round`, `spec_hash`,
  `base_ref`, `base_sha`, `verify`), conditions (`endpoint` — the URL as configured, in
  full; `model`, `effort`, `effort_source: "cli"`, `delegate_version`, `rules_hash`,
  `image_stamp`, `runner`, `timeout_s`, `edit_cap`, `parallel_rounds`), outcome
  (`status`, `worker_status`, `exit`, `verify_rc`, `nudges`, `tool_calls`, `tool_errors`,
  `errors`, `todos_done`, `todos_total`, `retries`), cost/time (`round_start`,
  `round_end`, `duration_s`, `steps`, `input_tokens`, `output_tokens`,
  `reasoning_tokens`, `cache_read`, `cache_write`, `final_context_tokens`, `diff_lines`,
  `source`: empty, `ts`).
- **Timeline row** — `kind:"timeline"`, the `derive_timeline` result plus identity;
  written immediately after its round row.
- **Effort** — `hard` iff `--hard` was given at `cmd_run`/`cmd_continue`; stored in
  `meta.env` as `EFFORT` at the same write that stores `MODEL`; `--hard` on continue
  upgrades the stored value. An absent key reads `normal`.

## Specification
1. **Effort first** — write `EFFORT` into the meta.env block (bin/delegate ~921) for new
   and continued tasks; every later reader (row, `top`) takes it from the record, not the CLI.
2. **The rows** — in `finalize_round`, after `lib/report.py report` has written
   `$rd/report.json`: build the round row exactly in the design's field order — values
   from `report.json`, `meta.env`, `$TASK_DIR/spec.md` (sha256), `BASE_URL`, `VERSION`,
   the rules hash over `$DELEGATE_RULES_DIR` (the `context_stamp` construction),
   `image_stamp` (empty on the native runner), `DELEGATE_TIMEOUT`/`DELEGATE_CHUNK_CAP`
   in force, the sibling-`lock` scan for `parallel_rounds` (excluding this task), and
   `round_start`/`round_end` from `finalize_round`'s own arguments. Build the timeline
   row from `derive_timeline "$rd/events.jsonl"`. Write both with the T1 CLI
   (`delegate ledger append --file -`); extend that case's flags as needed — additively.
   Token totals and cache sums come from the derivation's `totals` (one parse of the
   events file for both rows).
3. **Failure mode** — both appends follow the `fire_hook` pattern: on failure one
   `warn:` line, and the round's recorded outcome and exit code byte-identical to a
   ledger-less run. Ledger disabled (`LEDGER=off`/empty resolution failure): rows skipped
   silently.
4. **Native and docker runners** — `image_stamp` empty for native; the round row must not
   depend on docker being present.
5. **`delegate top`** — the running-task view groups by chain (lib/taskstate.py); a one-word effort marker per task is welcome there **only if** it falls out of reading `meta.env` fields generically; do not restructure it. (There is no `delegate status` command; effort visibility rides `top`/`list` or nothing.)

## Report
Write your diff; then answer, in order: (1) for every `grep -n '^function '
bin/delegate` function your diff touches — did you change it? (2) for the ones you did
not change (especially `do_round`, and the value `finalize_round` returns to its
callers) — did you copy its contract exactly? (3) is any new code path unexercised by
`tests/test_ledger_round.sh`? The reviewer reads your diff hunk by hunk and audits each
one against its surroundings; a hunk that silently shifts an outcome — the value
`finalize_round` returns, the warn ordering — is a failed task.

## Boundaries
- No lifecycle change beyond the append points: `do_round` untouched; inside
  `finalize_round` the `return` the callers see must be unchanged — proved in a test,
  not in prose.
- The round row and timeline row contain no tool input/output/text (R4): the test greps
  the written line for fixture marker strings that sit in the fake events file's
  input/output parts and asserts they never reach the ledger.
- The `endpoint` value is the URL exactly as configured — recorded in full, never
  hashed, never truncated; keys and key files never appear (R7).
- `prune`/`rm`/`--clean` isolation is T3's test, not yours; do not touch them.
- Don't add features: no review rows (T3), no stats (T4).

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check will blame your untracked
deliverables ("stray untracked files") — that check only passes once the files are
committed, which the harness does at round end, before the chain's verify runs
(bin/delegate `finalize_round`: commit ~730, verify ~743). Run the full gate; if that
one check is the only failure, it is this known interaction — report it, don't edit
the test.

```bash
set -o pipefail && bash -n bin/delegate && python3 -m py_compile lib/*.py && [ -f tests/test_ledger_round.sh ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && ! git diff --name-only delegate/t-1-ledger-core | grep -qvE '^docs/specs/(t-brief|t-design|t-chain\.json|t-1-ledger-core\.md|t-2-round-row\.md)$|^bin/delegate$|^lib/ledger\.py$|^config\.example\.env$|^docs/reference\.md$|^tests/test_ledger(_round)?\.sh$' && echo GATE-OK
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
