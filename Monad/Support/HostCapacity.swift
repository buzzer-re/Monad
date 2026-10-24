//
//  HostCapacity.swift — how much of this Mac a VM may use. MonadHost
//  validates against it and every size picker is bounded by it.
//

import Foundation

struct HostCapacity: Equatable, Sendable {
    /// Memory always left to macOS.
    static let reservedMemoryGiB = 2

    /// CPU cores and whole GB of memory in this Mac.
    let cores: Int
    let memoryGiB: Int
    let maxCPUs: Int
    let maxMemoryGiB: Int

    init(cores: Int, memoryBytes: UInt64, vmMaxCPUs: Int, vmMaxMemoryBytes: UInt64) {
        self.cores = max(1, cores)
        memoryGiB = Int(memoryBytes >> 30)
        maxCPUs = max(1, min(self.cores, vmMaxCPUs))
        maxMemoryGiB = max(1, min(memoryGiB - Self.reservedMemoryGiB, Int(vmMaxMemoryBytes >> 30)))
    }

    static var current: HostCapacity {
        HostCapacity(cores: ProcessInfo.processInfo.processorCount, memoryBytes: ProcessInfo.processInfo.physicalMemory,
                     vmMaxCPUs: Int(MNDVirtualMachine.maximumCPUCount()),
                     vmMaxMemoryBytes: MNDVirtualMachine.maximumMemoryBytes())
    }

    func clampCPUs(_ n: Int) -> Int { min(max(1, n), maxCPUs) }
    func clampMemory(_ gib: Int) -> Int { min(max(1, gib), maxMemoryGiB) }
}

extension HostService.Limits {
    init(_ capacity: HostCapacity) {
        self.init(maxCPUs: capacity.maxCPUs, maxMemoryGiB: capacity.maxMemoryGiB)
    }
}
