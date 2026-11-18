//
//  GuestWindowLayout.swift — where a Linux program's window is on the Mac,
//  and what the Mac's pointer is in the program's terms: the arithmetic of
//  LinuxAppWindows.swift, apart from any window so that it is tested.
//
//  The VM has one display, on which its window manager gave each window a
//  place of its own. A Mac window shows the whole display through a view
//  the size of the display, moved behind the window so that only the
//  window's own place is inside it.
//

import CoreGraphics
import Foundation

enum GuestWindowLayout {
    /// The Mac window's content in points: the window proper (without a
    /// shadow the program draws around it), its pixels by the scale it
    /// was drawn at.
    static func contentSize(_ window: GuestWindow) -> CGSize {
        CGSize(width: CGFloat(window.innerWidth) / CGFloat(window.scale), height: CGFloat(window.innerHeight) / CGFloat(window.scale))
    }

    /// Where the view of the whole display lies in the window's content
    /// for the window's own part to be what shows, counted from the
    /// content's top left as the display's pixels are (the content view is
    /// flipped): the content can change size without this changing.
    static func displayFrame(_ window: GuestWindow, display: GuestDisplaySize) -> CGRect {
        let scale = CGFloat(window.scale)
        return CGRect(x: -CGFloat(window.x + window.innerX) / scale, y: -CGFloat(window.y + window.innerY) / scale,
                      width: CGFloat(display.width) / scale, height: CGFloat(display.height) / scale)
    }

    /// A point of the content (from its top left, in points) as the
    /// program gets the pointer: from its surface's top left, in 1/256 of
    /// its units. A point is a unit, whatever scale the program drew at.
    static func pointer(_ point: CGPoint, in window: GuestWindow) -> (x: Int32, y: Int32) {
        let scale = CGFloat(window.scale)
        return (fixed(point.x + CGFloat(window.innerX) / scale), fixed(point.y + CGFloat(window.innerY) / scale))
    }

    /// The Linux code of a mouse button, by AppKit's number for it.
    static func button(_ number: Int) -> UInt32? {
        (0...4).contains(number) ? UInt32(0x110 + number) : nil
    }

    /// Scrolling as the program gets it, in 1/256 of a unit, down and
    /// right positive. On the Mac the content follows the fingers, so the
    /// signs turn around. A wheel's step is 15 points.
    static func scroll(deltaX: CGFloat, deltaY: CGFloat, precise: Bool) -> (dx: Int32, dy: Int32) {
        let step: CGFloat = precise ? 1 : 15
        return (fixed(-deltaX * step), fixed(-deltaY * step))
    }

    /// Where a popup's content begins on the window it is on: in points
    /// from that window's content's top left, down and right. The window
    /// manager says it in that window's pixels.
    static func popupOffset(_ popup: GuestWindow, on parent: GuestWindow) -> CGPoint {
        CGPoint(x: CGFloat(popup.offsetX) / CGFloat(parent.scale), y: CGFloat(popup.offsetY) / CGFloat(parent.scale))
    }

    /// The parts of a popup that are there, in points from its content's
    /// top left, down: the Mac's window is cut to them, so a menu's round
    /// corners and its arrow show what is behind the menu. nil when the
    /// popup is all there.
    static func shape(_ popup: GuestWindow) -> [CGRect]? {
        guard !popup.shape.isEmpty else { return nil }
        let scale = CGFloat(popup.scale)
        var y = 0
        var rects: [CGRect] = []
        for band in popup.shape {
            if band.width > 0 {
                rects.append(CGRect(x: CGFloat(band.x) / scale, y: CGFloat(y) / scale,
                                    width: CGFloat(band.width) / scale, height: CGFloat(band.height) / scale))
            }
            y += band.height
        }
        return rects
    }

    /// Whether a popup at `offset` (from its window's content's top left)
    /// touches that window: a menu hangs from its window and a tooltip
    /// stands on it, a few points away at most. Nothing larger than a
    /// screen is a popup.
    static func popupTouches(offset: CGPoint, size: CGSize, window: CGSize) -> Bool {
        let popup = CGRect(origin: offset, size: size)
        guard popup.origin.x.isFinite, popup.origin.y.isFinite, size.width >= 1, size.height >= 1,
              size.width <= 8192, size.height <= 8192 else { return false }
        return popup.intersects(CGRect(origin: .zero, size: window).insetBy(dx: -8, dy: -8))
    }

    /// What the Mac's title bar says: the program's title (its name when
    /// it has none), then the VM's name, always: a program in a VM cannot
    /// pass for a window of the Mac's.
    static func title(_ window: GuestWindow, vm: String) -> String {
        let own = !window.title.isEmpty ? window.title : !window.appID.isEmpty ? window.appID : "Linux program"
        return "\(own.count > 80 ? own.prefix(80) + "…" : own) — \(vm)"
    }

    /// Whether a colour (0xRRGGBB) is dark to the eye. The Mac's title bar
    /// takes the colour of the bar a program drew under it, and its text
    /// and buttons are then drawn for a dark or a light bar.
    static func isDark(_ color: UInt32) -> Bool {
        let r = Double((color >> 16) & 0xff), g = Double((color >> 8) & 0xff), b = Double(color & 0xff)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b < 128
    }

    /// Whether what a program asks of its window is the user's doing, and
    /// so done. A move: the user holds the button down in that window (a
    /// drag of the bar the program drew, begun a moment ago). A zoom or
    /// putting it away: the user clicked or pressed a key in that window
    /// just before. Asked at any other time, nothing happens: a program
    /// in a VM does not move or resize the Mac's windows by itself.
    static func wishIsTheUsers(_ ask: GuestWindowAsk, window: UInt32, lastInputWindow: UInt32, lastInputAt: Date?,
                               leftButtonDown: Bool, now: Date) -> Bool {
        guard let lastInputAt, lastInputWindow == window else { return false }
        let since = now.timeIntervalSince(lastInputAt)
        switch ask {
        case .move: return leftButtonDown && since >= 0 && since <= 5
        case .zoom, .minimize: return since >= 0 && since <= 1
        }
    }

    /// From one list of windows to the next: the new ones, the ones that
    /// are no longer as they were, and the ids of those that went.
    static func changes(from old: [GuestWindow], to new: [GuestWindow]) -> (opened: [GuestWindow], changed: [GuestWindow], closed: [UInt32]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(new.map(\.id))
        return (new.filter { before[$0.id] == nil },
                new.filter { window in before[window.id].map { $0 != window } ?? false },
                old.map(\.id).filter { !ids.contains($0) })
    }

    /// 256ths, within what the protocol carries; a number that is none is 0.
    private static func fixed(_ value: CGFloat) -> Int32 {
        guard !value.isNaN else { return 0 }
        let scaled = (value * 256).rounded()
        return scaled >= CGFloat(Int32.max) ? .max : scaled <= CGFloat(Int32.min) ? .min : Int32(scaled)
    }
}
