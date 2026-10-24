//
//  PaneGeometry.swift — split panes on screen (Phase 11): where a split
//  view's dividers go for the PaneTree's fractions, the fractions a moved
//  divider leaves, and where a pane dragged over another would land.
//

import Foundation

enum PaneGeometry {
    /// The share of a pane, from each side, that drops on that edge.
    static let edgeZone = 0.25

    /// Divider positions in a split view `length` long whose dividers are
    /// `thickness` thick: each after the panes before it and their dividers.
    static func dividerPositions(_ fractions: [Double], length: CGFloat, thickness: CGFloat) -> [CGFloat] {
        guard fractions.count > 1 else { return [] }
        let room = max(0, length - thickness * CGFloat(fractions.count - 1))
        var before = 0.0
        return fractions.dropLast().enumerated().map { i, f in
            before += f
            return CGFloat(before) * room + thickness * CGFloat(i)
        }
    }

    /// Where each pane of that split view sits along it: between the
    /// dividers before and after it.
    static func spans(_ fractions: [Double], length: CGFloat, thickness: CGFloat) -> [Range<CGFloat>] {
        let positions = dividerPositions(fractions, length: length, thickness: thickness)
        return fractions.indices.map { i -> Range<CGFloat> in
            let start = i == 0 ? 0 : positions[i - 1] + thickness
            let end = i < positions.count ? positions[i] : length
            return start..<max(start, end)
        }
    }

    /// The fractions a split's subviews show, from their sizes along its
    /// axis; nil before they have any room.
    static func fractions(_ sizes: [CGFloat]) -> [Double]? {
        let total = sizes.reduce(0, +)
        guard !sizes.isEmpty, total > 0 else { return nil }
        return sizes.map { Double($0 / total) }
    }

    /// Where a pane dropped at `point` lands in a pane of `bounds` (y
    /// growing downwards): the nearest edge within its zone, else the
    /// centre (nil).
    static func dropEdge(at point: CGPoint, in bounds: CGRect) -> PaneTree.Edge? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let distances: [(PaneTree.Edge, CGFloat)] = [
            (.left, (point.x - bounds.minX) / bounds.width),
            (.right, (bounds.maxX - point.x) / bounds.width),
            (.top, (point.y - bounds.minY) / bounds.height),
            (.bottom, (bounds.maxY - point.y) / bounds.height),
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < edgeZone else { return nil }
        return nearest.0
    }
}
