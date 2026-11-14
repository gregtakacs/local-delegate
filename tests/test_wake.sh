#!/bin/bash
# delegate-wake: builds the fixed-template prompt from the hook env and POSTs it to the session.
# opencode 2 (/api/session/<id>/prompt, 200) is tried first; a server without that route (404
# that is not SessionNotFound, or 405) gets opencode 1's /session/<id>/prompt_async (204).
# Auth from the URL or the env is sent as Basic; a 401 or an unknown session fails at once;
# a dead server exits 1 (never hangs forever).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"; kill $fake 2>/dev/null' EXIT
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# A fake server whose generation is picked per session id:
#   ses_v2*  -> v2 route answers 200        ses_v1*  -> v2 route 404 (no route), v1 route 204
#   ses_gone -> v2 says SessionNotFound     ses_auth -> 401 unless Basic opencode:pw
# Every request is appended to $T/log as: METHOD PATH AUTH BODY
python3 - "$T" <<'P' &
import http.server, json, sys
t = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        auth = self.headers.get("Authorization", "-")
        with open(t + "/log", "a") as f:
            f.write(json.dumps([self.path, auth, body]) + "\n")
        sid = self.path.split("/")[-2]
        v2 = self.path.startswith("/api/session/")
        if sid == "ses_auth" and auth != "Basic b3BlbmNvZGU6cHc=":
            code, out = 401, "{}"
        elif sid == "ses_gone":
            code, out = 404, '{"_tag":"SessionNotFoundError"}'
        elif v2 and sid.startswith("ses_v1"):
            code, out = 404, ""
        elif v2:
            code, out = 200, '{"data":{}}'
        else:
            code, out = 204, ""
        self.send_response(code); self.end_headers()
        if out: self.wfile.write(out.encode())
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(t + "/port", "w").write(str(srv.server_address[1]))
srv.serve_forever()
P
fake=$!; for _ in $(seq 50); do [ -f $T/port ] && break; sleep 0.1; done
URL=http://127.0.0.1:$(cat $T/port)
last(){ tail -1 $T/log; }
field(){ python3 -c 'import json,sys; print(json.loads(sys.argv[1])[int(sys.argv[2])])' "$(last)" $1; }
unset DELEGATE_WAKE_PASSWORD DELEGATE_WAKE_PASSWORD_FILE OPENCODE_SERVER_PASSWORD OPENCODE_SESSION_ID

DELEGATE_CHAIN=hookdemo DELEGATE_CHAIN_STEP=demo-1 DELEGATE_CHAIN_STEP_N=1 DELEGATE_CHAIN_STEP_TOTAL=2 \
DELEGATE_CHAIN_STEP_STATUS=done DELEGATE_CHAIN_STATUS="demo-1=done, demo-2=running" \
  python3 $here/lib/delegate-wake --url $URL ses_v2a >/dev/null 2>&1; rc=$?
check "v2 server: on-step wake posts /api/session/<id>/prompt and exits 0" "[ $rc = 0 ] && [ \"\$(field 0)\" = /api/session/ses_v2a/prompt ]"
python3 -c 'import json,sys; b=json.loads(json.loads(sys.argv[1])[2]); t=b["text"]; assert "demo-1" in t and "still running" in t, b' "$(last)"
check "the v2 body is {text} and carries the step and says the chain runs on" "[ $? = 0 ]"
check "no password anywhere: no Authorization header" "[ \"\$(field 1)\" = - ]"

DELEGATE_CHAIN=hookdemo DELEGATE_CHAIN_RC=3 DELEGATE_CHAIN_STATUS="demo-1=blocked" DELEGATE_CHAIN_PLAN=/x/PLAN.json \
  python3 $here/lib/delegate-wake --url $URL ses_v1a >/dev/null 2>&1; rc=$?
check "v1 server: falls back to /session/<id>/prompt_async and exits 0" "[ $rc = 0 ] && [ \"\$(field 0)\" = /session/ses_v1a/prompt_async ]"
python3 -c 'import json,sys; b=json.loads(json.loads(sys.argv[1])[2]); t=b["parts"][0]["text"]; assert "ENDED" in t and "BLOCKED" in t and "delegate chain /x/PLAN.json" in t, t' "$(last)"
check "the v1 done wake carries the verdict and the resume command in parts[]" "[ $? = 0 ]"

OPENCODE_SESSION_ID=ses_v2env python3 $here/lib/delegate-wake --url $URL >/dev/null 2>&1; rc=$?
check "SESSION_ID defaults to \$OPENCODE_SESSION_ID" "[ $rc = 0 ] && [ \"\$(field 0)\" = /api/session/ses_v2env/prompt ]"

host=${URL#http://}
python3 $here/lib/delegate-wake --url "http://opencode:pw@$host" ses_auth >/dev/null 2>&1; rc=$?
check "user:pass in the URL becomes a Basic header" "[ $rc = 0 ] && [ \"\$(field 1)\" = 'Basic b3BlbmNvZGU6cHc=' ]"
OPENCODE_SERVER_PASSWORD=pw python3 $here/lib/delegate-wake --url $URL ses_auth >/dev/null 2>&1; rc=$?
check "\$OPENCODE_SERVER_PASSWORD authenticates as user opencode" "[ $rc = 0 ]"
printf 'pw\n' > $T/pwfile
DELEGATE_WAKE_PASSWORD_FILE=$T/pwfile python3 $here/lib/delegate-wake --url $URL ses_auth >/dev/null 2>&1; rc=$?
check "\$DELEGATE_WAKE_PASSWORD_FILE authenticates (trailing newline stripped)" "[ $rc = 0 ]"

n0=$(wc -l < $T/log)
start=$(date +%s)
DELEGATE_WAKE_PASSWORD=wrong python3 $here/lib/delegate-wake --url $URL ses_auth >/dev/null 2>&1; rc=$?
n1=$(wc -l < $T/log)
check "a rejected password exits 1 at once, without retries" "[ $rc = 1 ] && [ $((n1 - n0)) = 1 ] && [ $(( $(date +%s) - start )) -lt 2 ]"
python3 $here/lib/delegate-wake --url $URL ses_gone >/dev/null 2>&1; rc=$?
n2=$(wc -l < $T/log)
check "an unknown session exits 1 at once and never tries the v1 route" "[ $rc = 1 ] && [ $((n2 - n1)) = 1 ]"

python3 $here/lib/delegate-wake --url http://127.0.0.1:1 ses_test >/dev/null 2>&1; rc=$?
check "a dead server: exits 1 (the poll stays the fallback)" "[ $rc = 1 ]"
exit $fail
