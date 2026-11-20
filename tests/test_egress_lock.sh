#!/bin/bash
# Concurrent starts share one egress proxy recreate (2026-11-20): three tasks started together all
# saw an outdated proxy, each ran `docker rm -f` + `docker run`, and the later ones died on
# "removal of container delegate-egress is already in progress". ensure_egress now takes a lock
# and re-reads the proxy after taking it. The function runs from bin/delegate's own text (or the
# file named by $1, so the test can be shown failing on an older copy) against a fake docker
# whose rm is slow and refuses a second removal while one is in progress.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
src=${1:-$here/bin/delegate}
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
B=$T/bin; W=$T/world; mkdir -p "$B" "$W"

# fake docker: $W/label holds the proxy's delegate.egress.cfg label (absent = no proxy);
# $W/removing exists while an rm is in progress; every call is appended to $W/calls.
cat > "$B/docker" <<'FAKE'
#!/bin/bash
W=${FAKE_WORLD:?}; echo "$*" >> "$W/calls"
case "$1" in
  image) echo sha256:newimage ;;
  inspect)
    case "$3" in
      *egress.cfg*) [ -f "$W/label" ] && cat "$W/label"; exit 0 ;;
      *Running*) echo true ;;
    esac ;;
  ps) exit 0 ;;
  rm)
    if ! mkdir "$W/removing" 2>/dev/null; then
      echo "Error response from daemon: removal of container delegate-egress is already in progress" >&2
      exit 1
    fi
    sleep 0.5; rm -f "$W/label"; rmdir "$W/removing" ;;
  run)
    for a in "$@"; do case "$a" in delegate.egress.cfg=*) echo "${a#delegate.egress.cfg=}" > "$W/label" ;; esac; done ;;
  network) exit 0 ;;
esac
FAKE
chmod +x "$B/docker"

fn=$(sed -n -e '/^EGRESS_NAME=/p' -e '/^ensure_egress() {/,/^}/p' "$src")
check "ensure_egress is in $(basename "$src")" '[ -n "$fn" ]'

cat > "$T/run.sh" <<EOF
set -euo pipefail
DELEGATE_STATE=$T/state; DELEGATE_EGRESS_IMAGE=delegate-egress:local
grant_net() { echo filtered; }
url_hosts() { echo model.example; }
host_args() { :; }
warn() { echo "warn: \$*" >&2; }
die() { echo "die: \$*" >&2; exit 1; }
$fn
ensure_egress
EOF
mkdir -p "$T/state"
echo stale-config > "$W/label"           # an outdated proxy exists, no worker is running

pids=()
for i in 1 2 3; do
  FAKE_WORLD=$W PATH="$B:$PATH" bash "$T/run.sh" > "$T/out$i" 2>&1 & pids+=($!)
done
rcs=""
for p in "${pids[@]}"; do wait "$p"; rcs="$rcs$?"; done

check "three concurrent starts all succeed (exit codes: $rcs)" '[ "$rcs" = 000 ]'
check "no start hit 'removal ... already in progress'" '! grep -q "already in progress" "$T"/out*'
check "the proxy was removed exactly once" '[ "$(grep -c "^rm -f" "$W/calls")" = 1 ]'
check "the proxy was recreated exactly once" '[ "$(grep -c "^run " "$W/calls")" = 1 ]'
check "the proxy now carries the new config" '[ -f "$W/label" ] && ! grep -q stale-config "$W/label"'

exit $fail
