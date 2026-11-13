#!/usr/bin/env python3
"""delegate chain — run a planned slice step by step on the local worker, unattended.

  delegate chain PLAN.json            run (or resume) the chain
  delegate chain PLAN.json --status   where the chain is, without running anything
  delegate chain PLAN.json --clean    remove the chain's tasks (worktrees, sidecars; branches kept)
  delegate chain PLAN.json --on-done CMD
                                      when THIS run ends (any terminal state), run CMD through
                                      bash; see below
  delegate chain PLAN.json --on-step CMD
                                      the same, once per step as it is accepted; see below
  delegate chain PLAN.json --wait [--timeout S] [--interval S]
  delegate wait  PLAN.json [...]      the same: block THIS process until the chain stops

`--wait` returns when nothing of the chain is running: its runner (the pid a run records in
the chain's state) is gone and no step is running, verifying or committing. Exit 0 when every
step is done; 3 when one is blocked, partial, failed or interrupted (the status says which);
124 when --timeout passes first. It watches that one pid and the steps' own state, never a
process-name search (which matches the watcher's own command line). It blocks only its own
process: an orchestrating session starts it as a tracked background task and is told when it
exits; it never runs it in the foreground of a conversation.

`--on-done CMD` / `--on-step CMD` (env fallbacks `DELEGATE_ON_DONE` / `DELEGATE_ON_STEP`) are
the wake-ups for harnesses that have no background-completion notification. Both run CMD
through `bash -lc`, best-effort: their failure warns but never changes the chain's outcome.
`--on-done` fires once when THIS run of the chain reaches a terminal state — every step done,
a step blocked, or the retry budget spent — with the chain's exit code in the environment.
`--on-step` fires each time THIS run accepts a step (after its commit, in place mode), before
the next one starts; a step it skips as already done stays silent, so resuming doesn't
re-announce. Neither fires on `--status`, `--clean` or `--wait`. Both see DELEGATE_CHAIN (name),
DELEGATE_CHAIN_PLAN, DELEGATE_CHAIN_STATUS ("step=status, ..."); `--on-done` adds
DELEGATE_CHAIN_RC, `--on-step` adds DELEGATE_CHAIN_STEP, _STEP_N, _STEP_TOTAL, _STEP_STATUS,
and both run with the repo as cwd. Keep them idempotent and cheap: a resumed chain fires
`--on-done` again at its next terminal exit, and one that dies by timeout/SIGKILL never fires
at all — the poll stays the source of truth, the hook only tells you when to look. For an
orchestrating agent the natural CMD wakes the orchestrator itself: a desktop/ntfy ping, or
posting a "step accepted" / "chain done, verify" prompt to your own session (an opencode
server accepts `POST /session/<id>/prompt_async` and answers 204).

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
    st["pid"] = os.getpid()                 # so `delegate wait` can tell a live runner from a dead one
    save_state(plan, st)
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
                if plan.get("_on_step"):
                    fire_on_step(plan, i, s, len(plan["steps"]), plan["_on_step"])
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


ACTIVE = ("running", "verifying", "committing")


def runner_alive(plan):
    """True while the pid the last run recorded is still a live process."""
    pid = (load_state(plan) or {}).get("pid")
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
    except (OSError, ValueError):
        return False
    try:                                    # a reused pid is not our runner (Linux; elsewhere trust kill)
        cmd = Path("/proc/%d/cmdline" % int(pid)).read_bytes().replace(b"\0", b" ")
        return b"chain.py" in cmd
    except OSError:
        return True


def wait(plan, timeout=None, interval=20):
    """Block this process until the chain stops (see the module doc); returns the exit code."""
    t0 = time.time()
    while True:
        rows = status(plan)
        busy = runner_alive(plan) or any(st in ACTIVE for _, _, st, _ in rows)
        if not busy:
            print_status(plan)
            return 0 if all(st == "done" for _, _, st, _ in rows) else 3
        if timeout is not None and time.time() - t0 >= timeout:
            print_status(plan)
            print("delegate wait: still running after %ds" % timeout)
            return 124
        time.sleep(interval)


def _opt(args, name, default):
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return float(args[i + 1])
    return default


def _str_opt(args, name):
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return args[i + 1]
    return ""


def fire_hook(plan, cmd, what, extra):
    """A --on-* wake-up: best-effort by contract — loud on failure, never fatal, it cannot
    change the chain's outcome, and a broken hook never takes a healthy chain down with it.
    `what` names the hook in the warnings."""
    try:
        env = dict(os.environ, **extra)
        env.update(DELEGATE_CHAIN=plan["name"], DELEGATE_CHAIN_PLAN=plan["_path"],
                   DELEGATE_CHAIN_STATUS=", ".join(f"{name}={stt}" for _, name, stt, _ in status(plan)))
        r = subprocess.run(["bash", "-lc", cmd], env=env, cwd=plan["repo"], timeout=120)
        if r.returncode:
            note(f"{what} command exited {r.returncode} (the chain's result stands; poll to confirm)")
    except subprocess.TimeoutExpired:
        note(f"{what} command timed out after 120s (the chain's result stands; poll to confirm)")
    except Exception as e:                                                    # noqa: BLE001 — by contract
        note(f"{what} command failed: {e} (the chain's result stands; poll to confirm)")


def fire_on_done(plan, rc, cmd):
    fire_hook(plan, cmd, "on-done", {"DELEGATE_CHAIN_RC": str(rc)})


def fire_on_step(plan, i, s, total, cmd):
    fire_hook(plan, cmd, "on-step", {"DELEGATE_CHAIN_STEP": s["name"],
                                     "DELEGATE_CHAIN_STEP_N": str(i),
                                     "DELEGATE_CHAIN_STEP_TOTAL": str(total),
                                     "DELEGATE_CHAIN_STEP_STATUS": "done"})


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
    elif "--wait" in args:
        sys.exit(wait(plan, _opt(args, "--timeout", None), _opt(args, "--interval", 20)))
    else:
        plan["_on_step"] = _str_opt(args, "--on-step") or os.environ.get("DELEGATE_ON_STEP", "")
        hook = _str_opt(args, "--on-done") or os.environ.get("DELEGATE_ON_DONE", "")
        rc = 0
        try:
            run(plan)
        except SystemExit as e:
            rc = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
            raise
        finally:
            if hook:
                fire_on_done(plan, rc, hook)


if __name__ == "__main__":
    main()
