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

    /// What the Mac's title bar says: the program's title (its name when
    /// it has none), then the VM's name, always: a program in a VM cannot
    /// pass for a window of the Mac's.
    static func title(_ window: GuestWindow, vm: String) -> String {
        let own = !window.title.isEmpty ? window.title : !window.appID.isEmpty ? window.appID : "Linux program"
        return "\(own.count > 80 ? own.prefix(80) + "…" : own) — \(vm)"
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
