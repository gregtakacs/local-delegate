# Task B6: `delegate score` — hidden checks and verify on copies, after the run, outside the sandbox

`"hard": true` — this step creates a new container launch (the scorer) and decides what hidden
checks can see: security code. Confine the container launch to one new function `run_scorer` and
the command to `cmd_score`; the reviewer reads both in full. Slice B step 6 of 10
(`docs/specs/b-design.md` §Scoring, R12).

## Goal

`delegate score ID --hidden DIR --out DIR [--verify CMD] [--timeout S]` scores a finished task
on copies of its final tree: the bundle's hidden checks first, then the visible verify command,
each in a fresh scorer container that holds no credential, no grant and no shared cache, so
hidden checks never enter a sandbox while an agent runs and the agent's leftovers cannot reach
anything worth taking. It writes `score.json` and keeps a pristine copy of the final tree for
review.

## Read first

- `docs/specs/b-design.md` §Scoring.
- `bin/delegate`: `cmd_exec` (the closest existing command), `load_task`, `lock_task` (how the
  round lock looks), `ensure_service` / `ensure_network` / `ensure_egress` / `svc_net` /
  `svc_name`, `run_worker_docker` (the network-mode case block to mirror; copy only what the
  contract lists), `run_worker_native`, `run_limited` / `stop_worker` (container names
  `delegate-$ID-$tag`), `cmd_rm` (sidecar cleanup), `usage()`.
- `evals/run.sh` (how hidden checks run today: `.eval-hidden/check.sh`, PASS/FAIL counting) and
  `evals/cases/ui-tip/hidden/check.sh` (it reads `$DELEGATE_EVIDENCE_DIR`),
  `evals/cases/long-refactor/hidden/check.sh` (it writes `/tmp`).
- `tests/docker-stub.sh` (B4/B5).

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

### `run_scorer TAG DIR CMD...` (new function beside `run_worker_docker`)

- Docker runner: `docker run --rm --init --name "delegate-$ID-$TAG" --label delegate.task="$ID"
  --user UID:GID --entrypoint bash -v "$DIR:$DIR" -v "<scratch home>:/home/worker" -v
  "$OUT/evidence:$OUT/evidence:ro" -e HOME=/home/worker -e DELEGATE_EVIDENCE_DIR="$OUT/evidence"
  <network args> [-e DATABASE_URL=...] -w "$DIR" "$DELEGATE_IMAGE" -lc "<cmd>"`.
  - Network args mirror the task's grant network mode exactly as `run_worker_docker` builds them
    (`filtered`/`allow` → task network + `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` to the same proxy;
    `open` → task network; `host` → `--network host`), using `ensure_network`/`ensure_egress`.
  - Not present, by construction (the tests assert each): `/run/secrets` anything, the delegate key,
    `DELEGATE_BASE_URL`, `DELEGATE_MODEL`, the rules mount, the grants' `docker-args` (no devices,
    no rw mounts, no grant env), the guard shims, `GIT_COMMON`, the worktree, `$TASK_DIR/home`,
    the shared `delegate-cache`/`delegate-npm` volumes, `$DELEGATE_DOCKER_ARGS`.
  - The scratch home is `out/.home-$TAG` (created, deleted with the copies).
  - `--entrypoint bash`: the worker entrypoint renders an opencode config that needs a model
    endpoint; the scorer must have none.
- Service: when the task's `SERVICE=postgres`, a fresh sidecar `delegate-$ID-spg` (same image,
  env and readiness loop as `ensure_service`, on the task network) is started before each pass and
  removed (`docker rm -f`) after it; `DATABASE_URL` points at it. It is never the task's own
  `delegate-$ID-pg`. `NO_PROXY` gains its name.
- Native runner: the same pass natively — `env -i HOME=<scratch home> PATH="$PATH"
  DELEGATE_EVIDENCE_DIR=... bash -lc "<cmd>"` with cwd `DIR` (no service: `SERVICE=postgres`
  under native dies at option time, as `delegate run` does).
- Each pass runs through `run_limited` with its tag (the existing timeout/stop path; a timeout
  sets `*_timed_out` and rc 124).

### `cmd_rm` / `reap_leftovers`

- `delegate rm` also removes `delegate-$ID-spg` and any `delegate-$ID-s*` container if present
  (they carry the task label, so check the existing label-based cleanup covers them; add only what
  is missing).

### `tests/test_score.sh` — create

Offline, the docker stub from B4 (its `run --rm` with `--entrypoint bash` executes the `-lc`
command in the `-w` dir on the host — add that behaviour to the stub if it lacks it). A temp task
made by a real `delegate run` with the stub agent or the stub opencode (whichever B4's rig makes
simplest), then:
1. Hidden dir with a `check.sh` printing 2 PASS + 1 FAIL and `cat`ing a file only present in the
   hidden dir → `score.json` counts 2/3, `hidden.log` has the hidden file's text; `final/` exists
   and has no `.eval-hidden`; `hidden-tree/` and `verify-tree/` are gone.
2. Verify `test ! -e .eval-hidden && echo ok` → `verify_rc` 0 (verify never sees hidden files).
3. Scorer `docker run` lines (stub log) contain `--entrypoint bash`, the task network,
   `HTTPS_PROXY=`, and do **not** contain `/run/secrets`, `delegate_key`, `DELEGATE_BASE_URL`,
   `delegate-cache`, `delegate-npm`, the task's home path, the worktree path, `GIT_COMMON`; with a
   task run under a grant that has env + a secret + an rw mount, none of those appear either.
4. `SERVICE=postgres` task: a `delegate-<id>-spg` `run -d` before each pass and an `rm -f` after,
   `DATABASE_URL=` naming `-spg`, never `-pg`.
5. Refusals: lock dir present → die with the R12 message and `--out` not created; a stub `ps`
   listing `delegate-<id>-r1` → same; `--hidden` inside the worktree → die; `--out` non-empty → die.
6. A hidden `check.sh` that sleeps past `--timeout 2` → `hidden_timed_out: true`, rc 124.
7. Native runner variant (`DELEGATE_RUNNER=native` task): runs, counts, `HOME` is the scratch home
   (`check.sh` prints `$HOME` and the test compares).

## Out of scope

- Writing ledger rows (B7). No change to `run_worker_docker`, `run_worker_native`, `lib/grants.py`,
  `lib/agents.py`, the images, or existing tests (additive stub changes only).

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check blames untracked deliverables; the harness
commits before the chain's verify runs. If that is the only failure mid-round, report it; never
edit that test.

```bash
set -o pipefail && bash -n bin/delegate && python3 -m py_compile lib/*.py && [ -f tests/test_score.sh ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && ! git diff --name-only delegate/b-5-telemetry | grep -qvE '^docs/specs/b-|^bin/delegate$|^docs/reference\.md$|^tests/docker-stub\.sh$|^tests/test_score\.sh$' && echo GATE-OK
```

## Report format

```text
STATUS: done|partial|blocked
SUMMARY: <=3 sentences
TESTS: <counts; which suites ran; gate result>
RISKS: <what might still be wrong>
DEVIATIONS: <departures from this spec and why, or none>
```
