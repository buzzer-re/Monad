//
//  CanvasWindowModelTests.swift — the canvas window: making a VM or a
//  network opens one sheet at a time (two sheet modifiers on one view do
//  not both present on macOS, and New did nothing), for the network under
//  the pointer.
//

import XCTest
@testable import Monad

@MainActor
final class CanvasWindowModelTests: XCTestCase {
    private func canvas() -> CanvasWindowModel {
        CanvasWindowModel(host: HostClient(connect: { throw MonadError("no host here") }), store: nil)
    }

    func testMakingSomethingOpensOneSheet() {
        let c = canvas()
        XCTAssertNil(c.sheet)
        c.makeNetwork(at: CGPoint(x: 5, y: 6))
        XCTAssertEqual(c.sheet, .network(editing: nil, at: CGPoint(x: 5, y: 6)))
        c.makeVM(at: CGPoint(x: 1, y: 2))
        XCTAssertEqual(c.sheet, .newVM(network: NetworkDefinition.defaultName, at: CGPoint(x: 1, y: 2)),
                       "outside every network: the default one")
        c.editNetwork("lab", at: .zero)
        XCTAssertEqual(c.sheet, .network(editing: "lab", at: .zero))
        c.sheet = nil
        XCTAssertNil(c.sheet)
    }

    /// Writing tools: an arrow takes two clicks (the same thing twice draws
    /// nothing), a note or label clicked onto a VM or network is pinned there
    /// and written at once, a note left empty goes, a zone made on a network
    /// wraps it, and Esc leaves nothing half made.
    func testWritingOnTheCanvas() {
        let c = canvas()
        XCTAssertFalse(c.toolTap("vm:web"), "selecting is not writing")
        c.tool = .arrow
        XCTAssertTrue(c.toolTap("vm:web"))
        XCTAssertEqual(c.arrowStart, "vm:web")
        XCTAssertTrue(c.notes.isEmpty)
        _ = c.toolTap("vm:web")
        XCTAssertNil(c.arrowStart)
        XCTAssertTrue(c.notes.isEmpty, "not to itself")
        _ = c.toolTap("vm:web")
        _ = c.toolTap("net:lab")
        let arrow = c.notes.last
        XCTAssertEqual(arrow?.kind, .arrow)
        XCTAssertEqual(arrow?.on, "vm:web")
        XCTAssertEqual(arrow?.to, "net:lab")
        XCTAssertEqual(c.selectedNote, arrow?.id)
        XCTAssertNil(c.editingNote)

        c.tool = .note
        c.tint = .green
        XCTAssertTrue(c.toolTap("vm:web"))
        let note = c.notes.last
        XCTAssertEqual(note?.on, "vm:web")
        XCTAssertEqual(note?.tint, .green)
        XCTAssertEqual(c.editingNote, note?.id)
        XCTAssertEqual(c.tool, .select)
        c.finishEditing(note!.id, text: "  \n")
        XCTAssertNil(c.note(note!.id), "an empty note goes")

        c.tool = .label
        XCTAssertFalse(c.toolTap("mac"), "labels go on VMs and networks")
        XCTAssertTrue(c.toolTap("net:lab"))
        c.finishEditing(c.notes.last!.id, text: "isolated")
        XCTAssertEqual(c.notes.last?.text, "isolated")

        c.write(.zone, on: "net:lab")
        XCTAssertEqual(c.notes.last?.around, ["net:lab"])
        XCTAssertNil(c.notes.last?.on)

        c.tool = .arrow
        _ = c.toolTap("mac")
        c.cancelWriting()
        XCTAssertEqual(c.tool, .select)
        XCTAssertNil(c.arrowStart)
    }

    /// ⌘Z and ⇧⌘Z: writing, editing, recolouring and deleting go back and
    /// forth; a note deleted comes back with the arrows that went with it.
    func testUndoAndRedo() {
        let c = canvas()
        let undo = UndoManager()
        undo.groupsByEvent = false
        c.undoManager = undo
        c.write(.note, frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        let id = c.notes.last!.id
        c.finishEditing(id, text: "first")
        c.recolor(id, .blue)
        XCTAssertEqual(c.note(id)?.tint, .blue)
        undo.undo()
        XCTAssertEqual(c.note(id)?.tint, .yellow, "the colour back")
        undo.undo()
        XCTAssertEqual(c.note(id)?.text, "", "the text back")
        undo.undo()
        XCTAssertNil(c.note(id), "never written")
        undo.redo()
        XCTAssertNotNil(c.note(id))
        undo.redo()
        XCTAssertEqual(c.note(id)?.text, "first")

        c.write(.arrow, on: "note:" + id, to: "vm:web")
        XCTAssertEqual(c.notes.count, 2)
        c.removeNote(id)
        XCTAssertTrue(c.notes.isEmpty, "the arrow to it went too")
        undo.undo()
        XCTAssertEqual(c.notes.map(\.kind), [.note, .arrow], "both back")
        XCTAssertEqual(c.note(id)?.text, "first")
    }

    /// Delete: the selected note goes; a selected VM is only asked about
    /// (its disk cannot come back).
    func testDeleteRemovesTheSelection() {
        let c = canvas()
        c.write(.note, frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        let id = c.notes.last!.id
        c.editingNote = nil
        c.deleteSelection()
        XCTAssertNil(c.note(id))
        XCTAssertNil(c.selectedNote)
        c.selected = "web"
        c.deleteSelection()
        XCTAssertEqual(c.deleting, "web", "asked, not deleted")
    }

    /// This Mac's Show Forwards: every link between the Mac and the VMs, by
    /// VM, in the VM window's words, off ones marked.
    func testTheLinksToThisMacAreListedByVM() {
        var web = InstanceConfig.defaults(name: "web")
        let local = ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)
        var off = ForwardRule(kind: .remote, hostPort: 9000, guestPort: 9000)
        off.enabled = false
        web.forwards = [local, off]
        var db = InstanceConfig.defaults(name: "db")
        db.bridges = [CommandBridge(name: "mcp", command: ["/usr/bin/xcrun", "mcpbridge"], guestPort: 9001)]
        let links = MacLinks.list([web, db, InstanceConfig.defaults(name: "quiet")])
        XCTAssertEqual(links.map(\.vm), ["db", "web"], "VMs with links, by name")
        XCTAssertEqual(links[1].lines, [MacLinks.Line(text: VMSettingsDraft.describe(local), on: true, bridge: false),
                                         MacLinks.Line(text: VMSettingsDraft.describe(off), on: false, bridge: false)])
        XCTAssertEqual(links[0].lines, [MacLinks.Line(text: "Bridge mcp: /usr/bin/xcrun mcpbridge at 127.0.0.1:9001 in the VM",
                                                       on: true, bridge: true)])
        let c = canvas()
        c.showMacLinks()
        XCTAssertEqual(c.sheet, .macLinks)
    }
}
