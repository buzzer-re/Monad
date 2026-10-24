//
//  DistroStore.swift — Settings › Distributions: the distros the user added
//  (~/.monad/distros), checked before they are kept, kept under their id,
//  removed only while no VM uses them. Monad's own cannot be removed.
//

import Combine
import Foundation

@MainActor
final class DistroStore: ObservableObject {
    /// What a file would add, shown before it is kept.
    struct Preview {
        let distro: DistroConfig
        /// The host its checksums (and so its images) come from.
        let checksums: String
        /// How its images are checked.
        let verification: String
        /// It replaces a distro added before under the same id.
        let replaces: Bool
    }

    @Published private(set) var catalog: DistroCatalog
    private let directory: URL
    private let bundled: DistroCatalog

    init(directory: URL = Paths.distros, bundled: DistroCatalog) {
        self.directory = directory
        self.bundled = bundled
        catalog = bundled.adding(userDirectory: directory)
    }

    func reload() { catalog = bundled.adding(userDirectory: directory) }

    /// A file's distro, checked as `add` would: valid, not one of Monad's
    /// own, its pinned keys in the file.
    func check(_ data: Data) throws -> Preview {
        let d = try DistroCatalog.checkUserFile(data)
        guard bundled.distro(d.id) == nil else {
            throw DistroConfig.Invalid("\(d.id) is one of Monad's own distributions: give yours another id")
        }
        let verification: String
        if d.isSigned {
            verification = "OpenPGP signature by " + (d.image.signature.fingerprints ?? []).joined(separator: ", ")
        } else if d.image.checksums == nil {
            verification = "nothing, the image is used as it is"
        } else {
            verification = "checksums over HTTPS only, no signature" + (d.image.signature.note.map { " (\($0))" } ?? "")
        }
        let host: String
        if d.guestOS == .macos {
            let u = URL(string: d.image.url)
            host = d.image.url == DistroConfig.appleLatest ? "Apple" : u?.isFileURL == true ? "this Mac" : u?.host ?? d.image.url
        } else {
            let plan = try d.plan(release: d.defaultRelease.id, hostArch: d.architectures.keys.contains(ImagePipeline.hostArchitecture)
                ? ImagePipeline.hostArchitecture : "arm64")
            switch plan.checksums {
            case .url(let u), .index(let u, _): host = u.host ?? u.absoluteString
            case .direct(let u): host = u.isFileURL ? "this Mac" : u.host ?? u.absoluteString
            }
        }
        return Preview(distro: d, checksums: host, verification: verification,
                       replaces: catalog.added[d.id] != nil)
    }

    /// Keep a checked file as <id>.distro.json.
    func add(_ data: Data) throws {
        let preview = try check(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: directory.appendingPathComponent("\(preview.distro.id).distro.json"), options: .atomic)
        reload()
    }

    /// Remove an added distro; not while VMs (`usedBy`) are made from it.
    func remove(_ id: String, usedBy: [String]) throws {
        guard let file = catalog.added[id] else {
            throw DistroConfig.Invalid("\(id) is one of Monad's own distributions")
        }
        guard usedBy.isEmpty else {
            throw DistroConfig.Invalid("\(id) is used by \(usedBy.joined(separator: ", ")): remove "
                + (usedBy.count == 1 ? "that VM" : "those VMs") + " first")
        }
        try FileManager.default.removeItem(at: file)
        reload()
    }
}
