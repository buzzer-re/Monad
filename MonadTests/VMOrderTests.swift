//
//  VMOrderTests.swift — the order of the VMs (Virtual Machines window, VM
//  settings › Make Default): the top one is the default VM, the one Monad
//  opens first. Kept by MonadHost in instances/order.json.
//

import XCTest
@testable import Monad

final class VMOrderTests: XCTestCase {
    /// Without a saved order "default" comes first (today's default VM),
    /// then the others by name; a saved order is kept, VMs it does not
    /// know come after it by name, ephemeral VMs last.
    func testVMsAreListedInTheUsersOrder() {
        XCTAssertEqual(VMOrder.arrange(["web", "default", "alpha"], ephemeral: [], saved: []),
                       ["default", "alpha", "web"])
        XCTAssertEqual(VMOrder.arrange(["web", "alpha"], ephemeral: [], saved: []), ["alpha", "web"])
        XCTAssertEqual(VMOrder.arrange(["web", "default", "alpha", "zed"], ephemeral: [], saved: ["web", "gone", "default"]),
                       ["web", "default", "alpha", "zed"], "gone VMs are dropped, new ones go after")
        XCTAssertEqual(VMOrder.arrange(["tmp-b", "web", "tmp-a", "default"], ephemeral: ["tmp-a", "tmp-b"],
                                       saved: ["tmp-b", "web"]),
                       ["web", "default", "tmp-a", "tmp-b"], "ephemeral VMs are never in the order")
    }

    /// A move or Make Default: the names asked for first, the others as
    /// they were; names that are not in the list, or twice, are ignored.
    func testAMovePutsTheNamesAskedForFirst() {
        let now = ["default", "web", "db"]
        XCTAssertEqual(VMOrder.reordered(now, requested: ["db"]), ["db", "default", "web"], "Make Default")
        XCTAssertEqual(VMOrder.reordered(now, requested: ["web", "default", "db"]), ["web", "default", "db"])
        XCTAssertEqual(VMOrder.reordered(now, requested: ["nope", "web", "web"]), ["web", "default", "db"])
        XCTAssertEqual(VMOrder.reordered(now, requested: []), now)
    }

    /// The list's drag: SwiftUI's offsets turned into the new order.
    func testDraggingARowMovesIt() {
        let now = ["default", "web", "db"]
        XCTAssertEqual(VMOrder.moving(now, from: IndexSet(integer: 2), to: 0), ["db", "default", "web"])
        XCTAssertEqual(VMOrder.moving(now, from: IndexSet(integer: 0), to: 3), ["web", "db", "default"])
        XCTAssertEqual(VMOrder.moving(now, from: IndexSet(integer: 0), to: 2), ["web", "default", "db"])
        XCTAssertEqual(VMOrder.moving(now, from: IndexSet([0, 2]), to: 2), ["web", "default", "db"])
        XCTAssertEqual(VMOrder.moving(now, from: IndexSet(integer: 1), to: 1), now)
        XCTAssertEqual(VMOrder.moving(now, from: IndexSet(integer: 7), to: 0), now, "out of range: nothing moves")
    }

    /// A row dragged by its handle and dropped on another takes its place:
    /// below it when coming from above, above it when coming from below.
    func testDroppingARowOnAnotherTakesItsPlace() {
        let now = ["x", "a", "y", "b"]
        XCTAssertEqual(VMOrder.dropping(now, "a", onto: "b"), ["x", "y", "b", "a"])
        XCTAssertEqual(VMOrder.dropping(now, "b", onto: "x"), ["b", "x", "a", "y"])
        XCTAssertEqual(VMOrder.dropping(now, "y", onto: "a"), ["x", "y", "a", "b"])
        XCTAssertEqual(VMOrder.dropping(now, "a", onto: "a"), now)
        XCTAssertEqual(VMOrder.dropping(now, "nope", onto: "x"), now, "not a VM in the list")
        XCTAssertEqual(VMOrder.dropping(now, "a", onto: "nope"), now)
        XCTAssertEqual(VMOrder.dropEdge(now, dragging: "a", over: "b"), .below)
        XCTAssertEqual(VMOrder.dropEdge(now, dragging: "b", over: "x"), .above)
        XCTAssertNil(VMOrder.dropEdge(now, dragging: "a", over: "a"))
        XCTAssertNil(VMOrder.dropEdge(now, dragging: nil, over: "a"))
    }

    /// Move Up and Move Down (a row's menu): one place, never past either end.
    func testMoveUpAndDownGoOnePlace() {
        let now = ["default", "web", "db"]
        XCTAssertEqual(VMOrder.step(now, "web", by: -1), ["web", "default", "db"])
        XCTAssertEqual(VMOrder.step(now, "web", by: 1), ["default", "db", "web"])
        XCTAssertEqual(VMOrder.step(now, "default", by: -1), now, "already at the top")
        XCTAssertEqual(VMOrder.step(now, "db", by: 1), now, "already at the bottom")
        XCTAssertEqual(VMOrder.step(now, "nope", by: 1), now)
    }

    /// The file is the user's only (0600) and is read with care: names
    /// that are not VM names, repeats and anything past the cap are
    /// dropped; a broken file is an empty order.
    /// The chosen default VM is kept with the order; a file from before
    /// there was one reads as none chosen.
    func testTheDefaultIsSavedWithTheOrder() throws {
        let tmp = TempDir()
        let store = VMOrderStore(url: tmp.url.appendingPathComponent("order.json"))
        try store.save(["a", "b"], defaultVM: "b")
        XCTAssertEqual(store.load(), ["a", "b"])
        XCTAssertEqual(store.loadDefault(), "b")
        try Data(#"{"version":1,"order":["a"]}"#.utf8).write(to: store.url)
        XCTAssertNil(store.loadDefault())
        try Data(#"{"version":1,"order":["a"],"defaultVM":"Bad Name"}"#.utf8).write(to: store.url)
        XCTAssertNil(store.loadDefault())
    }

    func testTheOrderIsSavedAndReadWithCare() throws {
        let tmp = TempDir()
        let url = tmp.url.appendingPathComponent("order.json")
        let store = VMOrderStore(url: url)
        XCTAssertEqual(store.load(), [], "no file yet")
        try store.save(["web", "default"])
        XCTAssertEqual(store.load(), ["web", "default"])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self),
                       #"{"order":["web","default"],"version":1}"#)

        try Data(#"{"order":["web","../x","web","default",""],"version":1}"#.utf8).write(to: url)
        XCTAssertEqual(store.load(), ["web", "default"])
        try Data((#"{"order":["# + (0..<5000).map { "\"vm\($0)\"" }.joined(separator: ",") + #"],"version":1}"#).utf8)
            .write(to: url)
        XCTAssertEqual(store.load().count, VMOrder.maxVMs)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(store.load(), [])
        try Data(#"{"order":["web"],"version":9}"#.utf8).write(to: url)
        XCTAssertEqual(store.load(), [], "a newer Monad's file is not guessed at")
    }
}
