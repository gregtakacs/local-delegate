# Task B3: agent profiles — loading, argv rendering, setup lists, proxy decision, output parsers

`"hard": true` — profiles become argv inside the sandbox, they name which of the owner's setup
paths get copied into it, and the parsers read untrusted agent output. Slice B step 3 of 10,
chain segment 1 (`docs/specs/b-design.md` §Agent profiles, §The owner's harness setup, §Telemetry
(a)(b)). R19: this step writes data and parsers only; the code that copies setup into a sandbox
and starts containers is the orchestrator's (`b-o1-sandbox`), which re-validates what this lib
returns. No grant, key or credential handling here (R14 amended): the lib never reads a setup
file or an env value, it only names them.

## Goal

One abstraction for "an agent that can be started in the sandbox", for both the worker-under-test
and the reviewer roles: `lib/agents.py` loads and validates TOML profiles from trusted folders,
renders profile + model + effort to an argv list (no shell), lists the setup paths and env names
the profile declares, decides whether the logging proxy applies, and parses each harness's
machine-readable output into one normalized summary. Four profiles ship.

## Read first

- `docs/specs/b-design.md` §Agent profiles (the TOML example is the shipped `claude-code`
  profile, verbatim), §The owner's harness setup in the sandbox, §Telemetry, §CLI facts.
- `lib/grants.py` — `check_owned`, `NAME_RE`, `ENV_KEY_RE`, `ENV_RESERVED`, the tomllib/3.11
  handling (import these; do not copy or change `lib/grants.py`).
- `lib/report.py` `read_events`, `summarize`, `final_text` — the `opencode-json` parser reuses them.

## Contract

### `lib/agents.py` — create (stdlib; tomllib needs 3.11, same message as grants.py)

Loading:
- Folders: `$DELEGATE_HOME/agents/` (shipped, trusted as installed) and `$DELEGATE_AGENTS_DIR`
  (default `${XDG_CONFIG_HOME:-~/.config}/delegate/agents/`), whose folder and files must pass
  `grants.check_owned`. An owner file overrides the shipped one of the same name. No other
  source (no repo, worktree, plan folder, cwd).
- Name `NAME_RE`; file `<name>.toml`; `name` must equal the stem.
- Keys (unknown → `AgentError`): `name`, `kind` (`command`|`delegate`), `image` (str, default
  `""`), `argv` (non-empty list of str), `model_args`, `effort_args` (lists, default `[]`),
  `efforts` (list of `[a-z]{1,16}`, default `[]`), `version_argv` (list), `tested_versions`
  (list of str), `output` (`claude-stream`|`codex-json`|`opencode-json`|`none`), `verified`
  (bool, default true), tables `[setup]` (`paths`: list of str, `env`: list of str), `[env]`
  (plain `KEY = "value"`), `[api]` (`base_url_env`, `default_upstream`, `key_env` list,
  `dialect` `anthropic`|`openai`). `kind = "delegate"` allows only `name`, `kind`.
- `[setup] paths`: each non-empty, relative (no leading `/` or `~`), no `..` segment, no glob
  characters `*?[`, no NUL/newline, at most 64 entries. `[setup] env` and `api.key_env`: names
  matching `ENV_KEY_RE` and not starting with `DELEGATE_`; every `api.key_env` entry must be in
  `[setup] env`. `[env]` names match `ENV_KEY_RE` and not `ENV_RESERVED`; values str without
  newline/NUL. `api.base_url_env`: `ENV_KEY_RE`, and in `[setup] env`. `default_upstream`:
  `http(s)://host[:port][/path]`, no userinfo/query/fragment.
- `load_profile(name)`, `list_profiles()` (each with `source`, `verified`).

Rendering — `render_argv(profile, model, effort) -> list[str]`: placeholders `{model}`,
`{effort}`, `{model_args}`, `{effort_args}` only; `{{`/`}}` literal braces; any other `{...}` →
error. `{model_args}`/`{effort_args}` must be a whole element and splice the rendered list (empty
when the value is empty); absent → appended at the end. Values match
`^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$` or are empty; a non-empty effort must be in `efforts`.
Returns a list; nothing joins it into a string.

Setup — `setup_paths(profile) -> list[str]`, `setup_env(profile) -> list[str]`: the declared,
validated lists. The lib never opens a setup path and never reads an env value.

Launch env — `launch_env(profile, base_url) -> list[str]` (`KEY=VALUE` for `docker run -e`):
the profile's `[env]` items, plus `DELEGATE_AGENT_BASE_URL_ENV=<api.base_url_env>` and
`DELEGATE_AGENT_BASE_URL=<base_url>` when both are non-empty. Nothing else.

Proxy — `proxy_plan(profile, present_env, setup_base_url) -> dict | None`. `present_env`: the
set of `[setup] env` **names** that are set in the invoking environment (the caller passes names,
never values). Returns `{"upstream", "dialect", "base_url_env"}` iff `api.base_url_env` is set
and some `api.key_env` name is in `present_env` (the owner's setup already authenticates with an
API key); `upstream` = `setup_base_url` (the value of the setup's own base-URL variable, passed by
the caller) when non-empty and valid by the `default_upstream` rule, else `default_upstream`.
Otherwise `None`.

Version — `version_checked(profile, text) -> bool | None`: None when empty; else find the first
whitespace token that starts with a digit, or with `v` followed by a digit (strip the `v`); true
when a `tested_versions` entry is a prefix of it.

Parsers — `summarize(fmt, path) -> dict`, untrusted input: at most 512 MiB read; a line over
4 MiB or not a JSON object → counted in `unparsed_lines` and skipped; never raises on content;
missing file → empty summary. Keys: `steps`, `tool_calls`, `tools` (name → count),
`tool_errors` (≤ 50 × `"name: <≤240 chars, newlines → spaces>"`), `errors` (≤ 20 × ≤ 300 chars),
`input_tokens`, `output_tokens`, `reasoning_tokens`, `cache_read`, `cache_write` (int or None
when the stream carried no usage), `final_text` (≤ 20 000 chars), `model_reported`,
`agent_version`, `success` (True/False/None), `session`, `unparsed_lines`.
- `claude-stream` (documented; only `system/init` observed live on 2.1.325): `system/init` →
  `model_reported = model`, `agent_version = claude_code_version`, `session = session_id`;
  `system/api_retry` → an `errors` entry `api_retry: <error_status>`; `assistant` → distinct
  `message.id`s are steps; `message.usage` (last seen per id) summed (`cache_read_input_tokens`
  → `cache_read`, `cache_creation_input_tokens` → `cache_write`) unless a `result` event carries
  `usage`, which then wins; each distinct `tool_use` block id counts a call under its `name`;
  `user` → each `tool_result` with `is_error: true` is a tool error named by its tool (via
  `tool_use_id`), message from its `content` (str, or the text of its text blocks); `result` →
  `success = (subtype == "success" and not is_error)`, `final_text = result`. No `result` →
  `success = None`, `final_text` = the last assistant text block.
- `codex-json` (documented, **unverified**): `thread.started` → `session = thread_id`;
  `turn.completed` → steps + 1, `usage.input_tokens`, `usage.output_tokens`,
  `usage.cached_input_tokens` (→ `cache_read`), `usage.reasoning_output_tokens` (→ reasoning)
  summed; `item.completed` with `item.type` in `command_execution`, `file_change`,
  `mcp_tool_call`, `web_search` counts a call under that type; a `command_execution` with
  non-zero `exit_code` or `status == "failed"` is a tool error (`command_execution: <command>`);
  the last `agent_message` `text` → `final_text`; `turn.failed`/`error` → `errors` + `success =
  False`; else `True` once a `turn.completed` was seen, else `None`.
- `opencode-json`: `report.read_events` + `report.summarize` (import `lib/report.py`), mapped to
  `steps`, `tool_calls`, `tools`, `tool_errors`, `errors`, `output_tokens`, `reasoning_tokens`;
  `input_tokens`/`cache_read`/`cache_write` summed over `step_finish` `part.tokens` (`input`,
  `cache.read`, `cache.write`); `final_text` via `report.final_text`; `success` = no `error`
  event and at least one `step_finish`; `session` = the first `sessionID`.
- `none`: all empty, `steps = 0`.

CLI (`python3 lib/agents.py SUB`): `list`; `show NAME` (profile JSON + `source`, `verified`,
the argv rendered with model `MODEL` and the first effort); `argv NAME --model M --effort E`
(NUL-separated, for `mapfile -d ''`); `setup-paths NAME`, `setup-env NAME` (one per line);
`env NAME [--base-url URL]` (one `KEY=VALUE` per line); `proxy NAME --present "A B"
[--setup-base-url URL]` (one line `upstream dialect base_url_env`, or nothing); `version-checked
NAME FILE` (`true|false|null`); `summarize FMT FILE` (JSON). Errors: `delegate: agents:
<message>` to stderr, exit 2.

### Shipped profiles — create

- `agents/delegate.toml` — `name = "delegate"`, `kind = "delegate"`.
- `agents/claude-code.toml` — the design's example verbatim plus
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"` in `[env]`; header comment: which flags were
  checked against which version, and that `.claude/projects` (other sessions' transcripts) is
  deliberately not copied.
- `agents/codex.toml` — `verified = false`; argv `["codex", "exec", "--json",
  "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check", "{model_args}",
  "{effort_args}", "-"]`; `model_args = ["--model", "{model}"]`; `effort_args = ["-c",
  "model_reasoning_effort={effort}"]`; `efforts = ["minimal", "low", "medium", "high"]`;
  `version_argv = ["codex", "--version"]`; `tested_versions = []`; `output = "codex-json"`;
  `[setup] paths = [".codex/auth.json", ".codex/config.toml", ".codex/AGENTS.md"]`, `env =
  ["OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL"]`; `[api] base_url_env =
  "OPENAI_BASE_URL"`, `default_upstream = "https://api.openai.com/v1"`, `key_env =
  ["OPENAI_API_KEY", "CODEX_API_KEY"]`, `dialect = "openai"`; header: "UNVERIFIED — check every
  flag against `codex exec --help` before relying on it."
- `agents/opencode-own.toml` — OpenCode exactly as the owner configured it (for example with a
  Claude API key): `verified = false`; argv `["opencode", "run", "--format", "json",
  "{model_args}"]`; `model_args = ["-m", "{model}"]`; `version_argv = ["opencode",
  "--version"]`; `tested_versions = ["2.3"]`; `output = "opencode-json"`; `[setup] paths =
  [".config/opencode", ".local/share/opencode/auth.json"]`, `env = ["ANTHROPIC_API_KEY",
  "ANTHROPIC_BASE_URL"]`; `[env] OPENCODE_DISABLE_AUTOUPDATE = "1"`, `OPENCODE_DISABLE_SHARE =
  "1"`; `[api] base_url_env = "ANTHROPIC_BASE_URL"`, `default_upstream =
  "https://api.anthropic.com"`, `key_env = ["ANTHROPIC_API_KEY"]`, `dialect = "anthropic"`;
  header: whether the owner's provider honours `ANTHROPIC_BASE_URL`, and the auth-store path, are
  unverified.

### `bin/delegate`

- `agent)` case: `agent list` / `agent show NAME` → `lib/agents.py`; `usage()` lines; config
  `: "${DELEGATE_AGENTS_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/delegate/agents}"` and
  `: "${DELEGATE_AGENT_IMAGE:=delegate-agents:local}"`, exported to the lib calls.

### `tests/test_agents.sh` — create

Temp owner agents dir. At least: all four shipped profiles load; `show claude-code` argv equals
the design's list with `--model MODEL --effort low` at the placeholders; codex argv ends with `-`
after the spliced args; empty model drops `--model`; refusals — unknown key, `{prompt}`,
`{model_args}` inside a longer element, model `a b`, model `$(id)`, effort not in `efforts`,
setup paths `../x`, `/etc/passwd`, `~/.x`, `.claude/*`, `[env] PATH`/`DELEGATE_X`, `key_env` not
in `[setup] env`, `default_upstream = "https://u:p@h"`, group-writable owner file, name ≠ stem;
owner override; `setup-paths`/`setup-env` print the lists; `env` prints the plain env and the
base-URL pair only; `proxy` prints a line only when a `key_env` name is present, uses
`--setup-base-url` when valid and falls back to the default when not; `version-checked`
true/false/null, including `opencode v2.3.0` → true for `opencode-own`. Parsers on fixture streams
written in the test: claude (init, an assistant id repeated across two events, a tool_use + error
tool_result, an api_retry, a result with usage → exact numbers; again without result → per-id
sums, `success` null); codex (two turns, one failed command); opencode (today's event format, two
steps, a tool error); garbage lines, a 5 MiB line and a JSON array → `unparsed_lines` 3, no
exception; missing file → empty summary. The lib never opens a setup path: `show`/`setup-paths`
with a `HOME` whose `.claude` is mode 000 work without error.

## Out of scope

- Copying setups, containers, proxy launch (O1), rounds (B5). No change to `lib/grants.py`,
  `run_worker_*`, `lib/report.py`, `worker/*`, existing tests.

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check blames untracked deliverables; the harness
commits before the chain's verify runs. If that is the only failure mid-round, report it; never
edit that test. The **cage check** fails if this step changed any sandbox function or file
(R19: orchestrator code; `docs/specs/b-design.md` §Who writes what) — never "fix" it by editing
the check; leave the sandbox code alone and report what you needed under DEVIATIONS.

```bash
set -o pipefail && bash -n bin/delegate && python3 -m py_compile lib/*.py && [ -f tests/test_agents.sh ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && for fn in run_worker run_worker_docker run_worker_native ensure_network ensure_egress ensure_task_egress host_args read_mount_args make_guard_shims; do cmp -s <(git show bench:bin/delegate | sed -n "/^$fn() {/,/^}/p") <(sed -n "/^$fn() {/,/^}/p" bin/delegate) || { echo "CAGE CHANGED $fn (R19: orchestrator code)"; exit 1; }; done && { git diff --quiet bench -- lib/grants.py worker/egress.Dockerfile worker/egress-entrypoint.sh worker/entrypoint.sh lib/render-opencode-config.py worker/agent-launch || { echo "CAGE CHANGED files (R19: orchestrator code)"; exit 1; }; } && ! git diff --name-only delegate/b-2-effort-models | grep -qvE '^docs/specs/b-|^bin/delegate$|^lib/agents\.py$|^agents/(delegate|claude-code|codex|opencode-own)\.toml$|^tests/test_agents\.sh$' && echo GATE-OK
```

## Report format

```text
STATUS: done|partial|blocked
SUMMARY: <=3 sentences
TESTS: <counts; which suites ran; gate result>
RISKS: <what might still be wrong>
DEVIATIONS: <departures from this spec and why, or none>
```
