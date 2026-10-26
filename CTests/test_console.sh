#!/bin/sh
# Tests for Monad/Guest/monad-console.sh: the kernel's console is put on hvc0
# too (last, so /dev/console is hvc0) through whichever boot loader tool the
# guest has, quiet unless asked for "full" (the kernel, systemd and services
# print only errors there), only when it is not set that way yet, and the
# script never fails its caller. Stand-ins for grubby, update-grub and
# grub(2)-mkconfig, a fake root, and a PATH with nothing else from the
# system that runs the tests.
# Usage: test_console.sh [workdir]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../Monad/Guest/monad-console.sh"
SH=${CONSOLE_SHELL:-sh}
SH_PATH=$(command -v "$SH")   # the PATH below has no shell in it
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

# The tools the script may use, and nothing else: a real update-grub or
# grub-mkconfig on the machine running the tests must never be found.
SYS="$WORK/sys"
mkdir -p "$SYS"
for tool in awk cat cp grep mkdir mv rm sed; do
    real=$(command -v "$tool") || { echo "test_console.sh: no $tool" >&2; exit 1; }
    ln -s "$real" "$SYS/$tool"
done

BIN="$WORK/bin"
STATE="$WORK/state"
ROOT="$WORK/root"
stub() { # stub NAME (body on stdin): logs its arguments, then runs the body
    { echo '#!/bin/sh'; echo 'echo "'"$1"' $*" >>"$FAKE_STATE/log"'; cat; } >"$BIN/$1"
    chmod +x "$BIN/$1"
}

reset() { # reset TOOL...: a fresh root, and only these boot loader tools
    rm -rf "$BIN" "$STATE" "$ROOT"
    mkdir -p "$BIN" "$STATE" "$ROOT/etc/default"
    : >"$STATE/log"
    for tool in "$@"; do
        case "$tool" in
            # As grubby-bls's update_args: the arguments removed go (a bare
            # name with any value), then every argument named like an added
            # one (each console= for console=hvc0), then the added ones go
            # last. One kernel's arguments per line of $FAKE_STATE/kernels.
            grubby) stub grubby <<'EOF'
case "$1" in
    --info=ALL) sed -n 's/^/args="/; s/$/"/p' "$FAKE_STATE/kernels" ;;
    --update-kernel=ALL)
        [ "${FAKE_FAILS:-0}" = 0 ] || exit 1
        add=${2#--args=}
        drop=${3#--remove-args=}
        awk -v add="$add" -v drop="$drop" '{
            n = split($0, a, " "); m = split(drop, d, " "); k = split(add, p, " "); out = ""
            for (i = 1; i <= n; i++) {
                key = a[i]; sub(/=.*/, "", key); keep = 1
                for (j = 1; j <= m; j++) if (a[i] == d[j] || (d[j] !~ /=/ && key == d[j])) keep = 0
                for (j = 1; j <= k; j++) { name = p[j]; sub(/=.*/, "", name); if (key == name) keep = 0 }
                if (keep) out = out a[i] " "
            }
            print out add
        }' "$FAKE_STATE/kernels" >"$FAKE_STATE/kernels.new" && mv "$FAKE_STATE/kernels.new" "$FAKE_STATE/kernels" ;;
esac
EOF
                ;;
            *) stub "$tool" <<'EOF'
[ "${FAKE_FAILS:-0}" = 0 ]
EOF
                ;;
        esac
    done
}
fails=0
run() { # run [MODE]
    out=$(PATH="$BIN:$SYS" FAKE_STATE="$STATE" MONAD_ROOT="$ROOT" FAKE_FAILS="$fails" "$SH_PATH" "$SCRIPT" "$@" 2>&1)
    st=$?
    log=$(cat "$STATE/log")
}

QUIET="console=hvc0 quiet systemd.journald.max_level_console=err"
FULL="console=hvc0 loglevel=7 systemd.show_status=yes"

echo "monad-console tests ($SH)" >&2

# grub with /etc/default/grub.d (Debian, Ubuntu): a drop-in after the
# image's own settings, then update-grub; hvc0 is the last console. Quiet
# when nothing is asked.
reset update-grub
DROPIN="$ROOT/etc/default/grub.d/90-monad-console.cfg"
mkdir -p "$ROOT/etc/default/grub.d"
echo 'GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyAMA0"' >"$ROOT/etc/default/grub.d/50-cloudimg-settings.cfg"
run
check "grub.d: status" 0 "$st"
check "grub.d: update-grub ran" "update-grub " "$log"
check "grub.d: drop-in" '# Monad: the kernel console on hvc0 too, kept in serial.log, errors only (monad-console.sh).
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=hvc0 quiet systemd.journald.max_level_console=err"' "$(cat "$DROPIN")"
check "grub.d: hvc0 last" "console=tty1 console=ttyAMA0 $QUIET" "$(
    for f in "$ROOT"/etc/default/grub.d/*.cfg; do . "$f"; done; echo "$GRUB_CMDLINE_LINUX_DEFAULT")"
check "grub.d: says so" "monad-console: the kernel console reaches Monad from the next boot, errors only (/etc/default/grub.d/90-monad-console.cfg)" "$out"

# Already there: nothing runs (update-grub takes seconds, at every boot).
: >"$STATE/log"
run quiet
check "grub.d again: status" 0 "$st"
check "grub.d again: nothing" "" "$log$out"

# Full: the same drop-in, every message.
: >"$STATE/log"
run full
check "grub.d full: update-grub ran" "update-grub " "$log"
check "grub.d full: cmdline" "console=tty1 console=ttyAMA0 $FULL" "$(
    for f in "$ROOT"/etc/default/grub.d/*.cfg; do . "$f"; done; echo "$GRUB_CMDLINE_LINUX_DEFAULT")"
check "grub.d full: says so" "monad-console: the kernel console reaches Monad from the next boot, every message (/etc/default/grub.d/90-monad-console.cfg)" "$out"
check "grub.d full: no copy left" "no" "$([ -e "$DROPIN.monad-old" ] && echo yes || echo no)"
: >"$STATE/log"
run full
check "grub.d full again: nothing" "" "$log$out"

# Changed by hand: written again.
echo 'GRUB_CMDLINE_LINUX_DEFAULT=""' >"$DROPIN"
: >"$STATE/log"
run
check "grub.d changed: update-grub ran" "update-grub " "$log"

# update-grub fails: the drop-in is what it was (grub.cfg was made from
# it; the next boot tries again), and the caller still succeeds.
: >"$STATE/log"
fails=1; run full; fails=0
check "grub.d fails: status" 0 "$st"
check "grub.d fails: drop-in as it was" "console=tty1 console=ttyAMA0 $QUIET" "$(
    for f in "$ROOT"/etc/default/grub.d/*.cfg; do . "$f"; done; echo "$GRUB_CMDLINE_LINUX_DEFAULT")"
check "grub.d fails: says so" "monad-console: update-grub failed, so the kernel console stays as it was" "$out"
rm -f "$DROPIN"
fails=1; run; fails=0
check "grub.d fails first: no drop-in" "no" "$([ -e "$DROPIN" ] && echo yes || echo no)"

# Services print to the console through journald (cloud-init's tables at
# every boot): errors only while quiet, its default when full. Only where
# the guest has systemd.
reset
JOURNALD="$ROOT/etc/systemd/journald.conf.d/90-monad-console.conf"
run
check "journald, no systemd: nothing" "no" "$([ -e "$ROOT/etc/systemd" ] && echo yes || echo no)"
mkdir -p "$ROOT/etc/systemd"
run quiet
check "journald quiet: status" 0 "$st"
check "journald quiet: drop-in" '# Monad: services print only errors on the console, kept in serial.log (monad-console.sh).
[Journal]
MaxLevelConsole=err' "$(cat "$JOURNALD")"
check "journald quiet: says so" "monad-console: services print only errors on the console from the next boot
monad-console: no grubby, update-grub or grub-mkconfig here, so the kernel console stays as it was" "$out"
run quiet
check "journald quiet again: only the boot loader" "monad-console: no grubby, update-grub or grub-mkconfig here, so the kernel console stays as it was" "$out"
run full
check "journald full: no drop-in" "no" "$([ -e "$JOURNALD" ] && echo yes || echo no)"
check "journald full: says so" "monad-console: services print everything on the console from the next boot
monad-console: no grubby, update-grub or grub-mkconfig here, so the kernel console stays as it was" "$out"

# grubby (Fedora, AlmaLinux): every installed kernel, even where
# /etc/default/grub exists too. grubby replaces every console= with the
# ones it is given, so the kernel's own go again, before hvc0.
reset grubby grub2-mkconfig
printf 'GRUB_CMDLINE_LINUX="console=ttyAMA0"\n' >"$ROOT/etc/default/grub"
printf 'ro console=tty1 console=ttyS0,115200n8\nro console=tty1 console=ttyS0,115200n8 console=hvc0\n' >"$STATE/kernels"
run
check "grubby: status" 0 "$st"
check "grubby: every kernel" "grubby --info=ALL
grubby --update-kernel=ALL --args=console=tty1 console=ttyS0,115200n8 $QUIET --remove-args=loglevel=7 systemd.show_status=yes" "$log"
check "grubby: consoles kept, hvc0 last" "ro console=tty1 console=ttyS0,115200n8 $QUIET
ro console=tty1 console=ttyS0,115200n8 $QUIET" "$(cat "$STATE/kernels")"
check "grubby: says so" "monad-console: the kernel console reaches Monad from the next boot, errors only (grubby)" "$out"
check "grubby: /etc/default/grub left alone" 'GRUB_CMDLINE_LINUX="console=ttyAMA0"' "$(cat "$ROOT/etc/default/grub")"

: >"$STATE/log"
run
check "grubby done: only a look" "grubby --info=ALL" "$log"
check "grubby done: quiet" "" "$out"

# hvc0 is not the last console any more: set again.
printf 'ro console=hvc0 quiet console=tty1\n' >"$STATE/kernels"
: >"$STATE/log"
run
check "grubby, hvc0 not last" "ro console=tty1 $QUIET" "$(cat "$STATE/kernels")"

# Full: Monad's quiet goes (the image's too, all the same to grubby).
: >"$STATE/log"
run full
check "grubby full" "grubby --info=ALL
grubby --update-kernel=ALL --args=console=tty1 $FULL --remove-args=quiet systemd.journald.max_level_console=err" "$log"
check "grubby full: arguments" "ro console=tty1 $FULL" "$(cat "$STATE/kernels")"
check "grubby full: says so" "monad-console: the kernel console reaches Monad from the next boot, every message (grubby)" "$out"
: >"$STATE/log"
run full
check "grubby full again: only a look" "grubby --info=ALL" "$log"
run quiet
check "grubby back to quiet" "ro console=tty1 $QUIET" "$(cat "$STATE/kernels")"

printf 'ro\n' >"$STATE/kernels"
: >"$STATE/log"
fails=1; run; fails=0
check "grubby fails: status" 0 "$st"
check "grubby fails: says so" "monad-console: grubby could not change the kernel's arguments, so the kernel console stays as it was" "$out"

: >"$STATE/kernels"
: >"$STATE/log"
run
check "grubby, no kernel: only a look" "grubby --info=ALL" "$log"
check "grubby, no kernel: says so" "monad-console: grubby lists no kernel, so the kernel console stays as it was" "$out"

# /etc/default/grub alone (openSUSE): one line at its end (the file is
# shell, so it extends whatever was set before), then grub2-mkconfig into
# /boot/grub2. Full overrides an image that boots quiet by itself.
reset grub2-mkconfig
mkdir -p "$ROOT/boot/grub2"
printf 'GRUB_TIMEOUT=8\nGRUB_CMDLINE_LINUX_DEFAULT="splash=silent quiet"\n' >"$ROOT/etc/default/grub"
run
check "defaults: status" 0 "$st"
check "defaults: mkconfig" "grub2-mkconfig -o $ROOT/boot/grub2/grub.cfg" "$log"
check "defaults: line" 'GRUB_TIMEOUT=8
GRUB_CMDLINE_LINUX_DEFAULT="splash=silent quiet"
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=hvc0 quiet systemd.journald.max_level_console=err" # Monad: monad-console.sh' "$(cat "$ROOT/etc/default/grub")"
check "defaults: hvc0 last" "splash=silent quiet $QUIET" "$(. "$ROOT/etc/default/grub"; echo "$GRUB_CMDLINE_LINUX_DEFAULT")"
check "defaults: says so" "monad-console: the kernel console reaches Monad from the next boot, errors only (/etc/default/grub)" "$out"

: >"$STATE/log"
run
check "defaults again: nothing" "" "$log$out"

: >"$STATE/log"
run full
check "defaults full: mkconfig" "grub2-mkconfig -o $ROOT/boot/grub2/grub.cfg" "$log"
check "defaults full: one line, replaced" 'GRUB_TIMEOUT=8
GRUB_CMDLINE_LINUX_DEFAULT="splash=silent quiet"
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=hvc0 loglevel=7 systemd.show_status=yes" # Monad: monad-console.sh' "$(cat "$ROOT/etc/default/grub")"
check "defaults full: no copies left" "" "$(cd "$ROOT/etc/default" && for f in *; do [ "$f" = grub ] || echo "$f"; done)"

# grub-mkconfig into /boot/grub; failing, the file is as it was.
reset grub-mkconfig
mkdir -p "$ROOT/boot/grub"
printf 'GRUB_TIMEOUT=0\n' >"$ROOT/etc/default/grub"
fails=1; run; fails=0
check "defaults fails: status" 0 "$st"
check "defaults fails: mkconfig" "grub-mkconfig -o $ROOT/boot/grub/grub.cfg" "$log"
check "defaults fails: file as it was" "GRUB_TIMEOUT=0" "$(cat "$ROOT/etc/default/grub")"
check "defaults fails: says so" "monad-console: grub-mkconfig failed, so the kernel console stays as it was" "$out"
run
fails=1; run full; fails=0
check "defaults fails to change: as it was" 'GRUB_TIMEOUT=0
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=hvc0 quiet systemd.journald.max_level_console=err" # Monad: monad-console.sh' "$(cat "$ROOT/etc/default/grub")"

# No boot loader tool it knows: nothing changes, and it says so.
reset
printf 'GRUB_TIMEOUT=0\n' >"$ROOT/etc/default/grub"
run
check "unknown: status" 0 "$st"
check "unknown: file as it was" "GRUB_TIMEOUT=0" "$(cat "$ROOT/etc/default/grub")"
check "unknown: says so" "monad-console: no grubby, update-grub or grub-mkconfig here, so the kernel console stays as it was" "$out"

printf 'console tests (%s): %d checks, %d failures\n' "$SH" "$checks" "$failures" >&2
[ "$failures" -eq 0 ]
