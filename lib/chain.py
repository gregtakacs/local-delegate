#!/usr/bin/env python3
"""delegate chain — run a planned slice step by step on the local worker, unattended.

  delegate chain PLAN.json            run (or resume) the chain
  delegate chain PLAN.json --check    lint the plan (each step's "scope" vs the files its spec
                                      owns) and exit: nothing starts, no state is written, no hook
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
      {"name": "w4-1-handles", "spec": "docs/specs/w4-1.md", "verify": "npm ci && npm test",
       "scope": ["src/handles/", "tests/fixtures/handles/"]},
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

A step may carry `"scope": [...]` — the path patterns it is allowed to change, exactly the files its
spec owns (see the step-spec template's "Files owned"). `load_plan` validates every entry, and a run
or `--check` lints each scoped step's scope against its spec: a plan whose scope misses a file the
spec tells the worker to modify is refused there, before any state is written, with one line per
miss. A scoped step's verify is handed to the worker with a scope gate in front of it, so a step that
changed something outside its scope fails in a second, before the real verify starts, against the
branch that step itself begins from. A gate failure naming a file the spec owns is a plan bug: the
chain stops at once (exit 3) rather than spending retries on it, because no round can fix the plan.
A failure on any other path gets one targeted retry, to revert it. A step with no `scope` behaves
exactly as before.

In place ("here": true, no "base"): every step runs `delegate run --here` in the plan's repo
checkout itself, natively, in sequence, so the user watches the edits land live. The checkout
must be clean when the chain starts. Each accepted step is committed on the CURRENT branch
("<chain>: <step>"), so the slice is one commit per step there instead of a delegate/ branch.
A failing step's changes stay uncommitted in the checkout; re-running resumes it.

Nothing here reviews code. That is the orchestrator's job, once, at the end of the slice.
"""
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import taskstate                                                      # the task states top/list use
import ledger                                                         # the chain row (T2-F)

ME = Path(__file__).resolve()
DELEGATE = os.environ.get("DELEGATE_CHAIN_BIN") or str(ME.parent.parent / "bin" / "delegate")   # override: tests
STATE = Path(os.environ.get("DELEGATE_STATE") or
             Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "delegate")
UNTRUSTED = os.environ.get("DELEGATE_UNTRUSTED_REPO") == "1"   # no plain host git on the plan's repo


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


CONTRADICTION = ("If the spec contradicts itself, an existing test or the verify command, do not keep "
                 "trying: end with STATUS: blocked and state the contradiction under QUESTIONS.")


def retry_message(rep, tid, n, scope_paths=()):
    st = rep.get("status")
    if st == "done-but-verify-failed":
        msg = (f"The harness ran this step's verify command after your round and it FAILED (exit "
               f"{rep.get('verify_rc')}). Here is the tail of its output:\n\n```\n{verify_tail(tid, n)}\n```\n\n"
               "Find the cause and fix it in the code (never by weakening a test or the check), run the "
               "verify command yourself until it passes, then finish with the closing block.")
        if scope_paths:
            msg += ("\n\nThe scope gate refused this step before its verify ran: these changed paths are "
                    "outside this step's scope:\n"
                    + "".join(f"  {p}\n" for p in scope_paths)
                    + "\nRevert them — restore each changed file from this step's base and delete the new "
                      "ones — unless the spec requires them; if it does, end with STATUS: blocked and name "
                      "the file under QUESTIONS.")
        return msg + "\n\n" + CONTRADICTION
    if st in ("partial", "no-status"):
        return ("Your last round ended without completing the step (status: " + st + "). Finish every "
                "acceptance criterion in the spec, run the verify command until it passes, and end with "
                "the closing block. If something truly cannot be done, say exactly what under QUESTIONS. "
                + CONTRADICTION)
    if st in ("worker-error", "truncated", "timeout"):
        return ("Your last round was cut off (" + st + "). Re-check the state of the worktree (git status, "
                "the last files you touched), then continue the step from where it stands, keep tool "
                "payloads small, and finish with the verify command and the closing block.")
    return f"The step is not accepted yet (status: {st}). Complete it per the spec and verify."


# ------------------------------------------------------------------------------ scope ----
# A chain step's "only these files" rule is a plan field, not a grep at the end of a verify string:
# the chain lints it against the spec at load, runs it as the FIRST thing inside the verify it hands
# the task (so a scope miss costs a second, not a full test run), and refuses to retry a failure the
# worker cannot fix. A plan whose steps carry no "scope" is untouched by all of this.

SCOPE_CHARS = re.compile(r"[A-Za-z0-9._/*?+@=,~-]+\Z")          # nothing shell-shaped can reach a shell
SCOPE_BASE = re.compile(r"[A-Za-z0-9._/@+-]+\Z")                # the branch the gate diffs against
SCOPE_ESC = ".+()[]{}|^$\\"                                     # ERE metacharacters this regex may emit
OWNED_HEAD = re.compile(r"^\s*[-*]\s+(new|create|modify|delete|remove)\s*:", re.I)
BACKTICK = re.compile(r"`([^`\n]*)`")
OWNED_CUT = re.compile(r"\s(?:—|--)\s|;\s|\.(?=\s|$)|(?<=`)\s*:\s")
SCOPE_PROBE = "__delegate-scope-probe__"


def _scope_seg(seg):
    """One path segment (no '/'), its '*' and '?' as wildcards, as a POSIX ERE fragment."""
    out = []
    for ch in seg:
        if ch == "*":
            out.append("[^/]*")                                 # '*' never crosses '/'
        elif ch == "?":
            out.append("[^/]")
        elif ch in SCOPE_ESC:
            out.append("\\" + ch)                              # '.', '+' and friends stay literal
        else:
            out.append(ch)
    return "".join(out)


def _scope_entry(entry):
    """One scope entry as a POSIX ERE fragment matching the whole path it admits: an exact path,
    'dir/' for anything under a directory, and '*', '?', '**' as wildcards ('**' spans any number
    of segments, including none)."""
    parts = entry.split("/")
    rx, skip_sep = "", False
    for i, part in enumerate(parts):
        last = i == len(parts) - 1
        if part == "**":                                        # '**', 'dir/**', 'a/**/b'
            if i == 0:
                rx += ".*" if last else "(.*/)?"                # a leading ** eats its own separator
                skip_sep = True
            else:
                rx += "(/.*)?"
                skip_sep = False
        elif last and part == "":                               # 'dir/': anything under dir
            rx += "(/.*)?"
            skip_sep = False
        else:
            if not skip_sep and i:
                rx += "/"
            rx += _scope_seg(part)
            skip_sep = False
    return rx


def scope_regex(entries):
    """The entries as one anchored POSIX ERE. The lint (re.fullmatch) and the gate (grep -E) use
    this same string, so the two cannot disagree about what a scope admits."""
    return "^(" + "|".join(_scope_entry(e) for e in entries) + ")$"


def validate_scope(plan, s):
    """A step's 'scope' must be a non-empty list of repo-relative path patterns whose characters
    leave no way into a shell: no quote, space, '$', backslash, bracket or newline."""
    ent = s.get("scope")
    if not isinstance(ent, list) or not ent:
        die(f"step {s['name']}: 'scope' must be a non-empty list of path patterns", 2)
    for e in ent:
        why = None
        if not isinstance(e, str):
            die(f"step {s['name']}: scope entry {e!r}: every entry must be a string", 2)
        if not e:
            why = "it is empty"
        elif e.startswith("/"):
            why = "it must be repo-relative (no leading '/')"
        elif ".." in e.split("/"):
            why = "it may not contain a '..' segment"
        elif not SCOPE_CHARS.match(e):
            why = "it uses a character outside A-Za-z0-9 . _ / * ? + @ = , ~ -"
        if why:
            die(f"step {s['name']}: scope entry {e!r}: {why}", 2)
    s["_scope_re"] = scope_regex(ent)


def owned_paths(spec_text):
    """[(path, line_no)] — the files a spec claims to own: the backticked paths at the HEAD of a
    '- new:|create:|modify:|delete:|remove:' bullet (its continuation lines included). The head is
    the path list: it ends at the first ' — ', ' -- ', '; ' or sentence end, and text in
    parentheses is prose, so the bullet "modify: a.py, b.py (calls x.y) — reads c.md" (each name
    backticked) owns a.py and b.py only. A bullet under a 'Read first' heading is not an edit; a bare filename
    takes the directory of the path before it; 'dir/**' names that directory; a ':LINE' suffix is
    dropped."""
    lines = spec_text.splitlines()
    out, seen, heading_read = [], set(), False
    for i, line in enumerate(lines):
        if line.lstrip().startswith("#"):
            heading_read = line.lstrip("#").strip().lower() == "read first"
            continue
        if heading_read or not OWNED_HEAD.match(line):
            continue
        indent = len(line) - len(line.lstrip())
        bullet = [line]
        for nxt in lines[i + 1:]:
            if not nxt.strip() or len(nxt) - len(nxt.lstrip()) <= indent:
                break
            bullet.append(nxt)
        path_dir = None
        text = OWNED_HEAD.sub("", " ".join(x.strip() for x in bullet), count=1)
        while True:                                          # parentheses are prose: drop them
            t2 = re.sub(r"\([^()]*\)", " ", text)
            if t2 == text:
                break
            text = t2
        text = OWNED_CUT.split(text, maxsplit=1)[0]         # the path list ends at the first prose
        for tok in BACKTICK.findall(text):
            tok = re.sub(r":\d+(-\d+)?$", "", tok.strip())   # `file.py:670` is that file
            if not tok or " " in tok or ("/" not in tok and "." not in tok):
                continue                                     # ROUTE_PARAMS, frozenset({"hidden"}), …
            if tok.endswith("**"):
                tok = tok[:-2].rstrip("/") + "/"              # a '**' entry means the directory
            if not tok:
                continue
            if "/" in tok:
                path_dir = tok if tok.endswith("/") else tok[:tok.rindex("/") + 1]
            else:
                tok = (path_dir or "") + tok                   # bare name: the last path's directory
            if (tok, i + 1) not in seen:
                seen.add((tok, i + 1))
                out.append((tok, i + 1))
    return out


def owned_first(text):
    """A spec's owned paths de-duplicated by path, keeping the line of the first mention."""
    first = {}
    for p, n in owned_paths(text):
        first.setdefault(p, n)
    return first


def spec_text(s):
    """The step's spec as it is on disk NOW (a spec edited between rounds is what decides)."""
    try:
        return Path(s["_spec"]).read_text(errors="replace")
    except OSError:
        return ""


def lint_plan(plan):
    """Every path a step's spec owns must be inside that step's scope; a step with no 'scope' is
    not linted. Refuses (exit 2) before any state is written and before any step starts."""
    misses = []
    for s in plan["steps"]:
        s["_owned"] = sorted(owned_first(spec_text(s)))
        if not s.get("scope"):
            continue
        rx = re.compile(s["_scope_re"])
        for p, line in owned_first(spec_text(s)).items():
            probe = p + SCOPE_PROBE if p.endswith("/") else p          # a dir: covered by any path in it
            if not rx.fullmatch(probe):
                misses.append(f"step {s['name']}: the spec owns {p} ({s['spec']}:{line}) "
                              f"but the step's scope does not admit it")
    if misses:
        die("\n".join(dict.fromkeys(misses)), 2)


def check_plan(plan):
    """`delegate chain PLAN --check`: the lint's verdict for every step, and nothing else."""
    for i, s in enumerate(plan["steps"], 1):
        if s.get("scope"):
            print(f"  {i}. {s['name']}  scope: {len(s['scope'])} entries, "
                  f"owned: {len(s.get('_owned') or [])} (all covered)")
        else:
            print(f"  {i}. {s['name']}  no scope")


def scope_violations(tid, n):
    """The paths the scope gate refused in this round's verify.log, in order ([] if it said nothing)."""
    try:
        lines = (STATE / tid / "rounds" / str(n) / "verify.log").read_text(errors="replace").splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        rest = line[len("DELEGATE-SCOPE:"):].strip() if line.startswith("DELEGATE-SCOPE:") else ""
        if rest and not (rest.startswith("ok ") or rest.startswith("outside") or
                         rest.startswith("cannot find")) and rest not in out:
            out.append(rest)
    return out


def names_path(text, path):
    """True when the spec text names this exact path: not as part of a longer one (`a.py` is not
    named by `data.py` or `x/a.py`)."""
    return re.search(r"(?<![\w./-])" + re.escape(path) + r"(?![\w/-]|\.\w)", text) is not None


def step_verify(s, base):
    """The verify to hand a step: the scope gate in front of it when the step has a scope (so a
    scope miss fails in a second, before the real verify starts), the plan's verify otherwise.
    `base` is the branch this step starts from, or None in place."""
    if not s.get("scope"):
        return s["verify"]
    return scope_gate(s["scope"], base) + "\n" + s["verify"]


def print_step_verify(plan, name, base):
    """Print step `name`'s verify as the plan has it now (step_verify), with no newline added.
    Exit 2 when the plan has no such step, so the caller keeps the verify it recorded."""
    for s in plan["steps"]:
        if s.get("name") == name:
            sys.stdout.write(step_verify(s, base or None))
            return
    die(f"{plan['_path']} has no step {name!r}", 2)


# The gate's last line. Reports and logs show everything up to it as "[scope gate]" (bin/delegate
# verify_shown, lib/report.py shown_verify), so a step's own verify stays readable.
SCOPE_GATE_END = "# delegate chain: end of the scope gate"


def scope_gate(entries, base):
    """The bash snippet that runs FIRST inside the verify: every path this step changed (committed,
    staged, unstaged, deleted, untracked) must match the step's scope, diffed from the branch the
    step starts from. On a violation it prints the paths and exits 1, so the real verify never
    starts. `base` is None for an in-place step, whose changes sit uncommitted on its own HEAD."""
    from_ = ("__dsc_from=HEAD" if base is None else
             f"__dsc_from=$(git merge-base HEAD '{base}' 2>/dev/null || true)\n"
             f"if [ -z \"$__dsc_from\" ]; then "
             f"printf 'DELEGATE-SCOPE: cannot find the base %s\\n' '{base}'; exit 1; fi")
    return ("# delegate chain: this step's scope gate (runs before the verify; it takes a second)\n"
            "__dsc_re='" + scope_regex(entries) + "'\n" + from_ + "\n"
            "__dsc_files=$( { git -c core.quotePath=false diff --name-only --no-renames \"$__dsc_from\"; "
            "git -c core.quotePath=false ls-files --others --exclude-standard; } | sort -u)\n"
            "__dsc_n=0\n__dsc_bc=0\n__dsc_bad=''\n"
            "while IFS= read -r __dsc_p; do\n"
            "  [ -n \"$__dsc_p\" ] || continue\n"
            "  __dsc_n=$((__dsc_n+1))\n"
            "  if [[ $__dsc_p =~ $__dsc_re ]]; then continue; fi\n"
            "  __dsc_bc=$((__dsc_bc+1))\n"
            "  if [ \"$__dsc_bc\" = 1 ]; then __dsc_bad=\"$__dsc_p\"; "
            "else __dsc_bad=\"$__dsc_bad\n$__dsc_p\"; fi\n"
            "done <<< \"$__dsc_files\"\n"
            "if [ \"$__dsc_bc\" != 0 ]; then\n"
            "  printf \"DELEGATE-SCOPE: outside this step's scope:\\n\"\n"
            "  while IFS= read -r __dsc_p; do\n"
            "    [ -n \"$__dsc_p\" ] || continue\n"
            "    printf 'DELEGATE-SCOPE:   %s\\n' \"$__dsc_p\"\n"
            "  done <<< \"$__dsc_bad\"\n"
            "  exit 1\n"
            "fi\n"
            "printf 'DELEGATE-SCOPE: ok (%s changed paths)\\n' \"$__dsc_n\"\n"
            + SCOPE_GATE_END)


def load_plan(path, lint=False):
    p = Path(path).resolve()
    try:
        plan = json.loads(p.read_text())
    except (OSError, ValueError) as e:
        die(f"cannot read plan {p}: {e}")
    here = bool(plan.get("here"))
    if here and UNTRUSTED:
        # Refused here, at load: no step starts and no chain state is written for this plan.
        die('DELEGATE_UNTRUSTED_REPO=1: an in-place plan runs git in the checkout on the host; '
            'use an isolated plan (a "base", no "here")', 2)
    for k in ("name", "steps") + (() if here else ("base",)):
        if not plan.get(k):
            die(f"plan is missing '{k}'")
    if here:
        for k in ("base", "service", "copy"):
            if plan.get(k):
                die(f"an in-place plan (\"here\": true) cannot use '{k}'")
    if "scope" in plan:
        die("plan-level 'scope' is not supported; put it on each step", 2)
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
        if s.get("scope") is not None:
            validate_scope(plan, s)
    if any(s.get("scope") for s in plan["steps"]) and plan.get("base") and not SCOPE_BASE.match(plan["base"]):
        die(f"plan base {plan['base']!r}: a scoped step diffs against it; use A-Za-z0-9 . _ / @ + -", 2)
    if lint:
        lint_plan(plan)
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
        verify = step_verify(s, None if here else base)
        if n is None:
            note(f"{label}: starting " + ("in place" if here else f"from {base}"))
            r = subprocess.run([DELEGATE, "run", s["_spec"], "--repo", plan["repo"], "--name", s["name"],
                                *([] if here else ["--base", base]), "--verify", verify, *common,
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
            scope_paths = scope_violations(tid, n) if stt == "done-but-verify-failed" and s.get("scope") else []
            if scope_paths:
                # A path the spec itself names: no round can fix that, only an edited plan can.
                named = [p for p in scope_paths
                         if p in owned_first(spec_text(s)) or names_path(spec_text(s), p)]
                if named:
                    print_status(plan)
                    die(" ".join(f"{s['name']}: the scope gate refused {p}, which the spec names: the "
                                 f"plan's scope is wrong. Fix the step's \"scope\" in {plan['_path']} "
                                 f"(delegate chain {plan['_path']} --check), then re-run the chain."
                                 for p in named), 3)
            if tries >= retries:
                print_status(plan)
                die(f"{label} still '{stt}' after {tries} retr{'y' if tries == 1 else 'ies'}: "
                    f"`delegate report {tid}`. Fix the spec or send feedback, then re-run the chain.", 3)
            tries += 1
            note(f"{label}: {stt} — retry {tries}/{retries} in the same session")
            msg_file = STATE / tid / "chain-retry.md"
            msg_file.write_text(retry_message(rep or {}, tid, n, scope_paths))
            # the plan's verify, not the one the task was started with: an edited plan takes effect
            subprocess.run([DELEGATE, "continue", tid, str(msg_file),
                            "--verify", step_verify(s, None if here else base)],
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
    # The one git call an untrusted chain makes on the repo: through the delegate binary, which runs
    # it in the sandbox. Every other git() call here is in-place-only, behind load_plan's refusal.
    if UNTRUSTED:
        r = sh([DELEGATE, "_repo-git", plan["repo"], "--", "diff", "--stat=120", base_sha, f"delegate/{last}"])
    else:
        r = sh(["git", "-C", plan["repo"], "diff", "--stat=120", base_sha, f"delegate/{last}"])
    stat = r.stdout.strip()
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


# ------------------------------------------------------------------------ chain row ----
# T2-F: one ledger row per `delegate chain` RUN, written when run(plan) stops for any reason,
# including SIGINT/SIGTERM. It is best-effort exactly like the --on-* hooks above: any failure
# is one warning line on stderr and never changes the chain's outcome or exit code. --status,
# --wait and --clean write nothing: only a run that ran (or was running) steps ends in a row.

def chain_orchestrator(env):
    """The harness and session that started this run, read the way bin/delegate's
    `orchestrator_of` reads them: Claude Code wins when both ids are set (it is then the inner,
    direct caller), and an id outside the plain token shape is not recorded."""
    if env.get("CLAUDE_CODE_SESSION_ID"):
        harness, session = "claude-code", env["CLAUDE_CODE_SESSION_ID"]
    elif env.get("OPENCODE_SESSION_ID"):
        harness, session = "opencode", env["OPENCODE_SESSION_ID"]
    else:
        return None, None
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", session or ""):
        return None, None
    return harness, session


def chain_git_common(repo):
    """The repo's git common dir as an absolute path (the project name for a linked worktree),
    or None when git will not say — `project_of` then falls back to the repo."""
    r = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
    gc = r.stdout.strip() if r.returncode == 0 else ""
    if gc and not os.path.isabs(gc):                       # git < 2.31 prints it relative to cwd
        gc = str(Path(repo) / gc)
    return gc or None


def chain_step_records(plan):
    """One record per plan step, in plan order, from `status(plan)` — the same reading
    `delegate chain --status` prints, taken at the moment the run stopped. A step that never
    started has no round count, which is not the same as zero."""
    records = []
    for s, (_, _, step_status, n) in zip(plan["steps"], status(plan)):
        ran = step_status != "not started"
        records.append({"step": s["name"], "task_id": task_id(plan["repo"], s),
                        "status": step_status, "rounds": n if ran else None,
                        "retries": (n - 1) if ran and n else None,
                        "hard": bool(s.get("hard"))})
    return records


def chain_outcome(rc, plan):
    """`done` when the run ended green with every step done; else the first step that is not
    done decides the outcome: `blocked` and `partial` as such, `failed` for anything else a
    step ends in (retries spent, a run that died before the first report)."""
    rows = status(plan)
    if rc == 0 and all(st == "done" for _, _, st, _ in rows):
        return "done"
    for _, _, st, _ in rows:
        if st != "done":
            return st if st in ("blocked", "partial") else "failed"
    return "failed"


def record_chain_row(mark, plan, outcome, exit_code):
    """Append the chain row, once per run (`mark` guards the write vs. the signal handler).
    `outcome` names how the run stopped, or None to derive it from the exit code and the step
    statuses. Everything here is best-effort by contract: an error — unreadable plan,
    unwritable ledger — is one `delegate chain:` warning, and the run keeps the outcome and
    exit code it had."""
    if mark["written"]:
        return
    mark["written"] = True
    try:
        flag = os.environ.get("DELEGATE_LEDGER", "").strip()
        if flag.lower() in ("off", "none", "false"):
            note(f"chain row: the ledger is off (DELEGATE_LEDGER={flag}): the row was not written")
            return
        harness, session = chain_orchestrator(os.environ)
        ledger.append_chain_row(ledger.resolve_ledger({}, os.environ), {
            "chain": plan["name"], "repo": plan["repo"],
            "project": ledger.project_of(chain_git_common(plan["repo"]), plan["repo"]),
            "plan_hash": hashlib.sha256(Path(plan["_path"]).read_bytes()).hexdigest(),
            "started_at": mark["started"], "ended_at": time.time(),
            "outcome": outcome or chain_outcome(exit_code, plan), "exit": exit_code,
            "steps": chain_step_records(plan),
            "orchestrator": harness, "orchestrator_session": session})
    except Exception as e:                                # noqa: BLE001 — by contract, as with hooks
        note(f"chain row: {e} (the chain's result stands)")


def install_chain_signals(mark, plan):
    """SIGINT/SIGTERM: write the chain row, then die by the signal exactly as an unhandled
    chain does today — the default disposition restored and the signal re-raised at our own
    pid, so the exit stays 130/143 and --on-done still does not fire."""
    def handler(signum, frame):                            # noqa: ARG001 — signature
        record_chain_row(mark, plan, "interrupted", 128 + signum)
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, handler)


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return
    # only a run and --check lint the plan: --status, --clean and --wait read and report as before
    plan = load_plan(args[0], lint=("--check" in args or
                                    not any(f in args for f in ("--status", "--clean", "--wait",
                                                                "--step-verify"))))
    if "--step-verify" in args:
        # `delegate continue` on a chain step asks for the plan's current verify, so a scope or
        # verify edited in the plan reaches that round too (not only the chain's own retries).
        print_step_verify(plan, _str_opt(args, "--step-verify"),
                          None if "--here" in args else _str_opt(args, "--base"))
    elif "--check" in args:
        check_plan(plan)
    elif "--status" in args:
        print_status(plan)
    elif "--clean" in args:
        clean(plan)
    elif "--wait" in args:
        sys.exit(wait(plan, _opt(args, "--timeout", None), _opt(args, "--interval", 20)))
    else:
        plan["_on_step"] = _str_opt(args, "--on-step") or os.environ.get("DELEGATE_ON_STEP", "")
        hook = _str_opt(args, "--on-done") or os.environ.get("DELEGATE_ON_DONE", "")
        mark = {"written": False, "started": time.time()}
        install_chain_signals(mark, plan)
        rc = 0
        try:
            run(plan)
        except SystemExit as e:
            rc = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
            raise
        except BaseException:
            rc = 1                                        # a crash still ends the run: row first
            raise
        finally:
            record_chain_row(mark, plan, None, rc)
            if hook:
                fire_on_done(plan, rc, hook)


if __name__ == "__main__":
    main()
