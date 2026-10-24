//
//  TestSigner.swift — builds OpenPGP v4 Ed25519 keys and signatures in tests:
//  arbitrary subpackets for the verifier's edge cases, and signed checksum
//  files for the image pipeline.
//

import CryptoKit
import Foundation
@testable import Monad

/// Builds v4 Ed25519 keys and signatures with arbitrary subpackets, for the
/// cases real keys never exercise (expiry, revocation, critical subpackets).
struct TestSigner {
    let key = Curve25519.Signing.PrivateKey()
    let created: UInt32

    init(created: UInt32 = 1_700_000_000) { self.created = created }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    static func mpi(_ b: [UInt8]) -> [UInt8] {
        let t = Array(b.drop { $0 == 0 })
        let bits = t.isEmpty ? 0 : (t.count - 1) * 8 + (8 - t[0].leadingZeroBitCount)
        return be16(bits) + t
    }

    static func packet(_ tag: Int, _ body: [UInt8]) -> [UInt8] {
        [0xC0 | UInt8(tag), 0xFF] + be32(UInt32(body.count)) + body
    }

    static func sub(_ type: Int, _ data: [UInt8], critical: Bool = false) -> [UInt8] {
        [UInt8(data.count + 1), UInt8(type) | (critical ? 0x80 : 0)] + data
    }

    var keyBody: [UInt8] {
        let oid: [UInt8] = [0x2B, 0x06, 0x01, 0x04, 0x01, 0xDA, 0x47, 0x0F, 0x01]
        return [4] + Self.be32(created) + [22, UInt8(oid.count)] + oid + Self.mpi([0x40] + Array(key.publicKey.rawRepresentation))
    }

    var fingerprint: [UInt8] {
        var h = Insecure.SHA1()
        h.update(data: [0x99] + Self.be16(keyBody.count) + keyBody)
        return Array(h.finalize())
    }

    func signature(over data: [UInt8], type: UInt8 = 0, hash: UInt8 = 10, at time: UInt32,
                   hashed extra: [[UInt8]] = []) -> [UInt8] {
        let hashedArea = Self.sub(2, Self.be32(time)) + extra.flatMap { $0 }
        let portion: [UInt8] = [4, type, 22, hash] + Self.be16(hashedArea.count) + hashedArea
        var hasher = SHA512()
        hasher.update(data: data + portion + [4, 0xFF] + Self.be32(UInt32(portion.count)))
        let digest = Array(hasher.finalize())
        let rs = Array(try! key.signature(for: Data(digest)))
        let unhashed = Self.sub(33, [4] + fingerprint)
        return Self.packet(2, portion + Self.be16(unhashed.count) + unhashed + digest.prefix(2)
            + Self.mpi(Array(rs[0..<32])) + Self.mpi(Array(rs[32..<64])))
    }

    /// Key block: key, user ID, self-signature (flags, lifetime), optional revocation.
    func keyBlock(flags: UInt8 = 0x03, lifetime: UInt32? = nil, revoked: Bool = false) -> Data {
        var hashed = [Self.sub(27, [flags])]
        if let lifetime { hashed.append(Self.sub(9, Self.be32(lifetime))) }
        var out = Self.packet(6, keyBody) + Self.packet(13, Array("test".utf8))
        out += signature(over: [], type: 0x13, at: created, hashed: hashed)
        if revoked { out += signature(over: [], type: 0x20, at: created + 1) }
        return Data(out)
    }

    var fingerprintHex: String { fingerprint.map { String(format: "%02X", $0) }.joined() }

    static func armor(_ label: String, _ bytes: [UInt8], headers: String = "") -> String {
        let crc = OpenPGP.crc24(bytes)
        let crcBytes = Data([UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)])
        let body = Data(bytes).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PGP \(label)-----\n\(headers)\n\(body)\n=\(crcBytes.base64EncodedString())\n-----END PGP \(label)-----\n"
    }

    /// Armored key block for a key file.
    var armoredKey: String { Self.armor("PUBLIC KEY BLOCK", Array(keyBlock())) }

    /// Armored detached binary signature over `data`.
    func detachedSignature(over data: Data, at time: UInt32? = nil) -> Data {
        Data(Self.armor("SIGNATURE", signature(over: Array(data), at: time ?? created + 10)).utf8)
    }

    /// A cleartext-signed message (text signature, SHA-512).
    func clearsign(_ text: String, at time: UInt32? = nil) -> Data {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let canonical = lines.map { l -> String in
            var t = Substring(l)
            while let c = t.last, c == " " || c == "\t" { t = t.dropLast() }
            return String(t)
        }.joined(separator: "\r\n")
        let sig = signature(over: Array(canonical.utf8), type: 0x01, at: time ?? created + 10)
        let escaped = lines.map { $0.hasPrefix("-") ? "- " + $0 : $0 }.joined(separator: "\n")
        return Data(("-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA512\n\n" + escaped + "\n"
            + Self.armor("SIGNATURE", sig)).utf8)
    }
}
