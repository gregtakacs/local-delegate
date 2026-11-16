#!/bin/bash
# opencode/plugins-v2: the OpenCode 2.x entries for the four 1.x plugins, driven through a fake 2.x
# plugin context shaped like @opencode/plugin 2.3.0's (tool.hook / tool.transform / session.hook).
# Each entry default-exports {id, setup} (the shape 2.3.0 requires; the 1.x shape failed to load live
# 2026-11-16), and the adapter maps every 1.x hook the four plugins use. Runs node from PATH, else from a
# local node image with no network; skips cleanly when neither exists.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
driver=$(mktemp -d); trap 'rm -rf "$driver"' EXIT
cat > "$driver/drive.mjs" <<'JS'
const root = process.argv[2];
let fail = 0;
const ok = (c, m) => { console.log((c ? "ok   " : "FAIL ") + m); if (!c) fail = 1; };

function fakeContext(tools) {
  const after = [], compaction = [], transforms = [];
  const editor = {
    list: () => Object.entries(tools).map(([id, t]) => ({ id, ...t })),
    update: (id, fn) => { if (tools[id]) fn(tools[id]); },
  };
  return {
    ctx: {
      tool: {
        hook: async (name, cb) => { if (name === "execute.after") after.push(cb); return { dispose: async () => {} }; },
        transform: async (cb) => { transforms.push(cb); cb(editor); return { dispose: async () => {} }; },
      },
      session: { hook: async (name, cb) => { if (name === "compaction") compaction.push(cb); return { dispose: async () => {} }; } },
    },
    after, compaction, transforms,
  };
}
const toolSet = () => ({
  write: { description: "w", execute: async (input) => ({ content: "wrote " + input.path }) },
  edit: { description: "e", execute: async () => ({ content: [{ type: "text", text: "edited" }] }) },
  shell: { description: "s", execute: async () => ({ output: { exit: 0 } }) },
});

for (const name of ["chunk-cap", "notes-loop", "todo-loop", "verify-loop"]) {
  const mod = await import(`${root}/opencode/plugins-v2/${name}.js`);
  const def = mod.default;
  ok(def && typeof def.id === "string" && typeof def.setup === "function", `${name}: default export {id, setup}`);
}

// todo-loop: the first write with no list appends the reminder to the 2.x result content.
{
  const { default: plugin } = await import(`${root}/opencode/plugins-v2/todo-loop.js`);
  const f = fakeContext(toolSet());
  await plugin.setup(f.ctx);
  const ev = { tool: "write", sessionID: "s1", id: "c1", input: { path: "a.py", content: "x" }, status: "completed", result: { content: "Wrote a.py" } };
  for (const cb of f.after) await cb(ev);
  ok(typeof ev.result.content === "string" && ev.result.content.startsWith("Wrote a.py") && ev.result.content.includes("<todo-reminder>You changed a file"), "todo: reminder appended to a string result, original kept");
  const ev2 = { tool: "edit", sessionID: "s1", id: "c2", input: {}, status: "completed", result: { content: [{ type: "text", text: "ok" }] } };
  for (const cb of f.after) await cb(ev2);
  ok(Array.isArray(ev2.result.content) && ev2.result.content.length === 1, "todo: no second reminder, array result untouched");
  const ev3 = { tool: "write", sessionID: "s2", id: "c3", input: {}, status: "error", error: { message: "x" } };
  for (const cb of f.after) await cb(ev3);
  ok(!("result" in ev3), "todo: failed calls are left alone");
}

// adapter: array and output-only results.
{
  const { appendToResult } = await import(`${root}/opencode/plugins-v2/adapt.js`);
  const a = appendToResult({ content: [{ type: "text", text: "one" }], metadata: { k: 1 } }, "R");
  ok(a.content.length === 2 && a.content[1].text === "R" && a.metadata.k === 1, "append to an array result keeps parts and metadata");
  const b = appendToResult({ output: { exit: 0 } }, "R");
  ok(b.content[0].text === '{"exit":0}' && b.content[1].text === "R" && b.output.exit === 0, "output-only result: output shown as text, then the reminder");
}

// verify-loop: a UI file edit gets its reminder through the same path (2.x arg name `path`).
{
  const { default: plugin } = await import(`${root}/opencode/plugins-v2/verify-loop.js`);
  const f = fakeContext(toolSet());
  await plugin.setup(f.ctx);
  const ev = { tool: "write", sessionID: "v1", id: "c1", input: { path: "src/App.tsx", content: "x" }, status: "completed", result: { content: "Wrote" } };
  for (const cb of f.after) await cb(ev);
  ok(ev.result.content.length > "Wrote".length, "verify: a UI-file write gets the verify reminder");
  const evc = { sessionID: "v1", system: [] };
  for (const cb of f.compaction) await cb(evc);
  ok(evc.system.length >= 1 && evc.system[0].type === "text", "verify: pending UI file re-injected at compaction as a system part");
}

// chunk-cap: an oversize write fails the call before the tool runs; descriptions rewritten.
{
  const { default: plugin } = await import(`${root}/opencode/plugins-v2/chunk-cap.js`);
  const tools = toolSet();
  let ran = false;
  tools.write.execute = async () => { ran = true; return { content: "wrote" }; };
  const f = fakeContext(tools);
  await plugin.setup(f.ctx);
  let err = null;
  try { await tools.write.execute({ path: "big.txt", content: "x".repeat(200000) }, {}); } catch (e) { err = e; }
  ok(err && !ran, "chunk-cap: oversize write rejected before the tool runs");
  const small = await tools.write.execute({ path: "s.txt", content: "x" }, {});
  ok(ran && small.content === "wrote", "chunk-cap: a small write runs normally");
  ok(tools.write.description !== "w" && tools.edit.description !== "e", "chunk-cap: write/edit descriptions rewritten");
  ok(tools.shell.description !== "s", "chunk-cap: the 2.x `shell` tool gets the 1.x `bash` description edit");
}
process.exit(fail);
JS
if command -v node >/dev/null 2>&1; then
  node "$driver/drive.mjs" "$here"; rc=$?
elif command -v docker >/dev/null 2>&1 && docker image inspect node:24-trixie-slim >/dev/null 2>&1; then
  docker run --rm --network none -v "$driver:/d:ro" -v "$here/opencode:/r/opencode:ro" \
    node:24-trixie-slim node /d/drive.mjs /r; rc=$?
else
  echo "SKIP test_plugins_v2 (no node, no local node:24-trixie-slim image)"; exit 0
fi
if [ "$rc" = 0 ]; then echo "PASS test_plugins_v2"; else echo "FAIL test_plugins_v2"; fi
exit "$rc"
