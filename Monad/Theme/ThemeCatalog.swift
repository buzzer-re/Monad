//
//  ThemeCatalog.swift — the themes Monad knows: built-in ones shipped in the
//  app (read-only) and the user's own in ~/.monad/themes.
//

import Foundation
import os

struct ThemeCatalog {
    private(set) var themes: [Theme]
    /// Files that could not be used, for the editor to show.
    private(set) var problems: [String]
    private let builtInIDs: Set<String>
    private let userDirectory: URL?

    static let fileSuffix = ".theme.json"

    /// Built-in themes from `builtIn`, then the user's from `user`. User
    /// themes that are invalid or reuse a built-in id are skipped.
    static func load(builtIn: URL?, user: URL?) -> ThemeCatalog {
        var problems: [String] = []
        let bundled = read(builtIn, problems: &problems)
        let ids = Set(bundled.map(\.id))
        var own: [Theme] = []
        for t in read(user, problems: &problems) {
            if ids.contains(t.id) {
                problems.append("\(t.id)\(fileSuffix): the id of a built-in theme")
            } else {
                own.append(t)
            }
        }
        let byName: (Theme, Theme) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ThemeCatalog(themes: bundled.sorted(by: byName) + own.sorted(by: byName), problems: problems,
                            builtInIDs: ids, userDirectory: user)
    }

    /// Themes shipped in the app and the user's.
    static func live() -> ThemeCatalog {
        load(builtIn: Bundle.main.resourceURL, user: Paths.themes)
    }

    private static func read(_ dir: URL?, problems: inout [String]) -> [Theme] {
        guard let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(fileSuffix) }.sorted().compactMap { name in
            do {
                return try Theme.decode(Data(contentsOf: dir.appendingPathComponent(name)))
            } catch {
                problems.append("\(name): \(error.localizedDescription)")
                Log.app.error("theme \(name, privacy: .public) skipped: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    func theme(_ id: String) -> Theme? { themes.first { $0.id == id } }

    /// Not a theme: Monad Light or Monad Dark, following the appearance.
    static let automaticID = "automatic"

    /// The theme to draw with for `id`: "automatic" and missing themes (e.g.
    /// deleted) become Monad Light or Dark.
    func resolve(_ id: String, dark: Bool) -> Theme {
        if id != Self.automaticID, let t = theme(id) { return t }
        let fallback = dark ? Theme.monadDark : Theme.monadLight
        return theme(fallback.id) ?? fallback
    }

    func isBuiltIn(_ id: String) -> Bool { builtInIDs.contains(id) }

    /// Save a user theme (new or edited).
    mutating func save(_ theme: Theme) throws {
        guard !isBuiltIn(theme.id) else { throw Theme.Invalid("Built-in themes cannot be changed. Duplicate it first.") }
        guard let dir = userDirectory else { throw Theme.Invalid("There is no folder for user themes.") }
        try theme.validate()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try theme.encoded().write(to: dir.appendingPathComponent(theme.id + Self.fileSuffix), options: .atomic)
        themes.removeAll { $0.id == theme.id }
        themes.append(theme)
    }

    mutating func delete(_ id: String) throws {
        guard !isBuiltIn(id) else { throw Theme.Invalid("Built-in themes cannot be deleted.") }
        guard let dir = userDirectory, themes.contains(where: { $0.id == id }) else {
            throw Theme.Invalid("There is no theme “\(id)”.")
        }
        try FileManager.default.removeItem(at: dir.appendingPathComponent(id + Self.fileSuffix))
        themes.removeAll { $0.id == id }
    }

    /// A free, valid id derived from a theme name.
    func newID(for name: String) -> String {
        var slug = ""
        for ch in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) {
                slug.unicodeScalars.append(ch)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug += "-"
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "theme" }
        slug = String(slug.prefix(56))
        var id = slug, n = 2
        while theme(id) != nil {
            id = "\(slug)-\(n)"
            n += 1
        }
        return id
    }
}
