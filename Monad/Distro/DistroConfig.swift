//
//  DistroConfig.swift — one distribution, described entirely by data
//  (Monad/Distros/<id>.distro.json). Code in this folder implements generic
//  mechanisms the configuration selects; nothing here knows a distro by name.
//
//  Templates use {placeholders}:
//    everywhere      {release} {arch} and the release's own "vars"
//    signature.url   + {checksums}          (URL of the checksum file)
//    image.url       + {checksums} {dir} {file}
//  {dir} is the checksum file's directory (with a trailing slash) and {file}
//  the image name selected from the checksum file by the image.file glob.
//
//  A distro the user adds may have no checksum file: image.url is then the
//  image itself (an address or a file:// on this Mac), used as it is.
//

import Foundation

/// What runs in the guest: a Linux distribution, or macOS (Phase 14). It
/// decides how Monad provisions and reaches the guest, never its name.
enum GuestOS: String, Codable, Sendable {
    case linux
    case macos

    /// The guests VMs can be made of, in any build. A kind added later is
    /// left out until it can be made whole: known, but listed nowhere a VM
    /// is made.
    static let ready: Set<GuestOS> = [.linux, .macos]
}

struct DistroConfig: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    struct Release: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var isDefault: Bool?
        var vars: [String: String]?

        enum CodingKeys: String, CodingKey {
            case id, name, vars
            case isDefault = "default"
        }
    }

    enum ImageFormat: String, Codable, Sendable {
        case qcow2
        case raw
        case tarXz = "tar.xz"
        /// An Apple restore image (macOS guests), kept as it is.
        case ipsw
    }

    /// How a qcow2 or raw image is compressed as published (name.qcow2.xz).
    enum Compression: String, Codable, Sendable {
        case xz, gz
    }

    enum SignatureKind: String, Codable, Sendable {
        case detached, clearsigned, none
    }

    struct ChecksumSource: Codable, Equatable, Sendable {
        /// The checksum file itself...
        var url: String?
        /// ...or a directory listing and a glob naming it.
        var index: String?
        var pattern: String?
        var format: ChecksumFile.Format
        var algorithm: ChecksumFile.Algorithm
    }

    struct SignatureSource: Codable, Equatable, Sendable {
        var kind: SignatureKind
        /// Detached signature location.
        var url: String?
        /// Key files shipped in Monad's bundle.
        var keys: [String]?
        /// Primary key fingerprints trusted to sign (upper-case hex).
        var fingerprints: [String]?
        /// Why a distro is not signature-checked (required for kind none).
        var note: String?
        /// The signing keys themselves, armored, instead of `keys`: a distro
        /// the user adds is one file with everything in it.
        var publicKeys: [String]? = nil
    }

    struct ImageSource: Codable, Equatable, Sendable {
        /// nil: `url` is the image itself, nothing to check it against (a
        /// distro the user adds only).
        var checksums: ChecksumSource?
        var signature: SignatureSource
        /// Glob selecting the image in the checksum file.
        var file: String
        var url: String
        var format: ImageFormat
        /// Member holding the disk inside an archive.
        var member: String?
        /// The published file is compressed; the disk is what is inside.
        var compression: Compression? = nil
    }

    /// What Monad needs to know about a distro's guest, which is almost
    /// nothing: the guest itself decides the rest at boot (its admin groups,
    /// SELinux; every network sshd unit name is masked). Optional, like the
    /// whole "guest" section.
    struct GuestProfile: Codable, Equatable, Sendable {
        /// Where sshd is, if not /usr/sbin/sshd.
        var sshd: String? = nil
        /// apt, dnf or zypper: which profiles can install packages here.
        var packageManager: String? = nil

        var sshdPath: String { sshd ?? "/usr/sbin/sshd" }
    }

    var schema: Int
    var id: String
    var name: String
    var releases: [Release]
    /// Host architecture ("arm64", "x86_64") to the distro's name for it.
    var architectures: [String: String]
    var image: ImageSource
    var guest: GuestProfile
    /// The distro new VMs use unless another is chosen (at most one).
    var preferred: Bool? = nil
    /// macOS for an Apple restore image; absent: a Linux distribution.
    var kind: GuestOS? = nil

    var guestOS: GuestOS { kind ?? .linux }

    /// image.url of macOS: the latest restore image this Mac supports, as
    /// Virtualization reports it (VZMacOSRestoreImage).
    static let appleLatest = "apple:latest"

    /// Whether `url` is where a restore image may come from: Apple's latest,
    /// or an https address or a file on this Mac naming an .ipsw.
    static func isRestoreImageURL(_ url: String) -> Bool {
        if url == appleLatest { return true }
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
              u.path.lowercased().hasSuffix(".ipsw") else { return false }
        switch scheme {
        case "https": return !(u.host ?? "").isEmpty
        case "file": return u.path.hasPrefix("/") && !u.path.split(separator: "/").contains("..") && (u.host ?? "").isEmpty
        default: return false
        }
    }

    var isSigned: Bool { image.signature.kind != .none }

    var defaultRelease: Release { releases.first { $0.isDefault == true } ?? releases[0] }

    // MARK: Decoding

    struct Invalid: Error, Equatable, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func decode(_ data: Data) throws -> DistroConfig {
        struct Header: Decodable { let schema: Int }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.schema == schemaVersion else {
            throw Invalid("Distro configuration schema \(header.schema) is not supported (this Monad reads \(schemaVersion)).")
        }
        return try JSONDecoder().decode(DistroConfig.self, from: data)
    }

    // MARK: Planning

    /// Everything needed to fetch one release for one host architecture.
    struct Plan: Equatable, Sendable {
        enum Checksums: Equatable, Sendable {
            case url(URL)
            case index(URL, pattern: String)
            /// No checksum file: the image is here, used as it is.
            case direct(URL)
        }

        let distro: String
        let release: String
        let arch: String
        let checksums: Checksums
        let checksumFormat: ChecksumFile.Format
        let algorithm: ChecksumFile.Algorithm
        let signature: SignatureKind
        let filePattern: String
        let format: ImageFormat
        let member: String?
        let compression: Compression?
        fileprivate let vars: [String: String]
        fileprivate let signatureTemplate: String?
        fileprivate let urlTemplate: String

        func signatureURL(checksums: URL) throws -> URL? {
            guard let signatureTemplate else { return nil }
            var v = vars
            v["checksums"] = checksums.absoluteString
            return try DistroConfig.url(signatureTemplate, v)
        }

        func imageURL(file: String, checksums: URL) throws -> URL {
            guard ChecksumFile.isSafeFileName(file) else { throw Invalid("Unsafe image file name \(file).") }
            var v = vars
            v["checksums"] = checksums.absoluteString
            v["dir"] = checksums.deletingLastPathComponent().absoluteString
            v["file"] = file
            return try DistroConfig.url(urlTemplate, v)
        }
    }

    func plan(release releaseID: String, hostArch: String) throws -> Plan {
        guard let release = releases.first(where: { $0.id == releaseID }) else {
            throw Invalid("\(name) has no release \(releaseID).")
        }
        guard let arch = architectures[hostArch] else { throw Invalid("\(name) has no images for \(hostArch).") }
        var vars = release.vars ?? [:]
        vars["release"] = release.id
        vars["arch"] = arch
        let checksums: Plan.Checksums
        if let c = image.checksums {
            if let url = c.url {
                checksums = .url(try Self.url(url, vars))
            } else if let index = c.index, let pattern = c.pattern {
                checksums = .index(try Self.url(index, vars), pattern: try Self.expand(pattern, vars))
            } else {
                throw Invalid("\(name): no checksum location.")
            }
        } else {
            checksums = .direct(try Self.url(image.url, vars, allowFile: true))
        }
        return Plan(distro: id, release: release.id, arch: arch, checksums: checksums,
                    checksumFormat: image.checksums?.format ?? .gnu, algorithm: image.checksums?.algorithm ?? .sha256,
                    signature: image.signature.kind, filePattern: try Self.expand(image.file, vars),
                    format: image.format, member: image.member, compression: image.compression, vars: vars,
                    signatureTemplate: image.signature.kind == .detached ? image.signature.url : nil,
                    urlTemplate: image.url)
    }

    // MARK: Templates

    static func expand(_ template: String, _ vars: [String: String]) throws -> String {
        var out = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { throw Invalid("Unclosed { in \(template).") }
            let name = String(rest[rest.index(after: open)..<close])
            guard let value = vars[name] else { throw Invalid("Unknown placeholder {\(name)} in \(template).") }
            out += value
            rest = rest[rest.index(after: close)...]
        }
        if rest.contains("}") { throw Invalid("Stray } in \(template).") }
        return out + rest
    }

    /// An address from a template: https, or plain http where allowed (a
    /// distro the user adds may use it: their network, their choice;
    /// Monad's own are https only, checked by `validate`).
    static func url(_ template: String, _ vars: [String: String], httpsOnly: Bool = false,
                    allowFile: Bool = false) throws -> URL {
        let s = try expand(template, vars)
        if allowFile, !httpsOnly, let url = URL(string: s), url.scheme?.lowercased() == "file" {
            guard url.path.hasPrefix("/"), !url.path.split(separator: "/").contains(".."), (url.host ?? "").isEmpty else {
                throw Invalid("Not a file on this Mac: \(s).")
            }
            return URL(fileURLWithPath: url.path)
        }
        let schemes: Set<String> = httpsOnly ? ["https"] : ["https", "http"]
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), schemes.contains(scheme),
              let host = url.host, !host.isEmpty else {
            throw Invalid(httpsOnly ? "Not an https URL: \(s)." : "Not an http or https URL: \(s).")
        }
        return url
    }

    // MARK: Validation

    private static let reservedVars: Set<String> = ["release", "arch", "checksums", "dir", "file"]
    static let packageManagers: Set<String> = ["apt", "dnf", "zypper"]

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    /// `userFile`: a distro the user added (~/.monad/distros), which carries
    /// its keys inline and cannot make itself the default.
    func validate(userFile: Bool = false) throws {
        func check(_ ok: Bool, _ message: @autoclosure () -> String) throws {
            if !ok { throw Invalid("\(id): \(message())") }
        }
        if userFile {
            try check(image.signature.keys == nil,
                      "a distribution you add carries its signing keys inline (signature.publicKeys), not as files")
            try check(preferred != true, "a distribution you add cannot make itself the default (preferred)")
        }
        try check(schema == Self.schemaVersion, "unsupported schema \(schema)")
        try check(Self.matches(id, "^[a-z][a-z0-9-]{0,31}$"), "invalid id")
        try check(!name.trimmingCharacters(in: .whitespaces).isEmpty, "missing name")
        try check(!releases.isEmpty, "no releases")
        try check(releases.filter { $0.isDefault == true }.count == 1, "exactly one release must be the default")
        try check(Set(releases.map(\.id)).count == releases.count, "duplicate release ids")
        try check(architectures["arm64"] != nil, "no arm64 images")
        for (host, arch) in architectures {
            try check(Self.matches(host, "^[a-z0-9_]+$") && Self.matches(arch, "^[a-z0-9_]+$"), "bad architecture \(host)")
        }

        // macOS: an Apple restore image, which Apple signs and Virtualization
        // checks; no checksum file, no package manager.
        try check((guestOS == .macos) == (image.format == .ipsw), "macOS comes as an IPSW, and only macOS does")
        if guestOS == .macos {
            try check(Self.isRestoreImageURL(image.url),
                      "image.url is \(Self.appleLatest), or an https address or a file ending in .ipsw")
            try check(image.checksums == nil && image.signature.kind == .none && image.compression == nil && image.member == nil,
                      "a restore image has no checksum file, signature, compression or member")
            try check(guest.packageManager == nil && guest.sshd == nil, "macOS has no guest.packageManager or guest.sshd")
            return
        }

        // Checksums and signature
        let s = image.signature
        try check(image.compression == nil || image.format != .tarXz,
                  "image.compression is for qcow2 and raw images (a tar.xz is an archive)")
        guard let c = image.checksums else {
            // An image by its link alone: a distro the user adds, unsigned.
            try check(userFile, "no checksums: Monad's own distributions check their images")
            try check(s.kind == .none && s.url == nil && s.keys == nil && s.publicKeys == nil && s.fingerprints == nil,
                      "an image without a checksum file cannot be signed")
            try check(image.format != .tarXz, "an image without a checksum file is qcow2 or raw")
            for release in releases {
                var vars = release.vars ?? [:]
                try check(Set(vars.keys).isDisjoint(with: Self.reservedVars), "release \(release.id) redefines a built-in placeholder")
                vars["release"] = release.id
                for arch in architectures.values {
                    vars["arch"] = arch
                    do { _ = try Self.url(image.url, vars, allowFile: true) } catch let e as Invalid {
                        throw Invalid("\(id) \(release.id): \(e.message)")
                    }
                }
            }
            try validateGuest()
            return
        }
        try check((c.url != nil) != (c.index != nil), "give either checksums.url or checksums.index")
        try check((c.index == nil) == (c.pattern == nil), "checksums.index needs a pattern")
        switch s.kind {
        case .detached:
            try check(s.url != nil, "a detached signature needs a URL")
        case .clearsigned:
            try check(s.url == nil, "a clearsigned checksum file has no separate signature URL")
        case .none:
            try check(s.url == nil && s.keys == nil && s.publicKeys == nil && s.fingerprints == nil,
                      "an unsigned distro lists no keys")
            // Monad's own say why; a distro the user adds need not (a mirror
            // they host themselves, say): a signature is recommended there.
            try check(userFile || !(s.note ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                      "an unsigned distro must explain why (signature.note)")
        }
        if s.kind != .none {
            let keys = s.keys ?? [], inline = s.publicKeys ?? [], fprs = s.fingerprints ?? []
            try check(keys.isEmpty != inline.isEmpty,
                      "give the signing keys either as files (signature.keys) or inline (signature.publicKeys)")
            try check(keys.allSatisfy { ChecksumFile.isSafeFileName($0) && $0.hasSuffix(".asc") },
                      "signature.keys must name bundled .asc files")
            try check(inline.count <= 8 && inline.allSatisfy { $0.utf8.count <= 64 << 10 && $0.contains("BEGIN PGP PUBLIC KEY BLOCK") },
                      "signature.publicKeys must be up to 8 armored public keys")
            try check(!fprs.isEmpty && fprs.allSatisfy { Self.matches($0, "^[0-9A-F]{40}$") },
                      "signature.fingerprints must be 40 upper-case hex digits")
        }

        // Image
        try check((image.format == .tarXz) == (image.member != nil), "image.member is required for archives only")
        if let member = image.member { try check(!member.isEmpty && !member.hasPrefix("/"), "bad image.member") }

        // Every template must expand for every release.
        for release in releases {
            var vars = release.vars ?? [:]
            try check(Set(vars.keys).isDisjoint(with: Self.reservedVars), "release \(release.id) redefines a built-in placeholder")
            vars["release"] = release.id
            for arch in architectures.values {
                vars["arch"] = arch
                do {
                    if let u = c.url { _ = try Self.url(u, vars, httpsOnly: !userFile) }
                    if let i = c.index { _ = try Self.url(i, vars, httpsOnly: !userFile) }
                    if let p = c.pattern {
                        try check(Self.matches(try Self.expand(p, vars), "^[A-Za-z0-9._+~*?-]+$"), "bad checksums.pattern")
                    }
                    try check(Self.matches(try Self.expand(image.file, vars), "^[A-Za-z0-9._+~*?-]+$"), "bad image.file (a file name: letters, digits, . _ + ~ - and * ? for what changes)")
                    var full = vars
                    full["checksums"] = "https://example.invalid/dir/SUMS"
                    full["dir"] = "https://example.invalid/dir/"
                    full["file"] = "image.img"
                    if let u = s.url { _ = try Self.url(u, full, httpsOnly: !userFile) }
                    _ = try Self.url(image.url, full, httpsOnly: !userFile)
                } catch let e as Invalid {
                    throw Invalid("\(id) \(release.id): \(e.message)")
                }
            }
        }

        try validateGuest()
    }

    private func validateGuest() throws {
        func check(_ ok: Bool, _ message: String) throws {
            if !ok { throw Invalid("\(id): \(message)") }
        }
        let g = guest
        if let sshd = g.sshd { try check(Self.matches(sshd, "^/[A-Za-z0-9/._-]+$"), "guest.sshd must be an absolute path") }
        if let pm = g.packageManager { try check(Self.packageManagers.contains(pm), "unknown guest.packageManager") }
    }
}

extension DistroConfig {
    /// A file may leave the "guest" section out (in an extension, so the
    /// memberwise initializer stays).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        releases = try c.decode([Release].self, forKey: .releases)
        architectures = try c.decode([String: String].self, forKey: .architectures)
        image = try c.decode(ImageSource.self, forKey: .image)
        guest = try c.decodeIfPresent(GuestProfile.self, forKey: .guest) ?? GuestProfile()
        preferred = try c.decodeIfPresent(Bool.self, forKey: .preferred)
        kind = try c.decodeIfPresent(GuestOS.self, forKey: .kind)
    }
}
