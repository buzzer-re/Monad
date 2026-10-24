//
//  AgentAccess.swift — what a VM may do with Monad itself (agents phase):
//  nothing by default. With a role, Monad's MCP server is mapped into the
//  VM on a loopback port: `hostCommands` gives its own host commands as
//  tools; `orchestrator` also lets it make and run VMs of its own
//  (children, within limits) and ask the user for anything more.
//

import Foundation

struct AgentAccess: Codable, Equatable, Hashable {
    enum Role: String, Codable, CaseIterable {
        case hostCommands
        case orchestrator
    }

    var role: Role
    /// The MCP endpoint's port on the guest's loopback.
    var guestPort: Int = AgentAccess.defaultPort
    /// Orchestrator: how many VMs it may have made at once.
    var maxChildren: Int = 4
    /// Orchestrator: CPUs and memory its children may use together (nil:
    /// as much as the orchestrator itself has).
    var childCPUs: Int?
    var childMemoryGiB: Int?

    static let defaultPort = 7766
    static let maxChildrenLimit = 16

    init(role: Role, guestPort: Int = AgentAccess.defaultPort, maxChildren: Int = 4, childCPUs: Int? = nil,
         childMemoryGiB: Int? = nil) {
        self.role = role
        self.guestPort = guestPort
        self.maxChildren = maxChildren
        self.childCPUs = childCPUs
        self.childMemoryGiB = childMemoryGiB
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(Role.self, forKey: .role)
        guestPort = try c.decodeIfPresent(Int.self, forKey: .guestPort) ?? Self.defaultPort
        maxChildren = try c.decodeIfPresent(Int.self, forKey: .maxChildren) ?? 4
        childCPUs = try c.decodeIfPresent(Int.self, forKey: .childCPUs)
        childMemoryGiB = try c.decodeIfPresent(Int.self, forKey: .childMemoryGiB)
    }

    /// What is wrong with it; nil when nothing is.
    func problem(maxCPUs: Int, maxMemoryGiB: Int) -> String? {
        guard (1024...65535).contains(guestPort) else { return "Monad's MCP port in the VM is from 1024 to 65535." }
        guard (0...Self.maxChildrenLimit).contains(maxChildren) else {
            return "An orchestrator has 0 to \(Self.maxChildrenLimit) VMs of its own."
        }
        if let c = childCPUs, !(1...max(1, maxCPUs)).contains(c) { return "Its VMs' CPUs are 1 to \(maxCPUs) together." }
        if let m = childMemoryGiB, !(1...max(1, maxMemoryGiB)).contains(m) {
            return "Its VMs' memory is 1 to \(maxMemoryGiB) GB together."
        }
        return nil
    }

    /// What the role allows, in the user's words (asked before it is given).
    var summary: String {
        switch role {
        case .hostCommands:
            return "Agents in the VM can run its host commands through Monad's MCP server at 127.0.0.1:\(guestPort)."
        case .orchestrator:
            return "Agents in the VM can make, run and delete up to \(maxChildren) VMs of their own and run commands in them, "
                + "through Monad's MCP server at 127.0.0.1:\(guestPort). Anything more (other VMs, Monad's settings, "
                + "anything that reaches this Mac) asks you first."
        }
    }
}
