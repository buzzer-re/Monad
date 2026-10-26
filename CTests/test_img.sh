#!/bin/sh
# Tests for Monad/Guest/monad-img.sh (img in every VM): each picture goes
# out as one iTerm2 inline image (OSC 1337), its base64 on one line whatever
# the base64 and wc it finds (GNU, busybox or BSD); what is not a PNG, JPEG
# or GIF, or is larger than Monad shows, is said on stderr and the others
# still show. Expected encodings were made apart from the script (Python).
# Usage: test_img.sh [workdir]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../Monad/Guest/monad-img.sh"
SH=${IMG_SHELL:-sh}
SH_PATH=$(command -v "$SH")
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

ESC=$(printf '\033')
BEL=$(printf '\007')
image() { # image SIZE BASE64: what img prints for one picture
    printf '%s]1337;File=size=%s;inline=1:%s%s' "$ESC" "$1" "$2" "$BEL"
}
run() { # run ARGS... (stdin as given, PATH from RUNPATH): out, err, st
    out=$(PATH="${RUNPATH:-$PATH}" "$SH_PATH" "$SCRIPT" "$@" 2>"$WORK/err")
    st=$?
    err=$(cat "$WORK/err")
}

echo "img tests ($SH)" >&2
cd "$WORK"
# 66 bytes: GNU base64 wraps its 88 characters.
printf 'GIF89a%s' xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx >cat.gif
GIF=$(image 66 R0lGODlheHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4)
printf '\211PNG\r\n\032\n%s' 01234567890123456789012345678901234567890123456789 >"two words.png"
PNG=$(image 58 iVBORw0KGgowMTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDEyMzQ1Njc4OQ==)
printf '\377\330\377\340JFIF' >photo.jpg
JPEG=$(image 8 /9j/4EpGSUY=)
printf 'just text\n' >notes.txt

run cat.gif
check "gif: status" 0 "$st"
check "gif: one line" "$GIF" "$out"
check "gif: quiet" "" "$err"

run "two words.png" photo.jpg
check "two: status" 0 "$st"
check "two: in order" "$PNG
$JPEG" "$out"

run <cat.gif
check "stdin: status" 0 "$st"
check "stdin" "$GIF" "$out"

run notes.txt cat.gif
check "not a picture: status" 1 "$st"
check "not a picture: the others show" "$GIF" "$out"
check "not a picture: says so" "img: notes.txt: not a PNG, JPEG or GIF picture" "$err"

run missing.png photo.jpg
check "missing: status" 1 "$st"
check "missing: the others show" "$JPEG" "$out"
check "missing: says so" "img: missing.png: cannot be read" "$err"

run </dev/null
check "empty stdin: status" 1 "$st"
check "empty stdin: says so" "img: stdin: not a PNG, JPEG or GIF picture" "$err"

{ printf '\211PNG\r\n\032\n'; dd if=/dev/zero bs=1024 count=4096 2>/dev/null; } >big.png
run big.png
check "over 4 MB: status" 1 "$st"
check "over 4 MB: nothing" "" "$out"
check "over 4 MB: says so" "img: big.png: larger than 4 MB, which Monad does not show" "$err"

# BSD tools (a macOS guest): base64 never wraps, wc pads its count.
BSD="$WORK/bsd"
mkdir -p "$BSD"
real_base64=$(command -v base64)
real_wc=$(command -v wc)
printf '#!/bin/sh\n"%s" "$@" | tr -d "\\n"; echo\n' "$real_base64" >"$BSD/base64"
printf '#!/bin/sh\n"%s" "$@" | awk '"'"'{ printf "%%8s\\n", $1 }'"'"'\n' "$real_wc" >"$BSD/wc"
chmod +x "$BSD/base64" "$BSD/wc"
check "bsd: wc pads" "      66" "$(PATH="$BSD:$PATH" wc -c <cat.gif)"
RUNPATH="$BSD:$PATH"
run cat.gif
RUNPATH=""
check "bsd: status" 0 "$st"
check "bsd: one line" "$GIF" "$out"

printf 'img tests (%s): %d checks, %d failures\n' "$SH" "$checks" "$failures" >&2
[ "$failures" -eq 0 ]
