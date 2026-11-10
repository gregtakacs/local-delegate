// verify-loop.js — mechanical enforcement of the worker's UI verification rule.
//
// AGENTS.md is advisory: a model under context pressure drops it. This makes the nudge
// unavoidable by appending a reminder to the tool result of every UI file edit. opencode's
// own system prompt already instructs the model to act on <system-reminder> tags found in
// tool results, which is why this hook is the cheapest reliable lever available.
//
// Seeded into ~/.config/opencode/plugins/ by entrypoint.sh — that dir is regenerated per
// boot and is not a named volume, so it must be copied, not mounted.

const UI = /\.(html?|css|jsx|tsx|vue|svelte|astro|mdx)$/i;

// sessionID -> Set of UI files edited and not yet visually verified.
const pending = new Map();

// sessionID+file -> true once the reminder has fired for it. The reminder used to be appended
// after EVERY UI edit, which taxed each enrichment pass with a mandatory full screenshot sweep --
// so the cheapest way to satisfy it was to write the whole artifact in one `write` and sweep once.
// That is the exact behaviour verify-ui.md §C forbids, and it measured out real: the one-shot runs
// landed at 239/252 lines, the run that enriched over 8 passes landed at 490. Reminding once per
// file per session keeps the gate and removes the incentive to one-shot.
const reminded = new Set();

// NOTE: there is deliberately NO `experimental.chat.system.transform` hook here. Pushing
// into `output.system` makes opencode emit system content the vLLM chat template rejects
// with "System message must be at the beginning." (reproduced against an SGLang-served model),
// which kills every request in the session -- a total failure, not a degraded
// one. §1 and §4 of AGENTS.md already carry the instruction, and the reminder below is the
// part that actually fires at the moment of decision. Do not re-add a system hook without
// re-testing against the openai-compatible endpoint.
export const VerifyLoop = async () => ({
  "tool.execute.after": async (input, output) => {
    const isEdit = input.tool === "write" || input.tool === "edit" || input.tool === "apply_patch";
    if (!isEdit) return;

    const args = input.args || {};
    const file = args.filePath || args.path || args.file_path || "";
    if (!UI.test(file)) return;

    if (!pending.has(input.sessionID)) pending.set(input.sessionID, new Set());
    pending.get(input.sessionID).add(file);

    // One reminder per file per session. The compaction hook below is the repeat mechanism.
    const seen = input.sessionID + "\0" + file;
    if (reminded.has(seen)) return;
    reminded.add(seen);

    output.output +=
      "\n\n<verify-reminder>UI file changed: " + file +
      ". Per ~/.config/opencode/rules/verify-ui.md \u00a7C: GROW THE ARTIFACT FIRST (\u00a7C's 6000-char" +
      " cap makes one-shot writes impossible \u2014 grow it feature by feature until the \u00a710" +
      " enumeration is exhausted), then do" +
      " ONE sweep: capture and READ a screenshot of every user-visible state of it (`delegate-shot` is" +
      " in the image) before ending the task. Do not verify between passes, and do not one-shot" +
      " the whole file to dodge this reminder. If no renderer is available, say so out loud.</verify-reminder>";
  },

  // Compaction is where a long session loses "I still owe a screenshot". Re-inject it.
  "experimental.session.compacting": async (_input, output) => {
    const open = [...pending.values()].flatMap((s) => [...s]);
    if (!open.length) return;
    output.context.push(
      "UI files edited this session that still lack visual verification (verify-ui.md" +
        " before finishing): " + JSON.stringify(open),
    );
  },
});
