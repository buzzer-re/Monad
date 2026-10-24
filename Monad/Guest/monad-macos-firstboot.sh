#!/bin/sh
# Monad's first boot in a macOS guest (Phase 14). Run once, as root, by
# launchd (dev.monad.setup) from the files Monad's setup staged in
# $SETUP. It makes the account with Apple's own sysadminctl, gives it
# Monad's key and sudo, sets sshd to keys only, starts launchd's sshd on the
# loopback and monad-guestd (ssh and the agent on vsock), then takes itself
# and the password away.
# Remote Login (ssh on the network) is never turned on.
set -u
SETUP=/usr/local/libexec/monad/setup
MONAD=/usr/local/libexec/monad
LOG=/var/log/monad-setup.log
exec >>"$LOG" 2>&1
say() { echo "monad-setup: $(date '+%Y-%m-%d %H:%M:%S') $*"; }

[ -r "$SETUP/account" ] || { say "nothing staged"; exit 0; }
. "$SETUP/account"
case "$MONAD_USER" in
    ''|*[!a-z0-9_-]*) say "bad account name"; exit 1 ;;
esac
home="/Users/$MONAD_USER"

if id "$MONAD_USER" >/dev/null 2>&1; then
    say "account $MONAD_USER is there"
else
    say "making the account $MONAD_USER"
    if ! sysadminctl -addUser "$MONAD_USER" -fullName "$MONAD_USER" -password "$(cat "$SETUP/password")" \
            -home "$home" -shell /bin/zsh -admin; then
        say "sysadminctl failed"
        exit 1
    fi
    createhomedir -c -u "$MONAD_USER" >/dev/null 2>&1 || true
fi
group=$(id -gn "$MONAD_USER")

install -d -o "$MONAD_USER" -g "$group" -m 700 "$home/.ssh"
install -o "$MONAD_USER" -g "$group" -m 600 "$SETUP/authorized_keys" "$home/.ssh/authorized_keys"
install -d -o root -g wheel -m 755 /etc/sudoers.d
install -o root -g wheel -m 440 "$SETUP/sudoers" /etc/sudoers.d/monad
install -d -o root -g wheel -m 755 /etc/ssh/sshd_config.d
install -o root -g wheel -m 644 "$SETUP/sshd.conf" /etc/ssh/sshd_config.d/100-monad.conf

say "starting sshd (loopback) and monad-guestd"
install -d -o root -g wheel -m 755 "$MONAD"
install -o root -g wheel -m 755 "$SETUP/guestd" "$MONAD/guestd"
install -o root -g wheel -m 644 "$SETUP/agent" "$MONAD/agent"
install -o root -g wheel -m 644 "$SETUP/dev.monad.sshd.plist" /Library/LaunchDaemons/dev.monad.sshd.plist
launchctl bootstrap system /Library/LaunchDaemons/dev.monad.sshd.plist 2>/dev/null || true
install -o root -g wheel -m 644 "$SETUP/dev.monad.guestd.plist" /Library/LaunchDaemons/dev.monad.guestd.plist
launchctl bootstrap system /Library/LaunchDaemons/dev.monad.guestd.plist 2>/dev/null \
    || launchctl kickstart -k system/dev.monad.guestd

touch /var/db/.AppleSetupDone
rm -f "$SETUP/password"
rm -f /Library/LaunchDaemons/dev.monad.setup.plist
say "done"
