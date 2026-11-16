# Task T1: ledger core — lib/ledger.py, configuration, delegate ledger append/show

## The one move
Create `lib/ledger.py` — the ledger's whole file protocol plus the timeline derivation —
add the `LEDGER` config key, add `delegate ledger append|show`, document both, and make
`tests/test_ledger.sh` green.

## Why
Slice T's ledger is one append-only JSONL file outside every repository and outside the
task dirs (`docs/specs/t-design.md` §Location). T1 owns the file protocol (write, read,
kind registry) and `derive_timeline`, the one events-parsing function that T2 uses live
and T3 uses on import (R8: one code path). What rows the lifecycle *writes* is T2.

## What you may touch
- `lib/ledger.py` — create.
- `bin/delegate` — config block (`LEDGER`), `usage()`, the `ledger` subcommand dispatch.
- `config.example.env`, `docs/reference.md` — document, don't redesign.
- `tests/test_ledger.sh` — create.

Nothing else. In particular: no changes to `lib/report.py`, `lib/chain.py`,
`lib/taskstate.py`, or any existing test.

## Definitions
- **Row** — one flat JSON object per line. `kind` and `schema` are the first two keys
  written, so a reader can filter before parsing the rest.
- **Ledger path** — resolved by `lib/ledger.py`; see below.
- **Unknown kind** — a `kind` absent from `KINDS`.

## Specification

### `lib/ledger.py` — Python 3.10+ stdlib only, importable, no prints, no `sys.exit`
- `KINDS: dict[str, int]` = `{"round": 1, "timeline": 1, "review": 1, "benchmark": 1,
  "verdict": 1}` — the first three implemented by this slice, the last two registered for
  slice B so this build already skips their rows (design §Slice B). A row's kind is
  valid iff listed; its schema iff `1 <= schema <= KINDS[kind]`.
- `resolve_ledger(overrides: dict[str, str], env: Mapping[str, str]) -> str` — CLI
  override > env `DELEGATE_LEDGER` > `<state>/ledger/events.jsonl`, where `<state>` is
  the `DELEGATE_STATE` value from overrides/env, else `$XDG_STATE_HOME/delegate` (default
  `~/.local/state/delegate`) — matching lib/chain.py's default state dir. Pure function
  of its arguments; creates nothing.
- `append(ledger_path: str, row: Mapping) -> None` — requires valid `kind`/`schema`
  (raise `ValueError` otherwise); writes exactly one `\n`-terminated compact JSON line
  (`ensure_ascii=True`, separators without spaces, `kind` first) to `ledger_path`,
  creating parent dirs. Serialize writers with an exclusive `flock` on
  `<ledger_path>.lock`, obtained through a retry loop on `InterruptedError` (a signal
  must not lose a row), and flush + `fsync` the data file before releasing.
- `read_rows(ledger_path: str) -> Iterator[tuple[int, str, dict | None]]` — yields
  `(lineno, raw_text, row_or_None)` for every line; missing file yields nothing. The row
  is parsed only when the line is a JSON object with a valid `kind`/`schema`; otherwise
  `None` (malformed vs unknown derivable from `raw_text`). A trailing partial line
  yields `None` and never raises; reading takes no lock.
- `derive_timeline(events_path: str) -> dict` — the R4 derivation, one code path for live
  and import. Reads the opencode event stream: `step_start` opens a step at the event's
  millisecond `timestamp`; `step_finish` closes it with `part.tokens` (input, output,
  reasoning, cache.read, cache.write) and `part.reason`; each `tool_use` contributes
  `part.tool`, `part.state.status`, `part.state.time.start`/`.end`. Returns
  `{"steps": [...], "tools": [...], "totals": {"input": n, "output": n, "reasoning": n,
  "cache_read": n, "cache_write": n}}` in file order. Reads NOTHING else from an event —
  no `part.state.input`, no `part.state.output`, no `title`, no `metadata`, no `text`
  events (R4). A step never closed by `step_finish` (killed mid-step) closes at the last
  event timestamp with `reason` null and its partial tokens. Unparsable lines are
  skipped; a missing file returns empty lists and zero totals.

### `bin/delegate`
- Config block: `LEDGER="$(cfg LEDGER "")"` with the env-wins precedence stated in the
  comment, the way `GITHUB`/`IMAGE` document theirs.
- `delegate ledger append --kind K --task T --fields k=v[,k=v] [--task-dir D] [--status S] [--exit N] [--file F]`
  — `--file F` reads the row body from a JSON object file (`-` = stdin); merge order:
  file body, then scalars, then `--fields` (values comma-joined, JSON-parsed types kept,
  same rule as the other `--fields` uses in the file); `schema` from `KINDS[kind]`.
  `--task-dir D` supplies per-task values (the sourced `meta.env`) without a live task.
  T2 extends this flag list; design the case so it is additive. On ANY ledger failure:
  exactly one `warn: ...` line, exit 0. Success prints nothing.
- `delegate ledger show [--kind K]` — accepted rows, oldest first, one JSON object per
  line to stdout. Unreadable/missing = empty listing; unknown kinds and malformed lines
  are skipped, counted on one warning line to stderr.

### `tests/test_ledger.sh`
Same contract header and `ok`/`FAIL` style as `tests/test_chain.sh`. Point the ledger
into `mktemp -d` via `DELEGATE_LEDGER`; do not export `DELEGATE_STATE`. Cover at least:
`resolve_ledger` precedence (override > env > default, all three; resolution creates no
directory); unknown-kind row skipped by `show` but visible raw to `read_rows`; `schema`
above the registered value skipped; malformed and truncated-trailing lines skipped, the
next append well-formed; 8 processes × 2 rows concurrent appends all count with no torn
line; append survives `kill -INT` delivered mid-write (trap in a background child, the
pattern of `test_top.sh`); `derive_timeline` against a small fixture `events.jsonl` you
write in the test — step open/close with tokens and reason, a tool call with status and
times, a `text` event and a `tool_use` with input/output present in the fixture and
asserted ABSENT from the result, and one never-closed step closing at the last timestamp
with null reason; totals sum correctly.

## Report
Write your diff; then answer, in order: (1) for every `grep -n '^function ' bin/delegate`
function your diff touches — did you change it? (2) for the ones you did not change — did
you copy its contract exactly? (3) is any new code path unexercised by
`tests/test_ledger.sh`?

## Boundaries
- Nothing reaches a repository: no `git` call in `lib/ledger.py`; the `ledger` case calls
  none (R2). The default path is outside the task dirs; the isolation itself is T3's
  test.
- No tool input/output/text in `derive_timeline`'s result — R4 is the point of the field.
- Don't add features: no rotate, export, delete, edit; `append` and `show` only.

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check will blame your untracked
deliverables ("stray untracked files") — that check only passes once the files are
committed, which the harness does at round end, before the chain's verify runs
(bin/delegate `finalize_round`: commit ~730, verify ~743). Run the full gate; if that
one check is the only failure, it is this known interaction — report it, don't edit
the test.

```bash
set -o pipefail && bash -n bin/delegate && python3 -m py_compile lib/*.py && [ -f tests/test_ledger.sh ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && ! git diff --name-only bench | grep -qvE '^docs/specs/(t-brief|t-design|t-chain\.json|t-1-ledger-core\.md)$|^bin/delegate$|^lib/ledger\.py$|^config\.example\.env$|^docs/reference\.md$|^tests/test_ledger\.sh$' && echo GATE-OK
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
