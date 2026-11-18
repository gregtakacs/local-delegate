#!/bin/bash
# e2e-rig.sh — the shared installer e2e fixtures for O1b's acceptance tests. SOURCED, never run:
# test_profile_install.sh (step 5) and test_e2e_harness.sh (step 6) both load it so the stub
# harnesses, the stub OpenAI endpoint and the temp-HOME helpers exist in exactly one place.
#
# Contract for the sourcing test:
#   set `here` (the repo root) before sourcing, then call rig_init and wire an EXIT trap to
#   rig_cleanup. rig_init sets T (scratch + homes), BASE (the stub endpoint) and APIPID.
#   Helpers available after sourcing: mkhome/inst/doc/OCFG/SET/jq/PLUG.
# Everything is offline: no real $HOME is read, no docker, no real harness, no real model —
# installers run under a swapped HOME with the stub binaries first on PATH.
#
# The OpenAI stub answers like a tool caller (GET /models, non-stream and streamed tool_calls) so
# the installer's closing `doctor --quick` — and a full `delegate doctor` — can pass in the sandbox.

rig_init(){
  T=$(mktemp -d)
  mkdir -p "$T/stub"
  for b in opencode claude; do
    printf '#!/bin/sh\n[ "$1" = "--version" ] && echo 0.0.0-stub\nexit 0\n' > "$T/stub/$b"
    chmod +x "$T/stub/$b"
  done
  cat > "$T/stub-api.py" <<'RIGPY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
ARGS = json.dumps({"path": "hello.py", "content": "print(\"hi, \\\"probe\\\"\")"})
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if not self.path.endswith("/models"): self.send_response(404); self.end_headers(); return
        b = json.dumps({"object": "list",
                        "data": [{"id": "stub-model", "object": "model", "created": 1,
                                  "owned_by": "stub"}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        n = int(self.headers.get("content-length", 0) or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        if body.get("stream"):
            self.send_response(200); self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            def ev(d): self.wfile.write(b"data: " + json.dumps(d).encode() + b"\n\n")
            ev({"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "c", "type": "function",
                 "function": {"name": "write_file", "arguments": ARGS[:24]}}]}}]})
            ev({"choices": [{"delta": {"tool_calls": [{"index": 0,
                 "function": {"arguments": ARGS[24:]}}]}}]})
            self.wfile.write(b"data: [DONE]\n\n")
        else:
            b = json.dumps({"choices": [{"message": {"role": "assistant", "content": "",
                 "tool_calls": [{"id": "c", "type": "function",
                 "function": {"name": "write_file", "arguments": ARGS}}]}}]}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
s = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_port)); sys.stdout.flush()
s.serve_forever()
RIGPY
  python3 "$T/stub-api.py" "$T/port" & APIPID=$!
  for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
  BASE="http://127.0.0.1:$(cat "$T/port")/v1"
  printf 'stub-key\n' > "$T/key"; chmod 600 "$T/key"
}

rig_cleanup(){ [ -n "${APIPID:-}" ] && kill "$APIPID" 2>/dev/null; rm -rf "${T:-}"; }

# The worker's own DELEGATE_* exports win over config.env by design (bin/delegate line 20), so a
# test rig that means its own config has to clear them first.
CLEAN=(-u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME -u OPENCODE_CONFIG
       -u OPENCODE_PLUGINS_DIR -u OPENCODE_COMMANDS_DIR -u CLAUDE_SKILLS_DIR -u CLAUDE_AGENTS_DIR
       -u DELEGATE_MODEL -u DELEGATE_MODEL_HARD -u DELEGATE_BASE_URL -u DELEGATE_BASE_URLS
       -u DELEGATE_API_KEY_FILE -u DELEGATE_BASE_URLS_HARD -u DELEGATE_API_KEY_FILE_HARD -u DELEGATE_CHUNK_CAP -u DELEGATE_CONTEXT -u DELEGATE_RUNNER
       -u DELEGATE_EGRESS -u DELEGATE_WORKTREES -u DELEGATE_STATE -u DELEGATE_CACHE
       -u DELEGATE_OUTPUT -u DELEGATE_VISION -u DELEGATE_REASONING -u DELEGATE_IMAGE
       -u DELEGATE_IMAGE_STALE -u DELEGATE_IN_CONTAINER -u DELEGATE_TASK -u DELEGATE_WORKTREE
       -u DELEGATE_EVIDENCE_DIR -u DELEGATE_BIN_DIR -u DELEGATE_GRANTS_DIR -u DELEGATE_CHAIN_RC
       -u DELEGATE_CHAIN_STATUS -u DELEGATE_ON_DONE)

# A home, pre-seeded with a config pointing at the stub endpoint, as a real install would have.
mkhome(){ # mkhome DIR — the config exists before install.sh runs, so install keeps it verbatim
  mkdir -p "$1/.config/delegate"
  sed -e "s|^DELEGATE_BASE_URLS=.*|DELEGATE_BASE_URLS=\"$BASE\"|" \
      -e 's|^DELEGATE_MODEL=.*|DELEGATE_MODEL="stub-model"|' \
      -e 's|^DELEGATE_MODEL_HARD=.*|DELEGATE_MODEL_HARD="stub-model"|' \
      -e 's|^DELEGATE_RUNNER=.*|DELEGATE_RUNNER="native"|' \
      -e "s|^DELEGATE_API_KEY_FILE=.*|DELEGATE_API_KEY_FILE=\"$T/key\"|" \
      "$here/config.example.env" > "$1/.config/delegate/config.env"
}
inst(){ local h=$1; shift; env "${CLEAN[@]}" HOME="$h" PATH="$T/stub:$PATH" \
        XDG_CONFIG_HOME="$h/.config" CLAUDE_SKILLS_DIR="" OPENCODE_COMMANDS_DIR="" \
        "$here/install.sh" --no-build "$@"; }
doc(){ local h=$1; shift; env "${CLEAN[@]}" HOME="$h" PATH="$T/stub:$PATH" \
       XDG_CONFIG_HOME="$h/.config" "$here/bin/delegate" doctor "$@"; }
OCFG(){ printf '%s/.config/opencode/opencode.json' "$1"; }
SET(){ printf '%s/.claude/settings.json' "$1"; }
jq(){ python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$1" "$2"; }
PLUG(){ printf '%s/.config/opencode/plugins/%s.js' "$1" "$2"; }
