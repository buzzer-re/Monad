//
//  ProfileConfig.swift — a profile: what to set up in a VM, described as data
//  (built-ins in the bundle as <id>.profile.json, the user's own in
//  ~/.monad/profiles). Ordered steps, each exactly one of:
//
//    packages   names per package manager (apt, dnf, zypper); "a|b" installs
//               the first of them the distro has
//    runtime    a runtime Monad fetches and verifies on the Mac (nodejs)
//    npm        global npm packages
//    script     a POSIX sh script, run as root (MONAD_USER is the login user)
//
//  and optionally the commands the step must leave on PATH. Everything here
//  ends up in a shell script, so every name is checked against a strict
//  pattern: nothing can break out of the line it is written on.
//

import Foundation
import os

struct ProfileConfig: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1
    static let packageManagers: Set<String> = ["apt", "dnf", "zypper"]
    static let maxSteps = 16
    static let maxScriptBytes = 65_536

    struct Step: Codable, Equatable, Sendable {
        enum Kind: Equatable, Sendable { case packages, runtime, npm, script }

        var id: String
        var title: String
        var packages: [String: [String]]?
        var runtime: String?
        var npm: [String]?
        var script: String?
        /// Commands the step must leave on PATH.
        var commands: [String]?

        init(id: String, title: String, packages: [String: [String]]? = nil, runtime: String? = nil,
             npm: [String]? = nil, script: String? = nil, commands: [String]? = nil) {
            self.id = id
            self.title = title
            self.packages = packages
            self.runtime = runtime
            self.npm = npm
            self.script = script
            self.commands = commands
        }

        /// What the step does; nil unless it is exactly one thing.
        var kind: Kind? {
            let kinds: [Kind?] = [packages == nil ? nil : .packages, runtime == nil ? nil : .runtime,
                                  npm == nil ? nil : .npm, script == nil ? nil : .script]
            let set = kinds.compactMap { $0 }
            return set.count == 1 ? set[0] : nil
        }
    }

    var schema = ProfileConfig.schemaVersion
    var id: String
    var name: String
    var summary: String
    var steps: [Step]

    init(id: String, name: String, summary: String, steps: [Step]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.steps = steps
    }

    struct Invalid: Error, Equatable, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: Validation

    static func isID(_ s: String) -> Bool { s.matches(#"[a-z0-9][a-z0-9-]{0,31}"#) }
    /// A package name, or alternatives "a|b|c" (the first the distro has).
    static func isPackageName(_ s: String) -> Bool {
        let names = s.split(separator: "|", omittingEmptySubsequences: false)
        return (1...4).contains(names.count)
            && names.allSatisfy { String($0).matches(#"[A-Za-z0-9][A-Za-z0-9+._:-]{0,99}"#) }
    }
    static func isNPMSpec(_ s: String) -> Bool {
        s.count <= 214 && s.matches(#"(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*(@[A-Za-z0-9][A-Za-z0-9._+-]*)?"#)
    }
    static func isCommand(_ s: String) -> Bool { s.matches(#"[A-Za-z0-9][A-Za-z0-9._+-]{0,63}"#) }

    private static func isText(_ s: String, max: Int) -> Bool {
        !s.isEmpty && s.count <= max && !s.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// `runtimes`: the runtimes this Monad can provide.
    func validate(runtimes: Set<String>) throws {
        guard Self.isID(id) else { throw Invalid("“\(id)” is not a valid profile id: lowercase letters, digits and dashes.") }
        guard Self.isText(name, max: 40) else { throw Invalid("A profile needs a name of up to 40 characters.") }
        guard summary.count <= 200, !summary.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { throw Invalid("The summary of \(name) is too long.") }
        guard (1...Self.maxSteps).contains(steps.count) else {
            throw Invalid("\(name) needs 1 to \(Self.maxSteps) steps.")
        }
        var ids = Set<String>()
        for step in steps {
            let where_ = "\(name), step “\(step.title)”"
            guard Self.isID(step.id), ids.insert(step.id).inserted else {
                throw Invalid("\(name): step ids must be unique lowercase names (“\(step.id)”).")
            }
            guard Self.isText(step.title, max: 60) else { throw Invalid("\(name): every step needs a title.") }
            guard let kind = step.kind else {
                throw Invalid("\(where_) must be exactly one of packages, runtime, npm or script.")
            }
            switch kind {
            case .packages:
                let byManager = step.packages ?? [:]
                guard !byManager.isEmpty else { throw Invalid("\(where_) names no packages.") }
                for (manager, names) in byManager {
                    guard Self.packageManagers.contains(manager) else {
                        throw Invalid("\(where_): “\(manager)” is not a package manager Monad knows (apt, dnf, zypper).")
                    }
                    guard (1...64).contains(names.count) else { throw Invalid("\(where_): 1 to 64 packages per manager.") }
                    for n in names where !Self.isPackageName(n) { throw Invalid("\(where_): “\(n)” is not a package name.") }
                }
            case .runtime:
                guard let r = step.runtime, runtimes.contains(r) else {
                    throw Invalid("\(where_): “\(step.runtime ?? "")” is not a runtime Monad provides.")
                }
            case .npm:
                let specs = step.npm ?? []
                guard (1...32).contains(specs.count) else { throw Invalid("\(where_): 1 to 32 npm packages.") }
                for n in specs where !Self.isNPMSpec(n) { throw Invalid("\(where_): “\(n)” is not an npm package.") }
            case .script:
                let text = step.script ?? ""
                guard !text.isEmpty, text.utf8.count <= Self.maxScriptBytes, !text.contains("\u{0}") else {
                    throw Invalid("\(where_): a script of up to 64 KB is needed.")
                }
            }
            if let commands = step.commands {
                guard commands.count <= 16 else { throw Invalid("\(where_): at most 16 commands to check.") }
                for c in commands where !Self.isCommand(c) { throw Invalid("\(where_): “\(c)” is not a command name.") }
            }
        }
    }

    /// Whether every package step names packages for `packageManager`.
    func supports(packageManager: String) -> Bool {
        steps.allSatisfy { $0.packages == nil || $0.packages?[packageManager] != nil }
    }

    // MARK: Coding

    static func decode(_ data: Data) throws -> ProfileConfig {
        struct Header: Decodable { let schema: Int }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.schema == schemaVersion else {
            throw Invalid("Profile schema \(header.schema) is not supported (this Monad reads \(schemaVersion)).")
        }
        return try JSONDecoder().decode(ProfileConfig.self, from: data)
    }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}

private extension String {
    /// The whole string matches (no partial match, no trailing newline).
    func matches(_ pattern: String) -> Bool {
        range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }
}

/// The user's own profiles: one private JSON file each.
struct ProfileStore {
    let directory: URL

    init(directory: URL = Paths.profiles) {
        self.directory = directory
    }

    private func file(_ id: String) -> URL { directory.appendingPathComponent("\(id).profile.json") }

    /// Every valid profile, by id.
    func all(runtimes: Set<String> = ProfileCatalog.runtimes) throws -> [ProfileConfig] {
        try Paths.ensurePrivateDirectory(directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return files.filter { $0.lastPathComponent.hasSuffix(".profile.json") }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let p = try? ProfileConfig.decode(data),
                  url.lastPathComponent == "\(p.id).profile.json", (try? p.validate(runtimes: runtimes)) != nil else {
                Log.host.error("Ignoring the profile file \(url.lastPathComponent, privacy: .public): unreadable or invalid")
                return nil
            }
            return p
        }.sorted { $0.id < $1.id }
    }

    func save(_ profile: ProfileConfig, runtimes: Set<String> = ProfileCatalog.runtimes) throws {
        try profile.validate(runtimes: runtimes)
        try Paths.ensurePrivateDirectory(directory)
        let url = file(profile.id)
        try profile.encoded().write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func delete(id: String) throws {
        guard ProfileConfig.isID(id) else { return }
        try? FileManager.default.removeItem(at: file(id))
    }
}

/// Every profile there is: the built-ins (each as the user edited it, if
/// they did: their version is saved under the built-in's id), then the
/// user's own.
struct ProfileCatalog {
    /// Runtimes this Monad provides.
    static let runtimes: Set<String> = ["nodejs"]

    let builtIn: [ProfileConfig]
    let custom: [ProfileConfig]
    /// The built-ins as shipped, by id (empty when made in code, e.g. tests).
    var shippedBuiltIns: [ProfileConfig] = []

    init(builtIn: [ProfileConfig], custom: [ProfileConfig], shippedBuiltIns: [ProfileConfig] = []) {
        self.builtIn = builtIn
        self.custom = custom
        self.shippedBuiltIns = shippedBuiltIns
    }

    var all: [ProfileConfig] { builtIn + custom }

    func profile(_ id: String) -> ProfileConfig? { all.first { $0.id == id } }
    func isBuiltIn(_ id: String) -> Bool { builtIn.contains { $0.id == id } }
    func shipped(_ id: String) -> ProfileConfig? { shippedBuiltIns.first { $0.id == id } }
    /// A built-in the user changed.
    func isEdited(_ id: String) -> Bool {
        guard let s = shipped(id), let p = profile(id) else { return false }
        return s != p
    }

    static func bundled(_ bundle: Bundle = .main, custom: ProfileStore? = nil) throws -> ProfileCatalog {
        let urls = (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".profile.json") }
        let builtIn = try urls.map { url -> ProfileConfig in
            let p: ProfileConfig
            do {
                p = try ProfileConfig.decode(Data(contentsOf: url))
            } catch {
                throw ProfileConfig.Invalid("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            try p.validate(runtimes: runtimes)
            return p
        }.sorted { $0.id < $1.id }
        let ids = Set(builtIn.map(\.id))
        let saved = (try? custom?.all()) ?? []
        let effective = builtIn.map { b in saved.first { $0.id == b.id } ?? b }
        return ProfileCatalog(builtIn: effective, custom: saved.filter { !ids.contains($0.id) }, shippedBuiltIns: builtIn)
    }
}
