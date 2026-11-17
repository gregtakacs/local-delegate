# SG: untrusted repositories (sandboxed host-side git)

2026-11-17. Security slice, written and reviewed by a Claude lead. The sandbox core
(`lib/sandbox-git.sh`, `lib/safepath.py`, the `sbx`/`untrusted*` functions and the worker-mount
check in `bin/delegate`) is lead-written: the worker must not write the code that limits the worker.
The chain's steps do the surrounding plumbing, docs and tests.

## 1. The setting

`DELEGATE_UNTRUSTED_REPO=1` (env or `config.env`; default `0`). It means: someone other than you
can write this repository's `.git`, its working tree and its task worktrees
(`<DELEGATE_WORKTREES>/<project>/…`). With it `0`, delegate behaves exactly as before; every
existing suite passes unchanged. A task created with it on records `UNTRUSTED=1` in `meta.env`
(host-owned state), so later commands treat it the same even without the env.

Companions: `DELEGATE_SANDBOX_IMAGE` (default `DELEGATE_IMAGE`; needs bash, git ≥ 2.42, coreutils)
and `DELEGATE_SANDBOX_TIMEOUT` (600 s per sandboxed step). Nothing in delegate names a caller;
codehub's broker is one caller that sets it for the delegate children it starts.

## 2. Threats and mechanisms

| # | Threat (host delegate trusting state the other party writes) | Mechanism |
|---|---|---|
| 1 | Host git runs the repo's `core.fsmonitor` (status), hooks (`post-checkout` on worktree add), `filter.*.clean/smudge` (round commit, checkout), `textconv` (diff), on `rm`, `diff`, `run`, `continue` | Every git call for the repo goes through `sbx`: a `docker run --rm` with `--network none`, `--cap-drop ALL`, `no-new-privileges`, read-only root, `/tmp` tmpfs, the host uid, and bind mounts of only `REPO` and `<W>/<project>`. No secret, no Docker socket, no other repo. Hooks, fsmonitor, external diff and signing are also switched off in there (`-c`), filters and textconv run but can reach only those mounts. |
| 2 | `rev-parse --show-toplevel` / `--git-common-dir` follow `core.worktree` or a gitfile into another repo | In untrusted mode delegate never asks git where the repo is. `--repo` is `realpath`'d once and must be the top of a main checkout: `REPO/.git` a real directory, no `commondir`, no symlink on either path (`untrusted_repo_check`). `GIT_COMMON` is the string `REPO/.git`. In the sandbox every call pins `--git-dir`/`--work-tree` (and `GIT_COMMON_DIR` for a task worktree, so a worker-written `commondir` is ignored). |
| 3a | Swapping a task's leaf `<W>/<project>/<leaf>` or `.git/worktrees/<n>` for a symlink, so `check_gitlink`'s `rm -rf` hits another repo | `check_gitlink`, `--copy` and every path step run inside the sandbox, where a symlink can only reach the two mounts. Ops also refuse a worktree or gitdir path that is (or runs through) a symlink (`plain`). |
| 3b | docker `-v SRC:SRC` follows a symlinked source, so the worker gets any host dir (rw for the worktree and gitdir) | `lib/safepath.py` walks each source from `/` with `O_NOFOLLOW` per component and records the dev:ino of the directory it opened. The sources are mounted with `--mount` (a missing source fails rather than being created as root), and `sandbox-git.sh exec-next` runs first as the container's entrypoint, compares each mount's dev:ino with the host's and only then execs the image's own entrypoint. If a path is swapped between the two checks, the mounted inode differs and the start stops with exit 3 before any worker code runs. Same check on every `sbx` container. |
| 4 | Inline `python3 -c` / `python3 -` helpers put the cwd on `sys.path` | `-I` on every inline helper, unconditionally (step 1): it changes nothing else these helpers rely on. Script helpers (`python3 lib/x.py`) already get the script dir, not the cwd. |
| 5 | `--copy` reads `REPO/<path>` through repo-chosen symlinked folders and writes through the new worktree's checked-out symlinks | done by the sandbox `add` op |
| 6 | `--read` inside the repo or its worktrees, re-mounted (re-resolved) every round | refused in untrusted mode |
| 7 | `--here`, the native runner, `--orb` (reads its file from the repo on the host) | refused in untrusted mode; existing in-place/native tasks may only be `rm`'d |
| 8 | An old flat-layout task (`<W>/<leaf>`): its "worktrees folder" would be every project's | refused in untrusted mode |
| 9 | `delegate chain` runs `git status/add/commit` (in place) and `git diff --stat` on the repo | in untrusted mode an in-place plan is refused and the closing diffstat goes through `delegate _repo-git` (sandboxed) (step 2) |

## 3. What still runs on the host, and why it is safe

- `realpath`, `[ -d ]`, `[ -L ]`, `[ -e ]` on the repo and worktree paths: tests only, nothing is
  read or written through them, and the real checks are `safepath` plus the in-container inode check.
- `mkdir -p <W>/<project>`: under the owner's `DELEGATE_WORKTREES` (realpath'd); a planted symlink
  there makes `mkdir` a no-op and the following `safepath` refuses it.
- `sbx_identity`: `git config --includes --get user.{name,email}` with `GIT_DIR=REPO/.git`, cwd `/`,
  `timeout 10`. This keeps the owner's own identity rules (including `includeIf hasconfig:` noreply
  rules) for the round commit. `git config --get` only reads config and runs nothing. What is left:
  the repo's `include.path` can make it read another git-config-format file, and only the
  `user.*` value of that file can surface, in the repo's own commit. Accepted.
- Task state (`$DELEGATE_STATE/<id>`), the task's `home` and `evidence` mounts, grants,
  `report/peek/list/top/stats/ledger/quarantine`: host-owned files. They hold paths only as
  strings for display and filtering (`taskstate.py --repo` realpaths the filter and the stored
  `REPO`, which the other party cannot replace, only write inside).
- `docker image inspect` for the image's entrypoint: the owner's image.

## 4. Assumptions

The other party can write inside `REPO` and inside `<W>/<project>`, but cannot replace those two
directories themselves or anything above them (true in codehub: both are bind mounts in the
project's container). The owner's grant files are trusted even when they name paths in the repo.

## 5. Image and cost

The sandbox uses the worker image (`delegate-worker:local`, git 2.47), so there is nothing new to
build, and the script is bind-mounted from `DELEGATE_HOME`, so the image stamp does not change. A
container start costs about 0.3 s here. A run takes 2 steps (probe, add), a round's finish 3
(gitlink, commit-round, diffstat), `diff` 3 and `rm` 2–3, so a few seconds on rounds that take minutes.

Behaviour that differs with the setting on (documented in `docs/reference.md`): repo hooks don't
run on worktree add; a filter that needs network or a binary missing from the image (git-lfs)
fails; commits are never signed; diff output is never coloured.

## 6. Out of scope

A worker that rewrites `$WT_GITDIR/commondir` (or plants filters through it) so the harness's
*default-mode* host git runs code. This affects **default mode**, is independent of this setting
and is left unchanged here because the setting-off behaviour is binding. It goes to the owner
(sg-design §7).

## 7. For the owner

1. The default-mode gap above. A cheap fix would pin `GIT_COMMON_DIR` in `wgit` and check
   `commondir` after each round, but it changes default behaviour, so it is the owner's call.
2. The broker allows `--orb`; with this setting on, delegate refuses it.
3. `delegate run` prunes idle tasks of every repo. With the setting on, an old flat-layout task
   cannot be removed that way (refused) and stays until the owner prunes it without the setting.
