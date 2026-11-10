// todo-loop.js — mechanical nudge to keep the session's todo list live.
//
// Same failure class as verify-ui.md §C, same fix: the capability exists, the model under-uses
// it, prose is the weak lever. opencode's todo widget is a pure projection of the LAST
// `todowrite` — statuses never advance on their own. Measured against the session store: the
// 2026-09-11T19:52 flappy session wrote one 7-item list (1 completed, 1 in_progress, 5 pending)
// and never rewrote it across the entire build; flappy4 wrote its list up front and rewrote it
// exactly once, as a victory lap after the work was done. The panel is fiction for most of the
// session's life. AGENTS.md cannot be edited mid-benchmark (it is a measured variable), so this
// hook is the lever.
//
// Design rules carried over from verify-loop.js the hard way:
//   - Nudge once per window, never per call. Per-call nagging teaches the model to batch its
//     one and only todowrite to the end — the exact dodge the per-edit verify reminders caused.
//   - State lives in the plugin process, not the transcript, so it survives context compaction.

const CALLS_BETWEEN_NUDGES = 8; // stale list: nudge every 8 calls since the last todowrite
const CALLS_WITHOUT_LIST = 12;  // no list at all: long enough that only real tasks reach it
// Was 2. Delegate rounds now run 100+ tool calls, and with two nudges the list went stale for
// most of the round: the dashboard showed a finished, verified round as 1 item in progress and
// 10 pending. A nudge is a short appended line, cheap at this spacing; a compliant model resets
// the budget anyway.
const MAX_NUDGES = 8;

// sessionID -> { calls, nudges, everListed }
const state = new Map();

export const TodoLoop = async () => ({
  "tool.execute.after": async (input, output) => {
    const st = state.get(input.sessionID) || { calls: 0, nudges: 0, everListed: false };
    state.set(input.sessionID, st);

    if (input.tool === "todowrite" || input.tool === "todo") {
      st.everListed = true;
      st.calls = 0;
      st.nudges = 0; // the model complied; refresh both the window and the budget
      return;
    }

    st.calls += 1;

    // stale: fires at 6, then at 12 (threshold advances with each nudge). barren: strict
    // equality so the no-list nudge can only ever fire once, not every call past 12.
    const stale = st.everListed && st.calls >= CALLS_BETWEEN_NUDGES * (st.nudges + 1);
    const barren = !st.everListed && st.calls === CALLS_WITHOUT_LIST;
    if ((!stale && !barren) || st.nudges >= MAX_NUDGES) return;
    st.nudges += 1;

    output.output +=
      "\n\n<todo-reminder>" +
      st.calls +
      " tool calls since your last todowrite. opencode's todo panel renders ONLY your last" +
      " todowrite — statuses never update themselves. Re-send the FULL list right now, with" +
      " honest statuses (completed / in_progress / pending); do not save the rewrite for the" +
      " end of the task." +
      (st.everListed
        ? ""
        : " This task is long enough to plan: write the list before the next step.") +
      "</todo-reminder>";
  },

  // Compaction is where "I have an open list and it is stale" gets summarized away.
  // Same re-injection mechanism verify-loop.js uses.
  "experimental.session.compacting": async (input, output) => {
    const st = state.get(input && input.sessionID);
    if (!st || !st.everListed || st.calls < CALLS_BETWEEN_NUDGES) return;
    output.context.push(
      "The session's todo list is " +
        st.calls +
        " tool calls stale. On resume, refresh it first with todowrite to match real progress" +
        " — panel statuses never advance on their own.",
    );
  },
});