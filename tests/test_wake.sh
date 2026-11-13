#!/bin/bash
# delegate-wake: builds the fixed-template prompt from the hook env, POSTs it to
# /session/<id>/prompt_async, exits 0 on 204; a dead server exits 1 (never hangs forever).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

python3 - "$T" <<'P' &
import http.server, json, sys
t = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        open(t + "/req", "w").write(self.path + "\n" + self.rfile.read(int(self.headers["Content-Length"])).decode())
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(t + "/port", "w").write(str(srv.server_address[1]))
for _ in range(2):
    srv.handle_request()
P
fake=$!; for _ in $(seq 50); do [ -f $T/port ] && break; sleep 0.1; done
URL=http://127.0.0.1:$(cat $T/port)

DELEGATE_CHAIN=hookdemo DELEGATE_CHAIN_STEP=demo-1 DELEGATE_CHAIN_STEP_N=1 DELEGATE_CHAIN_STEP_TOTAL=2 \
DELEGATE_CHAIN_STEP_STATUS=done DELEGATE_CHAIN_STATUS="demo-1=done, demo-2=running" \
  python3 $here/lib/delegate-wake --url $URL ses_test >/dev/null 2>&1; rc=$?
check "on-step wake posts 204 and exits 0" "[ $rc = 0 ] && [ \"\$(head -1 $T/req)\" = /session/ses_test/prompt_async ]"
grep -q "demo-1" $T/req && grep -q "still running" $T/req
check "the step message carries the step and says the chain runs on" "[ $? = 0 ]"

DELEGATE_CHAIN=hookdemo DELEGATE_CHAIN_RC=3 DELEGATE_CHAIN_STATUS="demo-1=blocked" DELEGATE_CHAIN_PLAN=/x/PLAN.json \
  python3 $here/lib/delegate-wake --url $URL ses_test >/dev/null 2>&1
python3 - "$T/req" <<'P'
import json, sys
body = json.loads("\n".join(open(sys.argv[1]).read().splitlines()[1:]))
t = body["parts"][0]["text"]
assert "ENDED" in t and "BLOCKED" in t and "delegate chain /x/PLAN.json" in t, t
P
check "the done wake carries the verdict and the resume command" "[ $? = 0 ]"

python3 $here/lib/delegate-wake --url http://127.0.0.1:1 ses_test >/dev/null 2>&1; rc=$?
check "a dead server: exits 1 (the poll stays the fallback)" "[ $rc = 1 ]"
wait $fake 2>/dev/null
exit $fail
