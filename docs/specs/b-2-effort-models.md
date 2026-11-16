# Task B2: `--effort`, `delegate models`, and the offline docker stub

`"hard": false`. Slice B step 2 of 10, chain segment 1 (`docs/specs/b-design.md` §Conditions
and plans, R18, Owner question 5). R19: you do not touch `run_worker_*`,
`lib/render-opencode-config.py` or any egress/grant code — the orchestrator wires the effort into
the container in its piece `b-o1-sandbox`; the verify's cage check fails if you change them.

## Goal

Delegate mode can pick a model and a reasoning effort among what the already-configured endpoint
serves: `delegate models` lists the model ids that endpoint returns with the configured key;
`delegate run --effort E` records the effort as its own task field. And the repo gets an offline
`docker` stub that later steps (and the orchestrator's tests) use to exercise the docker runner
without docker.

## Read first

- `docs/specs/b-design.md` §Who writes what (the cage list), §Conditions and plans.
- `bin/delegate`: `need_config`, `pick_base_url`, `cmd_run` (option parsing, meta.env block),
  `cmd_continue`, `load_task`, `usage()`, `main()`; and **read only** `run_worker_docker`,
  `ensure_network`, `ensure_egress`, `ensure_service`, `check_image_fresh`, `run_limited`,
  `stop_worker`, `reap_leftovers` — the docker calls your stub must answer.
- `tests/e2e-rig.sh` (sourced-helper style, the stub `/models` endpoint), `tests/test_chain.sh`.

## Contract

### `bin/delegate`

- `cmd_run`: `--effort E` (must match `^[a-z]{1,16}$`, else `die "--effort: one lowercase word, e.g. high"`);
  meta.env block gains `REASONING_EFFORT=%q` (empty when not given). It has no effect on the
  container yet (O1 passes it as `DELEGATE_REASONING_EFFORT`).
- `cmd_continue`: `--effort` → `die "continue: a task keeps the effort it was run with"`.
- `delegate models [--json]`: `need_config`, `pick_base_url`, then GET `<base>/models` with the
  configured key (the same `curl` form `pick_base_url` uses: key in the `Authorization` header
  read from the key file, never on the command line as an argument other than that header);
  prints each `data[].id`, one per line, sorted (with `--json`: `{"endpoint": URL, "models":
  [...]}`). No answer / not JSON → `die "models: <url> gave no model list"`. Never prints the key.
- `usage()` lines for `--effort` and `models`.

### `tests/docker-stub.sh` — create (sourced, never run; header comment documents every behaviour)

`docker_stub_install DIR` writes an executable `DIR/docker` (bash) that appends every invocation
(`printf '%q ' "$@"; echo`) to `$DOCKER_STUB_LOG`, and emulates:
- `image inspect IMG [-f FMT]` → exit 0 unless IMG is listed in `$DOCKER_STUB_MISSING`; `-f
  '{{.Id}}'` → `sha256:stub`; any other format → empty line.
- `network inspect N` → exit 0 iff `$DOCKER_STUB_STATE/net-N` exists; `network create ... N` →
  creates it; `network connect|disconnect|rm|ls` → exit 0 (ls prints the created ones).
- `inspect -f FMT NAME` → `true` for `.State.Running`, empty for labels; `container inspect
  NAME` → exit 0 iff `$DOCKER_STUB_STATE/ctr-NAME` exists.
- `ps ... ` → prints the lines of `$DOCKER_STUB_PS` (default empty); `rm`, `kill`, `start`,
  `volume create`, `build` → exit 0; `exec ... pg_isready ...` → exit 0; other `exec` → exit 0.
- `run -d ... --name NAME ...` → creates `ctr-NAME`, prints `stubid`.
- `run --rm ...`: parse options the way `docker run` would for the options `bin/delegate` passes
  (`--name/-v/-e/-w/--network/--user/--label/--entrypoint/--mount/--device/--group-add/
  --device-cgroup-rule/--add-host/--tmpfs` take a value; `--rm/--init/-i/-d/--read-only` don't);
  the first non-option word is the image, the rest the command. Then: if `$DOCKER_STUB_HOOK` is
  an executable, run it with env `STUB_IMAGE`, `STUB_ENTRYPOINT`, `STUB_WORKDIR`, `STUB_NAME`,
  `STUB_ENVFILE` (a temp file of the `-e` pairs, one per line) and argv = the command, stdin
  passed through, and exit with its status. Otherwise: with `--entrypoint bash` or a command
  `bash -lc CMD`, run `bash -c CMD` in the `-w` dir with the `-e` pairs exported; with a command
  starting `opencode run`, run `$DOCKER_STUB_OPENCODE` (an executable) in the `-w` dir with stdin;
  else exit 0.

### `tests/test_docker_stub.sh` — create

Proves the stub against today's real docker path, offline: temp HOME/state/worktrees, a temp git
repo, config at the e2e rig's stub `/models` endpoint and a temp key file, `DELEGATE_RUNNER=docker`,
`DELEGATE_IMAGE_ALLOW_STALE=1`, stub first on PATH, `DOCKER_STUB_OPENCODE` = a script that writes
`hello.txt` and prints one `step_start` + one `step_finish` opencode event and a final text with
`STATUS: done`. At least:
1. `delegate run spec.md --verify 'test -f hello.txt'` exits 0; the round commit has `hello.txt`;
   `report.json` status `done`, `verify_rc` 0; the stub log has a `network create` for
   `delegate-<id>` and a worker `run --rm` with `-v <key file>:/run/secrets/delegate_key:ro`.
2. `--effort high` → meta.env `REASONING_EFFORT=high`; `--effort High` and `--effort 'a b'` die;
   `continue <id> --effort low` dies with the stated message.
3. `delegate models` prints the stub endpoint's ids sorted; `--json` parses; an endpoint returning
   garbage → the die message; the key file's sentinel content never appears in any output or log.
4. `$DOCKER_STUB_HOOK` receives the image, entrypoint, workdir and env file for a run.

## Out of scope

- Agent rounds, the proxy, scoring. Do not modify `run_worker_*`, `ensure_*`, `host_args`,
  `read_mount_args`, `make_guard_shims`, `lib/grants.py`, `lib/render-opencode-config.py`,
  `worker/*`, or existing tests.

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check blames untracked deliverables; the harness
commits before the chain's verify runs. If that is the only failure mid-round, report it; never
edit that test. The **cage check** fails if this step changed any sandbox function or file
(R19: orchestrator code; `docs/specs/b-design.md` §Who writes what) — never "fix" it by editing
the check; leave the sandbox code alone and report what you needed under DEVIATIONS.

```bash
set -o pipefail && bash -n bin/delegate && python3 -m py_compile lib/*.py && [ -f tests/test_docker_stub.sh ] && [ -f tests/docker-stub.sh ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && for fn in run_worker run_worker_docker run_worker_native ensure_network ensure_egress ensure_task_egress host_args read_mount_args make_guard_shims; do cmp -s <(git show bench:bin/delegate | sed -n "/^$fn() {/,/^}/p") <(sed -n "/^$fn() {/,/^}/p" bin/delegate) || { echo "CAGE CHANGED $fn (R19: orchestrator code)"; exit 1; }; done && { git diff --quiet bench -- lib/grants.py worker/egress.Dockerfile worker/egress-entrypoint.sh worker/entrypoint.sh lib/render-opencode-config.py worker/agent-launch || { echo "CAGE CHANGED files (R19: orchestrator code)"; exit 1; }; } && ! git diff --name-only delegate/b-1-bench-core | grep -qvE '^docs/specs/b-|^bin/delegate$|^config\.example\.env$|^docs/reference\.md$|^tests/docker-stub\.sh$|^tests/test_docker_stub\.sh$' && echo GATE-OK
```

## Report format

```text
STATUS: done|partial|blocked
SUMMARY: <=3 sentences
TESTS: <counts; which suites ran; gate result>
RISKS: <what might still be wrong>
DEVIATIONS: <departures from this spec and why, or none>
```
