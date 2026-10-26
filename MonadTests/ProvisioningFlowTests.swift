//
//  ProvisioningFlowTests.swift — VMManager creates instances inside an
//  injected root using fake image, key and VM providers.
//

import Combine
import XCTest
@testable import Monad

@MainActor
final class ProvisioningFlowTests: XCTestCase {
    private var fixture: ManagerFixture!
    private var tmp: TempDir { fixture.tmp }
    private var root: URL { fixture.root }
    private var runner: FakeCommandRunner { fixture.runner }
    private var factory: FakeMachineFactory { fixture.factory }
    private var images: FakeImageProvider { fixture.images }
    private var manager: VMManager { fixture.manager }

    override func setUp() async throws {
        fixture = try ManagerFixture()
    }

    private func createdVM(_ name: String, file: StaticString = #filePath, line: UInt = #line) async throws -> VMInstance {
        let vm = manager.instance(named: name)
        _ = await eventually { if case .preparing = vm.state { return false } else { return true } }
        return try XCTUnwrap(manager.existing(name), "provisioning \(name) failed: \(vm.state)", file: file, line: line)
    }

    // MARK: macOS (Phase 14)

    private func macConfig(_ name: String) -> InstanceConfig {
        var c = InstanceConfig.defaults(name: name)
        c.distro = "macos"
        c.release = nil
        c.cpus = 4
        c.memoryGiB = 4
        c.diskGiB = 64
        return c
    }

    /// The restore image is installed by Apple's installer into the VM's
    /// own folder, at the disk size asked for; no cloud-init seed; the VM
    /// says it is macOS. The installer's progress is the VM's state.
    func testAMacOSVMIsInstalledFromItsRestoreImage() async throws {
        let installer = FakeMacInstaller()
        installer.progressSteps = [0.03, 0.07, 0.25, 0.5, 0.55]
        let bin = TempDir()
        defer { withExtendedLifetime(bin) {} }
        let guestd = bin.url.appendingPathComponent("MonadHost")
        try Data("binary".utf8).write(to: guestd)
        fixture = try ManagerFixture {
            $0.macInstaller = installer
            $0.allowsMacGuests = true
            $0.macSetup = FakeMacSetup()
            $0.guestdBinary = guestd
        }
        var seen: [String] = []
        let vm = try manager.create(macConfig("mac"))
        let watch = vm.$state.sink { if case .preparing(let s) = $0 { seen.append(s) } }
        defer { watch.cancel() }
        await assertEventually("\(vm.state)") { vm.state == .stopped }
        XCTAssertEqual(installer.installs.map(\.restoreImage), [images.url])
        XCTAssertEqual(installer.installs.first?.diskBytes, 64 << 30)
        XCTAssertEqual(installer.installs.first?.paths.dir, vm.paths.dir)
        XCTAssertEqual(vm.config.guestOS, .macos)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vm.paths.seed.path), "no cloud-init")
        XCTAssertTrue(seen.contains("Installing macOS — 50%"), "\(seen)")
        XCTAssertEqual(try InstanceConfig.load(from: vm.paths.config).guestOS, .macos)
        // The VM's log has the install every 10%, not each step of it.
        vm.log.flush()
        let log = try String(contentsOf: vm.paths.vmLog, encoding: .utf8)
        for percent in [3, 25, 50] {
            XCTAssertTrue(log.contains("→ preparing (Installing macOS — \(percent)%)"), "\(percent)% in \(log)")
        }
        for percent in [7, 55] { XCTAssertFalse(log.contains("→ preparing (Installing macOS — \(percent)%)"), log) }
        XCTAssertTrue(log.contains("first boot: macOS answered"), log)
    }

    /// A step's progress goes to the VM's log each 10%: a new step always,
    /// the same step only when it reaches the next ten.
    func testProgressIsLoggedEachTenPercent() {
        XCTAssertTrue(VMInstance.logsProgress(from: "Preparing VM unit…", to: "Downloading x — 0% (1 MB)"))
        XCTAssertFalse(VMInstance.logsProgress(from: "Downloading x — 1% (1 MB)", to: "Downloading x — 9% (8 MB)"))
        XCTAssertTrue(VMInstance.logsProgress(from: "Downloading x — 9% (8 MB)", to: "Downloading x — 10% (9 MB)"))
        XCTAssertTrue(VMInstance.logsProgress(from: "Downloading x — 38% (1.2 GB)", to: "Downloading x — 52% (1.6 GB)"))
        XCTAssertFalse(VMInstance.logsProgress(from: "Downloading x — 12 MB", to: "Downloading x — 900 MB"),
                       "no total: only its size")
        XCTAssertTrue(VMInstance.logsProgress(from: "Installing macOS — 99%", to: "Installing macOS — 100%"))
        XCTAssertTrue(VMInstance.logsProgress(from: "Installing macOS — 40%", to: "Setting up macOS…"))
    }

    /// An IPSW file chosen in the New VM sheet is installed where it is:
    /// nothing is asked of Apple or downloaded; the VM's file keeps the
    /// image's name, not the path.
    func testAChosenRestoreImageIsInstalledWhereItIs() async throws {
        let installer = FakeMacInstaller()
        let bin = TempDir()
        defer { withExtendedLifetime(bin) {} }
        let guestd = bin.url.appendingPathComponent("MonadHost")
        try Data("binary".utf8).write(to: guestd)
        let ipsw = bin.url.appendingPathComponent("macOS 27.ipsw")
        try Data("ipsw".utf8).write(to: ipsw)
        fixture = try ManagerFixture {
            $0.macInstaller = installer
            $0.allowsMacGuests = true
            $0.macSetup = FakeMacSetup()
            $0.guestdBinary = guestd
        }
        var c = macConfig("mac")
        c.restoreImage = ipsw.path
        let vm = try manager.create(c)
        await assertEventually("\(vm.state)") { vm.state == .stopped }
        XCTAssertEqual(installer.installs.map(\.restoreImage), [ipsw])
        XCTAssertEqual(images.requests, 0, "nothing asked of Apple")
        let saved = try InstanceConfig.load(from: vm.paths.config)
        XCTAssertNil(saved.restoreImage)
        XCTAssertEqual(saved.image, "macOS (macOS 27.ipsw)")
    }

    /// A chosen IPSW that is not there fails the VM with why, before any install.
    func testAMissingRestoreImageSaysSo() async throws {
        let installer = FakeMacInstaller()
        fixture = try ManagerFixture {
            $0.macInstaller = installer
            $0.allowsMacGuests = true
            $0.macSetup = FakeMacSetup()
        }
        var c = macConfig("mac")
        c.restoreImage = "/nowhere/macOS 27.ipsw"
        let vm = try manager.create(c)
        await assertEventually("\(vm.state)") { vm.creationFailed }
        XCTAssertEqual(installer.installs.count, 0)
        guard case .failed(let why) = vm.state else { return XCTFail("\(vm.state)") }
        XCTAssertTrue(why.contains("macOS 27.ipsw"), why)
    }

    /// After the install, the setup: the staged files, the user asked once
    /// (here a fake that does what the root step does), the finished disk
    /// in place, the VM set up and ready to start; the password kept for
    /// the user, the staged copy gone.
    func testAMacOSVMIsSetUpAfterItsInstall() async throws {
        let setup = FakeMacSetup()
        let bin = TempDir()
        defer { withExtendedLifetime(bin) {} }
        let guestd = bin.url.appendingPathComponent("MonadHost")
        try Data("binary".utf8).write(to: guestd)
        fixture = try ManagerFixture {
            $0.macInstaller = FakeMacInstaller()
            $0.allowsMacGuests = true
            $0.macSetup = setup
            $0.guestdBinary = guestd
        }
        let vm = try manager.create(macConfig("mac"))
        await assertEventually("\(vm.state)") { vm.state == .stopped }
        XCTAssertEqual(setup.asked.map(\.vm), ["mac"])
        XCTAssertEqual(setup.asked.first?.disk, vm.paths.disk)
        XCTAssertEqual(try Data(contentsOf: vm.paths.disk), Data("set up".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vm.paths.macSetupDone.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vm.paths.macSetupPayload.path))
        let password = try String(contentsOf: vm.paths.macPassword, encoding: .utf8)
        XCTAssertEqual(password.count, 24)
        XCTAssertEqual(setup.stagedPassword, password, "the account's password is the one kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vm.paths.sshConfig.path))
    }

    /// Set up, it boots like a Linux VM but checked the macOS way: nothing
    /// may listen for ssh on its network (netstat), and the agent refreshed
    /// is the macOS one, where monad-guestd runs it.
    func testASetUpMacOSVMBootsCheckedTheMacOSWay() async throws {
        let bin = TempDir()
        defer { withExtendedLifetime(bin) {} }
        let guestd = bin.url.appendingPathComponent("MonadHost")
        try Data("binary".utf8).write(to: guestd)
        fixture = try ManagerFixture {
            $0.macInstaller = FakeMacInstaller()
            $0.allowsMacGuests = true
            $0.macSetup = FakeMacSetup()
            $0.guestdBinary = guestd
        }
        let vm = try manager.create(macConfig("mac"))
        await assertEventually { vm.state == .stopped }
        runner.setHandler { call in
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            if call.arguments.last == MacSetup.agentInstallCommand { return .ok("agent-ok\n") }
            return .ok()
        }
        vm.start()
        await assertEventually("\(vm.state)") { vm.state == .ready }
        let remote = runner.calls.compactMap { $0.executable == "/usr/bin/ssh" ? $0.arguments.last : nil }
        let check = try XCTUnwrap(remote.first { CloudInit.isIsolationCheck($0) })
        XCTAssertTrue(check.contains("netstat"), check)
        XCTAssertFalse(check.contains("systemctl"), "no Linux in a macOS check")
        await assertEventually { runner.calls.contains { $0.arguments.last == MacSetup.agentInstallCommand } }
        let install = try XCTUnwrap(runner.calls.first { $0.arguments.last == MacSetup.agentInstallCommand })
        XCTAssertEqual(install.stdin.map { String(decoding: $0, as: UTF8.self) }, try MacSetup.guestInstallScript())
    }

    /// The answer of `hdiutil attach` for a macOS disk, its Data volume
    /// holding TCC.db under the mount root it was given.
    private func attachingMacDisk(_ call: FakeCommandRunner.Call) throws -> ProcessRunner.Result {
        try FakeMacDisk.attach(call)
    }

    /// Set up, the VM starts once while it is made, with no network: its
    /// first boot makes the account and Monad's services; Monad logs in
    /// once (sshd makes its host keys, the Mac keeps the VM's), shuts it
    /// down cleanly from inside, then gives its ssh sessions full disk access
    /// (the Remote Login box's TCC row, macOS made TCC.db at that boot),
    /// writing the disk as the user. The order is the one checked by hand.
    func testAMacOSVMStartsOnceToFinishItsSetup() async throws {
        let bin = TempDir()
        defer { withExtendedLifetime(bin) {} }
        let guestd = bin.url.appendingPathComponent("MonadHost")
        try Data("binary".utf8).write(to: guestd)
        fixture = try ManagerFixture {
            $0.macInstaller = FakeMacInstaller()
            $0.allowsMacGuests = true
            $0.macSetup = FakeMacSetup()
            $0.guestdBinary = guestd
        }
        runner.setHandler { [unowned self] call in
            if call.executable == "/usr/bin/hdiutil", call.arguments.first == "attach" { return try attachingMacDisk(call) }
            if call.executable == "/usr/bin/ssh-keygen", let i = call.arguments.firstIndex(of: "-f") {
                try Data("PRIVATE".utf8).write(to: URL(fileURLWithPath: call.arguments[i + 1]))
                try Data("ssh-ed25519 AAAATEST monad-test\n".utf8).write(to: URL(fileURLWithPath: call.arguments[i + 1] + ".pub"))
            }
            return .ok()
        }
        var seen: [String] = []
        let vm = try manager.create(macConfig("mac"))
        let watch = vm.$state.sink { if case .preparing(let s) = $0 { seen.append(s) } }
        defer { watch.cancel() }
        await assertEventually("\(vm.state)") { vm.state == .stopped }
        XCTAssertTrue(seen.contains("Starting macOS for the first time…"), "\(seen)")
        XCTAssertEqual(factory.machine.started, 1)
        XCTAssertEqual(factory.machine.bridge?.path, vm.paths.sshSocket.path)
        XCTAssertEqual(factory.machine.bridge?.port, CloudInit.vsockSSHPort)
        let calls = runner.calls
        let login = try XCTUnwrap(calls.firstIndex { $0.executable == "/usr/bin/ssh" && $0.arguments.last == "true" })
        let shutdown = try XCTUnwrap(calls.firstIndex { $0.executable == "/usr/bin/ssh" && $0.arguments.last == VMManager.macShutdownCommand })
        // Recovery knows the account only from the Preboot volume (SIP is changed there).
        let preboot = try XCTUnwrap(calls.firstIndex { $0.executable == "/usr/bin/ssh" && $0.arguments.last == VMManager.macPrebootCommand })
        XCTAssertLessThan(login, preboot)
        XCTAssertLessThan(preboot, shutdown)
        let attachAt = try XCTUnwrap(calls.firstIndex { $0.executable == "/usr/bin/hdiutil" && $0.arguments.first == "attach" })
        XCTAssertLessThan(login, shutdown)
        XCTAssertLessThan(shutdown, attachAt, "the disk is written only once the VM is off")
        let boot = try XCTUnwrap(factory.made.last)
        XCTAssertEqual(boot.config.guestOS, .macos)
        XCTAssertEqual(boot.config.networks, [], "no network at the first boot")
        let attach = try XCTUnwrap(runner.calls.first { $0.executable == "/usr/bin/hdiutil" && $0.arguments.first == "attach" })
        XCTAssertTrue(attach.arguments.contains(vm.paths.disk.path))
        XCTAssertFalse(attach.arguments.contains("-readonly"))
        let sql = try XCTUnwrap(runner.calls.first { $0.executable == "/usr/bin/sqlite3" })
        XCTAssertTrue(sql.arguments.first?.hasSuffix("/Macintosh HD/Library/Application Support/com.apple.TCC/TCC.db") ?? false,
                      "\(sql.arguments)")
        XCTAssertEqual(sql.arguments.last, try MacSetup.fullDiskAccessSQL())
        let detach = try XCTUnwrap(runner.calls.first { $0.executable == "/usr/bin/hdiutil" && $0.arguments.first == "detach" })
        XCTAssertEqual(detach.arguments, ["detach", "/dev/disk6"])
        XCTAssertFalse(runner.calls.contains { $0.executable == "/usr/bin/sudo" || $0.executable == "/usr/bin/osascript" },
                       "the grant needs no admin")
    }

    /// A first boot where Monad never gets in fails the VM: stopped, not made.
    func testAMacOSFirstBootThatNeverEndsFailsTheVM() async throws {
        let bin = TempDir()
        defer { withExtendedLifetime(bin) {} }
        let guestd = bin.url.appendingPathComponent("MonadHost")
        try Data("binary".utf8).write(to: guestd)
        fixture = try ManagerFixture {
            $0.macInstaller = FakeMacInstaller()
            $0.allowsMacGuests = true
            $0.macSetup = FakeMacSetup()
            $0.guestdBinary = guestd
        }
        factory.machine.probeAnswers = [false]
        let vm = try manager.create(macConfig("mac"))
        await assertEventually("\(vm.state)") { if case .failed = vm.state { return true } else { return false } }
        if case .failed(let why) = vm.state { XCTAssertTrue(why.contains("first start"), why) }
        XCTAssertEqual(factory.machine.forceStops, 1)
        XCTAssertTrue(manager.existing("mac")?.isFailed ?? false, "listed as failed, with why")
    }

    /// Full disk access that cannot be given leaves a working VM (only
    /// protected folders stay closed to its sessions).
    func testAMacOSVMIsMadeEvenIfFullDiskAccessCannotBeGiven() async throws {
        let bin = TempDir()
        defer { withExtendedLifetime(bin) {} }
        let guestd = bin.url.appendingPathComponent("MonadHost")
        try Data("binary".utf8).write(to: guestd)
        fixture = try ManagerFixture {
            $0.macInstaller = FakeMacInstaller()
            $0.allowsMacGuests = true
            $0.macSetup = FakeMacSetup()
            $0.guestdBinary = guestd
        }
        runner.setHandler { call in
            if call.executable == "/usr/bin/hdiutil" { return .fail(1, "hdiutil: attach failed - Resource busy") }
            if call.executable == "/usr/bin/ssh-keygen", let i = call.arguments.firstIndex(of: "-f") {
                try Data("PRIVATE".utf8).write(to: URL(fileURLWithPath: call.arguments[i + 1]))
                try Data("ssh-ed25519 AAAATEST monad-test\n".utf8).write(to: URL(fileURLWithPath: call.arguments[i + 1] + ".pub"))
            }
            return .ok()
        }
        let vm = try manager.create(macConfig("mac"))
        await assertEventually("\(vm.state)") { vm.state == .stopped }
        XCTAssertNotNil(manager.existing("mac"))
    }

    /// The user says no (or the step fails): the VM is not made.
    func testAMacOSVMWhoseSetupIsRefusedGoes() async throws {
        let setup = FakeMacSetup()
        setup.error = MonadError("You chose not to finish setting it up.")
        let bin = TempDir()
        defer { withExtendedLifetime(bin) {} }
        let guestd = bin.url.appendingPathComponent("MonadHost")
        try Data("binary".utf8).write(to: guestd)
        fixture = try ManagerFixture {
            $0.macInstaller = FakeMacInstaller()
            $0.allowsMacGuests = true
            $0.macSetup = setup
            $0.guestdBinary = guestd
        }
        let vm = try manager.create(macConfig("mac"))
        await assertEventually { vm.isFailed }
        if case .failed(let why) = vm.state { XCTAssertTrue(why.contains("chose not"), why) } else { XCTFail("\(vm.state)") }
    }

    /// Installed but not yet set up (its account and Monad's way in): a
    /// start says so at once instead of waiting out the boot deadline.
    func testAMacOSVMNotSetUpDoesNotStart() async throws {
        let bin = TempDir()
        defer { withExtendedLifetime(bin) {} }
        let guestd = bin.url.appendingPathComponent("MonadHost")
        try Data("binary".utf8).write(to: guestd)
        fixture = try ManagerFixture {
            $0.macInstaller = FakeMacInstaller()
            $0.allowsMacGuests = true
            $0.macSetup = FakeMacSetup()
            $0.guestdBinary = guestd
        }
        let vm = try manager.create(macConfig("mac"))
        await assertEventually { vm.state == .stopped }
        try FileManager.default.removeItem(at: vm.paths.macSetupDone)
        let made = factory.made.count
        vm.start()
        if case .failed(let why) = vm.state { XCTAssertTrue(why.contains("set up"), why) } else { XCTFail("\(vm.state)") }
        XCTAssertEqual(factory.made.count, made, "nothing was booted")
    }

    /// Where macOS VMs are not enabled, one is refused and nothing is left.
    func testMacOSIsRefusedWhereItIsNotEnabled() async throws {
        let installer = FakeMacInstaller()
        fixture = try ManagerFixture { $0.macInstaller = installer }
        let vm = try manager.create(macConfig("mac"))
        await assertEventually { vm.isFailed }
        if case .failed(let why) = vm.state { XCTAssertTrue(why.contains("macOS"), why) } else { XCTFail("\(vm.state)") }
        XCTAssertTrue(installer.installs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vm.paths.disk.path))
    }

    /// macOS needs far more room than a Linux disk: without it the install
    /// is not started (it failed near its end, as Apple's "failed to install
    /// splat"), and the VM says so in plain words.
    func testMacOSIsNotInstalledWithoutRoomForIt() async throws {
        let installer = FakeMacInstaller()
        fixture = try ManagerFixture { $0.macInstaller = installer; $0.allowsMacGuests = true }
        let manager = VMManager(root: root, environment: fixture.env, images: images,
                                minimumFreeBytes: 0, macMinimumFreeBytes: 1 << 50)
        let vm = try manager.create(macConfig("mac"))
        await assertEventually { vm.isFailed }
        if case .failed(let why) = vm.state {
            XCTAssertTrue(why.hasPrefix("macOS needs about"), why)
            XCTAssertTrue(why.contains("GB free"), why)
        } else {
            XCTFail("\(vm.state)")
        }
        XCTAssertTrue(installer.installs.isEmpty, "nothing was installed")
    }

    /// An install that fails says why: the VM stays listed as failed, with
    /// its log, its large files gone, until it is deleted or made again.
    func testAFailedInstallLeavesNothing() async throws {
        let installer = FakeMacInstaller()
        installer.error = TestError("the restore image is damaged")
        fixture = try ManagerFixture { $0.macInstaller = installer; $0.allowsMacGuests = true }
        let vm = try manager.create(macConfig("mac"))
        await assertEventually { vm.isFailed }
        if case .failed(let why) = vm.state { XCTAssertTrue(why.contains("damaged"), why) } else { XCTFail("\(vm.state)") }
        XCTAssertTrue(manager.existing("mac") === vm, "listed, saying why")
        let fm = FileManager.default
        for file in [vm.paths.disk, vm.paths.auxStorage, vm.paths.hardwareModel, vm.paths.macMachineID, vm.paths.config] {
            XCTAssertFalse(fm.fileExists(atPath: file.path), file.lastPathComponent)
        }
        vm.log.flush()
        let log = (try? String(contentsOf: vm.paths.vmLog, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("creating the VM failed: Installing macOS failed") || log.contains("damaged"), log)
        try await manager.delete(vm)
        XCTAssertNil(manager.existing("mac"))
        XCTAssertFalse(fm.fileExists(atPath: vm.paths.dir.path))
    }

    func testProvisioningWritesOnlyInsideInjectedRoot() async throws {
        let vm = try await createdVM("unit")
        XCTAssertEqual(vm.state, .stopped)
        let files = tmp.files()
        for expected in ["instances/unit/instance.json", "instances/unit/disk.raw", "instances/unit/cidata.iso",
                         "instances/unit/ssh.config", "instances/unit/id_ed25519", "instances/unit/id_ed25519.pub"] {
            XCTAssertTrue(files.contains(expected), "missing \(expected) in \(files)")
        }
        // order.json: the VMs' order (VMOrder), beside the VMs.
        XCTAssertTrue(files.allSatisfy { $0 == "base.raw" || $0 == "instances/order.json" || $0.hasPrefix("instances/unit/") },
                      "\(files)")
    }

    /// A Lima VM is used where it is: no image, no copy of the disk, Lima's
    /// files untouched; listed again after a restart; removing it from
    /// Monad leaves the Lima VM (Phase 9).
    func testALimaVMIsUsedWhereItIs() async throws {
        let fm = FileManager.default
        let lima = tmp.url.appendingPathComponent("lima/default")
        try fm.createDirectory(at: lima, withIntermediateDirectories: true)
        try "vmType: vz\n".write(to: lima.appendingPathComponent("lima.yaml"), atomically: true, encoding: .utf8)
        let original = Data(repeating: 0xAB, count: 1 << 20)
        try original.write(to: lima.appendingPathComponent("diffdisk"))
        var cfg = InstanceConfig.defaults(name: "limavm")
        cfg.attached = AttachedDisk(lima: "default", dir: lima.path)
        _ = try manager.create(cfg)
        let vm = try await createdVM("limavm")
        XCTAssertEqual(vm.state, .stopped)
        XCTAssertEqual(images.requests, 0, "no image is fetched")
        XCTAssertFalse(fm.fileExists(atPath: vm.paths.disk.path), "the disk is not copied")
        XCTAssertTrue(fm.fileExists(atPath: vm.paths.seed.path))
        XCTAssertEqual(try Data(contentsOf: lima.appendingPathComponent("diffdisk")), original, "Lima's disk is untouched")
        XCTAssertEqual(vm.config.image, "Lima VM “default”")

        let env = VMEnvironment(runner: runner, machines: factory, clock: TestClock(), virtualizationSupported: true,
                                networks: FakeNetworkAttacher())
        let fresh = VMManager(root: root, environment: env, images: images, minimumFreeBytes: 0, macMinimumFreeBytes: 0)
        fresh.load()
        let again = try XCTUnwrap(fresh.existing("limavm"), "listed again after MonadHost restarts")
        XCTAssertEqual(again.state, .stopped)

        try await manager.delete(vm)
        XCTAssertFalse(fm.fileExists(atPath: vm.paths.dir.path))
        XCTAssertEqual(try Data(contentsOf: lima.appendingPathComponent("diffdisk")), original, "the Lima VM stays")
        XCTAssertTrue(fm.fileExists(atPath: lima.appendingPathComponent("lima.yaml").path))
    }

    /// Two Monad VMs on one Lima disk could run at once and corrupt it: a
    /// Lima VM is in Monad once, however its folder is named.
    func testALimaVMIsInMonadOnlyOnce() throws {
        let fm = FileManager.default
        let lima = tmp.url.appendingPathComponent("lima/default")
        try fm.createDirectory(at: lima, withIntermediateDirectories: true)
        try "vmType: vz\n".write(to: lima.appendingPathComponent("lima.yaml"), atomically: true, encoding: .utf8)
        try Data(count: 4096).write(to: lima.appendingPathComponent("diffdisk"))
        var cfg = InstanceConfig.defaults(name: "first")
        cfg.attached = AttachedDisk(lima: "default", dir: lima.path)
        _ = try manager.create(cfg)
        cfg.name = "second"
        XCTAssertThrowsError(try manager.create(cfg)) {
            XCTAssertEqual(($0 as? MonadError)?.message, "The Lima VM “default” is already in Monad as “first”.")
        }
        let alias = tmp.url.appendingPathComponent("alias")
        try fm.createDirectory(at: alias, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: alias.appendingPathComponent("default"), withDestinationURL: lima)
        cfg.attached = AttachedDisk(lima: "default", dir: alias.appendingPathComponent("default").path)
        XCTAssertThrowsError(try manager.create(cfg), "the same folder through a link")
        XCTAssertNil(manager.existing("second"))
    }

    /// "Copy to Monad": the Lima VM's disk becomes a VM of Monad's own (an
    /// APFS clone where it can be); the Lima VM is left as it is.
    func testALimaVMIsCopiedIntoMonad() async throws {
        let fm = FileManager.default
        let lima = try limaFolder("default")
        let original = Data(repeating: 0xAB, count: 1 << 20)
        try original.write(to: lima.appendingPathComponent("diffdisk"))
        try fm.createSymbolicLink(atPath: lima.appendingPathComponent("disk").path, withDestinationPath: "diffdisk")
        var cfg = InstanceConfig.defaults(name: "default-copy")
        cfg.copiedFrom = AttachedDisk(lima: "default", dir: lima.path, home: "/home/dev.guest")
        cfg.diskGiB = 1
        _ = try manager.create(cfg)
        let vm = try await createdVM("default-copy")
        XCTAssertEqual(vm.state, .stopped)
        XCTAssertEqual(images.requests, 0, "no image")
        let type = try fm.attributesOfItem(atPath: vm.paths.disk.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeRegular, "the disk itself, not Lima's link to it")
        XCTAssertEqual(try Data(contentsOf: vm.paths.disk), original)
        XCTAssertEqual(vm.config.disk(in: vm.paths), vm.paths.disk, "it boots its own disk")
        XCTAssertEqual(vm.config.image, "Copy of Lima VM “default”")
        try Data([1]).write(to: vm.paths.disk)
        XCTAssertEqual(try Data(contentsOf: lima.appendingPathComponent("diffdisk")), original, "the copy is apart")
        try await manager.delete(vm)
        XCTAssertTrue(fm.fileExists(atPath: lima.appendingPathComponent("diffdisk").path), "the Lima VM stays")
    }

    /// A disk is copied only while nothing writes to it: not while Lima runs it.
    func testALimaVMIsNotCopiedWhileLimaRunsIt() async throws {
        let lima = try limaFolder("busy")
        try Data(count: 4096).write(to: lima.appendingPathComponent("disk"))
        try "\(getpid())\n".write(to: lima.appendingPathComponent("ha.pid"), atomically: true, encoding: .utf8)
        var cfg = InstanceConfig.defaults(name: "busy-copy")
        cfg.copiedFrom = AttachedDisk(lima: "busy", dir: lima.path)
        let vm = try manager.create(cfg)
        await assertEventually { vm.isFailed }
        XCTAssertEqual(vm.state, .failed("Lima is running “busy”. Stop it first with limactl stop busy."))
        XCTAssertTrue(manager.existing("busy-copy")?.isFailed ?? false)
    }

    private func limaFolder(_ name: String) throws -> URL {
        let dir = tmp.url.appendingPathComponent("lima/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "vmType: vz\n".write(to: dir.appendingPathComponent("lima.yaml"), atomically: true, encoding: .utf8)
        return dir
    }

    /// A Lima VM removed in Lima is listed with why it cannot start.
    func testALimaVMGoneFromLimaIsListedAsFailed() async throws {
        let fm = FileManager.default
        let lima = tmp.url.appendingPathComponent("lima/gone")
        try fm.createDirectory(at: lima, withIntermediateDirectories: true)
        try "vmType: vz\n".write(to: lima.appendingPathComponent("lima.yaml"), atomically: true, encoding: .utf8)
        try Data(count: 4096).write(to: lima.appendingPathComponent("diffdisk"))
        var cfg = InstanceConfig.defaults(name: "gonevm")
        cfg.attached = AttachedDisk(lima: "gone", dir: lima.path)
        _ = try manager.create(cfg)
        _ = try await createdVM("gonevm")
        try fm.removeItem(at: lima)
        let env = VMEnvironment(runner: runner, machines: factory, clock: TestClock(), virtualizationSupported: true,
                                networks: FakeNetworkAttacher())
        let fresh = VMManager(root: root, environment: env, images: images, minimumFreeBytes: 0, macMinimumFreeBytes: 0)
        fresh.load()
        let vm = try XCTUnwrap(fresh.existing("gonevm"))
        guard case .failed(let why) = vm.state else { return XCTFail("\(vm.state)") }
        XCTAssertTrue(why.contains("gone"), why)
    }

    func testDiskIsClonedFromBaseAndGrown() async throws {
        let vm = try await createdVM("unit")
        let size = try FileManager.default.attributesOfItem(atPath: vm.paths.disk.path)[.size] as? NSNumber
        XCTAssertEqual(size?.uint64Value, UInt64(vm.config.diskGiB) << 30)
        let head = try FileHandle(forReadingFrom: vm.paths.disk).read(upToCount: 512)
        XCTAssertEqual(head?[510], 0x55, "base content copied")
    }

    func testAsksForTheConfiguredDistroAndRecordsTheRelease() async throws {
        var cfg = InstanceConfig.defaults(name: "deb")
        cfg.distro = "debian"
        _ = try manager.create(cfg)
        let vm = try await createdVM("deb")
        XCTAssertEqual(images.asked.map(\.distro), ["debian"])
        XCTAssertEqual(images.asked.first?.release, nil, "no release chosen: the distro's default")
        XCTAssertEqual(vm.config.release, "1.0")
        XCTAssertEqual(try InstanceConfig.load(from: vm.paths.config).release, "1.0")
    }

    /// A distro this Monad does not know (a VM service from an older Monad,
    /// a file removed meanwhile) is refused when the VM is made, so the New
    /// VM sheet says so instead of a tab on a VM that is gone.
    func testUnknownDistroIsRefusedAtOnceAndLeavesNothing() async throws {
        var cfg = InstanceConfig.defaults(name: "odd")
        cfg.distro = "plan9"
        XCTAssertThrowsError(try manager.create(cfg)) {
            XCTAssertEqual($0.localizedDescription, "This Monad does not know the distribution plan9.")
        }
        XCTAssertNil(manager.existing("odd"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.paths(for: "odd").dir.path))
    }

    func testRecordsImageNameAndUsesGeneratedKeyInSeed() async throws {
        let vm = try await createdVM("unit")
        XCTAssertEqual(vm.config.image, "Fake Linux 1.0")
        XCTAssertEqual(try InstanceConfig.load(from: vm.paths.config).image, "Fake Linux 1.0")
        let seed = try Data(contentsOf: vm.paths.seed)
        XCTAssertNotNil(seed.range(of: Data("ssh-ed25519 AAAATEST monad-test".utf8)))
        let keygen = try XCTUnwrap(runner.calls.first { $0.executable == "/usr/bin/ssh-keygen" })
        XCTAssertTrue(keygen.arguments.contains("ed25519"))
        XCTAssertTrue(keygen.arguments.contains(vm.paths.privateKey.path))
    }

    func testSSHConfigPointsInsideRoot() async throws {
        let vm = try await createdVM("unit")
        let cfg = try String(contentsOf: vm.paths.sshConfig, encoding: .utf8)
        XCTAssertTrue(cfg.contains(vm.paths.sshSocket.path))
        XCTAssertTrue(vm.paths.sshSocket.path.hasPrefix(root.path))
    }

    /// A VM that could not be made stays listed with why and its log; made
    /// again by name (a tab on it, or New VM) it is tried afresh.
    func testAVMThatCouldNotBeMadeIsListedAndMadeAgain() async throws {
        images.error = TestError("offline")
        let vm = manager.instance(named: "unit")
        await assertEventually { vm.isFailed }
        XCTAssertTrue(manager.existing("unit") === vm)
        let left = try FileManager.default.contentsOfDirectory(atPath: vm.paths.dir.path)
        XCTAssertEqual(left.filter { !$0.hasPrefix("vm.log") }, [], "only its log is kept")
        images.error = nil
        let again = manager.instance(named: "unit")
        XCTAssertFalse(again === vm, "made afresh")
        await assertEventually("\(again.state)") { again.state == .stopped }
        XCTAssertTrue(manager.existing("unit") === again)
        let other = try manager.create(InstanceConfig.defaults(name: "unit-2"))
        await assertEventually { other.state == .stopped }
        images.error = TestError("offline")
        let failed = try manager.create(InstanceConfig.defaults(name: "unit-3"))
        await assertEventually { failed.isFailed }
        images.error = nil
        let remade = try manager.create(InstanceConfig.defaults(name: "unit-3"))
        await assertEventually { remade.state == .stopped }
    }

    /// A VM that could not be made stays listed while MonadHost runs; one
    /// started again cleans up what it left (its log only).
    func testWhatAFailedVMLeftIsCleanedUpAfterARestart() async throws {
        images.error = TestError("offline")
        let vm = manager.instance(named: "unit")
        await assertEventually { vm.isFailed }
        manager.load()
        XCTAssertTrue(manager.existing("unit") === vm, "still listed")
        let restarted = fixture.makeManager()
        restarted.load()
        XCTAssertNil(restarted.existing("unit"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vm.paths.dir.path))
    }

    /// A VM still running when MonadHost ended (killed, crashed, the Mac
    /// lost power) was powered off without a shutdown, which can damage its
    /// disk: the next MonadHost says so in its log, once.
    func testAVMLeftRunningWhenMonadHostEndedIsNoted() async throws {
        let vm = try await createdVM("unit")
        manager.start(vm)
        await assertEventually { vm.state == .ready }
        // This MonadHost ends here, never seeing the VM stop.
        let restarted = fixture.makeManager()
        restarted.load()
        let again = try XCTUnwrap(restarted.existing("unit"))
        again.log.flush()
        let log = try String(contentsOf: again.paths.vmLog, encoding: .utf8)
        XCTAssertTrue(log.contains("MonadHost ended while this VM was running (its machine started "), log)
        XCTAssertTrue(log.contains("it was powered off without a shutdown, which can damage its disk"), log)
        XCTAssertFalse(FileManager.default.fileExists(atPath: again.paths.runningMark.path))
        let third = fixture.makeManager()
        third.load()
        third.flushLogs()
        let after = try String(contentsOf: again.paths.vmLog, encoding: .utf8)
        XCTAssertEqual(after.components(separatedBy: "MonadHost ended while").count, 2, "said once")
    }

    /// MonadHost quitting (launchd's SIGTERM at a logout or restart) says so
    /// in each running VM's log before it shuts the VM down, and every log is
    /// written out before it exits.
    func testQuittingSaysWhyInEachRunningVMsLog() async throws {
        let vm = try await createdVM("unit")
        let idle = try await createdVM("idle")
        manager.start(vm)
        await assertEventually { vm.state == .ready }
        await manager.stopAll(because: "MonadHost is quitting")
        manager.flushLogs()
        let log = try String(contentsOf: vm.paths.vmLog, encoding: .utf8)
        let why = try XCTUnwrap(log.range(of: "MonadHost is quitting: shutting the VM down"), log)
        let asked = try XCTUnwrap(log.range(of: "stop: asking the guest to shut down"), log)
        XCTAssertLessThan(why.lowerBound, asked.lowerBound)
        XCTAssertFalse(((try? String(contentsOf: idle.paths.vmLog, encoding: .utf8)) ?? "").contains("quitting"),
                       "a VM that was not running has nothing to say")
    }

    /// Settings › Virtual Machines › Full boot messages: the VMs running
    /// now get the change at once, so their next boot shows it; the others
    /// get it from the installer when they boot.
    func testChangedBootMessagesReachTheRunningVMs() async throws {
        var messages = BootMessages.quiet
        fixture = try ManagerFixture { $0.bootMessages = { messages } }
        let vm = try await createdVM("unit")
        _ = try await createdVM("idle")
        manager.start(vm)
        await assertEventually { vm.state == .ready }
        messages = .full
        manager.bootMessagesChanged()
        await assertEventually { self.runner.calls.contains { $0.arguments.last == CloudInit.bootMessagesCommand(.full) } }
        let sent = runner.calls.filter { $0.arguments.last == CloudInit.bootMessagesCommand(.full) }
        XCTAssertEqual(sent.count, 1, "only the running VM")
        XCTAssertTrue(sent.first?.arguments.contains(vm.sshHost) == true)
    }

    func testAFailedEphemeralVMLeavesNothing() async throws {
        images.error = TestError("offline")
        let vm = manager.createEphemeral()
        await assertEventually { vm.isFailed }
        XCTAssertNil(manager.existing(vm.name))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vm.paths.dir.path))
    }

    func testIncompleteLeftoverIsReplaced() async throws {
        let leftover = root.appendingPathComponent("unit")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: leftover.appendingPathComponent("disk.raw"))
        let vm = try await createdVM("unit")
        XCTAssertEqual(vm.state, .stopped)
        let head = try FileHandle(forReadingFrom: vm.paths.disk).read(upToCount: 5)
        XCTAssertNotEqual(head, Data("stale".utf8))
    }

    func testConcurrentRequestsShareOneProvisioning() async throws {
        let a = manager.instance(named: "unit")
        let b = manager.instance(named: "unit")
        XCTAssertTrue(a === b)
        _ = await eventually { a.state == .stopped }
        XCTAssertEqual(images.requests, 1)
    }

    func testLoadFindsExistingInstancesAndDropsEphemeralLeftovers() async throws {
        _ = try await createdVM("keep")
        var eph = InstanceConfig.defaults(name: "tmp-1", ephemeral: true)
        eph.image = "x"
        let ephPaths = InstancePaths(name: "tmp-1", root: root)
        try FileManager.default.createDirectory(at: ephPaths.dir, withIntermediateDirectories: true)
        try eph.save(to: ephPaths.config)
        FileManager.default.createFile(atPath: ephPaths.disk.path, contents: Data())

        let env = VMEnvironment(runner: runner, machines: factory, clock: TestClock(), virtualizationSupported: true,
                                networks: FakeNetworkAttacher())
        let fresh = VMManager(root: root, environment: env, images: images, minimumFreeBytes: 0, macMinimumFreeBytes: 0)
        fresh.load()
        XCTAssertEqual(fresh.instances.map(\.name), ["keep"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ephPaths.dir.path))
    }

    /// instance.json is checked when loaded, as on create and update (F-09):
    /// a file changed outside Monad does not get past the rules. The VM stays
    /// listed, failed with the reason, and does not start.
    func testATamperedConfigIsRefusedAtLoad() async throws {
        let vm = try await createdVM("keep")
        let bad: [(String, (inout InstanceConfig) -> Void)] = [
            ("user", { $0.user = "dev\n  ProxyCommand touch /tmp/x" }),
            ("share", {
                $0.sharing = SharingSettings(runtimeEnabled: true,
                                             shares: [SharedFolder(hostPath: "relative", guestPath: "/mnt/a", readOnly: true)])
            }),
            ("writable share holding ~/.monad", {
                $0.sharing = SharingSettings(runtimeEnabled: true,
                                             shares: [SharedFolder(hostPath: "/", guestPath: "/mnt/a", readOnly: false)])
            }),
        ]
        for (what, edit) in bad {
            var c = vm.config
            edit(&c)
            try c.save(to: vm.paths.config)
            let env = VMEnvironment(runner: runner, machines: factory, clock: TestClock(), virtualizationSupported: true,
                                    networks: FakeNetworkAttacher())
            let fresh = VMManager(root: root, environment: env, images: images, minimumFreeBytes: 0, macMinimumFreeBytes: 0)
            fresh.load()
            let loaded = try XCTUnwrap(fresh.existing("keep"), what)
            guard case .failed(let why) = loaded.state else { return XCTFail("\(what): \(loaded.state)") }
            XCTAssertTrue(why.contains("instance.json"), why)
            let starts = factory.machine.started
            loaded.start()
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(factory.machine.started, starts, "\(what): not started")
            XCTAssertTrue(loaded.isFailed)
        }
    }

    func testCreateRejectsInvalidAndDuplicateNames() async throws {
        XCTAssertThrowsError(try manager.create(.defaults(name: "Bad Name")))
        _ = try await createdVM("unit")
        XCTAssertThrowsError(try manager.create(.defaults(name: "unit")))
        // The Mac's disk does not tell "Unit" from "unit": one folder, one VM.
        XCTAssertThrowsError(try manager.create(.defaults(name: "Unit"))) { error in
            XCTAssertEqual(error.localizedDescription, "A VM named unit already exists.")
        }
        XCTAssertTrue(manager.isNameTaken("UNIT"))
        XCTAssertFalse(manager.isNameTaken("Other"))
    }

    func testEphemeralVMIsDeletedWhenLastSessionCloses() async throws {
        let vm = manager.createEphemeral()
        _ = await eventually { vm.state == .stopped || vm.state == .ready }
        manager.retain(vm)
        manager.retain(vm)
        manager.release(vm)
        XCTAssertNotNil(manager.existing(vm.name))
        manager.release(vm)
        await assertEventually { self.manager.existing(vm.name) == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: vm.paths.dir.path))
    }
}
