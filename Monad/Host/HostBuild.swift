//
//  HostBuild.swift — build identity of an executable: its Mach-O LC_UUID,
//  which changes with every link. The app compares the running MonadHost's
//  identity with the host embedded in its own bundle to notice an outdated
//  host after an update.
//
//  The file parser reads untrusted bytes and checks every offset.
//

import Foundation
import MachO

enum HostBuild {
    /// Identity of the running executable.
    static let current: String? = {
        // Image 0 is not guaranteed to be the executable (dyld may be listed
        // first); the executable is the one image of type MH_EXECUTE.
        for i in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(i), header.pointee.magic == MH_MAGIC_64,
                  header.pointee.filetype == UInt32(MH_EXECUTE) else { continue }
            let raw = UnsafeRawPointer(header)
            let size = Int(header.pointee.sizeofcmds)
            let commands = UnsafeRawBufferPointer(start: raw + MemoryLayout<mach_header_64>.size, count: size)
            return uuid(commands: commands, count: Int(header.pointee.ncmds))
        }
        return nil
    }()

    /// Identity of the executable at `url` (the slice for this Mac's CPU in
    /// a universal binary), or nil when it is not a readable 64-bit Mach-O.
    static func uuid(ofExecutableAt url: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let head = try? file.read(upToCount: 8), head.count == 8 else { return nil }

        var sliceOffset: UInt64 = 0
        switch be32(head, 0) {
        case FAT_MAGIC, FAT_MAGIC_64:
            let is64 = be32(head, 0) == FAT_MAGIC_64
            let count = Int(be32(head, 4))
            let entrySize = is64 ? 32 : 20
            guard count > 0, count <= 16,
                  let table = try? file.read(upToCount: count * entrySize), table.count == count * entrySize else {
                return nil
            }
            var found: UInt64?
            for i in 0..<count {
                let e = i * entrySize
                guard Int32(bitPattern: be32(table, e)) == currentCPU else { continue }
                found = is64 ? be64(table, e + 8) : UInt64(be32(table, e + 8))
                break
            }
            guard let found else { return nil }
            sliceOffset = found
        default:
            break
        }

        let headerSize = MemoryLayout<mach_header_64>.size
        guard (try? file.seek(toOffset: sliceOffset)) != nil,
              let header = try? file.read(upToCount: headerSize), header.count == headerSize,
              le32(header, 0) == MH_MAGIC_64 else { return nil }
        guard Int32(bitPattern: le32(header, 4)) == currentCPU else { return nil }
        let count = Int(le32(header, 16))
        let size = Int(le32(header, 20))
        guard size <= 1 << 20, let commands = try? file.read(upToCount: size), commands.count == size else { return nil }
        return commands.withUnsafeBytes { uuid(commands: $0, count: count) }
    }

    private static var currentCPU: Int32 {
        #if arch(arm64)
            CPU_TYPE_ARM64
        #else
            CPU_TYPE_X86_64
        #endif
    }

    /// Walks `count` load commands in `commands` looking for LC_UUID.
    private static func uuid(commands: UnsafeRawBufferPointer, count: Int) -> String? {
        var offset = 0
        for _ in 0..<count {
            guard offset + 8 <= commands.count else { return nil }
            let cmd = commands.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            let size = Int(commands.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
            guard size >= 8, offset + size <= commands.count else { return nil }
            if cmd == UInt32(LC_UUID) {
                guard size >= 24 else { return nil }
                let bytes = [UInt8](commands[(offset + 8)..<(offset + 24)])
                return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress).uuidString }
            }
            offset += size
        }
        return nil
    }

    private static func be32(_ d: Data, _ at: Int) -> UInt32 {
        d.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
    }

    private static func be64(_ d: Data, _ at: Int) -> UInt64 {
        d.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt64.self)) }
    }

    private static func le32(_ d: Data, _ at: Int) -> UInt32 {
        d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
    }
}
