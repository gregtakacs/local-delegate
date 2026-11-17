#!/bin/bash
# Task networks are released with the round's lock and swept before a new round takes one
# (0.6.1): a finished task kept its network for its whole record, and the host ran out of
# address pools. The functions run from bin/delegate's own text against a fake docker that
# keeps real state: networks, their delegate.task label, and the containers on each.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
B=$T/bin; W=$T/world; mkdir -p "$B" "$W/net"

# fake docker: $W/net/<name> holds "label=<task>" then one "c=<container>" line per container
cat > "$B/docker" <<'FAKE'
#!/bin/bash
W=${FAKE_WORLD:?}; echo "$*" >> "$W/calls"
case "$1 $2" in
  "network inspect")
    if [ "$3" = -f ]; then n=$5; f=$W/net/$n; [ -f "$f" ] || exit 1
      case "$4" in
        *Containers*) sed -n 's/^c=//p' "$f" | tr '\n' ' ' ;;
        *Labels*) sed -n 's/^label=//p' "$f" ;;
      esac; exit 0
    fi
    [ -f "$W/net/$3" ] ;;
  "network ls") ls "$W/net" ;;
  "network rm") f=$W/net/$3; [ -f "$f" ] || exit 1
    grep -q '^c=' "$f" && { echo "error: network $3 has active endpoints" >&2; exit 1; }
    rm -f "$f" ;;
  "network disconnect") n=$4; c=$5; [ -f "$W/net/$n" ] && sed -i "/^c=$c\$/d" "$W/net/$n" ;;
  "rm -f") shift 2; for c in "$@"; do for f in "$W"/net/*; do [ -f "$f" ] && sed -i "/^c=$c\$/d" "$f"; done; done ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$B/docker"
net() { local n=$1 t=$2; shift 2; { echo "label=$t"; for c in "$@"; do echo "c=$c"; done; } > "$W/net/$n"; }
has() { [ -f "$W/net/$1" ]; }

fns=$(sed -n -e '/^svc_net()/p' -e '/^EGRESS_NAME=/p' -e '/^egress_task_name()/p' \
      -e '/^release_service() {/,/^}/p' -e '/^gc_networks() {/,/^}/p' "$here/bin/delegate")
check "release_service and gc_networks are in bin/delegate" \
  'printf "%s" "$fns" | grep -q "^release_service() {" && printf "%s" "$fns" | grep -q "^gc_networks() {"'
run() { PATH="$B:$PATH" FAKE_WORLD=$W DELEGATE_RUNNER=docker DELEGATE_STATE=$T/state \
        bash -c "set -euo pipefail; $fns
$1"; }
S=$T/state; mkdir -p "$S"

# -- release_service: one task's own network ----------------------------------------------
net delegate-t1 t1 delegate-egress
run 'ID=t1; SERVICE=; release_service'
check "a finished task's network is released (egress detached first)" '! has delegate-t1'

net delegate-t2 t2 delegate-egress delegate-egress-t2
run 'ID=t2; SERVICE=; release_service'
check "an allow-mode task's own egress goes with it" '! has delegate-t2'

net delegate-t3 t3 delegate-egress delegate-t3-pg
run 'ID=t3; SERVICE=postgres; release_service'
check "a postgres task keeps its network (the sidecar lives on it)" 'has delegate-t3'

net delegate-t4 t4 delegate-egress delegate-t4-x123
run 'ID=t4; SERVICE=; release_service'
check "a network an exec still uses is kept" 'has delegate-t4'
check "... and the shared egress is not pulled from under that exec" 'grep -q "^c=delegate-egress$" "$W/net/delegate-t4"'

run 'ID=t-none; SERVICE=; release_service'
check "no network: nothing to do, no error" 'true'
check "a native-runner task touches no docker" \
  '! PATH="$B:$PATH" FAKE_WORLD=$W DELEGATE_RUNNER=native bash -c "$fns
ID=t5; SERVICE=; release_service; echo native" 2>&1 | grep -qv native'

# -- gc_networks: the sweep before a round takes a network --------------------------------
rm -f "$W"/net/*
mkdir -p "$S/live/lock" "$S/done" "$S/pg"; printf 'SERVICE=postgres\n' > "$S/pg/meta.env"
net delegate-live live delegate-egress
net delegate-done done delegate-egress
net delegate-gone gone delegate-egress
net delegate-pg pg delegate-egress delegate-pg-pg
net "delegate-doctor-$$" "doctor-$$" delegate-egress              # this shell: alive
net delegate-doctor-999999 doctor-999999 delegate-egress          # no such process
run 'gc_networks'
check "gc: a running task (lock held) keeps its network" 'has delegate-live'
check "gc: a finished task's network is released" '! has delegate-done'
check "gc: a network whose task record is gone is released" '! has delegate-gone'
check "gc: a postgres task keeps its network while its record exists" 'has delegate-pg'
check "gc: a live doctor probe keeps its network" "has delegate-doctor-$$"
check "gc: a dead doctor probe's network is released" '! has delegate-doctor-999999'

net "delegate-x" "../escape" delegate-egress
run 'gc_networks'
check "gc: a label that is not a plain task id is left alone" 'has delegate-x'

# -- the wiring ---------------------------------------------------------------------------
check "the round lock's EXIT trap releases the network before unlocking" \
  "grep -A3 '^lock_task() {' $here/bin/delegate | grep -q \"trap 'release_service || true; rmdir\""
check "a round sweeps before it ensures its own network" \
  "grep -B1 '^  ensure_service$' $here/bin/delegate | grep -q 'gc_networks'"
check "doctor's probe failure cannot skip its network cleanup" \
  "grep -q '|| res=\"\"' $here/bin/delegate"
exit $fail
