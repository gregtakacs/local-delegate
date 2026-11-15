#!/bin/bash
# O1b step 6 (acceptance): the end-to-end slice gate as a stranger would run it — a fresh host,
# both harnesses, install -> idempotent re-run -> uninstall -> reinstall, then the worker's own
# seeding path. Offline: temp HOME, stub opencode/claude on PATH, the stub OpenAI endpoint from
# the shared rig (tests/e2e-rig.sh, the same fixtures step 5's test uses — one copy, not a fork).
# No docker, no network, no real $HOME touched (the rig swaps HOME before every installer call).
# Asserts design §8/§9 coexistence and, in the worker leg, re-checks step 2's core+adapter split.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
APIPID=""
# shellcheck source=./e2e-rig.sh
. "$(dirname "$0")/e2e-rig.sh"
trap 'rig_cleanup' EXIT
rig_init

# The real ~ must never be observed: HOME is swapped before every installer/doctor call. Prove the
# rig does that and that a pre-existing ~/.claude, ~/.config/opencode in the caller's HOME is a
# decoy the run cannot reach (it lives under the ORIGINAL $HOME, which no helper passes through).
ORIG_HOME="$HOME"
check "HOME is swapped into a fresh temp tree, never the caller's home" \
  '[ "$T" != "$ORIG_HOME" ] && [ "$ORIG_HOME" != "$T" ]'

# ============================================================================
# 1. clean install (--no-build --runner native --claude-permissions): both harnesses coexist
# ============================================================================
H="$T/h1"; mkhome "$H"; mkdir -p "$H/.claude"
# foreign entries, pre-seeded so uninstall/reinstall can prove they are never touched
printf '{"model":"opus","permissions":{"deny":["Bash(my-own-rule *)"]}}\n' > "$(SET "$H")"
python3 - "$H" <<'PY'
import json, os, sys
p = sys.argv[1] + "/.config/opencode/opencode.json"
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump({"$schema": "https://opencode.ai/config.json",
           "permission": {"bash": {"my-own *": "allow"}}}, open(p, "w"))
PY
out=$(inst "$H" --runner native --claude-permissions 2>&1); rc=$?
check "install exits 0" "[ $rc -eq 0 ]"
# opencode side: our instructions + the clinerules glob + a deny row + the marker
check "opencode: _delegate record present" "grep -q '_delegate' '$(OCFG "$H")'"
check "opencode: core + adapter both in instructions" \
  "grep -q 'opencode/rules/harness-core.md' '$(OCFG "$H")' && grep -q 'opencode/rules/adapter-opencode.md' '$(OCFG "$H")'"
check "opencode: policy render added a deny row" "grep -q 'sudo' '$(OCFG "$H")'"
check "opencode: \$schema kept (merge never clobbers foreign keys)" "grep -q 'opencode.ai/config.json' '$(OCFG "$H")'"
# claude side: hooks + marker + permissions block (flag on) + rules file for the harness
check "settings: delegate record present (sibling file)" "[ -s '$H/.claude/delegate-profile.json' ]"
check "settings: no _delegate key in settings.json" "! grep -q '_delegate' '$(SET "$H")'"
check "settings: harness hooks installed" "grep -q 'claude/hooks/harness.py' '$(SET "$H")'"
check "settings: permissions rendered on --claude-permissions" \
  "jq '$(SET "$H")' 'len(d[\"permissions\"][\"deny\"]) > 0' | grep -q True"
check "settings: foreign deny untouched by the merge" "grep -q 'my-own-rule' '$(SET "$H")'"
check "rules file present for the harness" "[ -s '$H/.claude/rules/delegate-harness.md' ]"
# four plugin links, all resolving into this checkout
check "four plugin links created" \
  "[ -L '$(PLUG "$H" chunk-cap)' ] && [ -L '$(PLUG "$H" notes-loop)' ] && [ -L '$(PLUG "$H" todo-loop)' ] && [ -L '$(PLUG "$H" verify-loop)' ]"
check "plugin links resolve into the install tree" "readlink -f '$(PLUG "$H" chunk-cap)' | grep -qF '$here/'"

# .clinerules mechanism, per step 5's picked routes (S5 opencode glob, S6 claude import). A missing
# artefact is a finding, not a skip: check() prints the named FAIL line.
check ".clinerules (opencode, picked S5): instructions glob '.clinerules/*.md' installed" \
  "grep -q '\.clinerules/\*\.md' '$(OCFG "$H")'"
check ".clinerules (claude, picked S6): rules file carries the '@.clinerules' import" \
  "grep -q '@\.clinerules' '$H/.claude/rules/delegate-harness.md'"

# doctor exits 0 and prints the §9 harness block (six lines)
out=$(doc "$H" 2>&1); rc=$?
check "doctor exits 0 on the fresh install" "[ $rc -eq 0 ]"
check "doctor: harness block printed (rules/plugins/hooks/cap/permissions/exempt)" \
  "printf %s \"\$out\" | grep -qE '^rules:' && printf %s \"\$out\" | grep -qE '^plugins:' && printf %s \"\$out\" | grep -qE '^hooks:' && printf %s \"\$out\" | grep -qE '^cap:' && printf %s \"\$out\" | grep -qE '^permissions:' && printf %s \"\$out\" | grep -qE '^claude exempt:'"
check "doctor: reports OK overall" "printf %s \"\$out\" | grep -q 'doctor: OK'"

# ============================================================================
# 2. idempotence: a second install is byte-identical (hash both configs before/after)
# ============================================================================
cp "$(OCFG "$H")" "$T/oc.a"; cp "$(SET "$H")" "$T/st.a"; cp "$H/.claude/rules/delegate-harness.md" "$T/rl.a"
sha_a=$(sha256sum "$(OCFG "$H")" "$(SET "$H")" | awk '{print $1}' | tr '\n' ' ')
inst "$H" --runner native --claude-permissions >/dev/null 2>&1 || true
sha_b=$(sha256sum "$(OCFG "$H")" "$(SET "$H")" | awk '{print $1}' | tr '\n' ' ')
check "re-run: opencode+claude configs byte-identical (sha match)" "[ \"$sha_a\" = \"$sha_b\" ]"
check "re-run: opencode config byte-identical" "cmp -s '$(OCFG "$H")' '$T/oc.a'"
check "re-run: claude settings byte-identical" "cmp -s '$(SET "$H")' '$T/st.a'"
check "re-run: rules file byte-identical" "cmp -s '$H/.claude/rules/delegate-harness.md' '$T/rl.a'"

# reference copy of the step-1 (installed) state, for the reinstall comparison in section 4
cp "$(OCFG "$H")" "$T/oc.ref"; cp "$(SET "$H")" "$T/st.ref"; cp "$H/.claude/rules/delegate-harness.md" "$T/rl.ref"

# ============================================================================
# 3. uninstall: ours goes, theirs stays, links gone, rules file gone-or-foreign
# ============================================================================
out=$(inst "$H" --uninstall 2>&1); rc=$?
check "uninstall exits 0" "[ $rc -eq 0 ]"
check "uninstall: opencode _delegate record gone" "! grep -q '_delegate' '$(OCFG "$H")'"
check "uninstall: claude delegate record gone" "[ ! -e '$H/.claude/delegate-profile.json' ]"
check "uninstall: our deny row gone from opencode" "! grep -q 'sudo' '$(OCFG "$H")'"
check "uninstall: foreign opencode entry kept" "grep -q 'my-own' '$(OCFG "$H")'"
check "uninstall: foreign claude deny kept" "grep -q 'my-own-rule' '$(SET "$H")'"
check "uninstall: plugin links gone" \
  "[ ! -L '$(PLUG "$H" chunk-cap)' ] && [ ! -L '$(PLUG "$H" notes-loop)' ] && [ ! -L '$(PLUG "$H" todo-loop)' ] && [ ! -L '$(PLUG "$H" verify-loop)' ]"
check "uninstall: rules file gone (it was ours)" "[ ! -e '$H/.claude/rules/delegate-harness.md' ]"
check "uninstall: the config file itself is left for the user (only our entries removed)" \
  "[ -f '$(OCFG "$H")' ] && [ -f '$(SET "$H")' ]"

# ============================================================================
# 4. reinstall after uninstall -> back to the step-1 installed state
# ============================================================================
inst "$H" --runner native --claude-permissions >/dev/null 2>&1 || true
check "reinstall: opencode config restored to the step-1 state (byte-identical)" \
  "cmp -s '$(OCFG "$H")' '$T/oc.ref'"
check "reinstall: claude settings restored to the step-1 state (byte-identical)" \
  "cmp -s '$(SET "$H")' '$T/st.ref'"
check "reinstall: rules file restored byte-identical" \
  "cmp -s '$H/.claude/rules/delegate-harness.md' '$T/rl.ref'"
out=$(doc "$H" 2>&1); rc=$?
check "reinstall: doctor exits 0 again after the cycle" "[ $rc -eq 0 ]"

# ============================================================================
# 5. worker path regression, without docker: entrypoint.sh seeding into a temp HOME.
#    /opt/delegate is the container mount; it is not writable here, so run a faithful copy of
#    worker/entrypoint.sh whose only change is the tree root, the way test_chain.sh swaps in a
#    fake `delegate`. This EXECUTES the seeding (cp rules -> refuse-empty-core -> cat core+adapter
#    -> render opencode.json), then asserts on the seeded temp HOME.
# ============================================================================
FAKE="$T/opt/delegate"; WH="$T/whome"
mkdir -p "$FAKE/opencode" "$FAKE/lib" "$WH"
cp -R "$here/opencode/rules" "$FAKE/opencode/rules"
cp -R "$here/opencode/plugins" "$FAKE/opencode/plugins"
cp "$here/opencode/delegate-rules.md" "$FAKE/opencode/delegate-rules.md"
cp "$here/lib/render-opencode-config.py" "$FAKE/lib/render-opencode-config.py"
sed "s#/opt/delegate#$FAKE#g" "$here/worker/entrypoint.sh" > "$T/ep.sh"
seedenv=(env HOME="$WH" DELEGATE_BASE_URL=http://127.0.0.1:9/v1 DELEGATE_API_KEY_FILE="$T/key"
         DELEGATE_MODEL=stub-model DELEGATE_WORKTREE="$WH")
"${seedenv[@]}" bash "$T/ep.sh" true >"$T/ep.log" 2>&1; src=$?
check "entrypoint seeding runs clean (exit 0, execs the command)" "[ $src -eq 0 ]"
check "worker: the whole rules dir landed (core file present)" \
  "[ -s '$WH/.config/opencode/rules/harness-core.md' ]"
check "worker: composed delegate-rules.md has BOTH core and worker adapter" \
  "grep -q '^# Harness rules (core)\$' '$WH/.config/opencode/delegate-rules.md' && grep -q '^# Delegated-worker rules (headless adapter)\$' '$WH/.config/opencode/delegate-rules.md'"
coreln=$(grep -n '^# Harness rules (core)$' "$WH/.config/opencode/delegate-rules.md" 2>/dev/null | head -1 | cut -d: -f1)
adpln=$(grep -n '^# Delegated-worker rules (headless adapter)$' "$WH/.config/opencode/delegate-rules.md" 2>/dev/null | head -1 | cut -d: -f1)
check "worker: the core loads BEFORE the headless adapter (one coherent ruleset)" \
  '[ -n "$coreln" ] && [ -n "$adpln" ] && [ "$coreln" -lt "$adpln" ]'
check "worker: rendered opencode.json points at the single composed rules file" \
  "jq '$WH/.config/opencode/opencode.json' 'len(d[\"instructions\"])==1 and d[\"instructions\"][0].endswith(\"delegate-rules.md\")' | grep -q True"
# a missing core is fatal, never a silently deltas-only worker
rm "$FAKE/opencode/rules/harness-core.md"
"${seedenv[@]}" bash "$T/ep.sh" true >"$T/ep2.log" 2>&1; mrc=$?
check "worker: a missing core aborts the seed (exit 1), no composed file left" \
  "[ $mrc -ne 0 ] && grep -q 'harness-core.md is missing or empty' '$T/ep2.log' && [ ! -s '$WH/.config/opencode/delegate-rules.md' ]"

# ============================================================================
# 6. edge: a failing harness probe must not crash the whole install (the skip/NOTE path).
#    An opencode stub that exits 1 (harness present but the probe errors) plus a config whose
#    endpoint is unreachable: install.sh's closing doctor is a guarded probe, so the install
#    still finishes (exit 0) and prints the doctor NOTE instead of aborting mid-write.
# ============================================================================
ST1="$T/stub-fail"; mkdir -p "$ST1"
printf '#!/bin/sh\nexit 1\n' > "$ST1/opencode"; printf '#!/bin/sh\nexit 1\n' > "$ST1/claude"
chmod +x "$ST1/opencode" "$ST1/claude"
HF="$T/hf"; mkhome "$HF"; mkdir -p "$HF/.claude"
# point the config at a closed port so doctor's endpoint probe genuinely fails
sed -i 's|^DELEGATE_BASE_URLS=.*|DELEGATE_BASE_URLS="http://127.0.0.1:9/v1"|' "$HF/.config/delegate/config.env"
out=$(env "${CLEAN[@]}" HOME="$HF" PATH="$ST1:$PATH" XDG_CONFIG_HOME="$HF/.config" \
       CLAUDE_SKILLS_DIR="" OPENCODE_COMMANDS_DIR="" \
       "$here/install.sh" --no-build --runner native --claude-permissions 2>&1); rc=$?
check "failing harness probe: install still exits 0 (does not crash)" "[ $rc -eq 0 ]"
check "failing harness probe: install prints the skip/doctor NOTE" "printf %s \"\$out\" | grep -qiE 'NOTE|doctor reported problems'"
check "failing harness probe: the config files were still written (not aborted mid-install)" \
  "[ -f '$(OCFG "$HF")' ] && [ -f '$(SET "$HF")' ]"

# ============================================================================
# 7. hygiene: the run created no stray files in the repo. A temp dir leaked into the checkout or a
#    file written at the repo root would show up as an untracked entry; the test's own fixtures
#    (test_e2e_harness.sh, e2e-rig.sh) and any tracked edits are not litter, so they are allowed.
# ============================================================================
litter=$(git -C "$here" status --porcelain 2>/dev/null \
         | grep -E '^\?\?' | grep -vE '^(\?\? )?tests/(test_e2e_harness|e2e-rig)\.sh$' || true)
check "test leaves no stray untracked files in the repo" "[ -z \"\$litter\" ]"

if [ "$fail" = 0 ]; then echo "PASS test_e2e_harness"; else echo "FAIL test_e2e_harness"; fi
exit $fail
