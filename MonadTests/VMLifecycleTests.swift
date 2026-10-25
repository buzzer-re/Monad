//
//  VMLifecycleTests.swift — VMInstance state machine against fakes: no VZ,
//  no ssh, no real time.
//

import Combine
import XCTest
@testable import Monad

@MainActor
final class VMLifecycleTests: XCTestCase {
    private var tmp: TempDir!
    private var runner: FakeCommandRunner!
    private var factory: FakeMachineFactory!
    private var clock: TestClock!
    private var ssh: FakeSSHMaster!
    private var watcher: ManualProcessWatcher!
    private var debugLog: DebugLog!
    private var bridges: FakeBridges!

    override func setUp() async throws {
        tmp = TempDir()
        ssh = FakeSSHMaster()
        watcher = ManualProcessWatcher()
        runner = FakeCommandRunner { [ssh] call in
            if let r = ssh!.handle(call) { return r }
            // Default guest: ssh works and isolation is intact.
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            return .ok()
        }
        factory = FakeMachineFactory()
        bridges = FakeBridges()
        clock = TestClock()
        debugLog = DebugLog(process: "unit", directory: tmp.url.appendingPathComponent("logs"),
                            settings: tmp.url.appendingPathComponent("logging.json"))
        debugLog.setEnabled(true)
    }

    private var debugLogText: String {
        debugLog.flush()
        return (try? String(contentsOf: debugLog.currentFile, encoding: .utf8)) ?? ""
    }

    private func makeInstance(name: String = "unit", guest: DistroConfig.GuestProfile? = nil,
                              networks: NetworkAttaching? = nil, profiles: ProfileCatalog? = nil,
                              endpoints: FakeEndpoints? = nil,
                              edit: (inout InstanceConfig) -> Void = { _ in }) throws -> VMInstance {
        let paths = InstancePaths(name: name, root: tmp.url)
        try FileManager.default.createDirectory(at: paths.dir, withIntermediateDirectories: true)
        var config = InstanceConfig.defaults(name: name)
        config.networks = [NetworkAttachment(network: NetworkAttachment.defaultNAT, macAddress: nil)]
        edit(&config)
        try config.save(to: paths.config)
        var env = VMEnvironment(runner: runner, machines: factory, clock: clock, virtualizationSupported: true,
                                watcher: watcher, networks: networks)
        env.profiles = { profiles ?? ProfileCatalog(builtIn: [], custom: []) }
        env.debugLog = debugLog
        env.bridgeServer = { [bridges] in bridges!.make($0, $1) }
        env.hostCommandServer = { [bridges] in bridges!.make($0, $1, $2) }
        if let endpoints { env.mcpEndpoint = { socket, token, _ in endpoints.make(socket, token) } }
        let profile = guest ?? DistroConfig.GuestProfile(packageManager: "apt")
        return VMInstance(config: config, paths: paths, environment: env, guest: profile)
    }

    /// Each VM keeps its own log, with debug logging off too: what Monad
    /// did with it, for its Log page.
    func testAVMKeepsItsOwnLogEvenWithDebugLoggingOff() async throws {
        debugLog.setEnabled(false)
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        vm.log.flush()
        let text = (try? String(contentsOf: vm.paths.vmLog, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("state booting → ready"), text)
        XCTAssertTrue(text.contains("isolation check"), text)
        XCTAssertFalse(debugLogText.contains("state booting → ready"), "the debug log stays off")
    }

    func testSSHConfigIsRewrittenAtEveryBoot() async throws {
        let vm = try makeInstance()
        try "ControlMaster auto\nControlPersist yes\n".write(to: vm.paths.sshConfig, atomically: true, encoding: .utf8)
        vm.start()
        await assertEventually { vm.state == .ready }
        let cfg = try String(contentsOf: vm.paths.sshConfig, encoding: .utf8)
        XCTAssertTrue(cfg.contains("ControlMaster no"), "VMs created by older versions get the current ssh settings")
        XCTAssertFalse(cfg.contains("ControlMaster auto"))
    }

    func testIsolationCheckMasksEveryNetworkSSH() async throws {
        let vm = try makeInstance(guest: DistroConfig.GuestProfile(packageManager: "dnf"))
        vm.start()
        await assertEventually { vm.state == .ready }
        let check = try XCTUnwrap(runner.calls.first { CloudInit.isIsolationCheck($0.arguments.last) })
        XCTAssertTrue(check.arguments.last?.contains("mask --now ssh.service ssh.socket sshd.service sshd.socket") ?? false)
    }

    private var sshTrueCalls: [FakeCommandRunner.Call] { runner.sshCalls(runningRemote: "true") }

    // MARK: Start

    func testStartReachesReadyThroughBootingAndOpensBridge() async throws {
        let vm = try makeInstance()
        var states: [VMInstance.State] = []
        let sub = vm.$state.sink { states.append($0) }
        defer { sub.cancel() }

        vm.start()
        await assertEventually("state: \(vm.state)") { vm.state == .ready }

        XCTAssertEqual(states, [.stopped, .starting, .booting, .ready])
        XCTAssertEqual(factory.machine.started, 1)
        XCTAssertEqual(factory.machine.bridge?.path, vm.paths.sshSocket.path)
        XCTAssertEqual(factory.machine.bridge?.port, 22)
    }

    func testReadinessUsesSSHWithInstanceConfig() async throws {
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        let call = try XCTUnwrap(sshTrueCalls.first)
        XCTAssertEqual(Array(call.arguments.prefix(2)), ["-F", "none"], "never the file on disk")
        XCTAssertTrue(call.arguments.contains("User=\(vm.config.user)"))
        XCTAssertTrue(call.arguments.contains("BatchMode=yes"))
        XCTAssertTrue(call.arguments.contains("ControlMaster=no"), "probes must never become the mux master")
        XCTAssertEqual(call.arguments[call.arguments.count - 2], "monad-unit")
    }

    func testWaitsUntilVsockAnswersBeforeTryingSSH() async throws {
        let vm = try makeInstance()
        factory.machine.probeAnswers = [false, false, false, true]
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(factory.machine.probes, 4)
        XCTAssertEqual(sshTrueCalls.count, 1)
        XCTAssertGreaterThanOrEqual(clock.totalSlept, 3, "polls are paced by the clock")
    }

    func testRetriesSSHUntilKeysAreAccepted() async throws {
        var attempts = 0
        runner.setHandler { call in
            if call.arguments.last == "true" {
                attempts += 1
                return attempts < 3 ? .fail(255, "Permission denied") : .ok()
            }
            return .ok("ok\n")
        }
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(attempts, 3)
    }

    /// A boot that never reached sshd: once the VM is off, Monad reads its
    /// disk and the error says what it found (here the root's superblock
    /// zeroed, as one VM's was); the details go to its log.
    func testABootThatNeverAnswersSaysWhatItsDiskShows() async throws {
        let vm = try makeInstance()
        try DiskCheckTests.writeDisk(vm.paths.disk, primary: nil)
        factory.machine.probeAnswers = [false]
        vm.start()
        await assertEventually("state: \(vm.state)") {
            if case .failed(let m) = vm.state { return m.contains("Monad checked its disk") }
            return false
        }
        guard case .failed(let message) = vm.state else { return XCTFail() }
        XCTAssertTrue(message.hasPrefix("The guest did not become reachable over SSH."), message)
        XCTAssertTrue(message.contains("the filesystem cloudimg-rootfs has a damaged superblock"), message)
        XCTAssertTrue(vmLog(vm).contains("disk: no partition table; the whole disk: ext, damaged superblock, backup at block 32768"),
                      vmLog(vm))
    }

    /// A guest that powers itself off before Monad reached it failed its
    /// boot (it used to end as plainly stopped): it says so, with its disk.
    func testAGuestThatPowersOffWhileBootingFails() async throws {
        let vm = try makeInstance()
        try DiskCheckTests.writeDisk(vm.paths.disk, primary: DiskCheckTests.ext4Superblock(label: "cloudimg-rootfs"))
        factory.machine.probeAnswers = [false]
        vm.start()
        await assertEventually { vm.state == .booting }
        factory.machine.emit(.stopped)
        await assertEventually("state: \(vm.state)") {
            if case .failed(let m) = vm.state { return m.contains("Monad checked its disk") }
            return false
        }
        guard case .failed(let message) = vm.state else { return XCTFail() }
        XCTAssertTrue(message.hasPrefix("The guest powered itself off before Monad could reach it."), message)
        XCTAssertTrue(message.contains("found its partitions and filesystems intact"), message)
    }

    func testTimesOutWhenGuestNeverAnswers() async throws {
        let vm = try makeInstance()
        factory.machine.probeAnswers = [false]
        vm.start()
        await assertEventually("state: \(vm.state)") { vm.isFailed }
        guard case .failed(let message) = vm.state else { return XCTFail() }
        XCTAssertTrue(message.contains(vm.paths.serialLog.path), "points at the console log: \(message)")
        XCTAssertGreaterThanOrEqual(clock.totalSlept, 15 * 60)
        XCTAssertEqual(factory.machine.forceStops, 1, "a guest that never came up is powered off")
    }

    /// The guest's own report (Guest/monad-report.sh, on its console) goes
    /// to the debug log as it comes, and a boot that fails says what the
    /// guest said last, not what an older boot said.
    func testABootThatFailsSaysWhatTheGuestReported() async throws {
        let vm = try makeInstance()
        let log = vm.paths.serialLog
        try Data("MONAD| vsock: from an older boot\n".utf8).write(to: log)
        factory.machine.probeAnswers = [false]
        var written = false
        factory.machine.onProbe = {
            guard !written, let h = try? FileHandle(forWritingTo: log) else { return }
            written = true
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(("MONAD| selinux: enforcing\n"
                + "MONAD| selinux denied { create } to systemd: init_t -> sshd_t vsock_socket\n").utf8))
            try? h.close()
        }
        vm.start()
        await assertEventually("state: \(vm.state)") { vm.isFailed }
        guard case .failed(let message) = vm.state else { return XCTFail() }
        XCTAssertTrue(message.contains(
            "The guest says: selinux: enforcing; selinux denied { create } to systemd: init_t -> sshd_t vsock_socket."), message)
        XCTAssertFalse(message.contains("older boot"), message)
        XCTAssertTrue(message.contains(log.path), message)
        XCTAssertTrue(debugLogText.contains("guest: selinux denied { create } to systemd"), debugLogText)
        XCTAssertEqual(TimeInterval(CloudInit.reportWatchSeconds), VMInstance.bootTimeout, "the guest watches as long as Monad waits")
    }

    /// On a first boot cloud-init may still be changing sshd when the check
    /// runs, and drop it. No answer proves nothing either way: the check is
    /// asked again (an exposed guest still fails at once, see below).
    func testAnUnansweredIsolationCheckIsAskedAgain() async throws {
        var checks = 0
        runner.setHandler { call in
            guard CloudInit.isIsolationCheck(call.arguments.last) else { return .ok() }
            checks += 1
            return checks < 3 ? .fail(255, "Connection closed by UNKNOWN port 65535") : .ok("ok\n")
        }
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(checks, 3)
        XCTAssertEqual(factory.machine.forceStops, 0)
    }

    /// A guest that never answers the check is not used: it fails at the
    /// boot deadline, saying what ssh said.
    func testANeverAnsweredIsolationCheckFailsClosed() async throws {
        runner.setHandler { call in
            CloudInit.isIsolationCheck(call.arguments.last) ? .fail(255, "Connection closed by UNKNOWN port 65535") : .ok()
        }
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.isFailed }
        guard case .failed(let message) = vm.state else { return XCTFail() }
        XCTAssertTrue(message.contains("Connection closed by UNKNOWN port 65535"), message)
        XCTAssertGreaterThanOrEqual(clock.totalSlept, 15 * 60)
        XCTAssertEqual(factory.machine.forceStops, 1)
    }

    /// A guest whose own vsock sshd answered before Monad's was set up (a
    /// first boot) is not ready yet: asked again until Monad's is up.
    func testAVMIsReadyOnlyOnceMonadsOwnSSHDServes() async throws {
        var checks = 0
        runner.setHandler { [ssh] call in
            if let r = ssh!.handle(call) { return r }
            if CloudInit.isIsolationCheck(call.arguments.last) {
                checks += 1
                return .ok(checks < 3 ? CloudInit.monadSSHDNotYet + "\n" : "ok\n")
            }
            return .ok()
        }
        let vm = try makeInstance()
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        XCTAssertEqual(checks, 3)
    }

    func testIsolationFailureFailsClosed() async throws {
        runner.setHandler { call in
            CloudInit.isIsolationCheck(call.arguments.last) ? .ok("tcp22-open\n") : .ok()
        }
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.isFailed }
        guard case .failed(let message) = vm.state else { return XCTFail() }
        XCTAssertTrue(message.lowercased().contains("isolation"), message)
        XCTAssertEqual(factory.machine.forceStops, 1, "an exposed guest must not stay up")
    }

    // MARK: Guest components

    private var agentInstalls: [FakeCommandRunner.Call] {
        runner.calls.filter { $0.arguments.last == CloudInit.guestInstallCommand }
    }

    func testAgentIsInstalledOrUpdatedOnEveryBoot() async throws {
        runner.setHandler { call in
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            if call.arguments.last == CloudInit.guestInstallCommand { return .ok("agent-ok\n") }
            return .ok()
        }
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        await assertEventually { vm.agentAvailable }
        let install = try XCTUnwrap(agentInstalls.first)
        let payload = String(decoding: try XCTUnwrap(install.stdin), as: UTF8.self)
        XCTAssertTrue(payload.contains(Data(try CloudInit.agentScript().utf8).base64EncodedString()),
                      "ships the bundled agent")
        XCTAssertTrue(payload.contains(Data(CloudInit.agentSocketUnit.utf8).base64EncodedString()),
                      "ships the vsock socket unit")
        XCTAssertTrue(payload.contains("monad-agent.socket"))

        await vm.stop()
        vm.start()
        await assertEventually { vm.state == .ready }
        await assertEventually { self.agentInstalls.count == 2 }
    }

    func testAgentInstallFailureKeepsVMUsable() async throws {
        runner.setHandler { call in
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            if call.arguments.last == CloudInit.guestInstallCommand { return .fail(1, "sudo: a password is required") }
            return .ok()
        }
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        await assertEventually { !self.agentInstalls.isEmpty }
        XCTAssertFalse(vm.agentAvailable)
        XCTAssertEqual(vm.state, .ready)
    }

    /// Right after a first boot ssh can fail to connect (status 255) while
    /// cloud-init still sets sshd up: the steps run once the VM is ready
    /// are tried again then; a real answer from the guest is final.
    func testAnAgentInstallWhoseSSHCannotConnectIsTriedAgain() async throws {
        var installs = 0
        runner.setHandler { [ssh] call in
            if let r = ssh!.handle(call) { return r }
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            if call.arguments.last == CloudInit.guestInstallCommand {
                installs += 1
                return installs < 3 ? .fail(255, "Connection closed by UNKNOWN port 65535") : .ok("agent-ok\n")
            }
            return .ok()
        }
        let vm = try makeInstance()
        vm.start()
        await assertEventually("\(installs) installs") { vm.agentAvailable }
        XCTAssertEqual(installs, 3)
    }

    func testAnAgentInstallTheGuestRefusesIsNotTriedAgain() async throws {
        runner.setHandler { call in
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            if call.arguments.last == CloudInit.guestInstallCommand { return .fail(1, "sudo: a password is required") }
            return .ok()
        }
        let vm = try makeInstance()
        vm.start()
        await assertEventually { !self.agentInstalls.isEmpty }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(agentInstalls.count, 1)
        XCTAssertFalse(vm.agentAvailable)
    }

    func testSharesWhoseSSHCannotConnectAreTriedAgainThenGivenUp() async throws {
        var runs = 0
        runner.setHandler { [ssh] call in
            if let r = ssh!.handle(call) { return r }
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            if call.arguments.last == GuestShares.command { runs += 1; return .fail(255, "") }
            return .ok()
        }
        let vm = try sharingVM([folder])
        vm.start()
        await assertEventually("\(runs) runs") { vm.sharesError != nil }
        XCTAssertEqual(runs, VMInstance.sshAttempts)
        XCTAssertTrue(vm.sharesError?.contains("255") ?? false, vm.sharesError ?? "")
    }

    func testSharesWhoseSSHConnectsOnASecondTryAreMounted() async throws {
        var runs = 0
        runner.setHandler { [ssh] call in
            if let r = ssh!.handle(call) { return r }
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            if call.arguments.last == GuestShares.command { runs += 1; return runs == 1 ? .fail(255, "") : .ok("shares-ok\n") }
            return .ok()
        }
        let vm = try sharingVM([folder])
        vm.start()
        await assertEventually { runs == 2 }
        await assertEventually { self.debugLogText.contains("shares: every folder is mounted") }
        XCTAssertNil(vm.sharesError)
    }

    private func agentReadyVM() throws -> VMInstance {
        runner.setHandler { [ssh] call in
            if let r = ssh!.handle(call) { return r }
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            if call.arguments.last == CloudInit.guestInstallCommand { return .ok("agent-ok\n") }
            return .ok()
        }
        return try makeInstance()
    }

    // MARK: Lima VMs

    /// A Lima VM does not start while Lima runs it, and Monad forgets the
    /// guest's host keys at each boot (Lima may have changed them).
    func testALimaVMWaitsForLimaAndForgetsHostKeys() async throws {
        let lima = tmp.url.appendingPathComponent("lima/default")
        try FileManager.default.createDirectory(at: lima, withIntermediateDirectories: true)
        try "vmType: vz\n".write(to: lima.appendingPathComponent("lima.yaml"), atomically: true, encoding: .utf8)
        try Data(count: 4096).write(to: lima.appendingPathComponent("diffdisk"))
        try "\(getpid())\n".write(to: lima.appendingPathComponent("ha.pid"), atomically: true, encoding: .utf8)
        let vm = try makeInstance { $0.attached = AttachedDisk(lima: "default", dir: lima.path) }
        vm.start()
        XCTAssertEqual(vm.state, .failed("Lima is running “default”. Stop it first with limactl stop default."))
        XCTAssertTrue(factory.made.isEmpty, "no machine was built")
        try FileManager.default.removeItem(at: lima.appendingPathComponent("ha.pid"))
        try "[old] ssh-ed25519 AAAAOLD\n".write(to: vm.paths.knownHosts, atomically: true, encoding: .utf8)
        vm.start()
        await assertEventually { vm.state == .ready }
        let known = (try? String(contentsOf: vm.paths.knownHosts, encoding: .utf8)) ?? ""
        XCTAssertFalse(known.contains("AAAAOLD"), "host keys from before are forgotten")
        let isolation = runner.calls.compactMap(\.arguments.last).filter { CloudInit.isIsolationCheck($0) }
        XCTAssertFalse(isolation.isEmpty)
        XCTAssertTrue(isolation.allSatisfy { $0.contains("mask --runtime --now") }, "Lima's sshd comes back at its next boot")
    }

    /// The release and the debug Monad never boot one Lima disk at once:
    /// each holds the lock in Lima's folder while its VM runs.
    func testALimaVMRunsInOneMonadAtATime() async throws {
        let lima = tmp.url.appendingPathComponent("lima/default")
        try FileManager.default.createDirectory(at: lima, withIntermediateDirectories: true)
        try "vmType: vz\n".write(to: lima.appendingPathComponent("lima.yaml"), atomically: true, encoding: .utf8)
        try Data(count: 4096).write(to: lima.appendingPathComponent("diffdisk"))
        let lockFile = LimaDisk.lockFile(in: lima)
        let vm = try makeInstance { $0.attached = AttachedDisk(lima: "default", dir: lima.path) }
        let other = try XCTUnwrap(try DiskLock.take(lockFile), "the other Monad runs it")
        vm.start()
        XCTAssertEqual(vm.state, .failed("Another Monad (the release or the debug build) is running the Lima VM “default”. "
                                         + "Shut it down there first."))
        XCTAssertTrue(factory.made.isEmpty, "no machine was built")
        other.release()
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertNil(try DiskLock.take(lockFile), "held while the VM runs")
        await vm.forceStop()
        XCTAssertEqual(vm.state, .stopped)
        XCTAssertNotNil(try DiskLock.take(lockFile), "free once it stopped")
    }

    // MARK: Forwards

    func testConfiguredForwardsComeUpWhenReady() async throws {
        let vm = try makeInstance { $0.forwards = [ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)] }
        vm.start()
        await assertEventually { vm.forwards.first?.state == .active }
        XCTAssertEqual(ssh.specs, ["127.0.0.1:8080:127.0.0.1:80"])
        XCTAssertEqual(watcher.watched, [4242], "the ssh master is supervised")
    }

    /// A bridge serves while the VM runs: its server on the Mac, its remote
    /// forward on the ssh master. It follows edits and stops with the VM.
    func testBridgesServeWhileTheVMRuns() async throws {
        let bridge = CommandBridge(name: "cat", command: ["/bin/cat"], guestPort: 9000)
        let off = CommandBridge(name: "off", command: ["/bin/cat"], guestPort: 9001, enabled: false)
        let vm = try makeInstance { $0.bridges = [bridge, off] }
        let spec = "127.0.0.1:9000:\(bridge.socket(in: vm.paths).path)"
        XCTAssertTrue(bridges.started.isEmpty, "nothing before the VM runs")
        vm.start()
        await assertEventually("specs \(ssh.specs)") { self.ssh.specs == [spec] }
        XCTAssertEqual(bridges.started, ["cat"], "a disabled bridge does not serve")
        await assertEventually { vm.forwards.first { $0.origin == .bridge }?.state == .active }

        var c = vm.config
        c.bridges = [off]
        try vm.update(c)
        await assertEventually("specs \(ssh.specs)") { self.ssh.specs.isEmpty }
        XCTAssertEqual(bridges.stopped, ["cat"])

        c.bridges = [bridge]
        try vm.update(c)
        await assertEventually("specs \(ssh.specs)") { self.ssh.specs == [spec] }
        await vm.stop()
        XCTAssertEqual(bridges.stopped, ["cat", "cat"], "stopped with the VM")
    }

    /// Host commands serve as bridges do: while the VM runs, enabled ones,
    /// reached by a remote forward, stopped when removed or with the VM.
    func testHostCommandsServeWhileTheVMRuns() async throws {
        let share = SharedFolder(hostPath: tmp.url.path, guestPath: "/home/dev/src", readOnly: false)
        var command = buildCommand(in: tmp.url.path)
        command.guestSocket = nil
        command.guestPort = 9100
        var off = command
        off.id = UUID()
        off.name = "off"
        off.guestPort = 9101
        off.enabled = false
        let vm = try makeInstance {
            $0.sharing = SharingSettings(runtimeEnabled: true, shares: [share])
            $0.hostCommands = [command, off]
        }
        let spec = "127.0.0.1:9100:\(command.socket(in: vm.paths).path)"
        vm.start()
        await assertEventually("specs \(ssh.specs)") { self.ssh.specs == [spec] }
        XCTAssertEqual(bridges.started, ["app-make"])
        XCTAssertEqual(bridges.homes, [vm.config.home], "runs land in the guest's exchange folder")
        XCTAssertEqual(vm.hostCommandServer(named: "app-make")?.command, command)
        XCTAssertNil(vm.hostCommandServer(named: "off"))

        var c = vm.config
        c.hostCommands = [off]
        try vm.update(c)
        await assertEventually("specs \(ssh.specs)") { self.ssh.specs.isEmpty }
        XCTAssertEqual(bridges.stopped, ["app-make"])
        c.hostCommands = [command]
        try vm.update(c)
        await assertEventually("specs \(ssh.specs)") { self.ssh.specs == [spec] }
        await vm.stop()
        XCTAssertEqual(bridges.stopped, ["app-make", "app-make"], "stopped with the VM")
    }

    /// A VM with a role: Monad's MCP endpoint serves while it runs, reached
    /// by a remote forward at its port, the guest told where and with which
    /// token; the role taken away, all of it goes, the token too.
    func testARoleBringsMonadsEndpointIntoTheVM() async throws {
        let endpoints = FakeEndpoints()
        let vm = try makeInstance(endpoints: endpoints) { $0.agents = AgentAccess(role: .orchestrator, guestPort: 7800) }
        let spec = "127.0.0.1:7800:\(vm.paths.mcpSocket.path)"
        vm.start()
        await assertEventually("specs \(ssh.specs)") { self.ssh.specs == [spec] }
        XCTAssertEqual(endpoints.started, [vm.paths.mcpSocket.path])
        let token = try String(contentsOf: vm.paths.mcpToken, encoding: .utf8)
        XCTAssertEqual(token.count, 64)
        XCTAssertEqual(endpoints.tokens, [token])
        await assertEventually { self.discoveryScripts.contains { $0.contains("MONAD_MCP_TOKEN='\(token)'") } }

        var c = vm.config
        c.agents = nil
        try vm.update(c)
        await assertEventually("specs \(ssh.specs)") { self.ssh.specs.isEmpty }
        XCTAssertEqual(endpoints.stopped, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vm.paths.mcpToken.path), "a new role gets a new token")
        await assertEventually { self.discoveryScripts.last?.contains("rm -f \"$HOME/.monad/mcp.env\"") ?? false }
    }

    private var discoveryScripts: [String] {
        runner.calls.filter { $0.arguments.last == GuestDiscovery.command }.map { String(decoding: $0.stdin ?? Data(), as: UTF8.self) }
    }

    /// A bridge whose server cannot listen is left out; the others serve.
    func testABridgeThatCannotListenIsLeftOut() async throws {
        let bad = CommandBridge(name: "bad", command: ["/bin/cat"], guestPort: 9000)
        let good = CommandBridge(name: "good", command: ["/bin/cat"], guestPort: 9001)
        bridges.failing = ["bad"]
        let vm = try makeInstance { $0.bridges = [bad, good] }
        vm.start()
        await assertEventually("specs \(ssh.specs)") { self.ssh.specs == ["127.0.0.1:9001:\(good.socket(in: vm.paths).path)"] }
        XCTAssertTrue(debugLogText.contains("bridge bad"), debugLogText)
    }

    func testGuestPortsAreAutoForwarded() async throws {
        let ch = SocketPairChannel()
        factory.machine.channels = [ch]
        let vm = try agentReadyVM()
        vm.start()
        await assertEventually { self.factory.machine.openedPorts == [1024] }
        ch.agentSays("hello monad-agent 1\nport+ tcp 0.0.0.0 8000\n")
        await assertEventually { self.ssh.specs == ["127.0.0.1:8000:127.0.0.1:8000"] }
        XCTAssertEqual(vm.forwards.map(\.origin), [.auto])
        ch.agentSays("port- tcp 0.0.0.0 8000\n")
        await assertEventually { self.ssh.specs.isEmpty && vm.forwards.isEmpty }
    }

    func testForwardsGoAwayWithTheVM() async throws {
        let vm = try makeInstance { $0.forwards = [ForwardRule(kind: .socks, hostPort: 1080)] }
        vm.start()
        await assertEventually { vm.forwards.first?.state == .active }
        await vm.stop()
        XCTAssertTrue(vm.forwards.isEmpty)
    }

    // MARK: Settings changes

    func testForwardsCanChangeWhileRunning() async throws {
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        var c = vm.config
        c.forwards = [ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)]
        try vm.update(c)
        await assertEventually { self.ssh.specs == ["127.0.0.1:8080:127.0.0.1:80"] }
        c.forwards = []
        try vm.update(c)
        await assertEventually { self.ssh.specs.isEmpty }
        XCTAssertEqual(vm.state, .ready)
        XCTAssertEqual(vm.pendingRestart, [])
        XCTAssertEqual(factory.machine.started, 1)
    }

    func testHardwareChangesApplyAtTheNextBoot() async throws {
        let vm = try makeInstance()
        factory.machine.macAddress = "52:54:00:aa:bb:cc"
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(vm.pendingRestart, [], "the MAC recorded at boot is not a change")
        var c = vm.config
        c.cpus += 1
        try vm.update(c)
        XCTAssertEqual(try InstanceConfig.load(from: vm.paths.config).cpus, c.cpus, "saved right away")
        XCTAssertEqual(vm.pendingRestart, ["CPUs"])
        XCTAssertEqual(factory.made.count, 1)
        await vm.stop()
        XCTAssertEqual(vm.pendingRestart, [])
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(factory.made.count, 2, "the machine is rebuilt with the new settings")
        XCTAssertEqual(factory.made.last?.config.cpus, c.cpus)
    }

    func testAnyChangeWhileStoppedRebuildsTheMachine() async throws {
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        await vm.stop()
        var c = vm.config
        c.sharing.shares = [SharedFolder(hostPath: NSTemporaryDirectory(), guestPath: "/mnt/tmp", readOnly: true)]
        try vm.update(c)
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(factory.made.count, 2)
        XCTAssertEqual(factory.made.last?.config.sharing.shares, c.sharing.shares)
    }

    func testMemoryTargetIsAppliedAtBootAndLive() async throws {
        let vm = try makeInstance {
            $0.memoryGiB = 4
            $0.memoryTargetGiB = 2
        }
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(factory.machine.memoryTargets, [2 << 30])
        var c = vm.config
        c.memoryTargetGiB = 3
        try vm.update(c)
        c.memoryTargetGiB = nil
        try vm.update(c)
        XCTAssertEqual(factory.machine.memoryTargets, [2 << 30, 3 << 30, 4 << 30], "no target: all of the boot memory")
        XCTAssertEqual(vm.pendingRestart, [])
    }

    func testNoMemoryTargetLeavesTheBalloonAlone() async throws {
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        var c = vm.config
        c.cpus += 1
        try vm.update(c)
        XCTAssertEqual(factory.machine.memoryTargets, [])
    }

    func testMemoryTargetNeverExceedsTheBootMemory() async throws {
        let vm = try makeInstance { $0.memoryGiB = 2 }
        vm.start()
        await assertEventually { vm.state == .ready }
        var c = vm.config
        c.memoryGiB = 4
        c.memoryTargetGiB = 3
        try vm.update(c)
        XCTAssertEqual(vm.pendingRestart, ["memory"])
        XCTAssertEqual(factory.machine.memoryTargets, [2 << 30], "clamped to what the VM booted with")
    }

    // MARK: Shared folders

    private var shareCalls: [String] {
        runner.calls.filter { $0.arguments.last == GuestShares.command }.map { String(decoding: $0.stdin ?? Data(), as: UTF8.self) }
    }

    private func answerShares(_ result: ProcessRunner.Result = .ok("shares-ok\n")) {
        runner.setHandler { [ssh] call in
            if let r = ssh!.handle(call) { return r }
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            if call.arguments.last == GuestShares.command { return result }
            return .ok()
        }
    }

    private func sharingVM(_ shares: [SharedFolder] = []) throws -> VMInstance {
        try makeInstance {
            $0.sharing.runtimeEnabled = true
            $0.sharing.shares = shares
        }
    }

    private var folder: SharedFolder {
        SharedFolder(hostPath: tmp.url.path, guestPath: "/home/dev/src", readOnly: true)
    }

    /// The guest's answers for the reboot tests: one boot ID per read (the
    /// last repeats), and how its isolation check goes.
    private final class Guest {
        var boots: [String]
        var isolation = "ok"
        private(set) var bootReads = 0
        init(boots: [String]) { self.boots = boots }
        func nextBoot() -> String {
            bootReads += 1
            return boots.count > 1 ? boots.removeFirst() : boots[0]
        }
    }

    private func rebootingGuest(_ guest: Guest) throws -> VMInstance {
        runner.setHandler { [ssh] call in
            if let r = ssh!.handle(call) { return r }
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok(guest.isolation + "\n") }
            if call.arguments.last == CloudInit.guestInstallCommand { return .ok("agent-ok\n") }
            if call.arguments.last == GuestShares.command { return .ok("shares-ok\n") }
            if call.arguments.last == VMInstance.bootIDCommand { return .ok(guest.nextBoot() + "\n") }
            return .ok()
        }
        return try sharingVM([folder])
    }

    private var isolationChecks: Int { runner.calls.filter { CloudInit.isIsolationCheck($0.arguments.last) }.count }

    /// A guest that reboots by itself (sudo reboot) stays ready on the Mac,
    /// but its mounts are gone: when its agent comes back from a new boot,
    /// Monad checks its isolation again and mounts its folders again.
    func testAGuestThatRebootsByItselfGetsItsSharedFoldersBack() async throws {
        let first = SocketPairChannel(), second = SocketPairChannel()
        factory.machine.channels = [first, second]
        let guest = Guest(boots: ["boot-1", "boot-2"])
        let vm = try rebootingGuest(guest)
        vm.start()
        await assertEventually { self.shareCalls.count == 1 && guest.bootReads == 1 }
        let checks = isolationChecks
        first.hangUp()
        await assertEventually("\(self.shareCalls.count) share runs") { self.shareCalls.count == 2 }
        XCTAssertEqual(isolationChecks, checks + 1)
        XCTAssertEqual(vm.state, .ready)
        XCTAssertTrue(debugLogText.contains("rebooted by itself"), debugLogText)
    }

    /// An agent that only reconnects (same boot) changes nothing.
    func testAnAgentReconnectingInTheSameBootMountsNothingAgain() async throws {
        let first = SocketPairChannel(), second = SocketPairChannel()
        factory.machine.channels = [first, second]
        let guest = Guest(boots: ["boot-1"])
        let vm = try rebootingGuest(guest)
        vm.start()
        await assertEventually { self.shareCalls.count == 1 && guest.bootReads == 1 }
        first.hangUp()
        await assertEventually { guest.bootReads == 2 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(shareCalls.count, 1)
        XCTAssertEqual(vm.state, .ready)
    }

    /// A guest that comes back from its own reboot with ssh on its network
    /// is powered off, as at boot.
    func testAGuestRebootedIntoAnExposedSSHIsPoweredOff() async throws {
        let first = SocketPairChannel(), second = SocketPairChannel()
        factory.machine.channels = [first, second]
        let guest = Guest(boots: ["boot-1", "boot-2"])
        let vm = try rebootingGuest(guest)
        vm.start()
        await assertEventually { vm.state == .ready && guest.bootReads == 1 }
        guest.isolation = "tcp22-open"
        first.hangUp()
        await assertEventually("\(vm.state)") { if case .failed = vm.state { return true } else { return false } }
        if case .failed(let why) = vm.state { XCTAssertTrue(why.contains("isolation"), why) }
    }

    /// The exchange folder: made on the Mac before the machine is, on the
    /// device, and mounted read-only at boot even without shares.
    func testTheExchangeFolderIsMadeAndMountedAtBoot() async throws {
        answerShares()
        let vm = try sharingVM()
        vm.start()
        await assertEventually { self.shareCalls.count == 1 }
        XCTAssertTrue(shareCalls[0].contains("\tro\t\(vm.config.home)/.monad/exchange\n"), shareCalls[0])
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: vm.paths.exchange.path, isDirectory: &isDir) && isDir.boolValue)
        let mode = try FileManager.default.attributesOfItem(atPath: vm.paths.exchange.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755, "readable in the guest; the VM's folder around it is the user's only")
    }

    func testSharesAreMountedWhenReady() async throws {
        answerShares()
        let vm = try sharingVM([folder])
        vm.start()
        await assertEventually { self.shareCalls.count == 1 }
        XCTAssertTrue(shareCalls[0].contains("\tro\t/home/dev/src\n"), shareCalls[0])
        XCTAssertTrue(shareCalls[0].contains("\nrebind=0\n"), "a fresh device at boot: nothing bound yet")
        XCTAssertNil(vm.sharesError)
    }

    func testSharesChangeWhileRunning() async throws {
        answerShares()
        let vm = try sharingVM()
        vm.start()
        await assertEventually { vm.state == .ready }
        await assertEventually { self.shareCalls.count == 1 }
        XCTAssertFalse(shareCalls[0].contains("/home/dev/src"), "only the exchange folder at boot")
        var c = vm.config
        c.sharing.shares = [folder]
        try vm.update(c)
        await assertEventually { self.shareCalls.count == 2 }
        XCTAssertEqual(factory.machine.shareSets, [c.deviceShares(paths: vm.paths)],
                       "the host share changes before the guest mounts")
        XCTAssertTrue(shareCalls[1].contains("/home/dev/src"))
        XCTAssertTrue(shareCalls[1].contains("\nrebind=1\n"), "a new folder list makes earlier binds stale")
        XCTAssertEqual(vm.pendingRestart, [])
    }

    /// Settings › Logs: what a change to a running VM did, step by step.
    func testChangesToARunningVMAreLogged() async throws {
        answerShares(.init(status: 1, stdout: Data("shares-failed: /home/dev/src: mount: boom\n".utf8),
                           stderr: Data("monad-shares: the shared folder device holds: \n".utf8)))
        let vm = try sharingVM()
        vm.start()
        await assertEventually { vm.state == .ready }
        var c = vm.config
        c.sharing.shares = [folder]
        c.memoryTargetGiB = 1
        try vm.update(c)
        await assertEventually { self.shareCalls.count == 2 }
        await assertEventually { self.debugLogText.contains("mount: boom).\n") && self.debugLogText.components(separatedBy: "mount: boom).").count == 3 }
        let t = debugLogText
        for line in ["vm unit: state stopped → starting", "vm unit: state booting → ready",
                     "vm unit: update while ready: memory target, shared folders",
                     "vm unit: memory: balloon target 1 GiB",
                     "vm unit: shares: the device now holds 2 folders",
                     "    | home-dev-src = \(tmp.url.path) (ro)",
                     "vm unit: shares: asking the guest to mount 2 folders",
                     "    | home-dev-src at /home/dev/src (ro)",
                     "vm unit: shares: the guest answered status 1",
                     "    | stdout: shares-failed: /home/dev/src: mount: boom",
                     "vm unit: shares: Could not mount in the guest: /home/dev/src (mount: boom)."] {
            XCTAssertTrue(t.contains(line), "missing “\(line)” in:\n\(t)")
        }
    }

    func testGuestMountFailureIsReported() async throws {
        answerShares(.init(status: 1, stdout: Data("shares-failed: /home/dev/src\n".utf8), stderr: Data()))
        let vm = try sharingVM([folder])
        vm.start()
        await assertEventually { vm.sharesError != nil }
        XCTAssertTrue(vm.sharesError?.contains("/home/dev/src") ?? false, vm.sharesError ?? "")
        XCTAssertEqual(vm.state, .ready, "the VM stays usable")
    }

    func testSharesWaitForTheSharingDevice() async throws {
        answerShares()
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        var c = vm.config
        c.sharing.runtimeEnabled = true
        c.sharing.shares = [folder]
        try vm.update(c)
        XCTAssertEqual(vm.pendingRestart, ["folder sharing"])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(factory.machine.shareSets, [])
        XCTAssertEqual(shareCalls, [], "no device, nothing to mount")
    }

    func testMissingMacFolderIsRefused() async throws {
        let vm = try sharingVM()
        var c = vm.config
        c.sharing.shares = [SharedFolder(hostPath: tmp.url.appendingPathComponent("nope").path, guestPath: "/mnt/x",
                                         readOnly: true)]
        XCTAssertThrowsError(try vm.update(c))
    }

    func testSettingsCannotChangeWhileTheVMIsBeingCreated() throws {
        // Provisioning writes the final config when it ends; an edit made
        // meanwhile would be silently lost.
        let vm = try makeInstance()
        vm.setPreparing("Downloading…")
        var c = vm.config
        c.theme = "grass"
        XCTAssertThrowsError(try vm.update(c))
    }

    func testProvisionedSettingsCannotChange() async throws {
        let vm = try makeInstance()
        var c = vm.config
        c.user = "root"
        XCTAssertThrowsError(try vm.update(c))
        vm.start()
        await assertEventually { vm.state == .ready }
        c = vm.config
        c.diskGiB += 10
        XCTAssertThrowsError(try vm.update(c))
        XCTAssertEqual(try InstanceConfig.load(from: vm.paths.config).diskGiB, vm.config.diskGiB)
    }

    func testNoMasterWithoutForwards() async throws {
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(runner.calls.contains { $0.executable == "/bin/sh" }, "nothing to forward, no master needed")
    }

    func testGuestPortsArePublishedThroughTheAgent() async throws {
        let ch = SocketPairChannel()
        factory.machine.channels = [ch]
        let vm = try agentReadyVM()
        vm.start()
        await assertEventually { vm.agentAvailable }
        await assertEventually { self.factory.machine.openedPorts == [1024] }
        ch.agentSays("hello monad-agent 1\nport+ tcp 0.0.0.0 8000\n")
        await assertEventually { vm.guestPorts == [ListeningPort(address: "0.0.0.0", port: 8000)] }
    }

    func testAgentReconnectsWhileRunning() async throws {
        let first = SocketPairChannel(), second = SocketPairChannel()
        factory.machine.channels = [first, second]
        let vm = try agentReadyVM()
        vm.start()
        await assertEventually { self.factory.machine.openedPorts.count == 1 }
        first.agentSays("port+ tcp 0.0.0.0 8000\n")
        await assertEventually { !vm.guestPorts.isEmpty }
        first.hangUp()
        await assertEventually { self.factory.machine.openedPorts.count == 2 }
        second.agentSays("port+ tcp 0.0.0.0 9000\n")
        await assertEventually { vm.guestPorts == [ListeningPort(address: "0.0.0.0", port: 9000)] }
    }

    func testAnAgentThatKeepsDroppingIsRetriedWithBackoff() async throws {
        let channels = (0..<6).map { _ in SocketPairChannel() }
        channels.forEach { $0.hangUp() } // accepts, then goes away at once
        factory.machine.channels = channels
        var opened: [TimeInterval] = []
        factory.machine.onOpen = { [clock] in opened.append(clock!.totalSlept) }
        let vm = try agentReadyVM()
        vm.start()
        await assertEventually { opened.count >= 6 }
        await vm.stop()
        let gaps = zip(opened.dropFirst(), opened).prefix(5).map { $0 - $1 }
        XCTAssertEqual(gaps, [1, 2, 4, 8, 16])
    }

    func testAgentStopsWithTheVM() async throws {
        let ch = SocketPairChannel()
        factory.machine.channels = [ch]
        let vm = try agentReadyVM()
        vm.start()
        await assertEventually { self.factory.machine.openedPorts.count == 1 }
        ch.agentSays("port+ tcp 0.0.0.0 8000\n")
        await assertEventually { !vm.guestPorts.isEmpty }
        await vm.stop()
        XCTAssertTrue(vm.guestPorts.isEmpty)
        await assertEventually { ch.closed }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(factory.machine.openedPorts.count, 1, "no reconnect after stop")
    }

    func testStartErrorFails() async throws {
        factory.machine.startError = TestError("no entitlement")
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.isFailed }
        XCTAssertEqual(vm.state, .failed("no entitlement"))
        XCTAssertNil(factory.machine.bridge)
    }

    func testBridgeErrorFailsAndPowersOff() async throws {
        factory.machine.bridgeError = TestError("socket path in use")
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.isFailed }
        guard case .failed(let message) = vm.state else { return XCTFail() }
        XCTAssertTrue(message.contains("socket path in use"))
        XCTAssertEqual(factory.machine.forceStops, 1)
    }

    func testUnknownDistroRefusesToStart() async throws {
        let paths = InstancePaths(name: "unit", root: tmp.url)
        let env = VMEnvironment(runner: runner, machines: factory, clock: clock, virtualizationSupported: true)
        var cfg = InstanceConfig.defaults(name: "unit")
        cfg.distro = "plan9"
        let vm = VMInstance(config: cfg, paths: paths, environment: env, guest: nil)
        vm.start()
        XCTAssertTrue(vm.isFailed)
        XCTAssertTrue(factory.made.isEmpty, "no machine for a guest Monad cannot secure")
    }

    func testUnsupportedHostFailsWithoutCreatingAMachine() async throws {
        let paths = InstancePaths(name: "unit", root: tmp.url)
        let env = VMEnvironment(runner: runner, machines: factory, clock: clock, virtualizationSupported: false)
        let vm = VMInstance(config: .defaults(name: "unit"), paths: paths, environment: env,
                            guest: .init(packageManager: "apt"))
        vm.start()
        XCTAssertTrue(vm.isFailed)
        XCTAssertTrue(factory.made.isEmpty)
    }

    func testStartIsIgnoredWhileRunning() async throws {
        let vm = try makeInstance()
        vm.start()
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(factory.machine.started, 1)
    }

    func testGeneratedMACIsPersisted() async throws {
        let vm = try makeInstance()
        factory.machine.macAddress = "52:54:00:aa:bb:cc"
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(vm.config.primaryMACAddress, "52:54:00:aa:bb:cc")
        XCTAssertEqual(try InstanceConfig.load(from: vm.paths.config).primaryMACAddress, "52:54:00:aa:bb:cc")
    }

    // MARK: Monad networks

    private func onMonadNetwork(_ attacher: FakeNetworkAttacher, network: String = "default") throws -> VMInstance {
        try makeInstance(networks: attacher) { $0.networks = [NetworkAttachment(network: network, macAddress: nil)] }
    }

    func testAVMOnAMonadNetworkIsAttachedThroughNetd() async throws {
        let attacher = FakeNetworkAttacher()
        let vm = try onMonadNetwork(attacher)
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(attacher.attached.count, 1)
        XCTAssertEqual(attacher.attached.first?.vm, "unit")
        XCTAssertEqual(attacher.attached.first?.network, "default")
        // The MAC netd binds the port to is chosen first, and kept.
        let mac = try XCTUnwrap(attacher.attached.first?.mac)
        XCTAssertEqual(vm.config.primaryMACAddress, mac)
        XCTAssertEqual(try InstanceConfig.load(from: vm.paths.config).primaryMACAddress, mac)
        XCTAssertEqual(factory.nics.count, 1)
        XCTAssertNotNil(factory.nics.first ?? nil)
    }

    func testAppleNATNeedsNoAttachment() async throws {
        let attacher = FakeNetworkAttacher()
        let vm = try makeInstance(networks: attacher)
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertTrue(attacher.attached.isEmpty)
        XCTAssertNil(factory.nics.first ?? nil)
    }

    func testAnAttachFailureFailsTheStart() async throws {
        let attacher = FakeNetworkAttacher()
        attacher.error = TestError("netd refused the port")
        let vm = try onMonadNetwork(attacher)
        vm.start()
        await assertEventually { vm.isFailed }
        XCTAssertTrue(factory.made.isEmpty)
        if case .failed(let message) = vm.state { XCTAssertTrue(message.contains("netd refused the port"), message) }
    }

    func testWithoutTheNetworkServiceAMonadNetworkFailsClosed() async throws {
        let vm = try makeInstance { $0.networks = [NetworkAttachment(network: "default", macAddress: nil)] }
        vm.start()
        await assertEventually { vm.isFailed }
        XCTAssertTrue(factory.made.isEmpty)
    }

    func testARestartKeepsTheAttachment() async throws {
        let attacher = FakeNetworkAttacher()
        let vm = try onMonadNetwork(attacher)
        vm.start()
        await assertEventually { vm.state == .ready }
        await vm.stop()
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(attacher.attached.count, 1)
        XCTAssertEqual(attacher.detached, 0)
    }

    func testANewMachineGetsANewAttachmentAndTheOldOneGoes() async throws {
        let attacher = FakeNetworkAttacher()
        let vm = try onMonadNetwork(attacher)
        vm.start()
        await assertEventually { vm.state == .ready }
        await vm.stop()
        var c = vm.config
        c.networks[0].network = "lab"
        try vm.update(c)
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(attacher.attached.map(\.network), ["default", "lab"])
        XCTAssertEqual(attacher.attached[0].mac, attacher.attached[1].mac) // the VM keeps its MAC
        XCTAssertEqual(attacher.detached, 1)
    }

    func testTheVMsFirewallGoesWithItsNIC() async throws {
        let attacher = FakeNetworkAttacher()
        let fw = VMFirewall(allowlist: true, rules: [FirewallRule(action: .allow, proto: .tcp, target: "*.github.com")],
                            tags: ["web"])
        let vm = try makeInstance(networks: attacher) {
            $0.networks = [NetworkAttachment(network: "default", macAddress: nil)]
            $0.firewall = fw
        }
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(attacher.attached.first?.firewall, fw)
    }

    /// A firewall edit reaches the running VM's NIC at once: no restart, and
    /// no new machine the next time it starts.
    func testFirewallEditsApplyLive() async throws {
        let attacher = FakeNetworkAttacher()
        let vm = try onMonadNetwork(attacher)
        vm.start()
        await assertEventually { vm.state == .ready }
        var c = vm.config
        c.firewall.allowLAN = true
        try vm.update(c)
        XCTAssertEqual(attacher.firewallUpdates, [c.firewall])
        XCTAssertEqual(vm.pendingRestart, [])
        try vm.update(c) // unchanged: nothing sent
        XCTAssertEqual(attacher.firewallUpdates.count, 1)
        await vm.stop()
        c.firewall.tags = ["web"]
        try vm.update(c) // stopped: its NIC is still netd's
        XCTAssertEqual(attacher.firewallUpdates.last, c.firewall)
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(attacher.attached.count, 1)
        XCTAssertEqual(factory.made.count, 1, "the same machine")
    }

    // MARK: Monitor mode

    private let googleAsk = FirewallAsk(id: 7, proto: .tcp, address: "142.250.1.2", port: 443, names: ["www.google.com"])

    private func runningMonitored(_ attacher: FakeNetworkAttacher) async throws -> (VMInstance, NICAttachment) {
        let vm = try makeInstance(networks: attacher) {
            $0.networks = [NetworkAttachment(network: "default", macAddress: nil)]
            $0.firewall = VMFirewall(monitor: true, tags: ["Web"])
        }
        vm.start()
        await assertEventually { vm.state == .ready }
        return (vm, try XCTUnwrap(attacher.lastNIC))
    }

    private func tagStore() -> FirewallTagStore {
        FirewallTagStore(directory: tmp.url.appendingPathComponent("tags"))
    }

    func testQuestionsWaitOnTheVMUntilAnswered() async throws {
        let attacher = FakeNetworkAttacher()
        let (vm, nic) = try await runningMonitored(attacher)
        nic.ask(googleAsk)
        nic.ask(FirewallAsk(id: 8, proto: .tcp, address: "142.250.1.2", port: 443, names: [])) // asked again: once
        XCTAssertEqual(vm.firewallAsks, [googleAsk])
        try vm.answerFirewall(FirewallAnswer(askID: 7, decision: .allowUntilStop, target: .name("google.com"), scope: .vm),
                              tags: tagStore())
        XCTAssertEqual(attacher.sessionRules, [FirewallRule(action: .allow, proto: .tcp, target: "google.com", ports: 443...443)])
        XCTAssertEqual(vm.firewallAsks, [])
        XCTAssertEqual(vm.config.firewall.rules, [], "until the VM stops: saved nowhere")
        XCTAssertThrowsError(try vm.answerFirewall(FirewallAnswer(askID: 7, decision: .allow, target: .address, scope: .vm),
                                                   tags: tagStore()), "answered already")
    }

    func testALastingAnswerIsSavedOnTheVMOrATag() async throws {
        let attacher = FakeNetworkAttacher()
        let (vm, nic) = try await runningMonitored(attacher)
        let tags = tagStore()
        try tags.save(FirewallTag(name: "Web", rules: []))
        nic.ask(googleAsk)
        let second = FirewallAsk(id: 9, proto: .udp, address: "8.8.8.8", port: 53, names: [])
        nic.ask(second)
        try vm.answerFirewall(FirewallAnswer(askID: 7, decision: .block, target: .name("google.com"), scope: .tag("Web")),
                              tags: tags)
        let deny = FirewallRule(action: .deny, proto: .tcp, target: "google.com", ports: 443...443)
        XCTAssertEqual(try tags.tag(named: "Web")?.rules, [deny])
        XCTAssertEqual(attacher.sessionRules, [deny], "applies at once too")
        try vm.answerFirewall(FirewallAnswer(askID: 9, decision: .allow, target: .address, scope: .vm), tags: tags)
        let allow = FirewallRule(action: .allow, proto: .udp, target: "8.8.8.8/32", ports: 53...53)
        XCTAssertEqual(vm.config.firewall.rules, [allow])
        XCTAssertEqual(try InstanceConfig.load(from: vm.paths.config).firewall.rules, [allow])
        XCTAssertEqual(vm.firewallAsks, [])
        // A tag the VM does not carry is not a place for its answers.
        nic.ask(googleAsk)
        XCTAssertThrowsError(try vm.answerFirewall(FirewallAnswer(askID: 7, decision: .allow, target: .address,
                                                                  scope: .tag("Other")), tags: tags))
        XCTAssertEqual(vm.firewallAsks, [googleAsk], "still to answer")
    }

    /// One answer settles every question it covers.
    func testAnAnswerSettlesTheQuestionsItCovers() async throws {
        let attacher = FakeNetworkAttacher()
        let (vm, nic) = try await runningMonitored(attacher)
        nic.ask(googleAsk)
        nic.ask(FirewallAsk(id: 8, proto: .tcp, address: "142.250.9.9", port: 443, names: ["mail.google.com"]))
        nic.ask(FirewallAsk(id: 9, proto: .tcp, address: "1.1.1.1", port: 443, names: []))
        try vm.answerFirewall(FirewallAnswer(askID: 7, decision: .allowUntilStop, target: .name("google.com"), scope: .vm),
                              tags: tagStore())
        XCTAssertEqual(vm.firewallAsks.map(\.id), [9])
    }

    func testStoppingForgetsTheSession() async throws {
        let attacher = FakeNetworkAttacher()
        let (vm, nic) = try await runningMonitored(attacher)
        nic.ask(googleAsk)
        await vm.stop()
        XCTAssertEqual(vm.firewallAsks, [])
        XCTAssertEqual(attacher.forgotten, 1)
    }

    /// A guest cannot pile up questions.
    func testQuestionsAreBounded() async throws {
        let attacher = FakeNetworkAttacher()
        let (vm, nic) = try await runningMonitored(attacher)
        for i in 0..<(VMInstance.maxFirewallAsks + 10) {
            nic.ask(FirewallAsk(id: UInt64(i), proto: .udp, address: "8.8.8.\(i % 250)", port: 1000 + i, names: []))
        }
        XCTAssertEqual(vm.firewallAsks.count, VMInstance.maxFirewallAsks)
    }

    func testDiscardingTheVMReleasesItsAttachment() async throws {
        let attacher = FakeNetworkAttacher()
        let vm = try onMonadNetwork(attacher)
        vm.start()
        await assertEventually { vm.state == .ready }
        await vm.stop()
        vm.discardMachine()
        XCTAssertEqual(attacher.detached, 1)
    }

    // MARK: Profiles

    private let markProfile = ProfileConfig(id: "mark", name: "Mark", summary: "", steps: [
        ProfileConfig.Step(id: "one", title: "One", npm: ["x"]),
        ProfileConfig.Step(id: "two", title: "Two", npm: ["y"]),
    ])
    private let doneOutput = "@@monad step one start\nadded 1 package\n@@monad step one done\n@@monad step two start\n"
        + "@@monad step two done\n@@monad finished\n"

    private func profiled(_ ids: [String]) throws -> VMInstance {
        try makeInstance(profiles: ProfileCatalog(builtIn: [markProfile], custom: [])) { $0.profiles = ids }
    }

    /// The guest answers profile scripts with `output` and `status`.
    private func answerProfiles(_ output: String, status: Int32 = 0) {
        runner.setHandler { [ssh] call in
            if let r = ssh!.handle(call) { return r }
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            if call.arguments.last == VMInstance.profileCommand {
                return ProcessRunner.Result(status: status, stdout: Data(output.utf8), stderr: Data())
            }
            return .ok()
        }
    }

    private var profileCalls: [FakeCommandRunner.Call] { runner.sshCalls(runningRemote: VMInstance.profileCommand) }

    func testChosenProfilesRunOnceTheVMIsReadyAndOnlyOnce() async throws {
        answerProfiles(doneOutput)
        let vm = try profiled(["mark"])
        vm.start()
        await assertEventually { vm.profileRuns.first?.state == .done }
        let run = try XCTUnwrap(vm.profileRuns.first)
        XCTAssertEqual(run.name, "Mark")
        XCTAssertEqual(run.steps.map(\.state), [.done, .done])
        XCTAssertEqual(run.log, ["added 1 package"], "markers are not log lines")
        let script = String(decoding: try XCTUnwrap(profileCalls.first?.stdin), as: UTF8.self)
        XCTAssertTrue(script.contains("@@monad step one start"), "the rendered script goes to sudo sh in the guest")
        XCTAssertTrue(script.contains("MONAD_USER='\(vm.config.user)'"))
        // Recorded: the next boot does not run it again.
        await vm.stop()
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(profileCalls.count, 1)
    }

    func testAFailedStepIsReportedAndTriedAgainNextBoot() async throws {
        answerProfiles("@@monad step one start\nE: broken packages\n@@monad step one failed apt-get install failed\n", status: 1)
        let vm = try profiled(["mark"])
        vm.start()
        await assertEventually { vm.profileRuns.first?.state == .failed }
        let run = try XCTUnwrap(vm.profileRuns.first)
        XCTAssertEqual(run.message, "apt-get install failed")
        XCTAssertEqual(run.steps.map(\.state), [.failed, .waiting])
        XCTAssertEqual(run.log, ["E: broken packages"])
        await vm.stop()
        answerProfiles(doneOutput)
        vm.start()
        await assertEventually { vm.profileRuns.first?.state == .done }
        XCTAssertEqual(profileCalls.count, 2)
    }

    func testAScriptThatDiesWithoutAMarkerFails() async throws {
        answerProfiles("@@monad step one start\n", status: 255)
        let vm = try profiled(["mark"])
        vm.start()
        await assertEventually { vm.profileRuns.first?.state == .failed }
        XCTAssertEqual(vm.profileRuns.first?.message, "The setup ended early (status 255).")
    }

    func testProfilesRunOnDemandEvenIfApplied() async throws {
        answerProfiles(doneOutput)
        let vm = try profiled([])
        XCTAssertThrowsError(try vm.runProfiles(["mark"]), "not while stopped")
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(profileCalls.count, 0)
        try vm.runProfiles(["mark"])
        await assertEventually { vm.profileRuns.first?.state == .done }
        try vm.runProfiles(["mark"])
        await assertEventually { self.profileCalls.count == 2 }
        XCTAssertThrowsError(try vm.runProfiles(["nope"]))
    }

    func testAProfileAddedToARunningVMRunsAtOnce() async throws {
        answerProfiles(doneOutput)
        let vm = try profiled([])
        vm.start()
        await assertEventually { vm.state == .ready }
        var c = vm.config
        c.profiles = ["mark"]
        try vm.update(c)
        await assertEventually { vm.profileRuns.first?.state == .done }
    }

    func testAProfileForAnotherPackageManagerIsRefused() async throws {
        let aptOnly = ProfileConfig(id: "apt-only", name: "Apt only", summary: "",
                                    steps: [ProfileConfig.Step(id: "p", title: "P", packages: ["apt": ["git"]])])
        let vm = try makeInstance(guest: DistroConfig.GuestProfile(packageManager: "dnf"),
                                  profiles: ProfileCatalog(builtIn: [aptOnly], custom: []))
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertThrowsError(try vm.runProfiles(["apt-only"]))
    }

    /// Stop ends the running profile's whole process group in the guest (it
    /// runs under setsid and says its id first) and drops what was waiting.
    func testAProfileRunCanBeStopped() async throws {
        let release = DispatchSemaphore(value: 0)
        answerProfiles(doneOutput)
        runner.setStreamHandler { call, emit in
            guard call.arguments.last == VMInstance.profileCommand else { return nil }
            emit("@@monad pid 4242")
            emit("@@monad step one start")
            release.wait() // the script runs until it is killed
            return ProcessRunner.Result(status: 143, stdout: Data(), stderr: Data())
        }
        let other = ProfileConfig(id: "other", name: "Other", summary: "", steps: [.init(id: "o", title: "O", npm: ["z"])])
        let vm = try makeInstance(profiles: ProfileCatalog(builtIn: [markProfile, other], custom: [])) { $0.profiles = ["mark", "other"] }
        vm.start()
        await assertEventually { vm.profileRuns.first?.state == .running && vm.profileRuns.first?.steps.first?.state == .running }
        // -w: if setsid has to fork (it runs as a group leader), it waits and passes the status on.
        XCTAssertEqual(VMInstance.profileCommand, "sudo -n setsid -w sh -s monad-profile")
        vm.stopProfiles()
        await assertEventually { !self.runner.sshCalls(runningRemote: "sudo -n kill -TERM -- -4242").isEmpty }
        XCTAssertEqual(vm.profileRuns.last?.state, .failed, "the waiting one is dropped")
        XCTAssertEqual(vm.profileRuns.last?.message, "Stopped.")
        release.signal()
        await assertEventually { vm.profileRuns.first?.state == .failed }
        XCTAssertEqual(vm.profileRuns.first?.message, "Stopped.")
        XCTAssertEqual(profileCalls.count, 1, "other never ran")
        XCTAssertNil(AppliedProfiles.load(vm.paths.appliedProfiles).applied["mark"])
    }

    /// The page keeps the last lines, the VM's folder the whole output, per
    /// profile, from the latest run.
    func testTheWholeOutputIsKeptInALogFile() async throws {
        var out = "@@monad pid 77\n@@monad step one start\n"
        for i in 0..<100 { out += "line \(i)\n" }
        answerProfiles(out + "@@monad step one done\n@@monad step two start\n@@monad step two done\n@@monad finished\n")
        let vm = try profiled(["mark"])
        vm.start()
        await assertEventually { vm.profileRuns.first?.state == .done }
        let url = vm.paths.profileLog("mark")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\nline 0\n") && text.contains("\nline 99\n"), text)
        XCTAssertTrue(text.contains("@@monad step two done\n"), "with the steps")
        XCTAssertFalse(text.contains("@@monad pid"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)

        answerProfiles(doneOutput)
        try vm.runProfiles(["mark"])
        await assertEventually { vm.profileRuns.first?.state == .done && vm.profileRuns.first?.log == ["added 1 package"] }
        let again = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(again.contains("line 99"), "a new run, a new log")
        XCTAssertTrue(again.contains("added 1 package\n"))
    }

    func testTheLogFileIsBounded() throws {
        let url = tmp.url.appendingPathComponent("bounded.log")
        var log = ProfileLogFile(url: url, limit: 64)
        log.start()
        for i in 0..<20 { log.append("line \(i)") }
        log.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("line 0\n"), text)
        XCTAssertTrue(text.hasSuffix("[The log stops here: it reached its size limit.]\n"), text)
        XCTAssertLessThanOrEqual(text.utf8.count, 64 + 60)
        log.start()
        log.append("fresh")
        log.close()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "fresh\n")
    }

    func testTheLogKeepsTheLastLines() {
        var run = ProfileRun(profile: markProfile)
        for i in 0..<100 { run.apply("line \(i)") }
        XCTAssertEqual(run.log.count, ProfileRun.logLines)
        XCTAssertEqual(run.log.last, "line 99")
        run.apply(String(repeating: "x", count: 10_000))
        XCTAssertLessThanOrEqual(run.log.last?.count ?? 0, 300)
        run.apply("@@monad step two start")
        XCTAssertEqual(run.steps.map(\.state), [.waiting, .running])
        XCTAssertEqual(run.state, .running)
        run.apply("@@monad step nope start")
        XCTAssertEqual(run.steps.map(\.state), [.waiting, .running], "unknown steps change nothing")
    }

    // MARK: Runtime events

    func testGuestCrashFailsAndClosesBridge() async throws {
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        factory.machine.emit(.failed("guest panicked"))
        XCTAssertEqual(vm.state, .failed("guest panicked"))
        XCTAssertEqual(factory.machine.bridgeStopped, 1)
    }

    /// A machine that ended in an error (a guest crash, a failed boot) is
    /// not started again: Virtualization refuses ("cannot be started in its
    /// current state") and every retry failed at once. A new one is built.
    func testAMachineThatCannotStartAgainIsRebuilt() async throws {
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        factory.machine.emit(.failed("guest panicked"))
        factory.machine.canStart = false
        let old = factory.machine
        factory.machine = FakeVM()
        vm.start()
        await assertEventually("state: \(vm.state)") { vm.state == .ready }
        XCTAssertEqual(old.started, 1, "the old machine is not asked again")
        XCTAssertEqual(factory.machine.started, 1)
        XCTAssertTrue(debugLogText.contains("start: rebuilding the machine (the last one cannot start again)"), debugLogText)
    }

    func testGuestPowerOffStops() async throws {
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        factory.machine.emit(.stopped)
        XCTAssertEqual(vm.state, .stopped)
        XCTAssertEqual(factory.machine.bridgeStopped, 1)
    }

    private func vmLog(_ vm: VMInstance) -> String {
        vm.log.flush()
        return (try? String(contentsOf: vm.paths.vmLog, encoding: .utf8)) ?? ""
    }

    /// Every stop says why in the VM's log: the guest powering itself off, a
    /// shutdown Monad asked for, Monad powering it off, or an error from
    /// Virtualization. A VM once went from booting to stopped with no word.
    func testEveryStopSaysWhy() async throws {
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        factory.machine.emit(.stopped)
        XCTAssertTrue(vmLog(vm).contains("machine: the guest powered itself off (Monad did not ask it to)"), vmLog(vm))

        vm.start()
        await assertEventually { vm.state == .ready }
        await vm.stop()
        XCTAssertTrue(vmLog(vm).contains("machine: the guest shut down as asked"), vmLog(vm))

        vm.start()
        await assertEventually { vm.state == .ready }
        factory.machine.stopsGracefully = false
        await vm.stop(timeout: 20)
        XCTAssertTrue(vmLog(vm).contains("machine: powered off by Monad"), vmLog(vm))

        factory.machine.stopsGracefully = true
        vm.start()
        await assertEventually { vm.state == .ready }
        factory.machine.emit(.failed("guest panicked"))
        XCTAssertTrue(vmLog(vm).contains("machine: Virtualization stopped it with an error: guest panicked"), vmLog(vm))
    }

    /// While its machine runs, a VM has a mark in its folder, gone once the
    /// machine has stopped, however it stopped. A MonadHost that finds one
    /// at its start knows the VM was never shut down (VMManager.load).
    func testARunningMachineLeavesAMarkUntilItStops() async throws {
        let vm = try makeInstance()
        let mark = vm.paths.runningMark.path
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertTrue(FileManager.default.fileExists(atPath: mark))
        await vm.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: mark), "a shutdown")

        vm.start()
        await assertEventually { vm.state == .ready }
        factory.machine.emit(.failed("guest panicked"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mark), "an error")

        factory.machine.canStart = false
        factory.machine = FakeVM()
        factory.machine.probeAnswers = [false]
        vm.start()
        await assertEventually { vm.isFailed }
        XCTAssertFalse(FileManager.default.fileExists(atPath: mark), "a boot that never answered, powered off")

        factory.machine.canStart = false
        factory.machine = FakeVM()
        factory.machine.startError = TestError("no memory")
        vm.start()
        await assertEventually { vm.isFailed }
        XCTAssertFalse(FileManager.default.fileExists(atPath: mark), "never started")
    }

    // MARK: Stop

    func testGracefulStop() async throws {
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        await vm.stop()
        XCTAssertEqual(vm.state, .stopped)
        XCTAssertEqual(factory.machine.stopRequests, 1)
        XCTAssertEqual(factory.machine.forceStops, 0)
    }

    func testStopClosesSSHMasterWhenPresent() async throws {
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        FileManager.default.createFile(atPath: vm.paths.controlSocket.path, contents: nil)
        await vm.stop()
        XCTAssertTrue(runner.calls.contains { $0.arguments.contains("-O") && $0.arguments.contains("exit") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: vm.paths.controlSocket.path))
    }

    func testStopPowersOffAfterTimeout() async throws {
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        factory.machine.stopsGracefully = false
        await vm.stop(timeout: 20)
        XCTAssertEqual(vm.state, .stopped)
        XCTAssertEqual(factory.machine.forceStops, 1)
        XCTAssertEqual(clock.totalSlept, 20, accuracy: 0.5, "waited the full timeout before powering off")
    }

    func testStopRequestErrorFallsBackToPowerOff() async throws {
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        factory.machine.requestStopError = TestError("still in firmware")
        await vm.stop()
        XCTAssertEqual(vm.state, .stopped)
        XCTAssertEqual(factory.machine.forceStops, 1)
    }

    func testStopDuringBootCancelsReadiness() async throws {
        clock = TestClock(realDelay: 0.002) // keep the poll loop alive long enough to interrupt
        let vm = try makeInstance()
        factory.machine.probeAnswers = [false]
        vm.start()
        await assertEventually { vm.state == .booting }
        await vm.stop()
        XCTAssertEqual(vm.state, .stopped)
        let probesAtStop = factory.machine.probes
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(factory.machine.probes, probesAtStop, "no polling after stop")
        XCTAssertEqual(vm.state, .stopped)
    }

    func testRestartAfterStopReusesMachine() async throws {
        let vm = try makeInstance()
        vm.start()
        await assertEventually { vm.state == .ready }
        await vm.stop()
        vm.start()
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertEqual(factory.machine.started, 2)
    }
}
