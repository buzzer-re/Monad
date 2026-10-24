/*
 * mnd_netd_serve.c — monad-netd's main loop: the control channel from
 * MonadHost and everything netd carries, on one event loop.
 *
 * Replies are buffered, never written with a blocking call: if MonadHost
 * stops reading, netd stops reading commands once REPLY_PAUSE bytes of
 * replies wait (backpressure) and keeps carrying VM traffic. Commands are
 * read at most READ_CHUNK bytes at a time, which bounds the replies one read
 * can produce, so the reply buffer has a fixed size.
 */
#include "mnd_netd.h"
#include "mnd_netd_ctl.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifdef __APPLE__
#define SEND_FLAGS 0
#else
#define SEND_FLAGS MSG_NOSIGNAL
#endif

/* The longest line netd sends, newline included: mnd_ctl builds a reply in
 * MND_CTL_MAX_LINE bytes, its NUL included, and an event is shorter. A line
 * is sent whole or the session ends; a cut page of conns would say next=0
 * and hide everything after the cut. */
#define REPLY_MAX MND_CTL_MAX_LINE
#define READ_CHUNK 256
#define REPLY_PAUSE (64 * 1024)
/* One read of READ_CHUNK bytes holds at most READ_CHUNK commands, each
 * answered with one line; an event may land just before it (about 320 KB). */
#define REPLY_CAP (REPLY_PAUSE + MND_NETD_EVENT_MAX + 1 + READ_CHUNK * REPLY_MAX)

typedef struct {
    mnd_netd *d;
    mnd_ctl *ctl;
    int fd;
    bool done;
    int status;
    size_t outlen;
    char out[REPLY_CAP];
} server;

static void stop(server *s, int status) {
    if (s->done) return;
    s->done = true;
    s->status = status;
}

static void on_reply(void *ctx, const char *line) {
    server *s = ctx;
    size_t n = strnlen(line, REPLY_MAX);
    if (n >= REPLY_MAX || s->outlen + n + 1 > sizeof s->out) {
        stop(s, -1); /* cannot happen with the bounds above; never cut a line */
        return;
    }
    memcpy(s->out + s->outlen, line, n);
    s->out[s->outlen + n] = '\n';
    s->outlen += n + 1;
}

static void flush(server *s);
static void rewatch(server *s);

/* Events are dropped rather than stall netd when MonadHost is not reading.
 * They come from VM traffic, not from a command: sent from here. */
static void on_event(void *ctx, const char *line) {
    server *s = ctx;
    if (s->done || s->outlen > REPLY_PAUSE) return;
    on_reply(s, line);
    flush(s);
    rewatch(s);
}

static void flush(server *s) {
    while (s->outlen) {
        ssize_t n = send(s->fd, s->out, s->outlen, MSG_DONTWAIT | SEND_FLAGS);
        if (n > 0) {
            memmove(s->out, s->out + n, s->outlen - (size_t)n);
            s->outlen -= (size_t)n;
        } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
            return;
        } else {
            stop(s, 0); /* MonadHost is gone */
            return;
        }
    }
}

static void on_control(void *ctx, int fd, unsigned events);

static void rewatch(server *s) {
    unsigned ev = 0;
    if (!s->done && s->outlen < REPLY_PAUSE) ev |= MND_LOOP_READ;
    if (!s->done && s->outlen) ev |= MND_LOOP_WRITE;
    mnd_loop_watch(mnd_netd_loop(s->d), s->fd, ev, on_control, s);
}

static void read_commands(server *s) {
    char data[READ_CHUNK];
    union {
        struct cmsghdr h;
        char space[CMSG_SPACE(sizeof(int) * MND_CTL_MAX_FDS)];
    } u;
    struct iovec iov = {.iov_base = data, .iov_len = sizeof data};
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_iov = &iov;
    m.msg_iovlen = 1;
    m.msg_control = u.space;
    m.msg_controllen = sizeof u.space;
    ssize_t n = recvmsg(s->fd, &m, MSG_DONTWAIT);
    if (n < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) stop(s, 0);
        return;
    }
    int fds[MND_CTL_MAX_FDS];
    int nfds = 0;
    bool bad = (m.msg_flags & MSG_CTRUNC) != 0;
    for (struct cmsghdr *cm = CMSG_FIRSTHDR(&m); cm; cm = CMSG_NXTHDR(&m, cm)) {
        if (cm->cmsg_level != SOL_SOCKET || cm->cmsg_type != SCM_RIGHTS) {
            bad = true;
            continue;
        }
        size_t count = (cm->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        for (size_t i = 0; i < count; i++) {
            int fd;
            memcpy(&fd, CMSG_DATA(cm) + i * sizeof(int), sizeof fd);
            if (nfds < MND_CTL_MAX_FDS) {
                fcntl(fd, F_SETFD, FD_CLOEXEC);
                fds[nfds++] = fd;
            } else {
                close(fd);
                bad = true;
            }
        }
    }
    if (bad) {
        for (int i = 0; i < nfds; i++) close(fds[i]);
        stop(s, 1);
        return;
    }
    if (n == 0 && nfds == 0) {
        stop(s, 0); /* MonadHost closed the channel */
        return;
    }
    if (mnd_ctl_feed(s->ctl, data, (size_t)n, fds, nfds) != 0) stop(s, 1);
}

static void on_control(void *ctx, int fd, unsigned events) {
    server *s = ctx;
    (void)fd;
    if (events & MND_LOOP_WRITE) flush(s);
    if (!s->done && (events & MND_LOOP_READ) && s->outlen < REPLY_PAUSE) read_commands(s);
    if (!s->done) flush(s);
    rewatch(s);
}

int mnd_netd_serve(int control_fd) {
    if (control_fd < 0 || control_fd >= MND_LOOP_MAX_FDS) return -1;
    fcntl(control_fd, F_SETFL, fcntl(control_fd, F_GETFL) | O_NONBLOCK);
    fcntl(control_fd, F_SETFD, FD_CLOEXEC);
#ifdef __APPLE__
    int on = 1;
    setsockopt(control_fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
#endif
    server *s = calloc(1, sizeof *s);
    if (!s) {
        close(control_fd);
        return -1;
    }
    s->fd = control_fd;
    s->d = mnd_netd_create();
    s->ctl = s->d ? mnd_ctl_create(s->d, on_reply, s) : NULL;
    if (!s->ctl) {
        stop(s, -1);
    } else {
        mnd_netd_set_event_sink(s->d, on_event, s);
        rewatch(s);
    }
    while (!s->done)
        if (mnd_netd_run_once(s->d, UINT64_MAX) != 0) stop(s, -1);
    int status = s->status;
    if (s->d) mnd_loop_watch(mnd_netd_loop(s->d), control_fd, 0, NULL, NULL);
    mnd_ctl_destroy(s->ctl);
    mnd_netd_destroy(s->d);
    close(control_fd);
    free(s);
    return status;
}

int mnd_netd_send_command(int control, const char *line, int fd) {
    char data[MND_CTL_MAX_LINE + 1];
    size_t n = strnlen(line, MND_CTL_MAX_LINE + 1);
    if (n > MND_CTL_MAX_LINE - 1 || memchr(line, '\n', n)) return -1;
    memcpy(data, line, n);
    data[n++] = '\n';
    struct iovec iov = {.iov_base = data, .iov_len = n};
    union {
        struct cmsghdr h;
        char space[CMSG_SPACE(sizeof(int))];
    } u;
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_iov = &iov;
    m.msg_iovlen = 1;
    if (fd >= 0) {
        memset(&u, 0, sizeof u);
        m.msg_control = u.space;
        m.msg_controllen = sizeof u.space;
        struct cmsghdr *cm = CMSG_FIRSTHDR(&m);
        cm->cmsg_level = SOL_SOCKET;
        cm->cmsg_type = SCM_RIGHTS;
        cm->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(cm), &fd, sizeof fd);
    }
    ssize_t sent;
    do {
        sent = sendmsg(control, &m, SEND_FLAGS);
    } while (sent < 0 && errno == EINTR);
    return sent == (ssize_t)n ? 0 : -1;
}
