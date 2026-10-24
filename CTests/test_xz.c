/* Tests for mnd_xz against fixtures from gen_xz_fixtures.py. */
#include "../Monad/Backend/mnd_xz.h"
#include "test_util.h"

#include <fcntl.h>
#include <unistd.h>

static const char *g_dir = ".";
static const uint64_t LIMIT = 32u << 20;

static unsigned char *slurp(const char *name, const char *ext, size_t *len) {
    char path[512];
    snprintf(path, sizeof path, "%s/xz_%s.%s", g_dir, name, ext);
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

/* Decode `in` feeding at most `in_step` bytes and taking at most `out_step`
 * bytes per call. Returns the final code; the output goes to out and out_len. */
static int decode(const unsigned char *in, size_t in_len, size_t in_step, size_t out_step,
                  unsigned char **out, size_t *out_len, uint64_t limit) {
    mnd_xz *d = mnd_xz_new(limit);
    size_t cap = 1 << 16, n = 0, pos = 0;
    unsigned char *buf = malloc(cap);
    int rc = MND_XZ_OK;
    int idle = 0;
    for (;;) {
        size_t chunk = in_len - pos < in_step ? in_len - pos : in_step;
        bool finish = pos + chunk == in_len;
        if (cap - n < out_step) {
            cap = cap * 2 + out_step;
            buf = realloc(buf, cap);
        }
        size_t used = 0, wrote = 0;
        rc = mnd_xz_run(d, in + pos, chunk, &used, buf + n, out_step, &wrote, finish);
        pos += used;
        n += wrote;
        if (rc != MND_XZ_OK) break;
        idle = (used == 0 && wrote == 0) ? idle + 1 : 0;
        if (idle > 3) {
            fprintf(stderr, "    no progress at %zu/%zu: %s\n", pos, in_len, mnd_xz_error(d));
            rc = 99;
            break;
        }
    }
    if (rc < 0) fprintf(stderr, "    (expected?) error %d: %s\n", rc, mnd_xz_error(d));
    mnd_xz_free(d);
    *out = buf;
    *out_len = n;
    return rc;
}

static void expect_ok(const char *name, size_t in_step, size_t out_step) {
    size_t il, el;
    unsigned char *in = slurp(name, "xz", &il), *exp = slurp(name, "out", &el);
    CHECK(in && exp);
    if (!in || !exp) return;
    unsigned char *out;
    size_t ol;
    int rc = decode(in, il, in_step, out_step, &out, &ol, LIMIT);
    if (rc != MND_XZ_END) fprintf(stderr, "    %s: rc %d\n", name, rc);
    CHECK(rc == MND_XZ_END);
    CHECK_MEM(out, ol, exp, el);
    free(in);
    free(exp);
    free(out);
}

static void expect_error(const char *name, int code, uint64_t limit) {
    size_t il;
    unsigned char *in = slurp(name, "xz", &il);
    CHECK(in != NULL);
    if (!in) return;
    unsigned char *out;
    size_t ol;
    int rc = decode(in, il, 4096, 1 << 16, &out, &ol, limit);
    if (rc != code) fprintf(stderr, "    %s: expected %d, got %d\n", name, code, rc);
    CHECK(rc == code);
    free(in);
    free(out);
}

static void test_valid_whole_buffers(void) {
    const char *names[] = {"empty", "empty_block", "hello_none", "hello_crc32", "hello_crc64", "hello_sha256",
                           "mixed", "multiblock", "no_sizes", "small_dict", "lc0_lp2_pb0", "lc4_lp0_pb4",
                           "concatenated"};
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) expect_ok(names[i], SIZE_MAX, 1 << 22);
}

static void test_tiny_input_steps(void) {
    expect_ok("hello_sha256", 1, 1 << 16);
    expect_ok("concatenated", 1, 1 << 16);
    expect_ok("multiblock", 7, 1 << 16);
    expect_ok("small_dict", 3, 1 << 16);
}

static void test_tiny_output_steps(void) {
    expect_ok("hello_crc64", SIZE_MAX, 1);
    expect_ok("mixed", SIZE_MAX, 1);
    expect_ok("small_dict", 4096, 3);
    expect_ok("lc0_lp2_pb0", 1000, 777);
}

static void test_errors(void) {
    expect_error("bad_magic", MND_XZ_EFORMAT, LIMIT);
    expect_error("truncated", MND_XZ_ETRUNCATED, LIMIT);
    expect_error("truncated_footer", MND_XZ_ETRUNCATED, LIMIT);
    expect_error("corrupt_data", MND_XZ_ECORRUPT, LIMIT);
    expect_error("bad_check", MND_XZ_ECORRUPT, LIMIT);
    expect_error("bcj_filter", MND_XZ_EUNSUPPORTED, LIMIT);
    expect_error("check_reserved", MND_XZ_EUNSUPPORTED, LIMIT);
    expect_error("big_dict", MND_XZ_EMEMLIMIT, LIMIT);
    expect_error("index_mismatch", MND_XZ_EFORMAT, LIMIT);
    expect_error("bad_padding", MND_XZ_EFORMAT, LIMIT);
    expect_error("trailing_garbage", MND_XZ_EFORMAT, LIMIT);
}

static void test_memlimit_allows_big_dict_when_raised(void) {
    size_t il;
    unsigned char *in = slurp("big_dict", "xz", &il);
    unsigned char *out;
    size_t ol;
    CHECK(decode(in, il, SIZE_MAX, 1 << 16, &out, &ol, 128u << 20) == MND_XZ_END);
    CHECK(ol == 100);
    free(in);
    free(out);
}

static void test_errors_are_sticky(void) {
    size_t il;
    unsigned char *in = slurp("bad_magic", "xz", &il);
    mnd_xz *d = mnd_xz_new(LIMIT);
    unsigned char out[64];
    size_t used, wrote;
    CHECK(mnd_xz_run(d, in, il, &used, out, sizeof out, &wrote, true) == MND_XZ_EFORMAT);
    CHECK(strlen(mnd_xz_error(d)) > 0);
    CHECK(mnd_xz_run(d, in, il, &used, out, sizeof out, &wrote, true) == MND_XZ_EFORMAT);
    CHECK(used == 0 && wrote == 0);
    mnd_xz_free(d);
    free(in);
}

static void test_no_input_is_truncated(void) {
    mnd_xz *d = mnd_xz_new(LIMIT);
    unsigned char out[16];
    size_t used, wrote;
    CHECK(mnd_xz_run(d, NULL, 0, &used, out, sizeof out, &wrote, false) == MND_XZ_OK);
    CHECK(mnd_xz_run(d, NULL, 0, &used, out, sizeof out, &wrote, true) == MND_XZ_ETRUNCATED);
    mnd_xz_free(d);
}

static void test_file_reader(void) {
    char path[512];
    snprintf(path, sizeof path, "%s/xz_multiblock.xz", g_dir);
    int fd = open(path, O_RDONLY);
    CHECK(fd >= 0);
    mnd_xz_file *f = mnd_xz_file_open(fd, LIMIT);
    CHECK(f != NULL);
    size_t el;
    unsigned char *exp = slurp("multiblock", "out", &el);
    unsigned char *got = malloc(el + 1);
    size_t n = 0;
    ssize_t r;
    unsigned char buf[3000];
    while ((r = mnd_xz_file_read(f, buf, sizeof buf)) > 0) {
        CHECK(n + (size_t)r <= el);
        if (n + (size_t)r > el) break;
        memcpy(got + n, buf, (size_t)r);
        n += (size_t)r;
    }
    CHECK(r == 0);
    CHECK_MEM(got, n, exp, el);
    CHECK(mnd_xz_file_position(f) == (uint64_t)lseek(fd, 0, SEEK_END));
    CHECK(mnd_xz_file_read(f, buf, sizeof buf) == 0);
    mnd_xz_file_close(f);
    close(fd);
    free(exp);
    free(got);

    snprintf(path, sizeof path, "%s/xz_corrupt_data.xz", g_dir);
    fd = open(path, O_RDONLY);
    f = mnd_xz_file_open(fd, LIMIT);
    while ((r = mnd_xz_file_read(f, buf, sizeof buf)) > 0) {}
    CHECK(r == MND_XZ_ECORRUPT);
    CHECK(strlen(mnd_xz_file_error(f)) > 0);
    mnd_xz_file_close(f);
    close(fd);
}

int main(int argc, char **argv) {
    if (argc > 1) g_dir = argv[1];
    fprintf(stderr, "test_xz\n");
    RUN(test_valid_whole_buffers);
    RUN(test_tiny_input_steps);
    RUN(test_tiny_output_steps);
    RUN(test_errors);
    RUN(test_memlimit_allows_big_dict_when_raised);
    RUN(test_errors_are_sticky);
    RUN(test_no_input_is_truncated);
    RUN(test_file_reader);
    TEST_MAIN_END();
}
