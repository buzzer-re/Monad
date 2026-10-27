//
//  MacSetup.swift — a macOS VM set up with no setup screens (Phase 14).
//
//  After the install, Monad stages files in the VM's folder (`stage`), and a
//  root step started from the app with one admin prompt (monad-macsetup.sh)
//  copies them into the new disk: a one-time launchd job and what it needs.
//  At the VM's first boot that job makes the account with Apple's own
//  sysadminctl, gives it Monad's key and sudo, sets sshd to keys only,
//  starts sshd on the loopback (launchd's) and monad-guestd (MonadHost
//  --guestd: ssh and the agent on vsock), then takes itself and the
//  password away. Remote Login stays off.
//

import Foundation
import Security

enum MacSetup {
    /// Where the staged files go in the guest (the root step writes them).
    static let guestSetupDir = "/usr/local/libexec/monad/setup"
    static let guestdPath = "/usr/local/libexec/monad/guestd"

    /// Every staged file, by the name the root step installs it under.
    static let payloadFiles = ["account", "password", "authorized_keys", "sudoers", "sshd.conf", "firstboot.sh",
                               "dev.monad.setup.plist", "dev.monad.guestd.plist", "dev.monad.sshd.plist", "guestd", "agent"]

    static let sshdSettings = """
        # Monad: keys only (sshd is reached through monad-guestd on vsock, never on the network).
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PermitRootLogin no

        """

    /// Letters and digits only: sysadminctl takes it on its command line.
    static func newPassword() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<24).map { _ in chars[Int(rng.next(upperBound: UInt(chars.count)))] })
    }

    static func firstBootScript() throws -> String {
        guard let url = Bundle.main.url(forResource: "monad-macos-firstboot", withExtension: "sh") else {
            throw MonadError("monad-macos-firstboot.sh is missing from the app bundle")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The macOS guest agent. Never "monad-agent-macos.sh": on macOS, Bundle
    /// hands a "-macos" file out in place of the plain one (monad-agent.sh).
    static func agentScript() throws -> String {
        guard let url = Bundle.main.url(forResource: "monad-macos-agent", withExtension: "sh") else {
            throw MonadError("monad-macos-agent.sh is missing from the app bundle")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func plist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    /// The files for the root step, in `dir` (made again, private to the
    /// user). `guestd`: this MonadHost, copied into the guest.
    static func stage(_ config: InstanceConfig, publicKey: String, password: String, guestd: URL, agent: String,
                      into dir: URL) throws {
        try? FileManager.default.removeItem(at: dir)
        try Paths.ensurePrivateDirectory(dir)
        let setupJob = try plist(["Label": "dev.monad.setup", "RunAtLoad": true,
                                  "ProgramArguments": ["/bin/sh", guestSetupDir + "/firstboot.sh"]])
        let guestdJob = try plist(["Label": "dev.monad.guestd", "RunAtLoad": true, "KeepAlive": true,
                                   "ProgramArguments": [guestdPath, "--guestd"]])
        // sshd as macOS's own Remote Login job starts it, but on the guest's
        // loopback only: Apple's sshd refuses a session to a peer with no IP
        // address (docs/MACOS.md). monad-guestd joins vsock to it.
        let sshdJob = try plist([
            "Label": "dev.monad.sshd", "Program": "/usr/libexec/sshd-keygen-wrapper",
            "ProgramArguments": ["sshd-keygen-wrapper"],
            "Sockets": ["Listeners": ["SockNodeName": "127.0.0.1", "SockServiceName": MND_GUESTD_SSHD_PORT,
                                      "SockFamily": "IPv4"]],
            "inetdCompatibility": ["Wait": false], "StandardErrorPath": "/dev/null", "POSIXSpawnType": "Interactive",
        ])
        let files: [String: Data] = [
            "account": Data("MONAD_USER='\(config.user)'\n".utf8),
            "password": Data(password.utf8),
            "authorized_keys": Data(publicKey.utf8),
            "sudoers": Data("\(config.user) ALL=(ALL) NOPASSWD: ALL\n".utf8),
            "sshd.conf": Data(sshdSettings.utf8),
            "firstboot.sh": Data(try firstBootScript().utf8),
            "dev.monad.setup.plist": setupJob,
            "dev.monad.guestd.plist": guestdJob,
            "dev.monad.sshd.plist": sshdJob,
            "guestd": try Data(contentsOf: guestd),
            "agent": Data(agent.utf8),
        ]
        for name in payloadFiles {
            let url = dir.appendingPathComponent(name)
            try files[name]!.write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    // MARK: Full disk access

    /// Apple's ssh launcher, which launchd runs for each Monad session
    /// (dev.monad.sshd), and its code requirement.
    static let sshWrapper = "/usr/libexec/sshd-keygen-wrapper"
    static let sshWrapperRequirement = #"identifier "com.apple.sshd-keygen-wrapper" and anchor apple"#

    /// A code requirement compiled as TCC keeps it (csreq).
    static func requirementData(_ text: String) throws -> Data {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw MonadError("Cannot read the code requirement “\(text)”.")
        }
        var data: CFData?
        guard SecRequirementCopyData(requirement, [], &data) == errSecSuccess, let data else {
            throw MonadError("Cannot compile the code requirement “\(text)”.")
        }
        return data as Data
    }

    /// The TCC row macOS's own "Allow full disk access for remote users"
    /// (Remote Login) writes: the ssh launcher, by path, allowed.
    static func fullDiskAccessSQL() throws -> String {
        let csreq = try requirementData(sshWrapperRequirement).map { String(format: "%02x", $0) }.joined()
        return "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags) "
            + "VALUES ('kTCCServiceSystemPolicyAllFiles', '\(sshWrapper)', 1, 2, 4, 1, X'\(csreq)', 0);"
    }

    // MARK: Its name

    /// The VM named after itself: "monad-" and its name (as a Linux VM),
    /// its own name as the computer name. VM names are letters, digits and
    /// dashes, so they need no quoting.
    static func hostNameCommand(config: InstanceConfig) -> String {
        let host = "monad-\(config.name.lowercased())"
        return "sudo -n sh -c 'scutil --set ComputerName \(config.name) && scutil --set LocalHostName \(host) "
            + "&& scutil --set HostName \(host)'"
    }

    // MARK: The desktop

    /// The text on stdin onto the VM's clipboard, when `user` is logged in
    /// on its desktop (the login window has no clipboard: it fails then).
    static func pasteboardCommand(user: String) -> String {
        "[ \"$(stat -f%Su /dev/console)\" = \(user) ] && LANG=en_US.UTF-8 pbcopy"
    }

    // MARK: Logging in automatically

    /// /etc/kcpassword, which loginwindow reads to log in by itself: the
    /// password XORed with Apple's fixed key, padded with zeros (at least
    /// one) to a multiple of 12. Obfuscation, not protection: only root
    /// can read the file.
    static func kcpassword(_ password: String) -> Data {
        let key: [UInt8] = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F]
        var bytes = Array(password.utf8)
        bytes += [UInt8](repeating: 0, count: 12 - bytes.count % 12)
        return Data(bytes.enumerated().map { $0.element ^ key[$0.offset % key.count] })
    }

    /// Logs `user` in at boot: the encoded password on stdin.
    static func autoLoginOnCommand(user: String) -> String {
        "sudo -n sh -c 'umask 077 && cat > /etc/kcpassword && chown root:wheel /etc/kcpassword && "
            + "defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser \(user) && echo autologin-on'"
    }

    /// The login window again at boot.
    static let autoLoginOffCommand = "sudo -n sh -c 'rm -f /etc/kcpassword; "
        + "defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null; echo autologin-off'"

    /// Full disk access taken back: that row removed.
    static let fullDiskAccessRevokeSQL = "DELETE FROM access WHERE service = 'kTCCServiceSystemPolicyAllFiles' "
        + "AND client = '\(sshWrapper)';"

    /// What `hdiutil attach` attached: the image's own device (the first
    /// line; detaching it detaches the rest) and the volumes' mount points.
    static func attached(hdiutilOutput: String) -> (device: String?, mounts: [String]) {
        var device: String?
        var mounts: [String] = []
        for line in hdiutilOutput.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let dev = fields.first, dev.hasPrefix("/dev/disk") else { continue }
            if device == nil { device = dev }
            if fields.count > 2, !fields[2].isEmpty { mounts.append(fields[2]) }
        }
        return (device, mounts)
    }

    /// Full disk access for Monad's sessions in the stopped VM, written as
    /// the user into the guest's TCC database (macOS made it at the first
    /// boot): its disk attached read-write without admin rights, the row,
    /// detached. SIP keeps that database from the guest's own root.
    static func grantFullDiskAccess(disk: URL, runner: CommandRunning) async throws {
        try await setFullDiskAccess(true, disk: disk, runner: runner)
    }

    /// The row written (on) or removed (off) the same way.
    static func setFullDiskAccess(_ on: Bool, disk: URL, runner: CommandRunning) async throws {
        let sql = on ? try fullDiskAccessSQL() : fullDiskAccessRevokeSQL
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("monad-tcc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            // Only empty folders: never what a volume still mounted there holds.
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
                rmdir(root.appendingPathComponent(name).path)
            }
            rmdir(root.path)
        }
        let r = try await runner.run("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-noverify", "-noautofsck", "-mountroot", root.path,
            "-imagekey", "diskimage-class=CRawDiskImage", disk.path,
        ], stdin: nil, timeout: 120)
        let a = attached(hdiutilOutput: r.stdoutString)
        var failure: Error?
        if r.status != 0 {
            failure = MonadError("Cannot open the VM's disk: \(r.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else if let db = a.mounts.map({ $0 + "/Library/Application Support/com.apple.TCC/TCC.db" })
            .first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let w = try? await runner.run("/usr/bin/sqlite3", [db, sql], stdin: nil, timeout: 30)
            if w?.status != 0 {
                failure = MonadError("Cannot write the VM's privacy settings: \(w?.stderrString ?? "sqlite3 did not run")")
            }
        } else {
            failure = MonadError("The VM's privacy settings are not there yet (macOS makes them at its first start).")
        }
        if let device = a.device {
            _ = try? await runner.run("/usr/bin/hdiutil", ["detach", device], stdin: nil, timeout: 60)
        }
        if let failure { throw failure }
    }

    // MARK: Every boot

    /// Nothing may listen for ssh on the guest's network: Monad's sshd
    /// listens on the guest's loopback only, reached by monad-guestd on
    /// vsock. Prints "ok" or "tcp22-open".
    static let isolationScript = CloudInit.isolationMarker
        + "if /usr/sbin/netstat -anv -p tcp 2>/dev/null | \(isolationFilter); then echo tcp22-open; else echo ok; fi"

    /// Succeeds when netstat's lines (stdin) show ssh listening anywhere but
    /// the loopback.
    static let isolationFilter = "awk '$6 == \"LISTEN\" && $4 ~ /[.]22$/ && $4 != \"127.0.0.1.22\" && $4 != \"::1.22\" "
        + "{ f = 1 } END { exit !f }'"

    /// Run at every boot with guestInstallScript on stdin.
    static let agentInstallCommand = "sudo -n sh -s"

    /// What every boot refreshes, as root: the agent where monad-guestd runs
    /// it, img, and the Mac's time zone.
    static func guestInstallScript(timeZone: String = TimeZone.current.identifier) throws -> String {
        let clock = CloudInit.timeZoneName(timeZone).map { "systemsetup -settimezone \($0) >/dev/null 2>&1 || true\n" } ?? ""
        return """
        set -eu
        umask 022
        install_file() { # DEST MODE BASE64
            tmp=$(mktemp)
            printf '%s' "$3" | base64 -D > "$tmp"
            mkdir -p "${1%/*}"
            install -o root -g wheel -m "$2" "$tmp" "$1"
            rm -f "$tmp"
        }
        install_file /usr/local/libexec/monad/agent 0644 '\(Data(try agentScript().utf8).base64EncodedString())'
        \(try CloudInit.imgInstall())\(clock)echo agent-ok

        """
    }

    // MARK: The root step

    /// The finished disk, taken back from the root step's work folder
    /// (handed to the user): only a folder named as the step names it,
    /// directly in `workParent`, not a link, holding a plain disk.raw that
    /// is the user's. It replaces the VM's disk; the folder and the staged
    /// files (the password) go; the VM is marked set up.
    static func adopt(work: String, into paths: InstancePaths, workParent: String = "/private/tmp") throws {
        let refused = MonadError("The setup's result is not where Monad expects it. Nothing was changed.")
        let url = URL(fileURLWithPath: work)
        guard url.deletingLastPathComponent().path == URL(fileURLWithPath: workParent).path,
              url.lastPathComponent.range(of: "^monad-macsetup\\.[A-Za-z0-9]{6,}$", options: .regularExpression) != nil else {
            throw refused
        }
        let fm = FileManager.default
        let me = NSNumber(value: getuid())
        guard let a = try? fm.attributesOfItem(atPath: url.path), a[.type] as? FileAttributeType == .typeDirectory,
              a[.ownerAccountID] as? NSNumber == me else { throw refused }
        let disk = url.appendingPathComponent("disk.raw")
        guard let d = try? fm.attributesOfItem(atPath: disk.path), d[.type] as? FileAttributeType == .typeRegular,
              d[.ownerAccountID] as? NSNumber == me else { throw refused }
        guard rename(disk.path, paths.disk.path) == 0 else { throw MonadError.posix(errno, "Cannot put the set-up disk in place") }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.disk.path)
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: paths.macSetupPayload)
        try Data().write(to: paths.macSetupDone)
    }

    /// The app's call: Monad's root step through macOS's own password
    /// prompt, the plain words as its prompt. Root runs the script's text,
    /// which the app read from its own checked bundle (`bundleProblem`),
    /// never a file it would have to trust when the password is typed. Every
    /// value goes as an argument (AppleScript's argv), never into the
    /// command's text.
    static func rootStepCommand(scriptText: String, disk: String, payload: String, uid: uid_t, vm: String,
                                madeBy: String? = nil) -> (executable: String, arguments: [String]) {
        let source = [
            "on run argv",
            "do shell script \"/bin/sh -c \" & quoted form of item 1 of argv & \" monad-macsetup \" & quoted form of item 2 of argv"
                + " & \" \" & quoted form of item 3 of argv & \" \" & quoted form of item 4 of argv"
                + " with prompt (item 5 of argv) with administrator privileges",
            "end run",
        ]
        return ("/usr/bin/osascript",
                source.flatMap { ["-e", $0] } + [scriptText, disk, payload, String(uid), question(vm: vm, madeBy: madeBy)])
    }

    /// Why the step must not run on what MonadHost asked for: anything but
    /// the VM's own disk and staged files (a host that is not Monad's could
    /// name any file). nil when they are the VM's.
    static func requestProblem(_ request: MacSetupRequest, vm: String, instances: URL) -> String? {
        let paths = InstancePaths(name: vm, root: instances)
        func same(_ path: String, _ url: URL) -> Bool { (path as NSString).standardizingPath == url.standardizedFileURL.path }
        guard InstanceConfig.isValidName(vm), same(request.disk, paths.disk), same(request.payload, paths.macSetupPayload),
              !request.disk.contains("/../"), !request.payload.contains("/../") else {
            return "MonadHost asked to set up files that are not “\(vm)”'s. Nothing was run."
        }
        return nil
    }

    /// Why Monad must not ask for the password now: its bundle on disk is
    /// not intact, or is not the code that runs (changed or replaced since
    /// Monad was opened). nil when it is. Signed ad hoc, nothing tells a
    /// bundle changed and signed again before Monad was opened from Monad's
    /// own: that is said in SECURITY.md.
    static func bundleProblem(_ bundle: URL = Bundle.main.bundleURL) -> String? {
        let changed = "Monad's files changed since it was opened. Quit Monad, open it again, then make the VM again."
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return changed }
        // kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        let flags = SecCSFlags(rawValue: 1 << 0 | 1 << 3 | 1 << 4)
        guard SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess else { return changed }
        var code: SecCode?
        var running: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &running) == errSecSuccess, let running,
              SecCodeCopySigningInformation(running, [], &info) == errSecSuccess,
              let ours = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              ours.map({ String(format: "%02x", $0) }).joined() == HostXPCSecurity.cdhash(of: bundle) else { return changed }
        return nil
    }

    /// The work folder from the step's output, if it succeeded.
    static func workFolder(from output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix("monad-setup-done ") {
            return String(line.dropFirst("monad-setup-done ".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Why the step failed, from its output.
    static func failure(from output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix("monad-setup-failed: ") {
            return String(line.dropFirst("monad-setup-failed: ".count))
        }
        return nil
    }

    /// What the user is told before macOS asks for the password: what
    /// happens and why, in plain words.
    static func question(vm: String, madeBy: String? = nil) -> String {
        (madeBy.map { "The VM “\($0)” asked for “\(vm)”. " } ?? "")
            + "To finish setting up “\(vm)” without any setup screens, Monad will create an account with your name "
            + "inside the new Mac, with its own password, and connect it to Monad. macOS will ask for this Mac's "
            + "password once to allow this; Monad never sees or keeps it. Nothing on this Mac is changed."
    }
}
