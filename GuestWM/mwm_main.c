/*
 * mwm_main.c — monad-wm, Monad's window manager for a Linux VM's display:
 * takes the display (mwm_kms.c), listens where programs look for a Wayland
 * server ($XDG_RUNTIME_DIR/wayland-0) and serves them (mwm_server.c).
 * Whenever a window comes, goes or changes it prints the list, one line a
 * window, for whoever started it.
 *
 *   monad-wm [--size WIDTHxHEIGHT] [--card /dev/dri/card0] [--owner UID]
 *
 * --owner: started as root, the socket is given to that user, whose
 * programs then connect. Linux only.
 */
#define _GNU_SOURCE /* accept4 */
#include "mwm_kms.h"
#include "mwm_server.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stopping;

static void on_stop(int sig) {
    (void)sig;
    stopping = 1;
}

static void on_bus(int sig) {
    (void)sig;
    mwm_server_bus_error();
    _exit(70); /* not while copying a program's pixels: a fault of our own */
}

static void present(void *ctx, int x, int y, int width, int height) { mwm_kms_present(ctx, x, y, width, height); }

static uint32_t now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint32_t)((uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000);
}

/* The socket programs connect to, and the lock that says it is ours. */
static int listen_at(const char *dir, long owner, char *path, size_t pathlen) {
    char lock[sizeof(((struct sockaddr_un *)0)->sun_path) + 8];
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    if (snprintf(addr.sun_path, sizeof addr.sun_path, "%s/wayland-0", dir) >= (int)sizeof addr.sun_path) {
        fprintf(stderr, "monad-wm: %s is too long a place for the socket\n", dir);
        return -1;
    }
    snprintf(lock, sizeof lock, "%s.lock", addr.sun_path);
    int lock_fd = open(lock, O_CREAT | O_CLOEXEC | O_RDWR, 0660);
    if (lock_fd < 0 || flock(lock_fd, LOCK_EX | LOCK_NB) < 0) {
        fprintf(stderr, "monad-wm: another Wayland server holds %s\n", addr.sun_path);
        return -1;
    }
    unlink(addr.sun_path); /* left by one that ended: the lock says nobody serves it */
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0 || bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0 || listen(fd, 16) < 0) {
        fprintf(stderr, "monad-wm: cannot listen at %s: %s\n", addr.sun_path, strerror(errno));
        return -1;
    }
    if (owner >= 0 && (chown(addr.sun_path, (uid_t)owner, (gid_t)-1) < 0 || chown(lock, (uid_t)owner, (gid_t)-1) < 0)) {
        fprintf(stderr, "monad-wm: cannot give the socket to user %ld: %s\n", owner, strerror(errno));
        return -1;
    }
    snprintf(path, pathlen, "%s", addr.sun_path);
    return fd; /* the lock stays open, and ours, until we end */
}

static void print_windows(const mwm_server *server) {
    mwm_window list[MWM_MAX_WINDOWS];
    int n = mwm_server_windows(server, list, MWM_MAX_WINDOWS);
    printf("windows %d\n", n);
    for (int i = 0; i < n; i++) {
        printf("window %u %d %d %d %d app=%s title=%s\n", list[i].id, list[i].x, list[i].y, list[i].width, list[i].height,
               list[i].app_id, list[i].title);
    }
    fflush(stdout);
}

int main(int argc, char **argv) {
    int width = 3840, height = 2160;
    long owner = -1;
    const char *card = "/dev/dri/card0";
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--size") == 0 && i + 1 < argc && sscanf(argv[i + 1], "%dx%d", &width, &height) == 2) {
            i++;
        } else if (strcmp(argv[i], "--card") == 0 && i + 1 < argc) {
            card = argv[++i];
        } else if (strcmp(argv[i], "--owner") == 0 && i + 1 < argc) {
            owner = strtol(argv[++i], NULL, 10);
        } else {
            fprintf(stderr, "usage: monad-wm [--size WIDTHxHEIGHT] [--card /dev/dri/card0] [--owner UID]\n");
            return 64;
        }
    }
    const char *dir = getenv("XDG_RUNTIME_DIR");
    if (!dir || dir[0] != '/') {
        fprintf(stderr, "monad-wm: XDG_RUNTIME_DIR is not set\n");
        return 78;
    }

    char err[200];
    mwm_kms *kms = mwm_kms_open(card, width, height, err, sizeof err);
    if (!kms) {
        fprintf(stderr, "monad-wm: %s\n", err);
        return 69;
    }
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int listener = listen_at(dir, owner, path, sizeof path);
    if (listener < 0) return 69;

    mwm_screen screen = {.pixels = mwm_kms_pixels(kms), .width = width, .height = height, .stride = mwm_kms_stride(kms),
                         .present = present, .ctx = kms};
    mwm_server *server = mwm_server_new(&screen);
    if (!server) return 70;

    signal(SIGPIPE, SIG_IGN);
    struct sigaction stop = {.sa_handler = on_stop}, bus = {.sa_handler = on_bus};
    sigaction(SIGINT, &stop, NULL);
    sigaction(SIGTERM, &stop, NULL);
    sigaction(SIGBUS, &bus, NULL);

    printf("monad-wm: %dx%d at %s\n", width, height, path);
    fflush(stdout);
    uint32_t generation = mwm_server_generation(server), last_frame = now_ms();
    while (!stopping) {
        struct pollfd fds[1 + MWM_MAX_CLIENTS];
        int sockets[MWM_MAX_CLIENTS];
        bool wants[MWM_MAX_CLIENTS];
        int n = mwm_server_sockets(server, sockets, wants, MWM_MAX_CLIENTS);
        fds[0] = (struct pollfd){.fd = listener, .events = POLLIN};
        for (int i = 0; i < n; i++) fds[1 + i] = (struct pollfd){.fd = sockets[i], .events = (short)(POLLIN | (wants[i] ? POLLOUT : 0))};
        /* With programs connected, a frame every 16 ms; with none, nothing to wake for. */
        uint32_t now = now_ms();
        int wait = n == 0 ? -1 : (now - last_frame >= 16 ? 0 : (int)(16 - (now - last_frame)));
        int ready = poll(fds, (nfds_t)(1 + n), wait);
        if (ready < 0 && errno != EINTR) break;
        if (ready > 0) {
            if (fds[0].revents & POLLIN) {
                int fd = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
                if (fd >= 0) (void)mwm_server_add_client(server, fd);
            }
            for (int i = 0; i < n; i++) {
                if (fds[1 + i].revents) {
                    mwm_server_service(server, sockets[i], (fds[1 + i].revents & (POLLIN | POLLHUP | POLLERR)) != 0,
                                       (fds[1 + i].revents & POLLOUT) != 0);
                }
            }
        }
        now = now_ms();
        if (now - last_frame >= 16) {
            mwm_server_frame(server, now);
            last_frame = now;
        }
        if (mwm_server_generation(server) != generation) {
            generation = mwm_server_generation(server);
            print_windows(server);
        }
    }
    mwm_server_free(server);
    unlink(path);
    mwm_kms_close(kms);
    return 0;
}
