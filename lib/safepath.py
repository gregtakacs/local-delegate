#!/usr/bin/env python3
"""The identity of a directory reached without following any symlink (DELEGATE_UNTRUSTED_REPO).

    python3 -I safepath.py PATH...      one "PATH<TAB>DEV:INO" line per PATH, in order

Every PATH must be absolute and already normal (no `.`, `..`, empty component or trailing
slash) and must be a directory reached from `/` one component at a time with O_NOFOLLOW, so a
symlink at ANY component is refused — a final one included. The DEV:INO printed is that of the
directory actually opened (fstat on the descriptor), never of a second lookup of the path.

delegate uses it twice for an untrusted repository: the host refuses a path that is (or runs
through) a symlink before it hands the path to docker, and the container checks, after docker
mounted it, that what it got has this DEV:INO (lib/sandbox-git.sh `verify_mounts`). A path
swapped for a symlink between the two is caught by the second: the mount is compared with the
directory this walk opened, not with a path.

Exit 0 when every path passes; 3 with "SECURITY: ..." on stderr for the first that does not;
2 on bad usage. Run it with `python3 -I` so nothing from the caller's cwd is importable.
"""
import os
import stat
import sys


def walk(path):
    if not path.startswith("/") or "\n" in path or "\t" in path or "\0" in path:
        raise ValueError("not an absolute single-line path")
    parts = path.split("/")[1:]
    if path != "/" and any(p in ("", ".", "..") for p in parts):
        raise ValueError("not a normal path (empty, '.' or '..' component, or a trailing slash)")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC | getattr(os, "O_PATH", 0)
    fd = os.open("/", flags)
    try:
        for p in (parts if path != "/" else []):
            try:
                nfd = os.open(p, flags, dir_fd=fd)
            except OSError as e:
                # ELOOP: the component is a symlink; ENOTDIR: a file (or a symlink, with O_PATH)
                try:
                    st = os.lstat(p, dir_fd=fd)
                    what = "a symlink" if stat.S_ISLNK(st.st_mode) else "not a directory"
                except OSError:
                    what = os.strerror(e.errno)
                raise ValueError(f"component {p!r} is {what}") from None
            os.close(fd)
            fd = nfd
        st = os.fstat(fd)
        if not stat.S_ISDIR(st.st_mode):
            raise ValueError("not a directory")
        return f"{st.st_dev}:{st.st_ino}"
    finally:
        os.close(fd)


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out = []
    for p in argv:
        try:
            out.append(f"{p}\t{walk(p)}")
        except ValueError as e:
            print(f"SECURITY: {p}: {e}", file=sys.stderr)
            return 3
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
