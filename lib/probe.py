#!/usr/bin/env python3
"""Check that an OpenAI-compatible endpoint can actually drive an agent.

  probe.py BASE_URL KEY_FILE MODEL [--quick]

Agent CLIs live or die on tool calling, and the classic self-hosted failures are silent:
the server answers 200 but the call arrives as text in `content` ("<tool_call>...",
"<function=...>"), or with arguments that are not valid JSON, or only when not streaming.
This sends one forced-shape tool call non-streaming and (unless --quick) streaming, and
fails loudly on any of those.
"""
import json
import sys
import time
import urllib.request

base, key_file, model = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
quick = "--quick" in sys.argv[4:]
key = open(key_file).read().strip()

TOOLS = [{
    "type": "function",
    "function": {
        "name": "write_file",
        "description": "Write text content to a file at the given relative path.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Relative file path"},
                "content": {"type": "string", "description": "Full file content"},
            },
            "required": ["path", "content"],
        },
    },
}]
MESSAGES = [
    {"role": "system", "content": "You are a coding agent. Use tools to act."},
    {"role": "user", "content": 'Create hello.py containing exactly: print("hi, \\"probe\\"")\n'
                                "Use the write_file tool. Do not explain."},
]
LEAKS = ("<tool_call>", "<function=", "<|tool", "</tool_call>", '"name": "write_file"')


def post(body, stream):
    req = urllib.request.Request(
        base + "/chat/completions", data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=300)


def check(name, content, calls, elapsed):
    problems = []
    if not calls:
        problems.append("no tool_calls returned")
    for c in calls:
        fn = c.get("function") or {}
        if fn.get("name") != "write_file":
            problems.append(f"unexpected tool name {fn.get('name')!r}")
        try:
            args = json.loads(fn.get("arguments") or "")
            if not isinstance(args, dict) or "path" not in args or "content" not in args:
                problems.append(f"arguments missing fields: {args!r}"[:200])
            elif "probe" not in args["content"]:
                problems.append(f"content mangled: {args['content']!r}"[:200])
        except json.JSONDecodeError:
            problems.append(f"arguments are not JSON: {fn.get('arguments')!r}"[:200])
    if content and any(m in content for m in LEAKS):
        problems.append("tool-call markup leaked into content (phantom/unparsed tool call)")
    verdict = "ok" if not problems else "FAIL: " + "; ".join(problems)
    print(f"probe:    {model} {name}: {verdict} ({elapsed:.1f}s, {len(calls)} call(s))")
    return not problems


def non_stream():
    t = time.time()
    with post({"model": model, "messages": MESSAGES, "tools": TOOLS, "max_tokens": 4096}, False) as r:
        d = json.load(r)
    msg = d["choices"][0]["message"]
    return check("non-stream", msg.get("content") or "", msg.get("tool_calls") or [], time.time() - t)


def stream():
    t = time.time()
    calls, content = {}, []
    body = {"model": model, "messages": MESSAGES, "tools": TOOLS, "max_tokens": 4096, "stream": True}
    with post(body, True) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            ch = json.loads(data).get("choices") or []
            if not ch:
                continue
            delta = ch[0].get("delta") or {}
            if delta.get("content"):
                content.append(delta["content"])
            for tc in delta.get("tool_calls") or []:
                slot = calls.setdefault(tc.get("index", 0), {"function": {"name": "", "arguments": ""}})
                fn = tc.get("function") or {}
                slot["function"]["name"] += fn.get("name") or ""
                slot["function"]["arguments"] += fn.get("arguments") or ""
    return check("stream", "".join(content), [calls[k] for k in sorted(calls)], time.time() - t)


ok = True
try:
    ok = non_stream() and ok
    if not quick:
        ok = stream() and ok
except Exception as e:  # network, HTTP error, malformed JSON
    print(f"probe:    {model}: FAIL: {type(e).__name__}: {e}")
    ok = False
sys.exit(0 if ok else 1)
