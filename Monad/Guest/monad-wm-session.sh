#!/bin/sh
# Monad: what the VM's window manager (monad-wm, which shows the VM's
# programs as windows on the Mac) needs of the user's session.
#
#   monad-wm-session start USER     before the window manager starts
#   monad-wm-session stop USER      after it stopped
#   monad-wm-session size           the display to ask for, as WIDTHxHEIGHT
#
# Run as root by monad-wm.service.
#
# size: every window has a place of its own on the display, and one that
# finds no room is not shown; at a Retina screen's scale two ordinary
# windows fill 3840x2160. So the display is four times that where the VM
# has the memory for it (its pixels are 127 MB of the VM's).
#
# start: the user's session is there, for the programs' sockets and
# settings. And programs that draw a title bar of their own (GTK's header
# bars) draw no window buttons on it: each window has the Mac's title bar
# above it, with the Mac's buttons, and a second close button under those
# is one too many. GTK takes its buttons from the desktop's settings, so
# the VM's session is named as a desktop of its own (Monad), for which
# those settings have a default of their own (a schema override). The
# user's own settings are not touched, and a desktop session on the same
# VM (the Desktop profile) keeps its buttons.
#
# stop: the session's name is taken back.
#
# Exits 0 when the window manager can start; 64 for arguments that make no
# sense, 67 for a user there is none of, and the status of what failed
# when the user's session cannot be had. The settings are a nicety: what
# fails there is left as it is.
set -u
root=${MONAD_ROOT:-}
word=${1:-}
user=${2:-}
if [ "$word" = size ]; then
    kb=$(awk '/^MemTotal:/ { print $2; exit }' "$root/proc/meminfo" 2>/dev/null)
    case $kb in "" | *[!0-9]*) kb=0 ;; esac
    if [ "$kb" -ge 3500000 ]; then echo 7680x4320; else echo 3840x2160; fi
    exit 0
fi
case $word in start | stop) ;; *) echo "usage: monad-wm-session start|stop USER, or size" >&2; exit 64 ;; esac
case $user in
    "" | *[!a-z0-9_-]* | -*) echo "monad-wm-session: \"$user\" is no user name" >&2; exit 64 ;;
esac
uid=$(id -u "$user" 2>/dev/null) || { echo "monad-wm-session: there is no user $user" >&2; exit 67; }

# A command in the user's session.
as_user() {
    runuser -u "$user" -- env "XDG_RUNTIME_DIR=/run/user/$uid" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" "$@" >/dev/null 2>&1
}
# What tells programs the desktop's settings reads them when it starts: it starts again, if it runs.
portals="xdg-desktop-portal-gtk.service xdg-desktop-portal-gnome.service xdg-desktop-portal.service"

if [ "$word" = stop ]; then
    as_user systemctl --user unset-environment XDG_CURRENT_DESKTOP
    # shellcheck disable=SC2086
    as_user systemctl --user try-restart $portals
    exit 0
fi

loginctl enable-linger "$user" || exit $?
systemctl start "user@$uid.service" || exit $?

# The default of a desktop called Monad: no window buttons on a program's own title bar.
schemas="$root/usr/share/glib-2.0/schemas"
override="$schemas/90_monad.gschema.override"
if [ -d "$schemas" ]; then
    wanted="[org.gnome.desktop.wm.preferences:Monad]
button-layout=':'"
    if [ "$(cat "$override" 2>/dev/null)" != "$wanted" ]; then
        compiler=$(command -v glib-compile-schemas 2>/dev/null) || compiler=
        if [ -z "$compiler" ]; then
            for candidate in "$root"/usr/lib/*/glib-2.0/glib-compile-schemas; do
                [ -x "$candidate" ] && compiler=$candidate
            done
        fi
        # Written only where it can be made to count, and taken back when it cannot.
        if [ -n "$compiler" ]; then
            printf '%s\n' "$wanted" > "$override" && "$compiler" "$schemas" >/dev/null 2>&1 || rm -f "$override"
        else
            rm -f "$override"
        fi
    fi
fi
as_user systemctl --user set-environment XDG_CURRENT_DESKTOP=Monad
# shellcheck disable=SC2086
as_user systemctl --user try-restart $portals
exit 0
