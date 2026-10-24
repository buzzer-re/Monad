//
//  HostClientTests.swift — the app's view of MonadHost: mirrored VM state,
//  requests, and recovery when the host goes away or restarts. The host side
//  is a real HostService on fake VMs, reached through an in-process transport.
//

import Combine
import XCTest
@testable import Monad

/// In-process transport to a HostService. `kill()` simulates the host
/// crashing or the XPC connection being interrupted.
@MainActor
final class FakeHostTransport: HostTransport {
    var onEvent: ((Data) -> Void)?
    var onInvalidated: (() -> Void)?
    private var connection: HostConnection?
    private(set) var invalidated = false
    /// Like launchd with an agent it cannot spawn: messages are never answered.
    private let silent: Bool
    private var parked: [CheckedContinuation<Data, Error>] = []
    /// Events held back, as when XPC delivers a reply before an event.
    var holdEvents = false
    /// Changes every answer, e.g. into what an older host would say.
    var rewrite: ((inout HostResponse) -> Void)?
    private var heldEvents: [Data] = []

    init(service: HostService, silent: Bool = false) {
        self.silent = silent
        connection = service.connect { [weak self] event in
            guard let self, let data = try? HostProtocol.encode(event) else { return }
            if self.holdEvents { self.heldEvents.append(data) } else { self.onEvent?(data) }
        }
    }

    func send(_ request: Data) async throws -> Data {
        guard !invalidated, let connection else { throw TestError("connection invalid") }
        if silent {
            return try await withCheckedThrowingContinuation { parked.append($0) }
        }
        let data = await connection.handle(request)
        guard let rewrite, var r = try? HostProtocol.decode(HostResponse.self, from: data) else { return data }
        rewrite(&r)
        return try HostProtocol.encode(r)
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        connection?.close()
        connection = nil
        let waiting = parked
        parked.removeAll()
        for c in waiting { c.resume(throwing: TestError("connection invalidated")) }
    }

    func kill() {
        invalidate()
        onInvalidated?()
    }
}

/// A host that can be unreachable, crash and restart.
@MainActor
final class FakeHost {
    let fixture: ManagerFixture
    private(set) var manager: VMManager
    private(set) var service: HostService
    private(set) var transports: [FakeHostTransport] = []
    /// Connection attempts that fail before one succeeds (-1: always fail).
    var failures = 0
    /// Connections that are accepted but never answered.
    var silent = 0
    private(set) var attempts = 0
    /// Build a restarted host reports (a new binary after an update).
    var nextBuild: String?
    private(set) var shutdowns = 0

    init(build: String? = nil) throws {
        fixture = try ManagerFixture()
        manager = fixture.manager
        service = HostService(manager: manager, limits: .init(maxCPUs: 8, maxMemoryGiB: 16), build: build,
                              agents: fixture.tmp.url.appendingPathComponent("agents"))
        nextBuild = build
        wire()
    }

    /// An accepted shutdown makes launchd start the (possibly newer) host.
    private func wire() {
        service.onShutdown = { [weak self] in
            guard let self else { return }
            self.shutdowns += 1
            Task { await self.restart() }
        }
    }

    func connect() throws -> HostTransport {
        attempts += 1
        if failures != 0 {
            failures -= 1
            throw TestError("MonadHost is not running")
        }
        let t = FakeHostTransport(service: service, silent: silent > 0)
        if silent > 0 { silent -= 1 }
        transports.append(t)
        return t
    }

    var live: FakeHostTransport? { transports.last { !$0.invalidated } }

    /// The host process dies with its VMs and launchd starts a new one,
    /// which finds the VMs on disk, stopped.
    func restart() async {
        let old = transports.filter { !$0.invalidated }
        for vm in manager.instances where vm.isRunning {
            await vm.forceStop()
        }
        manager = fixture.makeManager()
        manager.load()
        service = HostService(manager: manager, limits: .init(maxCPUs: 8, maxMemoryGiB: 16), build: nextBuild,
                              agents: fixture.tmp.url.appendingPathComponent("agents"))
        wire()
        // Clients notice only now, so they can only reach the new host.
        for t in old { t.kill() }
    }

    func sessions(_ name: String) -> Int {
        manager.existing(name).map { manager.sessions(for: $0) } ?? -1
    }
}

@MainActor
final class HostClientTests: XCTestCase {
    private var host: FakeHost!
    private var client: HostClient!

    override func setUp() async throws {
        host = try FakeHost()
    }

    override func tearDown() async throws {
        client?.stop()
    }

    private func makeClient(version: Int = HostProtocol.version, timeout: TimeInterval = 30,
                            expectedBuild: String? = nil) -> HostClient {
        let host = self.host!
        let c = HostClient(connect: { try host.connect() }, clock: TestClock(realDelay: 0.001),
                           instanceRoot: host.fixture.root, requestTimeout: timeout, protocolVersion: version,
                           expectedHostBuild: expectedBuild)
        c.start()
        client = c
        return c
    }

    private func readyDefault(_ c: HostClient) async throws -> RemoteVM {
        let vm = try await c.ensureDefault()
        await assertEventually { vm.state == .stopped }
        try await c.attach(vm.name)
        await assertEventually("state \(vm.state)") { vm.state == .ready }
        return vm
    }

    // MARK: Mirroring

    /// Settings › Logs: the app's side, connection and requests.
    func testTheConnectionAndRequestsAreLogged() async throws {
        let tmp = TempDir()
        let debugLog = DebugLog(process: "Monad", directory: tmp.url, settings: tmp.url.appendingPathComponent("l.json"))
        debugLog.setEnabled(true)
        let host = self.host!
        let c = HostClient(connect: { try host.connect() }, clock: TestClock(realDelay: 0.001),
                           instanceRoot: host.fixture.root, debugLog: debugLog)
        c.start()
        client = c
        _ = try await c.ensureDefault()
        do { try await c.start("nope") } catch {}
        debugLog.flush()
        let t = (try? String(contentsOf: debugLog.currentFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(t.contains("client: connected to the VM service"), t)
        XCTAssertTrue(t.range(of: #"client: ensureDefault → ok after \d+\.\d\d s"#, options: .regularExpression) != nil, t)
        XCTAssertTrue(t.range(of: #"client: start nope → error after \d+\.\d\d s: "#, options: .regularExpression) != nil, t)
    }

    /// "Start VM at boot": when Monad opens it starts the VMs marked for it
    /// that are not running; others are left alone.
    func testVMsMarkedToStartAtBootStartWhenMonadOpens() async throws {
        let c = makeClient()
        let vm = try await c.ensureDefault()
        await assertEventually { vm.state == .stopped }
        let none = try await c.startMarkedVMs()
        XCTAssertEqual(none, [], "not marked")
        XCTAssertEqual(vm.state, .stopped)

        var config = vm.config
        config.startAtLaunch = true
        try await c.update(config)
        let started = try await c.startMarkedVMs()
        XCTAssertEqual(started, ["default"])
        await assertEventually("state \(vm.state)") { vm.state == .ready }
        let again = try await c.startMarkedVMs()
        XCTAssertEqual(again, [], "already running")
    }

    func testConnectsAndMirrorsVMs() async throws {
        let c = makeClient()
        await assertEventually { c.status == .connected }
        let vm = try await c.ensureDefault()
        XCTAssertEqual(vm.name, "default")
        XCTAssertTrue(c.instances.contains { $0 === vm })
        await assertEventually { vm.state == .stopped }
        XCTAssertEqual(vm.paths.dir, host.fixture.root.appendingPathComponent("default"),
                       "paths point into the shared instance directory")
        XCTAssertEqual(vm.sshHost, "monad-default")
    }

    func testUpdatesKeepObjectIdentity() async throws {
        let c = makeClient()
        let vm = try await readyDefault(c)
        XCTAssertTrue(c.vm(named: "default") === vm)
        XCTAssertEqual(vm.sessions, 1)
    }

    func testUpdateShowsTheHostsAnswerAtOnce() async throws {
        let c = makeClient()
        let vm = try await readyDefault(c)
        var cfg = vm.config
        cfg.cpus += 1
        host.transports.last?.holdEvents = true
        try await c.update(cfg)
        // No waiting for the change event: the settings window decides right
        // away whether to offer a restart.
        XCTAssertEqual(vm.config.cpus, cfg.cpus)
        XCTAssertEqual(vm.pendingRestart, ["CPUs"])
    }

    /// An older MonadHost (still serving while VMs run) does not know newer
    /// settings and drops them when it saves: that is an error, never a
    /// silent success.
    func testSettingsAnOlderHostDropsAreReported() async throws {
        let c = makeClient()
        let vm = try await readyDefault(c)
        var cfg = vm.config
        cfg.firewall.allowLAN = true
        host.live?.rewrite = { $0.instance?.config.firewall = VMFirewall() }
        do {
            try await c.update(cfg)
            XCTFail("an older host's dropped settings went unnoticed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("older Monad"), error.localizedDescription)
        }
        host.live?.rewrite = nil
        try await c.update(cfg)
        XCTAssertEqual(vm.config.firewall.allowLAN, true)
    }

    /// A VM whose creation fails (its image cannot be had, say) stays
    /// listed in the app as failed, saying why, with its log; made again by
    /// its name it is tried afresh.
    func testACreationThatFailsSaysWhy() async throws {
        let c = makeClient()
        host.fixture.images.error = TestError("the checksum file is not there")
        var cfg = InstanceConfig.defaults(name: "alma")
        cfg.cpus = 2
        cfg.memoryGiB = 2
        let vm = try await c.create(cfg)
        await assertEventually("state \(vm.state)") { vm.state.isFailed }
        guard case .failed(let why) = vm.state else { return XCTFail("the tab saw \(vm.state)") }
        XCTAssertTrue(why.contains("the checksum file is not there"), why)
        let listed = try await c.existing("alma")
        XCTAssertTrue(listed.state.isFailed, "listed, saying why")
        host.fixture.images.error = nil
        let again = try await c.create(cfg)
        await assertEventually { again.state == .stopped }
        let found = try await c.existing("alma")
        XCTAssertTrue(found === again, "made again, the old failure is forgotten")
    }

    /// The Virtual Machines window lists the VMs in the host's order, which
    /// a drag changes; the default VM is the top one until Make Default
    /// chooses one, and choosing does not move it.
    func testTheVMsAreInTheHostsOrder() async throws {
        let c = makeClient()
        for name in ["web", "db"] {
            var cfg = InstanceConfig.defaults(name: name)
            cfg.cpus = 2
            cfg.memoryGiB = 2
            let vm = try await c.create(cfg)
            await assertEventually { vm.state == .stopped }
        }
        XCTAssertEqual(c.instances.map(\.name), ["web", "db"], "new VMs at the bottom, not by name")
        XCTAssertEqual(c.defaultVM?.name, "web")
        try await c.makeDefault("db")
        XCTAssertEqual(c.instances.map(\.name), ["web", "db"], "choosing the default leaves the order")
        XCTAssertEqual(c.defaultVM?.name, "db")
        try await c.move(from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(c.instances.map(\.name), ["db", "web"])
        XCTAssertEqual(c.defaultVM?.name, "db", "and the order leaves the default")
        try await c.move("db", by: 1)
        XCTAssertEqual(c.instances.map(\.name), ["web", "db"])
        try await c.move("db", by: -1)
        XCTAssertEqual(c.instances.map(\.name), ["db", "web"], "Move Up")
        try await c.move("db", by: 1)
        XCTAssertEqual(c.instances.map(\.name), ["web", "db"], "Move Down")
        // The list changes at once (a drag must not snap back), and back if
        // the host refuses.
        do {
            try await c.reorder(["db", "not a name"])
            XCTFail("a refused reorder went unnoticed")
        } catch {}
        XCTAssertEqual(c.instances.map(\.name), ["web", "db"], "a refused change is undone")
        let tmp = try await c.createEphemeral()
        XCTAssertEqual(c.instances.map(\.name), ["web", "db", tmp.name], "ephemeral VMs last")

        // Another app (or a restarted one) sees the same order.
        let host = self.host!
        let other = HostClient(connect: { try host.connect() }, clock: TestClock(realDelay: 0.001),
                               instanceRoot: host.fixture.root)
        other.start()
        defer { other.stop() }
        await assertEventually { other.status == .connected }
        XCTAssertEqual(other.instances.map(\.name), ["web", "db", tmp.name])
        XCTAssertEqual(other.defaultVM?.name, "db")
        try await other.makeDefault("web")
        await assertEventually("\(String(describing: c.defaultVM?.name))") { c.defaultVM?.name == "web" }
        XCTAssertEqual(c.instances.map(\.name), ["web", "db", tmp.name])
    }

    /// The Virtual Machines list is drawn from the client: a VM moved to
    /// another group (here by another app) redraws it at once, though the
    /// VM's object stays the same.
    func testAGroupChangeRedrawsTheList() async throws {
        let c = makeClient()
        var cfg = InstanceConfig.defaults(name: "web")
        cfg.cpus = 2
        cfg.memoryGiB = 2
        let vm = try await c.create(cfg)
        await assertEventually { vm.state == .stopped }
        var told = 0
        let watch = c.objectWillChange.sink { told += 1 }
        defer { watch.cancel() }
        var grouped = vm.config
        grouped.group = "coding"
        try await c.update(grouped)
        XCTAssertEqual(vm.config.group, "coding")
        XCTAssertGreaterThan(told, 0, "the list hears of it")
        XCTAssertTrue(c.vm(named: "web") === vm)
    }

    func testDeletedVMsDisappear() async throws {
        let c = makeClient()
        var cfg = InstanceConfig.defaults(name: "work")
        cfg.cpus = 2
        cfg.memoryGiB = 2
        let vm = try await c.create(cfg)
        await assertEventually { vm.state == .stopped }
        try await c.delete("work")
        XCTAssertNil(c.vm(named: "work"))
    }

    func testLookupByNameWaitsForTheConnection() async throws {
        let other = host.service.connect { _ in }
        _ = await other.handle(HostRequest(id: 1, op: .hello, version: HostProtocol.version))
        _ = await other.handle(HostRequest(id: 2, op: .ensureDefault))
        host.failures = 2
        let c = makeClient()
        let vm = try await c.existing("default")
        XCTAssertEqual(vm.name, "default")
        do {
            _ = try await c.existing("nope")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "No VM named nope.")
        }
    }

    func testHostErrorsAreThrown() async {
        let c = makeClient()
        do {
            try await c.start("nope")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "No VM named nope.")
        }
    }

    // MARK: Connection problems

    func testRequestsWaitUntilTheHostIsReachable() async throws {
        host.failures = 3
        let c = makeClient()
        let vm = try await c.ensureDefault()
        XCTAssertEqual(vm.name, "default")
        XCTAssertEqual(host.attempts, 4)
        XCTAssertEqual(c.status, .connected)
    }

    func testUnreachableHostFailsRequestsAfterTheTimeout() async {
        host.failures = -1
        let c = makeClient(timeout: 5)
        do {
            _ = try await c.ensureDefault()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? HostClientError, .unavailable)
        }
        guard case .unavailable = c.status else { return XCTFail("status \(c.status)") }
        XCTAssertGreaterThan(host.attempts, 1, "keeps retrying")
    }

    func testIncompatibleHostIsReportedAndNotRetried() async {
        let c = makeClient(version: HostProtocol.version + 1)
        await assertEventually {
            if case .incompatible = c.status { return true } else { return false }
        }
        let attempts = host.attempts
        do {
            _ = try await c.ensureDefault()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? HostClientError, .incompatible)
        }
        XCTAssertEqual(host.attempts, attempts, "no reconnect loop against a host that will never match")
    }

    func testInterruptedConnectionReconnectsAndReattaches() async throws {
        let c = makeClient()
        let vm = try await readyDefault(c)
        let first = try XCTUnwrap(host.live)
        first.kill()
        await assertEventually { self.host.live != nil && self.host.live !== first }
        await assertEventually { c.status == .connected }
        await assertEventually { self.host.sessions("default") == 1 }
        XCTAssertTrue(c.vm(named: "default") === vm, "tabs keep their object")
        XCTAssertEqual(vm.state, .ready)

        try await c.detach("default")
        XCTAssertEqual(host.sessions("default"), 0)
    }

    func testHostRestartBootsAttachedVMsAgain() async throws {
        let c = makeClient()
        let vm = try await readyDefault(c)
        await host.restart()
        await assertEventually { c.status == .connected }
        await assertEventually("state \(vm.state)") { vm.state == .ready }
        XCTAssertEqual(host.sessions("default"), 1)
    }

    func testVMsGoneAfterRestartAreDropped() async throws {
        let c = makeClient()
        let name = try await c.createEphemeral().name
        await assertEventually { c.vm(named: name)?.state == .stopped }
        await host.restart() // ephemeral leftovers are deleted on load
        await assertEventually { c.vm(named: name) == nil }
    }

    func testDetachWithoutAttachIsANoOp() async throws {
        let c = makeClient()
        _ = try await c.ensureDefault()
        try await c.detach("default")
        XCTAssertEqual(host.sessions("default"), 0)
    }

    func testStopClosesTheConnection() async throws {
        let c = makeClient()
        _ = try await readyDefault(c)
        c.stop()
        XCTAssertNil(host.live)
        XCTAssertEqual(host.sessions("default"), 0, "the host releases what the app held")
    }

    // MARK: Host updates

    func testOutdatedIdleHostIsReplaced() async throws {
        host = try FakeHost(build: "old")
        host.nextBuild = "new"
        let c = makeClient(expectedBuild: "new")
        await assertEventually { c.status == .connected && self.host.shutdowns == 1 }
        await assertEventually { c.status == .connected && c.hostBuild == "new" }
        XCTAssertFalse(c.hostIsOutdated)
        _ = try await c.ensureDefault()
    }

    func testOutdatedHostWithRunningVMsIsKept() async throws {
        host = try FakeHost(build: "old")
        host.nextBuild = "new"
        // Another app instance started a VM before this one connected.
        let other = host.service.connect { _ in }
        _ = await other.handle(HostRequest(id: 1, op: .hello, version: HostProtocol.version))
        _ = await other.handle(HostRequest(id: 2, op: .ensureDefault))
        await assertEventually { self.host.manager.existing("default")?.state == .stopped }
        _ = await other.handle(HostRequest(id: 3, op: .start, name: "default"))
        await assertEventually { self.host.manager.existing("default")?.state == .ready }
        other.close()

        let c = makeClient(expectedBuild: "new")
        await assertEventually { c.status == .connected }
        await assertEventually { c.hostIsOutdated }
        XCTAssertEqual(host.shutdowns, 0)
        XCTAssertEqual(c.hostBuild, "old")
        XCTAssertEqual(c.vm(named: "default")?.state, .ready, "running VMs are never interrupted for an update")
    }

    /// A host from an older Monad (kept while its VMs run) does not know
    /// reorder: the user is told why, and the list stays as it was.
    func testAnOlderHostThatCannotReorderSaysSo() async throws {
        host = try FakeHost(build: "old")
        host.nextBuild = "new"
        let other = host.service.connect { _ in }
        _ = await other.handle(HostRequest(id: 1, op: .hello, version: HostProtocol.version))
        _ = await other.handle(HostRequest(id: 2, op: .ensureDefault))
        await assertEventually { self.host.manager.existing("default")?.state == .stopped }
        _ = await other.handle(HostRequest(id: 3, op: .start, name: "default"))
        await assertEventually { self.host.manager.existing("default")?.state == .ready }
        other.close()

        let c = makeClient(expectedBuild: "new")
        await assertEventually { c.hostIsOutdated }
        // What an older host answers a request it cannot read.
        host.live?.rewrite = { $0 = HostResponse(id: 0, error: "Malformed HostRequest message.") }
        do {
            try await c.makeDefault("default")
            XCTFail("an older host's refusal went unnoticed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("older Monad"), error.localizedDescription)
        }
        XCTAssertEqual(c.instances.map(\.name), ["default"])
    }

    /// "Restart VM Service": the running VMs stop, the old host makes way,
    /// and the tabs' VMs start again on the new one.
    func testOutdatedHostIsReplacedOnRequest() async throws {
        host = try FakeHost(build: "old")
        host.nextBuild = "new"
        let other = host.service.connect { _ in }
        _ = await other.handle(HostRequest(id: 1, op: .hello, version: HostProtocol.version))
        _ = await other.handle(HostRequest(id: 2, op: .ensureDefault))
        await assertEventually { self.host.manager.existing("default")?.state == .stopped }
        _ = await other.handle(HostRequest(id: 3, op: .start, name: "default"))
        await assertEventually { self.host.manager.existing("default")?.state == .ready }
        other.close()
        let c = makeClient(expectedBuild: "new")
        await assertEventually { c.status == .connected && c.hostIsOutdated }
        try await c.attach("default")
        var preparedWhileOldHostWasGone = false
        c.prepareHostLaunch = { [host] in preparedWhileOldHostWasGone = host?.live == nil }

        try await c.updateHost()
        await assertEventually { c.status == .connected && c.hostBuild == "new" }
        XCTAssertFalse(c.hostIsOutdated)
        XCTAssertEqual(host.shutdowns, 1)
        XCTAssertTrue(preparedWhileOldHostWasGone, "launchd is pointed at the new binary first")
        await assertEventually { self.host.sessions("default") == 1 }
        await assertEventually { self.host.manager.existing("default")?.state == .ready }
    }

    func testAnUpToDateHostIsNotRestarted() async throws {
        host = try FakeHost(build: "same")
        let c = makeClient(expectedBuild: "same")
        _ = try await readyDefault(c)
        try await c.updateHost()
        XCTAssertEqual(host.shutdowns, 0)
        XCTAssertEqual(c.vm(named: "default")?.state, .ready)
    }

    func testReplacementIsAttemptedOnlyOnce() async throws {
        host = try FakeHost(build: "old")
        host.nextBuild = "old" // launchd keeps starting a stale binary
        let c = makeClient(expectedBuild: "new")
        await assertEventually { self.host.shutdowns == 1 }
        await assertEventually { c.status == .connected && c.hostIsOutdated }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(host.shutdowns, 1, "no restart loop")
    }

    // MARK: Preparing a host launch (launch agent re-registration)

    func testUnreachableHostIsPreparedOncePerFailureStreak() async throws {
        host.failures = 2
        let c = makeClient()
        var prepared = 0
        c.prepareHostLaunch = { prepared += 1 }
        _ = try await c.ensureDefault()
        XCTAssertEqual(prepared, 1, "prepared after the first failure, not on every retry")
        XCTAssertEqual(host.attempts, 3)
    }

    /// A preparation that did not bring the host back (launchd lost the
    /// job) is tried again while the host stays unreachable.
    func testALongFailureStreakIsPreparedAgain() async throws {
        host.failures = 6
        let c = makeClient()
        var prepared = 0
        c.prepareHostLaunch = { prepared += 1 }
        _ = try await c.ensureDefault()
        XCTAssertEqual(prepared, 2, "after the first failure and again after five more")
        XCTAssertEqual(host.attempts, 7)
    }

    func testReplacedHostIsPreparedBeforeReconnecting() async throws {
        host = try FakeHost(build: "old")
        host.nextBuild = "new"
        let c = makeClient(expectedBuild: "new")
        var preparedWhileOldHostWasGone = false
        c.prepareHostLaunch = { [host] in preparedWhileOldHostWasGone = host?.live == nil }
        await assertEventually { c.status == .connected && c.hostBuild == "new" }
        XCTAssertTrue(preparedWhileOldHostWasGone, "never while the old host still serves (it may run VMs)")
    }

    func testSilentHostTimesOutAndIsPrepared() async throws {
        host.silent = 1
        let c = makeClient()
        var prepared = 0
        c.prepareHostLaunch = { prepared += 1 }
        _ = try await c.ensureDefault()
        XCTAssertEqual(prepared, 1)
        XCTAssertEqual(host.attempts, 2)
        XCTAssertTrue(host.transports[0].invalidated, "the unanswered connection is dropped")
    }

    func testReachableHostIsNotPrepared() async throws {
        let c = makeClient()
        var prepared = 0
        c.prepareHostLaunch = { prepared += 1 }
        _ = try await c.ensureDefault()
        XCTAssertEqual(prepared, 0)
    }

    func testMatchingOrUnknownBuildsAreLeftAlone() async throws {
        host = try FakeHost(build: "same")
        let c = makeClient(expectedBuild: "same")
        await assertEventually { c.status == .connected }
        XCTAssertFalse(c.hostIsOutdated)
        let unknown = makeClient(expectedBuild: nil)
        await assertEventually { unknown.status == .connected }
        XCTAssertEqual(host.shutdowns, 0)
        unknown.stop()
    }
}
