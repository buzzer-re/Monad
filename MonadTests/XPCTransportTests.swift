//
//  XPCTransportTests.swift — the production transport over real XPC, run
//  in-process through an anonymous listener (no launchd involved).
//

import XCTest
@testable import Monad

@MainActor
final class XPCTransportTests: XCTestCase {
    private var fixture: ManagerFixture!
    private var service: HostService!
    private var listener: HostXPCListener!
    private var transports: [XPCHostTransport] = []

    override func setUp() async throws {
        fixture = try ManagerFixture()
        service = HostService(manager: fixture.manager, limits: .init(maxCPUs: 8, maxMemoryGiB: 16))
    }

    override func tearDown() async throws {
        for t in transports { t.invalidate() }
        listener?.invalidate()
    }

    private func listen(requirement: String? = nil) {
        listener = HostXPCListener(listener: .anonymous(), service: service, peerRequirement: requirement)
        listener.resume()
    }

    private func transport() -> XPCHostTransport {
        let t = XPCHostTransport(endpoint: listener.endpoint, peerRequirement: nil)
        transports.append(t)
        return t
    }

    private func call(_ t: XPCHostTransport, _ r: HostRequest) async throws -> HostResponse {
        try HostProtocol.decode(HostResponse.self, from: try await t.send(try HostProtocol.encode(r)))
    }

    func testRequestsRoundTrip() async throws {
        listen()
        let t = transport()
        let hello = try await call(t, HostRequest(id: 1, op: .hello, version: HostProtocol.version))
        var expected = HostResponse(id: 1, version: HostProtocol.version)
        expected.build = HostBuild.current
        XCTAssertEqual(hello, expected)
        let list = try await call(t, HostRequest(id: 2, op: .list))
        var listed = HostResponse(id: 2, instances: [])
        listed.order = []
        XCTAssertEqual(list, listed)
    }

    func testEventsArrive() async throws {
        listen()
        let t = transport()
        var events: [HostEvent] = []
        t.onEvent = { data in
            if let e = try? HostProtocol.decode(HostEvent.self, from: data) { events.append(e) }
        }
        _ = try await call(t, HostRequest(id: 1, op: .hello, version: HostProtocol.version))
        _ = try await call(t, HostRequest(id: 2, op: .ensureDefault))
        await assertEventually {
            events.contains { if case .instance(let s) = $0 { return s.state == .stopped } else { return false } }
        }
    }

    func testHostSideInvalidationIsReported() async throws {
        listen()
        let t = transport()
        var lost = false
        t.onInvalidated = { lost = true }
        _ = try await call(t, HostRequest(id: 1, op: .hello, version: HostProtocol.version))
        listener.invalidate()
        await assertEventually { lost }
        do {
            _ = try await call(t, HostRequest(id: 2, op: .list))
            XCTFail("a dead connection cannot answer")
        } catch {}
    }

    func testClosingTheClientReleasesItsHostConnection() async throws {
        listen()
        let t = transport()
        _ = try await call(t, HostRequest(id: 1, op: .hello, version: HostProtocol.version))
        XCTAssertEqual(service.connectionCount, 1)
        var lost = false
        t.onInvalidated = { lost = true }
        t.invalidate()
        await assertEventually { self.service.connectionCount == 0 }
        XCTAssertFalse(lost, "closing our own side is not a loss")
    }

    func testPeersFailingTheCodeRequirementAreRefused() async throws {
        listen(requirement: #"identifier "dev.monad.not-us""#)
        let t = transport()
        do {
            _ = try await call(t, HostRequest(id: 1, op: .hello, version: HostProtocol.version))
            XCTFail("an unsigned or foreign peer must not be served")
        } catch {}
        XCTAssertEqual(service.connectionCount, 0)
    }

    /// Signed ad hoc, MonadHost pins its clients to Monad's own binaries as
    /// installed: the identifier and the code hash read from disk at each
    /// connection. This test process is Monad.app's binary: served when the
    /// pin names it, refused when it names another binary with the same
    /// identifier (a process that only borrows Monad's identifier).
    func testAdHocClientsArePinnedToTheInstalledBinaries() async throws {
        let app = try XCTUnwrap(Bundle.main.executableURL)
        let host = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: "MonadHost"))
        let pinned = try XCTUnwrap(HostXPCSecurity.clientRequirement(team: nil, app: app, host: host))
        let ours = try XCTUnwrap(HostXPCSecurity.cdhash(of: app))
        XCTAssertTrue(pinned.contains(#"identifier "\#(HostXPCSecurity.appIdentifier)" and cdhash H"\#(ours)""#), pinned)
        XCTAssertEqual(ours.count, 40, "a code directory hash, in hex")
        listener = HostXPCListener(listener: .anonymous(), service: service) {
            HostXPCSecurity.clientRequirement(team: nil, app: app, host: host)
        }
        listener.resume()
        _ = try await call(transport(), HostRequest(id: 1, op: .hello, version: HostProtocol.version))
        XCTAssertEqual(service.connectionCount, 1, "Monad's own binary is served")
        for t in transports { t.invalidate() }
        transports = []
        listener.invalidate()
        await assertEventually { self.service.connectionCount == 0 }

        // The pin names another binary as the app (MonadHost's hash under the app's identifier).
        listener = HostXPCListener(listener: .anonymous(), service: service) {
            HostXPCSecurity.clientRequirement(team: nil, app: host, host: host)
        }
        listener.resume()
        do {
            _ = try await call(transport(), HostRequest(id: 2, op: .hello, version: HostProtocol.version))
            XCTFail("a binary other than the installed one must not be served")
        } catch {}
        XCTAssertEqual(service.connectionCount, 0)

        // A requirement that cannot be read refuses (fails closed).
        listener.invalidate()
        listener = HostXPCListener(listener: .anonymous(), service: service) { nil }
        listener.resume()
        do {
            _ = try await call(transport(), HostRequest(id: 3, op: .hello, version: HostProtocol.version))
            XCTFail("no requirement, no service")
        } catch {}
        XCTAssertEqual(service.connectionCount, 0)
        XCTAssertNil(HostXPCSecurity.clientRequirement(team: nil, app: URL(fileURLWithPath: "/nonexistent/Monad"), host: host))
    }

    /// A build signed with a team requires that team: an ad hoc signed peer
    /// (any local process can be signed so, with any identifier) is refused.
    func testAnAdHocPeerFailsATeamRequirement() async throws {
        listen(requirement: #"anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345" and "#
            + #"(identifier "\#(HostXPCSecurity.appIdentifier)" or identifier "\#(HostXPCSecurity.hostIdentifier)")"#)
        let t = transport()
        do {
            _ = try await call(t, HostRequest(id: 1, op: .hello, version: HostProtocol.version))
            XCTFail("a peer without the team's certificate must not be served")
        } catch {}
        XCTAssertEqual(service.connectionCount, 0)
    }

    func testOwnSignatureSatisfiesTheDefaultRequirement() async throws {
        let requirement = try XCTUnwrap(HostXPCSecurity.peerRequirement())
        listen(requirement: requirement)
        let t = transport()
        let hello = try await call(t, HostRequest(id: 1, op: .hello, version: HostProtocol.version))
        XCTAssertTrue(hello.ok)
    }

    func testHostClientWorksEndToEndOverXPC() async throws {
        listen()
        let endpoint = listener.endpoint
        let client = HostClient(connect: { XPCHostTransport(endpoint: endpoint, peerRequirement: nil) },
                                clock: TestClock(realDelay: 0.001), instanceRoot: fixture.root)
        client.start()
        defer { client.stop() }
        let vm = try await client.ensureDefault()
        await assertEventually { vm.state == .stopped }
        try await client.attach(vm.name)
        await assertEventually("state \(vm.state)") { vm.state == .ready }
        XCTAssertEqual(vm.sessions, 1)
    }
}
