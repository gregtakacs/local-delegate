#!/usr/bin/env python3
"""Live progress reporter: follows a worker round's events.jsonl and posts compact snapshots
to stackd's POST /agents/progress, so the round shows up on the llama dashboard while it runs.

  progress.py --events F --stderr F --url BASE --key-file K --task ID --round N
              --phase-file P --stop-file S --ppid PID [--repo R --branch B --model M --host H
              --worktree W --started TS]

Display-only and best-effort: any failure is logged to stderr and ignored. It never
touches the worker. It exits when the harness writes the stop file (posting one final
snapshot with the round's status) or when the harness process disappears; a killed
harness simply stops reporting, and stackd drops the session after two minutes.
"""
import argparse
import json
import os
import sys
import time
import urllib.request

INTERVAL = 3.0
HEARTBEAT = 20.0   # post even when nothing changed, so a long silent stretch (the model thinking,
                   # a slow verify) never looks like a dead harness to stackd (stale after 120 s)
RECENT = 30


def short_path(p, worktree):
    p = str(p or "")
    if worktree and p.startswith(worktree.rstrip("/") + "/"):
        return p[len(worktree.rstrip("/")) + 1:]
    return p


def norm_todos(todos):
    """A worker's todo list as dicts. Models sometimes send it as a JSON string or as plain
    strings; a malformed list must never crash the reporter or the chain that reads it."""
    if isinstance(todos, str):
        try:
            todos = json.loads(todos)
        except ValueError:
            return []
    if not isinstance(todos, list):
        return []
    return [t if isinstance(t, dict) else {"content": str(t), "status": ""} for t in todos]


def tool_line(part, worktree):
    tool = part.get("tool") or "?"
    st = part.get("state") or {}
    inp = st.get("input") or {}
    if tool == "bash":
        txt = inp.get("command") or inp.get("description") or ""
    elif tool in ("read", "edit", "write", "apply_patch", "list"):
        txt = short_path(inp.get("filePath") or inp.get("path") or "", worktree)
        if tool == "read" and inp.get("offset"):
            txt += f" @{inp.get('offset')}"
    elif tool in ("grep", "glob"):
        txt = (inp.get("pattern") or "") + (f"  in {short_path(inp.get('path'), worktree)}" if inp.get("path") else "")
    elif tool in ("todowrite", "todo"):
        todos = norm_todos(inp.get("todos"))
        done = sum(1 for t in todos if t.get("status") == "completed")
        txt = f"plan updated: {done}/{len(todos)} done"
    elif tool == "webfetch":
        txt = inp.get("url") or ""
    else:
        txt = next((str(v) for v in inp.values() if isinstance(v, (str, int))), "")
    txt = " ".join(str(txt).split())
    ok = None if st.get("status") not in ("completed", "error") else st.get("status") == "completed"
    if ok is False:
        err = " ".join(str(st.get("error") or st.get("output") or "").split())[:120]
        txt = f"{txt}  ✗ {err}" if err else txt
    return tool, txt[:300], ok


class State:
    def __init__(self, worktree):
        self.worktree = worktree
        self.steps = self.tool_calls = self.tool_errors = self.out_tokens = self.ctx = 0
        self.in_tokens = self.cached_tokens = 0     # the round's whole input: fresh and cache hits
        self.todos = []
        self.recent = []
        self.last_text = ""
        self.seen_tools = {}   # part id -> index in recent (tool parts update in place)

    def add(self, e):
        t = e.get("type")
        p = e.get("part") or {}
        ts = (e.get("timestamp") or time.time() * 1000) / 1000
        if t == "tool_use":
            kind, txt, ok = tool_line(p, self.worktree)
            pid = p.get("id")
            if pid in self.seen_tools:
                self.recent[self.seen_tools[pid]].update(text=txt, ok=ok)
            else:
                self.tool_calls += 1
                self.recent.append({"t": ts, "kind": kind, "text": txt, "ok": ok})
                self.seen_tools[pid] = len(self.recent) - 1
            if ok is False:
                self.tool_errors += 1
            if kind in ("todowrite", "todo"):
                todos = norm_todos(((p.get("state") or {}).get("input") or {}).get("todos"))
                if todos:
                    self.todos = [{"content": x.get("content"), "status": x.get("status")} for x in todos]
        elif t == "text":
            txt = " ".join(str(p.get("text") or "").split())
            if txt:
                self.last_text = txt[-600:]
                self.recent.append({"t": ts, "kind": "says", "text": txt[:300], "ok": None})
        elif t == "step_finish":
            self.steps += 1
            tk = p.get("tokens") or {}
            self.out_tokens += int(tk.get("output") or 0)
            self.in_tokens += int(tk.get("input") or 0)
            self.cached_tokens += int((tk.get("cache") or {}).get("read") or 0)
            self.ctx = int(tk.get("input") or 0) + int((tk.get("cache") or {}).get("read") or 0)
        elif t == "error":
            msg = " ".join(str(((e.get("error") or {}).get("data") or {}).get("message") or e.get("error")).split())
            self.recent.append({"t": ts, "kind": "error", "text": msg[:300], "ok": False})
        if len(self.recent) > RECENT * 3:          # keep the in-place index map valid
            drop = len(self.recent) - RECENT
            self.recent = self.recent[drop:]
            self.seen_tools = {k: v - drop for k, v in self.seen_tools.items() if v >= drop}


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def main():
    ap = argparse.ArgumentParser()
    for k in ("events", "stderr", "url", "key-file", "task", "phase-file", "stop-file", "repo",
              "branch", "model", "host", "worktree", "prompt-file", "report-file",
              "runner", "egress", "orb", "orb-flash", "service", "chain", "here", "raw", "grants", "allow"):
        ap.add_argument("--" + k, default="")
    ap.add_argument("--round", type=int, default=1)
    ap.add_argument("--ppid", type=int, default=0)
    ap.add_argument("--started", type=float, default=time.time())
    a = ap.parse_args()

    url = a.url.rstrip("/") + "/agents/progress"
    st = State(a.worktree)
    offset, buf = 0, b""
    nudges = {}
    last_post, last_body, last_sent = 0.0, None, 0.0
    warned = False
    send_prompt = True          # the round's prompt rides the first post, and again if asked

    def text_of(path, limit=200_000):
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                return f.read(limit)
        except OSError:
            return ""

    def post(final=False, status=None):
        nonlocal last_body, warned, last_sent, send_prompt
        phase = ""
        try:
            phase = open(a.phase_file).read().strip() if a.phase_file else ""
        except OSError:
            pass
        # A finished round's phase is its status: the phase file still holds the last stage
        # it reached ("verifying"), and a final record carrying it read as a round still
        # verifying wherever phase is shown (owner, 2026-11-09).
        if final:
            phase = status or "finished"
        body = {"task": a.task, "round": a.round, "repo": a.repo, "branch": a.branch,
                "model": a.model, "host": a.host, "phase": phase or "worker",
                "started_at": a.started, "steps": st.steps, "tool_calls": st.tool_calls,
                "tool_errors": st.tool_errors, "output_tokens": st.out_tokens,
                "context_tokens": st.ctx, "input_tokens": st.in_tokens, "cached_tokens": st.cached_tokens,
                # the agent that started this round (DELEGATE_PARENT, set for a Claude agent's
                # commands), so the dashboard can total a lead's worker rounds on its card
                "parent": os.environ.get("DELEGATE_PARENT", "")[:120],
                "todos": st.todos, "recent": st.recent[-RECENT:],
                "last_text": st.last_text, "nudges": {k: v for k, v in nudges.items() if v},
                "final": final, "status": status,
                # how the round runs, for the dashboard's mode chips
                "mode": {"runner": a.runner, "here": a.here == "1", "raw": a.raw == "1",
                         "egress": a.egress, "orb": a.orb, "orb_flash": a.orb_flash == "1",
                         "service": a.service, "chain": a.chain,
                         "grants": a.grants.split(), "allow": a.allow.split()}}
        raw = json.dumps(body).encode()
        if raw == last_body and not final and not send_prompt and time.time() - last_sent < HEARTBEAT:
            return
        light = raw
        # the full texts: the prompt once (or when the daemon says it lost it), the round's
        # report (what goes back to the orchestrator) with the final post
        extra = {}
        if send_prompt and a.prompt_file:
            extra["prompt"] = text_of(a.prompt_file)
        if final and a.report_file:
            extra["report"] = text_of(a.report_file)
        if extra:
            raw = json.dumps({**body, **{k: v for k, v in extra.items() if v}}).encode()
        try:
            key = open(a.key_file).read().strip()
            req = urllib.request.Request(url, data=raw, method="POST", headers={
                "Authorization": "Bearer " + key, "content-type": "application/json"})
            resp = urllib.request.urlopen(req, timeout=10).read()
            last_body, last_sent = light, time.time()
            try:
                send_prompt = bool(json.loads(resp or b"{}").get("need_prompt"))
            except ValueError:
                send_prompt = False      # an older daemon: it has no texts to lose
        except Exception as e:  # noqa: BLE001 — display-only; never matters to the round
            if not warned:
                print(f"progress: cannot report to {url}: {e}", file=sys.stderr)
                warned = True

    while True:
        try:
            with open(a.events, "rb") as f:
                f.seek(offset)
                chunk = f.read()
                offset += len(chunk)
            buf += chunk
            *lines, buf = buf.split(b"\n")
            for line in lines:
                try:
                    st.add(json.loads(line))
                except (json.JSONDecodeError, AttributeError):
                    pass
        except FileNotFoundError:
            pass
        try:   # the harness logs one "nudge: <kind>" line per in-session retry
            nudges.clear()
            for line in open(a.stderr):
                if line.startswith("nudge: "):
                    k = line.split()[1]
                    nudges[k] = nudges.get(k, 0) + 1
        except OSError:
            pass
        if a.stop_file and os.path.exists(a.stop_file):
            status = (open(a.stop_file).read().strip() or "finished")
            post(final=True, status=status)
            return
        if a.ppid and not alive(a.ppid):
            return
        if time.time() - last_post >= INTERVAL:
            post()
            last_post = time.time()
        time.sleep(0.5)


def gone(argv):
    """`delegate rm` ran: tell stackd the task is gone, so its card leaves the board. A finished
    round otherwise stays on the board while its task exists (or until it is dismissed)."""
    ap = argparse.ArgumentParser(prog="progress.py gone")
    for k in ("url", "key-file", "task"):
        ap.add_argument("--" + k, default="")
    a = ap.parse_args(argv)
    try:
        key = open(a.key_file).read().strip()
        req = urllib.request.Request(a.url.rstrip("/") + "/agents/progress", method="POST",
                                     data=json.dumps({"task": a.task, "removed": True}).encode(),
                                     headers={"Authorization": "Bearer " + key, "content-type": "application/json"})
        urllib.request.urlopen(req, timeout=5).read()
    except Exception as e:  # noqa: BLE001 — display-only
        print(f"progress: cannot report the removal: {e}", file=sys.stderr)


def peek(argv):
    """One compact text snapshot of a round, for an orchestrator asked "how's it going?".
    Same data as the dashboard card; a few hundred tokens, never the raw event log."""
    ap = argparse.ArgumentParser(prog="progress.py peek")
    for k in ("events", "stderr", "phase-file", "worktree", "task", "report"):
        ap.add_argument("--" + k, default="")
    ap.add_argument("--round", type=int, default=1)
    ap.add_argument("--started", type=float, default=0)
    ap.add_argument("--running", type=int, default=0)
    ap.add_argument("--lines", type=int, default=8)
    a = ap.parse_args(argv)

    st = State(a.worktree)
    try:
        with open(a.events, "rb") as f:
            for line in f:
                try:
                    st.add(json.loads(line))
                except (json.JSONDecodeError, AttributeError):
                    pass
    except FileNotFoundError:
        pass
    phase = ""
    try:
        phase = open(a.phase_file).read().strip()
    except OSError:
        pass
    nudges = {}
    try:
        for line in open(a.stderr):
            if line.startswith("nudge: "):
                k = line.split()[1]
                nudges[k] = nudges.get(k, 0) + 1
    except OSError:
        pass

    def dur(sec):
        sec = max(0, int(sec))
        h, m = divmod(sec // 60, 60)
        return f"{h}h{m:02d}m" if h else f"{sec // 60}m{sec % 60:02d}s"

    if a.running:
        state = phase or "running"
        elapsed = dur(time.time() - a.started) if a.started else "?"
    else:
        state = "finished"
        try:
            r = json.load(open(a.report))
            state = f"finished: {r.get('status')}"
            elapsed = dur(r.get("duration_s") or 0)
        except (OSError, ValueError):
            elapsed = "?"
    head = (f"{a.task} · round {a.round} · {state} · {elapsed} · {st.steps} steps · "
            f"{st.tool_calls} tool calls" + (f" ({st.tool_errors} failed)" if st.tool_errors else "")
            + f" · {st.out_tokens // 1000}k tokens out · context {st.ctx // 1000}k")
    if nudges:
        head += " · retries " + ", ".join(f"{k}×{v}" for k, v in nudges.items())
    print(head)
    if st.todos:
        mark = {"completed": "✓", "in_progress": "▸"}
        print("plan:")
        for t in st.todos:
            print(f"  {mark.get(t.get('status'), '○')} {str(t.get('content') or '')[:80]}")
    else:
        print("plan: (no todo list yet)")
    rec = st.recent[-a.lines:]
    if rec:
        print("recent:")
        for e in rec:
            t = time.strftime("%H:%M", time.localtime(e["t"])) if e.get("t") else "     "
            txt = (e.get("text") or "")
            txt = f'"{txt[:100]}"' if e.get("kind") == "says" else txt[:110]
            flag = "  ✗" if e.get("ok") is False and "✗" not in txt else ""
            print(f"  {t} {e.get('kind', ''):<9} {txt}{flag}")
    if not a.running:
        print("(no round running — the full result is in `delegate report`)")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "gone":
        gone(sys.argv[2:])
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "peek":
        peek(sys.argv[2:])
    else:
        main()
