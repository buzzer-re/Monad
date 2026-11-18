/*
 * wm_test_client.h — what the window manager's tests share: a sheet of
 * plain memory for the windows' pixels, a server on it, and a client that speaks the wire format by
 * hand (connects, binds what the registry offers, opens a window).
 */
#ifndef WM_TEST_CLIENT_H
#define WM_TEST_CLIENT_H

#include "mwm_server.h"
#include "mwm_wire.h"

#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* A test uses the helpers it needs: the others are not a mistake of its. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#pragma GCC diagnostic ignored "-Wunused-variable"

static int checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)

enum { W = 400, H = 200 };
static uint32_t pixels[W * H];

static mwm_server *server(void) {
    memset(pixels, 0, sizeof pixels);
    mwm_screen screen = {.pixels = pixels, .width = W, .height = H, .stride = W};
    mwm_server *s = mwm_server_new(&screen);
    CHECK(s);
    return s;
}

enum { MAX_GLOBALS = 32 };

/* A client: its end of the socket, the server's descriptor, what the
 * registry offered, and the ids it gave what it bound. */
typedef struct {
    mwm_conn *c;
    int server_fd;
    uint32_t next;
    uint32_t registry;
    struct {
        uint32_t name, version;
        char interface[40];
    } globals[MAX_GLOBALS];
    int global_count;
    uint32_t compositor, shm, wm;
} client;

static void pump(mwm_server *s, client *k) {
    (void)mwm_conn_flush(k->c);
    mwm_server_service(s, k->server_fd, true, true);
    (void)mwm_conn_read(k->c);
}

/* What the server sent since, read without sending anything. */
static void drain(mwm_server *s, client *k) {
    mwm_server_service(s, k->server_fd, false, true);
    (void)mwm_conn_read(k->c);
}

/* The next event, which must be there. */
static mwm_msg event(client *k) {
    mwm_msg m;
    CHECK(mwm_conn_next(k->c, &m));
    return m;
}

static bool no_event(client *k) {
    mwm_msg m;
    return !mwm_conn_next(k->c, &m);
}

enum { DISPLAY_ERROR = 0, DISPLAY_DELETE_ID = 1 };

/* The version the registry offers of an interface; 0 when it has none. */
static uint32_t offered(const client *k, const char *interface) {
    for (int i = 0; i < k->global_count; i++)
        if (strcmp(k->globals[i].interface, interface) == 0) return k->globals[i].version;
    return 0;
}

/* Binds a global by its interface: the new object's id (nothing is read). */
static uint32_t bind_global(client *k, const char *interface, uint32_t version) {
    for (int i = 0; i < k->global_count; i++) {
        if (strcmp(k->globals[i].interface, interface) != 0) continue;
        uint32_t id = k->next++;
        mwm_put_begin(k->c, k->registry, 0); /* wl_registry.bind */
        mwm_put_uint(k->c, k->globals[i].name);
        mwm_put_string(k->c, interface);
        mwm_put_uint(k->c, version);
        mwm_put_uint(k->c, id);
        mwm_put_end(k->c);
        return id;
    }
    CHECK(!"the registry offers that interface");
    return 0;
}

/* Connects and binds what a window needs, by the names the registry gave. */
static client connect_client(mwm_server *s) {
    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    client k = {.c = mwm_conn_new(sv[0]), .server_fd = sv[1], .next = 2};
    CHECK(mwm_server_add_client(s, sv[1]));
    k.registry = k.next++;
    mwm_put_begin(k.c, 1, 1); /* wl_display.get_registry */
    mwm_put_uint(k.c, k.registry);
    mwm_put_end(k.c);
    pump(s, &k);
    mwm_msg m;
    while (mwm_conn_next(k.c, &m)) {
        CHECK(m.object == k.registry && m.opcode == 0); /* wl_registry.global */
        uint32_t name = mwm_get_uint(&m), len;
        const char *interface = mwm_get_string(&m, &len);
        uint32_t version = mwm_get_uint(&m);
        CHECK(interface && mwm_msg_done(&m) && name != 0 && version >= 1);
        CHECK(k.global_count < MAX_GLOBALS && len < sizeof k.globals[0].interface);
        k.globals[k.global_count].name = name;
        k.globals[k.global_count].version = version;
        memcpy(k.globals[k.global_count].interface, interface, len + 1);
        k.global_count++;
    }
    k.compositor = bind_global(&k, "wl_compositor", 1);
    k.shm = bind_global(&k, "wl_shm", 1);
    k.wm = bind_global(&k, "xdg_wm_base", 1);
    pump(s, &k);
    m = event(&k);
    CHECK(m.object == k.shm && m.opcode == 0); /* wl_shm.format: ARGB8888 */
    CHECK(mwm_get_uint(&m) == 0);
    m = event(&k);
    CHECK(m.object == k.shm && m.opcode == 0 && mwm_get_uint(&m) == 1); /* XRGB8888 */
    CHECK(no_event(&k));
    return k;
}

static void request(client *k, uint32_t object, uint16_t opcode, int count, ...) {
    va_list ap;
    va_start(ap, count);
    mwm_put_begin(k->c, object, opcode);
    for (int i = 0; i < count; i++) mwm_put_uint(k->c, va_arg(ap, uint32_t));
    mwm_put_end(k->c);
    va_end(ap);
}

/* A file of `words` pixels, each `color` plus its index in the low byte. */
static int pixel_file(uint32_t color, int words) {
    char path[] = "/tmp/monad-wm-test-XXXXXX";
    int fd = mkstemp(path);
    CHECK(fd >= 0);
    unlink(path);
    for (int i = 0; i < words; i++) {
        uint32_t v = color + (uint32_t)(i & 0xff);
        CHECK(write(fd, &v, 4) == 4);
    }
    return fd;
}

typedef struct {
    uint32_t surface, xdg, toplevel, pool, buffer;
    /* Its id on the sheet, once it is there. */
    uint32_t id;
} window;

/* A buffer of w × h pixels in a pool of its own. */
static void make_buffer(client *k, uint32_t pool, uint32_t buffer, uint32_t color, int w, int h) {
    int fd = pixel_file(color, w * h);
    mwm_put_begin(k->c, k->shm, 0); /* create_pool */
    mwm_put_uint(k->c, pool);
    mwm_put_fd(k->c, fd);
    mwm_put_int(k->c, w * h * 4);
    mwm_put_end(k->c);
    close(fd);
    request(k, pool, 0, 6, buffer, 0, (uint32_t)w, (uint32_t)h, (uint32_t)w * 4, 1); /* create_buffer, XRGB8888 */
}

/* A buffer of the pixels given, each with its own share of what is under it (ARGB8888, premultiplied). */
static void make_drawn(client *k, uint32_t pool, uint32_t buffer, const uint32_t *drawn, int w, int h) {
    char path[] = "/tmp/monad-wm-test-XXXXXX";
    int fd = mkstemp(path);
    CHECK(fd >= 0);
    unlink(path);
    CHECK(write(fd, drawn, (size_t)w * (size_t)h * 4) == (ssize_t)((size_t)w * (size_t)h * 4));
    mwm_put_begin(k->c, k->shm, 0); /* create_pool */
    mwm_put_uint(k->c, pool);
    mwm_put_fd(k->c, fd);
    mwm_put_int(k->c, w * h * 4);
    mwm_put_end(k->c);
    close(fd);
    request(k, pool, 0, 6, buffer, 0, (uint32_t)w, (uint32_t)h, (uint32_t)w * 4, 0); /* create_buffer, ARGB8888 */
}

/* The surface shows that buffer from now on, all of it new. */
static void show_buffer(mwm_server *s, client *k, uint32_t surface, uint32_t buffer, int w, int h) {
    request(k, surface, 1, 3, buffer, 0, 0);                   /* attach */
    request(k, surface, 2, 4, 0, 0, (uint32_t)w, (uint32_t)h); /* damage */
    request(k, surface, 6, 0);                                 /* commit */
    pump(s, k);
}

/* A top-level window of w × h pixels, mapped: the whole exchange. */
static window open_window(mwm_server *s, client *k, const char *title, const char *app, uint32_t color, int w, int h) {
    window v = {.surface = k->next++, .xdg = k->next++, .toplevel = k->next++, .pool = k->next++, .buffer = k->next++};
    int before = mwm_server_windows(s, NULL, 0);
    request(k, k->compositor, 0, 1, v.surface);         /* create_surface */
    request(k, k->wm, 2, 2, v.xdg, v.surface);          /* get_xdg_surface */
    request(k, v.xdg, 1, 1, v.toplevel);                /* get_toplevel */
    mwm_put_begin(k->c, v.toplevel, 2);                 /* set_title */
    mwm_put_string(k->c, title);
    mwm_put_end(k->c);
    mwm_put_begin(k->c, v.toplevel, 3);                 /* set_app_id */
    mwm_put_string(k->c, app);
    mwm_put_end(k->c);
    request(k, v.surface, 6, 0);                        /* commit: asks for its first configure */
    pump(s, k);
    mwm_msg m = event(k);
    CHECK(m.object == v.toplevel && m.opcode == 0);     /* xdg_toplevel.configure: any size */
    CHECK(mwm_get_int(&m) == 0 && mwm_get_int(&m) == 0);
    m = event(k);
    CHECK(m.object == v.xdg && m.opcode == 0);          /* xdg_surface.configure */
    uint32_t serial = mwm_get_uint(&m);
    CHECK(mwm_msg_done(&m));
    CHECK(mwm_server_windows(s, NULL, 0) == before);    /* nothing to show before it drew */
    request(k, v.xdg, 4, 1, serial);                    /* ack_configure */
    make_buffer(k, v.pool, v.buffer, color, w, h);
    request(k, v.surface, 1, 3, v.buffer, 0, 0);        /* attach */
    request(k, v.surface, 2, 4, 0, 0, (uint32_t)w, (uint32_t)h); /* damage */
    request(k, v.surface, 6, 0);                        /* commit */
    pump(s, k);
    mwm_window list[MWM_MAX_WINDOWS];
    int n = mwm_server_windows(s, list, MWM_MAX_WINDOWS);
    if (n == before + 1) v.id = list[n - 1].id;
    return v;
}

static uint32_t at(int x, int y) { return pixels[y * W + x]; }

/* What of a window was drawn since this was last asked: all of it at once; nothing is all zero. */
static mwm_drawn drawn(mwm_server *s, uint32_t id) {
    mwm_drawn d = {0};
    if (!mwm_server_take_drawn(s, id, W * H, &d)) d = (mwm_drawn){0};
    return d;
}

static bool drew(mwm_server *s, uint32_t id, int x, int y, int w, int h) {
    mwm_drawn d = drawn(s, id);
    return d.x == x && d.y == y && d.width == w && d.height == h;
}

/* The error the server sent before dropping the client: its code. */
static int dropped_with(mwm_server *s, client *k, uint32_t *object) {
    pump(s, k);
    mwm_msg m;
    int code = -1;
    while (mwm_conn_next(k->c, &m)) {
        if (m.object == 1 && m.opcode == DISPLAY_ERROR) {
            uint32_t len;
            *object = mwm_get_uint(&m);
            code = (int)mwm_get_uint(&m);
            CHECK(mwm_get_string(&m, &len) != NULL);
        }
    }
    int fds[MWM_MAX_SOCKETS];
    bool wants[MWM_MAX_SOCKETS];
    int n = mwm_server_sockets(s, fds, wants, MWM_MAX_SOCKETS);
    for (int i = 0; i < n; i++) CHECK(fds[i] != k->server_fd); /* gone from the server */
    mwm_conn_free(k->c);
    return code;
}

enum { ERROR_INVALID_OBJECT = 0, ERROR_INVALID_METHOD = 1, ERROR_NO_MEMORY = 2, ERROR_IMPLEMENTATION = 3 };

#pragma GCC diagnostic pop

#endif
