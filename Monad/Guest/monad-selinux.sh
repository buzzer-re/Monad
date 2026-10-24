#!/bin/sh
# monad-selinux.sh — load Monad's SELinux module (monad.cil, next to this
# script) where SELinux is on, when it is new or changed, then start the
# agent socket again if it is enabled (it failed without the module). Run by
# cloud-init at first boot and by the installer Monad runs at every boot.
# MONAD_ROOT exists for its tests (CTests/test_selinux.sh).

set -u
ROOT=${MONAD_ROOT:-}
CIL="$ROOT/usr/local/lib/monad/monad.cil"
LOADED="$ROOT/var/lib/monad/monad.cil.loaded"

[ -e "$ROOT/sys/fs/selinux/enforce" ] || exit 0
command -v semodule >/dev/null 2>&1 || exit 0
[ -f "$CIL" ] || exit 0

if semodule -l 2>/dev/null | grep -qx monad && cmp -s "$CIL" "$LOADED"; then exit 0; fi
if ! err=$(semodule -i "$CIL" 2>&1); then
    echo "monad-selinux: Monad's SELinux module was not loaded: $(printf '%s\n' "$err" | tail -1)"
    exit 0
fi
mkdir -p "$(dirname "$LOADED")" && cp "$CIL" "$LOADED"
echo "monad-selinux: loaded Monad's SELinux module"
if systemctl is-enabled -q monad-agent.socket 2>/dev/null; then
    systemctl reset-failed monad-agent.socket
    systemctl restart monad-agent.socket
fi
exit 0
