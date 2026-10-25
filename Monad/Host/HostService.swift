//
//  HostService.swift — MonadHost's side of the protocol: owns the VMManager,
//  answers requests from each connected app and pushes VM changes to all of
//  them. Transport-agnostic (XPC in production, direct calls in tests).
//
//  Tab sessions belong to the connection that attached them: when an app
//  quits or crashes its connection closes, its sessions are released, and
//  ephemeral VMs it used are discarded. Persistent VMs keep running.
//

import Combine
import Foundation
import os

@MainActor
final class HostService {
    struct Limits: Sendable {
        var maxCPUs: Int
        var maxMemoryGiB: Int

        static var host: Limits { Limits(HostCapacity.current) }
    }

    let manager: VMManager
    let limits: Limits
    /// Where the home folder and Monad's own folder are, for share checks.
    let sharePlaces: SharePolicy.Places
    /// Where answers saved on a firewall tag go.
    let tags: FirewallTagStore
    /// Reported in hello so apps can spot an outdated host.
    let build: String?
    /// An app asked the host to exit (it was idle); called after the reply.
    var onShutdown: (() -> Void)?
    /// The distributions MCP tools read and add to.
    var distroStore: () -> DistroStore = {
        let store = DistroStore(bundled: DistroCatalog.shipped ?? .empty)
        return store
    }
    /// Agents' questions for the user (MCPAccess).
    let approvals: Approvals
    /// "Always allow" answers, kept in `grantsFile`.
    private(set) var grants: MCPGrants
    let grantsFile: URL
    let audit: MCPAudit
    /// What is written on the canvas, kept in `notesStore`.
    private(set) var notes: [CanvasNote]
    let notesStore: CanvasNoteStore
    /// Brings Monad forward to ask the user (an agent's question); set by
    /// MonadHost (`openMonad`), nothing in tests.
    var openApp: () -> Void = {}

    static func openMonad() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", Flavor.current.appIdentifier]
        try? p.run()
    }
    /// Monad's version. MonadHost lives in Monad.app/Contents/MacOS, but its
    /// Bundle.main carries the tool's own embedded plist (no version), and
    /// Bundle(url:) for the app hands back that same object: the app's
    /// Info.plist is read from disk.
    nonisolated static var appVersion: String {
        Bundle.main.executableURL.flatMap(appVersion(executable:)) ?? "dev"
    }

    nonisolated static func appVersion(executable: URL) -> String? {
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist), data.count < 1 << 20,
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let v = info["CFBundleShortVersionString"] as? String, !v.isEmpty else { return nil }
        return v
    }

    /// Monad's MCP server (agents phase), made on first use.
    lazy var mcp: MCPServer = {
        let tools = MonadTools(service: self, distros: { [unowned self] in self.distroStore() })
        let server = MCPServer(name: "monad", version: Self.appVersion,
                               tools: { [unowned self] caller in
                                   MCPAccess.visible(tools.all() + tools.hostTools(for: caller), to: caller, vms: self.configs)
                               },
                               gate: { [unowned self] caller, tool, call in try await self.gate(caller, tool, call) })
        server.onCall = { [unowned self] caller, tool, arguments, result, duration in
            self.audit.record(caller: caller, tool: tool, arguments: arguments,
                              outcome: result.isError ? "error: \(result.text.prefix(200))" : "ok", duration: duration)
            self.debugLog.log("host", "mcp: \(MCPGrants.key(caller)) \(tool) → \(result.isError ? "error" : "ok")")
        }
        return server
    }()

    var configs: [String: InstanceConfig] {
        Dictionary(manager.instances.map { ($0.name, $0.config) }, uniquingKeysWith: { a, _ in a })
    }

    /// Before each MCP tool: allowed, refused, or the user is asked.
    private func gate(_ caller: MCPCaller, _ tool: MCPTool, _ call: MCPCall) async throws {
        let makesAMac = tool.name == "create_vm"
            && call.arguments["distro"]?.string.flatMap { manager.guestOS(ofDistro: $0) } == .macos
        switch MCPAccess.decide(caller: caller, tool: tool.name, risk: tool.risk, arguments: call.arguments,
                                vms: configs, grants: grants, makesAMac: makesAMac) {
        case .allow:
            return
        case .deny(let why):
            throw MonadError(why)
        case .ask:
            switch await approvals.ask(caller: caller, tool: tool.name, arguments: call.arguments) {
            case .deny: throw MonadError("The user did not allow \(tool.name). Do not try it again unless they ask.")
            case .once: return
            case .alwaysTool: grant(caller, tool: tool.name)
            case .alwaysAll: grant(caller, tool: nil)
            }
        }
    }

    private func grant(_ caller: MCPCaller, tool: String?) {
        grants.add(caller, tool: tool)
        try? grants.save(grantsFile)
    }

    func revoke(_ g: MCPGrants.Grant) {
        grants.grants.removeAll { $0 == g }
        try? grants.save(grantsFile)
    }

    func forgetGrants(of vm: String) {
        grants.forget(vm: vm)
        try? grants.save(grantsFile)
    }

    // MARK: Canvas notes

    /// Adds or changes a note; a new one is `author`'s. A changed one keeps
    /// whoever wrote it unless its words change: then they are `author`'s
    /// (an agent cannot put words under the user's name). Every app is told.
    @discardableResult
    func setNote(_ note: CanvasNote, author: String) throws -> CanvasNote {
        var n = note
        if let i = notes.firstIndex(where: { $0.id == n.id }) {
            n.author = n.text == notes[i].text ? notes[i].author : author
            try n.validate()
            notes[i] = n
        } else {
            guard notes.count < CanvasNote.maxNotes else {
                throw MonadError("The canvas holds at most \(CanvasNote.maxNotes) notes. Remove some first.")
            }
            n.author = author
            try n.validate()
            notes.append(n)
        }
        notesChanged()
        return n
    }

    func removeNote(_ id: String) throws {
        guard notes.contains(where: { $0.id == id }) else { throw MonadError("There is no note \(id) on the canvas.") }
        notes = CanvasNote.forget("note:" + id, in: notes)
        notesChanged()
    }

    private func notesChanged() {
        try? notesStore.save(notes)
        broadcast(.notes(notes))
    }
    // MARK: macOS setup (Phase 14)

    /// macOS VMs waiting for the user's password, by VM.
    private var macSetups: [String: (request: MacSetupRequest, waiter: CheckedContinuation<String, Error>)] = [:]

    /// The answer from an app; false when nothing is asked of `vm`.
    func answerMacSetup(_ vm: String, work: String?, error: String?) -> Bool {
        guard let asked = macSetups.removeValue(forKey: vm) else { return false }
        publish(vm)
        if let work {
            asked.waiter.resume(returning: work)
        } else {
            asked.waiter.resume(throwing: MonadError(error ?? "The setup did not run."))
        }
        return true
    }

    /// The VM is going (deleted): nothing to ask any more.
    func cancelMacSetup(_ vm: String) {
        guard let asked = macSetups.removeValue(forKey: vm) else { return }
        asked.waiter.resume(throwing: MonadError("The VM was deleted before its setup finished."))
    }

    private var connections: [ObjectIdentifier: HostConnection] = [:]
    private var observed: [String: AnyCancellable] = [:]
    /// The VMs observed, for the last snapshot of one that goes.
    private var last: [String: VMInstance] = [:]
    private var instancesObserver: AnyCancellable?
    private var orderObserver: AnyCancellable?
    private var defaultObserver: AnyCancellable?
    private var dirty: Set<String> = []
    private var flushScheduled = false

    /// Called when `isBusy` changes (drives idle exit, see HostLifetime).
    var onBusyChanged: ((Bool) -> Void)?
    private var wasBusy = false
    /// Settings › Logs.
    let debugLog: DebugLog
    /// The last summary logged per VM: only changes are logged.
    private var logged: [String: String] = [:]

    init(manager: VMManager, limits: Limits = .host, build: String? = HostBuild.current,
         tags: FirewallTagStore = FirewallTagStore(), debugLog: DebugLog = .shared,
         sharePlaces: SharePolicy.Places = .mac, agents: URL = Paths.root.appendingPathComponent("agents"),
         approvals: Approvals? = nil) {
        grantsFile = agents.appendingPathComponent("grants.json")
        grants = MCPGrants.load(agents.appendingPathComponent("grants.json"))
        audit = MCPAudit(url: agents.appendingPathComponent("audit.log"))
        notesStore = CanvasNoteStore(url: agents.deletingLastPathComponent().appendingPathComponent("canvas-notes.json"))
        notes = notesStore.load()
        self.approvals = approvals ?? Approvals()
        self.manager = manager
        self.limits = limits
        self.sharePlaces = sharePlaces
        self.tags = tags
        self.build = build
        self.debugLog = debugLog
        instancesObserver = manager.$instances.sink { [weak self] list in
            self?.instancesChanged(list)
        }
        orderObserver = manager.$order.dropFirst().removeDuplicates().sink { [weak self] order in
            self?.broadcast(.order(order))
        }
        defaultObserver = manager.$chosenDefault.combineLatest(manager.$order)
            .map { chosen, order in chosen ?? order.first }
            .removeDuplicates().dropFirst()
            .sink { [weak self] name in self?.broadcast(.defaultVM(name)) }
        self.approvals.onChange = { [weak self] list in self?.broadcast(.approvals(list)) }
        MCPRouter.handler = { [weak self] vm, data in await self?.mcp.handle(data, caller: .vm(vm)) }
        self.approvals.onAsk = { [weak self] in self?.openApp() }
        manager.macSetupAsker = self
    }

    var connectionCount: Int { connections.count }

    /// Whether anything needs the host: a connected app, or a VM that is
    /// running or being created.
    var isBusy: Bool {
        !connections.isEmpty || manager.instances.contains { $0.isRunning || $0.state.isPreparing }
    }

    private func updateBusy() {
        let busy = isBusy
        guard busy != wasBusy else { return }
        wasBusy = busy
        onBusyChanged?(busy)
    }

    /// A new client. `send` delivers events to it, always on the main actor.
    func connect(send: @escaping (HostEvent) -> Void) -> HostConnection {
        let c = HostConnection(service: self, send: send)
        connections[ObjectIdentifier(c)] = c
        debugLog.log("host", "an app connected (\(DebugLog.count(connections.count, "connection")))")
        updateBusy()
        return c
    }

    /// A connection for MonadHost's own use (the MCP tools): it gets no
    /// events and does not keep the host running.
    func internalConnection() -> HostConnection {
        HostConnection(service: self, send: { _ in })
    }

    fileprivate func disconnected(_ c: HostConnection) {
        guard connections.removeValue(forKey: ObjectIdentifier(c)) != nil else { return }
        debugLog.log("host", "an app disconnected (\(DebugLog.count(connections.count, "connection")) left)")
        updateBusy()
    }

    // MARK: Snapshots and events

    func snapshot(_ vm: VMInstance) -> VMSnapshot {
        VMSnapshot(name: vm.name, config: vm.config, state: vm.state, agent: vm.agentAvailable,
                   ports: vm.guestPorts.sorted { ($0.port, $0.address) < ($1.port, $1.address) },
                   sessions: manager.sessions(for: vm), forwards: vm.forwards.isEmpty ? nil : vm.forwards,
                   portsOverLimit: vm.portsOverLimit == 0 ? nil : vm.portsOverLimit,
                   pendingRestart: vm.pendingRestart.isEmpty ? nil : vm.pendingRestart, sharesError: vm.sharesError,
                   firewallProblem: vm.firewallProblem,
                   firewallAsks: vm.firewallAsks.isEmpty ? nil : vm.firewallAsks,
                   profileRuns: vm.profileRuns.isEmpty ? nil : vm.profileRuns,
                   macSetup: macSetups[vm.name]?.request, macSecurity: vm.macSecurity)
    }

    private func instancesChanged(_ list: [VMInstance]) {
        let names = Set(list.map(\.name))
        for gone in observed.keys where !names.contains(gone) {
            observed[gone] = nil
            // Its last change first: a creation that failed says why before
            // the VM goes.
            if dirty.remove(gone) != nil, let vm = last[gone] { broadcast(.instance(snapshot(vm))) }
            last[gone] = nil
            for c in connections.values { c.forget(gone) }
            broadcast(.removed(gone))
            let kept = CanvasNote.forget("vm:" + gone, in: notes)
            if kept != notes {
                notes = kept
                notesChanged()
            }
        }
        for vm in list where observed[vm.name] == nil {
            let name = vm.name
            last[name] = vm
            // objectWillChange fires before the new value is stored: publish
            // on the next turn, coalescing bursts into one snapshot.
            observed[name] = vm.objectWillChange.sink { [weak self] _ in self?.markDirty(name) }
            markDirty(name)
        }
        updateBusy()
    }

    private func markDirty(_ name: String) {
        dirty.insert(name)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        let names = dirty
        dirty.removeAll()
        for name in names.sorted() { publish(name) }
        updateBusy()
    }

    /// Send the current snapshot of `name` now.
    fileprivate func publish(_ name: String) {
        guard let vm = manager.existing(name) else { return }
        broadcast(.instance(snapshot(vm)))
    }

    private func broadcast(_ event: HostEvent) {
        if debugLog.isEnabled { logEvent(event) }
        for c in connections.values { c.deliver(event) }
    }

    /// What the apps are told about a VM, when it changed.
    private func logEvent(_ event: HostEvent) {
        switch event {
        case .instance(let s):
            var parts = [s.state.debugName, "agent \(s.agent ? "on" : "off")", DebugLog.count(s.sessions, "tab"),
                         DebugLog.count(s.ports.count, "guest port")]
            if let f = s.forwards {
                let failed = f.filter { if case .failed = $0.state { return true } else { return false } }.count
                parts.append(DebugLog.count(f.count, "forward") + (failed > 0 ? " (\(failed) failed)" : ""))
            }
            if let p = s.pendingRestart { parts.append("after a restart: " + p.joined(separator: ", ")) }
            if let e = s.sharesError { parts.append("shares: " + e) }
            if let a = s.firewallAsks { parts.append(DebugLog.count(a.count, "firewall question")) }
            if let r = s.profileRuns { parts.append("profiles: " + r.map { "\($0.profile) \($0.state.rawValue)" }.joined(separator: ", ")) }
            let summary = parts.joined(separator: ", ")
            guard logged[s.name] != summary else { return }
            logged[s.name] = summary
            debugLog.log("host", "event \(s.name): \(summary)")
        case .removed(let name):
            logged[name] = nil
            debugLog.log("host", "event \(name): removed")
        case .order(let names):
            debugLog.log("host", "event order: \(names.joined(separator: ", "))")
        case .approvals(let list):
            debugLog.log("host", "event approvals: \(DebugLog.count(list.count, "question")) waiting")
        case .notes(let list):
            debugLog.log("host", "event notes: \(DebugLog.count(list.count, "note")) on the canvas")
        case .defaultVM(let name):
            debugLog.log("host", "event default VM: \(name ?? "none")")
        }
    }
}

@MainActor
final class HostConnection {
    private weak var service: HostService?
    private let send: (HostEvent) -> Void
    private var greeted = false
    private var closed = false
    /// Tab sessions this client holds, per VM.
    private var sessions: [String: Int] = [:]

    fileprivate init(service: HostService, send: @escaping (HostEvent) -> Void) {
        self.service = service
        self.send = send
    }

    /// `name` was deleted; a later VM with the same name starts unattached.
    fileprivate func forget(_ name: String) { sessions[name] = nil }

    fileprivate func deliver(_ event: HostEvent) {
        guard !closed, greeted else { return }
        send(event)
    }

    /// The client went away: release everything it held.
    func close() {
        guard !closed else { return }
        closed = true
        guard let service else { return }
        for (name, count) in sessions {
            guard let vm = service.manager.existing(name) else { continue }
            for _ in 0..<count { service.manager.release(vm) }
            service.publish(name)
        }
        sessions.removeAll()
        service.disconnected(self)
    }

    /// Raw transport entry point: never throws, always answers.
    func handle(_ data: Data) async -> Data {
        let response: HostResponse
        do {
            let request = try HostProtocol.decode(HostRequest.self, from: data)
            response = await handle(request)
        } catch {
            Log.host.error("rejected message: \(error.localizedDescription, privacy: .public)")
            response = HostResponse(id: 0, error: error.localizedDescription)
        }
        return (try? HostProtocol.encode(response)) ?? Data(#"{"id":0,"ok":false}"#.utf8)
    }

    func handle(_ request: HostRequest) async -> HostResponse {
        let log = service?.debugLog ?? .shared
        let what = "#\(request.id) \(request.op.rawValue)" + (request.name.map { " " + $0 } ?? "")
            + (request.profiles.map { " " + $0.joined(separator: ",") } ?? "")
        // Windows poll connections and traffic every few seconds: logged only when they fail.
        let quiet = request.op == .connections || request.op == .traffic
        if !quiet { log.log("host", what) }
        let start = ContinuousClock.now
        let response: HostResponse
        do {
            try request.validate()
            response = try await perform(request)
        } catch {
            var r = HostResponse(id: request.id, error: error.localizedDescription)
            if case .versionMismatch = error as? HostProtocolError { r.version = HostProtocol.version }
            response = r
        }
        if !quiet || !response.ok {
            log.log("host", "\(what) → \(response.ok ? "ok" : "error") after \(DebugLog.elapsed(since: start))"
                    + (response.ok ? "" : ": \(response.error ?? "no reason given")"))
        }
        return response
    }

    private func perform(_ r: HostRequest) async throws -> HostResponse {
        guard let service, !closed else { throw MonadError("The connection is closed.") }
        let manager = service.manager

        if r.op == .hello {
            guard r.version == HostProtocol.version else {
                throw HostProtocolError.versionMismatch(host: HostProtocol.version, app: r.version ?? 0)
            }
            greeted = true
            // Questions asked before this app came (it was opened for them).
            if !service.approvals.pending.isEmpty { send(.approvals(service.approvals.pending)) }
            var reply = HostResponse(id: r.id, version: HostProtocol.version)
            reply.build = service.build
            return reply
        }
        guard greeted else { throw HostProtocolError.invalid("Say hello first.") }

        func vm(_ name: String?) throws -> VMInstance {
            guard let name, let vm = manager.existing(name) else { throw MonadError("No VM named \(r.name ?? "").") }
            return vm
        }
        func answer(_ vm: VMInstance) -> HostResponse { HostResponse(id: r.id, instance: service.snapshot(vm)) }

        switch r.op {
        case .hello:
            preconditionFailure("handled above")

        case .list:
            var reply = HostResponse(id: r.id, instances: manager.instances.map(service.snapshot))
            reply.order = manager.order
            reply.defaultVM = manager.defaultVMName
            return reply

        case .reorder:
            manager.reorder(r.names!)
            var reply = HostResponse(id: r.id, instances: manager.instances.map(service.snapshot))
            reply.order = manager.order
            reply.defaultVM = manager.defaultVMName
            return reply

        case .setDefault:
            try manager.setDefault(r.name!)
            var reply = HostResponse(id: r.id)
            reply.defaultVM = manager.defaultVMName
            return reply

        case .ensureDefault:
            return answer(manager.defaultInstance())

        case .createEphemeral:
            return answer(manager.createEphemeral())

        case .create:
            var config = r.config!
            // What runs in it, from its distribution, before its settings are checked.
            if let os = manager.guestOS(ofDistro: config.distro) { config.guestOS = os }
            try SharePolicy.apply(&config, places: service.sharePlaces)
            try config.validate(maxCPUs: service.limits.maxCPUs, maxMemoryGiB: service.limits.maxMemoryGiB)
            return answer(try manager.create(config))

        case .update:
            var config = r.config!
            let target = try vm(config.name)
            try SharePolicy.apply(&config, places: service.sharePlaces,
                                  known: Set(target.config.sharing.shares.map(\.hostPath)))
            try config.validate(maxCPUs: service.limits.maxCPUs, maxMemoryGiB: service.limits.maxMemoryGiB)
            try target.update(config)
            return answer(target)

        case .start:
            let target = try vm(r.name)
            manager.start(target)
            return answer(target)

        case .stop:
            let target = try vm(r.name)
            manager.cancelStart(target)
            let force = r.isForced
            Task { @MainActor in if force { await target.forceStop() } else { await target.stop() } }
            return answer(target)

        case .restart:
            // Done here so it completes even if the app goes away meanwhile.
            let target = try vm(r.name)
            Task { @MainActor in
                if target.isRunning { await target.stop() }
                target.start()
            }
            return answer(target)

        case .clone:
            let source = try vm(r.name)
            var config = r.config!
            try SharePolicy.apply(&config, places: service.sharePlaces)
            try config.validate(maxCPUs: service.limits.maxCPUs, maxMemoryGiB: service.limits.maxMemoryGiB)
            return answer(try await manager.clone(source, as: config.name, settings: config))

        case .openDesktop:
            let target = try vm(r.name)
            try target.openDesktop()
            return answer(target)

        case .delete:
            service.cancelMacSetup(r.name!)
            try await manager.delete(try vm(r.name))
            service.forgetGrants(of: r.name!)
            return HostResponse(id: r.id)

        case .answerApproval:
            guard service.approvals.answer(r.approvalID!, r.approvalAnswer!) else {
                throw MonadError("That question is no longer waiting (it was answered, or two minutes passed).")
            }
            return HostResponse(id: r.id)

        case .agentStatus:
            var reply = HostResponse(id: r.id)
            reply.grants = service.grants.grants
            reply.audit = service.audit.tail(50)
            return reply

        case .answerMacSetup:
            guard service.answerMacSetup(r.name!, work: r.macSetupWork, error: r.macSetupError) else {
                throw MonadError("Nothing is waiting to be set up in \(r.name!).")
            }
            return HostResponse(id: r.id)

        case .revokeGrant:
            service.revoke(r.grant!)
            var reply = HostResponse(id: r.id)
            reply.grants = service.grants.grants
            return reply

        case .notes, .setNote, .removeNote:
            if r.op == .setNote { try service.setNote(r.note!, author: "you") }
            if r.op == .removeNote { try service.removeNote(r.noteID!) }
            var reply = HostResponse(id: r.id)
            reply.notes = service.notes
            return reply

        case .attach:
            let target = try vm(r.name)
            sessions[target.name, default: 0] += 1
            manager.retain(target)
            if target.state == .stopped || target.isFailed { target.start() }
            service.publish(target.name)
            return answer(target)

        case .detach:
            let target = try vm(r.name)
            guard let held = sessions[target.name], held > 0 else { return answer(target) }
            sessions[target.name] = held == 1 ? nil : held - 1
            manager.release(target)
            service.publish(target.name)
            return answer(target)

        case .stopAll:
            await manager.stopAll(because: "Monad asked to stop every VM")
            return HostResponse(id: r.id)

        case .answerFirewall:
            let target = try vm(r.name)
            try target.answerFirewall(r.firewallAnswer!, tags: service.tags)
            return answer(target)

        case .runProfiles:
            let target = try vm(r.name)
            try target.runProfiles(r.profiles!)
            return answer(target)

        case .stopProfiles:
            let target = try vm(r.name)
            target.stopProfiles()
            return answer(target)

        case .connections:
            var reply = HostResponse(id: r.id)
            reply.connections = try await vm(r.name).connections()
            return reply

        case .traffic:
            var reply = HostResponse(id: r.id)
            reply.traffic = try await manager.traffic()
            return reply

        case .mcp:
            var reply = HostResponse(id: r.id)
            reply.mcp = await service.mcp.handle(Data(r.mcp!.utf8), caller: .mac).map { String(decoding: $0, as: UTF8.self) }
            return reply

        case .shutdown:
            guard !manager.instances.contains(where: { $0.isRunning || $0.state.isPreparing }) else {
                throw MonadError("MonadHost keeps running while VMs are in use.")
            }
            Log.host.notice("shutdown requested by an app")
            Task { @MainActor in service.onShutdown?() }
            return HostResponse(id: r.id)
        }
    }
}

extension HostService: MacSetupAuthorizing {
    nonisolated var workFolderParent: String { "/private/tmp" }

    /// Asks the apps (opening Monad if none is there) and waits for the one
    /// that answers.
    func authorize(vm: String, disk: URL, payload: URL) async throws -> String {
        cancelMacSetup(vm)
        return try await withCheckedThrowingContinuation { waiter in
            macSetups[vm] = (MacSetupRequest(disk: disk.path, payload: payload.path), waiter)
            publish(vm)
            if connectionCount == 0 { openApp() }
        }
    }
}
