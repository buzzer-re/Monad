//
//  HostServiceTests.swift — MonadHost's request handling on fake VMs: the
//  handshake, VM commands, per-connection tab sessions and change events.
//

import XCTest
@testable import Monad

/// Collects the events a connection receives.
@MainActor
final class EventLog {
    private(set) var events: [HostEvent] = []

    func record(_ e: HostEvent) { events.append(e) }

    func latest(_ name: String) -> VMSnapshot? {
        for case .instance(let s) in events.reversed() where s.name == name { return s }
        return nil
    }

    func removed(_ name: String) -> Bool { events.contains(.removed(name)) }
}

@MainActor
final class HostServiceTests: XCTestCase {
    private var fixture: ManagerFixture!
    private var service: HostService!
    private var nextID: UInt64 = 0

    override func setUp() async throws {
        fixture = try ManagerFixture()
        service = HostService(manager: fixture.manager, limits: .init(maxCPUs: 8, maxMemoryGiB: 16),
                              agents: fixture.tmp.url.appendingPathComponent("agents"))
    }

    private func connect(hello: Bool = true) async -> (HostConnection, EventLog) {
        let log = EventLog()
        let c = service.connect { log.record($0) }
        if hello {
            let r = await send(c, .hello, version: HostProtocol.version)
            XCTAssertTrue(r.ok, r.error ?? "")
        }
        return (c, log)
    }

    @discardableResult
    private func send(_ c: HostConnection, _ op: HostRequest.Op, name: String? = nil, force: Bool? = nil,
                      config: InstanceConfig? = nil, version: Int? = nil, names: [String]? = nil) async -> HostResponse {
        nextID += 1
        let r = await c.handle(HostRequest(id: nextID, op: op, name: name, force: force, config: config, version: version,
                                           names: names))
        XCTAssertEqual(r.id, nextID, "responses echo the request id")
        return r
    }

    /// Creates `name` and waits until provisioning finished.
    private func provisioned(_ c: HostConnection, _ log: EventLog, _ name: String = "default") async throws {
        if name == VMManager.defaultName {
            await send(c, .ensureDefault)
        } else {
            let r = await send(c, .create, config: config(name))
            XCTAssertTrue(r.ok, r.error ?? "")
        }
        await assertEventually("\(name): \(String(describing: log.latest(name)?.state))") {
            log.latest(name)?.state == .stopped
        }
    }

    private func config(_ name: String) -> InstanceConfig {
        var c = InstanceConfig.defaults(name: name)
        c.cpus = 2
        c.memoryGiB = 2
        c.diskGiB = 10
        return c
    }

    // MARK: Handshake

    /// A user name that would add lines to ssh_config is refused (F-08).
    func testHostileFieldsAreRefused() async throws {
        let (c, _) = await connect()
        var bad = config("evil")
        bad.user = "dev\n  ProxyCommand touch /tmp/pwned"
        let r = await send(c, .create, config: bad)
        XCTAssertFalse(r.ok)
        XCTAssertNil(fixture.manager.existing("evil"))
    }

    /// Shares are judged by where they really lead and stored that way;
    /// keys, the whole home folder and Monad's own files are guarded (F-14).
    func testSharesAreCheckedWhereTheyReallyLead() async throws {
        let home = TempDir()
        let fm = FileManager.default
        let monad = home.url.appendingPathComponent(".monad")
        let src = home.url.appendingPathComponent("src")
        let ssh = home.url.appendingPathComponent(".ssh")
        for d in [monad, src, ssh] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try fm.createSymbolicLink(at: home.url.appendingPathComponent("code"), withDestinationURL: src)
        try fm.createSymbolicLink(at: home.url.appendingPathComponent("innocent"), withDestinationURL: monad)
        service = HostService(manager: fixture.manager, limits: .init(maxCPUs: 8, maxMemoryGiB: 16),
                              sharePlaces: .init(home: home.url.path, monad: monad.path))
        let (c, _) = await connect()
        func sharing(_ path: String, readOnly: Bool = true, confirmed: Bool? = nil, name: String = "shares") -> InstanceConfig {
            var cfg = config(name)
            var share = SharedFolder(hostPath: path, guestPath: "/mnt/a", readOnly: readOnly)
            share.confirmed = confirmed
            cfg.sharing = SharingSettings(runtimeEnabled: true, shares: [share])
            return cfg
        }
        var r = await send(c, .create, config: sharing(home.url.appendingPathComponent("innocent").path))
        XCTAssertFalse(r.ok, "a link to ~/.monad")
        r = await send(c, .create, config: sharing(home.url.path, readOnly: false, confirmed: true))
        XCTAssertFalse(r.ok, "the home folder, writable")
        r = await send(c, .create, config: sharing(ssh.path))
        XCTAssertFalse(r.ok, "keys, without the user's word")
        XCTAssertNil(fixture.manager.existing("shares"))
        r = await send(c, .create, config: sharing(home.url.appendingPathComponent("code").path, readOnly: false))
        XCTAssertTrue(r.ok, r.error ?? "")
        let stored = try XCTUnwrap(fixture.manager.existing("shares")).config.sharing.shares.first?.hostPath
        XCTAssertEqual(stored, SharePolicy.resolve(src.path), "stored where it really leads")
        r = await send(c, .create, config: sharing(ssh.path, confirmed: true, name: "keys"))
        XCTAssertTrue(r.ok, r.error ?? "")
    }

    /// Settings › Logs: every request with its outcome and how long it took.
    func testRequestsAreLoggedWithTheirOutcome() async throws {
        let tmp = TempDir()
        let debugLog = DebugLog(process: "MonadHost", directory: tmp.url, settings: tmp.url.appendingPathComponent("l.json"))
        debugLog.setEnabled(true)
        service = HostService(manager: fixture.manager, limits: .init(maxCPUs: 8, maxMemoryGiB: 16), debugLog: debugLog)
        let (c, _) = await connect()
        await send(c, .start, name: "nope")
        debugLog.flush()
        let t = (try? String(contentsOf: debugLog.currentFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(t.contains("host: #1 hello"), t)
        XCTAssertTrue(t.range(of: #"host: #1 hello → ok after \d+\.\d\d s"#, options: .regularExpression) != nil, t)
        XCTAssertTrue(t.contains("host: #2 start nope"), t)
        XCTAssertTrue(t.range(of: #"host: #2 start nope → error after \d+\.\d\d s: "#, options: .regularExpression) != nil, t)
    }

    func testHelloReturnsHostVersion() async {
        let (c, _) = await connect(hello: false)
        let r = await send(c, .hello, version: HostProtocol.version)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.version, HostProtocol.version)
    }

    func testHelloReportsTheHostBuild() async {
        service = HostService(manager: fixture.manager, limits: .init(maxCPUs: 8, maxMemoryGiB: 16), build: "B1")
        let (c, _) = await connect(hello: false)
        let r = await send(c, .hello, version: HostProtocol.version)
        XCTAssertEqual(r.build, "B1")
    }

    func testShutdownWhenNoVMRuns() async throws {
        var asked = 0
        service.onShutdown = { asked += 1 }
        let (c, log) = await connect()
        try await provisioned(c, log)
        let r = await send(c, .shutdown)
        XCTAssertTrue(r.ok, r.error ?? "")
        await assertEventually { asked == 1 }
    }

    func testShutdownIsRefusedWhileAVMRuns() async throws {
        var asked = 0
        service.onShutdown = { asked += 1 }
        let (c, log) = await connect()
        try await provisioned(c, log)
        await send(c, .start, name: "default")
        await assertEventually { log.latest("default")?.state == .ready }
        let r = await send(c, .shutdown)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(asked, 0)
    }

    func testNothingButHelloBeforeHandshake() async {
        let (c, _) = await connect(hello: false)
        let r = await send(c, .list)
        XCTAssertFalse(r.ok)
        XCTAssertNotNil(r.error)
    }

    func testVersionMismatchIsRefusedAndKeepsConnectionLocked() async {
        let (c, _) = await connect(hello: false)
        let r = await send(c, .hello, version: HostProtocol.version + 1)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.version, HostProtocol.version, "the app learns which version is running")
        let r1 = await send(c, .list)
        XCTAssertFalse(r1.ok)
    }

    func testGarbageGetsAnErrorResponse() async throws {
        let (c, _) = await connect()
        let reply = await c.handle(Data("not json".utf8))
        let r = try HostProtocol.decode(HostResponse.self, from: reply)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.id, 0)
    }

    func testRawDataRoundTrip() async throws {
        let (c, _) = await connect()
        let request = try HostProtocol.encode(HostRequest(id: 77, op: .list))
        let r = try HostProtocol.decode(HostResponse.self, from: await c.handle(request))
        var expected = HostResponse(id: 77, instances: [])
        expected.order = []
        XCTAssertEqual(r, expected, "the list comes with the VMs' order")
    }

    func testInvalidRequestsAreRefused() async {
        let (c, _) = await connect()
        let r2 = await send(c, .start, name: "../../etc")
        XCTAssertFalse(r2.ok)
        let r3 = await send(c, .create)
        XCTAssertFalse(r3.ok)
    }

    /// An agent on the Mac (MonadHost --mcp) speaks MCP through the app's
    /// connection: one message in, the answer out, none for a notification.
    func testMCPMessagesAreAnswered() async throws {
        let (c, _) = await connect()
        nextID += 1
        var r = await c.handle(HostRequest(id: nextID, op: .mcp, mcp: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        XCTAssertTrue(r.ok, r.error ?? "")
        let answer = try XCTUnwrap(r.mcp)
        XCTAssertTrue(answer.contains("\"list_vms\""), answer)
        nextID += 1
        r = await c.handle(HostRequest(id: nextID, op: .mcp, mcp: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertTrue(r.ok)
        XCTAssertNil(r.mcp)
        nextID += 1
        r = await c.handle(HostRequest(id: nextID, op: .mcp))
        XCTAssertFalse(r.ok, "an mcp request carries a message")
        nextID += 1
        r = await c.handle(HostRequest(id: nextID, op: .mcp, mcp: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_vms"}}"#))
        XCTAssertTrue(r.mcp?.contains("\"isError\":false") ?? false, r.mcp ?? "")
    }

    /// A risky tool from the Mac asks the user: the apps are told, the
    /// answer lets it run (once, or always from then on) or refuses it.
    func testARiskyCallWaitsForTheUsersAnswer() async throws {
        let (app, log) = await connect()
        try await provisioned(app, log, "web")
        let (mac, _) = await connect()
        func call(_ tool: String, _ args: String) async -> HostResponse {
            nextID += 1
            return await mac.handle(HostRequest(id: nextID, op: .mcp,
                                                mcp: #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":""# + tool
                                                    + #"","arguments":"# + args + "}}"))
        }
        let first = Task { await call("add_bridge", #"{"name":"web","bridge":"cat","command":["/bin/cat"],"guest_port":9000}"#) }
        await assertEventually { if case .approvals(let l)? = log.events.last { return l.count == 1 } else { return false } }
        guard case .approvals(let asked)? = log.events.last else { return XCTFail() }
        XCTAssertEqual(asked[0].tool, "add_bridge")
        XCTAssertEqual(asked[0].caller, "mac")
        nextID += 1
        var r = await app.handle(HostRequest(id: nextID, op: .answerApproval).with { $0.approvalID = asked[0].id; $0.approvalAnswer = .alwaysTool })
        XCTAssertTrue(r.ok, r.error ?? "")
        let done = await first.value
        XCTAssertTrue(done.mcp?.contains("\"isError\":false") ?? false, done.mcp ?? "")
        XCTAssertEqual(fixture.manager.existing("web")?.config.bridges.map(\.name), ["cat"])

        let again = await call("add_bridge", #"{"name":"web","bridge":"cat2","command":["/bin/cat"],"guest_port":9001}"#)
        XCTAssertTrue(again.mcp?.contains("\"isError\":false") ?? false, "always: not asked again")
        nextID += 1
        r = await app.handle(HostRequest(id: nextID, op: .agentStatus))
        XCTAssertEqual(r.grants, [.init(caller: "mac", tool: "add_bridge")])
        XCTAssertTrue(r.audit?.contains { $0.contains("mac add_bridge") } ?? false, "\(r.audit ?? [])")

        let third = Task { await call("delete_vm", #"{"name":"web"}"#) }
        await assertEventually { if case .approvals(let l)? = log.events.last { return l.count == 1 } else { return false } }
        guard case .approvals(let q)? = log.events.last else { return XCTFail() }
        nextID += 1
        _ = await app.handle(HostRequest(id: nextID, op: .answerApproval).with { $0.approvalID = q[0].id; $0.approvalAnswer = .deny })
        let refused = await third.value
        XCTAssertTrue(refused.mcp?.contains("did not allow delete_vm") ?? false, refused.mcp ?? "")
        XCTAssertNotNil(fixture.manager.existing("web"))

        nextID += 1
        r = await app.handle(HostRequest(id: nextID, op: .revokeGrant).with { $0.grant = .init(caller: "mac", tool: "add_bridge") })
        XCTAssertEqual(r.grants, [])
        nextID += 1
        r = await app.handle(HostRequest(id: nextID, op: .answerApproval).with { $0.approvalID = UUID(); $0.approvalAnswer = .once })
        XCTAssertFalse(r.ok, "no such question")
    }

    /// A macOS VM's setup (Phase 14) is asked of the apps once, in the VM's
    /// snapshot; the answer (the root step's work folder, or why not) goes
    /// back to the setup; deleting the VM meanwhile cancels the question.
    func testAMacOSSetupIsAskedOfTheApps() async throws {
        let (app, log) = await connect()
        try await provisioned(app, log, "web")
        var opened = 0
        service.openApp = { opened += 1 }
        let disk = URL(fileURLWithPath: "/vms/web/disk.raw"), payload = URL(fileURLWithPath: "/vms/web/mac-setup")
        func ask() -> Task<String, Error> {
            Task { @MainActor in try await self.service.authorize(vm: "web", disk: disk, payload: payload) }
        }
        func answer(_ edit: @escaping (inout HostRequest) -> Void) async -> HostResponse {
            nextID += 1
            return await app.handle(HostRequest(id: nextID, op: .answerMacSetup, name: "web").with(edit))
        }

        let first = ask()
        await assertEventually { log.latest("web")?.macSetup != nil }
        XCTAssertEqual(log.latest("web")?.macSetup, MacSetupRequest(disk: disk.path, payload: payload.path))
        XCTAssertEqual(opened, 0, "an app is there: it is not opened again")
        var r = await answer { $0.macSetupWork = "/private/tmp/monad-macsetup.AbC123" }
        XCTAssertTrue(r.ok, r.error ?? "")
        let work = try await first.value
        XCTAssertEqual(work, "/private/tmp/monad-macsetup.AbC123")
        await assertEventually { log.latest("web")?.macSetup == nil }
        r = await answer { $0.macSetupWork = "/private/tmp/monad-macsetup.Again1" }
        XCTAssertFalse(r.ok, "nothing is asked any more")

        let second = ask()
        await assertEventually { log.latest("web")?.macSetup != nil }
        _ = await answer { $0.macSetupError = "You chose not to finish setting it up." }
        do {
            _ = try await second.value
            XCTFail("refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("chose not"), error.localizedDescription)
        }

        let third = ask()
        await assertEventually { log.latest("web")?.macSetup != nil }
        await send(app, .delete, name: "web")
        do {
            _ = try await third.value
            XCTFail("the VM went")
        } catch {}
        XCTAssertEqual(service.workFolderParent, "/private/tmp")
    }

    /// With no app open, Monad is opened to ask.
    func testAMacOSSetupOpensTheApp() async throws {
        let (app, log) = await connect()
        try await provisioned(app, log, "web")
        app.close()
        var opened = 0
        service.openApp = { opened += 1 }
        let asking = Task { @MainActor in
            try await self.service.authorize(vm: "web", disk: URL(fileURLWithPath: "/d"), payload: URL(fileURLWithPath: "/p"))
        }
        await assertEventually { opened == 1 }
        asking.cancel()
        service.cancelMacSetup("web")
        _ = try? await asking.value
    }

    // MARK: VM commands

    func testEnsureDefaultProvisionsAndReportsProgress() async throws {
        let (c, log) = await connect()
        let r = await send(c, .ensureDefault)
        XCTAssertEqual(r.instance?.name, "default")
        XCTAssertTrue(r.instance?.state.isPreparing ?? false, "\(String(describing: r.instance?.state))")
        await assertEventually { log.latest("default")?.state == .stopped }
        let r4 = await send(c, .ensureDefault)
        XCTAssertEqual(r4.instance?.state, .stopped, "second call returns the same VM")
    }

    func testListReturnsEveryVM() async throws {
        let (c, log) = await connect()
        try await provisioned(c, log, "default")
        try await provisioned(c, log, "work")
        let r5 = await send(c, .list)
        XCTAssertEqual(r5.instances?.map(\.name), ["default", "work"])
    }

    /// The top VM is the default one (the first tab when Monad opens): a
    /// new VM goes to the bottom, a reorder is saved and told to every app,
    /// a restarted host reads it back, and deleting the default makes the
    /// next one the default. Ephemeral VMs are never in the order.
    /// The default VM is chosen, not the top of the list: before one is
    /// chosen it is the top one (as before), then reordering leaves it
    /// alone; it is told to every app and kept; deleted, the top one is the
    /// default again.
    func testTheDefaultVMIsChosen() async throws {
        let (c, log) = await connect()
        try await provisioned(c, log, "web")
        try await provisioned(c, log, "db")
        var list = await send(c, .list)
        XCTAssertEqual(list.defaultVM, "web", "none chosen yet: the top one")
        let chosen = await send(c, .setDefault, name: "db")
        XCTAssertTrue(chosen.ok, chosen.error ?? "")
        XCTAssertEqual(chosen.defaultVM, "db")
        await assertEventually { log.events.contains(.defaultVM("db")) }
        let chosenFirst = await send(c, .ensureDefault)
        XCTAssertEqual(chosenFirst.instance?.name, "db")
        await send(c, .reorder, names: ["web"])
        list = await send(c, .list)
        XCTAssertEqual(list.order, ["web", "db"])
        XCTAssertEqual(list.defaultVM, "db", "the order does not choose it")
        let restarted = fixture.makeManager()
        restarted.load()
        XCTAssertEqual(restarted.defaultInstance().name, "db")
        let ghost = await send(c, .setDefault, name: "ghost")
        XCTAssertFalse(ghost.ok)
        await send(c, .delete, name: "db")
        let after = await send(c, .ensureDefault)
        XCTAssertEqual(after.instance?.name, "web")
    }

    func testTheTopVMIsTheDefault() async throws {
        let (c, log) = await connect()
        try await provisioned(c, log, "web")
        let only = await send(c, .ensureDefault)
        XCTAssertEqual(only.instance?.name, "web", "the only VM is the default, no new one is made")
        try await provisioned(c, log, "db")
        let list = await send(c, .list)
        XCTAssertEqual(list.instances?.map(\.name), ["web", "db"], "a new VM goes to the bottom")
        XCTAssertEqual(list.order, ["web", "db"])

        let moved = await send(c, .reorder, names: ["db"])
        XCTAssertTrue(moved.ok, moved.error ?? "")
        XCTAssertEqual(moved.order, ["db", "web"])
        XCTAssertEqual(moved.instances?.map(\.name), ["db", "web"])
        await assertEventually { log.events.contains(.order(["db", "web"])) }
        let top = await send(c, .ensureDefault)
        XCTAssertEqual(top.instance?.name, "db")

        let tmp = await send(c, .createEphemeral)
        let tmpName = try XCTUnwrap(tmp.instance?.name)
        await assertEventually { log.latest(tmpName)?.state == .stopped }
        let withTmp = await send(c, .reorder, names: [tmpName, "web"])
        XCTAssertEqual(withTmp.order, ["web", "db"], "an ephemeral VM cannot be the default")
        XCTAssertEqual(withTmp.instances?.map(\.name), ["web", "db", tmpName])

        let restarted = fixture.makeManager()
        restarted.load()
        XCTAssertEqual(restarted.instances.map(\.name), ["web", "db"])
        XCTAssertEqual(restarted.defaultInstance().name, "web")

        await send(c, .delete, name: "web")
        let next = await send(c, .ensureDefault)
        XCTAssertEqual(next.instance?.name, "db")
        let after = await send(c, .list)
        XCTAssertEqual(after.order, ["db"])
    }

    func testUnknownVMIsAnError() async {
        let (c, _) = await connect()
        let r = await send(c, .start, name: "nope")
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.error, "No VM named nope.")
    }

    /// A VM's connection log comes from netd while it runs on a Monad
    /// network; a stopped VM has none to ask for.
    func testAVMsConnectionsComeFromNetd() async throws {
        let (c, log) = await connect()
        try await provisioned(c, log)
        let entry = NetConnection(proto: .udp, address: "9.9.9.9", port: 53, verdict: .denied, reason: .byDefault,
                                  rule: nil, opened: 0, refused: 1, asked: 0, active: 0, bytesOut: 0, bytesIn: 0,
                                  firstSeen: 5, lastSeen: 5, name: nil)
        fixture.networks.connectionLog["default"] = [entry]
        let stopped = await send(c, .connections, name: "default")
        XCTAssertTrue(stopped.ok, stopped.error ?? "")
        XCTAssertEqual(stopped.connections, [])
        XCTAssertTrue(fixture.networks.connectionsAsked.isEmpty, "netd is not asked about a stopped VM")
        await send(c, .start, name: "default")
        await assertEventually { log.latest("default")?.state == .ready }
        let running = await send(c, .connections, name: "default")
        XCTAssertEqual(running.connections, [entry])
        XCTAssertEqual(fixture.networks.connectionsAsked, ["default"])
        let unknown = await send(c, .connections, name: "nope")
        XCTAssertFalse(unknown.ok)
    }

    /// VM-to-VM traffic on every Monad network, for the canvas.
    func testTrafficComesFromNetd() async throws {
        let (c, _) = await connect()
        let t = VMTraffic(network: "default", from: "a", to: "b", frames: 3, bytes: 180, lastSeen: 1)
        fixture.networks.traffic = [t]
        let r = await send(c, .traffic)
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(r.traffic, [t])
    }

    func testCreateValidatesAgainstHostLimits() async throws {
        let (c, log) = await connect()
        var big = config("big")
        big.cpus = 64
        let r = await send(c, .create, config: big)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.error, InstanceConfig.ValidationError.cpus(64, max: 8).localizedDescription)

        try await provisioned(c, log, "work")
        let r6 = await send(c, .create, config: config("work"))
        XCTAssertFalse(r6.ok, "duplicate name")
    }

    /// A Mac VM from the New VM sheet comes with its install image and SIP
    /// choice; what runs in it is known from its distribution before its
    /// settings are checked, so they are accepted.
    func testAMacVMsSettingsAreCheckedAsMacOS() async throws {
        let (c, _) = await connect()
        var mac = config("mac")
        mac.distro = "macos"
        mac.release = nil
        mac.memoryGiB = 4
        mac.diskGiB = 64
        mac.restoreImage = "/Users/dev/.monad/_cache/images/macos/UniversalMac_27.0.1_26A434_Restore.ipsw"
        mac.systemIntegrityProtection = false
        let r = await send(c, .create, config: mac)
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(r.instance?.config.guestOS, .macos)
    }

    func testStartAndGracefulStop() async throws {
        let (c, log) = await connect()
        try await provisioned(c, log)
        let r7 = await send(c, .start, name: "default")
        XCTAssertTrue(r7.ok)
        await assertEventually { log.latest("default")?.state == .ready }
        let r8 = await send(c, .stop, name: "default")
        XCTAssertTrue(r8.ok)
        await assertEventually { log.latest("default")?.state == .stopped }
        XCTAssertEqual(fixture.factory.machine.stopRequests, 1)
        XCTAssertEqual(fixture.factory.machine.forceStops, 0)
    }

    func testRestartAppliesSavedSettings() async throws {
        let (c, log) = await connect()
        try await provisioned(c, log)
        await send(c, .start, name: "default")
        await assertEventually { log.latest("default")?.state == .ready }
        var changed = try XCTUnwrap(log.latest("default")).config
        changed.cpus = 3
        let r = await send(c, .update, config: changed)
        XCTAssertEqual(r.instance?.pendingRestart, ["CPUs"])
        let made = fixture.factory.made.count
        let r2 = await send(c, .restart, name: "default")
        XCTAssertTrue(r2.ok, r2.error ?? "")
        await assertEventually { log.latest("default")?.state == .ready && self.fixture.factory.made.count == made + 1 }
        XCTAssertNil(log.latest("default")?.pendingRestart)
        XCTAssertEqual(fixture.factory.made.last?.config.cpus, 3)
        XCTAssertEqual(fixture.factory.machine.stopRequests, 1, "a clean shutdown, not a power cut")
    }

    func testRestartOfAStoppedVMStartsIt() async throws {
        let (c, log) = await connect()
        try await provisioned(c, log)
        let r = await send(c, .restart, name: "default")
        XCTAssertTrue(r.ok, r.error ?? "")
        await assertEventually { log.latest("default")?.state == .ready }
    }

    func testForcedStopPowersOff() async throws {
        let (c, log) = await connect()
        try await provisioned(c, log)
        await send(c, .start, name: "default")
        await assertEventually { log.latest("default")?.state == .ready }
        await send(c, .stop, name: "default", force: true)
        await assertEventually { log.latest("default")?.state == .stopped }
        XCTAssertEqual(fixture.factory.machine.forceStops, 1)
    }

    func testUpdateIsValidatedAndReachesRunningVMs() async throws {
        let (c, log) = await connect()
        try await provisioned(c, log, "work")
        var changed = try XCTUnwrap(log.latest("work")).config
        changed.cpus = 4
        let r = await send(c, .update, config: changed)
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(r.instance?.config.cpus, 4)
        XCTAssertEqual(try InstanceConfig.load(from: fixture.manager.paths(for: "work").config).cpus, 4)

        changed.memoryGiB = 999
        let r9 = await send(c, .update, config: changed)
        XCTAssertFalse(r9.ok, "validated like create")

        changed.memoryGiB = 2
        await send(c, .start, name: "work")
        await assertEventually { log.latest("work")?.state == .ready }
        changed = try XCTUnwrap(log.latest("work")).config
        changed.cpus = 2
        let r10 = await send(c, .update, config: changed)
        XCTAssertTrue(r10.ok, r10.error ?? "")
        XCTAssertEqual(r10.instance?.pendingRestart, ["CPUs"])
        XCTAssertEqual(r10.instance?.state, .ready)
    }

    func testDeleteRemovesFilesAndNotifies() async throws {
        let (c, log) = await connect()
        try await provisioned(c, log, "work")
        let r11 = await send(c, .delete, name: "work")
        XCTAssertTrue(r11.ok)
        XCTAssertTrue(log.removed("work"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manager.paths(for: "work").dir.path))
        let r12 = await send(c, .list)
        XCTAssertEqual(r12.instances, [])
    }

    // MARK: Tab sessions

    func testAttachStartsTheVMAndCountsSessions() async throws {
        let (c, log) = await connect()
        try await provisioned(c, log)
        let r = await send(c, .attach, name: "default")
        XCTAssertEqual(r.instance?.sessions, 1)
        await assertEventually { log.latest("default")?.state == .ready }
        await send(c, .attach, name: "default")
        XCTAssertEqual(log.latest("default")?.sessions, 2)
        await send(c, .detach, name: "default")
        XCTAssertEqual(log.latest("default")?.sessions, 1)
        XCTAssertEqual(log.latest("default")?.state, .ready, "detaching never stops a persistent VM")
    }

    func testAttachWhileProvisioningStartsWhenReady() async throws {
        let (c, log) = await connect()
        await send(c, .ensureDefault)
        await send(c, .attach, name: "default")
        await assertEventually { log.latest("default")?.state == .ready }
    }

    func testDetachWithoutAttachIsIgnored() async throws {
        let (c, log) = await connect()
        try await provisioned(c, log)
        await send(c, .detach, name: "default")
        await send(c, .attach, name: "default")
        XCTAssertEqual(log.latest("default")?.sessions, 1, "a connection can only release what it holds")
    }

    func testEphemeralVMIsDeletedWhenItsLastTabDetaches() async throws {
        let (c, log) = await connect()
        let r13 = await send(c, .createEphemeral)
        let name = try XCTUnwrap(r13.instance?.name)
        await send(c, .attach, name: name)
        await assertEventually { log.latest(name)?.state == .ready }
        await send(c, .detach, name: name)
        await assertEventually { log.removed(name) }
    }

    func testClosingAConnectionReleasesItsSessions() async throws {
        let (app, _) = await connect()
        let (_, log) = await connect()
        let r14 = await send(app, .createEphemeral)
        let name = try XCTUnwrap(r14.instance?.name)
        await send(app, .attach, name: name)
        await assertEventually { log.latest(name)?.state == .ready }

        app.close() // the app quit or crashed
        await assertEventually { log.removed(name) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manager.paths(for: name).dir.path))
    }

    func testPersistentVMKeepsRunningWhenTheAppGoesAway() async throws {
        let (app, log) = await connect()
        try await provisioned(app, log)
        await send(app, .attach, name: "default")
        await assertEventually { log.latest("default")?.state == .ready }
        app.close()

        let (again, _) = await connect()
        let r15 = await send(again, .list)
        let snap = try XCTUnwrap(r15.instances?.first)
        XCTAssertEqual(snap.state, .ready)
        XCTAssertEqual(snap.sessions, 0)
    }

    // MARK: Events

    func testEventsReachEveryConnectionButNotClosedOnes() async throws {
        let (a, logA) = await connect()
        let (b, logB) = await connect()
        let (gone, logGone) = await connect()
        gone.close()
        try await provisioned(a, logA)
        await send(a, .start, name: "default")
        await assertEventually { logB.latest("default")?.state == .ready }
        XCTAssertTrue(logGone.events.isEmpty)
        _ = b
    }

    /// Canvas notes: MonadHost keeps them, says who wrote them (an app is
    /// "you", whatever it claims), tells every app, and forgets a deleted
    /// VM's labels.
    func testCanvasNotesAreKeptAndShared() async throws {
        let (a, logA) = await connect()
        let (b, logB) = await connect()
        try await provisioned(a, logA, "web")
        var label = CanvasNote(id: "l1", kind: .label, text: "C2", on: "vm:web")
        label.author = "mac"
        var set = HostRequest(id: 900, op: .setNote)
        set.note = label
        var r = await a.handle(set)
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(r.notes?.map(\.author), ["you"])
        XCTAssertTrue(logB.events.contains(.notes(r.notes ?? [])), "every app is told")
        set.note = CanvasNote(id: "n1", kind: .note, text: "**lab**")
        r = await b.handle(set)
        XCTAssertEqual(r.notes?.map(\.id), ["l1", "n1"])
        // Kept on disk for the next MonadHost.
        let again = HostService(manager: fixture.manager, agents: fixture.tmp.url.appendingPathComponent("agents"))
        XCTAssertEqual(again.notes.map(\.id), ["l1", "n1"])

        set.note?.text = "edited"
        set.note?.author = "vm:web"
        r = await b.handle(set)
        XCTAssertEqual(r.notes?.last?.text, "edited")
        XCTAssertEqual(r.notes?.last?.author, "you", "an edit keeps who wrote it")

        await send(a, .delete, name: "web")
        XCTAssertEqual(service.notes.map(\.id), ["n1"], "the deleted VM's label went with it")
        var remove = HostRequest(id: 901, op: .removeNote)
        remove.noteID = "n1"
        r = await a.handle(remove)
        XCTAssertEqual(r.notes, [])
        r = await a.handle(remove)
        XCTAssertFalse(r.ok, "no such note")
    }

    func testSnapshotsCarryGuestPortsAndAgentState() async throws {
        let (c, log) = await connect()
        try await provisioned(c, log)
        let ch = SocketPairChannel()
        fixture.factory.machine.channels = [ch]
        fixture.runner.setHandler { call in
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            if call.arguments.last == CloudInit.guestInstallCommand { return .ok("agent-ok\n") }
            return .ok()
        }
        await send(c, .start, name: "default")
        await assertEventually { log.latest("default")?.agent == true }
        await assertEventually { self.fixture.factory.machine.openedPorts == [CloudInit.agentVsockPort] }
        ch.agentSays("hello monad-agent 1\nport+ tcp 0.0.0.0 8000\n")
        await assertEventually { log.latest("default")?.ports == [ListeningPort(address: "0.0.0.0", port: 8000)] }
    }
}

extension HostRequest {
    /// The request with fields set that its initializer does not take.
    func with(_ change: (inout HostRequest) -> Void) -> HostRequest {
        var r = self
        change(&r)
        return r
    }
}
