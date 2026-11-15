#!/bin/bash
# probe-s2-notes.sh — spike S2: the events the notes hook needs (docs/specs/o1b-design.md §6):
# SessionStart additionalContext lands on `startup` AND on `--resume` (matcher `resume`);
# the hook payload's cwd is the project dir (worktree check); PreCompact fires for a manual
# /compact and its stdout becomes the compaction instructions. Prints one SPIKE line.
set -u
ID="S2"
usage() {
  printf 'usage: %s [--help | --commands]\n' "$(basename "$0")"
  printf '  runs spike %s, prints one "SPIKE %s: PASS|FAIL|NOT-RUN-HERE" line; exit 0 unless FAIL\n' "$ID" "$ID"
}
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --commands)
    cat <<'CMDS'
SPIKE S2 commands:
  # TMP = fresh mktemp -d; hooks log their stdin JSON (which carries source + cwd) to TMP/ss.log
  write TMP/settings.json  # hooks.SessionStart: matcher "startup" -> hook-ss.sh, matcher "resume" -> hook-sr.sh
                           # hooks.PreCompact: matcher "manual" -> hook-pc.sh (prints preserve-instruction on stdout)
  cd TMP/proj && claude -p "List every spike TOKEN in your context, or NONE." --settings TMP/settings.json --output-format json
  #   -> expect the STARTUP marker; note session_id from the JSON result
  cd TMP/proj && claude -p "List every spike TOKEN in your context, or NONE." --settings TMP/settings.json --resume <session_id> --output-format json
  #   -> expect the RESUME marker; TMP/ss.log must show source=startup then source=resume, cwd=TMP/proj
  cd TMP/proj && claude -p "/compact" --settings TMP/settings.json --output-format json
  #   -> TMP/pc.log must show a PreCompact event with trigger=manual (stdout = compaction instructions)
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
NSS="S2-START-$$-${RANDOM}${RANDOM}"
NRS="S2-RESUME-$$-${RANDOM}${RANDOM}"
NPC="S2-COMPACT-$$-${RANDOM}${RANDOM}"
export SPIKE2_LOG="$T/ss.log" SPIKE2_NPC="$T/pc.log"
cat > "$T/hook-ss.sh" <<'HK'
#!/bin/bash
in=$(cat)
printf '%s\n' "$in" >> "$SPIKE2_LOG"
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"spike marker %s"}}\n' "$SPIKE2_SS"
exit 0
HK
sed 's/SessionStart/SessionStart/; s/SPIKE2_SS/SPIKE2_SR/' "$T/hook-ss.sh" > "$T/hook-sr.sh"
cat > "$T/hook-pc.sh" <<'HK'
#!/bin/bash
in=$(cat)
printf '%s\n' "$in" >> "$SPIKE2_NPC"
printf 'When you compact this conversation, preserve the literal token %s verbatim in the summary.\n' "$SPIKE2_PCN"
exit 0
HK
chmod +x "$T/hook-ss.sh" "$T/hook-sr.sh" "$T/hook-pc.sh"
python3 - "$T" <<'PY'
import json,sys
T=sys.argv[1]
cmd=lambda f:[{"type":"command","command":"bash %s/%s" % (T,f)}]
cfg={"hooks":{
 "SessionStart":[{"matcher":"startup","hooks":cmd("hook-ss.sh")},
                 {"matcher":"resume","hooks":cmd("hook-sr.sh")}],
 "PreCompact":[{"matcher":"manual","hooks":cmd("hook-pc.sh")}]}}
json.dump(cfg,open(T+"/settings.json","w"))
PY
Q='Answer with every TOKEN that appeared in your context as "spike marker <TOKEN>", comma separated, or NONE.'

run() { # $1..: claude args; sets OUT_JSON, ERR; returns claude rc
  OUT_JSON="$(timeout 300 claude -p "$Q" --settings "$T/settings.json" --output-format json "$@" 2>"$T/err")"
}
jget() { printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get(sys.argv[1],""))
except Exception: print("")' "$2"; }

cd "$T/proj" || report FAIL "cannot cd to temp project ($VER)"
SPIKE2_SS="$NSS" run || { report FAIL "startup run exited nonzero ($VER): $(head -c 120 "$T/err")"; }
start_ok=FAIL; printf '%s' "$(jget "$OUT_JSON" result)" | grep -q -- "$NSS" && start_ok=PASS
SID="$(jget "$OUT_JSON" session_id)"
resume_ok=FAIL; [ -n "$SID" ] || { resume_ok=NOID; }
if [ "$resume_ok" = FAIL ] && [ -n "$SID" ]; then
  SPIKE2_SR="$NRS" run --resume "$SID" || true
  printf '%s' "$(jget "$OUT_JSON" result)" | grep -q -- "$NRS" && resume_ok=PASS
fi
cwd_ok=FAIL; [ -s "$T/ss.log" ] && grep -qF -- "$T/proj" "$T/ss.log" && cwd_ok=PASS
src_ok=FAIL; [ -s "$T/ss.log" ] && grep -q '"startup"' "$T/ss.log" && grep -q '"resume"' "$T/ss.log" && src_ok=PASS
pc_ok=FAIL
OUT_PC="$(SPIKE2_PCN="$NPC" timeout 300 claude -p "/compact" --settings "$T/settings.json" --output-format json 2>>"$T/err")" || true
[ -s "$T/pc.log" ] && grep -q 'PreCompact' "$T/pc.log" && pc_ok=PASS
ev="version=$VER; startup-marker=$start_ok resume-marker=$resume_ok payload-cwd=$cwd_ok sources(startup+resume)=$src_ok precompact-manual=$pc_ok; long-session marker-survival not exercised (manual check on a real session)"
[ "$start_ok" = PASS ] && [ "$resume_ok" = PASS ] && [ "$cwd_ok" = PASS ] && [ "$src_ok" = PASS ] && [ "$pc_ok" = PASS ] && report PASS "$ev"
report FAIL "$ev"
