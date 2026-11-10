cd "$(dirname "$0")/.."
rm -rf /tmp/eval-orig && python3 .eval-hidden/gen.py /tmp/eval-orig >/dev/null
node .eval-hidden/check.mjs /tmp/eval-orig
n=$(grep -rn oldLog src test 2>/dev/null | wc -l); [ "$n" = 0 ] && echo "PASS no oldLog" || echo "FAIL oldLog remains ($n)"
node --test >/dev/null 2>&1 && echo "PASS suite" || echo "FAIL suite"
