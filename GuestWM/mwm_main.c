/*
 * mwm_main.c — monad-wm, Monad's window manager for a Linux VM's
 * programs: listens where programs look for a Wayland server
 * ($XDG_RUNTIME_DIR/wayland-0) and serves them (mwm_server.c), and
 * listens for MonadHost, which shows the windows on the Mac from the
 * pixels it is sent and has the pointer and the keyboard (mwm_ctl.c).
 * It takes no display: the windows are drawn on a sheet of memory.
 *
 *   monad-wm [--size WIDTHxHEIGHT] [--owner UID] [--control vsock:PORT | unix:PATH]
 *            [--gl vsock:PORT | unix:PATH]
 *
 * --size: the sheet, which every window has a place of its own on: the
 * room there is for windows (8192x8192 unless said; memory is only taken
 * where a window stands).
 * --owner: started as root, it gives the socket to that user, whose
 * programs then connect, and goes on as that user: what programs send it
 * is not read as root.
 * --control: where MonadHost connects. vsock:PORT is a port only the Mac
 * can dial (a connection from inside the VM is refused); unix:PATH is for
 * trying it by hand. Without it, nothing moves the pointer.
 * --gl: where MonadHost connects for drawing by the Mac's GPU (mwm_gl.h).
 * While it is connected, programs find $XDG_RUNTIME_DIR/monad-gl, which
 * Monad's own OpenGL library in the VM draws through; without, there is
 * no such socket and programs draw as they would anyway.
 * Linux only.
 */
#define _GNU_SOURCE /* accept4, ppoll */
#include "mwm_ctl.h"
#include "mwm_gl.h"
#include "mwm_server.h"

#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <linux/vm_sockets.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

/* Sixty frames a second while a program waits for one. */
#define FRAME_NS 16666667ull

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

static uint64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
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

/* Where MonadHost connects; *vsock says which kind it is. */
static int listen_for_host(const char *where, long owner, bool *vsock) {
    int fd = -1;
    *vsock = strncmp(where, "vsock:", 6) == 0;
    if (*vsock) {
        char *end;
        unsigned long port = strtoul(where + 6, &end, 10);
        struct sockaddr_vm addr = {.svm_family = AF_VSOCK, .svm_cid = VMADDR_CID_ANY, .svm_port = (unsigned)port};
        if (*end || port == 0 || port > 0xffff) {
            fprintf(stderr, "monad-wm: %s is no vsock port\n", where);
            return -1;
        }
        fd = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        if (fd < 0 || bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0 || listen(fd, 1) < 0) {
            fprintf(stderr, "monad-wm: cannot listen on %s: %s\n", where, strerror(errno));
            return -1;
        }
    } else if (strncmp(where, "unix:/", 6) == 0) {
        struct sockaddr_un addr = {.sun_family = AF_UNIX};
        if (snprintf(addr.sun_path, sizeof addr.sun_path, "%s", where + 5) >= (int)sizeof addr.sun_path) {
            fprintf(stderr, "monad-wm: %s is too long a place for a socket\n", where);
            return -1;
        }
        unlink(addr.sun_path);
        fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        mode_t before = umask(0177); /* the pointer and the keys are its owner's alone */
        bool ok = fd >= 0 && bind(fd, (struct sockaddr *)&addr, sizeof addr) == 0 && listen(fd, 1) == 0;
        umask(before);
        ok = ok && (owner < 0 || chown(addr.sun_path, (uid_t)owner, (gid_t)-1) == 0);
        if (!ok) {
            fprintf(stderr, "monad-wm: cannot listen at %s: %s\n", where, strerror(errno));
            return -1;
        }
    } else {
        fprintf(stderr, "monad-wm: --control takes vsock:PORT or unix:/PATH\n");
    }
    return fd;
}

/* Where programs' OpenGL libraries connect, while MonadHost is there to
 * draw for them: the user's own socket in the user's own folder. */
static int listen_for_programs(const char *dir, char *path, size_t pathlen) {
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    if (snprintf(addr.sun_path, sizeof addr.sun_path, "%s/" MWM_GL_SOCKET, dir) >= (int)sizeof addr.sun_path) return -1;
    unlink(addr.sun_path);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    mode_t before = umask(0177);
    bool ok = fd >= 0 && bind(fd, (struct sockaddr *)&addr, sizeof addr) == 0 && listen(fd, 16) == 0;
    umask(before);
    if (!ok) {
        if (fd >= 0) close(fd);
        return -1;
    }
    snprintf(path, pathlen, "%s", addr.sun_path);
    return fd;
}

/* MonadHost's connection, or -1: on a vsock port only the Mac's is taken. */
static int accept_host(int listener, bool vsock) {
    struct sockaddr_vm peer;
    socklen_t len = sizeof peer;
    int fd = vsock ? accept4(listener, (struct sockaddr *)&peer, &len, SOCK_CLOEXEC) : accept4(listener, NULL, NULL, SOCK_CLOEXEC);
    if (fd >= 0 && vsock && peer.svm_cid != VMADDR_CID_HOST) {
        close(fd); /* something in the VM dialed its own port: it is not the Mac */
        return -1;
    }
    return fd;
}

/* From root to the user whose programs these are, for good. */
static bool become(long owner) {
    struct passwd *user = getpwuid((uid_t)owner);
    if (!user) {
        fprintf(stderr, "monad-wm: there is no user %ld\n", owner);
        return false;
    }
    if (getuid() != 0) return true; /* started as that user already, or as another who cannot change */
    if (setgroups(0, NULL) < 0 || setgid(user->pw_gid) < 0 || setuid(user->pw_uid) < 0 || setuid(0) == 0) {
        fprintf(stderr, "monad-wm: cannot go on as user %ld: %s\n", owner, strerror(errno));
        return false;
    }
    return true;
}

int main(int argc, char **argv) {
    int width = MWM_MAX_SIDE, height = MWM_MAX_SIDE;
    long owner = -1;
    const char *control = NULL, *drawing = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--size") == 0 && i + 1 < argc && sscanf(argv[i + 1], "%dx%d", &width, &height) == 2) {
            i++;
        } else if (strcmp(argv[i], "--owner") == 0 && i + 1 < argc) {
            owner = strtol(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--control") == 0 && i + 1 < argc) {
            control = argv[++i];
        } else if (strcmp(argv[i], "--gl") == 0 && i + 1 < argc) {
            drawing = argv[++i];
        } else {
            fprintf(stderr, "usage: monad-wm [--size WIDTHxHEIGHT] [--owner UID] [--control vsock:PORT | unix:/PATH]"
                            " [--gl vsock:PORT | unix:/PATH]\n");
            return 64;
        }
    }
    const char *dir = getenv("XDG_RUNTIME_DIR");
    if (!dir || dir[0] != '/') {
        fprintf(stderr, "monad-wm: XDG_RUNTIME_DIR is not set\n");
        return 78;
    }

    if (width < 64 || height < 64 || width > MWM_MAX_SIDE || height > MWM_MAX_SIDE) {
        fprintf(stderr, "monad-wm: the sheet is from 64x64 to %dx%d\n", MWM_MAX_SIDE, MWM_MAX_SIDE);
        return 64;
    }
    /* The sheet: all zero, and no memory taken for a part until a window is drawn there. */
    size_t bytes = (size_t)width * (size_t)height * 4;
    uint32_t *sheet = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (sheet == MAP_FAILED) {
        fprintf(stderr, "monad-wm: no memory for a sheet of %dx%d: %s\n", width, height, strerror(errno));
        return 71;
    }
    /* What may need root first: the places to listen. */
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int listener = listen_at(dir, owner, path, sizeof path);
    if (listener < 0) return 69;
    bool vsock = false;
    int host_listener = control ? listen_for_host(control, owner, &vsock) : -1;
    if (control && host_listener < 0) return 69;
    bool gl_vsock = false;
    int gl_listener = drawing ? listen_for_host(drawing, owner, &gl_vsock) : -1;
    if (drawing && gl_listener < 0) return 69;
    if (owner >= 0 && !become(owner)) return 77;

    mwm_screen screen = {.pixels = sheet, .width = width, .height = height, .stride = width};
    mwm_server *server = mwm_server_new(&screen);
    mwm_ctl *ctl = server ? mwm_ctl_new(server) : NULL;
    mwm_gl *gl = mwm_gl_new();
    if (!ctl || !gl) return 70;
    /* Where programs connect to draw, while MonadHost is connected for it. */
    int gl_programs = -1;
    char gl_path[sizeof(((struct sockaddr_un *)0)->sun_path)] = "";

    signal(SIGPIPE, SIG_IGN);
    struct sigaction stop = {.sa_handler = on_stop}, bus = {.sa_handler = on_bus};
    sigaction(SIGINT, &stop, NULL);
    sigaction(SIGTERM, &stop, NULL);
    sigaction(SIGBUS, &bus, NULL);

    printf("monad-wm: %dx%d at %s\n", width, height, path);
    fflush(stdout);
    /* When the next frame is due. Frames keep to a grid of their own: counted
     * in whole milliseconds from when a program asked, a program that draws
     * every frame got fifty a second. */
    uint64_t due = now_ns();
    while (!stopping) {
        enum { FIXED = 5 };
        struct pollfd fds[FIXED + MWM_MAX_SOCKETS + MWM_GL_SOCKETS];
        int sockets[MWM_MAX_SOCKETS];
        bool wants[MWM_MAX_SOCKETS];
        int n = mwm_server_sockets(server, sockets, wants, MWM_MAX_SOCKETS);
        fds[0] = (struct pollfd){.fd = listener, .events = POLLIN};
        fds[1] = (struct pollfd){.fd = host_listener, .events = POLLIN};
        fds[2] = (struct pollfd){.fd = mwm_ctl_fd(ctl), .events = (short)(POLLIN | (mwm_ctl_wants_write(ctl) ? POLLOUT : 0))};
        /* The programs' drawing socket is there exactly while MonadHost is connected for drawing. */
        if (mwm_gl_attached(gl) && gl_programs < 0) {
            gl_programs = listen_for_programs(dir, gl_path, sizeof gl_path);
        } else if (!mwm_gl_attached(gl) && gl_programs >= 0) {
            close(gl_programs);
            unlink(gl_path);
            gl_programs = -1;
        }
        fds[3] = (struct pollfd){.fd = gl_listener, .events = POLLIN};
        fds[4] = (struct pollfd){.fd = gl_programs, .events = POLLIN};
        for (int i = 0; i < n; i++) {
            fds[FIXED + i] = (struct pollfd){.fd = sockets[i], .events = (short)(POLLIN | (wants[i] ? POLLOUT : 0))};
        }
        int gl_fds[MWM_GL_SOCKETS];
        bool gl_reads[MWM_GL_SOCKETS], gl_writes[MWM_GL_SOCKETS];
        int gl_n = mwm_gl_sockets(gl, gl_fds, gl_reads, gl_writes, MWM_GL_SOCKETS);
        for (int i = 0; i < gl_n; i++) {
            fds[FIXED + n + i] = (struct pollfd){.fd = gl_fds[i], .events = (short)((gl_reads[i] ? POLLIN : 0) | (gl_writes[i] ? POLLOUT : 0))};
        }
        /* With no program waiting to draw (and no copy waited for), there is nothing to wake up for. */
        uint64_t at = now_ns(), left = at >= due ? 0 : due - at;
        struct timespec wait = {.tv_sec = (time_t)(left / 1000000000ull), .tv_nsec = (long)(left % 1000000000ull)};
        int ready = ppoll(fds, (nfds_t)(FIXED + n + gl_n), mwm_server_wants_frame(server) ? &wait : NULL, NULL);
        if (ready < 0 && errno != EINTR) break;
        at = now_ns();
        uint32_t now = (uint32_t)(at / 1000000);
        if (ready > 0) {
            if (fds[0].revents & POLLIN) {
                int fd = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
                if (fd >= 0) (void)mwm_server_add_client(server, fd);
            }
            /* MonadHost's words first: where the pointer is before what programs do about it. */
            if (fds[2].revents) mwm_ctl_service(ctl, (fds[2].revents & (POLLIN | POLLHUP | POLLERR)) != 0, true, now);
            if (fds[1].revents & POLLIN) {
                int fd = accept_host(host_listener, vsock);
                if (fd >= 0) mwm_ctl_attach(ctl, fd);
            }
            for (int i = 0; i < n; i++) {
                if (fds[FIXED + i].revents) {
                    mwm_server_service(server, sockets[i], (fds[FIXED + i].revents & (POLLIN | POLLHUP | POLLERR)) != 0,
                                       (fds[FIXED + i].revents & POLLOUT) != 0);
                }
            }
            /* Drawing: what there was to poll before anything below changes it. */
            for (int i = 0; i < gl_n; i++) {
                short got = fds[FIXED + n + i].revents;
                if (got) mwm_gl_service(gl, gl_fds[i], (got & (POLLIN | POLLHUP | POLLERR)) != 0, (got & POLLOUT) != 0);
            }
            if (fds[3].revents & POLLIN) {
                int fd = accept_host(gl_listener, gl_vsock);
                if (fd >= 0) mwm_gl_attach(gl, fd);
            }
            if (gl_programs >= 0 && (fds[4].revents & POLLIN)) {
                int fd = accept4(gl_programs, NULL, NULL, SOCK_CLOEXEC);
                if (fd >= 0) (void)mwm_gl_add(gl, fd);
            }
        }
        if (mwm_server_wants_frame(server) && at >= due) {
            mwm_server_frame(server, now);
            /* On the grid while frames follow each other; from now when none was asked for a while. */
            due = at - due > FRAME_NS ? at + FRAME_NS : due + FRAME_NS;
        }
        mwm_ctl_update(ctl);
    }
    mwm_ctl_free(ctl);
    mwm_gl_free(gl);
    if (gl_programs >= 0) unlink(gl_path);
    mwm_server_free(server);
    unlink(path);
    munmap(sheet, bytes);
    return 0;
}
