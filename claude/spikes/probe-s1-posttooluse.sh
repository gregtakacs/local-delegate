#!/bin/bash
# probe-s1-posttooluse.sh — spike S1: PostToolUse hookSpecificOutput.additionalContext
# reaches the model in a headless -p run, and an async:true hook entry is not skipped
# (docs/specs/o1b-design.md §6; relied on by the step-4 todo/verify hooks).
# Drives claude -p with a throwaway --settings file inside a fresh temp dir; never
# reads or writes the machine's real login directory. Prints one SPIKE line.
set -u
ID="S1"
usage() {
  printf 'usage: %s [--help | --commands]\n' "$(basename "$0")"
  printf '  runs spike %s, prints one "SPIKE %s: PASS|FAIL|NOT-RUN-HERE" line; exit 0 unless FAIL\n' "$ID" "$ID"
}
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --commands)
    cat <<'CMDS'
SPIKE S1 commands:
  # TMP = fresh mktemp -d; writes TMP/proj, TMP/hook-ctx.sh, TMP/hook-async.sh, TMP/settings.json
  write TMP/hook-ctx.sh    # reads hook JSON on stdin, logs it, prints {"hookSpecificOutput":
                           #   {"hookEventName":"PostToolUse","additionalContext":"spike marker S1-SYNC-<n>"}}
  write TMP/hook-async.sh  # same shape, marker S1-ASYNC-<n>
  write TMP/settings.json  # {"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[
                           #   {"type":"command","command":"bash TMP/hook-ctx.sh"},
                           #   {"type":"command","command":"bash TMP/hook-async.sh","async":true}]}]}}
  cd TMP/proj && claude -p "Run exactly: echo hello. Then list every 'spike marker' TOKEN given in your context, or NONE." \
    --settings TMP/settings.json --output-format json
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

mkdir -p "$T/proj"
N1="S1-SYNC-$$-${RANDOM}${RANDOM}"
N2="S1-ASYNC-$$-${RANDOM}${RANDOM}"
export SPIKE1_LOG="$T/hook.log"
cat > "$T/hook-ctx.sh" <<'HK'
#!/bin/bash
in=$(cat)
printf '%s\n' "$in" >> "$SPIKE1_LOG"
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"spike marker %s"}}\n' "$SPIKE1_SYNC"
exit 0
HK
sed 's/SPIKE1_SYNC/SPIKE1_ASYNC/; s/hook\.log/hook-async.log/' "$T/hook-ctx.sh" > "$T/hook-async.sh"
chmod +x "$T/hook-ctx.sh" "$T/hook-async.sh"
python3 - "$T" <<'PY'
import json,sys
T=sys.argv[1]
cfg={"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[
  {"type":"command","command":"bash %s/hook-ctx.sh" % T},
  {"type":"command","command":"bash %s/hook-async.sh" % T,"async":True}]}]}}
json.dump(cfg,open(T+"/settings.json","w"))
PY
Q='Use the Bash tool to run exactly this command: echo hello. Then answer with every TOKEN that appeared in your context as "spike marker <TOKEN>", separated by commas, or NONE if there were none.'
out="$(cd "$T/proj" && SPIKE1_SYNC="$N1" SPIKE1_ASYNC="$N2" timeout 300 claude -p "$Q" --settings "$T/settings.json" --output-format json 2>"$T/err")" \
  || report FAIL "claude -p exited nonzero ($VER); err head: $(head -c 120 "$T/err")"
res="$(printf '%s' "$out" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("result",""))
except Exception: print(sys.stdin.read())' 2>/dev/null)"
sync_ok=FAIL; async_ok=FAIL
printf '%s' "$res" | grep -q -- "$N1" && sync_ok=PASS
printf '%s' "$res" | grep -q -- "$N2" && async_ok=PASS
log_ok=FAIL
[ -s "$T/hook.log" ] && log_ok=PASS
ev="version=$VER; additionalContext sync=$sync_ok async=$async_ok; hook stdin log=$log_ok (async fired: $([ -s "$T/hook-async.log" ] && echo yes || echo no))"
[ "$sync_ok" = PASS ] && [ "$async_ok" = PASS ] && [ "$log_ok" = PASS ] && report PASS "$ev"
report FAIL "$ev"
