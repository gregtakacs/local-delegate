# OpenCode adapter — completes `rules/harness-core.md`

This file supplies what `harness-core.md` defers, for a session running in OpenCode. Read the core
first; only harness specifics are here.

## Tools and params

Read with `read` (offset/limit); edit in place with `edit` (`oldString`/`newString`); create a file
with `write`; run shell with `bash`; plan with `todowrite`. One logical change per call, copied
`oldString` from a fresh read.

## Edit cap

Payloads over the configured cap (`DELEGATE_CHUNK_CAP`, default 8000) are rejected by the chunk-cap
plugin. Write a thin skeleton, then grow it with focused edits — the only writable shape here.

## UI-verification file

The core's `verify-ui.md` is installed at `~/.config/opencode/rules/verify-ui.md`. Read it before any
human-visible change and follow its §C before the first write.

## Notes path

When `DELEGATE_EVIDENCE_DIR` is unset, keep the core's NOTES.md at
`/tmp/opencode-notes/<repo>/NOTES.md`, where `<repo>` is the basename of the open project directory.

## Long background work

An interactive OpenCode session gets no completion notifications. For a long `delegate` command, run
it detached (`nohup delegate chain PLAN.json > chain.log 2>&1 &`, record the PID) and poll
`delegate chain PLAN.json --status` or `delegate list` sparingly — or pass `--on-step`/`--on-done`
hooks to be told instead. The report, not the polling, is what you act on.

## Delegating

For implementation bigger than a small edit, load the `/delegate` skill and follow it: you are the
orchestrator, the worker builds in a sandbox. Grants are the user's decision — never edit a grant
file.
