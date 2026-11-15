#!/bin/bash
# O1b step 5: the profile installer and the doctor drift block, against temp HOMEs, stub
# harnesses and a stub OpenAI endpoint — the installer and the doctor must not need the real
# harnesses or a real model. The merge contract (design §8) end to end: fresh merge, byte-stable
# re-run, foreign keys kept, a hand-written hook adopted, uninstall that removes only ours,
# invalid JSON refused untouched; then the six §9 doctor lines, each broken once, with the
# --quick FAIL→WARN demotion. Release mode gets its own fixture tree so the plugin links can
# point through `current`. No real $HOME is ever read or written.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
APIPID=""
# The stub harnesses, the stub OpenAI endpoint and the temp-HOME helpers live in one shared rig
# (tests/e2e-rig.sh) that step 6's end-to-end test loads too, so the machinery exists once.
# shellcheck source=./e2e-rig.sh
. "$(dirname "$0")/e2e-rig.sh"
trap 'rig_cleanup' EXIT
rig_init

# ---- 1. a fresh install merges both harnesses ----
H="$T/h1"; mkhome "$H"
mkdir -p "$H/.claude"
printf '{"model":"opus","hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"python3 /usr/local/bin/foreign.py"}]}]}}\n' > "$H/.claude/settings.json"
out=$(inst "$H" --claude-permissions 2>&1); rc=$?
check "install exits 0" "[ $rc -eq 0 ]"
check "opencode: machine entry" "grep -q '\"delegate\": \"allow\"' '$(OCFG "$H")'"
check "opencode: core rules entry" "grep -q 'opencode/rules/harness-core.md' '$(OCFG "$H")'"
check "opencode: clinerules glob entry" "grep -q 'clinerules' '$(OCFG "$H")'"
check "opencode: a deny row landed" "grep -q 'sudo' '$(OCFG "$H")'"
check "opencode: marker" "grep -q '_delegate' '$(OCFG "$H")'"
check "opencode: \$schema kept" "grep -q 'opencode.ai/config.json' '$(OCFG "$H")'"
check "settings: unknown keys kept" "jq '$(SET "$H")' 'd[\"model\"]' | grep -q opus"
check "settings: foreign hook kept" "grep -q 'foreign.py' '$(SET "$H")'"
check "settings: harness hook in" "grep -q 'claude/hooks/harness.py' '$(SET "$H")'"
check "settings: marker" "grep -q '_delegate' '$(SET "$H")'"
check "rules file written" "[ -s '$H/.claude/rules/delegate-harness.md' ]"
check "rules sha recorded" "grep -q rules_sha256 '$(SET "$H")'"
check "four plugin links" "[ -L '$(PLUG "$H" chunk-cap)' ] && [ -L '$(PLUG "$H" notes-loop)' ] && [ -L '$(PLUG "$H" todo-loop)' ] && [ -L '$(PLUG "$H" verify-loop)' ]"
check "plugin links resolve into the tree" "readlink -f '$(PLUG "$H" chunk-cap)' | grep -qF '$here/'"
check "permissions merged on request" "jq '$(SET "$H")' 'len(d[\"permissions\"][\"deny\"])' | grep -qvE '^0$'"

# ---- 2. a re-run changes nothing, byte for byte ----
cp "$(OCFG "$H")" "$T/oc.1"; cp "$(SET "$H")" "$T/st.1"; cp "$H/.claude/rules/delegate-harness.md" "$T/rl.1"
inst "$H" --claude-permissions >/dev/null 2>&1 || true
check "re-run: opencode config byte-identical" "cmp -s '$(OCFG "$H")' '$T/oc.1'"
check "re-run: settings byte-identical" "cmp -s '$(SET "$H")' '$T/st.1'"
check "re-run: rules file byte-identical" "cmp -s '$H/.claude/rules/delegate-harness.md' '$T/rl.1'"
check "re-run: plugin links still point through the install tree" "[ \"\$(readlink '$(PLUG "$H" chunk-cap)')\" = '$here/opencode/plugins/chunk-cap.js' ]"

# ---- 3. doctor: the six §9 lines, and a clean exit ----
out=$(doc "$H"); rc=$?
check "doctor exits 0 on a fresh install" "[ $rc -eq 0 ]"
check "doctor: rules line" "printf %s \"\$out\" | grep -qE '^rules:  +ok'"
check "doctor: plugins line" "printf %s \"\$out\" | grep -qE '^plugins:  +ok'"
check "doctor: hooks line" "printf %s \"\$out\" | grep -qE '^hooks:  +ok'"
check "doctor: cap line" "printf %s \"\$out\" | grep -qE '^cap:  +ok'"
check "doctor: permissions line" "printf %s \"\$out\" | grep -qE '^permissions:  +ok'"
check "doctor: claude exempt line" "printf %s \"\$out\" | grep -qE '^claude exempt:  +ok'"
check "doctor: the block reports OK at the end" "printf %s \"\$out\" | grep -q 'doctor: OK'"

# ---- 4. one broken thing per case: the exact line and its fix ----
mv "$(PLUG "$H" todo-loop)" "$T/todo-loop.bak"
out=$(doc "$H"); rc=$?
check "drift: a missing plugin link FAILs" "[ $rc -eq 1 ] && printf %s \"\$out\" | grep -qE '^plugins:  +FAIL.*fix: re-run install.sh'"
check "drift: --quick prints WARN and still exits 0" "doc '$H' --quick >'$T/q.log' 2>&1 && grep -qE '^plugins:  +WARN' '$T/q.log'"
mv "$T/todo-loop.bak" "$(PLUG "$H" todo-loop)"
echo tam >> "$H/.claude/rules/delegate-harness.md"
out=$(doc "$H"); rc=$?
check "drift: an edited rules file FAILs the rules line" "[ $rc -eq 1 ] && printf %s \"\$out\" | grep -qE '^rules:  +FAIL.*fix: re-run install.sh'"
python3 - "$H" <<'PY'
import json, sys
p = sys.argv[1] + "/.claude/settings.json"
d = json.load(open(p))
d["permissions"]["deny"] = [x for x in d["permissions"]["deny"] if "sudo" not in x]
json.dump(d, open(p, "w"), indent=2)
PY
out=$(doc "$H"); rc=$?
check "drift: a missing deny row FAILs the permissions line" "[ $rc -eq 1 ] && printf %s \"\$out\" | grep -qE '^permissions:  +FAIL.*fix: re-run install.sh'"
inst "$H" --claude-permissions >"$T/re.log" 2>&1 || true
check "a re-run refuses to clobber the edited rules file" "grep -q 'claude profile not installed' '$T/re.log'"
rm "$H/.claude/rules/delegate-harness.md"
inst "$H" --claude-permissions >/dev/null 2>&1 || true
check "re-install repairs every break once the edited rules file is gone" "doc '$H' >/dev/null 2>&1"
python3 - "$H" <<'PY'
import json, sys
p = sys.argv[1] + "/.claude/settings.json"
d = json.load(open(p))
d["hooks"]["PostToolUse"].append({"matcher": "*", "hooks": [
    {"type": "command", "command": "node chunk-cap.js"}]})
json.dump(d, open(p, "w"), indent=2)
PY
out=$(doc "$H"); rc=$?
check "drift: a cap hook on the Claude side FAILs the exempt line" "[ $rc -eq 1 ] && printf %s \"\$out\" | grep -qE '^claude exempt:  +FAIL'"
python3 - "$H" <<'PY'
import json, sys
p = sys.argv[1] + "/.claude/settings.json"
d = json.load(open(p))
d["hooks"]["PostToolUse"] = [g for g in d["hooks"]["PostToolUse"]
                             if "chunk-cap" not in json.dumps(g)]
json.dump(d, open(p, "w"), indent=2)
PY
check "drift: exempt line green again" "doc '$H' >/dev/null 2>&1"

# ---- 5. the adopt path: a hand-written hook with our command becomes ours ----
HA="$T/hadopt"; mkhome "$HA"; mkdir -p "$HA/.claude"
python3 - "$HA" "$here" <<'PY'
import json, sys
home, tree = sys.argv[1], sys.argv[2]
cmd = "python3 " + tree + "/claude/hooks/harness.py"
json.dump({"hooks": {"SessionStart": [{"matcher": "*", "hooks": [
    {"type": "command", "command": cmd, "timeout": 10}]}]}},
    open(home + "/.claude/settings.json", "w"), indent=2)
PY
inst "$HA" >/dev/null 2>&1 || true
check "adopt: the manual entry is recorded, not duplicated" \
  "jq '$(SET "$HA")' 'len(d[\"_delegate\"][\"hooks\"]) >= 4' | grep -q True"
check "adopt: doctor agrees the hooks are in place" "doc '$HA' >/dev/null 2>&1"

# ---- 6. invalid JSON: refused, file untouched ----
HB="$T/hbad"; mkhome "$HB"; mkdir -p "$HB/.claude"; printf '{not json' > "$HB/.claude/settings.json"
out=$(inst "$HB" --claude-permissions 2>&1) || true
check "invalid settings.json: NOTE, install continues" "printf %s \"\$out\" | grep -q 'claude profile not installed'"
check "invalid settings.json: bytes untouched" "cat '$HB/.claude/settings.json' | grep -q 'not json'"

# ---- 7. uninstall: ours goes, theirs stays, a hand-edited entry stays with a NOTE ----
HZ="$T/hz"; mkhome "$HZ"; mkdir -p "$HZ/.claude"
printf '{"permissions":{"deny":["Bash(my-own-rule *)"]}}\n' > "$HZ/.claude/settings.json"
python3 - "$HZ" <<'PY'
import json, os, sys
os.makedirs(sys.argv[1] + "/.config/opencode", exist_ok=True)
p = sys.argv[1] + "/.config/opencode/opencode.json"
json.dump({"permission": {"bash": {"my-own *": "allow"}}}, open(p, "w"))
PY
inst "$HZ" --claude-permissions >/dev/null 2>&1 || true
python3 - "$HZ" <<'PY'
import json, sys
p = sys.argv[1] + "/.claude/settings.json"
d = json.load(open(p))
d["hooks"]["SessionStart"][0]["hooks"][0]["timeout"] = 99   # hand-edited managed entry
json.dump(d, open(p, "w"), indent=2)
PY
out=$(env "${CLEAN[@]}" HOME="$HZ" PATH="$T/stub:$PATH" "$here/install.sh" --uninstall 2>&1); rc=$?
check "uninstall exits 0" "[ $rc -eq 0 ]"
check "uninstall: plugin links gone" "! ls '$(PLUG "$HZ" chunk-cap)' '$(PLUG "$HZ" verify-loop)' 2>/dev/null"
check "uninstall: rules file gone" "[ ! -e '$HZ/.claude/rules/delegate-harness.md' ]"
check "uninstall: opencode marker gone" "! grep -q _delegate '$(OCFG "$HZ")'"
check "uninstall: our deny row gone" "! grep -q 'sudo' '$(OCFG "$HZ")'"
check "uninstall: foreign opencode entry kept" "grep -q 'my-own' '$(OCFG "$HZ")'"
check "uninstall: claude marker gone" "! grep -q _delegate '$(SET "$HZ")'"
check "uninstall: foreign deny kept in settings" "grep -q 'my-own-rule' '$(SET "$HZ")'"
check "uninstall: hand-edited entry left with a NOTE" "grep -q 'timeout\": 99' '$(SET "$HZ")' && printf %s \"\$out\" | grep -q 'NOTE'"
check "uninstall: skill links gone" "[ ! -L '$HZ/.claude/skills/delegate' ] && [ ! -L '$HZ/.local/bin/delegate' ]"

# ---- 8. --claude-permissions off (the default): no permissions key, doctor WARNs ----
HO="$T/hperm"; mkhome "$HO"; mkdir -p "$HO/.claude"
inst "$HO" >/dev/null 2>&1 || true
check "permissions off: settings carries no permissions key" "! grep -q '\"permissions\"' '$(SET "$HO")'"
out=$(doc "$HO"); rc=$?
check "permissions off: doctor WARNs on that line" "[ $rc -eq 0 ] && printf %s \"\$out\" | grep -qE '^permissions:  +WARN.*fix: re-run install.sh'"
check "permissions off: the other five lines are ok" "printf %s \"\$out\" | grep -qE '^hooks:  +ok' && printf %s \"\$out\" | grep -qE '^rules:  +ok' && printf %s \"\$out\" | grep -qE '^cap:  +ok'"

# ---- 9. a HOME with spaces in it ----
HS="$T/h o m e"; mkdir -p "$HS"; mkhome "$HS/x"; mkdir -p "$HS/x/.claude"
inst "$HS/x" --claude-permissions >/dev/null 2>&1 || true
check "spaces in HOME: opencode config merged" "[ -f '$(OCFG "$HS/x")' ] && grep -q '_delegate' '$(OCFG "$HS/x")'"
check "spaces in HOME: plugin links created" "[ -L '$(PLUG "$HS/x" notes-loop)' ]"
check "spaces in HOME: doctor exits 0" "doc '$HS/x' >/dev/null 2>&1"

# ---- 10. --claude-hook back-compat: the old flag still lands the dashboard hook, now via -- ----
# the profile installer, and the profile itself comes along with it
HH="$T/hhook"; mkhome "$HH"; mkdir -p "$HH/.claude"
inst "$HH" --claude-hook >/dev/null 2>&1 || true
check "--claude-hook: agent-progress registered" "grep -q 'agent-progress.py' '$(SET "$HH")'"
check "--claude-hook: profile installed too (marker present)" "grep -q '_delegate' '$(SET "$HH")'"
check "--claude-hook: harness hooks present alongside" "grep -q 'harness.py' '$(SET "$HH")'"
out=$(doc "$HH"); rc=$?
check "--claude-hook: doctor exits 0" "[ $rc -eq 0 ]"
cp "$(SET "$HH")" "$(SET "$HH").first"
inst "$HH" --claude-hook >/dev/null 2>&1 || true
check "--claude-hook: re-run is a byte no-op" "cmp -s '$(SET "$HH")' '$(SET "$HH").first'"

# ---- 11. release mode: every profile link and command path goes through `current` ----
SRC="$T/src"; mkdir -p "$SRC"
for d in install.sh bin lib claude commands opencode policy config.example.env VERSION; do
  cp -R "$here/$d" "$SRC/"
done
printf '9.9.9\n' > "$SRC/VERSION"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
git init -q -b main "$SRC" >/dev/null && git -C "$SRC" add -A \
  && git -C "$SRC" commit -qm v9.9.9 && git -C "$SRC" tag v9.9.9
HR="$T/hrel"; mkhome "$HR"; mkdir -p "$HR/.claude"
out=$(env "${CLEAN[@]}" HOME="$HR" PATH="$T/stub:$PATH" XDG_CONFIG_HOME="$HR/.config" \
       XDG_DATA_HOME="$HR/.local/share" DELEGATE_BIN_DIR="$HR/.local/bin" \
       "$here/install.sh" --release v9.9.9 --from "$SRC" --no-build --claude-permissions 2>&1); rc=$?
root="$HR/.local/share/delegate"
check "release install exits 0" "[ $rc -eq 0 ]"
check "release: plugin links point through current, not a tag dir" \
  "[ \"\$(readlink '$(PLUG "$HR" chunk-cap)')\" = '$root/current/opencode/plugins/chunk-cap.js' ]"
check "release: instructions point through current" \
  "grep -q \"$root/current/opencode/rules/harness-core.md\" '$(OCFG "$HR")'"
check "release: hook commands point through current" \
  "grep -q \"$root/current/claude/hooks/harness.py\" '$(SET "$HR")'"
check "release: doctor still reports ok" \
  "env ${CLEAN[*]} HOME='$HR' PATH='$T/stub:$PATH' XDG_CONFIG_HOME='$HR/.config' XDG_DATA_HOME='$HR/.local/share' '$root/current/bin/delegate' doctor >'$T/rel.log' 2>&1 && grep -qE '^permissions:  +ok' '$T/rel.log'"

if [ "$fail" = 0 ]; then echo "PASS test_profile_install"; else echo "FAIL test_profile_install"; fi
exit $fail