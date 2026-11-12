//
//  TerminalWindowController.swift — a terminal window: its tabs
//  (TerminalTab, each the split panes of terminal contexts, TerminalPanes)
//  and their groups (TabStrip), drawn in Monad's own tab strip
//  (TabStripView) once there are two tabs or a group. The tab in front is
//  the only one in the window; the others' sessions go on out of sight.
//  Any window takes tabs on any VM (TabRouting); the "…" opens tabs and
//  VMs. The window holds the title, opacity, resize steps and closing; a
//  tab moves to another window with its sessions. What it would take to
//  open the window again is its `saved` (SavedSession).
//

import AppKit

/// One tab: its panes, and what the window shows of them.
@MainActor
final class TerminalTab {
    let id: TabID
    let panes: TerminalPanes
    private(set) var title = "Monad"
    private(set) var grid: (cols: Int, rows: Int)?
    /// The theme to paint the titlebar with while a pane is see-through.
    private(set) var seeThrough: Theme?
    /// Its title, grid or opacity changed.
    var onChange: (() -> Void)?

    init(id: TabID = .make(), panes: TerminalPanes) {
        self.id = id
        self.panes = panes
        panes.onTitle = { [weak self] title, grid in
            self?.title = title
            self?.grid = grid
            self?.onChange?()
        }
        panes.onTransparency = { [weak self] theme in
            self?.seeThrough = theme
            self?.onChange?()
        }
        panes.refresh()
    }
}

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    /// Open terminal windows (AppKit does not retain window controllers).
    private(set) static var all: [TerminalWindowController] = []

    /// The "…" menu in the titlebar and the tab strip; AppDelegate fills it when it opens.
    static let tabMenuID = NSUserInterfaceItemIdentifier("dev.monad.tab-menu")

    /// Something a saved session keeps changed, in any window.
    static var onSavedStateChange: (() -> Void)?
    /// A window is about to close, still among `all`.
    static var onWillClose: ((TerminalWindowController) -> Void)?

    private(set) var strip: TabStrip
    private var tabs: [TabID: TerminalTab] = [:]
    private let host: HostClient?
    /// The tab strip and the panes, and the titlebar a see-through theme gets (TerminalTitlebar).
    private let content: TerminalWindowContentView
    let stripView: TabStripView
    /// The "…" in the titlebar, for a window without a tab strip (the
    /// strip has its own).
    private let titlebarMenu = NSTitlebarAccessoryViewController()
    private var inFullScreen = false
    /// Sessions start once the window is shown (`start`), each tab's when
    /// it first comes to front.
    private var running = false
    private var groupPopover: NSPopover?
    /// The editor of the group being named, while its popover is open.
    var groupEditor: TabGroupEditor? { groupPopover?.contentViewController as? TabGroupEditor }

    convenience init(target: SessionTarget, host: HostClient? = nil) {
        let tab = TerminalTab(panes: TerminalPanes(target: target, host: host))
        self.init(tabs: [tab], strip: TabStrip(tab: tab.id), host: host)
        sizeToTerminal()
    }

    /// A window of tabs taken from other windows, their sessions as they are.
    convenience init(adopting tabs: [TerminalTab], host: HostClient? = nil) {
        precondition(!tabs.isEmpty)
        var strip = TabStrip(tab: tabs[0].id)
        for tab in tabs.dropFirst() { strip.add(tab.id) }
        strip.select(tabs[0].id)
        self.init(tabs: tabs, strip: strip, host: host)
    }

    /// A window of a saved session: its tabs and groups, where it was on
    /// the screen. nil when none of its tabs can be opened.
    convenience init?(restoring saved: SavedSession.Window, host: HostClient? = nil) {
        var made: [TerminalTab] = []
        var entries: [TabStrip.Tab] = []
        var front: TabID?
        for (i, tab) in saved.tabs.enumerated() {
            guard let panes = TerminalPanes(restoring: tab.panes, host: host) else { continue }
            let t = TerminalTab(panes: panes)
            made.append(t)
            entries.append(TabStrip.Tab(id: t.id, group: tab.group.map(TabGroupID.init)))
            if i <= saved.selected { front = t.id }
        }
        guard let strip = TabStrip(tabs: entries, groups: saved.groups, selected: front) else { return nil }
        self.init(tabs: made, strip: strip, host: host)
        if let f = saved.frame, f.count == 4 {
            let frame = NSRect(x: f[0], y: f[1], width: f[2], height: f[3])
            if Self.isOnScreen(frame, screens: NSScreen.screens.map(\.visibleFrame)) {
                window?.setFrame(frame, display: false)
                return
            }
        }
        sizeToTerminal()
        window?.center()
    }

    private init(tabs list: [TerminalTab], strip: TabStrip, host: HostClient?) {
        self.strip = strip
        self.host = host
        let rect = NSRect(x: 0, y: 0, width: 800, height: 500)
        let window = TerminalWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false)
        // Monad's own tabs: the system's tab bar has no place for groups.
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 240, height: 120)
        stripView = TabStripView(owner: nil)
        content = TerminalWindowContentView(tabStrip: stripView, frame: rect)
        super.init(window: window)
        window.delegate = self
        stripView.menuButton.tabMenu.owner = self
        addTitlebarMenu(to: window)
        wireStrip()
        window.contentView = content
        list.forEach(adopt)
        refresh()
        Self.all.append(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whether enough of a saved frame is on a screen to reach the window.
    nonisolated static func isOnScreen(_ frame: NSRect, screens: [NSRect]) -> Bool {
        screens.contains {
            let shared = $0.intersection(frame)
            return !shared.isNull && shared.width >= 120 && shared.height >= 60
        }
    }

    /// A new window: 100 by 30 cells of its first terminal.
    private func sizeToTerminal() {
        guard let window, let session = focusedSession else { return }
        var size = session.terminalView.contentSize(cols: 100, rows: 30)
        // Under a painted titlebar the terminal starts below it.
        size.height += content.titlebarHeight
        window.setContentSize(size)
        fontMetricsChanged()
    }

    // MARK: Tabs

    var tabCount: Int { strip.tabs.count }

    func tab(_ id: TabID) -> TerminalTab? { tabs[id] }

    /// The tab in front.
    var selectedTab: TerminalTab? { tabs[strip.selected] }

    /// The tabs, in the strip's order.
    var orderedTabs: [TerminalTab] { strip.tabs.compactMap { tabs[$0.id] } }

    /// Whether the titlebar's own "…" shows (the strip has one once it shows).
    var showsTitlebarMenu: Bool { !titlebarMenu.isHidden && !titlebarMenu.view.isHidden }

    /// Whether the tab strip shows: two tabs or more, or a group.
    var showsTabStrip: Bool { strip.tabs.count > 1 || !strip.groups.isEmpty }

    /// The session in front: the tab in front's focused pane, its visible context.
    var focusedSession: TerminalSessionViewController? { selectedTab?.panes.focusedSession }

    /// Every session of the window, tab by tab and pane by pane.
    var allSessions: [TerminalSessionViewController] { orderedTabs.flatMap(\.panes.allSessions) }

    /// This window for TabRouting: its session in front.
    var routingTab: TabRouting.Tab? {
        guard let s = focusedSession else { return nil }
        return TabRouting.Tab(target: s.target, vm: s.vm?.name)
    }

    /// Starts the sessions of the tab in front, and from now on each
    /// tab's when it comes to front: a window opened again with many tabs
    /// does not start every VM they are on at once.
    func start() {
        running = true
        selectedTab?.panes.start()
    }

    func closeAllSessions() {
        for tab in tabs.values { tab.panes.closeAllSessions() }
    }

    /// A new tab on `target`, in front: last, or at the end of `group`.
    @discardableResult
    func addTab(_ target: SessionTarget, in group: TabGroupID? = nil) -> TerminalTab {
        let tab = TerminalTab(panes: TerminalPanes(target: target, host: host))
        take(tab, in: group)
        return tab
    }

    /// A tab from another window joins this one, in front.
    func take(_ tab: TerminalTab, in group: TabGroupID? = nil) {
        adopt(tab)
        strip.add(tab.id, to: group)
        refresh()
    }

    private func adopt(_ tab: TerminalTab) {
        tabs[tab.id] = tab
        let id = tab.id
        tab.onChange = { [weak self] in self?.tabChanged(id) }
        tab.panes.onLastClosed = { [weak self] in self?.closeTab(id) }
        tab.panes.onLayoutChange = { [weak self] in self?.fontMetricsChanged() }
        tab.panes.onSavedStateChange = { Self.onSavedStateChange?() }
    }

    /// Takes a tab out with its sessions running, for another window; the
    /// window closes when it was its last.
    func release(_ id: TabID) -> TerminalTab? {
        guard let tab = tabs[id] else { return nil }
        tabs[id] = nil
        tab.onChange = nil
        tab.panes.onLastClosed = nil
        tab.panes.onLayoutChange = nil
        tab.panes.onSavedStateChange = nil
        tab.panes.view.removeFromSuperview()
        if strip.close(id) { refresh() } else { window?.close() }
        return tab
    }

    func select(_ id: TabID) {
        strip.select(id)
        refresh()
    }

    /// Closes a tab and its sessions; the window with its last one.
    func closeTab(_ id: TabID) {
        guard let tab = tabs[id] else { return }
        guard strip.close(id) else {
            window?.performClose(nil)
            return
        }
        tabs[id] = nil
        tab.panes.view.removeFromSuperview()
        tab.panes.closeAllSessions()
        refresh()
    }

    /// ⌘1 … ⌘9, over the tabs in sight. False when there is no such tab.
    @discardableResult
    func selectTab(number: Int) -> Bool {
        let visible = strip.visibleTabs
        guard let index = AppDelegate.tabIndex(forShortcut: number, tabCount: visible.count) else { return false }
        select(visible[index])
        return true
    }

    @objc func showNextTab(_ sender: Any?) {
        strip.selectVisible(by: 1)
        refresh()
    }

    @objc func showPreviousTab(_ sender: Any?) {
        strip.selectVisible(by: -1)
        refresh()
    }

    /// The tab in front in a window of its own.
    @objc func moveTabToNewWindow(_ sender: Any?) { moveToNewWindow(strip.selected) }

    func moveToNewWindow(_ id: TabID) {
        guard tabCount > 1, let tab = release(id) else { return }
        present(TerminalWindowController(adopting: [tab], host: host))
    }

    /// A group in a window of its own, still a group.
    func moveToNewWindow(_ group: TabGroupID) {
        let ids = strip.tabs(in: group)
        guard let g = strip.group(group), !ids.isEmpty, ids.count < tabCount else { return }
        let moved = ids.compactMap(release)
        guard !moved.isEmpty else { return }
        let other = TerminalWindowController(adopting: moved, host: host)
        other.strip.newGroup(g.id, name: g.name, color: g.color, tabs: moved.map(\.id))
        if g.collapsed { other.strip.toggleCollapsed(g.id) }
        other.refresh()
        present(other)
    }

    /// Every tab of `other` comes here, its groups with it; `other` closes.
    func absorb(_ other: TerminalWindowController) {
        guard other !== self else { return }
        let front = strip.selected
        var mapped: [TabGroupID: TabGroupID] = [:]
        for entry in other.strip.tabs {
            let from = entry.group.flatMap(other.strip.group)
            guard let tab = other.release(entry.id) else { continue }
            adopt(tab)
            if let from {
                if let here = mapped[from.id] {
                    strip.add(tab.id, to: here)
                } else {
                    // An id of its own: this window may hold the group it was moved out of.
                    let id = TabGroupID.make()
                    mapped[from.id] = id
                    strip.add(tab.id)
                    strip.newGroup(id, name: from.name, color: from.color, tabs: [tab.id])
                    if from.collapsed { strip.toggleCollapsed(id) }
                }
            } else {
                strip.add(tab.id)
            }
        }
        strip.select(front)
        refresh()
    }

    /// Shows a window made of this one's tabs, a step down and right of it.
    private func present(_ other: TerminalWindowController) {
        if let window, let w = other.window {
            w.setFrame(window.frame.offsetBy(dx: 28, dy: -28), display: false)
            w.makeKeyAndOrderFront(nil)
        }
        other.start()
    }

    // MARK: Groups

    /// The tab in front in a new group (Window ▸ Add Tab to New Group).
    @objc func addTabToNewGroup(_ sender: Any?) { group(strip.selected) }

    /// A new group of one tab, its name asked under its label.
    func group(_ tab: TabID) {
        let id = TabGroupID.make()
        strip.newGroup(id, name: "", tabs: [tab])
        refresh()
        editGroup(id)
    }

    /// A group of `members` with its name and colour given.
    func newGroup(_ id: TabGroupID = .make(), name: String, color: TabGroupColor? = nil, tabs members: [TabID]) {
        strip.newGroup(id, name: name, color: color, tabs: members)
        refresh()
    }

    /// A click on a group's label: it collapses, or opens again.
    func toggleCollapsed(_ id: TabGroupID) {
        strip.toggleCollapsed(id)
        refresh()
    }

    /// The group's name and colour, in a popover under its label.
    func editGroup(_ id: TabGroupID) {
        guard let group = strip.group(id) else { return }
        groupPopover?.close()
        // Only the strip is drawn again: the name field keeps the keys.
        let editor = TabGroupEditor(group: group, onName: { [weak self] name in
            self?.strip.rename(id, to: name)
            self?.refreshStrip()
        }, onColor: { [weak self] color in
            self?.strip.setColor(color, of: id)
            self?.refreshStrip()
        })
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = editor
        editor.onDone = { [weak popover] in popover?.close() }
        groupPopover = popover
        content.layoutSubtreeIfNeeded()
        guard stripView.window != nil, let frame = stripView.frame(of: id) else { return }
        popover.show(relativeTo: frame, of: stripView, preferredEdge: .maxY)
    }

    func closeGroup(_ id: TabGroupID) {
        strip.tabs(in: id).forEach(closeTab)
    }

    private func wireStrip() {
        stripView.onSelect = { [weak self] id in self?.select(id) }
        stripView.onClose = { [weak self] id in self?.closeTab(id) }
        stripView.onToggleGroup = { [weak self] id in self?.toggleCollapsed(id) }
        stripView.onDrop = { [weak self] item, target in
            self?.strip.drop(item, target)
            self?.refresh()
        }
        stripView.onNewTab = { [weak self] in (NSApp.delegate as? AppDelegate)?.newTab(from: self) }
        stripView.tabMenu = { [weak self] id in self?.menu(forTab: id) }
        stripView.groupMenu = { [weak self] id in self?.menu(forGroup: id) }
    }

    /// A tab's menu: its group, its window, closing.
    func menu(forTab id: TabID) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let app = NSApp.delegate as? AppDelegate
        menu.addItem(ClosureMenuItem("New Tab") { [weak self] in app?.newTab(from: self) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Add Tab to New Group") { [weak self] in self?.group(id) })
        let own = strip.group(of: id)
        let others = strip.groups.filter { $0.id != own?.id }
        if !others.isEmpty {
            let sub = NSMenu()
            for g in others {
                sub.addItem(ClosureMenuItem(g.name.isEmpty ? "Unnamed (\(g.color.title))" : g.name) { [weak self] in
                    self?.strip.move(id, to: g.id)
                    self?.refresh()
                })
            }
            let item = NSMenuItem(title: "Add Tab to Group", action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }
        if own != nil {
            menu.addItem(ClosureMenuItem("Remove from Group") { [weak self] in
                self?.strip.move(id, to: nil)
                self?.refresh()
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Move Tab to New Window", enabled: tabCount > 1) { [weak self] in self?.moveToNewWindow(id) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Close Tab") { [weak self] in self?.closeTab(id) })
        menu.addItem(ClosureMenuItem("Close Other Tabs", enabled: tabCount > 1) { [weak self] in
            guard let self else { return }
            self.select(id)
            self.strip.tabs.map(\.id).filter { $0 != id }.forEach(self.closeTab)
        })
        return menu
    }

    /// A group's menu: its name and colour, a tab in it, the whole of it.
    func menu(forGroup id: TabGroupID) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let group = strip.group(id) else { return menu }
        menu.addItem(ClosureMenuItem("Name and Color…") { [weak self] in self?.editGroup(id) })
        let colors = NSMenu()
        for c in TabGroupColor.allCases {
            colors.addItem(ClosureMenuItem(c.title, checked: c == group.color) { [weak self] in
                self?.strip.setColor(c, of: id)
                self?.refresh()
            })
        }
        let color = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        color.submenu = colors
        menu.addItem(color)
        menu.addItem(ClosureMenuItem(group.collapsed ? "Expand Group" : "Collapse Group") { [weak self] in self?.toggleCollapsed(id) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("New Tab in Group") { [weak self] in
            (NSApp.delegate as? AppDelegate)?.newTab(from: self, in: id)
        })
        menu.addItem(ClosureMenuItem("Move Group to New Window", enabled: strip.tabs(in: id).count < tabCount) { [weak self] in
            self?.moveToNewWindow(id)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Ungroup Tabs") { [weak self] in
            self?.strip.ungroup(id)
            self?.refresh()
        })
        menu.addItem(ClosureMenuItem("Close Group") { [weak self] in self?.closeGroup(id) })
        return menu
    }

    // MARK: What shows

    /// The window after its tabs or groups changed: the tab in front's
    /// panes, the strip, the title and opacity, and a session to save.
    private func refresh() {
        guard let window, let tab = selectedTab else { return }
        content.showsTabStrip = showsTabStrip
        content.show(tab.panes.view)
        showStrip()
        show(tab, in: window)
        refreshTabMenu()
        fontMetricsChanged()
        if running { tab.panes.start() }
        tab.panes.focusTerminal()
        Self.onSavedStateChange?()
    }

    /// A tab's title, grid or opacity changed.
    private func tabChanged(_ id: TabID) {
        guard let window, let tab = tabs[id] else { return }
        showStrip()
        if id == strip.selected { show(tab, in: window) }
    }

    private func showStrip() {
        var titles: [TabID: String] = [:]
        for (id, t) in tabs { titles[id] = t.title }
        stripView.show(strip, titles: titles)
    }

    /// A group's name or colour changed: the strip again, and a session to
    /// save. The tab in front and the first responder stay as they are.
    private func refreshStrip() {
        showStrip()
        Self.onSavedStateChange?()
    }

    /// The title and opacity of the tab in front are the window's.
    private func show(_ tab: TerminalTab, in window: NSWindow) {
        let title = tab.grid.map { "\(tab.title) — \($0.cols)×\($0.rows)" } ?? tab.title
        if window.title != title { window.title = title }
        let theme = tab.seeThrough
        window.isOpaque = theme == nil
        window.backgroundColor = theme == nil ? .windowBackgroundColor : .clear
        let style = TitlebarStyle.of(theme)
        if content.strip.style != style || content.painted != (style != nil) { content.apply(style, to: window) }
        stripView.paintsBackground = style == nil
    }

    func fontMetricsChanged() {
        // Steps of a cell only fit a window holding one terminal and no
        // tab strip (its height is not a number of cells).
        let single = selectedTab?.panes.isSingleTerminal == true && !showsTabStrip
        window?.contentResizeIncrements = single
            ? (focusedSession?.terminalView.cellSize ?? NSSize(width: 1, height: 1)) : NSSize(width: 1, height: 1)
    }

    // MARK: A saved session

    /// The window as a saved session keeps it; nil when none of its tabs
    /// can be opened again (ephemeral VMs only).
    var saved: SavedSession.Window? {
        var kept: [SavedSession.Tab] = []
        var front = 0
        var seenFront = false
        for entry in strip.tabs {
            if entry.id == strip.selected { seenFront = true }
            guard let panes = tabs[entry.id]?.panes.saved else { continue }
            if !seenFront || entry.id == strip.selected { front = kept.count }
            kept.append(SavedSession.Tab(group: entry.group?.value, panes: panes))
        }
        guard !kept.isEmpty else { return nil }
        let used = Set(kept.compactMap(\.group))
        let frame = window.map { [Double($0.frame.minX), Double($0.frame.minY), Double($0.frame.width), Double($0.frame.height)] }
        return SavedSession.Window(frame: frame, tabs: kept, groups: strip.groups.filter { used.contains($0.id.value) }, selected: front)
    }

    // MARK: Panes

    /// ⇧⌘V: a pane beside the focused one, on its VM.
    @objc func splitSideBySide(_ sender: Any?) { selectedTab?.panes.split(.horizontal) }

    /// ⇧⌘H: a pane below the focused one, on its VM.
    @objc func splitStacked(_ sender: Any?) { selectedTab?.panes.split(.vertical) }

    /// A new context in the focused pane.
    func addContext(_ target: SessionTarget) { selectedTab?.panes.addContext(target) }

    @objc func selectPaneLeft(_ sender: Any?) { selectedTab?.panes.moveFocus(.left) }
    @objc func selectPaneRight(_ sender: Any?) { selectedTab?.panes.moveFocus(.right) }
    @objc func selectPaneAbove(_ sender: Any?) { selectedTab?.panes.moveFocus(.up) }
    @objc func selectPaneBelow(_ sender: Any?) { selectedTab?.panes.moveFocus(.down) }

    /// ⇧⌘→ and ⇧⌘←: the focused pane's next or previous context.
    @objc func showNextContext(_ sender: Any?) { selectedTab?.panes.cycleContext(by: 1) }
    @objc func showPreviousContext(_ sender: Any?) { selectedTab?.panes.cycleContext(by: -1) }

    /// ⌘W: the context in front closes while its tab has others (its pane
    /// when it was the last there), else its tab while the window has
    /// others. False when it is the window's only one.
    func closeInFront() -> Bool {
        if selectedTab?.panes.closeContextInFront() == true { return true }
        guard tabCount > 1 else { return false }
        closeTab(strip.selected)
        return true
    }

    /// The window's first responder changed: a click in a pane's terminal
    /// focuses that pane.
    func firstResponderChanged(_ responder: NSResponder?) { selectedTab?.panes.firstResponderChanged(responder) }

    // MARK: Titlebar

    /// The "…" pull-down (new tabs and VMs, its menu says which VM a new
    /// tab opens on) in the titlebar, while the window shows no tab strip.
    private func addTitlebarMenu(to window: NSWindow) {
        let inTitlebar = TabMenuButton(owner: self)
        inTitlebar.frame = NSRect(x: 0, y: 0, width: 34, height: 22)
        titlebarMenu.view = inTitlebar
        titlebarMenu.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(titlebarMenu)
    }

    /// The titlebar "…" only while there is no tab strip to hold one, and not
    /// in full screen. Set only when it changes: in full screen any change
    /// to the titlebar brings it down until the mouse comes and goes.
    func refreshTabMenu() {
        let hidden = TabRouting.hidesTitlebarMenu(tabBarVisible: showsTabStrip,
                                                  fullScreen: inFullScreen || window?.styleMask.contains(.fullScreen) == true)
        if titlebarMenu.isHidden != hidden { titlebarMenu.isHidden = hidden }
        // The button itself too: a hidden accessory was still drawn (seen
        // on macOS 27, beside the strip's own "…").
        if titlebarMenu.view.isHidden != hidden { titlebarMenu.view.isHidden = hidden }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        Self.onWillClose?(self)
        groupPopover?.close()
        closeAllSessions()
        Self.all.removeAll { $0 === self }
        Self.onSavedStateChange?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshTabMenu()
        selectedTab?.panes.focusTerminal()
    }

    func windowDidMove(_ notification: Notification) { Self.onSavedStateChange?() }
    func windowDidEndLiveResize(_ notification: Notification) { Self.onSavedStateChange?() }

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
/// there are others, then the tab in front while there are others; the
/// close button the whole window with all its tabs; first-responder
/// changes reach the controller, so a click focuses its pane.
final class TerminalWindow: NSWindow {
    override func performClose(_ sender: Any?) {
        if sender is NSMenuItem, let controller = windowController as? TerminalWindowController,
           controller.closeInFront() { return }
        super.performClose(sender)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let made = super.makeFirstResponder(responder)
        if made { (windowController as? TerminalWindowController)?.firstResponderChanged(responder) }
        return made
    }
}

/// A "…" menu, knowing the window it belongs to.
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
