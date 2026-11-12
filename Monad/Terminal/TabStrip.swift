//
//  TabStrip.swift — a terminal window's tabs and their groups, as Firefox
//  has them. A group is a named, coloured run of tabs that stay together,
//  shown after its label; collapsed, it shows only its label, and the tab
//  in front when that is one of its own (so the window never shows a tab
//  the strip does not). A new tab goes last, in no group, unless it is
//  asked for in one. Tabs and groups move by drag and drop. Pure: the
//  strip's view (TabStripView) is drawn from it, and a window's saved
//  session (SavedSession) is made of it.
//

import Foundation

/// One tab of a terminal window.
struct TabID: Hashable, Codable, CustomStringConvertible {
    let value: String
    init(_ value: String) { self.value = value }
    static func make() -> TabID { TabID(UUID().uuidString) }
    var description: String { value }
}

struct TabGroupID: Hashable, Codable, CustomStringConvertible {
    let value: String
    init(_ value: String) { self.value = value }
    static func make() -> TabGroupID { TabGroupID(UUID().uuidString) }
    var description: String { value }
}

/// A group's colour, by name (TabStripView has the colours themselves).
enum TabGroupColor: String, Codable, CaseIterable {
    case blue, purple, cyan, orange, yellow, pink, green, gray, red
}

struct TabGroup: Equatable, Codable {
    static let maxNameLength = 40

    var id: TabGroupID
    var name: String
    var color: TabGroupColor
    var collapsed = false

    /// A name as it is kept: one line of printable text, trimmed, at most
    /// maxNameLength characters. It may be empty (a label with no words).
    static func cleanName(_ name: String) -> String {
        let printable = String(String.UnicodeScalarView(name.unicodeScalars.filter {
            $0.properties.generalCategory != .control
        }))
        return String(printable.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
    }
}

struct TabStrip: Equatable {
    struct Tab: Equatable {
        var id: TabID
        var group: TabGroupID?
    }

    /// What the strip shows, left to right.
    enum Item: Equatable {
        case group(TabGroupID)
        case tab(TabID)
    }

    /// Where a dragged tab or group is let go.
    enum Drop: Equatable {
        case before(Item)
        case after(Item)
        case end
    }

    /// The tabs in order; a group's tabs are next to each other.
    private(set) var tabs: [Tab]
    /// The groups, each with at least one tab.
    private(set) var groups: [TabGroup]
    /// The tab in front.
    private(set) var selected: TabID

    init(tab: TabID) {
        tabs = [Tab(id: tab)]
        groups = []
        selected = tab
    }

    /// A saved strip, put right where it makes no sense: each tab once, a
    /// group's tabs together where its first one is, one group per id and
    /// none without tabs, a tab in front that exists. nil without tabs.
    init?(tabs saved: [Tab], groups savedGroups: [TabGroup], selected front: TabID?) {
        var known: [TabGroup] = []
        for var g in savedGroups where !known.contains(where: { $0.id == g.id }) {
            g.name = TabGroup.cleanName(g.name)
            known.append(g)
        }
        var seen = Set<TabID>()
        var list: [Tab] = []
        for var t in saved where seen.insert(t.id).inserted {
            if let g = t.group, !known.contains(where: { $0.id == g }) { t.group = nil }
            list.append(t)
        }
        guard let first = list.first else { return nil }
        tabs = list
        groups = known
        selected = front.flatMap { f in list.contains { $0.id == f } ? f : nil } ?? first.id
        normalize()
    }

    // MARK: Reading

    func contains(_ tab: TabID) -> Bool { tabs.contains { $0.id == tab } }

    func group(_ id: TabGroupID) -> TabGroup? { groups.first { $0.id == id } }

    func group(of tab: TabID) -> TabGroup? {
        tabs.first { $0.id == tab }?.group.flatMap(group)
    }

    func tabs(in group: TabGroupID) -> [TabID] { tabs.filter { $0.group == group }.map(\.id) }

    /// Whether a tab shows in the strip: not in a collapsed group, or in front.
    private func inSight(_ tab: Tab) -> Bool {
        tab.id == selected || tab.group.flatMap(group)?.collapsed != true
    }

    var visibleTabs: [TabID] { tabs.filter(inSight).map(\.id) }

    /// How many of a group's tabs its collapsed label stands for.
    func hiddenCount(in group: TabGroupID) -> Int {
        tabs.filter { $0.group == group && !inSight($0) }.count
    }

    var items: [Item] {
        var out: [Item] = []
        var last: TabGroupID?
        for t in tabs {
            if let g = t.group, g != last { out.append(.group(g)) }
            last = t.group
            if inSight(t) { out.append(.tab(t.id)) }
        }
        return out
    }

    /// The colour a new group takes: the first no group has, else the
    /// least used.
    var nextColor: TabGroupColor {
        let all = TabGroupColor.allCases
        func uses(_ c: TabGroupColor) -> Int { groups.filter { $0.color == c }.count }
        return all.min { uses($0) < uses($1) } ?? .blue
    }

    // MARK: Tabs

    /// A new tab, in front: last, or at the end of `group`.
    mutating func add(_ tab: TabID, to group: TabGroupID? = nil) {
        guard !contains(tab) else { return }
        if let group, let end = tabs.lastIndex(where: { $0.group == group }) {
            tabs.insert(Tab(id: tab, group: group), at: end + 1)
        } else {
            tabs.append(Tab(id: tab))
        }
        selected = tab
    }

    /// Removes a tab; false (and nothing changes) for the last one, which
    /// closes its window instead, or a tab not here. When it was in front,
    /// the next tab in sight is (else the one before; else its neighbour,
    /// which then shows).
    mutating func close(_ tab: TabID) -> Bool {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == tab }) else { return false }
        if selected == tab {
            let after = tabs[(i + 1)...], before = tabs[..<i].reversed()
            let next = after.first(where: inSight) ?? before.first(where: inSight) ?? after.first ?? before.first
            if let next { selected = next.id }
        }
        tabs.remove(at: i)
        normalize()
        return true
    }

    mutating func select(_ tab: TabID) {
        if contains(tab) { selected = tab }
    }

    /// The next (1) or previous (-1) tab in sight, round the strip.
    mutating func selectVisible(by step: Int) {
        let visible = visibleTabs
        guard visible.count > 1, let i = visible.firstIndex(of: selected) else { return }
        selected = visible[((i + step) % visible.count + visible.count) % visible.count]
    }

    // MARK: Groups

    /// A group of `members`, where the first of them is.
    mutating func newGroup(_ id: TabGroupID, name: String, color: TabGroupColor? = nil, tabs members: [TabID]) {
        guard group(id) == nil, members.contains(where: contains) else { return }
        groups.append(TabGroup(id: id, name: TabGroup.cleanName(name), color: color ?? nextColor))
        for i in tabs.indices where members.contains(tabs[i].id) { tabs[i].group = id }
        normalize()
    }

    /// A tab into a group, at its end; out of its group (nil), right after it.
    mutating func move(_ tab: TabID, to group: TabGroupID?) {
        guard let i = tabs.firstIndex(where: { $0.id == tab }), tabs[i].group != group else { return }
        if let group {
            guard self.group(group) != nil else { return }
            var t = tabs.remove(at: i)
            t.group = group
            let end = tabs.lastIndex { $0.group == group } ?? tabs.count - 1
            tabs.insert(t, at: end + 1)
        } else {
            let old = tabs[i].group
            var t = tabs.remove(at: i)
            t.group = nil
            let end = tabs.lastIndex { $0.group == old }.map { $0 + 1 } ?? i
            tabs.insert(t, at: end)
        }
        normalize()
    }

    /// The group goes; its tabs stay where they are.
    mutating func ungroup(_ group: TabGroupID) {
        for i in tabs.indices where tabs[i].group == group { tabs[i].group = nil }
        normalize()
    }

    mutating func rename(_ group: TabGroupID, to name: String) {
        guard let i = groups.firstIndex(where: { $0.id == group }) else { return }
        groups[i].name = TabGroup.cleanName(name)
    }

    mutating func setColor(_ color: TabGroupColor, of group: TabGroupID) {
        guard let i = groups.firstIndex(where: { $0.id == group }) else { return }
        groups[i].color = color
    }

    mutating func toggleCollapsed(_ group: TabGroupID) {
        guard let i = groups.firstIndex(where: { $0.id == group }) else { return }
        groups[i].collapsed.toggle()
    }

    // MARK: Drag and drop

    /// A tab let go on a tab goes beside it, in its group; on a label,
    /// before the group or into it (first). A group moves whole, and never
    /// into another: beside it. Onto itself: nothing.
    mutating func drop(_ item: Item, _ target: Drop) {
        switch item {
        case .tab(let id):
            guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
            var moved = tabs[from]
            if case .before(.tab(id)) = target { return }
            if case .after(.tab(id)) = target { return }
            var rest = tabs
            rest.remove(at: from)
            guard let place = Self.place(target, in: rest, movingGroup: nil) else { return }
            moved.group = place.group
            rest.insert(moved, at: place.index)
            tabs = rest
        case .group(let id):
            let members = tabs.filter { $0.group == id }
            guard !members.isEmpty else { return }
            let rest = tabs.filter { $0.group != id }
            guard let place = Self.place(target, in: rest, movingGroup: id) else { return }
            tabs = Array(rest[..<place.index]) + members + Array(rest[place.index...])
        }
        normalize()
    }

    /// Where `target` is in `rest` (the tabs without what moves), and the
    /// group a tab takes there. A group being moved lands outside others.
    private static func place(_ target: Drop, in rest: [Tab], movingGroup: TabGroupID?) -> (index: Int, group: TabGroupID?)? {
        func span(_ g: TabGroupID) -> (first: Int, last: Int)? {
            guard let first = rest.firstIndex(where: { $0.group == g }),
                  let last = rest.lastIndex(where: { $0.group == g }) else { return nil }
            return (first, last)
        }
        switch target {
        case .end:
            return (rest.count, nil)
        case .before(.tab(let t)), .after(.tab(let t)):
            guard let i = rest.firstIndex(where: { $0.id == t }) else { return nil }
            var before = true
            if case .after = target { before = false }
            if movingGroup != nil, let g = rest[i].group, let s = span(g) {
                return (before ? s.first : s.last + 1, nil)
            }
            return (before ? i : i + 1, movingGroup == nil ? rest[i].group : nil)
        case .before(.group(let g)):
            guard g != movingGroup, let s = span(g) else { return nil }
            return (s.first, nil)
        case .after(.group(let g)):
            guard g != movingGroup, let s = span(g) else { return nil }
            return movingGroup == nil ? (s.first, g) : (s.last + 1, nil)
        }
    }

    // MARK: Order

    /// Groups without tabs go, and each group's tabs gather where its
    /// first one is.
    private mutating func normalize() {
        var out: [Tab] = []
        var placed = Set<TabGroupID>()
        for t in tabs {
            guard let g = t.group else {
                out.append(t)
                continue
            }
            if placed.insert(g).inserted { out += tabs.filter { $0.group == g } }
        }
        tabs = out
        groups.removeAll { !placed.contains($0.id) }
    }
}
