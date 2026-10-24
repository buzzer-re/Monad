#!/bin/sh
# Tests for the macOS guest agent (Monad/Guest/monad-agent-macos.sh, Phase 14)
# against canned netstat output: the same protocol as the Linux agent.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/../Monad/Guest/monad-agent-macos.sh"
SH=${AGENT_SHELL:-sh}
WORK=${1:-$(mktemp -d)}
mkdir -p "$WORK"
checks=0
failures=0

check() { # check NAME EXPECTED ACTUAL
    checks=$((checks + 1))
    if [ "$2" != "$3" ]; then
        failures=$((failures + 1))
        printf '%s: FAIL\n--- expected\n%s\n--- got\n%s\n' "$1" "$2" "$3" >&2
    fi
}

run_agent() { # stdin → agent reading netstat output from file $1
    MONAD_NETSTAT="cat $1" MONAD_AGENT_INTERVAL="${2:-1}" $SH "$AGENT"
}

echo "monad-agent-macos tests ($SH)" >&2

check hello "hello monad-agent 1" "$(echo hello | run_agent /dev/null)"

expected="port tcp 0.0.0.0 3000
port tcp 127.0.0.1 631
port tcp :: 8080
port tcp ::1 631
port tcp fe80::1 5432
end"
check ports "$expected" "$(echo ports | run_agent "$HERE/agent_fixtures/netstat_macos.txt")"

check unknown "error unknown-command" "$(echo format-disk | run_agent /dev/null)"
long=$(awk 'BEGIN { for (i = 0; i < 1100; i++) printf "x" }')
check long-line "error line-too-long" "$(echo "$long" | run_agent /dev/null)"

# watch-ports: polling, current listeners as port+, then changes as they come.
# It watches until the host goes; here, until the agent is stopped.
cp /dev/null "$WORK/netstat.txt"
echo watch-ports | MONAD_NETSTAT="cat $WORK/netstat.txt" MONAD_AGENT_INTERVAL=1 $SH "$AGENT" > "$WORK/watch.out" &
pid=$!
sleep 1
grep LISTEN "$HERE/agent_fixtures/netstat_macos.txt" | grep '\*\.3000' | head -1 > "$WORK/netstat.txt"
sleep 2
cp /dev/null "$WORK/netstat.txt"
sleep 2
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
check watch-mode "mode polling" "$(head -1 "$WORK/watch.out")"
check watch-opened "port+ tcp 0.0.0.0 3000" "$(grep '^port+' "$WORK/watch.out")"
check watch-closed "port- tcp 0.0.0.0 3000" "$(grep '^port-' "$WORK/watch.out")"

# Password prompts on screen (macOS's SecurityAgent, the lock screen): each
# new one is said once, while ports are watched, for Monad's auto-fill.
cp /dev/null "$WORK/netstat.txt"
cp /dev/null "$WORK/prompts.txt"
echo watch-ports | MONAD_NETSTAT="cat $WORK/netstat.txt" MONAD_PROMPTS="cat $WORK/prompts.txt" MONAD_AGENT_INTERVAL=1 \
    $SH "$AGENT" > "$WORK/prompts.out" &
pid=$!
sleep 1
echo "agent 321" > "$WORK/prompts.txt"
sleep 2
printf 'agent 321\nlocked\n' > "$WORK/prompts.txt"
sleep 2
cp /dev/null "$WORK/prompts.txt"
sleep 2
echo "agent 654" > "$WORK/prompts.txt"
sleep 2
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
check prompts "3" "$(grep -c '^prompt password$' "$WORK/prompts.out")"

# A prompt already on screen when the host connects is said at once.
echo "agent 777" > "$WORK/prompts-now.txt"
echo watch-ports | MONAD_NETSTAT="cat /dev/null" MONAD_PROMPTS="cat $WORK/prompts-now.txt" MONAD_AGENT_INTERVAL=1 \
    $SH "$AGENT" > "$WORK/prompts-now.out" &
pid=$!
sleep 2
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
check prompt-at-connect "1" "$(grep -c '^prompt password$' "$WORK/prompts-now.out")"

# The login window counts only once it has stayed (logging in by itself
# shows it for a moment): here 3 looks in a row.
cp /dev/null "$WORK/login.txt"
echo watch-ports | MONAD_NETSTAT="cat /dev/null" MONAD_PROMPTS="cat $WORK/login.txt" MONAD_LOGIN_LOOKS=3 \
    MONAD_AGENT_INTERVAL=1 $SH "$AGENT" > "$WORK/login.out" &
pid=$!
sleep 1
echo login > "$WORK/login.txt"
sleep 1
cp /dev/null "$WORK/login.txt"
sleep 2
check login-briefly "0" "$(grep -c '^prompt password$' "$WORK/login.out")"
echo login > "$WORK/login.txt"
sleep 5
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
check login-stays "1" "$(grep -c '^prompt password$' "$WORK/login.out")"

echo "$checks checks, $failures failures" >&2
[ "$failures" -eq 0 ]
