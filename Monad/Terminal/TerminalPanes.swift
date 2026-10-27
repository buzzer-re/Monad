//
//  TerminalPanes.swift — split panes of terminal contexts (Phase 11) in one
//  view: a terminal window's content (TerminalWindowController) or the
//  canvas's dock (CanvasWindowController). Each pane shows one of its
//  contexts, a terminal session that keeps running. Keystrokes and pastes
//  go to the focused pane's visible context only: it alone is the first
//  responder, and hidden contexts are out of the view hierarchy. What
//  belongs to the owner (a window's title, opacity and closing) it hears
//  through callbacks.
//

import AppKit

@MainActor
final class TerminalPanes: NSObject {
    private(set) var layout: PaneLayout
    private var sessions: [ContextID: TerminalSessionViewController] = [:]
    private var titles: [ContextID: String] = [:]
    private var grids: [ContextID: (cols: Int, rows: Int)] = [:]
    private var started: Set<ContextID> = []
    private let host: HostClient?
    /// The VMs that are on (PaneMenu.turnedOn): what the pane menu and
    /// ⇧⌘←/→ may switch to. Tests give their own.
    private let turnedOn: @MainActor () -> [String]
    /// Tells a drag of these panes from another set's.
    private let dragScope = UUID().uuidString

    let view = PaneContainerView()

    /// The context in front has a new title, or a new grid.
    var onTitle: ((_ title: String, _ grid: (cols: Int, rows: Int)?) -> Void)?
    /// Whether a shown context is translucent (a window lets the desktop through).
    /// The window must let the desktop show through: the theme to paint
    /// its titlebar with (the focused pane's when it is see-through), or
    /// nil for an opaque window.
    var onTransparency: ((Theme?) -> Void)?
    /// The last context went, or is to go: the owner closes (a window) or hides (the dock).
    var onLastClosed: (() -> Void)?
    /// The panes changed shape or the font changed (a window's resize steps).
    var onLayoutChange: (() -> Void)?

    init(target: SessionTarget, host: HostClient? = nil, turnedOn: (@MainActor () -> [String])? = nil) {
        self.host = host
        self.turnedOn = turnedOn ?? {
            PaneMenu.turnedOn((host ?? HostAgent.client).instances.map { ($0.name, $0.state) })
        }
        let context = ContextID.make()
        layout = PaneLayout(context: context, pane: .make())
        super.init()
        view.onNewPane = { [weak self] pane in self?.setUp(pane) }
        view.onFractions = { [weak self] fractions, path in self?.layout.setFractions(fractions, ofSplitAt: path) }
        _ = makeSession(target, context)
        rebuild()
    }

    /// The session in front: the focused pane's visible context.
    var focusedSession: TerminalSessionViewController? { layout.focusedContext.flatMap { sessions[$0] } }

    /// Every session, pane by pane.
    var allSessions: [TerminalSessionViewController] { layout.allContexts.compactMap { sessions[$0] } }

    var contextCount: Int { layout.allContexts.count }

    /// The VMs the contexts are on, pane by pane (once each).
    var vms: [String] {
        var seen: [String] = []
        for s in allSessions {
            guard let name = Self.vmName(s) else { continue }
            if !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    private static func vmName(_ s: TerminalSessionViewController) -> String? {
        if case .vm(let name) = s.target { return name }
        return s.vm?.name
    }

    /// One pane without a header: a window steps its size by the cell.
    var isSingleTerminal: Bool { layout.tree.panes.count == 1 && !layout.showsHeader(layout.tree.focused) }

    /// Starts the sessions not started yet; the one in front gets the keys.
    func start() {
        for (id, session) in sessions where !started.contains(id) {
            started.insert(id)
            session.start()
        }
        focusTerminal()
    }

    func closeAllSessions() {
        for session in sessions.values { session.close() }
    }

    /// Titles, opacity and shape told again (an owner that has just set
    /// its callbacks).
    func refresh() {
        refreshPanes()
        onLayoutChange?()
    }

    // MARK: Sessions

    private func makeSession(_ target: SessionTarget, _ id: ContextID, startIn directory: String? = nil) -> TerminalSessionViewController {
        let session = TerminalSessionViewController(target: target, cols: 100, rows: 30, host: host, startIn: directory)
        session.onTitleChange = { [weak self] title in
            self?.titles[id] = title
            self?.refreshTitles()
        }
        session.onGridChange = { [weak self] cols, rows in
            self?.grids[id] = (cols, rows)
            self?.refreshTitles()
        }
        session.onTransparencyChange = { [weak self] _ in self?.refreshOpacity() }
        session.onFinished = { [weak self] in self?.finished(id) }
        session.terminalView.extraMenuItems = { [weak self] in
            guard let self, let pane = self.layout.pane(of: id) else { return [] }
            return self.paneMenuItems(for: pane)
        }
        sessions[id] = session
        return session
    }

    /// A context's shell exited cleanly: it closes, and the owner hears
    /// when it was the last.
    private func finished(_ id: ContextID) {
        guard sessions[id] != nil else { return }
        if !close(id) { onLastClosed?() }
    }

    private func dispose(_ id: ContextID) {
        sessions[id]?.view.removeFromSuperview()
        sessions[id]?.close()
        sessions[id] = nil
        titles[id] = nil
        grids[id] = nil
        started.remove(id)
    }

    /// A new context's target: the VM of the one in front (an ephemeral VM
    /// by its name, once it has one).
    private var targetInFront: SessionTarget? {
        guard let s = focusedSession else { return nil }
        if s.target == .ephemeralVM { return s.vm.map { .vm($0.name) } }
        return s.target
    }

    // MARK: Panes

    /// A pane beside (horizontal) or below (vertical) the focused one, on its
    /// VM, in the directory its shell last reported.
    func split(_ axis: PaneTree.Axis) {
        guard let target = targetInFront else {
            NSSound.beep()
            return
        }
        let id = ContextID.make()
        _ = makeSession(target, id, startIn: target == .host ? nil : focusedSession?.directory)
        layout.split(axis, pane: .make(), context: id)
        rebuild()
        start()
    }

    /// A new context in the focused pane.
    func addContext(_ target: SessionTarget) {
        let id = ContextID.make()
        _ = makeSession(target, id)
        layout.addContext(id)
        refreshPanes()
        start()
    }

    /// The context on VM `name` brought to front, if there is one.
    @discardableResult
    func show(vm name: String) -> Bool {
        guard let id = layout.allContexts.first(where: { sessions[$0].flatMap(Self.vmName) == name }) else { return false }
        layout.show(id)
        refreshPanes()
        focusTerminal()
        return true
    }

    func moveFocus(_ direction: PaneTree.Direction) {
        layout.focus(direction)
        refreshPanes()
        focusTerminal()
    }

    /// ⇧⌘→ and ⇧⌘←: the next or previous entry of the focused pane's Switch
    /// Context list (PaneMenu.cycle): one of its contexts in front, or a new
    /// context on a running VM it has none on. A VM is never started, and
    /// the context left keeps its session, running. A beep when there is
    /// nothing else to go to.
    func cycleContext(by step: Int) {
        let pane = layout.tree.focused
        switch PaneMenu.cycle(pane, in: layout, vms: contextVMs, running: turnedOn(), by: step) {
        case .show(let id)?:
            layout.show(id)
            refreshPanes()
            focusTerminal()
        case .open(let target)?:
            addContext(target)
        default:
            NSSound.beep()
        }
    }

    /// The VM of each context, by what it was opened on (host shells have none).
    private var contextVMs: [ContextID: String] { sessions.compactMapValues(Self.vmName) }

    /// ⌘W with more than one context: the one in front closes, and its pane
    /// when it was the last there. False when it is the only one.
    func closeContextInFront() -> Bool {
        guard let id = layout.focusedContext else { return false }
        return close(id)
    }

    /// Closes a context, and its pane when it was the last there. False
    /// when it is the only one.
    @discardableResult
    private func close(_ id: ContextID) -> Bool {
        guard layout.allContexts.count > 1 else { return false }
        switch layout.closeContext(id) {
        case .context?:
            dispose(id)
            refreshPanes()
        case .pane?:
            dispose(id)
            rebuild()
        case .window?, nil:
            return false
        }
        focusTerminal()
        return true
    }

    func closePane(_ pane: PaneID) {
        guard let closed = layout.closePane(pane) else {
            onLastClosed?()
            return
        }
        closed.forEach(dispose)
        rebuild()
        focusTerminal()
    }

    /// The first responder changed: a click in a pane's terminal focuses
    /// that pane.
    func firstResponderChanged(_ responder: NSResponder?) {
        guard let terminal = responder as? MonadTerminalView,
              let id = sessions.first(where: { $0.value.terminalView === terminal })?.key,
              id != layout.focusedContext else { return }
        layout.show(id)
        refreshPanes()
    }

    // MARK: Views

    /// The panes again, from the tree; pane views and terminals are kept,
    /// so sessions go on as they were.
    private func rebuild() {
        view.show(layout.tree)
        refreshPanes()
        onLayoutChange?()
    }

    /// A new pane's view: its header focuses it, opens its menu and drags
    /// it; other panes drop on it.
    private func setUp(_ pane: PaneView) {
        let id = pane.id
        pane.header.onClick = { [weak self] in
            guard let self, let shown = self.layout.visible(in: id) else { return }
            self.layout.show(shown)
            self.refreshPanes()
            self.focusTerminal()
        }
        pane.header.menuItems = { [weak self] in self?.paneMenuItems(for: id) ?? [] }
        pane.header.dragPayload = { [weak self] in self?.dragPayload(for: id) }
        pane.accepts = { [weak self] payload in self?.draggedPane(payload).map { $0 != id } ?? false }
        pane.onDrop = { [weak self] payload, edge in
            guard let self, let dragged = self.draggedPane(payload), dragged != id else { return false }
            self.layout.drop(dragged, on: id, edge: edge)
            self.rebuild()
            self.focusTerminal()
            return true
        }
    }

    /// What a drag of `pane` carries.
    func dragPayload(for pane: PaneID) -> String { "\(dragScope) \(pane.value)" }

    /// The pane a drag carries, when it comes from these panes.
    func draggedPane(_ payload: String) -> PaneID? {
        let parts = payload.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == dragScope else { return nil }
        let pane = PaneID(parts[1])
        return layout.tree.contains(pane) ? pane : nil
    }

    // MARK: Pane menu

    /// The pane's menu (PaneMenu), for its header and its terminal.
    private func paneMenuItems(for pane: PaneID) -> [NSMenuItem] {
        let client = host ?? HostAgent.client
        var names: [ContextID: String] = [:]
        for (id, session) in sessions { names[id] = titles[id] ?? session.displayName }
        let items = PaneMenu.items(
            for: pane, in: layout, names: names, vms: contextVMs, running: turnedOn(),
            all: client.instances.filter { !$0.config.ephemeral }.map(\.name))
        return items.map { menuItem($0, pane: pane) }
    }

    private func menuItem(_ item: PaneMenu.Item, pane: PaneID) -> NSMenuItem {
        switch item {
        case .separator:
            return .separator()
        case .submenu(let title, let children):
            let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            children.forEach { submenu.addItem(self.menuItem($0, pane: pane)) }
            menuItem.submenu = submenu
            return menuItem
        case .action(let title, let action, let checked):
            let menuItem = NSMenuItem(title: title, action: #selector(choosePaneMenuItem(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.state = checked ? .on : .off
            menuItem.representedObject = PaneMenuChoice(pane: pane, action: action)
            return menuItem
        }
    }

    @objc private func choosePaneMenuItem(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? PaneMenuChoice, layout.tree.contains(choice.pane) else { return }
        switch choice.action {
        case .show(let id):
            layout.show(id)
            refreshPanes()
            focusTerminal()
        case .open(let target):
            layout.focus(choice.pane)
            addContext(target)
        case .closeContext(let id):
            if !close(id) { onLastClosed?() }
        case .split(let axis):
            layout.focus(choice.pane)
            split(axis)
        case .closePane:
            closePane(choice.pane)
        }
    }

    /// Each pane shows its visible context, its header when it has one and
    /// a ring when it is the focused one of several.
    private func refreshPanes() {
        let several = layout.tree.panes.count > 1
        for id in layout.tree.panes {
            guard let pane = view.paneView(id), let shown = layout.visible(in: id), let session = sessions[shown] else { continue }
            pane.show(session.view)
            pane.showsHeader = layout.showsHeader(id)
            pane.isFocused = several && id == layout.tree.focused
        }
        for (id, session) in sessions { session.isFocusedContext = id == layout.focusedContext }
        refreshTitles()
        refreshOpacity()
    }

    func focusTerminal() {
        guard let terminal = focusedSession?.terminalView, let window = terminal.window else { return }
        window.makeFirstResponder(terminal)
    }

    /// The title of the context in front, and each pane's header.
    private func refreshTitles() {
        for pane in layout.tree.panes {
            guard let shown = layout.visible(in: pane), let header = view.paneView(pane)?.header else { continue }
            let count = layout.contexts(in: pane).count
            header.title = (titles[shown] ?? sessions[shown]?.displayName ?? "") + (count > 1 ? "  (\(count))" : "")
        }
        guard let id = layout.focusedContext else { return }
        onTitle?(titles[id] ?? sessions[id]?.displayName ?? "Monad", grids[id])
    }

    private func refreshOpacity() {
        let shown = layout.tree.panes.compactMap { layout.visible(in: $0) }.compactMap { sessions[$0] }
        let seeThrough = shown.map(\.backdrop).filter(\.needsTransparentWindow)
        let focused = focusedSession?.backdrop
        onTransparency?((seeThrough.first { $0 === focused } ?? seeThrough.first)?.theme)
    }
}

/// A pane menu choice, carried by its NSMenuItem.
private final class PaneMenuChoice: NSObject {
    let pane: PaneID
    let action: PaneMenu.Action

    init(pane: PaneID, action: PaneMenu.Action) {
        self.pane = pane
        self.action = action
    }
}
