/*
 * mnd_qcow2.c — qcow2 -> sparse raw converter.
 * Format reference: https://gitlab.com/qemu-project/qemu/-/blob/master/docs/interop/qcow2.txt
 */
#include "mnd_qcow2.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#define QCOW_MAGIC 0x514649fbu
#define L1E_OFFSET_MASK 0x00fffffffffffe00ull
#define L2E_OFFSET_MASK 0x00fffffffffffe00ull
#define L2E_COMPRESSED (1ull << 62)
#define L2E_ZERO 1ull
#define INCOMPAT_DIRTY (1ull << 0)
#define INCOMPAT_CORRUPT (1ull << 1)
#define INCOMPAT_DATA_FILE (1ull << 2)
#define INCOMPAT_COMPRESSION (1ull << 3)
#define INCOMPAT_EXTL2 (1ull << 4)
#define MAX_VIRTUAL_SIZE (4ull << 40) /* 4 TiB */

static _Thread_local char g_err[256];

static int fail(int code, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_err, sizeof g_err, fmt, ap);
    va_end(ap);
    return code;
}

const char *mnd_qcow2_last_error(void) { return g_err; }

static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static uint64_t be64(const uint8_t *p) { return ((uint64_t)be32(p) << 32) | be32(p + 4); }

typedef struct {
    uint32_t version;
    uint32_t cluster_bits;
    uint64_t size;
    uint32_t l1_size;
    uint64_t l1_offset;
    uint64_t file_size;
} header;

static int read_exact(int fd, void *buf, size_t n, uint64_t off) {
    uint8_t *p = buf;
    size_t done = 0;
    while (done < n) {
        ssize_t r = pread(fd, p + done, n - done, (off_t)(off + done));
        if (r < 0) {
            if (errno == EINTR) continue;
            return errno;
        }
        if (r == 0) return EIO; /* truncated file */
        done += (size_t)r;
    }
    return 0;
}

static int write_exact(int fd, const void *buf, size_t n, uint64_t off) {
    const uint8_t *p = buf;
    size_t done = 0;
    while (done < n) {
        ssize_t w = pwrite(fd, p + done, n - done, (off_t)(off + done));
        if (w < 0) {
            if (errno == EINTR) continue;
            return errno;
        }
        done += (size_t)w;
    }
    return 0;
}

static int parse_header(int fd, header *h) {
    struct stat st;
    if (fstat(fd, &st) != 0) return fail(errno, "stat failed: %s", strerror(errno));
    h->file_size = (uint64_t)st.st_size;

    uint8_t b[112];
    memset(b, 0, sizeof b);
    if (h->file_size < 72) return fail(EINVAL, "file too small to be qcow2");
    size_t want = h->file_size < sizeof b ? (size_t)h->file_size : sizeof b;
    int e = read_exact(fd, b, want, 0);
    if (e) return fail(EIO, "cannot read header");
    if (be32(b) != QCOW_MAGIC) return fail(EINVAL, "not a qcow2 image");

    h->version = be32(b + 4);
    if (h->version != 2 && h->version != 3) return fail(ENOTSUP, "unsupported qcow2 version %u", h->version);
    if (be64(b + 8) != 0 || be32(b + 16) != 0) return fail(ENOTSUP, "backing files are not supported");
    h->cluster_bits = be32(b + 20);
    if (h->cluster_bits < 9 || h->cluster_bits > 21) return fail(EINVAL, "invalid cluster size");
    h->size = be64(b + 24);
    if (h->size == 0 || h->size > MAX_VIRTUAL_SIZE) return fail(EINVAL, "invalid virtual size");
    if (be32(b + 32) != 0) return fail(ENOTSUP, "encrypted images are not supported");
    h->l1_size = be32(b + 36);
    h->l1_offset = be64(b + 40);

    if (h->version >= 3) {
        uint64_t incompat = be64(b + 72);
        uint32_t hdr_len = be32(b + 100);
        if (incompat & INCOMPAT_CORRUPT) return fail(EINVAL, "image is marked corrupt");
        if (incompat & INCOMPAT_DATA_FILE) return fail(ENOTSUP, "external data files are not supported");
        if (incompat & INCOMPAT_EXTL2) return fail(ENOTSUP, "extended L2 entries are not supported");
        if (incompat & INCOMPAT_COMPRESSION) {
            if (hdr_len <= 104 || want <= 104 || b[104] != 0)
                return fail(ENOTSUP, "only zlib compression is supported");
        }
        uint64_t known = INCOMPAT_DIRTY | INCOMPAT_COMPRESSION;
        if (incompat & ~(known | INCOMPAT_CORRUPT | INCOMPAT_DATA_FILE | INCOMPAT_EXTL2))
            return fail(ENOTSUP, "unknown incompatible features 0x%llx", (unsigned long long)incompat);
    }

    uint64_t cluster = 1ull << h->cluster_bits;
    uint64_t l2_entries = cluster / 8;
    uint64_t clusters = (h->size + cluster - 1) / cluster;
    uint64_t need_l1 = (clusters + l2_entries - 1) / l2_entries;
    if (h->l1_size < need_l1) return fail(EINVAL, "L1 table too small for virtual size");
    if (h->l1_size > need_l1 + 1024 || (uint64_t)h->l1_size * 8 > (64ull << 20))
        return fail(EINVAL, "L1 table unreasonably large");
    if (h->l1_offset % cluster != 0 || h->l1_offset + (uint64_t)h->l1_size * 8 > h->file_size)
        return fail(EINVAL, "L1 table out of bounds");
    return 0;
}

int mnd_qcow2_probe(const char *path, mnd_qcow2_info *info) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return fail(errno, "cannot open %s: %s", path, strerror(errno));
    header h;
    int e = parse_header(fd, &h);
    close(fd);
    if (e) return e;
    if (info) {
        info->virtual_size = h.size;
        info->cluster_size = 1u << h.cluster_bits;
        info->version = h.version;
    }
    return 0;
}

static bool all_zero(const uint8_t *p, size_t n) {
    /* Word-at-a-time scan; clusters are always 8-byte multiples. */
    const uint64_t *w = (const uint64_t *)(const void *)p;
    for (size_t i = 0; i < n / 8; i++)
        if (w[i]) return false;
    return true;
}

static int inflate_cluster(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_len) {
    z_stream zs;
    memset(&zs, 0, sizeof zs);
    if (inflateInit2(&zs, -12) != Z_OK) return fail(ENOMEM, "zlib init failed");
    zs.next_in = (Bytef *)(uintptr_t)in;
    zs.avail_in = (uInt)in_len;
    zs.next_out = out;
    zs.avail_out = (uInt)out_len;
    int r = inflate(&zs, Z_FINISH);
    size_t produced = out_len - zs.avail_out;
    inflateEnd(&zs);
    /* qcow2 compressed data may be followed by padding: Z_BUF_ERROR with a
     * full output buffer is acceptable. */
    if ((r == Z_STREAM_END || r == Z_BUF_ERROR || r == Z_OK) && produced == out_len) return 0;
    return fail(EIO, "corrupt compressed cluster (zlib %d)", r);
}

int mnd_qcow2_to_raw(const char *src, const char *dst, mnd_qcow2_progress progress, void *ctx) {
    int in = open(src, O_RDONLY | O_CLOEXEC);
    if (in < 0) return fail(errno, "cannot open %s: %s", src, strerror(errno));
    header h;
    int e = parse_header(in, &h);
    if (e) {
        close(in);
        return e;
    }

    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (out < 0) {
        e = errno;
        close(in);
        return fail(e, "cannot create %s: %s", dst, strerror(e));
    }

    const uint64_t cluster = 1ull << h.cluster_bits;
    const uint64_t l2_entries = cluster / 8;
    const uint64_t clusters_total = (h.size + cluster - 1) / cluster;
    const unsigned csize_shift = 62 - (h.cluster_bits - 8);
    const uint64_t coff_mask = (1ull << csize_shift) - 1;

    uint64_t *l1 = malloc((size_t)h.l1_size * 8);
    uint8_t *l2raw = malloc(cluster);
    uint8_t *data = malloc(cluster);
    uint8_t *cbuf = malloc(cluster * 2 + 512);
    if (!l1 || !l2raw || !data || !cbuf) {
        e = fail(ENOMEM, "out of memory");
        goto done;
    }
    if (ftruncate(out, (off_t)h.size) != 0) {
        e = fail(errno, "cannot size output: %s", strerror(errno));
        goto done;
    }
    if ((e = read_exact(in, l1, (size_t)h.l1_size * 8, h.l1_offset)) != 0) {
        e = fail(EIO, "cannot read L1 table");
        goto done;
    }

    uint64_t done_clusters = 0;
    for (uint64_t i = 0; i < h.l1_size; i++) {
        uint64_t first = i * l2_entries;
        if (first >= clusters_total) break;
        uint64_t count = clusters_total - first < l2_entries ? clusters_total - first : l2_entries;
        uint64_t l2_off = be64((const uint8_t *)&l1[i]) & L1E_OFFSET_MASK;

        if (l2_off != 0) {
            if (l2_off % cluster != 0 || l2_off + cluster > h.file_size) {
                e = fail(EINVAL, "L2 table %llu out of bounds", (unsigned long long)i);
                goto done;
            }
            if ((e = read_exact(in, l2raw, cluster, l2_off)) != 0) {
                e = fail(EIO, "cannot read L2 table");
                goto done;
            }
            for (uint64_t j = 0; j < count; j++) {
                uint64_t ent = be64(l2raw + j * 8);
                uint64_t vofs = (first + j) * cluster;
                size_t len = (size_t)(h.size - vofs < cluster ? h.size - vofs : cluster);

                if (ent & L2E_COMPRESSED) {
                    uint64_t hofs = ent & coff_mask;
                    uint64_t sectors = ((ent & ~L2E_COMPRESSED & ~(1ull << 63)) >> csize_shift) + 1;
                    uint64_t clen = sectors * 512 - (hofs & 511);
                    if (hofs >= h.file_size) {
                        e = fail(EINVAL, "compressed cluster out of bounds");
                        goto done;
                    }
                    if (clen > cluster * 2 + 512) clen = cluster * 2 + 512;
                    if (hofs + clen > h.file_size) clen = h.file_size - hofs;
                    if ((e = read_exact(in, cbuf, (size_t)clen, hofs)) != 0) {
                        e = fail(EIO, "cannot read compressed cluster");
                        goto done;
                    }
                    if ((e = inflate_cluster(cbuf, (size_t)clen, data, cluster)) != 0) goto done;
                } else {
                    uint64_t hofs = ent & L2E_OFFSET_MASK;
                    if ((ent & L2E_ZERO) || hofs == 0) continue; /* reads as zero: keep the hole */
                    if (hofs % cluster != 0 || hofs + len > h.file_size) {
                        e = fail(EINVAL, "data cluster out of bounds");
                        goto done;
                    }
                    if ((e = read_exact(in, data, len, hofs)) != 0) {
                        e = fail(EIO, "cannot read data cluster");
                        goto done;
                    }
                    if (len < cluster) memset(data + len, 0, cluster - len);
                }
                if (all_zero(data, (size_t)cluster)) continue;
                if ((e = write_exact(out, data, len, vofs)) != 0) {
                    e = fail(e, "write failed: %s", strerror(e));
                    goto done;
                }
            }
        }
        done_clusters += count;
        if (progress && !progress(ctx, done_clusters * cluster > h.size ? h.size : done_clusters * cluster, h.size)) {
            e = fail(ECANCELED, "cancelled");
            goto done;
        }
    }
    if (fsync(out) != 0) {
        e = fail(errno, "fsync failed: %s", strerror(errno));
        goto done;
    }
    e = 0;

done:
    free(l1);
    free(l2raw);
    free(data);
    free(cbuf);
    close(in);
    if (close(out) != 0 && e == 0) e = fail(errno, "close failed");
    if (e) unlink(dst);
    return e;
}
