# Isolate delegate's inline python helpers from the cwd

## Goal
Every inline python helper in `bin/delegate` (`python3 -c '...'` and `python3 - <<...`) runs with
`-I`, so a module planted in the caller's working directory (for example a `json.py`) can never be
imported by them. This is unconditional and must change nothing else.

## Read first
- `docs/specs/sg-design.md` (row 4 of §2)
- `bin/delegate`: `grep -n 'python3 -c\|python3 - ' bin/delegate` lists every helper
- `tests/test_round_commit.sh` (static test style) and `tests/test_worktree_layout.sh` (behavioural style, temp HOME/state)

## Contract
- Every occurrence of `python3 -c` becomes `python3 -I -c`, and every `python3 -` (stdin script) becomes `python3 -I -`. Keep the arguments, the environment prefixes (`DELEGATE_LIB_DIR=... python3 -I - ...`) and the redirections exactly as they are.
- Do not touch `python3 "$DELEGATE_HOME/lib/<x>.py"` script calls, and don't touch `lib/safepath.py`, `lib/sandbox-git.sh` or the `sbx`/`untrusted*` functions.
- New test `tests/test_python_isolation.sh`, same `check` helper style as the other suites:
  1. static: `grep -nE 'python3 +(-c|-)( |$)' bin/delegate` finds nothing that lacks `-I` (no inline helper without `-I`);
  2. behavioural: in a temp dir holding a planted `json.py` that writes a marker file when imported, run `bin/delegate accept ID -m "why"` against a fabricated task in a temp `DELEGATE_STATE` (a `meta.env` with `ID`, `SLUG`, `REPO`, `WORKTREE`, `BRANCH`, `HERE=0`, plus `rounds/1/report.json` with `{"status":"failed"}`), with cwd = that temp dir. Assert accept succeeded, `accept.json` exists, and the marker was NOT written. Also run the same with the plain `python3 -c 'import json'` from that cwd and assert the marker IS written there (proves the plant works);
  3. the test touches no real `$HOME` (set `HOME`, `DELEGATE_STATE`, `DELEGATE_CONFIG=/dev/null`, `DELEGATE_PROGRESS=0`).

## Behaviour and edge cases
`-I` also ignores `PYTHON*` environment variables and user site-packages. None of the helpers use them (they read `DELEGATE_*` via `os.environ` and insert `DELEGATE_LIB_DIR` themselves). Confirm by reading each helper.

## Acceptance criteria
- `bash -n bin/delegate && python3 -m py_compile lib/*.py && for t in tests/test_*.sh; do bash "$t" || exit 1; done` passes (the full gate).
- `bash tests/test_python_isolation.sh` prints only `ok` lines.

## Out of scope
Anything in `lib/*.py`, chain.py, docs.
