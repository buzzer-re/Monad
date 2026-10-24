//
//  VMState.swift — lifecycle phase of a VM, shared by the host (which owns
//  the VM) and the app (which mirrors it).
//

import Foundation

enum VMState: Equatable, Sendable {
    case preparing(String) // creating disk / preparing image
    case stopped
    case starting
    case booting  // VM running, waiting for sshd over vsock
    case ready
    case stopping
    case failed(String)

    var label: String {
        switch self {
        case .preparing(let s): return s
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .booting: return "Booting"
        case .ready: return "Running"
        case .stopping: return "Stopping"
        case .failed(let m): return "Error: \(m)"
        }
    }

    /// For the debug log: "ready", "failed: why".
    var debugName: String {
        switch self {
        case .preparing(let s): return "preparing (\(s))"
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .booting: return "booting"
        case .ready: return "ready"
        case .stopping: return "stopping"
        case .failed(let m): return "failed: \(m)"
        }
    }

    var isRunning: Bool { [.starting, .booting, .ready, .stopping].contains(self) }
    var isFailed: Bool { if case .failed = self { return true } else { return false } }
    var isPreparing: Bool { if case .preparing = self { return true } else { return false } }
}
