//
//  DiskRepairTests.swift — Repair Disk: a stopped Linux VM's disk checked by
//  its own distribution's tools in a temporary VM, against fakes (machines,
//  ssh, images); the real disk check reads the test's disk file.
//

import XCTest
@testable import Monad

@MainActor
final class DiskRepairTests: XCTestCase {
    private var fixture: ManagerFixture!
    private var manager: VMManager { fixture.manager }
    private var factory: FakeMachineFactory { fixture.factory }

    override func setUp() async throws {
        fixture = try ManagerFixture { $0.disksAttachWhileRunning = true }
    }

    private func createdVM(_ name: String) async throws -> VMInstance {
        let vm = manager.instance(named: name)
        _ = await eventually { if case .preparing = vm.state { return false } else { return true } }
        return try XCTUnwrap(manager.existing(name), "provisioning \(name) failed: \(vm.state)")
    }

    private func log(_ vm: VMInstance) -> String {
        vm.log.flush()
        return (try? String(contentsOf: vm.paths.vmLog, encoding: .utf8)) ?? ""
    }

    /// The guest's side: its block devices (the disk appears once attached)
    /// and each check's status, in order; the commands Monad ran there.
    private final class Guest: @unchecked Sendable {
        private let lock = NSLock()
        private var attached = false
        var statuses: [String: [Int32]] = [:]
        var stderr: [String: String] = [:]
        var onRun: [String: () -> Void] = [:]
        private var all: [String] = []
        /// What the repair ran (the temporary VM's own boot steps left out).
        var ran: [String] { lock.withLock { all.filter { $0.hasPrefix("sudo -n e2fsck") || $0 == "sync" } } }

        func attach() { lock.withLock { attached = true } }

        func answer(_ remote: String) -> ProcessRunner.Result {
            lock.withLock {
                if remote == "ls /sys/block" { return .ok(attached ? "loop0\nsda\nvda\nvdb\n" : "loop0\nvda\nvdb\n") }
                all.append(remote)
                onRun[remote]?()
                guard var queue = statuses[remote], !queue.isEmpty else { return .ok() }
                let status = queue.count > 1 ? queue.removeFirst() : queue[0]
                statuses[remote] = queue
                return ProcessRunner.Result(status: status, stdout: Data("output of \(remote)\n".utf8),
                                            stderr: Data((stderr[remote] ?? "").utf8))
            }
        }
    }

    private func serve(_ guest: Guest) {
        fixture.runner.setHandler { call in
            if call.executable == "/usr/bin/ssh-keygen", let i = call.arguments.firstIndex(of: "-f") {
                let key = call.arguments[i + 1]
                try Data("PRIVATE".utf8).write(to: URL(fileURLWithPath: key))
                try Data("ssh-ed25519 AAAATEST monad-test\n".utf8).write(to: URL(fileURLWithPath: key + ".pub"))
                return .ok()
            }
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            if call.executable == "/usr/bin/ssh", let remote = call.arguments.last, remote != "true" {
                return guest.answer(remote)
            }
            return .ok()
        }
    }

    /// The root's main superblock zeroed (as one VM's was), its backup
    /// intact: e2fsck from the backup, then again until it has nothing left
    /// to fix, then a read-only check. All in a temporary VM of the same
    /// distribution that gets the disk only once it runs, and goes after.
    func testADamagedDiskIsRepairedInATemporaryVMOfItsDistribution() async throws {
        let vm = try await createdVM("server")
        try DiskCheckTests.writeDisk(vm.paths.disk, primary: nil)
        let guest = Guest()
        serve(guest)
        guest.statuses = ["sudo -n e2fsck -f -y -b 32768 -B 4096 /dev/sda": [12], "sudo -n e2fsck -f -y /dev/sda": [1, 0]]
        let disk = vm.paths.disk
        guest.onRun["sudo -n e2fsck -f -y /dev/sda"] = {
            try? DiskCheckTests.writeDisk(disk, primary: DiskCheckTests.ext4Superblock(label: "cloudimg-rootfs"))
        }
        factory.machine.onAttach = { guest.attach() }

        let summary = try await manager.repairDisk(vm)

        let helper = try XCTUnwrap(factory.diskMachines.first, "a machine that takes a disk")
        XCTAssertEqual(helper.distro, vm.config.distro)
        XCTAssertEqual(helper.release, vm.config.release)
        XCTAssertTrue(helper.ephemeral)
        XCTAssertEqual(factory.machine.attachedDisks, [vm.paths.disk], "attached once the helper ran")
        XCTAssertEqual(factory.machine.detachedDisks, 1)
        XCTAssertEqual(guest.ran, ["sudo -n e2fsck -f -y -b 32768 -B 4096 /dev/sda", "sudo -n e2fsck -f -y /dev/sda",
                                   "sudo -n e2fsck -f -y /dev/sda", "sudo -n e2fsck -f -n /dev/sda", "sync"])
        XCTAssertNil(manager.existing(helper.name), "the temporary VM is gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: InstancePaths(name: helper.name, root: fixture.root).dir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vm.paths.diskBeforeRepair.path), "the disk as it was is kept")
        XCTAssertEqual(vm.state, .stopped)
        XCTAssertTrue(summary.hasPrefix("Repair Disk repaired the filesystem cloudimg-rootfs (e2fsck)."), summary)
        XCTAssertTrue(summary.contains("disk.before-repair.raw"), summary)
        let text = log(vm)
        XCTAssertTrue(text.contains("repair: the disk before: no partition table; the whole disk: ext, damaged superblock"), text)
        XCTAssertTrue(text.contains("repair: e2fsck -f -y -b 32768 -B 4096 /dev/sda → status 12"), text)
        XCTAssertTrue(text.contains("stdout: output of sudo -n e2fsck -f -y /dev/sda"), text)
        XCTAssertTrue(text.contains("repair: the disk after: no partition table; the whole disk: ext, intact"), text)
    }

    /// Problems e2fsck cannot fix leave the VM failed with why; the copy
    /// stays, the temporary VM still goes.
    func testWhatCouldNotBeFixedIsSaid() async throws {
        let vm = try await createdVM("server")
        try DiskCheckTests.writeDisk(vm.paths.disk, primary: nil)
        let guest = Guest()
        serve(guest)
        guest.statuses = ["sudo -n e2fsck -f -y -b 32768 -B 4096 /dev/sda": [4], "sudo -n e2fsck -f -y /dev/sda": [4],
                          "sudo -n e2fsck -f -n /dev/sda": [4]]
        factory.machine.onAttach = { guest.attach() }
        let summary = try await manager.repairDisk(vm)
        XCTAssertTrue(summary.contains("could not fix the filesystem cloudimg-rootfs (e2fsck still finds problems)"), summary)
        guard case .failed(let why) = vm.state else { return XCTFail("\(vm.state)") }
        XCTAssertEqual(why, summary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vm.paths.diskBeforeRepair.path))
        XCTAssertTrue(factory.diskMachines.allSatisfy { manager.existing($0.name) == nil })
    }

    /// A distribution without the tool: said, nothing pretended.
    func testAMissingToolIsSaid() async throws {
        let vm = try await createdVM("server")
        try DiskCheckTests.writeDisk(vm.paths.disk, primary: nil)
        let guest = Guest()
        serve(guest)
        let first = "sudo -n e2fsck -f -y -b 32768 -B 4096 /dev/sda"
        guest.statuses = [first: [1]]
        guest.stderr = [first: "sudo: e2fsck: command not found\n"]
        factory.machine.onAttach = { guest.attach() }
        let summary = try await manager.repairDisk(vm)
        XCTAssertTrue(summary.contains("could not check the filesystem cloudimg-rootfs: this distribution's image has no e2fsck"), summary)
        XCTAssertEqual(guest.ran, [first, "sync"])
    }

    func testRepairIsRefusedWhenItCannotRun() async throws {
        let vm = try await createdVM("server")
        manager.start(vm)
        await assertEventually { vm.state == .ready }
        XCTAssertEqual(manager.repairProblem(vm), "Stop server first: its disk is in use while it runs.")
        await vm.stop()
        XCTAssertNil(manager.repairProblem(vm))

        var lima = InstanceConfig.defaults(name: "lima")
        lima.attached = AttachedDisk(lima: "default", dir: "/Users/dev/.lima/default")
        XCTAssertNotNil(manager.repairProblem(VMInstance(config: lima, paths: InstancePaths(name: "lima", root: fixture.root),
                                                         environment: fixture.env, guest: .init())))

        let old = try ManagerFixture { $0.disksAttachWhileRunning = false }
        let elsewhere = old.manager.instance(named: "server")
        _ = await eventually { if case .preparing = elsewhere.state { return false } else { return true } }
        XCTAssertEqual(old.manager.repairProblem(elsewhere),
                       "Repair Disk needs macOS 15 or later: it attaches the disk to a temporary VM while that VM runs.")
        do {
            _ = try await old.manager.repairDisk(elsewhere)
            XCTFail("refused")
        } catch {}
    }

    /// While its disk is repaired the VM neither starts nor goes away.
    func testARepairedVMDoesNotStartOrGo() async throws {
        let vm = try await createdVM("server")
        try DiskCheckTests.writeDisk(vm.paths.disk, primary: nil)
        let guest = Guest()
        serve(guest)
        factory.machine.onAttach = { guest.attach() }
        let repair = Task { try await manager.repairDisk(vm) }
        await assertEventually { vm.isRepairing }
        vm.start()
        XCTAssertTrue(vm.isRepairing, "not started")
        do {
            try await manager.delete(vm)
            XCTFail("refused")
        } catch {}
        _ = try await repair.value
        XCTAssertFalse(vm.isRepairing)
    }

    // MARK: What is run

    func testTheNewDiskIsTheOneTheGuestDidNotHave() {
        XCTAssertEqual(DiskRepair.newDisk(before: "loop0\nvda\nvdb\n", after: "loop0\nsda\nvda\nvdb\n"), "sda")
        XCTAssertNil(DiskRepair.newDisk(before: "vda\n", after: "vda\n"))
        XCTAssertNil(DiskRepair.newDisk(before: "vda\n", after: "vda\nsda; rm -rf /\n"), "only plain disk names")
        XCTAssertEqual(DiskRepair.device("sda", partition: 1), "/dev/sda1")
        XCTAssertEqual(DiskRepair.device("sda", partition: 0), "/dev/sda")
    }

    /// Each filesystem with its own tool: ext from its backup when only that
    /// is intact, FAT, XFS (never zeroing its log), btrfs (a damaged main
    /// superblock put back from its mirror; checked, never "repaired");
    /// nothing for swap or what Monad does not know.
    func testEachFilesystemGetsItsOwnTool() {
        func part(_ n: Int, _ fs: DiskReport.Filesystem, intact: Bool = true, backup: Bool = false) -> DiskReport.Partition {
            DiskReport.Partition(number: n, kind: .data, name: "", filesystem: fs, intact: intact, backupIntact: backup,
                                 backupBlock: backup && fs == .ext ? 32768 : 0, blockSize: fs == .ext ? 4096 : 0,
                                 label: "p\(n)", recordedErrors: false, needsRecovery: false, lastError: nil)
        }
        let report = DiskReport(table: .intact, partitions: [part(1, .ext, intact: false, backup: true), part(13, .ext),
                                                             part(15, .fat), part(2, .xfs), part(3, .btrfs, intact: false, backup: true),
                                                             part(4, .swap), part(5, .unknown)])
        let checks = DiskRepair.checks(report, disk: "sda")
        XCTAssertEqual(checks.map(\.first), ["e2fsck -f -y -b 32768 -B 4096 /dev/sda1", "e2fsck -f -y /dev/sda13",
                                             "fsck.vfat -a -w /dev/sda15", "xfs_repair /dev/sda2",
                                             "btrfs rescue super-recover -y /dev/sda3"])
        XCTAssertEqual(checks.map(\.again), ["e2fsck -f -y /dev/sda1", "e2fsck -f -y /dev/sda13", "fsck.vfat -a -w /dev/sda15",
                                             "xfs_repair /dev/sda2", "btrfs check --readonly /dev/sda3"])
        XCTAssertEqual(checks.map(\.verify), ["e2fsck -f -n /dev/sda1", "e2fsck -f -n /dev/sda13", "fsck.vfat -n /dev/sda15",
                                              "xfs_repair -n /dev/sda2", "btrfs check --readonly /dev/sda3"])
        XCTAssertFalse(checks.contains { $0.first.contains(" -L") }, "an XFS log is never thrown away")
    }
}
