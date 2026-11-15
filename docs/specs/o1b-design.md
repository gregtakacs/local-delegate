# O1b: the harness profile — one source of truth, two harnesses

Status: **slice design** for O1b of `docs/o1-design.md` §2 row "O1b" (the harness profile; R-O1-4).
Implements the binding owner rulings in codehub `docs/handoff.md` §3: the "**Harness profile**"
paragraph, "**Every OpenCode session follows the same rules, not only delegate work**",
"**Plain Claude Code sessions follow the same rules too**" (with the 2026-11-14 checked facts) and
"**Goal: OpenCode and Claude Code behave very similarly**". Design only: this slice adds no product
code; it lands as this design, six step specs (`o1b-1..6`) and `o1b-chain.json`, and is built as one
delegate release. Repo here is delegate; nothing depends on codehub.

## 1. What the slice adds, mapped to the rulings

| Ruling (handoff §3 paragraph) | What lands |
|---|---|
| Harness profile: one source of truth in delegate, translated per harness by `install.sh` | `opencode/rules/harness-core.md` (harness-neutral rules) + two short adapters; `policy/harness-permissions.json` + `lib/translate-permissions.py`; four Claude hook scripts; `install.sh` installs/merges both sides (§8) |
| Rules split: core + adapters; Claude installs as `~/.claude/rules/delegate-harness.md`, **not** `~/.claude/CLAUDE.md` (OpenCode falls back to that file and would load the rules twice) | §3 file layout; installer writes the rules file (symlink into `current/` preferred; plain copy if Claude misbehaves on rule symlinks — checked in step 5); deletion of `opencode/interactive-rules.md` with every in-repo reference updated |
| `.clinerules` / `.clinerules/*.md` of the open project loaded in both harnesses | OpenCode: an `instructions` glob entry (spike S5a: whether a global-config relative glob resolves per project); Claude Code: one-line project `CLAUDE.md`/`AGENTS.md` import **or** a user rule telling the agent to read `.clinerules` — "pick when testing" (spike S6) |
| Model-neutral wording: "orchestrator" / "worker", never "local model" | §4's list (~25 places, given there), fixed in step 2 |
| Plugins: all four for every OpenCode session; Claude Code hooks: `todo-loop`/`verify-loop` → `PostToolUse` additional context, `notes-loop` → `PreCompact`/`SessionStart`, `chunk-cap` → none (Claude Code exempt) | §5, spike §6 first, hook scripts in step 4 |
| Edit cap: the configured cap (`DELEGATE_CHUNK_CAP`, 8000) everywhere in OpenCode; rule text says "the configured cap"; Claude Code exempt | §5.3; rule text already fixed (commit `9a0fc54`); interactive sessions get the cap by finally loading `chunk-cap.js` |
| Every session, not only delegate work: plain one-prompt session, any agent (build, plan, explore/general subagents, custom-`prompt` agents), any model | §5.4: installer merges `instructions` + plugin links into the user's global OpenCode config; spike S5b proves subagent/custom-agent reach, step 6 tests it |
| Permissions: one policy file → OpenCode globs AND Claude `permissions` (`Bash(...)`, `Edit(...)`, `Read(...)`) in `~/.claude/settings.json`; same verdict for the same command despite last-match-wins vs deny>ask>allow; shared case list evaluated on both sides | §7, step 3 (hard) |
| Permission judge (`docs/permission-judge.md`) needs a Claude Code equivalent | §7.5: **`PermissionRequest`** hook event (name checked against the hooks reference, 2026-11-15); spike S3 before it is relied on |
| Installer merges, never clobbers, `~/.claude/settings.json` and `opencode.json`; keep unknown keys; mark what delegate owns | §8 |
| `delegate doctor` reports drift for this machine | §9 |
| Denied paths: agents never edit `~/.config/opencode/*`, the delegate checkout's `opencode/`+`claude/`, or `~/docker/secrets/*` live | §10: every mutation of those paths is an owner `install.sh` run; chain workers change the repo **on a branch**, exactly as every delegate slice so far |
| Release: ships as one delegate release; codehub's container picks it up via `delegate update` | §11 |

Out of scope (waits): §12. Site values (real hosts, ports, LAN addresses, the owner's paths) appear
nowhere in these specs — the policy file carries stances and generic patterns; per-machine service
lines (a daemon's `doctor`, a localhost health port) stay in the owner's own config overlay (§7.4).

## 2. File layout (after the slice)

```
opencode/
  rules/
    harness-core.md        # NEW: the harness-neutral core (from interactive-rules.md, §3)
    adapter-opencode.md    # NEW: OpenCode adapter (tool names/params, notes path, background work)
    adapter-claude-code.md # NEW: Claude Code adapter; installed as ~/.claude/rules/delegate-harness.md
    verify-ui.md           # unchanged
  delegate-rules.md        # worker rules: becomes the headless ADAPTER over harness-core (§3.3)
  plugins/                 # unchanged four; now installed for interactive sessions too (§5)
policy/                    # NEW top level
  harness-permissions.json # the one permission policy (§7.1)
  permission-cases.json    # shared case list; every step's test evaluates both engines (§7.3)
lib/
  translate-permissions.py # NEW: policy -> opencode globs / Claude settings block (§7.2)
  permission-eval.py       # NEW: opencode last-match and Claude deny>ask>allow evaluators (§7.3)
  merge-opencode-permissions.py  # extended: also merges `instructions` (§8.1)
claude/
  hooks/
    agent-progress.py      # unchanged
    harness.py             # NEW: one command-hook entry point, dispatches by hook_event_name (§6.3)
    todo-loop.py verify-loop.py notes-loop.py permission-guard.py  # NEW: behaviours (§6)
  spikes/                  # NEW: spike probes + run.sh; kept after the slice — they double as
                           # upgrade re-verification, and tests/ runs them in dry-run mode
install.sh                 # gains the profile install: rules, plugins, hooks, permissions;
                           # new flags --claude-profile / --claude-permissions (§8)
docs/specs/o1b-*.md        # this design + six step specs
docs/specs/o1b-chain.json  # the plan
```

`claude/spikes/` stays in the repo after the slice: the probes are the cheapest way to re-check a
Claude Code upgrade didn't break the hook contracts (a `tests/` guard runs them in `--dry-run`).

## 3. The rules split

### 3.1 Core (harness-neutral)

`opencode/rules/harness-core.md` takes, near-verbatim, the sections of `interactive-rules.md` that
name no OpenCode-specific tool: finish-the-job (§1), read-before-write/probe (§2), Definition of
Done (§3), UI rule (§4, pointing at the adapter for *where* `verify-ui.md` is installed),
plan-and-track (§5, "the todo list" not "TodoWrite"), batch (§6), small-context (§6a),
tool-call hygiene (§6b: "the configured edit cap"; the cap number itself is adapter territory, the
grow-don't-one-shot habit is core), bound-the-loop (§7), boundaries+git (§8 — commit/ask-first
rules are harness-neutral; the headless "no history-changing git" variant lives in the worker
adapter), working-notes (§9, the *path* is adapter-given), completeness (§10),
disagreeing-with-the-repo (§11), self-review (§12), reporting (§13), and the **"workers run only
their step's tests"** test policy (handoff §3 O1 bullet; today in `delegate-rules.md` §4/§7 — it
belongs in the core, phrased for the worker). Delegation-to-worker (interactive §14) is NOT core:
it becomes a one-paragraph pointer in each adapter naming that harness's entry point.

### 3.2 Adapters (short; ≤ 40 lines each)

- `adapter-opencode.md`: tool names (`edit` with `oldString`/`newString`, `write`, `bash`,
  `todowrite`, `read` with offset/limit), the **notes path** `/tmp/opencode-notes/<repo>/NOTES.md`
  when `DELEGATE_EVIDENCE_DIR` is unset, how to wait for background work (no wake notifications
  interactively: `nohup … &`, PID file, poll `delegate chain PLAN --status` sparingly — wording
  today in interactive §14 / `docs/harnesses.md`), the edit-cap sentence ("the configured cap,
  `DELEGATE_CHUNK_CAP`, default 8000"), the `verify-ui.md` install path, and the `/delegate`
  skill pointer.
- `adapter-claude-code.md`: tools (`Edit`, `Write`, `Bash`, `Read`, `Task`), the same notes path,
  how to run long chains (background bash; notifications work here), skill/agent entry
  (`/delegate`, the `delegate-lead` agent), the `.clinerules` load instruction (spike S6 decides
  import vs user-rule), one line that Claude Code is **exempt from the edit cap** (cap hygiene
  applies as style advice only).
- Install: OpenCode loads core+adapter via the merged `instructions` array (§8.1). Claude Code gets
  one concatenated file `~/.claude/rules/delegate-harness.md` (core+adapter, one write — Claude
  loads every `~/.claude/rules/*.md`; one file keeps ordering deterministic and is the exact name
  the double-load ruling prescribes). The installer never touches `~/.claude/CLAUDE.md`.

### 3.3 The worker rules

`opencode/delegate-rules.md` keeps only the headless deltas (turn-ends-task, the §13 STATUS block,
`$DELEGATE_EVIDENCE_DIR`, review rounds, no-git, §12a self-review) and gains one top line:
*sections it does not override are in `rules/harness-core.md`, loaded next.* `worker/entrypoint.sh`
seeds the core alongside (one `cp`), and `lib/render-opencode-config.py` sets
`instructions: [core, delegate-rules.md]` (core first). The worker test policy itself moves to the
core, so an interactive orchestrator honours it when writing a step's verify line.

## 4. Model-neutral wording (the list)

Replace "local model" (and "self-hosted model" where it stands for *the* worker) with **"the
worker"** / **"worker's model"** / **"the endpoint"**; the orchestrator is "orchestrator" or "you".
Positions found 2026-11-15 (`grep -rniE "local model|local worker|self-hosted model" -I`,
`evals/` excluded — eval fixtures are frozen measured prose):

| file | lines | fix |
|---|---|---|
| `claude/skills/delegate/SKILL.md` | 3 (frontmatter), 33, 45, 51, 57, 169 | "the worker designs and builds"; keep the phrase `"send to the local model"` **only** inside user-intent quotes (it is what the user says) |
| `claude/agents/delegate-lead.md` | 3, 8–9 | "the delegate worker (an agent on the endpoint delegate points at)" |
| `README.md` | 10, 30, 31, 40, 111, 116 | same wording; `--model qwen3-coder` examples (line 71) stay — model ids are examples, not claims |
| `AGENTS.md` | 3, 6 | "hand implementation to the delegate worker" |
| `docs/permission-judge.md` | 1 | title: "a worker-model auto mode" |
| `docs/harnesses.md` | 91 | "have the worker design the slice" |
| `docs/reference.md` | 33, 334 | as above |
| `opencode/interactive-rules.md` | 178 (§14 heading) | "Delegating to the worker"; text moves to the adapters with the file (§3) |
| `worker/Dockerfile`, `worker/entrypoint.sh` | header comments | "worker" |

≈ 25 positions, matching the handoff count. Gate after step 2: `grep -rniE "local model" -I . |
grep -v evals/ | grep -v 'send to the local model'` is empty, and the installed rules (core, both
adapters, `delegate-rules.md`) contain no "local model" at all. (Codehub's ~14 positions are its
own follow-up, §12.)

## 5. Plugins, the cap, and "every session"

### 5.1 OpenCode: all four, every session

`install.sh` symlinks each of `opencode/plugins/{chunk-cap,notes-loop,todo-loop,verify-loop}.js`
into `~/.config/opencode/plugins/` (same care as the skill link: a non-symlink file there is left
alone with a NOTE). The directory is proven: the worker image seeds exactly this layout
(`worker/entrypoint.sh` copies `plugins/` into `$HOME/.config/opencode/`) and all four run there.
`notes-loop.js` currently no-ops without `DELEGATE_EVIDENCE_DIR`; step 4 (OpenCode side: step 2
file edit) adds the interactive fallback — with the env unset it watches
`/tmp/opencode-notes/<basename(cwd)>/NOTES.md`, the path the core+adapter name. `todo-loop.js` and
`verify-loop.js` are session-id keyed and need no change.

### 5.2 Claude Code: the hook mapping

| plugin | Claude Code | mechanism (checked against the hooks reference, 2026-11-15) |
|---|---|---|
| `todo-loop` | `PostToolUse` | handler returns `hookSpecificOutput: {hookEventName:"PostToolUse", additionalContext: …}`; state keyed per `session_id` in the process, same "nudge once per window" budgets as the JS plugin |
| `verify-loop` | `PostToolUse`, matcher `Edit\|Write` | same mechanism, same once-per-file-per-session rule and the same §C rationale (it fights one-shotting; the reminder must not tax every pass) |
| `notes-loop` | `PreCompact` + `SessionStart` (matchers `startup\|resume\|compact`) | `PreCompact`: stdout becomes the compaction instructions → print "your notes are at $NOTES; read it next turn". `SessionStart`: `additionalContext` = "read $NOTES first if it exists" + the long-round nudge |
| `chunk-cap` | **none** | the owner's exemption ruling; `install.sh` writes no `PreToolUse` payload-size check, and doctor asserts its absence |

Notes path for Claude Code: `$CLAUDE_CODE_TASK_NOTES || /tmp/opencode-notes/<repo>/NOTES.md` — one
path convention in both harnesses (the adapter states it; spike S2 confirms hook cwd for a worktree
session: the `cwd` field, not `${CLAUDE_PROJECT_DIR}`, follows Claude per the hooks reference).

### 5.3 Edit cap

The cap is the configured value (`DELEGATE_CHUNK_CAP`, owner: **8000**) in every OpenCode session:
`chunk-cap.js` resolves it as `process.env.DELEGATE_CHUNK_CAP` → `DELEGATE_CHUNK_CAP` parsed from
`~/.config/delegate/config.env` → built-in 8000. (Interactive servers get no delegate env; reading
config.env in-plugin is what makes "everywhere" true without codehub pinning anything.) The Claude
adapter states the exemption; nothing enforces a cap there.

### 5.4 Every session, not only delegate work

The plain-session ruling is satisfied by *global* means: merged `instructions` (§8.1) + global
plugin links + global permissions. Subagent reach: the hooks reference states tool-event hooks run
inside subagents; OpenCode's doc claim ("global instructions apply to every session") is **tested**,
not assumed — spike S5b drives a plain `opencode run` session with an explore/general subagent and
a custom agent with its own `prompt`, and checks the rules text is answered from (the cheap probe:
ask the subagent to name the Definition-of-Done gate word from the core). Where subagents miss it,
step 5's fix options in order of preference: keep rules in `instructions` (they *should* apply),
add the same entries to the `agent` blocks delegate owns, or a `command`-type wrap. Recorded as a
deviation if OpenCode simply doesn't propagate; **do not** invent agent definitions for the user.

## 6. Hook spike plan (step 1; **no step builds on a hook before this records its finding**)

Probes live in `claude/spikes/`, each a script that drives real Claude Code `-p` sessions with an
isolated `--settings` file (never the owner's) and prints one line
`SPIKE <id>: PASS|FAIL|NOT-RUN-HERE — <evidence>`. The chain worker has no `claude` binary
(confirmed in this sandbox), so `run.sh --dry-run` (prints exact commands, exits 0) is the
chain-passable check, and **the orchestrator (or the codehub container, R-O1-7 login volume) runs
the probes for real on a logged-in Claude Code 2.1.x and pastes the output into §6.1**; step 1's
spec makes the NOT-RUN-HERE lines explicit, and the slice acceptance (step 6) refuses to close while
a probe that steps 4/5 depend on is not PASS.

| id | proves | relied on by |
|---|---|---|
| S1 | `PostToolUse` `additionalContext` reaches the model (model echoes the marker in its next message); async flag doesn't skip it | todo/verify hooks (step 4) |
| S2 | `PreCompact` stdout guides the summary (compact a long session, marker survives); `SessionStart` `additionalContext` lands on `startup` and `resume`; hook `cwd` in a worktree session | notes hook (step 4) |
| S3 | `PermissionRequest` fires for an `ask` rule, and a hook `decision.behavior:"allow"` answers it without a human (headless `-p`); `deny` from a `PreToolUse` hook beats a settings `allow`; behaviour in **auto mode** (classifier) when a rule says ask → does the hook still fire? | judge + exception list (steps 3–4), owner question Q1 |
| S4 | `permissions` semantics on the installed version: `Bash(git push *)`-style patterns, `:*` form vs space form, subcommand splitting (`npm test && git push`), `$()`/backtick handling, `Edit(**/.env)` / `Read(*/.env)` path syntax, deny>ask>allow order | translator (step 3) |
| S5 | (a) OpenCode global `instructions` entry `.clinerules/*.md`-style glob resolves per open project; (b) global instructions+plugins reach explore/general subagents and a custom agent with its own `prompt`; (c) project-level `.clinerules` loaded without any project config edit | rules install (step 5), `.clinerules` ruling |
| S6 | Claude Code `.clinerules` route: project-`CLAUDE.md` `@import` vs a user rule telling the agent to read the dir; pick one, verify the agent actually reads both `.clinerules` and `.clinerules/*.md` | adapter text (step 2 ships the neutral wording; step 5 installs the picked route) |
| S7 | Claude rules-file load: `~/.claude/rules/delegate-harness.md` is loaded in an arbitrary project; the installed entry is a **symlink into `current/`** (release-tree rule) — if Claude skips symlinked rule files, the installer copies instead (content-hash recorded for doctor) | rules install (step 5), doctor (step 5) |

### 6.1 Spike results (filled by the orchestrator after running `claude/spikes/run.sh`; step 1 may land with `NOT-RUN-HERE` lines, the slice may not close with them)

| probe | result | date | Claude Code version | note |
|---|---|---|---|---|
| S1 | PASS | 2026-11-15 | 2.1.325 | `PostToolUse` `additionalContext` reaches the model, sync and async; hook stdin JSON as documented |
| S2 | PASS | 2026-11-15 | 2.1.325 | `SessionStart` marker lands on `startup` and `resume`, payload `cwd` correct, `PreCompact` fires on manual `/compact`; long-session marker survival not exercised (check on a real session in step 6) |
| S3 | PASS for what steps 3–4 need | 2026-11-15 | 2.1.325 | `PermissionRequest` hook `allow`/`deny` answers an `ask` headless; `PreToolUse` deny beats a settings allow. `updatedInput` rewrite did NOT take: never rely on a hook rewriting a command. Auto-mode (classifier) leg not probed headless: Q1 pick stands (render ask), step 6 records live behaviour |
| S4 | PASS (stricter than the rig expected) | 2026-11-15 | 2.1.325 | allow, deny>allow, space-anchored prefixes, `$()` and `Edit(**/notes/*.md)` as expected. Re-run by the orchestrator with an execution log: a compound `echo X && git push` with `echo X*` allowed and `git push*` denied is **denied as a whole** (nothing ran) — compound commands are not split into separately-allowed parts; `Read(**/.env)` deny **does** block (in `permission_denials`, nothing read) — the probe's FAIL was its own oracle. Translator: a deny anywhere in a compound denies it |
| S5 | PASS | 2026-11-15 | n/a (opencode 1.18.30) | ran in the worker sandbox: relative `instructions` glob resolves per open project, custom-agent-with-prompt and explore subagent both receive global instructions, plugins load from the temp config dir, and project `.clinerules` is **not** auto-loaded without an `instructions` entry — step 5 installs the entry |
| S6 | PASS | 2026-11-15 | 2.1.325 | route: project `CLAUDE.md` `@import` of the FILE works; `@import` of a directory and a read-the-dir user rule did not load it. Step 5 installs file imports (`.clinerules` and each `.clinerules/*.md` by name) |
| S7 | NOT RUN (moot for install) | 2026-11-15 | 2.1.325 | needs a second logged-in config dir. The installer copies the rules file with a recorded sha (§8, owner decision 3), so the symlink question does not arise; that `~/.claude/rules/*.md` loads in an arbitrary project is checked live in step 6 |

No row is left a placeholder: the sandbox-runnable legs (S5, and S1–S4/S6 on a logged-in Claude
2.1.x) record PASS above; S7 stays NOT RUN because install never symlinks it (copy + sha, owner
decision 3). **The orchestrator must re-run `claude/spikes/run.sh` on a logged-in Claude Code
2.1.x before merging this slice, and paste any drift into the table** — the chain worker has no
`claude` binary (§15), so the probes above were recorded by the orchestrator, not by this chain.

If S3 shows auto-mode Claude never asks (classifier swallows the prompt), the Claude side keeps the
same policy file but the *ask* tier degrades to the owner's classifier — recorded under Q1's pick.

## 7. Permissions: one policy file, two renderings, same verdicts

### 7.1 The policy file

`policy/harness-permissions.json` (delegate-owned, source of truth). Shape (informative):

```json
{ "version": 1,
  "bash": [
    { "pattern": "*",              "effect": "ask",  "note": "default" },
    { "pattern": "git status *",   "effect": "allow" },
    { "pattern": "git push *",     "effect": "ask"  },
    { "pattern": "git push --force *", "effect": "deny", "over": ["git push *"] },
    { "pattern": "curl *LOCAL-HEALTH*", "effect": "allow", "via": "hook",
      "over": ["curl *"], "note": "opencode's last match lets it win; Claude's ask would not" }
  ],
  "read": [], "edit": [], "external_directory": [], "webfetch": []
}
```

Rules are **ordered** (opencode order is the semantics); `over` names the broader rule an entry
overrides, which is how the translator decides Claude expressibility without re-deriving
opencode's last-match scan. `via: "hook"` marks entries that cannot go into Claude's static arrays
(§7.2 exception rule) and are honoured by the permission hook instead.

Content source: the stance of codehub `docs/settings/opencode-permissions.jsonc` (the ~70 rules
named in the handoff), **de-site-ed**: service-specific allows (a named daemon's `doctor`, a
localhost port, `install.sh` paths) stay out — the file carries generic classes plus a documented
**machine overlay**: the owner's own extra rules live in their config and merge on top, never in
the repo. The two OpenCode entries delegate already merges (skill + skill-dir reads,
`lib/merge-opencode-permissions.py`) stay a separate machine-specific merge (they name install
paths), not policy.

### 7.2 The translation (the worked table)

`lib/translate-permissions.py --render opencode|claude|guard --policy … [--out -]`.
**The exception rule**: an opencode entry whose verdict beats an *earlier, less strict* rule cannot
be a Claude array entry — `allow`-after-`ask` and `allow`-after-`deny` lose under deny>ask>allow —
so it carries `via: "hook"`. `deny`-after-anything always maps (deny wins); `ask`-after-`allow`
maps trivially. Worked rows (the real generic rules of the jsonc, de-sited; both harnesses must
answer the verdict column for the exact input):

| command / path | opencode (last match) | Claude static arrays | Claude final | verdict |
|---|---|---|---|---|
| `git status --short` | `"git status *"` allow | allow `Bash(git status *)` | allow | allow=allow |
| `git push` | ask (explicit, and `"*"` ask anyway) | ask `Bash(git push *)` | ask | ask=ask |
| `git push --force` | deny entry wins | deny `Bash(git push --force *)` (deny beats ask) | deny | deny=deny |
| `rm -rf /` | `"rm -rf /*"` deny | deny `Bash(rm -rf /*)` | deny | deny=deny |
| `sudo ls` | `"sudo *"` deny | deny `Bash(sudo *)` | deny | deny=deny |
| `pkill x` | `"pkill *"` deny | deny `Bash(pkill *)` + hook backstop for subcommand forms (spike S4) | deny | deny=deny |
| `echo hi && git push` | `"*"` ask (chained, globs miss it) | ask — Claude splits subcommands (hooks docs): lands on the same ask; the case list pins it | ask | ask=ask |
| curl at the local health port | later allow wins | not expressible → `via: hook` (`permission-guard.py` answers `PermissionRequest` allow for it) | allow | allow=allow |
| read `.env` | `"*.env"` ask | ask `Read(*/.env*)` (form per spike S4) | ask | ask=ask |
| edit `.env` | `"*.env"` deny | deny `Edit(**/.env*)` | deny | deny=deny |
| edit `~/docker/secrets/x` | `*/docker/secrets/*` deny, relative+absolute spellings (the `render-opencode-config.py:48` finding) | deny `Read/Edit(**/docker/secrets/**)` + PreToolUse deny backstop | deny | deny=deny |
| file outside the project | `external_directory` ask | no same-named tool: path-scoped `Read`/`Edit` ask + cwd convention | ask | **closest-mapping** (recorded, not hidden) |
| `webfetch` | ask | ask `WebFetch` | ask | ask=ask |
| `npx *` | ask | ask `Bash(npx *)` | ask | ask=ask |

Translator behaviour: refuses (exit 1) any policy where an `over`-less `allow` beats an earlier
`ask`/`deny` without `via: "hook"`; emits ordered opencode JSON (first line `"*"` per section, as
the jsonc teaches) and a Claude `{"permissions": {"allow": [...], "ask": [...], "deny": [...]}}`
block plus, with `--render guard`, the exception JSON the hook loads from the install tree.

### 7.3 Same-verdict test

`policy/permission-cases.json`: ≥ 30 cases `{tool, command|path, expect}` covering every rule,
every `over` pair, chained/`$()`/backtick forms from the hooks docs, and each deny-after-ask row.
`lib/permission-eval.py` implements both engines standalone: the opencode evaluator reuses the
wildcard semantics already proven in `lib/merge-opencode-permissions.py` (`glob_re`,
last-match-wins, relative+absolute edit spellings); the Claude evaluator implements deny>ask>allow
over the rendered arrays with the pattern syntax spike S4 recorded. New
`tests/test_permission_policy.sh` (step 3): every case must get the **same** verdict from both
evaluators, equal to `expect`. This is the shared-case-list guard the ruling asks for.

### 7.4 Machine overlay

The rendered Claude block merges into `~/.claude/settings.json` (§8.2). The merge only rewrites
entries recorded under `_delegate.permissions`; every other entry in `permissions.*` is untouched;
`settings.local.json` is never written. OpenCode's overlay: the user's own `permission` entries are
kept exactly as today's merge does them.

### 7.5 The permission judge, Claude side

`docs/permission-judge.md` §2's opencode plugin subscribes to `permission.asked` and answers
**once**-allow. The Claude equivalent is the **`PermissionRequest`** event ("When a tool call needs
a permission decision"; output `hookSpecificOutput.decision.behavior` `allow`/`deny`, `updatedInput`
available) — event name checked against the hooks reference 2026-11-15, behaviour pending spike
S3. The shared judge core (`lib/permission-judge.py`: fixed prompt, one-word parse, §3 hard-limit
list, 2 s fail-to-human, audit jsonl) is a **later** slice, matching that doc's "plan, not built"
status; O1b installs the plumbing (hook wiring + exception list) so `permission-guard.py` today
implements only the static exception/limit logic of §7.2.

## 8. Installer: merge, never clobber, mark what is ours

### 8.1 OpenCode side

`lib/merge-opencode-permissions.py` grows (name kept; it becomes "the opencode-config merge"):

- `instructions`: ensures the array contains exactly the two delegate entries
  `~/.local/share/delegate/current/opencode/rules/harness-core.md` and `…/adapter-opencode.md`
  (release paths through `current`, the o1a-d1 rule that links go through `current`; dev checkout
  install uses the checkout paths, same as the other links); entries ours are recorded under
  `_delegate.instructions` so a re-run replaces **ours** and keeps the user's;
- `permission`: rendered from the policy (§7.2). Entries delegate owns (recorded in
  `_delegate.permissions`) are **updated in place** on re-run; foreign entries keep today's
  add-if-absent / never-rewrite behaviour (the `covered()`/`kept` logic stays);
- refuses invalid JSON, keeps unknown keys, `*.tmp` + `os.replace` — all unchanged;
- `--check` grows to cover instructions + policy sync (doctor's permission line uses it).

`opencode.json` gains the unknown top-level key `_delegate`: OpenCode's loader ignores unknown keys
(its own config carries extras in the wild). Step 5 verifies against the installed server; if the
validator ever objects, the marker moves to a sibling `~/.config/opencode/delegate-managed.json` —
recorded as a deviation, behaviour otherwise identical. Plugin links: four symlinks
`~/.config/opencode/plugins/<name>.js` → `current/opencode/plugins/<name>.js`, the skill link's
non-symlink left-alone rule verbatim.

### 8.2 Claude Code side (new install step; permissions behind a flag)

New `lib/merge-claude-settings.py`, mirroring the opencode merge's contract:

- `~/.claude/settings.json`: keep everything; merge `hooks` entries for `PostToolUse` (one
  `Edit|Write` matcher, one `*`), `SessionStart`, `PreCompact`, `PermissionRequest`, each command
  `python3 <install>/claude/hooks/harness.py` — the existing `--claude-hook` block's exec discipline
  (`agent-progress.py` entries untouched, no duplicate ids). When `--claude-permissions` is passed,
  merge the rendered `permissions` block (§7.2). Ownership marker: top-level
  `"_delegate": {"version": N, "hooks": [entry ids], "permissions": [rule strings],
  "rules_sha256": "…", "rules_target": "…"}`; re-runs update exactly those. A settings file without
  `_delegate` whose entries match our command strings is **adopted** (the upgrade path from today's
  `--claude-hook` shape).
- `~/.claude/rules/delegate-harness.md`: core+adapter as one installed file (symlink into `current/`
  when spike S7 proves Claude follows symlinked rule files; copy + `rules_sha256` otherwise).
  Never `~/.claude/CLAUDE.md` (double-load ruling, handoff §3).
- Flags: `--claude-profile` is **default-on** when `~/.claude` or a `claude` binary exists
  (rules + hooks; harmless, reversible via `_delegate`); `--claude-permissions` opts the
  permissions block in (Q2's pick); `--no-claude-profile` / `--no-claude-permissions` turn them off.
  codehub's container setup line will pass `--claude-permissions` (its own repo's follow-up, §12).
- `--uninstall` removes only entries recorded under `_delegate` (and the plugin/rules files it
  created); a hand-edited managed entry is left with a NOTE, same care as `unln` today.

## 9. `delegate doctor`: the drift section

A `harness:` block after the existing lines (one line + `fix:` per check, OK/WARN/FAIL like the
rest; exit 1 only on FAIL — drift alone is WARN so a machine mid-setup still passes `--quick`):

| line | check | drift it catches |
|---|---|---|
| `rules:` | opencode: `instructions` has our two entries pointing at the resolved install tree; claude: rules file exists, its sha256 == core+adapter concat (merge `--check`s both) | edited/stale rules on either side |
| `plugins:` | all four links present under `~/.config/opencode/plugins/`, targets under the install tree | one plugin missing → "every session" silently false |
| `hooks:` | the four `_delegate.hooks` ids present in settings.json, commands resolve under the install tree | Claude reminders/judge gone |
| `cap:` | `DELEGATE_CHUNK_CAP` from config.env vs the plugin's effective default (parse `chunk-cap.js`) vs the rule text ("the configured cap", no bare 6000 in any installed rules file) | silent cap divergence between worker and interactive |
| `permissions:` | `merge-opencode-permissions.py --check` (extended) and, when `--claude-permissions` was used, the settings block equals a fresh render; **cross-harness**: both engines on `permission-cases.json` agree | the two harnesses answering differently — the headline drift |
| `claude exempt:` | asserts **no** chunk-cap-shaped hook in settings (absence check, the exemption made observable) | someone (or a merge bug) adding a Claude cap |

Doctor reads only files; it never starts either harness (live load checks stay step 6's).

## 10. Denied paths and boundaries

The ruling list — agents may not edit `~/.config/opencode/*`, the delegate checkout's `opencode/`
and `claude/`, or `~/docker/secrets/*` — is served structurally, not by new hooks: nothing in the
profile depends on an agent editing those live. The flow stays the one AGENTS.md already mandates:
chain workers edit the repo **on a branch**; the owner's (or the container setup service's)
`install.sh` run applies the result to `~/.config/opencode/` and `~/.claude/`; `delegate update`
flips `current`, so installed content is only ever a release tree's content. Handoff §3
"Protection moves to the installed copy" is honoured once O1b lands: with a release install, the
edit-deny rules point at `~/.local/share/delegate/**` instead of the dev dirs (owner's call), and
the policy file's deny rows keep agents out of secrets/config dirs on **both** harnesses. The one
new guard this slice itself adds: the translators refuse to emit a rendering that drops a `deny`
row (a profile that silently loses denies is a FAIL, not drift).

## 11. Release and the codehub pickup

All six steps squash into one delegate release (VERSION `0.2.0`; tag `v0.2.0`, prepared locally,
**push only after asking the owner** — R-O1-5). Host: `install.sh --release v0.2.0` (or
`--from <clone>` until pushed), then `delegate update`; the profile lands through `current` like
every other file. Container: codehub's `oc/install.sh` bumps its `DELEGATE_RELEASE` constant and
re-runs the `setup` profile service (that's `delegate update` + `delegate doctor`, o1a-d2); the
container's Claude Code (R-O1-7 login volume) gets rules+hooks from the same run and, once codehub
passes `--claude-permissions`, the permissions block. Codehub-side changes are listed in §12 and are
**not** part of this chain.

## 12. What waits for later slices

- **The LLM judge itself** (both harnesses): `docs/permission-judge.md` stays "plan, not built";
  O1b ships plumbing + static exceptions only (§7.5).
- **Codehub follow-ups** (its repo, its chain): `oc/install.sh` passes `--claude-permissions` in the
  setup command and drops the hard-coded `interactive-rules.md` path from the generated
  `opencode.json` (installer owns `instructions` now); codehub's own ~14 "local model" wording
  fixes; the daemon doctor's `tool: delegate` skill detection (handoff §9) can now key off
  `_delegate`/the merged instructions instead of `opencode debug skill`.
- **Subagent propagation fixes beyond what S5b proves possible** (e.g. per-agent `instructions`
  overrides) — only if the spike shows a hole and OpenCode offers a lever.
- Guarding `~/.local/share/delegate/**` in the owner's live edit-denies (post-O1b owner call,
  handoff §3 "Protection moves to the installed copy").
- C1's Claude-in-tmux ergonomics; worker-image OpenCode pin unification (o1a-design §2).

## 13. Steps (all in `docs/specs/`, run as `o1b-chain.json`, repo `../..`, base `main`)

| step | hard | delivers | key verify addition |
|---|---|---|---|
| `o1b-1-hook-spike` | true | `claude/spikes/*` probes + `run.sh` (`--dry-run` for the sandbox), §6.1 table wired into the design, `tests/test_spikes.sh` (dry-run contract) | spikes dry-run green; probes listed |
| `o1b-2-rules-core` | false | `harness-core.md`, `adapter-opencode.md`, `adapter-claude-code.md`; `interactive-rules.md` deleted, refs updated; worker-rules slimmed (§3.3); model-neutral pass (§4 list) | rules-load test + wording grep |
| `o1b-3-policy` | true | `policy/*`, `lib/translate-permissions.py`, `lib/permission-eval.py`, `tests/test_permission_policy.sh` (shared case list, both engines) | same-verdict test |
| `o1b-4-hooks` | true | `claude/hooks/harness.py` + 4 behaviour modules (todo, verify, notes, permission-guard), notes-loop interactive fallback, `tests/test_claude_hooks.sh` (feed hook JSON, assert outputs; cap-abstence test) | hook contract tests |
| `o1b-5-install-doctor` | true | installer wiring (§8, both helpers), plugin links, rules install (S7 outcome applied), doctor drift block (§9), `tests/test_profile_install.sh`, `.clinerules` route installed per S5a/S6 | temp-HOME merge tests + doctor lines |
| `o1b-6-acceptance` | true | `tests/test_e2e_harness.sh`: full install into a temp HOME for both harnesses (fake `opencode`/`claude` stubs on PATH where the binary would prompt), re-run idempotence, `--uninstall` leaves `_delegate` empty, spike-status assertion (§6.1 no placeholder rows left), docs touch-up | end-to-end + full suite (last step) |

Order matters: 3 before 4 (guard renders from policy), 4 before 5 (installer wires real scripts),
1 before everything hook-related (ruling). Every step's verify runs the **full delegate test set**
(`for t in tests/test_*.sh; do bash "$t" || exit 1; done`) plus `bash -n` on the shell entry points
and `python3 -m py_compile lib/*.py` (+ `claude/hooks/*.py` from step 4 on), per the repo's AGENTS.md
gate, and ends with the per-step scope guard against the previous step's branch under
`set -o pipefail` (pattern from the o1a delegate chain). Live slice gate (o1-design §2 row): a
plain OpenCode session and a plain Claude Code session answer from the same rules — orchestrator +
owner, listed in step 6.

## 14. Tests (where each ruling gets its teeth)

- both engines agree on the shared case list: `tests/test_permission_policy.sh` (step 3)
- hook contracts (inputs from the hooks reference, outputs asserted): `tests/test_claude_hooks.sh` (4)
- merge never clobbers / owns-marked entries / adopt path / uninstall: `tests/test_profile_install.sh` (5, temp HOME)
- end-to-end install, both harnesses, idempotent, temp HOME: `tests/test_e2e_harness.sh` (6)
- spikes re-checkable in CI without claude: `tests/test_spikes.sh` (1)
- existing suites stay green at every step (the `for t in …` line above is in every verify).

## 15. Gate note

The chain worker's sandbox has no `claude` binary (checked 2026-11-15), so anything that must *run*
Claude Code is a probe script + orchestrator-side live run (§6), never a chain verify step. Docker
tests self-skip as today (`DOCKER=1` gates the proxy test).

## Owner questions

1. **Does Claude Code get `ask` rules at all?** The owner runs Claude Code in an auto mode with its
   own classifier (`PermissionDenied` is that classifier's branch, per the hooks reference), so
   static `ask` entries may be answers the classifier gives anyway.
   **Pick: yes, render `ask`** — the policy file stays the single truth; auto mode prompts nothing
   it can clear, and a *deny* row must exist regardless. Spike S3 records what an `ask` actually
   does under auto mode (prompt / classifier / silent allow) and if it is pure friction, the flag
   combination is `--claude-profile` without `--claude-permissions-ask` (a translator sub-flag,
   cheap to add in step 3 if S3 says so).
2. **Installer writes `~/.claude/settings.json` permissions by default, or behind a flag?**
   **Pick: behind the flag** (`--claude-permissions`, default off on the host; §8.2). The permission
   block changes how an interactive Claude behaves at every prompt; the owner's host Claude stays
   untouched until the owner opts in, while codehub's container (the parity-critical one, C1 launches
   there) passes the flag. Doctor WARNs "claude permissions not installed" so drift is visible, not
   silent.
3. **`_delegate` marker key vs sibling file** (§8.1): pick marker key; fallback pre-decided for step 5.
4. **Worker keeps `delegate-rules.md` as headless adapter rather than folding it into the core now**
   (§3.3): pick fold-later — one release of behaviour change at a time.

<!-- END -->

## Owner decisions (2026-11-15)

1. Claude Code gets **ask + deny** rules (spike S3 records what `ask` does under auto mode; if it is
   pure friction, the ask rows move behind a translator sub-flag).
2. Host `~/.claude/settings.json` permissions **behind `--claude-permissions`** (default off on the
   host; codehub's container passes it); doctor WARNs on the drift.
3. **Marker key** inside the settings files. 4. **Fold `delegate-rules.md` into the core later.**
