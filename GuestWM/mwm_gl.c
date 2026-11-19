/*
 * mwm_gl.c — see mwm_gl.h.
 */
#include "mwm_gl.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

enum {
    /* Bytes that may wait for a side that is slow to read: beyond, the other side is not read from. */
    WAITING = 2 << 20,
    /* Read at once. */
    PIECE = 64 << 10,
};

typedef struct {
    uint8_t *bytes;
    size_t len, sent, cap;
} queue;

typedef struct {
    int fd; /* -1: free */
    uint32_t stream;
    queue out;
} program;

struct mwm_gl {
    int host;
    queue host_out;
    /* A frame from MonadHost being read: its head so far, then whose it is and how much of it is still to come. */
    uint8_t head[8];
    size_t head_len;
    uint32_t in_stream, in_left;
    /* MonadHost's own word (stream 0) being read: its bytes so far. */
    uint8_t word[8];
    size_t word_len;
    uint32_t next_stream;
    program programs[MWM_GL_STREAMS];
};

static bool put(queue *q, const void *bytes, size_t n) {
    if (q->sent == q->len) q->sent = q->len = 0;
    if (q->len + n > q->cap) {
        if (q->sent > 0) { /* what went is room again */
            memmove(q->bytes, q->bytes + q->sent, q->len - q->sent);
            q->len -= q->sent;
            q->sent = 0;
        }
        if (q->len + n > q->cap) {
            size_t cap = q->cap ? q->cap : PIECE;
            while (cap < q->len + n) cap *= 2;
            uint8_t *grown = realloc(q->bytes, cap);
            if (!grown) return false;
            q->bytes = grown;
            q->cap = cap;
        }
    }
    memcpy(q->bytes + q->len, bytes, n);
    q->len += n;
    return true;
}

static size_t waiting(const queue *q) { return q->len - q->sent; }

/* Sends what waits, as far as the socket takes it. False when the other side is gone. */
static bool flush(int fd, queue *q) {
    while (q->sent < q->len) {
        ssize_t n = send(fd, q->bytes + q->sent, q->len - q->sent, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return true;
        if (n <= 0) return false;
        q->sent += (size_t)n;
    }
    return true;
}

static bool prepare(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return false;
#ifdef SO_NOSIGPIPE
    int on = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
#endif
    return true;
}

mwm_gl *mwm_gl_new(void) {
    mwm_gl *g = calloc(1, sizeof *g);
    if (!g) return NULL;
    g->host = -1;
    for (int i = 0; i < MWM_GL_STREAMS; i++) g->programs[i].fd = -1;
    return g;
}

static void program_gone(mwm_gl *g, program *p, bool tell) {
    if (!p || p->fd < 0) return;
    close(p->fd);
    p->fd = -1;
    free(p->out.bytes);
    p->out = (queue){0};
    if (tell && g->host >= 0) (void)put(&g->host_out, (uint32_t[]){0, 8, MWM_GL_CLOSED, p->stream}, 16);
}

/* MonadHost is gone: what the programs drew with is gone with it. */
static void host_gone(mwm_gl *g) {
    if (g->host >= 0) close(g->host);
    g->host = -1;
    free(g->host_out.bytes);
    g->host_out = (queue){0};
    g->head_len = 0;
    g->in_left = 0;
    g->word_len = 0;
    for (int i = 0; i < MWM_GL_STREAMS; i++) program_gone(g, &g->programs[i], false);
}

void mwm_gl_free(mwm_gl *g) {
    if (!g) return;
    host_gone(g);
    free(g);
}

void mwm_gl_attach(mwm_gl *g, int fd) {
    host_gone(g);
    if (!prepare(fd)) {
        close(fd);
        return;
    }
    g->host = fd;
    g->next_stream = 1;
}

bool mwm_gl_attached(const mwm_gl *g) { return g->host >= 0; }

bool mwm_gl_add(mwm_gl *g, int fd) {
    program *p = NULL;
    for (int i = 0; i < MWM_GL_STREAMS && !p; i++)
        if (g->programs[i].fd < 0) p = &g->programs[i];
    if (g->host < 0 || !p || !prepare(fd)) {
        close(fd);
        return false;
    }
    *p = (program){.fd = fd, .stream = g->next_stream++};
    if (!put(&p->out, (uint32_t[]){MWM_GL_MAGIC, p->stream}, 8) || !put(&g->host_out, (uint32_t[]){0, 8, MWM_GL_OPENED, p->stream}, 16)) {
        program_gone(g, p, false);
        return false;
    }
    if (!flush(p->fd, &p->out)) program_gone(g, p, true);
    return p->fd >= 0;
}

/* Whether any program has more waiting for it than may: MonadHost is then not read from. */
static bool a_program_is_slow(const mwm_gl *g) {
    for (int i = 0; i < MWM_GL_STREAMS; i++)
        if (g->programs[i].fd >= 0 && waiting(&g->programs[i].out) > WAITING) return true;
    return false;
}

int mwm_gl_sockets(const mwm_gl *g, int *fds, bool *wants_read, bool *wants_write, int max) {
    int n = 0;
    if (g->host < 0) return 0;
    bool host_slow = waiting(&g->host_out) > WAITING;
    if (n < max) {
        fds[n] = g->host;
        wants_read[n] = !a_program_is_slow(g);
        wants_write[n++] = waiting(&g->host_out) > 0;
    }
    for (int i = 0; i < MWM_GL_STREAMS && n < max; i++) {
        const program *p = &g->programs[i];
        if (p->fd < 0) continue;
        fds[n] = p->fd;
        wants_read[n] = !host_slow;
        wants_write[n++] = waiting(&p->out) > 0;
    }
    return n;
}

static program *by_stream(mwm_gl *g, uint32_t stream) {
    for (int i = 0; i < MWM_GL_STREAMS; i++)
        if (g->programs[i].fd >= 0 && g->programs[i].stream == stream) return &g->programs[i];
    return NULL;
}

/* What MonadHost sent: frames, each handed to the program it names as its bytes come. */
static void from_host(mwm_gl *g) {
    uint8_t piece[PIECE];
    while (g->host >= 0 && !a_program_is_slow(g)) {
        ssize_t got = recv(g->host, piece, sizeof piece, 0);
        if (got < 0 && errno == EINTR) continue;
        if (got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        if (got <= 0) {
            host_gone(g);
            return;
        }
        size_t at = 0, len = (size_t)got;
        while (at < len) {
            if (g->in_left == 0) {
                size_t take = sizeof g->head - g->head_len < len - at ? sizeof g->head - g->head_len : len - at;
                memcpy(g->head + g->head_len, piece + at, take);
                g->head_len += take;
                at += take;
                if (g->head_len < sizeof g->head) break;
                g->head_len = 0;
                memcpy(&g->in_stream, g->head, 4);
                memcpy(&g->in_left, g->head + 4, 4);
                if (g->in_left > MWM_GL_FRAME) { /* no frame is that long: there is no going on */
                    host_gone(g);
                    return;
                }
                g->word_len = 0;
                continue;
            }
            size_t take = g->in_left < len - at ? g->in_left : len - at;
            if (g->in_stream == 0) {
                /* MonadHost's own word: it ends a stream. Its program is hung up on, and not spoken of again. */
                size_t keep = sizeof g->word - g->word_len < take ? sizeof g->word - g->word_len : take;
                memcpy(g->word + g->word_len, piece + at, keep);
                g->word_len += keep;
                uint32_t kind, stream;
                memcpy(&kind, g->word, 4);
                memcpy(&stream, g->word + 4, 4);
                if (g->in_left == take && g->word_len == sizeof g->word && kind == MWM_GL_CLOSED) program_gone(g, by_stream(g, stream), false);
            } else {
                program *p = by_stream(g, g->in_stream); /* none: a program that ended meanwhile */
                if (p && (!put(&p->out, piece + at, take) || !flush(p->fd, &p->out))) program_gone(g, p, true);
            }
            at += take;
            g->in_left -= (uint32_t)take;
        }
    }
}

/* What a program wrote: to MonadHost, as frames of its stream. */
static void from_program(mwm_gl *g, program *p) {
    uint8_t piece[PIECE];
    while (p->fd >= 0 && g->host >= 0 && waiting(&g->host_out) <= WAITING) {
        ssize_t got = recv(p->fd, piece, sizeof piece, 0);
        if (got < 0 && errno == EINTR) continue;
        if (got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        if (got <= 0) {
            program_gone(g, p, true);
            return;
        }
        if (!put(&g->host_out, (uint32_t[]){p->stream, (uint32_t)got}, 8) || !put(&g->host_out, piece, (size_t)got)
            || !flush(g->host, &g->host_out)) {
            host_gone(g);
            return;
        }
    }
}

void mwm_gl_service(mwm_gl *g, int fd, bool readable, bool writable) {
    if (fd < 0) return;
    if (fd == g->host) {
        if (writable && !flush(g->host, &g->host_out)) {
            host_gone(g);
            return;
        }
        if (readable) from_host(g);
        return;
    }
    for (int i = 0; i < MWM_GL_STREAMS; i++) {
        program *p = &g->programs[i];
        if (p->fd != fd) continue;
        if (writable && !flush(p->fd, &p->out)) {
            program_gone(g, p, true);
            return;
        }
        if (readable) from_program(g, p);
        break;
    }
    /* What a program's going left to tell MonadHost. */
    if (g->host >= 0 && !flush(g->host, &g->host_out)) host_gone(g);
}
