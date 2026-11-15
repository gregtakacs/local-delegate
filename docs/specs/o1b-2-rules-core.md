# O1b step 2: split the rules into a harness-neutral core and two adapters; model-neutral wording

`"hard": false` — documentation/rule content, no boundary code, but the test policy must survive the
split intact. Slice O1b step 2 of 6 (`docs/specs/o1b-design.md` §3, §4, §13; handoff §3 "Harness
profile" (the split sentence, the test-policy bullet and the model-neutral ruling) and "Plain Claude
Code sessions follow the same rules too" bullet 3). Repo: delegate, branch off `main`; chain runs
after step 1's branch.

## Read first

- `docs/specs/o1b-design.md` §3 (the section-by-section split map), §4 (the wording table — it is
  the contract's list), §5.3 (cap wording), §7.4 notes, §8.1 (what the installer will expect: file
  names and the through-`current` paths).
- `opencode/interactive-rules.md` (the source of the core), `opencode/delegate-rules.md` (the worker
  deltas to keep; §4/§7 hold the test policy moving to the core), `opencode/rules/verify-ui.md`
  (stays), `worker/entrypoint.sh` + `lib/render-opencode-config.py:76-78` (how the worker loads
  rules today; §3.3's change), `docs/harnesses.md` §2/§5 (background-work wording the adapters reuse).
- `tests/test_top.sh` and `tests/test_skill_frontmatter.sh` (guards that will see the rename; keep
  both green — the skill frontmatter must stay valid YAML).

## Contract

- Create `opencode/rules/harness-core.md`, `opencode/rules/adapter-opencode.md`,
  `opencode/rules/adapter-claude-code.md` exactly as §3.1/§3.2 maps them. Hard requirements:
  - core names no tool binary name, no `~/.config/opencode` path, no Claude path, no cap number;
    it says "the configured edit cap" where hygiene needs it, and points at "your harness adapter"
    for paths/tools; it contains the **workers run only their step's tests** policy (the exact
    rule as the o1a specs practise it: a worker changes only its step's scope; the step's verify
    line runs the repo's full gate) phrased for the worker reading it;
  - adapters ≤ 40 lines each, starting with a line naming the core file they complete;
  - `adapter-claude-code.md` carries the exemption sentence (no edit cap; hygiene as style advice)
    and a `.clinerules` paragraph written route-neutral ("read `.clinerules` and `.clinerules/*.md`
    in the open project if present"; step 5 installs the mechanism spike S6 picked);
  - `adapter-opencode.md` carries the notes fallback path `/tmp/opencode-notes/<repo>/NOTES.md`,
    the detached-run-and-poll paragraph (from interactive §14 / harnesses.md), the cap sentence
    "the configured cap (`DELEGATE_CHUNK_CAP`, default 8000)", the `verify-ui.md` install path, and
    the `/delegate` skill pointer.
- Delete `opencode/interactive-rules.md`; fix every reference in the repo (grep it; includes
  codehub-facing prose: this repo's docs may mention the new paths only).
- `opencode/delegate-rules.md`: strip sections now in the core (keep deltas only: turn-ends-task,
  STATUS block, evidence dir, review rounds, boundaries-no-git variant, §12a self-review detail);
  first lines state it is the headless adapter and that the core loads with it.
- `worker/entrypoint.sh`: seed `rules/harness-core.md` with the existing `cp -r rules` (already
  covered by the recursive copy — verify, don't assume) and `lib/render-opencode-config.py`:
  `instructions: [f"{cfg_dir}/rules/harness-core.md", f"{cfg_dir}/delegate-rules.md"]`.
- Wording pass, the §4 table verbatim as the worklist (every line number re-grepped, positions may
  have drifted): "local model"/"self-hosted model" → worker/orchestrator phrasing per the table's
  fix column; the only surviving literal is the user-trigger quote `"send to the local model"` in
  the skill description.

## Behaviour and edge cases

- The worker still gets one coherent ruleset after compaction: core first, worker adapter second —
  the entrypoint seeds both and the config lists both; a missing core file must not be silently
  tolerated: `render-opencode-config.py` keeps listing it, `tests/test_render.sh` asserts the two
  entries (extend the existing test).
- Renumbered sections: cross-references inside the rules ("§3", "§13") must all resolve in the new
  files — the load test greps every internal `§<n>` mention against the new numbering.
- Skill description stays valid YAML unquoted-safe (the `: ` trap, `test_skill_frontmatter.sh`).
- No behaviour text weakened in transit: the Definition-of-Done list, the PID-kill rule, the
  no-pkill rule and the "environmental is a claim" sentence survive word-for-word into the core
  (the load test diffs key phrases).

## Acceptance criteria

1. `python3 -c "import subprocess"`-free load check: `bash tests/test_rules_load.sh` → PASS, exit 0
   (new test: files exist; core contains the DoD gate phrases, the test policy and no tool names —
   grep `opencode|claude|TodoWrite|todowrite|Edit\(` finds nothing outside code-word exemptions
   listed in the test; adapters ≤ 45 lines each; internal `§` refs resolve; interactive-rules.md is
   gone and no tracked file references it).
2. `bash tests/test_render.sh` → green with the new two-entry `instructions` assertion.
3. `grep -rniE "local model" -I . | grep -v evals/ | grep -v 'send to the local model'` → empty.
4. The Verify line → exit 0.

## Verify

`set -o pipefail && bash -n bin/delegate bin/delegate-wake install.sh worker/entrypoint.sh
claude/spikes/run.sh && python3 -m py_compile lib/*.py && for t in tests/test_*.sh; do bash "$t" ||
exit 1; done && ! git diff --name-only delegate/o1b-1-hook-spike -- ':(exclude)config.example.env'
| grep -qvE '^(opencode/|worker/|claude/skills/|claude/agents/|docs/|README[.]md$|AGENTS[.]md$|tests/)'`

## Out of scope

Any `install.sh`/merge changes (step 5), Claude hook scripts (step 4), policy files (step 3),
`evals/` fixture wording (frozen measured prose), README restructuring (wording edits only), codehub's
~14 wording positions (its repo).

## Notes

The core is deliberately the *interactive* text reborn neutral: the worker adapter keeps headless
teeth, the shared prose lands once. Deleting `interactive-rules.md` in the same step that creates
its replacements keeps every intermediate commit bootable (entrypoint/config change here too).
