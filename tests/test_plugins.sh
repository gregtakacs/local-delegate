#!/bin/bash
# opencode/plugins: the four OpenCode 2 plugins, driven through a fake plugin context shaped like
# @opencode/plugin 2.3.0's (tool.hook / tool.transform / session.hook). Each must default-export
# {id, setup} (2.3.0 refuses anything else: live, 2026-11-16) and nothing else. Behaviour: the todo
# windows (first edit, barren 12, stale 8), the UI verify reminder, the notes nudge, the chunk cap
# rejecting before the tool runs, and compaction context added to the EXISTING system text (a second
# system message breaks the SGLang chat template). Runs node from PATH, else a local node image with
# no network; skips cleanly when neither exists.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
driver=$(mktemp -d); trap 'rm -rf "$driver"' EXIT
cat > "$driver/drive.mjs" <<'JS'
const root = process.argv[2];
let fail = 0;
const ok = (c, m) => { console.log((c ? "ok   " : "FAIL ") + m); if (!c) fail = 1; };

function fakeContext(tools = {}) {
  const after = [], compaction = [];
  const editor = { update: (id, fn) => { if (tools[id]) fn(tools[id]); } };
  return {
    ctx: {
      tool: {
        hook: async (name, cb) => { if (name === "execute.after") after.push(cb); return { dispose: async () => {} }; },
        transform: async (cb) => { cb(editor); return { dispose: async () => {} }; },
      },
      session: { hook: async (name, cb) => { if (name === "compaction") compaction.push(cb); return { dispose: async () => {} }; } },
    },
    after, compaction,
  };
}
const fire = async (f, ev) => { for (const cb of f.after) await cb(ev); return ev; };
const done = (sessionID, tool, input = {}, result = { content: "ok" }) => ({ tool, sessionID, id: "c", input, status: "completed", result });

const NAMES = ["chunk-cap", "notes-loop", "todo-loop", "verify-loop"];
for (const name of NAMES) {
  const mod = await import(`${root}/opencode/plugins/${name}.js?${Date.now()}`);
  ok(mod.default && typeof mod.default.id === "string" && typeof mod.default.setup === "function", `${name}: default export {id, setup}`);
  ok(Object.keys(mod).join() === "default", `${name}: no other exports (2.x loads the default only)`);
}

// todo-loop
{
  const { default: p } = await import(`${root}/opencode/plugins/todo-loop.js`);
  const f = fakeContext(); await p.setup(f.ctx);
  let ev = await fire(f, done("t1", "write", { path: "a.py" }, { content: "Wrote a.py" }));
  ok(ev.result.content.startsWith("Wrote a.py") && ev.result.content.includes("<todo-reminder>You changed a file"), "todo: first write with no list -> reminder appended to the result");
  ev = await fire(f, done("t1", "edit", {}, { content: [{ type: "text", text: "ok" }] }));
  ok(ev.result.content.length === 1, "todo: not repeated on the next change");
  await fire(f, done("t2", "todowrite"));
  ev = await fire(f, done("t2", "write", {}, { content: "w" }));
  ok(ev.result.content === "w", "todo: a session with a list gets no first-edit reminder");
  ev = await fire(f, done("t3", "read", {}, { content: "r" }));
  ok(ev.result.content === "r", "todo: reads get nothing");
  let hit = 0;
  for (let i = 1; i <= 13; i++) { const e = await fire(f, done("t4", "shell", {}, { content: "s" })); if (e.result.content.includes("long enough to plan")) hit = i; }
  ok(hit === 12, "todo: no-list session without edits nudged once, at call 12 (got " + hit + ")");
  await fire(f, done("t5", "todowrite"));
  let first = 0;
  for (let i = 1; i <= 8; i++) { const e = await fire(f, done("t5", "shell", {}, { content: "s" })); if (e.result.content.includes("<todo-reminder>") && !first) first = i; }
  ok(first === 8, "todo: stale list nudged at call 8 (got " + first + ")");
  const err = { tool: "write", sessionID: "t6", id: "c", input: {}, status: "error", error: { message: "x" } };
  await fire(f, err);
  ok(!("result" in err), "todo: failed calls are never given a result");
  const ce = { sessionID: "t5", system: [{ type: "text", text: "SYS" }] };
  for (const cb of f.compaction) await cb(ce);
  ok(ce.system.length === 1 && ce.system[0].text.startsWith("SYS") && ce.system[0].text.includes("tool calls stale"), "todo: compaction note appended to the existing system text, no new system part");
  const ev2 = await fire(f, done("t7", "write", {}, { output: { bytes: 2 } }));
  ok(Array.isArray(ev2.result.content) && ev2.result.content[0].text === '{"bytes":2}' && ev2.result.content[1].text.includes("todo-reminder"), "todo: an output-only result keeps its output, then the reminder");
}

// verify-loop
{
  const { default: p } = await import(`${root}/opencode/plugins/verify-loop.js`);
  const f = fakeContext(); await p.setup(f.ctx);
  let ev = await fire(f, done("v1", "write", { path: "src/App.tsx" }, { content: "Wrote" }));
  ok(ev.result.content.includes("<verify-reminder>UI file changed: src/App.tsx"), "verify: UI-file write -> reminder (2.x arg `path`)");
  ev = await fire(f, done("v1", "edit", { path: "src/App.tsx" }, { content: "Edited" }));
  ok(ev.result.content === "Edited", "verify: once per file per session");
  ev = await fire(f, done("v1", "write", { path: "server.py" }, { content: "W" }));
  ok(ev.result.content === "W", "verify: non-UI files ignored");
  const ce = { sessionID: "v1", system: [{ type: "text", text: "SYS" }] };
  for (const cb of f.compaction) await cb(ce);
  ok(ce.system.length === 1 && ce.system[0].text.includes("src/App.tsx"), "verify: pending UI file re-injected into the existing system text");
  const other = { sessionID: "v2", system: [{ type: "text", text: "SYS" }] };
  for (const cb of f.compaction) await cb(other);
  ok(other.system[0].text === "SYS", "verify: another session's compaction does not list this session's files");
}

// notes-loop (no DELEGATE_EVIDENCE_DIR: the /tmp/opencode-notes fallback, which does not exist here)
{
  const { default: p } = await import(`${root}/opencode/plugins/notes-loop.js`);
  const f = fakeContext(); await p.setup(f.ctx);
  let hit = 0;
  for (let i = 1; i <= 26; i++) { const e = await fire(f, done("n1", "shell", {}, { content: "s" })); if (e.result.content.includes("<notes-reminder>")) hit = hit || i; }
  ok(hit === 25, "notes: one nudge at call 25 when no notes file exists (got " + hit + ")");
  const ce = { sessionID: "n1", system: [] };
  for (const cb of f.compaction) await cb(ce);
  ok(ce.system.length === 1 && ce.system[0].text.includes("NOTES.md"), "notes: compaction names the notes file (a part is added only when the request has none)");
}

// chunk-cap
{
  const { default: p } = await import(`${root}/opencode/plugins/chunk-cap.js`);
  let ran = 0;
  const tools = {
    write: { description: "w", execute: async () => { ran++; return { content: "wrote" }; } },
    edit: { description: "e", execute: async () => { ran++; return { content: "edited" }; } },
    shell: { description: "s", execute: async () => ({ content: "ran" }) },
  };
  const f = fakeContext(tools); await p.setup(f.ctx);
  let err = null;
  try { await tools.write.execute({ path: "big.txt", content: "x".repeat(8001) }, {}); } catch (e) { err = e; }
  ok(err && /content was 8001 characters, exceeding the recommended limit of 8000/.test(err.message) && ran === 0, "chunk-cap: an 8001-char write is rejected before the tool runs, Cline's wording");
  err = null;
  try { await tools.edit.execute({ path: "f", oldString: "a", newString: "y".repeat(9000) }, {}); } catch (e) { err = e; }
  ok(err && /newString was 9000/.test(err.message) && ran === 0, "chunk-cap: an oversize edit newString rejected");
  const small = await tools.write.execute({ path: "s.txt", content: "x".repeat(8000) }, {});
  ok(ran === 1 && small.content === "wrote", "chunk-cap: exactly 8000 chars runs normally");
  ok(tools.write.description.includes("Keep this at or below 8000") && tools.edit.description.includes("Keep this at or below 8000") && tools.shell.description.includes("within 16000"), "chunk-cap: write/edit/shell descriptions carry Cline's guidance");
}
process.exit(fail);
JS
if command -v node >/dev/null 2>&1; then
  node "$driver/drive.mjs" "$here"; rc=$?
elif command -v docker >/dev/null 2>&1 && docker image inspect node:24-trixie-slim >/dev/null 2>&1; then
  docker run --rm --network none -v "$driver:/d:ro" -v "$here/opencode:/r/opencode:ro" \
    node:24-trixie-slim node /d/drive.mjs /r; rc=$?
else
  echo "SKIP test_plugins (no node, no local node:24-trixie-slim image)"; exit 0
fi
if [ "$rc" = 0 ]; then echo "PASS test_plugins"; else echo "FAIL test_plugins"; fi
exit "$rc"
