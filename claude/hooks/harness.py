#!/usr/bin/env python3
"""harness.py — the single Claude Code command-hook entry point (O1b step 4, design §5.2/§6.3).

The install settings name ONE command (`python3 <install>/claude/hooks/harness.py`) for every
event; this reads the event JSON on stdin and dispatches by `hook_event_name` (plus `tool_name`
for the PostToolUse matcher split) to the four behaviour modules, writing exactly one hook output
on stdout or nothing (exit 0 = no decision — the hooks reference's shapes).

Crash-safety first: ANY internal error is exit 0, silent. A broken reminder must never block a
session. The permission guard shares that discipline in the direction that matters: it can only
ever ADD an allow for an explicit policy exception, and any failure is silent (no decision), so
the human/classifier answers — see permission-guard.py's fail-to-human contract. FIDELITY: this
file is the dispatch/state shell; the budgets, text and §3 hard limits are each in their own
module, which cites its JS twin or the judge doc.

Claude Code is exempt from the editor/payload gate by owner ruling (design §5.2/§9): no
opencode/plugins/chunk-cap.js twin is wired here, and this file must not gate on argument
length — tests/test_claude_hooks.sh asserts that abstention, so do not add such a check.
"""
import importlib.util
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)


def _mod(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_HERE, filename))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def _emit(payload):
    if payload is not None:
        if isinstance(payload, str):
            sys.stdout.write(payload if payload.endswith("\n") else payload + "\n")
        else:
            sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")


def _post_tool_output(text):
    if not text:
        return None
    return {"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": text}}


def _handle(event):
    """Return (stdout_payload_or_text, mutated_state_or_None). Pure of printing."""
    name = event.get("hook_event_name")

    if name == "PostToolUse":
        st = hooklib.load(event.get("session_id"))
        tid = event.get("tool_use_id")
        if tid and tid in st["done_ids"]:
            return None, None  # the `*` and `Edit|Write` matchers fired on one call: run once
        parts = []
        todo = _mod("delegate_todo_loop", "todo-loop.py")
        r = todo.handle(event, st)
        if r:
            parts.append(r)
        tool = event.get("tool_name") or ""
        if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch"):
            verify = _mod("delegate_verify_loop", "verify-loop.py")
            v = verify.handle(event, st)
            if v:
                parts.append(v)
        if tid:
            st["done_ids"] = (st["done_ids"] + [tid])[-50:]
        return _post_tool_output("\n".join(parts)), st

    if name in ("PreCompact", "SessionStart"):
        notes = _mod("delegate_notes_loop", "notes-loop.py")
        st = hooklib.load(event.get("session_id"))
        text, ctx = notes.handle(event, st)
        if name == "PreCompact":
            return (text or None), None
        return _session_start_output(event, ctx), (st if ctx else None)

    if name == "PermissionRequest":
        guard = _mod("delegate_permission_guard", "permission-guard.py")
        return guard.decide(event), None

    return None, None  # unknown event: silent no-decision


def _session_start_output(event, ctx):
    if not ctx:
        return None
    return {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": ctx}}


def main():
    global hooklib
    hooklib = _mod("delegate_hooklib", "hooklib.py")
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            return 0
        event = json.loads(raw)
        if not isinstance(event, dict):
            return 0
        payload, st = _handle(event)
        if st is not None:
            hooklib.save(event.get("session_id"), st)
        _emit(payload)
    except Exception:  # noqa: BLE001 — a hook must never break the agent; silent exit 0
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
