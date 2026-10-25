//
//  CanvasWindowController.swift — the canvas window (VM › Canvas): the
//  canvas on top and, once a VM's terminal is asked for there (a VM's
//  right-click or the inspector), a dock of terminal panes below it that
//  can be resized (TerminalPanes: splits, contexts, the pane menu, panes
//  dragged by their header). The Shell menu's splits and pane moves, and
//  ⌘W, act on the dock while its terminal is in front; its last context
//  going hides it. Phase 13's last step (docs/CANVAS.md).
//

import AppKit
import SwiftUI

@MainActor
final class CanvasWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let canvas: CanvasWindowModel
    private let host: HostClient
    private let splitController = NSSplitViewController()
    private let dockItem: NSSplitViewItem
    private let dockContent = NSView()
    private let dockTitle = NSTextField(labelWithString: "")
    private var dock: TerminalPanes?

    /// The dock's height when it first shows.
    static let dockHeight: CGFloat = 300

    init(host: HostClient? = nil, store: CanvasStore? = CanvasStore()) {
        let host = host ?? HostAgent.client
        self.host = host
        canvas = CanvasWindowModel(host: host, store: store)
        let window = CanvasWindow(contentRect: NSRect(origin: .zero, size: CanvasView.size),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: true)
        window.title = "Canvas"
        // The canvas runs under the titlebar, edge to edge.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        let top = NSSplitViewItem(viewController: NSHostingController(rootView: CanvasView(canvas: canvas)))
        top.minimumThickness = 240
        let dockController = NSViewController()
        dockController.view = Self.dockView(content: dockContent, title: dockTitle)
        dockItem = NSSplitViewItem(viewController: dockController)
        dockItem.minimumThickness = 120
        dockItem.canCollapse = true
        dockItem.isCollapsed = true
        dockItem.holdingPriority = .defaultLow + 1
        splitController.splitView.isVertical = false
        splitController.splitView.dividerStyle = .thin
        splitController.addSplitViewItem(top)
        splitController.addSplitViewItem(dockItem)

        super.init(window: window)
        window.delegate = self
        window.contentViewController = splitController
        window.setContentSize(CanvasView.size)
        canvas.onTerminal = { [weak self] name in self?.openTerminal(vm: name) }
        // ⌘Z and ⇧⌘Z (Edit › Undo, Redo) go through the window.
        canvas.undoManager = window.undoManager
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A slim bar (the terminal in front and a close button) above the panes.
    private static func dockView(content: NSView, title: NSTextField) -> NSView {
        let box = NSView()
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close the terminals") ?? NSImage(),
                             target: nil, action: #selector(CanvasWindowController.closeDockButton(_:)))
        close.isBordered = false
        close.toolTip = "Close the terminals in the canvas"
        let row = NSStackView(views: [icon, title, NSView(), close])
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(bar)
        box.addSubview(content)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: box.topAnchor),
            bar.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 26),
            row.topAnchor.constraint(equalTo: bar.topAnchor),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            content.topAnchor.constraint(equalTo: bar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    // MARK: The dock

    var dockIsShown: Bool { dock != nil && !dockItem.isCollapsed }

    /// The VMs with a terminal in the dock, pane by pane.
    var dockedVMs: [String] { dock?.vms ?? [] }

    /// A terminal on VM `name` in the dock: the one there is brought to
    /// front, else a new context in the focused pane.
    func openTerminal(vm name: String) {
        if let dock {
            if !dock.show(vm: name) { dock.addContext(.vm(name)) }
        } else {
            let panes = TerminalPanes(target: .vm(name), host: host)
            panes.onTitle = { [weak self] title, grid in
                self?.dockTitle.stringValue = grid.map { "\(title) — \($0.cols)×\($0.rows)" } ?? title
            }
            panes.onLastClosed = { [weak self] in self?.closeDock() }
            panes.view.frame = dockContent.bounds
            panes.view.autoresizingMask = [.width, .height]
            dockContent.addSubview(panes.view)
            dock = panes
            panes.refresh()
            panes.start()
        }
        if dockItem.isCollapsed {
            dockItem.isCollapsed = false
            let split = splitController.splitView
            split.setPosition(max(240, split.bounds.height - Self.dockHeight), ofDividerAt: 0)
        }
        dock?.focusTerminal()
    }

    /// Every terminal in the dock closed, and the dock hidden.
    func closeDock() {
        guard let panes = dock else { return }
        dock = nil
        panes.closeAllSessions()
        panes.view.removeFromSuperview()
        dockTitle.stringValue = ""
        dockItem.isCollapsed = true
    }

    @objc func closeDockButton(_ sender: Any?) { closeDock() }

    /// Whether the dock's terminal is in front (the Shell menu acts on it).
    private var dockHasFocus: Bool {
        guard let dock, let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: dock.view)
    }

    /// ⌘W: the dock's context in front closes, the dock with its last one.
    /// False when the dock's terminal is not in front (the window closes).
    func closeDockContextInFront() -> Bool {
        guard dockHasFocus, let dock else { return false }
        if !dock.closeContextInFront() { closeDock() }
        return true
    }

    func firstResponderChanged(_ responder: NSResponder?) { dock?.firstResponderChanged(responder) }

    // MARK: Shell menu, for the dock

    @objc func splitSideBySide(_ sender: Any?) { dock?.split(.horizontal) }
    @objc func splitStacked(_ sender: Any?) { dock?.split(.vertical) }
    @objc func selectPaneLeft(_ sender: Any?) { dock?.moveFocus(.left) }
    @objc func selectPaneRight(_ sender: Any?) { dock?.moveFocus(.right) }
    @objc func selectPaneAbove(_ sender: Any?) { dock?.moveFocus(.up) }
    @objc func selectPaneBelow(_ sender: Any?) { dock?.moveFocus(.down) }
    @objc func showNextContext(_ sender: Any?) { dock?.cycleContext(by: 1) }
    @objc func showPreviousContext(_ sender: Any?) { dock?.cycleContext(by: -1) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(splitSideBySide(_:)), #selector(splitStacked(_:)), #selector(selectPaneLeft(_:)),
             #selector(selectPaneRight(_:)), #selector(selectPaneAbove(_:)), #selector(selectPaneBelow(_:)),
             #selector(showNextContext(_:)), #selector(showPreviousContext(_:)):
            return dockHasFocus
        default:
            return true
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) { closeDock() }
}

/// The canvas window: ⌘W closes the dock's context in front while its
/// terminal is in front, and first-responder changes reach the controller,
/// so a click focuses a dock pane.
final class CanvasWindow: NSWindow {
    override func performClose(_ sender: Any?) {
        if sender is NSMenuItem, let controller = windowController as? CanvasWindowController,
           controller.closeDockContextInFront() { return }
        super.performClose(sender)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let made = super.makeFirstResponder(responder)
        if made { (windowController as? CanvasWindowController)?.firstResponderChanged(responder) }
        return made
    }
}
