/* Tests for mnd_loop: readiness, interest changes, deadlines, and changes
 * made from inside callbacks. */
#include "../Monad/Backend/net/mnd_loop.h"
#include "test_util.h"

#include <fcntl.h>
#include <stdbool.h>
#include <unistd.h>

typedef struct {
    int calls;
    unsigned last_events;
    int last_fd;
    mnd_loop *loop;
    int other_fd;   /* unwatched by the callback, if >= 0 */
    bool drain;
    void *rewatch;  /* then watched again with this probe, if set */
} probe;

static void on_event(void *ctx, int fd, unsigned events) {
    probe *p = ctx;
    p->calls++;
    p->last_events = events;
    p->last_fd = fd;
    if (p->drain && (events & MND_LOOP_READ)) {
        char buf[64];
        while (read(fd, buf, sizeof buf) > 0) {
        }
    }
    if (p->other_fd >= 0) {
        mnd_loop_watch(p->loop, p->other_fd, 0, NULL, NULL);
        if (p->rewatch) mnd_loop_watch(p->loop, p->other_fd, MND_LOOP_READ, on_event, p->rewatch);
    }
}

static void nonblocking(int fd) { fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK); }

static void test_readable_and_writable(void) {
    mnd_loop *loop = mnd_loop_create();
    CHECK(loop != NULL);
    int fds[2];
    CHECK(pipe(fds) == 0);
    nonblocking(fds[0]);
    probe p = {.other_fd = -1, .drain = true};
    CHECK(mnd_loop_watch(loop, fds[0], MND_LOOP_READ, on_event, &p) == 0);
    /* Nothing to read: the deadline passes. */
    uint64_t t0 = mnd_loop_now();
    CHECK(mnd_loop_run_once(loop, t0 + 50) == 0);
    CHECK(mnd_loop_now() >= t0 + 50 && p.calls == 0);
    CHECK(write(fds[1], "x", 1) == 1);
    CHECK(mnd_loop_run_once(loop, mnd_loop_now() + 1000) == 1);
    CHECK(p.calls == 1 && p.last_fd == fds[0] && p.last_events == MND_LOOP_READ);
    /* Level-triggered: data left unread is reported again. */
    p.drain = false;
    CHECK(write(fds[1], "y", 1) == 1);
    CHECK(mnd_loop_run_once(loop, mnd_loop_now() + 1000) == 1);
    CHECK(mnd_loop_run_once(loop, mnd_loop_now() + 1000) == 1);
    CHECK(p.calls == 3);
    /* Write interest on the other end. */
    probe w = {.other_fd = -1};
    CHECK(mnd_loop_watch(loop, fds[1], MND_LOOP_WRITE, on_event, &w) == 0);
    p.drain = true;
    CHECK(mnd_loop_run_once(loop, mnd_loop_now() + 1000) == 2);
    CHECK(w.calls == 1 && w.last_events == MND_LOOP_WRITE);
    /* Unwatched: silent. */
    CHECK(mnd_loop_watch(loop, fds[1], 0, NULL, NULL) == 0);
    CHECK(mnd_loop_watch(loop, fds[0], 0, NULL, NULL) == 0);
    CHECK(write(fds[1], "z", 1) == 1);
    CHECK(mnd_loop_run_once(loop, mnd_loop_now() + 30) == 0);
    close(fds[0]);
    close(fds[1]);
    mnd_loop_destroy(loop);
}

static void test_changing_interest(void) {
    mnd_loop *loop = mnd_loop_create();
    int fds[2];
    CHECK(pipe(fds) == 0);
    nonblocking(fds[0]);
    probe p = {.other_fd = -1, .drain = true};
    CHECK(mnd_loop_watch(loop, fds[1], MND_LOOP_WRITE, on_event, &p) == 0);
    CHECK(mnd_loop_run_once(loop, mnd_loop_now() + 1000) == 1);
    /* Now read interest only, on a write end: never readable. */
    CHECK(mnd_loop_watch(loop, fds[1], MND_LOOP_READ, on_event, &p) == 0);
    CHECK(mnd_loop_run_once(loop, mnd_loop_now() + 30) == 0);
    /* Both, then back to write. */
    CHECK(mnd_loop_watch(loop, fds[1], MND_LOOP_READ | MND_LOOP_WRITE, on_event, &p) == 0);
    CHECK(mnd_loop_run_once(loop, mnd_loop_now() + 1000) == 1 && (p.last_events & MND_LOOP_WRITE));
    CHECK(mnd_loop_watch(loop, fds[1], MND_LOOP_WRITE, on_event, &p) == 0);
    CHECK(mnd_loop_run_once(loop, mnd_loop_now() + 1000) == 1);
    /* Invalid descriptors. */
    CHECK(mnd_loop_watch(loop, -1, MND_LOOP_READ, on_event, &p) == -1);
    CHECK(mnd_loop_watch(loop, MND_LOOP_MAX_FDS, MND_LOOP_READ, on_event, &p) == -1);
    CHECK(mnd_loop_watch(loop, fds[0], MND_LOOP_READ, NULL, &p) == -1);
    close(fds[0]);
    close(fds[1]);
    mnd_loop_destroy(loop);
}

static void test_unwatching_inside_a_batch(void) {
    mnd_loop *loop = mnd_loop_create();
    int a[2], b[2];
    CHECK(pipe(a) == 0 && pipe(b) == 0);
    nonblocking(a[0]);
    nonblocking(b[0]);
    probe pa = {.other_fd = b[0], .loop = loop, .drain = true};
    probe pb = {.other_fd = a[0], .loop = loop, .drain = true};
    CHECK(mnd_loop_watch(loop, a[0], MND_LOOP_READ, on_event, &pa) == 0);
    CHECK(mnd_loop_watch(loop, b[0], MND_LOOP_READ, on_event, &pb) == 0);
    CHECK(write(a[1], "x", 1) == 1 && write(b[1], "x", 1) == 1);
    /* Both are ready; whichever runs first unwatches the other. */
    CHECK(mnd_loop_run_once(loop, mnd_loop_now() + 1000) == 1);
    CHECK(pa.calls + pb.calls == 1);
    /* Unwatched and watched again with another callback in the same batch:
     * the stale event goes to neither. */
    probe pc = {.other_fd = -1, .drain = true};
    probe pa2 = {.other_fd = b[0], .loop = loop, .drain = true, .rewatch = &pc};
    probe pb2 = {.other_fd = -1, .drain = false};
    CHECK(mnd_loop_watch(loop, a[0], MND_LOOP_READ, on_event, &pa2) == 0);
    CHECK(mnd_loop_watch(loop, b[0], MND_LOOP_READ, on_event, &pb2) == 0);
    CHECK(write(a[1], "x", 1) == 1 && write(b[1], "x", 1) == 1);
    mnd_loop_run_once(loop, mnd_loop_now() + 1000);
    CHECK(pa2.calls == 1 && pc.calls == 0);
    /* The next round, the new callback gets it. */
    CHECK(mnd_loop_watch(loop, a[0], 0, NULL, NULL) == 0);
    CHECK(mnd_loop_run_once(loop, mnd_loop_now() + 1000) == 1 && pc.calls == 1);
    close(a[0]);
    close(a[1]);
    close(b[0]);
    close(b[1]);
    mnd_loop_destroy(loop);
}

static void test_hang_up_reports_what_is_watched(void) {
    mnd_loop *loop = mnd_loop_create();
    int fds[2];
    CHECK(pipe(fds) == 0);
    nonblocking(fds[0]);
    probe p = {.other_fd = -1, .drain = true};
    CHECK(mnd_loop_watch(loop, fds[0], MND_LOOP_READ, on_event, &p) == 0);
    close(fds[1]); /* the other end goes away */
    CHECK(mnd_loop_run_once(loop, mnd_loop_now() + 1000) == 1);
    CHECK(p.last_events == MND_LOOP_READ); /* never WRITE: it was not asked for */
    CHECK(mnd_loop_watch(loop, fds[0], 0, NULL, NULL) == 0);
    close(fds[0]);
    mnd_loop_destroy(loop);
}

static void test_many_descriptors(void) {
    mnd_loop *loop = mnd_loop_create();
    enum { N = 200 };
    int fds[N][2];
    probe p = {.other_fd = -1, .drain = true};
    for (int i = 0; i < N; i++) {
        CHECK(pipe(fds[i]) == 0);
        nonblocking(fds[i][0]);
        CHECK(mnd_loop_watch(loop, fds[i][0], MND_LOOP_READ, on_event, &p) == 0);
        CHECK(write(fds[i][1], "x", 1) == 1);
    }
    int total = 0;
    for (int round = 0; round < 10 && total < N; round++) total += mnd_loop_run_once(loop, mnd_loop_now() + 1000);
    CHECK(total == N && p.calls == N);
    for (int i = 0; i < N; i++) {
        close(fds[i][0]);
        close(fds[i][1]);
    }
    mnd_loop_destroy(loop);
}

int main(void) {
    fprintf(stderr, "mnd_loop tests\n");
    RUN(test_readable_and_writable);
    RUN(test_changing_interest);
    RUN(test_unwatching_inside_a_batch);
    RUN(test_hang_up_reports_what_is_watched);
    RUN(test_many_descriptors);
    TEST_MAIN_END();
}
