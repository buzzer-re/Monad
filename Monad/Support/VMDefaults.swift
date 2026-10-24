//
//  VMDefaults.swift — sizing of new VMs. Shared by the app (settings UI)
//  and MonadHost, which lives inside the app bundle and therefore reads the
//  same preferences domain.
//

import Foundation

enum VMDefaults {
    static let cpusKey = "defaultCPUs"
    static let memoryKey = "defaultMemoryGiB"
    static let diskKey = "defaultDiskGiB"

    static func register() {
        let cores = ProcessInfo.processInfo.processorCount
        let memGiB = Int(ProcessInfo.processInfo.physicalMemory >> 30)
        UserDefaults.standard.register(defaults: [
            cpusKey: max(2, min(4, cores / 2)),
            memoryKey: max(2, min(4, memGiB / 4)),
            diskKey: 50,
        ])
    }

    /// Stored preferences never size a VM beyond this Mac.
    static var cpus: Int { cpus(.standard, capacity: .current) }
    static var memoryGiB: Int { memoryGiB(.standard, capacity: .current) }

    static func cpus(_ defaults: UserDefaults, capacity: HostCapacity) -> Int {
        capacity.clampCPUs(defaults.integer(forKey: cpusKey))
    }

    static func memoryGiB(_ defaults: UserDefaults, capacity: HostCapacity) -> Int {
        capacity.clampMemory(defaults.integer(forKey: memoryKey))
    }
    static var diskGiB: Int { max(10, UserDefaults.standard.integer(forKey: diskKey)) }
}
