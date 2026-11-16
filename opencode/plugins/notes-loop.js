// notes-loop.js — external memory for long rounds (OpenCode 2 plugin).
//
// Long sessions are where the model degrades: opencode compacts the context, the summary drops
// the decisions and gotchas, and the model re-discovers (or contradicts) them. delegate-rules.md
// §9a asks the worker to keep $DELEGATE_EVIDENCE_DIR/NOTES.md; this plugin makes the two moments
// that matter unavoidable:
//   - at compaction, the notes file is named in the compaction request, so the next turn reads it
//     instead of guessing;
//   - one nudge, once the round is clearly long, if no notes file exists yet.
//
// Same constraints as verify-loop.js: no second system message (the vLLM/SGLang chat template
// rejects it), reminders ride on tool results, once per window.

import { existsSync } from "node:fs";
import { join } from "node:path";

// A headless worker round names its notes file via DELEGATE_EVIDENCE_DIR (delegate-rules.md §9a).
// An interactive session has none, so §5.1 gives it the same external memory at the path the
// core+adapter name: /tmp/opencode-notes/<basename(cwd)>/NOTES.md, cwd being the server's project
// dir. The nudge rules are identical for both — the fallback only changes WHERE the file is.
const dir = process.env.DELEGATE_EVIDENCE_DIR || "";
const fallback = "/tmp/opencode-notes/" + (process.cwd().replace(/\/+$/, "").split("/").pop() || "session") + "/NOTES.md";
const notes = dir ? join(dir, "NOTES.md") : fallback;
const CALLS_BEFORE_NUDGE = 25;

// sessionID -> { calls, nudged }
const state = new Map();

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
  id: "delegate-notes-loop",
  async setup(context) {
    await context.tool.hook("execute.after", (event) => {
      const st = state.get(event.sessionID) || { calls: 0, nudged: false };
      state.set(event.sessionID, st);
      st.calls += 1;
      if (event.status !== "completed" || st.nudged || st.calls < CALLS_BEFORE_NUDGE || existsSync(notes)) return;
      st.nudged = true;
      event.result = appendToResult(event.result,
        "\n\n<notes-reminder>This round is long enough to need working notes (§9a). Create " +
        notes +
        " now: what is done, decisions and why, environment facts you had to discover (commands" +
        " that work, file locations, gotchas), and the next step. Update it after each milestone." +
        " It is what survives context compaction.</notes-reminder>");
    });

    await context.session.hook("compaction", (event) => {
      appendToSystem(event, existsSync(notes)
        ? "Your working notes are at " + notes + ". READ THEM FIRST after this compaction: they" +
            " hold your decisions, discovered environment facts and progress, which this summary" +
            " may have lost. Keep updating them."
        : "No working notes exist yet. Create " + notes + " before continuing (§9a), from what" +
            " this summary still holds.");
    });
  },
};
