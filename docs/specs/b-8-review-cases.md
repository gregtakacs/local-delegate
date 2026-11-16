# Task B8: review cases — seeded defects at known places, and clean changes

`"hard": false`. Slice B step 8 of 10 (`docs/specs/b-design.md` §Bundles "Review case", R16).

## Goal

Ground truth for benchmarking reviewers: five review bundles under `evals/review-cases/`, each a
base repo, a change, the spec the change was meant to implement, and a `truth.json` saying
whether the change should be accepted and exactly where its defects are. Three changes carry
seeded defects that the visible tests do **not** catch; two are clean. A test proves every piece
of the truth by running it: clean changes pass every hidden check, each seeded defect makes its
own hidden check fail, and each defect's `fix` (applied to exactly its `start..end` lines) makes
that check pass.

## Read first

- `docs/specs/b-design.md` §Bundles (the review-case layout and `truth.json`), §Review (how
  findings are matched to defects: same file, line within `start-3..end+3`).
- `lib/bench.py` (B1) — `load_case`, `load_truth` (including the optional `fix`).
- `evals/cases/py-semver/` — a Python case's `setup.sh`, `case.env`, `hidden/check.sh` +
  `check.py` style (PASS/FAIL lines).

## Contract

Every case: `case.env` = `KIND=review` and `VERIFY="python3 -m unittest -v 2>&1 | tail -30"`;
`setup.sh` copies `$2/base/.` into `$1`; `base/`, `change/`, `spec.md`, `truth.json`,
`hidden/check.sh` (runs `python3 .eval-hidden/check.py` from the tree root, as py-semver's does),
`hidden/check.py`. Python 3.10+ stdlib only. `change/` holds whole files (overlaid on the base);
no deletions are needed in these five (no `.delete` file).

Blindness rules for every file a reviewer can see (`base/`, `change/`, `spec.md`): no comment or
name containing `seed`, `defect`, `bug`, `TODO`, `FIXME`, `XXX`, `hack`, `intentional`; the
seeded code reads like an honest attempt. `truth.json` `what` sentences and `fix` lines are never
shown to a reviewer (B9 copies neither).

1. **`rv-slug-clean`** — spec: `slug.py` exports `slugify(text: str, max_len: int = 40) -> str`:
   NFKD-normalize, drop non-ASCII, lowercase, every run of characters outside `[a-z0-9]` becomes
   one `-`, strip leading/trailing `-`, then cut to `max_len` and strip a trailing `-` the cut
   left; an empty result is `"n-a"`; `max_len < 1` raises `ValueError`. Base: `slug.py` with the
   signature raising `NotImplementedError`, `test_slug.py` with two trivial tests marked
   `unittest.skip`, a README. Change: a correct `slug.py` and a `test_slug.py` with ≥ 6 real
   tests. `truth.json`: `accept`, no defects.
2. **`rv-slug-seeded`** — the same base and spec. Change: `slug.py` with exactly two defects and
   the same visible tests passing:
   - `d1` high: the cut happens after the trailing-`-` strip, so `slugify("ab cd", 3)` returns
     `"ab-"`.
   - `d2` medium: non-ASCII letters are dropped without NFKD normalization first, so `"café"`
     becomes `"caf"` instead of `"cafe"`.
3. **`rv-ratelimit-seeded`** — spec: `ratelimit.py` exports `class TokenBucket(rate: float,
   burst: int)` with `allow(key: str, now: float) -> bool` (each key starts full at `burst`,
   refills `rate` tokens per second continuously, capped at `burst`; one token per allowed call)
   and `client_key(environ: dict) -> str` returning `environ["REMOTE_ADDR"]` — the app runs with
   no trusted proxy, so forwarding headers must be ignored. Base: stubs + a README. Change:
   implementation + tests, with:
   - `d1` high (the security one): `client_key` returns the first `HTTP_X_FORWARDED_FOR` entry
     when present — any client can pick its own rate-limit key.
   - `d2` medium: refill uses `int(elapsed * rate)` and resets the key's timestamp on every call,
     so with `rate = 0.5` a key polled every second never refills.
4. **`rv-paginate-clean`** — spec: `paginate.py` exports `paginate(items: list, page: int,
   per_page: int) -> dict` → `{"items", "page", "pages", "total"}`; pages are 1-based; `pages =
   ceil(total / per_page)` (0 when `total == 0`); `page < 1` or `per_page < 1` raises
   `ValueError`; a page past the end returns `items: []` with the true `pages`/`total`. Base:
   stub + README. Change: correct implementation + ≥ 6 tests. `accept`.
5. **`rv-paginate-seeded`** — the same base and spec. Change with:
   - `d1` medium: `pages = total // per_page`, so a partial last page is missing from `pages`
     (and `paginate(list(range(5)), 3, 2)` returns `[]`).
   - `d2` medium: `page < 1` is not rejected; `page = 0` slices from `-per_page` and returns the
     last items.

`truth.json` for the seeded cases: `"verdict": "reject"`, each defect with `id`, `file`, `start`,
`end` (the smallest line range holding the faulty logic, 1-based, in the `change/` file), the
`severity` above, a one-sentence `what`, and `fix` (replacement lines for `start..end` that make
the code correct). `hidden/check.py` prints one line per check: `PASS <name>` or `FAIL <defect
id> <name>` for checks that target a seeded defect (clean cases use the same checks, all PASS);
≥ 6 checks per case.

### `tests/test_review_cases.sh` — create

For every dir in `evals/review-cases/`:
1. `load_case` succeeds and `kind == "review"`.
2. Build the after-tree in a temp dir (`setup.sh` then overlay `change/`), run its `VERIFY`
   command: exit 0 for **all five** (the visible tests do not catch the seeded defects).
3. Copy `hidden/` to `.eval-hidden/` in the after-tree, run `check.sh`: clean → ≥ 6 `PASS` and no
   `FAIL`; seeded → the set of defect ids on `FAIL` lines equals the `truth.json` defect ids.
4. For each defect: a fresh after-tree with only that defect's `fix` applied to lines
   `start..end` of its `file` → its `FAIL <id>` lines are gone, the other defect's remain, and
   `VERIFY` still passes. With every fix applied → no `FAIL` at all.
5. Blindness grep: none of the forbidden words (case-insensitive) in `base/`, `change/`,
   `spec.md`.
6. The base alone (no change) runs `check.sh` without crashing the checker (FAIL lines are fine).

## Out of scope

- Running reviewers (B9). No changes outside `evals/review-cases/**` and the new test.

## Verify

Mid-round, `tests/test_e2e_harness.sh`'s hygiene check blames untracked deliverables; the harness
commits before the chain's verify runs. If that is the only failure mid-round, report it; never
edit that test.

```bash
set -o pipefail && bash -n bin/delegate && python3 -m py_compile lib/*.py && [ -f tests/test_review_cases.sh ] && for f in tests/test_*.sh; do l=/tmp/gate-$(basename "$f" .sh).log; env -u DELEGATE_EVIDENCE_DIR bash "$f" >"$l" 2>&1 || { echo "GATE FAIL $f"; grep -h FAIL "$l" | head -20; exit 1; }; done && ! git diff --name-only delegate/b-7-bench-run | grep -qvE '^docs/specs/b-|^evals/review-cases/|^tests/test_review_cases\.sh$' && echo GATE-OK
```

## Report format

```text
STATUS: done|partial|blocked
SUMMARY: <=3 sentences
TESTS: <counts; which suites ran; gate result>
RISKS: <what might still be wrong>
DEVIATIONS: <departures from this spec and why, or none>
```
