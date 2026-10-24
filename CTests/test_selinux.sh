#!/bin/sh
# Tests for Monad/Guest/monad-selinux.sh: Monad's SELinux module is loaded
# only where SELinux is on, only when new or changed, and the agent socket
# is started again after it. Stand-ins for semodule and systemctl, a fake
# root. Usage: test_selinux.sh [workdir]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../Monad/Guest/monad-selinux.sh"
SH=${SELINUX_SHELL:-sh}
WORK=${1:-$(mktemp -d)}
rm -rf "$WORK"
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
checks=0
failures=0

check() { # check NAME EXPECTED ACTUAL
    checks=$((checks + 1))
    if [ "$2" != "$3" ]; then
        failures=$((failures + 1))
        printf '%s: FAIL\n--- expected\n%s\n--- got\n%s\n' "$1" "$2" "$3" >&2
    fi
}

BIN="$WORK/bin"
STATE="$WORK/state"
ROOT="$WORK/root"
mkdir -p "$BIN"
stub() { { echo '#!/bin/sh'; echo 'echo "'"$1"' $*" >>"$FAKE_STATE/log"'; cat; } >"$BIN/$1"; chmod +x "$BIN/$1"; }
stub semodule <<'EOF'
case "$1" in
    -l) cat "$FAKE_STATE/modules" 2>/dev/null ;;
    -i) [ "${FAKE_SEMODULE_FAILS:-0}" = 0 ] || { echo "semodule: bad rule" >&2; exit 1; }
        echo monad >>"$FAKE_STATE/modules" ;;
esac
EOF
stub systemctl <<'EOF'
case "$1" in is-enabled) [ -e "$FAKE_STATE/agent-enabled" ] ;; esac
EOF

reset() {
    rm -rf "$STATE" "$ROOT"
    mkdir -p "$STATE" "$ROOT/sys/fs/selinux" "$ROOT/usr/local/lib/monad"
    echo 1 >"$ROOT/sys/fs/selinux/enforce"
    echo "(allow a b (c (d)))" >"$ROOT/usr/local/lib/monad/monad.cil"
    : >"$STATE/log"
}
run() {
    out=$(PATH="$BIN:$PATH" FAKE_STATE="$STATE" MONAD_ROOT="$ROOT" $SH "$SCRIPT" 2>&1)
    st=$?
    log=$(cat "$STATE/log")
}

echo "monad-selinux tests ($SH)" >&2

# SELinux on, module new: loaded, remembered, agent socket not touched
# while it is not enabled (first boot: cloud-init enables it after).
reset
run
check "new: status" 0 "$st"
check "new: loaded" "semodule -l
semodule -i $ROOT/usr/local/lib/monad/monad.cil
systemctl is-enabled -q monad-agent.socket" "$log"
check "new: remembered" "$(cat "$ROOT/usr/local/lib/monad/monad.cil")" "$(cat "$ROOT/var/lib/monad/monad.cil.loaded")"
check "new: says so" "monad-selinux: loaded Monad's SELinux module" "$out"

# Loaded and unchanged: nothing to do (semodule -i takes seconds).
: >"$STATE/log"
run
check "same: only a look" "semodule -l" "$log"

# Changed: loaded again, and an enabled agent socket starts over.
echo "(allow a b (c (e)))" >"$ROOT/usr/local/lib/monad/monad.cil"
touch "$STATE/agent-enabled"
: >"$STATE/log"
run
check "changed: loaded, agent restarted" "semodule -l
semodule -i $ROOT/usr/local/lib/monad/monad.cil
systemctl is-enabled -q monad-agent.socket
systemctl reset-failed monad-agent.socket
systemctl restart monad-agent.socket" "$log"

# Removed by someone (semodule -r): loaded again.
: >"$STATE/modules"
: >"$STATE/log"
run
check "gone: loaded again" "semodule -i $ROOT/usr/local/lib/monad/monad.cil" "$(grep -- '-i' "$STATE/log")"

# A module the policy refuses: said, not remembered, the boot goes on.
reset
FAKE_SEMODULE_FAILS=1 run
check "refused: status" 0 "$st"
check "refused: says so" "monad-selinux: Monad's SELinux module was not loaded: semodule: bad rule" "$out"
check "refused: not remembered" "no" "$([ -e "$ROOT/var/lib/monad/monad.cil.loaded" ] && echo yes || echo no)"

# No SELinux, or no semodule: nothing.
reset
rm -r "$ROOT/sys/fs/selinux"
run
check "no selinux" "" "$log"
reset
rm "$BIN/semodule"
run
check "no semodule: status" 0 "$st"
check "no semodule" "" "$log"

printf '%d checks, %d failures\n' "$checks" "$failures" >&2
[ "$failures" -eq 0 ]
