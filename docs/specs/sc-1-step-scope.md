# Chain steps get a first-class `scope`: linted against the spec, checked before the tests, and no blind retries on a plan bug

## Goal

Today a chain step's "only touch these files" rule is a hand-written `grep -vE` at the end of
its `verify` string. Three measured failures came from it (codehub WV2, 2026-11-17): a guard
that left out a file the spec told the worker to modify (step 4: three full worker rounds and
three 4-5 minute test runs before it stopped as blocked), and two specs that clashed with an
existing test. Each failure ran the slow test gate before the one-second file check, and the
chain retried twice although no retry could fix the plan.

This step makes scope a plan field that `lib/chain.py` owns:

1. **Lint at load:** a step's spec names the files it owns; `load_plan` refuses to start a
   plan whose `scope` does not cover them (and `delegate chain PLAN --check` runs only that).
2. **Scope before tests:** the chain runs the scope gate first, inside the verify it hands
   the task, so a scope failure fails in a second, before the real verify starts.
3. **No blind retries:** a scope failure on a file the spec itself names is a plan bug, so
   the chain stops at once; a failure on a file the spec does not name gets one targeted
   retry message (revert these). Retry messages tell the worker to end `blocked`, not keep
   trying, when the spec contradicts itself, an existing test or the verify command.

Everything is generic and optional: a plan with no `scope` behaves exactly as today.

## Read first

- `lib/chain.py` — the whole file (625 lines). `load_plan` (line ~154), `retry_message`
  (~136), `verify_tail` (~128), `run` (~266, the per-step loop), `main` (~592, argv handling:
  how `--status`/`--clean`/`--wait` are parsed; add `--check` the same way).
- `tests/test_chain.sh` — the fake `delegate` and the `check` helper; extend its style.
- `claude/skills/delegate/design-template.md` lines 40-64 — the hand-written scope-gate
  advice this step replaces.
- `claude/skills/delegate/spec-template.md` — gains a "Files owned" section.
- `claude/skills/delegate/SKILL.md` "Phase 2" (around line 78) — gains one bullet.
- `docs/reference.md` — the chain section (grep `chain`); document the field and `--check`.
- `AGENTS.md` — the full gate.

## Contract

### Plan field

A step may carry `"scope": [ENTRY, ...]`, a non-empty list of strings. Plan-level `scope`
is not supported (refuse it at load: `plan-level 'scope' is not supported; put it on each step`).
Each ENTRY is a repo-relative path pattern:

- `path/to/file.py` — that exact path;
- `path/to/dir/` (trailing slash) — anything under that directory;
- a pattern with `*`, `?` or `**`: `*` and `?` never cross `/`, `**` matches any number of
  path segments including none (`a/**/b.py` matches `a/b.py` and `a/x/y/b.py`; `dir/**`
  matches everything under `dir/`).

Load-time validation, each failure `die(..., 2)` naming the step and the entry: not a string,
empty, starts with `/`, contains a `..` segment, contains a character outside
`[A-Za-z0-9._/*?+@=,~-]` (so no quote, space, `$`, backslash, bracket or newline can reach the
shell), or `scope` present but not a non-empty list.

Implement one matcher, `scope_regex(entries) -> str`: a POSIX ERE (used by `grep -E` in the
gate) that matches a whole path admitted by any entry, anchored `^(...)$`. Literal characters
escaped for ERE (`.`, `+`, and any other ERE metacharacter in the allowed set). The Python side
(lint, retry decision) uses the SAME regex through `re.fullmatch` so the two can never
disagree; add a test that runs both on the same path list.

### Owned paths in a spec (the lint)

`owned_paths(spec_text) -> list[(path, line_no)]`. An owned line is a markdown bullet whose
text starts with one of `new:`, `create:`, `modify:`, `delete:`, `remove:` (case-insensitive,
regex `^\s*[-*]\s+(new|create|modify|delete|remove)\s*:`). The bullet continues on following
lines that are indented more than the bullet and are not themselves a bullet at the same or
lower indent (stop at a blank line or the next same-level bullet). From the bullet and its
continuation take every backticked token; a token is a path when it contains no space and
contains `/` or a `.`. Normalise: strip a trailing `/**` or `**` to a directory (`dir/`); a
token with no `/` that follows a path token with a `/` in the same bullet takes that token's
directory (`hub/tests/test_routing.py`, `test_gate_order.py` → `hub/tests/test_gate_order.py`).
Tokens that are not paths (`ROUTE_PARAMS`, `frozenset({"hidden"})`) are ignored. Lines under a
heading named "Read first" or containing "read-only" on the bullet are never owned (they are
not edits), and a bullet starting `read-only:` is not an owned line.

Lint rule, for each step that has `scope`: every owned path (a `dir/` path: the directory
itself counts as covered when the scope admits any path under it, i.e. `dir/x` with a probe
name) must be admitted by the scope regex. On any miss: `die(..., 2)` with one line per miss:
`step NAME: the spec owns PATH (SPEC:LINE) but the step's scope does not admit it`. Run the
lint in `load_plan`, so every `delegate chain PLAN` run (and `--wait`, `--status`, `--clean`?
NO: only run and `--check`) refuses before any state is written or any step starts. A step
without `scope` is not linted.

`delegate chain PLAN.json --check`: load the plan, lint it, print one line per step
`  N. NAME  scope: K entries, owned: M (all covered)` or `  N. NAME  no scope` and exit 0;
on a lint failure the `die` above (exit 2). It never starts a step, never writes chain state,
never fires hooks. Add it to the module docstring and to `bin/delegate`'s chain help if the
help lists chain flags (grep for `--status` in `bin/delegate`; if the help is only the
docstring, the docstring is enough).

### The scope gate (before the verify)

`scope_gate(entries, base) -> str`: a bash snippet, using only bash, git, grep, sort and
printf (it runs inside the worker's toolchain container in the task worktree, like every
verify). When `base` is a ref it diffs `git merge-base HEAD BASE`; when `base` is `None`
(in-place chain) it diffs `HEAD`. The changed set is `git diff --name-only --no-renames
<from>` (working tree vs that commit: committed, staged and unstaged changes, deletions
included) plus `git ls-files --others --exclude-standard`, de-duplicated. Every path not
matching the scope regex is a violation. Output exactly:

- in scope: one line `DELEGATE-SCOPE: ok (N changed paths)`, and the snippet falls through;
- violation: `DELEGATE-SCOPE: outside this step's scope:` then one line per path,
  `DELEGATE-SCOPE:   PATH`, then `exit 1` (so the real verify never starts);
- the merge-base cannot be found: `DELEGATE-SCOPE: cannot find the base BASE` and `exit 1`.

Handle paths with spaces (read the list line by line; never word-split). It must work with
and without `set -o pipefail` and `set -e` in the caller, and must not leave variables that
could collide with the verify (prefix them `__dsc_`). `base` is single-quoted into the
snippet; it is a branch name the chain built (`delegate/<step>`) or the plan's `base`
(validate the plan's `base` at load against `[A-Za-z0-9._/@+-]+` when any step has `scope`).

The base for step i is the branch that step starts from: the plan's `base` for the first
step, else `delegate/<previous step name>` (exactly the `base` variable `run` already
tracks). In place (`"here": true`) it is `None` (each step's changes are uncommitted on top
of the previous accepted step's commit).

When a step has `scope`, the chain passes `--verify` as `scope_gate(...) + "\n" + verify`
everywhere it passes a verify today: the first `delegate run` and every retry's
`delegate continue ... --verify`. Steps without scope pass the verify unchanged.

### Retry policy

In `run`'s loop, when the status is `done-but-verify-failed` and the round's verify.log
contains `DELEGATE-SCOPE: outside this step's scope:`, parse the listed paths. Then:

- If any listed path appears in the step's spec text (the full path as a substring, or it is
  an owned path), it is a plan bug: `print_status(plan)` and `die` exit 3 at once, without a
  retry, with: `NAME: the scope gate refused PATH, which the spec names: the plan's scope is
  wrong. Fix the step's "scope" in PLAN (delegate chain PLAN --check), then re-run the chain.`
  (one sentence per such path is fine).
- Otherwise retry as now (counts against `retries`), with a message that lists the paths and
  says: they are outside this step's scope; revert them (restore changed files from the
  step's base, delete new ones) unless the spec requires them, and if it does, end with
  STATUS: blocked and name the file under QUESTIONS.

Add to the `done-but-verify-failed` and `partial`/`no-status` retry messages (keep their
current text): "If the spec contradicts itself, an existing test or the verify command, do not
keep trying: end with STATUS: blocked and state the contradiction under QUESTIONS."

### Docs

- `lib/chain.py` docstring: `"scope"` in the PLAN.json example and one paragraph (lint, gate
  first, plan-bug stop, `--check`).
- `docs/reference.md` chain section: the same, a little longer, with the entry forms.
- `claude/skills/delegate/spec-template.md`: a `## Files owned` section before `## Contract`,
  with the bullet forms `- create: \`path\` — purpose`, `- modify: \`path\` — what changes`,
  and a sentence that the chain lints these against the step's `scope`.
- `claude/skills/delegate/design-template.md`: in step 3 (the chain json), each step gets a
  `"scope"` listing exactly its spec's owned files (plus test fixture dirs); verify commands
  no longer carry a hand-written scope grep. Keep the design task's own acceptance command
  as is (it is not a chain step). Replace the paragraph starting "A scope gate written" with
  two sentences: steps use `"scope"`, and the chain runs it first against the step's own
  start branch.
- `claude/skills/delegate/SKILL.md` Phase 2: one bullet "Run `delegate chain PLAN --check`:
  it refuses a step whose scope misses a file its spec owns. Also look for existing tests
  that pin behaviour a step changes, and put them in that step's spec and scope."

## Acceptance criteria

1. `bash -n bin/delegate && python3 -m py_compile lib/*.py` → exit 0.
2. `bash tests/test_chain.sh` → every existing check still `ok`, plus new checks (in that file
   or a new `tests/test_chain_scope.sh`, same style, no docker, no network, temp dirs only):
   - scope_regex: exact file, `dir/`, `*` not crossing `/`, `**` zero and many segments,
     `.` and `+` literal (`a.py` does not admit `aXpy`); Python `re.fullmatch` and
     `grep -E` agree on a list of 20+ probe paths.
   - entry validation: `/abs`, `a/../b`, `a b`, `a'b`, `$x`, `[]`, empty list, non-list,
     plan-level scope → exit 2, no chain state file written.
   - owned_paths: a fixture spec with `- modify:`, `- create:`, a multi-line continuation, a
     bare filename inheriting the previous token's dir, a `dir/**` token, a non-path backtick
     token, a `Read first` bullet and a `read-only:` bullet (both ignored).
   - lint: a plan whose scope misses one owned file → exit 2 naming the file and spec line,
     and the fake delegate was never called; the fixed plan → `--check` exit 0 printing
     `all covered`; `--check` on a plan with no scope → exit 0, `no scope`.
   - gate, run for real with bash in a temp git repo with a base branch and a step branch:
     in-scope changes → `DELEGATE-SCOPE: ok` and the verify that follows runs; an
     out-of-scope modified file, an untracked file, a deleted file and a file whose name has
     a space → each listed, exit 1, and a marker the following verify would create is absent;
     works under `set -euo pipefail` in the caller; a missing base → `cannot find the base`.
     Step 2's gate uses `delegate/<step 1>` as its base (step 1's files are not violations).
   - composition: the `--verify` the fake delegate receives on `run` and on `continue` starts
     with the gate and ends with the plan's verify; a step without scope receives the plan's
     verify unchanged.
   - retry policy: round 1 verify.log listing a spec-named path → chain exits 3 after one
     round with no `continue`; listing an unnamed path → one `continue` whose message names
     the path; the contradiction sentence is in the partial and verify-failed messages.
3. The full gate: `for t in tests/test_*.sh; do bash "$t" || exit 1; done` → exit 0.

## Out of scope

- `bin/delegate` beyond, at most, a help-text line for `--check`. No harness, report, status
  or ledger changes; no new task status.
- A plan-level scope, globs beyond `*`/`?`/`**`, parsing hand-written `grep -vE` guards in
  existing verify strings.
- `VERSION`, release notes, `opencode/` (never touch it), `install.sh`, `lib/` files other
  than `chain.py`.

## Files owned

- modify: `lib/chain.py`
- modify: `tests/test_chain.sh`
- create: `tests/test_chain_scope.sh` (if you split the new checks out)
- create: `tests/fixtures/chain-scope/**` (if you need fixture specs)
- modify: `docs/reference.md`
- modify: `claude/skills/delegate/SKILL.md`, `design-template.md`, `spec-template.md`
