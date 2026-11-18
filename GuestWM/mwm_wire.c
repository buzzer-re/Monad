/*
 * mwm_wire.c — see mwm_wire.h.
 */
#include "mwm_wire.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

enum {
    IN_SIZE = 2 * MWM_MAX_MESSAGE,
    /* Descriptors sent with one sendmsg, and taken from one recvmsg. */
    FD_BATCH = 28,
};

struct mwm_conn {
    int fd;
    bool failed;

    uint8_t in[IN_SIZE];
    size_t in_len;
    /* The message handed out by mwm_conn_next, dropped at the next call. */
    size_t in_taken;
    int in_fds[MWM_MAX_FDS];
    int in_fd_count;

    uint8_t *out;
    size_t out_len, out_cap;
    int out_fds[MWM_MAX_FDS];
    int out_fd_count;
    /* Where the message being written starts in `out`; SIZE_MAX: none. */
    size_t writing;
};

static void set_cloexec(int fd) {
    int fdfl = fcntl(fd, F_GETFD);
    if (fdfl >= 0) (void)fcntl(fd, F_SETFD, fdfl | FD_CLOEXEC);
}

static void set_cloexec_nonblock(int fd) {
    int fl = fcntl(fd, F_GETFL);
    if (fl >= 0) (void)fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    set_cloexec(fd);
}

mwm_conn *mwm_conn_new(int fd) {
    mwm_conn *c = calloc(1, sizeof *c);
    if (!c) {
        close(fd);
        return NULL;
    }
    c->fd = fd;
    c->writing = SIZE_MAX;
    set_cloexec_nonblock(fd);
#ifdef SO_NOSIGPIPE
    /* Where a send cannot be told not to signal (the Mac, in tests): a client that left is an error, not a signal. */
    int on = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
#endif
    return c;
}

void mwm_conn_free(mwm_conn *c) {
    if (!c) return;
    for (int i = 0; i < c->in_fd_count; i++) close(c->in_fds[i]);
    for (int i = 0; i < c->out_fd_count; i++) close(c->out_fds[i]);
    close(c->fd);
    free(c->out);
    free(c);
}

int mwm_conn_fd(const mwm_conn *c) { return c->fd; }
bool mwm_conn_failed(const mwm_conn *c) { return c->failed; }
bool mwm_conn_wants_write(const mwm_conn *c) { return !c->failed && c->out_len > 0; }

/* The message handed out last is done with: what follows moves up. */
static void drop_taken(mwm_conn *c) {
    if (c->in_taken == 0) return;
    memmove(c->in, c->in + c->in_taken, c->in_len - c->in_taken);
    c->in_len -= c->in_taken;
    c->in_taken = 0;
}

int mwm_conn_read(mwm_conn *c) {
    if (c->failed) return -1;
    drop_taken(c);
    if (c->in_len == IN_SIZE) return 1; /* whole messages wait to be taken */
    union {
        struct cmsghdr align;
        char buf[CMSG_SPACE(sizeof(int) * FD_BATCH)];
    } control;
    struct iovec iov = {.iov_base = c->in + c->in_len, .iov_len = IN_SIZE - c->in_len};
    struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = control.buf, .msg_controllen = sizeof control.buf};
    ssize_t n;
    do {
#ifdef MSG_CMSG_CLOEXEC
        n = recvmsg(c->fd, &msg, MSG_CMSG_CLOEXEC);
#else
        n = recvmsg(c->fd, &msg, 0);
#endif
    } while (n < 0 && errno == EINTR);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        c->failed = true;
        return -1;
    }
    for (struct cmsghdr *cm = CMSG_FIRSTHDR(&msg); cm; cm = CMSG_NXTHDR(&msg, cm)) {
        if (cm->cmsg_level != SOL_SOCKET || cm->cmsg_type != SCM_RIGHTS) continue;
        size_t count = (cm->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        for (size_t i = 0; i < count; i++) {
            int fd;
            memcpy(&fd, CMSG_DATA(cm) + i * sizeof(int), sizeof fd);
            if (c->in_fd_count == MWM_MAX_FDS) {
                /* More than a client may hold unused. */
                close(fd);
                c->failed = true;
                continue;
            }
            set_cloexec(fd); /* where MSG_CMSG_CLOEXEC is not known */
            c->in_fds[c->in_fd_count++] = fd;
        }
    }
    if (n == 0 || c->failed || (msg.msg_flags & MSG_CTRUNC)) {
        c->failed = true;
        return -1;
    }
    c->in_len += (size_t)n;
    return 1;
}

static uint32_t word(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return v;
}

bool mwm_conn_next(mwm_conn *c, mwm_msg *m) {
    if (c->failed) return false;
    drop_taken(c);
    if (c->in_len < MWM_HEADER) return false;
    uint32_t second = word(c->in + 4);
    uint32_t size = second >> 16;
    if (size < MWM_HEADER || size % 4 != 0 || size > MWM_MAX_MESSAGE) {
        c->failed = true;
        return false;
    }
    if (c->in_len < size) return false;
    m->object = word(c->in);
    m->opcode = (uint16_t)(second & 0xffff);
    m->size = (uint16_t)size;
    m->body = c->in + MWM_HEADER;
    m->pos = 0;
    m->conn = c;
    m->bad = false;
    c->in_taken = size;
    return true;
}

static uint32_t body_len(const mwm_msg *m) { return (uint32_t)m->size - MWM_HEADER; }

uint32_t mwm_get_uint(mwm_msg *m) {
    if (m->bad || body_len(m) - m->pos < 4) {
        m->bad = true;
        return 0;
    }
    uint32_t v = word(m->body + m->pos);
    m->pos += 4;
    return v;
}

int32_t mwm_get_int(mwm_msg *m) { return (int32_t)mwm_get_uint(m); }

const uint8_t *mwm_get_array(mwm_msg *m, uint32_t *len) {
    *len = 0;
    uint32_t n = mwm_get_uint(m);
    if (m->bad) return NULL;
    uint32_t left = body_len(m) - m->pos;
    /* Checked before padding: a length near 2^32 would wrap. */
    if (n > left || ((n + 3) & ~3u) > left) {
        m->bad = true;
        return NULL;
    }
    const uint8_t *p = m->body + m->pos;
    m->pos += (n + 3) & ~3u;
    *len = n;
    return p;
}

const char *mwm_get_string(mwm_msg *m, uint32_t *len) {
    uint32_t n;
    const uint8_t *p = mwm_get_array(m, &n);
    *len = 0;
    if (!p || n == 0) return NULL; /* bad, or a null string */
    if (p[n - 1] != 0 || memchr(p, 0, n - 1)) {
        m->bad = true;
        return NULL;
    }
    *len = n - 1;
    return (const char *)p;
}

int mwm_get_fd(mwm_msg *m) {
    mwm_conn *c = m->conn;
    if (m->bad || c->in_fd_count == 0) {
        m->bad = true;
        return -1;
    }
    int fd = c->in_fds[0];
    c->in_fd_count--;
    memmove(c->in_fds, c->in_fds + 1, (size_t)c->in_fd_count * sizeof(int));
    return fd;
}

bool mwm_msg_done(const mwm_msg *m) { return !m->bad && m->pos == body_len(m); }

/* ------------------------------------------------------------------------ */
/* Writing                                                                   */

static uint8_t *out_room(mwm_conn *c, size_t n) {
    if (c->failed) return NULL;
    if (c->out_len + n > MWM_MAX_OUT) {
        c->failed = true; /* the client does not read */
        return NULL;
    }
    if (c->out_len + n > c->out_cap) {
        size_t cap = c->out_cap ? c->out_cap * 2 : 4096;
        while (cap < c->out_len + n) cap *= 2;
        uint8_t *grown = realloc(c->out, cap);
        if (!grown) {
            c->failed = true;
            return NULL;
        }
        c->out = grown;
        c->out_cap = cap;
    }
    uint8_t *p = c->out + c->out_len;
    c->out_len += n;
    return p;
}

void mwm_put_begin(mwm_conn *c, uint32_t object, uint16_t opcode) {
    size_t start = c->out_len;
    uint8_t *p = out_room(c, MWM_HEADER);
    if (!p) return;
    uint32_t second = opcode; /* the size is filled in by mwm_put_end */
    memcpy(p, &object, 4);
    memcpy(p + 4, &second, 4);
    c->writing = start;
}

void mwm_put_uint(mwm_conn *c, uint32_t v) {
    uint8_t *p = out_room(c, 4);
    if (p) memcpy(p, &v, 4);
}

void mwm_put_int(mwm_conn *c, int32_t v) { mwm_put_uint(c, (uint32_t)v); }

void mwm_put_array(mwm_conn *c, const void *data, uint32_t len) {
    if (len > MWM_MAX_MESSAGE) {
        c->failed = true;
        return;
    }
    mwm_put_uint(c, len);
    uint32_t padded = (len + 3) & ~3u;
    uint8_t *p = out_room(c, padded);
    if (!p) return;
    if (len) memcpy(p, data, len);
    memset(p + len, 0, padded - len);
}

void mwm_put_string(mwm_conn *c, const char *s) {
    if (!s) {
        mwm_put_uint(c, 0);
        return;
    }
    size_t n = strlen(s) + 1;
    if (n > MWM_MAX_MESSAGE) {
        c->failed = true;
        return;
    }
    mwm_put_array(c, s, (uint32_t)n);
}

void mwm_put_fd(mwm_conn *c, int fd) {
    if (c->failed) return;
    if (c->out_fd_count == MWM_MAX_FDS) {
        c->failed = true;
        return;
    }
    int copy = fcntl(fd, F_DUPFD_CLOEXEC, 0);
    if (copy < 0) {
        c->failed = true;
        return;
    }
    c->out_fds[c->out_fd_count++] = copy;
}

void mwm_put_end(mwm_conn *c) {
    if (c->failed || c->writing == SIZE_MAX) return;
    size_t size = c->out_len - c->writing;
    if (size > MWM_MAX_MESSAGE) {
        c->failed = true;
        return;
    }
    uint32_t second = word(c->out + c->writing + 4);
    second |= (uint32_t)size << 16;
    memcpy(c->out + c->writing + 4, &second, 4);
    c->writing = SIZE_MAX;
}

int mwm_conn_flush(mwm_conn *c) {
    if (c->failed) return -1;
    while (c->out_len > 0) {
        union {
            struct cmsghdr align;
            char buf[CMSG_SPACE(sizeof(int) * FD_BATCH)];
        } control;
        struct iovec iov = {.iov_base = c->out, .iov_len = c->out_len};
        struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1};
        /* The descriptors go with the first bytes: before any message that uses them is read. */
        int sending = c->out_fd_count < FD_BATCH ? c->out_fd_count : FD_BATCH;
        if (sending > 0) {
            memset(&control, 0, sizeof control);
            msg.msg_control = control.buf;
            msg.msg_controllen = CMSG_SPACE(sizeof(int) * (size_t)sending);
            struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
            cm->cmsg_level = SOL_SOCKET;
            cm->cmsg_type = SCM_RIGHTS;
            cm->cmsg_len = CMSG_LEN(sizeof(int) * (size_t)sending);
            memcpy(CMSG_DATA(cm), c->out_fds, sizeof(int) * (size_t)sending);
        }
        ssize_t n;
        do {
#ifdef MSG_NOSIGNAL
            n = sendmsg(c->fd, &msg, MSG_NOSIGNAL);
#else
            n = sendmsg(c->fd, &msg, 0);
#endif
        } while (n < 0 && errno == EINTR);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
            c->failed = true;
            return -1;
        }
        for (int i = 0; i < sending; i++) close(c->out_fds[i]);
        c->out_fd_count -= sending;
        memmove(c->out_fds, c->out_fds + sending, (size_t)c->out_fd_count * sizeof(int));
        memmove(c->out, c->out + n, c->out_len - (size_t)n);
        c->out_len -= (size_t)n;
        if (c->writing != SIZE_MAX) c->writing = c->writing >= (size_t)n ? c->writing - (size_t)n : 0;
    }
    return 1;
}
