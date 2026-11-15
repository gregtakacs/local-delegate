#!/usr/bin/env python3
"""permission-guard.py — the PermissionRequest hook's decision core (O1b step 4, design §7.5).

FIDELITY / SCOPE: this is SECURITY CODE. It implements ONLY the static exception + hard-limit
logic of design §7.2; the LLM judge (docs/permission-judge.md) is a later, unbuilt slice, so this
guard never invents an allow — it can answer `allow` for a policy `via: hook` exception and is
otherwise silent (exit 0, no decision: the human or Claude's classifier answers, exactly like
the judge's "can only remove prompts" property, permission-judge.md §5).

At event time it renders the guard view of the install tree's policy IN PROCESS (import
lib/translate-permissions.py, call render_guard; no CLI subprocess, no artefact written, the
install tree stays read-only) — so the guard always agrees with whatever policy this install
shipped, and a policy edit takes effect without a re-render step.

Decision order (a deny or a §3 hard limit always beats an exception):
  1. §3 hard-limit pattern (docs/permission-judge.md §3) on the command/path -> silent. The guard
     NEVER allows these, whatever the policy says ("tested" in the spec; the list is in code,
     "not configurable down", permission-judge.md §3).
  2. deny row re-checked from the rendered guard list (defense-in-depth: a deny the settings
     already carry is confirmed here, never contradicted).
  3. an allow_exception glob that covers the command (EVERY subcommand of a compound, per spike
     S4: a deny/undetermined anywhere denies the whole) -> the single allow decision.
  4. anything else -> silent, exit 0.

Fail-to-human (spec §4): the policy absent/unreadable/unrenderable, or the deny list present but
unreadable, is silent no-decision. Silence is the safe answer; the guard can only ever ADD an
allow, and only for a command the policy explicitly marked `via: hook`.
"""
import importlib.util
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_INSTALL_ROOT = os.path.dirname(os.path.dirname(_HERE))  # <root>/claude/hooks/x.py -> <root>


def _load(mod_name, filename):
    spec = importlib.util.spec_from_file_location(mod_name, os.path.join(_INSTALL_ROOT, "lib", filename))
    if spec is None or spec.loader is None:
        return None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# --- §3 hard limits (docs/permission-judge.md §3), matched per subcommand/path. These live in
# code and are never widened by the policy file. Word-boundary anchored so `sudo` matches at the
# start of the command or after a chain/pipe/subshell separator, and `pkill`/`kill` match as
# commands, not substrings of harmless words.
_HARD_BASH = [
    r"\b(sudo|doas)\b",
    r"\bsu\s",
    r"\bgit\s+push\b",
    r"\bgit\s+reset\s+--hard\b",
    r"\bgit\s+rebase\b",
    r"\bgit\s+branch\s+(-D|-f)\b",
    r"\bgit\s+clean\b",
    r"\bgit\s+(checkout|restore)\b\s+(-{1,2}f|(--|\.)\b)",
    r"\bfilter-(branch|repo)\b",
    r"\brm\s+(-[a-z]*r[a-z]*f|-rf|-fr)\b",
    r"\bdocker\s+compose\s+down\b",
    r"\bdocker\s+rm\b",
    r"\bdocker\s+volume\s+rm\b",
    r"\bsystemctl\s+(start|stop|restart|enable|disable)\b",
    r"\b(pkill|killall|kill)\b",
    r"\b(pip|npm|yarn|pnpm|apt|apt-get)\b",
    r"\b(npm|pnpm|yarn)\s+(-g|--global)\b",
    r"\|\s*(ba|z)?sh\b",
]
_HARD_ANY = [r"\bdocker/secrets\b", r"\.env\b", r"\.pem\b", r"\.key\b", r"\bid_\w+\b",
             r"token", r"credential", r"secret"]
_HARD_BASH_RE = [re.compile(p, re.I) for p in _HARD_BASH]
_HARD_ANY_RE = [re.compile(p, re.I) for p in _HARD_ANY]


def _command_of(event):
    """The permissioned string for this request: the Bash command, else a path, else a URL."""
    ti = event.get("tool_input") or {}
    if not isinstance(ti, dict):
        return None, ""
    tool = (event.get("tool_name") or "")
    if tool == "Bash":
        return "bash", str(ti.get("command") or "")
    if tool in ("Read", "Edit", "Write", "NotebookEdit", "MultiEdit"):
        for k in ("file_path", "path", "filePath", "notebook_path", "file"):
            if ti.get(k):
                return ("read" if tool == "Read" else "edit"), str(ti[k])
        return "edit", ""
    if tool == "WebFetch":
        return "webfetch", str(ti.get("url") or "")
    return "", ""


def _subs(kind, text, ev):
    if kind == "bash" and ev is not None:
        return ev.split_bash(text) or [text]
    return [text]


def _hard_limited(kind, text):
    """True if any §3 hard limit matches this command (per subcommand) or path."""
    if not text:
        return False
    ev = _load("permission_eval", "permission-eval.py")
    for sub in _subs(kind, text, ev):
        for rx in _HARD_ANY_RE:
            if rx.search(sub):
                return True
        if kind == "bash":
            for rx in _HARD_BASH_RE:
                if rx.search(sub):
                    return True
    return False


def _guard_view():
    """Render {allow_exceptions, deny} from the install tree's policy, in process. None on failure."""
    try:
        tr = _load("translate_permissions", "translate-permissions.py")
        if tr is None:
            return None
        policy_path = os.path.join(_INSTALL_ROOT, "policy", "harness-permissions.json")
        if not os.path.isfile(policy_path):
            return None  # permissions opted out (Q2): guard module inert
        policy = tr.load_policy(policy_path)
        if tr.validate(policy, os.path.expanduser("~")):
            return None  # a policy that will not render is a no-decision, never a guess
        return tr.render_guard(policy, os.path.expanduser("~"))
    except Exception:  # noqa: BLE001 — corrupt/unreadable policy => fail-to-human (silent)
        return None


def _covers(glob_re, exceptions, subs):
    """Every subcommand matches some allow_exception glob (the exception covers the WHOLE request)."""
    if not subs:
        return False
    return all(any(glob_re(x).match(sub) for x in exceptions) for sub in subs)


def decide(event):
    """Return the hookSpecificOutput allow dict, or None for no decision (silent)."""
    kind, text = _command_of(event)
    if not kind or not text:
        return None
    # 1. §3 hard limit: never auto-allow, regardless of policy (defense-in-depth + tested).
    if _hard_limited(kind, text):
        return None
    guard = _guard_view()
    if guard is None:
        return None  # policy absent/unreadable: inert, no stderr
    exceptions = guard.get("allow_exceptions") or []
    denies = guard.get("deny") or []
    if not exceptions:
        return None
    me = _load("merge_opencode_permissions", "merge-opencode-permissions.py")
    if me is None:
        return None
    ev = _load("permission_eval", "permission-eval.py")
    subs = _subs(kind, text, ev)
    # 2. deny re-check: if any subcommand matches a deny, stay silent (never contradict a deny).
    if any(any(me.glob_re(d).match(sub) for d in denies) for sub in subs):
        return None
    # 3. an exception that covers every subcommand -> the one allow. Only bash carries via:hook
    #    exceptions in O1b's policy; path/webfetch requests stay for the human.
    if kind == "bash" and _covers(me.glob_re, exceptions, subs):
        return {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "allow", "reason": "delegate policy exception"},
            }
        }
    return None


if __name__ == "__main__":
    import json
    try:
        d = json.load(sys.stdin)
        out = decide(d)
        if out is not None:
            sys.stdout.write(json.dumps(out) + "\n")
    except Exception:  # noqa: BLE001 — a broken guard must never block or fake a decision
        pass
    sys.exit(0)
