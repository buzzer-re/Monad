//
//  DiskRepair.swift — Repair Disk: a stopped Linux VM's disk checked, and
//  repaired where they can, by its own distribution's tools (e2fsck,
//  fsck.vfat, xfs_repair, btrfs) in a temporary VM of that distribution.
//  The disk reaches that VM only once it runs (a USB disk, macOS 15): made
//  from the same cloud image, it carries the same labels and UUIDs, which
//  at boot could make the temporary VM mount it as its own. A copy of the
//  disk as it was is kept first (an APFS clone, free until they differ).
//

import Foundation

enum DiskRepair {
    /// The disk the guest did not have before: its block devices then and
    /// now (`ls /sys/block`). Plain disk names only.
    static func newDisk(before: String, after: String) -> String? {
        let old = Set(disks(before))
        return disks(after).first { !old.contains($0) }
    }

    private static func disks(_ listing: String) -> [String] {
        listing.split(whereSeparator: \.isNewline).map(String.init)
            .filter { $0.range(of: "^(sd|vd)[a-z]{1,3}$", options: .regularExpression) != nil }
    }

    /// Partition `number` of the disk `name` (/dev/sda1); 0 is the disk itself.
    static func device(_ name: String, partition number: Int) -> String {
        "/dev/" + name + (number > 0 ? String(number) : "")
    }

    /// One filesystem's check, as root: the first run (from a backup copy
    /// when only that is intact), the one repeated while it still changes
    /// things, and a read-only check at the end.
    struct Check: Equatable {
        var partition: DiskReport.Partition
        var tool: String
        var first: String
        var again: String
        var verify: String
    }

    /// Every filesystem Monad knows a tool for. An XFS log is never thrown
    /// away (no xfs_repair -L) and btrfs is only checked: its "repair" can
    /// make things worse; a damaged main superblock is put back from its mirror.
    static func checks(_ report: DiskReport, disk name: String) -> [Check] {
        report.partitions.compactMap { p in
            let dev = device(name, partition: p.number)
            switch p.filesystem {
            case .ext:
                let backup = !p.intact && p.backupIntact && p.backupBlock > 0 ? " -b \(p.backupBlock) -B \(p.blockSize)" : ""
                return Check(partition: p, tool: "e2fsck", first: "e2fsck -f -y\(backup) \(dev)",
                             again: "e2fsck -f -y \(dev)", verify: "e2fsck -f -n \(dev)")
            case .fat:
                return Check(partition: p, tool: "fsck.vfat", first: "fsck.vfat -a -w \(dev)",
                             again: "fsck.vfat -a -w \(dev)", verify: "fsck.vfat -n \(dev)")
            case .xfs:
                return Check(partition: p, tool: "xfs_repair", first: "xfs_repair \(dev)",
                             again: "xfs_repair \(dev)", verify: "xfs_repair -n \(dev)")
            case .btrfs:
                return Check(partition: p, tool: "btrfs",
                             first: p.intact ? "btrfs check --readonly \(dev)" : "btrfs rescue super-recover -y \(dev)",
                             again: "btrfs check --readonly \(dev)", verify: "btrfs check --readonly \(dev)")
            case .unknown, .swap, .lvm, .luks:
                return nil
            }
        }
    }

    struct Outcome: Equatable {
        enum Result: Equatable { case clean, repaired, stillDamaged, noTool }
        var check: Check
        var result: Result
        var fixed: Bool { result == .clean || result == .repaired }
    }

    /// What Repair Disk did, in a few sentences.
    static func summary(_ outcomes: [Outcome], keptAs copy: String) -> String {
        let kept = "The disk as it was before is kept as \(copy) in the VM's folder."
        guard !outcomes.isEmpty else { return "Repair Disk found no filesystem on this disk it can check. " + kept }
        func list(_ items: [String]) -> String {
            items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
        func of(_ result: Outcome.Result) -> [Outcome] { outcomes.filter { $0.result == result } }
        var said: [String] = []
        func say(_ first: String, _ then: String, _ rest: String) { said.append((said.isEmpty ? first : then) + rest) }
        let repaired = of(.repaired).map { "\($0.check.partition.called) (\($0.check.tool))" }
        if !repaired.isEmpty { say("Repair Disk repaired ", "It repaired ", list(repaired) + ".") }
        let clean = of(.clean).map(\.check.partition.called)
        if !clean.isEmpty { say("Repair Disk found ", "It found ", list(clean) + " clean.") }
        let damaged = of(.stillDamaged).map { "\($0.check.partition.called) (\($0.check.tool) still finds problems)" }
        if !damaged.isEmpty { say("Repair Disk could not fix ", "It could not fix ", list(damaged) + "; the VM's log has what it said.") }
        for o in of(.noTool) {
            say("Repair Disk could not check ", "It could not check ",
                "\(o.check.partition.called): this distribution's image has no \(o.check.tool).")
        }
        return (said + [kept]).joined(separator: " ")
    }
}

extension VMManager {
    /// Why Repair Disk cannot run on `vm` now; nil when it can.
    func repairProblem(_ vm: VMInstance) -> String? {
        if !env.disksAttachWhileRunning {
            return "Repair Disk needs macOS 15 or later: it attaches the disk to a temporary VM while that VM runs."
        }
        if vm.config.guestOS != .linux { return "Repair Disk works on Linux VMs." }
        if vm.config.attached != nil { return "\(vm.name)'s disk is Lima's: check it from Lima, or copy the VM into Monad." }
        if vm.config.ephemeral { return "An ephemeral VM's disk goes with it." }
        if vm.isRepairing { return "\(vm.name)'s disk is being repaired already." }
        if vm.isRunning || vm.state.isPreparing { return "Stop \(vm.name) first: its disk is in use while it runs." }
        if !FileManager.default.fileExists(atPath: vm.paths.disk.path) { return "\(vm.name) has no disk." }
        return nil
    }

    /// Repair Disk on the stopped Linux VM `vm`: what it did, in a few
    /// sentences (also in the VM's log, with every tool's output). The VM is
    /// stopped afterwards, or failed with what is left.
    func repairDisk(_ vm: VMInstance) async throws -> String {
        if let why = repairProblem(vm) { throw MonadError(why) }
        let disk = vm.paths.disk, copy = vm.paths.diskBeforeRepair
        vm.beginRepair("Repairing its disk: keeping a copy of it")
        var helper: VMInstance?
        do {
            try? FileManager.default.removeItem(at: copy)
            let rc = await Task.detached { mnd_disk_clone(disk.path, copy.path) }.value
            if rc != 0 { throw MonadError.posix(rc, "Cannot keep a copy of the disk") }
            let before = await Task.detached { DiskReport.check(disk: disk) }.value
            vm.note("repair: the disk before: \(before?.logLine ?? "could not be read")")

            vm.repairStep("Repairing its disk: starting a temporary \(vm.config.distro) VM")
            let h = makeRepairHelper(for: vm)
            helper = h
            guard await settle(seconds: 3600, { !h.state.isPreparing }), !h.isFailed else {
                throw MonadError("The temporary VM could not be made: \(h.state.label)")
            }
            start(h)
            guard await settle(seconds: VMInstance.bootTimeout + 60, { h.state == .ready || h.isFailed }), h.state == .ready else {
                throw MonadError("The temporary VM did not start: \(h.state.label)")
            }
            let blocks = try await h.guestRun("ls /sys/block", timeout: 30).stdoutString
            vm.repairStep("Repairing its disk: attaching it to the temporary VM")
            try await h.attachDisk(disk)
            var name: String?
            for _ in 0..<30 {
                name = DiskRepair.newDisk(before: blocks, after: (try? await h.guestRun("ls /sys/block", timeout: 30))?.stdoutString ?? "")
                if name != nil { break }
                await env.clock.sleep(seconds: 1)
            }
            guard let name else { throw MonadError("The temporary VM did not see the disk.") }

            var outcomes: [DiskRepair.Outcome] = []
            for check in DiskRepair.checks(before ?? DiskReport(table: .none, partitions: []), disk: name) {
                vm.repairStep("Repairing its disk: \(check.tool) on \(check.partition.called)")
                outcomes.append(await run(check, in: h, for: vm))
            }
            _ = try? await h.guestRun("sync", timeout: 60)
            try? await h.detachDisk()
            await dropRepairHelper(h)
            helper = nil

            let after = await Task.detached { DiskReport.check(disk: disk) }.value
            vm.note("repair: the disk after: \(after?.logLine ?? "could not be read")")
            let summary = DiskRepair.summary(outcomes, keptAs: copy.lastPathComponent)
            vm.note("repair: " + summary)
            vm.endRepair(failure: !outcomes.isEmpty && outcomes.allSatisfy(\.fixed) ? nil : summary)
            return summary
        } catch {
            if let h = helper {
                try? await h.detachDisk()
                await dropRepairHelper(h)
            }
            let why = "Repair Disk stopped: \(error.localizedDescription)"
                + (FileManager.default.fileExists(atPath: copy.path) ? " The disk as it was before is kept as \(copy.lastPathComponent)." : "")
            vm.note("repair: " + why)
            vm.endRepair(failure: why)
            throw MonadError(why)
        }
    }

    /// A temporary VM of `vm`'s distribution and release, whose machine
    /// takes a disk while it runs. Ephemeral: gone after, and after a crash.
    private func makeRepairHelper(for vm: VMInstance) -> VMInstance {
        var name: String
        repeat {
            name = "repair-" + String(UUID().uuidString.prefix(6)).lowercased()
        } while isNameTaken(name)
        var config = InstanceConfig.defaults(name: name, ephemeral: true)
        config.distro = vm.config.distro
        config.release = vm.config.release
        config.cpus = 2
        config.memoryGiB = 2
        let helper = instance(named: name, config: config)
        helper.takesDisks = true
        return helper
    }

    private func dropRepairHelper(_ helper: VMInstance) async {
        await helper.forceStop()
        try? await delete(helper)
    }

    /// Until `done`, at most `seconds`; whether it came.
    private func settle(seconds: TimeInterval, _ done: () -> Bool) async -> Bool {
        let deadline = env.clock.now().addingTimeInterval(seconds)
        while !done() {
            if env.clock.now() >= deadline || Task.isCancelled { return false }
            await env.clock.sleep(seconds: 1)
        }
        return true
    }

    /// One filesystem: its tool until it changes nothing more (three runs
    /// at most), then the read-only check decides.
    private func run(_ check: DiskRepair.Check, in helper: VMInstance, for vm: VMInstance) async -> DiskRepair.Outcome {
        func root(_ command: String) async -> ProcessRunner.Result? {
            let r = try? await helper.guestRun("sudo -n " + command, timeout: 3600)
            vm.note("repair: \(command) → " + (r.map { "status \($0.status)" + DebugLog.output($0) } ?? "no answer"))
            return r
        }
        guard var r = await root(check.first) else { return .init(check: check, result: .stillDamaged) }
        if r.stderrString.contains("command not found") { return .init(check: check, result: .noTool) }
        let changed = r.status != 0
        var runs = 1
        while r.status != 0, runs < 3, let again = await root(check.again) {
            r = again
            runs += 1
        }
        guard let verify = await root(check.verify), verify.status == 0 else { return .init(check: check, result: .stillDamaged) }
        return .init(check: check, result: changed ? .repaired : .clean)
    }
}
