//
//  OpenPGPTests.swift — signature verification for distro checksum files.
//  Real signed files from Ubuntu, Fedora and openSUSE (verified with gpgv
//  when the fixtures were collected) plus GnuPG-generated Ed25519, subkey
//  and text-mode cases.
//

import CryptoKit
import XCTest
@testable import Monad

final class OpenPGPTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil), "missing \(name)")
        return try Data(contentsOf: url)
    }

    private func keys(_ name: String) throws -> [OpenPGPKey] {
        try OpenPGP.keys(from: fixture(name))
    }

    /// A time after every fixture signature and before any key expires.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func flip(_ data: Data, at index: Int) -> Data {
        var d = data
        d[index] ^= 0x01
        return d
    }

    // MARK: Keys

    func testKeyFingerprintsAndDates() throws {
        let ubuntu = try keys("pgp_key_ubuntu_cloud.asc")
        XCTAssertEqual(ubuntu.first?.fingerprint, "D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81")
        XCTAssertEqual(ubuntu.first?.created, Date(timeIntervalSince1970: 1_253_058_869))
        XCTAssertFalse(ubuntu.first?.isSubkey ?? true)

        let fedora = try keys("pgp_key_fedora44.asc")
        XCTAssertEqual(fedora.map(\.fingerprint), ["36F612DCF27F7D1A48A835E4DBFCF71C6D9F90A6"])
        XCTAssertNil(fedora.first?.expires)

        let suse = try keys("pgp_key_opensuse.asc")
        XCTAssertEqual(suse.first?.fingerprint, "AD485664E901B867051AB15F35A2F86E29B700A4")
        XCTAssertEqual(suse.first?.expires, Date(timeIntervalSince1970: 1_906_100_280))
    }

    func testSubkeysKnowTheirPrimary() throws {
        let k = try keys("pgp_key_gen_rsa_subkey.asc")
        XCTAssertEqual(k.map(\.fingerprint), ["7F058A4A3E8B408DD2231AF0208E6B5CA1F01AEC",
                                              "6B4ABEAC4E8DD09F885F5AFAC04AD05C98FA253C"])
        XCTAssertEqual(k.map(\.isSubkey), [false, true])
        XCTAssertEqual(Set(k.map(\.primaryFingerprint)), ["7F058A4A3E8B408DD2231AF0208E6B5CA1F01AEC"])
    }

    func testEd25519Key() throws {
        let k = try keys("pgp_key_gen_ed25519.asc")
        XCTAssertEqual(k.first?.fingerprint, "0E8B00D50C27A91DD03A479CDF3E4AB18B346476")
        guard case .ed25519(let raw) = k.first?.material else { return XCTFail("\(String(describing: k.first))") }
        XCTAssertEqual(raw.count, 32)
    }

    // MARK: Real distro signatures

    func testUbuntuDetachedArmoredSignature() throws {
        let v = try OpenPGP.verifyDetached(fixture("pgp_ubuntu_SHA256SUMS"), signature: fixture("pgp_ubuntu_SHA256SUMS.gpg"),
                                           keys: keys("pgp_key_ubuntu_cloud.asc"), now: now)
        XCTAssertEqual(v.primaryFingerprint, "D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81")
        XCTAssertEqual(v.created, Date(timeIntervalSince1970: 1_790_642_640))
    }

    func testOpenSUSEDetachedArmoredSignature() throws {
        let v = try OpenPGP.verifyDetached(fixture("pgp_opensuse_leap.sha256"), signature: fixture("pgp_opensuse_leap.sha256.asc"),
                                           keys: keys("pgp_key_opensuse.asc"), now: now)
        XCTAssertEqual(v.primaryFingerprint, "AD485664E901B867051AB15F35A2F86E29B700A4")
    }

    func testFedoraClearsignedChecksumFile() throws {
        let (text, v) = try OpenPGP.verifyClearsigned(fixture("pgp_fedora44_CHECKSUM"), keys: keys("pgp_key_fedora44.asc"),
                                                      now: now)
        XCTAssertEqual(v.primaryFingerprint, "36F612DCF27F7D1A48A835E4DBFCF71C6D9F90A6")
        XCTAssertTrue(text.contains("SHA256 (Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2) = 55c60a3b"))
        XCTAssertFalse(text.contains("BEGIN PGP"), "only the signed text is returned")
    }

    func testTamperedDataFails() throws {
        let sums = try fixture("pgp_ubuntu_SHA256SUMS")
        XCTAssertThrowsError(try OpenPGP.verifyDetached(flip(sums, at: 100), signature: fixture("pgp_ubuntu_SHA256SUMS.gpg"),
                                                        keys: keys("pgp_key_ubuntu_cloud.asc"), now: now)) {
            XCTAssertEqual($0 as? OpenPGPError, .badSignature)
        }
        var fedora = String(decoding: try fixture("pgp_fedora44_CHECKSUM"), as: UTF8.self)
        fedora = fedora.replacingOccurrences(of: "55c60a3b", with: "55c60a3c")
        XCTAssertThrowsError(try OpenPGP.verifyClearsigned(Data(fedora.utf8), keys: keys("pgp_key_fedora44.asc"), now: now)) {
            XCTAssertEqual($0 as? OpenPGPError, .badSignature)
        }
    }

    func testTamperedSignatureFails() throws {
        let sig = try fixture("pgp_opensuse_leap.sha256.asc")
        // Change one base64 character inside the signature body; the armor CRC catches it.
        var text = String(decoding: sig, as: UTF8.self)
        let range = try XCTUnwrap(text.range(of: "iQIz"))
        text.replaceSubrange(range, with: "iQIy")
        XCTAssertThrowsError(try OpenPGP.verifyDetached(fixture("pgp_opensuse_leap.sha256"), signature: Data(text.utf8),
                                                        keys: keys("pgp_key_opensuse.asc"), now: now))
    }

    func testOnlyTheGivenKeysAreTrusted() throws {
        XCTAssertThrowsError(try OpenPGP.verifyDetached(fixture("pgp_ubuntu_SHA256SUMS"),
                                                        signature: fixture("pgp_ubuntu_SHA256SUMS.gpg"),
                                                        keys: keys("pgp_key_fedora44.asc"), now: now)) {
            XCTAssertEqual($0 as? OpenPGPError, .noMatchingKey)
        }
        XCTAssertThrowsError(try OpenPGP.verifyDetached(fixture("pgp_ubuntu_SHA256SUMS"),
                                                        signature: fixture("pgp_ubuntu_SHA256SUMS.gpg"), keys: [], now: now)) {
            XCTAssertEqual($0 as? OpenPGPError, .noMatchingKey)
        }
    }

    // MARK: Clearsigned text rules

    func testClearsignedIgnoresUnsignedTextAround() throws {
        let original = String(decoding: try fixture("pgp_fedora44_CHECKSUM"), as: UTF8.self)
        let wrapped = "SHA256 (evil.qcow2) = 00\n" + original + "SHA256 (evil2.qcow2) = 11\n"
        let (text, _) = try OpenPGP.verifyClearsigned(Data(wrapped.utf8), keys: keys("pgp_key_fedora44.asc"), now: now)
        XCTAssertFalse(text.contains("evil"))
    }

    func testClearsignedCanonicalization() throws {
        let original = String(decoding: try fixture("pgp_fedora44_CHECKSUM"), as: UTF8.self)
        let keys = try keys("pgp_key_fedora44.asc")
        // CRLF line endings and trailing whitespace do not change the signed text.
        XCTAssertNoThrow(try OpenPGP.verifyClearsigned(Data(original.replacingOccurrences(of: "\n", with: "\r\n").utf8),
                                                       keys: keys, now: now))
        let spaced = original.replacingOccurrences(of: "bytes\n", with: "bytes  \t\n")
        XCTAssertNoThrow(try OpenPGP.verifyClearsigned(Data(spaced.utf8), keys: keys, now: now))
        // What comes back is what was signed: without the unsigned whitespace (F-16).
        let (text, _) = try OpenPGP.verifyClearsigned(Data(spaced.utf8), keys: keys, now: now)
        XCTAssertFalse(text.contains("bytes  \t"))
        XCTAssertTrue(text.contains("bytes\n"))
    }

    func testClearsignedRejectsAHashNotAnnounced() throws {
        let original = String(decoding: try fixture("pgp_fedora44_CHECKSUM"), as: UTF8.self)
        let lying = original.replacingOccurrences(of: "Hash: SHA256", with: "Hash: SHA512")
        XCTAssertThrowsError(try OpenPGP.verifyClearsigned(Data(lying.utf8), keys: keys("pgp_key_fedora44.asc"), now: now))
    }

    func testDashEscapingAndEd25519Clearsigned() throws {
        let (text, v) = try OpenPGP.verifyClearsigned(fixture("pgp_gen_message.ed25519.clearsigned"),
                                                      keys: keys("pgp_key_gen_ed25519.asc"), now: now)
        XCTAssertEqual(v.primaryFingerprint, "0E8B00D50C27A91DD03A479CDF3E4AB18B346476")
        XCTAssertTrue(text.contains("\n- a dash line"), text)
    }

    // MARK: Generated keys and signature kinds

    func testEd25519DetachedBinary() throws {
        XCTAssertNoThrow(try OpenPGP.verifyDetached(fixture("pgp_gen_message.txt"),
                                                    signature: fixture("pgp_gen_message.ed25519.sig"),
                                                    keys: keys("pgp_key_gen_ed25519.asc"), now: now))
        XCTAssertThrowsError(try OpenPGP.verifyDetached(flip(fixture("pgp_gen_message.txt"), at: 3),
                                                        signature: fixture("pgp_gen_message.ed25519.sig"),
                                                        keys: keys("pgp_key_gen_ed25519.asc"), now: now)) {
            XCTAssertEqual($0 as? OpenPGPError, .badSignature)
        }
    }

    func testSigningSubkeyOfATrustedPrimary() throws {
        let v = try OpenPGP.verifyDetached(fixture("pgp_gen_message.txt"), signature: fixture("pgp_gen_message.rsa_subkey.asc"),
                                           keys: keys("pgp_key_gen_rsa_subkey.asc"), now: now)
        XCTAssertEqual(v.signerFingerprint, "6B4ABEAC4E8DD09F885F5AFAC04AD05C98FA253C")
        XCTAssertEqual(v.primaryFingerprint, "7F058A4A3E8B408DD2231AF0208E6B5CA1F01AEC")
    }

    func testTextModeSignatureUsesCanonicalLineEndings() throws {
        let message = try fixture("pgp_gen_message.txt")
        let keys = try keys("pgp_key_gen_rsa_subkey.asc")
        let sig = try fixture("pgp_gen_message.rsa_text.sig")
        XCTAssertNoThrow(try OpenPGP.verifyDetached(message, signature: sig, keys: keys, now: now))
        let crlf = Data(String(decoding: message, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n").utf8)
        XCTAssertNoThrow(try OpenPGP.verifyDetached(crlf, signature: sig, keys: keys, now: now))
    }

    // MARK: Time

    func testSignaturesFromTheFutureAreRejected() throws {
        XCTAssertThrowsError(try OpenPGP.verifyDetached(fixture("pgp_ubuntu_SHA256SUMS"),
                                                        signature: fixture("pgp_ubuntu_SHA256SUMS.gpg"),
                                                        keys: keys("pgp_key_ubuntu_cloud.asc"),
                                                        now: Date(timeIntervalSince1970: 1_700_000_000))) {
            XCTAssertEqual($0 as? OpenPGPError, .notYetValid)
        }
    }

    func testSignatureMadeBeforeKeyExpiryStaysValid() throws {
        // openSUSE's key expires in 2030; the signature was made in 2026.
        XCTAssertNoThrow(try OpenPGP.verifyDetached(fixture("pgp_opensuse_leap.sha256"),
                                                    signature: fixture("pgp_opensuse_leap.sha256.asc"),
                                                    keys: keys("pgp_key_opensuse.asc"),
                                                    now: Date(timeIntervalSince1970: 2_000_000_000)))
    }

    // MARK: Hostile input

    func testGarbageNeverCrashes() throws {
        let sig = try fixture("pgp_gen_message.ed25519.sig")
        let message = try fixture("pgp_gen_message.txt")
        let keys = try keys("pgp_key_gen_ed25519.asc")
        for cut in 0..<sig.count {
            XCTAssertThrowsError(try OpenPGP.verifyDetached(message, signature: sig.prefix(cut), keys: keys, now: now))
        }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var bad = sig
            bad[Int.random(in: 0..<bad.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            _ = try? OpenPGP.verifyDetached(message, signature: bad, keys: keys, now: now)
        }
        for input in ["", "-----BEGIN PGP SIGNATURE-----\n", "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\nx\n"] {
            XCTAssertThrowsError(try OpenPGP.verifyClearsigned(Data(input.utf8), keys: keys, now: now))
            XCTAssertThrowsError(try OpenPGP.keys(from: Data(input.utf8)))
        }
        let key = try fixture("pgp_key_ubuntu_cloud.asc")
        for cut in stride(from: 0, to: key.count, by: 37) {
            _ = try? OpenPGP.keys(from: key.prefix(cut))
        }
    }
}

// MARK: - Crafted packets

final class OpenPGPCraftedTests: XCTestCase {
    private let t0: UInt32 = 1_700_000_000
    private let data = Array("SHA256 (x) = 00\n".utf8)

    private func verify(_ s: TestSigner, _ sig: [UInt8], block: Data? = nil, now: UInt32) throws -> OpenPGPVerification {
        try OpenPGP.verifyDetached(Data(data), signature: Data(sig), keys: OpenPGP.keys(from: block ?? s.keyBlock()),
                                   now: Date(timeIntervalSince1970: TimeInterval(now)))
    }

    private func expect(_ error: OpenPGPError, _ body: () throws -> Void, line: UInt = #line) {
        XCTAssertThrowsError(try body(), line: line) { XCTAssertEqual($0 as? OpenPGPError, error, line: line) }
    }

    func testCraftedSignatureVerifies() throws {
        let s = TestSigner(created: t0)
        XCTAssertNoThrow(try verify(s, s.signature(over: data, at: t0 + 10), now: t0 + 20))
    }

    func testSignatureAfterKeyExpiry() {
        let s = TestSigner(created: t0)
        let block = s.keyBlock(lifetime: 100)
        XCTAssertNoThrow(try verify(s, s.signature(over: data, at: t0 + 50), block: block, now: t0 + 1000))
        expect(.expiredKey) { _ = try verify(s, s.signature(over: data, at: t0 + 200), block: block, now: t0 + 1000) }
    }

    func testRevokedKey() {
        let s = TestSigner(created: t0)
        expect(.revokedKey) {
            _ = try verify(s, s.signature(over: data, at: t0 + 10), block: s.keyBlock(revoked: true), now: t0 + 20)
        }
    }

    func testExpiredSignature() {
        let s = TestSigner(created: t0)
        let sig = s.signature(over: data, at: t0 + 10, hashed: [TestSigner.sub(3, TestSigner.be32(60))])
        XCTAssertNoThrow(try verify(s, sig, now: t0 + 20))
        expect(.expiredSignature) { _ = try verify(s, sig, now: t0 + 1000) }
    }

    func testUnknownCriticalSubpacketIsRejected() {
        let s = TestSigner(created: t0)
        let sig = s.signature(over: data, at: t0 + 10, hashed: [TestSigner.sub(100, [1], critical: true)])
        expect(.unsupported("critical subpacket 100")) { _ = try verify(s, sig, now: t0 + 20) }
        // The same subpacket without the critical bit is ignored.
        XCTAssertNoThrow(try verify(s, s.signature(over: data, at: t0 + 10, hashed: [TestSigner.sub(100, [1])]),
                                    now: t0 + 20))
    }

    func testWeakHashIsRejected() {
        let s = TestSigner(created: t0)
        XCTAssertThrowsError(try verify(s, s.signature(over: data, hash: 2, at: t0 + 10), now: t0 + 20)) {
            guard case .unsupported = $0 as? OpenPGPError else { return XCTFail("\($0)") }
        }
    }

    func testKeyWithoutSigningFlagCannotSign() {
        let s = TestSigner(created: t0)
        expect(.noMatchingKey) {
            _ = try verify(s, s.signature(over: data, at: t0 + 10), block: s.keyBlock(flags: 0x01), now: t0 + 20)
        }
    }

    func testSignatureOlderThanTheKeyIsRejected() {
        let s = TestSigner(created: t0)
        expect(.badSignature) { _ = try verify(s, s.signature(over: data, at: t0 - 10), now: t0 + 20) }
    }

    func testAnotherKeysSignatureIsNotAccepted() {
        let trusted = TestSigner(created: t0), other = TestSigner(created: t0)
        expect(.noMatchingKey) {
            _ = try verify(trusted, other.signature(over: data, at: t0 + 10), block: trusted.keyBlock(), now: t0 + 20)
        }
    }
}
