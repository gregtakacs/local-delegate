#!/bin/bash
# Seeds opencode's config into the (per-task, bind-mounted) HOME on every start, then execs
# the command. Seeding every time — not once — means a change to the rules or plugins in the
# image reaches an in-flight task on its next review round, and nothing the model wrote into
# ~/.config/opencode survives to influence the next round.
set -euo pipefail

cfg="$HOME/.config/opencode"
rm -rf "$cfg"
mkdir -p "$cfg" "$HOME/.local/share" "$HOME/.cache"
cp -r /opt/delegate/opencode/rules /opt/delegate/opencode/plugins "$cfg/"
# The worker loads ONE instructions file (the rendered config points at delegate-rules.md).
# Compose it as the harness-neutral core FIRST, then the headless worker adapter that overrides
# parts of it, so one instruction path yields one coherent ruleset (core, then the deltas). A
# missing core is fatal, not silently tolerated: with only the deltas the worker would run with no
# Definition-of-Done gate, no PID-kill rule and no test policy — the whole point of the split.
core="$cfg/rules/harness-core.md"
adapter=/opt/delegate/opencode/delegate-rules.md
if [ ! -s "$core" ]; then
  echo "delegate entrypoint: rules/harness-core.md is missing or empty — refusing to start the" \
       "worker on the headless deltas alone" >&2
  exit 1
fi
cat "$core" "$adapter" > "$cfg/delegate-rules.md"
python3 /opt/delegate/lib/render-opencode-config.py "$cfg" > "$cfg/opencode.json"

# Private GitHub access, only when the task was started with --github. The token is read
# from its file at use time by git's credential helper; it is never written anywhere.
rm -f "$HOME/.gitconfig"
if [ "${DELEGATE_GITHUB:-0}" = 1 ] && [ -r /run/secrets/github_token ]; then
  git config --global credential.https://github.com.helper \
    '!f() { test "$1" = get && echo username=x-access-token && echo "password=$(cat /run/secrets/github_token)"; }; f'
  git config --global url."https://github.com/".insteadOf "git@github.com:"
  git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"
fi

if [ -n "${DELEGATE_EVIDENCE_DIR:-}" ]; then
  mkdir -p "$DELEGATE_EVIDENCE_DIR"
fi

# The PATH this container started with: the image's own, with the runner's guard shims first.
# A login shell (bash -lc: every verify and exec) resets PATH from /etc/profile;
# /etc/profile.d/zz-delegate-path.sh restores it from this.
export DELEGATE_PATH="$PATH"

exec "$@"
