#!/usr/bin/env python3
"""The flake ledger: the verify re-runs that turned a red round green.

  flakes.py append        --file PATH --repo R --task T --round N --verify CMD --rc N --log LOGFILE
  flakes.py list          --file PATH [--repo PATH] [--json]
  flakes.py plan-retries  [--plan-json JSON | --plan-file PATH]

A round whose worker said `done` and whose verify then failed may be the suite being flaky rather
than the work being wrong. The harness re-runs the same command once (bin/delegate, --verify-retries);
when that passes, the round is accepted and the failure is recorded here, one JSON line per event:

  {"at", "repo", "task", "round", "verify_sha256", "failed_rc", "tail"}

The line is the thing to read before blaming a slice: a repo whose name shows up twice has a flaky
test to fix at its source, which is what the tail's first failing line is for. `tail` is the last 40
lines of the failed run's log — the same text the round's verify-<n>.log holds, nothing new.
The file is created 0600 and stays 0600: it holds command output.
"""
import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone

TAIL_LINES = 40
SUMMARY_LIMIT = 160          # the printed failing line, clipped
FAIL_LINE = re.compile(r"FAIL|--- FAIL|Error\b|panic\b")


def sha256_of(text):
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()


def tail_of(path, lines=TAIL_LINES):
    """The last `lines` lines of a log, as one string (\"\" when the log is unreadable)."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            parts = f.read().splitlines()
    except OSError:
        return ""
    return "\n".join(parts[-lines:])


def summary_of(tail, rc=None):
    """What a reader of `delegate flakes` wants first: the first line of the tail that reads like
    a failure. A tail with no such line says so, with the exit code beside it."""
    for line in (tail or "").splitlines():
        if FAIL_LINE.search(line):
            return line.strip()[:SUMMARY_LIMIT]
    return f"(no failing line in the tail; exit {rc})" if rc is not None else "(no tail)"


def record(repo, task, rnd, verify, rc, log):
    """One flake row, in the contract's field order. `at` carries the offset on purpose: the
    doc checks in test_ledger.sh read an ISO-8601 timestamp by its +00:00, not by its Z."""
    return {"at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00"),
            "repo": repo, "task": task, "round": int(rnd),
            "verify_sha256": sha256_of(verify), "failed_rc": int(rc),
            "tail": tail_of(log)}


def append(path, row):
    """Append one row as one line, creating the file 0600. An existing file is tightened to 0600.
    Returns the row's summary line."""
    line = json.dumps(row, ensure_ascii=True, separators=(",", ":")) + "\n"
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, line.encode("utf-8", "replace"))
    finally:
        os.close(fd)
    return summary_of(row.get("tail"), row.get("failed_rc"))


def read(path):
    """Every row in the file, oldest first; an absent file is empty and a broken line is skipped."""
    rows = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return rows
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def same_repo(recorded, want):
    """The match rule for --repo: the same path in another spelling (a symlink, a trailing slash,
    a relative path walked from elsewhere), or the same directory's name on its own."""
    if not recorded:
        return False
    a = os.path.normpath(str(recorded).strip())
    b = os.path.normpath(str(want).strip())
    if a == b or os.path.basename(a.rstrip("/")) == os.path.basename(b.rstrip("/")):
        return True
    try:
        return os.path.realpath(a) == os.path.realpath(b)
    except OSError:
        return False


def filtered(rows, repo=None):
    """Newest first, and when `repo` is given, only that repository's flakes. The round number
    and task break same-second ties, so the order is total: a reader never wonders which of
    two flakes in one second happened first."""
    out = [r for r in rows if not repo or same_repo(r.get("repo"), repo)]

    def key(r):
        try:
            rnd = int(r.get("round") or 0)
        except (TypeError, ValueError):
            rnd = 0
        return (str(r.get("at") or ""), rnd, str(r.get("task") or ""))
    return sorted(out, key=key, reverse=True)


def render(rows):
    """Grouped by repo (newest flake first, groups in the same order), one line per flake:
    when, task and round, the exit code, and what the failing run said."""
    groups = {}
    for r in rows:
        groups.setdefault(str(r.get("repo") or "(unknown repo)"), []).append(r)
    order = sorted(groups, key=lambda k: max(str(r.get("at") or "") for r in groups[k]),
                   reverse=True)
    out = []
    for k in order:
        g = groups[k]
        out.append(f"{k}  ({len(g)} flake{'s' if len(g) != 1 else ''})")
        for r in g:
            out.append(f"  {r.get('at') or '?'}  {r.get('task') or '?'} round {r.get('round')}  "
                       f"exit {r.get('failed_rc')}  {summary_of(r.get('tail'), r.get('failed_rc'))}")
    last = rows[0].get("at") if rows else None
    out.append(f"{len(rows)} flake(s) in {len(groups)} repo(s)"
               + (f", newest {last}" if last else ""))
    return "\n".join(out)


def plan_retries(plan_json, plan_file):
    """The plan's verify_retries as text: the LAST step's key wins (a chain's final verify is
    the last step's gate), then the plan-level key. Empty when the plan carries neither — the
    caller falls back to the environment, then to the default of 1."""
    plan = None
    if plan_json:
        plan = json.loads(plan_json)
    elif plan_file and os.path.exists(plan_file):
        with open(plan_file, encoding="utf-8") as f:
            plan = json.load(f)
    if isinstance(plan, dict):
        steps = plan.get("steps")
        if isinstance(steps, list) and steps and isinstance(steps[-1], dict) \
                and isinstance(steps[-1].get("verify_retries"), int):
            return str(max(steps[-1]["verify_retries"], 0))
        if isinstance(plan.get("verify_retries"), int):
            return str(max(plan["verify_retries"], 0))
    return ""


def main():
    ap = argparse.ArgumentParser(prog="delegate flakes")
    ap.add_argument("cmd", choices=["append", "list", "plan-retries"])
    ap.add_argument("--file", default="")
    ap.add_argument("--repo", default="")
    ap.add_argument("--task", default="")
    ap.add_argument("--round", default="0")
    ap.add_argument("--verify", default="")
    ap.add_argument("--rc", default="1")
    ap.add_argument("--log", default="")
    ap.add_argument("--plan-json", dest="plan_json", default="")
    ap.add_argument("--plan-file", dest="plan_file", default="")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if a.cmd == "plan-retries":
        out = plan_retries(a.plan_json, a.plan_file)
        if out:
            print(out)
        return
    if not a.file:
        raise SystemExit("flakes: --file is required")
    if a.cmd == "append":
        if not a.verify:
            raise SystemExit("flakes append: --verify is required (the row keys the flake on it)")
        print(append(a.file, record(a.repo, a.task, a.round, a.verify, a.rc, a.log)))
        return
    rows = filtered(read(a.file), a.repo or None)
    if a.json:
        json.dump(rows, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return
    if not rows:
        print("(no flakes recorded" + (f" for {a.repo})" if a.repo else ")"))
        return
    print(render(rows))


if __name__ == "__main__":
    main()
