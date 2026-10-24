//
//  HostBuildTests.swift — build identity (Mach-O LC_UUID) of executables, used
//  to notice a running MonadHost that is older than the app's embedded one.
//

import MachO
import XCTest
@testable import Monad

final class HostBuildTests: XCTestCase {
    private var tmp: TempDir!

    override func setUp() {
        tmp = TempDir()
    }

    private func write(_ bytes: [UInt8], _ name: String = "bin") throws -> URL {
        let url = tmp.url.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// Minimal 64-bit Mach-O: header plus one LC_UUID command.
    private func thin(cpu: Int32, uuid: UInt8) -> [UInt8] {
        var b: [UInt8] = []
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { b.append(contentsOf: $0) } }
        u32(MH_MAGIC_64)
        u32(UInt32(bitPattern: cpu))
        u32(0)                      // cpusubtype
        u32(UInt32(MH_EXECUTE))
        u32(1)                      // ncmds
        u32(24)                     // sizeofcmds
        u32(0)                      // flags
        u32(0)                      // reserved
        u32(UInt32(LC_UUID))
        u32(24)
        b.append(contentsOf: [UInt8](repeating: uuid, count: 16))
        return b
    }

    /// Universal binary (big-endian fat header) with the given slices.
    private func fat(_ slices: [(cpu: Int32, body: [UInt8])]) -> [UInt8] {
        var b: [UInt8] = []
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { b.append(contentsOf: $0) } }
        u32(FAT_MAGIC)
        u32(UInt32(slices.count))
        var offset = UInt32(8 + 20 * slices.count)
        for s in slices {
            u32(UInt32(bitPattern: s.cpu))
            u32(0)
            u32(offset)
            u32(UInt32(s.body.count))
            u32(0)
            offset += UInt32(s.body.count)
        }
        for s in slices { b.append(contentsOf: s.body) }
        return b
    }

    private var currentCPU: Int32 {
        #if arch(arm64)
            CPU_TYPE_ARM64
        #else
            CPU_TYPE_X86_64
        #endif
    }

    private var otherCPU: Int32 {
        #if arch(arm64)
            CPU_TYPE_X86_64
        #else
            CPU_TYPE_ARM64
        #endif
    }

    func testRunningExecutableMatchesItsFile() throws {
        let current = try XCTUnwrap(HostBuild.current)
        let exe = try XCTUnwrap(Bundle.main.executableURL)
        XCTAssertEqual(HostBuild.uuid(ofExecutableAt: exe), current)
        XCTAssertEqual(current.count, 36, "UUID string")
    }

    func testThinBinary() throws {
        let url = try write(thin(cpu: currentCPU, uuid: 0xAB))
        XCTAssertEqual(HostBuild.uuid(ofExecutableAt: url), "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")
    }

    func testUniversalBinaryUsesTheSliceForThisMac() throws {
        let url = try write(fat([(otherCPU, thin(cpu: otherCPU, uuid: 0x11)),
                                 (currentCPU, thin(cpu: currentCPU, uuid: 0x22))]))
        XCTAssertEqual(HostBuild.uuid(ofExecutableAt: url), "22222222-2222-2222-2222-222222222222")
    }

    func testUniversalBinaryWithoutOurArchitecture() throws {
        let url = try write(fat([(otherCPU, thin(cpu: otherCPU, uuid: 0x11))]))
        XCTAssertNil(HostBuild.uuid(ofExecutableAt: url))
    }

    func testMalformedFilesHaveNoBuild() throws {
        XCTAssertNil(HostBuild.uuid(ofExecutableAt: try write([], "empty")))
        XCTAssertNil(HostBuild.uuid(ofExecutableAt: try write(Array("#!/bin/sh\necho hi\n".utf8), "script")))
        XCTAssertNil(HostBuild.uuid(ofExecutableAt: try write(Array(thin(cpu: currentCPU, uuid: 1).prefix(40)), "cut")))
        var lying = thin(cpu: currentCPU, uuid: 1)
        lying[20] = 0xFF // sizeofcmds (bytes 20-23) far beyond the file
        XCTAssertNil(HostBuild.uuid(ofExecutableAt: try write(lying, "lying")))
        var loop = thin(cpu: currentCPU, uuid: 1)
        loop[32 + 4] = 0 // cmdsize 0 would never advance
        XCTAssertNil(HostBuild.uuid(ofExecutableAt: try write(loop, "loop")))
        XCTAssertNil(HostBuild.uuid(ofExecutableAt: tmp.url.appendingPathComponent("missing")))
    }
}
