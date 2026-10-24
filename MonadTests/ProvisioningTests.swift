//
//  ProvisioningTests.swift — instance config, cloud-init, ssh_config and the
//  seed/disk/image helpers.
//

import XCTest
@testable import Monad

final class InstanceConfigTests: XCTestCase {
    func testNameValidation() {
        for ok in ["default", "a", "sandbox-2", "tmp-1a2b3c", "Upper", "MyVM-2", String(repeating: "a", count: 32)] {
            XCTAssertTrue(InstanceConfig.isValidName(ok), ok)
        }
        for bad in ["", "-lead", "has space", "dot.name", "under_score", "../x", "a/b", "é",
                    String(repeating: "a", count: 33)] {
            XCTAssertFalse(InstanceConfig.isValidName(bad), bad)
        }
        // Networks keep lowercase names (netd and their files use them as they are).
        var c = InstanceConfig.defaults(name: "MyVM")
        XCTAssertNoThrow(try c.validate(maxCPUs: 64, maxMemoryGiB: 512))
        c.networks = [NetworkAttachment(network: "Lab", macAddress: nil)]
        XCTAssertThrowsError(try c.validate(maxCPUs: 64, maxMemoryGiB: 512), "a VM on network “Lab”")
    }

    func testGuestUserNameIsAValidLinuxUser() {
        let name = InstanceConfig.guestUserName()
        XCTAssertFalse(name.isEmpty)
        XCTAssertLessThanOrEqual(name.count, 32)
        XCTAssertNotNil(name.range(of: "^[a-z][a-z0-9_-]*$", options: .regularExpression), name)
        XCTAssertNotEqual(name, "root")
    }

    /// A macOS VM (Phase 14) keeps its kind, fixed once made, and needs the
    /// room macOS needs; a Linux VM's file does not change.
    func testAMacOSVMNeedsRoomAndKeepsItsKind() throws {
        var c = InstanceConfig.defaults(name: "mac")
        c.guestOS = .macos
        c.cpus = 2
        c.memoryGiB = 2
        c.diskGiB = 64
        XCTAssertThrowsError(try c.validate(maxCPUs: 8, maxMemoryGiB: 16), "too little memory")
        c.memoryGiB = 4
        c.diskGiB = 20
        XCTAssertThrowsError(try c.validate(maxCPUs: 8, maxMemoryGiB: 16), "too little disk")
        c.diskGiB = InstanceConfig.macMinimumDiskGiB
        XCTAssertNoThrow(try c.validate(maxCPUs: 8, maxMemoryGiB: 16))
        let back = try JSONDecoder().decode(InstanceConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.guestOS, .macos)
        let linux = String(decoding: try JSONEncoder().encode(InstanceConfig.defaults(name: "l")), as: UTF8.self)
        XCTAssertFalse(linux.contains("guestOS"), "a Linux VM's file stays as it was")
        var other = c
        other.guestOS = .linux
        XCTAssertTrue(ConfigChange.fixed(from: c, to: other).contains("guest OS"))
    }

    /// The IPSW file a macOS VM is installed from, when one was chosen: an
    /// absolute path to an .ipsw, for macOS only; kept only until made.
    func testARestoreImageIsAnIPSWFileForMacOS() throws {
        var c = InstanceConfig.defaults(name: "mac")
        c.guestOS = .macos
        c.memoryGiB = 4
        c.diskGiB = 64
        c.restoreImage = "/Users/dev/Downloads/macOS 27.ipsw"
        XCTAssertNoThrow(try c.validate(maxCPUs: 8, maxMemoryGiB: 16))
        let back = try JSONDecoder().decode(InstanceConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.restoreImage, "/Users/dev/Downloads/macOS 27.ipsw")
        for bad in ["macOS.ipsw", "/Users/dev/disk.img", ""] {
            c.restoreImage = bad
            XCTAssertThrowsError(try c.validate(maxCPUs: 8, maxMemoryGiB: 16), bad)
        }
        var linux = InstanceConfig.defaults(name: "l")
        linux.restoreImage = "/Users/dev/Downloads/macOS 27.ipsw"
        XCTAssertThrowsError(try linux.validate(maxCPUs: 8, maxMemoryGiB: 16), "Linux takes no restore image")
        let plain = String(decoding: try JSONEncoder().encode(InstanceConfig.defaults(name: "l")), as: UTF8.self)
        XCTAssertFalse(plain.contains("restoreImage"))
    }

    func testJSONRoundTrip() throws {
        var c = InstanceConfig.defaults(name: "roundtrip")
        c.networks = []
        c.sharing = SharingSettings(runtimeEnabled: true,
                                    shares: [SharedFolder(hostPath: "/tmp/share", guestPath: "/mnt/share", readOnly: true)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("monad-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try c.save(to: url)
        let loaded = try InstanceConfig.load(from: url)
        XCTAssertEqual(loaded.name, c.name)
        XCTAssertTrue(loaded.networks.isEmpty)
        XCTAssertEqual(loaded.sharing.shares.first?.hostPath, "/tmp/share")
        XCTAssertEqual(loaded.createdAt.timeIntervalSince1970, c.createdAt.timeIntervalSince1970, accuracy: 1)
    }

    func testDefaultsAreSane() {
        let c = InstanceConfig.defaults(name: "x", ephemeral: true)
        XCTAssertTrue(c.ephemeral)
        XCTAssertFalse(c.networks.isEmpty)
        XCTAssertTrue(c.sharing.shares.isEmpty, "host folders must not be shared by default")
        XCTAssertGreaterThanOrEqual(c.cpus, 1)
        XCTAssertGreaterThanOrEqual(c.memoryGiB, 1)
        XCTAssertGreaterThanOrEqual(c.diskGiB, 10)
    }
}

final class CloudInitTests: XCTestCase {
    private let ubuntu = DistroConfig.GuestProfile(packageManager: "apt")
    /// A distro whose sshd is somewhere else (the one path a distro file may give).
    private let fedoraLike = DistroConfig.GuestProfile(sshd: "/usr/libexec/openssh/sshd", packageManager: "dnf")

    private var config: InstanceConfig {
        var c = InstanceConfig.defaults(name: "unit")
        c.user = "dev"
        return c
    }

    func testUserDataHardensSSH() {
        let ud = CloudInit.userData(config: config, guest: ubuntu, publicKey: "ssh-ed25519 AAAAC3Nz monad-unit\n")
        XCTAssertTrue(ud.hasPrefix("#cloud-config\n"))
        XCTAssertTrue(ud.contains("hostname: monad-unit"))
        XCTAssertTrue(ud.contains("- name: \"dev\""), "quoted in YAML")
        XCTAssertTrue(ud.contains("\"ssh-ed25519 AAAAC3Nz monad-unit\""), "key must be quoted and trimmed")
        XCTAssertTrue(ud.contains("ssh_pwauth: false"))
        XCTAssertTrue(ud.contains("lock_passwd: true"))
        XCTAssertTrue(ud.contains("ListenStream=vsock::22"))
        XCTAssertTrue(ud.contains("Accept=yes"))
        XCTAssertTrue(ud.contains("[systemctl, mask, --now, ssh.service, ssh.socket, sshd.service, sshd.socket, sshd-vsock.socket]"))
        XCTAssertFalse(ud.contains("groups:"), "groups are the guest's own (see below)")
        XCTAssertTrue(ud.contains("/usr/sbin/sshd -i\n"))
        XCTAssertTrue(ud.contains("PasswordAuthentication no"))
        XCTAssertTrue(ud.contains("/home/dev/.monad/shots"))
    }

    func testAgentScriptIsBundled() throws {
        let script = try CloudInit.agentScript()
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(script.contains("hello monad-agent 1"))
    }

    func testUserDataInstallsAgentVerbatim() throws {
        let ud = CloudInit.userData(config: config, guest: ubuntu, publicKey: "k")
        let encoded = Data(try CloudInit.agentScript().utf8).base64EncodedString()
        XCTAssertTrue(ud.contains("path: /usr/local/lib/monad/agent"))
        XCTAssertTrue(ud.contains("encoding: b64"))
        XCTAssertTrue(ud.contains("content: \(encoded)"), "script shipped byte for byte")
    }

    /// The guest says on its console what Monad's ssh needs (the boot tab
    /// shows the console): the setup once cloud-init has made it, then
    /// sshd's errors and SELinux denials until Monad logs in.
    func testTheGuestReportsItsSetupOnTheConsole() throws {
        let ud = CloudInit.userData(config: config, guest: ubuntu, publicKey: "k")
        let encoded = Data(try CloudInit.reportScript().utf8).base64EncodedString()
        XCTAssertTrue(ud.contains("path: /usr/local/lib/monad/report"))
        XCTAssertTrue(ud.contains("content: \(encoded)"), "script shipped byte for byte")
        XCTAssertTrue(ud.contains("path: /etc/systemd/system/monad-report.service"))
        XCTAssertTrue(CloudInit.reportServiceUnit.contains("ExecStart=/bin/sh /usr/local/lib/monad/report watch 900\n"))
        XCTAssertTrue(CloudInit.reportServiceUnit.contains("WantedBy=multi-user.target"))
        let enable = try XCTUnwrap(ud.range(of: "[systemctl, enable, --now, monad-sshd.socket]"))
        let setup = try XCTUnwrap(ud.range(of: "[sh, /usr/local/lib/monad/report, setup, \"dev\", \"/usr/sbin/sshd\"]"))
        let watch = try XCTUnwrap(ud.range(of: "[systemctl, enable, --now, --no-block, monad-report.service]"))
        XCTAssertLessThan(enable.lowerBound, setup.lowerBound, "reports the sockets as they are")
        XCTAssertLessThan(setup.lowerBound, watch.lowerBound)
        // VMs made before get the current script and unit at their next boot.
        let installer = try CloudInit.guestInstallScript(guest: ubuntu)
        XCTAssertTrue(installer.contains("install_file /usr/local/lib/monad/report 0755 '\(encoded)'"))
        XCTAssertTrue(installer.contains(
            "install_file /etc/systemd/system/monad-report.service 0644 '\(Data(CloudInit.reportServiceUnit.utf8).base64EncodedString())'"))
    }

    /// Where SELinux is on, Monad loads its own small policy module (rules
    /// its pieces were seen to need on openSUSE: systemd listening on the
    /// agent's vsock socket, sshd's helpers on theirs), at first boot before
    /// the sockets start, and from the installer at every boot, which starts
    /// the agent socket again (VMs made before get it at their next boot).
    func testSELinuxGetsMonadsModuleBeforeTheSocketsStart() throws {
        let cil = try CloudInit.selinuxModule()
        XCTAssertTrue(cil.contains("(allow init_t self (vsock_socket (listen accept)))"))
        XCTAssertTrue(cil.contains("(allow sshd_auth_t sshd_t (vsock_socket (getattr read write)))"))
        let script = try CloudInit.selinuxScript()
        for ud in [CloudInit.userData(config: config, guest: ubuntu, publicKey: "k"),
                   CloudInit.userData(config: config, guest: fedoraLike, publicKey: "k")] {
            XCTAssertTrue(ud.contains("content: \(Data(cil.utf8).base64EncodedString())"))
            XCTAssertTrue(ud.contains("content: \(Data(script.utf8).base64EncodedString())"))
            let load = try XCTUnwrap(ud.range(of: "[sh, /usr/local/lib/monad/selinux]"))
            let sockets = try XCTUnwrap(ud.range(of: "[systemctl, enable, --now, monad-sshd.socket]"))
            XCTAssertLessThan(load.lowerBound, sockets.lowerBound)
        }
        let installer = try CloudInit.guestInstallScript(guest: ubuntu)
        XCTAssertTrue(installer.contains("install_file /usr/local/lib/monad/monad.cil 0644 '\(Data(cil.utf8).base64EncodedString())'"))
        XCTAssertTrue(installer.contains("install_file /usr/local/lib/monad/selinux 0755 '\(Data(script.utf8).base64EncodedString())'"))
        let load = try XCTUnwrap(installer.range(of: "sh /usr/local/lib/monad/selinux\n"))
        let agent = try XCTUnwrap(installer.range(of: "systemctl enable --now monad-agent.socket"))
        XCTAssertLessThan(load.lowerBound, agent.lowerBound)
    }

    /// Generic fixes any distro may need: host keys made if the distro
    /// left that to its own sshd service (masked here), and the vsock
    /// driver loaded if the kernel did not load it by itself.
    func testSSHHasHostKeysAndVsockOnAnyDistro() {
        XCTAssertTrue(CloudInit.sshdServiceUnit(guest: ubuntu).contains("ExecStartPre=-/usr/bin/ssh-keygen -A\n"))
        let ud = CloudInit.userData(config: config, guest: ubuntu, publicKey: "k")
        XCTAssertTrue(ud.contains("bootcmd:\n  - [sh, -c, \"modprobe vmw_vsock_virtio_transport 2>/dev/null || true\"]\n"), ud)
    }

    func testAgentListensOnVsockOnlyWithHardenedService() {
        let ud = CloudInit.userData(config: config, guest: ubuntu, publicKey: "k")
        XCTAssertEqual(CloudInit.agentVsockPort, 1024)
        XCTAssertTrue(ud.contains("ListenStream=vsock::1024"))
        XCTAssertTrue(ud.contains("path: /etc/systemd/system/monad-agent@.service"))
        // Root without any capability (tracefs needs uid 0, nothing else).
        for directive in ["CapabilityBoundingSet=\n", "AmbientCapabilities=\n", "NoNewPrivileges=yes",
                          "ProtectSystem=strict", "ProtectHome=yes", "PrivateTmp=yes", "PrivateDevices=yes",
                          "RestrictAddressFamilies=AF_UNIX", "IPAddressDeny=any", "RestrictNamespaces=yes",
                          "LockPersonality=yes", "RestrictSUIDSGID=yes", "SystemCallFilter=@system-service",
                          "ExecStart=/usr/local/lib/monad/agent", "StandardInput=socket"] {
            XCTAssertTrue(CloudInit.agentServiceUnit.contains(directive), "missing \(directive)")
        }
        XCTAssertFalse(ud.contains("PrivateNetwork=yes"), "would hide the guest's real listening ports")
        XCTAssertFalse(CloudInit.agentServiceUnit.contains("ProtectKernelTunables=yes"),
                       "makes /sys read-only, which blocks the tracefs instance")
        XCTAssertFalse(CloudInit.agentServiceUnit.contains("DynamicUser=yes"), "tracefs requires uid 0")
        XCTAssertTrue(ud.contains("[systemctl, enable, --now, monad-agent.socket]"))
    }

    /// systemd starts sshd itself (under SELinux that is what gives sshd its
    /// own domain, the one that may log users in). Where the guest has no
    /// SELinux, an override starts it with SIGCHLD ignored instead: `sshd -i`
    /// forks a helper and becomes sshd-session, which never reaps it, a
    /// zombie for as long as the connection lasts; the kernel reaps it then.
    /// The guest decides, at first boot and at every boot (the installer).
    func testTheGuestDecidesHowSSHDStarts() throws {
        let unit = CloudInit.sshdServiceUnit(guest: fedoraLike)
        XCTAssertTrue(unit.contains("ExecStart=-/usr/libexec/openssh/sshd -i\n"), unit)
        XCTAssertFalse(unit.contains("/usr/bin/env"), unit)
        XCTAssertEqual(CloudInit.sshdReapOverride(guest: fedoraLike),
                       "[Service]\nExecStart=\nExecStart=-/usr/bin/env --ignore-signal=CHLD /usr/libexec/openssh/sshd -i\n")
        let ud = CloudInit.userData(config: config, guest: fedoraLike, publicKey: "k")
        for line in unit.split(separator: "\n") { XCTAssertTrue(ud.contains("      " + line), String(line)) }
        XCTAssertTrue(ud.contains("content: \(Data(CloudInit.sshdReapOverride(guest: fedoraLike).utf8).base64EncodedString())"))
        let reap = try XCTUnwrap(ud.range(of: "[sh, -c, \"[ -e /sys/fs/selinux/enforce ] || install -D -m 0644 /usr/local/lib/monad/sshd-reap.conf /etc/systemd/system/monad-sshd@.service.d/reap.conf\"]"))
        let reload = try XCTUnwrap(ud.range(of: "[systemctl, daemon-reload]"))
        XCTAssertLessThan(reap.lowerBound, reload.lowerBound)
        // VMs made before get both at their next boot, and lose the override if SELinux came on.
        let script = try CloudInit.guestInstallScript(guest: fedoraLike)
        XCTAssertTrue(script.contains("install_file /etc/systemd/system/monad-sshd@.service 0644 '\(Data(unit.utf8).base64EncodedString())'"))
        XCTAssertTrue(script.contains("install_file /usr/local/lib/monad/sshd-reap.conf 0644"))
        XCTAssertTrue(script.contains("if [ -e /sys/fs/selinux/enforce ]; then"))
        XCTAssertTrue(script.contains("rm -f \"$reap\""))
    }

    /// The distro file need not say where sshd is: /usr/sbin/sshd on every
    /// distro Monad knows (a symlink on Arch).
    func testSSHDIsInTheUsualPlaceUnlessTheDistroSaysOtherwise() {
        XCTAssertTrue(CloudInit.sshdServiceUnit(guest: .init()).contains("ExecStart=-/usr/sbin/sshd -i\n"))
        XCTAssertTrue(CloudInit.userData(config: config, guest: .init(), publicKey: "k")
            .contains("[sh, /usr/local/lib/monad/report, setup, \"dev\", \"/usr/sbin/sshd\"]"))
    }

    /// The user joins whichever admin groups the guest has (sudo comes from
    /// the sudoers rule cloud-init writes, not from a group).
    func testTheUserJoinsTheAdminGroupsTheGuestHas() {
        let ud = CloudInit.userData(config: config, guest: .init(), publicKey: "k")
        XCTAssertTrue(ud.contains("sudo: \"ALL=(ALL) NOPASSWD:ALL\""))
        XCTAssertTrue(ud.contains("[sh, -c, \"for g in wheel sudo adm; do getent group $g >/dev/null && usermod -aG $g dev; done; true\"]"), ud)
    }

    func testGuestInstallScriptIsIdempotentAndMatchesCloudInit() throws {
        let script = try CloudInit.guestInstallScript(guest: ubuntu)
        XCTAssertTrue(script.hasPrefix("set -eu\n"))
        XCTAssertTrue(script.contains("/usr/local/lib/monad/agent"))
        // Only rewrites a file when its content changed, then reloads once.
        XCTAssertTrue(script.contains("cmp -s"))
        XCTAssertTrue(script.contains("systemctl daemon-reload"))
        XCTAssertTrue(script.contains("systemctl enable --now monad-agent.socket"))
        XCTAssertTrue(script.hasSuffix("echo agent-ok\n"))
        // Same unit files as first boot.
        let ud = CloudInit.userData(config: config, guest: ubuntu, publicKey: "k")
        for unit in [CloudInit.agentSocketUnit, CloudInit.agentServiceUnit] {
            XCTAssertTrue(script.contains(Data(unit.utf8).base64EncodedString()))
            let firstLine = unit.split(separator: "\n").first.map(String.init) ?? ""
            XCTAssertTrue(ud.contains(firstLine))
        }
        XCTAssertEqual(CloudInit.guestInstallCommand, "sudo -n sh -s")
    }

    /// A Lima VM's seed keeps Lima working on the same disk (Phase 9): the
    /// network sshd is masked only until the next reboot, at each Monad boot
    /// (Lima needs it); host keys are kept; Lima's hostname and mounts stay
    /// Lima's; the existing user only gets Monad's key; Monad's folders go
    /// in the user's real home.
    func testALimaVMsSeedKeepsLimaWorking() {
        var c = config
        c.attached = AttachedDisk(lima: "default", dir: "/Users/dev/.lima/default", home: "/home/dev.linux")
        let ud = CloudInit.userData(config: c, guest: ubuntu, publicKey: "ssh-ed25519 AAAA k")
        XCTAssertTrue(ud.contains("hostname: lima-default\n"))
        XCTAssertTrue(ud.contains("ssh_deletekeys: false\n"))
        XCTAssertTrue(ud.contains("mounts: []\n"))
        XCTAssertFalse(ud.contains("[systemctl, mask, --now"), "no lasting mask")
        XCTAssertTrue(ud.contains("bootcmd:\n  - [systemctl, mask, --runtime, --now, ssh.service, ssh.socket, sshd.service, sshd.socket, sshd-vsock.socket, lima-guestagent.service]\n"))
        XCTAssertEqual(ud.components(separatedBy: "bootcmd:").count, 2, "one bootcmd, Lima's")
        XCTAssertFalse(ud.contains("[systemctl, enable, --now, --no-block, monad-report.service]"),
                       "Lima boots it too: no watch for Monad's login there")
        XCTAssertFalse(ud.contains("report, setup"))
        XCTAssertTrue(ud.contains("\"ssh-ed25519 AAAA k\""))
        XCTAssertFalse(ud.contains("lock_passwd"), "Lima's user is left as Lima made it")
        // Monad's vsock sshd only while Monad runs the VM: under Lima, systemd's
        // own vsock sshd (which Lima dials) may take vsock port 22.
        XCTAssertTrue(ud.contains("  - [systemctl, enable, --runtime, --now, monad-sshd.socket]\n"))
        XCTAssertFalse(ud.contains("[systemctl, enable, --now, monad-sshd.socket]"), "nothing lasting")
        XCTAssertTrue(ud.contains("  - [sh, -c, \"! [ -e /etc/systemd/system/monad-sshd.socket ] || systemctl enable --runtime --now --no-block monad-sshd.socket\"]\n"),
                      "at every later boot, before the unit would be started")
        XCTAssertTrue(ud.contains("/home/dev.linux/.monad/shots"))
        XCTAssertFalse(ud.contains("/home/dev/.monad"))
        XCTAssertFalse(ud.contains("\t"))
        XCTAssertEqual(CloudInit.metaData(config: c, instanceID: "iid-1"), "instance-id: iid-1\nlocal-hostname: lima-default\n")
        let s = CloudInit.enforceIsolationScript(guest: ubuntu, lima: true)
        XCTAssertTrue(s.contains("mask --runtime --now ssh.service ssh.socket sshd.service sshd.socket lima-guestagent.service"))
        XCTAssertTrue(s.contains("mask --runtime sshd-vsock.socket"))
        XCTAssertFalse(s.contains("mask --now"), "nothing lasting")
        XCTAssertTrue(s.contains("tcp22-open"))
        XCTAssertTrue(CloudInit.isIsolationCheck(s))
    }

    /// A copy of a Lima VM is Monad's own: Monad's host name, lasting masks
    /// (Lima's guest agent too), new host keys, and Lima's boot script gone
    /// (it would look for Lima's seed at every boot).
    func testACopiedLimaVMLeavesLimaBehind() {
        var c = config
        c.copiedFrom = AttachedDisk(lima: "default", dir: "/Users/dev/.lima/default", home: "/home/dev.guest")
        let ud = CloudInit.userData(config: c, guest: ubuntu, publicKey: "k")
        XCTAssertTrue(ud.contains("hostname: monad-unit\n"))
        XCTAssertTrue(ud.contains("[systemctl, mask, --now, ssh.service, ssh.socket, sshd.service, sshd.socket, sshd-vsock.socket, lima-guestagent.service]"))
        XCTAssertTrue(ud.contains("  - [rm, -f, /var/lib/cloud/scripts/per-boot/00-lima.boot.sh]\n"))
        XCTAssertTrue(ud.contains("[systemctl, enable, --now, monad-sshd.socket]"))
        XCTAssertTrue(ud.contains("/home/dev.guest/.monad/shots"))
        XCTAssertFalse(ud.contains("ssh_deletekeys"), "not the Lima VM's host keys")
        XCTAssertFalse(ud.contains("--runtime"), "lasting masks, not Lima's runtime ones")
        XCTAssertTrue(ud.contains("monad-report.service"), "it reports its setup like any Monad VM")
        XCTAssertFalse(ud.contains("\t"))
        XCTAssertFalse(CloudInit.userData(config: config, guest: ubuntu, publicKey: "k").contains("00-lima"))
    }

    /// Lima's host name for an instance: "lima-" and the name, with "." and
    /// "_" made "-".
    func testALimaVMKeepsLimasHostName() {
        var c = config
        c.attached = AttachedDisk(lima: "my_vm.1", dir: "/Users/dev/.lima/my_vm.1")
        XCTAssertTrue(CloudInit.userData(config: c, guest: ubuntu, publicKey: "k").contains("hostname: lima-my-vm-1\n"))
        XCTAssertEqual(CloudInit.metaData(config: c, instanceID: "i"), "instance-id: i\nlocal-hostname: lima-my-vm-1\n")
    }

    /// The check fails closed: where sudo asks for a password (a Lima VM can
    /// be set up so) the listening ports are still read, and a check that
    /// cannot read them never says "ok".
    func testTheIsolationCheckFailsClosed() throws {
        let tmp = TempDir()
        let bin = tmp.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        func stub(_ name: String, _ body: String) throws {
            let url = bin.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        func check(lima: Bool = false) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", CloudInit.enforceIsolationScript(guest: ubuntu, lima: lima)]
            p.environment = ["PATH": "\(bin.path):/usr/bin:/bin"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try stub("systemctl", "exit 0")
        try stub("sudo", "echo 'sudo: a password is required' >&2; exit 1")
        try stub("ss", "echo 'LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*'")
        XCTAssertEqual(try check(), "tcp22-open", "sshd still listens, whatever sudo says")
        XCTAssertEqual(try check(lima: true), "tcp22-open")
        try stub("ss", "echo 'LISTEN 0 4096 127.0.0.1:631 0.0.0.0:*'")
        XCTAssertEqual(try check(), "ok")
        try stub("ss", "exit 1")
        XCTAssertNotEqual(try check(), "ok", "ports that cannot be read are not closed ones")
    }

    /// On a first boot systemd's own vsock sshd (sshd-vsock.socket) answers
    /// before cloud-init has set up Monad's: the check then says "not yet"
    /// and masks nothing, or it would close the only way in until Monad's
    /// came up (and the steps run once the VM is ready would fail).
    func testTheIsolationCheckWaitsForMonadsOwnSSHD() throws {
        let tmp = TempDir()
        let bin = tmp.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let calls = tmp.url.appendingPathComponent("calls")
        func stub(_ name: String, _ body: String) throws {
            let url = bin.appendingPathComponent(name)
            try "#!/bin/sh\necho \"\(name) $*\" >> '\(calls.path)'\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        func check() throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", CloudInit.enforceIsolationScript(guest: ubuntu)]
            p.environment = ["PATH": "\(bin.path):/usr/bin:/bin"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try stub("systemctl", "[ \"$*\" = \"is-active --quiet monad-sshd.socket\" ] && exit 3; exit 0")
        try stub("sudo", "exit 0")
        try stub("ss", "echo 'LISTEN 0 4096 127.0.0.1:631 0.0.0.0:*'")
        XCTAssertEqual(try check(), CloudInit.monadSSHDNotYet)
        let ran = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
        XCTAssertFalse(ran.contains("sudo"), "nothing masked yet: \(ran)")
        try stub("systemctl", "exit 0")
        XCTAssertEqual(try check(), "ok")
    }

    func testUserDataHasNoTabs() {
        // YAML forbids tabs for indentation.
        XCTAssertFalse(CloudInit.userData(config: config, guest: ubuntu, publicKey: "k").contains("\t"))
    }

    func testMetaData() {
        let md = CloudInit.metaData(config: config, instanceID: "iid-1")
        XCTAssertEqual(md, "instance-id: iid-1\nlocal-hostname: monad-unit\n")
    }

    /// A name with capitals: the guest's host name is lowercase, as host names go.
    func testAHostNameIsLowercase() {
        var c = config
        c.name = "MyVM-2"
        XCTAssertTrue(CloudInit.userData(config: c, guest: ubuntu, publicKey: "k").contains("hostname: monad-myvm-2\n"))
        XCTAssertEqual(CloudInit.metaData(config: c, instanceID: "i"), "instance-id: i\nlocal-hostname: monad-myvm-2\n")
        // ssh lowercases the host it is given before it matches Host lines.
        XCTAssertEqual(c.sshHost, "monad-myvm-2")
        let paths = InstancePaths(name: c.name)
        let cfg = CloudInit.sshConfig(config: c, paths: paths)
        XCTAssertTrue(cfg.contains("Host monad-myvm-2\n"), cfg)
        XCTAssertTrue(cfg.contains("HostKeyAlias monad-myvm-2\n"), cfg)
        XCTAssertTrue(CloudInit.sshArguments(config: c, paths: paths).contains("HostKeyAlias=monad-myvm-2"))
    }

    func testSSHConfigUsesPrivateSocketAndKey() {
        let paths = InstancePaths(name: "unit")
        let cfg = CloudInit.sshConfig(config: config, paths: paths)
        XCTAssertTrue(cfg.contains("Host monad-unit"))
        XCTAssertTrue(cfg.contains("User dev"))
        XCTAssertTrue(cfg.contains("ProxyCommand /usr/bin/nc -U \(paths.sshSocket.path)"))
        XCTAssertTrue(cfg.contains("IdentityFile \(paths.privateKey.path)"))
        XCTAssertTrue(cfg.contains("IdentitiesOnly yes"))
        XCTAssertTrue(cfg.contains("IdentityAgent none"))
        XCTAssertTrue(cfg.contains("ForwardAgent no"))
        XCTAssertTrue(cfg.contains("UserKnownHostsFile \(paths.knownHosts.path)"))
        XCTAssertTrue(cfg.contains("ControlPath \(paths.controlSocket.path)"))
    }

    /// Monad's own ssh runs read no config file (F-09): any process of the
    /// user can rewrite ssh.config, and a ProxyCommand in it would run as a
    /// child of MonadHost. The options come from the VM's settings.
    func testSSHOptionsAreOnTheCommandLine() {
        let paths = InstancePaths(name: "unit")
        let args = CloudInit.sshArguments(config: config, paths: paths)
        XCTAssertEqual(Array(args.prefix(2)), ["-F", "none"])
        let options = stride(from: 2, to: args.count, by: 2).map { (args[$0], args[$0 + 1]) }
        XCTAssertEqual(args.count % 2, 0)
        XCTAssertTrue(options.allSatisfy { $0.0 == "-o" }, "\(args)")
        let values = options.map(\.1)
        for o in ["User=dev", "IdentityFile=\(paths.privateKey.path)", "IdentitiesOnly=yes", "IdentityAgent=none",
                  "ForwardAgent=no", "StrictHostKeyChecking=accept-new", "UserKnownHostsFile=\(paths.knownHosts.path)",
                  "HostKeyAlias=monad-unit", "ControlPath=\(paths.controlSocket.path)", "EscapeChar=none"] {
            XCTAssertTrue(values.contains(o), o)
        }
        XCTAssertTrue(values.contains { $0.hasPrefix("ProxyCommand=/usr/bin/nc -U ") && $0.hasSuffix("ssh.sock") })
        XCTAssertFalse(values.contains { $0.hasPrefix("ControlMaster=") }, "each caller chooses: ssh keeps the first")
    }

    /// `~` after a newline in a tab is not ssh's escape (F-17): pasted text
    /// or a guest-set clipboard cannot reach ssh's command line.
    func testTheSSHConfigFileTurnsOffEscapes() {
        XCTAssertTrue(CloudInit.sshConfig(config: config, paths: InstancePaths(name: "unit")).contains("  EscapeChar none\n"))
    }

    func testIsolationScriptChecksTCP22() {
        let s = CloudInit.enforceIsolationScript(guest: ubuntu)
        XCTAssertTrue(s.contains("mask --now ssh.service ssh.socket sshd.service sshd.socket"))
        XCTAssertTrue(s.contains("sshd-vsock.socket"))
        XCTAssertTrue(s.contains("tcp22-open"))
        XCTAssertTrue(CloudInit.isIsolationCheck(s))
        XCTAssertFalse(CloudInit.isIsolationCheck("true"))
        XCTAssertFalse(CloudInit.isIsolationCheck(nil))
    }

    /// Invariant over every distro Monad ships, and over none in particular:
    /// every network sshd unit name is masked at first boot and on every
    /// boot (a name the guest does not have costs nothing), passwords stay
    /// off, and systemd starts sshd itself.
    func testEveryDistroMasksEveryNetworkSSH() throws {
        XCTAssertEqual(CloudInit.networkSSHUnits, ["ssh.service", "ssh.socket", "sshd.service", "sshd.socket"])
        for d in try DistroCatalog.bundled().distros {
            let ud = CloudInit.userData(config: config, guest: d.guest, publicKey: "k")
            let iso = CloudInit.enforceIsolationScript(guest: d.guest)
            for unit in CloudInit.networkSSHUnits + ["sshd-vsock.socket"] {
                XCTAssertTrue(ud.contains(unit), "\(d.id): user-data does not mask \(unit)")
                XCTAssertTrue(iso.contains(unit), "\(d.id): isolation check does not mask \(unit)")
            }
            XCTAssertTrue(ud.contains("ssh_pwauth: false") && ud.contains("PasswordAuthentication no"), d.id)
            XCTAssertFalse(ud.contains("PasswordAuthentication yes"), d.id)
            XCTAssertTrue(ud.contains("ExecStart=-\(d.guest.sshdPath) -i\n"), d.id)
        }
    }

    /// Monad runs Apple silicon guests only (natively: it emulates nothing).
    func testTheBundledDistrosAreAppleSiliconOnly() throws {
        for d in try DistroCatalog.bundled().distros { XCTAssertEqual(Array(d.architectures.keys), ["arm64"], d.id) }
    }

    /// A distro file now describes images only: the bundled ones say
    /// nothing about their guests but the package manager (for profiles),
    /// which every Linux one has and macOS does not.
    func testTheBundledDistrosDescribeImagesNotGuests() throws {
        for d in try DistroCatalog.bundled().distros {
            XCTAssertEqual(d.guest, DistroConfig.GuestProfile(packageManager: d.guest.packageManager), d.id)
            XCTAssertEqual(d.guest.packageManager == nil, d.guestOS == .macos, d.id)
        }
    }

    func testUnixSocketPathFitsSunPath() {
        // sockaddr_un.sun_path is 104 bytes on macOS.
        let longest = InstancePaths(name: String(repeating: "a", count: 32))
        XCTAssertLessThan(longest.sshSocket.path.utf8.count, 104)
        XCTAssertLessThan(longest.controlSocket.path.utf8.count, 104)
    }
}

final class BackendHelperTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("monad-tests-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testSeedISOHasCidataLabelAndFiles() throws {
        let iso = tmp.appendingPathComponent("seed.iso")
        let ud = Data("#cloud-config\n".utf8), md = Data("instance-id: x\n".utf8)
        let rc: Int32 = ud.withUnsafeBytes { u in
            md.withUnsafeBytes { m in
                "user-data".withCString { un in
                    "meta-data".withCString { mn in
                        var files = [mnd_iso_file(name: un, data: u.baseAddress, len: u.count),
                                     mnd_iso_file(name: mn, data: m.baseAddress, len: m.count)]
                        return mnd_iso9660_write(iso.path, "cidata", &files, files.count)
                    }
                }
            }
        }
        XCTAssertEqual(rc, 0)
        let data = try Data(contentsOf: iso)
        XCTAssertEqual(data.count % 2048, 0)
        XCTAssertEqual(data.subdata(in: 16 * 2048 + 1..<16 * 2048 + 6), Data("CD001".utf8))
        XCTAssertEqual(data.subdata(in: 16 * 2048 + 40..<16 * 2048 + 46), Data("CIDATA".utf8))
        XCTAssertEqual(data[17 * 2048], 2, "Joliet supplementary descriptor")
        XCTAssertNotNil(data.range(of: ud))
        XCTAssertNotNil(data.range(of: md))
    }

    func testDiskCloneAndGrowAreSparse() throws {
        let src = tmp.appendingPathComponent("base.raw"), dst = tmp.appendingPathComponent("disk.raw")
        let payload = Data(repeating: 0xAB, count: 4096)
        try payload.write(to: src)
        XCTAssertEqual(mnd_disk_clone(src.path, dst.path), 0)
        XCTAssertEqual(mnd_disk_clone(src.path, dst.path), EEXIST, "never overwrite an existing disk")
        XCTAssertEqual(mnd_disk_grow(dst.path, 1 << 30), 0)
        let attrs = try FileManager.default.attributesOfItem(atPath: dst.path)
        XCTAssertEqual((attrs[.size] as? NSNumber)?.int64Value, 1 << 30)
        var allocated: UInt64 = 0
        XCTAssertEqual(mnd_disk_allocated_bytes(dst.path, &allocated), 0)
        XCTAssertLessThan(allocated, 64 << 20, "grown disk must stay sparse")
        XCTAssertEqual(try Data(contentsOf: dst).prefix(4096), payload)
        // Growing never shrinks.
        XCTAssertEqual(mnd_disk_grow(dst.path, 4096), 0)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? NSNumber)?.int64Value, 1 << 30)
    }

    func testQcow2ProbeRejectsGarbage() throws {
        let f = tmp.appendingPathComponent("junk.img")
        try Data(repeating: 7, count: 4096).write(to: f)
        var info = mnd_qcow2_info()
        XCTAssertEqual(mnd_qcow2_probe(f.path, &info), EINVAL)
    }
}

final class TransferTests: XCTestCase {
    func testSanitizeProducesSafeNames() {
        XCTAssertEqual(FileUploader.sanitize("shot-20260928-120000.png"), "shot-20260928-120000.png")
        XCTAssertEqual(FileUploader.sanitize("my file (1).png"), "my_file__1_.png")
        XCTAssertEqual(FileUploader.sanitize("../../etc/passwd"), "_.._etc_passwd")
        XCTAssertEqual(FileUploader.sanitize("$(rm -rf ~);.png"), "__rm_-rf____.png")
        XCTAssertEqual(FileUploader.sanitize("...hidden"), "hidden")
        XCTAssertEqual(FileUploader.sanitize(""), "file")
        XCTAssertEqual(FileUploader.sanitize("ümlaut.png"), "_mlaut.png")
        XCTAssertLessThanOrEqual(FileUploader.sanitize(String(repeating: "x", count: 500)).count, 120)
        for name in ["a b", "a'b", "a\"b", "a`b", "a$b", "a;b", "a\nb", "a/b"] {
            let s = FileUploader.sanitize(name)
            XCTAssertNil(s.rangeOfCharacter(from: CharacterSet(charactersIn: " '\"`$;\n/")), s)
        }
    }

    func testShellQuote() {
        XCTAssertEqual(ShellQuote.quote("/home/dev/.monad/shots/a.png"), "/home/dev/.monad/shots/a.png")
        XCTAssertEqual(ShellQuote.quote("/tmp/a b"), "'/tmp/a b'")
        XCTAssertEqual(ShellQuote.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellQuote.quote(""), "''")
        XCTAssertEqual(ShellQuote.quote("$(x)"), "'$(x)'")
    }
}
