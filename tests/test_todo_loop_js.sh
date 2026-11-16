#!/bin/bash
# opencode/plugins/todo-loop.js, driven directly: the first file change made with no todo list gets
# one reminder at once (harness-core §5 "before editing"; a 6-call task finished listless under the
# 12-call window, live 2026-11-15), never twice, never for a session with a list, never for reads;
# the stale and barren windows keep their timing. Runs node from PATH, else from a local node image
# (no network); skips cleanly when neither exists.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
driver=$(mktemp -d); trap 'rm -rf "$driver"' EXIT
cat > "$driver/drive.mjs" <<'JS'
const { TodoLoop } = await import(process.argv[2]);
const hooks = await TodoLoop();
const after = hooks["tool.execute.after"];
let fail = 0;
const ok = (c, m) => { console.log((c ? "ok   " : "FAIL ") + m); if (!c) fail = 1; };
const call = async (sid, tool) => { const o = { output: "" }; await after({ sessionID: sid, tool }, o); return o.output; };

let o = await call("a", "write");
ok(o.includes("<todo-reminder>You changed a file and this session has no todo list yet"), "first write with no list nudges at once");
ok(!(await call("a", "edit")).includes("<todo-reminder>"), "second change: no repeat");
await call("b", "todowrite");
ok(!(await call("b", "write")).includes("<todo-reminder>"), "session with a list: no first-edit nudge");
ok(!(await call("c", "read")).includes("<todo-reminder>"), "read-only call: no nudge");
ok((await call("d", "patch")).includes("You changed a file"), "opencode 1 patch counts as a change");
let hit = 0;
for (let i = 1; i <= 13; i++) { if ((await call("e", "shell")).includes("long enough to plan")) hit = i; }
ok(hit === 12, "no-list, no-edit session still nudges once at call 12 (got " + hit + ")");
await call("f", "todowrite");
let first = 0;
for (let i = 1; i <= 8; i++) { if ((await call("f", "edit")).includes("<todo-reminder>") && !first) first = i; }
ok(first === 8, "listed session: stale nudge still at call 8 (got " + first + ")");
process.exit(fail);
JS
plugin=$here/opencode/plugins/todo-loop.js
if command -v node >/dev/null 2>&1; then
  node "$driver/drive.mjs" "$plugin"; rc=$?
elif command -v docker >/dev/null 2>&1 && docker image inspect node:24-trixie-slim >/dev/null 2>&1; then
  docker run --rm --network none -v "$driver:/d:ro" -v "$here/opencode/plugins:/p:ro" \
    node:24-trixie-slim node /d/drive.mjs /p/todo-loop.js; rc=$?
else
  echo "SKIP test_todo_loop_js (no node, no local node:24-trixie-slim image)"; exit 0
fi
if [ "$rc" = 0 ]; then echo "PASS test_todo_loop_js"; else echo "FAIL test_todo_loop_js"; fi
exit "$rc"
