//
//  GuestSharesTests.swift — the script that mounts shared folders inside the
//  guest. It runs here under /bin/sh with stand-ins for mount, umount,
//  mountpoint and mkdir, so its reconciliation is tested for real.
//

import XCTest
@testable import Monad

final class GuestSharesTests: XCTestCase {
    private var tmp: TempDir!
    private var stubs: URL!

    override func setUpWithError() throws {
        tmp = TempDir()
        stubs = tmp.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)
        let state = tmp.url.appendingPathComponent("mounted").path
        let log = tmp.url.appendingPathComponent("log").path
        // A mount table in a file; every change is logged.
        try stub("mountpoint", #"[ "$1" = -q ] && shift; grep -qxF "$1" '\#(state)'"#)
        try stub("mkdir", "exit 0")
        try stub("mount", #"""
            case "$1" in
            -t) echo "$4" >> '\#(state)'; echo "mount $3 $4" >> '\#(log)' ;;
            --bind) [ -n "${FAIL_BIND:-}" ] && { echo "mount: $3: special device $2 does not exist." >&2; exit 32; }; echo "$3" >> '\#(state)'; echo "bind $2 $3" >> '\#(log)' ;;
            -o) echo "remount ${2##*,} $3" >> '\#(log)' ;;
            esac
            """#)
        try stub("umount", #"""
            [ "$1" = -l ] && shift
            grep -vxF "$1" '\#(state)' > '\#(state).tmp'; mv '\#(state).tmp' '\#(state)'
            echo "umount $1" >> '\#(log)'
            """#)
        try stub("rmdir", #"echo "rmdir $1" >> '\#(log)'"#)
        // mkdir is a stand-in that makes nothing: the record's folder exists already.
        try FileManager.default.createDirectory(at: tmp.url.appendingPathComponent("lib"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state, contents: nil)
    }

    private func stub(_ name: String, _ body: String) throws {
        let url = stubs.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private var log: [String] {
        let text = (try? String(contentsOf: tmp.url.appendingPathComponent("log"), encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: tmp.url.appendingPathComponent("log"))
        return text.split(separator: "\n").map(String.init)
    }

    @discardableResult
    private func run(_ shares: [SharedFolder], env: [String: String] = [:], rebind: Bool = false) throws -> String {
        try runAll(shares, env: env, rebind: rebind).out
    }

    /// stdout (the outcome) and stderr (what it did, for the debug log).
    private func runAll(_ shares: [SharedFolder], env: [String: String] = [:],
                        rebind: Bool = false) throws -> (out: String, err: String) {
        let script = GuestShares.script(for: shares,
                                        root: tmp.url.appendingPathComponent("virtiofs").path,
                                        list: tmp.url.appendingPathComponent("shares").path,
                                        made: tmp.url.appendingPathComponent("lib/shares-made").path, rebind: rebind)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-s"]
        p.environment = ["PATH": "\(stubs.path):/usr/bin:/bin"].merging(env) { $1 }
        let input = Pipe(), output = Pipe()
        let errors = tmp.url.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        p.standardInput = input
        p.standardOutput = output
        p.standardError = try FileHandle(forWritingTo: errors)
        try p.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: out, as: UTF8.self), try String(contentsOf: errors, encoding: .utf8))
    }

    private let root: String = "virtiofs"
    private func src(_ path: String) -> String { tmp.url.appendingPathComponent(root).path + "/" + path }

    func testMountsTheShareOnceAndBindsEachFolder() throws {
        let out = try run([SharedFolder(hostPath: "/Users/x/src", guestPath: "/home/dev/src", readOnly: true),
                           SharedFolder(hostPath: "/Users/x/data", guestPath: "/mnt/data", readOnly: false)])
        XCTAssertEqual(out, "shares-ok\n")
        XCTAssertEqual(log, ["mount monad \(tmp.url.appendingPathComponent(root).path)",
                             "bind \(src("home-dev-src")) /home/dev/src", "remount ro /home/dev/src",
                             "bind \(src("mnt-data")) /mnt/data", "remount rw /mnt/data"])
    }

    func testUnchangedFoldersAreLeftAlone() throws {
        let a = SharedFolder(hostPath: "/Users/x/src", guestPath: "/home/dev/src", readOnly: true)
        let b = SharedFolder(hostPath: "/Users/x/data", guestPath: "/mnt/data", readOnly: true)
        try run([a, b])
        _ = log
        XCTAssertEqual(try run([a]), "shares-ok\n")
        XCTAssertEqual(log, ["umount /mnt/data", "rmdir /mnt/data"], "a shell inside /home/dev/src is not disturbed")
    }

    /// A running VM's shared folder device gets a new folder list when
    /// folders are added or removed. Folders bound before it then point at
    /// nothing (stale), so every folder is bound again, unchanged ones too.
    func testAChangedDeviceBindsEveryFolderAgain() throws {
        let a = SharedFolder(hostPath: "/Users/x/src", guestPath: "/home/dev/src", readOnly: true)
        let b = SharedFolder(hostPath: "/Users/x/data", guestPath: "/mnt/data", readOnly: true)
        try run([a])
        _ = log
        let (out, err) = try runAll([a, b], rebind: true)
        XCTAssertEqual(out, "shares-ok\n")
        XCTAssertEqual(log, ["umount /home/dev/src", "bind \(src("home-dev-src")) /home/dev/src", "remount ro /home/dev/src",
                             "bind \(src("mnt-data")) /mnt/data", "remount ro /mnt/data"])
        XCTAssertTrue(err.contains("monad-shares: the shared folder device changed, binding every folder again\n"), err)
    }

    /// A folder bound before that no longer reads as a mount point (stale)
    /// is unmounted before it is bound again: binding over it fails.
    func testAStaleFolderIsUnmountedBeforeItIsBoundAgain() throws {
        let a = SharedFolder(hostPath: "/Users/x/src", guestPath: "/home/dev/src", readOnly: true)
        try run([a])
        _ = log
        // Only the folder reads as unmounted; the device itself still is.
        let table = tmp.url.appendingPathComponent("mounted")
        let mounted = try String(contentsOf: table, encoding: .utf8).split(separator: "\n").filter { $0 != "/home/dev/src" }
        try mounted.map { $0 + "\n" }.joined().write(to: table, atomically: true, encoding: .utf8)
        XCTAssertEqual(try run([a]), "shares-ok\n")
        XCTAssertEqual(log, ["umount /home/dev/src", "bind \(src("home-dev-src")) /home/dev/src", "remount ro /home/dev/src"])
    }

    func testChangedModeIsRemounted() throws {
        var a = SharedFolder(hostPath: "/Users/x/src", guestPath: "/home/dev/src", readOnly: true)
        try run([a])
        _ = log
        a.readOnly = false
        try run([a])
        XCTAssertEqual(log, ["umount /home/dev/src", "bind \(src("home-dev-src")) /home/dev/src",
                             "remount rw /home/dev/src"])
    }

    func testCollidingNamesMatchTheHost() throws {
        let shares = [SharedFolder(hostPath: "/a", guestPath: "/mnt/x", readOnly: true),
                      SharedFolder(hostPath: "/b", guestPath: "/mnt-x", readOnly: true)]
        XCTAssertEqual(SharingSettings.named(shares).map(\.name), ["mnt-x", "mnt-x-2"])
        try run(shares)
        XCTAssertTrue(log.contains("bind \(src("mnt-x-2")) /mnt-x"))
    }

    /// A failed folder says what mount said, and what the shared folder
    /// device holds (a folder added while the VM runs must show up there).
    func testFailuresAreReportedPerFolderWithTheReason() throws {
        try FileManager.default.createDirectory(at: tmp.url.appendingPathComponent("virtiofs/other"),
                                                withIntermediateDirectories: true)
        let (out, err) = try runAll([SharedFolder(hostPath: "/a", guestPath: "/mnt/a", readOnly: true)], env: ["FAIL_BIND": "1"])
        XCTAssertEqual(out, "shares-failed: /mnt/a: mount: /mnt/a: special device \(src("mnt-a")) does not exist.\n")
        XCTAssertTrue(err.contains("monad-shares: the shared folder device holds: other\n"), err)
        XCTAssertEqual(try run([SharedFolder(hostPath: "/a", guestPath: "/mnt/a", readOnly: true)]), "shares-ok\n",
                       "a failed folder is retried next time")
    }

    /// Each step is said on stderr, which only the debug log keeps.
    func testEachStepIsSaid() throws {
        let a = SharedFolder(hostPath: "/Users/x/src", guestPath: "/home/dev/src", readOnly: true)
        let b = SharedFolder(hostPath: "/Users/x/data", guestPath: "/mnt/data", readOnly: false)
        let first = try runAll([a, b]).err
        XCTAssertTrue(first.contains("monad-shares: mounting the shared folder device at \(tmp.url.appendingPathComponent(root).path)\n"), first)
        XCTAssertTrue(first.contains("monad-shares: mounted home-dev-src at /home/dev/src (ro)\n"), first)
        XCTAssertTrue(first.contains("monad-shares: mounted mnt-data at /mnt/data (rw)\n"), first)
        let second = try runAll([a]).err
        XCTAssertTrue(second.contains("monad-shares: unmounted /mnt/data\n"), second)
        XCTAssertTrue(second.contains("monad-shares: removed the empty folder /mnt/data\n"), second)
        XCTAssertTrue(second.contains("monad-shares: kept home-dev-src at /home/dev/src (ro)\n"), second)
    }

    func testTheProblemSaysWhy() {
        let failed = ProcessRunner.Result(status: 1, stdout: Data("shares-failed: /mnt/a: mount: boom\nshares-failed: /mnt/b\n".utf8),
                                          stderr: Data("monad-shares: the shared folder device holds: x\n".utf8))
        XCTAssertEqual(GuestShares.problem(failed), "Could not mount in the guest: /mnt/a (mount: boom), /mnt/b.")
        let lost = ProcessRunner.Result(status: 255, stdout: Data(),
                                        stderr: Data("Connection closed by UNKNOWN port 65535\nmonad-shares: mounting x\n".utf8))
        XCTAssertEqual(GuestShares.problem(lost), "Could not mount shared folders in the guest (Connection closed by UNKNOWN port 65535).")
        XCTAssertNil(GuestShares.problem(.init(status: 0, stdout: Data("shares-ok\n".utf8), stderr: Data())))
    }

    /// What the script made is remembered across reboots: a share removed
    /// while the VM was off loses its folder at the next run.
    func testAShareRemovedWhileTheVMWasOffLosesItsFolderToo() throws {
        let a = SharedFolder(hostPath: "/a", guestPath: "/mnt/a", readOnly: true)
        let b = SharedFolder(hostPath: "/b", guestPath: "/mnt/b", readOnly: true)
        try run([a, b])
        // A reboot: /run (the mount list) and every mount are gone.
        try FileManager.default.removeItem(at: tmp.url.appendingPathComponent("shares"))
        try "".write(to: tmp.url.appendingPathComponent("mounted"), atomically: true, encoding: .utf8)
        _ = log
        XCTAssertEqual(try run([a]), "shares-ok\n")
        XCTAssertEqual(log, ["mount monad \(tmp.url.appendingPathComponent(root).path)",
                             "bind \(src("mnt-a")) /mnt/a", "remount ro /mnt/a", "rmdir /mnt/b"])
    }

    func testRemovingEverythingUnmountsEverything() throws {
        try run([SharedFolder(hostPath: "/a", guestPath: "/mnt/a", readOnly: true)])
        _ = log
        XCTAssertEqual(try run([]), "shares-ok\n")
        XCTAssertEqual(log, ["umount /mnt/a", "rmdir /mnt/a"])
    }

    /// A removed folder leaves no empty folder behind, but only folders the
    /// script made go: one that was there before it mounted stays.
    func testOnlyFoldersItMadeAreRemoved() throws {
        let existing = tmp.url.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let mine = SharedFolder(hostPath: "/a", guestPath: existing.path, readOnly: true)
        try run([mine])
        _ = log
        let (out, err) = try runAll([])
        XCTAssertEqual(out, "shares-ok\n")
        XCTAssertEqual(log, ["umount \(existing.path)"], "it was there before")
        XCTAssertFalse(err.contains("removed"), err)
        let made = SharedFolder(hostPath: "/b", guestPath: "/mnt/b", readOnly: true)
        try run([made])
        _ = log
        let second = try runAll([]).err
        XCTAssertEqual(log, ["umount /mnt/b", "rmdir /mnt/b"])
        XCTAssertTrue(second.contains("monad-shares: removed the empty folder /mnt/b\n"), second)
        // Made once: removed once, then forgotten.
        try run([made])
        _ = log
        try run([])
        XCTAssertEqual(log.filter { $0.hasPrefix("rmdir") }, ["rmdir /mnt/b"])
    }
}
