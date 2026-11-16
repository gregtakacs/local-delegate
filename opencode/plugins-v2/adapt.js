// adapt.js — run a delegate OpenCode 1.x plugin on OpenCode 2.x, unchanged.
//
// OpenCode 2 rejects the 1.x module shape (`export const X = async () => ({hooks})`): a plugin must
// default-export `{ id, setup(context) }` and register hooks through the context (found live on
// 2.3.0, 2026-11-16: all four plugins failed to load). The logic stays in ../plugins/*.js, which
// the worker image (OpenCode 1.x) keeps loading directly; this file only maps the hook shapes, so
// the two versions can never drift apart. Hook mapping (from @opencode/plugin 2.3.0's types):
//
//   1.x "tool.execute.after"  (input {tool, sessionID, args}, output {output})
//     -> context.tool.hook("execute.after"): text the 1.x hook appends to `output.output` is
//        appended to the 2.x tool result's `content` (the call's other fields are untouched).
//   1.x "tool.execute.before" (input {tool, args}, output {args}; a throw fails the call)
//     -> context.tool.transform: the tool's `execute` is wrapped so the 1.x check runs first and its
//        throw becomes the call's error, which reaches the model as the tool result.
//   1.x "tool.definition"     (input {toolID}, output {description, parameters})
//     -> context.tool.transform: the description the 1.x hook writes replaces the tool's.
//   1.x "experimental.session.compacting" (input {sessionID}, output {context: string[]})
//     -> context.session.hook("compaction"): each context line becomes a system part.
//
// OpenCode 2 renamed `bash` to `shell`; the 1.x hooks are told the 1.x name.

const V1_NAME = { shell: "bash" };

function asText(value) {
  if (value === undefined || value === null) return "";
  return typeof value === "string" ? value : JSON.stringify(value);
}

// A copy of `result` whose model-facing content ends with `extra`. `content` may be a string, an
// array of {type: "text"|"file"} parts, or absent (then the structured `output` is what was shown,
// so it is carried over as text first).
export function appendToResult(result, extra) {
  const r = result || {};
  const content = r.content;
  let next;
  if (typeof content === "string") next = content + extra;
  else if (Array.isArray(content)) next = [...content, { type: "text", text: extra }];
  else {
    const shown = asText(r.output);
    next = shown ? [{ type: "text", text: shown }, { type: "text", text: extra }] : [{ type: "text", text: extra }];
  }
  return { ...r, content: next };
}

export function adapt(id, factory) {
  return {
    id,
    async setup(context) {
      const hooks = (await factory({})) || {};
      const after = hooks["tool.execute.after"];
      const before = hooks["tool.execute.before"];
      const definition = hooks["tool.definition"];
      const compacting = hooks["experimental.session.compacting"];

      if (after) {
        await context.tool.hook("execute.after", async (event) => {
          if (event.status !== "completed") return;
          const out = { output: "" };
          await after({ tool: V1_NAME[event.tool] || event.tool, sessionID: event.sessionID, callID: event.id, args: event.input || {} }, out);
          if (out.output) event.result = appendToResult(event.result, out.output);
        });
      }

      if (before || definition) {
        await context.tool.transform((editor) => {
          for (const tool of editor.list()) {
            const v1 = V1_NAME[tool.id] || tool.id;
            editor.update(tool.id, (t) => {
              if (definition) {
                const out = { description: t.description, parameters: undefined };
                // tool.definition hooks are synchronous in effect; a returned promise is awaited
                // by the 1.x loader, here only its synchronous edits can land (they are).
                definition({ toolID: v1 }, out);
                if (typeof out.description === "string") t.description = out.description;
              }
              if (before) {
                const execute = t.execute;
                t.execute = async (input, ctx) => {
                  await before({ tool: v1, sessionID: ctx && ctx.sessionID, args: input || {} }, { args: input || {} });
                  return execute(input, ctx);
                };
              }
            });
          }
        });
      }

      if (compacting) {
        await context.session.hook("compaction", async (event) => {
          const out = { context: [] };
          await compacting({ sessionID: event.sessionID }, out);
          for (const text of out.context) event.system.push({ type: "text", text });
        });
      }
    },
  };
}
