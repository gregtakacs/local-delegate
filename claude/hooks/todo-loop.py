#!/usr/bin/env python3
"""todo-loop.py — Claude Code port of opencode/plugins/todo-loop.js (O1b step 4, design §5.2).

FIDELITY: the source of truth is opencode/plugins/todo-loop.js. The constants below are copied
from it verbatim (same names, same values); the nudge TEXT is Claude-specific (see reminder()). What deliberately differs: the JS plugin keeps its `state` Map in the server
process; a Claude command hook is a new process per call, so counters live in a per-session
file (hooklib) — same budgets, same windows, file-backed (design §5.2: "the JS in-memory state
does not port"). `stale`/`barren` windows and MAX_NUDGES are unchanged.

todo-loop.js:17-23:
    CALLS_BETWEEN_NUDGES = 8   // stale list: nudge every 8 calls since the last todowrite
    CALLS_WITHOUT_LIST   = 12  // no list at all: only real tasks reach it
    MAX_NUDGES           = 8   // was 2; rounds now run 100+ calls, two left the list stale
"""
import sys

sys.path.insert(0, __import__("os").path.dirname(__file__))
import hooklib  # noqa: E402

CALLS_BETWEEN_NUDGES = 8  # todo-loop.js:17
CALLS_WITHOUT_LIST = 12   # todo-loop.js:18
MAX_NUDGES = 8            # todo-loop.js:23


def reminder(st):
    """The `<todo-reminder>` block, identical to the JS plugin's appended text (todo-loop.js:49-59)."""
    # Claude Code wording (the JS budgets, not its text): Claude's list tool differs by version
    # (TodoWrite, the Task* tools) and some sessions have none, so the nudge names no tool and
    # never mentions opencode's panel (found live 2026-11-15 on 2.1.325, which has no todo tool).
    if st["ever_listed"]:
        body = (" tool calls since you last updated your task list. Bring it up to date now, with"
                " honest statuses (completed / in_progress / pending); do not save the update for"
                " the end of the task.")
    else:
        body = (" tool calls and no task list yet. If this session has a todo or task-list tool,"
                " this task is long enough to plan: write the list before the next step.")
    return "<todo-reminder>" + str(st["calls"]) + body + "</todo-reminder>"


def handle(event, st):
    """Advance the todo counters for one PostToolUse; return a reminder string or ''.

    `event` is the hook input JSON (uses `tool_name`). Mirrors todo-loop.js's
    tool.execute.after: a todowrite resets the window and budget; every other call advances
    it and, at the window edge, emits once.
    """
    tool = (event.get("tool_name") or "")
    if tool in ("TodoWrite", "todo", "TaskCreate", "TaskUpdate"):
        st["ever_listed"] = True
        st["calls"] = 0
        st["nudges"] = 0  # complied: refresh the window and the budget (todo-loop.js:36)
        return ""

    st["calls"] += 1
    stale = st["ever_listed"] and st["calls"] >= CALLS_BETWEEN_NUDGES * (st["nudges"] + 1)
    barren = (not st["ever_listed"]) and st["calls"] == CALLS_WITHOUT_LIST
    if (not stale and not barren) or st["nudges"] >= MAX_NUDGES:
        return ""
    st["nudges"] += 1
    return reminder(st)
