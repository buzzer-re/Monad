//
//  GuestApps.swift — the graphical programs a Linux VM has, for the Apps
//  menu: what the guest's script (Guest/monad-apps.sh, from the VM's
//  desktop entries) prints is read here, and a program is started by its
//  id.
//
//  All of it is the guest's word, read as hostile: the list is bounded
//  lines of plain ASCII in an exact grammar, or it is no list; a name is
//  text to show in a menu and nothing more; an icon is bytes that begin as
//  a PNG file does, bounded, kept as a file in the VM's own folder and
//  decoded only by the app, by its id. The Mac never sends the guest
//  anything it said but an id, which can be nothing but an id.
//

import Foundation

/// A graphical program in a Linux VM (a desktop entry there).
struct GuestApp: Codable, Equatable, Sendable, Identifiable {
    /// The desktop entry's name without ".desktop": what it is started by.
    let id: String
    /// What it calls itself, made fit to show.
    var name: String
    /// MonadHost keeps an icon for it (GuestApps.iconFile).
    var hasIcon = false
}

enum GuestApps {
    /// The profile that sets up what shows a VM's programs as windows on the Mac.
    static let profile = "app-windows"
    static let path = "/usr/local/lib/monad/apps"
    static let maxApps = 256
    static let maxListBytes = 256 * 1024
    static let maxLineBytes = 1024
    /// An icon's file at most, and how many are asked for at once: a command's output is kept up to 1 MiB.
    static let maxIconBytes = 262_144
    static let iconsAtOnce = 6

    static let listCommand = path + " list"

    /// Letters, digits, dot, dash and underscore, beginning with a letter,
    /// a digit or an underscore: safe as a word of a command and as a file's name.
    static func isID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil
    }

    static func launchCommand(_ id: String) -> String? { isID(id) ? "\(path) launch \(id)" : nil }

    static func iconsCommand(_ ids: [String]) -> String? {
        guard !ids.isEmpty, ids.count <= 64, ids.allSatisfy(isID) else { return nil }
        return "\(path) icons " + ids.joined(separator: " ")
    }

    /// Where MonadHost keeps a program's icon, in the VM's folder.
    static func iconFile(_ id: String, in folder: URL) -> URL? {
        isID(id) ? folder.appendingPathComponent(id + ".png") : nil
    }

    /// `app <id> <icon> <name>` lines, then `end <count>`. nil unless it
    /// is exactly that. A program whose id is none here is left out.
    static func parseList(_ output: Data) -> [GuestApp]? {
        guard output.count <= maxListBytes, output.last == 0x0A else { return nil }
        var apps: [GuestApp] = [], seen = Set<String>(), lines = 0, ended = false
        for line in output.dropLast().split(separator: 0x0A, omittingEmptySubsequences: false) {
            guard !ended, line.count <= maxLineBytes, line.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return nil }
            let words = String(decoding: line, as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false)
            guard !words.contains(where: \.isEmpty) else { return nil }
            if words.first == "end" {
                guard words.count == 2, let count = strictNumber(words[1]), count == lines else { return nil }
                ended = true
                continue
            }
            guard words.first == "app", words.count == 4, lines < maxApps,
                  words[1].utf8.count <= 128, words[1].utf8.allSatisfy(isIDByte),
                  let name = GuestWindowReader.text(words[3]), GuestWindowReader.text(words[2]) != nil else { return nil }
            lines += 1
            let id = String(words[1])
            guard seen.insert(id).inserted else { return nil }
            guard isID(id) else { continue }
            let shown = name.trimmingCharacters(in: .whitespaces)
            apps.append(GuestApp(id: id, name: shown.isEmpty ? id : String(shown.prefix(80))))
        }
        return ended ? apps : nil
    }

    /// `icon <id> <bytes>` and that many bytes, again and again, then
    /// `end`: the icons of the programs asked about that are PNG files.
    /// What does not fit ends the reading; what came whole before is kept.
    static func parseIcons(_ output: Data, for ids: Set<String>) -> [String: Data] {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var icons: [String: Data] = [:]
        var at = output.startIndex
        while at < output.endIndex {
            guard let newline = output[at...].prefix(200).firstIndex(of: 0x0A) else { break }
            let line = output[at..<newline]
            guard line.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { break }
            let words = String(decoding: line, as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false)
            guard words.count == 3, words[0] == "icon", let count = strictNumber(words[2]), (1...maxIconBytes).contains(count) else { break }
            let start = output.index(after: newline)
            guard output.distance(from: start, to: output.endIndex) >= count else { break }
            let end = output.index(start, offsetBy: count)
            let id = String(words[1])
            if ids.contains(id), isID(id), icons[id] == nil, output[start..<end].starts(with: png) {
                icons[id] = Data(output[start..<end])
            }
            at = end
        }
        return icons
    }

    private static func isIDByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2E || byte == 0x2D
            || byte == 0x5F
    }

    /// Digits only, no sign, no leading zero, at most what an icon or a list can count.
    private static func strictNumber(_ word: Substring) -> Int? {
        guard !word.isEmpty, word.utf8.count <= 7, word.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), word == "0" || word.first != "0"
        else { return nil }
        return Int(word)
    }

    /// The programs for the Apps menu or its search: those whose name or
    /// id has every word of `search` (capitals and accents aside), the
    /// user's favourites apart and first, each list by name.
    static func arrange(_ apps: [GuestApp], favorites: [String], matching search: String = "")
        -> (favorites: [GuestApp], others: [GuestApp]) {
        func folded(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let words = folded(search).split(separator: " ")
        let found = apps.filter { app in
            let text = folded(app.name) + " " + folded(app.id)
            return words.allSatisfy { text.contains($0) }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let starred = Set(favorites)
        return (found.filter { starred.contains($0.id) }, found.filter { !starred.contains($0.id) })
    }
}

/// The programs the user starred in the Apps menu, by VM: the app's own
/// preferences, nothing of the VM's.
struct GuestAppFavorites {
    static let key = "guestAppFavorites"
    static let maxPerVM = 64
    var defaults: UserDefaults = .standard

    func ids(for vm: String) -> [String] {
        guard InstanceConfig.isValidName(vm), let all = defaults.dictionary(forKey: Self.key), let list = all[vm] as? [Any] else { return [] }
        return Array(list.compactMap { $0 as? String }.filter(GuestApps.isID).prefix(Self.maxPerVM))
    }

    func set(_ id: String, starred: Bool, for vm: String) {
        guard InstanceConfig.isValidName(vm), GuestApps.isID(id) else { return }
        var list = ids(for: vm)
        if starred {
            guard !list.contains(id), list.count < Self.maxPerVM else { return }
            list.append(id)
        } else {
            list.removeAll { $0 == id }
        }
        var all = defaults.dictionary(forKey: Self.key) ?? [:]
        all[vm] = list.isEmpty ? nil : list
        defaults.set(all, forKey: Self.key)
    }
}
