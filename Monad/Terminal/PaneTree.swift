//
//  PaneTree.swift — the split panes of a terminal window (Phase 11): an
//  n-ary tiling tree, as in i3 or yabai. Splitting a pane along its
//  parent's axis adds a sibling, the other way nests a split; closing a
//  pane collapses a split left with one child and merges a split into a
//  parent running the same way; a pane moves to another pane's edge (drag
//  and drop); focus moves by direction; dividers set each split's
//  fractions. Pure: the views are built from it, and it is Codable so a
//  layout can be kept.
//

import Foundation

/// One pane of a window.
struct PaneID: Hashable, Codable, CustomStringConvertible {
    let value: String
    init(_ value: String) { self.value = value }
    static func make() -> PaneID { PaneID(UUID().uuidString) }
    var description: String { value }
}

struct PaneTree: Equatable, Codable {
    /// horizontal: side by side (a vertical divider); vertical: stacked.
    enum Axis: String, Codable { case horizontal, vertical }
    enum Edge: String, Codable { case left, right, top, bottom }
    enum Direction { case left, right, up, down }

    indirect enum Node: Equatable, Codable {
        case pane(PaneID)
        case split(Split)
    }

    /// Children in order (left to right, top to bottom), each with its
    /// share of the split's room; the fractions add up to 1.
    struct Split: Equatable, Codable {
        var axis: Axis
        var children: [Node]
        var fractions: [Double]
    }

    /// The least room a divider leaves a pane, as a fraction of its split.
    static let minimumFraction = 0.05

    private(set) var root: Node
    private(set) var focused: PaneID

    init(pane: PaneID) {
        root = .pane(pane)
        focused = pane
    }

    /// Every pane, left to right and top to bottom.
    var panes: [PaneID] { Self.panes(in: root) }

    func contains(_ pane: PaneID) -> Bool { panes.contains(pane) }

    // MARK: Changes

    /// A new pane beside `pane` (after it), which takes the focus.
    mutating func split(_ pane: PaneID, _ axis: Axis, new: PaneID) {
        guard contains(pane), !contains(new) else { return }
        root = Self.inserting(new, beside: pane, axis: axis, before: false, in: root)
        focused = new
    }

    /// Removes `pane`; false (and nothing changes) for the last pane, which
    /// closes the window instead, or a pane not in the tree. The focus moves
    /// to the pane before it, else the one after.
    mutating func close(_ pane: PaneID) -> Bool {
        let order = panes
        guard order.count > 1, let i = order.firstIndex(of: pane), let rest = Self.removing(pane, from: root) else {
            return false
        }
        root = Self.flattened(rest)
        if focused == pane { focused = i > 0 ? order[i - 1] : order[i + 1] }
        return true
    }

    /// `pane` dropped on `target`'s edge: it leaves its place and goes
    /// there, focused.
    mutating func move(_ pane: PaneID, to target: PaneID, edge: Edge) {
        guard pane != target, contains(pane), contains(target), let rest = Self.removing(pane, from: root) else { return }
        let axis: Axis = edge == .left || edge == .right ? .horizontal : .vertical
        root = Self.flattened(Self.inserting(pane, beside: target, axis: axis, before: edge == .left || edge == .top,
                                             in: Self.flattened(rest)))
        focused = pane
    }

    mutating func focus(_ pane: PaneID) {
        if contains(pane) { focused = pane }
    }

    /// The nearest pane that way: of those as near, the one overlapping
    /// the focused pane most, then the top or left one. Nothing there: the
    /// focus stays.
    mutating func focus(_ direction: Direction) {
        let frames = frames(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let from = frames[focused] else { return }
        let e = 1e-9
        var best: (pane: PaneID, distance: Double, overlap: Double, position: Double)?
        for pane in panes where pane != focused {
            guard let f = frames[pane] else { continue }
            let distance: Double, overlap: Double, position: Double
            switch direction {
            case .right, .left:
                guard direction == .right ? f.minX >= from.maxX - e : f.maxX <= from.minX + e else { continue }
                distance = direction == .right ? f.minX - from.maxX : from.minX - f.maxX
                overlap = min(f.maxY, from.maxY) - max(f.minY, from.minY)
                position = f.minY
            case .down, .up:
                guard direction == .down ? f.minY >= from.maxY - e : f.maxY <= from.minY + e else { continue }
                distance = direction == .down ? f.minY - from.maxY : from.minY - f.maxY
                overlap = min(f.maxX, from.maxX) - max(f.minX, from.minX)
                position = f.minX
            }
            guard overlap > e else { continue }
            if let b = best {
                let nearer = distance < b.distance - e
                let asNear = abs(distance - b.distance) <= e
                let moreOverlap = overlap > b.overlap + e
                let asMuch = abs(overlap - b.overlap) <= e
                guard nearer || asNear && (moreOverlap || asMuch && position < b.position) else { continue }
            }
            best = (pane, distance, overlap, position)
        }
        if let best { focused = best.pane }
    }

    /// A divider moved: the fractions of the split at `path` (child
    /// indices from the root), normalized, each at least minimumFraction.
    /// Fractions that do not fit that split are ignored.
    mutating func setFractions(_ fractions: [Double], ofSplitAt path: [Int]) {
        if let changed = Self.setting(fractions, at: path[...], in: root) { root = changed }
    }

    // MARK: Layout

    /// The fractions of the split at `path` (child indices from the root);
    /// nil when no split is there.
    func fractions(ofSplitAt path: [Int]) -> [Double]? {
        var node = root
        for i in path {
            guard case .split(let s) = node, s.children.indices.contains(i) else { return nil }
            node = s.children[i]
        }
        guard case .split(let s) = node else { return nil }
        return s.fractions
    }

    /// Each pane's frame in `rect`, y growing downwards (a flipped view).
    func frames(in rect: CGRect) -> [PaneID: CGRect] {
        var frames: [PaneID: CGRect] = [:]
        Self.layout(root, in: rect, into: &frames)
        return frames
    }

    private static func layout(_ node: Node, in rect: CGRect, into frames: inout [PaneID: CGRect]) {
        switch node {
        case .pane(let id):
            frames[id] = rect
        case .split(let s):
            var offset: CGFloat = 0
            for (child, fraction) in zip(s.children, s.fractions) {
                let r: CGRect
                switch s.axis {
                case .horizontal:
                    r = CGRect(x: rect.minX + offset, y: rect.minY, width: rect.width * fraction, height: rect.height)
                    offset += r.width
                case .vertical:
                    r = CGRect(x: rect.minX, y: rect.minY + offset, width: rect.width, height: rect.height * fraction)
                    offset += r.height
                }
                layout(child, in: r, into: &frames)
            }
        }
    }

    // MARK: Tree surgery

    private static func panes(in node: Node) -> [PaneID] {
        switch node {
        case .pane(let id): return [id]
        case .split(let s): return s.children.flatMap(panes(in:))
        }
    }

    /// `new` beside `target`: a sibling sharing `target`'s room in the split
    /// around it when that split runs along `axis`, else a new split of
    /// the two in `target`'s place.
    private static func inserting(_ new: PaneID, beside target: PaneID, axis: Axis, before: Bool, in node: Node) -> Node {
        switch node {
        case .pane(let id):
            guard id == target else { return node }
            return .split(Split(axis: axis, children: before ? [.pane(new), node] : [node, .pane(new)], fractions: [0.5, 0.5]))
        case .split(var s):
            if s.axis == axis, let i = s.children.firstIndex(of: .pane(target)) {
                let half = s.fractions[i] / 2
                s.fractions[i] = half
                let at = before ? i : i + 1
                s.children.insert(.pane(new), at: at)
                s.fractions.insert(half, at: at)
                return .split(s)
            }
            s.children = s.children.map { inserting(new, beside: target, axis: axis, before: before, in: $0) }
            return .split(s)
        }
    }

    /// `node` without `pane`, its room shared by its siblings; a split left
    /// with one child becomes that child; nil when nothing is left.
    private static func removing(_ pane: PaneID, from node: Node) -> Node? {
        switch node {
        case .pane(let id):
            return id == pane ? nil : node
        case .split(let s):
            var children: [Node] = []
            var fractions: [Double] = []
            for (child, fraction) in zip(s.children, s.fractions) {
                guard let kept = removing(pane, from: child) else { continue }
                children.append(kept)
                fractions.append(fraction)
            }
            if children.count <= 1 { return children.first }
            return .split(Split(axis: s.axis, children: children, fractions: normalized(fractions)))
        }
    }

    /// Splits inside a split running the same way merge into it.
    private static func flattened(_ node: Node) -> Node {
        guard case .split(let s) = node else { return node }
        var children: [Node] = []
        var fractions: [Double] = []
        for (child, fraction) in zip(s.children.map(flattened), s.fractions) {
            if case .split(let inner) = child, inner.axis == s.axis {
                children += inner.children
                fractions += inner.fractions.map { $0 * fraction }
            } else {
                children.append(child)
                fractions.append(fraction)
            }
        }
        return .split(Split(axis: s.axis, children: children, fractions: fractions))
    }

    private static func setting(_ fractions: [Double], at path: ArraySlice<Int>, in node: Node) -> Node? {
        guard case .split(var s) = node else { return nil }
        if let i = path.first {
            guard s.children.indices.contains(i), let child = setting(fractions, at: path.dropFirst(), in: s.children[i]) else {
                return nil
            }
            s.children[i] = child
            return .split(s)
        }
        guard fractions.count == s.children.count, fractions.allSatisfy({ $0.isFinite && $0 >= 0 }),
              fractions.reduce(0, +) > 0 else { return nil }
        let least = min(minimumFraction, 1 / Double(fractions.count))
        s.fractions = normalized(normalized(fractions).map { max($0, least) })
        return .split(s)
    }

    private static func normalized(_ fractions: [Double]) -> [Double] {
        let sum = fractions.reduce(0, +)
        return sum > 0 ? fractions.map { $0 / sum } : fractions.map { _ in 1 / Double(fractions.count) }
    }
}
