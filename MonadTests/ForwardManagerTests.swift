//
//  ForwardManagerTests.swift — which forwards a VM should have (configured
//  rules plus auto-forwarded guest ports) and keeping its ssh master in line
//  with that, including when the master dies.
//

import XCTest
@testable import Monad

final class ForwardPlanTests: XCTestCase {
    private func port(_ a: String, _ p: Int) -> ListeningPort { ListeningPort(address: a, port: p) }

    func testAutoForwardsListeningPortsAboveTheMinimum() {
        let plan = ForwardPlan(configured: [], autoForward: AutoForwardSettings(ignoredPorts: [5432]),
                               ports: [port("0.0.0.0", 8000), port("127.0.0.1", 5000), port("0.0.0.0", 22),
                                       port("0.0.0.0", 5432), port("192.168.64.9", 9000), port("127.0.0.53", 53)])
        XCTAssertEqual(plan.forwards.map(\.spec.value).sorted(),
                       ["127.0.0.1:5000:127.0.0.1:5000", "127.0.0.1:8000:127.0.0.1:8000"])
        XCTAssertTrue(plan.forwards.allSatisfy { $0.origin == .auto })
    }

    /// A bridge's remote forward is planned; its guest port (and that of a
    /// forward into the Mac) is never auto-forwarded back to the Mac, where
    /// it would put a Mac command, or a Mac service, on a TCP port.
    func testBridgesAreForwardedAndNeverAutoForwardedBack() {
        let bridge = ForwardPlan.Bridge(spec: SSHMux.Spec(flag: "-R", value: "127.0.0.1:9000:/x/bridge-1.sock"), guestPort: 9000)
        let remote = ForwardRule(kind: .remote, hostPort: 5432, guestPort: 7000)
        let plan = ForwardPlan(configured: [remote], autoForward: AutoForwardSettings(),
                               ports: [port("127.0.0.1", 9000), port("127.0.0.1", 7000), port("0.0.0.0", 8000)],
                               bridges: [bridge])
        XCTAssertEqual(plan.forwards.map(\.spec.value),
                       ["127.0.0.1:7000:127.0.0.1:5432", "127.0.0.1:9000:/x/bridge-1.sock", "127.0.0.1:8000:127.0.0.1:8000"])
        XCTAssertEqual(plan.forwards.map(\.origin), [.configured, .bridge, .auto])
    }

    func testDualStackPortIsForwardedOnce() {
        let plan = ForwardPlan(configured: [], autoForward: AutoForwardSettings(),
                               ports: [port("0.0.0.0", 3000), port("::", 3000), port("::1", 4000)])
        XCTAssertEqual(plan.forwards.map(\.spec.value).sorted(),
                       ["127.0.0.1:3000:127.0.0.1:3000", "127.0.0.1:4000:[::1]:4000"])
    }

    func testConfiguredRulesWinOverAutoForwards() {
        let rule = ForwardRule(kind: .local, hostPort: 8000, guestPort: 80)
        let plan = ForwardPlan(configured: [rule], autoForward: AutoForwardSettings(), ports: [port("0.0.0.0", 8000)])
        XCTAssertEqual(plan.forwards.map(\.spec.value), ["127.0.0.1:8000:127.0.0.1:80"])
        XCTAssertEqual(plan.forwards.first?.origin, .configured)
    }

    func testDisabledRulesAndDisabledAutoForwarding() {
        var off = ForwardRule(kind: .local, hostPort: 9000, guestPort: 90)
        off.enabled = false
        let plan = ForwardPlan(configured: [off], autoForward: AutoForwardSettings(enabled: false),
                               ports: [port("0.0.0.0", 8000)])
        XCTAssertTrue(plan.forwards.isEmpty)
    }

    func testAutoForwardsAreCappedLowestPortsFirst() {
        let rule = ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)
        let plan = ForwardPlan(configured: [rule], autoForward: AutoForwardSettings(),
                               ports: Set((0..<5000).map { port("0.0.0.0", 10000 + $0) }))
        XCTAssertEqual(ForwardPlan.maxAutoForwards, 32)
        let auto = plan.forwards.filter { $0.origin == .auto }.compactMap(\.macPort)
        XCTAssertEqual(auto.count, 32)
        XCTAssertEqual(auto.first, 10000)
        XCTAssertEqual(auto.last, 10031)
        XCTAssertEqual(plan.forwards.filter { $0.origin == .configured }.count, 1, "configured forwards do not count")
        XCTAssertEqual(plan.overLimit, 4968)
    }

    func testSkippedPortsDoNotCountTowardsTheLimit() {
        let plan = ForwardPlan(configured: [], autoForward: AutoForwardSettings(ignoredPorts: [2000]),
                               ports: Set([port("0.0.0.0", 22), port("0.0.0.0", 2000)] + (0..<32).map { port("0.0.0.0", 3000 + $0) }))
        XCTAssertEqual(plan.forwards.count, 32)
        XCTAssertEqual(plan.overLimit, 0)
    }
}

/// Answers ssh control commands like a master that can be killed.
private final class FakeSSH: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32 = 0
    private var nextPID: Int32 = 100
    private(set) var active: [String] = []
    var busyHostPorts: Set<String> = []
    /// Programs listening on a Mac port (on any address), as lsof reports them.
    var listeners: [Int: [String]] = [:]
    var masterStartFails = false

    var masterPID: Int32 { lock.withLock { pid } }
    var activeSpecs: [String] { lock.withLock { active } }

    func kill() { lock.withLock { pid = 0; active = [] } }

    func handle(_ call: FakeCommandRunner.Call) -> ProcessRunner.Result {
        lock.withLock {
            if call.executable == "/bin/sh" {
                if masterStartFails { return .fail(255, "") }
                pid = nextPID
                nextPID += 1
                return .ok()
            }
            let args = call.arguments
            if call.executable == "/usr/sbin/lsof" {
                // -iTCP:<port>[,<port>…] -Fcn: a "p", "c", "f", "n" line per socket.
                let ports = (args.first { $0.hasPrefix("-iTCP:") }?.dropFirst(6) ?? "").split(separator: ",")
                    .compactMap { Int($0) }
                var out = ""
                for port in ports {
                    for (i, name) in (listeners[port] ?? []).enumerated() {
                        out += "p\(500 + i)\nc\(name)\nf3\nn*:\(port)\nf4\nn[::]:\(port)\n"
                    }
                }
                return out.isEmpty ? .fail(1) : .ok(out)
            }
            guard let o = args.firstIndex(of: "-O") else { return .fail(255, "unexpected") }
            switch args[o + 1] {
            case "check":
                return pid > 0 ? .init(status: 0, stdout: Data(), stderr: Data("Master running (pid=\(pid))\r\n".utf8))
                               : .fail(255, "Control socket connect: No such file or directory")
            case "forward":
                guard pid > 0 else { return .fail(255, "Control socket connect: No such file or directory") }
                let spec = args[o + 3]
                if busyHostPorts.contains(where: { spec.hasPrefix($0) }) { return .fail(255, "Port forwarding failed.") }
                active.append(spec)
                return .ok()
            case "cancel":
                active.removeAll { $0 == args[o + 3] }
                return .ok()
            default:
                return .ok()
            }
        }
    }
}

/// Lets a test say "the master process exited".
@MainActor
private final class FakeWatcher: ProcessExitWatching {
    private(set) var watched: [Int32] = []
    private var handlers: [Int32: () -> Void] = [:]

    func watch(pid: Int32, onExit: @escaping @MainActor () -> Void) -> ProcessWatch {
        watched.append(pid)
        handlers[pid] = onExit
        return ProcessWatch { [weak self] in self?.handlers[pid] = nil }
    }

    func exit(_ pid: Int32) { handlers.removeValue(forKey: pid)?() }
}

@MainActor
final class ForwardManagerTests: XCTestCase {
    private var ssh: FakeSSH!
    private var watcher: FakeWatcher!
    private var clock: TestClock!
    private var manager: ForwardManager!
    private var runner: FakeCommandRunner!
    private let paths = InstancePaths(name: "dev", root: URL(fileURLWithPath: "/tmp/monad-test"))

    override func setUp() async throws {
        ssh = FakeSSH()
        watcher = FakeWatcher()
        clock = TestClock()
        runner = FakeCommandRunner { [ssh] call in ssh!.handle(call) }
        manager = ForwardManager(mux: SSHMux(paths: paths, host: "monad-dev", options: CloudInit.sshArguments(config: InstanceConfig.defaults(name: "dev"), paths: paths)), runner: runner, watcher: watcher,
                                 clock: clock)
    }

    private func port(_ a: String, _ p: Int) -> ListeningPort { ListeningPort(address: a, port: p) }

    private func state(_ spec: String) -> ForwardStatus.State? {
        manager.statuses.first { $0.spec == spec }?.state
    }

    func testStartsTheMasterAndAddsForwards() async {
        await manager.apply(configured: [ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)],
                            autoForward: AutoForwardSettings(), ports: [port("0.0.0.0", 3000)])
        XCTAssertEqual(ssh.masterPID, 100)
        XCTAssertEqual(Set(ssh.activeSpecs), ["127.0.0.1:8080:127.0.0.1:80", "127.0.0.1:3000:127.0.0.1:3000"])
        XCTAssertEqual(state("127.0.0.1:8080:127.0.0.1:80"), .active)
        XCTAssertEqual(watcher.watched, [100], "the master is supervised")
    }

    func testRemovedAndClosedForwardsAreCancelled() async {
        let rule = ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)
        await manager.apply(configured: [rule], autoForward: AutoForwardSettings(), ports: [port("0.0.0.0", 3000)])
        await manager.apply(configured: [], autoForward: AutoForwardSettings(), ports: [])
        XCTAssertEqual(ssh.activeSpecs, [])
        XCTAssertTrue(manager.statuses.isEmpty)
    }

    func testABusyHostPortFailsOnlyThatForward() async {
        ssh.busyHostPorts = ["127.0.0.1:3000:"]
        await manager.apply(configured: [], autoForward: AutoForwardSettings(),
                            ports: [port("0.0.0.0", 3000), port("0.0.0.0", 4000)])
        XCTAssertEqual(state("127.0.0.1:3000:127.0.0.1:3000"), .failed("Port forwarding failed."))
        XCTAssertEqual(state("127.0.0.1:4000:127.0.0.1:4000"), .active)
        XCTAssertEqual(manager.statuses.first { $0.spec.hasPrefix("127.0.0.1:3000") }?.origin, .auto)
    }

    func testABusyMacPortNamesTheProgramHoldingIt() async {
        ssh.busyHostPorts = ["127.0.0.1:8000:", "127.0.0.1:1080"]
        ssh.listeners = [8000: ["limactl"], 1080: ["something", "other"]]
        await manager.apply(configured: [ForwardRule(kind: .socks, hostPort: 1080)], autoForward: AutoForwardSettings(),
                            ports: [port("0.0.0.0", 8000)])
        XCTAssertEqual(state("127.0.0.1:8000:127.0.0.1:8000"),
                       .failed("Port 8000 on this Mac is already in use by limactl."))
        XCTAssertEqual(state("127.0.0.1:1080"), .failed("Port 1080 on this Mac is already in use by something, other."))
    }

    /// The Mac port is held by another Monad VM's forward (its ssh master):
    /// the message names that VM, not "ssh". A VM's master is known by its
    /// pid while it runs, and forgotten when its forwards stop.
    func testAMacPortHeldByAnotherVMNamesTheVM() async {
        defer { ForwardManager.forgetMasters() }
        let other = ForwardManager(mux: SSHMux(paths: InstancePaths(name: "susetest", root: URL(fileURLWithPath: "/tmp/monad-test")),
                                                host: "monad-susetest", options: []),
                                   runner: FakeCommandRunner { call in
                                       call.arguments.contains("check")
                                           ? .init(status: 0, stdout: Data(), stderr: Data("Master running (pid=500)\r\n".utf8))
                                           : .ok()
                                   }, watcher: FakeWatcher(), clock: clock, vmName: "susetest")
        await other.apply(configured: [], autoForward: AutoForwardSettings(), ports: [port("0.0.0.0", 8000)])
        XCTAssertEqual(ForwardManager.masterVM(pid: 500), "susetest")
        ssh.busyHostPorts = ["127.0.0.1:8000:"]
        ssh.listeners = [8000: ["ssh"]]
        await manager.apply(configured: [], autoForward: AutoForwardSettings(), ports: [port("0.0.0.0", 8000)])
        XCTAssertEqual(state("127.0.0.1:8000:127.0.0.1:8000"),
                       .failed("Port 8000 on this Mac is already in use by the virtual machine susetest."))
        other.stop()
        XCTAssertNil(ForwardManager.masterVM(pid: 500))
    }

    func testPortsOverTheLimitAreNotForwardedAndCounted() async {
        var reported: [Int] = []
        manager.onChange = { reported.append($1) }
        await manager.apply(configured: [], autoForward: AutoForwardSettings(),
                            ports: Set((0..<40).map { port("0.0.0.0", 4000 + $0) }))
        XCTAssertEqual(ssh.activeSpecs.count, 32)
        XCTAssertEqual(manager.overLimit, 8)
        await manager.apply(configured: [], autoForward: AutoForwardSettings(),
                            ports: Set((0..<41).map { port("0.0.0.0", 4000 + $0) }))
        XCTAssertEqual(manager.overLimit, 9, "the count changes even when the forwards do not")
        XCTAssertEqual(reported.last, 9)
    }

    func testABurstOfGuestPortChangesRunsSSHABoundedNumberOfTimes() async {
        for i in 0..<100 {
            await manager.apply(configured: [], autoForward: AutoForwardSettings(), ports: [port("0.0.0.0", 3000 + i)],
                                guestEvent: true)
        }
        await assertEventually { self.ssh.activeSpecs == ["127.0.0.1:3099:127.0.0.1:3099"] }
        XCTAssertLessThan(runner.calls.count, 20, "\(runner.calls.count) runs")
    }

    func testSettingsChangesAreNotHeldBack() async {
        await manager.apply(configured: [], autoForward: AutoForwardSettings(), ports: [port("0.0.0.0", 3000)],
                            guestEvent: true)
        await manager.apply(configured: [ForwardRule(kind: .socks, hostPort: 1080)], autoForward: AutoForwardSettings(),
                            ports: [port("0.0.0.0", 3000)])
        XCTAssertEqual(Set(ssh.activeSpecs), ["127.0.0.1:3000:127.0.0.1:3000", "127.0.0.1:1080"])
    }

    func testAnAutoForwardSkipsAPortAMacProgramListensOn() async {
        // A Mac server on all addresses: ssh could still bind 127.0.0.1 next
        // to it and take the Mac's localhost traffic for that port.
        ssh.listeners = [8080: ["python3"], 9000: ["node", "node"]]
        await manager.apply(configured: [], autoForward: AutoForwardSettings(),
                            ports: [port("0.0.0.0", 8080), port("::1", 9000), port("0.0.0.0", 3000)])
        XCTAssertEqual(ssh.activeSpecs, ["127.0.0.1:3000:127.0.0.1:3000"])
        XCTAssertEqual(state("127.0.0.1:8080:127.0.0.1:8080"), .failed("Port 8080 on this Mac is already in use by python3."))
        XCTAssertEqual(state("127.0.0.1:9000:[::1]:9000"), .failed("Port 9000 on this Mac is already in use by node."))
        XCTAssertEqual(runner.calls.filter { $0.executable == "/usr/sbin/lsof" }.count, 1, "one lsof for every new port")
        ssh.listeners = [:]
        await manager.apply(configured: [], autoForward: AutoForwardSettings(),
                            ports: [port("0.0.0.0", 8080), port("::1", 9000), port("0.0.0.0", 3000)])
        XCTAssertEqual(state("127.0.0.1:8080:127.0.0.1:8080"), .active, "tried again once the Mac program is gone")
    }

    func testAConfiguredForwardIsNotHeldBackByTheCheck() async {
        ssh.listeners = [8080: ["python3"]]
        await manager.apply(configured: [ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)],
                            autoForward: AutoForwardSettings(), ports: [])
        XCTAssertEqual(state("127.0.0.1:8080:127.0.0.1:80"), .active, "the user chose this port")
    }

    func testFailedForwardIsRetriedOnTheNextApply() async {
        ssh.busyHostPorts = ["127.0.0.1:3000:"]
        await manager.apply(configured: [], autoForward: AutoForwardSettings(), ports: [port("0.0.0.0", 3000)])
        ssh.busyHostPorts = []
        await manager.apply(configured: [], autoForward: AutoForwardSettings(), ports: [port("0.0.0.0", 3000)])
        XCTAssertEqual(state("127.0.0.1:3000:127.0.0.1:3000"), .active)
    }

    func testMasterDeathRestoresEveryForward() async {
        await manager.apply(configured: [ForwardRule(kind: .socks, hostPort: 1080)], autoForward: AutoForwardSettings(),
                            ports: [port("0.0.0.0", 3000)])
        ssh.kill()
        watcher.exit(100)
        await assertEventually { self.ssh.masterPID == 101 && self.ssh.activeSpecs.count == 2 }
        XCTAssertEqual(watcher.watched, [100, 101])
    }

    func testAMasterThatKeepsDyingIsRestartedWithBackoff() async {
        await manager.apply(configured: [ForwardRule(kind: .socks, hostPort: 1080)], autoForward: AutoForwardSettings(),
                            ports: [])
        var expected: [TimeInterval] = []
        for n in 0..<8 {
            let pid = ssh.masterPID
            ssh.kill()
            watcher.exit(pid)
            await assertEventually { self.ssh.masterPID == pid + 1 }
            expected.append(min(60, pow(2, Double(n))))
            XCTAssertEqual(clock.totalSlept, expected.reduce(0, +), "restart \(n + 1)")
        }
    }

    func testAMasterThatRanForAWhileIsRestartedAtOnce() async {
        await manager.apply(configured: [ForwardRule(kind: .socks, hostPort: 1080)], autoForward: AutoForwardSettings(),
                            ports: [])
        ssh.kill()
        watcher.exit(100)
        await assertEventually { self.ssh.masterPID == 101 }
        XCTAssertEqual(clock.totalSlept, 1)
        await clock.sleep(seconds: 600) // the new master works for ten minutes
        ssh.kill()
        watcher.exit(101)
        await assertEventually { self.ssh.masterPID == 102 }
        XCTAssertEqual(clock.totalSlept, 601, "no delay after a long-lived master")
    }

    func testTheMasterLogIsSetAsideBeforeItGrowsLarge() async throws {
        let log = SSHMux(paths: paths, host: "monad-dev", options: CloudInit.sshArguments(config: InstanceConfig.defaults(name: "dev"), paths: paths)).masterLog
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: (1 << 20) + 1).write(to: log)
        defer {
            try? FileManager.default.removeItem(at: log)
            try? FileManager.default.removeItem(at: log.appendingPathExtension("1"))
        }
        await manager.apply(configured: [ForwardRule(kind: .socks, hostPort: 1080)], autoForward: AutoForwardSettings(),
                            ports: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "ssh starts a new log")
        let old = try FileManager.default.attributesOfItem(atPath: log.appendingPathExtension("1").path)
        XCTAssertEqual((old[.size] as? NSNumber)?.intValue, (1 << 20) + 1)
    }

    func testAStaleControlSocketIsRemovedBeforeAMasterStarts() async throws {
        // With a socket file left behind, ssh would start as a plain
        // connection ("disabling multiplexing") and never be a master.
        let socket = paths.controlSocket
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socket) }
        var existedAtStart: Bool?
        let runner = FakeCommandRunner { [ssh] call in
            if call.executable == "/bin/sh", existedAtStart == nil {
                existedAtStart = FileManager.default.fileExists(atPath: socket.path)
            }
            return ssh!.handle(call)
        }
        let m = ForwardManager(mux: SSHMux(paths: paths, host: "monad-dev", options: CloudInit.sshArguments(config: InstanceConfig.defaults(name: "dev"), paths: paths)), runner: runner, watcher: watcher, clock: clock)
        await m.apply(configured: [ForwardRule(kind: .socks, hostPort: 1080)], autoForward: AutoForwardSettings(), ports: [])
        XCTAssertEqual(existedAtStart, false)
        XCTAssertEqual(m.statuses.first?.state, .active)
    }

    func testMasterThatCannotStartMarksEverythingFailed() async {
        ssh.masterStartFails = true
        await manager.apply(configured: [ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)],
                            autoForward: AutoForwardSettings(), ports: [])
        guard case .failed = state("127.0.0.1:8080:127.0.0.1:80") else {
            return XCTFail("\(String(describing: state("127.0.0.1:8080:127.0.0.1:80")))")
        }
    }

    func testConcurrentAppliesDoNotDuplicateForwards() async {
        async let a: Void = manager.apply(configured: [], autoForward: AutoForwardSettings(), ports: [port("0.0.0.0", 3000)])
        async let b: Void = manager.apply(configured: [], autoForward: AutoForwardSettings(), ports: [port("0.0.0.0", 3000)])
        _ = await (a, b)
        XCTAssertEqual(ssh.activeSpecs, ["127.0.0.1:3000:127.0.0.1:3000"])
    }

    func testStopForgetsEverything() async {
        await manager.apply(configured: [], autoForward: AutoForwardSettings(), ports: [port("0.0.0.0", 3000)])
        manager.stop()
        XCTAssertTrue(manager.statuses.isEmpty)
        watcher.exit(100)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(ssh.masterPID, 100, "a stopped manager does not restart the master")
    }
}

@MainActor
final class KqueueProcessWatcherTests: XCTestCase {
    private func spawnSleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        return p
    }

    func testReportsTheExitOfARunningProcess() async throws {
        let p = try spawnSleeper()
        var exited = false
        let watch = KqueueProcessWatcher().watch(pid: p.processIdentifier) { exited = true }
        XCTAssertFalse(exited)
        p.terminate()
        await assertEventually { exited }
        watch.cancel()
    }

    func testReportsAProcessThatIsAlreadyGone() async throws {
        let p = try spawnSleeper()
        p.terminate()
        p.waitUntilExit()
        var exited = false
        let watch = KqueueProcessWatcher().watch(pid: p.processIdentifier) { exited = true }
        await assertEventually { exited }
        watch.cancel()
    }

    func testCancelledWatchStaysSilent() async throws {
        let p = try spawnSleeper()
        var exited = false
        let watch = KqueueProcessWatcher().watch(pid: p.processIdentifier) { exited = true }
        watch.cancel()
        p.terminate()
        p.waitUntilExit()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(exited)
    }
}
