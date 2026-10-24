#!/bin/sh
# Tests for the guest agent (Monad/Guest/monad-agent.sh) against fake /proc.
# Usage: test_agent.sh [workdir]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/../Monad/Guest/monad-agent.sh"
SH=${AGENT_SHELL:-sh}   # dash on Debian/Ubuntu, bash on Fedora/openSUSE
WORK=${1:-$(mktemp -d)}
mkdir -p "$WORK"
checks=0
failures=0

# Kills and counts processes whose environment mentions $1 (a private path
# every agent of one scenario gets). Linux only; prints 0 elsewhere.
reap_agents() {
    n=0
    if [ -d /proc/self ]; then
        for p in /proc/[0-9]*; do
            if grep -qs "$1" "$p/environ" 2>/dev/null; then
                n=$((n + 1))
                kill -9 "${p#/proc/}" 2>/dev/null
            fi
        done
    fi
    echo "$n"
}

check() { # check NAME EXPECTED ACTUAL
    checks=$((checks + 1))
    if [ "$2" != "$3" ]; then
        failures=$((failures + 1))
        printf '%s: FAIL\n--- expected\n%s\n--- got\n%s\n' "$1" "$2" "$3" >&2
    fi
}

run_agent() { # stdin → agent with fixture proc root
    MONAD_PROC="$1" MONAD_TRACEFS=/nonexistent MONAD_AGENT_INTERVAL="${2:-1}" $SH "$AGENT"
}

echo "monad-agent tests ($SH)" >&2
PROC="$WORK/proc"
rm -rf "$PROC"
cp -R "$HERE/agent_fixtures/base" "$PROC"

# hello / unknown command / quit
out=$(printf 'hello\nfrobnicate\nquit\nhello\n' | run_agent "$PROC")
check "hello+unknown+quit" "hello monad-agent 1
error unknown-command" "$out"

# snapshot: listening sockets only, sorted (C locale), IPv4 and IPv6 decoded
out=$(printf 'ports\n' | run_agent "$PROC")
check "ports snapshot" "port tcp 0.0.0.0 22
port tcp 0.0.0.0 8080
port tcp 127.0.0.1 5432
port tcp 127.0.0.53 53
port tcp 2001:db8:0:0:0:0:0:1 8081
port tcp :: 3000
port tcp ::1 9229
end" "$out"

# empty or missing tables
EMPTY="$WORK/empty"
mkdir -p "$EMPTY/net"
head -1 "$PROC/net/tcp" > "$EMPTY/net/tcp"
out=$(printf 'ports\n' | run_agent "$EMPTY")
check "no listeners" "end" "$out"

# watch-ports: initial state as port+, then diffs as sockets open and close.
# The agent is started directly (not via a function) so $! is its pid.
EVENTS="$WORK/events"
rm -f "$EVENTS"
( printf 'watch-ports\n'; sleep 3 ) |
    MONAD_PROC="$PROC" MONAD_TRACEFS=/nonexistent MONAD_AGENT_INTERVAL=0.2 MONAD_AGENT_KEEPALIVE=2 $SH "$AGENT" > "$EVENTS" &
AGENT_PID=$!
sleep 0.8
# close 8080, open 3001 (0BB9)
grep -v ':1F90 00000000:0000 0A' "$HERE/agent_fixtures/base/net/tcp" > "$PROC/net/tcp.new"
echo '   9: 00000000:0BB9 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1009 1 0000000000000000 100 0 0 10 0' >> "$PROC/net/tcp.new"
mv "$PROC/net/tcp.new" "$PROC/net/tcp"
sleep 1
kill "$AGENT_PID" 2>/dev/null
wait "$AGENT_PID" 2>/dev/null
initial=$(grep -c '^port+ ' "$EVENTS")
check "watch initial count" "8" "$initial"
check "watch close event" "port- tcp 0.0.0.0 8080" "$(grep '^port- ' "$EVENTS")"
check "watch open event" "port+ tcp 0.0.0.0 3001" "$(grep '^port+ tcp 0.0.0.0 3001' "$EVENTS")"
check "watch no duplicates" "" "$(grep '^port' "$EVENTS" | sort | uniq -d)"
check "keepalive sent" "yes" "$(grep -q '^ping$' "$EVENTS" && echo yes)"
check "announces polling fallback" "mode polling" "$(grep '^mode ' "$EVENTS")"
check "agent stops on TERM" "gone" "$(kill -0 "$AGENT_PID" 2>/dev/null && echo alive || echo gone)"

# Host disconnect: once nobody reads the output, the agent must exit by itself.
cp -R "$HERE/agent_fixtures/base/." "$PROC/"
FIFO="$WORK/fifo"
rm -f "$FIFO"
mkfifo "$FIFO"
( printf 'watch-ports\n'; sleep 10 ) |
    MONAD_PROC="$PROC" MONAD_TRACEFS=/nonexistent MONAD_AGENT_INTERVAL=0.2 MONAD_AGENT_KEEPALIVE=2 $SH "$AGENT" > "$FIFO" &
DISCONNECT_PID=$!
head -n 1 < "$FIFO" > /dev/null   # read one line, then hang up
sleep 2.5
check "agent exits after disconnect" "gone" "$(kill -0 "$DISCONNECT_PID" 2>/dev/null && echo alive || echo gone)"
kill -9 "$DISCONNECT_PID" 2>/dev/null

# Reactive mode: kernel socket events (tracefs) trigger an immediate resync.
# A fake tracefs whose trace_pipe is a FIFO the test writes to; polling is
# set to 100 s so only the event can explain a fast reaction.
TRACEFS="$WORK/tracefs"
INST="$TRACEFS/instances/monad-test"
rm -rf "$TRACEFS"
mkdir -p "$INST/events/sock/inet_sock_set_state"
mkfifo "$INST/trace_pipe"
cp -R "$HERE/agent_fixtures/base/." "$PROC/"
REACT="$WORK/react"
rm -f "$REACT"
( printf 'watch-ports\n'; sleep 6 ) |
    MONAD_PROC="$PROC" MONAD_TRACEFS="$TRACEFS" MONAD_TRACE_INSTANCE=monad-test \
    MONAD_AGENT_INTERVAL=100 MONAD_AGENT_TICK=100 $SH "$AGENT" > "$REACT" &
REACT_PID=$!
exec 3<> "$INST/trace_pipe"         # the kernel side of the pipe (read-write: never blocks)
sleep 0.5
check "tracepoint filter set" "newstate == 10 || oldstate == 10" "$(cat "$INST/events/sock/inet_sock_set_state/filter" 2>/dev/null)"
check "tracepoint enabled" "1" "$(cat "$INST/events/sock/inet_sock_set_state/enable" 2>/dev/null)"
check "initial listeners (reactive)" "7" "$(grep -c '^port+ ' "$REACT")"
check "announces event mode" "mode events" "$(grep '^mode ' "$REACT")"
echo '   9: 00000000:1F92 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1009 1 0000000000000000 100 0 0 10 0' >> "$PROC/net/tcp"
echo "python3-1 [001] ..... 1.0: inet_sock_set_state: family=AF_INET protocol=IPPROTO_TCP sport=8082 dport=0 oldstate=TCP_CLOSE newstate=TCP_LISTEN" >&3
sleep 0.5
check "event-driven open" "port+ tcp 0.0.0.0 8082" "$(grep '^port+ tcp 0.0.0.0 8082' "$REACT")"
grep -v ':1F92 ' "$PROC/net/tcp" > "$PROC/net/tcp.new" && mv "$PROC/net/tcp.new" "$PROC/net/tcp"
echo "python3-1 [001] ..... 2.0: inet_sock_set_state: family=AF_INET protocol=IPPROTO_TCP sport=8082 dport=0 oldstate=TCP_LISTEN newstate=TCP_CLOSE" >&3
sleep 0.5
check "event-driven close" "port- tcp 0.0.0.0 8082" "$(grep '^port- tcp 0.0.0.0 8082' "$REACT")"
kill "$REACT_PID" 2>/dev/null
exec 3>&-
sleep 0.5
check "tracepoint disabled on exit" "0" "$(cat "$INST/events/sock/inet_sock_set_state/enable" 2>/dev/null)"
check "reactive agent gone" "gone" "$(kill -0 "$REACT_PID" 2>/dev/null && echo alive || echo gone)"
check "reactive agent left nothing behind" "0" "$(reap_agents "$TRACEFS")"

# Reactive mode: when the host hangs up (input EOF), the agent exits and
# releases the tracepoint even if it never had anything to write.
TRACEFS2="$WORK/tracefs2"
INST2="$TRACEFS2/instances/monad-eof"
rm -rf "$TRACEFS2"
mkdir -p "$INST2/events/sock/inet_sock_set_state"
mkfifo "$INST2/trace_pipe"
exec 4<> "$INST2/trace_pipe"
( printf 'watch-ports\n'; sleep 1 ) |
    MONAD_PROC="$PROC" MONAD_TRACEFS="$TRACEFS2" MONAD_TRACE_INSTANCE=monad-eof \
    MONAD_AGENT_INTERVAL=100 MONAD_AGENT_TICK=100 $SH "$AGENT" > /dev/null &
EOF_PID=$!
sleep 2.5
check "exits on host hang-up" "gone" "$(kill -0 "$EOF_PID" 2>/dev/null && echo alive || echo gone)"
check "tracepoint released on hang-up" "0" "$(cat "$INST2/events/sock/inet_sock_set_state/enable" 2>/dev/null)"
kill -9 "$EOF_PID" 2>/dev/null
exec 4>&-

# Reactive mode stopped over and over (the host disconnecting): the agent
# always exits, nothing it started survives it (no subshell, no sleep), and
# stopping neither spins nor writes anything.
if [ -d /proc/self ]; then
    TRACEFS3="$WORK/tracefs3"
    INST3="$TRACEFS3/instances/monad-stop"
    rm -rf "$TRACEFS3"
    mkdir -p "$INST3/events/sock/inet_sock_set_state"
    mkfifo "$INST3/trace_pipe"
    exec 5<> "$INST3/trace_pipe"
    STOPERR="$WORK/stop-stderr"
    : > "$STOPERR"
    stuck=0
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        ( printf 'watch-ports\n'; sleep 5 ) |
            MONAD_PROC="$PROC" MONAD_TRACEFS="$TRACEFS3" MONAD_TRACE_INSTANCE=monad-stop \
            MONAD_AGENT_INTERVAL=100 MONAD_AGENT_TICK=100 $SH "$AGENT" > /dev/null 2>> "$STOPERR" &
        pid=$!
        sleep 0.3
        kill "$pid" 2>/dev/null
        # Teardown retries rmdir for up to 0.25 s (the fake instance never
        # goes away); an agent that spins never exits at all.
        tries=0
        while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 20 ]; do
            sleep 0.1
            tries=$((tries + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then stuck=$((stuck + 1)); fi
    done
    exec 5>&-
    sleep 0.3
    check "reactive stop x12: the agent always exits (within 2 s)" "0" "$stuck"
    check "reactive stop x12: nothing left behind" "0" "$(reap_agents "$TRACEFS3")"
    check "reactive stop x12: nothing on stderr" "0" "$(wc -c < "$STOPERR" | tr -d ' ')"
fi

# oversized / hostile input lines are rejected without echoing them back
long=$(awk 'BEGIN { while (i++ < 5000) printf "A" }')
out=$(printf '%s\nhello\n' "$long" | run_agent "$PROC")
check "oversized line" "error line-too-long
hello monad-agent 1" "$out"
out=$(printf 'ports; rm -rf /\n' | run_agent "$PROC")
check "no command injection" "error unknown-command" "$out"

printf '%d checks, %d failures\n' "$checks" "$failures" >&2
[ "$failures" -eq 0 ]
