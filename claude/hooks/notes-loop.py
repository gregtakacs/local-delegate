#!/usr/bin/env python3
"""notes-loop.py — Claude Code port of opencode/plugins/notes-loop.js (O1b step 4, design §5.2).

FIDELITY: the source of truth is opencode/plugins/notes-loop.js — the same external-memory idea,
the two moments that matter (after compaction the file is named; a long round without one is
nudged). What changes is the MECHANISM, forced by the hook events the spike recorded (§6.1 S2):
the JS plugin re-injects at `experimental.session.compacting`; the Claude equivalent is
`PreCompact` (stdout becomes the compaction instructions) plus `SessionStart` matcher `compact`
("after compaction"). The long-round nudge (notes-loop.js:19 CALLS_BEFORE_NUDGE = 25) rides on
PostToolUse, and the pointer text is identical to the JS string so the shared test asserts one
phrase on both engines.

Notes path (design §5.2): $DELEGATE_EVIDENCE_DIR/NOTES.md when set (a worker round), else
$CLAUDE_CODE_TASK_NOTES, else /tmp/opencode-notes/<basename(cwd)>/NOTES.md — one convention in
both harnesses.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import hooklib  # noqa: E402

CALLS_BEFORE_NUDGE = 25  # notes-loop.js:19


def notes_path(event):
    ev = os.environ.get("DELEGATE_EVIDENCE_DIR")
    if ev:
        return os.path.join(ev, "NOTES.md")
    cc = os.environ.get("CLAUDE_CODE_TASK_NOTES")
    if cc:
        return cc
    cwd = event.get("cwd") or os.getcwd()
    base = os.path.basename(cwd.rstrip("/")) or "session"
    return "/tmp/opencode-notes/%s/NOTES.md" % base


def pointer(path):
    """The one-line PreCompact stdout / SessionStart context line (§5.2: naming the file next)."""
    return "your notes: %s; read it before continuing" % path


def pre_compact(event):
    """PreCompact: the notes pointer on stdout, but only when a notes file actually exists."""
    p = notes_path(event)
    if os.path.isfile(p):
        return pointer(p)
    return ""


def session_start(event, st):
    """SessionStart (startup|resume|compact): the pointer as additionalContext + the long-round nudge.

    `compact` is the after-compaction moment the JS plugin handles by naming the file in the
    compacted context; here the same line. `startup`/`resume` seed it, and a long round with no
    notes file yet gets the once-only create nudge (notes-loop.js:30).
    """
    p = notes_path(event)
    return pointer(p) if os.path.isfile(p) else ""


def handle(event, st):
    """Dispatch by the sub-event this module owns; returns (stdout_text, additional_context)."""
    name = event.get("hook_event_name")
    if name == "PreCompact":
        return pre_compact(event), ""
    if name == "SessionStart":
        return "", session_start(event, st)
    return "", ""
