#!/usr/bin/env python3
"""delegate chain — run a planned slice step by step on the local worker, unattended.

  delegate chain PLAN.json            run (or resume) the chain
  delegate chain PLAN.json --check    lint the plan (each step's "scope" vs the files its spec
                                      owns; every verify runs the plan's "gate" — or its
                                      "step_gate" when the plan names one and the step is
                                      neither "hard" nor the last; and an "image" step that is
                                      not "hard", or a scope reaching .delegate/ without the
                                      "image" key; and a plan whose 2+ steps are
                                      all "hard": true gets a warning, never a refusal), print
                                      each step's verify as stored, and exit: nothing starts, no
                                      state is written, no hook
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
    "gate": "make check-sandbox",               # the repo's full gate, named once; a step's verify
                                                #   must contain it character for character, unless
                                                #   the step_gate below covers that step
    "step_gate": "make check-step",             # optional: the quick check an ordinary step may
                                                #   run instead (see below); never a reason to skip
                                                #   the gate on a hard or the last step
    "service": "postgres",                      # optional, every step
    "read": ["/path/to/another/checkout"],      # optional, every step
    "copy": [".env"],                           # optional, every step
    "orb": ".orb-target",                       # optional: a physical orb (serial + real LAN)
    "grants": ["orb-desk"],                     # optional: named access profiles (docs/grants.md);
    "allow": ["flash"],                         #   a step may set its own "grants"/"allow" too
    "retries": 2,                               # extra in-session rounds per step on failure
    "verify_retries": 1,                        # optional: re-runs a failed harness verify gets when
                                                #   the worker said done (a pass on a re-run is done, and
                                                #   the flake is logged). A step may set its own.
                                                #   Default 1; 0 keeps the old one-and-only verify.
    "timeout": 5400,                            # optional, per round
    "here": false,                              # optional: in place, see below
    "steps": [
      {"name": "w4-1-handles", "spec": "docs/specs/w4-1.md", "verify": "npm ci && npm test",
       "scope": ["src/handles/", "tests/fixtures/handles/"]},
      {"name": "w4-2-publish", "spec": "docs/specs/w4-2.md", "verify": "...", "hard": false},
      {"name": "w4-3-image", "spec": "docs/specs/w4-3.md", "verify": "...",
       "scope": [".delegate/Dockerfile"], "image": true, "hard": true}   # grows the worker image
    ]
  }

There are two verify levels, and the plan names both commands. `"gate"` is the repo's full gate;
`"step_gate"` is the quick check for one step — that step's own modules plus a scope guard. An
ordinary step's verify runs the gate **or** the step_gate; a step marked `"hard": true` and the
plan's **last** step must run the full gate, because that is where a skipped suite hides. The gate
still runs once more where it counts: the orchestrator runs it on a clean squash of the slice. A
plan with no `"step_gate"` is one level, as before: every step runs `"gate"`.

Each step runs on the previous step's branch, so the last step's branch holds the whole
slice, one commit per round. A step is accepted only when the harness status is `done`
(the worker said done AND the verify command passed). Otherwise the chain sends the failure
back into the same session (verify output tail, or what went wrong) up to `retries` times.
A step still failing after its retries gets one last round in the same session on the hard model
(`delegate continue --hard`), unless the plan sets `"escalate": false` or the two models are one;
then the chain stops — exit 3. Every step starts on the normal model: `"hard": true` sets the verify
level, not the model; `"xhigh": true` on a step or the plan starts it on the hard model. The chain
also stops at once on `blocked` (a decision only
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

A step may carry `"image": true` when it grows the project's worker image (it edits
`.delegate/Dockerfile`): such a step must also be `"hard": true`, and a step whose scope names
anything under `.delegate/` must carry the key (`--check` refuses both rules' breaches, naming the
step; an untrusted plan is refused for the key outright, since the rebuild runs the repo's own
Dockerfile on the host). When such a step's round ends (its verify passed in the OLD image or
failed), the chain rebuilds the image on the host — `delegate build --repo <the step's worktree>`,
pin-lint first: a refusal stops the chain with the step `image-refused` and the findings in its
report — and re-runs the step's verify through `delegate verify` in the NEW image: its verdict
decides the step, not the old image's. The build and re-verify log to the round's image-build.log
and the report gains an IMAGE section. The chain then pins that tag (DELEGATE_IMAGE, bin/delegate's
caller's-image rule) for every later call, so later steps run on the rebuilt image without a
rebuild of their own; the freshness check is untouched, and a stale image outside this path still
refuses. A step without the key whose diff touches `.delegate/` is refused at acceptance, like any
out-of-scope file: the chain stops at once.

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
import launch                                                         # the launch fingerprint
import newtests                                                       # the line printed for unrun new tests

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


def verify_tail(tid, n, lines=40, name="verify.log"):
    try:
        t = (STATE / tid / "rounds" / str(n) / name).read_text(errors="replace").splitlines()
        return "\n".join(t[-lines:])
    except OSError:
        return "(no verify log)"


def task_meta(tid):
    """A task's meta.env as a dict — the naive read (split on the first '=') for the few plain
    fields the chain names (REPO, WORKTREE, BASE_SHA); meta.env is shell-quoted, and a value
    needing ANSI-C quoting is not something these fields ever hold."""
    meta = {}
    try:
        for line in (STATE / tid / "meta.env").read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                meta[k] = v.strip("'\"")
    except OSError:
        pass
    return meta


def round_files(tid, n):
    """The paths the round's commit changed, name-only, through the delegate binary (which
    sandboxes git for an untrusted task's repo — the chain runs no plain host git on a plan repo).
    None when it cannot say: an unknown command, a round without a recorded commit."""
    r = sh([DELEGATE, "_round-diff", tid, str(n)])
    if r.returncode:
        return None
    return [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]


def touched_image_dir(paths):
    """The changed paths that reach .delegate/ — what the worker image is built from."""
    return [p for p in (paths or []) if p == ".delegate" or p.startswith(".delegate/")]


CONTRADICTION = ("If the spec contradicts itself, an existing test or the verify command, do not keep "
                 "trying: end with STATUS: blocked and state the contradiction under QUESTIONS.")


def retry_message(rep, tid, n, scope_paths=(), log="verify.log"):
    st = rep.get("status")
    if st == "done-but-verify-failed":
        msg = (f"The harness ran this step's verify command after your round and it FAILED (exit "
               f"{rep.get('verify_rc')}). Here is the tail of its output:\n\n```\n{verify_tail(tid, n, name=log)}\n```\n\n"
               "Find the cause and fix it in the code (never by weakening a test or the check), run the "
               "verify command yourself until it passes, then finish with the closing block.")
        if log == "image-build.log":
            msg += ("\n\nThis step is an image step: the chain rebuilt the project's worker image from "
                    "your `.delegate/` change on the host and re-ran this verify inside the new image; "
                    "the tail above is that re-verify and its build log. The failure is in the new "
                    "image — fix the code (or the Dockerfile's pin) so it passes there, and keep the "
                    "`.delegate/` change: it is this step's job.")
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


def step_gate(plan):
    """The plan's quick step check, or None when it names none. A plan may pair its full "gate"
    with a `"step_gate"`: the cheap command an ORDINARY step's verify may run instead of the whole
    suite — that step's own modules, plus a scope guard — so a three-step change stops paying the
    full gate once per step. It never replaces the gate where the gate is what the step is for: a
    `"hard": true` step and the plan's last step still run it (and the orchestrator runs the full
    gate once more on the squashed slice). Validated whenever the key is present; a plan with no
    `"step_gate"` is exactly as before: every step runs `"gate"`."""
    sg = plan.get("step_gate")
    if sg is None:
        return None
    if not isinstance(sg, str) or not sg.strip():
        die("plan 'step_gate' must be an ordinary step's quick check command, a non-empty string", 2)
    return sg.strip()


def lint_gate(plan):
    """A plan's "gate" is the repo's own gate command (e.g. `make check-sandbox`), named once.
    Every step's verify must run it, character for character: the full gate lives in the repo,
    under its own tests, never re-typed (or generated) per step. A generated verify once turned
    PYTHON into PYTHO2 and SDKCONFIG into SDKCO2FIG in four steps: each still ran, weaker, and
    no review saw it. A plan with no gate is not checked (older plans).

    When the plan names a `"step_gate"` too, an ordinary step may run that instead — but a
    `"hard": true` step and the plan's last step must still run "gate". Both commands are matched
    character for character, and a refusal says which of the two the step is missing."""
    gate = plan.get("gate")
    quick = step_gate(plan)                     # validated even when the plan has no gate at all
    if gate is None:
        return
    if not isinstance(gate, str) or not gate.strip():
        die("plan 'gate' must be the repo's gate command, a non-empty string", 2)
    gate = gate.strip()
    last = len(plan["steps"]) - 1
    full, either = [], []
    for i, s in enumerate(plan["steps"]):
        if gate in s["verify"]:
            continue
        must = bool(s.get("hard")) or i == last        # these run the full gate, as today
        if quick and not must and quick in s["verify"]:
            continue                                   # an ordinary step ran the quick check
        (full if (must or not quick) else either).append(s["name"])
    msgs = []
    if full:                                        # the sentence a plan with no step_gate gets
        msgs.append("these steps' verify does not run the plan's gate (%s) exactly as written: %s"
                    % (gate, ", ".join(full)))
    if either:
        msgs.append("these steps' verify does not run the plan's gate (%s) or its step_gate (%s) "
                    "exactly as written: %s" % (gate, quick, ", ".join(either)))
    if msgs:
        die("\n".join(msgs), 2)


def lint_image(plan):
    """The two plan rules for `"image": true` (the step key that grows the project's worker
    image): a step whose scope names anything under `.delegate/` must carry the key — that
    directory is the build context every later worker runs — and a step with the key must be
    `"hard": true`, because what it lands changes the toolchain of the whole rest of the chain.
    Refused at lint (exit 2, one line per breach, each naming its step) — `--check` and run alike."""
    msgs = []
    for s in plan["steps"]:
        if s.get("scope") and not s.get("image"):
            for e in s["scope"]:
                if e.split("/")[0] == ".delegate":
                    msgs.append(f"step {s['name']}: scope entry {e!r} reaches .delegate/, the "
                                f"project's worker-image build context: the step must carry "
                                f"\"image\": true (which also requires \"hard\": true)")
                    break
        if s.get("image") and not s.get("hard"):
            msgs.append(f"step {s['name']}: \"image\": true rebuilds the image every later step "
                        f"runs in: the step must also be \"hard\": true")
    if msgs:
        die("\n".join(msgs), 2)


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
    """`delegate chain PLAN --check`: the lint's verdict for every step, and each step's verify
    exactly as the chain will run it (minus the scope gate it adds), so the reviewer reads the
    stored text, not a design's description of it. A plan that marks every one of its 2+ steps
    hard gets a warning line: hard is a claim about a boundary or real algorithmic difficulty,
    and a plan that hard-marks all of its own work is not reading its own steps. It is a warning
    only: `--check`'s exit code does not change, and nothing is refused."""
    steps = plan["steps"]
    if len(steps) > 1 and all(bool(s.get("hard")) for s in steps):
        print("  warning: every step is marked hard: hard is for steps that guard a boundary or "
              "carry real algorithmic difficulty; routine steps (UI plumbing, tests, docs, "
              "pattern-following) run on the normal model")
    if plan.get("gate"):
        quick = step_gate(plan)
        if quick:
            print(f"  gate: {plan['gate'].strip()}  (every hard step and the last one run it)")
            print(f"  step_gate: {quick}  (every other step runs the gate or this)")
        else:
            print(f"  gate: {plan['gate'].strip()}  (every step runs it)")
    for i, s in enumerate(plan["steps"], 1):
        if s.get("scope"):
            print(f"  {i}. {s['name']}  scope: {len(s['scope'])} entries, "
                  f"owned: {len(s.get('_owned') or [])} (all covered)"
                  + ("  [image: the chain rebuilds .delegate/ and re-verifies in the new image]"
                     if s.get("image") else ""))
        else:
            print(f"  {i}. {s['name']}  no scope"
                  + ("  [image: the chain rebuilds .delegate/ and re-verifies in the new image]"
                     if s.get("image") else ""))
        for line in s["verify"].splitlines() or [""]:
            print(f"       verify: {line}")


def scope_violations(tid, n):
    """The paths the scope gate refused in this round's logs, in order ([] if it said nothing).
    An image step's re-verify prints the gate's lines into image-build.log, so both logs are read
    when the round has them."""
    rd = STATE / tid / "rounds" / str(n)
    lines = []
    for name in ("verify.log", "image-build.log"):
        try:
            lines += (rd / name).read_text(errors="replace").splitlines()
        except OSError:
            pass
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


# --------------------------------------------------------------------- image steps ----
# A step with "image": true changes what every later worker runs: it edits the project's own
# image context, .delegate/. Its own round can only verify in the OLD image, so when the round
# ends the chain rebuilds on the host (`delegate build --repo <the step's worktree>`; pin-lint
# first, and a refusal stops the chain — an unpinned add is a source edit away, not a retry
# away) and re-runs the step's verify in the NEW image: that verdict decides the step. The chain
# then PINS that tag (exports DELEGATE_IMAGE, bin/delegate's caller's-image rule) for every later
# call of the chain, so every later step's task records it and cannot land in another image. The
# freshness check itself is untouched: a caller that names its image has chosen its own risk, and
# outside a chain that pins, a tag that does not match the tree still refuses exactly as before.

IMAGE_ENV = "DELEGATE_IMAGE"
IMAGE_BASE_ENV = "DELEGATE_BASE_IMAGE"


def pin_image(plan, st, tag):
    """Pin this chain's later delegate calls to the tag it just built: the caller's-image rule
    (DELEGATE_IMAGE_CALLER, bin/delegate line 32) records it in every later step's meta.env, so
    run/continue/exec/verify and a retry all use it. DELEGATE_BASE_IMAGE goes along: bin/delegate
    would otherwise fix the base AT the caller's image, and a repo tag is never the base."""
    base = sh([DELEGATE, "_base-image"])
    base = base.stdout.strip().splitlines()[0] if base.returncode == 0 and base.stdout.strip() else ""
    if not base:
        note("image step: this binary would not name its base image; the chain pins the tag but "
             "not the base, so a later `delegate build` in this chain may retarget it")
    os.environ[IMAGE_ENV] = tag                       # this process's later calls: retries included
    if base:
        os.environ[IMAGE_BASE_ENV] = base
    st["image_tag"] = tag                             # and a resumed run re-exports both
    st["image_base"] = base or None
    save_state(plan, st)


def image_report(rd, info):
    """The round's report after an image pass: an IMAGE section in report.md, an "image" block in
    report.json, and the step's status rewritten to what the pass decided — `image-refused` on a
    pin-lint refusal, the re-verify's outcome otherwise (done, or done-but-verify-failed even when
    the old image said done: the new image is the environment this step lands in). What the round
    itself said is kept under status_before_image; nothing is rewritten silently."""
    rj = rd / "report.json"
    try:
        rep = json.loads(rj.read_text())
    except (OSError, ValueError):
        rep = {}
    refused = info.get("build_rc", 0) != 0
    final = "image-refused" if refused else ("done" if info.get("reverify_rc") == 0
                                            else "done-but-verify-failed")
    if rep.get("status") != final:
        rep["status_before_image"] = rep.get("status")
        rep["status"] = final
    rep["image"] = {"build": info.get("worktree"), "build_rc": info.get("build_rc"),
                    "pinlint": info.get("pinlint"), "layer_stamp": info.get("stamp"),
                    "tag": info.get("tag"), "reverify_rc": info.get("reverify_rc")}
    try:
        rj.write_text(json.dumps(rep, indent=2))
    except OSError:
        pass
    lines = ["", "## IMAGE", "",
             f"- `delegate build --repo {info.get('worktree')}`: exit {info.get('build_rc')}"
             f" (pinlint: {info.get('pinlint')})"]
    if info.get("stamp"):
        lines.append(f"- new image layer stamp: `{info['stamp']}`")
    if info.get("reverify_rc") is not None:
        lines.append(f"- re-verified in the new image (`delegate verify`): exit "
                     f"{info['reverify_rc']} — step status: {final}")
    if refused:
        lines += ["", "Not accepted: the rebuild was refused, so nothing ran in a new image. Pin "
                  "every add (or carry the reviewed `# delegate: unpinned-ok <why>` line), then "
                  "resume the step.", "", "The build said:"]
        lines += ["    " + ln for ln in (info.get("lines") or [])[-15:]]
    elif info.get("reverify_rc") != 0:
        lines += ["", "The step's verify failed **inside the rebuilt image**: the tail of the build "
                  "and re-verify is in `image-build.log` beside this report."]
    md = rd / "report.md"
    try:
        text = md.read_text(errors="replace") if md.exists() else ""
        if "## IMAGE" not in text:
            with md.open("a") as fh:
                fh.write("\n".join(lines) + "\n")
    except OSError:
        pass


def image_step(plan, s, tid, n, base, here, st):
    """One image step's round ending (the contract): rebuild the project's image from the step's
    tree on the host, pin this chain to the tag that build wrote, re-run the step's verify inside
    it, and record all of it in the round (image-build.log + the report's IMAGE section). Returns
    ("pass" | "fail" | "refused", info).

    The pin, not a loosened freshness rule: `build --repo` names the tag after the tree it built
    (a step's worktree, not the main checkout), so later steps could not find this tag on their
    own, and a chain that exports DELEGATE_IMAGE is a chain that says which image its steps run
    in. It lands in each step's meta.env (IMAGE), so continue/exec/verify reuse it and a later
    step's round cannot drift. The check itself is untouched: outside a chain that pins, an old
    tag for a changed .delegate/ still refuses exactly as today."""
    worktree = task_meta(tid).get("WORKTREE") or plan["repo"]
    rd = STATE / tid / "rounds" / str(n)
    log = [f"$ delegate build --repo {worktree}",
           "delegate chain: an image step: the round ended in the old image; rebuilding on the "
           "host from the step's tree, then re-running the verify inside the new image"]
    r = subprocess.run([DELEGATE, "build", "--repo", worktree], text=True, capture_output=True)
    log += (r.stdout or "").splitlines() + (r.stderr or "").splitlines()
    info = {"worktree": worktree, "build_rc": r.returncode, "stamp": None, "reverify_rc": None}
    if r.returncode:
        info.update({"pinlint": "refused", "lines": log})
        log.append(f"(build exited {r.returncode})")
        rd.mkdir(parents=True, exist_ok=True)
        (rd / "image-build.log").write_text("\n".join(log) + "\n")
        image_report(rd, info)
        return "refused", info
    info["pinlint"] = "clean"
    stamp, tag = "", ""
    rs = sh([DELEGATE, "_layer-stamp", worktree])
    if rs.returncode == 0:
        stamp = rs.stdout.strip()
    rn = sh([DELEGATE, "_image-name", worktree])
    if rn.returncode == 0:
        tag = rn.stdout.strip().splitlines()[0] if rn.stdout.strip() else ""
    if re.fullmatch(r"[0-9a-f]{64}", stamp or "") and tag.startswith("delegate-worker-"):
        pin_image(plan, st, tag)
    else:
        note("image step: the rebuilt image's tag and stamp could not be read back from the "
             "binary; this chain will not pin a later step's image (an old tag then refuses as "
             "it always has)")
    info["stamp"] = stamp or None
    info["tag"] = tag or None
    log += ["", "$ delegate verify " + tid + " '<the step verify>'",
            "delegate chain: re-verifying the step inside the rebuilt image",
            f"pinned to: {tag or '(no tag read back)'}"]
    rv = subprocess.run([DELEGATE, "verify", tid, step_verify(s, None if here else base)],
                        text=True, capture_output=True)
    log += (rv.stdout or "").splitlines() + (rv.stderr or "").splitlines()
    info["reverify_rc"] = rv.returncode
    log.append(f"(re-verify exited {rv.returncode})")
    (rd / "image-build.log").write_text("\n".join(log) + "\n")
    image_report(rd, info)
    return ("pass" if rv.returncode == 0 else "fail"), info


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
    if UNTRUSTED and any(s.get("image") for s in plan.get("steps") or []):
        # Same reason, same place: an image step builds the repo's .delegate/Dockerfile on the
        # host, which is exactly what the untrusted flag exists to keep the repo from doing.
        die('DELEGATE_UNTRUSTED_REPO=1: an "image": true step builds the repository\'s own '
            'Dockerfile on the host; refused', 2)
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
        lint_gate(plan)
        lint_image(plan)
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


def step_verify_retries(plan, s):
    """`--verify-retries` for this step: the step's key wins over the plan's; absent, the flag is
    not passed and `delegate run` resolves it from the environment, then from the default of 1."""
    v = s.get("verify_retries", plan.get("verify_retries"))
    return ["--verify-retries", str(int(v))] if isinstance(v, int) and not isinstance(v, bool) else []


def step_model(plan, s):
    """The model level a step's rounds start on. `"hard": true` is about the gate and the care a
    boundary step gets, not the model: every step starts on the normal model unless the step (or
    the plan) sets `"xhigh": true`. Measured (LLM-Stats 2026-11-effort-medium-vs-xhigh): on hard
    work the xhigh level matched medium on quality and took 25-70% longer."""
    return ["--hard"] if s.get("xhigh", plan.get("xhigh", False)) is True else []


def escalation_left(plan, s, escalated):
    """One last round on the hard model after a normal-model step spends its retries: true when
    this run has not escalated the step yet, the step did not already run on it, the plan allows
    it (`"escalate": false` turns it off), and the hard model is a different model."""
    if escalated or step_model(plan, s) or plan.get("escalate", True) is False:
        return False
    nm, hm = os.environ.get("DELEGATE_MODEL"), os.environ.get("DELEGATE_MODEL_HARD")
    return not (nm and hm and nm == hm)


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
    if st.get("image_tag"):
        # an image step already rebuilt the project's image on this chain: re-export the pin so
        # every delegate call from here on (a resumed run included) runs in that tag.
        os.environ[IMAGE_ENV] = st["image_tag"]
        if st.get("image_base"):
            os.environ[IMAGE_BASE_ENV] = st["image_base"]
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
            # A step the orchestrator finished outside the chain (`delegate continue` after a
            # blocked round) is done now: the chain's record says so too, or readers of the
            # state file (`--status`, dashboards) keep showing the old blocked round.
            rec = st["steps"].setdefault(s["name"], {})
            if rec.get("status") != "done" or rec.get("rounds") != n:
                rec.update({"status": "done", "rounds": n})
                save_state(plan, st)
            if rep.get("new_or_changed_tests_unrun"):
                note(f"{label}: {newtests.summary_line(rep['new_or_changed_tests_unrun'])}")
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
        hard = step_model(plan, s)
        escalated = False
        verify = step_verify(s, None if here else base)
        if n is None:
            note(f"{label}: starting " + ("in place" if here else f"from {base}"))
            r = subprocess.run([DELEGATE, "run", s["_spec"], "--repo", plan["repo"], "--name", s["name"],
                                *([] if here else ["--base", base]), "--verify", verify, *common,
                                *step_access(plan, s), *hard, *step_verify_retries(plan, s)],
                               stdout=subprocess.DEVNULL)
            if r.returncode not in (0,):
                n, rep = last_report(tid)
                if rep is None:
                    die(f"{label}: delegate run failed before producing a report (exit {r.returncode})", 2)
        tries = 0
        while True:
            n, rep = last_report(tid)
            stt = (rep or {}).get("status")
            rec = st["steps"].setdefault(s["name"], {})
            rec.update({"status": stt, "rounds": n})
            save_state(plan, st)
            if s.get("image") and stt in ("done", "done-but-verify-failed") and rec.get("image_round") != n:
                # The round's contract, stated above: its verify passed (or failed) in the OLD
                # image; rebuild on the host from the step's tree and re-run the verify inside the
                # new one. Once per round, whatever it said (the round's commit file is the base
                # the next step branches from, so this pass decides the round that produced it).
                rec["image_round"] = n
                note(f"{label}: image step — rebuilding on the host from the step's tree")
                verdict, info = image_step(plan, s, tid, n, base, here, st)
                if verdict == "refused":
                    rec["status"] = "image-refused"
                    save_state(plan, st)
                    print_status(plan)
                    die(f"{label}: the rebuild was REFUSED (pin-lint): the .delegate/Dockerfile is "
                        f"not fully pinned, and the chain does not run on an image it refused. "
                        f"`delegate report {tid}` names the lines; fix them (delegate continue "
                        f"{tid} -m \"pin it\"), then re-run the chain.", 3)
                n, rep = last_report(tid)                       # the report now says what the pass decided
                stt = (rep or {}).get("status")
                rec.update({"status": stt, "image_verdict": verdict})
                save_state(plan, st)
                if verdict == "pass":
                    note(f"{label}: accepted in the rebuilt image")
            if (rep or {}).get("new_or_changed_tests_unrun"):
                # the round added or changed test files its verify never ran: the same warning
                # line the report shows (a warning only — it moves no status, no acceptance, no
                # exit code)
                note(f"{label}: {newtests.summary_line(rep['new_or_changed_tests_unrun'])}")
            if stt == "done" and not s.get("image"):
                # A step without the key that touched .delegate/ is refused AT ACCEPTANCE, like any
                # out-of-scope file: its round changed the build context every later worker runs
                # from, and no rebuild happened for it. Best-effort: a chain whose delegate binary
                # has no _round-diff, or a round with no commit file, is not refused on a guess.
                bad = touched_image_dir(round_files(tid, n))
                if bad:
                    print_status(plan)
                    die(f"{label}: its round changed {', '.join(bad)} — .delegate/ is the "
                        f"project's worker-image build context, and a step without \"image\": "
                        f"true cannot rebuild it: give the step the key in {plan['_path']} "
                        f"(which requires \"hard\": true), or send feedback to revert the path. "
                        f"Nothing was branched from this round.", 3)
            if stt == "done":
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
            escalate = False
            if tries >= retries:
                if not escalation_left(plan, s, escalated):
                    print_status(plan)
                    die(f"{label} still '{stt}' after {tries} retr{'y' if tries == 1 else 'ies'}"
                        f"{' and one round on the hard model' if escalated else ''}: "
                        f"`delegate report {tid}`. Fix the spec or send feedback, then re-run the chain.", 3)
                escalated = escalate = True
                rec["escalated_round"] = n + 1
                save_state(plan, st)
                note(f"{label}: {stt} after {tries} retr{'y' if tries == 1 else 'ies'} — one last "
                     f"round on the hard model, in the same session")
            else:
                tries += 1
                note(f"{label}: {stt} — retry {tries}/{retries} in the same session")
            msg_file = STATE / tid / "chain-retry.md"
            # an image step whose RE-verify failed gets that tail, not the old image's verify.log
            log = "image-build.log" if rec.get("image_verdict") == "fail" else "verify.log"
            msg_file.write_text(retry_message(rep or {}, tid, n, scope_paths, log))
            # the plan's verify, not the one the task was started with: an edited plan takes effect
            subprocess.run([DELEGATE, "continue", tid, str(msg_file),
                            "--verify", step_verify(s, None if here else base),
                            *step_verify_retries(plan, s), *(["--hard"] if escalate else hard)],
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
            "orchestrator": harness, "orchestrator_session": session,
            "launch_sha256": mark.get("launch")})
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
        mark = {"written": False, "started": time.time(), "launch": launch.launch_sha256()}
        # every step's rounds carry this run's launch, not their own (bin/delegate launch_hash):
        # set even when empty, so a step never fingerprints the chain process as its launcher
        os.environ["DELEGATE_LAUNCH_SHA256"] = mark["launch"] or ""
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
