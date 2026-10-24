//
//  NetworkDefinitionTests.swift — Monad's networks as configuration: the
//  model, its validation, the netd command it becomes, and the store.
//

import XCTest
@testable import Monad

final class NetworkDefinitionTests: XCTestCase {
    private func nat(_ name: String = "lab", subnet: String = "10.80.0.0/24") -> NetworkDefinition {
        NetworkDefinition(name: name, kind: .nat, subnet: subnet)
    }

    // MARK: Model

    func testTheDefaultNetwork() throws {
        let d = NetworkDefinition.builtInDefault
        XCTAssertEqual(d.name, "default")
        XCTAssertEqual(d.kind, .nat)
        XCTAssertEqual(d.subnet, "10.77.0.0/24")
        XCTAssertNoThrow(try d.validate())
    }

    func testJSONRoundTripAndKinds() throws {
        var n = nat()
        n.kind = .hostOnly
        n.leaseSeconds = 600
        let data = try n.encoded()
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"host-only\""))
        XCTAssertEqual(try NetworkDefinition.decode(data), n)
        XCTAssertThrowsError(try NetworkDefinition.decode(Data(#"{"version": 99, "name": "x"}"#.utf8)))
    }

    /// Networks used to carry a firewall; it is each VM's now, and an old
    /// file still loads.
    func testFilesWithTheOldNetworkFirewallStillLoad() throws {
        let old = #"{"version": 1, "name": "lab", "kind": "nat", "subnet": "10.80.0.0/24","#
            + #" "firewall": {"allowlist": true, "allowLAN": false, "rules": []}}"#
        XCTAssertEqual(try NetworkDefinition.decode(Data(old.utf8)), nat())
        XCTAssertFalse(String(decoding: try nat().encoded(), as: UTF8.self).contains("firewall"))
    }

    // MARK: Validation

    func testNames() {
        for bad in ["", "Lab", "lab net", "-lab", "apple-nat", String(repeating: "a", count: 33), "lab/1"] {
            XCTAssertThrowsError(try nat(bad).validate(), bad)
        }
        XCTAssertNoThrow(try nat("lab-2").validate())
    }

    func testSubnets() {
        for bad in ["8.8.8.0/24", "10.80.0.1/24", "10.80.0.0/31", "10.80.0.0/7", "10.80.0.0", "10.80.0/24",
                    "10.080.0.0/24", "172.32.0.0/16", "192.169.0.0/16", "10.80.0.0/24 "] {
            XCTAssertThrowsError(try nat(subnet: bad).validate(), bad)
        }
        for good in ["10.0.0.0/8", "172.16.0.0/12", "172.31.5.0/24", "192.168.100.0/30"] {
            XCTAssertNoThrow(try nat(subnet: good).validate(), good)
        }
    }

    func testLease() {
        var n = nat()
        n.leaseSeconds = 30
        XCTAssertThrowsError(try n.validate())
        n.leaseSeconds = 3600
        XCTAssertNoThrow(try n.validate())
    }

    // MARK: What netd is told

    func testNetdCommands() {
        var n = nat()
        n.leaseSeconds = 600
        XCTAssertEqual(n.netdNetworkCommand, "network nat 10.80.0.0/24 lease=600 peers=0")
        var i = NetworkDefinition(name: "iso", kind: .internal, subnet: "10.81.0.0/24")
        XCTAssertEqual(i.netdNetworkCommand, "network internal 10.81.0.0/24 peers=1")
        i.kind = .none
        XCTAssertEqual(i.netdNetworkCommand, "network none 10.81.0.0/24 peers=1")
    }

    /// VMs are kept apart unless the network says otherwise: off for the
    /// default network, NAT and host-only, on where nothing leaves (F-02).
    func testVMsReachEachOtherOnlyWhereChosen() throws {
        XCTAssertFalse(NetworkDefinition.builtInDefault.vmsReachEachOther)
        XCTAssertFalse(NetworkDefinition(name: "h", kind: .hostOnly, subnet: "10.82.0.0/24").vmsReachEachOther)
        XCTAssertTrue(NetworkDefinition(name: "i", kind: .internal, subnet: "10.83.0.0/24").vmsReachEachOther)
        var n = nat()
        n.vmsReachEachOther = true
        XCTAssertEqual(n.netdNetworkCommand, "network nat 10.80.0.0/24 peers=1")
        XCTAssertEqual(try NetworkDefinition.decode(n.encoded()), n)
        XCTAssertTrue(String(decoding: try n.encoded(), as: UTF8.self).contains("\"vmsReachEachOther\" : true"))
        // A file from before the switch gets its kind's default.
        let old = #"{"version": 1, "name": "lab", "kind": "internal", "subnet": "10.80.0.0/24"}"#
        XCTAssertTrue(try NetworkDefinition.decode(Data(old.utf8)).vmsReachEachOther)
        XCTAssertFalse(String(decoding: try nat().encoded(), as: UTF8.self).contains("vmsReachEachOther"))
    }

    /// Nothing leaves a host-only network, lookups included, unless the
    /// network says its VMs may look names up through the Mac (F-10).
    func testHostOnlyNetworksLookUpThroughTheMacOnlyWhenChosen() throws {
        var h = NetworkDefinition(name: "h", kind: .hostOnly, subnet: "10.82.0.0/24")
        XCTAssertFalse(h.lookupsThroughTheMac)
        XCTAssertEqual(h.netdNetworkCommand, "network host-only 10.82.0.0/24 peers=0 dns=0")
        h.lookupsThroughTheMac = true
        XCTAssertEqual(h.netdNetworkCommand, "network host-only 10.82.0.0/24 peers=0 dns=1")
        XCTAssertEqual(try NetworkDefinition.decode(h.encoded()), h)
        XCTAssertEqual(nat().netdNetworkCommand, "network nat 10.80.0.0/24 peers=0")
    }

    /// Everything a valid definition renders is accepted by netd's own parser.
    func testNetdAcceptsWhatTheDefinitionsRender() throws {
        let d = try XCTUnwrap(mnd_netd_create())
        defer { mnd_netd_destroy(d) }
        let ctl = try XCTUnwrap(mnd_ctl_create(d, nil, nil))
        defer { mnd_ctl_destroy(ctl) }
        func run(_ line: String) -> String {
            var out = [CChar](repeating: 0, count: 256)
            mnd_ctl_command(ctl, line, &out, out.count)
            return String(cString: out)
        }
        var n = nat()
        n.leaseSeconds = 3600
        XCTAssertNoThrow(try n.validate())
        XCTAssertEqual(run(n.netdNetworkCommand), "ok 0")
        for kind in NetworkDefinition.Kind.allCases {
            let other = NetworkDefinition(name: "k", kind: kind, subnet: "172.20.0.0/16", leaseSeconds: 60)
            XCTAssertTrue(run(other.netdNetworkCommand).hasPrefix("ok "), kind.rawValue)
        }
        XCTAssertTrue(run(NetworkDefinition.builtInDefault.netdNetworkCommand).hasPrefix("ok "))
    }

    // MARK: Store

    private func tempStore() throws -> NetworkStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("networks-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return NetworkStore(directory: dir)
    }

    func testTheStoreCreatesTheDefaultAndKeepsFilesPrivate() throws {
        let store = try tempStore()
        XCTAssertEqual(try store.all().map(\.name), ["default"])
        let file = store.directory.appendingPathComponent("default.json")
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        let dirPerms = try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerms, 0o700)
    }

    func testSaveLoadDelete() throws {
        let store = try tempStore()
        try store.save(nat("lab"))
        try store.save(nat("alpha", subnet: "10.90.0.0/24"))
        XCTAssertEqual(try store.all().map(\.name), ["alpha", "default", "lab"])
        XCTAssertEqual(try store.network(named: "lab"), nat("lab"))
        XCTAssertThrowsError(try store.save(nat("bad", subnet: "8.8.8.0/24")))
        XCTAssertNil(try store.network(named: "bad"))
        try store.delete(named: "lab")
        XCTAssertNil(try store.network(named: "lab"))
        XCTAssertThrowsError(try store.delete(named: "default")) // edited, never deleted
    }

    func testBrokenFilesAreSkipped() throws {
        let store = try tempStore()
        _ = try store.all()
        try Data("{not json".utf8).write(to: store.directory.appendingPathComponent("broken.json"))
        var invalid = nat("sneaky", subnet: "8.8.8.0/24")
        invalid.name = "sneaky"
        try invalid.encoded().write(to: store.directory.appendingPathComponent("sneaky.json"))
        // A file whose name differs from its content is not trusted either.
        try nat("other").encoded().write(to: store.directory.appendingPathComponent("renamed.json"))
        XCTAssertEqual(try store.all().map(\.name), ["default"])
    }
}
