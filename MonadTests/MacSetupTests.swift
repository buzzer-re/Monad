//
//  MacSetupTests.swift — setting a macOS VM up with no setup screens (Phase
//  14): what Monad stages for the root step and the guest's first boot, the
//  first-boot script's shape, and the plain words the user is asked with.
//

import XCTest
@testable import Monad

final class MacSetupTests: XCTestCase {
    private var tmp: TempDir!

    override func setUp() {
        tmp = TempDir()
    }

    private var config: InstanceConfig {
        var c = InstanceConfig.defaults(name: "dev-mac")
        c.user = "dev"
        c.guestOS = .macos
        return c
    }

    /// The files staged for the root step, each private to the user, with
    /// exactly the names the root step installs (and nothing else).
    func testThePayloadIsStagedPrivately() throws {
        let dir = tmp.url.appendingPathComponent("mac-setup")
        let guestd = tmp.url.appendingPathComponent("MonadHost")
        try Data("binary".utf8).write(to: guestd)
        try MacSetup.stage(config, publicKey: "ssh-ed25519 AAAATEST monad\n", password: "Secret123secret456", guestd: guestd,
                           agent: "#!/bin/sh\necho agent\n", into: dir)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, MacSetup.payloadFiles.sorted())
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        for name in names {
            let m = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(m?.intValue, 0o600, name)
        }
        func text(_ n: String) throws -> String { try String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8) }
        XCTAssertEqual(try text("account"), "MONAD_USER='dev'\n")
        XCTAssertEqual(try text("password"), "Secret123secret456")
        XCTAssertEqual(try text("authorized_keys"), "ssh-ed25519 AAAATEST monad\n")
        XCTAssertEqual(try text("sudoers"), "dev ALL=(ALL) NOPASSWD: ALL\n")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("guestd")), Data("binary".utf8))
        let sshd = try text("sshd.conf")
        for line in ["PasswordAuthentication no", "KbdInteractiveAuthentication no", "PermitRootLogin no"] {
            XCTAssertTrue(sshd.contains(line), line)
        }
        // The launchd jobs are valid plists naming Monad's own files only.
        let setup = try PropertyListSerialization.propertyList(from: Data(contentsOf: dir.appendingPathComponent("dev.monad.setup.plist")),
                                                               format: nil) as? [String: Any]
        XCTAssertEqual(setup?["Label"] as? String, "dev.monad.setup")
        XCTAssertEqual(setup?["ProgramArguments"] as? [String], ["/bin/sh", MacSetup.guestSetupDir + "/firstboot.sh"])
        XCTAssertEqual(setup?["RunAtLoad"] as? Bool, true)
        let guestdJob = try PropertyListSerialization.propertyList(from: Data(contentsOf: dir.appendingPathComponent("dev.monad.guestd.plist")),
                                                                   format: nil) as? [String: Any]
        XCTAssertEqual(guestdJob?["ProgramArguments"] as? [String], [MacSetup.guestdPath, "--guestd"])
        XCTAssertEqual(guestdJob?["KeepAlive"] as? Bool, true)
        // sshd is started by launchd as macOS's own Remote Login starts it,
        // but listening on the guest's loopback only: Apple's sshd needs an
        // IP peer (its audit session; docs/MACOS.md). monad-guestd joins
        // each vsock connection to it.
        let sshdJob = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: dir.appendingPathComponent("dev.monad.sshd.plist")), format: nil) as? [String: Any])
        XCTAssertEqual(sshdJob["Label"] as? String, "dev.monad.sshd")
        XCTAssertEqual(sshdJob["Program"] as? String, "/usr/libexec/sshd-keygen-wrapper")
        XCTAssertEqual(sshdJob["ProgramArguments"] as? [String], ["sshd-keygen-wrapper"])
        XCTAssertEqual((sshdJob["inetdCompatibility"] as? [String: Any])?["Wait"] as? Bool, false)
        let listener = (sshdJob["Sockets"] as? [String: Any])?["Listeners"] as? [String: Any]
        XCTAssertEqual(listener?["SockNodeName"] as? String, "127.0.0.1")
        XCTAssertEqual(listener?["SockFamily"] as? String, "IPv4")
        XCTAssertEqual(listener?["SockServiceName"] as? String, MND_GUESTD_SSHD_PORT, "where monad-guestd joins it")
        XCTAssertNil(listener?["Bonjour"], "not announced")
    }

    /// The root step copies exactly the files Monad stages.
    func testTheRootStepKnowsEveryStagedFile() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "monad-macsetup", withExtension: "sh"))
        let script = try String(contentsOf: url, encoding: .utf8)
        let line = try XCTUnwrap(script.split(separator: "\n").first { $0.hasPrefix("PAYLOAD_FILES=") })
        let names = line.dropFirst("PAYLOAD_FILES=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        XCTAssertEqual(names.split(separator: " ").map(String.init).sorted(), MacSetup.payloadFiles.sorted())
    }

    /// Staging again (a retry) replaces what was there.
    func testStagingAgainStartsClean() throws {
        let dir = tmp.url.appendingPathComponent("mac-setup")
        let guestd = tmp.url.appendingPathComponent("MonadHost")
        try Data("binary".utf8).write(to: guestd)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dir.appendingPathComponent("leftover"))
        try MacSetup.stage(config, publicKey: "ssh-ed25519 K\n", password: "p", guestd: guestd, agent: "", into: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("leftover").path))
    }

    /// A password is long, random and plain (sysadminctl takes it as an
    /// argument): letters and digits only.
    func testPasswordsAreRandomAndPlain() {
        let a = MacSetup.newPassword(), b = MacSetup.newPassword()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 24)
        XCTAssertNil(a.range(of: "[^A-Za-z0-9]", options: .regularExpression))
    }

    /// The first boot (as root, once): the account through Apple's own
    /// sysadminctl, the key, sudo, sshd's settings, Monad's service; then it
    /// takes itself and the password away. Remote Login stays off.
    func testTheFirstBootScript() throws {
        let s = try MacSetup.firstBootScript()
        for part in ["sysadminctl -addUser", "-admin", "authorized_keys", "/etc/sudoers.d/monad",
                     "/etc/ssh/sshd_config.d/", "launchctl bootstrap system", "/Library/LaunchDaemons/dev.monad.guestd.plist",
                     "/Library/LaunchDaemons/dev.monad.sshd.plist",
                     "/var/db/.AppleSetupDone", "rm -f \"$SETUP/password\"", "rm -f /Library/LaunchDaemons/dev.monad.setup.plist"] {
            XCTAssertTrue(s.contains(part), part)
        }
        XCTAssertFalse(s.contains("systemsetup -setremotelogin on"), "no ssh on the network")
        XCTAssertFalse(s.contains("com.openssh.sshd"), "Remote Login is never turned on")
    }

    /// The first boot leaves the VM running: Monad logs in once, then shuts
    /// it down itself (powering off 0.1 s after sshd started left sshd
    /// failing every login on the next boot).
    func testTheFirstBootLeavesTheVMRunning() throws {
        let s = try MacSetup.firstBootScript()
        XCTAssertFalse(s.contains("shutdown"), s)
    }

    /// Full disk access for Monad's sessions is the row macOS's own "Allow
    /// full disk access for remote users" box writes: Apple's ssh launcher,
    /// by path, allowed, with its code requirement.
    func testFullDiskAccessIsTheRemoteLoginRow() throws {
        let req = try MacSetup.requirementData(MacSetup.sshWrapperRequirement)
        XCTAssertEqual(Array(req.prefix(4)), [0xfa, 0xde, 0x0c, 0x00], "a compiled code requirement")
        let sql = try MacSetup.fullDiskAccessSQL()
        XCTAssertTrue(sql.hasPrefix("INSERT OR REPLACE INTO access"), sql)
        for part in ["'kTCCServiceSystemPolicyAllFiles'", "'/usr/libexec/sshd-keygen-wrapper'", ", 1, 2, 4, 1, X'",
                     req.map { String(format: "%02x", $0) }.joined()] {
            XCTAssertTrue(sql.contains(part), part)
        }
    }

    /// What hdiutil attached: the image's own device (detached last) and
    /// the volumes' mount points.
    func testHdiutilsAnswerIsRead() {
        let out = """
            /dev/disk6          \tGUID_partition_scheme          \t
            /dev/disk6s1        \tApple_APFS_ISC                 \t
            /dev/disk7          \tEF57347C-0000-11AA-AA11-0030654\t
            /dev/disk7s1        \t41504653-0000-11AA-AA11-0030654\t/private/tmp/m.x/iSCPreboot
            /dev/disk9s1        \t41504653-0000-11AA-AA11-0030654\t/private/tmp/m.x/Macintosh HD
            /dev/disk9s5        \t41504653-0000-11AA-AA11-0030654\t/private/tmp/m.x/Data

            """
        let a = MacSetup.attached(hdiutilOutput: out)
        XCTAssertEqual(a.device, "/dev/disk6")
        XCTAssertEqual(a.mounts, ["/private/tmp/m.x/iSCPreboot", "/private/tmp/m.x/Macintosh HD", "/private/tmp/m.x/Data"])
        XCTAssertNil(MacSetup.attached(hdiutilOutput: "").device)
    }

    /// Each boot, ssh listening on the guest's network fails the VM; sshd
    /// on its loopback (Monad's own, reached through guestd) does not.
    func testTheIsolationCheckAllowsSSHOnTheLoopbackOnly() throws {
        func exposed(_ netstat: String) throws -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", MacSetup.isolationFilter]
            let input = Pipe()
            p.standardInput = input
            try p.run()
            input.fileHandleForWriting.write(Data(netstat.utf8))
            try input.fileHandleForWriting.close()
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        let row = { (local: String, state: String) in "tcp4       0      0  \(local)  *.*  \(state)  0 0 131072 131072 launchd:1\n" }
        XCTAssertFalse(try exposed(row("127.0.0.1.22", "LISTEN")), "Monad's sshd")
        XCTAssertFalse(try exposed("tcp6 0 0 ::1.22 *.* LISTEN 0 0\n"))
        XCTAssertFalse(try exposed(row("127.0.0.1.631", "LISTEN") + row("192.168.64.5.22", "ESTABLISHED")))
        XCTAssertFalse(try exposed(row("*.2222", "LISTEN")))
        XCTAssertTrue(try exposed(row("*.22", "LISTEN")), "Remote Login")
        XCTAssertTrue(try exposed("tcp6 0 0 *.22 *.* LISTEN 0 0\n"))
        XCTAssertTrue(try exposed(row("127.0.0.1.22", "LISTEN") + row("192.168.64.5.22", "LISTEN")))
        XCTAssertTrue(MacSetup.isolationScript.contains(MacSetup.isolationFilter))
    }

    // MARK: Taking the finished disk back

    /// The root step leaves the finished disk in a folder handed to the
    /// user; Monad (as the user) takes it from there only if it is what it
    /// should be, puts it in place of the VM's disk and cleans up.
    func testTheFinishedDiskIsTakenBack() throws {
        let paths = InstancePaths(name: "dev-mac", root: tmp.url.appendingPathComponent("instances"))
        try FileManager.default.createDirectory(at: paths.dir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: paths.disk)
        try FileManager.default.createDirectory(at: paths.macSetupPayload, withIntermediateDirectories: true)
        let tmpRoot = tmp.url.appendingPathComponent("private-tmp")
        let work = tmpRoot.appendingPathComponent("monad-macsetup.AbC123")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("set up".utf8).write(to: work.appendingPathComponent("disk.raw"))
        try MacSetup.adopt(work: work.path, into: paths, workParent: tmpRoot.path)
        XCTAssertEqual(try Data(contentsOf: paths.disk), Data("set up".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.macSetupPayload.path), "the staged files (the password) go")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.macSetupDone.path))
    }

    func testAnythingElseIsNotTakenBack() throws {
        let paths = InstancePaths(name: "dev-mac", root: tmp.url.appendingPathComponent("instances"))
        try FileManager.default.createDirectory(at: paths.dir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: paths.disk)
        let tmpRoot = tmp.url.appendingPathComponent("private-tmp")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let elsewhere = tmp.url.appendingPathComponent("monad-macsetup.Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: elsewhere.appendingPathComponent("disk.raw"))
        let linked = tmpRoot.appendingPathComponent("monad-macsetup.Linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: elsewhere)
        let wrongName = tmpRoot.appendingPathComponent("other.AbC")
        try FileManager.default.createDirectory(at: wrongName, withIntermediateDirectories: true)
        let diskIsLink = tmpRoot.appendingPathComponent("monad-macsetup.DiskLink")
        try FileManager.default.createDirectory(at: diskIsLink, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: diskIsLink.appendingPathComponent("disk.raw"),
                                                   withDestinationURL: elsewhere.appendingPathComponent("disk.raw"))
        for bad in [elsewhere.path, linked.path, wrongName.path, diskIsLink.path, tmpRoot.path + "/monad-macsetup.Gone",
                    tmpRoot.path + "/monad-macsetup.X/../../x"] {
            XCTAssertThrowsError(try MacSetup.adopt(work: bad, into: paths, workParent: tmpRoot.path), bad)
        }
        XCTAssertEqual(try Data(contentsOf: paths.disk), Data("old".utf8), "the VM's disk untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.macSetupDone.path))
    }

    /// The app runs the step through macOS's own password prompt, with the
    /// plain words as the prompt; every value is an argument, never part of
    /// a command line.
    func testTheStepIsAskedThroughMacOSsPrompt() {
        let text = "#!/bin/sh\necho the step\n"
        let c = MacSetup.rootStepCommand(scriptText: text,
                                         disk: "/Users/dev/.monad/instances/my vm/disk.raw",
                                         payload: "/Users/dev/.monad/instances/my vm/mac-setup", uid: 501, vm: "my vm")
        XCTAssertEqual(c.executable, "/usr/bin/osascript")
        // The script's text, which Monad holds, is what root runs: never a file it would have to trust.
        XCTAssertEqual(Array(c.arguments.suffix(5)), [text,
                                                      "/Users/dev/.monad/instances/my vm/disk.raw",
                                                      "/Users/dev/.monad/instances/my vm/mac-setup", "501",
                                                      MacSetup.question(vm: "my vm")])
        XCTAssertFalse(c.arguments.contains { $0.hasSuffix(".sh") }, "no path into the bundle")
        let script = c.arguments.dropLast(5).joined(separator: "\n")
        XCTAssertTrue(script.contains("/bin/sh -c "), script)
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue(script.contains("quoted form of item 2 of argv"))
        XCTAssertFalse(script.contains("my vm"), "values only as arguments")
        XCTAssertEqual(MacSetup.workFolder(from: "noise\nmonad-setup-done /private/tmp/monad-macsetup.Q1w2E3\n"),
                       "/private/tmp/monad-macsetup.Q1w2E3")
        XCTAssertNil(MacSetup.workFolder(from: "monad-setup-failed: cannot copy\n"))
        XCTAssertEqual(MacSetup.failure(from: "monad-setup-failed: cannot copy the disk\n"), "cannot copy the disk")
    }

    /// The app runs the step only on the VM's own disk and staged files,
    /// whatever MonadHost names (a host that is not Monad's could name any).
    func testTheStepRunsOnlyOnTheVMsOwnFiles() {
        let root = URL(fileURLWithPath: "/Users/dev/.monad/instances")
        let paths = InstancePaths(name: "dev-mac", root: root)
        XCTAssertNil(MacSetup.requestProblem(MacSetupRequest(disk: paths.disk.path, payload: paths.macSetupPayload.path),
                                             vm: "dev-mac", instances: root))
        for bad in [MacSetupRequest(disk: "/Users/dev/Documents/disk.raw", payload: paths.macSetupPayload.path),
                    MacSetupRequest(disk: paths.disk.path, payload: "/private/tmp/payload"),
                    MacSetupRequest(disk: InstancePaths(name: "other", root: root).disk.path, payload: paths.macSetupPayload.path),
                    MacSetupRequest(disk: paths.dir.path + "/../other/disk.raw", payload: paths.macSetupPayload.path)] {
            XCTAssertNotNil(MacSetup.requestProblem(bad, vm: "dev-mac", instances: root), "\(bad)")
        }
    }

    /// Before the password is asked: Monad's bundle on disk is intact and
    /// is the code that runs. A copy with one resource changed is refused.
    func testTheStepIsAskedOnlyFromAnIntactMonad() throws {
        XCTAssertNil(MacSetup.bundleProblem(Bundle.main.bundleURL), "this Monad, as built")
        let copy = tmp.url.appendingPathComponent("Monad.app")
        try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: copy)
        let script = copy.appendingPathComponent("Contents/Resources/monad-macsetup.sh")
        try (try String(contentsOf: script, encoding: .utf8) + "\necho changed\n").write(to: script, atomically: true, encoding: .utf8)
        XCTAssertNotNil(MacSetup.bundleProblem(copy), "a changed resource breaks the seal")
    }

    /// Who asked for the VM, when it was an agent's VM.
    func testTheQuestionSaysWhichVMAskedForIt() {
        XCTAssertTrue(MacSetup.question(vm: "update", madeBy: "agent-1").contains("“agent-1”"))
        XCTAssertEqual(MacSetup.question(vm: "update", madeBy: nil), MacSetup.question(vm: "update"))
    }

    /// The plain words: what happens and why, no jargon.
    func testTheQuestionIsInPlainWords() {
        let q = MacSetup.question(vm: "dev-mac")
        XCTAssertTrue(q.contains("dev-mac"))
        for jargon in ["root", "LaunchDaemon", "APFS", "volume", "sudo", "ssh", "payload", "mount"] {
            XCTAssertFalse(q.localizedCaseInsensitiveContains(jargon), jargon)
        }
        XCTAssertTrue(q.localizedCaseInsensitiveContains("password"))
        // Not the user's Mac account copied in: one of its own, and the
        // Mac's password is not kept.
        XCTAssertFalse(q.contains("add your account"))
        XCTAssertTrue(q.contains("its own password"))
        XCTAssertTrue(q.contains("Monad never sees or keeps it"))
    }
}
