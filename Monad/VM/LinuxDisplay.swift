//
//  LinuxDisplay.swift — a Linux VM's display, when its Display setting is
//  on: a virtio-gpu framebuffer with a USB keyboard and a pointer, shown
//  in the desktop window MonadHost opens (MacDesktop.swift, as for a macOS
//  VM). It is the one display Apple's Virtualization gives a Linux guest:
//  a 2D framebuffer the Mac draws straight from the VM's memory. What is
//  on it is drawn in the guest by its CPUs; no GPU is passed in. Off, the
//  VM has no graphics, keyboard or pointer device at all, so nothing of
//  the guest reaches that code on the Mac (docs/SECURITY.md).
//

import Foundation

enum LinuxDisplay {
    /// The display's size until its window gives it the window's own.
    static let width = 1920
    static let height = 1200
    /// The desktop window's title after the VM's name.
    static let windowKind = "Desktop"

    /// ⌘V in the desktop window: the text on stdin becomes the clipboard of
    /// the session on the VM's display (a Wayland one through wl-copy, an
    /// X11 one through xclip), run as the VM's user. The Mac's clipboard
    /// goes in only when the user presses ⌘V there; the guest never reads it.
    static let pasteCommand = """
        u=$(id -u); \
        for s in /run/user/$u/wayland-[0-9]*; do \
        case $s in *.lock) continue;; esac; [ -S "$s" ] || continue; \
        XDG_RUNTIME_DIR=/run/user/$u WAYLAND_DISPLAY=${s##*/} wl-copy >/dev/null 2>&1 && exit 0; \
        done; \
        DISPLAY=:0 xclip -selection clipboard >/dev/null 2>&1
        """

    /// The desktop window is on a screen with `scale` pixels to a point (2
    /// on a Retina screen): left for the session on the display (the
    /// Desktop profile's display-follow), which is told to use it now.
    static func scaleCommand(_ scale: Int) -> String {
        "r=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}; echo \(min(max(scale, 1), 3)) > \"$r/monad-display-scale\"; "
            + "f=/usr/local/lib/monad/display-follow; if [ -x \"$f\" ]; then \"$f\" once; fi"
    }
}
