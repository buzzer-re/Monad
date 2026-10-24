//
//  ImageLink.swift — the one thing the distro form's Simple view asks for:
//  where a disk image is, an address or a file on this Mac. Its name gives
//  the distro's name and version; next to it Monad looks for a checksum file
//  that lists it and that file's signature (ImagePipeline.discover).
//

import Foundation

struct ImageLink: Equatable {
    struct Refused: Error, Equatable, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let url: URL

    init(_ text: String) throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw Refused(message: "Paste the image's address, or choose the file.") }
        let url: URL
        if t.hasPrefix("/") {
            url = URL(fileURLWithPath: t)
        } else if t.hasPrefix("~/") {
            url = URL(fileURLWithPath: NSHomeDirectory() + t.dropFirst())
        } else if let u = URL(string: t), let scheme = u.scheme?.lowercased(),
                  scheme == "file" ? u.path.hasPrefix("/") : (scheme == "http" || scheme == "https") && !(u.host ?? "").isEmpty {
            url = scheme == "file" ? URL(fileURLWithPath: u.path) : u
        } else {
            throw Refused(message: "An http://, https:// address or a file on this Mac.")
        }
        guard !url.hasDirectoryPath, Self.format(of: Self.inner(url.lastPathComponent).name) != nil else {
            throw Refused(message: "This is not a disk image. Monad takes .qcow2, .img and .raw images, "
                + "also compressed as .xz or .gz.")
        }
        let path = url.path.lowercased()
        if path.range(of: #"(^|[/._-])(amd64|x86_64|x86-64|x64|i386|i686)([/._-]|$)"#, options: .regularExpression) != nil {
            throw Refused(message: "This image is for Intel and AMD PCs (amd64). Monad runs arm64 images natively: "
                + "look for aarch64 or arm64 in the name.")
        }
        self.url = url
    }

    /// The name without its compression suffix, and the compression.
    private static func inner(_ name: String) -> (name: String, compression: DistroConfig.Compression?) {
        let n = name.lowercased()
        if n.hasSuffix(".xz") { return (String(name.dropLast(3)), .xz) }
        if n.hasSuffix(".gz") { return (String(name.dropLast(3)), .gz) }
        return (name, nil)
    }

    /// How the published file is compressed (name.qcow2.xz), if it is.
    var compression: DistroConfig.Compression? { Self.inner(file).compression }

    var file: String { url.lastPathComponent }
    var isLocal: Bool { url.isFileURL }
    /// The folder the image is in, with its trailing slash.
    var directory: URL { url.deletingLastPathComponent() }

    /// What the name says. An .img is most often qcow2; the pipeline looks
    /// inside, and reads one that is a raw disk as raw.
    var format: DistroConfig.ImageFormat { Self.format(of: Self.inner(file).name) ?? .qcow2 }

    private static func format(of name: String) -> DistroConfig.ImageFormat? {
        let n = name.lowercased()
        if n.hasSuffix(".qcow2") || n.hasSuffix(".img") { return .qcow2 }
        if n.hasSuffix(".raw") { return .raw }
        return nil
    }

    /// A name and a version from the file name: its first word, and the
    /// first word after it that is a number ("latest" without one).
    var guess: (name: String, release: String) {
        var stem = Self.inner(file).name
        if let dot = stem.range(of: ".", options: .backwards) { stem = String(stem[..<dot.lowerBound]) }
        let words = stem.split(whereSeparator: { "-_ ".contains($0) }).map(String.init)
        var name = words.first ?? stem
        if name == name.lowercased(), let first = name.first { name = first.uppercased() + name.dropFirst() }
        let release = words.dropFirst().first { $0.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil }
        return (name, release ?? "latest")
    }

    /// Where a checksum file listing the image may be: the names in the
    /// folder's listing that look like one, then the usual names.
    func checksumCandidates(listing: String?) -> [URL] {
        var names: [String] = []
        if let listing {
            for name in DirectoryIndex.files(in: listing) {
                let n = name.lowercased()
                guard n.contains("checksum") || n.contains("sums") || n.hasSuffix(".sha256") || n.hasSuffix(".sha512"),
                      !Self.signatureSuffixes.contains(where: { n.hasSuffix($0) }) else { continue }
                names.append(name)
            }
        }
        names += ["CHECKSUM", "SHA256SUMS", "SHA512SUMS", "CHECKSUMS", file + ".sha256", file + ".sha256sum",
                  file + ".sha512", file + ".CHECKSUM"]
        var seen = Set<String>()
        return names.filter { ChecksumFile.isSafeFileName($0) && seen.insert($0).inserted }
            .prefix(Self.maxCandidates).map { directory.appendingPathComponent($0) }
    }

    static let maxCandidates = 12
    static let signatureSuffixes = [".asc", ".gpg", ".sign", ".sig"]
}

/// What Monad found next to an image.
struct ImageDiscovery: Equatable, Sendable {
    struct Checksums: Equatable, Sendable {
        var url: URL
        var format: ChecksumFile.Format
        var algorithm: ChecksumFile.Algorithm
        /// detached (with `signatureURL`), clearsigned, or none found.
        var signature: DistroConfig.SignatureKind
        var signatureURL: URL?
    }

    /// nil: nothing to check the image against.
    var checksums: Checksums?

    /// How a checksum file's text lists files: the layout and hash that
    /// read the most entries (nil when no line is a checksum).
    static func layout(of text: String) -> (format: ChecksumFile.Format, algorithm: ChecksumFile.Algorithm, file: ChecksumFile)? {
        var best: (format: ChecksumFile.Format, algorithm: ChecksumFile.Algorithm, file: ChecksumFile)?
        for format in [ChecksumFile.Format.gnu, .bsd] {
            for algorithm in [ChecksumFile.Algorithm.sha256, .sha512] {
                guard let f = try? ChecksumFile(text: text, format: format, algorithm: algorithm) else { continue }
                if f.entries.count > best?.file.entries.count ?? 0 { best = (format, algorithm, f) }
            }
        }
        return best
    }
}
