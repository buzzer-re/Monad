#!/bin/sh
# monad-health.sh — what a Linux guest tells Monad about its own health,
# without ssh: a guest out of memory, its disk full or its kernel in
# trouble is exactly when ssh stops answering, and then nothing is left to
# say why (a VM that "segfaults on every command" and times out, 2026-11).
#
# It writes to the VM's health port, a virtio console port Monad names
# dev.monad.health and logs on the Mac (health.log next to serial.log), so
# whatever it said before a freeze or a crash is still there after. Every
# line starts with "MONAD-H| ", is plain text and at most 300 bytes:
#
#   boot  id=… kernel=… cpus=N mem=KB           once, at start
#   snap  up=S mem=AVAIL/TOTAL swap=FREE/TOTAL psi=SOME,FULL load=L
#         procs=N dstate=N top=NAME:RSS,… disk=MOUNT:USED/SIZE,…
#                                               every INTERVAL seconds (KB)
#   kern  PRIO TEXT                             a kernel message about
#                                               memory, crashes, hangs or I/O
#   kern  dropped N                             the ones over the limit
#
#   monad-health run        all of it, until stopped (monad-health.service)
#   monad-health snapshot   one snap line
#   monad-health kernel     kern lines for the /dev/kmsg records on stdin
#   monad-health port       the health port's device, if there is one
#
# It only reads. MONAD_PROC, MONAD_SYS, MONAD_KMSG, MONAD_HEALTH_OUT and
# MONAD_HEALTH_INTERVAL exist for its tests (CTests/test_health.sh).

set -u
LC_ALL=C
export LC_ALL
PROC=${MONAD_PROC:-/proc}
SYS=${MONAD_SYS:-/sys}
KMSG=${MONAD_KMSG:-/dev/kmsg}
INTERVAL=${MONAD_HEALTH_INTERVAL:-15}
PORT_NAME=dev.monad.health
# Kernel lines kept per 10 s of kernel time; a storm is counted, not sent.
KERN_BURST=20

# The health port's device, or nothing (an older Monad, or Lima booting
# the same disk).
port() {
    for n in "$SYS"/class/virtio-ports/*/name; do
        [ -r "$n" ] || continue
        if [ "$(cat "$n" 2>/dev/null)" = "$PORT_NAME" ]; then
            d=${n%/name}
            echo "/dev/${d##*/}"
            return
        fi
    done
}

OUT=${MONAD_HEALTH_OUT:-$(port)}

# Each line on stdin, bounded and plain, to stdout and the port.
emit() {
    tr -d '\000-\011\013-\037\177' | sed 's/^/MONAD-H| /' | cut -c1-300 | while IFS= read -r line; do
        printf '%s\n' "$line"
        if [ -n "$OUT" ]; then { printf '%s\n' "$line" >>"$OUT"; } 2>/dev/null || true; fi
    done
}

# Free and total KB of a mount point; df is cut off if the mount hangs
# (a share whose Mac side went away), so a stuck share never stops the rest.
disk() { # LABEL MOUNT
    timeout 3 df -Pk "$2" 2>/dev/null | awk -v l="$1" 'NR == 2 { printf "%s:%s/%s", substr(l, 1, 40), $3, $2 }'
}

snapshot() {
    m=$(awk '
        /^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
        /^SwapTotal:/ { st = $2 } /^SwapFree:/ { sf = $2 }
        END { printf "mem=%d/%d swap=%d/%d", a, t, sf, st }' "$PROC/meminfo" 2>/dev/null)
    psi=$(awk '{ split($2, v, "="); x[$1] = v[2] } END { if ("some" in x) printf "%s,%s", x["some"], x["full"]; else printf "-" }' \
        "$PROC/pressure/memory" 2>/dev/null)
    up=$(awk '{ printf "%d", $1 }' "$PROC/uptime" 2>/dev/null)
    load=$(awk '{ split($4, p, "/"); printf "load=%s procs=%s", $1, p[2] }' "$PROC/loadavg" 2>/dev/null)
    dstate=$(cat "$PROC"/[0-9]*/stat 2>/dev/null | awk '{ sub(/^.*\) /, ""); if ($1 == "D") n++ } END { printf "%d", n }')
    disks=$(disk / /)
    # Each share once: its first mount (the others are folders of it
    # bound elsewhere, the same disk).
    shares=$(awk '$3 == "virtiofs" && $2 !~ /\\/ && !seen[$1]++ { print $2 }' "$PROC/mounts" 2>/dev/null)
    for s in $shares; do
        d=$(disk "$s" "$s")
        [ -n "$d" ] && disks="$disks,$d"
    done
    top=$(for f in "$PROC"/[0-9]*/status; do cat "$f" 2>/dev/null; echo; done | awk '
        /^Name:/ { sub(/^Name:[ \t]*/, ""); gsub(/[^A-Za-z0-9._-]/, "_"); n = substr($0, 1, 24) }
        /^VmRSS:/ { if (n != "") print $2, n }
        /^$/ { n = "" }' | sort -rn | head -3 | awk '{ printf "%s%s:%s", (NR > 1 ? "," : ""), $2, $1 }')
    # Disks last: a line too long loses the end of the shares, nothing else.
    echo "snap up=${up:-0} $m psi=${psi:--} $load dstate=$dstate top=$top disk=$disks" | emit
}

# /dev/kmsg records ("PRIO,SEQ,USEC,FLAGS;TEXT", continuation lines start
# with a space) to kern lines: errors and worse, what speaks of memory,
# crashes, hangs or I/O at any level, and the filesystems' warnings (not
# their notices: every boot mounts something).
kernel() {
    awk -v burst="$KERN_BURST" '
        /^ / { next }
        {
            semi = index($0, ";"); if (semi == 0) next
            split(substr($0, 1, semi - 1), h, ",")
            prio = h[1] % 8; usec = h[3] + 0
            text = substr($0, semi + 1)
            keep = prio <= 3
            if (prio <= 4 && text ~ /EXT4-fs|XFS|BTRFS|virtiofs|fuse:/) keep = 1
            if (text ~ /segfault|traps:|Unable to handle|Internal error|Out of memory|oom-kill|oom_reaper|Killed process|invoked oom-killer|soft lockup|hard LOCKUP|blocked for more than|hung_task|I\/O error|Bus error|BUG:|Oops|panic/) keep = 1
            if (!keep) next
            window = int(usec / 10000000)
            if (window != last) {
                if (dropped) printf "kern dropped %d\n", dropped
                last = window; sent = 0; dropped = 0
            }
            if (sent >= burst) { dropped++; next }
            sent++
            printf "kern %d %s\n", prio, text
            fflush()
        }
        END { if (dropped) printf "kern dropped %d\n", dropped }' | emit
}

case "${1:-}" in
    snapshot) snapshot ;;
    port) port ;;
    kernel) kernel ;;
    run)
        # No port: not Monad's boot (Lima boots the same disk). Nothing to do.
        [ -n "$OUT" ] || exit 0
        kb=$(awk '/^MemTotal:/ { print $2 }' "$PROC/meminfo" 2>/dev/null)
        cpus=$(grep -c '^processor' "$PROC/cpuinfo" 2>/dev/null)
        echo "boot id=$(cat "$PROC/sys/kernel/random/boot_id" 2>/dev/null) kernel=$(uname -r) cpus=${cpus:-0} mem=${kb:-0}" | emit
        # From the start of the kernel's buffer: an early boot's trouble too.
        kernel <"$KMSG" &
        reader=$!
        trap 'kill "$reader" 2>/dev/null; exit 0' INT TERM HUP
        while :; do
            snapshot
            sleep "$INTERVAL" &
            wait $! || true
        done
        ;;
    *)
        echo "usage: monad-health run | snapshot | kernel" >&2
        exit 2
        ;;
esac
