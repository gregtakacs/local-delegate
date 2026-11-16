# Task B6: `delegate score` — hidden checks and verify on copies, after the run, outside the sandbox

`"hard": true` — this step decides what hidden checks can see and when scoring may start. Slice B
step 6 of 10, chain segment 2 (`docs/specs/b-design.md` §Scoring, R12). R19: the scorer
container itself is the orchestrator's `run_scorer` (`docs/specs/b-o1-sandbox.md` §Interface,
item 7); you call it, you never edit it — the verify's cage check fails if you do.

## Goal

`delegate score ID --hidden DIR --out DIR [--verify CMD] [--timeout S]` scores a finished task
on copies of its final tree: the bundle's hidden checks first, then the visible verify command,
each in a fresh scorer container that holds no credential, no grant and no shared cache, so
hidden checks never enter a sandbox while an agent runs and the agent's leftovers cannot reach
anything worth taking. It writes `score.json` and keeps a pristine copy of the final tree for
review.

## Read first

- `docs/specs/b-design.md` §Scoring; `docs/specs/b-o1-sandbox.md` §Interface item 7 and the
  `run_scorer` it describes (read the function in `bin/delegate`).
- `bin/delegate`: `cmd_exec` (the closest existing command), `load_task`, `lock_task` (how the
  round lock looks), `ensure_service` / `ensure_network` / `ensure_egress` / `svc_net` /
  `svc_name`, `run_worker_docker` (the network-mode case block to mirror; copy only what the
  contract lists), `run_worker_native`, `run_limited` / `stop_worker` (container names
  `delegate-$ID-$tag`), `cmd_rm` (sidecar cleanup), `usage()`.
- `evals/run.sh` (how hidden checks run today: `.eval-hidden/check.sh`, PASS/FAIL counting) and
  `evals/cases/ui-tip/hidden/check.sh` (it reads `$DELEGATE_EVIDENCE_DIR`),
  `evals/cases/long-refactor/hidden/check.sh` (it writes `/tmp`).
- `tests/docker-stub.sh` (B2) and `tests/test_sandbox_bench.sh` (O1).

## Contract

### `cmd_score`

1. Options: `--hidden DIR` (required; must contain `check.sh`), `--out DIR` (required; created;
   must be empty or absent), `--verify CMD` (optional; default the task's `VERIFY` from meta.env),
   `--timeout S` (per pass, default `DELEGATE_VERIFY_TIMEOUT`), `--no-verify`. Unknown option → die.
2. Refuse (die, nothing copied) while the run is not over: the task's round lock dir exists, or
   (docker runner) `docker ps -aq --filter "name=^delegate-$ID-r"` lists anything. Message:
   `score: task ID is still running; scoring happens after the run has ended (R12)`.
3. Refuse when `--hidden` resolves (realpath) to a path inside the task's worktree, inside
   `GIT_COMMON`, inside the task dir, or inside any of the task's read mounts — hidden checks that
   were reachable by the agent are not hidden.
4. Copies (host-side, never following symlinks out of the tree; use `tar -C "$WORKTREE"
   --exclude=./.git -cf - . | tar -C DEST -xf -`):
   - `out/final/` — pristine final tree, kept;
   - `out/evidence/` — copy of `$TASK_DIR/evidence` (may be empty), kept;
   - `out/hidden-tree/` — copy of `final/` plus `--hidden` copied to `out/hidden-tree/.eval-hidden/`;
   - `out/verify-tree/` — a fresh copy of `final/` (never the hidden tree: verify must not see
     hidden files).
5. Hidden pass (tag `s1`): `bash .eval-hidden/check.sh` in `out/hidden-tree` via `run_scorer`,
   output to `out/hidden.log`; count lines starting `PASS` / `FAIL`.
6. Verify pass (tag `s2`, skipped with `--no-verify` or an empty command): `bash -lc "$VERIFY"`
   in `out/verify-tree`, output to `out/verify.log`.
7. `out/score.json`: `{"task_id", "hidden_pass", "hidden_fail", "hidden_total", "hidden_rc",
   "hidden_s", "hidden_timed_out", "verify_rc" (null when skipped), "verify_s",
   "verify_timed_out", "final": "<abs path of out/final>"}`; then `hidden-tree/` and
   `verify-tree/` are deleted. Print one line `score ID: hidden P/T, verify RC` to stdout. Exit 0
   whenever scoring ran (whatever the checks said); non-zero only for refusals and setup errors.

### Scorer container

- Every pass calls `run_scorer TAG DIR OUT CMD` (O1) through `run_limited` with its tag (`s1`
  hidden, `s2` verify), so timeouts and `delegate stop` use the existing path; create
  `OUT/.home-TAG` before and delete it after. `run_scorer` decides the container (no credentials,
  no harness setup, no grants, no shared caches, a fresh `-spg` postgres when `SERVICE=postgres`);
  `cmd_score` decides only what is copied where and in which order.
- `SERVICE=postgres` under the native runner dies at option time, as `delegate run` does.

### `cmd_rm` / `reap_leftovers`

- `delegate rm` also removes `delegate-$ID-spg` and any `delegate-$ID-s*` container if present
  (they carry the task label, so check the existing label-based cleanup covers them; add only what
  is missing).

### `tests/test_score.sh` — create

Offline, the docker stub from B2 (its `run --rm` with `--entrypoint bash` executes the `-lc`
command in the `-w` dir on the host). A temp task made by a real delegate-mode `delegate run`
with the stub opencode (as `tests/test_docker_stub.sh` does), then:
1. Hidden dir with a `check.sh` printing 2 PASS + 1 FAIL and `cat`ing a file only present in the
   hidden dir → `score.json` counts 2/3, `hidden.log` has the hidden file's text; `final/` exists
   and has no `.eval-hidden`; `hidden-tree/` and `verify-tree/` are gone.
2. Verify `test ! -e .eval-hidden && echo ok` → `verify_rc` 0 (verify never sees hidden files).
3. Scorer `docker run` lines (stub log) contain `--entrypoint bash`, the task network,
   `HTTPS_PROXY=`, and do **not** contain `/run/secrets`, `delegate_key`, `DELEGATE_BASE_URL`,
   `delegate-cache`, `delegate-npm`, the task's home path, the worktree path, `GIT_COMMON`, the
   agent home (O1's own suite covers the scorer in depth; this checks `cmd_score` calls it).
4. `SERVICE=postgres` task: a `delegate-<id>-spg` `run -d` before each pass and an `rm -f` after,
   `DATABASE_URL=` naming `-spg`, never `-pg`.
5. Refusals: lock dir present → die with the R12 message and `--out` not created; a stub `ps`
   listing `delegate-<id>-r1` → same; `--hidden` inside the worktree → die; `--out` non-empty → die.
6. A hidden `check.sh` that sleeps past `--timeout 2` → `hidden_timed_out: true`, rc 124.
7. Native runner variant (`DELEGATE_RUNNER=native` task): runs, counts, `HOME` is the scratch home
   (`check.sh` prints `$HOME` and the test compares).

## Out of scope

- Writing ledger rows (B7). No edits to `run_scorer` or any other O1 function or file (the cage
  check), `run_worker_*`, `lib/grants.py`, `lib/agents.py`, the images, or existing tests
  (additive changes to `tests/docker-stub.sh` only, if a behaviour you need is missing).

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check blames untracked deliverables; the harness
commits before the chain's verify runs. If that is the only failure mid-round, report it; never
edit that test. The **cage check** fails if this step changed any sandbox function or file
(R19: orchestrator code; `docs/specs/b-design.md` §Who writes what) — never "fix" it by editing
the check; leave the sandbox code alone and report what you needed under DEVIATIONS.

```bash
set -o pipefail && bash -n bin/delegate && python3 -m py_compile lib/*.py && [ -f tests/test_score.sh ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && for fn in run_worker run_worker_docker run_worker_native ensure_network ensure_egress ensure_task_egress host_args read_mount_args make_guard_shims net_args run_limited run_scorer agent_seed_home agent_scrub_home llmlog_start llmlog_stop; do cmp -s <(git show b-o1-sandbox:bin/delegate | sed -n "/^$fn() {/,/^}/p") <(sed -n "/^$fn() {/,/^}/p" bin/delegate) || { echo "CAGE CHANGED $fn (R19: orchestrator code)"; exit 1; }; done && { git diff --quiet b-o1-sandbox -- lib/grants.py worker/egress.Dockerfile worker/egress-entrypoint.sh worker/entrypoint.sh lib/render-opencode-config.py worker/agent-launch || { echo "CAGE CHANGED files (R19: orchestrator code)"; exit 1; }; } && ! git diff --name-only delegate/b-5-agent-round | grep -qvE '^docs/specs/b-|^bin/delegate$|^docs/reference\.md$|^tests/docker-stub\.sh$|^tests/test_score\.sh$' && echo GATE-OK
```

## Report format

```text
STATUS: done|partial|blocked
SUMMARY: <=3 sentences
TESTS: <counts; which suites ran; gate result>
RISKS: <what might still be wrong>
DEVIATIONS: <departures from this spec and why, or none>
```
