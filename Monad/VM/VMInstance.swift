//
//  VMInstance.swift — runtime state machine of one VM.
//
//      stopped ─start─▶ starting ─▶ booting ─(sshd over vsock + isolation ok)─▶ ready
//         ▲                │           │                                          │
//         └──── stop ──────┴───────────┴──────────── stopping ◀──── stop ─────────┘
//      any state ─(start error / timeout / isolation failure / guest crash)─▶ failed
//

import Combine
import Foundation
import os

/// Wrapper for values handed to background queues that are only used there.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
}

@MainActor
final class VMInstance: ObservableObject, Identifiable {
    typealias State = VMState

    /// An agent connection that lasted this long was healthy.
    static let healthyAgentConnection: TimeInterval = 10

    /// How long a first boot may take before we give up.
    static let bootTimeout: TimeInterval = 15 * 60

    nonisolated let name: String
    let paths: InstancePaths
    @Published private(set) var config: InstanceConfig
    @Published private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            if case .preparing = state {
                Log.vm.debug("\(self.name, privacy: .public): \(self.state.label, privacy: .public)")
            } else {
                Log.vm.notice("\(self.name, privacy: .public): \(self.state.label, privacy: .public)")
            }
            // Download and install progress: logged each 10%.
            if case .preparing(let a) = oldValue, case .preparing(let b) = state,
               !Self.logsProgress(from: a, to: b) { return }
            debug("state \(oldValue.debugName) → \(state.debugName)")
            if diskLock != nil, state == .stopped || (state.isFailed && !poweringOff) {
                diskLock = nil
                debug("lima: lock released")
            }
        }
    }

    /// Whether the guest agent answered the per-boot install (port events, shares).
    @Published private(set) var agentAvailable = false

    /// TCP ports listening inside the guest, as reported by the agent.
    @Published private(set) var guestPorts: Set<ListeningPort> = [] {
        didSet { if guestPorts != oldValue { applyForwards(guestEvent: true) } }
    }

    /// Port and socket forwards on the VM's ssh master, with their status.
    @Published private(set) var forwards: [ForwardStatus] = []
    /// Guest ports not auto-forwarded because of `ForwardPlan.maxAutoForwards`.
    @Published private(set) var portsOverLimit = 0

    private var forwarding: ForwardManager?
    /// Held while the VM boots a Lima disk: no other Monad (the release or
    /// the debug build) boots or copies it meanwhile.
    private var diskLock: DiskLock?
    /// Set while `fail` powers the machine off, which still uses the disk.
    private var poweringOff = false

    /// Bridge servers running now, by bridge id (Phase 12).
    private var bridgeServers: [UUID: (bridge: CommandBridge, server: BridgeServing)] = [:]
    /// Monad's MCP endpoint while the VM has a role and is ready, and its port.
    private var mcpEndpoint: (server: MCPEndpointServing, port: Int)?
    private var discoveryTask: Task<Void, Never>?
    /// The agents in the guest Monad registered itself with (agents phase).
    @Published private(set) var mcpRegistered: [String] = []
    /// Host command servers running now, by command id (agents phase).
    private var hostCommandServers: [UUID: (command: HostCommand, server: HostCommandServing)] = [:]

    /// macOS: System Integrity Protection as found at the last boot, and
    /// why it is not as set after a change in recovery (Security page).
    @Published private(set) var macSecurity: MacSecurityReport?
    /// The VM booted into recoveryOS while SIP is changed.
    private var recoveryMachine: (VirtualMachineControlling & MacRecoveryInput)?

    /// Why shared folders are not all mounted in the guest; nil when they are.
    @Published private(set) var sharesError: String?
    /// Why the VM's firewall is not in force as saved (netd refused it, a
    /// tag is missing); nil when it is.
    @Published private(set) var firewallProblem: String?
    /// Folders the running virtio-fs share holds (the boot config's at first).
    private var hostShares: [SharedFolder] = []
    private var sharesTask: Task<Void, Never>?

    private var agent: AgentClient?
    private var agentTask: Task<Void, Never>?

    private let env: VMEnvironment
    private var machine: VirtualMachineControlling?
    /// The NIC `machine` was built with, on a Monad network.
    private var nic: NICAttachment?
    /// Profiles set up (or being set up) since the VM started, in run order.
    @Published private(set) var profileRuns: [ProfileRun] = []
    private var profileQueue: [String] = []
    private var profileTask: Task<Void, Never>?
    /// What a profile's script is run with in the guest (as root, from stdin,
    /// as its own session so Stop can end everything it started, -w for its
    /// status if setsid has to fork; the argument names it in ps and keeps
    /// it apart from the agent install).
    static let profileCommand = "sudo -n setsid -w sh -s monad-profile"
    /// The running profile script's process group in the guest, once it said.
    private var profilePID: Int?
    private var profileStopRequested = false
    /// The longest a profile may take.
    static let profileTimeout: TimeInterval = 3600

    /// Monitor mode: questions waiting for the user, oldest first.
    @Published private(set) var firewallAsks: [FirewallAsk] = []
    /// More are not kept (netd asks again later): a guest cannot pile them up.
    static let maxFirewallAsks = 32
    /// Getting a NIC from monad-netd before the machine can be built.
    private var attaching = false
    /// The settings `machine` was built with.
    private var machineConfig: InstanceConfig?
    private var lifecycleTask: Task<Void, Never>?

    nonisolated var id: String { name }
    var sshHost: String { config.sshHost }
    /// How Monad's ssh runs reach the VM: options on the command line, never
    /// ssh.config (which other processes of the user can rewrite).
    var sshOptions: [String] { CloudInit.sshArguments(config: config, paths: paths) }
    var isFailed: Bool { state.isFailed }
    var isRunning: Bool { state.isRunning }

    /// The other macOS VMs this Monad runs (set by VMManager), for Apple's
    /// limit of two at once.
    var otherMacOSVMsRunning: () -> [String] = { [] }

    /// Why the machine did not start, in plain words where Apple's are not.
    private func startProblem(_ error: Error) -> String {
        guard VZMachineFactory.isMacOSLimit(error) else { return error.localizedDescription }
        let running = otherMacOSVMsRunning()
        let which = running.count >= 2
            ? "\(running.dropLast().joined(separator: ", ")) and \(running.last!) are running"
            : running.isEmpty ? "two are running outside this Monad (the other Monad build, or another app)"
            : "\(running[0]) is running here and another outside this Monad (the other Monad build, or another app)"
        return "A Mac runs at most two macOS VMs at once, and \(which). Stop one of them, then start \(name)."
    }

    /// Saved settings the running VM only picks up when it restarts.
    var pendingRestart: [String] {
        guard isRunning, let machineConfig else { return [] }
        return ConfigChange.restartOnly(from: machineConfig, to: config)
    }

    /// The distro's guest profile; nil when the distro is unknown to this
    /// Monad (the VM then refuses to start rather than guess).
    let guest: DistroConfig.GuestProfile?
    /// This boot's report from the guest's console (Guest/monad-report.sh).
    private var guestReport = GuestReport()

    init(config: InstanceConfig, paths: InstancePaths, environment: VMEnvironment, guest: DistroConfig.GuestProfile?) {
        self.name = config.name
        self.paths = paths
        self.log = VMLog(url: paths.vmLog)
        self.config = config
        self.env = environment
        self.guest = guest
        if config.guestOS == .macos {
            macSecurity = MacSecurityReport(sip: recordedSIP.map(\.word), fullDiskAccess: recordedFullDiskAccess)
        }
    }

    /// This VM's own log, always on (its Log page).
    nonisolated let log: VMLog

    /// A line in this VM's log from what makes or runs it (VMManager).
    func note(_ message: String) { debug(message) }

    private static let markStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// The machine runs: say since when, until its stop event takes it away.
    private func writeRunningMark() {
        try? Data(Self.markStamp.string(from: env.clock.now()).utf8).write(to: paths.runningMark, options: .atomic)
    }

    /// At MonadHost's start: a mark left behind is a machine the last
    /// MonadHost never saw stop (killed, crashed, the Mac lost power), so the
    /// guest was powered off without a shutdown. Said once.
    func noteUncleanStop() {
        guard let data = try? Data(contentsOf: paths.runningMark) else { return }
        try? FileManager.default.removeItem(at: paths.runningMark)
        let started = String(decoding: data.prefix(32), as: UTF8.self).filter { $0.isNumber || " -:".contains($0) }
        debug("MonadHost ended while this VM was running (its machine started \(started.isEmpty ? "earlier" : started)): "
              + "it was powered off without a shutdown, which can damage its disk")
    }

    /// What this VM does, step by step: its own log, and Settings › Logs.
    private func debug(_ message: @autoclosure () -> String) {
        let text = message()
        log.log(text)
        env.debugLog.log("vm \(name)", text)
    }

    /// Why the saved settings were refused when loaded (changed outside
    /// Monad); the VM does not start until valid settings are saved.
    private var configProblem: String?

    func refuseConfig(_ problem: String) {
        configProblem = problem
        debug("settings refused: \(problem)")
        state = .failed(problem)
    }

    func setPreparing(_ message: String) { state = .preparing(message) }
    /// Whether going from one preparing message to the next is logged: a
    /// new step always, the same step (only its numbers differ) when its
    /// percent reaches the next ten.
    nonisolated static func logsProgress(from old: String, to new: String) -> Bool {
        guard old.filter({ !$0.isNumber }) == new.filter({ !$0.isNumber }) else { return true }
        func tens(_ s: String) -> Int? {
            guard let sign = s.firstIndex(of: "%") else { return nil }
            return Int(String(s[..<sign].reversed().prefix { $0.isNumber }.reversed())).map { $0 / 10 }
        }
        guard let a = tens(old), let b = tens(new) else { return false }
        return a != b
    }
    /// Progress while being made: a message that arrives late (after the
    /// creation ended or failed) changes nothing.
    func reportProgress(_ message: String) {
        if case .preparing = state { state = .preparing(message) }
    }
    func setFailed(_ message: String) { state = .failed(message) }

    /// It could not be made: listed with why (and its log) until it is
    /// deleted or made again by its name.
    private(set) var creationFailed = false
    func setCreationFailed(_ message: String) {
        creationFailed = true
        state = .failed(message)
    }

    /// Why the Lima VM this VM boots cannot be used now; nil when it can (or
    /// the VM has its own disk). Lima must not run it at the same time.
    func limaProblem(checkRunning: Bool) -> String? {
        guard let attached = config.attached else { return nil }
        let dir = URL(fileURLWithPath: attached.dir, isDirectory: true)
        do {
            try LimaDisk.check(dir: dir)
        } catch {
            return "The Lima VM “\(attached.instance)” is gone or can no longer be used. \(error.localizedDescription) "
                + "Remove this VM from Monad, or bring the Lima VM back."
        }
        if checkRunning, LimaDisk.isRunning(dir: dir) {
            return "Lima is running “\(attached.instance)”. Stop it first with limactl stop \(attached.instance)."
        }
        return nil
    }
    func setStopped() { state = .stopped }

    /// Config as written by provisioning (records the base image used).
    func setProvisionedConfig(_ c: InstanceConfig) { config = c }

    /// Save new settings. Forwards apply at once; hardware changes wait for
    /// the next boot (see `pendingRestart`).
    func update(_ newConfig: InstanceConfig) throws {
        let changes = ConfigChange.all(from: config, to: newConfig)
        debug("update while \(state.debugName): \(changes.isEmpty ? "nothing changed" : changes.joined(separator: ", "))")
        guard !state.isPreparing else {
            // Provisioning writes the final config when it ends.
            debug("update refused: the VM is still being created")
            throw MonadError("The VM is still being created. Change its settings once it is ready.")
        }
        let fixed = ConfigChange.fixed(from: config, to: newConfig)
        guard fixed.isEmpty else {
            debug("update refused: fixed settings changed: \(fixed.joined(separator: ", "))")
            throw MonadError("These settings are fixed when the VM is created: \(fixed.joined(separator: ", ")).")
        }
        let old = config
        if newConfig.sharing.shares != old.sharing.shares {
            for share in newConfig.sharing.shares {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: share.hostPath, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    debug("update refused: the Mac folder \(share.hostPath) does not exist")
                    throw MonadError("The Mac folder \(share.hostPath) does not exist.")
                }
            }
        }
        do {
            try newConfig.save(to: paths.config)
        } catch {
            debug("update failed: cannot save \(paths.config.path): \(error.localizedDescription)")
            throw error
        }
        config = newConfig
        configProblem = nil // saved through Monad: validated by MonadHost
        if !pendingRestart.isEmpty { debug("applies after a restart: \(pendingRestart.joined(separator: ", "))") }
        if newConfig.effectiveFirewall != old.effectiveFirewall {
            if let nic {
                // Live: the machine keeps its NIC, so it is not rebuilt for this.
                debug("firewall: sent to netd, in force at once")
                nic.setFirewall(newConfig.effectiveFirewall)
                machineConfig?.firewall = newConfig.firewall
            } else {
                debug("firewall: saved, no Monad network NIC to send it to now")
            }
        }
        if newConfig.bridges != old.bridges { applyBridges() }
        if newConfig.hostCommands != old.hostCommands { applyHostCommands() }
        if newConfig.agents != old.agents { applyAgents() } else if newConfig.bridges != old.bridges
            || newConfig.hostCommands != old.hostCommands { refreshDiscovery() }
        applyForwards()
        if isRunning, newConfig.memoryTargetGiB != old.memoryTargetGiB { applyMemoryTarget() }
        let addedProfiles = Set(newConfig.profiles).subtracting(old.profiles)
        if state == .ready, !addedProfiles.isEmpty {
            debug("profiles: added \(addedProfiles.sorted().joined(separator: ", ")), setting up what is not yet")
            runPendingProfiles()
        }
        if newConfig.sharing.shares != old.sharing.shares { applyShares() }
    }

    /// The balloon target: the configured one (or all boot memory), never
    /// more than the running machine was built with.
    private func applyMemoryTarget() {
        guard let machine, let built = machineConfig else {
            debug("memory: no machine to set a balloon target on")
            return
        }
        let gib = min(config.memoryTargetGiB ?? built.memoryGiB, built.memoryGiB)
        debug("memory: balloon target \(gib) GiB")
        machine.setMemoryTarget(bytes: UInt64(gib) << 30)
    }

    // MARK: Start

    func start() {
        switch state {
        case .stopped, .failed: break
        default: return
        }
        if let configProblem {
            state = .failed(configProblem)
            return
        }
        guard env.virtualizationSupported else {
            state = .failed("Virtualization is not supported on this Mac.")
            return
        }
        guard guest != nil else {
            state = .failed("This Monad does not know the distribution \(config.distro).")
            return
        }
        if config.guestOS == .macos, !FileManager.default.fileExists(atPath: paths.macSetupDone.path) {
            state = .failed("This macOS VM is installed but not set up yet: Monad has not put its account and its way in on it.")
            return
        }
        if let problem = limaProblem(checkRunning: true) {
            state = .failed(problem)
            return
        }
        if let on = fullDiskAccessChange {
            changeFullDiskAccess(on: on)
            return
        }
        if config.bootToRecovery, config.guestOS == .macos {
            startInRecoveryForTheUser()
            return
        }
        if let on = sipChange {
            startInRecovery(sip: on)
            return
        }
        if let attached = config.attached, diskLock == nil {
            do {
                guard let lock = try DiskLock.take(LimaDisk.lockFile(in: URL(fileURLWithPath: attached.dir))) else {
                    state = .failed("Another Monad (the release or the debug build) is running the Lima VM "
                                    + "“\(attached.instance)”. Shut it down there first.")
                    return
                }
                diskLock = lock
                debug("lima: lock taken")
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
        }
        if config.attached != nil {
            // Lima may have changed the guest's host keys since Monad last ran it.
            try? FileManager.default.removeItem(at: paths.knownHosts)
        }
        let spent = machine.map { !$0.canStart } ?? false
        let rebuild = machine == nil || machineConfig != config || spent
        debug(machine == nil ? "start: building the machine"
              : spent ? "start: rebuilding the machine (the last one cannot start again)"
              : rebuild ? "start: rebuilding the machine (settings changed: \(ConfigChange.all(from: machineConfig ?? config, to: config).joined(separator: ", ")))"
              : "start: reusing the machine")
        if rebuild, let first = config.networks.first, !first.isAppleNAT {
            // The NIC comes from monad-netd, which answers asynchronously.
            state = .starting
            attaching = true
            lifecycleTask = Task { [weak self] in await self?.attachAndBoot() }
            return
        }
        let m: VirtualMachineControlling
        do {
            // Reused only as built: stopped VMs pick up every change.
            if let existing = machine, !rebuild {
                m = existing
            } else {
                if config.sharing.runtimeEnabled { try Self.makeExchange(paths) }
                m = try makeMachine(nic: nil)
                m.onEvent = { [weak self] event in self?.handle(event) }
                replaceMachine(m, nic: nil)
            }
            hostShares = machineConfig?.deviceShares(paths: paths) ?? []
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        state = .starting
        lifecycleTask = Task { [weak self] in await self?.boot(m) }
    }

    /// A new machine on a Monad network: its MAC first (netd binds the port to
    /// it), then the NIC, then the machine, then the usual boot.
    private func attachAndBoot() async {
        defer { attaching = false }
        guard let attacher = env.networks else {
            state = .failed("Monad networks are not available, so “\(config.networks[0].network)” cannot be used.")
            return
        }
        giveMACAddress()
        let network = config.networks[0].network
        let attachment: NICAttachment
        debug("network: asking netd for a NIC on \(network) with MAC \(config.networks[0].macAddress ?? "?")")
        do {
            attachment = try await attacher.attach(vm: name, network: network, mac: config.networks[0].macAddress ?? "",
                                                   firewall: config.effectiveFirewall)
        } catch {
            debug("network: netd refused: \(error.localizedDescription)")
            if state == .starting { state = .failed("The network “\(network)” is not available: \(error.localizedDescription)") }
            return
        }
        debug("network: NIC attached")
        guard state == .starting, !Task.isCancelled else {
            attachment.detach()
            return
        }
        let m: VirtualMachineControlling
        do {
            if config.sharing.runtimeEnabled { try Self.makeExchange(paths) }
            m = try makeMachine(nic: attachment.handle)
        } catch {
            attachment.detach()
            state = .failed(error.localizedDescription)
            return
        }
        m.onEvent = { [weak self] event in self?.handle(event) }
        attachment.onAsk = { [weak self] in self?.received($0) }
        attachment.onFirewallProblem = { [weak self] problem in
            guard let self, self.firewallProblem != problem else { return }
            self.firewallProblem = problem
            if let problem { self.debug("firewall: \(problem)") }
        }
        replaceMachine(m, nic: attachment)
        hostShares = machineConfig?.deviceShares(paths: paths) ?? []
        await boot(m)
    }

    /// netd binds a VM's port to its MAC address: one is made and kept
    /// the first time the VM joins a Monad network.
    private func giveMACAddress() {
        guard !config.networks.isEmpty, config.networks[0].macAddress == nil else { return }
        var c = config
        c.networks[0].macAddress = NetworkAttachment.randomMAC()
        try? c.save(to: paths.config)
        config = c
    }

    // MARK: Full disk access (macOS)

    /// Whether the VM's disk gives full disk access (a VM made before this
    /// was recorded was given it).
    private var recordedFullDiskAccess: Bool {
        (try? String(contentsOf: paths.macFullDiskAccess, encoding: .utf8)) != "off"
    }

    private var fullDiskAccessChange: Bool? {
        guard config.guestOS == .macos, config.fullDiskAccess != recordedFullDiskAccess else { return nil }
        return config.fullDiskAccess
    }

    /// Made: what its disk was given.
    func setFullDiskAccessFound(_ on: Bool) {
        macSecurity = MacSecurityReport(sip: macSecurity?.sip, problem: macSecurity?.problem, fullDiskAccess: on)
    }

    /// Written into the stopped VM's disk before macOS boots, then the start goes on.
    private func changeFullDiskAccess(on: Bool) {
        beginStartStep(on ? "Giving Monad's sessions full disk access…" : "Taking full disk access away from Monad's sessions…")
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            self.debug("full disk access: turning it \(on ? "on" : "off") in the VM's disk")
            var report = self.macSecurity ?? MacSecurityReport()
            do {
                try await MacSetup.setFullDiskAccess(on, disk: self.paths.disk, runner: self.env.runner)
                try? Data((on ? "on" : "off").utf8).write(to: self.paths.macFullDiskAccess, options: .atomic)
                report.fullDiskAccess = on
                report.accessProblem = nil
            } catch {
                self.debug("full disk access: not changed: \(error.localizedDescription)")
                report.accessProblem = "Monad could not change full disk access: \(error.localizedDescription)"
                report.fullDiskAccess = !on
                self.undoSecurityChange { $0.fullDiskAccess = !on }
            }
            report.step = self.macSecurity?.step
            self.macSecurity = report
            self.continueStart()
        }
    }

    // MARK: System Integrity Protection (macOS)

    /// SIP as found at the last boot (none yet: as installed, on).
    private var recordedSIP: MacRecovery.Status? {
        guard config.guestOS == .macos else { return nil }
        guard let word = try? String(contentsOf: paths.macSIPStatus, encoding: .utf8) else { return .enabled }
        return MacRecovery.status(from: "status: " + word)
    }

    /// Whether this start changes SIP first (true: on): it is not as set,
    /// and the VM is not just back from recovery with that change.
    private var sipChange: Bool? {
        guard config.guestOS == .macos, let found = recordedSIP else { return nil }
        let on = config.systemIntegrityProtection
        guard found != (on ? .enabled : .disabled) else { return nil }
        // Back from recovery, the boot after says whether it took.
        let tried = try? String(contentsOf: paths.macSIPAttempt, encoding: .utf8)
        return tried == (on ? "on" : "off") ? nil : on
    }

    /// Boot to Recovery, once: the switch goes off as it is used.
    private func startInRecoveryForTheUser() {
        var c = config
        c.bootToRecovery = false
        try? c.save(to: paths.config)
        config = c
        beginStartStep("In recovery: use its desktop (⋯ › Open macOS Desktop). Restarting or shutting down there starts macOS.")
        lifecycleTask = Task { [weak self] in await self?.recoveryForTheUser() }
    }

    private func startInRecovery(sip on: Bool) {
        beginStartStep("Turning System Integrity Protection \(on ? "on" : "off") in recovery (a few minutes)…")
        lifecycleTask = Task { [weak self] in await self?.changeSIPInRecovery(on: on) }
    }

    /// A step before macOS starts, part of starting: the VM can be grouped,
    /// edited and shut down meanwhile; the Security page says what it is.
    private func beginStartStep(_ what: String) {
        state = .starting
        var report = macSecurity ?? MacSecurityReport()
        report.step = what
        macSecurity = report
    }

    private func endStartStep() {
        macSecurity?.step = nil
    }

    /// Back from a step: macOS starts, unless the VM was shut down meanwhile.
    private func continueStart() {
        guard !Task.isCancelled, state == .starting else { return }
        endStartStep()
        state = .stopped
        start()
    }

    /// Recovery's machine: a display, a keyboard and a pointer, on the VM's
    /// own network (turning SIP on asks Apple), no shared folders. Its NIC
    /// goes into `attachment` for the caller to detach.
    private func makeRecovery(_ attachment: inout NICAttachment?) async throws -> VirtualMachineControlling & MacRecoveryInput {
        if let first = config.networks.first, !first.isAppleNAT {
            guard let attacher = env.networks else { throw MonadError("Monad networks are not available.") }
            giveMACAddress()
            attachment = try await attacher.attach(vm: name, network: first.network, mac: config.networks[0].macAddress ?? "",
                                                   firewall: config.effectiveFirewall)
        }
        var c = config
        c.sharing = SharingSettings()
        let m = try env.machines.makeRecoveryMachine(config: c, paths: paths, nic: attachment?.handle)
        recoveryMachine = m
        return m
    }

    /// The user's recovery: its desktop opens, nothing is typed; when the
    /// user leaves it (Virtualization stops a VM that restarts), macOS starts.
    private func recoveryForTheUser() async {
        debug("recovery: booting it for the user")
        var attachment: NICAttachment?
        defer {
            attachment?.detach()
            recoveryMachine = nil
        }
        do {
            let m = try await makeRecovery(&attachment)
            var stopped = false
            m.onEvent = { _ in stopped = true }
            try await m.start()
            do { try openDesktop() } catch { debug("recovery: desktop not opened: \(error.localizedDescription)") }
            while !stopped, !Task.isCancelled { await env.clock.sleep(seconds: 1) }
            guard !Task.isCancelled, state == .starting else { return }
        } catch {
            guard !Task.isCancelled, state == .starting else { return }
            debug("recovery: failed: \(error.localizedDescription)")
            await recoveryMachine?.forceStop()
            endStartStep()
            state = .failed(VZMachineFactory.isMacOSLimit(error) ? startProblem(error)
                            : "Monad could not start this VM in recovery: " + error.localizedDescription)
            return
        }
        debug("recovery: left, starting macOS")
        continueStart()
    }

    /// SIP changed in recovery: the steps typed; then it shuts down (or is
    /// powered off) and starts as usual.
    private func changeSIPInRecovery(on: Bool) async {
        debug("sip: turning it \(on ? "on" : "off") in recovery")
        var attachment: NICAttachment?
        defer {
            attachment?.detach()
            recoveryMachine = nil
        }
        do {
            let m = try await makeRecovery(&attachment)
            var stopped = false
            m.onEvent = { _ in stopped = true }
            let steps = MacRecovery.steps(sip: on)
            let headline = "Turning System Integrity Protection \(on ? "on" : "off") in recovery"
            func say(_ what: String) {
                debug("sip: \(what)")
                macSecurity?.step = "\(headline): \(what)…"
            }
            say("starting recovery (step 1 of \(MacRecovery.stepCount(steps)))")
            try await m.start()
            // Its screen read from now (the reader's view takes a moment to be drawn), and its desktop watch only.
            _ = await m.screen()
            let password = (try? String(contentsOf: paths.macPassword, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let screens = paths.recoveryScreens
            try? FileManager.default.removeItem(at: screens)
            try? FileManager.default.createDirectory(at: screens, withIntermediateDirectories: true)
            try await MacRecovery.run(steps, on: m, password: password, clock: env.clock, say: say,
                                     log: { [weak self] in self?.debug("sip: \($0)") },
                                     keep: { try? $1.write(to: screens.appendingPathComponent("\($0).png")) })
            let deadline = env.clock.now().addingTimeInterval(MacRecovery.shutdownTimeout)
            while !stopped, env.clock.now() < deadline, !Task.isCancelled { await env.clock.sleep(seconds: 1) }
            guard !Task.isCancelled, state == .starting else { return }
            if !stopped {
                debug("sip: recovery did not shut down, powering it off")
                await m.forceStop()
            }
        } catch {
            guard !Task.isCancelled, state == .starting else { return }
            debug("sip: recovery failed: \(error.localizedDescription)")
            await recoveryMachine?.forceStop()
            endStartStep()
            state = .failed(VZMachineFactory.isMacOSLimit(error) ? startProblem(error)
                            : "Monad could not start this VM in recovery to change System Integrity Protection: "
                            + error.localizedDescription)
            return
        }
        debug("sip: recovery done, starting macOS")
        try? Data((on ? "on" : "off").utf8).write(to: paths.macSIPAttempt, options: .atomic)
        continueStart()
    }

    /// Reads SIP in the booted VM; a change that did not take is shown.
    private func checkSIP() {
        Task { [weak self] in
            guard let self else { return }
            guard let r = try? await self.sshSteadily(MacRecovery.statusCommand, timeout: 30), r.status == 0 else {
                self.debug("sip: csrutil status did not answer")
                return
            }
            let found = MacRecovery.status(from: r.stdoutString)
            self.debug("sip: \(found.word)")
            try? Data(found.word.utf8).write(to: self.paths.macSIPStatus, options: .atomic)
            let on = self.config.systemIntegrityProtection
            let attempted = FileManager.default.fileExists(atPath: self.paths.macSIPAttempt.path)
            try? FileManager.default.removeItem(at: self.paths.macSIPAttempt)
            var problem: String?
            if found != (on ? .enabled : .disabled), attempted {
                problem = on
                    ? "Monad could not turn System Integrity Protection back on in recovery, so it is still off. It needs "
                        + "the internet there, and the steps can miss (the VM's log has each one). Turn it on again to try once more."
                    : "Monad could not turn System Integrity Protection off in recovery, so it is still on. Turn it off "
                        + "again to try once more, or do it by hand in recovery (Options, Terminal, csrutil disable)."
                // The switch shows what the VM has.
                if found == .enabled || found == .disabled { self.undoSecurityChange { $0.systemIntegrityProtection = found == .enabled } }
            }
            var report = self.macSecurity ?? MacSecurityReport()
            report.sip = found.word
            report.problem = problem
            self.macSecurity = report
        }
    }

    // MARK: Desktop (macOS)

    /// Logging in automatically, as set, for the next boot (written at
    /// every boot: a change made while it runs takes effect at the next).
    private func applyAutoLogin() {
        let on = config.autoLogin, user = config.user
        let password = (try? String(contentsOf: paths.macPassword, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Task { [weak self] in
            guard let self else { return }
            let r = on
                ? try? await self.sshSteadily(MacSetup.autoLoginOnCommand(user: user), stdin: MacSetup.kcpassword(password), timeout: 30)
                : try? await self.sshSteadily(MacSetup.autoLoginOffCommand, timeout: 30)
            self.debug("login: \(on ? "automatic" : "at the login window") at the next boot"
                       + (r?.status == 0 ? "" : " (not set: \(r?.stderrString ?? "ssh did not run"))"))
        }
    }

    /// The VM named after itself (macOS keeps its install's name otherwise,
    /// the same in every macOS VM).
    private func nameMac() {
        let command = MacSetup.hostNameCommand(config: config)
        Task { [weak self] in
            guard let self else { return }
            let r = try? await self.sshSteadily(command, timeout: 30)
            if r?.status != 0 { self.debug("name: not set: \(r?.stderrString ?? "ssh did not run")") }
        }
    }

    /// Auto-fill: a password prompt on the guest's screen gets the password,
    /// a moment after it shows. Only while the VM logs in by itself: the
    /// guest then has the password anyway (kcpassword); otherwise it has only
    /// a hash, and typing on its word would hand it the password.
    private func passwordPrompted() {
        guard config.desktopAutofill == true, config.autoLogin else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.env.clock.sleep(seconds: 1)
            await self.typePassword()
        }
    }

    /// Opens the VM's desktop (a window on its display), also while it is
    /// in recovery.
    func openDesktop() throws {
        guard config.guestOS == .macos else { throw MonadError("Only a macOS VM has a desktop to open.") }
        let typing = DesktopAction(title: "Type Password") { [weak self] in await self?.typePassword() }
        let paste: @MainActor (String) async -> Void = { [weak self] text in await self?.paste(text) }
        if let recovery = recoveryMachine { return try recovery.showDesktop(title: name, actions: [typing], paste: paste) }
        guard isRunning, let machine else { throw MonadError("\(name) is not running. Start it first.") }
        debug("desktop: opened")
        try machine.showDesktop(title: name, actions: [typing], paste: paste)
    }

    /// Before typing on the desktop: the keys the Mac's keyboard holds let
    /// go (⌘, held for ⌘V, would turn each character into a shortcut), and
    /// the display woken by a lone shift (the key that wakes it is lost).
    private func readyToType(_ input: MacRecoveryInput) async throws {
        try await input.release(keyCodes: MacRecovery.Key.modifiers)
        try await input.press(keyCode: MacRecovery.Key.shift, modifiers: [])
        await env.clock.sleep(seconds: 0.5)
    }

    /// ⌘V on the desktop: the Mac's text on the VM's clipboard, then ⌘V
    /// there; where there is no clipboard (the login window, recovery),
    /// typed instead.
    func paste(_ text: String) async {
        guard let input = (recoveryMachine ?? machine) as? MacRecoveryInput else { return }
        if recoveryMachine == nil, state == .ready,
           let r = try? await ssh(MacSetup.pasteboardCommand(user: config.user), stdin: Data(text.utf8), timeout: 15), r.status == 0 {
            debug("desktop: pasted through the VM's clipboard")
            try? await input.press(keyCode: MacRecovery.Key.v, modifiers: [MacRecovery.Key.command])
        } else if MacRecovery.keyStrokes(for: text) != nil {
            debug("desktop: typed what was pasted (no clipboard there)")
            try? await readyToType(input)
            try? await MacRecovery.run([.text(text)], on: input, password: "", clock: env.clock)
        } else {
            debug("desktop: not pasted (no clipboard there, and it cannot be typed)")
        }
    }

    /// The account's password and Return, typed into the desktop (the login
    /// window, a system prompt), never shown.
    func typePassword() async {
        guard let input = (recoveryMachine ?? machine) as? MacRecoveryInput else { return }
        let password = (try? String(contentsOf: paths.macPassword, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        debug("desktop: typing the account's password")
        do {
            try await readyToType(input)
            try await MacRecovery.run([.password, .key(MacRecovery.Key.returnKey, [])], on: input, password: password,
                                      clock: env.clock)
        } catch {
            debug("desktop: the password was not typed: \(error.localizedDescription)")
        }
    }

    /// A security setting that did not take goes back to what the VM has,
    /// saved, so the Security page shows the truth (the running machine
    /// counts as built so).
    private func undoSecurityChange(_ edit: (inout InstanceConfig) -> Void) {
        var c = config
        edit(&c)
        try? c.save(to: paths.config)
        config = c
        if machineConfig != nil { edit(&machineConfig!) }
    }

    /// Repair Disk's temporary VM: its machine takes a disk while it runs.
    var takesDisks = false

    private func makeMachine(nic: FileHandle?) throws -> VirtualMachineControlling {
        takesDisks ? try env.machines.makeDiskMachine(config: config, paths: paths, nic: nic)
                   : try env.machines.makeMachine(config: config, paths: paths, nic: nic)
    }

    /// Another VM's disk, attached while this (Repair Disk's) VM runs.
    func attachDisk(_ url: URL) async throws {
        guard state == .ready, let m = machine as? DiskAttaching else { throw MonadError("\(name) cannot take a disk now.") }
        debug("disk: attaching \(url.path)")
        try await m.attachDisk(url)
    }

    func detachDisk() async throws {
        guard let m = machine as? DiskAttaching else { return }
        debug("disk: detaching it")
        try await m.detachDisk()
    }

    // MARK: Repair Disk (VMManager.repairDisk)

    /// While its disk is repaired the VM does not start, change or go.
    private(set) var isRepairing = false

    func beginRepair(_ step: String) {
        isRepairing = true
        repairStep(step)
    }

    func repairStep(_ step: String) {
        debug("repair: " + step)
        state = .preparing(step)
    }

    /// Back to stopped, or failed with why.
    func endRepair(failure: String?) {
        isRepairing = false
        state = failure.map { .failed($0) } ?? .stopped
    }

    /// A new machine replaces the old one, whose NIC (if any) leaves netd.
    private func replaceMachine(_ m: VirtualMachineControlling, nic newNIC: NICAttachment?) {
        nic?.detach()
        nic = newNIC
        machine = m
        machineConfig = config
    }

    /// Drop the (stopped) machine and its network port, e.g. before the VM is
    /// deleted.
    func discardMachine() {
        guard !isRunning else { return }
        nic?.detach()
        nic = nil
        machine = nil
        machineConfig = nil
    }

    private func boot(_ m: VirtualMachineControlling) async {
        guestReport = .starting(at: paths.serialLog)
        debug("boot: starting the machine (\(config.cpus) CPUs, \(config.memoryGiB) GiB, folder sharing \(config.sharing.runtimeEnabled ? "on" : "off"))")
        do {
            try await m.start()
        } catch {
            debug("boot: the machine did not start: \(error.localizedDescription)")
            if state == .starting { state = .failed(startProblem(error)) }
            return
        }
        guard state == .starting, !Task.isCancelled else { return }
        writeRunningMark()
        persistMAC(m)
        if config.memoryTargetGiB != nil { applyMemoryTarget() }
        // Current ssh settings for VMs made by older versions (e.g. a
        // persistent ControlMaster, which forwards depend on).
        try? CloudInit.sshConfig(config: config, paths: paths).write(to: paths.sshConfig, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: paths.controlSocket)
        do {
            try m.startBridge(socketPath: paths.sshSocket.path, port: CloudInit.vsockSSHPort)
        } catch {
            debug("boot: no ssh bridge: \(error.localizedDescription)")
            await fail(m, "Cannot open SSH bridge: \(error.localizedDescription)")
            return
        }
        debug("boot: ssh bridge \(paths.sshSocket.path) → vsock port \(CloudInit.vsockSSHPort)")
        state = .booting
        await waitForSSH(m)
    }

    /// Keep the address the backend generated for a VM that had none. A chosen
    /// address is never replaced (on a Monad network, netd's port is bound to it).
    private func persistMAC(_ m: VirtualMachineControlling) {
        guard let mac = m.macAddress, !config.networks.isEmpty, config.primaryMACAddress == nil else { return }
        var c = config
        c.networks[0].macAddress = mac
        try? c.save(to: paths.config)
        config = c
        // The machine already runs with this address.
        machineConfig?.networks[0].macAddress = mac
    }

    /// Poll until sshd answers on vsock and our key is accepted, then verify
    /// that sshd is not reachable over the network before handing out shells.
    /// A check that gets no answer (on a first boot cloud-init may still be
    /// changing sshd) is asked again until the boot deadline.
    private func waitForSSH(_ m: VirtualMachineControlling) async {
        let deadline = env.clock.now().addingTimeInterval(Self.bootTimeout)
        var unanswered: String?
        var answering: Bool?
        while env.clock.now() < deadline {
            guard state == .booting, !Task.isCancelled else { return }
            readGuestReport()
            let probed = await m.probe(port: CloudInit.vsockSSHPort, timeout: 3)
            if probed != answering {
                debug(probed ? "boot: sshd answers on vsock" : "boot: sshd does not answer on vsock yet")
                answering = probed
            }
            if probed, state == .booting {
                let r = try? await ssh("true", timeout: 30)
                guard state == .booting, !Task.isCancelled else { return }
                if r?.status != 0 {
                    debug("boot: ssh login not accepted yet (\(r.map { "status \($0.status): " + ($0.stderrString.split(separator: "\n").last.map(String.init) ?? "") } ?? "ssh could not run"))")
                }
                if r?.status == 0 {
                    let isolation = await checkIsolation()
                    debug("boot: isolation check: \(isolation)")
                    switch isolation {
                    case .isolated:
                        guard state == .booting else { return }
                        becomeReady()
                        return
                    case .exposed(let verdict):
                        guard state == .booting else { return }
                        // Fail closed: a guest whose sshd is exposed on the network is not used.
                        Log.vm.error("\(self.sshHost, privacy: .public): isolation check failed: \(verdict, privacy: .public)")
                        await fail(m, "Guest isolation check failed (\(verdict)). The VM was powered off.")
                        return
                    case .unanswered(let why):
                        Log.vm.notice("\(self.sshHost, privacy: .public): isolation check unanswered, asking again: \(why, privacy: .public)")
                        unanswered = why
                    }
                }
            }
            await env.clock.sleep(seconds: 1)
        }
        guard state == .booting else { return }
        readGuestReport()
        if let unanswered {
            await fail(m, "Guest isolation check failed (no answer: \(unanswered.isEmpty ? "ssh said nothing" : unanswered)).\(guestSays) The VM was powered off.")
        } else {
            await failBoot(m, "The guest did not become reachable over SSH.\(guestSays) See \(paths.serialLog.path)")
        }
    }

    /// The guest's report lines (Guest/monad-report.sh) since the last
    /// read, into the debug log.
    private func readGuestReport() {
        for line in guestReport.newLines(in: paths.serialLog) { debug("guest: \(line)") }
    }

    /// What the guest said last, for a failure message ("" if nothing).
    private var guestSays: String {
        let last = guestReport.lines.suffix(4)
        return last.isEmpty ? "" : " The guest says: " + last.joined(separator: "; ") + "."
    }

    private enum Isolation {
        case isolated
        case exposed(String)
        /// The check did not run to the end (what ssh said, if anything).
        case unanswered(String)
    }

    private func checkIsolation() async -> Isolation {
        guard let guest else { return .exposed("its distribution is unknown, so it cannot be checked") }
        let r: ProcessRunner.Result
        let script = config.guestOS == .macos ? MacSetup.isolationScript
            : CloudInit.enforceIsolationScript(guest: guest, lima: config.attached != nil)
        do {
            r = try await ssh(script, timeout: 30)
        } catch {
            return .unanswered(error.localizedDescription)
        }
        switch r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "ok": return .isolated
        case CloudInit.monadSSHDNotYet: return .unanswered("Monad's ssh service is not set up in the guest yet")
        case "": return .unanswered(r.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").last.map(String.init) ?? "")
        case let verdict: return .exposed(verdict)
        }
    }

    private func becomeReady() {
        Log.vm.notice("\(self.sshHost, privacy: .public): sshd reachable over vsock only")
        debug("ready: starting forwards, shared folders, the guest agent and pending profiles")
        state = .ready
        applyBridges()
        applyHostCommands()
        applyAgents()
        startForwarding()
        let deviceShares = config.deviceShares(paths: paths)
        if !deviceShares.isEmpty || hostShares != deviceShares { applyShares() }
        installGuestComponents()
        runPendingProfiles()
        if config.guestOS == .macos {
            checkSIP()
            applyAutoLogin()
            nameMac()
        }
        #if DEBUG
            logGuestDiagnostics()
        #endif
    }

    /// How often a step run once the VM is ready tries ssh that cannot
    /// connect (status 255), 1, 2, 4 and 8 s apart.
    static let sshAttempts = 5

    /// ssh for the steps run once the VM is ready: right after a first boot
    /// it can fail to connect (status 255) while cloud-init still sets sshd
    /// up, so that is tried again; any answer from the guest is final.
    private func sshSteadily(_ remote: String, stdin: Data? = nil, timeout: TimeInterval) async throws -> ProcessRunner.Result {
        var delay: TimeInterval = 1
        var attempt = 1
        while true {
            let r = try await ssh(remote, stdin: stdin, timeout: timeout)
            guard r.status == 255, attempt < Self.sshAttempts, state == .ready, !Task.isCancelled else { return r }
            debug("ssh: could not connect (try \(attempt) of \(Self.sshAttempts)), trying again in \(Int(delay)) s")
            await env.clock.sleep(seconds: delay)
            delay *= 2
            attempt += 1
        }
    }

    private func ssh(_ remote: String, stdin: Data? = nil, timeout: TimeInterval) async throws -> ProcessRunner.Result {
        try await env.runner.run("/usr/bin/ssh", sshOptions + [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ControlMaster=no", sshHost, remote,
        ], stdin: stdin, timeout: timeout)
    }

    /// A command in the guest, as its user, over ssh (the MCP tools' exec,
    /// read_file and write_file). Only while the VM is ready; output is
    /// capped by the runner.
    func guestRun(_ command: String, stdin: Data? = nil, timeout: TimeInterval) async throws -> ProcessRunner.Result {
        guard state == .ready else { throw MonadError("\(name) is not running (it is \(state.label.lowercased())). Start it first.") }
        return try await ssh(command, stdin: stdin, timeout: timeout)
    }

    /// Install or update the guest agent to match this Monad version. Not
    /// critical: a failure leaves the VM usable without agent features.
    private func installGuestComponents() {
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let guest = self.guest else { return }
                let r: ProcessRunner.Result
                if self.config.guestOS == .macos {
                    r = try await self.sshSteadily(MacSetup.agentInstallCommand, stdin: Data(try MacSetup.guestInstallScript().utf8),
                                                   timeout: 60)
                } else {
                    let script = try CloudInit.guestInstallScript(guest: guest, lima: self.config.attached != nil,
                                                                  bootMessages: self.env.bootMessages())
                    r = try await self.sshSteadily(CloudInit.guestInstallCommand, stdin: Data(script.utf8), timeout: 60)
                }
                guard self.state == .ready else { return }
                self.debug("guest components: install answered status \(r.status)" + DebugLog.output(r))
                if r.status == 0, r.stdoutString.contains("agent-ok") {
                    Log.vm.notice("\(self.name, privacy: .public): guest agent installed")
                    self.agentAvailable = true
                    self.connectAgent()
                } else {
                    Log.vm.error("\(self.name, privacy: .public): agent install failed: \(r.stderrString, privacy: .public)")
                }
            } catch {
                self.debug("guest components: install failed: \(error.localizedDescription)")
                Log.vm.error("\(self.name, privacy: .public): agent install failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Settings › Virtual Machines › Full boot messages changed: set in the
    /// guest now, so its next boot shows them (the installer sets them at
    /// every boot too). Linux VMs Monad boots, while they run.
    func applyBootMessages(_ messages: BootMessages) {
        guard state == .ready, config.guestOS == .linux, config.attached == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            let said = messages == .full ? "every message" : "errors only"
            do {
                let r = try await self.ssh(CloudInit.bootMessagesCommand(messages), timeout: 120)
                self.debug("boot messages: \(said) from the next boot (status \(r.status))" + DebugLog.output(r))
            } catch {
                self.debug("boot messages: could not set \(said): \(error.localizedDescription)")
            }
        }
    }

    /// A boot that never reached sshd: powered off first, so nothing writes
    /// to the disk any more, then its disk is read for the error.
    private func failBoot(_ m: VirtualMachineControlling, _ message: String) async {
        await fail(m, message)
        await addDiskCheck(to: message)
    }

    /// Reads a stopped Linux VM's disk (DiskReport): all it found goes to the
    /// log, its summary joins `message` while that is still the VM's error.
    private func addDiskCheck(to message: String) async {
        guard config.guestOS == .linux, !isRunning else { return }
        let disk = config.attached?.disk ?? paths.disk
        guard let report = await Task.detached(operation: { DiskReport.check(disk: disk) }).value else {
            debug("disk: could not be read")
            return
        }
        debug("disk: \(report.logLine)")
        if state == .failed(message) { state = .failed(message + " " + report.summary) }
    }

    /// Power off and end in `failed` (a later `.stopped` event keeps the error).
    private func fail(_ m: VirtualMachineControlling, _ message: String) async {
        debug("powering off: \(message)")
        poweringOff = true
        state = .failed(message)
        disconnectGuest()
        agentAvailable = false
        await powerOff(m)
        poweringOff = false
        diskLock = nil
        m.stopBridge()
        try? FileManager.default.removeItem(at: paths.controlSocket)
    }

    /// Keep a channel to the agent open while the VM is ready; reconnect if
    /// the agent goes away (e.g. restarted by systemd).
    private func connectAgent() {
        agentTask?.cancel()
        agentTask = Task { [weak self] in
            var delay: TimeInterval = 1
            while let self, !Task.isCancelled, self.state == .ready, self.agentAvailable {
                guard let m = self.machine,
                      let channel = try? await m.openChannel(port: CloudInit.agentVsockPort, timeout: 5) else {
                    self.debug("agent: no answer on vsock port \(CloudInit.agentVsockPort), trying again in \(Int(delay)) s")
                    await self.env.clock.sleep(seconds: delay)
                    delay = min(delay * 2, 30)
                    continue
                }
                guard !Task.isCancelled, self.state == .ready else {
                    channel.close()
                    return
                }
                let connectedAt = self.env.clock.now()
                self.debug("agent: connected")
                let client = AgentClient(channel: channel)
                self.agent = client
                let disconnected = AsyncStream<Void> { cont in
                    client.onDisconnect = { cont.finish() }
                    client.onEvent = { [weak self, weak client] event in
                        guard let self, let client else { return }
                        self.guestPorts = client.ports
                        if let text = event.debugText { self.debug("agent: \(text)") }
                        switch event {
                        case .mode(let mode):
                            Log.vm.notice("\(self.name, privacy: .public): agent watching ports via \(mode.rawValue, privacy: .public)")
                        case .opened(let p):
                            Log.vm.notice("\(self.name, privacy: .public): guest port opened \(p.address, privacy: .public) \(p.port)")
                        case .closed(let p):
                            Log.vm.notice("\(self.name, privacy: .public): guest port closed \(p.address, privacy: .public) \(p.port)")
                        case .prompt:
                            self.passwordPrompted()
                        default:
                            break
                        }
                    }
                }
                client.start()
                await self.checkGuestBoot()
                for await _ in disconnected {}
                self.debug(String(format: "agent: disconnected after %.1f s", self.env.clock.now().timeIntervalSince(connectedAt)))
                self.guestPorts = []
                self.agent = nil
                // An agent that drops right away (crash loop, hostile guest)
                // is retried less and less often.
                let pause: TimeInterval
                if self.env.clock.now().timeIntervalSince(connectedAt) >= Self.healthyAgentConnection {
                    delay = 1
                    pause = 0.5
                } else {
                    pause = delay
                    delay = min(delay * 2, 30)
                }
                if !Task.isCancelled { await self.env.clock.sleep(seconds: pause) }
            }
        }
    }

    /// The guest's boot (Linux's boot_id, macOS's boot session).
    static let bootIDCommand = "cat /proc/sys/kernel/random/boot_id 2>/dev/null || sysctl -n kern.bootsessionuuid"

    /// The boot the guest was in when its agent last connected.
    private var guestBoot: String?

    /// A guest that rebooted by itself (sudo reboot) stays ready here, but
    /// what Monad did at its boot is gone (its mounts) or must be checked
    /// again (nothing listening for ssh on its network). Its agent comes
    /// back from the new boot: checked then, as at boot.
    private func checkGuestBoot() async {
        guard let r = try? await sshSteadily(Self.bootIDCommand, timeout: 15), r.status == 0, state == .ready else { return }
        let now = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !now.isEmpty else { return }
        let before = guestBoot
        guestBoot = now
        guard let before, before != now, let m = machine else { return }
        debug("guest: rebooted by itself: checking its isolation and mounting its shared folders again")
        Log.vm.notice("\(self.sshHost, privacy: .public): the guest rebooted by itself")
        switch await checkIsolation() {
        case .isolated:
            break
        case .exposed(let verdict):
            guard state == .ready else { return }
            Log.vm.error("\(self.sshHost, privacy: .public): isolation check failed after a reboot: \(verdict, privacy: .public)")
            await fail(m, "Guest isolation check failed after the guest restarted itself (\(verdict)). The VM was powered off.")
            return
        case .unanswered(let why):
            debug("guest: isolation check unanswered after the reboot: \(why)")
        }
        guard state == .ready else { return }
        if !config.deviceShares(paths: paths).isEmpty { applyShares() }
    }

    /// Drop everything that talks to the guest: forwards first, so the ssh
    /// master going away is not taken for a crash and restarted.
    private func disconnectGuest() {
        stopForwarding()
        stopBridges()
        sharesTask?.cancel()
        sharesTask = nil
        sharesError = nil
        agentTask?.cancel()
        agentTask = nil
        agent?.stop()
        agent = nil
        guestBoot = nil
        guestPorts = []
    }

    // MARK: Forwards

    private func startForwarding() {
        let manager = ForwardManager(mux: SSHMux(paths: paths, host: sshHost, options: sshOptions), runner: env.runner,
                                     watcher: env.watcher,
                                     clock: env.clock, debugLog: env.debugLog, debugScope: "vm \(name)", vmName: name)
        manager.onChange = { [weak self] statuses, overLimit in
            self?.forwards = statuses
            self?.portsOverLimit = overLimit
        }
        forwarding = manager
        applyForwards()
    }

    private func applyForwards(guestEvent: Bool = false) {
        guard let forwarding, state == .ready else { return }
        let (rules, auto, ports) = (config.forwards, config.autoForward, guestPorts)
        let bridges = config.bridges.compactMap { bridgeServers[$0.id]?.bridge }
            .map { ForwardPlan.Bridge(spec: $0.spec(in: paths), guestPort: $0.guestPort) }
            + config.hostCommands.compactMap { hostCommandServers[$0.id]?.command }
            .map { ForwardPlan.Bridge(spec: $0.spec(in: paths), guestPort: $0.guestPort) }
            + (mcpEndpoint.map { [ForwardPlan.Bridge(spec: Self.mcpSpec(port: $0.port, paths: paths), guestPort: $0.port)] } ?? [])
        debug("forwards: \(DebugLog.count(rules.count, "configured forward")), \(DebugLog.count(bridges.count, "bridge")), "
              + "auto-forward \(auto.enabled ? "on" : "off"), "
              + "guest listening on \(ports.isEmpty ? "nothing" : ports.map { "\($0.address):\($0.port)" }.sorted().joined(separator: " "))")
        Task { await forwarding.apply(configured: rules, autoForward: auto, ports: ports, bridges: bridges, guestEvent: guestEvent) }
    }

    // MARK: Connections

    /// What the VM tried to reach and what its firewall said (netd's log,
    /// Phase 13): only while it runs on a Monad network.
    func connections() async throws -> [NetConnection] {
        guard isRunning, let networks = env.networks, let first = config.networks.first, !first.isAppleNAT else {
            return []
        }
        return try await networks.connections(vm: name)
    }

    // MARK: Bridges

    /// The enabled bridges serve while the VM is ready: a new one starts, a
    /// changed one starts again, a removed or disabled one stops. One whose
    /// server cannot listen is left out (and said so in the debug log).
    private func applyBridges() {
        let wanted = state == .ready ? config.bridges.filter(\.enabled) : []
        for (id, running) in bridgeServers where !wanted.contains(running.bridge) {
            running.server.stop()
            bridgeServers[id] = nil
            debug("bridge \(running.bridge.name): stopped")
        }
        for bridge in wanted where bridgeServers[bridge.id] == nil {
            let server = env.bridgeServer(bridge, paths)
            do {
                try server.start()
                bridgeServers[bridge.id] = (bridge, server)
                debug("bridge \(bridge.name): serving \(bridge.command[0]) at \(bridge.guestEndpoint) in the VM")
            } catch {
                debug("bridge \(bridge.name): cannot serve: \(error.localizedDescription)")
            }
        }
    }

    private func stopBridges() {
        for running in bridgeServers.values {
            running.server.stop()
            debug("bridge \(running.bridge.name): stopped")
        }
        bridgeServers = [:]
        for running in hostCommandServers.values {
            running.server.stop()
            debug("host command \(running.command.name): stopped")
        }
        hostCommandServers = [:]
        mcpEndpoint?.server.stop()
        mcpEndpoint = nil
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    // MARK: Agents

    static func mcpSpec(port: Int, paths: InstancePaths) -> SSHMux.Spec {
        SSHMux.Spec(flag: "-R", value: "127.0.0.1:\(port):\(paths.mcpSocket.path)")
    }

    /// Monad's MCP endpoint serves while the VM is ready and has a role; the
    /// token goes when the role does. Then the guest is told (discovery).
    private func applyAgents() {
        let wanted = state == .ready ? config.agents : nil
        if let running = mcpEndpoint, running.port != wanted?.guestPort {
            running.server.stop()
            mcpEndpoint = nil
            debug("mcp: endpoint stopped")
        }
        if config.agents == nil { try? FileManager.default.removeItem(at: paths.mcpToken) }
        if let wanted, mcpEndpoint == nil {
            do {
                let token = try MCPHTTPServer.token(at: paths.mcpToken)
                let server = env.mcpEndpoint(paths.mcpSocket, token, name)
                try server.start()
                mcpEndpoint = (server, wanted.guestPort)
                debug("mcp: \(wanted.role.rawValue) endpoint at 127.0.0.1:\(wanted.guestPort) in the VM")
            } catch {
                debug("mcp: cannot serve: \(error.localizedDescription)")
            }
        }
        applyForwards()
        refreshDiscovery()
    }

    /// Writes what the guest finds (bridges.json, mcp.env) and registers
    /// Monad with its agents; again after a profile is set up (it may have
    /// installed one).
    private func refreshDiscovery() {
        guard state == .ready else { return }
        let token = config.agents != nil ? try? String(contentsOf: paths.mcpToken, encoding: .utf8) : nil
        let script = GuestDiscovery.script(config, token: token?.trimmingCharacters(in: .whitespacesAndNewlines))
        let previous = discoveryTask
        discoveryTask = Task { [weak self] in
            await previous?.value
            guard let self, self.state == .ready, !Task.isCancelled else { return }
            do {
                let r = try await self.ssh(GuestDiscovery.command, stdin: Data(script.utf8), timeout: 60)
                guard self.state == .ready else { return }
                self.mcpRegistered = GuestDiscovery.registered(r.stdoutString)
                self.debug("discovery: status \(r.status)"
                           + (self.mcpRegistered.isEmpty ? "" : ", Monad registered with \(self.mcpRegistered.joined(separator: ", "))"))
            } catch {
                self.debug("discovery: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Host commands

    /// The exchange folder, readable in the guest (0755; the VM's folder
    /// around it is 0700, so it is the user's only on the Mac).
    static func makeExchange(_ paths: InstancePaths) throws {
        try FileManager.default.createDirectory(at: paths.exchange, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.exchange.path)
    }

    /// As bridges: the enabled host commands serve while the VM is ready.
    private func applyHostCommands() {
        let wanted = state == .ready ? config.hostCommands.filter(\.enabled) : []
        for (id, running) in hostCommandServers where !wanted.contains(running.command) {
            running.server.stop()
            hostCommandServers[id] = nil
            debug("host command \(running.command.name): stopped")
        }
        for command in wanted where hostCommandServers[command.id] == nil {
            let server = env.hostCommandServer(command, paths, config.home)
            do {
                try server.start()
                hostCommandServers[command.id] = (command, server)
                debug("host command \(command.name): serving \(command.program) at \(command.guestEndpoint) in the VM")
            } catch {
                debug("host command \(command.name): cannot serve: \(error.localizedDescription)")
            }
        }
    }

    /// The server of the host command called `name`, while it serves (the
    /// MCP tools run it in process).
    func hostCommandServer(named name: String) -> (command: HostCommand, server: HostCommandServing)? {
        hostCommandServers.values.first { $0.command.name == name }
    }

    private func stopForwarding() {
        forwarding?.stop()
        forwarding = nil
        forwards = []
        portsOverLimit = 0
    }

    // MARK: Shared folders

    /// Make the running share and the guest's mounts match the config, one
    /// run at a time: the host share first (new folders must exist before
    /// the guest mounts them), then the guest.
    private func applyShares() {
        guard state == .ready else {
            debug("shares: applied once the VM is ready (now \(state.debugName))")
            return
        }
        guard let m = machine, machineConfig?.sharing.runtimeEnabled == true else {
            debug("shares: the running machine has no shared folder device (folder sharing applies after a restart)")
            return
        }
        let previous = sharesTask
        sharesTask = Task { [weak self] in
            await previous?.value
            guard let self, self.state == .ready, !Task.isCancelled else { return }
            let shares = self.config.deviceShares(paths: self.paths)
            let named = SharingSettings.named(shares)
            func mode(_ s: SharedFolder) -> String { s.readOnly ? "ro" : "rw" }
            // A new folder list on the device makes earlier binds stale.
            let rebind = shares != self.hostShares
            do {
                if rebind {
                    self.debug("shares: the device now holds \(DebugLog.count(shares.count, "folder"))"
                               + named.map { "\n\($0.name) = \($0.share.hostPath) (\(mode($0.share)))" }.joined())
                    try await m.setShares(shares)
                    self.hostShares = shares
                } else {
                    self.debug("shares: the device already holds \(DebugLog.count(shares.count, "folder"))")
                }
                self.debug("shares: asking the guest to mount \(DebugLog.count(shares.count, "folder"))"
                           + named.map { "\n\($0.name) at \(InstanceConfig.normalizedGuestPath($0.share.guestPath)) (\(mode($0.share)))" }.joined())
                let script = self.config.guestOS == .macos ? GuestShares.macScript(for: shares, rebind: rebind)
                    : GuestShares.script(for: shares, rebind: rebind)
                let r = try await self.sshSteadily(GuestShares.command, stdin: Data(script.utf8), timeout: 60)
                self.debug("shares: the guest answered status \(r.status)" + DebugLog.output(r))
                guard self.state == .ready, !Task.isCancelled else { return }
                self.sharesError = GuestShares.problem(r)
            } catch {
                self.debug("shares: failed: \(error.localizedDescription)")
                self.sharesError = error.localizedDescription
            }
            self.debug("shares: \(self.sharesError ?? "every folder is mounted")")
            if let problem = self.sharesError {
                Log.vm.error("\(self.name, privacy: .public): \(problem, privacy: .public)")
            }
        }
    }

    #if DEBUG
        /// Development aid: record what the guest looks like once reachable.
        private func logGuestDiagnostics() {
            let name = self.name
            let script = "uname -sr; . /etc/os-release; echo $PRETTY_NAME; id -un; "
                + "systemctl is-active monad-sshd.socket; cloud-init status 2>/dev/null; "
                + "ip -brief addr | grep -v '^lo'"
            Task { [weak self] in
                guard let self, let r = try? await self.ssh(script, timeout: 30) else { return }
                Log.vm.notice("\(name, privacy: .public) guest diagnostics:\n\(r.stdoutString, privacy: .public)")
            }
        }
    #endif

    // MARK: Stop

    /// Graceful shutdown (ACPI power button) with a timeout, then power off.
    func stop(timeout: TimeInterval = 20) async {
        if macSecurity?.step != nil {
            // A step before macOS (recovery, its disk): nothing to shut down cleanly.
            debug("stop: stopping before macOS started")
            lifecycleTask?.cancel()
            await recoveryMachine?.forceStop()
            recoveryMachine = nil
            endStartStep()
            state = .stopped
            return
        }
        if attaching {
            // Still waiting for its NIC: nothing runs yet.
            debug("stop: stopped while waiting for its network card (nothing ran yet)")
            lifecycleTask?.cancel()
            state = .stopped
            return
        }
        guard let m = machine, isRunning else { return }
        debug("stop: asking the guest to shut down (power off after \(Int(timeout)) s)")
        state = .stopping
        lifecycleTask?.cancel()
        disconnectGuest()
        await closeSSHMaster()
        do {
            try await m.requestStop()
        } catch {
            // The guest cannot receive the request (e.g. still in firmware).
            debug("stop: the guest cannot take the request (\(error.localizedDescription)), powering off")
            await powerOff(m)
        }
        let deadline = env.clock.now().addingTimeInterval(timeout)
        while state == .stopping && env.clock.now() < deadline {
            await env.clock.sleep(seconds: 0.2)
        }
        if state == .stopping {
            debug("stop: the guest did not shut down in time, powering off")
            Log.vm.info("\(self.name, privacy: .public) did not shut down in time; powering off")
            await powerOff(m)
            finishStop()
        }
    }

    func forceStop() async {
        if macSecurity?.step != nil { return await stop() }
        guard let m = machine else { return }
        debug("stop: powering off")
        lifecycleTask?.cancel()
        stopForwarding()
        await closeSSHMaster()
        await powerOff(m)
        finishStop()
    }

    /// Set while Monad powers the machine off, so its stop event says who
    /// stopped it (Virtualization reports the stop before the power-off returns).
    private var poweringOffByMonad = false

    private func powerOff(_ m: VirtualMachineControlling) async {
        poweringOffByMonad = true
        defer { poweringOffByMonad = false }
        await m.forceStop()
    }

    private func closeSSHMaster() async {
        guard FileManager.default.fileExists(atPath: paths.controlSocket.path) else { return }
        _ = try? await env.runner.run("/usr/bin/ssh", sshOptions + ["-O", "exit", sshHost],
                                      stdin: nil, timeout: 5)
    }

    private func finishStop() {
        endFirewallSession()
        endProfileRuns()
        disconnectGuest()
        agentAvailable = false
        machine?.stopBridge()
        try? FileManager.default.removeItem(at: paths.controlSocket)
        if !isFailed && state != .stopped { state = .stopped }
    }

    // MARK: Profiles

    /// Sets up profiles in the running VM, one after another, even ones set
    /// up before (running one again changes only what is missing or old).
    func runProfiles(_ ids: [String]) throws {
        guard state == .ready else { throw MonadError("Profiles are set up while the VM runs. Start it first.") }
        let catalog = env.profiles()
        var profiles: [ProfileConfig] = []
        for id in ids {
            guard let p = catalog.profile(id) else { throw MonadError("There is no profile “\(id)”.") }
            guard let manager = guest?.packageManager, p.supports(packageManager: manager) else {
                throw MonadError("\(p.name) has nothing for this distribution's package manager.")
            }
            profiles.append(p)
        }
        for p in profiles {
            let busy = profileQueue.contains(p.id)
                || profileRuns.contains { $0.profile == p.id && ($0.state == .waiting || $0.state == .running) }
            guard !busy else { continue }
            profileQueue.append(p.id)
            profileRuns.removeAll { $0.profile == p.id }
            profileRuns.append(ProfileRun(profile: p))
        }
        guard profileTask == nil else { return }
        profileTask = Task { [weak self] in
            while let self, let id = self.profileQueue.first {
                self.profileQueue.removeFirst()
                await self.runProfile(id)
            }
            self?.profileTask = nil
        }
    }

    /// The VM's profiles it has not finished setting up yet.
    private func runPendingProfiles() {
        let applied = AppliedProfiles.load(paths.appliedProfiles)
        let pending = config.profiles.filter { applied.applied[$0] == nil }
        guard !pending.isEmpty else { return }
        do {
            try runProfiles(pending)
        } catch {
            Log.vm.error("\(self.name, privacy: .public): profiles not run: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runProfile(_ id: String) async {
        guard let index = profileRuns.lastIndex(where: { $0.profile == id }) else { return }
        guard state == .ready, let manager = guest?.packageManager, let profile = env.profiles().profile(id) else {
            profileRuns[index].fail("The VM or the profile went away.")
            return
        }
        let script: String
        do {
            script = try ProfileScript.render(profile, packageManager: manager, user: config.user)
        } catch {
            profileRuns[index].fail(error.localizedDescription)
            return
        }
        profileRuns[index].state = .running
        debug("profiles: setting up \(id) (output in \(paths.profileLog(id).path))")
        Log.vm.notice("\(self.name, privacy: .public): setting up \(id, privacy: .public)")
        var file = ProfileLogFile(url: paths.profileLog(id))
        file.start()
        defer { file.close() }
        // Lines arrive on a reader thread: in order, through a stream.
        let (lines, sink) = AsyncStream.makeStream(of: String.self)
        let runner = env.runner
        let args = sshOptions + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                    "-o", "ControlMaster=no", sshHost, Self.profileCommand]
        let job = Task.detached { () -> Result<ProcessRunner.Result, Error> in
            defer { sink.finish() }
            do {
                return .success(try await runner.stream("/usr/bin/ssh", args, stdin: Data(script.utf8),
                                                        timeout: Self.profileTimeout) { sink.yield($0) })
            } catch {
                return .failure(error)
            }
        }
        for await line in lines {
            if case .pid(let pid) = ProfileProgress.parse(line) {
                profilePID = pid
                if profileStopRequested { killProfileGroup(pid) }
                continue
            }
            file.append(line)
            guard profileRuns.indices.contains(index), profileRuns[index].profile == id else { continue }
            profileRuns[index].apply(line)
        }
        let outcome = await job.value
        let stopped = profileStopRequested
        profilePID = nil
        profileStopRequested = false
        guard profileRuns.indices.contains(index), profileRuns[index].profile == id else { return }
        switch outcome {
        case .success(let r): profileRuns[index].finish(status: r.status)
        case .failure(let e): profileRuns[index].fail(e.localizedDescription)
        }
        if stopped {
            profileRuns[index].fail("Stopped.")
            for i in profileRuns[index].steps.indices where profileRuns[index].steps[i].state == .running {
                profileRuns[index].steps[i].state = .failed
            }
        }
        file.append(profileRuns[index].state == .done ? "[Set up.]" : "[Not set up: \(profileRuns[index].message ?? "")]")
        debug("profiles: \(id) " + (profileRuns[index].state == .done ? "is set up" : "failed: \(profileRuns[index].message ?? "")"))
        if profileRuns[index].state == .done {
            if config.agents != nil { refreshDiscovery() }
            var applied = AppliedProfiles.load(paths.appliedProfiles)
            applied.applied[id] = Date()
            try? applied.save(paths.appliedProfiles)
            Log.vm.notice("\(self.name, privacy: .public): \(id, privacy: .public) is set up")
        } else {
            Log.vm.error("\(self.name, privacy: .public): \(id, privacy: .public) failed: \(self.profileRuns[index].message ?? "", privacy: .public)")
        }
    }

    /// Stops the profile being set up (its whole process group in the guest)
    /// and drops the ones waiting. What finished stays.
    func stopProfiles() {
        debug("profiles: stop requested (script process group \(profilePID.map(String.init) ?? "not known yet"))")
        profileQueue.removeAll()
        for i in profileRuns.indices where profileRuns[i].state == .waiting {
            profileRuns[i].fail("Stopped.")
        }
        guard profileRuns.contains(where: { $0.state == .running }) else { return }
        profileStopRequested = true
        if let pid = profilePID { killProfileGroup(pid) }
    }

    /// TERM to the script's group, KILL if it is still there a little later.
    private func killProfileGroup(_ pid: Int) {
        Log.vm.notice("\(self.name, privacy: .public): stopping the profile run")
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.ssh("sudo -n kill -TERM -- -\(pid)", timeout: 15)
            await self.env.clock.sleep(seconds: 5)
            guard self.profilePID == pid else { return }
            _ = try? await self.ssh("sudo -n kill -KILL -- -\(pid)", timeout: 15)
        }
    }

    /// The VM stopped: what was still waiting will not run now.
    private func endProfileRuns() {
        profileQueue.removeAll()
        for i in profileRuns.indices where profileRuns[i].state == .waiting {
            profileRuns[i].fail("The VM stopped before this ran.")
        }
    }

    // MARK: Firewall monitor mode

    private func received(_ ask: FirewallAsk) {
        let known = firewallAsks.contains { $0.proto == ask.proto && $0.address == ask.address && $0.port == ask.port }
        guard !known, firewallAsks.count < Self.maxFirewallAsks else { return }
        debug("firewall: monitor mode asks about \(ask.proto.rawValue) \(ask.address):\(ask.port) \(ask.names.joined(separator: " "))")
        firewallAsks.append(ask)
    }

    /// The user answered: in force at once, and for allow and block also
    /// saved (on this VM, or on one of its tags so every VM with it
    /// follows). Settles every question the rule covers.
    func answerFirewall(_ answer: FirewallAnswer, tags: FirewallTagStore) throws {
        guard let ask = firewallAsks.first(where: { $0.id == answer.askID }) else {
            throw MonadError("This question was answered already.")
        }
        guard ask.targets.contains(answer.target) else { throw MonadError("That is not a name or address of this connection.") }
        let rule = Firewall.rule(answering: ask, allow: answer.decision != .block, target: answer.target)
        let what = ask.isLookup ? "a lookup of \(ask.names.first ?? "")" : "\(ask.address):\(ask.port)"
        debug("firewall: answered \(answer.decision) for \(what), saved on \(answer.scope)")
        if answer.decision != .allowUntilStop {
            switch answer.scope {
            case .vm:
                var c = config
                c.firewall.rules.append(rule)
                try c.firewall.validate()
                try update(c)
            case .tag(let name):
                guard config.effectiveFirewall.allTags.contains(name),
                      var tag = try tags.tag(named: name) ?? (name == config.group ? FirewallTag(name: name, rules: []) : nil) else {
                    throw MonadError("“\(name)” is not one of this VM's firewall tags.")
                }
                tag.rules.append(rule)
                try tags.save(tag)
            }
        }
        nic?.answer(rule)
        firewallAsks.removeAll { $0.id == ask.id || rule.answers($0) }
    }

    private func endFirewallSession() {
        nic?.forgetSession()
        firewallAsks = []
    }

    // MARK: Runtime events

    private func handle(_ event: VMRuntimeEvent) {
        // Whichever way, the machine no longer runs.
        try? FileManager.default.removeItem(at: paths.runningMark)
        switch event {
        case .stopped:
            debug("machine: " + (poweringOffByMonad ? "powered off by Monad"
                                 : state == .stopping ? "the guest shut down as asked"
                                 : "the guest powered itself off (Monad did not ask it to)"))
        case .failed(let message):
            debug("machine: Virtualization stopped it with an error: \(message)")
        }
        switch event {
        case .stopped:
            Log.vm.info("\(self.name, privacy: .public) stopped")
            lifecycleTask?.cancel()
            // Off before Monad reached it, and not asked to: a failed boot.
            let failedBoot = !poweringOffByMonad && (state == .starting || state == .booting)
            let message = "The guest powered itself off before Monad could reach it. See \(paths.serialLog.path)"
            if failedBoot { state = .failed(message) }
            finishStop()
            if failedBoot { Task { [weak self] in await self?.addDiskCheck(to: message) } }
        case .failed(let message):
            lifecycleTask?.cancel()
            endFirewallSession()
            endProfileRuns()
            disconnectGuest()
            machine?.stopBridge()
            state = .failed(message)
        }
    }
}
