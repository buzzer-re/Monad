//
//  MacDesktopTests.swift — a macOS VM's desktop, opened from its ⋯ menu
//  for what needs a person (installing the developer tools, a system
//  prompt): a window on its display, shown by MonadHost, which runs it.
//

import XCTest
@testable import Monad

@MainActor
final class MacDesktopTests: XCTestCase {
    private var fixture: ManagerFixture!
    private var manager: VMManager { fixture.manager }
    private var factory: FakeMachineFactory { fixture.factory }
    private var bin: TempDir!

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

    private func macVM(sip: Bool = true, edit: (inout InstanceConfig) -> Void = { _ in }) async throws -> VMInstance {
        var c = InstanceConfig.defaults(name: "mac")
        c.distro = "macos"
        c.release = nil
        c.cpus = 4
        c.memoryGiB = 4
        c.diskGiB = 64
        edit(&c)
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
        if !sip {
            var edited = vm.config
            edited.systemIntegrityProtection = false
            try vm.update(edited)
        }
        return vm
    }

    /// A running macOS VM's desktop opens in a window named after it.
    func testARunningMacVMsDesktopOpens() async throws {
        let vm = try await macVM()
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        try vm.openDesktop()
        XCTAssertEqual(factory.machine.desktops, ["mac"])
    }

    /// The desktop's Type Password types the account's password and Return
    /// (the login window, a system prompt), never showing it.
    func testThePasswordIsTypedIntoTheDesktop() async throws {
        let vm = try await macVM()
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        try vm.openDesktop()
        let password = try String(contentsOf: vm.paths.macPassword, encoding: .utf8)
        await factory.machine.desktopActions.first?.run()
        await assertEventually { factory.machine.typed == password + "\n" }
        XCTAssertEqual(factory.machine.desktopActions.map(\.title), ["Type Password"])
        // Keys held on the Mac (⌘ for ⌘V) let go first, and the display woken.
        XCTAssertEqual(factory.machine.inputLog.prefix(2), ["release", "wake"])
    }

    // MARK: ⌘V

    /// ⌘V on the desktop: the Mac's text goes on the VM's clipboard (over
    /// ssh, on stdin), then ⌘V is pressed there.
    func testPasteGoesThroughTheVMsClipboard() async throws {
        let vm = try await macVM()
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        try vm.openDesktop()
        await factory.machine.desktopPaste?("echo héllo\nls")
        let copy = try XCTUnwrap(fixture.runner.calls.last { $0.arguments.last == MacSetup.pasteboardCommand(user: vm.config.user) })
        XCTAssertEqual(copy.stdin, Data("echo héllo\nls".utf8))
        XCTAssertEqual(factory.machine.typed, "⌘v")
    }

    /// Nobody logged in on the desktop (the login window has no clipboard):
    /// the text is typed instead.
    func testAtTheLoginWindowPasteIsTyped() async throws {
        let vm = try await macVM()
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        fixture.runner.setHandler { call in
            if call.arguments.last == MacSetup.pasteboardCommand(user: vm.config.user) { return .fail(1, "") }
            return .ok()
        }
        try vm.openDesktop()
        await factory.machine.desktopPaste?("Secret 1!")
        XCTAssertEqual(factory.machine.typed, "Secret 1!")
        XCTAssertEqual(factory.machine.inputLog.prefix(2), ["release", "wake"], "⌘ is still held when ⌘V is pressed")
    }

    // MARK: Auto-fill

    /// With auto-fill, a password prompt the guest's agent sees on screen
    /// (an admin dialog, the lock screen) gets the password typed into it.
    func testAPromptIsFilledWithAutoFill() async throws {
        let channel = SocketPairChannel()
        factory.machine.channels = [channel]
        let vm = try await macVM { $0.desktopAutofill = true }
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        await assertEventually { self.factory.machine.openedPorts.contains(CloudInit.agentVsockPort) }
        channel.agentSays("hello monad-agent 1\nprompt password\n")
        let password = try String(contentsOf: vm.paths.macPassword, encoding: .utf8)
        await assertEventually { self.factory.machine.typed == password + "\n" }
    }

    /// Without it (or not asked yet), nothing is typed.
    func testNothingIsFilledWithoutAutoFill() async throws {
        let channel = SocketPairChannel()
        factory.machine.channels = [channel]
        let vm = try await macVM()
        XCTAssertNil(vm.config.desktopAutofill, "asked when the desktop is first opened")
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        await assertEventually { self.factory.machine.openedPorts.contains(CloudInit.agentVsockPort) }
        channel.agentSays("hello monad-agent 1\nprompt password\nping\n")
        await assertEventually { vm.agentAvailable }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(factory.machine.typed, "")
    }

    /// With automatic login off, the guest has only a hash of the password:
    /// auto-fill types nothing then (the desktop's Type Password still does).
    func testNothingIsFilledWhileAutomaticLoginIsOff() async throws {
        let channel = SocketPairChannel()
        factory.machine.channels = [channel]
        let vm = try await macVM {
            $0.desktopAutofill = true
            $0.autoLogin = false
        }
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        await assertEventually { self.factory.machine.openedPorts.contains(CloudInit.agentVsockPort) }
        channel.agentSays("hello monad-agent 1\nprompt password\nping\n")
        await assertEventually { vm.agentAvailable }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(factory.machine.typed, "")
    }

    // MARK: Its name

    /// Each macOS VM is named after itself (as a Linux VM is: monad-<name>,
    /// its own name for the Mac's computer name), at every boot.
    func testAMacVMIsNamedAfterItself() async throws {
        let vm = try await macVM()
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        XCTAssertEqual(MacSetup.hostNameCommand(config: vm.config),
                       "sudo -n sh -c 'scutil --set ComputerName mac && scutil --set LocalHostName monad-mac "
                       + "&& scutil --set HostName monad-mac'")
        await assertEventually { !self.sshCalls(MacSetup.hostNameCommand(config: vm.config)).isEmpty }
    }

    // MARK: Logging in automatically

    private func sshCalls(_ command: String) -> [FakeCommandRunner.Call] {
        fixture.runner.calls.filter { $0.executable == "/usr/bin/ssh" && $0.arguments.last == command }
    }

    /// On (the default): set up while the VM is made, and at every boot
    /// (the encoded password on stdin, never in an argument).
    func testItLogsInAutomaticallyByDefault() async throws {
        let vm = try await macVM()
        XCTAssertTrue(vm.config.autoLogin)
        let password = try String(contentsOf: vm.paths.macPassword, encoding: .utf8)
        XCTAssertEqual(sshCalls(MacSetup.autoLoginOnCommand(user: vm.config.user)).first?.stdin,
                       MacSetup.kcpassword(password), "while made")
        let made = sshCalls(MacSetup.autoLoginOnCommand(user: vm.config.user)).count
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        await assertEventually { self.sshCalls(MacSetup.autoLoginOnCommand(user: vm.config.user)).count == made + 1 }
        XCTAssertFalse(fixture.runner.calls.contains { $0.arguments.contains { $0.contains(password) } }, "never in an argument")
    }

    /// Off: taken away at the next boot.
    func testAutomaticLoginCanBeTurnedOff() async throws {
        let vm = try await macVM { $0.autoLogin = false }
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        await assertEventually { !self.sshCalls(MacSetup.autoLoginOffCommand).isEmpty }
        XCTAssertTrue(sshCalls(MacSetup.autoLoginOnCommand(user: vm.config.user)).isEmpty)
    }

    /// Both are macOS settings; automatic login applies at the next boot.
    func testTheyAreMacOSSettings() throws {
        var c = InstanceConfig.defaults(name: "mac")
        c.guestOS = .macos
        c.memoryGiB = 4
        c.diskGiB = 64
        var off = c
        off.autoLogin = false
        off.desktopAutofill = true
        XCTAssertNoThrow(try off.validate(maxCPUs: 8, maxMemoryGiB: 16))
        let back = try JSONDecoder().decode(InstanceConfig.self, from: JSONEncoder().encode(off))
        XCTAssertEqual(back.autoLogin, false)
        XCTAssertEqual(back.desktopAutofill, true)
        let plain = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        XCTAssertFalse(plain.contains("autoLogin") || plain.contains("desktopAutofill"))
        XCTAssertEqual(ConfigChange.restartOnly(from: c, to: off), ["automatic login"])
        var linux = InstanceConfig.defaults(name: "l")
        linux.autoLogin = false
        XCTAssertThrowsError(try linux.validate(maxCPUs: 8, maxMemoryGiB: 16))
        linux = InstanceConfig.defaults(name: "l")
        linux.desktopAutofill = true
        XCTAssertThrowsError(try linux.validate(maxCPUs: 8, maxMemoryGiB: 16))
    }

    /// The file macOS logs in automatically with: the password XORed with
    /// Apple's key, padded with at least one zero to a multiple of 12.
    func testTheAutomaticLoginPasswordIsEncodedAsMacOSReadsIt() {
        XCTAssertEqual(MacSetup.kcpassword("password"),
                       Data([0x0D, 0xE8, 0x21, 0x50, 0xA5, 0xD3, 0xAF, 0x8E, 0xA3, 0xB9, 0x1F, 0x7D]))
        XCTAssertEqual(MacSetup.kcpassword(String(repeating: "a", count: 12)).count, 24, "a zero after it")
    }

    /// Nothing to show for a stopped VM, or a Linux one.
    func testADesktopNeedsARunningMacVM() async throws {
        let vm = try await macVM()
        XCTAssertThrowsError(try vm.openDesktop()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Start it"), error.localizedDescription)
        }
        let linux = try manager.create(InstanceConfig.defaults(name: "box"))
        await assertEventually("\(linux.state)") { linux.state == .stopped }
        linux.start()
        await assertEventually("\(linux.state)") { linux.state == .ready }
        XCTAssertThrowsError(try linux.openDesktop()) { error in
            XCTAssertTrue(error.localizedDescription.contains("macOS"), error.localizedDescription)
        }
        XCTAssertEqual(factory.machine.desktops, [])
    }

    /// In recovery (SIP being changed) the desktop shows recovery.
    func testRecoveryCanBeWatched() async throws {
        let vm = try await macVM(sip: false)
        factory.recoveryMachine.paused = true
        vm.start()
        await assertEventually { factory.recoveryMachine.started == 1 }
        try vm.openDesktop()
        XCTAssertEqual(factory.recoveryMachine.desktops, ["mac"])
        await vm.stop()
    }
}
