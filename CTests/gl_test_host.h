/*
 * gl_test_host.h — the other end of the library's socket, for its tests
 * (test_gl_lib.c): a thread that plays the window manager and the Mac
 * behind it. It writes the eight bytes a stream begins with, takes the
 * commands apart strictly by mwm_gl_wire.h (a command that is not as the
 * header has it fails the test), keeps every one for the test to look
 * at, and answers the commands that have an answer, with what the test
 * told it to say, or with nonsense when that is the test.
 *
 * With it, the Wayland side the library is linked with here instead of
 * mgl_wayland.c: it notes what the library asked of it.
 */
#ifndef GL_TEST_HOST_H
#define GL_TEST_HOST_H

#include "mgl_internal.h"

#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static int checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
/* The same for the host's own thread and what it shares with the test's, without the count: that is one thread's to keep. */
#define MUST(x) do { if (!(x)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)

/* ---- What a command is made of ---- */

/* A command's arguments, by op: w a word, d data, D data or none (a NULL
 * pointer). An op without an entry is none of the protocol's. */
static const char *const grammar[MGL_OP_LAST + 1] = {
    [MGL_CONTEXT_CREATE] = "ww",
    [MGL_CONTEXT_DESTROY] = "w",
    [MGL_SURFACE_CREATE] = "wwwwww",
    [MGL_SURFACE_RESIZE] = "www",
    [MGL_SURFACE_DESTROY] = "w",
    [MGL_MAKE_CURRENT] = "www",
    [MGL_SWAP] = "w",
    [MGL_ACTIVE_TEXTURE] = "w",
    [MGL_ATTACH_SHADER] = "ww",
    [MGL_BIND_ATTRIB_LOCATION] = "wwd",
    [MGL_BIND_BUFFER] = "ww",
    [MGL_BIND_FRAMEBUFFER] = "ww",
    [MGL_BIND_RENDERBUFFER] = "ww",
    [MGL_BIND_TEXTURE] = "ww",
    [MGL_BLEND_COLOR] = "wwww",
    [MGL_BLEND_EQUATION] = "w",
    [MGL_BLEND_EQUATION_SEPARATE] = "ww",
    [MGL_BLEND_FUNC] = "ww",
    [MGL_BLEND_FUNC_SEPARATE] = "wwww",
    [MGL_BUFFER_DATA] = "wwwD",
    [MGL_BUFFER_SUB_DATA] = "wwd",
    [MGL_CHECK_FRAMEBUFFER_STATUS] = "w",
    [MGL_CLEAR] = "w",
    [MGL_CLEAR_COLOR] = "wwww",
    [MGL_CLEAR_DEPTHF] = "w",
    [MGL_CLEAR_STENCIL] = "w",
    [MGL_COLOR_MASK] = "wwww",
    [MGL_COMPILE_SHADER] = "w",
    [MGL_COPY_TEX_IMAGE_2D] = "wwwwwwww",
    [MGL_COPY_TEX_SUB_IMAGE_2D] = "wwwwwwww",
    [MGL_CREATE_PROGRAM] = "w",
    [MGL_CREATE_SHADER] = "ww",
    [MGL_CULL_FACE] = "w",
    [MGL_DELETE_BUFFERS] = "wd",
    [MGL_DELETE_FRAMEBUFFERS] = "wd",
    [MGL_DELETE_PROGRAM] = "w",
    [MGL_DELETE_RENDERBUFFERS] = "wd",
    [MGL_DELETE_SHADER] = "w",
    [MGL_DELETE_TEXTURES] = "wd",
    [MGL_DEPTH_FUNC] = "w",
    [MGL_DEPTH_MASK] = "w",
    [MGL_DEPTH_RANGEF] = "ww",
    [MGL_DETACH_SHADER] = "ww",
    [MGL_DISABLE] = "w",
    [MGL_DISABLE_VERTEX_ATTRIB_ARRAY] = "w",
    [MGL_DRAW_ARRAYS] = "www",
    [MGL_DRAW_ELEMENTS] = "wwww",
    [MGL_DRAW_ELEMENTS_CLIENT] = "wwwd",
    [MGL_CLIENT_ARRAY] = "wwwwwd",
    [MGL_ENABLE] = "w",
    [MGL_ENABLE_VERTEX_ATTRIB_ARRAY] = "w",
    [MGL_FINISH] = "",
    [MGL_FRAMEBUFFER_RENDERBUFFER] = "wwww",
    [MGL_FRAMEBUFFER_TEXTURE_2D] = "wwwww",
    [MGL_FRONT_FACE] = "w",
    [MGL_GENERATE_MIPMAP] = "w",
    [MGL_GET_ERROR] = "",
    [MGL_GET_UNIFORM] = "ww",
    [MGL_LINE_WIDTH] = "w",
    [MGL_LINK_PROGRAM] = "w",
    [MGL_POLYGON_OFFSET] = "ww",
    [MGL_READ_PIXELS] = "wwwwww",
    [MGL_RENDERBUFFER_STORAGE] = "wwww",
    [MGL_SAMPLE_COVERAGE] = "ww",
    [MGL_SCISSOR] = "wwww",
    [MGL_SHADER_SOURCE] = "wd",
    [MGL_STENCIL_FUNC] = "www",
    [MGL_STENCIL_FUNC_SEPARATE] = "wwww",
    [MGL_STENCIL_MASK] = "w",
    [MGL_STENCIL_MASK_SEPARATE] = "ww",
    [MGL_STENCIL_OP] = "www",
    [MGL_STENCIL_OP_SEPARATE] = "wwww",
    [MGL_TEX_IMAGE_2D] = "wwwwwwwwD",
    [MGL_TEX_PARAMETERF] = "www",
    [MGL_TEX_PARAMETERI] = "www",
    [MGL_TEX_SUB_IMAGE_2D] = "wwwwwwwwd",
    [MGL_UNIFORM_1F] = "ww",
    [MGL_UNIFORM_2F] = "www",
    [MGL_UNIFORM_3F] = "wwww",
    [MGL_UNIFORM_4F] = "wwwww",
    [MGL_UNIFORM_1I] = "ww",
    [MGL_UNIFORM_2I] = "www",
    [MGL_UNIFORM_3I] = "wwww",
    [MGL_UNIFORM_4I] = "wwwww",
    [MGL_UNIFORM_1FV] = "wwd",
    [MGL_UNIFORM_2FV] = "wwd",
    [MGL_UNIFORM_3FV] = "wwd",
    [MGL_UNIFORM_4FV] = "wwd",
    [MGL_UNIFORM_1IV] = "wwd",
    [MGL_UNIFORM_2IV] = "wwd",
    [MGL_UNIFORM_3IV] = "wwd",
    [MGL_UNIFORM_4IV] = "wwd",
    [MGL_UNIFORM_MATRIX_2FV] = "wwd",
    [MGL_UNIFORM_MATRIX_3FV] = "wwd",
    [MGL_UNIFORM_MATRIX_4FV] = "wwd",
    [MGL_USE_PROGRAM] = "w",
    [MGL_VERTEX_ATTRIB_4F] = "wwwww",
    [MGL_VERTEX_ATTRIB_POINTER] = "wwwwww",
    [MGL_VIEWPORT] = "wwww",
};

/* How many times each command came, over all the tests: at the end, every one the header has did. */
static int ops_seen[MGL_OP_LAST + 1];

/* ---- An answer being put together ---- */

typedef struct {
    uint8_t bytes[8192];
    size_t len;
} body;

static void body_u32(body *b, uint32_t v) {
    MUST(b->len + 4 <= sizeof b->bytes);
    memcpy(b->bytes + b->len, &v, 4);
    b->len += 4;
}

static void body_data(body *b, const void *bytes, size_t count) {
    size_t padded = (count + 3) & ~(size_t)3;
    body_u32(b, (uint32_t)count);
    MUST(b->len + padded <= sizeof b->bytes);
    memset(b->bytes + b->len, 0, padded);
    if (count > 0) memcpy(b->bytes + b->len, bytes, count);
    b->len += padded;
}

static void body_text(body *b, const char *text) { body_data(b, text, strlen(text)); }

/* ---- The host ---- */

/* How the answers go wrong, when they are to. */
enum {
    SANE,
    ODD_LENGTH,  /* a length that is no multiple of four */
    HUGE_LENGTH, /* a length larger than a reply may be */
    CUT_SHORT,   /* a length, half of the bytes, and the socket closed */
    HANG_UP,     /* the socket closed instead of an answer */
    RAW,         /* `raw`, whatever the command was */
};

typedef struct {
    uint32_t op;
    /* Where its arguments are in `bytes`, and how many bytes they are. */
    size_t at, size;
} host_command;

static struct {
    int fd, listener;
    pthread_t thread;
    pthread_mutex_t lock;
    bool over, gone;
    /* What came and is no whole command yet. */
    uint8_t *pending;
    size_t pending_len, pending_room;
    /* Every command's arguments, one after the other, and where each is. */
    uint8_t *bytes;
    size_t len, room;
    host_command *commands;
    size_t count, commands_room;
    /* How many of them the test has looked at. */
    size_t looked;
    /* The first thing that was not as the header has it. */
    const char *wrong;
    /* What the stream begins with. */
    uint32_t hello[2];
    /* The answers. */
    uint32_t error, status, compiled;
    const char *info;
    body link, uniform, raw;
    bool no_pixels;
    int nonsense;
    /* The Mac is slow: a Swap's answer is kept, and every answer after it (they come in the order of the commands),
     * until host_lets_go. How many Swap answers are kept now, and how many times they were let go. */
    bool holds_swaps;
    int swaps_held, let_go;
    uint8_t *held;
    size_t held_len, held_room;
} host = {.fd = -1, .listener = -1, .lock = PTHREAD_MUTEX_INITIALIZER};

/* Sets something of the host's while its thread may be looking. */
#define HOST(...) do { pthread_mutex_lock(&host.lock); __VA_ARGS__; pthread_mutex_unlock(&host.lock); } while (0)

static void host_send(const void *bytes, size_t count) {
    const uint8_t *at = bytes;
    while (count > 0) {
#ifdef MSG_NOSIGNAL
        /* The library may have hung up (a test's end) before an answer nobody reads was written: no signal for that. */
        ssize_t n = send(host.fd, at, count, MSG_NOSIGNAL);
#else
        ssize_t n = write(host.fd, at, count);
#endif
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return; /* the library hung up first: a test's end */
        at += n;
        count -= (size_t)n;
    }
}

/* An answer's bytes: written, or kept behind a Swap's answer that is held back. */
static void host_write(const void *bytes, size_t count) {
    if (host.swaps_held == 0) return host_send(bytes, count);
    if (host.held_room - host.held_len < count) {
        host.held_room = (host.held_room + count) * 2;
        host.held = realloc(host.held, host.held_room);
        MUST(host.held);
    }
    memcpy(host.held + host.held_len, bytes, count);
    host.held_len += count;
}

/* The Mac has drawn the picture: the answers held back go, in their order. `let_go` counts before they go, so that
 * whoever has read one of them finds it counted. */
static void host_lets_go(void) {
    pthread_mutex_lock(&host.lock);
    host.let_go++;
    host.swaps_held = 0;
    host_send(host.held, host.held_len);
    host.held_len = 0;
    pthread_mutex_unlock(&host.lock);
}

/* Nothing more is read or written; the library reads the end of the stream. */
static void host_hang_up(void) {
    shutdown(host.fd, SHUT_RDWR);
    host.over = true;
}

/* The byte at place i of what glReadPixels is answered. */
static uint8_t pixel_byte(size_t i) { return (uint8_t)(i * 7 + 3); }

static void host_answer(uint32_t op, const uint32_t *args) {
    static body b;
    b.len = 0;
    switch (host.nonsense) {
    case ODD_LENGTH: host_write(&(uint32_t){3}, 4), host_write("abc", 3); return;
    case HUGE_LENGTH: host_write(&(uint32_t){MWM_GL_REPLY + 4}, 4); return;
    case CUT_SHORT: host_write(&(uint32_t){8}, 4), host_write("half", 4), host_hang_up(); return;
    case HANG_UP: host_hang_up(); return;
    case RAW: host_write(&(uint32_t){(uint32_t)host.raw.len}, 4), host_write(host.raw.bytes, host.raw.len); return;
    default: break;
    }
    switch (op) {
    case MGL_GET_ERROR:
        body_u32(&b, host.error);
        host.error = 0;
        break;
    /* Nothing, once the picture is drawn: at once, or when the test says it is. */
    case MGL_SWAP:
        if (host.holds_swaps) host.swaps_held++;
        break;
    case MGL_FINISH: break;
    case MGL_CHECK_FRAMEBUFFER_STATUS: body_u32(&b, host.status); break;
    case MGL_COMPILE_SHADER:
        body_u32(&b, host.compiled);
        body_text(&b, host.info ? host.info : "");
        break;
    case MGL_LINK_PROGRAM: b = host.link; break;
    case MGL_GET_UNIFORM: b = host.uniform; break;
    case MGL_READ_PIXELS: {
        /* A read the Mac has an error for is answered with nothing at all, as the header has it. */
        if (host.no_pixels) break;
        /* Pixels can be more than a body holds: written as they are made. */
        size_t count = (size_t)args[2] * args[3] * 4;
        uint8_t *pixels = malloc(count + 8);
        MUST(pixels);
        memcpy(pixels, &(uint32_t){(uint32_t)(count + 4)}, 4);
        memcpy(pixels + 4, &(uint32_t){(uint32_t)count}, 4);
        for (size_t i = 0; i < count; i++) pixels[8 + i] = pixel_byte(i);
        host_write(pixels, count + 8);
        free(pixels);
        return;
    }
    default: return;
    }
    host_write(&(uint32_t){(uint32_t)b.len}, 4);
    host_write(b.bytes, b.len);
}

static void host_wrong(const char *what) {
    if (!host.wrong) host.wrong = what;
}

/* One whole command (`size` bytes at `at`): held against the header, kept, answered. */
static void host_command_came(const uint8_t *at, uint32_t op, uint32_t size) {
    if (op > MGL_OP_LAST || !grammar[op]) return host_wrong("an op the header has not");
    uint32_t args[16] = {0};
    size_t place = 8, words = 0, data = 0;
    bool none = false;
    for (const char *g = grammar[op]; *g; g++) {
        if (size - place < 4) return host_wrong("a command shorter than its arguments");
        uint32_t v;
        memcpy(&v, at + place, 4);
        place += 4;
        if (*g == 'w') {
            args[words++] = v;
            continue;
        }
        if (v == MWM_GL_NONE) {
            if (*g != 'D') return host_wrong("none where OpenGL allows no NULL");
            none = true;
            continue;
        }
        size_t padded = ((size_t)v + 3) & ~(size_t)3;
        if (size - place < padded) return host_wrong("data longer than its command");
        for (size_t i = v; i < padded; i++)
            if (at[place + i] != 0) return host_wrong("padding that is not zeros");
        data = v;
        place += padded;
    }
    if (place != size) return host_wrong("a command longer than its arguments");

    /* What the header says of single commands. */
    bool good = true;
    switch (op) {
    case MGL_CONTEXT_CREATE: good = args[0] >= 1; break;
    /* Whether it has an alpha, a depth and a stencil buffer: yes or no each. */
    case MGL_SURFACE_CREATE: good = args[0] >= 1 && args[3] <= 1 && args[4] <= 1 && args[5] <= 1; break;
    case MGL_CONTEXT_DESTROY:
    case MGL_SURFACE_RESIZE:
    case MGL_SURFACE_DESTROY:
    case MGL_SWAP: good = args[0] >= 1; break;
    case MGL_MAKE_CURRENT: good = (args[0] == 0) == (args[1] == 0) && (args[1] == 0) == (args[2] == 0); break;
    case MGL_BUFFER_DATA: good = none || data == args[1]; break;
    case MGL_DELETE_BUFFERS:
    case MGL_DELETE_TEXTURES:
    case MGL_DELETE_FRAMEBUFFERS:
    case MGL_DELETE_RENDERBUFFERS: good = data == (size_t)args[0] * 4; break;
    case MGL_UNIFORM_1FV:
    case MGL_UNIFORM_1IV: good = data == (size_t)args[1] * 4; break;
    case MGL_UNIFORM_2FV:
    case MGL_UNIFORM_2IV: good = data == (size_t)args[1] * 8; break;
    case MGL_UNIFORM_3FV:
    case MGL_UNIFORM_3IV: good = data == (size_t)args[1] * 12; break;
    case MGL_UNIFORM_4FV:
    case MGL_UNIFORM_4IV:
    case MGL_UNIFORM_MATRIX_2FV: good = data == (size_t)args[1] * 16; break;
    case MGL_UNIFORM_MATRIX_3FV: good = data == (size_t)args[1] * 36; break;
    case MGL_UNIFORM_MATRIX_4FV: good = data == (size_t)args[1] * 64; break;
    case MGL_COLOR_MASK: good = args[0] <= 1 && args[1] <= 1 && args[2] <= 1 && args[3] <= 1; break;
    case MGL_DEPTH_MASK: good = args[0] <= 1; break;
    case MGL_SAMPLE_COVERAGE: good = args[1] <= 1; break;
    case MGL_VERTEX_ATTRIB_POINTER: good = args[3] <= 1; break;
    case MGL_CLIENT_ARRAY: good = args[3] <= 1 && args[1] >= 1 && args[1] <= 4 && data % args[1] == 0; break;
    case MGL_DRAW_ELEMENTS_CLIENT:
        good = data == (size_t)args[1] * (args[2] == GL_UNSIGNED_BYTE ? 1 : args[2] == GL_UNSIGNED_SHORT ? 2 : 4);
        break;
    default: break;
    }
    if (!good) return host_wrong("arguments that do not agree with each other");
    /* The library reads a Swap's answer before it sends the next: it is one picture ahead of the Mac at most. */
    if (op == MGL_SWAP && host.swaps_held > 0) return host_wrong("a Swap before the one before it was answered");

    ops_seen[op]++;
    if (host.count == host.commands_room) {
        host.commands_room = host.commands_room ? host.commands_room * 2 : 64;
        host.commands = realloc(host.commands, host.commands_room * sizeof *host.commands);
        MUST(host.commands);
    }
    if (host.room - host.len < size) {
        host.room = (host.room + size) * 2;
        host.bytes = realloc(host.bytes, host.room);
        MUST(host.bytes);
    }
    memcpy(host.bytes + host.len, at + 8, size - 8);
    host.commands[host.count++] = (host_command){op, host.len, size - 8};
    host.len += size - 8;
    host_answer(op, args);
}

/* More bytes from the library: every whole command in them. */
static void host_bytes_came(const uint8_t *bytes, size_t count) {
    if (host.pending_room - host.pending_len < count) {
        host.pending_room = (host.pending_room + count) * 2;
        host.pending = realloc(host.pending, host.pending_room);
        MUST(host.pending);
    }
    memcpy(host.pending + host.pending_len, bytes, count);
    host.pending_len += count;
    size_t at = 0;
    while (host.pending_len - at >= 8 && !host.wrong) {
        uint32_t head[2];
        memcpy(head, host.pending + at, 8);
        if (head[1] < 8 || head[1] % 4 != 0 || head[1] > MWM_GL_COMMAND) {
            host_wrong("a size no command has");
            break;
        }
        if (host.pending_len - at < head[1]) break;
        host_command_came(host.pending + at, head[0], head[1]);
        at += head[1];
    }
    memmove(host.pending, host.pending + at, host.pending_len - at);
    host.pending_len -= at;
}

static void *host_run(void *unused) {
    (void)unused;
    static uint8_t chunk[1 << 16];
    if (host.listener >= 0) {
        /* The library dials, as it does a window manager. */
        host.fd = accept(host.listener, NULL, NULL);
        MUST(host.fd >= 0);
    }
#ifdef SO_NOSIGPIPE
    (void)setsockopt(host.fd, SOL_SOCKET, SO_NOSIGPIPE, &(int){1}, sizeof(int));
#endif
    host_write(host.hello, sizeof host.hello);
    for (;;) {
        struct pollfd p = {.fd = host.fd, .events = POLLIN};
        if (poll(&p, 1, -1) < 0) continue;
        /* Read under the lock: when the test finds nothing left to read, all that came is in `commands`. */
        pthread_mutex_lock(&host.lock);
        ssize_t n = host.over ? 0 : recv(host.fd, chunk, sizeof chunk, MSG_DONTWAIT);
        if (n > 0) host_bytes_came(chunk, (size_t)n);
        bool over = n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR);
        if (over) host.over = true;
        pthread_mutex_unlock(&host.lock);
        if (over) return NULL;
    }
}

/* A host as it is before a stream: nothing came, and the answers are the plain ones. */
static void host_reset(uint32_t magic, uint32_t stream) {
    host.fd = host.listener = -1;
    host.over = host.gone = false;
    host.pending_len = host.len = host.count = host.looked = 0;
    host.wrong = NULL;
    host.hello[0] = magic;
    host.hello[1] = stream;
    host.error = host.status = 0;
    host.compiled = 1;
    host.info = NULL;
    host.link.len = host.uniform.len = host.raw.len = 0;
    host.no_pixels = false;
    host.nonsense = SANE;
    host.holds_swaps = false;
    host.swaps_held = host.let_go = 0;
    host.held_len = 0;
}

/* A host that begins the stream with these eight bytes, and MONAD_GL_FD naming the library's end. */
static void host_start_saying(uint32_t magic, uint32_t stream) {
    int ends[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, ends) == 0);
    host_reset(magic, stream);
    host.fd = ends[0];
    char number[16];
    snprintf(number, sizeof number, "%d", ends[1]);
    setenv("MONAD_GL_FD", number, 1);
    CHECK(pthread_create(&host.thread, NULL, host_run, NULL) == 0);
}

/* A host that listens where a window manager does, for the library to dial. */
static void host_start_listening(const char *path, uint32_t stream) {
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    CHECK(strlen(path) < sizeof addr.sun_path);
    strcpy(addr.sun_path, path);
    host_reset(MWM_GL_MAGIC, stream);
    host.listener = socket(AF_UNIX, SOCK_STREAM, 0);
    CHECK(host.listener >= 0 && bind(host.listener, (struct sockaddr *)&addr, sizeof addr) == 0 && listen(host.listener, 1) == 0);
    unsetenv("MONAD_GL_FD");
    CHECK(pthread_create(&host.thread, NULL, host_run, NULL) == 0);
}

static void host_start(uint32_t stream) { host_start_saying(MWM_GL_MAGIC, stream); }

/* The window manager is gone, all of it: its thread has ended and its end of the socket is closed, so that what the
 * library writes next has nowhere to go. */
static void host_goes_away(void) {
    pthread_mutex_lock(&host.lock);
    host_hang_up();
    pthread_mutex_unlock(&host.lock);
    CHECK(pthread_join(host.thread, NULL) == 0);
    close(host.fd);
    host.gone = true;
}

/* The library closed its end (eglTerminate, or it never took the stream): the host's thread ends. */
static void host_stop(void) {
    if (!host.gone) {
        CHECK(pthread_join(host.thread, NULL) == 0);
        close(host.fd);
    }
    if (host.listener >= 0) close(host.listener);
    host.fd = host.listener = -1;
    if (host.wrong) fprintf(stderr, "the host was sent %s\n", host.wrong);
    CHECK(!host.wrong);
    CHECK(host.pending_len == 0); /* nothing but whole commands */
}

/* Waits until the host has taken apart everything the library has sent so far. */
static void host_settle(void) {
    for (int tries = 0;; tries++) {
        if (tries == 100000) host_wrong("nothing whole for ten seconds");
        if (host.wrong) break;
        pthread_mutex_lock(&host.lock);
        int unread = 0;
        bool settled = host.over || (ioctl(host.fd, FIONREAD, &unread) == 0 && unread == 0 && host.pending_len == 0);
        pthread_mutex_unlock(&host.lock);
        if (settled) break;
        usleep(100);
    }
    if (host.wrong) fprintf(stderr, "the host was sent %s\n", host.wrong);
    CHECK(!host.wrong);
}

/* The line of the test that looks at a command, for the message when it is another than the test says. */
static int looked_from;
#define CHECK_COMMAND(x) \
    do { \
        checks++; \
        if (!(x)) { \
            fprintf(stderr, "test_gl_lib.c:%d: the command there: %s\n", looked_from, #x); \
            exit(1); \
        } \
    } while (0)

/* The next command the test has not looked at: it is `op`, and these are its arguments. */
static const uint8_t *next_command(uint32_t op, size_t *size) {
    if (host.looked >= host.count) fprintf(stderr, "no command came where %u was to\n", op);
    CHECK_COMMAND(host.looked < host.count);
    const host_command *c = &host.commands[host.looked++];
    if (c->op != op) fprintf(stderr, "command %u came where %u was to\n", c->op, op);
    CHECK_COMMAND(c->op == op);
    *size = c->size;
    return host.bytes + c->at;
}

static const uint8_t *next_words(uint32_t op, size_t extra, int count, va_list list) {
    size_t size;
    const uint8_t *args = next_command(op, &size);
    CHECK_COMMAND(size == (size_t)count * 4 + extra);
    for (int i = 0; i < count; i++) {
        uint32_t want = va_arg(list, uint32_t), got;
        memcpy(&got, args + i * 4, 4);
        if (got != want) fprintf(stderr, "command %u, word %d: 0x%x where 0x%x was to be\n", op, i, got, want);
        CHECK_COMMAND(got == want);
    }
    return args + count * 4;
}

/* The next command is `op` with exactly these words and nothing else. */
static void expect_words(uint32_t op, int count, ...) {
    va_list list;
    va_start(list, count);
    (void)next_words(op, 0, count, list);
    va_end(list);
}
#define expect(...) (looked_from = __LINE__, expect_words(__VA_ARGS__))

/* The next command is `op` with these words, then one data argument of exactly these bytes. */
static void expect_words_and_data(uint32_t op, const void *bytes, size_t len, int count, ...) {
    va_list list;
    va_start(list, count);
    const uint8_t *data = next_words(op, 4 + ((len + 3) & ~(size_t)3), count, list);
    va_end(list);
    uint32_t said;
    memcpy(&said, data, 4);
    CHECK_COMMAND(said == len);
    CHECK_COMMAND(len == 0 || memcmp(data + 4, bytes, len) == 0);
}
#define expect_data(...) (looked_from = __LINE__, expect_words_and_data(__VA_ARGS__))

/* A float as the word it travels as. */
static uint32_t f32(float f) {
    uint32_t u;
    memcpy(&u, &f, 4);
    return u;
}

/* ---- Wayland, as the library sees it here ---- */

struct mgl_wl {
    void *display;
};

struct mgl_wl_surface {
    void *surface;
};

enum { PRESENTS = 64 };
static struct {
    /* mgl_wl_bind finds no monad_gl. */
    bool refuses;
    int binds, unbinds, surfaces, gone;
    void *display;
    struct {
        void *surface;
        uint32_t stream, id;
        int width, height, interval;
    } presents[PRESENTS];
    int present_count;
} wayland;

mgl_wl *mgl_wl_bind(void *display) {
    if (wayland.refuses) return NULL;
    mgl_wl *wl = calloc(1, sizeof *wl);
    CHECK(wl);
    wl->display = wayland.display = display;
    wayland.binds++;
    return wl;
}

void mgl_wl_unbind(mgl_wl *wl) {
    wayland.unbinds++;
    free(wl);
}

mgl_wl_surface *mgl_wl_surface_new(mgl_wl *wl, void *surface) {
    CHECK(wl && surface);
    mgl_wl_surface *s = calloc(1, sizeof *s);
    CHECK(s);
    s->surface = surface;
    wayland.surfaces++;
    return s;
}

bool mgl_wl_present(mgl_wl_surface *s, uint32_t stream, uint32_t surface, int width, int height, int interval) {
    CHECK(wayland.present_count < PRESENTS);
    wayland.presents[wayland.present_count].surface = s->surface;
    wayland.presents[wayland.present_count].stream = stream;
    wayland.presents[wayland.present_count].id = surface;
    wayland.presents[wayland.present_count].width = width;
    wayland.presents[wayland.present_count].height = height;
    wayland.presents[wayland.present_count].interval = interval;
    wayland.present_count++;
    return true;
}

void mgl_wl_surface_gone(mgl_wl_surface *s) {
    wayland.gone++;
    free(s);
}

#endif
