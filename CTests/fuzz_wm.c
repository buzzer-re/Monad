/*
 * fuzz_wm.c — fuzz target for Monad's window manager (GuestWM/mwm_server).
 *
 * The input is a script for up to three programs connected to one server
 * with a small display: raw bytes on a socket, requests built from the
 * input (any object, any opcode, numbers small, large and negative,
 * strings, descriptors of a file that may be shorter than said), the whole
 * exchange that opens a window with sizes from the input, frames, and
 * programs leaving. After every step: every window is inside the display
 * and has a size, no two windows share a pixel, there are no more windows
 * or programs than there may be, and a pixel outside every window is
 * black. The sanitizers check the rest.
 *
 * Built with -fsanitize=fuzzer (clang), LLVMFuzzerTestOneInput is the
 * target. Otherwise main() is a deterministic driver: `fuzz_wm [iterations]
 * [seed]`, default a short run.
 */
#include "mwm_server.h"
#include "mwm_wire.h"

#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

enum { W = 256, H = 128, PROGRAMS = 3, FILE_BYTES = 64 << 10 };

static void fail(const char *what) {
    fprintf(stderr, "fuzz_wm: invariant broken: %s\n", what);
    abort();
}

static uint32_t pixels[W * H];
static int shared_file = -1;
static long windows_seen;

typedef struct {
    const uint8_t *data;
    size_t len, pos;
} input;

static uint8_t byte(input *in) { return in->pos < in->len ? in->data[in->pos++] : 0; }

static uint32_t number(input *in) {
    switch (byte(in) % 8) {
    case 0: return 0;
    case 1: return byte(in) % 32;
    case 2: return byte(in);
    case 3: return (uint32_t)-(int32_t)(byte(in) % 16);
    case 4: return 0x7fffffff - byte(in) % 4;
    case 5: return 0xffffffff - byte(in) % 4;
    case 6: return (uint32_t)byte(in) << 8 | byte(in);
    default: return (uint32_t)byte(in) << 24 | (uint32_t)byte(in) << 16 | (uint32_t)byte(in) << 8 | byte(in);
    }
}

typedef struct {
    mwm_conn *conn; /* the program's end; NULL once it left */
    int server_fd;
    uint32_t next;
} program;

static void check(const mwm_server *s) {
    mwm_window list[MWM_MAX_WINDOWS + 1];
    int n = mwm_server_windows(s, list, MWM_MAX_WINDOWS + 1);
    if (n > MWM_MAX_WINDOWS) fail("more windows than there may be");
    static uint8_t covered[W * H];
    memset(covered, 0, sizeof covered);
    for (int i = 0; i < n; i++) {
        const mwm_window *w = &list[i];
        if (w->width <= 0 || w->height <= 0) fail("a window without a size");
        if (w->x < 0 || w->y < 0 || w->x + w->width > W || w->y + w->height > H) fail("a window outside the display");
        if (!w->title || !w->app_id || strlen(w->title) >= 128 || strlen(w->app_id) >= 128) fail("a title longer than it may be");
        for (int y = w->y; y < w->y + w->height; y++)
            for (int x = w->x; x < w->x + w->width; x++) {
                if (covered[y * W + x]) fail("two windows on one pixel");
                covered[y * W + x] = 1;
            }
    }
    for (int i = 0; i < W * H; i++)
        if (!covered[i] && pixels[i] != 0) fail("something drawn where no window is");
    int fds[MWM_MAX_CLIENTS + 1];
    bool wants[MWM_MAX_CLIENTS + 1];
    if (mwm_server_sockets(s, fds, wants, MWM_MAX_CLIENTS + 1) > PROGRAMS) fail("more programs than connected");
    windows_seen += n;
}

/* What the server sent is read and dropped: a program that reads. */
static void drain(program *p) {
    if (!p->conn) return;
    mwm_msg m;
    while (mwm_conn_read(p->conn) > 0)
        while (mwm_conn_next(p->conn, &m)) {}
}

static void request(program *p, input *in, uint32_t object, uint16_t opcode) {
    mwm_put_begin(p->conn, object, opcode);
    int args = byte(in) % 8;
    for (int i = 0; i < args; i++) {
        switch (byte(in) % 6) {
        case 0: {
            char text[40];
            int n = byte(in) % (int)sizeof text;
            for (int k = 0; k < n; k++) text[k] = (char)(byte(in) | 1);
            text[n < (int)sizeof text ? n : (int)sizeof text - 1] = 0;
            mwm_put_string(p->conn, byte(in) % 8 ? text : NULL);
            break;
        }
        case 1: mwm_put_fd(p->conn, shared_file); break;
        case 2: mwm_put_uint(p->conn, 1 + byte(in) % 24); break; /* an id that may exist */
        default: mwm_put_uint(p->conn, number(in)); break;
        }
    }
    mwm_put_end(p->conn);
}

static void words(program *p, uint32_t object, uint16_t opcode, int count, const uint32_t *args) {
    mwm_put_begin(p->conn, object, opcode);
    for (int i = 0; i < count; i++) mwm_put_uint(p->conn, args[i]);
    mwm_put_end(p->conn);
}

/* The exchange that opens a window, its sizes from the input. */
static void open_window(program *p, input *in) {
    uint32_t registry = p->next++, compositor = p->next++, shm = p->next++, wm = p->next++, surface = p->next++, xdg = p->next++,
             toplevel = p->next++, pool = p->next++, buffer = p->next++;
    words(p, 1, 1, 1, &registry);
    static const char *names[] = {"wl_compositor", "wl_shm", "xdg_wm_base"};
    uint32_t ids[] = {compositor, shm, wm};
    for (uint32_t i = 0; i < 3; i++) {
        mwm_put_begin(p->conn, registry, 0);
        mwm_put_uint(p->conn, i + 1);
        mwm_put_string(p->conn, names[i]);
        mwm_put_uint(p->conn, 1);
        mwm_put_uint(p->conn, ids[i]);
        mwm_put_end(p->conn);
    }
    words(p, compositor, 0, 1, &surface);
    words(p, wm, 2, 2, (uint32_t[]){xdg, surface});
    words(p, xdg, 1, 1, &toplevel);
    mwm_put_begin(p->conn, toplevel, 2);
    mwm_put_string(p->conn, "fuzz");
    mwm_put_end(p->conn);
    words(p, surface, 6, 0, NULL);
    uint32_t width = 1 + number(in) % 400, height = 1 + number(in) % 200, stride = width * 4 + (byte(in) % 4) * 4;
    mwm_put_begin(p->conn, shm, 0);
    mwm_put_uint(p->conn, pool);
    mwm_put_fd(p->conn, shared_file);
    mwm_put_uint(p->conn, byte(in) % 16 ? FILE_BYTES : number(in));
    mwm_put_end(p->conn);
    words(p, pool, 0, 6, (uint32_t[]){buffer, byte(in) % 8 ? 0 : number(in), width, height, stride, byte(in) % 2});
    words(p, surface, 1, 3, (uint32_t[]){buffer, 0, 0});
    words(p, surface, 6, 0, NULL);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (shared_file < 0) {
        signal(SIGPIPE, SIG_IGN); /* bytes written to a program the server dropped */
        char path[] = "/tmp/monad-fuzz-wm-XXXXXX";
        shared_file = mkstemp(path);
        if (shared_file < 0) fail("no file for the programs' pixels");
        unlink(path);
        static uint8_t fill[FILE_BYTES];
        memset(fill, 0x5a, sizeof fill);
        if (write(shared_file, fill, sizeof fill) != (ssize_t)sizeof fill) fail("the pixel file could not be written");
    }
    memset(pixels, 0, sizeof pixels);
    mwm_screen screen = {.pixels = pixels, .width = W, .height = H, .stride = W};
    mwm_server *s = mwm_server_new(&screen);
    if (!s) fail("no server");
    program programs[PROGRAMS];
    memset(programs, 0, sizeof programs);
    input in = {.data = data, .len = size};
    uint32_t time = 0;
    while (in.pos < in.len) {
        program *p = &programs[byte(&in) % PROGRAMS];
        if (!p->conn) {
            int sv[2];
            if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) fail("no socket pair");
            p->conn = mwm_conn_new(sv[0]);
            p->server_fd = sv[1];
            p->next = 2;
            if (!p->conn || !mwm_server_add_client(s, sv[1])) fail("a program could not connect");
        }
        switch (byte(&in) % 8) {
        case 0: { /* bytes as they are */
            uint8_t raw[64];
            size_t n = byte(&in) % sizeof raw;
            for (size_t i = 0; i < n; i++) raw[i] = byte(&in);
            (void)mwm_conn_flush(p->conn);
            if (n && write(mwm_conn_fd(p->conn), raw, n) < 0) { /* the server left first */ }
            break;
        }
        case 1: case 2: case 3:
            request(p, &in, 1 + byte(&in) % 24, byte(&in) % 16);
            break;
        case 4: case 5:
            open_window(p, &in);
            break;
        case 6:
            mwm_server_frame(s, time += 16);
            break;
        default: /* the program leaves */
            mwm_conn_free(p->conn);
            p->conn = NULL;
            mwm_server_service(s, p->server_fd, true, false);
            check(s);
            continue;
        }
        if (mwm_conn_failed(p->conn)) { /* a message the writer itself refuses: start over as a new program */
            mwm_conn_free(p->conn);
            p->conn = NULL;
            mwm_server_service(s, p->server_fd, true, false);
        } else {
            (void)mwm_conn_flush(p->conn);
            mwm_server_service(s, p->server_fd, true, true);
            drain(p);
        }
        check(s);
    }
    for (int i = 0; i < PROGRAMS; i++)
        if (programs[i].conn) mwm_conn_free(programs[i].conn);
    mwm_server_free(s);
    return 0;
}

#ifndef FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION
static uint64_t rng_state;
static uint32_t rnd(void) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return (uint32_t)(rng_state >> 16);
}

static long parse(const char *s, long fallback) {
    if (!s || !*s) return fallback;
    char *end;
    long v = strtol(s, &end, 0);
    return *end ? fallback : v;
}

int main(int argc, char **argv) {
    long iterations = parse(argc > 1 ? argv[1] : NULL, parse(getenv("FUZZ_ITERS"), 2000));
    rng_state = (uint64_t)parse(argc > 2 ? argv[2] : getenv("FUZZ_SEED"), 0x4d4f4e4144);
    if (rng_state == 0) rng_state = 1;
    static uint8_t script[2048];
    for (long it = 0; it < iterations; it++) {
        size_t len = 8 + rnd() % (sizeof script - 8);
        for (size_t i = 0; i < len; i++) script[i] = (uint8_t)rnd();
        LLVMFuzzerTestOneInput(script, len);
    }
    fprintf(stderr, "fuzz_wm: %ld scripts (%ld windows looked at), no invariant broken\n", iterations, windows_seen);
    return 0;
}
#endif
