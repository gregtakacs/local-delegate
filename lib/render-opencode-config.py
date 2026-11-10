#!/usr/bin/env python3
"""Render the worker's opencode.json from DELEGATE_* environment variables.

Usage: render-opencode-config.py CONFIG_DIR > CONFIG_DIR/opencode.json

One provider ("delegate"), pointed at any OpenAI-compatible /v1 endpoint. The API key is
read by opencode from a file at request time ({file:...}), so it never lands in the
rendered config, the process list, or the event log.
"""
import json
import os
import sys


def env(name, default=None, required=False):
    v = os.environ.get(name, default)
    if required and not v:
        sys.exit(f"render-opencode-config: {name} is not set")
    return v


cfg_dir = sys.argv[1]
base_url = env("DELEGATE_BASE_URL", required=True).rstrip("/")
key_file = env("DELEGATE_API_KEY_FILE", required=True)
model = env("DELEGATE_MODEL", required=True)
hard = env("DELEGATE_MODEL_HARD") or model
context = int(env("DELEGATE_CONTEXT", "131072"))
output = int(env("DELEGATE_OUTPUT", "32768"))
vision = env("DELEGATE_VISION", "1") == "1"
evidence = env("DELEGATE_EVIDENCE_DIR", "")


def model_entry(name):
    m = {
        "name": name,
        "reasoning": env("DELEGATE_REASONING", "1") == "1",
        "limit": {"context": context, "output": output},
    }
    if vision:
        m["modalities"] = {"input": ["text", "image"], "output": ["text"]}
        m["attachment"] = True
    return m


external = {"*": "deny", "/tmp/**": "allow", f"{cfg_dir}/**": "allow"}
if evidence:
    external[f"{evidence}/**"] = "allow"
# --read reference checkouts: readable by the file tools, never editable.
reads = [r for r in env("DELEGATE_READ_PATHS", "").split() if r]
for r in reads:
    external[f"{r}/**"] = "allow"

config = {
    "$schema": "https://opencode.ai/config.json",
    "autoupdate": False,
    "share": "disabled",
    # Not AGENTS.md: opencode auto-loads ~/.config/opencode/AGENTS.md as global rules, and
    # naming it explicitly too would load the rules twice.
    "instructions": [f"{cfg_dir}/delegate-rules.md"],
    "model": f"delegate/{model}",
    "small_model": f"delegate/{model}",
    "agent": {
        "build": {"model": f"delegate/{model}"},
        "plan": {"model": f"delegate/{hard}"},
    },
    "permission": {
        # Headless: there is nobody to answer an "ask". Everything inside the worktree is
        # allowed; outside it, only /tmp, the evidence dir and the rules are reachable by the
        # file tools. The real boundary is the container (docker runner) — bash is not
        # path-scoped by these rules.
        "external_directory": external,
        "edit": {f"{cfg_dir}/**": "deny", **{f"{r}/**": "deny" for r in reads}},
        "bash": "allow",
        "webfetch": "allow",
        "doom_loop": "allow",
    },
    "attachment": {"image": {"auto_resize": True, "max_width": 2000, "max_height": 2000}},
    "provider": {
        "delegate": {
            "npm": "@ai-sdk/openai-compatible",
            "name": "delegate worker endpoint",
            "options": {"baseURL": base_url, "apiKey": "{file:" + key_file + "}"},
            "models": {m: model_entry(m) for m in dict.fromkeys([model, hard])},
        }
    },
}
json.dump(config, sys.stdout, indent=2)
sys.stdout.write("\n")
