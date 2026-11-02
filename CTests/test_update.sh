#!/bin/sh
# Tests for Monad/App/monad-update.sh, which puts a checked update in place
# of Monad once the copy that downloaded it has quit, then opens it. Stand-ins
# for ditto, xattr, plutil and open (so they run on Linux too); a quarantine
# flag is a `.quarantine` file in the app. Usage: test_update.sh [workdir]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
UPDATE="$HERE/../Monad/App/monad-update.sh"
SH=${UPDATE_SHELL:-sh}
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
    { echo '#!/bin/sh'; echo 'echo "'"$1"' $*" >>"$FAKE_STATE/log"'; cat; } >"$BIN/$1"
    chmod +x "$BIN/$1"
}
stub open <<'EOF'
:
EOF
# ditto SRC DST; FAKE_DITTO=fail fails halfway (a part copied).
stub ditto <<'EOF'
if [ "${FAKE_DITTO:-}" = fail ]; then mkdir -p "$2"; exit 1; fi
cp -R "$1" "$2"
EOF
stub xattr <<'EOF'
case "$1" in
    -dr) find "$3" -name .quarantine -exec rm -f {} + ;;
    -p) [ -e "$3/.quarantine" ] || exit 1; echo 0081 ;;
esac
EOF
stub plutil <<'EOF'
# plutil -extract KEY raw -o - FILE
v=$(sed -n "/<key>$2<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}" "$6")
[ -n "$v" ] && echo "$v"
EOF
# mv: FAKE_MV=fail cannot move the new Monad into place.
stub mv <<'EOF'
case "${FAKE_MV:-}:$1" in
    fail:*.app.new) exit 1 ;;
esac
PATH=/usr/bin:/bin exec mv "$@"
EOF

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
}

STATE="$WORK/state"
DEST="$WORK/Applications/Monad.app"
UPD="$WORK/update"
reset() { # reset [DEST_ID]: Monad 1.0 installed, 1.2 downloaded (quarantined)
    rm -rf "$STATE" "$WORK/Applications" "$UPD"
    mkdir -p "$STATE" "$WORK/Applications" "$UPD/unpacked"
    make_app "$DEST" "${1:-dev.monad.Monad}" 1.0
    make_app "$UPD/unpacked/Monad.app" dev.monad.Monad 1.2
    touch "$UPD/unpacked/Monad.app/.quarantine"
    cp "$UPDATE" "$UPD/monad-update.sh"
    : >"$STATE/log"
}
version() { sed -n '/<key>CFBundleShortVersionString<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$1/Contents/Info.plist"; }
gone_pid() { /bin/sh -c 'exit 0' & p=$!; wait "$p"; echo "$p"; }

run() { # run PID [ENV…]: the script as the app starts it, from its copy in the work folder
    pid=$1
    shift
    env PATH="$BIN:$PATH" FAKE_STATE="$STATE" MONAD_UPDATE_WAIT=${MONAD_UPDATE_WAIT:-5} "$@" \
        $SH "$UPD/monad-update.sh" "$pid" "$UPD/unpacked/Monad.app" "$DEST" "$UPD" >"$WORK/out" 2>&1
    st=$?
}
opened() { grep -c "^open " "$STATE/log"; }

# Once the app has quit: the new Monad in place, without its quarantine
# flag, nothing left beside it, the work folder removed, and it is opened.
reset
run "$(gone_pid)"
check "swap: ends well" 0 "$st"
check "swap: the new version" 1.2 "$(version "$DEST")"
check "swap: no quarantine" no "$([ -e "$DEST/.quarantine" ] && echo yes || echo no)"
check "swap: nothing beside it" "Monad.app" "$(ls "$WORK/Applications")"
check "swap: the work folder goes" no "$([ -e "$UPD" ] && echo yes || echo no)"
check "swap: opened" "open $DEST" "$(grep '^open ' "$STATE/log")"

# It waits for the copy that downloaded it to quit.
reset
/bin/sleep 2 &
app=$!
run "$app"
check "wait: ends well" 0 "$st"
check "wait: the app had quit" gone "$(kill -0 "$app" 2>/dev/null && echo running || echo gone)"
check "wait: the new version" 1.2 "$(version "$DEST")"

# A copy that does not quit: nothing changes, nothing opens.
reset
/bin/sleep 30 &
app=$!
MONAD_UPDATE_WAIT=1 run "$app"
kill "$app" 2>/dev/null
check "no quit: fails" 1 "$st"
check "no quit: still 1.0" 1.0 "$(version "$DEST")"
check "no quit: nothing opened" 0 "$(opened)"
check "no quit: says why" yes "$(grep -q 'did not quit' "$WORK/out" && echo yes || echo no)"

# A copy that fails halfway: the old Monad stays and opens again.
reset
run "$(gone_pid)" FAKE_DITTO=fail
check "copy fails: fails" 1 "$st"
check "copy fails: still 1.0" 1.0 "$(version "$DEST")"
check "copy fails: nothing beside it" "Monad.app" "$(ls "$WORK/Applications")"
check "copy fails: the old one opens" "open $DEST" "$(grep '^open ' "$STATE/log")"

# The new one cannot be moved into place: the old one goes back.
reset
run "$(gone_pid)" FAKE_MV=fail
check "move fails: fails" 1 "$st"
check "move fails: still 1.0" 1.0 "$(version "$DEST")"
check "move fails: nothing beside it" "Monad.app" "$(ls "$WORK/Applications")"
check "move fails: the old one opens" "open $DEST" "$(grep '^open ' "$STATE/log")"

# Only over Monad: another app at the destination is left as it is.
reset dev.example.Other
run "$(gone_pid)"
check "not Monad: fails" 1 "$st"
check "not Monad: untouched" 1.0 "$(version "$DEST")"
check "not Monad: nothing opened" 0 "$(opened)"

# Nor with something else as the update.
reset
make_app "$UPD/unpacked/Monad.app" dev.monad.Monad.debug 1.2
run "$(gone_pid)"
check "update not Monad: fails" 1 "$st"
check "update not Monad: untouched" 1.0 "$(version "$DEST")"

$SH "$UPDATE" >/dev/null 2>&1
check "usage" 2 "$?"

printf 'monad-update tests (%s): %d checks, %d failures\n' "$SH" "$checks" "$failures" >&2
[ "$failures" -eq 0 ]
