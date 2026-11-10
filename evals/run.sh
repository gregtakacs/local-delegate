#!/usr/bin/env bash
# evals/run.sh — run the worker on a fixed set of tasks and score it with checks it never sees.
#
#   evals/run.sh [--label NAME] [--rules-ref GIT_REF] [--cases a,b,...] [--repeat N] [--keep]
#
# Each case (evals/cases/<case>/) has:
#   case.env   VERIFY=..., optional SERVICE=postgres, TIMEOUT=seconds
#   setup.sh   builds the starting repo in $1 (run on the host; may use the case's fixture/)
#   spec.md    what the worker is given
#   hidden/    check.sh + whatever it needs. Copied into the worktree only AFTER the run, run
#              in the worker environment, then removed. Prints PASS/FAIL lines.
#
# --rules-ref runs the worker with opencode/ (rules + plugins) as of that git revision, so
# a rule change can be compared against its parent on the same cases. Results go to
# evals/results/<stamp>-<label>.{md,jsonl}. One run per case is an anecdote; use --repeat 3+
# before concluding that a rule change helped.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
label=current rules_ref="" cases="" repeat=1 keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --label) label=$2; shift 2 ;;
    --rules-ref) rules_ref=$2; shift 2 ;;
    --cases) cases=$2; shift 2 ;;
    --repeat) repeat=$2; shift 2 ;;
    --keep) keep=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "evals: unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$cases" ] || cases=$(cd "$here/cases" && ls -d */ | tr -d / | paste -sd, -)

stamp=$(date +%Y%m%d-%H%M%S)
work=${XDG_STATE_HOME:-$HOME/.local/state}/delegate-evals/$stamp
mkdir -p "$work" "$here/results"
out_md="$here/results/$stamp-$label.md"
out_jsonl="$here/results/$stamp-$label.jsonl"

if [ -n "$rules_ref" ]; then
  mkdir -p "$work/rules"
  git -C "$root" archive "$rules_ref" opencode | tar -x -C "$work/rules"
  export DELEGATE_RULES_DIR="$work/rules/opencode"
  rules_desc="$rules_ref ($(git -C "$root" rev-parse --short "$rules_ref"))"
else
  rules_desc="working tree ($(git -C "$root" rev-parse --short HEAD)$(git -C "$root" diff --quiet -- opencode || echo '+dirty'))"
fi

{
  echo "# evals — $label — $stamp"
  echo
  echo "rules: $rules_desc · model: $(set -a; . "${DELEGATE_CONFIG:-$HOME/.config/delegate/config.env}" 2>/dev/null; echo "${DELEGATE_MODEL:-?}") · repeat: $repeat"
  echo
  echo "| case | # | harness | hidden | verify | time | steps | tools (failed) | out tok | final ctx | nudges | diff |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|"
} > "$out_md"

for c in ${cases//,/ }; do
  cd_="$here/cases/$c"
  [ -f "$cd_/spec.md" ] || { echo "evals: no such case: $c" >&2; continue; }
  VERIFY="" SERVICE="" TIMEOUT=3600
  # shellcheck disable=SC1091
  . "$cd_/case.env"
  for i in $(seq 1 "$repeat"); do
    repo="$work/$c-$i/$c"
    mkdir -p "$repo"
    bash "$cd_/setup.sh" "$repo" "$cd_" > "$work/$c-$i/setup.log" 2>&1
    git -C "$repo" init -q -b main 2>/dev/null || true
    git -C "$repo" add -A && git -C "$repo" -c user.name=eval -c user.email=eval@localhost commit -qm "fixture: $c"
    name="eval-$stamp-$i"
    id="$c-$name"
    echo "evals: $c #$i ..." >&2
    args=(run "$cd_/spec.md" --repo "$repo" --name "$name" --timeout "$TIMEOUT")
    [ -n "$VERIFY" ] && args+=(--verify "$VERIFY")
    [ -n "$SERVICE" ] && args+=(--service "$SERVICE")
    "$root/bin/delegate" "${args[@]}" > "$work/$c-$i/report.txt" 2>&1 || true

    tdir=${DELEGATE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/delegate}/$id
    rj=$(ls -d "$tdir"/rounds/*/report.json 2>/dev/null | sort -V | tail -1 || true)
    wt=$(set -a; . "$tdir/meta.env"; echo "$WORKTREE")
    hpass=0 hfail=0
    if [ -d "$wt" ]; then
      rm -rf "$wt/.eval-hidden"; cp -r "$cd_/hidden" "$wt/.eval-hidden"
      "$root/bin/delegate" exec "$id" -- "bash .eval-hidden/check.sh" > "$work/$c-$i/hidden.log" 2>&1 || true
      rm -rf "$wt/.eval-hidden"
      hpass=$(grep -c '^PASS' "$work/$c-$i/hidden.log" || true)
      hfail=$(grep -c '^FAIL' "$work/$c-$i/hidden.log" || true)
    fi
    python3 - "$rj" "$c" "$i" "$hpass" "$hfail" "$out_md" "$out_jsonl" "$wt" <<'EOF'
import json, subprocess, sys
rj, case, i, hp, hf, md, jl, wt = sys.argv[1:]
r = json.load(open(rj)) if rj else {}
diff = "?"
try:
    base = subprocess.run(["git", "-C", wt, "rev-list", "--max-parents=0", "HEAD"], capture_output=True, text=True).stdout.split()[0]
    st = subprocess.run(["git", "-C", wt, "diff", "--shortstat", base, "HEAD", "--", ".", ":!package-lock.json"], capture_output=True, text=True).stdout
    ins = next((p.split()[0] for p in st.split(",") if "insert" in p), "0")
    dele = next((p.split()[0] for p in st.split(",") if "delet" in p), "0")
    diff = f"+{ins}/-{dele}"
except Exception:
    pass
hp, hf = int(hp), int(hf)
row = {"case": case, "i": int(i), "status": r.get("status", "no-report"), "hidden_pass": hp,
       "hidden_fail": hf, "verify_rc": r.get("verify_rc"), "duration_s": r.get("duration_s"),
       "steps": r.get("steps"), "tool_calls": r.get("tool_calls"),
       "tool_errors": len(r.get("tool_errors") or []), "output_tokens": r.get("output_tokens"),
       "final_context_tokens": r.get("final_context_tokens"), "nudges": r.get("nudges") or {},
       "diff": diff}
open(jl, "a").write(json.dumps(row) + "\n")
d = row["duration_s"] or 0
nud = ",".join(f"{k}:{v}" for k, v in row["nudges"].items()) or "-"
open(md, "a").write(
    f"| {case} | {i} | {row['status']} | {hp}/{hp + hf} | {row['verify_rc']} | {d // 60}m{d % 60:02d}s | "
    f"{row['steps']} | {row['tool_calls']} ({row['tool_errors']}) | {row['output_tokens']} | "
    f"{row['final_context_tokens']} | {nud} | {diff} |\n")
EOF
    [ "$keep" = 1 ] || "$root/bin/delegate" rm "$id" --delete-branch >/dev/null 2>&1 || true
  done
done

{
  echo
  echo "hidden = checks the worker never saw (PASS/total). Logs: $work"
} >> "$out_md"
cat "$out_md"
