# Task B10: `delegate bench report`, `evals/run.sh` on top of bench, and the docs

`"hard": false`. Slice B step 10 of 10, chain segment 2 (`docs/specs/b-design.md` §Report, §Review "Scores are
computed by the report", R10, R16).

## Goal

Read the benchmark back: one command prints worker results per condition and reviewer results
per reviewer condition as medians and spread over several runs, from `benchmark`, `verdict` and
`match` rows only. `evals/run.sh` keeps its flags and becomes a thin wrapper over `delegate bench`.
The docs explain the whole workflow to the owner.

## Read first

- `docs/specs/b-design.md` §Report, §Review (hit rule, recall, false positives, verdict accuracy,
  agreement), §Row schemas, §What the owner must do, §CLI facts.
- `lib/bench.py` (B1 `stats`, field lists; B7/B9 for what the rows contain), `lib/ledger.py`
  `read_rows`.
- T4's `delegate stats` implementation (in `lib/ledger.py` or wherever T4 put it) — the table
  style, `--json` shape conventions, the unknown-kind warning line. Match them.
- `evals/run.sh`, `evals/README.md`, `docs/reference.md` §Measuring changes and §Layout,
  `docs/specs/b-o1-sandbox.md` (what the sandbox does with a harness setup, for the docs).

## Contract

### `delegate bench report [--session S]... [--plan NAME] [--case C] [--since YYYY-MM-DD] [--min-n N] [--json]`

(`lib/bench.py report`.) Reads only `benchmark`, `verdict`, `match` rows (other kinds filtered
before JSON parsing, as T4 does; unknown/malformed lines counted on one warning line).
`--session` repeatable; `--plan` matches the `plan` field; `--case` filters worker rows and
review-case verdicts; `--since` on `ts`. Read-only: the ledger is never opened for writing.

**Workers** — group `benchmark` rows by (`case`, `case_hash`, `mode`, `agent`, `model`,
`effort`, endpoint host, `rules_ref`, `source`). Columns: `n`, `hidden all-pass` (count/n),
`hidden %` (per-run `hidden_pass / hidden_total` ×100: median [min–max]), `verify ok`
(count of `verify_rc == 0` / n), `time s` (median [p25–p75]), `out tok` (median [p25–p75]),
`first edit s` (median), `last edit s` (median), `churn` (median `churn_events`), `timeouts`,
`setup/leak/run failed` (count). Rows with `status` `setup-failed`/`leak-refused`/`run-failed`
count in `n` and in the failed column but not in the medians.

**Reviewers** — join `verdict` → `match` on (`batch`, `subject`); unmatched verdicts are
excluded and counted on one line (`N verdicts not matched yet (batch still open)`). Group by
(`reviewer_mode`, `reviewer_agent`, `reviewer_model`, `reviewer_effort`). Per verdict on a
`review_case` target:
- a finding **hits** a defect when `finding.file == defect.file` and `finding.line` is not null
  and `defect.start - 3 <= line <= defect.end + 3`; a defect counts as found when any finding hits
  it; a finding that hits no defect is a false positive;
- `recall` = found / defects (seeded cases only; `None` for clean ones), `fp` = false positives,
  `fp_hm` = false positives of severity high or medium, `correct` = `verdict == truth.verdict`
  (`invalid`/`missing` are wrong).
Per verdict on a `run` target (joined to its `benchmark` row by `run_id`): `agrees_hidden` =
`(verdict == "accept") == hidden_all` (valid verdicts only); and per subject with ≥ 2 valid
verdicts, pairwise agreement: for reviewer X, the share of pairs (X, Y ≠ X) on the same subject
with the same verdict.
Columns: `cases n`, `recall` (median [min–max]), `fp` (median), `fp h+m` (median), `verdict
accuracy` (correct/n), `runs n`, `agree w/ reviewers` (share), `agree w/ hidden` (share),
`invalid+missing` (count).

**R10** — a group with `n < --min-n` (default 3) is not printed; one line per table says
`K groups below n=MIN hidden (--min-n 1 shows them)`. `--json` prints `{"workers": [...],
"reviewers": [...], "hidden_groups": {"workers": k, "reviewers": k}, "unmatched_verdicts": n,
"skipped_lines": n}` with every number the tables show (stats as `{n, median, p25, p75, min,
max}` objects). Empty ledger → empty tables, exit 0. Output is Markdown tables in the style of
`delegate stats`.

### `evals/run.sh` — rewritten as a wrapper, same flags

`--label NAME --rules-ref REF --cases a,b --repeat N --keep` and `-h`: writes a temp plan
(`name` = the label slugified to the plan-name rule; one delegate-mode condition, `label` = the
same, `rules_ref` when given; `repeat`; `cases` or `"all"`), runs `bin/delegate bench run PLAN
[--keep]`, takes the session id from its final `bench: session S:` line, then writes
`bin/delegate bench report --session S --min-n 1` to `evals/results/<YYYYmmdd-HHMMSS>-<label>.md`
and prints it. No `.jsonl` is written any more (the ledger holds the rows). The header comment
says so and points at `docs/benchmarks.md`.

### Docs

- `docs/benchmarks.md` — create: the workflow end to end (bundles and review cases; plans with a
  full example using placeholders only — `llm.example.com`, `model-a`, `model-b`; delegate mode
  (models from `delegate models`, R18) vs own-harness mode; agent profiles, where they are read
  from, and their `[setup]` lists; what happens to the owner's harness setup (copied per run into
  a directory only the agent's container mounts, at the owner's `$HOME` path, scrubbed before
  verify, never written back — B manages no credentials); the owner-run live checks from the
  design; building `delegate build --agents`; `delegate bench check/run/review/report/
  import-legacy`; the three telemetry sources and when each is empty; scoring after the run on
  copies; blind review and the `match` rows; reviewer metrics and their exact definitions; the
  security model table from the design; what is unverified — codex, the claude `result` event,
  `reasoningEffort` on the wire).
- `evals/README.md` — the bundle format (work and review cases), `evals/run.sh` as the
  quick path, a pointer to `docs/benchmarks.md`; keep the cases table, add the review cases.
- `docs/reference.md` — §Measuring changes points at `docs/benchmarks.md` and lists the `bench`,
  `score`, `agent`, `models` commands; §Layout gains `agents/`, `evals/review-cases/`.
- No host names, IPs, personal names or real model names anywhere (public repo).

### `tests/test_bench_report.sh` — create

Fixture rows appended through B1's builders into a temp ledger. At least:
1. Worker groups: 3 runs of condition A (hidden 10/10, 9/10, 10/10), 3 of B, 1 of C → A and B
   printed with exact medians/spread, C hidden by `--min-n 3` with the hidden-groups line, shown
   with `--min-n 1`; a `setup-failed` row counts in n and failed only.
2. Two `case_hash` values for one case form two groups (bundles are never pooled).
3. Reviewer metrics on hand-computed fixtures: a seeded case with defects at 12–14 and 30–30;
   findings at line 16 (hit, within +3), 26 (miss, 4 away), null line (miss) → recall 0.5, fp 2;
   a clean case with one low finding → fp 1, fp_hm 0, `accept` correct; an `invalid` verdict →
   wrong; agreement: three reviewers on two run subjects with known verdicts → exact shares;
   agreement with hidden against `hidden_all` true/false runs.
4. Unmatched verdicts (a batch with no `match` rows) excluded and counted.
5. `--json` parses; every table number is present; empty ledger → exit 0 and empty tables;
   a garbage line and an unknown kind → one warning line, counts right.
6. `evals/run.sh --label t --cases X --repeat 1` with `DELEGATE_BENCH_BIN` pointing at B7's fake:
   writes the `.md` report under a temp `evals/results` (make the results dir overridable with
   `EVALS_RESULTS_DIR` for the test) and no `.jsonl`.
7. Docs hygiene: `docs/benchmarks.md` exists, and none of `docs/benchmarks.md`,
   `evals/README.md`, `agents/*.toml` contains an IPv4 address other than `127.0.0.1`, or an
   e-mail address outside `example.com`/`localhost`. (Never write a real host, person or model
   name into the test to search for it — the test file is public too.)

## Out of scope

- New metrics beyond the design's; plots; prices. No changes to `lib/ledger.py`, `bin/delegate`
  beyond the usage line, `evals/cases/**`, `evals/review-cases/**`, or other tests.

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check blames untracked deliverables; the harness
commits before the chain's verify runs. If that is the only failure mid-round, report it; never
edit that test. The **cage check** fails if this step changed any sandbox function or file
(R19: orchestrator code; `docs/specs/b-design.md` §Who writes what) — never "fix" it by editing
the check; leave the sandbox code alone and report what you needed under DEVIATIONS.

```bash
set -o pipefail && bash -n bin/delegate && bash -n evals/run.sh && python3 -m py_compile lib/*.py && [ -f tests/test_bench_report.sh ] && [ -f docs/benchmarks.md ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && for fn in run_worker run_worker_docker run_worker_native ensure_network ensure_egress ensure_task_egress host_args read_mount_args make_guard_shims net_args run_limited run_scorer agent_seed_home agent_scrub_home llmlog_start llmlog_stop; do cmp -s <(git show b-o1-sandbox:bin/delegate | sed -n "/^$fn() {/,/^}/p") <(sed -n "/^$fn() {/,/^}/p" bin/delegate) || { echo "CAGE CHANGED $fn (R19: orchestrator code)"; exit 1; }; done && { git diff --quiet b-o1-sandbox -- lib/grants.py worker/egress.Dockerfile worker/egress-entrypoint.sh worker/entrypoint.sh lib/render-opencode-config.py worker/agent-launch || { echo "CAGE CHANGED files (R19: orchestrator code)"; exit 1; }; } && ! git diff --name-only delegate/b-9-review | grep -qvE '^docs/specs/b-|^bin/delegate$|^lib/bench\.py$|^evals/run\.sh$|^evals/README\.md$|^docs/benchmarks\.md$|^docs/reference\.md$|^tests/test_bench_report\.sh$' && echo GATE-OK
```

## Report format

```text
STATUS: done|partial|blocked
SUMMARY: <=3 sentences
TESTS: <counts; which suites ran; gate result>
RISKS: <what might still be wrong>
DEVIATIONS: <departures from this spec and why, or none>
```
