//
//  Snapshots.swift — a VM's snapshots, like VMware's: each the VM's disks
//  (APFS clones: no room until they differ), its added disks, its firmware
//  store and its settings as they were, and, for a VM that was running, its
//  memory (Virtualization's saved state), so a restore brings it back
//  running where it was. Kept in the VM's folder, snapshots/<id>/; each
//  remembers the one before it (the VM's current snapshot when it was
//  taken), so they form a tree. VMInstance takes, restores and deletes them.
//

import Foundation

struct Snapshot: Codable, Equatable, Identifiable, Sendable {
    /// 8 lowercase hex digits: a folder name, never the user's text.
    var id: String
    var name: String
    var createdAt: Date
    /// The snapshot the VM was at when this one was taken.
    var parent: String?
    /// Its memory was saved: a restore resumes it running.
    var memory: Bool
    /// The VM's settings when it was taken.
    var config: InstanceConfig

    static let maxNameLength = 64
    /// Snapshots a VM may keep.
    static let maxCount = 64

    static func isValidName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && name.count <= maxNameLength && name.plain() == name
    }

    static func isValidID(_ id: String) -> Bool {
        id.range(of: "^[0-9a-f]{8}$", options: .regularExpression) != nil
    }

    static func newID() -> String { String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(8)) }
}

/// A VM's snapshots on disk.
struct SnapshotStore {
    let paths: InstancePaths

    /// Every snapshot that reads back, oldest first.
    func list() -> [Snapshot] {
        let fm = FileManager.default
        let ids = (try? fm.contentsOfDirectory(atPath: paths.snapshots.path)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ids.filter(Snapshot.isValidID).compactMap { id in
            guard let data = try? Data(contentsOf: paths.snapshotInfo(id)),
                  let snap = try? decoder.decode(Snapshot.self, from: data), snap.id == id else { return nil }
            return snap
        }
        .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    func save(_ snap: Snapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snap).write(to: paths.snapshotInfo(snap.id), options: .atomic)
    }

    /// The snapshot the VM is at (the last taken or restored).
    var current: String? {
        get {
            let id = (try? String(contentsOf: paths.currentSnapshot, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return id.flatMap { Snapshot.isValidID($0) ? $0 : nil }
        }
        nonmutating set {
            if let newValue {
                try? Data(newValue.utf8).write(to: paths.currentSnapshot, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: paths.currentSnapshot)
            }
        }
    }
}
