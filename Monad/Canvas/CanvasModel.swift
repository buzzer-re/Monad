//
//  CanvasModel.swift — the canvas (Phase 13): the Monad networks as frames
//  and the VMs as nodes inside them, This Mac and the Internet beside them,
//  and edges: traffic between VMs (netd's switch), forwards and bridges to
//  this Mac, and the way out of NAT networks. A VM's network is the frame
//  it sits in: dropped into another, the canvas asks to move it there (the
//  window confirms and saves). New networks and VMs are placed on their
//  own; what the user moves stays where it is put, saved in
//  ~/.monad/canvas.json. Geometry only, no UI (docs/CANVAS.md).
//

import CoreGraphics
import Foundation

/// A VM as the canvas shows it.
struct CanvasVM: Equatable {
    var name: String
    /// Its Monad network; nil for none here (no network device, Apple's NAT,
    /// or a network that is gone).
    var network: String?
    var running: Bool
    /// Forwards or bridges between it and this Mac.
    var linksToMac: Bool
}

extension CanvasVM {
    /// From the VM's settings; `networks` are the Monad networks there are.
    init(config: InstanceConfig, running: Bool, networks: [String]) {
        let network = config.networks.first.flatMap { $0.isAppleNAT || !networks.contains($0.network) ? nil : $0.network }
        let links = config.forwards.contains { $0.enabled } || config.bridges.contains { $0.enabled }
        self.init(name: config.name, network: network, running: running, linksToMac: links)
    }
}

struct CanvasNetwork: Equatable {
    var name: String
    var kind: NetworkDefinition.Kind
}

/// Where everything is: frames by network (CanvasModel.outside for the VMs
/// on no Monad network), node centres by VM.
struct CanvasLayout: Codable, Equatable {
    static let currentVersion = 1
    var version = CanvasLayout.currentVersion
    var frames: [String: CGRect] = [:]
    var nodes: [String: CGPoint] = [:]
    /// This Mac and the Internet: placed once beside the groups, then where
    /// the user puts them (absent in layouts saved before they were kept).
    var mac: CGPoint?
    var internet: CGPoint?
}

enum CanvasLandmark { case mac, internet }

enum CanvasEdge: Equatable, Hashable {
    /// Between two VMs, both ways (names in order): bytes, and whether seen lately.
    case traffic(String, String, bytes: UInt64, live: Bool)
    /// A VM with forwards or bridges to this Mac.
    case mac(String)
    /// A NAT network's way out.
    case internet(String)
}

/// What a drop asks for; the window confirms and saves it.
enum CanvasIntent: Equatable {
    case moveVM(String, from: String?, to: String)
}

struct CanvasModel {
    static let node = CGSize(width: 240, height: 96)
    static let padding: CGFloat = 24
    static let header: CGFloat = 44
    static let gap: CGFloat = 20
    static let frameGap: CGFloat = 80
    /// New networks fill a row this wide, then start the next one below.
    static let rowWidth: CGFloat = 1000
    static let columns = 2
    /// The area of the VMs on no Monad network (never a network name).
    static let outside = ""
    /// Traffic seen this many seconds ago or less is live.
    static let liveWithin = 10
    static let minFrame = CGSize(width: padding * 2 + CGFloat(columns) * node.width + CGFloat(columns - 1) * gap,
                                 height: header + padding * 2 + node.height)

    private(set) var layout: CanvasLayout
    private(set) var vms: [CanvasVM] = []
    private(set) var networks: [CanvasNetwork] = []
    /// VMs dropped into another network, waiting for the answer: where to.
    private var pending: [String: String] = [:]
    /// Where a dragged node started, and where a node waiting for an
    /// answer goes back to if the answer is no.
    private var dragOrigin: [String: CGPoint] = [:]
    private var moveOrigin: [String: CGPoint] = [:]
    /// Where something being made on the canvas goes once it exists.
    private var vmHints: [String: CGPoint] = [:]
    private var networkHints: [String: CGPoint] = [:]

    init(layout: CanvasLayout = CanvasLayout()) {
        self.layout = layout
    }

    func frame(_ network: String) -> CGRect? { layout.frames[network] }
    func position(_ vm: String) -> CGPoint? { layout.nodes[vm] }

    /// The Monad network whose frame holds `point`.
    func network(at point: CGPoint) -> String? {
        networks.map(\.name).first { layout.frames[$0]?.contains(point) == true }
    }

    var internetPosition: CGPoint {
        layout.internet ?? CGPoint(x: bounds.midX, y: bounds.minY - 110)
    }

    var macPosition: CGPoint {
        layout.mac ?? CGPoint(x: bounds.minX - 150, y: bounds.midY)
    }

    /// A layout from before (⌘Z): frames, nodes and landmarks as they were.
    mutating func restore(_ layout: CanvasLayout) {
        self.layout = layout
        fit()
    }

    /// This Mac or the Internet moved by the user.
    mutating func moveLandmark(_ landmark: CanvasLandmark, to point: CGPoint) {
        switch landmark {
        case .mac: layout.mac = point
        case .internet: layout.internet = point
        }
    }

    // MARK: Keeping up with the VMs and networks

    /// A VM being made at `point`: it appears there if that is in its network.
    mutating func hint(vm: String, at point: CGPoint) {
        vmHints[vm] = point
    }

    /// A network being made at `point`: its frame's top left goes there.
    mutating func hint(network: String, at point: CGPoint) {
        networkHints[network] = point
    }

    /// The VMs and networks there are now: new ones placed, gone ones
    /// dropped, frames grown to hold their VMs. Nothing else moves.
    mutating func update(vms: [CanvasVM], networks: [CanvasNetwork]) {
        self.vms = vms
        self.networks = networks
        var keys = networks.map(\.name)
        if vms.contains(where: { $0.network == nil }) { keys.append(Self.outside) }
        layout.frames = layout.frames.filter { keys.contains($0.key) }
        layout.nodes = layout.nodes.filter { name, _ in vms.contains { $0.name == name } }
        // An answered move is settled once the VM's settings say so.
        pending = pending.filter { name, target in
            guard keys.contains(target), let vm = vms.first(where: { $0.name == name }) else { return false }
            return vm.network != target
        }
        moveOrigin = moveOrigin.filter { pending[$0.key] != nil }
        for key in keys where layout.frames[key] == nil {
            let origin = networkHints.removeValue(forKey: key) ?? nextFrameOrigin()
            layout.frames[key] = CGRect(origin: origin, size: Self.minFrame)
        }
        for vm in vms {
            let area = place(of: vm)
            let hint = vmHints.removeValue(forKey: vm.name)
            if let p = layout.nodes[vm.name], let f = layout.frames[area], f.contains(rect(at: p)) { continue }
            if layout.nodes[vm.name] == nil, let hint, layout.frames[area]?.contains(hint) == true {
                layout.nodes[vm.name] = hint
                continue
            }
            layout.nodes[vm.name] = freeSlot(in: area, for: vm.name)
        }
        fit()
        // Placed once beside the groups, then left where they are.
        if !layout.frames.isEmpty {
            if layout.internet == nil { layout.internet = internetPosition }
            if layout.mac == nil { layout.mac = macPosition }
        }
    }

    // MARK: Moving things

    /// A node being dragged.
    mutating func drag(_ vm: String, to point: CGPoint) {
        guard let p = layout.nodes[vm] else { return }
        if dragOrigin[vm] == nil { dragOrigin[vm] = p }
        layout.nodes[vm] = point
    }

    /// A node let go: in another network's frame it asks to move the VM
    /// there (and waits there for the answer), in its own area it stays
    /// where it is put, anywhere else it goes back.
    mutating func drop(_ vm: String, at point: CGPoint) -> CanvasIntent? {
        guard let v = vms.first(where: { $0.name == vm }), let current = layout.nodes[vm] else { return nil }
        let origin = dragOrigin.removeValue(forKey: vm) ?? current
        if let target = network(at: point), target != v.network {
            layout.nodes[vm] = point
            pending[vm] = target
            moveOrigin[vm] = moveOrigin[vm] ?? origin
            fit()
            return .moveVM(vm, from: v.network, to: target)
        }
        if let own = layout.frames[place(of: v)], own.contains(point) {
            layout.nodes[vm] = point
            fit()
            return nil
        }
        layout.nodes[vm] = origin
        return nil
    }

    /// The answer was no (or saving failed): back where it was.
    mutating func cancelMove(_ vm: String) {
        pending[vm] = nil
        if let origin = moveOrigin.removeValue(forKey: vm) { layout.nodes[vm] = origin }
    }

    /// The VM's settings once a move is answered yes: its network, its MAC
    /// kept (its lease on each network goes with the MAC), nothing else.
    static func config(_ config: InstanceConfig, movedTo network: String) -> InstanceConfig {
        var c = config
        c.networks = [NetworkAttachment(network: network, macAddress: config.networks.first?.macAddress)]
        return c
    }

    /// A frame moved, its VMs with it.
    mutating func moveNetwork(_ name: String, by delta: CGSize) {
        guard let f = layout.frames[name] else { return }
        layout.frames[name] = f.offsetBy(dx: delta.width, dy: delta.height)
        for vm in vms where place(of: vm) == name {
            if let p = layout.nodes[vm.name] { layout.nodes[vm.name] = CGPoint(x: p.x + delta.width, y: p.y + delta.height) }
        }
    }

    // MARK: Edges

    /// Traffic between VMs on the canvas (both ways in one edge), the VMs
    /// linked to this Mac, and the NAT networks' way out.
    func edges(traffic: [VMTraffic]) -> [CanvasEdge] {
        let names = Set(vms.map(\.name))
        var pairs: [String: (a: String, b: String, bytes: UInt64, last: Int)] = [:]
        for t in traffic where t.from != t.to && names.contains(t.from) && names.contains(t.to) {
            let (a, b) = t.from < t.to ? (t.from, t.to) : (t.to, t.from)
            var e = pairs[a + "\u{0}" + b] ?? (a, b, 0, Int.max)
            let (sum, overflow) = e.bytes.addingReportingOverflow(t.bytes)
            e.bytes = overflow ? .max : sum
            e.last = min(e.last, t.lastSeen)
            pairs[a + "\u{0}" + b] = e
        }
        var out: [CanvasEdge] = pairs.values.sorted { ($0.a, $0.b) < ($1.a, $1.b) }
            .map { .traffic($0.a, $0.b, bytes: $0.bytes, live: $0.last <= Self.liveWithin) }
        out += vms.filter(\.linksToMac).map(\.name).sorted().map { .mac($0) }
        out += networks.filter { $0.kind == .nat }.map(\.name).sorted().map { .internet($0) }
        return out
    }

    // MARK: Geometry

    /// The area a VM's node belongs in: where it waits for an answer, else
    /// its network's frame, else the outside area.
    private func place(of vm: CanvasVM) -> String {
        pending[vm.name] ?? vm.network ?? Self.outside
    }

    private func rect(at center: CGPoint) -> CGRect {
        CGRect(x: center.x - Self.node.width / 2, y: center.y - Self.node.height / 2,
               width: Self.node.width, height: Self.node.height)
    }

    private var bounds: CGRect {
        let all = layout.frames.values.reduce(CGRect.null) { $0.union($1) }
        return all.isNull ? .zero : all
    }

    /// Right of the last row's frames while the row has room, else the
    /// start of a new row below everything.
    private func nextFrameOrigin() -> CGPoint {
        let frames = Array(layout.frames.values)
        guard let lastRowTop = frames.map(\.minY).max() else { return .zero }
        let row = frames.filter { abs($0.minY - lastRowTop) < 1 }
        let x = (row.map(\.maxX).max() ?? 0) + Self.frameGap
        if x + Self.minFrame.width <= Self.rowWidth + Self.minFrame.width, x <= Self.rowWidth {
            return CGPoint(x: x, y: lastRowTop)
        }
        return CGPoint(x: 0, y: (frames.map(\.maxY).max() ?? 0) + Self.frameGap)
    }

    private func slot(_ i: Int, in f: CGRect) -> CGPoint {
        let col = i % Self.columns, row = i / Self.columns
        return CGPoint(x: f.minX + Self.padding + CGFloat(col) * (Self.node.width + Self.gap) + Self.node.width / 2,
                       y: f.minY + Self.header + Self.padding + CGFloat(row) * (Self.node.height + Self.gap)
                           + Self.node.height / 2)
    }

    /// The first slot of the frame no other node covers.
    private func freeSlot(in area: String, for vm: String) -> CGPoint {
        let f = layout.frames[area] ?? CGRect(origin: .zero, size: Self.minFrame)
        var i = 0
        while true {
            let p = slot(i, in: f)
            let room = rect(at: p).insetBy(dx: -Self.gap / 4, dy: -Self.gap / 4)
            if !layout.nodes.contains(where: { $0.key != vm && rect(at: $0.value).intersects(room) }) { return p }
            i += 1
        }
    }

    /// Frames grow to hold their nodes, and frames that came to overlap move
    /// right, their nodes with them.
    private mutating func fit() {
        for (key, f) in layout.frames {
            var grown = f
            for vm in vms where place(of: vm) == key {
                if let p = layout.nodes[vm.name] { grown = grown.union(rect(at: p).insetBy(dx: -Self.padding, dy: -Self.padding)) }
            }
            grown.size.width = max(grown.width, Self.minFrame.width)
            grown.size.height = max(grown.height, Self.minFrame.height)
            layout.frames[key] = grown
        }
        let order = layout.frames.sorted { ($0.value.minX, $0.key) < ($1.value.minX, $1.key) }.map(\.key)
        for (i, key) in order.enumerated() {
            for earlier in order[..<i] {
                guard let f = layout.frames[key], let e = layout.frames[earlier],
                      f.insetBy(dx: -(Self.frameGap / 2 - 1), dy: -(Self.frameGap / 2 - 1)).intersects(e) else { continue }
                moveNetwork(key, by: CGSize(width: e.maxX + Self.frameGap - f.minX, height: 0))
            }
        }
    }
}

/// The layout on disk (~/.monad/canvas.json), private to the user. A file
/// that cannot be read, or from a newer Monad, starts the layout again.
struct CanvasStore {
    let url: URL

    init(url: URL = Paths.root.appendingPathComponent("canvas.json")) {
        self.url = url
    }

    func load() -> CanvasLayout {
        guard let data = try? Data(contentsOf: url),
              var layout = try? JSONDecoder().decode(CanvasLayout.self, from: data),
              layout.version == CanvasLayout.currentVersion else { return CanvasLayout() }
        let sane: (CGFloat) -> Bool = { $0.isFinite && abs($0) < 1e7 }
        layout.frames = layout.frames.filter { [$0.value.minX, $0.value.minY, $0.value.width, $0.value.height].allSatisfy(sane) }
        layout.nodes = layout.nodes.filter { sane($0.value.x) && sane($0.value.y) }
        if let p = layout.mac, !(sane(p.x) && sane(p.y)) { layout.mac = nil }
        if let p = layout.internet, !(sane(p.x) && sane(p.y)) { layout.internet = nil }
        return layout
    }

    func save(_ layout: CanvasLayout) throws {
        try Paths.ensurePrivateDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(layout).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
