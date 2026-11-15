# O1b step 4: the Claude Code hook scripts (todo, verify, notes, permission-guard) and the OpenCode notes fallback

`"hard": true` — `permission-guard.py` decides allow/deny at runtime (security code), and the
reminder hooks must nudge without nagging (their budgets are measured behaviour in the JS twins).
Slice O1b step 4 of 6 (`docs/specs/o1b-design.md` §5–§6, §13; handoff §3 "Plugins → hooks" mapping,
binding). Repo: delegate, branch off `main`; chain runs after steps 1–3, and **step 4 does not merge
until §6.1 shows S1/S2/S3/S4 not-FAIL** (SPIKE results may still say NOT-RUN-HERE only if the
orchestrator is running this chain on a machine with Claude Code; otherwise the orchestrator runs
step 4 from a logged-in session, per the design §6/§15).

## Read first

- `docs/specs/o1b-design.md` §5 (plugin parity table), §6 (what the spike proved; re-read the
  recorded lines), §7.5 (guard scope), §8.2 (entry shape the installer will wire).
- The JS twins: `opencode/plugins/todo-loop.js` and `verify-loop.js` (nudge budgets: every-8-calls
  stale-list nudge, once-per-file reminder, MAX_NUDGES, state in process not transcript),
  `notes-loop.js` (compaction pointer + long-round nudge, `CALLS_BEFORE_NUDGE`),
  `chunk-cap.js` header (the FIDELITY comment style: state what the source of truth is).
- `claude/hooks/agent-progress.py` (stdin JSON, common input fields: `session_id`, `transcript_path`,
  `cwd`, `hook_event_name`, `tool_name`, `tool_input`; output discipline), `claude/spikes/` S1/S2/S3
  probes (the same contracts, already runnable).
- `docs/permission-judge.md` §3 (the hard-limit list the guard must never auto-allow) and step 3's
  guard rendering (`--render guard` output; it is the input file the hook loads).

## Contract

- `claude/hooks/harness.py` — single executable entry point the settings file names. Reads the event
  JSON on stdin, dispatches on `hook_event_name` (plus `tool_name` for the PostToolUse matcher split)
  to the four modules, writes exactly one hook-output JSON on stdout or nothing (exit 0 = no
  decision; the hooks reference's shapes). Crash-safety first: any internal error → exit 0 silently
  (a broken reminder must never block a session; the guard inverts this rule, see below). State
  (nudge counters) lives in a jsonl under `/tmp/delegate-claude-hooks/<session_id>.json` (processes
  don't persist between hook calls — the JS in-memory state does not port; file-backed and per
  session, with the same budgets as the JS).
  - `PostToolUse` (`*`): todo-loop port — same windows, same nudge text as the JS plugin's, output
    via `hookSpecificOutput: {"hookEventName":"PostToolUse","additionalContext": …}`.
  - `PostToolUse` (`Edit|Write`): verify-loop port — first edit of a UI file per session reminds once
    ("read `~/.claude/rules/delegate-verify-ui.md`…") — path note: the UI rule file ships inside the
    concatenated `delegate-harness.md` rules file (step 5), the reminder names where to find §C.
  - `PreCompact`: print the notes pointer on **stdout** (the reference says PreCompact stdout guides
    the summary) — one line, `your notes: <NOTES path>; read it before continuing` if it exists, plus
    the same content via `additionalContext` on `SessionStart` (`startup|resume|compact` matchers).
  - `PermissionRequest`: delegate to `permission-guard.py`, which runs
    `lib/translate-permissions.py --render guard` against the install tree's policy at event time
    (stdlib, single process, the install tree stays read-only — no rendered artefact) — deny list re-checked
    (defense-in-depth; a deny the settings already carry is re-denied here), `allow_exceptions`
    matched → `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{
    "behavior":"allow","reason":"delegate policy exception"}}}`; anything else → no output, exit 0
    (the human/classifier answers). Guard failures are **fail-to-human**: a corrupt guard.json =
    silent no-decision; an unreadable-but-present deny list = deny nothing new, stay silent; the
    guard NEVER emits behavior allow for a command matching any judge-doc §3 pattern (tested).
  - Never touches anything outside `/tmp/delegate-claude-hooks/` and its read-only inputs.
- `opencode/plugins/notes-loop.js` — the interactive fallback (§5.1): with no
  `DELEGATE_EVIDENCE_DIR`, derive `/tmp/opencode-notes/<basename(cwd)>/NOTES.md`; same nudge rules.
- `tests/test_claude_hooks.sh` — no `claude` needed: pipes handcrafted event JSON into
  `harness.py` and asserts stdout shapes: PostToolUse nudge appears only after the budgeted call
  count (simulate 9 calls), UI reminder once-per-file, PreCompact stdout line, SessionStart JSON key,
  guard allow only on exception match, guard silent (no stdout, exit 0) on every §3 hard-limit
  command list (sudo, `git push --force`, chained `foo && sudo …`, `.env` paths, pattern kills),
  harness.py exits 0 silently on garbage stdin, and the cap-abstence assertion (§9's claude-exempt
  made testable here): `harness.py` contains no edit-size/payload-size check at all (grep guard).

## Behaviour and edge cases

- Todo nudge budgets read from the JS constants (same numbers, comment cites the file);
  MAX_NUDGES honoured; stale-state file older than 24 h treated as a new session.
- `SessionStart` matcher `compact` is the notes-loop "after compaction" moment the JS plugin
  implements by naming the file in the compacted context — port's line does exactly that.
- Concurrent sessions: per-session state file keyed on `session_id` from the event JSON; writes are
  `tmp+os.replace`.
- Hook input arrives with keys the modules ignore; unknown event names → exit 0.
- the policy file absent or unreadable (permissions opted out, Q2) → guard module inert (exit 0, no
  stderr noise).

## Acceptance criteria

1. `bash tests/test_claude_hooks.sh` → PASS, exit 0.
2. `printf '{"hook_event_name":"PreCompact","trigger":"auto","session_id":"t","transcript_path":"/tmp/x","cwd":"/tmp"}' | python3 claude/hooks/harness.py` → exit 0, one notes line or none, no traceback.
3. The Verify line → exit 0.

## Verify

`set -o pipefail && bash -n bin/delegate bin/delegate-wake install.sh && python3 -m py_compile
lib/*.py claude/hooks/*.py && for t in tests/test_*.sh; do bash "$t" || exit 1; done && ! git diff
--name-only delegate/o1b-3-policy -- ':(exclude)config.example.env' | grep -qvE
'^(claude/hooks/|opencode/plugins/|tests/|docs/specs/)'`

## Out of scope

`install.sh` changes (step 5), the OpenCode merge (step 5), LLM judging (not built), `.clinerules`
(step 5), policy content (step 3 — the guard consumes its rendering).

## Notes

The four behaviours exist twice after this step (JS + Python). That is the ruling's cost, and the
pair is kept honest by shared test fixtures where feasible: `tests/test_claude_hooks.sh` embeds the
expected nudge strings taken from the JS sources. If Claude Code turns out to want a plugin-bundled
`hooks/hooks.json` instead of user-settings entries (managed-vs-user precedence edge, hooks
reference), that changes step 5's merge target, not this step's scripts.
