# AGENTS.md: for any coding agent working with or in this repo

**To USE delegate** (hand implementation to a self-hosted model while you orchestrate):

- Follow [claude/skills/delegate/SKILL.md](claude/skills/delegate/SKILL.md). It's the method:
  the local model designs the slice, you review the plan, chains run on the worker, you verify
  once per slice, and the work lands on a local branch.
- [docs/harnesses.md](docs/harnesses.md) says how to read that file from a harness other than
  Claude Code: polling instead of notifications, and no subagents.
- The worker's model can be any OpenAI-compatible endpoint with working tool calls. Run
  `delegate doctor` first.
- **Never create or edit a grant file** (`~/.config/delegate/grants/`). Access beyond the sandbox
  is the user's decision ([docs/grants.md](docs/grants.md)).

**To CHANGE delegate** (this repo):

- `bin/delegate` is bash. Running chains execute it from this checkout, so work in a separate
  worktree, and land by merging, never by editing a running copy in place.
- The sandbox and grant code (`bin/delegate`'s `run_worker_*`, `lib/grants.py`,
  `worker/egress-entrypoint.sh`) is security code. Change it only with tests
  (`tests/test_grants.sh`, `DOCKER=1` for the proxy), and never with the delegate worker
  itself: the worker must not write the code that limits the worker.
- Tests: `tests/test_grants.sh`, `tests/test_chain.sh`, `tests/test_top.sh`, `bash -n bin/delegate`,
  `python3 -m py_compile lib/*.py`.
