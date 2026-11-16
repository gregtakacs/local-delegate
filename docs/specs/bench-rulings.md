# Telemetry and benchmarks: owner rulings

Settled by the owner on 2026-11-16. They bind two slices: **T** (telemetry: a durable record of
real delegate work) and **B** (benchmarks: comparing models and agents on fixed tasks). Neither
slice may contradict them. A design that needs one changed says so under `## Owner questions`.

## Purpose

- **R1. The goal is to benchmark models, and separately agents.** The owner designs and runs
  benchmarks between models and their execution behaviour (local and frontier), and keeps
  per-project effort and time stats from everyday delegate work. The full delegation record is
  not needed for that; a summary is.

## What is recorded (slice T)

- **R2. A durable ledger, outside every repo and outside the task records.** `delegate prune`,
  `delegate rm` and `delegate chain --clean` never touch it. Nothing in it is ever committed to
  a repo. The raw `events.jsonl` keeps its 14-day prune and is not copied into the ledger.
- **R3. One summary row per round**, written by delegate when the round ends (the report is the
  source), covering:
  - task identity: repo, slice/chain, step, task id, round, spec hash, base ref and SHA, verify
    command;
  - conditions: endpoint URL, model name as served (the alias is fine to record), **effort as
    its own field** (`hard` or `normal`, from `--hard`), delegate version, a hash of the worker
    rules, the worker image stamp, runner, timeout, edit cap, and how many other worker rounds
    were running at the same time;
  - outcome: harness status, worker status, verify exit code, nudges, tool errors, todo
    completion, chain retries;
  - cost and time: start and end time, duration, steps, tool calls, input / output / reasoning /
    cache tokens, final context size.
- **R4. A compact per-step timeline per round**, derived from `events.jsonl` before it is
  pruned: for each model step its start and end timestamps and tokens; for each tool call its
  tool name, success, start and end. No tool inputs or outputs, no text. Timestamps are
  per-call, because they are the join key with the inference server's own request logs (R7).
- **R5. A review row per step when a slice lands**, written by the orchestrator: accepted
  as-is or fixed, bugs found by severity, lines changed by the reviewer. Rows link to round rows
  by task id.
- **R6. Per-project totals come from the rows** (rounds, wall time, tokens, retries, review
  findings, by repo / slice / model / effort), shown by a `delegate` command.
- **R7. Resolving a model name to the real model is out of scope.** For a local endpoint the
  owner joins the ledger to the inference server's own logs and configs after the fact
  (endpoint, model name and timestamps are the key). For a frontier endpoint, the endpoint and
  model name at that time is the claim; nothing more is recorded or verified.
- **R8. Existing task records can be imported** into the ledger once, while they still exist.

## Benchmarks (slice B)

- **R9. A benchmark task is a fixed bundle:** prompt, base repo state, visible verify command,
  hidden checks. `evals/cases/<case>/` is that bundle today and is extended, not replaced.
- **R10. Several runs per condition.** Each run is one sample; reports show medians and spread,
  never a single run.
- **R11. Two ways to run a bundle:**
  - **delegate mode**: the delegate worker (same OpenCode harness and rules for every model),
    so models are compared, not harnesses. The model and endpoint are chosen per run.
  - **own-harness mode**: the bundle's prompt given once to a standalone agent in its own
    harness (Claude Code, Codex, or any agent a command template describes), from the same base,
    in the same kind of sandbox, with the same time limit and network rules as delegate mode.
- **R12. Hidden checks never enter the sandbox** in either mode while the agent runs. Scoring
  (hidden checks, verify, review) runs on a copy after the run has ended.
- **R13. Own-harness telemetry, best available per run:** (a) a pass-through logging proxy on
  the harness's API base URL, when the harness accepts one and uses an API key; (b) the
  harness's own machine-readable output, checked against the installed version; (c) always, a
  file timeline of the work tree (a watcher or frequent snapshots: time to first edit, churn,
  when it settled). Fields a harness does not give stay empty; rows carry `mode`.
- **R14. Own-harness agents run fully auto-approved, only inside the sandbox.** Never on the
  host. Their credentials reach the sandbox only through a grant the owner writes; delegate
  code never writes a grant.
- **R15. Blind review.** The reviewer gets the spec and the diff under a run id that does not
  name the model or agent. The verdict is recorded first and matched to the run afterwards.
- **R16. The reviewer is itself a pluggable agent, and is benchmarked too.** Any agent the
  own-harness mode can run (or the delegate worker) can be the reviewer. Reviewers are scored
  against ground truth: review cases with known, seeded defects at known places, plus clean
  diffs, giving recall, false positives and verdict accuracy; and on real runs, agreement
  between reviewers of the same diff. Reviewer results are compared across agents like worker
  results are.
- **R17. Lost history is an accepted edge case.** A bundle whose base commit no longer exists is
  rebuilt or retired, not rescued.
