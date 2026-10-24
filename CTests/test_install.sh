#!/bin/sh
# Tests for scripts/install.sh (and the archive `release.sh package` makes
# for it) with stand-ins for curl, ditto, codesign, xattr, plutil,
# launchctl, osascript, open and xcodebuild, so they run on Linux too.
# A quarantine flag is a `.quarantine` file in the app, a broken signature
# a `.badsig` file. Usage: test_install.sh [workdir]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPTS="$HERE/../scripts"
SH=${INSTALL_SHELL:-sh}
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

check_has() { # check_has NAME NEEDLE HAYSTACK
    checks=$((checks + 1))
    case "$3" in
        *"$2"*) ;;
        *) failures=$((failures + 1))
           printf '%s: FAIL\n--- missing\n%s\n--- in\n%s\n' "$1" "$2" "$3" >&2 ;;
    esac
}

check_lacks() { # check_lacks NAME NEEDLE HAYSTACK
    checks=$((checks + 1))
    case "$3" in
        *"$2"*) failures=$((failures + 1))
           printf '%s: FAIL\n--- unexpected\n%s\n--- in\n%s\n' "$1" "$2" "$3" >&2 ;;
    esac
}

# --- stand-ins ---------------------------------------------------------------

BIN="$WORK/bin"
mkdir -p "$BIN"
stub() { # stub NAME (body on stdin)
    { echo '#!/bin/sh'; echo 'echo "'"$1"' $*" >>"$FAKE_STATE/log"'; cat; } >"$BIN/$1"
    chmod +x "$BIN/$1"
}

stub uname <<'EOF'
echo "${FAKE_UNAME:-Darwin}"
EOF
stub sleep <<'EOF'
:
EOF
stub open <<'EOF'
:
EOF
# curl: /releases/latest answers with the URL it lands on ($FAKE_STATE/latest),
# /releases/download/TAG/FILE with $FAKE_STATE/releases/TAG/FILE.
stub curl <<'EOF'
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift ;;
        -w|--proto) shift ;;
        https://*) url=$1 ;;
    esac
    shift
done
case "$url" in
    */releases/latest)
        [ -s "$FAKE_STATE/latest" ] || exit 22
        cat "$FAKE_STATE/latest" ;;
    */releases/download/*)
        src="$FAKE_STATE/releases/${url#*/releases/download/}"
        [ -f "$src" ] || exit 22
        cp "$src" "$out" ;;
    *) exit 6 ;;
esac
EOF
stub shasum <<'EOF'
python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest() + "  " + sys.argv[1])' "$3"
EOF
# ditto: -x -k ZIP DIR, -c -k --keepParent SRC ZIP, or SRC DST.
stub ditto <<'EOF'
if [ "$1" = -x ]; then
    mkdir -p "$4" && unzip -q "$3" -d "$4"
elif [ "$1" = -c ]; then
    python3 - "$4" "$5" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
parent = os.path.dirname(os.path.abspath(src))
with zipfile.ZipFile(dst, "w") as z:
    for root, dirs, files in os.walk(src):
        for name in dirs + files:
            path = os.path.join(root, name)
            z.write(path, os.path.relpath(path, parent))
PY
else
    cp -R "$1" "$2"
fi
EOF
stub xattr <<'EOF'
case "$1" in
    -dr) find "$3" -name .quarantine -exec rm -f {} + ;;
    -p) [ -e "$3/.quarantine" ] || exit 1; echo 0081 ;;
esac
EOF
stub codesign <<'EOF'
for a; do last=$a; done
case "$1" in
    --verify) [ ! -e "$last/.badsig" ] ;;
    -dv) sed 's/^/Identifier=/' "$last" >&2 ;;
esac
EOF
stub plutil <<'EOF'
# plutil -extract KEY raw -o - FILE
v=$(sed -n "/<key>$2<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}" "$6")
[ -n "$v" ] && echo "$v"
EOF
# osascript: "true" while $FAKE_STATE/app_running counts down.
stub osascript <<'EOF'
n=$(cat "$FAKE_STATE/app_running" 2>/dev/null || echo 0)
if [ "$n" -gt 0 ]; then echo $((n - 1)) >"$FAKE_STATE/app_running"; echo true; else echo false; fi
EOF
# launchctl: a job while $FAKE_STATE/job exists, with a pid while
# $FAKE_STATE/host_running counts down.
stub launchctl <<'EOF'
case "$1" in
    print)
        [ -e "$FAKE_STATE/job" ] || exit 113
        n=$(cat "$FAKE_STATE/host_running" 2>/dev/null || echo 0)
        if [ "$n" -gt 0 ]; then echo $((n - 1)) >"$FAKE_STATE/host_running"; printf '\tpid = 4242\n'; fi
        printf '\tprogram = /old/MonadHost\n' ;;
    bootout) rm -f "$FAKE_STATE/job" ;;
    bootstrap) touch "$FAKE_STATE/job" ;;
esac
EOF
# xcodebuild: makes $FAKE_STATE/template.app the product.
stub xcodebuild <<'EOF'
dd=""
while [ $# -gt 0 ]; do
    [ "$1" = -derivedDataPath ] && { dd=$2; shift; }
    shift
done
[ "${FAKE_BUILD_FAILS:-0}" = 0 ] || { echo "Foo.swift:1: error: nope"; exit 65; }
mkdir -p "$dd/Build/Products/Release"
rm -rf "$dd/Build/Products/Release/Monad.app"
cp -R "$FAKE_STATE/template.app" "$dd/Build/Products/Release/Monad.app"
EOF
# mv: FAKE_MV=fail cannot move the new Monad into place; FAKE_MV=stop has
# the script stopped (TERM) just after the old one is moved aside.
stub mv <<'EOF'
case "${FAKE_MV:-}:$1" in
    fail:*.app.new) exit 1 ;;
    stop:*/Monad.app) PATH=/usr/bin:/bin mv "$@" && kill -TERM "$PPID"; exit ;;
esac
PATH=/usr/bin:/bin exec mv "$@"
EOF

# --- fixtures ----------------------------------------------------------------

make_app() { # make_app DIR BUNDLE_ID VERSION
    mkdir -p "$1/Contents/MacOS"
    cat >"$1/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$2</string>
	<key>CFBundleShortVersionString</key>
	<string>$3</string>
</dict>
</plist>
EOF
    printf '#!/bin/sh\n' >"$1/Contents/MacOS/Monad"
    echo "dev.monad.MonadHost" >"$1/Contents/MacOS/MonadHost"
    chmod +x "$1/Contents/MacOS/Monad" "$1/Contents/MacOS/MonadHost"
}

zip_app() { # zip_app APP ZIP
    (cd "$(dirname "$1")" && python3 - "$(basename "$1")" "$2" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w") as z:
    for root, dirs, files in os.walk(src):
        for name in dirs + files:
            z.write(os.path.join(root, name))
PY
    )
}

publish() { # publish TAG APP [SHA-256]: a release on the fake GitHub
    d="$STATE/releases/$1"
    mkdir -p "$d"
    zip_app "$2" "$d/Monad.zip"
    sum=${3:-$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$d/Monad.zip")}
    echo "$sum  Monad.zip" >"$d/Monad.zip.sha256"
}

STATE="$WORK/state"
DEST="$WORK/Applications"
REPO="$WORK/repo"
LOOSE="$WORK/loose"
mkdir -p "$REPO/scripts" "$REPO/Monad.xcodeproj" "$LOOSE"
cp "$SCRIPTS/install.sh" "$SCRIPTS/release.sh" "$REPO/scripts/"
cp "$SCRIPTS/install.sh" "$LOOSE/"
make_app "$WORK/fx/v09/Monad.app" dev.monad.Monad 0.9
make_app "$WORK/fx/v08/Monad.app" dev.monad.Monad 0.8
make_app "$WORK/fx/debug/Monad.app" dev.monad.Monad.debug 0.9
make_app "$WORK/fx/other/Monad.app" com.example.other 3.0

reset() {
    rm -rf "$STATE" "$DEST" "$REPO/build" "$WORK/home"
    mkdir -p "$STATE/releases" "$DEST" "$WORK/home"
    : >"$STATE/log"
    touch "$STATE/job"
    cp -R "$WORK/fx/v09/Monad.app" "$STATE/template.app"
}

run_in() { # run_in SCRIPT ARGS...: sets $out and $st
    script=$1
    shift
    out=$(cd "$WORK" && PATH="$BIN:$PATH" FAKE_STATE="$STATE" HOME="$WORK/home" \
        $SH "$script" --dest "$DEST" "$@" 2>&1)
    st=$?
}
run() { run_in "$REPO/scripts/install.sh" "$@"; }
version_of() { sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$1/Contents/Info.plist"; }

echo "install.sh tests ($SH)" >&2

# The latest release: found by where /releases/latest leads, downloaded by
# its tag, checked against its SHA-256, installed without quarantine, and
# opened once launchd's old MonadHost job is gone.
reset
publish v0.9 "$WORK/fx/v09/Monad.app"
echo "https://github.com/buzzer-re/Monad/releases/tag/v0.9" >"$STATE/latest"
run --release
check "latest: status" 0 "$st"
check "latest: installed" 0.9 "$(version_of "$DEST/Monad.app")"
log=$(cat "$STATE/log")
check "latest: zip by tag" 1 "$(grep -c ' https://github.com/buzzer-re/Monad/releases/download/v0.9/Monad.zip$' "$STATE/log")"
check_has "latest: sha by tag" " https://github.com/buzzer-re/Monad/releases/download/v0.9/Monad.zip.sha256" "$log"
check_has "latest: signature checked" "codesign --verify --deep --strict" "$log"
check_has "latest: quarantine removed" "xattr -dr com.apple.quarantine $DEST/Monad.app.new" "$log"
check_has "latest: old job gone" "launchctl bootout gui/" "$log"
check_has "latest: opened" "open $DEST/Monad.app" "$log"
check_has "latest: says the checksum matched" "SHA-256 matches" "$out"
check "latest: nothing left over" "Monad.app" "$(ls "$DEST")"

# A tag asked for; a tag that is not one never reaches curl.
reset
publish v0.8 "$WORK/fx/v08/Monad.app"
run --release v0.8 --no-open
check "tag: status" 0 "$st"
check "tag: installed" 0.8 "$(version_of "$DEST/Monad.app")"
check_lacks "tag: latest not asked" "releases/latest" "$(cat "$STATE/log")"
check_lacks "--no-open" "open " "$(cat "$STATE/log")"
reset
run --release 'v1;rm -rf x'
check "bad tag: refused" 1 "$st"
check_lacks "bad tag: no download" "curl" "$(cat "$STATE/log")"
run --release ../../evil
check "tag with slashes: refused" 1 "$st"

# A download that does not match its SHA-256 is not installed, and the
# Monad already there stays.
reset
cp -R "$WORK/fx/v08/Monad.app" "$DEST/Monad.app"
publish v0.9 "$WORK/fx/v09/Monad.app" "0000000000000000000000000000000000000000000000000000000000000000"
echo "https://github.com/buzzer-re/Monad/releases/tag/v0.9" >"$STATE/latest"
run --release
check "mismatch: status" 1 "$st"
check_has "mismatch: says so" "does not match its SHA-256" "$out"
check "mismatch: old one stays" 0.8 "$(version_of "$DEST/Monad.app")"
check "mismatch: nothing staged" "Monad.app" "$(ls "$DEST")"
reset
publish v0.9 "$WORK/fx/v09/Monad.app" "not-a-sum"
run --release v0.9
check "no sum: status" 1 "$st"

# No release yet (GitHub sends /releases/latest to the list of releases).
reset
echo "https://github.com/buzzer-re/Monad/releases" >"$STATE/latest"
run --release
check "no release: status" 1 "$st"
check_has "no release: points at --build" "--build" "$out"
reset
run --release
check "unreachable: status" 1 "$st"

# A file the user has: a zip downloaded with a browser (quarantined), or
# an app.
reset
cp -R "$WORK/fx/v09/Monad.app" "$WORK/q.app" && touch "$WORK/q.app/.quarantine"
mkdir -p "$WORK/qzip" && rm -rf "$WORK/qzip/Monad.app" && cp -R "$WORK/q.app" "$WORK/qzip/Monad.app"
zip_app "$WORK/qzip/Monad.app" "$WORK/Monad.zip"
run --from "$WORK/Monad.zip"
check "from zip: status" 0 "$st"
check "from zip: installed" 0.9 "$(version_of "$DEST/Monad.app")"
check "from zip: quarantine gone" "" "$(find "$DEST/Monad.app" -name .quarantine)"
check_lacks "from zip: no download" "curl" "$(cat "$STATE/log")"
reset
run --from "$WORK/q.app"
check "from app: status" 0 "$st"
check "from app: quarantine gone" "" "$(find "$DEST/Monad.app" -name .quarantine)"
check "from app: the source is untouched" "$WORK/q.app/.quarantine" "$(find "$WORK/q.app" -name .quarantine)"
run --from "$WORK/nothing-here"
check "from nothing: refused" 1 "$st"

# Only Monad's Release build, signed and intact, is installed, and only
# over a Monad.
reset
run --from "$WORK/fx/debug/Monad.app"
check "debug build: refused" 1 "$st"
check_has "debug build: says why" "dev.monad.Monad.debug" "$out"
check "debug build: nothing installed" "" "$(ls "$DEST")"
reset
cp -R "$WORK/fx/v09/Monad.app" "$WORK/bad.app" && touch "$WORK/bad.app/.badsig"
run --from "$WORK/bad.app"
check "broken signature: refused" 1 "$st"
check_has "broken signature: says so" "signature" "$out"
check "broken signature: nothing installed" "" "$(ls "$DEST")"
reset
cp -R "$WORK/fx/other/Monad.app" "$DEST/Monad.app"
run --from "$WORK/fx/v09/Monad.app"
check "not Monad there: refused" 1 "$st"
check "not Monad there: left as it is" 3.0 "$(version_of "$DEST/Monad.app")"

# An older Monad is replaced in place.
reset
cp -R "$WORK/fx/v08/Monad.app" "$DEST/Monad.app"
run --from "$WORK/fx/v09/Monad.app" --no-open
check "upgrade: status" 0 "$st"
check "upgrade: new one" 0.9 "$(version_of "$DEST/Monad.app")"
check "upgrade: nothing left over" "Monad.app" "$(ls "$DEST")"

# The swap never leaves no Monad: the new one fails to move into place, or
# the script is stopped between the two moves, and the old one is back.
reset
cp -R "$WORK/fx/v08/Monad.app" "$DEST/Monad.app"
FAKE_MV=fail run --from "$WORK/fx/v09/Monad.app" --no-open
check "swap fails: status" 1 "$st"
check "swap fails: old one back" 0.8 "$(version_of "$DEST/Monad.app")"
check "swap fails: nothing left over" "Monad.app" "$(ls "$DEST")"
reset
cp -R "$WORK/fx/v08/Monad.app" "$DEST/Monad.app"
FAKE_MV=stop run --from "$WORK/fx/v09/Monad.app" --no-open
check "swap stopped: status" 130 "$st"
check "swap stopped: old one back" 0.8 "$(version_of "$DEST/Monad.app")"
check "swap stopped: nothing left over" "Monad.app" "$(ls "$DEST")"

# Safe to cut short (curl | sh runs what has arrived): everything is in
# functions, and the last line, the only other one, calls main…
script="$REPO/scripts/install.sh"
top=$(awk '
    infn { if ($0 ~ /^}/) infn = 0; next }
    /^[[:space:]]*(#|$)/ { next }
    /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{.*\}[[:space:]]*$/ { next }
    /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{[[:space:]]*(#.*)?$/ { infn = 1; next }
    { print }' "$script")
check "cut: only main at the top" 'main "$@"' "$top"
check "cut: main last" 'main "$@"' "$(tail -n 1 "$script")"
# …so any part of it, run as curl | sh would, does nothing.
lines=$(wc -l <"$script")
cut_ok=0 cut_bad=""
k=1
while [ "$k" -lt "$lines" ]; do
    reset
    cp -R "$WORK/fx/v08/Monad.app" "$DEST/Monad.app"
    rm -rf "$WORK/tmp" && mkdir -p "$WORK/tmp"
    head -n "$k" "$script" >"$WORK/cut.sh"
    (cd "$WORK" && PATH="$BIN:$PATH" FAKE_STATE="$STATE" HOME="$WORK/home" TMPDIR="$WORK/tmp" \
        $SH -s -- --dest "$DEST" --from "$WORK/fx/v09/Monad.app" --no-open <"$WORK/cut.sh" >/dev/null 2>&1)
    if [ ! -s "$STATE/log" ] && [ "$(ls "$DEST")" = Monad.app ] && [ "$(version_of "$DEST/Monad.app")" = 0.8 ] &&
        [ -z "$(ls "$WORK/tmp")" ]; then
        cut_ok=$((cut_ok + 1))
    else
        cut_bad="$cut_bad $k"
    fi
    k=$((k + 1))
done
check "cut: no part does anything (lines cut after)" "" "$cut_bad"
check_lacks "cut: parts tried" " 0 " " $cut_ok "

# Monad is not replaced while it runs, nor while its VMs run (MonadHost).
reset
echo 2 >"$STATE/app_running"
echo 2 >"$STATE/host_running"
run --from "$WORK/fx/v09/Monad.app" --no-open
check "waits: status" 0 "$st"
check "waits: app asked until it quit" 3 "$(grep -c '^osascript' "$STATE/log")"
check_has "waits: says to quit" "waiting for Monad to quit" "$out"
check_has "waits: says to stop the VMs" "waiting for Monad's VMs to stop" "$out"
check "waits: said once each" 1 "$(printf '%s\n' "$out" | grep -c 'waiting for Monad to quit')"

# The checkout's build/ folder is used when there is one, else the
# latest release; --build makes one first.
reset
mkdir -p "$REPO/build/Build/Products/Release"
cp -R "$WORK/fx/v08/Monad.app" "$REPO/build/Build/Products/Release/Monad.app"
run --no-open
check "build folder: status" 0 "$st"
check "build folder: installed" 0.8 "$(version_of "$DEST/Monad.app")"
check_lacks "build folder: no download" "curl" "$(cat "$STATE/log")"
check_has "build folder: says which" "$REPO/build" "$out"
reset
publish v0.9 "$WORK/fx/v09/Monad.app"
echo "https://github.com/buzzer-re/Monad/releases/tag/v0.9" >"$STATE/latest"
run --no-open
check "no build folder: the latest release" 0.9 "$(version_of "$DEST/Monad.app")"
reset
run --build --no-open
check "build: status" 0 "$st"
check_has "build: Release, ad hoc, into build/" \
    "xcodebuild -project $REPO/Monad.xcodeproj -scheme Monad -configuration Release -derivedDataPath $REPO/build CODE_SIGN_IDENTITY=- build" \
    "$(cat "$STATE/log")"
check "build: installed" 0.9 "$(version_of "$DEST/Monad.app")"
reset
FAKE_BUILD_FAILS=1 run --build
check "build fails: status" 1 "$st"
check_has "build fails: shows the error" "error: nope" "$out"
check "build fails: nothing installed" "" "$(ls "$DEST")"

# Run on its own (curl | sh): no checkout, so no build/ folder and no --build.
reset
publish v0.9 "$WORK/fx/v09/Monad.app"
echo "https://github.com/buzzer-re/Monad/releases/tag/v0.9" >"$STATE/latest"
run_in "$LOOSE/install.sh" --no-open
check "loose: the latest release" 0.9 "$(version_of "$DEST/Monad.app")"
run_in "$LOOSE/install.sh" --build
check "loose: no --build" 1 "$st"
check_has "loose: says how" "git clone" "$out"

# Where it cannot or should not run.
reset
chmod a-w "$DEST"
run --from "$WORK/fx/v09/Monad.app"
chmod u+w "$DEST"
if [ "$(id -u)" != 0 ]; then
    check "read-only: refused" 1 "$st"
    check_has "read-only: says what to do" "--dest ~/Applications" "$out"
fi
reset
FAKE_UNAME=Linux run --from "$WORK/fx/v09/Monad.app"
check "not a Mac: refused" 1 "$st"
reset
run --frobnicate
check "unknown option: usage" 2 "$st"
run --release --from "$WORK/fx/v09/Monad.app"
check "two sources: refused" 1 "$st"

# release.sh package: the archive and checksum install.sh downloads, made
# only from a clean checkout.
reset
git -C "$REPO" init -q
git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -qm fixture
echo "# changed" >>"$REPO/scripts/release.sh"
out=$(PATH="$BIN:$PATH" FAKE_STATE="$STATE" HOME="$WORK/home" sh "$REPO/scripts/release.sh" package 2>&1)
check "package dirty: refused" 1 "$?"
git -C "$REPO" checkout -q -- scripts/release.sh
out=$(PATH="$BIN:$PATH" FAKE_STATE="$STATE" HOME="$WORK/home" sh "$REPO/scripts/release.sh" package 2>&1)
check "package: status" 0 "$?"
dist="$WORK/home/Library/Developer/Monad-Release/dist"
check "package: files" "Monad.zip
Monad.zip.sha256" "$(ls "$dist")"
check_has "package: says how to publish" "gh release create v0.9" "$out"
mkdir -p "$STATE/releases/v0.9"
cp "$dist/Monad.zip" "$dist/Monad.zip.sha256" "$STATE/releases/v0.9/"
echo "https://github.com/buzzer-re/Monad/releases/tag/v0.9" >"$STATE/latest"
run --release --no-open
check "package: installs" 0 "$st"
check "package: installed" 0.9 "$(version_of "$DEST/Monad.app")"

printf '%d checks, %d failures\n' "$checks" "$failures" >&2
[ "$failures" -eq 0 ]
