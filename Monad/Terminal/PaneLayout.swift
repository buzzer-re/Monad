//
//  PaneLayout.swift — a terminal window's panes and their contexts
//  (Phase 11): the PaneTree, and in each pane several contexts (VM
//  sessions that keep running), one visible. Closing a pane's last context
//  closes the pane, closing the last pane the window; a pane dropped on
//  another's edge moves there, on its centre joins it. Keystrokes and
//  pastes go to focusedContext only: the focused pane's visible context.
//

import Foundation

/// One context (a terminal session) of a window.
struct ContextID: Hashable, Codable, CustomStringConvertible {
    let value: String
    init(_ value: String) { self.value = value }
    static func make() -> ContextID { ContextID(UUID().uuidString) }
    var description: String { value }
}

struct PaneLayout: Equatable {
    /// What closing a context closed.
    enum Closing: Equatable { case context, pane(PaneID), window }

    private(set) var tree: PaneTree
    private var contextsByPane: [PaneID: [ContextID]]
    private var visibleByPane: [PaneID: ContextID]

    init(context: ContextID, pane: PaneID) {
        tree = PaneTree(pane: pane)
        contextsByPane = [pane: [context]]
        visibleByPane = [pane: context]
    }

    /// The context that gets keystrokes and pastes.
    var focusedContext: ContextID? { visible(in: tree.focused) }

    func contexts(in pane: PaneID) -> [ContextID] { contextsByPane[pane] ?? [] }

    /// A pane's header (to drag it, with its context menu) shows once the
    /// window has more than one pane or the pane more than one context.
    func showsHeader(_ pane: PaneID) -> Bool {
        tree.panes.count > 1 || contexts(in: pane).count > 1
    }
    func visible(in pane: PaneID) -> ContextID? { visibleByPane[pane] }

    func pane(of context: ContextID) -> PaneID? {
        contextsByPane.first { $0.value.contains(context) }?.key
    }

    /// Every context, pane by pane.
    var allContexts: [ContextID] { tree.panes.flatMap(contexts(in:)) }

    // MARK: Changes

    /// A new context in the focused pane, shown.
    mutating func addContext(_ context: ContextID) {
        guard pane(of: context) == nil else { return }
        contextsByPane[tree.focused, default: []].append(context)
        visibleByPane[tree.focused] = context
    }

    /// Shows a context and focuses its pane.
    mutating func show(_ context: ContextID) {
        guard let pane = pane(of: context) else { return }
        visibleByPane[pane] = context
        tree.focus(pane)
    }

    /// Splits the focused pane: `pane` beside it, holding `context`, focused.
    mutating func split(_ axis: PaneTree.Axis, pane: PaneID, context: ContextID) {
        guard !tree.contains(pane), self.pane(of: context) == nil else { return }
        tree.split(tree.focused, axis, new: pane)
        contextsByPane[pane] = [context]
        visibleByPane[pane] = context
    }

    mutating func focus(_ pane: PaneID) { tree.focus(pane) }
    mutating func focus(_ direction: PaneTree.Direction) { tree.focus(direction) }

    /// The divider of the split at `path` moved.
    mutating func setFractions(_ fractions: [Double], ofSplitAt path: [Int]) {
        tree.setFractions(fractions, ofSplitAt: path)
    }

    /// Closes a context: the one before it shows (else the one after); its
    /// pane closes when it was the last, the window when that was the last
    /// pane (the layout is then left as it was). nil: not in this window.
    mutating func closeContext(_ context: ContextID) -> Closing? {
        guard let pane = pane(of: context), var list = contextsByPane[pane], let i = list.firstIndex(of: context) else {
            return nil
        }
        if list.count == 1 {
            guard tree.close(pane) else { return .window }
            contextsByPane[pane] = nil
            visibleByPane[pane] = nil
            return .pane(pane)
        }
        list.remove(at: i)
        contextsByPane[pane] = list
        if visibleByPane[pane] == context { visibleByPane[pane] = list[max(0, i - 1)] }
        return .context
    }

    /// Closes a pane; its contexts, to be closed. nil for the last pane,
    /// which closes the window instead, or a pane not in this window.
    mutating func closePane(_ pane: PaneID) -> [ContextID]? {
        let closed = contexts(in: pane)
        guard tree.close(pane) else { return nil }
        contextsByPane[pane] = nil
        visibleByPane[pane] = nil
        return closed
    }

    /// A pane dragged onto `target`: to its edge, or with no edge (its
    /// centre) into it, its contexts after the target's, its visible one
    /// shown and focused.
    mutating func drop(_ pane: PaneID, on target: PaneID, edge: PaneTree.Edge?) {
        guard pane != target, tree.contains(pane), tree.contains(target) else { return }
        if let edge {
            tree.move(pane, to: target, edge: edge)
            return
        }
        let moved = contexts(in: pane)
        let shown = visibleByPane[pane]
        guard tree.close(pane) else { return }
        contextsByPane[pane] = nil
        visibleByPane[pane] = nil
        contextsByPane[target, default: []] += moved
        if let shown { visibleByPane[target] = shown }
        tree.focus(target)
    }
}
