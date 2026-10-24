/* Tests for mnd_pty. */
#include "../Monad/Backend/mnd_pty.h"
#include "test_util.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

static size_t read_all(int fd, char *buf, size_t cap, int timeout_ms) {
    size_t n = 0;
    for (;;) {
        struct pollfd p = {fd, POLLIN, 0};
        int r = poll(&p, 1, timeout_ms);
        if (r <= 0) break;
        ssize_t got = read(fd, buf + n, cap - 1 - n);
        if (got < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        if (got <= 0) break; /* EOF or EIO once the slave closes */
        n += (size_t)got;
        if (n >= cap - 1) break;
    }
    buf[n] = 0;
    return n;
}

static char *env[] = {"TERM=xterm-256color", "PATH=/usr/bin:/bin", NULL};

static void test_spawn_and_size(void) {
    char *argv[] = {"/bin/sh", "-c", "stty size; echo \"tty:$(tty | cut -c1-5)\"; echo hi", NULL};
    mnd_pty p;
    CHECK(mnd_pty_spawn("/bin/sh", argv, env, "/", 100, 30, &p) == 0);
    char buf[4096];
    read_all(p.master_fd, buf, sizeof buf, 3000);
    CHECK(strstr(buf, "30 100") != NULL);
    CHECK(strstr(buf, "tty:/dev/") != NULL);
    CHECK(strstr(buf, "hi\r\n") != NULL);
    int st;
    CHECK(mnd_pty_wait(p.pid, &st, false) == 1);
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0);
    close(p.master_fd);
}

static void test_resize(void) {
    char *argv[] = {"/bin/sh", "-c", "sleep 0.3; stty size", NULL};
    mnd_pty p;
    CHECK(mnd_pty_spawn("/bin/sh", argv, env, NULL, 80, 24, &p) == 0);
    CHECK(mnd_pty_resize(p.master_fd, 50, 20, 0, 0) == 0);
    char buf[1024];
    read_all(p.master_fd, buf, sizeof buf, 3000);
    CHECK(strstr(buf, "20 50") != NULL);
    mnd_pty_wait(p.pid, NULL, false);
    close(p.master_fd);
}

static void test_exec_failure(void) {
    char *argv[] = {"/nonexistent/binary", NULL};
    mnd_pty p;
    CHECK(mnd_pty_spawn("/nonexistent/binary", argv, env, NULL, 80, 24, &p) == ENOENT);
}

static void test_signal(void) {
    char *argv[] = {"/bin/sh", "-c", "sleep 30", NULL};
    mnd_pty p;
    CHECK(mnd_pty_spawn("/bin/sh", argv, env, NULL, 80, 24, &p) == 0);
    CHECK(mnd_pty_wait(p.pid, NULL, true) == 0);
    CHECK(mnd_pty_signal(p.pid, SIGHUP) == 0);
    int st;
    CHECK(mnd_pty_wait(p.pid, &st, false) == 1);
    CHECK(WIFSIGNALED(st));
    close(p.master_fd);
}

int main(void) {
    fprintf(stderr, "mnd_pty tests\n");
    RUN(test_spawn_and_size);
    RUN(test_resize);
    RUN(test_exec_failure);
    RUN(test_signal);
    TEST_MAIN_END();
}
