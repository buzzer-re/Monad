/*
 * test_guestd.c — monad-guestd, Monad's way into a macOS guest (Phase 14):
 * one process per connection with the connection as its stdin and stdout,
 * at most so many at a time per service, nothing else. Unix sockets stand
 * in for vsock here.
 */
#include "mnd_guestd.h"
#include "test_util.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

static char dir[64];

static int dial(unsigned port) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    snprintf(a.sun_path, sizeof a.sun_path, "%s/%u", dir, port);
    for (int i = 0; i < 100; i++) {
        if (connect(fd, (struct sockaddr *)&a, sizeof a) == 0) return fd;
        usleep(20000);
    }
    close(fd);
    return -1;
}

/* Everything the other side sends until it closes (at most cap - 1 bytes). */
static size_t slurp(int fd, char *buf, size_t cap) {
    size_t n = 0;
    struct timeval tv = {.tv_sec = 5};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    while (n + 1 < cap) {
        ssize_t r = read(fd, buf + n, cap - 1 - n);
        if (r <= 0) break;
        n += (size_t)r;
    }
    buf[n] = 0;
    return n;
}

static char *const echo_argv[] = {"/bin/cat", NULL};
static char *const hello_argv[] = {"/bin/sh", "-c", "echo hello from $MONAD_GUESTD_PORT", NULL};
static char *const slow_argv[] = {"/bin/sh", "-c", "sleep 2", NULL};
static char *const missing_argv[] = {"/nonexistent/program", NULL};

static void test_config_checks(void) {
    mnd_guestd_config c = {.family = AF_UNIX, .unix_dir = dir, .max_children = 4};
    c.services[0] = (mnd_guestd_service){.port = 22, .argv = echo_argv};
    c.nservices = 1;
    CHECK(mnd_guestd_check(&c) == 0);
    static char *const relative[] = {"cat", NULL};
    c.services[0].argv = relative;
    CHECK(mnd_guestd_check(&c) != 0);
    c.services[0].argv = echo_argv;
    c.services[1] = (mnd_guestd_service){.port = 22, .argv = echo_argv};
    c.nservices = 2;
    CHECK(mnd_guestd_check(&c) != 0); /* a port twice */
    c.nservices = 0;
    CHECK(mnd_guestd_check(&c) != 0);
    c.nservices = 1;
    c.max_children = 0;
    CHECK(mnd_guestd_check(&c) != 0);
}

static void test_serves_each_connection(void) {
    mnd_guestd_config c = {.family = AF_UNIX, .unix_dir = dir, .max_children = 2};
    c.services[0] = (mnd_guestd_service){.port = 22, .argv = echo_argv};
    c.services[1] = (mnd_guestd_service){.port = 1024, .argv = hello_argv};
    c.services[2] = (mnd_guestd_service){.port = 5, .argv = slow_argv};
    c.services[3] = (mnd_guestd_service){.port = 6, .argv = missing_argv};
    c.nservices = 4;
    CHECK(mnd_guestd_check(&c) == 0);

    pid_t server = fork();
    if (server == 0) _exit(mnd_guestd_run(&c) == 0 ? 0 : 1);

    /* The connection is the program's stdin and stdout. */
    int a = dial(22);
    CHECK(a >= 0);
    CHECK(write(a, "ping\n", 5) == 5);
    shutdown(a, SHUT_WR);
    char buf[256];
    slurp(a, buf, sizeof buf);
    CHECK(strcmp(buf, "ping\n") == 0);
    close(a);

    /* Each service runs its own program, told its port. */
    int b = dial(1024);
    slurp(b, buf, sizeof buf);
    CHECK(strcmp(buf, "hello from 1024\n") == 0);
    close(b);

    /* Two at a time: a third is closed at once, then served once one ends. */
    int s1 = dial(5), s2 = dial(5);
    usleep(200000);
    int s3 = dial(5);
    CHECK(s1 >= 0 && s2 >= 0 && s3 >= 0);
    CHECK(slurp(s3, buf, sizeof buf) == 0); /* closed, nothing run */
    close(s3);
    slurp(s1, buf, sizeof buf);
    slurp(s2, buf, sizeof buf);
    close(s1);
    close(s2);
    usleep(300000);
    int s4 = dial(5);
    struct timeval tv = {.tv_sec = 0, .tv_usec = 500000};
    setsockopt(s4, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    errno = 0;
    CHECK(read(s4, buf, 1) < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)); /* running, not refused */
    close(s4);

    /* A program that cannot run closes the connection, the server goes on. */
    int m = dial(6);
    CHECK(slurp(m, buf, sizeof buf) == 0);
    close(m);
    int again = dial(1024);
    slurp(again, buf, sizeof buf);
    CHECK(strcmp(buf, "hello from 1024\n") == 0);
    close(again);

    kill(server, SIGTERM);
    int status = 0;
    waitpid(server, &status, 0);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0); /* SIGTERM: a clean stop */
}

/* The guest's own services: ssh (launchd's sshd job on the guest's
 * loopback), and the agent; nothing else. */
static void test_the_guests_services(void) {
    mnd_guestd_config c;
    mnd_guestd_guest_config(&c);
    CHECK(mnd_guestd_check(&c) == 0);
    CHECK(c.nservices == 2);
    CHECK(c.services[0].port == 22);
    /* sshd is launchd's, on the guest's loopback (Apple's sshd needs an IP
     * peer): each connection joined to it. */
    CHECK(strcmp(c.services[0].argv[0], "/usr/bin/nc") == 0);
    CHECK(c.services[0].argv[1] && strcmp(c.services[0].argv[1], "127.0.0.1") == 0);
    CHECK(c.services[0].argv[1] && c.services[0].argv[2] && strcmp(c.services[0].argv[2], MND_GUESTD_SSHD_PORT) == 0);
    CHECK(c.services[0].argv[1] && c.services[0].argv[2] && c.services[0].argv[3] == NULL);
    CHECK(c.services[1].port == 1024);
    CHECK(strcmp(c.services[1].argv[0], "/bin/sh") == 0);
    CHECK(strcmp(c.services[1].argv[1], MND_GUESTD_AGENT) == 0);
}

int main(void) {
    snprintf(dir, sizeof dir, "/tmp/mnd-guestd-%d", (int)getpid());
    mkdir(dir, 0700);
    RUN(test_config_checks);
    RUN(test_serves_each_connection);
    RUN(test_the_guests_services);
    char cmd[300];
    snprintf(cmd, sizeof cmd, "rm -rf %s", dir);
    if (system(cmd) != 0) { /* best effort */ }
    TEST_MAIN_END();
}
