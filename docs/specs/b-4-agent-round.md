# Task B4: own-harness rounds — `delegate run --agent NAME`

`"hard": true` — this step adds a second program to the sandbox (`run_worker_docker`), a new
container entrypoint that handles credentials, and a parser of untrusted output into the report:
security code (AGENTS.md). The cage changes are confined to `run_worker_docker`, `do_round`'s
agent branch, `cmd_run`'s agent block and `worker/agent-launch`; the reviewer reads them in full.
Slice B step 4 of 10 (`docs/specs/b-design.md` §Own-harness round, §Credentials, R11, R14).

## Goal

`delegate run SPEC --agent NAME [--model M] [--effort E] [--endpoint E] [--grant G]...` runs a
standalone agent (a B3 profile) once, inside the same sandbox a delegate round uses — same
worktree, read-only `.git`, task network, egress proxy, timeout, grants — fully auto-approved
only there, and turns its own output into the round's `report.json`. Commit, verify, report and
T's ledger rows happen exactly as for a delegate round.

## Read first

- `docs/specs/b-design.md` §Own-harness round, §Credentials, §Telemetry (b).
- `bin/delegate`: `cmd_run` (options, refusals for `--here`, `need_config`, `check_image_fresh`,
  `BASE_URL=`, meta.env block, the prompt block), `cmd_continue`, `do_round`, `run_limited`,
  `run_worker`, `run_worker_docker` (all of it), `finalize_round`, `check_image_fresh`,
  `image_freshness`, `context_stamp`, `cmd_build`, `ensure_grants`, `grants_py`.
- `worker/Dockerfile`, `worker/entrypoint.sh` — the base image and what its entrypoint does (it
  renders an opencode config that needs a model endpoint; agent rounds must not use it).
- `lib/agents.py` (B3): `argv`, `env`, `version-checked`, `summarize`; `lib/grants.py` `secrets`.
- `lib/report.py` — `cmd_report`, `main`.
- `tests/e2e-rig.sh` (how an offline rig is shared), `tests/test_chain.sh` (fake binary pattern).

## Contract

### `cmd_run` — the agent block

- New options `--agent NAME`, `--effort E` (B2 added `--effort` for delegate mode; with
  `--agent` it is the agent's effort). `--model M` with `--agent` is the agent's model (not
  `DELEGATE_MODEL`).
- `--agent` naming a `kind = "delegate"` profile: behave exactly as if `--agent` were absent.
- `--agent` naming a `kind = "command"` profile:
  - Refuse, each with `die "--agent: own-harness agents run only in the docker sandbox (R14); <flag> does not apply"`:
    `DELEGATE_RUNNER != docker`, `--here`, `--raw`, `--orb`, `--orb-flash`, `--github`.
  - `AGENT_IMAGE` = profile `image` or `$DELEGATE_AGENT_IMAGE`; it must exist
    (`docker image inspect`) else die `agent image X missing — run: delegate build --agents`;
    when it equals `$DELEGATE_AGENT_IMAGE`, its stamp is checked like the worker image's
    (`DELEGATE_IMAGE_STALE`/`DELEGATE_IMAGE_ALLOW_STALE` apply).
  - Profile `verified = false` → one `note` line: `agent NAME is UNVERIFIED: its flags were not
    checked against an installed binary`.
  - `BASE_URL` is **not** probed: it is the endpoint's `base_url` when `--endpoint` is given
    (B2's resolver; its key file is NOT used), else the profile's `api.default_upstream`, else
    empty. `pick_base_url` is not called.
  - The model argument is validated by `lib/agents.py argv` before any task dir is created (a
    bad model/effort dies with the lib's message and leaves nothing behind).
  - meta.env: add `MODE=%q` (`delegate` or `own-harness`; `delegate` written for every non-agent
    run too), `AGENT`, `AGENT_IMAGE`, `AGENT_MODEL`, `AGENT_EFFORT`, `AGENT_ENDPOINT`. `MODEL` is
    set to `AGENT_MODEL` (may be empty) so T's round row and the report carry the agent's model.
  - Prompt (instead of the delegate prompt; every line exact, the bracketed lines conditional as
    in the delegate prompt):

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

    The network line appears when the effective grant network mode is `filtered` (as in the
    delegate prompt). No `§13`, no rules, no task id.
- `cmd_continue` on a task with `MODE=own-harness`: `die "continue: own-harness runs are one-shot (R11): the prompt is given once; start a new run"`.

### `do_round` — the agent branch (when `MODE=own-harness`)

1. Version: `docker run --rm --network none --user UID:GID --entrypoint "" "$AGENT_IMAGE" <version_argv>`
   (from `lib/agents.py show`), first line, ≤ 200 chars, to `$rd/agent-version`; failure → empty
   file, never fatal.
2. argv: `python3 lib/agents.py argv "$AGENT" --model "$AGENT_MODEL" --effort "$AGENT_EFFORT" > "$rd/.argv"`
   (die on failure), read with `mapfile -d '' -t`.
3. Launch env: `python3 lib/agents.py env "$AGENT" --have "<grants secrets, space-joined>" [--base-url "$AGENT_BASE_URL"]`
   to `$rd/.agent-env` (NUL- or newline-separated `KEY=VALUE`, your choice, documented in a
   comment); a failure (no granted credential) dies before the round starts, leaving the round
   dir with a `report.json` of status `worker-error` is NOT required — die is enough, but the
   lock must be released. `AGENT_BASE_URL` = `$BASE_URL` in this step (B5 points it at the
   logging proxy).
4. `RL_STDIN="$rd/prompt.md" AGENT_MODE=1 AGENT_ENV_FILE="$rd/.agent-env" run_limited "$secs" "r$n" run_worker "r$n" "${argv[@]}" > "$rd/agent.jsonl" 2> "$rd/stderr.log"`.
5. No nudge loop, no session id. `reap_leftovers` as today. Then `finalize_round` unchanged in
   its flow; `lib/report.py report` gets `--agent-format "<profile output>" --agent-output
   "$rd/agent.jsonl" --agent-version-file "$rd/agent-version" --mode own-harness --agent "$AGENT"`
   (pass `--mode delegate` for delegate rounds so every report carries `mode`).
6. `$rd/.argv` and `$rd/.agent-env` are removed after the round (they hold no secret, but they
   are scaffolding).

### `run_worker_docker` — the agent variant (`AGENT_MODE=1`)

Exactly these differences from a delegate round, nothing else:
- image `$AGENT_IMAGE`; `--entrypoint /usr/local/bin/delegate-agent-launch`;
- **no** `-v "$DELEGATE_API_KEY_FILE:/run/secrets/delegate_key:ro"`, no rules mount, no
  `render-opencode-config.py` mount, no `-e DELEGATE_BASE_URL/DELEGATE_API_KEY_FILE/DELEGATE_MODEL/
  DELEGATE_MODEL_HARD/DELEGATE_CONTEXT/DELEGATE_OUTPUT/DELEGATE_VISION/DELEGATE_REASONING/
  DELEGATE_REASONING_EFFORT/DELEGATE_CHUNK_CAP`;
- `-e` for every line of `$AGENT_ENV_FILE`;
- `NO_PROXY`/`no_proxy` gain `delegate-$ID-llmlog` (the B5 sidecar) in filtered/allow modes;
- everything else identical: `--rm --init -i`, name `delegate-$ID-$tag`, label, `--user`, worktree
  rw, `GIT_COMMON` ro, worktree gitdir, home, caches, evidence, network args, grants
  `docker-args` (which now include `[secrets]` mounts), guard shims, `DATABASE_URL`, read mounts,
  `DELEGATE_EVIDENCE_DIR`, `DELEGATE_TASK`, `DELEGATE_WORKTREE`, `$DELEGATE_DOCKER_ARGS`, `-w`.
- Verify rounds (`v$n`) and `delegate exec` of an agent task use the normal worker path (no
  `AGENT_MODE`): the verify runs in the worker image as today.

### `worker/agent-launch` — create (bash, the agent image's launcher)

```text
- set -euo pipefail; rm -f "$HOME/.gitconfig"; mkdir -p "$DELEGATE_EVIDENCE_DIR" when set
- secrets dir: ${DELEGATE_AGENT_SECRETS_DIR:-/run/secrets/grant}
- for each "ENV=name" in $DELEGATE_AGENT_SECRETS: ENV must match ^[A-Z_][A-Z0-9_]*$ and name
  ^[a-z0-9][a-z0-9._-]{0,47}$ (else "agent-launch: bad secret mapping" to stderr, exit 2); a
  missing/unreadable file is skipped; else export ENV with the file's content (trailing newlines
  stripped). Never echo a value.
- DELEGATE_AGENT_BASE_URL_ENV (same ENV regex) set → export it = DELEGATE_AGENT_BASE_URL
- unset DELEGATE_AGENT_SECRETS DELEGATE_AGENT_SECRETS_DIR DELEGATE_AGENT_BASE_URL_ENV DELEGATE_AGENT_BASE_URL
- no argv → "agent-launch: no command" exit 2; else exec "$@"
```

### `worker/agents.Dockerfile` — create

`ARG BASE=delegate-worker:local`, `FROM ${BASE}`; `ARG CLAUDE_CODE_VERSION=2.1.325`;
`ARG CODEX_VERSION=latest` with a comment `UNVERIFIED pin: set an exact version once checked`;
`RUN npm install -g --no-audit --no-fund @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
@openai/codex@${CODEX_VERSION} && claude --version && codex --version`;
`COPY --chmod=755 worker/agent-launch /usr/local/bin/delegate-agent-launch`;
`ENV DISABLE_AUTOUPDATER=1`. The base entrypoint stays (agent rounds override it).

### `cmd_build`

`delegate build --agents` (the flag is removed from the args passed to `docker build`): builds the
worker and egress images as today, then `docker build --label io.delegate.stamp=$stamp
--build-arg BASE="$DELEGATE_IMAGE" -t "$DELEGATE_AGENT_IMAGE" -f worker/agents.Dockerfile
"$DELEGATE_HOME"`. Without `--agents`, nothing new happens.

### `lib/report.py`

- New args `--agent-format`, `--agent-output`, `--agent-version-file`, `--mode`, `--agent`.
- With `--agent-format`: the summary comes from `agents.summarize(fmt, path)` (import from
  `lib/agents.py`), `worker_status` is `None`, and status is: `aborted` when aborted; `timeout`
  when exit 124; `worker-error` when exit ≠ 0 or `success is False`; else `done`; then
  `done-but-verify-failed` as today. `report.json` gains `mode`, `agent`, `agent_version`
  (the file's line), `version_checked` (via `agents.version_checked`), `model_reported`,
  `input_tokens`, `cache_read`, `cache_write`, `success`, `unparsed_lines`; the markdown header
  says `agent: NAME <version> (version checked: yes|no|unknown)` instead of `worker said`. The
  final text section shows `final_text` (it is the agent's last message).
- Without `--agent-format`: output identical to today plus `"mode": "delegate"` and `"agent":
  "delegate"` in `report.json` (no markdown change).

### `tests/docker-stub.sh` — create (sourced, never run; like `tests/e2e-rig.sh`)

`docker_stub_install DIR` writes an executable `DIR/docker` that appends every invocation's argv
(one line, `printf '%q '`) to `$DOCKER_STUB_LOG`, and emulates: `image inspect` (exit 0, `-f
'{{.Id}}'` → `sha256:stub`, label/Env formats → empty), `network inspect` (exit 1 first, then 0
once created), `network create/connect/ls`, `inspect -f` (egress label/running → `true`), `ps -q`
(empty), `container inspect` (exit 1), `rm`/`kill`/`start` (exit 0), `run -d` (prints an id),
and `run --rm ...`: finds the image argument (first non-option after the options; know the
options `bin/delegate` passes that take a value) and the `-w DIR`; when the image is
`$DOCKER_STUB_AGENT_IMAGE` and `--entrypoint` is the launcher, runs `$DOCKER_STUB_AGENT` (a test
script) in `DIR` with the container's stdin and the `-e` pairs exported; when the entrypoint is
`""` (version) prints `$DOCKER_STUB_VERSION`; when the command is `bash -lc CMD` runs `CMD` with
bash in `DIR`. Document every behaviour in its header comment.

### `tests/test_agent_round.sh` — create

Offline: temp HOME/state/worktrees, a temp git repo, config pointing `DELEGATE_BASE_URLS` at a
stub `/models` server (as in `tests/e2e-rig.sh`), a temp grants dir with a grant `t-key`
(`[secrets] anthropic-api-key = <temp file with a SENTINEL>`), `DELEGATE_RUNNER=docker`,
`DELEGATE_IMAGE_ALLOW_STALE=1`, the docker stub first on PATH. The stub agent writes `hello.txt`,
copies its stdin to `$T/seen-prompt`, records `env` to `$T/agent-env`, and prints a fixture
claude stream (init + one assistant with a tool_use + result success with usage). At least:
1. `delegate run spec.md --agent claude-code --model model-a --effort high --grant t-key` exits
   0; the round commit contains `hello.txt`; `report.json` has `mode: own-harness`, `agent:
   claude-code`, `status: done`, the fixture's tokens and tool count, `agent_version` from the
   stub; meta.env has `MODE=own-harness`, `AGENT_MODEL=model-a`.
2. The agent `docker run` line (from the stub log) has `--entrypoint
   /usr/local/bin/delegate-agent-launch`, the agent image, `/run/secrets/grant/anthropic-api-key:ro`,
   `--network delegate-<id>`, `HTTPS_PROXY=`, `NO_PROXY=` containing `delegate-<id>-llmlog`,
   `--user`, the `GIT_COMMON` `:ro` mount, `--model model-a --effort high`; and does **not**
   contain `delegate_key`, `DELEGATE_BASE_URL=`, `DELEGATE_MODEL=`, `/opt/delegate/opencode`.
3. The SENTINEL appears nowhere: not in the stub log, `report.md`, `report.json`, meta.env,
   `stderr.log`, the prompt, the ledger file.
4. The prompt the agent saw equals the contract text (check the first line, the "do not commit"
   line, the verify line when `--verify` is given, `<specification>` and the spec text), and has
   no `§13` and no task id.
5. Refusals: `DELEGATE_RUNNER=native`, `--here`, `--raw`, `--github`, `--orb x` each die with the
   R14 message and create no task; `--model 'a b'` dies before a task dir exists; no grant with a
   credential → dies with the lib's "needs one of these grant secrets" message.
6. `delegate continue <id> -m x` on the agent task dies with the one-shot message.
7. Agent stub exits 1 / prints a result with `is_error: true` → status `worker-error`; a
   `--timeout 2` with a stub that sleeps 30 → status `timeout`.
8. `--agent delegate` runs the normal delegate path (assert the docker run line is the worker
   image with the delegate key mount).
9. `worker/agent-launch` run directly (not through docker) with `DELEGATE_AGENT_SECRETS_DIR` at a
   temp dir: exports the mapped variable, skips a missing file, unsets its own `DELEGATE_AGENT_*`
   variables (the child's `env` shows none), exits 2 on `DELEGATE_AGENT_SECRETS='lower=x'` and on
   no argv, never prints the value.
10. `delegate build --agents` with the stub: three `docker build` lines, the third with
    `-f .../worker/agents.Dockerfile`, `--build-arg BASE=` and the stamp label; without `--agents`
    two lines.

## Out of scope

- The logging proxy and file timeline (B5), scoring (B6), bench (B7). No change to `lib/agents.py`
  except a bug you must fix to make this work (say so under DEVIATIONS); no change to
  `lib/grants.py`, `worker/Dockerfile`, `worker/entrypoint.sh`, the egress files, or existing tests.

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check blames untracked deliverables; the harness
commits before the chain's verify runs. If that is the only failure mid-round, report it; never
edit that test.

```bash
set -o pipefail && bash -n bin/delegate && bash -n worker/agent-launch && python3 -m py_compile lib/*.py && [ -f tests/test_agent_round.sh ] && [ -f tests/docker-stub.sh ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && ! git diff --name-only delegate/b-3-agent-profiles | grep -qvE '^docs/specs/b-|^bin/delegate$|^lib/report\.py$|^lib/agents\.py$|^worker/agent-launch$|^worker/agents\.Dockerfile$|^config\.example\.env$|^docs/reference\.md$|^tests/docker-stub\.sh$|^tests/test_agent_round\.sh$' && echo GATE-OK
```

## Report format

```text
STATUS: done|partial|blocked
SUMMARY: <=3 sentences
TESTS: <counts; which suites ran; gate result>
RISKS: <what might still be wrong>
DEVIATIONS: <departures from this spec and why, or none>
```
