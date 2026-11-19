#!/bin/sh
# Tests for Monad/Guest/monad-apps.sh: which desktop entries of a Linux VM
# count as applications, the one form they are listed in (the Mac reads the
# list as hostile, so every text of a desktop file must arrive as one
# encoded word), the icons handed out as PNG bytes, and what launch starts.
# A fake tree as MONAD_ROOT, a stand-in for rsvg-convert, and on PATH only
# the tools the script may use.
# Usage: test_apps.sh [workdir]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../Monad/Guest/monad-apps.sh"
SH=${APPS_SHELL:-sh}
SH_PATH=$(command -v "$SH")   # the PATH below is not the machine's
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

# The tools the script may use, and nothing else: the machine's own
# rsvg-convert must never be found, nor a tool no guest is sure to have.
SYS="$WORK/sys"
mkdir -p "$SYS"
for tool in awk cat head id mkdir mv nohup od rm sh true wc; do
    real=$(command -v "$tool") || { echo "test_apps.sh: no $tool" >&2; exit 1; }
    ln -s "$real" "$SYS/$tool"
done
# setsid where there is one (Linux); a Mac starts the program with nohup.
if command -v setsid >/dev/null 2>&1; then ln -s "$(command -v setsid)" "$SYS/setsid"; fi

BIN="$WORK/bin"
CONV="$WORK/conv"
mkdir -p "$BIN" "$CONV"

png() { # png FILE TEXT: a file that starts as a PNG does
    mkdir -p "$(dirname "$1")"
    printf '\211PNG\r\n\032\n%s' "$2" > "$1"
}
rep() { # rep TEXT N: the text N times (awk reads \ooo in it as a byte)
    awk -v s="$1" -v n="$2" 'BEGIN { for (i = 0; i < n; i++) printf "%s", s }'
}
size() { wc -c < "$1" | tr -d ' '; }
same() { cmp -s "$1" "$2" && echo same || echo differs; }
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

# rsvg-convert: notes how it was called and prints a small PNG; fails while
# $WORK/rsvg.fails is there.
png "$WORK/drawn.png" drawn
cat > "$CONV/rsvg-convert" <<EOF
#!$SH_PATH
echo "\$*" >> "$WORK/rsvg.calls"
[ -f "$WORK/rsvg.fails" ] && exit 1
cat "$WORK/drawn.png"
EOF
chmod 755 "$CONV/rsvg-convert"

# What launch really starts: notes its arguments, folder and environment.
cat > "$BIN/probe" <<EOF
#!$SH_PATH
{
    printf 'args:'
    for a; do printf ' <%s>' "\$a"; done
    printf '\nfolder: %s\n' "\$(pwd -P)"
    printf 'display: %s %s %s %s %s\n' "\$XDG_RUNTIME_DIR" "\$WAYLAND_DISPLAY" "\$XDG_SESSION_TYPE" "\$MOZ_ENABLE_WAYLAND" "\$QT_QPA_PLATFORM"
    printf 'desktop: %s\n' "\${XDG_CURRENT_DESKTOP-none}"
    printf 'libraries: %s\n' "\${LD_LIBRARY_PATH-none}"
    printf 'locale: %s\n' "\${LC_ALL-none}"
} > "$WORK/probe.new"
mv "$WORK/probe.new" "$WORK/probe.out"
EOF
chmod 755 "$BIN/probe"

ROOT="$WORK/root"
RUNTIME="$WORK/norun"
TOOLS=$SYS
DATA_HOME=
DATA_DIRS=
RECORD=
LOCALE=
LIBRARIES=
mkdir -p "$RUNTIME"

apps() { # apps ARGUMENT...: the script on the fake tree; its output, errors and status are kept
    env -i PATH="$TOOLS" HOME=/home/dev MONAD_ROOT="$ROOT" XDG_RUNTIME_DIR="$RUNTIME" \
        ${DATA_HOME:+XDG_DATA_HOME="$DATA_HOME"} ${DATA_DIRS:+XDG_DATA_DIRS="$DATA_DIRS"} \
        ${RECORD:+MONAD_APPS_RUN="$RECORD"} ${LOCALE:+LC_ALL="$LOCALE"} ${LIBRARIES:+LD_LIBRARY_PATH="$LIBRARIES"} \
        "$SH_PATH" "$SCRIPT" "$@" > "$WORK/out" 2> "$WORK/err"
    status=$?
}

entry() { # entry FOLDER ID: a desktop file (on stdin) in one of the data folders
    mkdir -p "$ROOT$1/applications"
    cat > "$ROOT$1/applications/$2.desktop"
}
app() { # app FOLDER ID NAME EXEC [LINE ...]: an application's desktop file
    app_folder=$1 app_id=$2
    {
        printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n' "$3" "$4"
        shift 4
        for line; do printf '%s\n' "$line"; done
    } | entry "$app_folder" "$app_id"
}

# No folders at all: an empty list is still a list.
ROOT="$WORK/empty"
mkdir -p "$ROOT"
apps list
check "nothing: status" 0 "$status"
check "nothing: list" "end 0" "$(cat "$WORK/out")"
apps icons
check "nothing: icons" "0 end" "$status $(cat "$WORK/out")"
ROOT="$WORK/root"

# The tree. U is the user's folder, L and S the system's (XDG_DATA_DIRS as it is when unset).
U=/home/dev/.local/share
L=/usr/local/share
S=/usr/share
HICOLOR="$ROOT/usr/share/icons/hicolor"
PIXMAPS="$ROOT/usr/share/pixmaps"

app $U editor "My Editor" "myedit %F" Icon=editor
app $U shadow Shadow shadow Hidden=true                 # hides the system's entry of that id
app $L local-tool "Local Tool" 'bar 100%% %f' Icon=/opt/tool/icon.png
app $S -lead "Leading Dash" lead                        # an id may begin as an option does
app $S abs-svg Drawn drawn Icon=/opt/tool/logo.svg
app $S bigicon "Big Icon" bigicon Icon=bigicon
entry $S browser <<'EOF'
[Desktop Entry]
Name[de]=Netzbrowser
Name=Web Browser
Name[fr]=Navigateur
Type=Application
Exec=foo --new-window %U
Icon=browser
Terminal=false
NoDisplay=false
Hidden=false
Actions=private;

[Desktop Action private]
Name=Private Window
Exec=foo --private
Icon=private
Terminal=true
NoDisplay=true
EOF
app $S cafe "$(printf 'Caf\303\251 & Co')" cafe
app $S codes Codes 'prog --a=%u --b=%% %x 5%'
printf '[Desktop Entry]\r\nType=Application\r\nName=Windows Lines\r\nExec=crlf %%f\r\nIcon=crlf-icon\r\nNoDisplay=false\r\n\r\n[Desktop Action a]\r\nName=Other\r\n' | entry $S crlf
printf '[Desktop Entry]\r\nType=Application\r\nName=Windows Hidden\r\nExec=crlf\r\nHidden=true\r\n' | entry $S crlf-hidden
app $S ctrl "$(printf 'A\001B\177C\377')" ctrl Icon=tiny4
app $S dash - dash Icon=-
app $S editor "System Editor" sysedit Icon=editor
app $S emptyexec "No Command" "  "
app $S emptyname "   " emptyname
app $S hidden Hidden hidden Hidden=true
app $S "$(rep i 129)" "Id Too Long" toolong
printf '[Desktop Entry]\nType=Link\nName=A Link\nExec=link\nURL=https://example.com/\n' | entry $S link
app $S long "$(rep '\303\251' 150)" long                # 300 bytes; byte 127 is inside a character
app $S long2 "a$(rep '\342\202\254' 100)" long2         # byte 127 ends a character
app $S long3 "ab$(rep '\342\202\254' 100)" long3        # bytes 126 to 128 are one character
app $S long4 "$(rep '\360\237\230\200' 75)" long4       # bytes 125 to 128 are one character
app $S longascii "$(rep x 300)" longascii
app $S longicon "Long Icon" longicon "Icon=/opt/$(rep p 200).png"
app $S "$(rep m 128)" "Longest Id" maxid
app $S nodisplay "No Display" nodisplay NoDisplay=true
printf '[Desktop Entry]\nType=Application\nName=No Exec\n' | entry $S noexec
printf '[Desktop Entry]\nType=Application\nName[de]=Nur Deutsch\nExec=noname\n' | entry $S noname
app $S notpng "Not A PNG" notpng Icon=notpng
app $S percent "100% sure" percent Icon=../pixmaps/browser
app $S probe Probe "\"$BIN/probe\" %u one \"two words\" 50%%" "Path=$ROOT/opt/tool"
app $S shadow "System Shadow" sysshadow
app $S svg Vector vector Icon=vector
printf '# before the group\nName=Too Early\nExec=wrong\nHidden=true\n\n[Desktop Entry]\n# a comment\nType = Application\nName =  Spaced \t Out \t \nExec\t=\ttabs --run\nIcon= tabs+icon\nName[de]=Leerzeichen\n\n[Desktop Action more]\nName=More\nExec=tabs --more\nNoDisplay=true\nHidden=true\nIcon=wrong\n' | entry $S tabs
app $S terminal "In A Terminal" terminal Terminal=true
app $S "bad id" "Bad Id" badid
app $S 'bad~id' "Bad Id" badid
app $S 'bad,id' "Bad Id" badid
mkdir -p "$ROOT$S/applications/folder.desktop" "$ROOT$S/applications/kde4"
printf '[Desktop Entry]\nType=Application\nName=Nested\nExec=nested\n' > "$ROOT$S/applications/kde4/nested.desktop"
# A file of exactly 64 KiB is read; one byte more and it is not.
padded() { # padded ID BYTES: an application's desktop file of that size
    printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n' "$1" "$1" | entry $S "$1"
    awk -v n="$(($2 - $(size "$ROOT$S/applications/$1.desktop")))" 'BEGIN {
        for (; n >= 64; n -= 64) printf "#%062d\n", 0
        if (n > 0) { for (i = 1; i < n; i++) printf "#"; printf "\n" }
    }' >> "$ROOT$S/applications/$1.desktop"
}
padded edge 65536
padded over 65537
check "the tree: a file of 64 KiB" 65536 "$(size "$ROOT$S/applications/edge.desktop")"
check "the tree: a file of one byte more" 65537 "$(size "$ROOT$S/applications/over.desktop")"
app /var/lib/snapd/desktop browser "Snap Browser" snapbrowser
app /var/lib/snapd/desktop snap-app "Snap App" snap-app
app /var/lib/flatpak/exports/share org.example.App "Flat App" flat Icon=org.example.App

# Icons. Sizes are tried 128 256 96 64 48 32, then pixmaps, then drawings.
png "$HICOLOR/128x128/apps/editor.png" editor-128
png "$HICOLOR/256x256/apps/editor.png" editor-256-larger
png "$HICOLOR/48x48/apps/editor.png" editor-48
mkdir -p "$HICOLOR/scalable/apps" "$ROOT/usr/share/icons/Adwaita/scalable/apps" "$ROOT/opt/tool"
echo '<svg/>' > "$HICOLOR/scalable/apps/editor.svg"
png "$ROOT/opt/tool/icon.png" local-tool
echo '<svg/>' > "$ROOT/opt/tool/logo.svg"
png "$HICOLOR/128x128/apps/bigicon.png" ""
head -c 262137 /dev/zero >> "$HICOLOR/128x128/apps/bigicon.png"       # one byte too many
png "$PIXMAPS/bigicon.png" "never the second choice"
png "$HICOLOR/32x32/apps/browser.png" browser-32
png "$PIXMAPS/browser.png" browser-pixmap
printf '\211PNG' > "$PIXMAPS/tiny4.png"
png "$ROOT/opt/$(rep p 200).png" longicon
echo '<html>not a PNG</html>' > "$PIXMAPS/notpng.png"
echo '<svg/>' > "$HICOLOR/scalable/apps/vector.svg"
echo '<svg/>' > "$ROOT/usr/share/icons/Adwaita/scalable/apps/vector.svg"
echo '<svg/>' > "$PIXMAPS/vector.svg"
png "$HICOLOR/64x64/apps/tabs+icon.png" tabs-64
png "$HICOLOR/48x48/apps/tabs+icon.png" tabs-48
png "$PIXMAPS/org.example.App.png" flat
# Drawings older than anything made from them here.
touch -t 202001010000 "$HICOLOR/scalable/apps/vector.svg" "$ROOT/opt/tool/logo.svg"

# list, byte for byte.
{
    cat <<'EOF'
app editor editor My%20Editor
app local-tool /opt/tool/icon.png Local%20Tool
app -lead - Leading%20Dash
app abs-svg /opt/tool/logo.svg Drawn
app bigicon bigicon Big%20Icon
app browser browser Web%20Browser
app cafe - Caf%C3%A9%20&%20Co
app codes - Codes
app crlf crlf-icon Windows%20Lines
app ctrl tiny4 A%01B%7FC%FF
app dash %2D %2D
app edge - edge
EOF
    echo "app long - $(rep '%C3%A9' 63)"
    echo "app long2 - a$(rep '%E2%82%AC' 42)"
    echo "app long3 - ab$(rep '%E2%82%AC' 41)"
    echo "app long4 - $(rep '%F0%9F%98%80' 31)"
    echo "app longascii - $(rep x 127)"
    echo "app longicon /opt/$(rep p 122) Long%20Icon"
    echo "app $(rep m 128) - Longest%20Id"
    cat <<'EOF'
app notpng notpng Not%20A%20PNG
app percent ../pixmaps/browser 100%25%20sure
app probe - Probe
app svg vector Vector
app tabs tabs+icon Spaced%20%09%20Out
app snap-app - Snap%20App
app org.example.App org.example.App Flat%20App
end 26
EOF
} > "$WORK/list.expected"
apps list
check "list: status" 0 "$status"
check "list: the applications" "$(cat "$WORK/list.expected")" "$(cat "$WORK/out")"
check "list: byte for byte" same "$(same "$WORK/list.expected" "$WORK/out")"
check "list: nothing else said" "" "$(cat "$WORK/err")"
check "list: only printable ASCII" "" "$(LC_ALL=C tr -d '\n\040-\176' < "$WORK/out")"

# Other folders: XDG_DATA_HOME and XDG_DATA_DIRS are followed, a folder that
# is not absolute is none (the tree's root before it would name another).
app /custom/home mine Mine mine
app /custom/share custom Custom custom
mkdir -p "${ROOT}relative/share/applications"
printf '[Desktop Entry]\nType=Application\nName=Relative\nExec=relative\n' > "${ROOT}relative/share/applications/relative.desktop"
DATA_HOME=/custom/home DATA_DIRS=/custom/share:relative/share::/usr/share
apps list
check "folders: status" 0 "$status"
check "folders: the first lines" "app mine - Mine
app custom - Custom
app -lead - Leading%20Dash" "$(head -n 3 "$WORK/out")"
check_has "folders: the system's editor, no longer hidden by the user's" "app editor editor System%20Editor" "$(cat "$WORK/out")"
check_has "folders: the system's shadow too" "app shadow - System%20Shadow" "$(cat "$WORK/out")"
check_lacks "folders: not one left out of XDG_DATA_DIRS" "app local-tool" "$(cat "$WORK/out")"
check_lacks "folders: not a relative one" "relative" "$(cat "$WORK/out")"
check "folders: the count" "end 28" "$(tail -n 1 "$WORK/out")"
DATA_HOME= DATA_DIRS=

# The icons stream of $1 taken apart as its reader does: each icon's bytes
# go to $2/<id>.png and "<id> <bytes>" is printed, then "end" when the
# stream ends as it should ("bad ..." for anything else).
split_icons() {
    stream=$1 into=$2 at=1
    rm -rf "$into"
    mkdir -p "$into"
    while :; do
        header=$(tail -c +"$at" "$stream" | head -n 1)
        case $header in
            end)
                if [ $((at + 3)) -eq "$(size "$stream")" ]; then echo end; else echo "bad: bytes after end"; fi
                return ;;
            "icon "*)
                set -- $header
                case ${3:-x} in *[!0-9]*) echo "bad: $header"; return ;; esac
                at=$((at + ${#header} + 1))
                tail -c +"$at" "$stream" | head -c "$3" > "$into/$2.png"
                at=$((at + $3))
                echo "$2 $3" ;;
            *)
                echo "bad: $header"
                return ;;
        esac
    done
}
CACHE="$ROOT/home/dev/.cache/monad/icons"
LONGICON="$ROOT/opt/$(rep p 200).png"

# icons without rsvg-convert: the PNG files, and no icon for a drawing.
apps icons
check "icons, no converter: status" 0 "$status"
check "icons, no converter: which" "editor $(size "$HICOLOR/128x128/apps/editor.png")
local-tool $(size "$ROOT/opt/tool/icon.png")
browser $(size "$HICOLOR/32x32/apps/browser.png")
longicon $(size "$LONGICON")
tabs $(size "$HICOLOR/64x64/apps/tabs+icon.png")
org.example.App $(size "$PIXMAPS/org.example.App.png")
end" "$(split_icons "$WORK/out" "$WORK/got")"
check "icons, no converter: by name, 128 first" same "$(same "$WORK/got/editor.png" "$HICOLOR/128x128/apps/editor.png")"
check "icons, no converter: by path" same "$(same "$WORK/got/local-tool.png" "$ROOT/opt/tool/icon.png")"
check "icons, no converter: a size before pixmaps" same "$(same "$WORK/got/browser.png" "$HICOLOR/32x32/apps/browser.png")"
check "icons, no converter: a path longer than the list shows" same "$(same "$WORK/got/longicon.png" "$LONGICON")"
check "icons, no converter: 64 before 48" same "$(same "$WORK/got/tabs.png" "$HICOLOR/64x64/apps/tabs+icon.png")"
check "icons, no converter: pixmaps" same "$(same "$WORK/got/org.example.App.png" "$PIXMAPS/org.example.App.png")"
check "icons, no converter: nothing else said" "" "$(cat "$WORK/err")"
check "icons, no converter: nothing kept" "" "$(ls "$CACHE" 2>/dev/null)"

# With rsvg-convert: a drawing is drawn once and kept.
TOOLS="$CONV:$SYS"
apps icons
check "icons: status" 0 "$status"
check "icons: which" "editor $(size "$HICOLOR/128x128/apps/editor.png")
local-tool $(size "$ROOT/opt/tool/icon.png")
abs-svg $(size "$WORK/drawn.png")
browser $(size "$HICOLOR/32x32/apps/browser.png")
longicon $(size "$LONGICON")
svg $(size "$WORK/drawn.png")
tabs $(size "$HICOLOR/64x64/apps/tabs+icon.png")
org.example.App $(size "$PIXMAPS/org.example.App.png")
end" "$(split_icons "$WORK/out" "$WORK/got")"
check "icons: a drawing by path" same "$(same "$WORK/got/abs-svg.png" "$WORK/drawn.png")"
check "icons: a drawing by name" same "$(same "$WORK/got/svg.png" "$WORK/drawn.png")"
check "icons: a PNG still as it is" same "$(same "$WORK/got/editor.png" "$HICOLOR/128x128/apps/editor.png")"
check "icons: how the converter was called (hicolor's drawing first, never a PNG's)" "-w 128 -h 128 $ROOT/opt/tool/logo.svg
-w 128 -h 128 $HICOLOR/scalable/apps/vector.svg" "$(cat "$WORK/rsvg.calls")"
check "icons: what is kept" "abs-svg.png svg.png " "$(ls "$CACHE" | tr '\n' ' ')"
check "icons: nothing else said" "" "$(cat "$WORK/err")"
apps icons
check "icons again: the same" "abs-svg $(size "$WORK/drawn.png") svg $(size "$WORK/drawn.png")" "$(split_icons "$WORK/out" "$WORK/got" | grep svg | tr '\n' ' ' | sed 's/ $//')"
check "icons again: nothing drawn again" 2 "$(lines "$WORK/rsvg.calls")"
# The drawing changed: drawn again. A converter that fails gives no icon, and not the old one.
touch -t 203001010000 "$HICOLOR/scalable/apps/vector.svg"
: > "$WORK/rsvg.fails"
apps icons
check "converter fails: status" 0 "$status"
check_lacks "converter fails: no icon" "svg " "$(split_icons "$WORK/out" "$WORK/got" | grep -v abs-svg)"
check_has "converter fails: the others are there" "abs-svg " "$(split_icons "$WORK/out" "$WORK/got")"
check "converter fails: it was tried" 3 "$(lines "$WORK/rsvg.calls")"
check "converter fails: nothing half done is kept" "abs-svg.png svg.png " "$(ls "$CACHE" | tr '\n' ' ')"
rm "$WORK/rsvg.fails"
apps icons
check_has "drawing changed: drawn again" "svg $(size "$WORK/drawn.png")" "$(split_icons "$WORK/out" "$WORK/got" | grep -v abs-svg)"
check "drawing changed: the converter ran once more" 4 "$(lines "$WORK/rsvg.calls")"
# The icons of some: only theirs, in the order asked. One that is no application's, or has no icon, is left out.
apps icons svg nothere editor hidden abs-svg
check "icons of some: status" 0 "$status"
check "icons of some: which, as asked" "svg $(size "$WORK/drawn.png")
editor $(size "$HICOLOR/128x128/apps/editor.png")
abs-svg $(size "$WORK/drawn.png")
end" "$(split_icons "$WORK/out" "$WORK/got")"
check "icons of some: nothing else said" "" "$(cat "$WORK/err")"
apps icons editor "bad id"
check "icons of an id with a space: status" 2 "$status"
check "icons of an id with a space: nothing on stdout" "" "$(cat "$WORK/out")"
apps icons ../editor
check "icons of a path: status" 2 "$status"
apps icons $(rep "x " 65)
check "icons of more than are asked at once: status" 2 "$status"
TOOLS=$SYS

# launch: what it refuses.
RECORD="$WORK/launched"
apps launch "bad id"
check "launch, an id with a space: status" 2 "$status"
check "launch, an id with a space: says something" 1 "$(lines "$WORK/err")"
apps launch ../browser
check "launch, a path: status" 2 "$status"
apps launch ""
check "launch, an empty id: status" 2 "$status"
apps launch "$(rep i 129)"
check "launch, an id too long: status" 2 "$status"
apps launch
check "launch, no id: status" 2 "$status"
check_has "launch, no id: usage" "usage:" "$(cat "$WORK/err")"
apps launch browser more
check "launch, two ids: status" 2 "$status"
apps
check "no subcommand: status" 2 "$status"
check_has "no subcommand: usage" "usage:" "$(cat "$WORK/err")"
check "no subcommand: nothing on stdout" "" "$(cat "$WORK/out")"
apps remove browser
check "another subcommand: status" 2 "$status"
apps list more
check "list with more: status" 2 "$status"
apps launch nothere
check "launch, unknown: status" 4 "$status"
check "launch, unknown: says so" "No such application: nothere" "$(cat "$WORK/err")"
for hidden in hidden shadow nodisplay terminal link noexec noname over crlf-hidden; do
    apps launch "$hidden"
    check "launch, $hidden (not listed): status" 4 "$status"
done
check "launch, not listed: says so" "No such application: crlf-hidden" "$(cat "$WORK/err")"
apps launch browser
check "launch, no window manager: status" 5 "$status"
check "launch, no window manager: one sentence" 1 "$(lines "$WORK/err")"
check_has "launch, no window manager: says so" "window manager is not running" "$(cat "$WORK/err")"
: > "$RUNTIME/wayland-0"
apps launch browser
check "launch, a file that is no socket: status" 5 "$status"
check "launch, refused: nothing was started" "no" "$([ -e "$RECORD" ] && echo yes || echo no)"

# launch with the window manager's socket there.
RUNTIME="$WORK/run"
mkdir -p "$RUNTIME"
# The socket is bound by its name alone: a Mac's socket paths end at 104 bytes.
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import os, socket, sys; os.chdir(sys.argv[1]); socket.socket(socket.AF_UNIX).bind("wayland-0")' "$RUNTIME" &&
    [ -S "$RUNTIME/wayland-0" ]; then
    # MONAD_APPS_RUN: the command line, its field codes gone.
    apps launch browser
    check "launch: status" 0 "$status"
    check "launch: silent" "" "$(cat "$WORK/out")$(cat "$WORK/err")"
    apps launch local-tool
    apps launch editor
    apps launch codes
    apps launch crlf
    apps launch -lead
    check "launch: the command lines" "foo --new-window
bar 100%
myedit
prog --a= --b=% %x 5%
crlf
lead" "$(cat "$RECORD")"
    apps launch nothere
    check "launch, unknown with a window manager: status" 4 "$status"
    RECORD=

    # For real: the program runs on after the script, in the entry's folder, pointed at the window manager.
    started() { # waits for the probe to have run
        tries=0
        while [ ! -f "$WORK/probe.out" ] && [ "$tries" -lt 100 ]; do
            sleep 0.1 2>/dev/null || sleep 1
            tries=$((tries + 1))
        done
        cat "$WORK/probe.out" 2>/dev/null
        rm -f "$WORK/probe.out"
    }
    LOCALE=POSIX
    apps launch probe
    check "start: status" 0 "$status"
    check "start: silent" "" "$(cat "$WORK/out")$(cat "$WORK/err")"
    check "start: what ran" "args: <one> <two words> <50%>
folder: $(cd "$ROOT/opt/tool" && pwd -P)
display: $RUNTIME wayland-0 wayland 1 wayland;xcb
desktop: Monad
libraries: none
locale: POSIX" "$(started)"
    LOCALE=
    apps launch probe
    check "start, no locale: the script's own is not handed on" "locale: none" "$(started | tail -n 1)"

    # Drawing by the Mac's GPU: while the Mac is there for it (the window manager's drawing socket) and Monad's
    # own OpenGL library is built, the program finds that library before the system's; else it is as it was.
    mkdir -p "$ROOT/usr/local/lib/monad/gl/lib"
    : > "$ROOT/usr/local/lib/monad/gl/lib/libEGL.so.1"
    apps launch probe
    check "start, the Mac not there to draw: the system's libraries" "libraries: none" "$(started | grep libraries)"
    python3 -c 'import os, socket, sys; os.chdir(sys.argv[1]); socket.socket(socket.AF_UNIX).bind("monad-gl")' "$RUNTIME"
    apps launch probe
    check "start, the Mac draws: Monad's library first" "libraries: /usr/local/lib/monad/gl/lib" "$(started | grep libraries)"
    LIBRARIES=/opt/lib
    apps launch probe
    check "start, the Mac draws: before the ones the caller had" "libraries: /usr/local/lib/monad/gl/lib:/opt/lib" "$(started | grep libraries)"
    LIBRARIES=
    rm "$ROOT/usr/local/lib/monad/gl/lib/libEGL.so.1"
    apps launch probe
    check "start, no library built: the system's" "libraries: none" "$(started | grep libraries)"
else
    echo "test_apps.sh: no python3 to make a socket with; what launch starts is not checked" >&2
fi
RECORD=

# More applications than are listed: the first 256, and launch knows no other.
ROOT="$WORK/many"
n=0
while [ "$n" -lt 300 ]; do
    id=$(printf 'app%03d' "$n")
    app $S "$id" "App $n" "$id"
    n=$((n + 1))
done
apps list
check "many: status" 0 "$status"
check "many: the applications" 256 "$(grep -c '^app ' "$WORK/out")"
check "many: the first and the last" "app app000 - App%200
app app255 - App%20255
end 256" "$(sed -n '1p;256p;257p' "$WORK/out")"
check "many: nothing after the count" 257 "$(lines "$WORK/out")"
if [ -S "$RUNTIME/wayland-0" ]; then
    RECORD="$WORK/launched-many"
    apps launch app255
    check "many: the last one listed starts" "0 app255" "$status $(cat "$RECORD")"
    apps launch app256
    check "many: the next one is unknown" 4 "$status"
    RECORD=
fi

# More icon bytes than are handed out: 32 icons of the largest size are 8 MiB, the rest are left out.
ROOT="$WORK/heavy"
png "$ROOT/opt/largest.png" ""
head -c 262136 /dev/zero >> "$ROOT/opt/largest.png"
n=0
while [ "$n" -lt 34 ]; do
    id=$(printf 'icon-%02d' "$n")
    app $S "$id" "Icon $n" "$id" Icon=/opt/largest.png
    n=$((n + 1))
done
apps icons
check "heavy: status" 0 "$status"
split_icons "$WORK/out" "$WORK/got" > "$WORK/heavy.icons"
check "heavy: the icons" "33 icon-00 262144 icon-31 262144 end" \
    "$(lines "$WORK/heavy.icons") $(sed -n '1p;32p;33p' "$WORK/heavy.icons" | tr '\n' ' ' | sed 's/ $//')"
check "heavy: the largest icon as it is" same "$(same "$WORK/got/icon-31.png" "$ROOT/opt/largest.png")"
check "heavy: the bytes" $((32 * (20 + 262144) + 4)) "$(size "$WORK/out")"

echo "test_apps.sh ($SH): $checks checks, $failures failures"
[ "$failures" -eq 0 ]
