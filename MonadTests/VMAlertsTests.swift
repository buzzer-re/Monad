//
//  VMAlertsTests.swift — the notifications Monad posts, like VMware's: a VM
//  low on memory or disk space, a problem its health shows, the Mac's own
//  disk almost full. Each once, until it clears and comes back.
//

import XCTest
@testable import Monad

final class VMAlertsTests: XCTestCase {
    private let lowMemory = GuestWarning(kind: .lowMemory, percent: 93)
    private let lowDisk = GuestWarning(kind: .lowDisk, percent: 91, mount: "/")

    private func vm(_ name: String, running: Bool = true, _ warnings: [GuestWarning] = [],
                    health: String? = nil) -> VMAlerts.VM {
        VMAlerts.VM(name: name, running: running, warnings: warnings, health: health)
    }

    func testAWarningIsNotifiedOnceWithWhatToDo() throws {
        var alerts = VMAlerts()
        XCTAssertEqual(alerts.update([vm("dev")]), [])
        let said = alerts.update([vm("dev", [lowMemory])])
        XCTAssertEqual(said.count, 1)
        let a = try XCTUnwrap(said.first)
        XCTAssertEqual(a.vm, "dev")
        XCTAssertEqual(a.title, "“dev” is low on memory")
        XCTAssertEqual(a.body, "93% of its memory is in use. Give it more in its settings › Resources, or close programs in it.")
        XCTAssertEqual(alerts.update([vm("dev", [GuestWarning(kind: .lowMemory, percent: 97)])]), [], "once")

        let disk = try XCTUnwrap(alerts.update([vm("dev", [lowMemory, lowDisk])]).first)
        XCTAssertEqual(disk.title, "“dev” is low on disk space")
        XCTAssertEqual(disk.body, "Its disk (/) is 91% full. Programs in it fail to write once it is full: free some space in it.")
    }

    func testAWarningThatClearsAndComesBackIsNotifiedAgain() {
        var alerts = VMAlerts()
        XCTAssertEqual(alerts.update([vm("dev", [lowMemory])]).count, 1)
        XCTAssertEqual(alerts.update([vm("dev")]), [])
        XCTAssertEqual(alerts.update([vm("dev", [lowMemory])]).count, 1, "again")
        XCTAssertEqual(alerts.update([vm("dev", running: false, [lowMemory])]), [], "a stopped VM warns of nothing")
        XCTAssertEqual(alerts.update([vm("dev", [lowMemory])]).count, 1, "a new run starts clean")
        XCTAssertEqual(alerts.update([]), [], "a deleted VM is forgotten")
        XCTAssertEqual(alerts.update([vm("dev", [lowMemory])]).count, 1)
    }

    func testEachVMIsItsOwn() {
        var alerts = VMAlerts()
        XCTAssertEqual(alerts.update([vm("a", [lowMemory]), vm("b", [lowMemory])]).map(\.vm), ["a", "b"])
    }

    func testAHealthProblemIsNotifiedWhenItIsNew() throws {
        var alerts = VMAlerts()
        let oom = "The VM ran out of memory: Linux stopped node to free some. Give it more memory (its settings › Resources)."
        let a = try XCTUnwrap(alerts.update([vm("dev", health: oom)]).first)
        XCTAssertEqual(a.title, "“dev” has a problem")
        XCTAssertEqual(a.body, oom)
        XCTAssertEqual(alerts.update([vm("dev", health: oom)]), [])
        let more = oom + " The VM's disk is 96% full: programs in it may fail to write. Free some space in it."
        XCTAssertEqual(alerts.update([vm("dev", health: more)]).map(\.body), [more], "a new problem")
        XCTAssertEqual(alerts.update([vm("dev", running: false, health: more)]), [], "kept after it stops: not again")
    }

    func testTheyAreOnByDefault() {
        XCTAssertEqual(Settings.defaults[SettingsKey.vmAlerts] as? Bool, true)
    }

    func testTheMacsDiskIsWarnedWhenItIsAlmostFull() throws {
        var alerts = VMAlerts()
        let gb: Int64 = 1 << 30
        XCTAssertEqual(alerts.update(macFree: 50 * gb), [])
        let a = try XCTUnwrap(alerts.update(macFree: 3 * gb + gb / 5).first)
        XCTAssertNil(a.vm)
        XCTAssertEqual(a.title, "Your Mac is low on disk space")
        XCTAssertEqual(a.body, "3.2 GB free. VMs fail to write to their disks when it is full: free some space on your Mac.")
        XCTAssertEqual(alerts.update(macFree: 2 * gb), [], "once")
        XCTAssertEqual(alerts.update(macFree: 12 * gb), [], "not clear yet below 15 GB")
        XCTAssertEqual(alerts.update(macFree: 9 * gb), [], "still the same episode")
        XCTAssertEqual(alerts.update(macFree: 20 * gb), [])
        XCTAssertEqual(alerts.update(macFree: 5 * gb).count, 1, "again")
    }
}
