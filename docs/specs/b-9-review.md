# Task B9: `delegate bench review` — blind reviews by pluggable agents, `verdict` then `match` rows

`"hard": true` — this step parses untrusted reviewer output and decides what a reviewer can see
(blindness is the point of R15): review the verdict parser and the blind-repo builder line by
line. Slice B step 9 of 10 (`docs/specs/b-design.md` §Review, §Row schemas `verdict`/`match`,
R15, R16).

## Goal

`delegate bench review` gives every scored run of a session, and every review case, to each
reviewer condition of the plan — the delegate worker or any agent profile — under a subject id
that names no model, agent, condition, case or session. Each reviewer writes a verdict file;
bench validates it and appends a `verdict` row at once; only after every verdict of the batch is
in does it append the `match` rows that say which run or review case each subject was.

## Read first

- `docs/specs/b-design.md` §Review, §Row schemas (`verdict`, `match`), §Trust.
- `lib/bench.py` (B1 row builders, ids; B7 `run` — reuse its subprocess, env and task-id helpers,
  don't fork them), `lib/ledger.py` (`append`, `read_rows`), B8's `evals/review-cases/*`.
- `bin/delegate` `cmd_run` (the delegate prompt wrapper a delegate-mode reviewer gets; `--raw`
  is not used), `cmd_rm`.
- `tests/test_bench_run.sh` (B7) — reuse its fake-`delegate` approach.

## Contract

### CLI

`delegate bench review (SESSION | --plan PLAN) [--reviewers a,b] [--cases-only | --runs-only]
[--batch B] [--keep] [--dry-run]` → `lib/bench.py review`. `SESSION`: its saved plan's
`reviewers` and `review_cases`, and its scored runs. `--plan PLAN` without a session: review
cases only (a reviewer benchmark with no worker runs), in a new dir
`$DELEGATE_STATE/bench/<plan name>-reviews-<stamp>/`. `--reviewers` narrows by label. `--batch B`
resumes a batch. `usage()` line.

### Batch

- `batch = "rb-" + secrets.token_hex(4)`; state `<session dir>/reviews/<batch>/` (mode 700) with
  `subjects.json` (mode 600): `{subject: {"target": "run"|"review_case", "run_id"?, "case",
  "case_hash"}}`.
- Subjects: every run of the session whose `benchmark` row has a `score/final/` dir on disk and a
  status other than `setup-failed`, `leak-refused`, `run-failed`; plus every review case named by
  `review_cases` (unless `--runs-only`); `--cases-only` drops runs.
- Work list: subjects × reviewer conditions, shuffled with `random.Random(batch)`. Resume skips a
  pair that already has a `verdict` row with this `batch`, `subject` and `reviewer`.

### Blind repo (one per subject)

- Path: `$DELEGATE_STATE/bench-review/<subject>/<subject>/` (the repo dir is named by the subject
  so task ids stay unique; no session, plan, batch, case, condition, model or agent string in the
  path).
- Commit 1 `base`: the run's fixture tree (`git archive` of the fixture repo's first commit) or
  the review case's `setup.sh` output. Commit 2 `change`: the after-tree — the run's
  `score/final/` or base + the case's `change/` overlay (+ `change/.delete`) — **sanitized**:
  drop `.git`, `node_modules`, `.venv`, `__pycache__`, `.eval-hidden`, `.claude/`, `.codex/`,
  `.opencode/`, anything starting `.delegate`, `REVIEW-VERDICT.json`, and `CLAUDE.md`/`AGENTS.md`
  unless the base has them; symlinks are dropped, not followed.
- Both commits: `-c user.name=bench -c user.email=bench@localhost`, `GIT_AUTHOR_DATE` and
  `GIT_COMMITTER_DATE` = `2000-01-01T00:00:00Z`, messages exactly `base` and `change`.
  `git init -q -b main`.

### Reviewer run

- `delegate run <prompt file> --repo <blind repo> --name r<k> --timeout <review_timeout>` (`k` =
  the reviewer's 1-based index in the plan's `reviewers`), plus the reviewer condition's flags
  exactly as B7 builds them for a worker condition (`--endpoint/--model/--effort` or
  `--agent/--model/--effort/--endpoint/--grant`). No `--verify`, no `--service`. Environment: B7's
  (`DELEGATE_READ_PATHS=` empty), with `DELEGATE_FILE_TIMELINE=0`.
- The prompt file (in the batch dir, never inside the blind repo), verbatim:

  ```text
  You are reviewing a code change. You are not told who or what wrote it, and it does not matter: judge the change against the specification below.

  - The working directory is a git repository with two commits. `git diff HEAD~1 HEAD` is the change; `HEAD~1` is the code before it.
  - You may read anything and run anything here (tests, scripts). Do not edit, add or delete any file except the verdict file.
  - Write your verdict to `REVIEW-VERDICT.json` at the repository root, as one JSON object:
    {"verdict": "accept" or "reject",
     "findings": [{"file": "<path from the repository root>", "line": <line in the file after the change, or null>,
                   "end_line": <line or null>, "severity": "high" or "medium" or "low",
                   "summary": "<one sentence, at most 200 characters>"}]}
  - "accept" means you would merge the change as it is. A finding of severity high or medium means "reject".
  - List every real problem: behaviour that contradicts the specification, security problems, error handling the specification asks for and the change lacks. Do not list style preferences. An empty list is right for a change without problems.

  <specification>
  <the case's spec.md verbatim>
  </specification>
  ```
- After the run: read `<worktree>/REVIEW-VERDICT.json` (worktree path from the task's meta.env),
  then append the `verdict` row, then (unless `--keep`) `rm <task id> --delete-branch`.

### Verdict parsing (`parse_verdict(path) -> dict`, untrusted)

- `os.lstat`: missing → `verdict: "missing"`; not a regular file (symlink, dir, fifo) →
  `invalid`, reason `not a regular file`; > 256 KiB → `invalid`, `too large`; read with
  `O_NOFOLLOW`. Not UTF-8 / not JSON / not an object → `invalid` with that reason. `verdict` not
  `accept`/`reject` → `invalid`, `bad verdict`. `findings` absent → `[]`; not a list → `invalid`.
- Each finding: an object with `file` (str, 1..300 chars, relative, no NUL, no `..` segment),
  `line` (int ≥ 1 or null), `end_line` (int ≥ `line`, or null; null when `line` is null),
  `severity` (`high`/`medium`/`low`), `summary` (str, cut to 200 chars, newlines → spaces).
  Unknown keys ignored. A finding that fails these is dropped and counted in `findings_dropped`.
  At most 100 kept, in file order; `findings_total` = valid findings before the cut.
- Never `eval`, never a path opened from inside the file's content.

### Rows

- `verdict` (B1 `verdict_row`, fields per the design): `review_id`, `batch`, `subject`, reviewer
  label/mode/agent/model/effort/endpoint (meta.env `BASE_URL`), `reviewer_agent_version` and
  `reviewer_model_reported` (report.json), `reviewer_task_id`, `status` (report.json), the parsed
  verdict fields, `duration_s`, tokens (report.json for own-harness; T's round row for delegate
  mode). Appended immediately after each review.
- `match` (B1 `match_row`): one per subject, appended only after the work list is finished (every
  pair has a `verdict` row for this batch): run subjects → `target: "run"`, `run_id`, `session`,
  `case`, `case_hash`; review cases → `target: "review_case"`, `case`, `case_hash`, `truth` with
  each defect's `id, file, start, end, severity` only (no `what`, no `fix`). An interrupted batch
  writes no `match` rows; `--batch B` finishes it and then writes them. A batch whose `match` rows
  exist is complete; rerunning it does nothing.

### `tests/test_bench_review.sh` — create

Offline; temp state, ledger, cases (`DELEGATE_BENCH_CASES` with one work case, the real
`evals/review-cases` or a temp copy), a session made by B7 with its fake `delegate` (two scored
runs with distinctive condition labels/models, e.g. `cond-zeta`/`model-zeta`), and a fake
`delegate` for reviewers that copies its prompt to a log and writes a verdict file chosen by the
test. At least:
1. Two reviewers × (2 runs + 5 review cases) → 14 `verdict` rows then 7 `match` rows; in the
   ledger every `verdict` row of the batch precedes every `match` row.
2. Blindness: no prompt, blind-repo path, commit message, author, or file in the blind repo
   contains the session name, plan name, `cond-zeta`, `model-zeta`, a run id, a case name, the
   word `truth`, a defect `what` sentence; commit dates are 2000-01-01; `.eval-hidden`,
   `node_modules`, a planted `.claude/settings.json` and `CLAUDE.md` (absent from base) are not in
   commit 2; a symlink in the final tree is dropped.
3. Each reviewer run's argv carries its condition's flags and `--name r<k>`, no `--verify`; env
   has empty `DELEGATE_READ_PATHS`.
4. Parser cases, each a verdict row with the stated values: missing; symlink to a valid file →
   `invalid`/`not a regular file`; 300 KiB → `too large`; `not json`; `[]`; `verdict: "maybe"`;
   150 valid findings → 100 kept, `findings_total` 150; a finding with `file: "../x"`, one with
   `severity: "critical"`, one with `line: 0` → dropped, `findings_dropped` 3; a 1 000-char
   summary → 200 chars.
5. `match` truth rows carry defect ids/lines/severities and no `what`/`fix`.
6. Interrupt simulation: the fake fails (exit 1, no verdict file) on the 3rd pair → that pair's row
   is `missing`; run with a fake that raises `KeyboardInterrupt`-equivalent (exit 130 and the test
   kills bench) → no `match` rows; `--batch B` resumes, runs only the missing pairs, then writes
   the 7 `match` rows; a third call does nothing.
7. `--plan PLAN --cases-only` with no session → 5 subjects per reviewer, only `review_case` matches.

## Out of scope

- Scoring reviewers and agreement (B10 computes them from rows). No change to `bin/delegate`
  beyond the usage line/dispatch, nothing in `lib/agents.py`, `lib/grants.py`, `evals/**`, or
  existing tests.

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check blames untracked deliverables; the harness
commits before the chain's verify runs. If that is the only failure mid-round, report it; never
edit that test.

```bash
set -o pipefail && bash -n bin/delegate && python3 -m py_compile lib/*.py && [ -f tests/test_bench_review.sh ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && ! git diff --name-only delegate/b-8-review-cases | grep -qvE '^docs/specs/b-|^bin/delegate$|^lib/bench\.py$|^tests/test_bench_(core|review)\.sh$' && echo GATE-OK
```

## Report format

```text
STATUS: done|partial|blocked
SUMMARY: <=3 sentences
TESTS: <counts; which suites ran; gate result>
RISKS: <what might still be wrong>
DEVIATIONS: <departures from this spec and why, or none>
```
