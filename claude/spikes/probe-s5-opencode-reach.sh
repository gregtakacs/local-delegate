#!/bin/bash
# probe-s5-opencode-reach.sh — spike S5 (docs/specs/o1b-design.md §6): the OpenCode rules-reach
# facts step 5's install relies on: (a) a *global* config `instructions` entry with the relative
# glob `.clinerules/*.md` resolves against the open project (different project => different file),
# (b) global instructions also reach a custom agent that defines its own `prompt` and the built-in
# explore subagent, and plugins load from the temp config dir; (c) whether a project's `.clinerules`
# is loaded with NO config entry at all (recorded either way; the answer sets the ruling).
# Runs `opencode run` headless against the worker's own self-hosted endpoint env
# (DELEGATE_BASE_URL / DELEGATE_MODEL / DELEGATE_API_KEY_FILE) with a temp XDG_CONFIG_HOME — the
# machine's real opencode config is never read or written. Prints one SPIKE line.
set -u
ID="S5"
usage() {
  printf 'usage: %s [--help | --commands]\n' "$(basename "$0")"
  printf '  runs spike %s, prints one "SPIKE %s: PASS|FAIL|NOT-RUN-HERE" line; exit 0 unless FAIL\n' "$ID" "$ID"
}
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --commands)
    cat <<'CMDS'
SPIKE S5 commands:
  # TMP = fresh mktemp -d; TMP/xdg/opencode/opencode.json points provider "delegate" at
  # $DELEGATE_BASE_URL (apiKey "{file:$DELEGATE_API_KEY_FILE}", read at request time — never printed)
  # and sets instructions [".clinerules/*.md"]; TMP/xdg/opencode/plugins/spike-log.js appends its
  # load line to $SPIKE5_LOG; projects TMP/projA/.clinerules/rule-a.md (word S5A-*) and
  # TMP/projB/.clinerules/rule-b.md (word S5B-*); global rules file TMP/global/rules.md (word S5G-*).
  cd TMP/projA && XDG_CONFIG_HOME=TMP/xdg opencode run -m delegate/$DELEGATE_MODEL "<no-tool code-word question>"           # expect S5A word
  cd TMP/projB && XDG_CONFIG_HOME=TMP/xdg opencode run -m delegate/$DELEGATE_MODEL "<no-tool code-word question>"           # expect S5B word (glob is per-project)
  # instructions=[.clinerules/*.md, TMP/global/rules.md]: expect BOTH S5A and S5G
  # add "agent":{"spike":{"prompt":"..."}}: expect the glob word still present
  cd TMP/projA && XDG_CONFIG_HOME=TMP/xdg opencode run -m delegate/$DELEGATE_MODEL --agent explore "<question>"             # expect S5A word
  cd TMP/projA && XDG_CONFIG_HOME=TMP/xdg opencode run -m delegate/$DELEGATE_MODEL --agent spike "<question>"               # custom agent, own prompt
  # instructions=[] with project .clinerules present: expect NO word (autoload finding, recorded)
CMDS
    exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

T="$(mktemp -d "${TMPDIR:-/tmp}/delegate-spike-$ID.XXXXXX")"
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
report() { printf 'SPIKE %s: %s — %s\n' "$ID" "$1" "$2"; [ "$1" = "FAIL" ] && exit 1; exit 0; }

command -v opencode >/dev/null 2>&1 || report NOT-RUN-HERE "opencode binary absent (command -v opencode)"
for v in DELEGATE_BASE_URL DELEGATE_MODEL DELEGATE_API_KEY_FILE; do
  [ -n "${!v:-}" ] || report NOT-RUN-HERE "env $v unset; the spike needs the worker's self-hosted endpoint config"
done
[ -r "$DELEGATE_API_KEY_FILE" ] || report NOT-RUN-HERE "DELEGATE_API_KEY_FILE not readable"
OVER="$(opencode --version 2>/dev/null | tail -1)"

MODEL="$DELEGATE_MODEL"
mkdir -p "$T/xdg/opencode/plugins" "$T/projA/.clinerules" "$T/projB/.clinerules" "$T/global"
WA="S5A-$$-${RANDOM}${RANDOM}"; WB="S5B-$$-${RANDOM}${RANDOM}"; WG="S5G-$$-${RANDOM}${RANDOM}"
printf 'The project code word is %s.\n' "$WA" > "$T/projA/.clinerules/rule-a.md"
printf 'The project code word is %s.\n' "$WB" > "$T/projB/.clinerules/rule-b.md"
printf 'The global code word is %s.\n' "$WG" > "$T/global/rules.md"
cat > "$T/xdg/opencode/plugins/spike-log.js" <<'JS'
import { appendFileSync } from "node:fs";
const log = process.env.SPIKE5_LOG || "";
export default async ({ directory }) => {
  if (log) appendFileSync(log, "load " + (directory || "") + "\n");
  return {};
};
JS
Q='Answer using ONLY your system context, without reading any file or running any tool. If your context states one or more code words, reply with exactly those code words separated by a comma. Otherwise reply exactly NO-CODE-WORD.'

mkcfg() { # $1 = JSON array of instructions entries; $2 = extra agent JSON object or empty
python3 - "$T" "$MODEL" "$1" "${2:-}" <<'PY'
import json,os,sys
T,model,instr,agent_extra=sys.argv[1],sys.argv[2],json.loads(sys.argv[3]),(json.loads(sys.argv[4]) if len(sys.argv)>4 and sys.argv[4] else {})
agents={"spike":{"description":"spike custom agent","mode":"primary",
  "prompt":"You are a terse spike assistant. Never mention code words yourself; only echo what your context states."}}
agents.update(agent_extra)
cfg={"$schema":"https://opencode.ai/config.json","autoupdate":False,"share":"disabled",
 "model":"delegate/"+model,"small_model":"delegate/"+model,
 "instructions":instr,"agent":agents,
 "permission":{"external_directory":{"*":"deny","/tmp/**":"allow",T+"/**":"allow"},
               "edit":{},"bash":"allow","webfetch":"allow","doom_loop":"allow"},
 "provider":{"delegate":{"npm":"@ai-sdk/openai-compatible","name":"spike",
   "options":{"baseURL":os.environ["DELEGATE_BASE_URL"].rstrip("/"),
              "apiKey":"{file:"+os.environ["DELEGATE_API_KEY_FILE"]+"}"},
   "models":{model:{"name":model,"limit":{"context":131072,"output":8192}}}}}}
json.dump(cfg,open(T+"/xdg/opencode/opencode.json","w"),indent=2)
PY
}
runoc() { # $1 = project dir, rest = extra opencode args -> sets ANSWER
  local out
  out="$(cd "$1" && SPIKE5_LOG="$T/plugin.log" XDG_CONFIG_HOME="$T/xdg" timeout 300 \
        opencode run -m "delegate/$MODEL" "${@:2}" "$Q" 2>/dev/null | tail -c 400 | tr -d '\n')" || true
  ANSWER="${out:-}"
}
has() { printf '%s' "$ANSWER" | grep -qF -- "$1" && echo yes || echo no; }

GLOB='[".clinerules/*.md"]'
mkcfg "$GLOB"
runoc "$T/projA"; a1=$(has "$WA"); notG=$(has "$WG")
runoc "$T/projB"; a2=$(has "$WB"); notA=$(has "$WA")
mkcfg "[\".clinerules/*.md\",\"$T/global/rules.md\"]"
runoc "$T/projA"; bb=$(has "$WA"); bg=$(has "$WG")
runoc "$T/projA" --agent spike; ag=$(has "$WA")
runoc "$T/projA" --agent explore; ex=$(has "$WA")
mkcfg '[]'
runoc "$T/projA"; cword=$(has "$WA")
plg=FAIL; [ -s "$T/plugin.log" ] && grep -q '^load ' "$T/plugin.log" && plg=PASS

# the no-tool guard must not leak: with instructions=[] the words are unreachable by context
guard=PASS; [ "$cword" = no ] || guard=LEAK
ok=yes
for x in "$a1" "$a2" "$bb" "$bg" "$ag" "$ex"; do [ "$x" = yes ] || ok=no; done
[ "$notG$notA" = nono ] || ok=no   # per-project isolation
autoload="no"; [ "$cword" = yes ] && autoload="yes"
ev="opencode=$OVER; glob-per-project=A:$a1/B:$a2 isolation:$([ "$notG$notA" = nono ] && echo ok || echo broken); global-entry=$bb+$bg; custom-agent=$ag explore-subagent=$ex; clinerules-autoload=$autoload; plugin-load=$plg; guard=$guard"
[ "$ok" = yes ] && [ "$guard" = PASS ] && report PASS "$ev"
report FAIL "$ev"
