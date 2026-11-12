//
//  SavedSession.swift — what Monad keeps of its terminal windows to open
//  them again the next time: each window's place, tabs and groups
//  (TabStrip), each tab's panes (PaneTree), and for each context the VM it
//  was on, the directory its shell last reported (OSC 7) and its theme.
//  Nothing a program printed is kept, and no ephemeral VM: those are
//  discarded when Monad quits. Kept in ~/.monad/session.json (0600,
//  SessionStore). The file is read as untrusted: the directories in it
//  came from guests, so what does not fit is left out, and a directory is
//  only ever used quoted, on the VM that reported it.
//

import Foundation

struct SavedSession: Codable, Equatable {
    static let currentVersion = 1
    static let maxWindows = 16
    static let maxTabs = 64
    /// Contexts in one tab.
    static let maxContexts = 64

    enum Kind: String, Codable {
        case vm
        /// A host shell.
        case host
        /// The default VM, when the tab had not found which one yet.
        case defaultVM = "default"
    }

    struct Context: Codable, Equatable {
        var kind: Kind
        var vm: String?
        var directory: String?
        var theme: String?

        /// The context as it may be opened, or nil when it may not.
        var sanitized: Context? {
            var c = self
            switch kind {
            case .vm:
                guard let vm, vm.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil else { return nil }
            case .host, .defaultVM:
                c.vm = nil
            }
            if let d = directory, !Self.isDirectory(d) { c.directory = nil }
            if let t = theme, t.isEmpty || t.count > 128 || Self.hasControl(t) { c.theme = nil }
            return c
        }

        /// An absolute path of printable characters, as OSC 7 is taken.
        static func isDirectory(_ path: String) -> Bool {
            path.hasPrefix("/") && path.utf8.count <= 4096 && !hasControl(path)
        }

        private static func hasControl(_ s: String) -> Bool {
            s.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
    }

    /// A tab's panes: the tree, and each pane's contexts (by the pane's id)
    /// with the one that shows.
    struct Panes: Codable, Equatable {
        var tree: PaneTree
        var contexts: [String: [Context]]
        var visible: [String: Int]

        init(tree: PaneTree, contexts: [String: [Context]], visible: [String: Int]) {
            self.tree = tree
            self.contexts = contexts
            self.visible = visible
        }

        /// A tab's panes as they are, without the contexts `context` gives
        /// nil for (they cannot come back); a pane left with none closes.
        /// nil when nothing is left.
        init?(layout: PaneLayout, context: (ContextID) -> Context?) {
            var layout = layout
            var kept: [ContextID: Context] = [:]
            for id in layout.allContexts {
                if let c = context(id) {
                    kept[id] = c
                } else if layout.closeContext(id) == .window {
                    return nil
                }
            }
            tree = layout.tree
            contexts = [:]
            visible = [:]
            for pane in layout.tree.panes {
                let ids = layout.contexts(in: pane)
                contexts[pane.value] = ids.compactMap { kept[$0] }
                visible[pane.value] = layout.visible(in: pane).flatMap(ids.firstIndex(of:)) ?? 0
            }
        }

        /// The panes to open: a layout of new contexts, and what each one
        /// opens. nil when the parts do not fit together.
        func restored() -> (layout: PaneLayout, contexts: [ContextID: Context])? {
            guard tree.isSound else { return nil }
            var ids: [PaneID: [ContextID]] = [:]
            var shown: [PaneID: ContextID] = [:]
            var opened: [ContextID: Context] = [:]
            for pane in tree.panes {
                let list = (contexts[pane.value] ?? []).compactMap(\.sanitized)
                guard !list.isEmpty else { return nil }
                let made = list.map { _ in ContextID.make() }
                for (id, c) in zip(made, list) { opened[id] = c }
                ids[pane] = made
                shown[pane] = made[min(max(visible[pane.value] ?? 0, 0), made.count - 1)]
            }
            guard opened.count <= SavedSession.maxContexts,
                  let layout = PaneLayout(tree: tree, contexts: ids, visible: shown) else { return nil }
            return (layout, opened)
        }

        /// Only what `restored` would open, or nil.
        var sanitized: Panes? {
            guard tree.isSound else { return nil }
            var out = Panes(tree: tree, contexts: [:], visible: [:])
            var count = 0
            for pane in tree.panes {
                let list = (contexts[pane.value] ?? []).compactMap(\.sanitized)
                guard !list.isEmpty else { return nil }
                count += list.count
                out.contexts[pane.value] = list
                out.visible[pane.value] = min(max(visible[pane.value] ?? 0, 0), list.count - 1)
            }
            return count <= SavedSession.maxContexts ? out : nil
        }
    }

    struct Tab: Codable, Equatable {
        /// Its group's id, when it is in one.
        var group: String?
        var panes: Panes
    }

    struct Window: Codable, Equatable {
        /// x, y, width, height on the screen.
        var frame: [Double]?
        var tabs: [Tab]
        var groups: [TabGroup]
        /// The tab in front, by its place.
        var selected: Int

        var sanitized: Window? {
            var kept: [Tab] = []
            var front = 0
            for (i, tab) in tabs.enumerated() where kept.count < SavedSession.maxTabs {
                guard var t = tab.panes.sanitized.map({ Tab(group: tab.group, panes: $0) }) else { continue }
                if let g = t.group, g.isEmpty || g.count > 64 { t.group = nil }
                if i <= selected { front = kept.count }
                kept.append(t)
            }
            guard !kept.isEmpty else { return nil }
            var f = frame
            if let v = f, v.count != 4 || !v.allSatisfy(\.isFinite) || !(100...20_000).contains(v[2])
                || !(60...20_000).contains(v[3]) || abs(v[0]) > 100_000 || abs(v[1]) > 100_000 { f = nil }
            return Window(frame: f, tabs: kept, groups: Array(groups.prefix(SavedSession.maxTabs)), selected: front)
        }

        /// The window's strip, a tab id for each of `tabs` in order.
        func strip(ids: [TabID]) -> TabStrip? {
            let list = zip(ids, tabs).map { TabStrip.Tab(id: $0, group: $1.group.map(TabGroupID.init)) }
            return TabStrip(tabs: list, groups: groups, selected: ids.indices.contains(selected) ? ids[selected] : nil)
        }
    }

    var version = SavedSession.currentVersion
    var windows: [Window]

    init(windows: [Window]) { self.windows = windows }

    /// What to do with the saved session, given the open windows as they
    /// would be saved (nil: a window with nothing that can open again).
    enum Keeping: Equatable {
        /// No terminal window is open: what was saved stays, so the tabs of
        /// the last window closed open again.
        case asItIs
        /// Windows are open, none with anything to open again.
        case nothing
        case session(SavedSession)
    }

    static func keeping(_ windows: [Window?]) -> Keeping {
        if windows.isEmpty { return .asItIs }
        let kept = windows.compactMap { $0 }
        return kept.isEmpty ? .nothing : .session(SavedSession(windows: kept))
    }

    /// Only what may be opened.
    var sanitized: SavedSession {
        var s = self
        s.windows = Array(windows.compactMap(\.sanitized).prefix(Self.maxWindows))
        return s
    }
}

/// ~/.monad/session.json, the user's only.
struct SessionStore {
    let url: URL

    init(url: URL = Paths.root.appendingPathComponent("session.json")) {
        self.url = url
    }

    /// The session to open, or nil: no file, one that cannot be read, a
    /// later Monad's, or one with no window left in it.
    func load() -> SavedSession? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size < 4 << 20,
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(SavedSession.self, from: data),
              file.version == SavedSession.currentVersion else { return nil }
        let session = file.sanitized
        return session.windows.isEmpty ? nil : session
    }

    func save(_ session: SavedSession) throws {
        try Paths.ensurePrivateDirectory(url.deletingLastPathComponent())
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try enc.encode(session).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
