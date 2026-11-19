#!/bin/sh
# Monad: the graphical applications of a Linux VM, for the Mac to show and
# to start. Monad lists a VM's applications with their icons and opens one
# as a window on the Mac; this script is the VM's side of that. It reads
# the freedesktop desktop entries (the .desktop files a desktop's menu is
# made of), so it asks nothing of a distribution but sh, awk and coreutils.
#
# Monad runs it over the VM's ssh connection and reads all it prints as it
# reads anything a VM says, as hostile. So the output has one fixed form,
# and no text of a desktop file is printed as it is: a name or an icon is
# cut to 127 bytes and written as one word of printable ASCII.
#
#   apps list          "app <id> <icon> <name>" for each application, then
#                      "end <count>". <icon> is "-" when the entry has none.
#   apps icons [ID...] for each application whose icon is found, in list's
#                      order: the line "icon <id> <bytes>", then that many
#                      bytes of a PNG file and nothing after them. Then the
#                      line "end". With ids (64 at most), only theirs, in the
#                      order asked: Monad asks for a few at a time.
#   apps launch <id>   starts the application in Monad's window manager,
#                      detached, so it lives on when the ssh command ends.
#
# A word: each byte that is not printable ASCII (0x21 to 0x7E), and "%", is
# written %XX; an empty text is "-" and the text "-" is "%2D".
#
# An application is a desktop entry of Type=Application with a Name and an
# Exec that is not hidden (NoDisplay, Hidden) and needs no terminal; its id
# is the file's name without ".desktop". The folders are read as a desktop
# reads them, the user's first, and the first file of an id is the one that
# counts, so a hidden entry of the user's hides the system's. At most 256
# applications, from files of at most 64 KiB; an icon of at most 256 KiB,
# 8 MiB of icons in all.
#
# Exits 0; 2 for a call that is wrong or an id that cannot be one, 4 when
# launch is asked for an application list does not show, 5 when the VM's
# window manager is not running.
#
# For the tests: MONAD_ROOT goes before every file and folder read or
# written here (never before what launch runs), and with MONAD_APPS_RUN
# launch appends the command line to that file and starts nothing.
set -u
# Bytes are bytes while desktop files are read: a name is cut and encoded
# byte by byte, and A-Z must mean ASCII. The program launch starts gets the
# locale back that the caller had.
caller_locale=${LC_ALL-}
caller_has_locale=${LC_ALL+yes}
LC_ALL=C
export LC_ALL

ROOT=${MONAD_ROOT:-}
nl='
'

usage() {
    echo "usage: apps list | icons [id ...] | launch <id>" >&2
    exit 2
}

# An id is part of a line the Mac parses and of a file name here.
valid_id() {
    case $1 in
        '' | *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    [ "${#1}" -le 128 ]
}

# One data folder's desktop files: a line "D<folder>", then the files with
# their sizes as wc prints them ("SIZE ./ID.desktop"). wc takes them many
# at a time: a VM has a hundred or more, and a process for each would be
# felt every time the list is asked for. It is given nothing but names
# that are ids, so no wc has a reason to print a name its own way.
folder() { # folder DIRECTORY
    case $1 in
        /*) ;;
        *) return 0 ;;   # XDG: a folder that is not absolute is not one
    esac
    case $ROOT$1 in
        *"$nl"*) return 0 ;;   # its name would not be one line
    esac
    (
        CDPATH= cd -- "$ROOT$1/applications" 2>/dev/null || exit 0
        printf 'D%s\n' "$ROOT$1/applications"
        set --
        for f in *.desktop; do
            valid_id "${f%.desktop}" && [ -f "$f" ] && [ -r "$f" ] || continue
            set -- ${1+"$@"} "./$f"   # an id may begin with "-", an option to wc
            if [ $# -ge 64 ]; then
                wc -c "$@" 2>/dev/null
                set --
            fi
        done
        [ $# -eq 0 ] || wc -c "$@" 2>/dev/null
    )
}

# Every desktop file there is, in the order they count.
candidates() {
    folder "${XDG_DATA_HOME:-${HOME:+$HOME/.local/share}}"
    rest=${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:
    while [ -n "$rest" ]; do
        folder "${rest%%:*}"
        rest=${rest#*:}
    done
    folder /var/lib/snapd/desktop
    folder /var/lib/flatpak/exports/share
}

# The applications, as one subcommand needs them. awk reads each desktop
# file once, and nothing of a file reaches the shell from here but, for
# icons and launch, the values they are about.
#   list            the lines of "apps list"
#   icons           "path <id> <file>" or "name <id> <icon name>" for each icon
#   launch <id>     "P<folder>" and "E<command line>" when list shows the id
entries() { # entries MODE [ID]
    candidates | awk -v mode="$1" -v want="${2:-}" '
        function trim(s) {
            sub(/^[ \t]+/, "", s)
            sub(/[ \t]+$/, "", s)
            return s
        }
        # A text as one word of printable ASCII, from at most 127 of its bytes.
        function word(s,    out, i, c, n) {
            if (length(s) > 127) {
                # Cut before a character, never inside one: a UTF-8 character
                # is one byte and then up to three of 0x80 to 0xBF.
                n = 127
                for (i = 0; i < 3 && n > 0; i++) {
                    c = byte[substr(s, n + 1, 1)]
                    if (c < 128 || c > 191) break
                    n--
                }
                s = substr(s, 1, n)
            }
            if (s == "") return "-"
            if (s == "-") return "%2D"
            out = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                n = byte[c]   # a NUL byte is not in the table, and is 0
                out = out ((n > 32 && n < 127 && c != "%") ? c : sprintf("%%%02X", n))
            }
            return out
        }
        # An Exec line as the command to run: no file or URL is handed over,
        # so the field codes go, and %% is the percent sign it stands for.
        function command(s,    out, i, c, d) {
            out = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "%" && i < length(s)) {
                    d = substr(s, i + 1, 1)
                    if (d == "%" || index("fFuUdDnNickvm", d) > 0) {
                        if (d == "%") out = out "%"
                        i++
                        continue
                    }
                }
                out = out c
            }
            return trim(out)
        }
        # The keys of the [Desktop Entry] group into v. The groups after it
        # (the actions of an application) have a Name and an Exec of their own.
        function entry(path,    line, inside, eq, key) {
            split("", v)
            inside = 0
            while ((getline line < path) > 0) {
                sub(/\r$/, "", line)
                if (line ~ /^\[/) {
                    if (inside) break
                    inside = (line ~ /^\[Desktop Entry\][ \t]*$/)
                    continue
                }
                eq = index(line, "=")
                if (!inside || eq < 2 || line ~ /^#/) continue
                key = substr(line, 1, eq - 1)
                sub(/[ \t]+$/, "", key)
                v[key] = trim(substr(line, eq + 1))
            }
            close(path)
        }
        BEGIN {
            # awk has no function for the number of a byte.
            for (i = 1; i < 256; i++) byte[sprintf("%c", i)] = i
            count = 0
        }
        /^D/ {
            dir = substr($0, 2)
            next
        }
        {
            # "SIZE ./ID.desktop"; the total wc adds after several files is no file.
            if ($0 !~ /^[ \t]*[0-9]+ \.\/[A-Za-z0-9._-]+\.desktop$/) next
            size = $1
            id = substr($2, 3, length($2) - 10)
            path = dir "/" id ".desktop"
            if (id in seen) next
            seen[id] = 1
            if (count >= 256 || size + 0 > 65536) next
            entry(path)
            if (v["Type"] != "Application" || v["Name"] == "" || v["Exec"] == "") next
            if (v["NoDisplay"] == "true" || v["Hidden"] == "true" || v["Terminal"] == "true") next
            count++
            if (mode == "list") {
                print "app", id, word(v["Icon"]), word(v["Name"])
            } else if (mode == "icons") {
                icon = v["Icon"]
                if (icon ~ /^\//) print "path", id, icon
                else if (icon != "" && length(icon) <= 128 && icon !~ /[^A-Za-z0-9._+-]/) print "name", id, icon
            } else if (id == want) {
                print "P" v["Path"]
                print "E" command(v["Exec"])
            }
        }
        END {
            if (mode == "list") print "end", count
        }
    '
}

# Sets $file to an SVG file's PNG, or leaves it empty. Drawn once and kept
# until the SVG changes: rsvg-convert takes longer than all the rest.
converted() { # converted ID SVG
    [ -n "$cache" ] || return 0
    png=$cache/$1.png
    if [ -f "$png" ] && [ "$png" -nt "$2" ]; then
        file=$png
        return 0
    fi
    command -v rsvg-convert >/dev/null 2>&1 || return 0
    mkdir -p "$cache" 2>/dev/null || return 0
    # Under another name first: a drawing half written must never be handed out.
    if rsvg-convert -w 128 -h 128 "$2" 2>/dev/null </dev/null >"$png.$$" && [ -s "$png.$$" ] && mv -f "$png.$$" "$png"; then
        file=$png
    else
        rm -f "$png.$$"
    fi
}

# Sets $file to the PNG file of an application's icon, or to nothing.
icon_file() { # icon_file ID path|name ICON
    file=
    case $2 in
        path)
            [ -f "$ROOT$3" ] || return 0
            case $3 in
                *.png) file=$ROOT$3 ;;
                *.svg) converted "$1" "$ROOT$3" ;;
            esac ;;
        name)
            for px in 128 256 96 64 48 32; do
                f=$ROOT/usr/share/icons/hicolor/${px}x$px/apps/$3.png
                [ ! -f "$f" ] || { file=$f; return 0; }
            done
            f=$ROOT/usr/share/pixmaps/$3.png
            [ ! -f "$f" ] || { file=$f; return 0; }
            for f in "$ROOT/usr/share/icons/hicolor/scalable/apps/$3.svg" \
                "$ROOT/usr/share/icons/Adwaita/scalable/apps/$3.svg" \
                "$ROOT/usr/share/pixmaps/$3.svg"; do
                [ ! -f "$f" ] || { converted "$1" "$f"; return 0; }
            done ;;
    esac
}

# Whether a file starts as a PNG file does.
is_png() {
    set -- $(od -An -tx1 -N8 "$1" 2>/dev/null)
    [ $# -eq 8 ] && [ "$1$2$3$4$5$6$7$8" = 89504e470d0a1a0a ]
}

icons() { # icons [ID...]
    cache=${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}
    case $cache in
        /*) cache=$ROOT$cache/monad/icons ;;
        *) cache= ;;
    esac
    found=$(entries icons)
    if [ $# -gt 0 ]; then
        asked=
        for id; do
            valid_id "$id" || { echo "apps: that cannot be an application's id" >&2; exit 2; }
            line=$(printf '%s\n' "$found" | awk -v id="$id" '$2 == id { print; exit }')
            [ -z "$line" ] || asked=$asked$line$nl
        done
        found=$asked
    fi
    total=0
    printf '%s\n' "$found" | while read -r kind id icon; do
        [ -n "$kind" ] || continue
        icon_file "$id" "$kind" "$icon"
        [ -n "$file" ] || continue
        bytes=$(wc -c 2>/dev/null < "$file") || continue
        bytes=$((bytes + 0))   # some wc put blanks before the number
        [ "$bytes" -gt 0 ] && [ "$bytes" -le 262144 ] && [ $((total + bytes)) -le 8388608 ] && is_png "$file" || continue
        total=$((total + bytes))
        printf 'icon %s %s\n' "$id" "$bytes"
        # Never more bytes than the line before said, whatever becomes of the file meanwhile.
        head -c "$bytes" "$file"
    done
    echo end
}

launch() { # launch ID
    valid_id "$1" || { echo "apps: that cannot be an application's id" >&2; exit 2; }
    found=$(entries launch "$1")
    [ -n "$found" ] || { printf 'No such application: %s\n' "$1" >&2; exit 4; }
    dir=${found%%"$nl"*}
    dir=${dir#P}
    run=${found#*"$nl"}
    run=${run#E}
    runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
    [ -S "$runtime/wayland-0" ] || { echo "The VM's window manager is not running." >&2; exit 5; }
    if [ -n "${MONAD_APPS_RUN:-}" ]; then
        printf '%s\n' "$run" >> "$MONAD_APPS_RUN"
        exit 0
    fi
    if [ -n "$caller_has_locale" ]; then LC_ALL=$caller_locale; else unset LC_ALL; fi
    # An ssh command has no session of a desktop: the program is told where
    # Monad's window manager is, and the toolkits that would rather look for
    # an X server are told to use Wayland.
    # The desktop's name is Monad's: GTK then reads the settings Monad set
    # for it (wm-session), and draws no window buttons beside the Mac's.
    XDG_RUNTIME_DIR=$runtime
    WAYLAND_DISPLAY=wayland-0
    XDG_SESSION_TYPE=wayland
    XDG_CURRENT_DESKTOP=Monad
    MOZ_ENABLE_WAYLAND=1
    QT_QPA_PLATFORM="wayland;xcb"
    export XDG_RUNTIME_DIR WAYLAND_DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP MOZ_ENABLE_WAYLAND QT_QPA_PLATFORM
    # While the Mac is there to draw (GPU drawing, in the VM's settings in Monad),
    # the program finds Monad's own OpenGL ES library before the system's.
    gl=/usr/local/lib/monad/gl/lib
    if [ -S "$runtime/monad-gl" ] && [ -e "$ROOT$gl/libEGL.so.1" ]; then
        LD_LIBRARY_PATH=$gl${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
        export LD_LIBRARY_PATH
    fi
    [ -z "$dir" ] || [ ! -d "$dir" ] || CDPATH= cd -- "$dir" 2>/dev/null || :
    # A session of its own and nothing of ssh's left open, or the program
    # would end with the ssh command, or keep it from ending. The Exec line
    # is the one text of a desktop file that the shell reads: that is what
    # it is for.
    if ! command -v setsid >/dev/null 2>&1; then
        nohup sh -c "exec $run" </dev/null >/dev/null 2>&1 &
    elif setsid -f true </dev/null >/dev/null 2>&1; then
        setsid -f sh -c "exec $run" </dev/null >/dev/null 2>&1
    else
        setsid sh -c "exec $run" </dev/null >/dev/null 2>&1 &   # a setsid that cannot fork (busybox)
    fi
    exit 0
}

case ${1:-} in
    list) [ $# -eq 1 ] || usage; entries list ;;
    icons) [ $# -le 65 ] || usage; shift; icons "$@" ;;
    launch) [ $# -eq 2 ] || usage; launch "$2" ;;
    *) usage ;;
esac
