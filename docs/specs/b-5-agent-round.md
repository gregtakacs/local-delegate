# Task B5: own-harness rounds — `delegate run --agent NAME`, on top of the orchestrator's sandbox code

`"hard": true` — this step decides when the owner's harness setup is copied into a sandbox and
when it is scrubbed, builds the agent prompt, and turns untrusted agent output into the report.
Slice B step 5 of 10, chain segment 2, based on the orchestrator's branch `b-o1-sandbox`
(`docs/specs/b-design.md` §Own-harness round, §The owner's harness setup, §Telemetry). R19: you
**call** the orchestrator's functions (`run_worker_docker`'s agent variant, `agent_seed_home`,
`agent_scrub_home`, `llmlog_start`, `llmlog_stop`) exactly as `docs/specs/b-o1-sandbox.md`
§Interface says; you never edit them, `run_worker*`, `worker/agent-launch`, `lib/grants.py`,
`lib/render-opencode-config.py` or egress code — the verify's cage check fails if you do.

## Goal

`delegate run SPEC --agent NAME [--model M] [--effort E]` runs a standalone agent (a B3 profile)
once, inside the same sandbox a delegate round uses, with the owner's harness setup copied in for
that run only, and turns its own output into the round's `report.json`. Commit, verify, report
and T's ledger rows happen as for any round. Every round of any mode can also record the file
timeline.

## Read first

- `docs/specs/b-o1-sandbox.md` §Interface (all of it — the contract you build on), then the
  functions themselves in `bin/delegate`.
- `docs/specs/b-design.md` §Own-harness round, §Telemetry.
- `bin/delegate`: `cmd_run` (options, `--here` refusals, `need_config`, `check_image_fresh`,
  `BASE_URL=`, meta.env block, prompt block), `cmd_continue`, `do_round`, `run_limited`,
  `finalize_round`, `context_stamp`, `image_freshness`, `cmd_build`, `progress_start`/`progress_stop`
  (the side-process start/stop-file/kill-by-PID pattern).
- `lib/agents.py` (B3), `lib/filetimeline.py` (B4), `lib/report.py` (`cmd_report`, `main`).
- `tests/docker-stub.sh` (B2) and `tests/test_sandbox_bench.sh` (O1: how it drives the stub).

## Contract

### `cmd_run`

- `--agent NAME` with a `kind = "delegate"` profile → exactly as without `--agent`.
- `--agent NAME` with a `kind = "command"` profile:
  - Refuse, each with `die "--agent: own-harness agents run only in the docker sandbox (R14); <flag> does not apply"`:
    `DELEGATE_RUNNER != docker`, `--here`, `--raw`, `--orb`, `--orb-flash`, `--github`, `--grant`.
  - `--model`/`--effort` are the agent's; validated by `lib/agents.py argv` before any task dir
    exists (a bad value dies leaving nothing).
  - `AGENT_IMAGE` = profile `image` or `$DELEGATE_AGENT_IMAGE`; missing → `die "agent image X
    missing — run: delegate build --agents"`; when it is `$DELEGATE_AGENT_IMAGE`, its stamp is
    checked like the worker image's. `verified = false` → one `note` saying the agent is
    UNVERIFIED.
  - `BASE_URL` (no probe, no `pick_base_url`): the value of the profile's `api.base_url_env` in
    the invoking environment if set, else `api.default_upstream`, else empty.
  - meta.env: `MODE=%q` (`own-harness`; and `delegate` written for every other run), `AGENT`,
    `AGENT_IMAGE`, `AGENT_MODEL`, `AGENT_EFFORT`; `MODEL` = `AGENT_MODEL`.
  - Prompt (instead of the delegate prompt; exact text; bracketed lines conditional as in the
    delegate prompt; the network line when the network mode is `filtered`):

    ```text
    You are working on the task below in a git repository. Nobody will answer questions while you work: decide, implement it completely, verify it by running it, then stop.

    - Working directory: `<WORKTREE>`. Leave your work in the working tree and do not commit: this repository's git metadata is read-only here, and the harness records the tree when you stop.
    - Evidence directory (screenshots and logs the task asks for): `$DELEGATE_EVIDENCE_DIR`
    [- A throwaway Postgres for this task only is at `$DATABASE_URL`.]
    [- When you finish, this verify command will be run on your work: `<verify>`. Run it yourself before you stop.]
    [- Network: the model API and the public internet are reachable through a proxy; your LAN and the docker host are not, by design. Do not try to work around it.]

    <specification>
    <spec.md verbatim>
    </specification>
    ```
- `cmd_continue` on `MODE=own-harness`: `die "continue: own-harness runs are one-shot (R11): the prompt is given once; start a new run"`.

### `do_round`

Both modes, when `DELEGATE_FILE_TIMELINE=1` (config default `0`; `DELEGATE_FILE_TIMELINE_S`
default `1`): start `lib/filetimeline.py watch --root "$WORKTREE" --out "$rd/files.jsonl"
--interval "$DELEGATE_FILE_TIMELINE_S" --stop-file "$rd/.files-stop" --ppid $$` right before the
first `run_limited`, keep its PID; after the last worker invocation of the round (after the nudge
loop in delegate mode) touch the stop file, wait ≤ 5 s, kill by that PID; write `$rd/files.json`
from `summary --start --end`. Any failure: one `warn`, never fatal, never a changed status.

Agent branch (`MODE=own-harness`), in this order:
1. Version: `docker run --rm --network none --user UID:GID --entrypoint "" "$AGENT_IMAGE"
   <version_argv>` → first line ≤ 200 chars to `$rd/agent-version` (failure → empty file). No
   setup is mounted for this.
2. `python3 lib/agents.py argv ... > "$rd/.argv"` (die on failure), `mapfile -d '' -t`.
3. Proxy decision: `present` = the names from `lib/agents.py setup-env "$AGENT"` that are set
   and non-empty in the environment (names only); `plan=$(python3 lib/agents.py proxy "$AGENT"
   --present "$present" --setup-base-url "<value of the profile's base_url_env, if set>")`. When
   `plan` is non-empty: `agent_base=$(llmlog_start "$rd" <upstream> <dialect>)`; else
   `agent_base=""`.
4. `python3 lib/agents.py env "$AGENT" ${agent_base:+--base-url "$agent_base"} > "$rd/.agent-env"`.
5. `agent_seed_home "$rd"` (O1). From here on every exit path must reach step 7: put the run in
   a block whose failure still runs it, and call `agent_scrub_home` at the start of
   `finalize_round` too (covers `delegate finish` after a killed harness).
6. `RL_STDIN="$rd/prompt.md" AGENT_MODE=1 AGENT_ENV_FILE="$rd/.agent-env" run_limited "$secs" "r$n" run_worker "r$n" "${argv[@]}" > "$rd/agent.jsonl" 2> "$rd/stderr.log"`;
   `reap_leftovers`.
7. `llmlog_stop "$rd"` (when started), `agent_scrub_home "$rd"`, `rm -f "$rd/.argv" "$rd/.agent-env"`.
8. No nudge loop, no session. `finalize_round` as today; `lib/report.py report` gets
   `--agent-format <profile output> --agent-output "$rd/agent.jsonl" --agent-version-file
   "$rd/agent-version" --mode own-harness --agent "$AGENT"` (and `--mode delegate --agent
   delegate` for delegate rounds), plus `--files-json "$rd/files.json"` and `--llm-json
   "$rd/llm.json"` when present.

### `lib/report.py`

- New args `--agent-format`, `--agent-output`, `--agent-version-file`, `--mode`, `--agent`,
  `--files-json`, `--llm-json`.
- With `--agent-format`: the summary comes from `agents.summarize(fmt, path)`; `worker_status`
  is None; status: `aborted` when aborted; `timeout` on exit 124; `worker-error` when exit ≠ 0 or
  `success is False`; else `done`; then `done-but-verify-failed` as today. `report.json` gains
  `mode`, `agent`, `agent_version`, `version_checked`, `model_reported`, `input_tokens`,
  `cache_read`, `cache_write`, `success`, `unparsed_lines`; `proxy_bypassed` = true when `llm`
  shows 0 requests and the summary has tokens; the markdown header says `agent: NAME <version>
  (version checked: yes|no|unknown)` instead of `worker said`; the final-text section shows
  `final_text`.
- `files`/`llm` objects embedded when those files exist (both modes).
- Without `--agent-format`: as today plus `"mode": "delegate"`, `"agent": "delegate"`.

### Image and build

- `worker/agents.Dockerfile`: `ARG BASE=delegate-worker:local`, `FROM ${BASE}`; `ARG
  CLAUDE_CODE_VERSION=2.1.325`; `ARG CODEX_VERSION=latest` with the comment `UNVERIFIED pin: set an
  exact version once checked`; `RUN npm install -g --no-audit --no-fund
  @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} @openai/codex@${CODEX_VERSION} && claude
  --version && codex --version`; `COPY --chmod=755 worker/agent-launch
  /usr/local/bin/delegate-agent-launch` (the file O1 wrote); `ENV DISABLE_AUTOUPDATER=1`.
- `cmd_build --agents` (removed from the args passed on): after the worker and egress images,
  `docker build --label io.delegate.stamp=$stamp --build-arg BASE="$DELEGATE_IMAGE" -t
  "$DELEGATE_AGENT_IMAGE" -f worker/agents.Dockerfile "$DELEGATE_HOME"`.

### `tests/test_agent_round.sh` — create

Offline, the B2 docker stub with a `DOCKER_STUB_HOOK` that plays the agent (writes `hello.txt`,
copies stdin to `$T/seen-prompt`, dumps its env file to `$T/agent-env`, prints a fixture claude
stream: init + an assistant with a tool_use + result success with usage) and plays version
(`2.1.325 (Claude Code)`) and `bash -lc` (runs it). Temp `HOME` = a fake owner home with
`.claude/.credentials.json` containing SENTINEL-C; `ANTHROPIC_API_KEY=SENTINEL-K` exported for the
proxy cases, unset otherwise. At least:
1. `delegate run spec.md --agent claude-code --model model-a --effort high` exits 0; the round
   commit has `hello.txt`; `report.json` has `mode: own-harness`, `agent: claude-code`, `status:
   done`, the fixture's tokens and tool count, `agent_version`, `version_checked: true`; meta.env
   `MODE=own-harness`, `AGENT_MODEL=model-a`.
2. After the run `$TASK_DIR/agent-home` does not exist, and neither SENTINEL appears in the round
   dir, `report.*`, meta.env, the stub log, the prompt, or the ledger file.
3. Without `ANTHROPIC_API_KEY`: no `llmlog` `run -d` in the stub log; with it: `run -d` for
   `delegate-<id>-llmlog` and the agent's env has `ANTHROPIC_BASE_URL=http://delegate-<id>-llmlog:8080`,
   then `rm -f` of the sidecar; `report.json.llm` present when the hook writes a fake log.
4. The prompt equals the contract text (first line, the do-not-commit line, the verify line with
   `--verify`, `<specification>` and the spec), with no `§13` and no task id.
5. Refusals: native runner, `--here`, `--raw`, `--github`, `--orb x`, `--grant g` → the R14
   message, no task; `--model 'a b'` → dies before a task dir exists; `continue` → one-shot message.
6. Hook exits 1 / result `is_error: true` → `worker-error`; `--timeout 2` with a hook sleeping 30
   → `timeout`, and the agent-home is gone afterwards.
7. `--agent delegate` → the normal worker image line with the delegate key mount.
8. `DELEGATE_FILE_TIMELINE=1` delegate-mode round (stub opencode writes two files) → `files.json`
   with `files_touched` 2 embedded in `report.json`.
9. `delegate build --agents` → three `docker build` lines, the third with
   `worker/agents.Dockerfile`, `--build-arg BASE=` and the stamp label; without, two.

## Out of scope

- Scoring (B6), bench (B7). No edits to the O1 functions or files (the cage check), `lib/agents.py`
  (unless a bug blocks you — say so under DEVIATIONS), `lib/grants.py`, `worker/Dockerfile`,
  `worker/entrypoint.sh`, egress files, existing tests.

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check blames untracked deliverables; the harness
commits before the chain's verify runs. If that is the only failure mid-round, report it; never
edit that test. The **cage check** fails if this step changed any sandbox function or file
(R19: orchestrator code; `docs/specs/b-design.md` §Who writes what) — never "fix" it by editing
the check; leave the sandbox code alone and report what you needed under DEVIATIONS.

```bash
set -o pipefail && bash -n bin/delegate && python3 -m py_compile lib/*.py && [ -f tests/test_agent_round.sh ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && for fn in run_worker run_worker_docker run_worker_native ensure_network ensure_egress ensure_task_egress host_args read_mount_args make_guard_shims net_args run_limited run_scorer agent_seed_home agent_scrub_home llmlog_start llmlog_stop; do cmp -s <(git show b-o1-sandbox:bin/delegate | sed -n "/^$fn() {/,/^}/p") <(sed -n "/^$fn() {/,/^}/p" bin/delegate) || { echo "CAGE CHANGED $fn (R19: orchestrator code)"; exit 1; }; done && { git diff --quiet b-o1-sandbox -- lib/grants.py worker/egress.Dockerfile worker/egress-entrypoint.sh worker/entrypoint.sh lib/render-opencode-config.py worker/agent-launch || { echo "CAGE CHANGED files (R19: orchestrator code)"; exit 1; }; } && ! git diff --name-only b-o1-sandbox | grep -qvE '^docs/specs/b-|^bin/delegate$|^lib/report\.py$|^lib/agents\.py$|^worker/agents\.Dockerfile$|^config\.example\.env$|^docs/reference\.md$|^tests/docker-stub\.sh$|^tests/test_agent_round\.sh$' && echo GATE-OK
```

## Report format

```text
STATUS: done|partial|blocked
SUMMARY: <=3 sentences
TESTS: <counts; which suites ran; gate result>
RISKS: <what might still be wrong>
DEVIATIONS: <departures from this spec and why, or none>
```
