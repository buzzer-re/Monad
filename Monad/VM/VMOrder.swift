//
//  VMOrder.swift — the order of the VMs, set by dragging the Virtual
//  Machines list. The default VM (the first tab when Monad opens, and what
//  ⌘T opens with no tab in front) is chosen with Make Default; until one
//  is chosen it is the top one. MonadHost keeps both in
//  instances/order.json and tells every app when they change. Ephemeral
//  VMs are never in it.
//

import Foundation

enum VMOrder {
    /// The most VMs an order holds (far more than a Mac runs).
    static let maxVMs = 256

    /// `names` in the user's order: those in `saved` first as saved, then
    /// the others by name with "default" first (the default VM before
    /// there was an order), then the ephemeral ones by name.
    static func arrange(_ names: [String], ephemeral: Set<String>, saved: [String]) -> [String] {
        let present = Set(names)
        var seen = Set<String>()
        var out: [String] = []
        for n in saved where present.contains(n) && !ephemeral.contains(n) && seen.insert(n).inserted {
            out.append(n)
        }
        func rank(_ n: String) -> Int { n == VMManager.defaultName ? 0 : 1 }
        let rest = names.filter { !seen.contains($0) && !ephemeral.contains($0) }.sorted { (rank($0), $0) < (rank($1), $1) }
        return out + rest + names.filter { ephemeral.contains($0) }.sorted()
    }

    /// `current` with the names in `requested` first (each once, only
    /// those in `current`), the others after them as they were.
    static func reordered(_ current: [String], requested: [String]) -> [String] {
        let known = Set(current)
        var first: [String] = []
        for n in requested where known.contains(n) && !first.contains(n) { first.append(n) }
        return first + current.filter { !first.contains($0) }
    }

    /// A row dragged by its handle and dropped on `target` takes its place:
    /// below it when coming from above, above it when coming from below.
    static func dropping(_ names: [String], _ name: String, onto target: String) -> [String] {
        guard name != target, let from = names.firstIndex(of: name), let to = names.firstIndex(of: target) else {
            return names
        }
        return step(names, name, by: to - from)
    }

    enum Edge { case above, below }

    /// Where the drop line shows on the row under the pointer, or nil when
    /// the drop would change nothing.
    static func dropEdge(_ names: [String], dragging name: String?, over target: String) -> Edge? {
        guard let name, name != target, let from = names.firstIndex(of: name),
              let to = names.firstIndex(of: target) else { return nil }
        return from < to ? .below : .above
    }

    /// Move Up or Move Down: `name` `delta` places, never past either end.
    static func step(_ names: [String], _ name: String, by delta: Int) -> [String] {
        guard let i = names.firstIndex(of: name) else { return names }
        let j = min(max(i + delta, 0), names.count - 1)
        guard j != i else { return names }
        var out = names
        out.remove(at: i)
        out.insert(name, at: j)
        return out
    }

    /// A drag in a list: the rows at `offsets` moved before the row at
    /// `destination` (SwiftUI's onMove). Out of range: nothing moves.
    static func moving(_ names: [String], from offsets: IndexSet, to destination: Int) -> [String] {
        guard !offsets.isEmpty, offsets.allSatisfy(names.indices.contains), (0...names.count).contains(destination) else {
            return names
        }
        let kept = names.indices.filter { !offsets.contains($0) }
        return kept.filter { $0 < destination }.map { names[$0] } + offsets.map { names[$0] }
            + kept.filter { $0 >= destination }.map { names[$0] }
    }
}

/// instances/order.json, the user's only. Read with care: it is a file
/// anyone running as the user could change.
struct VMOrderStore {
    static let version = 1

    private struct File: Codable {
        var version: Int
        var order: [String]
        /// The chosen default VM (absent before one was chosen).
        var defaultVM: String?
    }

    let url: URL

    /// The saved order: VM names only, each once, at most VMOrder.maxVMs;
    /// empty without a file or with one this Monad cannot read.
    func load() -> [String] {
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20,
              let file = try? JSONDecoder().decode(File.self, from: data), file.version == Self.version else { return [] }
        var seen = Set<String>()
        return Array(file.order.filter { InstanceConfig.isValidName($0) && seen.insert($0).inserted }.prefix(VMOrder.maxVMs))
    }

    /// The chosen default VM, if one was chosen and its name is a VM name.
    func loadDefault() -> String? {
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20,
              let file = try? JSONDecoder().decode(File.self, from: data), file.version == Self.version,
              let name = file.defaultVM, InstanceConfig.isValidName(name) else { return nil }
        return name
    }

    func save(_ order: [String], defaultVM: String? = nil) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(File(version: Self.version, order: Array(order.prefix(VMOrder.maxVMs)), defaultVM: defaultVM))
        try Paths.ensurePrivateDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
