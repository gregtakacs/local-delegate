# Task B7: `delegate bench run` — sessions, fixtures, leak guard, runs, scoring, `benchmark` rows

`"hard": true` — this step turns plan and bundle data into `delegate` command lines and decides
what an agent's sandbox may contain (the hidden-check leak guard, the mount check): security
relevant. Slice B step 7 of 10 (`docs/specs/b-design.md` §Conditions and plans, §Scoring,
§Row schemas `benchmark`, R9–R12, R17).

## Goal

`delegate bench run PLAN` executes a plan: for every (repeat, case, condition) in the seeded
order it builds the fixture repo from the bundle, refuses to run if any hidden-check content
could reach the sandbox, runs the condition through `delegate run` (delegate mode or
`--agent`), scores it with `delegate score`, and appends one `benchmark` row to T's ledger. A
session is resumable; nothing is run twice for the same (case, condition, repeat).

## Read first

- `docs/specs/b-design.md` §Conditions and plans, §Scoring, §Row schemas (`benchmark`, field by
  field), §Trust and security summary, Decisions 2 and 4.
- `lib/bench.py` (B1: `load_plan`, `run_matrix`, `load_case`, `case_hash`, `benchmark_row`,
  `new_run_id`, `session_id`), `lib/ledger.py` (`append`, `read_rows`, the `round` row fields),
  `lib/agents.py` (`load_profile`, `version_checked`), `lib/endpoints.py` (resolve), `lib/grants.py`
  (`resolve` — to validate a condition's grants and read their mount/secret paths).
- `evals/run.sh` — fixture building today (setup.sh, `git init`, the eval commit identity) and
  the `rules_ref` archive trick; reuse both behaviours.
- `bin/delegate` `cmd_run` (task id = `<repo basename>-<name slug>`), meta.env format (`%q`),
  `cmd_score` (B6) and its `score.json`, `cmd_rm`.
- `tests/test_chain.sh` — the fake-`delegate` pattern (`DELEGATE_CHAIN_BIN`) to copy as
  `DELEGATE_BENCH_BIN`.

## Contract

### CLI

`delegate bench run PLAN [--session S] [--cases a,b] [--repeat N] [--keep] [--dry-run]`
(dispatched to `lib/bench.py run`). `--cases`/`--repeat` narrow/override the plan. `--session S`
resumes S (its saved plan is used; PLAN must have the same `name`). `--dry-run` prints the run
order and each run's `delegate` argv (as a JSON list per line) and runs nothing. `usage()` line.

### Session

- New session: `session_id(plan name)`; dir `$DELEGATE_STATE/bench/<session>/` (mode 700) with
  `plan.json` = the normalized plan + `seed` + `case_hashes` (`{case: hash}` at start) +
  `delegate_version`.
- Before the first run: every condition's `agent` loads (`kind` checked against `mode`:
  own-harness needs `kind = "command"`), every `endpoint` resolves, every condition's `grants`
  resolve via `grants.resolve(gdir, names, [], runner="docker")`; any failure → error, nothing run.
- **Mount check**: for every grant of every condition, no `ro`/`rw` mount and no secret path may be
  equal to, inside, or a parent of the bundle roots (`evals/cases`, `evals/review-cases`, their
  realpaths) → error `grant G mounts P, which contains benchmark bundles (R12)`.
- Resume: rows already in the ledger with `kind == "benchmark"` and this `session` mark their
  `(case, condition, repeat)` done; those are skipped.
- Before each run the case's `case_hash` is recomputed; a mismatch with `plan.json` stops the
  session with `bundle C changed during session S; start a new session` (results of two bundle
  versions are never pooled).

### One run

1. `run_id = new_run_id()`; run dir `runs/<run_id>/`; `meta.json` there = `{run_id, case,
   condition, repeat}` (mode 600).
2. Fixture: `runs/<run_id>/<case>/` created; `bash <case>/setup.sh <repo> <case dir>` with cwd the
   run dir, a 600 s timeout, output to `setup.log`; then `git init -q -b main` (tolerate an
   existing repo), `git add -A`, `git -c user.name=eval -c user.email=eval@localhost commit -qm
   "fixture: <case>"`. Any failure → a `benchmark` row with `status: "setup-failed"` (R17: rebuilt
   or retired, not rescued) and the next run.
3. **Leak guard**: sha256 of every regular file ≥ 32 bytes under the case's `hidden/`; if any
   regular file in the fixture tree (excluding `.git`) has one of those hashes → row `status:
   "leak-refused"` naming nothing more, no task started. (Small files are skipped: an empty
   `__init__.py` must not trip it.)
4. Rules: a delegate-mode `rules_ref` → `git -C $DELEGATE_HOME archive <ref> opencode` extracted
   once per distinct resolved SHA into `<session>/rules/<sha>/`, passed as `DELEGATE_RULES_DIR`.
   The ref is passed after `--` style safety: validate with `git rev-parse --verify --quiet
   "<ref>^{commit}"` first (the B1 regex already forbids a leading `-`).
5. Run (argv list, `subprocess.run`, never a shell; `DELEGATE_BENCH_BIN` overrides
   `$DELEGATE_HOME/bin/delegate` for tests):
   `run <case>/spec.md --repo <repo> --name <run_id> --timeout <TIMEOUT> [--verify <VERIFY>]
   [--service postgres]` plus, delegate mode: `[--endpoint E] [--model M] [--effort X]`;
   own-harness: `--agent A [--model M] [--effort X] [--endpoint E] [--grant G]...`.
   Environment: inherited, plus `DELEGATE_FILE_TIMELINE=1`, `DELEGATE_READ_PATHS=` (empty: no
   configured reference mounts in a benchmark), `DELEGATE_PROGRESS` as inherited, and
   `DELEGATE_RULES_DIR` when step 4 applies. Output to `runs/<run_id>/run.log`.
6. Task id = `<case>-<run_id>` (check against `cmd_run`'s slug rule); its `meta.env` must exist,
   else row `status: "run-failed"`.
7. Score: `score <task id> --hidden <case>/hidden --out runs/<run_id>/score` (B6). A non-zero exit
   → the row still gets written with the hidden/verify fields empty and `status` from the report.
8. Row (`benchmark_row`): identity from the session/run; condition fields from the plan;
   `endpoint` = meta.env `BASE_URL` in full; `model` = requested model, `model_reported` =
   `report.json` `model_reported` (own-harness) or `model` (delegate); `agent_version` /
   `version_checked` from `report.json` (delegate mode: `agent_version` empty); `image` = the
   image used (`AGENT_IMAGE` or the configured worker image), `image_stamp` from the T round row
   when present; `task_id`; `status`, `exit`, `timed_out` (status `timeout`), `timeout_s`;
   hidden/verify fields from `score.json` (`hidden_all` = `hidden_total > 0 and hidden_fail == 0
   and hidden_rc == 0`); `start`/`end`/`duration_s` from the T round row (or report); counters
   and tokens: own-harness from `report.json` (`tokens_source: "harness"`) falling back to
   `report.json.llm` (`"proxy"`) when the harness gave none; delegate mode from T's `round` row
   for this task (input/output/reasoning/cache) with `"harness"`; `llm_*` from `report.json.llm`;
   file-timeline fields from `report.json.files`; `diff_added/diff_deleted/diff_files` from
   `git --git-dir=<GIT_COMMON> diff --numstat <BASE_SHA> <round commit> -- . ':!package-lock.json'`
   (host-side, read-only object access; binary files count 0); `nudges` from `report.json`;
   `telemetry` = the sources that yielded data. Append with `ledger.append`. A ledger failure →
   one `warn:` line, the session continues.
9. Unless `--keep`: `rm <task id> --delete-branch` (the `score/final/` copy and the fixture repo
   stay in the session dir: review needs them).
10. One progress line per run to stderr: `bench: [k/N] <case> <condition> #<repeat> -> <status>, hidden P/T, <duration>s`.
11. End: `bench: session S: N runs, M skipped (done before), K failed to set up` and exit 0; exit 2
    for plan/validation errors; Ctrl-C stops after killing the child by PID (no row for the
    interrupted run; resume reruns it).

### `tests/test_bench_run.sh` — create

Offline. Temp `DELEGATE_STATE`, `DELEGATE_LEDGER`, `DELEGATE_BENCH_CASES` (two tiny cases written
by the test: one `setup.sh` that writes a file, one that exits 1), a temp grants dir and agents
dir, and a fake `delegate` (`DELEGATE_BENCH_BIN`) that records its argv and environment, and
plays `run` (creates `$DELEGATE_STATE/<id>/meta.env` with `%q` values, a worktree with a change
committed on top of the fixture, `rounds/1/report.json` with `files`/`llm` sections), `score`
(writes `score.json` and `final/`), `rm`. At least:
1. Two conditions (delegate with endpoint/model/effort; own-harness with agent/model/grant) ×
   one good case × repeat 2 → 4 rows, each with every `BENCHMARK_FIELDS` key, the right `mode`,
   `endpoint`, `model`, `hidden_all`, diff numbers, telemetry list; the recorded argv lists match
   the contract exactly, and each env had `DELEGATE_FILE_TIMELINE=1` and empty
   `DELEGATE_READ_PATHS`.
2. The failing-setup case → `setup-failed` rows, no `run` call for it.
3. Resume: rerun with `--session S` → 0 new `run` calls; delete one row's worth (fresh ledger with
   3 of the 4 rows) → exactly 1 new run.
4. Leak guard: a case whose `setup.sh` copies `hidden/check.mjs` (≥ 32 bytes) into the fixture →
   `leak-refused`, no `run` call.
5. A grant with `mounts.ro` = the cases root → refused before any run; a secret path inside it →
   refused.
6. A changed `hidden/check.sh` between two runs of one session → the session stops with the
   bundle-changed message.
7. `rules_ref: "HEAD"` → the fake saw `DELEGATE_RULES_DIR` pointing at an extracted `opencode/`
   tree; `rules_ref: "nonexistent-ref"` → validation error, nothing run.
8. `--dry-run` prints N argv lines and runs nothing; plan model `$(id)` → exit 2.
9. Values with spaces or `;` in VERIFY reach the fake as one argv element, unchanged.

## Out of scope

- Review (B9), report (B10), `evals/run.sh` (B10). No change to `bin/delegate` beyond the `bench
  run` usage line and dispatch (if B1's dispatch already forwards, no change at all); no change to
  `lib/grants.py`, `lib/agents.py`, `lib/endpoints.py` (import only) or existing tests.

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check blames untracked deliverables; the harness
commits before the chain's verify runs. If that is the only failure mid-round, report it; never
edit that test.

```bash
set -o pipefail && bash -n bin/delegate && python3 -m py_compile lib/*.py && [ -f tests/test_bench_run.sh ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && ! git diff --name-only delegate/b-6-score | grep -qvE '^docs/specs/b-|^bin/delegate$|^lib/bench\.py$|^tests/test_bench_run\.sh$' && echo GATE-OK
```

## Report format

```text
STATUS: done|partial|blocked
SUMMARY: <=3 sentences
TESTS: <counts; which suites ran; gate result>
RISKS: <what might still be wrong>
DEVIATIONS: <departures from this spec and why, or none>
```
