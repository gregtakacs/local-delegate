#!/usr/bin/env python3
"""hooklib.py — shared state for the Claude Code reminder hooks (O1b step 4).

FIDELITY: the budgets and nudge TEXT live in the behaviour modules, each citing its JS twin
(opencode/plugins/{todo,verify,notes}-loop.js). This file only ports the ONE thing the JS
plugins had that a command hook cannot: in-process, per-session state. A JS plugin keeps a
`Map` alive for the life of the server; a Claude command hook is a fresh process per call, so
the same counters are backed by a small JSON file per session under
/tmp/delegate-claude-hooks/<session_id>.json. Same budgets, same windows, same once-per-file
rules — only the storage medium differs (design §5.2: "the JS in-memory state does not port").

A state file older than STATE_TTL is treated as a new session (a stale counter from a session
the user closed must not suppress today's first nudge). Writes are tmp + os.replace so two
hook processes for the same session never interleave a half-written file.
"""
import json
import os
import tempfile
import time

STATE_DIR = os.environ.get("DELEGATE_CLAUDE_HOOK_STATE") or "/tmp/delegate-claude-hooks"
STATE_TTL = 24 * 3600  # seconds; older than a day -> new session

DEFAULT = {
    "calls": 0,          # tool calls since the last todowrite (todo-loop)
    "nudges": 0,         # todo nudges sent this window (todo-loop MAX_NUDGES)
    "ever_listed": False,  # has this session written a todo list yet
    "edit_nudged": False,  # the first-file-change-without-a-list reminder already fired
    "ui_reminded": [],   # UI files the verify reminder already fired for (once per file)
    "ui_pending": [],    # UI files edited, not yet visually verified (compaction re-injection)
    "done_ids": [],      # tool_use_ids already processed (idempotency across matchers)
    "updated": 0.0,
}


def state_path(session_id):
    """Per-session file; the id is sanitised so it can never escape STATE_DIR."""
    safe = "".join(c if c.isalnum() or c in "._-" else "_" for c in str(session_id or "default"))
    return os.path.join(STATE_DIR, (safe or "default") + ".json")


def load(session_id):
    st = dict(DEFAULT)
    st["ui_reminded"] = []
    st["ui_pending"] = []
    st["done_ids"] = []
    p = state_path(session_id)
    try:
        age = time.time() - os.path.getmtime(p)
        if age > STATE_TTL:
            return st  # stale file from a closed session: start fresh
        with open(p) as f:
            disk = json.load(f)
        if isinstance(disk, dict):
            for k in DEFAULT:
                if k in disk:
                    st[k] = disk[k]
            for k in ("ui_reminded", "ui_pending", "done_ids"):
                if not isinstance(st[k], list):
                    st[k] = []
    except (OSError, ValueError):
        pass
    return st


def save(session_id, st):
    st["updated"] = time.time()
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    p = state_path(session_id)
    fd, tmp = tempfile.mkstemp(dir=STATE_DIR, prefix=".st.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(st, f)
        os.replace(tmp, p)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    return st
