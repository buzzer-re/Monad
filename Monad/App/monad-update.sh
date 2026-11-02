#!/bin/sh
#
# monad-update.sh — puts a downloaded update in place of Monad, then opens it
# (Monad › Check for Updates). The app has already checked the update (the
# release's SHA-256, Monad's Release bundle id, the version, the signature)
# and runs this from a copy in its work folder, since the bundle this came
# in is the one replaced. VMs keep running in MonadHost meanwhile; the new
# Monad replaces that MonadHost once no VM runs.
#
#   monad-update.sh PID NEW DEST WORK
#
#   PID   the Monad that downloaded it: nothing is replaced while it runs
#   NEW   the checked Monad.app
#   DEST  the installed Monad.app, replaced
#   WORK  the work folder, removed at the end
#
# As in scripts/install.sh, the new copy is made beside the old one and two
# moves swap them; if any step fails the old Monad stays (or goes back) and
# opens again.

say() { printf 'monad-update: %s\n' "$*"; }

plist_value() { # FILE KEY
    plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

main() {
    [ $# -eq 4 ] || {
        echo "usage: monad-update.sh PID NEW DEST WORK" >&2
        exit 2
    }
    pid=$1 new=$2 dest=$3 work=$4
    wait_for=${MONAD_UPDATE_WAIT:-120}
    staged="$dest.new" aside="$dest.old"
    trap 'rm -rf "$work"' EXIT

    i=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$i" -ge "$wait_for" ]; then
            say "Monad (pid $pid) did not quit in $wait_for s: not updated"
            exit 1
        fi
        sleep 1
        i=$((i + 1))
    done

    id=$(plist_value "$dest/Contents/Info.plist" CFBundleIdentifier)
    new_id=$(plist_value "$new/Contents/Info.plist" CFBundleIdentifier)
    if [ -z "$id" ] || [ "$id" != "$new_id" ]; then
        say "$dest is '${id:-not an app}' and the update '${new_id:-not an app}': not updated"
        exit 1
    fi
    version=$(plist_value "$new/Contents/Info.plist" CFBundleShortVersionString)

    rm -rf "$staged" "$aside"
    if ! ditto "$new" "$staged"; then
        rm -rf "$staged"
        reopen "cannot copy the update next to $dest"
    fi
    xattr -dr com.apple.quarantine "$staged" 2>/dev/null || true
    if xattr -p com.apple.quarantine "$staged" >/dev/null 2>&1; then
        rm -rf "$staged"
        reopen "cannot remove the quarantine flag from $staged"
    fi
    mv "$dest" "$aside" || {
        rm -rf "$staged"
        reopen "cannot move $dest aside"
    }
    if ! mv "$staged" "$dest"; then
        mv "$aside" "$dest"
        rm -rf "$staged"
        reopen "cannot move the update into $dest"
    fi
    rm -rf "$aside"
    say "Monad ${version:-?} is in $dest"
    open "$dest"
}

reopen() { # WHY: the old Monad stays; open it again
    say "$1: Monad stays as it was"
    open "$dest"
    exit 1
}

main "$@"
