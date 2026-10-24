//
//  VMDetailView.swift — one VM's window: overview and controls, resources,
//  network and firewall, connections, shared folders and forwarding, in a
//  System Settings–style sidebar. Edits go to MonadHost as one update; most
//  apply to the running VM at once, and if some need a restart the user is
//  asked whether to restart now.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct VMDetailView: View {
    static let size = NSSize(width: 860, height: 640)

    enum Page: String, CaseIterable, Identifiable {
        case overview, resources, network, security, connections, profiles, folders, forwarding, configuration, log
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .resources: return "Resources"
            case .network: return "Network"
            case .security: return "Security"
            case .connections: return "Connections"
            case .profiles: return "Profiles"
            case .folders: return "Shared Folders"
            case .forwarding: return "Port Forwarding"
            case .configuration: return "Configuration"
            case .log: return "Log"
            }
        }

        var symbol: String {
            switch self {
            case .overview: return "info.circle.fill"
            case .resources: return "cpu.fill"
            case .network: return "network"
            case .security: return "lock.shield.fill"
            case .connections: return "point.3.connected.trianglepath.dotted"
            case .profiles: return "wand.and.stars"
            case .folders: return "folder.fill"
            case .forwarding: return "arrow.left.arrow.right"
            case .configuration: return "curlybraces"
            case .log: return "doc.text.fill"
            }
        }

        var color: Color {
            switch self {
            case .overview: return .gray
            case .resources: return .blue
            case .network: return .indigo
            case .security: return .red
            case .connections: return .orange
            case .profiles: return .pink
            case .folders: return .cyan
            case .forwarding: return .purple
            case .configuration: return .brown
            case .log: return .teal
            }
        }
    }

    @ObservedObject var vm: RemoteVM
    @ObservedObject var host: HostClient
    @State private var page: Page = .overview
    @State private var draft: VMSettingsDraft
    @State private var errorMessage: String?
    @State private var errorTitle = "Could not save"
    @State private var saving = false
    @State private var confirmShare: String?
    @State private var addingForward = false
    /// A failed forward to turn around (a Mac port into the VM), waiting
    /// for the user's word.
    @State private var turning: ForwardRule?
    @State private var addingBridge = false
    @State private var addingHostCommand = false
    @State private var restartPrompt: (title: String, message: String)?
    /// Monad networks the VM can join and the firewall tags there are (read
    /// when the page shows).
    @State private var networks: [NetworkDefinition] = []
    @State private var tags: [FirewallTag] = []
    @State private var profileCatalog = ProfileCatalog(builtIn: [], custom: [])
    /// The Configuration page: its text, the saved settings it was loaded
    /// from, this Mac's facts to check it against, a place to select in it,
    /// and an edit waiting for the user's word.
    @State private var configText = ""
    @State private var configBaseline = ""
    @State private var configMac: VMConfigFile.Mac?
    @State private var configFocus: NSRange?
    @State private var confirmingEdit = false
    /// SIP was switched off: asked first.
    @State private var confirmingSIP = false
    /// A macOS VM's account password, while shown on the Overview.
    @State private var shownPassword: String?

    /// The pages this VM has (Security: macOS only).
    private var pages: [Page] {
        Page.allCases.filter { $0 != .security || vm.config.guestOS == .macos }
    }

    private var networkDetail: String {
        guard let name = draft.networkName else { return "No network device: the VM is offline (after a restart)." }
        if draft.config.networks.first?.isAppleNAT == true {
            return "Apple's NAT: the VM can reach this Mac and your local network. Switch to a Monad network to firewall it."
        }
        return networks.first { $0.name == name }?.kind.summary ?? "The network “\(name)” does not exist any more."
    }

    private let capacity = HostCapacity.current

    /// `configText`: the Configuration page's text to start with (previews).
    init(vm: RemoteVM, host: HostClient, page: Page = .overview, configText: String? = nil) {
        self.vm = vm
        self.host = host
        _page = State(initialValue: page)
        _draft = State(initialValue: VMSettingsDraft(vm.config))
        _configText = State(initialValue: configText ?? "")
    }

    private var exists: Bool { host.instances.contains { $0 === vm } }

    var body: some View {
        if host.hostIsOutdated {
            OutdatedHostGate(host: host)
                .frame(minWidth: 760, minHeight: 520)
        } else {
            settings
        }
    }

    private var settings: some View {
        NavigationSplitView {
            List(pages, selection: $page) { p in
                HStack(spacing: 10) {
                    IconTile(symbol: p.symbol, color: p.color, size: 24)
                    Text(p.title).font(Design.body)
                    Spacer()
                    if p == .folders && vm.sharesError != nil
                        || p == .security && (vm.macSecurity?.problem ?? vm.macSecurity?.accessProblem) != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 2)
                .tag(p)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 260)
            .safeAreaInset(edge: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(vm.name).font(.system(size: 17, weight: .bold))
                    StatusBadge(state: exists ? vm.state : .stopped)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch page {
                    case .overview: overview
                    case .resources: resources
                    case .network: network
                    case .security: security
                    case .connections:
                        ConnectionsPage(vm: vm, host: host) { rule in
                            // Unsaved edits keep it too (a refresh leaves them be).
                            if draft.isDirty { draft.firewallRules.putFirst(rule) }
                        }
                    case .profiles: profiles
                    case .folders: folders
                    case .forwarding: forwarding
                    case .configuration: configuration
                    case .log: VMLogPage(url: vm.paths.vmLog)
                    }
                }
                .formStyle(.grouped)
                .font(Design.body)
                .disabled(!exists)
                // The Configuration page applies its own text; the Log only shows.
                if page != .configuration && page != .log { saveBar }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onReceive(vm.$snapshot) { draft.refresh(from: $0.config) }
        .alert(errorTitle, isPresented: Binding(get: { errorMessage != nil },
                                                      set: { if !$0 { errorMessage = nil; errorTitle = "Could not save" } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(restartPrompt?.title ?? "", isPresented: Binding(get: { restartPrompt != nil },
                                                               set: { if !$0 { restartPrompt = nil } })) {
            Button("Restart Now") { restart() }
            Button("Later", role: .cancel) {}
        } message: {
            Text(restartPrompt?.message ?? "")
        }
        .confirmationDialog("Share “\(URL(fileURLWithPath: confirmShare ?? "/").lastPathComponent)”?",
                            isPresented: Binding(get: { confirmShare != nil }, set: { if !$0 { confirmShare = nil } })) {
            Button("Share Folder") {
                if let path = confirmShare { draft.addShare(hostPath: path, confirmed: true) }
                confirmShare = nil
            }
        } message: {
            Text(VMSettingsDraft.confirmShareText)
        }
        .confirmationDialog("Let the VM reach this Mac?",
                            isPresented: Binding(get: { turning != nil }, set: { if !$0 { turning = nil } })) {
            Button("Turn Around") {
                if let rule = turning, let i = draft.config.forwards.firstIndex(where: { $0.id == rule.id }) {
                    draft.config.forwards[i] = rule
                }
                turning = nil
            }
        } message: {
            Text(turning.flatMap(VMSettingsDraft.confirmation(for:)) ?? "")
        }
        .sheet(isPresented: $addingForward) {
            ForwardEditor { rule in
                draft.config.forwards.append(rule)
                addingForward = false
            } onCancel: { addingForward = false }
        }
        .sheet(isPresented: $addingBridge) {
            BridgeEditor { bridge in
                draft.addBridge(bridge)
                addingBridge = false
            } onCancel: { addingBridge = false }
        }
        .sheet(isPresented: $addingHostCommand) {
            HostCommandEditor(shares: draft.config.sharing.shares) { command in
                draft.config.hostCommands.append(command)
                addingHostCommand = false
            } onCancel: { addingHostCommand = false }
        }
    }

    // MARK: Save bar

    private var saveBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if vm.isRunning && !draft.appliesAfterRestart.isEmpty {
                    Label("Applies after a restart: \(draft.appliesAfterRestart.joined(separator: ", "))",
                          systemImage: "arrow.clockwise")
                        .font(Design.caption).foregroundStyle(.orange)
                } else if draft.isDirty {
                    Text("Unsaved changes").font(Design.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { draft = VMSettingsDraft(vm.config) }
                    .disabled(!draft.isDirty || saving)
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.isDirty || saving || !exists)
            }
            .controlSize(.large)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    // MARK: Overview

    private var isDefault: Bool { host.defaultVM === vm }

    private var overview: some View {
        Form {
            Section {
                PageHeader(symbol: vm.config.symbol, color: vm.isRunning ? .accentColor : .gray, title: vm.name,
                           subtitle: DistroCatalog.label(vm.config))
                HStack(spacing: 10) {
                    Button { (NSApp.delegate as? AppDelegate)?.openTab(in: vm) } label: {
                        Label("Open Tab", systemImage: "terminal")
                    }
                    .buttonStyle(.borderedProminent)
                    if vm.isRunning {
                        Button { run { try await host.stop(vm.name) } } label: { Label("Shut Down", systemImage: "stop.fill") }
                            .disabled(vm.state == .stopping)
                        Button { restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                            .disabled(vm.state == .stopping)
                    } else {
                        Button { run { try await host.start(vm.name) } } label: { Label("Start", systemImage: "play.fill") }
                            .disabled(vm.state.isPreparing)
                    }
                    Spacer()
                }
                .controlSize(.large)
            }
            if !vm.pendingRestart.isEmpty || vm.sharesError != nil || vm.state.isFailed {
                Section("Attention") {
                    if !vm.pendingRestart.isEmpty {
                        HStack {
                            Notice(symbol: "arrow.clockwise.circle.fill", color: .orange,
                                   text: "Saved changes to \(vm.pendingRestart.joined(separator: ", ")) apply after a restart.")
                            Spacer()
                            Button("Restart Now") { restart() }.disabled(vm.state != .ready)
                        }
                    }
                    if let problem = vm.sharesError {
                        Notice(symbol: "exclamationmark.triangle.fill", color: .red, text: problem)
                    }
                    if case .failed(let why) = vm.state {
                        Notice(symbol: "xmark.octagon.fill", color: .red, text: why)
                    }
                }
            }
            if let lima = VMSettingsDraft.limaNotes(for: vm.config) {
                Section("Lima") {
                    Notice(symbol: "externaldrive.connected.to.line.below", color: .teal, text: lima.shared)
                    if vm.isRunning {
                        Notice(symbol: "exclamationmark.triangle.fill", color: .orange, text: lima.warning)
                    }
                }
            } else if let note = VMSettingsDraft.copyNote(for: vm.config) {
                Section("Lima") {
                    Notice(symbol: "doc.on.doc", color: .teal, text: note)
                }
            }
            if vm.config.guestOS == .macos {
                Section("Desktop") {
                    SettingRow(symbol: "macwindow", color: .blue, title: "macOS Desktop",
                               detail: "Its screen in a window, for what needs you there (an installer, a system prompt). "
                                   + "Closing the window leaves the VM running.") {
                        Button("Open") { run { try await (NSApp.delegate as? AppDelegate)?.openDesktop(of: vm.name) } }.disabled(!vm.isRunning)
                    }
                    SettingRow(symbol: "key", color: .gray, title: "Password",
                               detail: "The account “\(vm.config.user)” logs in with it. The desktop's Type Password types it for you.") {
                        HStack {
                            if let shown = shownPassword {
                                Text(shown).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                Button("Hide") { shownPassword = nil }
                            } else {
                                Button("Show") {
                                    shownPassword = (try? String(contentsOf: vm.paths.macPassword, encoding: .utf8))?
                                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "(not found)"
                                }
                            }
                        }
                    }
                }
            }
            if !vm.config.ephemeral {
                Section("Startup") {
                    SettingRow(symbol: "star.fill", color: .yellow, title: "Default VM",
                               detail: isDefault ? "Monad opens this VM first. It is the top of the Virtual Machines list."
                                   : "The default VM opens first when Monad opens. It is the top of the Virtual Machines list.") {
                        if isDefault {
                            TagLabel(text: "default VM", color: .yellow)
                        } else {
                            Button("Make Default") { run { try await host.makeDefault(vm.name) } }
                        }
                    }
                    SettingRow(symbol: "power", color: .green, title: "Start VM at boot",
                               detail: "Starts this VM when Monad opens, without opening a tab.") {
                        Toggle("", isOn: $draft.config.startAtLaunch).labelsHidden().toggleStyle(.checkbox)
                    }
                }
            }
            Section("Appearance") {
                SettingRow(symbol: "photo", color: .orange, title: "Images in the terminal",
                           detail: VMSettingsDraft.inlineImagesDetail) {
                    Toggle("", isOn: $draft.config.inlineImages).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(symbol: "paintpalette", color: .pink, title: "Theme",
                           detail: "Used by this VM's tabs. Applies at once when you save.") {
                    Picker("", selection: $draft.config.theme) {
                        Text("App Default").tag(String?.none)
                        Text("Automatic (Light/Dark)").tag(String?.some(ThemeCatalog.automaticID))
                        Divider()
                        ForEach(ThemeStore.shared.catalog.themes) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Section("Details") {
                LabeledContent("State", value: exists ? vm.state.label : "Deleted")
                LabeledContent("Processors", value: "\(vm.config.cpus)")
                LabeledContent("Memory", value: "\(vm.config.memoryGiB) GB")
                LabeledContent("Disk", value: "\(vm.config.diskGiB) GB" + (vm.config.attached == nil ? "" : ", Lima's"))
                LabeledContent("Network", value: vm.config.networks.first?.displayName ?? "None")
                LabeledContent("User", value: vm.config.user)
                LabeledContent("Open tabs", value: "\(vm.sessions)")
            }
        }
    }

    // MARK: Resources

    private var resources: some View {
        Form {
            Section {
                QuantityRow(symbol: "cpu", color: .blue, title: "CPUs", value: $draft.config.cpus,
                            range: 1...capacity.maxCPUs, unit: draft.config.cpus == 1 ? "core" : "cores",
                            detail: "This Mac has \(capacity.cores) cores.")
                QuantityRow(symbol: "memorychip", color: .green, title: "Memory", value: $draft.config.memoryGiB,
                            range: 1...capacity.maxMemoryGiB, unit: "GB",
                            detail: "Up to \(capacity.maxMemoryGiB) GB of this Mac's \(capacity.memoryGiB) GB. \(HostCapacity.reservedMemoryGiB) GB always stay with macOS.")
            } header: {
                Text("Processors and Memory")
            } footer: {
                Text("Applied when the VM starts.").font(Design.caption).foregroundStyle(.secondary)
            }
            .onChange(of: draft.config.memoryGiB) {
                if let t = draft.config.memoryTargetGiB, t > draft.config.memoryGiB {
                    draft.config.memoryTargetGiB = draft.config.memoryGiB
                }
            }
            Section {
                SettingRow(symbol: "gauge.with.dots.needle.33percent", color: .mint, title: "Limit memory in use",
                           detail: "Hands memory back to the Mac while the VM runs, without a restart.") {
                    Toggle("", isOn: Binding(get: { draft.config.memoryTargetGiB != nil },
                                             set: { draft.config.memoryTargetGiB = $0 ? draft.config.memoryGiB : nil }))
                        .labelsHidden().toggleStyle(.switch)
                }
                if draft.config.memoryTargetGiB != nil {
                    QuantityRow(symbol: "memorychip", color: .mint, title: "Memory in use",
                                value: Binding(get: { draft.config.memoryTargetGiB ?? draft.config.memoryGiB },
                                               set: { draft.config.memoryTargetGiB = $0 }),
                                range: 1...max(1, draft.config.memoryGiB), unit: "GB")
                }
            } header: {
                Text("Memory Balloon")
            }
        }
    }

    // MARK: Security (macOS)

    private var security: some View {
        Form {
            Section {
                SettingRow(symbol: "lock.shield", color: .red, title: "System Integrity Protection",
                           detail: VMSettingsDraft.sipDetail) {
                    Toggle("", isOn: Binding(get: { draft.config.systemIntegrityProtection },
                                             set: { on in
                                                 if on { draft.config.systemIntegrityProtection = true } else { confirmingSIP = true }
                                             }))
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingRow(symbol: "checkmark.shield", color: .gray, title: "Now",
                           detail: vm.macSecurity?.step ?? VMSettingsDraft.sipFound(vm.macSecurity)) { EmptyView() }
                if let problem = vm.macSecurity?.problem {
                    Notice(symbol: "exclamationmark.triangle.fill", color: .orange, text: problem)
                }
            } header: {
                Text("System Integrity Protection")
            } footer: {
                Text("Changed in the VM's recovery at its next start: Monad starts it there, makes the change and restarts it, "
                     + "in a few minutes. Turning SIP back on needs the internet in the VM.")
                    .font(Design.caption).foregroundStyle(.secondary)
            }
            Section {
                SettingRow(symbol: "externaldrive.badge.checkmark", color: .blue, title: "Full disk access",
                           detail: VMSettingsDraft.fullDiskAccessDetail) {
                    Toggle("", isOn: $draft.config.fullDiskAccess).labelsHidden().toggleStyle(.switch)
                }
                if let problem = vm.macSecurity?.accessProblem {
                    Notice(symbol: "exclamationmark.triangle.fill", color: .orange, text: problem)
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Written into the VM's disk at its next start, before macOS boots.")
                    .font(Design.caption).foregroundStyle(.secondary)
            }
            Section {
                SettingRow(symbol: "person.crop.circle.badge.checkmark", color: .green, title: "Log in automatically",
                           detail: VMSettingsDraft.autoLoginDetail) {
                    Toggle("", isOn: $draft.config.autoLogin).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(symbol: "key.fill", color: .orange, title: "Auto-fill the password",
                           detail: VMSettingsDraft.autofillDetail) {
                    Toggle("", isOn: Binding(get: { draft.config.desktopAutofill ?? false },
                                             set: { draft.config.desktopAutofill = $0 }))
                        .labelsHidden().toggleStyle(.switch)
                }
            } header: {
                Text("Desktop")
            }
            Section {
                SettingRow(symbol: "lifepreserver", color: .red, title: "Boot to Recovery",
                           detail: VMSettingsDraft.bootToRecoveryDetail) {
                    Toggle("", isOn: $draft.config.bootToRecovery).labelsHidden().toggleStyle(.switch)
                }
            } header: {
                Text("Recovery")
            } footer: {
                Text("Once: the switch turns itself off when the VM starts in recovery.")
                    .font(Design.caption).foregroundStyle(.secondary)
            }
        }
        .alert(VMSettingsDraft.disableSIPConfirmation(vm: vm.name, newVM: false).title, isPresented: $confirmingSIP) {
            Button("Disable SIP") { draft.config.systemIntegrityProtection = false }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(VMSettingsDraft.disableSIPConfirmation(vm: vm.name, newVM: false).message)
        }
    }

    // MARK: Profiles

    private var profiles: some View {
        Form {
            Section {
                if profileCatalog.all.isEmpty {
                    Text("No profiles found.").foregroundStyle(.secondary)
                }
                ForEach(profileCatalog.all) { p in
                    profileRow(p)
                }
            } header: {
                Text("Profiles")
            } footer: {
                Text("A chosen profile is set up once, when the VM starts (or at once if it runs). Run Again sets it up again: only what is missing or out of date changes. Custom profiles are made in Settings › Profiles.")
                    .font(Design.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { profileCatalog = (try? ProfileCatalog.bundled(custom: ProfileStore())) ?? profileCatalog }
    }

    private func profileRow(_ p: ProfileConfig) -> some View {
        let last = vm.profileRuns.last { $0.profile == p.id }
        let busy = last?.state == .running || last?.state == .waiting
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Toggle("", isOn: Binding(get: { draft.config.profiles.contains(p.id) },
                                         set: { draft.setProfile(p.id, on: $0) }))
                    .labelsHidden().toggleStyle(.checkbox)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(Design.rowTitle)
                    Text(p.summary).font(Design.caption).foregroundStyle(.secondary)
                    if let last { profileStatus(last) }
                }
                Spacer()
                if busy {
                    Button("Stop") {
                        let name = vm.name
                        run { try await host.stopProfiles(name) }
                    }
                    .help("Stop setting it up, and drop the profiles waiting after it.")
                } else {
                    Button(last == nil ? "Run Now" : "Run Again") {
                        let name = vm.name
                        run { try await host.runProfiles(name, [p.id]) }
                    }
                    .disabled(!vm.isRunning)
                    .help(vm.isRunning ? "Set it up in the VM now." : "Start the VM first.")
                }
            }
            if let last {
                if busy {
                    Text(last.log.last ?? "Waiting for output…")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                HStack(alignment: .firstTextBaseline) {
                    DisclosureGroup("Output (last \(ProfileRun.logLines) lines)") {
                        Text(last.log.isEmpty ? "Nothing yet." : last.log.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    let log = InstancePaths(name: vm.name).profileLog(p.id)
                    Button("Full Log") { NSWorkspace.shared.open(log) }
                        .disabled(!FileManager.default.fileExists(atPath: log.path))
                        .help("The whole output of the latest run, in Console")
                }
                .font(Design.caption)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func profileStatus(_ run: ProfileRun) -> some View {
        switch run.state {
        case .waiting:
            Label("Waiting to start", systemImage: "clock").font(Design.caption).foregroundStyle(.secondary)
        case .running:
            Label(ProfileBanner.of([run])?.text ?? "Setting up", systemImage: "gearshape.2")
                .font(Design.caption).foregroundStyle(.orange)
        case .done:
            Label("Set up", systemImage: "checkmark.circle.fill").font(Design.caption).foregroundStyle(.green)
        case .failed:
            Label(run.message ?? "Failed", systemImage: "xmark.circle.fill").font(Design.caption).foregroundStyle(.red)
        }
    }

    // MARK: Network

    /// Whether the edited firewall would decide anything, on the edited network.
    private var firewallEffect: Firewall.Effect { Firewall.effect(for: draft.config, networks: networks) }

    private var network: some View {
        Form {
            Section {
                SettingRow(symbol: "network", color: .blue, title: "Network", detail: networkDetail) {
                    Picker("", selection: $draft.networkName) {
                        Text("None").tag(String?.none)
                        ForEach(networks.map(\.name), id: \.self) { Text($0).tag(String?.some($0)) }
                        if draft.original.networks.first?.isAppleNAT == true {
                            Text("Apple NAT").tag(String?.some(draft.original.networks[0].network))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                Text("Network")
            } footer: {
                Text("Networks are set up in Settings › Networks. VMs on the same network can reach each other. Changing the network needs a restart.")
                    .font(Design.caption).foregroundStyle(.secondary)
            }
            if let problem = vm.firewallProblem {
                Section { Notice(symbol: "exclamationmark.shield.fill", color: .red, text: problem) }
            }
            Section {
                if firewallEffect == .active {
                    FirewallSwitchRows(firewall: $draft.config.firewall, tags: tags, group: draft.config.group)
                } else {
                    Notice(symbol: "exclamationmark.shield.fill", color: .orange, text: firewallEffect.explanation)
                    if firewallEffect == .appleNAT, networks.contains(where: { $0.name == NetworkDefinition.defaultName }) {
                        Button("Move to the “\(NetworkDefinition.defaultName)” Network") {
                            draft.networkName = NetworkDefinition.defaultName
                        }
                    }
                }
            } header: {
                Text("Firewall")
            } footer: {
                Text(firewallEffect == .active
                     ? "This VM's own. Other VMs are not affected. Changes apply at once, to open connections too."
                     : "Its settings are kept and apply once it is on a Monad NAT network.")
                    .font(Design.caption).foregroundStyle(.secondary)
            }
            if firewallEffect == .active {
                Section {
                    FirewallRuleRows(editor: $draft.firewallRules)
                } header: {
                    Text("Rules")
                } footer: {
                    Text(FirewallText.rulesFooter).font(Design.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            networks = (try? NetworkStore().all()) ?? []
            tags = (try? FirewallTagStore().all()) ?? []
        }
    }

    // MARK: Shared folders

    private var folders: some View {
        Form {
            Section {
                SettingRow(symbol: "externaldrive.connected.to.line.below", color: .cyan, title: "Folder sharing",
                           detail: "Gives the VM a shared-folder device. Turning it on or off needs a restart.") {
                    Toggle("", isOn: $draft.config.sharing.runtimeEnabled).labelsHidden().toggleStyle(.switch)
                }
            }
            if let problem = vm.sharesError {
                Section { Notice(symbol: "exclamationmark.triangle.fill", color: .red, text: problem) }
            }
            Section {
                if draft.config.sharing.shares.isEmpty {
                    Text("No folders shared.").foregroundStyle(.secondary)
                }
                ForEach($draft.config.sharing.shares, id: \.self) { $share in
                    HStack(alignment: .top, spacing: 12) {
                        IconTile(symbol: "folder.fill", color: .cyan, size: 28)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(URL(fileURLWithPath: share.hostPath).lastPathComponent).font(Design.rowTitle)
                            Text(share.hostPath).font(Design.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            HStack(spacing: 8) {
                                Label("In the VM", systemImage: "arrow.turn.down.right")
                                    .font(Design.caption).foregroundStyle(.secondary)
                                    .fixedSize()
                                TextField("In the VM", text: $share.guestPath)
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .font(Design.body.monospaced())
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: 340)
                            }
                            if let note = VMSettingsDraft.note(for: share) {
                                Label(note, systemImage: "exclamationmark.triangle.fill")
                                    .font(Design.caption).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        Picker("", selection: $share.readOnly) {
                            Text("Read-only").tag(true)
                            Text("Read & Write").tag(false)
                        }
                        .labelsHidden().fixedSize()
                        Button(role: .destructive) {
                            draft.config.sharing.shares.removeAll { $0 == share }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Stop sharing this folder")
                    }
                    .padding(.vertical, 4)
                }
                Button { chooseFolder() } label: { Label("Add Folder…", systemImage: "plus") }
            } header: {
                Text("Folders")
            } footer: {
                Text("Folders are mounted in the VM as soon as you save.").font(Design.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Forwarding

    private var forwarding: some View {
        Form {
            Section {
                if draft.config.forwards.isEmpty {
                    Text("No forwards. Add a Mac port to use a program on this Mac from the VM. Ports the VM opens are forwarded by themselves (below).")
                        .foregroundStyle(.secondary)
                }
                ForEach($draft.config.forwards) { $rule in
                    HStack(spacing: 12) {
                        IconTile(symbol: icon(rule), color: .purple, size: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(VMSettingsDraft.describe(rule)).font(Design.rowTitle)
                            forwardStatus(rule).font(Design.caption)
                        }
                        Spacer()
                        if rule.kind == .local, case .failed? = VMSettingsDraft.status(of: rule, in: vm.forwards)?.state {
                            // Usually made the wrong way round: the Mac port is
                            // the program it was meant to reach.
                            Button("Turn Around") { turning = VMSettingsDraft.turnedAround(rule) }
                                .help("Make it \(VMSettingsDraft.describe(VMSettingsDraft.turnedAround(rule)))")
                        }
                        Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        Button(role: .destructive) {
                            draft.config.forwards.removeAll { $0.id == rule.id }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
                Button { addingForward = true } label: { Label("Add Forward…", systemImage: "plus") }
            } header: {
                Text("Forwards")
            }
            bridges
            hostCommands
            Section {
                SettingRow(symbol: "wand.and.stars", color: .indigo, title: "Forward ports automatically",
                           detail: "Ports from \(draft.config.autoForward.minimumPort) up that the VM opens are reachable on this Mac's localhost.") {
                    Toggle("", isOn: $draft.config.autoForward.enabled).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(symbol: "nosign", color: .gray, title: "Ports to skip") {
                    TextField("", text: $draft.ignoredPortsText, prompt: Text("5432, 6379"))
                        .textFieldStyle(.roundedBorder).frame(width: 180)
                }
                let auto = vm.forwards.filter { $0.origin == .auto }
                ForEach(auto, id: \.spec) { status in
                    HStack {
                        Image(systemName: "arrow.right.circle.fill").foregroundStyle(.indigo)
                        Text("localhost:\(Self.macPort(status.spec))").font(Design.body.monospacedDigit())
                        Spacer()
                        stateText(status.state).font(Design.caption)
                    }
                }
                if vm.isRunning && auto.isEmpty && draft.config.autoForward.enabled {
                    Text("No ports forwarded right now.").font(Design.caption).foregroundStyle(.secondary)
                }
                if vm.portsOverLimit > 0 {
                    Label("\(vm.portsOverLimit) more \(vm.portsOverLimit == 1 ? "port is" : "ports are") not forwarded. Monad forwards at most \(ForwardPlan.maxAutoForwards) per VM, lowest first.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Design.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Automatic Forwarding")
            }
        }
    }

    /// Stdio bridges (Phase 12): Mac programs the VM can run.
    private var bridges: some View {
        Section {
            if draft.config.bridges.isEmpty {
                Text("No bridges. A bridge lets the VM run a program on this Mac, such as xcrun mcpbridge, through a port or socket in the VM.")
                    .foregroundStyle(.secondary)
            }
            ForEach($draft.config.bridges) { $bridge in
                HStack(spacing: 12) {
                    IconTile(symbol: "terminal", color: .orange, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bridge.name).font(Design.rowTitle)
                        Text("\(bridge.command.joined(separator: " ")) at \(bridge.guestEndpoint) in the VM")
                            .font(Design.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        bridgeStatus(bridge).font(Design.caption)
                    }
                    Spacer()
                    let log = bridge.log(in: InstancePaths(name: vm.name))
                    Button { NSWorkspace.shared.open(log) } label: { Image(systemName: "doc.text") }
                        .buttonStyle(.borderless)
                        .help("Show what the program wrote and each connection")
                        .disabled(!FileManager.default.fileExists(atPath: log.path))
                    Toggle("", isOn: $bridge.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Button(role: .destructive) {
                        draft.config.bridges.removeAll { $0.id == bridge.id }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
                .padding(.vertical, 3)
            }
            Button { addingBridge = true } label: { Label("Add Bridge…", systemImage: "plus") }
        } header: {
            Text("Bridges")
        } footer: {
            Text("Each connection runs the program once on this Mac, as you, without a shell. On the Mac a bridge listens on a private socket, never a network port.")
                .font(Design.caption).foregroundStyle(.secondary)
        }
    }

    /// Host commands (agents phase): Mac commands the VM runs with values
    /// it varies under patterns, one run at a time.
    private var hostCommands: some View {
        Section {
            if draft.config.hostCommands.isEmpty {
                Text(draft.config.sharing.shares.isEmpty
                     ? "No host commands. A host command runs in a folder this VM shares: share one first."
                     : "No host commands. A host command lets the VM run a program on this Mac with values it chooses, each checked against a pattern you set, such as make with a target.")
                    .foregroundStyle(.secondary)
            }
            ForEach($draft.config.hostCommands) { $command in
                HStack(spacing: 12) {
                    IconTile(symbol: "hammer", color: .purple, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(command.name).font(Design.rowTitle)
                        Text("\(([command.program] + command.fixedArguments).joined(separator: " "))"
                             + command.arguments.map { " ‹\($0.name)›" }.joined()
                             + " at \(command.guestEndpoint) in the VM")
                            .font(Design.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        hostCommandStatus(command).font(Design.caption)
                    }
                    Spacer()
                    let paths = InstancePaths(name: vm.name)
                    let log = command.log(in: paths)
                    Button { NSWorkspace.shared.open(log) } label: { Image(systemName: "doc.text") }
                        .buttonStyle(.borderless)
                        .help("Show each run, what was refused and what the program wrote to stderr")
                        .disabled(!FileManager.default.fileExists(atPath: log.path))
                    let runs = paths.exchange.appendingPathComponent("runs")
                    Button { NSWorkspace.shared.open(runs) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless)
                        .help("Show the runs (also at ~/.monad/exchange/runs in the VM)")
                        .disabled(!command.results || !FileManager.default.fileExists(atPath: runs.path))
                    Toggle("", isOn: $command.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Button(role: .destructive) {
                        draft.config.hostCommands.removeAll { $0.id == command.id }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
                .padding(.vertical, 3)
            }
            Button { addingHostCommand = true } label: { Label("Add Host Command…", systemImage: "plus") }
                .disabled(draft.config.sharing.shares.isEmpty)
        } header: {
            Text("Host Commands")
        } footer: {
            Text("The VM sends values over the command's socket or port (run <values>, or describe), or calls it as an MCP tool. Monad checks each value against its pattern before anything runs, and no shell reads them. Runs are kept in ~/.monad/exchange/runs in the VM.")
                .font(Design.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func hostCommandStatus(_ command: HostCommand) -> some View {
        let spec = command.spec(in: InstancePaths(name: vm.name))
        if let state = vm.forwards.first(where: { $0.origin == .bridge && $0.flag == spec.flag && $0.spec == spec.value })?.state {
            stateText(state)
        } else if !command.enabled {
            Text("Off").foregroundStyle(.secondary)
        } else if vm.state == .ready {
            Label("Not serving. Settings › Logs says why.", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        } else {
            Text("Serves while the VM runs.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func bridgeStatus(_ bridge: CommandBridge) -> some View {
        if let state = VMSettingsDraft.status(of: bridge, in: vm.forwards, paths: InstancePaths(name: vm.name)) {
            stateText(state)
        } else if !bridge.enabled {
            Text("Off").foregroundStyle(.secondary)
        } else if vm.state == .ready {
            Label("Not serving. Settings › Logs says why.", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        } else {
            Text("Serves while the VM runs.").foregroundStyle(.secondary)
        }
    }

    private func icon(_ rule: ForwardRule) -> String {
        switch rule.kind {
        case .local: return "arrow.right"
        case .remote: return "arrow.left"
        case .socks: return "globe"
        case .unixLocal, .unixRemote: return "point.3.connected.trianglepath.dotted"
        }
    }

    private static func macPort(_ spec: String) -> String {
        spec.split(separator: ":").dropFirst().first.map(String.init) ?? "?"
    }

    @ViewBuilder
    private func stateText(_ state: ForwardStatus.State) -> some View {
        switch state {
        case .active: Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let reason): Label(reason, systemImage: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func forwardStatus(_ rule: ForwardRule) -> some View {
        if !rule.enabled {
            Text("Off").foregroundStyle(.secondary)
        } else if !vm.isRunning {
            Text("Starts with the VM").foregroundStyle(.secondary)
        } else if let status = VMSettingsDraft.status(of: rule, in: vm.forwards) {
            stateText(status.state)
        } else {
            Text("Not saved yet").foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Share"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch VMSettingsDraft.shareVerdict(url.path) {
        case .fine: draft.addShare(hostPath: url.path)
        case .needsConfirmation: confirmShare = url.path
        case .refused(let why):
            errorTitle = "This folder cannot be shared"
            errorMessage = why
        }
    }

    private func save() {
        let config: InstanceConfig
        do {
            config = try draft.build(maxCPUs: capacity.maxCPUs, maxMemoryGiB: capacity.maxMemoryGiB,
                                     tags: (try? FirewallTagStore().all()) ?? [])
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let wasRunning = vm.isRunning
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                try await host.update(config)
                draft.saved(config)
                // The host's answer, which includes earlier saved changes too.
                restartPrompt = VMSettingsDraft.restartPrompt(vm: vm.name, pending: vm.pendingRestart, isRunning: wasRunning)
            } catch {
                errorMessage = HostAgent.describe(error)
            }
        }
    }

    private func restart() {
        run { try await host.restart(vm.name) }
    }

    // MARK: Configuration

    /// The VM's settings as saved (instance.json), to copy or export.
    private var savedJSON: String { Self.json(vm.config) }

    private static func json(_ config: InstanceConfig) -> String {
        (try? VMConfigFile.export(config)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// The editor's text checked as it is typed.
    private var configCheck: VMConfigFile.Check {
        VMConfigFile.check(configText, against: vm.config, on: configMac ?? .current(taken: []))
    }

    private var configuration: some View {
        let check = configCheck
        let edited = configText != configBaseline
        return VStack(alignment: .leading, spacing: 12) {
            PageHeader(symbol: "curlybraces", color: .brown, title: "Configuration",
                       subtitle: "This VM's settings as instance.json holds them. Edit them or paste others here, then apply.")
            HStack(spacing: 10) {
                Button { applyConfiguration(check) } label: { Label("Apply", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!check.canApply || draft.isDirty || saving || !exists)
                Button("Revert") { configText = configBaseline }
                    .disabled(!edited || saving)
                Button("Format") { if let laid = VMConfigFile.format(configText) { configText = laid } }
                    .disabled(VMConfigFile.format(configText).map { $0 == configText } ?? true)
                    .help("Lay the JSON out as instance.json is: sorted keys, two spaces")
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(configText, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { exportConfiguration() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    .help("Save the settings as they are saved now, for a backup or to import elsewhere")
            }
            .controlSize(.large)
            configStatus(check, edited: edited)
            JSONEditor(text: $configText, focus: $configFocus)
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(check.problems.isEmpty ? Color.secondary.opacity(0.3) : Color.red.opacity(0.7), lineWidth: 1))
            if !check.problems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(check.problems.prefix(6).enumerated()), id: \.offset) { _, problem in
                        Button {
                            configFocus = VMConfigFile.range(of: problem, in: configText)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                                if !problem.path.isEmpty {
                                    Text(problem.path).font(.system(size: 12, weight: .semibold, design: .monospaced))
                                }
                                Text(problem.message).font(Design.caption).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show it in the text")
                    }
                    if check.problems.count > 6 {
                        Text("… and \(check.problems.count - 6) more").font(Design.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Every key is checked as you type: JSON, the keys Monad knows, their types and values, as on save. What was set when the VM was made cannot change. docs/CONFIG.md describes every field, and Import in the Virtual Machines window makes a new VM from such a file.")
                .font(Design.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear {
            if configMac == nil { configMac = .current(taken: []) }
            if configBaseline.isEmpty {
                configBaseline = savedJSON
                if configText.isEmpty { configText = configBaseline }
            }
        }
        // The same publisher each time (a new one would be subscribed again,
        // and answer at once, on every redraw).
        .onReceive(vm.$snapshot) { snapshot in
            // Saved elsewhere: follow, unless the user is editing.
            let saved = Self.json(snapshot.config)
            if configText == configBaseline && saved != configBaseline {
                configBaseline = saved
                configText = saved
            }
        }
        .confirmationDialog("Let the VM reach into this Mac?", isPresented: $confirmingEdit) {
            Button("Apply") { if let config = configCheck.config { apply(config) } }
        } message: {
            Text("These settings let \(vm.name) reach into this Mac:\n\n"
                 + configCheck.reachesIntoMac.map { "• " + $0 }.joined(separator: "\n")
                 + "\n\nApply them only if you trust where they came from.")
        }
    }

    /// One line on what Apply would do (no Notice: its text keeps its full
    /// height, too tall for this page, which does not scroll).
    @ViewBuilder
    private func configStatus(_ check: VMConfigFile.Check, edited: Bool) -> some View {
        let (symbol, color, text): (String, Color, String) = {
            if draft.isDirty {
                return ("exclamationmark.circle.fill", .orange,
                        "Save or revert the changes on the other pages first. They are not in this text.")
            }
            if !check.problems.isEmpty {
                return ("xmark.octagon.fill", .red, check.problems.count == 1 ? "1 problem. Click it to see where it is."
                            : "\(check.problems.count) problems. Click one to see where it is.")
            }
            if check.changes.isEmpty {
                return ("checkmark.circle.fill", .green, edited ? "Valid, and the same settings as saved." : "The settings as saved.")
            }
            let later = ConfigChange.restartOnly(from: vm.config, to: check.config ?? vm.config)
            return ("checkmark.circle.fill", .green,
                    "Valid. Apply changes: \(check.changes.joined(separator: ", "))."
                        + (later.isEmpty ? "" : " After a restart: \(later.joined(separator: ", ")).")
                        + (check.reachesIntoMac.isEmpty ? "" : " You are asked first: it lets the VM reach into this Mac."))
        }()
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(Design.body).lineLimit(2)
        }
    }

    private func loadConfiguration() {
        let saved = savedJSON
        if configBaseline != saved { configBaseline = saved }
        if configText != saved { configText = saved }
    }

    private func applyConfiguration(_ check: VMConfigFile.Check) {
        guard let config = check.config, check.canApply else { return }
        if check.reachesIntoMac.isEmpty {
            apply(config)
        } else {
            confirmingEdit = true
        }
    }

    /// Saves settings from the Configuration page, as Save does.
    private func apply(_ config: InstanceConfig) {
        let wasRunning = vm.isRunning
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                try await host.update(config)
                draft.saved(config)
                loadConfiguration()
                restartPrompt = VMSettingsDraft.restartPrompt(vm: vm.name, pending: vm.pendingRestart, isRunning: wasRunning)
            } catch {
                errorTitle = "Could not apply"
                errorMessage = HostAgent.describe(error)
            }
        }
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = VMConfigFile.fileName(for: vm.config)
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try VMConfigFile.export(vm.config).write(to: url, options: .atomic)
        } catch {
            errorTitle = "Could not export"
            errorMessage = error.localizedDescription
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await action() } catch { errorMessage = HostAgent.describe(error) }
        }
    }
}

/// Plain text for JSON: no smart quotes or dashes and no spelling fixes
/// (they would break it), monospaced, with undo. `focus` selects a range
/// and shows it, then clears.
private struct JSONEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focus: NSRange?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.string = text
        view.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        if let range = focus {
            let length = (view.string as NSString).length
            let safe = NSRange(location: min(range.location, length), length: max(0, min(range.length, length - min(range.location, length))))
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(safe)
            view.scrollRangeToVisible(safe)
            view.showFindIndicator(for: safe)
            DispatchQueue.main.async { focus = nil }
        }
    }

    /// The space it is offered, scrolling inside it: never the height of
    /// its text (which would make the window that tall).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: proposal.height ?? 300)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONEditor
        init(_ parent: JSONEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

/// Sheet for one new forward.
private struct ForwardEditor: View {
    enum Kind: String, CaseIterable, Identifiable {
        case macPort, vmPort, socks, socket
        var id: String { rawValue }

        var title: String {
            switch self {
            case .macPort: return "Mac Port"
            case .vmPort: return "VM Port"
            case .socks: return "SOCKS"
            case .socket: return "Socket"
            }
        }

        var explanation: String {
            switch self {
            case .macPort: return "A program on this Mac, used from the VM: the VM connects to 127.0.0.1 and reaches the Mac's port."
            case .vmPort: return "A program in the VM, used from this Mac. Ports the VM opens are usually forwarded by themselves (below)."
            case .socks: return "A SOCKS5 proxy on this Mac. Connections leave from the VM."
            case .socket: return "A Unix socket in the VM, used from this Mac (e.g. Docker)."
            }
        }
    }

    var onAdd: (ForwardRule) -> Void
    var onCancel: () -> Void

    @State private var kind: Kind = .macPort
    @State private var hostPort = ""
    @State private var guestPort = ""
    @State private var hostSocket = ""
    @State private var guestSocket = ""
    /// A forward into the Mac, waiting for the user's word.
    @State private var confirming: ForwardRule?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "arrow.left.arrow.right", color: .purple, title: "Add Forward", subtitle: kind.explanation)
                .padding(.horizontal, 24).padding(.top, 18)
            Form {
                Picker("Kind", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                switch kind {
                case .macPort:
                    TextField("Mac port", text: $hostPort, prompt: Text("8000"))
                    TextField("In the VM at port", text: $guestPort, prompt: Text(hostPort.isEmpty ? "the same" : hostPort))
                case .vmPort:
                    TextField("VM port", text: $guestPort, prompt: Text("80"))
                    TextField("On the Mac at port", text: $hostPort, prompt: Text("8080"))
                case .socks:
                    TextField("Mac port", text: $hostPort, prompt: Text("1080"))
                case .socket:
                    TextField("Mac socket", text: $hostSocket, prompt: Text("~/.monad/docker.sock"))
                    TextField("VM socket", text: $guestSocket, prompt: Text("/run/docker.sock"))
                }
                if kind == .macPort {
                    Notice(symbol: "exclamationmark.shield", color: .orange,
                           text: "Programs in the VM will reach this port on your Mac, past the VM's firewall.")
                        .font(Design.caption)
                } else {
                    Notice(symbol: "lock.fill", color: .green, text: "Mac ports listen on 127.0.0.1 only.").font(Design.caption)
                }
            }
            .formStyle(.grouped)
            .font(Design.body)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    guard let rule else { return }
                    if VMSettingsDraft.confirmation(for: rule) != nil { confirming = rule } else { onAdd(rule) }
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(rule == nil)
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 500, height: 400)
        .confirmationDialog("Let the VM reach this Mac?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Add Forward") {
                if let rule = confirming { onAdd(rule) }
                confirming = nil
            }
        } message: {
            Text(confirming.flatMap(VMSettingsDraft.confirmation(for:)) ?? "")
        }
    }

    private var rule: ForwardRule? {
        switch kind {
        case .macPort:
            return VMSettingsDraft.portForward(macPort: hostPort, vmPort: guestPort, intoVM: true)
        case .vmPort:
            return VMSettingsDraft.portForward(macPort: hostPort, vmPort: guestPort, intoVM: false)
        case .socks:
            guard let hp = Int(hostPort.trimmingCharacters(in: .whitespaces)) else { return nil }
            return ForwardRule(kind: .socks, hostPort: hp)
        case .socket:
            let h = (hostSocket as NSString).expandingTildeInPath
            guard h.hasPrefix("/"), guestSocket.hasPrefix("/") else { return nil }
            return ForwardRule(kind: .unixLocal, hostSocket: h, guestSocket: guestSocket)
        }
    }
}

/// Adds a stdio bridge: a name, the program (by name or full path) and its
/// arguments, and where the VM reaches it. What the VM can then do is
/// asked before it is added.
private struct BridgeEditor: View {
    var onAdd: (CommandBridge) -> Void
    var onCancel: () -> Void

    @State private var name = ""
    @State private var program = ""
    @State private var arguments = ""
    @State private var usesSocket = false
    @State private var guestPort = ""
    @State private var guestSocket = ""
    @State private var confirming: CommandBridge?

    /// Where a program typed by name is looked for (GUI apps get a short PATH).
    private static let searchPath = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        + ":/opt/homebrew/bin:/usr/local/bin"

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "terminal", color: .orange, title: "Add Bridge",
                       subtitle: "A program on this Mac the VM can run, through a port or socket in the VM.")
                .padding(.horizontal, 24).padding(.top, 18)
            Form {
                TextField("Name", text: $name, prompt: Text("Xcode MCP"))
                HStack {
                    TextField("Program", text: $program, prompt: Text("xcrun"))
                    Button("Choose…") { choose() }
                }
                if let resolved, resolved != program.trimmingCharacters(in: .whitespaces) {
                    Text(resolved).font(Design.caption).foregroundStyle(.secondary)
                } else if !program.trimmingCharacters(in: .whitespaces).isEmpty && resolved == nil {
                    Text("No program by that name.").font(Design.caption).foregroundStyle(.orange)
                }
                TextField("Arguments", text: $arguments, prompt: Text("mcpbridge"))
                Picker("In the VM", selection: $usesSocket) {
                    Text("Port").tag(false)
                    Text("Socket").tag(true)
                }
                .pickerStyle(.segmented)
                if usesSocket {
                    TextField("VM socket", text: $guestSocket, prompt: Text("/run/user/1000/mcp.sock"))
                } else {
                    TextField("VM port", text: $guestPort, prompt: Text("9000"))
                }
                Notice(symbol: "exclamationmark.shield", color: .orange,
                       text: "Programs in the VM can run this program on your Mac, as you, with the input they send. Arguments are separated by spaces and no shell reads them.")
                    .font(Design.caption)
            }
            .formStyle(.grouped)
            .font(Design.body)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Button("Add") { confirming = bridge }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(bridge == nil)
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 520, height: 470)
        .confirmationDialog("Let the VM run this program?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Add Bridge") {
                if let bridge = confirming { onAdd(bridge) }
                confirming = nil
            }
        } message: {
            Text(confirming.map(VMSettingsDraft.confirmation(for:)) ?? "")
        }
    }

    private var resolved: String? { VMSettingsDraft.resolveProgram(program, path: Self.searchPath) }

    private var bridge: CommandBridge? {
        guard let resolved else { return nil }
        let bridge = CommandBridge(name: name.trimmingCharacters(in: .whitespaces),
                                   command: [resolved] + VMSettingsDraft.arguments(arguments),
                                   guestPort: usesSocket ? nil : Int(guestPort.trimmingCharacters(in: .whitespaces)),
                                   guestSocket: usesSocket ? guestSocket.trimmingCharacters(in: .whitespaces) : nil)
        return bridge.isValidName && bridge.isValidCommand && bridge.isValidEndpoint ? bridge : nil
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/bin")
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { program = url.path }
    }
}

/// Adds a host command: the program and its fixed arguments, the values
/// the VM may give and their patterns, where it runs and for how long, and
/// where the VM reaches it. What the VM can then do is asked first.
private struct HostCommandEditor: View {
    let shares: [SharedFolder]
    var onAdd: (HostCommand) -> Void
    var onCancel: () -> Void

    @State private var draft: HostCommandDraft
    @State private var confirming: HostCommand?

    init(shares: [SharedFolder], onAdd: @escaping (HostCommand) -> Void, onCancel: @escaping () -> Void) {
        self.shares = shares
        self.onAdd = onAdd
        self.onCancel = onCancel
        _draft = State(initialValue: HostCommandDraft(shares: shares))
    }

    var body: some View {
        let (command, problem) = draft.command(shares: shares)
        VStack(spacing: 0) {
            PageHeader(symbol: "hammer", color: .purple, title: "Add Host Command",
                       subtitle: "A program on this Mac the VM can run with values it chooses, each checked against a pattern.")
                .padding(.horizontal, 24).padding(.top, 18)
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("app-make"))
                    TextField("Summary", text: $draft.summary, prompt: Text("Build and benchmark the app on the Mac."))
                    HStack {
                        TextField("Program", text: $draft.program, prompt: Text("make"))
                        Button("Choose…") { chooseProgram() }
                    }
                    TextField("Fixed arguments", text: $draft.fixedArguments, prompt: Text("always passed first"))
                }
                Section {
                    ForEach($draft.arguments) { $row in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("", text: $row.name, prompt: Text("name")).labelsHidden()
                                    .textFieldStyle(.roundedBorder).frame(width: 120)
                                TextField("", text: $row.pattern, prompt: Text("^(build|test)$")).labelsHidden()
                                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                                Toggle("Required", isOn: $row.required).toggleStyle(.checkbox).fixedSize()
                                Button { draft.arguments.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                            TextField("", text: $row.summary, prompt: Text("What it is, for the agent")).labelsHidden()
                                .textFieldStyle(.roundedBorder)
                        }
                        .padding(.vertical, 2)
                    }
                    Button("Add Value") { draft.arguments.append(.init()) }
                        .disabled(draft.arguments.count >= HostCommand.maxArguments)
                } header: {
                    Text("Values the VM gives")
                } footer: {
                    Text("In order, after the fixed arguments. A pattern starts with ^ and ends with $, so it covers the whole value; keep it tight.")
                        .font(Design.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("Working folder", selection: $draft.workingDirectory) {
                        ForEach(shares, id: \.hostPath) { Text($0.hostPath).tag($0.hostPath) }
                        if !shares.contains(where: { $0.hostPath == draft.workingDirectory }) {
                            Text(draft.workingDirectory).tag(draft.workingDirectory)
                        }
                    }
                    Button("Choose a Folder Inside a Share…") { chooseFolder() }
                    Stepper("Time limit: \(HostCommandDraft.duration(draft.timeoutMinutes * 60))", value: $draft.timeoutMinutes,
                            in: 1...1440)
                    Toggle("Keep each run in the exchange folder", isOn: $draft.results)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Environment (NAME=value, one per line)")
                        TextEditor(text: $draft.environment).font(.system(.caption, design: .monospaced)).frame(height: 54)
                    }
                    Picker("In the VM", selection: $draft.usesSocket) {
                        Text("Port").tag(false)
                        Text("Socket").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if draft.usesSocket {
                        TextField("VM socket", text: $draft.guestSocket, prompt: Text("/run/monad/make.sock"))
                    } else {
                        TextField("VM port", text: $draft.guestPort, prompt: Text("9100"))
                    }
                }
                if let problem {
                    Section { Text(problem).font(Design.caption).foregroundStyle(.red) }
                } else if let command, !command.warnings.isEmpty {
                    Section { Notice(symbol: "exclamationmark.triangle.fill", color: .orange, text: command.warnings.joined(separator: " ")) }
                }
            }
            .formStyle(.grouped)
            .font(Design.body)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Button("Add") { confirming = command }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(command == nil)
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 620, height: 680)
        .confirmationDialog("Let the VM run this program?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Add Host Command") {
                if let command = confirming { onAdd(command) }
                confirming = nil
            }
        } message: {
            Text(confirming.map(HostCommandDraft.confirmation(for:)) ?? "")
        }
    }

    private func chooseProgram() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/bin")
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { draft.program = url.path }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = shares.first.map { URL(fileURLWithPath: $0.hostPath) }
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { draft.workingDirectory = url.path }
    }
}

#if DEBUG
/// Sample data for SwiftUI previews of the VM windows.
@MainActor
enum PreviewFixtures {
    private struct Offline: Error {}

    static let client = HostClient(connect: { throw Offline() })

    static let vm: RemoteVM = {
        var c = InstanceConfig.defaults(name: "dev")
        c.distro = "ubuntu"
        c.release = "26.04"
        c.cpus = 4
        c.memoryGiB = 8
        c.memoryTargetGiB = 6
        c.sharing = SharingSettings(runtimeEnabled: true, shares: [
            SharedFolder(hostPath: NSHomeDirectory() + "/src/project", guestPath: "/home/dev/project", readOnly: true),
            SharedFolder(hostPath: NSHomeDirectory() + "/Downloads", guestPath: "/home/dev/Downloads", readOnly: false),
        ])
        c.forwards = [ForwardRule(kind: .local, hostPort: 8080, guestPort: 80), ForwardRule(kind: .socks, hostPort: 1080)]
        let snap = VMSnapshot(
            name: "dev", config: c, state: .ready, agent: true, ports: [], sessions: 2,
            forwards: [
                ForwardStatus(flag: "-L", spec: "127.0.0.1:8080:127.0.0.1:80", origin: .configured, state: .active),
                ForwardStatus(flag: "-D", spec: "127.0.0.1:1080", origin: .configured,
                              state: .failed("Port 1080 on this Mac is already in use by limactl.")),
                ForwardStatus(flag: "-L", spec: "127.0.0.1:3000:127.0.0.1:3000", origin: .auto, state: .active),
            ],
            pendingRestart: ["CPUs"])
        return RemoteVM(snapshot: snap, root: URL(fileURLWithPath: "/tmp"))
    }()
}

#Preview("Overview") {
    VMDetailView(vm: PreviewFixtures.vm, host: PreviewFixtures.client, page: .overview)
        .frame(width: VMDetailView.size.width, height: VMDetailView.size.height)
}

#Preview("Resources") {
    VMDetailView(vm: PreviewFixtures.vm, host: PreviewFixtures.client, page: .resources)
        .frame(width: VMDetailView.size.width, height: VMDetailView.size.height)
}

#Preview("Shared Folders") {
    VMDetailView(vm: PreviewFixtures.vm, host: PreviewFixtures.client, page: .folders)
        .frame(width: VMDetailView.size.width, height: VMDetailView.size.height)
}

#Preview("Port Forwarding") {
    VMDetailView(vm: PreviewFixtures.vm, host: PreviewFixtures.client, page: .forwarding)
        .frame(width: VMDetailView.size.width, height: VMDetailView.size.height)
}

#Preview("Configuration") {
    VMDetailView(vm: PreviewFixtures.vm, host: PreviewFixtures.client, page: .configuration)
        .frame(width: VMDetailView.size.width, height: VMDetailView.size.height)
}

#Preview("Configuration, edited") {
    let saved = String(decoding: (try? VMConfigFile.export(PreviewFixtures.vm.config)) ?? Data(), as: UTF8.self)
    let text = saved.replacingOccurrences(of: "\"cpus\" : 4", with: "\"cpu\" : 6")
        .replacingOccurrences(of: "\"diskGiB\" : 50", with: "\"diskGiB\" : \"big\"")
        .replacingOccurrences(of: "\"name\" : \"dev\"", with: "\"name\" : \"renamed\"")
    return VMDetailView(vm: PreviewFixtures.vm, host: PreviewFixtures.client, page: .configuration, configText: text)
        .frame(width: VMDetailView.size.width, height: VMDetailView.size.height)
}
#endif

// MARK: - Log

/// The VM's Log page: the latest part of its log (VMLog), read again only
/// when the file changed.
@MainActor
final class VMLogPageModel: ObservableObject {
    let url: URL
    @Published private(set) var text = ""
    private var seen: [Int64] = []
    private var timer: Timer?

    init(url: URL) { self.url = url }

    /// Whether the text changed.
    @discardableResult
    func refresh() -> Bool {
        let stamp = [url, VMLog.previous(of: url)].flatMap { u -> [Int64] in
            var st = stat()
            guard stat(u.path, &st) == 0 else { return [-1, -1] }
            return [Int64(st.st_size), Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)]
        }
        guard stamp != seen else { return false }
        seen = stamp
        let new = VMLog.read(url)
        guard new != text else { return false }
        text = new
        return true
    }

    /// Looked at once a second while the page shows.
    func start() {
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

struct VMLogPage: View {
    @StateObject private var model: VMLogPageModel

    init(url: URL) { _model = StateObject(wrappedValue: VMLogPageModel(url: url)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(symbol: "doc.text.fill", color: .teal, title: "Log",
                       subtitle: "What Monad did with this VM, as it happens: how it was made, each start, its shared folders, its agent, its firewall answers.")
            HStack(spacing: 10) {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.text, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(model.text.isEmpty)
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.url]) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .disabled(model.text.isEmpty)
            }
            .controlSize(.large)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.text.isEmpty ? "Nothing yet." : model.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(model.text.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .onChange(of: model.text) { proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .padding(24)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
