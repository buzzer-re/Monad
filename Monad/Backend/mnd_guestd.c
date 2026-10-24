/*
 * mnd_guestd.c — monad-guestd (see mnd_guestd.h).
 */
#include "mnd_guestd.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/vsock.h>
#endif

static volatile sig_atomic_t stopping = 0;

static void on_stop(int sig) {
    (void)sig;
    stopping = 1;
}

int mnd_guestd_check(const mnd_guestd_config *c) {
    if (!c || c->nservices < 1 || c->nservices > MND_GUESTD_MAX_SERVICES) return -1;
    if (c->max_children < 1 || c->max_children > 64) return -1;
    if (c->family == AF_UNIX && (!c->unix_dir || c->unix_dir[0] != '/')) return -1;
    for (int i = 0; i < c->nservices; i++) {
        const mnd_guestd_service *s = &c->services[i];
        if (s->port == 0 || !s->argv || !s->argv[0] || s->argv[0][0] != '/') return -1;
        for (int j = 0; j < i; j++)
            if (c->services[j].port == s->port) return -1;
    }
    return 0;
}

/* sshd is launchd's to start (dev.monad.sshd, as macOS's own Remote Login
 * starts it) on the guest's loopback: Apple's sshd refuses a session to a
 * peer with no IP address (its audit session, docs/MACOS.md), so each vsock
 * connection is joined to it over TCP. */
static char *const ssh_argv[] = {"/usr/bin/nc", "127.0.0.1", MND_GUESTD_SSHD_PORT, NULL};
static char *const agent_argv[] = {"/bin/sh", MND_GUESTD_AGENT, NULL};

void mnd_guestd_guest_config(mnd_guestd_config *c) {
    memset(c, 0, sizeof *c);
#if defined(__APPLE__)
    c->family = AF_VSOCK;
#else
    c->family = AF_UNIX; /* never served off macOS; keeps the check honest */
    c->unix_dir = "/nonexistent";
#endif
    c->services[0] = (mnd_guestd_service){.port = 22, .argv = ssh_argv};
    c->services[1] = (mnd_guestd_service){.port = 1024, .argv = agent_argv};
    c->nservices = 2;
    c->max_children = 16;
}

static int listen_on(const mnd_guestd_config *c, unsigned port) {
    int fd = socket(c->family, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    int rc = -1;
    if (c->family == AF_UNIX) {
        struct sockaddr_un a = {.sun_family = AF_UNIX};
        if ((size_t)snprintf(a.sun_path, sizeof a.sun_path, "%s/%u", c->unix_dir, port) >= sizeof a.sun_path) {
            close(fd);
            return -1;
        }
        unlink(a.sun_path);
        rc = bind(fd, (struct sockaddr *)&a, sizeof a);
    }
#if defined(__APPLE__)
    else if (c->family == AF_VSOCK) {
        struct sockaddr_vm a = {.svm_len = sizeof a, .svm_family = AF_VSOCK, .svm_port = port,
                                .svm_cid = VMADDR_CID_ANY};
        rc = bind(fd, (struct sockaddr *)&a, sizeof a);
    }
#endif
    if (rc != 0 || listen(fd, 16) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/* The connection's program: the connection as stdin and stdout, stderr
 * to nothing, its port in MONAD_GUESTD_PORT. Never returns. */
static void become(const mnd_guestd_service *s, int conn) {
    setsid();
    signal(SIGTERM, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    signal(SIGCHLD, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    int null = open("/dev/null", O_WRONLY);
    if (dup2(conn, 0) < 0 || dup2(conn, 1) < 0 || (null >= 0 && dup2(null, 2) < 0)) _exit(127);
    if (conn > 2) close(conn);
    if (null > 2) close(null);
    char port[16];
    snprintf(port, sizeof port, "%u", s->port);
    setenv("MONAD_GUESTD_PORT", port, 1);
    execv(s->argv[0], s->argv);
    _exit(127);
}

int mnd_guestd_run(const mnd_guestd_config *c) {
    if (mnd_guestd_check(c) != 0) return -1;
    int fds[MND_GUESTD_MAX_SERVICES];
    for (int i = 0; i < c->nservices; i++) {
        fds[i] = listen_on(c, c->services[i].port);
        if (fds[i] < 0) {
            for (int j = 0; j < i; j++) close(fds[j]);
            return -1;
        }
    }
    struct sigaction sa = {.sa_handler = on_stop};
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    /* Who runs for which service, to keep each within max_children. */
    enum { MAX_KIDS = MND_GUESTD_MAX_SERVICES * 64 };
    pid_t kids[MAX_KIDS] = {0};
    int kid_service[MAX_KIDS] = {0};

    while (!stopping) {
        /* Reap whoever ended. */
        for (;;) {
            pid_t done = waitpid(-1, NULL, WNOHANG);
            if (done <= 0) break;
            for (int k = 0; k < MAX_KIDS; k++)
                if (kids[k] == done) kids[k] = 0;
        }
        struct pollfd p[MND_GUESTD_MAX_SERVICES];
        for (int i = 0; i < c->nservices; i++) p[i] = (struct pollfd){.fd = fds[i], .events = POLLIN};
        int ready = poll(p, (nfds_t)c->nservices, 200);
        if (ready < 0) {
            if (errno == EINTR) continue;
            break;
        }
        for (int i = 0; i < c->nservices && ready > 0; i++) {
            if (!(p[i].revents & POLLIN)) continue;
            int conn = accept(fds[i], NULL, NULL);
            if (conn < 0) continue;
            int running = 0, free_slot = -1;
            for (int k = 0; k < MAX_KIDS; k++) {
                if (kids[k] && kid_service[k] == i) running++;
                if (!kids[k] && free_slot < 0) free_slot = k;
            }
            if (running >= c->max_children || free_slot < 0) {
                close(conn); /* busy: closed at once, nothing run */
                continue;
            }
            pid_t pid = fork();
            if (pid == 0) {
                for (int j = 0; j < c->nservices; j++) close(fds[j]);
                become(&c->services[i], conn);
            }
            close(conn);
            if (pid > 0) {
                kids[free_slot] = pid;
                kid_service[free_slot] = i;
            }
        }
    }
    for (int i = 0; i < c->nservices; i++) close(fds[i]);
    return 0;
}

int mnd_guestd_main(void) {
    mnd_guestd_config c;
    mnd_guestd_guest_config(&c);
    return mnd_guestd_run(&c) == 0 ? 0 : 1;
}
