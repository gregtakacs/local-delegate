# Per-repo worktree layout and a project filter for list, top and stats

## Goal

codehub's A2 slice gives every project its own container. It mounts only that project's
worktree folder, `<DELEGATE_WORKTREES>/<project>/`, into the container at the same host path.
A host-side broker runs delegate for the container and must show it only that project's tasks.
This step makes two changes to delegate:

1. New tasks get their worktree at `<DELEGATE_WORKTREES>/<project>/<leaf>` instead of the flat
   `<DELEGATE_WORKTREES>/<id>`. Tasks created in the old flat layout keep working for report,
   diff, rm, continue, verify, exec, peek and chain, because those all read `WORKTREE` from the
   task's `meta.env`.
2. `delegate list --repo PATH` and `delegate top --repo PATH` show only that project's tasks.
   `delegate stats --repo R` also matches when R and the row's project are the same directory
   under different spellings.

## Read first

- `AGENTS.md`: the full gate and the test style. Every suite is `tests/test_*.sh` with the
  `check NAME 'EXPR'` helper, temp dirs only, and no docker or model.
- `bin/delegate`:
  - `cmd_run` (around lines 920 to 1010): `ID="$reponame-$SLUG"`,
    `WORKTREE="$DELEGATE_WORKTREES/$ID"`, the `[ ! -e "$WORKTREE" ]` check,
    `mkdir -p ... "$DELEGATE_WORKTREES"`, `git worktree add`, and `GIT_COMMON` computed from the
    repo.
  - `cmd_list`, `cmd_top`, `cmd_rm`, `cmd_stats` and `STATS_USAGE`.
  - `usage()`.
- `lib/taskstate.py`:
  - `state()`, whose returned dict already carries `repo`.
  - `all_states`, `visible_tasks`, `cmd_top`, `frame`, `main` (the `statuses` command), `leads`.
- `lib/ledger.py`: `project_of(git_common, repo)` (the definition of a project), `_axis`, and
  `stats()`'s `repo` filter.
- `tests/test_top.sh`: the `mk` helper that fabricates state dirs. Imitate it.
- `tests/test_stats.sh`, lines 245 to 260: the project-axis case.
- `tests/test_orchestrator.sh`: how a bash function is extracted from `bin/delegate` with `sed`
  and tested on its own.
- `docs/reference.md`: where the worktree, `list`, `top` and `stats` are documented.

## Contract

### 1. Worktree path (new tasks only, not `--here`)

- Add a function to `bin/delegate`:

  ```bash
  task_worktree_path() { # GIT_COMMON REPO ID -> prints the worktree path for a new task
  ```

- The **project dir name** `P`:
  - when `GIT_COMMON` ends in `/.git`, `P` is the basename of `GIT_COMMON` minus that `/.git`
    (the main checkout's folder name);
  - otherwise (a bare common dir, or an empty one), `P` is the basename of `REPO`.
- The **leaf** `L`: `ID` with a leading `P-` removed when `ID` starts with `P-`; otherwise `ID`.
  - A task run from the main checkout `~/src/codehub` with slug `x`: `ID=codehub-x`, path
    `<W>/codehub/x`.
  - A task run from a linked worktree `~/w/codehub-lead` of the same repo: `ID=codehub-lead-x`,
    path `<W>/codehub/lead-x`.
- It prints `$DELEGATE_WORKTREES/$P/$L`.
- `cmd_run` (the non-`--here` branch) computes `GIT_COMMON` before the worktree path is needed;
  move that line up if it has to. It then sets
  `WORKTREE=$(task_worktree_path "$GIT_COMMON" "$repo" "$ID")`.
- Keep the existing check `[ ! -e "$WORKTREE" ] || die "worktree path already exists: $WORKTREE"`.
- Add one new refusal before `mkdir`: if `$DELEGATE_WORKTREES/$P` exists and is not a directory,
  or if it contains a `.git` entry (it is a checkout itself, for example an old flat-layout
  worktree named like a project), die with exactly:
  `delegate: $DELEGATE_WORKTREES/$P is not a per-repo worktree folder (it is a checkout or a file); move it or set DELEGATE_WORKTREES`
- Replace `mkdir -p "$TASK_DIR/rounds" "$DELEGATE_WORKTREES"` with a version that also creates
  `$DELEGATE_WORKTREES/$P`. `--here` tasks create no worktree folder, as today.
- Unchanged:
  - the task id: still `<basename of repo>-<slug>`;
  - the branch: still `delegate/<slug>`;
  - `meta.env` still records the full `WORKTREE` path.
- `cmd_rm` removes the task's worktree as today, but **never** removes the per-repo folder
  `<W>/<P>`, even when it is left empty: a container bind-mounts that folder, and removing it
  would break the mount.

### 2. Old flat-layout tasks

No migration. A task whose `meta.env` says `WORKTREE=<W>/<id>` keeps that path for every
command. Nothing anywhere may recompute a worktree path from an id; grep for it.

### 3. `delegate list [--repo PATH]`

- `cmd_list` accepts an optional `--repo PATH`. Anything else, or `--repo` with no value, fails
  with `usage: delegate list [--repo PATH]` and exit 2.
- It passes the filter through to `taskstate.py statuses --repo PATH`.
- The output format is unchanged. With a filter that matches nothing it prints `(no tasks)`.

### 4. `delegate top [--repo PATH]`

- `lib/taskstate.py cmd_top` gains `--repo PATH`.
- When it is given:
  - only matching tasks are shown, and the "N task(s)" count counts only those;
  - the hidden-task count counts only matching tasks;
  - the Claude leads section is **not shown at all**. Leads are not per project, and their
    names would leak other work. `lead_rows` is empty and the header says `0 lead(s)`.
- `delegate top ID --repo PATH` for a task that does not match prints
  `delegate top: no such task: ID (see: delegate list)` and exits 1, exactly as for an unknown
  id.

### 5. The match rule (one function, used by list and top)

- In `lib/taskstate.py`:

  ```python
  def task_project(meta) -> str:  # the main checkout, as lib/ledger.py's project_of defines it
  def matches_repo(t_or_meta, repo_filter: str) -> bool:
  ```

- `state()` adds two keys to its dict: `"project": task_project(meta)` and
  `"git_common": meta.get("GIT_COMMON") or ""`.
- A task matches `PATH` when `os.path.realpath(PATH)` equals `os.path.realpath(project)` or
  `os.path.realpath(REPO)`.
  - `PATH` need not exist, and neither do the task's paths: `realpath` of a missing path is
    still a string, compared as is.
- An empty filter matches every task (no filter given).
- `taskstate.py statuses --repo PATH` filters the same way.

### 6. `delegate stats --repo R`

- Keep the exact-match behaviour.
- Also count a row as matching when R and the row's repo axis (`_axis(row, "repo")`, which is
  the project when the row has one) are both absolute paths and their `os.path.realpath` are
  equal.
- Update the `--repo` wording in `usage()`/`STATS_USAGE` and in `docs/reference.md` to say so.

### 7. Docs

- `docs/reference.md`:
  - one paragraph on the per-repo layout, including the "old tasks keep their path" rule and
    the "per-repo folder is never removed" rule;
  - the `--repo` filters on `list` and `top`.
- `usage()` lines for `list` and `top` name `--repo PATH`.
- `config.example.env`: one comment line on `DELEGATE_WORKTREES` saying worktrees go under
  `<DELEGATE_WORKTREES>/<project>/<slug>`.

## Behaviour and edge cases

- The repo is a main checkout: `<W>/<repo>/<slug>`.
- The repo is a linked worktree of project P: `<W>/P/<id minus "P-" or id>`.
- `<W>/<P>` already exists as a normal folder holding other tasks' worktrees: fine, the task is
  added beside them.
- `<W>/<P>` is a checkout (it has `.git`), or it is a file: refused with the message above
  before anything is created (no branch, no task dir left behind; check the refusal comes
  before `git worktree add` and before `mkdir -p "$TASK_DIR/rounds"`).
- `rm` of an old flat-layout task removes `<W>/<id>` as today.
- `rm` of a new-layout task removes `<W>/<P>/<leaf>`, keeps `<W>/<P>`, and runs
  `git worktree prune`.
- `list --repo` with a relative path: resolved by `realpath` against the cwd.
- `list --repo` with a path that has a trailing slash, or that goes through a symlink to the
  project: still matches.

## Acceptance criteria

Add a new suite `tests/test_worktree_layout.sh` in the existing style (temp dir, real `git`, no
docker, no model, no network, and `DELEGATE_STATE`, `DELEGATE_WORKTREES`, `DELEGATE_CONFIG`,
`XDG_*` and `HOME` all under the temp dir). It must cover:

1. `task_worktree_path`, extracted with `sed` as in `tests/test_orchestrator.sh`, for three
   cases:
   - a main checkout → `<W>/repo/slug`;
   - a linked worktree named `repo-lead` → `<W>/repo/lead-slug`;
   - a bare-or-empty `GIT_COMMON` → `<W>/<basename REPO>/<id minus prefix>`.
2. The refusal: a fake `<W>/repo` holding `.git` makes the guard die with the exact message. A
   plain folder passes. Test the guard as a function, or by running `cmd_run` far enough;
   choose what needs no endpoint, and say which in a comment.
3. Two fabricated tasks in a real git repo, each with a real `git worktree add`, `meta.env`
   written as `cmd_run` writes it (`RUNNER=native`, `HERE=0`, `GIT_COMMON` set) and one round
   with a `report.md` and a `commit` file:
   - one in the old flat layout `<W>/repo-old`;
   - one in the new layout `<W>/repo/new`.

   For both, run the real `bin/delegate` with `DELEGATE_CONFIG` pointing at a temp config
   (`DELEGATE_RUNNER=native`):
   - `delegate report ID` prints the report;
   - `delegate diff ID` prints a diffstat naming the committed file;
   - `delegate rm ID` removes the worktree. `<W>/repo` still exists after the new-layout task
     is removed.
4. `delegate list`: with no filter both tasks are listed. A third fabricated task whose
   `REPO`/`GIT_COMMON` name another repo is not listed under `--repo <the first repo>`, and is
   listed under `--repo <the other repo>`. A symlinked path to the first repo matches it. A
   filter matching nothing prints `(no tasks)`. `list --bogus` exits 2.
5. `taskstate.py top --once --repo X`:
   - only X's tasks appear;
   - no lead row appears, even with a lead state file present under the cache dir (fabricate
     one as `tests/test_top.sh` does);
   - `top ID --repo X` for another repo's task exits 1 with the no-such-task line.
6. `stats --repo` with a symlinked spelling of a row's project counts that row. An unrelated
   path counts nothing.

Then run the full gate, all of it:

```
bash -n bin/delegate && python3 -m py_compile lib/*.py && for t in tests/test_*.sh; do bash "$t" || exit 1; done
```

→ exit 0. `tests/test_top.sh` and `tests/test_stats.sh` must still pass unchanged. If an
existing assertion there really pins the old flat path, change only that assertion and say so
in DEVIATIONS.

## Out of scope

- Do not touch:
  - the sandbox and grant code: `run_worker_*`, `lib/grants.py`, `worker/`, `make_guard_shims`,
    the egress code;
  - `lib/chain.py`;
  - `install.sh`;
  - `VERSION`, the changelog (no release, no version bump);
  - `claude/` and `opencode/`.
- No migration of existing worktrees, no `peek --repo`, and no new subcommands.
- No change to task ids, branch names, or anything `--here` does.

## Notes

- `GIT_COMMON` is computed in `cmd_run` as
  `$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd)`. That is the logical path,
  not `pwd -P`. `task_worktree_path` uses only basenames, so either is fine.
- The `meta.env` values are written with `printf %q`. Read them in tests the way
  `lib/taskstate.py` already does (it has a meta reader; use it, don't write a new one).
- The per-repo folder survives `rm` on purpose: a broker bind-mounts it into a container.
