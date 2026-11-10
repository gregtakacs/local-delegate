# Tip splitter page

## Goal
A single static page that splits a restaurant bill, with its logic in a testable module. No build step, no dependencies; it must work opened straight from disk.

## Contract
- `tip.js` (ES module) exports `split({ bill, tipPercent, people, roundUp })` returning `{ tip, total, perPerson }`, amounts in **integer cents**.
  - `bill` is a decimal string as typed by a user (e.g. `"84.50"`). Invalid or negative → throw `RangeError`.
  - `people` is an integer ≥ 1, else `RangeError`. `tipPercent` is between 0 and 100 inclusive, else `RangeError`.
  - `roundUp: true` rounds `perPerson` up to the next whole dollar (and `total` becomes `perPerson * people`).
  - No floating-point drift: `split({bill:"0.10", tipPercent:10, people:1})` → tip 1 cent.
- `index.html` + `style.css`: inputs with ids `bill`, `tip`, `people`, `roundup` (checkbox); preset tip buttons 10/15/18/20 with `data-tip` attributes; outputs with ids `out-tip`, `out-total`, `out-per` showing formatted dollars (e.g. `$12.34`); an element `#error` that shows a human message for invalid input and is empty otherwise. Results update as the user types.
- `index.html` loads `tip.js` via `<script type="module">` and must not use `fetch` or any network.
- Tests: `tip.test.js` with node:test.

## Acceptance criteria
1. `node --test` passes.
2. The page renders correctly in each state (empty, valid input, invalid input) at 360px and 1280px wide. Verify by screenshots per your UI rules.

## Out of scope
No currency selection, no history, no frameworks.
