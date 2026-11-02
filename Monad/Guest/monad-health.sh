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
#         procs=N dstate=N cpu=PCT io=PCT busy=NAME:PCT,…
#         top=NAME:RSS,… [vol=MOUNT:USED/SIZE,…] disk=MOUNT:USED/SIZE,…
#                                               every INTERVAL seconds (KB;
#                                               CPU since the last one, 100
#                                               is one core)
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
# The last snapshot's CPU counters, to say what the CPU did since
# (monad-health.service's RuntimeDirectory).
STATE=${MONAD_HEALTH_STATE:-${RUNTIME_DIRECTORY:-/run/monad-health}}
TICK=${MONAD_CLK_TCK:-$(getconf CLK_TCK 2>/dev/null || echo 100)}
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

# mawk (Debian's, Ubuntu's awk) reads a pipe in blocks unless told not to.
INTERACTIVE=
if awk -W version 2>/dev/null | grep -q mawk; then INTERACTIVE="-W interactive"; fi

# The one writer: each line on stdin, bounded and plain, to stdout and the
# port, flushed at once. One process only, holding the port: a virtio port
# takes one opener at a time (a second one's writes fail while the first
# holds it), and a pipe through tr or sed would hold lines in its buffer
# (seen: an OOM kill that never reached the Mac while the guest still ran).
emit() {
    # shellcheck disable=SC2086
    awk $INTERACTIVE -v out="$OUT" '{
        line = $0
        gsub(/[[:cntrl:]]/, "", line)
        line = substr("MONAD-H| " line, 1, 300)
        print line
        fflush()
        if (out != "") { print line >> out; fflush(out) }
    }'
}

# Free and total KB of a mount point; df is cut off if the mount hangs
# (a share whose Mac side went away), so a stuck share never stops the rest.
# USED/SIZE as df counts it: of what can be used (used + available), not
# the filesystem's whole size, of which ext4 keeps 5% for root.
disk() { # LABEL MOUNT
    timeout 3 df -Pk "$2" 2>/dev/null | awk -v l="$1" 'NR == 2 { printf "%s:%s/%.0f", substr(l, 1, 40), $3, $3 + $4 }'
}

# CPU since the last snapshot: the guest's (busy, and waiting for disks)
# and the three processes that used the most, 100 being one core. "-" the
# first time: nothing to compare with.
cpu() {
    mkdir -p "$STATE" 2>/dev/null
    now=$(awk '{ print $1 }' "$PROC/uptime" 2>/dev/null)
    { echo "up $now"
      awk '$1 == "cpu" { print "all", $2 + $3 + $4 + $7 + $8 + $9, $6 }' "$PROC/stat" 2>/dev/null
      # One cat for every process (one each would cost more CPU than most
      # of what it measures); one that ends meanwhile is skipped.
      cat "$PROC"/[0-9]*/stat 2>/dev/null | awk '
          NF == 0 { next }
          {
              lp = index($0, "("); rp = 0
              for (i = length($0); i > 0; i--) if (substr($0, i, 1) == ")") { rp = i; break }
              if (lp == 0 || rp == 0) next
              name = substr($0, lp + 1, rp - lp - 1)
              gsub(/[^A-Za-z0-9._-]/, "_", name)
              n = split(substr($0, rp + 2), f, " ")
              if (n >= 13) print "p", $1, f[12] + f[13], substr(name, 1, 24)
          }'
    } >"$STATE/cpu.new" 2>/dev/null || { echo "cpu=- io=- busy="; return; }
    if [ -r "$STATE/cpu.last" ]; then
        awk -v tick="$TICK" '
            FNR == NR { if ($1 == "up") up0 = $2; else if ($1 == "all") { b0 = $2; w0 = $3 } else p0[$2] = $3; next }
            $1 == "up" { dt = $2 - up0 }
            $1 == "all" { b = $2 - b0; w = $3 - w0 }
            $1 == "p" { d = $3 - ($2 in p0 ? p0[$2] : 0); if (d > 0) print "p", d, $4 }
            END {
                if (dt <= 0) { print "cpu=- io=-"; exit }
                printf "cpu=%d io=%d\n", b * 100 / tick / dt + 0.5, w * 100 / tick / dt + 0.5
                printf "dt %s\n", dt
            }' "$STATE/cpu.last" "$STATE/cpu.new" >"$STATE/cpu.diff"
        totals=$(grep -v '^[pd]' "$STATE/cpu.diff")
        dt=$(sed -n 's/^dt //p' "$STATE/cpu.diff")
        busy=$(grep '^p ' "$STATE/cpu.diff" | sort -k2 -rn | head -3 | awk -v tick="$TICK" -v dt="${dt:-0}" '
            dt > 0 { printf "%s%s:%d", (NR > 1 ? "," : ""), $3, $2 * 100 / tick / dt + 0.5 }')
        echo "$totals busy=$busy"
    else
        echo "cpu=- io=- busy="
    fi
    mv -f "$STATE/cpu.new" "$STATE/cpu.last"
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
    top=$(cat "$PROC"/[0-9]*/status 2>/dev/null | awk '
        /^Name:/ { sub(/^Name:[ \t]*/, ""); gsub(/[^A-Za-z0-9._-]/, "_"); n = substr($0, 1, 24) }
        /^VmRSS:/ { if (n != "") print $2, n; n = "" }' | sort -rn | head -3 | awk '{ printf "%s%s:%s", (NR > 1 ? "," : ""), $2, $1 }')
    # The disks added in the VM's settings: a virtio disk at /mnt/<name>.
    vols=""
    for v in $(awk '$1 ~ /^\/dev\/vd/ && $2 ~ /^\/mnt\/[a-z][a-z0-9-]*$/ { print $2 }' "$PROC/mounts" 2>/dev/null); do
        d=$(disk "$v" "$v")
        [ -n "$d" ] && vols="${vols:+$vols,}$d"
    done
    used=$(cpu)
    # Disks last: a line too long loses the end of the shares, nothing else.
    echo "snap up=${up:-0} $m psi=${psi:--} $load dstate=$dstate $used top=$top ${vols:+vol=$vols }disk=$disks"
}

# /dev/kmsg records ("PRIO,SEQ,USEC,FLAGS;TEXT", continuation lines start
# with a space) to kern lines: errors and worse, what speaks of memory,
# crashes, hangs or I/O at any level, and the filesystems' warnings (not
# their notices: every boot mounts something).
kernel() {
    # shellcheck disable=SC2086
    awk $INTERACTIVE -v burst="$KERN_BURST" '
        function say(line) { print line; fflush() }
        /^ / { next }
        {
            semi = index($0, ";"); if (semi == 0) next
            split(substr($0, 1, semi - 1), h, ",")
            prio = h[1] % 8; usec = h[3] + 0
            text = substr($0, semi + 1)
            # A crash report: the faulting address, then (abort details
            # left out) who crashed, where, and its call trace, at most 30
            # lines; the register dump is left out.
            if (text ~ /Unable to handle kernel/) { abort = 1; trace = 0 }
            else if (abort && text !~ /Internal error/) next
            if (text ~ /Internal error|BUG:|WARNING:|general protection|Kernel panic/) { abort = 0; trace = 1; traced = 0 }
            if (trace && text ~ /^CPU: |^pc : |^lr : |^Call trace:|^ +[A-Za-z0-9_.]+\+0x|^Code: |^---\[ end trace/) {
                if (text ~ /^---\[ end trace/) trace = 0
                if (++traced > 30) next
                keep = 1
            } else {
                keep = prio <= 3
                if (prio <= 4 && text ~ /EXT4-fs|XFS|BTRFS|virtiofs|fuse:/) keep = 1
                if (text ~ /segfault|traps:|Unable to handle|Internal error|Out of memory|oom-kill|oom_reaper|Killed process|invoked oom-killer|soft lockup|hard LOCKUP|blocked for more than|hung_task|I\/O error|Bus error|BUG:|Oops|panic|apparmor="STATUS"/) keep = 1
            }
            if (!keep) next
            window = int(usec / 10000000)
            if (window != last) {
                if (dropped) say("kern dropped " dropped)
                last = window; sent = 0; dropped = 0
            }
            if (sent >= burst) { dropped++; next }
            sent++
            say("kern " prio " " text)
        }
        END { if (dropped) say("kern dropped " dropped) }'
}

run() {
    kb=$(awk '/^MemTotal:/ { print $2 }' "$PROC/meminfo" 2>/dev/null)
    cpus=$(grep -c '^processor' "$PROC/cpuinfo" 2>/dev/null)
    echo "boot id=$(cat "$PROC/sys/kernel/random/boot_id" 2>/dev/null) kernel=$(uname -r) cpus=${cpus:-0} mem=${kb:-0}"
    # From the start of the kernel's buffer: an early boot's trouble too.
    kernel <"$KMSG" &
    reader=$!
    trap 'kill "$reader" 2>/dev/null; exit 0' INT TERM HUP
    while :; do
        snapshot
        sleep "$INTERVAL" &
        wait $! || true
    done
}

case "${1:-}" in
    snapshot) snapshot | emit ;;
    port) port ;;
    kernel) kernel | emit ;;
    run)
        # No port: not Monad's boot (Lima boots the same disk). Nothing to do.
        [ -n "$OUT" ] || exit 0
        # Both the kernel's lines and the snapshots, through the one writer
        # (lines this short go through a pipe whole, never mixed).
        run | emit
        ;;
    *)
        echo "usage: monad-health run | snapshot | kernel" >&2
        exit 2
        ;;
esac
