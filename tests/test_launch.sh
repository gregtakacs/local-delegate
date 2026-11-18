#!/bin/bash
# The launch fingerprint (round:4, chain:2): lib/launch.py walks up from delegate's process to the
# Claude Code Bash wrapper (`bash -c '... && eval '<command>' && ...'`) and records only the
# sha256 of <command>, so the work view can tell which (sub-)agent launched a run. Fake /proc
# trees for the walk and its hostile inputs, one real wrapper process, bin/delegate's launch_hash
# from its own text, and the ledger rows. No network, no docker; HOME and XDG_* are this suite's.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
umask 022
export HOME=$T/home XDG_CONFIG_HOME=$T/xdg-config XDG_STATE_HOME=$T/xdg-state \
       XDG_CACHE_HOME=$T/xdg-cache XDG_DATA_HOME=$T/xdg-data
mkdir -p "$HOME"
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
L() { python3 -I "$here/lib/launch.py" "$@"; }
sha() { printf '%s' "$1" | sha256sum | cut -c1-64; }

# A fake /proc: mkproc ROOT PID PPID COMM ARG... writes <ROOT>/<PID>/{cmdline,stat}.
mkproc() {
  local root=$1 pid=$2 ppid=$3 comm=$4; shift 4
  mkdir -p "$root/$pid"
  printf '%s\0' "$@" > "$root/$pid/cmdline"
  printf '%s (%s) S %s 1 1 0 -1 4194560\n' "$pid" "$comm" "$ppid" > "$root/$pid/stat"
}
# The wrapper exactly as Claude Code builds it: the command single-quoted with '"'"' for each '.
wrap() { python3 -c '
import sys
c = sys.argv[1]
print("source /home/u/.claude/shell-snapshots/snap.sh 2>/dev/null || true && \\builtin shopt -u extglob 2>/dev/null || true && eval " + "\x27" + c.replace("\x27", "\x27\"\x27\"\x27") + "\x27" + " && pwd -P >| /tmp/claude-ab12-cwd", end="")
' "$1"; }

# ------------------------------------------------------------- 1. the walk ------------
CMD=$'cd ~/src/app && delegate run "spec \'one\'.md" --hard\necho "done, it\'s $HOME" | tail -3'
P=$T/proc1
mkproc "$P" 1 0 systemd /sbin/init
mkproc "$P" 40 1 claude claude --continue
mkproc "$P" 50 40 bash /bin/bash -c "$(wrap "$CMD")"
mkproc "$P" 60 50 'bash) S 7 (x' bash /home/u/.local/bin/delegate run spec.md   # a hostile comm
mkproc "$P" 70 60 python3 python3 /x/lib/chain.py plan.json
check "the wrapper's command (quotes and newlines) hashes to its own sha256" \
  '[ "$(L --pid 70 --proc "$P")" = "$(sha "$CMD")" ]'
check "the hash is 64 lowercase hex" '[[ "$(L --pid 70 --proc "$P")" =~ ^[0-9a-f]{64}$ ]]'
check "starting at the wrapper itself finds it" '[ "$(L --pid 50 --proc "$P")" = "$(sha "$CMD")" ]'
check "the command text itself is never printed" \
  '! L --pid 70 --proc "$P" | grep -q "delegate run"'

# the first wrapper up the tree wins: an inner tool call inside an outer one
INNER='delegate continue x -m "fix it"'
mkproc "$P" 80 70 bash bash -c "$(wrap "$INNER")"
mkproc "$P" 90 80 bash bash /x/bin/delegate continue x
check "the nearest wrapper is the launcher" '[ "$(L --pid 90 --proc "$P")" = "$(sha "$INNER")" ]'

# --------------------------------------------------------- 2. no wrapper: null --------
Q=$T/proc2
mkproc "$Q" 1 0 systemd /sbin/init
mkproc "$Q" 30 1 sshd sshd
mkproc "$Q" 31 30 bash -bash
mkproc "$Q" 32 31 bash bash /x/bin/delegate run s.md
check "a plain terminal: nothing, exit 0" '[ -z "$(L --pid 32 --proc "$Q")" ] && L --pid 32 --proc "$Q"'
mkproc "$Q" 33 31 bash bash -c 'make test && ./delegate run s.md'
mkproc "$Q" 34 33 bash bash /x/bin/delegate run s.md
check "a bash -c without the eval wrapper is not a launch" '[ -z "$(L --pid 34 --proc "$Q")" ]'
mkproc "$Q" 35 31 zsh /bin/zsh -c "$(wrap 'echo hi')"
mkproc "$Q" 36 35 bash bash /x/bin/delegate run s.md
check "a non-bash shell with the same text is not a launch" '[ -z "$(L --pid 36 --proc "$Q")" ]'
mkproc "$Q" 37 31 bash bash -c "x && eval 'unterminated"
mkproc "$Q" 38 37 bash bash /x/bin/delegate run s.md
check "an unterminated quote after eval: null, no crash" '[ -z "$(L --pid 38 --proc "$Q" 2>&1)" ]'
mkproc "$Q" 39 39 bash bash /x/bin/delegate run s.md                 # its own parent
check "a parent cycle ends the walk: null" '[ -z "$(L --pid 39 --proc "$Q")" ]'
check "a pid with no /proc entry: null" '[ -z "$(L --pid 99999 --proc "$Q")" ]'
check "a bad --pid: nothing, exit 0" '[ -z "$(L --pid nope)" ] && L --pid nope'

# deeper than 8 parents: never reached
D=$T/proc3; mkproc "$D" 1 0 systemd /sbin/init
mkproc "$D" 100 1 bash bash -c "$(wrap 'deep')"
prev=100; for i in $(seq 101 109); do mkproc "$D" "$i" "$prev" bash bash x; prev=$i; done
check "the wrapper 8 parents up is found" '[ "$(L --pid 108 --proc "$D")" = "$(sha deep)" ]'
check "the wrapper 9 parents up is not (at most 8 levels)" '[ -z "$(L --pid 109 --proc "$D")" ]'

# ------------------------------------------------- 3. a huge hostile cmdline -----------
H=$T/proc4
mkproc "$H" 1 0 systemd /sbin/init
mkproc "$H" 50 1 bash bash -c "$(wrap 'small')"
mkdir -p "$H/60"
{ printf 'bash\0-c\0'; printf "true && eval '"; head -c $((1024 * 1024 + 10)) /dev/zero | tr '\0' a; printf "'\0"; } > "$H/60/cmdline"
printf '60 (bash) S 50 1 1\n' > "$H/60/stat"
mkproc "$H" 70 60 bash bash /x/bin/delegate run s.md
out=$(L --pid 70 --proc "$H" 2>&1); rc=$?
check "a cmdline over 1 MiB: null, exit 0, no traceback" '[ -z "$out" ] && [ "$rc" = 0 ]'
check "the cap is 1 MiB" 'grep -q "^CMDLINE_CAP = 1 << 20 " "$here/lib/launch.py"'

# ------------------------------------------- 4. the injectable reader (python API) -----
check "launch_sha256 with an injected reader, and one that raises" "python3 -I - '$here/lib' <<'PY'
import hashlib, sys
sys.path.insert(0, sys.argv[1])
import launch
cmd = \"echo 'a b'\"
tree = {7: (b'bash\\0/x/bin/delegate\\0run\\0', b'7 (bash) S 6 1'),
        6: (b'/usr/bin/bash\\0-c\\0p && eval ' + b\"'echo '\\\"'\\\"'a b'\\\"'\\\"''\" + b' && pwd -P\\0', b'6 (bash) S 1 1')}
def read(pid, name):
    c, s = tree.get(pid, (None, None))
    return c if name == 'cmdline' else s
assert launch.launch_sha256(7, read) == hashlib.sha256(cmd.encode()).hexdigest(), launch.launch_sha256(7, read)
def boom(pid, name): raise RuntimeError('hostile')
assert launch.launch_sha256(7, boom) is None
assert launch.launch_sha256(7, lambda p, n: b'\\xff' * 10) is None
assert launch.eval_command(['bash', '-c']) is None
PY"

# ------------------------------------------------------- 5. a real wrapper process ------
REAL="python3 -I $here/lib/launch.py"
got=$(bash -c "true && eval '$REAL' && true")
check "a live bash -c ... eval wrapper: the hash of its command" '[ "$got" = "$(sha "$REAL")" ]'

# --------------------------------------------- 6. bin/delegate's launch_hash -----------
fn=$(sed -n '/^launch_hash() {/,/^}/p' "$here/bin/delegate")
check "launch_hash is defined in bin/delegate" '[ -n "$fn" ]'
lh() { env -i PATH="$PATH" DELEGATE_HOME="$here" "$@" bash -c "$fn"'
launch_hash'; }
H64=$(sha chain-launch)
check "a chain step takes the chain's exported launch" \
  '[ "$(lh DELEGATE_CHAIN=c DELEGATE_LAUNCH_SHA256=$H64)" = "$H64" ]'
check "a chain that found none: the step records none either" \
  '[ -z "$(lh DELEGATE_CHAIN=c DELEGATE_LAUNCH_SHA256=)" ]'
check "an exported value that is not a sha256 is dropped" \
  '[ -z "$(lh DELEGATE_CHAIN=c DELEGATE_LAUNCH_SHA256="x;id")" ] && [ -z "$(lh DELEGATE_CHAIN=c DELEGATE_LAUNCH_SHA256=${H64^^})" ]'
{ echo "$fn"; echo launch_hash; } > "$T/lh.sh"
LH="env -i PATH=/usr/local/bin:/usr/bin:/bin DELEGATE_HOME=$here DELEGATE_LAUNCH_SHA256=$H64 bash $T/lh.sh"
got=$(bash -c "true && eval '$LH' && true")
check "outside a chain the exported value is ignored: its own launch" \
  '[ "$got" = "$(sha "$LH")" ]'
check "do_round records the round's launch beside its prompt" \
  'grep -qF '"'"'launch_hash > "$rd/launch.sha256"'"'"' "$here/bin/delegate"'
check "finalize_round passes it to the round row" \
  'grep -qF -- '"'"'--launch-sha256 "$(cat "$rd/launch.sha256"'"'"' "$here/bin/delegate"'
check "the chain exports its launch to its steps" \
  'grep -qF '"'"'os.environ["DELEGATE_LAUNCH_SHA256"] = mark["launch"] or ""'"'"' "$here/lib/chain.py"'

# ------------------------------------------------------------- 7. the ledger rows ------
check "round:4 and chain:2 carry launch_sha256; older rows still read" "python3 -I - '$here/lib' '$T' <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[1])
import ledger
h = 'ab' * 32
assert ledger.KINDS['round'] == 4 and ledger.KINDS['chain'] == 2, ledger.KINDS
keys = list(ledger.ROUND_KEYS)
assert keys.index('launch_sha256') == keys.index('orchestrator_session') + 1
ck = list(ledger.CHAIN_KEYS)
assert ck.index('launch_sha256') == ck.index('orchestrator_session') + 1
assert ledger.build_round_row({}, {'launch_sha256': h})['launch_sha256'] == h
assert ledger.build_round_row({}, {'launch_sha256': h.upper()})['launch_sha256'] == h
assert ledger.build_round_row({}, {'launch_sha256': 'echo hi'})['launch_sha256'] is None
assert ledger.build_round_row({}, {})['launch_sha256'] is None
assert ledger.build_chain_row({'launch_sha256': h})['launch_sha256'] == h
assert ledger.build_chain_row({'launch_sha256': 5})['launch_sha256'] is None
p = os.path.join(sys.argv[2], 'led.jsonl')
ledger.append_chain_row(p, {'chain': 'c', 'launch_sha256': h})
with open(p, 'a') as f:
    for kind, schema in (('round', 1), ('round', 2), ('round', 3), ('chain', 1)):
        f.write(json.dumps({'kind': kind, 'schema': schema, 'task_id': 't'}) + '\n')
    f.write(json.dumps({'kind': 'round', 'schema': 5, 'task_id': 't'}) + '\n')
rows = [r for _, _, r in ledger.read_rows(p)]
assert rows[0]['schema'] == 2 and rows[0]['launch_sha256'] == h, rows[0]
assert [r and (r['kind'], r['schema']) for r in rows[1:5]] == [('round', 1), ('round', 2), ('round', 3), ('chain', 1)], rows
assert rows[5] is None
PY"

if [ "$fail" = 0 ]; then echo "PASS test_launch"; else echo "FAIL test_launch"; fi
exit $fail
