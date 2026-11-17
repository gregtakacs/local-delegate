#!/usr/bin/env bash
# SG-3: DELEGATE_UNTRUSTED_REPO=1 (off by default) runs the worker's git and path steps inside
# the throwaway sandbox container, so every host-side step that touches the repository has to
# refuse. This suite proves each refusal fires and that nothing before it shells out to host git
# or talks to docker: a stub `docker` that fails the run (exit 99) and logs its argv stands at
# the front of PATH, and an EMPTY log means no host docker call happened on the refused paths.
# No docker and no network are needed.
#
# The ACCEPTED paths of the contract deliberately run to the end of the sandbox setup — that is
# how we know the checks passed — and reach only the docker stub (rc 99). Refused paths exit 1
# before any container: a refusal never reaches the stub. The stub's exit 99 is the acceptance
# signal.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

T="$(mktemp -d)"
cleanup() {
  [[ -d "$T" ]] && { chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"; }
  return 0
}
trap cleanup EXIT
export TMPDIR="$T"                      # mktemp -d inside the tests uses the sandbox too
mkdir -p "$T/home" "$T/logs" "$T/state" "$T/wt" "$T/config" "$T/grants" "$T/bin"

# A stub docker that fails the run and logs its argv. A refusal must leave it empty; an accepted
# path must have appended the sandbox `docker run` to it.
{
  printf '%s\n' '#!/usr/bin/env bash' \
    '{ printf docker; for a in "$@"; do printf " %q" "$a"; done; printf "\\n"; } >>"$DELEGATE_TEST_DOCKER_LOG"' \
    'exit 99'
} >"$T/bin/docker"
chmod +x "$T/bin/docker"
export DELEGATE_TEST_DOCKER_LOG="$T/logs/docker.log"
: >"$DELEGATE_TEST_DOCKER_LOG"

# A stub chain runner, so the CLI never needs the real chain.py python bootstrap. The chain
# refusals under test fire in bin/delegate before the runner is ever invoked.
{
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "chain ran: $*" >>"$DELEGATE_TEST_CHAIN_LOG"' \
    'exit 0'
} >"$T/bin/delegate-chain-stub"
chmod +x "$T/bin/delegate-chain-stub"
export DELEGATE_TEST_CHAIN_LOG="$T/logs/chain.log"
: >"$DELEGATE_TEST_CHAIN_LOG"

# A fake model endpoint on a refused port: reaching the network check fails fast and loudly.
export DELEGATE_TEST_ENDPOINT="http://127.0.0.1:1/v1"
printf 'dummy-key\n' >"$T/key"
chmod 600 "$T/key"

# The environment every refused and accepted run sees. HOME and the state dirs are fresh per
# run; the config file is empty so nothing sneaks in from a real config.
base_env() {
  printf '%s\n' \
    "HOME=$T/home" \
    "PATH=$T/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "DELEGATE_CONFIG=$T/config/env" \
    "DELEGATE_STATE=$T/state" \
    "DELEGATE_WORKTREES=$T/wt" \
    "DELEGATE_GRANTS_DIR=$T/grants" \
    "DELEGATE_PROGRESS=0" \
    "DELEGATE_PRUNE_DAYS=0" \
    "DELEGATE_IMAGE_ALLOW_STALE=1" \
    "DELEGATE_PROBE_TIMEOUT=1" \
    "DELEGATE_BASE_URLS=$DELEGATE_TEST_ENDPOINT" \
    "DELEGATE_MODEL=stub-model" \
    "DELEGATE_API_KEY_FILE=$T/key" \
    "DELEGATE_CHAIN_BIN=$T/bin/delegate-chain-stub" \
    "DELEGATE_TEST_DOCKER_LOG=$DELEGATE_TEST_DOCKER_LOG" \
    "DELEGATE_TEST_CHAIN_LOG=$DELEGATE_TEST_CHAIN_LOG"
}

# run_as VAR=VAL... -- CMD ARGS: the environment base plus the overrides, argv without a shell.
# env takes the last value of a repeated name, so overrides win. Nothing from the ambient
# environment (a worker's own DELEGATE_* setup, proxies) leaks in.
run_as() {
  local envs=()
  while [[ $# -gt 0 && "$1" != '--' ]]; do envs+=("$1"); shift; done
  shift
  : >"$DELEGATE_TEST_DOCKER_LOG"          # each case proves what *that* invocation touched
  : >"$DELEGATE_TEST_CHAIN_LOG"
  local -a kv=()
  while IFS= read -r line; do kv+=("$line"); done < <(base_env)
  OUT="$(env -i "${kv[@]}" "${envs[@]}" bash -c 'exec "$@"' _ "$@" 2>&1)"
  RC=$?
}

# refused LABEL NEEDLE ENV... -- CMD ARGS: must exit 1 with NEEDLE (fixed string) in the output,
# and touch neither the docker stub nor the chain stub before refusing.
refused() {
  local label="$1" needle="$2"; shift 2
  RC=0; OUT=""
  run_as "$@"
  [[ $RC -eq 1 ]] || die "$label: expected exit 1, got $RC: $OUT"
  check "$label" grep -qF -- "$needle" <<<"$OUT"
  [[ -s "$DELEGATE_TEST_DOCKER_LOG" ]] && die "$label: docker was invoked before refusing: $(cat "$DELEGATE_TEST_DOCKER_LOG")"
  [[ -s "$DELEGATE_TEST_CHAIN_LOG" ]] && die "$label: the chain runner was invoked before refusing"
  return 0
}

# accepted_to_sandbox LABEL ENV... -- CMD ARGS: must get all the way into the sandbox setup and
# die only on the stubbed container: the docker log holds the sandbox `docker run`, and nothing
# on stderr is an untrusted refusal. Refused paths never reach the stub at all.
accepted_to_sandbox() {
  local label="$1"; shift
  RC=0; OUT=""
  run_as "$@"
  check "$label: reaches the sandbox container" \
    bash -c 'grep -q -- "--network none" "$1" && ! grep -qF "DELEGATE_UNTRUSTED_REPO=1: " <<<"$2"' \
    _ "$DELEGATE_TEST_DOCKER_LOG" "$OUT"
}

die() { printf 'FAIL: %s\n' "$1" >&2; [[ -n "${2:-}" ]] && printf '%s\n' "$2" >&2; exit 1; }
FAILURES=0
CHECKS=0
check() {
  local label="$1"; shift
  CHECKS=$((CHECKS + 1))
  if "$@"; then printf 'ok - %s\n' "$label"
  else printf 'not ok - %s\n' "$label"; FAILURES=$((FAILURES + 1)); fi
}

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
printf '%s\n' '[user]' '    name = t' '    email = t@example.invalid' >"$GIT_CONFIG_GLOBAL"
unset DELEGATE_UNTRUSTED_REPO DELEGATE_SANDBOX_IMAGE DELEGATE_SANDBOX_TIMEOUT DELEGATE_HERE 2>/dev/null || true

# ---- fixtures -----------------------------------------------------------------------------
mkrepo() {  # mkrepo DIR: an ordinary main-checkout repo with one commit
  git init -q "$1" || die "fixture: git init $1"
  git -C "$1" config user.name t
  git -C "$1" config user.email t@example.invalid
  echo hi >"$1/file"
  git -C "$1" add file && git -C "$1" -c commit.gpgsign=false commit -qm one || die "fixture: commit $1"
}
REPO="$T/src/repo"
mkdir -p "$T/src"
mkrepo "$REPO"
mkdir -p "$REPO/docs"                               # a subdirectory of the repo (not a top)
printf 'x\n' >"$T/loose"                            # a file well outside every repo

git -C "$REPO" worktree add -q "$T/src/linked" HEAD # a linked checkout: its .git is a gitfile
mkrepo "$T/src/we,ird"                              # comma in the repository path
mkrepo "$T/real/repo"                               # reached through a symlinked parent: the
ln -s "$T/real" "$T/src/link"                       # path runs through a symlink, top is real
mkrepo "$T/src/cd"                                  # a main checkout with a commondir file
printf 'gitdir: %s\n' "$T/src/cd" >"$T/src/cd/.git/commondir"
mkdir -p "$T/src/fake" && ln -s "$REPO/.git" "$T/src/fake/.git"   # a symlinked .git

SPEC="$T/spec.md"
printf '%s\n' '# Task' '' 'Do the thing.' >"$SPEC"

DELEGATE=("$here/bin/delegate")
U=DELEGATE_UNTRUSTED_REPO=1
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"

# mkmeta ID WORKTREE WT_GITDIR GIT_COMMON HERE RUNNER UNTRUSTED: fabricate a finished task
# under $T/state/<ID>/ (probe-verified meta.env shape). The sticky refusals key off UNTRUSTED=1
# written into meta.env with the environment variable never set.
mkmeta() {
  local id="$1" wt="$2" gtd="$3" gc="$4" h="$5" runner="$6" untrusted="$7" d="$T/state/$1"
  mkdir -p "$d/rounds/1"
  { printf 'ID=%s\nSLUG=%s\nREPO=%s\nWORKTREE=%s\nBRANCH=%s\n' "$id" "${id#*-}" "$REPO" "$wt" "delegate/${id#*-}"
    printf 'BASE_REF=main\nBASE_SHA=%s\nGIT_COMMON=%s\nMODEL=m\nVERIFY=true\n' "$BASE_SHA" "$gc"
    printf 'SERVICE=\nCOPIED=\nSESSION=\nCREATED=2026-01-01T00:00:00Z\nWT_GITDIR=%s\n' "$gtd"
    printf 'READS=\nGITHUB=0\nEGRESS=filtered\nHERE=%s\nRUNNER=%s\nRAW=0\n' "$h" "$runner"
    [[ "$untrusted" == 1 ]] && printf 'UNTRUSTED=1\n'
  } >"$d/meta.env"
  printf 'report\n' >"$d/rounds/1/report.md"
  : >"$d/$id.log"
}

# ---- load-time validation: a bad value refuses EVERY command -----------------------------------
refused "DELEGATE_UNTRUSTED_REPO=2 refuses list" "must be 0 or 1" \
  DELEGATE_UNTRUSTED_REPO=2 -- "${DELEGATE[@]}" list
refused "DELEGATE_UNTRUSTED_REPO=2 refuses rm too" "must be 0 or 1" \
  DELEGATE_UNTRUSTED_REPO=2 -- "${DELEGATE[@]}" rm nosuchtask
refused "DELEGATE_UNTRUSTED_REPO=yes refuses status" "must be 0 or 1" \
  DELEGATE_UNTRUSTED_REPO=yes -- "${DELEGATE[@]}" status

# ---- run-level refusals: anything that would touch the repo on the host -----------------------
refused "--here runs the worker on the host" "--here runs the worker natively" \
  "$U" -- "${DELEGATE[@]}" run "$SPEC" --here
refused "the native runner" "the native runner runs the worker on the host" \
  "$U" DELEGATE_RUNNER=native -- "${DELEGATE[@]}" run "$SPEC" --repo "$REPO"
refused "--orb reads the repo on the host" "--orb reads its target file" \
  "$U" -- "${DELEGATE[@]}" run "$SPEC" --repo "$REPO" --orb .orb-target
refused "a repo path that is a subdirectory" "not the top of a main checkout" \
  "$U" -- "${DELEGATE[@]}" run "$SPEC" --repo "$REPO/docs"
refused "a repo path with a gitfile" "not the top of a main checkout" \
  "$U" -- "${DELEGATE[@]}" run "$SPEC" --repo "$T/src/linked"
refused "a repo path with a symlinked .git" "not the top of a main checkout" \
  "$U" -- "${DELEGATE[@]}" run "$SPEC" --repo "$T/src/fake"
refused "a repo borrowing another (commondir)" "commondir" \
  "$U" -- "${DELEGATE[@]}" run "$SPEC" --repo "$T/src/cd"
refused "a comma in the repo path" "comma, tab or newline" \
  "$U" -- "${DELEGATE[@]}" run "$SPEC" --repo "$T/src/we,ird"
refused "worktrees inside the repository" "DELEGATE_WORKTREES is inside the repository" \
  "$U" DELEGATE_WORKTREES="$REPO/wt" -- "${DELEGATE[@]}" run "$SPEC" --repo "$REPO"
refused "--read inside the repository" "inside the untrusted repository" \
  "$U" -- "${DELEGATE[@]}" run "$SPEC" --repo "$REPO" --read "$REPO/docs"

# ---- accepted shapes run the git steps in the sandbox; the stub is the acceptance signal ------
accepted_to_sandbox "a plain repo run goes through the sandbox" \
  "$U" -- "${DELEGATE[@]}" run "$SPEC" --repo "$REPO"
check "the sandbox call caps privileges and mounts the repo" \
  bash -c 'grep -q -- "--cap-drop" "$1" && grep -q -- "--network none" "$1" && grep -qF -- "$2" "$1"' \
  _ "$DELEGATE_TEST_DOCKER_LOG" "$REPO"
accepted_to_sandbox "a repo under a symlinked parent dir is accepted" \
  "$U" -- "${DELEGATE[@]}" run "$SPEC" --repo "$T/src/link/repo"
# the CLI canonicalizes the path before mounting: what reaches docker is the real directory
check "docker was handed the resolved real path, not the symlink" \
  grep -qF -- "$(readlink -f "$T/src/link/repo")" "$DELEGATE_TEST_DOCKER_LOG"
accepted_to_sandbox "--read outside the repo is accepted" \
  "$U" -- "${DELEGATE[@]}" run "$SPEC" --repo "$REPO" --read "$T/loose"

# ---- tasks created under the setting: meta.env alone keeps them sandboxed (sticky) ------------
# A real per-repo-layout worktree so the accepted path has everything a finished task has.
git -C "$REPO" worktree add -q -b delegate/sticky "$T/wt/repo/sticky" HEAD || die "fixture worktree"
WT_GTD="$(git -C "$T/wt/repo/sticky" rev-parse --absolute-git-dir)"
mkmeta task-sticky "$T/wt/repo/sticky" "$WT_GTD" "$REPO/.git" 0 docker 1
mkmeta task-inplace "$REPO" "$REPO/.git" "$REPO/.git" 1 native 1
mkmeta task-native "$T/wt/repo/native" "$REPO/.git/worktrees/native" "$REPO/.git" 0 native 1
mkmeta task-flat "$T/wt/repo-flat" "$REPO/.git/worktrees/repo-flat" "$REPO/.git" 0 docker 1
mkdir -p "$T/elsewhere/gitdir" "$T/other/.git"
mkmeta task-badgd "$T/wt/repo/badgd" "$T/elsewhere/gitdir" "$REPO/.git" 0 docker 1
mkmeta task-badgc "$T/wt/repo/badgc" "$REPO/.git/worktrees/badgc" "$T/other/.git" 0 docker 1

# No DELEGATE_UNTRUSTED_REPO in the environment anywhere below: UNTRUSTED=1 in meta.env is what
# makes untrusted() true, so every command on these tasks obeys the mode the task was born in.
for c in diff verify; do
  refused "sticky in-place task refuses $c" "in-place (--here) task" \
    -- "${DELEGATE[@]}" "$c" task-inplace
done
refused "sticky in-place task refuses continue" "in-place (--here) task" \
  -- "${DELEGATE[@]}" continue task-inplace -m note
refused "sticky in-place task refuses exec" "in-place (--here) task" \
  -- "${DELEGATE[@]}" exec task-inplace -- true
for c in continue verify exec; do
  case "$c" in
    continue) extra=(-m note);;
    exec)     extra=(-- true);;
    *)        extra=();;
  esac
  refused "sticky native task refuses $c" "native runner, which runs the worker on the host" \
    -- "${DELEGATE[@]}" "$c" task-native "${extra[@]}"
done
refused "a flat-layout task is refused (diff)" "not in the per-repo layout" \
  -- "${DELEGATE[@]}" diff task-flat
refused "a worktree git dir outside the repo is refused" "worktree git dir is" \
  -- "${DELEGATE[@]}" diff task-badgd
refused "a borrowed GIT_COMMON is refused" "not $REPO/.git" \
  -- "${DELEGATE[@]}" diff task-badgc

# delegate rm is the one command available for host-running tasks; it needs no sandbox git, and
# neither does it obey the mode without meta. Accepted here means: removed without refusing.
RC=0; OUT=""
run_as -- "${DELEGATE[@]}" rm task-inplace
check "rm is available for an in-place sticky task (no refusal)" \
  bash -c '! grep -qF "DELEGATE_UNTRUSTED_REPO=1: " <<<"$1"' _ "$OUT"

# The sticky well-formed task proves stickiness positively: with no environment variable set at
# all, its diff still routes through the sandbox container rather than host git.
accepted_to_sandbox "diff of a sticky task runs sandboxed (no env var set)" \
  -- "${DELEGATE[@]}" diff task-sticky

# ---- an in-place chain plan is refused at load, before any step starts -------------------------
printf '%s\n' '{"name": "sg3", "here": true, "steps": [{"spec": "a.md"}]}' >"$T/plan.json"
RC=0; OUT=""
run_as "$U" -- "${DELEGATE[@]}" chain "$T/plan.json"
[[ $RC -eq 2 ]] || die "chain in-place plan: expected exit 2, got $RC: $OUT"
check "an in-place chain plan is refused" grep -qF -- "an in-place plan runs git in the checkout on the host" <<<"$OUT"
check "no chain step started" test ! -s "$DELEGATE_TEST_CHAIN_LOG"
check "the chain refusal touched no docker" test ! -s "$DELEGATE_TEST_DOCKER_LOG"

# ---- setting unset (and set to 0 explicitly): ordinary behaviour, no refusal text --------------
RC=0; OUT=""
run_as -- "${DELEGATE[@]}" run "$SPEC" --repo "$REPO"
check "with the setting unset a plain run reaches the endpoint check" \
  bash -c 'test "$1" -eq 1 && grep -qF "no endpoint in DELEGATE_BASE_URLS" <<<"$2"' _ "$RC" "$OUT"
check "with the setting unset nothing mentions the untrusted refusal" \
  bash -c '! grep -q DELEGATE_UNTRUSTED_REPO <<<"$1"' _ "$OUT"
check "with the setting unset no container was started" test ! -s "$DELEGATE_TEST_DOCKER_LOG"
RC=0; OUT=""
run_as DELEGATE_UNTRUSTED_REPO=0 -- "${DELEGATE[@]}" run "$SPEC" --repo "$REPO"
check "DELEGATE_UNTRUSTED_REPO=0 behaves the same as unset" \
  bash -c 'test "$1" -eq 1 && grep -qF "no endpoint in DELEGATE_BASE_URLS" <<<"$2" && ! grep -q DELEGATE_UNTRUSTED_REPO=1 <<<"$2"' _ "$RC" "$OUT"

# ---- lib/safepath.py: the identity walk every untrusted mount check rides on -------------------
ln -s "$REPO" "$T/plink"                             # final component symlinked
SP=("$here/lib/safepath.py")
EXPECT_INO="$(stat -c '%d:%i' "$REPO")"
RC=0; OUT=""
run_as -- "${SP[@]}" "$REPO"
check "safepath prints PATH<TAB>DEV:INO for a plain directory" \
  bash -c 'test "$1" -eq 0 && test "$2" = "$(printf "%s\t%s" "$3" "$4")"' _ "$RC" "$OUT" "$REPO" "$EXPECT_INO"
RC=0; OUT=""
run_as -- "${SP[@]}" "$REPO" "$T/state"
check "safepath handles several paths, in order" \
  bash -c 'test "$(sed -n "2s|\t.*||p" <<<"$2")" = "$3" && test "$(sed -n "1s|\t.*||p" <<<"$2")" = "$1"' _ "$REPO" "$OUT" "$T/state"
for bad in "$T/plink" "$T/src/link/repo" "$T/loose" "src/repo" "$REPO/../real/repo" "$REPO/"; do
  RC=0; OUT=""
  run_as -- "${SP[@]}" "$bad"
  check "safepath refuses $bad (exit 3 + SECURITY)" \
    bash -c 'test "$1" -eq 3 && grep -q SECURITY <<<"$2"' _ "$RC" "$OUT"
done
RC=0; OUT=""
run_as -- "${SP[@]}"
check "safepath with no paths is a usage error (exit 2)" test "$RC" -eq 2

if (( FAILURES )); then
  printf 'FAIL: %s: %d of %d checks failed\n' "${BASH_SOURCE[0]##*/}" "$FAILURES" "$CHECKS" >&2
  exit 1
fi
printf 'PASS: %s: %d checks\n' "${BASH_SOURCE[0]##*/}" "$CHECKS"
