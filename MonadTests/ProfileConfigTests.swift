//
//  ProfileConfigTests.swift — profiles as data: the model, its validation,
//  the built-in profiles, and the store for the user's own.
//

import XCTest
@testable import Monad

final class ProfileConfigTests: XCTestCase {
    private typealias Step = ProfileConfig.Step

    private func profile(_ steps: [Step], id: String = "mine") -> ProfileConfig {
        ProfileConfig(id: id, name: "Mine", summary: "Things I want.", steps: steps)
    }

    private let tools = Step(id: "tools", title: "Tools", packages: ["apt": ["git"], "dnf": ["git"], "zypper": ["git"]])

    // MARK: Built-ins

    func testTheBuiltInProfiles() throws {
        let catalog = try ProfileCatalog.bundled()
        XCTAssertEqual(catalog.builtIn.map(\.id), ["agentic", "server"])
        for p in catalog.builtIn {
            XCTAssertNoThrow(try p.validate(runtimes: ["nodejs"]), p.id)
            for manager in ["apt", "dnf", "zypper"] { XCTAssertTrue(p.supports(packageManager: manager), "\(p.id) on \(manager)") }
        }
        let agentic = try XCTUnwrap(catalog.profile("agentic"))
        XCTAssertEqual(agentic.steps.map(\.kind), [.packages, .runtime, .npm, .script])
        XCTAssertEqual(agentic.steps[1].runtime, "nodejs")
        XCTAssertEqual(agentic.steps[2].npm, ["bun", "@anthropic-ai/claude-code", "@openai/codex",
                                              "@mariozechner/pi-coding-agent", "@oh-my-pi/pi-coding-agent"])
        XCTAssertEqual(agentic.steps[2].commands, ["bun", "claude", "codex", "pi", "omp"])
        XCTAssertEqual(agentic.steps[3].id, "herdr")
        XCTAssertEqual(agentic.steps[3].commands, ["herdr"])
        let server = try XCTUnwrap(catalog.profile("server"))
        XCTAssertEqual(server.steps.map(\.id), ["containers", "nerdctl", "services", "rootless"])
        XCTAssertEqual(server.steps.map(\.kind), [.packages, .script, .script, .script])
        XCTAssertEqual(server.steps[0].commands, ["podman", "buildah", "docker", "nginx"])
        XCTAssertEqual(server.steps[1].commands, ["nerdctl"])
        let pkgs = try XCTUnwrap(server.steps[0].packages)
        // Docker by each distro's name for it; Compose v2 is docker-compose-v2 on Ubuntu, docker-compose on Debian.
        // Rootless nerdctl: newuidmap (uidmap) and the user's D-Bus (Debian and Ubuntu split them out).
        XCTAssertEqual(pkgs["apt"], ["podman", "buildah", "docker.io", "docker-compose-v2|docker-compose", "nginx",
                                     "uidmap", "dbus-user-session"])
        XCTAssertEqual(pkgs["dnf"], ["podman", "buildah", "moby-engine", "docker-compose", "nginx"])
        XCTAssertEqual(pkgs["zypper"], ["podman", "buildah", "docker", "docker-compose", "nginx"])
        for list in pkgs.values { XCTAssertFalse(list.contains("podman-docker"), "its docker shim would hide Docker's") }
    }

    // MARK: Validation

    func testAStepIsExactlyOneThing() {
        XCTAssertNoThrow(try profile([tools]).validate(runtimes: []))
        XCTAssertThrowsError(try profile([Step(id: "none", title: "Nothing")]).validate(runtimes: []))
        XCTAssertThrowsError(try profile([Step(id: "two", title: "Two", npm: ["left-pad"], script: "true")]).validate(runtimes: []))
        XCTAssertThrowsError(try profile([]).validate(runtimes: []), "at least one step")
        XCTAssertThrowsError(try profile([tools, tools]).validate(runtimes: []), "step ids are unique")
        XCTAssertThrowsError(try profile([Step(id: "rt", title: "Rust", runtime: "rust")]).validate(runtimes: ["nodejs"]))
        XCTAssertNoThrow(try profile([Step(id: "rt", title: "Node", runtime: "nodejs")]).validate(runtimes: ["nodejs"]))
    }

    /// Names end up in a shell script: nothing that could break out of it.
    func testNamesCannotEscapeTheScript() {
        for bad in ["git; rm -rf /", "$(id)", "a b", "", "`x`", "-y", "pkg\nother"] {
            XCTAssertThrowsError(try profile([Step(id: "p", title: "P", packages: ["apt": [bad]])]).validate(runtimes: []), bad)
            XCTAssertThrowsError(try profile([Step(id: "n", title: "N", npm: [bad])]).validate(runtimes: []), bad)
            XCTAssertThrowsError(try profile([Step(id: "c", title: "C", npm: ["x"], commands: [bad])]).validate(runtimes: []), bad)
        }
        for bad in ["a|", "|a", "a||b", "a|b c"] {
            XCTAssertThrowsError(try profile([Step(id: "p", title: "P", packages: ["apt": [bad]])]).validate(runtimes: []), bad)
        }
        for good in ["build-essential", "gcc-c++", "libstdc++6", "python3.12", "g++", "perl-base:arm64",
                     "docker-compose-v2|docker-compose"] {
            XCTAssertNoThrow(try profile([Step(id: "p", title: "P", packages: ["apt": [good]])]).validate(runtimes: []), good)
        }
        for good in ["left-pad", "@scope/pkg", "@anthropic-ai/claude-code", "typescript@5.6.3", "@a/b@1.0.0-beta.1"] {
            XCTAssertNoThrow(try profile([Step(id: "n", title: "N", npm: [good])]).validate(runtimes: []), good)
        }
        XCTAssertThrowsError(try profile([Step(id: "p", title: "P", packages: ["pacman": ["git"]])]).validate(runtimes: []),
                             "known package managers only")
        XCTAssertThrowsError(try profile([Step(id: "Bad Id", title: "P", npm: ["x"])]).validate(runtimes: []))
        XCTAssertThrowsError(try profile([Step(id: "s", title: "S", script: String(repeating: "x", count: 70_000))])
            .validate(runtimes: []), "scripts are bounded")
        XCTAssertThrowsError(try profile([Step(id: "s", title: "S", script: "a\u{0}b")]).validate(runtimes: []))
        XCTAssertThrowsError(try profile([tools], id: "Bad").validate(runtimes: []))
        var unnamed = profile([tools])
        unnamed.name = ""
        XCTAssertThrowsError(try unnamed.validate(runtimes: []))
    }

    func testAProfileSaysWhichDistrosItSuits() {
        let aptOnly = profile([Step(id: "p", title: "P", packages: ["apt": ["git"]])])
        XCTAssertTrue(aptOnly.supports(packageManager: "apt"))
        XCTAssertFalse(aptOnly.supports(packageManager: "zypper"))
        XCTAssertTrue(profile([Step(id: "n", title: "N", npm: ["x"])]).supports(packageManager: "zypper"))
    }

    func testFutureSchemasAreRefused() {
        XCTAssertThrowsError(try ProfileConfig.decode(Data(#"{"schema": 9, "id": "x"}"#.utf8)))
    }

    // MARK: The user's profiles

    private func tempStore() -> ProfileStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return ProfileStore(directory: dir)
    }

    func testTheStoreKeepsCustomProfilesPrivate() throws {
        let store = tempStore()
        XCTAssertEqual(try store.all(), [])
        try store.save(profile([tools]))
        XCTAssertEqual(try store.all().map(\.id), ["mine"])
        let file = store.directory.appendingPathComponent("mine.profile.json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertThrowsError(try store.save(profile([], id: "empty")))
        try Data("{broken".utf8).write(to: store.directory.appendingPathComponent("broken.profile.json"))
        try profile([tools], id: "other").encoded().write(to: store.directory.appendingPathComponent("renamed.profile.json"))
        XCTAssertEqual(try store.all().map(\.id), ["mine"], "broken and renamed files are skipped")
        try store.delete(id: "mine")
        XCTAssertEqual(try store.all(), [])
    }

    /// A built-in the user edited is saved under its id and used instead of
    /// the shipped one, until restored.
    func testAnEditedBuiltInReplacesTheShippedOne() throws {
        let store = tempStore()
        try store.save(profile([tools], id: "agentic"))
        try store.save(profile([tools], id: "mine"))
        let catalog = try ProfileCatalog.bundled(custom: store)
        XCTAssertEqual(catalog.all.map(\.id), ["agentic", "server", "mine"])
        XCTAssertEqual(catalog.profile("agentic")?.name, "Mine", "the user's version")
        XCTAssertEqual(catalog.shipped("agentic")?.name, "Agentic")
        XCTAssertTrue(catalog.isBuiltIn("agentic"))
        XCTAssertTrue(catalog.isEdited("agentic"))
        XCTAssertFalse(catalog.isEdited("server"))
        XCTAssertFalse(catalog.isBuiltIn("mine"))
    }
}
