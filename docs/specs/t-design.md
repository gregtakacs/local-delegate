# T design: telemetry ledger (rulings R2–R8)

Slice T of `docs/specs/bench-rulings.md`. This file is the design; `t-<n>-*.md` are the
implementation steps; `t-chain.json` is the chain plan. No product code is written by this
task — every claim below names the file and line it was read from.

## Goal

A durable ledger of one summary row per round plus a compact timeline and review rows,
and one command that prints per-project totals from them. R1 states the purpose this
serves: benchmark models, and keep per-project effort and time stats from everyday
delegate work — a summary is enough, the full delegation record is not. Today the facts
live only as `$DELEGATE_STATE/<task-id>/rounds/<n>/report.json` and `events.jsonl` (the
raw log is pruned after 14 days, R2), which `delegate prune`/`delegate rm`
(bin/delegate `cmd_prune` ~1052, `cmd_rm` ~1295) delete.

## Ruling map

| ruling | what it says (R9–R17 belong to slice B) | this design | step |
|---|---|---|---|
| R2 | durable ledger outside every repo and outside the task records; `prune`/`rm`/`chain --clean` never touch it; nothing committed to a repo; raw `events.jsonl` keeps its 14-day prune and is **not copied** into the ledger | one append-only JSONL file; location a config setting; derived rows only, never the raw log | T1, T2 |
| R3 | one summary row per round, written by delegate when the round ends, the report the source; fields: task identity (repo, slice/chain, step, task id, round, spec hash, base ref and SHA, verify command), conditions (endpoint URL, model as served, effort as its own field, delegate version, hash of the worker rules, image stamp, runner, timeout, edit cap, other rounds running), outcome (harness status, worker status, verify exit, nudges, tool errors, todo completion, chain retries), cost and time (start, end, duration, steps, tool calls, input/output/reasoning/cache tokens, final context size) | the `kind:"round"` row, field by field below | T2 |
| R4 | a compact per-step timeline per round, derived from `events.jsonl` before it is pruned; per step start/end and tokens, per tool call name, success, start/end; no inputs/outputs/text; timestamps are the join key with the inference server's request logs | the `kind:"timeline"` row, stored in the ledger — a pointer to the raw log is not enough because that log is pruned | T1 (derive), T2 (write) |
| R5 | a review row per step when a slice lands, written by the orchestrator: accepted-as-is or fixed, bugs found by severity, lines changed by the reviewer; linked to round rows by task id | the `kind:"review"` row + a `delegate ledger review` command | T3 |
| R6 | per-project totals come from the rows — rounds, wall time, tokens, retries, review findings, by repo / slice / model / effort — shown by a `delegate` command | `delegate stats` | T4 |
| R7 | resolving a model name to the real model is out of scope; the endpoint, model name and timestamps are the join key to the server's own logs; for a frontier endpoint that pair is the claim | the row stores the endpoint URL **as configured, in full** (R3's conditions list); model-name resolution is nowhere attempted; keys and key files are never recorded | T2 |
| R8 | existing task records can be imported once, while they still exist | `delegate ledger import` over the state dirs, through the same code path as a live round, marked `source:"import"`, deduplicated by task id + round | T3 |

## Location and format

- **File**: one append-only JSONL file, default `<state>/ledger/events.jsonl`, `<state>`
  = `DELEGATE_STATE` (default `$XDG_STATE_HOME/delegate`, cf. lib/chain.py's default
  state dir). It sits **beside** the task dirs, never inside one, so the task-dir-scoped
  `prune`/`rm` cannot reach it; a config key `LEDGER` overrides the path (`cfg()`
  layering: environment wins over the config file, bin/delegate ~100). Documented in
  `config.example.env` (T1).
- **Quarantine**: the worker never writes the ledger and never mounts it — every write
  happens host-side (`finalize_round`, the `ledger` command, `stats`). Nothing in the
  ledger is ever committed to a repo (R2): no `git` call touches the ledger path, and the
  round commit (bin/delegate ~730) runs in the task's worktree, which cannot contain it.
  `delegate chain --clean` (lib/chain.py) removes chain state and task dirs, not the
  ledger — T3's tests assert isolation both at the default path and with `LEDGER`
  pointed inside `$DELEGATE_STATE` beside the task dirs.
- **Concurrency**: appends take an exclusive `flock` on a sidecar `<file>.lock`, write one
  `\n`-terminated compact JSON line, flush + fsync, release. Readers take no lock and
  never see a partial line (one line is one buffered write); a reader skips lines it
  cannot parse, and skips kinds it does not know, counting them onto one warning line
  rather than failing.
- **Failure mode**: every ledger call site in the lifecycle follows `fire_hook`
  (lib/chain.py — never fatal, one note line): a failed append prints one warning to
  stderr and changes nothing else — not the round's status, not its exit code.
- **Kinds and versions**: each row carries `kind` and `schema` (int, ≥ 1, the key's
  version in `lib/ledger.py`'s `KINDS`). T1 ships `round:1`, `timeline:1`, `review:1` and
  registers `benchmark`/`verdict` (slice B's; see §Slice B) so readers tolerate them
  before they exist. Later revisions: `round:2` adds the orchestrator fields; `timeline:2`
  (T3) adds `ctx` to each step and the `events` array; `round:3` (T2-F) adds `todos` and
  `worker_report`, and T2-F registers `chain:1` (one row per `delegate chain` run, written
  by lib/chain.py). Readers accept any schema of a
  known kind at or below the registered version, so v1 timeline rows still import, still
  show, and simply have no positions. Fields a source cannot give stay empty — never
  guessed.
- **Forward compatibility**: a row whose `kind` the reader doesn't list, or whose
  `schema` is above the known version for that kind, is skipped and counted (the import
  runs against records of every vintage; slice B will add kinds to the same file).

## Row schemas

Compact JSON: `kind` and `schema` are the first keys written, so a reader can filter on
them before parsing a whole line. `ts` is ISO-8601 UTC at append time. Field order below
is the order `lib/ledger.py` writes for the kind.

### `kind: "round"` — written by delegate when the round ends (R3, R7)

| field | source (code read this round) |
|---|---|
| `task_id`, `slug`, `repo` | `meta.env` `ID`/`SLUG`/`REPO` (written bin/delegate ~921) |
| `project` | the main checkout: `meta.env` `GIT_COMMON` minus `/.git` (falls back to `repo`); `stats` groups the repo axis by it, so a chain run from a linked worktree joins its project (added in review) |
| `chain`, `step` | `meta.env` `CHAIN` (empty for single tasks); `step` = `SLUG` — under a chain the slug is the step name (`lib/chain.py` names tasks `delegate/<chain>/<step>`) |
| `run_id` | the task id (`meta.env` `ID`). `chain` and `step` already group a chain's rows; slice B gives its benchmark runs their own ids |
| `round` | `report.json` `round` (lib/report.py) |
| `spec_hash` | sha256 of `$TASK_DIR/spec.md` — the spec copy `cmd_run` stores (bin/delegate ~919) |
| `base_ref`, `base_sha` | `meta.env` `BASE_REF`/`BASE_SHA` (~923) |
| `verify` | `meta.env` `VERIFY`; `verify_rc` from `report.json` `verify_rc` (null when no verify command) |
| `endpoint` | the base URL actually used, recorded in full — `BASE_URL` at append time (from `--base-url` / the `DELEGATE_BASE_URLS` rotation, `pick_base_url`). R7: this pair with model and timestamps is the join key; keys and key files are never recorded |
| `model` | `report.json` `model` — the name as served (an alias is fine to record, R3/R7) |
| `effort` | `hard`/`normal`, its own field (R3): new `meta.env` key `EFFORT` written from `--hard` at `cmd_run`/`cmd_continue`; absent key ⇒ `normal` (visible through `delegate top`/`list`, which read `meta.env` generically via lib/taskstate.py) |
| `effort_source` | `cli` for live rounds; `inferred` for imported rows (§Import) |
| `delegate_version` | `VERSION` in bin/delegate (~11) |
| `rules_hash` | sha256 over the worker rules the round used: the sorted contents of `$DELEGATE_RULES_DIR` (`rules/`, `plugins/`, `delegate-rules.md`) — the tree `run_worker_native` copies into the task HOME and `render-opencode-config.py` wires into the worker config (~79, ~524-533; docker mounts the same tree read-only, ~511). Same construction as `context_stamp()` (~1333) |
| `image_stamp` | `image_stamp` of the worker image (label `io.delegate.stamp`, ~1336); empty for the native runner |
| `runner` | `meta.env` `RUNNER` (~925) |
| `timeout_s` | `DELEGATE_TIMEOUT` in force at append (~70) |
| `edit_cap` | `DELEGATE_CHUNK_CAP` in force at append (~60) |
| `parallel_rounds` | count of *other* tasks holding a round lock at append time — sibling `lock/` dirs under `$DELEGATE_STATE` (the dirs lib/taskstate.py's running-state scan uses) |
| `status` | `report.json` `status`: one of `done`, `partial`, `blocked`, `no-status`, `worker-error`, `timeout`, `truncated`, `done-but-verify-failed` (lib/report.py 85–183) |
| `worker_status` | `report.json` `worker_status` (the worker's closing block; may be null, report.py ~163) |
| `exit` | `report.json` `exit` |
| `nudges` | `report.json` `nudges` |
| `tool_calls`, `tool_errors`, `errors` | `report.json` (lib/report.py `summarize`) |
| `todos_done`, `todos_total` | from `report.json` `todos` (~137): entries with `status == "completed"` / all entries (~219 counts open ones the same way); empty when no list |
| `todos` | T2-F, round:3 — the round's final todo write as `[{"text", "status"}]` (`report.json` `todo_items`; item `content` becomes `text`), at most 50 items, each text cut to 200 characters; null when the round made no todo write |
| `worker_report` | T2-F, round:3 — the worker's §13 closing block parsed by `lib/report.py`: `{status, not_verified, deviations, decisions, omissions, suggestions, questions}`, at most 20 items per list, each cut to 300 characters, `none` read as empty; `FILES`, `VERIFIED` and `EVIDENCE` are never kept (paths and command lines); null when the final message has no `STATUS:` line |
| `retries` | this round's retry count = `round - 1` (round dirs are 1-based); stats-level retries are derived from the rows, never from chain state, which `--clean` removes (§Stats) |
| `round_start`, `round_end` | `finalize_round`'s `start`/`end` epoch-seconds arguments (~715) |
| `duration_s` | `report.json` `duration_s` |
| `steps` | `report.json` `steps` |
| `input_tokens`, `output_tokens`, `reasoning_tokens` | summed by the timeline derivation (§Timeline) over `step_finish` `part.tokens`; `report.json` carries `output_tokens`/`reasoning_tokens` (the input sum is what report.py only keeps per last step) |
| `cache_read`, `cache_write` | sum of `step_finish` `part.tokens.cache.read`/`.write` over the round (§Timeline) |
| `final_context_tokens` | `report.json` `final_context_tokens` (last step's input + cache read, report.py ~116) |
| `diff_lines` | added+deleted lines from `$rd/diffstat`, the `git diff --stat` file `finalize_round` writes (~750) — parsed, not re-derived |
| `source` | empty for live rounds; `import` for imported rows (§Import) |
| `ts` | append time |

No tool inputs, outputs, prompts, text parts or reasoning text in any field (R4); no
keys (R7's claim needs only endpoint, model and timestamps).

### `kind: "timeline"` — the compact per-step timeline, one row per round (R4)

`events.jsonl` is pruned after 14 days (R2), so the timeline must live in the ledger
itself; a pointer at the raw log is rejected. Written beside the round row, same
transaction of the lock (T2). Schema 2 (T3); shape — one row per round holding arrays:

| field | contents |
|---|---|
| `task_id`, `run_id`, `round` | identity, same values as the round row (the join key) |
| `steps` | array, in file order: `{"start": <ms>, "end": <ms>, "input": n, "output": n, "reasoning": n, "cache_read": n, "cache_write": n, "reason": <finish reason>, "ctx": n}` — `ctx` is the step's context size, `input + cache_read + cache_write`; `null` while the step never closed |
| `tools` | array, in file order: `{"tool": <name>, "status": <state.status>, "start": <ms>, "end": <ms>}` |
| `events` | array, step order: the round's reliability records — `{"kind": K, "step": N, "ctx": T}` for every nudge, tool error and verify-fail; kinds `nudge:malformed`, `nudge:api-error`, `nudge:no-status`, `tool-error:invalid-args`, `tool-error`, `verify-fail`; nothing else (no message, no tool text — R4) |
| `source` | empty, or `import` |
| `ts` | append time |

Derivation (`lib/ledger.py derive_timeline(events_path)`, T1; used by T2 live, by T3 on
import — one code path, R8): parse `events.jsonl`; a model step opens at its
`step_start` `timestamp` and closes at the matching `step_finish` (`part.tokens` input,
output, reasoning, cache.read, cache.write; `part.reason`); each `tool_use` contributes
`part.tool`, `part.state.status`, `part.state.time.start`/`.end`. **Nothing else from an
event is read**: no `part.state.input`/`output`, no `title`, no `metadata`, no `text`
events. Timestamps are the events' own millisecond values — they are the join key with
the inference server's request logs (R4/R7). A step whose `step_finish` never came (killed
mid-step) closes with the last event's timestamp and `reason: null`; tokens are partial —
the same rule live and on import, so no timeline row silently differs by provenance.

The `events` array (T3) merges three sources in one place, `ledger.timeline_events`,
called by `append_round_and_timeline` so live and import share it (R8). The walk
contributes one record per failed tool call — an error line seen again for the same call
id replaces the earlier record, and an id that later completes drops its open error (a
retried-and-fixed call interrupted nothing); the error text is read only to decide the
kind: a message starting `The arguments provided to the tool are invalid` is recorded as
`tool-error:invalid-args`, anything else as plain `tool-error`. An error inside a step
that later closes carries that step's `ctx`; one in a step that never closes carries a
null `ctx` (the `unknown` bucket). The harness's own interruptions land here too: the
round's `stderr.log` may hold lines the runner echoed as `nudge: <kind> step=<N> ctx=<T>`
(the pair comes from `lib/report.py position EVENTS`, which answers `<N> <T>`: step_finish
count and last closed step's context). A line without the pair — the format rounds wrote
before positions existed — still counts, recorded with `step` and `ctx` null, joining the
`unknown` bucket: a position nobody recorded is never invented. And a round whose
`verify_rc` is non-zero contributes one `verify-fail` event at the round's final position:
the last closed step, else `report.json`'s `steps`/`final_context_tokens`, else `0 0`.

One row per round (not one per step): the row is atomic per round — the same round that
writes the round row writes one timeline row, no interleaving across rounds. `stats`
(T3) parses them by kind before anything else and keeps only the identity, the per-step
`ctx` counts and the events' kinds, steps and sizes; no text from a row can reach a
table. The arrays stay bounded by the round's own step/tool/event counts (report
counters reach several hundred steps and tool calls in a long round, so a timeline row
can be ~100 KB).

### `kind: "review"` — the orchestrator's verdict, per step (R5)

`delegate ledger review TASK_ID [--round N] --verdict accepted|fixed|rejected
--bugs high=N,medium=N,low=N --lines-changed N [--note TEXT]` — one row per call.
R5 records what the orchestrator decided, so the command takes it as flags; no parsing of
review documents, no verdict inferred from anything.

| field | source |
|---|---|
| `kind`, `schema` | `review`, `1` |
| `task_id` | argument; the link to round rows (R5) |
| `round` | `--round`, else the task's highest round row already in the ledger |
| `verdict` | `accepted` (as-is) / `fixed` (accepted after reviewer changes) / `rejected`; R5 names the first two, and `rejected` is the case a round whose `status` is `blocked` ends in — a verdict value is needed for it even though the ledger never reads statuses to infer one |
| `bugs_high`, `bugs_medium`, `bugs_low` | `--bugs high=2,medium=1` — bugs found by severity; absent ⇒ 0 |
| `lines_changed` | `--lines-changed N` — changed by the reviewer |
| `note` | `--note TEXT`, free text the orchestrator typed; empty unless given |
| `ts` | append time |

### `kind: "chain"` — one row per `delegate chain` run, written when the run stops (T2-F)

Task records get pruned; chain state gets `--clean`ed; this row is what a later reader has
of a finished slice: how it ended, on which step, with what exit code. Steps, statuses and
counts only — no step text, no commands, no diffs (R4). Written once per run by
`lib/chain.py` when `run(plan)` stops for any reason, SIGINT/SIGTERM included (the handler
writes the row, restores the default disposition and re-raises, so the run still dies by
the signal); `--status`, `--wait` and `--clean` write none. Writing it follows `fire_hook`:
one warning line on failure, never an outcome or exit-code change.

| field | source |
|---|---|
| `kind`, `schema` | `chain`, `1` |
| `chain` | the plan's `name` |
| `repo` | the plan's repo, absolute (as `load_plan` resolves it) |
| `project` | `project_of` over the repo's git common dir — the main checkout for a linked worktree (same rule as the round row) |
| `plan_hash` | sha256 (hex) of the plan file's bytes: the exact plan this run executed |
| `started_at`, `ended_at` | the run's clock, ISO-8601 UTC seconds |
| `outcome` | `done` when every step is done; else the first step that is not done (`blocked`, `partial`, `failed` for anything else); `interrupted` when a signal stopped the run |
| `exit` | the run's exit code (`0`, `2`, `3`, or `128 + signum` after a caught signal) |
| `steps` | one entry per plan step, in plan order: `{step, task_id, status, rounds, retries, hard}` — `status` as `status(plan)` reports it; a step that never ran has null counts, not zero |
| `orchestrator`, `orchestrator_session` | the environment the chain runs in, same source and token rule as `meta.env`'s `ORCH`/`ORCH_SESSION`; null when unknown |
| `ts` | append time |

## Write points

| moment | code | writer |
|---|---|---|
| round ends | `finalize_round` (bin/delegate: after `lib/report.py report` writes `$rd/report.json`, before the wake hook ~765) appends the `round` row then the `timeline` row | host |
| effort recorded | `cmd_run`/`cmd_continue` meta.env write block (~921): `EFFORT` | host |
| review lands | `delegate ledger review ...` | orchestrator |
| chain run ends | `lib/chain.py` appends the `chain` row (T2-F): in `main()`'s finally, and from the SIGINT/SIGTERM handler before re-raising | host |
| import, once | `delegate ledger import` (§Import) | host |

`fire_hook` (lib/chain.py) stays the failure pattern for every one of them: one warning
line, never an exit-code change. The round commit at ~730 happens inside the task's
worktree — the ledger path is not in any worktree, so R2's "nothing committed" holds by
construction, asserted by T2's tests.

## Import (R8)

`delegate ledger import` walks the state dirs the way lib/taskstate.py does
(directories under `$DELEGATE_STATE` containing `meta.env`, ~353) and, for every round
dir holding a `report.json`, rebuilds that round's `round` row **and** `timeline` row
through the same code paths a live round uses (`derive_timeline` over the round's
`events.jsonl`; the row builder fed from `report.json` + `meta.env` + the files on
disk), marked `source:"import"`. Idempotent: a `(task_id, round)` with an existing
`round`-kind row (any source) is skipped and counted on the summary line — importing
twice adds nothing.

Field recovery, exact: `spec_hash` from the dir's `spec.md`; `base_ref`/`base_sha`/
`verify`/`runner` from `meta.env`; `endpoint` empty (the URL used was never recorded —
R7: an unrecorded endpoint stays empty, never guessed); `model` from `report.json`;
`delegate_version`/`rules_hash`/`image_stamp`/`timeout_s`/`edit_cap` empty (per-round
values no longer recoverable); `parallel_rounds` empty; `round_start` = the first timeline step's start (ms → s); `round_end`
from the report file's own modification time (the report's write instant, after the round);
`endpoint` for an imported row is empty for the same reason; token fields from the
timeline derivation over the events file; `diff_lines` from `$rd/diffstat` when present;
`status`/`worker_status`/`exit`/`verify_rc`/`nudges`/counters/`final_context_tokens` from
`report.json`; `retries` = `round - 1` as live.

Effort for an imported round is inferred: `hard` when the round's `model` equals the
configured hard model (`DELEGATE_MODEL_HARD`) and that differs from the configured
`DELEGATE_MODEL`, else `normal` — with `effort_source: "inferred"` on the row so the
provenance travels with the value. Live rounds carry `effort_source: "cli"`.

## Stats (R6)

`delegate stats [--chain NAME] [--since YYYY-MM-DD] [--repo R] [--kind K] [--json]`
reads `round` and `review` rows, and joins `timeline` rows to the group of their
`(task_id, round)` for the reliability figures below — every other known kind is
filtered out at the line level before parsing — and prints, per project grouped by
**repo / chain (slice) / model / effort** (R6's four axes): rounds, accepted-or-fixed
rate, total and mean wall time, input/output/reasoning/cache tokens, retries, and the
review findings joined by task id (verdict counts, bugs by severity, reviewer lines
changed). One failures table: `tool_errors`, `errors`, and status counts over the same
groups, plus `verify-fail=N` when the group has rounds whose `verify_rc` is non-zero. Retries are derived from
the rows themselves — `sum(max(round) − 1)` per task — not from chain state, which
`chain --clean` removes; that is why the round row carries `round` at all. Import-sourced
rows are labelled in the totals (their verdict counts come from statuses, since no review
rows exist for them). `--json` prints the same facts as one object. An empty or unreadable
ledger prints empty tables and exits 0; unknown-kind and malformed lines are skipped and
counted on one warning line. No prices, no dollars: R6 asks for counts.

One more table (T3), `reliability (per 100 model requests)`: each group's timeline rows
say how many model requests its rounds made (one per recorded step) and what
interrupted them. Per group and in a `(total)` line: `requests`, each event kind's
`rates_per_100_requests` (`round(100 × count / requests, 2)`; `verify-fail` is excluded —
it ends a round, not a request), and `verify-fail/100rds`
(`verify_fail_per_100_rounds`): the rounds whose round row has a non-zero `verify_rc`, over
the group's round count. It is counted off the round rows, not the timeline events, so rounds
recorded before timeline schema 2 count too; the `verify-fail` event only places a failure
in its context bucket. `null`/`-` when the group
saw no requests at all, `-` when it saw rounds and no timeline row (nothing known,
not a claim of clean). The same rates broken down by the context size the event landed
at — `0-32k`, `32-64k`, `64-128k`, `128-256k`, `256-512k`, `512k+`, and `unknown` for
unclosed steps and v1 rows — appear per bucket in `--json` as `by_context`. A v1
timeline row has no positions: its steps count as requests in `unknown`, and it holds
no events.

## Slice B (not this slice's code)

The reservation mechanism is T1's `KINDS` registry: slice B will add `benchmark` and
`verdict` rows to the same file, and T1 already registers both so readers of today's
build skip them cleanly. B defines their fields itself, under R9–R17; this design defines
nothing for them beyond the names.

## Chain plan

Four steps (`t-1`…`t-4`), each verify = the repo's full gate plus the step's own new tests
plus the scope check, per the brief. Round ordering the specs rely on: `finalize_round`
commits the worker's work first (`wgit add -A` + round commit, bin/delegate ~730) and
runs the verify command only after (~743) — at chain-verify time the tree is clean and
`tests/test_e2e_harness.sh`'s hygiene check passes; a worker running the full gate
*mid-round* sees that one check blame its own untracked files, which each step spec names
as a known interaction (report it; never edit the test). The canonical full-gate line
the step specs and `t-chain.json` share, byte for byte:

```bash
G=/tmp/delegate-t-gate.log; set -o pipefail
{ bash -n bin/delegate && python3 -m py_compile lib/*.py; } &&
  for f in tests/test_*.sh; do echo "GATE $f"; env -u DELEGATE_EVIDENCE_DIR bash "$f"; done >"$G" 2>&1; gate=$?
```

(`set -o pipefail` belongs to the pattern: the scope check pipes `grep -qvE`, and without
pipefail a `git diff` that dies — bad ref, unlocked index — leaves grep at EOF, "no
offending line", and the step passes on the gate's corpse.) The scope pattern is o1b's:
`! git diff --name-only <ref> | grep -qvE '<allowed>'`; the first ref is `bench` (the
chain base), later refs the previous step's branch and the step's own.

## Decisions taken here (the calls the brief left open)

1. **Default ledger path**: `$DELEGATE_STATE/ledger/events.jsonl` — beside the task dirs,
   so the brief's "outside every task directory" holds while `prune`/`rm` stay unaware of
   it; config key `LEDGER` overrides. Isolation is test-enforced in T3.
2. **Timeline rows**: `kind:"timeline"`, one row per round holding the arrays (§Timeline);
   same file, because append + lock + ordering stay one story; `stats` drops other
   known kinds by `kind` before parsing, and reads timeline rows only for the
   reliability figures (T3).
3. **Effort**: new `meta.env` key `EFFORT` from `--hard` — the only R3 field not derivable
   from files that exist today, hence an explicit T2 change; on import it is *inferred*
   and labelled `effort_source:"inferred"` (§Import).
4. **Retries**: stored per row as `round - 1`; group totals derived on read as
   `sum(max(round) − 1)` — chain state is `--clean`-able, the ledger is not (R2).
5. **Import dedupe**: `(task_id, round)` checked against existing `round`-kind rows, any
   source.
6. **One file**: single append-only stream for all kinds; rotation out of scope (R2 names
   no rotation).

## Owner questions

1. **A verdict value for the not-accepted case.** R5 names `accepted` and `fixed`; a step
   a slice ends up dropping needs a third. Option A: keep it out of the schema and mark
   such tasks only in the task record; Option B: add `rejected`. **Picked B** —
   `delegate chain` abandons exist, and a missing enum value would force a row shape the
   reader must special-case. Changing B to A later is one constant and never breaks
   readers (unknown rows would only be historical).
2. **Timeline rows in the same file.** Option A: one file for all kinds; Option B:
   `timeline.jsonl` beside the events file so the stats reader's stream stays small.
   **Picked A** — one lock, one append order, one file to back up; `stats` drops the
   kinds it does not read by `kind` before parsing, and reads only the timeline rows
   whose `(task_id, round)` match a kept round row. If stats ever reads slowly on a big
   ledger, B is a pure move (T1's `read_rows` takes the path; nothing else changes).
3. **The totals command's name.** Option A: `delegate stats`; Option B:
   `delegate ledger stats`. **Picked A** — R6 says "shown by a `delegate` command", the
   name is shorter, and `ledger` stays the write side.

## Orchestrator review (Phase 2)

- Owner questions 1–3: B (`rejected`), A (one file), A (`delegate stats`) accepted as picked.
- `run_id` is the task id; the timeline-size claim was corrected (long rounds reach several hundred steps).
- Every step verify was rebuilt: the earlier form printed the gate's failures and then exited on
  the scope check alone, so a step with failing tests passed. Now the first failing suite fails
  the step (proven on a scratch worktree: failing test rc=1, out-of-scope file rc=1, clean rc=0).

## Gate note

`tests/test_release_install.sh` passes on the current `bench` (0.4.2 fixed the version
pair; verified this round). The one known environment interaction: `tests/test_plugins.sh`
fails its "no notes file" check when `DELEGATE_EVIDENCE_DIR` is exported in the worker's
environment (it runs `delegate new` with the ambient env), so the full-gate loop runs
every suite under `env -u DELEGATE_EVIDENCE_DIR`. A worker may still hit the mid-round
litter check (§Chain plan). Neither is edited; both are reported as environmental.

## Acceptance (verify)

`python3 -c "import json,os;p=json.load(open('docs/specs/t-chain.json'));assert p['steps'];[open(s['spec'] if os.path.exists(s['spec']) else 'docs/specs/'+s['spec']) for s in p['steps']];assert os.path.getsize('docs/specs/t-design.md')>3000;print('ok',len(p['steps']),'steps')" && ! git diff --name-only bench | grep -qvE '^docs/specs/'`
