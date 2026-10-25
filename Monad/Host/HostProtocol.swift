//
//  HostProtocol.swift — messages between Monad.app and MonadHost (the
//  launchd agent that owns the VMs). JSON with sorted keys, carried as Data
//  over XPC. The app and the host can be different builds for a while (the
//  host keeps running across app updates), so the format is versioned and
//  pinned by HostProtocolTests.
//
//      app → host   HostRequest    one per call, answered by a HostResponse
//      host → app   HostEvent      pushed whenever a VM changes
//

import Foundation

enum HostProtocol {
    /// Bumped on any incompatible change; both sides compare it in `hello`.
    static let version = 1
    /// Largest message either side accepts (configs are a few KB).
    static let maxMessageBytes = 1 << 20

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .custom(InstanceConfig.encodeDate)
        return try enc.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maxMessageBytes else { throw HostProtocolError.tooLarge(data.count) }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom(InstanceConfig.decodeDate)
        do {
            return try dec.decode(type, from: data)
        } catch let error as InstanceConfig.DecodingProblem {
            throw error
        } catch {
            throw HostProtocolError.invalid("Malformed \(type) message.")
        }
    }
}

enum HostProtocolError: Error, Equatable, LocalizedError {
    case tooLarge(Int)
    case invalid(String)
    case versionMismatch(host: Int, app: Int)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let n): return "Message too large (\(n) bytes)."
        case .invalid(let why): return why
        case .versionMismatch(let host, let app):
            return "The running MonadHost speaks protocol \(host), this Monad speaks \(app). Quit Monad and stop its VMs to update the host."
        }
    }
}

// MARK: - Requests

struct HostRequest: Codable, Equatable, Sendable {
    enum Op: String, Codable, Sendable {
        case hello           // version → host version
        case list            // → instances
        case ensureDefault   // the default VM (chosen, else the top of the order), "default" made when there is none → instance
        case createEphemeral // → instance
        case create          // config → instance
        case update          // config → instance (live where possible)
        case start, stop, delete // name (stop: force)
        case restart         // name: clean shutdown, then start (applies saved settings)
        case attach, detach  // name: a tab starts/stops using the VM
        case stopAll
        case shutdown        // exit so launchd can start a newer host; refused while VMs run
        case answerFirewall  // name, firewallAnswer: a monitor-mode question answered → instance
        case runProfiles     // name, profiles: set them up in the running VM → instance
        case stopProfiles    // name: stop the profile being set up, drop the waiting ones → instance
        case connections     // name: the VM's connection log (netd), most recent first → connections
        case traffic         // traffic between VMs on the Monad networks (netd) → traffic
        case reorder         // names first, the other VMs after them → instances, order, defaultVM
        case mcp             // mcp: one MCP message from an agent on the Mac (MonadHost --mcp) → mcp: the answer, if any
        case answerApproval  // approvalID, approvalAnswer: the user answered an agent's question
        case agentStatus     // → grants, audit (Settings › Agents)
        case revokeGrant     // grant: an "always allow" taken back → grants
        case notes           // → notes: what is written on the canvas
        case setNote         // note: added or changed (the host says who wrote it) → notes
        case removeNote      // noteID → notes
        case setDefault      // name: Make Default → defaultVM
        case answerMacSetup  // name, macSetupWork or macSetupError: a macOS VM's setup step done or not (Phase 14)
        case openDesktop     // name: a macOS VM's desktop in a window (shown by the host) → instance
        case clone           // name, config: a copy of the stopped VM `name` with these settings → instance
        case repairDisk      // name: Repair Disk on the stopped Linux VM (minutes) → instance, message: what it did
    }

    var id: UInt64
    var op: Op
    var name: String?
    var force: Bool?
    var config: InstanceConfig?
    var version: Int?
    var firewallAnswer: FirewallAnswer?
    var profiles: [String]?
    /// reorder: VM names, the new top first.
    var names: [String]?
    /// mcp: one JSON-RPC message.
    var mcp: String?
    var approvalID: UUID?
    var approvalAnswer: ApprovalAnswer?
    var grant: MCPGrants.Grant?
    /// setNote: the note.
    var note: CanvasNote?
    /// removeNote: its id.
    var noteID: String?
    /// answerMacSetup: the root step's work folder, or why it did not run.
    var macSetupWork: String?
    var macSetupError: String?

    init(id: UInt64, op: Op, name: String? = nil, force: Bool? = nil, config: InstanceConfig? = nil,
         version: Int? = nil, firewallAnswer: FirewallAnswer? = nil, profiles: [String]? = nil, names: [String]? = nil,
         mcp: String? = nil) {
        self.mcp = mcp
        self.id = id
        self.op = op
        self.name = name
        self.force = force
        self.config = config
        self.version = version
        self.firewallAnswer = firewallAnswer
        self.profiles = profiles
        self.names = names
    }

    var isForced: Bool { force ?? false }

    /// Checks that the fields `op` needs are present and well formed. The
    /// host treats every request as untrusted input.
    func validate() throws {
        switch op {
        case .hello:
            guard version != nil else { throw HostProtocolError.invalid("hello needs a protocol version.") }
        case .list, .ensureDefault, .createEphemeral, .stopAll, .shutdown, .traffic:
            break
        case .start, .stop, .restart, .delete, .attach, .detach, .stopProfiles, .connections, .setDefault,
             .openDesktop, .repairDisk:
            guard let name, InstanceConfig.isValidName(name) else {
                throw HostProtocolError.invalid("\(op.rawValue) needs a valid VM name.")
            }
        case .create, .update:
            guard let config, InstanceConfig.isValidName(config.name) else {
                throw HostProtocolError.invalid("\(op.rawValue) needs a configuration with a valid name.")
            }
        case .clone:
            guard let name, InstanceConfig.isValidName(name), let config, InstanceConfig.isValidName(config.name) else {
                throw HostProtocolError.invalid("clone needs a VM name and a configuration with a valid name.")
            }
        case .answerFirewall:
            guard let name, InstanceConfig.isValidName(name), let a = firewallAnswer else {
                throw HostProtocolError.invalid("answerFirewall needs a VM name and an answer.")
            }
            if case .tag(let tag) = a.scope, !FirewallTag.isValidName(tag) {
                throw HostProtocolError.invalid("answerFirewall: not a tag name.")
            }
            if case .name(let n) = a.target, n.hasPrefix("*") || !NetworkDefinition.isHostPattern(n) {
                throw HostProtocolError.invalid("answerFirewall: not a host name.")
            }
        case .runProfiles:
            guard let name, InstanceConfig.isValidName(name), let ids = profiles, (1...16).contains(ids.count),
                  ids.allSatisfy(ProfileConfig.isID) else {
                throw HostProtocolError.invalid("runProfiles needs a VM name and profile ids.")
            }
        case .reorder:
            guard let names, (1...VMOrder.maxVMs).contains(names.count), names.allSatisfy(InstanceConfig.isValidName) else {
                throw HostProtocolError.invalid("reorder needs VM names.")
            }
        case .mcp:
            guard let mcp, mcp.utf8.count <= MCP.maxMessageBytes else { throw HostProtocolError.invalid("mcp needs one message.") }
        case .answerApproval:
            guard approvalID != nil, approvalAnswer != nil else { throw HostProtocolError.invalid("answerApproval needs a question and an answer.") }
        case .agentStatus:
            break
        case .revokeGrant:
            guard grant != nil else { throw HostProtocolError.invalid("revokeGrant needs a grant.") }
        case .notes:
            break
        case .answerMacSetup:
            guard let name, InstanceConfig.isValidName(name), (macSetupWork == nil) != (macSetupError == nil),
                  (macSetupWork ?? macSetupError ?? "").utf8.count <= 4096 else {
                throw HostProtocolError.invalid("answerMacSetup needs a VM name and a work folder or a reason.")
            }
        case .setNote:
            guard let note else { throw HostProtocolError.invalid("setNote needs a note.") }
            try note.validate()
        case .removeNote:
            guard let noteID, CanvasNote.isID(noteID) else { throw HostProtocolError.invalid("removeNote needs a note's id.") }
        }
    }
}

// MARK: - Responses

struct HostResponse: Codable, Equatable, Sendable {
    var id: UInt64
    var ok: Bool
    var error: String?
    var version: Int?
    /// hello: identity of the host executable (see HostBuild).
    var build: String?
    var instance: VMSnapshot?
    var instances: [VMSnapshot]?
    /// connections: the VM's connection log.
    var connections: [NetConnection]?
    /// traffic: between VMs, by network and VM name.
    var traffic: [VMTraffic]?
    /// list, reorder: the VMs' order, the default one first (ephemeral VMs
    /// are not in it).
    var order: [String]?
    /// mcp: the answer (absent for a notification).
    var mcp: String?
    /// agentStatus, revokeGrant: the "always allow" answers.
    var grants: [MCPGrants.Grant]?
    /// agentStatus: the audit log's last lines.
    var audit: [String]?
    /// notes, setNote, removeNote: everything written on the canvas.
    var notes: [CanvasNote]?
    /// list, reorder, setDefault: the default VM (the chosen one, else the
    /// top of the order).
    var defaultVM: String?
    /// repairDisk: what it did, in a few sentences.
    var message: String?

    init(id: UInt64, version: Int? = nil, instance: VMSnapshot? = nil, instances: [VMSnapshot]? = nil) {
        self.id = id
        self.ok = true
        self.version = version
        self.instance = instance
        self.instances = instances
    }

    init(id: UInt64, error: String) {
        self.id = id
        self.ok = false
        self.error = error
    }
}

/// Everything the app shows about a VM.
struct VMSnapshot: Codable, Equatable, Sendable {
    var name: String
    var config: InstanceConfig
    var state: VMState
    /// Whether the guest agent is installed and answering.
    var agent: Bool
    var ports: [ListeningPort]
    /// Tabs (across all connected apps) using the VM.
    var sessions: Int
    /// Port and socket forwards with their status; absent when there are none.
    var forwards: [ForwardStatus]? = nil
    /// Guest ports not auto-forwarded because of the limit; absent when none.
    var portsOverLimit: Int? = nil
    /// Saved settings the running VM only picks up when it restarts.
    var pendingRestart: [String]? = nil
    /// Why shared folders are not all mounted in the guest.
    var sharesError: String? = nil
    /// Why the firewall is not in force as saved (netd refused it).
    var firewallProblem: String? = nil
    /// Monitor-mode questions waiting for the user; absent when there are none.
    var firewallAsks: [FirewallAsk]? = nil
    /// Profiles set up since the VM started; absent when none.
    var profileRuns: [ProfileRun]? = nil
    /// A macOS VM waiting for the user's password to finish its setup.
    var macSetup: MacSetupRequest? = nil
    /// A macOS VM's System Integrity Protection as found, and any problem.
    var macSecurity: MacSecurityReport? = nil
}

/// What the app needs to run a macOS VM's setup step (Phase 14).
struct MacSetupRequest: Codable, Equatable, Sendable {
    var disk: String
    var payload: String
}

extension VMState: Codable {
    private enum Keys: String, CodingKey { case phase, detail }
    private enum Phase: String, Codable { case preparing, stopped, starting, booting, ready, stopping, failed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Phase.self, forKey: .phase) {
        case .preparing: self = .preparing(try c.decode(String.self, forKey: .detail))
        case .stopped: self = .stopped
        case .starting: self = .starting
        case .booting: self = .booting
        case .ready: self = .ready
        case .stopping: self = .stopping
        case .failed: self = .failed(try c.decode(String.self, forKey: .detail))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .preparing(let detail):
            try c.encode(Phase.preparing, forKey: .phase)
            try c.encode(detail, forKey: .detail)
        case .stopped: try c.encode(Phase.stopped, forKey: .phase)
        case .starting: try c.encode(Phase.starting, forKey: .phase)
        case .booting: try c.encode(Phase.booting, forKey: .phase)
        case .ready: try c.encode(Phase.ready, forKey: .phase)
        case .stopping: try c.encode(Phase.stopping, forKey: .phase)
        case .failed(let detail):
            try c.encode(Phase.failed, forKey: .phase)
            try c.encode(detail, forKey: .detail)
        }
    }
}

// MARK: - Events

enum HostEvent: Equatable, Sendable {
    /// A VM appeared or changed.
    case instance(VMSnapshot)
    /// A VM was deleted.
    case removed(String)
    /// The VMs' order changed (the top one is the default VM until one is chosen).
    case order([String])
    /// Agents' questions waiting for the user (all of them, each time).
    case approvals([ApprovalRequest])
    /// What is written on the canvas (all of it, each time it changes).
    case notes([CanvasNote])
    /// The default VM changed (nil: there is no VM).
    case defaultVM(String?)
}

extension HostEvent: Codable {
    private enum Keys: String, CodingKey { case event, instance, name, names, approvals, notes }
    private enum Kind: String, Codable { case instance, removed, order, approvals, notes, defaultVM }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .event) {
        case .instance: self = .instance(try c.decode(VMSnapshot.self, forKey: .instance))
        case .removed: self = .removed(try c.decode(String.self, forKey: .name))
        case .order: self = .order(try c.decode([String].self, forKey: .names))
        case .approvals: self = .approvals(try c.decode([ApprovalRequest].self, forKey: .approvals))
        case .notes: self = .notes(try c.decode([CanvasNote].self, forKey: .notes))
        case .defaultVM: self = .defaultVM(try c.decodeIfPresent(String.self, forKey: .name))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .instance(let snap):
            try c.encode(Kind.instance, forKey: .event)
            try c.encode(snap, forKey: .instance)
        case .removed(let name):
            try c.encode(Kind.removed, forKey: .event)
            try c.encode(name, forKey: .name)
        case .order(let names):
            try c.encode(Kind.order, forKey: .event)
            try c.encode(names, forKey: .names)
        case .approvals(let list):
            try c.encode(Kind.approvals, forKey: .event)
            try c.encode(list, forKey: .approvals)
        case .notes(let list):
            try c.encode(Kind.notes, forKey: .event)
            try c.encode(list, forKey: .notes)
        case .defaultVM(let name):
            try c.encode(Kind.defaultVM, forKey: .event)
            try c.encodeIfPresent(name, forKey: .name)
        }
    }
}
