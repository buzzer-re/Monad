#!/bin/sh
# monad-console.sh — the kernel's console on hvc0 too: the virtio console
# whose output Monad keeps in the VM's serial.log and shows in the boot tab.
# Cloud images send it to tty1 and a serial port (ttyAMA0, ttyS0) that a
# Monad VM does not have, so a boot that failed before sshd (no root
# filesystem, a kernel panic) said nothing at all. hvc0 goes last: the last
# console= is /dev/console, where the guest's MONAD| report lines go too.
#
# Through the boot loader tool the guest has, whatever its distribution:
# grubby, a drop-in in /etc/default/grub.d, or /etc/default/grub itself. It
# takes effect at the next boot, does nothing when already done, and always
# exits 0: the installer it runs in must not fail over it. Run by cloud-init
# at first boot and by the installer Monad runs at every boot (not in a Lima
# VM, which Lima boots too). MONAD_ROOT exists for its tests
# (CTests/test_console.sh).

set -u
ROOT=${MONAD_ROOT:-}
ARG=console=hvc0
MARK="# Monad: monad-console.sh"

say() { echo "monad-console: $*"; }
kept() { say "$1, so the kernel console stays as it was"; }
done_at_next_boot() { say "the kernel console reaches Monad from the next boot ($1)"; }

# Every installed kernel's entry (newer kernels copy the running one's line).
if command -v grubby >/dev/null 2>&1; then
    if grubby --info=ALL 2>/dev/null | grep '^args=' | grep -qv "$ARG"; then
        if grubby --update-kernel=ALL --args="$ARG" >/dev/null 2>&1; then
            done_at_next_boot grubby
        else
            kept "grubby could not add $ARG"
        fi
    fi
    exit 0
fi

# A drop-in read after the image's own settings (50-cloudimg-settings.cfg).
DROPIN=/etc/default/grub.d/90-monad-console.cfg
if [ -d "$ROOT/etc/default/grub.d" ] && command -v update-grub >/dev/null 2>&1; then
    want='# Monad: the kernel console on hvc0 too, kept in serial.log (monad-console.sh).
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=hvc0"'
    [ "$(cat "$ROOT$DROPIN" 2>/dev/null)" = "$want" ] && exit 0
    printf '%s\n' "$want" >"$ROOT$DROPIN.new" && mv "$ROOT$DROPIN.new" "$ROOT$DROPIN" || exit 0
    if update-grub >/dev/null 2>&1; then
        done_at_next_boot "$DROPIN"
    else
        rm -f "$ROOT$DROPIN"
        kept "update-grub failed"
    fi
    exit 0
fi

# /etc/default/grub is shell: a line at its end extends what it set before.
DEFAULTS=/etc/default/grub
mkconfig=""
for tool in grub2-mkconfig grub-mkconfig; do
    if command -v "$tool" >/dev/null 2>&1; then mkconfig=$tool; break; fi
done
out=""
for dir in /boot/grub2 /boot/grub; do
    if [ -d "$ROOT$dir" ]; then out=$ROOT$dir/grub.cfg; break; fi
done
if [ -f "$ROOT$DEFAULTS" ] && [ -n "$mkconfig" ] && [ -n "$out" ]; then
    grep -qF "$MARK" "$ROOT$DEFAULTS" && exit 0
    cp "$ROOT$DEFAULTS" "$ROOT$DEFAULTS.monad-old" || exit 0
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT %s" %s\n' "$ARG" "$MARK" >>"$ROOT$DEFAULTS"
    if "$mkconfig" -o "$out" >/dev/null 2>&1; then
        rm -f "$ROOT$DEFAULTS.monad-old"
        done_at_next_boot "$DEFAULTS"
    else
        mv "$ROOT$DEFAULTS.monad-old" "$ROOT$DEFAULTS"
        kept "$mkconfig failed"
    fi
    exit 0
fi

kept "no grubby, update-grub or grub-mkconfig here"
exit 0
