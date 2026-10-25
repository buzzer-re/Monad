/*
 * fuzz_decoders.c — fuzz the image decoders (F-19): mnd_xz, mnd_tar,
 * mnd_qcow2 and mnd_unpack (.xz and .gz images) get mutated copies of the test fixtures (flipped bytes,
 * overwritten spans, cuts, splices) and random bytes. They only see
 * verified data in Monad today; this keeps them safe if that ever changes.
 * mnd_diskcheck reads what a guest wrote to its own disk, so it gets the
 * disk fixtures with their regions mutated the same way, and odd sizes.
 *
 * Invariants: no crash or sanitizer report; output stays within what was
 * asked for; on failure tar, qcow2 and unpack leave no output file; a disk
 * report stays within the disk, its bounds and printable text.
 *
 *   fuzz_decoders <build dir> [iterations] [seed]
 */
#include "../Monad/Backend/mnd_diskcheck.h"
#include "../Monad/Backend/mnd_qcow2.h"
#include "../Monad/Backend/mnd_tar.h"
#include "../Monad/Backend/mnd_unpack.h"
#include "../Monad/Backend/mnd_xz.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

static void fail(const char *what) {
    fprintf(stderr, "fuzz_decoders: invariant broken: %s\n", what);
    abort();
}

static uint64_t rng_state;

static uint32_t rnd(void) {
    rng_state = rng_state * 6364136223846793005ull + 1442695040888963407ull;
    return (uint32_t)(rng_state >> 33);
}

typedef struct {
    uint8_t *data;
    size_t len;
} blob;

static blob load(const char *dir, const char *name) {
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    blob b = {0};
    FILE *f = fopen(path, "rb");
    if (!f) return b;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n > 0 && n < (64 << 20)) {
        b.data = malloc((size_t)n);
        if (b.data && fread(b.data, 1, (size_t)n, f) == (size_t)n) {
            b.len = (size_t)n;
        } else {
            free(b.data);
            b.data = NULL;
        }
    }
    fclose(f);
    return b;
}

/* A mutated copy of one of the seeds (or random bytes). Caller frees. */
static blob mutate(const blob *seeds, int nseeds) {
    blob out = {0};
    const blob *s = nseeds ? &seeds[rnd() % (unsigned)nseeds] : NULL;
    if (!s || !s->len || rnd() % 16 == 0) {
        out.len = 1 + rnd() % 4096;
        out.data = malloc(out.len);
        for (size_t i = 0; i < out.len; i++) out.data[i] = (uint8_t)rnd();
        return out;
    }
    out.len = s->len;
    out.data = malloc(out.len + 4096);
    memcpy(out.data, s->data, out.len);
    for (unsigned m = 0, k = 1 + rnd() % 8; m < k; m++) {
        size_t at = rnd() % out.len;
        switch (rnd() % 6) {
        case 0: out.data[at] ^= (uint8_t)(1u << (rnd() % 8)); break;
        case 1: out.data[at] = (uint8_t)rnd(); break;
        case 2: /* a span of one value: 0, 0xff or random */
            for (size_t i = at, e = at + rnd() % 64; i < e && i < out.len; i++)
                out.data[i] = (uint8_t)(rnd() % 3 == 0 ? 0 : rnd() % 2 ? 0xff : rnd());
            break;
        case 3: out.len = at ? at : 1; break; /* cut */
        case 4: { /* copy a span from elsewhere */
            size_t from = rnd() % out.len, n = rnd() % 256;
            if (from + n > out.len) n = out.len - from;
            if (at + n > out.len) n = out.len - at;
            memmove(out.data + at, out.data + from, n);
            break;
        }
        default: { /* a 32- or 64-bit field set to an edge value */
            static const uint64_t edges[] = {0, 1, 0x7fffffff, 0x80000000, 0xffffffff, 0xffffffffffffffffull,
                                             0x7fffffffffffffffull, 512, 65536, 1u << 31};
            uint64_t v = edges[rnd() % (sizeof edges / sizeof edges[0])];
            size_t w = rnd() % 2 ? 4 : 8;
            for (size_t i = 0; i < w && at + i < out.len; i++) out.data[at + i] = (uint8_t)(v >> (8 * (w - 1 - i)));
            break;
        }
        }
    }
    return out;
}

/* ---- xz ------------------------------------------------------------------------- */

static void fuzz_xz(const blob *in) {
    mnd_xz *d = mnd_xz_new(16u << 20);
    if (!d) fail("no xz decoder");
    static uint8_t out[1 << 16];
    size_t pos = 0;
    uint64_t total = 0;
    for (int step = 0; step < 100000; step++) {
        /* Input in small pieces, so every state is entered at a boundary. */
        size_t chunk = 1 + rnd() % 512, used = 0, written = 0;
        if (chunk > in->len - pos) chunk = in->len - pos;
        bool finish = pos + chunk == in->len;
        size_t room = 1 + rnd() % sizeof out;
        int r = mnd_xz_run(d, in->data + pos, chunk, &used, out, room, &written, finish);
        if (used > chunk || written > room) fail("xz used or wrote more than it was given");
        pos += used;
        total += written;
        if (r != MND_XZ_OK || total > (256u << 20)) break;
        if (!used && !written && finish) fail("xz made no progress at the end of its input");
    }
    (void)mnd_xz_error(d);
    mnd_xz_free(d);
}

/* ---- tar -------------------------------------------------------------------------- */

typedef struct {
    const blob *b;
    size_t pos;
} mem_reader;

static ssize_t read_mem(void *ctx, void *buf, size_t n) {
    mem_reader *m = ctx;
    size_t left = m->b->len - m->pos, piece = 1 + rnd() % 4096; /* short reads */
    if (n > left) n = left;
    if (n > piece) n = piece;
    memcpy(buf, m->b->data + m->pos, n);
    m->pos += n;
    return (ssize_t)n;
}

static bool bounded(void *ctx, uint64_t done, uint64_t total) {
    (void)ctx;
    (void)total;
    return done < (64u << 20); /* a member larger than this is cancelled */
}

static void fuzz_tar(const blob *in, const char *dst) {
    mem_reader m = {in, 0};
    uint64_t size = 0;
    static const char *const patterns[] = {"*", "disk.raw", "*.raw", "a/*"};
    int r = mnd_tar_extract(read_mem, &m, patterns[rnd() % 4], dst, bounded, NULL, &size);
    struct stat st;
    bool exists = stat(dst, &st) == 0;
    if (r != 0 && exists) fail("a failed tar extraction left its output");
    if (r == 0 && (!exists || (uint64_t)st.st_size != size)) fail("tar output differs from the size it reported");
    unlink(dst);
}

/* ---- qcow2 ------------------------------------------------------------------------ */

static int qcow2_calls;

static bool few_calls(void *ctx, uint64_t done, uint64_t total) {
    (void)ctx;
    (void)done;
    (void)total;
    return ++qcow2_calls < 4096;
}

static void fuzz_qcow2(const blob *in, const char *src, const char *dst) {
    int fd = open(src, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) fail("cannot write the qcow2 input");
    if (write(fd, in->data, in->len) != (ssize_t)in->len) fail("short write");
    close(fd);
    mnd_qcow2_info info;
    if (mnd_qcow2_probe(src, &info) == 0 && info.virtual_size <= (1ull << 30)) {
        qcow2_calls = 0;
        int r = mnd_qcow2_to_raw(src, dst, few_calls, NULL);
        struct stat st;
        bool exists = stat(dst, &st) == 0;
        if (r != 0 && exists) fail("a failed qcow2 conversion left its output");
        if (r == 0 && (uint64_t)st.st_size != info.virtual_size) fail("raw output is not the virtual size");
        unlink(dst);
    }
    (void)mnd_qcow2_last_error();
    unlink(src);
}

/* A gzip seed: a few members of disk-like data. */
static blob gzip_seed(void) {
    blob b = {0};
    uint8_t data[8192];
    for (size_t i = 0; i < sizeof data; i++) data[i] = i < 4096 ? 0 : (uint8_t)(i * 31);
    b.data = malloc(2 * compressBound(sizeof data) + 64);
    for (int m = 0; m < 2; m++) {
        z_stream s;
        memset(&s, 0, sizeof s);
        if (deflateInit2(&s, 6, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) fail("deflateInit2");
        s.next_in = data;
        s.avail_in = sizeof data;
        s.next_out = b.data + b.len;
        s.avail_out = (uInt)(compressBound(sizeof data) + 32);
        if (deflate(&s, Z_FINISH) != Z_STREAM_END) fail("deflate");
        b.len += s.total_out;
        deflateEnd(&s);
    }
    return b;
}

static void fuzz_unpack(const blob *in, int kind, const char *src, const char *dst) {
    int fd = open(src, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) fail("cannot write the unpack input");
    if (write(fd, in->data, in->len) != (ssize_t)in->len) fail("short write");
    close(fd);
    int r = mnd_unpack(src, dst, kind, 8u << 20, NULL, NULL);
    struct stat st;
    bool exists = stat(dst, &st) == 0;
    if (r != 0 && exists) fail("a failed unpack left its output");
    if (r == 0 && !exists) fail("a finished unpack has no output");
    (void)mnd_unpack_last_error();
    unlink(dst);
    unlink(src);
}

/* ---- disks ------------------------------------------------------------------------ */

/* A disk fixture from gen_disk_fixtures.py: its size and regions; the rest
 * reads as zeros. */
typedef struct {
    uint64_t size;
    int count;
    uint64_t off[64];
    blob data[64];
} vdisk;

static uint64_t le(const uint8_t *p, int n) {
    uint64_t v = 0;
    for (int i = n - 1; i >= 0; i--) v = v << 8 | p[i];
    return v;
}

static vdisk disk_seed(const char *dir, const char *name) {
    vdisk d = {0};
    blob b = load(dir, name);
    if (b.len < 20 || memcmp(b.data, "MNDDISK1", 8)) {
        free(b.data);
        return d;
    }
    d.size = le(b.data + 8, 8);
    size_t pos = 20;
    for (uint64_t i = 0, n = le(b.data + 16, 4); i < n && d.count < 64 && pos + 12 <= b.len; i++) {
        uint64_t len = le(b.data + pos + 8, 4);
        if (len > b.len - pos - 12) break;
        d.off[d.count] = le(b.data + pos, 8);
        d.data[d.count].data = malloc(len ? len : 1);
        memcpy(d.data[d.count].data, b.data + pos + 12, len);
        d.data[d.count].len = len;
        d.count++;
        pos += 12 + len;
    }
    free(b.data);
    return d;
}

static int read_disk(void *ctx, uint64_t off, void *buf, size_t len) {
    const vdisk *d = ctx;
    if (off > d->size || len > d->size - off) fail("diskcheck read outside the disk it was given");
    if (len > (4u << 20)) fail("diskcheck asked for more than 4 MiB at once");
    memset(buf, 0, len);
    for (int i = 0; i < d->count; i++) {
        uint64_t a = off > d->off[i] ? off : d->off[i];
        uint64_t e = d->off[i] + d->data[i].len, b = off + len < e ? off + len : e;
        if (a < b) memcpy((uint8_t *)buf + (a - off), d->data[i].data + (a - d->off[i]), (size_t)(b - a));
    }
    return rnd() % 512 == 0 ? -1 : 0; /* now and then a read fails */
}

static void printable(const char *s, size_t cap) {
    size_t n = strnlen(s, cap);
    if (n == cap) fail("diskcheck text is not terminated");
    for (size_t i = 0; i < n; i++)
        if (s[i] < 0x20 || s[i] > 0x7e) fail("diskcheck text is not printable");
}

static void fuzz_disk(const vdisk *seeds, int nseeds) {
    const vdisk *s = &seeds[rnd() % (unsigned)nseeds];
    vdisk d = *s;
    for (int i = 0; i < d.count; i++) d.data[i] = (blob){0};
    for (int i = 0; i < d.count; i++) {
        if (rnd() % 3 == 0) {
            d.data[i] = mutate(&s->data[i], 1);
        } else {
            d.data[i].len = s->data[i].len;
            d.data[i].data = malloc(d.data[i].len ? d.data[i].len : 1);
            memcpy(d.data[i].data, s->data[i].data, d.data[i].len);
        }
        if (rnd() % 64 == 0) d.off[i] ^= (uint64_t)1 << (rnd() % 40);
    }
    if (rnd() % 16 == 0) d.size = rnd() % 8 ? d.size >> (rnd() % 20) : (uint64_t)rnd() << (rnd() % 20);
    mnd_disk_report r;
    int rc = mnd_disk_check(read_disk, &d, d.size, &r);
    if (rc == 0) {
        if (r.count > MND_DISK_MAX_PARTS || (r.gpt == MND_GPT_NONE && r.count != 1)) fail("diskcheck reported too much");
        for (unsigned i = 0; i < r.count; i++) {
            const mnd_disk_part *p = &r.parts[i];
            printable(p->name, sizeof p->name);
            printable(p->label, sizeof p->label);
            printable(p->first_error_func, sizeof p->first_error_func);
            printable(p->last_error_func, sizeof p->last_error_func);
            if (p->first_lba > p->last_lba || p->last_lba >= d.size / 512 + (r.gpt == MND_GPT_NONE))
                fail("diskcheck partition outside the disk");
            if ((p->primary_ok || p->backup_ok) && p->fs == MND_FS_UNKNOWN) fail("diskcheck found nothing yet says it is intact");
            if (p->backup_ok && p->fs == MND_FS_EXT &&
                (p->block_size < 1024 || p->backup_block * p->block_size >= (p->last_lba - p->first_lba + 1) * 512))
                fail("diskcheck backup outside its partition");
        }
    }
    for (int i = 0; i < d.count; i++) free(d.data[i].data);
}

static long number(const char *s, long fallback) {
    char *end;
    long v = s && *s ? strtol(s, &end, 0) : 0;
    return s && *s && !*end ? v : fallback;
}

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : "build";
    long iterations = number(argc > 2 ? argv[2] : NULL, number(getenv("FUZZ_ITERS"), 600));
    rng_state = (uint64_t)number(argc > 3 ? argv[3] : getenv("FUZZ_SEED"), 0x4d4f4e4144);

    static const char *const xz_names[] = {"xz_mixed.xz", "tar_sparse_xz.tar.xz", "xz_bad_check.xz",
                                           "xz_bad_padding.xz"};
    static const char *const tar_names[] = {"tar_plain.tar", "tar_gnu_sparse.tar", "tar_gnu_sparse_ext.tar",
                                            "tar_pax_sparse.tar", "tar_pax_path.tar", "tar_gnu_longname.tar",
                                            "tar_base256_size.tar", "tar_among_others.tar"};
    static const char *const qcow2_names[] = {"fx_v3_512.qcow2", "fx_v2_512.qcow2", "fx_v3_64k.qcow2"};
    blob xz[4], tar[8], qcow2[3];
    int nxz = 0, ntar = 0, nqcow2 = 0;
    for (int i = 0; i < 4; i++) if ((xz[nxz] = load(dir, xz_names[i])).len) nxz++;
    for (int i = 0; i < 8; i++) if ((tar[ntar] = load(dir, tar_names[i])).len) ntar++;
    for (int i = 0; i < 3; i++) if ((qcow2[nqcow2] = load(dir, qcow2_names[i])).len) nqcow2++;
    if (!nxz || !ntar || !nqcow2) {
        fprintf(stderr, "fuzz_decoders: fixtures missing in %s (run make first)\n", dir);
        return 1;
    }
    char tmp[1024], dst[1100], src[1100];
    snprintf(tmp, sizeof tmp, "%s/fuzzdec-XXXXXX", dir);
    if (!mkdtemp(tmp)) fail("no temporary folder");
    snprintf(dst, sizeof dst, "%s/out", tmp);
    snprintf(src, sizeof src, "%s/in.qcow2", tmp);
    char packed[1100];
    snprintf(packed, sizeof packed, "%s/in.packed", tmp);
    blob gz = gzip_seed();
    static const char *const disk_names[] = {"disk_cloud.regions", "disk_zeroed_root.regions", "disk_root_errors.regions",
                                             "disk_others.regions", "disk_bare_ext4.regions", "disk_many.regions",
                                             "disk_gpt_backup.regions"};
    vdisk disks[7];
    int ndisks = 0;
    for (int i = 0; i < 7; i++) if ((disks[ndisks] = disk_seed(dir, disk_names[i])).count) ndisks++;
    if (!ndisks) {
        fprintf(stderr, "fuzz_decoders: disk fixtures missing in %s (run make first)\n", dir);
        return 1;
    }
    for (long it = 0; it < iterations; it++) {
        fuzz_disk(disks, ndisks);
        blob ux = mutate(xz, nxz);
        fuzz_unpack(&ux, MND_UNPACK_XZ, packed, dst);
        free(ux.data);
        blob ug = mutate(&gz, 1);
        fuzz_unpack(&ug, MND_UNPACK_GZIP, packed, dst);
        free(ug.data);
        blob a = mutate(xz, nxz);
        fuzz_xz(&a);
        free(a.data);
        blob t = mutate(tar, ntar);
        fuzz_tar(&t, dst);
        free(t.data);
        blob q = mutate(qcow2, nqcow2);
        fuzz_qcow2(&q, src, dst);
        free(q.data);
    }
    rmdir(tmp);
    for (int i = 0; i < nxz; i++) free(xz[i].data);
    for (int i = 0; i < ntar; i++) free(tar[i].data);
    for (int i = 0; i < nqcow2; i++) free(qcow2[i].data);
    free(gz.data);
    for (int i = 0; i < ndisks; i++)
        for (int k = 0; k < disks[i].count; k++) free(disks[i].data[k].data);
    fprintf(stderr, "fuzz_decoders: %ld rounds of xz, tar, qcow2, unpack and diskcheck, no invariant broken\n", iterations);
    return 0;
}
