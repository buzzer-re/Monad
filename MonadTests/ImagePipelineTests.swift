//
//  ImagePipelineTests.swift — from a distro configuration to a verified raw
//  base disk: checksum discovery, signature check, download, digest check,
//  conversion (qcow2, raw, tar.xz), caching and offline use. Three test
//  distros cover the three signature kinds and the three image formats.
//

import CryptoKit
import XCTest
@testable import Monad

/// Serves files from memory and records every request.
final class FakeFetcher: ImageFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [URL: Data] = [:]
    private var offline: Set<URL> = []
    private var _requests: [URL] = []
    /// The small files fetched that may not leave their site on a redirect.
    private var _onSite: [URL] = []
    var onSite: [URL] { lock.withLock { _onSite } }
    /// Delay before download() returns, to let concurrent callers overlap.
    var downloadDelay: TimeInterval = 0

    var requests: [URL] { lock.withLock { _requests } }

    func serve(_ url: String, _ data: Data) { lock.withLock { files[URL(string: url)!] = data } }
    func goOffline(_ url: String) { _ = lock.withLock { offline.insert(URL(string: url)!) } }
    func count(_ url: String) -> Int { requests.filter { $0.absoluteString == url }.count }

    private func lookup(_ url: URL) throws -> Data {
        try lock.withLock {
            _requests.append(url)
            if offline.contains(url) { throw URLError(.notConnectedToInternet) }
            guard let d = files[url] else { throw ImageFetchError.http(404, url) }
            return d
        }
    }

    func data(from url: URL, limit: Int, staysOnSite: Bool) async throws -> Data {
        if staysOnSite { lock.withLock { _onSite.append(url) } }
        let d = try lookup(url)
        guard d.count <= limit else { throw ImageFetchError.tooLarge(url, limit) }
        return d
    }

    func reachable(_ url: URL) async throws {
        _ = try lookup(url)
    }

    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let d = try lookup(url)
        if downloadDelay > 0 { try await Task.sleep(nanoseconds: UInt64(downloadDelay * 1e9)) }
        progress(Int64(d.count), Int64(d.count))
        try d.write(to: file)
    }
}

/// Progress messages from @Sendable callbacks.
final class MessageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var all: [String] { lock.withLock { items } }
    func add(_ m: String) { lock.withLock { items.append(m) } }
}

/// A DEBUG-style local image source for tests.
struct FakeLocalSource: LocalImageSource {
    let files: [String: URL]
    func candidates(named file: String) -> [URL] { files[file].map { [$0] } ?? [] }
}

final class ImagePipelineTests: XCTestCase {
    private var tmp: TempDir!
    private var fetcher: FakeFetcher!
    private let signer = TestSigner()

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil), name))
    }

    private func hex<D: Digest>(_ d: D) -> String { d.map { String(format: "%02x", $0) }.joined() }

    private func digest(_ url: URL) throws -> String { hex(SHA256.hash(data: try Data(contentsOf: url))) }

    // Expected contents of the converted disks (see the fixtures' generators).
    private let qcow2Disk = "43bbc11eefbdd27b8571f115075c1baa6e33bccfec6036cffb75bfeba45766e9"
    private let rawDisk = "fcb0949a78060a18b1078d6498e51eeb8390e24ff6698f66aad33b7bd20c4032"
    private let tarDisk = "d20b826f03176e2ba968bd540a77e68a231f002c181e859ef93932651a507ca8"

    private func distros() -> [DistroConfig] {
        let key = "distro-key-test.asc"
        let guest = DistroConfig.GuestProfile(packageManager: "apt")
        func release(_ id: String) -> DistroConfig.Release { .init(id: id, name: "Release \(id)", isDefault: true, vars: nil) }
        return [
            DistroConfig(schema: 1, id: "signedq", name: "Signed QCOW", releases: [release("1")],
                         architectures: ["arm64": "arm64"],
                         image: .init(checksums: .init(url: "https://a.example/{release}/SHA256SUMS", index: nil, pattern: nil,
                                                       format: .gnu, algorithm: .sha256),
                                      signature: .init(kind: .detached, url: "{checksums}.gpg", keys: [key],
                                                       fingerprints: [signer.fingerprintHex], note: nil),
                                      file: "a-{release}-{arch}.qcow2", url: "{dir}{file}", format: .qcow2, member: nil),
                         guest: guest),
            DistroConfig(schema: 1, id: "clearraw", name: "Clearsigned Raw", releases: [release("2")],
                         architectures: ["arm64": "aarch64"],
                         image: .init(checksums: .init(url: nil, index: "https://b.example/{release}/",
                                                       pattern: "B-{release}-*-CHECKSUM", format: .bsd, algorithm: .sha256),
                                      signature: .init(kind: .clearsigned, url: nil, keys: [key],
                                                       fingerprints: [signer.fingerprintHex], note: nil),
                                      file: "b-{release}-*.{arch}.raw", url: "{dir}{file}", format: .raw, member: nil),
                         guest: guest),
            DistroConfig(schema: 1, id: "unsignedtar", name: "Unsigned Tar", releases: [release("rolling")],
                         architectures: ["arm64": "arm64"],
                         image: .init(checksums: .init(url: "https://c.example/current/SHA512SUMS", index: nil, pattern: nil,
                                                       format: .gnu, algorithm: .sha512),
                                      signature: .init(kind: .none, url: nil, keys: nil, fingerprints: nil,
                                                       note: "Checksums over HTTPS only."),
                                      file: "c-*-{arch}.tar.xz", url: "{dir}{file}", format: .tarXz, member: "disk.raw"),
                         guest: guest),
        ]
    }

    private func pipeline(local: [LocalImageSource] = []) throws -> ImagePipeline {
        let keyFile = tmp.url.appendingPathComponent("distro-key-test.asc")
        try signer.armoredKey.write(to: keyFile, atomically: true, encoding: .utf8)
        let catalog = try DistroCatalog(distros: distros()) { name in
            name == "distro-key-test.asc" ? keyFile : nil
        }
        return ImagePipeline(catalog: catalog, cache: tmp.url.appendingPathComponent("images"), fetcher: fetcher,
                             hostArch: "arm64", localSources: local, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    override func setUp() async throws {
        tmp = TempDir()
        fetcher = FakeFetcher()
    }

    private func serveSignedQcow2(image: Data? = nil) throws {
        let qcow = try fixture("image_fixture.qcow2")
        let sums = Data("\(hex(SHA256.hash(data: qcow))) *a-1-arm64.qcow2\n\(String(repeating: "0", count: 64))  a-1-amd64.qcow2\n".utf8)
        fetcher.serve("https://a.example/1/SHA256SUMS", sums)
        fetcher.serve("https://a.example/1/SHA256SUMS.gpg", signer.detachedSignature(over: sums))
        fetcher.serve("https://a.example/1/a-1-arm64.qcow2", image ?? qcow)
    }

    private func serveClearsignedRaw() throws {
        let raw = try fixture("image_fixture.raw")
        let listing = #"<a href="B-2-5-CHECKSUM">B-2-5-CHECKSUM</a> <a href="b-2-5.aarch64.raw">x</a>"#
        fetcher.serve("https://b.example/2/", Data(listing.utf8))
        fetcher.serve("https://b.example/2/B-2-5-CHECKSUM",
                      signer.clearsign("# b-2-5.aarch64.raw: \(raw.count) bytes\nSHA256 (b-2-5.aarch64.raw) = \(hex(SHA256.hash(data: raw)))\n"))
        fetcher.serve("https://b.example/2/b-2-5.aarch64.raw", raw)
    }

    private func serveUnsignedTar() throws {
        let tar = try fixture("image_fixture.tar.xz")
        fetcher.serve("https://c.example/current/SHA512SUMS",
                      Data("\(hex(SHA512.hash(data: tar)))  c-2026.2-arm64.tar.xz\n\(String(repeating: "1", count: 128))  c-2026.2-amd64.tar.xz\n".utf8))
        fetcher.serve("https://c.example/current/c-2026.2-arm64.tar.xz", tar)
    }

    // MARK: The three kinds

    /// A distro the user added carries its key inline: its image is checked
    /// against that key the same way, and a key it does not carry is not used.
    func testAnAddedDistrosInlineKeyChecksItsImage() async throws {
        var d = distros()[0]
        d.image.signature.keys = nil
        d.image.signature.publicKeys = [signer.armoredKey]
        let catalog = try DistroCatalog(distros: [d]) { _ in nil }
        let p = ImagePipeline(catalog: catalog, cache: tmp.url.appendingPathComponent("images"), fetcher: fetcher,
                              hostArch: "arm64", localSources: [], now: { Date(timeIntervalSince1970: 1_800_000_000) })
        try serveSignedQcow2()
        let base = try await p.baseImage(distro: "signedq", release: nil) { _ in }
        XCTAssertEqual(base.verification, .signature(fingerprint: signer.fingerprintHex))

        d.image.signature.publicKeys = [TestSigner().armoredKey]
        XCTAssertThrowsError(try DistroCatalog(distros: [d]) { _ in nil }.trustedKeys(for: d), "the pinned key is not in the file")
    }

    /// Settings' Check: the checksum file is fetched and its signature
    /// verified, the image found in it, and the image itself not downloaded.
    func testACheckFindsTheImageWithoutDownloadingIt() async throws {
        try serveSignedQcow2()
        let found = try await pipeline().check(distro: distros()[0])
        XCTAssertEqual(found.file, "a-1-arm64.qcow2")
        XCTAssertEqual(found.imageURL.absoluteString, "https://a.example/1/a-1-arm64.qcow2")
        XCTAssertEqual(found.verification, .signature(fingerprint: signer.fingerprintHex))
        XCTAssertEqual(fetcher.requests.map(\.absoluteString), ["https://a.example/1/SHA256SUMS",
                                                                "https://a.example/1/SHA256SUMS.gpg"])
        var unsigned = distros()[0]
        unsigned.image.signature.fingerprints = [TestSigner().fingerprintHex]
        unsigned.image.signature.keys = nil
        unsigned.image.signature.publicKeys = [TestSigner().armoredKey]
        do {
            _ = try await pipeline().check(distro: unsigned)
            XCTFail("a key that did not sign it")
        } catch {}
    }

    /// The form's Check reads the checksum file as it is first (signed
    /// inside or not), to learn its format and the images it lists. Nothing
    /// is trusted from it yet: the check that follows verifies it.
    func testTheChecksumFileIsReadAsItIs() async throws {
        try serveSignedQcow2()
        let text = try await pipeline().peek(distro: distros()[0])
        XCTAssertTrue(text.contains("a-1-arm64.qcow2"), text)
        XCTAssertEqual(fetcher.requests.map(\.absoluteString), ["https://a.example/1/SHA256SUMS"])
    }

    /// Unsigned checksums stay on their site; on a plain http site a
    /// redirect may stay on http there.
    func testARedirectStaysOnItsSiteAndScheme() {
        let lan = URL(string: "http://mirror.home.arpa/x/SUMS")!
        XCTAssertTrue(URLSessionFetcher.staysOnSite(from: lan, to: URL(string: "http://mirror.home.arpa/y/SUMS")!))
        XCTAssertTrue(URLSessionFetcher.staysOnSite(from: lan, to: URL(string: "https://mirror.home.arpa/y/SUMS")!))
        let secure = URL(string: "https://cloud.debian.org/x/SUMS")!
        XCTAssertFalse(URLSessionFetcher.staysOnSite(from: secure, to: URL(string: "http://cloud.debian.org/x/SUMS")!),
                       "never down from https")
        XCTAssertFalse(URLSessionFetcher.staysOnSite(from: lan, to: URL(string: "http://elsewhere.example/SUMS")!))
    }

    func testDetachedSignatureAndQcow2() async throws {
        try serveSignedQcow2()
        let messages = MessageLog()
        let base = try await pipeline().baseImage(distro: "signedq", release: nil) { messages.add($0) }
        XCTAssertEqual(try digest(base.url), qcow2Disk)
        XCTAssertEqual(base.name, "Release 1", "release names carry the distro name (\"Ubuntu 26.04 LTS\")")
        XCTAssertEqual(base.release, "1")
        XCTAssertEqual(base.verification, .signature(fingerprint: signer.fingerprintHex))
        XCTAssertEqual(fetcher.requests.map(\.absoluteString), ["https://a.example/1/SHA256SUMS",
                                                                "https://a.example/1/SHA256SUMS.gpg",
                                                                "https://a.example/1/a-1-arm64.qcow2"])
        let attrs = try FileManager.default.attributesOfItem(atPath: base.url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o444, "base images are read-only")
        XCTAssertFalse(messages.all.isEmpty)
    }

    func testClearsignedChecksumsFoundThroughTheDirectoryListing() async throws {
        try serveClearsignedRaw()
        let base = try await pipeline().baseImage(distro: "clearraw", release: "2") { _ in }
        XCTAssertEqual(try digest(base.url), rawDisk)
        XCTAssertEqual(base.verification, .signature(fingerprint: signer.fingerprintHex))
    }

    func testUnsignedChecksumsAndTarXz() async throws {
        try serveUnsignedTar()
        let base = try await pipeline().baseImage(distro: "unsignedtar", release: nil) { _ in }
        XCTAssertEqual(try digest(base.url), tarDisk)
        XCTAssertEqual(base.verification, .checksumOverHTTPS)
    }

    // MARK: Refusals

    /// A mirror serving an older (validly signed) checksum file, with its old
    /// image, is refused once a newer one was seen for that release (F-16).
    func testAnOlderSignedChecksumFileIsRefused() async throws {
        let qcow = try fixture("image_fixture.qcow2")
        let sums = Data("\(hex(SHA256.hash(data: qcow))) *a-1-arm64.qcow2\n".utf8)
        fetcher.serve("https://a.example/1/SHA256SUMS", sums)
        fetcher.serve("https://a.example/1/SHA256SUMS.gpg", signer.detachedSignature(over: sums, at: signer.created + 1000))
        fetcher.serve("https://a.example/1/a-1-arm64.qcow2", qcow)
        _ = try await pipeline().baseImage(distro: "signedq", release: nil) { _ in }
        fetcher.serve("https://a.example/1/SHA256SUMS.gpg", signer.detachedSignature(over: sums, at: signer.created + 500))
        do {
            _ = try await pipeline().baseImage(distro: "signedq", release: nil) { _ in }
            XCTFail("an older signature was taken")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("older"), error.localizedDescription)
        }
        // The same date again is fine (the same file).
        fetcher.serve("https://a.example/1/SHA256SUMS.gpg", signer.detachedSignature(over: sums, at: signer.created + 1000))
        _ = try await pipeline().baseImage(distro: "signedq", release: nil) { _ in }
    }

    /// Checksums only HTTPS vouches for are not taken from another site a
    /// redirect points to; signed ones may come from any mirror (F-16).
    func testUnsignedChecksumsStayOnTheirSite() async throws {
        try serveUnsignedTar()
        _ = try await pipeline().baseImage(distro: "unsignedtar", release: nil) { _ in }
        XCTAssertEqual(fetcher.onSite.map(\.absoluteString), ["https://c.example/current/SHA512SUMS"])
        try serveSignedQcow2()
        _ = try await pipeline().baseImage(distro: "signedq", release: nil) { _ in }
        XCTAssertEqual(fetcher.onSite.count, 1)
        let site = URL(string: "https://cloud.debian.org/images/SHA512SUMS")!
        XCTAssertTrue(URLSessionFetcher.staysOnSite(from: site, to: URL(string: "https://cdimage.debian.org/x/SHA512SUMS")!))
        XCTAssertFalse(URLSessionFetcher.staysOnSite(from: site, to: URL(string: "https://debian.org.evil.example/SHA512SUMS")!))
        XCTAssertFalse(URLSessionFetcher.staysOnSite(from: site, to: URL(string: "http://cloud.debian.org/SHA512SUMS")!))
        XCTAssertFalse(URLSessionFetcher.staysOnSite(from: site, to: URL(string: "https://notdebian.org/SHA512SUMS")!))
    }

    func testTamperedImageIsRejectedAndNothingIsKept() async throws {
        var bad = try fixture("image_fixture.qcow2")
        bad[bad.count - 1] ^= 0xFF
        try serveSignedQcow2(image: bad)
        let p = try pipeline()
        do {
            _ = try await p.baseImage(distro: "signedq", release: nil) { _ in }
            XCTFail("a corrupted download must not be used")
        } catch {
            guard case .digestMismatch = error as? ImagePipeline.Problem else { return XCTFail("\(error)") }
        }
        // No image and no metadata; the signature date seen is kept (the checksum file was genuine).
        let left = (try? FileManager.default.contentsOfDirectory(atPath: tmp.url.appendingPathComponent("images").path)) ?? []
        XCTAssertTrue(left.filter { !$0.hasPrefix(".") && $0 != "downloads" && $0 != "signature-dates.json" }.isEmpty,
                      "\(left)")
    }

    func testForeignSignatureStopsBeforeTheImageIsDownloaded() async throws {
        try serveSignedQcow2()
        let sums = try await fetcher.data(from: URL(string: "https://a.example/1/SHA256SUMS")!, limit: 1 << 20, staysOnSite: false)
        fetcher.serve("https://a.example/1/SHA256SUMS.gpg", TestSigner().detachedSignature(over: sums))
        do {
            _ = try await pipeline().baseImage(distro: "signedq", release: nil) { _ in }
            XCTFail("expected a signature error")
        } catch {
            XCTAssertEqual(error as? OpenPGPError, .noMatchingKey)
        }
        XCTAssertEqual(fetcher.count("https://a.example/1/a-1-arm64.qcow2"), 0)
    }

    func testTamperedChecksumFileIsRejected() async throws {
        try serveSignedQcow2()
        fetcher.serve("https://a.example/1/SHA256SUMS", Data("\(String(repeating: "f", count: 64)) *a-1-arm64.qcow2\n".utf8))
        do {
            _ = try await pipeline().baseImage(distro: "signedq", release: nil) { _ in }
            XCTFail("expected a signature error")
        } catch {
            XCTAssertEqual(error as? OpenPGPError, .badSignature)
        }
    }

    func testOversizedChecksumFileIsRefused() async throws {
        try serveSignedQcow2()
        fetcher.serve("https://a.example/1/SHA256SUMS", Data(count: 2 << 20))
        do {
            _ = try await pipeline().baseImage(distro: "signedq", release: nil) { _ in }
            XCTFail("expected an error")
        } catch {
            guard case .tooLarge = error as? ImageFetchError else { return XCTFail("\(error)") }
        }
    }

    func testUnknownDistroOrRelease() async throws {
        let p = try pipeline()
        do { _ = try await p.baseImage(distro: "nope", release: nil) { _ in }; XCTFail() } catch {}
        do { _ = try await p.baseImage(distro: "signedq", release: "9") { _ in }; XCTFail() } catch {}
    }

    // MARK: Cache, offline, local images

    func testVerifiedImageIsReused() async throws {
        try serveSignedQcow2()
        let p = try pipeline()
        let first = try await p.baseImage(distro: "signedq", release: nil) { _ in }
        let second = try await p.baseImage(distro: "signedq", release: nil) { _ in }
        XCTAssertEqual(first.url, second.url)
        XCTAssertEqual(fetcher.count("https://a.example/1/a-1-arm64.qcow2"), 1)
    }

    func testOfflineUsesTheCachedImage() async throws {
        try serveSignedQcow2()
        let first = try await pipeline().baseImage(distro: "signedq", release: nil) { _ in }
        fetcher.goOffline("https://a.example/1/SHA256SUMS")
        let messages = MessageLog()
        let again = try await pipeline().baseImage(distro: "signedq", release: nil) { messages.add($0) }
        XCTAssertEqual(again.url, first.url)
        XCTAssertEqual(again.verification, first.verification)
        XCTAssertTrue(messages.all.contains { $0.localizedCaseInsensitiveContains("offline") }, "\(messages.all)")
    }

    func testOfflineWithoutACachedImageFails() async throws {
        fetcher.goOffline("https://a.example/1/SHA256SUMS")
        do {
            _ = try await pipeline().baseImage(distro: "signedq", release: nil) { _ in }
            XCTFail("expected an error")
        } catch {}
    }

    func testConcurrentRequestsShareOneDownload() async throws {
        try serveSignedQcow2()
        fetcher.downloadDelay = 0.2
        let p = try pipeline()
        async let a = p.baseImage(distro: "signedq", release: nil) { _ in }
        async let b = p.baseImage(distro: "signedq", release: nil) { _ in }
        let (x, y) = try await (a, b)
        XCTAssertEqual(x.url, y.url)
        XCTAssertEqual(fetcher.count("https://a.example/1/a-1-arm64.qcow2"), 1)
    }

    func testLocalCopyWithTheRightDigestSavesTheDownload() async throws {
        try serveSignedQcow2()
        let local = tmp.url.appendingPathComponent("lima-data")
        try fixture("image_fixture.qcow2").write(to: local)
        let base = try await pipeline(local: [FakeLocalSource(files: ["a-1-arm64.qcow2": local])])
            .baseImage(distro: "signedq", release: nil) { _ in }
        XCTAssertEqual(try digest(base.url), qcow2Disk)
        XCTAssertEqual(fetcher.count("https://a.example/1/a-1-arm64.qcow2"), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path), "local sources are only read")
    }

    func testLocalCopyWithAnotherDigestIsIgnored() async throws {
        try serveSignedQcow2()
        let local = tmp.url.appendingPathComponent("lima-data")
        try Data("not the image".utf8).write(to: local)
        let base = try await pipeline(local: [FakeLocalSource(files: ["a-1-arm64.qcow2": local])])
            .baseImage(distro: "signedq", release: nil) { _ in }
        XCTAssertEqual(try digest(base.url), qcow2Disk)
        XCTAssertEqual(fetcher.count("https://a.example/1/a-1-arm64.qcow2"), 1)
    }

    // MARK: An image by its link

    private func linked(_ url: String) -> DistroConfig {
        DistroConfig(schema: 1, id: "linked", name: "Linked", releases: [.init(id: "1", name: "Linked 1", isDefault: true, vars: nil)],
                     architectures: ["arm64": "aarch64"],
                     image: .init(checksums: nil, signature: .init(kind: .none, url: nil, keys: nil, fingerprints: nil, note: nil),
                                  file: URL(string: url)?.lastPathComponent ?? "", url: url, format: .qcow2, member: nil),
                     guest: .init())
    }

    private func pipeline(_ d: DistroConfig) throws -> ImagePipeline {
        ImagePipeline(catalog: try DistroCatalog(distros: [d], userFiles: true) { _ in nil },
                      cache: tmp.url.appendingPathComponent("images"), fetcher: fetcher, hostArch: "arm64", localSources: [])
    }

    /// An image given by its link alone: downloaded once as it is (there is
    /// nothing to check it against), its digest recorded, reused after.
    func testAnImageByItsLinkIsDownloadedOnceAsItIs() async throws {
        let qcow = try fixture("image_fixture.qcow2")
        fetcher.serve("https://l.example/x.qcow2", qcow)
        let d = linked("https://l.example/x.qcow2")
        try d.validate(userFile: true)
        let p = try pipeline(d)
        let base = try await p.baseImage(distro: "linked", release: nil) { _ in }
        XCTAssertEqual(base.verification, .unverified)
        XCTAssertEqual(base.digest, hex(SHA256.hash(data: qcow)))
        XCTAssertEqual(try digest(base.url), qcow2Disk)
        let again = try await p.baseImage(distro: "linked", release: nil) { _ in }
        XCTAssertEqual(again.url, base.url)
        XCTAssertEqual(fetcher.requests.map(\.absoluteString), ["https://l.example/x.qcow2"])
        let found = try await p.check(distro: d)
        XCTAssertEqual(found.imageURL.absoluteString, "https://l.example/x.qcow2")
        XCTAssertEqual(found.verification, .unverified)
        fetcher.goOffline("https://l.example/x.qcow2")
        do {
            _ = try await p.check(distro: d)
            XCTFail("a link that does not answer")
        } catch {}
    }

    /// A file on this Mac is read where it is, never moved or changed. An
    /// .img that is a raw disk inside is read as raw.
    func testAnImageOnThisMacIsReadWhereItIs() async throws {
        let file = tmp.url.appendingPathComponent("My Image.img")
        try fixture("image_fixture.raw").write(to: file)
        let d = linked(file.absoluteString)
        try d.validate(userFile: true)
        let base = try await pipeline(d).baseImage(distro: "linked", release: nil) { _ in }
        XCTAssertEqual(try digest(base.url), rawDisk)
        XCTAssertEqual(fetcher.requests, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        _ = try await pipeline(d).check(distro: d)
        try FileManager.default.removeItem(at: file)
        do {
            _ = try await pipeline(d).check(distro: d)
            XCTFail("the file is gone")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("My Image.img"), error.localizedDescription)
        }
    }

    /// Compressed images: the checksum is the compressed file's (as the
    /// project publishes it), the disk is what is inside. Monad's own xz
    /// decoder, zlib for gzip.
    func testCompressedImagesAreUnpacked() async throws {
        let xz = try fixture("image_fixture.qcow2.xz")
        fetcher.serve("https://l.example/x.qcow2.xz", xz)
        var d = linked("https://l.example/x.qcow2.xz")
        d.image.compression = .xz
        try d.validate(userFile: true)
        let fromLink = try await pipeline(d).baseImage(distro: "linked", release: nil) { _ in }
        XCTAssertEqual(try digest(fromLink.url), qcow2Disk)
        XCTAssertEqual(fromLink.digest, hex(SHA256.hash(data: xz)))

        let gz = try fixture("image_fixture.raw.gz")
        var sums = distros()[2]
        sums.id = "gzipped"
        sums.image.checksums = .init(url: "https://g.example/SHA256SUMS", index: nil, pattern: nil, format: .gnu, algorithm: .sha256)
        sums.image.file = "g-{arch}.raw.gz"
        sums.image.format = .raw
        sums.image.member = nil
        sums.image.compression = .gz
        fetcher.serve("https://g.example/SHA256SUMS", Data("\(hex(SHA256.hash(data: gz)))  g-arm64.raw.gz\n".utf8))
        fetcher.serve("https://g.example/g-arm64.raw.gz", gz)
        let checked = try await pipeline(sums).baseImage(distro: "gzipped", release: nil) { _ in }
        XCTAssertEqual(try digest(checked.url), rawDisk)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmp.url.appendingPathComponent("images/downloads").path)
        XCTAssertEqual(leftovers, [], "nothing is left but the disk")

        var archive = distros()[2]
        archive.image.compression = .xz
        XCTAssertThrowsError(try archive.validate(), "a tar.xz is an archive, not a compressed disk")

        fetcher.serve("https://l.example/bad.qcow2.xz", Data("not xz".utf8))
        var bad = linked("https://l.example/bad.qcow2.xz")
        bad.image.compression = .xz
        do {
            _ = try await pipeline(bad).baseImage(distro: "linked", release: nil) { _ in }
            XCTFail("not xz")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(".xz"), error.localizedDescription)
        }
    }

    /// The form's link: Monad looks next to the image for a checksum file
    /// that lists it (the names in the directory listing first, then the
    /// usual ones) and for that file's signature.
    func testTheChecksumsNextToAnImageAreFound() async throws {
        let dir = "https://repo.example/almalinux/10/cloud/aarch64/images/"
        fetcher.serve(dir, Data(#"<a href="AlmaLinux-10-GenericCloud-latest.aarch64.qcow2">x</a> <a href="CHECKSUM">CHECKSUM</a> <a href="CHECKSUM.asc">s</a>"#.utf8))
        fetcher.serve(dir + "CHECKSUM", try fixture("distro_almalinux10_aarch64_CHECKSUM"))
        fetcher.serve(dir + "CHECKSUM.asc", try fixture("distro_almalinux10_aarch64_CHECKSUM.asc"))
        let alma = try await pipeline().discover(try ImageLink(dir + "AlmaLinux-10-GenericCloud-latest.aarch64.qcow2"))
        XCTAssertEqual(alma.checksums, .init(url: URL(string: dir + "CHECKSUM")!, format: .gnu, algorithm: .sha256,
                                             signature: .detached, signatureURL: URL(string: dir + "CHECKSUM.asc")!))
        XCTAssertEqual(fetcher.requests.map(\.absoluteString), [dir, dir + "CHECKSUM", dir + "CHECKSUM.asc"])

        // No listing; a sha512 file signed in a .sign file.
        let deb = "https://deb.example/trixie/latest/"
        let sums = "\(String(repeating: "a", count: 128))  debian-13-genericcloud-arm64.qcow2\n"
        fetcher.serve(deb + "SHA512SUMS", Data(sums.utf8))
        fetcher.serve(deb + "SHA512SUMS.sign", Data("sig".utf8))
        let debian = try await pipeline().discover(try ImageLink(deb + "debian-13-genericcloud-arm64.qcow2"))
        XCTAssertEqual(debian.checksums, .init(url: URL(string: deb + "SHA512SUMS")!, format: .gnu, algorithm: .sha512,
                                               signature: .detached, signatureURL: URL(string: deb + "SHA512SUMS.sign")!))

        // A clearsigned one says so; one that does not list the image is passed by.
        let b = "https://b.example/2/"
        fetcher.serve(b + "CHECKSUM", Data("\(String(repeating: "b", count: 64))  other.qcow2\n".utf8))
        fetcher.serve(b + "SHA256SUMS", signer.clearsign("SHA256 (b-2.raw) = \(String(repeating: "c", count: 64))\n"))
        let clear = try await pipeline().discover(try ImageLink(b + "b-2.raw"))
        XCTAssertEqual(clear.checksums, .init(url: URL(string: b + "SHA256SUMS")!, format: .bsd, algorithm: .sha256,
                                              signature: .clearsigned, signatureURL: nil))

        // Nothing next to it, or a file on this Mac: nothing to check against.
        let none = try await pipeline().discover(try ImageLink("https://n.example/x.qcow2"))
        XCTAssertNil(none.checksums)
        let before = fetcher.requests.count
        let local = try await pipeline().discover(try ImageLink("/tmp/x.qcow2"))
        XCTAssertNil(local.checksums)
        XCTAssertEqual(fetcher.requests.count, before)
    }

    // MARK: Helpers

    // MARK: macOS restore images

    private struct FakeRestore: MacRestoreSource {
        let release: MacRestoreRelease?
        func latest() async throws -> MacRestoreRelease {
            guard let release else { throw URLError(.notConnectedToInternet) }
            return release
        }
    }

    private func macPipeline(latest: MacRestoreRelease?, distros: [DistroConfig]? = nil, userFiles: Bool = false) throws -> ImagePipeline {
        let mac = try XCTUnwrap(DistroCatalog.bundled().distro("macos"))
        return ImagePipeline(catalog: try DistroCatalog(distros: distros ?? [mac], userFiles: userFiles) { _ in nil },
                             cache: tmp.url.appendingPathComponent("images"), fetcher: fetcher, hostArch: "arm64",
                             localSources: [], macRestore: FakeRestore(release: latest))
    }

    /// The latest macOS for this Mac: Apple says where it is, it is
    /// downloaded once as it is (no conversion) and kept; offline, the one
    /// kept is used; the kept ones are listed and can be removed.
    func testTheLatestMacOSIsDownloadedOnceAndKept() async throws {
        let link = "https://updates.cdn-apple.com/2026/fullrestores/UniversalMac_27.0_26A100_Restore.ipsw"
        let ipsw = Data("restore image".utf8)
        fetcher.serve(link, ipsw)
        let latest = MacRestoreRelease(url: URL(string: link)!, build: "26A100", version: "27.0")
        let p = try macPipeline(latest: latest)
        let base = try await p.baseImage(distro: "macos", release: nil) { _ in }
        XCTAssertEqual(base.url.lastPathComponent, "UniversalMac_27.0_26A100_Restore.ipsw")
        XCTAssertEqual(try Data(contentsOf: base.url), ipsw, "kept as it is")
        XCTAssertEqual(base.release, "26A100")
        XCTAssertEqual(base.name, "macOS 27.0 (26A100)")
        _ = try await p.baseImage(distro: "macos", release: nil) { _ in }
        XCTAssertEqual(fetcher.count(link), 1, "downloaded once")

        let offline = try macPipeline(latest: nil)
        let kept = try await offline.baseImage(distro: "macos", release: nil) { _ in }
        XCTAssertEqual(kept.url, base.url, "offline: the one kept")

        XCTAssertEqual(p.restoreImages().map(\.file), ["UniversalMac_27.0_26A100_Restore.ipsw"])
        XCTAssertEqual(p.restoreImages().first?.bytes, Int64(ipsw.count))
        try p.removeRestoreImage("UniversalMac_27.0_26A100_Restore.ipsw")
        XCTAssertEqual(p.restoreImages().map(\.file), [])
        XCTAssertThrowsError(try p.removeRestoreImage("../images"), "only a kept restore image")
        do {
            _ = try await offline.baseImage(distro: "macos", release: nil) { _ in }
            XCTFail("offline with nothing kept")
        } catch {}
    }

    /// An IPSW already on this Mac is used where it is: nothing downloaded,
    /// nothing copied.
    func testARestoreImageOnThisMacIsUsedWhereItIs() async throws {
        let file = tmp.url.appendingPathComponent("macOS 27.ipsw")
        try Data("restore image".utf8).write(to: file)
        var mac = try XCTUnwrap(DistroCatalog.bundled().distro("macos"))
        mac.id = "mymac"
        mac.preferred = nil
        mac.image.url = file.absoluteString
        try mac.validate(userFile: true)
        let p = try macPipeline(latest: nil, distros: [mac], userFiles: true)
        let base = try await p.baseImage(distro: "mymac", release: nil) { _ in }
        XCTAssertEqual(base.url.path, file.path)
        XCTAssertEqual(fetcher.requests, [])
        XCTAssertEqual(p.restoreImages().map(\.file), [])
    }

    func testFileDigests() throws {
        let f = tmp.url.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: f)
        XCTAssertEqual(try FileDigest.hex(of: f, algorithm: .sha256),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try FileDigest.hex(of: f, algorithm: .sha512).prefix(16), "ddaf35a193617aba")
    }
}
