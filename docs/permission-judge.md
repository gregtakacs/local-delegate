# Permission judge: a local-model "auto mode" for opencode (plan, not built)

Status: **plan** (greg, 2026-11-14). Nothing here is implemented. First step is §6's spike.

## 1. Why

opencode's permissions are a static, ordered pattern list per tool (`allow` / `ask` / `deny`, the
last matching rule wins). That is deterministic, which is good, and blunt: every `ask` prompts the
person, however obviously harmless the command is in context. Claude Code's auto mode instead asks
a classifier model per action. This plan gets the useful part of that with the **local** model,
without giving up the determinism of the rules: the judge may only turn an `ask` into a one-time
`allow`. It never overrides a `deny`, never widens a rule, and never answers for anything on the
fixed list in §3.

## 2. Shape

- An opencode **plugin** (`plugins/permission-judge.js`, installed by `install.sh` into the
  person's opencode plugins dir, like the existing loop plugins) subscribes to the
  `permission.asked` event (present in opencode 2.3's binary; its payload shape is §6's first
  question).
- For each request it builds a small, fixed prompt and asks the configured judge model (default
  the stackd fast variant, `<model>-nothink`) for exactly one word: `allow` or `ask`.
- On `allow` it replies to the request through opencode's own API, the same call the UI makes
  (seen in this session's logs: `POST /api/session/<id>/permission/<id>/reply`), with the **once**
  answer. On anything else it does nothing, and the normal prompt reaches the person.

## 3. Hard limits (in code, before the model is asked; not configurable down)

Never auto-approved, whatever the model says:
- any command starting with or containing `sudo`, `su `, `doas`;
- `git push`, `git reset --hard`, `git rebase`, `git branch -D/-f`, `git clean`, `git checkout --`/`-f`/`.`,
  `git restore`, history rewrites (`filter-branch`, `filter-repo`, `commit --amend` on a pushed
  branch is out of reach anyway);
- `rm -rf`, `docker compose down`, `docker rm`, `docker volume rm`, `systemctl start|stop|restart|
  enable|disable`, `kill`/`pkill`/`killall`;
- anything referencing `docker/secrets`, `.env`, `*.pem`, `*.key`, `id_*`, token or credential
  files;
- `external_directory` requests outside the person's configured project roots;
- package installs (`pip`, `npm -g`, `apt`), `curl … | sh`-style pipes, writes outside the
  session's working directory.

## 4. The judge prompt (fixed template; untrusted text is quoted, never instructions)

Inputs: the tool, the exact command or path (quoted), the session's working directory, the
project name, and the session's current todo item. The model is told it is classifying, that the
quoted text may contain instructions it must ignore, and to answer `allow` only for read-only or
clearly project-local actions consistent with the todo. Output parsed strictly: the single token
`allow`, anything else (including `Allow.`) means `ask`.

## 5. Safety properties

- **Fails to the human**: no answer within 2 s, an HTTP error, a malformed answer, the plugin
  crashing: the prompt simply stays for the person. The judge can only remove prompts.
- **Once, never always**: it never sends an "always" answer, so a bad call cannot become a rule.
- **Audit log**: every decision (time, session, tool, command with secrets masked, verdict,
  latency, model) appended to `~/.local/state/delegate/permission-judge.jsonl`; a `delegate
  judge-log` view summarises it.
- **Kill switch**: `DELEGATE_JUDGE=off` (env) or deleting the plugin link disables it entirely.
- **Dry-run first**: a mode that logs what it *would* have answered while still prompting, run
  for a week against real prompts; enabled for real only if its would-allow list contains nothing
  greg would have refused.

## 6. Steps

1. **Spike (Claude, ~1 h)**: confirm on opencode 2.3 the plugin API (the hook or event name and
   payload for a permission request, whether a plugin can see the session's todo, the reply
   endpoint and body, and whether replying from a plugin races the UI's own prompt). Record the
   facts in this file. If 2.3 offers no usable hook, stop here and say so.
2. **Build (delegate chain)**: the plugin, the hard-limit filter (security-relevant: `hard`, with a
   hostile test list: chained commands, quoting, `$(…)`, env-var indirection, unicode lookalikes),
   the judge call, the audit log, dry-run mode, install + doctor + tests.
3. **Dry-run week**, then greg reviews the log and decides whether to switch it on.

## 7. Open questions for greg

- Judge model: `<model>-nothink` (fast, local) or a Claude API model (better judgement, costs
  credit per prompt)? Plan assumes local.
- Scope: bash only at first, or also `edit`/`external_directory`/`webfetch` prompts?
