// verify-loop.js — mechanical enforcement of the worker's UI verification rule (OpenCode 2 plugin).
//
// AGENTS.md is advisory: a model under context pressure drops it. This makes the nudge
// unavoidable by appending a reminder to the tool result of a UI file edit. opencode's own system
// prompt already instructs the model to act on reminder tags found in tool results, which is why
// this hook is the cheapest reliable lever available.
//
// Seeded into the worker's ~/.config/opencode/plugins/ per task, and linked into an interactive
// install's plugins dir by install.sh.

const UI = /\.(html?|css|jsx|tsx|vue|svelte|astro|mdx)$/i;
const EDIT_TOOLS = new Set(["write", "edit", "apply_patch"]);

// sessionID -> Set of UI files edited and not yet visually verified.
const pending = new Map();

// sessionID+file -> true once the reminder has fired for it. The reminder used to be appended
// after EVERY UI edit, which taxed each enrichment pass with a mandatory full screenshot sweep --
// so the cheapest way to satisfy it was to write the whole artifact in one `write` and sweep once.
// That is the exact behaviour verify-ui.md §C forbids, and it measured out real: the one-shot runs
// landed at 239/252 lines, the run that enriched over 8 passes landed at 490. Reminding once per
// file per session keeps the gate and removes the incentive to one-shot.
const reminded = new Set();

// NOTE: there is deliberately NO system-prompt hook adding a system message here. Extra system
// content made opencode emit a second system message, which the vLLM/SGLang chat template rejects
// with "System message must be at the beginning." (reproduced against an SGLang-served model) —
// every request in the session fails. Compaction context below is appended to the system text the
// request already has, never a new message. Re-test against the openai-compatible endpoint before
// changing that.

function appendToResult(result, extra) {
  const r = result || {};
  if (typeof r.content === "string") return { ...r, content: r.content + extra };
  if (Array.isArray(r.content)) return { ...r, content: [...r.content, { type: "text", text: extra }] };
  const shown = r.output === undefined ? "" : typeof r.output === "string" ? r.output : JSON.stringify(r.output);
  return { ...r, content: shown ? [{ type: "text", text: shown }, { type: "text", text: extra }] : [{ type: "text", text: extra }] };
}

function appendToSystem(event, text) {
  const parts = event.system;
  if (parts.length) parts[parts.length - 1].text += "\n\n" + text;
  else parts.push({ type: "text", text });
}

export default {
  id: "delegate-verify-loop",
  async setup(context) {
    await context.tool.hook("execute.after", (event) => {
      if (event.status !== "completed" || !EDIT_TOOLS.has(event.tool)) return;
      const args = event.input || {};
      const file = args.path || args.filePath || args.file_path || "";
      if (!UI.test(file)) return;

      if (!pending.has(event.sessionID)) pending.set(event.sessionID, new Set());
      pending.get(event.sessionID).add(file);

      // One reminder per file per session. The compaction hook below is the repeat mechanism.
      const seen = event.sessionID + "\0" + file;
      if (reminded.has(seen)) return;
      reminded.add(seen);

      event.result = appendToResult(event.result,
        "\n\n<verify-reminder>UI file changed: " + file +
        ". Per ~/.config/opencode/rules/verify-ui.md §C: GROW THE ARTIFACT FIRST (§C's edit" +
        " cap makes one-shot writes impossible — grow it feature by feature until the §10" +
        " enumeration is exhausted), then do" +
        " ONE sweep: capture and READ a screenshot of every user-visible state of it (`delegate-shot` is" +
        " in the image) before ending the task. Do not verify between passes, and do not one-shot" +
        " the whole file to dodge this reminder. If no renderer is available, say so out loud.</verify-reminder>");
    });

    // Compaction is where a long session loses "I still owe a screenshot". Re-inject it.
    await context.session.hook("compaction", (event) => {
      const open = [...(pending.get(event.sessionID) || [])];
      if (!open.length) return;
      appendToSystem(event, "UI files edited this session that still lack visual verification" +
        " (verify-ui.md before finishing): " + JSON.stringify(open));
    });
  },
};
