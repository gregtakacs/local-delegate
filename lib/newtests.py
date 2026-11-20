#!/usr/bin/env python3
"""The new-tests check: a round's report warns when its verify never ran a test file the
round ADDED OR CHANGED.

The measured misses: a round added hub/tests/test_wv43_page.py, the orchestrator's verify ran
other modules only, the harness said "verify exit 0", the round was accepted — and the full
gate later showed errors in exactly that new file. Same day, the second shape: a new test
method inside an existing module (hub/tests/test_c1a1_browser.py) whose module the verify never
ran. Nothing in the report said those tests had never run.
`uncovered(added_paths, verify_cmd, verify_log)` answers which of a round's added-or-changed
test files neither its verify command nor its verify log names or covers.

A path counts as a TEST FILE when its file name has one of the shapes repos use:
`test_*.py`, `*_test.py`, `*_test.go`, `tests/test_*.sh` (or `test/test_*.sh`),
`*.test.{js,ts,mjs}`, `*.spec.{js,ts}` — a file under `test/` or `tests/` with one of those
shapes counts too.

A test file is COVERED when the verify command or the verify log holds any of:
  - its repo path, its dotted module (`hub/tests/test_x.py` -> `hub.tests.test_x`) or its
    file name;
  - a token that is a path prefix of it (`hub/`, `hub/tests`, `./hub/tests/`) or a dotted
    package prefix of it (`hub`, `hub.tests`);
  - (Go) `./...` in a command run from an ancestor directory of the file — the last relative
    `cd` before it names that directory; an absolute `cd`, or no `cd`, is the repo root;
  - a test runner invoked with no file or module argument at all — bare `pytest`,
    `python3 tools/run_tests.py`, `npm test`, `go test ./...`, `make check` — which runs
    everything.

The check is a warning channel: it changes no status and no exit code.

  newtests.py uncovered --added-or-changed FILE --verify-cmd CMD [--verify-log FILE]
        print the test paths the verify never ran, one per line. A or AM is the caller's diff,
        not this rule's: the answer depends on a path's shape and on the verify text alone.
"""
import argparse
import re
import sys

# Test-file shapes, matched on the file name (the last path segment).
_BASE_SHAPES = (
    re.compile(r"test_[^/]+\.py$"),
    re.compile(r"[^/]+_test\.py$"),
    re.compile(r"[^/]+_test\.go$"),
    re.compile(r"[^/]+\.test\.(?:js|ts|mjs)$"),
    re.compile(r"[^/]+\.spec\.(?:js|ts)$"),
)
# `test_*.sh` is a test shape only under a test/ or tests/ directory (a repo's scripts/ may
# hold deployment helpers of the same name).
_SHAPE_SH = re.compile(r"test_[^/]+\.sh$")

# A verify token: anything that can be a word of a command line or of its log.
_TOKEN = re.compile(r"[\w.+=/@:-]+")

# Shell segment boundaries: a verify is often several commands.
_SEGMENTS = re.compile(r"[\r\n;|&]+|\bthen\b|\bdo\b")

# Quoted command strings: a runner inside quotes runs everything the same way.
_QUOTED = re.compile(r"'([^'\n]*)'|\"([^\"\n]*)\"")


def _norm(path):
    """A repo-relative path spelled the way this module compares them: no leading ./ or /."""
    p = str(path).strip().lstrip("/")
    while p.startswith("./"):
        p = p[2:]
    return p


def is_test_file(path):
    """True when the added path has the shape of a test file (see the module docstring)."""
    p = _norm(path)
    if not p:
        return False
    base = p.rsplit("/", 1)[-1]
    if any(rx.search(base) for rx in _BASE_SHAPES):
        return True
    if _SHAPE_SH.search(base) and any(seg in ("test", "tests") for seg in p.split("/")[:-1]):
        return True
    return False


def _dir_prefix_hit(path, tokens, run_dir_counts=False):
    """A token that is a path prefix (`hub/`, `hub/tests`, `./hub/tests/`) or a dotted package
    prefix (`hub.tests`) of the file's directory: the verify points at a directory the file
    sits in, which for every runner in the rules means it collects the file. The bare `.`
    (run from here) counts only in the command, never in the log: a pytest progress line is
    built from dots, and it is the command that must say the file ran."""
    p = _norm(path)
    for t in tokens:
        t = _norm(t).rstrip("/")
        if not t or t == p:
            continue
        if t == ".":
            if run_dir_counts:
                return True                # `pytest .`: the run dir is the verify's own root
            continue
        if p.startswith(t + "/"):
            return True
        if "." in t and "/" not in t:
            d = t.replace(".", "/")
            if p.startswith(d + "/"):
                return True
    return False


def _go_wildcard_covers(path, text):
    """Go's `./...`: the pattern walks every package at or below the run directory. The run
    directory is the target of the last `cd` before the first `./...` mention — a relative one
    is inside the repo, an absolute one or none is taken as the repo root (the verify starts
    there), so the pattern reaches the file's package."""
    idx = text.find("./...")
    if idx < 0:
        return False
    m = None
    for m in re.finditer(r"(?:^|[\s;&|(])cd\s+([^\s;&|)]+)", text[:idx]):
        pass
    run = "." if m is None else m.group(1)
    if run.startswith("/") or run.startswith("$") or run == "~":
        return True                        # cannot anchor an absolute dir on the repo: give cover
    run = _norm(run).rstrip("/") or "."
    if run == ".":
        return True                        # from the repo root ./... reaches every package
    return _norm(path).startswith(run + "/")


# Bare runners: a runner named with no file/module argument runs everything, so nothing is
# "unrun". Deliberately a small known set: an unknown script with positional-looking words is
# NOT assumed to run all.
_PY_RUNNERS = ("pytest", "py.test")
_JS_TESTERS = ("npm", "pnpm", "yarn", "bun")
_MAKE_TARGETS = ("test", "tests", "check", "checks")
_BARE_TOOLS = ("jest", "vitest", "mocha")


def _segment_covers_everything(seg):
    toks = seg.split()
    i = 0
    while i < len(toks) and re.fullmatch(r"\w+=\S*", toks[i]):      # leading env assignments
        i += 1
    while i < len(toks) and toks[i] in ("command", "time", "nice", "sudo", "env"):
        i += 1
    if i < len(toks) and toks[i] == "timeout":
        i += 2 if i + 1 < len(toks) and re.fullmatch(r"[\d.]+[smhd]?", toks[i + 1]) else 1
    if i >= len(toks):
        return False
    prog = toks[i].rsplit("/", 1)[-1]
    rest = toks[i + 1:]
    pos = [t for t in rest if not t.startswith("-")]                # flags never name a test

    if prog in _PY_RUNNERS:
        return not pos
    if prog == "python3" or prog == "python" or re.fullmatch(r"python3\.\d+", prog):
        if rest[:1] == ["-m"]:
            return pos[:1] in (["pytest"], ["unittest"]) and len(pos) == 1
        if len(pos) == 1:                                         # python3 [-I] tools/run_tests.py
            script = pos[0].rsplit("/", 1)[-1]
            if re.search(r"(^|[._-])tests?([._-]|$)", script):
                return True
        return False
    if prog in _JS_TESTERS:
        j = 1 if rest[:1] == ["run"] else 0
        if rest[j:j + 1] == ["test"]:
            tail = rest[j + 1:]
            return not [t for t in tail if not t.startswith("-") or t == "--"]
        return False
    if prog in _BARE_TOOLS:
        return not pos
    if prog == "cargo" and rest[:1] == ["test"]:
        return not [t for t in rest[1:] if not t.startswith("-")]
    if prog == "make" and pos and pos[0] in _MAKE_TARGETS:
        return not pos[1:]
    return False


def _bare_runner(text):
    """Any segment of this command/log is a runner invoked with no file/module argument. A
    quoted segment (`bash -c 'pytest -q'`) is its own candidate too: the quotes hide the
    runner from the outer split, and its words run everything just the same."""
    segs = _SEGMENTS.split(text)
    segs += [a or b for a, b in _QUOTED.findall(text)]
    return any(_segment_covers_everything(seg) for seg in segs if seg.strip())


def uncovered(added_paths, verify_cmd, verify_log):
    """The paths that are test files and that neither the verify command nor the verify log
    runs or covers (rules in the module docstring), in the order given, without repeats.
    `added_paths` is the round's added-or-changed list (bin/delegate's `diff-filter=AM` diff);
    the check is about a path's shape and whether the verify reached it, not how it changed."""
    text = (verify_cmd or "") + "\n" + (verify_log or "")
    tok_cmd = _TOKEN.findall(verify_cmd or "")
    tok_log = _TOKEN.findall(verify_log or "")
    out = []
    for path in added_paths or []:
        p = _norm(path)
        if not p or p in out or not is_test_file(p):
            continue
        dotted = p[:-3].replace("/", ".") if p.endswith(".py") else ""
        base = p.rsplit("/", 1)[-1]
        if (p in text or (dotted and dotted in text) or base in text
                or _dir_prefix_hit(p, tok_cmd, run_dir_counts=True)
                or _dir_prefix_hit(p, tok_log)
                or (p.endswith(".go") and _go_wildcard_covers(p, text))
                or _bare_runner(text)):
            continue
        out.append(p)
    return out


def summary_line(paths):
    """The one line every surface shows for an uncovered round (report.md, its printed summary,
    the chain's note for the step): same words, same order, same em dash."""
    return "TESTS NOT IN VERIFY (added or changed): " + ", ".join(paths) + " — the verify never ran them"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["uncovered"])
    ap.add_argument("--added-or-changed", default="",
                    help="file with one added-or-changed path per line")
    ap.add_argument("--verify-cmd", default="")
    ap.add_argument("--verify-log", default="", help="file; - reads stdin")
    a = ap.parse_args()
    try:
        added = sys.stdin.read().splitlines() if a.added_or_changed == "-" \
            else open(a.added_or_changed, encoding="utf-8", errors="replace").read().splitlines()
    except FileNotFoundError:
        added = []
    try:
        log = sys.stdin.read() if a.verify_log == "-" \
            else (open(a.verify_log, encoding="utf-8", errors="replace").read() if a.verify_log else "")
    except FileNotFoundError:
        log = ""
    for p in uncovered(added, a.verify_cmd, log):
        print(p)


if __name__ == "__main__":
    main()

