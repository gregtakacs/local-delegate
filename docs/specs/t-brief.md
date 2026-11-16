# T design: plan the telemetry ledger slice and write its step specs (no product code)

## Goal

Slice **T** of `docs/specs/bench-rulings.md` (rulings R1–R8; R9–R17 belong to the next slice,
B, and constrain the schema only). Your job in this task is **design only**: the slice design,
a spec per step, and a `delegate chain` plan that other workers will run step by step. Write no
product code.

What T delivers: a durable ledger that every round appends a summary row and a compact
per-step timeline to; review rows the orchestrator writes when a slice lands; a one-time import
of existing task records; a `delegate` command that shows per-project totals.

## Read first

- `docs/specs/bench-rulings.md`: all of it. R2–R8 are this slice; R11, R13 and R16 tell you
  what slice B will add to the same ledger.
- The round lifecycle in `bin/delegate`: `do_round` (line ~642), `finalize_round` (~715; it
  writes the round commit and calls `lib/report.py report`), `cmd_run` and `cmd_continue` (how
  `--hard` picks the model; `meta.env` keys), `cmd_prune`, `cmd_rm` (they delete task records
  and must leave the ledger alone), `cmd_doctor`, `cmd_build` (the image stamp label).
- `lib/report.py` (the report.json fields and how they are derived from `events.jsonl`),
  `lib/taskstate.py` (reading task state, which `delegate top` and `list` use), `lib/chain.py`
  (chain state, retries, `--clean`), `lib/progress.py`.
- A real task record to see the actual shapes:
  `~/.local/state/delegate/` is NOT mounted; instead read the report.json fields from
  `lib/report.py` and the event shapes it parses. Event types seen in real logs: `step_start`,
  `step_finish` (`part.tokens` = input, output, reasoning, cache.read, cache.write; `part.reason`),
  `tool_use` (`part.tool`, `part.state` = input, output, status, time{start,end}, title, metadata),
  `text`; each event has a millisecond `timestamp`.
- `evals/run.sh` and `evals/README.md`: the existing benchmark rows (slice B will move them onto
  this ledger, so the schema must be able to carry them).
- Test style to imitate: `tests/test_chain.sh` (a fake `delegate`, temp `DELEGATE_STATE`),
  `tests/test_top.sh`, `tests/test_round_commit.sh`. Repo conventions: `AGENTS.md`, `README.md`,
  `docs/reference.md` (the command reference a new command must be added to).
- The step-spec template: `~/.claude/skills/delegate/spec-template.md` (mounted read-only), and
  `docs/specs/o1b-*.md` / `o1b-chain.json` for how earlier slices of this repo were planned.

## Fixed requirements

- The ledger lives outside every repo and outside every task directory under
  `$DELEGATE_STATE`; `prune`, `rm` and `chain --clean` cannot reach it. Its location is a config
  setting with a default under the XDG state or data home, documented in
  `config.example.env`.
- Appending is safe with several rounds finishing at once (several workers run in parallel):
  one writer at a time, and a reader never sees a half-written row.
- A ledger failure (disk full, unwritable path, bad record) never changes a round's outcome or
  exit code: it is one warning line, like a failing wake-up hook.
- Every row has a `kind` and a schema version, so slice B can add kinds (benchmark runs in both
  modes, reviewer verdicts) without a migration. Unknown kinds are skipped by readers.
- Effort is its own field (`hard` / `normal`), recorded from the `--hard` flag at run or
  continue time, not inferred from the model name.
- No tool input, tool output or model text in any row (R4). No secrets, keys, key file
  contents or grant contents in any row; the endpoint URL is recorded as configured.
- Python 3.10+ standard library only, like the rest of `lib/`.
- This is a public repository: no host names, IP addresses, personal names or real model
  aliases in code, tests, docs or examples. Use placeholders such as `llm.example.com` and
  `model-a`.

## What to write

1. `docs/specs/t-design.md`: what the slice adds, mapped to the rulings (cite R-numbers);
   the row schema for each kind, field by field, with its source in the code; where and when
   each row is written; the import; the stats command with its output shape and flags; what
   waits for slice B; and `## Owner questions` (pick an option and mark it; don't stop).
2. One spec per step, `docs/specs/t-<n>-<slug>.md`, following the template. Use 2–5 steps.
   Each step is one coherent change, under ~1500 lines and ~90 minutes.
3. `docs/specs/t-chain.json`:
   `{"name":"t","repo":"../..","base":"bench","retries":2,"steps":[…]}`.
   - A step gets `"hard": true` when it has real algorithmic content **or** guards a boundary
     (concurrent appends, parsing records, building paths). Every other step `"hard": false`.
   - Every verify runs the repo's full gate (`bash -n bin/delegate`, `python3 -m py_compile lib/*.py`, and
     every `tests/test_*.sh`, as `docs/specs/o1b-chain.json` does), plus the step's own new tests, and a
     scope check against the branch that step starts from. Use `set -o pipefail` when it pipes;
     write the scope check as `! git diff --name-only <from> | grep -qvE '<allowed>'`.

## Rules

- Respect the rulings, and use real names from the code you read. Never invent an API.
- No secrets and nothing from `.env` in a spec.

## Out of scope

Any change outside `docs/specs/`. Benchmark running, own-harness agents and reviewers (slice
B). Resolving model names to real models (R7).

## Acceptance (verify)

`python3 -c "import json,os;p=json.load(open('docs/specs/t-chain.json'));assert p['steps'];[open(s['spec'] if os.path.exists(s['spec']) else 'docs/specs/'+s['spec']) for s in p['steps']];assert os.path.getsize('docs/specs/t-design.md')>3000;print('ok',len(p['steps']),'steps')" && ! git diff --name-only bench | grep -qvE '^docs/specs/'`
