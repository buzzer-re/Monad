//
//  HostCapacityTests.swift — how much of the Mac a VM may use. One source
//  for MonadHost's validation, the default sizes and every picker.
//

import XCTest
@testable import Monad

final class HostCapacityTests: XCTestCase {
    private let gib: UInt64 = 1 << 30

    func testMemoryLeavesRoomForMacOS() {
        let c = HostCapacity(cores: 10, memoryBytes: 16 * gib, vmMaxCPUs: 64, vmMaxMemoryBytes: 1024 * gib)
        XCTAssertEqual(c.maxCPUs, 10)
        XCTAssertEqual(c.maxMemoryGiB, 14)
        XCTAssertEqual(c.memoryGiB, 16)
        XCTAssertEqual(HostCapacity(cores: 4, memoryBytes: 8 * gib, vmMaxCPUs: 64, vmMaxMemoryBytes: 1024 * gib).maxMemoryGiB, 6)
        XCTAssertEqual(HostCapacity(cores: 1, memoryBytes: 2 * gib, vmMaxCPUs: 64, vmMaxMemoryBytes: 1024 * gib).maxMemoryGiB, 1,
                       "never below 1 GB")
    }

    func testVirtualizationLimitsWin() {
        let c = HostCapacity(cores: 24, memoryBytes: 192 * gib, vmMaxCPUs: 16, vmMaxMemoryBytes: 64 * gib)
        XCTAssertEqual(c.maxCPUs, 16)
        XCTAssertEqual(c.maxMemoryGiB, 64)
    }

    func testOddMemorySizesRoundDown() {
        let c = HostCapacity(cores: 8, memoryBytes: 18 * gib - 1, vmMaxCPUs: 64, vmMaxMemoryBytes: 1024 * gib)
        XCTAssertEqual(c.memoryGiB, 17)
        XCTAssertEqual(c.maxMemoryGiB, 15)
    }

    func testClamping() {
        let c = HostCapacity(cores: 8, memoryBytes: 16 * gib, vmMaxCPUs: 64, vmMaxMemoryBytes: 1024 * gib)
        XCTAssertEqual(c.clampCPUs(64), 8)
        XCTAssertEqual(c.clampCPUs(0), 1)
        XCTAssertEqual(c.clampMemory(256), 14)
        XCTAssertEqual(c.clampMemory(0), 1)
    }

    func testTheHostValidatesWithTheSameLimits() {
        let limits = HostService.Limits(HostCapacity.current)
        XCTAssertEqual(limits.maxCPUs, HostCapacity.current.maxCPUs)
        XCTAssertEqual(limits.maxMemoryGiB, HostCapacity.current.maxMemoryGiB)
        XCTAssertLessThan(limits.maxMemoryGiB, Int(ProcessInfo.processInfo.physicalMemory >> 30))
    }

    func testStoredDefaultsNeverExceedTheMac() {
        let defaults = UserDefaults(suiteName: "monad-capacity-\(UUID().uuidString)")!
        let c = HostCapacity(cores: 8, memoryBytes: 16 * gib, vmMaxCPUs: 64, vmMaxMemoryBytes: 1024 * gib)
        defaults.set(256, forKey: VMDefaults.memoryKey)
        defaults.set(64, forKey: VMDefaults.cpusKey)
        XCTAssertEqual(VMDefaults.memoryGiB(defaults, capacity: c), 14)
        XCTAssertEqual(VMDefaults.cpus(defaults, capacity: c), 8)
    }
}
