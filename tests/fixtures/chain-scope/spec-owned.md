# Fixture step spec: every shape `owned_paths` must read, and the ones it must not

## Read first

- modify: `lib/not_an_edit.py` — under a "Read first" heading, so this is reading, not an edit

## Files owned

- create: `hub/app.py` — the entry point
- modify: `lib/router.py`, `lib/params.py` — the route table; after the dash `lib/prose.py` is prose
- create: `hub/tests/test_routing.py`, `test_gate_order.py` (a bare filename takes the directory of
  the path before it; `in/parens.py` is prose), `test_origin.py:40`
- delete: `legacy/old_worker.py`
- modify: `docs/specs/**` — every spec under that directory
- remove: `tmp/cache/` — the cache directory (the `ROUTE_PARAMS` name here is not a path)
- read-only: `worker/egress-entrypoint.sh` — a read-only bullet is never an owned file
- create: `src/fixtures/new/**` (a fresh world). The tree under `src/fixtures/old/` is read-only for this
  step, so that sentence names no owned path.

## Contract

- modify: `lib/contract_item.md` — an owned bullet counts wherever it appears in the spec, not
  only under "Files owned"
