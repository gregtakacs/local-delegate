#!/bin/bash
# A verify's own stage logs survive its container (0.8.9). Before, a stage that logged to /tmp
# (`suite > /tmp/x.log && grep -q ok /tmp/x.log`) took its log with the container, and a failed
# round reported an exit code and nothing else (gal2-2: five rounds, two of them on causes one log
# line would have named). The functions run from bin/delegate's own text, against the real /tmp.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
T=$(mktemp -d); W=$(mktemp -d /tmp/dvtest.XXXXXX); trap 'rm -rf "$T" "$W"' EXIT

fns=$(sed -n -e '/^VERIFY_KEEP_MAX=/p' -e '/^VERIFY_KEEP_SIZE=/p' \
  -e '/^verify_wrapped() {/,/^}/p' -e '/^verify_keep_note() {/,/^}/p' "$here/bin/delegate")
check "verify_wrapped and verify_keep_note are in bin/delegate" \
  'printf "%s" "$fns" | grep -q "^verify_wrapped() {" && printf "%s" "$fns" | grep -q "^verify_keep_note() {"'
# what the round does: wrap, run (bash -lc in the container; plain bash here), note on failure
round() { # RUNNER VERIFY KEEP -> rc; the round's verify log in $T/verify.log
  : > "$T/verify.log"
  local cmd; cmd=$(DELEGATE_RUNNER=$1 bash -c "$fns"'
verify_wrapped "$1" "$2"' _ "$2" "$3")
  bash -c "$cmd" >> "$T/verify.log" 2>&1; local rc=$?
  bash -c "$fns"'
verify_keep_note "$1" "$2" "$3"' _ "$T/verify.log" "$3" "$rc"
  return $rc; }

echo "old" > "$W/before.log"; touch -d '1 hour ago' "$W/before.log"
K="$T/keep r1"     # a space in the path: quoted all the way through
round docker "set -o pipefail; echo stage-a-fine > $W/a.log && grep -q fine $W/a.log && printf 'line1\nTypeError: boom at x.py:3\n' > $W/b.log && grep -q '0 failed' $W/b.log && echo never > $W/c.log" "$K"; rc=$?
check "a failed verify keeps its exit code" '[ $rc = 1 ]'
check "the stage logs it wrote are kept, flattened under the keep dir" \
  '[ -f "$K/$(basename $W)_a.log" ] && [ -f "$K/$(basename $W)_b.log" ]'
check "a log from before the verify is not" '! ls "$K" | grep -q before'
check "the round's verify log names the kept logs" 'grep -q "stage logs it wrote are kept in $K" $T/verify.log'
check "…and shows the logs' tails, the actual error among them" 'grep -q "  | TypeError: boom at x.py:3" $T/verify.log'

K2="$T/keep-pass"
round docker "echo fine > $W/p.log && grep -q fine $W/p.log" "$K2"; rc=$?
check "a passing verify: exit 0, logs kept, no failure note" '[ $rc = 0 ] && [ -f "$K2/$(basename $W)_p.log" ] && ! grep -q "stage logs" $T/verify.log'

K3="$T/keep-exit"
round docker "echo partial > $W/e.log; exit 3" "$K3"; rc=$?
check "a verify that exits early: its code survives and its logs are still kept" '[ $rc = 3 ] && [ -f "$K3/$(basename $W)_e.log" ]'

K4="$T/keep-sete"
round docker "set -e; cd /; echo x > $W/s.log; false; echo not-reached > $W/t.log" "$K4"; rc=$?
check "set -e and a cd inside the verify do not stop the keeping" '[ $rc = 1 ] && [ -f "$K4/$(basename $W)_s.log" ] && [ ! -f "$K4/$(basename $W)_t.log" ]'

K5="$T/keep-size"
round docker "head -c 3000000 /dev/zero > $W/huge.log; echo tiny > $W/tiny.log; echo data > $W/out.bin; false" "$K5"
check "only small *.log files: not a 3 MB log, not a .bin" \
  '[ -f "$K5/$(basename $W)_tiny.log" ] && ! ls "$K5" | grep -q huge && ! ls "$K5" | grep -q out.bin'

K6="$T/keep-native"
cmd=$(DELEGATE_RUNNER=native bash -c "$fns"'
verify_wrapped "$1" "$2"' _ "echo hi > $W/n.log" "$K6")
check "the native runner runs the verify as written (its /tmp is the host's)" '[ "$cmd" = "echo hi > $W/n.log" ]'

K7="$T/keep-pct"
round docker "printf '%s\n' 100% > $W/pct.log; grep -q 100% $W/pct.log" "$K7"; rc=$?
check "a verify with % and quotes runs unchanged" '[ $rc = 0 ] && grep -q "100%" "$K7/$(basename $W)_pct.log"'

exit $fail
