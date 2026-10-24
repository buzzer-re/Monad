//
//  ChecksumFile.swift — the checksum lists distros publish next to their
//  images, in the three layouts seen in practice:
//
//    gnu     "<hex>  <file>" or "<hex> *<file>"   (sha256sum/sha512sum output)
//    bsd     "SHA256 (<file>) = <hex>"            (Fedora CHECKSUM)
//    single  one gnu-style line for one file     (openSUSE .sha256)
//
//  Lines that do not parse are ignored (comments, signature armor). File
//  names must be plain names: they become part of a download URL.
//

import Foundation

struct ChecksumFile: Equatable {
    enum Format: String, Codable, Sendable {
        case gnu, bsd, single
    }

    enum Algorithm: String, Codable, Sendable {
        case sha256, sha512

        var hexLength: Int { self == .sha256 ? 64 : 128 }
        var bsdName: String { self == .sha256 ? "SHA256" : "SHA512" }
    }

    struct Entry: Equatable, Sendable {
        let file: String
        /// Lower-case hex.
        let digest: String
    }

    enum Problem: Error, Equatable, LocalizedError {
        case empty
        case notSingle(Int)
        case notFound(String)
        case ambiguous(String, [String])

        var errorDescription: String? {
            switch self {
            case .empty: return "The checksum file lists no files."
            case .notSingle(let n): return "Expected a checksum for one file, found \(n)."
            case .notFound(let p): return "The checksum file has no entry for \(p)."
            case .ambiguous(let p, let files): return "Several files match \(p): \(files.joined(separator: ", "))."
            }
        }
    }

    let algorithm: Algorithm
    let entries: [Entry]

    init(text: String, format: Format, algorithm: Algorithm) throws {
        self.algorithm = algorithm
        var found: [Entry] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw[...]
            let entry = format == .bsd ? Self.bsd(line, algorithm) : Self.gnu(line, algorithm)
            if let entry { found.append(entry) }
        }
        guard !found.isEmpty else { throw Problem.empty }
        if format == .single, found.count != 1 { throw Problem.notSingle(found.count) }
        entries = found
    }

    /// The one entry whose file name matches the glob `pattern`.
    func entry(matching pattern: String) throws -> Entry {
        let matches = entries.filter { Glob.matches(pattern, $0.file) }
        let names = Array(Set(matches.map(\.file))).sorted()
        guard !matches.isEmpty else { throw Problem.notFound(pattern) }
        guard names.count == 1 else { throw Problem.ambiguous(pattern, names) }
        let digests = Set(matches.map(\.digest))
        guard digests.count == 1 else { throw Problem.ambiguous(pattern, names) }
        return matches[0]
    }

    /// Letters, digits and ._+~- only; no path separators, no leading dot.
    static func isSafeFileName<S: StringProtocol>(_ s: S) -> Bool {
        guard !s.isEmpty, s.count <= 255, s.first != "." else { return false }
        return s.unicodeScalars.allSatisfy { c in
            c.isASCII && (CharacterSet.alphanumerics.contains(c) || "._+~-".unicodeScalars.contains(c))
        }
    }

    private static func hex(_ s: Substring, _ algorithm: Algorithm) -> String? {
        guard s.count == algorithm.hexLength, s.allSatisfy(\.isHexDigit) else { return nil }
        return s.lowercased()
    }

    private static func gnu(_ line: Substring, _ algorithm: Algorithm) -> Entry? {
        guard let space = line.firstIndex(of: " "), let digest = hex(line[..<space], algorithm) else { return nil }
        var rest = line[line.index(after: space)...]
        if rest.first == " " || rest.first == "*" { rest = rest.dropFirst() }
        guard isSafeFileName(rest) else { return nil }
        return Entry(file: String(rest), digest: digest)
    }

    private static func bsd(_ line: Substring, _ algorithm: Algorithm) -> Entry? {
        let prefix = algorithm.bsdName + " ("
        guard line.hasPrefix(prefix), let close = line.range(of: ") = ", options: .backwards) else { return nil }
        let name = line[line.index(line.startIndex, offsetBy: prefix.count)..<close.lowerBound]
        guard isSafeFileName(name), let digest = hex(line[close.upperBound...], algorithm) else { return nil }
        return Entry(file: String(name), digest: digest)
    }
}

/// Directory listings (HTML autoindex pages) used to discover versioned file
/// names, e.g. Fedora's "Fedora-Cloud-44-1.7-aarch64-CHECKSUM".
enum DirectoryIndex {
    enum Problem: Error, Equatable, LocalizedError {
        case notFound(String)
        case ambiguous(String, [String])

        var errorDescription: String? {
            switch self {
            case .notFound(let p): return "The directory listing has no file matching \(p)."
            case .ambiguous(let p, let f): return "Several files match \(p): \(f.joined(separator: ", "))."
            }
        }
    }

    /// Plain file names linked from the page (same directory only).
    static func files(in html: String) -> [String] {
        var out: [String] = []
        var rest = html[...]
        while let r = rest.range(of: "href=", options: .caseInsensitive) {
            rest = rest[r.upperBound...]
            guard let quote = rest.first, quote == "\"" || quote == "'" else { continue }
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: quote) else { break }
            var target = rest[..<end]
            rest = rest[rest.index(after: end)...]
            if target.hasPrefix("./") { target = target.dropFirst(2) }
            if ChecksumFile.isSafeFileName(target) { out.append(String(target)) }
        }
        return out
    }

    static func file(in html: String, matching pattern: String) throws -> String {
        let matches = Array(Set(files(in: html).filter { Glob.matches(pattern, $0) })).sorted()
        guard let first = matches.first else { throw Problem.notFound(pattern) }
        guard matches.count == 1 else { throw Problem.ambiguous(pattern, matches) }
        return first
    }
}

enum Glob {
    static func matches(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }
}
