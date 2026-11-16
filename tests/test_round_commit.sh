#!/bin/bash
# Round commits land in the user's history whenever a round or chain is merged unsquashed, so
# their message carries the slug, round and STATUS only: never the served model name (a site
# value; the report keeps it). Static, because a real round needs a worker.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
# join backslash-continued lines first: the round commit's -m arguments span two lines
msgs=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$here/bin/delegate" | grep -E 'commit(-tree)? .*-m ')
check "round commits are made in bin/delegate" '[ -n "$msgs" ]'
check "no commit message names the model" '! printf "%s\n" "$msgs" | grep -q "MODEL"'
check "the round commit keeps its STATUS line" 'printf "%s\n" "$msgs" | grep "round \$n" | grep -q status_line'
exit $fail
