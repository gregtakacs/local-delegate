# <Short imperative title — becomes the task name>

## Goal

<Two or three sentences: what this step delivers and why, in terms of behaviour. Link it to
the larger plan: "Slice W2 of docs/design.md §12: ...".>

## Read first

- `docs/design.md` §<n> — <what to take from it>
- `<path/to/existing/file>` — <the pattern to imitate: structure, naming, error style>
- `<path/to/types-or-schema>` — <the types it must use, not redefine>

## Contract

<Everything that must come out exactly as written. Be literal.>

- Files to create / modify: `<path>` — <purpose>
- Routes / functions / components: `<signature or METHOD /path>` → <inputs, outputs, status codes>
- Data: `<table.column>` types, constraints, indexes; migration name `<name>`
- Env vars: `<NAME>` — <meaning, default>
- Error shapes / copy text: <verbatim>

## Behaviour and edge cases

- <rule> — e.g. "a second handle change inside 14 days → 409 `{ error: "handle_cooldown" }`"
- <empty / invalid / unauthorized / duplicate cases and what each returns>

## Acceptance criteria

Each one is a command and its expected result; the worker must run all of them.

1. `<command>` → <expected>
2. `<command>` → <expected>

## Out of scope

- <things a helpful worker might add but must not: other routes, styling, refactors of X>
- Do not modify: `<paths>`

## Notes

<Constraints, gotchas you already know, decisions already made and their reasons.>
