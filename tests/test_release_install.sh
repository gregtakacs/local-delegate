#!/bin/bash
# install.sh --release: pinned trees under $XDG_DATA_HOME/delegate, the `current` flip, and
# links that resolve through current — never a tag dir. Refusals: an existing dest whose stamp
# disagrees, a missing tag, a VERSION that disagrees with the tag, a `current` that is a real
# dir. --uninstall/--purge and both doctor install lines. The fetch source is a local file://
# fixture repo built here: no network, no docker.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# the tree a release installs: everything the installer links or copies
SRC=$T/src
mkdir -p "$SRC/bin" "$SRC/lib" "$SRC/claude/skills" "$SRC/claude/agents" "$SRC/commands/opencode"
cp "$here/install.sh" "$SRC/"
cp "$here/bin/delegate" "$here/bin/delegate-wake" "$SRC/bin/"
cp "$here/lib/merge-opencode-permissions.py" "$SRC/lib/"
cp "$here/config.example.env" "$SRC/"
cp -R "$here/claude/skills/delegate" "$SRC/claude/skills/"
cp "$here/claude/agents/delegate-lead.md" "$SRC/claude/agents/"
cp "$here/commands/opencode/delegate.md" "$SRC/commands/opencode/"
printf '0.1.0\n' > "$SRC/VERSION"
git init -q -b main "$SRC" && git -C "$SRC" add -A && git -C "$SRC" commit -qm v0.1.0 && git -C "$SRC" tag v0.1.0
printf '0.1.1\n' > "$SRC/VERSION"; echo '+ one commit' > "$SRC/CHANGES"
git -C "$SRC" add -A && git -C "$SRC" commit -qm v0.1.1 && git -C "$SRC" tag v0.1.1
git -C "$SRC" tag 0.1.1 v0.1.1   # two tags, one commit: legal, the tag only names the directory
echo dirty >> "$SRC/bin/delegate"   # a dirty working copy must never be what installs
# a fixture whose tagged commit carries the wrong VERSION
BAD=$T/bad; mkdir -p "$BAD"; printf '0.1.0\n' > "$BAD/VERSION"
git init -q -b main "$BAD" && git -C "$BAD" add -A && git -C "$BAD" commit -qm x && git -C "$BAD" tag v0.2.0

rc=0; out=""; docout=""
inst() { # inst HOMEDIR DATADIR [installer args...] — DATADIR NONE omits XDG_DATA_HOME
  local h=$1 d=$2; shift 2
  local xd=(); [ "$d" = NONE ] || xd=(XDG_DATA_HOME="$d")
  out=$(env HOME="$h" XDG_CONFIG_HOME="$h/cfg" DELEGATE_BIN_DIR="$h/bin" CLAUDE_SKILLS_DIR="$h/skills" \
    CLAUDE_AGENTS_DIR="$h/agents" OPENCODE_COMMANDS_DIR="$h/cfg/opencode/commands" "${xd[@]}" \
    "$here/install.sh" "$@" 2>&1); rc=$?
}
doctor_of() { # doctor_of HOMEDIR DATADIR — run the installed delegate doctor, keep whatever it printed
  local h=$1 d=$2 xd=(); [ "$d" = NONE ] || xd=(XDG_DATA_HOME="$d")
  docout=$(env HOME="$h" XDG_CONFIG_HOME="$h/cfg" "${xd[@]}" "$h/bin/delegate" doctor --quick 2>&1 || true)
}

H=$T/h1 XD=$T/xd1; root=$XD/delegate
inst "$H" "$XD" --release v0.1.0 --from "$SRC" --no-build
check "first --release install exits 0" '[ $rc -eq 0 ]'
check "version dir landed" "[ -x '$root/v0.1.0/bin/delegate' ] && [ -f '$root/v0.1.0/install.sh' ]"
check "installed VERSION file" "[ \$(cat '$root/v0.1.0/VERSION') = 0.1.0 ]"
check "stamp says the tag" "[ \$(cat '$root/v0.1.0/.delegate-version') = v0.1.0 ]"
check "source record says repo and tag" \
  "grep -qx 'repo=file://$SRC' '$root/v0.1.0/.delegate-source' && grep -qx 'tag=v0.1.0' '$root/v0.1.0/.delegate-source'"
check "root created 0700" "[ \$(stat -c %a '$root') = 700 ]"
check "current flipped to ./v0.1.0" "[ \$(readlink '$root/current') = ./v0.1.0 ]"
check "every link targets a current path, never a tag dir" \
  "! readlink '$H/bin/delegate' '$H/bin/delegate-wake' '$H/skills/delegate' '$H/agents/delegate-lead.md' '$H/cfg/opencode/commands/delegate.md' | grep -q 'v0[.]'"
check "delegate link resolves under current" \
  "[ \$(readlink '$H/bin/delegate') = '$root/current/bin/delegate' ] && [ \$(readlink -f '$H/bin/delegate') = '$root/v0.1.0/bin/delegate' ]"
check "config copied from the release tree" "grep -q DELEGATE_RUNNER '$H/cfg/delegate/config.env'"
if command -v opencode >/dev/null; then   # merge writes config content; skip if this box has no opencode
  check "opencode config merged against the installed tree" \
    "grep -q 'claude/skills/delegate' '$H/cfg/opencode/opencode.json'"
fi

# idempotent re-run: fetch skipped, nothing rewritten, modes kept
touch "$root/v0.1.0/marker"
modes1=$(stat -c '%a %n' "$root/v0.1.0/bin/delegate" "$root/v0.1.0/VERSION" "$root/v0.1.0/install.sh")
inst "$H" "$XD" --release v0.1.0 --from "$SRC" --no-build
check "re-run exits 0" '[ $rc -eq 0 ]'
check "re-run skipped the fetch (marker survived)" \
  "[ -f '$root/v0.1.0/marker' ] && printf %s \"\$out\" | grep -q 'fetch skipped'"
check "re-run changed no modes" \
  "[ \"\$(stat -c '%a %n' '$root/v0.1.0/bin/delegate' '$root/v0.1.0/VERSION' '$root/v0.1.0/install.sh')\" = \"\$modes1\" ]"
check "re-run left current alone" "[ \$(readlink '$root/current') = ./v0.1.0 ]"

inst "$H" "$XD" --release v0.1.1 --from "$SRC" --no-build
check "second tag installs beside the first" \
  "[ \$rc -eq 0 ] && [ \$(cat '$root/v0.1.1/VERSION') = 0.1.1 ] && [ -f '$root/v0.1.0/marker' ]"
check "current flipped to the new tag" "[ \$(readlink '$root/current') = ./v0.1.1 ]"
check "links still point through current" \
  "[ \$(readlink '$H/bin/delegate') = '$root/current/bin/delegate' ] && [ \$(readlink -f '$H/bin/delegate') = '$root/v0.1.1/bin/delegate' ]"

mkdir -p "$root/v9.9.9"; echo wrong > "$root/v9.9.9/.delegate-version"
inst "$H" "$XD" --release v9.9.9 --from "$SRC" --no-build
check "existing dest with a wrong stamp is refused" '[ $rc -eq 1 ] && printf %s "$out" | grep -qi refus'
check "refused dest left untouched, current unmoved" \
  "[ \$(cat '$root/v9.9.9/.delegate-version') = wrong ] && [ ! -e '$root/v9.9.9/bin' ] && [ \$(readlink '$root/current') = ./v0.1.1 ]"

inst "$H" "$XD" --release v3.0.0 --from "$SRC" --no-build
check "missing tag exits 1" '[ $rc -eq 1 ]'
check "missing tag leaves no dest, no dest.tmp, current unmoved" \
  "[ ! -e '$root/v3.0.0' ] && [ ! -e '$root/v3.0.0.tmp' ] && [ \$(readlink '$root/current') = ./v0.1.1 ]"

inst "$H" "$XD" --release v0.2.0 --from "$BAD" --no-build
check "VERSION/tag mismatch is refused" '[ $rc -eq 1 ] && printf %s "$out" | grep -q VERSION'
check "mismatch leaves nothing in root" "[ ! -e '$root/v0.2.0' ] && [ ! -e '$root/v0.2.0.tmp' ]"

H2=$T/h2; inst "$H2" "$T/xd2" --release v0.1.0 --repo "file://$SRC" --no-build
check "--repo file:// reaches the same outcome as --from" \
  "[ \$rc -eq 0 ] && [ \$(readlink '$T/xd2/delegate/current') = ./v0.1.0 ] && [ \$(cat '$T/xd2/delegate/v0.1.0/.delegate-version') = v0.1.0 ] && [ \$(readlink '$H2/bin/delegate') = '$T/xd2/delegate/current/bin/delegate' ]"
H3=$T/h3; inst "$H3" "$T/xd3" --release v0.1.0 --repo "file://$BAD" --from "$SRC" --no-build
check "--from wins over --repo" "[ \$rc -eq 0 ] && [ -f '$T/xd3/delegate/v0.1.0/VERSION' ]"

H4=$T/h4; mkdir -p "$T/xd4/delegate/current" && echo mine > "$T/xd4/delegate/current/file"
inst "$H4" "$T/xd4" --release v0.1.0 --from "$SRC" --no-build
check "a real directory named current is refused" '[ $rc -eq 1 ] && printf %s "$out" | grep -qiE "not a symlink"'
check "current dir kept, never rmdir-ed" "[ -f '$T/xd4/delegate/current/file' ]"

inst "$H" "$XD" --release 0.1.1 --from "$SRC" --no-build
check "a second tag on one commit installs (the tag names the dir)" \
  "[ \$rc -eq 0 ] && [ \$(cat '$root/0.1.1/.delegate-version') = 0.1.1 ] && [ \$(readlink '$root/current') = ./0.1.1 ]"

doctor_of "$H" "$XD"
check "doctor: the release line, exact" \
  "printf %s \"\$docout\" | grep -qE '^install: release 0[.]1[.]1 \\(current -> $root/0[.]1[.]1\\)\$'"
check "delegate --version unchanged through the release link" \
  "[ \"\$(env HOME='$H' '$H/bin/delegate' --version)\" = \"\$(env HOME='$H' '$here/bin/delegate' --version)\" ]"

# plain ./install.sh: today's behaviour, and doctor says dev checkout
H7=$T/h7; inst "$H7" NONE --no-build
check "plain install exits 0, links into the dev checkout" \
  "[ \$rc -eq 0 ] && [ \$(readlink '$H7/bin/delegate') = '$here/bin/delegate' ]"
doctor_of "$H7" NONE
check "doctor: the dev checkout line, exact" "printf %s \"\$docout\" | grep -qE '^install: dev checkout \\($here\\)\$'"

inst "$H7" NONE --uninstall
check "uninstall removes dev links and keeps the config" \
  "[ \$rc -eq 0 ] && [ ! -L '$H7/bin/delegate' ] && [ ! -L '$H7/skills/delegate' ] && [ ! -L '$H7/cfg/opencode/commands/delegate.md' ] && [ ! -L '$H7/agents/delegate-lead.md' ] && [ -f '$H7/cfg/delegate/config.env' ]"
echo not-a-link > "$H7/bin/delegate"
inst "$H7" NONE --uninstall
check "uninstall leaves a foreign file alone, still exits 0" \
  "[ \$rc -eq 0 ] && [ \$(cat '$H7/bin/delegate') = not-a-link ]"
inst "$H" "$XD" --uninstall
check "uninstall removes links pointing under root, keeps root" \
  "[ \$rc -eq 0 ] && [ ! -L '$H/bin/delegate' ] && [ -d '$root/v0.1.0' ]"
inst "$H" "$XD" --purge
check "purge removes root when this checkout is outside it" "[ \$rc -eq 0 ] && [ ! -e '$root' ]"

# purge from a checkout that IS inside root must not saw off its own branch
out=$(env HOME="$H2" XDG_CONFIG_HOME="$H2/cfg" XDG_DATA_HOME="$T/xd2" \
  DELEGATE_BIN_DIR="$H2/bin" CLAUDE_SKILLS_DIR="$H2/skills" CLAUDE_AGENTS_DIR="$H2/agents" \
  "$T/xd2/delegate/v0.1.0/install.sh" --purge 2>&1); rc=$?
check "purge from inside root keeps root and says why" \
  "[ \$rc -eq 0 ] && [ -d '$T/xd2/delegate' ] && printf %s \"\$out\" | grep -qi inside"

# a root deleted by hand leaves dangling links: uninstall/purge must still own and clean them
rm -rf "$T/xd2/delegate/v0.1.0"
inst "$H2" "$T/xd2" --purge
check "purge removes dangling links under root, then root itself" \
  "[ \$rc -eq 0 ] && [ ! -L '$H2/bin/delegate' ] && [ ! -e '$T/xd2/delegate' ]"

XDG_REL=$T/h5; inst "$XDG_REL" "" --release v0.1.0 --from "$SRC" --no-build
check "empty XDG_DATA_HOME treated as unset" "[ \$rc -eq 0 ] && [ -f '$XDG_REL/.local/share/delegate/v0.1.0/VERSION' ]"
inst "$T/h6" "reldir" --release v0.1.0 --from "$SRC" --no-build
check "relative XDG_DATA_HOME treated as unset" "[ \$rc -eq 0 ] && [ -f '$T/h6/.local/share/delegate/v0.1.0/VERSION' ] && [ ! -e '$T/reldir' ]"
check "relative XDG_DATA_HOME: nothing written into the current directory (opencode --version logs there)" "[ ! -e reldir ] && [ ! -e '$here/reldir' ]"

# a --repo value that looks like a git option is a repository path, never an option
H9=$T/h9; mkdir -p "$H9"
inst "$H9" "$H9/data" --release v0.1.0 --repo "--upload-pack=touch $T/pwned" --no-build
check "an option-shaped --repo is refused" "[ $rc -ne 0 ]"
check "an option-shaped --repo never runs as a git option" "[ ! -e '$T/pwned' ]"
check "VERSION file agrees with bin/delegate" \
  "[ \"\$(cat '$here/VERSION')\" = \"\$(sed -n 's/^VERSION=//p' '$here/bin/delegate' | head -n1)\" ]"

check "no .tmp litter anywhere under the temp dir" \
  "! find '$T' -name '*.tmp' -not -path '*/.git/*' | grep -q ."
[ $fail -eq 0 ] && echo "PASS tests/test_release_install.sh"
exit $fail
