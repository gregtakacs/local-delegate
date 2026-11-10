# evals

Five fixed tasks, scored by checks the worker never sees, so that a change to the worker
rules (or the model, or the server) can be measured rather than argued about.

| case | exercises |
|---|---|
| `py-semver` | a spec with exact grammar rules: parsing strictness, ordering, dataclass contract |
| `node-handles-pg` | a real database (`--service postgres`), idempotent migrations, a concurrency race |
| `ui-tip` | a UI: integer-cents money logic, DOM contract, the screenshot self-verification loop |
| `bugfix-duration` | five bug reports in existing code: focused fixes, regression tests, no collateral changes |
| `long-refactor` | an API migration across 60 generated modules (~30K tokens of code, three import styles, computed levels), compared call by call against the original: the long-context / many-tool-calls stress case |

```bash
evals/run.sh                                    # all cases, current rules
evals/run.sh --label before-6b --rules-ref HEAD~1 --cases long-refactor --repeat 3
evals/run.sh --label after-6b                   --cases long-refactor --repeat 3
```

Results land in `evals/results/<stamp>-<label>.md` (a table) and `.jsonl` (one row per run).
**One run per case is an anecdote.** The model is sampled, so compare medians over `--repeat 3`
or more before believing a rule change helped. Watch `hidden`, `tools (failed)`, `nudges` and
`final ctx` as well as the pass rate.
