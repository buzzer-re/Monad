//
//  TabStripView.swift — a terminal window's tab strip, drawn from its
//  TabStrip where TabStripLayout puts things: each group's label in its
//  colour, with a line under the label and its tabs; tabs with their
//  title and a close button; "+" and the "…" menu. A click on a tab
//  brings it to front, on a label collapses or opens its group; tabs and
//  labels drag to another place; a right-click opens the tab's or the
//  group's menu, which the window fills. Monad draws the strip itself:
//  the system's tab bar has no place for groups.
//

import AppKit

extension TabGroupColor {
    /// The label's fill: strong under dark text on a dark window, deep
    /// under white text on a light one.
    func fill(dark: Bool) -> NSColor {
        let c: (Int, Int, Int)
        switch (self, dark) {
        case (.blue, true): c = (128, 170, 255)
        case (.blue, false): c = (0, 97, 224)
        case (.purple, true): c = (200, 160, 255)
        case (.purple, false): c = (130, 60, 210)
        case (.cyan, true): c = (128, 235, 255)
        case (.cyan, false): c = (0, 125, 150)
        case (.orange, true): c = (255, 170, 100)
        case (.orange, false): c = (190, 85, 0)
        case (.yellow, true): c = (255, 220, 100)
        case (.yellow, false): c = (140, 100, 0)
        case (.pink, true): c = (255, 150, 200)
        case (.pink, false): c = (200, 40, 120)
        case (.green, true): c = (130, 230, 150)
        case (.green, false): c = (0, 125, 60)
        case (.gray, true): c = (190, 190, 200)
        case (.gray, false): c = (95, 95, 105)
        case (.red, true): c = (255, 140, 140)
        case (.red, false): c = (200, 40, 40)
        }
        return NSColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
    }

    /// The colour's name, as menus show it.
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

@MainActor
final class TabStripView: NSView {
    private(set) var strip: TabStrip?
    private var titles: [TabID: String] = [:]
    private(set) var layout = TabStripLayout(items: [], chipWidths: [:], width: 0)

    /// Its own background and bottom line; off over a painted titlebar,
    /// which paints the strip's room too.
    var paintsBackground = true {
        didSet { needsDisplay = true }
    }

    var onSelect: ((TabID) -> Void)?
    var onClose: ((TabID) -> Void)?
    var onToggleGroup: ((TabGroupID) -> Void)?
    var onDrop: ((TabStrip.Item, TabStrip.Drop) -> Void)?
    var onNewTab: (() -> Void)?
    var tabMenu: ((TabID) -> NSMenu?)?
    var groupMenu: ((TabGroupID) -> NSMenu?)?

    /// The "…" at the far end (new tabs and VMs).
    let menuButton: TabMenuButton

    private enum Press: Equatable {
        case item(TabStrip.Item)
        case close(TabID)
        case plus
    }
    private var pressed: Press?
    private var pressedAt = NSPoint.zero
    /// Where the item being dragged would land.
    private var dropTarget: TabStrip.Drop?
    private var hovered: NSPoint?
    private var tracking: NSTrackingArea?

    private static let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let titleFont = NSFont.systemFont(ofSize: 12)

    init(owner: TerminalWindowController?) {
        menuButton = TabMenuButton(owner: owner)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: TabStripLayout.height))
        addSubview(menuButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The strip as it is now, with each tab's title.
    func show(_ strip: TabStrip, titles: [TabID: String]) {
        self.strip = strip
        self.titles = titles
        relayout()
    }

    /// A group's label in this view, to point a popover at.
    func frame(of group: TabGroupID) -> NSRect? {
        layout.slots.first { $0.item == .group(group) }?.frame
    }

    /// The label's width for a name (none: a bare dot of colour).
    static func chipWidth(_ name: String) -> CGFloat {
        name.isEmpty ? 0 : ceil((name as NSString).size(withAttributes: [.font: labelFont]).width) + 18
    }

    private func relayout() {
        var widths: [TabGroupID: CGFloat] = [:]
        for g in strip?.groups ?? [] { widths[g.id] = Self.chipWidth(g.name) }
        layout = TabStripLayout(items: strip?.items ?? [], chipWidths: widths, width: bounds.width)
        menuButton.frame = layout.menu
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if paintsBackground {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
        guard let strip else { return }
        let dark = isDark
        // A group's line, under its label and the tabs of it that show.
        var lines: [TabGroupID: (minX: CGFloat, maxX: CGFloat)] = [:]
        for slot in layout.slots {
            let id: TabGroupID?
            switch slot.item {
            case .group(let g): id = g
            case .tab(let t): id = strip.group(of: t)?.id
            }
            guard let id else { continue }
            lines[id] = (min(lines[id]?.minX ?? slot.frame.minX, slot.frame.minX), slot.frame.maxX)
        }
        for (id, span) in lines {
            guard let group = strip.group(id), layout.slots.contains(where: {
                if case .tab(let t) = $0.item { return strip.group(of: t)?.id == id }
                return false
            }) else { continue }
            group.color.fill(dark: dark).setFill()
            NSBezierPath(roundedRect: NSRect(x: span.minX, y: TabStripLayout.underlineY, width: span.maxX - span.minX, height: 2),
                         xRadius: 1, yRadius: 1).fill()
        }
        for slot in layout.slots {
            switch slot.item {
            case .group(let id):
                if let group = strip.group(id) { draw(group, in: slot.frame, hidden: strip.hiddenCount(in: id), dark: dark) }
            case .tab(let id):
                drawTab(id, in: slot.frame, selected: id == strip.selected)
            }
        }
        drawPlus()
        drawDropTarget()
    }

    private func draw(_ group: TabGroup, in frame: NSRect, hidden: Int, dark: Bool) {
        group.color.fill(dark: dark).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7).fill()
        guard !group.name.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: group.name, attributes: [
            .font: Self.labelFont, .paragraphStyle: style,
            .foregroundColor: dark ? NSColor(white: 0.08, alpha: 1) : NSColor.white,
        ])
        let height = text.size().height
        text.draw(in: NSRect(x: frame.minX + 6, y: frame.midY - height / 2, width: frame.width - 12, height: height))
    }

    private func showsClose(_ frame: NSRect, selected: Bool) -> Bool {
        guard frame.width >= 72 else { return false }
        return selected || hovered.map(frame.contains) == true
    }

    private func drawTab(_ id: TabID, in frame: NSRect, selected: Bool) {
        let over = hovered.map(frame.contains) == true
        if selected || over {
            NSColor.labelColor.withAlphaComponent(selected ? 0.14 : 0.06).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7).fill()
        }
        if selected {
            NSColor.labelColor.withAlphaComponent(0.18).setStroke()
            NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).stroke()
        }
        let close = showsClose(frame, selected: selected)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: titles[id] ?? "", attributes: [
            .font: Self.titleFont, .paragraphStyle: style,
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        let height = text.size().height
        let room = frame.width - 20 - (close ? 18 : 0)
        if room > 4 { text.draw(in: NSRect(x: frame.minX + 10, y: frame.midY - height / 2, width: room, height: height)) }
        guard close else { return }
        let box = TabStripLayout.closeBox(in: frame)
        if hovered.map(box.contains) == true {
            NSColor.labelColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        }
        let x = NSBezierPath()
        let r = box.insetBy(dx: 4.5, dy: 4.5)
        x.move(to: NSPoint(x: r.minX, y: r.minY))
        x.line(to: NSPoint(x: r.maxX, y: r.maxY))
        x.move(to: NSPoint(x: r.maxX, y: r.minY))
        x.line(to: NSPoint(x: r.minX, y: r.maxY))
        x.lineWidth = 1.3
        x.lineCapStyle = .round
        NSColor.secondaryLabelColor.setStroke()
        x.stroke()
    }

    private func drawPlus() {
        let box = layout.plus
        if hovered.map(box.contains) == true {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: box.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let plus = NSBezierPath()
        plus.move(to: NSPoint(x: box.midX - 5, y: box.midY))
        plus.line(to: NSPoint(x: box.midX + 5, y: box.midY))
        plus.move(to: NSPoint(x: box.midX, y: box.midY - 5))
        plus.line(to: NSPoint(x: box.midX, y: box.midY + 5))
        plus.lineWidth = 1.5
        plus.lineCapStyle = .round
        NSColor.secondaryLabelColor.setStroke()
        plus.stroke()
    }

    /// While something is dragged: a bar where it would land.
    private func drawDropTarget() {
        guard let dropTarget else { return }
        let half = TabStripLayout.gap / 2
        let x: CGFloat
        switch dropTarget {
        case .before(let item): x = (layout.slots.first { $0.item == item }?.frame.minX ?? 0) - half
        case .after(let item): x = (layout.slots.first { $0.item == item }?.frame.maxX ?? 0) + half
        case .end: x = (layout.slots.last?.frame.maxX ?? 0) + half
        }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: x - 1.5, y: TabStripLayout.itemY, width: 3, height: TabStripLayout.itemHeight),
                     xRadius: 1.5, yRadius: 1.5).fill()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressedAt = p
        dropTarget = nil
        if layout.plus.contains(p) {
            pressed = .plus
        } else if let slot = layout.slot(at: p) {
            if case .tab(let id) = slot.item {
                if showsClose(slot.frame, selected: id == strip?.selected), TabStripLayout.closeBox(in: slot.frame).contains(p) {
                    pressed = .close(id)
                    return
                }
                pressed = .item(slot.item)
                onSelect?(id)
            } else {
                pressed = .item(slot.item)
            }
        } else {
            // The bare strip is the window's: it drags it, and a
            // double-click zooms it, as on a titlebar.
            pressed = nil
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .item = pressed else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard dropTarget != nil || abs(p.x - pressedAt.x) > 5 else { return }
        dropTarget = layout.drop(at: p.x)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let was = pressed, target = dropTarget
        pressed = nil
        dropTarget = nil
        needsDisplay = true
        switch was {
        case .plus?:
            if layout.plus.contains(p) { onNewTab?() }
        case .close(let id)?:
            if let slot = layout.slots.first(where: { $0.item == .tab(id) }), TabStripLayout.closeBox(in: slot.frame).contains(p) {
                onClose?(id)
            }
        case .item(let item)?:
            if let target {
                onDrop?(item, target)
            } else if case .group(let id) = item {
                onToggleGroup?(id)
            }
        case nil:
            break
        }
    }

    /// A middle click closes a tab.
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, middleClick(at: convert(event.locationInWindow, from: nil)) else {
            super.otherMouseUp(with: event)
            return
        }
    }

    /// A middle click at `point`; false when no tab is there.
    func middleClick(at point: NSPoint) -> Bool {
        guard case .tab(let id)? = layout.slot(at: point)?.item else { return false }
        onClose?(id)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        switch layout.slot(at: convert(event.locationInWindow, from: nil))?.item {
        case .tab(let id)?: return tabMenu?(id)
        case .group(let id)?: return groupMenu?(id)
        case nil: return nil
        }
    }
}

/// A menu item that runs a closure (the tab strip's menus).
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, enabled: Bool = true, checked: Bool = false, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: enabled ? #selector(fire) : nil, keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { run() }
}

/// A group's name and colour, in a popover under its label: the name as
/// it is typed, the colour as it is clicked.
@MainActor
final class TabGroupEditor: NSViewController, NSTextFieldDelegate {
    private let group: TabGroup
    private let onName: (String) -> Void
    private let onColor: (TabGroupColor) -> Void
    private let field = NSTextField()
    private var swatches: [TabGroupColor: NSButton] = [:]
    private var color: TabGroupColor
    /// Return in the name: the popover closes.
    var onDone: (() -> Void)?

    init(group: TabGroup, onName: @escaping (String) -> Void, onColor: @escaping (TabGroupColor) -> Void) {
        self.group = group
        self.onName = onName
        self.onColor = onColor
        color = group.color
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let colors = TabGroupColor.allCases
        let side: CGFloat = 20, gap: CGFloat = 6, margin: CGFloat = 14
        let width = margin * 2 + CGFloat(colors.count) * side + CGFloat(colors.count - 1) * gap
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 96))
        let title = NSTextField(labelWithString: "Tab group")
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: margin, y: 72, width: width - margin * 2, height: 16)
        field.frame = NSRect(x: margin, y: 44, width: width - margin * 2, height: 22)
        field.stringValue = group.name
        field.placeholderString = "Name"
        field.delegate = self
        field.target = self
        field.action = #selector(done(_:))
        root.addSubview(title)
        root.addSubview(field)
        for (i, c) in colors.enumerated() {
            let b = NSButton(frame: NSRect(x: margin + CGFloat(i) * (side + gap), y: 14, width: side, height: side))
            b.title = ""
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = side / 2
            b.toolTip = c.title
            b.setAccessibilityLabel(c.title)
            b.tag = i
            b.target = self
            b.action = #selector(pick(_:))
            swatches[c] = b
            root.addSubview(b)
        }
        view = root
        refreshSwatches()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
        refreshSwatches()
    }

    private func refreshSwatches() {
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for (c, b) in swatches {
            b.layer?.backgroundColor = c.fill(dark: dark).cgColor
            b.layer?.borderWidth = c == color ? 2.5 : 0
            b.layer?.borderColor = NSColor.labelColor.cgColor
        }
    }

    func controlTextDidChange(_ notification: Notification) { onName(field.stringValue) }

    /// Return and Esc in the name close the popover.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) else {
            return false
        }
        onName(field.stringValue)
        onDone?()
        return true
    }

    @objc private func pick(_ sender: NSButton) {
        guard TabGroupColor.allCases.indices.contains(sender.tag) else { return }
        color = TabGroupColor.allCases[sender.tag]
        refreshSwatches()
        onColor(color)
    }

    @objc private func done(_ sender: Any?) { onDone?() }
}
