# Levels of delegation

All levels use the same worker underneath: an opencode agent on your self-hosted model,
started with `delegate run`. The levels differ in who plans, who reviews, and how closely
you watch.

## The levels

| Level | You say | Claude's role | Worker runs | Best for |
|---|---|---|---|---|
| **Raw (pipe)** | `/delegate raw: …` (add `here` for in place) | None: passes your text verbatim and prints the worker's answer verbatim; `raw: …` again continues the same session | Isolated, or in place with `here` | Talking to the local agent directly, with Claude only as the pipe |
| **0. Claude does it** | (nothing special) | Writes the code itself | — | Under ~30 lines, debugging an unknown cause, design work |
| **1. Supervised** | `/delegate here, I'm watching: …` | Writes a short spec from your request, reviews each round, sends corrections | **In place** (`--here`): your checkout, native, unsandboxed, no commits | Small to medium tasks while you're at the screen and want to see edits live |
| **2. Single task** | `/delegate …` | Same as level 1, but runs it in the background | **Sandboxed**: own worktree and branch, Docker, filtered network, one commit per round | Self-contained tasks you don't need to watch, several in parallel |
| **3. Slice lead** | "Start a delegate-lead for slice W5 of `docs/design.md`, repo X, base Y" | A sub-agent plans the whole slice: 2–6 specs, a chain, one live check, a squash-merge, a short report | Sandboxed, chained step after step, each step accepted only when done and verified | A section of a written design, roughly 2–6 steps or up to ~5k lines |
| **3h. Slice lead, in place** | "Start a delegate-lead for slice W5 of `docs/design.md` in X, in place, I'm watching" | Same planning, chain and live check, but in your checkout | **In place**: chained steps edit your checkout live, one commit per accepted step on your current branch | A design section you want to watch being built, step by step |
| **4. Hub** | One session that starts several leads | Hands out slices, relays reports, asks you only for real decisions | Several leads, each with its own chain | A whole design built in parallel slices |

How to pick: the bigger the work, and the more of it a design doc already settles, the
higher the level. Levels 1 and 2 need only a sentence from you, because Claude writes the
spec. Levels 3 and 4 need a design doc, because the lead writes every spec up front from it.

Rule of thumb:

- quick, and you're watching: level 1
- quick, and you aren't: level 2
- one section of a design doc: level 3 (3h if you want to watch it)
- a whole design: level 4

## Example prompts

Level 1, supervised in place:

> /delegate here, I'm watching: add a `--json` flag to `stackctl keys list`. Verify with
> `pytest tests/test_api_keys.py`. Leave it uncommitted.

Level 2, sandboxed in the background:

> /delegate: add a `--json` flag to `stackctl keys list`, verify with
> `pytest tests/test_api_keys.py`, and merge it when it passes your review.

Level 3, from any session:

> Start a delegate-lead for slice W5 of `docs/design.md` in `~/src/my-app`,
> building on branch `w4`. Don't merge into main.

Add "with model: sonnet" to try a cheaper lead.

Level 3h, a slice in place:

> Start a delegate-lead for slice W5 of `docs/design.md` in `~/src/my-app`,
> in place, I'm watching.

The checkout must be clean (commit or stash first). The lead commits its specs, then the
chain runs each step in your checkout and commits it as `<chain>: <step>` once it's done and
verified. A failing step stays uncommitted until the lead fixes it. At the end the lead does
its live check and commits any fixes on top. There's no squash-merge.

Level 4, the hub:

> Be the hub for `docs/design.md`. Start a delegate-lead per slice (W5 and G3 in parallel,
> W6 after W5), relay their reports, and ask me only for decisions the design doesn't settle.

A hub can also run its slices in place ("in place, I'm watching"), but then only one at a
time: two workers in one checkout would overwrite each other. Parallel slices need the
isolated default.

## Isolated or in place

| | Isolated (default) | In place (`--here`, `"here": true`, "I'm watching") |
|---|---|---|
| Where the worker edits | Its own worktree, branch `delegate/<slug>` | Your checkout, your current branch |
| Sandbox | Docker, non-root, network filtered | None: native, as you |
| You see changes | After the round, in the report and diff | Live, in your editor |
| Commits | One per round on the task branch, then merge | Single task: none (snapshot refs). Chain: one per accepted step on your branch |
| Parallel | Yes, many tasks and slices | One in-place task per checkout |
| `--service postgres`, `--copy` | Yes | No |
| Starting state | Your branch's last commit | Single task: your working tree as is. Chain: must be clean |

## Where the Claude tokens go

- **Levels 1 and 2:** your main thread holds the spec, the reports and the diffs. That's
  cheap for a few tasks. Start a fresh session after a long run of unrelated ones, or every
  turn re-reads a growing context.
- **Level 3:** the lead pays for planning once and for the live check once; the hub pays
  almost nothing. Measured on one real 5-step slice: lead about $8.60, hub about $0.90, for 5 steps
  and about 5,200 lines. The live check can be the expensive part: a browser-driven check,
  as in W4b, costs more, and it also found a real bug.
- **Level 4:** the cost is the sum of the leads. Keep the hub's own context thin.
- **The model knob:** a Sonnet lead should cost about a third less, because cache reads cost
  the same on both models and cache writes and output cost half. Spec quality is the open
  question.

## Options on any delegated task

Claude picks these from the spec. You can also ask for them.

| Option | Effect |
|---|---|
| `--verify "cmd"` | The harness runs it after each round, and a step only counts as done when it passes. Always give one. |
| `--hard` | Uses the high-effort model (`DELEGATE_MODEL_HARD`) for steps with real algorithmic content. |
| `--service postgres` | A throwaway database as `$DATABASE_URL`. Docker only. |
| `--read PATH` | Another repo mounted read-only (secret-looking files blanked), to port or imitate code from. |
| `--copy .env` | Copies an untracked config file into the worktree. Never committed. |
| `--github` | Lets the worker clone private repos with a read-only token. |
| `--orb .orb-target` | Access to a physical orb over serial and the real LAN, one orb per task. |
| `--egress open` | Allows the LAN when a task needs a LAN service. The default is model endpoint plus public internet only. |
| `--here` | Level 1: in place, native, unsandboxed, no commits. Not with `--service`, `--copy`, `--base` or `--github`. In a chain plan: `"here": true` (level 3h). |

In a chain plan (`delegate chain --help`), the same options go in the plan:
`"service"`, `"read"`, `"copy"`, `"orb"`, `"retries"`, `"timeout"`, `"here"`, plus `"hard"`
and `"verify"` per step.

## Watching and steering

- **Dashboard:** the llama dashboard's "Coding agents · live" card shows worker rounds and
  Claude sub-agents, with phase, plan and recent actions. This is how you watch, so Claude
  doesn't spend tokens doing it.
- **Ask Claude "how's it going?":** Claude runs one `delegate peek ID`, a snapshot of a few
  hundred tokens.
- **Change something:** tell Claude, not the worker. Claude sends
  `delegate continue ID -m "…"` into the same worker session, which keeps the review loop
  intact.
- **Stop:** "stop it", and Claude runs `delegate stop ID`. What the worker had done so far
  is committed (or snapshotted with `--here`) and reported as `aborted`.
- **Blocked:** the worker reports `STATUS: blocked` with QUESTIONS. The lead or Claude
  answers from the design, or brings them to you.

## Running it by hand

Everything Claude does is also available as plain CLI commands:

```bash
delegate run SPEC.md --verify "npm test" [--here]
delegate report ID          # the compact report of the last round
delegate diff ID [--full]   # diffstat, or the full diff
delegate continue ID -m "1. …" -m "2. …"
delegate chain plan.json    # a planned slice, unattended
delegate rm ID
```

`delegate --help` lists everything.
