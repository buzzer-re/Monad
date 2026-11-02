/* Tests for mnd_rotlog: a log file that never grows past its cap. */
#include "../Monad/Backend/mnd_rotlog.h"
#include "test_util.h"

#include <sys/stat.h>
#include <unistd.h>

static long fsize(const char *p) {
    struct stat st;
    return stat(p, &st) == 0 ? (long)st.st_size : -1;
}

static void paths(char *log, char *old, size_t n, const char *name) {
    snprintf(log, n, "/tmp/mnd-rotlog-%s-%d.log", name, (int)getpid());
    snprintf(old, n, "%s.1", log);
    unlink(log);
    unlink(old);
}

static void test_writes_and_rotates(void) {
    char log[128], old[140];
    paths(log, old, sizeof log, "rot");
    int err = 0;
    mnd_rotlog *l = mnd_rotlog_open(log, 1000, &err);
    CHECK(l != NULL);
    if (!l) return;
    char chunk[300];
    memset(chunk, 'a', sizeof chunk);
    for (int i = 0; i < 3; i++) CHECK(mnd_rotlog_write(l, chunk, sizeof chunk) == 0);
    CHECK(fsize(log) == 900);
    CHECK(fsize(old) == -1);
    memset(chunk, 'b', sizeof chunk);
    CHECK(mnd_rotlog_write(l, chunk, sizeof chunk) == 0); /* would pass 1000: rotate first */
    CHECK(fsize(old) == 900);
    CHECK(fsize(log) == 300);
    for (int i = 0; i < 20; i++) CHECK(mnd_rotlog_write(l, chunk, sizeof chunk) == 0);
    CHECK(fsize(log) <= 1000 && fsize(old) <= 1000); /* never more than two files */

    /* One write larger than the cap keeps only its tail. */
    char big[2500];
    memset(big, 'c', sizeof big);
    big[sizeof big - 1] = 'z';
    CHECK(mnd_rotlog_write(l, big, sizeof big) == 0);
    CHECK(fsize(log) == 1000);
    FILE *f = fopen(log, "r");
    char tail[1001] = {0};
    CHECK(f && fread(tail, 1, 1000, f) == 1000);
    if (f) fclose(f);
    CHECK(tail[999] == 'z');
    mnd_rotlog_close(l);
    unlink(log);
    unlink(old);
}

static void put(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    fputs(text, f);
    fclose(f);
}

/* What a crash left is still there after: opening keeps the file (a
 * MonadHost that starts again, health.log across boots), and a new boot
 * moves the last one to <path>.1 instead of throwing it away. */
static void test_reopening_keeps_and_a_new_boot_rotates(void) {
    char log[128], old[140];
    paths(log, old, sizeof log, "keep");
    put(log, "previous run\n");
    int err = 0;
    mnd_rotlog *l = mnd_rotlog_open(log, 1000, &err);
    CHECK(l != NULL);
    if (!l) return;
    CHECK(fsize(log) == 13); /* kept */
    CHECK(mnd_rotlog_write(l, "boot 1\n", 7) == 0);
    CHECK(fsize(log) == 20);
    mnd_rotlog_rotate(l); /* next boot */
    CHECK(fsize(log) == 0);
    CHECK(fsize(old) == 20);
    CHECK(mnd_rotlog_write(l, "boot 2\n", 7) == 0);
    CHECK(fsize(log) == 7);
    mnd_rotlog_rotate(l);
    CHECK(fsize(old) == 7); /* only the last boot before this one */
    mnd_rotlog_rotate(l); /* a boot that wrote nothing keeps the one before */
    CHECK(fsize(old) == 7);
    CHECK(fsize(log) == 0);
    mnd_rotlog_close(l);

    /* A file already at its cap is rotated on open, so the cap still holds. */
    char full[1000];
    memset(full, 'x', sizeof full - 1);
    full[sizeof full - 1] = 0;
    put(log, full);
    l = mnd_rotlog_open(log, 999, &err);
    CHECK(l != NULL);
    if (!l) return;
    CHECK(fsize(old) == 999);
    CHECK(fsize(log) == 0);
    CHECK(mnd_rotlog_write(l, "a", 1) == 0);
    CHECK(fsize(log) == 1);
    mnd_rotlog_close(l);
    unlink(log);
    unlink(old);
}

/* A symlink in the log's place is never followed. */
static void test_a_link_is_not_followed(void) {
    char log[128], old[140], target[150];
    paths(log, old, sizeof log, "link");
    snprintf(target, sizeof target, "%s.target", log);
    put(target, "keep me\n");
    CHECK(symlink(target, log) == 0);
    int err = 0;
    CHECK(mnd_rotlog_open(log, 1000, &err) == NULL);
    CHECK(fsize(target) == 8);
    unlink(log);
    unlink(target);
}

static void test_bad_path(void) {
    int err = 0;
    CHECK(mnd_rotlog_open("/nonexistent-dir/x.log", 1000, &err) == NULL);
    CHECK(err != 0);
    CHECK(mnd_rotlog_open("/tmp/x", 0, &err) == NULL);
}

int main(void) {
    fprintf(stderr, "mnd_rotlog tests\n");
    RUN(test_writes_and_rotates);
    RUN(test_reopening_keeps_and_a_new_boot_rotates);
    RUN(test_a_link_is_not_followed);
    RUN(test_bad_path);
    TEST_MAIN_END();
}
