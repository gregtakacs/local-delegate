#!/bin/bash
# An endpoint and a key per level: DELEGATE_BASE_URLS_HARD and DELEGATE_API_KEY_FILE_HARD, each
# defaulting to the normal level's. A --hard task (or a chain step with "hard": true) uses them
# for pick_base_url, the key its worker gets, every later round, exec and verify, and its ledger
# row's endpoint; the egress allowlist holds both levels' hosts; doctor probes both when they
# differ. Two stub endpoints that each answer only their own key, a stub opencode (native
# runner), a stub docker that logs its argv. No network beyond 127.0.0.1, no real model, no real
# docker; HOME, XDG_*, the config and the umask are this suite's own.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
umask 022
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
mkdir -p "$T/home" "$T/bin" "$T/keys" "$T/state" "$T/wt" "$T/logs"

# ------------------------------------------------------------------ the rig ------------
# stub-api.py PORTFILE LOG KEY: /models answers 200 only to `Bearer KEY` (401 otherwise); a POST
# answers like a tool caller (what probe.py wants). Each request is logged as "METHOD PATH
# auth=ok|bad model=M" — never the key itself.
cat > "$T/stub-api.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port_file, log, key = sys.argv[1:4]
ARGS = json.dumps({"path": "hello.py", "content": "print(\"hi, \\\"probe\\\"\")"})
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _auth(self): return self.headers.get("Authorization") == "Bearer " + key
    def _log(self, model=""):
        with open(log, "a") as f:
            f.write(f"{self.command} {self.path} auth={'ok' if self._auth() else 'bad'} model={model}\n")
    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        self._log()
        if not self._auth(): return self._json(401, {"error": "bad key"})
        self._json(200, {"object": "list", "data": [{"id": "m", "object": "model"}]})
    def do_POST(self):
        n = int(self.headers.get("content-length", 0) or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        self._log(body.get("model", ""))
        if not self._auth(): return self._json(401, {"error": "bad key"})
        if body.get("stream"):
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            def ev(d): self.wfile.write(b"data: " + json.dumps(d).encode() + b"\n\n")
            ev({"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "c", "type": "function",
                 "function": {"name": "write_file", "arguments": ARGS}}]}}]})
            self.wfile.write(b"data: [DONE]\n\n")
        else:
            self._json(200, {"choices": [{"message": {"role": "assistant", "content": "",
                 "tool_calls": [{"id": "c", "type": "function",
                 "function": {"name": "write_file", "arguments": ARGS}}]}}]})
s = HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_port))
s.serve_forever()
PY
start_api() { # NAME KEY -> sets URL_<NAME>
  python3 -I "$T/stub-api.py" "$T/$1.port" "$T/logs/$1.log" "$2" & PIDS+=($!)
  local i; for i in $(seq 50); do [ -s "$T/$1.port" ] && break; sleep 0.1; done
  printf -v "URL_$1" 'http://127.0.0.1:%s/v1' "$(cat "$T/$1.port")"
}
start_api N normal-key; start_api H hard-key
printf 'normal-key\n' > "$T/keys/normal"; printf 'hard-key\n' > "$T/keys/hard"
chmod 600 "$T/keys/normal" "$T/keys/hard"

# A stub opencode: `run` records which endpoint and key file the rendered config gives the
# worker, and does nothing else; `--version` answers.
cat > "$T/bin/opencode" <<'SH'
#!/bin/bash
[ "${1:-}" = --version ] && { echo 2.0.0-stub; exit 0; }
[ "${1:-}" = run ] || exit 0
python3 -I -c '
import json, os, sys
c = json.load(open(os.path.join(os.environ["XDG_CONFIG_HOME"], "opencode", "opencode.json")))
p = c["provider"]["delegate"]["options"]
print("baseURL=" + p["baseURL"]); print("apiKey=" + p["apiKey"])' >> "$STUB_OPENCODE_LOG"
exit 0
SH
chmod +x "$T/bin/opencode"
export STUB_OPENCODE_LOG=$T/logs/opencode.log

# The environment every case starts from: nothing inherited but PATH's system dirs.
base_env=(HOME="$T/home" PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"
  XDG_CONFIG_HOME="$T/home/.config" XDG_STATE_HOME="$T/home/.local/state"
  XDG_CACHE_HOME="$T/home/.cache" XDG_DATA_HOME="$T/home/.local/share"
  DELEGATE_CONFIG="$T/config.env" DELEGATE_STATE="$T/state" DELEGATE_WORKTREES="$T/wt"
  DELEGATE_CACHE="$T/cache" DELEGATE_GRANTS_DIR="$T/grants" DELEGATE_LEDGER="$T/ledger.jsonl"
  DELEGATE_PROGRESS=0 DELEGATE_PRUNE_DAYS=0 DELEGATE_PROBE_TIMEOUT=2 DELEGATE_RUNNER=native
  DELEGATE_EGRESS=open STUB_OPENCODE_LOG="$STUB_OPENCODE_LOG")
D() { env -i "${base_env[@]}" "$@"; }
dl() { D "${cfg[@]}" "$here/bin/delegate" "$@"; }

# A repo to delegate in, and a spec.
R=$T/src/app; mkdir -p "$R"
git -C "$R" init -q -b main
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
printf '# Task\nDo nothing.\n' > "$T/spec.md"

# ------------------------------------------------- 1. defaults are unchanged -----------
fn_cfg=$(sed -n '/^: "\${DELEGATE_BASE_URLS:=/,/^: "\${DELEGATE_API_KEY_FILE_HARD:=/p' "$here/bin/delegate")
check "the hard keys are defined beside the normal ones" '[ -n "$fn_cfg" ]'
defaults() { env -i HOME="$T/home" PATH=/usr/bin:/bin "$@" bash -c "$fn_cfg"'
printf "%s|%s\n" "$DELEGATE_BASE_URLS_HARD" "$DELEGATE_API_KEY_FILE_HARD"'; }
check "unset: the hard level is the normal level" \
  '[ "$(defaults DELEGATE_BASE_URLS="http://a/v1 http://b/v1" DELEGATE_API_KEY_FILE=/k/n)" = "http://a/v1 http://b/v1|/k/n" ]'
check "set: the hard level is its own" \
  '[ "$(defaults DELEGATE_BASE_URLS=http://a/v1 DELEGATE_API_KEY_FILE=/k/n DELEGATE_BASE_URLS_HARD=http://h/v1 DELEGATE_API_KEY_FILE_HARD=/k/h)" = "http://h/v1|/k/h" ]'
check "the key file default is the normal key file's path" \
  '[ "$(defaults)" = "|$T/home/.config/delegate/api-key" ]'
check "the hard key file is ~-expanded like the normal one" \
  'grep -qF '"'"'DELEGATE_API_KEY_FILE_HARD=$(expand "$DELEGATE_API_KEY_FILE_HARD")'"'"' "$here/bin/delegate"'

# ------------------------------------- 2. the egress allowlist holds both hosts --------
uh=$(sed -n '/^url_hosts() {/p' "$here/bin/delegate")
hosts() { env -i PATH=/usr/bin:/bin "$@" bash -c "$uh"'
url_hosts | tr "\n" " "'; }
check "egress: both levels' hosts, each once" \
  '[ "$(hosts DELEGATE_BASE_URLS="https://lan.example:8000/v1 https://pub.example/v1" DELEGATE_BASE_URLS_HARD="https://hard.example/v1 https://pub.example/v1")" = "hard.example lan.example pub.example " ]'
check "egress: one level configured, its hosts as before" \
  '[ "$(hosts DELEGATE_BASE_URLS=https://lan.example/v1 DELEGATE_BASE_URLS_HARD=https://lan.example/v1)" = "lan.example " ]'

# the shared proxy, as delegate really starts it, through a stub docker that logs its argv
cat > "$T/bin/docker" <<'SH'
#!/bin/bash
{ printf docker; printf ' %q' "$@"; printf '\n'; } >> "$STUB_DOCKER_LOG"
exit 0
SH
chmod +x "$T/bin/docker"
eg=$(sed -n '/^ensure_egress() {/,/^}/p; /^url_hosts() {/p; /^host_args() {/,/^}/p' "$here/bin/delegate")
D DELEGATE_BASE_URLS="http://normal.invalid/v1" DELEGATE_BASE_URLS_HARD="http://hard.invalid/v1" \
  STUB_DOCKER_LOG="$T/logs/docker-egress.log" DELEGATE_EGRESS_IMAGE=egress:t EGRESS_NAME=delegate-egress \
  bash -c 'die(){ echo "$*" >&2; exit 1; }; warn(){ :; }; grant_net(){ echo filtered; }
'"$eg"'
ensure_egress' 2>"$T/logs/egress.err"
check "egress: the proxy is started allowing both levels' hosts" \
  "grep -qF 'DELEGATE_ALLOW_HOSTS=hard.invalid\ normal.invalid' '$T/logs/docker-egress.log'"

# --------------------------------------- 3. a normal task and a hard task, end to end ---
cfg=(DELEGATE_BASE_URLS="$URL_N" DELEGATE_API_KEY_FILE="$T/keys/normal"
     DELEGATE_BASE_URLS_HARD="$URL_H" DELEGATE_API_KEY_FILE_HARD="$T/keys/hard"
     DELEGATE_MODEL=m-normal DELEGATE_MODEL_HARD=m-hard)
: > "$T/logs/N.log"; : > "$T/logs/H.log"; : > "$STUB_OPENCODE_LOG"
dl run "$T/spec.md" --repo "$R" --name lvl-normal > "$T/logs/run-normal.out" 2>&1; rc=$?
check "a normal task runs (exit 0)" '[ "$rc" = 0 ] || { tail -5 "$T/logs/run-normal.out"; false; }'
check "normal: pick_base_url asked the normal endpoint with the normal key" \
  'grep -q "^GET /v1/models auth=ok" "$T/logs/N.log"'
check "normal: the hard endpoint was never asked" '[ ! -s "$T/logs/H.log" ]'
check "normal: the worker got the normal endpoint and key file" \
  '[ "$(cat "$STUB_OPENCODE_LOG")" = "$(printf "baseURL=%s\napiKey={file:%s}" "$URL_N" "$T/keys/normal")" ]'

: > "$T/logs/N.log"; : > "$T/logs/H.log"; : > "$STUB_OPENCODE_LOG"
dl run "$T/spec.md" --repo "$R" --name lvl-hard --hard > "$T/logs/run-hard.out" 2>&1; rc=$?
check "a hard task runs (exit 0)" '[ "$rc" = 0 ] || { tail -5 "$T/logs/run-hard.out"; false; }'
check "hard: pick_base_url asked the hard endpoint with the hard key" \
  'grep -q "^GET /v1/models auth=ok" "$T/logs/H.log"'
check "hard: the normal endpoint was never asked" '[ ! -s "$T/logs/N.log" ]'
check "hard: the worker got the hard endpoint and key file" \
  '[ "$(cat "$STUB_OPENCODE_LOG")" = "$(printf "baseURL=%s\napiKey={file:%s}" "$URL_H" "$T/keys/hard")" ]'

# a later round of the hard task, without --hard: the recorded level holds
: > "$T/logs/N.log"; : > "$T/logs/H.log"; : > "$STUB_OPENCODE_LOG"
tid=$(ls "$T/state" | grep -- 'lvl-hard$')
dl continue "$tid" -m "again" > "$T/logs/cont-hard.out" 2>&1; rc=$?
check "continue on the hard task (no --hard) runs (exit 0)" '[ "$rc" = 0 ] || { tail -5 "$T/logs/cont-hard.out"; false; }'
check "continue: the hard endpoint and key again, never the normal one" \
  'grep -q "^GET /v1/models auth=ok" "$T/logs/H.log" && [ ! -s "$T/logs/N.log" ] \
   && grep -qx "baseURL=$URL_H" "$STUB_OPENCODE_LOG" && grep -qx "apiKey={file:$T/keys/hard}" "$STUB_OPENCODE_LOG"'

# exec and verify of the hard task: the worker env is the hard level's (no endpoint probe)
check "exec of the hard task sees the hard level (BASE_URL, key file)" \
  "grep -q '^cmd_exec() {' '$here/bin/delegate' && sed -n '/^cmd_exec() {/,/^}/p' '$here/bin/delegate' | grep -qF 'BASE_URL=\${LVL_URLS%% *}'"
check "verify of the hard task sees the hard level" \
  "sed -n '/^cmd_verify() {/,/^}/p' '$here/bin/delegate' | grep -qF 'BASE_URL=\${LVL_URLS%% *}'"
check "load_task sets the level from the task's recorded EFFORT" \
  "sed -n '/^load_task() {/,/^}/p' '$here/bin/delegate' | grep -qF 'set_level \"\${EFFORT:-normal}\"'"
check "the docker worker mounts the level's key, never the normal key by name" \
  "grep -qF -- '-v \"\$KEY_FILE:/run/secrets/delegate_key:ro\"' '$here/bin/delegate' && ! grep -qF -- '-v \"\$DELEGATE_API_KEY_FILE:/run/secrets' '$here/bin/delegate'"
out=$(dl exec "$tid" -- 'printf "%s\n" "$DELEGATE_TASK"' 2>&1); rc=$?
check "exec of the hard task runs" '[ "$rc" = 0 ] && [ "$out" = "$tid" ]'
rm -f "$T/state/$tid/home/.config/opencode/opencode.json"
dl exec "$tid" -- true >/dev/null 2>&1
check "exec: the worker's rendered config is the hard level's" "python3 -I - '$T/state/$tid/home/.config/opencode/opencode.json' '$URL_H' '$T/keys/hard' <<'PY'
import json, sys
o = json.load(open(sys.argv[1]))['provider']['delegate']['options']
assert (o['baseURL'], o['apiKey']) == (sys.argv[2], '{file:' + sys.argv[3] + '}'), o
PY"
rm -f "$T/state/$tid/home/.config/opencode/opencode.json"
dl verify "$tid" true >/dev/null 2>&1; rc=$?
check "verify: exit 0, and the worker's rendered config is the hard level's" "[ \$rc = 0 ] && grep -qF '$URL_H' '$T/state/$tid/home/.config/opencode/opencode.json'"

# the ledger: each round row's endpoint is the URL that round used
check "ledger: the rows' endpoints are the levels' URLs" "python3 -I - '$T/ledger.jsonl' '$URL_N' '$URL_H' <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
r = [(x['slug'], x['round'], x['effort'], x['endpoint']) for x in rows if x['kind'] == 'round']
want = [('lvl-normal', 1, 'normal', sys.argv[2]), ('lvl-hard', 1, 'hard', sys.argv[3]),
        ('lvl-hard', 2, 'hard', sys.argv[3])]
assert r == want, r
PY"

# the round row names its launch (lib/launch.py): a run started from a Claude Code style wrapper
{ printf 'exec env -i'; printf ' %q' "${base_env[@]}" "${cfg[@]}" "$here/bin/delegate" run "$T/spec.md" --repo "$R" --name lvl-launch; printf '\n'; } > "$T/run-launch.sh"
LC="bash $T/run-launch.sh"
bash -c "true && eval '$LC' && true" > "$T/logs/run-launch.out" 2>&1; rc=$?
check "a run launched from a tool-call wrapper: its round row carries that command's sha256" \
  "[ \$rc = 0 ] && python3 -I - '$T/ledger.jsonl' \$(printf %s '$LC' | sha256sum | cut -c1-64) <<'PY'
import json, sys
r = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
r = [x for x in r if x['kind'] == 'round' and x['slug'] == 'lvl-launch']
assert len(r) == 1 and r[0]['launch_sha256'] == sys.argv[2] and r[0]['schema'] == 4, r
PY"

# a chain step with "xhigh": true (since 0.9.11 "hard" alone sets the gate, not the model): the hard level, and every round of it carries the chain's launch
mkdir -p "$T/plan"; cp "$T/spec.md" "$T/plan/spec.md"
printf '{"name": "lvlchain", "repo": "%s", "base": "main", "retries": 1,
 "steps": [{"name": "lvl-chain", "spec": "spec.md", "verify": "true", "hard": true, "xhigh": true}]}\n' "$R" > "$T/plan/plan.json"
{ printf 'exec env -i'; printf ' %q' "${base_env[@]}" "${cfg[@]}" "$here/bin/delegate" chain "$T/plan/plan.json"; printf '\n'; } > "$T/chain-launch.sh"
CC="bash $T/chain-launch.sh"
: > "$T/logs/N.log"; : > "$T/logs/H.log"
timeout 300 bash -c "true && eval '$CC' && true" > "$T/logs/chain.out" 2>&1
check "a chain's hard step: every round on the hard endpoint, each carrying the chain's launch" \
  "[ ! -s '$T/logs/N.log' ] && python3 -I - '$T/ledger.jsonl' '$URL_H' \$(printf %s '$CC' | sha256sum | cut -c1-64) <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
r = [x for x in rows if x['kind'] == 'round' and x['slug'] == 'lvl-chain']
c = [x for x in rows if x['kind'] == 'chain' and x['chain'] == 'lvlchain']
assert len(r) >= 2, r                     # the stub worker never says done: the step retried
assert all(x['endpoint'] == sys.argv[2] and x['effort'] == 'hard' for x in r), r
assert all(x['launch_sha256'] == sys.argv[3] for x in r), [x['launch_sha256'] for x in r]
assert len(c) == 1 and c[0]['schema'] == 2 and c[0]['launch_sha256'] == sys.argv[3], c
PY"

# --------------------------------------- 4. an unreadable or missing hard key -----------
: > "$T/logs/N.log"; : > "$T/logs/H.log"
miss=(DELEGATE_API_KEY_FILE_HARD="$T/keys/nope")
out=$(D "${cfg[@]}" "${miss[@]}" "$here/bin/delegate" run "$T/spec.md" --repo "$R" --name miss-h --hard 2>&1); rc=$?
check "a missing hard key file: --hard is refused, naming the file and the setting" \
  '[ "$rc" != 0 ] && printf %s "$out" | grep -qF "API key file not readable: $T/keys/nope (DELEGATE_API_KEY_FILE_HARD"'
check "the refusal comes before any endpoint is asked" '[ ! -s "$T/logs/H.log" ] && [ ! -s "$T/logs/N.log" ]'
check "the refusal leaves no task behind" '! ls "$T/state" | grep -q "miss-h$"'
cp "$T/keys/hard" "$T/keys/locked"; chmod 000 "$T/keys/locked"
if [ -r "$T/keys/locked" ]; then
  echo "ok   an unreadable hard key file (skipped: running as root, every file is readable)"
else
  out=$(D "${cfg[@]}" DELEGATE_API_KEY_FILE_HARD="$T/keys/locked" "$here/bin/delegate" run "$T/spec.md" --repo "$R" --name lock-h --hard 2>&1); rc=$?
  check "an unreadable hard key file: --hard is refused the same way" \
    '[ "$rc" != 0 ] && printf %s "$out" | grep -qF "API key file not readable: $T/keys/locked (DELEGATE_API_KEY_FILE_HARD"'
fi
out=$(D "${cfg[@]}" "${miss[@]}" "$here/bin/delegate" run "$T/spec.md" --repo "$R" --name miss-n 2>&1); rc=$?
check "a missing hard key file does not stop a normal task" '[ "$rc" = 0 ] || { printf "%s\n" "$out" | tail -3; false; }'
out=$(D "${cfg[@]}" DELEGATE_API_KEY_FILE="$T/keys/nope" "$here/bin/delegate" run "$T/spec.md" --repo "$R" --name miss-nn 2>&1); rc=$?
check "the normal key's refusal is unchanged" \
  '[ "$rc" != 0 ] && printf %s "$out" | grep -qF "API key file not readable: $T/keys/nope"'
out=$(D "${cfg[@]}" DELEGATE_API_KEY_FILE_HARD="$T/keys/normal" "$here/bin/delegate" run "$T/spec.md" --repo "$R" --name wrong-h --hard 2>&1); rc=$?
check "a hard key the hard endpoint refuses: no endpoint, refused" \
  '[ "$rc" != 0 ] && printf %s "$out" | grep -qF "no endpoint in DELEGATE_BASE_URLS_HARD answered /models"'

# ---------------------------------------------------------------- 5. doctor -------------
: > "$T/logs/N.log"; : > "$T/logs/H.log"
out=$(dl doctor --quick 2>&1)
check "doctor (levels differ): the normal endpoint and the hard one are both named" \
  'printf %s "$out" | grep -qx "endpoint: $URL_N" && printf %s "$out" | grep -qx "endpoint (hard): $URL_H"'
check "doctor: the hard model was probed at the hard endpoint with the hard key" \
  'grep -q "^POST /v1/chat/completions auth=ok model=m-hard" "$T/logs/H.log"'
check "doctor: the normal model was probed at the normal endpoint, the hard model was not" \
  'grep -q "^POST /v1/chat/completions auth=ok model=m-normal" "$T/logs/N.log" && ! grep -q "model=m-hard" "$T/logs/N.log"'
: > "$T/logs/N.log"; : > "$T/logs/H.log"
out=$(D DELEGATE_BASE_URLS="$URL_N" DELEGATE_API_KEY_FILE="$T/keys/normal" DELEGATE_MODEL=m-normal \
      DELEGATE_MODEL_HARD=m-hard "$here/bin/delegate" doctor --quick 2>&1)
check "doctor (one level): no hard endpoint line, the hard model probed at the one endpoint" \
  '! printf %s "$out" | grep -q "endpoint (hard)" && grep -q "model=m-hard" "$T/logs/N.log" && [ ! -s "$T/logs/H.log" ]'
out=$(D "${cfg[@]}" DELEGATE_API_KEY_FILE_HARD="$T/keys/nope" "$here/bin/delegate" doctor --quick 2>&1); rc=$?
check "doctor: a missing hard key is a problem, named" \
  '[ "$rc" != 0 ] && printf %s "$out" | grep -qF "endpoint (hard): API key file not readable: $T/keys/nope" && printf %s "$out" | grep -q "PROBLEMS FOUND"'

# ---------------------------------------------------------- 6. install.sh flags ---------
IH=$T/ihome; mkdir -p "$IH"
env -i HOME="$IH" PATH="$T/bin:/usr/local/bin:/usr/bin:/bin" XDG_CONFIG_HOME="$IH/.config" \
  CLAUDE_SKILLS_DIR="" OPENCODE_COMMANDS_DIR="" DELEGATE_BIN_DIR="$IH/bin" \
  "$here/install.sh" --no-build --no-claude-profile --runner native --base-url "$URL_N" --model m-normal \
  --key-file "$T/keys/normal" --base-url-hard "$URL_H" --key-file-hard "$T/keys/hard" > "$T/logs/install.out" 2>&1
ic=$IH/.config/delegate/config.env
check "install.sh --base-url-hard / --key-file-hard write their keys" \
  "grep -qx 'DELEGATE_BASE_URLS_HARD=\"$URL_H\"' '$ic' && grep -qx 'DELEGATE_API_KEY_FILE_HARD=\"$T/keys/hard\"' '$ic'"
check "install.sh: the normal ones as before" \
  "grep -qx 'DELEGATE_BASE_URLS=\"$URL_N\"' '$ic' && grep -qx 'DELEGATE_API_KEY_FILE=\"$T/keys/normal\"' '$ic'"
IH2=$T/ihome2; mkdir -p "$IH2"
env -i HOME="$IH2" PATH="$T/bin:/usr/local/bin:/usr/bin:/bin" XDG_CONFIG_HOME="$IH2/.config" \
  CLAUDE_SKILLS_DIR="" OPENCODE_COMMANDS_DIR="" DELEGATE_BIN_DIR="$IH2/bin" \
  "$here/install.sh" --no-build --no-claude-profile --runner native --base-url "$URL_N" --model m-normal \
  --key-file "$T/keys/normal" > "$T/logs/install2.out" 2>&1
check "install.sh without them: the hard keys stay commented out (they default)" \
  "! grep -q '^DELEGATE_BASE_URLS_HARD=\|^DELEGATE_API_KEY_FILE_HARD=' '$IH2/.config/delegate/config.env'"
check "install.sh --help names both flags" \
  "'$here/install.sh' --help | grep -q -- '--base-url-hard URL' && '$here/install.sh' --help | grep -q -- '--key-file-hard PATH'"

if [ "$fail" = 0 ]; then echo "PASS test_endpoint_levels"; else echo "FAIL test_endpoint_levels"; fi
exit $fail
