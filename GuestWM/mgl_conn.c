/*
 * mgl_conn.c — the library's one connection to the window manager
 * (mwm_gl_wire.h): the socket, the buffer commands are written to until
 * there is reason to send them, and the answers of the few commands that
 * have one, a Swap's among them, which is read late. When the other end
 * goes away, or answers what the protocol does not have, the stream is
 * lost: nothing more is written or read, and the program's calls do
 * nothing from then on.
 */
#include "mgl_internal.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

/* A buffer that grew for a texture is not kept at that size. */
enum { KEEP = 1 << 20 };

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    int fd;
    bool open, lost;
    uint32_t stream;
    uint8_t *buf;
    size_t len, room;
    /* The command being written: where it begins, and whether it still can be. */
    size_t begun;
    bool spoiled;
    /* The last MakeCurrent: context, draw, read. */
    uint32_t current[3];
    /* The last Swap's answer has not been read. It is never read for its
     * own sake: a stream that is closed or lost takes it along. */
    bool swap_unread;
} conn = {.fd = -1};

void mgl_lock(void) { pthread_mutex_lock(&lock); }
void mgl_unlock(void) { pthread_mutex_unlock(&lock); }

static bool write_all(const uint8_t *bytes, size_t count) {
    while (count > 0) {
#ifdef MSG_NOSIGNAL
        /* A window manager that is gone is an error to return, not a signal that ends the program. */
        ssize_t n = send(conn.fd, bytes, count, MSG_NOSIGNAL);
#else
        ssize_t n = write(conn.fd, bytes, count);
#endif
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        bytes += n;
        count -= (size_t)n;
    }
    return true;
}

static bool read_all(uint8_t *bytes, size_t count) {
    while (count > 0) {
        ssize_t n = read(conn.fd, bytes, count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        bytes += n;
        count -= (size_t)n;
    }
    return true;
}

/* The socket: the one a test hands over, or the window manager's. */
static int dial(void) {
    const char *given = getenv("MONAD_GL_FD");
    if (given && *given) {
        char *end;
        long fd = strtol(given, &end, 10);
        return *end == 0 && fd >= 0 && fd < 1 << 20 ? (int)fd : -1;
    }
    const char *dir = getenv("XDG_RUNTIME_DIR");
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    if (!dir || !*dir || strlen(dir) + sizeof "/" MWM_GL_SOCKET > sizeof addr.sun_path) return -1;
    strcpy(addr.sun_path, dir);
    strcat(addr.sun_path, "/" MWM_GL_SOCKET);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    (void)fcntl(fd, F_SETFD, FD_CLOEXEC);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

bool mgl_conn_open(void) {
    if (conn.open) return true;
    conn.fd = dial();
    if (conn.fd < 0) return false;
#ifdef SO_NOSIGPIPE
    (void)setsockopt(conn.fd, SOL_SOCKET, SO_NOSIGPIPE, &(int){1}, sizeof(int));
#endif
    uint32_t hello[2];
    if (!read_all((uint8_t *)hello, sizeof hello) || hello[0] != MWM_GL_MAGIC || hello[1] == 0) {
        close(conn.fd);
        conn.fd = -1;
        return false;
    }
    conn.open = true;
    conn.lost = false;
    conn.stream = hello[1];
    conn.len = 0;
    conn.swap_unread = false;
    memset(conn.current, 0, sizeof conn.current);
    return true;
}

void mgl_conn_close(void) {
    if (!conn.open) return;
    (void)mgl_flush();
    close(conn.fd);
    free(conn.buf);
    conn.buf = NULL;
    conn.len = conn.room = 0;
    conn.fd = -1;
    conn.open = conn.lost = false;
    conn.stream = 0;
}

uint32_t mgl_conn_stream(void) { return conn.stream; }
bool mgl_conn_lost(void) { return conn.lost || !conn.open; }
uint32_t mgl_conn_context(void) { return conn.current[0]; }

void mgl_conn_fail(void) {
    conn.lost = true;
    conn.len = 0;
    conn.swap_unread = false;
}

/* Room for `count` more bytes of the command being written; NULL (and the
 * command spoiled) when it would be larger than a command may be. */
static uint8_t *room(size_t count) {
    if (conn.spoiled) return NULL;
    if (count > MWM_GL_COMMAND || conn.len - conn.begun + count > MWM_GL_COMMAND) {
        conn.spoiled = true;
        return NULL;
    }
    if (conn.room - conn.len < count) {
        size_t want = conn.room ? conn.room : 2 * MGL_FLUSH;
        while (want - conn.len < count) want *= 2;
        uint8_t *grown = realloc(conn.buf, want);
        if (!grown) {
            conn.spoiled = true;
            return NULL;
        }
        conn.buf = grown;
        conn.room = want;
    }
    uint8_t *at = conn.buf + conn.len;
    conn.len += count;
    return at;
}

void mgl_begin(uint32_t op) {
    conn.begun = conn.len;
    conn.spoiled = mgl_conn_lost();
    mgl_u32(op);
    mgl_u32(0); /* its size, when it is known */
}

void mgl_u32(uint32_t v) {
    uint8_t *at = room(4);
    if (at) memcpy(at, &v, 4);
}

uint8_t *mgl_data_room(size_t count) {
    if (count > MWM_GL_COMMAND) {
        conn.spoiled = true;
        return NULL;
    }
    size_t padded = (count + 3) & ~(size_t)3;
    uint8_t *at = room(4 + padded);
    if (!at) return NULL;
    uint32_t n = (uint32_t)count;
    memcpy(at, &n, 4);
    memset(at + 4 + count, 0, padded - count);
    return at + 4;
}

void mgl_data(const void *bytes, size_t count) {
    uint8_t *at = mgl_data_room(count);
    if (at && count > 0) memcpy(at, bytes, count);
}

void mgl_none(void) { mgl_u32(MWM_GL_NONE); }

bool mgl_end(void) {
    if (conn.spoiled) {
        conn.len = conn.begun;
        /* A lost stream takes no command, and that is no error of the command's. */
        return mgl_conn_lost();
    }
    uint32_t size = (uint32_t)(conn.len - conn.begun);
    memcpy(conn.buf + conn.begun + 4, &size, 4);
    if (conn.len > MGL_FLUSH) (void)mgl_flush();
    return true;
}

void mgl_make_current(uint32_t context, uint32_t draw, uint32_t rd) {
    if (conn.current[0] == context && conn.current[1] == draw && conn.current[2] == rd) return;
    mgl_begin(MGL_MAKE_CURRENT);
    mgl_u32(context);
    mgl_u32(draw);
    mgl_u32(rd);
    if (mgl_end()) {
        conn.current[0] = context;
        conn.current[1] = draw;
        conn.current[2] = rd;
    }
}

bool mgl_flush(void) {
    if (mgl_conn_lost()) return false;
    if (conn.len > 0 && !write_all(conn.buf, conn.len)) {
        mgl_conn_fail();
        return false;
    }
    conn.len = 0;
    if (conn.room > KEEP) {
        free(conn.buf);
        conn.buf = NULL;
        conn.room = 0;
    }
    return true;
}

/* The answer to the stream's last Swap, when it has not been read yet:
 * nothing, and there once the Mac has drawn that picture, which this
 * waits for. Answers come in the order of the commands, so it is in front
 * of every answer after it. False when the stream is lost. */
static bool swap_answered(void) {
    if (mgl_conn_lost()) return false;
    if (!conn.swap_unread) return true;
    uint32_t len;
    if (!read_all((uint8_t *)&len, 4) || len != 0) {
        mgl_conn_fail();
        return false;
    }
    conn.swap_unread = false;
    return true;
}

bool mgl_swap(uint32_t surface) {
    if (!swap_answered()) return false;
    mgl_begin(MGL_SWAP);
    mgl_u32(surface);
    /* A Swap there was no memory to write has no answer to wait for. */
    bool written = mgl_end();
    if (!mgl_flush()) return false;
    conn.swap_unread = written;
    return true;
}

bool mgl_reply_read(mgl_reply *r) {
    *r = (mgl_reply){.bad = true};
    if (!mgl_flush() || !swap_answered()) return false;
    uint32_t len;
    if (!read_all((uint8_t *)&len, 4) || len % 4 != 0 || len > MWM_GL_REPLY) {
        mgl_conn_fail();
        return false;
    }
    if (len > 0) {
        r->bytes = malloc(len);
        if (!r->bytes || !read_all(r->bytes, len)) {
            /* Without its answer read, the stream's next bytes are no answer to anything. */
            free(r->bytes);
            r->bytes = NULL;
            mgl_conn_fail();
            return false;
        }
    }
    r->len = len;
    r->bad = false;
    return true;
}

uint32_t mgl_reply_u32(mgl_reply *r) {
    uint32_t v = 0;
    if (r->bad || r->len - r->at < 4) {
        r->bad = true;
        return 0;
    }
    memcpy(&v, r->bytes + r->at, 4);
    r->at += 4;
    return v;
}

const uint8_t *mgl_reply_data(mgl_reply *r, size_t *count) {
    *count = 0;
    uint32_t n = mgl_reply_u32(r);
    if (r->bad || n == MWM_GL_NONE) return NULL;
    size_t padded = ((size_t)n + 3) & ~(size_t)3;
    if (r->len - r->at < padded) {
        r->bad = true;
        return NULL;
    }
    const uint8_t *bytes = r->bytes + r->at;
    r->at += padded;
    *count = n;
    return bytes;
}

bool mgl_reply_end(mgl_reply *r) {
    bool whole = !r->bad && r->at == r->len;
    free(r->bytes);
    r->bytes = NULL;
    if (!whole) mgl_conn_fail();
    return whole;
}
