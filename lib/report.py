#!/usr/bin/env python3
"""Turn one worker round (opencode `run --format json` events + git + verify) into the
compact report the orchestrator reads.

  report.py final-text EVENTS.jsonl          print the worker's closing message
  report.py report --id ... --out-md F ...   write report.md + report.json, print report.md

The report is deliberately small: the orchestrator's context is the scarce resource, so
it gets the worker's own closing block, the facts the harness measured itself (exit code,
tokens, tool errors, diffstat, verify result), and paths to everything else.
"""
import argparse
import json
import os
import re
import sys
from collections import Counter

FINAL_TEXT_MAX_LINES = 220
DIFFSTAT_MAX_LINES = 60
VERIFY_TAIL_LINES = 40


def read_events(path):
    events = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    events.append({"type": "_unparsed", "raw": line[:500]})
    except FileNotFoundError:
        pass
    return events


def final_text(events):
    """Text the worker produced after its last tool call — its closing message."""
    last_tool = -1
    for i, e in enumerate(events):
        if e.get("type") == "tool_use":
            last_tool = i
    chunks = [
        (e.get("part") or {}).get("text", "")
        for e in events[last_tool + 1:]
        if e.get("type") == "text"
    ]
    text = "\n".join(c for c in chunks if c).strip()
    if not text:  # fall back to the last text part anywhere
        for e in reversed(events):
            if e.get("type") == "text" and (e.get("part") or {}).get("text"):
                return e["part"]["text"].strip()
    return text


# Tool-call markup that only shows up in message text when the server failed to parse a call
# (Qwen3-coder / Hermes / generic chat-template formats).
LEAK_MARKERS = ("<tool_call>", "</tool_call>", "<function=", "</function>", "<parameter=",
                "<|tool_call", "<|im_start|>", "<tool_use>", "<invoke ")


def leaked_markup(text):
    return [m for m in LEAK_MARKERS if m in text]


def nudge_kind(events, exit_code):
    """What, if anything, the harness should send back into the session."""
    if exit_code in (124, 130):
        return "none"
    text = final_text(events)
    if leaked_markup(text):
        return "malformed"
    last = next((e for e in reversed(events) if e.get("type") not in ("step_start", "_unparsed")), None)
    if last and last.get("type") == "error":
        data = (last.get("error") or {}).get("data") or {}
        code = data.get("statusCode")
        if data.get("isRetryable") is False and code and 400 <= int(code) < 500:
            return "none"  # bad model id, bad key: retrying cannot help
        return "api-error"
    if not re.search(r"^\s*STATUS:\s*[a-z]+", text, re.M | re.I):
        return "no-status"
    return "none"


def summarize(events):
    tools = Counter()
    tool_errors = []
    errors = []
    steps = 0
    out_tokens = reasoning_tokens = 0
    last_ctx = 0
    todos = None
    finish_reasons = Counter()
    last_finish = None
    for e in events:
        t = e.get("type")
        p = e.get("part") or {}
        if t == "tool_use":
            name = p.get("tool", "?")
            tools[name] += 1
            st = p.get("state") or {}
            if st.get("status") == "error":
                msg = str(st.get("error") or st.get("output") or "")[:240].replace("\n", " ")
                tool_errors.append(f"{name}: {msg}")
            if name in ("todowrite", "todo"):
                todos = (st.get("input") or {}).get("todos") or todos
        elif t == "step_finish":
            steps += 1
            tk = p.get("tokens") or {}
            out_tokens += int(tk.get("output") or 0)
            reasoning_tokens += int(tk.get("reasoning") or 0)
            cache = tk.get("cache") or {}
            last_ctx = int(tk.get("input") or 0) + int(cache.get("read") or 0)
            finish_reasons[p.get("reason", "?")] += 1
            last_finish = p.get("reason")
        elif t == "error":
            err = e.get("error") or {}
            data = err.get("data") or {}
            errors.append(f"{err.get('name', 'error')}: {str(data.get('message', err))[:300]}")
        elif t == "_unparsed":
            errors.append("unparsed event line: " + e["raw"][:200])
    return {
        "tools": dict(tools.most_common()),
        "tool_calls": sum(tools.values()),
        "tool_errors": tool_errors,
        "errors": errors,
        "steps": steps,
        "output_tokens": out_tokens,
        "reasoning_tokens": reasoning_tokens,
        "final_context_tokens": last_ctx,
        "finish_reasons": dict(finish_reasons),
        "last_finish": last_finish,
        "todos": todos,
    }


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except (FileNotFoundError, TypeError):
        return ""


def clip(text, max_lines, where="tail"):
    lines = text.rstrip("\n").splitlines()
    if len(lines) <= max_lines:
        return "\n".join(lines)
    if where == "head":
        return "\n".join(lines[:max_lines] + [f"... ({len(lines) - max_lines} more lines)"])
    return "\n".join([f"... ({len(lines) - max_lines} earlier lines)"] + lines[-max_lines:])


def cmd_report(a):
    events = read_events(a.events)
    s = summarize(events)
    text = final_text(events)
    m = re.search(r"^\s*STATUS:\s*([a-z]+)", text, re.M | re.I)
    worker_status = m.group(1).lower() if m else None

    exit_code = int(a.exit)
    if a.aborted == "1":
        status = "aborted"
    elif exit_code == 124:
        status = "timeout"
    elif not events or (exit_code != 0 and not text):
        status = "worker-error"
    elif s["errors"] and not text:
        status = "worker-error"
    elif not text and s["last_finish"] == "length":
        status = "truncated"  # hit the output-token limit mid-step and never finished
    elif worker_status in ("done", "partial", "blocked"):
        status = worker_status
    else:
        status = "no-status"  # finished without the §13 block: treat as partial

    verify_rc = None if a.verify_rc in ("", None) else int(a.verify_rc)
    if status == "done" and verify_rc not in (None, 0):
        status = "done-but-verify-failed"

    stderr_tail = clip(read_text(a.stderr), 15)
    diffstat = read_text(a.diffstat).rstrip()
    verify_log = read_text(a.verify_log)

    mins, secs = divmod(int(a.duration), 60)
    L = []
    L.append(f"# delegate report — {a.id} — round {a.round}")
    L.append("")
    L.append(f"STATUS (harness): **{status}**   worker said: {worker_status or '—'}   "
             f"exit: {exit_code}   time: {mins}m{secs:02d}s   model: {a.model}")
    L.append(f"steps: {s['steps']}   tool calls: {s['tool_calls']} "
             f"({', '.join(f'{k} {v}' for k, v in list(s['tools'].items())[:8]) or 'none'})   "
             f"output tokens: {s['output_tokens']}   final context: {s['final_context_tokens']}")
    L.append(f"branch: {a.branch}   worktree: {a.worktree}   base: {a.base}@{a.base_sha[:12]}   "
             f"head: {a.commit[:12]}")
    if a.access:
        L.append(f"access: {a.access}")
    refused = os.path.join(a.evidence, "guard-refused.log") if a.evidence else ""
    if refused and os.path.exists(refused):
        rl = [l.rstrip() for l in open(refused, encoding="utf-8", errors="replace") if l.strip()]
        if rl:
            L.append(f"GUARD: the worker ran {len(rl)} guarded command(s), refused by the harness: "
                     + " | ".join(rl[-3:]))
    if s["errors"]:
        L.append("")
        L.append("## Run errors")
        L.extend(f"- {e}" for e in s["errors"][:10])
    if s["tool_errors"]:
        L.append("")
        L.append(f"## Failed tool calls ({len(s['tool_errors'])})")
        L.extend(f"- {e}" for e in s["tool_errors"][:10])
        if len(s["tool_errors"]) > 10:
            L.append(f"- ... {len(s['tool_errors']) - 10} more")
    if s["todos"]:
        open_items = [t for t in s["todos"] if t.get("status") != "completed"]
        if open_items:
            L.append("")
            L.append("## Worker's todo list: items not completed")
            L.extend(f"- [{t.get('status')}] {t.get('content')}" for t in open_items[:15])
    L.append("")
    L.append("## Worker's closing message")
    L.append("")
    L.append(clip(text, FINAL_TEXT_MAX_LINES, "head") if text else "_(none — the worker produced no final text)_")
    L.append("")
    L.append("## Diff since base (harness)")
    L.append("")
    L.append("```")
    L.append(clip(diffstat, DIFFSTAT_MAX_LINES, "tail") if diffstat else "(no changes)")
    L.append("```")
    if a.verify_cmd:
        L.append("")
        L.append(f"## Verify (harness): `{a.verify_cmd}` -> exit {verify_rc}")
        L.append("")
        L.append("```")
        L.append(clip(verify_log, VERIFY_TAIL_LINES, "tail"))
        L.append("```")
    if "SECURITY:" in read_text(a.stderr):
        L.insert(4, "**SECURITY: the worker modified the worktree's .git pointer (restored). Review this round's diff with suspicion.**")
    nudges = re.findall(r"^nudge: (\S+)", read_text(a.stderr), re.M)
    if nudges:
        c = Counter(nudges)
        L.insert(4, "NOTE: harness nudged the worker in-session: " +
                 ", ".join(f"{k} x{v}" for k, v in c.items()) +
                 " (malformed = tool call arrived as text; api-error = server error mid-turn;"
                 " no-status = ended without the closing block)")
    if s["finish_reasons"].get("length"):
        L.insert(4, f"WARNING: {s['finish_reasons']['length']} step(s) hit the output-token limit (finish_reason=length)")
    if status in ("worker-error", "timeout", "truncated") and stderr_tail:
        L.append("")
        L.append("## Worker stderr (tail)")
        L.append("```")
        L.append(stderr_tail)
        L.append("```")
    rd = os.path.dirname(a.out_md)
    L.append("")
    L.append(f"files: {rd}/{{prompt.md,events.jsonl,stderr.log,verify.log}}   evidence: {a.evidence}")
    L.append(f"next: `delegate diff {a.id} [--full | -- PATH]` · `delegate exec {a.id} -- CMD` · "
             f"`delegate continue {a.id} FEEDBACK.md`")
    md = "\n".join(L) + "\n"

    with open(a.out_md, "w", encoding="utf-8") as f:
        f.write(md)
    with open(a.out_json, "w", encoding="utf-8") as f:
        json.dump({**s, "id": a.id, "round": int(a.round), "status": status,
                   "worker_status": worker_status, "exit": exit_code,
                   "duration_s": int(a.duration), "verify_rc": verify_rc,
                   "commit": a.commit, "model": a.model,
                   "nudges": dict(Counter(re.findall(r"^nudge: (\S+)", read_text(a.stderr), re.M)))},
                  f, indent=2)
    sys.stdout.write(md)


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "final-text":
        print(final_text(read_events(sys.argv[2])))
        return
    if len(sys.argv) >= 4 and sys.argv[1] == "nudge-kind":
        print(nudge_kind(read_events(sys.argv[2]), int(sys.argv[3] or 0)))
        return
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["report"])
    for k in ("id", "round", "events", "stderr", "exit", "duration", "model", "worktree",
              "branch", "base", "base-sha", "commit", "diffstat", "evidence", "verify-cmd",
              "verify-rc", "verify-log", "out-md", "out-json", "aborted", "access"):
        ap.add_argument("--" + k, default="")
    cmd_report(ap.parse_args())


if __name__ == "__main__":
    main()
