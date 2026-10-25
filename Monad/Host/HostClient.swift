//
//  HostClient.swift — the app's connection to MonadHost. Mirrors every VM as
//  a RemoteVM (stable object per name, updated from host events), forwards
//  commands, and survives the host going away: it reconnects with backoff,
//  reloads the VM list and re-attaches the tab sessions it holds, so a host
//  restart brings the VMs of open tabs back up.
//

import Combine
import Foundation
import os

/// One connection to MonadHost. Callbacks arrive on the main actor.
@MainActor
protocol HostTransport: AnyObject {
    /// Sends an encoded HostRequest and returns the encoded HostResponse.
    /// Throws when the connection is gone.
    func send(_ request: Data) async throws -> Data
    /// Encoded HostEvents pushed by the host.
    var onEvent: ((Data) -> Void)? { get set }
    /// The connection broke (host exited, crashed or was replaced).
    var onInvalidated: (() -> Void)? { get set }
    /// Close from this side; `onInvalidated` is not called.
    func invalidate()
}

enum HostClientError: Error, Equatable, LocalizedError {
    case unavailable
    case incompatible
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: return "MonadHost is not reachable."
        case .incompatible: return "The running MonadHost belongs to a different Monad version."
        case .unexpectedResponse: return "MonadHost sent an unexpected response."
        }
    }
}

/// The app-side mirror of one VM.
@MainActor
final class RemoteVM: ObservableObject, Identifiable {
    nonisolated let name: String
    /// Files of the instance (ssh config, serial log), shared with the host.
    let paths: InstancePaths
    @Published private(set) var snapshot: VMSnapshot

    init(snapshot: VMSnapshot, root: URL) {
        name = snapshot.name
        paths = InstancePaths(name: snapshot.name, root: root)
        self.snapshot = snapshot
    }

    nonisolated var id: String { name }
    var config: InstanceConfig { snapshot.config }
    var state: VMState { snapshot.state }
    var sessions: Int { snapshot.sessions }
    var agentAvailable: Bool { snapshot.agent }
    var guestPorts: [ListeningPort] { snapshot.ports }
    var forwards: [ForwardStatus] { snapshot.forwards ?? [] }
    var portsOverLimit: Int { snapshot.portsOverLimit ?? 0 }
    var pendingRestart: [String] { snapshot.pendingRestart ?? [] }
    var sharesError: String? { snapshot.sharesError }
    var firewallProblem: String? { snapshot.firewallProblem }
    /// macOS: System Integrity Protection as found at the last boot.
    var macSecurity: MacSecurityReport? { snapshot.macSecurity }
    /// Monitor-mode questions waiting for the user.
    var firewallAsks: [FirewallAsk] { snapshot.firewallAsks ?? [] }
    var profileRuns: [ProfileRun] { snapshot.profileRuns ?? [] }
    var isRunning: Bool { state.isRunning }
    var isFailed: Bool { state.isFailed }
    var sshHost: String { config.sshHost }

    /// State changes only (not every snapshot update).
    var statePublisher: AnyPublisher<VMState, Never> {
        $snapshot.map(\.state).removeDuplicates().eraseToAnyPublisher()
    }

    fileprivate func update(_ s: VMSnapshot) {
        if s != snapshot { snapshot = s }
    }
}

@MainActor
final class HostClient: ObservableObject {
    enum Status: Equatable {
        case connecting
        case connected
        case unavailable(String)
        case incompatible(String)
    }

    @Published private(set) var status: Status = .connecting {
        didSet {
            guard status != oldValue else { return }
            switch status {
            case .connecting: debug("connecting to the VM service")
            case .connected: debug("connected to the VM service (build \(hostBuild ?? "unknown"))")
            case .unavailable(let why): debug("the VM service is not reachable: \(why)")
            case .incompatible(let why): debug("the VM service is incompatible: \(why)")
            }
        }
    }
    /// Every VM the host knows, in the user's order (the host's), ephemeral
    /// VMs last.
    @Published private(set) var instances: [RemoteVM] = []
    /// Agents' questions waiting for the user (MCPAccess).
    @Published private(set) var approvals: [ApprovalRequest] = []
    /// What is written on the canvas (MonadHost's, kept up to date).
    @Published private(set) var notes: [CanvasNote] = []
    /// The host's order of the persistent VMs (empty from an older host).
    private var order: [String] = []
    /// The default VM (Make Default; the top one until one is chosen). An
    /// older host does not say: the top one.
    @Published private(set) var defaultName: String?
    private var hostSaysDefault = false
    /// Identity of the connected host (see HostBuild).
    @Published private(set) var hostBuild: String?
    /// The host is older than this app's and could not be replaced (VMs
    /// were running); it is replaced once it has been idle and exits.
    @Published private(set) var hostIsOutdated = false {
        didSet {
            if hostIsOutdated != oldValue {
                debug(hostIsOutdated ? "the VM service is from an older Monad (build \(hostBuild ?? "unknown"), expected \(expectedHostBuild ?? "unknown"))"
                      : "the VM service is up to date")
            }
        }
    }

    /// Runs before connecting when no host is serving: after an outdated host
    /// made way, and after the first failed attempt of a streak. The app uses
    /// it to refresh the launch agent's registration (launchd pins the agent
    /// binary it was registered with). Never runs while a host is reachable,
    /// so it cannot disturb running VMs.
    var prepareHostLaunch: (@MainActor () async -> Void)?

    /// Settings › Logs.
    private let debugLog: DebugLog
    private func debug(_ message: @autoclosure () -> String) { debugLog.log("client", message()) }

    private let makeTransport: @MainActor () throws -> HostTransport
    private let clock: MonadClock
    private let root: URL
    private let requestTimeout: TimeInterval
    /// A host that accepts the connection but does not answer hello in time
    /// is treated as unreachable. (launchd holds messages for an agent it
    /// cannot spawn instead of failing them.)
    static let handshakeTimeout: TimeInterval = 5
    private let protocolVersion: Int
    private let expectedHostBuild: String?
    private var replacementAttempted = false
    private var replacementWait: CheckedContinuation<Void, Never>?

    private var transport: HostTransport?
    private var connectTask: Task<Void, Never>?
    private var stopped = false
    private var nextID: UInt64 = 0
    /// Tab sessions this app holds, re-attached after a reconnect.
    private var attachments: [String: Int] = [:]
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(connect: @escaping @MainActor () throws -> HostTransport, clock: MonadClock = SystemClock(),
         instanceRoot: URL = Paths.instances, requestTimeout: TimeInterval = 20,
         protocolVersion: Int = HostProtocol.version, expectedHostBuild: String? = nil, debugLog: DebugLog = .shared) {
        self.debugLog = debugLog
        makeTransport = connect
        self.expectedHostBuild = expectedHostBuild
        self.clock = clock
        root = instanceRoot
        self.requestTimeout = requestTimeout
        self.protocolVersion = protocolVersion
    }

    func vm(named name: String) -> RemoteVM? { instances.first { $0.name == name } }

    /// The default VM, opened first when Monad opens: the one chosen with
    /// Make Default, else the top of the list.
    var defaultVM: RemoteVM? {
        defaultName.flatMap(vm(named:)) ?? instances.first { !$0.config.ephemeral }
    }

    // MARK: Connection

    func start() {
        guard connectTask == nil, transport == nil, !stopped else { return }
        connectTask = Task { [weak self] in await self?.connectLoop() }
    }

    /// Disconnect for good (app quitting). The host releases our sessions.
    func stop() {
        stopped = true
        connectTask?.cancel()
        connectTask = nil
        transport?.invalidate()
        transport = nil
        replacementWait?.resume()
        replacementWait = nil
        failWaiters(.unavailable)
    }

    private func connectLoop() async {
        var delay: TimeInterval = 0.25
        var failures = 0
        while !stopped, !Task.isCancelled {
            do {
                if try await connectOnce() {
                    connectTask = nil
                    return
                }
                // The outdated host is exiting: wait for it to go, then
                // connect again (launchd starts the new binary).
                await waitForReplacement()
                if let prepare = prepareHostLaunch { await prepare() }
                continue
            } catch HostClientError.incompatible {
                connectTask = nil
                return
            } catch {
                transport?.invalidate()
                transport = nil
                if !stopped { status = .unavailable(error.localizedDescription) }
                Log.host.info("MonadHost unreachable: \(error.localizedDescription, privacy: .public)")
                // Prepared after the first failure, and again after every
                // five more while the host stays unreachable (a preparation
                // that did not bring it back, such as launchd losing the job).
                failures += 1
                if failures % 5 == 1, let prepare = prepareHostLaunch {
                    await prepare()
                    continue
                }
                await clock.sleep(seconds: delay)
                delay = min(delay * 2, 10)
            }
        }
        connectTask = nil
    }

    /// Returns false when the host agreed to exit for a newer build.
    private func connectOnce() async throws -> Bool {
        let t = try makeTransport()
        transport = t
        t.onEvent = { [weak self] data in self?.receive(data) }
        t.onInvalidated = { [weak self, weak t] in
            guard let self, let t else { return }
            self.lost(t)
        }

        let hello = try await handshake(HostRequest(id: takeID(), op: .hello, version: protocolVersion), on: t)
        guard hello.ok else {
            if let v = hello.version, v != protocolVersion {
                let message = HostProtocolError.versionMismatch(host: v, app: protocolVersion).localizedDescription
                Log.host.error("\(message, privacy: .public)")
                t.invalidate()
                transport = nil
                status = .incompatible(message)
                failWaiters(.incompatible)
                throw HostClientError.incompatible
            }
            throw MonadError(hello.error ?? "MonadHost refused the connection.")
        }
        hostBuild = hello.build
        if let expected = expectedHostBuild, let running = hello.build, running != expected {
            if !replacementAttempted {
                replacementAttempted = true
                let r = try await roundTrip(HostRequest(id: takeID(), op: .shutdown), on: t)
                if r.ok {
                    Log.host.notice("replacing MonadHost \(running, privacy: .public) with \(expected, privacy: .public)")
                    return false
                }
                Log.host.notice("MonadHost is outdated but busy: \(r.error ?? "", privacy: .public)")
            }
            hostIsOutdated = true
        } else {
            hostIsOutdated = false
        }

        let list = try await roundTrip(HostRequest(id: takeID(), op: .list), on: t)
        guard list.ok, let snapshots = list.instances else { throw HostClientError.unexpectedResponse }
        reconcile(snapshots, order: list.order)
        hostSaysDefault = list.defaultVM != nil
        defaultName = list.defaultVM ?? order.first
        for (name, count) in attachments.sorted(by: { $0.key < $1.key }) {
            for _ in 0..<count {
                let r = try await roundTrip(HostRequest(id: takeID(), op: .attach, name: name), on: t)
                if let snap = r.instance { upsert(snap) }
            }
        }
        guard transport === t else { throw HostClientError.unavailable }
        status = .connected
        Log.host.notice("connected to MonadHost")
        let ready = waiters
        waiters.removeAll()
        for (_, w) in ready { w.resume() }
        return true
    }

    /// Until the old host's connection drops, at most 10 s.
    private func waitForReplacement() async {
        guard transport != nil else { return }
        let deadline = clock.now().addingTimeInterval(10)
        let timeout = Task { [weak self] in
            while let self, self.replacementWait != nil || self.transport != nil, self.clock.now() < deadline {
                await self.clock.sleep(seconds: 0.5)
            }
            self?.replacementWait?.resume()
            self?.replacementWait = nil
        }
        defer { timeout.cancel() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if transport == nil { c.resume() } else { replacementWait = c }
        }
        transport?.invalidate()
        transport = nil
    }

    /// roundTrip, but the transport is dropped if no answer comes in time.
    private func handshake(_ request: HostRequest, on t: HostTransport) async throws -> HostResponse {
        let clock = self.clock
        let deadline = clock.now().addingTimeInterval(Self.handshakeTimeout)
        var timedOut = false
        let watchdog = Task { @MainActor in
            while clock.now() < deadline {
                if Task.isCancelled { return }
                await clock.sleep(seconds: 0.5)
            }
            guard !Task.isCancelled else { return }
            timedOut = true
            Log.host.error("MonadHost did not answer within \(Int(Self.handshakeTimeout))s")
            t.invalidate()
        }
        defer { watchdog.cancel() }
        do {
            return try await roundTrip(request, on: t)
        } catch {
            throw timedOut ? HostClientError.unavailable : error
        }
    }

    private func lost(_ t: HostTransport) {
        guard t === transport, !stopped else { return }
        Log.host.notice("connection to MonadHost lost; reconnecting")
        transport = nil
        status = .connecting
        if let w = replacementWait {
            replacementWait = nil
            w.resume()
            return
        }
        if connectTask == nil {
            connectTask = Task { [weak self] in await self?.connectLoop() }
        }
    }

    /// Wait until connected, at most `requestTimeout`.
    private func connected() async throws {
        switch status {
        case .connected: return
        case .incompatible: throw HostClientError.incompatible
        default: break
        }
        if stopped { throw HostClientError.unavailable }
        let id = UUID()
        // Time out in the clock's time (virtual in tests).
        let deadline = clock.now().addingTimeInterval(requestTimeout)
        let timeout = Task { [weak self] in
            while let self, self.waiters[id] != nil, self.clock.now() < deadline {
                await self.clock.sleep(seconds: 1)
            }
            self?.waiters.removeValue(forKey: id)?.resume(throwing: HostClientError.unavailable)
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            waiters[id] = c
        }
    }

    private func failWaiters(_ error: HostClientError) {
        let pending = waiters
        waiters.removeAll()
        for (_, w) in pending { w.resume(throwing: error) }
    }

    // MARK: Messages

    private func takeID() -> UInt64 {
        nextID += 1
        return nextID
    }

    private func roundTrip(_ request: HostRequest, on t: HostTransport) async throws -> HostResponse {
        let reply = try await t.send(try HostProtocol.encode(request))
        let response = try HostProtocol.decode(HostResponse.self, from: reply)
        guard response.id == request.id else { throw HostClientError.unexpectedResponse }
        return response
    }

    /// Send a request once connected; host-side failures become errors.
    @discardableResult
    private func request(_ op: HostRequest.Op, name: String? = nil, force: Bool? = nil,
                         config: InstanceConfig? = nil, firewallAnswer: FirewallAnswer? = nil,
                         profiles: [String]? = nil, names: [String]? = nil,
                         edit: (inout HostRequest) -> Void = { _ in }) async throws -> HostResponse {
        let what = op.rawValue + (name.map { " " + $0 } ?? "")
        let start = ContinuousClock.now
        func failed(_ why: String) { debug("\(what) → error after \(DebugLog.elapsed(since: start)): \(why)") }
        do {
            try await connected()
        } catch {
            failed("not connected: \(error.localizedDescription)")
            throw error
        }
        guard let t = transport else {
            failed("not connected")
            throw HostClientError.unavailable
        }
        let r: HostResponse
        do {
            var request = HostRequest(id: takeID(), op: op, name: name, force: force, config: config,
                                      firewallAnswer: firewallAnswer, profiles: profiles, names: names)
            edit(&request)
            r = try await roundTrip(request, on: t)
        } catch let e as HostClientError {
            failed(e.localizedDescription)
            throw e
        } catch {
            failed("the connection broke: \(error.localizedDescription)")
            throw HostClientError.unavailable
        }
        guard r.ok else {
            failed(r.error ?? "no reason given")
            throw MonadError(r.error ?? "MonadHost could not \(op.rawValue).")
        }
        debug("\(what) → ok after \(DebugLog.elapsed(since: start))")
        if let snap = r.instance { upsert(snap) }
        return r
    }

    private func instance(from r: HostResponse) throws -> RemoteVM {
        guard let name = r.instance?.name, let vm = vm(named: name) else { throw HostClientError.unexpectedResponse }
        return vm
    }

    private func receive(_ data: Data) {
        guard let event = try? HostProtocol.decode(HostEvent.self, from: data) else {
            Log.host.error("dropped malformed event from MonadHost")
            return
        }
        switch event {
        case .instance(let snap): upsert(snap)
        case .removed(let name): remove(name)
        case .order(let names): setOrder(names)
        case .approvals(let list): approvals = Array(list.prefix(Approvals.maxPending))
        case .notes(let list): setNotes(list)
        case .defaultVM(let name):
            hostSaysDefault = true
            defaultName = name.flatMap { InstanceConfig.isValidName($0) ? $0 : nil }
        }
    }

    /// Why a VM that failed and was removed failed (only a creation fails
    /// that way), for a tab still opened on it.
    private var failedCreations: [String: String] = [:]

    private func upsert(_ snap: VMSnapshot) {
        guard InstanceConfig.isValidName(snap.name) else { return }
        if let vm = vm(named: snap.name) {
            // The Virtual Machines list is drawn from this client, in groups:
            // a VM changing group changes the list, not only the VM.
            if vm.config.group != snap.config.group { objectWillChange.send() }
            vm.update(snap)
        } else {
            failedCreations[snap.name] = nil
            instances.append(RemoteVM(snapshot: snap, root: root))
            arrange()
        }
    }

    /// The host's order, as far as it is VM names.
    private func setOrder(_ names: [String]) {
        order = Array(names.filter(InstanceConfig.isValidName).prefix(VMOrder.maxVMs))
        if !hostSaysDefault { defaultName = order.first }
        arrange()
    }

    private func arrange() {
        let names = VMOrder.arrange(instances.map(\.name),
                                    ephemeral: Set(instances.filter(\.config.ephemeral).map(\.name)), saved: order)
        guard names != instances.map(\.name) else { return }
        let byName = Dictionary(instances.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        instances = names.compactMap { byName[$0] }
    }

    private func remove(_ name: String) {
        attachments[name] = nil
        if case .failed(let why)? = vm(named: name)?.state { failedCreations[name] = why }
        instances.removeAll { $0.name == name }
    }

    private func reconcile(_ snapshots: [VMSnapshot], order: [String]?) {
        let names = Set(snapshots.map(\.name))
        for vm in instances where !names.contains(vm.name) { remove(vm.name) }
        for s in snapshots { upsert(s) }
        setOrder(order ?? [])
    }

    // MARK: Commands

    /// The VM called `name`, once connected.
    func existing(_ name: String) async throws -> RemoteVM {
        try await connected()
        guard let vm = vm(named: name) else {
            if let why = failedCreations[name] { throw MonadError("Creating \(name) failed: \(why)") }
            throw MonadError("No VM named \(name).")
        }
        return vm
    }

    func ensureDefault() async throws -> RemoteVM {
        try instance(from: try await request(.ensureDefault))
    }

    func createEphemeral() async throws -> RemoteVM {
        try instance(from: try await request(.createEphemeral))
    }

    func create(_ config: InstanceConfig) async throws -> RemoteVM {
        try instance(from: try await request(.create, config: config))
    }

    /// A copy of the stopped VM `name` with `config` (InstanceConfig.copy).
    func clone(_ name: String, as config: InstanceConfig) async throws -> RemoteVM {
        try instance(from: try await request(.clone, name: name, config: config))
    }

    func update(_ config: InstanceConfig) async throws {
        let r = try await request(.update, config: config)
        // A host from an older Monad (kept while VMs run) drops settings it
        // does not know when it saves them.
        if let saved = r.instance?.config, saved != config {
            throw MonadError("The VM service is from an older Monad and did not keep all of these settings. "
                + "It is updated once no VM is running. Stop the VMs, then save again.")
        }
    }

    func start(_ name: String) async throws {
        try await request(.start, name: name)
    }

    /// "Start VM at boot", once when Monad opens: the VMs marked for it that
    /// are not running (or being created) are started. Their names.
    @discardableResult
    func startMarkedVMs() async throws -> [String] {
        try await connected()
        var started: [String] = []
        for vm in instances where vm.config.startAtLaunch && !vm.config.ephemeral && !vm.isRunning && !vm.state.isPreparing {
            do {
                try await start(vm.name)
                started.append(vm.name)
            } catch {
                debug("start at boot: \(vm.name) did not start: \(error.localizedDescription)")
            }
        }
        debug("start at boot: \(started.isEmpty ? "nothing to start" : "started " + started.joined(separator: ", "))")
        return started
    }

    func stop(_ name: String, force: Bool = false) async throws {
        try await request(.stop, name: name, force: force ? true : nil)
    }

    /// Clean shutdown, then start: the VM picks up its saved settings.
    /// Sets up profiles in the running VM `name`.
    func runProfiles(_ name: String, _ ids: [String]) async throws {
        try await request(.runProfiles, name: name, profiles: ids)
    }

    /// Stops the profile being set up in VM `name` and drops the waiting ones.
    func stopProfiles(_ name: String) async throws {
        try await request(.stopProfiles, name: name)
    }

    /// VM `name`'s connection log, most recent first (empty unless it runs
    /// on a Monad network).
    func connections(_ name: String) async throws -> [NetConnection] {
        try await request(.connections, name: name).connections ?? []
    }

    /// Traffic between VMs on the Monad networks (the canvas's live edges).
    func traffic() async throws -> [VMTraffic] {
        try await request(.traffic).traffic ?? []
    }

    /// Answers a monitor-mode question of VM `name`.
    func answerFirewall(_ name: String, _ answer: FirewallAnswer) async throws {
        try await request(.answerFirewall, name: name, firewallAnswer: answer)
    }

    func restart(_ name: String) async throws {
        try await request(.restart, name: name)
    }

    /// A macOS VM's desktop, in a window MonadHost shows.
    func openDesktop(_ name: String) async throws {
        try await request(.openDesktop, name: name)
    }

    /// Repair Disk (it takes minutes): what it did.
    func repairDisk(_ name: String) async throws -> String {
        try await request(.repairDisk, name: name).message ?? ""
    }

    func delete(_ name: String) async throws {
        try await request(.delete, name: name)
        remove(name)
    }

    /// The VMs in `names` first, the others after them (the top one is the
    /// default VM until one is chosen with Make Default). Every app is told.
    func reorder(_ names: [String]) async throws {
        let before = order
        let listed = instances.filter { !$0.config.ephemeral }.map(\.name)
        setOrder(VMOrder.reordered(listed, requested: names))
        do {
            let r = try await request(.reorder, names: names)
            if let snapshots = r.instances { reconcile(snapshots, order: r.order) }
        } catch {
            setOrder(before)
            if hostIsOutdated {
                throw MonadError("The VM service is from an older Monad and cannot change the order of the VMs. "
                    + "It is updated once no VM is running.")
            }
            throw error
        }
    }

    /// Make Default: `name` opens first from now on (an older host knows
    /// the default only as the top of the order).
    func makeDefault(_ name: String) async throws {
        do {
            defaultName = try await request(.setDefault, name: name).defaultVM ?? name
            hostSaysDefault = true
        } catch {
            guard hostIsOutdated else { throw error }
            try await reorder([name])
        }
    }

    /// Move Up and Move Down in a row's menu.
    func move(_ name: String, by delta: Int) async throws {
        let listed = instances.filter { !$0.config.ephemeral }.map(\.name)
        let moved = VMOrder.step(listed, name, by: delta)
        guard moved != listed else { return }
        try await reorder(moved)
    }

    /// A drag in the Virtual Machines list (the persistent VMs, as listed).
    func move(from offsets: IndexSet, to destination: Int) async throws {
        let listed = instances.filter { !$0.config.ephemeral }.map(\.name)
        let moved = VMOrder.moving(listed, from: offsets, to: destination)
        guard moved != listed else { return }
        try await reorder(moved)
    }

    /// The user's answer to an agent's question.
    func answerApproval(_ id: UUID, _ answer: ApprovalAnswer) async throws {
        try await request(.answerApproval) {
            $0.approvalID = id
            $0.approvalAnswer = answer
        }
    }

    /// Settings › Agents: the "always allow" answers and the latest calls.
    func agentStatus() async throws -> (grants: [MCPGrants.Grant], audit: [String]) {
        let r = try await request(.agentStatus)
        return (r.grants ?? [], r.audit ?? [])
    }

    func revokeGrant(_ grant: MCPGrants.Grant) async throws -> [MCPGrants.Grant] {
        try await request(.revokeGrant) { $0.grant = grant }.grants ?? []
    }

    /// A macOS VM's setup step: its work folder, or why it did not run.
    func answerMacSetup(_ name: String, work: String?, error: String?) async throws {
        try await request(.answerMacSetup, name: name) {
            $0.macSetupWork = work
            $0.macSetupError = error
        }
    }

    // MARK: Canvas notes

    /// The host's notes, as far as they pass their checks.
    private func setNotes(_ list: [CanvasNote]) {
        let checked = Array(list.filter { (try? $0.validate()) != nil }.prefix(CanvasNote.maxNotes))
        if checked != notes { notes = checked }
    }

    func loadNotes() async throws {
        setNotes(try await request(.notes).notes ?? [])
    }

    func setNote(_ note: CanvasNote) async throws {
        setNotes(try await request(.setNote) { $0.note = note }.notes ?? [])
    }

    func removeNote(_ id: String) async throws {
        setNotes(try await request(.removeNote) { $0.noteID = id }.notes ?? [])
    }

    func stopAll() async throws {
        try await request(.stopAll)
    }

    /// Restarts an outdated host on the user's word: every VM stops, the host
    /// exits, and the new one is connected as on launch (launchd pointed at
    /// the new binary first). Tabs' VMs start again on it.
    func updateHost() async throws {
        guard hostIsOutdated else { return }
        debug("restarting the VM service on request: every VM stops")
        try await request(.stopAll)
        guard let t = transport else { throw HostClientError.unavailable }
        let r = try await roundTrip(HostRequest(id: takeID(), op: .shutdown), on: t)
        guard r.ok else { throw MonadError(r.error ?? "The VM service could not restart.") }
        Log.host.notice("restarting MonadHost for an update")
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            await self.waitForReplacement()
            if let prepare = self.prepareHostLaunch { await prepare() }
            await self.connectLoop()
        }
    }

    /// A tab starts using `name` (the host starts it if needed).
    func attach(_ name: String) async throws {
        attachments[name, default: 0] += 1
        do {
            try await request(.attach, name: name)
        } catch {
            detachLocally(name)
            throw error
        }
    }

    /// A tab stopped using `name`.
    func detach(_ name: String) async throws {
        guard detachLocally(name) else { return }
        guard status == .connected else { return } // the host already dropped our sessions
        try await request(.detach, name: name)
    }

    @discardableResult
    private func detachLocally(_ name: String) -> Bool {
        guard let n = attachments[name], n > 0 else { return false }
        attachments[name] = n == 1 ? nil : n - 1
        return true
    }
}
