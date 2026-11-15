//
//  SSHHostsView.swift — Virtual Machines › SSH: the servers Monad opens
//  tabs on and carries ports to and from, and the sheet that adds or
//  changes one. They are MonadHost's (this view mirrors them through
//  HostClient); a typed password goes to MonadHost for the Keychain and is
//  never shown again.
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
        let made = SSHHost(name: name, host: trimmed(host), port: number, user: trimmed(user), auth: auth, keyPath: key,
                           jump: jump)
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

    /// The forwards carried through the host that are not up.
    static func failedForwards(_ snapshot: SSHHostSnapshot) -> Int {
        (snapshot.forwards ?? []).filter { if case .failed = $0.state { return true } else { return false } }.count
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
                .help("Host, user and how Monad signs in")
            Menu {
                if snapshot.config.auth == .generated {
                    Button(snapshot.config.keyInstalled ? "Install Key Again…" : "Install Key…") { installKey() }
                        .disabled(installing)
                }
                if snapshot.hasPassword {
                    Button("Forget Password") { run { try await host.forgetSSHPassword(name) } }
                }
                if SSHHostDraft.failedForwards(snapshot) > 0 {
                    Button("Connect Forwards Again") { run { try await host.connectSSHHost(name) } }
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
    @StateObject private var submission = SheetSubmission()

    init(editing: SSHHost?, hosts: [SSHHost], onSave: @escaping (SSHHost, String?) async throws -> SSHHost,
         onInstallKey: @escaping (String) async throws -> Void, onClose: @escaping () -> Void) {
        self.editing = editing
        self.hosts = hosts
        self.onSave = onSave
        self.onInstallKey = onInstallKey
        self.onClose = onClose
        _draft = State(initialValue: SSHHostDraft(editing))
        _taken = State(initialValue: hosts.map(\.name))
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
