#!/bin/bash
# probe-s3-permission-request.sh — spike S3 (docs/specs/o1b-design.md §6, owner question Q1):
# PermissionRequest fires under -p for a rule that says ask; a hook decision.behavior
# "allow" answers it headlessly (with updatedInput honoured); "deny" blocks; and a
# PreToolUse permissionDecision "deny" beats a settings allow. Oracle: PreToolUse/
# PostToolUse logger hooks record attempted vs executed, so nothing relies on the model's
# self-report. All rules live in the throwaway --settings file; the machine's real
# settings are never depended on. Prints one SPIKE line.
set -u
ID="S3"
usage() {
  printf 'usage: %s [--help | --commands]\n' "$(basename "$0")"
  printf '  runs spike %s, prints one "SPIKE %s: PASS|FAIL|NOT-RUN-HERE" line; exit 0 unless FAIL\n' "$ID" "$ID"
}
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --commands)
    cat <<'CMDS'
SPIKE S3 commands:
  # TMP = fresh mktemp -d; hook scripts under TMP log stdin and answer with decision JSON:
  #   hook-ask-allow.sh  -> {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
  #   hook-ask-rewrite.sh-> same, plus decision.updatedInput {"command":"echo SPIKE3d-REWRITTEN"}
  #   hook-ask-deny.sh   -> decision.behavior "deny"
  #   hook-pre-deny.sh   -> PreToolUse {"permissionDecision":"deny","permissionDecisionReason":"spike3"}
  #   hook-pre-log.sh / hook-post-log.sh -> append tool_name+command to TMP/attempted / TMP/executed
  write TMP/settings-A.json # permissions.ask ["Bash(echo SPIKE3a*)"]      + PermissionRequest allow hook
  write TMP/settings-B.json # permissions.ask ["Bash(echo SPIKE3d*)"]      + PermissionRequest rewrite hook
  write TMP/settings-C.json # permissions.ask ["Bash(touch SPIKE3c*)"]     + PermissionRequest deny hook
  write TMP/settings-D.json # permissions.allow ["Bash(touch SPIKE3b*)"]   + PreToolUse deny hook
  cd TMP/proj && for s in A B C D; do claude -p "Run exactly the one command the rules mention." --settings TMP/settings-$s.json --output-format json; done
  # expect: TMP/executed gains "echo SPIKE3a..." and "echo SPIKE3d-REWRITTEN"; no SPIKE3c; no SPIKE3b
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

mkdir -p "$T/proj" "$T/proj/notes"
export SPIKE3_DIR="$T"

# decision-answer hook: $1 = behavior, $2 = rewritten command or empty
hook_decision() { # $1 file, $2 behavior, $3 rewritten cmd
cat > "$1" <<'HK'
#!/bin/bash
cat >> "$SPIKE3_DIR/pr.log"
printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"%s"%s}}}\n' "__BEHAVIOR__" "__EXTRA__"
exit 0
HK
local extra=""
 if [ -n "${3:-}" ]; then
   extra=', "updatedInput": {"command": "'"${3}"'"}'
 fi
 sed -e "s/__BEHAVIOR__/$2/" -e "s|__EXTRA__|$extra|" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
 chmod +x "$1"
}
hook_decision "$T/hook-ask-allow.sh" allow ""
hook_decision "$T/hook-ask-rewrite.sh" allow "echo SPIKE3d-REWRITTEN"
hook_decision "$T/hook-ask-deny.sh" deny ""
cat > "$T/hook-pre-deny.sh" <<'HK'
#!/bin/bash
cat >> "$SPIKE3_DIR/pre.log"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"spike3 probe deny"}}\n'
exit 0
HK
cat > "$T/hook-pre-log.sh" <<'HK'
#!/bin/bash
python3 -c 'import json,sys,os
d=json.load(sys.stdin)
open(os.environ["SPIKE3_DIR"]+"/attempted","a").write(d.get("tool_name","")+" "+json.dumps(d.get("tool_input",{}))+"\n")'
exit 0
HK
cat > "$T/hook-post-log.sh" <<'HK'
#!/bin/bash
python3 -c 'import json,sys,os
d=json.load(sys.stdin)
open(os.environ["SPIKE3_DIR"]+"/executed","a").write(d.get("tool_name","")+" "+json.dumps(d.get("tool_input",{}))+"\n")'
exit 0
HK
chmod +x "$T/hook-pre-deny.sh" "$T/hook-pre-log.sh" "$T/hook-post-log.sh"

python3 - "$T" <<'PY'
import json,sys
T=sys.argv[1]
log=[{"type":"command","command":"bash %s/hook-pre-log.sh" % T},
     {"type":"command","command":"bash %s/hook-post-log.sh" % T}]
def pr(f): return {"hooks":[{"type":"command","command":"bash %s/%s" % (T,f)}]}
def w(name, perms, hooks):
    cfg={}
    if perms: cfg["permissions"]=perms
    if hooks: cfg["hooks"]=hooks
    json.dump(cfg,open(T+"/settings-"+name+".json","w"))
H={"hooks":{}}
def add(ev,*entries):
    H["hooks"].setdefault(ev,[]).extend(entries)
add("PreToolUse", {"matcher":"Bash","hooks":[{"type":"command","command":"bash %s/hook-pre-log.sh" % T}]})
add("PostToolUse",{"matcher":"Bash","hooks":[{"type":"command","command":"bash %s/hook-post-log.sh" % T}]})
w("A", {"ask":["Bash(echo SPIKE3a*)"]}, {**H["hooks"], "PermissionRequest":[{"matcher":"Bash","hooks":pr("hook-ask-allow.sh")["hooks"]}]})
w("B", {"ask":["Bash(echo SPIKE3d*)"]}, {**H["hooks"], "PermissionRequest":[{"matcher":"Bash","hooks":pr("hook-ask-rewrite.sh")["hooks"]}]})
w("C", {"ask":["Bash(touch SPIKE3c*)"]}, {**H["hooks"], "PermissionRequest":[{"matcher":"Bash","hooks":pr("hook-ask-deny.sh")["hooks"]}]})
w("D", {"allow":["Bash(touch SPIKE3b*)"]}, {**H["hooks"], "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash %s/hook-pre-deny.sh" % T}]}]})
PY

ask() { # $1 settings suffix, $2 exact command hint
  : > "$T/attempted"; : > "$T/executed"
  ( cd "$T/proj" && timeout 300 claude -p "Use the Bash tool to run exactly this one command and nothing else: $2" \
      --settings "$T/settings-$1.json" --output-format json ) >"$T/out-$1.json" 2>"$T/err-$1" || true
}
EX() { [ -s "$T/executed" ] && grep -qF -- "$1" "$T/executed" && echo yes || echo no; }

ask A "echo SPIKE3a"
a_ok=FAIL; [ "$(EX SPIKE3a)" = yes ] && a_ok=PASS
ask B "echo SPIKE3d"
d_ok=FAIL; [ "$(EX SPIKE3d-REWRITTEN)" = yes ] && d_ok=PASS
ask C "touch SPIKE3c"
c_ok=FAIL; [ "$(EX SPIKE3c)" = no ] && [ -s "$T/pr.log" ] && c_ok=PASS
ask D "touch SPIKE3b"
b_ok=FAIL; [ "$(EX SPIKE3b)" = no ] && [ -s "$T/pre.log" ] && b_ok=PASS
ev="version=$VER; ask-hook-allow=$a_ok updatedInput-rewrite=$d_ok ask-hook-deny=$c_ok pretooluse-deny-over-settings-allow=$b_ok; auto-mode(classifier) not probed here - run with --permission-mode auto manually (Q1)"
[ "$a_ok$b_ok$c_ok$d_ok" = PASSPASSPASSPASS ] && report PASS "$ev"
report FAIL "$ev"
