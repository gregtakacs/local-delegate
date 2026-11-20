#!/bin/bash
# lib/pinlint.py: a project's .delegate/Dockerfile must pin every add it installs.
#
# Why: the project image is part of the toolchain contract. gorb-os built its worker by hand,
# installing clang-21/lld-21 from apt.llvm.org with only the MAJOR pinned, while its shelf check
# is byte-for-byte on clang's output — so any silent rebuild could change what the gate compares.
# pinlint flags each unpinned add; `delegate build --repo` refuses on any finding.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PL="python3 $here/lib/pinlint.py"

# c NAME BODY -> writes header + body (body supports \n and \ via %b), runs the lint -> F OUT RC
c(){ F="$T/$1"; mkdir -p "$F"
  { printf 'ARG BASE=delegate-worker:local\nFROM ${BASE}\n'; printf '%b\n' "$2"; } > "$F/Dockerfile"
  OUT=$($PL "$F/Dockerfile" 2>&1); RC=$?; }

# -- FROM ------------------------------------------------------------------------------
c from_bad 'FROM ubuntu:22.04'
check "FROM: a non-base image is flagged" '[ "$RC" = 1 ] && grep -qE "FROM:.*ubuntu:22.04" <<<"$OUT"'
c from_ok 'FROM node@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
check "FROM: a @sha256-pinned image, and the \$BASE ARG form, are clean" '[ "$RC" = 0 ] && ! grep -q FROM: <<<"$OUT"'

# -- apt -------------------------------------------------------------------------------
c apt_bad 'RUN apt-get install -y clang-21 lld-21'
check "apt: packages without = are flagged" '[ "$RC" = 1 ] && grep -qE "apt-get install.*clang-21 lld-21" <<<"$OUT"'
c apt_ok 'RUN apt-get install -y clang-21=1:21.1.3-1 lld-21=1:21.1.3-1'
check "apt: version-pinned packages are clean" '[ "$RC" = 0 ]'
c apt_t 'RUN apt-get install -y -t bookworm-backports bar'
check "apt: an option value is not mistaken for a package" '[ "$RC" = 1 ] && grep -qE "not pinned with =: bar$" <<<"$OUT" && ! grep -q bookworm-backports <<<"$OUT"'
c apt_update 'RUN apt-get update && apt-get install -y foo=1.0'
check "apt: apt-get update is not an install" '[ "$RC" = 0 ]'

# -- pip -------------------------------------------------------------------------------
c pip_bad 'RUN pip install requests && pip3 install click'
check "pip: unpinned requirements are flagged" '[ "$RC" = 1 ] && grep -q requests <<<"$OUT" && grep -q click <<<"$OUT"'
c pip_ok 'RUN pip install requests==2.32.3 && pip3 install click==8.1.7'
check "pip: ==-pinned requirements are clean" '[ "$RC" = 0 ]'
c pip_m 'RUN python3 -m pip install --break-system-packages --no-cache-dir numpy==1.26.4'
check "pip: python -m pip, flags ignored, pinned is clean" '[ "$RC" = 0 ]'
c pip_m2 'RUN python3 -m pip install numpy'
check "pip: python -m pip, unpinned is flagged" '[ "$RC" = 1 ] && grep -qE "pip install.*numpy" <<<"$OUT"'
c pip_url 'RUN pip install "pkg @ https://x/y.whl#sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
check "pip: a #sha256-pinned URL requirement is clean" '[ "$RC" = 0 ]'

# -- npm -------------------------------------------------------------------------------
c npm_bad 'RUN npm install -g typescript'
check "npm -g: no version is flagged" '[ "$RC" = 1 ] && grep -qE "npm install -g.*typescript" <<<"$OUT"'
c npm_range 'RUN npm install -g eslint@latest'
check "npm -g: a floating tag is flagged" '[ "$RC" = 1 ] && grep -qE "not pinned to @<exact version>: eslint@latest" <<<"$OUT"'
c npm_ok 'RUN npm i -g typescript@5.4.5 && npm install -g @scope/pkg@1.2.3'
check "npm -g: exact versions are clean" '[ "$RC" = 0 ]'

# -- curl / wget -----------------------------------------------------------------------
c curl_bad 'RUN curl -fsSL https://get.example.com/install.sh -o /tmp/i.sh'
check "curl: a versionless, unchecked fetch is flagged" '[ "$RC" = 1 ] && grep -qE "curl:.*install.sh" <<<"$OUT"'
c curl_ver 'RUN curl -fsSL https://example.com/tool-1.2.3.tar.gz | tar xz'
check "curl: a versioned URL is clean" '[ "$RC" = 0 ]'
c curl_sha 'RUN curl -fsSL https://example.com/t.tgz -o t.tgz && echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  t.tgz" | sha256sum -c -'
check "curl: a following sha256sum -c clears the fetch" '[ "$RC" = 0 ]'
c wget_ver 'RUN wget -q https://example.com/x-9.8.sh -O /tmp/x.sh'
check "wget: a versioned URL is clean" '[ "$RC" = 0 ]'

# -- git clone -------------------------------------------------------------------------
c git_bad 'RUN git clone https://github.com/o/r.git'
check "git: a bare clone is flagged" '[ "$RC" = 1 ] && grep -qE "git clone:.*no --branch" <<<"$OUT"'
c git_main 'RUN git clone --branch main https://github.com/o/r.git'
check "git: --branch main counts as unpinned" '[ "$RC" = 1 ] && grep -qE "git clone:.*moving ref" <<<"$OUT"'
c git_tag 'RUN git clone --branch v1.2.3 https://github.com/o/r.git'
check "git: --branch <tag> is clean" '[ "$RC" = 0 ]'
c git_co 'RUN git clone https://github.com/o/r.git /r && cd /r && git checkout 1a2b3c4'
check "git: a following git checkout <sha> is clean" '[ "$RC" = 0 ]'

# -- continuations join into one logical line ------------------------------------------
c cont 'RUN apt-get install -y \\\n      clang \\\n      python3-dev'
check "continuation: a multi-line install is ONE finding at its start line" \
  '[ "$RC" = 1 ] && [ "$(grep -c "apt-get install" <<<"$OUT")" = 1 ] && grep -qE ":3: apt-get install.*clang python3-dev" <<<"$OUT"'

# -- ARG defaults count as the value ---------------------------------------------------
c arg 'ARG GO_VERSION=1.27.2\nRUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xz'
check "ARG: a URL carrying \${GO_VERSION}=1.27.2 is pinned" '[ "$RC" = 0 ] && ! grep -q "go.dev" <<<"$OUT"'

# -- the unpinned-ok marker ------------------------------------------------------------
c marker_ok 'RUN apt-get install -y clang-21  # delegate: unpinned-ok apt.llvm.org ships only the major'
check "marker: a justified unpinned-ok is allowed, not flagged" \
  '[ "$RC" = 0 ] && grep -qE "allowed: apt.llvm.org ships only the major" <<<"$OUT" && ! grep -q "apt-get install:" <<<"$OUT"'
c marker_lead '# delegate: unpinned-ok the vendor publishes no stable tarball\nRUN curl -fsSL https://get.example.com/install.sh | sh'
check "marker: a leading comment line carries the allowance" \
  '[ "$RC" = 0 ] && grep -qE "allowed: the vendor publishes no stable tarball" <<<"$OUT"'
c marker_empty 'RUN apt-get install -y clang-21  # delegate: unpinned-ok'
check "marker: an empty reason is refused, and the add is still flagged" \
  '[ "$RC" = 1 ] && grep -qE "unpinned-ok.*no reason" <<<"$OUT" && grep -qE "apt-get install.*clang-21" <<<"$OUT"'

# -- the pip -r FILE case --------------------------------------------------------------
rfile(){ local d="$T/$1"; mkdir -p "$d"
  printf 'ARG BASE=delegate-worker:local\nFROM ${BASE}\nRUN pip install -r requirements.txt\n' > "$d/Dockerfile"; echo "$d"; }
d=$(rfile r_ok);  printf 'requests==2.0.0\nflask==3.0.0  # trailing\n\n' > "$d/requirements.txt"
OUT=$($PL "$d/Dockerfile" 2>&1); RC=$?
check "-r: a fully ==-pinned file is clean" '[ "$RC" = 0 ]'
d=$(rfile r_bad); printf 'requests==2.0.0\nflask\n' > "$d/requirements.txt"
OUT=$($PL "$d/Dockerfile" 2>&1); RC=$?
check "-r: an unpinned line in the file is flagged" '[ "$RC" = 1 ] && grep -qE "pip install -r.*not ==-pinned: flask" <<<"$OUT"'
d="$T/r_miss"; mkdir -p "$d"
printf 'ARG BASE=delegate-worker:local\nFROM ${BASE}\nRUN pip install -r absent.txt\n' > "$d/Dockerfile"
OUT=$($PL "$d/Dockerfile" 2>&1); RC=$?
check "-r: a file missing from the build context is flagged" '[ "$RC" = 1 ] && grep -q "not in the build context" <<<"$OUT"'

# -- gorb-os's real, hand-built image --------------------------------------------------
GORB="$here/tests/fixtures/pinlint/gorb.Dockerfile"
OUT=$($PL "$GORB" 2>&1); RC=$?
check "gorb: the hand-built image is refused (exit 1)" '[ "$RC" = 1 ]'
check "gorb: flags clang-21 lld-21 (the byte-for-byte gate)" 'grep -qE "apt-get install.*clang-21 lld-21" <<<"$OUT"'
check "gorb: flags the unversioned apt set" 'grep -q "gnupg zlib1g-dev python3-pil python3-numpy tzdata" <<<"$OUT"'
check "gorb: flags the second unversioned apt set" 'grep -q "flex bison gperf cmake" <<<"$OUT"'
check "gorb: does NOT flag the ==-pinned pip install" '! grep -q "pip install" <<<"$OUT"'
check "gorb: does NOT flag --branch v5.5.6 git clone" '! grep -q "git clone" <<<"$OUT"'
check "gorb: does NOT flag the go tarball pinned via ARG GO_VERSION" '! grep -q "go.dev" <<<"$OUT"'

# ======================================================================================
# `delegate build --repo` refuses an unpinned .delegate/Dockerfile BEFORE building, and
# `DELEGATE_PINLINT=warn` downgrades that to a warning. Same shape as test_repo_image.sh:
# a fake docker that records its argv, and cmd_build run from bin/delegate's own text.
B=$T/bin; W=$T/world; mkdir -p "$B" "$W/img"
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
  -e '/^image_freshness() {/,/^}/p' -e '/^cmd_build() {/,/^}/p' \
  "$here/bin/delegate")
bld(){ # [PINLINT] REPO — runs cmd_build --repo REPO; sets OUT and RC
  local pin=$1; shift; : > "$W/calls"
  OUT=$(PATH="$B:$PATH" FAKE_WORLD=$W DELEGATE_HOME=$here DELEGATE_RUNNER=docker \
    DELEGATE_BASE_IMAGE=delegate-worker:local DELEGATE_IMAGE=delegate-worker:local \
    DELEGATE_EGRESS_IMAGE=delegate-egress:local DELEGATE_EGRESS=filtered DELEGATE_UNTRUSTED_REPO=0 \
    DELEGATE_IMAGE_CALLER= DELEGATE_IMAGE_STALE=error DELEGATE_IMAGE_ALLOW_STALE=0 \
    DELEGATE_PINLINT=$pin \
    bash -c "set -euo pipefail; $fns
cmd_build --repo \"$1\"" 2>&1); RC=$?; }

mkrepo(){ local r=$T/$1; mkdir -p "$r/.delegate"; git -C "$r" init -q
  printf 'ARG BASE=delegate-worker:local\nFROM ${BASE}\n%s\n' "$2" > "$r/.delegate/Dockerfile"; echo "$r"; }
badr=$(mkrepo badrepo 'RUN apt-get install -y clang-21 lld-21')
okrepo=$(mkrepo okrepo 'RUN apt-get install -y clang-21=1:21.1.3-1')

bld error "$badr"
check "build --repo refuses an unpinned Dockerfile (exit 2)" '[ "$RC" = 2 ]'
check "  and prints the lint line and the fix on stderr" \
  'grep -q "clang-21 lld-21" <<<"$OUT" && grep -q "not fully pinned" <<<"$OUT"'
check "  and builds nothing, before the refusal" '! grep -q -- "-t delegate-worker-badrepo" "$W/calls"'
bld "" "$badr"
check "the refusal is the default (DELEGATE_PINLINT unset = error)" '[ "$RC" = 2 ]'
bld warn "$badr"
check "DELEGATE_PINLINT=warn downgrades to a warning and still builds" \
  '[ "$RC" = 0 ] && grep -q "unpinned installs" <<<"$OUT" && grep -q -- "-t delegate-worker-badrepo" "$W/calls"'
bld error "$okrepo"
check "a fully pinned repo Dockerfile builds, refused by nothing" \
  '[ "$RC" = 0 ] && grep -q "built delegate-worker-okrepo:local" <<<"$OUT"'

# -- doctor: a hand-built repo image (not the base, no repo-layer stamp) ---------------
dblock=$(sed -n '/if docker image inspect/,/MISSING/p' "$here/bin/delegate")$'\n    fi'
printf 'stamp=\n' > "$W/img/delegate-worker-gorb:local"          # present, unstamped, NO layer label
dout=$(PATH="$B:$PATH" FAKE_WORLD=$W DELEGATE_HOME=$here DELEGATE_RUNNER=docker \
  DELEGATE_BASE_IMAGE=delegate-worker:local DELEGATE_IMAGE=delegate-worker-gorb:local \
  bash -c "set -uo pipefail; $fns
doctor_image(){ local ok=1; $dblock; echo \"OK=\$ok\"; }; doctor_image" 2>&1)
check "doctor names a hand-built repo image and gives the one-line fix" \
  'grep -q "built by hand" <<<"$dout" && grep -q "move its Dockerfile to .delegate/Dockerfile and run: delegate build --repo" <<<"$dout" && grep -q "OK=0" <<<"$dout"'
printf 'stamp=\nlayer=deadbeef\n' > "$W/img/delegate-worker-gorb:local"   # a stamp-carrying repo build
dout=$(PATH="$B:$PATH" FAKE_WORLD=$W DELEGATE_HOME=$here DELEGATE_RUNNER=docker \
  DELEGATE_BASE_IMAGE=delegate-worker:local DELEGATE_IMAGE=delegate-worker-gorb:local \
  bash -c "set -uo pipefail; $fns
doctor_image(){ local ok=1; $dblock; echo \"OK=\$ok\"; }; doctor_image" 2>&1)
check "doctor stays quiet about hand-building once the layer stamp is there" \
  '! grep -q "built by hand" <<<"$dout"'

exit $fail
