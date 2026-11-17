#!/bin/bash
# sandbox-git.sh — runs INSIDE a short-lived container, never on the host (DELEGATE_UNTRUSTED_REPO=1).
#
# The host side (bin/delegate `sbx`, `sbx_worker_args`) starts it as the container's entrypoint,
# with no network, no capabilities, a read-only root, the host user's uid, and bind mounts of only
# the repository and its per-repo worktrees folder (or, in front of a worker, the worker's own
# mounts). Whatever the repository's config, hooks, attributes or symlinks make git do in here,
# they can only reach those mounts: no secret, no Docker socket and no other repo is in the
# container. Arguments come from bin/delegate, never from the repository.
#
# First, always: every mount named in DELEGATE_SBX_EXPECT ("PATH<TAB>DEV:INO" lines, from
# lib/safepath.py on the host) must be the directory the host opened, compared by device and
# inode. A path swapped for a symlink after the host's check gets a different directory mounted,
# and the op stops here before anything reads or writes it.
#
#   probe        REPO BRANCH [BASE]                    key<TAB>value lines (see op_probe)
#   add          REPO WORKTREE BRANCH BASE_SHA [COPY...]   worktree add + --copy; prints "gitdir<TAB>P"
#   gitlink      WT_GITDIR WORKTREE                    "ok", or "restored<TAB>WHAT-WAS-THERE"
#   commit-round WT_GITDIR WORKTREE COMMON MSG1 MSG2 [COPIED...]   prints the HEAD commit
#   repo-git     REPO -- GIT-ARGS...                   git on the main checkout
#   wt-git       WT_GITDIR WORKTREE COMMON -- GIT-ARGS...   git on a task worktree, gitdir pinned
#   exec-next    CMD...                                in front of a worker: check, then exec the
#                                                      image's own entrypoint (DELEGATE_SBX_NEXT)
# Exit 3: SECURITY refusal. Exit 4: bad use or a failed --copy. Otherwise git's own status.
set -euo pipefail

die()  { echo "delegate sandbox: $*" >&2; exit 4; }
sec()  { echo "delegate sandbox: SECURITY: $*" >&2; exit 3; }

# The same hardening the host's wgit uses for a worker-written worktree, for every git call in
# here: no hooks, no fsmonitor daemon, no external diff, no signing (no keys in here), and any
# owner accepted (the uid is the host user's; a userns remap would otherwise refuse everything).
G=(git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c diff.external=
   -c commit.gpgSign=false -c tag.gpgSign=false -c safe.directory='*')

verify_mounts() {
  local line p want have n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    p=${line%%$'\t'*}; want=${line#*$'\t'}
    have=$(stat -c '%d:%i' -- "$p" 2>/dev/null) || sec "$p is not mounted"
    [ "$have" = "$want" ] || sec "$p is not the directory the host checked (got $have, want $want): a path was swapped"
    n=$((n + 1))
  done <<< "${DELEGATE_SBX_EXPECT:-}"
  [ "$n" -gt 0 ] || sec "no mount to check (DELEGATE_SBX_EXPECT is empty)"
  unset DELEGATE_SBX_EXPECT
}

# A path the op works on must be itself, not a symlink at any component — inside the container,
# where a symlink can only reach the mounts anyway; this keeps one task's op off another's tree.
plain() { # PATH WHAT
  local r; r=$(realpath -e -- "$1" 2>/dev/null) || sec "$2 $1 does not exist"
  [ "$r" = "$1" ] || sec "$2 $1 is (or runs through) a symlink, to $r"
  [ -d "$1" ] || sec "$2 $1 is not a directory"
}

main_checkout() { # REPO — a main checkout: REPO/.git a real directory, not a linked worktree's
  plain "$1" repository
  [ -d "$1/.git" ] && [ ! -L "$1/.git" ] || sec "$1/.git is not a directory (a gitfile, a symlink, or missing)"
  [ ! -e "$1/.git/commondir" ] || sec "$1/.git has a commondir file (it borrows another repository)"
}

rgit() { local repo=$1; shift; ( cd "$repo" && "${G[@]}" --git-dir="$repo/.git" --work-tree="$repo" "$@" ); }
# A task worktree: its gitdir pinned (the worker can rewrite the `.git` pointer file) and its
# common dir pinned too (GIT_COMMON_DIR outranks the worker-writable `commondir` file).
tgit() { local gd=$1 wt=$2 common=$3; shift 3
         ( cd "$wt" && GIT_COMMON_DIR=$common "${G[@]}" --git-dir="$gd" --work-tree="$wt" "$@" ); }

op_probe() { # REPO BRANCH [BASE] -> branch_exists, head, base_ref, base_sha, dirty
  local repo=$1 branch=$2 base=${3:-} head sha dirty=0 exists=0
  main_checkout "$repo"
  rgit "$repo" show-ref --verify --quiet "refs/heads/$branch" && exists=1
  head=$(rgit "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  [ -n "$base" ] || base=$head
  sha=$(rgit "$repo" rev-parse --verify --quiet "$base^{commit}" 2>/dev/null || true)
  [ -z "$(rgit "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ] || dirty=1
  printf 'branch_exists\t%s\nhead\t%s\nbase_ref\t%s\nbase_sha\t%s\ndirty\t%s\n' \
    "$exists" "$head" "$base" "$sha" "$dirty"
}

op_add() { # REPO WORKTREE BRANCH BASE_SHA [COPY...]
  local repo=$1 wt=$2 branch=$3 sha=$4 c gd; shift 4
  main_checkout "$repo"
  plain "$(dirname "$wt")" "worktree folder"
  [ ! -e "$wt" ] && [ ! -L "$wt" ] || sec "worktree path already exists: $wt"
  rgit "$repo" worktree add -q -b "$branch" "$wt" "$sha"
  gd=$("${G[@]}" -C "$wt" rev-parse --absolute-git-dir)
  printf 'gitdir\t%s\n' "$gd"
  for c in "$@"; do
    [ -e "$repo/$c" ] || die "--copy: $repo/$c does not exist"
    mkdir -p "$(dirname "$wt/$c")"
    cp -a "$repo/$c" "$wt/$c"
  done
}

op_gitlink() { # WT_GITDIR WORKTREE
  local gd=$1 wt=$2 want have
  plain "$wt" worktree
  want="gitdir: $gd"
  have=$(head -c 4096 "$wt/.git" 2>/dev/null || true)
  if [ -L "$wt/.git" ] || [ "$have" != "$want" ]; then
    rm -rf "$wt/.git"; printf '%s\n' "$want" > "$wt/.git"
    printf 'restored\t%s\n' "$(printf '%s' "${have:0:120}" | tr '\n\t' '  ')"
  else
    echo ok
  fi
}

op_commit_round() { # WT_GITDIR WORKTREE COMMON MSG1 MSG2 [COPIED...]
  local gd=$1 wt=$2 common=$3 m1=$4 m2=$5 c; shift 5
  plain "$wt" worktree; plain "$gd" "worktree git dir"
  tgit "$gd" "$wt" "$common" add -A
  for c in "$@"; do tgit "$gd" "$wt" "$common" reset -q -- "$c" 2>/dev/null || true; done
  if ! tgit "$gd" "$wt" "$common" diff --cached --quiet; then
    tgit "$gd" "$wt" "$common" commit -q --no-verify -m "$m1" -m "$m2"
  fi
  tgit "$gd" "$wt" "$common" rev-parse HEAD
}

op_exec_next() {
  local next=() l
  while IFS= read -r l; do [ -n "$l" ] && next+=("$l"); done <<< "${DELEGATE_SBX_NEXT:-}"
  unset DELEGATE_SBX_NEXT
  exec "${next[@]}" "$@"
}

verify_mounts
op=${1:-}; shift || true
case "$op" in
  probe)        [ $# -ge 2 ] || die "usage: probe REPO BRANCH [BASE]"; op_probe "$@" ;;
  add)          [ $# -ge 4 ] || die "usage: add REPO WORKTREE BRANCH BASE_SHA [COPY...]"; op_add "$@" ;;
  gitlink)      [ $# -eq 2 ] || die "usage: gitlink WT_GITDIR WORKTREE"; op_gitlink "$@" ;;
  commit-round) [ $# -ge 5 ] || die "usage: commit-round WT_GITDIR WORKTREE COMMON MSG1 MSG2 [COPIED...]"; op_commit_round "$@" ;;
  repo-git)     [ $# -ge 2 ] && [ "$2" = -- ] || die "usage: repo-git REPO -- ARGS"
                repo=$1; shift 2; main_checkout "$repo"; rgit "$repo" "$@" ;;
  wt-git)       [ $# -ge 4 ] && [ "$4" = -- ] || die "usage: wt-git WT_GITDIR WORKTREE COMMON -- ARGS"
                gd=$1 wt=$2 common=$3; shift 4; plain "$wt" worktree; plain "$gd" "worktree git dir"
                tgit "$gd" "$wt" "$common" "$@" ;;
  exec-next)    op_exec_next "$@" ;;
  *) die "unknown op '$op'" ;;
esac
