//
//  DiskCheck.swift — what a stopped Linux VM's disk looks like from outside
//  (mnd_diskcheck): its partitions, which filesystem each holds, and whether
//  its superblock is intact or only a backup copy is. Read only, and only
//  while nothing runs on the disk; said in a sentence when a boot fails, in
//  full in the VM's log.
//

import Foundation

struct DiskReport: Equatable {
    enum Table: Equatable { case none, intact, backupOnly }
    enum Kind: Equatable { case other, efi, root, boot, data, swap, lvm }
    enum Filesystem: String, Equatable { case unknown, ext, xfs, btrfs, fat, swap, lvm, luks }

    struct RecordedError: Equatable {
        var function: String
        var time: Date
    }

    struct Partition: Equatable {
        /// The GPT entry's number; 0 is the whole disk (no partition table).
        var number: Int
        var kind: Kind
        var name: String
        var filesystem: Filesystem
        /// Its main superblock is there and sane, its checksum holds.
        var intact: Bool
        var backupIntact: Bool
        /// ext: where its backup is (e2fsck -b and -B).
        var backupBlock: UInt64
        var blockSize: UInt32
        var label: String
        var recordedErrors: Bool
        var needsRecovery: Bool
        var lastError: RecordedError?

        /// How it is called in a sentence.
        var called: String {
            if !label.isEmpty { return "the filesystem \(label)" }
            if !name.isEmpty { return "the filesystem \(name)" }
            return number == 0 ? "the filesystem" : "the filesystem on partition \(number)"
        }

        /// Its superblock is damaged, or it says it has errors: worth a check.
        var damaged: Bool { filesystem != .unknown && (!intact || recordedErrors) }
    }

    var table: Table
    var partitions: [Partition]
    /// Used GPT entries not reported (outside the disk, or too many).
    var skipped: Int

    static func check(disk: URL) -> DiskReport? {
        let fd = open(disk.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { return nil }
        var box = fd
        var report = mnd_disk_report()
        let rc = mnd_disk_check({ ctx, offset, buf, len in
            guard let ctx, let buf, offset <= UInt64(Int64.max) else { return -1 }
            let fd = ctx.load(as: Int32.self)
            return pread(fd, buf, len, off_t(offset)) == len ? 0 : -1
        }, &box, UInt64(st.st_size), &report)
        return rc == 0 ? DiskReport(report) : nil
    }

    init(table: Table, partitions: [Partition], skipped: Int = 0) {
        self.table = table
        self.partitions = partitions
        self.skipped = skipped
    }

    init(_ r: mnd_disk_report) {
        switch r.gpt {
        case MND_GPT_OK: table = .intact
        case MND_GPT_BACKUP: table = .backupOnly
        default: table = .none
        }
        skipped = Int(r.skipped)
        partitions = withUnsafeBytes(of: r.parts) { raw in
            Array(raw.bindMemory(to: mnd_disk_part.self).prefix(Int(r.count))).map(Partition.init)
        }
    }

    /// What is wrong, worst first; empty when nothing is.
    var problems: [String] {
        var out: [String] = []
        if table == .none, partitions.count == 1, partitions[0].filesystem == .unknown {
            return ["it has no partition table and no filesystem Monad recognizes"]
        }
        if table == .backupOnly {
            out.append("its main partition table is damaged (the backup copy at the disk's end is intact)")
        }
        for p in partitions where p.filesystem != .unknown && !p.intact {
            out.append(p.backupIntact
                ? "\(p.called) has a damaged superblock (a backup copy\(p.backupBlock > 0 ? " at block \(p.backupBlock)" : "") is intact)"
                : "\(p.called) has a damaged superblock and no intact copy")
        }
        for p in partitions where p.intact && p.recordedErrors {
            out.append("\(p.called) recorded errors" + (p.lastError.map { " (the last in \($0.function) on \(Self.stamp($0.time)))" } ?? ""))
        }
        for p in partitions where p.filesystem == .unknown && [.root, .boot, .efi].contains(p.kind) {
            out.append("partition \(p.number) (\(p.kind == .efi ? "EFI" : p.kind == .boot ? "/boot" : "the root")) holds no filesystem Monad recognizes")
        }
        return out
    }

    /// Something a filesystem check can work on.
    var repairable: Bool { table == .backupOnly || partitions.contains { $0.damaged } }

    /// A sentence or two for a boot that failed.
    var summary: String {
        let found = problems
        guard !found.isEmpty else {
            return "Monad checked its disk and found its partitions and filesystems intact, so the cause is inside the guest."
        }
        return "Monad checked its disk: " + found.joined(separator: "; ") + "." + (repairable ? " It needs a filesystem check." : "")
    }

    /// Everything it found, on one line for the VM's log.
    var logLine: String {
        let head: String
        switch table {
        case .none: head = "no partition table"
        case .intact: head = "GPT intact"
        case .backupOnly: head = "main GPT damaged, its backup intact"
        }
        let parts = partitions.map { p -> String in
            let kind: String
            switch p.kind {
            case .efi: kind = "EFI"
            case .root: kind = "root"
            case .boot: kind = "/boot"
            case .data: kind = "data"
            case .swap: kind = "swap"
            case .lvm: kind = "LVM"
            case .other: kind = "other"
            }
            let label = [p.label.isEmpty ? p.name : p.label, kind].filter { !$0.isEmpty }.joined(separator: ", ")
            var s = (p.number == 0 ? "the whole disk" : "partition \(p.number) (\(label))") + ": "
            guard p.filesystem != .unknown else { return s + "nothing recognized" }
            s += p.filesystem.rawValue + ", " + (p.intact ? "intact" : "damaged superblock")
            if !p.intact { s += p.backupIntact ? (p.backupBlock > 0 ? ", backup at block \(p.backupBlock)" : ", backup intact") : ", no intact copy" }
            if p.recordedErrors { s += ", errors recorded" + (p.lastError.map { " (last: \($0.function), \(Self.stamp($0.time)))" } ?? "") }
            if p.needsRecovery { s += ", journal not replayed" }
            return s
        }
        return ([head] + parts).joined(separator: "; ") + (skipped > 0 ? "; \(skipped) more entries left out" : "")
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}

extension DiskReport.Partition {
    init(_ p: mnd_disk_part) {
        number = Int(p.number)
        switch p.kind {
        case MND_PART_EFI: kind = .efi
        case MND_PART_LINUX_ROOT: kind = .root
        case MND_PART_LINUX_BOOT: kind = .boot
        case MND_PART_LINUX_DATA: kind = .data
        case MND_PART_LINUX_SWAP: kind = .swap
        case MND_PART_LINUX_LVM: kind = .lvm
        default: kind = .other
        }
        switch p.fs {
        case MND_FS_EXT: filesystem = .ext
        case MND_FS_XFS: filesystem = .xfs
        case MND_FS_BTRFS: filesystem = .btrfs
        case MND_FS_FAT: filesystem = .fat
        case MND_FS_SWAP: filesystem = .swap
        case MND_FS_LVM: filesystem = .lvm
        case MND_FS_LUKS: filesystem = .luks
        default: filesystem = .unknown
        }
        name = Self.string(p.name)
        label = Self.string(p.label)
        intact = p.primary_ok != 0
        backupIntact = p.backup_ok != 0
        backupBlock = p.backup_block
        blockSize = p.block_size
        recordedErrors = p.has_errors != 0
        needsRecovery = p.needs_recovery != 0
        let last = Self.string(p.last_error_func)
        lastError = last.isEmpty || p.last_error_time == 0 ? nil
            : DiskReport.RecordedError(function: last, time: Date(timeIntervalSince1970: TimeInterval(p.last_error_time)))
    }

    /// A C char array (NUL-terminated by mnd_diskcheck, printable ASCII).
    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
