//
//  SettingsView.swift — Monad's Settings window, laid out like a VM's
//  window: a sidebar of areas (the terminal, privacy between the Mac and its
//  VMs, new-VM defaults, the Monad networks VMs join, firewall tags,
//  profiles, logs) and the chosen one beside it.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Settings: the areas in a sidebar, the chosen one beside it.
struct SettingsView: View {
    /// Opened at this size: SwiftUI would size the window only after its
    /// first render and it would open empty.
    static let size = NSSize(width: 1000, height: 640)
    /// The widest areas (a list beside an editor) need 760 beside the sidebar.
    static let minSize = NSSize(width: 980, height: 560)
    static let sidebarWidth: CGFloat = 210

    @State private var pane: SettingsPane

    init(pane: SettingsPane = .terminal) {
        _pane = State(initialValue: pane)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { p in
                HStack(spacing: 10) {
                    IconTile(symbol: p.symbol, color: p.color, size: 24)
                    Text(p.title).font(Design.body)
                }
                .padding(.vertical, 2)
                .tag(p)
            }
            .navigationSplitViewColumnWidth(min: Self.sidebarWidth, ideal: Self.sidebarWidth, max: 260)
        } detail: {
            pane.content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(pane.title)
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        .onReceive(SettingsRequest.shared.$pane.compactMap { $0 }) { p in
            pane = p
            SettingsRequest.shared.pane = nil
        }
    }
}

/// Another window asks Settings for a pane (and a firewall tag there).
@MainActor
final class SettingsRequest: ObservableObject {
    static let shared = SettingsRequest()
    @Published var pane: SettingsPane?
    @Published var tag: String?
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case terminal, privacy, machines, distributions, networks, firewall, profiles, agents, logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .privacy: return "Privacy"
        case .machines: return "Virtual Machines"
        case .distributions: return "Distributions"
        case .networks: return "Networks"
        case .firewall: return "Firewall"
        case .profiles: return "Profiles"
        case .agents: return "Agents"
        case .logs: return "Logs"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: return "terminal.fill"
        case .privacy: return "hand.raised.fill"
        case .machines: return "shippingbox.fill"
        case .distributions: return "square.stack.3d.up.fill"
        case .networks: return "network"
        case .firewall: return "shield.lefthalf.filled"
        case .profiles: return "wand.and.stars"
        case .agents: return "sparkles"
        case .logs: return "doc.text.magnifyingglass"
        }
    }

    var color: Color {
        switch self {
        case .terminal: return .gray
        case .privacy: return .blue
        case .machines: return .indigo
        case .distributions: return .green
        case .networks: return .cyan
        case .firewall: return .red
        case .profiles: return .pink
        case .agents: return .purple
        case .logs: return .orange
        }
    }

    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .terminal: TerminalSettingsPane()
        case .privacy: PrivacySettingsPane()
        case .machines: MachineSettingsPane()
        case .distributions: DistributionsSettingsPane()
        case .networks: NetworksSettingsPane()
        case .firewall: FirewallTagsSettingsPane()
        case .profiles: ProfilesSettingsPane()
        case .agents: AgentsSettingsPane()
        case .logs: LogsSettingsPane()
        }
    }
}

private func settingsChanged() {
    NotificationCenter.default.post(name: .monadSettingsChanged, object: nil)
}

// MARK: - Terminal

private struct TerminalSettingsPane: View {
    @ObservedObject private var themes = ThemeStore.shared
    @AppStorage(SettingsKey.fontSize) private var fontSize = 13.0
    @AppStorage(SettingsKey.optionAsMeta) private var optionAsMeta = true
    @AppStorage(SettingsKey.cursorBlink) private var cursorBlink = false
    @AppStorage(SettingsKey.scrollbackLines) private var scrollback = 10_000

    private static let scrollbackChoices = [1_000, 5_000, 10_000, 50_000, 100_000, 200_000]

    var body: some View {
        Form {
            Section {
                SettingRow(symbol: "textformat.size", color: .blue, title: "Font size") {
                    HStack(spacing: 6) {
                        Text("\(Int(fontSize)) pt").font(Design.value)
                        Stepper("", value: $fontSize, in: 8...36, step: 1).labelsHidden()
                    }
                }
                Slider(value: $fontSize, in: 8...36, step: 1) {
                    Text("Font size")
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger")
                }
                .labelsHidden()
                .padding(.leading, 38)
                Text("user@monad:~$ ls -la")
                    .font(.system(size: fontSize, design: .monospaced))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85)))
                    .foregroundStyle(.green)
            } header: {
                Text("Text")
            }
            Section("Appearance") {
                SettingRow(symbol: "paintpalette", color: .pink, title: "Theme",
                           detail: "For tabs whose VM has no theme of its own. View ▸ Theme changes one tab.") {
                    Picker("", selection: Binding(get: { themes.defaultThemeID }, set: { themes.defaultThemeID = $0 })) {
                        Text("Automatic (Light/Dark)").tag(ThemeCatalog.automaticID)
                        Divider()
                        ForEach(themes.catalog.themes) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HStack {
                    Spacer()
                    Button("Edit Themes…") { (NSApp.delegate as? AppDelegate)?.showThemeEditor(nil) }
                }
            }
            Section("Behavior") {
                SettingRow(symbol: "option", color: .gray, title: "Use Option as Meta key",
                           detail: "Option+letter sends Esc+letter, as shells and editors expect.") {
                    Toggle("", isOn: $optionAsMeta).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(symbol: "cursorarrow.rays", color: .purple, title: "Blinking cursor") {
                    Toggle("", isOn: $cursorBlink).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(symbol: "scroll", color: .teal, title: "Scrollback",
                           detail: "Lines kept per tab, at most 64 MB each (fewer lines in very wide windows). Applies to new tabs.") {
                    Picker("", selection: $scrollback) {
                        ForEach(Self.choices(including: scrollback), id: \.self) { n in
                            Text("\(n.formatted()) lines").tag(n)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
        .font(Design.body)
        .onChange(of: fontSize) { settingsChanged() }
        .onChange(of: cursorBlink) { settingsChanged() }
    }

    private static func choices(including current: Int) -> [Int] {
        scrollbackChoices.contains(current) ? scrollbackChoices : (scrollbackChoices + [current]).sorted()
    }
}

// MARK: - Privacy

private struct PrivacySettingsPane: View {
    @AppStorage(SettingsKey.allowOSC52) private var allowOSC52 = true

    var body: some View {
        Form {
            Section {
                SettingRow(symbol: "doc.on.clipboard", color: .orange, title: "Let VMs set the clipboard",
                           detail: "Programs in a VM may copy text to the Mac's clipboard (OSC 52), up to 100 KB, from the tab you are looking at. Never while the VM boots.") {
                    Toggle("", isOn: $allowOSC52).labelsHidden().toggleStyle(.switch)
                }
            } header: {
                Text("Clipboard")
            } footer: {
                Notice(symbol: "lock.fill", color: .green,
                       text: "VMs can never read the Mac's clipboard. Images reach a VM only when you paste or drop them into its tab.")
                    .font(Design.caption)
            }
        }
        .formStyle(.grouped)
        .font(Design.body)
    }
}

// MARK: - Logs

private struct LogsSettingsPane: View {
    @State private var enabled = DebugLog.load()
    @State private var errorMessage: String?

    private var today: URL { DebugLog.shared.currentFile }

    var body: some View {
        Form {
            Section {
                SettingRow(symbol: "doc.text.magnifyingglass", color: .gray, title: "Debug logging",
                           detail: "Monad and its VM service write each step they take to a log file, one a day. Turn it on to look into a problem, and include the file when you report one.") {
                    Toggle("", isOn: Binding(get: { enabled }, set: { set($0) })).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(symbol: "folder", color: .blue, title: "Log files",
                           detail: Paths.logs.path.replacingOccurrences(of: Paths.home.path, with: "~")
                               + "/monad_<date>.log, the last \(DebugLog.keepDays) days.") {
                    HStack {
                        Button("Open Today's Log") { NSWorkspace.shared.open(today) }
                            .disabled(!FileManager.default.fileExists(atPath: today.path))
                        Button("Show in Finder") {
                            try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: today.path) ? today : Paths.logs])
                        }
                    }
                }
            } header: {
                Text("Logs")
            } footer: {
                Notice(symbol: "lock.fill", color: .green,
                       text: "Logs stay on this Mac, readable only by you. They hold VM names, folder paths, commands Monad runs and what they print.")
                    .font(Design.caption)
            }
        }
        .formStyle(.grouped)
        .font(Design.body)
        .alert("Could not change debug logging", isPresented: Binding(get: { errorMessage != nil },
                                                                     set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func set(_ on: Bool) {
        do {
            // MonadHost follows through the notification the save posts.
            try DebugLog.save(enabled: on)
            DebugLog.shared.reloadSettings()
            enabled = on
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Virtual machines

private struct MachineSettingsPane: View {
    @AppStorage(SettingsKey.defaultCPUs) private var cpus = 2
    @AppStorage(SettingsKey.defaultMemoryGiB) private var memory = 4
    @AppStorage(SettingsKey.defaultDiskGiB) private var disk = 50

    private let capacity = HostCapacity.current

    var body: some View {
        Form {
            Section {
                QuantityRow(symbol: "cpu", color: .blue, title: "CPUs", value: $cpus, range: 1...capacity.maxCPUs,
                            unit: cpus == 1 ? "core" : "cores")
                QuantityRow(symbol: "memorychip", color: .green, title: "Memory", value: $memory,
                            range: 1...capacity.maxMemoryGiB, unit: "GB",
                            detail: "At most \(capacity.maxMemoryGiB) GB of this Mac's \(capacity.memoryGiB) GB.")
                QuantityRow(symbol: "internaldrive", color: .gray, title: "Disk", value: $disk, range: 10...1024, step: 10,
                            unit: "GB", detail: "Disks grow as they fill. This is the most a VM can use.")
            } header: {
                Text("New VMs start with")
            } footer: {
                Text(capacity.summary).font(Design.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .font(Design.body)
        .onAppear {
            cpus = capacity.clampCPUs(cpus)
            memory = capacity.clampMemory(memory)
        }
    }
}

// MARK: - Networks

private struct NetworksSettingsPane: View {
    @StateObject private var model = NetworkEditorModel()
    @State private var confirmDelete = false
    @State private var creating = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if model.draft != nil {
                editor
            } else {
                Text("No network selected").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(Design.body)
        .confirmationDialog("Delete the network “\(model.saved?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete() }
        } message: {
            Text("VMs on it lose their network until they are moved to another one.")
        }
        .sheet(isPresented: $creating) {
            NetworkSheet(editing: nil) { name in
                creating = false
                if let name { model.reload(selecting: name) }
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.saved?.name }, set: { if let n = $0 { model.select(n) } })) {
                ForEach(model.names, id: \.self) { name in
                    Label(name, systemImage: name == NetworkDefinition.defaultName ? "network.badge.shield.half.filled" : "network")
                        .tag(name)
                }
            }
            .listStyle(.sidebar)
            HStack(spacing: 4) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .help("New network")
                Button { confirmDelete = true } label: { Image(systemName: "minus") }
                    .disabled(!model.canDelete)
                    .help("Delete network")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(width: 180)
    }

    private var draft: Binding<NetworkDefinition> {
        Binding(get: { model.draft ?? .builtInDefault }, set: { model.draft = $0 })
    }

    private var editor: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if model.canRename {
                        TextField("Name", text: draft.name)
                    } else {
                        LabeledContent("Name", value: draft.wrappedValue.name)
                    }
                    Picker("Kind", selection: draft.kind) {
                        ForEach(NetworkDefinition.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField("Subnet", text: draft.subnet, prompt: Text("10.78.0.0/24"))
                } header: {
                    Text("Network")
                } footer: {
                    Text(draft.wrappedValue.kind.summary).font(Design.caption).foregroundStyle(.secondary)
                }
                Section {
                    SettingRow(symbol: "point.3.connected.trianglepath.dotted", color: .indigo,
                               title: "VMs can reach each other",
                               detail: "Off: each VM on this network reaches the gateway only, never another VM. Running VMs follow at their next start.") {
                        Toggle("", isOn: draft.vmsReachEachOther).labelsHidden().toggleStyle(.switch)
                    }
                    if draft.wrappedValue.kind == .hostOnly {
                        SettingRow(symbol: "magnifyingglass", color: .blue, title: "Look up names through this Mac",
                                   detail: "Off: nothing leaves this network, name lookups included. On: lookups go to the Mac's DNS servers, and a VM could send data out in them.") {
                            Toggle("", isOn: draft.lookupsThroughTheMac).labelsHidden().toggleStyle(.switch)
                        }
                    }
                }
                Section {
                    Notice(symbol: "shield.lefthalf.filled", color: .blue,
                           text: "Each VM has its own firewall, on its Network page. Reusable rule lists are in Firewall.")
                        .font(Design.caption)
                }
                if let problem = model.errorMessage {
                    Section { Notice(symbol: "exclamationmark.triangle.fill", color: .red, text: problem) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Revert") { model.revert() }.disabled(!model.isDirty)
                Button("Save") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isDirty)
            }
            .padding(12)
        }
    }
}

/// New Network, or one to edit, as a sheet (Settings › Networks' "+" and
/// the canvas): the networks editor's model and checks.
struct NetworkSheet: View {
    let editing: String?
    /// VMs on the network being edited: it is deleted only when none is.
    let usedBy: Int
    /// The name, just before it is saved (the canvas places the new group).
    var willSave: (String) -> Void
    /// The network saved, or nil (cancelled or deleted).
    var onDone: (String?) -> Void
    @StateObject private var model: NetworkEditorModel

    init(editing: String?, usedBy: Int = 0, willSave: @escaping (String) -> Void = { _ in },
         onDone: @escaping (String?) -> Void) {
        self.editing = editing
        self.usedBy = usedBy
        self.willSave = willSave
        self.onDone = onDone
        _model = StateObject(wrappedValue: NetworkEditorModel(startingNew: editing == nil))
    }

    private var draft: Binding<NetworkDefinition> {
        Binding(get: { model.draft ?? .builtInDefault }, set: { model.draft = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "point.3.filled.connected.trianglepath.dotted", color: .indigo,
                       title: editing ?? "New Network", subtitle: draft.wrappedValue.kind.summary)
                .padding(.horizontal, 24).padding(.top, 18)
            Form {
                Section {
                    if model.canRename {
                        TextField("Name", text: draft.name)
                    } else {
                        LabeledContent("Name", value: draft.wrappedValue.name)
                    }
                    Picker("Kind", selection: draft.kind) {
                        ForEach(NetworkDefinition.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField("Subnet", text: draft.subnet, prompt: Text("10.78.0.0/24"))
                    Toggle("VMs can reach each other", isOn: draft.vmsReachEachOther)
                } footer: {
                    Text("Each VM has its own firewall, on its Network page.")
                        .font(Design.caption).foregroundStyle(.secondary)
                }
                if let problem = model.errorMessage {
                    Section { Notice(symbol: "exclamationmark.triangle.fill", color: .red, text: problem) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if editing != nil, model.canDelete {
                    Button("Delete", role: .destructive) { if model.delete() { onDone(nil) } }
                        .disabled(usedBy > 0)
                        .help(usedBy > 0 ? "VMs are on this network: move them first" : "Delete this network")
                }
                Spacer()
                Button("Cancel", role: .cancel) { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Create" : "Save") {
                    if let name = model.draft?.name { willSave(name) }
                    if model.save() { onDone(model.saved?.name) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.isDirty)
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 520, height: 480)
        .onAppear { if let editing { model.select(editing) } }
    }
}

private struct FirewallTagsSettingsPane: View {
    @ObservedObject private var host = HostAgent.client
    @StateObject private var model = FirewallTagEditorModel(members: HostAgent.client)
    @State private var confirmDelete = false
    @State private var saving = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if model.draftName != nil {
                editor
            } else {
                VStack(spacing: 10) {
                    Text("No firewall tags").font(Design.rowTitle)
                    Text("A tag is a list of firewall rules that VMs can carry. Edit it once, and every VM with it follows.")
                        .font(Design.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("New Tag") { model.addTag() }
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(Design.body)
        .onReceive(SettingsRequest.shared.$tag.compactMap { $0 }) { name in
            model.open(name)
            SettingsRequest.shared.tag = nil
        }
        .confirmationDialog("Delete the tag “\(model.saved?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await model.delete() } }
        } message: {
            Text("It is taken off the VMs that carry it, and they lose its rules at once.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.saved?.name }, set: { if let n = $0 { model.select(n) } })) {
                ForEach(model.names, id: \.self) { name in
                    Label(name, systemImage: "tag").tag(name)
                }
            }
            .listStyle(.sidebar)
            HStack(spacing: 4) {
                Button { model.addTag() } label: { Image(systemName: "plus") }
                    .help("New tag")
                Button { confirmDelete = true } label: { Image(systemName: "minus") }
                    .disabled(!model.canDelete)
                    .help("Delete tag")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(width: 180)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if model.canRename {
                        TextField("Name", text: Binding(get: { model.draftName ?? "" }, set: { model.draftName = $0 }))
                    } else {
                        LabeledContent("Name", value: model.draftName ?? "")
                    }
                    SettingRow(symbol: "questionmark.bubble", color: .blue, title: "Ask about new connections",
                               detail: "Monitor mode for every VM with this tag. Answers can be saved to the tag.") {
                        Toggle("", isOn: $model.monitor).labelsHidden().toggleStyle(.switch)
                    }
                } header: {
                    Text("Tag")
                } footer: {
                    Text("VMs refer to a tag by name, so it is fixed once saved.")
                        .font(Design.caption).foregroundStyle(.secondary)
                }
                Section {
                    FirewallRuleRows(editor: $model.rules)
                } header: {
                    Text("Rules")
                } footer: {
                    Text(FirewallText.rulesFooter + " A tag's rules come after the VM's own.")
                        .font(Design.caption).foregroundStyle(.secondary)
                }
                Section {
                    if model.vms.isEmpty {
                        Text("There are no VMs yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.vms, id: \.name) { vm in
                        Toggle(isOn: Binding(get: { model.selectedVMs.contains(vm.name) },
                                             set: { model.setVM(vm.name, selected: $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vm.name)
                                if vm.effect != .active {
                                    Text(vm.effect.explanation).font(Design.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                } header: {
                    Text("VMs with This Tag")
                } footer: {
                    Text("Optional. VMs can also be given tags on their Network page.")
                        .font(Design.caption).foregroundStyle(.secondary)
                }
                if let problem = model.errorMessage {
                    Section { Notice(symbol: "exclamationmark.triangle.fill", color: .red, text: problem) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Revert") { model.revert() }.disabled(!model.isDirty || saving)
                Button("Save") {
                    saving = true
                    Task {
                        await model.save()
                        saving = false
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!model.isDirty || saving)
            }
            .padding(12)
        }
    }
}

// MARK: - Distributions

/// Monad's distributions and the ones you added: one file each in the
/// distros folder (docs/DISTROS.md), checked and shown before it is kept.
private struct DistributionsSettingsPane: View {
    @ObservedObject private var host = HostAgent.client
    @StateObject private var store = DistroStore(bundled: DistroCatalog.shipped ?? DistroCatalog.empty)
    @State private var importing = false
    @State private var editing: (draft: DistroDraft, existing: Bool)?
    @State private var pending: (data: Data, preview: DistroStore.Preview)?
    @State private var removing: DistroConfig?
    @State private var problem: String?
    /// macOS restore images kept after a download, for the next Mac VM.
    @State private var restoreImages: [ImagePipeline.RestoreImageFile] = []
    @State private var removingRestoreImage: String?

    var body: some View {
        Form {
            Section {
                ForEach(store.catalog.distros.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                        id: \.id) { d in
                    let added = store.catalog.added[d.id] != nil
                    SettingRow(symbol: added ? "square.and.arrow.down.fill" : "shippingbox.fill",
                               color: added ? .green : .gray, title: d.name, detail: detail(d, added: added)) {
                        if added {
                            HStack {
                                Button("Edit…") { editing = (DistroDraft(d), true) }
                                Button("Remove…") { removing = d }
                            }
                        }
                    }
                }
            } header: {
                Text("Distributions")
            } footer: {
                Text("A distribution is one file that says where its cloud images are and how to check them. "
                     + "Yours go in the distros folder, next to Monad's own. The VM itself works out the rest when it boots.")
                    .font(Design.caption).foregroundStyle(.secondary)
            }
            if !restoreImages.isEmpty {
                Section {
                    ForEach(restoreImages, id: \.file) { image in
                        SettingRow(symbol: "apple.logo", color: .gray, title: image.file,
                                   detail: ByteCountFormatter.string(fromByteCount: image.bytes, countStyle: .file)) {
                            Button("Remove…") { removingRestoreImage = image.file }
                        }
                    }
                } header: {
                    Text("macOS Restore Images")
                } footer: {
                    Text("Kept after a download, so the next Mac VM installs without one. Mac VMs already made do not need them.")
                        .font(Design.caption).foregroundStyle(.secondary)
                }
            }
            if !store.catalog.problems.isEmpty {
                Section("Not loaded") {
                    ForEach(store.catalog.problems, id: \.file) { p in
                        Notice(symbol: "exclamationmark.triangle.fill", color: .orange, text: "\(p.file): \(p.message)")
                    }
                }
            }
            Section {
                HStack {
                    Button("New Distribution…") { editing = (DistroDraft(), false) }
                    Button("Add From File…") { importing = true }
                    Button("Show Folder") { showFolder() }
                    Spacer()
                    Button("Reload") { store.reload() }.help("Read the distros folder again")
                }
            }
        }
        .formStyle(.grouped)
        .font(Design.body)
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let e = editing {
                DistroEditor(draft: e.draft, existing: e.existing,
                             builtIn: Set((DistroCatalog.shipped ?? .empty).distros.map(\.id))) { draft in
                    try store.add(draft.json())
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                pending = (data, try store.check(data))
            } catch {
                problem = "\(url.lastPathComponent): \(DistroCatalog.describe(error))"
            }
        }
        .confirmationDialog(pending.map { "Add \($0.preview.distro.name)?" } ?? "",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(pending?.preview.replaces == true ? "Replace" : "Add") {
                guard let p = pending else { return }
                do { try store.add(p.data) } catch { problem = DistroCatalog.describe(error) }
                pending = nil
            }
        } message: {
            if let p = pending?.preview {
                Text("Images come from \(p.checksums), checked by \(p.verification). "
                     + (p.replaces ? "It replaces the \(p.distro.id) you added before." : "New VMs can use it at once."))
            }
        }
        .confirmationDialog(removing.map { "Remove \($0.name)?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                guard let d = removing else { return }
                let users = host.instances.filter { $0.config.distro == d.id }.map(\.name)
                do { try store.remove(d.id, usedBy: users) } catch { problem = DistroCatalog.describe(error) }
                removing = nil
            }
        } message: {
            Text("Its file is deleted from the distros folder. Images already downloaded stay in the cache.")
        }
        .confirmationDialog("Remove \(removingRestoreImage ?? "")?",
                            isPresented: Binding(get: { removingRestoreImage != nil }, set: { if !$0 { removingRestoreImage = nil } })) {
            Button("Remove", role: .destructive) {
                guard let file = removingRestoreImage else { return }
                do { try ImagePipeline.removeRestoreImage(file) } catch { problem = error.localizedDescription }
                restoreImages = ImagePipeline.restoreImages()
                removingRestoreImage = nil
            }
        } message: {
            Text("The next Mac VM downloads macOS again.")
        }
        .onAppear { restoreImages = ImagePipeline.restoreImages() }
        .alert("Distribution not changed", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private func detail(_ d: DistroConfig, added: Bool) -> String {
        let releases = d.releases.map(\.name).joined(separator: ", ")
        let check = d.isSigned ? "signed" : "checksums over HTTPS only"
        return "\(releases) · \(check) · " + (added ? "added (\(d.id).distro.json)" : "comes with Monad")
    }

    private func showFolder() {
        try? FileManager.default.createDirectory(at: Paths.distros, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(Paths.distros)
    }
}

/// New Distribution… and Edit…: the distro file as a form. Simple is like
/// picking a disk image in a virtual machine app: the image's address (or a
/// file on this Mac) is all it takes; Monad looks next to it for checksums
/// and their signature and takes the name and version from its file name.
/// Advanced shows every field of the file, and its Check fetches and
/// verifies the checksum file and finds the image without downloading it.
private struct DistroEditor: View {
    @State var draft: DistroDraft
    let existing: Bool
    let builtIn: Set<String>
    let save: (DistroDraft) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var advanced = false
    @State private var importingKey = false
    @State private var importingImage = false
    /// Simple: looking next to the image for its checksums.
    @State private var looking = false
    /// The link Simple last looked at (its result is in the draft).
    @State private var looked: String?
    @State private var linkProblem: String?
    @State private var checking = false
    /// Check's result, for the draft it checked: nil ok means it read the
    /// checksum file and something is still to fill in.
    @State private var checked: (draft: DistroDraft, ok: Bool?, text: String)?
    /// The images the checksum file lists, from Check.
    @State private var images: [String] = []
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if advanced { advancedSections } else { simpleSections }
                if let other = draft.problems[.other] {
                    Section { Notice(symbol: "exclamationmark.triangle.fill", color: .orange, text: other) }
                }
                if advanced, let checked, checked.draft == draft {
                    Section("Check") {
                        switch checked.ok {
                        case true?: Notice(symbol: "checkmark.seal.fill", color: .green, text: checked.text)
                        case false?: Notice(symbol: "xmark.octagon.fill", color: .red, text: checked.text)
                        case nil: Notice(symbol: "info.circle.fill", color: .blue, text: checked.text)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: 12) {
                Toggle("Advanced", isOn: Binding(get: { advanced }, set: { on in
                    if !on {
                        draft.showLink()
                        looked = draft.link
                    }
                    advanced = on
                }))
                .toggleStyle(.switch).controlSize(.small)
                .disabled(advanced && draft.needsAdvanced)
                .help(advanced && draft.needsAdvanced ? "This distribution uses fields only Advanced shows"
                      : "Every field of the distribution file")
                if advanced {
                    Button("Check") { check() }
                        .disabled(!draft.canCheck || checking)
                        .help("Read the checksum file and its signature, and find the image, without downloading it")
                    if checking { ProgressView().controlSize(.small) }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing ? "Save" : "Add") {
                    do {
                        try save(draft)
                        dismiss()
                    } catch {
                        saveError = DistroCatalog.describe(error)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(looking || !draft.problems.isEmpty
                          || (!existing && DistroDraft.problem(id: draft.id, builtIn: builtIn) != nil))
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 620, height: advanced ? 720 : 560)
        .font(Design.body)
        .onAppear {
            advanced = draft.needsAdvanced
            if !draft.link.isEmpty { looked = draft.link }
        }
        .task(id: draft.link) { await look(at: draft.link) }
        .fileImporter(isPresented: $importingKey, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try draft.readKey(from: url)
                draft.setKey(draft.publicKey)
            } catch {
                saveError = DistroCatalog.describe(error)
            }
        }
        .fileImporter(isPresented: $importingImage, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            draft.link = url.path
        }
        .alert("Not saved", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: Simple

    @ViewBuilder
    private var simpleSections: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    IconTile(symbol: "opticaldiscdrive.fill", color: .indigo, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Disk image").font(.headline)
                        Text("A cloud image for arm64: .qcow2, .img or .raw, also compressed as .xz or .gz.")
                            .font(Design.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("", text: $draft.link, prompt: Text("https://example.org/images/name-10.aarch64.qcow2"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                    Button("Choose File…") { importingImage = true }
                }
                linkStatus
            }
            .padding(.vertical, 6)
        }
        if looked != nil && looked == draft.link && linkProblem == nil {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("AlmaLinux"))
                problem(.name)
                idTaken
                TextField("Version", text: $draft.basicRelease, prompt: Text("10"))
                problem(.releases)
                packageManager
            } footer: {
                Text("Taken from the image's name. The package manager lets profiles install packages in its VMs.")
                    .font(Design.caption).foregroundStyle(.secondary)
            }
            if draft.signatureFound {
                Section {
                    keyEditor
                } header: {
                    Text("Signing key (optional)")
                } footer: {
                    Text("Its checksum file is signed. With the project's key (from its own site, often RPM-GPG-KEY-… "
                         + "or a .asc file) Monad checks that signature too.")
                        .font(Design.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var linkStatus: some View {
        if looking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Looking next to it for its checksums…").font(Design.caption).foregroundStyle(.secondary)
            }
        } else if let linkProblem {
            Notice(symbol: "xmark.octagon.fill", color: .red, text: linkProblem)
        } else if looked != nil && looked == draft.link {
            if draft.direct {
                Notice(symbol: "exclamationmark.shield.fill", color: .orange,
                       text: (draft.link.hasPrefix("/") ? "A file on this Mac. " : "No checksum file next to it. ")
                       + "Monad uses the image as it is, nothing checks it.")
            } else {
                let sums = URL(string: draft.checksumsURL)?.lastPathComponent ?? draft.checksumsURL
                Notice(symbol: "checkmark.shield.fill", color: .green,
                       text: "Every download is checked against \(sums), next to it"
                       + (draft.signature != .none ? ", and its signature against the key." : "."))
            }
        }
    }

    /// Simple's link changed: once typing stops, look next to the image.
    private func look(at text: String) async {
        guard !advanced, looked != text else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        linkProblem = nil
        guard !trimmed.isEmpty else { return }
        let link: ImageLink
        do {
            link = try ImageLink(trimmed)
        } catch {
            linkProblem = error.localizedDescription
            return
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        if link.isLocal {
            do { _ = try ImagePipeline.localImage(link.url) } catch {
                linkProblem = error.localizedDescription
                return
            }
        }
        looking = true
        defer { looking = false }
        let found = await ImagePipeline.live.discover(link)
        guard !Task.isCancelled else { return }
        var next = draft
        next.use(link, found: found)
        looked = next.link
        draft = next
    }

    // MARK: Advanced

    @ViewBuilder
    private var advancedSections: some View {
        Section("Distribution") {
            TextField("Name", text: $draft.name, prompt: Text("Required"))
            TextField("Id", text: $draft.id, prompt: Text("Follows the name")).disabled(existing)
            problem(.name)
            problem(.id)
            idTaken
            packageManager
            TextField("sshd (optional)", text: $draft.sshd, prompt: Text("/usr/sbin/sshd"))
        }
        Section {
            ForEach(draft.releases.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    TextField("", text: $draft.releases[i].id, prompt: Text("Version, like 10"))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 120)
                    TextField("", text: $draft.releases[i].name,
                              prompt: Text("Name (\(draft.name.isEmpty ? "the distro's" : draft.name) \(draft.releases[i].id))"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                    TextField("", text: $draft.releases[i].vars, prompt: Text("Extra values"))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 130)
                    Toggle("Default", isOn: Binding(get: { draft.releases[i].isDefault }, set: { on in
                        for j in draft.releases.indices { draft.releases[j].isDefault = on && j == i }
                    }))
                    .toggleStyle(.checkbox).fixedSize()
                    Button { draft.releases.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).disabled(draft.releases.count == 1)
                }
            }
            Button("Add Release") {
                draft.releases.append(.init(id: "", name: "", isDefault: draft.releases.isEmpty, vars: ""))
            }
            problem(.releases)
        } header: {
            Text("Releases")
        } footer: {
            Text("Extra values are more placeholders for that release (codename=trixie, used as {codename} in the "
                 + "addresses below).")
                .font(Design.caption).foregroundStyle(.secondary)
        }
        Section {
            Picker("Checked against", selection: $draft.direct) {
                Text("A checksum file").tag(false)
                Text("Nothing, the image as it is").tag(true)
            }
            if draft.direct {
                wide("Image address, or file:// on this Mac", $draft.imageURL,
                     prompt: "https://example.org/{release}/name-{release}.{arch}.qcow2")
                problem(.link)
            } else {
                Picker("Checksum file", selection: $draft.useIndex) {
                    Text("At an address").tag(false)
                    Text("Named in a directory listing").tag(true)
                }
                wide(draft.useIndex ? "Listing address" : "Checksum file address", $draft.checksumsURL,
                     prompt: "https://example.org/{release}/{arch}/SHA256SUMS")
                if draft.useIndex {
                    wide("File in the listing", $draft.indexPattern, prompt: "Name-{release}-*-CHECKSUM")
                }
                Picker("Its lines look like", selection: $draft.checksumFormat) {
                    Text("hash  file").tag(ChecksumFile.Format.gnu)
                    Text("SHA256 (file) = hash").tag(ChecksumFile.Format.bsd)
                    Text("just the hash").tag(ChecksumFile.Format.single)
                }
                Picker("Hash", selection: $draft.algorithm) {
                    Text("SHA-256").tag(ChecksumFile.Algorithm.sha256)
                    Text("SHA-512").tag(ChecksumFile.Algorithm.sha512)
                }
                problem(.checksums)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Image file, as the checksum file names it")
                    HStack {
                        TextField("", text: $draft.file, prompt: Text("name-{release}-*.{arch}.qcow2"))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                        if !images.isEmpty {
                            Menu("Images") {
                                ForEach(images, id: \.self) { name in
                                    Button(name) { draft.pick(name) }
                                }
                            }
                            .fixedSize()
                            .help("The images the checksum file lists")
                        }
                    }
                }
                .padding(.vertical, 2)
                problem(.file)
                wide("Image address (optional)", $draft.imageURL, prompt: "next to the checksum file")
            }
            Picker("Image format", selection: $draft.format) {
                Text("qcow2").tag(DistroConfig.ImageFormat.qcow2)
                Text("raw").tag(DistroConfig.ImageFormat.raw)
                if !draft.direct { Text("tar.xz with a raw disk").tag(DistroConfig.ImageFormat.tarXz) }
            }
            if draft.format == .tarXz {
                TextField("Disk inside the archive", text: $draft.member, prompt: Text("disk.raw"))
            } else {
                Picker("Compressed", selection: $draft.compression) {
                    Text("No").tag(DistroConfig.Compression?.none)
                    Text("xz").tag(DistroConfig.Compression?.some(.xz))
                    Text("gzip").tag(DistroConfig.Compression?.some(.gz))
                }
            }
            TextField("Architecture, as it writes it", text: $draft.arm64, prompt: Text("aarch64"))
        } header: {
            Text("Images")
        } footer: {
            Text("Monad runs Apple silicon (arm64) images. {arch} is how the distro writes that in its addresses, "
                 + "usually aarch64 or arm64. Addresses and names can also use {release} and a release's extra values. "
                 + "Give an image address only when the images are not next to the checksum file; it can use {file}, "
                 + "the image the checksum file names. Check sets the line format and the hash from the file itself.")
                .font(Design.caption).foregroundStyle(.secondary)
        }
        if !draft.direct {
            Section {
                Picker("Checksums are", selection: $draft.signature) {
                    Text("Signed, in a separate file").tag(DistroConfig.SignatureKind.detached)
                    Text("Signed, inside the file").tag(DistroConfig.SignatureKind.clearsigned)
                    Text("Not signed").tag(DistroConfig.SignatureKind.none)
                }
                if draft.signature == .detached {
                    wide("Signature address", $draft.signatureURL, prompt: "{checksums}.asc")
                    problem(.signature)
                }
                if draft.signature != .none {
                    keyEditor
                } else {
                    TextField("Why (optional)", text: $draft.note, prompt: Text("My own mirror"))
                }
            } header: {
                Text("Signature (recommended)")
            }
        }
        if let advice = draft.advice {
            Section { Notice(symbol: "info.circle.fill", color: .orange, text: advice) }
        }
    }

    // MARK: Shared

    /// A long field: its label above it, the whole width for the text.
    private func wide(_ label: String, _ text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
            TextField("", text: text, prompt: Text(prompt))
                .labelsHidden().textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var keyEditor: some View {
        TextEditor(text: Binding(get: { draft.publicKey }, set: { draft.setKey($0) }))
            .font(.system(.caption, design: .monospaced))
            .frame(height: 90)
            .overlay(alignment: .topLeading) {
                if draft.publicKey.isEmpty {
                    Text("Paste the project's public key (-----BEGIN PGP PUBLIC KEY BLOCK-----…)")
                        .font(Design.caption).foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                }
            }
        HStack {
            Button("Choose Key File…") { importingKey = true }
            Spacer()
            if !draft.fingerprints.isEmpty {
                Text(draft.fingerprints.joined(separator: ", "))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        problem(.key)
    }

    @ViewBuilder
    private var idTaken: some View {
        if !existing, let taken = DistroDraft.problem(id: draft.id, builtIn: builtIn) {
            Text(taken).font(Design.caption).foregroundStyle(.red)
        }
    }

    private var packageManager: some View {
        Picker("Package manager", selection: $draft.packageManager) {
            Text("None (no profiles)").tag("")
            Text("apt").tag("apt")
            Text("dnf").tag("dnf")
            Text("zypper").tag("zypper")
        }
    }

    @ViewBuilder
    private func problem(_ field: DistroDraft.Field) -> some View {
        if let text = draft.problems[field] {
            Text(text).font(Design.caption).foregroundStyle(.red)
        }
    }

    /// Read the checksum file and learn from it, then, once nothing is
    /// missing, verify it and find the image.
    private func check() {
        checking = true
        checked = nil
        Task {
            defer { checking = false }
            do {
                if !draft.direct {
                    let text = try await ImagePipeline.live.peek(distro: try draft.probe())
                    images = try draft.learn(from: text)
                }
                guard draft.problems.isEmpty else {
                    let listed = images.isEmpty ? "lists no disk image for this Mac"
                        : images.count == 1 ? "lists one image" : "lists \(images.count) images"
                    let next = draft.file.isEmpty && !images.isEmpty ? " Pick one from Images." : " Fill in what is missing, then Check again."
                    checked = (draft, images.isEmpty ? false : nil, "The checksum file \(listed).\(next)")
                    return
                }
                let found = try await ImagePipeline.live.check(distro: try draft.config())
                let how: String
                switch found.verification {
                case .signature(let fpr): how = "its checksums are signed by \(fpr)"
                case .checksumOverHTTPS: how = "its checksums are not signed"
                case .unverified: how = "there is nothing to check it against"
                }
                let place = found.imageURL.isFileURL ? "this Mac" : found.imageURL.host ?? found.imageURL.absoluteString
                checked = (draft, true, "Found \(found.file) on \(place), and \(how).")
            } catch {
                checked = (draft, false, DistroCatalog.describe(error))
            }
        }
    }
}

private struct ProfilesSettingsPane: View {
    private static let builtIn = (try? ProfileCatalog.bundled().builtIn) ?? []
    @StateObject private var model = ProfileEditorModel(builtIn: ProfilesSettingsPane.builtIn)
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if model.draft != nil {
                editor
            } else {
                VStack(spacing: 10) {
                    Text("No custom profiles").font(Design.rowTitle)
                    Text("A profile sets up a VM: packages, Node.js, npm packages and scripts. Agentic and Server come with Monad, and can be changed.")
                        .font(Design.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("New Profile") { model.addProfile() }
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(Design.body)
        .confirmationDialog("Delete the profile “\(model.saved?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete() }
        } message: {
            Text("VMs that chose it keep what it set up, and it is not run again.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.saved?.id }, set: { if let id = $0 { model.select(id) } })) {
                Section("Built-in") {
                    ForEach(Self.builtIn) { p in
                        HStack {
                            Label(p.name, systemImage: "shippingbox")
                            if model.editedBuiltIns.contains(p.id) {
                                Spacer()
                                Text("edited").font(Design.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(p.id)
                        .help(p.summary)
                    }
                }
                Section("Yours") {
                    ForEach(model.ids, id: \.self) { id in
                        Label(id, systemImage: "wand.and.stars").tag(id)
                    }
                }
            }
            .listStyle(.sidebar)
            HStack(spacing: 4) {
                Button { model.addProfile() } label: { Image(systemName: "plus") }
                    .help("New profile")
                Button { confirmDelete = true } label: { Image(systemName: "minus") }
                    .disabled(!model.canDelete)
                    .help(model.isBuiltIn ? "Built-in profiles are restored, not deleted" : "Delete profile")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(width: 200)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            ProfileDraftForm(model: model)
            Divider()
            HStack {
                if model.isEdited {
                    Button("Restore Default") { model.restoreDefault() }
                        .help("Use the profile as it comes with Monad again")
                }
                Spacer()
                Button("Revert") { model.revert() }.disabled(!model.isDirty)
                Button("Save") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isDirty)
            }
            .padding(12)
        }
    }
}

/// A profile's draft: its id, name and summary, and its steps (Settings ›
/// Profiles, and Create New Profile in the New VM sheet).
struct ProfileDraftForm: View {
    @ObservedObject var model: ProfileEditorModel

    var body: some View {
        Form {
            Section {
                if model.canChangeID {
                    TextField("Id", text: draft.id, prompt: Text("my-tools"))
                } else {
                    LabeledContent("Id", value: draft.wrappedValue.id)
                }
                TextField("Name", text: draft.name)
                TextField("Summary", text: draft.summary, prompt: Text("What it sets up"))
            } header: {
                Text(model.isBuiltIn ? "Built-in Profile" : "Profile")
            } footer: {
                Text(model.isBuiltIn
                     ? "Comes with Monad. Your changes are saved as your version and used instead, until you restore the default."
                     : "VMs refer to a profile by its id, so it is fixed once saved.")
                    .font(Design.caption).foregroundStyle(.secondary)
            }
            ForEach(Array((model.draft?.steps ?? []).indices), id: \.self) { i in
                stepSection(i)
            }
            Section {
                Menu {
                    Button("Packages") { model.addStep(.packages) }
                    Button("Node.js LTS") { model.addStep(.node) }
                    Button("npm Packages") { model.addStep(.npm) }
                    Button("Script") { model.addStep(.script) }
                } label: {
                    Label("Add Step", systemImage: "plus")
                }
                .fixedSize()
            } footer: {
                Text("Steps run in order, as root, each skipping what is already there. Names are separated by spaces. A step fails if a command it lists is not on PATH afterwards.")
                    .font(Design.caption).foregroundStyle(.secondary)
            }
            if let problem = model.errorMessage {
                Section { Notice(symbol: "exclamationmark.triangle.fill", color: .red, text: problem) }
            }
        }
        .formStyle(.grouped)
    }

    private var draft: Binding<ProfileConfig> {
        Binding(get: { model.draft ?? ProfileConfig(id: "", name: "", summary: "", steps: []) }, set: { model.draft = $0 })
    }

    private func stepSection(_ i: Int) -> some View {
        let step = model.step(i)
        return Section {
            TextField("Title", text: Binding(get: { model.step(i)?.title ?? "" }, set: { t in model.updateStep(i) { $0.title = t } }))
            switch step?.kind {
            case .packages:
                ForEach(["apt", "dnf", "zypper"], id: \.self) { m in
                    TextField(m, text: Binding(get: { model.packagesText(i, manager: m) }, set: { model.setPackages(i, manager: m, $0) }),
                              prompt: Text(m == "apt" ? "Debian, Ubuntu" : m == "dnf" ? "Fedora" : "openSUSE"))
                }
            case .runtime:
                Text("The newest Node.js LTS for the VM's CPU, from nodejs.org, checked against its checksums.")
                    .font(Design.caption).foregroundStyle(.secondary)
            case .npm:
                TextField("npm", text: Binding(get: { model.npmText(i) }, set: { model.setNPM(i, $0) }),
                          prompt: Text("typescript @scope/tool"))
            case .script:
                TextEditor(text: Binding(get: { model.step(i)?.script ?? "" }, set: { t in model.updateStep(i) { $0.script = t } }))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 110)
            case nil:
                EmptyView()
            }
            TextField("Commands", text: Binding(get: { model.commandsText(i) }, set: { model.setCommands(i, $0) }),
                      prompt: Text("Optional, checked on PATH afterwards"))
        } header: {
            HStack {
                Text("Step \(i + 1)")
                Spacer()
                Button { model.moveStep(i, up: true) } label: { Image(systemName: "arrow.up") }
                    .disabled(i == 0).help("Move up")
                Button { model.moveStep(i, up: false) } label: { Image(systemName: "arrow.down") }
                    .disabled(i + 1 >= (model.draft?.steps.count ?? 0)).help("Move down")
                Button { model.removeStep(i) } label: { Image(systemName: "trash") }
                    .help("Remove step")
            }
            .buttonStyle(.borderless)
        }
    }
}

#if DEBUG
#Preview("Settings") { SettingsView(pane: .networks).frame(width: SettingsView.size.width, height: SettingsView.size.height) }
#Preview("Networks") { NetworksSettingsPane().frame(width: 760, height: 560) }
#Preview("New Network") { NetworkSheet(editing: nil) { _ in } }
#Preview("Profiles") { ProfilesSettingsPane().frame(width: 760, height: 560) }
#Preview("Firewall") { FirewallTagsSettingsPane().frame(width: 760, height: 560) }
#Preview("Terminal") { TerminalSettingsPane().frame(width: 560, height: 470) }
#Preview("Privacy") { PrivacySettingsPane().frame(width: 560, height: 470) }
#Preview("Virtual Machines") { MachineSettingsPane().frame(width: 560, height: 470) }
#Preview("Logs") { LogsSettingsPane().frame(width: 560, height: 470) }
#Preview("New Distribution") { DistroEditor(draft: DistroDraft(), existing: false, builtIn: []) { _ in } }
#Preview("New Distribution, found") {
    let dir = "https://repo.almalinux.org/almalinux/10/cloud/aarch64/images/"
    var draft = DistroDraft()
    draft.use(try! ImageLink(dir + "AlmaLinux-10-GenericCloud-latest.aarch64.qcow2"),
              found: ImageDiscovery(checksums: .init(url: URL(string: dir + "CHECKSUM")!, format: .gnu, algorithm: .sha256,
                                                     signature: .detached, signatureURL: URL(string: dir + "CHECKSUM.asc")!)))
    return DistroEditor(draft: draft, existing: false, builtIn: []) { _ in }
}
#endif
