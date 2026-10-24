#!/usr/bin/env python3
"""Write qcow2 fixtures plus their expected raw contents for test_qcow2.

Independent from the C reader: builds images byte-by-byte from the spec with
a mix of plain, zlib-compressed, zero-flagged and unallocated clusters.
Usage: gen_qcow2_fixture.py OUTDIR
"""
import os
import random
import struct
import sys
import zlib


def build(path_qcow, path_raw, version, cluster_bits, vsize, seed):
    rnd = random.Random(seed)
    cs = 1 << cluster_bits
    l2_entries = cs // 8
    nclusters = (vsize + cs - 1) // cs
    l1_size = (nclusters + l2_entries - 1) // l2_entries

    raw = bytearray(vsize)
    # Layout: header cluster, L1 cluster(s), L2 tables, then data.
    l1_clusters = max(1, (l1_size * 8 + cs - 1) // cs)
    next_off = cs * (1 + l1_clusters)
    l1 = [0] * l1_size
    l2_tables = {}
    blobs = []  # (offset, bytes)

    def alloc(n, align=cs):
        nonlocal next_off
        next_off = (next_off + align - 1) // align * align
        off = next_off
        next_off += n
        return off

    for c in range(nclusters):
        l1i, l2i = divmod(c, l2_entries)
        if l1i == 1:
            continue  # whole L2 range unallocated
        kind = rnd.choice(["plain", "comp", "zero", "none", "plain", "comp"])
        length = min(cs, vsize - c * cs)
        if kind == "none":
            continue
        if l1i not in l2_tables:
            l2_tables[l1i] = [0] * l2_entries
        if kind == "zero":
            if version < 3:
                continue
            l2_tables[l1i][l2i] = 1  # zero flag, no host cluster
            # stale data at a bogus offset must be ignored: fill raw with zeros
            continue
        # compressible payload with a pattern plus some randomness
        pat = bytes([rnd.randrange(256)]) * 16 + bytes(rnd.randrange(4) for _ in range(16))
        data = (pat * (cs // len(pat) + 1))[:cs]
        if c == nclusters - 1 and length < cs:
            data = data[:length] + bytes(cs - length)
        raw[c * cs:c * cs + length] = data[:length]
        if kind == "plain":
            off = alloc(cs)
            blobs.append((off, data))
            l2_tables[l1i][l2i] = off | (1 << 63)
        else:
            co = zlib.compressobj(9, zlib.DEFLATED, -12)
            comp = co.compress(data) + co.flush()
            x = 62 - (cluster_bits - 8)
            off = alloc(len(comp), 512)
            sectors = (off % 512 + len(comp) + 511) // 512
            if sectors - 1 >= (1 << (62 - x)):
                # does not fit the size field: store plain instead
                off = alloc(cs)
                blobs.append((off, data))
                l2_tables[l1i][l2i] = off | (1 << 63)
                continue
            blobs.append((off, comp))
            l2_tables[l1i][l2i] = (1 << 62) | ((sectors - 1) << x) | off

    for l1i, table in sorted(l2_tables.items()):
        off = alloc(cs)
        blobs.append((off, b"".join(struct.pack(">Q", e) for e in table)))
        l1[l1i] = off | (1 << 63)

    hdr = bytearray(cs)
    struct.pack_into(">IIQIIQIIQQIIQ", hdr, 0,
                     0x514649FB, version, 0, 0, cluster_bits, vsize, 0,
                     l1_size, cs, 0, 0, 0, 0)
    if version == 3:
        struct.pack_into(">QQQII", hdr, 72, 0, 0, 0, 4, 104)

    img = bytearray(next_off)
    img[0:cs] = hdr
    for i, e in enumerate(l1):
        struct.pack_into(">Q", img, cs + i * 8, e)
    for off, b in blobs:
        img[off:off + len(b)] = b
    with open(path_qcow, "wb") as f:
        f.write(img)
    with open(path_raw, "wb") as f:
        f.write(raw)


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    build(f"{out}/fx_v3_512.qcow2", f"{out}/fx_v3_512.raw", 3, 9, 100 * 1024 + 300, 1)
    build(f"{out}/fx_v2_512.qcow2", f"{out}/fx_v2_512.raw", 2, 9, 70 * 1024, 2)
    build(f"{out}/fx_v3_64k.qcow2", f"{out}/fx_v3_64k.raw", 3, 16, 3 * 1024 * 1024 + 17, 3)


if __name__ == "__main__":
    main()
