# O1b step 1: hook spike — prove the Claude Code hook contracts before anything builds on them

`"hard": true` — nothing in the slice may rely on a hook event this step has not probed (owner
ruling, handoff §3 "Verify each hook can do the job in a spike before promising it"), and the
permission probes touch the security path. Slice O1b step 1 of 6 (`docs/specs/o1b-design.md` §6,
§13; rulings §1's table there). Repo: delegate, branch off `main`. No product behaviour changes:
this step ships probes, their test, and the wiring of results into the design doc.

## Read first

- `docs/specs/o1b-design.md` §6 (probe table S1–S7, what each must print), §1 rows "Plugins" and
  "Permission judge", §15 (sandbox has no `claude` binary — the design is written around that).
- codehub `docs/handoff.md` §3 paragraphs "Plain Claude Code sessions follow the same rules too"
  and "Goal: OpenCode and Claude Code behave very similarly" (binding; the 2026-11-14 checked facts).
- `claude/hooks/agent-progress.py` (the house style of a Claude Code command hook in this repo:
  stdin JSON, exit codes, never writing outside its business), `install.sh`'s `--claude-hook` block
  (how hook entries are shaped in `~/.claude/settings.json`: `matcher`, `hooks[].type/command/async/timeout`).
- `opencode/plugins/todo-loop.js`, `verify-loop.js`, `notes-loop.js` (the behaviours S1/S2 must show
  a hook can carry: nudge-once state, per-file reminder, compaction pointer).
- `lib/merge-opencode-permissions.py` `glob_re`/`covered` (S4's opencode side reference),
  `lib/render-opencode-config.py:48` comment (relative-vs-absolute edit spellings, S4/S5).
- `tests/test_merge_opencode_permissions.sh` (test style: `set -u`, temp dirs, `check`/PASS lines,
  offline self-skip).
- Claude Code hooks reference (live doc, fetched 2026-11-15 — the probe expectations quote it):
  `PostToolUse` → `hookSpecificOutput.additionalContext`; `SessionStart` matcher values
  `startup|resume|clear|compact|fork`; `PreCompact` stdout = compaction instructions;
  `PermissionRequest` → `hookSpecificOutput.decision.behavior` `allow|deny` + `updatedInput`;
  `PreToolUse` → `permissionDecision`; hooks run inside subagents; `if` uses permission-rule syntax.
  A probe that contradicts the doc wins — the doc is 2026-11-15, the binary on the machine is ground truth.

## Contract

- `claude/spikes/` — new dir, one script per probe: `probe-s1-posttooluse.sh`,
  `probe-s2-notes.sh`, `probe-s3-permission-request.sh`, `probe-s4-permissions-syntax.sh`,
  `probe-s5-opencode-reach.sh`, `probe-s6-clinerules.sh`, `probe-s7-rules-load.sh`, and
  `run.sh`. Rules every probe obeys:
  - runs Claude Code **headless** (`claude -p "<prompt>"`) against a throwaway
    `--settings <tmp>/settings.json` and a temp `CLAUDE_CONFIG_DIR`-style home where the CLI allows
    it; **never** reads or writes the machine's real `~/.claude` (the login dir is off-limits);
  - prints exactly one line `SPIKE <id>: PASS|FAIL|NOT-RUN-HERE — <one evidence line>`;
  - exits 0 on PASS and NOT-RUN-HERE, 1 on FAIL, so `run.sh` aggregates;
  - `NOT-RUN-HERE` is printed when `command -v claude` is absent or unlogged-in (a probe does not
    fake a login and never prints credential material).
  - S5/S6 run **OpenCode** (`opencode run`) instead of claude, in a temp `XDG_CONFIG_HOME`; they
    print the same line shape and run fine in the worker sandbox — S5 must not print NOT-RUN-HERE
    there (opencode is present; if it is somehow absent, same rule applies).
- `run.sh` — `run.sh` runs every probe and prints the `SPIKE` lines plus a summary; `run.sh
  --dry-run` prints each probe's exact command lines (the ones a logged-in machine would run) and
  exits 0 without executing a model. `run.sh --only <id>` selects one probe.
- `docs/specs/o1b-design.md` §6.1: this step fills the table's rows it honestly can (S5 from the
  sandbox), leaves the rest `NOT-RUN-HERE`-ready: keep the `TODO` marker only in rows never run —
  the acceptance step fails on `TODO`, so step 1 replaces every row's `TODO` with
  `NOT-RUN-HERE (<date>)` or a real result. Do not edit any other section of the design.
- `tests/test_spikes.sh` — new test in house style: every probe exists and is `bash -n` clean;
  `run.sh --dry-run` exits 0 and prints ≥ 7 `SPIKE` command groups; each probe script refuses to run
  with `--help`; no probe script contains a path under the real `$HOME/.claude` (grep guard; temp
  dirs only); S5 probes actually **run** here and print a parseable `SPIKE S5…` line (opencode is
  present in the sandbox); the design doc's §6.1 table has no `TODO` left.

## Behaviour and edge cases

- A probe whose Claude Code version lacks the event prints `FAIL` with the version — that is a
  finding, not a crash: probes use `set -u`, guard every intermediate, and never `eval` model output.
- The `PermissionRequest` probe defines the ask rule under test inside its throwaway settings file
  (`permissions.ask: ["Bash(echo SPIKE*)"]`-shaped, per the doc; adjust by what S4 recorded about
  syntax) — it must not depend on any permissions the machine's real settings carry.
- Probes that answer a prompt headlessly pass `--permission-mode`/`--dangerously-skip-permissions`
  only where the probe's own question demands it; default posture first, flags only to isolate the
  behaviour under test — recorded in the evidence line which flag mattered.
- Nothing under `claude/spikes/` may call `git push`, write outside its temp dirs, or read secrets
  (the test's grep guard enforces the `$HOME/.claude` rule; a reviewer eyeballs the rest).

## Acceptance criteria

1. `bash tests/test_spikes.sh` → its PASS lines, exit 0.
2. `bash claude/spikes/run.sh --dry-run` → exit 0, one command group per probe S1–S7.
3. The Verify line → exit 0.
4. `git diff --name-only main` → only `claude/spikes/`, `tests/`, `docs/specs/`.

## Verify

`set -o pipefail && bash -n bin/delegate bin/delegate-wake install.sh worker/entrypoint.sh
claude/spikes/run.sh claude/spikes/probe-*.sh && python3 -m py_compile lib/*.py && bash
tests/test_spikes.sh && for t in tests/test_*.sh; do bash "$t" || exit 1; done && ! git diff
--name-only main -- ':(exclude)config.example.env' | grep -qvE
'^(claude/spikes/|tests/|docs/specs/)'`

## Out of scope

Any change to `install.sh`, `lib/`, `opencode/`, `claude/hooks/` (the shipped hooks are step 4);
editing the design's rulings; filling S1–S4/S6/S7 with paper results (NOT-RUN-HERE is the honest
value in a sandbox without Claude Code — the orchestrator runs `claude/spikes/run.sh` for real on a
logged-in machine and on the codehub container, and pastes the lines into §6.1 before step 4 merges);
touching the machine's real `~/.claude` or `~/.config/opencode`.

## Notes

Why probes-in-repo beats results-in-docs: a Claude Code upgrade silently breaking a hook contract
is exactly the drift class this slice exists to catch; `run.sh` stays the re-check. The sandbox
fact (no `claude`) was recorded on 2026-11-15 by `command -v claude`; if a later worker image ships
it, the same run upgrades findings with zero spec change.
