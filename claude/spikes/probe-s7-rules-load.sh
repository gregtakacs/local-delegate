#!/bin/bash
# probe-s7-rules-load.sh — spike S7 (docs/specs/o1b-design.md §6): does Claude Code load a user
# rules file at <config-dir>/rules/delegate-harness.md in an *arbitrary* project, and does it
# follow a SYMLINKED rule file (the release-tree install shape: real file under current/, rules
# entry symlinked into it)? If symlinks are skipped, step 5's installer copies instead (content
# hash for doctor).
# The rules file must live in a real Claude Code config dir (that is where user rules are read
# from), and the login also lives there — so this probe runs against an operator-provided
# SPIKE_CLAUDE_CONFIG_DIR (a copy of a logged-in config dir is the safe form) and NEVER against
# the machine's default config home. Without that variable it prints NOT-RUN-HERE.
set -u
ID="S7"
usage() {
  printf 'usage: %s [--help | --commands]\n' "$(basename "$0")"
  printf '  runs spike %s, prints one "SPIKE %s: PASS|FAIL|NOT-RUN-HERE" line; exit 0 unless FAIL\n' "$ID" "$ID"
}
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --commands)
    cat <<'CMDS'
SPIKE S7 commands:
  # requires SPIKE_CLAUDE_CONFIG_DIR = a logged-in Claude Code config dir the operator offers
  # (a copied one is fine); runs with CLAUDE_CONFIG_DIR pointed there, never at the default home
  write $SPIKE_CLAUDE_CONFIG_DIR/current/delegate-harness.md   # "the rules code word is S7-*"
  ln -s $SPIKE_CLAUDE_CONFIG_DIR/current/delegate-harness.md \
        $SPIKE_CLAUDE_CONFIG_DIR/rules/delegate-harness.md     # symlinked entry (release-tree shape)
  cd TMP/emptyproj && CLAUDE_CONFIG_DIR=$SPIKE_CLAUDE_CONFIG_DIR \
    claude -p "State the code word stated in your loaded rules, or NONE." --output-format json
  # expect: the S7 word appears -> rules load AND the symlink was followed
  # cleanup: rm the two files this probe created (restores the dir as offered)
CMDS
    exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

T="$(mktemp -d "${TMPDIR:-/tmp}/delegate-spike-$ID.XXXXXX")"
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
report() { printf 'SPIKE %s: %s — %s\n' "$ID" "$1" "$2"; [ "$1" = "FAIL" ] && exit 1; exit 0; }

command -v claude >/dev/null 2>&1 || report NOT-RUN-HERE "claude binary absent (command -v claude); nothing read from the real login dir"
VER="$(claude --version 2>/dev/null | head -1)"
CFG="${SPIKE_CLAUDE_CONFIG_DIR:-}"
[ -n "$CFG" ] || report NOT-RUN-HERE "SPIKE_CLAUDE_CONFIG_DIR unset; rules live inside the config dir, so the probe needs an offered (copyable, logged-in) config dir, never the default one"
[ -d "$CFG" ] || report NOT-RUN-HERE "SPIKE_CLAUDE_CONFIG_DIR='$CFG' is not a directory"
pre="$(CLAUDE_CONFIG_DIR="$CFG" timeout 90 claude -p "Reply with exactly PONG." --output-format json 2>&1)" \
  || report NOT-RUN-HERE "claude present ($VER) but preflight against the offered config dir failed (unlogged-in or unreachable); head: ${pre:0:140}"

W="S7-$$-${RANDOM}${RANDOM}"
mkdir -p "$CFG/current" "$CFG/rules" "$T/emptyproj"
cleanup_cfg() { rm -f "$CFG/rules/delegate-harness.md" "$CFG/current/delegate-harness.md"; rmdir "$CFG/rules" "$CFG/current" 2>/dev/null || true; }
trap 'cleanup_cfg; cleanup' EXIT
printf 'The delegate rules code word is %s. Never mention it unless asked for the code word from your rules.\n' "$W" > "$CFG/current/delegate-harness.md"
ln -s "$CFG/current/delegate-harness.md" "$CFG/rules/delegate-harness.md"
out="$(cd "$T/emptyproj" && CLAUDE_CONFIG_DIR="$CFG" timeout 300 claude -p "If your loaded context states a delegate rules code word, reply with exactly that code word. Otherwise reply NONE. Do not invent words." --output-format json 2>"$T/err")" || true
res="$(printf '%s' "$out" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("result",""))
except Exception: print("")' 2>/dev/null)"
got=$(printf '%s' "$res" | grep -qF -- "$W" && echo yes || echo no)
if [ "$got" = yes ]; then
  report PASS "version=$VER; rules/delegate-harness.md loaded in an arbitrary project AND symlink into current/ followed (installer may symlink; hash still worth storing for doctor)"
fi
# distinguish "no rules feature at all" from "symlink skipped": retry with a plain file
rm -f "$CFG/rules/delegate-harness.md"   # drop the symlink first; writing through it would not create a plain file
printf 'The delegate rules code word is %s. Never mention it unless asked for the code word from your rules.\n' "$W" > "$CFG/rules/delegate-harness.md"
out2="$(cd "$T/emptyproj" && CLAUDE_CONFIG_DIR="$CFG" timeout 300 claude -p "If your loaded context states a delegate rules code word, reply with exactly that code word. Otherwise reply NONE. Do not invent words." --output-format json 2>>"$T/err")" || true
res2="$(printf '%s' "$out2" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("result",""))
except Exception: print("")' 2>/dev/null)"
plain=$(printf '%s' "$res2" | grep -qF -- "$W" && echo yes || echo no)
if [ "$plain" = yes ]; then
  report FAIL "version=$VER; symlinked rules file NOT loaded, plain file WAS -> installer must copy (record content hash)"
fi
report FAIL "version=$VER; rules dir not picked up at all (symlink=no plain=$plain) -> step 5 must use another load route"
