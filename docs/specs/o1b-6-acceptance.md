# O1b step 6: acceptance — end-to-end install for both harnesses, spike table closed, docs honest

`"hard": true` — the last step is the slice's gate: it asserts the installed artefacts of steps 1–5
actually coexist (temp HOME, both harnesses, re-run, uninstall) and that nothing in the shipped
docs still promises what the spikes did not prove. Slice O1b step 6 of 6
(`docs/specs/o1b-design.md` §13 row 6, §14, §6.1; handoff §3 "Harness profile" acceptance
paragraphs). Repo: delegate, branch off `main`; runs after step 5.

## Read first

- `docs/specs/o1b-design.md` §6.1 (the spike table as steps 1/5 left it), §13 (the slice gate note:
  the live two-harness session check is orchestrator+owner, not a chain step), §14, §15.
- `tests/test_e2e_acceptance.sh` and `tests/test_release_install.sh` (house e2e style: temp HOME,
  fake binaries on PATH, no network, no docker, cleanup traps), `tests/test_profile_install.sh`
  (step 5's rig — reuse its helpers; do not fork a second copy of the stub machinery).
- `install.sh` (the profile block as step 5 shipped it — this step tests it, does not change it),
  `bin/delegate` doctor's harness block, `claude/spikes/run.sh`, `docs/harnesses.md` §2/§5,
  `docs/agent-install.md`, `README.md`, `AGENTS.md` (the three files this step may touch for prose).

## Contract

- `tests/test_e2e_harness.sh` — new, house style, offline, temp `HOME`, stubs for `opencode`/`claude`
  on PATH. Asserts, in order:
  1. clean install (`--no-build --runner native --claude-permissions`): both config files created
     with `_delegate` records; rules file(s) present for both harnesses; the four plugin links;
     `.clinerules` mechanism per step 5's picked route; doctor exits 0 with the harness block.
  2. idempotence: second install byte-identical configs (hash both files before/after).
  3. uninstall: `_delegate` sections empty or gone, foreign entries (pre-seeded in the fixture)
     untouched, plugin links gone, rules file gone-or-foreign.
  4. reinstall after uninstall → identical to step 1's state.
  5. worker path regression: `worker/entrypoint.sh` seeding logic exercised **without docker** the
     way `test_chain.sh` fakes it (sourceable seam or direct file assertions on the seeded temp
     HOME): core + worker adapter both land, config lists both (step 2's contract re-checked here).
- `docs/specs/o1b-design.md` §6.1: this step's author records the table's final state as found
  (rows run in the sandbox show results; Claude rows still NOT-RUN-HERE keep that marker **with a
  date** and a one-line "orchestrator must run `claude/spikes/run.sh` before merge" note under the
  table); no row says `TODO` (the acceptance grep).
- Docs honesty pass (only what the slice changed): `README.md` install section gains the profile
  sentence (what `--claude-profile`/`--claude-permissions` do, default off on host);
  `docs/agent-install.md` gains the Claude Code profile route; `docs/harnesses.md` points at
  `harness-core.md` + adapters instead of the deleted `interactive-rules.md` (grep the whole repo for
  the dead name); `AGENTS.md` mentions the profile flags on the change-delegate side if it names
  install flags today — grep, don't guess.
- Fixture hygiene: any temp dirs the test makes are under `mktemp -d` and removed on exit.

## Behaviour and edge cases

- The e2e test must pass on a machine **with** real `~/.claude` and `~/.config/opencode` present:
  it never reads them (HOME swap happens before any installer call; assert `HOME` inside the test).
- Stubs exit 0 and print nothing; one variant stub exits 1 (installer must not crash the whole
  install over a failing harness probe — assert the NOTE/skip path step 5 implemented).
- Assert no test leaves files in the repo root (`git status --porcelain` clean at test end except
  the test's own tracked files).
- If a step-5 artefact is missing (e.g. the picked `.clinerules` route), the e2e test names the gap
  in its FAIL line rather than skipping — a missing artefact is a finding for the orchestrator.

## Acceptance criteria

1. `bash tests/test_e2e_harness.sh` → PASS, exit 0.
2. `for t in tests/test_*.sh; do bash "$t" || exit 1; done` → whole suite green (Verify re-runs it).
3. `grep -rn "interactive-rules" -I . | grep -v '^./.git' | grep -v docs/specs/` → empty (dead name
   gone from shipped prose; design/spec files may keep the historical mention).
4. `grep -c TODO docs/specs/o1b-design.md` → `0`.
5. The Verify line → exit 0.

## Verify

`set -o pipefail && bash -n bin/delegate bin/delegate-wake install.sh worker/entrypoint.sh
claude/spikes/run.sh tests/test_e2e_harness.sh && python3 -m py_compile lib/*.py claude/hooks/*.py
&& for t in tests/test_*.sh; do bash "$t" || exit 1; done && ! grep -rq TODO docs/specs/o1b-design.md
&& ! git diff --name-only delegate/o1b-5-install-doctor -- ':(exclude)config.example.env' | grep
-qvE '^(tests/|docs/|README[.]md$|AGENTS[.]md$)'`

## Out of scope

Any change to `lib/`, `claude/hooks/`, `claude/spikes/`, `policy/`, `opencode/` product code — a bug
found here is reported in the summary, fixed in a review round, not silently patched around (the one
exception: adding a missing file the previous step's contract plainly required, named under
DEVIATIONS). The live two-harness slice gate (§13) — orchestrator+owner run it; the codehub pickup
and its `--claude-permissions` setup-command change (§12, codehub repo).

## Notes

This step deliberately has no product-code surface: its job is to try to *break* the slice as a
stranger would (fresh host, both harnesses, uninstall, reinstall) and to make the docs match the
evidence. A green run here plus the orchestrator's live gate is what "O1b done" means.

<!-- END -->
