//
//  MCPAccess.swift — who may call which of Monad's MCP tools, and when the
//  user is asked (agents phase, decided with the user on 2026-10-12):
//
//  - An agent on the Mac: everything; a risky tool (it reaches into the
//    Mac or cannot be undone) asks first, unless the user said "always" for
//    that tool or for all.
//  - A VM without a role: nothing (it has no endpoint either).
//  - A VM with the hostCommands role: its own host commands and their runs.
//  - An orchestrator VM: reads, makes VMs of its own (children, within its
//    limits) and runs, stops, deletes and works in them without asking;
//    anything else asks the user (always for that tool, or for that VM).
//
//  A question waits for the app (opened when needed) and is refused after
//  two minutes. Grants live in ~/.monad/agents/grants.json, written by
//  MonadHost only. Every call is in the audit log.
//

import Foundation

enum MCPAccess {
    enum Decision: Equatable {
        case allow
        case ask
        case deny(String)
    }

    /// The tools an orchestrator uses on its children (and itself) freely.
    static let childTools: Set<String> = ["get_vm", "start_vm", "stop_vm", "restart_vm", "delete_vm", "exec",
                                          "read_file", "write_file", "list_connections"]
    /// Reading Monad's lists, free for an orchestrator.
    static let orchestratorReads: Set<String> = ["list_vms", "list_distros", "list_networks"]
    /// A VM's own host commands and their runs (host_<name>, run tools).
    static func isHostCommandTool(_ name: String) -> Bool {
        name.hasPrefix("host_") || ["list_runs", "run_status", "run_wait"].contains(name)
    }

    /// Whether `tool` may run for `caller` now, needs the user, or not at all.
    /// `vms`: every VM's settings, by name. `makesAMac`: the call makes a
    /// macOS VM, which ends in the Mac's administrator password prompt, so
    /// it asks whoever calls.
    static func decide(caller: MCPCaller, tool: String, risk: MCPTool.Risk, arguments: [String: JSONValue],
                       vms: [String: InstanceConfig], grants: MCPGrants, makesAMac: Bool = false) -> Decision {
        switch caller {
        case .mac:
            guard risk == .risky || makesAMac else { return .allow }
            return grants.allows(caller, tool) ? .allow : .ask
        case .vm(let name):
            guard let me = vms[name], let access = me.agents else { return .deny("This VM has no access to Monad.") }
            if isHostCommandTool(tool) { return .allow }
            guard access.role == .orchestrator else {
                return .deny("This VM may only run its host commands. Its role is set in Monad's settings.")
            }
            if orchestratorReads.contains(tool) || (tool == "create_vm" && !makesAMac) { return .allow }
            if childTools.contains(tool), let target = arguments["name"]?.string,
               target == name ? risk == .read : vms[target]?.parent == name {
                return .allow
            }
            return grants.allows(caller, tool) ? .allow : .ask
        }
    }

    /// The tools a caller sees.
    static func visible(_ tools: [MCPTool], to caller: MCPCaller, vms: [String: InstanceConfig]) -> [MCPTool] {
        switch caller {
        case .mac:
            return tools.filter { !isHostCommandTool($0.name) }
        case .vm(let name):
            guard let access = vms[name]?.agents else { return [] }
            if access.role == .hostCommands { return tools.filter { isHostCommandTool($0.name) } }
            return tools
        }
    }
}

/// "Always allow" answers: per caller, for one tool or all.
struct MCPGrants: Codable, Equatable {
    struct Grant: Codable, Equatable, Hashable {
        /// "mac", or "vm:<name>".
        var caller: String
        /// nil: every tool.
        var tool: String?
    }

    var grants: [Grant] = []

    static func key(_ caller: MCPCaller) -> String {
        switch caller {
        case .mac: return "mac"
        case .vm(let name): return "vm:\(name)"
        }
    }

    func allows(_ caller: MCPCaller, _ tool: String) -> Bool {
        let k = Self.key(caller)
        return grants.contains { $0.caller == k && ($0.tool == nil || $0.tool == tool) }
    }

    mutating func add(_ caller: MCPCaller, tool: String?) {
        let g = Grant(caller: Self.key(caller), tool: tool)
        if !grants.contains(g) { grants.append(g) }
    }

    /// A VM's grants go with it.
    mutating func forget(vm name: String) { grants.removeAll { $0.caller == "vm:\(name)" } }

    static func load(_ url: URL) -> MCPGrants {
        guard let data = try? Data(contentsOf: url), data.count < 1 << 20,
              var g = try? JSONDecoder().decode(MCPGrants.self, from: data) else { return MCPGrants() }
        g.grants = g.grants.filter { ($0.caller == "mac" || ($0.caller.hasPrefix("vm:") && InstanceConfig.isValidName(String($0.caller.dropFirst(3)))))
            && ($0.tool.map { $0.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil } ?? true) }
        return g
    }

    func save(_ url: URL) throws {
        try Paths.ensurePrivateDirectory(url.deletingLastPathComponent())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// A question for the user: an agent wants to do something risky.
struct ApprovalRequest: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    /// "mac" or "vm:<name>".
    var caller: String
    var tool: String
    /// What it would do, in words, with its arguments.
    var detail: String
    var asked: Date

    var callerLabel: String {
        caller == "mac" ? "An agent on this Mac" : "The VM “\(caller.dropFirst(3))”"
    }
}

enum ApprovalAnswer: String, Codable, Sendable {
    case deny, once, alwaysTool, alwaysAll
}

/// The questions waiting for the user, and their answers.
@MainActor
final class Approvals {
    nonisolated static let timeout: TimeInterval = 120
    nonisolated static let maxPending = 16

    private(set) var pending: [ApprovalRequest] = []
    private var waiters: [UUID: CheckedContinuation<ApprovalAnswer, Never>] = [:]
    /// The list changed (HostService tells the apps).
    var onChange: (([ApprovalRequest]) -> Void)?
    /// A question was asked (MonadHost opens the app if none is there).
    var onAsk: (() -> Void)?
    private let clock: MonadClock
    private let timeoutSeconds: TimeInterval

    init(clock: MonadClock = SystemClock(), timeout: TimeInterval = Approvals.timeout) {
        self.clock = clock
        timeoutSeconds = timeout
    }

    /// Waits for the user's answer; no answer in time is a refusal.
    func ask(caller: MCPCaller, tool: String, arguments: [String: JSONValue]) async -> ApprovalAnswer {
        guard pending.count < Self.maxPending else { return .deny }
        let request = ApprovalRequest(id: UUID(), caller: MCPGrants.key(caller), tool: tool,
                                      detail: Self.describe(tool, arguments), asked: Date())
        pending.append(request)
        onChange?(pending)
        onAsk?()
        let id = request.id
        let timeoutSeconds = self.timeoutSeconds
        let clock = self.clock
        Task { @MainActor [weak self] in
            await clock.sleep(seconds: timeoutSeconds)
            self?.answer(id, .deny)
        }
        return await withCheckedContinuation { waiters[id] = $0 }
    }

    /// The user's answer; false when the question is gone (answered or timed out).
    @discardableResult
    func answer(_ id: UUID, _ answer: ApprovalAnswer) -> Bool {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return false }
        pending.remove(at: i)
        onChange?(pending)
        waiters.removeValue(forKey: id)?.resume(returning: answer)
        return true
    }

    /// The arguments in words, short: one line each, a key that is not a
    /// plain name shown quoted (it cannot pass for another), and nothing a
    /// caller could use to shape the text (control, format and separator
    /// characters: a newline, a right-to-left override).
    static func describe(_ tool: String, _ arguments: [String: JSONValue]) -> String {
        let args = arguments.keys.sorted().map { key -> String in
            let name = key.range(of: #"\A[a-z0-9_]{1,64}\z"#, options: .regularExpression) != nil
                ? key : String(decoding: JSONValue.string(key).encoded(), as: UTF8.self)
            let line = (name + ": " + String(decoding: arguments[key]!.encoded(), as: UTF8.self)).plain(limit: 300)
            // A list cut short says how long it is, so what is not shown is not taken for absent.
            if case .array(let items)? = arguments[key], line.hasSuffix("…") {
                return line + " (\(items.count) items, not all shown)"
            }
            return line
        }
        let text = ([tool.plain()] + args).joined(separator: "\n")
        return text.count > 2000 ? String(text.prefix(2000)) + "…" : text
    }
}

/// Every MCP call, one line each: when, who, what, with what, and how it
/// ended. A file that passes 1 MB starts again (the old one kept as .1).
struct MCPAudit {
    let url: URL
    static let maxBytes = 1 << 20

    func record(caller: MCPCaller, tool: String, arguments: [String: JSONValue], outcome: String, duration: Duration) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var args = String(decoding: JSONValue.object(arguments).encoded(), as: UTF8.self)
        if args.count > 500 { args = String(args.prefix(500)) + "…" }
        let ms = Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
        let line = "\(stamp) \(MCPGrants.key(caller)) \(tool) \(args) → \(outcome) (\(ms) ms)\n"
            .replacingOccurrences(of: "\r", with: " ")
        try? Paths.ensurePrivateDirectory(url.deletingLastPathComponent())
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.maxBytes {
            let old = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.utf8CString.withUnsafeBytes { write(fd, $0.baseAddress, $0.count - 1) }
    }

    /// The last `count` lines, newest last.
    func tail(_ count: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(count).map(String.init))
    }
}
