cd "$(dirname "$0")/.."
node .eval-hidden/check.mjs
# DOM check: render the real page headless and inspect what it shows.
out=$(chromium --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --allow-file-access-from-files \
      --virtual-time-budget=4000 --dump-dom "file://$PWD/index.html" 2>/dev/null)
for id in bill tip people roundup out-tip out-total out-per error; do
  echo "$out" | grep -q "id=\"$id\"" && echo "PASS dom #$id" || echo "FAIL dom #$id"
done
echo "$out" | grep -q 'data-tip="15"' && echo "PASS dom presets" || echo "FAIL dom presets"
echo "$out" | grep -qE 'NaN|undefined' && echo "FAIL dom shows NaN/undefined" || echo "PASS dom no NaN/undefined"
grep -q 'fetch(' index.html tip.js && echo "FAIL uses fetch" || echo "PASS no fetch"
n=$(ls "$DELEGATE_EVIDENCE_DIR"/*.png "$DELEGATE_EVIDENCE_DIR"/*/*.png 2>/dev/null | wc -l)
[ "$n" -ge 4 ] && echo "PASS screenshots ($n)" || echo "FAIL screenshots ($n < 4)"
