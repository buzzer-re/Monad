//
//  LimaInstancesTests.swift — finding the Lima VMs on this Mac (Phase 9):
//  `limactl list --json` read, a scan of ~/.lima when limactl is missing,
//  which instances can be booted in place and why not, the distro an
//  instance runs (recognized from the distro files' own download hosts),
//  and whether Lima is running one now.
//

import XCTest
@testable import Monad

final class LimaInstancesTests: XCTestCase {
    /// `limactl list --json`: one object per line (Lima 1.x, trimmed).
    private let listJSON = """
    {"name":"default","hostname":"lima-default","status":"Stopped","dir":"/Users/dev/.lima/default","vmType":"vz","arch":"aarch64","cpus":4,"memory":4294967296,"disk":107374182400,"config":{"vmType":"vz","arch":"aarch64","images":[{"location":"https://cloud-images.ubuntu.com/releases/24.04/release-20250115/ubuntu-24.04-server-cloudimg-arm64.img","arch":"aarch64"}],"mounts":[{"location":"/Users/dev","mountPoint":"/Users/dev","writable":false},{"location":"/tmp/lima","mountPoint":"/tmp/lima","writable":true}],"user":{"name":"dev","home":"/home/dev.linux","uid":501}},"limaVersion":"1.0.6"}
    {"name":"old","status":"Stopped","dir":"/Users/dev/.lima/old","vmType":"qemu","arch":"aarch64","cpus":2,"memory":2147483648,"config":{"images":[{"location":"https://cloud.debian.org/images/cloud/bookworm/20250115-2000/debian-12-genericcloud-arm64-20250115-2000.qcow2"}]}}
    {"name":"fed","status":"Running","dir":"/Users/dev/.lima/fed","vmType":"vz","arch":"aarch64","cpus":2,"memory":2147483648,"hostAgentPID":4242,"config":{"images":[{"location":"https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-41-1.4.aarch64.qcow2"}]}}
    not json at all
    """

    func testTheListIsRead() throws {
        let list = LimaInstances.parseList(listJSON, macUser: "dev")
        XCTAssertEqual(list.map(\.name), ["default", "old", "fed"], "a bad line is skipped")
        let d = try XCTUnwrap(list.first)
        XCTAssertEqual(d.dir.path, "/Users/dev/.lima/default")
        XCTAssertEqual(d.disk.path, "/Users/dev/.lima/default/diffdisk")
        XCTAssertEqual(d.status, .stopped)
        XCTAssertEqual(d.vmType, "vz")
        XCTAssertEqual(d.cpus, 4)
        XCTAssertEqual(d.memoryBytes, 4 << 30)
        XCTAssertEqual(d.diskBytes, 100 << 30)
        XCTAssertEqual(d.user, "dev")
        XCTAssertEqual(d.home, "/home/dev.linux")
        XCTAssertEqual(d.mounts, [.init(location: "/Users/dev", mountPoint: "/Users/dev", writable: false),
                                  .init(location: "/tmp/lima", mountPoint: "/tmp/lima", writable: true)])
        XCTAssertEqual(list[2].status, .running)
    }

    /// Lima before 1.0 says nothing about the user: it is the Mac's, with
    /// its home at /home/<user>.linux.
    func testTheUserDefaultsToLimas() throws {
        let old = try XCTUnwrap(LimaInstances.parseList(listJSON, macUser: "dev").dropFirst().first)
        XCTAssertEqual(old.user, "dev")
        XCTAssertEqual(old.home, "/home/dev.linux")
    }

    func testOnlyAStoppedVZInstanceWithARawDiskCanBeShared() throws {
        let home = TempDir()
        func instance(_ name: String, vmType: String = "vz", status: LimaInstance.Status = .stopped,
                      disk: Data? = Data(count: 4096)) throws -> LimaInstance {
            let dir = home.url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let disk { try disk.write(to: dir.appendingPathComponent("diffdisk")) }
            return LimaInstance(name: name, dir: dir, status: status, vmType: vmType, arch: "aarch64", cpus: 2,
                                memoryBytes: 2 << 30, imageLocations: [], user: "dev", home: "/home/dev.linux", mounts: [])
        }
        XCTAssertNil(LimaDisk.problem(try instance("ok"), hostArch: "aarch64"))
        XCTAssertEqual(LimaDisk.problem(try instance("q", vmType: "qemu"), hostArch: "aarch64"),
                       "Lima runs “q” with QEMU. Only VMs Lima runs with Apple's virtualization (vmType vz) can be used in place.")
        XCTAssertEqual(LimaDisk.problem(try instance("new", disk: nil), hostArch: "aarch64"),
                       "“new” has no disk yet. Start it once in Lima.")
        XCTAssertEqual(LimaDisk.problem(try instance("qcow", disk: Data([0x51, 0x46, 0x49, 0xFB]) + Data(count: 100)),
                                        hostArch: "aarch64"),
                       "The disk of “qcow” is in QEMU's format, which Apple's virtualization cannot open.")
        XCTAssertEqual(LimaDisk.problem(try instance("busy", status: .running), hostArch: "aarch64"),
                       "Lima is running “busy”. Stop it first with limactl stop busy.")
        XCTAssertEqual(LimaDisk.problem(try instance("intel"), hostArch: "x86_64"),
                       "“intel” is an aarch64 VM, and this Mac runs x86_64 ones.")
    }

    /// Lima 2.1 renamed the disk `disk`; older instances keep `diffdisk`, and
    /// migrated ones have `disk` as a link to it.
    func testTheDiskIsFoundUnderEitherName() throws {
        let home = TempDir()
        let fm = FileManager.default
        let dir = home.url.appendingPathComponent("vm")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "vmType: vz\n".write(to: dir.appendingPathComponent("lima.yaml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(LimaDisk.diskFile(in: dir).lastPathComponent, "diffdisk", "none yet")
        try Data(count: 4096).write(to: dir.appendingPathComponent("diffdisk"))
        XCTAssertEqual(LimaDisk.diskFile(in: dir).lastPathComponent, "diffdisk")
        XCTAssertNoThrow(try LimaDisk.check(dir: dir))

        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("disk").path, withDestinationPath: "diffdisk")
        XCTAssertEqual(LimaDisk.diskFile(in: dir).lastPathComponent, "disk")
        XCTAssertNoThrow(try LimaDisk.check(dir: dir), "a migrated instance")
        XCTAssertEqual(AttachedDisk(lima: "vm", dir: dir.path).disk.lastPathComponent, "disk")
        try fm.removeItem(at: dir.appendingPathComponent("disk"))
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("disk").path, withDestinationPath: "/etc/hosts")
        XCTAssertThrowsError(try LimaDisk.check(dir: dir), "a link out of the folder is not Lima's disk")

        try fm.removeItem(at: dir.appendingPathComponent("disk"))
        try fm.removeItem(at: dir.appendingPathComponent("diffdisk"))
        try Data(count: 4096).write(to: dir.appendingPathComponent("disk"))
        XCTAssertNoThrow(try LimaDisk.check(dir: dir), "Lima 2.1 and later")
        let i = LimaInstance(name: "vm", dir: dir, status: .stopped, vmType: "vz", arch: "aarch64", cpus: 2,
                             memoryBytes: 2 << 30, imageLocations: [], user: "dev", home: "/home/dev.guest", mounts: [])
        XCTAssertEqual(i.disk.lastPathComponent, "disk")
        XCTAssertNil(LimaDisk.problem(i, hostArch: "aarch64"), "it has a disk")
    }

    /// Lima 2.1 made /home/<user>.guest the default home (/home/<user>.linux
    /// before), and Lima 1.0 and later never names the user admin.
    func testTheDefaultUserAndHomeFollowLimasVersion() {
        func parsed(_ version: String?, macUser: String = "dev") -> LimaInstance? {
            let v = version.map { #","limaVersion":"\#($0)""# } ?? ""
            return LimaInstances.parseList(#"{"name":"a","status":"Stopped","dir":"/Users/dev/.lima/a","vmType":"vz"\#(v)}"#,
                                           macUser: macUser).first
        }
        XCTAssertEqual(parsed("2.1.0")?.home, "/home/dev.guest")
        XCTAssertEqual(parsed("2.2.1")?.home, "/home/dev.guest")
        XCTAssertEqual(parsed("1.0.6")?.home, "/home/dev.linux")
        XCTAssertEqual(parsed("<unknown>")?.home, "/home/dev.guest", "a development build of Lima")
        XCTAssertEqual(parsed("")?.home, "/home/dev.linux", "made before Lima 0.20")
        XCTAssertEqual(parsed(nil)?.home, "/home/dev.linux")
        XCTAssertEqual(parsed("1.0.0", macUser: "admin")?.user, "lima")
        XCTAssertEqual(parsed("1.0.0", macUser: "admin")?.home, "/home/lima.linux")
        XCTAssertEqual(parsed("0.23.0", macUser: "admin")?.user, "admin")
    }

    /// What Lima says about an instance counts: one it is still setting up or
    /// reports broken is left alone, and Monad needs sudo without a password.
    func testLimasStateAndSudoAreRespected() throws {
        let home = TempDir()
        let dir = home.url.appendingPathComponent("x")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: dir.appendingPathComponent("disk"))
        func instance(_ status: LimaInstance.Status, sudo: Bool? = nil) -> LimaInstance {
            LimaInstance(name: "x", dir: dir, status: status, vmType: "vz", arch: "aarch64", cpus: 2, memoryBytes: 2 << 30,
                         imageLocations: [], user: "dev", home: "/home/dev.guest", mounts: [], passwordlessSudo: sudo)
        }
        XCTAssertNil(LimaDisk.problem(instance(.stopped), hostArch: "aarch64"))
        XCTAssertNil(LimaDisk.problem(instance(.stopped, sudo: true), hostArch: "aarch64"))
        XCTAssertEqual(LimaDisk.problem(instance(.installing), hostArch: "aarch64"), "Lima is still setting up “x”.")
        XCTAssertEqual(LimaDisk.problem(instance(.broken), hostArch: "aarch64"), "Lima reports “x” as broken. limactl list says why.")
        XCTAssertEqual(LimaDisk.problem(instance(.stopped, sudo: false), hostArch: "aarch64"),
                       "Lima set up “x” so that sudo asks for a password. Monad needs passwordlessSudo, Lima's default.")
        let parsed = LimaInstances.parseList(
            #"{"name":"x","status":"Installing","dir":"/Users/dev/.lima/x","vmType":"vz","config":{"user":{"passwordlessSudo":false}}}"#,
            macUser: "dev")
        XCTAssertEqual(parsed.first?.status, .installing)
        XCTAssertEqual(parsed.first?.passwordlessSudo, false)
    }

    /// Lima holds <dir>/ha.pid while its host agent runs the instance.
    func testLimaRunningAnInstanceIsSeenFromItsHostAgent() throws {
        let tmp = TempDir()
        let dir = tmp.url
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertFalse(LimaDisk.isRunning(dir: dir))
        try "\(getpid())\n".write(to: dir.appendingPathComponent("ha.pid"), atomically: true, encoding: .utf8)
        XCTAssertTrue(LimaDisk.isRunning(dir: dir))
        try "999999999\n".write(to: dir.appendingPathComponent("ha.pid"), atomically: true, encoding: .utf8)
        XCTAssertFalse(LimaDisk.isRunning(dir: dir), "a host agent that is gone left its file")
        try "garbage".write(to: dir.appendingPathComponent("ha.pid"), atomically: true, encoding: .utf8)
        XCTAssertFalse(LimaDisk.isRunning(dir: dir))
    }

    /// MonadHost only boots a disk that is a Lima VM's: a folder with a
    /// lima.yaml and a regular file named diffdisk (not a link, not a device).
    func testOnlyARealLimaFolderCanBeAttached() throws {
        let home = TempDir()
        let fm = FileManager.default
        let dir = home.url.appendingPathComponent("default")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let disk = dir.appendingPathComponent("diffdisk")
        try Data(count: 4096).write(to: disk)
        XCTAssertThrowsError(try LimaDisk.check(dir: dir), "no lima.yaml")
        try "vmType: vz\n".write(to: dir.appendingPathComponent("lima.yaml"), atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try LimaDisk.check(dir: dir))
        try fm.removeItem(at: disk)
        XCTAssertThrowsError(try LimaDisk.check(dir: dir), "no disk")
        try fm.createSymbolicLink(at: disk, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertThrowsError(try LimaDisk.check(dir: dir), "a link")
        try fm.removeItem(at: disk)
        try fm.createDirectory(at: disk, withIntermediateDirectories: false)
        XCTAssertThrowsError(try LimaDisk.check(dir: dir), "a folder")
    }

    /// The distro is recognized by the download host in each distro's own
    /// file, the release when the URL names one Monad has.
    func testTheDistroIsRecognizedFromTheImage() throws {
        let catalog = try XCTUnwrap(DistroCatalog.live)
        let list = LimaInstances.parseList(listJSON, macUser: "dev")
        XCTAssertEqual(catalog.recognize(imageLocations: list[0].imageLocations)?.distro, "ubuntu")
        XCTAssertEqual(catalog.recognize(imageLocations: list[0].imageLocations)?.release, "24.04")
        XCTAssertEqual(catalog.recognize(imageLocations: list[1].imageLocations)?.distro, "debian")
        XCTAssertEqual(catalog.recognize(imageLocations: list[1].imageLocations)?.release, "12", "bookworm")
        XCTAssertEqual(catalog.recognize(imageLocations: list[2].imageLocations)?.distro, "fedora")
        XCTAssertNil(catalog.recognize(imageLocations: list[2].imageLocations)?.release, "41 is not one Monad has")
        XCTAssertNil(catalog.recognize(imageLocations: ["/Users/dev/images/custom.img"]))
        XCTAssertNil(catalog.recognize(imageLocations: ["https://example.com/ubuntu-24.04.img"]))
        XCTAssertNil(catalog.recognize(imageLocations: ["https://cloud-images.ubuntu.com.evil.example/24.04/x.img"]))
    }

    /// Without limactl, ~/.lima is scanned: an instance is a folder with a
    /// lima.yaml; vz instances have a vz-identifier.
    func testWithoutLimactlTheLimaFolderIsScanned() async throws {
        let home = TempDir()
        let fm = FileManager.default
        for (name, vz) in [("default", true), ("q", false), ("_config", false)] {
            let dir = home.url.appendingPathComponent(name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard !name.hasPrefix("_") else { continue }
            try "2.1.0\n".write(to: dir.appendingPathComponent("lima-version"), atomically: true, encoding: .utf8)
            try "images:\n- location: \"https://cloud-images.ubuntu.com/releases/24.04/release/x.img\"\n"
                .write(to: dir.appendingPathComponent("lima.yaml"), atomically: true, encoding: .utf8)
            try Data(count: 4096).write(to: dir.appendingPathComponent("diffdisk"))
            if vz { try Data().write(to: dir.appendingPathComponent("vz-identifier")) }
        }
        let runner = FakeCommandRunner { _ in .fail(1, "") }
        let found = await LimaInstances(runner: runner, limactlCandidates: ["/nonexistent/limactl"], limaHome: home.url,
                                        macUser: "dev").list()
        XCTAssertEqual(found.map(\.name), ["default", "q"])
        XCTAssertEqual(found.map(\.vmType), ["vz", "qemu"])
        XCTAssertEqual(found[0].imageLocations, ["https://cloud-images.ubuntu.com/releases/24.04/release/x.img"])
        XCTAssertEqual(found[0].user, "dev")
        XCTAssertEqual(found[0].diskBytes, 4096, "the disk's own size")
        XCTAssertEqual(found[0].home, "/home/dev.guest", "from its lima-version")
        XCTAssertTrue(runner.calls.isEmpty, "no limactl to ask")
    }

    func testLimactlIsAskedWhenItIsThere() async throws {
        let tmp = TempDir(), empty = TempDir()
        let limactl = tmp.url.appendingPathComponent("limactl")
        try FileManager.default.createDirectory(at: limactl.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: limactl.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let runner = FakeCommandRunner { [listJSON] _ in .ok(listJSON) }
        let found = await LimaInstances(runner: runner, limactlCandidates: [limactl.path], limaHome: empty.url,
                                        macUser: "dev").list()
        XCTAssertEqual(found.map(\.name), ["default", "old", "fed"])
        XCTAssertEqual(runner.calls.map(\.arguments), [["list", "--json"]])
        XCTAssertEqual(runner.calls.first?.executable, limactl.path)
    }
}
