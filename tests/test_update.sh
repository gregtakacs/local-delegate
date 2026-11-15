#!/bin/bash
# delegate update: a release install moves by flipping `current`, through the same fetch/verify
# block install.sh --release uses (lib/release-fetch.sh). The scene is set with that installer.
# Covered: the flip and every link resolving under current; the previous version dir kept with its
# stamp; --to on an existing stamped dir fetching nothing (the tag moves under it and nothing
# lands); --repo / --from beating the recorded source; a missing tag refusing with current unmoved;
# a dev checkout refusing; --version and doctor printing the installed line; a failing doctor
# leaving the flip stood. No network, no docker, and no inheritance from the environment the test
# runs in: everything below runs under `env -i` with one fixed env, whose endpoint is a refused
# loopback port — so the doctor update ends with fails fast, for a reason this test controls.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# the tree a release installs, exactly as test_release_install.sh builds it, plus the lib update
# sources: update runs the fetch code of the tree that is RUNNING, so it must be in the tagged tree
SRC=$T/src
mkdir -p "$SRC/bin" "$SRC/lib" "$SRC/claude/skills" "$SRC/claude/agents" "$SRC/commands/opencode"
cp "$here/install.sh" "$SRC/"
cp "$here/bin/delegate" "$here/bin/delegate-wake" "$SRC/bin/"
cp "$here/lib/merge-opencode-permissions.py" "$here/lib/release-fetch.sh" "$SRC/lib/"
cp "$here/config.example.env" "$SRC/"
cp -R "$here/claude/skills/delegate" "$SRC/claude/skills/"
cp "$here/claude/agents/delegate-lead.md" "$SRC/claude/agents/"
cp "$here/commands/opencode/delegate.md" "$SRC/commands/opencode/"
printf '0.1.0\n' > "$SRC/VERSION"
git init -q -b main "$SRC" && git -C "$SRC" add -A && git -C "$SRC" commit -qm v0.1.0 && git -C "$SRC" tag v0.1.0
printf '0.1.1\n' > "$SRC/VERSION"; echo '+ one commit' > "$SRC/CHANGES"
git -C "$SRC" add -A && git -C "$SRC" commit -qm v0.1.1 && git -C "$SRC" tag v0.1.1
printf '0.1.2\n' > "$SRC/VERSION"
git -C "$SRC" add -A && git -C "$SRC" commit -qm v0.1.2 && git -C "$SRC" tag v0.1.2
printf '0.1.1\n' > "$SRC/VERSION"   # HEAD back at v0.1.1's content; tags, not HEAD, name installs
git -C "$SRC" add -A && git -C "$SRC" commit -qm back

# a second, unrelated repo: proof of which URL a fetch actually used
ALT=$T/alt; git clone -q "$SRC" "$ALT" 2>/dev/null
printf '0.3.0\n' > "$ALT/VERSION"; echo 'from the alt repo' > "$ALT/ALT-FETCHED"
git -C "$ALT" add -A && git -C "$ALT" commit -qm v0.3.0 && git -C "$ALT" tag v0.3.0

H=$T/h; XD=$T/xd; root=$XD/delegate
# a config the installer will not overwrite, and no DELEGATE_* from outside reaching the run
mkdir -p "$H/cfg/delegate"
printf 'DELEGATE_BASE_URLS="http://127.0.0.1:1/v1"\nDELEGATE_MODEL="unused"\nDELEGATE_API_KEY_FILE="/dev/null"\n' > "$H/cfg/delegate/config.env"
run_env() { # run_env PROG [args...] — one fixed environment for every install, update and doctor
  env -i PATH="$PATH" HOME="$H" XDG_CONFIG_HOME="$H/cfg" XDG_DATA_HOME="$XD" \
    DELEGATE_BIN_DIR="$H/bin" CLAUDE_SKILLS_DIR="$H/skills" CLAUDE_AGENTS_DIR="$H/agents" \
    OPENCODE_COMMANDS_DIR="$H/cfg/opencode/commands" DELEGATE_PROBE_TIMEOUT=1 "$@"
}
rc=0; out=""; docout=""; ver=""
inst() { # inst [installer args...] — the d1 installer, the only way the scene gets set
  out=$(run_env "$here/install.sh" "$@" 2>&1); rc=$?
}
upd() { # upd [update args...] — run delegate the way its users do: through the installed link
  out=$(run_env "$H/bin/delegate" update "$@" 2>&1); rc=$?
}

inst --release v0.1.0 --from "$SRC" --no-build
check "scene: the d1 installer left v0.1.0 current" \
  "[ \$rc -eq 0 ] && [ \$(readlink '$root/current') = ./v0.1.0 ] && [ -x '$root/v0.1.0/bin/delegate' ]"
touch "$root/v0.1.0/marker"
LINKS=( "$H/bin/delegate" "$H/bin/delegate-wake" "$H/skills/delegate" "$H/agents/delegate-lead.md" )
if command -v opencode >/dev/null; then LINKS+=( "$H/cfg/opencode/commands/delegate.md" ); fi
L="${LINKS[*]}"   # temp paths carry no spaces
if command -v opencode >/dev/null; then
  check "before the update, the opencode config names no v0.1.1" \
    "! grep -q 'v0[.]1[.]1' '$H/cfg/opencode/opencode.json'"
fi

# ---- the flip -----------------------------------------------------------------------------
upd --to v0.1.1
check "update printed the updated line, naming the tag and the kept dir" \
  "printf %s \"\$out\" | grep -qE '^updated: v0[.]1[.]0 -> v0[.]1[.]1 \\(previous kept at $root/v0[.]1[.]0\\)\$'"
check "current flipped to ./v0.1.1" "[ \$(readlink '$root/current') = ./v0.1.1 ]"
check "the tree current names is the one the tag carried, stamped and recorded" \
  "[ \$(cat '$root/v0.1.1/VERSION') = 0.1.1 ] && grep -qx 'tag=v0.1.1' '$root/v0.1.1/.delegate-source' \
   && grep -qx 'repo=file://$SRC' '$root/v0.1.1/.delegate-source'"
check "every link install.sh made still points through current, never a tag dir" \
  "! readlink $L | grep -q 'v0[.]'"
check "every link's target is under current/, and resolves into the new version dir" \
  "( for p in $L; do case \$(readlink \"\$p\") in '$root'/current/*) ;; *) exit 1 ;; esac; \
   case \$(readlink -f \"\$p\") in '$root'/v0.1.1/*) ;; *) exit 1 ;; esac; done )"
check "the delegate link resolves through current to the new tree" \
  "[ \$(readlink -f '$H/bin/delegate') = '$root/v0.1.1/bin/delegate' ]"
check "the version it came from survived, stamp and marker intact" \
  "[ -d '$root/v0.1.0' ] && [ \$(cat '$root/v0.1.0/.delegate-version') = v0.1.0 ] && [ -f '$root/v0.1.0/marker' ]"
check "doctor ran after the flip, on the tree current now names" \
  "printf %s \"\$out\" | grep -qE '^install: release v0[.]1[.]1 \\(current -> $root/v0[.]1[.]1\\)\$'"
check "the failing doctor did not roll the flip back, and named the way out" \
  "[ \$(readlink '$root/current') = ./v0.1.1 ] && printf %s \"\$out\" | grep -q 'delegate update --to v0[.]1[.]0'"
if command -v opencode >/dev/null; then
  check "the merge re-ran with the new tree's own script, against the new tree's rules" \
    "grep -q \"$root/v0[.]1[.]1/claude/skills/delegate\" '$H/cfg/opencode/opencode.json'"
fi
check "update deleted nothing: both version dirs are still there" \
  "[ -d '$root/v0.1.0' ] && [ -d '$root/v0.1.1' ]"

# ---- bare update = repair the recorded tag; --to on a stamped dir fetches nothing ----------
upd
check "bare update takes --to from the record (same tag, fetch skipped)" \
  "printf %s \"\$out\" | grep -qE '^updated: v0[.]1[.]1 -> v0[.]1[.]1 ' && printf %s \"\$out\" | grep -q 'fetch skipped'"

# move the tag under the install: only a fetch would notice, and there must be no fetch
echo 'a later commit' > "$SRC/LATE"
git -C "$SRC" add -A && git -C "$SRC" commit -qm later && git -C "$SRC" tag -f v0.1.1 >/dev/null 2>&1
touch "$root/v0.1.1/marker2"
upd --to v0.1.1
check "--to an existing stamped dir fetched nothing: the moved tag did not land" \
  "[ -f '$root/v0.1.1/marker2' ] && [ ! -e '$root/v0.1.1/LATE' ] && printf %s \"\$out\" | grep -q 'fetch skipped'"
check "and current did not move while all that was decided" \
  "[ \$(readlink '$root/current') = ./v0.1.1 ]"

# ---- a fetch that cannot be done leaves the install exactly as it was ----------------------
mkdir -p "$root/v3.0.0.tmp" && echo junk > "$root/v3.0.0.tmp/junk"   # a dest left half-built by an interrupted run
upd --to v3.0.0
check "a tag the source has not got is refused, exit 1" \
  "[ \$rc -eq 1 ] && printf %s \"\$out\" | grep -qi refusing"
check "refused fetch moved current not at all" "[ \$(readlink '$root/current') = ./v0.1.1 ]"
check "refused fetch left no dest, and cleared the half-built one" \
  "[ ! -e '$root/v3.0.0' ] && [ ! -e '$root/v3.0.0.tmp' ]"
check "current is no way dangling after the failure" \
  "[ -e '$root/current' ] && [ \$(readlink -f '$root/current') = '$root/v0.1.1' ]"

# ---- the recorded source, and the flags that beat it ---------------------------------------
: > "$T/dangle.log"
( while :; do [ -e "$root/current" ] || date +%s%N >> "$T/dangle.log"; sleep 0.02; done ) & poll=$!
run_env "$H/bin/delegate" update --to v0.3.0 --repo "file://$ALT" > "$T/flip.out" 2>&1; rc=$?
kill "$poll" 2>/dev/null; wait "$poll" 2>/dev/null
check "--repo overrode the record: the alt repo's tree installed, exit code is the doctor's" \
  "[ \$rc -ne 0 ] && [ \$(readlink '$root/current') = ./v0.3.0 ] && [ -f '$root/v0.3.0/ALT-FETCHED' ] \
   && grep -qx 'repo=file://$ALT' '$root/v0.3.0/.delegate-source' && grep -q '^updated: ' '$T/flip.out'"
check "current was never dangling while the flip ran (mv -T of a symlink is atomic)" \
  "[ ! -s '$T/dangle.log' ]"
upd --to v0.1.2 --repo "file://$T/nope" --from "$SRC"
check "--from wins over --repo, as it does in install.sh" \
  "[ \$(readlink '$root/current') = ./v0.1.2 ] && [ -f '$root/v0.1.2/VERSION' ] \
   && grep -qx 'repo=file://$SRC' '$root/v0.1.2/.delegate-source'"
upd --to v0.1.1 --repo "file://$SRC"
check "rollback is the same command the other way: a lower tag installs with no comparison" \
  "[ \$(readlink '$root/current') = ./v0.1.1 ] && printf %s \"\$out\" | grep -qE '^updated: v0[.]1[.]2 -> v0[.]1[.]1 '"
check "update deleted no version directory, ever: no GC in this slice" \
  "[ -d '$root/v0.1.0' ] && [ -d '$root/v0.1.1' ] && [ -d '$root/v0.1.2' ] && [ -d '$root/v0.3.0' ]"

# ---- who may run it, and what it needs to know ---------------------------------------------
out=$(env -i PATH="$PATH" HOME="$H" XDG_CONFIG_HOME="$H/cfg" XDG_DATA_HOME="$XD" \
  "$here/bin/delegate" update --to v0.3.0 2>&1); rc=$?
check "a dev checkout refuses: exit 1, the message, and current untouched" \
  "[ \$rc -eq 1 ] && printf %s \"\$out\" | grep -q 'dev checkout: update installs nothing' \
   && printf %s \"\$out\" | grep -q 'run install.sh from the checkout you develop' \
   && [ \$(readlink '$root/current') = ./v0.1.1 ]"
upd --to
check "a flag with no value is refused, not a surprise unset" \
  "[ \$rc -eq 1 ] && printf %s \"\$out\" | grep -q 'needs a value'"
upd --bogus
check "an unknown flag is refused with the usage line" \
  "[ \$rc -eq 1 ] && printf %s \"\$out\" | grep -qF 'delegate update [--to TAG]'"
upd --help
check "update --help lists all three flags" \
  "[ \$rc -eq 0 ] && printf %s \"\$out\" | grep -qF '[--to TAG] [--repo URL] [--from DIR]'"
check "update --help says how to roll back, and that nothing is pruned" \
  "printf %s \"\$out\" | grep -q 'delegate update --to <the previous tag>' \
   && printf %s \"\$out\" | grep -qiE 'never deletes any version directory'"
check "update --help names minisign --verify as the later slice it is" \
  "printf %s \"\$out\" | grep -qi minisign"

cp "$root/v0.1.1/.delegate-source" "$T/source.bak"
printf 'tag=\nrepo=\n' > "$root/v0.1.1/.delegate-source"
upd
check "no tag recorded, none given: refused with current unmoved" \
  "[ \$rc -eq 1 ] && printf %s \"\$out\" | grep -q 'records no tag' && [ \$(readlink '$root/current') = ./v0.1.1 ]"
printf 'tag=v0.1.1\n' > "$root/v0.1.1/.delegate-source"
upd --to v0.3.0
check "no repo recorded and no --repo/--from: refused before any clone" \
  "[ \$rc -eq 1 ] && printf %s \"\$out\" | grep -q 'records no repo' && [ \$(readlink '$root/current') = ./v0.1.1 ]"
cp "$T/source.bak" "$root/v0.1.1/.delegate-source"

# a hand-deleted version dir: the installed link is broken, so this is run from any other tree
ln -sfn ./gone "$root/current"
out=$(env -i PATH="$PATH" HOME="$H" XDG_CONFIG_HOME="$H/cfg" XDG_DATA_HOME="$XD" \
  "$here/bin/delegate" update --to v0.1.2 2>&1); rc=$?
check "a dangling current is named as such, not reported as a dev checkout" \
  "[ \$rc -eq 1 ] && printf %s \"\$out\" | grep -q 'is dangling' && printf %s \"\$out\" | grep -q './gone'"
ln -sfn ./v0.1.1 "$root/current"
check "and update left the dangling link alone until told what to do with it" \
  "[ \$(readlink '$root/current') = ./v0.1.1 ]"

# ---- what the install now reports ----------------------------------------------------------
ver=$(run_env "$H/bin/delegate" --version 2>&1)
check "--version's second line is the installed line, regex exact" \
  "printf %s \"\$ver\" | grep -qE '^install: release v0[.]1[.]1 \\(current -> $root/v0[.]1[.]1\\)\$'"
vout=$(run_env "$H/bin/delegate" --version 2>/dev/null); vrc=$?
check "--version exits 0 with the version token alone on stdout" \
  "[ \$vrc -eq 0 ] && [ \"\$vout\" = 0.1.0 ]"
docout=$(run_env "$H/bin/delegate" doctor --quick 2>&1 || true)
iline=$(printf %s "$docout" | grep -m1 '^install: ')
vline=$(printf %s "$ver" | grep -m1 '^install: ')
check "--version repeats doctor's install line verbatim" "[ \"\$vline\" = \"\$iline\" ] && [ -n \"\$iline\" ]"
devline=$(env -i PATH="$PATH" HOME="$H" XDG_CONFIG_HOME="$H/cfg" XDG_DATA_HOME="$XD" \
  "$here/bin/delegate" --version 2>&1 | tail -n1)
check "--version on a dev checkout says so, in the same words doctor uses" \
  "[ \"\$devline\" = 'install: dev checkout ($here)' ]"

check "no .tmp litter anywhere under the temp dir" \
  "! find '$T' -name '*.tmp' -not -path '*/.git/*' | grep -q ."
check "root kept its 0700 and current is still a symlink" \
  "[ \$(stat -c %a '$root') = 700 ] && [ -L '$root/current' ]"

[ $fail -eq 0 ] && echo "PASS tests/test_update.sh"
exit $fail
