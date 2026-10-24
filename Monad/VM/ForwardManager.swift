//
//  ForwardManager.swift — keeps a VM's port and socket forwards on its ssh
//  ControlMaster in line with what should exist: the configured rules plus
//  Lima-style auto-forwards of ports the guest listens on. Event-driven: it
//  reconciles when the config or the guest's ports change, and when the
//  master process exits (watched with kqueue), it restarts the master and
//  restores every forward.
//

import Foundation
import os

// MARK: - Status

struct ForwardStatus: Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable {
        case configured, auto, bridge
    }

    enum State: Equatable, Sendable {
        case active
        case failed(String)
    }

    let flag: String
    let spec: String
    let origin: Origin
    var state: State
}

extension ForwardStatus.State: Codable {
    private enum Keys: String, CodingKey { case state, reason }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .state) {
        case "active": self = .active
        case "failed": self = .failed(try c.decode(String.self, forKey: .reason))
        default: throw DecodingError.dataCorruptedError(forKey: .state, in: c, debugDescription: "unknown forward state")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .active: try c.encode("active", forKey: .state)
        case .failed(let reason):
            try c.encode("failed", forKey: .state)
            try c.encode(reason, forKey: .reason)
        }
    }
}

// MARK: - What should exist

struct ForwardPlan: Equatable {
    struct Forward: Equatable {
        let spec: SSHMux.Spec
        let origin: ForwardStatus.Origin
        /// The TCP port it listens on on the Mac, if any.
        var macPort: Int? = nil
    }

    let forwards: [Forward]
    /// Guest ports not forwarded because of `maxAutoForwards`.
    let overLimit: Int

    /// A guest can listen on thousands of ports: forward the lowest few.
    static let maxAutoForwards = 32

    /// A stdio bridge's remote forward (Phase 12), and its port in the VM.
    struct Bridge: Equatable {
        let spec: SSHMux.Spec
        let guestPort: Int?
    }

    init(configured: [ForwardRule], autoForward: AutoForwardSettings, ports: Set<ListeningPort>, bridges: [Bridge] = []) {
        var out: [Forward] = []
        var overLimit = 0
        var hostBindings = Set<String>()
        // Ports sshd listens on in the guest for forwards into the Mac and
        // bridges: forwarded back, they would put a Mac service or command
        // on a TCP port of the Mac.
        var intoTheMac = Set<Int>()
        for rule in configured where rule.enabled {
            let macPort = rule.kind == .local || rule.kind == .socks ? rule.hostPort : nil
            out.append(Forward(spec: SSHMux.spec(rule), origin: .configured, macPort: macPort))
            if rule.bindsOnHost, let p = rule.hostPort { hostBindings.insert("\(rule.hostAddress):\(p)") }
            if rule.kind == .remote, let p = rule.guestPort { intoTheMac.insert(p) }
        }
        for bridge in bridges {
            out.append(Forward(spec: bridge.spec, origin: .bridge))
            if let p = bridge.guestPort { intoTheMac.insert(p) }
        }
        let firstAuto = out.count
        if autoForward.enabled {
            let byPort = Dictionary(grouping: ports) { $0.port }
            for (port, listeners) in byPort.sorted(by: { $0.key < $1.key }) {
                guard port >= autoForward.minimumPort, port <= 65535, !autoForward.ignoredPorts.contains(port),
                      !intoTheMac.contains(port), let target = Self.guestTarget(listeners) else { continue }
                // A configured rule already owning this Mac port wins.
                if hostBindings.contains("127.0.0.1:\(port)") || hostBindings.contains("0.0.0.0:\(port)") { continue }
                if out.count - firstAuto >= Self.maxAutoForwards {
                    overLimit += 1
                    continue
                }
                let rule = ForwardRule(kind: .local, hostAddress: "127.0.0.1", hostPort: port, guestHost: target,
                                       guestPort: port)
                out.append(Forward(spec: SSHMux.spec(rule), origin: .auto, macPort: port))
            }
        }
        forwards = out
        self.overLimit = overLimit
    }

    /// Where, inside the guest, a port reachable from localhost is served:
    /// only wildcard and loopback listeners are auto-forwarded.
    private static func guestTarget(_ listeners: [ListeningPort]) -> String? {
        let addresses = Set(listeners.map(\.address))
        if addresses.contains("0.0.0.0") { return "127.0.0.1" }
        if let v4 = listeners.first(where: { $0.isLoopback && !$0.address.contains(":") }) { return v4.address }
        if addresses.contains("::") || addresses.contains("::1") { return "::1" }
        return nil
    }
}

// MARK: - Process supervision

/// Cancels a watch when asked or when released.
final class ProcessWatch {
    private var onCancel: (() -> Void)?

    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }

    func cancel() {
        onCancel?()
        onCancel = nil
    }

    deinit { onCancel?() }
}

@MainActor
protocol ProcessExitWatching {
    func watch(pid: Int32, onExit: @escaping @MainActor () -> Void) -> ProcessWatch
}

/// kqueue (EVFILT_PROC) through a dispatch source; no polling.
struct KqueueProcessWatcher: ProcessExitWatching {
    func watch(pid: Int32, onExit: @escaping @MainActor () -> Void) -> ProcessWatch {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler {
            source.cancel()
            MainActor.assumeIsolated { onExit() }
        }
        source.resume()
        // The process may already be gone; kqueue would then never fire.
        if kill(pid, 0) != 0 && errno == ESRCH {
            source.cancel()
            DispatchQueue.main.async { MainActor.assumeIsolated { onExit() } }
        }
        return ProcessWatch { source.cancel() }
    }
}

// MARK: - Manager

@MainActor
final class ForwardManager {
    private(set) var statuses: [ForwardStatus] = []
    var onChange: ((_ statuses: [ForwardStatus], _ overLimit: Int) -> Void)?
    /// Guest ports not forwarded because of `ForwardPlan.maxAutoForwards`.
    private(set) var overLimit = 0

    private let mux: SSHMux
    private let runner: CommandRunning
    private let watcher: ProcessExitWatching
    private let clock: MonadClock
    private var plan: ForwardPlan?
    private var active: [SSHMux.Spec: ForwardStatus.Origin] = [:]
    private var failures: [SSHMux.Spec: String] = [:]
    private var masterPID: Int32?
    private var masterStartedAt: Date?
    /// Grows while masters keep dying young, so a broken guest does not
    /// make us spawn ssh in a loop.
    private var restartDelay: TimeInterval = 0
    private var watch: ProcessWatch?
    private var running = false
    private var rerun = false
    private var stopped = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastReconcile: Date?
    /// A reconciliation for guest port events, waiting out the interval.
    private var heldBack: Task<Void, Never>?

    /// A master that ran at least this long was healthy.
    static let healthyMasterAge: TimeInterval = 30
    static let maxRestartDelay: TimeInterval = 60
    /// A guest opening and closing ports quickly must not keep MonadHost
    /// running ssh: its port events reconcile at most this often.
    static let guestEventInterval: TimeInterval = 1

    private let debugLog: DebugLog
    private let debugScope: String

    /// The VM whose forwards these are (its master is named after it when
    /// it holds a port another VM wants).
    private let vmName: String?

    /// Each running ssh master by pid, with its VM: a Mac port held by one
    /// is "in use by the virtual machine <name>", not by "ssh".
    private static var masters: [Int32: String] = [:]
    static func masterVM(pid: Int32) -> String? { masters[pid] }
    static func forgetMasters() { masters = [:] }

    init(mux: SSHMux, runner: CommandRunning, watcher: ProcessExitWatching? = nil, clock: MonadClock = SystemClock(),
         debugLog: DebugLog = .shared, debugScope: String = "forwards", vmName: String? = nil) {
        self.vmName = vmName
        self.mux = mux
        self.runner = runner
        self.watcher = watcher ?? KqueueProcessWatcher()
        self.clock = clock
        self.debugLog = debugLog
        self.debugScope = debugScope
    }

    /// Settings › Logs.
    private func debug(_ message: @autoclosure () -> String) {
        debugLog.log(debugScope, "forwards: " + message())
    }

    /// Make the master's forwards match the rules and the guest's ports.
    /// A `guestEvent` (the guest's ports changed) reconciles at most once
    /// per `guestEventInterval`, with the newest plan.
    func apply(configured: [ForwardRule], autoForward: AutoForwardSettings, ports: Set<ListeningPort>,
               bridges: [ForwardPlan.Bridge] = [], guestEvent: Bool = false) async {
        guard !stopped else { return }
        plan = ForwardPlan(configured: configured, autoForward: autoForward, ports: ports, bridges: bridges)
        if guestEvent, let last = lastReconcile {
            let wait = Self.guestEventInterval - clock.now().timeIntervalSince(last)
            if wait > 0 {
                if heldBack == nil {
                    debug("guest ports changed again within \(Self.guestEventInterval) s, applied in \(String(format: "%.1f", wait)) s")
                    let clock = self.clock
                    heldBack = Task { @MainActor [weak self] in
                        await clock.sleep(seconds: wait)
                        guard let self, !Task.isCancelled else { return }
                        self.heldBack = nil
                        await self.reconcileSerially()
                    }
                }
                return
            }
        }
        await reconcileSerially()
    }

    /// The VM stopped: forget forwards (the master goes with it).
    func stop() {
        stopped = true
        heldBack?.cancel()
        heldBack = nil
        watch?.cancel()
        watch = nil
        if let pid = masterPID { Self.masters[pid] = nil }
        masterPID = nil
        active = [:]
        failures = [:]
        publish([], overLimit: 0)
    }

    // MARK: Reconciliation

    /// One reconciliation at a time; requests during a run cause one more.
    private func reconcileSerially() async {
        if running {
            rerun = true
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        running = true
        repeat {
            rerun = false
            lastReconcile = clock.now()
            await reconcile()
        } while rerun && !stopped
        running = false
        let done = waiters
        waiters.removeAll()
        for w in done { w.resume() }
    }

    private func reconcile() async {
        guard let plan, !stopped else { return }
        if plan.forwards.isEmpty && active.isEmpty && masterPID == nil {
            publish([], overLimit: plan.overLimit)
            return
        }
        guard let pid = await ensureMaster() else {
            active = [:]
            let reason = "The SSH connection to the VM is not available (\(masterLogTail()))."
            debug("no ssh master: \(masterLogTail())")
            for f in plan.forwards { failures[f.spec] = reason }
            publish(plan)
            return
        }
        if pid != masterPID {
            debug("ssh master \(pid) is up")
            // A new master has no forwards.
            active = [:]
            if let old = masterPID { Self.masters[old] = nil }
            masterPID = pid
            if let vmName { Self.masters[pid] = vmName }
            masterStartedAt = clock.now()
            watch?.cancel()
            watch = watcher.watch(pid: pid) { [weak self] in self?.masterExited(pid) }
        }
        let wanted = Set(plan.forwards.map(\.spec))
        for spec in active.keys where !wanted.contains(spec) {
            _ = try? await runner.run("/usr/bin/ssh", mux.cancel(spec), timeout: 15)
            debug("removed \(spec.flag) \(spec.value)")
            active[spec] = nil
        }
        failures = failures.filter { wanted.contains($0.key) }
        // ssh binds 127.0.0.1 even next to a Mac server listening on all
        // addresses, and would then take the Mac's localhost traffic for
        // that port: an auto-forward never goes where a Mac program listens.
        let newAuto = plan.forwards.filter { $0.origin == .auto && active[$0.spec] == nil }.compactMap(\.macPort)
        let macListeners = newAuto.isEmpty ? [:] : await programs(listeningOn: newAuto)
        for f in plan.forwards where active[f.spec] == nil {
            guard !stopped else { return }
            if f.origin == .auto, let port = f.macPort, let holders = macListeners[port] {
                failures[f.spec] = Self.inUse(port, by: holders)
                debug("\(f.spec.flag) \(f.spec.value) skipped: \(failures[f.spec] ?? "")")
                continue
            }
            let r = try? await runner.run("/usr/bin/ssh", mux.add(f.spec), timeout: 15)
            if let r, r.status == 0 {
                debug("added \(f.spec.flag) \(f.spec.value) (\(f.origin))")
                active[f.spec] = f.origin
                failures[f.spec] = nil
            } else {
                // ssh only says "Port forwarding failed."; name what holds the port.
                var holders: [String] = []
                if let port = f.macPort { holders = await programs(listeningOn: [port])[port] ?? [] }
                if let port = f.macPort, !holders.isEmpty {
                    failures[f.spec] = Self.inUse(port, by: holders)
                } else {
                    failures[f.spec] = r.map(Self.reason) ?? "ssh did not answer"
                }
                Log.vm.notice("forward \(f.spec.flag, privacy: .public) \(f.spec.value, privacy: .public) failed: \(self.failures[f.spec] ?? "", privacy: .public)")
                debug("\(f.spec.flag) \(f.spec.value) failed: \(failures[f.spec] ?? "")")
            }
        }
        publish(plan)
    }

    /// ssh appends to its -E log forever; set it aside once it is large.
    static let masterLogLimit = 1 << 20

    private func ensureMaster() async -> Int32? {
        if let pid = await checkMaster() { return pid }
        // No master answers: a socket file left behind is stale. ssh would
        // otherwise start as a plain connection ("disabling multiplexing")
        // and never be a master.
        try? FileManager.default.removeItem(at: mux.paths.controlSocket)
        let log = mux.masterLog
        if let size = (try? FileManager.default.attributesOfItem(atPath: log.path))?[.size] as? NSNumber,
           size.intValue > Self.masterLogLimit {
            let old = log.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: log, to: old)
        }
        let start = mux.startMaster
        _ = try? await runner.run(start.executable, start.arguments, timeout: 60)
        return await checkMaster()
    }

    private func checkMaster() async -> Int32? {
        guard let r = try? await runner.run("/usr/bin/ssh", mux.check, timeout: 10), r.status == 0 else { return nil }
        return SSHMux.masterPID(fromCheckOutput: r.stderrString + r.stdoutString)
    }

    /// Programs listening on these Mac TCP ports on any address, per lsof
    /// (only ports something listens on are keys).
    private func programs(listeningOn ports: [Int]) async -> [Int: [String]] {
        guard let r = try? await runner.run("/usr/sbin/lsof", ["-nP", "-iTCP:" + ports.map(String.init).joined(separator: ","),
                                                                "-sTCP:LISTEN", "-Fcn"], timeout: 10),
              r.status == 0 else { return [:] }
        return Self.listeners(fromLsof: r.stdoutString)
    }

    /// lsof -Fcn: "p" starts a process, "c" names it (a Monad VM's ssh
    /// master is named after its VM), each "n" after it is a socket
    /// ("*:8080", "127.0.0.1:8080", "[::1]:8080").
    static func listeners(fromLsof output: String) -> [Int: [String]] {
        var out: [Int: [String]] = [:]
        var name = "another program"
        var vm: String?
        for line in output.split(whereSeparator: \.isNewline) {
            switch line.first {
            case "p":
                name = "another program"
                vm = Int32(line.dropFirst()).flatMap { masters[$0] }
                if let vm { name = "the virtual machine \(vm)" }
            case "c": if vm == nil { name = String(line.dropFirst()) }
            case "n":
                guard let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]) else { continue }
                if !(out[port] ?? []).contains(name) { out[port, default: []].append(name) }
            default: continue
            }
        }
        return out
    }

    private static func inUse(_ port: Int, by holders: [String]) -> String {
        "Port \(port) on this Mac is already in use by \(holders.joined(separator: ", "))."
    }

    private func masterExited(_ pid: Int32) {
        guard !stopped, pid == masterPID else { return }
        let lived = masterStartedAt.map { clock.now().timeIntervalSince($0) } ?? Self.healthyMasterAge
        restartDelay = lived < Self.healthyMasterAge ? min(max(restartDelay * 2, 1), Self.maxRestartDelay) : 0
        let delay = restartDelay
        Log.vm.notice("ssh master \(pid) exited after \(Int(lived)) s; restoring forwards in \(Int(delay)) s")
        debug("ssh master \(pid) exited after \(Int(lived)) s, restoring forwards in \(Int(delay)) s (\(masterLogTail()))")
        if let pid = masterPID { Self.masters[pid] = nil }
        masterPID = nil
        masterStartedAt = nil
        active = [:]
        watch = nil
        let clock = self.clock
        Task { @MainActor [weak self] in
            if delay > 0 { await clock.sleep(seconds: delay) }
            guard let self, !self.stopped else { return }
            await self.reconcileSerially()
        }
    }

    // MARK: Status

    private func publish(_ plan: ForwardPlan) {
        publish(plan.forwards.map { f in
            ForwardStatus(flag: f.spec.flag, spec: f.spec.value, origin: f.origin,
                          state: active[f.spec] != nil ? .active : .failed(failures[f.spec] ?? "Not set up yet."))
        }, overLimit: plan.overLimit)
    }

    private func publish(_ new: [ForwardStatus], overLimit: Int) {
        guard new != statuses || overLimit != self.overLimit else { return }
        if overLimit != self.overLimit, overLimit > 0 {
            debug("\(DebugLog.count(overLimit, "guest port")) not forwarded (at most \(ForwardPlan.maxAutoForwards))")
        }
        statuses = new
        self.overLimit = overLimit
        onChange?(new, overLimit)
    }

    /// Last non-empty line of ssh's output: its actual complaint.
    private static func reason(_ r: ProcessRunner.Result) -> String {
        let text = (r.stderrString + "\n" + r.stdoutString)
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? "ssh exited with status \(r.status)"
    }

    private func masterLogTail() -> String {
        guard let text = try? String(contentsOf: mux.masterLog, encoding: .utf8) else { return "no details" }
        return text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "no details"
    }
}
