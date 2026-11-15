#!/usr/bin/env python3
"""permission-eval.py — evaluate a permission case under one harness's rendered rules.

The shared-verdict test (design §7.3): the same case run through BOTH engines must yield the
same verdict, equal to the case's `expect`. Neither harness is invoked; this reimplements each
harness's documented decision procedure over a rendered config produced by
translate-permissions.py.

  --engine opencode : last-match-wins over the ordered pattern map, using the wildcard
                      semantics imported from lib/merge-opencode-permissions.py (shared
                      glob_re; that script's CLI is unchanged). Whole command string, NO
                      subcommand splitting (that is why its default rule is "*": ask).
  --engine claude   : deny > ask > allow over the rendered arrays, with Bash subcommand
                      splitting (see split_bash). allow_exceptions (the §7.2 hook exceptions)
                      are applied at the hook's precedence (they beat a rendered ask, never a
                      deny). An unparseable / unmatched command falls to the per-tool default,
                      never an upgrade.

Usage:
  permission-eval.py --engine {opencode,claude} --config PATH|[-] [--cases FILE] [--case JSON]
    --config - reads the rendered config from stdin; --case - reads a single case from stdin.
  permission-eval.py --engine both --policy PATH [--cases FILE] [--home HOME]
    Renders BOTH engines from the policy (one process, the doctor's cross-harness check) and
    prints one line per case `verdict <v> (expect <e>) ok|DRIFT opencode=<v> claude=<v>`; exit 1
    if either engine disagrees with the case's expect.
Prints one line `verdict <allow|ask|deny>` per evaluated case, in order.
"""
import importlib.util
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "merge_opencode_permissions", os.path.join(_HERE, "merge-opencode-permissions.py"))
_merge = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_merge)
_spec2 = importlib.util.spec_from_file_location(
    "translate_permissions", os.path.join(_HERE, "translate-permissions.py"))
_tp = importlib.util.module_from_spec(_spec2)
_spec2.loader.exec_module(_tp)
glob_re = _merge.glob_re   # shared wildcard semantics with the merge script (don't fork them)

# Per-tool verdict when NO rule matches an input — mirrors the opencode catch-all "*" rule that
# translate-permissions.py deliberately does not render into the Claude static arrays, so both
# engines start from the same default posture. (design §7.1/§7.2)
TOOL_DEFAULT = {"bash": "ask", "read": "allow", "edit": "allow",
                "external_directory": "ask", "webfetch": "ask",
                "skill": "allow", "doom_loop": "allow"}
STRICTNESS = {"allow": 0, "ask": 1, "deny": 2}
# Tool names a case's tool is allowed to be matched by in the Claude arrays. external_directory
# has no Claude same-tool, so it is served path-scoped by Read/Edit (closest-mapping, §7.2).
CLAUDE_TOOLS = {"bash": {"Bash"}, "read": {"Read"}, "edit": {"Edit"},
                "webfetch": {"WebFetch"}, "external_directory": {"Read", "Edit"}}


def split_bash(cmd):
    """Split one bash command line into separately-permissioned subcommands.

    One function on purpose. Rules come from the Claude Code hooks reference `if`
    permission-rule table (see claude/spikes/probe-s4-permissions-syntax.sh and
    docs/specs/o1b-1-hook-spike.md §Read first): commands chained with `&&`, `||` or `;` are
    evaluated per subcommand, and a command nested in `$( … )` or backticks is evaluated as a
    subcommand too (the S4 finding: a deny anywhere in a compound denies the whole line). The
    overall verdict is the STRICTEST any subcommand reaches (deny > ask > allow) — never an
    upgrade. Returns a list (possibly one element); an empty element is dropped.
    """
    parts, cur, i, n = [], [], 0, len(cmd)
    while i < n:
        two = cmd[i:i + 2]
        if two in ("&&", "||"):
            parts.append("".join(cur)); cur = []; i += 2; continue
        if cmd[i] == ";":
            parts.append("".join(cur)); cur = []; i += 1; continue
        if two == "$(":
            depth, j = 1, i + 2
            while j < n and depth:
                if cmd[j:j + 2] == "$(":
                    depth += 1; j += 2; continue
                if cmd[j] == "(":
                    depth += 1
                elif cmd[j] == ")":
                    depth -= 1
                j += 1
            parts.append(cmd[i + 2:j - 1])           # the nested command is a subcommand
            cur.append(" "); i = j; continue
        if cmd[i] == "`":
            j = cmd.find("`", i + 1)
            if j == -1:
                j = n
            parts.append(cmd[i + 1:j])
            cur.append(" "); i = j + 1; continue
        cur.append(cmd[i]); i += 1
    parts.append("".join(cur))
    return [p.strip() for p in parts if p.strip()]


def _match(entry, sub):
    """Does one Claude rule string match a subcommand/path? `WebFetch` is blanket."""
    if entry == "WebFetch":
        return True
    if not (entry.endswith(")") and "(" in entry):
        return False
    _, _, inner = entry.partition("(")
    return bool(glob_re(inner[:-1]).match(sub))


def _entry_tool(entry):
    if entry == "WebFetch":
        return "WebFetch"
    return entry.split("(", 1)[0] if "(" in entry else None


def _relevant(entries, tool):
    accept = CLAUDE_TOOLS.get(tool, set())
    return [e for e in entries if _entry_tool(e) in accept]


def claude_verdict(cfg, tool, inp):
    perms = cfg.get("permissions", {})
    deny = _relevant(perms.get("deny", []), tool)
    ask = _relevant(perms.get("ask", []), tool)
    allow = _relevant(perms.get("allow", []), tool)
    exceptions = cfg.get("allow_exceptions", []) if tool == "bash" else []
    subs = split_bash(inp) if tool == "bash" else [inp]
    verdicts = []
    for sub in subs:
        if any(_match(e, sub) for e in deny):
            verdicts.append("deny"); continue
        if any(_match("Bash(" + x + ")", sub) for x in exceptions):
            verdicts.append("allow"); continue
        if any(_match(e, sub) for e in ask):
            verdicts.append("ask"); continue
        if any(_match(e, sub) for e in allow):
            verdicts.append("allow"); continue
        verdicts.append(TOOL_DEFAULT.get(tool, "ask"))
    return max(verdicts, key=lambda v: STRICTNESS[v])


def opencode_verdict(cfg, tool, inp):
    rules = cfg.get(tool, {})
    decision = None
    for key, value in rules.items():            # insertion order; opencode: last match wins
        if glob_re(key).match(inp):
            decision = value
    return decision if decision is not None else TOOL_DEFAULT.get(tool, "ask")


def evaluate(engine, cfg, tool, inp):
    return claude_verdict(cfg, tool, inp) if engine == "claude" else opencode_verdict(cfg, tool, inp)


def parse(argv):
    opts = {"engine": None, "config": "-", "cases": None, "case": None,
            "policy": None, "home": os.path.expanduser("~")}
    argv = list(argv)
    while argv:
        a = argv.pop(0)
        if a == "--engine":
            opts["engine"] = argv.pop(0)
        elif a == "--config":
            opts["config"] = argv.pop(0)
        elif a == "--cases":
            opts["cases"] = argv.pop(0)
        elif a == "--case":
            opts["case"] = argv.pop(0)
        elif a == "--policy":
            opts["policy"] = argv.pop(0)
        elif a == "--home":
            opts["home"] = argv.pop(0)
        else:
            sys.exit("permission-eval: unknown option " + a)
    if opts["engine"] not in ("opencode", "claude", "both"):
        sys.exit("permission-eval: --engine must be opencode, claude or both")
    if opts["engine"] == "both" and not opts["policy"]:
        sys.exit("permission-eval: --engine both needs --policy")
    return opts


def _read(path):
    return sys.stdin.read() if path == "-" else open(path).read()


def _cases_from(text):
    doc = json.loads(text)
    return doc["cases"] if isinstance(doc, dict) and "cases" in doc else [doc] if isinstance(doc, dict) else doc


def main(argv):
    o = parse(argv)
    if o["engine"] == "both":
        try:
            policy = _tp.load_policy(o["policy"])
            errs = _tp.validate(policy, o["home"])
            if errs:
                sys.exit("permission-eval: policy invalid: " + "; ".join(errs))
            oc = _tp.render_opencode(policy, o["home"])
            cl = _tp.render_claude(policy, o["home"])
        except (ValueError, OSError) as e:
            sys.exit("permission-eval: cannot render policy (%s)" % e)
        cases = _cases_from(_read(o["cases"])) if o["cases"] else _cases_from(_read("-"))
        bad = 0
        for c in cases:
            vo, vc = evaluate("opencode", oc, c["tool"], c["input"]), \
                     evaluate("claude", cl, c["tool"], c["input"])
            ok = vo == c["expect"] and vc == c["expect"]
            bad += 0 if ok else 1
            print("%s opencode=%s claude=%s expect=%s | %s"
                  % ("ok" if ok else "DRIFT", vo, vc, c["expect"], c["input"]))
        return 1 if bad else 0
    cfg = json.loads(_read(o["config"]))
    if o["case"] is not None:                    # a single case, inline JSON string
        cases = [json.loads(o["case"])]
    elif o["cases"] is not None:                 # a case-list file
        cases = _cases_from(_read(o["cases"]))
    else:                                        # case list on stdin
        cases = _cases_from(_read("-"))
    for c in cases:
        print("verdict " + evaluate(o["engine"], cfg, c["tool"], c["input"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
