# <SLICE> design: plan the slice and write its step specs (no product code)

<!-- The Phase 1 brief. Give pointers and fixed rules, never your own plan: the worker designs.
     First move any ruling that binds this slice from memory into the design doc; mount the
     remaining relevant memory notes with one --read each (never the whole memory folder).
     Run it as: delegate run THIS.md --repo REPO --name <slice>-design --base BASE --hard
       [--read OTHER_REPO] [--read MEMORY_NOTE …] --read ~/.claude/skills/delegate --verify "<the Acceptance command>"
     Then review the plan (Phase 2) and run the chain. -->

## Goal

Slice **<SLICE>** of `<design doc path>` (§12 row and its gate). Your job in this task is
**design only**: the slice design, a spec per step, and a `delegate chain` plan that other
workers will run step by step. Write no product code.

## Read first

- `<design doc>`: §0 rulings (name the ones that bind this slice), the sections the slice
  implements, and the §12 row with its gate.
- The code it changes: <entry files, the modules to imitate, the data model>.
- How earlier slices were planned, which you should imitate: `docs/specs/<earlier>-*.md` and
  `docs/specs/<earlier>-chain.json`.
- The step-spec template: `~/.claude/skills/delegate/spec-template.md` (mounted read-only).
- Settled decisions that aren't in the repo yet, mounted read-only for you:
  `<~/.claude/projects/<project>/memory/<topic>.md, one line per note, with what it settles>`.
  They're binding, like the design doc's rulings. Where a note and the code disagree, the
  note is the owner's decision: say so in the design, don't follow the code.

## Fixed requirements

<Anything not open to the worker's judgement: security rules, limits, names already decided,
what must not change. Write each one so it can go into the step specs word for word.>

## What to write

1. `docs/specs/<slice>-design.md`: what the slice adds, mapped to the design's sentences
   (cite §); data and migrations; routes and pages with their caller rules; the gate as
   concrete checks; what waits for later slices; and `## Owner questions` (pick an option and
   mark it; don't stop).
2. One spec per step, `docs/specs/<slice>-<n>-<slug>.md`, following the template. Use 2–5
   steps. Each step is one coherent change, under ~1500 lines and ~90 minutes.
3. `docs/specs/<slice>-chain.json`:
   `{"name":"<slice>","repo":"../..","base":"<BASE>","retries":2,"steps":[…]}`.
   - A step gets `"hard": true` when it has real algorithmic content **or** guards a security
     boundary: validating untrusted input, building commands or paths from it, auth or tokens,
     sandboxing, permission checks, crypto. Every other step gets `"hard": false`.
   - Every verify runs the real toolchain and the repo's full gate, plus the step's own tests.
     Use `set -o pipefail` when it pipes.
   - A plan for a different repo uses an absolute `"repo"` and bare spec file names.

## Rules

- Respect the rulings, and use real names from the code you read. Never invent an API.
- No secrets and nothing from `.env` in a spec.

## Out of scope

Any change outside `docs/specs/`.

## Acceptance (verify)

`python3 -c "import json,os;p=json.load(open('docs/specs/<slice>-chain.json'));assert p['steps'];[open(s['spec']) for s in p['steps']];assert os.path.getsize('docs/specs/<slice>-design.md')>3000;print('ok',len(p['steps']),'steps')" && git diff --name-only HEAD | grep -v '^docs/specs/' | (! grep .)`

A scope gate written `… | grep -v X | (! grep .)` passes only without `set -o pipefail`: under pipefail the empty, in-scope case fails too (grep -v exits 1). In a verify that sets pipefail, write it `! git diff --name-only | grep -qvE 'X'`. In a chain, a step's scope gate diffs against the branch that step starts from (`delegate/<previous step>`; the chain's base only for step 1): diffed against the chain base, step 2 inherits step 1's files and can never pass.
