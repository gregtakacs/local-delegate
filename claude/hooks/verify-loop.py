#!/usr/bin/env python3
"""verify-loop.py — Claude Code port of opencode/plugins/verify-loop.js (O1b step 4, design §5.2).

FIDELITY: the source of truth is opencode/plugins/verify-loop.js. Same UI regex, same
once-per-file-per-session rule (verify-loop.js:16-22 — the reason it is once, not every edit:
per-edit reminders taxed every pass and measured into one-shot writes, the exact behaviour
verify-ui.md §C forbids), same pending set for the compaction re-injection. The reminder TEXT
is adapted for Claude Code: it points at the installed UI rule rather than the in-repo path.
Where that rule lives is a path detail only Claude Code changes — the UI rule ships INSIDE the
concatenated ~/.claude/rules/delegate-harness.md (install step 5), so the reminder names the
file and the §C section to open, and cites the legacy ~/.claude/rules/delegate-verify-ui.md
name the spec's reminder uses.

verify-loop.js:11 UI = /\\.(html?|css|jsx|tsx|vue|svelte|astro|mdx)$/i
"""
import re
import sys

sys.path.insert(0, __import__("os").path.dirname(__file__))
import hooklib  # noqa: E402

UI = re.compile(r"\.(html?|css|jsx|tsx|vue|svelte|astro|mdx)$", re.I)  # verify-loop.js:11


def _edited_file(event):
    ti = event.get("tool_input") or {}
    if not isinstance(ti, dict):
        return ""
    for k in ("file_path", "filePath", "path", "notebook_path"):
        v = ti.get(k)
        if isinstance(v, str) and v:
            return v
    return ""


def reminder(path):
    # verify-loop.js:48-55, re-pointed at the Claude Code install path. The §C rationale (grow
    # the artifact first, then ONE sweep) is the load-bearing part; do not reword it away.
    return (
        "<verify-reminder>UI file changed: " + path +
        ". Per delegate's UI rule (§C: read ~/.claude/rules/delegate-verify-ui.md, which ships"
        " inside ~/.claude/rules/delegate-harness.md): GROW THE ARTIFACT FIRST (\u00a7C grows it"
        " feature by feature until the \u00a710 enumeration is exhausted), then do"
        " ONE sweep: capture and READ a screenshot of every user-visible state of it before ending"
        " the task. Do not verify between passes, and do not one-shot the whole file to dodge this"
        " reminder. If no renderer is available, say so out loud.</verify-reminder>"
    )


def handle(event, st):
    """One PostToolUse for an Edit/Write; remind once per UI file per session. Returns a string or ''."""
    tool = (event.get("tool_name") or "")
    if tool not in ("Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch"):
        return ""
    path = _edited_file(event)
    if not path or not UI.search(path):
        return ""

    if path not in st["ui_pending"]:
        st["ui_pending"].append(path)

    if path in st["ui_reminded"]:  # one reminder per file per session (verify-loop.js:45)
        return ""
    st["ui_reminded"].append(path)
    return reminder(path)
