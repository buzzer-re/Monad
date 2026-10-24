//
//  CanvasView.swift — VM › Canvas (Phase 13): CanvasModel on screen, a live
//  map in the manner of a deployment canvas. A dotted ground that pans with
//  two fingers (or a drag) and zooms with a pinch or ⌘-scroll; networks as
//  dashed groups, VMs as cards with their state, curved edges for traffic
//  (flowing while live), forwards to this Mac and the way out. Clicking a VM
//  opens its inspector; "New" or a right-click makes a VM or a network
//  where the pointer is; a VM dragged into another network moves there once
//  the user says yes (docs/CANVAS.md).
//

import AppKit
import Combine
import SwiftUI

// MARK: - Style

/// The canvas's palette: obsidian ground with a warm bias, the app icon's
/// ember as the accent (selection, live traffic), and its light twin.
enum CanvasStyle {
    private static func color(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }

    static let ground = color(rgb(0xF2F1EE), rgb(0x121115))
    static let dot = color(rgb(0x1A1714, 0.18), rgb(0xFFF6EE, 0.13))
    static let card = color(rgb(0xFFFFFF), rgb(0x1C1A1F))
    static let cardLine = color(rgb(0x1A1714, 0.12), rgb(0xFFF6EE, 0.09))
    static let cardLineHover = color(rgb(0x1A1714, 0.28), rgb(0xFFF6EE, 0.22))
    static let group = color(rgb(0x1A1714, 0.025), rgb(0xFFF6EE, 0.025))
    static let groupLine = color(rgb(0x1A1714, 0.22), rgb(0xFFF6EE, 0.16))
    static let ember = color(rgb(0xD9551F), rgb(0xFF7A3D))
    static let wire = color(rgb(0x1A1714, 0.30), rgb(0xFFF6EE, 0.22))
    static let internet = color(rgb(0x2F6FD6, 0.55), rgb(0x6EA8FF, 0.5))
    static let panel = color(rgb(0xFBFAF8), rgb(0x18171B))

    /// A distribution's tile: its initial on its own colour.
    /// What a VM's tile shows: its distribution's letter, or a symbol.
    enum Mark: Equatable {
        case letter(String)
        case symbol(String)
    }

    /// A VM's tile: Apple's mark for a macOS VM, else its distribution's.
    static func tile(for config: InstanceConfig) -> (mark: Mark, color: Color) {
        if config.guestOS == .macos { return (.symbol("apple.logo"), Color(nsColor: rgb(0x3A3A3C))) }
        let d = distro(config.distro)
        return (.letter(d.letter), d.color)
    }

    static func distro(_ id: String) -> (letter: String, color: Color) {
        let colors: [String: UInt32] = ["ubuntu": 0xE95420, "debian": 0xA80030, "fedora": 0x3C6EB4, "opensuse": 0x5DA034,
                                        "arch": 0x1793D1, "alpine": 0x0D597F]
        let c = colors[id.lowercased()].map { Color(nsColor: rgb($0)) } ?? Color.gray
        return (String(id.prefix(1)).uppercased(), c)
    }
}

// MARK: - Window state

/// The one sheet the canvas shows at a time (two sheet modifiers on one
/// view do not both present on macOS): a VM being made in a network at a
/// spot, or a network being made at a spot or edited.
enum CanvasSheet: Identifiable, Equatable {
    case newVM(network: String?, at: CGPoint)
    case network(editing: String?, at: CGPoint)
    /// Every forward and bridge between this Mac and the VMs.
    case macLinks

    var id: String {
        switch self {
        case .newVM: return "vm"
        case .network(let editing, _): return "network " + (editing ?? "")
        case .macLinks: return "mac"
        }
    }
}

/// Everything between this Mac and the VMs (This Mac's Show Forwards): per
/// VM with any, its forwards and bridges in the VM window's words.
enum MacLinks {
    struct Line: Equatable {
        var text: String
        var on: Bool
        var bridge: Bool
    }

    struct Entry: Equatable {
        var vm: String
        var lines: [Line]
    }

    static func list(_ configs: [InstanceConfig]) -> [Entry] {
        configs.compactMap { c in
            let lines = c.forwards.map { Line(text: VMSettingsDraft.describe($0), on: $0.enabled, bridge: false) }
                + c.bridges.map { b in
                    Line(text: "Bridge \(b.name): \(b.command.joined(separator: " ")) at \(b.guestEndpoint) in the VM",
                         on: b.enabled, bridge: true)
                }
            return lines.isEmpty ? nil : Entry(vm: c.name, lines: lines)
        }
        .sorted { $0.vm.localizedStandardCompare($1.vm) == .orderedAscending }
    }
}

/// The one alert at a time: a restart to offer, or what went wrong.
enum CanvasAlert: Equatable {
    case restart(CanvasMoveQuestion)
    case problem(String)
}

/// A move waiting for the user's answer.
struct CanvasMoveQuestion: Identifiable, Equatable {
    var vm: String
    var from: String?
    var to: String
    var id: String { vm }
}

@MainActor
final class CanvasWindowModel: ObservableObject {
    @Published private(set) var model: CanvasModel
    @Published private(set) var traffic: [VMTraffic] = []
    @Published private(set) var definitions: [NetworkDefinition] = []
    @Published var zoom: CGFloat = 1
    @Published var pan = CGSize(width: 220, height: 180)
    @Published var selected: String?
    @Published var hovered: String?
    /// The pointer, on the canvas (for what a right-click makes).
    @Published var pointer = CGPoint.zero
    @Published var question: CanvasMoveQuestion?
    @Published var sheet: CanvasSheet?
    @Published var alert: CanvasAlert?
    /// Docks a terminal on a VM in the canvas window (CanvasWindowController);
    /// without one, a tab opens instead.
    var onTerminal: ((String) -> Void)?
    let host: HostClient
    /// Where the layout is kept (nil: nowhere, as in tests).
    private let store: CanvasStore?
    /// Sample VMs, networks and traffic instead of MonadHost's (previews).
    private var sample: (vms: [RemoteVM], networks: [NetworkDefinition], traffic: [VMTraffic])?
    /// When each VM, network ("net:<name>") and note ("note:<id>")
    /// appeared while the canvas was open: they grow in.
    @Published private(set) var born: [String: Date] = [:]
    private var loaded = false
    private var hostObserver: AnyCancellable?
    private var notesObserver: AnyCancellable?

    // MARK: Writing on the canvas

    /// What a click or a drag on the ground does.
    @Published var tool: CanvasTool = .select
    /// The colour new notes, labels, zones, arrows and ink get.
    @Published var tint: CanvasNote.Tint = .yellow
    /// What is written on the canvas (MonadHost's, or the preview's).
    @Published private(set) var notes: [CanvasNote] = []
    @Published var selectedNote: String?
    @Published var editingNote: String?
    /// An arrow being drawn: where it starts.
    @Published var arrowStart: String?
    /// A zone or stroke being drawn, not yet saved.
    @Published var sketch: CanvasNote?
    /// Notes being moved or resized: where they are until let go.
    @Published var moving: [String: CGRect] = [:]
    /// The window's, for ⌘Z and ⇧⌘Z; nil: nothing is undone (previews).
    var undoManager: UndoManager?
    /// A VM the user asked to delete (Delete on its card): waits for yes.
    @Published var deleting: String?
    /// The layout as last saved: what ⌘Z goes back to after a move.
    private var savedLayout: CanvasLayout?

    /// Registers how to go back; what that runs registers the way forward.
    private func undoable(_ name: String, _ back: @escaping (CanvasWindowModel) -> Void) {
        guard let undo = undoManager else { return }
        let manual = !undo.groupsByEvent && !undo.isUndoing && !undo.isRedoing
        if manual { undo.beginUndoGrouping() }
        undo.registerUndo(withTarget: self) { back($0) }
        undo.setActionName(name)
        if manual { undo.endUndoGrouping() }
    }
    private var refreshScheduled = false
    static let growIn: TimeInterval = 0.7

    init(host: HostClient, store: CanvasStore? = CanvasStore()) {
        self.host = host
        self.store = store
        model = CanvasModel(layout: store?.load() ?? CanvasLayout())
        // A VM made, changed or gone shows at once, not at the next poll.
        hostObserver = host.$instances.sink { [weak self] _ in self?.scheduleRefresh() }
        // Notes written anywhere (an agent, another window) show at once.
        notesObserver = host.$notes.sink { [weak self] list in
            DispatchQueue.main.async { self?.received(list) }
        }
    }

    private func received(_ list: [CanvasNote]) {
        guard sample == nil, list != notes else { return }
        let now = Date()
        if loaded {
            for n in list where !notes.contains(where: { $0.id == n.id }) { born["note:" + n.id] = now }
        }
        withAnimation(loaded ? .spring(response: 0.5, dampingFraction: 0.75) : nil) { notes = list }
        if let s = selectedNote, !list.contains(where: { $0.id == s }) { selectedNote = nil }
        if let e = editingNote, !list.contains(where: { $0.id == e }) { editingNote = nil }
    }

    /// Where notes and zones are now (ones being moved where the pointer has them).
    var places: [String: CGRect] {
        CanvasNotesLayout.place(notes, in: model).merging(moving) { _, b in b }
    }

    func note(_ id: String) -> CanvasNote? { notes.first { $0.id == id } }

    /// Saves a note (shown at once, MonadHost's answer after).
    func save(_ note: CanvasNote, undoName: String? = nil) {
        if let previous = self.note(note.id) {
            undoable(undoName ?? "Change") { $0.save(previous, undoName: undoName) }
        } else {
            let id = note.id
            undoable(undoName ?? "Add") { $0.removeNote(id) }
        }
        if let i = notes.firstIndex(where: { $0.id == note.id }) {
            notes[i] = note
        } else {
            born["note:" + note.id] = Date()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { notes.append(note) }
        }
        guard sample == nil else { return }
        Task {
            do { try await host.setNote(note) } catch {
                alert = .problem(HostAgent.describe(error))
                try? await host.loadNotes()
                received(host.notes)
            }
        }
    }

    func removeNote(_ id: String) {
        let kept = CanvasNote.forget("note:" + id, in: notes)
        let gone = notes.enumerated().filter { e in !kept.contains { $0.id == e.element.id } }
        if !gone.isEmpty { undoable("Delete") { $0.restore(gone.map { ($0.offset, $0.element) }, primary: id) } }
        withAnimation(.easeOut(duration: 0.2)) { notes = kept }
        if selectedNote == id { selectedNote = nil }
        if editingNote == id { editingNote = nil }
        guard sample == nil else { return }
        Task {
            do { try await host.removeNote(id) } catch { alert = .problem(HostAgent.describe(error)) }
        }
    }

    /// Notes deleted together back where they were (⌘Z of a delete).
    private func restore(_ gone: [(index: Int, note: CanvasNote)], primary: String) {
        undoable("Delete") { $0.removeNote(primary) }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            for (i, n) in gone.sorted(by: { $0.index < $1.index }) where note(n.id) == nil {
                notes.insert(n, at: min(i, notes.count))
            }
        }
        guard sample == nil else { return }
        Task {
            do { for (_, n) in gone { try await host.setNote(n) } } catch { alert = .problem(HostAgent.describe(error)) }
        }
    }

    /// Delete (⌫): the selected note, label, zone, arrow or stroke goes; a
    /// selected VM is asked about first, its disk cannot come back.
    func deleteSelection() {
        guard editingNote == nil else { return }
        if let id = selectedNote {
            removeNote(id)
        } else if let vm = selected {
            deleting = vm
        }
    }

    var hasSelection: Bool { editingNote == nil && (selectedNote != nil || selected != nil) }

    func confirmDelete() {
        guard let name = deleting else { return }
        deleting = nil
        selected = nil
        Task {
            do { try await host.delete(name) } catch { alert = .problem(HostAgent.describe(error)) }
        }
    }

    /// A move by hand let go: saved, and ⌘Z puts things back.
    func moved() {
        if let before = savedLayout, before != model.layout { undoableLayout(before) }
        save()
    }

    private func undoableLayout(_ before: CanvasLayout) {
        let now = model.layout
        undoable("Move") { m in
            m.undoableLayout(now)
            m.model.restore(before)
            m.save()
        }
    }

    /// A new note, label or zone, being written at once.
    func write(_ kind: CanvasNote.Kind, frame: CGRect? = nil, on: String? = nil, to: String? = nil) {
        var n = CanvasNote(id: CanvasNote.newID(), kind: kind, tint: tint, frame: frame, on: on, to: to)
        if kind == .zone && frame == nil, let on { n.around = [on]; n.on = nil }
        save(n)
        selectedNote = n.id
        if kind != .arrow { editingNote = n.id }
    }

    /// Done writing: an empty note or label goes.
    func finishEditing(_ id: String, text: String) {
        if editingNote == id { editingNote = nil }
        guard var n = note(id) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && (n.kind == .note || n.kind == .label) {
            removeNote(id)
            return
        }
        guard n.text != text else { return }
        n.text = String(text.prefix(n.kind == .label ? CanvasNote.maxLabel : CanvasNote.maxText))
        save(n)
    }

    func recolor(_ id: String, _ tint: CanvasNote.Tint) {
        guard var n = note(id) else { return }
        n.tint = tint
        self.tint = tint
        save(n, undoName: "Colour")
    }

    /// A click with the arrow tool: the first thing is where it starts, the
    /// second where it ends.
    func arrowTap(_ ref: String?) {
        guard let ref else { arrowStart = nil; return }
        guard let start = arrowStart else { arrowStart = ref; return }
        arrowStart = nil
        guard start != ref else { return }
        write(.arrow, on: start, to: ref)
    }

    /// A click on a VM, network, note or landmark with a writing tool.
    /// Returns whether the tool used it.
    func toolTap(_ ref: String) -> Bool {
        switch tool {
        case .arrow:
            arrowTap(ref)
            return true
        case .note where CanvasRef(ref)?.isPlace == true:
            write(.note, on: ref)
            tool = .select
            return true
        case .label where CanvasRef(ref)?.isPlace == true:
            write(.label, on: ref)
            tool = .select
            return true
        default:
            return false
        }
    }

    /// Back to selecting, nothing half made.
    func cancelWriting() {
        tool = .select
        arrowStart = nil
        sketch = nil
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            Task { @MainActor in
                self?.refreshScheduled = false
                await self?.refresh()
            }
        }
    }

    /// Something grew in a moment ago: draw every frame until it is done.
    var animating: Bool { born.values.contains { Date().timeIntervalSince($0) < Self.growIn } }

    /// 0 when `key` just appeared, 1 once it has grown in.
    func growth(_ key: String, at now: Date = Date()) -> CGFloat {
        guard let b = born[key] else { return 1 }
        let t = min(1, max(0, now.timeIntervalSince(b) / Self.growIn))
        return CGFloat(1 - pow(1 - t, 3))
    }

    func vm(named name: String) -> RemoteVM? {
        sample.map { $0.vms.first { $0.name == name } } ?? host.vm(named: name)
    }

    /// The VMs, networks and traffic again; the layout saved if placing
    /// something new changed it.
    func refresh() async {
        definitions = sample?.networks ?? (try? NetworkStore().all()) ?? []
        let names = definitions.map(\.name)
        let before = model.layout
        let vms = (sample?.vms ?? host.instances).map { CanvasVM(config: $0.config, running: $0.isRunning, networks: names) }
        if loaded {
            let now = Date()
            for vm in vms where !model.vms.contains(where: { $0.name == vm.name }) { born[vm.name] = now }
            for n in names where model.layout.frames[n] == nil { born["net:" + n] = now }
        }
        born = born.filter { Date().timeIntervalSince($0.value) < Self.growIn * 2 }
        withAnimation(loaded ? .spring(response: 0.55, dampingFraction: 0.78) : nil) {
            model.update(vms: vms, networks: definitions.map { CanvasNetwork(name: $0.name, kind: $0.kind) })
        }
        if !loaded, sample == nil {
            try? await host.loadNotes()
            received(host.notes)
        }
        loaded = true
        if model.layout != before { save() }
        if let selected, model.position(selected) == nil { self.selected = nil }
        if let sample {
            traffic = sample.traffic
        } else if let latest = try? await host.traffic() {
            traffic = latest
        }
    }

    func save() {
        savedLayout = model.layout
        guard sample == nil else { return }
        try? store?.save(model.layout)
    }

    #if DEBUG
    /// A canvas of sample VMs: two networks, VMs in each state, live traffic.
    static func preview() -> CanvasWindowModel {
        let m = CanvasWindowModel(host: HostAgent.client)
        m.model = CanvasModel()
        func vm(_ name: String, _ distro: String, _ release: String, _ network: String?, _ state: VMState,
                forwards: Int = 0) -> RemoteVM {
            var c = InstanceConfig.defaults(name: name)
            c.distro = distro
            c.release = release
            c.networks = network.map { [NetworkAttachment(network: $0, macAddress: nil)] } ?? []
            c.forwards = (0..<forwards).map { ForwardRule(kind: .local, hostPort: 8000 + $0, guestPort: 8000 + $0) }
            let snap = VMSnapshot(name: name, config: c, state: state, agent: state == .ready, ports: [], sessions: 1)
            return RemoteVM(snapshot: snap, root: FileManager.default.temporaryDirectory)
        }
        m.sample = (vms: [vm("default", "ubuntu", "24.04", "default", .ready, forwards: 1),
                          vm("lima-dev", "ubuntu", "26.04", "default", .stopped),
                          vm("web", "debian", "13", "lab", .ready),
                          vm("db", "fedora", "43", "lab", .booting),
                          vm("scratch", "debian", "13", nil, .stopped)],
                    networks: [.builtInDefault, NetworkDefinition(name: "lab", kind: .internal, subnet: "192.168.77.0/24")],
                    traffic: [VMTraffic(network: "lab", from: "web", to: "db", frames: 900, bytes: 1_400_000, lastSeen: 1),
                              VMTraffic(network: "lab", from: "db", to: "web", frames: 700, bytes: 3_100_000, lastSeen: 2)])
        var zone = CanvasNote(id: "z1", kind: .zone, text: "Staging", tint: .purple)
        zone.around = ["net:lab"]
        var sketch = CanvasNote(id: "i1", kind: .ink, tint: .red)
        sketch.points = (0...40).map { CGPoint(x: 120 + Double($0) * 6, y: -60 + sin(Double($0) / 4) * 14) }
        m.notes = [zone, sketch,
                   CanvasNote(id: "l1", kind: .label, text: "C2", tint: .red, on: "vm:web"),
                   CanvasNote(id: "l2", kind: .label, text: "no internet", tint: .blue, on: "net:lab"),
                   CanvasNote(id: "a1", kind: .arrow, text: "backups", tint: .green, on: "vm:db", to: "vm:scratch"),
                   CanvasNote(id: "n1", kind: .note, text: "**Web tier**: nginx and the app, rebuilt nightly.", on: "vm:web",
                              author: "mac")]
        m.selected = "web"
        return m
    }
    #endif

    // MARK: Coordinates

    func screen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + pan.width, y: p.y * zoom + pan.height)
    }

    func canvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - pan.width) / zoom, y: (p.y - pan.height) / zoom)
    }

    func scroll(by delta: CGSize) {
        pan = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
    }

    /// Zooms keeping the canvas point under `point` (on screen) in place.
    func zoom(to new: CGFloat, around point: CGPoint) {
        let z = min(max(new, 0.25), 2.5)
        let c = canvas(point)
        zoom = z
        pan = CGSize(width: point.x - c.x * z, height: point.y - c.y * z)
    }

    /// Everything in view.
    func fit(_ size: CGSize) {
        let frames = model.layout.frames.values.reduce(CGRect.null) { $0.union($1) }
        guard !frames.isNull, size.width > 0, size.height > 0 else { return }
        let all = frames.union(CGRect(origin: model.macPosition, size: .zero))
            .union(CGRect(origin: model.internetPosition, size: .zero))
            .insetBy(dx: -140, dy: -90)
        zoom = min(max(min(size.width / all.width, size.height / all.height), 0.25), 1.2)
        pan = CGSize(width: (size.width - all.width * zoom) / 2 - all.minX * zoom,
                     height: (size.height - all.height * zoom) / 2 - all.minY * zoom)
    }

    // MARK: Moving VMs

    func drag(_ vm: String, to p: CGPoint) {
        model.drag(vm, to: p)
    }

    func drop(_ vm: String, at p: CGPoint) {
        if case .moveVM(let name, let from, let to)? = model.drop(vm, at: p) {
            question = CanvasMoveQuestion(vm: name, from: from, to: to)
        } else {
            moved()
        }
    }

    /// Yes saves the VM's network (a running VM is offered a restart, as
    /// the change applies at its next boot); no puts it back.
    func answer(_ yes: Bool) {
        guard let q = question else { return }
        question = nil
        guard yes, let vm = host.vm(named: q.vm) else {
            model.cancelMove(q.vm)
            return
        }
        let before = vm.config.networks
        Task {
            do {
                try await host.update(CanvasModel.config(vm.config, movedTo: q.to))
                save()
                undoable("Move to \(q.to)") { $0.setNetworks(q.vm, before) }
                if vm.isRunning { alert = .restart(q) }
            } catch {
                model.cancelMove(q.vm)
                alert = .problem(HostAgent.describe(error))
            }
        }
    }

    /// ⌘Z of a move between networks: the VM's networks as they were.
    private func setNetworks(_ name: String, _ networks: [NetworkAttachment]) {
        guard let vm = host.vm(named: name) else { return }
        let now = vm.config.networks
        undoable("Move") { $0.setNetworks(name, now) }
        var c = vm.config
        c.networks = networks
        Task {
            do { try await host.update(c) } catch { alert = .problem(HostAgent.describe(error)) }
        }
    }

    func moveNetwork(_ name: String, by delta: CGSize) {
        model.moveNetwork(name, by: delta)
    }

    // MARK: Making things

    /// New VM at `point`, in the network there (or the default one).
    func makeVM(at point: CGPoint) {
        sheet = .newVM(network: model.network(at: point) ?? NetworkDefinition.defaultName, at: point)
    }

    func makeNetwork(at point: CGPoint) {
        sheet = .network(editing: nil, at: point)
    }

    func editNetwork(_ name: String, at point: CGPoint) {
        sheet = .network(editing: name, at: point)
    }

    func showMacLinks() {
        sheet = .macLinks
    }

    /// A terminal on VM `name`, docked in the canvas.
    func openTerminal(_ name: String) {
        if let onTerminal {
            onTerminal(name)
        } else if let vm = host.vm(named: name) {
            (NSApp.delegate as? AppDelegate)?.openTab(in: vm)
        }
    }

    func moveLandmark(_ landmark: CanvasLandmark, to point: CGPoint) {
        model.moveLandmark(landmark, to: point)
    }

    /// The VMs' settings (MonadHost's, or the preview's samples).
    var configs: [InstanceConfig] { (sample?.vms ?? host.instances).map(\.config) }

    /// Throws for the New VM sheet to say why, while it stays open.
    func create(_ config: InstanceConfig, at point: CGPoint) async throws {
        model.hint(vm: config.name, at: point)
        _ = try await host.create(config)
        sheet = nil
        selected = config.name
        await refresh()
    }

    func networkWillBeSaved(_ name: String, at point: CGPoint) {
        model.hint(network: name, at: point)
    }

    var running: Int { model.vms.filter(\.running).count }
}

// MARK: - The canvas

struct CanvasView: View {
    static let size = NSSize(width: 1240, height: 800)

    @StateObject private var canvas: CanvasWindowModel
    @State private var nodeDragStart: [String: CGPoint] = [:]
    @State private var frameDragDone: [String: CGSize] = [:]
    @State private var panStart: CGSize?
    @State private var creating = false
    @State private var landmarkDragStart: CGPoint?

    init(host: HostClient) {
        _canvas = StateObject(wrappedValue: CanvasWindowModel(host: host))
    }

    init(canvas: CanvasWindowModel) {
        _canvas = StateObject(wrappedValue: canvas)
    }

    private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ground(geo.size)
                    CanvasInput(onScroll: { canvas.scroll(by: $0) },
                                onZoom: { factor, point in canvas.zoom(to: canvas.zoom * factor, around: point) },
                                onDelete: {
                                    guard canvas.hasSelection else { return false }
                                    canvas.deleteSelection()
                                    return true
                                })
                        .allowsHitTesting(false)
                    drawing
                    let places = canvas.places
                    ForEach(canvas.notes.filter { $0.kind == .zone }) { n in
                        if let r = places[n.id] {
                            CanvasZoneTitle(note: n, rect: r, canvas: canvas)
                            if n.frame != nil, canvas.selectedNote == n.id { CanvasZoneHandle(note: n, rect: r, canvas: canvas) }
                        }
                    }
                    ForEach(Array(canvas.model.layout.frames.keys).sorted(), id: \.self) { groupLabel($0) }
                    landmark(.mac, symbol: "laptopcomputer", title: "This Mac", at: canvas.model.macPosition)
                    landmark(.internet, symbol: "globe.americas.fill", title: "Internet", at: canvas.model.internetPosition)
                    ForEach(canvas.model.vms, id: \.name) { card($0) }
                    labels
                    ForEach(canvas.notes.filter { $0.kind == .arrow && !$0.text.isEmpty || canvas.editingNote == $0.id && $0.kind == .arrow }) { n in
                        if let mid = arrowMiddle(n, places) { CanvasArrowWords(note: n, at: mid, canvas: canvas) }
                    }
                    ForEach(canvas.notes.filter { $0.kind == .note }) { n in
                        if let r = places[n.id] { CanvasNoteCard(note: n, rect: r, canvas: canvas) }
                    }
                    if canvas.model.vms.isEmpty && canvas.notes.isEmpty {
                        emptyState.frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .coordinateSpace(name: "canvas")
                .clipped()
                .onContinuousHover(coordinateSpace: .named("canvas")) { phase in
                    if case .active(let p) = phase { canvas.pointer = canvas.canvas(p) }
                }
                .overlay(alignment: .topLeading) { titleChip }
                .overlay(alignment: .top) { CanvasToolPalette(canvas: canvas) }
                .overlay(alignment: .topTrailing) { newMenu(geo.size) }
                .overlay(alignment: .bottomLeading) { zoomControls(geo.size) }
                .task {
                    var fitted = false
                    while !Task.isCancelled {
                        await canvas.refresh()
                        if !fitted {
                            canvas.fit(geo.size)
                            fitted = true
                        }
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            }
            if let name = canvas.selected, let vm = canvas.vm(named: name) {
                CanvasInspector(vm: vm, canvas: canvas)
                    .frame(width: 360)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(CanvasStyle.ground)
        .animation(.snappy(duration: 0.22), value: canvas.selected)
        .onExitCommand {
            canvas.selected = nil
            canvas.selectedNote = nil
            canvas.editingNote = nil
            canvas.cancelWriting()
        }
        .frame(minWidth: 720, minHeight: 480)
        .confirmationDialog(canvas.deleting.map { "Delete “\($0)” and its disk?" } ?? "",
                            isPresented: Binding(get: { canvas.deleting != nil }, set: { if !$0 { canvas.deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { canvas.confirmDelete() }
            Button("Cancel", role: .cancel) { canvas.deleting = nil }
        } message: {
            Text("Everything in the VM is lost. This cannot be undone.")
        }
        .confirmationDialog(canvas.question.map { "Move “\($0.vm)” to \($0.to)?" } ?? "",
                            isPresented: Binding(get: { canvas.question != nil }, set: { if !$0 { canvas.answer(false) } }),
                            titleVisibility: .visible) {
            Button("Move") { canvas.answer(true) }
            Button("Cancel", role: .cancel) { canvas.answer(false) }
        } message: {
            Text("Its network becomes \(canvas.question?.to ?? ""). A running VM moves when it starts again.")
        }
        .alert(alertTitle, isPresented: Binding(get: { canvas.alert != nil }, set: { if !$0 { canvas.alert = nil } }),
               presenting: canvas.alert) { alert in
            if case .restart(let q) = alert {
                Button("Restart Now") { Task { try? await canvas.host.restart(q.vm) } }
                Button("Later", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { alert in
            switch alert {
            case .restart(let q): Text("It joins \(q.to) when it starts again.")
            case .problem(let why): Text(why)
            }
        }
        .sheet(item: $canvas.sheet) { sheet in
            switch sheet {
            case .newVM(let network, let point):
                CreateVMSheet(initialNetwork: network) { config in
                    try await canvas.create(config, at: point)
                } onCancel: { canvas.sheet = nil }
            case .network(let editing, let point):
                NetworkSheet(editing: editing, usedBy: canvas.model.vms.filter { $0.network != nil && $0.network == editing }.count,
                             willSave: { canvas.networkWillBeSaved($0, at: point) }) { _ in
                    canvas.sheet = nil
                    Task { await canvas.refresh() }
                }
            case .macLinks:
                MacLinksSheet(entries: MacLinks.list(canvas.configs),
                              open: { name in
                                  canvas.sheet = nil
                                  if let vm = canvas.vm(named: name) { appDelegate?.showDetails(of: vm, page: .forwarding) }
                              },
                              done: { canvas.sheet = nil })
            }
        }
    }

    private var alertTitle: String {
        switch canvas.alert {
        case .restart(let q)?: return "Restart “\(q.vm)” now?"
        case .problem?: return "Something went wrong"
        case nil: return ""
        }
    }

    // MARK: Ground and drawing

    private func ground(_ size: CGSize) -> some View {
        Canvas { ctx, size in
            var step = 24 * canvas.zoom
            while step < 12 { step *= 2 }
            let ox = canvas.pan.width.truncatingRemainder(dividingBy: step)
            let oy = canvas.pan.height.truncatingRemainder(dividingBy: step)
            let r = max(0.8, 1.1 * min(canvas.zoom, 1.2))
            var dots = Path()
            var y = oy - step
            while y < size.height + step {
                var x = ox - step
                while x < size.width + step {
                    dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    x += step
                }
                y += step
            }
            ctx.fill(dots, with: .color(CanvasStyle.dot))
        }
        .background(CanvasStyle.ground)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .named("canvas")) { groundTap(canvas.canvas($0)) }
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
            .onChanged { v in groundDrag(v) }
            .onEnded { v in groundDragEnded(v) })
        .contextMenu { groundMenu }
    }

    /// A click on the ground: the tool's, else what is drawn there (an
    /// arrow, a stroke, a zone's edge), else nothing selected.
    private func groundTap(_ p: CGPoint) {
        let network = canvas.model.network(at: p)
        switch canvas.tool {
        case .note:
            let size = CanvasNotesLayout.size(of: "")
            canvas.write(.note, frame: CGRect(x: p.x - size.width / 2, y: p.y - 20, width: size.width, height: size.height))
            canvas.tool = .select
            return
        case .label, .zone:
            if let network {
                if canvas.tool == .label { canvas.write(.label, on: "net:" + network) } else { canvas.write(.zone, on: "net:" + network) }
                canvas.tool = .select
            }
            return
        case .arrow:
            canvas.arrowTap(network.map { "net:" + $0 })
            return
        case .select, .pen:
            break
        }
        canvas.selected = nil
        canvas.editingNote = nil
        canvas.selectedNote = CanvasNotesLayout.hit(p, canvas.notes, places: canvas.places, in: canvas.model,
                                                    tolerance: 8 / canvas.zoom)
    }

    /// A drag on the ground: draws a zone or ink with those tools, else pans.
    private func groundDrag(_ v: DragGesture.Value) {
        let start = canvas.canvas(v.startLocation), now = canvas.canvas(v.location)
        switch canvas.tool {
        case .zone:
            var s = CanvasNote(id: "sketch", kind: .zone, tint: canvas.tint)
            s.frame = CGRect(x: min(start.x, now.x), y: min(start.y, now.y), width: abs(now.x - start.x), height: abs(now.y - start.y))
            canvas.sketch = s
        case .pen:
            var s = canvas.sketch ?? CanvasNote(id: "sketch", kind: .ink, tint: canvas.tint, points: [start])
            s.points?.append(now)
            canvas.sketch = s
        default:
            let from = panStart ?? canvas.pan
            if panStart == nil { panStart = from }
            canvas.pan = CGSize(width: from.width + v.translation.width, height: from.height + v.translation.height)
        }
    }

    private func groundDragEnded(_ v: DragGesture.Value) {
        panStart = nil
        guard let s = canvas.sketch else { return }
        canvas.sketch = nil
        switch s.kind {
        case .zone:
            guard let r = s.frame, r.width >= 60, r.height >= 40 else { return }
            canvas.write(.zone, frame: r.integral)
            canvas.tool = .select
        case .ink:
            let points = CanvasNote.simplify(s.points ?? [])
            guard points.count >= 2 else { return }
            var n = CanvasNote(id: CanvasNote.newID(), kind: .ink, tint: s.tint)
            n.points = points
            canvas.save(n)
        default:
            break
        }
    }

    /// The labels, by what they are on: under a VM's card, along the top
    /// of a network's frame after its title.
    @ViewBuilder private var labels: some View {
        let byTarget = Dictionary(grouping: canvas.notes.filter { $0.kind == .label }, by: { $0.on ?? "" })
        ForEach(byTarget.keys.sorted(), id: \.self) { target in
            if let r = canvas.model.rect(of: target) {
                let onVM: Bool = { if case .vm? = CanvasRef(target) { return true } else { return false } }()
                CanvasLabels(target: target, labels: byTarget[target] ?? [],
                             origin: onVM ? CGPoint(x: r.minX + 4, y: r.maxY + 8) : CGPoint(x: r.minX + 14, y: r.maxY + 8),
                             canvas: canvas)
            }
        }
    }

    private func arrowMiddle(_ n: CanvasNote, _ places: [String: CGRect]) -> CGPoint? {
        guard let on = n.on, let to = n.to, let a = CanvasNotesLayout.rect(of: on, places: places, in: canvas.model),
              let b = CanvasNotesLayout.rect(of: to, places: places, in: canvas.model) else { return nil }
        return CanvasNotesLayout.arrow(from: a.insetBy(dx: -6, dy: -6), to: b.insetBy(dx: -6, dy: -6)).point(at: 0.5)
    }

    @ViewBuilder private var groundMenu: some View {
        let spot = canvas.pointer
        let network = canvas.model.network(at: spot)
        Button(network.map { "New VM in \($0)" } ?? "New VM Here") { canvas.makeVM(at: spot) }
        Button("New Network Here") { canvas.makeNetwork(at: spot) }
        Button("New Note Here") {
            let size = CanvasNotesLayout.size(of: "")
            canvas.write(.note, frame: CGRect(x: spot.x, y: spot.y, width: size.width, height: size.height))
        }
        if let network {
            Divider()
            Button("Edit “\(network)”…") { canvas.editNetwork(network, at: spot) }
        }
    }

    private var anyLive: Bool {
        canvas.model.edges(traffic: canvas.traffic).contains { if case .traffic(_, _, _, true) = $0 { return true } else { return false } }
    }

    private var drawing: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !anyLive && !canvas.animating)) { timeline in
            Canvas { ctx, _ in
                draw(&ctx, phase: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .allowsHitTesting(false)
    }

    /// A curve between two points: leaves and arrives along the longer axis.
    private func curve(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path()
        p.move(to: a)
        let dx = b.x - a.x, dy = b.y - a.y
        if abs(dx) >= abs(dy) {
            p.addCurve(to: b, control1: CGPoint(x: a.x + dx / 2, y: a.y), control2: CGPoint(x: b.x - dx / 2, y: b.y))
        } else {
            p.addCurve(to: b, control1: CGPoint(x: a.x, y: a.y + dy / 2), control2: CGPoint(x: b.x, y: b.y - dy / 2))
        }
        return p
    }

    /// The line between two VM cards and the middle of it (for its label):
    /// between facing edges when there is room, else an arc under both cards.
    private func link(_ p: CGPoint, _ q: CGPoint) -> (Path, CGPoint) {
        let w = CanvasModel.node.width / 2, h = CanvasModel.node.height / 2
        let dx = q.x - p.x, dy = q.y - p.y
        let start: CGPoint, end: CGPoint, c1: CGPoint, c2: CGPoint
        if abs(dx) >= abs(dy), abs(dx) - 2 * w > 80 {
            let side: CGFloat = dx > 0 ? 1 : -1
            start = CGPoint(x: p.x + side * w, y: p.y)
            end = CGPoint(x: q.x - side * w, y: q.y)
            c1 = CGPoint(x: (start.x + end.x) / 2, y: start.y)
            c2 = CGPoint(x: (start.x + end.x) / 2, y: end.y)
        } else if abs(dy) - 2 * h > 60 {
            let side: CGFloat = dy > 0 ? 1 : -1
            start = CGPoint(x: p.x, y: p.y + side * h)
            end = CGPoint(x: q.x, y: q.y - side * h)
            c1 = CGPoint(x: start.x, y: (start.y + end.y) / 2)
            c2 = CGPoint(x: end.x, y: (start.y + end.y) / 2)
        } else {
            // Neighbours: under both cards, clear of the group's label above.
            let dip = 56 + abs(dx) * 0.15
            start = CGPoint(x: p.x, y: p.y + h)
            end = CGPoint(x: q.x, y: q.y + h)
            c1 = CGPoint(x: start.x, y: max(start.y, end.y) + dip)
            c2 = CGPoint(x: end.x, y: max(start.y, end.y) + dip)
        }
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: c1, control2: c2)
        let mid = CGPoint(x: (start.x + 3 * c1.x + 3 * c2.x + end.x) / 8, y: (start.y + 3 * c1.y + 3 * c2.y + end.y) / 8)
        return (path, mid)
    }

    private func draw(_ ctx: inout GraphicsContext, phase: TimeInterval) {
        ctx.translateBy(x: canvas.pan.width, y: canvas.pan.height)
        ctx.scaleBy(x: canvas.zoom, y: canvas.zoom)
        let m = canvas.model
        let now = Date()
        let places = canvas.places
        CanvasNotesDrawing.zones(&ctx, canvas, places: places, now: now)
        for (key, f) in m.layout.frames {
            // A network that just appeared grows from its middle and glows.
            let g = canvas.growth("net:" + key, at: now)
            let rect = f.insetBy(dx: f.width * (1 - g) * 0.15, dy: f.height * (1 - g) * 0.15)
            let shape = Path(roundedRect: rect, cornerRadius: 18)
            ctx.fill(shape, with: .color(CanvasStyle.group.opacity(Double(g))))
            ctx.stroke(shape, with: .color(CanvasStyle.groupLine.opacity(Double(g))),
                       style: StrokeStyle(lineWidth: 1.2, dash: key == CanvasModel.outside ? [3, 5] : [7, 6]))
            if g < 1 {
                ctx.stroke(Path(roundedRect: rect.insetBy(dx: -6 * g, dy: -6 * g), cornerRadius: 22),
                           with: .color(Color.accentColor.opacity(Double(1 - g))), lineWidth: 3)
            }
        }
        for edge in m.edges(traffic: canvas.traffic) {
            switch edge {
            case .traffic(let a, let b, let bytes, let live):
                guard let p = m.position(a), let q = m.position(b) else { continue }
                let (path, mid) = link(p, q)
                let width = min(1.5 + log10(Double(bytes) + 1) / 2, 5)
                if live {
                    ctx.stroke(path, with: .color(CanvasStyle.ember.opacity(0.25)), lineWidth: width + 4)
                    ctx.stroke(path, with: .color(CanvasStyle.ember),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [8, 10],
                                                  dashPhase: CGFloat(-phase * 36).truncatingRemainder(dividingBy: 18)))
                } else {
                    ctx.stroke(path, with: .color(CanvasStyle.wire), lineWidth: width)
                }
                let label = ctx.resolve(Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(live ? CanvasStyle.ember : Color.secondary))
                let size = label.measure(in: CGSize(width: 200, height: 40))
                let chip = Path(roundedRect: CGRect(x: mid.x - size.width / 2 - 7, y: mid.y - size.height / 2 - 3,
                                                    width: size.width + 14, height: size.height + 6), cornerRadius: 8)
                ctx.fill(chip, with: .color(CanvasStyle.card))
                ctx.stroke(chip, with: .color(CanvasStyle.cardLine), lineWidth: 1)
                ctx.draw(label, at: mid)
            case .mac(let vm):
                guard let p = m.position(vm) else { continue }
                ctx.stroke(curve(m.macPosition, CGPoint(x: p.x - CanvasModel.node.width / 2, y: p.y)), with: .color(CanvasStyle.wire),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 5]))
            case .internet(let network):
                guard let f = m.frame(network) else { continue }
                ctx.stroke(curve(m.internetPosition, CGPoint(x: f.midX, y: f.minY)), with: .color(CanvasStyle.internet), lineWidth: 1.5)
            }
        }
        CanvasNotesDrawing.strokes(&ctx, canvas, places: places, now: now)
    }

    // MARK: Groups, landmarks, cards

    /// A network's label: drag it to move the group and its VMs.
    private func groupLabel(_ key: String) -> some View {
        let f = canvas.model.frame(key) ?? .zero
        let definition = canvas.definitions.first { $0.name == key }
        let outside = key == CanvasModel.outside
        return HStack(spacing: 7) {
            Image(systemName: outside ? "circle.dashed" : "point.3.filled.connected.trianglepath.dotted")
                .foregroundStyle(.secondary)
            Text(outside ? "No Monad network" : key).font(.system(size: 13, weight: .semibold))
            if let definition {
                Text("\(definition.kind.title) · \(definition.subnet)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(CanvasStyle.card))
        .overlay(Capsule().stroke(CanvasStyle.cardLine))
        .contentShape(Capsule())
        .help(definition?.kind.summary ?? "VMs with no Monad network: no network device, or Apple's NAT")
        .onTapGesture {
            if !outside, canvas.tool == .zone {
                canvas.write(.zone, on: "net:" + key)
                canvas.tool = .select
            } else if !outside { _ = canvas.toolTap("net:" + key) }
        }
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
            .onChanged { v in
                let done = frameDragDone[key] ?? .zero
                canvas.moveNetwork(key, by: CGSize(width: (v.translation.width - done.width) / canvas.zoom,
                                                   height: (v.translation.height - done.height) / canvas.zoom))
                frameDragDone[key] = v.translation
            }
            .onEnded { _ in
                frameDragDone[key] = nil
                canvas.moved()
            })
        .contextMenu {
            if !outside {
                Button("New VM in \(key)") { canvas.makeVM(at: CGPoint(x: f.midX, y: f.midY)) }
                Button("Edit “\(key)”…") { canvas.editNetwork(key, at: f.origin) }
                Divider()
                Button("Add Label") { canvas.write(.label, on: "net:" + key) }
                Button("Add Note") { canvas.write(.note, on: "net:" + key) }
                Button("Wrap in a Zone") { canvas.write(.zone, on: "net:" + key) }
            }
        }
        .scaleEffect(canvas.zoom, anchor: .topLeading)
        .offset(x: (f.minX + 14) * canvas.zoom + canvas.pan.width, y: (f.minY - 16) * canvas.zoom + canvas.pan.height)
    }

    /// This Mac or the Internet: dragged where the user wants it; This Mac
    /// lists its forwards and bridges on a click or a right-click.
    private func landmark(_ which: CanvasLandmark, symbol: String, title: String, at p: CGPoint) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(CanvasStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(CanvasStyle.cardLine))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            if canvas.toolTap(which == .mac ? "mac" : "internet") { return }
            if which == .mac { canvas.showMacLinks() }
        }
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
            .onChanged { v in
                let start = landmarkDragStart ?? p
                if landmarkDragStart == nil { landmarkDragStart = start }
                canvas.moveLandmark(which, to: CGPoint(x: start.x + v.translation.width / canvas.zoom,
                                                       y: start.y + v.translation.height / canvas.zoom))
            }
            .onEnded { _ in
                landmarkDragStart = nil
                canvas.moved()
            })
        .contextMenu {
            if which == .mac { Button("Show Forwards and Bridges…") { canvas.showMacLinks() } }
        }
        .help(which == .mac ? "This Mac: click for its forwards and bridges to the VMs" : "The internet, reached through NAT networks")
        .scaleEffect(canvas.zoom)
        .position(canvas.screen(p))
    }

    private func card(_ vm: CanvasVM) -> some View {
        let p = canvas.model.position(vm.name) ?? .zero
        let remote = canvas.vm(named: vm.name)
        let selected = canvas.selected == vm.name
        return CanvasCard(vm: vm, remote: remote, selected: selected, hovered: canvas.hovered == vm.name)
            .onHover { inside in canvas.hovered = inside ? vm.name : (canvas.hovered == vm.name ? nil : canvas.hovered) }
            .onTapGesture { if !canvas.toolTap("vm:" + vm.name) { canvas.selected = vm.name } }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
                .onChanged { v in
                    let start = nodeDragStart[vm.name] ?? p
                    if nodeDragStart[vm.name] == nil { nodeDragStart[vm.name] = start }
                    canvas.drag(vm.name, to: CGPoint(x: start.x + v.translation.width / canvas.zoom,
                                                     y: start.y + v.translation.height / canvas.zoom))
                }
                .onEnded { v in
                    let start = nodeDragStart.removeValue(forKey: vm.name) ?? p
                    canvas.drop(vm.name, at: CGPoint(x: start.x + v.translation.width / canvas.zoom,
                                                     y: start.y + v.translation.height / canvas.zoom))
                })
            .contextMenu {
                if let remote {
                    Button("Terminal in the Canvas") { canvas.openTerminal(remote.name) }
                    Button("Open Tab") { appDelegate?.openTab(in: remote) }
                    Button("Connections") { appDelegate?.showDetails(of: remote, page: .connections) }
                    Button("Settings…") { appDelegate?.showDetails(of: remote) }
                    Divider()
                    if remote.isRunning {
                        Button("Restart") { Task { try? await canvas.host.restart(remote.name) } }
                        Button("Shut Down") { Task { try? await canvas.host.stop(remote.name) } }
                    } else {
                        Button("Start") { Task { try? await canvas.host.start(remote.name) } }
                    }
                    Divider()
                    Button("Add Label") { canvas.write(.label, on: "vm:" + remote.name) }
                    Button("Add Note") { canvas.write(.note, on: "vm:" + remote.name) }
                    Button("Arrow From Here") {
                        canvas.tool = .arrow
                        canvas.arrowStart = "vm:" + remote.name
                    }
                }
            }
            .scaleEffect(canvas.zoom)
            .position(canvas.screen(p))
            .transition(.scale(scale: 0.2).combined(with: .opacity))
    }

    // MARK: Chrome

    private var titleChip: some View {
        let networks = canvas.model.networks.count
        let vms = canvas.model.vms.count
        return HStack(spacing: 10) {
            Text("Canvas").font(.system(size: 13, weight: .bold))
            Text("\(vms) \(vms == 1 ? "VM" : "VMs") · \(canvas.running) running · \(networks) \(networks == 1 ? "network" : "networks")")
                .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(CanvasStyle.cardLine))
        .padding(.leading, 84).padding(.top, 10)
    }

    /// New: a palette of what can be made, in the middle of the view (a
    /// right-click makes it where the pointer is).
    private func newMenu(_ size: CGSize) -> some View {
        let middle = canvas.canvas(CGPoint(x: size.width / 2, y: size.height / 2))
        return Button { creating = true } label: {
            Label("New", systemImage: "plus")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(CanvasStyle.ember))
                .foregroundStyle(.white)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Make a VM or a network. Right-click the canvas to make one where the pointer is.")
        .popover(isPresented: $creating, arrowEdge: .bottom) {
            CreatePalette { choice in
                creating = false
                // A sheet presents once the popover is gone.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    switch choice {
                    case .vm: canvas.makeVM(at: middle)
                    case .network: canvas.makeNetwork(at: middle)
                    }
                }
            }
        }
        .padding(.trailing, 14).padding(.top, 10)
    }

    private func zoomControls(_ size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return HStack(spacing: 2) {
            Button { canvas.zoom(to: canvas.zoom / 1.25, around: center) } label: { Image(systemName: "minus") }
                .help("Zoom out")
            Text("\(Int((canvas.zoom * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .frame(width: 42)
            Button { canvas.zoom(to: canvas.zoom * 1.25, around: center) } label: { Image(systemName: "plus") }
                .help("Zoom in")
            Divider().frame(height: 16).padding(.horizontal, 2)
            Button { canvas.fit(size) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Show everything")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(CanvasStyle.cardLine))
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No VMs yet").font(.system(size: 15, weight: .semibold))
            Text("Use New, or right-click the canvas, to make one where you want it.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(CanvasStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(CanvasStyle.cardLine))
        .allowsHitTesting(false)
    }
}

// MARK: - A VM's card

/// A VM's tile (CanvasStyle.tile), `side` points square.
private struct VMTile: View {
    let config: InstanceConfig?
    let side: CGFloat

    var body: some View {
        let tile = config.map(CanvasStyle.tile) ?? (.letter(""), Color.gray)
        Group {
            switch tile.mark {
            case .letter(let l): Text(l).font(.system(size: side / 2, weight: .bold, design: .rounded))
            case .symbol(let s): Image(systemName: s).font(.system(size: side / 2, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: side, height: side)
        .background(RoundedRectangle(cornerRadius: side / 3.8).fill(tile.color))
    }
}

private struct CanvasCard: View {
    let vm: CanvasVM
    let remote: RemoteVM?
    let selected: Bool
    let hovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VMTile(config: remote?.config, side: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(release).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                StatusBadge(state: remote?.state ?? .stopped)
                Spacer(minLength: 4)
                Text(resources).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                if vm.linksToMac {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                        .help("Forwards or bridges to this Mac")
                }
            }
        }
        .padding(12)
        .frame(width: CanvasModel.node.width, height: CanvasModel.node.height)
        .background(RoundedRectangle(cornerRadius: 12).fill(CanvasStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(selected ? CanvasStyle.ember : (hovered ? CanvasStyle.cardLineHover : CanvasStyle.cardLine),
                    lineWidth: selected ? 2 : 1))
        .shadow(color: selected ? CanvasStyle.ember.opacity(0.35) : .black.opacity(0.18), radius: selected ? 10 : 3, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var release: String {
        guard let c = remote?.config else { return "" }
        let r = DistroCatalog.label(c)
        return c.group.map { "\(r) · \($0)" } ?? r
    }

    private var resources: String {
        guard let c = remote?.config else { return "" }
        return "\(c.cpus) CPU · \(c.memoryGiB) GB"
    }
}

// MARK: - Inspector

/// The selected VM: what it is, what it does, and its controls.
private struct CanvasInspector: View {
    @ObservedObject var vm: RemoteVM
    @ObservedObject var canvas: CanvasWindowModel

    private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    var body: some View {
        let c = vm.config
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VMTile(config: c, side: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.name).font(.system(size: 17, weight: .bold)).lineLimit(1)
                    StatusBadge(state: vm.state)
                }
                Spacer()
                Button { canvas.selected = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close (Esc)")
            }
            .padding(18)
            HStack(spacing: 8) {
                Button { canvas.openTerminal(vm.name) } label: { Label("Terminal", systemImage: "terminal") }
                    .buttonStyle(.borderedProminent).tint(CanvasStyle.ember)
                    .help("A terminal on this VM, docked below the canvas")
                Button("Open Tab") { appDelegate?.openTab(in: vm) }
                if vm.isRunning {
                    Button("Restart") { Task { try? await canvas.host.restart(vm.name) } }
                    Button("Shut Down") { Task { try? await canvas.host.stop(vm.name) } }
                } else {
                    Button("Start") { Task { try? await canvas.host.start(vm.name) } }
                }
            }
            .controlSize(.regular)
            .padding(.horizontal, 18).padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Machine") {
                        row("Distribution", DistroCatalog.label(c))
                        row("Processors", "\(c.cpus)")
                        row("Memory", "\(c.memoryGiB) GB")
                        row("Disk", "\(c.diskGiB) GB")
                    }
                    section("Network") {
                        row("Network", c.networks.first?.displayName ?? "None")
                        row("Firewall", firewall(c.firewall))
                    }
                    if !c.forwards.isEmpty || !c.bridges.isEmpty {
                        section("This Mac") {
                            ForEach(c.forwards.prefix(4)) { rule in
                                Text(VMSettingsDraft.describe(rule)).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            ForEach(c.bridges.prefix(4)) { bridge in
                                Text("Bridge \(bridge.name)").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    let peers = traffic
                    if !peers.isEmpty {
                        section("Traffic with other VMs") {
                            ForEach(peers, id: \.peer) { p in
                                HStack {
                                    Circle().fill(p.live ? CanvasStyle.ember : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                                    Text(p.peer).font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: p.bytes), countStyle: .file))
                                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                    HStack {
                        Button("Connections…") { appDelegate?.showDetails(of: vm, page: .connections) }
                        Button("Settings…") { appDelegate?.showDetails(of: vm) }
                    }
                }
                .padding(18)
            }
        }
        .background(CanvasStyle.panel)
        .overlay(alignment: .leading) { Rectangle().fill(CanvasStyle.cardLine).frame(width: 1) }
    }

    private var traffic: [(peer: String, bytes: UInt64, live: Bool)] {
        canvas.model.edges(traffic: canvas.traffic).compactMap { edge in
            guard case .traffic(let a, let b, let bytes, let live) = edge, a == vm.name || b == vm.name else { return nil }
            return (a == vm.name ? b : a, bytes, live)
        }
    }

    private func firewall(_ f: VMFirewall) -> String {
        let rules = f.rules.count + f.tags.count
        let mode = f.monitor ? "Asks about new destinations"
            : f.allowlist ? "Only what its rules allow"
            : f.allowLAN ? "Open, this Mac included" : "Open, this Mac and its network blocked"
        return rules == 0 ? mode : "\(mode) · \(f.rules.count) rules, \(f.tags.count) tags"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - This Mac

/// Every forward and bridge between this Mac and the VMs, by VM.
private struct MacLinksSheet: View {
    let entries: [MacLinks.Entry]
    var open: (String) -> Void
    var done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "laptopcomputer", color: .gray, title: "This Mac and the VMs",
                       subtitle: "Ports and sockets forwarded either way, and Mac programs the VMs can run.")
                .padding(.horizontal, 24).padding(.top, 18)
            if entries.isEmpty {
                Text("No VM has forwards or bridges to this Mac.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(entries, id: \.vm) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(entry.vm).font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Button("Port Forwarding…") { open(entry.vm) }.controlSize(.small)
                                }
                                ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                                    HStack(spacing: 8) {
                                        Image(systemName: line.bridge ? "terminal" : "arrow.left.arrow.right")
                                            .frame(width: 16).foregroundStyle(.secondary)
                                        Text(line.text).font(.system(size: 12))
                                            .foregroundStyle(line.on ? Color.primary : Color.secondary)
                                        if !line.on { TagLabel(text: "off") }
                                    }
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { done() }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - New

/// What New makes: a row each, Railway's "what would you like to create".
private struct CreatePalette: View {
    enum Choice { case vm, network }
    var onChoose: (Choice) -> Void
    @State private var hovered: Choice?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 6)
            row(.vm, symbol: "server.rack", title: "Virtual Machine", detail: "A Linux system with its own disk")
            row(.network, symbol: "point.3.filled.connected.trianglepath.dotted", title: "Network",
                detail: "NAT, host-only, internal or a plain switch")
        }
        .padding(6)
        .frame(width: 290)
    }

    private func row(_ choice: Choice, symbol: String, title: String, detail: String) -> some View {
        Button { onChoose(choice) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(CanvasStyle.ember.opacity(0.15)))
                    .foregroundStyle(CanvasStyle.ember)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovered == choice ? Color.secondary.opacity(0.12) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? choice : (hovered == choice ? nil : hovered) }
    }
}

// MARK: - Trackpad

/// Two-finger scrolling pans, a pinch or ⌘-scroll zooms around the pointer,
/// anywhere over the canvas (cards included); scroll views keep theirs.
private struct CanvasInput: NSViewRepresentable {
    var onScroll: (CGSize) -> Void
    var onZoom: (CGFloat, CGPoint) -> Void
    /// Delete or ⌫ with the canvas in front; true when it was used.
    var onDelete: () -> Bool

    func makeNSView(context: Context) -> InputView {
        let v = InputView()
        v.onScroll = onScroll
        v.onZoom = onZoom
        v.onDelete = onDelete
        return v
    }

    func updateNSView(_ v: InputView, context: Context) {
        v.onScroll = onScroll
        v.onZoom = onZoom
        v.onDelete = onDelete
    }

    final class InputView: NSView {
        var onScroll: ((CGSize) -> Void)?
        var onZoom: ((CGFloat, CGPoint) -> Void)?
        var onDelete: (() -> Bool)?
        private var monitor: Any?
        private var keys: Any?

        /// The canvas's own view (the split view's top item): keys count only
        /// while focus is there and not in a text field (the docked terminal
        /// and text being edited keep theirs).
        private var canvasRoot: NSView? {
            var v: NSView? = self
            while let s = v?.superview, !(s is NSSplitView), s !== window?.contentView { v = s }
            return v
        }

        private func takesKeys(_ window: NSWindow) -> Bool {
            guard let responder = window.firstResponder else { return true }
            if responder === window { return true }
            guard let view = responder as? NSView, !(view is NSText), let root = canvasRoot else { return false }
            return view.isDescendant(of: root)
        }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let keys { NSEvent.removeMonitor(keys) }
            monitor = nil
            keys = nil
            guard window != nil else { return }
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      event.keyCode == 51 || event.keyCode == 117,
                      event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                      self.takesKeys(window), self.onDelete?() == true else { return event }
                return nil
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                if window.contentView?.hitTest(event.locationInWindow)?.enclosingScrollView != nil { return event }
                if event.type == .magnify {
                    self.onZoom?(1 + event.magnification, p)
                } else if event.modifierFlags.contains(.command) {
                    self.onZoom?(exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)), p)
                } else {
                    let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                    self.onScroll?(CGSize(width: event.scrollingDeltaX * k, height: event.scrollingDeltaY * k))
                }
                return nil
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let keys { NSEvent.removeMonitor(keys) }
            monitor = nil
            keys = nil
            super.removeFromSuperview()
        }
    }
}

#if DEBUG
#Preview("Canvas") {
    CanvasView(canvas: .preview()).frame(width: 1240, height: 800)
}
#endif
