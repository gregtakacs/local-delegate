#!/usr/bin/env bash
# The docker verify mirrors the host: its umask, and XDG_CONFIG_HOME when the host sets one
# (pointing at the worker's own $HOME/.config). DELEGATE_VERIFY_MIRROR_HOST=0 turns it off.
set -u
cd "$(dirname "$0")/.."
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
fn=$(sed -n '/^verify_wrapped()/,/^}/p' bin/delegate)
run() { # MIRROR -> prints "umask|xdg" as the wrapped verify sees them
  DELEGATE_RUNNER=docker VERIFY_KEEP_SIZE=2M VERIFY_KEEP_MAX=5 DELEGATE_VERIFY_MIRROR_HOST=$1 \
    bash -c "$fn"'
      umask 002; export XDG_CONFIG_HOME=/host/xdg
      script=$(verify_wrapped "echo \"\$(umask)|\${XDG_CONFIG_HOME:-unset}\"" "$(mktemp -d)/keep")
      (umask 022; unset XDG_CONFIG_HOME; HOME=/home/worker bash -c "$script")'
}
out=$(run 1)
[ "$out" = "0002|/home/worker/.config" ] && ok "mirror on: verify sees the host umask and an XDG under its own HOME" || bad "mirror on: got '$out'"
out=$(run 0)
[ "$out" = "0022|unset" ] && ok "mirror off: verify keeps the container's own environment" || bad "mirror off: got '$out'"
exit $fail
