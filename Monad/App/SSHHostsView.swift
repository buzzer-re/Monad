//
//  SSHHostsView.swift — Virtual Machines › SSH: the servers Monad opens
//  tabs on and carries ports to and from, and the sheet that adds or
//  changes one (how Monad signs in, the host's own forwards, and Monad's
//  agent on the server, asked about before it goes there). They are
//  MonadHost's (this view mirrors them through HostClient); a typed
//  password goes to MonadHost for the Keychain and is never shown again.
//

import AppKit
import SwiftUI

/// The sheet's fields as typed, and the SSH host they make.
struct SSHHostDraft: Equatable {
    var name = ""
    var host = ""
    /// Empty: 22.
    var port = ""
    var user = ""
    /// nil: directly.
    var jump: String?
    var auth = SSHHost.Auth.password
    /// A private key: one file (`keyPath`), or ssh's own keys and agent.
    var usesKeyFile = false
    var keyPath = ""
    /// Monad's agent on the server: its ports forwarded by themselves.
    /// Set only once the user said yes (SSHHostAgent.question).
    var agent = false
    /// Ports the automatic forwards skip, as typed ("5432, 6379").
    var ignoredPorts = ""
    /// Its own forwards, between this Mac and the server.
    var forwards: [ForwardRule] = []
    /// What the sheet does not show of the automatic forwards (where they start).
    private(set) var autoForward = AutoForwardSettings()
    /// A host being changed keeps its name (the name is its identity).
    let isNew: Bool

    init(_ host: SSHHost?, user: String = NSUserName()) {
        isNew = host == nil
        guard let host else {
            self.user = user
            return
        }
        name = host.name
        self.host = host.host
        port = host.port == 22 ? "" : String(host.port)
        self.user = host.user
        jump = host.jump
        auth = host.auth
        usesKeyFile = host.keyPath != nil
        keyPath = host.keyPath ?? ""
        agent = host.agent
        autoForward = host.autoForward
        ignoredPorts = VMSettingsDraft.text(host.autoForward.ignoredPorts)
        forwards = host.forwards
    }

    /// The host as typed, checked. `taken`: the names there are (a new
    /// host must not take one); `home`: what "~" in a key's path stands for.
    func build(taken: [String] = [], home: String = NSHomeDirectory()) throws -> SSHHost {
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        let name = trimmed(self.name)
        if isNew, let other = taken.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw MonadError("An SSH host named \(other) exists already.")
        }
        var number = 22
        if !trimmed(port).isEmpty {
            guard let typed = Int(trimmed(port)) else { throw MonadError("“\(trimmed(port))” is not a port number.") }
            number = typed
        }
        var key: String?
        if auth == .key, usesKeyFile {
            let path = trimmed(keyPath)
            guard !path.isEmpty else { throw MonadError("Choose a key file, or use ssh's own keys and agent.") }
            key = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        }
        var auto = autoForward
        auto.ignoredPorts = try VMSettingsDraft.ports(ignoredPorts)
        let made = SSHHost(name: name, host: trimmed(host), port: number, user: trimmed(user), auth: auth, keyPath: key,
                           jump: jump, agent: agent, autoForward: auto, forwards: forwards)
        try made.validate()
        return made
    }

    /// A row's second line: "dev@example.com:2222 through bastion".
    static func summary(_ snapshot: SSHHostSnapshot) -> String {
        let c = snapshot.config
        var text = c.port == 22 ? "\(c.user)@\(c.host)" : "\(c.user)@\(SSHMux.address(c.host)):\(c.port)"
        if let jump = c.jump { text += " through \(jump)" }
        return text
    }

    /// How a row says the host signs in.
    static func signIn(_ snapshot: SSHHostSnapshot) -> String {
        switch snapshot.config.auth {
        case .password: return snapshot.hasPassword ? "Password in Keychain" : "Password asked each time"
        case .key: return "Private key"
        case .generated: return snapshot.config.keyInstalled ? "Monad's key" : "Monad's key, not installed yet"
        }
    }

    /// The forwards carried through the host that are not up (the VMs' and
    /// its own: an automatic one that is not, mostly for a Mac port already
    /// in use, is skipped rather than broken, and says so in the sheet).
    static func failedForwards(_ snapshot: SSHHostSnapshot) -> Int {
        (snapshot.forwards ?? []).filter {
            if $0.origin != .auto, case .failed = $0.state { return true } else { return false }
        }.count
    }

    /// How a row says the host's agent is doing; nil without one.
    static func agentTag(_ snapshot: SSHHostSnapshot) -> (text: String, problem: Bool)? {
        guard snapshot.config.agent else { return nil }
        return snapshot.agentRunning == true ? ("Agent running", false) : ("Agent not running", true)
    }

    /// Whether Connect Again has something to do: a forward is not up, or
    /// the agent is not running.
    static func canReconnect(_ snapshot: SSHHostSnapshot) -> Bool {
        failedForwards(snapshot) > 0 || (snapshot.config.agent && snapshot.agentRunning != true)
    }

    /// The Mac port of an automatic forward ("127.0.0.1:8080:127.0.0.1:8080").
    static func macPort(ofAutoForward spec: String) -> String {
        spec.split(separator: ":").dropFirst().first.map(String.init) ?? "?"
    }

    /// How one of the host's own forwards is doing, in the sheet: `saved`
    /// is the host as MonadHost has it (nil: not saved yet).
    static func state(of rule: ForwardRule, saved: SSHHostSnapshot?) -> (text: String, problem: Bool) {
        guard rule.enabled else { return ("Off", false) }
        guard let saved, saved.config.forwards.contains(rule) else { return ("Not saved yet", false) }
        switch VMSettingsDraft.status(of: rule, in: saved.forwards ?? [])?.state {
        case .active?: return ("Active", false)
        case .failed(let why)?: return (why, true)
        case nil: return ("Not connected", false)
        }
    }
}

/// The SSH hosts, a row each.
struct SSHHostsTab: View {
    @ObservedObject var host: HostClient
    var onEdit: (SSHHost?) -> Void
    var onError: (String) -> Void

    var body: some View {
        if host.sshHosts.isEmpty {
            ContentUnavailableView {
                Label("No SSH hosts", systemImage: "server.rack")
            } description: {
                Text("Add a server to open tabs on it and to carry ports between it and your VMs.")
            } actions: {
                Button("New SSH Host…") { onEdit(nil) }.controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(host.sshHosts) { snapshot in
                    SSHHostRow(snapshot: snapshot, host: host, onEdit: { onEdit(snapshot.config) }, onError: onError)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
        }
    }
}

private struct SSHHostRow: View {
    let snapshot: SSHHostSnapshot
    let host: HostClient
    var onEdit: () -> Void
    var onError: (String) -> Void
    @State private var confirmDelete = false
    @State private var installing = false

    private var name: String { snapshot.config.name }

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: "server.rack", color: .teal, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Flow(spacing: 8) {
                    Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    TagLabel(text: SSHHostDraft.signIn(snapshot),
                             color: snapshot.config.auth == .generated && !snapshot.config.keyInstalled ? .orange : .secondary)
                    if let agent = SSHHostDraft.agentTag(snapshot) {
                        TagLabel(text: agent.text, color: agent.problem ? .orange : .secondary)
                    }
                    if let forwards = snapshot.forwards, !forwards.isEmpty {
                        TagLabel(text: "\(forwards.count) forward\(forwards.count == 1 ? "" : "s")")
                        let failed = SSHHostDraft.failedForwards(snapshot)
                        if failed > 0 { TagLabel(text: "\(failed) failed", color: .red) }
                    }
                }
                Text(SSHHostDraft.summary(snapshot)).font(Design.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if installing {
                    Text("Installing Monad's key. Monad asks in a panel of its own for what the server needs.")
                        .font(Design.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if installing { ProgressView().controlSize(.small) }
            Button("Open Tab") { (NSApp.delegate as? AppDelegate)?.open(.ssh(name)) }
            Button(action: onEdit) { Image(systemName: "slider.horizontal.3") }
                .help("Host, user, how Monad signs in, and its port forwarding")
            Menu {
                if snapshot.config.auth == .generated {
                    Button(snapshot.config.keyInstalled ? "Install Key Again…" : "Install Key…") { installKey() }
                        .disabled(installing)
                }
                if snapshot.hasPassword {
                    Button("Forget Password") { run { try await host.forgetSSHPassword(name) } }
                }
                if SSHHostDraft.canReconnect(snapshot) {
                    Button("Connect Again") { run { try await host.connectSSHHost(name) } }
                }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .controlSize(.large)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { onEdit() })
        .confirmationDialog("Delete the SSH host “\(name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { run { try await host.removeSSHHost(name) } }
        } message: {
            Text("Monad forgets it, its password and its key. The server keeps the key in authorized_keys until you remove it there.")
        }
    }

    private func installKey() {
        installing = true
        run {
            defer { installing = false }
            try await host.installSSHKey(name)
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await action() } catch { onError(HostAgent.describe(error)) }
        }
    }
}

/// New SSH Host, and an SSH host's settings.
struct SSHHostSheet: View {
    let editing: SSHHost?
    /// Every SSH host there is (the names taken, and those to connect through).
    let hosts: [SSHHost]
    /// The host being changed as MonadHost has it now (its forwards, its
    /// agent); nil for a new one.
    var status: SSHHostSnapshot?
    /// Saves the host with the password typed (nil: none typed) and says
    /// how MonadHost has it now; throws to keep the sheet open with the reason.
    var onSave: (SSHHost, String?) async throws -> SSHHost
    /// Installs Monad's key on the saved host (it waits for the user's answers).
    var onInstallKey: (String) async throws -> Void
    /// Cancelled, or saved: the caller closes the sheet.
    var onClose: () -> Void

    @State private var draft: SSHHostDraft
    @State private var password = ""
    /// Saved from this sheet already (only the key's install failed).
    @State private var saved = false
    /// The names taken when the sheet opened: a host this sheet saved (even
    /// when the save then said why something else failed) is not in the way of itself.
    @State private var taken: [String]
    /// The agent is asked about before it goes onto the server.
    @State private var askingAgent = false
    @State private var addingForward = false
    @StateObject private var submission = SheetSubmission()

    init(editing: SSHHost?, hosts: [SSHHost], status: SSHHostSnapshot? = nil,
         onSave: @escaping (SSHHost, String?) async throws -> SSHHost,
         onInstallKey: @escaping (String) async throws -> Void, onClose: @escaping () -> Void) {
        self.editing = editing
        self.hosts = hosts
        self.status = status
        self.onSave = onSave
        self.onInstallKey = onInstallKey
        self.onClose = onClose
        _draft = State(initialValue: SSHHostDraft(editing))
        _taken = State(initialValue: hosts.map(\.name))
    }

    /// Turning automatic forwards on puts Monad's agent on the server:
    /// only after the user's yes. Off needs no question.
    private var agentChoice: Binding<Bool> {
        Binding(get: { draft.agent }, set: { on in
            if on { askingAgent = true } else { draft.agent = false }
        })
    }

    private var agentQuestion: (title: String, message: String) {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        return SSHHostAgent.question(host: name.isEmpty ? "this server" : name,
                                     user: draft.user.trimmingCharacters(in: .whitespaces))
    }

    /// The hosts this one may connect through: others, themselves reached directly.
    private var jumpChoices: [String] {
        hosts.filter { $0.name != editing?.name && $0.jump == nil }.map(\.name)
    }

    /// Others connect through this host: it cannot connect through another.
    private var isJumpedThrough: Bool {
        guard let editing else { return false }
        return hosts.contains { $0.jump == editing.name }
    }

    /// Whether Save goes on to install Monad's key: the server does not have it yet.
    private var installsKey: Bool {
        guard draft.auth == .generated else { return false }
        let current = hosts.first { $0.name == draft.name.trimmingCharacters(in: .whitespaces) }
        return !(current?.auth == .generated && current?.keyInstalled == true)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "server.rack", color: .teal, title: editing == nil ? "New SSH host" : "SSH host “\(draft.name)”",
                       subtitle: "A server reached over ssh. Monad reads no ssh config file for it.")
                .padding(.horizontal, 24).padding(.top, 18)
            Form {
                Section("Server") {
                    TextField("Name", text: $draft.name, prompt: Text("box"))
                        .disabled(editing != nil || saved)
                        .help(editing != nil ? "The name is the host's identity in Monad: tabs and forwards use it." : "")
                    TextField("Host", text: $draft.host, prompt: Text("example.com"))
                    TextField("Port", text: $draft.port, prompt: Text("22"))
                    TextField("User", text: $draft.user)
                    Picker("Connect through", selection: $draft.jump) {
                        Text("Directly").tag(String?.none)
                        ForEach(jumpChoices, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .disabled(isJumpedThrough)
                    .help(isJumpedThrough ? "Other SSH hosts connect through this one." : "")
                }
                Section("Sign in") {
                    Picker("Sign in with", selection: $draft.auth) {
                        Text("Password").tag(SSHHost.Auth.password)
                        Text("Private key").tag(SSHHost.Auth.key)
                        Text("Key pair from Monad").tag(SSHHost.Auth.generated)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch draft.auth {
                    case .password:
                        SecureField("Password", text: $password)
                        Text("Kept in your login Keychain, never in Monad's files. Leave it empty to be asked when it first connects.")
                            .font(Design.caption).foregroundStyle(.secondary)
                    case .key:
                        Picker("Key", selection: $draft.usesKeyFile) {
                            Text("ssh's own keys and agent").tag(false)
                            Text("A key file").tag(true)
                        }
                        if draft.usesKeyFile {
                            HStack {
                                TextField("Key file", text: $draft.keyPath, prompt: Text("~/.ssh/id_ed25519"))
                                Button("Choose…", action: chooseKey)
                            }
                        }
                        Text("A passphrase is asked in a panel of Monad's.")
                            .font(Design.caption).foregroundStyle(.secondary)
                    case .generated:
                        Text("Monad makes a key pair for this server only and installs its public half with ssh-copy-id. "
                             + "The server may ask for your password once, in a panel of Monad's; after that the key signs in.")
                            .font(Design.caption).foregroundStyle(.secondary)
                    }
                }
                forwarding
            }
            .formStyle(.grouped)
            .font(Design.body)
            Divider()
            SubmissionError(message: submission.error)
            HStack {
                if submission.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(saved ? "Close" : "Cancel", role: .cancel) { onClose() }.keyboardShortcut(.cancelAction)
                Button(installsKey ? "Save and Install Key" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(submission.busy)
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        // A grouped form has no height of its own in a sheet.
        .frame(width: 520, height: 640)
        .confirmationDialog(agentQuestion.title, isPresented: $askingAgent, titleVisibility: .visible) {
            Button("Put the Agent There") { draft.agent = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(agentQuestion.message)
        }
        .sheet(isPresented: $addingForward) {
            ForwardEditor(side: .server) { rule in
                draft.forwards.append(rule)
                addingForward = false
            } onCancel: { addingForward = false }
        }
    }

    /// The host's own forwards, and the automatic ones its agent makes.
    @ViewBuilder private var forwarding: some View {
        Section {
            Toggle(isOn: agentChoice) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Forward ports automatically")
                    Text("Ports from \(draft.autoForward.minimumPort) up that the server listens on are reachable on this Mac's "
                         + "localhost, while Monad is open or a VM runs. Monad's agent on the server says which.")
                        .font(Design.caption).foregroundStyle(.secondary)
                }
            }
            if draft.agent {
                TextField("Ports to skip", text: $draft.ignoredPorts, prompt: Text("5432, 6379"))
                agentState
            }
            ForEach($draft.forwards) { $rule in
                let state = SSHHostDraft.state(of: rule, saved: status)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(VMSettingsDraft.describe(rule, side: .server))
                        Text(state.text).font(Design.caption).foregroundStyle(state.problem ? Color.red : Color.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Button(role: .destructive) {
                        draft.forwards.removeAll { $0.id == rule.id }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            Button { addingForward = true } label: { Label("Add Forward…", systemImage: "plus") }
        } header: {
            Text("Port forwarding")
        }
    }

    /// How the agent is doing on the host as it is saved, and what it forwards now.
    @ViewBuilder private var agentState: some View {
        if let status, status.config.agent {
            if status.agentRunning == true {
                let auto = (status.forwards ?? []).filter { $0.origin == .auto }
                if auto.isEmpty {
                    Text("The agent is running. No ports forwarded right now.").font(Design.caption).foregroundStyle(.secondary)
                }
                ForEach(auto, id: \.spec) { forward in
                    HStack {
                        Image(systemName: "arrow.right.circle.fill").foregroundStyle(.indigo)
                        Text("localhost:\(SSHHostDraft.macPort(ofAutoForward: forward.spec))").font(Design.body.monospacedDigit())
                        Spacer()
                        switch forward.state {
                        case .active: Text("Active").font(Design.caption).foregroundStyle(.green)
                        case .failed(let why): Text(why).font(Design.caption).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                }
                if let over = status.portsOverLimit {
                    Label("\(over) more \(over == 1 ? "port is" : "ports are") not forwarded. Monad forwards at most \(ForwardPlan.maxAutoForwards) per server, lowest first.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Design.caption).foregroundStyle(.orange)
                }
            } else {
                Label(status.agentProblem ?? "The agent is not running: Monad is not connected to the server. "
                        + "Connect Again is in the host's ⋯ menu.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Design.caption).foregroundStyle(.orange)
            }
        } else {
            Text("The agent goes onto the server when you save.").font(Design.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        let typed = draft.auth == .password ? password : ""
        Task {
            await submission.submit {
                let host = try draft.build(taken: taken)
                let now = try await onSave(host, typed.isEmpty ? nil : typed)
                saved = true
                password = ""
                // The host stays saved when only the install fails; its row then offers Install Key.
                if now.auth == .generated, !now.keyInstalled { try await onInstallKey(now.name) }
                onClose()
            }
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = Paths.home.appendingPathComponent(".ssh", isDirectory: true)
        panel.prompt = "Choose"
        panel.message = "The private key to sign in with (not its .pub file)."
        if panel.runModal() == .OK, let url = panel.url { draft.keyPath = url.path }
    }
}

#if DEBUG
#Preview("New SSH host") {
    SSHHostSheet(editing: nil, hosts: [], onSave: { host, _ in host }, onInstallKey: { _ in }, onClose: {})
}
#endif
