# Migrate the job runner off oldLog

## Goal
Carry out the logging migration described in `MIGRATION.md` across the whole codebase, and remove the legacy API.

## Read first
- `MIGRATION.md`, `src/log.js`, `test/jobs.test.js`, and the job modules in `src/jobs/` (they use several import styles).

## Contract
- `src/log.js` exports `log` with methods `debug`, `info`, `warn`, `error` (each `(msg)`), and keeps `setSink`. `oldLog` no longer exists anywhere in `src/` or `test/`.
- Every job module calls the new API. Messages, levels and LOG_LEVEL filtering stay exactly the same, including for computed levels. Calling `log[level]` with an unknown level must still throw `Error("unknown log level: <level>")`.
- Update `test/jobs.test.js` to the new API, and add a test that LOG_LEVEL filtering still works.

## Acceptance criteria
1. `node --test` passes.
2. `grep -rn oldLog src test` prints nothing.
3. For every job, the sequence of (level, message) pairs it logs is identical before and after the migration. Prove this with a comparison script under `$DELEGATE_EVIDENCE_DIR`, run against the original code (`git show HEAD:<path>` / `git worktree` is not available; use `git show` or `git archive HEAD | tar -x -C /tmp/orig`).

## Out of scope
Changing what any job computes or logs, or reformatting job modules beyond the call sites.
