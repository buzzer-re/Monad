//
//  PaneContainerView.swift — a window's panes on screen (Phase 11): nested
//  split views built from the PaneTree, a PaneView per pane, kept as long
//  as the pane lives so its terminal goes on. Dividers go where the tree's
//  fractions say. AppKit resizes the panes itself too, while the split
//  views are built and when the window resizes, and names a divider in
//  every resize; only a divider the user drags changes the fractions.
//

import AppKit

@MainActor
final class PaneContainerView: NSView, NSSplitViewDelegate {
    /// A pane's view was made (the window sets up its header and drops).
    var onNewPane: ((PaneView) -> Void)?
    /// The user dragged a divider: the new fractions of the split at that path.
    var onFractions: (([Double], [Int]) -> Void)?

    private var paneViews: [PaneID: PaneView] = [:]

    override var isFlipped: Bool { true }

    func paneView(_ id: PaneID) -> PaneView? { paneViews[id] }

    /// The panes as `tree` has them: the split views again, the pane views
    /// of panes still there kept. Each pane has its frame before it is back
    /// in the window, so its terminal never takes the sizes the split views
    /// pass through while they are built.
    func show(_ tree: PaneTree) {
        for id in paneViews.keys where !tree.contains(id) { paneViews[id] = nil }
        subviews.forEach { $0.removeFromSuperview() }
        let top = build(tree.root, path: [])
        top.frame = bounds
        top.autoresizingMask = [.width, .height]
        if let split = top as? PaneSplitView { place(split, tree) }
        addSubview(top)
        layoutSubtreeIfNeeded()
    }

    private func build(_ node: PaneTree.Node, path: [Int]) -> NSView {
        switch node {
        case .pane(let id):
            if let view = paneViews[id] { return view }
            let view = PaneView(id: id)
            paneViews[id] = view
            onNewPane?(view)
            return view
        case .split(let s):
            let split = PaneSplitView(path: path)
            split.isVertical = s.axis == .horizontal
            split.dividerStyle = .thin
            split.delegate = self
            for (i, child) in s.children.enumerated() { split.addArrangedSubview(build(child, path: path + [i])) }
            return split
        }
    }

    /// The panes of `split` where the tree's fractions put them, then the
    /// splits inside it (the outer ones size them). The subviews come with
    /// the sizes they had, a new pane none: each gets its frame first, so
    /// that the split view, left to adjust or move its dividers one by one,
    /// cannot squeeze one out.
    private func place(_ split: PaneSplitView, _ tree: PaneTree) {
        let views = split.arrangedSubviews
        if let fractions = tree.fractions(ofSplitAt: split.path), fractions.count == views.count {
            let size = split.bounds.size
            let thickness = split.dividerThickness
            let length = split.isVertical ? size.width : size.height
            for (view, span) in zip(views, PaneGeometry.spans(fractions, length: length, thickness: thickness)) {
                let along = span.upperBound - span.lowerBound
                view.frame = split.isVertical ? NSRect(x: span.lowerBound, y: 0, width: along, height: size.height)
                    : NSRect(x: 0, y: span.lowerBound, width: size.width, height: along)
            }
            split.adjustSubviews()
            for (i, position) in PaneGeometry.dividerPositions(fractions, length: length, thickness: thickness).enumerated() {
                split.setPosition(position, ofDividerAt: i)
            }
        }
        for case let inner as PaneSplitView in views { place(inner, tree) }
    }

    // MARK: NSSplitViewDelegate

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let split = notification.object as? PaneSplitView, split.draggingDivider else { return }
        let sizes = split.arrangedSubviews.map { split.isVertical ? $0.frame.width : $0.frame.height }
        if let fractions = PaneGeometry.fractions(sizes) { onFractions?(fractions, split.path) }
    }
}

extension NSPasteboard.PasteboardType {
    /// A pane dragged by its header: "<window number> <pane id>".
    static let monadPane = NSPasteboard.PasteboardType("dev.monad.pane")
}

/// A split of the pane tree, with its place in it (child indices from the root).
final class PaneSplitView: NSSplitView {
    let path: [Int]
    /// The user is dragging one of its dividers: AppKit tracks the drag
    /// inside mouseDown (clicks elsewhere go to the panes).
    var draggingDivider = false

    init(path: [Int]) {
        self.path = path
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        draggingDivider = true
        defer { draggingDivider = false }
        super.mouseDown(with: event)
    }
}

/// One pane: a header when it has one (its context's title, to focus or
/// drag it), the visible context's view, and a ring when it is focused.
/// Laid out whenever it resizes, not on a later layout pass.
final class PaneView: NSView {
    let id: PaneID
    let header = PaneHeaderView()
    private var content: NSView?
    private let ring = PaneFocusRing()

    var showsHeader = false {
        didSet { if showsHeader != oldValue { place() } }
    }

    var isFocused = false {
        didSet { ring.isHidden = !isFocused }
    }

    /// Whether a dragged pane (its pasteboard string) may land here.
    var accepts: ((String) -> Bool)?
    /// A pane dropped here: on an edge, or the centre (nil).
    var onDrop: ((String, PaneTree.Edge?) -> Bool)?
    private let zone = PaneDropZoneView()

    init(id: PaneID) {
        self.id = id
        super.init(frame: .zero)
        addSubview(header)
        ring.isHidden = true
        addSubview(ring)
        zone.isHidden = true
        addSubview(zone)
        registerForDraggedTypes([.monadPane])
        place()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Shows a context's view (the one shown before leaves the hierarchy).
    func show(_ view: NSView) {
        guard view !== content else { return }
        content?.removeFromSuperview()
        content = view
        addSubview(view, positioned: .below, relativeTo: ring)
        place()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { place() }

    override func layout() {
        super.layout()
        place()
    }

    private func place() {
        let headerHeight: CGFloat = showsHeader ? PaneHeaderView.height : 0
        header.isHidden = !showsHeader
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        content?.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: max(0, bounds.height - headerHeight))
        ring.frame = bounds
        zone.frame = bounds
    }

    // MARK: Dropping a pane

    private func payload(_ sender: NSDraggingInfo) -> String? {
        sender.draggingPasteboard.string(forType: .monadPane).flatMap { accepts?($0) == true ? $0 : nil }
    }

    private func edge(_ sender: NSDraggingInfo) -> PaneTree.Edge? {
        PaneGeometry.dropEdge(at: convert(sender.draggingLocation, from: nil), in: bounds)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard payload(sender) != nil else {
            zone.isHidden = true
            return []
        }
        zone.edge = edge(sender)
        zone.isHidden = false
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { zone.isHidden = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        zone.isHidden = true
        guard let payload = payload(sender) else { return false }
        return onDrop?(payload, edge(sender)) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { zone.isHidden = true }
}

/// Where a dragged pane would land: half the pane on an edge, the whole
/// pane for its centre. It never takes clicks.
final class PaneDropZoneView: NSView {
    var edge: PaneTree.Edge? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let area: NSRect
        switch edge {
        case .left?: area = NSRect(x: b.minX, y: b.minY, width: b.width / 2, height: b.height)
        case .right?: area = NSRect(x: b.midX, y: b.minY, width: b.width / 2, height: b.height)
        case .top?: area = NSRect(x: b.minX, y: b.minY, width: b.width, height: b.height / 2)
        case .bottom?: area = NSRect(x: b.minX, y: b.midY, width: b.width, height: b.height / 2)
        case nil: area = b
        }
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        area.insetBy(dx: 4, dy: 4).fill()
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath(roundedRect: area.insetBy(dx: 4, dy: 4), xRadius: 6, yRadius: 6)
        path.lineWidth = 2
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A pane's title bar: its context's title. A click focuses the pane, a
/// drag moves it (onto another pane's edge or centre), a right-click
/// opens its menu.
final class PaneHeaderView: NSView, NSDraggingSource {
    static let height: CGFloat = 22
    private let label = NSTextField(labelWithString: "")
    private var pressedAt: NSPoint?
    var onClick: (() -> Void)?
    var menuItems: (() -> [NSMenuItem])?
    /// What a drag of this header carries (TerminalWindowController).
    var dragPayload: (() -> String?)?

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        // Not insetBy: on a header still too small that gives CGRect.null,
        // an infinite origin AppKit complains about.
        label.frame = NSRect(x: 8, y: 3, width: max(0, bounds.width - 16), height: max(0, bounds.height - 6))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        pressedAt = event.locationInWindow
        onClick?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressedAt, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4,
              let payload = dragPayload?() else { return }
        pressedAt = nil
        let item = NSPasteboardItem()
        item.setString(payload, forType: .monadPane)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = bitmapImageRepForCachingDisplay(in: bounds).map { rep -> NSImage in
            cacheDisplay(in: bounds, to: rep)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(rep)
            return image
        }
        dragging.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { pressedAt = nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let items = menuItems?(), !items.isEmpty else { return nil }
        let menu = NSMenu()
        items.forEach(menu.addItem)
        return menu
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

/// The focused pane's outline; it never takes clicks.
final class PaneFocusRing: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
