# Task T2-F: a chain row, and forensic text on the round row

## The one move
Make the ledger keep everything a later reader needs to understand a finished task once its
record has been pruned, except the command log:
1. a new `kind:"chain"` row, written by `lib/chain.py` when a chain run ends;
2. round rows go to `schema: 3`, gaining `todos` (the plan's items with their status) and
   `worker_report` (the worker's STATUS block, parsed).
Add `tests/test_ledger_forensics.sh`.

## Why
A consumer (a work view) shows finished delegate work long after `delegate prune` has removed the
task record (`DELEGATE_PRUNE_DAYS`, default 14). Today the ledger has per-round numbers and a
per-step timeline, but not how a chain ended, not the plan's items, and not the worker's STATUS
block. The owner's ruling (2026-11-17): keep steps, rounds, retries, nudges, errors, verify exit
codes, statuses, plan items and the STATUS block; never tool inputs or outputs, commands, file
contents, diffs or transcripts.

## Read first
- `docs/specs/t-design.md` (§Row schemas, kinds and versions, forward compatibility) and
  `docs/specs/t-2-round-row.md` (how the round row was added; imitate it).
- `lib/ledger.py`: `KINDS`, `ROUND_KEYS`, `build_round_row`, `append_round_and_timeline`,
  `append`, `read_rows`, `_accepted`, `read_stats_rows`, `stats`, `import_state`.
- `lib/report.py`: `summarize` (the `todos` it already extracts from the final todo write),
  `final_text`, `cmd_report` (the `STATUS:` match and the `report.json` it writes).
- `opencode/delegate-rules.md` lines ~108-125: the STATUS block the worker ends with.
- `lib/chain.py`: `run(plan)` (every way it ends: all done, a step blocked/partial/failed, retries
  exhausted, interrupted by a signal), `load_state`, `status`, `chain_state_path`.
- `bin/delegate`: where `finalize_round` calls the ledger; `ORCH`/`ORCH_SESSION` in `meta.env`.
- Tests to imitate: `tests/test_ledger_round.sh`, `tests/test_chain.sh`, `tests/test_ledger.sh`.

## What you may touch
- `lib/ledger.py`, `lib/report.py`, `lib/chain.py`; `bin/delegate` only where the ledger call
  needs a value it does not pass yet.
- `docs/reference.md` (the ledger section: the new kind and the new fields), `docs/specs/t-design.md`
  (add the two schemas under §Row schemas, marked "T2-F").
- `tests/test_ledger_forensics.sh` (create). Existing tests must not change, and must still pass.

Nothing else.

## Contract (verbatim)

### Round row, schema 3
`KINDS["round"] = 3`. `ROUND_KEYS` gains, in this order, after `todos_total`:
`"todos"`, `"worker_report"`.

- `todos`: list of `{"text": str, "status": str}` from the round's final todo write (the
  `todos` `summarize` already finds; item `content` -> `text`, `status` as written), at most 50
  items, each `text` cut to 200 characters; `null` when the round made no todo write.
- `worker_report`: `null` when the worker's final message has no `STATUS:` line; else
  `{"status": str|null, "not_verified": [str], "deviations": [str], "decisions": [str],
  "omissions": [str], "suggestions": [str], "questions": [str]}` parsed from the block in the
  final message. Each list holds the section's lines (a one-line `HEADING: text` gives one item;
  following `- item` lines give one item each, the leading `- ` stripped); an item reading `none`
  (any case) or an empty section gives `[]`. At most 20 items per list, each cut to 300
  characters. `FILES`, `VERIFIED` and `EVIDENCE` are **not** kept (paths and command lines).
- Both fields are derived in `lib/report.py` and written into `report.json` (so `import_state`
  can rebuild them from a stored round), then carried into the round row by `build_round_row`.
- A reader keeps accepting schema 1 and 2 rows unchanged (missing fields read as `null`).

### Chain row, schema 1 (new kind)
`KINDS["chain"] = 1`. Written once per `delegate chain` run, when `run(plan)` stops for any
reason, including SIGINT/SIGTERM (catch, write, re-raise or exit as today). Never written by
`status`, `wait`, or `--clean`. Field order:

`chain` (the plan's `name`), `repo` (absolute), `project` (as `project_of` gives it), `plan_hash`
(sha256 of the plan file's bytes, hex), `started_at`, `ended_at` (ISO 8601 UTC, seconds),
`outcome` (`done` | `blocked` | `partial` | `failed` | `interrupted`), `exit` (the run's exit
code), `steps` (list, one per plan step in plan order: `{"step": name, "task_id": str|null,
"status": the step's status as `status(plan)` reports it, "rounds": int|null, "retries":
int|null, "hard": bool}`), `orchestrator`, `orchestrator_session` (from the environment the
chain runs in, the same source `meta.env`'s `ORCH`/`ORCH_SESSION` use; `null` when unknown),
`ts`.

`outcome`: `done` when every step is done; else the status of the first step that is not done
(`blocked`, `partial`, or `failed` for anything else a step can end in); `interrupted` when a
signal stopped the run.

### Rules that hold for both
- Writing a ledger row can never change a round's or a chain's outcome or exit code: any error is
  one warning line on stderr, then the run continues as it would have (same as T2's rule).
- Nothing from tool inputs or outputs, commands, file contents or diffs enters either row.
- `delegate stats`, `delegate ledger show` and `import_state` keep working; `stats` ignores the
  `chain` kind (it is not a round).

## Acceptance (verify)
The repo's full gate, plus the new suite:
`bash -n bin/delegate && python3 -m py_compile lib/*.py && for t in tests/test_*.sh; do bash "$t" || exit 1; done`

`tests/test_ledger_forensics.sh` must cover, with a temp `DELEGATE_STATE` and ledger (never the
real ones):
1. a round whose final message has a full STATUS block -> row schema 3, `worker_report` lists
   exactly as specified (multi-line `- ` items, `none`, a one-line heading, caps at 20/300);
   `FILES`/`VERIFIED`/`EVIDENCE` text absent from the row's JSON;
2. a final message with no STATUS line -> `worker_report: null`; no todo write -> `todos: null`;
   60 todos -> 50 kept, a 500-character item cut to 200;
3. a planted marker string inside a tool input and a tool output of the events -> absent from
   every row written;
4. a fake chain (imitate `tests/test_chain.sh`) that ends done, one that ends blocked, and one
   stopped by SIGTERM -> one chain row each with the right `outcome`, `exit` and `steps`;
5. a ledger whose append fails (read-only file) -> the round and the chain keep their outcome and
   exit code, one warning line;
6. schema 1 and 2 round rows still read by `read_rows` and counted by `stats`; a `chain` row is not
   counted as a round.

## Out of scope
The bench slice's `verdict`/`benchmark` kinds; `delegate prune` (its behaviour stays as it is);
any UI; backfilling old rows.
