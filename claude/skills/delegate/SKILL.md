---
name: delegate
description: The DEFAULT way to implement anything bigger than a small edit when the self-hosted `delegate` worker is available. The local model designs the slice (design doc, step specs, chain plan) and types the code; Claude orchestrates, reviews the plan, verifies the result and lands it. Use it whenever the user asks to delegate/offload/"send to the local model"/"use the worker", AND unprompted in ordinary conversation whenever you judge that the implementation savings outweigh the orchestration overhead (several files or steps, a slice of a written design, scaffolds, endpoints, tests, migrations, pattern-following refactors, ports). Not for tiny edits (under ~30 lines), debugging an unknown cause, urgent one-line fixes, or pure design discussion. Never unprompted for visual or audio design (looks, themes, art, icons, layouts, colour, typography, sound), those stay with Claude unless the user deliberately asks for them to be delegated.
---

# Delegating implementation to the local worker

You are the **orchestrator**: you own the design, the spec for each step, the review, and
the merge. The worker (an opencode agent on a self-hosted model, run by `delegate`) owns
the typing, inside its own worktree, on its own branch `delegate/<slug>`. It works under
strict rules (read first, plan, implement completely, verify by running, end with a
STATUS block) — your job is to give it a spec good enough that those rules produce the
right thing, and then to **not trust its claims** until you have checked them.

The point is to save your context and tokens. Every habit below exists for that: you
read the report, the diffstat and the risky files — not the transcript, not the whole diff.

**Not Claude Code?** Everything here is a `delegate` or `git` command, so any agent or harness
that runs shell commands can follow it, and the worker's model can be any OpenAI-compatible
endpoint. Read "in the background, you're notified" as "detach and poll `--status`", and
"delegate-lead" as "design that slice yourself". See `docs/harnesses.md` in the delegate repo.

## 0. Once per session

```bash
delegate doctor --quick      # endpoint, key, image, tool-calling probe
delegate list                # tasks already in flight
```

If doctor fails, stop and tell the user what failed — do not fall back to doing the
whole job yourself silently.

## The default workflow: the local model designs and builds, Claude orchestrates and verifies

This is the house default for any work worth delegating, whether the user asked for it or
not. Skip a phase only for a reason you can name.

**Phase 0: decide, and say so.**
- Delegate when the savings beat the overhead: several files or steps, a slice of a design,
  anything whose acceptance you can write as commands.
- Don't delegate: under ~30 lines, an unknown-cause bug, an urgent fix, or the user wanting it
  done by hand.
- **Never delegate design or audiovisual work unprompted.** Looks, themes, art, icons, layouts,
  colour, typography, motion and sound stay with you: designing them and producing them. This is
  where the local model is weakest (2026-11-11: its eight-look icon and plane art passed every
  test, but two sets failed at true size, and its look furniture drifted generic). Delegate it
  only when the user deliberately asks for that piece to be delegated. A slice that mixes both
  kinds is split: the worker builds the plumbing (code, tests, wiring) against art and look specs
  you wrote, and you do the visual part yourself.
- In conversation, when you choose this unprompted, say so in one line ("I'll hand this to the
  local worker: design, then a chain; I'll verify"), so the user can say no.

**Phase 1: the local worker designs the slice.**
- Run one design task (`--hard`) from a short brief built on [design-template.md](design-template.md).
  The brief has pointers (the design doc sections, the code, earlier specs to imitate), the
  fixed rules and constraints, and the out-of-scope list. It does NOT contain your own plan.
- **Give it the settled decisions it can't see.** The measured gap between the local model and
  a fresh Claude session writing the same spec was knowledge, not reasoning: its only misses
  were owner rulings recorded only in Claude's memory notes (LLM-Stats,
  `2026-11-spec-writers`). Before the design task:
  1. **A ruling that binds this slice and lives only in memory** goes into the repo's design
     doc (a numbered ruling, committed). That's durable for every later worker and reviewer.
  2. **The memory notes relevant to this slice** are mounted read-only with `--read` (for
     example `--read ~/.claude/projects/<project>/memory/<topic>.md`), and the brief lists them
     under "Read first".
     - **Mount specific notes, never the whole memory folder.** It covers every project,
       including infrastructure notes, and the worker has internet access.
     - **Skip a note that names secrets, keys or hosts the slice doesn't need.**
- The worker writes `docs/specs/<slice>-design.md`, one spec per step, and a
  `<slice>-chain.json`. Its verify fails if anything outside `docs/specs/` changed.
- Open choices go under `## Owner questions`, with the option it picked. It doesn't stop.

**Exception: a Claude lead designs instead.** Use the **`delegate-lead`** agent when the slice is
security-sensitive: auth, tokens, sandboxing, untrusted input or code, crypto, permission
models. Also use it when the local design fails your review twice. The lead writes the specs
and runs the chain itself.

**Phase 2: you review the plan (minutes, not hours).**
- Every step is under ~1500 lines and ~90 min.
- The `base` branch really exists, and its verify commands use the real toolchain.
- Spec paths resolve: the chain looks in the repo first, then next to the plan file, so a plan
  for another repo uses bare file names.
- Nothing in the plan contradicts the design's rulings.
- **Every step that guards a boundary runs `"hard": true`:** validating untrusted input,
  building commands or paths from it, auth or tokens, sandboxing, permission checks, crypto.
  Set it yourself when the plan doesn't. A local design marks steps by algorithmic
  difficulty only: in one measured slice it ran the command runner and the security step on
  the normal model, and every bug that reached review sat in exactly those two steps.
- Accept each owner question or change it, and log the call. Fix the plan in place, and commit
  it to the design branch.

**Phase 3: run the chains.**
- Start `delegate chain PLAN.json` as a **tracked background task** (the Bash tool's background
  mode), one per slice, so the session is told the moment it exits. Never with a shell `&` inside a
  foreground command: nothing tracks that, and the chain can finish unseen for hours. Independent
  slices run in parallel, with at most ~3 worker tasks on one GPU across all chains.
- **Resuming** after answering a step (`delegate continue … ; delegate chain …`) is the same: one
  tracked background task. If a chain is already running untracked, start `delegate wait PLAN.json`
  as a tracked background task: it blocks only its own process until the chain stops (exit 0 all
  done, 3 blocked or failed, 124 on `--timeout`). Never run `delegate wait` in the foreground of a
  conversation, and never hand-roll a watcher with `pgrep -f '<text>'`: it matches its own command
  line and never returns.
- **In a harness with no background-completion notification** (OpenCode, Cline, plain shells):
  run the chain detached **and with the wake-up hooks** — `--on-step 'CMD' --on-done 'CMD'`
  (env fallbacks `DELEGATE_ON_STEP` / `DELEGATE_ON_DONE`) — so the chain reports back instead of
  the session polling. `--on-step` fires when a step is accepted (`$DELEGATE_CHAIN_STEP`,
  `$DELEGATE_CHAIN_STEP_N`, `_STEP_TOTAL`, `_DELEGATE_CHAIN_STATUS`), `--on-done` when the run
  ends (`$DELEGATE_CHAIN_RC`, `_STATUS`). Let the hook wake *you* where the harness allows it —
  for opencode that is `delegate-wake` (on PATH after install; `--url` or `$DELEGATE_WAKE_URL`
  for a non-default server; it posts a fixed-template prompt into the session — opencode 2's
  `/api/session/<id>/prompt`, falling back to opencode 1's `/session/<id>/prompt_async`), and you
  verify and relaunch the chain from that turn; otherwise let it ping the person (ntfy, desktop).
  On opencode 2 your own session id is `$OPENCODE_SESSION_ID` and the server password is in
  your environment, so a bare `delegate-wake` needs no arguments; on opencode 1 the id is not in
  the environment — read it from `GET <server>/session?directory=<repo dir>` (the newest session
  is you) and pass it as `delegate-wake SESSION_ID`, with `DELEGATE_WAKE_URL` exported. Idempotent and cheap only: a resumed chain fires `--on-done` again at its next
  terminal exit, a killed one never fires, and a failing hook is a warning line, never a changed
  outcome — so the hook says *when to look* and `--status` stays the source of truth.
- Base each chain on the design branch, so the `Plan:` commit travels with the slice.
- Steps that need a special toolchain run with `DELEGATE_IMAGE=<image>` exported.
- Don't watch. You act on the end-of-chain report.

**Phase 4: verify, yourself, once per slice.** This is where the value is. On the project this was measured on,
the bugs that mattered were all found here.
- **Diffstat:** look for files outside the slice, especially files another branch or a fix of
  yours already changed. A worker may copy a fix it found on `main`; byte-identical copies drop
  out in the squash.
- **The risky code, line by line:** auth, tokens, permission checks, anything parsing an
  upload or untrusted input (size caps that ignore chunked bodies, unbounded unpacking), CI
  workflows (a step's own `env` isn't visible to its `if:`), and router or edge-auth changes.
- **The full gate**, on a clean squash of the slice onto its real base, not the worker's
  word: typecheck, lint, every test, build.
- **One live check with real binaries and real inputs**, not only stubs. Example: build the
  real tool and feed it a real artifact made by the real SDK.
- **When you fix something,** add a test and prove it fails without the fix.
- **A red test you didn't expect:** run it many times on the untouched base before blaming the
  slice. If it's flaky there too, file it, don't fix it in the slice.
- **Deploy gaps:** check compose files that list env vars one by one. A new setting that isn't
  in the list never reaches the app.

**Phase 5: land, and log.**
- Squash onto a NEW local branch named for the slice, cut from the right base. Use the repo's
  commit style.
- No push, no merge into `main`, and no deploy unless the user asked.
- Clean up with `delegate chain … --clean`, `delegate rm`, and by deleting the `delegate/*`
  branches.
- When the user is away, append every decision and its reason to a log file they will read,
  newest at the bottom, with a summary at the top.

**In place:** when the user says "in place" or "I'm watching", run that one slice's chain with
`"here": true` in their checkout. Each accepted step is committed on their current branch, with
no worktrees and no squash. Only one in-place slice per checkout at a time.

The single-task sections below are still right for one-off tasks, and they are what each chain
step does under the hood.

## 1. Decide what to delegate

Delegate a step when you can write its acceptance criteria as commands. Good fits:
scaffolding, a route/page/component per a written contract, schema + migration + seed,
tests for existing behaviour, a pattern-following refactor, porting code, glue.

Keep for yourself: the decisions the user owns (and the calls on owner questions),
reviewing the plan, verifying the result, security-sensitive cores (auth flows, crypto,
permission checks: a Claude lead specs them and you review them line by line), debugging
where the cause is unknown, anything under ~30 lines (the spec would cost more than the
edit), and visual or audio design and production (looks, art, icons, layouts, colour, type,
sound) unless the user asks for it to be delegated. A slice's ordinary engineering design work
goes to the local worker (Phase 1 above).

Split a big slice into steps of roughly **one coherent change, < ~1500 lines of diff,
< ~90 min of worker time**. Independent steps can run in parallel (separate tasks, max ~3
at once against one GPU); dependent steps run in sequence, each `--base` on the previous
step's branch.

## 2. Write the spec

Write it to a file (scratchpad, or `.delegate/` in the repo if the user wants them kept).
Use `spec-template.md` beside this file. What makes or breaks a run:

- **Read-first list.** Exact paths: the design-doc section, the files to imitate, the
  types/schemas it must use. The worker is good at following existing patterns and bad at
  guessing which ones you meant.
- **Contract, verbatim.** Names, routes, function signatures, table/column names, env var
  names, error shapes, copy text. Anything you leave open the worker will decide, and you
  will review its decision.
- **Acceptance criteria as commands** + expected outcomes. These become `--verify`.
- **Out of scope**, explicitly — including "do not touch X" for nearby files.
- **No secrets** in the spec. Use `--copy .env` for untracked config the code needs.

## 3. Run it — in the background

```bash
delegate run SPEC.md --repo /path/to/repo --name <short-slug> \
  --verify "npm ci && npm run typecheck && npm test" \
  [--base <branch>] [--copy .env] [--service postgres] [--hard]
```

- **Always `run_in_background: true`** — a round takes minutes to over an hour. You are
  notified when it exits; do not poll, do not sleep. Meanwhile do other work (write the next
  spec, review another task).
- `--service postgres` gives the task a throwaway Postgres as `$DATABASE_URL` (Prisma etc.).
- `--read PATH` mounts another checkout read-only (secret-looking files blanked) — use it
  when the step ports or imitates code from another repo, instead of pasting code into the spec.
- `--github` (only if `DELEGATE_GITHUB_TOKEN_FILE` is configured) lets it clone private repos.
- **Access beyond the sandbox is a grant** (`--grant NAME`, chain plan `"grants"`; see
  `docs/grants.md` in the delegate repo): a profile the user wrote in `~/.config/delegate/grants/`,
  for a device, a LAN service, extra mounts or env. `delegate grant list` shows them, and
  `delegate grant show NAME` shows exactly what one does. Never write or edit a grant file
  yourself: grants are the user's decision. A guarded command (for example flashing) stays
  refused unless the task has `--allow GUARD`, and only add that when the spec really needs it.
  `--orb .orb-target` is the built-in grant for a physical orb (host network, its own serial
  port, a lock per orb, flashing guarded unless `--allow flash`). Say in the spec exactly what
  the worker may do to a device.
- The worker's network is filtered by default: model endpoint + public internet, no LAN.
  `--egress open` only when the task genuinely needs a LAN service, and say so to the user.
- `--hard` uses the high-effort model variant — for steps with real algorithmic content, and
  by default for any step that guards a security boundary (see Phase 2).
- The task id is `<repo>-<slug>`; the command prints a report when the round ends.

### Supervised, in place (`--here`)

When the user says they're watching, wants it "local", "in place", "in my checkout", or "no
sandbox", add `--here` (with no design doc, a short spec written from their request is
enough). The worker then edits the user's checkout directly, natively and unsandboxed: no
worktree, branch, container, egress proxy or commits, so changes show up live in their
editor. Each round is recorded as a snapshot ref (`refs/delegate/<slug>/r<n>`, made with a
throwaway index, so their index and branch are untouched), and `report`, `diff`
(`--round N`, or the live tree by default), `continue -m`, `stop` and `peek` work as usual.
The user's own uncommitted changes are in the base snapshot, so diffs show only the worker's.
Not with `--service`, `--copy`, `--base`, `--github`, or `delegate chain`; one in-place task
per checkout at a time. Review it as below; when it's accepted, leave the changes uncommitted
for the user (or commit if they ask) and `delegate rm ID` (drops only the snapshot refs).

### Raw: Claude is only a pipe (`/delegate raw: …`)

When the request starts with `raw:` (e.g. `/delegate raw: …` or `/delegate raw here: …`), you
are a pass-through, nothing more. Everything after `raw:` (after `here:` when both are given)
goes to the worker **verbatim**: don't rewrite it, add to it, write a spec, read code, or
review anything. Send it on stdin with a quoted heredoc so the shell changes nothing:

```bash
delegate run - --raw [--here] --name raw-<short-slug> --repo <repo> <<'DELEGATE_RAW_EOF'
<the user's text, exactly>
DELEGATE_RAW_EOF
```

Run it in the background as usual. When it ends, its stdout is the worker's last message,
verbatim: reply with exactly that text and nothing else (no summary, no commentary, no
"here is the response"); the one exception is when the run failed, then say so in one line
with the stderr's last lines. Location as for any task: `here` (or "in place", "I'm
watching") adds `--here`, otherwise the isolated worktree. No `--verify` unless the user's
text asks for one.

**Follow-ups:** while a raw task from this conversation exists, a later `raw: …` continues
it (same worker session, it remembers): `delegate continue <id> --raw - <<'DELEGATE_RAW_EOF'`
… with the text verbatim, printed back verbatim the same way. `raw new: …` starts a fresh task
instead. Leave the task in place afterwards (the user may follow up); `delegate rm` it only
when asked, or when the user moves on to other work in this repo.

## 4. Review — cheap first, then deep where it matters

1. **Read the report** it printed (`delegate report ID` to see it again). Check, in order:
   harness STATUS (`done` / `partial` / `blocked` / `no-status` / `worker-error` /
   `timeout` / `truncated` / `done-but-verify-failed`), the verify exit code and tail, failed
   tool calls, the NOTE line on in-session nudges (malformed tool calls the harness retried),
   unfinished todo items, then the worker's FILES (anything marked `unrequested:`),
   DEVIATIONS / DECISIONS / OMISSIONS / NOT VERIFIED. A **SECURITY** line means the worker
   tampered with git plumbing: read that round's whole diff and tell the user.
2. **Verify yourself — never accept "VERIFIED" lines on faith.** `delegate verify ID`
   re-runs the verify command; `delegate exec ID -- <cmd>` runs anything in the worker's
   toolchain (use this when the host lacks node/python/etc.), e.g. a curl against a started
   server, a single test file, `npx prisma migrate status`.
3. **Diffstat**: `delegate diff ID`. Look for files outside the spec's scope, deleted or
   weakened tests, lockfile churn, giant generated files, stray debug files.
4. **Read selectively**: `delegate diff ID -- path/one path/two`. Always read in full:
   auth/permission code, migrations, anything handling secrets or user input, public API
   contracts. Skim or sample the rest. Don't read lockfiles or generated code.
5. For UI work, open the screenshots the worker cites under the evidence dir (Read tool on
   the PNGs) — cheaper than reasoning about CSS.

## 5. Iterate — feedback rounds

Write numbered, concrete feedback (file:line, what is wrong, what right looks like) to a
file, then in the background:

```bash
delegate continue ID FEEDBACK.md [--verify "..."]
delegate continue ID -m "fix X in a.ts:40 — …" -m "add a test for Y"   # short follow-ups, one -m per item
```

Same worker session, so it remembers its work; each round is one more commit. Budget:
**at most 3 feedback rounds.** If round 3 still isn't right, the spec was wrong or the task
too big — fix the remaining issues yourself in the worktree, or re-scope into a new task.
A `blocked` status means it needs a decision: answer its QUESTIONS (ask the user if it is
genuinely their call) and continue.

## Watching and stopping

**Do not watch a running round.** Its output costs your context and you cannot act on it
mid-round anyway. You act on the report. The **user** watches live rounds on the llama dashboard
("Coding agents · live" card: plan, activity feed, tokens), which the harness feeds by itself.

**Only when the user asks** how a round is going, answer with one `delegate peek ID`. It prints
the same compact snapshot as the dashboard (state, elapsed, steps, tool calls, tokens, the
worker's plan, the last few actions) in a few hundred tokens. Summarise it in a sentence or two.
Never peek on your own initiative, never repeat it to wait for progress (the end-of-round
notification does that), and never read `events.jsonl` instead.

If the user asks you to stop a round, or a round is clearly wrong (for example the user says
so from the dashboard), run `delegate stop ID`. The round ends as `aborted`, the worker's
partial work is still committed, and its report is printed by the `run`/`continue` you started.
Then fix the spec or send numbered feedback. Follow-ups always go through you, never around
you, so your picture of the task stays true.

## 6. Land it

The work is on branch `delegate/<slug>` in `$WORKTREE`, one commit per round. When it
passes your review:

```bash
git -C <repo> merge --squash delegate/<slug> && git -C <repo> commit   # or cherry-pick / rebase as the repo prefers
delegate rm ID --delete-branch                                          # worktree, sidecar db, state
```

Follow the repo's own commit conventions for the squash message and describe what the
change does — not who typed it. Only commit/merge when the user has asked you to; otherwise
report the branch as ready for their review.

## 7. Reporting to the user

Per task: what was delegated, rounds used, what you verified yourself (commands), what you
fixed by hand, and anything the worker flagged that still needs a decision. Be plain about
failures — a `partial` that you finished yourself is fine to report as such.

## Don'ts

- Don't `cat` events.jsonl or prompt.md — they are huge; the report already has what matters.
- Don't edit files in a worktree while a round is running on it.
- Don't delegate work on stacks the worker must not touch (production deploy dirs,
  infrastructure that serves the model itself).
- Don't paste secrets, tokens or production data into specs or feedback.
