//
//  ProfileEditorModel.swift — the editor behind Settings › Profiles: the
//  built-in profiles and the user's own, one edited at a time as a draft,
//  saved only when valid. An edited built-in is saved under its id (used
//  instead of the shipped one) until restored. Names lists (packages, npm
//  packages, commands) are typed as space-separated text and kept as typed
//  until the profile is saved.
//

import Combine
import Foundation

@MainActor
final class ProfileEditorModel: ObservableObject {
    /// What a new step does.
    enum NewStep { case packages, node, npm, script }

    let store: ProfileStore
    /// The built-ins as shipped.
    private let builtIn: [ProfileConfig]
    /// The user's own profiles (not edited built-ins).
    @Published private(set) var ids: [String] = []
    /// Built-ins the user saved a version of.
    @Published private(set) var editedBuiltIns: Set<String> = []
    @Published var draft: ProfileConfig?
    /// Per step: the typed text of its lists ("apt", "dnf", "zypper", "npm", "commands").
    @Published private(set) var texts: [[String: String]] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var saved: ProfileConfig?

    /// `startingNew`: on a new profile (the New VM sheet's "Create New
    /// Profile"), else on the user's first.
    init(store: ProfileStore = ProfileStore(), builtIn: [ProfileConfig], startingNew: Bool = false) {
        self.store = store
        self.builtIn = builtIn
        reload()
        if startingNew {
            addProfile()
        } else if let first = ids.first {
            select(first)
        }
    }

    var builtInIDs: [String] { builtIn.map(\.id) }
    private var builtInSet: Set<String> { Set(builtInIDs) }

    /// The draft is a built-in (as shipped or as edited).
    var isBuiltIn: Bool { draft.map { builtInSet.contains($0.id) } ?? false && saved != nil }
    var isEdited: Bool { isBuiltIn && editedBuiltIns.contains(draft?.id ?? "") }
    /// Built-ins are restored, not deleted.
    var canDelete: Bool { saved != nil && !isBuiltIn }

    var isDirty: Bool {
        guard let saved else { return draft != nil }
        return draft != saved || texts != Self.texts(of: saved)
    }

    /// VMs refer to profiles by id: fixed once saved.
    var canChangeID: Bool { saved == nil && draft != nil }

    func select(_ id: String) {
        saved = (try? store.all().first { $0.id == id }) ?? builtIn.first { $0.id == id }
        draft = saved
        texts = saved.map(Self.texts) ?? []
        errorMessage = nil
    }

    /// Back to the shipped version of the built-in being edited.
    func restoreDefault() {
        guard isBuiltIn, let id = draft?.id else { return }
        try? store.delete(id: id)
        reload()
        select(id)
    }

    func revert() {
        if let id = saved?.id ?? ids.first {
            select(id)
        } else {
            saved = nil
            draft = nil
            texts = []
        }
    }

    func addProfile() {
        var n = 1
        while ids.contains("profile-\(n)") || builtInSet.contains("profile-\(n)") { n += 1 }
        saved = nil
        draft = ProfileConfig(id: "profile-\(n)", name: "New Profile", summary: "", steps: [])
        texts = []
        errorMessage = nil
    }

    // MARK: Steps

    func addStep(_ kind: NewStep) {
        guard var d = draft else { return }
        var n = d.steps.count + 1
        while d.steps.contains(where: { $0.id == "step-\(n)" }) { n += 1 }
        let id = "step-\(n)"
        switch kind {
        case .packages: d.steps.append(.init(id: id, title: "Packages", packages: [:]))
        case .node: d.steps.append(.init(id: id, title: "Node.js LTS", runtime: "nodejs"))
        case .npm: d.steps.append(.init(id: id, title: "npm packages", npm: []))
        case .script: d.steps.append(.init(id: id, title: "Script", script: ""))
        }
        draft = d
        texts.append([:])
    }

    func removeStep(_ i: Int) {
        guard let d = draft, d.steps.indices.contains(i) else { return }
        draft?.steps.remove(at: i)
        texts.remove(at: i)
    }

    func moveStep(_ i: Int, up: Bool) {
        guard let d = draft, d.steps.indices.contains(i) else { return }
        let j = up ? i - 1 : i + 1
        guard d.steps.indices.contains(j) else { return }
        draft?.steps.swapAt(i, j)
        texts.swapAt(i, j)
    }

    /// Changes step `i` (title, script); nothing if there is none.
    func updateStep(_ i: Int, _ change: (inout ProfileConfig.Step) -> Void) {
        guard var d = draft, d.steps.indices.contains(i) else { return }
        change(&d.steps[i])
        draft = d
    }

    func step(_ i: Int) -> ProfileConfig.Step? {
        guard let d = draft, d.steps.indices.contains(i) else { return nil }
        return d.steps[i]
    }

    func packagesText(_ i: Int, manager: String) -> String { text(i, manager) }
    func npmText(_ i: Int) -> String { text(i, "npm") }
    func commandsText(_ i: Int) -> String { text(i, "commands") }

    func setPackages(_ i: Int, manager: String, _ s: String) { setText(i, manager, s) }
    func setNPM(_ i: Int, _ s: String) { setText(i, "npm", s) }
    func setCommands(_ i: Int, _ s: String) { setText(i, "commands", s) }

    private func text(_ i: Int, _ key: String) -> String {
        texts.indices.contains(i) ? texts[i][key] ?? "" : ""
    }

    private func setText(_ i: Int, _ key: String, _ s: String) {
        guard texts.indices.contains(i) else { return }
        texts[i][key] = s
    }

    // MARK: Saving

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "," }).map(String.init)
    }

    private static func texts(of p: ProfileConfig) -> [[String: String]] {
        p.steps.map { step in
            var t: [String: String] = [:]
            for (m, names) in step.packages ?? [:] { t[m] = names.joined(separator: " ") }
            if let npm = step.npm { t["npm"] = npm.joined(separator: " ") }
            if let c = step.commands { t["commands"] = c.joined(separator: " ") }
            return t
        }
    }

    /// The draft with its typed lists in place.
    private func built() -> ProfileConfig? {
        guard var d = draft else { return nil }
        for i in d.steps.indices {
            let t = texts.indices.contains(i) ? texts[i] : [:]
            if d.steps[i].packages != nil {
                var byManager: [String: [String]] = [:]
                for m in ProfileConfig.packageManagers {
                    let w = Self.words(t[m] ?? "")
                    if !w.isEmpty { byManager[m] = w }
                }
                d.steps[i].packages = byManager
            }
            if d.steps[i].npm != nil { d.steps[i].npm = Self.words(t["npm"] ?? "") }
            let commands = Self.words(t["commands"] ?? "")
            d.steps[i].commands = commands.isEmpty ? nil : commands
        }
        return d
    }

    @discardableResult
    func save() -> Bool {
        guard let p = built() else { return false }
        if saved == nil, builtInSet.contains(p.id) {
            errorMessage = "“\(p.id)” is a built-in profile. Choose another id."
            return false
        }
        if saved == nil, ids.contains(p.id) {
            errorMessage = "A profile with the id “\(p.id)” already exists."
            return false
        }
        do {
            try store.save(p)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        reload()
        select(p.id)
        return true
    }

    @discardableResult
    func delete() -> Bool {
        guard canDelete, let id = saved?.id else { return false }
        do {
            try store.delete(id: id)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        saved = nil
        reload()
        revert()
        return true
    }

    private func reload() {
        let all = (try? store.all().map(\.id)) ?? []
        ids = all.filter { !builtInSet.contains($0) }
        editedBuiltIns = Set(all.filter { builtInSet.contains($0) })
    }
}
