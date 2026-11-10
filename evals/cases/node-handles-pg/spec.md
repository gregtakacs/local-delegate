# Handle store on Postgres

## Goal
Persist user handles in Postgres with a small data layer over `pg`, a migration, and tests that run against the real database at `$DATABASE_URL`.

## Contract
- Dependency: `pg` 8.x only.
- `migrations/001_handles.sql`: table `handle(handle text primary key, user_id text not null, created_at timestamptz not null default now(), retired_at timestamptz)` and a unique partial index so a user has at most one non-retired handle.
- `src/store.js` exports:
  - `migrate(pool)` — applies `migrations/*.sql` in order, idempotently, tracking applied files in a table `_migrations(name text primary key)`.
  - `claimHandle(pool, userId, handle)` → `{ ok: true }` or `{ ok: false, error: "taken" | "user_has_handle" }`. A retired handle stays taken forever.
  - `retireHandle(pool, handle)` → `true` if a live handle was retired, else `false`.
  - `currentHandle(pool, userId)` → the user's live handle string, or `null`.
- `npm run migrate` runs `migrate` against `$DATABASE_URL`.

## Acceptance criteria
1. `npm install && npm run migrate && npm run migrate` → both migrate runs succeed.
2. `npm test` passes, with store tests against the real database.

## Out of scope
No HTTP server, no ORM, no handle-format validation.
