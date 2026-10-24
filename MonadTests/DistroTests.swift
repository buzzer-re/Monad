//
//  DistroTests.swift — distro configuration files, checksum files and
//  directory listings. Checksum and listing fixtures are the real files the
//  distros publish.
//

import XCTest
@testable import Monad

private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle(for: DistroCatalogTests.self).url(forResource: name, withExtension: nil), name)
    return try Data(contentsOf: url)
}

private func text(_ name: String) throws -> String { String(decoding: try fixture(name), as: UTF8.self) }

// MARK: - Checksum files

final class ChecksumFileTests: XCTestCase {
    func testGNUFormatWithBinaryMarker() throws {
        let sums = try ChecksumFile(text: text("pgp_ubuntu_SHA256SUMS"), format: .gnu, algorithm: .sha256)
        let e = try sums.entry(matching: "ubuntu-26.04-server-cloudimg-arm64.img")
        XCTAssertEqual(e.file, "ubuntu-26.04-server-cloudimg-arm64.img")
        XCTAssertEqual(e.digest, "63a93bd5a8d76e33b15ceb5daa3657bd79be804748051ab178e643b0f5da22e7")
    }

    func testGNUFormatSHA512() throws {
        let sums = try ChecksumFile(text: text("distro_debian13_SHA512SUMS"), format: .gnu, algorithm: .sha512)
        XCTAssertEqual(try sums.entry(matching: "debian-13-genericcloud-arm64.qcow2").digest,
                       "9eeabc75e74a682fcaff785f6c1f6896b486159397201f51f58298a8f95990f6debb8058b6969ca95cf6823f6e8058dd6f8589ba940a194b2780cd7f95771d69")
    }

    func testBSDFormatFromAVerifiedClearsignedFile() throws {
        let key = try OpenPGP.keys(from: fixture("pgp_key_fedora44.asc"))
        let (signed, _) = try OpenPGP.verifyClearsigned(fixture("pgp_fedora44_CHECKSUM"), keys: key,
                                                        now: Date(timeIntervalSince1970: 1_800_000_000))
        let sums = try ChecksumFile(text: signed, format: .bsd, algorithm: .sha256)
        let e = try sums.entry(matching: "Fedora-Cloud-Base-Generic-44-*.aarch64.qcow2")
        XCTAssertEqual(e.file, "Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2")
        XCTAssertEqual(e.digest, "55c60a3b80d3616a08705afd0459e75fe9f03c54aba7a46e4002a41a72fa0d5b")
    }

    func testSingleFileFormat() throws {
        let sums = try ChecksumFile(text: text("pgp_opensuse_leap.sha256"), format: .single, algorithm: .sha256)
        let e = try sums.entry(matching: "Leap-16.0-Minimal-VM.aarch64-Cloud.qcow2")
        XCTAssertEqual(e.digest, "36f4935b8e771e18479c5e186af019e4e0e0fbf2461df868f9297126d04d3796")
    }

    func testPatternWithAVersionInside() throws {
        let sums = try ChecksumFile(text: """
            3f4ca86ae1eca0dc2bf2092f065a959508e186c6b44f85758813a8e9a0604f3e  example-2026.2-cloud-amd64.tar.xz
            9ab19c28d049fdc6f1d5d30f6cc93b8b01997f11c89f6992f690c07b16b7b7e4  example-2026.2-cloud-arm64.tar.xz

            """, format: .gnu, algorithm: .sha256)
        let e = try sums.entry(matching: "example-*-cloud-arm64.tar.xz")
        XCTAssertEqual(e.file, "example-2026.2-cloud-arm64.tar.xz")
        XCTAssertEqual(e.digest, "9ab19c28d049fdc6f1d5d30f6cc93b8b01997f11c89f6992f690c07b16b7b7e4")
    }

    func testAmbiguousAndMissingEntries() throws {
        let sums = try ChecksumFile(text: text("distro_debian13_SHA512SUMS"), format: .gnu, algorithm: .sha512)
        XCTAssertThrowsError(try sums.entry(matching: "*-arm64.qcow2")) {
            guard case .ambiguous = $0 as? ChecksumFile.Problem else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try sums.entry(matching: "nope.qcow2")) {
            XCTAssertEqual($0 as? ChecksumFile.Problem, .notFound("nope.qcow2"))
        }
    }

    func testHostileLinesAreIgnored() throws {
        let hex = String(repeating: "a", count: 64)
        let body = """
        \(hex)  ../../etc/passwd
        \(hex)  dir/file.img
        \(String(repeating: "g", count: 64))  bad-hex.img
        \(String(repeating: "a", count: 63))  short.img
        SHA256 (evil name.img) = \(hex)
        \(hex)  good.img
        """
        let sums = try ChecksumFile(text: body, format: .gnu, algorithm: .sha256)
        XCTAssertEqual(sums.entries.map(\.file), ["good.img"])
        XCTAssertThrowsError(try ChecksumFile(text: "no checksums here\n", format: .gnu, algorithm: .sha256))
    }

    func testSingleFormatRejectsMoreThanOneEntry() {
        let hex = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try ChecksumFile(text: "\(hex)  a.img\n\(hex)  b.img\n", format: .single, algorithm: .sha256))
    }
}

// MARK: - Directory listings

final class DirectoryIndexTests: XCTestCase {
    func testFindsTheVersionedChecksumFile() throws {
        let html = try text("distro_fedora44_aarch64_index.html")
        XCTAssertEqual(try DirectoryIndex.file(in: html, matching: "Fedora-Cloud-44-*-aarch64-CHECKSUM"),
                       "Fedora-Cloud-44-1.7-aarch64-CHECKSUM")
    }

    func testRelativeLinksAndHostileHrefs() throws {
        let html = """
        <a href="./Leap-16.0-Minimal-VM.aarch64-Cloud.qcow2.sha256">x</a>
        <a href="../up.sha256">x</a> <a href="https://evil.example/a.sha256">x</a>
        <a href="/abs.sha256">x</a> <a href="dir/b.sha256">x</a> <a href="c.sha256?x=1">x</a>
        """
        XCTAssertEqual(try DirectoryIndex.file(in: html, matching: "*.sha256"), "Leap-16.0-Minimal-VM.aarch64-Cloud.qcow2.sha256")
    }

    func testNoneOrSeveralMatches() {
        XCTAssertThrowsError(try DirectoryIndex.file(in: "<a href=\"a.txt\">", matching: "*.iso"))
        XCTAssertThrowsError(try DirectoryIndex.file(in: "<a href=\"a-1.iso\"><a href=\"a-2.iso\">", matching: "a-*.iso"))
    }
}

// MARK: - Configuration

final class DistroConfigTests: XCTestCase {
    private let key = "distro-key-test.asc"
    private let fpr = String(repeating: "A", count: 40)

    private func config(_ edit: (inout DistroConfig) -> Void = { _ in }) -> DistroConfig {
        var c = DistroConfig(
            schema: 1, id: "demo", name: "Demo Linux",
            releases: [.init(id: "1.0", name: "Demo 1.0", isDefault: true, vars: ["codename": "first"]),
                       .init(id: "2.0", name: "Demo 2.0", isDefault: nil, vars: ["codename": "second"])],
            architectures: ["arm64": "aarch64"],
            image: .init(
                checksums: .init(url: "https://demo.example/{codename}/{arch}/SHA256SUMS", index: nil, pattern: nil,
                                 format: .gnu, algorithm: .sha256),
                signature: .init(kind: .detached, url: "{checksums}.asc", keys: [key], fingerprints: [fpr], note: nil),
                file: "demo-{release}-*-{arch}.qcow2", url: "{dir}{file}", format: .qcow2, member: nil),
            guest: .init(packageManager: "dnf"))
        edit(&c)
        return c
    }

    private func invalid(_ edit: (inout DistroConfig) -> Void, line: UInt = #line) {
        XCTAssertThrowsError(try config(edit).validate(), line: line)
    }

    /// A VM's distribution as people read it: the distro file's name, not
    /// its id made capital ("macOS", never "Macos"), with the release.
    func testADistributionIsShownByItsName() throws {
        let catalog = try DistroCatalog.bundled()
        XCTAssertEqual(catalog.label(distro: "macos", release: "26A434"), "macOS 26A434")
        XCTAssertEqual(catalog.label(distro: "ubuntu", release: "26.04"), "Ubuntu 26.04")
        XCTAssertEqual(catalog.label(distro: "ubuntu", release: nil), "Ubuntu")
        XCTAssertEqual(catalog.label(distro: "gone", release: "1"), "Gone 1", "a distro no longer known")
    }

    /// macOS is a distribution of its own kind: an Apple restore image
    /// (IPSW), the latest this Mac supports or one by its link or file; a
    /// Linux distro never takes one. Apple signs restore images and
    /// Virtualization checks them, so there is no checksum file.
    func testMacOSIsADistroOfItsOwnKind() throws {
        XCTAssertEqual(GuestOS.ready, [.linux, .macos], "made in any build, the release too")
        let mac = try XCTUnwrap(DistroCatalog.bundled().distro("macos"))
        XCTAssertEqual(mac.guestOS, .macos)
        XCTAssertEqual(mac.image.format, .ipsw)
        XCTAssertEqual(mac.image.url, DistroConfig.appleLatest)
        XCTAssertNil(mac.guest.packageManager)
        XCTAssertNoThrow(try mac.validate())
        var linked = mac
        linked.id = "macos-27"
        linked.image.url = "https://updates.cdn-apple.com/2026/UniversalMac_27.0_26A100_Restore.ipsw"
        XCTAssertNoThrow(try linked.validate(userFile: true))
        linked.image.url = "file:///Users/dev/Downloads/macOS%2027.ipsw"
        XCTAssertNoThrow(try linked.validate(userFile: true))
        for bad in ["https://x.example/disk.qcow2", "apple:older", "ftp://x.example/y.ipsw"] {
            linked.image.url = bad
            XCTAssertThrowsError(try linked.validate(userFile: true), bad)
        }
        var qcow = mac
        qcow.image.format = .qcow2
        XCTAssertThrowsError(try qcow.validate(), "macOS comes as an IPSW")
        invalid { $0.image.format = .ipsw }
        XCTAssertEqual(config().guestOS, .linux, "a distro that does not say is Linux")
    }

    func testValidConfigAndRoundTrip() throws {
        let c = config()
        XCTAssertNoThrow(try c.validate())
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try DistroConfig.decode(data), c)
        XCTAssertEqual(c.defaultRelease.id, "1.0")
    }

    func testTemplatesExpandPerReleaseAndArchitecture() throws {
        let c = config()
        let plan = try c.plan(release: "2.0", hostArch: "arm64")
        XCTAssertEqual(plan.checksums, .url(URL(string: "https://demo.example/second/aarch64/SHA256SUMS")!))
        XCTAssertEqual(plan.filePattern, "demo-2.0-*-aarch64.qcow2")
        let sums = URL(string: "https://demo.example/second/aarch64/SHA256SUMS")!
        XCTAssertEqual(try plan.signatureURL(checksums: sums)?.absoluteString,
                       "https://demo.example/second/aarch64/SHA256SUMS.asc")
        XCTAssertEqual(try plan.imageURL(file: "demo-2.0-7-aarch64.qcow2", checksums: sums).absoluteString,
                       "https://demo.example/second/aarch64/demo-2.0-7-aarch64.qcow2")
    }

    func testIndexedChecksums() throws {
        let c = config {
            $0.image.checksums!.url = nil
            $0.image.checksums!.index = "https://demo.example/{release}/{arch}/"
            $0.image.checksums!.pattern = "Demo-{release}-*-{arch}-CHECKSUM"
        }
        XCTAssertNoThrow(try c.validate())
        let plan = try c.plan(release: "1.0", hostArch: "arm64")
        XCTAssertEqual(plan.checksums, .index(URL(string: "https://demo.example/1.0/aarch64/")!,
                                              pattern: "Demo-1.0-*-aarch64-CHECKSUM"))
    }

    func testUnknownReleaseOrArchitecture() {
        XCTAssertThrowsError(try config().plan(release: "9.9", hostArch: "arm64"))
        XCTAssertThrowsError(try config().plan(release: "1.0", hostArch: "riscv64"))
    }

    func testValidationErrors() {
        invalid { $0.schema = 2 }
        invalid { $0.id = "Bad Id" }
        invalid { $0.releases = [] }
        invalid { $0.releases[1].isDefault = true }             // two defaults
        invalid { $0.releases[0].isDefault = nil }              // none
        invalid { $0.releases[1].id = "1.0" }                   // duplicate
        invalid { $0.architectures = ["x86_64": "amd64"] }      // no arm64
        invalid { $0.image.checksums!.url = "http://demo.example/SUMS" }
        invalid { $0.image.checksums!.url = "https://demo.example/{unknown}/SUMS" }
        invalid { $0.image.checksums!.index = "https://demo.example/" }  // both url and index
        invalid { $0.image.signature.fingerprints = ["abc"] }
        invalid { $0.image.signature.fingerprints = [] }
        invalid { $0.image.signature.keys = [] }
        invalid { $0.image.signature.url = nil }                 // detached needs a URL
        invalid { $0.image.signature.kind = .none }              // unsigned needs a note, no keys
        invalid { $0.image.format = .tarXz }                     // needs a member
        invalid { $0.image.member = "disk.raw" }                 // only for archives
        invalid { $0.image.file = "../{release}.img" }
        invalid { $0.image.url = "https://demo.example/{nope}" }
        invalid { $0.guest.sshd = "sshd" }
        invalid { $0.guest.sshd = "/usr/sbin/ssh d" }
        invalid { $0.guest.packageManager = "brew" }
    }

    func testUnsignedDistroNeedsAReason() throws {
        let c = config {
            $0.image.signature = .init(kind: .none, url: nil, keys: nil, fingerprints: nil,
                                       note: "The project publishes checksums over HTTPS only.")
        }
        XCTAssertNoThrow(try c.validate())
        XCTAssertFalse(c.isSigned)
    }

    func testOnlyOneDistroMayBePreferred() throws {
        var a = config()
        a.preferred = true
        var b = config { $0.id = "other"; $0.name = "Another" }
        b.preferred = true
        XCTAssertThrowsError(try DistroCatalog(distros: [a, b]) { _ in nil })
        b.preferred = nil
        XCTAssertEqual(try DistroCatalog(distros: [a, b]) { _ in nil }.defaultDistro?.id, "demo")
        a.preferred = nil
        XCTAssertEqual(try DistroCatalog(distros: [b, a]) { _ in nil }.defaultDistro?.id, "other",
                       "without a preference the first by name")
    }

    func testFutureSchemaIsRejectedWhenDecoding() {
        XCTAssertThrowsError(try DistroConfig.decode(Data(#"{"schema": 99, "id": "x"}"#.utf8)))
    }
}

// MARK: - Bundled catalog

final class DistroCatalogTests: XCTestCase {
    func testAllBundledDistrosLoadAndValidate() throws {
        let catalog = try DistroCatalog.bundled()
        XCTAssertEqual(catalog.distros.map(\.id), ["debian", "fedora", "macos", "opensuse", "ubuntu"])
        for d in catalog.distros where d.guestOS == .linux {
            XCTAssertNoThrow(try d.validate(), d.id)
            XCTAssertNoThrow(try d.plan(release: d.defaultRelease.id, hostArch: "arm64"), d.id)
        }
    }

    func testSignedDistrosPinKeysThatShipWithMonad() throws {
        let catalog = try DistroCatalog.bundled()
        for d in catalog.distros where d.isSigned {
            let keys = try catalog.trustedKeys(for: d)
            XCTAssertFalse(keys.isEmpty, d.id)
            XCTAssertEqual(Set(keys.map(\.primaryFingerprint)), Set(d.image.signature.fingerprints ?? []), d.id)
        }
        XCTAssertEqual(catalog.distros.filter(\.isSigned).map(\.id), ["fedora", "opensuse", "ubuntu"])
    }

    func testDefaultPlansMatchWhatTheDistrosPublish() throws {
        let catalog = try DistroCatalog.bundled()
        func plan(_ id: String) throws -> DistroConfig.Plan {
            let d = try XCTUnwrap(catalog.distro(id))
            return try d.plan(release: d.defaultRelease.id, hostArch: "arm64")
        }
        XCTAssertEqual(try plan("ubuntu").checksums,
                       .url(URL(string: "https://cloud-images.ubuntu.com/releases/26.04/release/SHA256SUMS")!))
        XCTAssertEqual(try plan("debian").checksums,
                       .url(URL(string: "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS")!))
        XCTAssertEqual(try plan("fedora").checksums,
                       .index(URL(string: "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/")!,
                              pattern: "Fedora-Cloud-44-*-aarch64-CHECKSUM"))
        XCTAssertEqual(try plan("opensuse").checksums,
                       .url(URL(string: "https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.aarch64-Cloud.qcow2.sha256")!))

        // The file patterns select exactly the published image in the real checksum files.
        let ubuntu = try ChecksumFile(text: text("pgp_ubuntu_SHA256SUMS"), format: .gnu, algorithm: .sha256)
        XCTAssertNoThrow(try ubuntu.entry(matching: plan("ubuntu").filePattern))
        let debian = try ChecksumFile(text: text("distro_debian13_SHA512SUMS"), format: .gnu, algorithm: .sha512)
        XCTAssertNoThrow(try debian.entry(matching: plan("debian").filePattern))
        let suse = try ChecksumFile(text: text("pgp_opensuse_leap.sha256"), format: .single, algorithm: .sha256)
        XCTAssertNoThrow(try suse.entry(matching: plan("opensuse").filePattern))
        XCTAssertEqual(try DirectoryIndex.file(in: text("distro_fedora44_aarch64_index.html"),
                                               matching: { if case .index(_, let p) = try plan("fedora").checksums { return p }; return "" }()),
                       "Fedora-Cloud-44-1.7-aarch64-CHECKSUM")
    }
}
