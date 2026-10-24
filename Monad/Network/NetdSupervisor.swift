//
//  NetdSupervisor.swift — MonadHost's side of monad-netd: starts it (its own
//  binary with --netd), tells it the Mac's nameservers and networks, creates
//  Monad networks on first use, and hands it the VMs' NICs, each behind its
//  VM's firewall (with the rules of the tags the VM carries).
//
//  Commands go down the control channel in order and netd answers each in
//  order; a firewall's lines go down together, so nothing lands between
//  them. For every NIC the supervisor keeps a copy of netd's end of the
//  socket pair, so when netd dies it is started again (with backoff) and
//  given everything back: running VMs keep their network and firewall
//  without a reboot. A new port lets nothing out until its firewall is set.
//

import Foundation
import os
import SystemConfiguration

/// What netd needs to know about the Mac.
protocol HostNetworkInfo {
    /// IPv4 nameservers, "a.b.c.d" or "a.b.c.d:port".
    var nameservers: [String] { get }
    /// The Mac's own IPv4 networks, "a.b.c.0/prefix".
    var localNetworks: [String] { get }
}

@MainActor
final class NetdSupervisor: NetworkAttaching {
    enum SupervisorError: Error, LocalizedError {
        case unknownNetwork(String)
        case refused(String)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unknownNetwork(let n): return "There is no network named “\(n)”."
            case .refused(let reason): return "monad-netd refused: \(reason)"
            case .unavailable(let why): return "monad-netd is not available: \(why)"
            }
        }
    }

    private struct Port {
        let vm: String
        let network: String
        let mac: String
        /// A copy of netd's end of the NIC's socket pair, sent again after a restart.
        let netdEnd: Int32
        var id: Int?
        var firewall: VMFirewall
        /// What netd enforces for it now (nil: nothing yet, so it is closed).
        var enforced: Firewall.Resolved?
        /// Monitor-mode answers until the VM stops (sent again after a restart).
        var session: [FirewallRule] = []
        /// Where netd's questions for it go.
        weak var nic: NICAttachment?
    }

    private let executable: String
    private let store: NetworkStore
    private let tags: FirewallTagStore
    private let hostInfo: HostNetworkInfo

    private var control: Int32 = -1
    private var pid: pid_t = 0
    private var reader: DispatchSourceRead?
    private var pending = Data()
    /// One handler per command sent, in order: netd answers in order.
    private var waiting: [@MainActor (Result<String, Error>) -> Void] = []
    private var starting: Task<Void, Error>?
    /// Monad networks netd knows: name → its id and the definition it was made from.
    private var networks: [String: (id: Int, definition: NetworkDefinition)] = [:]
    /// Networks being asked of netd: VMs joining meanwhile wait for the same
    /// answer instead of asking again (each ask is a separate switch).
    private var creating: [String: (definition: NetworkDefinition, generation: Int, task: Task<Int, Error>)] = [:]
    private var networksGeneration = 0
    private var ports: [UUID: Port] = [:]
    private var nextAskID: UInt64 = 1
    /// Firewall sends started from callbacks (edits, tag changes); sync waits for them.
    private var inflight: [UUID: Task<Void, Never>] = [:]
    private var restartDelay: TimeInterval = 1
    private var restartTask: Task<Void, Never>?
    private var closing = false

    /// netd's process, while it runs (tests stop it to see recovery).
    var processID: pid_t? { control >= 0 ? pid : nil }

    /// MonadHost's supervisor: netd is MonadHost's own binary (in Monad.app's
    /// Contents/MacOS, which is also where the app's Bundle.main points).
    static let shared = NetdSupervisor(
        executable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MonadHost").path)

    private var hostWatcher: HostNetworkWatcher?
    /// Watches the firewall tags folder: tag edits apply without being announced.
    private var tagsWatch: DispatchSourceFileSystemObject?

    /// Settings › Logs.
    private let debugLog: DebugLog
    private func debug(_ message: @autoclosure () -> String) { debugLog.log("netd", message()) }

    init(executable: String, store: NetworkStore = NetworkStore(), tags: FirewallTagStore = FirewallTagStore(),
         hostInfo: HostNetworkInfo = SystemHostNetworkInfo(), debugLog: DebugLog = .shared) {
        self.debugLog = debugLog
        self.executable = executable
        self.store = store
        self.tags = tags
        self.hostInfo = hostInfo
    }

    // MARK: NetworkAttaching

    func attach(vm: String, network: String, mac: String, firewall: VMFirewall) async throws -> NICAttachment {
        guard let definition = try store.network(named: network) else { throw SupervisorError.unknownNetwork(network) }
        try await ensureRunning()
        let networkID = try await ensureNetwork(definition)
        debug("\(vm) joins \(network) with MAC \(mac)")
        // A VM has one NIC: a new machine's replaces the old machine's, which
        // is let go later (netd keeps one port per MAC, so it goes first).
        for (key, old) in ports where old.vm == vm {
            debug("\(vm): its old NIC (port \(old.id.map(String.init) ?? "none")) makes way")
            ports[key] = nil
            close(old.netdEnd)
            if let id = old.id, control >= 0 { _ = try? await command("unport \(id)") }
        }
        // A port let go just now (a macOS VM back from recovery) leaves
        // netd before this one is made: netd keeps one port per MAC.
        for task in Array(inflight.values) { await task.value }
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw SupervisorError.unavailable(String(cString: strerror(errno)))
        }
        let vmEnd = fds[0], netdEnd = fds[1]
        // Room for bursts both ways (the values Apple suggests for this attachment).
        var snd: Int32 = 1 << 20, rcv: Int32 = 4 << 20
        setsockopt(vmEnd, SOL_SOCKET, SO_SNDBUF, &snd, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(vmEnd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(vmEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(netdEnd, F_SETFD, FD_CLOEXEC)
        let key = UUID()
        ports[key] = Port(vm: vm, network: network, mac: mac, netdEnd: netdEnd, id: nil, firewall: firewall)
        do {
            let id = try await sendPort(key, networkID: networkID)
            ports[key]?.id = id
            try await sendFirewall(key)
        } catch {
            debug("\(vm) could not join \(network): \(error.localizedDescription)")
            if let id = ports[key]?.id, control >= 0 { Task { _ = try? await self.command("unport \(id)") } }
            ports[key] = nil
            close(netdEnd)
            close(vmEnd)
            throw error
        }
        Log.host.info("\(vm, privacy: .public) joined network \(network, privacy: .public)")
        let nic = NICAttachment(handle: FileHandle(fileDescriptor: vmEnd, closeOnDealloc: true),
                                onFirewall: { [weak self] in self?.setFirewall(key, $0) },
                                onAnswer: { [weak self] in self?.answer(key, $0) },
                                onForget: { [weak self] in self?.forgetSession(key) },
                                onDetach: { [weak self] in self?.detach(key) })
        ports[key]?.nic = nic
        nic.firewallApplied(problem: ports[key]?.enforced?.problem)
        return nic
    }

    /// The VM's connection log, most recent first, from each of its ports
    /// (netd's conns, page by page: at most `maxPages`). Not written to the
    /// debug log line by line: a page is polled every few seconds while a
    /// window shows it.
    func connections(vm: String) async throws -> [NetConnection] {
        let ids = ports.values.filter { $0.vm == vm }.compactMap(\.id)
        guard !ids.isEmpty, control >= 0 else { return [] }
        var all: [NetConnection] = []
        for id in ids {
            var from = 0
            for _ in 0..<Self.maxPages {
                let reply = try await send(["conns \(id) from=\(from)"], fd: -1)[0]
                guard let page = NetConnection.page(reply) else { throw SupervisorError.refused(Self.reason(reply)) }
                all += page.entries
                guard page.next > from else { break }
                from = page.next
            }
        }
        return all
    }

    /// Pages read per port: the log holds 256 entries, a page a dozen or more.
    static let maxPages = 64

    /// Traffic between VMs on every network (netd's peers, page by page:
    /// at most `maxPages` a network), by VM name; a port no VM holds any
    /// more is left out.
    func traffic() async throws -> [VMTraffic] {
        guard control >= 0 else { return [] }
        var names: [Int: String] = [:]
        for port in ports.values { if let id = port.id { names[id] = port.vm } }
        var all: [VMTraffic] = []
        for (network, entry) in networks.sorted(by: { $0.key < $1.key }) {
            var from = 0
            for _ in 0..<Self.maxPages {
                let reply = try await send(["peers \(entry.id) from=\(from)"], fd: -1)[0]
                guard let page = NetPeer.page(reply) else { throw SupervisorError.refused(Self.reason(reply)) }
                all += page.entries.compactMap { p in
                    guard let a = names[p.from], let b = names[p.to] else { return nil }
                    return VMTraffic(network: network, from: a, to: b, frames: p.frames, bytes: p.bytes, lastSeen: p.lastSeen)
                }
                guard page.next > from else { break }
                from = page.next
            }
        }
        return all
    }

    /// Waits until netd has handled everything sent or started so far
    /// (a start in progress included, with its replay of networks and NICs).
    func sync() async throws {
        if let starting { _ = try? await starting.value }
        while let task = inflight.values.first { await task.value }
        guard control >= 0 else { return }
        _ = try await command("ping")
    }

    /// The Mac's nameservers or networks changed.
    func hostInfoChanged() {
        guard control >= 0 else { return }
        Task {
            do {
                try await self.sendHostInfo()
            } catch {
                // netd keeps the previous list; a restart of netd sends it again.
                Log.host.error("the Mac's networks did not reach monad-netd: \(error.localizedDescription, privacy: .public)")
                self.debug("the Mac's networks did not reach monad-netd: \(error.localizedDescription)")
            }
        }
    }

    /// Stops netd (MonadHost is going away; netd would exit on its own too).
    func shutDown() {
        closing = true
        restartTask?.cancel()
        tagsWatch?.cancel()
        tagsWatch = nil
        for port in ports.values { close(port.netdEnd) }
        ports.removeAll()
        stopProcess()
    }

    // MARK: Firewalls

    private func setFirewall(_ key: UUID, _ firewall: VMFirewall) {
        guard ports[key] != nil else { return }
        ports[key]?.firewall = firewall
        track { await self.sendFirewallLogged(key) }
    }

    /// Gives netd the port's firewall with its tags' rules, unless netd
    /// enforces exactly that already.
    private func sendFirewall(_ key: UUID) async throws {
        guard let port = ports[key], let id = port.id else { return }
        let resolved = Firewall.resolve(port.firewall, tags: (try? tags.all()) ?? [])
        guard resolved != port.enforced else { return }
        if let problem = resolved.problem {
            Log.host.error("\(port.vm, privacy: .public)'s firewall: \(problem, privacy: .public)")
        }
        for reply in try await commands(Firewall.netdCommands(resolved, port: id)) where !Self.isOK(reply) {
            throw SupervisorError.refused(Self.reason(reply))
        }
        // Still the same port (not detached or re-sent meanwhile)?
        if ports[key]?.id == id { ports[key]?.enforced = resolved }
    }

    /// Runs work that `sync` waits for; it forgets it once done.
    private func track(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        // The task runs on the main actor too, so it starts after this line.
        inflight[id] = Task {
            await work()
            self.inflight[id] = nil
        }
    }

    // MARK: Monitor mode

    private func answer(_ key: UUID, _ rule: FirewallRule) {
        guard ports[key] != nil else { return }
        ports[key]?.session.append(rule)
        if ports[key]!.session.count > Int(MND_NET_MAX_SESSION_RULES) { ports[key]?.session.removeFirst() }
        guard let id = ports[key]?.id else { return }
        track { await self.sendLogged(Firewall.sessionCommand(rule, port: id), for: key) }
    }

    private func forgetSession(_ key: UUID) {
        guard ports[key] != nil else { return }
        ports[key]?.session = []
        guard let id = ports[key]?.id else { return }
        track { await self.sendLogged("forget \(id)", for: key) }
    }

    private func sendLogged(_ line: String, for key: UUID) async {
        do {
            try await expectOK(line)
        } catch {
            let vm = ports[key]?.vm ?? "?"
            Log.host.error("\(vm, privacy: .public): \(line, privacy: .public) was refused: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A line netd sent on its own.
    private func event(_ line: String) {
        guard let parsed = FirewallAsk.parse(line, id: nextAskID) else {
            Log.host.error("monad-netd sent an unknown event")
            return
        }
        nextAskID += 1
        guard let port = ports.values.first(where: { $0.id == parsed.port }) else { return }
        port.nic?.ask(parsed.ask)
    }

    /// Sends the firewall and tells the VM what came of it (the Firewall
    /// page shows a refusal: the saved rules would otherwise read as in force).
    private func sendFirewallLogged(_ key: UUID) async {
        do {
            try await sendFirewall(key)
            ports[key]?.nic?.firewallApplied(problem: ports[key]?.enforced?.problem)
        } catch {
            let vm = ports[key]?.vm ?? "?"
            Log.host.error("\(vm, privacy: .public)'s firewall was not applied: \(error.localizedDescription, privacy: .public)")
            ports[key]?.nic?.firewallApplied(problem: "monad-netd refused these rules (\(error.localizedDescription)): "
                                                       + "the ones before are still in force.")
        }
    }

    private func watchTags() {
        guard tagsWatch == nil else { return }
        _ = try? tags.all() // the folder exists from here on
        let fd = open(tags.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tagsChanged() }
        }
        source.setCancelHandler { close(fd) }
        tagsWatch = source
        source.resume()
    }

    /// A tag was saved or deleted: VMs carrying tags get their firewall again
    /// (sent only where what it resolves to changed).
    private func tagsChanged() {
        guard control >= 0 else { return }
        for (key, port) in ports where !port.firewall.allTags.isEmpty {
            track { await self.sendFirewallLogged(key) }
        }
    }

    // MARK: Ports

    private func sendPort(_ key: UUID, networkID: Int) async throws -> Int {
        guard let port = ports[key] else { throw SupervisorError.unavailable("the port went away") }
        let copy = dup(port.netdEnd) // netd gets its own descriptor; ours stays for a restart
        guard copy >= 0 else { throw SupervisorError.unavailable(String(cString: strerror(errno))) }
        defer { close(copy) }
        ports[key]?.enforced = nil // a new port starts closed
        return try parseID(try await command("port \(networkID) \(port.mac)", fd: copy))
    }

    private func detach(_ key: UUID) {
        guard let port = ports.removeValue(forKey: key) else { return }
        debug("\(port.vm) leaves \(port.network) (port \(port.id.map(String.init) ?? "none"))")
        close(port.netdEnd)
        if let id = port.id, control >= 0 { track { _ = try? await self.command("unport \(id)") } }
    }

    // MARK: netd's lifetime

    /// Returns once netd is set up, not merely started: a VM joining while
    /// `launch` still hands it the earlier NICs would have its own port
    /// asked for twice (netd refuses the second, failing both).
    private func ensureRunning() async throws {
        if let starting { return try await starting.value }
        if control >= 0 { return }
        let task = Task { try await self.launch() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func launch() async throws {
        closing = false
        // The NICs from before this netd: only they are handed to it again.
        let earlier = Array(ports.keys)
        var sv: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0 else {
            throw SupervisorError.unavailable(String(cString: strerror(errno)))
        }
        var on: Int32 = 1
        setsockopt(sv[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(sv[0], F_SETFD, FD_CLOEXEC)
        let child = mnd_netd_spawn(executable, sv[1])
        close(sv[1])
        guard child > 0 else {
            close(sv[0])
            throw SupervisorError.unavailable("it could not be started")
        }
        control = sv[0]
        pid = child
        startReading()
        networks.removeAll()
        creating.removeAll()
        networksGeneration += 1
        Log.host.notice("monad-netd started (pid \(child))")
        debug("started monad-netd (pid \(child))")
        if hostWatcher == nil, hostInfo is SystemHostNetworkInfo {
            hostWatcher = HostNetworkWatcher { [weak self] in self?.hostInfoChanged() }
        }
        watchTags()
        try await sendHostInfo()
        // After a restart: every network in use and every NIC, again.
        for key in earlier {
            guard let port = ports[key], let definition = try? store.network(named: port.network) else { continue }
            let networkID = try await ensureNetwork(definition)
            // Not `ports[key]?.id = try await …`: that holds an access to
            // `ports` across the await, and sendPort reads it.
            let portID = try await sendPort(key, networkID: networkID)
            ports[key]?.id = portID
            await sendFirewallLogged(key) // if refused, the port stays closed
            for rule in ports[key]?.session ?? [] { await sendLogged(Firewall.sessionCommand(rule, port: portID), for: key) }
        }
    }

    /// One odd entry would make netd refuse the whole list: only well-formed
    /// ones are sent, up to what netd keeps.
    private func sendHostInfo() async throws {
        let nameservers = hostInfo.nameservers.filter(Self.isNameserver)
        let networks = hostInfo.localNetworks.filter { NetworkDefinition.parseCIDR($0).map { $0.prefix > 0 } ?? false }
        let dropped = hostInfo.localNetworks.count - networks.count
        if dropped > 0 { debug("\(DebugLog.count(dropped, "Mac network")) not sent: not a.b.c.d/prefix") }
        if networks.count > Int(MND_NET_MAX_HOST_NETWORKS) {
            Log.host.error("the Mac has \(networks.count) networks, monad-netd blocks the first \(MND_NET_MAX_HOST_NETWORKS)")
            debug("the Mac has \(networks.count) networks, only the first \(MND_NET_MAX_HOST_NETWORKS) are blocked")
        }
        try await expectOK((["nameservers"] + nameservers.prefix(Int(MND_NETD_MAX_NAMESERVERS))).joined(separator: " "))
        try await expectOK((["hostnets"] + networks.prefix(Int(MND_NET_MAX_HOST_NETWORKS))).joined(separator: " "))
    }

    /// "a.b.c.d" or "a.b.c.d:port".
    private static func isNameserver(_ s: String) -> Bool {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let address = NetworkDefinition.parseIPv4(String(parts[0])), address != 0 else { return false }
        guard parts.count == 2 else { return true }
        return Int(parts[1]).map { (1...65535).contains($0) && String($0) == parts[1] } ?? false
    }

    /// netd's network for a definition; a changed definition gets a new one
    /// (VMs already on the old one stay there until they join again).
    private func ensureNetwork(_ definition: NetworkDefinition) async throws -> Int {
        if let known = networks[definition.name], known.definition == definition { return known.id }
        if let pending = creating[definition.name], pending.definition == definition, pending.generation == networksGeneration {
            return try await pending.task.value
        }
        let generation = networksGeneration
        let task = Task { @MainActor in try self.parseID(try await self.command(definition.netdNetworkCommand)) }
        creating[definition.name] = (definition, generation, task)
        defer { if creating[definition.name]?.generation == generation { creating[definition.name] = nil } }
        let id = try await task.value
        // netd restarted meanwhile: that network went with it.
        guard generation == networksGeneration else { return try await ensureNetwork(definition) }
        networks[definition.name] = (id, definition)
        return id
    }

    private func stopProcess() {
        if let reader {
            reader.cancel() // closes the channel once dispatch has let go of it
        } else if control >= 0 {
            close(control)
        }
        reader = nil
        control = -1
        let waiters = waiting
        waiting.removeAll()
        for w in waiters { w(.failure(SupervisorError.unavailable("it stopped"))) }
        if pid > 0 {
            let child = pid
            pid = 0
            // It exits once its channel closes; make sure, then collect it.
            DispatchQueue.global().async {
                var status: Int32 = 0
                for _ in 0..<50 {
                    if waitpid(child, &status, WNOHANG) == child { return }
                    usleep(20_000)
                }
                kill(child, SIGKILL)
                waitpid(child, &status, 0)
            }
        }
    }

    /// netd went away on its own: start it again if VMs use it.
    private func lost() {
        Log.host.error("monad-netd stopped unexpectedly")
        debug("monad-netd stopped unexpectedly\(ports.isEmpty ? "" : ", starting it again in \(Int(restartDelay)) s")")
        stopProcess()
        guard !closing, !ports.isEmpty else { return }
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 60)
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            guard let self, !Task.isCancelled, self.control < 0 else { return }
            do {
                try await self.ensureRunning()
                self.restartDelay = 1
            } catch {
                Log.host.error("monad-netd could not be started again: \(error.localizedDescription, privacy: .public)")
                self.lost()
            }
        }
    }

    // MARK: The channel

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: control, queue: .main)
        let fd = control
        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buf, buf.count)
            MainActor.assumeIsolated {
                guard let self, fd == self.control else { return }
                if n <= 0 {
                    self.lost()
                } else {
                    self.received(Data(buf[0..<n]))
                }
            }
        }
        // Closing a descriptor dispatch still watches aborts the process.
        source.setCancelHandler { close(fd) }
        reader = source
        source.resume()
    }

    private func received(_ data: Data) {
        pending.append(data)
        // netd's lines are at most MND_CTL_MAX_LINE: a longer one is a netd gone wrong.
        if pending.count > 1 << 16, !pending.contains(0x0A) {
            Log.host.error("monad-netd sent a line longer than 64 KB; starting it again")
            pending.removeAll()
            lost()
            return
        }
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...nl)
            if line.hasPrefix("event ") {
                event(line)
                continue
            }
            guard !waiting.isEmpty else { continue }
            waiting.removeFirst()(.success(line))
        }
    }

    private func command(_ line: String, fd: Int32 = -1) async throws -> String {
        try await commands([line], fd: fd)[0]
    }

    /// Replies to several commands, sent together: nothing else is sent
    /// between them (netd ends a firewall transaction at any other command).
    /// `fd` goes with the first.
    private func commands(_ lines: [String], fd: Int32 = -1) async throws -> [String] {
        guard control >= 0 else {
            debug("not sent, monad-netd is not running: \(lines.joined(separator: " ; "))")
            throw SupervisorError.unavailable("it is not running")
        }
        guard !lines.isEmpty else { return [] }
        guard debugLog.isEnabled else { return try await send(lines, fd: fd) }
        do {
            let replies = try await send(lines, fd: fd)
            debug(zip(lines, replies).map { "\($0) → \($1)" }.joined(separator: "\n"))
            return replies
        } catch {
            debug("\(lines.joined(separator: "\n")) → failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func send(_ lines: [String], fd: Int32) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let batch = ReplyBatch(expected: lines.count, continuation: continuation)
            for (i, line) in lines.enumerated() {
                guard mnd_netd_send_command(control, line, i == 0 ? fd : -1) == 0 else {
                    // Replies to lines already sent still arrive; the batch ignores them.
                    batch.fail(SupervisorError.unavailable("its channel is broken"))
                    return
                }
                waiting.append(batch.take)
            }
        }
    }

    private func expectOK(_ line: String) async throws {
        let reply = try await command(line)
        guard Self.isOK(reply) else { throw SupervisorError.refused(Self.reason(reply)) }
    }

    private static func isOK(_ reply: String) -> Bool { reply == "ok" || reply.hasPrefix("ok ") }

    private func parseID(_ reply: String) throws -> Int {
        guard reply.hasPrefix("ok "), let id = Int(reply.dropFirst(3)) else { throw SupervisorError.refused(Self.reason(reply)) }
        return id
    }

    private static func reason(_ reply: String) -> String {
        reply.hasPrefix("err ") ? String(reply.dropFirst(4)) : reply
    }
}

/// Collects the replies to a batch of commands, then resumes its caller once.
@MainActor
private final class ReplyBatch {
    private let expected: Int
    private var replies: [String] = []
    private var continuation: CheckedContinuation<[String], Error>?

    init(expected: Int, continuation: CheckedContinuation<[String], Error>) {
        self.expected = expected
        self.continuation = continuation
    }

    func take(_ result: Result<String, Error>) {
        switch result {
        case .success(let reply):
            replies.append(reply)
            if replies.count == expected { finish(.success(replies)) }
        case .failure(let error):
            finish(.failure(error))
        }
    }

    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<[String], Error>) {
        let c = continuation
        continuation = nil
        c?.resume(with: result)
    }
}

/// The Mac's nameservers (SystemConfiguration) and IPv4 networks (its interfaces).
struct SystemHostNetworkInfo: HostNetworkInfo {
    var nameservers: [String] {
        guard let store = SCDynamicStoreCreate(nil, "Monad" as CFString, nil, nil),
              let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = dns["ServerAddresses"] as? [String] else { return [] }
        return servers.filter { NetworkDefinition.parseIPv4($0) != nil }
    }

    var localNetworks: [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var out: [String] = []
        var i = list
        while let a = i {
            defer { i = a.pointee.ifa_next }
            let flags = Int32(a.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = a.pointee.ifa_addr,
                  let mask = a.pointee.ifa_netmask, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if let text = Self.network(address: ip, mask: m), !out.contains(text) { out.append(text) }
        }
        return out
    }

    /// "a.b.c.0/prefix" for an interface address. A full mask (PPPoE, some
    /// VPNs) is the Mac's own address alone, "/32": it must still reach netd.
    static func network(address: UInt32, mask: UInt32) -> String? {
        let prefix = mask.nonzeroBitCount
        guard prefix > 0, mask == ~UInt32(0) << (32 - UInt32(prefix)) else { return nil }
        let net = address & mask
        return "\(net >> 24).\((net >> 16) & 255).\((net >> 8) & 255).\(net & 255)/\(prefix)"
    }
}

/// Calls back when the Mac's nameservers or IPv4 addresses change
/// (SystemConfiguration notifications, no polling).
@MainActor
final class HostNetworkWatcher {
    private var store: SCDynamicStore?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let watcher = Unmanaged<HostNetworkWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        guard let store = SCDynamicStoreCreate(nil, "Monad" as CFString, callback, &context) else { return }
        let keys = ["State:/Network/Global/DNS", "State:/Network/Global/IPv4"] as CFArray
        let patterns = ["State:/Network/Interface/.*/IPv4"] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, keys, patterns),
              SCDynamicStoreSetDispatchQueue(store, DispatchQueue.main) else { return }
        self.store = store
    }

    isolated deinit {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
    }
}
