#!/usr/bin/env bash
# SG hostile suite (DOCKER=1): a repository whose own bytes try to make host-side git run a
# program or act on another repository. Each attack is run twice through `delegate _repo-git`:
# with DELEGATE_UNTRUSTED_REPO=0 as the control (the payload must really fire on the host, or the
# test proves nothing), and with DELEGATE_UNTRUSTED_REPO=1, where the payload may run only inside
# the throwaway sandbox and must leave no trace outside the repository.
#
# The payloads are harmless: each one only creates a marker file in a directory outside the
# repository ($OUT), which is never mounted into the sandbox.
#
#   DOCKER=1 tests/test_untrusted_hostile.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "${DOCKER:-0}" != 1 ]; then echo "skip  untrusted-repo hostile suite (DOCKER=1 to run it)"; exit 0; fi
docker image inspect "${DELEGATE_IMAGE:-delegate-worker:local}" >/dev/null 2>&1 || {
  echo "skip  untrusted-repo hostile suite (no ${DELEGATE_IMAGE:-delegate-worker:local} image)"; exit 0; }

T="$(mktemp -d)"; trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
OUT=$T/outside; mkdir -p "$OUT"
export DELEGATE_STATE=$T/state DELEGATE_WORKTREES=$T/wt
mkdir -p "$DELEGATE_STATE" "$DELEGATE_WORKTREES"
fails=0
ok()   { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
rg()   { local mode=$1 repo=$2; shift 2
         DELEGATE_UNTRUSTED_REPO=$mode "$here/bin/delegate" _repo-git "$repo" -- "$@" >"$T/last.out" 2>&1; }

new_repo() { # NAME -> a fresh main checkout with one commit, path on stdout
  local r=$T/$1; rm -rf "$r"; mkdir -p "$r"
  git -C "$r" init -q -b main
  git -C "$r" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  echo "$r"
}
marker_script() { # REPO NAME -> an executable inside the repo's .git that writes $OUT/NAME
  local s=$1/.git/payload-$2.sh
  printf '#!/bin/sh\ntouch %q 2>/dev/null\nexit 0\n' "$OUT/$2" >"$s"; chmod +x "$s"; echo "$s"
}
# attack NAME SETUP-FN TRIGGER-ARGS... : control (off) must fire, untrusted (on) must not.
attack() {
  local name=$1 setup=$2; shift 2
  local r; r=$(new_repo "$name-off"); "$setup" "$r" "$name"; rm -f "$OUT/$name"
  rg 0 "$r" "$@"
  if [ -e "$OUT/$name" ]; then ok "$name: control fires on the host with the setting off"
  else fail "$name: control did not fire, the payload proves nothing ($(tail -2 "$T/last.out"))"; fi
  rm -f "$OUT/$name"
  r=$(new_repo "$name-on"); "$setup" "$r" "$name"
  if rg 1 "$r" "$@"; then ok "$name: the git command itself ran in the sandbox (exit 0)"
  else fail "$name: the sandboxed git command failed, so the test proves nothing ($(tail -2 "$T/last.out"))"; fi
  if [ -e "$OUT/$name" ]; then fail "$name: ran on the host with DELEGATE_UNTRUSTED_REPO=1"
  else ok "$name: no trace outside the repository with DELEGATE_UNTRUSTED_REPO=1"; fi
  rm -f "$OUT/$name"
}

set_fsmonitor() { git -C "$1" config core.fsmonitor "$(marker_script "$1" "$2")"; }
set_hook()      { mkdir -p "$1/.git/hooks"; cp "$(marker_script "$1" "$2")" "$1/.git/hooks/post-checkout"; }
set_hookspath() { local d=$1/.git/myhooks; mkdir -p "$d"; cp "$(marker_script "$1" "$2")" "$d/post-checkout"
                  git -C "$1" config core.hooksPath "$d"; }
set_clean()     { local s; s=$(marker_script "$1" "$2"); git -C "$1" config filter.evil.clean "$s"
                  echo '* filter=evil' >"$1/.gitattributes"; echo data >"$1/f.txt"; }
set_textconv()  { local s; s=$(marker_script "$1" "$2"); echo one >"$1/f.txt"
                  git -C "$1" add f.txt; git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q -m f
                  git -C "$1" config diff.evil.textconv "$s"; echo 'f.txt diff=evil' >"$1/.gitattributes"
                  echo two >"$1/f.txt"; }

attack fsmonitor set_fsmonitor status --porcelain
attack post-checkout set_hook checkout -q -b side
attack hookspath set_hookspath checkout -q -b side
attack clean-filter set_clean add -A
attack textconv set_textconv --no-pager diff

# core.worktree pointing at another repository: with the setting off git really works on the
# victim; with it on, the victim is neither listed nor touched.
victim=$(new_repo victim); echo secret >"$victim/victim-file"; before=$(cd "$victim" && find . -path ./.git -prune -o -print | sort | md5sum)
r=$(new_repo worktree-off); git -C "$r" config core.worktree "$victim"
rg 0 "$r" status --porcelain
if grep -q victim-file "$T/last.out"; then ok "core.worktree: control works on the victim with the setting off"
else fail "core.worktree: control did not reach the victim ($(tail -2 "$T/last.out"))"; fi
r=$(new_repo worktree-on); git -C "$r" config core.worktree "$victim"
rg 1 "$r" add -A
rg 1 "$r" status --porcelain
if grep -q victim-file "$T/last.out"; then fail "core.worktree: untrusted mode listed the victim's files"
else ok "core.worktree: the victim is not visible with DELEGATE_UNTRUSTED_REPO=1"; fi
after=$(cd "$victim" && find . -path ./.git -prune -o -print | sort | md5sum)
[ "$before" = "$after" ] && [ -z "$(git -C "$victim" status --porcelain 2>/dev/null | grep -v '^?? victim-file$')" ] \
  && ok "core.worktree: the victim repository is unchanged" || fail "core.worktree: the victim changed"

# A gitfile or a commondir that borrows the victim's administration: refused before any git runs.
r=$(new_repo gitfile); rm -rf "$r/.git"; echo "gitdir: $victim/.git" >"$r/.git"
if rg 1 "$r" status; then fail "gitfile: accepted"; else ok "gitfile: refused ($(grep -o 'is not the top of a main checkout' "$T/last.out" | head -1))"; fi
r=$(new_repo commondir); echo "$victim/.git" >"$r/.git/commondir"
if rg 1 "$r" status; then fail "commondir: accepted"; else ok "commondir: refused"; fi

# A .git that is a symlink to the victim's: refused.
r=$(new_repo dotgit-link); rm -rf "$r/.git"; ln -s "$victim/.git" "$r/.git"
if rg 1 "$r" status; then fail ".git symlink: accepted"; else ok ".git symlink: refused"; fi

# The sandbox leaves no container behind.
left=$(docker ps -a --filter label=delegate.sandbox=1 --format '{{.Names}}' | grep -c "delegate-sbx-" || true)
[ "$left" = 0 ] && ok "no sandbox container left behind" || fail "$left sandbox container(s) left behind"

[ "$fails" = 0 ] && { echo "PASS untrusted-repo hostile suite"; exit 0; }
echo "FAIL untrusted-repo hostile suite: $fails"; exit 1
