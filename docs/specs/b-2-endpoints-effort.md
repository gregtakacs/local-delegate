# Task B2: per-run endpoint and reasoning effort for delegate mode

`"hard": true` — this step changes which key file is mounted into the worker container and which
hosts the egress proxy allows: sandbox code (AGENTS.md). Every change below is confined to the
functions named; the reviewer reads them in full. Slice B step 2 of 10 (`docs/specs/b-design.md`
§Credentials "Delegate mode, per-run endpoint", Owner question 5).

## Goal

Let a benchmark choose the endpoint, model and reasoning effort of each delegate-mode run:
`delegate run --endpoint NAME --model M --effort E`. The endpoint comes from an owner-written
endpoints file (same trust rule as grants), is pinned with no fallback, and its key file is the
one mounted for that task; the effort reaches opencode as the model's `reasoningEffort` option.

## Read first

- `docs/specs/b-design.md` §Credentials, §Trust and security summary.
- `lib/grants.py` — `check_owned`, `grant_path`, `fail`, `load_grant` (the ownership rule and the
  tomllib/3.11 handling to copy exactly).
- `bin/delegate` — config block (~55-90: `DELEGATE_API_KEY_FILE`, `expand`), `need_config`,
  `pick_base_url`, `url_hosts`, `ensure_egress`, `cmd_run` (option parsing, `BASE_URL=` ~line
  838, the meta.env write block), `load_task`, `cmd_continue`, `run_worker_docker` (the
  `/run/secrets/delegate_key` mount and the `-e DELEGATE_*` list), `run_worker_native`,
  `usage()`, `main()`.
- `lib/render-opencode-config.py` — `model_entry`.
- `tests/test_grants.sh`, `tests/test_render.sh` — house style; how they build temp grant dirs.

## Contract

### `lib/endpoints.py` — create (stdlib; Python 3.11+ only where tomllib is needed, same message as grants.py)

- Path: `$DELEGATE_ENDPOINTS`, default `${XDG_CONFIG_HOME:-~/.config}/delegate/endpoints.toml`.
- Ownership: the file and its folder pass `grants.check_owned` (import it from `lib/grants.py`; do
  not copy it). A missing file = no endpoints (not an error) unless a name is asked for.
- Format: one table per endpoint; table names `[a-z0-9][a-z0-9._-]{0,47}`; keys exactly
  `base_url` (must start `http://` or `https://`, no whitespace, no `@` before the host, no
  query or fragment) and `key_file` (`~` expanded; must be absolute after expansion). Unknown keys
  → error. The key file must exist and pass `check_owned` at **resolve** time, never at list time.
- CLI: `python3 lib/endpoints.py resolve NAME` → prints two lines, `base_url` then `key_file`;
  `python3 lib/endpoints.py hosts` → every endpoint's host, one per line (no error when the
  file is missing: prints nothing); `python3 lib/endpoints.py list` → `NAME  BASE_URL  key:
  readable|missing` per line. Errors: one line `delegate: endpoints: <message>` to stderr, exit 2.
  It never prints or reads key-file **content**.

### `bin/delegate`

- Config: `: "${DELEGATE_ENDPOINTS:=${XDG_CONFIG_HOME:-$HOME/.config}/delegate/endpoints.toml}"`,
  expanded like the other paths.
- `url_hosts`: also emits every host from `lib/endpoints.py hosts` (deduplicated with the
  existing ones), so the shared egress proxy's allow list and fingerprint are the same for every
  run whatever endpoint it picks. A broken endpoints file makes `url_hosts` warn once and emit
  only the `DELEGATE_BASE_URLS` hosts (never die inside the proxy setup).
- `cmd_run`: new options `--endpoint NAME` and `--effort E`.
  - `--endpoint`: resolve via `lib/endpoints.py resolve`; set `DELEGATE_API_KEY_FILE` to its key
    file and `DELEGATE_BASE_URLS` to its `base_url` **before** `need_config`; `BASE_URL` comes
    from `pick_base_url` over that single URL, and a non-answer dies with
    `endpoint NAME (<url>) did not answer /models with its key` — never a fallback to another URL.
  - `--effort`: must match `^[a-z]{1,16}$` else die `--effort: one lowercase word, e.g. high`.
  - meta.env block: add `ENDPOINT=%q` and `REASONING_EFFORT=%q` (empty when not given).
- `load_task` (or wherever a continued task re-establishes `DELEGATE_API_KEY_FILE`/`BASE_URL`):
  when `ENDPOINT` is non-empty, re-resolve it the same way (a removed endpoint dies with its name);
  `cmd_continue` therefore keeps the task's endpoint and effort. `--endpoint` and `--effort` are
  **not** accepted by `continue` (die: "a task keeps the endpoint and effort it was run with").
- `run_worker_docker` and `run_worker_native`: pass `DELEGATE_REASONING_EFFORT="$REASONING_EFFORT"`
  (empty when unset) next to `DELEGATE_REASONING`. The key mount line itself does not change — it
  already mounts `$DELEGATE_API_KEY_FILE`, which `--endpoint` has set.
- `delegate endpoint list` → `lib/endpoints.py list`. `usage()` lines for `--endpoint`,
  `--effort` and `endpoint list`.

### `lib/render-opencode-config.py`

- `model_entry`: when `DELEGATE_REASONING_EFFORT` is non-empty, add
  `"options": {"reasoningEffort": <value>}` to every model entry. Empty → no `options` key (the
  rendered config for today's runs is byte-for-byte unchanged; `tests/test_render.sh` must keep
  passing untouched).

### `config.example.env`, `docs/reference.md`

- Document `DELEGATE_ENDPOINTS`, the file format (placeholder URL `https://llm.example.com/v1`,
  placeholder names `local-a`), `--endpoint`, `--effort`, `delegate endpoint list`.

### `tests/test_endpoints.sh` — create

Offline; temp `XDG_CONFIG_HOME`; a stub `/models` endpoint like `tests/e2e-rig.sh`'s (copy the
pattern, or source the rig) on 127.0.0.1. At least:
1. resolve / hosts / list on a good file; `list` never prints key content (write a key file
   containing a sentinel string and assert it is absent from all outputs and from meta.env).
2. Refusals: group-writable file, file owned by someone else is not testable as non-root — test
   group/world-writable file and folder; unknown key; bad name; `base_url` with `user@host`,
   with a query, `ftp://`; relative `key_file`; missing key file at resolve.
3. `url_hosts` includes an endpoint host, deduplicated, and still works (DELEGATE_BASE_URLS hosts
   only, one warning) with a broken endpoints file. Call it by sourcing nothing: run
   `bin/delegate` through a tiny test hook is not available — test it with
   `bash -c 'source <(sed -n "/^url_hosts()/,/^}/p" bin/delegate); ...'` or an equivalent that
   exercises the real function text.
4. `delegate run --endpoint NAME` against the stub with `DELEGATE_RUNNER=native` and a stub
   `opencode` on PATH (a script that writes one `step_finish` event and exits 0): meta.env has
   `ENDPOINT=NAME`, the rendered `opencode.json` in the task home has the stub URL as `baseURL`,
   the key file's path as `apiKey` `{file:...}`; with `--effort high` both model entries carry
   `options.reasoningEffort == "high"`; without it no `options` key.
5. `--endpoint NAME` whose URL does not answer → non-zero exit, the message names the endpoint,
   and no task dir with a round was created; a second endpoint that answers is never tried.
6. `delegate continue ID --endpoint x` and `--effort x` die with the stated message.

## Behaviour and edge cases

- No `--endpoint`: everything exactly as today (config key file, `DELEGATE_BASE_URLS` rotation).
- `--endpoint` with `--here`: allowed (native, the key file path is only read by opencode).
- The endpoints file is read by host code only; it is never mounted.

## Out of scope

- Agent rounds (B4). Grants. The egress image. Do not modify `lib/grants.py` (import from it),
  `worker/*`, any existing test.

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check blames untracked deliverables; the harness
commits before the chain's verify runs. If that is the only failure mid-round, report it; never
edit that test.

```bash
set -o pipefail && bash -n bin/delegate && python3 -m py_compile lib/*.py && [ -f tests/test_endpoints.sh ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && ! git diff --name-only delegate/b-1-bench-core | grep -qvE '^docs/specs/b-|^bin/delegate$|^lib/endpoints\.py$|^lib/render-opencode-config\.py$|^config\.example\.env$|^docs/reference\.md$|^tests/test_endpoints\.sh$' && echo GATE-OK
```

## Report format

```text
STATUS: done|partial|blocked
SUMMARY: <=3 sentences
TESTS: <counts; which suites ran; gate result>
RISKS: <what might still be wrong>
DEVIATIONS: <departures from this spec and why, or none>
```
