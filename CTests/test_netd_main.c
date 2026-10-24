/* Tests for mnd_netd_main: the netd process's start (descriptor 3 as the
 * control channel, inherited descriptors closed) run in a forked child. */
#include "../Monad/Backend/net/mnd_netd.h"
#include "test_util.h"

#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

/* Starts mnd_netd_main in a child with `control` as its descriptor 3 and
 * `extra` left open too; returns the pid. */
static pid_t spawn(int control, int extra) {
    pid_t pid = fork();
    if (pid == 0) {
        if (control >= 0) dup2(control, MND_NETD_CONTROL_FD);
        else close(MND_NETD_CONTROL_FD);
        if (control >= 0 && control != MND_NETD_CONTROL_FD) close(control);
        (void)extra; /* inherited on purpose */
        _exit(mnd_netd_main());
    }
    return pid;
}

static int status_of(pid_t pid, int ms) {
    for (int i = 0; i < ms / 10; i++) {
        int st;
        if (waitpid(pid, &st, WNOHANG) == pid) return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
        usleep(10000);
    }
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);
    return -1;
}

static int open_fds_of(pid_t pid) {
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/fd", (int)pid);
    DIR *d = opendir(path);
    if (!d) return -1;
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)))
        if (e->d_name[0] != '.') n++;
    closedir(d);
    return n;
}

static void test_serves_on_descriptor_3_and_closes_the_rest(void) {
    int sv[2], leak[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    CHECK(pipe(leak) == 0); /* something the parent forgot to mark close-on-exec */
    pid_t pid = spawn(sv[1], leak[0]);
    close(sv[1]);
    CHECK(write(sv[0], "ping\n", 5) == 5);
    struct pollfd p = {.fd = sv[0], .events = POLLIN};
    char buf[64] = {0};
    CHECK(poll(&p, 1, 2000) == 1 && read(sv[0], buf, sizeof buf - 1) > 0);
    CHECK_STR(buf, "ok pong\n");
    /* 0, 1, 2 and the control channel, plus netd's own loop: nothing inherited. */
    int n = open_fds_of(pid);
    CHECK(n >= 4 && n <= 5);
    close(sv[0]);
    CHECK(status_of(pid, 2000) == 0);
    close(leak[0]);
    close(leak[1]);
}

static void test_refuses_without_a_control_socket(void) {
    CHECK(status_of(spawn(-1, -1), 2000) == 64);
    int p[2];
    CHECK(pipe(p) == 0);
    CHECK(status_of(spawn(p[0], -1), 2000) == 64); /* a pipe is not a socket */
    close(p[0]);
    close(p[1]);
}

static void test_protocol_violation_exit_status(void) {
    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    pid_t pid = spawn(sv[1], -1);
    close(sv[1]);
    CHECK(write(sv[0], "\x01\n", 2) == 2);
    CHECK(status_of(pid, 2000) == 1);
    close(sv[0]);
}

static const char *self_path;

static void test_spawned_like_monadhost_does(void) {
    int sv[2], leak[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    CHECK(pipe(leak) == 0); /* not close-on-exec: netd must still not keep it */
    pid_t pid = mnd_netd_spawn(self_path, sv[1]);
    CHECK(pid > 0);
    close(sv[1]);
    CHECK(mnd_netd_send_command(sv[0], "ping", -1) == 0);
    struct pollfd p = {.fd = sv[0], .events = POLLIN};
    char buf[64] = {0};
    CHECK(poll(&p, 1, 3000) == 1 && read(sv[0], buf, sizeof buf - 1) > 0);
    CHECK_STR(buf, "ok pong\n");
    int n = open_fds_of(pid);
    CHECK(n >= 4 && n <= 5);
    /* A NIC handed over with its command. */
    CHECK(mnd_netd_send_command(sv[0], "network nat 10.77.0.0/24", -1) == 0);
    int nic[2];
    CHECK(socketpair(AF_UNIX, SOCK_DGRAM, 0, nic) == 0);
    CHECK(mnd_netd_send_command(sv[0], "port 0 02:4d:4f:4e:00:01", nic[0]) == 0);
    close(nic[0]);
    size_t got = 0;
    memset(buf, 0, sizeof buf);
    while (!strstr(buf, "ok 0\nok 0\n") && poll(&p, 1, 3000) == 1) {
        ssize_t r = read(sv[0], buf + got, sizeof buf - 1 - got);
        if (r <= 0) break;
        got += (size_t)r;
    }
    CHECK_STR(buf, "ok 0\nok 0\n");
    CHECK(mnd_netd_send_command(sv[0], "bad\nline", -1) == -1); /* one line only */
    close(sv[0]);
    CHECK(status_of(pid, 3000) == 0);
    close(nic[1]);
    close(leak[0]);
    close(leak[1]);
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--netd")) return mnd_netd_main(); /* spawned by the test above */
    self_path = argv[0];
    signal(SIGPIPE, SIG_IGN);
    fprintf(stderr, "monad-netd process start tests\n");
    RUN(test_serves_on_descriptor_3_and_closes_the_rest);
    RUN(test_refuses_without_a_control_socket);
    RUN(test_protocol_violation_exit_status);
    RUN(test_spawned_like_monadhost_does);
    TEST_MAIN_END();
}
