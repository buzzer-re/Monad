/* Tests for mnd_bridge: an echo upstream behind a unix socket. */
#include "../Monad/Backend/mnd_bridge.h"
#include "test_util.h"

#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static atomic_int g_released;

static void *echo_thread(void *arg) {
    int fd = (int)(intptr_t)arg;
    char buf[8192];
    for (;;) {
        ssize_t n = read(fd, buf, sizeof buf);
        if (n <= 0) break;
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(fd, buf + off, (size_t)(n - off));
            if (w <= 0) goto out;
            off += w;
        }
    }
    /* EOF from client: say goodbye then close (tests half-close). */
    (void)!write(fd, "bye", 3);
out:
    close(fd);
    return NULL;
}

static int up_connect(void *ctx) {
    (void)ctx;
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) return -1;
    pthread_t t;
    pthread_create(&t, NULL, echo_thread, (void *)(intptr_t)sv[1]);
    pthread_detach(t);
    return sv[0];
}

static void up_release(void *ctx, int fd) {
    (void)ctx;
    close(fd);
    atomic_fetch_add(&g_released, 1);
}

static int dial(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = {0};
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, path, sizeof a.sun_path - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void test_echo(void) {
    char path[128];
    snprintf(path, sizeof path, "/tmp/mnd-bridge-%d.sock", (int)getpid());
    int err = 0;
    mnd_bridge *b = mnd_bridge_start(path, (mnd_bridge_upstream){NULL, up_connect, up_release}, &err);
    CHECK(b != NULL);
    if (!b) return;
    CHECK(access(path, F_OK) == 0);

    int c = dial(path);
    CHECK(c >= 0);
    /* Large payload to exercise partial writes. */
    size_t total = 1 << 20;
    char *data = malloc(total), *back = malloc(total + 16);
    for (size_t i = 0; i < total; i++) data[i] = (char)(i * 31);
    size_t sent = 0, got = 0;
    while (got < total) {
        if (sent < total) {
            ssize_t w = write(c, data + sent, total - sent > 4096 ? 4096 : total - sent);
            if (w > 0) sent += (size_t)w;
        }
        ssize_t r = read(c, back + got, total + 16 - got);
        if (r <= 0) break;
        got += (size_t)r;
    }
    CHECK(got == total && memcmp(data, back, total) == 0);
    shutdown(c, SHUT_WR);
    char tail[8] = {0};
    size_t tn = 0;
    ssize_t r;
    while ((r = read(c, tail + tn, sizeof tail - 1 - tn)) > 0) tn += (size_t)r;
    CHECK_STR(tail, "bye");
    close(c);

    /* A second connection while stopping must be torn down. */
    int c2 = dial(path);
    CHECK(c2 >= 0);
    CHECK(write(c2, "x", 1) == 1);
    char one;
    CHECK(read(c2, &one, 1) == 1 && one == 'x');
    mnd_bridge_stop(b);
    CHECK(read(c2, &one, 1) <= 0);
    close(c2);
    CHECK(atomic_load(&g_released) == 2);
    CHECK(access(path, F_OK) != 0);
    free(data);
    free(back);
}

/* An upstream the "hypervisor" closes on its own, as Virtualization.framework
 * does with vsock connections when the VM stops. */
static atomic_int g_stolen_fd = -1;
static atomic_int g_stolen_peer = -1;

static int up_connect_stealable(void *ctx) {
    (void)ctx;
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) return -1;
    atomic_store(&g_stolen_fd, sv[0]);
    atomic_store(&g_stolen_peer, sv[1]);
    return sv[0];
}

static void up_release_stolen(void *ctx, int fd) {
    (void)ctx;
    (void)fd; /* already closed by its owner */
}

static double cpu_seconds(void) {
    struct rusage u;
    getrusage(RUSAGE_SELF, &u);
    return (double)u.ru_utime.tv_sec + u.ru_utime.tv_usec / 1e6 + (double)u.ru_stime.tv_sec + u.ru_stime.tv_usec / 1e6;
}

static void test_upstream_closed_underneath_does_not_spin(void) {
    char path[128];
    snprintf(path, sizeof path, "/tmp/mnd-bridge-steal-%d.sock", (int)getpid());
    int err = 0;
    mnd_bridge *b = mnd_bridge_start(path, (mnd_bridge_upstream){NULL, up_connect_stealable, up_release_stolen}, &err);
    CHECK(b != NULL);
    if (!b) return;
    int c = dial(path);
    CHECK(c >= 0);
    CHECK(write(c, "x", 1) == 1);
    for (int i = 0; i < 500 && atomic_load(&g_stolen_peer) < 0; i++) usleep(2000);
    char one;
    CHECK(read(atomic_load(&g_stolen_peer), &one, 1) == 1); /* the splice loop is running */
    close(atomic_load(&g_stolen_fd)); /* the VM went away */
    /* The client half-closes: the loop reads its EOF and goes back to
     * polling only the dead upstream. */
    shutdown(c, SHUT_WR);

    double before = cpu_seconds();
    usleep(400 * 1000);
    double used = cpu_seconds() - before;
    CHECK(used < 0.1); /* a spinning thread would use ~0.4 s */
    if (used >= 0.1) fprintf(stderr, "  bridge used %.3f s of CPU in 0.4 s\n", used);

    /* The client learns the session ended (bounded wait, never hang). */
    struct pollfd pc = {c, POLLIN, 0};
    CHECK(poll(&pc, 1, 2000) == 1);
    char buf[8];
    CHECK(read(c, buf, sizeof buf) <= 0);
    close(c);
    mnd_bridge_stop(b);
    close(atomic_load(&g_stolen_peer));
}

static void test_refuses_regular_file(void) {
    char path[128];
    snprintf(path, sizeof path, "/tmp/mnd-bridge-file-%d", (int)getpid());
    FILE *f = fopen(path, "w");
    fclose(f);
    int err = 0;
    mnd_bridge *b = mnd_bridge_start(path, (mnd_bridge_upstream){NULL, up_connect, up_release}, &err);
    CHECK(b == NULL && err == EEXIST);
    unlink(path);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN); /* the echo peer may write after teardown */
    fprintf(stderr, "mnd_bridge tests\n");
    RUN(test_echo);
    RUN(test_upstream_closed_underneath_does_not_spin);
    RUN(test_refuses_regular_file);
    TEST_MAIN_END();
}
