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
exit $fail
