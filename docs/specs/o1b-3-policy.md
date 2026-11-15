# O1b step 3: the permission policy file, the two renderers, the shared-verdict test

`"hard": true` — this is the security translation the handoff calls "the biggest gap": a wrong
verdict here silently prompts where it should block or, worse, allows where today an owner types a
password. Review line by line; retries 2. Slice O1b step 3 of 6 (`docs/specs/o1b-design.md` §7,
§13; handoff §3 "Permissions (biggest)" + the OpenCode last-match-wins finding of 2026-11-15). Repo:
delegate, branch off `main`; chain runs after steps 1–2.

## Read first

- `docs/specs/o1b-design.md` §7 in full (policy shape, the exception rule, the worked table — the
  table is the spec's seed list), §6 S3/S4 (what may not be assumed until the spike says so),
  §8.1–§8.2 (who will consume the renderings next steps).
- codehub `docs/settings/opencode-permissions.jsonc` (READ-ONLY reference mount; the stance and the
  ~70 rules; de-site it: the daemon-name, the localhost port and the `install.sh` allow lines do not
  come; everything else is policy).
- `lib/merge-opencode-permissions.py` (`glob_re`, `covered`, last-match scan — reuse, don't fork
  semantics), `lib/render-opencode-config.py:48-61` (`edit_denies`: relative **and** absolute
  spellings — the policy renderer must emit both for every denied directory),
  `docs/permission-judge.md` §3 (the hard-limit list: anything that may never be auto-allowed is
  deny-or-ask, never allow, in the policy too).
- `tests/test_merge_opencode_permissions.sh` and one more `tests/test_*.sh` (house style).

## Contract

- `policy/harness-permissions.json` — the one policy file. Design §7.1's schema exactly:
  `version`, ordered per-tool rule lists (`bash`, `read`, `edit`, `external_directory`, `webfetch`,
  `skill`, `doom_loop` as needed), each rule `{pattern, effect, over?, via?, note?}`; the first
  `bash` rule is `{pattern:"*", effect:"ask"}` unless the worked table's default-posture note says
  otherwise; `deny` rows include the judge doc §3 list (sudo/doas, force-push forms, `rm -rf /`,
  pattern kills, `**/docker/secrets/**`, `.env`/key/pem paths); every `allow` that overrides an
  earlier broader rule carries `over`, and `via:"hook"` exactly where §7.2's exception rule applies.
  No site values, no host names, no ports.
- `policy/permission-cases.json` — ≥ 30 cases `{tool, input, expect, why?}`: each policy rule hit at
  least once, each `over` pair as *both* the broad and the narrow command, the chained/`$()`/backtick
  forms the hooks doc lists, `.env` read vs edit (different verdicts), a secrets path, a
  health-port-shaped curl (written generically: `curl http://127.0.0.1:9/healthz` — loopback is not
  a site value), one external-directory path, one webfetch.
- `lib/translate-permissions.py`:
  `--policy PATH --render opencode|claude|guard [--out -] [--check]`.
  opencode rendering: ordered pattern maps preserving file order, `"*"` first, deny rows emitted in
  both spellings (`**/docker/secrets/**` as `{abs}/**` plus relative, per the `edit_denies` finding,
  absolute from `~`-expansion at render time with `--home HOME` for testability). Claude rendering:
  `{"permissions": {"allow": [...], "ask": [...], "deny": [...]}}` with `Bash(...)`/`Edit(...)`/
  `Read(...)`/`WebFetch` strings; pattern syntax = spike S4's recorded form, defaulting to
  `Bash(git push *)` style and `**`/`*` path globs, one constant block at the top of the file so the
  form is one reviewed edit if S4 surprises. `--render guard`: JSON for step 4's hook:
  `{version, allow_exceptions: [...], deny: [...]}` (deny rows duplicated as a hook backstop).
  Refusals (exit 1, nothing written): an allow overriding an earlier ask/deny without `over`+`via`;
  a rendered opencode or claude set that drops any policy deny row (the §10 guard: re-scan both
  renderings against the deny list); unknown effect strings; empty section with a non-empty policy.
- `lib/permission-eval.py`: `--engine opencode|claude --config - < case.json` prints
  `verdict <allow|ask|deny>` per case. opencode engine: last-match-wins with `glob_re` semantics
  imported from the merge script (shared function; the merge script's CLI unchanged). Claude engine:
  deny>ask>allow over the rendered arrays, Bash subcommand splitting (`&&`, `||`, `;`, `$()`,
  backticks per the hooks doc's `if` table — splitting lives in ONE function with a comment naming
  the doc; conservative: unparseable command → engine says the *broadest* verdict any subcommand
  could reach, which is deny > ask > allow precedence, never an upgrade).
- `tests/test_permission_policy.sh` — house style; runs translate over the shipped policy into a
  temp dir, feeds every case to both engines, asserts engine==engine==`expect`; plus translator
  refusal tests (construct the bad policies inline), deny-survival checks, and a golden test that
  `--render opencode` output parses with the merge script's own `covered()` (so the merge step's
  doctor `--check` will agree with the renderer).

## Behaviour and edge cases

- Re-running the translator is byte-stable (ordered dicts, no timestamps anywhere).
- `.env` asymmetry honoured: read=ask, edit=deny must both hold for the same path string.
- The renderer emits both `.env` relative and `**/.env*` deep forms as the case list demands
  (opencode matched-relatively; Claude patterns per S4).
- `permission-cases.json` is data, not code: an added row must be enough to fail the test when a
  future policy edit breaks parity (the test asserts ≥1 case per rule id via a `note` convention).

## Acceptance criteria

1. `bash tests/test_permission_policy.sh` → PASS, exit 0.
2. `python3 lib/translate-permissions.py --policy policy/harness-permissions.json --render opencode
   --home /home/t | python3 -c "import json,sys; d=json.load(sys.stdin); assert
   list(d['bash'])[0]=='*' and d['bash']['*']=='ask'"` → exit 0.
3. The Verify line → exit 0.

## Verify

`set -o pipefail && bash -n bin/delegate bin/delegate-wake install.sh && python3 -m py_compile
lib/*.py && for t in tests/test_*.sh; do bash "$t" || exit 1; done && ! git diff --name-only
delegate/o1b-2-rules-core -- ':(exclude)config.example.env' | grep -qvE
'^(policy/|lib/|tests/|docs/specs/)'`

## Out of scope

Installer/merge wiring (step 5), hook code (step 4), the LLM judge (stays unbuilt, §7.5), worker
config (`render-opencode-config.py` keeps its headless all-allow posture: the worker boundary is the
container, unchanged this slice), codehub's own permission file (it keeps its copy; only its
*stance* migrates).

## Notes

The worked table in §7.2 rows are test cases already; adding a row to the table means adding it to
`permission-cases.json` in the same commit. If spike S4 lands contradicting the default pattern
form, change the constant block, not the policy.
