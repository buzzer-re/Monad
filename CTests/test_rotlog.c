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

static void test_reset_starts_a_fresh_file(void) {
    char log[128], old[140];
    paths(log, old, sizeof log, "reset");
    FILE *f = fopen(log, "w");
    fputs("previous run\n", f);
    fclose(f);
    int err = 0;
    mnd_rotlog *l = mnd_rotlog_open(log, 1000, &err);
    CHECK(l != NULL);
    if (!l) return;
    CHECK(fsize(log) == 0); /* opening truncates */
    CHECK(mnd_rotlog_write(l, "boot 1\n", 7) == 0);
    mnd_rotlog_reset(l); /* next boot */
    CHECK(fsize(log) == 0);
    CHECK(fsize(old) == -1);
    CHECK(mnd_rotlog_write(l, "boot 2\n", 7) == 0);
    CHECK(fsize(log) == 7);
    mnd_rotlog_close(l);
    unlink(log);
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
    RUN(test_reset_starts_a_fresh_file);
    RUN(test_bad_path);
    TEST_MAIN_END();
}
