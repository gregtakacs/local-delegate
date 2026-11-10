# local-delegate: full reference

Use Claude Code (or yourself) as the **architect and reviewer**, and a **self-hosted coding
model** as the implementer. You write a spec; `delegate` hands it to an
[opencode](https://opencode.ai) agent running against any OpenAI-compatible endpoint, in a
fresh git worktree on its own branch; you get back a compact report, a branch with one commit
per round, and a way to send review feedback into the same agent session.

All you need on the server side is an **OpenAI-compatible `/v1` endpoint with tool calling,
and an API key** (vLLM, SGLang, llama.cpp server, LM Studio, Ollama's `/v1`, LiteLLM, a
hosted provider...). On the client side: git, curl, python3, and either Docker (recommended)
or opencode.

```
Claude Code (orchestrator)                       worker container (per round)
  writes spec.md ──► delegate run ──► git worktree + branch delegate/<slug>
                                       opencode run  ──HTTPS /v1──►  your model server
                                       (rules: read → plan → build → verify → STATUS block)
                     ◄── report: STATUS, verify result, diffstat, failed tool calls, the
                         worker's own closing block (VERIFIED / DEVIATIONS / OMISSIONS ...)
  reviews: delegate diff / exec / verify
  delegate continue <id> feedback.md  ──► same session, next round, next commit
  merge --squash delegate/<slug>; delegate rm <id>
```

Why it saves tokens: the orchestrator never reads the worker's transcript. It reads a spec it
wrote, a report of ~100 lines, a diffstat, and the specific files it decides to review.

**Which level of delegation to use** (supervised in place, single task, slice lead, hub), with example prompts: [docs/levels.md](levels.md).

## Why the worker is strict

A local model in a stock agent harness tends to one-shot the task, skip running it, and
declare victory. The worker here runs with rules and plugins that were ported from a
long tuning effort to make opencode behave like stock **Cline** on the same model, which
produced markedly more complete and better-checked work:

- `opencode/delegate-rules.md`: the operating rules. A turn without a tool call ends the task. Read first,
  probe the environment. A Definition of Done that has to be *proved by commands*. Plan with
  TodoWrite. Bounded fix loops that may never weaken a test. "Complete inside the scope, restrained at its
  edge". A required closing block (`STATUS / FILES / VERIFIED / NOT VERIFIED / DEVIATIONS /
  DECISIONS / OMISSIONS / SUGGESTIONS / QUESTIONS / EVIDENCE`) that the harness parses.
- `opencode/plugins/chunk-cap.js`: a letter-port of Cline's editor size gate. `write`/`edit` payloads over 6000
  characters are rejected with Cline's own message. This forces skeleton-then-grow instead
  of one giant write, which is where most of the missing features came from.
- `opencode/plugins/todo-loop.js`: nudges the model to keep its todo list current (and survives
  context compaction).
- `opencode/plugins/verify-loop.js` + `opencode/rules/verify-ui.md`: any UI change has to be checked
  by **screenshots the model reads back**, via `delegate-shot` (headless chromium in the image),
  across states and viewports.

## Install

```bash
git clone <this repo> ~/src/delegate && cd ~/src/delegate
./install.sh --base-url https://llm.example.com/v1 --model qwen3-coder --key-stdin <<< "$MY_API_KEY"
```

`install.sh` links `delegate` into `~/.local/bin`, links the Claude Code skill into
`~/.claude/skills/delegate`, and writes `~/.config/delegate/config.env` (it never overwrites an existing one).
It then builds the worker image and runs `delegate doctor --quick`. Review the config afterwards:
[config.example.env](../config.example.env) documents every setting.

`delegate doctor` checks the config, the image, which endpoint answers, and **sends a real
tool call, both streaming and non-streaming**. It fails if the call comes back as text in `content`
(unparsed or "phantom" tool calls) or if its arguments aren't valid JSON. Fix those before
trusting any agent on the endpoint.

### Runners

| `DELEGATE_RUNNER` | Worker runs as | Gets | Use when |
|---|---|---|---|
| `docker` (default) | `delegate-worker` image: node 24 + corepack, python3, git, psql, chromium, opencode (pinned) | the task worktree, the repo's git dir, an evidence dir, the key (read-only). **No** docker socket, home dir, SSH keys or root | almost always. Also required for `--service postgres` |
| `native` | `opencode` from your PATH, as you, with a per-task `HOME` | everything you can reach (the file tools are fenced to the worktree, `bash` is not) | no Docker available, and you trust the model with your user account |

**Supervised, in place: `delegate run SPEC --here`.** For when you're watching. The worker
edits your current checkout directly, with the native runner, whatever `DELEGATE_RUNNER`
says: no worktree, branch, container, egress filter or commits, so changes appear live in your
editor and stay uncommitted. Each round is kept as a snapshot ref (`refs/delegate/<slug>/r<n>`,
made with a throwaway index: your index and branch are never touched), so `report`, `diff`,
`continue`, `stop` and `peek` work as usual and your own uncommitted edits stay out of the diff.
`delegate rm` deletes only those refs. One in-place task per checkout; not with `--service`,
`--copy`, `--base` or `--github`. A chain plan with `"here": true` runs a whole slice this way,
committing each accepted step on your current branch (see [docs/levels.md](levels.md), level 3h).

## Use it by hand

```bash
delegate run spec.md --repo ~/src/app --name add-handles \
    --verify "npm ci && npm run typecheck && npm test" --service postgres --copy .env
#   ... minutes later: the report (also: delegate report app-add-handles)
delegate diff app-add-handles                  # diffstat since base
delegate diff app-add-handles -- src/auth.ts   # content of chosen files
delegate exec app-add-handles -- npx prisma migrate status
delegate continue app-add-handles feedback.md  # next round, same session
git -C ~/src/app merge --squash delegate/add-handles && git -C ~/src/app commit
delegate rm app-add-handles --delete-branch
```

| Flag | Meaning |
|---|---|
| `--base REF` | branch the worktree from REF (default: the repo's current branch). Chain dependent steps by basing on the previous task's `delegate/<slug>` |
| `--verify CMD` | run after every round in the worker environment. The exit code and log tail go into the report, and the worker is told to run it first |
| `--copy PATH` | copy an untracked file (e.g. `.env`) from the main checkout. It is never committed |
| `--read PATH` | mount another checkout read-only, for reference (e.g. code to port). Secret-looking files in it (`.env*`, `*.pem`, `*.key`, `credentials*`, `*token*`, `secrets/`, `.ssh/`...) are blanked |
| `--github` | let the worker clone private GitHub repos and call the API with `DELEGATE_GITHUB_TOKEN_FILE`. Use a fine-grained **read-only** token |
| `--egress filtered\|open` | network policy for this task (default `DELEGATE_EGRESS=filtered`, see Security model) |
| `--service postgres` | a throwaway Postgres just for this task, as `$DATABASE_URL`. Removed by `delegate rm` |
| `--hard` | use `DELEGATE_MODEL_HARD` (e.g. a high-reasoning-effort variant) |
| `--timeout S` | wall-clock limit for the round (default `DELEGATE_TIMEOUT`, 90 min) |

`delegate peek ID` prints a compact snapshot of the current round (state, steps, tool calls,
tokens, the worker's plan, the last few actions). It's about 250 tokens, compared with the raw
event log's tens of thousands, so an orchestrator can answer "how's it going?" cheaply.

Follow-ups: `delegate continue ID -m "first item" -m "second item"` (each `-m` is one numbered
item), or a file, or `-` for stdin. `delegate stop ID` aborts a running round. The worker's
partial work is still committed, and the round reports as `aborted`.

### Grants: named access beyond the sandbox (`--grant NAME`)

Everything a task may reach beyond the default sandbox is a **grant**: a TOML file you write in
`~/.config/delegate/grants/<name>.toml` (or `$DELEGATE_GRANTS_DIR`). A task gets it with
`--grant NAME` (repeatable), or `"grants": [...]` in a chain plan, at plan or step level. The full
design is in [docs/grants.md](grants.md).

```toml
# ~/.config/delegate/grants/printer.toml
brief = "You may print test pages on the office printer at http://printer.lan:631/."
lock = "printer"                       # one task at a time
[network]
mode = "allow"                         # filtered (default) | allow | open | host
allow = ["printer.lan:631"]            # allow: just these LAN destinations, through the task's own proxy
[devices]
paths = []                             # exact devices; reenumerate = true for boards that re-enumerate on reset
[mounts]
ro = []                                # read-only, secrets blanked like --read
rw = []
[env]
PRINTER_URL = "http://printer.lan:631"
[guards.purge]                         # commands refused unless the task has --allow purge
commands = ["lpadmin"]
args = ["-x"]                          # refuse only these arguments (glob patterns); omit to refuse always
note = "Removing printers is blocked."
```

- **Trust:** grants are read only from that folder, which must be yours and not writable by
  anyone else. They're never read from a repo, so a worker can't grant itself anything.
  Unknown keys are an error.
- **Network:** the widest mode asked for wins, and the report says which grant asked.
  - `allow` gets the task its own proxy, which passes the model endpoint, the public internet
    and exactly the listed LAN hosts, ports and CIDRs. It covers HTTP and HTTPS only.
  - `host` is the host's network, unfiltered. Use it for mDNS, ARP and raw sockets.
- **Devices:** each path gets its own cgroup rule. With `reenumerate = true`, the live `/dev` is
  mounted and the rule covers that device's major only (166 for ttyACM, 188 for ttyUSB), never
  other kinds.
- **Guards:** a shim for each guarded command, first on PATH in **both** runners, refuses and logs
  to the evidence dir's `guard-refused.log`; the report flags it. `--allow NAME` lifts a guard.
  It's a guard, not a sandbox: a full path still reaches the binary, and the worker is told so.
- **Locks and probes:** a lock key admits one task at a time. A probe (a serial port, or an HTTP
  URL) is checked at each round start, and the worker is told the result.
- **Checking a grant:** `delegate grant list` shows every grant and whether it's valid.
  `delegate grant show NAME [--allow G]` prints the docker args, read-only paths, locks and
  prompt lines it would produce, without running anything.
- **`continue` keeps a task's access:** it refuses `--grant`, `--allow` and `--orb`.
- **Native and `--here` tasks** already run as you, so only a grant's env, brief, guards, locks
  and probes apply there.

### Physical devices: `--orb .orb-target` (the built-in orb grant)

`--orb FILE` (or `"orb"` in a chain plan) is the built-in grant for an orb on USB serial and the
LAN. A grant file can name it too, with `kind = "orb"` and `target = "/abs/path/.orb-target"`, so a
chain plan can say `"grants": ["orb-desk"]`. It **parses** the `.orb-target` (`ORB_LABEL`,
`ORB_BASE_MAC`, `ORB_SERIAL`, `ORB_IP`) and never executes it. For that task:

- **Network:** `host`, so HTTP to the orb, mDNS and `ip neigh` (re-proving the IP against the MAC)
  work. The egress filter doesn't apply.
- **Serial:** the live `/dev`, with access limited to **that port's own** device major, so
  `/dev/serial/by-id/...` survives the reset a flash causes. If the port isn't attached when the
  task starts, it falls back to both serial majors, as before grants.
- **One task per orb**, with a lock keyed by MAC. Each round's prompt gives the port's state:
  attached and free, held by another process (named; the worker must not kill it and reports
  `blocked`), or not attached.
- **Flashing is guarded** unless `--allow flash` (`--orb-flash` still works as a shorthand):
  `esptool`, `esptool.py` and `idf.py` refuse any write, erase or flash in **both** runners. The
  prompt says a blank or unbootable board means `STATUS: blocked`. (A worker facing a blank board
  once flashed it over USB and rewrote its partition table.)
- `.orb-target` is copied into the worktree if git doesn't track it, and never committed.

Can't be combined with `--service`. On WSL, attach the board with usbipd-win
(`usbipd attach --wsl --busid X --auto-attach`), and use Docker Engine installed **inside** the
distro: host networking must mean WSL's network, and that network must reach the LAN (WSL
"mirrored" networking) for mDNS and `ip neigh` to see the orb.

### Chains: a whole slice, unattended

`delegate chain PLAN.json` runs a planned list of steps (each with a spec and a verify command)
one after another, each on the previous step's branch. A step is accepted only when the worker
says done **and** its verify command passes. Otherwise the failure (the verify output tail, or
what went wrong) goes back into the same session, up to `retries` times. The chain stops with
exit 3 on `blocked` or when a step keeps failing, and re-running resumes from that step.
`--status` shows where it is and `--clean` removes the chain's tasks. The `delegate-lead`
Claude Code agent (`claude/agents/`, installed by `install.sh`) uses this: it plans the
slice once, runs the chain, and checks the result once.

### Watching live rounds

**Off by default.** With `DELEGATE_PROGRESS=1`, while a round runs the harness posts compact
progress snapshots, plus the round's full prompt and report, to
[stackd](https://github.com/gregtakacs/stackd)'s dashboard (`POST /agents/progress`, with the same
key as the model traffic). Only turn it on for an endpoint you run yourself. A snapshot holds: phase, steps, tool calls,
tokens, the worker's todo list and a feed of its recent tool calls. stackd's dashboard shows
them in a **Coding agents · live** card, admin-only and read-only, which is only there while
something runs. A finished round stays 15 minutes with its final status (its phase is set to that status too). It works from any
machine that can reach the endpoint. `DELEGATE_PROGRESS_URL`
and `DELEGATE_PROGRESS_KEY_FILE` point it elsewhere. The endpoint is stackd-specific: on another
server the reporter logs one warning to the round's `progress.log` and the round carries on.

The **harness status** in the report is computed, not copied from the worker. It is
`timeout` or `worker-error` if the run broke, `done-but-verify-failed` if the worker said done but your
verify command failed, and `no-status` if the closing block is missing. Otherwise it is the worker's
`done`/`partial`/`blocked`.

State per task lives in `~/.local/state/delegate/<id>/`: `spec.md`, `meta.env`, and
`rounds/<n>/` holding `prompt.md`, `events.jsonl`, `stderr.log`, `verify.log`, `report.md`, `report.json` and `commit`.
The worker's home dir holds its opencode session, and `evidence/` holds its screenshots.

### Watching the Claude agents too

Background Claude agents (the ones that plan, spec and review delegate work) can report to
the same dashboard card through a Claude Code hook: `claude/hooks/agent-progress.py`, installed
with `./install.sh --claude-hook` (adds async `PostToolUse`, `PostToolUseFailure` and
`SubagentStop` hooks to `~/.claude/settings.json`). It reports only **subagent** tool calls,
never your main conversation. Each agent appears as "<description> · <id>" with a *Claude
agent* label, its plan, tool calls and a feed of what it's doing, and a final "finished" when
it stops. Give it its own key (`DELEGATE_AGENT_HOOK_KEY_FILE` in the config, an inference key)
so the dashboard can tell it apart from worker rounds.

## Use it from any agent or harness

The CLI is the whole interface, so any orchestrator that runs shell commands can drive it:
Codex, OpenCode, Cline, Aider, a CI job, or you. Likewise, any OpenAI-compatible `/v1` endpoint
with working tool calls can be the worker's model (vLLM, SGLang, llama.cpp, Ollama, LM Studio,
LiteLLM, OpenRouter, OpenAI). [docs/harnesses.md](harnesses.md) covers the command protocol,
polling when your harness has no background notifications, and how to read the Claude-specific
parts of the skill. [AGENTS.md](../AGENTS.md) points other coding agents at all of it.

## Use it from Claude Code

Installing the skill ([claude/skills/delegate/SKILL.md](../claude/skills/delegate/SKILL.md))
makes this the **default way Claude implements anything bigger than a small edit**, whether
you ask for it or not. When it picks it unprompted, it says so in one line, so you can say no.

1. **The local model designs the slice.** One design task, from
   [design-template.md](../claude/skills/delegate/design-template.md), writes the slice design, the
   step specs and a chain plan. Security-sensitive slices are designed by a Claude lead
   (the `delegate-lead` agent) instead.
2. **Claude reviews the plan:** step sizes, real base branches and toolchains, and the owner
   questions, each logged.
3. **The chains run on the local worker**, unattended, slices in parallel.
4. **Claude verifies once per slice:**
   - the risky code, line by line;
   - the full gate on a clean squash;
   - one live check with real binaries;
   - each fix proven by a test that fails without it.
5. **It lands on a local branch per slice.** It is pushed, merged or deployed only when you
   ask, and every decision is logged when you're away.

Typical prompt (or just describe the feature):

> Implement slice W2 from docs/design.md.

On a machine with no node (or other toolchain), `delegate exec <id> -- <cmd>` is how Claude
runs tests, typechecks and servers in the worker's environment.

## From another machine (e.g. a laptop on WSL)

The worker runs **where the files are**, so only model traffic crosses the network.

1. Inside WSL (not Windows): install Docker (Docker Desktop with WSL integration, or
   docker-ce in the distro), then clone this repo and run `install.sh`. Use
   `--runner native` if you'd rather install opencode than Docker.
2. Run VS Code with the **WSL remote** ("WSL: <distro>" in the status bar), so Claude Code's
   shell is the WSL one and finds `delegate`.
3. Keep repos on the Linux filesystem (`~/src/...`), not `/mnt/c/...`. Worktrees and file
   watching across that boundary are very slow.
4. List the LAN URL first and the public one second in `DELEGATE_BASE_URLS`. Each run uses the
   first that answers.
5. Give each machine its own API key, so usage is attributable and keys can be revoked separately.

**Behind Cloudflare (or any proxy with an idle timeout):** opencode streams, which keeps the
connection alive, so long generations are fine. Non-streaming requests longer than 100s would
get a `524`. `delegate doctor` exercises both paths.

## Cleaning up

Tasks stay until removed, so follow-ups work any time later. `delegate run` removes tasks idle
for `DELEGATE_PRUNE_DAYS` (default 14, `0` turns it off) by itself; by hand:

```bash
delegate prune --dry-run            # what would go, and how big it is
delegate prune --days 3             # remove tasks idle 3+ days (branches kept)
delegate prune --days 0 --delete-branch --caches   # everything not running, their branches, shared caches
```

Native and `--here` tasks share one cache directory (`~/.cache/delegate/native`), so a Go or
npm cache is built once, not once per task.

## Security model

The worker is treated like an unattended contractor, not like you. It runs for up to an
hour with nobody watching each step, it reads untrusted text (dependencies, web pages, cloned
repos) that can carry prompt injections, and a model error in a long context can be destructive.
So it gets exactly what the task needs.

- **Files:** read-write only in its worktree, its evidence dir and its own home. The repo's shared
  `.git` is mounted **read-only**: a writable one would let it plant a hook or `core.fsmonitor`
  that runs on the host at the harness's next commit. Host-side git on a worktree pins
  `--git-dir`, disables hooks and fsmonitor, and restores (and flags) a tampered `.git` pointer.
- **No** docker socket, root, capabilities, devices (GPU/USB), host home or SSH keys.
- **Network (`DELEGATE_EGRESS=filtered`, the default):** each task's network is `--internal`.
  The only way out is the `delegate-egress` proxy, which allows the model endpoint host(s) and the
  public internet, and refuses private ranges, the docker host and link-local/metadata, judged by the
  resolved address. `docker logs delegate-egress` shows every request. Residual risk: the model
  host's own IP is reachable on 443. If that host is a reverse proxy fronting other LAN services, a
  worker could ask for those by name (SNI/Host) on the same IP. `--egress open` gives a plain
  bridge, LAN included. The native runner is not filtered at all.
- `--read` checkouts are read-only, with secret-looking files blanked; `--github` is opt-in per task.
- The API key is mounted read-only and read by opencode at request time. It never
  appears in the rendered config, argv or the event log.
- The worker never commits, pushes or switches branches (its rules forbid it, and the harness does
  the commits). Pushing and merging stay with you or the orchestrator.
- Don't point it at repos whose working tree *is* production (deploy dirs, live infra
  config). Delegation is for code that goes through review.

## Measuring changes

`evals/` holds five fixed tasks with hidden checks: a spec-strict library, a Postgres data layer,
a UI, a bug-fix batch and a 60-module long-context refactor. `evals/run.sh --rules-ref REF`
runs them against any revision of the worker rules. See [evals/README.md](../evals/README.md).

## Troubleshooting

- `unknown model` — `DELEGATE_MODEL` must match an id from `curl -H "Authorization: Bearer $KEY" $BASE/models`.
- Report says `worker-error` with an API error — check the stderr tail in the report, then
  `delegate doctor`. A "System message must be at the beginning" error from a vLLM chat
  template means something injected a second system message. The plugins here deliberately don't.
- The worker hit the context limit, or slows down late in long rounds — lower `DELEGATE_CONTEXT`
  (opencode compacts earlier) or split the task.
- `task ... is busy` after a crash — `rmdir ~/.local/state/delegate/<id>/lock`.
- Stray containers — `docker ps --filter label=delegate.task`.

## Layout

```
bin/delegate                  the CLI (bash)
lib/report.py                 events.jsonl + git + verify -> report.md / report.json
lib/probe.py                  tool-calling probe used by doctor
lib/render-opencode-config.py DELEGATE_* env -> opencode.json (one provider, key by file)
opencode/                     worker rules, UI-verification rules, plugins (mounted live into
                              the container: edit them without rebuilding the image)
worker/                       Dockerfile, entrypoint, delegate-shot
claude/skills/delegate/       the Claude Code skill + spec template
```
