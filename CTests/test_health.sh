#!/bin/sh
# Tests for the guest's health lines (Monad/Guest/monad-health.sh): memory,
# swap, pressure, disks, the biggest processes and the kernel's trouble, as
# bounded MONAD-H| lines on the health port, against a fake /proc and /sys
# and a stand-in for df. Usage: test_health.sh [workdir]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HEALTH="$HERE/../Monad/Guest/monad-health.sh"
SH=${HEALTH_SHELL:-sh}
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
PROC="$WORK/proc"
SYS="$WORK/sys"
mkdir -p "$BIN"
# df -Pk MOUNT: $WORK/df.<mount with / as _> holds its two lines; "hang"
# sleeps past the script's timeout, as a share whose Mac side went away.
cat >"$BIN/df" <<'EOF'
#!/bin/sh
f="$FAKE_DF/df.$(printf '%s' "$2" | tr / _)"
[ -e "$f" ] || exit 1
if [ "$(cat "$f")" = hang ]; then exec sleep 30; fi
cat "$f"
EOF
chmod +x "$BIN/df"

proc_entry() { # PID NAME STATE RSS_KB [UTIME STIME] (clock ticks)
    mkdir -p "$PROC/$1"
    printf 'Name:\t%s\nState:\t%s\nVmRSS:\t   %s kB\n' "$2" "$3" "$4" >"$PROC/$1/status"
    printf '%s (%s) %s 1 1 1 0 -1 0 0 0 0 0 %s %s 0 0 20 0\n' "$1" "$2" "$3" "${5:-0}" "${6:-0}" >"$PROC/$1/stat"
}
cpu_total() { # USER SYSTEM IDLE IOWAIT (clock ticks, all CPUs)
    printf 'cpu  %s 0 %s %s %s 0 0 0 0 0\ncpu0 0 0 0 0 0 0 0 0 0 0\n' "$1" "$2" "$3" "$4" >"$PROC/stat"
}

reset() {
    rm -rf "$PROC" "$SYS" "$WORK"/df.*
    mkdir -p "$PROC/pressure" "$PROC/sys/kernel/random" "$SYS/class/virtio-ports/vport1p1"
    printf 'MemTotal:        2014312 kB\nMemFree:           51200 kB\nMemAvailable:      40960 kB\nSwapTotal:             0 kB\nSwapFree:              0 kB\n' >"$PROC/meminfo"
    printf 'some avg10=42.50 avg60=30.00 avg300=9.00 total=1\nfull avg10=31.25 avg60=20.00 avg300=5.00 total=1\n' >"$PROC/pressure/memory"
    echo '3725.43 7000.00' >"$PROC/uptime"
    echo '7.81 5.02 2.10 3/412 9999' >"$PROC/loadavg"
    printf '/dev/vda1 / ext4 rw 0 0\nshare0 /mnt/work virtiofs rw 0 0\nshare0 /home/dev/work virtiofs rw 0 0\nshare1 /mnt/my\\040files virtiofs rw 0 0\nproc /proc proc rw 0 0\n' >"$PROC/mounts"
    printf 'processor\t: 0\nprocessor\t: 1\n' >"$PROC/cpuinfo"
    cpu_total 1000 500 8000 100
    rm -rf "$WORK/state"
    echo 6f1c2a10-0000-4000-8000-000000000001 >"$PROC/sys/kernel/random/boot_id"
    proc_entry 1 systemd S 12000
    proc_entry 812 node R 1480000
    proc_entry 813 'Web Content' D 220000
    proc_entry 900 'bun' S 96000
    proc_entry 901 'kworker/u8:2' D 0
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/vda1 20511312 20100000 411312 98%% /\n' >"$WORK/df._"
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nshare0 976490576 500000000 476490576 52%% /mnt/work\n' >"$WORK/df._mnt_work"
    echo "$PORT_NAME_IN_TEST" >"$SYS/class/virtio-ports/vport1p1/name"
    : >"$WORK/port"
}
PORT_NAME_IN_TEST=dev.monad.health

run() { # run MODE (stdin as given): $out (stdout), $port (what the port got), $st
    : >"$WORK/port"
    PATH="$BIN:$PATH" FAKE_DF="$WORK" MONAD_PROC="$PROC" MONAD_SYS="$SYS" MONAD_HEALTH_OUT="$WORK/port" \
        MONAD_HEALTH_STATE="$WORK/state" MONAD_CLK_TCK=100 \
        $SH "$HEALTH" "$@" >"$WORK/stdout" 2>"$WORK/stderr"
    st=$?
    out=$(cat "$WORK/stdout")
    port=$(cat "$WORK/port")
}

echo "monad-health tests ($SH)" >&2

reset
run snapshot
check "snapshot: status" 0 "$st"
check "snapshot: the whole line (a share bound twice counted once; no CPU yet: nothing to compare with)" "MONAD-H| snap up=3725 mem=40960/2014312 swap=0/0 psi=42.50,31.25 load=7.81 procs=412 dstate=2 cpu=- io=- busy= top=node:1480000,Web_Content:220000,bun:96000 disk=/:20100000/20511312,/mnt/work:500000000/976490576" "$out"
check "snapshot: to the port too" "$out" "$port"

# CPU since the snapshot before: 100 is one core (as Activity Monitor
# counts), and the processes that used the most. 10 s later, node used
# 12 s of CPU (1200 ticks), Web Content 3 s; the guest 18 s busy, 2 s
# waiting for its disk.
reset
proc_entry 812 node R 1480000 4000 1000
proc_entry 813 'Web Content' D 220000 100 100
run snapshot
echo '3735.43 7000.00' >"$PROC/uptime"
proc_entry 812 node R 1480000 4900 1300
proc_entry 813 'Web Content' D 220000 300 200
proc_entry 950 'new one' R 1000 50 0
cpu_total 2500 800 8200 300
run snapshot
check "cpu: busy and waiting, per core" "cpu=180 io=20 busy=node:120,Web_Content:30,new_one:5" \
    "$(printf '%s\n' "$out" | sed 's/.* \(cpu=[^ ]* io=[^ ]* busy=[^ ]*\) .*/\1/')"

# A share that hangs is cut off; the rest is still said.
reset
echo hang >"$WORK/df._mnt_work"
start=$(date +%s)
run snapshot
took=$(($(date +%s) - start))
check "hung share: status" 0 "$st"
check "hung share: left out" "disk=/:20100000/20511312" "$(printf '%s\n' "$out" | sed 's/.* \(disk=[^ ]*\)$/\1/')"
check "hung share: within the timeout" yes "$([ "$took" -le 6 ] && echo yes || echo no)"

# No pressure file (an older kernel), no swap line at all.
reset
rm "$PROC/pressure/memory"
printf 'MemTotal: 1000 kB\nMemAvailable: 500 kB\n' >"$PROC/meminfo"
run snapshot
check "no psi" "psi=- mem=500/1000 swap=0/0" "$(printf '%s\n' "$out" | sed 's/.* \(mem=[^ ]*\) \(swap=[^ ]*\) \(psi=[^ ]*\).*/\3 \1 \2/')"

# Shares mounted deep in a home folder: their names are cut, so the line
# keeps its end.
reset
long=/home/dev/$(printf 'd%.0s' $(seq 1 120))
printf 'share2 %s virtiofs rw 0 0\n' "$long" >>"$PROC/mounts"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nshare2 9 1 8 1%% %s\n' "$long" >"$WORK/df.$(printf '%s' "$long" | tr / _)"
run snapshot
check "long share: cut to 40" "$(printf '%s' "$long" | cut -c1-40)" "$(printf '%s\n' "$out" | tr ',' '\n' | sed -n 's/^\(\/home\/dev\/d*\):.*/\1/p')"
check "long share: within 300" yes "$([ "$(printf '%s' "$out" | wc -c)" -le 300 ] && echo yes || echo no)"

# Kernel records: what speaks of trouble, at any level; errors and worse;
# a filesystem's own warnings, not its notices.
reset
cat >"$WORK/kmsg" <<'EOF'
6,100,1000000,-;Linux version 6.12.0 (builder)
6,101,2000000,-;ls[4242]: segfault at 0 ip 0000aaaa sp 0000ffff error 6 in libc.so.6[ffff8000+1a0000]
 SUBSYSTEM=cpu
3,102,3000000,-;Out of memory: Killed process 812 (node) total-vm:9000000kB, anon-rss:1400000kB
4,103,3100000,-;node invoked oom-killer: gfp_mask=0x140cca, order=0, oom_score_adj=0
6,104,3200000,-;usb 1-1: new device
6,1041,3200001,-;EXT4-fs (vda1): mounted filesystem 2dd1ee96 r/w with ordered data mode.
6,1042,3200002,-;virtiofs virtio4: discovered new tag: monad
5,1043,3200003,-;virtiofs virtio4: virtio_fs_setup_dax: No cache capability
6,1044,3200004,-;fuse: init (API version 7.45)
4,1045,3200005,-;EXT4-fs warning (device vda1): ext4_dx_add_entry: Directory index full!
3,105,3300000,-;virtio_net virtio0 enp0s1: some error
2,106,3400000,c;watchdog: BUG: soft lockup - CPU#1 stuck for 22s! [ls:4242]
6,107,3500000,-;EXT4-fs (vda1): I/O error while writing superblock
3,108,3600000,-;bad	tab and ESC[31m color
not a record
EOF
printf '3,109,3700000,-;%s\n' "$(printf 'x%.0s' $(seq 1 400))" >>"$WORK/kmsg"
run kernel <"$WORK/kmsg"
check "kernel: status" 0 "$st"
check "kernel: the ones that matter" "MONAD-H| kern 6 ls[4242]: segfault at 0 ip 0000aaaa sp 0000ffff error 6 in libc.so.6[ffff8000+1a0000]
MONAD-H| kern 3 Out of memory: Killed process 812 (node) total-vm:9000000kB, anon-rss:1400000kB
MONAD-H| kern 4 node invoked oom-killer: gfp_mask=0x140cca, order=0, oom_score_adj=0
MONAD-H| kern 4 EXT4-fs warning (device vda1): ext4_dx_add_entry: Directory index full!
MONAD-H| kern 3 virtio_net virtio0 enp0s1: some error
MONAD-H| kern 2 watchdog: BUG: soft lockup - CPU#1 stuck for 22s! [ls:4242]
MONAD-H| kern 6 EXT4-fs (vda1): I/O error while writing superblock
MONAD-H| kern 3 badtab and ESC[31m color" "$(printf '%s\n' "$out" | sed '$d')"
check "kernel: a long line is cut" 300 "$(printf '%s\n' "$out" | tail -1 | tr -d '\n' | wc -c | tr -d ' ')"
check "kernel: to the port too" "$out" "$port"

# A kernel oops (seen: AppArmor's find_attach on every exec, so every
# command "segfaulted"): who crashed, where, and the call trace, which have
# no word of their own to be kept by; the register dump is left out. And
# AppArmor loading or replacing profiles, which such crashes follow.
reset
cat >"$WORK/oops" <<'EOF2'
1,200,1447831751,-;Unable to handle kernel NULL pointer dereference at virtual address 0000000000000008
1,201,1447831800,-;Mem abort info:
0,202,1447916028,-;Internal error: Oops: 0000000096000004 [#1]  SMP
4,203,1447937398,-;Modules linked in: tcp_diag inet_diag
4,204,1447946645,-;CPU: 1 UID: 0 PID: 17297 Comm: agent Not tainted 7.0.0-38-generic #38-Ubuntu PREEMPT(lazy)
4,205,1447946949,-;Hardware name: Apple Inc. Apple Virtualization Generic Platform
4,206,1447947006,-;pc : find_attach+0x13c/0x4f8
4,207,1447947097,-;lr : find_attach+0x9c/0x4f8
4,208,1447947147,-;x29: ffff800083f13790 x28: ffff00003023d220 x27: 0000000000000000
4,209,1447947389,-;Call trace:
4,210,1447947400,-; find_attach+0x13c/0x4f8 (P)
4,211,1447947410,-; profile_transition+0x154/0x5c0
4,212,1447947420,-; apparmor_bprm_creds_for_exec+0x638/0xad0
0,213,1447947880,-;Code: eb15001f 54fffee0 f9403ea1 9101c2ba (f9400420)
4,214,1447947935,-;---[ end trace 0000000000000000 ]---
4,215,1447947950,-;pc : not kept outside a trace
5,216,1448000000,-;audit: type=1400 audit(1.0:42): apparmor="STATUS" operation="profile_replace" name="fwupd" pid=900 comm="apparmor_parser"
EOF2
run kernel <"$WORK/oops"
check "oops: who, where and how" "MONAD-H| kern 1 Unable to handle kernel NULL pointer dereference at virtual address 0000000000000008
MONAD-H| kern 0 Internal error: Oops: 0000000096000004 [#1]  SMP
MONAD-H| kern 4 CPU: 1 UID: 0 PID: 17297 Comm: agent Not tainted 7.0.0-38-generic #38-Ubuntu PREEMPT(lazy)
MONAD-H| kern 4 pc : find_attach+0x13c/0x4f8
MONAD-H| kern 4 lr : find_attach+0x9c/0x4f8
MONAD-H| kern 4 Call trace:
MONAD-H| kern 4  find_attach+0x13c/0x4f8 (P)
MONAD-H| kern 4  profile_transition+0x154/0x5c0
MONAD-H| kern 4  apparmor_bprm_creds_for_exec+0x638/0xad0
MONAD-H| kern 0 Code: eb15001f 54fffee0 f9403ea1 9101c2ba (f9400420)
MONAD-H| kern 4 ---[ end trace 0000000000000000 ]---
MONAD-H| kern 5 audit: type=1400 audit(1.0:42): apparmor=\"STATUS\" operation=\"profile_replace\" name=\"fwupd\" pid=900 comm=\"apparmor_parser\"" "$out"

# A storm: KERN_BURST lines per 10 s of kernel time, the rest counted.
reset
i=0
: >"$WORK/storm"
while [ $i -lt 50 ]; do
    printf '6,%d,%d,-;app[%d]: segfault at 0\n' $i $((5000000 + i * 1000)) $i >>"$WORK/storm"
    i=$((i + 1))
done
printf '6,99,25000000,-;late[1]: segfault at 0\n' >>"$WORK/storm"
run kernel <"$WORK/storm"
check "storm: 20 then the count, then the next window" "20
MONAD-H| kern dropped 30
MONAD-H| kern 6 late[1]: segfault at 0" "$(printf '%s\n' "$out" | grep -c 'segfault at 0$' | awk '{ print $1 - 1 }')
$(printf '%s\n' "$out" | tail -2)"

# The port is found by its name; another port is not written to.
reset
check "port: by name" /dev/vport1p1 "$(PATH="$BIN:$PATH" MONAD_PROC="$PROC" MONAD_SYS="$SYS" $SH "$HEALTH" port)"
echo something.else >"$SYS/class/virtio-ports/vport1p1/name"
check "port: not another" "" "$(PATH="$BIN:$PATH" MONAD_PROC="$PROC" MONAD_SYS="$SYS" $SH "$HEALTH" port)"

# run: the boot line, then a snapshot, and the kernel's lines as they come.
reset
cp "$WORK/kmsg" "$WORK/kmsg.run"
PATH="$BIN:$PATH" FAKE_DF="$WORK" MONAD_PROC="$PROC" MONAD_SYS="$SYS" MONAD_HEALTH_OUT="$WORK/port" \
    MONAD_KMSG="$WORK/kmsg.run" MONAD_HEALTH_INTERVAL=1 $SH "$HEALTH" run >/dev/null 2>&1 &
pid=$!
# Until the first snapshot and all 9 kernel lines are there (a fixed wait
# fell short on a busy machine), at most 15 s.
i=0
while [ $i -lt 75 ]; do
    if grep -q '^MONAD-H| snap ' "$WORK/port" 2>/dev/null &&
        [ "$(grep -c '^MONAD-H| kern ' "$WORK/port" 2>/dev/null)" -ge 9 ]; then break; fi
    sleep 0.2
    i=$((i + 1))
done
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
port=$(cat "$WORK/port")
check "run: boot first" "MONAD-H| boot id=6f1c2a10-0000-4000-8000-000000000001 kernel=$(uname -r) cpus=2 mem=2014312" "$(printf '%s\n' "$port" | head -1)"
check "run: snapshots" yes "$([ "$(printf '%s\n' "$port" | grep -c '^MONAD-H| snap ')" -ge 1 ] && echo yes || echo no)"
check "run: kernel lines" 9 "$(printf '%s\n' "$port" | grep -c '^MONAD-H| kern ')"

# A kernel line reaches the port as it comes, not when a buffer fills: the
# OOM kill is what must be there before the guest freezes.
reset
rm -f "$WORK/kmsg.fifo"
mkfifo "$WORK/kmsg.fifo"
PATH="$BIN:$PATH" FAKE_DF="$WORK" MONAD_PROC="$PROC" MONAD_SYS="$SYS" MONAD_HEALTH_OUT="$WORK/port" \
    MONAD_KMSG="$WORK/kmsg.fifo" MONAD_HEALTH_INTERVAL=60 $SH "$HEALTH" run >/dev/null 2>&1 &
pid=$!
exec 7>"$WORK/kmsg.fifo"
printf '3,500,9000000,-;Out of memory: Killed process 17955 (python3) total-vm:1707252kB\n' >&7
seen=no
for i in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q 'Killed process 17955' "$WORK/port" 2>/dev/null; then seen=yes; break; fi
    sleep 0.2
done
check "streamed: the OOM kill is there at once" yes "$seen"
exec 7>&-
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null

# No health port (Lima boots the same disk): run ends at once, quietly.
reset
rm -rf "$SYS/class/virtio-ports"
PATH="$BIN:$PATH" FAKE_DF="$WORK" MONAD_PROC="$PROC" MONAD_SYS="$SYS" MONAD_KMSG="$WORK/kmsg" \
    MONAD_HEALTH_INTERVAL=1 $SH "$HEALTH" run >"$WORK/stdout" 2>&1 &
pid=$!
sleep 1
if kill -0 "$pid" 2>/dev/null; then st=running; kill "$pid"; else wait "$pid"; st=$?; fi
check "no port: run ends" 0 "$st"
check "no port: says nothing" "" "$(cat "$WORK/stdout")"

run nonsense
check "usage" 2 "$st"

printf 'monad-health tests (%s): %d checks, %d failures\n' "$SH" "$checks" "$failures" >&2
[ "$failures" -eq 0 ]
