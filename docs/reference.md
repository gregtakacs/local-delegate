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

A worker in a stock agent harness tends to one-shot the task, skip running it, and
declare victory. The worker here runs with rules and plugins that were ported from a
long tuning effort to make opencode behave like stock **Cline** on the same model, which
produced markedly more complete and better-checked work:

- `opencode/delegate-rules.md`: the operating rules. A turn without a tool call ends the task. Read first,
  probe the environment. A Definition of Done that has to be *proved by commands*. Plan with
  TodoWrite. Bounded fix loops that may never weaken a test. "Complete inside the scope, restrained at its
  edge". A required closing block (`STATUS / FILES / VERIFIED / NOT VERIFIED / DEVIATIONS /
  DECISIONS / OMISSIONS / SUGGESTIONS / QUESTIONS / EVIDENCE`) that the harness parses.
- `opencode/plugins/chunk-cap.js`: a letter-port of Cline's editor size gate. `write`/`edit` payloads over
  `DELEGATE_CHUNK_CAP` characters (default 8000; Cline's own value is 6000) are rejected with
  Cline's own message. This forces skeleton-then-grow instead
  of one giant write, which is where most of the missing features came from.
- `opencode/plugins/todo-loop.js`: nudges the model to keep its todo list current (and survives
  context compaction): once at the first file change made with no list, once at 12 calls with no
  list, and every 8 calls while a list is stale. `claude/hooks/todo-loop.py` is the Claude Code twin.
- The four plugins are OpenCode 2 plugins (a default-exported `{id, setup}` registering `tool.hook`,
  `tool.transform` and `session.hook`); OpenCode 1 cannot load them. `delegate doctor` reads OpenCode's log
  to confirm they loaded, and the install turns on `experimental.todo` (2.x ships `todowrite` off).
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

Release installs pin a tag instead of installing whatever a working copy happens to contain:

```bash
./install.sh --release v0.1.1 [--repo URL | --from DIR] [any install flags above]
./install.sh --uninstall   # remove just the links this installer made
./install.sh --purge       # --uninstall, plus the delegate data dir when this checkout is outside it
```

- `--release TAG` — `git clone --depth 1 --branch TAG`, verify the clone's `VERSION` file says TAG
  (minus a leading `v`), install it under `~/.local/share/delegate/TAG`, and point `current` at it.
  An existing version dir is reused only when its own `.delegate-version` stamp names it.
- `--repo URL` — clone source (default `https://github.com/gregtakacs/local-delegate`, the public
  repo; name your fork or a mirror here).
- `--from DIR` — clone from this existing local git clone; wins over `--repo`. Only the tag's commit
  installs — a dirty working copy in DIR is not an error and not installed.

Installed releases live under `~/.local/share/delegate` (`$XDG_DATA_HOME/delegate`): one directory
per tag plus a `current` symlink. Every link a `--release` install makes points *through* `current`,
never at a tag dir, so updating is a single atomic flip and two versions on disk can never be mixed
by one running tree. On a machine that installed this way the dev checkout is never what runs;
`delegate doctor`'s `install:` line says which tree you are in and what `current` points at.

An install made this way moves with `delegate update [--to TAG] [--repo URL] [--from DIR]`: it
re-runs the clone, verify and flip the installer itself runs — with the checking code from the tree
you are running, never from the tree being installed — takes `--to` from `current/.delegate-source`
when you give no tag (so a bare `delegate update` re-fetches or repairs what you have), takes the
source from that record's `repo=` unless `--repo`/`--from` says otherwise, and ends by re-running
the opencode permission merge and `delegate doctor`. Roll back with the same command the other way:
`delegate update --to <the previous tag>`. `update` never deletes a version directory — that is why
the rollback works — and pruning old releases is a later slice, so until then remove one by hand
once `current` has moved off it. Tags are opaque: no version comparison, no downgrade protection.

`delegate doctor` checks the config, the image, which endpoint answers, and **sends a real
tool call, both streaming and non-streaming**. It fails if the call comes back as text in `content`
(unparsed or "phantom" tool calls) or if its arguments aren't valid JSON. Fix those before
trusting any agent on the endpoint.

### Runners

| `DELEGATE_RUNNER` | Worker runs as | Gets | Use when |
|---|---|---|---|
| `docker` (default) | `delegate-worker` image: node 24 + corepack, python3, git, psql, chromium, opencode (pinned) | the task worktree, the repo's git dir, an evidence dir, the key (read-only). **No** docker socket, home dir, SSH keys or root | almost always. Also required for `--service postgres` |
| `native` | `opencode` from your PATH, as you, with a per-task `HOME` | everything you can reach (the file tools are fenced to the worktree, `bash` is not) | no Docker available, and you trust the model with your user account |

**A repo's own image: `.delegate/Dockerfile`.** The base image carries what every project needs
and nothing project-specific. A repo whose work needs more (a cross compiler, an SDK, another
language) declares it in `.delegate/Dockerfile`, built FROM the base, with `.delegate/` as the
whole build context:

```dockerfile
ARG BASE=delegate-worker:local
FROM ${BASE}
RUN …the toolchain, pinned to the versions the repo's CI uses…
RUN go version && clang --version   # fail the build, not the first task
```

`delegate build --repo DIR` builds it as `delegate-worker-<repo>:local`. Every task on that repo
then runs in it: `run` chooses it and records it in the task (`IMAGE` in `meta.env`), and
`continue`, `exec`, `verify` and every chain step reuse that record, so no command lands in
the wrong image for want of an export. It is stale (and refused, naming the build that fixes
it) when the base changed or anything under `.delegate/` did. An explicit `DELEGATE_IMAGE`
still overrides it, and an untrusted repository's Dockerfile is never built or used.

What belongs there: the toolchains the repo's CI installs, at CI's versions; the rule is that
what CI runs, the worker can run. What does not: project dependencies (modules, packages from
the repo's own lockfiles), which the worker fetches itself through the egress proxy into the
shared caches, and anything only a person or the host has (a device, a GUI browser on the
host, a signing key), which stays with the orchestrator. A worker may propose a change to
`.delegate/Dockerfile` like any other file; it is built on the host, after review, never by the
worker.

**Login shells keep the container's PATH.** Every verify, `exec` and chain step runs through
`bash -lc`, and a login shell reads `/etc/profile`, which resets `PATH`. Until 0.8.6 that
dropped what an image put on `PATH` (a project layer's toolchain) and the guard shims the
runner puts first. The entrypoint now records the starting `PATH` as `DELEGATE_PATH`, and a
root-owned `/etc/profile.d/zz-delegate-path.sh` restores it after `/etc/profile`'s reset.

**Supervised, in place: `delegate run SPEC --here`.** For when you're watching. The worker
edits your current checkout directly, with the native runner, whatever `DELEGATE_RUNNER`
says: no worktree, branch, container, egress filter or commits, so changes appear live in your
editor and stay uncommitted. Each round is kept as a snapshot ref (`refs/delegate/<slug>/r<n>`,
made with a throwaway index: your index and branch are never touched), so `report`, `diff`,
`continue`, `stop` and `peek` work as usual and your own uncommitted edits stay out of the diff.
`delegate rm` deletes only those refs. One in-place task per checkout; not with `--service`,
`--copy`, `--base` or `--github`. A chain plan with `"here": true` runs a whole slice this way,
committing each accepted step on your current branch (see [docs/levels.md](levels.md), level 3h).
`DELEGATE_UNTRUSTED_REPO=1` refuses all of this (see [Untrusted repositories](#untrusted-repositories)).

## Use it by hand

### Where the worktrees live: one folder per project

New tasks are filed under their project: `<DELEGATE_WORKTREES>/<project>/<slug>`. The folder name
is the **main checkout's** — a task started from a linked worktree `~/w/codehub-lead` of `codehub`
lands at `<W>/codehub/lead-x`, beside that project's other tasks (its id is still `codehub-lead-x`).
A2's per-project container bind-mounts exactly that folder, at the same host path, so a host-side
broker can run delegate for one project and see one project's work. Two rules keep old work usable:
**a task keeps the path written in its `meta.env`** — nothing recomputes a worktree path from a task
id, so tasks created in the old flat `<DELEGATE_WORKTREES>/<id>` layout keep working for `report`,
`diff`, `rm`, `continue`, `verify`, `exec`, `peek` and `chain`, and are never migrated — and
**`delegate rm` never removes the project folder**, not even when its last task goes: that folder is
a live bind mount, and dropping it under the container would break the mount. A task is refused
before anything is created if `<W>/<project>` is already a checkout or a file (an old flat-layout
worktree named like a project, say): move it, or set `DELEGATE_WORKTREES` elsewhere.

```bash
delegate run spec.md --repo ~/src/app --name add-handles \
    --verify "npm ci && npm run typecheck && npm test" --service postgres --copy .env
#   ... minutes later: the report (also: delegate report app-add-handles)
delegate diff app-add-handles                  # diffstat since base
delegate diff app-add-handles -- src/auth.ts   # content of chosen files
delegate exec app-add-handles -- npx prisma migrate status
delegate continue app-add-handles feedback.md  # next round, same session
delegate top                                   # every round, live, in this terminal (Ctrl-C quits)
git -C ~/src/app merge --squash delegate/add-handles && git -C ~/src/app commit
delegate rm app-add-handles --delete-branch
```

| Flag | Meaning |
|---|---|
| `--base REF` | branch the worktree from REF (default: the repo's current branch). Chain dependent steps by basing on the previous task's `delegate/<slug>` |
| `--verify CMD` | run after every round in the worker environment. The exit code and log tail go into the report, and the worker is told to run it first |
| `--copy PATH` | copy an untracked file (e.g. `.env`) from the main checkout. It is never committed |
| `--read PATH` | mount another checkout read-only, for reference (e.g. code to port). Secret-looking files in it (`.env*`, `*.pem`, `*.key`, `credentials*`, `*token*`, `secrets/`, `.ssh/`...) are blanked. Refused inside the repository under `DELEGATE_UNTRUSTED_REPO=1` (see [Untrusted repositories](#untrusted-repositories)) |
| `--github` | let the worker clone private GitHub repos and call the API with `DELEGATE_GITHUB_TOKEN_FILE`. Use a fine-grained **read-only** token |
| `--egress filtered\|open` | network policy for this task (default `DELEGATE_EGRESS=filtered`, see Security model) |
| `--service postgres` | a throwaway Postgres just for this task, as `$DATABASE_URL`. Removed by `delegate rm` |
| `--hard` | use `DELEGATE_MODEL_HARD` (e.g. a high-reasoning-effort variant); recorded as the task's `EFFORT=hard` in its `meta.env`, and on every round's ledger row |
| `--timeout S` | wall-clock limit for the round (default `DELEGATE_TIMEOUT`, 90 min) |

`delegate peek ID` prints a compact snapshot of the current round (state, steps, tool calls,
tokens, the worker's plan, the last few actions). It's about 250 tokens, compared with the raw
event log's tens of thousands, so an orchestrator can answer "how's it going?" cheaply.
`delegate top ID` is the same thing refreshed, and `delegate top` is every task at once
(see *Watching locally* below).

Follow-ups: `delegate continue ID -m "first item" -m "second item"` (each `-m` is one numbered
item), or a file, or `-` for stdin. `delegate stop ID` aborts a running round. The worker's
partial work is still committed, and the round reports as `aborted`.

`continue --verify CMD` replaces the task's verify from then on (later rounds, `delegate verify`, and a chain's retries), and a chain retry always runs the plan's current verify, so editing a step's verify in the plan and re-running the chain takes effect. A plain `continue` (no `--verify`) of a chain step does the same: it rebuilds the step's verify, scope gate included, from the plan the chain state names, so a scope widened in the plan applies to that round too. A step the plan no longer has, or a chain with no state, keeps the recorded verify.

**Flagged rounds are kept.** When a worker's closing message reports planted instructions, a prompt injection or an exfiltration attempt, `delegate rm` (and `prune`, `chain --clean`) copies that round's events, report and prompt to `$DELEGATE_STATE/quarantine/<id>-<time>/` before removing the task, so the source can still be traced. Nothing else is kept.

### The telemetry ledger (`delegate ledger`)

One append-only JSONL file — `$DELEGATE_LEDGER`, default `$DELEGATE_STATE/ledger/events.jsonl` —
holds one summary row per round, verdict, review, timeline and chain run, across every task:
the input to
trend model performance over time (see *Measuring changes*) without walking task directories,
and without a database. Rows carry identity, times, token and cost totals — **never** prompts,
tool inputs or outputs — so the ledger is safe to keep after `delegate rm` and to read by hand.
The lifecycle writes it from host-side code; nothing a worker does touches it.

```bash
delegate ledger show                          # every accepted row, oldest first
delegate ledger show --kind round             # one kind only
delegate ledger append --kind round --task-dir ~/.local/state/delegate/abc123 \
    --file round.json --fields exit_code=0    # write one row (used by lifecycle, and you)
```

`append` takes `--kind` (round|chain|verdict|review|timeline) plus the row from `--task-dir DIR`'s
`meta.env` (identity defaults), `--file F` (a JSON object; `-` reads stdin) and the
`--status`/`--exit`/`--task`/`--fields k=v,...` scalars, each overriding the one before it.
`append --kind round --round-from-report R --events E` is the round-row form: it builds the
row in the design's field order from a finished round's `report.json`, its `meta.env`, and
the condition flags (`--endpoint`, `--effort`, `--rules-hash`, `--timeout-s`, …), then appends
the round's `timeline` row from the same single parse of `E` — token sums included. The
lifecycle does exactly that at every round's end, in `finalize_round`; `DELEGATE_LEDGER=off`
skips the writes silently. Effort is recorded per task as `EFFORT` in `meta.env` (`--hard`
writes `hard`; a continue with `--hard` upgrades it; an absent key reads `normal`) and every
round row takes its effort from that record, not from the command line.
Writing is never fatal: anything wrong — bad kind, unreadable file, unwritable path — is one
`warn:` line and exit 0, because telemetry must never cost a round its result. `show` skips
malformed lines and kinds this build doesn't know, counting them in one warning. The R4
derivation itself — a round's `events.jsonl` -> the steps, tool times and token totals a
`timeline` row holds, with no tool payload ever read — is `lib/ledger.py`'s `derive_timeline`,
and the file protocol that module's own. `lib/ledger.py` is importable; `delegate ledger` is its
whole command-line surface, and the only writer on the command line.

**Forensics (T2-F): round rows at schema 3, and the chain row.** A round row now also keeps
what its record loses to `delegate prune`: `todos` (the plan's items from the round's final
todo write — at most 50, each text cut to 200 characters) and `worker_report` (the worker's
closing block parsed: the claimed status plus the *not verified*, *deviations*, *decisions*,
*omissions*, *suggestions* and *questions* lists, at most 20 items of 300 characters each;
`FILES`, `VERIFIED` and `EVIDENCE` name paths and command lines and are never kept). Both are
derived by `lib/report.py` into `report.json`, so an import rebuilds them. And every
`delegate chain` run ends — when it stops for any reason, SIGINT/SIGTERM included — with one
`kind:"chain"` row that `lib/chain.py` writes: the plan's name, its absolute repo and project,
the sha256 of the plan file's bytes, start and end, the outcome
(`done`, `blocked`, `partial`, `failed`, `interrupted`), the run's exit code, one entry per
step with its status and round/retry counts, and the orchestrator session. `--status`,
`--wait` and `--clean` write no row. `stats` ignores chain rows — a chain is not a round.
Like every other write, neither field nor row is ever fatal: one `warn:` line, same result.

**Your verdicts: `delegate ledger review`.** When a step lands you record what you decided; the
ledger stores it as one `review` row, linked to that task's round rows by task id — a verdict is
data you supply, never something inferred from a review document:

```bash
delegate ledger review abc123 --verdict fixed --bugs high=1,medium=2 --lines-changed 40 \
    --note "auth check moved out of the handler"
delegate ledger review abc123 --verdict accepted --lines-changed 0   # --round: the task's newest
```

`--verdict` is `accepted` (as-is), `fixed` (accepted after your changes) or `rejected`; a missing
or other value is refused, because this row *is* the verdict. `--bugs` names only the severities
you found, so an omitted one is 0, and `--round` defaults to the newest `round` row the ledger
already holds for that task (empty when it holds none). A review row carries no diff content and
no file lists — only the note you typed. As everywhere in the ledger, a row that cannot be
written costs one `warn:` line and exit 0, never the command's result.

**Once, before the history is pruned: `delegate ledger import`.** Task records are kept until
`delegate prune` reaches them (14 days by default), and the ledger is what outlives them — so run
this once, by hand:

```bash
delegate ledger import                      # every task under $DELEGATE_STATE
delegate ledger import --state /path/to/state
```

For every round dir that still holds a `report.json` it writes the same pair a live round writes,
through the same builders, marked `source:"import"`. The record no longer carries what the round
conditions were — the endpoint URL, delegate version, rules hash, image stamp, timeout, edit cap,
rounds running beside it — so those fields stay empty rather than guessed: an unrecorded endpoint
is an empty one. `round_start` comes from the first timeline step, `round_end` from the report's
own mtime, and effort is *inferred* from the round's model against `DELEGATE_MODEL_HARD`, labelled
`effort_source:"inferred"` so the provenance travels with the value. It is idempotent: a
(task id, round) the ledger already has — from this import or from a live round — is skipped, so
running it twice adds nothing. It prints one line, `imported N, skipped M, tasks K`, and a record
it cannot read is one `warn:` line plus a skipped count: the command's exit code stays 0. It
never writes, moves or deletes anything under `$DELEGATE_STATE` except the ledger itself.

### Project totals (`delegate stats`)

```bash
delegate stats [--chain NAME] [--repo R] [--since YYYY-MM-DD] [--json]
```

One read over the ledger: per-project totals grouped by `repo/chain`, `model`, `effort`.
It reads only `round` and `review` rows, filters by the `kind` the writer puts first
*before* parsing anything, and prints three tables — one per concern — and a total line:

```
delegate stats — by project (4 of 9 round rows)
repo/chain        model  effort  rounds          ok%  wall               tok(in/out/r)  cache%  retries  source
acme/widgets/t-1  m1     hard         5   75% review  17m30s avg 3m30s     1050/105/10     55%        4  -
...
```

- **`ok%`** is per task (one step's outcome): a reviewed task counts when its latest verdict is
  `accepted` or `fixed`, an unreviewed one when its last round ended `done`. The column labels
  the source: `review` (every task reviewed), `status` (none), `mixed` (some).
- **`repo`** groups by project: the main checkout, so a chain run from a linked worktree joins
  its repository's rows.
- **`retries`** is `sum(max(round) − 1)` over the group's task ids, read off the rows'
  `round` field and from nowhere else.
- **`wall`** is the `duration_s` sum with its mean beside it; **`tok(in/out/r)`** sums the
  row fields; **`cache%`** is `cache_read / (cache_read + input_tokens)` per round, meaned
  over the rounds that had tokens to ratio.
- The **findings** table (review rows only) counts verdicts, bugs by severity, and reviewer
  lines changed; the **failures** table carries `tool_errors`, `errors`, and per-status
  counts, with `worker-error`, `timeout`, `truncated` and `done-but-verify-failed` always
  spelled out, at their zero when a run did not use them.
- Import-sourced rows are labelled: the `source` column reads `N import`, and a group made
  of import rows takes its `ok%` from statuses, since no review rows exist for an import.
- `--chain`, `--repo` match a row's own field exactly and `--since` filters on `ts`
  (date-first, inclusive); they combine, and a filter that keeps nothing prints zeroes.
  `--repo R` also matches a row whose repo axis is the **same directory under another
  spelling** — when both `R` and that axis are absolute paths and their `realpath`s are equal,
  a symlink to the checkout and a trailing slash name the same project — so one project's
  totals do not split in two because a round was recorded through a link.
- `--json` prints the same facts as one object: `groups`, `findings`, `failures`,
  `totals`, `counts`, the echoed `filters`, and the line counts `skipped` (lines this
  build cannot use) and `filtered` (known kinds stats does not read). No warning goes to
  stderr in that mode; the document carries the count itself.

Stats never writes: not to the ledger, not to the state dir. A ledger that is missing,
empty, unreadable, or off (`DELEGATE_LEDGER=off`) is empty tables at exit 0 — an owner
who has not run a round yet has a real answer of zero, not a failure. Lines that are
malformed, of an unknown kind, or of a schema this build does not know are counted on
exactly one `warn:` line and dropped; stats prints no prices and no dollar amounts,
because R6 asked for counts.

### What comes after T

Slice B (benchmarks) will add `benchmark` and `verdict` rows to the same ledger under
rulings R9–R17: fixed bundles extended from `evals/cases/` (R9), several runs per
condition with medians and spread (R10), delegate mode and own-harness mode (R11/R13),
hidden checks never in the sandbox (R12), sandbox-only auto-approval with owner-written
grants (R14), blind review with verdicts recorded before matching (R15), pluggable and
benchmarked reviewers (R16), lost history accepted (R17). The `KINDS` registry from T1
reserves both kind names; slice B defines the fields.

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
`ORB_BASE_MAC`, `ORB_SERIAL`, `ORB_IP`) and never executes it. Refused under
`DELEGATE_UNTRUSTED_REPO=1`: the file is read from the repository on the host. For that task:

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
`--status` shows where it is and `--clean` removes the chain's tasks. `delegate wait PLAN.json`
(or `delegate chain PLAN.json --wait`) blocks its own process until the chain stops: its runner,
the pid each run records in the chain's state, is gone and no step is running. It exits 0 when
every step is done, 3 when one is blocked or failed, and 124 after `--timeout S`. It never
searches process names, so it cannot mistake itself for the chain. Run it, like the chain, as a
background job whose exit you are told about, never in the foreground of an agent's session. The `delegate-lead`
Claude Code agent (`claude/agents/`, installed by `install.sh`) uses this: it plans the
slice once, runs the chain, and checks the result once.

**Step scopes: `"scope": [...]` on a step.** Each entry is a repo-relative pattern for a path the
step may change: `path/to/file.py` (that exact file), `path/to/dir/` (anything under that
directory), or a pattern with `*`, `?`, `**` — where `*` and `?` never cross a `/` and `**` matches
any number of path segments, including none (`a/**/b.py` matches `a/b.py` and `a/x/y/b.py`, and
`dir/**` is everything under `dir/`). A plan-level `scope` is not supported: the rule belongs on the
step that can break it. Entries are validated at load (exit 2): non-empty strings, no leading `/`,
no `..` segment, and only `A-Za-z0-9 . _ / * ? + @ = , ~ -` — so no quote, space, `$`, backslash,
bracket or newline can reach the shell the gate runs in. A plan with scoped steps also needs a plain
`base` (`A-Za-z0-9 . _ / @ + -`), since the gate names it.

The chain then does three things with it. **It lints the plan** against the specs: every file a step's
spec claims in a `- new:`/`create:`/`modify:`/`delete:`/`remove:` bullet (its "Files owned", see the
step-spec template) must be admitted by that step's scope, or the plan is refused with one line per
miss and nothing has started. Only the path list at the head of such a bullet counts: text after
` — `, `;` or a full stop and anything in parentheses is prose, a bare file name takes the directory of
the path before it, and a `:LINE` suffix is dropped — which is the mistake a hand-written gate makes in the other direction,
a guard that omits a file the spec told the worker to change. `delegate chain PLAN.json --check` runs
exactly that and nothing else: one line per step (`scope: K entries, owned: M (all covered)` or
`no scope`), exit 0 when the plan is sound, exit 2 when it is not. It starts no step, writes no chain
state and fires no hook, so it is the command to run on a freshly written plan. **It runs the gate
first**: a scoped step's verify starts with a short bash snippet that lists what the step changed
(committed, staged, unstaged, deleted, untracked; `git diff --name-only --no-renames` from the merge
base with the branch the step started from, plus untracked files) and exits 1 on anything outside the
scope, before the real verify begins. A scope miss therefore costs a second instead of a full test run,
and step 2 is compared against `delegate/<step 1>`, not against the chain's base, so it does not
inherit step 1's files. (In place, the gate diffs the step's own HEAD.) The task still runs the whole
snippet, but its notes, `verify.log` and report show it as `[scope gate]` in front of the plan's
verify; the gate's own `DELEGATE-SCOPE:` lines in the log say what it found. **And it does not retry a plan
bug**: when the gate names a file the step's own spec mentions, no round can fix that — the chain stops
at once (exit 3) and says to fix the plan and re-check it. A gate failure on any other path gets one
targeted retry, whose message lists the paths and tells the worker to revert them or stop as blocked.
A step with no `scope` is untouched by all of this: the same verify, the same retries as before.

### Watching locally: `delegate top`

`delegate top` is the same view with no server: it reads the state dirs and refreshes in place
(Ctrl-C quits, 2 s by default, `--interval S`). No lock, no writes, nothing sent anywhere.

- **Claude leads** first, when the Claude Code hook is installed: each lead is a header line —
  phase, its description, how long — with a line under it of its own tokens and the worker tokens of
  the work its commands started, and *that work nested beneath it*: its chains (steps indented under
  the chain), then the tasks it started directly. A lead that has stopped posting for over 30 minutes
  reads `stale?` where its phase was, since its process may simply be gone; a lead that reported
  `finished` is dropped an hour later (counted on the last line, and back with `--all`). Leads are
  read from `$XDG_CACHE_HOME/claude-agent-progress`, so one shows even while its worker runs on a
  worker host.
- **Not started by a lead** holds the rest: chains (with the plan to re-run) and loose tasks. A chain
  step whose `meta.env` predates `CHAIN=` is placed there from the chain's own state file and plan,
  so grouping does not depend on when the task was started.
- **Task rows**: state, id, round, elapsed, `steps/tools(failures)`, tokens out, the worker's current
  todo item and its last action. Running and verifying sort first. The lead header lines share these
  columns (phase over state, description over id), and everything is built from one column plan, so
  a narrow terminal drops whole columns rather than drifting.
- Then the counts, and one line per **interrupted** round: the round whose harness died between the
  worker stopping and its report — `delegate finish ID`, or `delegate chain PLAN` for a chain step.

`--once` prints one frame and exits (that is also what happens when stdout isn't a terminal, so
piping it to a log works); `--all` includes tasks finished more than 24 h ago; `--color` forces
colour onto a pipe, and `NO_COLOR` turns it off wherever `--color` does the opposite.
`delegate top ID` shows that one task: `delegate peek` plus its state, chain and lead.
`--repo PATH` narrows the view to one project, and `delegate list [--repo PATH]` filters the same
way (both are `lib/taskstate.py`'s one rule): a task matches when the directory `PATH` names is its
project — its main checkout — or the repo it was run in, compared through `realpath`, so a symlink
to the checkout, a trailing slash, or a path relative to the cwd all match, and a path that does not
exist matches nothing it would not have anyway. With `--repo`, the "N task(s)" count and the hidden
count speak for that project alone and **the Claude leads are not shown at all**: a lead is a
session, not a project, and its name and its other children would leak the very work the filter
exists to keep out. `delegate top ID --repo PATH` for another project's task prints the same
`no such task` line an unknown id gets, without confirming that the task exists.

The states come from `lib/taskstate.py`, which `delegate list`, `delegate chain` and `top` all
read: **running** (a round's lock exists and it has no report yet), **verifying** (its `verify.log`
is newer than its events — `delegate verify` and `exec` land here too), **interrupted**, **new**, or
the status in its `report.json`. The numbers of a round still in flight are parsed from its
`events.jsonl` with the same code the dashboard reporter uses; a finished round's come from its
`report.json`, so a restarted machine reports the same thing it did before.

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

1. **The worker designs the slice.** One design task, from
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

## Untrusted repositories

`DELEGATE_UNTRUSTED_REPO=1` (env or `config.env`; default `0`) says: someone other than you can
write this repository — its `.git`, its working tree and its task worktrees under
`<DELEGATE_WORKTREES>/<project>/`. With `0` delegate behaves exactly as before. With `1`, every
host-side step that would read or run the repository through git instead runs inside a throwaway
container, and any command that cannot be made safe this way **refuses** rather than half-works.
It is one setting for a whole run; whoever starts delegate for such a repository sets it, and
nothing names or trusts a particular caller. A task created with the setting on records
`UNTRUSTED=1` in its (host-owned) `meta.env`, so `diff`, `verify`, `continue` and `rm` keep
obeying the mode later even when the env is not set again.

**What runs sandboxed, and its limits.** Every git call about the repository, and every path
step that could follow a planted symlink (`check_gitlink`, `--copy`, the round commit, diffstats)
goes through one container: `docker run --rm` with `--network none`, `--cap-drop ALL`,
`no-new-privileges`, a read-only root and a tmpfs `/tmp`, as your uid, binding **only** `REPO`
and `<DELEGATE_WORKTREES>/<project>` — no secrets, no Docker socket, no other repository. The
repository's `core.fsmonitor`, hooks, external diff and commit signing are switched off inside
it with `-c` overrides; clean/smudge filters and textconv do run, but they can reach only those
two mounts. The scheme assumes the other party can write *inside* those two directories but
cannot replace the directories themselves or anything above them; where both are bind mounts
that is exactly the shape you get. It costs a container start (a few seconds) spread over
rounds that take minutes.

**The inode check.** Before a path is handed to docker as a mount source, `lib/safepath.py`
walks it from `/` one component at a time with `O_NOFOLLOW` (a symlink at any component, or a
non-normal path, exits 3 with `SECURITY: …`) and records the `DEV:INO` of the directory it
opened; sources are mounted with `--mount`, so a missing source fails instead of being created
as root. Inside the container an entrypoint wrapper (`lib/sandbox-git.sh`) re-opens each mount,
compares its `DEV:INO` with the host's answer, and only then execs the image's own entrypoint —
a path swapped for a symlink between the two checks stops the start before any worker code
runs. Worker mounts get the same check.

**What refuses with `DELEGATE_UNTRUSTED_REPO=1`** (message prefix `delegate:
DELEGATE_UNTRUSTED_REPO=1:`, exit 1, nothing touched):

- any command when the variable is not exactly `0` or `1` (`must be 0 or 1`);
- `run --here`, and any task on the native runner — those run the worker on the host, where no
  sandbox exists (`--here` also refuses a chain plan with `"here": true`, exit 2, before any
  step starts);
- `run --orb FILE` — the target file is read from the repository on the host;
- a `--repo` that is not the top of a main checkout: a subdirectory, a linked worktree or
  gitfile, a symlinked `.git`, or a `.git` with a `commondir` file (it borrows another
  repository); delegate never asks git where the repo is — the path is realpath'd once and
  checked as a string;
- a repository or worktree path containing a comma, tab or newline (they ride through the mount
  parsing), a (re)solved mount source that safepath finds to be or run through a symlink, and
  `DELEGATE_WORKTREES` inside the repository itself;
- `--read PATH` for anything inside the repository or its worktrees — it is re-mounted (and
  re-resolved) every round, so the repo could point it anywhere;
- any command on an existing task except `rm`, when the task is in-place or on the native
  runner, predates the per-repo worktree layout, or has a worktree git dir that is not under
  `<REPO>/.git/worktrees/`, or a `GIT_COMMON` that is not the string `<REPO>/.git`. `rm` such
  tasks: it only runs git, sandboxed.

**Behaviour that differs with the setting on:** repository hooks do not run on `worktree add`;
a clean/smudge filter that needs network, or a binary missing from the sandbox image (git-lfs),
fails; commits are never signed; `delegate diff` output is never coloured.

Companion settings: `DELEGATE_SANDBOX_IMAGE` — the image these containers use (default
`DELEGATE_IMAGE`; it needs bash, git ≥ 2.42 and coreutils) — and `DELEGATE_SANDBOX_TIMEOUT` —
seconds one sandboxed git step may take before it is killed (default `600`). Refusals and the
mount checks are covered by `tests/test_untrusted_repo.sh`, which needs neither docker nor
network.

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
lib/ledger.py                 the telemetry ledger: JSONL protocol, R4 timeline derivation
lib/taskstate.py              one read-only task state -> `top`, `list`, `chain` (and a CLI)
lib/probe.py                  tool-calling probe used by doctor
lib/render-opencode-config.py DELEGATE_* env -> opencode.json (one provider, key by file)
opencode/                     worker rules, UI-verification rules, plugins (mounted live into
                              the container: edit them without rebuilding the image)
worker/                       Dockerfile, entrypoint, delegate-shot
claude/skills/delegate/       the Claude Code skill + spec template
```
