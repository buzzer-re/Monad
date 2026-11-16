//
//  SSHHostManager.swift — MonadHost's side of SSH hosts: it owns their
//  files (~/.monad/ssh-hosts), their passwords in the Keychain and Monad's
//  key pairs, answers the questions of every ssh Monad starts for them
//  (SSHAskpass), and installs a key with ssh-copy-id.
//
//  It also keeps one ssh master per host that carries anything, while
//  MonadHost runs: the VMs' forwards through the host (SSHForward), the
//  host's own forwards to this Mac, and, with the user's yes, Monad's
//  agent on the server (SSHHostAgent), whose ports come to this Mac's
//  localhost by themselves like a VM's.
//
//  The app only mirrors what `snapshots` says (HostClient) and never sees a
//  password: a typed one comes in over XPC and goes to the Keychain.
//

import Foundation
import os

@MainActor
final class SSHHostManager {
    struct Environment {
        var runner: CommandRunning = LoggingCommandRunner(SystemCommandRunner())
        var secrets: SecretStoring = KeychainSecrets()
        var clock: MonadClock = SystemClock()
        /// Supervises ssh masters; nil means kqueue.
        var watcher: ProcessExitWatching? = nil
        /// This build's MonadHost, as ssh's askpass.
        var helper: String = SSHAskpass.helperPath
        var home: URL = Paths.home
        /// The user's ssh-agent, for installing a key and for hosts that
        /// sign in with ssh's own keys.
        var agentSocket: String? = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        var debugLog: DebugLog = .shared
        /// Runs an agent on a server: ssh, its input and output one stream.
        var channels: ChannelSpawning = ProcessChannelSpawner()
        /// The agent's script for a server's system (nil: Monad has none).
        var agentScript: @Sendable (SSHHostAgent.System) -> String? = SSHHostAgent.script(for:)
    }

    static let shared = SSHHostManager()

    let root: URL
    private let env: Environment
    private let store: SSHHostStore
    /// By name.
    private(set) var hosts: [SSHHost]
    let prompts: SSHPrompts
    private let tickets: SSHTickets
    /// The hosts changed, or what is known about them (HostService tells the apps).
    var onChange: (([SSHHostSnapshot]) -> Void)?
    private var installing = Set<String>()

    // One ssh master per host that carries anything, kept by a
    // ForwardManager as a VM's is: the VMs' forwards through the host
    // (SSHForward), the host's own, and those its agent's ports make.
    /// What each VM wants, by VM.
    private var wanted: [String: [SSHLeg]] = [:]
    /// By host: its master's manager, the forwards as they are, and what
    /// was last applied (the same again does nothing).
    private var links: [String: ForwardManager] = [:]
    private var statuses: [String: [ForwardStatus]] = [:]
    private var overLimit: [String: Int] = [:]
    private var applied: [String: Applied] = [:]

    /// Everything a host's master is made to carry.
    private struct Applied: Equatable {
        var legs: Set<SSHLeg>
        var rules: [ForwardRule]
        var autoForward: AutoForwardSettings
        var ports: Set<ListeningPort>
        var agent: Bool
    }

    // Monad's agent on the hosts that have one (SSHHostAgent), by host: the
    // loop that keeps it running while a master is up (and which run of it
    // that is), the agent while it is connected, and what it reported.
    private var agentTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var agents: [String: AgentClient] = [:]
    private var agentPorts: [String: Set<ListeningPort>] = [:]
    private var agentProblems: [String: String] = [:]
    /// A connection to an agent that lasted this long was a working one.
    static let healthyAgentConnection: TimeInterval = 10
    /// One thing at a time per host: a master ended before the next starts.
    private var work: [String: Task<Void, Never>] = [:]
    /// The ticket of each host's master as it last started, and the ticket
    /// behind each waiting question: a master no longer wanted takes its
    /// questions with it.
    private var masterTicket: [String: String] = [:]
    private var questions: [UUID: String] = [:]

    init(root: URL = Paths.sshHosts, environment: Environment = Environment()) {
        self.root = root
        env = environment
        store = SSHHostStore(root: root)
        hosts = store.all()
        prompts = SSHPrompts(clock: environment.clock)
        tickets = SSHTickets(clock: environment.clock)
    }

    /// MonadHost, as it starts: a master left by a MonadHost that ended
    /// has forwards nothing here knows about. (Not at init: the app and
    /// tests make managers too, beside a MonadHost whose masters are in use.)
    func endLeftoverMasters() {
        for host in hosts where FileManager.default.fileExists(atPath: paths(host.name).controlSocket.path) {
            enqueue(host.name) { [weak self] in await self?.endMaster(host) }
        }
    }

    /// MonadHost, once it serves: the hosts with an agent or forwards of
    /// their own are connected to while it runs.
    func connectHosts() {
        for host in hosts where host.keepsConnection { sync(host.name) }
    }

    /// MonadHost, as it ends: no master outlives it (a forward on a Mac
    /// port would stay with nothing left to say whose it is).
    func stopAll() async {
        for host in hosts {
            interrupt(host.name)
            await enqueue(host.name) { [weak self] in await self?.tearDown(host) }.value
        }
    }

    var snapshots: [SSHHostSnapshot] {
        hosts.map { host in
            let name = host.name
            let forwards = statuses[name] ?? []
            return SSHHostSnapshot(config: host,
                                   hasPassword: host.auth == .password && env.secrets.hasPassword(for: name),
                                   forwards: forwards.isEmpty ? nil : forwards,
                                   agentRunning: host.agent ? agents[name]?.version != nil : nil,
                                   agentProblem: host.agent ? agentProblems[name] : nil,
                                   portsOverLimit: overLimit[name].flatMap { $0 > 0 ? $0 : nil })
        }
    }

    func host(named name: String) -> SSHHost? { hosts.first { $0.name == name } }

    private func existing(_ name: String) throws -> SSHHost {
        guard let host = host(named: name) else { throw MonadError("No SSH host named \(name).") }
        return host
    }

    private func paths(_ name: String) -> InstancePaths { store.paths(name) }

    private func changed() { onChange?(snapshots) }

    /// ssh's options for a run to `host`, through its jump host if it has one.
    private func arguments(_ host: SSHHost, purpose: SSHHostPurpose = .session) -> [String] {
        SSHHost.sshArguments(host, root: root, home: env.home, jump: host.jump.flatMap { self.host(named: $0) },
                             purpose: purpose)
    }

    /// What an ssh Monad starts for `name` gets: its questions come here.
    private func askpassEnvironment(for name: String) -> [String: String] {
        var out = SSHAskpass.environment(ticket: tickets.issue(for: name), helper: env.helper)
        if let agent = env.agentSocket { out["SSH_AUTH_SOCK"] = agent }
        return out
    }

    /// Ends the host's ssh master, if one runs, and removes its socket.
    private func endMaster(_ host: SSHHost) async {
        let socket = paths(host.name).controlSocket
        guard FileManager.default.fileExists(atPath: socket.path) else { return }
        _ = try? await env.runner.run("/usr/bin/ssh", arguments(host) + [
            "-o", "ControlPath=" + SSHHost.optionValue(path: socket.path), "-O", "exit", host.host,
        ], timeout: 5)
        try? FileManager.default.removeItem(at: socket)
    }

    // MARK: Changes

    /// Adds a host or changes the one of this name. `password` (a
    /// password host's, typed by the user) goes to the Keychain.
    func set(_ incoming: SSHHost, password: String?) async throws {
        var host = incoming
        host.version = SSHHost.currentVersion
        try host.validate()
        let password = password.flatMap { $0.isEmpty ? nil : $0 }
        if let password, !SSHAskpass.isAnswerable(password) {
            throw MonadError("A password is one line of at most \(SSHAskpass.maxSecretBytes) bytes.")
        }
        let old = self.host(named: host.name)
        if old == nil {
            guard hosts.count < SSHHost.maxHosts else {
                throw MonadError("Monad keeps at most \(SSHHost.maxHosts) SSH hosts.")
            }
            if let other = hosts.first(where: { $0.name.caseInsensitiveCompare(host.name) == .orderedSame }) {
                throw MonadError("An SSH host named \(other.name) exists already.")
            }
        }
        if let jump = host.jump {
            guard let through = self.host(named: jump) else {
                throw MonadError("“\(jump)” is not an SSH host to connect through.")
            }
            guard through.jump == nil, !hosts.contains(where: { $0.jump == host.name }) else {
                throw MonadError("An SSH host used to connect through cannot connect through another.")
            }
        }
        // Whether the server has Monad's key is MonadHost's to say.
        host.keyInstalled = false
        if host.auth == .generated, let old, old.auth == .generated, old.keyInstalled, old.host == host.host,
           old.port == host.port, old.user == host.user {
            host.keyInstalled = true
        }

        try Paths.ensurePrivateDirectory(paths(host.name).dir)
        if host.auth == .generated {
            try await CloudInit.ensureKeyPair(paths(host.name), name: "ssh-" + host.name, runner: env.runner)
        } else {
            try? FileManager.default.removeItem(at: paths(host.name).privateKey)
            try? FileManager.default.removeItem(at: paths(host.name).publicKey)
        }
        try store.save(host)
        hosts.removeAll { $0.name == host.name }
        hosts.append(host)
        hosts.sort { $0.name < $1.name }
        defer { changed() }
        // Another server, account or way in: its master and those that
        // connect through it start again. Anything else (a host that is
        // new and may be one forwards were waiting for, its own forwards,
        // its agent): its master carries what is wanted now. An agent
        // turned off is taken from the server first.
        let agentGone = old.map { $0.agent && !host.agent } ?? false
        if let old, old.host != host.host || old.port != host.port || old.user != host.user || old.auth != host.auth
            || old.keyPath != host.keyPath || old.jump != host.jump {
            for name in [host.name] + hosts.filter({ $0.jump == host.name }).map(\.name) {
                guard let current = self.host(named: name) else { continue }
                interrupt(name)
                enqueue(name) { [weak self] in
                    if name == host.name, agentGone { await self?.removeAgent(old) }
                    await self?.tearDown(name == host.name ? old : current)
                    await self?.reconcile(name, force: true)
                }
            }
        } else {
            if let old, agentGone { enqueue(host.name) { [weak self] in await self?.removeAgent(old) } }
            sync(host.name)
        }
        if host.auth != .password {
            try? env.secrets.removePassword(for: host.name)
        } else if let password {
            // The host is saved either way; without the Keychain it asks each time.
            try env.secrets.setPassword(password, for: host.name)
        }
    }

    /// VM forwards naming it stay, and say that it is missing.
    func remove(_ name: String) async throws {
        let host = try existing(name)
        if let dependent = hosts.first(where: { $0.jump == name }) {
            throw MonadError("\(dependent.name) connects through it.")
        }
        tickets.forget(host: name)
        try? env.secrets.removePassword(for: name)
        interrupt(name)
        await enqueue(name) { [weak self] in
            if host.agent { await self?.removeAgent(host) }
            await self?.tearDown(host)
        }.value
        try store.delete(name)
        hosts.removeAll { $0.name == name }
        changed()
    }

    func forgetPassword(_ name: String) throws {
        _ = try existing(name)
        try env.secrets.removePassword(for: name)
        changed()
    }

    /// The host's connection tried again (after a question went unanswered,
    /// or the server came back), and its agent with it.
    func reconnect(_ name: String) throws {
        _ = try existing(name)
        sync(name, force: true)
    }

    // MARK: Forwards

    /// What the VMs want of `name`'s master.
    private func legs(for name: String) -> Set<SSHLeg> {
        Set(wanted.values.joined().filter { $0.host == name })
    }

    @discardableResult
    private func enqueue(_ name: String, _ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = work[name]
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        work[name] = task
        return task
    }

    private func sync(_ name: String, force: Bool = false) {
        enqueue(name) { [weak self] in await self?.reconcile(name, force: force) }
    }

    /// Makes `name`'s master carry what is wanted of it now: the VMs' legs,
    /// the host's own forwards, and the ports its agent reports. Nothing
    /// happens when that is what was applied last (a VM applies its
    /// forwards at every change of its ports; that must not sign in again
    /// or ask anything); no master when nothing wants one.
    private func reconcile(_ name: String, force: Bool) async {
        guard let host = host(named: name) else { return }
        let legs = legs(for: name)
        guard !legs.isEmpty || host.keepsConnection else { return await tearDown(host) }
        let now = Applied(legs: legs, rules: host.forwards, autoForward: host.effectiveAutoForward,
                          ports: host.agent ? agentPorts[name] ?? [] : [], agent: host.agent)
        let before = applied[name]
        if force || before != now {
            applied[name] = now
            let link = links[name] ?? makeLink(host)
            links[name] = link
            // Only the server's ports changed: applied as often as a VM's are.
            var portsOnly = false
            if !force, var same = before {
                same.ports = now.ports
                portsOnly = same == now
            }
            // A port a VM's forward makes the server listen on is that VM's:
            // the agent reports it too, and it never comes to the Mac by itself.
            let bridges = legs.sorted { ($0.spec.flag, $0.spec.value) < ($1.spec.flag, $1.spec.value) }
                .map { ForwardPlan.Bridge(spec: $0.spec, guestPort: $0.listensOn) }
            await link.apply(configured: host.forwards, autoForward: now.autoForward, ports: now.ports, bridges: bridges,
                             guestEvent: portsOnly, keepMaster: host.agent)
        }
        ensureAgent(name, again: force)
    }

    private func makeLink(_ host: SSHHost) -> ForwardManager {
        let name = host.name
        let control = SSHHost.optionValue(path: paths(name).controlSocket.path)
        // The master may ask (a password, a host key): through Monad's
        // askpass, and it may wait for the user's answers.
        let mux = SSHMux(paths: paths(name), host: host.host, options: arguments(host) + ["-o", "ControlPath=" + control],
                         interactive: true, startTimeout: 300)
        let link = ForwardManager(mux: mux, runner: env.runner, watcher: env.watcher, clock: env.clock,
                                  debugLog: env.debugLog, debugScope: "ssh \(name)", holder: "the SSH host \(name)",
                                  target: "the SSH host \(name)")
        link.masterEnvironment = { [weak self] in
            guard let self else { return [:] }
            let environment = self.askpassEnvironment(for: name)
            self.masterTicket[name] = environment[SSHAskpass.ticketVariable]
            return environment
        }
        link.onChange = { [weak self] statuses, overLimit in
            guard let self, self.links[name] === link else { return }
            self.statuses[name] = statuses
            self.overLimit[name] = overLimit
            self.changed()
        }
        // Up: the agent can run over it. Gone: the agent's stream ends by
        // itself (runAgent sees to what it had reported).
        link.onMaster = { [weak self] up in
            guard let self, up, self.links[name] === link else { return }
            self.ensureAgent(name, again: true)
        }
        return link
    }

    /// `name`'s master is not wanted as it is: what it waits for (a
    /// question of its start, in the user's face) ends now, so that what
    /// comes next does not wait for it.
    private func interrupt(_ name: String) {
        links[name]?.stop()
        guard let ticket = masterTicket.removeValue(forKey: name) else { return }
        for (id, asked) in questions where asked == ticket { prompts.answer(id, nil, remember: false) }
    }

    private func tearDown(_ host: SSHHost) async {
        let name = host.name
        let hadAgent = agentTasks[name] != nil || agents[name] != nil || agentProblems[name] != nil
        stopAgent(name)
        links[name]?.stop()
        links[name] = nil
        applied[name] = nil
        overLimit[name] = nil
        let had = statuses.removeValue(forKey: name) != nil
        await endMaster(host)
        if had || hadAgent { changed() }
    }

    // MARK: The agent

    /// Monad has no agent for what the server says it is: nothing to try again.
    private struct NoAgent: LocalizedError {
        let said: String
        var errorDescription: String? { "Monad's agent runs on Linux and macOS servers. This one says it is “\(said)”." }
    }

    /// ssh's options for a run over `host`'s master: nothing that could ask.
    private func masterArguments(_ host: SSHHost) -> [String] {
        arguments(host) + ["-o", "ControlPath=" + SSHHost.optionValue(path: paths(host.name).controlSocket.path),
                           "-o", "ControlMaster=no", "-o", "BatchMode=yes"]
    }

    private func agentLog(_ name: String, _ message: String) {
        env.debugLog.log("ssh \(name)", "agent: " + message)
    }

    /// Keeps `name`'s agent running while its master is up, when it is to
    /// have one and none runs. One that was given up on (a server Monad has
    /// no agent for) is tried `again` only with a new connection or at the
    /// user's word, never at every change of a VM's ports.
    private func ensureAgent(_ name: String, again: Bool) {
        guard let host = host(named: name), host.agent, agentTasks[name] == nil, let link = links[name], link.hasMaster,
              again || agentProblems[name] == nil else { return }
        let id = UUID()
        agentTasks[name] = (id, Task { @MainActor [weak self] in
            await self?.runAgent(name, over: link)
            if let self, self.agentTasks[name]?.id == id { self.agentTasks[name] = nil }
        })
    }

    /// The agent on `host`'s server, as a stream: the script for its system
    /// put in ~/.monad there (each time: it then matches this Monad) and run.
    private func openAgent(_ host: SSHHost) async throws -> ByteChannel {
        let ssh = masterArguments(host) + [host.host]
        let probe = try await env.runner.run("/usr/bin/ssh", ssh + [SSHHostAgent.probe], timeout: 30)
        guard probe.status == 0 else {
            throw MonadError("The server did not answer Monad (\(Self.lastLine(probe.stderrString) ?? "ssh exited with status \(probe.status)")).")
        }
        guard let system = SSHHostAgent.System(uname: probe.stdoutString), let script = env.agentScript(system) else {
            throw NoAgent(said: SSHHostAgent.System.said(probe.stdoutString) ?? "nothing")
        }
        let install = try await env.runner.run("/usr/bin/ssh", ssh + [SSHHostAgent.remote(SSHHostAgent.install)],
                                               stdin: Data(script.utf8), timeout: 30)
        guard install.status == 0 else {
            throw MonadError("Monad's agent could not be put on the server (\(Self.lastLine(install.stderrString) ?? "ssh exited with status \(install.status)")).")
        }
        return try env.channels.open("/usr/bin/ssh", ssh + [SSHHostAgent.remote(SSHHostAgent.run(system))], environment: [:])
    }

    /// Runs the agent over `link`'s master until that master, the host or
    /// the wish for an agent is gone; an agent that ends is run again, less
    /// and less often when it ends at once (a broken or hostile server).
    private func runAgent(_ name: String, over link: ForwardManager) async {
        var delay: TimeInterval = 1
        func wanted() -> SSHHost? {
            guard !Task.isCancelled, links[name] === link, link.hasMaster, let host = host(named: name), host.agent else {
                return nil
            }
            return host
        }
        while let host = wanted() {
            let channel: ByteChannel
            do {
                channel = try await openAgent(host)
            } catch {
                guard wanted() != nil else { return }
                agentProblems[name] = error.localizedDescription.plain(limit: 300)
                agentLog(name, agentProblems[name] ?? "")
                changed()
                if error is NoAgent { return }
                await env.clock.sleep(seconds: delay)
                delay = min(delay * 2, 60)
                continue
            }
            guard wanted() != nil else {
                channel.close()
                return
            }
            agentProblems[name] = nil
            let connectedAt = env.clock.now()
            let client = AgentClient(channel: channel)
            agents[name] = client
            let ended = AsyncStream<Void> { continuation in
                client.onDisconnect = { continuation.finish() }
                client.onEvent = { [weak self, weak client] event in
                    guard let self, let client, self.agents[name] === client else { return }
                    if let text = event.debugText { self.agentLog(name, text) }
                    if case .hello = event { self.changed() }
                    guard self.agentPorts[name] ?? [] != client.ports else { return }
                    self.agentPorts[name] = client.ports
                    self.sync(name)
                }
            }
            client.start()
            changed()
            for await _ in ended {}
            // Stopped from here (stopAgent): there is nothing left to see to.
            guard agents[name] === client else { return }
            agents[name] = nil
            agentPorts[name] = nil
            // What it reported is not for a master that starts meanwhile.
            link.forgetPorts()
            changed()
            let lasted = env.clock.now().timeIntervalSince(connectedAt)
            agentLog(name, String(format: "its connection ended after %.1f s", lasted))
            let pause: TimeInterval
            if lasted >= Self.healthyAgentConnection {
                delay = 1
                pause = 0.5
            } else {
                pause = delay
                delay = min(delay * 2, 60)
            }
            await env.clock.sleep(seconds: pause)
            guard !Task.isCancelled, links[name] === link else { return }
            // A master that is still there takes those ports off now. One
            // that went is started again by its ForwardManager, in its own time.
            if link.hasMaster { sync(name) } else { applied[name]?.ports = [] }
        }
    }

    private func stopAgent(_ name: String) {
        agentTasks.removeValue(forKey: name)?.task.cancel()
        agents.removeValue(forKey: name)?.stop()
        agentPorts[name] = nil
        agentProblems[name] = nil
    }

    /// The agent is no longer wanted on `host`: it stops, and its script is
    /// taken from the server while Monad is still connected to it (it
    /// stays there otherwise: a file nothing runs).
    private func removeAgent(_ host: SSHHost) async {
        stopAgent(host.name)
        guard FileManager.default.fileExists(atPath: paths(host.name).controlSocket.path) else { return }
        _ = try? await env.runner.run("/usr/bin/ssh", masterArguments(host) + [host.host, SSHHostAgent.remote(SSHHostAgent.remove)],
                                      timeout: 15)
    }

    // MARK: Questions

    /// A ticket for one ssh run to this host (a tab's, an upload's): the
    /// app puts it in that ssh's environment (SSHAskpass.environment).
    func ticket(for name: String) throws -> String {
        _ = try existing(name)
        return tickets.issue(for: name)
    }

    /// One question of an ssh Monad started, relayed by the askpass helper.
    /// A stored password answers only ssh's own password question for that
    /// user and host, once per connection; everything else is the user's.
    func ask(ticket value: String, prompt: String, hint: String?) async throws -> String {
        guard let ticket = tickets.ticket(value), let host = host(named: ticket.host) else {
            throw MonadError("This question did not come from a connection Monad started.")
        }
        guard let kind = SSHAskpass.kind(prompt: prompt, hint: hint) else { return "" }
        let shown = SSHAskpass.shown(prompt)
        if kind == .secret {
            var candidates = [host]
            if let through = host.jump.flatMap({ self.host(named: $0) }) { candidates.append(through) }
            for candidate in candidates {
                // A Keychain that does not answer leaves the question to the user.
                guard candidate.auth == .password, SSHAskpass.isPasswordPrompt(prompt, for: candidate),
                      !ticket.released.contains(candidate.name),
                      let password = try? env.secrets.password(for: candidate.name) else { continue }
                tickets.update(value) { $0.released.insert(candidate.name); $0.note(answered: shown) }
                return password
            }
        }
        let canRemember = kind == .secret && host.auth == .password && SSHAskpass.isPasswordPrompt(prompt, for: host)
        // The same question again on one connection: the last answer was refused.
        let request = SSHPromptRequest(id: UUID(), host: host.name, kind: kind, prompt: shown, canRemember: canRemember,
                                       retry: kind == .secret && ticket.answered.contains(shown), asked: env.clock.now())
        if kind == .secret { tickets.update(value) { $0.note(answered: shown) } }
        questions[request.id] = value
        let (answer, remember) = await prompts.ask(request)
        questions[request.id] = nil
        guard let answer else { throw MonadError("The question was not answered.") }
        switch kind {
        case .confirm:
            return answer == "yes" ? "yes" : "no"
        case .secret:
            guard SSHAskpass.isAnswerable(answer) else { throw MonadError("The answer is not one line that ssh takes.") }
            // Kept by `answer`: asked again on this connection, the server refused it.
            if remember && canRemember { tickets.update(value) { $0.released.insert(host.name) } }
            return answer
        }
    }

    /// The user's answer to a waiting question (nil: cancelled). A password
    /// to keep goes to the Keychain first; ssh gets the answer even when
    /// the Keychain refuses, and that refusal is then thrown.
    func answer(_ id: UUID, _ answer: String?, remember: Bool) throws {
        guard let request = prompts.pending.first(where: { $0.id == id }) else {
            throw MonadError("That question is no longer waiting (it was answered, or two minutes passed).")
        }
        var problem: Error?
        var kept = false
        if let answer, remember, request.canRemember, SSHAskpass.isAnswerable(answer), !answer.isEmpty {
            do {
                try env.secrets.setPassword(answer, for: request.host)
                kept = true
            } catch {
                problem = error
            }
        }
        prompts.answer(id, answer, remember: remember)
        if kept { changed() }
        if let problem { throw problem }
    }

    // MARK: Monad's key pair

    /// Installs the public half of Monad's key pair on the server with
    /// ssh-copy-id, which signs in with the keys this Mac already has
    /// (default files, the agent) and falls back to the password. That
    /// password is asked in Monad's panel like any question and never kept.
    func installKey(_ name: String) async throws {
        let host = try existing(name)
        guard host.auth == .generated else { throw MonadError("\(name) does not use a key pair of Monad's.") }
        guard installing.insert(name).inserted else { throw MonadError("Monad is already installing the key on \(name).") }
        defer { installing.remove(name) }
        let paths = paths(name)
        try Paths.ensurePrivateDirectory(paths.dir)
        try await CloudInit.ensureKeyPair(paths, name: "ssh-" + name, runner: env.runner)
        // ssh-copy-id keeps its scratch files under ~/.ssh.
        let dotSSH = env.home.appendingPathComponent(".ssh", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dotSSH.path) {
            try FileManager.default.createDirectory(at: dotSSH, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let copied = try await env.runner.run(
            "/usr/bin/ssh-copy-id",
            ["-i", paths.publicKey.path] + arguments(host, purpose: .install) + ["-o", "ControlPath=none", host.host],
            environment: askpassEnvironment(for: name), stdin: nil, timeout: 600)
        guard copied.status == 0 else {
            throw MonadError(Self.lastLine(copied.stderrString) ?? "ssh-copy-id exited with status \(copied.status)")
        }
        let check = try await env.runner.run(
            "/usr/bin/ssh", arguments(host) + ["-o", "ControlPath=none", "-o", "BatchMode=yes", host.host, "true"],
            timeout: 30)
        guard check.status == 0 else {
            throw MonadError("The key was copied, but the server did not accept it: "
                             + (Self.lastLine(check.stderrString) ?? "ssh exited with status \(check.status)"))
        }
        // The host may have changed while the user answered.
        guard var now = self.host(named: name), now.auth == .generated, now.host == host.host, now.port == host.port,
              now.user == host.user else { return }
        now.keyInstalled = true
        try store.save(now)
        hosts = hosts.map { $0.name == name ? now : $0 }
        changed()
    }

    /// The last non-empty line of a tool's complaint, as Monad shows it.
    private static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
            .map { $0.plain(limit: 300) }
    }
}

extension SSHHostManager: SSHLegApplying {
    /// What `vm` wants on the SSH hosts' masters now (nothing once it
    /// stops). Called at every change of the VM's ports too: only a change
    /// of its legs does anything.
    func apply(_ legs: [SSHLeg], for vm: String) {
        let before = wanted[vm] ?? []
        guard legs != before else { return }
        wanted[vm] = legs.isEmpty ? nil : legs
        for name in Set((before + legs).map(\.host)).sorted() {
            // A master nothing wants any more takes its question with it now.
            if self.legs(for: name).isEmpty, host(named: name)?.keepsConnection != true { interrupt(name) }
            sync(name)
        }
    }
}
