#!/bin/sh
# Tests for Monad/Guest/monad-wm-session.sh: what the VM's window manager
# needs of the user's session before it starts and after it stops. The
# user's session is there for its programs; programs with a title bar of
# their own (GTK's) draw no window buttons on it while the Mac's are above
# them, without the user's own settings being touched; and all of it is
# undone when the window manager stops. Stand-ins for systemctl, loginctl,
# runuser, id and glib-compile-schemas, a folder as the VM's root.
# Usage: test_wm_session.sh [workdir]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../Monad/Guest/monad-wm-session.sh"
SH=${WM_SESSION_SHELL:-sh}
SH_PATH=$(command -v "$SH")   # the PATH below has no shell in it
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

SYS="$WORK/sys"
BIN="$WORK/bin"
ROOT="$WORK/root"
mkdir -p "$SYS" "$BIN" "$ROOT"
for tool in awk cat cmp mkdir mv rm; do
    real=$(command -v "$tool") || { echo "test_wm_session.sh: no $tool" >&2; exit 1; }
    ln -s "$real" "$SYS/$tool"
done
# Each stand-in notes how it was called; FAILS names the ones that fail.
for tool in systemctl loginctl glib-compile-schemas; do
    cat > "$BIN/$tool" <<EOF
#!$SH_PATH
echo "$tool \$*" >> "$WORK/calls"
case " \${FAILS:-} " in *" $tool "*) exit 1 ;; esac
exit 0
EOF
    chmod 755 "$BIN/$tool"
done
# runuser -u USER -- COMMAND...: noted, and the command run (it is another stand-in).
cat > "$BIN/runuser" <<EOF
#!$SH_PATH
echo "runuser \$*" >> "$WORK/calls"
case " \${FAILS:-} " in *" runuser "*) exit 1 ;; esac
shift 3
exec "\$@"
EOF
cat > "$BIN/env" <<EOF
#!$SH_PATH
while [ \$# -gt 0 ]; do case \$1 in *=*) shift ;; *) break ;; esac; done
exec "\$@"
EOF
cat > "$BIN/id" <<EOF
#!$SH_PATH
[ "\$1" = -u ] && [ "\$2" = dev ] && { echo 1000; exit 0; }
echo "id: no such user" >&2
exit 1
EOF
chmod 755 "$BIN/runuser" "$BIN/env" "$BIN/id"

run() { # run [VAR=value ...] -- ARGS: the script; its output and status are kept
    vars=
    while [ "$1" != -- ]; do vars="$vars $1"; shift; done
    shift
    rm -f "$WORK/calls"
    # shellcheck disable=SC2086
    /usr/bin/env -i PATH="$BIN:$SYS" MONAD_ROOT="$ROOT" $vars "$SH_PATH" "$SCRIPT" "$@" > "$WORK/out" 2> "$WORK/err"
    status=$?
}
calls() { cat "$WORK/calls" 2>/dev/null; }
OVERRIDE="$ROOT/usr/share/glib-2.0/schemas/90_monad.gschema.override"
AS_USER="runuser -u dev -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"

# What is no user, or no word it knows: nothing is run.
run -- start 'dev; rm -rf /'
check "a name that is none: status" 64 "$status"
check "a name that is none: nothing run" "" "$(calls)"
run -- start nobody
check "an unknown user: status" 67 "$status"
run -- dance dev
check "an unknown word: status" 64 "$status"
run --
check "no word: status" 64 "$status"

# A VM with no settings schemas (no GTK there): the session only.
run -- start dev
check "plain: status" 0 "$status"
check "plain: the user's session, and its desktop's name" "loginctl enable-linger dev
systemctl start user@1000.service
$AS_USER systemctl --user set-environment XDG_CURRENT_DESKTOP=Monad
systemctl --user set-environment XDG_CURRENT_DESKTOP=Monad
$AS_USER systemctl --user try-restart xdg-desktop-portal-gtk.service xdg-desktop-portal-gnome.service xdg-desktop-portal.service
systemctl --user try-restart xdg-desktop-portal-gtk.service xdg-desktop-portal-gnome.service xdg-desktop-portal.service" "$(calls)"
check "plain: no override written where no schemas are" no "$([ -e "$OVERRIDE" ] && echo yes || echo no)"

# With schemas: the override for programs under Monad's window manager, compiled once.
mkdir -p "$ROOT/usr/share/glib-2.0/schemas"
run -- start dev
check "schemas: status" 0 "$status"
check "schemas: the override" "[org.gnome.desktop.wm.preferences:Monad]
button-layout=':'" "$(cat "$OVERRIDE")"
check "schemas: compiled" "glib-compile-schemas $ROOT/usr/share/glib-2.0/schemas" "$(calls | grep glib)"
run -- start dev
check "schemas, again: not compiled again" "" "$(calls | grep glib)"
echo stale > "$OVERRIDE"
run -- start dev
check "schemas, changed: written again" "button-layout=':'" "$(grep button "$OVERRIDE")"
check "schemas, changed: compiled again" 1 "$(calls | grep -c glib)"

# No compiler of schemas: the override is not left half in force, and the window manager still starts.
mv "$BIN/glib-compile-schemas" "$WORK/glib-compile-schemas.away"
rm "$OVERRIDE"
run -- start dev
check "no schema compiler: status" 0 "$status"
check "no schema compiler: no override" no "$([ -e "$OVERRIDE" ] && echo yes || echo no)"
mv "$WORK/glib-compile-schemas.away" "$BIN/glib-compile-schemas"

# What fails: without the user's session there is no window manager; the rest is not worth stopping for.
run FAILS=loginctl -- start dev
check "no lingering: fails" 1 "$status"
run FAILS=systemctl -- start dev
check "no session: fails" 1 "$status"
run FAILS=runuser -- start dev
check "the session's settings fail: it starts all the same" 0 "$status"
rm -f "$OVERRIDE"
run FAILS=glib-compile-schemas -- start dev
check "the schemas do not compile: it starts all the same" 0 "$status"
check "the schemas do not compile: no override left" no "$([ -e "$OVERRIDE" ] && echo yes || echo no)"

run -- size
check "a word that is none: refused" 64 "$status"

# Stopping: the session is as it was for whatever has the display next.
run -- stop dev
check "stop: status" 0 "$status"
check "stop: the desktop's name is taken back" "$AS_USER systemctl --user unset-environment XDG_CURRENT_DESKTOP
systemctl --user unset-environment XDG_CURRENT_DESKTOP
$AS_USER systemctl --user try-restart xdg-desktop-portal-gtk.service xdg-desktop-portal-gnome.service xdg-desktop-portal.service
systemctl --user try-restart xdg-desktop-portal-gtk.service xdg-desktop-portal-gnome.service xdg-desktop-portal.service" "$(calls)"
run FAILS="runuser systemctl" -- stop dev
check "stop: never fails" 0 "$status"

echo "test_wm_session.sh ($SH): $checks checks, $failures failures"
[ "$failures" -eq 0 ]
