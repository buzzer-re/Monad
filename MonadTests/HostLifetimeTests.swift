//
//  HostLifetimeTests.swift — MonadHost is started on demand by launchd and
//  exits once nothing needs it: no app connected and no VM running or being
//  created, for a grace period.
//

import XCTest
@testable import Monad

@MainActor
final class HostLifetimeTests: XCTestCase {
    private var fixture: ManagerFixture!
    private var service: HostService!
    private var lifetime: HostLifetime!
    private var exits = 0

    override func setUp() async throws {
        fixture = try ManagerFixture()
        service = HostService(manager: fixture.manager, limits: .init(maxCPUs: 8, maxMemoryGiB: 16))
        lifetime = HostLifetime(service: service, grace: 30, clock: TestClock(realDelay: 0.001)) { [weak self] in
            self?.exits += 1
        }
    }

    private func hello(_ c: HostConnection) async {
        _ = await c.handle(HostRequest(id: 1, op: .hello, version: HostProtocol.version))
    }

    func testExitsWhenIdleAfterGrace() async {
        lifetime.start()
        await assertEventually { self.exits == 1 }
    }

    func testAConnectedAppKeepsTheHostAlive() async throws {
        let c = service.connect { _ in }
        lifetime.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(exits, 0)
        c.close()
        await assertEventually { self.exits == 1 }
    }

    func testARunningVMKeepsTheHostAliveWithoutApps() async throws {
        let c = service.connect { _ in }
        await hello(c)
        _ = await c.handle(HostRequest(id: 2, op: .ensureDefault))
        await assertEventually { self.fixture.manager.existing("default")?.state == .stopped }
        _ = await c.handle(HostRequest(id: 3, op: .start, name: "default"))
        await assertEventually { self.fixture.manager.existing("default")?.state == .ready }
        lifetime.start()
        c.close()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(exits, 0, "VMs outlive the app")

        await fixture.manager.existing("default")?.stop()
        await assertEventually { self.exits == 1 }
    }

    func testProvisioningKeepsTheHostAlive() async throws {
        let c = service.connect { _ in }
        await hello(c)
        _ = await c.handle(HostRequest(id: 2, op: .ensureDefault))
        lifetime.start()
        c.close()
        XCTAssertTrue(service.isBusy, "creating a VM counts as work")
        await assertEventually { self.exits == 1 }
        XCTAssertEqual(fixture.manager.existing("default")?.state, .stopped, "exit only after provisioning finished")
    }

    func testActivityDuringGraceCancelsTheExit() async throws {
        lifetime = HostLifetime(service: service, grace: 3600, clock: SystemClock()) { [weak self] in
            self?.exits += 1
        }
        lifetime.start()
        let c = service.connect { _ in }
        c.close()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(exits, 0)
    }
}
