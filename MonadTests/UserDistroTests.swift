//
//  UserDistroTests.swift — distributions people add themselves (like Lima's
//  templates): one self-contained file per distro in ~/.monad/distros, its
//  signing key inside. Monad's own distros come first and stay; a user file
//  that is broken, too large or reuses a name is left out and says why.
//

import XCTest
@testable import Monad

/// A user distro file: images signed with `signer`'s key, carried inline.
func userDistroJSON(id: String = "rocky", name: String = "Rocky Linux", signer: TestSigner,
                    extra: String = "") -> String {
    let key = signer.armoredKey.replacingOccurrences(of: "\n", with: "\\n")
    return """
    {
      "schema": 1, "id": "\(id)", "name": "\(name)",
      "releases": [{ "id": "10", "name": "\(name) 10", "default": true }],
      "architectures": { "arm64": "aarch64" },
      "image": {
        "checksums": { "url": "https://r.example/{release}/{arch}/CHECKSUM", "format": "gnu", "algorithm": "sha256" },
        "signature": { "kind": "detached", "url": "{checksums}.asc",
                       "publicKeys": ["\(key)"], "fingerprints": ["\(signer.fingerprintHex)"] },
        "file": "\(id)-{release}-*.{arch}.qcow2", "url": "{dir}{file}", "format": "qcow2"
      }\(extra)
    }
    """
}

final class UserDistroCatalogTests: XCTestCase {
    private let signer = TestSigner()
    private var tmp: TempDir!
    private var dir: URL { tmp.url.appendingPathComponent("distros") }

    override func setUp() {
        tmp = TempDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func bundled() throws -> DistroCatalog { try DistroCatalog.bundled() }

    /// A file there is a distro like Monad's own, marked as added, its key
    /// read from the file itself.
    func testAUserFileAddsADistro() throws {
        try write("rocky.distro.json", userDistroJSON(signer: signer))
        let catalog = try bundled().adding(userDirectory: dir)
        let rocky = try XCTUnwrap(catalog.distro("rocky"))
        XCTAssertEqual(rocky.name, "Rocky Linux")
        XCTAssertEqual(catalog.added["rocky"], dir.appendingPathComponent("rocky.distro.json"))
        XCTAssertNil(catalog.added["ubuntu"])
        XCTAssertEqual(Set(catalog.distros.map(\.id)), ["debian", "fedora", "macos", "opensuse", "ubuntu", "rocky"])
        XCTAssertEqual(try catalog.trustedKeys(for: rocky).map(\.primaryFingerprint), [signer.fingerprintHex])
        XCTAssertEqual(rocky.guest, DistroConfig.GuestProfile(), "no guest section: the guest decides")
        XCTAssertEqual(catalog.problems, [])
    }

    /// No folder, an empty one, other files: just Monad's own.
    func testNothingThereIsMonadsOwn() throws {
        XCTAssertEqual(try bundled().adding(userDirectory: tmp.url.appendingPathComponent("none")).distros.count, 5)
        try write("notes.txt", "hello")
        try write("README.md", "# my distros")
        let catalog = try bundled().adding(userDirectory: dir)
        XCTAssertEqual(catalog.distros.count, 5)
        XCTAssertEqual(catalog.problems, [])
    }

    /// Each refused file says why, and the others still load.
    func testABadFileIsLeftOutAndSaysWhy() throws {
        try write("rocky.distro.json", userDistroJSON(signer: signer))
        try write("broken.distro.json", "{ not json")
        try write("ubuntu.distro.json", userDistroJSON(id: "ubuntu", name: "My Ubuntu", signer: signer))
        try write("alma.distro.json", userDistroJSON(id: "other", signer: signer))
        try write("plain.distro.json", userDistroJSON(id: "plain", signer: signer)
            .replacingOccurrences(of: "\"kind\": \"detached\"", with: "\"kind\": \"detached\", \"keys\": [\"x.asc\"]"))
        try write("wrongkey.distro.json", userDistroJSON(id: "wrongkey", signer: signer)
            .replacingOccurrences(of: signer.fingerprintHex, with: TestSigner().fingerprintHex))
        try write("huge.distro.json", userDistroJSON(id: "huge", signer: signer, extra: ", \"pad\": \"" + String(repeating: "x", count: 300_000) + "\""))
        let catalog = try bundled().adding(userDirectory: dir)
        XCTAssertNotNil(catalog.distro("rocky"))
        XCTAssertEqual(catalog.distro("ubuntu")?.name, "Ubuntu", "Monad's own stays")
        let why = Dictionary(uniqueKeysWithValues: catalog.problems.map { ($0.file, $0.message) })
        XCTAssertEqual(Set(why.keys), ["broken.distro.json", "ubuntu.distro.json", "alma.distro.json", "plain.distro.json",
                                       "huge.distro.json", "wrongkey.distro.json"])
        XCTAssertTrue(why["wrongkey.distro.json"]?.contains("pinned keys missing") ?? false, why["wrongkey.distro.json"] ?? "")
        XCTAssertTrue(why["ubuntu.distro.json"]?.contains("Monad's own") ?? false, why["ubuntu.distro.json"] ?? "")
        XCTAssertTrue(why["alma.distro.json"]?.contains("other.distro.json") ?? false, why["alma.distro.json"] ?? "")
        XCTAssertTrue(why["plain.distro.json"]?.contains("publicKeys") ?? false, why["plain.distro.json"] ?? "")
        XCTAssertTrue(why["huge.distro.json"]?.contains("too large") ?? false, why["huge.distro.json"] ?? "")
    }

    /// Plain http is the user's choice for a distro they add (a mirror on
    /// their own network), signed or not; Monad's own stay https, and
    /// nothing but http and https is an address.
    func testAnAddedDistroMayUsePlainHTTP() throws {
        try write("lan.distro.json", userDistroJSON(id: "lan", signer: signer)
            .replacingOccurrences(of: "https://r.example", with: "http://192.168.1.20:8080"))
        try write("ftp.distro.json", userDistroJSON(id: "ftp", signer: signer)
            .replacingOccurrences(of: "https://r.example", with: "ftp://r.example"))
        let catalog = try bundled().adding(userDirectory: dir)
        let lan = try XCTUnwrap(catalog.distro("lan"), "\(catalog.problems)")
        XCTAssertEqual(try lan.plan(release: "10", hostArch: "arm64").checksums,
                       .url(URL(string: "http://192.168.1.20:8080/10/aarch64/CHECKSUM")!))
        XCTAssertEqual(catalog.problems.map(\.file), ["ftp.distro.json"])
        var own = try XCTUnwrap(DistroCatalog.bundled().distro("ubuntu"))
        own.image.checksums!.url = "http://cloud-images.ubuntu.com/releases/{release}/release/SHA256SUMS"
        XCTAssertThrowsError(try own.validate(), "Monad's own stay https")
    }

    /// An image by its link alone, no checksum file: a distro the user adds
    /// may be that (an address or a file on this Mac), unsigned; Monad's
    /// own always have checksums.
    func testAnImageByItsLinkAlone() throws {
        let json = #"""
        { "schema": 1, "id": "mine", "name": "Mine",
          "releases": [{ "id": "1", "name": "Mine 1", "default": true }],
          "architectures": { "arm64": "aarch64" },
          "image": { "signature": { "kind": "none" }, "file": "x.qcow2",
                     "url": "LINK", "format": "qcow2" } }
        """#
        try write("mine.distro.json", json.replacingOccurrences(of: "LINK", with: "https://l.example/x.qcow2"))
        try write("local.distro.json", json.replacingOccurrences(of: "\"mine\"", with: "\"local\"")
            .replacingOccurrences(of: "LINK", with: "file:///Volumes/VMs/My%20Image.img"))
        try write("signed.distro.json", json.replacingOccurrences(of: "\"mine\"", with: "\"signed\"")
            .replacingOccurrences(of: "LINK", with: "https://l.example/x.qcow2")
            .replacingOccurrences(of: #""kind": "none""#, with: #""kind": "clearsigned""#))
        try write("ftp.distro.json", json.replacingOccurrences(of: "\"mine\"", with: "\"ftp\"")
            .replacingOccurrences(of: "LINK", with: "ftp://l.example/x.qcow2"))
        let catalog = try bundled().adding(userDirectory: dir)
        let mine = try XCTUnwrap(catalog.distro("mine"), "\(catalog.problems)")
        XCTAssertEqual(try mine.plan(release: "1", hostArch: "arm64").checksums, .direct(URL(string: "https://l.example/x.qcow2")!))
        XCTAssertEqual(try catalog.distro("local")?.plan(release: "1", hostArch: "arm64").checksums,
                       .direct(URL(fileURLWithPath: "/Volumes/VMs/My Image.img")))
        XCTAssertEqual(Set(catalog.problems.map(\.file)), ["signed.distro.json", "ftp.distro.json"])
        var own = mine
        XCTAssertThrowsError(try own.validate(), "Monad's own have checksums")
        own.image.url = "file:///tmp/x.qcow2"
        XCTAssertThrowsError(try own.validate(userFile: false))
    }

    /// The app (and MonadHost, which runs from inside it) may open plain
    /// http: macOS refuses it otherwise. Which addresses are allowed is
    /// Monad's own rule (above), not the system's.
    func testTheAppMayOpenPlainHTTP() throws {
        let ats = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
        XCTAssertEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
    }

    /// A link is not followed (the folder is the user's, a link could point
    /// anywhere), and a user distro cannot make itself the default.
    func testLinksAndPreferenceAreRefused() throws {
        let elsewhere = tmp.url.appendingPathComponent("elsewhere.json")
        try Data(userDistroJSON(id: "linked", signer: signer).utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("linked.distro.json"), withDestinationURL: elsewhere)
        try write("pushy.distro.json", userDistroJSON(id: "pushy", signer: signer, extra: ", \"preferred\": true"))
        let catalog = try bundled().adding(userDirectory: dir)
        XCTAssertNil(catalog.distro("linked"))
        XCTAssertNil(catalog.distro("pushy"))
        XCTAssertEqual(catalog.defaultDistro?.id, "ubuntu")
        XCTAssertEqual(Set(catalog.problems.map(\.file)), ["linked.distro.json", "pushy.distro.json"])
    }

    /// An unsigned distro is allowed, as for Monad's own, if it says why.
    /// A signature is recommended, not required: an unsigned distro the
    /// user adds loads with or without a reason (Monad's own must give one).
    func testAnUnsignedDistroLoadsWithOrWithoutAReason() throws {
        let unsigned = #"""
        { "schema": 1, "id": "nosig", "name": "No Signatures",
          "releases": [{ "id": "1", "name": "One", "default": true }],
          "architectures": { "arm64": "aarch64" },
          "image": {
            "checksums": { "url": "https://n.example/SHA256SUMS", "format": "gnu", "algorithm": "sha256" },
            "signature": { "kind": "none", "note": "The project publishes no signatures." },
            "file": "nosig-{arch}.qcow2", "url": "{dir}{file}", "format": "qcow2" } }
        """#
        try write("nosig.distro.json", unsigned)
        try write("noreason.distro.json", unsigned.replacingOccurrences(of: "\"nosig\"", with: "\"noreason\"")
            .replacingOccurrences(of: #", "note": "The project publishes no signatures.""#, with: ""))
        let catalog = try bundled().adding(userDirectory: dir)
        XCTAssertEqual(catalog.distro("nosig")?.isSigned, false)
        XCTAssertEqual(catalog.distro("noreason")?.image.signature.note, nil)
        XCTAssertEqual(catalog.problems, [])
    }
}

@MainActor
final class DistroStoreTests: XCTestCase {
    private let signer = TestSigner()
    private var tmp: TempDir!
    private var store: DistroStore!
    private var dir: URL { tmp.url.appendingPathComponent("distros") }

    override func setUp() async throws {
        tmp = TempDir()
        store = DistroStore(directory: dir, bundled: try DistroCatalog.bundled())
    }

    /// Settings › Distributions › Add: the file is checked first, shown,
    /// then kept in the folder under its id.
    func testAddingAFileKeepsItUnderItsName() throws {
        let data = Data(userDistroJSON(signer: signer).utf8)
        let preview = try store.check(data)
        XCTAssertEqual(preview.distro.id, "rocky")
        XCTAssertEqual(preview.checksums, "r.example")
        XCTAssertEqual(preview.verification, "OpenPGP signature by \(signer.fingerprintHex)")
        XCTAssertFalse(preview.replaces)
        try store.add(data)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("rocky.distro.json")), data)
        XCTAssertNotNil(store.catalog.distro("rocky"))
        XCTAssertTrue(try store.check(data).replaces, "the same id again replaces it")
    }

    func testABadFileIsNotKept() throws {
        XCTAssertThrowsError(try store.add(Data("{}".utf8)))
        XCTAssertThrowsError(try store.add(Data(userDistroJSON(id: "fedora", signer: signer).utf8))) {
            XCTAssertTrue("\($0.localizedDescription)".contains("Monad's own"), $0.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("fedora.distro.json").path))
    }

    /// Remove: not while a VM uses it (the VM could not be started), and
    /// never one of Monad's own.
    func testRemovingAnAddedDistro() throws {
        try store.add(Data(userDistroJSON(signer: signer).utf8))
        XCTAssertThrowsError(try store.remove("rocky", usedBy: ["web"])) {
            XCTAssertTrue($0.localizedDescription.contains("web"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try store.remove("ubuntu", usedBy: []))
        try store.remove("rocky", usedBy: [])
        XCTAssertNil(store.catalog.distro("rocky"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rocky.distro.json").path))
    }
}
