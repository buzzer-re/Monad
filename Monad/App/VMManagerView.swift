//
//  VMManagerView.swift — list, create, start/stop and delete VMs (all
//  owned by MonadHost; this view mirrors them through HostClient), and the
//  Lima VMs on this Mac that Monad can boot where they are (LimaList).
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Shell ▸ New VM… asks the Virtual Machines window for its New VM sheet,
/// open or not yet.
@MainActor
final class NewVMRequest: ObservableObject {
    static let shared = NewVMRequest()
    @Published var pending = false
}

struct VMManagerView: View {
    enum Tab: Hashable { case monad, lima }

    /// One sheet at a time (two sheet modifiers on one view do not both
    /// present on macOS).
    enum Sheet: Identifiable {
        case create
        case importing(VMConfigFile.Imported, file: String)

        var id: String {
            switch self {
            case .create: return "create"
            case .importing(_, let file): return "import " + file
            }
        }
    }

    @ObservedObject var host: HostClient
    @ObservedObject private var newVM = NewVMRequest.shared
    @State private var sheet: Sheet?
    /// The VM whose handle is being dragged, and the row under the pointer.
    @State private var dragging: String?
    @State private var dropTarget: String?
    @State private var errorMessage: String?
    @State private var tab = Tab.monad
    /// Bumped by "Look Again" to list the Lima VMs once more.
    @State private var limaLook = 0
    /// The groups' order, the empty ones and which are collapsed (VMGroups).
    @State private var groups = VMGroupStore().load()
    /// A group being named: a new one (for `forVM`, if any) or a rename.
    @State private var naming: GroupNaming?
    @State private var groupName = ""
    @State private var deletingGroup: String?
    /// The VM being duplicated, the copy's name, and what was not copied.
    @State private var duplicating: String?
    @State private var copyName = ""
    @State private var copyNotice: String?
    /// The VM whose disk is to be repaired (asked first), and what Repair Disk did.
    @State private var repairing: String?
    @State private var repairNotice: String?
    @State private var dropGroup: String??

    struct GroupNaming: Identifiable {
        var renaming: String?
        var forVM: String?
        var id: String { (renaming ?? "+") + (forVM ?? "") }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if host.status == .connected && host.hostIsOutdated {
                OutdatedHostNotice(host: host)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Color.orange.opacity(0.12))
            } else if let notice = hostNotice {
                Notice(symbol: "exclamationmark.triangle.fill", color: .orange, text: notice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Color.orange.opacity(0.12))
            }
            if tab == .lima {
                LimaTab(host: host, look: limaLook, onError: { errorMessage = $0 })
            } else if host.instances.isEmpty {
                ContentUnavailableView {
                    Label("No Virtual Machines", systemImage: "shippingbox")
                } description: {
                    Text("Open a tab to create the default VM, or create one with its own distribution and size.")
                } actions: {
                    Button("New VM…") { sheet = .create }.controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // Dragged by their handle and dropped on another row (or a
                    // group's heading): the order, and the group.
                    // Headings are rows, not section headers: they scroll with
                    // the list instead of sticking over one another.
                    ForEach(sections, id: \.group) { section in
                        groupHeader(section)
                            .listRowSeparator(.hidden)
                        if !section.collapsed {
                            ForEach(section.vms.compactMap { name in persistent.first { $0.name == name } }) { vm in
                                row(vm, in: section)
                            }
                            if section.vms.isEmpty, section.group != nil {
                                Text("No VMs. Drag one here, or use Move to Group in a VM's ⋯ menu.")
                                    .font(Design.caption).foregroundStyle(.secondary)
                                    .padding(.leading, 62).padding(.vertical, 4)
                                    .listRowSeparator(.hidden)
                            }
                        }
                    }
                    ForEach(host.instances.filter(\.config.ephemeral)) { vm in
                        VMRow(vm: vm, host: host, isDefault: false, place: nil, dropEdge: nil, onDragStart: {},
                              onError: { errorMessage = $0 }, groups: [], onGroup: { _ in }, onNewGroup: {})
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
            Divider()
            HStack {
                Text(HostCapacity.current.summary).font(Design.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSWorkspace.shared.open(Paths.instances)
                } label: {
                    Label("Show Files", systemImage: "folder")
                }
                .help("Open ~/.monad/instances in Finder")
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
        .frame(minWidth: 720, minHeight: 360)
        .onAppear(perform: takeNewVMRequest)
        .onChange(of: newVM.pending) { takeNewVMRequest() }
        .sheet(item: $sheet) { which in
            switch which {
            case .create:
                CreateVMSheet { config in
                    let vm = try await host.create(config)
                    (NSApp.delegate as? AppDelegate)?.openTab(in: vm)
                    sheet = nil
                } onCancel: { sheet = nil }
            case .importing(let imported, let file):
                ImportVMSheet(imported: imported, file: file, taken: Set(host.instances.map(\.name))) { config in
                    let vm = try await host.create(config)
                    sheet = nil
                    (NSApp.delegate as? AppDelegate)?.showDetails(of: vm)
                } onCancel: { sheet = nil }
            }
        }
        .alert(naming?.renaming.map { "Rename “\($0)”" } ?? "New Group", isPresented: Binding(
            get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("coding, analysis, agents…", text: $groupName)
            Button(naming?.renaming == nil ? "Create" : "Rename") { finishNaming() }
            Button("Cancel", role: .cancel) { naming = nil }
        } message: {
            Text(naming?.renaming == nil
                 ? "A group gathers VMs in this list, and works as a firewall tag: its rules apply to every VM in it."
                 : "Its VMs and its firewall rules go with it.")
        }
        .confirmationDialog("Delete the group “\(deletingGroup ?? "")”?", isPresented: Binding(
            get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } }), titleVisibility: .visible) {
            Button("Delete Group", role: .destructive) { if let g = deletingGroup { deleteGroup(g) } }
            Button("Cancel", role: .cancel) { deletingGroup = nil }
        } message: {
            Text("Its VMs stay, in no group, and lose the group's firewall rules. The rules stay in Settings › Firewall as a tag.")
        }
        .alert("Duplicate “\(duplicating ?? "")”", isPresented: Binding(
            get: { duplicating != nil }, set: { if !$0 { duplicating = nil } })) {
            TextField("Name", text: $copyName)
            Button("Duplicate") { finishDuplicating() }
            Button("Cancel", role: .cancel) { duplicating = nil }
        } message: {
            Text("The same Mac, with its own identity. Its disk is cloned, so it takes no room until it changes. "
                 + "What was allowed for this VM alone (shared folders, bridges, host commands, forwards into the Mac) "
                 + "is not copied.")
        }
        .alert("Duplicated", isPresented: Binding(get: { copyNotice != nil }, set: { if !$0 { copyNotice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(copyNotice ?? "")
        }
        .confirmationDialog("Repair the disk of “\(repairing ?? "")”?", isPresented: Binding(
            get: { repairing != nil }, set: { if !$0 { repairing = nil } }), titleVisibility: .visible) {
            Button("Repair Disk") { if let name = repairing { repairDisk(name) } }
            Button("Cancel", role: .cancel) { repairing = nil }
        } message: {
            Text(VMSettingsDraft.repairDiskText)
        }
        .alert("Repair Disk", isPresented: Binding(get: { repairNotice != nil }, set: { if !$0 { repairNotice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(repairNotice ?? "")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil },
                                                           set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            IconTile(symbol: "shippingbox.fill", color: .indigo, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Virtual Machines").font(.system(size: 20, weight: .bold))
                Text(countLine).font(Design.body).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $tab) {
                Text("Monad").tag(Tab.monad)
                Text("Lima").tag(Tab.lima)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            if tab == .lima {
                Button {
                    limaLook += 1
                } label: {
                    Label("Look Again", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
            } else {
                Button {
                    groupName = ""
                    naming = GroupNaming()
                } label: {
                    Label("New Group", systemImage: "folder.badge.plus")
                }
                .controlSize(.large)
                .help("Gather VMs (coding, analysis, agents…); a group's firewall rules apply to its VMs")
                Button {
                    importFile()
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .controlSize(.large)
                .help("Make a VM from a settings file (docs/CONFIG.md)")
                Button {
                    sheet = .create
                } label: {
                    Label("New VM", systemImage: "plus")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func takeNewVMRequest() {
        guard newVM.pending else { return }
        newVM.pending = false
        tab = .monad
        sheet = .create
    }

    /// Import…: a VM's settings file, read and fitted to this Mac, then the
    /// import sheet.
    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a VM's settings file (exported from a VM's Configuration page, or written by hand)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try VMConfigFile.load(url, on: .current(taken: host.instances.map(\.name)))
            sheet = .importing(imported, file: url.lastPathComponent)
        } catch {
            errorMessage = HostAgent.describe(error)
        }
    }

    /// The VMs that can be dragged (ephemeral ones are listed after them).
    private var persistent: [RemoteVM] { host.instances.filter { !$0.config.ephemeral } }

    private var sections: [VMGroups.Section] {
        groups.sections(persistent.map(\.name), configs: Dictionary(persistent.map { ($0.name, $0.config) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Every group there is, saved or named by a VM.
    private var groupNames: [String] { sections.compactMap(\.group) }

    private func row(_ vm: RemoteVM, in section: VMGroups.Section) -> some View {
        let names = section.vms
        return VMRow(vm: vm, host: host, isDefault: vm === host.defaultVM,
                     place: names.count > 1 ? (vm.name == names.first ? .top : vm.name == names.last ? .bottom : .middle) : nil,
                     dropEdge: dropTarget == vm.name ? VMOrder.dropEdge(names, dragging: dragging, over: vm.name) : nil,
                     onDragStart: { dragging = vm.name },
                     onError: { errorMessage = $0 },
                     groups: groupNames,
                     onGroup: { setGroup(vm.name, $0) },
                     onNewGroup: {
                         groupName = ""
                         naming = GroupNaming(forVM: vm.name)
                     },
                     onDuplicate: {
                         copyName = InstanceConfig.copyName(of: vm.name, taken: host.instances.map(\.name))
                         duplicating = vm.name
                     },
                     onRepair: { repairing = vm.name })
            .onDrop(of: [.plainText], isTargeted: Binding(
                get: { dropTarget == vm.name },
                set: { over in
                    if over { dropTarget = vm.name } else if dropTarget == vm.name { dropTarget = nil }
                })) { providers in
                drop(providers, onto: vm.name)
            }
    }

    /// A group's heading: collapse, name and count, its menu; a VM dropped
    /// on it joins it. VMs in no group get a plain heading once there are
    /// groups.
    @ViewBuilder private func groupHeader(_ section: VMGroups.Section) -> some View {
        let vms = section.vms.compactMap { name in persistent.first { $0.name == name } }
        let running = vms.filter(\.isRunning).count
        let target = dropGroup.map { $0 == section.group } ?? false
        if let group = section.group {
            HStack(spacing: 14) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(section.collapsed ? 0 : 90))
                    .animation(.snappy(duration: 0.18), value: section.collapsed)
                    .frame(width: 22)
                IconTile(symbol: section.collapsed ? "folder.fill" : "folder", color: .indigo, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group).font(.system(size: 17, weight: .bold))
                    Text(vms.isEmpty ? "No VMs" : "\(vms.count) VM\(vms.count == 1 ? "" : "s")"
                         + (running > 0 ? " · \(running) running" : "")
                         + (section.collapsed ? " · " + vms.prefix(4).map(\.name).joined(separator: ", ")
                            + (vms.count > 4 ? "…" : "") : ""))
                        .font(Design.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Menu {
                    Button("Rename…") {
                        groupName = group
                        naming = GroupNaming(renaming: group)
                    }
                    Button("Firewall Rules…") { firewallRules(group) }
                    Divider()
                    Button("Move Up") { moveGroup(group, by: -1) }.disabled(groupNames.first == group)
                    Button("Move Down") { moveGroup(group, by: 1) }.disabled(groupNames.last == group)
                    Divider()
                    Button("Delete Group…", role: .destructive) { deletingGroup = group }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .controlSize(.large)
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(target ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(target ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture {
                groups.toggle(group)
                saveGroups()
            }
            .help(section.collapsed ? "Click to show its VMs" : "Click to hide its VMs")
            .onDrop(of: [.plainText], isTargeted: dropBinding(group)) { dropOnGroup($0, group) }
            .padding(.top, 6)
        } else if sections.count > 1 {
            HStack(spacing: 14) {
                Color.clear.frame(width: 22)
                IconTile(symbol: "tray", color: .gray, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("No group").font(.system(size: 17, weight: .bold)).foregroundStyle(.secondary)
                    Text("\(vms.count) VM\(vms.count == 1 ? "" : "s"). Drag one here to take it out of its group.")
                        .font(Design.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 8).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(target ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(target ? Color.accentColor : .clear, lineWidth: 2))
            .onDrop(of: [.plainText], isTargeted: dropBinding(nil)) { dropOnGroup($0, nil) }
            .padding(.top, 6)
        } else if persistent.count > 1 {
            Label("Drag a VM by its handle to reorder it. Use New Group to gather VMs.", systemImage: "line.3.horizontal")
                .font(Design.caption).foregroundStyle(.secondary)
                .padding(.vertical, 4)
        }
    }

    private func dropBinding(_ group: String?) -> Binding<Bool> {
        Binding(get: { dropGroup == .some(group) },
                set: { over in
                    if over { dropGroup = .some(group) } else if dropGroup == .some(group) { dropGroup = nil }
                })
    }

    private func dropOnGroup(_ providers: [NSItemProvider], _ group: String?) -> Bool {
        dropGroup = nil
        guard let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let name = item as? NSString as String? else { return }
            Task { @MainActor in
                dragging = nil
                setGroup(name, group)
            }
        }
        return true
    }

    private func saveGroups() {
        do { try VMGroupStore().save(groups) } catch { errorMessage = HostAgent.describe(error) }
    }

    /// A VM to a group (nil: none), through its settings like any change.
    private func setGroup(_ name: String, _ group: String?) {
        guard let vm = host.vm(named: name), vm.config.group != group else { return }
        if let group {
            groups.adopt(group)
            if let i = groups.groups.firstIndex(where: { $0.name == group }), groups.groups[i].collapsed {
                groups.groups[i].collapsed = false
            }
            saveGroups()
        }
        var c = vm.config
        c.group = group
        Task { @MainActor in
            do { try await host.update(c) } catch { errorMessage = HostAgent.describe(error) }
        }
    }

    /// Repair Disk takes minutes; the row shows each step meanwhile.
    private func repairDisk(_ name: String) {
        Task { @MainActor in
            do { repairNotice = try await host.repairDisk(name) } catch { errorMessage = HostAgent.describe(error) }
        }
    }

    private func finishDuplicating() {
        guard let source = duplicating, let vm = host.instances.first(where: { $0.name == source }) else { return }
        duplicating = nil
        let (config, left) = vm.config.copy(named: copyName.trimmingCharacters(in: .whitespaces))
        Task { @MainActor in
            do {
                _ = try await host.clone(source, as: config)
                if !left.isEmpty {
                    copyNotice = "“\(config.name)” is ready to start. Not copied: \(left.joined(separator: ", ")). "
                        + "Add them in its settings if it needs them."
                }
            } catch {
                errorMessage = HostAgent.describe(error)
            }
        }
    }

    private func finishNaming() {
        guard let n = naming else { return }
        naming = nil
        let name = groupName.trimmingCharacters(in: .whitespaces)
        do {
            if let old = n.renaming {
                guard name != old else { return }
                let changed = try groups.rename(old, to: name, configs: persistent.map(\.config))
                try renameTag(old, to: name)
                saveGroups()
                Task { @MainActor in
                    do { for c in changed { try await host.update(c) } } catch { errorMessage = HostAgent.describe(error) }
                }
            } else {
                try groups.add(name)
                saveGroups()
                if let vm = n.forVM { setGroup(vm, name) }
            }
        } catch {
            errorMessage = HostAgent.describe(error)
        }
    }

    /// A group's firewall tag follows its name.
    private func renameTag(_ old: String, to new: String) throws {
        let store = FirewallTagStore()
        guard var tag = try store.tag(named: old) else { return }
        guard try store.tag(named: new) == nil else {
            throw MonadError("There is already a firewall tag called \(new); the group would take its rules. Pick another name.")
        }
        tag.name = new
        try store.save(tag)
        try store.delete(named: old)
    }

    private func deleteGroup(_ group: String) {
        deletingGroup = nil
        let freed = groups.remove(group, configs: persistent.map(\.config))
        saveGroups()
        Task { @MainActor in
            do { for c in freed { try await host.update(c) } } catch { errorMessage = HostAgent.describe(error) }
        }
    }

    private func moveGroup(_ group: String, by delta: Int) {
        guard let i = groupNames.firstIndex(of: group) else { return }
        for name in groupNames { groups.adopt(name) }
        groups.move(group, to: i + delta)
        saveGroups()
    }

    /// The group's rules: its firewall tag, made when it has none yet.
    private func firewallRules(_ group: String) {
        let store = FirewallTagStore()
        do {
            if try store.tag(named: group) == nil { try store.save(FirewallTag(name: group, rules: [])) }
            (NSApp.delegate as? AppDelegate)?.showSettings(pane: .firewall, tag: group)
        } catch {
            errorMessage = HostAgent.describe(error)
        }
    }

    /// A handle dropped on the row of `target`: the dragged VM takes its
    /// place. Only the name of a VM in the list moves anything (text dragged
    /// in from elsewhere does not).
    private func drop(_ providers: [NSItemProvider], onto target: String) -> Bool {
        dropTarget = nil
        guard let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let name = item as? NSString as String? else { return }
            Task { @MainActor in
                dragging = nil
                // Dropped among another group's VMs: it joins that group.
                if let other = host.vm(named: target), host.vm(named: name)?.config.group != other.config.group {
                    setGroup(name, other.config.group)
                }
                let listed = persistent.map(\.name)
                let moved = VMOrder.dropping(listed, name, onto: target)
                guard moved != listed else { return }
                do {
                    try await host.reorder(moved)
                } catch {
                    errorMessage = HostAgent.describe(error)
                }
            }
        }
        return true
    }

    private var countLine: String {
        if tab == .lima { return "Managed by Lima. Monad can boot one where it is while Lima has it stopped." }
        let total = host.instances.count
        let running = host.instances.filter(\.isRunning).count
        if total == 0 { return "Each VM is an isolated Linux system." }
        return "\(total) VM\(total == 1 ? "" : "s") · \(running) running"
    }

    private var hostNotice: String? {
        switch host.status {
        case .connected:
            return nil
        case .connecting:
            return "Connecting to the VM service…"
        case .unavailable(let why):
            return "The VM service is not reachable: \(why)"
        case .incompatible(let why):
            return why
        }
    }
}

/// The VM service is from an older Monad (it was kept for the running VMs):
/// says so, and restarts it on request.
struct OutdatedHostNotice: View {
    @ObservedObject var host: HostClient
    var detail = "Changes made since may not be in effect."

    var body: some View {
        HStack(spacing: 12) {
            Notice(symbol: "exclamationmark.triangle.fill", color: .orange,
                   text: "The VM service is from an older Monad. \(detail)")
            Spacer()
            RestartHostButton(host: host)
        }
    }
}

/// In a VM's window while the VM service is outdated: its settings are not
/// shown (an older service may not know them, or drop them) until the
/// service is restarted.
struct OutdatedHostGate: View {
    @ObservedObject var host: HostClient

    var body: some View {
        ContentUnavailableView {
            Label("The VM Service Needs a Restart", systemImage: "arrow.triangle.2.circlepath")
        } description: {
            Text("It is from an older Monad, kept running for your VMs. This VM's settings open once it runs the version from this Monad.")
        } actions: {
            RestartHostButton(host: host).controlSize(.large).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Restarts the VM service after a confirmation (every VM shuts down).
struct RestartHostButton: View {
    @ObservedObject var host: HostClient
    @State private var confirm = false
    @State private var restarting = false
    @State private var errorMessage: String?

    var body: some View {
        Button(restarting ? "Restarting…" : "Restart VM Service") { confirm = true }
            .disabled(restarting)
            .help("Shut down every VM and start the VM service from this Monad.")
            .confirmationDialog("Restart the VM service?", isPresented: $confirm) {
                Button("Shut Down VMs and Restart", role: .destructive) { restart() }
            } message: {
                Text("Every running VM shuts down. Open tabs start their VM again once the service is back.")
            }
            .alert("Could not restart the VM service", isPresented: Binding(get: { errorMessage != nil },
                                                                            set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func restart() {
        restarting = true
        Task {
            do {
                try await host.updateHost()
            } catch {
                errorMessage = error.localizedDescription
            }
            restarting = false
        }
    }
}

private struct VMRow: View {
    /// Where a VM that can be dragged sits in the order.
    enum Place { case top, middle, bottom }

    @ObservedObject var vm: RemoteVM
    let host: HostClient
    /// The top of the list: the VM Monad opens first.
    let isDefault: Bool
    /// nil: the row cannot move (an ephemeral VM, or the only one).
    let place: Place?
    /// Where the dragged VM would land, while a handle is over this row.
    let dropEdge: VMOrder.Edge?
    /// This row's handle started a drag.
    var onDragStart: () -> Void
    var onError: (String) -> Void
    /// The groups there are, and moving the VM to one (nil: none).
    var groups: [String]
    var onGroup: (String?) -> Void
    var onNewGroup: () -> Void
    /// Duplicate… (macOS VMs): the list asks for the copy's name.
    var onDuplicate: () -> Void = {}
    /// Repair Disk… (Linux VMs of Monad's own): the list asks first.
    var onRepair: () -> Void = {}
    @State private var confirmDelete = false
    @State private var overHandle = false

    var body: some View {
        HStack(spacing: 14) {
            if place != nil {
                handle
            } else if !vm.config.ephemeral {
                Color.clear.frame(width: 22) // the only VM: aligned with a list of several
            }
            IconTile(symbol: vm.config.symbol,
                     color: vm.isRunning ? .accentColor : .gray, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Flow(spacing: 8) {
                    Text(vm.name).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    StatusBadge(state: vm.state)
                    if vm.config.guestOS == .macos, let sip = VMSettingsDraft.sipTag(vm.macSecurity) {
                        TagLabel(text: sip, color: vm.macSecurity?.sip == "disabled" ? .orange : .green)
                            .help("System Integrity Protection, as macOS said when the VM last started. "
                                  + "Change it on the VM's Security page.")
                    }
                    if isDefault {
                        TagLabel(text: "default VM", color: .yellow)
                            .help("Monad opens this VM first. Use Make Default in another VM's ⋯ menu to change it.")
                    }
                    if vm.config.ephemeral { TagLabel(text: "ephemeral") }
                    if vm.config.attached != nil { TagLabel(text: "shared with Lima", color: .teal) }
                    if vm.config.copiedFrom != nil { TagLabel(text: "copied from Lima") }
                    if vm.config.startAtLaunch { TagLabel(text: "starts at boot", color: .green) }
                    if !vm.pendingRestart.isEmpty { TagLabel(text: "restart to apply", color: .orange) }
                    if vm.sharesError != nil { TagLabel(text: "folder problem", color: .red) }
                }
                Text(summary).font(Design.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                if case .failed(let why) = vm.state {
                    Text(why).font(Design.caption).foregroundStyle(.red).lineLimit(2)
                } else if case .preparing(let what) = vm.state {
                    Text(what).font(Design.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let step = vm.macSecurity?.step {
                    Text(step).font(Design.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            VMControls(vm: vm, host: host, onError: onError)
            Button { (NSApp.delegate as? AppDelegate)?.showDetails(of: vm) } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("Settings, shared folders and forwarding")
            .disabled(isPreparing)
            Menu {
                if vm.config.guestOS == .macos {
                    Button("Open macOS Desktop") { run { try await (NSApp.delegate as? AppDelegate)?.openDesktop(of: vm.name) } }
                        .disabled(!vm.isRunning)
                    Button("Duplicate…") { onDuplicate() }
                        .disabled(vm.isRunning || vm.state.isPreparing)
                        .help(vm.isRunning ? "Stop it first: its disk is in use while it runs." : "")
                    Divider()
                }
                if vm.config.guestOS == .linux, vm.config.attached == nil, !vm.config.ephemeral {
                    Button("Repair Disk…") { onRepair() }
                        .disabled(vm.isRunning || vm.state.isPreparing)
                        .help(vm.isRunning ? "Stop it first: its disk is in use while it runs." : "")
                    Divider()
                }
                Button("Make Default") { run { try await host.makeDefault(vm.name) } }
                    .disabled(isDefault || vm.config.ephemeral)
                if !vm.config.ephemeral {
                    Menu("Move to Group") {
                        ForEach(groups, id: \.self) { g in
                            Button(g) { onGroup(g) }.disabled(vm.config.group == g)
                        }
                        if !groups.isEmpty { Divider() }
                        Button("New Group…") { onNewGroup() }
                        Button("No Group") { onGroup(nil) }.disabled(vm.config.group == nil)
                    }
                }
                Button("Move Up") { run { try await host.move(vm.name, by: -1) } }
                    .disabled(place == nil || place == .top)
                Button("Move Down") { run { try await host.move(vm.name, by: 1) } }
                    .disabled(place == nil || place == .bottom)
                Divider()
                Button("Force Stop") { run { try await host.stop(vm.name, force: true) } }.disabled(!vm.isRunning)
                Divider()
                Button(removal.menu, role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isPreparing)
        }
        .controlSize(.large)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        // Simultaneous: it must not take the mouse from the handle's drag.
        .simultaneousGesture(TapGesture(count: 2).onEnded { (NSApp.delegate as? AppDelegate)?.showDetails(of: vm) })
        .overlay(alignment: dropEdge == .above ? .top : .bottom) {
            if dropEdge != nil {
                Capsule().fill(Color.accentColor).frame(height: 3).offset(y: dropEdge == .above ? -2 : 2)
            }
        }
        .confirmationDialog(removal.title, isPresented: $confirmDelete) {
            Button(removal.button, role: .destructive) {
                run { try await host.delete(vm.name) }
            }
        } message: {
            Text(removal.message)
        }
    }

    private var removal: VMSettingsDraft.Removal { VMSettingsDraft.removal(for: vm.config) }

    /// The grip a row is dragged by, with the open hand over it.
    private var handle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(overHandle ? .primary : .secondary)
            .frame(width: 22, height: 36)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != overHandle else { return }
                overHandle = inside
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if overHandle { NSCursor.pop() }
                overHandle = false
            }
            .help("Drag to change the order, or onto another group to move it there.")
            .accessibilityLabel("Reorder")
            .onDrag {
                onDragStart()
                return NSItemProvider(object: vm.name as NSString)
            }
    }

    private var summary: String {
        let c = vm.config
        var parts = [DistroCatalog.label(c),
                     "\(c.cpus) CPU\(c.cpus == 1 ? "" : "s")", "\(c.memoryGiB) GB memory", "\(c.diskGiB) GB disk"]
        if c.networks.isEmpty { parts.append("no network") }
        if !c.sharing.shares.isEmpty { parts.append("\(c.sharing.shares.count) shared folder\(c.sharing.shares.count == 1 ? "" : "s")") }
        if !vm.forwards.isEmpty { parts.append("\(vm.forwards.count) forward\(vm.forwards.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private var isPreparing: Bool { vm.state.isPreparing }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await action() } catch { onError(HostAgent.describe(error)) }
        }
    }
}

/// Open Tab, and Start, or Restart and Shut Down: on a VM's row in either tab.
private struct VMControls: View {
    @ObservedObject var vm: RemoteVM
    let host: HostClient
    var onError: (String) -> Void

    var body: some View {
        Button("Open Tab") { (NSApp.delegate as? AppDelegate)?.openTab(in: vm) }
            .disabled(vm.state.isPreparing)
        if vm.isRunning {
            Button { run { try await host.restart(vm.name) } } label: { Image(systemName: "arrow.clockwise") }
                .help("Restart")
                .disabled(vm.state == .stopping)
            Button { run { try await host.stop(vm.name) } } label: { Image(systemName: "stop.fill") }
                .help("Shut down")
                .disabled(vm.state == .stopping)
        } else {
            Button { run { try await host.start(vm.name) } } label: { Image(systemName: "play.fill") }
                .help("Start")
                .disabled(vm.state.isPreparing)
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await action() } catch { onError(HostAgent.describe(error)) }
        }
    }
}

// MARK: - Lima

/// The Lima VMs on this Mac. limactl runs only while this tab is shown.
private struct LimaTab: View {
    @ObservedObject var host: HostClient
    var look: Int
    var onError: (String) -> Void
    @State private var list = DistroCatalog.live.map { LimaList(catalog: $0) }
    @State private var adding: String?
    @State private var pending: Pending?

    /// A VM to make once the user agreed.
    private struct Pending {
        let id: String
        let mode: LimaList.Mode
        let plan: LimaList.Plan
    }

    /// The folders of the Lima VMs Monad has, and their Monad VM.
    private var inMonad: [String: String] {
        Dictionary(host.instances.compactMap { vm in vm.config.attached.map { ($0.dir, vm.name) } },
                   uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        Group {
            if let l = list {
                if !l.loaded {
                    ProgressView("Looking for Lima VMs…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if l.rows.isEmpty {
                    ContentUnavailableView("No Lima VMs", systemImage: "shippingbox",
                                           description: Text("Monad asks limactl, or looks in ~/.lima."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(l.rows) { row($0) }
                        } footer: {
                            Text("Only VMs Lima runs with Apple's virtualization can be used. Monad boots the disk where it is, without a copy, and Lima can use it again whenever Monad does not run it.")
                                .font(Design.caption).foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: false))
                }
            } else {
                Notice(symbol: "xmark.octagon.fill", color: .red, text: "The distribution list could not be loaded.")
                    .padding(20).frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .task(id: look) {
            let found = await LimaInstances(runner: LoggingCommandRunner(SystemCommandRunner())).list()
            let checked = await Task.detached { found.map { (instance: $0, problem: LimaDisk.problem($0)) } }.value
            list?.inMonad = inMonad
            list?.setFound(checked)
        }
        .onChange(of: inMonad) { list?.inMonad = inMonad }
        .confirmationDialog(pending.map(title) ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { p in
            Button(p.mode == .copy ? "Copy to Monad" : "Use in Monad") { make(p.id, p.plan) }
        } message: { p in
            Text(message(p))
        }
    }

    private func title(_ p: Pending) -> String {
        p.mode == .copy ? "Copy “\(p.id)” to Monad?" : "Use “\(p.id)” in Monad?"
    }

    private func message(_ p: Pending) -> String {
        var parts: [String] = []
        if p.mode == .copy {
            parts.append("Monad makes “\(p.plan.config.name)”, a VM of its own from a copy of the disk. Changes in one do not reach the other, and on this Mac the copy takes space only as they differ.")
        }
        if !p.plan.folders.isEmpty {
            parts.append("Shared as in Lima:\n" + p.plan.folders.joined(separator: "\n"))
        }
        parts += p.plan.notes
        return parts.joined(separator: "\n\n")
    }

    private func row(_ row: LimaList.Row) -> some View {
        HStack(spacing: 14) {
            IconTile(symbol: "shippingbox.fill", color: row.problem == nil ? .teal : .gray, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(row.id).font(.system(size: 15, weight: .semibold))
                    if let vm = row.monadVM { TagLabel(text: "in Monad as \(vm)", color: .teal) }
                }
                Text(row.detail).font(Design.caption).foregroundStyle(.secondary).lineLimit(1)
                if let problem = row.problem {
                    Text(problem).font(Design.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            if let name = row.monadVM, let vm = host.instances.first(where: { $0.name == name }) {
                StatusBadge(state: vm.state)
                VMControls(vm: vm, host: host, onError: onError)
            } else {
                Button(adding == row.id ? "Adding…" : "Use in Monad") { ask(row.id, .inPlace) }
                    .disabled(row.problem != nil || adding != nil)
            }
            Menu {
                Button("Copy to Monad…") { ask(row.id, .copy) }
                    .disabled(plan(row.id, .copy) == nil || adding != nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .controlSize(.large)
        .padding(.vertical, 6)
    }

    private func plan(_ id: String, _ mode: LimaList.Mode) -> LimaList.Plan? {
        list?.plan(id, mode, taken: Set(host.instances.map(\.name)), capacity: .current)
    }

    /// A copy is always confirmed, and so is a VM sharing folders that need
    /// the user's word (SharePolicy) or leaving some of Lima's out.
    private func ask(_ id: String, _ mode: LimaList.Mode) {
        guard let plan = plan(id, mode) else { return }
        if mode == .copy || plan.needsConfirmation || !plan.notes.isEmpty {
            pending = Pending(id: id, mode: mode, plan: plan)
        } else {
            make(id, plan)
        }
    }

    /// The VM starts when a tab is opened on it, as any VM.
    private func make(_ id: String, _ plan: LimaList.Plan) {
        adding = id
        Task { @MainActor in
            do { _ = try await host.create(plan.config) } catch { onError(HostAgent.describe(error)) }
            adding = nil
        }
    }
}

// MARK: - New VM

/// Create New Profile, from the New VM sheet: the Settings › Profiles form
/// on a new profile, chosen for the VM once saved.
private struct NewProfileSheet: View {
    /// The new profile's id, nil when cancelled.
    var onDone: (String?) -> Void

    @StateObject private var model = ProfileEditorModel(builtIn: (try? ProfileCatalog.bundled().builtIn) ?? [],
                                                        startingNew: true)

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "wand.and.stars", color: .purple, title: "New Profile",
                       subtitle: "What to set up in a VM when it first starts.")
                .padding(.horizontal, 24).padding(.top, 18)
            ProfileDraftForm(model: model)
                .font(Design.body)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Create") { if model.save() { onDone(model.saved?.id) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 560, height: 620)
    }
}

/// Import: the VM a settings file makes on this Mac, what was changed to fit
/// it, and what reaches into the Mac, left out unless the user keeps it.
struct ImportVMSheet: View {
    let imported: VMConfigFile.Imported
    let file: String
    let taken: Set<String>
    /// Throws to keep the sheet open with the reason; the caller closes it.
    var onImport: (InstanceConfig) async throws -> Void
    var onCancel: () -> Void
    @State private var name: String
    @State private var keepMacAccess = false
    @StateObject private var submission = SheetSubmission()

    init(imported: VMConfigFile.Imported, file: String, taken: Set<String>,
         onImport: @escaping (InstanceConfig) async throws -> Void, onCancel: @escaping () -> Void) {
        self.imported = imported
        self.file = file
        self.taken = taken
        self.onImport = onImport
        self.onCancel = onCancel
        _name = State(initialValue: imported.config.name)
    }

    private var problem: String? { VMConfigFile.nameProblem(name, taken: taken) }

    private var summary: String {
        let c = imported.config
        var parts = [DistroCatalog.label(c),
                     "\(c.cpus) CPU\(c.cpus == 1 ? "" : "s")", "\(c.memoryGiB) GB memory", "\(c.diskGiB) GB disk"]
        parts.append(c.networks.isEmpty ? "no network" : c.networks.map(\.displayName).joined(separator: ", "))
        if !c.profiles.isEmpty { parts.append("profiles: " + c.profiles.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "square.and.arrow.down", color: .indigo, title: "Import a VM", subtitle: file)
                .padding(.horizontal, 24).padding(.top, 18)
            Form {
                Section {
                    TextField("Name", text: $name)
                    if let problem { Text(problem).font(Design.caption).foregroundStyle(.red) }
                    Text(summary).font(Design.caption).foregroundStyle(.secondary)
                } footer: {
                    Text("Made from a fresh image of its distribution, like a new VM.")
                        .font(Design.caption).foregroundStyle(.secondary)
                }
                if !imported.notes.isEmpty {
                    Section("Changed for this Mac") {
                        ForEach(imported.notes, id: \.self) { Notice(symbol: "info.circle.fill", color: .blue, text: $0) }
                    }
                }
                if !imported.macAccess.isEmpty {
                    Section {
                        Toggle("Keep what reaches into this Mac", isOn: $keepMacAccess)
                        ForEach(imported.macAccess.lines, id: \.self) { line in
                            Label(line, systemImage: "arrow.down.right.circle")
                                .foregroundStyle(keepMacAccess ? .primary : .secondary)
                        }
                    } header: {
                        Text("Reaches into this Mac")
                    } footer: {
                        Notice(symbol: "exclamationmark.triangle.fill", color: .orange,
                               text: "Left out unless you keep it. Keep it only for a file you trust: a bridge runs a command on this Mac whenever the VM asks, and shared folders and forwards let the VM reach into it.")
                            .font(Design.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .font(Design.body)
            Divider()
            SubmissionError(message: submission.error)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Button(submission.busy ? "Importing…" : "Import") {
                    let config = imported.config(named: name, keepingMacAccess: keepMacAccess)
                    Task { await submission.submit { try await onImport(config) } }
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(problem != nil || submission.busy)
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 600, height: 620)
    }
}

/// A sheet's one action (New VM's Create, Import): busy while it runs, a
/// second press ignored, its error shown in the sheet itself. An alert on
/// the window behind a sheet waits until the sheet closes: a failed Create
/// said nothing, and a second press then said "already exists".
@MainActor
final class SheetSubmission: ObservableObject {
    @Published private(set) var busy = false
    @Published var error: String?

    func submit(_ work: @MainActor () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do { try await work() } catch { self.error = HostAgent.describe(error) }
    }
}

/// Where a sheet says why its action failed, above its buttons.
private struct SubmissionError: View {
    let message: String?

    var body: some View {
        if let message {
            Notice(symbol: "exclamationmark.triangle.fill", color: .red, text: message)
                .font(Design.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 10)
        }
    }
}

/// New VM (the VM list's "New VM…", and the canvas, which picks the network).
struct CreateVMSheet: View {
    var initialNetwork: String?
    /// Throws to keep the sheet open with the reason; the caller closes it.
    var onCreate: (InstanceConfig) async throws -> Void
    var onCancel: () -> Void

    init(initialNetwork: String? = nil, onCreate: @escaping (InstanceConfig) async throws -> Void,
         onCancel: @escaping () -> Void) {
        self.initialNetwork = initialNetwork
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    private let capacity = HostCapacity.current
    @State private var name = ""
    @State private var form = DistroCatalog.live.map(NewVMForm.init)
    @State private var cpus = VMDefaults.cpus
    @State private var memory = VMDefaults.memoryGiB
    @State private var disk = VMDefaults.diskGiB
    @State private var tags: [FirewallTag] = []
    @State private var sharePath = ""
    @State private var shareConfirmed = false
    @State private var shareReadOnly = true
    @StateObject private var submission = SheetSubmission()
    @State private var creatingProfile = false
    /// SIP was switched off: asked first.
    @State private var confirmingSIP = false

    private var nameValid: Bool { InstanceConfig.isValidName(name) }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "plus.square.on.square", color: .indigo, title: "New Virtual Machine",
                       subtitle: form?.isMac == true ? "An isolated Mac with its own disk." : "An isolated Linux system with its own disk.")
                .padding(.horizontal, 24).padding(.top, 18)
            Form {
                Section {
                    SettingRow(symbol: "character.cursor.ibeam", color: .indigo, title: "Name",
                               detail: nameHint) {
                        TextField("", text: $name, prompt: Text("sandbox"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                }
                if let f = form {
                    Section("System") {
                        SettingRow(symbol: "square.stack.3d.up", color: .orange, title: "Distribution") {
                            Picker("", selection: Binding(get: { f.distro }, set: { form?.distro = $0 })) {
                                ForEach(f.distros) { Text($0.name).tag($0.id) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        if f.isMac {
                            SettingRow(symbol: "arrow.down.circle", color: .pink, title: "Install from",
                                       detail: "Apple's restore image. A download is kept for the next Mac VM (Settings › Distributions).") {
                                Picker("", selection: Binding(get: { f.restoreImage }, set: { form?.restoreImage = $0 })) {
                                    ForEach(f.restoreImages) { Text($0.name).tag($0.id) }
                                }
                                .labelsHidden().frame(maxWidth: 260)
                            }
                            HStack {
                                Spacer()
                                Button("Choose IPSW…") { chooseRestoreImage() }
                            }
                        } else {
                            SettingRow(symbol: "tag", color: .pink, title: "Release") {
                                Picker("", selection: Binding(get: { f.release }, set: { form?.release = $0 })) {
                                    ForEach(f.releases) { Text($0.name).tag($0.id) }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .fixedSize()
                            }
                        }
                        Notice(symbol: f.imagesAreChecked ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                               color: f.imagesAreChecked ? .green : .orange, text: f.verification)
                            .font(Design.caption)
                    }
                } else {
                    Notice(symbol: "xmark.octagon.fill", color: .red, text: "The distribution list could not be loaded.")
                }
                if let f = form, f.isMac {
                    Section {
                        SettingRow(symbol: "lock.shield", color: .red, title: "System Integrity Protection",
                                   detail: VMSettingsDraft.sipDetail) {
                            Toggle("", isOn: Binding(get: { !f.disableSIP },
                                                     set: { on in if on { form?.disableSIP = false } else { confirmingSIP = true } }))
                                .labelsHidden().toggleStyle(.switch)
                        }
                        SettingRow(symbol: "externaldrive.badge.checkmark", color: .blue, title: "Full disk access",
                                   detail: VMSettingsDraft.fullDiskAccessDetail) {
                            Toggle("", isOn: Binding(get: { f.fullDiskAccess }, set: { form?.fullDiskAccess = $0 }))
                                .labelsHidden().toggleStyle(.switch)
                        }
                        SettingRow(symbol: "person.crop.circle.badge.checkmark", color: .green, title: "Log in automatically",
                                   detail: "Starts at its desktop, without the login window.") {
                            Toggle("", isOn: Binding(get: { f.autoLogin }, set: { form?.autoLogin = $0 }))
                                .labelsHidden().toggleStyle(.switch)
                        }
                    } header: {
                        Text("Security")
                    }
                }
                Section {
                    QuantityRow(symbol: "cpu", color: .blue, title: "CPUs", value: $cpus, range: 1...capacity.maxCPUs,
                                unit: cpus == 1 ? "core" : "cores")
                    QuantityRow(symbol: "memorychip", color: .green, title: "Memory", value: $memory,
                                range: minimumMemory...max(minimumMemory, capacity.maxMemoryGiB), unit: "GB",
                                detail: "Up to \(capacity.maxMemoryGiB) GB of this Mac's \(capacity.memoryGiB) GB.")
                    QuantityRow(symbol: "internaldrive", color: .gray, title: "Disk", value: $disk, range: minimumDisk...1024,
                                step: 10, unit: "GB", detail: "Fixed once created. Space is used only as it fills.")
                } header: {
                    Text("Resources")
                }
                if let f = form {
                    Section {
                        SettingRow(symbol: "network", color: .blue, title: "Network",
                                   detail: f.network == nil ? "No network device at all."
                                       : "VMs on the same network can reach each other. Set up in Settings › Networks.") {
                            Picker("", selection: Binding(get: { f.network }, set: { form?.network = $0 })) {
                                Text("None").tag(String?.none)
                                ForEach(f.networks) { Text($0.name).tag(String?.some($0.id)) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        if f.firewallApplies {
                            FirewallSwitchRows(firewall: Binding(get: { f.firewall }, set: { form?.firewall = $0 }),
                                               tags: tags)
                        }
                    } header: {
                        Text("Network")
                    } footer: {
                        Text(f.firewallApplies ? "This VM's own firewall. Rules can be added on its Network page later." : "")
                            .font(Design.caption).foregroundStyle(.secondary)
                    }
                }
                if let f = form, !f.profileChoices.isEmpty {
                    Section {
                        ForEach(f.profileChoices) { p in
                            Toggle(isOn: Binding(get: { f.isChosen(p.id) && p.supported }, set: { _ in form?.toggleProfile(p.id) })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).font(Design.rowTitle)
                                    Text(p.supported ? p.summary : "Not available for this distribution.")
                                        .font(Design.caption).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(!p.supported)
                        }
                        Button("Create New Profile…") { creatingProfile = true }
                    } header: {
                        Text("Profiles")
                    } footer: {
                        Text("Set up in the VM once it first starts. Progress shows in its tab. Profiles are edited in Settings › Profiles.")
                            .font(Design.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    SettingRow(symbol: "folder", color: .cyan, title: "Shared folder",
                               detail: sharePath.isEmpty ? "Optional. More can be added later." : sharePath) {
                        HStack {
                            if !sharePath.isEmpty {
                                Toggle("Read-only", isOn: $shareReadOnly).toggleStyle(.checkbox)
                                Button { sharePath = "" } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).help("Don't share a folder")
                            }
                            Button(sharePath.isEmpty ? "Choose…" : "Change…") { chooseFolder() }
                        }
                    }
                    if let f = form {
                        SettingRow(symbol: "photo", color: .orange, title: "Images in the terminal",
                                   detail: VMSettingsDraft.inlineImagesDetail) {
                            Toggle("", isOn: Binding(get: { f.inlineImages }, set: { form?.inlineImages = $0 }))
                                .labelsHidden().toggleStyle(.switch)
                        }
                    }
                } header: {
                    Text("Access")
                }
            }
            .formStyle(.grouped)
            .font(Design.body)
            Divider()
            SubmissionError(message: submission.error)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Button(submission.busy ? "Creating…" : "Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!nameValid || form == nil || submission.busy)
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 600, height: 720)
        .alert(VMSettingsDraft.disableSIPConfirmation(vm: name.isEmpty ? "the VM" : name, newVM: true).title,
               isPresented: $confirmingSIP) {
            Button("Disable SIP") { form?.disableSIP = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(VMSettingsDraft.disableSIPConfirmation(vm: name.isEmpty ? "the VM" : name, newVM: true).message)
        }
        .sheet(isPresented: $creatingProfile) {
            NewProfileSheet { id in
                creatingProfile = false
                if let id, let catalog = try? ProfileCatalog.bundled(custom: ProfileStore()) {
                    form?.profileCreated(id, catalog: catalog)
                }
            }
        }
        .onChange(of: form?.distro) {
            // macOS needs more room: raised to its minimums (a usable disk for it).
            guard let f = form else { return }
            memory = max(memory, f.minimumMemoryGiB)
            if f.isMac && disk < Self.macDiskGiB { disk = Self.macDiskGiB }
            disk = max(disk, f.minimumDiskGiB)
        }
        .onAppear {
            let cache = ImagePipeline.restoreCache(in: Paths.imageCache)
            form?.setKeptRestoreImages(ImagePipeline.restoreImages().map {
                NewVMForm.KeptRestoreImage(path: cache.appendingPathComponent($0.file).path, bytes: $0.bytes)
            })
            form?.setNetworks((try? NetworkStore().all()) ?? [.builtInDefault])
            if let initialNetwork, form?.networks.contains(where: { $0.id == initialNetwork }) == true { form?.network = initialNetwork }
            if let catalog = try? ProfileCatalog.bundled(custom: ProfileStore()) { form?.setProfiles(catalog) }
            tags = (try? FirewallTagStore().all()) ?? []
        }
    }

    private var nameHint: String {
        !name.isEmpty && !nameValid ? "Use letters, digits and dashes (up to 32)." : "Also the host name inside the VM."
    }

    /// The disk a new Mac VM starts with (it can be raised, not shrunk).
    private static let macDiskGiB = 64
    private var minimumMemory: Int { form?.minimumMemoryGiB ?? 1 }
    private var minimumDisk: Int { form?.minimumDiskGiB ?? 10 }

    private func chooseRestoreImage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let ipsw = UTType(filenameExtension: "ipsw") { panel.allowedContentTypes = [ipsw] }
        panel.prompt = "Use"
        panel.message = "Choose a macOS restore image (.ipsw) for this Mac."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        form?.chooseRestoreImage(path: url.path)
    }

    private func create() {
        var c = InstanceConfig.defaults(name: name)
        if let form { c = form.apply(to: c) }
        c.cpus = capacity.clampCPUs(cpus)
        c.memoryGiB = capacity.clampMemory(memory)
        c.diskGiB = disk
        if !sharePath.isEmpty {
            var draft = VMSettingsDraft(c)
            draft.addShare(hostPath: sharePath, confirmed: shareConfirmed)
            draft.config.sharing.shares[0].readOnly = shareReadOnly
            c = draft.config
        }
        let config = c
        Task { await submission.submit { try await onCreate(config) } }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Share"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var confirmed = false
        switch VMSettingsDraft.shareVerdict(url.path) {
        case .fine:
            break
        case .needsConfirmation:
            let alert = NSAlert()
            alert.messageText = "Share “\(url.lastPathComponent)”?"
            alert.informativeText = VMSettingsDraft.confirmShareText
            alert.addButton(withTitle: "Share Folder")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            confirmed = true
        case .refused(let why):
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” cannot be shared"
            alert.informativeText = why
            alert.runModal()
            return
        }
        sharePath = url.path
        shareConfirmed = confirmed
    }
}

#if DEBUG
#Preview("New VM") { CreateVMSheet(onCreate: { _ in }, onCancel: {}) }

#Preview("Rows") {
    List {
        Section {
            VMRow(vm: PreviewFixtures.vm, host: PreviewFixtures.client, isDefault: true, place: .top, dropEdge: nil,
                  onDragStart: {}, onError: { _ in }, groups: ["coding"], onGroup: { _ in }, onNewGroup: {})
            VMRow(vm: PreviewFixtures.vm, host: PreviewFixtures.client, isDefault: false, place: .bottom, dropEdge: .above,
                  onDragStart: {}, onError: { _ in }, groups: ["coding"], onGroup: { _ in }, onNewGroup: {})
        } header: {
            Label("coding", systemImage: "folder.fill")
                .font(.system(size: 13, weight: .semibold)).padding(.vertical, 4)
        }
    }
    .listStyle(.inset(alternatesRowBackgrounds: false))
    .frame(width: 760, height: 260)
}

#Preview("Import") {
    var c = InstanceConfig.defaults(name: "web")
    c.distro = "ubuntu"
    c.release = "24.04"
    c.cpus = 16
    c.networks = [NetworkAttachment(network: "lab", macAddress: "52:54:00:12:34:56")]
    c.sharing = SharingSettings(runtimeEnabled: true, shares: [
        SharedFolder(hostPath: NSHomeDirectory() + "/src", guestPath: "/home/dev/src", readOnly: false)])
    c.bridges = [CommandBridge(name: "mcp", command: ["/usr/bin/xcrun", "mcpbridge"], guestPort: 9001)]
    let mac = VMConfigFile.Mac(takenNames: ["web"], networks: ["default"], distros: ["ubuntu"], maxCPUs: 8,
                               maxMemoryGiB: 16, places: .mac)
    let imported = try! VMConfigFile.read(VMConfigFile.export(c), on: mac)
    return ImportVMSheet(imported: imported, file: "web.monad.json", taken: ["web"], onImport: { _ in }, onCancel: {})
}
#endif
