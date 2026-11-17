# delegate chain: honour DELEGATE_UNTRUSTED_REPO

## Goal
With `DELEGATE_UNTRUSTED_REPO=1` in the environment, `lib/chain.py` never runs plain host git on the
plan's repo. With it unset or `0`, chain.py behaves exactly as now.

## Read first
- `docs/specs/sg-design.md` §2 row 9
- `lib/chain.py`: `git()`, `dirty()`, `commit_step()`, the in-place block in the runner (`if here:` near `start_head`), and the two closing `git diff --stat=120` calls
- `bin/delegate` `cmd_repo_git` (the internal `_repo-git REPO -- GIT-ARGS` subcommand, already there)
- `tests/test_chain.sh` (the fake delegate via `DELEGATE_CHAIN_BIN`)

## Contract
- `UNTRUSTED = os.environ.get("DELEGATE_UNTRUSTED_REPO") == "1"` (module level, beside the other env reads).
- In plan loading: when `UNTRUSTED` and the plan has `"here": true`, `die("DELEGATE_UNTRUSTED_REPO=1: an in-place plan runs git in the checkout on the host; use an isolated plan (a \"base\", no \"here\")", 2)` before anything runs or any state is written.
- The closing isolated-mode diffstat (`git -C repo diff --stat=120 base_sha delegate/<last>`) runs as `sh([DELEGATE, "_repo-git", plan["repo"], "--", "diff", "--stat=120", base_sha, f"delegate/{last}"])` when `UNTRUSTED`; otherwise the existing call, unchanged. `DELEGATE` is chain.py's existing path to the delegate binary (honours `DELEGATE_CHAIN_BIN`).
- No other git call in chain.py is reachable in untrusted mode (the in-place ones are behind the refusal). State that in a short comment.
- Tests appended to `tests/test_chain.sh` (keep every existing check unchanged):
  1. `DELEGATE_UNTRUSTED_REPO=1` + a `"here": true` plan: exit 2, the message names DELEGATE_UNTRUSTED_REPO, no step was started (the fake records nothing), no chain state file;
  2. `DELEGATE_UNTRUSTED_REPO=1` + an isolated plan that completes: the fake delegate is called with `_repo-git <repo> -- diff --stat=120 ...` (make the fake log that call's argv), and chain prints the fake's output under "whole slice";
  3. without the variable the same isolated plan makes no `_repo-git` call.

## Acceptance criteria
- The full gate passes: `bash -n bin/delegate && python3 -m py_compile lib/*.py && for t in tests/test_*.sh; do bash "$t" || exit 1; done`.

## Out of scope
bin/delegate, other lib files. Another branch edits chain.py too, so keep the diff small and local.
