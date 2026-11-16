// todo-loop.js — mechanical nudge to keep the session's todo list live (OpenCode 2 plugin).
//
// Same failure class as verify-ui.md §C, same fix: the capability exists, the model under-uses
// it, prose is the weak lever. opencode's todo widget is a pure projection of the LAST
// `todowrite` — statuses never advance on their own. Measured against the session store: the
// 2026-09-11T19:52 flappy session wrote one 7-item list (1 completed, 1 in_progress, 5 pending)
// and never rewrote it across the entire build; flappy4 wrote its list up front and rewrote it
// exactly once, as a victory lap after the work was done. The panel is fiction for most of the
// session's life.
//
// OpenCode 2 ships `todowrite` behind the `experimental.todo` flag (off in release builds); the
// installer and the worker config turn it on. Without it there is no list to keep, and this plugin
// only reminds (2026-11-16: the model answered the reminder by listing its tools, no todowrite).
//
// Design rules carried over from verify-loop.js the hard way:
//   - Nudge once per window, never per call. Per-call nagging teaches the model to batch its
//     one and only todowrite to the end — the exact dodge the per-edit verify reminders caused.
//   - State lives in the plugin process, not the transcript, so it survives context compaction.
//   - Reminders ride on tool results (appended to the result's content); compaction context is
//     appended to the existing system text, never a new system message (see verify-loop.js).

const CALLS_BETWEEN_NUDGES = 8; // stale list: nudge every 8 calls since the last todowrite
const CALLS_WITHOUT_LIST = 12;  // no list at all: long enough that only real tasks reach it
// Was 2. Delegate rounds now run 100+ tool calls, and with two nudges the list went stale for
// most of the round: the dashboard showed a finished, verified round as 1 item in progress and
// 10 pending. A nudge is a short appended line, cheap at this spacing; a compliant model resets
// the budget anyway.
const MAX_NUDGES = 8;
// File-changing tools. The rules say "call the todo tool before editing" (harness-core §5); the
// 12-call barren window let a 6-call multi-file task finish with no list at all (live, 2026-11-15),
// so the FIRST change made with no list gets one reminder right away. Once per session, never per edit.
const EDIT_TOOLS = new Set(["write", "edit", "apply_patch"]);
const TODO_TOOLS = new Set(["todowrite", "todo"]);

// sessionID -> { calls, nudges, everListed, editNudged }
const state = new Map();

// A copy of a tool result whose model-facing content ends with `extra`. `content` is a string, an
// array of {type: "text"|"file"} parts, or absent (then the structured `output` was what the model
// saw, so it is carried over as text first).
function appendToResult(result, extra) {
  const r = result || {};
  if (typeof r.content === "string") return { ...r, content: r.content + extra };
  if (Array.isArray(r.content)) return { ...r, content: [...r.content, { type: "text", text: extra }] };
  const shown = r.output === undefined ? "" : typeof r.output === "string" ? r.output : JSON.stringify(r.output);
  return { ...r, content: shown ? [{ type: "text", text: shown }, { type: "text", text: extra }] : [{ type: "text", text: extra }] };
}

// Compaction context goes into the system text the compaction request already has: a second
// system message breaks openai-compatible chat templates (verify-loop.js).
function appendToSystem(event, text) {
  const parts = event.system;
  if (parts.length) parts[parts.length - 1].text += "\n\n" + text;
  else parts.push({ type: "text", text });
}

// One tool call, counted; returns the reminder text to append, or "".
function step(sessionID, tool) {
  const st = state.get(sessionID) || { calls: 0, nudges: 0, everListed: false, editNudged: false };
  state.set(sessionID, st);

  if (TODO_TOOLS.has(tool)) {
    st.everListed = true;
    st.calls = 0;
    st.nudges = 0; // the model complied; refresh both the window and the budget
    return "";
  }

  st.calls += 1;

  if (!st.everListed && !st.editNudged && EDIT_TOOLS.has(tool) && st.nudges < MAX_NUDGES) {
    st.editNudged = true;
    st.nudges += 1;
    return "<todo-reminder>You changed a file and this session has no todo list yet. The" +
      " harness rules ask for the list before editing: write it now with todowrite, with the" +
      " real steps including verification, and keep its statuses current.</todo-reminder>";
  }

  // stale: fires at 8, then at 16 (threshold advances with each nudge). barren: strict
  // equality so the no-list nudge can only ever fire once, not every call past 12.
  const stale = st.everListed && st.calls >= CALLS_BETWEEN_NUDGES * (st.nudges + 1);
  const barren = !st.everListed && st.calls === CALLS_WITHOUT_LIST;
  if ((!stale && !barren) || st.nudges >= MAX_NUDGES) return "";
  st.nudges += 1;

  return "<todo-reminder>" +
    st.calls +
    " tool calls since your last todowrite. opencode's todo panel renders ONLY your last" +
    " todowrite — statuses never update themselves. Re-send the FULL list right now, with" +
    " honest statuses (completed / in_progress / pending); do not save the rewrite for the" +
    " end of the task." +
    (st.everListed ? "" : " This task is long enough to plan: write the list before the next step.") +
    "</todo-reminder>";
}

export default {
  id: "delegate-todo-loop",
  async setup(context) {
    await context.tool.hook("execute.after", (event) => {
      const text = step(event.sessionID, event.tool);
      if (text && event.status === "completed") event.result = appendToResult(event.result, "\n\n" + text);
    });

    // Compaction is where "I have an open list and it is stale" gets summarized away.
    await context.session.hook("compaction", (event) => {
      const st = state.get(event.sessionID);
      if (!st || !st.everListed || st.calls < CALLS_BETWEEN_NUDGES) return;
      appendToSystem(event, "The session's todo list is " + st.calls +
        " tool calls stale. On resume, refresh it first with todowrite to match real progress" +
        " — panel statuses never advance on their own.");
    });
  },
};
