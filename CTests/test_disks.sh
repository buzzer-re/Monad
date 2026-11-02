#!/bin/sh
# Tests for Monad/Guest/monad-disks.sh, which formats and mounts a Linux
# VM's extra disks (Add Disk › Format and mount): a blank disk becomes ext4
# and is mounted at /mnt/<name> for good (fstab, by UUID); a disk with a
# filesystem is never formatted. Stand-ins for blkid, mkfs.ext4, mount,
# mountpoint and chown. Usage: test_disks.sh [workdir]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DISKS="$HERE/../Monad/Guest/monad-disks.sh"
SH=${DISKS_SHELL:-sh}
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
mkdir -p "$BIN"
stub() { # stub NAME (body on stdin)
    { echo '#!/bin/sh'; echo 'echo "'"$1"' $*" >>"$FAKE/log"'; cat; } >"$BIN/$1"
    chmod +x "$BIN/$1"
}
# A device is a file in $FAKE/dev; its filesystem's UUID is in DEVICE.fs.
stub blkid <<'EOF'
for a; do dev=$a; done
[ -s "$dev.fs" ] || exit 2
case "$*" in
    *"-o value"*) cat "$dev.fs" ;;
    *) echo "$dev: UUID=\"$(cat "$dev.fs")\" TYPE=\"ext4\"" ;;
esac
EOF
stub mkfs.ext4 <<'EOF'
for a; do dev=$a; done
echo "uuid-$(basename "$dev")" >"$dev.fs"
EOF
# mount MOUNTPOINT: by fstab; mounted points are lines in $FAKE/mounted.
stub mount <<'EOF'
grep -q " $1 " "$MONAD_FSTAB" || exit 32
echo "$1" >>"$FAKE/mounted"
EOF
stub mountpoint <<'EOF'
for a; do m=$a; done
grep -qx "$m" "$FAKE/mounted" 2>/dev/null
EOF
stub chown <<'EOF'
:
EOF

FAKE="$WORK/fake"
reset() {
    rm -rf "$FAKE"
    mkdir -p "$FAKE/dev" "$FAKE/mnt"
    : >"$FAKE/log"
    printf 'UUID=root / ext4 defaults 0 1\n' >"$FAKE/fstab"
}
disk() { : >"$FAKE/dev/virtio-$1"; } # a blank disk
run() { # run ARGS…
    env PATH="$BIN:$PATH" FAKE="$FAKE" MONAD_DEV_DIR="$FAKE/dev" MONAD_FSTAB="$FAKE/fstab" MONAD_MNT="$FAKE/mnt" \
        $SH "$DISKS" "$@" >"$WORK/out" 2>&1
    st=$?
}

# A blank disk: formatted with its name as label, in fstab by UUID (nofail,
# so a VM without it still boots), mounted, and given to the user.
reset
disk data
run dev data
check "blank: ok" 0 "$st"
check "blank: formatted" "mkfs.ext4 -q -L data $FAKE/dev/virtio-data" "$(grep '^mkfs' "$FAKE/log")"
check "blank: in fstab" "UUID=uuid-virtio-data $FAKE/mnt/data ext4 defaults,nofail 0 2" "$(tail -1 "$FAKE/fstab")"
check "blank: mounted" "$FAKE/mnt/data" "$(cat "$FAKE/mounted")"
check "blank: the user's" "chown dev: $FAKE/mnt/data" "$(grep '^chown' "$FAKE/log")"
check "blank: says so" "monad-disks: data: formatted (ext4) and mounted at $FAKE/mnt/data" "$(cat "$WORK/out")"

# Every boot after: nothing formatted again, fstab not grown, mounted once.
: >"$FAKE/log"
run dev data
check "again: ok" 0 "$st"
check "again: no format" "" "$(grep '^mkfs' "$FAKE/log")"
check "again: one fstab line" 1 "$(grep -c "/mnt/data " "$FAKE/fstab")"
check "again: mounted once" 1 "$(grep -c . "$FAKE/mounted")"
check "again: no chown" "" "$(grep '^chown' "$FAKE/log")"

# A disk that has a filesystem (the user's, or another OS's) is never
# formatted: it is mounted as it is.
reset
disk old
echo "uuid-theirs" >"$FAKE/dev/virtio-old.fs"
run dev old
check "used: ok" 0 "$st"
check "used: never formatted" "" "$(grep '^mkfs' "$FAKE/log")"
check "used: mounted by its UUID" "UUID=uuid-theirs $FAKE/mnt/old ext4 defaults,nofail 0 2" "$(tail -1 "$FAKE/fstab")"

# A disk not attached (yet): said, the others still done.
reset
disk two
run dev one two
check "missing: fails" 1 "$st"
check "missing: said" "monad-disks: one: not attached (no $FAKE/dev/virtio-one)" "$(head -1 "$WORK/out")"
check "missing: the next one done" yes "$(grep -q 'two: formatted' "$WORK/out" && echo yes || echo no)"

# Names reach paths and fstab: only Monad's disk names.
reset
run dev '../etc' 'a b' 'X'
check "bad names: refused" 2 "$st"
check "bad names: nothing done" "" "$(cat "$FAKE/log")"
run 'r;oot' data
check "bad user: refused" 2 "$st"

$SH "$DISKS" >/dev/null 2>&1
check "usage" 2 "$?"

printf 'monad-disks tests (%s): %d checks, %d failures\n' "$SH" "$checks" "$failures" >&2
[ "$failures" -eq 0 ]
