//
//  CanvasNotes.swift — what the user and agents write on the canvas: notes
//  (Markdown on a coloured card, free or pinned beside a VM or network),
//  labels (chips on a VM or network), zones (a titled area drawn by hand,
//  or wrapped around networks and VMs and following them), arrows with
//  words between any two things, and ink. MonadHost keeps them in
//  ~/.monad/canvas-notes.json (0600) and tells every app when they change;
//  agents write them through the MCP tools, the user on the canvas. Each
//  is checked as input from an agent, whoever wrote it (docs/CANVAS.md).
//

import CoreGraphics
import Foundation

/// A thing on the canvas, by name: "vm:<name>", "net:<name>",
/// "note:<id>", "mac" or "internet".
enum CanvasRef: Equatable {
    case vm(String)
    case network(String)
    case note(String)
    case mac
    case internet

    init?(_ text: String) {
        switch text {
        case "mac": self = .mac
        case "internet": self = .internet
        default:
            if text.hasPrefix("vm:"), InstanceConfig.isValidName(String(text.dropFirst(3))) {
                self = .vm(String(text.dropFirst(3)))
            } else if text.hasPrefix("net:"), NetworkDefinition.isValidName(String(text.dropFirst(4))) {
                self = .network(String(text.dropFirst(4)))
            } else if text.hasPrefix("note:"), CanvasNote.isID(String(text.dropFirst(5))) {
                self = .note(String(text.dropFirst(5)))
            } else {
                return nil
            }
        }
    }

    /// `text` as a ref: one already, else a VM's name, else a network's.
    static func resolve(_ text: String, vms: [String], networks: [String]) -> String? {
        if CanvasRef(text) != nil { return text }
        if vms.contains(text) { return "vm:" + text }
        if networks.contains(text) { return "net:" + text }
        return nil
    }

    /// A VM or a network (what labels, pinned notes and zones are on).
    var isPlace: Bool {
        switch self {
        case .vm, .network: return true
        default: return false
        }
    }
}

struct CanvasNote: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable { case note, label, zone, arrow, ink }
    enum Tint: String, Codable, CaseIterable, Sendable { case yellow, orange, red, green, blue, purple, gray }

    static let maxNotes = 500
    static let maxText = 4000
    static let maxLabel = 80
    static let maxPoints = 2000
    static let maxAround = 16
    /// Coordinates past this are not a place on any canvas.
    static let maxCoordinate: CGFloat = 1e7
    static let maxSize: CGFloat = 20_000

    var id: String
    var kind: Kind
    var text: String = ""
    var tint: Tint = .yellow
    /// note, zone: where it is; nil for a note placed beside what it is on,
    /// or a zone wrapped around `around`.
    var frame: CGRect?
    /// label, pinned note: the VM or network it is on; arrow: where it starts.
    var on: String?
    /// arrow: where it ends.
    var to: String?
    /// zone: the VMs and networks it wraps.
    var around: [String]?
    /// ink: the stroke.
    var points: [CGPoint]?
    /// "you", "mac" (an agent on this Mac) or "vm:<name>" (an agent in it).
    var author: String = "you"

    static func isID(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9]{1,16}$", options: .regularExpression) != nil
    }

    static func newID() -> String {
        String((0..<8).map { _ in "0123456789abcdef".randomElement()! })
    }

    static func isAuthor(_ s: String) -> Bool {
        s == "you" || s == "mac" || (s.hasPrefix("vm:") && InstanceConfig.isValidName(String(s.dropFirst(3))))
    }

    private static func sane(_ v: CGFloat) -> Bool { v.isFinite && abs(v) < maxCoordinate }

    func validate() throws {
        guard Self.isID(id) else { throw MonadError("A note's id is 1 to 16 lowercase letters and digits.") }
        guard Self.isAuthor(author) else { throw MonadError("Not a note's author.") }
        let limit = kind == .label ? Self.maxLabel : Self.maxText
        guard text.count <= limit else { throw MonadError("At most \(limit) characters.") }
        guard !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t" }) else {
            throw MonadError("No control characters in a note.")
        }
        if let f = frame {
            guard [f.minX, f.minY].allSatisfy(Self.sane), f.width.isFinite, f.height.isFinite,
                  f.width > 0, f.height > 0, f.width <= Self.maxSize, f.height <= Self.maxSize else {
                throw MonadError("Not a place on the canvas.")
            }
        }
        let onRef = try on.map(Self.ref)
        let toRef = try to.map(Self.ref)
        switch kind {
        case .note:
            if let onRef, !onRef.isPlace { throw MonadError("A note is pinned to a VM or a network.") }
        case .label:
            guard let onRef, onRef.isPlace else { throw MonadError("A label is on a VM or a network.") }
        case .arrow:
            guard on != nil, to != nil else { throw MonadError("An arrow goes from one thing to another.") }
            guard onRef != toRef else { throw MonadError("An arrow goes to something else.") }
        case .zone:
            let refs = try (around ?? []).map(Self.ref)
            guard refs.count <= Self.maxAround else { throw MonadError("A zone wraps at most \(Self.maxAround) things.") }
            guard refs.allSatisfy(\.isPlace) else { throw MonadError("A zone wraps VMs and networks.") }
            guard frame != nil || !refs.isEmpty else { throw MonadError("A zone has a place, or wraps VMs or networks.") }
        case .ink:
            guard let points, (2...Self.maxPoints).contains(points.count),
                  points.allSatisfy({ Self.sane($0.x) && Self.sane($0.y) }) else {
                throw MonadError("Ink is a stroke of 2 to \(Self.maxPoints) points.")
            }
        }
    }

    private static func ref(_ s: String) throws -> CanvasRef {
        guard let r = CanvasRef(s) else {
            throw MonadError("“\(s.prefix(40))” is not a thing on the canvas (vm:<name>, net:<name>, note:<id>, mac or internet).")
        }
        return r
    }

    /// The notes once `ref` is gone: its labels and arrows go, notes pinned
    /// to it are unpinned, zones stop wrapping it (and go when they wrapped
    /// only it); a note that goes takes the arrows to it along.
    static func forget(_ ref: String, in notes: [CanvasNote]) -> [CanvasNote] {
        notes.compactMap { n in
            if ref == "note:" + n.id { return nil }
            var n = n
            switch n.kind {
            case .label:
                if n.on == ref { return nil }
            case .arrow:
                if n.on == ref || n.to == ref { return nil }
            case .note:
                if n.on == ref { n.on = nil }
            case .zone:
                if let around = n.around, around.contains(ref) {
                    let rest = around.filter { $0 != ref }
                    if rest.isEmpty && n.frame == nil { return nil }
                    n.around = rest.isEmpty ? nil : rest
                }
            case .ink:
                break
            }
            return n
        }
    }

    /// A stroke with the points that add nothing left out (Ramer–Douglas–
    /// Peucker), coarser until it fits `maxPoints`.
    static func simplify(_ points: [CGPoint], tolerance: CGFloat = 1.5) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var tolerance = tolerance
        while true {
            var keep = [Bool](repeating: false, count: points.count)
            keep[0] = true
            keep[points.count - 1] = true
            var stack = [(0, points.count - 1)]
            while let (a, b) = stack.popLast() {
                guard b > a + 1 else { continue }
                var far = a, distance: CGFloat = -1
                for i in (a + 1)..<b {
                    let d = CanvasNotesLayout.distance(points[i], points[a], points[b])
                    if d > distance { distance = d; far = i }
                }
                if distance > tolerance {
                    keep[far] = true
                    stack.append((a, far))
                    stack.append((far, b))
                }
            }
            let out = zip(points, keep).filter(\.1).map(\.0)
            if out.count <= maxPoints { return out }
            tolerance *= 2
        }
    }
}

// MARK: - Placing

extension CanvasModel {
    static func nodeRect(at center: CGPoint) -> CGRect {
        CGRect(x: center.x - node.width / 2, y: center.y - node.height / 2, width: node.width, height: node.height)
    }

    /// Where a VM, network, This Mac or the Internet is (notes are placed by
    /// CanvasNotesLayout); nil for what is not on the canvas.
    func rect(of ref: String) -> CGRect? {
        switch CanvasRef(ref) {
        case .vm(let name)?: return position(name).map(Self.nodeRect)
        case .network(let name)?: return frame(name)
        case .mac?: return CGRect(x: macPosition.x - 65, y: macPosition.y - 22, width: 130, height: 44)
        case .internet?: return CGRect(x: internetPosition.x - 60, y: internetPosition.y - 22, width: 120, height: 44)
        case .note?, nil: return nil
        }
    }
}

enum CanvasNotesLayout {
    static let noteWidth: CGFloat = 230
    static let minHeight: CGFloat = 64
    static let maxAutoHeight: CGFloat = 360
    static let gap: CGFloat = 18
    /// Room a wrapping zone leaves around what it wraps, and above it for its title.
    static let zoneMargin: CGFloat = 28
    static let zoneTitle: CGFloat = 36

    /// A note's size for its text, about 30 characters a line.
    static func size(of text: String) -> CGSize {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int((Double($1.count) / 30).rounded(.up))) }
        return CGSize(width: noteWidth, height: min(max(30 + CGFloat(lines) * 18, minHeight), maxAutoHeight))
    }

    /// Where each note and zone is drawn, by id: its own frame, else beside
    /// what it is pinned to (stacked down), else in a column right of
    /// everything; a zone around what it wraps.
    static func place(_ notes: [CanvasNote], in m: CanvasModel) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        let landmarks = [m.rect(of: "mac"), m.rect(of: "internet")].compactMap { $0 }
        let everything = (Array(m.layout.frames.values) + landmarks).reduce(CGRect.null) { $0.union($1) }
        let column = everything.isNull ? CGPoint.zero : CGPoint(x: everything.maxX + 60, y: everything.minY)
        var below: [String: CGFloat] = [:]
        var freeY = column.y
        for n in notes {
            switch n.kind {
            case .note:
                if let f = n.frame { out[n.id] = f; continue }
                let size = size(of: n.text)
                if let on = n.on, let r = m.rect(of: on) {
                    let y = below[on] ?? r.minY
                    out[n.id] = CGRect(origin: CGPoint(x: r.maxX + gap, y: y), size: size)
                    below[on] = y + size.height + gap / 2
                } else {
                    out[n.id] = CGRect(origin: CGPoint(x: column.x, y: freeY), size: size)
                    freeY += size.height + gap
                }
            case .zone:
                if let f = n.frame { out[n.id] = f; continue }
                let wrapped = (n.around ?? []).compactMap { m.rect(of: $0) }.reduce(CGRect.null) { $0.union($1) }
                guard !wrapped.isNull else { continue }
                out[n.id] = CGRect(x: wrapped.minX - zoneMargin, y: wrapped.minY - zoneMargin - zoneTitle,
                                   width: wrapped.width + zoneMargin * 2, height: wrapped.height + zoneMargin * 2 + zoneTitle)
            case .label, .arrow, .ink:
                break
            }
        }
        return out
    }

    /// Where a ref is, notes included.
    static func rect(of ref: String, places: [String: CGRect], in m: CanvasModel) -> CGRect? {
        if case .note(let id)? = CanvasRef(ref) { return places[id] }
        return m.rect(of: ref)
    }

    /// A gentle curve from one edge to another.
    struct Arrow: Equatable {
        var start: CGPoint
        var control: CGPoint
        var end: CGPoint

        func point(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                           y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
        }

        /// The direction it arrives in, for the head.
        var heading: CGFloat { atan2(end.y - control.y, end.x - control.x) }
    }

    static func arrow(from a: CGRect, to b: CGRect) -> Arrow {
        let ca = CGPoint(x: a.midX, y: a.midY), cb = CGPoint(x: b.midX, y: b.midY)
        let start = edge(of: a, toward: cb), end = edge(of: b, toward: ca)
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let dx = end.x - start.x, dy = end.y - start.y
        let bend: CGFloat = 0.12
        return Arrow(start: start, control: CGPoint(x: mid.x - dy * bend, y: mid.y + dx * bend), end: end)
    }

    /// Where the line from `r`'s middle toward `p` leaves `r`.
    static func edge(of r: CGRect, toward p: CGPoint) -> CGPoint {
        let c = CGPoint(x: r.midX, y: r.midY)
        let dx = p.x - c.x, dy = p.y - c.y
        guard dx != 0 || dy != 0 else { return CGPoint(x: r.maxX, y: c.y) }
        let tx = dx == 0 ? CGFloat.infinity : (r.width / 2) / abs(dx)
        let ty = dy == 0 ? CGFloat.infinity : (r.height / 2) / abs(dy)
        let t = min(tx, ty)
        return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
    }

    /// Distance from `p` to the segment a–b.
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = dx * dx + dy * dy
        let t = len == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// The arrow, stroke or zone edge (or title) under `p`, the top one
    /// first; notes and labels take their own clicks.
    static func hit(_ p: CGPoint, _ notes: [CanvasNote], places: [String: CGRect], in m: CanvasModel,
                    tolerance: CGFloat = 8) -> String? {
        for n in notes.reversed() {
            switch n.kind {
            case .ink:
                let pts = n.points ?? []
                if zip(pts, pts.dropFirst()).contains(where: { distance(p, $0, $1) <= tolerance + 2 }) { return n.id }
            case .arrow:
                guard let on = n.on, let to = n.to, let a = rect(of: on, places: places, in: m),
                      let b = rect(of: to, places: places, in: m) else { continue }
                let arrow = arrow(from: a, to: b)
                let samples = (0...32).map { arrow.point(at: CGFloat($0) / 32) }
                if zip(samples, samples.dropFirst()).contains(where: { distance(p, $0, $1) <= tolerance }) { return n.id }
            case .zone:
                guard let r = places[n.id] else { continue }
                let near = r.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
                let inner = r.insetBy(dx: tolerance, dy: tolerance)
                let title = CGRect(x: r.minX, y: r.minY, width: r.width, height: zoneTitle)
                if near && (!inner.contains(p) || title.contains(p)) { return n.id }
            case .note, .label:
                break
            }
        }
        return nil
    }
}

/// The notes on disk (~/.monad/canvas-notes.json), private to the user,
/// written by MonadHost only. Notes that fail their checks are left out.
struct CanvasNoteStore {
    let url: URL

    init(url: URL = Paths.root.appendingPathComponent("canvas-notes.json")) {
        self.url = url
    }

    private struct File: Codable {
        var version = 1
        var notes: [CanvasNote]
    }

    func load() -> [CanvasNote] {
        guard let data = try? Data(contentsOf: url), data.count < 8 << 20,
              let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 else { return [] }
        var seen = Set<String>()
        return Array(file.notes.filter { (try? $0.validate()) != nil && seen.insert($0.id).inserted }.prefix(CanvasNote.maxNotes))
    }

    func save(_ notes: [CanvasNote]) throws {
        try Paths.ensurePrivateDirectory(url.deletingLastPathComponent())
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(File(notes: notes)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
