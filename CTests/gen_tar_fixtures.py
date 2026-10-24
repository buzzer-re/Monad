#!/usr/bin/env python3
"""Fixtures for test_tar: tar archives written byte by byte (no GNU tar
needed), covering ustar, pax, GNU long names, base-256 numbers and both GNU
sparse encodings used in practice (old GNU 'S' with extension headers, and
pax 1.0). Every valid archive is cross-checked with Python's tarfile.

Output: <dir>/tar_<name>.tar and <dir>/tar_<name>.out (expected content of
the member the test extracts). tar_sparse_xz.tar.xz wraps a sparse archive
in .xz for the end-to-end test.
"""
import io
import lzma
import os
import random
import sys
import tarfile

BLOCK = 512


def octal(value, width):
    s = b"%0*o" % (width - 1, value)
    assert len(s) == width - 1, (value, width)
    return s + b"\0"


def base256(value, width):
    return bytes([0x80]) + value.to_bytes(width - 1, "big")


def pad(data):
    return data + b"\0" * ((-len(data)) % BLOCK)


def header(name, size, typeflag=b"0", gnu=False, size_field=None, extra=None, linkname=b""):
    h = bytearray(BLOCK)
    h[0:len(name)] = name
    h[100:108] = octal(0o644, 8)
    h[108:116] = octal(0, 8)
    h[116:124] = octal(0, 8)
    h[124:136] = size_field if size_field is not None else octal(size, 12)
    h[136:148] = octal(1_700_000_000, 12)
    h[156:157] = typeflag
    h[157:157 + len(linkname)] = linkname
    if gnu:
        h[257:265] = b"ustar  \0"
    else:
        h[257:263] = b"ustar\0"
        h[263:265] = b"00"
    if extra:
        for off, val in extra:
            h[off:off + len(val)] = val
    h[148:156] = b" " * 8
    h[148:156] = b"%06o\0 " % sum(h)
    return bytes(h)


def member(name, data, **kw):
    return header(name, len(data), **kw) + pad(data)


def pax_record(key, value):
    body = b" %s=%s\n" % (key, value)
    n = len(body) + 1
    while len(str(n).encode()) + len(body) != n:
        n = len(str(n).encode()) + len(body)
    return str(n).encode() + body


def pax(records, name=b"PaxHeaders/x"):
    data = b"".join(pax_record(k, v) for k, v in records)
    return member(name, data, typeflag=b"x")


def end():
    return b"\0" * (2 * BLOCK)


def sparse_image(realsize, segments, rnd):
    """Bytes of a file that is zero except for the given (offset, length) runs."""
    img = bytearray(realsize)
    for off, n in segments:
        img[off:off + n] = bytes(rnd.getrandbits(8) | 1 for _ in range(n))
    return bytes(img)


def gnu_sparse(name, realsize, segments, image):
    """Old GNU sparse member ('S') with extension headers as needed."""
    entries = list(segments)
    stored = b"".join(image[o:o + n] for o, n in entries)
    first, rest = entries[:4], entries[4:]
    extra = []
    for i, (o, n) in enumerate(first):
        extra += [(386 + 24 * i, octal(o, 12)), (398 + 24 * i, octal(n, 12))]
    extra += [(482, b"\x01" if rest else b"\x00"), (483, octal(realsize, 12))]
    out = header(name, len(stored), typeflag=b"S", gnu=True, extra=extra)
    while rest:
        chunk, rest = rest[:21], rest[21:]
        ext = bytearray(BLOCK)
        for i, (o, n) in enumerate(chunk):
            ext[24 * i:24 * i + 12] = octal(o, 12)
            ext[24 * i + 12:24 * i + 24] = octal(n, 12)
        ext[504] = 1 if rest else 0
        out += bytes(ext)
    return out + pad(stored)


def pax_sparse_1_0(name, realsize, segments, image):
    """pax format 1.0 sparse member: map as decimal text at the start of the data."""
    stored = b"".join(image[o:o + n] for o, n in segments)
    m = b"%d\n" % len(segments) + b"".join(b"%d\n%d\n" % (o, n) for o, n in segments)
    body = pad(m) + stored
    ph = pax([(b"GNU.sparse.major", b"1"), (b"GNU.sparse.minor", b"0"),
              (b"GNU.sparse.name", name), (b"GNU.sparse.realsize", b"%d" % realsize)])
    return ph + header(b"./GNUSparseFile.0/" + name, len(body)) + pad(body)


def write(d, name, tar, expected=None, member_name=None):
    with open(os.path.join(d, f"tar_{name}.tar"), "wb") as f:
        f.write(tar)
    if expected is not None:
        with tarfile.open(fileobj=io.BytesIO(tar)) as t:
            got = t.extractfile(member_name).read()
        assert got == expected, f"{name}: tarfile disagrees ({len(got)} vs {len(expected)})"
        with open(os.path.join(d, f"tar_{name}.out"), "wb") as f:
            f.write(expected)


def main(d):
    os.makedirs(d, exist_ok=True)
    rnd = random.Random(99)
    disk = bytes(rnd.getrandbits(8) for _ in range(70_000)) + b"\0" * 300_000 + b"tail!" * 1000

    readme = member(b"readme.txt", b"hello\n")
    folder = header(b"images/", 0, typeflag=b"5")
    link = header(b"images/latest.raw", 0, typeflag=b"2", linkname=b"disk.raw")

    write(d, "plain", member(b"disk.raw", disk) + end(), disk, "disk.raw")
    write(d, "among_others", readme + folder + link + member(b"images/disk.raw", disk) + end(), disk,
          "images/disk.raw")
    write(d, "dot_slash", member(b"./disk.raw", disk) + end(), disk, "./disk.raw")
    long_name = b"a/" + b"very-long-directory-name/" * 8 + b"disk.raw"
    write(d, "gnu_longname", member(b"././@LongLink", long_name + b"\0", typeflag=b"L", gnu=True)
          + member(long_name[:99], disk, gnu=True) + end(), disk, long_name.decode())
    write(d, "pax_path", pax([(b"path", b"real/disk.raw")]) + member(b"placeholder", disk) + end(), disk,
          "real/disk.raw")
    write(d, "pax_size", pax([(b"size", b"%d" % len(disk))])
          + header(b"disk.raw", 0, size_field=octal(0, 12)) + pad(disk) + end(), disk, "disk.raw")
    write(d, "base256_size", header(b"disk.raw", len(disk), size_field=base256(len(disk), 12)) + pad(disk)
          + end(), disk, "disk.raw")
    # Some writers end with a single zero block, or none at all.
    write(d, "no_end_blocks", member(b"disk.raw", disk), disk, "disk.raw")

    segs = [(0, 4096), (1 << 20, 10_000), (3 << 20, 1), ((5 << 20) - 512, 512)]
    realsize = 5 << 20
    img = sparse_image(realsize, segs, rnd)
    write(d, "gnu_sparse", readme + gnu_sparse(b"disk.raw", realsize, segs, img) + end(), img, "disk.raw")

    many = [(i * 65536, 100 + i) for i in range(30)]  # 4 in the header + 21 + 5 in two extension blocks
    rs2 = 31 * 65536
    img2 = sparse_image(rs2, many, rnd)
    write(d, "gnu_sparse_ext", gnu_sparse(b"disk.raw", rs2, many, img2) + end(), img2, "disk.raw")

    trailing_hole = [(0, 1000)]
    img3 = sparse_image(8 << 20, trailing_hole, rnd)
    write(d, "gnu_sparse_hole_end", gnu_sparse(b"disk.raw", 8 << 20, trailing_hole, img3) + end(), img3,
          "disk.raw")

    write(d, "pax_sparse", readme + pax_sparse_1_0(b"disk.raw", realsize, segs, img) + end(), img, "disk.raw")

    # End to end through xz.
    with open(os.path.join(d, "tar_sparse_xz.tar.xz"), "wb") as f:
        f.write(lzma.compress(gnu_sparse(b"disk.raw", realsize, segs, img) + end(), check=lzma.CHECK_CRC64))
    with open(os.path.join(d, "tar_sparse_xz.out"), "wb") as f:
        f.write(img)

    # Invalid
    good = member(b"disk.raw", disk) + end()
    bad = bytearray(good)
    bad[0] ^= 0x20
    write(d, "bad_checksum", bytes(bad))
    write(d, "truncated_data", good[:BLOCK + 10_000])
    write(d, "not_found", readme + end())
    write(d, "sparse_overlap", gnu_sparse(b"disk.raw", realsize, [(0, 5000), (4096, 100)], img) + end())
    write(d, "sparse_unordered", gnu_sparse(b"disk.raw", realsize, [(4096, 10), (0, 10)], img) + end())
    write(d, "sparse_beyond_end", gnu_sparse(b"disk.raw", 4096, [(0, 10), (8192, 10)], img) + end())
    lying = bytearray(gnu_sparse(b"disk.raw", realsize, segs, img) + end())
    lying[124:136] = octal(10, 12)  # stored size smaller than the map says
    lying[148:156] = b" " * 8
    lying[148:156] = b"%06o\0 " % sum(lying[:BLOCK])
    write(d, "sparse_size_mismatch", bytes(lying))
    write(d, "bad_octal", header(b"disk.raw", 0, size_field=b"12345678z01\0") + end())


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
