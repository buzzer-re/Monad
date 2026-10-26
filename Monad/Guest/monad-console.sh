#!/bin/sh
# monad-console.sh — the kernel's console on hvc0 too: the virtio console
# whose output Monad keeps in the VM's serial.log and shows in the boot tab.
# Cloud images send it to tty1 and a serial port (ttyAMA0, ttyS0) that a
# Monad VM does not have, so a boot that failed before sshd (no root
# filesystem, a kernel panic) said nothing at all. hvc0 goes last: the last
# console= is /dev/console, where the guest's MONAD| report lines go too.
#
# Quiet unless asked for "full" (Settings › Virtual Machines › Full boot
# messages): the kernel, systemd and the services journald forwards to the
# console (cloud-init's tables, at every boot) print only errors there, so
# a boot that works shows next to nothing and one that fails still says why.
#
# Through the boot loader tool the guest has, whatever its distribution:
# grubby, a drop-in in /etc/default/grub.d, or /etc/default/grub itself. It
# takes effect at the next boot, does nothing when already done, and always
# exits 0: the installer it runs in must not fail over it. Run by cloud-init
# at first boot, by the installer Monad runs at every boot and when the
# setting changes (not in a Lima VM, which Lima boots too). MONAD_ROOT
# exists for its tests (CTests/test_console.sh).
# Usage: monad-console.sh [quiet|full]

set -u
ROOT=${MONAD_ROOT:-}
MARK="# Monad: monad-console.sh"
# The arguments Monad wants, and the other mode's (gone from the kernel's).
# loglevel and systemd.show_status come after an image's own quiet.
MODE=quiet
[ "${1:-}" = full ] && MODE=full
case $MODE in
    full) ARGS="console=hvc0 loglevel=7 systemd.show_status=yes"; DROP="quiet"; SAID="every message" ;;
    *) ARGS="console=hvc0 quiet"; DROP="loglevel=7 systemd.show_status=yes"; SAID="errors only" ;;
esac

say() { echo "monad-console: $*"; }
kept() { say "$1, so the kernel console stays as it was"; }
done_at_next_boot() { say "the kernel console reaches Monad from the next boot, $SAID ($1)"; }

# Services whose output goes to the journal and the console go through
# journald, which reads this at its start.
JOURNALD=/etc/systemd/journald.conf.d/90-monad-console.conf
if [ -d "$ROOT/etc/systemd" ]; then
    if [ "$MODE" = quiet ]; then
        want='# Monad: services print only errors on the console, kept in serial.log (monad-console.sh).
[Journal]
MaxLevelConsole=err'
        if [ "$(cat "$ROOT$JOURNALD" 2>/dev/null)" != "$want" ] &&
            mkdir -p "$ROOT${JOURNALD%/*}" && printf '%s\n' "$want" >"$ROOT$JOURNALD"; then
            say "services print only errors on the console from the next boot"
        fi
    elif [ -e "$ROOT$JOURNALD" ] && rm -f "$ROOT$JOURNALD"; then
        say "services print everything on the console from the next boot"
    fi
fi

# Every installed kernel's entry (newer kernels copy the running one's
# line). grubby replaces every console= with the ones it is given, so the
# kernel's own go again, before hvc0; nothing runs when each entry has
# Monad's arguments, hvc0 last, and none of the other mode's.
if command -v grubby >/dev/null 2>&1; then
    entries=$(grubby --info=ALL 2>/dev/null | sed -n 's/^args="\(.*\)"$/\1/p')
    if [ -z "$entries" ]; then
        kept "grubby lists no kernel"
        exit 0
    fi
    plan=$(printf '%s\n' "$entries" | awk -v want="$ARGS" -v drop="$DROP" '
        {
            n = split($0, a, " "); split("", have); last = ""
            for (i = 1; i <= n; i++) {
                have[a[i]] = 1
                if (a[i] !~ /^console=/) continue
                last = a[i]
                if (a[i] != "console=hvc0" && !(a[i] in seen)) { seen[a[i]] = 1; consoles = consoles a[i] " " }
            }
            if (last != "console=hvc0") stale = 1
            m = split(want, w, " "); for (i = 1; i <= m; i++) if (!(w[i] in have)) stale = 1
            m = split(drop, d, " "); for (i = 1; i <= m; i++) if (d[i] in have) stale = 1
        }
        END { if (stale) print consoles want }')
    if [ -n "$plan" ]; then
        if grubby --update-kernel=ALL --args="$plan" --remove-args="$DROP" >/dev/null 2>&1; then
            done_at_next_boot grubby
        else
            kept "grubby could not change the kernel's arguments"
        fi
    fi
    exit 0
fi

# A drop-in read after the image's own settings (50-cloudimg-settings.cfg).
# Failing, the one before stays: grub.cfg was made from it.
DROPIN=/etc/default/grub.d/90-monad-console.cfg
if [ -d "$ROOT/etc/default/grub.d" ] && command -v update-grub >/dev/null 2>&1; then
    want="# Monad: the kernel console on hvc0 too, kept in serial.log, $SAID (monad-console.sh).
GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT $ARGS\""
    [ "$(cat "$ROOT$DROPIN" 2>/dev/null)" = "$want" ] && exit 0
    rm -f "$ROOT$DROPIN.monad-old"
    if [ -e "$ROOT$DROPIN" ]; then cp "$ROOT$DROPIN" "$ROOT$DROPIN.monad-old" || exit 0; fi
    printf '%s\n' "$want" >"$ROOT$DROPIN.new" && mv "$ROOT$DROPIN.new" "$ROOT$DROPIN" || exit 0
    if update-grub >/dev/null 2>&1; then
        rm -f "$ROOT$DROPIN.monad-old"
        done_at_next_boot "$DROPIN"
    else
        if [ -e "$ROOT$DROPIN.monad-old" ]; then mv "$ROOT$DROPIN.monad-old" "$ROOT$DROPIN"; else rm -f "$ROOT$DROPIN"; fi
        kept "update-grub failed"
    fi
    exit 0
fi

# /etc/default/grub is shell: a line at its end extends what it set before.
# Rewritten in place (its owner, mode and label stay), as it was on failure.
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
    line="GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT $ARGS\" $MARK"
    grep -qxF "$line" "$ROOT$DEFAULTS" && exit 0
    cp "$ROOT$DEFAULTS" "$ROOT$DEFAULTS.monad-old" || exit 0
    { grep -vF "$MARK" "$ROOT$DEFAULTS.monad-old"; printf '%s\n' "$line"; } >"$ROOT$DEFAULTS.new" &&
        cat "$ROOT$DEFAULTS.new" >"$ROOT$DEFAULTS"
    rm -f "$ROOT$DEFAULTS.new"
    if "$mkconfig" -o "$out" >/dev/null 2>&1; then
        rm -f "$ROOT$DEFAULTS.monad-old"
        done_at_next_boot "$DEFAULTS"
    else
        cat "$ROOT$DEFAULTS.monad-old" >"$ROOT$DEFAULTS" && rm -f "$ROOT$DEFAULTS.monad-old"
        kept "$mkconfig failed"
    fi
    exit 0
fi

kept "no grubby, update-grub or grub-mkconfig here"
exit 0
