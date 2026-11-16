# Task B3: agent profiles, argv rendering, output parsers, and the grant `[secrets]` table

`"hard": true` — profiles become argv inside the sandbox, the parsers read untrusted agent
output, and `[secrets]` changes `lib/grants.py` (security code, AGENTS.md). Slice B step 3 of 10
(`docs/specs/b-design.md` §Agent profiles, §Credentials, §Telemetry (b), Owner question 2).

## Goal

One abstraction for "an agent that can be started in the sandbox", used later by both the
worker-under-test and the reviewer roles: `lib/agents.py` loads and validates TOML agent
profiles from trusted folders only, renders a profile + model + effort into an argv list (no
shell), computes the launch environment, and parses each harness's machine-readable output into
one normalized summary. Grants gain a `[secrets]` table: owner-named files mounted read-only at
`/run/secrets/grant/<name>`, the only way an agent credential reaches a sandbox.

## Read first

- `docs/specs/b-design.md` §Agent profiles (the TOML example is the shipped `claude-code`
  profile, verbatim), §Credentials, §Telemetry (b), §CLI facts and what is unverified.
- `lib/grants.py` in full — `NAME_RE`, `ENV_KEY_RE`, `ENV_RESERVED`, `TOP_KEYS`/`SECTION_KEYS`,
  `check_owned`, `parse_grant`, `resolve`, `docker_args`, `summary`, `main` — and
  `docs/grants.md` (the format doc you extend).
- `tests/test_grants.sh` — its fixtures and helpers; you add cases to it.
- `lib/report.py` `summarize` — the summary keys the agent parsers must also produce.

## Contract

### `lib/grants.py` — the `[secrets]` table

- `TOP_KEYS` gains `secrets`. `[secrets]` is a table `name = "path"`: name matches `NAME_RE`;
  path a string, `~` expanded, absolute; at **resolve** time the path must be a regular file
  (`os.lstat` — a symlink is refused, so the owner names the real file), owned by the user, not
  group- or world-writable (reuse `check_owned`'s rule). Errors through `fail()` naming the grant
  and the secret.
- `resolve(...)`: collects `secrets: [{"name", "path", "grant"}]` into the resolved dict; the same
  name from two grants → `fail`. `runner == "native"` with any secret → `fail("grant G: [secrets]
  needs the docker runner; a native task cannot keep a secret from the rest of your account")`.
  A `kind = "orb"` grant takes no `[secrets]` (the existing orb key whitelist already refuses it —
  keep it so).
- `docker_args(r)`: for each secret `-v`, `<path>:/run/secrets/grant/<name>:ro`.
- `summary(r)`: adds `secrets: <name>, <name>` when any (names only).
- `main`: new subcommand `secrets` printing the resolved secret **names**, one per line.
  `show NAME` prints the mount lines (paths, never content). Nothing reads secret file content,
  anywhere in this file.
- `docs/grants.md`: a `[secrets]` subsection under "The file" and "What each part does" (purpose,
  the path inside the container, read-only, never blanked, docker runner only, names in the
  report), using a placeholder path.

### `lib/agents.py` — create (stdlib; tomllib needs 3.11, same message as grants.py)

Profile loading:
- Folders, in order: `$DELEGATE_HOME/agents/` (shipped) and `$DELEGATE_AGENTS_DIR` (default
  `${XDG_CONFIG_HOME:-~/.config}/delegate/agents/`). The owner folder and its files must pass
  `grants.check_owned` (import it); the shipped folder is trusted as part of the install. A
  name in the owner folder overrides the shipped one. No other source: no repo, worktree, plan
  folder or cwd lookup.
- Name `NAME_RE`, file `<name>.toml`, the `name` key must equal the stem.
- Keys (unknown → `AgentError`): `name`, `kind` (`command` | `delegate`), `image` (str, default
  `""`), `argv` (non-empty list of str), `model_args`, `effort_args` (lists of str, default `[]`),
  `efforts` (list of `[a-z]{1,16}`, default `[]` = any effort refused), `version_argv` (list, may be
  empty), `tested_versions` (list of str), `output` (`claude-stream` | `codex-json` | `none`),
  `verified` (bool, default true; the shipped codex profile sets false), tables `[env]` (plain
  `KEY = "value"`), `[secrets_env]` (`ENV = "secret-name"`), `[api]` (`base_url_env`,
  `default_upstream`, `proxy_key_env`, `dialect` `anthropic` | `openai`).
  `kind = "delegate"` allows only `name`, `kind`.
- Env names in `[env]`, `[secrets_env]`, `api.base_url_env` match `grants.ENV_KEY_RE` and NOT
  `grants.ENV_RESERVED`; values in `[env]` are str without newline or NUL; `[secrets_env]` values
  match `NAME_RE`; `api.proxy_key_env` must be a key of `[secrets_env]`; `default_upstream` is
  `http(s)://host[:port][/path]`, no userinfo, query or fragment.
- `load_profile(name) -> dict`, `list_profiles() -> list[dict]` (each with `source` path and
  `verified`).

Rendering (`render_argv(profile, model, effort) -> list[str]`):
- Placeholders `{model}`, `{effort}`, `{model_args}`, `{effort_args}` only; `{{`/`}}` are literal
  braces; any other `{...}` → `AgentError`. `{model_args}`/`{effort_args}` must be an entire argv
  element and splice the rendered list (empty when the value is empty); when `argv` has no such
  element the list is appended at the end. `{model}`/`{effort}` may appear inside an element
  (`model_reasoning_effort={effort}`).
- `model` and `effort` match `^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$` or are empty; a non-empty
  effort must be in `efforts`. Empty model → `model_args` dropped (the agent's own default).
- The function returns a list; nothing joins it into a string anywhere.

Launch environment (`launch_env(profile, have_secrets, base_url) -> list[str]`, `KEY=VALUE`
items for `docker run -e`):
- every `[env]` item;
- `DELEGATE_AGENT_SECRETS=ENV=name ENV2=name2` for the `[secrets_env]` entries whose secret is in
  `have_secrets`; when the profile has `[secrets_env]` and none is granted → `AgentError("agent
  NAME needs one of these grant secrets: a, b")`;
- when `api.base_url_env` and `base_url` are set: `DELEGATE_AGENT_BASE_URL_ENV=<env>` and
  `DELEGATE_AGENT_BASE_URL=<url>` (the launcher exports it);
- never a secret value (it has none to give).

Proxy decision (`proxy_plan(profile, have_secrets, upstream) -> dict | None`): `{"upstream",
"dialect", "base_url_env"}` when `api.base_url_env` is set and the secret mapped to
`api.proxy_key_env` is in `have_secrets`; else `None`.

Version check: `version_checked(profile, version_text) -> bool | None` — `None` when the text is
empty; true when any `tested_versions` entry is a prefix of the first whitespace-separated token
that starts with a digit; else false.

Parsers (`summarize(fmt, path) -> dict`), untrusted input:
- Read at most 512 MiB; a line over 4 MiB, or not a JSON object, is counted in
  `unparsed_lines` and skipped; never raises on content (only on a missing file → empty summary).
- Common result keys: `steps`, `tool_calls`, `tools` (name → count), `tool_errors` (list of
  `"name: <≤240 chars, newlines → spaces>"`, at most 50), `errors` (list, at most 20, ≤300 chars
  each), `input_tokens`, `output_tokens`, `reasoning_tokens`, `cache_read`, `cache_write` (ints or
  `None` when the stream carried no usage), `final_text` (≤ 20 000 chars), `model_reported`,
  `agent_version`, `success` (`True`/`False`/`None`), `session`, `unparsed_lines`.
- `claude-stream` (documented shapes; only `system/init` was observed live on 2.1.325):
  `system`/`init` → `model_reported = model`, `agent_version = claude_code_version`, `session =
  session_id`; `system`/`api_retry` → one `errors` entry `api_retry: <error_status>`;
  `assistant` → `message.id` distinct ids are `steps`; its `message.usage` (last seen per id)
  summed into tokens (`cache_read_input_tokens` → `cache_read`, `cache_creation_input_tokens` →
  `cache_write`) unless a `result` event carries `usage`, which then wins; each `tool_use` content
  block (distinct `id`) counts a call under its `name`; `user` → each `tool_result` with
  `is_error: true` is a tool error named by its `tool_use_id`'s tool, message from its `content`
  (str, or the text of its text blocks); `result` → `success = (subtype == "success" and not
  is_error)`, `final_text = result` (str). No `result` event → `success = None`, `final_text` =
  the last assistant text block.
- `codex-json` (documented, **unverified**): `thread.started` → `session = thread_id`;
  `turn.completed` → `steps += 1`, `usage.input_tokens`, `usage.output_tokens`,
  `usage.cached_input_tokens` (→ `cache_read`), `usage.reasoning_output_tokens` if present (→
  `reasoning_tokens`) summed; `item.completed` with `item.type` in `command_execution`,
  `file_change`, `mcp_tool_call`, `web_search` counts a call under that type; a
  `command_execution` with non-zero `exit_code` or `status == "failed"` is a tool error
  (`command_execution: <command, ≤240>`); the last `agent_message` item's `text` is `final_text`;
  `turn.failed`/`error` → an `errors` entry and `success = False`; otherwise `success = True` when
  at least one `turn.completed` was seen, else `None`.
- `none`: every key empty/`None`, `steps = 0`.

CLI (`python3 lib/agents.py SUB`): `list`; `show NAME` (the profile as JSON plus `source`,
`verified`, and the argv rendered with model `MODEL` and the first effort); `argv NAME --model M
--effort E` (argv NUL-separated, for `mapfile -d ''`); `env NAME --have "a b" [--base-url URL]`
(one `KEY=VALUE` per line); `proxy NAME --have "a b" --upstream URL` (one line `upstream dialect
base_url_env`, or nothing); `version-checked NAME FILE` (`true|false|null`); `summarize FMT FILE`
(JSON). Errors: `delegate: agents: <message>` on stderr, exit 2.

### Shipped profiles — create

- `agents/delegate.toml`: `name = "delegate"`, `kind = "delegate"`.
- `agents/claude-code.toml`: the design's TOML example verbatim (plus
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"` in `[env]`), a header comment saying which
  flags were checked against which version.
- `agents/codex.toml`: `kind = "command"`, `verified = false`, argv `["codex", "exec", "--json",
  "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check", "{model_args}",
  "{effort_args}", "-"]`, `model_args = ["--model", "{model}"]`, `effort_args = ["-c",
  "model_reasoning_effort={effort}"]`, `efforts = ["minimal", "low", "medium", "high"]`,
  `version_argv = ["codex", "--version"]`, `tested_versions = []`, `output = "codex-json"`,
  `[secrets_env] CODEX_API_KEY = "openai-api-key"`, `[api] base_url_env = "OPENAI_BASE_URL"`,
  `default_upstream = "https://api.openai.com/v1"`, `proxy_key_env = "CODEX_API_KEY"`,
  `dialect = "openai"`; a header comment: "UNVERIFIED — codex was not installed when this was
  written; check every flag against `codex exec --help` before relying on it."

### `bin/delegate`

- `agent)` case: `agent list` / `agent show NAME` → `lib/agents.py`. `usage()` lines.
- Config: `: "${DELEGATE_AGENTS_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/delegate/agents}"` and
  `: "${DELEGATE_AGENT_IMAGE:=delegate-agents:local}"`, exported to the lib calls.

### Tests

- `tests/test_agents.sh` — create. Fixtures under `mktemp -d`; the owner agents dir points there.
  At least: shipped profiles all load; `show claude-code` argv equals the design's list with
  `--model MODEL --effort low` spliced at the placeholders; codex argv ends with `-` after the
  spliced args; empty model drops `--model`; each refusal — unknown key, `{prompt}` placeholder,
  `{model_args}` inside a longer element, model `a b`, model `$(id)`, effort not in `efforts`,
  `[env] PATH = "x"`, `[env] DELEGATE_X = "y"`, `[secrets_env] HOME = "s"`, `proxy_key_env` not in
  `secrets_env`, `default_upstream = "https://u:p@h"`, group-writable owner file, name ≠ stem;
  owner profile overrides shipped; `env` output has `DELEGATE_AGENT_SECRETS` with only granted
  names, errors when none granted, never contains a secret value (fixture secret file with a
  sentinel); `proxy` prints a line only with the API-key secret; `version-checked` true/false/null.
  Parsers: write fixture streams in the test — a claude stream with init, two assistant messages
  (one repeated id across two events), a tool_use + error tool_result, an api_retry, and a result
  with usage → exact counts and tokens (result usage wins); the same without a result event →
  summed per-id usage, `success` null; a codex stream with two turns, one failed command → counts;
  garbage lines, a 5 MiB line and a JSON array line → `unparsed_lines` 3, no exception; a missing
  file → empty summary.
- `tests/test_grants.sh` — add cases (do not change existing ones): `[secrets]` parse; the mount
  arg `/run/secrets/grant/<name>:ro` in `docker-args`; `secrets` subcommand lists names; `summary`
  names only and no file content anywhere in any output (sentinel); symlinked secret, missing
  file, group-writable file, relative path, bad name, same name in two grants, native runner →
  each refused with the stated reason.

## Out of scope

- Using any of this in a round (B4), the proxy (B5), the image (B4). Do not modify
  `bin/delegate` beyond the `agent` case, config lines and `usage()`; no change to
  `run_worker_*`, `lib/report.py`, `worker/*`.

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check blames untracked deliverables; the harness
commits before the chain's verify runs. If that is the only failure mid-round, report it; never
edit that test.

```bash
set -o pipefail && bash -n bin/delegate && python3 -m py_compile lib/*.py && [ -f tests/test_agents.sh ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && ! git diff --name-only delegate/b-2-endpoints-effort | grep -qvE '^docs/specs/b-|^bin/delegate$|^lib/agents\.py$|^lib/grants\.py$|^agents/(delegate|claude-code|codex)\.toml$|^docs/grants\.md$|^tests/test_(agents|grants)\.sh$' && echo GATE-OK
```

## Report format

```text
STATUS: done|partial|blocked
SUMMARY: <=3 sentences
TESTS: <counts; which suites ran; gate result>
RISKS: <what might still be wrong>
DEVIATIONS: <departures from this spec and why, or none>
```
