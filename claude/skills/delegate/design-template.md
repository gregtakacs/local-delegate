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

## The repo's gate

`<the ONE command the repo's own docs name as the worker's full gate, e.g. make check-sandbox>`.
A step's verify ends with it, exactly as written here — always, for a `"hard": true` step and for
the plan's last step.

**The quick step check** (optional, but name it if the repo has one):
`<the ONE command that checks one step and nothing else: its own modules plus a scope guard, e.g.
make check-step>`. Any other step may end its verify with this instead of the full gate, so a
three-step change does not pay the whole suite three times: the gate still runs on the hard steps,
on the last step, and once by the orchestrator on the squashed slice. The plan names both commands
(`"gate"`, `"step_gate"`); where the repo names no such quick check, name none and every step runs
the gate. Either way, one command from the repo's own docs, never a verify you invented per step.

## Fixed requirements

<Anything not open to the worker's judgement: security rules, limits, names already decided,
what must not change. Write each one so it can go into the step specs word for word.>

<If the slice parses anything an agent, worker or other program wrote (transcripts, state,
ledgers, plan files, git metadata, another tool's database), it is security-sensitive: a
Claude lead designs it (SKILL.md, Phase 1). Either way, list its hostile cases here as required
acceptance items: non-regular files, non-finite and huge numbers, oversize input, control and
bidi characters, root escapes, `$` vs `\Z`, concurrency, one bad record among good ones.>

## What to write

1. `docs/specs/<slice>-design.md`: what the slice adds, mapped to the design's sentences
   (cite §); data and migrations; routes and pages with their caller rules; the gate as
   concrete checks; what waits for later slices; and `## Owner questions` (pick an option and
   mark it; don't stop).
2. One spec per step, `docs/specs/<slice>-<n>-<slug>.md`, following the template. Use 2–5
   steps. Each step is one coherent change, under ~1500 lines and ~90 minutes.
3. `docs/specs/<slice>-chain.json`:
   `{"name":"<slice>","repo":"../..","base":"<BASE>","gate":"<the repo's gate>","step_gate":"<the quick step check, or leave it out>","retries":2,"steps":[…]}`.
   - A step gets `"hard": true` when it has real algorithmic content **or** guards a security
     boundary: validating untrusted input, building commands or paths from it, auth or tokens,
     sandboxing, permission checks, crypto. Every other step gets `"hard": false`. `"hard"` picks
     the model *and* the verify level: a hard step runs the full gate, never the quick check.
   - Every step gets `"scope"`: the path patterns it may change — exactly the files its own spec
     lists under "Files owned", plus that step's test fixture directories. `delegate chain PLAN
     --check` refuses a step whose scope misses one of them.
   - Every verify is the step's own tests (its suite, and its `--mutations` run when the repo has
     them), then the repo's gate, exactly as "The repo's gate" names it — except that an ordinary
     step (not `"hard"`, not the plan's last step) may end with the plan's `"step_gate"` instead:
     the quick check for one step, its own modules plus the scope guard. Nothing else: no
     toolchain setup, no build flags, no copy of what the gate already runs. Both commands live in
     the repo under its own tests; a verify that re-types either one (or a step that weakens it)
     is the bug. The chain refuses a plan whose verify does not contain its `"gate"` — or, for an
     ordinary step when the plan names one, its `"step_gate"`; the refusal says which.
   - Write each verify by hand, literally, in the chain file. Do not generate the plan with a
     script: one generator's blanket `replace("N", n)` turned `PYTHON` into `PYTHO2` and
     `SDKCONFIG` into `SDKCO2FIG` in every step, and each still ran, weaker, unseen.
   - Use `set -o pipefail` when it pipes. A chain verify carries no scope gate of its own: the
     chain runs each step's `"scope"` first, against the branch that step itself starts from.
   - A plan for a different repo uses an absolute `"repo"` and bare spec file names.

## Rules

- Respect the rulings, and use real names from the code you read. Never invent an API.
- No secrets and nothing from `.env` in a spec.

## Out of scope

Any change outside `docs/specs/`.

## Acceptance (verify)

`python3 -c "import json,os;p=json.load(open('docs/specs/<slice>-chain.json'));assert p['steps'];[open(s['spec']) for s in p['steps']];assert os.path.getsize('docs/specs/<slice>-design.md')>3000;print('ok',len(p['steps']),'steps')" && git diff --name-only HEAD | grep -v '^docs/specs/' | (! grep .)`

A chain step does not write its own scope gate: it gets a `"scope"` listing exactly the files its spec owns, and the chain runs that gate itself, first, diffed against the branch that step starts from (`delegate/<previous step>`; the plan's base only for step 1).
