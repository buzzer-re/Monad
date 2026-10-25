#!/usr/bin/env python3
"""Write disk fixtures for test_diskcheck and fuzz_decoders.

Independent from the C checker: GPTs, ext4, FAT32, btrfs, XFS, swap, LUKS and
LVM headers built byte by byte from their specs (the layouts were checked
against mkfs.ext4, mkfs.btrfs, mkfs.vfat, mkfs.xfs and mkswap). A disk is
mostly empty, so each one is written as regions: a file of
  b"MNDDISK1", u64 disk size, u32 count, then per region u64 offset, u32 length, bytes
(little-endian); everything outside a region reads as zeros.
Usage: gen_disk_fixtures.py OUTDIR
"""
import os
import struct
import sys
import uuid
import zlib

SECTOR = 512
GIB = 1 << 30

EFI = uuid.UUID("C12A7328-F81F-11D2-BA4B-00A0C93EC93B")
ROOT_ARM64 = uuid.UUID("B921B045-1DF0-41C3-AF44-4C6F280D3FAE")
XBOOTLDR = uuid.UUID("BC13C2FF-59E6-4262-A352-B275FD6F7172")
LINUX_DATA = uuid.UUID("0FC63DAF-8483-4772-8E79-3D69D8477DE4")
SWAP = uuid.UUID("0657FD6D-A4AB-43C4-84E5-0933C84B4F4F")
LVM = uuid.UUID("E6D6D379-F507-44C2-A23C-238F2A3DF928")


def crc32c(data, crc=0xFFFFFFFF):
    """CRC32C without the final inversion (as ext4 stores it)."""
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ (0x82F63B78 if crc & 1 else 0)
    return crc


class Disk:
    def __init__(self, size):
        self.size = size
        self.regions = {}

    def put(self, offset, data):
        assert offset + len(data) <= self.size
        self.regions[offset] = bytes(data)

    def write(self, path):
        with open(path, "wb") as f:
            f.write(b"MNDDISK1" + struct.pack("<QI", self.size, len(self.regions)))
            for off in sorted(self.regions):
                data = self.regions[off]
                f.write(struct.pack("<QI", off, len(data)) + data)


# ---- GPT -----------------------------------------------------------------------

def gpt(disk, parts, entries=128, entry_size=128, break_main=False):
    """parts: (number, type uuid, first lba, last lba, name)."""
    last = disk.size // SECTOR - 1
    table = bytearray(entries * entry_size)
    for number, kind, first, end, name in parts:
        e = bytearray(entry_size)
        e[0:16] = kind.bytes_le
        e[16:32] = uuid.uuid5(uuid.NAMESPACE_DNS, "part%d" % number).bytes_le
        struct.pack_into("<QQQ", e, 32, first, end, 0)
        encoded = name.encode("utf-16-le")[:72]
        e[56:56 + len(encoded)] = encoded
        table[(number - 1) * entry_size:number * entry_size] = e
    table_crc = zlib.crc32(bytes(table)) & 0xFFFFFFFF
    table_sectors = (len(table) + SECTOR - 1) // SECTOR

    def header(my_lba, alt_lba, entries_lba):
        h = bytearray(SECTOR)
        h[0:8] = b"EFI PART"
        struct.pack_into("<IIII", h, 8, 0x00010000, 92, 0, 0)
        struct.pack_into("<QQQQ", h, 24, my_lba, alt_lba, 34, last - 33)
        h[56:72] = uuid.uuid5(uuid.NAMESPACE_DNS, "disk").bytes_le
        struct.pack_into("<QIII", h, 72, entries_lba, entries, entry_size, table_crc)
        struct.pack_into("<I", h, 16, zlib.crc32(bytes(h[:92])) & 0xFFFFFFFF)
        return h

    mbr = bytearray(SECTOR)
    mbr[446 + 4] = 0xEE
    struct.pack_into("<II", mbr, 446 + 8, 1, min(last, 0xFFFFFFFF))
    mbr[510:512] = b"\x55\xaa"
    disk.put(0, mbr)
    main = header(1, last, 2)
    if break_main:
        main[20] ^= 0xFF  # its CRC no longer holds
    disk.put(SECTOR, main)
    disk.put(2 * SECTOR, table)
    disk.put((last - table_sectors) * SECTOR, table)
    disk.put(last * SECTOR, header(last, 1, last - table_sectors))


# ---- filesystems ---------------------------------------------------------------

def ext4_superblock(block_size, group, label, csum=True, state=1, errors=None, recovery=False):
    sb = bytearray(1024)
    log = {1024: 0, 2048: 1, 4096: 2}[block_size]
    per_group = 8 * block_size
    struct.pack_into("<IIIIIIII", sb, 0, 4 * 8192, 4 * per_group, 0, 1000, 30000, 1 if block_size == 1024 else 0, log, log)
    struct.pack_into("<III", sb, 32, per_group, per_group, 8192)
    struct.pack_into("<IIHhHHHH", sb, 44, 1792938000, 1792938050, 3, -1, 0xEF53, state, 1, 0)
    struct.pack_into("<IIII", sb, 64, 0, 0, 0, 1)  # lastcheck, interval, creator, rev 1
    struct.pack_into("<IHH", sb, 84, 11, 256, group)  # first_ino, inode_size, block_group_nr
    incompat = 0x2C2 | (0x4 if recovery else 0)
    ro_compat = 0x46B if csum else 0x6B
    struct.pack_into("<III", sb, 92, 0x3C, incompat, ro_compat)
    sb[104:120] = uuid.uuid5(uuid.NAMESPACE_DNS, label).bytes
    struct.pack_into("<H", sb, 0xFE, 64)  # 64-bit group descriptors
    sb[0x174] = 4  # 16 groups per flex group
    name = label.encode()[:16]
    sb[120:120 + len(name)] = name
    if errors:
        count, func, when = errors
        struct.pack_into("<II", sb, 0x194, count, when)
        f = func.encode()[:32]
        sb[0x1A8:0x1A8 + len(f)] = f
        struct.pack_into("<I", sb, 0x1CC, when)
        sb[0x1E0:0x1E0 + len(f)] = f
    if csum:
        sb[0x175] = 1
        struct.pack_into("<I", sb, 0x3FC, crc32c(bytes(sb[:0x3FC])))
    return sb


def ext4(disk, start, block_size, label, groups=(1, 3), primary=None, **kw):
    """An ext4 at byte `start`: its superblock, and backups in `groups`."""
    disk.put(start + 1024, primary if primary is not None else ext4_superblock(block_size, 0, label, **kw))
    first_data = 1 if block_size == 1024 else 0
    for g in groups:
        block = g * 8 * block_size + first_data
        disk.put(start + block * block_size, ext4_superblock(block_size, g, label, csum=kw.get("csum", True)))


def fat32(disk, start, label):
    bs = bytearray(SECTOR)
    bs[0:3] = b"\xeb\x58\x90"
    bs[3:11] = b"mkfs.fat"
    struct.pack_into("<HBHBHHBH", bs, 11, 512, 1, 32, 2, 0, 0, 0xF8, 0)
    struct.pack_into("<HHII", bs, 24, 32, 64, 0, 202752)
    struct.pack_into("<IHHIHH", bs, 36, 1568, 0, 0, 2, 1, 6)
    bs[64] = 0x80
    bs[66] = 0x29
    bs[71:82] = label.encode().ljust(11)[:11]
    bs[82:90] = b"FAT32   "
    bs[510:512] = b"\x55\xaa"
    disk.put(start, bs)
    disk.put(start + 6 * SECTOR, bs)


def btrfs_superblock(label, mirror=0):
    sb = bytearray(4096)
    sb[0x20:0x30] = uuid.uuid5(uuid.NAMESPACE_DNS, label).bytes
    struct.pack_into("<Q", sb, 0x30, 0x10000 if mirror == 0 else 0x4000000)
    sb[0x40:0x48] = b"_BHRfS_M"
    struct.pack_into("<IIIII", sb, 0x90, 4096, 16384, 4096, 4096, 0)  # sectorsize, nodesize, ...
    struct.pack_into("<H", sb, 0xC4, 0)  # crc32c
    name = label.encode()[:255]
    sb[0x12B:0x12B + len(name)] = name
    struct.pack_into("<I", sb, 0, crc32c(bytes(sb[0x20:])) ^ 0xFFFFFFFF)  # btrfs keeps the inverted one
    return sb


def btrfs(disk, start, label, break_main=False):
    main = btrfs_superblock(label)
    if break_main:
        main[0x100] ^= 0xFF
    disk.put(start + 0x10000, main)
    disk.put(start + 0x4000000, btrfs_superblock(label, mirror=1))


def xfs(disk, start, label):
    sb = bytearray(SECTOR)
    sb[0:4] = b"XFSB"
    struct.pack_into(">I", sb, 4, 4096)
    name = label.encode()[:12]
    sb[108:108 + len(name)] = name
    disk.put(start, sb)


# ---- the disks -----------------------------------------------------------------

def cloud(size=8 * GIB, root=None, gpt_kw=None, **root_kw):
    """Shaped like Ubuntu's cloud image: root (1), /boot (13), EFI (15)."""
    d = Disk(size)
    last = size // SECTOR - 34
    gpt(d, [(1, ROOT_ARM64, 2099200, last, ""), (13, XBOOTLDR, 206848, 2097152, ""),
            (15, EFI, 2048, 204800, "")], **(gpt_kw or {}))
    ext4(d, 2099200 * SECTOR, 4096, "cloudimg-rootfs", primary=root, **root_kw)
    ext4(d, 206848 * SECTOR, 1024, "BOOT", groups=(1,), csum=False)
    fat32(d, 2048 * SECTOR, "UEFI")
    return d


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)

    cloud().write(os.path.join(out, "disk_cloud.regions"))

    # What a VM's disk looked like after it stopped booting: the root's main
    # superblock zeroed but for the counts and the error it was recording.
    zeroed = bytearray(1024)
    struct.pack_into("<II", zeroed, 12, 10962371, 6274843)
    struct.pack_into("<I", zeroed, 48, 0x6ADE1042)
    struct.pack_into("<II", zeroed, 0x194, 1, 0x6ADE1042)
    zeroed[0x1A8:0x1A8 + 24] = b"ext4_reserve_inode_write"
    cloud(root=zeroed).write(os.path.join(out, "disk_zeroed_root.regions"))

    cloud(state=2, recovery=True, errors=(1, "ext4_reserve_inode_write", 0x6ADE1042)).write(
        os.path.join(out, "disk_root_errors.regions"))

    bad = ext4_superblock(4096, 0, "cloudimg-rootfs")
    bad[0x3FC] ^= 0x01
    cloud(root=bad).write(os.path.join(out, "disk_bad_csum.regions"))

    cloud(gpt_kw={"break_main": True}).write(os.path.join(out, "disk_gpt_backup.regions"))

    d = Disk(16 * GIB)
    m = 1 << 20
    parts = [(1, ROOT_ARM64, 2048, 2048 + 2 * GIB // SECTOR - 1, "xfsroot"),
             (2, LINUX_DATA, 8 * m // SECTOR * 600, 8 * m // SECTOR * 600 + GIB // SECTOR - 1, "btrfs"),
             (3, SWAP, 8 * m // SECTOR * 800, 8 * m // SECTOR * 800 + 16 * m // SECTOR - 1, "swap"),
             (4, LINUX_DATA, 8 * m // SECTOR * 900, 8 * m // SECTOR * 900 + 16 * m // SECTOR - 1, "crypt"),
             (5, LVM, 8 * m // SECTOR * 1000, 8 * m // SECTOR * 1000 + 16 * m // SECTOR - 1, "lvm"),
             (6, LINUX_DATA, 8 * m // SECTOR * 1100, 8 * m // SECTOR * 1100 + 16 * m // SECTOR - 1, "empty"),
             (7, LINUX_DATA, 8 * m // SECTOR * 1200, 8 * m // SECTOR * 1200 + GIB // SECTOR - 1, "btrfs2")]
    gpt(d, parts)
    xfs(d, 2048 * SECTOR, "xfsroot")
    btrfs(d, parts[1][2] * SECTOR, "data")
    swap = bytearray(4096)
    swap[4086:4096] = b"SWAPSPACE2"
    d.put(parts[2][2] * SECTOR, swap)
    d.put(parts[3][2] * SECTOR, b"LUKS\xba\xbe\x00\x02")
    lvm = bytearray(SECTOR)
    lvm[0:8] = b"LABELONE"
    d.put(parts[4][2] * SECTOR + SECTOR, lvm)
    btrfs(d, parts[6][2] * SECTOR, "data2", break_main=True)
    d.write(os.path.join(out, "disk_others.regions"))

    bare = Disk(1 * GIB)
    ext4(bare, 0, 4096, "bare")
    bare.write(os.path.join(out, "disk_bare_ext4.regions"))

    # More used entries than reported, some outside the disk or backwards.
    h = Disk(4 * GIB)
    many = [(i, LINUX_DATA, 2048 + i * 4096, 2048 + i * 4096 + 4095, "p%d" % i) for i in range(1, 21)]
    many[2] = (3, LINUX_DATA, 2048, 4 * GIB // SECTOR + 10, "past the end")
    many[3] = (4, LINUX_DATA, 9000, 8000, "backwards")
    gpt(h, many)
    h.write(os.path.join(out, "disk_many.regions"))


if __name__ == "__main__":
    main()
