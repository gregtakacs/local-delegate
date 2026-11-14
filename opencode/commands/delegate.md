---
description: "Hand implementation to the local delegate worker (loads the delegate skill)"
---
Load the `delegate` skill with the skill tool and follow it for the request below. Treat the
request exactly as if the user had typed it after `/delegate` in Claude Code: a leading `raw:`,
`here:`, "in place" or "I'm watching" keeps the meaning the skill gives it.

Request: $ARGUMENTS

If the request is empty, ask what to delegate; do not start anything.
