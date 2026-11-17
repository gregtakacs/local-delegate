#!/bin/bash
# A2: WHERE a new task's worktree goes (<DELEGATE_WORKTREES>/<project>/<leaf>) and WHAT one
# project can see of the task list: `delegate list --repo`, `delegate top --repo`, and
# `delegate stats --repo` (which also matches another spelling of the same directory). Real git,
# temp dirs only, task state fabricated the way tests/test_top.sh does it, plus two real
# `git worktree add`s so report/diff/rm run against real worktrees. No docker, no model, no
# network: the new-task path rule and the per-repo-folder refusal are tested on the bash
# functions extracted from bin/delegate with sed (what tests/test_orchestrator.sh does for
# orchestrator_of), because `delegate run` checks its config and probes its endpoint long before
# it names a worktree path, and this suite has neither.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME=$T/home XDG_CACHE_HOME=$T/cache XDG_CONFIG_HOME=$T/xdg-config XDG_STATE_HOME=$T/xdg-state
export DELEGATE_STATE=$T/state DELEGATE_WORKTREES=$T/wtrees DELEGATE_CACHE=$T/cache/delegate
export DELEGATE_CONFIG=$T/config.env DELEGATE_LEDGER=$T/led/events.jsonl
export DELEGATE_PRUNE_DAYS=0 DELEGATE_PROGRESS=0
mkdir -p "$HOME" "$XDG_CACHE_HOME/claude-agent-progress" "$DELEGATE_STATE" "$DELEGATE_WORKTREES" "$T/led"
printf 'DELEGATE_RUNNER=native\n' > "$DELEGATE_CONFIG"          # what an installed config says
W=$DELEGATE_WORKTREES
D() { "$here/bin/delegate" "$@"; }
ts() { python3 "$here/lib/taskstate.py" "$@"; }
lit() { grep -Fq -- "$1" "$here/bin/delegate"; }                # a literal line of bin/delegate
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# ------------------------------------------------------- 1. the path for a new task -------
# Extracted, not run: the rule is string work over GIT_COMMON/REPO/ID alone. The `_` after the
# script is `bash -c`'s $0 placeholder, which is what lets the arguments reach "$@".
fn=$(sed -n '/^task_worktree_path() {/,/^}/p' "$here/bin/delegate")
check "task_worktree_path is defined in bin/delegate" '[ -n "$fn" ]'
wt() { DELEGATE_WORKTREES=$W bash -c "$fn"'
task_worktree_path "$@"' _ "$@"; }
check "a main checkout: <W>/<repo>/<slug>" \
  '[ "$(wt "$T/src/repo/.git" "$T/src/repo" repo-x)" = "$W/repo/x" ]'
check "a linked worktree of repo named repo-lead: <W>/repo/lead-x, one project" \
  '[ "$(wt "$T/src/repo/.git" "$T/wt/repo-lead" repo-lead-x)" = "$W/repo/lead-x" ]'
check "a bare common dir (no /.git): basename REPO, id minus that prefix" \
  '[ "$(wt "$T/srv/bare/proj" "$T/srv/bare/proj" proj-task-2)" = "$W/proj/task-2" ]'
check "an empty common dir: the same rule over the repo's basename" \
  '[ "$(wt "" "$T/src/repo" repo-x)" = "$W/repo/x" ]'
check "an id that does not start with <project>- keeps the whole id as the leaf" \
  '[ "$(wt "$T/src/repo/.git" "$T/src/repo" other-1)" = "$W/repo/other-1" ]'
check "a trailing slash on GIT_COMMON changes nothing" \
  '[ "$(wt "$T/src/repo/.git/" "$T/src/repo" repo-x)" = "$W/repo/x" ]'
check "the leaf keeps the dashes of a real slug" \
  '[ "$(wt "$T/src/repo/.git" "$T/src/repo" repo-add-handles)" = "$W/repo/add-handles" ]'
check "the task id and the branch are untouched by the layout" \
  'lit "printf '"'"'ID=%q\nSLUG=%q\nREPO=%q\nWORKTREE=%q\nBRANCH=%q\n'"'"'" && lit "BRANCH=\"delegate/\$SLUG\""'

# ------------------------------------------- 2. <W>/<project> must not be a checkout ------
gf=$(sed -n '/^worktree_folder_check() {/,/^}/p' "$here/bin/delegate")
check "worktree_folder_check is defined in bin/delegate" '[ -n "$gf" ]'
# The guard as a function, with a `die` of its own: reaching it inside cmd_run would need a
# readable API key, an endpoint that answers /models, and a runner on PATH — none of which this
# suite may use, and none of which the guard itself depends on.
{ echo 'die() { echo "delegate: $*" >&2; exit 1; }'; echo "$gf"; echo 'worktree_folder_check "$1"'; } > "$T/guard.sh"
guard() { bash "$T/guard.sh" "$@" 2>&1; }                       # message on stdout+stderr, rc in $?
msg() { printf 'delegate: %s is not a per-repo worktree folder (it is a checkout or a file); move it or set DELEGATE_WORKTREES' "$1"; }
mkdir -p "$W/repo/.git"                                          # a checkout's admin dir is enough
guard "$W/repo" >/dev/null; rc=$?
check "a project folder that is itself a checkout is refused (rc 1)" '[ "$rc" = 1 ]'
check "the refusal is exactly the message, naming the folder and what to do" \
  '[ "$(guard "$W/repo")" = "$(msg "$W/repo")" ]'
: > "$W/plain"; guard "$W/plain"; rc=$?
check "a project folder that is a plain file is refused the same way" \
  '[ "$rc" = 1 ] && [ "$(guard "$W/plain")" = "$(msg "$W/plain")" ]'
rm -f "$W/plain"; mkdir -p "$W/repo2/add-handles"; guard "$W/repo2"; rc=$?
check "a plain folder that already holds another task's worktree passes" '[ "$rc" = 0 ]'
guard "$W/notthere"; rc=$?
check "no folder yet passes: run creates it beside the worktree" '[ "$rc" = 0 ]'
rm -rf "$W/repo"

# nothing may exist yet when the refusal lands: not a branch, not a task dir, not the folder
l_guard=$(grep -n 'worktree_folder_check "\$WORKTREE_PARENT"' "$here/bin/delegate" | cut -d: -f1)
l_mkdir=$(grep -n 'mkdir -p "$TASK_DIR/rounds"' "$here/bin/delegate" | cut -d: -f1)
l_add=$(grep -n 'git -C "$repo" worktree add' "$here/bin/delegate" | cut -d: -f1)
check "cmd_run calls the guard, before the branch, the task dir and the folder" \
  '[ -n "$l_guard" ] && [ -n "$l_mkdir" ] && [ -n "$l_add" ] \
     && [ "$l_guard" -lt "$l_mkdir" ] && [ "$l_guard" -lt "$l_add" ]'
check "cmd_run takes the path from task_worktree_path, never rebuilt from the id" \
  'lit "WORKTREE=\$(task_worktree_path \"\$GIT_COMMON\" \"\$repo\" \"\$ID\")" \
     && ! lit "WORKTREE=\"\$DELEGATE_WORKTREES/\$ID\""'
check "run creates <W>/<project> with the task dir" \
  'lit "mkdir -p \"\$TASK_DIR/rounds\" \"\${WORKTREE_PARENT:-\$DELEGATE_WORKTREES}\""'

# ------------------------------ 3. two real worktrees: report, diff and rm still work -----
repo=$T/src/repo; other=$T/src/other
mkdir -p "$repo" "$other"
git -C "$repo" init -q -b main
echo '# repo' > "$repo/README.md"; git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -qm init
GITC=$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd)     # exactly as cmd_run does it
check "GIT_COMMON of a main checkout is its own .git" '[ "$GITC" = "$repo/.git" ]'

mkwt() { # ID WORKTREE BRANCH FILE: a real worktree + a commit + meta.env as cmd_run writes it
  local id=$1 wt=$2 branch=$3 file=$4 d=$DELEGATE_STATE/$1 base head
  mkdir -p "$(dirname "$wt")"
  git -C "$repo" worktree add -q -b "$branch" "$wt" HEAD || return 1
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'work by %s\n' "$id" > "$wt/$file"
  git -C "$wt" add -A && git -C "$wt" -c user.name=w -c user.email=w@w commit -qm "$id: round 1"
  head=$(git -C "$wt" rev-parse HEAD)
  mkdir -p "$d/rounds/1"
  { printf 'ID=%q\nSLUG=%q\nREPO=%q\nWORKTREE=%q\nBRANCH=%q\n' "$id" "${id#*-}" "$repo" "$wt" "$branch"
    printf 'BASE_REF=%q\nBASE_SHA=%q\nGIT_COMMON=%q\nMODEL=%q\nVERIFY=%q\n' main "$base" "$GITC" m true
    printf 'SERVICE=%q\nCOPIED=%q\nSESSION=\nCREATED=%q\nWT_GITDIR=%q\n' \
      '' '' "$(date -Is)" "$(git -C "$wt" rev-parse --absolute-git-dir)"
    printf 'READS=%q\nGITHUB=%q\nEGRESS=%q\nHERE=%q\nRUNNER=%q\nRAW=%q\n' '' 0 filtered 0 native 0
  } > "$d/meta.env"                                              # HERE=0, RUNNER=native, GIT_COMMON set
  printf 'the report of %s\n' "$id" > "$d/rounds/1/report.md"
  printf '%s\n' "$head" > "$d/rounds/1/commit"
}
mkwt repo-old "$W/repo-old" delegate/old old.md                   # made in the old flat layout
mkwt repo-new "$W/repo/new" delegate/new new.md                   # made in the new per-repo layout
jget() { ts json "$DELEGATE_STATE/$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2"; }
check "the flat task's worktree is <W>/<id>, as it was made"       '[ -f "$W/repo-old/.git" ]'
check "the new task's worktree is <W>/<project>/<leaf>" \
  '[ -f "$W/repo/new/.git" ] && [ -d "$W/repo" ] && [ "$(cat "$W/repo/new/new.md")" = "work by repo-new" ]'
check "each records its own path, not one derived from its id" \
  '[ "$(jget repo-old worktree)" = "$W/repo-old" ] && [ "$(jget repo-new worktree)" = "$W/repo/new" ]'
check "state() names the project the ledger names, and the common dir it came from" \
  '[ "$(jget repo-new project)" = "$repo" ] && [ "$(jget repo-new git_common)" = "$GITC" ]'
for id in repo-old repo-new; do
  D report "$id" > "$T/rep-$id" 2>"$T/rep-$id.err"; rc=$?
  check "delegate report $id reads its round from the path in its meta.env" \
    "[ \$rc = 0 ] && grep -q 'the report of $id' \$T/rep-\$id"
  D diff "$id" > "$T/diff-$id" 2>"$T/diff-$id.err"; rc=$?
  check "delegate diff $id prints a diffstat naming its committed file" \
    "[ \$rc = 0 ] && grep -q '${id##*-}.md' \$T/diff-\$id && ! grep -qi security \$T/diff-\$id.err"
done

# ------------------------------------------------------------------ 4. delegate list ------
mkmeta() { # ID REPO GIT_COMMON WORKTREE [DONE_OLD]: state only — list and top read meta.env
  local id=$1 r=$2 gc=$3 wt=$4 old=${5:-} d=$DELEGATE_STATE/$1
  mkdir -p "$d/rounds/1"
  printf 'ID=%s\nSLUG=%s\nREPO=%s\nGIT_COMMON=%s\nWORKTREE=%s\nBRANCH=delegate/%s\nMODEL=m\nVERIFY=true\nHERE=0\nRAW=0\nRUNNER=native\nEGRESS=filtered\n' \
    "$id" "$id" "$r" "$gc" "$wt" "$id" > "$d/meta.env"
  if [ -n "$old" ]; then       # finished, and long enough ago that top hides it by age
    printf '{"status":"done","steps":1,"tool_calls":1,"output_tokens":10,"final_context_tokens":20,"duration_s":9}\n' > "$d/rounds/1/report.json"
    echo spec > "$d/rounds/1/prompt.md"; : > "$d/rounds/1/events.jsonl"
    touch -d '3 days ago' "$d/rounds/1/report.json" "$d/rounds/1/events.jsonl" "$d/rounds/1/prompt.md"
  fi
}
mkmeta other-x "$other" "$other/.git" "$W/other/x"
mkmeta other-old "$other" "$other/.git" "$W/other/old" done
ln -s "$repo" "$T/link"
rows() { tail -n +2 <<<"$1" | grep -c .; }                        # task lines, past the header
all=$(D list); l1=$(D list --repo "$repo"); l2=$(D list --repo "$other"); l3=$(D list --repo "$T/link")
l4=$(D list --repo "$repo/"); l5=$(cd "$T/src" && D list --repo ./repo)
check "no filter: every task of every project" \
  '[ "$(rows "$all")" = 4 ] && grep -q repo-old <<<"$all" && grep -q repo-new <<<"$all" && grep -q other-x <<<"$all"'
check "--repo shows that project's two tasks and no others" \
  '[ "$(rows "$l1")" = 2 ] && grep -q repo-old <<<"$l1" && grep -q repo-new <<<"$l1" && ! grep -q other <<<"$l1"'
check "the other project's filter shows its own two" \
  '[ "$(rows "$l2")" = 2 ] && grep -q other-x <<<"$l2" && grep -q other-old <<<"$l2" && ! grep -q repo- <<<"$l2"'
check "a symlink to the checkout is the same project" '[ "$l3" = "$l1" ]'
check "a trailing slash is the same project"          '[ "$l4" = "$l1" ]'
check "a relative --repo resolves against the cwd"    '[ "$l5" = "$l1" ]'
check "the format is the same filtered or not" \
  '[ "$(head -1 <<<"$all")" = "$(head -1 <<<"$l1")" ] && head -1 <<<"$l1" | grep -q "^TASK *ROUNDS *STATUS *WORKTREE$"'
out=$(D list --repo "$T/nowhere"); rc=$?
check "a filter that matches nothing says (no tasks), at rc 0" '[ $rc = 0 ] && [ "$out" = "(no tasks)" ]'
out=$(D list --bogus 2>&1); rc=$?
check "list --bogus is the usage line at rc 2" \
  '[ $rc = 2 ] && [ "$out" = "usage: delegate list [--repo PATH]" ]'
out=$(D list --repo 2>&1); rc=$?
check "list --repo with no value is the same refusal" \
  '[ $rc = 2 ] && [ "$out" = "usage: delegate list [--repo PATH]" ]'

# -------------------------------------------------------------------- 5. delegate top -----
python3 - "$XDG_CACHE_HOME/claude-agent-progress/aaaa.json" <<'PY'
import json, sys, time
json.dump({"desc": "lead-name-leaks", "phase": "delegating", "started_at": time.time() - 900,
           "last_post": time.time(), "tool_calls": 3, "tool_errors": 0, "todos": [], "recent": [],
           "children": ["task:repo-old"], "usage": {"input": 5000, "cache_read": 60000, "output": 4100}},
          open(sys.argv[1], "w"))
PY
topall=$(COLUMNS=200 D top --once 2>&1); toprepo=$(COLUMNS=200 D top --once --repo "$repo" 2>&1)
check "unfiltered, top shows the leads and the other project too" \
  'grep -q lead-name-leaks <<<"$topall" && grep -q other-x <<<"$topall" \
     && grep -q "3 task(s) · 1 lead(s)" <<<"$topall" && grep -q "1 finished >24h hidden" <<<"$topall"'
check "--repo shows only that project's tasks" \
  'grep -q repo-old <<<"$toprepo" && grep -q repo-new <<<"$toprepo" && ! grep -q other <<<"$toprepo"'
check "--repo counts only those tasks, and hides none of the other project's" \
  'grep -q "2 task(s) · 0 lead(s)" <<<"$toprepo" && ! grep -q hidden <<<"$toprepo"'
check "--repo shows no lead row at all, not even the lead that claims this task" \
  '! grep -q lead-name-leaks <<<"$toprepo" && grep -q "Not started by a lead" <<<"$toprepo"'
D top other-x --repo "$repo" --once >"$T/t1" 2>"$T/t1.err"; rc=$?
check "top ID --repo for another project's task: the no-such-task line at rc 1" \
  '[ $rc = 1 ] && [ ! -s "$T/t1" ] \
     && grep -qxF "delegate top: no such task: other-x (see: delegate list)" "$T/t1.err"'
D top --repo "" --once >"$T/t0" 2>&1; rc=$?
check "top --repo with an empty path is a usage error, not an unfiltered view" \
  '[ $rc = 2 ] && grep -q "needs a path" "$T/t0" && ! grep -q other-x "$T/t0"'
D top repo-old --repo "$T/link" --once >"$T/t2" 2>&1; rc=$?
check "the same ID through its own project's path is shown, at rc 0, with no lead named" \
  '[ $rc = 0 ] && grep -q repo-old "$T/t2" && ! grep -q lead-name-leaks "$T/t2"'

# ------------------------------------------------------------------ 6. stats --repo -------
st() { OUT="$OUT" python3 -c 'import json,os,sys
d = json.loads(os.environ["OUT"])
print(eval("d" + sys.argv[1], {"d": d}))' "$1"; }
D ledger append --kind round --task st-1 \
  --fields "repo=$repo,project=$repo,chain=c1,model=m1,effort=hard,status=done,ts=2026-11-10T00:00:00Z,round=1,duration_s=5"
OUT=$(D stats --repo "$repo" --json 2>/dev/null)
check "stats --repo still matches a row by its own spelling" \
  '[ "$(st "[\"counts\"][\"round_rows\"]")" = 1 ] && [ "$(st "[\"groups\"][0][\"repo\"]")" = "'"$repo"'" ]'
OUT=$(D stats --repo "$T/link" --json 2>/dev/null)
check "stats --repo through a symlink to the project counts that row" \
  '[ "$(st "[\"counts\"][\"round_rows\"]")" = 1 ]'
OUT=$(D stats --repo "$repo/" --json 2>/dev/null)
check "and a trailing slash is the same directory" '[ "$(st "[\"counts\"][\"round_rows\"]")" = 1 ]'
OUT=$(D stats --repo "$other" --json 2>/dev/null)
check "an unrelated project counts nothing" '[ "$(st "[\"counts\"][\"round_rows\"]")" = 0 ]'
OUT=$(D stats --repo repo --json 2>/dev/null)
check "a relative --repo that is not the row's exact field counts nothing" \
  '[ "$(st "[\"counts\"][\"round_rows\"]")" = 0 ]'
OUT=$(D stats --repo "$T/link" 2>/dev/null)
check "the text output is the same one-row table through the symlink" \
  'printf "%s\n" "$OUT" | grep -q "1 of 1 round rows"'

# ------------------------------------ 7. rm: the task goes, the project folder stays -------
for id in repo-old repo-new; do
  D rm "$id" >"$T/rm-$id" 2>&1; rc=$?
  check "delegate rm $id exits 0" '[ $rc = 0 ]'
done
check "rm removed the flat task's <W>/<id>"              '[ ! -e "$W/repo-old" ]'
check "rm removed the new task's <W>/<project>/<leaf>"   '[ ! -e "$W/repo/new" ]'
check "but <W>/<project> is still there: a container bind-mounts it" '[ -d "$W/repo" ]'
check "rm kept both branches (no --delete-branch)" \
  'git -C "$repo" show-ref --verify --quiet refs/heads/delegate/old \
     && git -C "$repo" show-ref --verify --quiet refs/heads/delegate/new'
check "and pruned the repo's worktree registry" '[ "$(git -C "$repo" worktree list | grep -c "^")" = 1 ]'
check "both task states are gone, the other project's are not" \
  '[ ! -e "$DELEGATE_STATE/repo-old" ] && [ ! -e "$DELEGATE_STATE/repo-new" ] \
     && [ -f "$DELEGATE_STATE/other-x/meta.env" ] && [ -f "$DELEGATE_STATE/other-old/meta.env" ]'

echo
if [ "$fail" -eq 0 ]; then echo "PASS: test_worktree_layout"; else echo "FAIL: test_worktree_layout"; fi
exit $fail
