#!/bin/bash
# A repo's own image (.delegate/Dockerfile), and the login-shell PATH fix (0.8.6).
#
# Two failures this pins. A worker whose image HAD Go answered "go: command not found": every
# verify and exec runs `bash -lc`, and /etc/profile reset PATH, dropping the image's Go and clang
# AND the guard shims the runner puts first. And the image was picked per command by an export,
# so one command without it ran in the plain image. The functions run from bin/delegate's own
# text against a fake docker that keeps real image labels.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
B=$T/bin; W=$T/world; mkdir -p "$B" "$W/img"

# fake docker: $W/img/<tag> holds "stamp=…" and "layer=…" lines; builds record their argv
cat > "$B/docker" <<'FAKE'
#!/bin/bash
W=${FAKE_WORLD:?}; echo "$*" >> "$W/calls"
case "$1 $2" in
  "image inspect")
    if [ "$3" = -f ]; then t=$5; f=$W/img/${t//\//_}; [ -f "$f" ] || exit 1
      case "$4" in
        *io.delegate.layer*) sed -n 's/^layer=//p' "$f" ;;
        *io.delegate.stamp*) sed -n 's/^stamp=//p' "$f" ;;
      esac; exit 0
    fi
    [ -f "$W/img/${3//\//_}" ] ;;
  "volume create"|"run --rm") exit 0 ;;
esac
if [ "$1" = build ]; then
  shift; tag="" stamp="" layer=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -t) tag=$2; shift 2 ;;
      --label) case "$2" in io.delegate.stamp=*) stamp=${2#*=};; io.delegate.layer=*) layer=${2#*=};; esac; shift 2 ;;
      *) shift ;;
    esac
  done
  { echo "stamp=$stamp"; [ -z "$layer" ] || echo "layer=$layer"; } > "$W/img/${tag//\//_}"
fi
exit 0
FAKE
chmod +x "$B/docker"

fns=$(sed -n -e '/^die()/p' -e '/^note()/p' -e '/^untrusted()/p' \
  -e '/^context_stamp() {/,/^}/p' -e '/^repo_image_name() {/,/^}/p' -e '/^repo_layer_stamp() {/,/^}/p' \
  -e '/^choose_image() {/,/^}/p' -e '/^image_layer() {/,/^}/p' -e '/^image_stamp() {/,/^}/p' \
  -e '/^image_freshness() {/,/^}/p' -e '/^check_image_fresh() {/,/^}/p' -e '/^cmd_build() {/,/^}/p' \
  "$here/bin/delegate")
for f in choose_image repo_image_name repo_layer_stamp image_freshness check_image_fresh cmd_build; do
  check "$f is in bin/delegate" 'printf "%s" "$fns" | grep -q "^$f() {"'
done
run() { PATH="$B:$PATH" FAKE_WORLD=$W DELEGATE_HOME=$here DELEGATE_RUNNER=docker \
        DELEGATE_BASE_IMAGE=delegate-worker:local DELEGATE_IMAGE=delegate-worker:local \
        DELEGATE_EGRESS_IMAGE=delegate-egress:local DELEGATE_EGRESS=filtered DELEGATE_UNTRUSTED_REPO=${UNTR:-0} \
        DELEGATE_IMAGE_CALLER=${CALLER:-} DELEGATE_IMAGE_STALE=error DELEGATE_IMAGE_ALLOW_STALE=0 \
        bash -c "set -euo pipefail; $fns
$1" 2>&1; }

repo() { local r=$T/$1; mkdir -p "$r"; git -C "$r" init -q; echo "$r"; }
plain=$(repo plain); gorb=$(repo "Gorb OS-2")
mkdir -p "$gorb/.delegate"
printf 'ARG BASE=delegate-worker:local\nFROM ${BASE}\nRUN go version\n' > "$gorb/.delegate/Dockerfile"

# -- naming and choosing ----------------------------------------------------------------
check "a repo's image is named for it, lowercased and tag-safe" \
  '[ "$(run "repo_image_name \"$gorb\"")" = "delegate-worker-gorb-os-2:local" ]'
check "a repo with no .delegate/Dockerfile runs in the base" \
  '[ "$(run "choose_image \"$plain\"; echo \$DELEGATE_IMAGE \${IMAGE_REPO:-none}")" = "delegate-worker:local none" ]'
check "a repo with one runs in its own image" \
  '[ "$(run "choose_image \"$gorb\"; echo \$DELEGATE_IMAGE")" = "delegate-worker-gorb-os-2:local" ]'
check "the caller's explicit DELEGATE_IMAGE still wins" \
  '[ "$(CALLER=mine:1 run "choose_image \"$gorb\"; echo \$DELEGATE_IMAGE \${IMAGE_REPO:-none}")" = "mine:1 none" ]'
check "an untrusted repo's Dockerfile is never chosen" \
  '[ "$(UNTR=1 run "choose_image \"$gorb\"; echo \$DELEGATE_IMAGE")" = "delegate-worker:local" ]'

# -- building ---------------------------------------------------------------------------
out=$(run 'cmd_build --repo "'"$gorb"'"')
check "build --repo builds the base, then the repo layer FROM it, from .delegate/ alone" \
  'grep -q -- "--build-arg BASE=delegate-worker:local -t delegate-worker-gorb-os-2:local -f $gorb/.delegate/Dockerfile $gorb/.delegate" "$W/calls"'
check "and says so" 'printf "%s" "$out" | grep -q "built delegate-worker-gorb-os-2:local"'
check "a fresh repo image is fresh" \
  '[ "$(run "IMAGE_REPO=\"$gorb\"; image_freshness delegate-worker-gorb-os-2:local \"$gorb\"")" = fresh ]'
echo "RUN clang --version" >> "$gorb/.delegate/Dockerfile"
check "editing .delegate/ makes it stale" \
  '[ "$(run "image_freshness delegate-worker-gorb-os-2:local \"$gorb\"")" = stale ]'
check "and a run refuses it, naming the build that fixes it" \
  'run "IMAGE_REPO=\"$gorb\"; DELEGATE_IMAGE=delegate-worker-gorb-os-2:local; check_image_fresh" | grep -q "delegate build --repo $gorb"'
check "build --repo on a repo without one is refused" \
  'run "cmd_build --repo \"$plain\"" | grep -q "has no .delegate/Dockerfile"'
check "build --repo of an untrusted repo is refused" \
  'UNTR=1 run "cmd_build --repo \"$gorb\"" | grep -q "does not get its Dockerfile built"'

# -- load_task: the recorded image, for every later command -------------------------------
lt=$(sed -n '/^load_task() {/,/^}/p' "$here/bin/delegate")
check "load_task is in bin/delegate" 'printf "%s" "$lt" | grep -q "^load_task() {"'
mk_task() { # ID KEY=VALUE... — written as bin/delegate writes it, each value %q-quoted
  local d=$T/state/$1 kv; mkdir -p "$d"; : > "$d/meta.env"
  for kv in "${@:2}"; do printf '%s=%q\n' "${kv%%=*}" "${kv#*=}" >> "$d/meta.env"; done
}
printf '%s\n' "$lt" > "$T/load_task.sh"
lrun() { run "task_dir() { echo \"$T/state/\$1\"; }; . \"$T/load_task.sh\"
load_task $1; echo \$DELEGATE_IMAGE"; }
mk_task t1 "REPO=$plain" "IMAGE=delegate-worker-gorb-os-2:local" "IMAGE_REPO=$gorb"
check "a task runs in the image recorded at run, whatever the repo holds now" \
  '[ "$(lrun t1 | tail -1)" = "delegate-worker-gorb-os-2:local" ]'
mk_task t2 "REPO=$gorb"
check "a task from before IMAGE was recorded takes its repo's own" \
  '[ "$(lrun t2 | tail -1)" = "delegate-worker-gorb-os-2:local" ]'
check "and an explicit caller image overrides a recorded one" \
  '[ "$(CALLER=mine:1 lrun t1 | tail -1)" = "mine:1" ]'

# -- the login-shell PATH ------------------------------------------------------------------
check "the image installs the PATH restorer root-owned under /etc/profile.d" \
  'grep -q "COPY --chmod=644 worker/profile-path.sh /etc/profile.d/zz-delegate-path.sh" "$here/worker/Dockerfile"'
check "the entrypoint records the starting PATH before it execs" \
  'awk "/export DELEGATE_PATH=\"\\\$PATH\"/{a=NR} /^exec \"\\\$@\"/{b=NR} END{exit !(a && b && a<b)}" "$here/worker/entrypoint.sh"'
got=$(env -i DELEGATE_PATH=/home/worker/.delegate-shims:/usr/local/go/bin:/usr/bin:/bin \
      bash -c 'PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games; . "'"$here"'/worker/profile-path.sh"; echo "$PATH"')
check "after /etc/profile's reset, the shims and the image's tools come back first" \
  '[ "$got" = "/home/worker/.delegate-shims:/usr/local/go/bin:/usr/bin:/bin" ]'
got=$(env -i bash -c 'PATH=/usr/bin:/bin; . "'"$here"'/worker/profile-path.sh"; echo "$PATH"')
check "with nothing recorded it leaves PATH alone" '[ "$got" = "/usr/bin:/bin" ]'

if [ "${DOCKER:-0}" = 1 ]; then
  img=${DELEGATE_IMAGE:-delegate-worker:local}
  # as the runner starts it: a per-task HOME the entrypoint writes into, and what it renders from
  h=$T/live-home; mkdir -p "$h"; echo dummy > "$T/key"
  got=$(docker run --rm --user "$(id -u):$(id -g)" -v "$h:/home/worker" -v "$T/key:/run/secrets/delegate_key:ro" \
        -e DELEGATE_API_KEY_FILE=/run/secrets/delegate_key -e DELEGATE_BASE_URL=http://127.0.0.1:1/v1 \
        -e DELEGATE_MODEL=m -e DELEGATE_MODEL_HARD=m -e DELEGATE_CONTEXT=1000 -e DELEGATE_OUTPUT=100 \
        -e PATH=/opt/probe:/usr/local/bin:/usr/bin:/bin "$img" bash -lc 'echo $PATH' | tail -1)
  check "live: a login shell in $img keeps the container's PATH" '[ "${got%%:*}" = /opt/probe ]'
fi

exit $fail
