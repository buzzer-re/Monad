//
//  SSHForward.swift — a port carried between a VM and an SSH host, Monad in
//  the middle:
//
//      SSH host <── ssh master ──> Monad (a unix socket) <── ssh master ──> VM
//
//  Two forwards, one on each master, joined by a socket in the VM's folder
//  (0600, the user's own): never a TCP port of the Mac, so nothing else on
//  the Mac or its network can use the path. The VM reaches only the one
//  address the rule names, as the SSH host reaches it; or the SSH host
//  offers the one VM port the rule names.
//

import Foundation

struct SSHForward: Codable, Equatable, Hashable, Identifiable {
    enum Direction: String, Codable, CaseIterable {
        /// Programs in the VM connect to 127.0.0.1:guestPort and reach
        /// remoteHost:remotePort as the SSH host resolves and reaches it.
        case intoVM
        /// The SSH host listens on remoteHost:remotePort (an address of its
        /// own) and connections reach 127.0.0.1:guestPort in the VM.
        case ontoHost
    }

    static let maxPerVM = 8

    var id: UUID = UUID()
    /// The SSH host's name in Monad.
    var sshHost: String
    var direction: Direction
    var guestPort: Int
    var remoteHost: String = "127.0.0.1"
    var remotePort: Int
    var enabled: Bool = true

    /// Short, for the 104 bytes of a unix socket path.
    func socket(in paths: InstancePaths) -> URL {
        paths.dir.appendingPathComponent("sshfwd-" + id.uuidString.prefix(8).lowercased() + ".sock")
    }

    /// The forward on the VM's ssh master.
    func vmSpec(in paths: InstancePaths) -> SSHMux.Spec {
        let socket = socket(in: paths).path
        switch direction {
        case .intoVM: return SSHMux.Spec(flag: "-R", value: "127.0.0.1:\(guestPort):\(socket)")
        case .ontoHost: return SSHMux.Spec(flag: "-L", value: "\(socket):127.0.0.1:\(guestPort)")
        }
    }

    /// The forward on the SSH host's ssh master.
    func hostSpec(in paths: InstancePaths) -> SSHMux.Spec {
        let socket = socket(in: paths).path
        switch direction {
        case .intoVM: return SSHMux.Spec(flag: "-L", value: "\(socket):\(SSHMux.address(remoteHost)):\(remotePort)")
        case .ontoHost: return SSHMux.Spec(flag: "-R", value: "\(SSHMux.address(remoteHost)):\(remotePort):\(socket)")
        }
    }

    /// The socket the VM's master makes on the Mac (nil when the SSH host's
    /// does): one left behind by a master that died is in the way of the next.
    func vmBoundSocket(in paths: InstancePaths) -> URL? {
        direction == .ontoHost ? socket(in: paths) : nil
    }

    /// Why this cannot be a forward, or nil.
    var problem: String? {
        guard SSHHost.isValidName(sshHost) else { return "“\(sshHost)” is not an SSH host's name." }
        for port in [guestPort, remotePort] where !(1...65535).contains(port) {
            return "\(port) is not a valid port (1–65535)."
        }
        let plain = !remoteHost.unicodeScalars.contains { $0.properties.generalCategory == .control }
        switch direction {
        case .intoVM:
            // sshd in the VM listens as the VM's user.
            guard guestPort >= 1024 else { return "The port in the VM is from 1024 to 65535." }
            guard plain, InstanceConfig.isHostName(remoteHost) || InstanceConfig.isIPLiteral(remoteHost) else {
                return "“\(remoteHost)” is not a host name or address."
            }
        case .ontoHost:
            guard plain, InstanceConfig.isIPLiteral(remoteHost) else {
                return "“\(remoteHost)” is not an address for the SSH host to listen on."
            }
        }
        return nil
    }

    /// The same path (everything but `id` and `enabled`).
    func sameRoute(_ other: SSHForward) -> Bool {
        sshHost == other.sshHost && direction == other.direction && guestPort == other.guestPort
            && remoteHost == other.remoteHost && remotePort == other.remotePort
    }
}

extension SSHForward {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sshHost = try c.decode(String.self, forKey: .sshHost)
        direction = try c.decode(Direction.self, forKey: .direction)
        guestPort = try c.decode(Int.self, forKey: .guestPort)
        remoteHost = try c.decodeIfPresent(String.self, forKey: .remoteHost) ?? "127.0.0.1"
        remotePort = try c.decode(Int.self, forKey: .remotePort)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// One forward on an SSH host's master, for a VM's SSHForward.
struct SSHLeg: Equatable, Hashable {
    let host: String
    let spec: SSHMux.Spec
}

/// Keeps the SSH hosts' side of the VMs' forwards (SSHHostManager).
@MainActor
protocol SSHLegApplying: AnyObject {
    /// What `vm` wants on the SSH hosts' masters now (all of it, each time;
    /// empty when it stops).
    func apply(_ legs: [SSHLeg], for vm: String)
}
