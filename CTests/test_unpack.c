/* Tests for mnd_unpack: a compressed disk image (.xz, .gz) into a sparse file.
 * xz input comes from gen_xz_fixtures.py; gzip input is written here. */
#include "../Monad/Backend/mnd_unpack.h"
#include "test_util.h"

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

static const char *g_dir = ".";
static const uint64_t LIMIT = 32u << 20;

static unsigned char *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *b = malloc((size_t)n + 1);
    if (fread(b, 1, (size_t)n, f) != (size_t)n) {
        free(b);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *len = (size_t)n;
    return b;
}

static void path(char *out, size_t n, const char *name) { snprintf(out, n, "%s/%s", g_dir, name); }

static bool fs_supports_holes(void) {
    char p[512];
    path(p, sizeof p, "unpack_probe");
    int fd = open(p, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    bool ok = false;
    if (fd >= 0 && ftruncate(fd, 8 << 20) == 0 && pwrite(fd, "x", 1, (8 << 20) - 1) == 1) {
        struct stat st;
        fsync(fd);
        ok = fstat(fd, &st) == 0 && (uint64_t)st.st_blocks * 512 < (4u << 20);
    }
    if (fd >= 0) close(fd);
    unlink(p);
    return ok;
}

/* A disk-like payload: data, a long run of zeros, data again. */
static unsigned char *payload(size_t *len) {
    size_t n = (64u << 10) + (1u << 20) + 5000;
    unsigned char *b = calloc(1, n);
    for (size_t i = 0; i < (64u << 10); i++) b[i] = (unsigned char)(i * 7 + 1);
    for (size_t i = n - 5000; i < n; i++) b[i] = (unsigned char)(i * 13 + 3);
    *len = n;
    return b;
}

/* `parts` gzip members, concatenated, holding `data` split between them. */
static void write_gzip(const char *file, const unsigned char *data, size_t len, int parts) {
    FILE *out = fopen(file, "wb");
    size_t per = len / (size_t)parts;
    for (int p = 0; p < parts; p++) {
        size_t from = per * (size_t)p, n = p == parts - 1 ? len - from : per;
        uLongf cap = compressBound(n) + 64;
        unsigned char *z = malloc(cap);
        z_stream s;
        memset(&s, 0, sizeof s);
        deflateInit2(&s, 6, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY);
        s.next_in = (Bytef *)(data + from);
        s.avail_in = (uInt)n;
        s.next_out = z;
        s.avail_out = (uInt)cap;
        deflate(&s, Z_FINISH);
        fwrite(z, 1, s.total_out, out);
        deflateEnd(&s);
        free(z);
    }
    fclose(out);
}

static void expect_same(const char *file, const unsigned char *exp, size_t len) {
    size_t n = 0;
    unsigned char *got = slurp(file, &n);
    CHECK(got != NULL);
    if (got) CHECK_MEM(got, n, exp, len);
    free(got);
}

static uint64_t g_last_done, g_total;
static bool record(void *ctx, uint64_t done, uint64_t total) {
    (void)ctx;
    g_last_done = done;
    g_total = total;
    return true;
}

static void test_xz(void) {
    char in[512], out[512], exp_path[512];
    path(in, sizeof in, "xz_multiblock.xz");
    path(out, sizeof out, "unpack_xz.out");
    path(exp_path, sizeof exp_path, "xz_multiblock.out");
    g_last_done = g_total = 0;
    CHECK(mnd_unpack(in, out, MND_UNPACK_XZ, LIMIT, record, NULL) == 0);
    size_t el;
    unsigned char *exp = slurp(exp_path, &el);
    expect_same(out, exp, el);
    struct stat st;
    CHECK(stat(out, &st) == 0 && (st.st_mode & 0777) == 0600);
    CHECK(stat(in, &st) == 0 && g_total == (uint64_t)st.st_size && g_last_done == g_total);
    free(exp);
    unlink(out);
}

static void test_gzip_with_holes(void) {
    size_t len;
    unsigned char *data = payload(&len);
    char in[512], out[512];
    path(in, sizeof in, "unpack.gz");
    path(out, sizeof out, "unpack_gz.out");
    write_gzip(in, data, len, 1);
    CHECK(mnd_unpack(in, out, MND_UNPACK_GZIP, LIMIT, NULL, NULL) == 0);
    expect_same(out, data, len);
    if (fs_supports_holes()) {
        struct stat st;
        CHECK(stat(out, &st) == 0 && (uint64_t)st.st_blocks * 512 < (512u << 10));
    }
    unlink(out);

    /* Concatenated members are one stream, as gzip reads them. */
    write_gzip(in, data, len, 3);
    CHECK(mnd_unpack(in, out, MND_UNPACK_GZIP, LIMIT, NULL, NULL) == 0);
    expect_same(out, data, len);
    unlink(out);
    unlink(in);
    free(data);
}

static void expect_failure(const char *in, int kind, int code) {
    char out[512];
    path(out, sizeof out, "unpack_fail.out");
    int rc = mnd_unpack(in, out, kind, LIMIT, NULL, NULL);
    CHECK(rc == code);
    if (rc != code) fprintf(stderr, "    got %d (%s)\n", rc, mnd_unpack_last_error());
    CHECK(strlen(mnd_unpack_last_error()) > 0);
    CHECK(access(out, F_OK) != 0);
}

static void test_failures(void) {
    char in[512];
    path(in, sizeof in, "xz_corrupt_data.xz");
    expect_failure(in, MND_UNPACK_XZ, EINVAL);

    /* Not gzip at all (zlib would copy it through). */
    path(in, sizeof in, "xz_multiblock.xz");
    expect_failure(in, MND_UNPACK_GZIP, EINVAL);

    /* A gzip file cut short. */
    size_t len;
    unsigned char *data = payload(&len);
    path(in, sizeof in, "unpack_cut.gz");
    write_gzip(in, data, len, 1);
    size_t zl;
    unsigned char *z = slurp(in, &zl);
    FILE *f = fopen(in, "wb");
    fwrite(z, 1, zl / 2, f);
    fclose(f);
    expect_failure(in, MND_UNPACK_GZIP, EINVAL);

    /* A corrupt gzip body. */
    z[zl / 2] ^= 0x55;
    z[zl / 2 + 1] ^= 0xAA;
    f = fopen(in, "wb");
    fwrite(z, 1, zl, f);
    fclose(f);
    expect_failure(in, MND_UNPACK_GZIP, EINVAL);
    unlink(in);
    free(z);
    free(data);

    path(in, sizeof in, "unpack_missing.gz");
    expect_failure(in, MND_UNPACK_GZIP, ENOENT);
    path(in, sizeof in, "xz_multiblock.xz");
    expect_failure(in, 42, EINVAL);
}

static bool stop(void *ctx, uint64_t done, uint64_t total) {
    (void)ctx;
    (void)done;
    (void)total;
    return false;
}

static void test_cancel_and_replace(void) {
    char in[512], out[512];
    path(in, sizeof in, "xz_multiblock.xz");
    path(out, sizeof out, "unpack_cancel.out");
    FILE *f = fopen(out, "wb");
    fputs("old", f);
    fclose(f);
    CHECK(mnd_unpack(in, out, MND_UNPACK_XZ, LIMIT, stop, NULL) == ECANCELED);
    CHECK(access(out, F_OK) != 0);
    f = fopen(out, "wb");
    fputs("old", f);
    fclose(f);
    CHECK(mnd_unpack(in, out, MND_UNPACK_XZ, LIMIT, NULL, NULL) == 0);
    struct stat st;
    CHECK(stat(out, &st) == 0 && st.st_size > 3);
    unlink(out);
}

int main(int argc, char **argv) {
    if (argc > 1) g_dir = argv[1];
    fprintf(stderr, "test_unpack\n");
    RUN(test_xz);
    RUN(test_gzip_with_holes);
    RUN(test_failures);
    RUN(test_cancel_and_replace);
    TEST_MAIN_END();
}
