# Task B1: lib/bench.py core — bundles, plans, ids, row builders, stats, legacy import

`"hard": false`. Slice B step 1 of 10, chain segment 1 (`docs/specs/b-design.md`). Base: `bench` with slice T
landed (`lib/ledger.py`, `delegate ledger`, `delegate stats` exist).

## Goal

Create the pure-Python core every later B step uses: read a benchmark bundle without executing
it, identify it by content hash, load and validate a bench plan into a run matrix, mint run and
subject ids, build `benchmark`/`verdict`/`match` rows in the design's field order, compute
median/spread, and import the old `evals/results/*.jsonl` rows into the ledger. Expose two
commands: `delegate bench check PLAN` and `delegate bench import-legacy FILE...`.

## Read first

- `docs/specs/b-design.md` — §Bundles, §Conditions and plans, §Row schemas (all three kinds and
  §Legacy rows), §Report (only for what the stats helpers must support).
- `lib/ledger.py` — `KINDS`, `append`, `read_rows`, `resolve_ledger` (T1). Use them; never write
  the ledger file yourself.
- `bin/delegate` — the `ledger` and `stats` cases in `main()` (how a subcommand dispatches to a
  Python lib), `usage()`.
- `evals/run.sh` — what a case is today; `evals/cases/*/case.env` (the real files your parser must
  accept); `evals/results/*.jsonl` and their `.md` siblings (the legacy input).
- `tests/test_ledger.sh` (T1) — house style for a Python-lib test suite (`ok`/`FAIL` lines,
  `mktemp -d`, `DELEGATE_LEDGER` pointed into the temp dir).

## Contract

### `lib/bench.py` — Python 3.10+ stdlib only; importable (no work at import time); a CLI under `if __name__ == "__main__"`

Library functions (exact names; later steps import them):

- `class BenchError(Exception)` — every validation failure raises it with a one-line message
  naming the file and the field.
- `parse_case_env(path) -> dict` — lines `KEY=VALUE`; blank lines and lines starting with `#`
  skipped; `VALUE` through `shlex.split(value, comments=False, posix=True)` must give exactly one
  token (else `BenchError`); allowed keys `VERIFY`, `SERVICE`, `TIMEOUT`, `KIND`; unknown key →
  `BenchError`. Defaults: `VERIFY=""`, `SERVICE=""`, `TIMEOUT=3600`, `KIND="work"`. `TIMEOUT` an
  int 60..86400; `SERVICE` in `("", "postgres")`; `KIND` in `("work", "review")`. Never executes
  anything (no `bash`, no `source`).
- `case_hash(case_dir) -> str` — sha256 hex over the case dir: for every regular file in sorted
  relative-path order (POSIX separators), feed `relpath.encode() + b"\0" + sha256(content).hexdigest().encode() + b"\n"`.
  A symlink anywhere in the dir → `BenchError`. Directories named `__pycache__` are skipped.
- `load_case(case_dir) -> dict` — `{"name", "dir", "kind", "verify", "service", "timeout",
  "hash", "spec", "hidden"}` (`spec`/`hidden` are paths). Work case requires `spec.md`, `setup.sh`,
  `hidden/check.sh`. Review case (`KIND=review`) additionally requires `change/` (dir) and
  `truth.json` validated by `load_truth`.
- `load_truth(path) -> dict` — `{"verdict": "accept"|"reject", "defects": [{"id", "file",
  "start", "end", "severity", "what"}]}`; ids unique `[a-z0-9-]{1,16}`; `file` relative, no `..`,
  not absolute; `1 <= start <= end`; severity in `high|medium|low`; `accept` ⇔ `defects == []`.
  Each defect may also carry `fix` (a list of strings: the replacement for lines `start..end`,
  used only by B8's tests to prove the defect sits on those lines); any other key → `BenchError`.
- `list_cases(root, kind) -> list[str]` — sorted case names under `root` (`evals/cases` or
  `evals/review-cases`) whose `case.env` has that `KIND` (a dir without `case.env` is skipped).
- `load_plan(path, cases_root, review_root) -> dict` — validates the plan of design §Conditions
  and plans: top keys `name` (`[a-z0-9][a-z0-9._-]{0,47}`), `cases` (list or `"all"`), `repeat`
  (int 1..50, default 3), `seed` (int, default 0), `conditions` (non-empty list), `reviewers`
  (list, default `[]`), `review_cases` (list or `"all"`, default `[]`), `review_timeout` (int
  60..86400, default 1800). Each condition/reviewer: `label` per the design regex, unique within
  its list; `mode` `delegate` | `own-harness`; delegate mode allows only `label, mode, model,
  effort, rules_ref`; own-harness allows only `label, mode, agent, model, effort` and requires
  `agent` (R14 amended, R18: a plan carries no endpoint, key, grant or path). Values: `agent`
  matches `[a-z0-9][a-z0-9._-]{0,47}`; `model` and `effort` match `^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$`
  (or are absent/empty); `rules_ref` matches `^[A-Za-z0-9._/~^@{}-]{1,64}$` and does not start
  with `-`. Unknown keys anywhere → `BenchError`. Case names resolved (`"all"` → `list_cases`),
  each must exist and be of the right kind. Profile names are only shape-checked here (B3 resolves them;
  B7 checks delegate-mode models against `delegate models`). Returns the normalized plan dict (defaults filled).
- `run_matrix(plan) -> list[dict]` — `[{"repeat", "case", "condition"}]`: for repeat 1..N the
  case × condition pairs (case order then condition order) shuffled by
  `random.Random(f"{plan['seed']}:{repeat}")`; deterministic for a given plan.
- `new_run_id()` → `"b-" + secrets.token_hex(6)`; `new_subject_id()` → `"s-" + secrets.token_hex(5)`;
  `new_review_id()` → `"v-" + secrets.token_hex(6)`; `session_id(plan_name, now=None)` →
  `f"{plan_name}-{YYYYmmdd-HHMMSS}"` (UTC).
- `benchmark_row(**fields) -> dict`, `verdict_row(**fields) -> dict`, `match_row(**fields) -> dict` —
  return a dict with `kind`, `schema` (from `ledger.KINDS`) first, then **every** field of the
  design's list in the design's order (absent ones as `None`, `telemetry`/`findings` as `[]`,
  `nudges` as `{}`), `ts` last (UTC ISO-8601, `Z`). An unknown field name → `BenchError` (a typo is
  not a silent new column). Export the three field-order lists as `BENCHMARK_FIELDS`,
  `VERDICT_FIELDS`, `MATCH_FIELDS`.
- `stats(values) -> dict` — over the non-`None` numbers: `{"n", "median", "p25", "p75", "min",
  "max"}`; `statistics.quantiles(..., n=4, method="inclusive")` for the quartiles when n ≥ 2;
  n = 1 → all of median/p25/p75/min/max equal that value; n = 0 → `{"n": 0}` and `None`s.
- `legacy_rows(jsonl_path) -> list[dict]` — design §Legacy rows exactly: one `benchmark` row per
  parseable line; model from the sibling `<stem>.md` line containing `· model: X ·` (the `X`),
  else empty; stem `<YYYYmmdd-HHMMSS>-<label>` → `condition = label`, `session = "legacy-" + stem`;
  `diff` `"+A/-D"` → ints, anything else → `None`; `run_id` = `"b-" + sha256(f"{basename}:{lineno}").hexdigest()[:12]`.

### `lib/ledger.py`

- Add `"match": 1` to `KINDS`. Nothing else in this file changes. If `tests/test_ledger.sh`
  (T's) asserts the exact set of registered kinds, extend that one assertion with `match` — the
  only change allowed in that file.

### CLI (`python3 lib/bench.py SUB ...`, dispatched by `bin/delegate bench SUB ...`)

- `check PLAN` → validates and prints, one per line, `repeat case condition` in run order, then
  `N runs: C cases x K conditions x R repeats; reviewers: ...; review cases: ...`. Exit 0; on
  `BenchError` one line `delegate bench: <message>` to stderr, exit 2.
- `import-legacy FILE...` → appends each file's rows through `ledger.append`, skipping a row whose
  `run_id` already has a `benchmark` row in the ledger; prints
  `imported N, skipped M (already in the ledger), unreadable K`. Exit 0 (a missing file counts as
  unreadable and prints one `warn:` line).
- Cases root defaults: `$DELEGATE_HOME/evals/cases` and `$DELEGATE_HOME/evals/review-cases`
  (`DELEGATE_BENCH_CASES` / `DELEGATE_BENCH_REVIEW_CASES` override, for tests).

### `bin/delegate`

- `bench)` case in `main()`: `exec python3 "$DELEGATE_HOME/lib/bench.py" "$@"` with the ledger
  path resolved the way the `ledger` case does it; a `bench` line block in `usage()` naming
  `check` and `import-legacy` (later steps add their subcommands).

### `tests/test_bench_core.sh` — create

Offline, temp dirs only, `DELEGATE_LEDGER` into `mktemp -d`. At least:
1. `parse_case_env` on every real `evals/cases/*/case.env` returns their VERIFY verbatim (compare
   with what bash sourcing gives, in a subshell, for these trusted files only).
2. A case.env with `EVIL=$(touch /tmp/x)` → error (unknown key), and one with
   `VERIFY=$(touch $T/pwned)` parses as the literal string and `$T/pwned` does not exist.
3. `case_hash` stable across two calls, changes when one byte of `hidden/check.sh` changes,
   errors on a symlink.
4. Plan validation: a good plan passes; each of — unknown top key, unknown condition key
   (including `endpoint` and `grants`, which plans no longer take), duplicate label,
   own-harness without agent, model `"; rm -rf /"`, rules_ref `--upload-pack=x`,
   unknown case — fails with a message naming the field.
5. `run_matrix` deterministic for a seed, differs for another seed, has R×C×K entries.
6. Row builders: `kind`/`schema` first, `ts` last, field order equals the exported list, unknown
   field errors; a row round-trips through `ledger.append` + `ledger.read_rows`; a `match` row is
   accepted by `delegate ledger show --kind match`.
7. `stats` on `[]`, `[5]`, `[1,2,3,4]` (median 2.5, p25/p75 by the inclusive method), with `None`s
   ignored.
8. `import-legacy` on both real `evals/results/*.jsonl`: 10 rows imported, model equal to the
   text between `· model: ` and ` ·` in the `.md` header (extract it in the test with `sed`; never
   write a model name literally into the test — this repo is public), a second import imports 0
   and skips 10. The header looks like `rules: <...> · model: <name, may contain spaces> · repeat: 1`.
9. `delegate bench check` on a temp plan prints the matrix and exits 0; on a broken plan exits 2.

## Behaviour and edge cases

- Nothing in `lib/bench.py` runs a subprocess in this step.
- A plan file that is not JSON, or JSON that is not an object → `BenchError`.
- `cases: []` → error ("no cases"); `conditions: []` → error.

## Out of scope

- Running anything (B7), agent profiles (B3), reports (B10), docs (B10).
- Do not modify `evals/run.sh`, `evals/cases/**`, `lib/report.py`, `lib/chain.py`, or any test
  other than creating `tests/test_bench_core.sh`.

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check blames untracked deliverables; the harness
commits before the chain's verify runs. If that is the only failure mid-round, report it; never
edit that test. The **cage check** fails if this step changed any sandbox function or file
(R19: orchestrator code; `docs/specs/b-design.md` §Who writes what) — never "fix" it by editing
the check; leave the sandbox code alone and report what you needed under DEVIATIONS.

```bash
set -o pipefail && bash -n bin/delegate && python3 -m py_compile lib/*.py && [ -f tests/test_bench_core.sh ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && for fn in run_worker run_worker_docker run_worker_native ensure_network ensure_egress ensure_task_egress host_args read_mount_args make_guard_shims; do cmp -s <(git show bench:bin/delegate | sed -n "/^$fn() {/,/^}/p") <(sed -n "/^$fn() {/,/^}/p" bin/delegate) || { echo "CAGE CHANGED $fn (R19: orchestrator code)"; exit 1; }; done && { git diff --quiet bench -- lib/grants.py worker/egress.Dockerfile worker/egress-entrypoint.sh worker/entrypoint.sh lib/render-opencode-config.py worker/agent-launch || { echo "CAGE CHANGED files (R19: orchestrator code)"; exit 1; }; } && ! git diff --name-only bench | grep -qvE '^docs/specs/b-|^bin/delegate$|^lib/bench\.py$|^lib/ledger\.py$|^tests/test_ledger\.sh$|^tests/test_bench_core\.sh$' && echo GATE-OK
```

## Report format

```text
STATUS: done|partial|blocked
SUMMARY: <=3 sentences
TESTS: <counts; which suites ran; gate result>
RISKS: <what might still be wrong>
DEVIATIONS: <departures from this spec and why, or none>
```
