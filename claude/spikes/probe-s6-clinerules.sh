#!/bin/bash
# probe-s6-clinerules.sh — spike S6 (docs/specs/o1b-design.md §6): the Claude Code route for the
# shared `.clinerules` dir, to be picked by measurement, not assumption:
#   route 1: project CLAUDE.md with a file import  "@.clinerules/rule-a.md"
#   route 2: project CLAUDE.md with a directory import "@.clinerules/"  (does it expand to *.md?)
#   route 3: no CLAUDE.md; a rule-like instruction telling the agent to read the dir
#            (stand-in for a user rule: --append-system-prompt; the user-rule file itself lives in
#            the login dir this probe must not touch, so step 2's shipped wording uses the same
#            sentence and the orchestrator re-checks with the real user rule)
# PASS = at least one route makes the agent state the code word; the evidence line names which,
# and whether both the file and the directory forms of `.clinerules` were picked up.
set -u
ID="S6"
usage() {
  printf 'usage: %s [--help | --commands]\n' "$(basename "$0")"
  printf '  runs spike %s, prints one "SPIKE %s: PASS|FAIL|NOT-RUN-HERE" line; exit 0 unless FAIL\n' "$ID" "$ID"
}
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --commands)
    cat <<'CMDS'
SPIKE S6 commands:
  # TMP = fresh mktemp -d; TMP/proj{1,2,3}/.clinerules/rule-a.md holds "code word S6A-*",
  # rule-b.md holds "code word S6B-*"
  printf '@.clinerules/rule-a.md\n'            > TMP/proj1/CLAUDE.md   # route 1 (file import)
  printf '@.clinerules/\n'                     > TMP/proj2/CLAUDE.md   # route 2 (dir import)
  # route 3: no CLAUDE.md; run 3 appends a system rule telling the agent to read the dir first
  cd TMP/projN && claude -p "State every code word in your context, comma separated, or NONE." --output-format json
  #   (run 3 adds: --append-system-prompt "Before answering, read every .md file under .clinerules/ in the project")
  # expect: which route(s) answer with the S6A (and for the dir form, also S6B) words
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
pre="$(timeout 90 claude -p "Reply with exactly PONG." --output-format json 2>&1)" \
  || report NOT-RUN-HERE "claude present ($VER) but a no-settings preflight -p run failed (unlogged-in or endpoint unreachable); head: ${pre:0:140}"

A="S6A-$$-${RANDOM}${RANDOM}"; B="S6B-$$-${RANDOM}${RANDOM}"
for p in 1 2 3; do
  mkdir -p "$T/proj$p/.clinerules"
  printf 'The first code word is %s.\n' "$A" > "$T/proj$p/.clinerules/rule-a.md"
  printf 'The second code word is %s.\n' "$B" > "$T/proj$p/.clinerules/rule-b.md"
done
printf '@.clinerules/rule-a.md\n' > "$T/proj1/CLAUDE.md"
printf '@.clinerules/\n' > "$T/proj2/CLAUDE.md"
Q='State every code word that appears in your context, comma separated, or NONE. Do not invent words.'
routeword() { # $1 project, $2 extra args...
  local out res
  out="$(cd "$T/proj$1" && timeout 300 claude -p "$Q" --output-format json "${@:3}" 2>/dev/null)" || true
  res="$(printf '%s' "$out" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("result",""))
except Exception: print("")' 2>/dev/null)"
  printf '%s' "$res"
}
r1="$(routeword 1)"; r2="$(routeword 2)"
r3="$(routeword 3 --append-system-prompt 'Before answering any question, read every .md file under .clinerules/ in the project directory (and nothing else extra).')"
w1=$(printf '%s' "$r1" | grep -qF -- "$A" && echo yes || echo no)
w2a=$(printf '%s' "$r2" | grep -qF -- "$A" && echo yes || echo no)
w2b=$(printf '%s' "$r2" | grep -qF -- "$B" && echo yes || echo no)
w3=$(printf '%s' "$r3" | grep -qF -- "$A" && echo yes || echo no)
picked="none"
[ "$w1" = yes ] && picked="CLAUDE.md @import(file)"
[ "$w2a$w2b" = yesyes ] && picked="CLAUDE.md @import(dir)"
[ "$w3" = yes ] && picked="${picked/none/append-system-prompt(user-rule stand-in)}"
ok=FAIL
{ [ "$w1" = yes ] || [ "$w2a$w2b" = yesyes ] || [ "$w3" = yes ]; } && ok=PASS
ev="version=$VER; file-import=$w1 dir-import(A,B)=$w2a/$w2b read-dir-rule=$w3; picked=$picked (route 3 is a stand-in for the shipped user-rule wording; re-check with the real user rule)"
[ "$ok" = PASS ] && report PASS "$ev"
report FAIL "$ev"
