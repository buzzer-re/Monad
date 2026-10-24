//
//  VMGroupsTests.swift — groups in the Virtual Machines list: sections in
//  the user's order (groups only named by a VM's settings after them, the
//  VMs in no group last), collapsed or not, renamed with their VMs, and
//  kept in a file read with care.
//

import XCTest
@testable import Monad

final class VMGroupsTests: XCTestCase {
    private func vm(_ name: String, _ group: String?) -> InstanceConfig {
        var c = InstanceConfig.defaults(name: name)
        c.group = group
        return c
    }

    func testSectionsFollowTheSavedGroupsThenTheRest() {
        let vms = [vm("a", "coding"), vm("b", nil), vm("c", "analysis"), vm("d", "coding"), vm("e", "zeta")]
        let saved = VMGroups(groups: [.init(name: "analysis"), .init(name: "coding", collapsed: true), .init(name: "empty")])
        let sections = saved.sections(vms.map(\.name), configs: Dictionary(uniqueKeysWithValues: vms.map { ($0.name, $0) }))
        XCTAssertEqual(sections.map(\.group), ["analysis", "coding", "empty", "zeta", nil])
        XCTAssertEqual(sections.map(\.vms), [["c"], ["a", "d"], [], ["e"], ["b"]], "VMs in the list's order")
        XCTAssertEqual(sections.map(\.collapsed), [false, true, false, false, false])
    }

    func testNoGroupsNoHeaders() {
        let sections = VMGroups().sections(["a", "b"], configs: ["a": vm("a", nil), "b": vm("b", nil)])
        XCTAssertEqual(sections.map(\.group), [nil])
        XCTAssertEqual(sections.first?.vms, ["a", "b"])
    }

    func testGroupsAreMadeRenamedAndRemoved() throws {
        var g = VMGroups()
        try g.add("coding")
        XCTAssertThrowsError(try g.add("Coding"), "names differ in more than case")
        XCTAssertThrowsError(try g.add("no spaces"))
        try g.add("agents")
        g.toggle("coding")
        XCTAssertEqual(g.groups.map(\.collapsed), [true, false])
        let configs = [vm("a", "coding"), vm("b", "agents"), vm("c", "coding")]
        let changed = try g.rename("coding", to: "dev", configs: configs)
        XCTAssertEqual(g.groups.map(\.name), ["dev", "agents"])
        XCTAssertEqual(g.groups.first?.collapsed, true, "kept collapsed")
        XCTAssertEqual(changed.map(\.name), ["a", "c"])
        XCTAssertEqual(Set(changed.map(\.group)), ["dev"])
        XCTAssertThrowsError(try g.rename("dev", to: "agents", configs: configs), "taken")
        let freed = g.remove("agents", configs: configs)
        XCTAssertEqual(freed.map(\.name), ["b"])
        XCTAssertNil(freed.first?.group)
        XCTAssertEqual(g.groups.map(\.name), ["dev"])
        g.move("dev", to: 0)
        XCTAssertEqual(g.groups.map(\.name), ["dev"])
    }

    func testTheFileIsReadWithCare() throws {
        let tmp = TempDir()
        let store = VMGroupStore(url: tmp.url.appendingPathComponent("vm-groups.json"))
        XCTAssertEqual(store.load(), VMGroups())
        var g = VMGroups()
        try g.add("coding")
        try g.add("analysis")
        g.toggle("analysis")
        try store.save(g)
        XCTAssertEqual(store.load(), g)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        try Data(#"{"version":1,"groups":[{"name":"ok"},{"name":"bad name"},{"name":"OK"}]}"#.utf8).write(to: store.url)
        XCTAssertEqual(store.load().groups.map(\.name), ["ok"], "bad and repeated names left out")
        try Data("nope".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), VMGroups())
    }
}
