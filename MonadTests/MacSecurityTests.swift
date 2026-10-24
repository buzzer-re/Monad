//
//  MacSecurityTests.swift — a macOS VM's System Integrity Protection, set
//  on its Security page: a change is made at the next start in the VM's
//  recoveryOS (MacRecovery), then the VM boots and `csrutil status` says
//  how SIP is. A change that did not take is undone (the setting shows
//  what the VM has) and says why; full disk access the same way.
//

import Combine
import XCTest
@testable import Monad

@MainActor
final class MacSecurityTests: XCTestCase {
    private var fixture: ManagerFixture!
    private var manager: VMManager { fixture.manager }
    private var factory: FakeMachineFactory { fixture.factory }
    private var bin: TempDir!
    /// What `csrutil status` answers in the booted VM.
    private var sipAnswer = "enabled"

    override func setUp() async throws {
        bin = TempDir()
        let guestd = bin.url.appendingPathComponent("MonadHost")
        try Data("binary".utf8).write(to: guestd)
        fixture = try ManagerFixture {
            $0.macInstaller = FakeMacInstaller()
            $0.allowsMacGuests = true
            $0.macSetup = FakeMacSetup()
            $0.guestdBinary = guestd
        }
    }

    private var macConfig: InstanceConfig {
        var c = InstanceConfig.defaults(name: "mac")
        c.distro = "macos"
        c.release = nil
        c.cpus = 4
        c.memoryGiB = 4
        c.diskGiB = 64
        return c
    }

    /// A macOS VM, made and set up, stopped; SIP as `sip` in its settings.
    private func macVM(sip: Bool, made config: InstanceConfig? = nil) async throws -> VMInstance {
        let vm = try manager.create(config ?? macConfig)
        await assertEventually("\(vm.state)") { vm.state == .stopped }
        fixture.runner.setHandler { [unowned self] call in
            if call.executable == "/usr/bin/hdiutil", call.arguments.first == "attach" { return try FakeMacDisk.attach(call) }
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            if call.arguments.last == MacSetup.agentInstallCommand { return .ok("agent-ok\n") }
            if call.arguments.last == MacRecovery.statusCommand {
                return .ok("System Integrity Protection status: \(self.sipAnswer).\n")
            }
            return .ok()
        }
        var edited = vm.config
        edited.systemIntegrityProtection = sip
        try vm.update(edited)
        return vm
    }

    /// Off: the VM first boots into recovery on its own network, where
    /// csrutil is typed with the account's password; then it boots, and
    /// SIP is found off. The next start goes straight to macOS.
    func testTurningSIPOffGoesThroughRecovery() async throws {
        let vm = try await macVM(sip: false)
        sipAnswer = "disabled"
        let booted = factory.machine.started
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        XCTAssertEqual(factory.recoveries.count, 1)
        let recovery = try XCTUnwrap(factory.recoveries.first)
        XCTAssertFalse(recovery.config.sharing.runtimeEnabled, "no shared folders in recovery")
        XCTAssertNotNil(recovery.nic, "the VM's own network")
        let password = try String(contentsOf: vm.paths.macPassword, encoding: .utf8)
        XCTAssertTrue(factory.recoveryMachine.typed.contains("csrutil disable\ny\n\(password)\n"), factory.recoveryMachine.typed)
        XCTAssertGreaterThan(factory.recoveryMachine.clicks, 0)
        XCTAssertEqual(factory.machine.started, booted + 1, "then macOS itself")
        await assertEventually { vm.macSecurity?.sip == "disabled" }
        XCTAssertNil(vm.macSecurity?.problem)
        XCTAssertEqual(try String(contentsOf: vm.paths.macSIPStatus, encoding: .utf8), "disabled")

        await vm.stop()
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        XCTAssertEqual(factory.recoveries.count, 1, "SIP is as wanted: no recovery")
    }

    /// SIP on, as installed: no recovery; the status is still read.
    func testAVMWithSIPAsWantedStartsStraightAway() async throws {
        let vm = try await macVM(sip: true)
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        XCTAssertEqual(factory.recoveries.count, 0)
        await assertEventually { vm.macSecurity?.sip == "enabled" }
        XCTAssertNil(vm.macSecurity?.problem)
    }

    /// Recovery ran but SIP is still on: the setting goes back to on (the
    /// switch shows what the VM has), the page says why, and the next
    /// start does not go through recovery. Turning it off again tries again.
    func testAChangeThatDidNotTakeIsUndoneAndSaysWhy() async throws {
        let vm = try await macVM(sip: false)
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        await assertEventually { vm.macSecurity?.problem != nil }
        XCTAssertEqual(vm.macSecurity?.sip, "enabled")
        XCTAssertTrue(vm.macSecurity?.problem?.contains("could not turn System Integrity Protection off") == true,
                      vm.macSecurity?.problem ?? "")
        XCTAssertTrue(vm.config.systemIntegrityProtection, "back to what the VM has")
        XCTAssertTrue(try InstanceConfig.load(from: vm.paths.config).systemIntegrityProtection, "saved so")
        XCTAssertEqual(vm.pendingRestart, [], "nothing waits for a restart")

        await vm.stop()
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        XCTAssertEqual(factory.recoveries.count, 1, "not at every start")

        sipAnswer = "disabled"
        await vm.stop()
        var edited = vm.config
        edited.systemIntegrityProtection = false
        try vm.update(edited)
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready && factory.recoveries.count == 2 }
        await assertEventually { vm.macSecurity?.sip == "disabled" }
        XCTAssertNil(vm.macSecurity?.problem)
        XCTAssertFalse(vm.config.systemIntegrityProtection)
    }

    /// Turning SIP back on is `csrutil enable`.
    func testTurningSIPOnIsTypedToo() async throws {
        let vm = try await macVM(sip: true)
        try Data("disabled".utf8).write(to: vm.paths.macSIPStatus)
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        XCTAssertTrue(factory.recoveryMachine.typed.contains("csrutil enable\n"), factory.recoveryMachine.typed)
    }

    /// Recovery that never shuts down is powered off after a while; the
    /// VM then boots as it is (the check says how SIP is).
    func testRecoveryThatDoesNotShutDownIsPoweredOff() async throws {
        let vm = try await macVM(sip: false)
        factory.recoveryMachine.shutsDown = false
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        XCTAssertEqual(factory.recoveryMachine.forceStops, 1)
    }

    /// Recovery is part of starting: the VM says it is starting and what
    /// it does there; it can be grouped and shut down like any VM starting.
    func testRecoveryIsPartOfStarting() async throws {
        let vm = try await macVM(sip: false)
        factory.recoveryMachine.paused = true
        var steps: [String] = []
        let watch = vm.$macSecurity.sink { if let s = $0?.step { steps.append(s) } }
        defer { watch.cancel() }
        vm.start()
        await assertEventually { factory.recoveryMachine.started == 1 }
        XCTAssertEqual(vm.state, .starting)
        XCTAssertTrue(steps.contains { $0.contains("System Integrity Protection") && $0.contains("recovery") }, "\(steps)")
        XCTAssertTrue(steps.contains { $0.contains("starting recovery (step 1 of 8)") }, "\(steps)")
        var grouped = vm.config
        grouped.group = "work"
        XCTAssertNoThrow(try vm.update(grouped), "settings can change meanwhile")
        await vm.stop()
        XCTAssertEqual(vm.state, .stopped)
        XCTAssertGreaterThanOrEqual(factory.recoveryMachine.forceStops, 1)
        XCTAssertNil(vm.macSecurity?.step)
        XCTAssertEqual(factory.recoveries.count, 1)
    }

    /// Each step in recovery shows on the VM's status and goes in its log.
    func testRecoveryShowsEachStep() async throws {
        let vm = try await macVM(sip: false)
        sipAnswer = "disabled"
        var steps: [String] = []
        let watch = vm.$macSecurity.sink { if let s = $0?.step { steps.append(s) } }
        defer { watch.cancel() }
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        for n in ["starting recovery (step 1 of 8)", "opening Terminal (step 4 of 8)", "shutting recovery down (step 8 of 8)"] {
            XCTAssertTrue(steps.contains { $0.contains(n) }, "\(n) in \(steps)")
        }
        vm.log.flush()
        let log = try String(contentsOf: vm.paths.vmLog, encoding: .utf8)
        XCTAssertTrue(log.contains("sip: opening Terminal (step 4 of 8)"), log)
    }

    // MARK: Full disk access

    private var sqlCalls: [FakeCommandRunner.Call] { fixture.runner.calls.filter { $0.executable == "/usr/bin/sqlite3" } }

    /// Made with full disk access off: nothing is written into its disk.
    func testFullDiskAccessCanBeLeftOffWhenTheVMIsMade() async throws {
        var c = macConfig
        c.fullDiskAccess = false
        let vm = try manager.create(c)
        await assertEventually("\(vm.state)") { vm.state == .stopped }
        XCTAssertEqual(sqlCalls.count, 0)
        XCTAssertEqual(try String(contentsOf: vm.paths.macFullDiskAccess, encoding: .utf8), "off")
        XCTAssertEqual(vm.macSecurity?.fullDiskAccess, false)
    }

    /// Changed on the Security page: at the next start, before macOS
    /// boots, the row goes from (or into) the stopped VM's disk; once.
    func testFullDiskAccessIsChangedOnTheStoppedDiskAtTheNextStart() async throws {
        let vm = try await macVM(sip: true)
        var edited = vm.config
        edited.fullDiskAccess = false
        try vm.update(edited)
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        XCTAssertEqual(sqlCalls.last?.arguments.last, MacSetup.fullDiskAccessRevokeSQL)
        XCTAssertEqual(try String(contentsOf: vm.paths.macFullDiskAccess, encoding: .utf8), "off")
        XCTAssertEqual(vm.macSecurity?.fullDiskAccess, false)
        let written = sqlCalls.count
        await vm.stop()
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        XCTAssertEqual(sqlCalls.count, written, "as set: nothing written")

        await vm.stop()
        edited.fullDiskAccess = true
        try vm.update(edited)
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        XCTAssertEqual(sqlCalls.last?.arguments.last, try MacSetup.fullDiskAccessSQL())
        XCTAssertEqual(vm.macSecurity?.fullDiskAccess, true)
    }

    /// A change that cannot be written is shown, and the VM starts anyway.
    func testAFullDiskAccessChangeThatFailsIsShown() async throws {
        let vm = try await macVM(sip: true)
        var edited = vm.config
        edited.fullDiskAccess = false
        try vm.update(edited)
        fixture.runner.setHandler { call in
            if call.executable == "/usr/bin/hdiutil" { return .fail(1, "hdiutil: attach failed - Resource busy") }
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            if call.arguments.last == MacSetup.agentInstallCommand { return .ok("agent-ok\n") }
            return .ok()
        }
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        XCTAssertTrue(vm.macSecurity?.accessProblem?.contains("Resource busy") == true, vm.macSecurity?.accessProblem ?? "")
        XCTAssertTrue(vm.config.fullDiskAccess, "back to what the disk has")
        XCTAssertTrue(try InstanceConfig.load(from: vm.paths.config).fullDiskAccess)
        XCTAssertEqual(vm.macSecurity?.fullDiskAccess, true)
    }

    /// SIP is a macOS setting, on unless turned off; it applies at the next start.
    func testSIPIsAMacOSSettingAppliedAtTheNextStart() throws {
        var c = InstanceConfig.defaults(name: "mac")
        c.guestOS = .macos
        c.memoryGiB = 4
        c.diskGiB = 64
        XCTAssertTrue(c.systemIntegrityProtection)
        var off = c
        off.systemIntegrityProtection = false
        XCTAssertNoThrow(try off.validate(maxCPUs: 8, maxMemoryGiB: 16))
        XCTAssertEqual(try JSONDecoder().decode(InstanceConfig.self, from: JSONEncoder().encode(off)).systemIntegrityProtection, false)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("systemIntegrityProtection"),
                       "on is not written")
        XCTAssertEqual(ConfigChange.restartOnly(from: c, to: off), ["System Integrity Protection"])
        var linux = InstanceConfig.defaults(name: "l")
        linux.systemIntegrityProtection = false
        XCTAssertThrowsError(try linux.validate(maxCPUs: 8, maxMemoryGiB: 16), "Linux has no SIP")
        // Full disk access the same way.
        XCTAssertTrue(c.fullDiskAccess)
        var closed = c
        closed.fullDiskAccess = false
        XCTAssertNoThrow(try closed.validate(maxCPUs: 8, maxMemoryGiB: 16))
        XCTAssertEqual(try JSONDecoder().decode(InstanceConfig.self, from: JSONEncoder().encode(closed)).fullDiskAccess, false)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("fullDiskAccess"))
        XCTAssertEqual(ConfigChange.restartOnly(from: c, to: closed), ["full disk access"])
        linux = InstanceConfig.defaults(name: "l")
        linux.fullDiskAccess = false
        XCTAssertThrowsError(try linux.validate(maxCPUs: 8, maxMemoryGiB: 16), "a macOS setting")
    }

    // MARK: Boot to Recovery

    /// Boot to Recovery, once: the next start opens recovery and its desktop
    /// for the user (nothing typed), and the switch is off again. Leaving
    /// recovery (restart or shut down there) starts macOS.
    func testBootToRecoveryIsOnce() async throws {
        let vm = try await macVM(sip: true)
        var c = vm.config
        c.bootToRecovery = true
        try vm.update(c)
        let booted = factory.machine.started
        vm.start()
        await assertEventually { self.factory.recoveryMachine.started == 1 }
        XCTAssertEqual(vm.state, .starting)
        XCTAssertTrue(vm.macSecurity?.step?.contains("recovery") ?? false, "\(String(describing: vm.macSecurity?.step))")
        XCTAssertEqual(factory.recoveryMachine.desktops, ["mac"], "its desktop opened")
        XCTAssertFalse(vm.config.bootToRecovery, "once")
        XCTAssertFalse(try InstanceConfig.load(from: vm.paths.config).bootToRecovery, "saved off")
        XCTAssertEqual(factory.recoveryMachine.typed, "", "nothing typed: it is the user's")
        XCTAssertEqual(factory.machine.started, booted, "not macOS yet")

        factory.recoveryMachine.onEvent?(.stopped)
        await assertEventually("\(vm.state)") { vm.state == .ready }
        XCTAssertEqual(factory.machine.started, booted + 1, "then macOS")
        XCTAssertNil(vm.macSecurity?.step)
        await vm.stop()
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        XCTAssertEqual(factory.recoveryMachine.started, 1, "not again")
    }

    /// Shut down while in recovery: the VM stops there, macOS does not start.
    func testStoppingInRecoveryStops() async throws {
        let vm = try await macVM(sip: true)
        var c = vm.config
        c.bootToRecovery = true
        try vm.update(c)
        let booted = factory.machine.started
        vm.start()
        await assertEventually { self.factory.recoveryMachine.started == 1 }
        await vm.stop()
        XCTAssertEqual(vm.state, .stopped)
        XCTAssertEqual(factory.machine.started, booted)
    }

    /// A macOS setting, saved only while on, applied at the next start.
    func testBootToRecoveryIsAMacOSSetting() throws {
        var mac = macConfig
        mac.guestOS = .macos
        var on = mac
        on.bootToRecovery = true
        XCTAssertNoThrow(try on.validate(maxCPUs: 8, maxMemoryGiB: 16))
        XCTAssertEqual(ConfigChange.restartOnly(from: mac, to: on), ["boot to recovery"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(mac), as: UTF8.self).contains("bootToRecovery"))
        XCTAssertTrue(try JSONDecoder().decode(InstanceConfig.self, from: JSONEncoder().encode(on)).bootToRecovery)
        var linux = InstanceConfig.defaults(name: "l")
        linux.bootToRecovery = true
        XCTAssertThrowsError(try linux.validate(maxCPUs: 8, maxMemoryGiB: 16))
    }
}
