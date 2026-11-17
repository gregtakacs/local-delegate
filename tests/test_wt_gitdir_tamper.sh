#!/usr/bin/env bash
# Default mode (no DELEGATE_UNTRUSTED_REPO): the worker can write its worktree's git dir
# ($WT_GITDIR, mounted into the container). A `commondir` there that points at a directory the
# worker built (the real objects and refs by symlink, plus its own config) would make the host's
# `wgit` load that config: here a textconv that runs on `delegate diff`. The payload only creates a
# marker file outside the repository. A control run of plain git proves the attack fires; then
# delegate must not run it, must restore `commondir`, and must move a worker-written
# `config.worktree` aside. No docker, no network.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ok()   { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
G=(git -c user.name=t -c user.email=t@example.invalid)

REPO=$T/repo; OUT=$T/outside; mkdir -p "$REPO" "$OUT" "$T/state" "$T/wt" "$T/home"
"${G[@]}" -C "$REPO" init -q -b main
echo one >"$REPO/f.txt"; "${G[@]}" -C "$REPO" add f.txt; "${G[@]}" -C "$REPO" commit -q -m base
BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
WT=$T/wt/repo/task; mkdir -p "$T/wt/repo"
git -C "$REPO" worktree add -q -b delegate/task "$WT" "$BASE_SHA"
WT_GITDIR=$(git -C "$WT" rev-parse --absolute-git-dir)
echo two >"$WT/f.txt"; "${G[@]}" -C "$WT" commit -q -am round

ID=repo-task; D=$T/state/$ID; mkdir -p "$D/rounds/1"
{ printf 'ID=%s\nSLUG=task\nREPO=%s\nWORKTREE=%s\nBRANCH=delegate/task\n' "$ID" "$REPO" "$WT"
  printf 'BASE_REF=main\nBASE_SHA=%s\nGIT_COMMON=%s\nMODEL=m\nVERIFY=true\n' "$BASE_SHA" "$REPO/.git"
  printf 'SERVICE=\nCOPIED=\nSESSION=\nCREATED=2026-01-01T00:00:00Z\nWT_GITDIR=%s\n' "$WT_GITDIR"
  printf 'READS=\nGITHUB=0\nEGRESS=filtered\nHERE=0\nRUNNER=docker\nRAW=0\n'
} >"$D/meta.env"
printf 'report\n' >"$D/rounds/1/report.md"; : >"$D/$ID.log"

# What a worker can build from inside its container: a stand-in common dir in its own worktree.
EVIL=$WT/.evil; mkdir -p "$EVIL/info"
ln -s "$REPO/.git/objects" "$EVIL/objects"; ln -s "$REPO/.git/refs" "$EVIL/refs"
printf '#!/bin/sh\ntouch %q\ncat "$1"\n' "$OUT/textconv" >"$EVIL/payload.sh"; chmod +x "$EVIL/payload.sh"
printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n[diff "evil"]\n\ttextconv = %s\n' \
  "$EVIL/payload.sh" >"$EVIL/config"
echo '* diff=evil' >"$EVIL/info/attributes"
orig_commondir=$(cat "$WT_GITDIR/commondir")
tamper() { printf '%s\n' "$EVIL" >"$WT_GITDIR/commondir"; }

# Control: the same git call wgit made before the fix (no GIT_COMMON_DIR) runs the payload.
tamper; rm -f "$OUT/textconv"
git --git-dir="$WT_GITDIR" --work-tree="$WT" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
  --no-pager diff "$BASE_SHA" HEAD >/dev/null 2>&1
[ -e "$OUT/textconv" ] && ok "control: a tampered commondir runs the worker's textconv on the host" \
  || fail "control: the payload did not fire, so this test proves nothing"
rm -f "$OUT/textconv"

dl() { HOME=$T/home DELEGATE_CONFIG=$T/none DELEGATE_STATE=$T/state DELEGATE_WORKTREES=$T/wt \
         DELEGATE_PRUNE_DAYS=0 "$here/bin/delegate" "$@"; }
tamper
out=$(dl diff "$ID" --full 2>&1); rc=$?
[ "$rc" = 0 ] && ok "delegate diff still works on the tampered task (exit 0)" || fail "delegate diff exit $rc: ${out:0:300}"
[ ! -e "$OUT/textconv" ] && ok "delegate diff did not run the worker's textconv" || fail "delegate diff ran the worker's textconv on the host"
printf '%s' "$out" | grep -q 'SECURITY: .*commondir was modified by the worker' \
  && ok "the tampering is reported as SECURITY" || fail "no SECURITY line for the commondir: ${out:0:300}"
[ "$(cat "$WT_GITDIR/commondir")" = "$orig_commondir" ] && ok "commondir restored to $orig_commondir" \
  || fail "commondir not restored: $(cat "$WT_GITDIR/commondir")"
printf '%s' "$out" | grep -q '^+two' && ok "the diff shows the round's real change" || fail "diff output lacks the change"

# Even if the check were skipped, wgit pins the common dir: tamper and call a git that pins it.
tamper; rm -f "$OUT/textconv"
GIT_COMMON_DIR="$REPO/.git" git --git-dir="$WT_GITDIR" --work-tree="$WT" --no-pager diff "$BASE_SHA" HEAD >/dev/null 2>&1
[ ! -e "$OUT/textconv" ] && ok "GIT_COMMON_DIR alone outranks a tampered commondir" || fail "GIT_COMMON_DIR did not outrank commondir"
printf '%s\n' "$orig_commondir" >"$WT_GITDIR/commondir"

# A worker-written config.worktree is moved aside, and an untampered task says nothing.
printf '[core]\n\tfsmonitor = %s\n' "$EVIL/payload.sh" >"$WT_GITDIR/config.worktree"
out=$(dl diff "$ID" 2>&1)
[ ! -e "$WT_GITDIR/config.worktree" ] && ls "$WT_GITDIR"/config.worktree.delegate-quarantined.* >/dev/null 2>&1 \
  && ok "config.worktree moved aside" || fail "config.worktree left in place"
printf '%s' "$out" | grep -q 'SECURITY: the worker wrote .*config.worktree' && ok "and reported as SECURITY" || fail "no SECURITY line for config.worktree"
out=$(dl diff "$ID" 2>&1)
printf '%s' "$out" | grep -q SECURITY && fail "an untampered task reported SECURITY: ${out:0:200}" || ok "an untampered task reports nothing"

[ "$fails" = 0 ] && { echo "PASS worktree git-dir tampering (default mode)"; exit 0; }
echo "FAIL worktree git-dir tampering: $fails"; exit 1
