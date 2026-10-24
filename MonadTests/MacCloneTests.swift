//
//  MacCloneTests.swift — a copy of a stopped macOS VM: its disk and
//  platform files cloned (APFS, so it takes no room until it changes),
//  the same account and keys, and a machine identifier of its own (two
//  Macs with one identifier cannot both run). What reaches the Mac is not
//  copied unless asked again: shares, bridges, host commands, Mac-side
//  forwards, an agent role.
//

import Virtualization
import XCTest
@testable import Monad

@MainActor
final class MacCloneTests: XCTestCase {
    private var fixture: ManagerFixture!
    private var manager: VMManager { fixture.manager }
    private var service: HostService!
    private var tools: MonadTools!
    private var tmp: TempDir!

    override func setUp() async throws {
        tmp = TempDir()
        let guestd = tmp.url.appendingPathComponent("MonadHost")
        try Data("binary".utf8).write(to: guestd)
        fixture = try ManagerFixture {
            $0.macInstaller = FakeMacInstaller()
            $0.allowsMacGuests = true
            $0.macSetup = FakeMacSetup()
            $0.guestdBinary = guestd
        }
        service = HostService(manager: fixture.manager, limits: .init(maxCPUs: 8, maxMemoryGiB: 16),
                              sharePlaces: SharePolicy.Places(home: "/Users/dev", monad: "/Users/dev/.monad"),
                              agents: tmp.url.appendingPathComponent("agents"))
        // The service asks the app to set a macOS VM up; here the fake does it.
        fixture.manager.macSetupAsker = nil
        let store = DistroStore(directory: tmp.url.appendingPathComponent("distros"), bundled: try DistroCatalog.bundled())
        tools = MonadTools(service: service, distros: { store },
                           networks: NetworkStore(directory: tmp.url.appendingPathComponent("networks")),
                           discover: { _ in ImageDiscovery(checksums: nil) })
    }

    private func macVM(_ name: String = "mac", edit: (inout InstanceConfig) -> Void = { _ in }) async throws -> VMInstance {
        var c = InstanceConfig.defaults(name: name)
        c.distro = "macos"
        c.release = nil
        c.cpus = 4
        c.memoryGiB = 4
        c.diskGiB = 64
        c.guestOS = .macos
        edit(&c)
        // Made with the fixture's answers (its first boot as MacDesktopTests has it), then ssh as on a set-up Mac.
        fixture.runner.setHandler { call in
            if call.executable == "/usr/bin/ssh-keygen", let i = call.arguments.firstIndex(of: "-f") {
                try Data("PRIVATE".utf8).write(to: URL(fileURLWithPath: call.arguments[i + 1]))
                try Data("ssh-ed25519 AAAATEST monad-test\n".utf8).write(to: URL(fileURLWithPath: call.arguments[i + 1] + ".pub"))
                return .ok()
            }
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            return .ok()
        }
        let vm = try manager.create(c)
        await assertEventually("\(vm.state)") { vm.state == .stopped }
        fixture.runner.setHandler { call in
            if call.executable == "/usr/bin/ssh-keygen", let i = call.arguments.firstIndex(of: "-f") {
                try Data("PRIVATE".utf8).write(to: URL(fileURLWithPath: call.arguments[i + 1]))
                try Data("ssh-ed25519 AAAATEST monad-test\n".utf8).write(to: URL(fileURLWithPath: call.arguments[i + 1] + ".pub"))
                return .ok()
            }
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            if call.arguments.last == MacSetup.agentInstallCommand { return .ok("agent-ok\n") }
            if call.arguments.last == MacRecovery.statusCommand { return .ok("System Integrity Protection status: enabled.\n") }
            return .ok()
        }
        return vm
    }

    private func call(_ name: String, _ arguments: [String: JSONValue], caller: MCPCaller = .mac) async throws -> MCPResult {
        let tool = try XCTUnwrap(tools.all().first { $0.name == name }, name)
        return try await tool.run(MCPCall(caller: caller, arguments: arguments))
    }

    private func data(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    /// The copy has the disk, the platform files, the account and its keys;
    /// its machine identifier is new.
    func testACopyIsTheSameMacWithItsOwnIdentifier() async throws {
        let source = try await macVM()
        try Data("the disk".utf8).write(to: source.paths.disk)
        let copy = try await manager.clone(source, as: "mac-2")
        XCTAssertEqual(copy.state, .stopped)
        XCTAssertTrue(manager.existing("mac-2") === copy)
        let s = source.paths, c = copy.paths
        for file in [\InstancePaths.disk, \.auxStorage, \.hardwareModel, \.macPassword, \.macSetupDone,
                     \.privateKey, \.publicKey] {
            XCTAssertEqual(try data(c[keyPath: file]), try data(s[keyPath: file]), "\(file)")
        }
        XCTAssertNotEqual(try data(c.macMachineID), try data(s.macMachineID))
        XCTAssertNotNil(VZMacMachineIdentifier(dataRepresentation: try data(c.macMachineID)), "one Virtualization reads")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: c.macPassword.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: c.privateKey.path)[.posixPermissions] as? Int, 0o600)
        let ownLog = try? data(c.vmLog)
        XCTAssertNotEqual(ownLog, try? data(s.vmLog), "its own log")
        XCTAssertEqual(copy.config.name, "mac-2")
        XCTAssertEqual(copy.config.user, source.config.user)
        XCTAssertEqual(copy.config.guestOS, .macos)
        XCTAssertEqual(manager.instances.last?.name, "mac-2", "listed at the bottom")
    }

    /// The copy runs, side by side with its source.
    func testACopyStarts() async throws {
        let source = try await macVM()
        let copy = try await manager.clone(source, as: "mac-2")
        copy.start()
        await assertEventually("\(copy.state)") { copy.state == .ready }
        source.start()
        await assertEventually("\(source.state)") { source.state == .ready }
    }

    /// A running VM's disk is being written: it is stopped first. Linux VMs
    /// (their cloud-init seed names them) are not copied yet.
    func testOnlyAStoppedMacVMIsCopied() async throws {
        let source = try await macVM()
        source.start()
        await assertEventually("\(source.state)") { source.state == .ready }
        do {
            _ = try await manager.clone(source, as: "mac-2")
            XCTFail("running")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Stop"), error.localizedDescription)
        }
        XCTAssertNil(manager.existing("mac-2"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.paths(for: "mac-2").dir.path), "nothing left")
        await source.stop()

        let linux = try manager.create(InstanceConfig.defaults(name: "box"))
        await assertEventually("\(linux.state)") { linux.state == .stopped }
        do {
            _ = try await manager.clone(linux, as: "box-2")
            XCTFail("linux")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("macOS"), error.localizedDescription)
        }
    }

    /// A name in use, or not a name, is refused, and nothing is changed.
    func testTheCopysNameIsChecked() async throws {
        let source = try await macVM()
        _ = try await macVM("other")
        for bad in ["other", "mac", "Bad Name"] {
            do {
                _ = try await manager.clone(source, as: bad)
                XCTFail(bad)
            } catch {}
        }
        XCTAssertEqual(Set(manager.instances.map(\.name)), ["mac", "other"])
    }

    // MARK: Two at once

    /// A Mac runs at most two macOS VMs at once (Apple's limit, which
    /// Virtualization checks; Monad has none of its own). A third says which
    /// are running and what to do, not Apple's words.
    func testAThirdRunningMacSaysWhichToStop() async throws {
        let a = try await macVM("a"), b = try await macVM("b"), c = try await macVM("c")
        a.start()
        b.start()
        await assertEventually("\(a.state) \(b.state)") { a.state == .ready && b.state == .ready }
        fixture.factory.machine.startError = NSError(domain: VZErrorDomain,
                                                     code: VZError.Code.virtualMachineLimitExceeded.rawValue)
        c.start()
        await assertEventually("\(c.state)") { c.state.isFailed }
        XCTAssertEqual(c.state, .failed("A Mac runs at most two macOS VMs at once, and a and b are running. "
                                        + "Stop one of them, then start c."))
        // Run by something else (the other Monad, another app): said so.
        await a.stop()
        await b.stop()
        c.start()
        await assertEventually("\(c.state)") { c.state.isFailed }
        XCTAssertEqual(c.state, .failed("A Mac runs at most two macOS VMs at once, and two are running outside "
                                        + "this Monad (the other Monad build, or another app). Stop one of them, then start c."))
    }

    // MARK: Its settings

    /// What a copy takes (the tool and the app's Duplicate alike): all but
    /// what was allowed for the original alone, which is named.
    func testACopysSettingsLeaveTheMacsAccessBehind() {
        var c = InstanceConfig.defaults(name: "mac")
        c.guestOS = .macos
        c.networks[0].macAddress = "02:00:00:00:00:01"
        c.sharing.shares = [SharedFolder(hostPath: "/Users/dev/code", guestPath: "/Users/dev/code", readOnly: false)]
        c.forwards = [ForwardRule(kind: .local, hostPort: 8080, guestPort: 80),
                      ForwardRule(kind: .unixRemote, hostSocket: "/tmp/a.sock", guestSocket: "/tmp/a.sock")]
        c.startAtLaunch = true
        c.group = "coding"
        let (copy, left) = c.copy(named: "mac-2")
        XCTAssertEqual(copy.name, "mac-2")
        XCTAssertEqual(copy.sharing.shares, [])
        XCTAssertEqual(copy.forwards.map(\.kind), [.local])
        XCTAssertNil(copy.networks[0].macAddress)
        XCTAssertFalse(copy.startAtLaunch)
        XCTAssertEqual(copy.group, "coding", "a group is how it is listed")
        XCTAssertEqual(left, ["shared folders", "forwards into the Mac"])
        XCTAssertEqual(InstanceConfig.defaults(name: "x").copy(named: "y").left, [])
    }

    /// The name offered for a copy: the first free one after the original's.
    func testACopyIsOfferedAFreeName() {
        XCTAssertEqual(InstanceConfig.copyName(of: "mac", taken: ["mac"]), "mac-2")
        XCTAssertEqual(InstanceConfig.copyName(of: "mac", taken: ["mac", "mac-2", "MAC-3"]), "mac-4", "in any case")
        let long = String(repeating: "a", count: 32)
        let name = InstanceConfig.copyName(of: long, taken: [long])
        XCTAssertTrue(InstanceConfig.isValidName(name), name)
        XCTAssertTrue(name.hasSuffix("-2"), name)
    }

    // MARK: set_macos_security

    /// A macOS VM's Security page as a tool: what it is given is changed,
    /// the rest kept, through the VM's settings (applied at its next start).
    func testTheToolSetsAMacsSecurity() async throws {
        let vm = try await macVM()
        let r = try await call("set_macos_security", ["name": .string("mac"), "sip": .bool(false),
                                                      "boot_to_recovery": .bool(true)])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertFalse(vm.config.systemIntegrityProtection)
        XCTAssertTrue(vm.config.bootToRecovery)
        XCTAssertTrue(vm.config.fullDiskAccess, "kept")
        XCTAssertTrue(vm.config.autoLogin, "kept")
        _ = try await call("set_macos_security", ["name": .string("mac"), "full_disk_access": .bool(false),
                                                  "auto_login": .bool(false)])
        XCTAssertFalse(vm.config.fullDiskAccess)
        XCTAssertFalse(vm.config.autoLogin)
        XCTAssertFalse(vm.config.systemIntegrityProtection, "kept")
        let linux = try manager.create(InstanceConfig.defaults(name: "box"))
        await assertEventually("\(linux.state)") { linux.state == .stopped }
        do {
            _ = try await call("set_macos_security", ["name": .string("box"), "sip": .bool(false)])
            XCTFail("not a Mac")
        } catch {}
    }

    // MARK: clone_vm

    /// The tool copies a VM; what reaches the Mac stays with the source
    /// (asked for again on the copy), and its network cards get new addresses.
    func testTheToolCopiesWithoutTheMacsAccess() async throws {
        let source = try await macVM()
        var c = source.config
        c.networks[0].macAddress = "02:00:00:00:00:01"
        c.sharing.shares = [SharedFolder(hostPath: tmp.url.path, guestPath: "/Users/dev/code", readOnly: false)]
        c.bridges = [CommandBridge(name: "b", command: ["/bin/cat"], guestPort: 7000)]
        c.forwards = [ForwardRule(kind: .local, hostPort: 8080, guestPort: 80),
                      ForwardRule(kind: .remote, hostPort: 9000, guestPort: 9000)]
        try c.save(to: source.paths.config)
        try source.update(c)

        let r = try await call("clone_vm", ["name": .string("mac"), "new_name": .string("mac-2")])
        XCTAssertFalse(r.isError, r.text)
        let copy = try XCTUnwrap(manager.existing("mac-2"))
        XCTAssertEqual(copy.config.sharing.shares, [])
        XCTAssertEqual(copy.config.bridges, [])
        XCTAssertEqual(copy.config.hostCommands, [])
        XCTAssertNil(copy.config.agents)
        XCTAssertEqual(copy.config.forwards.map(\.guestPort), [80], "guest-side forwards stay")
        XCTAssertNil(copy.config.networks[0].macAddress)
        XCTAssertEqual(copy.config.networks[0].network, source.config.networks[0].network)
        XCTAssertTrue(r.text.contains("mac-2"), r.text)
        XCTAssertTrue(r.text.contains("shared folders"), r.text)
        XCTAssertEqual(source.config.sharing.shares.count, 1, "the source is left as it was")
    }

    /// Start it straight away, if asked.
    func testTheToolCanStartTheCopy() async throws {
        _ = try await macVM()
        _ = try await call("clone_vm", ["name": .string("mac"), "new_name": .string("mac-2"), "start": .bool(true)])
        let copy = try XCTUnwrap(manager.existing("mac-2"))
        await assertEventually("\(copy.state)") { copy.state == .ready }
    }

    /// A VM that makes VMs gets a copy as one of its own: its limits, its
    /// networks and firewall.
    func testAnOrchestratorsCopyIsItsChild() async throws {
        _ = try await macVM()
        let boss = try await macVM("boss") {
            $0.agents = AgentAccess(role: .orchestrator, maxChildren: 0)
        }
        do {
            _ = try await call("clone_vm", ["name": .string("mac"), "new_name": .string("mac-2")], caller: .vm(boss.name))
            XCTFail("over its limit")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("most it may"), error.localizedDescription)
        }
        XCTAssertNil(manager.existing("mac-2"))
    }
}
