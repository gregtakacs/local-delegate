cd "$(dirname "$0")/.." && node .eval-hidden/check.mjs
n=$(grep -cE '"#4[1-5]' test/duration.test.js 2>/dev/null); n=${n:-0}
[ "$n" -ge 5 ] && echo "PASS regression tests named per issue ($n)" || echo "FAIL regression tests named per issue ($n < 5)"
