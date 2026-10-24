#!/bin/sh
# monad-macsetup — Monad's one root step for a new macOS VM (Phase 14),
# started from Monad.app through macOS's own password prompt:
#     monad-macsetup.sh <the VM's disk> <its staged files> <the user's uid>
# It puts Monad's one-time first-boot job (and what it needs) into the new
# disk, so the VM sets itself up with no setup screens (MacSetup.swift).
#
# What makes running as root safe here:
#  - The disk and the staged files are copied first into a folder only root
#    can write (an APFS clone of the disk), and checked there: plain files
#    belonging to the user (a link, or someone else's file, is refused).
#    Nothing the user's programs do meanwhile reaches what root works on.
#  - Inside the disk every directory on the way is checked not to be a link
#    before anything is written; the disk is mounted nosuid, nodev, hidden.
#  - Root never writes into the user's folders: the finished disk is left in
#    the work folder, handed to the user, and Monad (as the user) moves it.
#  - Nothing in the work folder is removed or handed over while the new
#    Mac's volume may still be mounted in it (a failed umount stops the step).
# Prints "monad-setup-done <folder>" or "monad-setup-failed: <why>".
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077

PAYLOAD_FILES="account password authorized_keys sudoers sshd.conf firstboot.sh dev.monad.setup.plist dev.monad.guestd.plist dev.monad.sshd.plist guestd agent"
SETUP_DIR=usr/local/libexec/monad/setup

# --- checks (also sourced by the tests: MONAD_MACSETUP_LIB=1) ---------------

file_uid() { if [ "$(uname)" = Darwin ]; then stat -f %u "$1"; else stat -c %u "$1"; fi; }

# A plain file (not a link) belonging to $2.
owned_regular() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ "$(file_uid "$1")" = "$2" ]
}

# $1/$2 made a real directory, no step on the way a link (made 755 where missing).
safe_dir() {
    cur=$1
    rest=$2
    while [ -n "$rest" ]; do
        part=${rest%%/*}
        if [ "$part" = "$rest" ]; then rest=""; else rest=${rest#*/}; fi
        [ -z "$part" ] && continue
        case "$part" in .|..) return 1 ;; esac
        cur="$cur/$part"
        [ -L "$cur" ] && return 1
        if [ ! -e "$cur" ]; then
            mkdir -m 755 "$cur" || return 1
            [ "$(id -u)" = 0 ] && chown 0:0 "$cur"
        fi
        [ -d "$cur" ] || return 1
    done
    return 0
}

# Copy $1 to $2/$3 with mode $4, owned by root; refused if the way or the
# target is a link.
put() {
    dir=$(dirname "$3")
    safe_dir "$2" "$dir" || return 1
    [ -L "$2/$3" ] && return 1
    [ -e "$2/$3" ] && { [ -f "$2/$3" ] || return 1; }
    cp "$1" "$2/$3.monad-new" || return 1
    chmod "$4" "$2/$3.monad-new" || return 1
    [ "$(id -u)" = 0 ] && chown 0:0 "$2/$3.monad-new"
    mv -f "$2/$3.monad-new" "$2/$3"
}

# The Data volume of the APFS container on store $1, from `diskutil apfs list`.
data_volume() {
    awk -v store="$1" '
        /^\+-- Container/ { inside = 0 }
        /APFS Physical Store Disk:/ { inside = ($NF == store) }
        inside && /APFS Volume Disk \(Role\):/ && /\(Data\)/ {
            for (i = 1; i <= NF; i++) if ($i ~ /^disk[0-9]+s[0-9]+$/) { print $i; exit }
        }'
}

# --- the step's parts (sourced by the tests too) --------------------------------

work=""
attached=""
mounted=""
# Unmounts the new Mac's Data volume and detaches its disk. Fails, and keeps
# them, if the volume is still in use: then nothing in it may be removed.
cleanup() {
    if [ -n "$mounted" ]; then
        umount "$mounted" >/dev/null 2>&1 || return 1
        mounted=""
    fi
    if [ -n "$attached" ]; then
        hdiutil detach "/dev/$attached" >/dev/null 2>&1 || return 1
        attached=""
    fi
    return 0
}
# True once the volume is unmounted for certain: its mount point (if made)
# empty again, and gone.
unmounted() {
    cleanup || return 1
    if [ -n "$work" ] && [ -e "$work/mnt" ]; then rmdir "$work/mnt" 2>/dev/null || return 1; fi
    return 0
}
# The work folder goes, unless the volume may still be mounted in it: root
# never removes what may be the new Mac's files. Then it stays, and says where.
fail() {
    if unmounted; then
        echo "monad-setup-failed: $*"
        [ -n "$work" ] && rm -rf "$work"
    else
        echo "monad-setup-failed: $* (its folder is left at $work)"
    fi
    exit 1
}

# Copies first, checks on the copies: $disk and $payload into $work, both
# the user's ($uid).
stage() {
    owned_regular "$disk" "$uid" || fail "the VM's disk is not a plain file of yours"
    cp -c "$disk" "$work/disk.raw" || fail "cannot copy the VM's disk (it must be on the same volume as /private/tmp)"
    owned_regular "$work/disk.raw" "$uid" || fail "the VM's disk changed while it was copied"
    cp -RPp "$payload" "$work/payload" || fail "cannot copy the staged files"
    [ -d "$work/payload" ] && [ ! -L "$work/payload" ] || fail "the staged files are not a folder"
    for name in $PAYLOAD_FILES; do
        owned_regular "$work/payload/$name" "$uid" || fail "$name is not a plain file of yours"
    done
}

# The end: the volume unmounted for certain before anything in $work is
# removed or handed to the user.
finish() {
    sync
    unmounted || fail "the new Mac's disk is still in use; try again"
    rm -rf "$work/payload" "$work/empty"
    # Handed to the user: Monad moves the disk into place itself.
    chown -R "$uid" "$work" || fail "cannot hand the disk back"
    echo "monad-setup-done $work"
}

[ "${MONAD_MACSETUP_LIB:-}" = 1 ] && return 0 2>/dev/null

# --- the step ------------------------------------------------------------------

[ $# -eq 3 ] || fail "usage: monad-macsetup.sh <disk> <staged files> <uid>"
disk=$1
payload=$2
uid=$3
[ "$(id -u)" = 0 ] || fail "this step runs with your password, as the Mac's administrator"
case "$uid" in ''|*[!0-9]*) fail "not a user id: $uid" ;; esac
[ "$uid" -gt 0 ] || fail "not a user id: $uid"

work=$(mktemp -d /private/tmp/monad-macsetup.XXXXXX) || fail "cannot make a work folder"
chmod 700 "$work"

stage

# The new Mac's Data volume, mounted where only root looks.
out=$(hdiutil attach -nomount -noverify -noautofsck -imagekey diskimage-class=CRawDiskImage "$work/disk.raw") \
    || fail "cannot attach the VM's disk"
attached=$(echo "$out" | awk 'NR == 1 { sub("^/dev/", "", $1); print $1 }')
store=$(echo "$out" | awk '$2 == "Apple_APFS" { sub("^/dev/", "", $1); print $1; exit }')
[ -n "$store" ] || fail "the VM's disk has no APFS container (is macOS installed?)"
vol=$(diskutil apfs list | data_volume "$store")
[ -n "$vol" ] || fail "the VM's disk has no Data volume (is macOS installed?)"
mkdir -m 700 "$work/mnt"
mount_apfs -o nobrowse,nosuid,nodev "/dev/$vol" "$work/mnt" || fail "cannot open the VM's Data volume"
mounted="$work/mnt"

p="$work/payload"
m="$work/mnt"
for name in account password authorized_keys sudoers sshd.conf dev.monad.guestd.plist dev.monad.sshd.plist agent; do
    put "$p/$name" "$m" "$SETUP_DIR/$name" 600 || fail "cannot write $name"
done
put "$p/firstboot.sh" "$m" "$SETUP_DIR/firstboot.sh" 700 || fail "cannot write firstboot.sh"
put "$p/guestd" "$m" "$SETUP_DIR/guestd" 755 || fail "cannot write guestd"
put "$p/dev.monad.setup.plist" "$m" "Library/LaunchDaemons/dev.monad.setup.plist" 644 || fail "cannot write the setup job"
: > "$work/empty"
put "$work/empty" "$m" "private/var/db/.AppleSetupDone" 644 || fail "cannot mark setup done"

finish
