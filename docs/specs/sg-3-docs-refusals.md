# Document untrusted repositories, and test the refusals that need no docker

## Goal
`docs/reference.md` documents the new setting; `tests/test_untrusted_repo.sh` proves every
untrusted-mode refusal in `bin/delegate` that fires before a container would start, plus `lib/safepath.py`.

## Read first
- `docs/specs/sg-design.md` (all of it: the section text must agree with it)
- `docs/reference.md` (find where configuration variables are listed; follow its style)
- `bin/delegate`: the `untrusted`, `untrusted_repo_check`, `untrusted_task_check` functions, the `if untrusted` blocks in `cmd_run`, and `cmd_continue/finish/verify/exec/diff/rm`
- `lib/safepath.py`
- `tests/test_worktree_layout.sh` (how a test runs `bin/delegate` with temp HOME/state/config and a fabricated task)

## Contract
### docs/reference.md
A section `## Untrusted repositories` (and a row/entry for each of `DELEGATE_UNTRUSTED_REPO`, `DELEGATE_SANDBOX_IMAGE`, `DELEGATE_SANDBOX_TIMEOUT` wherever the reference lists config variables). Content: what the setting means (someone else can write the repo's .git, working tree and task worktrees), off by default and nothing changes when off, sticky per task (`UNTRUSTED=1` in meta.env), what runs in the sandbox (every git call and path step for that repo) and its limits (no network, no capabilities, read-only root, host uid, only the repo and `<DELEGATE_WORKTREES>/<project>` mounted), the inode check on worker mounts, what is refused (`--here`, native runner, `--orb`, `--read` inside the repo/worktrees, a repo path that is not the top of a main checkout or has a symlink/commondir/comma, old flat-layout tasks, in-place and native tasks except `rm`, in-place chain plans), and the behaviour differences from sg-design §5. Neutral wording: name no particular product that uses it; at most "for example a service that runs delegate for a container that can write the project".

### tests/test_untrusted_repo.sh (no docker, no network)
`check` style. A stub `docker` first on PATH that exits 99 and logs its argv to a file, so any attempt to start a container is visible; `DELEGATE_IMAGE_ALLOW_STALE=1`, a dummy `DELEGATE_BASE_URLS`/`DELEGATE_MODEL`/API key file, temp HOME/state/worktrees, `DELEGATE_CONFIG` pointing at a temp file, `DELEGATE_PROGRESS=0`, `DELEGATE_PRUNE_DAYS=0`. Each refusal: non-zero exit, the message contains `DELEGATE_UNTRUSTED_REPO=1` (or the documented message), and the stub docker was never called:
1. `DELEGATE_UNTRUSTED_REPO=2` → refused for every command (try `list`).
2. `run --here`; `DELEGATE_RUNNER=native run`; `run --orb f`.
3. `run --repo <subdir of a repo>`; repo whose `.git` is a gitfile (`git worktree add` makes one); repo whose `.git` is a symlink to a real `.git`; repo with `.git/commondir`; repo reached through a symlinked parent folder is accepted up to the docker step (realpath'd: the stub is then called, which is fine to assert separately); repo path containing a comma.
4. `run --read <path inside the repo>` refused.
5. fabricated existing tasks (meta.env written by the test, with `UNTRUSTED=1` and NO env var, to prove stickiness): an in-place task (`HERE=1`) refused by `diff`, `continue -m x`, `verify`, `exec -- true`; a native task (`RUNNER=native`) refused by `continue`/`verify`/`exec`; a flat-layout task (`WORKTREE=$W/repo-x`) refused by `diff`; a task whose `WT_GITDIR` is outside `$REPO/.git/worktrees/` refused by `diff`; a task whose `GIT_COMMON` is not `$REPO/.git` refused.
6. With the variable unset, a normal repo's `run` gets past these checks exactly as before (it reaches the endpoint probe and fails there on the dummy URL, with no `DELEGATE_UNTRUSTED_REPO` text in the output).
7. `lib/safepath.py`: prints `PATH<TAB>DEV:INO` matching `stat -c %d:%i` for a real dir; exit 3 + `SECURITY` for a symlink at the last component, at a middle component, for a file, for a relative path, for `a/../b`, for a trailing slash; exit 2 with no args.

## Acceptance criteria
- The full gate passes: `bash -n bin/delegate && python3 -m py_compile lib/*.py && for t in tests/test_*.sh; do bash "$t" || exit 1; done`.
- `bash tests/test_untrusted_repo.sh` prints only `ok` lines.

## Out of scope
Changing `bin/delegate`, `lib/safepath.py` or `lib/sandbox-git.sh`: they are the sandbox core, written by the lead. If a refusal does not behave as the contract says, do not change the code: report it under QUESTIONS (STATUS: blocked) with the command and output. The docker-backed hostile tests are written by the lead in a separate file.
