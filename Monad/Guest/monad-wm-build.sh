#!/bin/sh
# Monad: builds the VM's window manager (monad-wm, which shows the VM's
# programs as windows on the Mac) from the C sources Monad put beside this
# script, with the distribution's own C compiler: Monad ships no program
# for Linux that it did not build, and a Mac cannot build one.
#
# Beside it, from the sources in gl/, the library the VM's programs draw
# with the Mac's GPU through (libEGL.so.1 and libGLESv2.so.2, in gl/lib:
# only programs started for Monad's windows look there, and only while
# the Mac is there to draw). It is built the same way; nothing is said
# for it and its failing is no failure here: programs then draw as before.
#
# Run as root by Monad's installer at each boot and by the App windows profile.
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
    echo "monad-wm-build: Monad has put no sources in $src (it does when the VM starts)" >&2
    exit 69
fi
if ! command -v cc >/dev/null 2>&1; then
    echo "monad-wm-build: this VM has no C compiler (cc); the App windows profile installs one" >&2
    exit 69
fi
# The drawing library: its sources, and the protocol it shares with the window manager.
gl="$lib/gl"
if ls "$gl"/*.c >/dev/null 2>&1; then
    glsum=$(for f in "$gl"/*.c "$gl"/*.h "$src/mwm_gl_wire.h"; do [ -f "$f" ] && { echo "${f##*/}"; cat "$f"; }; done | sha256sum | cut -d' ' -f1)
    if [ ! -s "$gl/lib/libmonad-gl.so" ] || [ "$(cat "$gl/built" 2>/dev/null)" != "$glsum" ]; then
        mkdir -p "$gl/lib"
        new="$gl/lib/libmonad-gl.so.new"
        rm -f "$new"
        cc -std=gnu11 -O2 -fPIC -shared -fvisibility=hidden -I"$src" -o "$new" "$gl"/*.c -ldl -lpthread
        glstatus=$?
        if [ "$glstatus" -eq 0 ] && [ -s "$new" ] && chmod 755 "$new" && mv -f "$new" "$gl/lib/libmonad-gl.so" \
            && ln -sf libmonad-gl.so "$gl/lib/libEGL.so.1" && ln -sf libmonad-gl.so "$gl/lib/libGLESv2.so.2"; then
            printf '%s\n' "$glsum" > "$gl/built"
        else
            rm -f "$new"
            echo "monad-wm-build: the library programs draw with the Mac's GPU through did not build (status $glstatus): they go on as before" >&2
        fi
    fi
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
