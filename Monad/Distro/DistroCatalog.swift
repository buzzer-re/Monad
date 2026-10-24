//
//  DistroCatalog.swift — the distros Monad knows: every *.distro.json in the
//  app bundle, validated, with their pinned signing keys, and the ones the
//  user added (~/.monad/distros, one self-contained file each, like Lima's
//  templates). A user file that is broken, too large, a link, or reuses a
//  name is left out and says why; Monad's own always stay.
//

import Foundation
import os

struct DistroCatalog: Sendable {
    let distros: [DistroConfig]
    private let keyURL: @Sendable (String) -> URL?
    /// The distros the user added, by id, with their files.
    private(set) var added: [String: URL] = [:]
    /// The user's files that were left out, and why.
    private(set) var problems: [Problem] = []

    struct Problem: Equatable, Sendable {
        let file: String
        let message: String
    }

    static let maxUserFileSize = 256 << 10
    static let maxUserFiles = 64

    /// `userFiles`: distros the user added, validated by their rules.
    init(distros: [DistroConfig], userFiles: Bool = false, keyURL: @escaping @Sendable (String) -> URL?) throws {
        var seen = Set<String>()
        for d in distros {
            try d.validate(userFile: userFiles)
            guard seen.insert(d.id).inserted else { throw DistroConfig.Invalid("Duplicate distro id \(d.id).") }
        }
        guard distros.filter({ $0.preferred == true }).count <= 1 else {
            throw DistroConfig.Invalid("More than one distro is marked preferred.")
        }
        self.distros = distros.sorted { $0.id < $1.id }
        self.keyURL = keyURL
    }

    /// Configurations and keys shipped in `bundle` (MonadHost reads the app's
    /// bundle: it lives in Contents/MacOS).
    static func bundled(_ bundle: Bundle = .main) throws -> DistroCatalog {
        let urls = (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".distro.json") }
        let configs = try urls.map { url -> DistroConfig in
            do {
                return try DistroConfig.decode(Data(contentsOf: url))
            } catch let e as DistroConfig.Invalid {
                throw e
            } catch {
                throw DistroConfig.Invalid("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let root = bundle.resourceURL
        return try DistroCatalog(distros: configs) { name in
            guard ChecksumFile.isSafeFileName(name), let root else { return nil }
            let url = root.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    func distro(_ id: String) -> DistroConfig? { distros.first { $0.id == id } }

    /// No distros (when Monad's own catalog is broken).
    static let empty: DistroCatalog = DistroCatalog(checked: [], keyURL: { _ in nil }, added: [:], problems: [])

    /// This catalog and the distros in `directory` (<id>.distro.json each).
    func adding(userDirectory directory: URL) -> DistroCatalog {
        var result = self
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return result }
        var list = distros
        for name in names.sorted() where name.hasSuffix(".distro.json") {
            do {
                guard result.added.count < Self.maxUserFiles else {
                    throw DistroConfig.Invalid("more than \(Self.maxUserFiles) distributions added: left out")
                }
                let d = try Self.readUserFile(directory.appendingPathComponent(name))
                guard name == "\(d.id).distro.json" else {
                    throw DistroConfig.Invalid("its id is \(d.id): name the file \(d.id).distro.json")
                }
                guard !list.contains(where: { $0.id == d.id }) else {
                    throw DistroConfig.Invalid("\(d.id) is one of Monad's own distributions: give yours another id")
                }
                list.append(d)
                result.added[d.id] = directory.appendingPathComponent(name)
            } catch {
                result.problems.append(Problem(file: name, message: Self.describe(error)))
            }
        }
        result = DistroCatalog(checked: list.sorted { $0.id < $1.id }, keyURL: keyURL, added: result.added,
                               problems: result.problems)
        return result
    }

    /// A user's distro file, read with care: a plain file (a link is not
    /// followed), not too large, valid as a user file.
    static func readUserFile(_ url: URL) throws -> DistroConfig {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else {
            throw DistroConfig.Invalid("not a plain file (a link is not followed)")
        }
        guard ((attrs[.size] as? NSNumber)?.intValue ?? 0) <= maxUserFileSize else {
            throw DistroConfig.Invalid("too large (more than \(maxUserFileSize >> 10) KB)")
        }
        return try checkUserFile(Data(contentsOf: url))
    }

    /// A user's distro, from its file's bytes.
    static func checkUserFile(_ data: Data) throws -> DistroConfig {
        guard data.count <= maxUserFileSize else {
            throw DistroConfig.Invalid("too large (more than \(maxUserFileSize >> 10) KB)")
        }
        let d = try DistroConfig.decode(data)
        try d.validate(userFile: true)
        // Every pinned fingerprint must be a key in the file itself.
        if d.isSigned { _ = try DistroCatalog(distros: [d], userFiles: true) { _ in nil }.trustedKeys(for: d) }
        return d
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? DistroConfig.Invalid { return e.message }
        if let e = error as? DecodingError {
            switch e {
            case .dataCorrupted(let c): return "not valid JSON: \(c.underlyingError?.localizedDescription ?? c.debugDescription)"
            case .keyNotFound(let k, _): return "missing \(k.stringValue)"
            case .typeMismatch(_, let c), .valueNotFound(_, let c):
                return "\(c.codingPath.map(\.stringValue).joined(separator: ".")): \(c.debugDescription)"
            @unknown default: return error.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private init(checked distros: [DistroConfig], keyURL: @escaping @Sendable (String) -> URL?,
                 added: [String: URL], problems: [Problem]) {
        self.distros = distros
        self.keyURL = keyURL
        self.added = added
        self.problems = problems
    }

    /// The preferred distro, else the first by name.
    var defaultDistro: DistroConfig? {
        distros.first { $0.preferred == true }
            ?? distros.min { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The catalog shipped with this Monad (nil, and logged, if it is broken).
    static let shipped: DistroCatalog? = {
        do {
            return try bundled()
        } catch {
            Log.image.fault("distro catalog: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    /// A VM's distribution as people read it: the distro file's name
    /// ("macOS", "Ubuntu"), not its id, with the release.
    func label(distro id: String, release: String?) -> String {
        [distro(id)?.name ?? id.capitalized, release].compactMap { $0 }.joined(separator: " ")
    }

    /// The same for a VM's settings: Monad's own distros by their names, the
    /// user's read only when the VM uses one.
    static func label(_ config: InstanceConfig) -> String {
        let catalog = shipped?.distro(config.distro) != nil ? shipped : live
        return catalog?.label(distro: config.distro, release: config.release)
            ?? [config.distro.capitalized, config.release].compactMap { $0 }.joined(separator: " ")
    }

    /// Monad's distros and the user's, read again each time (a distro added
    /// in Settings is there at once, in the app and in MonadHost).
    static var live: DistroCatalog? { shipped?.adding(userDirectory: Paths.distros) }

    /// The keys allowed to sign `distro`'s checksums: every key in its key
    /// files whose primary is pinned. Every pinned fingerprint must be present.
    func trustedKeys(for distro: DistroConfig) throws -> [OpenPGPKey] {
        let pins = Set(distro.image.signature.fingerprints ?? [])
        var keys: [OpenPGPKey] = []
        for name in distro.image.signature.keys ?? [] {
            guard let url = keyURL(name) else { throw DistroConfig.Invalid("\(distro.id): key file \(name) is missing.") }
            keys += try OpenPGP.keys(from: Data(contentsOf: url)).filter { pins.contains($0.primaryFingerprint) }
        }
        for block in distro.image.signature.publicKeys ?? [] {
            keys += try OpenPGP.keys(from: Data(block.utf8)).filter { pins.contains($0.primaryFingerprint) }
        }
        let found = Set(keys.map(\.primaryFingerprint))
        guard found == pins else {
            throw DistroConfig.Invalid("\(distro.id): pinned keys missing from its key files: \(pins.subtracting(found).sorted())")
        }
        return keys
    }
}
