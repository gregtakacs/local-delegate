#!/usr/bin/env python3
"""translate-permissions.py — the one permission policy -> per-harness renderings.

Reads policy/harness-permissions.json (design §7.1) and emits, for a given --render target:

  opencode : ordered pattern maps (the opencode `permission` object). File order is the
             semantics (opencode evaluates in order, last match wins); "*" is first per
             section; `deny` rows are emitted in BOTH the canonical (relative) spelling and
             an absolute one (from --home ~-expansion), per the render-opencode-config.py:48
             edit_denies finding.
  claude   : {"permissions": {"allow": [...], "ask": [...], "deny": [...]}} plus the
             allow_exceptions the PermissionRequest hook must answer (§7.2 exception rule).
  guard    : {"version": N, "allow_exceptions": [...], "deny": [...]} for step 4's hook
             (deny rows duplicated as a backstop).

Refusals (exit 1, nothing written): an `allow` that beats an earlier rendered (non-catch-all)
`ask`/`deny` without `via: "hook"`; a rendering that drops any policy `deny` row (§10 guard);
unknown effect strings; a `deny`/`ask` carrying `via`; an empty section in a non-empty policy;
an `over` naming a rule that is not earlier in its section.

Usage:
  translate-permissions.py --policy PATH --render opencode|claude|guard [--out -]
                           [--home HOME] [--check]
"""
import argparse
import json
import os
import sys
from collections import OrderedDict

EFFECTS = ("allow", "ask", "deny")
SECTIONS = ("bash", "read", "edit", "external_directory", "webfetch", "skill", "doom_loop")

# --- Claude Code permission-rule pattern form (spike S4, design §6.1, 2026-11-15) -------------
# One block so the whole form is a single reviewed edit if a later S4 re-run surprises.
# S4 recorded: deny > ask > allow; a `Bash(cmd *)` space form matches `cmd tail` (a trailing
# argument) but NOT the bare `cmd`, so deny patterns use a trailing `*` (no space) to also match
# the bare command; Read/Edit path globs use `**`; `WebFetch` needs no argument for a blanket
# rule. Subcommand splitting of `&&`/`||`/`;`/`$()`/backticks is done in permission-eval.py.
CLAUDE_TOOL = {"bash": "Bash", "read": "Read", "edit": "Edit",
               "external_directory": ("Read", "Edit"), "webfetch": None}
CLAUDE_BLANKET_WEBFETCH = "WebFetch"


def die(msg):
    print("translate-permissions: " + msg, file=sys.stderr)
    return 1


def load_policy(path):
    with open(path) as f:
        return json.load(f, object_pairs_hook=OrderedDict)


def sections(policy):
    return [(k, policy[k]) for k in SECTIONS if k in policy]


def abs_spelling(pattern, home):
    """The absolute spelling of a `**/X` deny pattern: {home}/X (None if not deep-rooted)."""
    if pattern.startswith("**/"):
        return home.rstrip("/") + "/" + pattern[3:]
    return None


def opencode_patterns(rule, home):
    """Every opencode key a rule must appear under. Deny rows get relative + absolute spellings."""
    pats = [rule["pattern"]]
    if rule["effect"] == "deny":
        a = abs_spelling(rule["pattern"], home)
        if a:
            pats.append(a)
    return pats


def claude_entries(tool, pattern, effect, home):
    """Claude static-array strings for one policy rule (may be empty for blanket webfetch)."""
    tools = CLAUDE_TOOL.get(tool)
    if tools is None:                       # webfetch: blanket, no argument
        return [CLAUDE_BLANKET_WEBFETCH]
    names = [tools] if isinstance(tools, str) else list(tools)
    out = []
    for name in names:
        out.append("%s(%s)" % (name, pattern))
        if effect == "deny":
            a = abs_spelling(pattern, home)
            if a:
                out.append("%s(%s)" % (name, a))
    return out


def validate(policy, home):
    """Return a list of refusal messages (empty when the policy renders cleanly)."""
    errs = []
    if not isinstance(policy.get("version"), int):
        errs.append("missing/invalid 'version'")
    present = sections(policy)
    if not present:
        errs.append("no rule sections in policy")
    total = sum(len(rules) for _, rules in present if isinstance(rules, list))
    for tool, rules in present:
        if not isinstance(rules, list):
            errs.append("%s: not a rule list" % tool)
            continue
        if not rules:
            if total:
                errs.append("%s: empty section in a non-empty policy" % tool)
            continue
        if rules[0].get("pattern") != "*":
            errs.append("%s: first rule pattern must be \"*\" (opencode's default-first posture)" % tool)
        if tool == "bash" and rules[0].get("effect") != "ask":
            errs.append("bash: default posture (first rule) must be ask")
        for i, r in enumerate(rules):
            eff = r.get("effect")
            if eff not in EFFECTS:
                errs.append("%s[%d]: unknown effect %r" % (tool, i, eff))
                continue
            if "via" in r and eff != "allow":
                errs.append("%s[%d]: 'via' is only meaningful on an allow" % (tool, i))
            for t in r.get("over", []):
                if not any(rules[j].get("pattern") == t for j in range(i)):
                    errs.append("%s[%d]: over target %r is not an earlier rule in the section" % (tool, i, t))
            if eff == "allow":
                # this allow is later, so opencode lets it win over every earlier rule; under
                # Claude's deny>ask>allow an allow that beats a *rendered* ask/deny is lost.
                beaten = [rules[j] for j in range(i)
                          if rules[j].get("effect") in ("ask", "deny")
                          and rules[j].get("pattern") != "*"]
                if beaten and r.get("via") != "hook":
                    errs.append("%s[%d]: allow beats earlier rendered ask/deny (%s) without via:hook"
                                % (tool, i, ", ".join(b["pattern"] for b in beaten)))
    return errs


def render_opencode(policy, home):
    out = OrderedDict()
    for tool, rules in sections(policy):
        m = OrderedDict()
        for r in rules:
            for p in opencode_patterns(r, home):
                m[p] = r["effect"]
        out[tool] = m
    return out


def render_claude(policy, home):
    allow, ask, deny, exceptions = [], [], [], []

    def add(bucket, s):
        if s not in bucket:
            bucket.append(s)

    for tool, rules in sections(policy):
        for r in rules:
            eff, p = r["effect"], r["pattern"]
            if eff == "allow" and r.get("via") == "hook":
                if tool == "bash":
                    add(exceptions, p)
                continue                       # a hook exception never enters a static array
            if p == "*":
                continue                       # catch-all default lives in the engine, not an array
            for s in claude_entries(tool, p, eff, home):
                add({"allow": allow, "ask": ask, "deny": deny}[eff], s)
    return OrderedDict([
        ("permissions", OrderedDict([("allow", allow), ("ask", ask), ("deny", deny)])),
        ("allow_exceptions", exceptions),
    ])


def render_guard(policy, home):
    exceptions, deny = [], []

    def add(seq, s):
        if s not in seq:
            seq.append(s)

    for tool, rules in sections(policy):
        for r in rules:
            if r["effect"] == "allow" and r.get("via") == "hook":
                add(exceptions, r["pattern"])
            elif r["effect"] == "deny":
                add(deny, r["pattern"])
    return OrderedDict([("version", policy["version"]),
                        ("allow_exceptions", exceptions),
                        ("deny", deny)])


def deny_survival(policy, oc, cl, home):
    """Design §10 guard: neither rendering may silently drop a policy deny row."""
    errs = []
    for tool, rules in sections(policy):
        for r in rules:
            if r["effect"] != "deny":
                continue
            keys = {r["pattern"]}
            a = abs_spelling(r["pattern"], home)
            if a:
                keys.add(a)
            if not (keys & set(oc.get(tool, {}))):
                errs.append("opencode rendering drops deny %s/%s" % (tool, r["pattern"]))
            if not any(s in cl["permissions"]["deny"]
                       for s in claude_entries(tool, r["pattern"], "deny", home)):
                errs.append("claude rendering drops deny %s/%s" % (tool, r["pattern"]))
    return errs


def emit(doc, out):
    text = json.dumps(doc, indent=2) + "\n"
    if out == "-":
        sys.stdout.write(text)
    else:
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        with open(out, "w") as f:
            f.write(text)


def main(argv):
    ap = argparse.ArgumentParser(prog="translate-permissions")
    ap.add_argument("--policy", required=True)
    ap.add_argument("--render", required=True, choices=["opencode", "claude", "guard"])
    ap.add_argument("--out", default="-")
    ap.add_argument("--home", default=os.path.expanduser("~"))
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)

    try:
        policy = load_policy(a.policy)
    except (ValueError, OSError) as e:
        return die("cannot read policy %s (%s)" % (a.policy, e))

    errs = validate(policy, a.home)
    if errs:
        return die("; ".join(errs))

    oc = render_opencode(policy, a.home)
    cl = render_claude(policy, a.home)
    gd = render_guard(policy, a.home)
    errs = deny_survival(policy, oc, cl, a.home)
    if errs:
        return die("; ".join(errs))

    if a.check:                       # validated + denies survive; write nothing
        return 0
    emit({"opencode": oc, "claude": cl, "guard": gd}[a.render], a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
