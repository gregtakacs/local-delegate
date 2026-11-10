// notes-loop.js — external memory for long rounds.
//
// Long sessions are where the model degrades: opencode compacts the context, the summary drops
// the decisions and gotchas, and the model re-discovers (or contradicts) them. delegate-rules.md
// §9a asks the worker to keep $DELEGATE_EVIDENCE_DIR/NOTES.md; this plugin makes the two moments
// that matter unavoidable:
//   - after compaction, the notes file is named in the compacted context, so the next turn
//     reads it instead of guessing;
//   - one nudge, once the round is clearly long, if no notes file exists yet.
//
// Same constraints as verify-loop.js: no system-prompt transform (the vLLM/SGLang chat
// template rejects a second system message), reminders ride on tool results, once per window.

import { existsSync } from "node:fs";
import { join } from "node:path";

const dir = process.env.DELEGATE_EVIDENCE_DIR || "";
const notes = dir ? join(dir, "NOTES.md") : "";
const CALLS_BEFORE_NUDGE = 25;

// sessionID -> { calls, nudged }
const state = new Map();

export const NotesLoop = async () => ({
  "tool.execute.after": async (input, output) => {
    if (!notes) return;
    const st = state.get(input.sessionID) || { calls: 0, nudged: false };
    state.set(input.sessionID, st);
    st.calls += 1;
    if (st.nudged || st.calls < CALLS_BEFORE_NUDGE || existsSync(notes)) return;
    st.nudged = true;
    output.output +=
      "\n\n<notes-reminder>This round is long enough to need working notes (§9a). Create " +
      notes +
      " now: what is done, decisions and why, environment facts you had to discover (commands" +
      " that work, file locations, gotchas), and the next step. Update it after each milestone." +
      " It is what survives context compaction.</notes-reminder>";
  },

  "experimental.session.compacting": async (_input, output) => {
    if (!notes) return;
    output.context.push(
      existsSync(notes)
        ? "Your working notes are at " + notes + ". READ THEM FIRST after this compaction: they" +
            " hold your decisions, discovered environment facts and progress, which this summary" +
            " may have lost. Keep updating them."
        : "No working notes exist yet. Create " + notes + " before continuing (§9a), from what" +
            " this summary still holds.",
    );
  },
});
