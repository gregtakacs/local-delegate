# SemVer parse and compare

## Goal
A stdlib-only Python module implementing SemVer 2.0.0 parsing and precedence.

## Contract
- `semver.py` at the repo root:
  - `parse(s: str) -> Version`, raising `ValueError` for anything that is not a valid SemVer 2.0.0 string (follow semver.org §2, §9, §10 exactly: no leading zeros in numeric identifiers, no empty identifiers, build metadata allowed).
  - `Version` is a frozen dataclass with fields `major`, `minor`, `patch` (ints), `prerelease` (tuple of str|int), `build` (tuple of str), supports `str(v)` round-tripping the input, and total ordering by SemVer precedence (§11). Build metadata is ignored for ordering and equality.
  - `compare(a: str, b: str) -> int` returning -1, 0 or 1.
- `test_semver.py`: unittest tests.

## Acceptance criteria
1. `python3 -m unittest -v` passes.
2. The tests include the §11 precedence chain `1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-alpha.beta < 1.0.0-beta < 1.0.0-beta.2 < 1.0.0-beta.11 < 1.0.0-rc.1 < 1.0.0` and invalid inputs.

## Out of scope
No CLI, no packaging files, no dependencies.
