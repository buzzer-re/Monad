#!/bin/sh
# monad-agent — Monad's in-guest control channel.
#
# Started by systemd for each connection the HOST opens to vsock port 1024
# (monad-agent.socket, Accept=yes); the guest never initiates connections.
# POSIX sh + awk only, so it runs unchanged on every supported distro.
#
# Protocol: one command per line on stdin, replies on stdout.
#   hello        -> "hello monad-agent 1"
#   ports        -> "port tcp <addr> <port>" per listening TCP socket, then "end"
#   watch-ports  -> "mode events|polling", "port+ …" for current listeners,
#                   then "port+ …"/"port- …" as sockets open and close, plus
#                   a periodic "ping" (runs until the host disconnects)
#   quit         -> close the connection
#   anything else-> "error unknown-command"
#
# watch-ports is event driven: the kernel tracepoint sock:inet_sock_set_state
# (read through a private tracefs instance, filtered to LISTEN transitions)
# wakes the agent the moment a socket starts or stops listening. Where
# tracefs is unavailable (e.g. kernel lockdown) it falls back to polling.
set -u
LC_ALL=C
export LC_ALL

PROC=${MONAD_PROC:-/proc}
TRACEFS=${MONAD_TRACEFS:-/sys/kernel/tracing}
INSTANCE="$TRACEFS/instances/${MONAD_TRACE_INSTANCE:-monad-agent-$$}"
EVENT="$INSTANCE/events/sock/inet_sock_set_state"
INTERVAL=${MONAD_AGENT_INTERVAL:-1}   # polling fallback
TICK=${MONAD_AGENT_TICK:-10}          # keepalive + safety resync (reactive mode)
KEEPALIVE=${MONAD_AGENT_KEEPALIVE:-10} # polls per ping (polling fallback)
MAX_LINE=1024

# A closed connection or a stop request ends the agent.
trap 'exit 0' INT TERM HUP PIPE

# Listening TCP sockets as sorted, unique "port tcp ADDR PORT" lines.
listening() {
    for table in "$PROC/net/tcp" "$PROC/net/tcp6"; do
        [ -r "$table" ] && cat "$table"
    done | awk '
        function hex(s,    i, n, c) {
            n = 0
            s = toupper(s)
            for (i = 1; i <= length(s); i++) {
                c = index("0123456789ABCDEF", substr(s, i, 1)) - 1
                if (c < 0) return -1
                n = n * 16 + c
            }
            return n
        }
        # The four bytes of a little-endian 32-bit word, most significant first.
        function word(w) {
            return substr(w, 7, 2) substr(w, 5, 2) substr(w, 3, 2) substr(w, 1, 2)
        }
        function v4(a) {
            return hex(substr(a, 7, 2)) "." hex(substr(a, 5, 2)) "." hex(substr(a, 3, 2)) "." hex(substr(a, 1, 2))
        }
        function v6(a,    bytes, i, g, out, zero) {
            bytes = word(substr(a, 1, 8)) word(substr(a, 9, 8)) word(substr(a, 17, 8)) word(substr(a, 25, 8))
            out = ""
            zero = 1
            for (i = 0; i < 8; i++) {
                g[i] = hex(substr(bytes, i * 4 + 1, 4))
                if (i < 7 && g[i] != 0) zero = 0
            }
            if (zero && g[7] == 0) return "::"
            if (zero && g[7] == 1) return "::1"
            for (i = 0; i < 8; i++) out = out (i ? ":" : "") sprintf("%x", g[i])
            return out
        }
        $4 == "0A" {
            split($2, part, ":")
            addr = part[1]
            port = hex(part[2])
            if (port <= 0 || port > 65535) next
            if (length(addr) == 8) print "port tcp " v4(addr) " " port
            else if (length(addr) == 32) print "port tcp " v6(addr) " " port
        }
    ' | sort -u
}

# Print port+/port- for the difference between $prev and the current set,
# then remember the current set. Returns non-zero if stdout is gone.
emit_changes() {
    cur=$(listening)
    PREV=$prev CUR=$cur awk 'BEGIN {
        n = split(ENVIRON["CUR"], c, "\n")
        for (i = 1; i <= n; i++) if (c[i] != "") now[c[i]] = 1
        n = split(ENVIRON["PREV"], p, "\n")
        for (i = 1; i <= n; i++) if (p[i] != "") was[p[i]] = 1
        for (k in now) if (!(k in was)) { line = k; sub(/^port /, "", line); print "port+ " line }
        for (k in was) if (!(k in now)) { line = k; sub(/^port /, "", line); print "port- " line }
    }' || return 1
    prev=$cur
}

# --- event-driven mode --------------------------------------------------------

trace_setup() {
    mkdir -p "$INSTANCE" 2>/dev/null || return 1
    if [ ! -d "$EVENT" ]; then
        rmdir "$INSTANCE" 2>/dev/null
        return 1
    fi
    { echo 'newstate == 10 || oldstate == 10' > "$EVENT/filter"; } 2>/dev/null &&
        { echo 1 > "$EVENT/enable"; } 2>/dev/null && return 0
    trace_teardown
    return 1
}

trace_teardown() {
    { echo 0 > "$EVENT/enable"; } 2>/dev/null
    # The instance is busy until the last trace_pipe reader is gone; callers
    # wait for the reader first, so this retry is only a short safety net.
    tries=0
    while [ -d "$INSTANCE" ] && ! rmdir "$INSTANCE" 2>/dev/null && [ "$tries" -lt 5 ]; do
        tries=$((tries + 1))
        sleep 0.05
    done
    :
}

# Resync on every wake-up; ticks also carry the keepalive.
react_loop() {
    trap - EXIT
    prev=""
    echo "mode events" || exit 0
    emit_changes || exit 0
    while IFS= read -r line; do
        if [ "$line" = "tick" ]; then
            echo "ping" 2>/dev/null || exit 0
        fi
        emit_changes || exit 0
    done
}

# Every helper is a direct child with a known pid. Stopping never waits
# inside a trap handler: in bash that can spin forever (a subshell looping on
# "wait: pid N is not a child of this shell"), and dash can stall there. The
# trap only ends the loop; the cleanup after `wait` does the rest.
watch_reactive() {
    work=$(mktemp -d) || { trace_teardown; return 1; }
    mkfifo "$work/events" || { rm -rf "$work"; trace_teardown; return 1; }
    react_loop < "$work/events" &
    loop_pid=$!
    # Kernel events, one line each. Plain read(2) through the shell: some cat
    # implementations use splice(2), which holds tracefs events back until a
    # page fills.
    ( trap - EXIT; while IFS= read -r _; do echo event || exit 0; done < "$INSTANCE/trace_pipe" ) > "$work/events" &
    reader_pid=$!
    # Ticks: keepalive and a safety resync. The sleep is the ticker's own
    # child and goes with it, so nothing outlives the agent.
    (
        trap - EXIT
        s=""
        trap 'kill "$s" 2>/dev/null; exit 0' TERM
        while :; do
            sleep "$TICK" &
            s=$!
            wait "$s"
            echo tick || exit 0
        done
    ) > "$work/events" &
    ticker_pid=$!
    # Background jobs read /dev/null in a non-interactive shell, so hand the
    # hang-up watcher the real connection explicitly.
    exec 3<&0
    ( trap - EXIT; while IFS= read -r _; do :; done; kill -TERM $$ 2>/dev/null ) <&3 &
    hangup_pid=$!
    # A trapped signal interrupts `wait` (unlike a foreground command).
    trap 'kill "$loop_pid" 2>/dev/null' INT TERM HUP PIPE
    wait "$loop_pid"           # ends when output to the host fails, or on a stop
    trap '' INT TERM HUP PIPE  # stopping: nothing interrupts the cleanup
    kill "$loop_pid" "$reader_pid" "$ticker_pid" "$hangup_pid" 2>/dev/null
    wait "$loop_pid" "$reader_pid" "$ticker_pid" "$hangup_pid" 2>/dev/null
    rm -rf "$work"
    trace_teardown
    exit 0
}

# --- polling fallback -----------------------------------------------------------

watch_polling() {
    prev=""
    ticks=0
    echo "mode polling" || exit 0
    while :; do
        emit_changes || exit 0
        ticks=$((ticks + 1))
        if [ "$ticks" -ge "$KEEPALIVE" ]; then
            ticks=0
            echo "ping" 2>/dev/null || exit 0
        fi
        sleep "$INTERVAL" || exit 0
    done
}

watch_ports() {
    if trace_setup; then
        watch_reactive
    fi
    watch_polling
}

while IFS= read -r line; do
    if [ "${#line}" -gt "$MAX_LINE" ]; then
        echo "error line-too-long"
        continue
    fi
    case "$line" in
        hello) echo "hello monad-agent 1" ;;
        ports) listening; echo "end" ;;
        watch-ports) watch_ports ;;
        quit) exit 0 ;;
        *) echo "error unknown-command" ;;
    esac
done
