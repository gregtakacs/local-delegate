#!/bin/bash
# merge-opencode-permissions.py: the orchestrator-side permission merge. delegate's skill is
# only usable from opencode if the config allows loading it, so install.sh merges the entries.
# Contract: create-or-merge, never overwrite a value the user set, refuse (unchanged) on
# invalid JSON, idempotent, --check verifies without writing.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
M=$here/lib/merge-opencode-permissions.py
cfg=$T/opencode.json
args() { python3 "$M" --config "$cfg" --skill-dir "$T/skills/delegate" --real-dir "$here/claude/skills/delegate" "$@"; }

# fresh: no config at all
check "fresh run succeeds" "args >/dev/null"
check "config created" "[ -f '$cfg' ]"
check "skill.delegate allow present" \
  "python3 -c \"import json;d=json.load(open('\$cfg'));assert d['permission']['skill']['delegate']=='allow'\""
check "both skill dirs allowed" \
  "python3 -c \"import json;d=json.load(open('\$cfg'));e=d['permission']['external_directory'];assert e['\$T/skills/delegate/**']=='allow';assert e['$here/claude/skills/delegate/**']=='allow'\""

# idempotent: a second run changes nothing, byte for byte
cp "$cfg" "$cfg.first"; check "second run no-op" "args >/dev/null && cmp -s '$cfg' '$cfg.first'"

# merge preserves user content and user decisions
python3 - "$cfg" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["model"] = "keep/me"; d["permission"]["skill"]["delegate"] = "ask"
d["permission"].setdefault("bash", {})["*"] = "allow"
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF
out=$(args 2>&1); rc=$?
check "merge with user values succeeds" "[ $rc -eq 0 ]"
check "user value not overwritten" "python3 -c \"import json;d=json.load(open('\$cfg'));assert d['permission']['skill']['delegate']=='ask';assert d['model']=='keep/me';assert d['permission']['bash']['*']=='allow'\""
check "kept-value reported" "printf %s \"\$out\" | grep -q 'kept'"

# invalid json: refuse, file untouched
echo '{oops' > "$cfg"
check "invalid json refused" "! args >/dev/null 2>&1"
check "invalid json untouched" "cmp -s '$cfg' <(echo '{oops')"

# --check: ok after a real merge, non-zero when entries are missing or config absent
echo '{}' > "$cfg"; args >/dev/null
check "--check ok" "args --check >/dev/null 2>&1"
rm "$cfg"; echo '{}' > "$cfg"
check "--check fails on missing entries" "! args --check >/dev/null 2>&1"
check "--check says the fix" "args --check 2>&1 | grep -q install.sh"
rm "$cfg"
check "--check fails on absent config" "! args --check >/dev/null 2>&1"

# coverage: a broader rule that already allows the skill dirs counts (opencode: last match wins)
cov() {  # cov NAME EXPECT(ok|missing) JSON-of-external_directory
  printf '{"permission":{"skill":{"delegate":"allow"},"external_directory":%s}}\n' "$3" > "$cfg"
  if [ "$2" = ok ]; then check "coverage: $1" "args --check >/dev/null 2>&1"
  else check "coverage: $1" "! args --check >/dev/null 2>&1"; fi
}
cov "broad parent allow" ok "{\"*\":\"ask\",\"$T/**\":\"allow\",\"$here/**\":\"allow\"}"
cov "star allow" ok '{"*":"allow"}'
cov "broad allow, later specific ask" missing "{\"$T/**\":\"allow\",\"$here/**\":\"allow\",\"$T/skills/**\":\"ask\"}"
cov "broad allow, then star ask last" missing "{\"$T/**\":\"allow\",\"$here/**\":\"allow\",\"*\":\"ask\"}"
cov "only one dir covered" missing "{\"*\":\"ask\",\"$T/**\":\"allow\"}"
cov "sibling prefix is not coverage" missing "{\"*\":\"ask\",\"$T/skills/delegatex/**\":\"allow\",\"$here/**\":\"allow\"}"
cov "deny" missing "{\"$T/**\":\"deny\",\"$here/**\":\"allow\"}"
# merge: covered dirs get no redundant literal entries; uncovered ones still do
printf '{"permission":{"external_directory":{"*":"ask","%s/**":"allow"}}}\n' "$T" > "$cfg"
args >/dev/null
check "merge skips a covered dir" "python3 -c \"import json;e=json.load(open('\$cfg'))['permission']['external_directory'];assert '\$T/skills/delegate/**' not in e\""
check "merge adds an uncovered dir" "python3 -c \"import json;e=json.load(open('\$cfg'))['permission']['external_directory'];assert e['$here/claude/skills/delegate/**']=='allow'\""
# The default --config path, XDG_CONFIG_HOME unset (a container): ~/.config/opencode, never ~/opencode.
DH="$T/defhome"; mkdir -p "$DH"
env -u XDG_CONFIG_HOME HOME="$DH" python3 "$M" --skill-dir "$T/skills/delegate" --real-dir "$here/claude/skills/delegate" >/dev/null 2>&1
check "default config path is ~/.config/opencode/opencode.json" "[ -f '$DH/.config/opencode/opencode.json' ] && [ ! -e '$DH/opencode' ]"
# a user's catch-all that differs from a non-deny policy row stays the user's: kept on install,
# never recorded as ours, so a later install (from any tree) never rewrites it
PC="$T/polcfg.json"
printf '{"permission":{"bash":{"*":"allow"},"webfetch":{"*":"allow"}}}\n' > "$PC"
pol() { python3 "$M" --config "$PC" --skill-dir "$T/skills/delegate" --real-dir "$here/claude/skills/delegate" --permission-policy "$here/policy/harness-permissions.json" --render "$@"; }
pol >/dev/null 2>&1
check "policy: user's bash catch-all kept on install" "python3 -c \"import json;d=json.load(open('$PC'));assert d['permission']['bash']['*']=='allow'\""
check "policy: user's catch-alls not recorded as ours" "python3 -c \"import json;r=json.load(open('$PC'))['_delegate']['permissions'];assert ['bash','*'] not in r and ['webfetch','*'] not in r, r\""
pol >/dev/null 2>&1
check "policy: ...and still kept on a re-run" "python3 -c \"import json;d=json.load(open('$PC'));assert d['permission']['bash']['*']=='allow' and d['permission']['webfetch']['*']=='allow'\""
check "policy: a policy deny row still landed" "python3 -c \"import json;d=json.load(open('$PC'));assert d['permission']['bash']['sudo *']=='deny'\""

exit $fail
