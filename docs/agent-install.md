# Installing local-delegate: steps for an agent

*You are a coding agent installing local-delegate for the person you're working with. Follow these
steps in order. Run the commands yourself, show the person what each step found, and ask them only
for what's marked **ASK**. Stop and explain if a step fails: don't work around a failure.*

## 1. Check the machine

```bash
uname -s; cat /etc/os-release 2>/dev/null | head -2
git --version; curl --version | head -1; python3 --version
docker version --format '{{.Server.Version}}' 2>&1 | head -1
```

- It needs **Linux or WSL**, with git, curl and python3. macOS is untested: say so before going on.
- **Python 3.11+** is needed only for grants (optional). Older versions work for everything else.
- **Docker** (the server must answer) is strongly recommended: it's the sandbox. Without it, tell
  the person the "native" runner runs the worker **unsandboxed, as them**, and **ASK** whether to
  continue with `--runner native`, or stop so they can install Docker first.
- If `docker version` fails with a permission error, the person isn't in the `docker` group. Tell
  them, and don't use sudo to work around it.

## 2. Get the model details

The worker talks to an OpenAI-compatible `/v1` endpoint. **ASK** the person for:

1. **The endpoint URL**, ending in `/v1`. For example `http://localhost:8000/v1` (vLLM or
   SGLang), `http://localhost:11434/v1` (Ollama), `http://localhost:1234/v1` (LM Studio), or a
   hosted one like `https://openrouter.ai/api/v1`.
2. **The model name** exactly as that server knows it. Offer to list them:
   `curl -s -H "Authorization: Bearer $KEY" <URL>/models`. Optionally ask for a second,
   "hard" model for difficult steps; the default is the same model.
3. **The API key.** For a local server with no auth, any dummy value works.
   - **Never echo the key, write it into a command line, or put it in a file in a repo.** Pass it on
     stdin, as below, and install.sh stores it in `~/.config/delegate/api-key` with mode 600.

Also ask the model's **context window** if they know it (the default is 131072).

## 3. Get the code

```bash
git clone https://github.com/gregtakacs/local-delegate ~/src/local-delegate
cd ~/src/local-delegate
```

If `~/src/local-delegate` already exists, `git -C ~/src/local-delegate pull` instead.

## 4. Install

Run this from the clone, filling in the values from step 2. The key goes on stdin:

```bash
./install.sh --base-url "<URL>" --model "<MODEL>" [--model-hard "<HARD_MODEL>"] \
  [--context <TOKENS>] [--runner native] --key-stdin <<< "<KEY>"
```

Some harnesses would record that heredoc in their history. In that case, ask the person to run
this line themselves, or to put the key in a file outside any repo and pass `--key-file <path>`.

The installer:
- links `delegate` into `~/.local/bin`, plus the Claude Code skill and agent;
- if `opencode` is on PATH, merges the few `permission` entries the delegate skill needs into
  `~/.config/opencode/opencode.json` so the person's agents can load the skill without a prompt —
  it only adds entries that are absent, never rewrites a value already set, and refuses a config
  that isn't valid JSON (then say so; don't edit their config by hand);
- writes `~/.config/delegate/config.env`, and never overwrites an existing one;
- builds the worker and egress images, which takes a few minutes the first time.

If `~/.local/bin` isn't on PATH, say so, and show the line to add to their shell profile.

## 5. Prove it works

```bash
delegate doctor
```

It checks the config, the images, that the endpoint answers, and that the model returns **real
tool calls**, streaming and non-streaming. It must end with `doctor: OK`.
- With `opencode` installed it also prints a `skill:` line. If it WARNs, re-run `install.sh`; if
  it still warns, the person's opencode config has a `permission.skill.delegate` value of their
  own — leave it and tell them loading the skill may prompt once per session.
- Confirm opencode actually *sees* the skill: `opencode debug skill | grep -c '"name": "delegate"'`
  must print 1. Zero usually means `SKILL.md`'s frontmatter won't parse (a `: ` inside the
  unquoted `description:` line breaks YAML silently) — run `tests/test_skill_frontmatter.sh`.
- If the tool-call probe fails, the model or server isn't usable as a worker yet. That's usually a
  server flag for tool parsing (for example vLLM's `--enable-auto-tool-choice --tool-call-parser
  …`). Report what doctor printed; don't change their server for them.

## 6. Tell the person what they have

In a few lines:
- `delegate` is installed, and doctor passed.
- **Claude Code users:** the skill is installed, so Claude delegates bigger tasks on its own and
  says so first.
- **Other agents:** point them at `docs/harnesses.md`, and offer to add a line to this project's
  `AGENTS.md` (or your rules file), "use local-delegate for implementation work, following
  `~/src/local-delegate/claude/skills/delegate/SKILL.md`", if they want it.
- **The safety defaults:** sandboxed, filtered network, no telemetry. Extra access is a grant they
  write themselves (`docs/grants.md`). **Don't create grant files for them unless they ask**, and
  never one that widens access they didn't ask for.

**Don't run a first real task** unless they ask. If they do, offer a tiny one, such as adding a
test to a scratch repo.
