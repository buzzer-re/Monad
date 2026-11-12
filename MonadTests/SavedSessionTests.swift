//
//  SavedSessionTests.swift — what Monad keeps of its terminal windows to
//  open them again: each window's tabs and groups, each tab's panes, and
//  for each context its VM and the directory its shell was in. Ephemeral
//  VMs are gone by then and are left out. The file is the user's
//  (~/.monad/session.json), but nothing in it is taken on trust: the
//  directories in it came from guests.
//

import XCTest
@testable import Monad

final class SavedSessionTests: XCTestCase {
    private typealias Context = SavedSession.Context

    private func vm(_ name: String, _ directory: String? = nil) -> Context {
        Context(kind: .vm, vm: name, directory: directory, theme: nil)
    }

    private func window(_ tabs: [SavedSession.Tab], groups: [TabGroup] = [], selected: Int = 0,
                        frame: [Double]? = [10, 20, 800, 500]) -> SavedSession.Window {
        SavedSession.Window(frame: frame, tabs: tabs, groups: groups, selected: selected)
    }

    private func tab(_ contexts: Context..., group: String? = nil) -> SavedSession.Tab {
        let pane = PaneID("p")
        return SavedSession.Tab(group: group, panes: SavedSession.Panes(
            tree: PaneTree(pane: pane), contexts: [pane.value: contexts], visible: [pane.value: 0]))
    }

    // MARK: Panes

    func testATabsPanesComeBackAsTheyWere() throws {
        let c1 = ContextID("c1"), c2 = ContextID("c2"), c3 = ContextID("c3")
        var layout = PaneLayout(context: c1, pane: PaneID("left"))
        layout.addContext(c2)
        layout.split(.horizontal, pane: PaneID("right"), context: c3)
        layout.setFractions([0.7, 0.3], ofSplitAt: [])
        layout.show(c1)
        let saved = try XCTUnwrap(SavedSession.Panes(layout: layout) { id in
            self.vm(id == c3 ? "db" : "web", "/srv/\(id.value)")
        })
        let data = try JSONEncoder().encode(saved)
        let back = try XCTUnwrap(JSONDecoder().decode(SavedSession.Panes.self, from: data).restored())
        XCTAssertEqual(back.layout.tree, layout.tree)
        let left = back.layout.contexts(in: PaneID("left")), right = back.layout.contexts(in: PaneID("right"))
        XCTAssertEqual(left.compactMap { back.contexts[$0]?.directory }, ["/srv/c1", "/srv/c2"])
        XCTAssertEqual(right.compactMap { back.contexts[$0]?.vm }, ["db"])
        XCTAssertEqual(back.layout.focusedContext.flatMap { back.contexts[$0]?.directory }, "/srv/c1")
        XCTAssertFalse(left.contains(c1), "contexts get ids of their own")
    }

    func testContextsThatCannotComeBackAreLeftOut() throws {
        let keep = ContextID("keep"), gone = ContextID("gone"), alone = ContextID("alone")
        var layout = PaneLayout(context: keep, pane: PaneID("a"))
        layout.addContext(gone)
        layout.split(.vertical, pane: PaneID("b"), context: alone)
        let saved = try XCTUnwrap(SavedSession.Panes(layout: layout) { $0 == keep ? self.vm("web") : nil })
        XCTAssertEqual(saved.tree.panes, [PaneID("a")], "a pane left with nothing closes")
        XCTAssertEqual(saved.contexts["a"]?.count, 1)
        XCTAssertNotNil(saved.restored())
        XCTAssertNil(SavedSession.Panes(layout: layout) { _ in nil }, "nothing to bring back: no tab")
    }

    // MARK: The file

    func testASessionIsKeptInAPrivateFile() throws {
        let tmp = TempDir()
        let store = SessionStore(url: tmp.url.appendingPathComponent("monad/session.json"))
        XCTAssertNil(store.load())
        let work = TabGroup(id: TabGroupID("g"), name: "work", color: .purple, collapsed: true)
        let session = SavedSession(windows: [window([tab(vm("web", "/home/dev/site"), group: "g"),
                                                     tab(Context(kind: .host, vm: nil, directory: nil, theme: "Pro"))],
                                                    groups: [work], selected: 1)])
        try store.save(session)
        XCTAssertEqual(store.load(), session)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testAFileThatMakesNoSenseIsIgnored() throws {
        let tmp = TempDir()
        let store = SessionStore(url: tmp.url.appendingPathComponent("session.json"))
        try Data("{ not json".utf8).write(to: store.url)
        XCTAssertNil(store.load())
        var newer = SavedSession(windows: [window([tab(vm("web"))])])
        newer.version = SavedSession.currentVersion + 1
        try JSONEncoder().encode(newer).write(to: store.url)
        XCTAssertNil(store.load(), "a later Monad's file")
        try Data(count: 5 << 20).write(to: store.url)
        XCTAssertNil(store.load(), "too big to be one")
        try store.save(SavedSession(windows: []))
        XCTAssertNil(store.load(), "no window: nothing to open")
    }

    func testNothingInTheFileIsTakenOnTrust() throws {
        let long = "/" + String(repeating: "x", count: 5000)
        let s = SavedSession(windows: [
            window([tab(vm("web", "relative/path")), tab(vm("web", "/tmp/a\u{1B}]0;x\u{07}")), tab(vm("web", long)),
                    tab(vm("web; rm -rf ~")), tab(vm("")), tab(Context(kind: .vm, vm: nil, directory: nil, theme: nil)),
                    tab(vm("web", "/ok"), Context(kind: .host, vm: nil, directory: "/Users/dev", theme: String(repeating: "t", count: 999)))],
                   selected: 99, frame: [0, 0, .infinity, 5]),
            window([tab(vm("$(id)"))]),
        ]).sanitized
        XCTAssertEqual(s.windows.count, 1, "a window with no tab left is not opened")
        let w = try XCTUnwrap(s.windows.first)
        XCTAssertNil(w.frame)
        XCTAssertEqual(w.tabs.count, 4, "tabs on VMs with impossible names are left out")
        XCTAssertEqual(w.tabs.prefix(3).map { $0.panes.contexts["p"]?.first?.directory }, [nil, nil, nil])
        XCTAssertEqual(w.tabs[3].panes.contexts["p"], [vm("web", "/ok"), Context(kind: .host, vm: nil, directory: "/Users/dev", theme: nil)])
        XCTAssertEqual(w.selected, 3)
    }

    func testTooMuchIsCutShort() {
        let many = (0..<500).map { _ in tab(vm("web")) }
        let s = SavedSession(windows: (0..<100).map { _ in window(many) }).sanitized
        XCTAssertEqual(s.windows.count, SavedSession.maxWindows)
        XCTAssertEqual(s.windows[0].tabs.count, SavedSession.maxTabs)
    }

    func testPanesThatDoNotFitTogetherAreLeftOut() throws {
        var layout = PaneLayout(context: ContextID("1"), pane: PaneID("a"))
        layout.split(.horizontal, pane: PaneID("b"), context: ContextID("2"))
        let good = try XCTUnwrap(SavedSession.Panes(layout: layout) { _ in self.vm("web") })
        XCTAssertNotNil(good.restored())
        // A split with fewer shares than panes, as a damaged file has it.
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(good), encoding: .utf8))
        XCTAssertTrue(json.contains("[0.5,0.5]"))
        let bad = try JSONDecoder().decode(SavedSession.Panes.self, from: Data(json.replacingOccurrences(of: "[0.5,0.5]", with: "[0.5]").utf8))
        XCTAssertFalse(bad.tree.isSound)
        XCTAssertNil(bad.restored())
        var missing = good
        missing.contexts["b"] = nil
        XCTAssertNil(missing.restored(), "a pane with no context")
        var twice = good
        twice.tree = try JSONDecoder().decode(PaneTree.self, from: Data(
            String(data: JSONEncoder().encode(good.tree), encoding: .utf8)!.replacingOccurrences(of: "\"b\"", with: "\"a\"").utf8))
        XCTAssertNil(twice.restored(), "the same pane twice")
        XCTAssertEqual(SavedSession(windows: [window([SavedSession.Tab(group: nil, panes: bad), tab(vm("web"))])]).sanitized.windows.first?.tabs.count, 1)
    }
}
