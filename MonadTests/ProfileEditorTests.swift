//
//  ProfileEditorTests.swift — what the user sees of profiles: the banner over
//  a VM's tab while one is set up, and the editor of custom profiles in
//  Settings › Profiles.
//

import XCTest
@testable import Monad

@MainActor
final class ProfileEditorTests: XCTestCase {
    private let agentic = ProfileConfig(id: "agentic", name: "Agentic", summary: "", steps: [
        .init(id: "base", title: "Base tools", npm: ["x"]),
        .init(id: "node", title: "Node.js LTS", runtime: "nodejs"),
        .init(id: "agents", title: "Coding agents", npm: ["y"]),
    ])

    // MARK: The banner

    func testTheBannerFollowsTheRun() {
        var run = ProfileRun(profile: agentic)
        XCTAssertEqual(ProfileBanner.of([run])?.text, "Agentic: waiting to start")
        run.apply("@@monad step base start")
        run.apply("@@monad step base done")
        run.apply("@@monad step node start")
        let b = ProfileBanner.of([run])
        XCTAssertEqual(b?.text, "Setting up Agentic: Node.js LTS (2 of 3)")
        XCTAssertEqual(b?.kind, .working)
        run.apply("@@monad step node done")
        run.apply("@@monad step agents start")
        run.apply("@@monad step agents done")
        run.apply("@@monad finished")
        run.finish(status: 0)
        XCTAssertEqual(ProfileBanner.of([run]), ProfileBanner(text: "Agentic is set up.", kind: .done))
        var bad = ProfileRun(profile: agentic)
        bad.apply("@@monad step base start")
        bad.apply("@@monad step base failed apt-get install failed")
        XCTAssertEqual(ProfileBanner.of([run, bad]),
                       ProfileBanner(text: "Agentic could not be set up: apt-get install failed", kind: .failed))
        XCTAssertNil(ProfileBanner.of([]))
        for b in [ProfileBanner.of([run]), ProfileBanner.of([bad])] { XCTAssertFalse(b?.text.contains(";") ?? true) }
    }

    /// While it works, the banner shows the latest line the script printed.
    func testTheBannerShowsTheLatestOutput() {
        var run = ProfileRun(profile: agentic)
        run.apply("@@monad step base start")
        XCTAssertNil(ProfileBanner.of([run])?.detail)
        run.apply("› Installing git")
        run.apply("Get:1 http://ports.ubuntu.com noble InRelease")
        XCTAssertEqual(ProfileBanner.of([run])?.detail, "Get:1 http://ports.ubuntu.com noble InRelease")
        run.apply("@@monad step base failed apt-get install failed")
        XCTAssertNil(ProfileBanner.of([run])?.detail, "the reason says it all")
    }

    /// The one being set up wins over finished ones.
    func testTheRunningOneIsShown() {
        var done = ProfileRun(profile: agentic)
        done.apply("@@monad finished")
        done.finish(status: 0)
        var server = ProfileRun(profile: ProfileConfig(id: "server", name: "Server", summary: "",
                                                       steps: [.init(id: "c", title: "Containers", npm: ["z"])]))
        server.apply("@@monad step c start")
        XCTAssertEqual(ProfileBanner.of([done, server])?.text, "Setting up Server: Containers (1 of 1)")
    }

    // MARK: Custom profiles

    private var store: ProfileStore!

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("profile-editor-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        store = ProfileStore(directory: dir)
    }

    func testANewProfileIsEditedAndSaved() throws {
        let m = ProfileEditorModel(store: store, builtIn: [])
        XCTAssertEqual(m.ids, [])
        m.addProfile()
        XCTAssertEqual(m.draft?.id, "profile-1")
        XCTAssertTrue(m.isDirty)
        m.draft?.name = "Rust"
        m.addStep(.packages)
        m.setPackages(0, manager: "apt", "build-essential  curl")
        m.setPackages(0, manager: "dnf", "gcc curl")
        m.setPackages(0, manager: "zypper", "gcc curl")
        m.addStep(.script)
        m.updateStep(1) { $0.script = "curl -fsSL https://sh.rustup.rs | sh -s -- -y\n" }
        m.setCommands(1, "cargo  rustc")
        XCTAssertTrue(m.save())
        let saved = try XCTUnwrap(try store.all().first)
        XCTAssertEqual(saved.steps[0].packages?["apt"], ["build-essential", "curl"])
        XCTAssertEqual(saved.steps[1].commands, ["cargo", "rustc"])
        XCTAssertEqual(saved.steps.map(\.id), ["step-1", "step-2"])
        XCTAssertFalse(m.isDirty)
        XCTAssertEqual(m.packagesText(0, manager: "apt"), "build-essential curl")
        XCTAssertEqual(m.ids, ["profile-1"])
    }

    /// From the New VM sheet: the editor opens on a new profile.
    func testTheEditorCanStartOnANewProfile() throws {
        let m = ProfileEditorModel(store: store, builtIn: [agentic], startingNew: true)
        XCTAssertEqual(m.draft?.id, "profile-1")
        XCTAssertNil(m.saved)
        XCTAssertTrue(m.canChangeID)
        m.draft?.name = "Tools"
        m.addStep(.npm)
        m.setNPM(0, "typescript")
        XCTAssertTrue(m.save())
        XCTAssertEqual(m.saved?.id, "profile-1")
    }

    func testInvalidProfilesAreNotSaved() {
        let m = ProfileEditorModel(store: store, builtIn: [agentic])
        m.addProfile()
        XCTAssertFalse(m.save(), "no steps")
        XCTAssertNotNil(m.errorMessage)
        m.addStep(.npm)
        m.setNPM(0, "left-pad; rm -rf /")
        XCTAssertFalse(m.save())
        m.setNPM(0, "left-pad")
        m.draft?.id = "agentic"
        XCTAssertFalse(m.save(), "a new profile cannot take a built-in's id")
        m.draft?.id = "pads"
        XCTAssertTrue(m.save())
        XCTAssertFalse(m.canChangeID, "VMs refer to profiles by id")
    }

    func testStepsMoveAndGo() throws {
        let m = ProfileEditorModel(store: store, builtIn: [])
        m.addProfile()
        m.addStep(.npm)
        m.addStep(.node)
        m.addStep(.script)
        XCTAssertEqual(m.draft?.steps.map(\.kind), [.npm, .runtime, .script])
        XCTAssertEqual(m.draft?.steps[1].runtime, "nodejs")
        m.moveStep(2, up: true)
        XCTAssertEqual(m.draft?.steps.map(\.kind), [.npm, .script, .runtime])
        m.removeStep(0)
        m.removeStep(9) // harmless
        XCTAssertEqual(m.draft?.steps.map(\.kind), [.script, .runtime])
    }

    func testDeletingAndReverting() throws {
        try store.save(ProfileConfig(id: "mine", name: "Mine", summary: "", steps: [.init(id: "n", title: "N", npm: ["x"])]))
        let m = ProfileEditorModel(store: store, builtIn: [])
        XCTAssertEqual(m.draft?.id, "mine")
        m.draft?.name = "Changed"
        m.revert()
        XCTAssertEqual(m.draft?.name, "Mine")
        XCTAssertTrue(m.delete())
        XCTAssertEqual(m.ids, [])
        XCTAssertNil(m.draft)
    }

    // MARK: Built-ins

    func testBuiltInsCanBeViewedEditedAndRestored() throws {
        let m = ProfileEditorModel(store: store, builtIn: [agentic])
        XCTAssertEqual(m.builtInIDs, ["agentic"])
        m.select("agentic")
        XCTAssertEqual(m.draft?.name, "Agentic", "shown as shipped")
        XCTAssertTrue(m.isBuiltIn)
        XCTAssertFalse(m.isEdited)
        XCTAssertFalse(m.canChangeID)
        XCTAssertFalse(m.canDelete, "built-ins are restored, not deleted")
        XCTAssertEqual(m.npmText(0), "x")
        m.addStep(.script)
        m.updateStep(3) { $0.script = "echo extra\n" }
        XCTAssertTrue(m.save())
        XCTAssertEqual(try store.all().map(\.id), ["agentic"], "saved as the user's version")
        XCTAssertTrue(m.isEdited)
        XCTAssertEqual(m.draft?.steps.count, 4)
        XCTAssertEqual(m.ids, [], "not listed among the user's own")
        m.restoreDefault()
        XCTAssertFalse(m.isEdited)
        XCTAssertEqual(m.draft?.steps.count, 3)
        XCTAssertEqual(try store.all(), [])
    }
}
