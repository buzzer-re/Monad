/* Tests for mnd_tar against fixtures from gen_tar_fixtures.py. */
#include "../Monad/Backend/mnd_tar.h"
#include "../Monad/Backend/mnd_xz.h"
#include "test_util.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *g_dir = ".";

static unsigned char *slurp_path(const char *path, size_t *len) {
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

/* A reader handing out at most `step` bytes per call, to exercise short reads. */
typedef struct {
    int fd;
    size_t step;
} step_reader;

static ssize_t read_steps(void *ctx, void *buf, size_t n) {
    step_reader *r = ctx;
    if (n > r->step) n = r->step;
    return read(r->fd, buf, n);
}

static ssize_t failing_reader(void *ctx, void *buf, size_t n) {
    (void)ctx;
    (void)buf;
    (void)n;
    return -1;
}

static int extract(const char *fixture, const char *pattern, size_t step, uint64_t *size, char *out, size_t outlen) {
    char in[512];
    snprintf(in, sizeof in, "%s/tar_%s.tar", g_dir, fixture);
    snprintf(out, outlen, "%s/tar_%s.extracted", g_dir, fixture);
    unlink(out);
    step_reader r = {open(in, O_RDONLY), step};
    CHECK(r.fd >= 0);
    int e = mnd_tar_extract(read_steps, &r, pattern, out, NULL, NULL, size);
    if (e) fprintf(stderr, "    %s: %s (%s)\n", fixture, strerror(e), mnd_tar_last_error());
    close(r.fd);
    return e;
}

/* Does this file system keep holes? Probe with a file that is all hole. */
static bool fs_supports_holes(void) {
    char p[512];
    snprintf(p, sizeof p, "%s/tar_probe", g_dir);
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

static void expect_extracted(const char *fixture, const char *pattern, bool sparse) {
    size_t steps[] = {SIZE_MAX, 511, 7};
    for (size_t i = 0; i < sizeof steps / sizeof *steps; i++) {
        char out[512], exp_path[512];
        uint64_t size = 0;
        int e = extract(fixture, pattern, steps[i], &size, out, sizeof out);
        CHECK(e == 0);
        snprintf(exp_path, sizeof exp_path, "%s/tar_%s.out", g_dir, fixture);
        size_t el, gl;
        unsigned char *exp = slurp_path(exp_path, &el), *got = slurp_path(out, &gl);
        CHECK(exp && got);
        if (exp && got) CHECK_MEM(got, gl, exp, el);
        CHECK(size == el);
        struct stat st;
        CHECK(stat(out, &st) == 0 && (st.st_mode & 0777) == 0600);
        if (sparse && fs_supports_holes()) {
            if (!((uint64_t)st.st_blocks * 512 < (uint64_t)st.st_size / 2))
                fprintf(stderr, "    %s: %lld of %lld bytes allocated\n", fixture, (long long)st.st_blocks * 512,
                        (long long)st.st_size);
            CHECK((uint64_t)st.st_blocks * 512 < (uint64_t)st.st_size / 2);
        }
        free(exp);
        free(got);
        unlink(out);
    }
}

static void expect_failure(const char *fixture, int code) {
    char out[512];
    uint64_t size;
    int e = extract(fixture, "disk.raw", SIZE_MAX, &size, out, sizeof out);
    if (e != code) fprintf(stderr, "    %s: expected %s, got %s\n", fixture, strerror(code), strerror(e));
    CHECK(e == code);
    CHECK(access(out, F_OK) != 0);
}

static void test_plain_members(void) {
    expect_extracted("plain", "disk.raw", false);
    expect_extracted("among_others", "images/disk.raw", false);
    expect_extracted("dot_slash", "disk.raw", false);
    expect_extracted("gnu_longname", "a/*/disk.raw", false);
    expect_extracted("pax_path", "real/disk.raw", false);
    expect_extracted("pax_size", "disk.raw", false);
    expect_extracted("base256_size", "disk.raw", false);
    expect_extracted("no_end_blocks", "disk.raw", false);
}

static void test_patterns(void) {
    expect_extracted("among_others", "*.raw", false);
    expect_extracted("plain", "*", false);
}

static void test_sparse_members(void) {
    expect_extracted("gnu_sparse", "disk.raw", true);
    expect_extracted("gnu_sparse_ext", "disk.raw", true);
    expect_extracted("gnu_sparse_hole_end", "disk.raw", true);
    expect_extracted("pax_sparse", "disk.raw", true);
}

static void test_zero_runs_in_plain_data_become_holes(void) {
    /* plain: 70 KB of data, 300 KB of zeros, 5 KB of text */
    if (!fs_supports_holes()) return;
    char out[512];
    uint64_t size;
    CHECK(extract("plain", "disk.raw", SIZE_MAX, &size, out, sizeof out) == 0);
    struct stat st;
    CHECK(stat(out, &st) == 0);
    CHECK((uint64_t)st.st_blocks * 512 < 200 * 1024);
    unlink(out);
}

static void test_failures(void) {
    expect_failure("bad_checksum", EINVAL);
    expect_failure("truncated_data", EINVAL);
    expect_failure("not_found", ENOENT);
    expect_failure("sparse_overlap", EINVAL);
    expect_failure("sparse_unordered", EINVAL);
    expect_failure("sparse_beyond_end", EINVAL);
    expect_failure("sparse_size_mismatch", EINVAL);
    expect_failure("bad_octal", EINVAL);
}

static void test_reader_error(void) {
    char out[512];
    snprintf(out, sizeof out, "%s/tar_reader_error.extracted", g_dir);
    uint64_t size;
    CHECK(mnd_tar_extract(failing_reader, NULL, "disk.raw", out, NULL, NULL, &size) == EIO);
    CHECK(access(out, F_OK) != 0);
}

static int progress_calls;
static bool cancel_after_two(void *ctx, uint64_t done, uint64_t total) {
    (void)ctx;
    CHECK(done <= total);
    return ++progress_calls < 2;
}

static void test_cancel_removes_output(void) {
    char in[512], out[512];
    snprintf(in, sizeof in, "%s/tar_plain.tar", g_dir);
    snprintf(out, sizeof out, "%s/tar_cancel.extracted", g_dir);
    int fd = open(in, O_RDONLY);
    progress_calls = 0;
    uint64_t size;
    step_reader r = {fd, 4096};
    CHECK(mnd_tar_extract(read_steps, &r, "disk.raw", out, cancel_after_two, NULL, &size) == ECANCELED);
    CHECK(access(out, F_OK) != 0);
    close(fd);
}

static ssize_t xz_reader(void *ctx, void *buf, size_t n) {
    ssize_t r = mnd_xz_file_read(ctx, buf, n);
    return r < 0 ? -1 : r;
}

static void test_tar_xz_end_to_end(void) {
    char in[512], out[512], exp_path[512];
    snprintf(in, sizeof in, "%s/tar_sparse_xz.tar.xz", g_dir);
    snprintf(out, sizeof out, "%s/tar_sparse_xz.extracted", g_dir);
    snprintf(exp_path, sizeof exp_path, "%s/tar_sparse_xz.out", g_dir);
    int fd = open(in, O_RDONLY);
    mnd_xz_file *xz = mnd_xz_file_open(fd, 64u << 20);
    uint64_t size;
    CHECK(mnd_tar_extract(xz_reader, xz, "disk.raw", out, NULL, NULL, &size) == 0);
    size_t el, gl;
    unsigned char *exp = slurp_path(exp_path, &el), *got = slurp_path(out, &gl);
    CHECK(exp && got);
    if (exp && got) CHECK_MEM(got, gl, exp, el);
    mnd_xz_file_close(xz);
    close(fd);
    free(exp);
    free(got);
    unlink(out);
}

static void test_replaces_existing_output(void) {
    char out[512];
    snprintf(out, sizeof out, "%s/tar_plain.extracted", g_dir);
    FILE *f = fopen(out, "wb");
    fputs("old content that is longer than nothing", f);
    fclose(f);
    char in[512];
    snprintf(in, sizeof in, "%s/tar_plain.tar", g_dir);
    step_reader r = {open(in, O_RDONLY), SIZE_MAX};
    uint64_t size;
    CHECK(mnd_tar_extract(read_steps, &r, "disk.raw", out, NULL, NULL, &size) == 0);
    struct stat st;
    CHECK(stat(out, &st) == 0 && (uint64_t)st.st_size == size);
    close(r.fd);
    unlink(out);
}

int main(int argc, char **argv) {
    if (argc > 1) g_dir = argv[1];
    fprintf(stderr, "test_tar\n");
    RUN(test_plain_members);
    RUN(test_patterns);
    RUN(test_sparse_members);
    RUN(test_zero_runs_in_plain_data_become_holes);
    RUN(test_failures);
    RUN(test_reader_error);
    RUN(test_cancel_removes_output);
    RUN(test_tar_xz_end_to_end);
    RUN(test_replaces_existing_output);
    TEST_MAIN_END();
}
