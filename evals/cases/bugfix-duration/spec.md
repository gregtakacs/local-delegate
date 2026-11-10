# Fix the duration bugs in ISSUES.md

## Goal
Fix every bug report in `ISSUES.md` (#41–#45) in `src/duration.js`, without changing behaviour that isn't reported as a bug: the output format, the `largest` option and the exports stay as they are.

## Read first
- `ISSUES.md`, `src/duration.js`, `test/duration.test.js`.

## Contract
- For each issue, add a regression test to `test/duration.test.js` that fails on the current code and passes after your fix. Name each test after its issue number (e.g. `"#41 singular units"`).
- Don't rewrite the module from scratch. Make focused fixes.

## Acceptance criteria
1. `node --test` passes.
2. Each regression test fails against the original `src/duration.js` (`git show HEAD:src/duration.js`). Prove that in your summary.

## Out of scope
New features, other units, i18n.
