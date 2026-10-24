#!/bin/sh
# monad-agent (macOS guests, Phase 14) — Monad's in-guest control channel.
#
# Started by monad-guestd for each connection the HOST opens to vsock port
# 1024; the guest never initiates connections. The same protocol as the
# Linux agent (monad-agent.sh):
#   hello        -> "hello monad-agent 1"
#   ports        -> "port tcp <addr> <port>" per listening TCP socket, then "end"
#   watch-ports  -> "mode polling", "port+ …" for current listeners, then
#                   "port+ …"/"port- …" as sockets open and close, plus a
#                   periodic "ping" (runs until the host disconnects), and
#                   "prompt password" when a password prompt comes on screen
#                   (macOS's SecurityAgent, the lock screen, the login window
#                   once it stays), for auto-fill
#   quit         -> close the connection
#   anything else-> "error unknown-command"
# macOS has no tracepoint for listening sockets: netstat, once a second.
set -u
LC_ALL=C
export LC_ALL

NETSTAT=${MONAD_NETSTAT:-/usr/sbin/netstat -anv -p tcp}
PROMPTS=${MONAD_PROMPTS:-prompts_on_screen}
# The login window counts once seen this many times in a row: logging in by
# itself shows it for a moment.
LOGIN_LOOKS=${MONAD_LOGIN_LOOKS:-5}
INTERVAL=${MONAD_AGENT_INTERVAL:-1}
KEEPALIVE=${MONAD_AGENT_KEEPALIVE:-10}
MAX_LINE=1024

trap 'exit 0' INT TERM HUP PIPE

# Listening TCP sockets as sorted, unique "port tcp ADDR PORT" lines.
# netstat writes "addr.port"; "*" is any address (IPv4 for tcp4, else IPv6).
listening() {
    $NETSTAT 2>/dev/null | awk '
        $1 ~ /^tcp/ && $6 == "LISTEN" {
            local = $4
            n = split(local, part, ".")
            port = part[n]
            if (port !~ /^[0-9]+$/ || port + 0 <= 0 || port + 0 > 65535) next
            addr = substr(local, 1, length(local) - length(port) - 1)
            sub(/%.*/, "", addr)
            if (addr == "*") addr = ($1 == "tcp4") ? "0.0.0.0" : "::"
            print "port tcp " addr " " (port + 0)
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

# The password prompts on screen now, one line each: "agent PID" for a
# SecurityAgent dialog, "locked" for the lock screen, "login" for the login
# window (nobody logged in on the console).
prompts_on_screen() {
    pgrep -x SecurityAgent 2>/dev/null | sed 's/^/agent /'
    /usr/sbin/ioreg -n Root -d1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes' && echo locked
    [ "$(stat -f%Su /dev/console 2>/dev/null)" = root ] && pgrep -x loginwindow >/dev/null 2>&1 && echo login
}

# "prompt password" for each prompt not on screen at the last look (all of
# them at the first: the host just connected).
login_looks=0
emit_prompts() {
    now_prompts=$($PROMPTS 2>/dev/null | sort -u)
    if printf '%s\n' "$now_prompts" | grep -qx login; then
        login_looks=$((login_looks + 1))
        [ "$login_looks" -ge "$LOGIN_LOOKS" ] || now_prompts=$(printf '%s\n' "$now_prompts" | grep -vx login)
    else
        login_looks=0
    fi
    PREV=$prev_prompts CUR=$now_prompts awk 'BEGIN {
        n = split(ENVIRON["PREV"], p, "\n")
        for (i = 1; i <= n; i++) if (p[i] != "") was[p[i]] = 1
        n = split(ENVIRON["CUR"], c, "\n")
        for (i = 1; i <= n; i++) if (c[i] != "" && !(c[i] in was)) print "prompt password"
    }' || return 1
    prev_prompts=$now_prompts
}

watch_ports() {
    prev=""
    prev_prompts=""
    ticks=0
    echo "mode polling" || exit 0
    while :; do
        emit_changes || exit 0
        emit_prompts || exit 0
        ticks=$((ticks + 1))
        if [ "$ticks" -ge "$KEEPALIVE" ]; then
            ticks=0
            echo "ping" 2>/dev/null || exit 0
        fi
        sleep "$INTERVAL" || exit 0
    done
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
