#!/bin/sh
# Tests for the checks of Monad's root step for macOS VMs
# (Monad/Guest/monad-macsetup.sh, Phase 14), as the user, in a scratch tree.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${1:-$(mktemp -d)}
rm -rf "$WORK"
mkdir -p "$WORK"
checks=0
failures=0
check() { # check NAME EXPECTED ACTUAL
    checks=$((checks + 1))
    if [ "$2" != "$3" ]; then
        failures=$((failures + 1))
        printf '%s: FAIL\n--- expected\n%s\n--- got\n%s\n' "$1" "$2" "$3" >&2
    fi
}
ok() { if "$@"; then echo yes; else echo no; fi; }

MONAD_MACSETUP_LIB=1
. "$HERE/../Monad/Guest/monad-macsetup.sh"
echo "monad-macsetup tests" >&2
me=$(id -u)

echo data > "$WORK/file"
ln -s "$WORK/file" "$WORK/link"
mkdir "$WORK/dir"
check plain-file yes "$(ok owned_regular "$WORK/file" "$me")"
check link no "$(ok owned_regular "$WORK/link" "$me")"
check folder no "$(ok owned_regular "$WORK/dir" "$me")"
check someone-else no "$(ok owned_regular "$WORK/file" 12345)"

root="$WORK/vol"
mkdir -p "$root/Library"
check makes-the-way yes "$(ok safe_dir "$root" "usr/local/libexec/monad/setup")"
check made "yes" "$( [ -d "$root/usr/local/libexec/monad/setup" ] && echo yes || echo no)"
ln -s /etc "$root/private"
check link-on-the-way no "$(ok safe_dir "$root" "private/var/db")"
check dot-dot no "$(ok safe_dir "$root" "usr/../../escape")"

check put yes "$(ok put "$WORK/file" "$root" "usr/local/libexec/monad/setup/account" 600)"
check put-content data "$(cat "$root/usr/local/libexec/monad/setup/account")"
if [ "$(uname)" = Darwin ]; then mode=$(stat -f %Lp "$root/usr/local/libexec/monad/setup/account"); else mode=$(stat -c %a "$root/usr/local/libexec/monad/setup/account"); fi
check put-mode 600 "$mode"
check put-through-link no "$(ok put "$WORK/file" "$root" "private/var/db/.AppleSetupDone" 644)"
ln -s "$WORK/elsewhere" "$root/Library/target.plist"
check put-onto-link no "$(ok put "$WORK/file" "$root" "Library/target.plist" 644)"
check nothing-written-there no "$( [ -e "$WORK/elsewhere" ] && echo yes || echo no)"

check data-volume disk8s5 "$(data_volume disk7s2 < "$HERE/agent_fixtures/diskutil_apfs_list.txt")"
check not-this-mac "" "$(data_volume disk9s2 < "$HERE/agent_fixtures/diskutil_apfs_list.txt")"

# --- the step's copies and its end, with stand-ins on PATH ------------------

FAKE="$WORK/fake"
mkdir -p "$FAKE"
# umount and hdiutil fail while $WORK/busy exists (a volume still in use);
# an unmount takes the volume's files out of the mount point.
real_umount() {
    cat > "$FAKE/umount" <<EOF
#!/bin/sh
echo "umount \$*" >> "$WORK/calls"
[ ! -e "$WORK/busy" ] || exit 1
rm -rf "$WORK/volume"
mkdir "$WORK/volume"
mv "\$1"/* "$WORK/volume/" 2>/dev/null
exit 0
EOF
    chmod +x "$FAKE/umount"
}
real_umount
cat > "$FAKE/hdiutil" <<EOF
#!/bin/sh
echo "hdiutil \$*" >> "$WORK/calls"
[ ! -e "$WORK/busy" ]
EOF
# chown: only says it was called.
cat > "$FAKE/chown" <<EOF
#!/bin/sh
echo "chown \$*" >> "$WORK/calls"
EOF
# cp -c clones as root does, the owner kept. Here the user's program swaps
# the disk for a link to someone else's file just before the clone; the
# stand-in notes the owner a root clone would keep, and stat reports it.
cat > "$FAKE/cp" <<EOF
#!/bin/sh
if [ "\$1" = -c ]; then
    if [ -e "$WORK/swap" ]; then rm -f "\$2"; ln -s "\$(cat "$WORK/swap")" "\$2"; fi
    /bin/cp "\$2" "\$3" || exit 1
    if [ "\$(uname)" = Darwin ]; then /usr/bin/stat -L -f %u "\$2"; else stat -L -c %u "\$2"; fi > "\$3.owner"
    exit 0
fi
exec /bin/cp "\$@"
EOF
cat > "$FAKE/stat" <<EOF
#!/bin/sh
for last; do :; done
[ -f "\$last.owner" ] && exec cat "\$last.owner"
for d in /usr/bin /bin; do [ -x "\$d/stat" ] && exec "\$d/stat" "\$@"; done
exit 1
EOF
chmod +x "$FAKE"/*

# A work folder as the step has it before its end: the new Mac's Data
# volume mounted on mnt (here a folder with a file in it).
new_work() {
    rm -rf "$WORK/w" "$WORK/calls" "$WORK/busy" "$WORK/swap"
    mkdir -p "$WORK/w/mnt/Users" "$WORK/w/payload"
    echo keep > "$WORK/w/mnt/Users/file"
    echo disk > "$WORK/w/disk.raw"
    : > "$WORK/calls"
}
# Runs a function of the step in a subshell, as the step has it then.
step() { (PATH="$FAKE:$PATH"; work="$WORK/w"; mounted="$work/mnt"; attached=disk9; uid=$me; "$@") 2>&1; }

new_work
out=$(step finish)
check done "monad-setup-done $WORK/w" "$out"
check done-unmounted "umount $WORK/w/mnt" "$(head -n 1 "$WORK/calls")"
check done-mnt-gone no "$( [ -e "$WORK/w/mnt" ] && echo yes || echo no)"
check done-chowned "chown -R $me $WORK/w" "$(grep '^chown' "$WORK/calls")"
check done-volume-whole keep "$(cat "$WORK/volume/Users/file" 2>&1)"

# The volume is still in use: nothing in it is removed or handed over, and
# the folder is left for a look.
new_work
: > "$WORK/busy"
out=$(step finish)
check busy-fails "monad-setup-failed: the new Mac's disk is still in use; try again (its folder is left at $WORK/w)" "$out"
check busy-kept keep "$(cat "$WORK/w/mnt/Users/file" 2>&1)"
check busy-disk-kept disk "$(cat "$WORK/w/disk.raw" 2>&1)"
check busy-not-chowned "" "$(grep '^chown' "$WORK/calls")"

# umount says it worked, but the volume is still there: the same.
new_work
cat > "$FAKE/umount" <<EOF
#!/bin/sh
echo "umount \$*" >> "$WORK/calls"
EOF
chmod +x "$FAKE/umount"
out=$(step finish)
check still-there "monad-setup-failed: the new Mac's disk is still in use; try again (its folder is left at $WORK/w)" "$out"
check still-there-kept keep "$(cat "$WORK/w/mnt/Users/file" 2>&1)"
check still-there-not-chowned "" "$(grep '^chown' "$WORK/calls")"
real_umount

# Any failure while the volume is mounted leaves the folder too…
new_work
: > "$WORK/busy"
out=$(step fail "cannot write guestd")
check fail-mounted "monad-setup-failed: cannot write guestd (its folder is left at $WORK/w)" "$out"
check fail-mounted-kept keep "$(cat "$WORK/w/mnt/Users/file" 2>&1)"
# …and once unmounted it is removed, as before.
new_work
out=$(step fail "cannot write guestd")
check fail-unmounted "monad-setup-failed: cannot write guestd" "$out"
check fail-removed no "$( [ -e "$WORK/w" ] && echo yes || echo no)"

# The copies: the disk swapped for a link to someone else's file between
# the owner check and the clone is refused.
staged="$WORK/staged"
rm -rf "$staged"
mkdir -p "$staged/payload"
for name in $PAYLOAD_FILES; do echo x > "$staged/payload/$name"; done
echo disk > "$staged/disk.raw"
stage_step() {
    rm -rf "$WORK/w"
    mkdir -p "$WORK/w"
    (PATH="$FAKE:$PATH"; work="$WORK/w"; mounted=""; attached=""; uid=$me
     disk="$staged/disk.raw"; payload="$staged/payload"; stage && echo staged) 2>&1
}
check stage-plain staged "$(stage_step)"
other=/etc/hosts # someone else's file, unless the tests run as root
if [ "$(file_uid "$other")" != "$me" ]; then
    echo "$other" > "$WORK/swap"
    check stage-swapped "monad-setup-failed: the VM's disk changed while it was copied" "$(stage_step)"
    rm -f "$WORK/swap"
fi

# The script refuses to run without root, saying so.
out=$(sh "$HERE/../Monad/Guest/monad-macsetup.sh" "$WORK/file" "$WORK/dir" "$me" 2>&1)
case "$(id -u)" in
    0) ;;
    *) check needs-root "monad-setup-failed: this step runs with your password, as the Mac's administrator" "$out" ;;
esac

echo "$checks checks, $failures failures" >&2
[ "$failures" -eq 0 ]
