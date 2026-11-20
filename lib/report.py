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


SCOPE_GATE_END = "\n# delegate chain: end of the scope gate\n"   # lib/chain.py SCOPE_GATE_END


def shown_verify(cmd):
    """A chain step's verify starts with its scope gate (about 25 lines of bash the plan never
    wrote); show it as "[scope gate]" so the report shows the step's own verify."""
    head, sep, rest = cmd.partition(SCOPE_GATE_END)
    return "[scope gate] " + rest if sep and head.startswith("# delegate chain:") else cmd


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


# The closing block every worker ends with (opencode/delegate-rules.md §13) is what a later
# reader has left once `delegate prune` removes the task record, so the ledger keeps it: the
# status the worker claimed, and the six sections that say what it could not verify, what it
# decided, what it skipped, what it suggests and what it is asking. FILES, VERIFIED and EVIDENCE
# name paths and command lines and are parsed past, never stored.
REPORT_SECTIONS = (("NOT VERIFIED", "not_verified"), ("DEVIATIONS", "deviations"),
                   ("DECISIONS", "decisions"), ("OMISSIONS", "omissions"),
                   ("SUGGESTIONS", "suggestions"), ("QUESTIONS", "questions"))
STATUS_LINE = re.compile(r"^\s*STATUS:\s*([a-z]+)", re.M | re.I)
# A heading is a line that is the section's own name and a colon: `DEVIATIONS:` or
# `NOT VERIFIED: nothing`. Any heading ends the section before it, tracked or not — that is what
# keeps a `VERIFIED:` list of command lines out of the stored block.
BLOCK_HEADING = re.compile(r"^[ \t]*([A-Z][A-Z _-]{0,30})[ \t]*:[ \t]*(.*)$")
BLOCK_ITEM = re.compile(r"^[ \t]*- (.*)$")
NONE_WORD = "none"


def _is_none_item(text):
    """§13 spells an empty section `none`; the word alone, in any case and with or without the
    punctuation a worker leaves on it, is no item."""
    return text.strip().strip(".*:;-— \t").lower() == NONE_WORD


def parse_worker_report(text):
    """The §13 block as the ledger stores it: `{"status": ..., "not_verified": [...], ...}`, the
    six lists in the design's order. None when the message carries no `STATUS:` line at all — a
    worker that ended without the block has nothing to report.

    The block starts at the first `STATUS:` line (the same line `cmd_report` reads for
    `worker_status`, so the two agree). One section's items are its `- ` lines, the bullet
    stripped; a heading with text on its own line (`DEVIATIONS: one clause`) is that one item,
    and a bare heading followed by plain lines takes those. An item reading `none` is no item.
    The row's own caps (20 items, 300 characters) are lib/ledger.py's, applied at write time.
    """
    if not text:
        return None
    m = STATUS_LINE.search(text)
    if not m:
        return None
    words = {key: [] for _heading, key in REPORT_SECTIONS}
    plain = {key: [] for _heading, key in REPORT_SECTIONS}
    current = None
    for line in text[m.start():].splitlines():
        head = BLOCK_HEADING.match(line)
        if head:
            name = head.group(1).strip()
            current = next((k for h, k in REPORT_SECTIONS if h == name), None)
            inline = head.group(2).strip()
            if current and inline and not _is_none_item(inline):
                words[current].append(inline)
            continue
        if current is None or not line.strip():
            continue
        item = BLOCK_ITEM.match(line)
        if item:
            words[current].append(item.group(1).strip())
        elif not line.lstrip().startswith(("```", "~~~")):
            plain[current].append(line.strip())
    out = {"status": m.group(1).lower() if m.group(1) else None}
    for _heading, key in REPORT_SECTIONS:
        out[key] = list(words[key] or plain[key])
    return out


def row_todos(todos):
    """The round's todo list as the ledger's `todos` field wants it: `{"text", "status"}` per
    item, the text from the item's `content`. None when the round never wrote a list; the caps
    (50 items, 200 characters) are lib/ledger.py's, applied at write time."""
    if not isinstance(todos, list):
        return None
    out = []
    for t in todos:
        if not isinstance(t, dict):
            continue
        text = t.get("text") if isinstance(t.get("text"), str) else t.get("content")
        status = t.get("status")
        out.append({"text": "" if text is None else str(text),
                    "status": "" if status is None else str(status)})
    return out


def steps_ctxs(events_path):
    """Per-step context size (input + cache.read + cache.write tokens), in stream order.

    Reads step_finish parts straight from the event file; a missing or unreadable file
    is the empty list."""
    ctxs = []
    for ev in read_events(events_path):
        if ev.get("type") != "step_finish":
            continue
        p = ev.get("part")
        if not isinstance(p, dict):
            continue
        t = p.get("tokens")
        if not isinstance(t, dict):
            t = {}
        c = t.get("cache")
        if not isinstance(c, dict):
            c = {}

        def num(x):
            return x if isinstance(x, (int, float)) and not isinstance(x, bool) else 0

        ctxs.append(int(num(t.get("input"))) + int(num(c.get("read"))) + int(num(c.get("write"))))
    return ctxs


def position(events_path):
    """The round's live position as the nudge line records it: (steps so far, context size of
    the last step). An event file with no steps is (0, 0)."""
    ctxs = steps_ctxs(events_path)
    return (len(ctxs), ctxs[-1] if ctxs else 0)


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
    # A flaked verify (see --verify-retries in bin/delegate): the caller normalized rc to 0 and
    # hands us the record of the failed runs. The round is done; the flake goes beside it.
    flaky = None
    if getattr(a, "verify_flaky", ""):
        try:
            flaky = json.loads(a.verify_flaky)
        except ValueError:
            flaky = None
    if status == "done" and verify_rc not in (None, 0) and not flaky:
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
        L.append(f"## Verify (harness): `{shown_verify(a.verify_cmd)}` -> exit {verify_rc}")
        L.append("")
        L.append("```")
        L.append(clip(verify_log, VERIFY_TAIL_LINES, "tail"))
        L.append("```")
        if flaky:
            L.append("")
            L.append(f"VERIFY FLAKE: run 1 failed (exit {flaky.get('first_rc')}), "
                     f"run {int(flaky.get('failed_runs', 0)) + 1} passed — logged to flakes.jsonl")
    if "SECURITY:" in read_text(a.stderr):
        L.insert(4, "**SECURITY: the worker modified the worktree's .git pointer (restored). Review this round's diff with suspicion.**")
    nudges = re.findall(r"^nudge: (\S+)(?:\s|$)", read_text(a.stderr), re.M)
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
                   **({"verify_flaky": flaky} if flaky else {}),
                   "commit": a.commit, "model": a.model,
                   # what the round row's `todos` and `worker_report` are built from, kept here so
                   # `delegate ledger import` rebuilds the same two fields from a stored round
                   "todo_items": row_todos(s["todos"]),
                   "worker_report": parse_worker_report(text),
                   "nudges": dict(Counter(re.findall(r"^nudge: (\S+)", read_text(a.stderr), re.M)))},
                  f, indent=2)
    sys.stdout.write(md)


# What a worker writes when it met planted instructions or a prompt injection. Matched on its
# final message and its report's free text only, never on the prompt (the spec may discuss
# injection as a topic).
FLAG_RE = re.compile(
    r"\bplanted\b|prompt[ -]?injection|injected instruction|"
    r"\bignor(?:e|ed|ing) (?:the |these |those |its |any )?(?:planted |embedded |injected )?instructions\b|"
    r"instructions? (?:in|inside|from) (?:a|the|an) (?:file|comment|page|output|tool result)|"
    r"told (?:me|it|the worker) to (?:commit|push|copy|send|exfiltrat|curl|upload)|exfiltrat",
    re.I)


def flagged(events_path, report_json=""):
    text = final_text(read_events(events_path))
    if report_json and os.path.exists(report_json):
        try:
            with open(report_json, encoding="utf-8") as f:
                d = json.load(f)
            text += "\n" + " ".join(str(t.get("content", "")) for t in d.get("todos") or [] if isinstance(t, dict))
        except (OSError, ValueError):
            pass
    return bool(FLAG_RE.search(text or ""))


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "flagged":
        sys.exit(0 if flagged(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "") else 1)
    if len(sys.argv) >= 3 and sys.argv[1] == "final-text":
        print(final_text(read_events(sys.argv[2])))
        return
    if len(sys.argv) >= 4 and sys.argv[1] == "nudge-kind":
        print(nudge_kind(read_events(sys.argv[2]), int(sys.argv[3] or 0)))
        return
    if len(sys.argv) >= 3 and sys.argv[1] == "position":
        print(*position(sys.argv[2]))
        return
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["report"])
    for k in ("id", "round", "events", "stderr", "exit", "duration", "model", "worktree",
              "branch", "base", "base-sha", "commit", "diffstat", "evidence", "verify-cmd",
              "verify-rc", "verify-log", "verify-flaky", "out-md", "out-json", "aborted", "access"):
        ap.add_argument("--" + k, default="")
    cmd_report(ap.parse_args())


if __name__ == "__main__":
    main()
