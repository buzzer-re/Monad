//
//  CanvasModelTests.swift — the canvas (Phase 13): networks as frames and
//  VMs as nodes inside them, placed on their own and kept where the user
//  puts them, a VM's network being the frame it sits in (dropped into
//  another, it asks to move there), edges for traffic between VMs, links
//  to this Mac and NAT networks' way out, and the layout saved to disk.
//

import XCTest
@testable import Monad

final class CanvasModelTests: XCTestCase {
    private let nat = CanvasNetwork(name: "default", kind: .nat)
    private let lab = CanvasNetwork(name: "lab", kind: .internal)

    private func vm(_ name: String, _ network: String?, running: Bool = true, mac: Bool = false) -> CanvasVM {
        CanvasVM(name: name, network: network, running: running, linksToMac: mac)
    }

    private func model(_ vms: [CanvasVM], _ networks: [CanvasNetwork]? = nil) -> CanvasModel {
        var m = CanvasModel()
        m.update(vms: vms, networks: networks ?? [nat, lab])
        return m
    }

    /// The node's rectangle.
    private func rect(_ m: CanvasModel, _ name: String) throws -> CGRect {
        let p = try XCTUnwrap(m.position(name), name)
        return CGRect(x: p.x - CanvasModel.node.width / 2, y: p.y - CanvasModel.node.height / 2,
                      width: CanvasModel.node.width, height: CanvasModel.node.height)
    }

    func testNetworksAndVMsArePlacedOnTheirOwn() throws {
        let m = model([vm("a", "default"), vm("b", "default"), vm("c", "lab"), vm("d", nil)])
        let def = try XCTUnwrap(m.frame("default")), labFrame = try XCTUnwrap(m.frame("lab"))
        let outside = try XCTUnwrap(m.frame(CanvasModel.outside), "VMs on no Monad network have their own area")
        XCTAssertFalse(def.intersects(labFrame))
        XCTAssertFalse(def.intersects(outside) || labFrame.intersects(outside))
        let a = try rect(m, "a"), b = try rect(m, "b"), c = try rect(m, "c"), d = try rect(m, "d")
        XCTAssertTrue(def.contains(a) && def.contains(b))
        XCTAssertTrue(labFrame.contains(c))
        XCTAssertTrue(outside.contains(d))
        XCTAssertFalse(a.intersects(b))
        // This Mac and the Internet stand apart from every frame.
        for frame in [def, labFrame, outside] {
            XCTAssertFalse(frame.contains(m.macPosition) || frame.contains(m.internetPosition))
        }
        var again = m
        again.update(vms: [vm("a", "default"), vm("b", "default"), vm("c", "lab"), vm("d", nil)], networks: [nat, lab])
        XCTAssertEqual(again.layout, m.layout, "nothing moves by itself")
    }

    /// Networks are placed in rows that wrap, so the map stays near the
    /// window's shape instead of one long strip.
    func testNetworksWrapIntoRows() throws {
        let networks = (1...5).map { CanvasNetwork(name: "net\($0)", kind: .nat) }
        let m = model(networks.map { vm("vm-\($0.name)", $0.name) }, networks)
        let frames = try networks.map { try XCTUnwrap(m.frame($0.name)) }
        XCTAssertGreaterThan(Set(frames.map(\.minY)).count, 1, "more than one row")
        XCTAssertLessThanOrEqual(frames.map(\.maxX).max() ?? 0, CanvasModel.rowWidth + CanvasModel.minFrame.width)
        for (i, f) in frames.enumerated() {
            for other in frames[(i + 1)...] { XCTAssertFalse(f.intersects(other)) }
        }
    }

    func testAFrameGrowsToHoldItsVMs() throws {
        let names = (1...7).map { "vm\($0)" }
        let m = model(names.map { vm($0, "default") })
        let frame = try XCTUnwrap(m.frame("default"))
        let rects = try names.map { try rect(m, $0) }
        for (i, r) in rects.enumerated() {
            XCTAssertTrue(frame.contains(r), names[i])
            for other in rects[(i + 1)...] { XCTAssertFalse(r.intersects(other)) }
        }
        XCTAssertFalse(frame.intersects(try XCTUnwrap(m.frame("lab"))), "the next frame makes room")
    }

    func testAVMsNetworkIsTheFrameItSitsIn() throws {
        let m = model([vm("a", "default")])
        let def = try XCTUnwrap(m.frame("default")), labFrame = try XCTUnwrap(m.frame("lab"))
        XCTAssertEqual(m.network(at: CGPoint(x: def.midX, y: def.midY)), "default")
        XCTAssertEqual(m.network(at: CGPoint(x: labFrame.midX, y: labFrame.midY)), "lab")
        XCTAssertNil(m.network(at: CGPoint(x: def.minX - 500, y: def.minY - 500)))
    }

    func testDroppingAVMIntoAnotherNetworkAsksToMoveIt() throws {
        var m = model([vm("a", "default"), vm("b", "default")])
        let before = try XCTUnwrap(m.position("a"))
        let labFrame = try XCTUnwrap(m.frame("lab"))
        let target = CGPoint(x: labFrame.midX, y: labFrame.midY)
        m.drag("a", to: target)
        XCTAssertEqual(m.drop("a", at: target), .moveVM("a", from: "default", to: "lab"))
        XCTAssertTrue(try XCTUnwrap(m.frame("lab")).contains(try rect(m, "a")), "it waits there for the answer")
        m.update(vms: [vm("a", "default"), vm("b", "default")], networks: [nat, lab])
        XCTAssertTrue(try XCTUnwrap(m.frame("lab")).contains(try rect(m, "a")), "while the question is open")
        m.cancelMove("a")
        XCTAssertEqual(m.position("a"), before, "no: back where it was")
        // Yes: the VM's settings say lab from then on, and it stays.
        m.drag("a", to: target)
        _ = m.drop("a", at: target)
        m.update(vms: [vm("a", "lab"), vm("b", "default")], networks: [nat, lab])
        XCTAssertTrue(try XCTUnwrap(m.frame("lab")).contains(try rect(m, "a")))
        XCTAssertEqual(m.network(at: try XCTUnwrap(m.position("a"))), "lab")
    }

    func testDroppingInItsOwnNetworkOrOutsideChangesNothing() throws {
        var m = model([vm("a", "default"), vm("b", "default")])
        let def = try XCTUnwrap(m.frame("default"))
        let start = try XCTUnwrap(m.position("a"))
        let inside = CGPoint(x: def.maxX - CanvasModel.node.width / 2 - 1, y: def.maxY - CanvasModel.node.height / 2 - 1)
        m.drag("a", to: inside)
        XCTAssertNil(m.drop("a", at: inside))
        XCTAssertEqual(m.position("a"), inside, "moved within its network")
        let far = CGPoint(x: def.minX - 900, y: def.minY - 900)
        m.drag("a", to: far)
        XCTAssertNil(m.drop("a", at: far))
        XCTAssertEqual(m.position("a"), inside, "dropped on no network: back")
        XCTAssertNotEqual(start, inside)
        // A VM on no Monad network goes nowhere by a drop on its own area.
        var n = model([vm("d", nil)])
        let outside = try XCTUnwrap(n.frame(CanvasModel.outside))
        XCTAssertNil(n.drop("d", at: CGPoint(x: outside.midX, y: outside.midY)))
    }

    /// What is made on the canvas appears where it was made: a network's
    /// frame at the spot, a VM at the spot when that is in its network.
    func testNewThingsAppearWhereTheyWereMade() throws {
        var m = model([vm("a", "default")], [nat])
        let spot = CGPoint(x: 1400, y: 600)
        m.hint(network: "lab", at: spot)
        m.update(vms: [vm("a", "default")], networks: [nat, lab])
        XCTAssertEqual(m.frame("lab")?.origin, spot, "the new network")
        let def = try XCTUnwrap(m.frame("default"))
        let inside = CGPoint(x: def.maxX - CanvasModel.node.width / 2 - 20, y: def.maxY - 30)
        m.hint(vm: "b", at: inside)
        m.update(vms: [vm("a", "default"), vm("b", "default")], networks: [nat, lab])
        XCTAssertEqual(m.position("b"), inside, "the new VM, in its network")
        XCTAssertTrue(try XCTUnwrap(m.frame("default")).contains(try rect(m, "b")), "its frame grew to hold it")
        m.hint(vm: "c", at: inside)
        m.update(vms: [vm("a", "default"), vm("b", "default"), vm("c", "lab")], networks: [nat, lab])
        XCTAssertTrue(try XCTUnwrap(m.frame("lab")).contains(try rect(m, "c")), "a spot outside its network is not used")
    }

    /// This Mac and the Internet stay where they are: they were placed from
    /// the groups' bounds, so moving any network moved the Internet as if it
    /// were tied to it. They can be dragged, and are kept in the layout.
    func testLandmarksStayWhereTheyAre() throws {
        var m = model([vm("a", "default"), vm("c", "lab")])
        let internet = m.internetPosition, mac = m.macPosition
        m.moveNetwork("lab", by: CGSize(width: 300, height: 400))
        m.update(vms: [vm("a", "default"), vm("c", "lab")], networks: [nat, lab])
        XCTAssertEqual(m.internetPosition, internet)
        XCTAssertEqual(m.macPosition, mac)
        m.moveLandmark(.internet, to: CGPoint(x: 10, y: -400))
        XCTAssertEqual(m.internetPosition, CGPoint(x: 10, y: -400))
        XCTAssertEqual(m.layout.internet, CGPoint(x: 10, y: -400), "kept in the layout")
        // A layout saved before they were kept places them once, then keeps them.
        let old = try JSONDecoder().decode(CanvasLayout.self, from: Data(#"{"version":1,"frames":{},"nodes":{}}"#.utf8))
        var n = CanvasModel(layout: old)
        n.update(vms: [vm("a", "default")], networks: [nat])
        XCTAssertNotNil(n.layout.mac)
        XCTAssertNotNil(n.layout.internet)
    }

    func testMovingANetworkMovesItsVMs() throws {
        var m = model([vm("a", "default"), vm("c", "lab")])
        let a = try XCTUnwrap(m.position("a")), c = try XCTUnwrap(m.position("c"))
        let frame = try XCTUnwrap(m.frame("default"))
        m.moveNetwork("default", by: CGSize(width: 0, height: 400))
        XCTAssertEqual(m.frame("default"), frame.offsetBy(dx: 0, dy: 400))
        XCTAssertEqual(m.position("a"), CGPoint(x: a.x, y: a.y + 400))
        XCTAssertEqual(m.position("c"), c, "others stay")
    }

    func testWhatIsGoneIsDropped() {
        var m = model([vm("a", "default"), vm("c", "lab")])
        m.update(vms: [vm("a", "default")], networks: [nat])
        XCTAssertNil(m.position("c"))
        XCTAssertNil(m.frame("lab"))
        XCTAssertNil(m.frame(CanvasModel.outside), "no VM outside: no area")
        XCTAssertEqual(Set(m.layout.nodes.keys), ["a"])
        XCTAssertEqual(Set(m.layout.frames.keys), ["default"])
    }

    func testEdges() {
        let m = model([vm("a", "default"), vm("b", "default", mac: true), vm("c", "lab")])
        let traffic = [VMTraffic(network: "default", from: "a", to: "b", frames: 3, bytes: 300, lastSeen: 2),
                       VMTraffic(network: "default", from: "b", to: "a", frames: 1, bytes: 60, lastSeen: 40),
                       VMTraffic(network: "lab", from: "c", to: "gone", frames: 1, bytes: 60, lastSeen: 1),
                       VMTraffic(network: "default", from: "c", to: "a", frames: 1, bytes: 90, lastSeen: 30)]
        XCTAssertEqual(m.edges(traffic: traffic), [
            .traffic("a", "b", bytes: 360, live: true),
            .traffic("a", "c", bytes: 90, live: false),
            .mac("b"),
            .internet("default"),
        ], "both ways in one edge, VMs not on the canvas left out, an internal network has no way out")
    }

    func testAVMIsReadFromItsSettings() {
        var c = InstanceConfig.defaults(name: "web")
        c.networks = [NetworkAttachment(network: "lab", macAddress: nil)]
        XCTAssertEqual(CanvasVM(config: c, running: true, networks: ["default", "lab"]),
                       CanvasVM(name: "web", network: "lab", running: true, linksToMac: false))
        XCTAssertNil(CanvasVM(config: c, running: false, networks: ["default"]).network, "a network that is gone")
        c.networks = [NetworkAttachment(network: NetworkDefinition.appleNATName, macAddress: nil)]
        XCTAssertNil(CanvasVM(config: c, running: false, networks: ["default"]).network, "Apple's NAT")
        c.networks = []
        c.forwards = [ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)]
        let linked = CanvasVM(config: c, running: false, networks: [])
        XCTAssertNil(linked.network)
        XCTAssertTrue(linked.linksToMac)
    }

    /// A move saved: the VM's network and nothing else, its MAC kept (its
    /// lease on each network goes with the MAC).
    func testAMoveChangesOnlyTheVMsNetwork() {
        var c = InstanceConfig.defaults(name: "web")
        c.networks = [NetworkAttachment(network: "default", macAddress: "02:4d:4f:4e:00:21")]
        c.cpus = 3
        let moved = CanvasModel.config(c, movedTo: "lab")
        XCTAssertEqual(moved.networks, [NetworkAttachment(network: "lab", macAddress: "02:4d:4f:4e:00:21")])
        var rest = moved
        rest.networks = c.networks
        XCTAssertEqual(rest, c, "nothing else changes")
        c.networks = []
        XCTAssertEqual(CanvasModel.config(c, movedTo: "lab").networks, [NetworkAttachment(network: "lab", macAddress: nil)])
    }

    /// ⌘Z puts a layout back: frames, nodes and landmarks where they were.
    func testALayoutIsPutBack() throws {
        var m = model([vm("a", "default"), vm("c", "lab")])
        let before = m.layout
        m.moveNetwork("lab", by: CGSize(width: 300, height: 40))
        m.moveLandmark(.mac, to: CGPoint(x: -900, y: 0))
        XCTAssertNotEqual(m.layout, before)
        m.restore(before)
        XCTAssertEqual(m.layout, before)
    }

    func testTheLayoutIsSavedAndRead() throws {
        let tmp = TempDir()
        let store = CanvasStore(url: tmp.url.appendingPathComponent("canvas.json"))
        XCTAssertEqual(store.load(), CanvasLayout(), "none yet")
        var m = model([vm("a", "default"), vm("c", "lab")])
        m.moveNetwork("lab", by: CGSize(width: 100, height: 50))
        try store.save(m.layout)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        var back = CanvasModel(layout: store.load())
        back.update(vms: [vm("a", "default"), vm("c", "lab")], networks: [nat, lab])
        XCTAssertEqual(back.layout, m.layout, "read back where it was left")
        try Data("{not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), CanvasLayout(), "an unreadable file: start again")
        try Data(#"{"version":99,"frames":{},"nodes":{}}"#.utf8).write(to: store.url)
        XCTAssertEqual(store.load(), CanvasLayout(), "a newer file: start again")
    }

    /// A VM's tile: its distribution's letter and colour, or Apple's mark
    /// for a macOS VM (by what runs in it, not by a distribution's name).
    func testATilesMarkComesFromTheVM() {
        var linux = InstanceConfig.defaults(name: "box")
        linux.distro = "ubuntu"
        XCTAssertEqual(CanvasStyle.tile(for: linux).mark, .letter("U"))
        var mac = InstanceConfig.defaults(name: "mac")
        mac.distro = "my-macos"
        mac.guestOS = .macos
        XCTAssertEqual(CanvasStyle.tile(for: mac).mark, .symbol("apple.logo"))
        XCTAssertEqual(mac.symbol, "apple.logo", "in the list and on its page too")
        XCTAssertEqual(linux.symbol, "server.rack")
        XCTAssertEqual(InstanceConfig.defaults(name: "e", ephemeral: true).symbol, "hourglass")
    }
}
