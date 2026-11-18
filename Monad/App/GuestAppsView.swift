//
//  GuestAppsView.swift — a Linux VM's graphical programs in Monad: the Apps
//  submenu of a VM's ⋯ menu (favourites first, each with its icon) and a
//  panel to search them. Choosing one starts it in the VM, and its window
//  opens on this Mac (LinuxAppWindows.swift).
//
//  What the programs are and what they are called is the VM's word
//  (GuestApps.swift reads it as hostile). An icon is a PNG file MonadHost
//  keeps in the VM's folder: it is decoded here, in the app, only as a PNG,
//  small, and only when it is to be shown. Favourites are the app's own.
//

import AppKit
import Combine
import SwiftUI

/// The programs of the VMs, as MonadHost last listed them, and the user's favourites.
@MainActor
final class GuestAppsStore: ObservableObject {
    static let shared = GuestAppsStore()

    struct Listing: Equatable {
        var apps: [GuestApp] = []
        var loading = false
        var error: String?
    }

    @Published private(set) var listings: [String: Listing] = [:]
    @Published private(set) var favorites: [String: [String]] = [:]
    private let kept = GuestAppFavorites()
    private let icons = NSCache<NSString, NSImage>()

    func listing(of vm: String) -> Listing { listings[vm] ?? Listing() }

    func favorites(of vm: String) -> [String] {
        favorites[vm] ?? kept.ids(for: vm)
    }

    /// Asks MonadHost for the VM's programs; what was listed before stays shown meanwhile.
    func load(_ vm: String, host: HostClient) {
        guard !listing(of: vm).loading else { return }
        listings[vm, default: Listing()].loading = true
        Task { @MainActor in
            var next = listing(of: vm)
            do {
                next.apps = try await host.guiApps(vm)
                next.error = nil
            } catch {
                next.error = HostAgent.describe(error)
            }
            next.loading = false
            // An icon may have come for a program that had none.
            for app in next.apps { icons.removeObject(forKey: "\(vm)/\(app.id)" as NSString) }
            listings[vm] = next
        }
    }

    /// The VM stopped: its programs are not there to start.
    func forget(_ vm: String) {
        if listings[vm] != nil { listings[vm] = nil }
    }

    func isFavorite(_ app: GuestApp, vm: String) -> Bool { favorites(of: vm).contains(app.id) }

    func toggleFavorite(_ app: GuestApp, vm: String) {
        kept.set(app.id, starred: !isFavorite(app, vm: vm), for: vm)
        favorites[vm] = kept.ids(for: vm)
    }

    func launch(_ app: GuestApp, vm: String, host: HostClient) async throws {
        try await host.launchGuiApp(app.id, in: vm)
    }

    /// The program's icon: the PNG file MonadHost keeps for it, decoded
    /// small and as a PNG only; nil when it has none that can be shown.
    func icon(_ app: GuestApp, vm: String) -> NSImage? {
        guard app.hasIcon else { return nil }
        let key = "\(vm)/\(app.id)" as NSString
        if let image = icons.object(forKey: key) { return image }
        guard InstanceConfig.isValidName(vm), let file = GuestApps.iconFile(app.id, in: InstancePaths(name: vm).appIcons),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size <= GuestApps.maxIconBytes,
              let data = try? Data(contentsOf: file),
              let decoded = TerminalImages.decode(data, format: MND_IMAGE_PNG, maxPixelSize: 96) else { return nil }
        let image = NSImage(cgImage: decoded, size: NSSize(width: 18, height: 18))
        icons.setObject(image, forKey: key)
        return image
    }
}

/// A program's row in a menu or a list: its icon (a plain symbol when it has none) and its name.
private struct GuestAppLabel: View {
    let app: GuestApp
    let vm: String
    @ObservedObject var store: GuestAppsStore
    var side: CGFloat = 18

    var body: some View {
        Label {
            Text(app.name)
        } icon: {
            if let icon = store.icon(app, vm: vm) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: side, height: side)
            } else {
                Image(systemName: "app.dashed").frame(width: side, height: side)
            }
        }
    }
}

/// "Apps" in a Linux VM's ⋯ menu.
struct GuestAppsMenu: View {
    @ObservedObject var vm: RemoteVM
    let host: HostClient
    var onError: (String) -> Void
    @ObservedObject private var store = GuestAppsStore.shared

    var body: some View {
        Menu("Apps") {
            let listing = store.listing(of: vm.name)
            let lists = GuestApps.arrange(listing.apps, favorites: store.favorites(of: vm.name))
            if vm.state != .ready {
                Button("Start the VM to see its programs") {}.disabled(true)
            } else if VMSettingsDraft.displayLacksProfile(display: vm.config.display, profiles: vm.config.profiles) {
                Button("Nothing is set up to show programs yet") {}.disabled(true)
                Button("Add the App Windows Profile") { addProfile() }
            } else if listing.apps.isEmpty {
                Button(listing.loading ? "Looking for programs…" : listing.error ?? "No programs with windows were found") {}.disabled(true)
                if !listing.loading { Button("Look Again") { store.load(vm.name, host: host) } }
            } else {
                Button("Search Apps…") { GuestAppsPanelController.shared.show(vm: vm, host: host) }
                Divider()
                if !lists.favorites.isEmpty {
                    ForEach(lists.favorites) { app in item(app) }
                    Divider()
                }
                ForEach(lists.others) { app in item(app) }
                Divider()
                Button(listing.loading ? "Looking for programs…" : "Look Again") { store.load(vm.name, host: host) }
                    .disabled(listing.loading)
            }
        }
    }

    private func item(_ app: GuestApp) -> some View {
        Button { start(app) } label: { GuestAppLabel(app: app, vm: vm.name, store: store, side: 16) }
    }

    private func start(_ app: GuestApp) {
        let name = vm.name
        Task { @MainActor in
            do { try await store.launch(app, vm: name, host: host) } catch { onError(HostAgent.describe(error)) }
        }
    }

    /// The VM has a display and nothing to show on it: the profile that
    /// shows its programs as windows is added to its settings, which sets
    /// it up at once in a running VM.
    private func addProfile() {
        var config = vm.config
        guard !config.profiles.contains("app-windows") else { return }
        config.profiles.append("app-windows")
        Task { @MainActor in
            do { try await host.update(config) } catch { onError(HostAgent.describe(error)) }
        }
    }
}

/// The search panel: one at a time, for the VM it was opened for.
@MainActor
final class GuestAppsPanelController: NSObject, NSWindowDelegate {
    static let shared = GuestAppsPanelController()
    private var panel: NSPanel?

    func show(vm: RemoteVM, host: HostClient) {
        close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Apps in \(vm.name)"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: GuestAppsPanel(vm: vm, host: host) { [weak self] in self?.close() })
        panel.setContentSize(NSSize(width: 420, height: 460))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
        GuestAppsStore.shared.load(vm.name, host: host)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Clicking elsewhere puts it away, as a menu would be.
    func windowDidResignKey(_ notification: Notification) { close() }
}

/// A field to type in, the favourites, then every program; Return starts the first one found.
struct GuestAppsPanel: View {
    @ObservedObject var vm: RemoteVM
    let host: HostClient
    var onDone: () -> Void
    @ObservedObject private var store = GuestAppsStore.shared
    @State private var search = ""
    @State private var selected: String?
    @State private var problem: String?
    @FocusState private var typing: Bool

    private var lists: (favorites: [GuestApp], others: [GuestApp]) {
        GuestApps.arrange(store.listing(of: vm.name).apps, favorites: store.favorites(of: vm.name), matching: search)
    }

    private var found: [GuestApp] { lists.favorites + lists.others }

    var body: some View {
        let listing = store.listing(of: vm.name)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search the programs in \(vm.name)", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 18))
                    .focused($typing)
                    .onSubmit { if let app = chosen { start(app) } }
                if listing.loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 12)
            Divider()
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(Design.caption).foregroundStyle(.red)
                    .padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
            if found.isEmpty {
                Spacer()
                Text(empty(listing)).font(Design.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
                Spacer()
            } else {
                List(selection: $selected) {
                    if !lists.favorites.isEmpty {
                        Section("Favourites") { ForEach(lists.favorites) { row($0) } }
                    }
                    Section(lists.favorites.isEmpty ? "Programs" : "All programs") { ForEach(lists.others) { row($0) } }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 340, minHeight: 300)
        .onAppear { typing = true }
        .onChange(of: search) { selected = nil }
        .onExitCommand { onDone() }
    }

    /// What Return starts: the row picked, else the first one found.
    private var chosen: GuestApp? { found.first { $0.id == selected } ?? found.first }

    private func empty(_ listing: GuestAppsStore.Listing) -> String {
        if vm.state != .ready { return "\(vm.name) is not running. Start it to see its programs." }
        if listing.loading { return "Looking for programs…" }
        if let error = listing.error { return error }
        return search.isEmpty ? "No programs with windows were found in \(vm.name)." : "No program is called that."
    }

    private func row(_ app: GuestApp) -> some View {
        HStack(spacing: 10) {
            GuestAppLabel(app: app, vm: vm.name, store: store, side: 28).font(Design.body)
            Spacer()
            Button { store.toggleFavorite(app, vm: vm.name) } label: {
                Image(systemName: store.isFavorite(app, vm: vm.name) ? "star.fill" : "star")
                    .foregroundStyle(store.isFavorite(app, vm: vm.name) ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(store.isFavorite(app, vm: vm.name) ? "Take it out of the favourites" : "Keep it among the favourites, first in the Apps menu")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { start(app) }
        .tag(app.id)
    }

    private func start(_ app: GuestApp) {
        let name = vm.name
        Task { @MainActor in
            do {
                try await store.launch(app, vm: name, host: host)
                onDone()
            } catch {
                problem = HostAgent.describe(error)
            }
        }
    }
}
