/*
 * mnd_bridge.c — unix socket <-> upstream fd splice server.
 */
#include "mnd_bridge.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define BRIDGE_BUF (64 * 1024)
#define BRIDGE_MAX_CONN 64

typedef struct conn {
    struct mnd_bridge *bridge;
    int client;
    int upstream;
    struct conn *next;
} conn;

struct mnd_bridge {
    char *path;
    int listen_fd;
    int wake[2];
    pthread_t accept_thread;
    mnd_bridge_upstream up;

    pthread_mutex_t mu;
    pthread_cond_t cv;
    conn *conns;
    int active;
    bool stopping;
};

static void set_cloexec(int fd) {
    int fl = fcntl(fd, F_GETFD);
    if (fl >= 0) fcntl(fd, F_SETFD, fl | FD_CLOEXEC);
}

static void set_nosigpipe(int fd) {
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#else
    (void)fd;
#endif
}

static ssize_t send_all(int fd, const char *p, size_t n) {
    size_t off = 0;
    while (off < n) {
#ifdef MSG_NOSIGNAL
        ssize_t w = send(fd, p + off, n - off, MSG_NOSIGNAL);
        if (w < 0 && errno == ENOTSOCK) w = write(fd, p + off, n - off);
#else
        ssize_t w = write(fd, p + off, n - off);
#endif
        if (w < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                struct pollfd pfd = {fd, POLLOUT, 0};
                if (poll(&pfd, 1, 30000) <= 0) return -1;
                continue;
            }
            return -1;
        }
        off += (size_t)w;
    }
    return (ssize_t)off;
}

/* Copy both directions until both sides have closed or an error occurs. */
static void splice_loop(int a, int b) {
    char *buf = malloc(BRIDGE_BUF);
    if (!buf) return;
    bool a_open = true, b_open = true; /* readable sides */
    while (a_open || b_open) {
        struct pollfd p[2];
        int n = 0, ia = -1, ib = -1;
        if (a_open) {
            ia = n;
            p[n++] = (struct pollfd){a, POLLIN, 0};
        }
        if (b_open) {
            ib = n;
            p[n++] = (struct pollfd){b, POLLIN, 0};
        }
        int r = poll(p, (nfds_t)n, -1);
        if (r < 0) {
            if (errno == EINTR) continue;
            break;
        }
        bool fail = false, handled = false;
        for (int k = 0; k < 2 && !fail; k++) {
            int idx = k == 0 ? ia : ib;
            if (idx < 0) continue;
            /* The descriptor was closed underneath us (the hypervisor drops
             * vsock connections when the VM stops): poll() would report
             * this forever, so the session is over. */
            if (p[idx].revents & POLLNVAL) {
                fail = true;
                break;
            }
            if (!(p[idx].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            handled = true;
            int from = k == 0 ? a : b, to = k == 0 ? b : a;
            ssize_t got = read(from, buf, BRIDGE_BUF);
            if (got < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            if (got <= 0) {
                /* EOF (or error) on this side: propagate the half-close. */
                shutdown(to, SHUT_WR);
                if (k == 0) a_open = false;
                else b_open = false;
                if (got < 0) fail = true;
                continue;
            }
            if (send_all(to, buf, (size_t)got) < 0) fail = true;
        }
        /* Never loop on events we cannot act on: that would spin. */
        if (fail || !handled) break;
    }
    free(buf);
}

static void *conn_thread(void *arg) {
    conn *c = arg;
    mnd_bridge *b = c->bridge;

    int up = b->up.connect(b->up.ctx);
    pthread_mutex_lock(&b->mu);
    c->upstream = up;
    bool stopping = b->stopping;
    pthread_mutex_unlock(&b->mu);

    if (up >= 0 && !stopping) {
        set_nosigpipe(up);
        splice_loop(c->client, up);
    }

    pthread_mutex_lock(&b->mu);
    for (conn **pp = &b->conns; *pp; pp = &(*pp)->next) {
        if (*pp == c) {
            *pp = c->next;
            break;
        }
    }
    close(c->client);
    c->client = -1;
    c->upstream = -1;
    pthread_mutex_unlock(&b->mu);
    if (up >= 0) {
        if (b->up.release) b->up.release(b->up.ctx, up);
        else close(up);
    }

    pthread_mutex_lock(&b->mu);
    b->active--;
    pthread_cond_broadcast(&b->cv);
    pthread_mutex_unlock(&b->mu);
    free(c);
    return NULL;
}

static void *accept_thread(void *arg) {
    mnd_bridge *b = arg;
    for (;;) {
        struct pollfd p[2] = {{b->listen_fd, POLLIN, 0}, {b->wake[0], POLLIN, 0}};
        int r = poll(p, 2, -1);
        if (r < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (p[1].revents) break;
        if (!(p[0].revents & POLLIN)) continue;
        int fd = accept(b->listen_fd, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR || errno == ECONNABORTED || errno == EAGAIN) continue;
            if (errno == EMFILE || errno == ENFILE) {
                usleep(100000);
                continue;
            }
            break;
        }
        set_cloexec(fd);
        set_nosigpipe(fd);
        int fl = fcntl(fd, F_GETFL);
        if (fl >= 0) fcntl(fd, F_SETFL, fl & ~O_NONBLOCK);

        conn *c = calloc(1, sizeof *c);
        pthread_mutex_lock(&b->mu);
        bool refuse = !c || b->stopping || b->active >= BRIDGE_MAX_CONN;
        if (!refuse) {
            c->bridge = b;
            c->client = fd;
            c->upstream = -1;
            c->next = b->conns;
            b->conns = c;
            b->active++;
        }
        pthread_mutex_unlock(&b->mu);
        if (refuse) {
            close(fd);
            free(c);
            continue;
        }
        pthread_t t;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&t, &attr, conn_thread, c) != 0) {
            pthread_mutex_lock(&b->mu);
            for (conn **pp = &b->conns; *pp; pp = &(*pp)->next) {
                if (*pp == c) {
                    *pp = c->next;
                    break;
                }
            }
            b->active--;
            pthread_cond_broadcast(&b->cv);
            pthread_mutex_unlock(&b->mu);
            close(fd);
            free(c);
        }
        pthread_attr_destroy(&attr);
    }
    return NULL;
}

mnd_bridge *mnd_bridge_start(const char *socket_path, mnd_bridge_upstream upstream, int *err) {
    int e = 0;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    if (!socket_path || !upstream.connect || strlen(socket_path) >= sizeof addr.sun_path) {
        if (err) *err = ENAMETOOLONG;
        return NULL;
    }
    mnd_bridge *b = calloc(1, sizeof *b);
    if (!b) {
        if (err) *err = ENOMEM;
        return NULL;
    }
    b->listen_fd = -1;
    b->wake[0] = b->wake[1] = -1;
    b->up = upstream;
    b->path = strdup(socket_path);
    pthread_mutex_init(&b->mu, NULL);
    pthread_cond_init(&b->cv, NULL);
    if (!b->path) {
        e = ENOMEM;
        goto fail;
    }

    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof addr.sun_path - 1);

    /* Replace a stale socket, but never clobber a non-socket file. */
    struct stat st;
    if (lstat(socket_path, &st) == 0) {
        if (!S_ISSOCK(st.st_mode)) {
            e = EEXIST;
            goto fail;
        }
        unlink(socket_path);
    }

    b->listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (b->listen_fd < 0) {
        e = errno;
        goto fail;
    }
    set_cloexec(b->listen_fd);
    mode_t old = umask(0177);
    int br = bind(b->listen_fd, (struct sockaddr *)&addr, sizeof addr);
    umask(old);
    if (br != 0) {
        e = errno;
        goto fail;
    }
    chmod(socket_path, 0600);
    if (listen(b->listen_fd, 16) != 0) {
        e = errno;
        goto fail;
    }
    if (pipe(b->wake) != 0) {
        e = errno;
        b->wake[0] = b->wake[1] = -1;
        goto fail;
    }
    set_cloexec(b->wake[0]);
    set_cloexec(b->wake[1]);
    if (pthread_create(&b->accept_thread, NULL, accept_thread, b) != 0) {
        e = EAGAIN;
        goto fail;
    }
    return b;

fail:
    if (b->listen_fd >= 0) {
        close(b->listen_fd);
        unlink(socket_path);
    }
    if (b->wake[0] >= 0) close(b->wake[0]);
    if (b->wake[1] >= 0) close(b->wake[1]);
    pthread_mutex_destroy(&b->mu);
    pthread_cond_destroy(&b->cv);
    free(b->path);
    free(b);
    if (err) *err = e;
    return NULL;
}

void mnd_bridge_stop(mnd_bridge *b) {
    if (!b) return;
    pthread_mutex_lock(&b->mu);
    b->stopping = true;
    pthread_mutex_unlock(&b->mu);

    char x = 1;
    ssize_t w;
    do {
        w = write(b->wake[1], &x, 1);
    } while (w < 0 && errno == EINTR);
    pthread_join(b->accept_thread, NULL);
    close(b->listen_fd);
    unlink(b->path);

    /* Unblock splice loops; each thread closes its own fds. */
    pthread_mutex_lock(&b->mu);
    for (conn *c = b->conns; c; c = c->next) {
        if (c->client >= 0) shutdown(c->client, SHUT_RDWR);
        if (c->upstream >= 0) shutdown(c->upstream, SHUT_RDWR);
    }
    while (b->active > 0) pthread_cond_wait(&b->cv, &b->mu);
    pthread_mutex_unlock(&b->mu);

    close(b->wake[0]);
    close(b->wake[1]);
    pthread_mutex_destroy(&b->mu);
    pthread_cond_destroy(&b->cv);
    free(b->path);
    free(b);
}

int mnd_bridge_active(mnd_bridge *b) {
    pthread_mutex_lock(&b->mu);
    int n = b->active;
    pthread_mutex_unlock(&b->mu);
    return n;
}
