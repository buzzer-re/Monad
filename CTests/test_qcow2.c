/* Tests for mnd_qcow2 against fixtures from gen_qcow2_fixture.py. */
#include "../Monad/Backend/mnd_qcow2.h"
#include "test_util.h"

#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *g_dir = ".";

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

static int calls;
static bool count_progress(void *ctx, uint64_t done, uint64_t total) {
    (void)ctx;
    calls++;
    return done <= total;
}
static bool cancel_progress(void *ctx, uint64_t done, uint64_t total) {
    (void)ctx;
    (void)done;
    (void)total;
    return false;
}

static void convert_and_compare(const char *name) {
    char q[512], r[512], o[512];
    snprintf(q, sizeof q, "%s/%s.qcow2", g_dir, name);
    snprintf(r, sizeof r, "%s/%s.raw", g_dir, name);
    snprintf(o, sizeof o, "%s/%s.out", g_dir, name);
    mnd_qcow2_info info;
    CHECK(mnd_qcow2_probe(q, &info) == 0);
    calls = 0;
    int e = mnd_qcow2_to_raw(q, o, count_progress, NULL);
    if (e) fprintf(stderr, "    error: %s\n", mnd_qcow2_last_error());
    CHECK(e == 0);
    CHECK(calls > 0);
    size_t el, ol;
    unsigned char *exp = slurp(r, &el), *got = slurp(o, &ol);
    CHECK(exp && got);
    CHECK(el == info.virtual_size);
    CHECK_MEM(got, ol, exp, el);
    free(exp);
    free(got);
    unlink(o);
}

static void test_fixtures(void) {
    convert_and_compare("fx_v3_512");
    convert_and_compare("fx_v2_512");
    convert_and_compare("fx_v3_64k");
}

static void test_rejects(void) {
    char p[512], o[512];
    snprintf(p, sizeof p, "%s/bad.qcow2", g_dir);
    snprintf(o, sizeof o, "%s/bad.out", g_dir);
    FILE *f = fopen(p, "wb");
    fputs("definitely not a qcow2 image, just some text padding padding padding padding padding", f);
    fclose(f);
    CHECK(mnd_qcow2_to_raw(p, o, NULL, NULL) == EINVAL);
    CHECK(access(o, F_OK) != 0);

    /* Backing file set -> ENOTSUP */
    char q[512];
    snprintf(q, sizeof q, "%s/fx_v3_512.qcow2", g_dir);
    size_t n;
    unsigned char *img = slurp(q, &n);
    img[15] = 0x80; /* backing_file_offset != 0 */
    f = fopen(p, "wb");
    fwrite(img, 1, n, f);
    fclose(f);
    CHECK(mnd_qcow2_to_raw(p, o, NULL, NULL) == ENOTSUP);
    free(img);

    /* Cancellation removes the output. */
    CHECK(mnd_qcow2_to_raw(q, o, cancel_progress, NULL) == ECANCELED);
    CHECK(access(o, F_OK) != 0);
    unlink(p);
}

static void test_truncated(void) {
    char q[512], p[512], o[512];
    snprintf(q, sizeof q, "%s/fx_v3_64k.qcow2", g_dir);
    snprintf(p, sizeof p, "%s/trunc.qcow2", g_dir);
    snprintf(o, sizeof o, "%s/trunc.out", g_dir);
    size_t n;
    unsigned char *img = slurp(q, &n);
    FILE *f = fopen(p, "wb");
    fwrite(img, 1, n / 2, f);
    fclose(f);
    CHECK(mnd_qcow2_to_raw(p, o, NULL, NULL) != 0);
    free(img);
    unlink(p);
}

int main(int argc, char **argv) {
    if (argc > 1) g_dir = argv[1];
    fprintf(stderr, "mnd_qcow2 tests\n");
    RUN(test_fixtures);
    RUN(test_rejects);
    RUN(test_truncated);
    TEST_MAIN_END();
}
