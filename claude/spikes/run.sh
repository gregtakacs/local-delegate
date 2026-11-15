#!/bin/bash
# run.sh — run the O1b hook spike probes (docs/specs/o1b-design.md §6) and print one
# SPIKE line per probe plus a summary. Probes that cannot run here (no Claude Code
# login, no opencode) print NOT-RUN-HERE and exit 0; only a real FAIL exits 1.
#
#   run.sh              run every probe
#   run.sh --dry-run    print each probe's exact command lines, run nothing, exit 0
#   run.sh --only <id>  run one probe: <id> matches S1..S7 or a substring of the script name
#   run.sh --help       usage
set -u
cd "$(dirname "$0")"

PROBES="probe-s1-posttooluse probe-s2-notes probe-s3-permission-request
probe-s4-permissions-syntax probe-s5-opencode-reach probe-s6-clinerules
probe-s7-rules-load"

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  --help|-h)
    usage; exit 0 ;;
  --dry-run)
    for p in $PROBES; do
      bash "./$p.sh" --commands
    done
    exit 0 ;;
  --only)
    [ $# -ge 2 ] || { echo "run.sh --only needs a probe id (S1..S7 or a name substring)" >&2; exit 2; }
    low=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
    found=""
    for p in $PROBES; do
      id="s${p#probe-s}"; id="${id%%-*}"
      case "$p" in
        "$low"*|*"$low"*) found="$p"; break ;;
      esac
      [ "$id" = "$low" ] && { found="$p"; break; }
    done
    [ -n "$found" ] || { echo "no probe matches '$2'" >&2; exit 2; }
    exec bash "./$found.sh" ;;
  "") ;;
  *)
    echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

pass=0; fails=0; skipped=0; rc=0
for p in $PROBES; do
  line=$(bash "./$p.sh" 2>&1 | grep -E '^SPIKE ' | tail -1) || true
  if [ -z "$line" ]; then
    line="SPIKE ${p#probe-}: FAIL — probe printed no SPIKE line"
  fi
  printf '%s\n' "$line"
  case "$line" in
    *": PASS"*) pass=$((pass+1)) ;;
    *": FAIL"*) fails=$((fails+1)); rc=1 ;;
    *": NOT-RUN-HERE"*) skipped=$((skipped+1)) ;;
    *) fails=$((fails+1)); rc=1 ;;
  esac
done
printf 'SPIKE summary: %d PASS, %d FAIL, %d NOT-RUN-HERE\n' "$pass" "$fails" "$skipped"
exit "$rc"
