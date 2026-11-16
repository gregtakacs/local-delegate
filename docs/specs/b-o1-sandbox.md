# O1 (orchestrator, by hand): sandbox code for slice B — agent containers, setup copy, logging sidecar, scorer

**Not a chain step.** R19: this is written by the orchestrator (whichever agent runs slice B and
its review), by hand, with tests — never handed to the sandboxed worker. It sits between chain
segment 1 (`b-chain.json`, steps 1–4) and segment 2 (`b-chain-2.json`, steps 5–10).

- Branch: `git branch b-o1-sandbox delegate/b-4-telemetry-libs`, work in a worktree of it,
  commit there (repo conventions, noreply identity). Segment 2 uses `b-o1-sandbox` as its base,
  and its steps' cage checks compare the functions below against it — so O1 is the only place
  they are written, and segment 2 builds on them unchanged.
- Files O1 may change: `bin/delegate`, `worker/agent-launch` (create),
  `lib/render-opencode-config.py`, `tests/test_sandbox_bench.sh` (create), `docs/specs/b-*`.
  Nothing in `lib/grants.py` or the egress files changes in slice B.
- Done when: `tests/test_sandbox_bench.sh` passes, the full gate passes
  (`set -o pipefail && bash -n bin/delegate && bash -n worker/agent-launch && python3 -m py_compile lib/*.py && for f in tests/test_*.sh; do env -u DELEGATE_EVIDENCE_DIR bash "$f" >/tmp/o1-$(basename "$f").log 2>&1 || { echo "FAIL $f"; exit 1; }; done`),
  and every hunk below was read back against this spec.

## Read first

- `docs/specs/b-design.md` §Who writes what, §The owner's harness setup in the sandbox,
  §Telemetry (a), §Scoring, §Trust.
- `bin/delegate`: `run_worker`, `run_worker_docker`, `run_worker_native`, `run_limited`,
  `stop_worker`, `ensure_network`, `ensure_egress`, `ensure_task_egress`, `ensure_service`,
  `svc_net`, `svc_name`, `egress_task_name`, `grant_net`, `make_guard_shims`.
- `lib/agents.py` (B3): `setup-paths`, `setup-env`, `env`, `proxy` subcommands (the data O1
  consumes; O1 re-validates it, never trusts it blindly). `lib/llmlog.py` (B4) `serve` flags.
- `lib/render-opencode-config.py` `model_entry`; `tests/docker-stub.sh` (B2).

## Interface consumed by segment 2 (exact; B5 and B6 call these and may not change them)

Variables set by the caller (B5's `do_round`) before calling: `ID`, `TASK_DIR`, `WORKTREE`,
`AGENT`, `AGENT_IMAGE`, `BASE_URL`, plus `AGENT_MODE=1` and `AGENT_ENV_FILE` for the run.

1. **`agent_seed_home RD`** → prints the agent-home path `$TASK_DIR/agent-home/r<n>` (n = the
   round dir's basename).
   - Paths from `python3 lib/agents.py setup-paths "$AGENT"` (one per line). Re-validate each:
     non-empty, not absolute, no `..` segment, no `*?[`, no newline; else die. For each that
     exists under `$HOME`: `cp -RL --no-preserve=ownership` into the same relative path (parents
     created, mode 700 dirs). A source that is a socket/fifo/device, or a dereferenced tree
     containing one, is skipped with a `note`. Before copying, `du -sLk` the present sources;
     over `DELEGATE_AGENT_SETUP_MAX_MB` (default 64) → `agent_scrub_home`, die naming the largest.
   - Env: for each name from `lib/agents.py setup-env "$AGENT"` (validated `^[A-Z_][A-Z0-9_]*$`)
     that is set and non-empty in the current environment, append `printf '%s=%q\n'` to
     `<home>/.delegate-agent-env` (created mode 600 with `umask 077`). Values are never echoed.
   - Prints a one-line `note`: `agent setup: N paths, M env names copied for AGENT` (names only
     on request: the list of copied relative paths goes to `$RD/agent-setup.txt`, never values).
2. **`agent_scrub_home RD`** → `rm -rf "$TASK_DIR/agent-home"`; idempotent; never fails.
   O1 also makes `run_limited`'s INT/TERM trap remove `$TASK_DIR/agent-home` (absent → no-op),
   so a killed round leaves no copy.
3. **`run_worker_docker` agent variant**, selected by `AGENT_MODE=1` (B5 sets it only for the
   agent invocation). Differences from a delegate round, and nothing else:
   - image `$AGENT_IMAGE`; `--entrypoint /usr/local/bin/delegate-agent-launch`;
   - the agent home `$TASK_DIR/agent-home/r<n>` mounted read-write **at `$HOME`** (the owner's
     path) with `-e HOME=$HOME`, instead of `$TASK_DIR/home:/home/worker`; the cache volumes at
     `$HOME/.cache` and `$HOME/.npm`;
   - no `-v "$DELEGATE_API_KEY_FILE:/run/secrets/delegate_key:ro"`, no rules mount, no
     `render-opencode-config.py` mount, none of the `-e DELEGATE_BASE_URL/API_KEY_FILE/MODEL/
     MODEL_HARD/CONTEXT/OUTPUT/VISION/REASONING/REASONING_EFFORT/CHUNK_CAP`;
   - `-e` for each line of `$AGENT_ENV_FILE` (B3's `agents.py env` output: plain profile env
     and the base-URL pair only; O1 refuses any line whose name is not `^[A-Z_][A-Z0-9_]*$` or
     matches `lib/grants.py`'s `ENV_RESERVED` other than `DELEGATE_AGENT_BASE_URL(_ENV)`);
   - `NO_PROXY`/`no_proxy` gain `delegate-$ID-llmlog` in filtered/allow modes;
   - **no** grant docker-args (`--grant` is refused for agent runs; assert `GRANTS` empty and die
     otherwise), no guard shims;
   - identical: `--rm --init -i`, name, label, `--user`, worktree rw, `GIT_COMMON` ro, worktree
     gitdir, evidence, network args, `DATABASE_URL`, read mounts, `DELEGATE_EVIDENCE_DIR`,
     `DELEGATE_TASK`, `DELEGATE_WORKTREE`, `$DELEGATE_DOCKER_ARGS`, `-w`.
   - `AGENT_MODE=1` with the native runner → die (R14).
4. **`worker/agent-launch`** (bash; the agent image's entrypoint): `set -euo pipefail`; never touches
   `$HOME/.gitconfig` (it may be part of the owner's copied setup); `mkdir -p "$DELEGATE_EVIDENCE_DIR"` when
   set; if `$HOME/.delegate-agent-env` exists: `set -a; . "$HOME/.delegate-agent-env"; set +a;
   rm -f "$HOME/.delegate-agent-env"`; if `DELEGATE_AGENT_BASE_URL_ENV` matches
   `^[A-Z_][A-Z0-9_]*$`, `export "$DELEGATE_AGENT_BASE_URL_ENV=$DELEGATE_AGENT_BASE_URL"`; unset
   both; no argv → `agent-launch: no command` exit 2; `exec "$@"`. Never prints a value.
5. **`llmlog_start RD UPSTREAM DIALECT`** → prints the base URL the agent must use, or nothing
   when the proxy is not started. Only for `AGENT_MODE` runs, grant network mode
   `filtered`/`allow`/`open` (host: nothing, one `note`). `docker run -d --rm --name
   "delegate-$ID-llmlog" --label delegate.task="$ID" --network "$(svc_net)" --user UID:GID
   --read-only --tmpfs /tmp --entrypoint python3 -v "$DELEGATE_HOME/lib/llmlog.py:/opt/delegate/llmlog.py:ro"
   -v "$RD/llm:/log" "$DELEGATE_IMAGE" /opt/delegate/llmlog.py serve --listen 0.0.0.0:8080
   --upstream "$UPSTREAM" --dialect "$DIALECT" --log /log/llm.jsonl [--via http://<proxy>:3128]`
   — `--via` = `$EGRESS_NAME` in filtered, `$(egress_task_name)` in allow, none in open. No
   agent home, worktree, key or grant mounted. Waits ≤ 10 s for the port (a `docker exec`
   `python3 -c` connect loop); failure → `docker rm -f`, one `warn`, prints nothing. Success →
   prints `http://delegate-$ID-llmlog:8080` + the upstream's path.
6. **`llmlog_stop RD`** → `docker rm -f delegate-$ID-llmlog` (absent → no-op), then
   `python3 lib/llmlog.py summary "$RD/llm/llm.jsonl" > "$RD/llm.json"` when the log exists.
7. **`run_scorer TAG DIR OUT CMD`** → runs `bash -lc CMD` with cwd `DIR`, returns its rc, output
   to the caller's stdout/stderr. Docker: `docker run --rm --init --name "delegate-$ID-$TAG"
   --label delegate.task="$ID" --user UID:GID --entrypoint bash -v "$DIR:$DIR" -v
   "$OUT/.home-$TAG:/home/worker" -v "$OUT/evidence:$OUT/evidence:ro" -e HOME=/home/worker -e
   DELEGATE_EVIDENCE_DIR="$OUT/evidence"` + the task's network args (the same mode-case as
   `run_worker_docker`, factored into a helper `net_args` that **both** use, so they cannot drift)
   + `DATABASE_URL` of a fresh `delegate-$ID-spg` when `SERVICE=postgres` (started before, `rm -f`
   after, never the task's `-pg`) + `-w "$DIR" "$DELEGATE_IMAGE" -lc "$CMD"`. Never: `/run/secrets`,
   the delegate key, `DELEGATE_BASE_URL`/`MODEL`, rules, grant args, shims, `GIT_COMMON`, the
   worktree, `$TASK_DIR/home`, the agent home, `delegate-cache`/`delegate-npm`,
   `$DELEGATE_DOCKER_ARGS`. Native: `env -i HOME="$OUT/.home-$TAG" PATH="$PATH"
   DELEGATE_EVIDENCE_DIR="$OUT/evidence" bash -lc "$CMD"` in `DIR`.
8. **Reasoning effort**: `run_worker_docker` (delegate variant) adds `-e
   DELEGATE_REASONING_EFFORT="${REASONING_EFFORT:-}"`; `run_worker_native` passes the same to
   the config render; `lib/render-opencode-config.py` `model_entry` adds `"options":
   {"reasoningEffort": E}` when it is non-empty (no `options` key otherwise: today's render is
   byte-identical, `tests/test_render.sh` unchanged).

## `tests/test_sandbox_bench.sh` — write it

Offline, B2's docker stub, temp HOME (`HOME=$T/ownerhome` with a fake harness setup: a
`.claude/.credentials.json` with SENTINEL-C, `.claude/projects/x.jsonl` that must not be copied,
a symlink `.claude/settings.json → $T/elsewhere/settings.json`, a fifo), `ANTHROPIC_API_KEY=SENTINEL-K`
exported. Call the functions by sourcing a copy of `bin/delegate` with `main` neutralised (or add
a `DELEGATE_SOURCE_ONLY=1` guard to `main` — O1 may), and cover:
1. `agent_seed_home`: the listed files copied (the symlink's target content, not a link), the
   fifo skipped, `.claude/projects` absent, `.delegate-agent-env` mode 600 holding the key as a
   `%q` line; over-cap → died and nothing left; a profile path `../x` (fake `agents.py` output
   via a stub profile) → die.
2. Agent `docker run` line (stub log): launcher entrypoint, agent image, `-v <agent home>:$HOME`
   and `-e HOME=$HOME`, `HTTPS_PROXY=`, `NO_PROXY` with `-llmlog`, `GIT_COMMON` `:ro`; and absent:
   `delegate_key`, `/opt/delegate/opencode`, `DELEGATE_BASE_URL=`, `DELEGATE_MODEL=`,
   `$TASK_DIR/home`, any grant arg. Neither SENTINEL appears in the stub log, the round dir, or
   stderr.
3. `agent_scrub_home` removes the copy; `run_limited` interrupted with INT removes it too.
4. `worker/agent-launch` run directly with a temp HOME: sources and deletes the env file, exports
   the base URL pair, unsets its own variables, exit 2 without argv, prints no value.
5. `llmlog_start` in filtered mode: the `run -d` line has the llmlog mount, `--read-only`, `--via
   http://delegate-egress:3128`, and no agent home, worktree, `/run/secrets` or key; host mode →
   nothing started; `llmlog_stop` issues `rm -f`.
6. `run_scorer`: the absent list of item 7 holds for a task run with a grant that has env, an rw
   mount and a device; postgres case starts `-spg` and removes it; native variant's `$HOME` is
   the scratch home; `net_args` output is identical for `run_worker_docker` and `run_scorer` in
   all four network modes.
7. Effort: delegate-mode docker line carries `DELEGATE_REASONING_EFFORT=high` for a task with
   `REASONING_EFFORT=high`; rendered config has `options.reasoningEffort`; empty → no `options`.
8. `AGENT_MODE=1` with `DELEGATE_RUNNER=native` → die.
