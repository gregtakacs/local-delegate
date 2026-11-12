#!/usr/bin/env python3
"""One definition of a delegate task's state, computed read-only from its state dir.

  taskstate.py status   ID            the state as one word (running, verifying, interrupted, done, ...)
  taskstate.py statuses              id / rounds / state / worktree, one tab-separated line per task
  taskstate.py json     ID           the whole state dict (scripts, tests)
  taskstate.py leads                 the Claude leads' live rows, tab-separated (used by top)
  taskstate.py top      [ID] [--once] [--interval S] [--all] [--state D] [--cache D] [--color]
                                   the live view, as `delegate top` shows it

`state()` never takes a lock and never writes: it is what `delegate top`, `delegate list` and
`delegate chain` all read so they cannot disagree about whether a round is running, verifying,
interrupted (its harness died before writing a report), or finished with some status.

A running (or interrupted) round's numbers come from its events.jsonl, parsed with the same
`progress.State` the live dashboard reporter uses; a finished round's from its report.json,
which the harness wrote from that same parse.
"""
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from unicodedata import combining, east_asian_width

LIB = Path(os.path.realpath(__file__)).parent
sys.path.insert(0, str(LIB))
import progress                                                # noqa: E402  (event parsing, shared)

DAY = 86400
FULL_PARSE_MAX = 8 * 1024 * 1024                              # bigger rounds: report + tail only
TAIL_BYTES = 256 * 1024
ACTIONS = 15                                                  # `top ID`: last actions shown
RES = "\033[0m"
CODE = {"running": "\033[32m", "verifying": "\033[36m", "interrupted": "\033[31m", "aborted": "\033[31m",
        "worker-error": "\033[31m", "timeout": "\033[31m", "truncated": "\033[31m", "no-status": "\033[33m",
        "partial": "\033[33m", "blocked": "\033[33m", "done-but-verify-failed": "\033[33m",
        "accepted": "\033[32m",
        "done": "\033[2m", "new": "\033[2m", "stale?": "\033[33m", "finished": "\033[2m"}


def default_state_dir():
    return Path(os.environ.get("DELEGATE_STATE") or
                Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "delegate")


def agent_state_dir():
    """Where the Claude Code hook (claude/hooks/agent-progress.py) keeps one file per lead."""
    return Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "claude-agent-progress"


def _mtime(p):
    try:
        return os.path.getmtime(str(p))
    except OSError:
        return 0.0


def _size(p):
    try:
        return os.path.getsize(str(p))
    except OSError:
        return 0


def _num(v, d=0):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return d


def meta_env(task_dir):
    """meta.env is bash's `printf %q` output; unquote enough of it to read the fields top shows."""
    out = {}
    try:
        lines = (Path(task_dir) / "meta.env").read_text(errors="replace").splitlines()
    except OSError:
        return out
    for line in lines:
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        if not k or not k.replace("_", "A").isalnum():
            continue
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        elif v.startswith("$'"):
            try:
                import ast
                v = ast.literal_eval(v[1:])
            except (ValueError, SyntaxError):
                pass
        elif "\\" in v:
            v = v.replace("\\ ", " ")
        out[k] = v
    return out


def round_dirs(task_dir):
    d = Path(task_dir) / "rounds"
    try:
        return sorted(int(p.name) for p in d.iterdir() if p.name.isdigit() and p.is_dir())
    except OSError:
        return []


def read_json(path):
    try:
        return json.loads(Path(path).read_text(errors="replace"))
    except (OSError, ValueError):
        return None


def parse_events(path, worktree="", tail=0):
    """Feed a round's events.jsonl into progress.State; with `tail`, only its last bytes."""
    st = progress.State(worktree)
    size = _size(path)
    if not size:
        return st
    with open(str(path), "rb") as f:
        if tail and size > tail:
            f.seek(size - tail)
            data = f.read()
            _, _, data = data.partition(b"\n")          # the first line may be cut in half
        else:
            data = f.read()
    for line in data.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if isinstance(obj, dict):
            st.add(obj)
    return st


def current_todo(todos):
    """The item the worker is on now: the in-progress one, else the next pending."""
    todos = [t for t in (todos or []) if isinstance(t, dict)]
    for t in todos:
        if str(t.get("status") or "").replace("-", "_").lower() in ("in_progress", "started", "active"):
            return str(t.get("content") or "")
    for t in todos:
        if str(t.get("status") or "").replace("-", "_").lower() in ("pending", "not_started", "todo", ""):
            return str(t.get("content") or "")
    return ""


def last_action(st):
    """One line, <=100 chars, what the round did last."""
    e = (st.recent or [None])[-1]
    if not e:
        return " ".join(str(st.last_text or "").split())[:100]
    txt = " ".join(str(e.get("text") or "").split())
    kind = str(e.get("kind") or "")
    line = txt if (not txt or txt.startswith(kind)) else f"{kind} {txt}"
    if e.get("ok") is False and "✗" not in line:
        line = (line + " ✗").strip()
    return line[:100]


_CHAIN_CACHE = {}


def chain_index(state_dir):
    """Where each task belongs, from $DELEGATE_STATE/chains/*.json and the plans they point at:
    {"exact": {task id: (chain, plan)}, "suffix": {"-<step name>": (chain, plan)}}.

    The plans are what name the steps and the repo, so this places tasks whose meta.env has no
    CHAIN (started before it was recorded): their ids are chain.py's task_id(repo, step) -- the
    same rule, imported rather than copied -- plus the 48-character form `delegate run` actually
    cuts them to. A chain state file that records no plan (older chains recorded none) still
    places its steps, by the step names it does hold. Cached per state dir, keyed on the files' mtimes.
    """
    empty = {"exact": {}, "suffix": {}}
    try:
        files = sorted((Path(state_dir) / "chains").glob("*.json"))
    except OSError:
        return empty
    if not files:
        _CHAIN_CACHE.pop(str(state_dir), None)
        return empty
    sig = tuple((f.name, _mtime(f)) for f in files)
    hit = _CHAIN_CACHE.get(str(state_dir))
    if hit and hit[0] == sig:
        return hit[1]
    out = {"exact": {}, "suffix": {}}
    chain_lib = None
    try:
        if str(LIB) not in sys.path:
            sys.path.insert(0, str(LIB))
        import chain as chain_lib                                    # noqa: F811 (the one task_id rule)
    except Exception:                                                # noqa: BLE001 (no plan map then)
        chain_lib = None
    for f in files:
        st = read_json(f) or {}
        name, plan_path = str(st.get("name") or f.stem), str(st.get("plan") or "")
        names = [str(k) for k in (st.get("steps") or {})]
        plan = read_json(plan_path) if plan_path else None
        if isinstance(plan, dict) and isinstance(plan.get("steps"), list) and plan.get("repo"):
            repo = str(plan["repo"])
            for s in plan["steps"]:
                if isinstance(s, dict) and s.get("name"):
                    names.append(str(s["name"]))
        for n in names:
            out["suffix"].setdefault("-" + n[:48], (name, plan_path))
            if chain_lib and isinstance(plan, dict) and plan.get("repo"):
                tid = chain_lib.task_id(str(plan["repo"]), {"name": n})
                out["exact"][tid] = (name, plan_path)
                cut = f"{Path(str(plan['repo'])).name}-{n[:48]}"     # what cmd_run's slugify leaves
                out["exact"][cut] = (name, plan_path)
    _CHAIN_CACHE[str(state_dir)] = (sig, out)
    return out


def chain_of(tid, state_dir, meta):
    """The chain a task belongs to, and the plan that re-runs it: its meta.env first, then the
    chain state files and the plans they point at (see chain_index)."""
    idx = chain_index(state_dir)
    if meta.get("CHAIN"):
        name = meta["CHAIN"]
        plan = idx["exact"].get(tid, ("", ""))[1] if idx["exact"].get(tid, ("", ""))[0] == name else ""
        if not plan:
            plan = str((read_json(Path(state_dir) / "chains" / f"{name}.json") or {}).get("plan") or "")
        return name, plan
    if tid in idx["exact"]:
        return idx["exact"][tid]
    for key, val in idx["suffix"].items():
        if tid.endswith(key):
            return val
    return "", ""


def mode_label(meta):
    """How this task runs, as a short label: runner/egress, here, raw, its grants."""
    parts = [p for p in (meta.get("RUNNER") or "", meta.get("EGRESS") or "",
                         "here" if meta.get("HERE") == "1" else "",
                         "raw" if meta.get("RAW") == "1" else "",
                         meta.get("SERVICE") or "") if p]
    s = "/".join(parts) or "-"
    g = (meta.get("GRANTS") or "").split()
    a = (meta.get("ALLOW") or "").split()
    if g:
        s += " +" + ",".join(g)
    if a:
        s += " !" + ",".join(a)
    return s


# ------------------------------------------------------------------------ the state ----
def state(task_dir, now=None, state_dir=None):
    """Everything top/list/chain show about one task, from its state dir alone. Pure read."""
    d = Path(task_dir)
    now = time.time() if now is None else now
    state_dir = Path(state_dir) if state_dir else default_state_dir()
    meta = meta_env(d)
    tid = meta.get("ID") or d.name
    rs = round_dirs(d)
    n = rs[-1] if rs else 0
    rd = d / "rounds" / str(n)
    rj = rd / "report.json"
    ev, vl, ph = rd / "events.jsonl", rd / "verify.log", rd / ".phase"
    rep = read_json(rj) if n else None
    locked = (d / "lock").is_dir()

    status, sub = "new", ""
    if n:
        if rep is None:
            if locked:
                status = "running"
                if _size(vl) and _mtime(vl) > _mtime(ev):
                    sub = "verifying"                   # the worker finished; the harness is running verify
            else:
                status = "interrupted"                  # its harness died before writing the report
        else:
            status = str(rep.get("status") or "no-status")
            # A lock over a round that already reported: `delegate verify`/`exec`, or the next round
            # just started. Something is running on this task, so don't show it as finished.
            if locked and _mtime(d / "lock") > _mtime(rj):
                sub = "verifying"

    # `delegate accept`: the delegator overrode a failed outcome (after reproducing and
    # reproducing-away, e.g. a stale-image verify failure), or landed the work. The round's own
    # report keeps the failure — evidence stays as written; the task shows accepted instead.
    # The overlay stops the moment the state it accepted has moved on (a newer round, a retry).
    if not locked:
        acc = read_json(d / "accept.json")
        if acc and acc.get("round") == n and acc.get("status_before") == status:
            status, sub = "accepted", ""

    worktree = meta.get("WORKTREE") or ""
    live = rep is None and n > 0                        # no report yet: the events are the truth
    big = _size(ev) > FULL_PARSE_MAX
    st = parse_events(ev, worktree, tail=(TAIL_BYTES if (not live or big) else 0))
    if live and not big:
        steps, tools, failed = st.steps, st.tool_calls, st.tool_errors
        out_t, in_t = st.out_tokens, st.in_tokens + st.cached_tokens
        todos = st.todos
    elif rep:
        steps, tools = _num(rep.get("steps")), _num(rep.get("tool_calls"))
        te = rep.get("tool_errors")
        failed = len(te) if isinstance(te, list) else _num(te)
        out_t, in_t = _num(rep.get("output_tokens")), _num(rep.get("final_context_tokens"))
        todos = rep.get("todos") or st.todos
    else:
        steps, tools, failed, out_t, in_t, todos = 0, 0, 0, 0, 0, []

    start = _mtime(rd / "prompt.md") or _mtime(rd)
    if status == "new":
        elapsed = 0.0
    elif status == "running":
        elapsed = max(0.0, now - (start or now))
    elif status == "interrupted":
        elapsed = max(0.0, (_mtime(ev) or _mtime(vl) or _mtime(rd)) - (start or now))
    elif sub == "verifying":
        elapsed = max(0.0, now - max(_mtime(d / "lock"), _mtime(rj)))
    else:
        elapsed = float(_num((rep or {}).get("duration_s")))

    chain, chain_plan = chain_of(tid, state_dir, meta)
    # when this task last did anything, by its round's files (meta.env is written at creation, so it
    # says nothing about a round); `top` hides a finished task by this age.
    act = max(_mtime(rj), _mtime(ev), _mtime(vl), _mtime(d / "lock") if locked else 0.0)
    return {
        "id": tid, "dir": str(d), "round": n, "status": status, "substate": sub, "state": sub or status,
        "running": status == "running", "interrupted": status == "interrupted",
        "worktree": worktree, "branch": meta.get("BRANCH") or "", "repo": meta.get("REPO") or "",
        "model": meta.get("MODEL") or "", "verify": meta.get("VERIFY") or "",
        "elapsed": elapsed, "steps": steps, "tool_calls": tools, "tool_errors": failed,
        "output_tokens": out_t, "input_tokens": in_t,
        "todo": current_todo(todos), "last_action": last_action(st),
        "phase": (Path(ph).read_text().strip() if Path(ph).exists() else ""),
        "chain": chain, "chain_plan": chain_plan, "mode": mode_label(meta),
        "runner": meta.get("RUNNER") or "", "egress": meta.get("EGRESS") or "",
        "grants": (meta.get("GRANTS") or "").split(), "allow": (meta.get("ALLOW") or "").split(),
        "last_activity": act, "age": max(0.0, now - act),
        "resume": (f"delegate chain {chain_plan}" if status == "interrupted" and chain_plan
                   else f"delegate finish {tid}"),
    }


def all_states(state_dir=None, now=None):
    state_dir = Path(state_dir) if state_dir else default_state_dir()
    out = []
    try:
        dirs = sorted(p for p in state_dir.iterdir() if p.is_dir() and (p / "meta.env").exists())
    except OSError:
        return out
    for p in dirs:
        out.append(state(str(p), now=now, state_dir=state_dir))
    return out


# ---------------------------------------------------------------------- Claude leads ----
OUT_KEYS = ("output", "output_tokens", "out")
IN_KEYS = ("input", "input_tokens", "in")
CACHE_READ_KEYS = ("cache_read", "cache_read_input_tokens", "cache_read_tokens")
STALE_AFTER, HIDDEN_AFTER = 1800, 3600             # a quiet lead: shown stale, then hidden


def lead_usage(st):
    """The lead's own tokens, however its state file happens to spell them: the hook's own
    aggregation (input/cache_read/output), the raw API names, or flat at the top level. `in` is
    fresh plus cache reads, which is what the dashboard's "in" means for an agent."""
    for src in (st.get("usage") or {}, st.get("tokens") or {}, st):
        if not isinstance(src, dict):
            continue
        out = next((_num(src[k]) for k in OUT_KEYS if k in src), None)
        inp = next((_num(src[k]) for k in IN_KEYS if k in src), None)
        if out is None and inp is None:
            continue
        cache = next((_num(src[k]) for k in CACHE_READ_KEYS if k in src), 0)
        return _num(out), _num(inp) + _num(cache)
    return 0, 0


def leads(now=None, tasks=None, cache_dir=None):
    """The Claude agents in ~/.cache/claude-agent-progress, updated in the last 24 h: their phase,
    elapsed, their own tokens, the worker tokens of the tasks and chains their commands started
    (`children`), and whether to show them at all. A lead whose process died without saying so
    keeps its last phase; after 30 min of silence it is shown `stale?`, and a finished one is
    hidden after an hour."""
    now = time.time() if now is None else now
    tasks = all_states() if tasks is None else tasks
    by_id = {t["id"]: t for t in tasks}
    rows = []
    d = Path(cache_dir) if cache_dir else agent_state_dir()
    try:
        files = sorted(d.glob("*.json"))
    except OSError:
        return rows
    for f in files:
        st = read_json(f)
        if not isinstance(st, dict):
            continue
        updated = max(_mtime(f), _num(st.get("last_post")))
        quiet = now - updated
        if quiet > DAY:
            continue
        kids = [str(k) for k in (st.get("children") or [])]
        hit, direct = {}, []
        for k in kids:
            if k.startswith("task:"):
                t = by_id.get(k[5:])
                if t:
                    hit[t["id"]] = t
                    direct.append(t["id"])
            elif k.startswith("chain:"):
                for t in tasks:
                    if t["chain"] and t["chain"] == k[6:]:
                        hit[t["id"]] = t
        out, inp = lead_usage(st)
        phase = str(st.get("phase") or "")
        started = _num(st.get("started_at")) or now
        rows.append({"name": str(st.get("desc") or f.stem), "agent": f.stem,
                     "phase": phase, "quiet": quiet,
                     "stale": phase not in ("finished",) and quiet > STALE_AFTER,
                     "hidden": phase == "finished" and quiet > HIDDEN_AFTER,
                     "elapsed": max(0.0, now - started), "out": out, "inp": inp,
                     "worker_out": sum(t["output_tokens"] for t in hit.values()),
                     "tasks": len(hit), "kids": len(kids), "children": kids,
                     "task_ids": direct, "chain_names": sorted(set(
                         k[6:] for k in kids if k.startswith("chain:")))})
    return sorted(rows, key=lambda r: -r["quiet"])            # the one that posted most recently first


# ---------------------------------------------------------------------------- rendering ----
def colour_on(args):
    """ANSI unless NO_COLOR says otherwise; --color forces it on for a pipe (tests, scripts)."""
    if os.environ.get("NO_COLOR"):
        return False
    return bool(args.color) or sys.stdout.isatty()


def disp_w(s):
    """Columns a string takes on the terminal: CJK and fullwidth glyphs take two, marks take none.
    Clipping by len() would let a worker's 实现登录页面 overflow the frame."""
    return sum(0 if combining(c) else 2 if east_asian_width(c) in "WF" else 1 for c in s)


def _cw(s, w):
    """Clip to w columns (not w characters)."""
    out, n = "", 0
    for c in s:
        n += disp_w(c)
        if n > w:
            return out
        out += c
    return out


def _clip(s, w):
    s = " ".join(str(s or "").split())
    if w <= 0 or disp_w(s) <= w:
        return s
    return _cw(s, max(0, w - 1)) + "…"


def fmt_tokens(n):
    """Tokens, short. A lead's input is cache reads and runs into the millions, so it needs an M."""
    n = _num(n)
    if n < 1000:
        return str(n)
    if n < 100000:
        return f"{n / 1000:.1f}k"
    if n < 1000000:
        return f"{n / 1000:.0f}k"
    return f"{n / 1000000:.1f}M"


def fmt_elapsed(sec):
    sec = max(0, int(sec or 0))
    if not sec:
        return "-"
    h, m = divmod(sec // 60, 60)
    return f"{h}h{m:02d}m" if h else (f"{m}m{sec % 60:02d}s" if m else f"{sec}s")


def _cell(text, code, w, on):
    pad = " " * max(0, w - disp_w(text))
    return f"{code}{text}{RES}{pad}" if (on and code) else text + pad


SHORT = {"done-but-verify-failed": "verify-failed"}          # the state column is narrow


MID = ("round", 4), ("elapsed", 7), ("stats", 15), ("tokens", 7)


def _layout(width, indent, idw_cap=38):
    """The one column plan every row of the frame is built from, so a lead's header line and its
    steps' lines share column positions: (mid columns kept, id width, todo width, action width).
    Too narrow: the middle columns give way, largest first, then the id, then the todo, then the action.
    `idw_cap` is how wide the id column may get: the frame passes the widest id it is about to show,
    so short ids do not eat the columns a worker's current item would otherwise have."""
    cols = list(MID)
    while cols and indent + 14 + sum(w + 1 for _, w in cols) + 13 > width:
        cols.remove(max(cols, key=lambda c: c[1]))
    avail = max(0, width - indent - 14 - sum(w + 1 for _, w in cols))
    idw = max(12, min(idw_cap, avail - 1))
    tail = max(0, avail - idw - 1)
    todo_w = min(30, max(0, tail - 20))
    return cols, idw, todo_w, max(0, tail - todo_w - 1)


def idw_hint(tasks, lead_rows=()):
    """The id column, bucketed to a multiple of 8 columns so it does not jitter every refresh."""
    w = max([disp_w(t["id"]) for t in tasks] + [disp_w(r["name"]) for r in lead_rows] + [12])
    return min(38, max(12, (w + 7) // 8 * 8))


def row(t, width, on, indent="", cap=38):
    """One task: state, id, round, elapsed, steps/tools(failed), tokens out, current item, last action."""
    cols, idw, todo_w, act_w = _layout(width, len(indent), cap)
    txt = {"round": f"r{t['round']}" if t["round"] else "-", "elapsed": fmt_elapsed(t["elapsed"]),
           "stats": f"{t['steps']}st {t['tool_calls']}t({t['tool_errors']}f)",
           "tokens": fmt_tokens(t["output_tokens"])}
    stt = _clip(SHORT.get(t["state"], t["state"]), 13)
    line = indent + _cell(stt, CODE.get(t["state"], ""), 14, on) + _cell(_clip(t["id"], idw), "", idw + 1, on)
    for name, w in cols:
        line += _cell(_clip(txt[name], w), "", w + 1, on)
    if todo_w:
        line += _cell(_clip(t["todo"], todo_w), "", todo_w, on) + " "
    if act_w:
        line += _clip(t["last_action"], act_w)
    return line.rstrip()


def lead_row(r, width, on, indent="", cap=38):
    """A Claude lead as two lines: a header row in the task rows' own columns (its phase where a
    state goes, its description where a task id goes, its elapsed time in the elapsed column), and
    under it its tokens -- its own, and its workers'. The tokens get the line to themselves because
    on an 80-column terminal they would otherwise be clipped away, and a lead's own output is the
    point of showing it. A lead quiet for over half an hour reads `stale?` where its phase was: its
    process may be gone, and the state file cannot tell us."""
    cols, idw, _, _ = _layout(width, len(indent), cap)
    gap = sum(w + 1 for name, w in cols if name == "round")        # leave the round column blank
    phase = "stale?" if r["stale"] else r["phase"]
    head = (indent + _cell(_clip(phase, 13), CODE.get(phase, ""), 14, on)
            + _cell(_clip(r["name"], idw), "", idw + 1, on) + " " * gap
            + _cell(fmt_elapsed(r["elapsed"]), "", 8, on))
    parts = [f"own {fmt_tokens(r['out'])} out / {fmt_tokens(r['inp'])} in",
             f"{r['tasks']} task(s) {fmt_tokens(r['worker_out'])} out"]
    if r["quiet"] > 120:
        parts.append(f"quiet {fmt_elapsed(r['quiet'])}")
    if r["stale"]:
        parts.append("no post for over 30m: it may have died")
    return [head.rstrip(), _ind(len(indent) + 2, " · ".join(parts), width)]


def _ind(n, s, width):
    """Indent without _clip eating it: _clip collapses runs of space, leading ones included."""
    return " " * n + _clip(s, max(0, width - n))


def _chain_lines(name, ts, width, on, indent, cap, plan=""):
    """One chain and its steps, at `indent`; its steps sorted by id."""
    done = sum(1 for t in ts if t["status"] == "done")
    plan = plan or next((t["chain_plan"] for t in ts if t["chain_plan"]), "")
    out = [_ind(indent, f"{name} ({done}/{len(ts)} done){(' ' + plan) if plan else ''}", width)]
    out += [row(t, width, on, indent=" " * (indent + 2), cap=cap) for t in sorted(ts, key=lambda t: t["id"])]
    return out


def _by_activity(ts):
    return sorted(ts, key=lambda t: (t["state"] != "running", t["state"] != "verifying", -t["last_activity"]))


def frame(tasks, lead_rows, args, width, now, hidden, hidden_leads=0):
    """One frame, nested by who started what: each lead is a header row with its chains (steps
    indented below) and the tasks it started directly under it; then the chains and tasks no lead
    claims. Everything is clipped to the terminal width."""
    on = args.color_ansi
    cap = idw_hint(tasks, lead_rows)
    L = []
    hdr = (f"delegate top · {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(now))} · "
           f"{args.state} · {len(tasks)} task(s) · {len(lead_rows)} lead(s)")
    if hidden:
        hdr += f" · {hidden} finished >24h hidden (--all)"
    if args.watch:
        hdr += " · Ctrl-C quits"
    L.append(_clip(hdr, width))

    left = {t["id"]: t for t in tasks}
    for r in lead_rows:
        chains = {c: ts for c in r["chain_names"]
                  for ts in [[t for t in left.values() if t["chain"] == c]] if ts}
        under = {t["id"] for ts in chains.values() for t in ts}    # a step is shown once: under its chain
        direct = [left[i] for i in r["task_ids"] if i in left and i not in under]
        mine = [t for ts in chains.values() for t in ts] + direct
        # its own row counts what is here to show, so the line and the tree under it cannot disagree
        L += [""] + lead_row(dict(r, tasks=len(mine),
                                  worker_out=sum(t["output_tokens"] for t in mine)), width, on, cap=cap)
        for c in sorted(chains):
            L += _chain_lines(c, chains[c], width, on, 2, cap)
            for t in chains[c]:
                left.pop(t["id"], None)
        if direct:
            L += [row(t, width, on, indent="  ", cap=cap) for t in _by_activity(direct)]
            for t in direct:
                left.pop(t["id"], None)
    rest_chains, loose = {}, []
    for t in left.values():
        (rest_chains.setdefault(t["chain"], []) if t["chain"] else loose).append(t)
    if rest_chains or loose:
        L += ["", _clip("Not started by a lead", width)]
        for c in sorted(rest_chains):
            L += _chain_lines(c, rest_chains[c], width, on, 2, cap)
        L += [row(t, width, on, indent="  ", cap=cap) for t in _by_activity(loose)]
    counts = {}
    for t in tasks:
        counts[t["state"]] = counts.get(t["state"], 0) + 1
    note = " ·  ".join(f"{v} {k}" for k, v in sorted(counts.items())) or "no tasks"
    if hidden_leads:                                             # off the header: a narrow one would clip it
        note += f" ·  {hidden_leads} finished lead(s) hidden (--all)"
    L.append("")
    L.append(_ind(2, note, width))
    for t in tasks:
        if t["interrupted"]:
            L.append(_ind(2, f"interrupted: {t['id']} -> {t['resume']}", width))
    return L


def visible_tasks(args, now):
    ts = all_states(args.state, now)
    if args.all_:
        return ts, 0
    keep = [t for t in ts if t["status"] in ("running", "interrupted", "new")
            or t["substate"] == "verifying" or t["age"] <= DAY]
    return keep, len(ts) - len(keep)


def peek_command(t, lines=ACTIONS):
    d = Path(t["dir"]) / "rounds" / str(t["round"])
    running = 1 if (t["status"] == "running" or t["substate"] == "verifying") else 0
    return [sys.executable, str(LIB / "progress.py"), "peek",
            "--events", str(d / "events.jsonl"), "--stderr", str(d / "stderr.log"),
            "--phase-file", str(d / ".phase"), "--worktree", t["worktree"], "--task", t["id"],
            "--round", str(t["round"]), "--started", str(_mtime(d / "prompt.md")),
            "--running", str(running), "--report", str(d / "report.json"), "--lines", str(lines)]


def watch_one(args):
    """`delegate top ID`: peek's own output for the task, refreshed."""
    d = Path(args.state) / args.id
    if not (d / "meta.env").exists():
        print(f"delegate top: no such task: {args.id} (see: delegate list)", file=sys.stderr)
        return 1
    try:
        while True:
            now = time.time()
            t = state(str(d), now, args.state)
            if t["round"] == 0:
                print(f"{t['id']}: no rounds yet")
            else:
                subprocess.run(peek_command(t))
            tail = [f"state: {t['state']}" + (f" (round {t['round']}, {fmt_elapsed(t['elapsed'])}, {t['mode']})"
                                               if t["round"] else "")
                    + (f", chain {t['chain']}" if t["chain"] else "")]
            if t["interrupted"]:
                tail.append(f"this round's harness died before writing its report: {t['resume']}")
            for r in leads(now, [t], args.cache):
                if r["tasks"]:
                    tail.append(f"started by Claude agent {r['name']} ({r['phase']}, "
                                f"{fmt_elapsed(r['elapsed'])}, {fmt_tokens(r['out'])} out)")
                    break
            print("\n".join(_clip(x, args.width) for x in tail))
            if not args.watch:
                return 0
            time.sleep(args.interval)
    except KeyboardInterrupt:
        return 0
    finally:
        if args.watch:
            sys.stdout.write("\033[?25h")


def cmd_top(argv):
    import argparse
    import shutil
    ap = argparse.ArgumentParser(prog="delegate top", description=__doc__.splitlines()[0])
    ap.add_argument("id", nargs="?", default="")
    ap.add_argument("--once", action="store_true", help="print one frame, no clearing, and exit")
    ap.add_argument("--interval", default="2", help="refresh seconds (default 2)")
    ap.add_argument("--all", action="store_true", dest="all_",
                    help="include tasks finished more than 24 h ago, and leads finished over an hour ago")
    ap.add_argument("--state", default="", help="task state dir (default $DELEGATE_STATE)")
    ap.add_argument("--cache", default="", help="Claude agent state dir (default $XDG_CACHE_HOME/claude-agent-progress)")
    ap.add_argument("--color", action="store_true", help="force ANSI colours even when piped")
    a = ap.parse_args(argv)
    try:
        a.interval = float(a.interval)
    except ValueError:
        print("delegate top: --interval wants a number of seconds", file=sys.stderr)
        return 2
    if a.interval < 0.2:
        a.interval = 0.2
    a.state = a.state or str(default_state_dir())
    a.color_ansi = colour_on(a)
    a.watch = not a.once and sys.stdout.isatty()          # not a tty: one frame, no clearing
    a.width = shutil.get_terminal_size((120, 40)).columns
    if a.id:
        return watch_one(a)
    try:
        if a.watch:
            sys.stdout.write("\033[?25l")                 # back when we leave, however we leave
        while True:
            now = time.time()
            tasks, hidden = visible_tasks(a, now)
            rows = leads(now, tasks, a.cache)
            shown = rows if a.all_ else [r for r in rows if not r["hidden"]]
            a.width = shutil.get_terminal_size((120, 40)).columns
            lines = frame(tasks, shown, a, a.width, now, hidden, len(rows) - len(shown))
            sys.stdout.write(("\033[2J\033[H" if a.watch else "") + "\n".join(lines) + "\n")
            sys.stdout.flush()
            if not a.watch:
                return 0
            time.sleep(a.interval)
    except KeyboardInterrupt:
        return 0
    finally:
        if a.watch:
            sys.stdout.write("\033[?25h\n")


def _pick(argv, flag, default=""):
    return argv[argv.index(flag) + 1] if flag in argv and argv.index(flag) + 1 < len(argv) else default


def main(argv=None):
    # `delegate top | head` must not print a BrokenPipe traceback when head quits early
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return 0
    cmd, rest = argv[0], argv[1:]
    if cmd == "top":
        return cmd_top(rest)
    state_dir = _pick(rest, "--state", "") or str(default_state_dir())
    if cmd in ("status", "json"):
        if not rest:
            print("taskstate: need a task id", file=sys.stderr)
            return 2
        d = Path(state_dir) / rest[0] if "/" not in rest[0] else Path(rest[0])
        if not (d / "meta.env").exists():
            print(f"taskstate: no such task: {rest[0]}", file=sys.stderr)
            return 1
        t = state(str(d), state_dir=state_dir)
        if cmd == "json":
            print(json.dumps(t, indent=2, default=str))
        else:
            print(t["state"])
        return 0
    if cmd == "statuses":
        for t in all_states(state_dir):
            print("\t".join([t["id"], str(t["round"]), t["state"], t["worktree"]]))
        return 0
    if cmd == "leads":
        now = time.time()
        ts = all_states(state_dir, now)
        for r in leads(now, ts, _pick(rest, "--cache", "")):
            print("\t".join(str(x) for x in (r["name"], r["phase"], int(r["elapsed"]),
                                             r["out"], r["inp"], r["worker_out"], r["tasks"])))
        return 0
    print(f"taskstate: unknown command {cmd!r} (see: taskstate.py --help)", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
