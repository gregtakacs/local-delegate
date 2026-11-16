#!/bin/bash
# The harness rules split: a harness-neutral core plus per-harness adapters, the worker
# adapter slimmed to headless deltas, the interactive rules file retired. This test is the
# rules-load guard (O1b step 2). No model, no binaries — it reads files and greps them.
#
# NOTE on wording greps: meta planning docs under docs/specs/ quote the very phrases and the
# grep commands being removed (they define the gate), so they are exempt — the same convention
# step 6's dead-name check uses (`grep -v docs/specs/`). Patterns below use a dot (`local.model`,
# `interactive.rules`) so this file's own text is not a literal match a repo-wide gate would hit.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
R=$here/opencode/rules
core=$R/harness-core.md
ao=$R/adapter-opencode.md
ac=$R/adapter-claude-code.md
dr=$here/opencode/delegate-rules.md
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# ------------------------------------------------------------------ files exist ----------
check "core exists"           '[ -f "$core" ]'
check "opencode adapter exists" '[ -f "$ao" ]'
check "claude adapter exists" '[ -f "$ac" ]'
check "worker adapter exists" '[ -f "$dr" ]'
stray=$(ls -A "$here/opencode" | grep -vE '^(delegate-rules\.md|plugins|rules)$' || true)
check "interactive rules file is gone (only the post-split layout ships)" '[ -z "$stray" ]'

# ---------------------------------------------------- core neutrality (no tools/paths) ----
check "core names no harness tool/harness name" \
  '! grep -niE "opencode|claude|todowrite|edit\(" "$core"'
check "core states no edit-cap number" \
  '! grep -nE "8000|6000" "$core"'
check "core defers the cap to the adapter" \
  'grep -q "the configured edit cap" "$core"'
check "core points at the harness adapter for tool/paths" \
  'grep -qi "your harness adapter" "$core"'
check "core carries the workers-run-only-their-step-scope test policy" \
  'grep -q "changes only what its step" "$core" && grep -qi "full gate" "$core"'

# ------------------------------------------- key behaviour survives into the core ----------
haskw(){ grep -qF "$1" "$core"; }
check "DoD gate phrase survives (watched run ends in evidence)" \
  'haskw "A watched run ends in evidence, not in a status word."'
check "DoD gate phrase survives (naming a check)" 'haskw "Naming a check is not passing it."'
check "DoD list entries survive (exercised / no fabrication)" \
  'haskw "Exercised, not inspected." && haskw "No fabrication."'
check "PID-kill rule survives verbatim" \
  'haskw "Stop processes only by the PID you got when you started them"'
check "no-pkill rule survives verbatim" \
  'grep -qE "Never .pkill., .killall." "$core"'
check "the environmental-is-a-claim sentence survives" \
  'haskw "is a claim, not a verdict"'

# -------------------------------------------------- adapters short, name the core ----------
lines(){ wc -l < "$1"; }
check "opencode adapter <= 45 lines" '[ "$(lines "$ao")" -le 45 ]'
check "claude adapter <= 45 lines"   '[ "$(lines "$ac")" -le 45 ]'
check "opencode adapter names the core in its first lines" \
  'head -3 "$ao" | grep -q "harness-core.md"'
check "claude adapter names the core in its first lines" \
  'head -3 "$ac" | grep -q "harness-core.md"'
check "claude adapter states the edit-cap exemption" \
  'grep -qi "exempt" "$ac" && grep -qi "style advice" "$ac"'
check "claude adapter tells the agent to read .clinerules (route-neutral)" \
  'grep -qF ".clinerules" "$ac" && grep -qF ".clinerules/*.md" "$ac" && ! grep -qiE "import|@" "$ac"'
check "opencode adapter names the notes fallback path" \
  'grep -qF "/tmp/opencode-notes/<repo>/NOTES.md" "$ao"'
check "opencode adapter states the configured cap sentence" \
  'grep -qF "DELEGATE_CHUNK_CAP" "$ao" && grep -qF "default 8000" "$ao"'
check "opencode adapter points at verify-ui.md install path" \
  'grep -qF "verify-ui.md" "$ao" && grep -qF "/rules/verify-ui.md" "$ao"'

# ------------------------------------------------- cross-references resolve ----------------
numsec(){ grep -oE '^## [0-9]+[a-z]?\.' "$1" | sed -E 's/^## //; s/\.$//' | sort -u; }
numref(){ grep -oE '§[0-9]+[a-z]?' "$1" | sed 's/§//' | sort -u; }
refs_resolve(){ # FILE ALLOWED(all headings, newline-separated)
  local f=$1 allowed=$2 r bad=0
  for r in $(numref "$f"); do grep -qx "$r" <<<"$allowed" || { echo "   dangling §$r in $f"; bad=1; }; done
  return $bad;
}
check "core internal §-refs resolve within the core" \
  'refs_resolve "$core" "$(numsec "$core")"'
check "worker adapter §-refs resolve (worker ∪ core)" \
  'refs_resolve "$dr" "$(numsec "$dr"; numsec "$core")"'
check "opencode adapter §-refs resolve (adapter ∪ core)" \
  'refs_resolve "$ao" "$(numsec "$ao"; numsec "$core")"'
check "claude adapter §-refs resolve (adapter ∪ core)" \
  'refs_resolve "$ac" "$(numsec "$ac"; numsec "$core")"'

# --------------------------------------- worker adapter is the headless deltas -------------
check "worker adapter opens by naming itself the headless adapter" \
  'head -3 "$dr" | grep -qi "headless adapter"'
check "worker adapter states the core loads with/after it" \
  'head -12 "$dr" | grep -q "rules/harness-core.md"'
check "worker adapter keeps the STATUS closing block" \
  'grep -q "^STATUS: done | partial | blocked" "$dr" && grep -q "^FILES:" "$dr" && grep -q "^EVIDENCE:" "$dr"'
check "worker adapter keeps the no-history git variant" \
  'grep -qF "Do not run git commands that change history or branches" "$dr"'

# --------------------------------------------- dead name: interactive rules ----------------
dead=$(git -C "$here" ls-files | grep -v '^docs/specs/' | grep -v '^tests/test_rules_load.sh$')
check "no tracked non-spec file references the retired interactive rules file" \
  '! printf "%s\n" $dead | while read -r f; do [ -f "$here/$f" ] && grep -q "interactive.rules" "$here/$f" && exit 1; done'

# ------------------------------------------------------- model-neutral wording -------------
check "no product file says the vendor model phrase" \
  '[ -z "$(grep -rniE "local.model" -I "$here" 2>/dev/null | grep -v "/.git/" | grep -v "evals/" | grep -v "docs/specs/" | grep -v "send to the local.model" | grep -v "tests/test_rules_load.sh")" ]'
check "installed rules (core, adapters, worker) never say the vendor model phrase" \
  '! grep -niE "local.model" "$core" "$ao" "$ac" "$dr"'

# --------- worker seeding: one composed instructions file (exercised, not grepped) --
# The rendered config points at ONE file (delegate-rules.md); worker/entrypoint.sh composes the
# core and the adapter into it, core first, and refuses to run on the deltas alone. Assert the
# entrypoint says that, then EXECUTE the same two steps in a throwaway dir to prove the ordering
# and the missing-core refusal (a missing core must never yield a silently deltas-only worker).
ep="$here/worker/entrypoint.sh"
check "entrypoint seeds the whole rules dir recursively (lands the core file)" \
  'grep -qE "cp -r[^\n]*opencode/rules" "$ep"'
check "entrypoint refuses to start when the core is missing or empty (loud, not silent)" \
  'grep -q "harness-core.md is missing or empty" "$ep" && grep -qE "^\s*exit 1" "$ep"'
check "entrypoint composes core THEN adapter into the one worker rules file" \
  'grep -qE "cat \"\\\$core\" \"\\\$adapter\" > \"\\\$cfg/delegate-rules.md\"" "$ep"'

sim=$(mktemp -d); trap 'rm -rf "$sim"' EXIT
# mkseed mirrors the entrypoint exactly: require a non-empty core, then cat core + adapter.
mkseed(){ # $1 = core content, or NONE to simulate a missing core; rc 1 when core absent/empty
  local c="$sim/cfg" core="$sim/cfg/rules/harness-core.md" a="$here/opencode/delegate-rules.md"
  rm -rf "$c"; mkdir -p "$c/rules"
  [ "$1" = NONE ] || printf 'HARNESS_CORE_SIGNATURE_LINE\n%s\n' "$1" > "$core"
  [ -s "$core" ] || return 1
  cat "$core" "$a" > "$c/delegate-rules.md"
}
mkseed "core body" >"$sim/out" 2>&1; seeded_rc=$?
check "seeding succeeds when the core is present" '[ "$seeded_rc" = 0 ]'
check "composed worker file carries the core signature line" \
  'grep -q "^HARNESS_CORE_SIGNATURE_LINE$" "$sim/cfg/delegate-rules.md"'
c_line=$(grep -n "^HARNESS_CORE_SIGNATURE_LINE$" "$sim/cfg/delegate-rules.md" 2>/dev/null | head -1 | cut -d: -f1)
a_line=$(grep -n "^# Delegated-worker rules (headless adapter)" "$sim/cfg/delegate-rules.md" 2>/dev/null | head -1 | cut -d: -f1)
check "the composed worker file puts the core BEFORE the worker adapter" \
  '[ -n "$c_line" ] && [ -n "$a_line" ] && [ "$c_line" -lt "$a_line" ]'
mkseed NONE >"$sim/out" 2>&1; miss_rc=$?
check "a missing/empty core makes seeding fail (never a silent deltas-only worker)" \
  '[ "$miss_rc" -ne 0 ] && [ ! -s "$sim/cfg/delegate-rules.md" ]'

exit $fail
