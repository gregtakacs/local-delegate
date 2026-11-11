# local-delegate

**Your frontier agent designs and reviews. Your own model writes the code.**

`local-delegate` hands implementation work to a coding model you host yourself, while the agent
you already use (Claude Code, Codex, OpenCode, Cline, or you) stays in charge of the design, the
review and the merge. Each task runs in a sandboxed container, in its own git worktree, on its own
branch. It comes back as a compact report and a branch you can review, send feedback on, or merge.

Every line the local model writes costs your frontier model nothing. The orchestrator never reads
the worker's transcript: it writes a spec, reads a ~100-line report, and reviews the files that
matter.

```
your agent (orchestrator)                      worker container, one per round
  writes a spec ───► delegate run ───► git worktree + branch delegate/<slug>
                                        opencode ──OpenAI-compatible /v1──► your model
                                        (strict rules: read, plan, build, verify, report)
                ◄─── report: status, verify result, diffstat, what the worker claims it proved
  reviews: delegate diff / verify / exec
  feedback ───► delegate continue ───► same session, next round, next commit
  lands it: merge --squash delegate/<slug>
```

## What it's like in practice

On one real project (a Next.js site plus ESP32 firmware and its desktop app), across about two
dozen delegated steps:

- The local model also **wrote the slice designs and step specs**. A side-by-side test had a fresh
  Claude session, the local model and a warm orchestrator write the same spec. The local model came
  a close second, and its only misses were project decisions it had no way to see. See
  [LLM-Stats: three agents write the same spec](https://github.com/gregtakacs/LLM-Stats/tree/main/2026-11-spec-writers).
- **Most steps were accepted on their first round.** The orchestrator's job shrank to reviewing
  plans and verifying the result once per slice.
- **The verification is where the value was.** Real bugs (an uncapped upload body, a zip bomb in
  an unpacker, a CI step that could never run) were all caught in the orchestrator's one deep review
  per slice, never in per-step babysitting.

It isn't magic. A local model still ships the occasional subtle bug, and that's why the method
makes the orchestrator verify, not trust.

## What you need

- **Linux, or WSL**, with **git, curl, python3 (3.11+ for grants)** and **Docker** (recommended).
  A Docker-free "native" runner exists for machines without Docker.
- **An OpenAI-compatible `/v1` endpoint whose model does tool calling properly**: vLLM, SGLang,
  llama.cpp `llama-server`, Ollama (`/v1`), LM Studio, LiteLLM, OpenRouter, or a hosted provider.
  `delegate doctor` sends it a real tool call and tells you whether it's good enough.
- **An orchestrating agent that can run shell commands.** Claude Code gets a ready-made skill;
  anything else follows [docs/harnesses.md](docs/harnesses.md).

## Install

### Let your agent do it

Paste this into the coding agent you already use (Claude Code, Codex, OpenCode, Cline…):

> Install local-delegate from https://github.com/gregtakacs/local-delegate by following its
> `docs/agent-install.md`. Ask me for anything it needs.

It will check your machine, ask for your model endpoint, model name and API key, install, build the
sandbox images, and prove it works with `delegate doctor`. The steps it follows are in
[docs/agent-install.md](docs/agent-install.md), if you want to read them first.

### Or by hand

```bash
git clone https://github.com/gregtakacs/local-delegate ~/src/local-delegate
cd ~/src/local-delegate
./install.sh --base-url http://localhost:8000/v1 --model qwen3-coder --key-stdin <<< "$MY_API_KEY"
delegate doctor
```

`install.sh` is safe to re-run, and never overwrites an existing config or key. It:
- puts `delegate` on your PATH (`~/.local/bin`);
- installs the Claude Code skill and agent (as symlinks, so a `git pull` updates them);
- writes `~/.config/delegate/config.env`;
- builds the worker and egress-proxy images.

For a server with no key, pass any dummy key.

## Your first task

```bash
cat > spec.md <<'EOF'
# Add a /health endpoint
Add GET /health that answers {"ok": true}. Add a test. Don't touch anything else.
EOF
delegate run spec.md --repo ~/src/my-app --name health --verify "npm test"
```

The command prints a report when the round ends. Then:

```bash
delegate diff  my-app-health                      # what changed
delegate continue my-app-health -m "also return the version from package.json"
git -C ~/src/my-app merge --squash delegate/health && git -C ~/src/my-app commit
delegate rm my-app-health --delete-branch
```

To watch it, or all of them, in this terminal: `delegate top` (Ctrl-C quits, `--once` for one
frame, `delegate top ID` for one task's recent actions). It nests the work under the Claude lead
that started it, with the tokens each side spent. Chain and round states come from the same
files, so `top`, `list` and `chain --status` cannot disagree. A round whose harness died before it
wrote its report shows as **interrupted** and `top` prints the command that picks it back up.
No dashboard, no network.

With Claude Code you don't type any of this. Say what you want built: the installed skill makes
delegating the **default for anything bigger than a small edit**. Claude tells you in one line when
it hands work to the local model, and you can say no.

## For bigger work: slices and chains

A slice of a design runs as a **chain**:
1. The local model writes the plan: a design, one spec per step, and a chain file.
2. Your orchestrator reviews the plan.
3. `delegate chain plan.json` runs the steps unattended. Each step is accepted only when the worker
   says it's done and its verify command passes, and failures are retried in the same session.
4. The orchestrator verifies the whole slice once, deeply, and lands it on a branch.

The method, phase by phase, is in the skill:
[claude/skills/delegate/SKILL.md](claude/skills/delegate/SKILL.md). It's readable as plain
instructions by any agent.

## Safety

The worker is an AI writing and running code on your machine, so it's boxed in by default:

- **Its own container, worktree and branch.** It has no docker socket, no home folder, no SSH keys
  and no root, and the repo's shared `.git` is read-only, so it can't plant hooks that run on your
  host.
- **A filtered network.** It reaches only your model endpoint and the public internet, through a
  proxy that refuses your LAN, the docker host and cloud metadata.
- **Anything more is a grant you write.** Grants are named profiles in
  `~/.config/delegate/grants/`: a LAN service, a USB device, a mount, guarded commands. A worker
  can't write or edit them. See [docs/grants.md](docs/grants.md).
- **No telemetry.** Live progress reporting to a dashboard is off unless you turn it on, for an
  endpoint you run yourself.

**What it doesn't protect against:** a worker that's *allowed* to use the network can still send
your code to the internet. Don't hand it code you can't share with your model's host. A `--here`
(in-place) task runs unsandboxed as you, by design, for when you're watching.

## Docs

| | |
|---|---|
| [docs/agent-install.md](docs/agent-install.md) | install steps written for an agent to follow |
| [docs/harnesses.md](docs/harnesses.md) | driving it from any agent; any OpenAI-compatible endpoint |
| [docs/grants.md](docs/grants.md) | access beyond the sandbox: devices, LAN services, guards |
| [docs/levels.md](docs/levels.md) | how much to delegate: in place, single task, slice lead, hub |
| [docs/reference.md](docs/reference.md) | every command and setting, runners, chains, troubleshooting |
| [AGENTS.md](AGENTS.md) | for coding agents using or changing this repo |

## Status

It's used daily, by one person, on real projects, and has been run on Linux and WSL, not yet on
macOS. The worker harness is opencode at a pinned version.

Issues and pull requests are welcome. If you change the sandbox or grant code, bring tests
(`tests/test_grants.sh`, `DOCKER=1` for the proxy).

## License

[MIT](LICENSE)
