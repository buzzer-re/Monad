//
//  LaunchctlAgentTests.swift — loading MonadHost with launchctl (builds
//  without a Team ID, where SMAppService pins the ad-hoc code hash and a
//  rebuilt host could never start). launchd takes a job down in the
//  background after a bootout, and a bootstrap before it is gone fails: the
//  job was lost after a release until Monad was opened again.
//

import XCTest
@testable import Monad

final class LaunchctlAgentTests: XCTestCase {
    private var tmp: TempDir!
    private var runner: FakeCommandRunner!
    private var clock: TestClock!
    private var agent: LaunchctlAgent!
    private let host = URL(fileURLWithPath: "/Applications/Monad.app/Contents/MacOS/MonadHost")

    override func setUp() {
        tmp = TempDir()
        runner = FakeCommandRunner()
        clock = TestClock()
        agent = LaunchctlAgent(program: host, directory: tmp.url.appendingPathComponent("launchd"), uid: 501,
                               runner: runner, clock: clock)
    }

    private var commands: [[String]] { runner.calls.map { [$0.executable] + $0.arguments } }
    private var printJob: [String] { ["/bin/launchctl", "print", "gui/501/\(LaunchctlAgent.label)"] }
    private var bootoutJob: [String] { ["/bin/launchctl", "bootout", "gui/501/\(LaunchctlAgent.label)"] }
    private var bootstrapJob: [String] { ["/bin/launchctl", "bootstrap", "gui/501", agent.plistURL.path] }

    func testPlistStartsTheEmbeddedHostOnDemand() throws {
        try agent.writePlist()
        let data = try Data(contentsOf: agent.plistURL)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, LaunchctlAgent.label)
        XCTAssertEqual(plist["Program"] as? String, host.path)
        XCTAssertEqual((plist["MachServices"] as? [String: Bool])?[LaunchctlAgent.label], true)
        XCTAssertNil(plist["RunAtLoad"], "started on demand by its Mach service")
        XCTAssertNil(plist["KeepAlive"])
        let mode = try FileManager.default.attributesOfItem(atPath: agent.plistURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testLoadsWhenNotLoaded() async throws {
        runner.setHandler { call in call.arguments.first == "print" ? .fail(113, "Could not find service") : .ok() }
        try await agent.ensureLoaded()
        XCTAssertEqual(commands, [printJob, bootstrapJob])
    }

    func testLeavesALoadedJobAlone() async throws {
        runner.setHandler { _ in .ok("state = running\n") }
        try await agent.ensureLoaded()
        XCTAssertEqual(commands, [printJob])
    }

    func testReloadReplacesTheJob() async throws {
        runner.setHandler { call in call.arguments.first == "print" ? .fail(113, "Could not find service") : .ok() }
        try await agent.reload(vmsRunning: false)
        XCTAssertEqual(commands, [printJob, bootoutJob, printJob, bootstrapJob])
        XCTAssertTrue(FileManager.default.fileExists(atPath: agent.plistURL.path))
    }

    /// A MonadHost that runs VMs (another copy of Monad's, or one this app
    /// can no longer reach after an update) is never booted out: that would
    /// power them off (seen: two Debug copies taking turns, every VM shut
    /// down at each turn). One with no VM running is replaced, even while it
    /// runs: this app's own connections start it on demand, so it is
    /// running whenever it is looked at (seen: a stale registration kept for
    /// good).
    func testReloadNeverEndsAHostThatRunsVMs() async throws {
        let running = "gui/501/dev.monad.host = {\n\tstate = running\n\tpid = 4242\n}\n"
        runner.setHandler { call in call.arguments.first == "print" ? .ok(running) : .ok() }
        do {
            try await agent.reload(vmsRunning: true)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("still running"), error.localizedDescription)
        }
        XCTAssertEqual(commands, [printJob], "no bootout")
        try await agent.reload(vmsRunning: false)
        XCTAssertTrue(commands.contains(bootoutJob), "no VMs: replaced though it runs")
        // A job that is not running is replaced whatever the marks say (they
        // are left behind by a MonadHost that crashed).
        runner.setHandler { call in
            call.arguments.first == "print" ? .ok("gui/501/dev.monad.host = {\n\tstate = not running\n}\n") : .ok()
        }
        let before = commands.filter { $0 == bootoutJob }.count
        try await agent.reload(vmsRunning: true)
        XCTAssertEqual(commands.filter { $0 == bootoutJob }.count, before + 1)
    }

    /// The marks MonadHost keeps in each running VM's folder.
    func testVMsRunningAreSeenByTheirMarks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(LaunchctlAgent.vmsRunning(in: root), "no folder")
        let a = InstancePaths(name: "a", root: root), b = InstancePaths(name: "b", root: root)
        for p in [a, b] { try FileManager.default.createDirectory(at: p.dir, withIntermediateDirectories: true) }
        XCTAssertFalse(LaunchctlAgent.vmsRunning(in: root))
        try Data("2026-11-01 19:00:00".utf8).write(to: b.runningMark)
        XCTAssertTrue(LaunchctlAgent.vmsRunning(in: root))
    }

    /// The old job is still going for a while after the bootout: the new one
    /// is loaded once it is gone.
    func testReloadWaitsForTheOldJobToGo() async throws {
        var prints = 0
        runner.setHandler { call in
            guard call.arguments.first == "print" else { return .ok() }
            prints += 1
            if prints == 1 { return .ok("state = not running\n") }
            return prints <= 3 ? .ok("state = running\n") : .fail(113, "Could not find service")
        }
        try await agent.reload(vmsRunning: false)
        XCTAssertEqual(commands, [printJob, bootoutJob, printJob, printJob, printJob, bootstrapJob])
        XCTAssertGreaterThan(clock.totalSlept, 0)
    }

    /// A bootstrap refused while launchd still takes the old job down is
    /// tried again.
    func testARefusedBootstrapIsTriedAgain() async throws {
        var bootstraps = 0
        runner.setHandler { call in
            switch call.arguments.first {
            case "print": return .fail(113)
            case "bootstrap":
                bootstraps += 1
                return bootstraps <= 2 ? .fail(5, "Bootstrap failed: 5: Input/output error") : .ok()
            default: return .ok()
            }
        }
        try await agent.ensureLoaded()
        XCTAssertEqual(bootstraps, 3)
    }

    /// Loaded meanwhile (by another copy of Monad): nothing to report.
    func testAJobLoadedMeanwhileIsFine() async throws {
        var prints = 0
        runner.setHandler { call in
            switch call.arguments.first {
            case "print":
                prints += 1
                return prints == 1 ? .fail(113) : .ok("state = running\n")
            case "bootstrap": return .fail(37, "Bootstrap failed: 37: Operation already in progress")
            default: return .ok()
            }
        }
        try await agent.ensureLoaded()
    }

    func testBootstrapFailureIsReported() async {
        runner.setHandler { call in
            switch call.arguments.first {
            case "print": return .fail(113)
            case "bootstrap": return .fail(5, "Bootstrap failed: 5: Input/output error")
            default: return .ok()
            }
        }
        do {
            try await agent.ensureLoaded()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Input/output error"), error.localizedDescription)
        }
        XCTAssertEqual(commands.filter { $0 == bootstrapJob }.count, LaunchctlAgent.bootstrapTries, "tried a few times first")
    }
}
