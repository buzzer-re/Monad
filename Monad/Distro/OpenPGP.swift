//
//  OpenPGP.swift — verify OpenPGP signatures on distro checksum files
//  (RFC 4880 v4 packets). Crypto comes from Apple frameworks: RSA PKCS#1 v1.5
//  from Security, Ed25519 and the hashes from CryptoKit. No third-party code.
//
//  Trust model: callers pass only the keys they trust (pinned by the primary
//  key fingerprint in a distro's configuration). Key files are bundled with
//  Monad, so key attributes (expiry, usage flags, revocation) are read from
//  them without re-verifying their self-signatures; any key packet in a
//  trusted block may sign if its flags allow it.
//
//  Supported: detached signatures (binary or armored) and cleartext-signed
//  messages; signature types 0x00 (binary) and 0x01 (text); RSA (>= 2048
//  bits) and EdDSA/Ed25519; SHA-256, SHA-384, SHA-512.
//

import CryptoKit
import Foundation
import Security

struct OpenPGPKey: Equatable, Sendable {
    enum Material: Equatable, Sendable {
        case rsa(modulus: [UInt8], exponent: [UInt8])
        case ed25519(Data)
        case unsupported(algorithm: Int)
    }

    /// Upper-case hex, 40 characters.
    let fingerprint: String
    let keyID: UInt64
    let created: Date
    var expires: Date?
    let material: Material
    let isSubkey: Bool
    let primaryFingerprint: String
    /// Key flags from the self-signature or binding (nil: none stated).
    var flags: UInt8?
    var revoked = false

    var canSign: Bool {
        if revoked { return false }
        if case .unsupported = material { return false }
        guard let flags else { return !isSubkey }
        return flags & 0x02 != 0
    }
}

struct OpenPGPVerification: Equatable, Sendable {
    let signerFingerprint: String
    let primaryFingerprint: String
    let created: Date
}

enum OpenPGPError: Error, Equatable, LocalizedError {
    case armor(String)
    case malformed(String)
    case unsupported(String)
    case noMatchingKey
    case badSignature
    case notYetValid
    case expiredSignature
    case expiredKey
    case revokedKey
    case weakKey

    var errorDescription: String? {
        switch self {
        case .armor(let m): return "Invalid OpenPGP armor: \(m)"
        case .malformed(let m): return "Malformed OpenPGP data: \(m)"
        case .unsupported(let m): return "Unsupported OpenPGP feature: \(m)"
        case .noMatchingKey: return "The signature was not made by a trusted key."
        case .badSignature: return "The signature does not match the data."
        case .notYetValid: return "The signature is dated in the future."
        case .expiredSignature: return "The signature has expired."
        case .expiredKey: return "The signing key had expired when the signature was made."
        case .revokedKey: return "The signing key is revoked."
        case .weakKey: return "The signing key is too weak."
        }
    }
}

enum OpenPGP {
    /// Clock skew tolerated for signatures dated slightly in the future.
    static let allowedSkew: TimeInterval = 300

    // MARK: Public API

    /// Every key (primary and subkeys) in armored or binary key data.
    static func keys(from data: Data) throws -> [OpenPGPKey] {
        let bytes = try unarmorIfNeeded(data, label: "PUBLIC KEY BLOCK")
        var keys: [OpenPGPKey] = []
        var primary: String?
        var current: Int? // index in keys of the key subsequent signatures describe
        var latestCert: [String: UInt32] = [:]
        for packet in try packets(bytes) {
            switch packet.tag {
            case 6, 14:
                guard let key = try parseKey(packet.body, isSubkey: packet.tag == 14, primary: primary) else {
                    current = nil
                    continue
                }
                if packet.tag == 6 { primary = key.fingerprint }
                keys.append(key)
                current = keys.count - 1
            case 2:
                guard let i = current, let sig = try? parseSignature(packet.body) else { continue }
                apply(sig, to: &keys[i], latestCert: &latestCert)
            default:
                continue
            }
        }
        guard !keys.isEmpty else { throw OpenPGPError.malformed("no public keys") }
        return keys
    }

    /// Verify a detached signature over `data`.
    @discardableResult
    static func verifyDetached(_ data: Data, signature: Data, keys: [OpenPGPKey],
                               now: Date = Date()) throws -> OpenPGPVerification {
        let sigBytes = try unarmorIfNeeded(signature, label: "SIGNATURE")
        let sigs = try packets(sigBytes).filter { $0.tag == 2 }.map { try parseSignature($0.body) }
        guard !sigs.isEmpty else { throw OpenPGPError.malformed("no signature packet") }
        return try verifyAny(sigs, keys: keys, now: now) { sig in
            switch sig.type {
            case 0x00: return Array(data)
            case 0x01: return canonicalText(Array(data))
            default: throw OpenPGPError.unsupported("signature type \(sig.type)")
            }
        }
    }

    /// Verify a cleartext-signed message; returns only the signed text (dash
    /// escaping and trailing whitespace removed, "\n" line endings, ending
    /// with a newline).
    static func verifyClearsigned(_ message: Data, keys: [OpenPGPKey],
                                  now: Date = Date()) throws -> (text: String, verification: OpenPGPVerification) {
        let parsed = try parseClearsigned(message)
        let sigs = try packets(parsed.signature).filter { $0.tag == 2 }.map { try parseSignature($0.body) }
        guard !sigs.isEmpty else { throw OpenPGPError.malformed("no signature packet") }
        for sig in sigs {
            guard sig.type == 0x01 else { throw OpenPGPError.malformed("cleartext signature is not a text signature") }
            if let allowed = parsed.hashes, !allowed.contains(sig.hash.name) {
                throw OpenPGPError.malformed("signature uses \(sig.hash.name), the message announces \(allowed)")
            }
        }
        // Trailing whitespace is not signed: what comes back is only what was.
        let canonical = parsed.lines.map { stripTrailingWhitespace($0) }
        let signed = Array(canonical.joined(separator: "\r\n").utf8)
        let v = try verifyAny(sigs, keys: keys, now: now) { _ in signed }
        return (canonical.joined(separator: "\n") + "\n", v)
    }

    // MARK: Verification

    private static func verifyAny(_ sigs: [Signature], keys: [OpenPGPKey], now: Date,
                                  data: (Signature) throws -> [UInt8]) throws -> OpenPGPVerification {
        var firstError: OpenPGPError?
        for sig in sigs {
            let candidates = keys.filter { key in
                if let fpr = sig.issuerFingerprint { return key.fingerprint == fpr }
                if let id = sig.issuerKeyID { return key.keyID == id }
                return true
            }
            if candidates.isEmpty { continue }
            do {
                return try verify(sig, data: data(sig), candidates: candidates, now: now)
            } catch let e as OpenPGPError {
                if firstError == nil { firstError = e }
            }
        }
        throw firstError ?? OpenPGPError.noMatchingKey
    }

    private static func verify(_ sig: Signature, data: [UInt8], candidates: [OpenPGPKey],
                               now: Date) throws -> OpenPGPVerification {
        if sig.created > now.addingTimeInterval(allowedSkew) { throw OpenPGPError.notYetValid }
        if let life = sig.lifetime, life > 0, sig.created.addingTimeInterval(TimeInterval(life)) <= now {
            throw OpenPGPError.expiredSignature
        }
        var hasher = sig.hash.hasher()
        hasher.update(data)
        hasher.update(sig.hashedPortion)
        let trailer = UInt32(sig.hashedPortion.count)
        hasher.update([0x04, 0xFF, UInt8(trailer >> 24), UInt8(trailer >> 16 & 0xFF), UInt8(trailer >> 8 & 0xFF),
                       UInt8(trailer & 0xFF)])
        let digest = hasher.finalize()
        guard digest.count >= 2, digest[0] == sig.left16[0], digest[1] == sig.left16[1] else {
            throw OpenPGPError.badSignature
        }
        var lastError = OpenPGPError.badSignature
        for key in candidates {
            if key.revoked { lastError = .revokedKey; continue }
            guard key.canSign else { lastError = .noMatchingKey; continue }
            guard key.created <= sig.created else { lastError = .badSignature; continue }
            if let expires = key.expires, sig.created >= expires { lastError = .expiredKey; continue }
            if try check(sig, digest: Data(digest), key: key) {
                return OpenPGPVerification(signerFingerprint: key.fingerprint,
                                           primaryFingerprint: key.primaryFingerprint, created: sig.created)
            }
        }
        throw lastError
    }

    private static func check(_ sig: Signature, digest: Data, key: OpenPGPKey) throws -> Bool {
        switch (key.material, sig.algorithm) {
        case (.rsa(let n, let e), 1), (.rsa(let n, let e), 3):
            guard sig.mpis.count == 1 else { throw OpenPGPError.malformed("RSA signature needs one integer") }
            return try verifyRSA(modulus: n, exponent: e, signature: sig.mpis[0], digest: digest, hash: sig.hash)
        case (.ed25519(let raw), 22):
            guard sig.mpis.count == 2, sig.mpis[0].count <= 32, sig.mpis[1].count <= 32 else {
                throw OpenPGPError.malformed("EdDSA signature needs two 32-byte integers")
            }
            let rs = leftPad(sig.mpis[0], to: 32) + leftPad(sig.mpis[1], to: 32)
            guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
            return pk.isValidSignature(Data(rs), for: digest)
        default:
            return false
        }
    }

    private static func verifyRSA(modulus: [UInt8], exponent: [UInt8], signature: [UInt8], digest: Data,
                                  hash: HashAlgorithm) throws -> Bool {
        let n = Array(modulus.drop { $0 == 0 })
        let bits = n.count * 8 - (n.first.map { $0.leadingZeroBitCount } ?? 8)
        guard bits >= 2048 else { throw OpenPGPError.weakKey }
        guard signature.count <= n.count else { return false }
        let der = asn1Sequence([asn1Integer(n), asn1Integer(exponent)])
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic,
                                      kSecAttrKeySizeInBits: bits]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(der) as CFData, attrs as CFDictionary, &error) else {
            throw OpenPGPError.malformed("unusable RSA key")
        }
        let sigData = Data(leftPad(signature, to: n.count))
        return SecKeyVerifySignature(key, hash.rsaAlgorithm, digest as CFData, sigData as CFData, &error)
    }

    // MARK: Hashes

    enum HashAlgorithm: Equatable {
        case sha256, sha384, sha512

        init(id: Int) throws {
            switch id {
            case 8: self = .sha256
            case 9: self = .sha384
            case 10: self = .sha512
            case 1, 2, 3: throw OpenPGPError.unsupported("weak hash algorithm \(id)")
            default: throw OpenPGPError.unsupported("hash algorithm \(id)")
            }
        }

        var name: String {
            switch self {
            case .sha256: return "SHA256"
            case .sha384: return "SHA384"
            case .sha512: return "SHA512"
            }
        }

        var rsaAlgorithm: SecKeyAlgorithm {
            switch self {
            case .sha256: return .rsaSignatureDigestPKCS1v15SHA256
            case .sha384: return .rsaSignatureDigestPKCS1v15SHA384
            case .sha512: return .rsaSignatureDigestPKCS1v15SHA512
            }
        }

        func hasher() -> AnyHasher { AnyHasher(self) }
    }

    struct AnyHasher {
        private var s256 = SHA256()
        private var s384 = SHA384()
        private var s512 = SHA512()
        private let kind: HashAlgorithm

        init(_ kind: HashAlgorithm) { self.kind = kind }

        mutating func update(_ bytes: [UInt8]) {
            switch kind {
            case .sha256: s256.update(data: bytes)
            case .sha384: s384.update(data: bytes)
            case .sha512: s512.update(data: bytes)
            }
        }

        func finalize() -> [UInt8] {
            switch kind {
            case .sha256: return Array(s256.finalize())
            case .sha384: return Array(s384.finalize())
            case .sha512: return Array(s512.finalize())
            }
        }
    }

    // MARK: Packets

    struct Packet {
        let tag: Int
        let body: [UInt8]
    }

    static func packets(_ b: [UInt8]) throws -> [Packet] {
        var out: [Packet] = []
        var i = 0
        while i < b.count {
            let h = b[i]
            guard h & 0x80 != 0 else { throw OpenPGPError.malformed("not a packet header") }
            i += 1
            var tag: Int
            var length: Int
            if h & 0x40 != 0 { // new format
                tag = Int(h & 0x3F)
                guard i < b.count else { throw OpenPGPError.malformed("truncated packet length") }
                let o = Int(b[i])
                if o < 192 {
                    length = o
                    i += 1
                } else if o < 224 {
                    guard i + 1 < b.count else { throw OpenPGPError.malformed("truncated packet length") }
                    length = ((o - 192) << 8) + Int(b[i + 1]) + 192
                    i += 2
                } else if o == 255 {
                    guard i + 4 < b.count else { throw OpenPGPError.malformed("truncated packet length") }
                    length = Int(b[i + 1]) << 24 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 8 | Int(b[i + 4])
                    i += 5
                } else {
                    throw OpenPGPError.unsupported("partial body lengths")
                }
            } else { // old format
                tag = Int(h >> 2 & 0x0F)
                switch h & 3 {
                case 0:
                    guard i < b.count else { throw OpenPGPError.malformed("truncated packet length") }
                    length = Int(b[i])
                    i += 1
                case 1:
                    guard i + 1 < b.count else { throw OpenPGPError.malformed("truncated packet length") }
                    length = Int(b[i]) << 8 | Int(b[i + 1])
                    i += 2
                case 2:
                    guard i + 3 < b.count else { throw OpenPGPError.malformed("truncated packet length") }
                    length = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
                    i += 4
                default:
                    throw OpenPGPError.unsupported("indeterminate packet length")
                }
            }
            guard length >= 0, length <= b.count - i else { throw OpenPGPError.malformed("packet longer than its data") }
            out.append(Packet(tag: tag, body: Array(b[i..<i + length])))
            i += length
        }
        return out
    }

    /// A reader over packet bytes that throws instead of reading past the end.
    struct Reader {
        let b: [UInt8]
        var i = 0

        init(_ b: [UInt8]) { self.b = b }

        var remaining: Int { b.count - i }

        mutating func u8() throws -> Int {
            guard i < b.count else { throw OpenPGPError.malformed("truncated packet") }
            defer { i += 1 }
            return Int(b[i])
        }

        mutating func u16() throws -> Int { try u8() << 8 | u8() }

        mutating func u32() throws -> UInt32 {
            UInt32(try u16()) << 16 | UInt32(try u16())
        }

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard n >= 0, n <= remaining else { throw OpenPGPError.malformed("truncated packet") }
            defer { i += n }
            return Array(b[i..<i + n])
        }

        mutating func mpi() throws -> [UInt8] {
            let bits = try u16()
            return try bytes((bits + 7) / 8)
        }
    }

    // MARK: Keys

    private static let ed25519OID: [UInt8] = [0x2B, 0x06, 0x01, 0x04, 0x01, 0xDA, 0x47, 0x0F, 0x01]

    /// A v4 public key or subkey; nil for key versions this code does not handle.
    private static func parseKey(_ body: [UInt8], isSubkey: Bool, primary: String?) throws -> OpenPGPKey? {
        var r = Reader(body)
        guard try r.u8() == 4 else { return nil }
        let created = Date(timeIntervalSince1970: TimeInterval(try r.u32()))
        let algorithm = try r.u8()
        let material: OpenPGPKey.Material
        switch algorithm {
        case 1, 3:
            let n = try r.mpi()
            let e = try r.mpi()
            material = .rsa(modulus: n, exponent: e)
        case 22:
            let oidLen = try r.u8()
            let oid = try r.bytes(oidLen)
            let point = try r.mpi()
            if oid == ed25519OID, point.count == 33, point[0] == 0x40 {
                material = .ed25519(Data(point[1...]))
            } else {
                material = .unsupported(algorithm: algorithm)
            }
        default:
            material = .unsupported(algorithm: algorithm)
        }
        var fp = Insecure.SHA1()
        fp.update(data: [0x99, UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)])
        fp.update(data: body)
        let digest = Array(fp.finalize())
        let fingerprint = digest.map { String(format: "%02X", $0) }.joined()
        let keyID = digest.suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        if isSubkey && primary == nil { throw OpenPGPError.malformed("subkey without a primary key") }
        return OpenPGPKey(fingerprint: fingerprint, keyID: keyID, created: created, expires: nil, material: material,
                          isSubkey: isSubkey, primaryFingerprint: isSubkey ? primary! : fingerprint)
    }

    /// Key attributes from self-signatures (0x10-0x13, 0x1F), subkey bindings
    /// (0x18) and revocations (0x20, 0x28). The newest self-signature wins.
    private static func apply(_ sig: Signature, to key: inout OpenPGPKey, latestCert: inout [String: UInt32]) {
        switch sig.type {
        case 0x20, 0x28:
            key.revoked = true
        case 0x10...0x13, 0x18, 0x1F:
            let stamp = UInt32(sig.created.timeIntervalSince1970)
            if let seen = latestCert[key.fingerprint], seen > stamp { return }
            latestCert[key.fingerprint] = stamp
            key.expires = sig.keyLifetime.flatMap { $0 > 0 ? key.created.addingTimeInterval(TimeInterval($0)) : nil }
            if let f = sig.keyFlags { key.flags = f }
        default:
            break
        }
    }

    // MARK: Signatures

    struct Signature {
        let type: Int
        let algorithm: Int
        let hash: HashAlgorithm
        let hashedPortion: [UInt8]
        let created: Date
        let lifetime: UInt32?
        let keyLifetime: UInt32?
        let keyFlags: UInt8?
        let issuerFingerprint: String?
        let issuerKeyID: UInt64?
        let left16: [UInt8]
        let mpis: [[UInt8]]
    }

    private static let knownSubpackets: Set<Int> = [2, 3, 4, 5, 7, 9, 11, 12, 16, 21, 22, 23, 24, 25, 26, 27, 28,
                                                     30, 31, 32, 33, 34, 35]

    static func parseSignature(_ body: [UInt8]) throws -> Signature {
        var r = Reader(body)
        let version = try r.u8()
        guard version == 4 else { throw OpenPGPError.unsupported("signature version \(version)") }
        let type = try r.u8()
        let algorithm = try r.u8()
        let hashID = try r.u8()
        let hashedLength = try r.u16()
        let hashed = try r.bytes(hashedLength)
        let hashedPortion = Array(body[0..<(6 + hashedLength)])
        let unhashed = try r.bytes(try r.u16())
        let left16 = try r.bytes(2)
        var mpis: [[UInt8]] = []
        while r.remaining > 0 { mpis.append(try r.mpi()) }

        var created: UInt32?
        var lifetime: UInt32?
        var keyLifetime: UInt32?
        var flags: UInt8?
        var fingerprint: String?
        var keyID: UInt64?
        func walk(_ area: [UInt8], hashed: Bool) throws {
            var s = Reader(area)
            while s.remaining > 0 {
                let o = try s.u8()
                var len: Int
                if o < 192 {
                    len = o
                } else if o < 255 {
                    len = ((o - 192) << 8) + (try s.u8()) + 192
                } else {
                    len = Int(try s.u32())
                }
                guard len >= 1 else { throw OpenPGPError.malformed("empty subpacket") }
                var p = Reader(try s.bytes(len))
                let raw = try p.u8()
                let kind = raw & 0x7F
                let critical = raw & 0x80 != 0
                if critical && hashed && !knownSubpackets.contains(kind) {
                    throw OpenPGPError.unsupported("critical subpacket \(kind)")
                }
                switch kind {
                case 2 where hashed: created = try p.u32()
                case 3 where hashed: lifetime = try p.u32()
                case 9 where hashed: keyLifetime = try p.u32()
                case 27 where hashed: flags = p.remaining > 0 ? UInt8(try p.u8()) : 0
                case 16: keyID = try p.bytes(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                case 33:
                    let v = try p.u8()
                    if v == 4 { fingerprint = try p.bytes(20).map { String(format: "%02X", $0) }.joined() }
                default: break
                }
            }
        }
        try walk(hashed, hashed: true)
        try walk(unhashed, hashed: false)
        guard let created else { throw OpenPGPError.malformed("signature without a creation time") }
        return Signature(type: type, algorithm: algorithm, hash: try HashAlgorithm(id: hashID),
                         hashedPortion: hashedPortion, created: Date(timeIntervalSince1970: TimeInterval(created)),
                         lifetime: lifetime, keyLifetime: keyLifetime, keyFlags: flags,
                         issuerFingerprint: fingerprint, issuerKeyID: keyID, left16: left16, mpis: mpis)
    }

    // MARK: Text

    /// Line endings converted to CRLF (signature type 0x01).
    static func canonicalText(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count + b.count / 32)
        var prev: UInt8 = 0
        for c in b {
            if c == 0x0A && prev != 0x0D { out.append(0x0D) }
            out.append(c)
            prev = c
        }
        return out
    }

    private static func stripTrailingWhitespace(_ s: String) -> String {
        var t = Substring(s)
        while let last = t.last, last == " " || last == "\t" { t = t.dropLast() }
        return String(t)
    }

    // MARK: Armor

    /// Lines split at LF bytes, a trailing CR removed. (Splitting a String
    /// would not work: Swift treats CRLF as one Character.)
    private static func lines(_ data: Data) throws -> [String] {
        try data.split(separator: 0x0A, omittingEmptySubsequences: false).map { raw in
            let line = raw.last == 0x0D ? raw.dropLast() : raw
            guard let s = String(data: Data(line), encoding: .utf8) else { throw OpenPGPError.armor("not UTF-8 text") }
            return s
        }
    }

    private static func unarmorIfNeeded(_ data: Data, label: String) throws -> [UInt8] {
        guard let first = data.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }) else {
            throw OpenPGPError.malformed("empty input")
        }
        if first != UInt8(ascii: "-") { return Array(data) }
        let all = try lines(data)
        guard let start = all.firstIndex(of: "-----BEGIN PGP \(label)-----") else {
            throw OpenPGPError.armor("missing BEGIN PGP \(label)")
        }
        return try decodeArmorBody(all, from: start + 1, end: "-----END PGP \(label)-----")
    }

    /// Armor headers, blank line, base64, optional "=CRC24", END line.
    private static func decodeArmorBody(_ lines: [String], from start: Int, end: String) throws -> [UInt8] {
        var i = start
        while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            guard lines[i].contains(": ") else { throw OpenPGPError.armor("bad armor header") }
            i += 1
        }
        i += 1
        var base64 = ""
        var crc: String?
        while i < lines.count, lines[i] != end {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("=") {
                crc = String(line.dropFirst())
            } else if crc == nil {
                base64 += line
            } else if !line.isEmpty {
                throw OpenPGPError.armor("data after the checksum")
            }
            i += 1
        }
        guard i < lines.count else { throw OpenPGPError.armor("missing \(end)") }
        guard let decoded = Data(base64Encoded: base64) else { throw OpenPGPError.armor("bad base64") }
        let bytes = Array(decoded)
        if let crc {
            guard let expected = Data(base64Encoded: crc), expected.count == 3 else {
                throw OpenPGPError.armor("bad checksum line")
            }
            let v = crc24(bytes)
            guard expected[0] == UInt8(v >> 16 & 0xFF), expected[1] == UInt8(v >> 8 & 0xFF),
                  expected[2] == UInt8(v & 0xFF) else { throw OpenPGPError.armor("checksum mismatch") }
        }
        guard !bytes.isEmpty else { throw OpenPGPError.armor("empty body") }
        return bytes
    }

    static func crc24(_ b: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xB704CE
        for byte in b {
            crc ^= UInt32(byte) << 16
            for _ in 0..<8 {
                crc <<= 1
                if crc & 0x1000000 != 0 { crc ^= 0x1864CFB }
            }
        }
        return crc & 0xFFFFFF
    }

    private struct Clearsigned {
        let hashes: [String]?
        let lines: [String]
        let signature: [UInt8]
    }

    private static func parseClearsigned(_ data: Data) throws -> Clearsigned {
        let all = try lines(data)
        let begin = "-----BEGIN PGP SIGNED MESSAGE-----"
        guard let start = all.firstIndex(of: begin) else { throw OpenPGPError.armor("not a cleartext-signed message") }
        guard all[(start + 1)...].firstIndex(of: begin) == nil else {
            throw OpenPGPError.armor("more than one signed message")
        }
        var i = start + 1
        var hashes: [String]?
        while i < all.count, !all[i].trimmingCharacters(in: .whitespaces).isEmpty {
            let line = all[i]
            guard line.hasPrefix("Hash: ") else { throw OpenPGPError.armor("unexpected header \(line)") }
            let names = line.dropFirst(6).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            hashes = (hashes ?? []) + names
            i += 1
        }
        guard i < all.count else { throw OpenPGPError.armor("missing message") }
        i += 1
        var message: [String] = []
        let sigBegin = "-----BEGIN PGP SIGNATURE-----"
        while i < all.count, all[i] != sigBegin {
            var line = all[i]
            if line.hasPrefix("- ") {
                line.removeFirst(2)
            } else if line.hasPrefix("-") {
                throw OpenPGPError.armor("unescaped dash line in the signed text")
            }
            message.append(line)
            i += 1
        }
        guard i < all.count else { throw OpenPGPError.armor("missing signature") }
        let signature = try decodeArmorBody(all, from: i + 1, end: "-----END PGP SIGNATURE-----")
        return Clearsigned(hashes: hashes, lines: message, signature: signature)
    }

    // MARK: ASN.1 (RSA public key for Security.framework)

    private static func asn1Length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private static func asn1Integer(_ magnitude: [UInt8]) -> [UInt8] {
        var v = Array(magnitude.drop { $0 == 0 })
        if v.isEmpty { v = [0] }
        if v[0] & 0x80 != 0 { v.insert(0, at: 0) }
        return [0x02] + asn1Length(v.count) + v
    }

    private static func asn1Sequence(_ parts: [[UInt8]]) -> [UInt8] {
        let body = parts.flatMap { $0 }
        return [0x30] + asn1Length(body.count) + body
    }

    private static func leftPad(_ b: [UInt8], to n: Int) -> [UInt8] {
        b.count >= n ? Array(b.suffix(n)) : [UInt8](repeating: 0, count: n - b.count) + b
    }
}
