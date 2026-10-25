//
//  DiskCheckTests.swift — DiskReport: a stopped VM's disk read through
//  mnd_diskcheck (its own tests are CTests/test_diskcheck.c), and what Monad
//  says about it.
//

import XCTest
@testable import Monad

final class DiskCheckTests: XCTestCase {
    private var tmp: TempDir!

    override func setUp() {
        tmp = TempDir()
    }

    /// An ext4 superblock without checksums (enough for the checker): the
    /// copy of `group`, 4 KiB blocks.
    static func ext4Superblock(group: UInt16 = 0, label: String, errors: (function: String, time: UInt32)? = nil) -> Data {
        var sb = Data(count: 1024)
        func put32(_ v: UInt32, _ at: Int) { withUnsafeBytes(of: v.littleEndian) { sb.replaceSubrange(at..<at + 4, with: $0) } }
        func put16(_ v: UInt16, _ at: Int) { withUnsafeBytes(of: v.littleEndian) { sb.replaceSubrange(at..<at + 2, with: $0) } }
        put32(2, 24)          // 4 KiB blocks
        put32(32768, 32)      // blocks per group
        put16(0xEF53, 56)
        put16(errors == nil ? 1 : 2, 58)
        put16(group, 90)
        sb.replaceSubrange(120..<120 + label.utf8.count, with: Array(label.utf8))
        if let errors {
            put32(1, 0x194)
            put32(errors.time, 0x198)
            sb.replaceSubrange(0x1A8..<0x1A8 + errors.function.utf8.count, with: Array(errors.function.utf8))
            put32(errors.time, 0x1CC)
            sb.replaceSubrange(0x1E0..<0x1E0 + errors.function.utf8.count, with: Array(errors.function.utf8))
        }
        return sb
    }

    /// A sparse disk file holding one ext4 (no partition table): its main
    /// superblock if given, and its backup in group 1.
    static func writeDisk(_ url: URL, primary: Data?, label: String = "cloudimg-rootfs") throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        if let primary {
            try file.seek(toOffset: 1024)
            try file.write(contentsOf: primary)
        }
        try file.seek(toOffset: 32768 * 4096)
        try file.write(contentsOf: ext4Superblock(group: 1, label: label))
        try file.truncate(atOffset: 1 << 30)
    }

    func testAnIntactDiskSaysTheCauseIsInsideTheGuest() throws {
        let disk = tmp.url.appendingPathComponent("disk.raw")
        try Self.writeDisk(disk, primary: Self.ext4Superblock(label: "cloudimg-rootfs"))
        let report = try XCTUnwrap(DiskReport.check(disk: disk))
        XCTAssertEqual(report.table, .none)
        XCTAssertEqual(report.partitions.count, 1)
        XCTAssertEqual(report.partitions.first?.filesystem, .ext)
        XCTAssertEqual(report.partitions.first?.label, "cloudimg-rootfs")
        XCTAssertTrue(report.problems.isEmpty)
        XCTAssertFalse(report.repairable)
        XCTAssertEqual(report.summary, "Monad checked its disk and found its partitions and filesystems intact, so the cause is inside the guest.")
    }

    /// The incident: the root's main superblock zeroed, its backup intact.
    func testADamagedSuperblockIsNamedWithItsBackup() throws {
        let disk = tmp.url.appendingPathComponent("disk.raw")
        try Self.writeDisk(disk, primary: nil)
        let report = try XCTUnwrap(DiskReport.check(disk: disk))
        let root = try XCTUnwrap(report.partitions.first)
        XCTAssertFalse(root.intact)
        XCTAssertTrue(root.backupIntact)
        XCTAssertEqual(root.backupBlock, 32768)
        XCTAssertEqual(root.blockSize, 4096)
        XCTAssertTrue(report.repairable)
        XCTAssertEqual(report.problems, ["the filesystem cloudimg-rootfs has a damaged superblock (a backup copy at block 32768 is intact)"])
        XCTAssertTrue(report.summary.hasPrefix("Monad checked its disk: the filesystem cloudimg-rootfs has a damaged superblock"), report.summary)
        XCTAssertTrue(report.summary.hasSuffix("Repair Disk, in its ⋯ menu, can check and repair it."), report.summary)
    }

    func testRecordedErrorsAreNamedWithTheLastOne() throws {
        let disk = tmp.url.appendingPathComponent("disk.raw")
        try Self.writeDisk(disk, primary: Self.ext4Superblock(label: "cloudimg-rootfs",
                                                              errors: ("ext4_reserve_inode_write", 1_792_938_050)))
        let report = try XCTUnwrap(DiskReport.check(disk: disk))
        let root = try XCTUnwrap(report.partitions.first)
        XCTAssertTrue(root.recordedErrors)
        XCTAssertEqual(root.lastError?.function, "ext4_reserve_inode_write")
        XCTAssertEqual(root.lastError?.time, Date(timeIntervalSince1970: 1_792_938_050))
        XCTAssertTrue(report.repairable)
        let problem = try XCTUnwrap(report.problems.first)
        XCTAssertTrue(problem.hasPrefix("the filesystem cloudimg-rootfs recorded errors (the last in ext4_reserve_inode_write on "), problem)
    }

    func testADiskWithNothingKnownOnItSaysSo() throws {
        let disk = tmp.url.appendingPathComponent("disk.raw")
        FileManager.default.createFile(atPath: disk.path, contents: Data(repeating: 0, count: 1 << 20))
        let report = try XCTUnwrap(DiskReport.check(disk: disk))
        XCTAssertEqual(report.problems, ["it has no partition table and no filesystem Monad recognizes"])
        XCTAssertFalse(report.repairable)
    }

    func testAMissingDiskIsNoReport() {
        XCTAssertNil(DiskReport.check(disk: tmp.url.appendingPathComponent("gone.raw")))
    }
}
