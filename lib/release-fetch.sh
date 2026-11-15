#!/usr/bin/env bash
# lib/release-fetch.sh — the fetch/verify/flip block of `install.sh --release`, as one sourceable
# function so `delegate update` retargets `current` with the SAME code the installer runs: two
# copies of this logic, one that checks VERSION and one that forgets, is a supply-chain bug.
# Plain bash, no dependencies. Safe to source more than once: it defines functions only.
#
#   release_fetch TAG URL DEST_ROOT
#
# Clones TAG (depth 1) from URL into DEST_ROOT/TAG, refuses unless the clone really carries the
# tag and its VERSION file matches the tag, writes the version/source stamps, then flips
# DEST_ROOT/current to it with `mv -T` (atomic by construction: `current` is never dangling).
# Exit codes and refusal messages are install.sh's: 2 for a tag that is not a plain name, 1 for
# every refusal. An existing version dir is reused, never rewritten, and only when its own
# .delegate-version stamp names it.
#
# Optional globals the caller sets: RF_PROG (message prefix, default install.sh), RF_FLAG (the
# flag that carried the tag, default --release), RF_SAY (the progress printer).
rf_say() { printf '==> %s\n' "$*"; }

release_fetch() {
  local tag=$1 url=$2 root=$3
  local prog=${RF_PROG:-install.sh} flag=${RF_FLAG:---release}
  local printer=${RF_SAY:-rf_say}
  local cur dest tmp want have

  case "$tag" in */*|.*|-*|*' '*|"") echo "$prog: $flag wants a plain tag name, got '$tag'" >&2; return 2 ;; esac
  mkdir -p -m 700 "$root"
  cur=$root/current
  if [ -e "$cur" ] && [ ! -L "$cur" ]; then
    echo "$prog: $cur exists and is not a symlink; that is not the shape install --release" >&2
    echo "  manages (a symlink flipped between version dirs). Move it aside and re-run;" >&2
    echo "  install.sh will never remove that directory." >&2
    return 1
  fi
  dest=$root/$tag
  if [ -e "$dest" ]; then
    # An existing version dir is only reusable when its own stamp says it is this tag.
    if [ "$(head -n1 "$dest/.delegate-version" 2>/dev/null || true)" = "$tag" ]; then
      "$printer" "release $tag already installed: $dest (fetch skipped)"
    else
      echo "$prog: refusing: $dest exists and its .delegate-version is not '$tag'" >&2
      return 1
    fi
  else
    "$printer" "fetching $tag from $url"
    tmp=$dest.tmp
    rm -rf "$tmp"
    git clone --quiet --depth 1 --branch "$tag" "$url" "$tmp" \
      || { rm -rf "$tmp"; echo "$prog: refusing: clone of tag '$tag' from $url failed" >&2; return 1; }
    git -C "$tmp" rev-parse -q --verify "refs/tags/$tag" >/dev/null \
      || { rm -rf "$tmp"; echo "$prog: refusing: tag '$tag' missing in the clone" >&2; return 1; }
    want=${tag#v}
    have=$(cat "$tmp/VERSION" 2>/dev/null || true)
    [ "$have" = "$want" ] \
      || { rm -rf "$tmp"; echo "$prog: refusing: tag $tag carries VERSION '${have:-<missing>}', expected '$want'" >&2; return 1; }
    mv -T "$tmp" "$dest" || { rm -rf "$tmp"; echo "$prog: refusing: $dest appeared while fetching" >&2; return 1; }
    { printf '%s\n' "$tag" >"$dest/.delegate-version" \
      && printf 'repo=%s\ntag=%s\n' "$url" "$tag" >"$dest/.delegate-source"; } \
      || { rm -rf "$dest"; echo "$prog: refusing: cannot write stamps under $dest" >&2; return 1; }
  fi
  ln -sfn "./$tag" "$root/.current.tmp" && mv -T "$root/.current.tmp" "$cur" \
    || { rm -f "$root/.current.tmp"; echo "$prog: refusing: cannot flip $cur" >&2; return 1; }
  "$printer" "current -> $dest"
  return 0
}
