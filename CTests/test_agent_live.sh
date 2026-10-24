#!/bin/sh
# Live test of monad-agent's event-driven mode against the REAL kernel
# tracepoint, run as root with no capabilities (like the guest service).
# Needs Linux, tracefs and passwordless sudo; skipped otherwise.
# Complements test_agent.sh, whose fake tracefs cannot reproduce kernel
# trace_pipe behaviour (e.g. splice holding events back).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/../Monad/Guest/monad-agent.sh"
if [ "$(uname -s)" != Linux ] || ! sudo -n true 2>/dev/null || ! sudo -n test -d /sys/kernel/tracing/events/sock; then
    echo "monad-agent live test: skipped (needs Linux, tracefs and sudo)" >&2
    exit 0
fi
command -v setpriv >/dev/null && command -v python3 >/dev/null || { echo "live test: skipped (setpriv/python3)" >&2; exit 0; }

WORK=$(mktemp -d /tmp/monad-live.XXXXXX)
chmod 755 "$WORK"
cp "$AGENT" "$WORK/agent.sh"
chmod 755 "$WORK/agent.sh"
OUT="$WORK/out"
: > "$OUT"
chmod 666 "$OUT"
INSTANCE=monad-live-$$
failures=0

echo "monad-agent live test (real tracepoint, root without capabilities)" >&2
( printf 'watch-ports\n'; sleep 6 ) | sudo -n setpriv --no-new-privs \
    --securebits +noroot,+noroot_locked,+no_setuid_fixup,+no_setuid_fixup_locked \
    --bounding-set -all --inh-caps -all --ambient-caps -all \
    env MONAD_TRACE_INSTANCE=$INSTANCE MONAD_AGENT_INTERVAL=60 MONAD_AGENT_TICK=60 sh "$WORK/agent.sh" > "$OUT" &
sleep 1.5

python3 - "$OUT" <<'PY' || failures=$((failures + 1))
import socket, sys, time
out = sys.argv[1]
def wait_for(text, limit=1.0):
    t = time.monotonic()
    while time.monotonic() - t < limit:
        if text in open(out).read():
            return (time.monotonic() - t) * 1000
        time.sleep(0.001)
    return None
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 48555)); s.listen()
opened = wait_for("port+ tcp 0.0.0.0 48555")
s.close()
closed = wait_for("port- tcp 0.0.0.0 48555")
print("open -> port+: %s ms, close -> port-: %s ms" % (
    "%.1f" % opened if opened is not None else "MISSED", "%.1f" % closed if closed is not None else "MISSED"),
    file=sys.stderr)
# Reactive means well under the 60 s poll interval configured above.
sys.exit(0 if opened is not None and closed is not None and opened < 250 and closed < 250 else 1)
PY

sleep 5   # host "disconnects" when the input pipe closes
if sudo -n test -d /sys/kernel/tracing/instances/$INSTANCE; then
    echo "live: tracing instance left behind" >&2
    failures=$((failures + 1))
    sudo -n sh -c "echo 0 > /sys/kernel/tracing/instances/$INSTANCE/events/sock/inet_sock_set_state/enable; rmdir /sys/kernel/tracing/instances/$INSTANCE"
fi
rm -rf "$WORK"
echo "live: $failures failure(s)" >&2
[ "$failures" -eq 0 ]
