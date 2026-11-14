# Using delegate from any agent or harness

`delegate` is a plain command-line tool. Anything that can run shell commands and read their
output can be the **orchestrator**: Claude Code, Codex, OpenCode, Cline, Aider, a CI job, or a
person. Anything that serves an **OpenAI-compatible** `/v1` endpoint with tool calling can be the
**worker's model**. Neither side is tied to the other, or to the stack it was built on.

```
 orchestrator (any agent or person)      delegate CLI            worker
 ────────────────────────────────── ──▶ (worktree, sandbox, ──▶ opencode in a container,
 writes specs, runs commands,            grants, chains,         talking to ANY
 reads reports, reviews, lands           reports)                OpenAI-compatible /v1
```

## 1. The worker's model: any OpenAI-compatible endpoint

Set these in `~/.config/delegate/config.env` (see [config.example.env](../config.example.env)):

| Setting | What |
|---|---|
| `DELEGATE_BASE_URLS` | One or more `/v1` URLs, tried in order: vLLM, SGLang, llama.cpp `llama-server`, Ollama (`http://host:11434/v1`), LM Studio, LiteLLM, OpenRouter, OpenAI, or any gateway that speaks the chat-completions API |
| `DELEGATE_API_KEY_FILE` | A file holding the bearer key. Put a dummy value in it if the server needs none |
| `DELEGATE_MODEL`, `DELEGATE_MODEL_HARD` | Model names as the server knows them (`--hard` uses the second) |
| `DELEGATE_CONTEXT` | The model's context window, in tokens |
| `DELEGATE_VISION`, `DELEGATE_REASONING` | 1 if the model takes images, or emits reasoning content |

The worker is opencode with one provider, `@ai-sdk/openai-compatible`
(`lib/render-opencode-config.py`), so the endpoint needs nothing beyond the standard API.
**It must do tool calling properly:** `delegate doctor` sends a real tool call, streaming and
non-streaming, and fails if the call comes back as text or with invalid JSON arguments. Run it
before trusting any new endpoint or model.

## 2. The orchestrator: any agent that can run commands

The orchestrator's whole interface is commands, files and exit codes:

| Step | Command | Read back |
|---|---|---|
| health | `delegate doctor --quick` | exit 0, or the line that failed |
| one task | `delegate run SPEC.md --repo R --name N --verify "CMD" [--base B] [--grant G]...` | the report on stdout at the end; exit 0 |
| follow-up | `delegate continue ID FEEDBACK.md` or `-m "text"` | the next report |
| a slice | `delegate chain PLAN.json` | exit 0 (all steps done) or 3 (a step failed or is blocked) |
| wake-ups | `delegate chain … --on-step CMD --on-done CMD` (or `DELEGATE_ON_STEP` / `DELEGATE_ON_DONE`) | CMD runs in `bash -lc` when a step is accepted / the run ends; `DELEGATE_CHAIN_*` env carries the outcome |
| where it is | `delegate list`, `delegate chain PLAN.json --status`, `delegate peek ID` | plain text |
| results | `delegate report ID`, `delegate diff ID [-- PATHS]`, `delegate verify ID`, `delegate exec ID -- CMD` | plain text, exit codes |
| clean up | `delegate rm ID --delete-branch`, `delegate chain PLAN.json --clean` | |

Rounds take minutes to over an hour:

- **With background jobs and notifications:** start `run`, `continue` and `chain` in the
  background, and act when they exit. Claude Code works this way.
- **Without them:** run it detached (`nohup delegate chain PLAN.json > chain.log 2>&1 &`), then
  check `delegate chain PLAN.json --status` or `delegate list` every few minutes. Check rarely:
  a round's progress costs your context, and you can't act on it mid-round anyway.
- **To be told instead of polling:** `--on-step CMD` fires when the chain accepts a step,
  `--on-done CMD` when the run ends in any terminal state (env fallbacks `DELEGATE_ON_STEP` /
  `DELEGATE_ON_DONE`). It's a plain shell command — a desktop or ntfy ping, or a wake-up prompt
  posted back to your orchestrator session. `DELEGATE_CHAIN_STATUS` (`name=state, …`),
  `DELEGATE_CHAIN_RC` (on-done) and `DELEGATE_CHAIN_STEP`, `_STEP_N`, `_STEP_TOTAL` (on-step)
  carry the outcome; the hook is best-effort and its failure never changes the chain's. Fire it
  from the *launching* command and stay idempotent: a resumed chain fires `--on-done` again at
  its next terminal exit, and a killed one never fires — so the hook says *when to look*, and
  `--status` stays the truth. For a wake-up that acts: `delegate-wake [SESSION_ID]` (shipped on
  PATH, `--url`/`$DELEGATE_WAKE_URL` to point elsewhere) posts a fixed-template "chain ended,
  verify" prompt into that session — opencode 2's `POST /api/session/<id>/prompt` (200), else
  opencode 1's `prompt_async` (204) — and the session runs it as a normal turn. On opencode 2 the
  id defaults to `$OPENCODE_SESSION_ID` and the Basic password to `$OPENCODE_SERVER_PASSWORD`,
  both of which an agent's shell inherits; a rejected password or unknown session fails at once. Behind
  the codehub hub, that call goes through the hub's proxy.
- **Either way:** the report is what you act on. Its `STATUS (harness):` line is `done`,
  `partial`, `blocked`, `no-status`, `worker-error`, `timeout`, `truncated` or
  `done-but-verify-failed`, and the `access:` and `GUARD:` lines say what the task could reach.

## 3. The method

The method is the same whatever drives it. It's written for Claude Code in
[claude/skills/delegate/SKILL.md](../claude/skills/delegate/SKILL.md), but nothing in it needs
Claude. Load that file into your agent's instructions (its rules file, `AGENTS.md`, a system
prompt, or a custom command) and read past the Claude Code specifics:

| SKILL.md says | Elsewhere |
|---|---|
| "run in the background; you are notified when it exits" | detach and poll `--status`, as above |
| the `delegate-lead` agent (a Claude subagent) for security-sensitive slices | do that slice's design yourself, or in a second session of your agent, with the same brief |
| Agent / Skill / Monitor tools | ignore; every action in the method is a `delegate` or `git` command |
| the progress hook `claude/hooks/agent-progress.py` (dashboard cards for Claude agents) | optional; the worker's own rounds report to the dashboard whatever the orchestrator is |

The parts that matter for any orchestrator:

1. **Decide** when it's worth delegating.
2. **Have the local model design the slice** from a short brief
   ([design-template.md](../claude/skills/delegate/design-template.md)), with the settled
   decisions it can't see moved into the repo or mounted with `--read`.
3. **Review the plan:** step sizes, real base branches, toolchains, owner questions.
4. **Run the chains.**
5. **Verify once per slice yourself:** the risky code line by line, the full gate on a clean
   squash, one live check with real binaries, and a test that fails without each fix.
6. **Land it on a local branch.** Push, merge or deploy only when the person asks.

## 4. Grants and safety don't depend on the orchestrator

Grants are read only from the user's own folder, never from a repo
([grants.md](grants.md)). An orchestrator can *ask* for a grant by name, but it
can't create one by writing a file in a repo, and `continue` can't widen a task's access. Write
that rule into your agent's instructions too: **never create or edit a grant file; grants are the
user's decision.**
