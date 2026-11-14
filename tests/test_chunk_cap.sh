#!/bin/bash
# chunk-cap.js honours DELEGATE_CHUNK_CAP (default 8000, Cline's own is 6000; invalid or < 1000 -> 8000).
# Runs the plugin's hook in node inside the worker image, since the host may have no node.
# Also: with no config, bin/delegate hands workers 8000 (delegate's default); a config value wins.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
cap_of() { env -u DELEGATE_CHUNK_CAP DELEGATE_CONFIG="$1" "$here/bin/delegate" doctor 2>/dev/null | grep -o 'edit cap: [0-9]*'; }
cfg=$(mktemp); echo 'DELEGATE_CHUNK_CAP=7000' > "$cfg"
got=$(cap_of /nonexistent); [ "$got" = "edit cap: 8000" ] && echo "ok   no config -> 8000" || { echo "FAIL no config -> 8000 (got: $got)"; exit 1; }
got=$(cap_of "$cfg"); rm -f "$cfg"; [ "$got" = "edit cap: 7000" ] && echo "ok   config 7000 wins" || { echo "FAIL config 7000 wins (got: $got)"; exit 1; }
img=${DELEGATE_IMAGE:-delegate-worker:local}
if ! docker image inspect "$img" >/dev/null 2>&1; then echo "skip: no $img image (delegate build)"; exit 0; fi
fail=0
probe() { # cap-env-or-"unset" tool field size -> prints "ok" or "rejected:<limit in message>"
  local envarg=(); [ "$1" != unset ] && envarg=(-e "DELEGATE_CHUNK_CAP=$1")
  docker run --rm "${envarg[@]}" -v "$here/opencode/plugins/chunk-cap.js:/p/chunk-cap.mjs:ro" \
    --entrypoint node "$img" --input-type=module -e "
      const { ChunkCap } = await import('/p/chunk-cap.mjs');
      const h = await ChunkCap();
      const args = { ['$3']: 'x'.repeat($4) };
      try { await h['tool.execute.before']({ tool: '$2', args }, {}); console.log('ok'); }
      catch (e) { console.log('rejected:' + (e.message.match(/limit of (\d+)/) || [])[1]); }"
}
check() { local got; got=$(probe "$1" "$2" "$3" "$4"); if [ "$got" = "$5" ]; then echo "ok   cap=$1 $2.$3=$4 -> $got"; else echo "FAIL cap=$1 $2.$3=$4 -> $got (want $5)"; fail=1; fi; }
check unset write content    8000 ok
check unset write content    8001 rejected:8000
check 8000  write content    7999 ok
check 8000  write content    8000 ok
check 8000  write content    8001 rejected:8000
check 8000  edit  newString  8500 rejected:8000
check 8000  edit  oldString  8500 rejected:8000
check 8000  bash  command    50000 ok
check junk  write content    8001 rejected:8000
check 500   write content    8001 rejected:8000
exit $fail
