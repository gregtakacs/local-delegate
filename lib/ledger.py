#!/usr/bin/env python3
"""The telemetry ledger: its whole file protocol, plus the one events.jsonl -> timeline derivation.

One append-only JSONL file, outside every repository and outside the task dirs (R2), written
host-side only — the worker never sees it. Everything `delegate` does with the ledger goes
through these names:

  KINDS                    the row kinds this build knows, with the highest schema of each
  resolve_ledger           CLI override > $DELEGATE_LEDGER > <state>/ledger/events.jsonl
  append                   one flock'd, fsync'd line; ValueError on a row this build must not store
  read_rows                (lineno, raw, row-or-None) for every line; None means skip it
  derive_timeline          a round's events.jsonl -> {steps, tools, totals}, no text and no payloads (R4)
  ROUND_KEYS               the round-row schema's field list, in write order
  build_round_row          report.json + collected values -> the round row, in that order
  build_timeline_row       a derivation + identity -> the timeline row
  append_round_and_timeline  the live round-end entry point: both rows, one events parse
  REVIEW_KEYS              the review-row schema's field list, in write order
  build_review_row         the orchestrator's flags -> the review row, in that order
  latest_round             a task's highest round row already in the ledger (R5's --round default)
  import_state             $DELEGATE_STATE -> round+timeline rows for every stored round (R8)
  read_stats_rows          the `round` + `review` rows alone, timeline lines dropped unparse
  stats                    R6's per-project totals over those rows, as one JSON-ready dict

Importable and silent: no printing, no sys.exit, no git, stdlib only. A row this build cannot
store is skipped by the reader, never an error: the ledger outlives every build that appended to
it, and slice B writes kinds here that today's code must tolerate. See docs/specs/t-design.md.
"""
from __future__ import annotations

import datetime
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
from typing import Any, Iterator, Mapping

# The kinds this build knows, and the highest schema version of each. `round`, `timeline` and
# `review` are slice T's; `benchmark` and `verdict` are registered for slice B so a reader of
# this build already skips their rows cleanly instead of meeting an unknown kind for the first
# time. A kind is valid iff listed here; a row's schema iff 1 <= schema <= KINDS[kind].
# round:2 adds `orchestrator`/`orchestrator_session` (the delegating session); a v1 round
# row reads the same with both null.
# timeline:2 adds `ctx` to every step and the `events` list — the reliability positions
# (nudges, tool errors, verify-fails, each with step and context size); a v1 timeline row
# reads the same with steps' ctx null and no events.
KINDS: dict[str, int] = {"round": 2, "timeline": 2, "review": 1, "benchmark": 1, "verdict": 1}

LEDGER_FILENAME = "events.jsonl"          # the ledger's own file, beside — never inside — task dirs


# ------------------------------------------------------------------ the path ----------
def _home(env: Mapping[str, str]) -> str:
    return env.get("HOME") or os.path.expanduser("~")


def _expanduser(value: str, env: Mapping[str, str]) -> str:
    """`~` and `~/x` -> HOME, the same rule bin/delegate's expand() applies."""
    if value == "~":
        return _home(env)
    if value.startswith("~/"):
        return _home(env) + value[1:]
    return value


def resolve_ledger(overrides: dict[str, str], env: Mapping[str, str]) -> str:
    """The ledger file to use: a CLI/config override, then $DELEGATE_LEDGER, then the default
    `<state>/ledger/events.jsonl`. `<state>` is the DELEGATE_STATE from `overrides` then `env`,
    else `$XDG_STATE_HOME/delegate` (default `~/.local/state/delegate`) — lib/chain.py's default
    state dir, so the ledger sits beside the task records and no task-dir prune can reach it.

    A pure function of its arguments, and it creates nothing: pointing at a ledger that is not
    there yet is not a write.
    """
    ov = overrides or {}
    for value in (ov.get("LEDGER"), env.get("DELEGATE_LEDGER")):
        if value:
            return _expanduser(value, env)
    state = ov.get("DELEGATE_STATE") or env.get("DELEGATE_STATE")
    if not state:
        xdg = env.get("XDG_STATE_HOME") or os.path.join(_home(env), ".local", "state")
        state = os.path.join(xdg, "delegate")
    return os.path.join(_expanduser(state, env), "ledger", LEDGER_FILENAME)


# ------------------------------------------------------------------- one row ----------
def _check(row: Mapping[str, Any]) -> int:
    """Validate a row's `kind`/`schema` and return the schema. The two raise sites below are the
    whole of what `append` refuses."""
    kind = row.get("kind")
    if not isinstance(kind, str) or kind not in KINDS:
        raise ValueError(f"unknown ledger row kind {kind!r}")
    schema = row.get("schema")
    if isinstance(schema, bool) or not isinstance(schema, int):
        raise ValueError(f"ledger row schema must be an int, not {schema!r} (kind {kind})")
    if not 1 <= schema <= KINDS[kind]:
        raise ValueError(f"ledger row schema {schema} out of range for kind {kind!r} "
                         f"(this build knows 1..{KINDS[kind]})")
    return schema


def _line(row: Mapping[str, Any]) -> str:
    """The row as one compact JSON line: `kind` and `schema` first, so a reader can filter on
    them before parsing the rest; the remaining keys keep the writer's order."""
    _check(row)                                            # refuse before writing anything
    out: dict[str, Any] = {"kind": row["kind"], "schema": row["schema"]}
    out.update({k: v for k, v in row.items() if k not in ("kind", "schema")})
    return json.dumps(out, ensure_ascii=True, separators=(",", ":"))


def _lock(path: str) -> int:
    """The lock fd, exclusively held. Blocking in `flock` is where a signal can land, and a lost
    EINTR there would be a lost row, so acquisition retries until it owns the lock."""
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            return fd
        except InterruptedError:
            continue


def _needs_newline(path: str) -> bool:
    """True when the file's last byte is not a newline: a writer killed mid-`write` leaves a
    partial line, and gluing the next row onto it would lose the next row. Checked under the
    lock, so the answer cannot go stale before it is acted on."""
    try:
        with open(path, "rb") as f:
            if os.fstat(f.fileno()).st_size == 0:
                return False
            f.seek(-1, os.SEEK_END)
            return f.read(1) != b"\n"
    except FileNotFoundError:
        return False


def append(ledger_path: str, row: Mapping) -> None:
    """Append one row as exactly one `\\n`-terminated line. `ValueError` unless `kind` is a known
    kind and `schema` a valid version of it; parent directories are created.

    Writers are serialized by an exclusive `flock` on a `<ledger_path>.lock` sidecar, and the
    data file is flushed and fsync'd before the lock is released — so a reader (which takes no
    lock) never sees half a line, and an acknowledged row is on the file. A trailing partial
    line left by a killed writer is closed off first, so it costs its own row and no other.
    """
    if not isinstance(row, Mapping):
        raise ValueError(f"ledger row must be a mapping, not {type(row).__name__}")
    line = _line(row)
    path = Path(ledger_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = _lock(str(path) + ".lock")
    try:
        closing = "\n" if _needs_newline(str(path)) else ""
        with open(path, "a", encoding="utf-8") as f:
            f.write(closing + line + "\n")
            f.flush()
            os.fsync(f.fileno())
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


# ------------------------------------------------------------------- reading ----------
def _accepted(line: str) -> dict | None:
    """The row this line holds, or None: not JSON, not an object, an unknown kind, or a schema
    this build does not know. Whether a skipped line was malformed or merely unknown stays
    readable from the raw text the caller got, so nothing is lost by not saying which here."""
    try:
        e = json.loads(line)
    except ValueError:
        return None
    if not isinstance(e, dict):
        return None
    kind = e.get("kind")
    if not isinstance(kind, str) or kind not in KINDS:
        return None
    schema = e.get("schema")
    if isinstance(schema, bool) or not isinstance(schema, int):
        return None
    if not 1 <= schema <= KINDS[kind]:
        return None
    return e


def read_rows(ledger_path: str) -> Iterator[tuple[int, str, dict | None]]:
    """`(lineno, raw_text, row_or_None)` for every line, oldest first. A missing or unreadable
    file yields nothing, and so does an empty one. `raw_text` has the line's newline stripped; a
    trailing partial line (a writer killed mid-write) is a line like any other, and parses to
    None. No locking: one line is one buffered write, so anything that reads as a whole line is
    complete."""
    try:
        f = open(ledger_path, encoding="utf-8", errors="replace")
    except OSError:
        return
    with f:
        for lineno, raw in enumerate(f, 1):
            if raw.endswith("\n"):
                raw = raw[:-1]
            if raw.endswith("\r"):
                raw = raw[:-1]
            yield (lineno, raw, _accepted(raw))


# ----------------------------------------------------------------- the timeline -------
def _ms(value: Any) -> int | None:
    """An event timestamp, in the events' own milliseconds — the join key with the inference
    server's request logs (R4/R7), so it is carried through unchanged, never reformatted."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return int(value)


def _count(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    return int(value)


def _dict(value: Any) -> dict:
    return value if isinstance(value, dict) else {}


def _events(events_path: str) -> Iterator[dict]:
    """Every JSON-object line of an events file. Unparsable lines are skipped; a missing file is
    simply no events."""
    try:
        f = open(events_path, encoding="utf-8", errors="replace")
    except OSError:
        return
    with f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                e = json.loads(raw)
            except ValueError:
                continue
            if isinstance(e, dict):
                yield e


def _new_step(start: int | None) -> dict:
    return {"start": start, "end": start, "input": 0, "output": 0, "reasoning": 0,
            "cache_read": 0, "cache_write": 0, "ctx": None, "reason": None}


def derive_timeline(events_path: str) -> dict:
    """The R4 derivation, in one code path that both a live round and an import walk (R8): a
    round's `events.jsonl` -> the `steps`/`tools`/`totals` a timeline row holds.

    A step opens at its `step_start` timestamp and closes at the matching `step_finish`, taking
    that event's `part.tokens` and `part.reason`; a `step_finish` whose `step_start` never made
    the log still counts, at its own instant. A step no `step_finish` ever closed (a round killed
    mid-step) closes at the last event's timestamp with `reason` null and its partial tokens —
    the same rule live and on import, so no row differs by provenance. `totals` sums the
    `step_finish` token counts, which is the same as summing the steps: tokens only arrive with a
    finish, so an unclosed step contributes zero to both.

    Nothing else about an event is read — not `part.state.input`, not `part.state.output`, not
    `title`, not `metadata`, and no `text` events at all (R4). Tool calls repeat in the stream
    while they run (pending, then completed, same `part.id`), so one call is one entry, updated
    in place at its first-appearance position: R4 records name, success and times per call, not
    per event line.
    """
    steps: list[dict] = []
    tools: list[dict] = []
    events: list[dict] = []
    open_errors: dict[str, dict] = {}         # call id -> its still-open error record (never
                                              # a list position: those shift when one drops)
    totals = {"input": 0, "output": 0, "reasoning": 0, "cache_read": 0, "cache_write": 0}
    open_step: dict | None = None
    seen_tools: dict[str, int] = {}
    last_ts: int | None = None

    for e in _events(events_path):
        ts = _ms(e.get("timestamp"))
        if ts is not None:
            last_ts = ts
        etype = e.get("type")
        part = _dict(e.get("part"))

        if etype == "step_start":
            if open_step is not None:                      # two starts, no finish: the first is over
                open_step["end"] = ts if ts is not None else last_ts
                steps.append(open_step)
            open_step = _new_step(ts)
        elif etype == "step_finish":
            tokens = _dict(part.get("tokens"))
            cache = _dict(tokens.get("cache"))
            counted = {"input": _count(tokens.get("input")), "output": _count(tokens.get("output")),
                       "reasoning": _count(tokens.get("reasoning")),
                       "cache_read": _count(cache.get("read")), "cache_write": _count(cache.get("write"))}
            step = open_step
            if step is not None:
                open_step = None
            else:                                        # a finish whose start was lost still
                step = _new_step(ts)                     # counts, at its own instant
            steps.append(step)
            step["end"] = ts if ts is not None else step["start"]
            step.update(counted)
            step["ctx"] = (counted["input"] + counted["cache_read"]
                           + counted["cache_write"])
            step["reason"] = part.get("reason")
            for k, v in counted.items():
                totals[k] += v
            for ev in events:                              # errors inside the step that just closed
                if ev.get("open") and ev["step"] == len(steps):
                    ev["ctx"] = step["ctx"]
                    ev["open"] = False
        elif etype == "tool_use":
            state = _dict(part.get("state"))
            time_ = _dict(state.get("time"))
            entry = {"tool": part.get("tool"), "status": state.get("status"),
                     "start": _ms(time_.get("start")), "end": _ms(time_.get("end"))}
            call_id = part.get("id")
            if isinstance(call_id, str) and call_id in seen_tools:
                tools[seen_tools[call_id]] = entry          # the same call, further along
            else:
                if isinstance(call_id, str) and call_id:
                    seen_tools[call_id] = len(tools)
                tools.append(entry)
            if entry["status"] == "error":
                # R4 read-only-by-exception: the error TEXT never leaves this walk — its first
                # characters only decide which of the two tool-error kinds the record gets.
                err = state.get("error")
                err = err if isinstance(err, str) else ("" if err is None else str(err))
                kind = ("tool-error:invalid-args" if err.startswith(INVALID_ARGS_PREFIX)
                        else "tool-error")
                # Open errors are tracked by call id, never by list position: positions shift
                # when an entry is dropped. A repeat of an open error updates that record in
                # place; a dropped one simply appends a fresh record.
                if isinstance(call_id, str) and call_id in open_errors:
                    ev = open_errors[call_id]
                    ev.update(kind=kind, step=len(steps) + 1, ctx=None, open=True)
                else:
                    ev = {"kind": kind, "step": len(steps) + 1, "ctx": None, "open": True}
                    if isinstance(call_id, str) and call_id:
                        open_errors[call_id] = ev
                    events.append(ev)
            elif isinstance(call_id, str) and call_id in open_errors:
                ev = open_errors.pop(call_id)               # a retried call that then worked
                if ev["open"]:
                    ev["dropped"] = True                    # filtered out at the end

    if open_step is not None:                              # killed mid-step: the last event closes it
        open_step["end"] = last_ts
        steps.append(open_step)
    events = [ev for ev in events if not ev.pop("dropped", False)]
    for ev in events:                                      # an error in a step that never closed
        ev.pop("open", None)                               # keeps its null ctx
    return {"steps": steps, "tools": tools, "totals": totals, "events": events}


# ----------------------------------------------------------------------- rows -------
# The round-row schema, in the order the design says it is written (§Row schemas,
# docs/specs/t-design.md). A row whose value was not collectable is null, never
# absent: `delegate ledger append --round-from-report` always writes this key set
# in this order, so a reader can positionally trust a round row, and T3's import
# (which lacks live conditions) writes nulls rather than guessing.
ROUND_KEYS = (
    "task_id", "slug", "repo", "project", "chain", "step", "run_id", "round", "spec_hash",
    "base_ref", "base_sha", "verify", "endpoint", "model", "effort",
    "effort_source", "delegate_version", "rules_hash", "image_stamp", "runner",
    "orchestrator", "orchestrator_session", "timeout_s", "edit_cap", "parallel_rounds",
    "status", "worker_status",
    "exit", "verify_rc", "nudges", "tool_calls", "tool_errors", "errors",
    "todos_done", "todos_total", "retries", "round_start", "round_end",
    "duration_s", "steps", "input_tokens", "output_tokens", "reasoning_tokens",
    "cache_read", "cache_write", "final_context_tokens", "diff_lines",
    "source", "ts",
)


def _num(value: Any) -> int | float | None:
    """A number, or None: bools never count as numbers here, and strings that
    are numbers (from CLI flags) become numbers."""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return value
    if isinstance(value, str):
        text = value.strip()
        if re.fullmatch(r"[+-]?\d+", text):
            return int(text)
        if re.fullmatch(r"[+-]?\d+(\.\d*)?([eE][+-]?\d+)?", text):
            return float(text)
    return None


def parse_diffstat(text: str) -> int | None:
    """`git diff --stat` output -> its one diff_lines figure: added+deleted.
    The summary line ("N files changed, A insertions(+), D deletions(-)") is
    the authority when present; without it the per-file "| A +--" columns are
    split by their +/- mark counts. None when the text is no diffstat at all
    (an empty file: a round with no diff is diff_lines 0, a missing file is
    nothing known)."""
    if not text.strip():
        return None
    changed = re.search(r"(\d[\d,]*) files? changed", text)
    ins = re.search(r"(\d[\d,]*) insertions?\(\+\)", text)
    dele = re.search(r"(\d[\d,]*) deletions?\(-\)", text)
    if changed and (ins or dele):                          # the summary line is git's own total
        return (int(ins.group(1).replace(",", "")) if ins else 0) + \
               (int(dele.group(1).replace(",", "")) if dele else 0)
    if not re.search(r"\|", text):                         # neither summary nor per-file rows
        return None
    total = 0
    for line in text.splitlines():                         # per-file rows: lines touched
        m = re.match(r".*?\|\s*(\d+)([ +-]*)", line)
        if m:
            total += int(m.group(1))
    return total


def _count_of(value: Any) -> int | None:
    """A count: a list's length (report.json keeps `errors` and `tool_errors` as
    message lists; the row keeps only their size — the messages themselves are
    exactly the free text R4 keeps out of the ledger), else a number, else None."""
    if isinstance(value, list):
        return len(value)
    return _num(value)


# The reliability records a timeline row's `events` list holds (schema 2): who interrupted
# the model or failed, and where in the round it happened — kind, step, context size. The
# error TEXT behind a tool-error never reaches a row: its first characters only decide
# which of the two tool-error kinds the record gets (R4's one read-by-exception, and still
# store-nothing).
INVALID_ARGS_PREFIX = "The arguments provided to the tool are invalid"
NUDGE_LINE = re.compile(r"^nudge: ([A-Za-z0-9._-]+)(?: step=(\d+) ctx=(\d+))?$")

# The context-size buckets stats reports reliability by: token counts at powers of two,
# each bucket holding ctx < its bound; "unknown" takes ctx that never was.
CTX_BUCKETS = (("0-32k", 32_768), ("32-64k", 65_536), ("64-128k", 131_072),
               ("128-256k", 262_144), ("256-512k", 524_288), ("512k+", None))


def ctx_bucket(n: Any) -> str:
    """The bucket a context size falls in. Anything that is not a non-negative integer —
    an unclosed step, a v1 row's step, a record with no position — is "unknown"."""
    if isinstance(n, bool) or not isinstance(n, int) or n < 0:
        return "unknown"
    for label, hi in CTX_BUCKETS:
        if hi is None or n < hi:
            return label
    return "512k+"


def parse_nudge_lines(text: str) -> list:
    """`nudge: <kind>[ step=<N> ctx=<T>]` lines from a round's stderr, in file order, as
    [("nudge:<kind>", N|None, T|None)]. A line without the position pair is the old format,
    written before positions existed: still a nudge of that kind, with no position of its own
    (null step and ctx — never an invented one). A `nudge:` line this grammar does not know
    is not a nudge."""
    out = []
    for line in (text or "").splitlines():
        m = NUDGE_LINE.match(line.strip())
        if m:
            out.append(("nudge:" + m.group(1),
                        int(m.group(2)) if m.group(2) is not None else None,
                        int(m.group(3)) if m.group(3) is not None else None))
    return out


def _final_position(derived: Mapping[str, Any] | None, fallback=None) -> tuple:
    """(steps so far, ctx of the last closed step) from a derivation — the position a
    verify-fail record takes, being a property of the finished round rather than of one
    logged instant. With no closed step anywhere the caller's `fallback` pair (read off the
    round row: `steps`, `final_context_tokens`) is used; with neither, (0, 0)."""
    ctxs = [s.get("ctx") for s in (derived or {}).get("steps") or [] if s.get("ctx") is not None]
    if ctxs:
        return len(ctxs), ctxs[-1]
    if isinstance(fallback, (tuple, list)) and len(fallback) == 2:
        return (fallback[0] or 0, fallback[1] or 0)
    return (0, 0)


def timeline_events(derived: Mapping[str, Any] | None, stderr_text: str = "",
                    verify_rc=None, fallback=None) -> list:
    """R8, again: the ONE derivation of a timeline row's `events`, shared by the live round
    and the import. Tool errors come from the walk (already in `derived`); nudges come from
    the round's stderr — an old-format line with no position of its own records null step and
    ctx and joins the "unknown" bucket, because a position nobody recorded is never invented.
    A verify-fail record is appended when the round's verify exit code is non-zero
    (`verify_rc not in (None, 0)` — the exit code, not a status string), at the round's final
    position. Sorted by step, stable, nulls first (a missing step sorts like the walk's -1),
    so a row's events read in round order. Only kind, step and ctx are produced: no message,
    no tool text (R4)."""
    events = [dict(ev) for ev in ((derived or {}).get("events") or [])]
    for kind, n, t in parse_nudge_lines(stderr_text):
        events.append({"kind": kind, "step": n, "ctx": t})
    if isinstance(verify_rc, int) and not isinstance(verify_rc, bool) and verify_rc != 0:
        final = _final_position(derived, fallback)
        events.append({"kind": "verify-fail", "step": final[0], "ctx": final[1]})
    events.sort(key=lambda ev: ev["step"] if isinstance(ev["step"], int) else -1)
    return events


def build_timeline_row(derived: Mapping[str, Any], identity: Mapping[str, Any],
                       source: str = "", ts: str | None = None) -> dict:
    """A round's timeline row: the derive_timeline result (steps, tools — never
    its totals, which belong to the round row's cost fields) plus the identity
    fields, in the design's order. `identity` supplies at least task_id, run_id
    and round; absent join keys are null, the key order is fixed."""
    derived = derived if isinstance(derived, Mapping) else {}
    identity = identity if isinstance(identity, Mapping) else {}
    if ts is None:
        ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"task_id": identity.get("task_id"), "run_id": identity.get("run_id"),
            "round": identity.get("round"), "steps": derived.get("steps") or [],
            "tools": derived.get("tools") or [], "events": derived.get("events") or [],
            "source": source, "ts": ts}


def append_round_and_timeline(ledger_path: str, report_path: str, events_path: str,
                              extra: Mapping[str, Any] | None = None) -> int:
    """The live round-end entry point (`delegate ledger append --round-from-report`):
    read the round's report.json, derive its timeline from events.jsonl ONCE (the
    totals feed the round row, the steps/tools the timeline row), and append the
    round row immediately followed by the timeline row. `extra` carries everything
    the two files don't: meta.env identity, endpoint, hashes, caps, timings,
    diff_lines. Returns the number of rows appended; raises ValueError/OSError for
    anything the caller turns into its one warning line — an unreadable
    report.json writes no rows, an unreadable events file writes the round row
    alone with null token sums (a pruned or killed-early round still counts)."""
    extra = dict(extra or {})
    try:
        with open(report_path, encoding="utf-8") as f:
            report = json.load(f)
    except OSError as exc:
        raise ValueError(f"cannot read report {report_path}: {exc.strerror or exc}") from exc
    except ValueError as exc:
        raise ValueError(f"report {report_path} is not JSON: {exc}") from exc
    if not isinstance(report, dict):
        raise ValueError(f"report {report_path} holds a JSON {type(report).__name__}, not an object")
    derived = derive_timeline(events_path) if events_path and os.path.exists(events_path) else None
    if derived is not None:
        extra["totals"] = derived["totals"]
        # R8, once more: the row's `events` come from one merge — the walk's tool errors, the
        # round's stderr nudge lines, and a verify-fail decided by this round's verify exit
        # code off report.json. Import arrives here by the same door as a live round.
        stderr_path = os.path.join(os.path.dirname(report_path), "stderr.log")
        try:
            with open(stderr_path, encoding="utf-8", errors="replace") as f:
                stderr_text = f.read()
        except OSError:
            stderr_text = ""
        derived["events"] = timeline_events(
            derived, stderr_text, report.get("verify_rc"),
            fallback=(report.get("steps"), report.get("final_context_tokens")))
    row = build_round_row(report, extra)
    append(ledger_path, {"kind": "round", "schema": KINDS["round"], **row})
    if derived is None:
        return 1
    identity = {k: row[k] for k in ("task_id", "run_id", "round")}
    tl = build_timeline_row(derived, identity, source=extra.get("source", ""), ts=row["ts"])
    append(ledger_path, {"kind": "timeline", "schema": KINDS["timeline"], **tl})
    return 2


def _iso(epoch: Any) -> str | None:
    """An epoch-seconds figure as an ISO-8601 UTC string (round_start/round_end
    are stored like `ts`: comparable strings), None when there is no number."""
    n = _num(epoch)
    if n is None:
        return None
    return datetime.datetime.fromtimestamp(n, datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ")


def project_of(git_common: Any, repo: Any) -> str | None:
    """The project a round belongs to: the main checkout, not the worktree it ran in. A chain run
    from a linked worktree records that worktree as `repo`; its git common dir (`<main>/.git`)
    names the project. A bare common dir is its own name; no common dir falls back to `repo`."""
    gc = git_common if isinstance(git_common, str) else ""
    if gc:
        gc = gc.rstrip("/")
        return gc[:-5] if gc.endswith("/.git") else gc
    return repo if isinstance(repo, str) and repo else None


def build_round_row(report: Mapping[str, Any], extra: Mapping[str, Any] | None = None) -> dict:
    """The round row, in ROUND_KEYS order, from a round's `report.json` contents
    plus whatever else the caller collected (`extra`, keyed by row field):
    identity and conditions from meta.env and the live environment, endpoint,
    hashes, caps, timings, diff_lines, and the timeline derivation's `totals`
    when one ran (token sums and duration/steps then come from it, as the design
    demands — one parse serves both rows). A field neither source carries lands
    null; the key order never varies. `source`: empty for live rows — an import
    passes its own value."""
    report = report if isinstance(report, Mapping) else {}
    extra = extra if isinstance(extra, Mapping) else {}
    totals = extra.get("totals") if isinstance(extra.get("totals"), Mapping) else None

    def pick(key: str, from_report: str = ""):
        """extra first, then report.json, else null."""
        if key in extra and extra[key] is not None:
            return extra[key]
        return report.get(from_report or key)

    nudges = report.get("nudges")
    todos = report.get("todos") or []
    done = sum(1 for t in todos if isinstance(t, Mapping) and t.get("status") == "completed")
    rnd = _num(report.get("round"))
    row: dict[str, Any] = {
        "task_id": pick("task_id"), "slug": pick("slug"), "repo": pick("repo"),
        "project": pick("project") or project_of("", pick("repo")),
        "chain": pick("chain") or None,
        "step": pick("step"), "run_id": pick("run_id") or pick("task_id"),
        "round": rnd, "spec_hash": pick("spec_hash"),
        "base_ref": pick("base_ref"), "base_sha": pick("base_sha"),
        "verify": pick("verify") or None,
        "endpoint": pick("endpoint"), "model": pick("model"),
        "effort": pick("effort") or "normal", "effort_source": pick("effort_source"),
        "delegate_version": pick("delegate_version"),
        "rules_hash": pick("rules_hash"),
        # the design stores image_stamp empty (not null) on the native runner and when the
        # docker image carries no label — image_stamp() itself prints "" in both cases.
        "image_stamp": pick("image_stamp") or "",
        "runner": pick("runner"),
        # the session that delegated the task (meta.env ORCH/ORCH_SESSION), null when
        # it was started from a plain shell or before round:2
        "orchestrator": pick("orchestrator") or None,
        "orchestrator_session": pick("orchestrator_session") or None,
        "timeout_s": _num(extra.get("timeout_s")), "edit_cap": _num(extra.get("edit_cap")),
        "parallel_rounds": _num(extra.get("parallel_rounds")),
        "status": pick("status"), "worker_status": pick("worker_status"),
        "exit": _num(pick("exit")), "verify_rc": _num(report.get("verify_rc")),
        "nudges": nudges if isinstance(nudges, dict) else None,
        "tool_calls": _num(pick("tool_calls")),
        "tool_errors": _count_of(pick("tool_errors")),
        "errors": _count_of(pick("errors")),
        "todos_done": done, "todos_total": len(todos),
        "retries": (rnd - 1) if rnd is not None and rnd >= 1 else 0,
        "round_start": _iso(pick("round_start")), "round_end": _iso(pick("round_end")),
        "duration_s": _num(report.get("duration_s")),
        "steps": _num(report.get("steps")),
        "input_tokens": _num(totals.get("input")) if totals else None,
        "output_tokens": _num(totals.get("output")) if totals else _num(report.get("output_tokens")),
        "reasoning_tokens": _num(totals.get("reasoning")) if totals else _num(report.get("reasoning_tokens")),
        "cache_read": _num(totals.get("cache_read")) if totals else None,
        "cache_write": _num(totals.get("cache_write")) if totals else None,
        "final_context_tokens": _num(report.get("final_context_tokens")),
        "diff_lines": _num(extra.get("diff_lines")),
        "source": extra.get("source", ""),
        "ts": extra.get("ts"),
    }
    if row["ts"] is None:
        row["ts"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {k: row[k] for k in ROUND_KEYS}


# ------------------------------------------------------------------- review row -------
# R5: the orchestrator's verdict on a landed step, given as flags — never parsed out of a
# review document. Field order from the design (§Review row); a review row carries no diff
# content, no file lists, and no prose beyond the note the caller typed.
REVIEW_KEYS = ("task_id", "round", "verdict", "bugs_high", "bugs_medium", "bugs_low",
               "lines_changed", "note", "ts")

VERDICTS = ("accepted", "fixed", "rejected")

BUG_FIELDS = {"high": "bugs_high", "medium": "bugs_medium", "low": "bugs_low"}


def parse_bugs(text: Any) -> dict:
    """`high=2,medium=1` -> the three bug counts, a severity not named 0. Raises ValueError on
    an entry that is not `severity=whole-number`: a miscounted finding must not be filed as a
    silent zero. A Mapping keyed by the same severities (either `high` or `bugs_high`) comes
    through this one door, so a caller holding parsed counts is validated like a flag string."""
    counts = {"bugs_high": 0, "bugs_medium": 0, "bugs_low": 0}
    if isinstance(text, Mapping):
        items = list(text.items())
    else:
        items = []
        for token in str(text or "").split(","):
            token = token.strip()
            if not token:
                continue
            key, sep, value = token.partition("=")
            items.append((key, value if sep else None))
    for key, value in items:
        name = str(key).strip().lower()
        if name.startswith("bugs_"):
            name = name[5:]
        field = BUG_FIELDS.get(name)
        n = _num(value)
        if field is None or n is None:
            raise ValueError(f"bad bugs entry {str(key).strip()}"
                             f"{'=' + str(value) if value is not None else ''}"
                             f" (want high=N,medium=N,low=N with whole numbers)")
        counts[field] = int(n)
    return counts


def build_review_row(values: Mapping[str, Any]) -> dict:
    """The review row, in REVIEW_KEYS order, from what the command was handed: `task_id`;
    `round` (None stays None — a task with no round row has nothing to link to); `verdict`,
    one of VERDICTS or ValueError, because this row IS the orchestrator's judgement and a
    missing or unknown one is a caller error rather than a field to leave null; `bugs` as one
    `--bugs` string (see parse_bugs); `lines_changed`; `note`, empty unless typed; `ts` now."""
    values = values if isinstance(values, Mapping) else {}
    row: dict[str, Any] = {
        "task_id": values.get("task_id"),
        "round": _num(values.get("round")),
        "verdict": values.get("verdict"),
    }
    row.update(parse_bugs(values.get("bugs", "")))
    row["lines_changed"] = _num(values.get("lines_changed"))
    row["note"] = values.get("note") or ""
    row["ts"] = values.get("ts")
    if row["verdict"] not in VERDICTS:
        raise ValueError(f"review verdict must be one of {', '.join(VERDICTS)}, "
                         f"not {row['verdict']!r}")
    if row["ts"] is None:
        row["ts"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {k: row[k] for k in REVIEW_KEYS}


def latest_round(ledger_path: str, task_id: str) -> int | None:
    """The highest round this ledger holds for one task — R5's `--round` default — or None
    when it holds no round row for it."""
    top: int | None = None
    for _lineno, _raw, row in read_rows(ledger_path):
        if row is None or row["kind"] != "round" or row.get("task_id") != task_id:
            continue
        n = _num(row.get("round"))
        if n is not None and (top is None or n > top):
            top = int(n)
    return top


# ---------------------------------------------------------------------- import --------
# R8: the task records that still exist become the same rows a live round writes, once, marked
# `source:"import"` — through append_round_and_timeline, so no field is computed twice and no
# row differs by provenance. Read-only over the records: the only file this walk writes is the
# ledger. Design: docs/specs/t-design.md §Import.

def _meta_env(task_dir: str) -> dict:
    """A task's `meta.env` as lib/taskstate.py's scan reads it: bash's `printf %q` output,
    unquoted enough for the fields a row needs. Duplicated rather than imported because this
    module is dependency-free by design; the forms and the fallbacks are the same three. An
    unreadable record raises — it is a skipped task, never an empty one."""
    out: dict[str, str] = {}
    with open(os.path.join(task_dir, "meta.env"), encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    for line in lines:
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if not key or not key.replace("_", "A").isalnum():
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        elif value.startswith("$'"):
            try:
                import ast
                value = ast.literal_eval(value[1:])
            except (ValueError, SyntaxError):
                pass
        elif "\\" in value:
            value = re.sub(r"\\(.)", r"\1", value)      # printf %q: every escape stands for itself
        out[key] = value
    return out


def _round_dirs(task_dir: str) -> list:
    """A task's round numbers, ascending — the numeric sort lib/taskstate.py's round_dirs
    applies. No readable rounds/ directory is simply no rounds."""
    out = []
    try:
        entries = os.scandir(os.path.join(task_dir, "rounds"))
    except OSError:
        return out
    with entries as it:
        for e in it:
            if e.name.isdigit() and e.is_dir():
                out.append(int(e.name))
    return sorted(out)


def _first_step_start_ms(derived: Mapping[str, Any] | None) -> int | None:
    """A round's start, as an import recovers it: the first timeline step's start, in ms (§Import
    — the first step's start is when the round began). Steps are in file order, so that is the
    first one carrying a number."""
    for step in (derived or {}).get("steps") or []:
        if isinstance(step, Mapping):
            n = _num(step.get("start"))
            if n is not None:
                return int(n)
    return None


def _seen_rounds(ledger_path: str) -> set:
    """The `(task_id, round)` pairs this ledger already holds a round row for, whatever wrote
    them: a round that ran live after the last prune is skipped by the import, not duplicated."""
    seen = set()
    for _lineno, _raw, row in read_rows(ledger_path):
        if row is None or row["kind"] != "round":
            continue
        n = _num(row.get("round"))
        if isinstance(row.get("task_id"), str) and n is not None:
            seen.add((row["task_id"], int(n)))
    return seen


def _inferred_effort(report_model: Any, model: str, model_hard: str) -> str:
    """Effort for a round whose `EFFORT` was never recorded: `hard` iff the model the round
    reports is the configured hard model and that model differs from the configured model —
    otherwise `normal`. An inference, and labelled one: the row says `inferred` (§Import)."""
    if model_hard and isinstance(report_model, str) and report_model == model_hard \
            and model_hard != model:
        return "hard"
    return "normal"


def _import_round(ledger_path: str, task_dir: str, round_no: int, task_id: str,
                  meta: Mapping[str, str], model: str, model_hard: str) -> int:
    """Both rows for one stored round, through the live path: the same report read, the same
    one parse of the round's events, the same builder. Returns the rows appended (1 for a round
    whose events.jsonl is already gone: a pruned round still counts, with null token sums).
    Every field the record no longer carries is left null, per §Import's recovery table: the
    endpoint was never written down, and neither the version, hashes, caps nor the count of
    rounds that ran beside it. `round_start` is the first step's start, `round_end` the report
    file's own mtime."""
    rd = os.path.join(task_dir, "rounds", str(round_no))
    report_path = os.path.join(rd, "report.json")
    events_path = os.path.join(rd, "events.jsonl")
    with open(report_path, encoding="utf-8") as f:
        report_model = json.load(f).get("model")
    spec_hash = None
    try:
        with open(os.path.join(task_dir, "spec.md"), "rb") as f:
            spec_hash = hashlib.sha256(f.read()).hexdigest()
    except OSError:
        pass                                                 # no spec copy, no spec hash
    diff_lines = None
    try:
        with open(os.path.join(rd, "diffstat"), encoding="utf-8", errors="replace") as f:
            diff_lines = parse_diffstat(f.read())
    except OSError:
        pass                                                 # nothing captured, nothing known
    derived = derive_timeline(events_path) if events_path else None
    start_ms = _first_step_start_ms(derived)
    try:
        round_end = int(os.path.getmtime(report_path))
    except OSError:
        round_end = None
    extra = {
        "task_id": task_id, "run_id": task_id,
        "slug": meta.get("SLUG") or None, "step": meta.get("SLUG") or None,
        "repo": meta.get("REPO") or None,
        "project": project_of(meta.get("GIT_COMMON", ""), meta.get("REPO") or ""),
        "chain": meta.get("CHAIN") or None,
        "base_ref": meta.get("BASE_REF") or None, "base_sha": meta.get("BASE_SHA") or None,
        "verify": meta.get("VERIFY") or None, "runner": meta.get("RUNNER") or None,
        "orchestrator": meta.get("ORCH") or None,
        "orchestrator_session": meta.get("ORCH_SESSION") or None,
        "effort": _inferred_effort(report_model, model, model_hard),
        "effort_source": "inferred",
        "spec_hash": spec_hash, "diff_lines": diff_lines,
        "round_start": int(start_ms / 1000) if start_ms is not None else None,
        "round_end": round_end,
        "source": "import",
    }
    return append_round_and_timeline(ledger_path, report_path, events_path, extra)


def import_state(ledger_path: str, state_dir: str, model: str = "",
                 model_hard: str = "") -> dict:
    """R8, once: every stored round that still exists becomes `round` + `timeline` rows written
    by the live code path, marked `source:"import"`.

    Walks the directories under `state_dir` that hold a `meta.env` — the scan lib/taskstate.py
    uses — in name order, and for each round dir holding a `report.json` appends its rows.
    Deduped on `(task_id, round)` against the round rows the ledger already holds (any source)
    and against what this call has already written, so importing twice adds nothing.

    Returns `{"imported": N, "skipped": M, "tasks": K, "warnings": [...]}`: a record this build
    could not read, or a round whose rows could not be written, is counted `skipped` with its
    reason in `warnings` — the walk continues, and nothing here is a failure. Rounds with no
    `report.json` (a round that never ended) are neither imported nor skipped: there is no row
    to write for them."""
    imported = skipped = tasks = 0
    warnings: list[str] = []
    try:
        entries = sorted(os.listdir(state_dir))
    except OSError as exc:
        return {"imported": 0, "skipped": 0, "tasks": 0,
                "warnings": [f"cannot read the state dir: {exc.strerror or exc}"]}
    seen = _seen_rounds(ledger_path)
    for name in entries:
        task_dir = os.path.join(state_dir, name)
        if not os.path.isdir(task_dir) or not os.path.isfile(os.path.join(task_dir, "meta.env")):
            continue                                         # the same filter as the top scan
        tasks += 1
        try:
            meta = _meta_env(task_dir)
            rounds = _round_dirs(task_dir)
        except OSError as exc:
            skipped += 1
            warnings.append(f"{name}: cannot read its record ({exc.strerror or exc})")
            continue
        task_id = meta.get("ID") or name
        for round_no in rounds:
            if not os.path.isfile(os.path.join(task_dir, "rounds", str(round_no), "report.json")):
                continue                                     # no report: no row to import
            if (task_id, round_no) in seen:
                skipped += 1
                continue
            try:
                _import_round(ledger_path, task_dir, round_no, task_id, meta, model, model_hard)
            except (ValueError, OSError) as exc:
                skipped += 1
                warnings.append(f"{name} round {round_no}: {exc}")
                continue
            seen.add((task_id, round_no))                    # two records, one task id: once
            imported += 1
    return {"imported": imported, "skipped": skipped, "tasks": tasks, "warnings": warnings}


# ---------------------------------------------------------------------- stats --------
# R6: per-project totals from the rows alone — never from task dirs, and never from chain
# state, which `chain --clean` removes. Everything here reads: it opens the ledger and writes
# nothing, ever. `timeline` rows are the biggest lines in the file and stats has no use for
# them, so they are dropped at the line level before anything is parsed. No prices and no
# dollar amounts appear anywhere in stats: R6 asks counts. Design: t-design.md §Stats.

STATS_KINDS = ("round", "review", "timeline")                 # the only kinds stats reads
STATS_AXES = ("repo", "chain", "model", "effort")       # R6's four group axes
TOKEN_FIELDS = ("input_tokens", "output_tokens", "reasoning_tokens",
                "cache_read", "cache_write")
# The statuses the failures table names even where their count is 0 (R6 names these four, so
# a run with no timeouts still reads `timeout 0` and two runs of stats stay comparable).
FAILURE_STATUSES = ("worker-error", "timeout", "truncated", "done-but-verify-failed")
STATUS_ORDER = ("done", "done-but-verify-failed") + FAILURE_STATUSES
_OK_STATUSES = ("done",)                                # ok% when no review rows exist
_ACCEPTED_VERDICTS = ("accepted", "fixed")              # ok% when review rows do exist

_KIND_HEAD = re.compile(r'^\{"kind":"([^"]+)"')


def _axis(row: Mapping[str, Any], field: str) -> str:
    """One grouping axis as a string: null (a round with no chain, an import that never saw
    the effort) is the empty axis, never the string 'None'."""
    value = row.get(field)
    if field == "repo":                                  # per project: the main checkout, so a
        value = row.get("project") or value             # chain run from a worktree joins its repo
    return "" if value is None or value == "" else str(value)


def read_stats_rows(ledger_path: str) -> dict:
    """The ledger's `round` and `review` rows, oldest first: `{"rows": [...], "skipped": n,
    "filtered": n}`. A missing, empty or unreadable file is no rows and no error — stats on
    such a ledger prints empty tables and loses nothing.

    Lines of a known kind that stats does not read (`timeline`, and slice B's once it writes
    them) are counted in `filtered` and dropped on the `kind` the writer put first, before
    parsing. `skipped` counts what this build cannot use at all: not JSON, not an object, a
    kind it does not know, a schema above the one it knows, a blank line. Neither count is a
    failure here: the caller prints one warning line for `skipped` and goes on."""
    out: dict[str, Any] = {"rows": [], "skipped": 0, "filtered": 0, "timelines": []}
    try:
        f = open(ledger_path, encoding="utf-8", errors="replace")
    except OSError:
        return out
    with f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                out["skipped"] += 1                          # a blank line holds no row
                continue
            head = _KIND_HEAD.match(raw)
            if head is not None:
                kind = head.group(1)
                if kind in STATS_KINDS or kind == "timeline":
                    pass                                     # parse it below, like any other
                elif kind in KINDS:
                    out["filtered"] += 1                      # known kind, not stats' business
                    continue
                else:
                    out["skipped"] += 1                       # unknown kind: never parsed
                    continue
            row = _accepted(raw)
            if row is None:
                out["skipped"] += 1
                continue
            if row["kind"] == "timeline":                     # stats joins these by (task_id,
                out["timelines"].append(row)                  # round) after the grouping pass
                continue
            if row["kind"] not in STATS_KINDS:
                out["filtered"] += 1
                continue
            out["rows"].append(row)
    return out


def _since_ok(ts: Any, since: str) -> bool:
    """`--since` on one row: a `ts` from that day or later. ISO-8601 UTC strings compare as
    strings; a row with no comparable ts is older than any date a caller can name."""
    return isinstance(ts, str) and ts[:10] >= since


def _new_group(key: tuple) -> dict:
    """One group's accumulators, keyed by R6's four axes. The private `_` keys hold what the
    printed figures are derived from and never reach the caller: `_finish_group` turns them
    into the table's own keys."""
    return {"axes": dict(zip(STATS_AXES, key)), "rounds": 0, "import_rounds": 0,
            "task_ids": [], "_max_round": {}, "_statuses": {}, "_tool_errors": 0,
            "_errors": 0, "_wall_s": 0.0, "_wall_n": 0,
            "_tokens": dict.fromkeys(TOKEN_FIELDS, 0), "_cache_pcts": [], "_done": 0,
            "_reviews": [], "_verdicts": dict.fromkeys(VERDICTS, 0),
            "_last": {}, "_task_verdict": {},
            "_bugs": {"high": 0, "medium": 0, "low": 0}, "_lines_changed": 0,
            "_keys": set(), "_requests": 0, "_rel_events": {},
            "_ctx": {}, "_verify_fails": 0}                # bucket -> {requests, events}


def _ctx_enter(group: dict, ctx: Any, kind: str | None = None) -> None:
    """One model request (kind None) or one reliability event into its context bucket."""
    label = ctx_bucket(ctx)
    cell = group["_ctx"].setdefault(label, {"requests": 0, "events": {}})
    if kind is None:
        cell["requests"] += 1
    else:
        cell["events"][kind] = cell["events"].get(kind, 0) + 1


def _add_timeline(group: dict, row: Mapping[str, Any]) -> None:
    """One timeline row's reliability into the group its round row belongs to. Every step is
    one model request, bucketed by its own context size; every event is one record, bucketed
    by the position it carries. A v1 row has no positions: its steps count as requests in the
    `unknown` bucket, and it holds no events. Only kinds, counts and buckets come out of a
    row here — never a step's or an event's text (R4)."""
    steps = row.get("steps")
    steps = steps if isinstance(steps, list) else []
    try:
        schema = int(row.get("schema") or 1)
    except (TypeError, ValueError):
        schema = 1
    if schema < 2:
        for _ in steps:
            group["_requests"] += 1
            _ctx_enter(group, None)
        return
    for s in steps:
        group["_requests"] += 1
        _ctx_enter(group, s.get("ctx") if isinstance(s, dict) else None)
    events = row.get("events")
    for ev in events if isinstance(events, list) else []:
        if not isinstance(ev, dict):
            continue
        kind = ev.get("kind")
        if not isinstance(kind, str) or not kind:
            continue
        group["_rel_events"][kind] = group["_rel_events"].get(kind, 0) + 1
        _ctx_enter(group, ev.get("ctx"), kind)


def _add_round(group: dict, row: Mapping[str, Any]) -> None:
    """One round row into its group. Every figure counts only what the row actually holds: a
    null duration, token sum or counter is nothing known rather than a zero, so a round whose
    events were pruned still counts its round and its status, and moves no average."""
    group["rounds"] += 1
    if row.get("source") == "import":
        group["import_rounds"] += 1
    task_id = row.get("task_id")
    rnd = _num(row.get("round"))
    if isinstance(task_id, str) and task_id and rnd is not None:
        group["_keys"].add((task_id, int(rnd)))              # the join key for a timeline row
    vrc = row.get("verify_rc")
    if isinstance(vrc, int) and not isinstance(vrc, bool) and vrc != 0:
        group["_verify_fails"] += 1     # from the round row: every schema has it, old rounds too
    named = isinstance(task_id, str) and task_id != ""
    if named and task_id not in group["task_ids"]:
        group["task_ids"].append(task_id)
    rnd = _num(row.get("round"))
    if named and rnd is not None and rnd >= 1:
        top = group["_max_round"].get(task_id)
        if top is None or rnd > top:
            group["_max_round"][task_id] = int(rnd)
    duration = _num(row.get("duration_s"))
    if duration is not None:
        group["_wall_s"] += float(duration)
        group["_wall_n"] += 1
    for field in TOKEN_FIELDS:
        n = _num(row.get(field))
        if n is not None:
            group["_tokens"][field] += int(n)
    cache_read, inp = _num(row.get("cache_read")), _num(row.get("input_tokens"))
    if cache_read is not None and inp is not None and (cache_read + inp) > 0:
        group["_cache_pcts"].append(cache_read / (cache_read + inp))
    for field, total in (("tool_errors", "_tool_errors"), ("errors", "_errors")):
        n = _num(row.get(field))
        if n is not None:
            group[total] += int(n)
    status = row.get("status")
    if named and rnd is not None:
        last = group["_last"].get(task_id)
        if last is None or rnd >= last[0]:
            group["_last"][task_id] = (rnd, status)
    if isinstance(status, str) and status:
        group["_statuses"][status] = group["_statuses"].get(status, 0) + 1
        if status in _OK_STATUSES:
            group["_done"] += 1


def _add_review(group: dict, row: Mapping[str, Any]) -> None:
    """One review row into its group's findings. Joined by task id, so a row that arrives here
    is already known to name a task this group holds rounds for."""
    group["_reviews"].append(row)
    verdict = row.get("verdict")
    if isinstance(row.get("task_id"), str) and verdict in VERDICTS:
        group["_task_verdict"][row["task_id"]] = verdict   # the latest review of a task wins
    if verdict in group["_verdicts"]:
        group["_verdicts"][verdict] += 1
    for severity in ("high", "medium", "low"):
        n = _num(row.get("bugs_" + severity))
        if n is not None:
            group["_bugs"][severity] += int(n)
    n = _num(row.get("lines_changed"))
    if n is not None:
        group["_lines_changed"] += int(n)


def _sorted_statuses(counts: Mapping[str, int]) -> dict:
    """A status histogram in print order: the design's named statuses first, then anything
    else the ledger carried, by name. Only statuses that occurred appear — a group that never
    timed out owns no `timeout` key, and the failures table prints its zero."""
    out = {k: counts[k] for k in STATUS_ORDER if k in counts}
    out.update({k: counts[k] for k in sorted(counts) if k not in out})
    return out


def _finish_group(group: dict) -> dict:
    """The accumulators as the printed figures. Retries are the design's derivation — `sum
    (max(round) - 1)` over the group's task ids, read off the rows and from nowhere else, which
    is why the round row carries `round` at all; ok% says which source it used; wall carries
    its mean beside its sum; cache% is the mean of the per-round ratios, over the rounds that
    had tokens to ratio."""
    axes = group["axes"]
    reviews = group["_reviews"]
    # ok% is per task (one step's outcome), never a mix of units: a reviewed task counts by its
    # latest verdict, an unreviewed one by its last round's status. The source says which applied.
    tasks = [t for t in group["task_ids"] if t in group["_last"] or t in group["_task_verdict"]]
    reviewed = [t for t in tasks if t in group["_task_verdict"]]
    ok_num = sum(1 for t in reviewed if group["_task_verdict"][t] in _ACCEPTED_VERDICTS) + sum(
        1 for t in tasks if t not in group["_task_verdict"] and group["_last"][t][1] in _OK_STATUSES)
    ok_den = len(tasks)
    ok_source = ("review" if reviewed and len(reviewed) == ok_den else
                 "mixed" if reviewed else "status")
    cache_pcts = group["_cache_pcts"]
    return {
        **{field: (axes[field] or None) for field in STATS_AXES},
        "rounds": group["rounds"],
        "import_rounds": group["import_rounds"],
        "task_ids": sorted(group["task_ids"]),
        "ok_pct": (100.0 * ok_num / ok_den) if ok_den else None,
        "ok_source": ok_source,
        "ok_num": ok_num, "ok_den": ok_den,
        "wall_s": group["_wall_s"], "wall_n": group["_wall_n"],
        "wall_mean_s": (group["_wall_s"] / group["_wall_n"]) if group["_wall_n"] else None,
        "tokens": dict(group["_tokens"]),
        "cache_pct": (100.0 * sum(cache_pcts) / len(cache_pcts)) if cache_pcts else None,
        "retries": sum(top - 1 for top in group["_max_round"].values()),
        "statuses": _sorted_statuses(group["_statuses"]),
        "tool_errors": group["_tool_errors"],
        "errors": group["_errors"],
        "findings": {"rows": len(reviews), **group["_verdicts"],
                     "bugs_high": group["_bugs"]["high"],
                     "bugs_medium": group["_bugs"]["medium"],
                     "bugs_low": group["_bugs"]["low"],
                     "lines_changed": group["_lines_changed"]},
        **_reliability(group),
    }


def _rate_per_100(counts: Mapping[str, int], denom: int) -> dict | None:
    """Each kind's occurrences per 100 of the denominator, two decimals; verify-fail is not
    a per-request rate (it ends a round, not a request) and has its own figure. Rates need a
    population: with no requests at all in the group, the answer is nothing known (None),
    not a division by zero."""
    if not denom:
        return None
    return {k: round(100.0 * n / denom, 2)
            for k, n in sorted(counts.items()) if k != "verify-fail"}


def _reliability(group: dict) -> dict:
    """R4-safe reliability figures from the timeline rows joined into a group: the model
    requests the round's steps carried, the reliability records per 100 of them, verify-fails
    per 100 rounds, and the same rates per context-size bucket. A group with no timeline rows
    has the zero, not the null — it saw rounds and no recorded interruptions."""
    rel = group["_rel_events"]
    by_ctx = {}
    for label, _hi in (*CTX_BUCKETS, ("unknown", None)):
        cell = group["_ctx"].get(label)
        if cell is None:
            continue
        by_ctx[label] = {"requests": cell["requests"],
                         "events": dict(sorted(cell["events"].items())),
                         "rates_per_100_requests": _rate_per_100(cell["events"],
                                                                  cell["requests"])}
    return {
        "requests": group["_requests"],
        "rates_per_100_requests": _rate_per_100(rel, group["_requests"]),
        # counted off the round rows' verify_rc, not the timeline events: a round recorded
        # before timeline schema 2 failed its verify just the same
        "verify_fails": group["_verify_fails"],
        "verify_fail_per_100_rounds": round(100.0 * group["_verify_fails"] / group["rounds"], 2)
        if group["rounds"] else None,
        "by_context": by_ctx,
    }


def stats(ledger_path: str, chain: str = "", repo: str = "", since: str = "") -> dict:
    """R6's totals over one ledger, as plain JSON-ready data and none of it a rendering:
    `{"ledger", "filters", "counts", "groups", "findings", "failures", "totals", "skipped",
    "filtered"}`. `chain`, `repo` and `since` narrow the rows before anything is grouped — they
    match a row's own field exactly, and `--since` compares on `ts`, so a row with no `ts`
    matches no date. The path is reported as it was given; a ledger that is missing, empty or
    unreadable yields empty tables, not an error, because stats is a reader and an owner who
    has not run a round yet has a real answer of zero, not a failure.

    Groups come from the `round` rows, keyed by repo / chain / model / effort. `review` rows
    join a group by `task_id`: a review whose task the filters removed appears in no table,
    and a review naming no task this ledger holds rounds for has no axes to belong to and
    counts only in `counts.review_rows`. Import-sourced rows are counted in their group and
    reported beside the round count (`import_rounds`) — they never mix silently into a live
    group's total, and a group of them takes its ok% from statuses anyway, since no review
    rows exist for an import."""
    data = read_stats_rows(ledger_path)
    groups: dict[tuple, dict] = {}
    by_task: dict[str, set] = {}
    total = _new_group(("", "", "", ""))            # the same accumulators, over every kept row
    counts = {"round_rows": 0, "review_rows": 0, "timeline_rows": 0}
    tl_index: dict[tuple, dict] = {}               # (task_id, round) -> its timeline row
    for row in data["timelines"]:
        task_id, rnd = row.get("task_id"), _num(row.get("round"))
        if isinstance(task_id, str) and task_id and rnd is not None:
            tl_index[(task_id, int(rnd))] = row    # a rerun's row supersedes the earlier one
    for row in data["rows"]:
        if since and not _since_ok(row.get("ts"), since):
            continue
        if row["kind"] != "round":
            counts["review_rows"] += 1
            continue
        if chain and _axis(row, "chain") != chain:
            continue
        if repo and _axis(row, "repo") != repo:
            continue
        counts["round_rows"] += 1
        key = tuple(_axis(row, field) for field in STATS_AXES)
        group = groups.get(key)
        if group is None:
            groups[key] = group = _new_group(key)
        _add_round(group, row)
        _add_round(total, row)
        task_id = row.get("task_id")
        if isinstance(task_id, str) and task_id:
            by_task.setdefault(task_id, set()).add(key)
    # The reliability pass: every kept round row that has a timeline row gets one. A round
    # whose events were pruned (or a v1 round imported from before positions) has none, and
    # contributes nothing here — its rounds and statuses are already in the group.
    for row in data["rows"]:
        if since and not _since_ok(row.get("ts"), since):
            continue
        if row["kind"] != "round" or (_axis(row, "chain") and chain and _axis(row, "chain") != chain) \
                or (repo and _axis(row, "repo") != repo):
            continue
        tl = tl_index.get((row.get("task_id"), int(_num(row.get("round")) or 0)))
        if tl is None:
            continue
        counts["timeline_rows"] += 1
        key = tuple(_axis(row, field) for field in STATS_AXES)
        _add_timeline(groups.get(key) or total, tl)
        _add_timeline(total, tl)
    joined: set = set()
    for row in data["rows"]:
        if row["kind"] != "review":
            continue
        if since and not _since_ok(row.get("ts"), since):
            continue
        keys = by_task.get(row.get("task_id"), ())
        if keys and id(row) not in joined:
            _add_review(total, row)                   # once per row, whatever it joined
            joined.add(id(row))
        for key in keys:
            _add_review(groups[key], row)

    finished = [_finish_group(groups[key]) for key in sorted(groups)]
    totals = _finish_group(total)
    for field in STATS_AXES:                             # a total belongs to no one group
        totals.pop(field, None)
    totals["groups"] = len(finished)
    return {
        "ledger": ledger_path,
        "filters": {"chain": chain or None, "repo": repo or None, "since": since or None},
        "counts": {**counts, "groups": len(finished)},
        "groups": finished,
        "findings": [_findings_table_row(g) for g in finished],
        "failures": [_failures_table_row(g) for g in finished],
        "totals": totals,
        "skipped": data["skipped"],
        "filtered": data["filtered"],
    }


def _axes_label(group: Mapping[str, Any]) -> str:
    """`repo/chain`, an empty axis shown as `-` so a chainless group still reads as one."""
    return f"{group['repo'] or '-'}/{group['chain'] or '-'}"


def _findings_table_row(g: Mapping[str, Any]) -> dict:
    """One findings row: review rows only, joined to its group by task id."""
    return {"axes": _axes_label(g), "model": g["model"], "effort": g["effort"],
            **g["findings"]}


def _failures_table_row(g: Mapping[str, Any]) -> dict:
    """One failures row: the counters R6 names, with the four statuses it names always
    present at their zero so the column a run did not use still reads as a zero."""
    statuses = {name: g["statuses"].get(name, 0) for name in FAILURE_STATUSES}
    statuses.update({k: v for k, v in g["statuses"].items() if k not in statuses})
    return {"axes": _axes_label(g), "model": g["model"], "effort": g["effort"],
            "tool_errors": g["tool_errors"], "errors": g["errors"], "statuses": statuses,
            "verify_fails": g["verify_fails"]}

