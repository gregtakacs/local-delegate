#!/usr/bin/env python3
"""delegate chain — run a planned slice step by step on the local worker, unattended.

  delegate chain PLAN.json            run (or resume) the chain
  delegate chain PLAN.json --status   where the chain is, without running anything
  delegate chain PLAN.json --clean    remove the chain's tasks (worktrees, sidecars; branches kept)

PLAN.json (written by the orchestrator, normally next to the specs):
  {
    "name": "w4-handles",                       # chain id; state lives under DELEGATE_STATE/chains/
    "repo": ".",                                # relative to the plan file's directory
    "base": "w4",                               # branch the first step starts from
    "service": "postgres",                      # optional, every step
    "read": ["/path/to/another/checkout"],      # optional, every step
    "copy": [".env"],                           # optional, every step
    "orb": ".orb-target",                       # optional: a physical orb (serial + real LAN)
    "grants": ["orb-desk"],                     # optional: named access profiles (docs/grants.md);
    "allow": ["flash"],                         #   a step may set its own "grants"/"allow" too
    "retries": 2,                               # extra in-session rounds per step on failure
    "timeout": 5400,                            # optional, per round
    "here": false,                              # optional: in place, see below
    "steps": [
      {"name": "w4-1-handles", "spec": "docs/specs/w4-1.md", "verify": "npm ci && npm test"},
      {"name": "w4-2-publish", "spec": "docs/specs/w4-2.md", "verify": "...", "hard": false}
    ]
  }

Each step runs on the previous step's branch, so the last step's branch holds the whole
slice, one commit per round. A step is accepted only when the harness status is `done`
(the worker said done AND the verify command passed). Otherwise the chain sends the failure
back into the same session (verify output tail, or what went wrong) up to `retries` times.
It stops — exit 3 — when a step is still failing, or at once on `blocked` (a decision only
the orchestrator can make). Re-running the same command resumes from the failed step:
fix its spec or answer its question first, then run again. A step whose last round was
interrupted (its harness died before writing the report) is finished first, with
`delegate finish`, and the chain decides on the report that produces.

In place ("here": true, no "base"): every step runs `delegate run --here` in the plan's repo
checkout itself, natively, in sequence, so the user watches the edits land live. The checkout
must be clean when the chain starts. Each accepted step is committed on the CURRENT branch
("<chain>: <step>"), so the slice is one commit per step there instead of a delegate/ branch.
A failing step's changes stay uncommitted in the checkout; re-running resumes it.

Nothing here reviews code. That is the orchestrator's job, once, at the end of the slice.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import taskstate                                                      # the task states top/list use

ME = Path(__file__).resolve()
DELEGATE = os.environ.get("DELEGATE_CHAIN_BIN") or str(ME.parent.parent / "bin" / "delegate")   # override: tests
STATE = Path(os.environ.get("DELEGATE_STATE") or
             Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "delegate")


def die(msg, code=1):
    print(f"delegate chain: {msg}", file=sys.stderr)
    sys.exit(code)


def note(msg):
    print(f"delegate chain: {msg}", file=sys.stderr, flush=True)


def sh(args, check=False):
    return subprocess.run(args, text=True, capture_output=True, check=check)


def task_id(repo, step):
    return f"{Path(repo).name}-{step['name']}"


def last_report(tid):
    d = STATE / tid / "rounds"
    if not d.is_dir():
        return None, None
    rounds = sorted((int(p.name) for p in d.iterdir() if p.name.isdigit()))
    for n in reversed(rounds):
        rj = d / str(n) / "report.json"
        if rj.exists():
            return n, json.loads(rj.read_text())
    return (rounds[-1] if rounds else None), None


def verify_tail(tid, n, lines=40):
    try:
        t = (STATE / tid / "rounds" / str(n) / "verify.log").read_text(errors="replace").splitlines()
        return "\n".join(t[-lines:])
    except OSError:
        return "(no verify log)"


def retry_message(rep, tid, n):
    st = rep.get("status")
    if st == "done-but-verify-failed":
        return (f"The harness ran this step's verify command after your round and it FAILED (exit "
                f"{rep.get('verify_rc')}). Here is the tail of its output:\n\n```\n{verify_tail(tid, n)}\n```\n\n"
                "Find the cause and fix it in the code (never by weakening a test or the check), run the "
                "verify command yourself until it passes, then finish with the closing block.")
    if st in ("partial", "no-status"):
        return ("Your last round ended without completing the step (status: " + st + "). Finish every "
                "acceptance criterion in the spec, run the verify command until it passes, and end with "
                "the closing block. If something truly cannot be done, say exactly what under QUESTIONS.")
    if st in ("worker-error", "truncated", "timeout"):
        return ("Your last round was cut off (" + st + "). Re-check the state of the worktree (git status, "
                "the last files you touched), then continue the step from where it stands, keep tool "
                "payloads small, and finish with the verify command and the closing block.")
    return f"The step is not accepted yet (status: {st}). Complete it per the spec and verify."


def load_plan(path):
    p = Path(path).resolve()
    try:
        plan = json.loads(p.read_text())
    except (OSError, ValueError) as e:
        die(f"cannot read plan {p}: {e}")
    here = bool(plan.get("here"))
    for k in ("name", "steps") + (() if here else ("base",)):
        if not plan.get(k):
            die(f"plan is missing '{k}'")
    if here:
        for k in ("base", "service", "copy"):
            if plan.get(k):
                die(f"an in-place plan (\"here\": true) cannot use '{k}'")
    plan["_dir"] = p.parent
    plan["_path"] = str(p)
    plan["repo"] = str((p.parent / plan.get("repo", ".")).resolve())
    os.environ["DELEGATE_CHAIN"] = plan["name"]    # the steps' rounds report it (dashboard mode chip)
    names = [s.get("name") for s in plan["steps"]]
    if len(set(names)) != len(names) or not all(names):
        die("every step needs a unique 'name'")
    for n in names:
        if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,47}", n):
            die(f"step name {n!r}: use 1-48 chars of a-z 0-9 . _ - (it becomes the branch delegate/<name>)")
    for s in plan["steps"]:
        if not s.get("spec") or not s.get("verify"):
            die(f"step {s.get('name')}: 'spec' and 'verify' are required")
        sp = (Path(plan["repo"]) / s["spec"])
        if not sp.exists():
            sp = plan["_dir"] / s["spec"]
        if not sp.exists():
            die(f"step {s['name']}: spec not found: {s['spec']}")
        s["_spec"] = str(sp)
    return plan


def git(repo, *a):
    return sh(["git", "-C", repo, *a])


def dirty(repo):
    return bool(git(repo, "status", "--porcelain").stdout.strip())


def commit_step(plan, s, st):
    """In place: commit an accepted step on the current branch (once)."""
    rec = st["steps"].setdefault(s["name"], {})
    if rec.get("commit"):
        return
    repo = plan["repo"]
    if dirty(repo):
        git(repo, "add", "-A")
        r = git(repo, "-c", "core.hooksPath=/dev/null", "commit", "-q", "--no-verify",
                "-m", f"{plan['name']}: {s['name']}", "-m", f"delegated step, spec {s['spec']}")
        if r.returncode:
            die(f"step {s['name']}: committing it failed: {(r.stderr or r.stdout).strip()}", 2)
        note(f"step {s['name']}: committed on {git(repo, 'rev-parse', '--abbrev-ref', 'HEAD').stdout.strip()}")
    rec["commit"] = git(repo, "rev-parse", "HEAD").stdout.strip()
    save_state(plan, st)


def load_state(plan):
    try:
        return json.loads(chain_state_path(plan).read_text())
    except (OSError, ValueError):
        return None


def chain_state_path(plan):
    return STATE / "chains" / f"{plan['name']}.json"


def save_state(plan, st):
    p = chain_state_path(plan)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(st, indent=2))


def status(plan):
    """One row per step, with the same states `delegate top` and `delegate list` print (so an
    interrupted step — its harness died before the report — reads `interrupted` here too)."""
    rows = []
    for i, s in enumerate(plan["steps"], 1):
        tid = task_id(plan["repo"], s)
        n, rep = last_report(tid)
        st = taskstate.state(str(STATE / tid), state_dir=str(STATE)).get("state") or "new"
        rows.append((i, s["name"], "not started" if st == "new" else st, n or 0))
    return rows


def print_status(plan):
    print(f"chain {plan['name']}  ({plan['repo']}, from {plan['base']})")
    for i, name, st, n in status(plan):
        print(f"  {i}. {name:<36} {st:<24} rounds {n}")


def step_access(plan, s):
    """A step's own grants and allows, beyond the plan's (docs/grants.md)."""
    out = []
    for g in s.get("grants") or []:
        if g not in (plan.get("grants") or []):
            out += ["--grant", g]
    for g in s.get("allow") or []:
        if g not in (plan.get("allow") or []):
            out += ["--allow", g]
    return out


def run(plan):
    retries = int(plan.get("retries", 2))
    common = []
    if plan.get("service"):
        common += ["--service", plan["service"]]
    for r in plan.get("read") or []:
        common += ["--read", r]
    for c in plan.get("copy") or []:
        common += ["--copy", c]
    if plan.get("timeout"):
        common += ["--timeout", str(plan["timeout"])]
    if plan.get("orb"):
        common += ["--orb", str((Path(plan["repo"]) / plan["orb"]).resolve())]
    for g in plan.get("grants") or []:
        common += ["--grant", g]
    for g in plan.get("allow") or []:
        common += ["--allow", g]
    here = bool(plan.get("here"))
    base = plan.get("base")
    t0 = time.time()
    st = load_state(plan) or {}
    if st.get("finished") or not st.get("steps"):
        st = {"name": plan["name"], "started": t0, "steps": {}}
    st["steps"] = st.get("steps") or {}
    st["plan"] = plan["_path"]              # so `delegate top` can name the command that resumes it
    if here:
        common += ["--here"]
        any_started = any(last_report(task_id(plan["repo"], s))[0] is not None for s in plan["steps"])
        if not any_started:
            if dirty(plan["repo"]):
                die("an in-place chain starts from a clean checkout (each accepted step is committed "
                    "on your branch): commit or stash your changes first", 2)
            st["start_head"] = git(plan["repo"], "rev-parse", "HEAD").stdout.strip()
            st["branch"] = git(plan["repo"], "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
        save_state(plan, st)
    for i, s in enumerate(plan["steps"], 1):
        tid = task_id(plan["repo"], s)
        label = f"step {i}/{len(plan['steps'])} {s['name']}"
        n, rep = last_report(tid)
        if rep and rep.get("status") == "done":
            note(f"{label}: already done, skipping")
            if here:
                commit_step(plan, s, st)
            base = f"delegate/{s['name']}"
            continue
        if n is not None and rep is None and not (STATE / tid / "lock").is_dir():
            # The round's harness died (killed, host restarted) after the worker stopped and before
            # the report: the work is uncommitted and unverified, and its status is unknown. Finish
            # it the way `delegate finish` does (commit/snapshot, verify, report) and decide on that.
            note(f"{label}: round {n} was interrupted (no report) — finishing it")
            r = subprocess.run([DELEGATE, "finish", tid], stdout=subprocess.DEVNULL)
            n, rep = last_report(tid)
            if rep is None:
                die(f"{label}: finishing round {n} produced no report (exit {r.returncode}): "
                    f"`delegate finish {tid}` (then `delegate report {tid}`)", 2)
        hard = ["--hard"] if s.get("hard") else []
        if n is None:
            note(f"{label}: starting " + ("in place" if here else f"from {base}"))
            r = subprocess.run([DELEGATE, "run", s["_spec"], "--repo", plan["repo"], "--name", s["name"],
                                *([] if here else ["--base", base]), "--verify", s["verify"], *common,
                                *step_access(plan, s), *hard],
                               stdout=subprocess.DEVNULL)
            if r.returncode not in (0,):
                n, rep = last_report(tid)
                if rep is None:
                    die(f"{label}: delegate run failed before producing a report (exit {r.returncode})", 2)
        tries = 0
        while True:
            n, rep = last_report(tid)
            stt = (rep or {}).get("status")
            st["steps"].setdefault(s["name"], {}).update({"status": stt, "rounds": n})
            save_state(plan, st)
            if stt == "done":
                note(f"{label}: done in {n} round(s)")
                if here:
                    commit_step(plan, s, st)
                break
            if stt == "blocked":
                print_status(plan)
                die(f"{label} is BLOCKED and needs a decision: `delegate report {tid}` (QUESTIONS). "
                    f"Answer it with `delegate continue {tid} -m \"...\"`, then re-run the chain.", 3)
            if tries >= retries:
                print_status(plan)
                die(f"{label} still '{stt}' after {tries} retr{'y' if tries == 1 else 'ies'}: "
                    f"`delegate report {tid}`. Fix the spec or send feedback, then re-run the chain.", 3)
            tries += 1
            note(f"{label}: {stt} — retry {tries}/{retries} in the same session")
            msg_file = STATE / tid / "chain-retry.md"
            msg_file.write_text(retry_message(rep or {}, tid, n))
            # the plan's verify, not the one the task was started with: an edited plan takes effect
            subprocess.run([DELEGATE, "continue", tid, str(msg_file), "--verify", s["verify"]],
                           stdout=subprocess.DEVNULL)
        base = f"delegate/{s['name']}"

    # Whole-slice summary for the orchestrator's one review.
    first = task_id(plan["repo"], plan["steps"][0])
    last = plan["steps"][-1]["name"]
    meta = {}
    try:
        for line in (STATE / first / "meta.env").read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                meta[k] = v.strip("'\"")
    except OSError:
        pass
    print(f"# chain {plan['name']}: all {len(plan['steps'])} steps done in {int((time.time() - t0) / 60)} min")
    print()
    for i, name, stt, n in status(plan):
        print(f"  {i}. {name:<36} {stt:<10} rounds {n}")
    if here:
        start = st.get("start_head") or "HEAD"
        stat = sh(["git", "-C", plan["repo"], "diff", "--stat=120", start, "HEAD"]).stdout.strip()
        print(f"\nwhole slice, in place: {len(plan['steps'])} commits on {st.get('branch', 'your branch')} since "
              f"{start[:12]}\n```\n" + "\n".join(stat.splitlines()[-40:]) + "\n```")
        print(f"\nnext: one live check of the slice, read the risky files with `git diff {start[:12]}..HEAD -- PATHS`,"
              f" commit any fixes on top, then `delegate chain {plan['_path']} --clean`.")
        st["finished"] = time.time()
        save_state(plan, st)
        return
    base_sha = meta.get("BASE_SHA", plan["base"])
    stat = sh(["git", "-C", plan["repo"], "diff", "--stat=120", base_sha, f"delegate/{last}"]).stdout.strip()
    print(f"\nwhole slice: branch delegate/{last} (from {plan['base']})\n```\n" + "\n".join(stat.splitlines()[-40:]) + "\n```")
    print(f"\nnext: one live check of the slice, read the risky files with `git diff {plan['base']}...delegate/{last} -- PATHS`,"
          f" squash-merge delegate/{last}, then `delegate chain {plan['_path']} --clean`.")
    st["finished"] = time.time()
    save_state(plan, st)


def clean(plan):
    for s in plan["steps"]:
        tid = task_id(plan["repo"], s)
        if (STATE / tid).exists():
            r = sh([DELEGATE, "rm", tid])
            note((r.stderr or r.stdout).strip() or f"removed {tid}")
    try:
        chain_state_path(plan).unlink()
    except OSError:
        pass


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return
    plan = load_plan(args[0])
    if "--status" in args:
        print_status(plan)
    elif "--clean" in args:
        clean(plan)
    else:
        run(plan)


if __name__ == "__main__":
    main()
