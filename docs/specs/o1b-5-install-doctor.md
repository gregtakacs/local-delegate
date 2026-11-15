# O1b step 5: installer — merge both harnesses' configs, install the profile, teach doctor to report drift

`"hard": true` — this step writes the owner's live config files (`~/.config/opencode/opencode.json`,
`~/.claude/settings.json`): security code, merge discipline, never clobber (AGENTS.md names it;
handoff §3 "Goal" paragraph: the installer is the translator). Slice O1b step 5 of 6
(`docs/specs/o1b-design.md` §8, §9, §13). Repo: delegate, branch off `main`; runs after step 4.

## Read first

- `docs/specs/o1b-design.md` §8 (the merge contract, `_delegate` markers), §9 (doctor table), §5.1
  (plugin links), §5.4 (the subagent reach it must deliver), §10 (boundaries), §15.
- `install.sh` end to end: the flag loop, `unln`, the `--claude-hook` settings block (the json-merge
  idiom to reuse, incl. `.tmp` + `os.replace`), the skill-link "left alone" care, `--check` absence
  (doctor runs the merge `--check`), and o1a-d1's `DELEGATE_HOME=$root/current` contract (everything
  installed points **through `current`** in release mode).
- `lib/merge-opencode-permissions.py` (every line; its `covered()` and `kept` semantics are the
  contract to preserve while growing it), `bin/delegate`'s `cmd_doctor` + `install_line` (house
  format of a check line and its `fix:` tail).
- Spike results §6.1 rows S5 and S6 (they decide the `.clinerules` mechanism and what instructions
  reach); if S5 is `NOT-RUN-HERE` still, implement the design's preferred reading and mark the
  doctor line WARN with the fix "run claude/spikes/run.sh" — never guess silently.
- codehub `docs/settings/opencode-permissions.jsonc` header (the ordered-"*"-first lesson),
  step 3's `--render opencode` output shape (it is what gets merged).

## Contract

- `install.sh` (flag loop + new profile block, after the existing agent-link block):
  - `--claude-profile` / `--no-claude-profile` (default: on when `~/.claude` exists),
    `--claude-permissions` / `--no-claude-permissions` (default: **off**; design Q2's pick);
  - OpenCode (when `opencode` is on PATH, as today): call the extended merge helper with
    `--instructions <core> <adapter-opencode>` (paths through `$DELEGATE_HOME`, like every other
    link), `--permission-policy policy/harness-permissions.json --render` (it invokes
    `lib/translate-permissions.py --render opencode` internally and merges that; the old
    skill/`external_directory` entries stay exactly as today, they are machine entries, not policy);
    then the four plugin symlinks `~/.config/opencode/plugins/<name>.js`
    → `$DELEGATE_HOME/opencode/plugins/<name>.js` with `unln`-style care (non-symlink → NOTE, left).
  - Claude (new block): `lib/merge-claude-settings.py` writes the `hooks` entries (events
    `PostToolUse`×2, `SessionStart`, `PreCompact`, `PermissionRequest`; command
    `python3 $DELEGATE_HOME/claude/hooks/harness.py`, `timeout 10`, sync), merges the rendered
    `permissions` block **only** with `--claude-permissions`, records `_delegate` (ids, rule strings,
    `rules_sha256`, `target`), and writes `~/.claude/rules/delegate-harness.md` = core+adapter
    concatenated, **or** the symlink into `current/` when spike S7 recorded PASS for symlinks
    (choice is data: a constant at the top of the helper, default copy until S7 says otherwise).
    Refuse (exit 1, file untouched) a `~/.claude/settings.json` that is not valid JSON; keep unknown
    keys; re-run updates only `_delegate`-recorded entries; an existing hand-written `hooks` entry
    with the same command string is adopted into `_delegate.hooks` (idempotence for the pre-existing
    manual install the owner has today); the old `--claude-hook` block is **replaced** by a call
    into the same helper (agent-progress entries move under `_delegate.hooks` too, same commands —
    no behaviour change for the dashboard).
  - `.clinerules` route per spike S6: OpenCode side appends the chosen `instructions` glob entry
    (or records its refusal); Claude side appends the chosen one-liner to the rules file (import or
    rule sentence) — one if/else in the helper, both branches shipped, pick stored as a constant.
  - `--uninstall` removes the four plugin links, the rules file (only when its sha/symlink is ours),
    and every `_delegate`-recorded hook/permission entry from both config files, leaving everything
    else; `--purge` unchanged otherwise.
- `lib/merge-opencode-permissions.py`: extended as designed; **`--check` must still exit 0 on today's
  already-merged configs** (back-compat: an existing config lacking `instructions` is a check FAIL
  only after `--instructions` was ever passed — encode this as: `_delegate` absent + instructions
  missing → WARN line from the helper, doctor turns it into the fix line; `_delegate` present +
  entries wrong → FAIL).

- `bin/delegate` doctor: the §9 block, six lines, house format, each with a `fix:` naming the exact
  command; runs the merge helpers' `--check`s and the cross-engine case-list evaluation
  (`permission-eval.py` over both renderings — the headline drift check, cheap: one subprocess).
  `doctor --quick` prints the block too but downgrades FAILs to WARN (the existing `--quick`
  semantics: it skips the live probe, not the config review).
- `tests/test_profile_install.sh` (house style; temp `HOME`, stub `opencode`/`claude` on PATH as
  executable no-ops — the installer must not need the real harnesses to install their files):
  fresh install merges; re-run idempotent byte-for-byte; unknown keys kept (`model`, a foreign hook
  survive); a hand-edited managed entry left with NOTE on uninstall; invalid settings.json refused
  untouched; adopt path (pre-seed the manual hook entry, expect it under `_delegate` after install);
  plugin links point at `$DELEGATE_HOME` (works in both `--from` release mode and dev mode via
  `test_release_install.sh`'s local-git-repo trick); doctor drift: break one thing per case
  (delete a plugin link, stale rules sha, deny row missing from settings) → expect the exact line +
  `fix:`; `--claude-permissions` off → settings carry no `permissions` key and doctor WARNs.

## Behaviour and edge cases

- No real `$HOME` reads anywhere in the new tests (the I1 lesson: isolation first; everything under
  the temp `HOME`).
- Paths with spaces in `HOME` (the i1 review's fixture lesson): every new link/merge handles them.
- `~/.claude` exists but is a file (not dir) → refuse with fix line, don't rmdir.
- A `settings.json` where `permissions` exists but has no `_delegate` record → the merge **adds** its
  entries and adopts identical strings; it never removes foreign entries and never claims foreign
  ones in `_delegate`.
- The opencode `permission` array form (not pattern-map): merge refuses with today's message
  (unchanged).
- Doctor runs offline (config-file checks only).

## Acceptance criteria

1. `bash tests/test_profile_install.sh` → PASS, exit 0.
2. `bash tests/test_release_install.sh` → still green (the `--from` mode links point through
   `current`, nothing absolute to a worktree).
3. `HOME=$T PATH=$STUBS:$PATH ./install.sh --no-build --runner native --claude-permissions
   --key-file "$T/k" && bin/delegate doctor` in the test rig's temp HOME → exit 0 and the harness
   block's six lines on stdout.
4. The Verify line → exit 0.

## Verify

`set -o pipefail && bash -n bin/delegate bin/delegate-wake install.sh worker/entrypoint.sh
claude/spikes/run.sh && python3 -m py_compile lib/*.py claude/hooks/*.py && for t in tests/test_*.sh;
do bash "$t" || exit 1; done && ! git diff --name-only delegate/o1b-4-hooks --
':(exclude)config.example.env' | grep -qvE '^(install[.]sh$|bin/delegate$|lib/|tests/|docs/|README[.]md$|worker/)'`

## Out of scope

New hook behaviours (step 4 owns the scripts; step 5 only wires and merges), policy content (step 3),
rule wording (step 2), codehub's generated container config and its setup-service flag line (§12:
codehub repo), the worker image build (`--no-build` respected by tests; nothing rebuilds here).

## Notes

"If the `_delegate` key ever trips the opencode schema validator, the marker moves to
`~/.config/opencode/delegate-managed.json`" is pre-decided in the design (§8.1): if step 5's live
check hits it, move the **opencode** marker only (sibling file, same ids), add a deviation line to
the design, keep the Claude `_delegate` (settings.json tolerates unknown keys per the settings doc).

<!-- END -->
