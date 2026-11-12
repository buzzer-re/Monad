//
//  TabStripLayout.swift — where the tab strip (TabStripView) puts things:
//  group labels at the width of their name, tabs sharing the rest of the
//  room up to a width, the "+" after the last of them and the "…" at the
//  far end. Also what is under a point, and where a drag lets go there
//  (the nearer half of what is under it). Pure.
//

import CoreGraphics

struct TabStripLayout: Equatable {
    static let height: CGFloat = 36
    /// A tab is never narrower or wider than this.
    static let tabWidths: ClosedRange<CGFloat> = 48...220
    static let chipWidths: ClosedRange<CGFloat> = 26...160
    static let inset: CGFloat = 8
    static let gap: CGFloat = 4
    static let button: CGFloat = 26
    /// Labels and tabs, above the line a group draws under its own.
    static let itemY: CGFloat = 4
    static let itemHeight: CGFloat = 25
    static let underlineY: CGFloat = 31

    struct Slot: Equatable {
        var item: TabStrip.Item
        var frame: CGRect
    }

    let slots: [Slot]
    let plus: CGRect
    let menu: CGRect

    init(items: [TabStrip.Item], chipWidths: [TabGroupID: CGFloat], width: CGFloat) {
        let buttonY = Self.itemY + (Self.itemHeight - Self.button) / 2
        menu = CGRect(x: max(Self.inset, width - Self.inset - Self.button), y: buttonY, width: Self.button, height: Self.button)
        func chip(_ id: TabGroupID) -> CGFloat {
            min(max(chipWidths[id] ?? 0, Self.chipWidths.lowerBound), Self.chipWidths.upperBound)
        }
        var chips: CGFloat = 0
        var tabCount = 0
        for item in items {
            switch item {
            case .group(let id): chips += chip(id)
            case .tab: tabCount += 1
            }
        }
        // Everything but the tabs: the insets, the gaps, the labels, the "+".
        let fixed = Self.inset + chips + CGFloat(items.count) * Self.gap + Self.button + Self.gap
        let room = menu.minX - fixed
        let tabWidth = tabCount == 0 ? 0 : min(max(room / CGFloat(tabCount), Self.tabWidths.lowerBound), Self.tabWidths.upperBound)
        var x = Self.inset
        var out: [Slot] = []
        for item in items {
            let w: CGFloat
            switch item {
            case .group(let id): w = chip(id)
            case .tab: w = tabWidth
            }
            out.append(Slot(item: item, frame: CGRect(x: x, y: Self.itemY, width: w, height: Self.itemHeight)))
            x += w + Self.gap
        }
        slots = out
        // Too many tabs for the room: the "+" stays in sight, over the last.
        plus = CGRect(x: min(x, menu.minX - Self.gap - Self.button), y: buttonY, width: Self.button, height: Self.button)
    }

    func slot(at point: CGPoint) -> Slot? { slots.first { $0.frame.contains(point) } }

    /// Where a drag at `x` lets go: before or after what is under it, by
    /// its nearer half; in a gap, after what is before it; past the last,
    /// at the end.
    func drop(at x: CGFloat) -> TabStrip.Drop {
        guard let first = slots.first, let last = slots.last else { return .end }
        if x < first.frame.minX { return .before(first.item) }
        if x > last.frame.maxX + Self.gap { return .end }
        for slot in slots.reversed() where x >= slot.frame.minX {
            return x < slot.frame.midX ? .before(slot.item) : .after(slot.item)
        }
        return .end
    }

    /// A tab's close button.
    static func closeBox(in frame: CGRect) -> CGRect {
        let side: CGFloat = 16
        return CGRect(x: frame.maxX - side - 5, y: frame.midY - side / 2, width: side, height: side)
    }
}
