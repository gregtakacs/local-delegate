# B design: benchmarks — models, own-harness agents, blind pluggable reviewers (R9–R19)

Slice B of `docs/specs/bench-rulings.md`, revised for the owner's amendments (R14 amended, R18,
R19). This file is the design; `b-<n>-*.md` and `b-o1-sandbox.md` are the step specs;
`b-chain.json` (segment 1) and `b-chain-2.json` (segment 2) are the chain plans. B builds on
slice T (`docs/specs/t-design.md`): every result is a row in T's ledger (`lib/ledger.py`:
`append`, `read_rows`, `KINDS`), never a second store. B starts from `bench` after T lands.

## Goal

Run a fixed task bundle (R9) many times (R10) under named **conditions** — the delegate worker
with a model and effort the configured endpoint serves (R18), or a standalone agent in its own
harness exactly as the owner set it up (R11, R14) — score each run outside the sandbox after it
ended (R12), record what telemetry each harness can give (R13), and have pluggable agents review
the results blind (R15), with the reviewers themselves scored against seeded ground truth and
against each other (R16). One report command reads it all back from the ledger as medians and
spread. B creates, stores, rotates or maps no credentials (R14 amended).

## Who writes what (R19)

The sandboxed worker never writes `run_worker_*`, `lib/grants.py`, `worker/egress*`, or any
other code that builds a sandbox or carries the owner's harness setup into one. That code is
**one orchestrator-written piece, `b-o1-sandbox`**, between two chain segments:

| order | piece | written by |
|---|---|---|
| 1–4 | chain segment 1 (`b-chain.json`): `b-1-bench-core`, `b-2-effort-models`, `b-3-agent-profiles`, `b-4-telemetry-libs` | worker |
| 5 | **`b-o1-sandbox`** (`docs/specs/b-o1-sandbox.md`): the agent variant of `run_worker_docker`, `agent_seed_home` / `agent_scrub_home`, `worker/agent-launch`, `llmlog_start` / `llmlog_stop`, `run_scorer`, the reasoning-effort env in `run_worker_docker`/`run_worker_native` and `render-opencode-config.py`'s `model_entry`, with `tests/test_sandbox_bench.sh` | **orchestrator, by hand** |
| 6–11 | chain segment 2 (`b-chain-2.json`, base = the orchestrator's branch `b-o1-sandbox`): `b-5-agent-round`, `b-6-score`, `b-7-bench-run`, `b-8-review-cases`, `b-9-review`, `b-10-report` | worker |

How it is enforced, not just stated: every worker step's verify also runs a **cage check** that
fails when the step changed a sandbox function or file. In segment 1 it compares the text of
`run_worker`, `run_worker_docker`, `run_worker_native`, `ensure_network`, `ensure_egress`,
`ensure_task_egress`, `host_args`, `read_mount_args`, `make_guard_shims` (each extracted with
`sed -n '/^NAME() {/,/^}/p'`) and the files `lib/grants.py`, `worker/egress.Dockerfile`,
`worker/egress-entrypoint.sh`, `worker/entrypoint.sh`, `lib/render-opencode-config.py`,
`worker/agent-launch` against `bench` (nothing in segment 1 may change or create them). In
segment 2 the same lists plus the functions O1 writes or touches — `net_args`, `run_limited`,
`run_scorer`, `agent_seed_home`, `agent_scrub_home`, `llmlog_start`, `llmlog_stop` — are compared
against `b-o1-sandbox`. Proven on a scratch worktree of `bench`: clean → passes; one inserted line
in `run_worker_docker` → `CAGE CHANGED run_worker_docker`, rc 1; one appended line in
`lib/grants.py` → `CAGE CHANGED files`, rc 1. Every worker step still runs the full
gate, so segment 2's steps pass against the orchestrator piece they build on (its tests are in
the gate).

## Ruling map

| ruling | this design | piece |
|---|---|---|
| R9 bundle | `evals/cases/<case>/` unchanged in shape; case.env **parsed, never sourced**; `case_hash`; review bundles in `evals/review-cases/` | B1, B8 |
| R10 several runs | plans: cases × conditions × `repeat` (default 3), seeded interleaved order; report shows n, median, p25–p75, min–max; groups below `--min-n` 3 hidden | B1, B7, B10 |
| R11 two modes | delegate mode = `delegate run --model M --effort E`; own-harness = `delegate run --agent NAME`: same task machinery, a different program in the container, one prompt, no nudges, no continue | B2, B5, O1 |
| R12 scoring after, on a copy | `delegate score` (B6) on `run_scorer` (O1): refuses while the run lives; hidden then verify, each on its own copy, in a scorer with no credentials, no harness setup, no grants, no shared caches | O1, B6, B7 |
| R13 telemetry | (a) `lib/llmlog.py` sidecar only when the copied setup already authenticates with an API key and the harness takes a base-URL setting; (b) the harness's own output (`claude-stream`, `codex-json`, `opencode-json`); (c) always, `lib/filetimeline.py` | B3, B4, O1, B5 |
| R14 (amended) | the harness's existing setup — the profile's declared paths under the owner's `$HOME` and declared env variables — is copied by the orchestrator-written `agent_seed_home` into a per-round directory that only the agent's container mounts (writable there, so refreshing logins work), never written back, deleted after the agent ends (before verify); auto-approve flags live in profiles, which run only in `run_worker_docker`; `--agent` refuses native and `--here`; B adds no grant format and no key files | B3, O1, B5 |
| R15 blind review | subject ids, blind two-commit repos, `verdict` rows first, `match` rows after the batch | B9 |
| R16 reviewers benchmarked | reviewer = any condition; seeded review cases → recall / false positives / verdict accuracy; agreement on real runs | B8, B9, B10 |
| R17 lost history | bundles rebuilt by `setup.sh`; a failing setup is `setup-failed`, never rescued | B7 |
| R18 configured endpoint | delegate mode has no endpoint choice: `delegate models` lists what the configured endpoint serves; a plan's delegate-mode `model` must be in that list (checked at session start) | B2, B7 |
| R19 orchestrator writes sandbox code | `b-o1-sandbox` + the cage check above | O1, all |

## Architecture in one picture

```
delegate bench run PLAN ──► for each (repeat, case, condition), in seeded shuffled order:
   lib/bench.py               1. fixture repo  ← bash setup.sh (host, as evals/run.sh does today)
                              2. leak guard    ← no hidden/ file content inside the fixture
                              3. delegate run  ← delegate mode: --model M --effort X --verify V
                                                 own-harness:   --agent A --model M --effort X --verify V
                                 (worktree, task network, egress, timeout as for any round;
                                  own-harness: agent_seed_home copies the harness setup into
                                  $TASK_DIR/agent-home/r1, mounted only into the agent container
                                  at the owner's $HOME path, scrubbed when the agent ends;
                                  DELEGATE_FILE_TIMELINE=1 → lib/filetimeline.py beside the round;
                                  API-key setups → lib/llmlog.py sidecar on the task network)
                              4. delegate score ← copies, hidden checks, verify, in a scorer container
                              5. ledger append  ← one `benchmark` row
delegate bench review SESSION ──► subjects → reviewer tasks → `verdict` rows → then `match` rows
delegate bench report [...] ──► tables from `benchmark` / `verdict` / `match` rows
```

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

## Conditions and plans (R10, R11, R18)

A **plan** is a JSON file the owner writes. It names agent profiles by name only; it carries no
endpoint, key, grant or path:

```json
{
  "name": "nov-models",
  "cases": ["py-semver", "bugfix-duration"],
  "repeat": 3,
  "seed": 7,
  "conditions": [
    {"label": "a-high", "mode": "delegate", "model": "model-a", "effort": "high"},
    {"label": "a-rules-old", "mode": "delegate", "model": "model-a", "rules_ref": "HEAD~1"},
    {"label": "cc", "mode": "own-harness", "agent": "claude-code", "model": "model-b", "effort": "high"},
    {"label": "oc", "mode": "own-harness", "agent": "opencode-own", "model": "provider-x/model-b"}
  ],
  "reviewers": [
    {"label": "rv-cc", "mode": "own-harness", "agent": "claude-code", "model": "model-b"},
    {"label": "rv-a", "mode": "delegate", "model": "model-a"}
  ],
  "review_cases": "all",
  "review_timeout": 1800
}
```

- `cases`: names or `"all"`. `review_cases`: names, `"all"` or `[]`.
- A condition's `label` is `[a-z0-9][a-z0-9._-]{0,31}`, unique in its list; `mode` is
  `delegate` or `own-harness`. Delegate mode takes `model` (optional; default `DELEGATE_MODEL`),
  `effort` (optional), `rules_ref` (optional git ref whose `opencode/` tree is the worker rules).
  Own-harness takes `agent` (required), `model` (optional: empty = the harness's own configured
  default), `effort` (must be in the profile's `efforts`).
- R18: before the first run of a session, every delegate-mode `model` must appear in `delegate
  models` (the ids the configured endpoint's `/models` returns with the configured key); a
  missing one stops the session before anything runs. Own-harness models are the harness's
  business: they are passed as given and recorded as requested and as reported.
- Unknown keys are errors; `delegate bench check PLAN` validates and prints the run matrix.
- Order: per repeat, case × condition pairs shuffled with `random.Random(f"{seed}:{repeat}")`;
  one run at a time.
- A **session** (`<plan name>-<YYYYmmdd-HHMMSS>`) is one execution of a plan, state in
  `$DELEGATE_STATE/bench/<session>/`, resumable with `--session S`.

## Agent profiles (R11, R14, R16) — one abstraction for workers and reviewers

A profile says how to start one agent in the sandbox and which parts of the owner's existing
setup it needs. The same profile serves the worker and the reviewer role.

Profiles are TOML files read only from `$DELEGATE_HOME/agents/` (shipped, public, placeholders)
and `$DELEGATE_AGENTS_DIR` (default `~/.config/delegate/agents/`; file and folder owned by the
user, not group/world-writable — the grants ownership rule, imported from `lib/grants.py`, not
changed). Never from a repo, worktree, plan folder or spec. An owner file overrides a shipped one.

```toml
# agents/claude-code.toml
name = "claude-code"
kind = "command"                     # "command" | "delegate"
image = ""                           # "" = DELEGATE_AGENT_IMAGE (default delegate-agents:local)
argv = ["claude", "-p", "--verbose", "--output-format", "stream-json",
        "--dangerously-skip-permissions", "--no-session-persistence",
        "{model_args}", "{effort_args}"]
model_args = ["--model", "{model}"]
effort_args = ["--effort", "{effort}"]
efforts = ["low", "medium", "high", "xhigh", "max"]
version_argv = ["claude", "--version"]
tested_versions = ["2.1.325"]
output = "claude-stream"             # claude-stream | codex-json | opencode-json | none
[setup]
paths = [".claude/.credentials.json", ".claude/settings.json", ".claude/CLAUDE.md",
         ".claude/rules", ".claude/skills", ".claude/agents", ".claude/commands", ".claude.json"]
env = ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL"]
[env]
DISABLE_AUTOUPDATER = "1"
[api]
base_url_env = "ANTHROPIC_BASE_URL"  # the harness takes its API base URL from this variable
default_upstream = "https://api.anthropic.com"
key_env = ["ANTHROPIC_API_KEY"]      # API-key mode = one of these is in the copied setup env
dialect = "anthropic"
```

- `[setup] paths`: relative to the owner's `$HOME`; no `..`, not absolute, no glob. Copied when
  present, skipped when absent. Deliberately file- and folder-precise: the profile never names a
  whole harness folder that also holds the owner's transcripts or histories of other sessions
  (`~/.claude/projects` is not copied). `[setup] env`: names of variables copied from the
  environment of the process that runs `delegate` (the owner's shell), when set.
- Shipped profiles: `delegate` (the worker itself; `kind = "delegate"`), `claude-code`, `codex`
  (`.codex/auth.json`, `.codex/config.toml`, `.codex/AGENTS.md`; env `OPENAI_API_KEY`,
  `CODEX_API_KEY`, `OPENAI_BASE_URL`; `verified = false`), and `opencode-own` — OpenCode as the
  owner configured it, e.g. with a Claude API key: argv `["opencode", "run", "--format",
  "json", "{model_args}"]`, `model_args = ["-m", "{model}"]`, paths `.config/opencode`,
  `.local/share/opencode/auth.json`, env `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, output
  `opencode-json` (today's opencode event stream, the parser `lib/report.py` already has),
  `[api]` `base_url_env = "ANTHROPIC_BASE_URL"`, `key_env = ["ANTHROPIC_API_KEY"]` — whether its
  provider honours that variable is unverified (`verified = false` until the owner's live check).
- `argv` rendering (`lib/agents.py`): placeholders `{model}`, `{effort}`, `{model_args}`,
  `{effort_args}` only; values `^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$`; an argv list, no shell.
  The prompt goes on stdin.

## The owner's harness setup in the sandbox (R14 amended)

Written by the orchestrator (`b-o1-sandbox`), consumed by B5.

- `agent_seed_home RD`: creates `$TASK_DIR/agent-home/r<n>` (mode 700). For each validated
  `[setup] paths` entry under `$HOME`, copies it with `cp -RL` (symlinks dereferenced, so the
  copy holds the files the owner's setup actually reads; sockets/fifos skipped), keeping
  relative layout. Total copy capped at `DELEGATE_AGENT_SETUP_MAX_MB` (default 64): over the cap,
  the round dies naming the largest path. For each `[setup] env` name set in the invoking
  environment, a line `NAME=<printf %q value>` goes to `<agent home>/.delegate-agent-env` (mode
  600). The original files are only read; nothing is ever copied back.
- The agent container mounts that directory **read-write at the owner's own `$HOME` path** and
  runs with `HOME` set to it, so absolute paths inside the owner's config resolve inside the copy,
  and a login token the harness refreshes is refreshed in the copy only. The normal task home is
  not mounted into the agent container; the agent-home is mounted into nothing else.
- `worker/agent-launch` (the agent container's entrypoint) sources and deletes
  `.delegate-agent-env`, exports the profile's plain `[env]`, sets the base-URL variable when the
  proxy is on, and `exec`s the argv. Values never appear in `docker run` arguments, `docker
  inspect`, logs or reports.
- `agent_scrub_home RD`: `rm -rf` of the agent-home right after the agent's container exits —
  before commit, verify and report — and on every exit path (INT/TERM trap, `delegate stop`,
  `delegate rm`, `delegate prune`). The verify container, `delegate exec`, the scorer and the
  reviewer never see it.
- R14's "read-only" holds for the owner's originals: the sandbox never has them, only a copy;
  the copy is writable in the sandbox because refreshing logins must write, and it is discarded.

## Own-harness round (R11, R13b, R14)

`delegate run SPEC --agent NAME [--model M] [--effort E]` plus the usual
`--repo/--name/--base/--timeout/--verify/--service/--read/--copy` (B5).

- Refused: `DELEGATE_RUNNER=native`, `--here`, `--raw`, `--orb`, `--orb-flash`, `--github`,
  `--grant`. `delegate continue` on an agent task dies (one-shot, R11).
- `meta.env`: `MODE`, `AGENT`, `AGENT_IMAGE`, `AGENT_MODEL`, `AGENT_EFFORT`; `BASE_URL` = the
  setup env's base-URL variable if set, else the profile's `default_upstream` (what T's round row
  records as `endpoint`; for a subscription login it is the harness's claim, R7).
- Prompt: the delegate environment lines (worktree, evidence dir, `$DATABASE_URL`, verify,
  network), no delegate rules, no closing block, then the spec verbatim (exact text in B5).
- `do_round`'s agent branch: version (`version_argv` in the image, `--network none`, no
  setup), argv, `agent_seed_home`, optional `llmlog_start`, `run_limited` → `run_worker` with
  `AGENT_MODE=1`, `llmlog_stop`, `agent_scrub_home`, then `finalize_round` as for every round with
  `lib/report.py report --agent-format F --agent-output $rd/agent.jsonl`.
- Image: `worker/agents.Dockerfile` `FROM ${BASE}` (the worker image) + the claude and codex CLIs
  at pinned versions + `worker/agent-launch`; opencode is already in the base. `delegate build
  --agents`.

## Telemetry (R13)

- **(b) harness output** — `lib/agents.py summarize(fmt, path)` → one normalized summary
  (`steps, tool_calls, tools, tool_errors, errors, input/output/reasoning tokens, cache_read,
  cache_write, final_text, model_reported, agent_version, success, session, unparsed_lines`);
  `opencode-json` reuses `lib/report.py summarize`. `version_checked` per run against the
  profile's `tested_versions`. Untrusted input: line cap 4 MiB, 512 MiB total, never raises.
- **(a) logging proxy** — on only when all hold: the profile has `[api] base_url_env`; one of
  its `key_env` variables is set in the copied setup env (the owner's existing setup already
  authenticates with an API key); the network mode is not `host`. Upstream = the setup env's
  base-URL value if set (the owner's own), else `default_upstream`. The agent's base-URL variable
  is pointed at `http://delegate-<id>-llmlog:8080` + the upstream path. A subscription login, a
  key held only in a file the profile cannot point elsewhere, or a harness without a base-URL
  setting → no proxy; (b) and (c) only, `llm_*` fields empty. A proxy that saw no request while
  the harness reported tokens records `proxy_bypassed: true` (the harness ignored the variable).
  `lib/llmlog.py` (B4) forwards to that one origin only, passes headers through, streams bodies
  unchanged, logs per request only timing, path (no query), status, model, usage, byte counts —
  never a header or body; it holds no key. Sidecar launch is O1's `llmlog_start`.
- **(c) file timeline** — `lib/filetimeline.py` (B4), wired by B5 for every round when
  `DELEGATE_FILE_TIMELINE=1` (bench sets it in both modes).

## Scoring (R12)

`delegate score ID --hidden DIR --out DIR [--verify CMD] [--timeout S]` (B6, over O1's
`run_scorer`):

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
`SERVICE=postgres` (`delegate-<id>-spg`, removed after). No key mount, no harness-setup copy, no grants, no rules, no
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
   (`delegate run` with the reviewer's mode/agent/model/effort, `--name r<k>`,
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
`llm_requests`, `llm_errors`, `llm_input`, `llm_output`, `proxy_bypassed`, `first_edit_s`, `last_edit_s`,
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
| agent profiles | `$DELEGATE_HOME/agents/` + owner dir | argv runs only inside `run_worker_docker`'s agent variant; no shell; values regex-checked; setup paths relative to `$HOME`, re-validated by the orchestrator-written copier |
| the owner's harness setup | the owner's `$HOME` and shell env, copied per round | only the agent's container mounts the copy; scrubbed before verify; never written back; never in argv, inspect, logs, reports or the ledger |
| plans | anywhere | names only (profiles, models); no path, endpoint, key or grant |
| bundle setup.sh | the delegate repo | runs on the host, as `evals/run.sh` runs it today |
| hidden/ | the delegate repo | never inside a fixture (content-hash check), never mounted; scored after, in a scorer that has no setup copy, key, grant or cache |
| agent/reviewer output | untrusted | size-capped, lstat-checked, schema-validated parsers; never executed |
| sandbox code | orchestrator only (R19) | the cage check in every worker step's verify |

## Steps

| # | piece | by | hard | what |
|---|---|---|---|---|
| 1 | `b-1-bench-core` | worker | no | `lib/bench.py` core: case.env parser, bundles, `case_hash`, plans, ids, row builders, stats, legacy import; `match` kind; `delegate bench check/import-legacy` |
| 2 | `b-2-effort-models` | worker | no | `--effort` (meta `REASONING_EFFORT`), `delegate models`, `tests/docker-stub.sh` + its test against today's docker path |
| 3 | `b-3-agent-profiles` | worker | yes | `lib/agents.py` (profiles, trust, argv, setup lists, proxy decision, parsers), four shipped profiles, `delegate agent list/show` |
| 4 | `b-4-telemetry-libs` | worker | yes | `lib/llmlog.py` proxy and `lib/filetimeline.py`, pure stdlib, tested offline |
| O1 | `b-o1-sandbox` | **orchestrator** | — | agent variant of `run_worker_docker`, `agent_seed_home`/`agent_scrub_home`, `worker/agent-launch`, `llmlog_start`/`llmlog_stop`, `run_scorer`, effort env + `model_entry` option; `tests/test_sandbox_bench.sh` |
| 5 | `b-5-agent-round` | worker | yes | `delegate run --agent`: options, prompt, `do_round` agent branch over O1's functions, report from agent output, file-timeline wiring, agents image, `build --agents` |
| 6 | `b-6-score` | worker | yes | `delegate score` over O1's `run_scorer` |
| 7 | `b-7-bench-run` | worker | yes | `delegate bench run`: sessions, R18 model check, fixtures, leak guard, runs, scoring, `benchmark` rows, resume |
| 8 | `b-8-review-cases` | worker | no | five review cases with truth and proving checks |
| 9 | `b-9-review` | worker | yes | `delegate bench review`: subjects, blind repos, reviewers, verdict parsing, `verdict` then `match` rows |
| 10 | `b-10-report` | worker | no | `delegate bench report`, `evals/run.sh` wrapper, docs |

Every worker step's verify is the full gate in the proven form (`bash -n`, `py_compile`, the
step's new test present, every `tests/test_*.sh` passing under `env -u DELEGATE_EVIDENCE_DIR`),
then the cage check, then the scope check against the **previous piece's branch** (`bench` for
step 1; `b-o1-sandbox` for step 5).

**Running it.** (1) `delegate chain docs/specs/b-chain.json` (segment 1, base `bench`). (2) The
orchestrator cuts `b-o1-sandbox` from `delegate/b-4-telemetry-libs`, writes O1 by hand per its
spec, passes `tests/test_sandbox_bench.sh` and the full gate, commits. (3) `delegate chain
docs/specs/b-chain-2.json` (segment 2, base `b-o1-sandbox`). (4) Phase 3: the orchestrator's
review and live checks, then the owner-run checks below.

## Decisions taken here

1. Own-harness runs reuse the task machinery (`delegate run --agent`); "same kind of sandbox,
   same time limit and network rules" holds by construction.
2. Delegate mode keeps `--verify` (prompt parity with today and with legacy results); the
   authoritative `verify_rc` is always the scorer's, on a copy.
3. Scoring uses no shared caches.
4. One run at a time; order shuffled per repeat with a recorded seed.
5. Blind mapping lives in `match` rows written after the verdicts.
6. Reviewer findings carry a ≤ 200-character summary; no prompts, diffs, code or setup content
   ever reach the ledger.
7. The report hides groups below n = 3 by default.
8. The harness setup copy is mounted at the owner's own `$HOME` path, so absolute paths in the
   owner's config keep working inside the copy.
9. The copier and the copy's lifetime are sandbox code (they carry credentials into a
   container), so they are in O1, not in a worker step; the profile's path list is data the
   worker's `lib/agents.py` validates and O1 re-validates.
10. `render-opencode-config.py` writes the worker's permission rules, so its `model_entry` change
    is in O1 too, though R19 does not name the file.

## Owner questions (each with the option picked)

1. ~~Who writes the sandbox code~~ — settled by R19: the orchestrator (`b-o1-sandbox`).
2. ~~How agent credentials enter~~ — settled by R14 amended: the owner's existing setup, copied.
3. ~~Delegate-mode endpoints~~ — settled by R18: the configured endpoint only.
4. **T's round rows for own-harness rounds** show zero tokens (T sums the opencode timeline).
   **Picked A**: leave T; agent tokens live in the `benchmark` row. (Stands.)
5. **Effort in delegate mode**: a separate `REASONING_EFFORT`, rendered as opencode's
   `reasoningEffort`; T's `EFFORT` keeps hard/normal. (Stands.)
6. **Which setup paths a shipped profile copies.** Option A: whole harness folders (`~/.claude`,
   `~/.codex`, `~/.config/opencode`), exactly as set up. Option B: the precise config, login and
   instruction files listed above. **Picked B** — whole folders carry transcripts and histories of
   unrelated sessions into every run (and can be hundreds of MB); an owner who wants more lists it
   in an owner profile of the same name.
7. **Owner config that names paths outside the copied set** (a hook script in another folder, an
   `apiKeyHelper` command, a plugin symlinked from elsewhere). Option A: copy it too, chasing
   references. Option B: copy only the declared paths (symlinks dereferenced); anything else is
   absent in the sandbox and fails visibly in that harness's own way. **Picked B** — B cannot
   parse every harness's config safely; the owner adds paths to the profile when a harness needs
   them, and the owner-run checks below show it.

## What the owner must do (not delegate code, not an agent session)

- After B lands: `delegate build` (the worker stamp changes at O1 and B5), then `delegate build
  --agents`.
- If a shipped profile's path list does not match how a harness is set up, write an owner profile
  of the same name in `~/.config/delegate/agents/`.
- Check `agents/codex.toml` against `codex exec --help` once codex is installed in the image.

### Owner-run live checks (an agent session must not run these: they copy setup paths the session may not read)

1. `delegate run <tiny spec> --agent claude-code` with the owner's subscription login: the run
   completes; `report.json` has the stream's tokens and `version_checked: true`; no proxy
   sidecar; afterwards `$TASK_DIR/agent-home` is gone and the owner's `~/.claude/.credentials.json`
   modification time is unchanged.
2. The same with `ANTHROPIC_API_KEY` set in the owner's shell: the `llmlog` sidecar ran, `llm.json`
   shows requests and tokens matching the stream's within rounding, and the proxy log contains no
   header or body (grep it for the first 8 characters of the key: no match).
3. `--agent opencode-own` with the owner's OpenCode configured for a Claude API key: completes;
   whether `ANTHROPIC_BASE_URL` reached the provider is visible as `proxy_bypassed`; set
   `verified = true` in an owner copy of the profile only if it did.
4. `--agent codex` once its flags are checked.
5. A small `delegate bench run` plan with one own-harness condition and `delegate bench review`
   with an own-harness reviewer, end to end.

The orchestrator's own Phase 3 live checks need no owner setup: delegate-mode `bench run` on two
cases with two models from `delegate models`, `delegate score` against a real docker scorer
(including the postgres case), the logging proxy's TLS tunnel through the egress proxy using a
throwaway local upstream, `delegate bench review` with delegate-mode reviewers on the review
cases, and `delegate bench report`.

## CLI facts and what is unverified

- claude 2.1.325 (installed), checked this session against `--help` and an offline probe:
  `-p`, `--output-format stream-json` (requires `--verbose` with `-p`),
  `--dangerously-skip-permissions`, `--no-session-persistence`, `--model`, `--effort
  low|medium|high|xhigh|max`, `--version`; `ANTHROPIC_BASE_URL` + `ANTHROPIC_API_KEY` honoured;
  the stream's first event is `system`/`init` with `model` and `claude_code_version`. Not
  observed: the `result` event's fields; how a copied subscription login behaves under a different
  machine path (owner check 1).
- codex: **not installed** — every flag and event name in `agents/codex.toml` is from its
  documentation, unverified.
- opencode 2.3.0: `opencode run --format json` and `-m` are what delegate uses today;
  `reasoningEffort` → `reasoning_effort` found in the binary (wire effect unverified); whether its
  Anthropic provider honours `ANTHROPIC_BASE_URL` is unverified (owner check 3); the auth store
  path `.local/share/opencode/auth.json` is from its documentation.
