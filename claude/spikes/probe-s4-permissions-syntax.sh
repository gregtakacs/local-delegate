#!/bin/bash
# probe-s4-permissions-syntax.sh — spike S4 (docs/specs/o1b-design.md §6): the permission-rule
# semantics step 3's translator relies on, on the *installed* version: prefix patterns,
# `:*`/trailing-space anchoring, deny>ask>allow order, subcommand splitting of `cmd1 && cmd2`,
# `$()` handling, and Read/Edit path syntax (`**/.env`, `**/notes/*.md`).
# `git push` appears only inside deny rules and in commands the deny is expected to BLOCK;
# the throwaway project is not a git repo, so even a leaked attempt dies harmlessly.
# Oracle: logger hooks (attempted vs executed) + --output-format json permission_denials.
# Prints one SPIKE line.
set -u
ID="S4"
usage() {
  printf 'usage: %s [--help | --commands]\n' "$(basename "$0")"
  printf '  runs spike %s, prints one "SPIKE %s: PASS|FAIL|NOT-RUN-HERE" line; exit 0 unless FAIL\n' "$ID" "$ID"
}
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --commands)
    cat <<'CMDS'
SPIKE S4 commands:
  # TMP = fresh mktemp -d (NOT a git repo); logger hooks append tool_name+tool_input to
  # TMP/attempted (PreToolUse) and TMP/executed (PostToolUse); settings files below all carry them.
  write TMP/settings-1.json # allow  ["Bash(echo SPIKE4a*)"]
  write TMP/settings-2.json # deny   ["Bash(echo SPIKE4b*)"] allow ["Bash(echo *)"]
  write TMP/settings-3.json # deny   ["Bash(echo SPIKE4c *)"] allow ["Bash(echo *)"]
  write TMP/settings-4.json # deny   ["Bash(git push*)"] allow ["Bash(echo SPIKE4d*)"]
  write TMP/settings-5.json # deny   ["Bash(git push*)"] allow ["Bash(echo *)"]
  write TMP/settings-6.json # deny   ["Read(**/.env)"]
  write TMP/settings-7.json # allow  ["Edit(**/notes/*.md)"]
  cd TMP/proj
  claude -p "Run exactly: echo SPIKE4a"            --settings TMP/settings-1.json --output-format json   # executed has SPIKE4a
  claude -p "Run exactly: echo SPIKE4b"            --settings TMP/settings-2.json --output-format json   # denied (deny>allow)
  claude -p "Run exactly: echo SPIKE4cX"           --settings TMP/settings-3.json --output-format json   # executed (space form does not match SPIKE4cX)
  claude -p "Run exactly: echo SPIKE4c tail"       --settings TMP/settings-3.json --output-format json   # denied (space form matches)
  claude -p "Run exactly: echo SPIKE4d && git push" --settings TMP/settings-4.json --output-format json  # echo executed, push denied (subcommand split)
  claude -p "Run exactly: echo SPIKE4e $(git push)" --settings TMP/settings-5.json --output-format json  # whole command denied ($() nested deny)
  claude -p "Read the .env file in this directory and state its contents." --settings TMP/settings-6.json --output-format json  # Read denied
  claude -p "Append the line SPIKE4f to notes/a.md." --settings TMP/settings-7.json --output-format json # Edit executed
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

mkdir -p "$T/proj/notes"
printf 'SPIKE4-SECRET=word\n' > "$T/proj/.env"
printf 'existing line\n' > "$T/proj/notes/a.md"
export SPIKE4_DIR="$T"
cat > "$T/hook-pre-log.sh" <<'HK'
#!/bin/bash
python3 -c 'import json,sys,os
d=json.load(sys.stdin)
open(os.environ["SPIKE4_DIR"]+"/attempted","a").write(d.get("tool_name","")+" "+json.dumps(d.get("tool_input",{}))+"\n")'
exit 0
HK
cat > "$T/hook-post-log.sh" <<'HK'
#!/bin/bash
python3 -c 'import json,sys,os
d=json.load(sys.stdin)
open(os.environ["SPIKE4_DIR"]+"/executed","a").write(d.get("tool_name","")+" "+json.dumps(d.get("tool_input",{}))+"\n")'
exit 0
HK
chmod +x "$T/hook-pre-log.sh" "$T/hook-post-log.sh"
python3 - "$T" <<'PY'
import json,sys
T=sys.argv[1]
logs={"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash %s/hook-pre-log.sh" % T}]},
                   {"matcher":"Read","hooks":[{"type":"command","command":"bash %s/hook-pre-log.sh" % T}]},
                   {"matcher":"Edit","hooks":[{"type":"command","command":"bash %s/hook-pre-log.sh" % T}]}],
      "PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash %s/hook-post-log.sh" % T}]},
                   {"matcher":"Edit","hooks":[{"type":"command","command":"bash %s/hook-post-log.sh" % T}]}]}
def w(n, perms):
    cfg={"permissions":perms}; cfg.update(hooks=logs)
    json.dump(cfg,open("%s/settings-%d.json" % (T,n),"w"))
w(1, {"allow":["Bash(echo SPIKE4a*)"]})
w(2, {"deny":["Bash(echo SPIKE4b*)"], "allow":["Bash(echo *)"]})
w(3, {"deny":["Bash(echo SPIKE4c *)"], "allow":["Bash(echo *)"]})
w(4, {"deny":["Bash(git push*)"], "allow":["Bash(echo SPIKE4d*)"]})
w(5, {"deny":["Bash(git push*)"], "allow":["Bash(echo *)"]})
w(6, {"deny":["Read(**/.env)"]})
w(7, {"allow":["Edit(**/notes/*.md)"]})
PY

ask() { # $1 settings n, $2 prompt
  : > "$T/attempted"; : > "$T/executed"
  ( cd "$T/proj" && timeout 300 claude -p "$2" --settings "$T/settings-$1.json" --output-format json ) \
    >"$T/out-$1.json" 2>"$T/err-$1" || true
}
ran() { [ -s "$T/executed" ] && grep -qF -- "$1" "$T/executed" && echo yes || echo no; }
denied_in_out() { [ -s "$T/out-$1.json" ] && grep -q 'permission_denials' "$T/out-$1.json" && grep -qi 'deni' "$T/out-$1.json" && grep -qF -- "$2" "$T/out-$1.json" && echo yes || echo no; }

ask 1 "Use the Bash tool to run exactly this command and nothing else: echo SPIKE4a"
c1=$([ "$(ran SPIKE4a)" = yes ] && echo PASS || echo FAIL)
ask 2 "Use the Bash tool to run exactly this command and nothing else: echo SPIKE4b"
c2=$([ "$(ran SPIKE4b)" = no ] && [ "$(denied_in_out 2 SPIKE4b)" = yes ] && echo PASS || echo FAIL)
ask 3 "Use the Bash tool to run exactly this command and nothing else: echo SPIKE4cX"
c3a=$([ "$(ran SPIKE4cX)" = yes ] && echo PASS || echo FAIL)
ask 3 "Use the Bash tool to run exactly this command and nothing else: echo SPIKE4c tail"
c3b=$([ "$(ran SPIKE4c)" = no ] && echo PASS || echo FAIL)
ask 4 "Use the Bash tool to run exactly this command line and nothing else: echo SPIKE4d && git push"
c4=$([ "$(ran SPIKE4d)" = yes ] && [ "$(ran 'git push')" = no ] && echo PASS || echo FAIL)
ask 5 'Use the Bash tool to run exactly this command and nothing else: echo SPIKE4e $(git push)'
c5=$([ "$(ran SPIKE4e)" = no ] && echo PASS || echo FAIL)
ask 6 "Use the Read tool on the file named .env in the current directory, then say DONE."
c6=$([ "$(ran SPIKE4-SECRET)" = no ] && grep -qF 'Read' "$T/attempted" && echo PASS || echo FAIL)
ask 7 "Use the Edit tool to append the line SPIKE4f to the file notes/a.md."
c7=$([ "$(ran SPIKE4f)" = yes ] && echo PASS || echo FAIL)
all=PASS
for c in "$c1" "$c2" "$c3a" "$c3b" "$c4" "$c5" "$c6" "$c7"; do
  [ "$c" = PASS ] || all=FAIL
done
ev="version=$VER; allow=$c1 deny>allow=$c2 space-anchor:loose=$c3a tight=$c3b subcommand-split=$c4 dollar-paren=$c5 read-env=$c6 edit-path=$c7"
[ "$all" = PASS ] && report PASS "$ev"
report FAIL "$ev"
