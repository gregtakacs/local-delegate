#!/usr/bin/env bash
# Grants (docs/grants.md): trust rules, resolution, the docker args they produce, guards,
# locks, the built-in orb grant against the pre-grants --orb arguments, continue's refusal, and
# (with docker) the per-task allow-list proxy.
#   tests/test_grants.sh            # everything that needs no docker
#   DOCKER=1 tests/test_grants.sh   # plus the allow-list proxy, with throwaway containers
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
G="python3 $HERE/lib/grants.py"
T=$(mktemp -d); trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"; [ -n "${CLEAN:-}" ] && eval "$CLEAN"' EXIT
D="$T/grants"; mkdir -p "$D"; chmod 755 "$D"
pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "ok    $*"; }
bad()  { fail=$((fail + 1)); echo "FAIL  $*"; }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }
refuses() { local what=$1 want=$2; shift 2; local out; out=$("$@" 2>&1) && { bad "$what (accepted)"; return; }
  case "$out" in *"$want"*) ok "$what" ;; *) bad "$what (said: $out)" ;; esac; }
grant() { printf '%s\n' "$2" > "$D/$1.toml"; chmod 644 "$D/$1.toml"; }
show() { $G resolve --dir "$D" "$@"; }
args_of() { local f="$T/r.json"; show "$@" > "$f" && $G docker-args "$f"; }

# ---- 1. trust and parsing
grant good 'brief = "hi"'
check "a plain grant resolves" show --grant good
grant typo $'[network]\nmdoe = "host"'
refuses "an unknown key is refused" "unknown key" show --grant typo
grant top 'unknown = 1'
refuses "an unknown top-level key is refused" "unknown key" show --grant top
refuses "a bad name is refused" "grant name" show --grant '../repo/evil'
refuses "a missing grant is refused" "no grant" show --grant nope
grant gw 'brief = "x"'; chmod 664 "$D/gw.toml"
refuses "a group-writable grant file is refused" "writable by group" show --grant gw
chmod 644 "$D/gw.toml"; chmod 777 "$D"
refuses "a world-writable grants folder is refused" "writable by group or others" show --grant good
chmod 755 "$D"
ln -s "$D/good.toml" "$D/link.toml"
refuses "a symlinked grant is refused" "symlink" show --grant link
grant env1 $'[env]\nPATH = "/evil"'
refuses "a grant may not set PATH" "reserved" show --grant env1
grant env2 $'[env]\nDELEGATE_IMAGE = "x"'
refuses "a grant may not set DELEGATE_*" "reserved" show --grant env2
grant gpat $'[guards.x]\ncommands = ["rm"]\nargs = ["$(id)"]'
refuses "a guard pattern with shell characters is refused" "glob patterns" show --grant gpat
grant gcmd $'[guards.x]\ncommands = ["rm -rf"]'
refuses "a guard command with a space is refused" "plain command names" show --grant gcmd
grant allow0 $'[network]\nmode = "allow"'
refuses "mode allow with no entries is refused" "at least one" show --grant allow0
grant allowbad $'[network]\nmode = "allow"\nallow = ["evil host"]'
refuses "a malformed allow entry is refused" "is not a host" show --grant allowbad
grant devbad $'[devices]\npaths = ["/etc/passwd"]'
refuses "a device outside /dev is refused" "under /dev" show --grant devbad
grant rwmiss $'[mounts]\nrw = ["/nonexistent/delegate-test"]'
refuses "a missing rw mount is refused" "does not exist" show --grant rwmiss

# ---- 2. what each part produces
grant filt 'brief = "f"'
r=$(show --grant filt); check "default network is filtered" grep -q '"mode": "filtered"' <<< "$r"
grant lan $'[network]\nmode = "allow"\nallow = ["192.168.1.131:8080", "10.9.0.0/24", "printer.lan"]'
show --grant lan > "$T/lan.json"
net=$($G net "$T/lan.json")
check "allow mode carries its entries to the proxy" grep -q $'^allow\tnet|192.168.1.131/32|8080 net|10.9.0.0/24| host|printer.lan|\t' <<< "$net"
grant openg $'[network]\nmode = "open"'
check "open mode" grep -q '"mode": "open"' <(show --grant openg)
grant hostg $'[network]\nmode = "host"'
check "host mode" grep -q '"mode": "host"' <(show --grant hostg)
grant exact $'[devices]\npaths = ["/dev/null"]'
a=$(args_of --grant exact)
check "an exact device becomes one --device, nothing wider" bash -c '[ "$(printf "%s\n" "$1" | tr "\n" " ")" = "--device /dev/null:/dev/null " ] || [[ "$1" == *"--device"*"/dev/null:/dev/null"* && "$1" != *"cgroup"* && "$1" != *"/dev:/dev"* ]]' _ "$a"
grant reen $'[devices]\npaths = ["/dev/tty"]\nreenumerate = true'
a=$(args_of --grant reen)
check "reenumerate widens to that device's major only" bash -c '[[ "$1" == *"c 5:* rmw"* && "$1" == *"/dev:/dev"* && "$1" != *"166"* && "$1" != *"188"* ]]' _ "$a"
mkdir -p "$T/ro" "$T/rw"; chmod 755 "$T/ro" "$T/rw"
grant mnt $'[mounts]\nro = ["'"$T/ro"$'"]\nrw = ["'"$T/rw"$'"]\n[env]\nTHING_IP = "10.1.2.3"'
show --grant mnt > "$T/mnt.json"
check "ro mounts are listed for --read handling" grep -qx "$T/ro" <($G ro "$T/mnt.json")
check "rw mounts become a bind mount" grep -qx "$T/rw:$T/rw" <($G docker-args "$T/mnt.json")
check "env becomes -e" grep -qx "THING_IP=10.1.2.3" <($G docker-args "$T/mnt.json")
check "no output when a grant adds no docker args" bash -c '[ -z "$('"$G"' docker-args <('"$G"' resolve --dir '"$D"' --grant filt))" ]'

# ---- 3. combining
check "host beats allow, and names the grant" grep -q '"reason": "grant hostg"' <(show --grant lan --grant hostg)
check "open beats allow" grep -q '"mode": "open"' <(show --grant lan --grant openg)
grant lan2 $'[network]\nmode = "allow"\nallow = ["192.168.1.200"]'
show --grant lan --grant lan2 > "$T/lan2.json"
check "allow-lists merge" grep -q '192.168.1.200' <($G net "$T/lan2.json")
check "--egress open is a floor" grep -q '"mode": "open"' <(show --grant filt --egress open)
grant e1 $'[env]\nX_IP = "1"'; grant e2 $'[env]\nX_IP = "2"'
refuses "two grants setting one env var differently are refused" "grants disagree" show --grant e1 --grant e2

# ---- 4. guards (make_guard_shims from bin/delegate, extracted)
fn() { sed -n "/^$1() {/,/^}$/p" "$HERE/bin/delegate"; }
eval "$(fn grants_py)"; eval "$(fn grants_file)"; eval "$(fn make_guard_shims)"
DELEGATE_HOME=$HERE; ID=test-task; TASK_DIR="$T/task"; mkdir -p "$TASK_DIR" "$T/home" "$T/ev" "$T/bin"
printf '#!/bin/sh\necho "real tool ran: $*"\n' > "$T/bin/tool"; chmod +x "$T/bin/tool"
grant gtool $'[guards.danger]\ncommands = ["tool"]\nargs = ["write*", "erase"]\nnote = "Writing is blocked."'
show --grant gtool > "$(grants_file)"
shims=$(make_guard_shims "$T/home" "$T/ev")
check "a guard makes a shim" test -x "$shims/tool"
out=$(PATH="$shims:$T/bin:$PATH" tool write_flash 0x0 2>&1); rc=$?
check "the shim refuses a guarded argument (exit 3)" test "$rc" = 3
check "the refusal is logged for the report" grep -q 'danger: tool write_flash' "$T/ev/guard-refused.log"
out=$(PATH="$shims:$T/bin:$PATH" tool read_mac 2>&1)
check "an unguarded argument reaches the real tool" grep -q 'real tool ran: read_mac' <<< "$out"
show --grant gtool --allow danger > "$(grants_file)"
check "--allow lifts the guard (no shim)" test -z "$(make_guard_shims "$T/home" "$T/ev")"
refuses "--allow of a guard nobody granted is refused" "no granted guard" show --grant filt --allow danger
check "a guard's note reaches the prompt" grep -q 'Writing is blocked' <($G prompt <(show --grant gtool))

# ---- 5. locks (grant_lock / grant_unlock, extracted)
eval "$(fn grant_lock)"; eval "$(fn grant_unlock)"
die() { echo "die: $*"; return 1; }
DELEGATE_STATE="$T/state"; mkdir -p "$DELEGATE_STATE"
grant lk 'lock = "bench-1"'
TASK_DIR="$T/state/task-a"; mkdir -p "$TASK_DIR/lock"; ID=task-a; show --grant lk > "$(grants_file)"
grant_lock; check "the first task takes the lock" grep -qx task-a "$DELEGATE_STATE/locks/bench-1/owner"
TASK_DIR="$T/state/task-b"; mkdir -p "$TASK_DIR"; ID=task-b; show --grant lk > "$(grants_file)"
out=$(grant_lock 2>&1); check "a second live task is refused, with the holder named" grep -q 'in use by task task-a' <<< "$out"
rmdir "$T/state/task-a/lock"
grant_lock; check "a stale lock (holder not running) is taken over" grep -qx task-b "$DELEGATE_STATE/locks/bench-1/owner"
grant_unlock; check "unlock releases only our own lock" test ! -e "$DELEGATE_STATE/locks/bench-1"

# ---- 5b. no task (doctor's probe) and a task from before grants (exec, verify, continue)
eval "$(fn ensure_grants)"; eval "$(fn grants_resolve_args)"; eval "$(fn grant_net)"; eval "$(fn grant_allow)"; eval "$(fn grant_reads)"
out=$(TASK_DIR= EGRESS=open grant_net 2>&1); check "grant_net with no task is the --egress setting" test "$out" = open
out=$(TASK_DIR= READS="/a /b" grant_reads 2>&1); check "grant_reads with no task is --read" test "$out" = "/a /b"
TASK_DIR="$T/state/old-task"; mkdir -p "$TASK_DIR"; GRANTS=""; ALLOW=""; ORB_FILE=""; EGRESS=filtered; READS=""
DELEGATE_GRANTS_DIR=$D; DELEGATE_RUNNER=docker
out=$(grant_net 2>&1); check "a task from before grants resolves on first use" test "$out" = filtered
check "... and keeps the resolution" test -s "$TASK_DIR/grants.json"

# ---- 6. the built-in orb grant vs the pre-grants --orb arguments
orbf="$T/orb-target"; printf 'ORB_LABEL=desk\nORB_BASE_MAC=AA:BB:CC:DD:EE:FF\nORB_SERIAL=/dev/serial/by-id/usb-not-attached-delegate-test\nORB_IP=192.168.1.50\n' > "$orbf"
show --orb-file "$orbf" > "$T/orb.json"
gid=$(getent group dialout | cut -d: -f3)
# what run_worker_docker passed before grants, for an orb whose serial port is not attached
old=$(printf '%s\n' -v /dev:/dev --device-cgroup-rule 'c 166:* rmw' --device-cgroup-rule 'c 188:* rmw' \
  -e ORB_LABEL=desk -e ORB_BASE_MAC=AA:BB:CC:DD:EE:FF -e ORB_SERIAL=/dev/serial/by-id/usb-not-attached-delegate-test \
  -e ORB_IP=192.168.1.50 ${gid:+--group-add $gid} | paste - - | sort)
new=$($G docker-args "$T/orb.json" | paste - - | sort)
check "--orb (port not attached): the same docker args as before grants" test "$old" = "$new"
check "--orb is on the host network" grep -q $'^host\t' <($G net "$T/orb.json")
check "--orb locks by MAC" grep -q '^orb-aabbccddeeff' <($G locks "$T/orb.json")
check "--orb guards flashing, with the old note" grep -q 'Flashing is BLOCKED' <($G prompt "$T/orb.json")
check "--orb probes the serial port" grep -q 'NOT attached' <($G prompt "$T/orb.json")
check "--orb with --allow flash lifts the guard" bash -c '! '"$G"' prompt <('"$G"' resolve --dir '"$D"' --orb-file '"$orbf"' --allow flash) | grep -q BLOCKED'
chmod 644 "$orbf"
grant desk $'kind = "orb"\ntarget = "'"$orbf"$'"'
check "kind = orb names the same built-in" bash -c 'diff <('"$G"' docker-args <('"$G"' resolve --dir '"$D"' --grant desk) | paste - - | sort) <(printf "%s\n" "$1")' _ "$new"
grant deskx $'kind = "orb"\ntarget = "'"$orbf"$'"\n[network]\nmode = "open"'
refuses "a kind = orb grant can't add its own access" "takes only target" show --grant deskx

# ---- 7. continue keeps its access
out=$("$HERE/bin/delegate" continue some-task --grant x -m hi 2>&1)
check "continue refuses --grant" grep -q "can't change a task's access" <<< "$out"
out=$("$HERE/bin/delegate" continue some-task --allow flash -m hi 2>&1)
check "continue refuses --allow" grep -q "can't change a task's access" <<< "$out"

# ---- 8. the per-task allow-list proxy (docker)
if [ "${DOCKER:-0}" = 1 ]; then
  tag=delegate-egress:grants-test-$$ net=delegate-grants-test-$$
  CLEAN="docker rm -f $net-a $net-b $net-px >/dev/null 2>&1; docker network rm $net >/dev/null 2>&1; docker image rm $tag >/dev/null 2>&1"
  docker build -q -t "$tag" -f "$HERE/worker/egress.Dockerfile" "$HERE" >/dev/null
  docker network create "$net" >/dev/null
  for s in a b; do docker run -d --name "$net-$s" --network "$net" python:3-alpine python -m http.server 8000 >/dev/null; done
  sleep 3
  ipa=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$net-a")
  ipb=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$net-b")
  grant lanp $'[network]\nmode = "allow"\nallow = ["'"$ipa"$':8000"]'
  lan=$($G net <(show --grant lanp) | cut -f2)
  docker run -d --name "$net-px" --network "$net" -e DELEGATE_LAN_ALLOW="$lan" "$tag" >/dev/null; sleep 3
  c() { docker run --rm --network "$net" -e http_proxy="http://$net-px:3128" curlimages/curl:8.11.1 -s -o /dev/null -m 10 -w '%{http_code}' "$1"; }
  check "the allow proxy reaches the granted LAN address" test "$(c "http://$ipa:8000/")" = 200
  check "the allow proxy refuses an ungranted LAN address" test "$(c "http://$ipb:8000/")" = 403
  check "the allow proxy refuses the granted host on another port" test "$(c "http://$ipa:9999/")" = 403
else
  echo "skip  the allow proxy (DOCKER=1 to run it)"
fi

echo
echo "grants: $pass passed, $fail failed"
[ "$fail" = 0 ]
