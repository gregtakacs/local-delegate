#!/usr/bin/env bash
# install.sh — put `delegate` on PATH, install the Claude Code skill, write a config, build
# the worker image. Safe to re-run: it never overwrites an existing config or key.
#
#   ./install.sh                                   # interactive-free; edit the config after
#   ./install.sh --base-url https://llm.example.com/v1 --model qwen3-coder \
#                [--model-hard qwen3-coder-think] [--key-file PATH | --key-stdin] \
#                [--runner docker|native] [--context 131072] [--no-build]
#                [--claude-profile|--no-claude-profile] [--claude-permissions] [--claude-hook]
#   ./install.sh --release TAG [--repo URL | --from DIR] [any install flags above]
#                # pinned install under ${XDG_DATA_HOME:-$HOME/.local/share}/delegate; the
#                # links point through its `current` symlink, so an update is one flip.
#   ./install.sh --uninstall   # remove the links this installer created (ours only)
#   ./install.sh --purge       # --uninstall, and also remove that delegate data directory
#                              # when this checkout is not inside it
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
cfg_dir=${XDG_CONFIG_HOME:-$HOME/.config}/delegate
cfg=$cfg_dir/config.env
bin_dir=${DELEGATE_BIN_DIR:-$HOME/.local/bin}
skill_dir=${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}
oc_cmd_dir=${OPENCODE_COMMANDS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode/commands}
oc_plugin_dir=${OPENCODE_PLUGINS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins}
# The installed OpenCode's major version (0 when absent or unreadable); DELEGATE_OPENCODE_MAJOR
# overrides it (tests, and installs prepared before OpenCode itself is on PATH).
# `env` arguments that unset every XDG base dir that is set but not absolute.
oc_xdg_unset() {
  local var
  for var in XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_CONFIG_HOME; do
    case "${!var-/}" in /*) ;; *) printf -- '-u %s ' "$var" ;; esac
  done
}
opencode_major() {
  if [ -n "${DELEGATE_OPENCODE_MAJOR:-}" ]; then echo "$DELEGATE_OPENCODE_MAJOR"; return; fi
  local v
  # OpenCode writes a log under XDG_DATA_HOME even for --version: a relative value (invalid per
  # the spec, treated as unset here) would drop it into the current directory.
  v=$(env $(oc_xdg_unset) opencode --version 2>/dev/null | sed -nE 's/[^0-9]*([0-9]+)\..*/\1/p' | head -1)
  echo "${v:-0}"
}
oc_cfg=${OPENCODE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json}
agents_dir=${CLAUDE_AGENTS_DIR:-$HOME/.claude/agents}
# An empty or relative XDG_DATA_HOME is invalid per the XDG base dir spec: treat it as unset.
xdg_data=${XDG_DATA_HOME:-}; case "$xdg_data" in /*) ;; *) xdg_data="$HOME/.local/share" ;; esac
root=$xdg_data/delegate

base_url="" model="" model_hard="" key_file="" key_stdin=0 runner="" context="" build=1 claude_hook=0
# Claude profile: "" = default (on when ~/.claude exists), 1/0 = explicit flag. Permissions
# default off (design Q2): the static arrays are the owner's call, not the installer's.
claude_profile="" claude_permissions=0
release="" repo="https://github.com/<owner>/local-delegate" from="" uninstall=0 purge=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base-url) base_url=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --model-hard) model_hard=$2; shift 2 ;;
    --key-file) key_file=$2; shift 2 ;;
    --key-stdin) key_stdin=1; shift ;;
    --runner) runner=$2; shift 2 ;;
    --context) context=$2; shift 2 ;;
    --no-build) build=0; shift ;;
    --claude-hook) claude_hook=1; claude_profile=1; shift ;;
    --claude-profile) claude_profile=1; shift ;;
    --no-claude-profile) claude_profile=0; shift ;;
    --claude-permissions) claude_permissions=1; shift ;;
    --no-claude-permissions) claude_permissions=0; shift ;;
    --release) release=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --from) from=$2; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    --purge) purge=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

say() { printf '==> %s\n' "$*"; }

for t in git curl python3; do command -v "$t" >/dev/null || { echo "install.sh: $t is required" >&2; exit 1; }; done

if [ "$uninstall" = 1 ] || [ "$purge" = 1 ]; then
  # Remove only links we made: symlinks whose target resolves inside this checkout or the
  # release tree. Anything else that happens to sit at these paths is left alone, as today.
  unln() {
    local p=$1 t
    if [ -L "$p" ]; then
      # readlink -f fails on a dangling link (its root may have been deleted by hand):
      # then judge by the raw target, anchored at the link's own directory.
      t=$(readlink -f "$p" 2>/dev/null || true)
      [ -n "$t" ] || { t=$(readlink "$p"); case "$t" in /*) ;; *) t=$(cd "$(dirname "$p")" && pwd)/$t ;; esac; }
      case "$t" in
        "$here/"*|"$root/"*) rm -f "$p"; say "removed $p" ;;
        *) say "left $p (points at $t, not this install)" ;;
      esac
    elif [ -e "$p" ]; then say "NOTE: $p exists and is not a symlink; left alone"
    fi
  }
  unln "$bin_dir/delegate"; unln "$bin_dir/delegate-wake"
  unln "$skill_dir/delegate"; unln "$oc_cmd_dir/delegate.md"
  unln "$agents_dir/delegate-lead.md"
  for name in chunk-cap notes-loop todo-loop verify-loop; do
    unln "$oc_plugin_dir/$name.js"
  done
  # Config files next: each helper removes ONLY what it recorded under _delegate (and, for a
  # pre-marker config, only entries matching exactly what we would have written). Both exit 0
  # when their target file doesn't exist.
  python3 "$here/lib/merge-opencode-permissions.py" --config "$oc_cfg" \
    --skill-dir "$skill_dir/delegate" --real-dir "$here/claude/skills/delegate" --uninstall \
    || say "NOTE: opencode config not cleaned; see the message above"
  python3 "$here/lib/merge-claude-settings.py" --uninstall \
    || say "NOTE: claude settings not cleaned; see the message above"
  if [ "$purge" = 1 ]; then
    case "$here" in
      "$root"/*) say "NOTE: this checkout lives inside $root; leaving it in place" ;;
      *) rm -rf "$root"; say "removed $root" ;;
    esac
  fi
  exit 0
fi

DELEGATE_HOME=$here
if [ -n "$release" ]; then
  # The fetch/verify/flip lives in lib/release-fetch.sh, where `delegate update` runs exactly the
  # same code; this is a thin caller. Sourced here rather than at the top: an install tree that is
  # not doing a --release fetch never needs the file (and `--purge` from inside root must not).
  # shellcheck disable=SC1091
  . "$here/lib/release-fetch.sh"
  url=$repo
  if [ -n "$from" ] && [ ! -e "$root/$release" ]; then
    from=$(cd "$from" 2>/dev/null && pwd) || { echo "install.sh: --from is not a directory: $from" >&2; exit 1; }
    url=file://$from          # --from wins over --repo; a dirty working copy is not installed, the tag is
  fi
  RF_PROG=install.sh release_fetch "$release" "$url" "$root" || exit $?
  DELEGATE_HOME=$root/current
fi
DELEGATE_REAL=$(readlink -f "$DELEGATE_HOME")   # content reads take the resolved tree; links keep current

mkdir -p "$bin_dir" "$skill_dir" "$cfg_dir"
chmod 700 "$cfg_dir"
ln -sfn "$DELEGATE_HOME/bin/delegate" "$bin_dir/delegate"
ln -sfn "$DELEGATE_HOME/bin/delegate-wake" "$bin_dir/delegate-wake"
say "delegate -> $bin_dir/delegate"
case ":$PATH:" in *":$bin_dir:"*) ;; *) say "NOTE: $bin_dir is not on your PATH; add it to your shell profile" ;; esac

if [ -e "$skill_dir/delegate" ] && [ ! -L "$skill_dir/delegate" ]; then
  say "NOTE: $skill_dir/delegate exists and is not a symlink; left alone"
else
  ln -sfn "$DELEGATE_HOME/claude/skills/delegate" "$skill_dir/delegate"
  say "Claude Code skill -> $skill_dir/delegate (use /delegate, or just ask Claude to delegate)"
fi

# opencode as orchestrator: let the skill load without a permission prompt and let agents
# read it. Merges only entries that are absent; never rewrites values you set.
if command -v opencode >/dev/null; then
  # --real-dir takes the resolved tree (the merge writes it into the config as file content);
  # every link below still goes through $DELEGATE_HOME, which in release mode is `current`.
  # The rules/policy additions are each guarded on the file existing, so an install tree from
  # before O1b (or a release fixture that ships without them) merges exactly as before.
  oc_extra=()
  for f in opencode/rules/harness-core.md opencode/rules/adapter-opencode.md; do
    [ -f "$DELEGATE_HOME/$f" ] && oc_extra+=(--instructions "$DELEGATE_HOME/$f")
  done
  if [ -f "$DELEGATE_HOME/policy/harness-permissions.json" ]; then
    oc_extra+=(--permission-policy "$DELEGATE_HOME/policy/harness-permissions.json" --render)
  fi
  python3 "$DELEGATE_HOME/lib/merge-opencode-permissions.py" \
    --skill-dir "$skill_dir/delegate" --real-dir "$DELEGATE_REAL/claude/skills/delegate" \
    ${oc_extra[@]+"${oc_extra[@]}"} \
    || say "NOTE: opencode config not merged; see the message above"
  # opencode's "/" menu lists commands, not skills: /delegate is a command that loads the skill.
  mkdir -p "$oc_cmd_dir"
  if [ -e "$oc_cmd_dir/delegate.md" ] && [ ! -L "$oc_cmd_dir/delegate.md" ]; then
    say "NOTE: $oc_cmd_dir/delegate.md exists and is not a symlink; left alone"
  else
    ln -sfn "$DELEGATE_HOME/commands/opencode/delegate.md" "$oc_cmd_dir/delegate.md"
    say "opencode command -> $oc_cmd_dir/delegate.md (type /delegate in opencode)"
  fi
  # The harness plugins (design §5.1), each a link through the install tree so an update is
  # picked up without re-running the installer. Same left-alone care as every other link.
  # OpenCode 2.x rejects the 1.x plugin shape (all four failed to load on 2.3.0, 2026-11-16), so a
  # 2.x install links the opencode/plugins-v2 entries, which wrap the same 1.x logic. Only the
  # plugin names are linked: plugins-v2/adapt.js is a module, not a plugin.
  oc_plugin_src=plugins
  if [ "$(opencode_major)" -ge 2 ] 2>/dev/null && [ -d "$DELEGATE_HOME/opencode/plugins-v2" ]; then
    oc_plugin_src=plugins-v2
  fi
  if ls "$DELEGATE_HOME"/opencode/plugins/*.js >/dev/null 2>&1; then
    mkdir -p "$oc_plugin_dir"
    for p in "$DELEGATE_HOME"/opencode/plugins/*.js; do
      name=$(basename "$p"); dest="$oc_plugin_dir/$name"
      [ -f "$DELEGATE_HOME/opencode/$oc_plugin_src/$name" ] || continue
      if [ -e "$dest" ] && [ ! -L "$dest" ]; then
        say "NOTE: $dest exists and is not a symlink; left alone"
      else
        ln -sfn "$DELEGATE_HOME/opencode/$oc_plugin_src/$name" "$dest"
        say "opencode plugin -> $dest ($oc_plugin_src)"
      fi
    done
  fi
fi

if [ "$key_stdin" = 1 ]; then
  key_file=$cfg_dir/api-key
  if [ -e "$key_file" ]; then say "api key file exists, not overwritten: $key_file"
  else ( umask 077; tr -d '\r\n' > "$key_file" ); say "api key -> $key_file (600)"; fi
fi

if [ -f "$cfg" ]; then
  say "config exists, not overwritten: $cfg"
else
  cp "$DELEGATE_HOME/config.example.env" "$cfg"
  chmod 600 "$cfg"
  setv() { python3 - "$cfg" "$1" "$2" <<'EOF'
import re, sys
path, key, val = sys.argv[1:]
s = open(path).read()
s, n = re.subn(rf'^{key}=.*$', f'{key}="{val}"', s, count=1, flags=re.M)
if not n: s += f'{key}="{val}"\n'
open(path, "w").write(s)
EOF
  }
  [ -n "$base_url" ]   && setv DELEGATE_BASE_URLS "$base_url"
  [ -n "$model" ]      && setv DELEGATE_MODEL "$model"
  [ -n "$model_hard$model" ] && setv DELEGATE_MODEL_HARD "${model_hard:-$model}"
  [ -n "$key_file" ]   && setv DELEGATE_API_KEY_FILE "$key_file"
  [ -n "$runner" ]     && setv DELEGATE_RUNNER "$runner"
  [ -n "$context" ]    && setv DELEGATE_CONTEXT "$context"
  say "config -> $cfg  (review it: endpoint, model ids, context, runner)"
fi

# shellcheck disable=SC1090
runner_now=$(set -a; . "$cfg"; echo "${DELEGATE_RUNNER:-docker}")
if [ "$runner_now" = docker ]; then
  if ! command -v docker >/dev/null; then
    say "NOTE: DELEGATE_RUNNER=docker but docker is missing; install it or set DELEGATE_RUNNER=native"
  elif [ "$build" = 1 ]; then
    say "building the worker image (a few minutes the first time)"
    "$DELEGATE_HOME/bin/delegate" build
  fi
else
  command -v opencode >/dev/null || say "NOTE: native runner needs opencode: curl -fsSL https://opencode.ai/install | bash"
fi

mkdir -p "$agents_dir"
if [ -e "$agents_dir/delegate-lead.md" ] && [ ! -L "$agents_dir/delegate-lead.md" ]; then
  say "NOTE: $agents_dir/delegate-lead.md exists and is not a symlink; left alone"
else
  ln -sfn "$DELEGATE_HOME/claude/agents/delegate-lead.md" "$agents_dir/delegate-lead.md"
  say "Claude Code agent -> $agents_dir/delegate-lead.md (plans a slice, runs it as a chain, checks once)"
fi

# Claude Code profile: hooks, rules file, and (only on request) the rendered permission arrays.
# The whole block is the old --claude-hook path grown up: one helper call, everything it writes
# recorded under `_delegate` so --uninstall and doctor know exactly what is ours.
if [ "$claude_profile" = "" ] && [ ! -d "$HOME/.claude" ]; then claude_profile=0; fi
if [ "$claude_profile" != 0 ]; then
  if [ -e "$HOME/.claude" ] && [ ! -d "$HOME/.claude" ]; then
    say "NOTE: ~/.claude exists and is not a directory; profile not installed"
  else
    cc_extra=()
    [ -f "$DELEGATE_HOME/policy/harness-permissions.json" ] &&
      cc_extra+=(--policy "$DELEGATE_HOME/policy/harness-permissions.json")
    if [ "$claude_permissions" = 1 ]; then
      if [ ${#cc_extra[@]} -eq 0 ]; then
        say "NOTE: --claude-permissions needs policy/harness-permissions.json; permissions not merged"
      else
        cc_extra+=(--permissions)
      fi
    fi
    [ "$claude_hook" = 1 ] && cc_extra+=(--agent-progress)
    python3 "$DELEGATE_HOME/lib/merge-claude-settings.py" \
      --install "$DELEGATE_HOME" --real-dir "$DELEGATE_REAL" ${cc_extra[@]+"${cc_extra[@]}"} \
      || say "NOTE: claude profile not installed; see the message above"
  fi
fi

say "checking the setup"
"$DELEGATE_HOME/bin/delegate" doctor --quick || say "doctor reported problems — fix the config and re-run: delegate doctor"
