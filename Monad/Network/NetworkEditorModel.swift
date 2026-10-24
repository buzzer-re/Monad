//
//  NetworkEditorModel.swift — the networks editor behind Settings › Networks:
//  one network edited at a time as a draft, saved only when valid.
//

import Combine
import Foundation

@MainActor
final class NetworkEditorModel: ObservableObject {
    let store: NetworkStore
    @Published private(set) var names: [String] = []
    @Published var draft: NetworkDefinition?
    @Published private(set) var errorMessage: String?
    /// The draft as stored; nil for a network not saved yet.
    @Published private(set) var saved: NetworkDefinition?

    /// `startingNew`: on a new network (the New Network sheet), else on
    /// the default one.
    init(store: NetworkStore = NetworkStore(), startingNew: Bool = false) {
        self.store = store
        reload()
        if startingNew {
            addNetwork()
        } else {
            select(NetworkDefinition.defaultName)
        }
    }

    /// The networks again (one was saved elsewhere), showing `name`.
    func reload(selecting name: String) {
        reload()
        select(name)
    }

    var isDirty: Bool {
        guard let saved else { return draft != nil }
        return draft != saved
    }

    /// VMs refer to networks by name: only a new network can be renamed.
    var canRename: Bool { saved == nil }
    var canDelete: Bool { saved != nil && saved?.name != NetworkDefinition.defaultName }

    func select(_ name: String) {
        saved = try? store.network(named: name)
        draft = saved
        errorMessage = nil
    }

    func revert() { select(saved?.name ?? NetworkDefinition.defaultName) }

    /// A new NAT network with a free name and a free 10.x.0.0/24 subnet.
    func addNetwork() {
        let all = (try? store.all()) ?? []
        var n = 1
        while names.contains("network-\(n)") { n += 1 }
        let used = Set(all.map(\.subnet))
        let subnet = (78...254).lazy.map { "10.\($0).0.0/24" }.first { !used.contains($0) } ?? "10.254.0.0/24"
        draft = NetworkDefinition(name: "network-\(n)", kind: .nat, subnet: subnet)
        saved = nil
        errorMessage = nil
    }

    // MARK: Saving

    @discardableResult
    func save() -> Bool {
        guard let d = draft else { return false }
        if saved == nil, names.contains(d.name) {
            errorMessage = "A network named “\(d.name)” already exists."
            return false
        }
        do {
            try store.save(d)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        errorMessage = nil
        reload()
        select(d.name)
        return true
    }

    @discardableResult
    func delete() -> Bool {
        guard canDelete, let name = saved?.name else { return false }
        do {
            try store.delete(named: name)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        reload()
        select(NetworkDefinition.defaultName)
        return true
    }

    private func reload() {
        names = (try? store.all().map(\.name)) ?? []
    }
}
