#!/bin/sh
# Tests for Monad/Guest/monad-console.sh: the kernel's console is put on hvc0
# too (last, so /dev/console is hvc0) through whichever boot loader tool the
# guest has, only when it is not there yet, and the script never fails its
# caller. Stand-ins for grubby, update-grub and grub(2)-mkconfig, a fake
# root, and a PATH with nothing else from the system that runs the tests.
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
for tool in cat cp grep mv rm sed; do
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
            grubby) stub grubby <<'EOF'
case "$1" in
    --info=ALL) sed -n 's/^/args="/; s/$/"/p' "$FAKE_STATE/kernels" ;;
    --update-kernel=ALL)
        [ "${FAKE_FAILS:-0}" = 0 ] || exit 1
        arg=${2#--args=}
        sed "s/\$/ $arg/" "$FAKE_STATE/kernels" >"$FAKE_STATE/kernels.new" && mv "$FAKE_STATE/kernels.new" "$FAKE_STATE/kernels" ;;
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
run() {
    out=$(PATH="$BIN:$SYS" FAKE_STATE="$STATE" MONAD_ROOT="$ROOT" FAKE_FAILS="$fails" "$SH_PATH" "$SCRIPT" 2>&1)
    st=$?
    log=$(cat "$STATE/log")
}

echo "monad-console tests ($SH)" >&2

# grub with /etc/default/grub.d (Debian, Ubuntu): a drop-in after the
# image's own settings, then update-grub; hvc0 is the last console.
reset update-grub
mkdir -p "$ROOT/etc/default/grub.d"
echo 'GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyAMA0"' >"$ROOT/etc/default/grub.d/50-cloudimg-settings.cfg"
run
check "grub.d: status" 0 "$st"
check "grub.d: update-grub ran" "update-grub " "$log"
check "grub.d: drop-in" '# Monad: the kernel console on hvc0 too, kept in serial.log (monad-console.sh).
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=hvc0"' "$(cat "$ROOT/etc/default/grub.d/90-monad-console.cfg")"
check "grub.d: hvc0 last" "console=tty1 console=ttyAMA0 console=hvc0" "$(
    for f in "$ROOT"/etc/default/grub.d/*.cfg; do . "$f"; done; echo "$GRUB_CMDLINE_LINUX_DEFAULT")"
check "grub.d: says so" "monad-console: the kernel console reaches Monad from the next boot (/etc/default/grub.d/90-monad-console.cfg)" "$out"

# Already there: nothing runs (update-grub takes seconds, at every boot).
: >"$STATE/log"
run
check "grub.d again: status" 0 "$st"
check "grub.d again: nothing" "" "$log$out"

# Changed by hand: written again.
echo 'GRUB_CMDLINE_LINUX_DEFAULT=""' >"$ROOT/etc/default/grub.d/90-monad-console.cfg"
: >"$STATE/log"
run
check "grub.d changed: update-grub ran" "update-grub " "$log"

# update-grub fails: the drop-in goes (the next boot tries again), and the
# caller still succeeds.
rm -f "$ROOT/etc/default/grub.d/90-monad-console.cfg"
: >"$STATE/log"
fails=1; run; fails=0
check "grub.d fails: status" 0 "$st"
check "grub.d fails: no drop-in" "no" "$([ -e "$ROOT/etc/default/grub.d/90-monad-console.cfg" ] && echo yes || echo no)"
check "grub.d fails: says so" "monad-console: update-grub failed, so the kernel console stays as it was" "$out"

# grubby (Fedora, AlmaLinux): every installed kernel, even where
# /etc/default/grub exists too.
reset grubby grub2-mkconfig
printf 'GRUB_CMDLINE_LINUX="console=ttyAMA0"\n' >"$ROOT/etc/default/grub"
printf 'ro console=ttyAMA0\nro console=ttyAMA0 console=hvc0\n' >"$STATE/kernels"
run
check "grubby: status" 0 "$st"
check "grubby: every kernel" "grubby --info=ALL
grubby --update-kernel=ALL --args=console=hvc0" "$log"
check "grubby: says so" "monad-console: the kernel console reaches Monad from the next boot (grubby)" "$out"
check "grubby: /etc/default/grub left alone" 'GRUB_CMDLINE_LINUX="console=ttyAMA0"' "$(cat "$ROOT/etc/default/grub")"

printf 'ro console=hvc0\nro quiet console=hvc0\n' >"$STATE/kernels"
: >"$STATE/log"
run
check "grubby done: only a look" "grubby --info=ALL" "$log"
check "grubby done: quiet" "" "$out"

printf 'ro\n' >"$STATE/kernels"
: >"$STATE/log"
fails=1; run; fails=0
check "grubby fails: status" 0 "$st"
check "grubby fails: says so" "monad-console: grubby could not add console=hvc0, so the kernel console stays as it was" "$out"

# /etc/default/grub alone (openSUSE): one line appended (the file is shell,
# so it extends whatever was set before), then grub2-mkconfig into
# /boot/grub2.
reset grub2-mkconfig
mkdir -p "$ROOT/boot/grub2"
printf 'GRUB_TIMEOUT=8\nGRUB_CMDLINE_LINUX_DEFAULT="splash=silent quiet"\n' >"$ROOT/etc/default/grub"
run
check "defaults: status" 0 "$st"
check "defaults: mkconfig" "grub2-mkconfig -o $ROOT/boot/grub2/grub.cfg" "$log"
check "defaults: line" 'GRUB_TIMEOUT=8
GRUB_CMDLINE_LINUX_DEFAULT="splash=silent quiet"
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=hvc0" # Monad: monad-console.sh' "$(cat "$ROOT/etc/default/grub")"
check "defaults: hvc0 last" "splash=silent quiet console=hvc0" "$(. "$ROOT/etc/default/grub"; echo "$GRUB_CMDLINE_LINUX_DEFAULT")"
check "defaults: says so" "monad-console: the kernel console reaches Monad from the next boot (/etc/default/grub)" "$out"

: >"$STATE/log"
run
check "defaults again: nothing" "" "$log$out"

# grub-mkconfig into /boot/grub; failing, the file is as it was.
reset grub-mkconfig
mkdir -p "$ROOT/boot/grub"
printf 'GRUB_TIMEOUT=0\n' >"$ROOT/etc/default/grub"
fails=1; run; fails=0
check "defaults fails: status" 0 "$st"
check "defaults fails: mkconfig" "grub-mkconfig -o $ROOT/boot/grub/grub.cfg" "$log"
check "defaults fails: file as it was" "GRUB_TIMEOUT=0" "$(cat "$ROOT/etc/default/grub")"
check "defaults fails: says so" "monad-console: grub-mkconfig failed, so the kernel console stays as it was" "$out"

# No boot loader tool it knows: nothing changes, and it says so.
reset
printf 'GRUB_TIMEOUT=0\n' >"$ROOT/etc/default/grub"
run
check "unknown: status" 0 "$st"
check "unknown: file as it was" "GRUB_TIMEOUT=0" "$(cat "$ROOT/etc/default/grub")"
check "unknown: says so" "monad-console: no grubby, update-grub or grub-mkconfig here, so the kernel console stays as it was" "$out"

printf 'console tests (%s): %d checks, %d failures\n' "$SH" "$checks" "$failures" >&2
[ "$failures" -eq 0 ]
