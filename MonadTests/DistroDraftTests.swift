//
//  DistroDraftTests.swift — Settings › Distributions › New Distribution…:
//  a form for the same file a user would write by hand. Fields in, the
//  file out (and back for Edit…), the key's fingerprint read from the key,
//  each problem said in the user's words.
//

import XCTest
@testable import Monad

final class DistroDraftTests: XCTestCase {
    private let signer = TestSigner()

    /// A draft as someone fills it in for Rocky Linux.
    private func rocky() -> DistroDraft {
        var d = DistroDraft()
        d.name = "Rocky Linux"
        d.releases = [DistroDraft.ReleaseRow(id: "10", name: "Rocky Linux 10", isDefault: true, vars: "")]
        d.arm64 = "aarch64"
        d.checksumsURL = "https://r.example/{release}/{arch}/CHECKSUM"
        d.checksumFormat = .bsd
        d.signature = .detached
        d.signatureURL = "{checksums}.asc"
        d.publicKey = signer.armoredKey
        d.file = "Rocky-{release}-GenericCloud-*.{arch}.qcow2"
        d.packageManager = "dnf"
        return d
    }

    /// The form makes the same file a person would write: valid as a user
    /// file, loadable as one, the fingerprint taken from the pasted key.
    func testAFilledFormMakesTheFile() throws {
        let draft = rocky()
        XCTAssertEqual(draft.id, "rocky-linux", "the id follows the name until it is edited")
        XCTAssertEqual(draft.fingerprints, [signer.fingerprintHex])
        XCTAssertEqual(draft.problems, [:])
        let config = try draft.config()
        XCTAssertEqual(config.image.signature.fingerprints, [signer.fingerprintHex])
        XCTAssertEqual(config.image.signature.publicKeys, [draft.publicKey], "the key as pasted")
        XCTAssertEqual(config.guest, DistroConfig.GuestProfile(packageManager: "dnf"))
        let loaded = try DistroCatalog.checkUserFile(try draft.json())
        XCTAssertEqual(loaded, config)
    }

    /// Edit…: a distro opens in the form as it was, and saves unchanged.
    func testADistroOpensInTheFormAsItWas() throws {
        var draft = rocky()
        draft.id = "rocky"
        draft.releases.append(DistroDraft.ReleaseRow(id: "9", name: "Rocky Linux 9", isDefault: false, vars: "minor=9.6, x=y"))
        let config = try draft.config()
        XCTAssertEqual(config.releases[1].vars, ["minor": "9.6", "x": "y"])
        let reopened = DistroDraft(config)
        XCTAssertEqual(reopened.id, "rocky")
        XCTAssertEqual(try reopened.config(), config)
        var renamed = reopened
        renamed.name = "Rocky"
        XCTAssertEqual(renamed.id, "rocky", "an existing id does not follow the name")
    }

    /// Each problem in the user's words, by field.
    func testProblemsAreSaidPlainly() {
        var d = DistroDraft()
        XCTAssertEqual(d.problems[.name], "Give it a name.")
        XCTAssertEqual(d.problems[.checksums], "Where is its checksum file? An https:// address.")
        XCTAssertEqual(d.problems[.file], "Which image? A file name as the checksum file lists it, * for what changes.")
        d = rocky()
        d.checksumsURL = "ftp://r.example/CHECKSUM"
        XCTAssertEqual(d.problems[.checksums], "An http:// or https:// address.")
        d.checksumsURL = "http://192.168.1.20/CHECKSUM"
        XCTAssertNil(d.problems[.checksums], "plain http is the user's choice")
        XCTAssertEqual(d.advice, "This address is plain http. The signature still vouches for the image.")
        d.signature = .none
        XCTAssertEqual(d.advice, "This address is plain http and nothing is signed: anything between this Mac and "
            + "that server could change the image. Fine on a network you trust.")
        d = rocky()
        d.publicKey = "not a key"
        XCTAssertEqual(d.problems[.key], "This is not an OpenPGP public key (paste the whole -----BEGIN PGP PUBLIC KEY BLOCK----- text).")
        d = rocky()
        d.releases = [DistroDraft.ReleaseRow(id: "10", name: "Rocky 10", isDefault: false, vars: "")]
        XCTAssertEqual(d.problems[.releases], "Pick the release new VMs get by default.")
        d = rocky()
        XCTAssertNil(d.advice, "signed: nothing to recommend")
        d.signature = .none
        XCTAssertEqual(d.problems, [:], "a signature is recommended, not required (a mirror you host yourself)")
        XCTAssertEqual(d.advice, "Without a signature Monad can only compare the image with checksums from the same server. "
            + "If the project signs its checksums, add its key.")
        XCTAssertEqual(try d.config().image.signature.publicKeys, nil, "an unsigned distro carries no key")
        XCTAssertNil(try d.config().image.signature.note, "no reason needed")
        d.note = "My own mirror."
        XCTAssertEqual(try d.config().image.signature.note, "My own mirror.")
        d = rocky()
        d.id = "ubuntu"
        XCTAssertEqual(DistroDraft.problem(id: d.id, builtIn: ["ubuntu"]), "That name is one of Monad's own distributions.")
        d.id = "Bad Id"
        XCTAssertEqual(d.problems[.id], "Lowercase letters, digits and dashes, starting with a letter.")
    }

    /// A key file chosen instead of pasted: its text goes in the form.
    func testAKeyFileFillsTheKey() throws {
        let tmp = TempDir()
        let file = tmp.url.appendingPathComponent("RPM-GPG-KEY.asc")
        try signer.armoredKey.write(to: file, atomically: true, encoding: .utf8)
        var d = rocky()
        d.publicKey = ""
        try d.readKey(from: file)
        XCTAssertEqual(d.fingerprints, [signer.fingerprintHex])
        XCTAssertThrowsError(try d.readKey(from: tmp.url.appendingPathComponent("none.asc")))
    }

    /// Apple silicon only (Monad runs guests natively, it emulates nothing),
    /// and the image address is optional: by default the image is next to
    /// its checksum file.
    func testTheFormAsksOnlyWhatItNeeds() throws {
        let d = rocky()
        XCTAssertEqual(d.imageURL, "", "nothing to fill in by default")
        let config = try d.config()
        XCTAssertEqual(config.image.url, "{dir}{file}")
        XCTAssertEqual(config.architectures, ["arm64": "aarch64"])
        XCTAssertEqual(DistroDraft(config).imageURL, "", "the default stays out of sight")
        var elsewhere = d
        elsewhere.imageURL = "https://cdn.example/{file}"
        XCTAssertEqual(DistroDraft(try elsewhere.config()).imageURL, "https://cdn.example/{file}")
    }

    /// A real distro, as someone would fill in the form for it: AlmaLinux
    /// 10's arm64 cloud images, their CHECKSUM signed by "AlmaLinux OS 10"
    /// (RSA 4096) with the key from repo.almalinux.org (fixtures fetched
    /// 2026-10-12). Monad's own verifier accepts it, and the pattern picks
    /// the image.
    func testAlmaLinux10AsAnExample() throws {
        var d = DistroDraft()
        d.name = "AlmaLinux"
        d.releases = [DistroDraft.ReleaseRow(id: "10", name: "AlmaLinux 10", isDefault: true, vars: "")]
        d.arm64 = "aarch64"
        d.checksumsURL = "https://repo.almalinux.org/almalinux/{release}/cloud/{arch}/images/CHECKSUM"
        d.signatureURL = "{checksums}.asc"
        d.publicKey = String(decoding: try fixture("pgp_key_almalinux10.asc"), as: UTF8.self)
        d.file = "AlmaLinux-{release}-GenericCloud-latest.{arch}.qcow2"
        d.packageManager = "dnf"
        XCTAssertEqual(d.problems, [:])
        XCTAssertEqual(d.fingerprints, ["EE6DB7B98F5BF5EDD9DA0DE5DEE5C11CC2A1E572"])
        let config = try d.config()
        let plan = try config.plan(release: "10", hostArch: "arm64")
        XCTAssertEqual(plan.checksums, .url(URL(string: "https://repo.almalinux.org/almalinux/10/cloud/aarch64/images/CHECKSUM")!))
        let sums = try fixture("distro_almalinux10_aarch64_CHECKSUM")
        let keys = try DistroCatalog(distros: [config], userFiles: true) { _ in nil }.trustedKeys(for: config)
        let v = try OpenPGP.verifyDetached(sums, signature: try fixture("distro_almalinux10_aarch64_CHECKSUM.asc"),
                                           keys: keys, now: Date(timeIntervalSince1970: 1_791_800_000))
        XCTAssertEqual(v.primaryFingerprint, "EE6DB7B98F5BF5EDD9DA0DE5DEE5C11CC2A1E572")
        let entry = try ChecksumFile(text: String(decoding: sums, as: UTF8.self), format: .gnu, algorithm: .sha256)
            .entry(matching: plan.filePattern)
        XCTAssertEqual(entry.file, "AlmaLinux-10-GenericCloud-latest.aarch64.qcow2")
        XCTAssertEqual(try plan.imageURL(file: entry.file, checksums: URL(string: "https://repo.almalinux.org/almalinux/10/cloud/aarch64/images/CHECKSUM")!).absoluteString,
                       "https://repo.almalinux.org/almalinux/10/cloud/aarch64/images/AlmaLinux-10-GenericCloud-latest.aarch64.qcow2")
    }

    private let almaDir = "https://repo.example/almalinux/10/cloud/aarch64/images/"

    /// What Monad found next to AlmaLinux's image: its CHECKSUM, signed.
    private func almaDraft() throws -> DistroDraft {
        var d = DistroDraft()
        d.use(try ImageLink(almaDir + "AlmaLinux-10-GenericCloud-latest.aarch64.qcow2"),
              found: ImageDiscovery(checksums: .init(url: URL(string: almaDir + "CHECKSUM")!, format: .gnu, algorithm: .sha256,
                                                     signature: .detached, signatureURL: URL(string: almaDir + "CHECKSUM.asc")!)))
        return d
    }

    /// Simple: the image's link is all it takes, like picking a disk image
    /// in a virtual machine app. The name and version come from the file
    /// name, the checksum file next to it checks every download, and the
    /// key that verifies its signature is optional.
    func testTheLinkIsAllItTakes() throws {
        var d = try almaDraft()
        XCTAssertEqual(d.name, "AlmaLinux")
        XCTAssertEqual(d.basicRelease, "10")
        XCTAssertEqual(d.id, "almalinux")
        XCTAssertEqual(d.problems, [:], "the key is optional")
        XCTAssertTrue(d.signatureFound)
        var c = try d.config()
        XCTAssertEqual(c.image.checksums?.url, almaDir + "CHECKSUM")
        XCTAssertEqual(c.image.file, "AlmaLinux-10-GenericCloud-latest.aarch64.qcow2")
        XCTAssertEqual(c.image.url, "{dir}{file}")
        XCTAssertEqual(c.image.signature.kind, .none)
        XCTAssertEqual(c.releases.map(\.name), ["AlmaLinux 10"])
        XCTAssertFalse(d.needsAdvanced)

        d.setKey(String(decoding: try fixture("pgp_key_almalinux10.asc"), as: UTF8.self))
        XCTAssertEqual(d.problems, [:])
        c = try d.config()
        XCTAssertEqual(c.image.signature.kind, .detached)
        XCTAssertEqual(c.image.signature.url, "{checksums}.asc")
        XCTAssertEqual(c.image.signature.fingerprints, ["EE6DB7B98F5BF5EDD9DA0DE5DEE5C11CC2A1E572"])
        let reopened = DistroDraft(c)
        XCTAssertEqual(reopened.link, almaDir + "AlmaLinux-10-GenericCloud-latest.aarch64.qcow2")
        XCTAssertFalse(reopened.needsAdvanced, "Edit… opens it as it was made")
        XCTAssertEqual(try reopened.config(), c)
        d.setKey("")
        XCTAssertEqual(try d.config().image.signature.kind, .none)
    }

    /// No checksum file next to it (or a file on this Mac): the image is
    /// used as it is, and the form says nothing checks it.
    func testWithoutChecksumsTheImageIsTakenAsItIs() throws {
        var d = DistroDraft()
        let file = URL(fileURLWithPath: "/Volumes/VMs/My Linux 2.raw")
        d.use(try ImageLink(file.path), found: ImageDiscovery(checksums: nil))
        XCTAssertEqual(d.name, "My")
        d.name = "Mine"
        XCTAssertEqual(d.problems, [:])
        let c = try d.config()
        XCTAssertNil(c.image.checksums)
        XCTAssertEqual(c.image.url, file.absoluteString)
        XCTAssertEqual(c.image.format, .raw)
        XCTAssertEqual(c.image.signature.kind, .none)
        XCTAssertFalse(d.signatureFound)
        XCTAssertEqual(d.advice, "Nothing to check this image against: it is used as it is. Fine for an image you trust.")
        XCTAssertEqual(DistroDraft(c).link, file.path)
        XCTAssertFalse(DistroDraft(c).needsAdvanced)

        d.use(try ImageLink("https://l.example/other-3.qcow2"), found: ImageDiscovery(checksums: nil))
        XCTAssertEqual(d.name, "Mine", "a name the user gave stays")
        XCTAssertEqual(d.basicRelease, "3", "the guessed version follows the image")
    }

    /// A compressed image: the distro says how, and Edit… shows it as it was.
    func testACompressedImageKeepsItsCompression() throws {
        var d = DistroDraft()
        d.use(try ImageLink("https://d.example/a/FreeBSD-15.0-RELEASE-arm64-aarch64-ufs.qcow2.xz"), found: ImageDiscovery(checksums: nil))
        let c = try d.config()
        XCTAssertEqual(c.image.compression, .xz)
        XCTAssertEqual(c.image.format, .qcow2)
        XCTAssertEqual(DistroDraft(c).compression, .xz)
        XCTAssertFalse(DistroDraft(c).needsAdvanced)
        d.use(try ImageLink("https://d.example/a/other-1.qcow2"), found: ImageDiscovery(checksums: nil))
        XCTAssertNil(try d.config().image.compression)
    }

    /// What is pasted is trimmed: a space or a line break around the image
    /// name made "bad image.file".
    func testWhatIsPastedIsTrimmed() throws {
        var d = rocky()
        d.file = " Rocky-{release}-GenericCloud-*.{arch}.qcow2 \n"
        d.checksumsURL = "https://r.example/{release}/{arch}/CHECKSUM\n"
        d.basicRelease = "10 "
        XCTAssertEqual(d.problems, [:])
        XCTAssertEqual(try d.config().image.file, "Rocky-{release}-GenericCloud-*.{arch}.qcow2")
    }

    /// Simple shows the link, the name, the version and the key: what it
    /// cannot show opens Advanced, so nothing is hidden that the file has.
    func testWhatSimpleCannotShowNeedsAdvanced() throws {
        XCTAssertFalse(DistroDraft().needsAdvanced, "New Distribution… opens Simple")
        var typing = DistroDraft()
        typing.link = "https://r.example/not-yet"
        XCTAssertFalse(typing.needsAdvanced, "a link being typed is Simple's")
        let base = try almaDraft()
        XCTAssertFalse(base.needsAdvanced)
        let changes: [(String, (inout DistroDraft) -> Void)] = [
            ("a templated checksum address", { $0.checksumsURL = "https://r.example/{release}/CHECKSUM" }),
            ("an image pattern", { $0.file = "AlmaLinux-*.qcow2" }),
            ("two releases", { $0.releases.append(.init(id: "9", name: "", isDefault: false, vars: "")) }),
            ("extra values", { $0.releases[0].vars = "minor=9.6" }),
            ("an id of its own", { $0.id = "rl" }),
            ("another arch word", { $0.arm64 = "arm64" }),
            ("a directory listing", { $0.useIndex = true; $0.indexPattern = "*-CHECKSUM" }),
            ("another signature address", { $0.setKey(self.signer.armoredKey); $0.signatureURL = "sig/{checksums}" }),
            ("an image elsewhere", { $0.imageURL = "https://cdn.example/{file}" }),
            ("a tar.xz", { $0.format = .tarXz; $0.member = "disk.raw" }),
            ("sshd elsewhere", { $0.sshd = "/usr/bin/sshd" }),
        ]
        for (what, change) in changes {
            var d = base
            change(&d)
            XCTAssertTrue(d.needsAdvanced, what)
        }
    }

    /// Check reads the checksum file before it verifies anything: how its
    /// lines look, which hash, whether it is signed inside, and which
    /// images it lists (named with {release} and {arch}; first the ones
    /// that do not change, cloud images, short names). One image is taken
    /// at once.
    func testCheckLearnsFromTheChecksumFile() throws {
        var d = DistroDraft()
        d.name = "AlmaLinux"
        d.basicRelease = "10"
        d.checksumFormat = .bsd
        d.algorithm = .sha512
        let images = try d.learn(from: String(decoding: try fixture("distro_almalinux10_aarch64_CHECKSUM"), as: UTF8.self))
        XCTAssertEqual(d.checksumFormat, .gnu)
        XCTAssertEqual(d.algorithm, .sha256)
        XCTAssertEqual(d.signature, .detached)
        XCTAssertEqual(images.count, 12)
        XCTAssertEqual(Array(images.prefix(3)), ["AlmaLinux-{release}-GenericCloud-latest.{arch}.qcow2",
                                                 "AlmaLinux-{release}-GenericCloud-ext4-latest.{arch}.qcow2",
                                                 "AlmaLinux-{release}-OpenNebula-latest.{arch}.qcow2"])
        XCTAssertTrue(images.contains("AlmaLinux-{release}-GenericCloud-10.2-20261012.0.{arch}.qcow2"),
                      "only the release's own place becomes {release}")
        XCTAssertEqual(d.file, "", "several images: the user picks")

        let bsd = """
        -----BEGIN PGP SIGNED MESSAGE-----
        Hash: SHA512

        SHA512 (x-1-aarch64.raw) = \(String(repeating: "ab", count: 64))
        SHA512 (x-1-x86_64.raw) = \(String(repeating: "cd", count: 64))
        SHA512 (x-1-aarch64.iso) = \(String(repeating: "ef", count: 64))
        -----BEGIN PGP SIGNATURE-----
        abc
        -----END PGP SIGNATURE-----
        """
        var x = DistroDraft()
        x.name = "X"
        x.basicRelease = "1"
        XCTAssertEqual(try x.learn(from: bsd), ["x-{release}-{arch}.raw"], "disk images for this Mac only")
        XCTAssertEqual(x.checksumFormat, .bsd)
        XCTAssertEqual(x.algorithm, .sha512)
        XCTAssertEqual(x.signature, .clearsigned)
        XCTAssertEqual(x.file, "x-{release}-{arch}.raw", "the only one is taken")
        XCTAssertEqual(x.format, .raw, "the format follows the file name")
        x.signature = .none
        _ = try x.learn(from: bsd)
        XCTAssertEqual(x.signature, .none, "unsigned stays the user's choice")

        XCTAssertThrowsError(try x.learn(from: "<html><body>Not Found</body></html>")) {
            XCTAssertEqual($0.localizedDescription, "This is not a checksum file: no line is a hash and a file name. "
                + "Check its address.")
        }
    }

    /// Check needs only enough to fetch the checksum file: the image and
    /// the key can come after it.
    func testCheckCanRunBeforeTheImageAndKey() throws {
        var d = DistroDraft()
        d.name = "AlmaLinux"
        d.basicRelease = "10"
        d.checksumsURL = "https://repo.almalinux.org/almalinux/{release}/cloud/{arch}/images/CHECKSUM"
        XCTAssertNotNil(d.problems[.file])
        XCTAssertNotNil(d.problems[.key])
        XCTAssertTrue(d.canCheck)
        let plan = try d.probe().plan(release: "10", hostArch: "arm64")
        XCTAssertEqual(plan.checksums, .url(URL(string: "https://repo.almalinux.org/almalinux/10/cloud/aarch64/images/CHECKSUM")!))
        d.checksumsURL = ""
        XCTAssertFalse(d.canCheck)
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil), name))
    }

    func testIdsAreMadeFromNames() {
        XCTAssertEqual(DistroDraft.slug("AlmaLinux OS 10"), "almalinux-os-10")
        XCTAssertEqual(DistroDraft.slug("  9 Lives!! "), "d-9-lives")
        XCTAssertEqual(DistroDraft.slug(String(repeating: "a", count: 50)).count, 32)
    }
}

/// The link the form's Simple view takes: an address or a file on this Mac.
final class ImageLinkTests: XCTestCase {
    func testALinkOrAFile() throws {
        XCTAssertEqual(try ImageLink("  https://r.example/a/x.qcow2 \n").url.absoluteString, "https://r.example/a/x.qcow2")
        XCTAssertEqual(try ImageLink("http://192.168.1.20/x.img").url.absoluteString, "http://192.168.1.20/x.img")
        XCTAssertEqual(try ImageLink("/Volumes/VMs/My Image.img").url, URL(fileURLWithPath: "/Volumes/VMs/My Image.img"))
        XCTAssertEqual(try ImageLink("file:///tmp/x.raw").url, URL(fileURLWithPath: "/tmp/x.raw"))
        XCTAssertEqual(try ImageLink("~/x.raw").url, URL(fileURLWithPath: NSHomeDirectory() + "/x.raw"))
        XCTAssertTrue(try ImageLink("/tmp/x.raw").isLocal)
        XCTAssertEqual(try ImageLink("https://r.example/a/x.qcow2").directory.absoluteString, "https://r.example/a/")
        func refused(_ text: String) -> String {
            do { _ = try ImageLink(text); return "accepted" } catch { return error.localizedDescription }
        }
        XCTAssertEqual(refused(" "), "Paste the image's address, or choose the file.")
        XCTAssertEqual(refused("ftp://r.example/x.qcow2"), "An http://, https:// address or a file on this Mac.")
        XCTAssertEqual(refused("https://r.example/a/"),
                       "This is not a disk image. Monad takes .qcow2, .img and .raw images, also compressed as .xz or .gz.")
        XCTAssertEqual(refused("https://r.example/x.iso"),
                       "This is not a disk image. Monad takes .qcow2, .img and .raw images, also compressed as .xz or .gz.")
    }

    /// Compressed images as projects publish them: .xz and .gz around a
    /// .qcow2, .img or .raw. An image for Intel PCs is refused (Monad runs
    /// arm64 images natively and emulates nothing).
    func testCompressedImagesAndTheirArchitecture() throws {
        let bsd = try ImageLink("https://download.example/releases/VM-IMAGES/15.0-RELEASE/aarch64/Latest/"
            + "FreeBSD-15.0-RELEASE-arm64-aarch64-ufs.qcow2.xz")
        XCTAssertEqual(bsd.format, .qcow2)
        XCTAssertEqual(bsd.compression, .xz)
        XCTAssertEqual(bsd.guess.name, "FreeBSD")
        XCTAssertEqual(bsd.guess.release, "15.0")
        XCTAssertEqual(try ImageLink("/tmp/x.raw.gz").format, .raw)
        XCTAssertEqual(try ImageLink("/tmp/x.raw.gz").compression, .gz)
        XCTAssertEqual(try ImageLink("/tmp/x.img.xz").compression, .xz)
        XCTAssertNil(try ImageLink("/tmp/x.qcow2").compression)
        func refused(_ text: String) -> String {
            do { _ = try ImageLink(text); return "accepted" } catch { return error.localizedDescription }
        }
        XCTAssertEqual(refused("https://d.example/releases/VM-IMAGES/15.0-RELEASE/amd64/Latest/FreeBSD-15.0-RELEASE-amd64-ufs.qcow2.xz"),
                       "This image is for Intel and AMD PCs (amd64). Monad runs arm64 images natively: "
                       + "look for aarch64 or arm64 in the name.")
        XCTAssertEqual(refused("https://d.example/noble-server-cloudimg-amd64.img"), refused("https://d.example/x86_64/a.qcow2"))
        XCTAssertEqual(refused("https://d.example/a.qcow2.zst"),
                       "This is not a disk image. Monad takes .qcow2, .img and .raw images, also compressed as .xz or .gz.")
    }

    func testTheFormatFromTheName() throws {
        XCTAssertEqual(try ImageLink("https://r.example/x.qcow2").format, .qcow2)
        XCTAssertEqual(try ImageLink("https://r.example/x.img").format, .qcow2, "Monad looks inside: a raw .img is read as raw")
        XCTAssertEqual(try ImageLink("https://r.example/x.RAW").format, .raw)
    }

    func testANameAndVersionFromTheFileName() throws {
        func guess(_ file: String) throws -> String {
            let g = try ImageLink("https://r.example/" + file).guess
            return "\(g.name) \(g.release)"
        }
        XCTAssertEqual(try guess("AlmaLinux-10-GenericCloud-latest.aarch64.qcow2"), "AlmaLinux 10")
        XCTAssertEqual(try guess("Rocky-10-GenericCloud-Base.latest.aarch64.qcow2"), "Rocky 10")
        XCTAssertEqual(try guess("debian-13-genericcloud-arm64.qcow2"), "Debian 13")
        XCTAssertEqual(try guess("Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2"), "Fedora 44")
        XCTAssertEqual(try guess("openSUSE-Leap-16.0-Minimal-VM.aarch64-Cloud.qcow2"), "openSUSE 16.0")
        XCTAssertEqual(try guess("noble-server-cloudimg-arm64.img"), "Noble latest")
    }
}
