#!/usr/bin/env python3
"""Fixtures for test_xz: .xz files assembled here around raw LZMA2 data from
Python's lzma module, so multi-block streams, every check type and precise
corruptions can be produced without the xz tool. Every valid fixture is
cross-checked with liblzma (lzma.decompress) before it is written.

Output: <dir>/xz_<name>.xz and, for valid ones, <dir>/xz_<name>.out.
"""
import hashlib
import lzma
import os
import random
import struct
import sys
import zlib

MAGIC = b"\xfd7zXZ\x00"
FOOTER_MAGIC = b"YZ"
CHECK_NONE, CHECK_CRC32, CHECK_CRC64, CHECK_SHA256 = 0, 1, 4, 10


def vli(n):
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def _crc64_table():
    poly = 0xC96C5795D7870F42
    table = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (c >> 1) ^ (poly if c & 1 else 0)
        table.append(c)
    return table


CRC64_TABLE = _crc64_table()


def crc64(data):
    crc = 0xFFFFFFFFFFFFFFFF
    for b in data:
        crc = CRC64_TABLE[(crc ^ b) & 0xFF] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFFFFFFFFFF


def check_value(kind, data):
    if kind == CHECK_NONE:
        return b""
    if kind == CHECK_CRC32:
        return struct.pack("<I", zlib.crc32(data))
    if kind == CHECK_CRC64:
        return struct.pack("<Q", crc64(data))
    if kind == CHECK_SHA256:
        return hashlib.sha256(data).digest()
    return b"\x00" * {2: 4, 3: 4, 5: 8, 6: 8}.get(kind, 16)


def dict_props(dict_size):
    for p in range(41):
        if ((2 | (p & 1)) << (p // 2 + 11)) >= dict_size:
            return p
    return 40


def block(data, check, dict_size=1 << 20, lc=3, lp=0, pb=2, sizes=True, filters=None, extra=b""):
    """One block: header, LZMA2 data, padding, check. Returns (bytes, unpadded, usize)."""
    raw = lzma.compress(data, format=lzma.FORMAT_RAW,
                        filters=[{"id": lzma.FILTER_LZMA2, "dict_size": dict_size,
                                  "lc": lc, "lp": lp, "pb": pb}])
    if filters is None:
        filters = [(0x21, bytes([dict_props(dict_size)]))]
    flags = (len(filters) - 1) | (0x40 if sizes else 0) | (0x80 if sizes else 0)
    body = bytes([flags])
    if sizes:
        body += vli(len(raw)) + vli(len(data))
    for fid, props in filters:
        body += vli(fid) + vli(len(props)) + props
    body += extra
    size = 1 + len(body) + 4
    size = (size + 3) & ~3
    body += b"\x00" * (size - 1 - len(body) - 4)
    hdr = bytes([size // 4 - 1]) + body
    hdr += struct.pack("<I", zlib.crc32(hdr))
    pad = (-len(raw)) % 4
    blk = hdr + raw + b"\x00" * pad + check_value(check, data)
    unpadded = len(hdr) + len(raw) + len(check_value(check, data))
    return blk, unpadded, len(data)


def stream(parts, check=CHECK_CRC64, **kw):
    """A complete stream from a list of per-block payloads."""
    flags = bytes([0, check])
    out = MAGIC + flags + struct.pack("<I", zlib.crc32(flags))
    records = []
    for p in parts:
        b, unpadded, usize = block(p, check, **kw)
        out += b
        records.append((unpadded, usize))
    index = b"\x00" + vli(len(records))
    for u, s in records:
        index += vli(u) + vli(s)
    index += b"\x00" * ((-len(index)) % 4)
    index += struct.pack("<I", zlib.crc32(index))
    out += index
    backward = len(index) // 4 - 1
    footer_body = struct.pack("<I", backward) + flags
    out += struct.pack("<I", zlib.crc32(footer_body)) + footer_body + FOOTER_MAGIC
    return out


def index_size(xz):
    """Size of the index of the last stream in xz, from the footer's backward size."""
    return (struct.unpack("<I", xz[-8:-4])[0] + 1) * 4


def write(d, name, xz, expected=None, crosscheck=True):
    with open(os.path.join(d, f"xz_{name}.xz"), "wb") as f:
        f.write(xz)
    if expected is not None:
        if crosscheck:
            assert lzma.decompress(xz) == expected, f"{name}: liblzma disagrees"
        with open(os.path.join(d, f"xz_{name}.out"), "wb") as f:
            f.write(expected)


def main(d):
    os.makedirs(d, exist_ok=True)
    rnd = random.Random(1234)
    text = b"".join(b"line %06d: the quick brown fox jumps over the lazy dog\n" % i for i in range(20000))
    noise = bytes(rnd.getrandbits(8) for _ in range(300_000))           # stored as uncompressed chunks
    mixed = text[:400_000] + noise + text[400_000:] + b"\x00" * 3_000_000  # > 2 MiB: several LZMA2 chunks

    # Valid
    write(d, "empty", stream([]), b"")
    write(d, "empty_block", stream([b""]), b"")
    write(d, "hello_none", stream([b"hello, world\n"], CHECK_NONE), b"hello, world\n")
    write(d, "hello_crc32", stream([b"hello, world\n"], CHECK_CRC32), b"hello, world\n")
    write(d, "hello_crc64", stream([b"hello, world\n"], CHECK_CRC64), b"hello, world\n")
    write(d, "hello_sha256", stream([b"hello, world\n"], CHECK_SHA256), b"hello, world\n")
    write(d, "mixed", stream([mixed]), mixed)
    write(d, "multiblock", stream([mixed[:1_000_000], mixed[1_000_000:2_500_000], mixed[2_500_000:]]), mixed)
    write(d, "no_sizes", stream([text], sizes=False), text)
    write(d, "small_dict", stream([mixed], dict_size=4096), mixed)
    write(d, "lc0_lp2_pb0", stream([mixed], lc=0, lp=2, pb=0), mixed)
    write(d, "lc4_lp0_pb4", stream([text], lc=4, lp=0, pb=4), text)
    # Python's lzma stops at stream padding, so check the two streams one by one.
    first, second = stream([b"first stream\n"]), stream([b"second stream\n"], CHECK_CRC32)
    assert lzma.decompress(first) == b"first stream\n" and lzma.decompress(second) == b"second stream\n"
    write(d, "concatenated", first + b"\x00" * 8 + second, b"first stream\nsecond stream\n", crosscheck=False)

    # Invalid
    good = stream([text])
    write(d, "bad_magic", b"\xfd7zXY\x00" + good[6:])
    write(d, "truncated", good[: len(good) // 2])
    write(d, "truncated_footer", good[:-3])
    body = bytearray(good)
    body[len(body) // 2] ^= 0x55
    write(d, "corrupt_data", bytes(body))
    chk = bytearray(stream([b"hello, world\n"], CHECK_CRC64))
    chk[len(chk) - 12 - index_size(chk) - 8] ^= 1  # first byte of the block's CRC64
    write(d, "bad_check", bytes(chk))
    write(d, "bcj_filter", stream([text[:1000]], filters=[(0x04, b""), (0x21, bytes([dict_props(1 << 20)]))]))
    write(d, "check_reserved", stream([b"x"], check=3))
    write(d, "big_dict", stream([b"x" * 100], dict_size=64 << 20))
    idx = bytearray(stream([b"abc"], CHECK_CRC32))
    # Index record uncompressed size 3 -> 4 (and fix the index CRC so only the
    # mismatch with the decoded block is wrong).
    isz = index_size(idx)
    ipos = len(idx) - 12 - isz
    assert idx[ipos] == 0 and idx[ipos + 1] == 1 and idx[ipos + 3] == 3, idx[ipos:ipos + isz].hex()
    idx[ipos + 3] = 4
    idx[ipos + isz - 4:ipos + isz] = struct.pack("<I", zlib.crc32(bytes(idx[ipos:ipos + isz - 4])))
    write(d, "index_mismatch", bytes(idx))
    write(d, "bad_padding", stream([b"first"]) + b"\x00\x00")
    trailing = stream([b"first"]) + b"garbage!"
    write(d, "trailing_garbage", trailing)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
