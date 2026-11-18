#!/bin/sh
# Monad: builds the VM's window manager (monad-wm, which shows the VM's
# programs as windows on the Mac) from the C sources Monad put beside this
# script, with the distribution's own C compiler: Monad ships no program
# for Linux that it did not build, and a Mac cannot build one.
#
# Run as root by Monad's installer at each boot and by the Windows profile.
# Builds only when the sources are not the ones the program was built
# from, so a boot with nothing new costs one checksum. Prints "built" when
# it did build (the service is then to be restarted).
#
#   monad-wm-build [DIRECTORY]      default /usr/local/lib/monad
#
# Exits 0 when the program is there and current, 69 when there is no C
# compiler or no sources, the compiler's status when it fails (the program
# that was there stays).
set -u
lib=${1:-/usr/local/lib/monad}
src="$lib/wm"
if ! ls "$src"/*.c >/dev/null 2>&1; then
    echo "monad-wm-build: Monad has put no sources in $src (it does for a VM whose Display is on)" >&2
    exit 69
fi
if ! command -v cc >/dev/null 2>&1; then
    echo "monad-wm-build: this VM has no C compiler (cc); the Windows profile installs one" >&2
    exit 69
fi
# The sources' names and contents: a file added, removed or changed is a new build.
sum=$(for f in "$src"/*.c "$src"/*.h; do [ -f "$f" ] && { echo "${f##*/}"; cat "$f"; }; done | sha256sum | cut -d' ' -f1)
if [ -x "$lib/monad-wm" ] && [ "$(cat "$lib/monad-wm.built" 2>/dev/null)" = "$sum" ]; then
    exit 0
fi
tmp="$lib/monad-wm.new"
rm -f "$tmp"
cc -std=gnu11 -O2 -o "$tmp" "$src"/*.c
status=$?
if [ "$status" -ne 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    echo "monad-wm-build: the compiler failed (status $status)" >&2
    [ "$status" -ne 0 ] || status=70
    exit "$status"
fi
chmod 755 "$tmp" && mv -f "$tmp" "$lib/monad-wm" && printf '%s\n' "$sum" > "$lib/monad-wm.built" || exit 73
echo built
