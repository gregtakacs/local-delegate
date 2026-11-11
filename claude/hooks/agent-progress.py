#!/usr/bin/env python3
"""Claude Code hook: report background/sub-agent activity to the llama dashboard.

Installed (async) on PostToolUse, PostToolUseFailure and SubagentStop. For tool calls made
by a SUBAGENT (the hook input carries `agent_id`), it keeps a small per-agent tally and posts
it to stackd's POST /agents/progress, so the Claude agents that plan, spec and review
delegate work show up on the "Coding agents · live" card next to the worker rounds they
start. Main-session tool calls are ignored.

Never in the way: it is meant to run with `async: true`, posts with a short timeout, and
always exits 0. Configuration comes from the delegate config (~/.config/delegate/config.env):
DELEGATE_AGENT_HOOK_URL (default: DELEGATE_PROGRESS_URL, else the first DELEGATE_BASE_URLS
entry minus /v1) and DELEGATE_AGENT_HOOK_KEY_FILE (default: DELEGATE_PROGRESS_KEY_FILE,
else DELEGATE_API_KEY_FILE). DELEGATE_AGENT_HOOK=0 turns it off.
"""
import fcntl
import hashlib
import json
import os
import re
import shlex
import socket
import sys
import time
import urllib.request
from pathlib import Path

STATE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "claude-agent-progress"
RECENT = 30
MIN_INTERVAL = 3.0
DOC_MAX = 200_000


def load_config():
    cfg = {}
    p = Path(os.environ.get("DELEGATE_CONFIG") or
             Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "delegate" / "config.env")
    try:
        for line in p.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            v = v.split(" #")[0].strip().strip('"').strip("'")
            cfg[k.strip()] = os.path.expanduser(v)
    except OSError:
        pass
    cfg.update({k: v for k, v in os.environ.items() if k.startswith("DELEGATE_")})
    return cfg


def endpoints(cfg):
    if cfg.get("DELEGATE_AGENT_HOOK_URL"):
        return [cfg["DELEGATE_AGENT_HOOK_URL"].rstrip("/")]
    if cfg.get("DELEGATE_PROGRESS_URL"):
        return [cfg["DELEGATE_PROGRESS_URL"].rstrip("/")]
    urls = (cfg.get("DELEGATE_BASE_URLS") or cfg.get("DELEGATE_BASE_URL") or "").split()
    return [u.rstrip("/").removesuffix("/v1") for u in urls]


def summarize(tool, inp, cwd):
    inp = inp if isinstance(inp, dict) else {}

    def rel(p):
        p = str(p or "")
        return p[len(cwd) + 1:] if cwd and p.startswith(cwd.rstrip("/") + "/") else p
    if tool == "Bash":
        return " ".join(str(inp.get("command") or "").split())
    if tool in ("Read", "Write", "Edit", "NotebookEdit"):
        return rel(inp.get("file_path") or inp.get("notebook_path"))
    if tool in ("Grep", "Glob"):
        return str(inp.get("pattern") or "") + (f"  in {rel(inp.get('path'))}" if inp.get("path") else "")
    if tool == "TodoWrite":
        todos = inp.get("todos") or []
        return f"plan updated: {sum(1 for t in todos if t.get('status') == 'completed')}/{len(todos)} done"
    if tool in ("WebFetch", "WebSearch"):
        return str(inp.get("url") or inp.get("query") or "")
    if tool in ("Agent", "Task"):
        return str(inp.get("description") or "")
    return next((str(v) for v in inp.values() if isinstance(v, (str, int))), "")


def agent_meta(transcript_path, agent_id):
    # <project>/<session>.jsonl  ->  <project>/<session>/subagents/agent-<id>.meta.json
    try:
        t = Path(transcript_path)
        return json.loads((t.with_suffix("") / "subagents" / f"agent-{agent_id}.meta.json").read_text())
    except (OSError, ValueError, TypeError):
        return {}


def agent_prompt(transcript_path, agent_id):
    """The brief the agent was started with: the first user message of its own transcript
    (<project>/<session>/subagents/agent-<id>.jsonl)."""
    try:
        t = Path(transcript_path).with_suffix("") / "subagents" / f"agent-{agent_id}.jsonl"
        with open(t, encoding="utf-8", errors="replace") as f:
            for line in f:
                d = json.loads(line)
                if d.get("type") != "user":
                    continue
                c = (d.get("message") or {}).get("content")
                if isinstance(c, list):
                    c = "\n\n".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
                return str(c or "")[:DOC_MAX]
    except (OSError, ValueError, TypeError):
        pass
    return ""


def slugify(v):
    """bin/delegate's slugify: the task id is <repo dir>-<slug of --name>."""
    v = re.sub(r"[^a-z0-9._-]+", "-", str(v).lower()).strip("-")
    return v[:48]


def effective_cwd(prefix, cwd):
    """The directory a command is in by the time it reaches a point: the hook's cwd, moved by
    every `cd DIR` before that point (leads write `cd WORKTREE && delegate chain plan.json`)."""
    here = cwd or "."
    for m in re.finditer(r"(?:^|[\s;&|(])cd\s+(\"[^\"]*\"|'[^']*'|[^\s;&|)]+)", prefix):
        d = m.group(1).strip("\"'")
        d = os.path.expanduser(d)
        here = d if os.path.isabs(d) else os.path.normpath(os.path.join(here, d))
    return here


def delegate_children(cmd, cwd):
    """The delegate tasks a Bash command starts or continues, as dashboard keys: task ids
    ("task:<id>") and chains ("chain:<plan name>", each of whose steps reports the chain).
    Subagents get no agent id in their environment, so the lead is linked to its worker
    rounds from its own commands instead."""
    out = []
    for m in re.finditer(r"(?:^|[\s;&|(])delegate\s+(run|continue|chain)\s+([^;&|]*)", cmd):
        verb = m.group(1)
        cwd_here = effective_cwd(cmd[:m.start()], cwd)
        try:
            args = shlex.split(m.group(2))
        except ValueError:
            args = m.group(2).split()
        if verb == "continue":
            if args and not args[0].startswith("-"):
                out.append("task:" + args[0])
        elif verb == "run":
            opt = {args[i]: args[i + 1] for i in range(len(args) - 1) if args[i] in ("--name", "--repo")}
            if opt.get("--name"):
                repo = opt.get("--repo") or cwd_here or "."
                repo = os.path.expanduser(repo)
                if not os.path.isabs(repo):
                    repo = os.path.join(cwd_here or ".", repo)
                try:
                    import subprocess
                    top = subprocess.run(["git", "-C", repo, "rev-parse", "--show-toplevel"], capture_output=True,
                                         text=True, timeout=3).stdout.strip() or repo
                except Exception:  # noqa: BLE001
                    top = repo
                out.append(f"task:{Path(top).name}-{slugify(opt['--name'])}")
        elif verb == "chain" and args and not args[0].startswith("-"):
            plan = Path(os.path.expanduser(args[0]))
            if not plan.is_absolute():
                plan = Path(cwd_here or ".") / plan
            try:
                name = json.loads(plan.read_text()).get("name")
                if name:
                    out.append("chain:" + str(name)[:120])
            except (OSError, ValueError, AttributeError):
                pass
    return out


def agent_usage(transcript_path, agent_id):
    """The agent's own token use so far, summed from its transcript (each API message once)."""
    tot = {"input": 0, "cache_read": 0, "cache_write": 0, "output": 0}
    seen = set()
    try:
        t = Path(transcript_path).with_suffix("") / "subagents" / f"agent-{agent_id}.jsonl"
        with open(t, encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"usage"' not in line:
                    continue
                try:
                    msg = (json.loads(line).get("message") or {})
                except ValueError:
                    continue
                u, mid = msg.get("usage"), msg.get("id")
                if not isinstance(u, dict) or not mid or mid in seen:
                    continue
                seen.add(mid)
                tot["input"] += int(u.get("input_tokens") or 0)
                tot["cache_read"] += int(u.get("cache_read_input_tokens") or 0)
                tot["cache_write"] += int(u.get("cache_creation_input_tokens") or 0)
                tot["output"] += int(u.get("output_tokens") or 0)
    except (OSError, TypeError):
        return None
    return tot


def post(cfg, body):
    """Post one snapshot; the daemon's answer (dict) or None."""
    key_file = (cfg.get("DELEGATE_AGENT_HOOK_KEY_FILE") or cfg.get("DELEGATE_PROGRESS_KEY_FILE")
                or cfg.get("DELEGATE_API_KEY_FILE") or "")
    try:
        key = Path(key_file).read_text().strip()
    except OSError:
        return None
    raw = json.dumps(body).encode()
    cache = STATE_DIR / "endpoint"
    eps = endpoints(cfg)
    try:   # the endpoint that worked last time first (laptop: LAN at home, public away)
        good = cache.read_text().strip()
        if good in eps:
            eps = [good] + [e for e in eps if e != good]
    except OSError:
        pass
    for ep in eps:
        try:
            req = urllib.request.Request(ep + "/agents/progress", data=raw, method="POST", headers={
                "Authorization": "Bearer " + key, "content-type": "application/json"})
            resp = urllib.request.urlopen(req, timeout=4).read()
            try:
                cache.write_text(ep)
            except OSError:
                pass
            try:
                return json.loads(resp or b"{}")
            except ValueError:
                return {}
        except Exception:  # noqa: BLE001 — display-only
            continue
    return None


def main():
    try:
        d = json.load(sys.stdin)
    except ValueError:
        return
    agent = d.get("agent_id")
    event = d.get("hook_event_name") or ""
    if not agent:
        return                                   # main conversation: not reported
    cfg = load_config()
    if cfg.get("DELEGATE_AGENT_HOOK", "1") == "0":
        return
    if event == "SubagentStop" and not (d.get("agent_type") or "").strip():
        return                                   # internal agents (suggestions, /btw)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    sf = STATE_DIR / f"{agent}.json"
    now = time.time()
    with open(STATE_DIR / f"{agent}.lock", "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        try:
            st = json.loads(sf.read_text())
        except (OSError, ValueError):
            if event == "SubagentStop":
                return                           # never seen this agent work: nothing to finish
            meta = agent_meta(d.get("transcript_path"), agent)
            st = {"started_at": now, "tool_calls": 0, "tool_errors": 0, "recent": [], "todos": [],
                  "desc": meta.get("description") or d.get("agent_type") or "agent",
                  "model": meta.get("pickedEffortModel") or "",
                  "background": meta.get("requestShape") == "background",
                  "type": d.get("agent_type") or "", "last_post": 0.0, "phase": "working"}
        final = False
        if event in ("PostToolUse", "PostToolUseFailure"):
            tool = d.get("tool_name") or "?"
            ok = event == "PostToolUse"
            st["tool_calls"] += 1
            st["tool_errors"] += 0 if ok else 1
            txt = summarize(tool, d.get("tool_input"), d.get("cwd") or "")
            st["recent"] = (st["recent"] + [{"t": now, "kind": tool, "text": txt[:300], "ok": ok}])[-RECENT:]
            if tool == "TodoWrite":
                st["todos"] = [{"content": t.get("content"), "status": t.get("status")}
                               for t in ((d.get("tool_input") or {}).get("todos") or [])]
            if tool == "SubagentHandback":
                # The agent's real end: its report to whoever started it. It is posted as final
                # right here: the SubagentStop that follows can be processed FIRST (async hooks
                # race), and if the hand-back then waited for it, the board kept "waiting".
                st["handed_back"] = True
                final = True
                st["phase"] = "finished"
                full = str((d.get("tool_input") or {}).get("message") or "")
                msg = " ".join(full.split())
                if full.strip():
                    st["report"] = full[:DOC_MAX]
                if msg:
                    st["last_text"] = msg[-600:]
                    st["recent"][-1]["text"] = ("report: " + msg)[:300]
            else:
                st["handed_back"] = False          # working again after a hand-back: a new stretch
            if tool == "Bash" and "delegate " in txt:
                kids = delegate_children(str((d.get("tool_input") or {}).get("command") or ""), d.get("cwd") or "")
                st["children"] = list(dict.fromkeys((st.get("children") or []) + kids))[-200:]
            if tool == "Bash" and "delegate " in txt and any(f"delegate {v}" in txt for v in ("run", "continue", "chain")):
                st["phase"] = "delegating"
            elif tool == "Bash" and "delegate peek" in txt:
                st["phase"] = "checking a round"
            else:
                st["phase"] = "working"
            st["cwd"] = d.get("cwd") or st.get("cwd")
            if final:
                st["phase"] = "finished"
        elif event == "SubagentStop":
            # Background agents stop and are resumed many times (they end a turn waiting on a
            # delegate round and are woken when it finishes), so the state is kept: start time
            # and counts carry across every stop/resume. Deleting it here once made the next
            # stop post "took 0m00s" and reset a resumed agent's elapsed time.
            final = bool(st.get("handed_back"))
            st["phase"] = "finished" if final else "waiting"
            full = str(d.get("last_assistant_message") or "")
            last = " ".join(full.split())
            if full.strip() and not st.get("handed_back"):
                st["report"] = full[:DOC_MAX]     # its latest word so far; a hand-back replaces it
            if last:
                st["last_text"] = last[-600:]
                st["recent"] = (st["recent"] + [{"t": now, "kind": "says", "text": last[:300], "ok": None}])[-RECENT:]
        else:
            return
        due = final or event == "SubagentStop" or now - st.get("last_post", 0) >= MIN_INTERVAL
        if due:
            st["last_post"] = now
        sf.write_text(json.dumps(st))
    if not due:
        return
    body = {
        "task": f"{st['desc']} · {agent[:6]}", "kind": "claude", "round": None,
        "repo": st.get("cwd") or "", "branch": st.get("type") or "", "model": st.get("model") or "Claude",
        "host": socket.gethostname().split(".")[0], "phase": st["phase"], "started_at": st["started_at"],
        "steps": None, "tool_calls": st["tool_calls"], "tool_errors": st["tool_errors"],
        "todos": st["todos"], "recent": st["recent"], "last_text": st.get("last_text", ""),
        "final": final, "status": "finished" if final else None,   # waiting = live, no dismiss
        "children": st.get("children") or [],
    }
    u = agent_usage(d.get("transcript_path"), agent)
    if u:
        body["usage"] = u
    if not st.get("prompt_sent"):
        p = agent_prompt(d.get("transcript_path"), agent)
        if p:
            body["prompt"] = p
    rep_ = st.get("report") or ""
    rep_id = hashlib.sha1(rep_.encode()).hexdigest() if rep_ else ""
    if rep_ and st.get("report_sent") != rep_id:
        body["report"] = rep_
    ans = post(cfg, body)
    if ans is not None:
        with open(STATE_DIR / f"{agent}.lock", "w") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            try:
                cur = json.loads(sf.read_text())
            except (OSError, ValueError):
                cur = st
            lost = bool(ans.get("need_prompt"))        # the daemon restarted: send both again
            cur["prompt_sent"] = ("prompt" in body or bool(cur.get("prompt_sent"))) and not lost
            if lost:
                cur["report_sent"] = ""
            elif "report" in body:
                cur["report_sent"] = rep_id
            sf.write_text(json.dumps(cur))
    if final:
        prune_old_state(now)


def prune_old_state(now, days=3):
    """State outlives stops (see above); drop agents not heard from in a few days."""
    for f in STATE_DIR.glob("*.json"):
        try:
            if now - f.stat().st_mtime > days * 86400:
                f.unlink()
                (STATE_DIR / (f.stem + ".lock")).unlink(missing_ok=True)
        except OSError:
            pass


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001 — a hook must never break the agent
        pass
    sys.exit(0)
