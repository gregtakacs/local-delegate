# Task B4: telemetry libraries — the logging proxy and the file timeline (pure stdlib)

`"hard": true` — a proxy that carries the owner's API keys in transit and parses untrusted
response bodies. Slice B step 4 of 10, chain segment 1 (`docs/specs/b-design.md` §Telemetry,
R13). R19: this step writes the two programs and their offline tests only. Starting the proxy as
a container on a task network is the orchestrator's `llmlog_start` (`b-o1-sandbox`); wiring the
file timeline into rounds is B5. No change to `bin/delegate` at all.

## Goal

Two standalone stdlib programs: `lib/llmlog.py`, a pass-through logging proxy that records each
model request's timing and token usage and never a header or a body, and `lib/filetimeline.py`,
a poller that records when files in a work tree changed and summarizes it.

## Read first

- `docs/specs/b-design.md` §Telemetry (all three sources).
- `lib/progress.py` — a long-running stdlib side process in this repo (`--ppid` handling).
- `tests/test_ledger.sh` — house style for a Python-lib suite.

## Contract

### `lib/llmlog.py` — create (stdlib only)

`python3 llmlog.py serve --listen HOST:PORT --upstream URL --dialect anthropic|openai --log FILE
[--via http://HOST:PORT] [--port-file FILE]`:
- `ThreadingHTTPServer`, `protocol_version = "HTTP/1.1"`, every method. Port 0 allowed; the bound
  port is written to `--port-file` when given.
- Forwards only to `--upstream`'s origin; the request path (must start with `/`) is appended to
  the upstream's path prefix only when it does not already start with it (document the rule in
  the module docstring; the agent's base URL is the sidecar origin + the upstream path).
  Absolute-URI request lines and `CONNECT` → `405`, logged with `error: "refused"`.
- Upstream connection: `https` upstream with `--via` → `HTTPSConnection(via host, via port)` +
  `set_tunnel(upstream host, port)`, default SSL context (verification on); `http` upstream with
  `--via` → absolute-URI request to the via proxy; no `--via` → direct. Never reads
  `HTTP(S)_PROXY` from the environment (explicit only).
- Request: body by `Content-Length` (≤ 64 MiB, else `413`) or chunked (decoded, same cap);
  headers forwarded except hop-by-hop (`Connection`, `Keep-Alive`, `Proxy-*`, `TE`, `Trailer`,
  `Transfer-Encoding`, `Upgrade`) and `Host` (set to the upstream's); `Accept-Encoding` replaced by
  `identity`.
- Response: status and headers passed through minus hop-by-hop; body streamed in chunks as it
  arrives (`read1`), with `Content-Length` when upstream gave one, else chunked to the client. A
  client disconnect closes the upstream connection.
- Usage reading on a tee of the body, never altering it: `text/event-stream` → SSE `data:` lines
  (a line over 1 MiB is dropped, not buffered); JSON → a copy up to 8 MiB parsed at the end.
  `anthropic`: `message_start.message.usage` (`input_tokens`, `cache_read_input_tokens`,
  `cache_creation_input_tokens`, `output_tokens`), then the last `message_delta.usage.output_tokens`;
  non-stream: top-level `usage` with the same names. `openai`: chat-completions `usage`
  (`prompt_tokens`, `completion_tokens`, `prompt_tokens_details.cached_tokens`,
  `completion_tokens_details.reasoning_tokens`) in the JSON or the stream's last chunk carrying it;
  Responses API `response.completed` event / non-stream body `usage` (`input_tokens`,
  `output_tokens`, `input_tokens_details.cached_tokens`, `output_tokens_details.reasoning_tokens`).
  Anything unreadable → `usage: null`.
- Log: one compact JSON line per request, appended and flushed at its end: `start_ms`,
  `first_byte_ms`, `end_ms`, `method`, `path` (no query string), `status`, `stream` (bool),
  `model` (the request JSON's top-level `model` if a str ≤ 128 chars, else null), `usage`
  (`{input, output, cache_read, cache_write, reasoning}` or null), `bytes_in`, `bytes_out`,
  `error` (an exception class name or `refused`/`too_large`, else null). **Never** a header, a
  query string, a request or response body, or any part of one beyond those fields. The log stops
  growing at 64 MiB (later requests are counted on a final `{"dropped": n}` line at shutdown).
- `SIGTERM` → stop accepting, finish in-flight writes, exit 0.

`python3 llmlog.py summary FILE` → JSON `{"requests", "errors" (status ≥ 400 or error set),
"first_ms", "last_ms", "input", "output", "cache_read", "cache_write", "reasoning", "models"
(distinct, ≤ 10)}`; a missing/empty file → `{"requests": 0}` and nulls.

### `lib/filetimeline.py` — create (stdlib only)

- `watch --root DIR --out FILE [--interval S (default 1.0, min 0.2)] --stop-file F [--ppid PID]`:
  baseline stat walk at start (no events), then every interval a walk (`os.scandir`, no symlink
  following; skip dirs named `.git`, `node_modules`, `.venv`, `__pycache__`, and the `.git` file)
  comparing `(mtime_ns, size)` per regular file; appends `{"t_ms", "op": "add"|"mod"|"del",
  "path" (relative), "size", "delta" (size change)}` lines, flushed per walk. Caps: 50 000 files
  per walk (then the walk stops early and one `{"t_ms", "op": "truncated", "what": "files"}` is
  written once), 200 000 events (then one `truncated` `events` line and no more events). Exits on
  the stop file, or when `--ppid` is gone, after one final walk.
- `summary FILE --start EPOCH_S --end EPOCH_S` → JSON `{"first_edit_s", "last_edit_s",
  "idle_tail_s", "churn_events", "churn_bytes" (sum of |delta|), "files_touched", "rewrites" (paths
  with ≥ 3 `mod` events), "truncated" (bool)}`; times relative to start, rounded to 0.1 s; no
  events → zeros for counts and nulls for times.

### `tests/test_bench_telemetry.sh` — create

Offline. A fake upstream (Python `http.server` written by the test) serving: an Anthropic
non-stream JSON with `usage`; an Anthropic SSE stream of `message_start` / two deltas /
`message_delta` with a 1 s pause between events; an OpenAI chat stream whose last chunk has
`usage`; a Responses-API stream ending in `response.completed`; a 500; and an endpoint that
records the request headers it received. The proxy runs locally on port 0. At least:
1. Response bodies through the proxy are byte-identical to direct ones for all five.
2. Log lines: one per request, usage numbers exact per dialect, `stream` right, `status` 500 →
   counted in `summary.errors`.
3. Streaming is not buffered: the first SSE event reaches the client before the upstream has sent
   the second (time it).
4. Sent `Authorization: Bearer SENTINEL-A`, `x-api-key: SENTINEL-A`, a query `?k=SENTINEL-Q` and a
   body containing `SENTINEL-B`: no sentinel in the log file or the summary; the recording endpoint
   received the auth headers unchanged and `Accept-Encoding: identity`.
5. Absolute-URI request line and `CONNECT` → 405 and `error: "refused"`; a request with a forged
   `Host:` still reaches only the configured upstream.
6. `--via` to a fake forward proxy written in the test (absolute-URI HTTP) for an `http` upstream:
   the request goes through it. (The TLS tunnel path is checked live in Phase 3.)
7. Body over 64 MiB → 413 (generate it streaming, don't hold 64 MiB twice).
8. `SIGTERM` → exit 0 within 3 s.
9. `filetimeline.py watch` on a temp dir with a scripted writer (add, modify ×3, delete, a file
   under `node_modules/` and `.git/` that must not appear): events and `summary` numbers exact
   (`rewrites` 1, `files_touched` 2…); stop file honoured; `--ppid` of a dead PID exits.

## Out of scope

- Any container launch or round wiring (O1, B5). Do not modify `bin/delegate`, `lib/report.py`,
  `lib/agents.py`, `lib/grants.py`, `worker/*`, or existing tests.

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check blames untracked deliverables; the harness
commits before the chain's verify runs. If that is the only failure mid-round, report it; never
edit that test. The **cage check** fails if this step changed any sandbox function or file
(R19: orchestrator code; `docs/specs/b-design.md` §Who writes what) — never "fix" it by editing
the check; leave the sandbox code alone and report what you needed under DEVIATIONS.

```bash
set -o pipefail && bash -n bin/delegate && python3 -m py_compile lib/*.py && [ -f tests/test_bench_telemetry.sh ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && for fn in run_worker run_worker_docker run_worker_native ensure_network ensure_egress ensure_task_egress host_args read_mount_args make_guard_shims; do cmp -s <(git show bench:bin/delegate | sed -n "/^$fn() {/,/^}/p") <(sed -n "/^$fn() {/,/^}/p" bin/delegate) || { echo "CAGE CHANGED $fn (R19: orchestrator code)"; exit 1; }; done && { git diff --quiet bench -- lib/grants.py worker/egress.Dockerfile worker/egress-entrypoint.sh worker/entrypoint.sh lib/render-opencode-config.py worker/agent-launch || { echo "CAGE CHANGED files (R19: orchestrator code)"; exit 1; }; } && ! git diff --name-only delegate/b-3-agent-profiles | grep -qvE '^docs/specs/b-|^lib/llmlog\.py$|^lib/filetimeline\.py$|^tests/test_bench_telemetry\.sh$' && echo GATE-OK
```

## Report format

```text
STATUS: done|partial|blocked
SUMMARY: <=3 sentences
TESTS: <counts; which suites ran; gate result>
RISKS: <what might still be wrong>
DEVIATIONS: <departures from this spec and why, or none>
```
