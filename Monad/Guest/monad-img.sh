#!/bin/sh
# monad-img.sh — img: pictures in a Monad tab. Monad installs it as
# /usr/local/bin/img in every VM, Linux or macOS, again at each boot, and
# never over an img that is not this one.
#
# Each picture goes out as iTerm2's inline image (OSC 1337), which Monad
# shows only when the VM's "Images in the terminal" is on (its window ›
# Overview): PNG, JPEG or GIF, at most 4 MB. GNU, busybox and BSD tools
# alike: base64's lines are joined, wc's padding goes. Tested by
# CTests/test_img.sh.
# Usage: img FILE...   or   command | img

set -u
MAX=4194304

show() { # show FILE NAME
    case $(od -An -tx1 -N4 "$1" | tr -d ' \n') in
        89504e47 | ffd8ff* | 47494638) ;;
        *)
            echo "img: $2: not a PNG, JPEG or GIF picture" >&2
            return 1
            ;;
    esac
    size=$(wc -c <"$1" | tr -d ' ')
    if [ "$size" -gt "$MAX" ]; then
        echo "img: $2: larger than 4 MB, which Monad does not show" >&2
        return 1
    fi
    printf '\033]1337;File=size=%s;inline=1:' "$size"
    base64 <"$1" | tr -d '\n'
    printf '\a\n'
}

if [ $# -eq 0 ]; then
    if [ -t 0 ]; then
        echo "usage: img FILE...   or   command | img" >&2
        exit 2
    fi
    tmp=$(mktemp) || exit 1
    trap 'rm -f "$tmp"' EXIT
    cat >"$tmp"
    show "$tmp" stdin
    exit
fi

status=0
for f in "$@"; do
    if [ -f "$f" ] && [ -r "$f" ]; then
        show "$f" "$f" || status=1
    else
        echo "img: $f: cannot be read" >&2
        status=1
    fi
done
exit "$status"
