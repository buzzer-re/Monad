//
//  TerminalWindowTests.swift — terminal windows and their tabs: Monad's
//  own tab strip with groups, as Firefox has them. A new tab (⌘T) joins
//  the window in front without changing its size (seen with the system's
//  tabs: each ⌘T changed the window "a tiny bit", 2026-11-02); only the
//  tab in front is in the window; tabs and groups move to other windows
//  with their sessions; a window is saved and comes back as it was.
//  Sessions are never started here (no host).
//

import XCTest
@testable import Monad

@MainActor
final class TerminalWindowTests: XCTestCase {
    private let host = HostClient(connect: { throw MonadError("no host here") })
    private var before: [TerminalWindowController] = []

    override func setUp() {
        super.setUp()
        before = TerminalWindowController.all
    }

    override func tearDown() {
        for c in TerminalWindowController.all where !before.contains(where: { $0 === c }) { c.window?.close() }
        super.tearDown()
    }

    /// A window as AppDelegate.open makes one, not started (no shell).
    private func controller(_ target: SessionTarget = .host) -> TerminalWindowController {
        TerminalWindowController(target: target, host: host)
    }

    private func isShown(_ tab: TerminalTab, in c: TerminalWindowController) -> Bool {
        guard let content = c.window?.contentView else { return false }
        return tab.panes.view.isDescendant(of: content)
    }

    func testANewTabKeepsTheWindowsSize() throws {
        let c = controller()
        let window = try XCTUnwrap(c.window)
        window.makeKeyAndOrderFront(nil)
        XCTAssertFalse(c.showsTabStrip, "one tab: no strip")
        XCTAssertTrue(c.stripView.isHidden)
        // Where the user left it: not the size a new window starts at.
        window.setFrame(NSRect(x: 100, y: 100, width: 913, height: 577), display: true)
        let frame = window.frame
        for n in 2...4 {
            c.addTab(.host)
            XCTAssertEqual(window.frame, frame, "tab \(n): the window stays as it is")
            XCTAssertEqual(c.tabCount, n)
        }
        XCTAssertTrue(c.showsTabStrip)
        XCTAssertFalse(c.stripView.isHidden)
        XCTAssertEqual(c.stripView.frame.height, TabStripLayout.height)
        XCTAssertEqual(window.contentResizeIncrements, NSSize(width: 1, height: 1), "no cell steps under a tab strip")
        XCTAssertEqual(c.stripView.layout.slots.count, 4)
        XCTAssertNil(window.tabbedWindows, "not the system's tabs")
    }

    func testOnlyTheTabInFrontIsInTheWindow() throws {
        let c = controller(.vm("web"))
        let first = try XCTUnwrap(c.selectedTab)
        let second = c.addTab(.vm("db"))
        XCTAssertTrue(isShown(second, in: c))
        XCTAssertFalse(isShown(first, in: c))
        XCTAssertEqual(c.focusedSession?.target, .vm("db"))
        XCTAssertEqual(c.routingTab?.target, .vm("db"))
        c.select(first.id)
        XCTAssertTrue(isShown(first, in: c))
        XCTAssertFalse(isShown(second, in: c))
        XCTAssertEqual(c.window?.title.hasPrefix("web"), true, c.window?.title ?? "")
        XCTAssertEqual(c.allSessions.map(\.target), [.vm("web"), .vm("db")], "every tab's sessions are the window's")
        c.showNextTab(nil)
        XCTAssertEqual(c.strip.selected, second.id)
        c.showNextTab(nil)
        XCTAssertEqual(c.strip.selected, first.id)
    }

    func testClosingATabShowsAnotherAndTheLastClosesTheWindow() throws {
        let c = controller(.vm("web"))
        let first = try XCTUnwrap(c.selectedTab)
        let second = c.addTab(.vm("db"))
        XCTAssertTrue(c.closeInFront(), "⌘W closes the tab in front while there are others")
        XCTAssertEqual(c.tabCount, 1)
        XCTAssertNil(c.tab(second.id))
        XCTAssertTrue(isShown(first, in: c))
        XCTAssertFalse(c.showsTabStrip)
        XCTAssertFalse(c.closeInFront(), "the last one is the window's to close")
        c.selectedTab?.panes.addContext(.vm("db"))
        XCTAssertTrue(c.closeInFront(), "a context first")
        XCTAssertEqual(c.tabCount, 1)
        c.closeTab(first.id)
        XCTAssertFalse(TerminalWindowController.all.contains { $0 === c })
    }

    func testAGroupShowsTheStripAndCollapses() throws {
        let c = controller(.vm("web"))
        let first = try XCTUnwrap(c.selectedTab)
        let work = TabGroupID("work")
        c.newGroup(work, name: "work", tabs: [first.id])
        XCTAssertTrue(c.showsTabStrip, "a group shows the strip, also with one tab")
        let other = c.addTab(.vm("db"))
        let inGroup = c.addTab(.vm("web"), in: work)
        XCTAssertEqual(c.strip.tabs.map(\.id), [first.id, inGroup.id, other.id])
        c.select(other.id)
        c.stripView.onToggleGroup?(work)
        XCTAssertEqual(c.stripView.layout.slots.map(\.item), [.group(work), .tab(other.id)])
        XCTAssertNotNil(c.stripView.frame(of: work))
        XCTAssertTrue(c.selectTab(number: 1))
        XCTAssertEqual(c.strip.selected, other.id, "⌘1 is the first tab in sight")
        // Its menus hold what the strip can do.
        XCTAssertTrue(c.menu(forTab: other.id).items.map(\.title).contains("Add Tab to Group"))
        XCTAssertTrue(c.menu(forTab: first.id).items.map(\.title).contains("Remove from Group"))
        XCTAssertTrue(c.menu(forGroup: work).items.map(\.title).contains("Expand Group"))
        c.closeGroup(work)
        XCTAssertEqual(c.strip.tabs.map(\.id), [other.id])
        XCTAssertTrue(c.strip.groups.isEmpty)
    }

    // MARK: The strip under the mouse

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in c: TerminalWindowController, button: Int = 0) throws -> NSEvent {
        let window = try XCTUnwrap(c.window)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: c.stripView.convert(point, to: nil), modifierFlags: [],
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func frame(_ item: TabStrip.Item, in c: TerminalWindowController) throws -> NSRect {
        c.window?.contentView?.layoutSubtreeIfNeeded()
        return try XCTUnwrap(c.stripView.layout.slots.first { $0.item == item }?.frame, "\(item) is not in the strip")
    }

    private func click(_ point: NSPoint, in c: TerminalWindowController) throws {
        c.stripView.mouseDown(with: try mouse(.leftMouseDown, at: point, in: c))
        c.stripView.mouseUp(with: try mouse(.leftMouseUp, at: point, in: c))
    }

    private func drag(from: NSPoint, to: NSPoint, in c: TerminalWindowController) throws {
        c.stripView.mouseDown(with: try mouse(.leftMouseDown, at: from, in: c))
        let mid = NSPoint(x: (from.x + to.x) / 2, y: from.y)
        c.stripView.mouseDragged(with: try mouse(.leftMouseDragged, at: mid, in: c))
        c.stripView.mouseDragged(with: try mouse(.leftMouseDragged, at: to, in: c))
        c.stripView.mouseUp(with: try mouse(.leftMouseUp, at: to, in: c))
    }

    /// The strip as the user works it: clicks on tabs, their ×, the "+"
    /// (asked of the app, not opened here) and a group's label.
    func testClicksInTheStrip() throws {
        let c = controller(.vm("web"))
        c.window?.setFrame(NSRect(x: 60, y: 60, width: 1000, height: 400), display: false)
        let first = try XCTUnwrap(c.selectedTab)
        let second = c.addTab(.vm("db")), third = c.addTab(.vm("api"))
        try click(NSPoint(x: try frame(.tab(first.id), in: c).midX, y: 16), in: c)
        XCTAssertEqual(c.strip.selected, first.id)
        XCTAssertTrue(isShown(first, in: c))

        let work = TabGroupID.make()
        c.newGroup(work, name: "work", tabs: [second.id, third.id])
        let label = try frame(.group(work), in: c)
        try click(NSPoint(x: label.midX, y: label.midY), in: c)
        XCTAssertEqual(c.strip.group(work)?.collapsed, true, "a click on the label collapses its group")
        XCTAssertEqual(c.stripView.layout.slots.map(\.item), [.tab(first.id), .group(work)])
        try click(NSPoint(x: try frame(.group(work), in: c).midX, y: label.midY), in: c)
        XCTAssertEqual(c.strip.group(work)?.collapsed, false)

        // The × of the tab in front.
        try click(NSPoint(x: try frame(.tab(second.id), in: c).midX, y: 16), in: c)
        let box = TabStripLayout.closeBox(in: try frame(.tab(second.id), in: c))
        try click(NSPoint(x: box.midX, y: box.midY), in: c)
        XCTAssertNil(c.tab(second.id))
        XCTAssertEqual(c.tabCount, 2)

        // A middle click closes too.
        let at = try frame(.tab(third.id), in: c)
        XCTAssertTrue(c.stripView.middleClick(at: NSPoint(x: at.midX, y: at.midY)))
        XCTAssertFalse(c.stripView.middleClick(at: NSPoint(x: c.stripView.layout.plus.midX, y: at.midY)))
        XCTAssertNil(c.tab(third.id))
        XCTAssertTrue(c.strip.groups.isEmpty, "its group went with its last tab")

        var asked = 0
        c.stripView.onNewTab = { asked += 1 }
        c.addTab(.vm("db"))
        try click(NSPoint(x: c.stripView.layout.plus.midX, y: c.stripView.layout.plus.midY), in: c)
        XCTAssertEqual(asked, 1)
    }

    /// Tabs and labels dragged along the strip: into a group, out of it,
    /// and a group as a whole.
    func testDragsInTheStrip() throws {
        let c = controller(.vm("web"))
        c.window?.setFrame(NSRect(x: 60, y: 60, width: 1200, height: 400), display: false)
        let first = try XCTUnwrap(c.selectedTab)
        let a = c.addTab(.vm("a")), b = c.addTab(.vm("b")), last = c.addTab(.vm("z"))
        let work = TabGroupID.make()
        c.newGroup(work, name: "work", tabs: [a.id, b.id])
        XCTAssertEqual(c.strip.tabs.map(\.id), [first.id, a.id, b.id, last.id])

        // The last tab onto the left half of b: before it, in its group.
        var from = try frame(.tab(last.id), in: c), to = try frame(.tab(b.id), in: c)
        try drag(from: NSPoint(x: from.midX, y: 16), to: NSPoint(x: to.minX + 6, y: 16), in: c)
        XCTAssertEqual(c.strip.tabs.map(\.id), [first.id, a.id, last.id, b.id])
        XCTAssertEqual(c.strip.group(of: last.id)?.id, work)
        XCTAssertEqual(c.strip.selected, last.id, "the tab dragged is in front")

        // Out again: past the end of the strip.
        from = try frame(.tab(last.id), in: c)
        try drag(from: NSPoint(x: from.midX, y: 16), to: NSPoint(x: c.stripView.layout.plus.maxX + 60, y: 16), in: c)
        XCTAssertEqual(c.strip.tabs.map(\.id), [first.id, a.id, b.id, last.id])
        XCTAssertNil(c.strip.group(of: last.id))

        // The label: the whole group before the first tab; no collapse.
        let label = try frame(.group(work), in: c)
        to = try frame(.tab(first.id), in: c)
        try drag(from: NSPoint(x: label.midX, y: 16), to: NSPoint(x: to.minX + 4, y: 16), in: c)
        XCTAssertEqual(c.strip.tabs.map(\.id), [a.id, b.id, first.id, last.id])
        XCTAssertEqual(c.strip.tabs(in: work), [a.id, b.id])
        XCTAssertEqual(c.strip.group(work)?.collapsed, false)

        // A press that hardly moves is a click, not a drag.
        from = try frame(.tab(first.id), in: c)
        c.stripView.mouseDown(with: try mouse(.leftMouseDown, at: NSPoint(x: from.midX, y: 16), in: c))
        c.stripView.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: from.midX + 2, y: 16), in: c))
        c.stripView.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: from.midX + 2, y: 16), in: c))
        XCTAssertEqual(c.strip.tabs.map(\.id), [a.id, b.id, first.id, last.id])
        XCTAssertEqual(c.strip.selected, first.id)
    }

    /// A new group asks for its name under its label: the name as it is
    /// typed, the colour as it is clicked.
    func testANewGroupIsNamedAndColouredInItsPopover() throws {
        let c = controller(.vm("web"))
        let first = try XCTUnwrap(c.selectedTab)
        c.window?.orderFront(nil)
        c.group(first.id)
        let group = try XCTUnwrap(c.strip.group(of: first.id))
        XCTAssertEqual(group.name, "")
        XCTAssertTrue(c.showsTabStrip)
        let editor = try XCTUnwrap(c.groupEditor)
        let field = try XCTUnwrap(editor.view.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
        // Typing must not hand the keys back to the terminal (seen: the
        // field lost them after the first letter).
        c.window?.makeFirstResponder(nil)
        field.stringValue = "work"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertFalse(c.window?.firstResponder is MonadTerminalView, "the name field keeps the keys while it is typed in")
        XCTAssertEqual(c.strip.group(group.id)?.name, "work")
        XCTAssertEqual(try frame(.group(group.id), in: c).width, TabStripView.chipWidth("work"), "the label grows with its name")
        let swatches = editor.view.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(swatches.count, TabGroupColor.allCases.count)
        let red = try XCTUnwrap(TabGroupColor.allCases.firstIndex(of: .red))
        swatches.first { $0.tag == red }?.performClick(nil)
        XCTAssertEqual(c.strip.group(group.id)?.color, .red)
        XCTAssertEqual(c.saved?.groups.first?.name, "work")
        // Return in the name closes the popover.
        var closed = 0
        editor.onDone = { closed += 1 }
        XCTAssertTrue(editor.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(closed, 1)
        XCTAssertFalse(editor.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveLeft(_:))))
        XCTAssertEqual(closed, 1)
    }

    func testATabMovesToAWindowOfItsOwnWithItsSession() throws {
        let c = controller(.vm("web"))
        let first = try XCTUnwrap(c.selectedTab)
        let second = c.addTab(.vm("db"))
        let session = try XCTUnwrap(second.panes.focusedSession)
        c.moveToNewWindow(second.id)
        XCTAssertEqual(c.strip.tabs.map(\.id), [first.id])
        let other = try XCTUnwrap(TerminalWindowController.all.last)
        XCTAssertFalse(other === c)
        XCTAssertTrue(other.focusedSession === session, "the same session, still running")
        XCTAssertTrue(isShown(second, in: other))
        c.moveToNewWindow(first.id)
        XCTAssertEqual(c.tabCount, 1, "a window's only tab stays")
    }

    func testAGroupMovesToAWindowOfItsOwnAndWindowsMerge() throws {
        let c = controller(.vm("web"))
        let first = try XCTUnwrap(c.selectedTab)
        let a = c.addTab(.vm("a")), b = c.addTab(.vm("b"))
        let work = TabGroupID.make()
        c.newGroup(work, name: "work", color: .green, tabs: [a.id, b.id])
        c.moveToNewWindow(work)
        XCTAssertEqual(c.strip.tabs.map(\.id), [first.id])
        let other = try XCTUnwrap(TerminalWindowController.all.last)
        XCTAssertEqual(other.strip.tabs(in: work), [a.id, b.id])
        XCTAssertEqual(other.strip.group(work)?.name, "work")
        XCTAssertEqual(other.strip.group(work)?.color, .green)

        c.absorb(other)
        XCTAssertFalse(TerminalWindowController.all.contains { $0 === other }, "left with no tab, it closed")
        XCTAssertEqual(c.strip.tabs.map(\.id), [first.id, a.id, b.id])
        XCTAssertEqual(c.strip.group(of: a.id)?.name, "work")
        XCTAssertEqual(c.strip.group(of: b.id)?.id, c.strip.group(of: a.id)?.id)
        XCTAssertEqual(c.strip.selected, first.id)
        XCTAssertEqual(c.allSessions.count, 3)
    }

    /// What Monad keeps to open a window again: its tabs and groups, each
    /// tab's panes and VMs, the tab in front, where it was.
    func testAWindowIsSavedAndComesBackAsItWas() async throws {
        let c = controller(.vm("web"))
        let first = try XCTUnwrap(c.selectedTab)
        let session = try XCTUnwrap(first.panes.focusedSession)
        session.model.feed("\u{1B}]7;file://monad-web/home/dev/site\u{07}")
        await assertEventually { session.directory == "/home/dev/site" }
        let db = c.addTab(.vm("db"))
        c.addTab(.ephemeralVM)
        c.addTab(.host)
        db.panes.split(.horizontal)
        let work = TabGroupID.make()
        c.newGroup(work, name: "work", color: .orange, tabs: [first.id, db.id])
        c.toggleCollapsed(work)
        c.select(db.id)
        c.window?.setFrame(NSRect(x: 140, y: 160, width: 900, height: 520), display: false)

        let saved = try XCTUnwrap(c.saved)
        XCTAssertEqual(saved.tabs.count, 3, "the ephemeral VM's tab is not kept")
        XCTAssertEqual(saved.selected, 1)
        let data = try JSONEncoder().encode(SavedSession(windows: [saved]))
        let read = try XCTUnwrap(JSONDecoder().decode(SavedSession.self, from: data).sanitized.windows.first)
        let back = try XCTUnwrap(TerminalWindowController(restoring: read, host: host))
        XCTAssertEqual(back.orderedTabs.map { $0.panes.allSessions.map(\.target) }, [[.vm("web")], [.vm("db"), .vm("db")], [.host]])
        XCTAssertEqual(back.orderedTabs.first?.panes.focusedSession?.startDirectory, "/home/dev/site")
        let group = try XCTUnwrap(back.strip.groups.first)
        XCTAssertEqual([group.name, group.color.rawValue], ["work", "orange"])
        XCTAssertTrue(group.collapsed)
        XCTAssertEqual(back.strip.tabs(in: group.id).count, 2)
        XCTAssertEqual(back.strip.selected, back.orderedTabs[1].id)
        XCTAssertEqual(back.focusedSession?.target, .vm("db"))
        XCTAssertTrue(back.showsTabStrip)
        if NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSRect(x: 140, y: 160, width: 900, height: 520)) }) {
            XCTAssertEqual(back.window?.frame, NSRect(x: 140, y: 160, width: 900, height: 520))
        }
        XCTAssertEqual(back.saved?.tabs, saved.tabs, "saved again before anything started: the same")

        let onlyEphemeral = controller(.ephemeralVM)
        XCTAssertNil(onlyEphemeral.saved)
    }

    func testAWindowOpensWhereItWasOnlyWhileThatIsOnAScreen() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        XCTAssertTrue(TerminalWindowController.isOnScreen(NSRect(x: 100, y: 100, width: 800, height: 500), screens: screens))
        XCTAssertTrue(TerminalWindowController.isOnScreen(NSRect(x: 1200, y: 100, width: 800, height: 500), screens: screens))
        XCTAssertFalse(TerminalWindowController.isOnScreen(NSRect(x: 3000, y: 100, width: 800, height: 500), screens: screens),
                       "on a display that is gone")
        XCTAssertFalse(TerminalWindowController.isOnScreen(NSRect(x: 1400, y: 880, width: 800, height: 500), screens: screens),
                       "a corner is not enough to reach it")
        XCTAssertFalse(TerminalWindowController.isOnScreen(NSRect(x: 0, y: 0, width: 800, height: 500), screens: []))
    }

    /// The saved session, given the open windows: the tabs of the last
    /// window closed stay for the next start; open windows with nothing
    /// to keep leave nothing.
    func testWhatIsKeptOfTheOpenWindows() throws {
        XCTAssertEqual(SavedSession.keeping([]), .asItIs)
        XCTAssertEqual(SavedSession.keeping([nil, nil]), .nothing)
        let c = controller(.vm("web"))
        let saved = try XCTUnwrap(c.saved)
        XCTAssertEqual(SavedSession.keeping([nil, saved]), .session(SavedSession(windows: [saved])))
    }

    /// A host shell opens again in its folder while that is still there.
    func testAHostShellOpensInItsFolderWhileItIsThere() throws {
        let tmp = TempDir()
        XCTAssertEqual(TerminalSessionViewController.hostDirectory(tmp.url.path, home: "/Users/dev"), tmp.url.path)
        XCTAssertEqual(TerminalSessionViewController.hostDirectory(tmp.url.appendingPathComponent("gone").path, home: "/Users/dev"), "/Users/dev")
        XCTAssertEqual(TerminalSessionViewController.hostDirectory(nil, home: "/Users/dev"), "/Users/dev")
        let file = tmp.url.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertEqual(TerminalSessionViewController.hostDirectory(file.path, home: "/Users/dev"), "/Users/dev")
    }
}
