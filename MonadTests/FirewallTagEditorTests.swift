//
//  FirewallTagEditorTests.swift — the firewall tags editor's model: listing,
//  new tags, editing rules as text, the VMs that carry a tag, saving only
//  what is valid.
//

import XCTest
@testable import Monad

/// VMs as MonadHost reports them; updates recorded, and refused for some.
@MainActor
private final class FakeMembers: FirewallTagMembers {
    var vmConfigs: [InstanceConfig]
    var refuse: Set<String> = []
    private(set) var updates: [String] = []

    init(_ names: [String]) {
        vmConfigs = names.map { InstanceConfig.defaults(name: $0) }
    }

    func update(_ config: InstanceConfig) async throws {
        if refuse.contains(config.name) { throw TestError("\(config.name) is busy") }
        updates.append(config.name)
        if let i = vmConfigs.firstIndex(where: { $0.name == config.name }) { vmConfigs[i] = config }
    }

    func tags(of vm: String) -> [String] { vmConfigs.first { $0.name == vm }?.firewall.tags ?? [] }
}

@MainActor
final class FirewallTagEditorTests: XCTestCase {
    private var store: FirewallTagStore!

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tag-editor-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        store = FirewallTagStore(directory: dir)
    }

    func testStartsEmptyAndANewTagGetsAFreeName() async throws {
        let m = FirewallTagEditorModel(store: store)
        XCTAssertEqual(m.names, [])
        XCTAssertNil(m.draftName)
        XCTAssertFalse(m.isDirty)
        m.addTag()
        XCTAssertEqual(m.draftName, "tag-1")
        XCTAssertTrue(m.isDirty)
        XCTAssertTrue(m.canRename)
        do {
            let done = await m.save()
            XCTAssertTrue(done)
        }
        m.addTag()
        XCTAssertEqual(m.draftName, "tag-2")
        m.draftName = "web"
        do {
            let done = await m.save()
            XCTAssertTrue(done)
        }
        XCTAssertEqual(m.names, ["tag-1", "web"])
        XCTAssertFalse(m.canRename, "VMs refer to tags by name")
        m.addTag()
        m.draftName = "web"
        do {
            let done = await m.save()
            XCTAssertFalse(done, "names are unique")
        }
        XCTAssertNotNil(m.errorMessage)
        m.draftName = "WEB"
        do {
            let done = await m.save()
            XCTAssertFalse(done, "whatever the case")
        }
        m.draftName = "Python"
        do {
            let done = await m.save()
            XCTAssertTrue(done)
        }
        XCTAssertEqual(m.names, ["Python", "tag-1", "web"])
    }

    func testRulesAreEditedAndValidatedOnSave() async throws {
        try store.save(FirewallTag(name: "web", rules: []))
        let m = FirewallTagEditorModel(store: store)
        XCTAssertEqual(m.draftName, "web", "the first tag is selected")
        m.rules.add()
        m.rules.update(0) { $0.target = "*.github.com" }
        m.rules.setPorts(0, "443")
        XCTAssertTrue(m.isDirty)
        do {
            let done = await m.save()
            XCTAssertTrue(done)
        }
        XCTAssertEqual(try store.tag(named: "web")?.rules,
                       [FirewallRule(action: .allow, proto: .tcp, target: "*.github.com", ports: 443...443)])
        XCTAssertFalse(m.isDirty)
        // Invalid: kept as a draft with the reason, nothing saved.
        m.rules.update(0) { $0.target = "not a host" }
        do {
            let done = await m.save()
            XCTAssertFalse(done)
        }
        XCTAssertNotNil(m.errorMessage)
        XCTAssertTrue(m.isDirty)
        XCTAssertEqual(try store.tag(named: "web")?.rules.first?.target, "*.github.com")
        m.rules.update(0) { $0.target = "10.0.0.0/8" }
        m.rules.setPorts(0, "nope")
        do {
            let done = await m.save()
            XCTAssertFalse(done)
        }
        m.rules.setPorts(0, "")
        do {
            let done = await m.save()
            XCTAssertTrue(done)
        }
        XCTAssertNil(m.errorMessage)
        m.revert()
        XCTAssertFalse(m.isDirty)
    }

    func testSwitchingAndDeleting() async throws {
        try store.save(FirewallTag(name: "a", rules: []))
        try store.save(FirewallTag(name: "b", rules: [FirewallRule(action: .deny, proto: .any, target: "1.2.3.4/32")]))
        let m = FirewallTagEditorModel(store: store)
        m.select("b")
        XCTAssertEqual(m.rules.rules.count, 1)
        XCTAssertTrue(m.canDelete)
        do {
            let done = await m.delete()
            XCTAssertTrue(done)
        }
        XCTAssertEqual(m.names, ["a"])
        XCTAssertEqual(m.draftName, "a")
        m.addTag()
        XCTAssertFalse(m.canDelete, "not saved yet")
        m.revert()
        XCTAssertEqual(m.draftName, "a", "an unsaved new tag is dropped")
    }

    func testATagCanTurnOnMonitorMode() async throws {
        try store.save(FirewallTag(name: "web", rules: []))
        let m = FirewallTagEditorModel(store: store)
        XCTAssertFalse(m.monitor)
        m.monitor = true
        XCTAssertTrue(m.isDirty)
        let ok = await m.save()
        XCTAssertTrue(ok)
        XCTAssertEqual(try store.tag(named: "web")?.monitor, true)
        XCTAssertFalse(m.isDirty)
        m.addTag()
        XCTAssertFalse(m.monitor, "a new tag starts without it")
    }

    // MARK: VMs

    func testTheVMsATagGoesOnAreChosenWithIt() async throws {
        let vms = FakeMembers(["box", "dev", "web"])
        vms.vmConfigs[1].firewall.tags = ["other"]
        let m = FirewallTagEditorModel(store: store, members: vms)
        m.addTag()
        m.draftName = "Ads"
        XCTAssertEqual(m.vms.map(\.name), ["box", "dev", "web"])
        XCTAssertEqual(m.selectedVMs, [])
        m.setVM("dev", selected: true)
        m.setVM("web", selected: true)
        XCTAssertTrue(m.isDirty)
        let ok = await m.save()
        XCTAssertTrue(ok)
        XCTAssertEqual(vms.tags(of: "dev"), ["other", "Ads"], "added after the VM's other tags")
        XCTAssertEqual(vms.tags(of: "web"), ["Ads"])
        XCTAssertEqual(vms.tags(of: "box"), [])
        XCTAssertFalse(m.isDirty)
        XCTAssertEqual(m.selectedVMs, ["dev", "web"])
        // Taken off one VM: only that VM changes.
        m.setVM("web", selected: false)
        let ok2 = await m.save()
        XCTAssertTrue(ok2)
        XCTAssertEqual(vms.tags(of: "web"), [])
        XCTAssertEqual(vms.updates, ["dev", "web", "web"])
    }

    func testAVMThatRefusesIsReported() async throws {
        let vms = FakeMembers(["box", "dev"])
        vms.refuse = ["dev"]
        let m = FirewallTagEditorModel(store: store, members: vms)
        m.addTag()
        m.setVM("box", selected: true)
        m.setVM("dev", selected: true)
        let ok = await m.save()
        XCTAssertFalse(ok)
        XCTAssertTrue(m.errorMessage?.contains("dev") == true, m.errorMessage ?? "")
        XCTAssertEqual(try store.all().map(\.name), ["tag-1"], "the tag itself is saved")
        XCTAssertEqual(vms.tags(of: "box"), ["tag-1"])
        XCTAssertTrue(m.isDirty, "dev is still to do")
        vms.refuse = []
        let ok2 = await m.save()
        XCTAssertTrue(ok2)
        XCTAssertEqual(vms.tags(of: "dev"), ["tag-1"])
    }

    func testDeletingATagTakesItOffItsVMs() async throws {
        let vms = FakeMembers(["box"])
        vms.vmConfigs[0].firewall.tags = ["a", "b"]
        try store.save(FirewallTag(name: "a", rules: []))
        let m = FirewallTagEditorModel(store: store, members: vms)
        XCTAssertEqual(m.selectedVMs, ["box"])
        let ok = await m.delete()
        XCTAssertTrue(ok)
        XCTAssertEqual(vms.tags(of: "box"), ["b"])
    }

    func testEachVMSaysWhetherItsFirewallIsInEffect() {
        let vms = FakeMembers(["box", "old"])
        vms.vmConfigs[1].networks = [NetworkAttachment(network: "nat", macAddress: nil)]
        let m = FirewallTagEditorModel(store: store, members: vms, networks: { [.builtInDefault] })
        XCTAssertEqual(m.vms.map(\.effect), [.active, .appleNAT])
    }
}
