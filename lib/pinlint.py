#!/usr/bin/env python3
"""pinlint.py — lint a project's .delegate/Dockerfile: every add must be pinned.

Usage: pinlint.py DOCKERFILE
  exit 0 when every install is exactly pinned (or carries a justified marker);
  exit 1 when any is not. It prints one line per finding, in file order:
      <file>:<line>: <what>: <why>
  and one line per allowed marker:
      <file>:<line>: allowed: <reason>

Why: the project image IS part of the toolchain contract. A rebuild that silently
changes a compiler changes the bytes the repo's own gates compare (gorb-os's shelf
check is byte-for-byte on clang's output, yet pinned only `clang-21`). So everything
a project image installs is pinned exactly:

  FROM                 a base other than delegate-worker / a base ARG, and not @sha256-pinned
  apt-get install/apt  a package without `=` (flags ignored)
  pip / pip3 / python -m pip install   a requirement without `==` or `#sha256=`
  npm install -g / i -g                a package without `@<exact version>`
  curl / wget          a URL with no version token (digit.digit) and no sha256 check in the RUN
  git clone            no --branch/-b <tag> (main/master/HEAD count as unpinned) and no
                       `git checkout <ref>` later in the RUN

`ARG NAME=default` counts as that value, so a `${NAME}` carrying a version is pinned.
A line carrying `# delegate: unpinned-ok <reason>` is allowed only with a non-empty
reason, and is listed as "allowed: <reason>".
"""
import os
import re
import shlex
import sys

MARKER = re.compile(r'\bdelegate:\s*unpinned-ok\b(.*)$')
VERSION = re.compile(r'\d+\.\d+')
EXACT_NPM = re.compile(r'^(?:@[^/]+/)?[^@]+@\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]+)?$')
URLISH = re.compile(r'^[a-z][a-z0-9+.-]*://', re.I)
APT_VALUE = {'-t', '--target-release', '-o', '--option', '-c', '--config', '-d', '--download-only'}
PIP_VALUE = {'-r', '--requirement', '-e', '--editable', '-c', '--constraint', '-i',
             '--index-url', '--extra-index-url', '-f', '--find-links', '-t', '--target',
             '--upgrade-strategy', '-C', '--config-settings', '--proxy', '--trusted-host',
             '--platform', '--python-version', '--implementation', '--abi',
             '--no-binary', '--only-binary'}
BASE_PREFIX = 'delegate-worker'
PATHISH = ('.', '..', '/')


def strip_comment(text):
    """Split an unquoted, word-initial `#` comment off a shell fragment."""
    out, q, i = [], None, 0
    while i < len(text):
        c = text[i]
        if q:
            out.append(c)
            if c == q:
                q = None
        elif c in '"\'':
            q = c
            out.append(c)
        elif c == '#' and (i == 0 or text[i - 1] in ' \t'):
            return ''.join(out), text[i:]
        else:
            out.append(c)
        i += 1
    return ''.join(out), ''


def split_commands(code):
    """Split a RUN body on &&, ;, | at quote depth 0 -> [(text, start_index)]."""
    parts, q, start, i, n = [], None, 0, 0, len(code)
    while i < n:
        c = code[i]
        if q:
            if c == q:
                q = None
            i += 1
            continue
        if c in '"\'':
            q = c
            i += 1
            continue
        if c in '&;|':
            step = 2 if code.startswith(c + c, i) else 1
            if i > start:
                parts.append((code[start:i], start))
            i += step
            start = i
            continue
        i += 1
    if n > start:
        parts.append((code[start:], start))
    return parts


def words(text):
    try:
        return shlex.split(text)
    except ValueError:
        return text.split()


class Ins:
    __slots__ = ('directive', 'line', 'args', 'code', 'map', 'marker_line', 'marker_reason')

    def __init__(self, directive, line):
        self.directive = directive
        self.line = line
        self.args = ''
        self.code = ''
        self.map = []
        self.marker_line = None
        self.marker_reason = None


def parse(path):
    """Yield Ins objects in file order. Backslash continuations are joined; comment
    lines (whole-line, or the inline tail of a code line) are collected as markers."""
    text = open(path, encoding='utf-8').read()
    lines = text.split('\n')
    pending = []            # leading whole-line comments, (lineno, text), for the next instruction
    out = []
    i, n = 0, len(lines)
    while i < n:
        ln = lines[i]
        num = i + 1
        s = ln.strip()
        if s == '':
            pending = []
            i += 1
            continue
        if s.startswith('#'):
            pending.append((num, ln))
            i += 1
            continue
        d = re.match(r'\s*(\S+)(.*)', ln, re.S)
        ins = Ins(d.group(1).upper(), num)
        parts = []          # (lineno, code_without_comment)
        comments = list(pending)
        pending = []

        def feed(line_text, lineno):
            code, comment = strip_comment(line_text)
            comments.append((lineno, comment))
            code = re.sub(r'\\\s*$', '', code)
            parts.append((lineno, code))

        # first physical line: only the arguments after the directive are shell text
        code0, comm0 = strip_comment(d.group(2))
        comments.append((num, comm0))
        ins.args = re.sub(r'\\\s*$', '', code0)
        parts.append((num, re.sub(r'\\\s*$', '', code0)))
        cont = re.search(r'\\\s*$', ln)
        i += 1
        while cont:
            if i >= n:
                break
            nxt = lines[i]
            if nxt.strip().startswith('#'):
                comments.append((i + 1, nxt))
                cont = re.search(r'\\\s*$', nxt)
                i += 1
                continue
            cont = re.search(r'\\\s*$', nxt)
            feed(nxt, i + 1)
            i += 1
        # joined code with a char -> physical-line map
        code, cmap = [], []
        for lineno, p in parts:
            for ch in p:
                code.append(ch)
                cmap.append(lineno)
            code.append(' ')
            cmap.append(lineno)
        ins.code = ''.join(code)
        ins.map = cmap
        for lineno, c in comments:
            m = MARKER.search(c)
            if m and ins.marker_reason is None:
                ins.marker_line = lineno
                ins.marker_reason = m.group(1).strip()
        out.append(ins)
    return out


def sub(text, args):
    """Expand ${NAME} / $NAME using recorded ARG defaults (unknown left as-is)."""
    def rep(m):
        return args.get(m.group(1) or m.group(2), m.group(0))
    return re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)', rep, text)


def has_sha256(code):
    return bool(re.search(r'sha256sum\s+-c', code)) or \
        bool(re.search(r'\b[0-9a-fA-F]{64}\b[^\n]{0,40}\|\s*sha256sum', code))


def req_pinned(req):
    if req.startswith(PATHISH) or req.startswith('file:'):
        return True
    if '==' in req:
        return True
    if '#' in req and 'sha256=' in req:
        return True
    return False


def check_requirements_file(ctx, rel):
    """Return None if a -r FILE is fully ==-pinned, else a reason string."""
    if os.path.isabs(rel):
        return "-r path is absolute, outside the build context"
    full = os.path.normpath(os.path.join(ctx, rel))
    if not (full == ctx or full.startswith(ctx + os.sep)):
        return "-r file is outside the build context"
    if not os.path.isfile(full):
        return "-r file is not in the build context"
    try:
        body = open(full, encoding='utf-8').read().split('\n')
    except OSError as e:
        return "-r file unreadable: %s" % e
    for raw in body:
        line = raw.split('#', 1)[0].strip()
        if not line or line.startswith('-'):
            continue
        if '==' not in line:
            return "line in %s is not ==-pinned: %s" % (rel, line)
    return None


def line_of(m, cmap):
    """Physical line number of a command segment starting at char index m."""
    for i in range(m, len(cmap)):
        if cmap[i] is not None:
            return cmap[i]
    return m


def check_run(ins, ctx, args, report):
    code = sub(ins.code, args)
    sha = has_sha256(code)
    segs = split_commands(code)
    segw = [(seg, off, words(seg)) for (seg, off) in segs]

    def git_checkout_after(clone_off):
        for seg, off, w in segw:
            if off > clone_off and len(w) >= 2 and w[0] == 'git' and 'checkout' in w[1:]:
                return True
        return False

    for seg, off, w in segw:
        if not w:
            continue
        prog, lineno = os.path.basename(w[0]), line_of(off, ins.map)
        rest = w[1:]

        # --- apt-get install / apt install -------------------------------------------
        if prog in ('apt-get', 'apt') and 'install' in rest:
            i, pkgs = rest.index('install') + 1, []
            while i < len(rest):
                t = rest[i]
                if t.startswith('-'):
                    base = t.split('=', 1)[0]
                    if base in APT_VALUE and '=' not in t and i + 1 < len(rest):
                        i += 2
                        continue
                    i += 1
                    continue
                pkgs.append(t)
                i += 1
            bad = [p for p in pkgs if '=' not in p]
            if bad:
                report(lineno, 'apt-get install', "packages not pinned with =: " + " ".join(bad))
            continue

        # --- pip / pip3 / python -m pip install --------------------------------------
        pip_i = None
        if prog in ('pip', 'pip3') or re.match(r'^pip\d*(\.\d+)*$', prog):
            pip_i = 0
        elif re.match(r'^python(\d+(\.\d+)*)?$', prog) and len(rest) >= 3 \
                and rest[0] == '-m' and re.match(r'^pip\d*(\.\d+)*$', rest[1]):
            pip_i = 1
        if pip_i is not None and 'install' in rest[pip_i:]:
            tail = rest[pip_i:]
            j, reqs = tail.index('install') + 1, []
            while j < len(tail):
                t = tail[j]
                if t.startswith('-'):
                    base = t.split('=', 1)[0]
                    if base in ('-r', '--requirement') and '=' not in t and j + 1 < len(tail):
                        r = check_requirements_file(ctx, tail[j + 1])
                        if r:
                            report(lineno, 'pip install -r', r)
                        j += 2
                        continue
                    if base in PIP_VALUE and '=' not in t and j + 1 < len(tail):
                        j += 2
                        continue
                    j += 1
                    continue
                reqs.append(t)
                j += 1
            bad = [r for r in reqs if not req_pinned(r)]
            if bad:
                report(lineno, 'pip install', "requirements not pinned with ==: " + " ".join(bad))
            continue

        # --- npm install -g / npm i -g -----------------------------------------------
        if prog == 'npm' and rest and rest[0] in ('install', 'i', 'add', 'is'):
            if any(t in ('-g', '--global') for t in rest):
                bad, k = [], 1
                while k < len(rest):
                    t = rest[k]
                    if t.startswith('-'):
                        k += 1
                        continue
                    if not EXACT_NPM.match(t) and not t.startswith(PATHISH):
                        bad.append(t)
                    k += 1
                if bad:
                    report(lineno, 'npm install -g', "packages not pinned to @<exact version>: " + " ".join(bad))
            continue

        # --- curl / wget fetch -------------------------------------------------------
        if prog in ('curl', 'wget'):
            for u in [t for t in rest if URLISH.match(sub(t, args))]:
                su = sub(u, args)
                if VERSION.search(su) or sha:
                    continue
                report(lineno, prog, "fetch has no version token in the URL and no sha256 check in the RUN: " + u)
            continue

        # --- git clone ---------------------------------------------------------------
        if prog == 'git' and 'clone' in rest:
            branch, k = None, rest.index('clone') + 1
            while k < len(rest):
                t = rest[k]
                if t in ('--branch', '-b') and k + 1 < len(rest):
                    branch = rest[k + 1]
                    k += 2
                    continue
                if t.startswith('--branch='):
                    branch = t.split('=', 1)[1]
                k += 1
            if branch in (None, 'main', 'master', 'HEAD') and not git_checkout_after(off):
                why = "no --branch <tag> and no git checkout in this RUN" if branch is None \
                    else "--branch '%s' is a moving ref" % branch
                report(lineno, 'git clone', why)
            continue


def check_from(ins, args, report):
    a = [t for t in words(ins.args) if not t.startswith('--')]   # drop --platform=...
    if not a:
        return
    ref = a[0]
    sref = sub(ref, args)
    if '@sha256:' in ref or '@sha256:' in sref:
        return
    if re.match(r'^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$', ref):
        return                                  # parameterised base ($BASE-style ARG)
    if sref.startswith(BASE_PREFIX):
        return
    report(ins.line, 'FROM',
           "base image is not delegate-worker (or a $BASE ARG) and not @sha256-pinned: " + ref)


def main(argv):
    if len(argv) != 2 or argv[1] in ('-h', '--help'):
        sys.stderr.write("usage: pinlint.py DOCKERFILE\n")
        return 2
    path = argv[1]
    if not os.path.isfile(path):
        sys.stderr.write("pinlint.py: not a file: %s\n" % path)
        return 2
    ctx = os.path.dirname(os.path.abspath(path))
    lines, seq = [], [0]

    def report(lineno, what, why):
        seq[0] += 1
        lines.append((lineno, seq[0], "%s:%d: %s: %s" % (path, lineno, what, why), True))

    args = {}
    for ins in parse(path):
        mline, mreason = ins.marker_line, ins.marker_reason
        if mline is not None:
            if mreason:
                seq[0] += 1
                lines.append((ins.line, seq[0], "%s:%d: allowed: %s" % (path, ins.line, mreason), False))
                continue
            report(mline, 'delegate: unpinned-ok', 'marker has no reason (a non-empty reason is required)')
        if ins.directive == 'ARG':
            m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)(?:=(.*))?', ins.args, re.S)
            if m and m.group(2) is not None:
                args[m.group(1)] = m.group(2).strip('"\'')
            continue
        if ins.directive == 'FROM':
            check_from(ins, args, report)
            continue
        if ins.directive == 'RUN':
            check_run(ins, ctx, args, report)
            continue

    lines.sort(key=lambda r: (r[0], r[1]))
    for _, _, text, _ in lines:
        print(text)
    return 1 if any(f for _, _, _, f in lines) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
