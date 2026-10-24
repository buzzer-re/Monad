//
//  MacGuestSharesTests.swift — shared folders in a macOS guest: the device
//  mounted once with Apple's mount_virtiofs, each folder a symbolic link at
//  its path (macOS has no bind mounts). The script runs here under /bin/sh
//  with stand-ins for mount and mount_virtiofs; the links are real.
//

import XCTest
@testable import Monad

final class MacGuestSharesTests: XCTestCase {
    private var tmp: TempDir!
    private var stubs: URL!
    private var root: String { tmp.url.appendingPathComponent("virtiofs").path }
    private var home: String { tmp.url.appendingPathComponent("Users/dev").path }

    override func setUpWithError() throws {
        tmp = TempDir()
        stubs = tmp.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let state = tmp.url.appendingPathComponent("mounted").path
        let log = tmp.url.appendingPathComponent("log").path
        FileManager.default.createFile(atPath: state, contents: nil)
        // macOS's mount lists "tag on path (type, …)", the path resolved
        // (/var is /private/var), as the temporary folder here is too.
        try stub("mount", #"while read -r p; do echo "monad on $(cd "$p" && pwd -P) (virtiofs, local)"; done < '\#(state)'"#)
        try stub("mount_virtiofs", #"""
            [ -n "${FAIL_MOUNT:-}" ] && { echo "mount_virtiofs: no such device" >&2; exit 1; }
            grep -qxF "$2" '\#(state)' && { echo "mount_virtiofs: failed to mount $2: Resource busy" >&2; exit 1; }
            echo "$2" >> '\#(state)'; echo "mount_virtiofs $1 $2" >> '\#(log)'
            """#)
        try stub("umount", #"""
            [ "$1" = -f ] && shift
            grep -vxF "$1" '\#(state)' > '\#(state).tmp'; mv '\#(state).tmp' '\#(state)'
            echo "umount $1" >> '\#(log)'
            """#)
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
        let script = GuestShares.macScript(for: shares, root: root,
                                           made: tmp.url.appendingPathComponent("db/shares-made").path, rebind: rebind)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-s"]
        p.environment = ["PATH": "\(stubs.path):/usr/bin:/bin"].merging(env) { $1 }
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        try p.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: out, as: UTF8.self)
    }

    private func link(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    private func share(_ guest: String, readOnly: Bool = true) -> SharedFolder {
        SharedFolder(hostPath: "/Users/x/" + (guest as NSString).lastPathComponent, guestPath: guest, readOnly: readOnly)
    }

    /// The device is mounted once; each folder is a link to its directory
    /// there, its parent folders made where missing.
    func testEachFolderIsALinkIntoTheDevice() throws {
        let src = share(home + "/src"), data = share(home + "/work/data", readOnly: false)
        XCTAssertEqual(try run([src, data]), "shares-ok\n")
        XCTAssertEqual(log, ["mount_virtiofs monad \(root)"])
        let named = SharingSettings.named([src, data])
        XCTAssertEqual(link(home + "/src"), root + "/" + named[0].name)
        XCTAssertEqual(link(home + "/work/data"), root + "/" + named[1].name)
    }

    /// Run again with the same folders: nothing is mounted or linked again.
    func testUnchangedFoldersAreLeftAlone() throws {
        let src = share(home + "/src")
        try run([src])
        _ = log
        XCTAssertEqual(try run([src]), "shares-ok\n")
        XCTAssertEqual(log, [])
        XCTAssertNotNil(link(home + "/src"))
    }

    /// A folder no longer shared loses its link (made by Monad); the others stay.
    func testARemovedFolderLosesItsLink() throws {
        let src = share(home + "/src"), data = share(home + "/data")
        try run([src, data])
        XCTAssertEqual(try run([src]), "shares-ok\n")
        XCTAssertNotNil(link(home + "/src"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/data"))
        XCTAssertNil(link(home + "/data"))
    }

    /// An empty folder where a share goes is replaced by the link; a folder
    /// with something in it, or a file, is never touched and is reported.
    func testWhatIsAlreadyThereIsNeverOverwritten() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/empty", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/full", withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: home + "/full/notes.txt"))
        let out = try run([share(home + "/empty"), share(home + "/full")])
        XCTAssertNotNil(link(home + "/empty"))
        XCTAssertTrue(out.contains("shares-failed: \(home)/full: "), out)
        XCTAssertEqual(try String(contentsOfFile: home + "/full/notes.txt", encoding: .utf8), "mine")
        XCTAssertFalse(out.contains("shares-ok"))
    }

    /// The running VM's device was given a new folder list: mounted again.
    func testAChangedDeviceIsMountedAgain() throws {
        let src = share(home + "/src")
        try run([src])
        _ = log
        XCTAssertEqual(try run([src], rebind: true), "shares-ok\n")
        XCTAssertEqual(log, ["umount \(root)", "mount_virtiofs monad \(root)"])
    }

    /// A device that cannot be mounted says so.
    func testADeviceThatCannotBeMountedSaysSo() throws {
        let out = try run([share(home + "/src")], env: ["FAIL_MOUNT": "1"])
        XCTAssertTrue(out.hasPrefix("shares-failed: the shared folder device: "), out)
        XCTAssertEqual(GuestShares.problem(.init(status: 1, stdout: Data(out.utf8), stderr: Data())),
                       "Could not mount in the guest: the shared folder device (mount_virtiofs: no such device).")
    }

    /// What the guest says (root in it writes it) is shown in Monad's words:
    /// plain, bounded, a few folders at most.
    func testWhatTheGuestSaysIsPlainAndBounded() {
        func shown(_ out: String) -> String {
            GuestShares.problem(.init(status: 1, stdout: Data(out.utf8), stderr: Data())) ?? ""
        }
        let long = shown("shares-failed: /home/dev/src: " + String(repeating: "y", count: 10_000) + "\u{1b}[31m\u{202E}\n")
        XCTAssertLessThanOrEqual(long.count, 400, long)
        XCTAssertFalse(long.unicodeScalars.contains { [.control, .format].contains($0.properties.generalCategory) }, long)
        let many = shown((0..<50).map { "shares-failed: /f\($0): no\n" }.joined())
        XCTAssertLessThanOrEqual(many.count, 1000, many)
        XCTAssertTrue(many.hasSuffix("and 42 more."), many)
    }

    /// A macOS VM's user lives in /Users, so its exchange folder does too.
    func testAMacOSVMsHomeIsInUsers() {
        var c = InstanceConfig.defaults(name: "mac")
        c.guestOS = .macos
        c.user = "dev"
        XCTAssertEqual(c.home, "/Users/dev")
        c.guestOS = .linux
        XCTAssertEqual(c.home, "/home/dev")
    }
}
