#!/usr/bin/env python3
"""The launch fingerprint: which shell command started this delegate run.

Claude Code runs every Bash tool call as

    /bin/bash -c '<prelude> && eval '"'"'<command>'"'"' && pwd -P >| /tmp/claude-XXXX-cwd'

and <command> is, byte for byte, the `command` of the Bash tool_use in the launching agent's
transcript. A sub-agent's shell has exactly its parent session's environment, so the env cannot
say which sub-agent launched a run; the sha256 of that command can, matched against the
transcripts. Only the hash is ever produced: the command text is never stored or printed.

  launch.py [--pid PID] [--proc DIR]   print the lowercase hex sha256, or nothing; exit 0 always

`launch_sha256()` walks up from PID (default: this process) through `/proc/<pid>/stat`'s parent
field, at most MAX_DEPTH parents, to the first ancestor whose argv is `[.../bash, -c, S]` with
` && eval '` in S, and hashes the single shell word after that `eval`. No such ancestor, a parse
failure, an oversized cmdline (over CMDLINE_CAP bytes) or a system without /proc: None. It never
raises: a fingerprint must never change or stop the run that asks for it.
"""
import hashlib
import os
import shlex
import sys

MAX_DEPTH = 8                 # parents examined above the starting process
CMDLINE_CAP = 1 << 20         # bytes read from one /proc/<pid>/cmdline; a longer one is no match
STAT_CAP = 4096
WRAPPER = " && eval '"


class Oversized(Exception):
    """A /proc file longer than its cap: hostile or not, it is not read further."""


def proc_reader(root="/proc"):
    """read(pid, name) -> the bytes of <root>/<pid>/<name>, None when unreadable, or Oversized
    when it is longer than that file's cap."""
    def read(pid, name):
        cap = CMDLINE_CAP if name == "cmdline" else STAT_CAP
        try:
            with open(os.path.join(root, str(pid), name), "rb") as f:
                data = f.read(cap + 1)
        except OSError:
            return None
        if len(data) > cap:
            raise Oversized(name)
        return data
    return read


def parent_pid(stat):
    """Field 4 of /proc/<pid>/stat. The comm field (2) is parenthesised and may itself hold
    spaces and ')', so the fields are counted from the LAST ')'."""
    try:
        rest = stat[stat.rindex(b")") + 1:].split()
        return int(rest[1])
    except (ValueError, IndexError):
        return None


def eval_command(argv):
    """The command a Claude Code Bash wrapper evals, or None when argv is not that wrapper."""
    if len(argv) != 3 or argv[1] != "-c":
        return None
    if argv[0] != "bash" and not argv[0].endswith("/bash"):
        return None
    s = argv[2]
    i = s.find(WRAPPER)
    if i < 0:
        return None
    try:
        lex = shlex.shlex(s[i + len(WRAPPER) - 1:], posix=True)
        lex.whitespace_split = True
        lex.commenters = ""
        word = lex.get_token()
    except ValueError:                  # an unterminated quote: not the wrapper's shape
        return None
    return word if isinstance(word, str) else None


def launch_sha256(pid=None, read=None, max_depth=MAX_DEPTH):
    """The lowercase hex sha256 of the launching Bash tool call's command, or None."""
    try:
        if read is None:
            if not sys.platform.startswith("linux") or not os.path.isdir("/proc"):
                return None
            read = proc_reader()
        pid = os.getpid() if pid is None else int(pid)
        seen = set()
        for _ in range(max_depth + 1):          # the starting process, then its parents
            if pid is None or pid <= 0 or pid in seen:
                return None
            seen.add(pid)
            raw = read(pid, "cmdline")
            if raw:
                argv = [a.decode("utf-8", "surrogateescape") for a in raw.rstrip(b"\0").split(b"\0")]
                cmd = eval_command(argv)
                if cmd is not None:
                    return hashlib.sha256(cmd.encode("utf-8", "surrogateescape")).hexdigest()
            if pid == 1:
                return None
            stat = read(pid, "stat")
            pid = parent_pid(stat) if stat else None
        return None
    except Exception:                           # noqa: BLE001 — never raise, by contract
        return None


def main(argv):
    pid, root = None, None
    try:
        while argv:
            flag = argv.pop(0)
            if flag == "--pid":
                pid = int(argv.pop(0))
            elif flag == "--proc":
                root = argv.pop(0)
            else:
                return 0
    except (IndexError, ValueError):
        return 0
    h = launch_sha256(pid, proc_reader(root) if root else None)
    if h:
        print(h)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
