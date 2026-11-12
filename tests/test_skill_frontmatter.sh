#!/bin/bash
# claude/skills/delegate/SKILL.md: the frontmatter must stay parseable. A ": " inside the
# unquoted description plain-scalar broke YAML loading (2026-11-12, e7f6bb2), and opencode
# silently skipped the whole skill. Dependency-free check of the plain-scalar hazards.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

sk=$here/claude/skills/delegate/SKILL.md
desc=$(awk 'f&&/^---/{exit} /^description:/{sub(/^description: /,"");print;f=1}' "$sk")
check "description found" '[ -n "$desc" ]'
check "no colon-space inside description value" \
  '[ "$(printf %s "$desc" | grep -c ": ")" = 0 ]'
check "no space-hash inside description value" \
  '! printf %s "$desc" | grep -q " #"'
check "no leading indicator chars" \
  '! printf %s "$desc" | head -c1 | grep -qE "[][{}&*!|>\"\x27%\x60#,?@+-]"'
exit $fail
