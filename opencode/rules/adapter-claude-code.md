# Claude Code adapter — completes `rules/harness-core.md`

This file supplies what `harness-core.md` defers, for a session running in Claude Code. It is
installed as `~/.claude/rules/delegate-harness.md`, never `~/.claude/CLAUDE.md`. Read the core first;
only harness specifics are here.

## Tools and params

Read with `Read` (offset/limit); edit in place with `Edit`; create a file with `Write`; run shell
with `Bash`; plan with the todo tool; hand a slice to a worker with `Task`. One change per call.

## Edit cap — exempt

Claude Code enforces no payload cap here. The core's grow-don't-one-shot hygiene is style advice
only: write a thin skeleton, then grow it. Nothing rejects a large write.

## UI-verification file

The core's `verify-ui.md` ships beside this adapter; read it before any human-visible change and
follow its §C before the first write.

## Notes path

Keep the core's NOTES.md at `/tmp/opencode-notes/<repo>/NOTES.md` (the same convention as OpenCode),
unless a task-notes path is set for the session.

## Project rules

Read `.clinerules` and `.clinerules/*.md` in the open project if present, and follow them.

## Long background work and delegating

Claude Code notifies on background completion, so run long chains in the background and act when
they finish. The `/delegate` skill and the `delegate-lead` agent are the entry points. Grants are the
user's decision — never edit a grant file.
