//
//  DistroDraft.swift — the form behind Settings › Distributions › New
//  Distribution… and Edit…: the same file a person would write by hand
//  (docs/DISTROS.md), as fields. The signing key is pasted or read from its
//  file and its fingerprint taken from the key; each problem is said by
//  field, in the user's words, before Monad's own validation has its say.
//
//  Simple takes the image's link (an address or a file on this Mac) and
//  fills in the rest from what Monad finds next to it (`use`); Advanced
//  shows every field.
//

import Foundation

struct DistroDraft: Equatable {
    struct ReleaseRow: Equatable {
        var id: String
        var name: String
        var isDefault: Bool
        /// More placeholders for this release, "key=value, key=value".
        var vars: String
    }

    enum Field: Hashable {
        case name, id, releases, link, checksums, file, signature, key, note, other
    }

    var name = ""
    /// Follows the name until it is set (and is set for a distro opened to edit).
    var id: String {
        get { idValue ?? Self.slug(name) }
        set { idValue = newValue }
    }
    private var idValue: String?
    var releases = [ReleaseRow(id: "", name: "", isDefault: true, vars: "")]
    /// How the distro writes Apple silicon in its addresses ({arch}).
    var arm64 = "aarch64"
    /// The checksum file is found in a directory listing (`checksumsURL` is
    /// the listing, `indexPattern` names the file in it).
    var useIndex = false
    var checksumsURL = ""
    var indexPattern = ""
    var checksumFormat: ChecksumFile.Format = .gnu
    var algorithm: ChecksumFile.Algorithm = .sha256
    var signature: DistroConfig.SignatureKind = .detached
    var signatureURL = DistroDraft.defaultSignatureURL
    /// Armored public key(s), as pasted or read from a key file.
    var publicKey = ""
    /// Why the images are not signed (signature none), optional.
    var note = ""
    var file = ""
    /// Where the image is, if not next to its checksum file ("" = {dir}{file}).
    var imageURL = ""
    var format: DistroConfig.ImageFormat = .qcow2
    var member = ""
    /// The published image is compressed (.xz, .gz).
    var compression: DistroConfig.Compression?
    var packageManager = ""
    var sshd = ""
    /// No checksum file: `imageURL` is the image itself, used as it is.
    var direct = false
    /// Simple's one field: where the image is, as the user gave it.
    var link = ""
    /// How the checksum file found next to the image is signed: a key makes
    /// the signature checked, no key leaves it unchecked.
    private var foundSignature: DistroConfig.SignatureKind = .none
    /// The name and version last taken from an image's name: replaced by
    /// the next image's while the user has not changed them.
    private var guessed: (name: String, release: String)?

    static func == (a: DistroDraft, b: DistroDraft) -> Bool {
        a.name == b.name && a.idValue == b.idValue && a.releases == b.releases && a.arm64 == b.arm64
            && a.useIndex == b.useIndex && a.checksumsURL == b.checksumsURL && a.indexPattern == b.indexPattern
            && a.checksumFormat == b.checksumFormat && a.algorithm == b.algorithm && a.signature == b.signature
            && a.signatureURL == b.signatureURL && a.publicKey == b.publicKey && a.note == b.note && a.file == b.file
            && a.imageURL == b.imageURL && a.format == b.format && a.member == b.member && a.compression == b.compression
            && a.packageManager == b.packageManager && a.sshd == b.sshd && a.direct == b.direct && a.link == b.link
            && a.foundSignature == b.foundSignature
    }

    /// The image is in the same folder as its checksum file.
    static let besideChecksums = "{dir}{file}"

    init() {}

    /// An added distro, to edit.
    init(_ c: DistroConfig) {
        name = c.name
        idValue = c.id
        releases = c.releases.map {
            ReleaseRow(id: $0.id, name: $0.name, isDefault: $0.isDefault == true,
                       vars: ($0.vars ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        }
        arm64 = c.architectures["arm64"] ?? ""
        direct = c.image.checksums == nil
        useIndex = c.image.checksums?.index != nil
        checksumsURL = c.image.checksums?.url ?? c.image.checksums?.index ?? ""
        indexPattern = c.image.checksums?.pattern ?? ""
        checksumFormat = c.image.checksums?.format ?? .gnu
        algorithm = c.image.checksums?.algorithm ?? .sha256
        signature = c.image.signature.kind
        foundSignature = c.image.signature.kind
        signatureURL = c.image.signature.url ?? (c.image.signature.kind == .detached ? "" : "{checksums}.asc")
        publicKey = (c.image.signature.publicKeys ?? []).joined(separator: "\n")
        note = c.image.signature.note ?? ""
        file = c.image.file
        imageURL = c.image.url == Self.besideChecksums ? "" : c.image.url
        format = c.image.format
        member = c.image.member ?? ""
        compression = c.image.compression
        packageManager = c.guest.packageManager ?? ""
        sshd = c.guest.sshd ?? ""
        link = simpleLink ?? ""
    }

    // MARK: Simple

    /// The link Simple shows for this draft: the image itself, or the
    /// image named literally beside a checksum file named literally.
    private var simpleLink: String? {
        let text: String
        if direct {
            text = imageURL
        } else {
            let sums = Self.trim(checksumsURL), image = Self.trim(file)
            guard !useIndex, Self.trim(imageURL).isEmpty, Self.isLiteral(sums), Self.isLiteral(image), !image.isEmpty,
                  let u = URL(string: sums) else { return nil }
            text = u.deletingLastPathComponent().appendingPathComponent(image).absoluteString
        }
        guard let link = try? ImageLink(Self.trim(text)) else { return nil }
        return link.isLocal ? link.url.path : link.url.absoluteString
    }

    private static func isLiteral(_ s: String) -> Bool { !s.contains { "{}*?".contains($0) } }

    /// The image at `link`, with what Monad found next to it. The name and
    /// version come from its file name unless the user gave their own.
    mutating func use(_ link: ImageLink, found: ImageDiscovery) {
        let g = link.guess
        if Self.trim(name).isEmpty || name == guessed?.name { name = g.name }
        if Self.trim(basicRelease).isEmpty || basicRelease == guessed?.release { basicRelease = g.release }
        guessed = g
        self.link = link.isLocal ? link.url.path : link.url.absoluteString
        format = link.format
        compression = link.compression
        member = ""
        useIndex = false
        indexPattern = ""
        arm64 = "aarch64"
        file = link.file
        if let c = found.checksums {
            direct = false
            imageURL = ""
            checksumsURL = c.url.absoluteString
            checksumFormat = c.format
            algorithm = c.algorithm
            foundSignature = c.signature
            signatureURL = Self.defaultSignatureURL
            if let sig = c.signatureURL?.absoluteString, sig.hasPrefix(c.url.absoluteString) {
                signatureURL = "{checksums}" + sig.dropFirst(c.url.absoluteString.count)
            }
            signature = Self.trim(publicKey).isEmpty ? .none : c.signature
        } else {
            direct = true
            imageURL = link.url.absoluteString
            checksumsURL = ""
            foundSignature = .none
            signature = .none
        }
    }

    /// Simple shows the link again (after Advanced).
    mutating func showLink() { link = simpleLink ?? link }

    /// The checksum file next to the image is signed: Simple offers its key.
    var signatureFound: Bool { !direct && foundSignature != .none }

    /// Simple's key: with one the signature is checked, without it is not.
    mutating func setKey(_ key: String) {
        publicKey = key
        guard !direct else { return }
        signature = Self.trim(key).isEmpty ? .none : (foundSignature == .none ? .detached : foundSignature)
    }

    // MARK: Basic and Advanced

    /// The Basic form's one release: the default one's id.
    var basicRelease: String {
        get { releases.first(where: \.isDefault)?.id ?? releases.first?.id ?? "" }
        set {
            if let i = releases.firstIndex(where: \.isDefault) ?? releases.indices.first {
                releases[i].id = newValue
            } else {
                releases = [ReleaseRow(id: newValue, name: "", isDefault: true, vars: "")]
            }
        }
    }

    static let defaultSignatureURL = "{checksums}.asc"

    /// The draft has something only the Advanced form shows (Edit… opens
    /// there then): Simple shows an image's link, a name, a version and a
    /// key.
    var needsAdvanced: Bool {
        let signatureShown = signature != .detached || (signatureURL.hasPrefix("{checksums}")
            && ImageLink.signatureSuffixes.contains(String(signatureURL.dropFirst("{checksums}".count))))
        return releases.count > 1 || releases.contains { !Self.trim($0.vars).isEmpty }
            || id != Self.slug(name) || Self.trim(arm64) != "aarch64" || format == .tarXz || !Self.trim(sshd).isEmpty
            || !signatureShown || (hasImage && simpleLink == nil)
    }

    /// Where the image is has been given (a new draft has nothing yet).
    private var hasImage: Bool {
        direct ? !Self.trim(imageURL).isEmpty
            : !Self.trim(checksumsURL).isEmpty || !Self.trim(file).isEmpty || !Self.trim(imageURL).isEmpty
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Check

    /// Enough to fetch the checksum file: the image and the key may come
    /// after Check has read it.
    var canCheck: Bool { (try? probe()) != nil }

    /// The draft as far as fetching its checksum file goes.
    func probe() throws -> DistroConfig {
        var d = self
        if d.file.trimmingCharacters(in: .whitespaces).isEmpty { d.file = "*" }
        d.signature = .none
        return try d.config()
    }

    /// What the checksum file says about itself: how its lines look, which
    /// hash, whether it is signed inside. Returns the disk images it lists
    /// for this Mac, named with {release} and {arch} (first the ones that
    /// do not change from one build to the next, cloud images, short
    /// names), and takes the image if there is only one.
    mutating func learn(from text: String) throws -> [String] {
        guard let best = ImageDiscovery.layout(of: text) else {
            throw MonadError("This is not a checksum file: no line is a hash and a file name. Check its address.")
        }
        // One gnu line is also what "single" means: kept if it was chosen.
        if !(checksumFormat == .single && best.format == .gnu && best.file.entries.count == 1) { checksumFormat = best.format }
        algorithm = best.algorithm
        if signature != .none {
            signature = text.contains("-----BEGIN PGP SIGNED MESSAGE-----") ? .clearsigned
                : signature == .clearsigned ? .detached : signature
        }
        var names: [String] = []
        for e in best.file.entries where Self.isDiskImage(e.file) && !names.contains(e.file) {
            names.append(e.file)
        }
        let word = arm64.trimmingCharacters(in: .whitespaces)
        if !word.isEmpty, names.contains(where: { Self.hasToken($0, word) }) {
            names = names.filter { Self.hasToken($0, word) }
        }
        var choices: [String] = []
        for n in names {
            let t = template(n)
            if !choices.contains(t) { choices.append(t) }
        }
        let order = Dictionary(uniqueKeysWithValues: choices.enumerated().map { ($1, $0) })
        choices.sort { a, b in
            func key(_ s: String) -> (Int, Int, Int, Int) {
                (s.lowercased().contains("latest") ? 0 : 1, s.lowercased().contains("cloud") ? 0 : 1, s.count, order[s] ?? 0)
            }
            return key(a) < key(b)
        }
        if choices.count == 1 { pick(choices[0]) }
        return choices
    }

    /// An image from Check's list.
    mutating func pick(_ image: String) {
        file = image
        if let f = Self.imageFormat(ofFile: image) { format = f }
    }

    /// The format a file name says; nil when it says none (`.img` is often
    /// qcow2 inside).
    static func imageFormat(ofFile name: String) -> DistroConfig.ImageFormat? {
        let n = name.lowercased()
        if n.hasSuffix(".qcow2") { return .qcow2 }
        if n.hasSuffix(".raw") { return .raw }
        if n.hasSuffix(".tar.xz") { return .tarXz }
        return nil
    }

    static func isDiskImage(_ name: String) -> Bool {
        imageFormat(ofFile: name) != nil || name.lowercased().hasSuffix(".img")
    }

    /// A file name with the release and the arch word as placeholders: the
    /// release where it first stands alone, the arch word wherever it does.
    func template(_ file: String) -> String {
        var out = file
        let word = arm64.trimmingCharacters(in: .whitespaces)
        if !word.isEmpty { out = Self.replacingTokens(word, with: "{arch}", in: out, all: true) }
        let release = basicRelease.trimmingCharacters(in: .whitespaces)
        if !release.isEmpty { out = Self.replacingTokens(release, with: "{release}", in: out, all: false) }
        return out
    }

    private static let separators = Set("-_.")

    private static func hasToken(_ s: String, _ token: String) -> Bool {
        replacingTokens(token, with: "\u{0}", in: s, all: false) != s
    }

    /// `token` replaced where separators (or the ends) stand on both sides.
    private static func replacingTokens(_ token: String, with replacement: String, in s: String, all: Bool) -> String {
        var out = ""
        var rest = s[...]
        var done = false
        while !done, let r = rest.range(of: token) {
            let before = r.lowerBound == rest.startIndex ? (out.last ?? "-") : rest[rest.index(before: r.lowerBound)]
            let after = r.upperBound == rest.endIndex ? "-" : rest[r.upperBound]
            let alone = separators.contains(before) && separators.contains(after)
            out += rest[..<r.lowerBound]
            if alone {
                out += replacement
                done = !all
            } else {
                out += rest[r]
            }
            rest = rest[r.upperBound...]
        }
        return out + rest
    }

    /// The primary keys' fingerprints in `publicKey` (none if it does not parse).
    var fingerprints: [String] {
        guard let keys = try? OpenPGP.keys(from: Data(publicKey.utf8)) else { return [] }
        var out: [String] = []
        for k in keys where !out.contains(k.primaryFingerprint) { out.append(k.primaryFingerprint) }
        return out
    }

    /// Read the key from a file chosen instead of pasted.
    mutating func readKey(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count <= 64 << 10 else { throw DistroConfig.Invalid("\(url.lastPathComponent) is too large for a key") }
        publicKey = String(decoding: data, as: UTF8.self)
    }

    // MARK: The file

    /// The file. What was typed or pasted is trimmed (a space or a line
    /// break at an end is never meant).
    func config() throws -> DistroConfig {
        let t = Self.trim
        let signed = !direct && signature != .none
        let name = t(self.name)
        let imageAt = t(imageURL)
        let c = DistroConfig(
            schema: DistroConfig.schemaVersion, id: t(id), name: name,
            releases: releases.map {
                let vars = Self.vars($0.vars)
                let rid = t($0.id)
                let rname = t($0.name)
                return .init(id: rid, name: rname.isEmpty ? "\(name) \(rid)" : rname,
                             isDefault: $0.isDefault ? true : nil, vars: vars.isEmpty ? nil : vars)
            },
            architectures: ["arm64": t(arm64)],
            image: .init(
                checksums: direct ? nil : .init(url: useIndex ? nil : t(checksumsURL), index: useIndex ? t(checksumsURL) : nil,
                                                pattern: useIndex ? t(indexPattern) : nil, format: checksumFormat, algorithm: algorithm),
                signature: .init(kind: signed ? signature : .none, url: signed && signature == .detached ? t(signatureURL) : nil,
                                 keys: nil, fingerprints: signed ? fingerprints : nil,
                                 note: signed || t(note).isEmpty ? nil : t(note),
                                 publicKeys: signed ? [publicKey] : nil),
                file: t(file), url: direct || !imageAt.isEmpty ? imageAt : Self.besideChecksums, format: format,
                member: format == .tarXz ? t(member) : nil, compression: format == .tarXz ? nil : compression),
            guest: .init(sshd: t(sshd).isEmpty ? nil : t(sshd), packageManager: packageManager.isEmpty ? nil : packageManager))
        try c.validate(userFile: true)
        if signed { _ = try DistroCatalog(distros: [c], userFiles: true) { _ in nil }.trustedKeys(for: c) }
        return c
    }

    /// The file, as Save writes it (and DistroStore checks it again).
    func json() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(config())
    }

    // MARK: Problems

    /// What is wrong, by field, in the user's words; Monad's own validation
    /// speaks (as .other) once the fields themselves look right.
    var problems: [Field: String] {
        var p: [Field: String] = [:]
        if name.trimmingCharacters(in: .whitespaces).isEmpty { p[.name] = "Give it a name." }
        if id.range(of: "^[a-z][a-z0-9-]{0,31}$", options: .regularExpression) == nil {
            p[.id] = "Lowercase letters, digits and dashes, starting with a letter."
        }
        if releases.isEmpty || releases.contains(where: { $0.id.trimmingCharacters(in: .whitespaces).isEmpty }) {
            p[.releases] = "Which release? Its number or name, like 10 or 2026.1."
        } else if releases.filter(\.isDefault).count != 1 {
            p[.releases] = "Pick the release new VMs get by default."
        }
        let url = Self.trim(checksumsURL)
        if direct {
            let at = Self.trim(imageURL)
            if at.isEmpty {
                p[.link] = "Paste the image's address, or choose the file."
            } else if (try? DistroConfig.url(at, ["release": Self.trim(basicRelease), "arch": Self.trim(arm64)],
                                             allowFile: true)) == nil {
                p[.link] = "An http://, https:// address or a file on this Mac."
            }
        } else if url.isEmpty {
            p[.checksums] = "Where is its checksum file? An https:// address."
        } else if !url.hasPrefix("https://"), !url.hasPrefix("http://") {
            p[.checksums] = "An http:// or https:// address."
        } else if useIndex, Self.trim(indexPattern).isEmpty {
            p[.checksums] = "Which file in that listing? A name with * for what changes."
        }
        if !direct, Self.trim(file).isEmpty {
            p[.file] = "Which image? A file name as the checksum file lists it, * for what changes."
        }
        switch direct ? .none : signature {
        case .detached where signatureURL.isEmpty:
            p[.signature] = "Where is the signature? Usually {checksums}.asc or {checksums}.gpg."
        default: break
        }
        if !direct, signature != .none {
            if publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                p[.key] = "Paste its signing key, or choose the key file."
            } else if fingerprints.isEmpty {
                p[.key] = "This is not an OpenPGP public key (paste the whole -----BEGIN PGP PUBLIC KEY BLOCK----- text)."
            }
        }
        if p.isEmpty {
            do { _ = try config() } catch { p[.other] = DistroCatalog.describe(error) }
        }
        return p
    }

    /// Said under the form, not a problem: a signature and https are
    /// recommended, and the choice is the user's.
    var advice: String? {
        if direct { return "Nothing to check this image against: it is used as it is. Fine for an image you trust." }
        let plain = checksumsURL.hasPrefix("http://") || imageURL.hasPrefix("http://")
        switch (signature == .none, plain) {
        case (true, true):
            return "This address is plain http and nothing is signed: anything between this Mac and "
                + "that server could change the image. Fine on a network you trust."
        case (true, false):
            return "Without a signature Monad can only compare the image with checksums from the same server. "
                + "If the project signs its checksums, add its key."
        case (false, true):
            return "This address is plain http. The signature still vouches for the image."
        case (false, false):
            return nil
        }
    }

    /// The id is taken by one of Monad's own distros.
    static func problem(id: String, builtIn: Set<String>) -> String? {
        builtIn.contains(id) ? "That name is one of Monad's own distributions." : nil
    }

    /// An id from a name: lowercase, dashes, a letter first, 32 at most.
    static func slug(_ name: String) -> String {
        var out = ""
        for ch in name.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber { out.append(ch) } else if !out.hasSuffix("-") { out.append("-") }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if let first = out.first, !first.isLetter { out = "d-" + out }
        out = String(out.prefix(32))
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    private static func vars(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in text.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, !kv[0].isEmpty { out[kv[0]] = kv[1] }
        }
        return out
    }
}
