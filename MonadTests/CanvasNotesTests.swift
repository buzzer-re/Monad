//
//  CanvasNotesTests.swift — what the user and agents write on the canvas:
//  notes, labels, zones, arrows and ink, checked like any input from an
//  agent, kept by MonadHost in a private file, forgotten with what they
//  were on, and placed on the canvas next to what they are about.
//

import XCTest
@testable import Monad

final class CanvasNotesTests: XCTestCase {
    private func note(_ kind: CanvasNote.Kind, _ text: String = "hi", id: String = "a1",
                      on: String? = nil, to: String? = nil) -> CanvasNote {
        CanvasNote(id: id, kind: kind, text: text, on: on, to: to)
    }

    private func model() -> CanvasModel {
        var m = CanvasModel()
        m.update(vms: [CanvasVM(name: "web", network: "lab", running: true, linksToMac: false),
                       CanvasVM(name: "db", network: "lab", running: true, linksToMac: false),
                       CanvasVM(name: "box", network: "dirty", running: false, linksToMac: false)],
                 networks: [CanvasNetwork(name: "lab", kind: .nat), CanvasNetwork(name: "dirty", kind: .internal)])
        return m
    }

    // MARK: Checks

    func testWhatTheyMayBe() throws {
        var zone = note(.zone, "Malware lab")
        zone.around = ["net:lab", "net:dirty"]
        var drawn = note(.zone, "Scratch")
        drawn.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        var ink = note(.ink, "")
        ink.points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 4)]
        for good in [note(.note, "**Detonation** box, no internet"), note(.note, "pinned", on: "vm:box"),
                     note(.label, "isolated", on: "net:dirty"), note(.label, "C2", on: "vm:web"),
                     note(.arrow, "logs", on: "vm:box", to: "vm:web"), note(.arrow, "", on: "note:b2", to: "internet"),
                     note(.arrow, "", on: "mac", to: "net:lab"), zone, drawn, ink] {
            XCTAssertNoThrow(try good.validate(), "\(good)")
        }
        var bad: [(CanvasNote, String)] = [
            (note(.note, id: "Not An ID"), "id"),
            (note(.note, id: ""), "empty id"),
            (note(.label), "a label is on something"),
            (note(.label, String(repeating: "x", count: CanvasNote.maxLabel + 1), on: "vm:web"), "a long label"),
            (note(.label, "x", on: "note:a2"), "a label is on a VM or a network"),
            (note(.arrow, on: "vm:web"), "an arrow goes somewhere"),
            (note(.arrow, on: "vm:Bad Name", to: "vm:web"), "not a VM name"),
            (note(.arrow, on: "disk:web", to: "vm:web"), "not a kind of thing"),
            (note(.arrow, on: "vm:web", to: "vm:web"), "to itself"),
            (note(.note, String(repeating: "x", count: CanvasNote.maxText + 1)), "too long"),
            (note(.note, "bell\u{7}"), "control characters"),
            (note(.zone, "nowhere"), "a zone has a frame or wraps something"),
        ]
        var nan = note(.note)
        nan.frame = CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)
        bad.append((nan, "not a number"))
        var huge = note(.note)
        huge.frame = CGRect(x: 0, y: 0, width: 1e9, height: 10)
        bad.append((huge, "too big"))
        var dot = note(.ink, "")
        dot.points = [CGPoint(x: 1, y: 1)]
        bad.append((dot, "ink is a stroke"))
        var crowd = note(.zone)
        crowd.around = (0...CanvasNote.maxAround).map { "vm:v\($0)" }
        bad.append((crowd, "wraps too much"))
        for (n, why) in bad {
            XCTAssertThrowsError(try n.validate(), why)
        }
    }

    /// A note's links open only on the web, as the terminal's do: another
    /// scheme (a file, an app, System Settings, a shortcut) shows as text.
    func testANotesLinksAreWebOnly() {
        let shown = CanvasNoteCard.markdown("[a](https://example.com/x) [b](file:///Applications/Utilities/Terminal.app) "
                                            + "[c](x-apple.systempreferences:com.apple.preference.security) "
                                            + "[d](shortcuts://run-shortcut?name=x) [e](http://example.org)")
        let links = shown.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.absoluteString), ["https://example.com/x", "http://example.org"])
        XCTAssertEqual(String(shown.characters), "a b c d e", "the words stay")
    }

    func testIdsAreShortAndNew() {
        let ids = (0..<50).map { _ in CanvasNote.newID() }
        XCTAssertEqual(Set(ids).count, 50)
        for id in ids { XCTAssertNoThrow(try note(.note, id: id).validate(), id) }
    }

    /// An agent may name a thing plainly: a VM, else a network.
    func testRefsInPlainWords() {
        XCTAssertEqual(CanvasRef("vm:web"), .vm("web"))
        XCTAssertEqual(CanvasRef("net:lab"), .network("lab"))
        XCTAssertEqual(CanvasRef("note:ab12"), .note("ab12"))
        XCTAssertEqual(CanvasRef("mac"), .mac)
        XCTAssertEqual(CanvasRef("internet"), .internet)
        XCTAssertNil(CanvasRef("web"))
        XCTAssertEqual(CanvasRef.resolve("web", vms: ["web"], networks: ["lab"]), "vm:web")
        XCTAssertEqual(CanvasRef.resolve("lab", vms: ["web"], networks: ["lab"]), "net:lab")
        XCTAssertEqual(CanvasRef.resolve("net:lab", vms: [], networks: []), "net:lab")
        XCTAssertNil(CanvasRef.resolve("ghost", vms: ["web"], networks: ["lab"]))
    }

    // MARK: Keeping them

    func testTheStoreKeepsGoodNotesOnly() throws {
        let tmp = TempDir()
        let store = CanvasNoteStore(url: tmp.url.appendingPathComponent("canvas-notes.json"))
        XCTAssertEqual(store.load(), [])
        let notes = [note(.note, "one", id: "a1"), note(.label, "two", id: "b2", on: "vm:web")]
        try store.save(notes)
        XCTAssertEqual(store.load(), notes)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        // One bad note in the file is left out, the rest kept.
        var text = String(decoding: try Data(contentsOf: store.url), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"vm:web\"", with: "\"vm:Bad Name\"")
        try Data(text.utf8).write(to: store.url)
        XCTAssertEqual(store.load().map(\.id), ["a1"])
        try Data("{not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), [])
    }

    /// What goes takes its labels and arrows along; notes pinned to it stay,
    /// unpinned; a zone that wrapped only it goes too.
    func testWhatIsGoneIsForgotten() {
        var zone = note(.zone, "both", id: "z1")
        zone.around = ["vm:box", "vm:web"]
        var lone = note(.zone, "lone", id: "z2")
        lone.around = ["vm:box"]
        let notes = [note(.label, "x", id: "l1", on: "vm:box"), note(.label, "y", id: "l2", on: "vm:web"),
                     note(.arrow, "", id: "r1", on: "vm:web", to: "vm:box"), note(.note, "p", id: "n1", on: "vm:box"),
                     note(.arrow, "", id: "r2", on: "note:n1", to: "vm:web"), zone, lone]
        let after = CanvasNote.forget("vm:box", in: notes)
        XCTAssertEqual(after.map(\.id), ["l2", "n1", "r2", "z1"])
        XCTAssertNil(after.first { $0.id == "n1" }?.on, "unpinned")
        XCTAssertEqual(after.first { $0.id == "z1" }?.around, ["vm:web"])
        XCTAssertEqual(CanvasNote.forget("note:n1", in: after).map(\.id), ["l2", "z1"], "arrows to a note go with it")
    }

    func testInkIsSimplified() {
        let line = (0...100).map { CGPoint(x: CGFloat($0), y: CGFloat($0) * 0.5) }
        XCTAssertEqual(CanvasNote.simplify(line), [line.first!, line.last!], "a straight line is two points")
        let corner = (0...50).map { CGPoint(x: CGFloat($0), y: 0) } + (1...50).map { CGPoint(x: 50, y: CGFloat($0)) }
        XCTAssertEqual(CanvasNote.simplify(corner), [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50)])
        let scribble = (0..<10_000).map { CGPoint(x: CGFloat($0 % 97) * 3, y: CGFloat($0 % 89) * 5) }
        XCTAssertLessThanOrEqual(CanvasNote.simplify(scribble).count, CanvasNote.maxPoints)
    }

    // MARK: On the canvas

    func testThingsHaveAPlace() throws {
        let m = model()
        let web = try XCTUnwrap(m.rect(of: "vm:web"))
        XCTAssertEqual(web.size, CanvasModel.node)
        XCTAssertEqual(m.rect(of: "net:lab"), m.frame("lab"))
        XCTAssertNotNil(m.rect(of: "mac"))
        XCTAssertNotNil(m.rect(of: "internet"))
        XCTAssertNil(m.rect(of: "vm:ghost"))
        XCTAssertNil(m.rect(of: "net:gone"))
    }

    /// A note without a place of its own sits beside what it is pinned to
    /// (several stack down), a free one right of everything; a zone wraps
    /// what it is around; a moved note stays where it was put.
    func testNotesAndZonesArePlaced() throws {
        let m = model()
        var zone = note(.zone, "lab", id: "z1")
        zone.around = ["net:lab", "net:dirty"]
        var moved = note(.note, "moved", id: "n4")
        moved.frame = CGRect(x: -500, y: -500, width: 200, height: 100)
        let notes = [note(.note, "first", id: "n1", on: "vm:web"), note(.note, "second", id: "n2", on: "vm:web"),
                     note(.note, "free", id: "n3"), moved, zone, note(.note, "lost", id: "n5", on: "vm:ghost")]
        let places = CanvasNotesLayout.place(notes, in: m)
        let web = try XCTUnwrap(m.rect(of: "vm:web"))
        let n1 = try XCTUnwrap(places["n1"]), n2 = try XCTUnwrap(places["n2"])
        XCTAssertGreaterThan(n1.minX, web.maxX)
        XCTAssertEqual(n1.minY, web.minY, accuracy: 1)
        XCTAssertGreaterThan(n2.minY, n1.maxY - 1, "stacked, not on top of each other")
        let everything = m.layout.frames.values.reduce(CGRect.null) { $0.union($1) }
        XCTAssertGreaterThan(try XCTUnwrap(places["n3"]).minX, everything.maxX)
        XCTAssertEqual(places["n4"], moved.frame)
        let z = try XCTUnwrap(places["z1"])
        let labFrame = try XCTUnwrap(m.frame("lab")), dirtyFrame = try XCTUnwrap(m.frame("dirty"))
        XCTAssertTrue(z.contains(labFrame) && z.contains(dirtyFrame))
        XCTAssertNotNil(places["n5"], "pinned to something gone: placed as a free note")
    }

    func testANotesSizeFollowsItsText() {
        let short = CanvasNotesLayout.size(of: "hi")
        let long = CanvasNotesLayout.size(of: String(repeating: "word ", count: 120))
        XCTAssertEqual(short.width, long.width)
        XCTAssertGreaterThan(long.height, short.height)
        XCTAssertLessThanOrEqual(long.height, CanvasNotesLayout.maxAutoHeight)
    }

    /// An arrow leaves and reaches the edges of what it joins, not their middles.
    func testArrowsJoinEdges() throws {
        let m = model()
        let a = try XCTUnwrap(m.rect(of: "vm:web")), b = try XCTUnwrap(m.rect(of: "vm:box"))
        let arrow = CanvasNotesLayout.arrow(from: a, to: b)
        XCTAssertFalse(a.insetBy(dx: 1, dy: 1).contains(arrow.start))
        XCTAssertTrue(a.insetBy(dx: -1, dy: -1).contains(arrow.start))
        XCTAssertFalse(b.insetBy(dx: 1, dy: 1).contains(arrow.end))
        XCTAssertTrue(b.insetBy(dx: -1, dy: -1).contains(arrow.end))
    }

    /// A click near an arrow or a stroke, or on a zone's edge, picks it;
    /// the inside of a zone is left to what is in it.
    func testHitting() throws {
        let m = model()
        var ink = note(.ink, "", id: "i1")
        ink.points = [CGPoint(x: -400, y: -400), CGPoint(x: -300, y: -400)]
        var zone = note(.zone, "z", id: "z1")
        zone.frame = CGRect(x: -1000, y: -1000, width: 400, height: 300)
        let arrow = note(.arrow, "", id: "r1", on: "vm:web", to: "vm:box")
        let notes = [ink, zone, arrow]
        let places = CanvasNotesLayout.place(notes, in: m)
        XCTAssertEqual(CanvasNotesLayout.hit(CGPoint(x: -350, y: -397), notes, places: places, in: m), "i1")
        XCTAssertEqual(CanvasNotesLayout.hit(CGPoint(x: -1000, y: -900), notes, places: places, in: m), "z1")
        XCTAssertNil(CanvasNotesLayout.hit(CGPoint(x: -800, y: -850), notes, places: places, in: m))
        let a = try XCTUnwrap(m.rect(of: "vm:web")), b = try XCTUnwrap(m.rect(of: "vm:box"))
        let mid = CanvasNotesLayout.arrow(from: a, to: b).point(at: 0.5)
        XCTAssertEqual(CanvasNotesLayout.hit(mid, notes, places: places, in: m), "r1")
    }
}
