# B design: benchmarks — models, own-harness agents, blind pluggable reviewers (R9–R17)

Slice B of `docs/specs/bench-rulings.md`. This file is the design; `b-<n>-*.md` are the step
specs; `b-chain.json` is the chain plan. B builds on slice T (`docs/specs/t-design.md`): every
result is a row in T's ledger (`lib/ledger.py`: `append`, `read_rows`, `KINDS`), never a second
store (R2–R8 are T's). B's chain starts from `bench` after T is squashed onto it.

## Goal

Run a fixed task bundle (R9) many times (R10) under named **conditions** — the delegate worker on
a chosen endpoint/model/effort, or a standalone agent in its own harness (R11) — score each run
outside the sandbox after it ended (R12), record what telemetry each harness can give (R13), and
have pluggable agents review the results blind (R15), with the reviewers themselves scored
against seeded ground truth and against each other (R16). One report command reads it all back
from the ledger as medians and spread.

## Ruling map

| ruling | this design | step |
|---|---|---|
| R9 bundle | `evals/cases/<case>/` unchanged in shape (case.env, setup.sh, spec.md, hidden/); case.env is **parsed, never sourced**; a bundle is identified by `case_hash` (content hash of its dir); review bundles live in `evals/review-cases/<case>/` with the same shape plus `change/` and `truth.json` | B1, B8 |
| R10 several runs | a bench **plan** names cases × conditions × `repeat` (default 3); runs are interleaved in a seeded shuffled order; the report shows n, median, p25–p75, min–max per group and hides groups below `--min-n` (default 3) | B1, B7, B10 |
| R11 two modes | `mode:"delegate"` = `delegate run` with `--endpoint/--model/--effort` per run; `mode:"own-harness"` = `delegate run --agent NAME`: the same task machinery (worktree, task network, egress proxy, timeout, grants), a different program in the container, one prompt, no nudges, no continue | B2, B3, B4 |
| R12 scoring after, on a copy | `delegate score`: refuses while the task's agent container or round lock exists; copies the final tree out; runs hidden checks, then the visible verify, each on its own copy, in a fresh **scorer** container with no credentials, no grants, no shared caches; hidden/ is never under any path a task container mounts (B7 checks it before every run) | B6, B7 |
| R13 telemetry | (a) `lib/llmlog.py`, a pass-through logging proxy sidecar on the task network, when the agent profile names a base-URL variable and the run's grant supplies the profile's API-key secret; (b) the harness's own output parsed by `lib/agents.py` (`claude-stream`, `codex-json`), each parser with the versions it was checked against; (c) always, `lib/filetimeline.py`, a host-side poller of the worktree; empty stays empty; every row carries `mode` | B3, B5 |
| R14 auto-approve only in the sandbox; creds only via owner grants | `--agent` refuses the native runner and `--here`; agent profiles carry the auto-approve flags, so they only ever run inside `run_worker_docker`; a new grant table `[secrets]` mounts owner-named files read-only at `/run/secrets/grant/<name>`; the in-container launcher turns them into the env vars the profile names; delegate code never writes a grant (tests run against temp grant dirs) | B3, B4 |
| R15 blind review | reviewers get a **subject** id (`s-<10 hex>`), a fresh two-commit repo (fixture, then the sanitized final tree) under a path that names no session, plan, model or agent, and the spec; the `verdict` row is appended first; a `match` row (subject → run or review case) is appended only after every verdict of the batch | B9 |
| R16 reviewers pluggable + benchmarked | a reviewer is a condition like a worker (delegate worker or any agent profile); review cases with seeded defects at known file/line ranges plus clean changes give recall, false positives, verdict accuracy; on real runs, pairwise agreement between reviewers and agreement with the hidden checks; one report table compares reviewer conditions | B8, B9, B10 |
| R17 lost history | bundles are rebuilt by `setup.sh` from files, never from a commit; a case whose setup fails is reported `setup-failed` and skipped, never rescued | B7 |

## Architecture in one picture

```
delegate bench run PLAN ──► for each (repeat, case, condition), in seeded shuffled order:
   lib/bench.py               1. fixture repo  ← bash setup.sh (host, as evals/run.sh does today)
                              2. leak guard    ← no hidden/ file content inside the fixture or any mount
                              3. delegate run  ← mode delegate: --endpoint E --model M --effort X --verify V
                                                 mode own-harness: --agent A --model M --effort X [--grant G]
                                 (bin/delegate: worktree, task network, egress, timeout, grants;
                                  DELEGATE_FILE_TIMELINE=1 → lib/filetimeline.py beside the round;
                                  own-harness + API key → lib/llmlog.py sidecar on the task network)
                              4. delegate score ← copy out, hidden checks, verify, in a scorer container
                              5. ledger append  ← one `benchmark` row
delegate bench review SESSION ──► subjects (runs + review cases) → reviewer tasks → `verdict` rows
                                  → then `match` rows
delegate bench report [...] ──► tables from `benchmark` / `verdict` / `match` rows
```

Everything that starts a container stays in `bin/delegate` (bash), next to the code it must match;
everything that parses, plans and aggregates is stdlib Python in `lib/`.

## Bundles (R9, R17)

Work case — `evals/cases/<case>/`, unchanged: `case.env` (`VERIFY=`, `SERVICE=`, `TIMEOUT=`),
`setup.sh` (builds the start repo in `$1`, may read `$2` = the case dir), `spec.md` (the prompt),
`hidden/check.sh` (prints `PASS ...`/`FAIL ...` lines; runs from `<tree>/.eval-hidden/`).

- `case.env` is **parsed** by `lib/bench.py` (`KEY=VALUE` lines, values through `shlex.split`
  with exactly one resulting token; comments and blank lines skipped; unknown keys an error; known
  keys `VERIFY`, `SERVICE`, `TIMEOUT`, `KIND`). Today `evals/run.sh` sources it on the host; a
  bundle is data, not a script that runs on the host outside `setup.sh`.
- `KIND` defaults to `work`; `review` marks a review case (below).
- `case_hash` = sha256 over the case dir: for each regular file in sorted relative-path order,
  `path\0` + sha256(content) + `\n`. Symlinks are an error. It goes in every row so results from
  a changed bundle are never pooled with the old one (the report groups by it).

Review case — `evals/review-cases/<case>/` (B8): `case.env` with `KIND=review`, `setup.sh` (the
base), `change/` (files overlaid on the base to make the after-state; a file named in
`change/.delete` one path per line is removed), `spec.md` (what the change was meant to do),
`truth.json`:

```json
{"verdict": "reject",
 "defects": [{"id": "d1", "file": "slug.py", "start": 12, "end": 14, "severity": "high",
              "what": "one sentence, never shown to a reviewer"}]}
```

and `hidden/check.sh` which proves the truth: on the after-state it prints `FAIL <defect id> ...`
for every seeded defect and `PASS` otherwise; a clean case (`"verdict": "accept"`,
`"defects": []`) prints only `PASS` lines.

## Conditions and plans (R10, R11)

A **plan** is a JSON file the owner writes (it may sit in a repo; it names profiles, endpoints and
grants by name only, and every name resolves through owner-written stores — see Trust):

```json
{
  "name": "nov-models",
  "cases": ["py-semver", "bugfix-duration"],
  "repeat": 3,
  "seed": 7,
  "conditions": [
    {"label": "a-high", "mode": "delegate", "endpoint": "local-a", "model": "model-a", "effort": "high"},
    {"label": "a-rules-old", "mode": "delegate", "model": "model-a", "rules_ref": "HEAD~1"},
    {"label": "cc", "mode": "own-harness", "agent": "claude-code", "model": "model-b",
     "effort": "high", "grants": ["agent-key-b"]}
  ],
  "reviewers": [
    {"label": "rv-cc", "mode": "own-harness", "agent": "claude-code", "model": "model-b", "grants": ["agent-key-b"]},
    {"label": "rv-a", "mode": "delegate", "endpoint": "local-a", "model": "model-a"}
  ],
  "review_cases": "all",
  "review_timeout": 1800
}
```

- `cases`: names or `"all"` (every work case). `review_cases`: names, `"all"` or `[]`.
- A condition's `label` is `[a-z0-9][a-z0-9._-]{0,31}`, unique in its list. `mode` is
  `delegate` or `own-harness`. Delegate mode takes `endpoint` (a name in the endpoints file,
  optional — default: the configured `DELEGATE_BASE_URLS`), `model` (optional — default
  `DELEGATE_MODEL`), `effort` (optional), `rules_ref` (optional git ref of this repo whose
  `opencode/` tree is the worker rules, as `evals/run.sh --rules-ref` today). Own-harness takes
  `agent` (a profile name, required), `model`, `effort` (must be in the profile's `efforts`),
  `endpoint` (optional: the endpoint's `base_url` only, never its key) and `grants`.
- Unknown keys anywhere are an error; `delegate bench check PLAN` validates and prints the run
  matrix without running anything.
- Order: for each repeat 1..N, the case × condition pairs shuffled with `random.Random(seed)`
  (seed recorded in the session); one run at a time. Interleaving spreads time-of-day and load
  effects over conditions; T's `parallel_rounds` records anything else that ran.
- A **session** (`<plan name>-<YYYYmmdd-HHMMSS>`) is one execution of a plan; its state lives in
  `$DELEGATE_STATE/bench/<session>/`; `--session S` resumes it, skipping every (case, condition,
  repeat) that already has a `benchmark` row in the ledger for S.

## Agent profiles (R11, R14, R16) — one abstraction for workers and reviewers

A profile says how to start one agent inside the sandbox. The same profile serves both roles: a
worker condition and a reviewer condition differ only in the prompt and what is read back.

Profiles are TOML files read only from `$DELEGATE_HOME/agents/` (shipped, public, placeholders)
and `$DELEGATE_AGENTS_DIR` (default `~/.config/delegate/agents/`, the owner's; same ownership
rule as grants: file and folder owned by the user, not group/world-writable). Never from a repo,
a worktree, a plan's folder or a spec. An owner file of the same name overrides the shipped one.

```toml
# agents/claude-code.toml
name = "claude-code"                 # must equal the file stem
kind = "command"                     # "command" | "delegate"
image = ""                           # "" = DELEGATE_AGENT_IMAGE (default delegate-agents:local)
argv = ["claude", "-p", "--verbose", "--output-format", "stream-json",
        "--dangerously-skip-permissions", "--no-session-persistence",
        "{model_args}", "{effort_args}"]
model_args = ["--model", "{model}"]  # spliced where "{model_args}" stands; nothing when no model
effort_args = ["--effort", "{effort}"]
efforts = ["low", "medium", "high", "xhigh", "max"]
version_argv = ["claude", "--version"]
tested_versions = ["2.1.325"]        # prefixes the output parser was checked against
output = "claude-stream"             # parser: claude-stream | codex-json | none
[env]                                # plain values only, never secrets
DISABLE_AUTOUPDATER = "1"
[secrets_env]                        # env var in the container  <-  grant secret name
ANTHROPIC_API_KEY = "anthropic-api-key"
CLAUDE_CODE_OAUTH_TOKEN = "claude-oauth-token"
[api]
base_url_env = "ANTHROPIC_BASE_URL"
default_upstream = "https://api.anthropic.com"
proxy_key_env = "ANTHROPIC_API_KEY"  # the logging proxy runs only when THIS variable gets a secret
dialect = "anthropic"                # how the proxy reads usage: anthropic | openai
```

- `kind = "delegate"` (`agents/delegate.toml`) means the delegate worker itself: the normal
  opencode path, `--endpoint/--model/--effort`. Only `name` and `kind` are allowed with it.
- `argv` rendering (`lib/agents.py render`): placeholders `{model}`, `{effort}`, `{model_args}`,
  `{effort_args}` only, anything else in braces is an error (`{{`/`}}` escape); `{model_args}` /
  `{effort_args}` must be whole elements and splice lists (empty when the value is empty); values
  must match `^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$`. The result is an argv list handed to
  `docker run ... IMAGE <launcher> <argv...>` — no shell is involved at any point, on the host or
  in the container.
- The prompt reaches the agent on stdin (`RL_STDIN`, as delegate mode does today), never in argv.
- Shipped: `delegate`, `claude-code` (flags checked against claude 2.1.325's `--help` and a live
  probe this session), `codex` (codex is not installed on the design host: flags from codex's
  documentation, `tested_versions = []`, marked unverified in the file and in `delegate agent show`).

## Credentials (R14)

- **Own-harness agents**: only through a grant the owner writes, via a new grant table:

  ```toml
  [secrets]                       # name -> host file; mounted read-only, never blanked
  anthropic-api-key = "/home/USER/.config/delegate/keys/anthropic.key"
  ```

  Each secret is mounted `-v FILE:/run/secrets/grant/<name>:ro`. Names follow the grant-name rule;
  the file must exist, be a regular file owned by the user and not group/world-writable; the same
  name in two of a task's grants is an error; the native runner refuses a grant with secrets (it
  cannot isolate them). Report, summary and `delegate grant show` list secret **names and host
  paths**, never content. `mounts.ro` stays as it is (it blanks secret-looking names — the reason a
  separate table is needed).
- The in-container launcher (`worker/agent-launch`, the agent image's entrypoint for agent rounds)
  reads `DELEGATE_AGENT_SECRETS="ENV=name ENV2=name2"`, exports each `ENV` from
  `/run/secrets/grant/<name>` when that file exists, exports the profile's plain `[env]`, sets the
  base-URL variable, unsets its own `DELEGATE_AGENT_*` variables, and `exec`s the argv. Secret
  values never appear in a `docker run` command line, `docker inspect`, a log or a report.
- **Delegate mode, per-run endpoint**: an owner-written endpoints file (`$DELEGATE_ENDPOINTS`,
  default `~/.config/delegate/endpoints.toml`, the grants ownership rule):

  ```toml
  [local-a]
  base_url = "https://llm.example.com/v1"
  key_file = "~/.config/delegate/keys/local-a.key"
  ```

  `delegate run --endpoint NAME` pins `BASE_URL` to that entry (its `/models` must answer 200 with
  its key, else the run dies — no fallback to another endpoint) and mounts its `key_file` where
  `DELEGATE_API_KEY_FILE` is mounted today. Every endpoint's host joins the egress allow list
  (`url_hosts`) permanently, so the shared proxy's fingerprint does not flip between runs. For an
  own-harness condition an `endpoint` contributes its `base_url` only; the key still comes from a
  grant.
- Agent rounds never receive the delegate endpoint key, `DELEGATE_BASE_URL` or the worker rules.

## Own-harness round (R11, R13b, R14)

`delegate run SPEC --agent NAME [--model M] [--effort E] [--endpoint E] [--grant G]...` plus the
usual `--repo/--name/--base/--timeout/--verify/--service/--read/--copy`.

- Refused: `DELEGATE_RUNNER=native`, `--here`, `--raw`, `--orb`, `--orb-flash`, `--github`
  ("own-harness agents run only in the docker sandbox (R14)"). `delegate continue` on an agent task
  dies: own-harness runs are one-shot (R11: the prompt is given once).
- `meta.env` gains `MODE=own-harness`, `AGENT`, `AGENT_IMAGE`, `AGENT_MODEL`, `AGENT_EFFORT`,
  `AGENT_ENDPOINT`, `AGENT_UPSTREAM`. `BASE_URL` is the upstream the agent talks to (endpoint
  `base_url`, else the profile's `default_upstream`) — that is what T's round row records as
  `endpoint` (R7).
- Prompt (exact text in B4): the same environment lines delegate mode writes (worktree, evidence
  dir, `$DATABASE_URL`, verify command, network), none of the delegate rules, no closing block, then
  the spec verbatim.
- `do_round`'s agent branch: capture the agent version (`version_argv` in the image), render argv,
  start the telemetry side processes, `run_limited` → `run_worker` with `AGENT_MODE=1`, stdout to
  `$rd/agent.jsonl`; no nudge loop; `finalize_round` as for every round (commit, verify, report),
  with `lib/report.py report --agent-format F --agent-output $rd/agent.jsonl` building the same
  `report.json` keys from the agent's output.
- `run_worker_docker` with `AGENT_MODE=1`: the agent image, `--entrypoint
  /usr/local/bin/delegate-agent-launch`, no delegate key mount, no `DELEGATE_BASE_URL`/`MODEL`/
  rules mounts or env, the same worktree / read-only `.git` / home / evidence / cache mounts, the
  same network arguments, the grants' docker args (now including secrets), and `NO_PROXY` extended
  with the logging sidecar's name.
- Image: `worker/agents.Dockerfile`, `FROM ${BASE}` (the worker image: same OS, toolchain,
  browser, user model), adding the claude and codex CLIs at pinned versions and the launcher.
  `delegate build --agents` builds `DELEGATE_AGENT_IMAGE` with the same stamp label; agent rounds
  check its freshness like the worker image.

## Telemetry (R13)

- **(b) harness output** — `lib/agents.py summarize(fmt, path)` → `{steps, tool_calls, tools,
  tool_errors, errors, input_tokens, output_tokens, reasoning_tokens, cache_read, cache_write,
  final_text, model_reported, success, session}`; `version_checked` is true when the captured
  version starts with one of `tested_versions`, false otherwise, null when unknown. Untrusted
  input: line cap 4 MiB, total cap 512 MiB read, non-JSON lines counted, never raised.
  Delegate mode's (b) is today's opencode events (T's round row and `report.json`).
- **(a) logging proxy** — `lib/llmlog.py serve` in a sidecar `delegate-<id>-llmlog` (the worker
  image, `--entrypoint python3`, the script mounted read-only, only its log dir mounted
  read-write, on the task network, its upstream reached through the same egress proxy as
  everything else). It forwards to the **one** configured upstream origin only (absolute-URI
  requests and `CONNECT` get 405), passes headers through (minus hop-by-hop; `Accept-Encoding:
  identity` so usage can be read), streams the response through unchanged, and logs per request:
  `start_ms, first_byte_ms, end_ms, method, path` (no query), `status, stream, model` (request's
  top-level `model` string), `usage` (`input, output, cache_read, cache_write, reasoning`), byte
  counts, and an exception class name on failure. Never a header, never a body. It holds no key:
  the agent's own key passes through in the request headers.
  Started only when the profile has `[api] base_url_env` and the round's grants provide the secret
  mapped to `proxy_key_env`; otherwise (b)/(c) only, and the `llm_*` fields stay empty. Not in
  `host` network mode.
- **(c) file timeline** — `lib/filetimeline.py watch` on the host, every `DELEGATE_FILE_TIMELINE_S`
  (default 1) seconds: a stat walk of the worktree (skipping `.git`, `node_modules`, `.venv`,
  `__pycache__`), events `{t_ms, op: add|mod|del, path, size, delta}` to `$rd/files.jsonl`;
  caps: 50 000 files, 200 000 events (then one `truncated` event). `summary` → `first_edit_s`,
  `last_edit_s`, `idle_tail_s` (round end − last edit), `churn_events`, `churn_bytes`,
  `files_touched`, `rewrites` (files modified ≥ 3 times). Polling misses writes inside one interval;
  that is stated, not hidden. On for every round when `DELEGATE_FILE_TIMELINE=1`, which
  `delegate bench` sets (both modes, so the timeline compares like with like).

## Scoring (R12)

`delegate score ID --hidden DIR --out DIR [--verify CMD] [--timeout S]` (B6):

1. Refuses while the task's round lock is held or any `delegate-<id>-r*` container exists.
2. `out/final/`: the worktree copied out (`tar` excluding `./.git`), kept pristine for review;
   `out/evidence/`: the task's evidence copied.
3. Hidden: `out/hidden-tree/` = copy of final + `hidden/` copied to `.eval-hidden/`; `bash
   .eval-hidden/check.sh` in a **scorer** container (tag `s1`); `hidden.log`; PASS/FAIL counted.
4. Verify: `out/verify-tree/` = a fresh copy of final; the verify command (tag `s2`); `verify.log`.
5. `out/score.json`: `hidden_pass, hidden_fail, hidden_total, hidden_rc, hidden_s, verify_rc,
   verify_s, hidden_timed_out, verify_timed_out`. The copies are deleted after, `final/` kept.

Scorer container: the worker image with `--entrypoint bash` (the worker entrypoint needs a model
endpoint the scorer must not have), `--user` as the worker, the task network with the same mode as
the task, the copy mounted read-write at its own path, a scratch home, the evidence copy
read-only as `DELEGATE_EVIDENCE_DIR`, a **fresh** postgres sidecar per pass when the case has
`SERVICE=postgres` (`delegate-<id>-spg`, removed after). No key mount, no grants, no rules, no
shared caches (the agent could have written them). Native runner: the same steps natively in the
copy with a scratch `HOME` (the native runner already trusts the code it runs). The agent's code
does execute during scoring — in a sandbox holding nothing worth taking.

## Review (R15, R16)

`delegate bench review SESSION [--reviewers a,b] [--cases-only] [--runs-only]` (B9):

1. **Subjects**: one per scored run of the session (its `final/` tree) and one per review case in
   the plan's `review_cases`. Subject id `s-<10 hex>`; the subject→target map is held in
   `$DELEGATE_STATE/bench/<session>/reviews/<batch>/subjects.json` (mode 600) until step 4.
2. **Blind repo** per subject at `$DELEGATE_STATE/bench-review/<subject>/repo` (no session, plan,
   model or agent in any path): commit 1 = the fixture (work) or base (review case), commit 2 =
   the sanitized after-tree; author `bench <bench@localhost>`, both dates fixed at
   `2000-01-01T00:00:00Z`, messages `base` and `change`. Sanitizing drops `.git`, `node_modules`,
   `.venv`, `__pycache__`, `.eval-hidden`, `.claude/`, `.codex/`, `.opencode/`, `.delegate*`, and
   `CLAUDE.md`/`AGENTS.md` unless present in the base.
3. **Reviewers**: for each subject × reviewer condition, a delegate task on the blind repo
   (`delegate run` with the reviewer's mode/agent/endpoint/model/effort/grants, `--name rv`,
   no `--verify`, `review_timeout`) with the review prompt (verbatim in B9). The reviewer writes
   `REVIEW-VERDICT.json` at the repo root. Bench reads it from the worktree with `lstat` (regular
   file only, ≤ 256 KiB), validates it, and appends one `verdict` row — invalid or missing files are
   recorded as `verdict:"invalid"`/`"missing"` with the reason, never dropped.
4. **Match**: only after every verdict of the batch is appended, one `match` row per subject.

Scores are computed by the report from the rows: on review cases, a finding hits a defect when the
file is equal and its line lies in `[start-3, end+3]` (a finding without a line never hits);
recall = defects hit / defects; false positives = findings hitting no defect (all findings on a
clean case), also counted for high+medium only; verdict accuracy = verdict equals the truth
(invalid/missing count as wrong). On real runs: pairwise verdict agreement among reviewers of the
same subject, and agreement with the hidden checks (`accept` ⇔ every hidden check passed).

## Row schemas (T's ledger; `kind` and `schema` first, `ts` last)

T1 already registers `benchmark:1` and `verdict:1`; B1 adds `match:1` to `KINDS`. Empty means
the source did not give it (`""`, `null`, never a guess).

### `kind:"benchmark"` — one per worker run (B7), field order

`run_id` (`b-<12 hex>`), `session`, `plan`, `case`, `case_hash`, `repeat`, `condition` (label),
`mode` (`delegate` | `own-harness`), `agent` (`delegate` in delegate mode), `agent_version`,
`version_checked`, `endpoint` (URL in full, R7), `model` (as requested, may be empty),
`model_reported` (as the harness reported it), `effort`, `rules_ref`, `image`, `image_stamp`,
`task_id` (joins T's `round` rows), `status` (`report.json` status, or `setup-failed` /
`leak-refused` / `run-failed`), `exit`, `timed_out`, `timeout_s`, `hidden_pass`, `hidden_fail`, `hidden_total`,
`hidden_all` (bool), `hidden_rc`, `verify_rc`, `start`, `end`, `duration_s`, `steps`,
`tool_calls`, `tool_errors` (count), `input_tokens`, `output_tokens`, `reasoning_tokens`,
`cache_read`, `cache_write`, `final_context_tokens`, `tokens_source` (`harness` | `proxy` | ``),
`llm_requests`, `llm_errors`, `llm_input`, `llm_output`, `first_edit_s`, `last_edit_s`,
`idle_tail_s`, `churn_events`, `churn_bytes`, `files_touched`, `rewrites`, `diff_added`,
`diff_deleted`, `diff_files`, `nudges` (object, delegate mode), `telemetry` (list of
`harness`/`proxy`/`files`), `source` (`""` | `legacy`), `ts`.

### `kind:"verdict"` — one per (subject, reviewer) (B9)

`review_id` (`v-<12 hex>`), `batch`, `subject`, `reviewer` (label), `reviewer_mode`,
`reviewer_agent`, `reviewer_agent_version`, `reviewer_endpoint`, `reviewer_model`,
`reviewer_model_reported`, `reviewer_effort`, `reviewer_task_id`, `status` (task status),
`verdict` (`accept` | `reject` | `invalid` | `missing`), `invalid_reason`, `findings` (≤ 100 of
`{file, line, end_line, severity, summary≤200 chars}`), `findings_total`, `findings_dropped`,
`duration_s`,
`input_tokens`, `output_tokens`, `ts`. No run id, case name or condition in it.

### `kind:"match"` — one per subject, after the batch's verdicts (B9)

`batch`, `subject`, `target` (`run` | `review_case`), `run_id` (target `run`), `session`,
`case`, `case_hash`, `truth` (target `review_case`: `{verdict, defects:[{id, file, start, end,
severity}]}` — `what` is not copied), `ts`.

### Legacy rows

`delegate bench import-legacy FILE...` maps `evals/results/*.jsonl` rows onto `benchmark` rows:
`source:"legacy"`, `mode:"delegate"`, `agent:"delegate"`, `session` = `legacy-<file stem>`,
`condition` = the label part of the stem, `model` from the sibling `.md` header's
`model: X` (else empty), `case`, `repeat` = `i`, `status`, `hidden_pass`, `hidden_fail`,
`hidden_total` = sum, `hidden_all`, `verify_rc`, `duration_s`, `steps`, `tool_calls`,
`tool_errors`, `output_tokens`, `final_context_tokens`, `nudges`, `diff_added`/`diff_deleted`
parsed from `"+A/-D"`; `case_hash` empty (the bundle of that day is not recoverable, R17);
`run_id` = `b-` + first 12 hex of sha256(`<file basename>:<line number>`), so importing twice adds
nothing (skipped and counted).

## Report (R10, R16) — `delegate bench report` (B10)

`[--session S]... [--plan P] [--case C] [--since YYYY-MM-DD] [--min-n N] [--json]`.

- **Workers**: group by `case`, `case_hash`, `mode`, `agent`, `model`, `effort`, `endpoint`
  host, `rules_ref`; columns n, hidden all-pass rate, hidden pass % median [min–max], verify
  pass rate, duration median [p25–p75], output tokens median [p25–p75], first edit median,
  last edit median, churn median, timeouts. Legacy rows are their own groups (no case hash).
- **Reviewers**: group by reviewer condition (`reviewer_agent`, `reviewer_model`,
  `reviewer_effort`); on review cases n, recall median [min–max], false positives median
  (all / high+medium), verdict accuracy; on runs n, agreement with other reviewers, agreement with
  hidden checks, invalid/missing count.
- Groups with n < `--min-n` (default 3, R10) are not printed; one line says how many were hidden.
  `--json` prints the same facts as one object. Empty ledger: empty tables, exit 0.

## Trust and security summary

| thing | from where | why it can't widen access |
|---|---|---|
| grants (incl. `[secrets]`) | owner dir only, ownership-checked | unchanged rule; secrets are files, mounted read-only |
| endpoints | owner file only, ownership-checked | a plan names an endpoint; it cannot point a key file at an arbitrary host path |
| agent profiles | `$DELEGATE_HOME/agents/` + owner dir | argv runs only inside `run_worker_docker`; no shell; values regex-checked; secrets only by grant |
| plans | anywhere | names only; every name resolves through the three stores above |
| bundle setup.sh | the delegate repo | runs on the host, as `evals/run.sh` runs it today (no change in trust) |
| hidden/ | the delegate repo | never inside a fixture (content-hash check), never mounted; scored after, in a scorer with nothing to steal |
| agent/reviewer output | untrusted | size-capped, lstat-checked, schema-validated parsers; never executed |

## Steps

| step | hard | what |
|---|---|---|
| B1 `b-1-bench-core` | no | `lib/bench.py` core: case.env parser, bundles, `case_hash`, plans, ids, row builders, stats helpers, legacy import; `match` kind; `delegate bench check/import-legacy` |
| B2 `b-2-endpoints-effort` | yes | endpoints file, `--endpoint` pin and key mount, endpoint hosts in egress allow, `--effort` → opencode `reasoningEffort` |
| B3 `b-3-agent-profiles` | yes | `lib/agents.py` (profiles, trust, argv rendering, launch env, output parsers), shipped profiles, grant `[secrets]`, `delegate agent list/show` |
| B4 `b-4-agent-round` | yes | `delegate run --agent`: prompt, `do_round` agent branch, `run_worker_docker` agent variant, launcher, agents image, report from agent output, docker test stub |
| B5 `b-5-telemetry` | yes | `lib/llmlog.py` proxy + sidecar, `lib/filetimeline.py` + its wiring |
| B6 `b-6-score` | yes | `delegate score`: copies, scorer container, fresh postgres, native path |
| B7 `b-7-bench-run` | yes | `delegate bench run`: sessions, fixtures, leak guard, runs, scoring, `benchmark` rows, resume; `evals/run.sh` becomes a wrapper |
| B8 `b-8-review-cases` | no | five review cases (three seeded, two clean) with truth and proving checks |
| B9 `b-9-review` | yes | `delegate bench review`: subjects, blind repos, reviewer tasks, verdict parsing, `verdict` then `match` rows |
| B10 `b-10-report` | no | `delegate bench report`, docs (`docs/benchmarks.md`, `evals/README.md`, reference) |

Every step's verify is the full gate in the brief's proven form: `bash -n`, `py_compile`, the
step's new test file present, every `tests/test_*.sh` passing under `env -u
DELEGATE_EVIDENCE_DIR`, and a scope check against the **previous step's branch** (`bench` for
B1). Steps that need docker or real agent CLIs carry offline tests (a stub `docker` and stub agent
CLIs on PATH, `tests/docker-stub.sh` from B4); the live checks are the lead's, in Phase 3.

## Decisions taken here

1. Own-harness runs reuse the task machinery (`delegate run --agent`) instead of a second
   sandbox: "same base, same kind of sandbox, same time limit and network rules" (R11) holds by
   construction, and the egress and grant code stays in one place.
2. Delegate mode keeps `--verify` (so its prompt is exactly today's and legacy results stay
   comparable); the authoritative `verify_rc` is always the scorer's, on a copy, in both modes.
3. Scoring uses no shared caches; `npm install` in a verify fetches through the egress proxy.
4. One run at a time; order shuffled per repeat with a recorded seed.
5. Blind mapping lives in `match` rows written after the verdicts, not in `benchmark` rows.
6. Reviewer findings carry a ≤ 200-character summary (the only free text B writes to the ledger);
   no prompts, diffs or code ever reach the ledger.
7. The report hides groups below n = 3 by default (R10: never a single run).

## Owner questions (each with the option picked)

1. **AGENTS.md says the worker must not write the code that limits the worker**
   (`run_worker_*`, `lib/grants.py`, egress). B must extend exactly that code: the `[secrets]`
   grant table (B3), the endpoint key mount and egress allow hosts (B2), the agent variant of
   `run_worker_docker` and the launcher (B4), the logging sidecar launch (B5) and the scorer
   container (B6). Option A: the worker writes them as `hard` steps whose specs dictate the cage
   tests verbatim, and the lead reads those functions in full in Phase 3. Option B: the lead
   hand-writes those hunks (≈ 200 lines over five functions) on the step branches before review.
   **Picked A** — it is what this slice's brief asks for (security steps `hard: true` on the
   chain); each cage change is confined to named functions listed in the spec so Phase 3 can read
   all of them, and the specs make the assertions tests, not prose. If the owner holds the AGENTS.md
   rule literally, B is the fallback and the specs already isolate the hunks.
2. **How own-harness credentials enter the sandbox.** Option A: reuse `mounts.ro` (the key file
   appears at its host path; but secret-looking names are blanked by design). Option B: a new grant
   table `[secrets]` mounted at `/run/secrets/grant/<name>`. **Picked B** — a fixed path the
   launcher can rely on, never blanked, and listed by name in reports.
3. **Where a delegate-mode run's endpoint key comes from.** Option A: an owner-written endpoints
   file. Option B: a grant secret. **Picked A** — the delegate endpoint key is the harness's own
   credential (mounted today from config), not an agent credential; R14's grant rule stays
   specific to own-harness agents.
4. **T's round rows for own-harness rounds.** T's builder sums tokens from the opencode timeline,
   which agent rounds do not have, so their round rows show zero tokens. Option A: leave T as
   designed; the `benchmark` row is where agent tokens live. Option B: B4 makes T's builder fall
   back to `report.json` token fields when the timeline is empty. **Picked A** (no change to T's
   design); B is a small follow-up if `delegate stats` should count agent tokens.
5. **Effort in delegate mode.** R3's `effort` is `hard`/`normal`; a bench condition's effort is a
   reasoning level. **Picked**: a separate `REASONING_EFFORT` (meta.env) rendered as opencode's
   `reasoningEffort` model option (opencode 2.3's binary maps it to `reasoning_effort` on the wire;
   confirmed live in Phase 3); T's `EFFORT` keeps its meaning.

## What the owner must do (not delegate code, not the worker)

- Write the grants that carry agent credentials, e.g. `~/.config/delegate/grants/agent-key-b.toml`
  with `[secrets] anthropic-api-key = "<path>"` (API key: proxy telemetry on) or
  `claude-oauth-token = "<path>"` (a `claude setup-token` token: no proxy telemetry, R13a), and one
  for codex if used. Key files mode 600.
- Write `~/.config/delegate/endpoints.toml` for delegate-mode endpoints other than the default.
- After B lands: `delegate build` (the worker stamp changes) and `delegate build --agents`.
- Install codex in the agent image only after checking its flags (`codex exec --help`) against
  `agents/codex.toml`; until then the `codex` profile is marked unverified.

## CLI facts and what is unverified

- claude 2.1.325 (installed), checked this session: `-p`, `--output-format stream-json` (requires
  `--verbose` with `-p`: verified by the error it prints), `--dangerously-skip-permissions`,
  `--permission-mode`, `--no-session-persistence`, `--model`, `--effort low|medium|high|xhigh|max`,
  `--version`, `setup-token`; `ANTHROPIC_BASE_URL` + `ANTHROPIC_API_KEY` honoured (a probe against a
  dead local port reported `apiKeySource: ANTHROPIC_API_KEY` and retried against that URL); the
  stream's first event is `{"type":"system","subtype":"init", ..., "model", "claude_code_version"}`.
  Not observed (no live call made): the `result` event's fields (`num_turns`, `usage`,
  `is_error`, `duration_ms`) — documented, the parser is tolerant, B4's fixture is built from the
  documentation and replaced by a captured stream in the Phase 3 live check.
  `CLAUDE_CODE_OAUTH_TOKEN` is present in the binary; its behaviour is unverified.
- codex: **not installed** — every flag in `agents/codex.toml` (`exec`, `--json`,
  `--dangerously-bypass-approvals-and-sandbox`, `--skip-git-repo-check`, `--model`,
  `-c model_reasoning_effort=`, `-` for stdin, `CODEX_API_KEY`, `OPENAI_BASE_URL`) and its JSONL
  event names (`thread.started`, `item.completed`, `turn.completed` with `usage`) are from its
  documentation, unverified.
- opencode 2.3.0: `reasoningEffort` → `reasoning_effort` found in the binary; wire effect
  unverified.
