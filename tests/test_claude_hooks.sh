#!/bin/bash
# tests/test_claude_hooks.sh — the hook contract test (O1b step 4, design §13/§14).
# No `claude` needed: handcrafted event JSON is piped into claude/hooks/harness.py and the
# stdout shapes asserted. Covers: PostToolUse todo nudge gated on the JS budget (nudge only
# after 8 calls since a todowrite), verify-loop once-per-file, PreCompact stdout line,
# SessionStart JSON key, PermissionRequest allow ONLY on an exception match and SILENT on every
# docs/permission-judge.md §3 hard-limit command, crash-safety on garbage stdin, an inert guard
# when the policy is absent, and the §9 claude-exempt assertion made testable: harness.py carries
# no edit-size/payload-size check.
#
# The nudge strings are the SHARED fixture: taken verbatim from opencode/plugins/todo-loop.js so
# the Python port and the JS twin stay honest to one another (spec §Notes).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
H=$here/claude/hooks/harness.py
STATE=$(mktemp -d)/state           # keep every run's counters isolated
export DELEGATE_CLAUDE_HOOK_STATE="$STATE"
unset DELEGATE_EVIDENCE_DIR CLAUDE_CODE_TASK_NOTES 2>/dev/null || true
T=$(mktemp -d); trap 'rm -rf "$STATE" "$T" /tmp/opencode-notes/hook-test-*' EXIT
fail=0
ok(){ echo "ok   $1"; }
bad(){ echo "FAIL $1"; fail=1; }

ev(){ # event-json builder: ev KEY=VAL ...
  python3 - "$@" <<'PY'
import json,sys
d={}
for a in sys.argv[1:]:
    k,_,v=a.partition("=")
    try: v=json.loads(v)
    except Exception: pass
    d[k]=v
print(json.dumps(d))
PY
}
run(){ printf '%s' "$1" | python3 "$H"; }
out(){ run "$1" > "$T/o" 2>"$T/e"; cat "$T/o"; }
rc(){ run "$1" >/dev/null 2>&1; echo $?; }
has(){ printf '%s' "$2" | grep -qF -- "$1"; }
SID(){ echo "t-$RANDOM$RANDOM"; }   # fresh session id per assertion family

# --- 1. todo nudge appears ONLY after the budgeted call count (JS CALLS_BETWEEN_NUDGES = 8) ----
s=$(SID)
mk(){ ev hook_event_name=PostToolUse session_id="$s" cwd=/tmp tool_name="$1" tool_use_id="$2" tool_input="$3"; }
mk TodoWrite "$(SID)" '{"todos":[]}' | python3 "$H" >/dev/null   # establish ever_listed, reset window
first7_clean=1
for i in $(seq 1 7); do
  o=$(out "$(mk Bash call-$i '{"command":"echo x"}')")
  has "<todo-reminder>" "$o" && { first7_clean=0; bad "todo nudge fired early (call $i)"; }
done
[ "$first7_clean" = 1 ] && ok "no todo nudge for calls 1-7 after a todowrite"
o8=$(out "$(mk Bash call-8 '{"command":"echo x"}')")
if has "<todo-reminder>" "$o8" && has "8 tool calls since you last updated your task list" "$o8" \
   && ! has "opencode" "$o8" && ! has "todowrite" "$o8" && has "</todo-reminder>" "$o8"; then
  ok "todo nudge fires at call 8 with Claude wording, no opencode/todowrite (window advances)"
else
  bad "todo nudge at call 8: got: $o8"
fi
o9=$(out "$(mk Bash call-9 '{"command":"echo x"}')")
has "<todo-reminder>" "$o9" && bad "todo re-nudged at call 9 (budget not honoured)" || ok "no re-nudge at call 9 (window advances per JS)"

b=$(SID)
bmk(){ ev hook_event_name=PostToolUse session_id="$b" cwd=/tmp tool_name=Bash tool_use_id="$1" tool_input='{"command":"x"}'; }
barren_hit=0
for i in $(seq 1 13); do
  o=$(out "$(bmk barren-$i)")
  if has "<todo-reminder>" "$o"; then
    if [ "$i" = 12 ] && has "long enough to plan" "$o"; then barren_hit=1; else barren_hit=2; fi
  fi
done
[ "$barren_hit" = 1 ] && ok "no-list session nudges once at call 12 (CALLS_WITHOUT_LIST)" || bad "barren nudge wrong (hit=$barren_hit)"

# --- 2. verify-loop: once per UI file per session, points at the UI rule §C ---------------------
s2=$(SID)
w(){ ev hook_event_name=PostToolUse session_id="$s2" cwd=/tmp tool_name=Write tool_use_id="$1" tool_input="$2"; }
v1=$(out "$(w e1 '{"file_path":"/tmp/app/index.html"}')")
if has "<verify-reminder>" "$v1" && has "/tmp/app/index.html" "$v1" \
   && has "delegate-verify-ui.md" "$v1" && has "§C" "$v1" && has "ONE sweep" "$v1"; then
  ok "first UI edit reminds once, naming delegate-verify-ui.md / §C"
else
  bad "verify reminder: got: $v1"
fi
v2=$(out "$(w e2 '{"file_path":"/tmp/app/index.html"}')")
has "<verify-reminder>" "$v2" && bad "verify reminded twice for the same file" || ok "second edit of the same file: silent (once-per-file)"
v3=$(out "$(w e3 '{"file_path":"/tmp/app/main.css"}')")
has "<verify-reminder>" "$v3" && ok "a DIFFERENT UI file reminds again (per-file, not per-session)" || bad "distinct UI file not reminded: $v3"
v4=$(out "$(w e4 '{"file_path":"/tmp/app/main.py"}')")
has "<verify-reminder>" "$v4" && bad "non-UI edit reminded" || ok "non-UI file: silent"

# --- 3. PreCompact: the notes pointer on STDOUT (plain line), only when a notes file exists ------
nodir=/tmp/opencode-notes/hook-test-$$; mkdir -p "$nodir"
pc=$(out "$(ev hook_event_name=PreCompact trigger=auto session_id=$(SID) transcript_path=/tmp/x cwd="$nodir")")
[ -z "$pc" ] && ok "PreCompact with no notes file: no stdout" || bad "PreCompact emitted without a file: $pc"
echo hi > "$nodir/NOTES.md"
pc=$(out "$(ev hook_event_name=PreCompact trigger=manual session_id=$(SID) transcript_path=/tmp/x cwd="$nodir")")
[ "$(rc "$(ev hook_event_name=PreCompact trigger=manual session_id=$(SID) cwd="$nodir")")" = 0 ] || bad "PreCompact nonzero exit"
if has "your notes: $nodir/NOTES.md" "$pc" && has "read it before continuing" "$pc" && ! printf '%s' "$pc" | grep -qF '{'; then
  ok "PreCompact stdout = one notes pointer line (plain text, not JSON): $pc"
else
  bad "PreCompact line: got: $pc"
fi

# --- 4. SessionStart: the same content via additionalContext (JSON key present) ------------------
ss=$(out "$(ev hook_event_name=SessionStart source=startup session_id=$(SID) cwd="$nodir")")
if printf '%s' "$ss" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["hookEventName"]=="SessionStart"; assert "NOTES.md" in d["hookSpecificOutput"]["additionalContext"]'; then
  ok "SessionStart additionalContext carries the notes pointer (JSON key shape)"
else
  bad "SessionStart shape: got: $ss"
fi
ssmiss=$(out "$(ev hook_event_name=SessionStart source=startup session_id=$(SID) cwd=/tmp/opencode-notes/hook-test-missing-$$)")
[ -z "$ssmiss" ] && ok "SessionStart with no notes file: silent" || bad "SessionStart printed without a file: $ssmiss"

# --- 5. PermissionRequest: allow ONLY on an exception match; silent on every §3 hard limit ------
pr(){ ev hook_event_name=PermissionRequest session_id=p cwd=/tmp tool_name=Bash tool_input="$(python3 -c 'import json,sys;print(json.dumps({"command":sys.argv[1]}))' "$1")"; }
allow=$(out "$(pr 'curl http://localhost:9090/healthz')")
if printf '%s' "$allow" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["decision"]["behavior"]=="allow"; assert d["hookSpecificOutput"]["hookEventName"]=="PermissionRequest"; assert d["hookSpecificOutput"]["decision"]["reason"]=="delegate policy exception"'; then
  ok "guard allows the policy exception (curl *healthz*)"
else
  bad "guard did not allow exception: got: $allow"
fi
for c in 'sudo ls' 'git push --force' 'git push --force-with-lease' 'echo hi && sudo rm -rf /' 'su - root' 'doas reboot' 'pkill chrome' 'killall node' 'rm -rf /' 'git reset --hard' 'npm install -g foo' 'curl http://h/healthz && sudo reboot'; do
  o=$(out "$(pr "$c")")
  [ -z "$o" ] && [ "$(rc "$(pr "$c")")" = 0 ] || bad "guard NOT silent on §3 command: $c -> $o"
done
ok "guard silent (no stdout, exit 0) on the full §3 hard-limit command list"
envread=$(out "$(ev hook_event_name=PermissionRequest session_id=p cwd=/tmp tool_name=Read tool_input='{"file_path":"/x/app/.env"}')")
[ -z "$envread" ] || bad "guard allowed a .env read: $envread"
benign=$(out "$(pr 'git status --short')")
[ -z "$benign" ] || bad "guard decided on a non-exception command: $benign"
ok "guard stays silent on non-exception commands (human/classifier answers)"
cmp=$(out "$(pr 'curl http://h/healthz && git push --force')")
[ -z "$cmp" ] || bad "compound with a denied subcommand produced an allow: $cmp"
ok "compound: an exception subcommand never overrides a denied sibling (S4 finding)"
# Shell plumbing the splitter does not model (pipe, background, redirect, newline, substitution,
# subshell) must never ride along on an exception: the glob's `*` would swallow it.
for c in 'curl http://h/healthz | python3' 'curl http://h/healthz & rm -r ~/x' 'curl http://h/healthz > ~/.bashrc' \
         "$(printf 'curl http://h/healthz\nrm -r ~/x')" 'curl http://h/healthz$(id)' 'curl http://h/healthz `id`' \
         'curl http://h/healthz <(cat ~/x)' '(curl http://h/healthz)'; do
  o=$(out "$(pr "$c")")
  [ -z "$o" ] || bad "guard allowed an exception with shell plumbing: $c -> $o"
done
ok "guard never allows an exception carrying a pipe, &, redirect, newline or substitution"

# --- 6. fail-to-human: a missing policy file makes the guard inert ------------------------------
tree=$T/faketree; mkdir -p "$tree/claude/hooks" "$tree/lib"
cp "$here"/claude/hooks/*.py "$tree/claude/hooks/"
cp "$here"/lib/*.py "$tree/lib/"          # policy/ deliberately absent
fh="$tree/claude/hooks/harness.py"
inert=$(printf '%s' "$(pr 'curl http://localhost:9090/healthz')" | python3 "$fh"; echo "rc$?")
[ "$inert" = "rc0" ] || bad "guard not inert without a policy file: $inert"
ok "no policy file (permissions opted out): guard inert, exit 0, no decision"

# --- 7. crash-safety: garbage stdin / unknown event are exit 0, silent --------------------------
[ "$(out 'this is not json at all {{{')" = "" ] || bad "garbage stdin produced output"
[ "$(rc 'not json')" = 0 ] || bad "garbage stdin nonzero exit"
ok "garbage stdin: exit 0, silent (no traceback)"
[ -z "$(out "$(ev hook_event_name=NonexistentEvent session_id=z)")" ] || bad "unknown event produced output"
ok "unknown event name: silent, exit 0"

# --- 8. §9 claude-exempt made testable: harness.py has NO edit/payload size check ---------------
# Assert the ABSENCE of size GATING (an executable length comparison / a rejection), not the
# absence of the topic word: harness.py legitimately documents the exemption in prose. A gate
# would look like `len(...) > N`, a "too large"/"exceeding" rejection, a *_CHAR_LIMIT constant,
# or a PreToolUse handler. None may appear.
if grep -nE 'len\([^)]*\)[[:space:]]*[<>]|CHAR_LIMIT|char_limit|too large|exceeding the|PreToolUse' "$H"; then
  bad "harness.py gates on argument size (Claude Code must be cap-exempt)"
else
  ok "harness.py has no edit-size/payload-size check (cap-abstence, §9)"
fi
# and no hook module enforces a cap / rejects an oversized payload
if grep -rnE 'CHAR_LIMIT|char_limit|too large|exceeding the recommended|len\([A-Za-z_.]*\)[[:space:]]*>[[:space:]]*[0-9]{4}' "$here"/claude/hooks/*.py; then
  bad "a hook module enforces an edit/payload cap"
else
  ok "no hook module enforces a cap"
fi

# --- 9. per-session idempotency: two PostToolUse matchers, one tool_use_id, run once -----------
s3=$(SID)
id_ev(){ ev hook_event_name=PostToolUse session_id="$s3" cwd=/tmp tool_name=Write tool_use_id=dup tool_input='{"file_path":"/tmp/p/a.tsx"}'; }
i1=$(out "$(id_ev)")
i2=$(out "$(id_ev)")
has "<verify-reminder>" "$i1" || bad "first matcher invocation produced no reminder: $i1"
[ -z "$i2" ] || bad "second matcher (same tool_use_id) double-fired: $i2"
ok "two settings matchers on one Edit fire the reminder once (tool_use_id idempotency)"

# --- 10. corrupt / unreadable policy: fail-to-human, never a guess ------------------------------
ctree=$T/ctree; mkdir -p "$ctree/policy" "$ctree/lib" "$ctree/claude/hooks"
cp "$here"/lib/*.py "$ctree/lib/"; cp "$here"/claude/hooks/*.py "$ctree/claude/hooks/"
cpr(){ printf '{"hook_event_name":"PermissionRequest","session_id":"p","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"curl http://h/healthz"}}'; }
for body in 'not json {{{' '' '{"version":"x"}' '{"version":1,"bash":[{"pattern":"*","effect":"perhaps"}]}'; do
  printf '%s' "$body" > "$ctree/policy/harness-permissions.json"
  o=$(cpr | python3 "$ctree/claude/hooks/harness.py" 2>"$T/cerr"); rc=$?
  [ -z "$o" ] && [ "$rc" = 0 ] && [ ! -s "$T/cerr" ] || bad "guard decided/errored on a broken policy ($body): out=$o rc=$rc"
done
ok "corrupt/unvalidated/empty policy: silent, exit 0, no stderr (fail-to-human)"

# --- 11. notes path resolves from DELEGATE_EVIDENCE_DIR when the hook runs in a worker round ---
evdir=$T/ev; mkdir -p "$evdir"; echo hi > "$evdir/NOTES.md"
enpc=$(printf '%s' "$(ev hook_event_name=PreCompact trigger=auto session_id=$(SID) cwd=/tmp)" | env DELEGATE_EVIDENCE_DIR="$evdir" python3 "$H")
has "$evdir/NOTES.md" "$enpc" && ok "worker round: notes pointer uses DELEGATE_EVIDENCE_DIR" || bad "DELEGATE_EVIDENCE_DIR ignored: $enpc"

# --- 12. stale state (> 24 h) is a new session, not a suppressed budget -------------------------
ss2=$(SID); sp=$(printf '%s' "$STATE" | sed 's#/$##'); sp="$sp/$ss2.json"
printf '{"calls":999,"nudges":9,"ever_listed":true,"ui_reminded":["/tmp/app/index.html"],"ui_pending":[],"done_ids":[],"updated":0}' > "$sp"
touch -d '25 hours ago' "$sp"
so=$(out "$(ev hook_event_name=PostToolUse session_id="$ss2" cwd=/tmp tool_name=Write tool_use_id=z1 tool_input='{"file_path":"/tmp/app/index.html"}')")
has "<verify-reminder>" "$so" && ok "state older than 24h treated as a new session (reminder not suppressed)" || bad "stale state suppressed the reminder"

# --- 13. state isolation: files live under the state dir, keyed per session ----------------------
ls "$STATE" >/dev/null 2>&1 && ok "state dir written under $STATE" || bad "no state dir created"

exit $fail
