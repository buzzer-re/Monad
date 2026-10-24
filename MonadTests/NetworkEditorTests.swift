//
//  NetworkEditorTests.swift — the networks editor's model: listing, new
//  networks, saving only what is valid.
//

import XCTest
@testable import Monad

@MainActor
final class NetworkEditorTests: XCTestCase {
    private var store: NetworkStore!

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("editor-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        store = NetworkStore(directory: dir)
    }

    func testListsNetworksAndSelectsTheDefault() {
        let m = NetworkEditorModel(store: store)
        XCTAssertEqual(m.names, ["default"])
        XCTAssertEqual(m.draft?.name, "default")
        XCTAssertFalse(m.isDirty)
        XCTAssertFalse(m.canDelete)
    }

    /// The New Network sheet (Settings › Networks' "+" and the canvas)
    /// opens on a new network; the pane that opened it lists it once saved.
    func testTheSheetStartsOnANewNetworkAndThePaneListsIt() {
        let sheet = NetworkEditorModel(store: store, startingNew: true)
        XCTAssertEqual(sheet.draft?.name, "network-1")
        XCTAssertTrue(sheet.canRename)
        XCTAssertNil(sheet.saved)
        let pane = NetworkEditorModel(store: store)
        XCTAssertTrue(sheet.save())
        XCTAssertEqual(pane.names, ["default"])
        pane.reload(selecting: "network-1")
        XCTAssertEqual(pane.names, ["default", "network-1"])
        XCTAssertEqual(pane.saved?.name, "network-1", "shown in the pane")
    }

    func testANewNetworkGetsAFreeNameAndSubnet() throws {
        let m = NetworkEditorModel(store: store)
        m.addNetwork()
        XCTAssertEqual(m.draft?.name, "network-1")
        XCTAssertEqual(m.draft?.subnet, "10.78.0.0/24")
        XCTAssertEqual(m.draft?.kind, .nat)
        XCTAssertTrue(m.isDirty)
        XCTAssertTrue(m.save())
        m.addNetwork()
        XCTAssertEqual(m.draft?.name, "network-2")
        XCTAssertEqual(m.draft?.subnet, "10.79.0.0/24")
        XCTAssertTrue(m.save())
        XCTAssertEqual(m.names, ["default", "network-1", "network-2"])
    }

    func testInvalidNetworksAreNotSaved() throws {
        let m = NetworkEditorModel(store: store)
        m.addNetwork()
        m.draft?.subnet = "8.8.8.0/24"
        XCTAssertFalse(m.save())
        XCTAssertNotNil(m.errorMessage)
        XCTAssertTrue(m.isDirty)
        XCTAssertEqual(m.names, ["default"])
    }

    func testRevertAndSwitchingNetworks() throws {
        try store.save(NetworkDefinition(name: "lab", kind: .internal, subnet: "192.168.50.0/24"))
        let m = NetworkEditorModel(store: store)
        m.draft?.leaseSeconds = 600
        XCTAssertTrue(m.isDirty)
        m.revert()
        XCTAssertFalse(m.isDirty)
        XCTAssertNil(m.draft?.leaseSeconds)
        m.select("lab")
        XCTAssertEqual(m.draft?.kind, .internal)
        XCTAssertTrue(m.canDelete)
    }

    func testDeletingANetwork() throws {
        try store.save(NetworkDefinition(name: "lab", kind: .nat, subnet: "192.168.50.0/24"))
        let m = NetworkEditorModel(store: store)
        m.select("lab")
        XCTAssertTrue(m.delete())
        XCTAssertEqual(m.names, ["default"])
        XCTAssertEqual(m.draft?.name, "default")
        XCTAssertFalse(m.delete(), "the default network stays")
        XCTAssertEqual(m.names, ["default"])
    }

    func testRenamingIsNotPossibleAfterSaving() {
        let m = NetworkEditorModel(store: store)
        XCTAssertFalse(m.canRename)
        m.addNetwork()
        XCTAssertTrue(m.canRename)
        m.draft?.name = "lab"
        XCTAssertTrue(m.save())
        XCTAssertFalse(m.canRename, "VMs refer to networks by name")
        m.addNetwork()
        m.draft?.name = "lab"
        XCTAssertFalse(m.save(), "names are unique")
    }
}
