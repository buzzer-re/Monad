//
//  TerminalWindowController.swift — a terminal window (or native tab): its
//  split panes of terminal contexts (TerminalPanes), each a session that
//  keeps running. Any window takes tabs on any VM (TabRouting); the "…"
//  opens tabs and VMs. The window holds the title, opacity, resize steps,
//  the titlebar's "…" and closing; the panes do the rest.
//

import AppKit

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    /// Open terminal windows (AppKit does not retain window controllers).
    private(set) static var all: [TerminalWindowController] = []

    /// The "…" menu in the titlebar; AppDelegate fills it when it opens.
    static let tabMenuID = NSUserInterfaceItemIdentifier("dev.monad.tab-menu")

    private let terminals: TerminalPanes
    /// The panes, and the titlebar a see-through theme gets (TerminalTitlebar).
    private let content: TerminalWindowContentView
    /// The "…" in the titlebar, for a window without a tab bar (each tab
    /// has its own "…" once the bar shows).
    private let titlebarMenu = NSTitlebarAccessoryViewController()
    private var inFullScreen = false

    init(target: SessionTarget) {
        terminals = TerminalPanes(target: target)
        content = TerminalWindowContentView(terminals: terminals.view)
        let window = TerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false)
        // Tabs join a window when asked (AppDelegate.open); new windows
        // follow the Mac's own "Prefer tabs" setting.
        window.tabbingMode = .automatic
        window.tabbingIdentifier = TabRouting.group
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 240, height: 120)
        super.init(window: window)
        window.delegate = self
        addTabMenu(to: window)
        terminals.onTitle = { [weak self] title, grid in
            guard let window = self?.window else { return }
            window.title = grid.map { "\(title) — \($0.cols)×\($0.rows)" } ?? title
            window.tab.title = title
        }
        terminals.onTransparency = { [weak self] theme in
            guard let self, let window = self.window else { return }
            window.isOpaque = theme == nil
            window.backgroundColor = theme == nil ? .windowBackgroundColor : .clear
            self.content.apply(TitlebarStyle.of(theme), to: window)
        }
        terminals.onLastClosed = { [weak self] in self?.window?.performClose(nil) }
        terminals.onLayoutChange = { [weak self] in self?.fontMetricsChanged() }
        window.contentView = content
        terminals.refresh()
        if let session = terminals.focusedSession {
            var size = session.terminalView.contentSize(cols: 100, rows: 30)
            // Under a painted titlebar the terminal starts below it.
            size.height += content.titlebarHeight
            window.setContentSize(size)
        }
        fontMetricsChanged()
        Self.all.append(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The session in front: the focused pane's visible context.
    var focusedSession: TerminalSessionViewController? { terminals.focusedSession }

    /// Every session of the window, pane by pane.
    var allSessions: [TerminalSessionViewController] { terminals.allSessions }

    /// This window for TabRouting: its session in front.
    var routingTab: TabRouting.Tab? {
        guard let s = focusedSession else { return nil }
        return TabRouting.Tab(target: s.target, vm: s.vm?.name)
    }

    /// Starts the sessions not started yet; the one in front gets the keys.
    func start() { terminals.start() }

    func closeAllSessions() { terminals.closeAllSessions() }

    func fontMetricsChanged() {
        // Steps of a cell only fit a window holding one terminal.
        window?.contentResizeIncrements = terminals.isSingleTerminal
            ? (focusedSession?.terminalView.cellSize ?? NSSize(width: 1, height: 1)) : NSSize(width: 1, height: 1)
    }

    // MARK: Panes

    /// ⇧⌘V: a pane beside the focused one, on its VM.
    @objc func splitSideBySide(_ sender: Any?) { terminals.split(.horizontal) }

    /// ⇧⌘H: a pane below the focused one, on its VM.
    @objc func splitStacked(_ sender: Any?) { terminals.split(.vertical) }

    /// A new context in the focused pane.
    func addContext(_ target: SessionTarget) { terminals.addContext(target) }

    @objc func selectPaneLeft(_ sender: Any?) { terminals.moveFocus(.left) }
    @objc func selectPaneRight(_ sender: Any?) { terminals.moveFocus(.right) }
    @objc func selectPaneAbove(_ sender: Any?) { terminals.moveFocus(.up) }
    @objc func selectPaneBelow(_ sender: Any?) { terminals.moveFocus(.down) }

    /// ⇧⌘→ and ⇧⌘←: the focused pane's next or previous context.
    @objc func showNextContext(_ sender: Any?) { terminals.cycleContext(by: 1) }
    @objc func showPreviousContext(_ sender: Any?) { terminals.cycleContext(by: -1) }

    /// ⌘W with more than one context: the one in front closes, and its pane
    /// when it was the last there. False when it is the window's only one.
    func closeContextInFront() -> Bool { terminals.closeContextInFront() }

    /// The window's first responder changed: a click in a pane's terminal
    /// focuses that pane.
    func firstResponderChanged(_ responder: NSResponder?) { terminals.firstResponderChanged(responder) }

    private func focusTerminal() { terminals.focusTerminal() }

    // MARK: Titlebar

    /// The tab bar's "+": another tab on the VM in front, as ⌘T.
    override func newWindowForTab(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.newTab(from: self)
    }

    /// The "…" pull-down (new tabs and VMs, its menu says which VM a new
    /// tab opens on): in each tab, and in the titlebar while the window
    /// shows no tab bar.
    private func addTabMenu(to window: NSWindow) {
        let inTitlebar = TabMenuButton(owner: self)
        inTitlebar.frame = NSRect(x: 0, y: 0, width: 34, height: 22)
        titlebarMenu.view = inTitlebar
        titlebarMenu.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(titlebarMenu)
        // A tab's accessory is sized by constraints.
        let inTab = TabMenuButton(owner: self)
        inTab.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inTab.widthAnchor.constraint(equalToConstant: 22),
            inTab.heightAnchor.constraint(equalToConstant: 16),
        ])
        window.tab.accessoryView = inTab
    }

    /// The titlebar "…" only while there is no tab bar to hold one, and not
    /// in full screen. Set only when it changes: in full screen any change
    /// to the titlebar brings it down until the mouse comes and goes.
    func refreshTabMenu() {
        let hidden = TabRouting.hidesTitlebarMenu(tabBarVisible: window?.tabGroup?.isTabBarVisible ?? false,
                                                  fullScreen: inFullScreen || window?.styleMask.contains(.fullScreen) == true)
        if titlebarMenu.isHidden != hidden { titlebarMenu.isHidden = hidden }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        closeAllSessions()
        Self.all.removeAll { $0 === self }
        // Its group may have lost its tab bar.
        DispatchQueue.main.async { Self.all.forEach { $0.refreshTabMenu() } }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshTabMenu()
        focusTerminal()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        inFullScreen = true
        refreshTabMenu()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        inFullScreen = false
        refreshTabMenu()
    }
}

/// A terminal window: Shell ▸ Close (⌘W) closes the context in front while
/// there are others, the close button the whole window; first-responder
/// changes reach the controller, so a click focuses its pane.
final class TerminalWindow: NSWindow {
    override func performClose(_ sender: Any?) {
        if sender is NSMenuItem, let controller = windowController as? TerminalWindowController,
           controller.closeContextInFront() { return }
        super.performClose(sender)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let made = super.makeFirstResponder(responder)
        if made { (windowController as? TerminalWindowController)?.firstResponderChanged(responder) }
        return made
    }
}

/// A "…" menu, knowing the window it belongs to (a tab's "…" may be
/// clicked while another tab is in front).
final class TerminalTabMenu: NSMenu {
    weak var owner: TerminalWindowController?
}

/// The "…": only its icon; a click opens its menu below it, filled by
/// AppDelegate as it opens. (A pull-down button drew its first item's
/// title beside the icon.)
final class TabMenuButton: NSButton {
    let tabMenu = TerminalTabMenu()

    init(owner: TerminalWindowController?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 16))
        image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "New tabs and VMs")
        title = ""
        imagePosition = .imageOnly // after the title, which resets it
        isBordered = false
        toolTip = "New tabs and VMs"
        tabMenu.owner = owner
        tabMenu.identifier = TerminalWindowController.tabMenuID
        tabMenu.delegate = NSApp.delegate as? NSMenuDelegate
        target = self
        action = #selector(open(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func open(_ sender: Any?) {
        tabMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 2 : bounds.minY - 2), in: self)
    }
}
