#!/bin/sh
#
# monad-disks.sh — formats and mounts a Linux VM's extra disks (the VM's
# settings › Disks › Format and mount), run by Monad as root after each
# boot. A disk Monad attached is /dev/disk/by-id/virtio-<name>. A blank one
# gets ext4 (labelled with its name) and is given to the user; one that has
# a filesystem is never formatted. Each goes in fstab by UUID with nofail
# (a VM whose disk was removed still boots) and is mounted at /mnt/<name>.
#
#   monad-disks.sh USER NAME…
#
# MONAD_DEV_DIR, MONAD_FSTAB and MONAD_MNT exist for its tests
# (CTests/test_disks.sh).

DEV=${MONAD_DEV_DIR:-/dev/disk/by-id}
FSTAB=${MONAD_FSTAB:-/etc/fstab}
MNT=${MONAD_MNT:-/mnt}

say() { printf 'monad-disks: %s\n' "$*"; }

valid_name() { # Monad's disk names (InstanceConfig): a-z, then a-z 0-9 -, 16 at most
    case "$1" in
        '' | [!a-z]* | *[!a-z0-9-]*) return 1 ;;
    esac
    [ "${#1}" -le 16 ]
}

valid_user() {
    case "$1" in
        '' | -* | *[!A-Za-z0-9._-]*) return 1 ;;
    esac
}

one() { # USER NAME
    user=$1 name=$2
    dev="$DEV/virtio-$name" dir="$MNT/$name"
    if [ ! -e "$dev" ]; then
        say "$name: not attached (no $dev)"
        return 1
    fi
    made=""
    if ! blkid "$dev" >/dev/null 2>&1; then
        mkfs.ext4 -q -L "$name" "$dev" || {
            say "$name: could not be formatted"
            return 1
        }
        made=yes
    fi
    uuid=$(blkid -s UUID -o value "$dev")
    [ -n "$uuid" ] || {
        say "$name: has no UUID to mount it by"
        return 1
    }
    mkdir -p "$dir"
    grep -q "^UUID=$uuid " "$FSTAB" || printf 'UUID=%s %s ext4 defaults,nofail 0 2\n' "$uuid" "$dir" >>"$FSTAB"
    if ! mountpoint -q "$dir"; then
        mount "$dir" || {
            say "$name: could not be mounted at $dir"
            return 1
        }
    fi
    if [ -n "$made" ]; then
        chown "$user:" "$dir"
        say "$name: formatted (ext4) and mounted at $dir"
    else
        say "$name: mounted at $dir"
    fi
}

main() {
    [ $# -ge 2 ] || {
        echo "usage: monad-disks.sh USER NAME..." >&2
        exit 2
    }
    user=$1
    shift
    valid_user "$user" || {
        echo "monad-disks: not a user name: $user" >&2
        exit 2
    }
    for n; do
        valid_name "$n" || {
            echo "monad-disks: not a disk name: $n" >&2
            exit 2
        }
    done
    st=0
    for n; do one "$user" "$n" || st=1; done
    exit $st
}

main "$@"
