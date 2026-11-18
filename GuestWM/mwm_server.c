/*
 * mwm_server.c — see mwm_server.h. This part: the programs connected, the
 * objects each has, the registry, shared memory and the output.
 *
 * A program's objects are kept by the ids it gave them (small numbers it
 * reuses), each with what it is. A request names an object and an opcode;
 * anything that does not fit (an object that is not there, a request the
 * interface does not have, arguments that do not fit the message, a buffer
 * outside its memory) ends with wl_display.error and the program dropped.
 */
#include "mwm_internal.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

enum { SHM_INVALID_FORMAT = 0, SHM_INVALID_STRIDE = 1, SHM_INVALID_FD = 2 };
enum { FORMAT_ARGB8888 = 0, FORMAT_XRGB8888 = 1 };
enum { OUTPUT_GEOMETRY = 0, OUTPUT_MODE = 1, OUTPUT_DONE = 2, OUTPUT_SCALE = 3 };

/* The globals a program may bind, by their name in the registry. */
static const struct {
    const char *interface;
    uint32_t version;
    obj_type type;
} globals[] = {
    {"wl_compositor", 4, T_COMPOSITOR},
    {"wl_shm", 1, T_SHM},
    {"xdg_wm_base", 2, T_WM_BASE},
    {"wl_output", 2, T_OUTPUT},
    {"wl_seat", 5, T_SEAT},
    {"wl_subcompositor", 1, T_SUBCOMPOSITOR},
    {"wl_data_device_manager", 3, T_DATA_MANAGER},
    {"zxdg_decoration_manager_v1", 1, T_DECORATION_MANAGER},
    {"wp_cursor_shape_manager_v1", 2, T_SHAPE_MANAGER},
};
enum { GLOBALS = sizeof globals / sizeof globals[0] };

/* ------------------------------------------------------------------------ */
/* Objects and errors                                                        */

void mwm_fail(client *c, uint32_t id, uint32_t code, const char *why) {
    if (c->dead) return;
    mwm_put_begin(c->conn, 1, 0);
    mwm_put_uint(c->conn, id);
    mwm_put_uint(c->conn, code);
    mwm_put_string(c->conn, why);
    mwm_put_end(c->conn);
    (void)mwm_conn_flush(c->conn);
    c->dead = true;
}

static object *find(client *c, uint32_t id) {
    if (id >= SERVER_ID) { /* one the server made for it */
        object *o = id - SERVER_ID < SERVER_IDS ? &c->server_objects[id - SERVER_ID] : NULL;
        return o && o->type != T_NONE ? o : NULL;
    }
    if (id == 0 || id >= c->object_cap || c->objects[id].type == T_NONE) return NULL;
    return &c->objects[id];
}

void *mwm_find_as(client *c, uint32_t id, obj_type type) {
    object *o = find(c, id);
    return o && o->type == type ? o->data : NULL;
}

bool mwm_is(client *c, uint32_t id, obj_type type) {
    object *o = find(c, id);
    return o && o->type == type;
}

bool mwm_add(client *c, uint32_t id, obj_type type, void *data) {
    if (c->dead) return false;
    if (id == 0 || id >= MWM_MAX_OBJECTS) {
        mwm_fail(c, 1, E_NO_MEMORY, "too many objects");
        return false;
    }
    if (id >= c->object_cap) {
        uint32_t cap = c->object_cap ? c->object_cap : 64;
        while (cap <= id) cap *= 2;
        object *grown = realloc(c->objects, cap * sizeof *grown);
        if (!grown) {
            mwm_fail(c, 1, E_NO_MEMORY, "out of memory");
            return false;
        }
        memset(grown + c->object_cap, 0, (cap - c->object_cap) * sizeof *grown);
        c->objects = grown;
        c->object_cap = cap;
    }
    if (c->objects[id].type != T_NONE) {
        mwm_fail(c, id, E_INVALID_OBJECT, "an object has that id already");
        return false;
    }
    c->objects[id] = (object){.type = (uint8_t)type, .data = data};
    return true;
}

uint32_t mwm_add_server(client *c, obj_type type, void *data) {
    for (uint32_t i = 0; !c->dead && i < SERVER_IDS; i++) {
        if (c->server_objects[i].type != T_NONE) continue;
        c->server_objects[i] = (object){.type = (uint8_t)type, .data = data};
        return SERVER_ID + i;
    }
    return 0;
}

void mwm_del(client *c, uint32_t id) {
    if (id >= SERVER_ID) { /* the server's own id: free to give again, and nothing to tell */
        if (id - SERVER_ID < SERVER_IDS) c->server_objects[id - SERVER_ID] = (object){.type = T_NONE};
        return;
    }
    if (id == 0 || id >= c->object_cap) return;
    c->objects[id] = (object){.type = T_NONE};
    if (c->dead) return;
    mwm_put_begin(c->conn, 1, 1);
    mwm_put_uint(c->conn, id);
    mwm_put_end(c->conn);
}

void mwm_event_uint(client *c, uint32_t id, uint16_t opcode, uint32_t v) {
    mwm_put_begin(c->conn, id, opcode);
    mwm_put_uint(c->conn, v);
    mwm_put_end(c->conn);
}

void mwm_skip_arguments(mwm_msg *m) { m->pos = (uint32_t)m->size - MWM_HEADER; }

/* ------------------------------------------------------------------------ */
/* Buffers and pools                                                         */

static void pool_unref(pool *p) {
    if (!p || --p->refs > 0) return;
    if (p->map) munmap(p->map, p->size);
    if (p->fd >= 0) close(p->fd);
    free(p);
}

void mwm_buffer_unshown(buffer *b) {
    if (!b || --b->shown > 0) return;
    client *c = b->owner;
    if (b->id == 0) { /* destroyed by the program meanwhile: nothing holds it now */
        pool_unref(b->pool);
        free(b);
    } else if (!c->dead) {
        mwm_put_begin(c->conn, b->id, 0); /* wl_buffer.release */
        mwm_put_end(c->conn);
    }
}

static void buffer_destroy(client *c, buffer *b, bool tell) {
    uint32_t id = b->id;
    b->id = 0;
    if (tell) mwm_del(c, id);
    if (b->shown == 0) {
        pool_unref(b->pool);
        free(b);
    }
}

static bool map_pool(pool *p, int32_t size) {
    struct stat st;
    if (size <= 0 || fstat(p->fd, &st) != 0 || st.st_size < (off_t)size) return false;
    uint8_t *map = mmap(NULL, (size_t)size, PROT_READ, MAP_SHARED, p->fd, 0);
    if (map == MAP_FAILED) return false;
    if (p->map) munmap(p->map, p->size);
    p->map = map;
    p->size = (size_t)size;
    return true;
}

static void create_pool(client *c, mwm_msg *m) {
    uint32_t id = mwm_get_uint(m);
    int fd = mwm_get_fd(m);
    int32_t size = mwm_get_int(m);
    if (m->bad) {
        if (fd >= 0) close(fd);
        return;
    }
    pool *p = calloc(1, sizeof *p);
    if (!p) {
        close(fd);
        mwm_fail(c, m->object, E_NO_MEMORY, "out of memory");
        return;
    }
    p->fd = fd;
    p->refs = 1;
    if (!map_pool(p, size)) {
        pool_unref(p);
        mwm_fail(c, m->object, SHM_INVALID_FD, "the pool's file is not that large, or cannot be mapped");
        return;
    }
    if (!mwm_add(c, id, T_POOL, p)) pool_unref(p);
}

static void create_buffer(client *c, pool *p, mwm_msg *m) {
    uint32_t id = mwm_get_uint(m);
    int32_t offset = mwm_get_int(m), width = mwm_get_int(m), height = mwm_get_int(m), stride = mwm_get_int(m);
    uint32_t format = mwm_get_uint(m);
    if (m->bad) return;
    if (format != FORMAT_ARGB8888 && format != FORMAT_XRGB8888) {
        mwm_fail(c, m->object, SHM_INVALID_FORMAT, "a format that was not offered");
        return;
    }
    /* In 64 bits: the sizes are the program's. */
    if (offset < 0 || width <= 0 || height <= 0 || stride < 0 || (int64_t)stride < (int64_t)width * 4
        || (int64_t)offset + (int64_t)stride * height > (int64_t)p->size) {
        mwm_fail(c, m->object, SHM_INVALID_STRIDE, "the buffer is not inside its pool");
        return;
    }
    buffer *b = calloc(1, sizeof *b);
    if (!b) {
        mwm_fail(c, m->object, E_NO_MEMORY, "out of memory");
        return;
    }
    *b = (buffer){.owner = c, .id = id, .pool = p, .offset = offset, .width = width, .height = height, .stride = stride,
                  .alpha = format == FORMAT_ARGB8888};
    if (!mwm_add(c, id, T_BUFFER, b)) {
        free(b);
        return;
    }
    p->refs++;
}

/* ------------------------------------------------------------------------ */
/* The registry and the output                                               */

static void output_scale(mwm_server *s, client *c, uint32_t id) {
    if (c->objects[id].version < 2) return;
    mwm_event_uint(c, id, OUTPUT_SCALE, (uint32_t)s->scale);
    mwm_put_begin(c->conn, id, OUTPUT_DONE);
    mwm_put_end(c->conn);
}

static void bind_global(client *c, mwm_msg *m) {
    mwm_server *s = c->server;
    uint32_t name = mwm_get_uint(m), len;
    const char *interface = mwm_get_string(m, &len);
    uint32_t version = mwm_get_uint(m), id = mwm_get_uint(m);
    if (m->bad) return;
    if (name == 0 || name > GLOBALS || !interface || strcmp(interface, globals[name - 1].interface) != 0 || version == 0
        || version > globals[name - 1].version) {
        mwm_fail(c, m->object, E_INVALID_OBJECT, "no such global");
        return;
    }
    obj_type type = globals[name - 1].type;
    if (!mwm_add(c, id, type, NULL)) return;
    c->objects[id].version = (uint8_t)version;
    if (type == T_SEAT) {
        mwm_seat_bound(c, id);
    } else if (type == T_SHM) {
        mwm_event_uint(c, id, 0, FORMAT_ARGB8888);
        mwm_event_uint(c, id, 0, FORMAT_XRGB8888);
    } else if (type == T_OUTPUT) {
        mwm_put_begin(c->conn, id, OUTPUT_GEOMETRY);
        mwm_put_int(c->conn, 0);
        mwm_put_int(c->conn, 0);
        mwm_put_int(c->conn, 0);
        mwm_put_int(c->conn, 0);
        mwm_put_int(c->conn, 0);
        mwm_put_string(c->conn, "Monad");
        mwm_put_string(c->conn, "display");
        mwm_put_int(c->conn, 0);
        mwm_put_end(c->conn);
        mwm_put_begin(c->conn, id, OUTPUT_MODE);
        mwm_put_uint(c->conn, 1); /* current */
        mwm_put_int(c->conn, s->screen.width);
        mwm_put_int(c->conn, s->screen.height);
        mwm_put_int(c->conn, 60000);
        mwm_put_end(c->conn);
        output_scale(s, c, id);
    }
}

void mwm_server_scale(mwm_server *s, int scale) {
    if (scale < 1 || scale > MAX_SCALE || scale == s->scale) return;
    s->scale = scale;
    for (int i = 0; i < MWM_MAX_CLIENTS; i++) {
        client *c = s->clients[i];
        if (!c || c->dead) continue;
        for (uint32_t id = 0; id < c->object_cap; id++)
            if (c->objects[id].type == T_OUTPUT) output_scale(s, c, id);
    }
    mwm_flush(s);
}

/* ------------------------------------------------------------------------ */
/* Requests                                                                  */

static void dispatch(mwm_server *s, client *c, mwm_msg *m) {
    object *o = find(c, m->object);
    if (m->object == 1) {
        if (m->opcode == 0) { /* sync */
            uint32_t id = mwm_get_uint(m);
            if (m->bad || !mwm_add(c, id, T_CALLBACK, NULL)) return;
            mwm_event_uint(c, id, 0, ++s->serial);
            mwm_del(c, id);
        } else if (m->opcode == 1) { /* get_registry */
            uint32_t id = mwm_get_uint(m);
            if (m->bad || !mwm_add(c, id, T_REGISTRY, NULL)) return;
            for (uint32_t i = 0; i < GLOBALS; i++) {
                mwm_put_begin(c->conn, id, 0);
                mwm_put_uint(c->conn, i + 1);
                mwm_put_string(c->conn, globals[i].interface);
                mwm_put_uint(c->conn, globals[i].version);
                mwm_put_end(c->conn);
            }
        } else {
            mwm_fail(c, 1, E_INVALID_METHOD, "wl_display has no such request");
        }
        return;
    }
    if (!o) {
        mwm_fail(c, m->object, E_INVALID_OBJECT, "no such object");
        return;
    }
    switch ((obj_type)o->type) {
    case T_REGISTRY:
        if (m->opcode == 0) bind_global(c, m);
        else mwm_fail(c, m->object, E_INVALID_METHOD, "wl_registry has no such request");
        break;
    case T_COMPOSITOR:
    case T_SURFACE:
    case T_REGION:
    case T_SUBCOMPOSITOR:
    case T_SUBSURFACE:
        mwm_surface_request(s, c, o, m);
        break;
    case T_CALLBACK: /* told once and gone: it takes no request */
        mwm_fail(c, m->object, E_INVALID_METHOD, "wl_callback has no requests");
        break;
    case T_SHM:
        if (m->opcode == 0) create_pool(c, m);
        else mwm_fail(c, m->object, E_INVALID_METHOD, "wl_shm has no such request");
        break;
    case T_POOL: {
        pool *p = o->data;
        if (m->opcode == 0) {
            create_buffer(c, p, m);
        } else if (m->opcode == 1) { /* destroy: its buffers keep the memory */
            mwm_del(c, m->object);
            pool_unref(p);
        } else if (m->opcode == 2) { /* resize: only ever larger */
            int32_t size = mwm_get_int(m);
            if (m->bad) return;
            if ((size_t)(size > 0 ? size : 0) < p->size || !map_pool(p, size)) {
                mwm_fail(c, m->object, SHM_INVALID_FD, "the pool cannot be resized to that");
            }
        } else {
            mwm_fail(c, m->object, E_INVALID_METHOD, "wl_shm_pool has no such request");
        }
        break;
    }
    case T_BUFFER:
        if (m->opcode == 0) {
            mwm_surface_forget_buffer(c, o->data); /* an attach that was never committed no longer names it */
            buffer_destroy(c, o->data, true);
        } else {
            mwm_fail(c, m->object, E_INVALID_METHOD, "wl_buffer has no such request");
        }
        break;
    case T_OUTPUT:
        if (m->opcode == 0) mwm_del(c, m->object); /* release */
        else mwm_fail(c, m->object, E_INVALID_METHOD, "wl_output has no such request");
        break;
    case T_SEAT:
    case T_POINTER:
    case T_KEYBOARD:
    case T_SHAPE_MANAGER:
    case T_SHAPE_DEVICE:
        mwm_seat_request(s, c, o, m);
        break;
    case T_WM_BASE:
    case T_POSITIONER:
    case T_XDG_SURFACE:
    case T_TOPLEVEL:
    case T_POPUP:
    case T_DECORATION_MANAGER:
    case T_DECORATION:
        mwm_shell_request(s, c, o, m);
        break;
    case T_DATA_MANAGER:
    case T_DATA_SOURCE:
    case T_DATA_DEVICE:
    case T_DATA_OFFER:
        mwm_data_request(s, c, o, m);
        break;
    case T_DISPLAY:
    case T_NONE:
        mwm_fail(c, m->object, E_INVALID_OBJECT, "no such object");
        break;
    }
}

/* ------------------------------------------------------------------------ */
/* Clients                                                                   */

static void client_free(mwm_server *s, client *c) {
    c->dead = true; /* nothing more is said to it */
    mwm_data_client_gone(s, c);
    /* Surfaces first (they hold buffers), then the rest. */
    for (uint32_t i = 0; i < c->object_cap; i++) {
        if (c->objects[i].type == T_SURFACE) {
            mwm_surface_destroy(s, c, c->objects[i].data, false);
            c->objects[i].type = T_NONE;
        }
    }
    for (uint32_t i = 0; i < c->object_cap; i++) {
        object *o = &c->objects[i];
        switch ((obj_type)o->type) {
        case T_BUFFER: buffer_destroy(c, o->data, false); break;
        case T_XDG_SURFACE: case T_SUBSURFACE: case T_POSITIONER: case T_DATA_SOURCE: free(o->data); break;
        default: continue;
        }
        o->type = T_NONE;
    }
    for (uint32_t i = 0; i < c->object_cap; i++) {
        if (c->objects[i].type == T_POOL) pool_unref(c->objects[i].data);
    }
    mwm_conn_free(c->conn);
    free(c->objects);
    free(c);
}

mwm_server *mwm_server_new(const mwm_screen *screen) {
    if (!screen || !screen->pixels || screen->width <= 0 || screen->height <= 0 || screen->stride < screen->width) return NULL;
    mwm_server *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    s->screen = *screen;
    s->scale = 1;
    if (!mwm_seat_init(s)) {
        free(s);
        return NULL;
    }
    mwm_data_init(s);
    return s;
}

void mwm_server_free(mwm_server *s) {
    if (!s) return;
    for (int i = 0; i < MWM_MAX_CLIENTS; i++)
        if (s->clients[i]) client_free(s, s->clients[i]);
    mwm_seat_free(s);
    mwm_data_free(s);
    free(s);
}

bool mwm_server_add_client(mwm_server *s, int fd) {
    for (int i = 0; i < MWM_MAX_CLIENTS; i++) {
        if (s->clients[i]) continue;
        client *c = calloc(1, sizeof *c);
        mwm_conn *conn = c ? mwm_conn_new(fd) : NULL;
        if (!conn) {
            if (!c) close(fd);
            free(c);
            return false;
        }
        c->server = s;
        c->conn = conn;
        s->clients[i] = c;
        return true;
    }
    close(fd);
    return false;
}

int mwm_server_sockets(const mwm_server *s, int *fds, bool *wants_write, int max) {
    int n = 0;
    for (int i = 0; i < MWM_MAX_CLIENTS && n < max; i++) {
        if (!s->clients[i]) continue;
        fds[n] = mwm_conn_fd(s->clients[i]->conn);
        wants_write[n] = mwm_conn_wants_write(s->clients[i]->conn);
        n++;
    }
    return n + mwm_data_sockets(s, fds + n, wants_write + n, max - n);
}

void mwm_flush(mwm_server *s) {
    for (int i = 0; i < MWM_MAX_CLIENTS; i++) {
        client *c = s->clients[i];
        if (!c) continue;
        if (!c->dead && mwm_conn_flush(c->conn) < 0) c->dead = true;
        if (c->dead || mwm_conn_failed(c->conn)) {
            s->clients[i] = NULL;
            client_free(s, c);
        }
    }
}

void mwm_server_service(mwm_server *s, int fd, bool readable, bool writable) {
    (void)writable; /* what waits is sent below, for every client */
    bool programs = false;
    for (int i = 0; i < MWM_MAX_CLIENTS; i++) {
        client *c = s->clients[i];
        if (!c || mwm_conn_fd(c->conn) != fd) continue;
        programs = true;
        if (readable) {
            int got;
            do {
                got = mwm_conn_read(c->conn);
                mwm_msg m;
                while (!c->dead && mwm_conn_next(c->conn, &m)) {
                    dispatch(s, c, &m);
                    if (!c->dead && !mwm_msg_done(&m)) mwm_fail(c, m.object, E_INVALID_METHOD, "the request's arguments do not fit it");
                }
            } while (got > 0 && !c->dead);
            if (got < 0) c->dead = true;
        }
        break;
    }
    if (!programs) (void)mwm_data_service(s, fd); /* a pipe of the clipboard's */
    mwm_flush(s);
}

void mwm_server_frame(mwm_server *s, uint32_t time_ms) {
    s->frame_time = time_ms;
    mwm_data_frame(s, time_ms);
    for (int i = 0; s->frames_waiting > 0 && i < MWM_MAX_CLIENTS; i++) {
        client *c = s->clients[i];
        if (!c || c->dead) continue;
        for (uint32_t id = 0; id < c->object_cap; id++) {
            if (c->objects[id].type != T_SURFACE) continue;
            surface *f = c->objects[id].data;
            for (int k = 0; k < f->waiting_count; k++) {
                mwm_event_uint(c, f->frames_waiting[k], 0, time_ms);
                mwm_del(c, f->frames_waiting[k]);
            }
            s->frames_waiting -= f->waiting_count;
            f->waiting_count = 0;
        }
    }
    mwm_flush(s);
}

bool mwm_server_wants_frame(const mwm_server *s) { return s->frames_waiting > 0 || mwm_data_waits(s); }

void mwm_server_size(const mwm_server *s, int *width, int *height) {
    *width = s->screen.width;
    *height = s->screen.height;
}


int mwm_server_windows(const mwm_server *s, mwm_window *out, int max) {
    int n = 0;
    for (int i = 0; i < s->window_count; i++) {
        const window *w = &s->windows[s->order[i]];
        if (out && n < max) {
            const xdg *x = w->surface ? w->surface->xdg : NULL;
            /* The part that is the window, in its pixels; all of it unless the program said less. */
            box inner = {0, 0, w->width, w->height};
            if (x && x->geometry.x2 > x->geometry.x1 && x->geometry.y2 > x->geometry.y1) {
                box g = {x->geometry.x1 * w->scale, x->geometry.y1 * w->scale, x->geometry.x2 * w->scale, x->geometry.y2 * w->scale};
                if (g.x1 < 0) g.x1 = 0;
                if (g.y1 < 0) g.y1 = 0;
                if (g.x2 > w->width) g.x2 = w->width;
                if (g.y2 > w->height) g.y2 = w->height;
                if (g.x2 > g.x1 && g.y2 > g.y1) inner = g;
            }
            /* A popup: the window it is on, and where it stands from that window's own top left, in that window's pixels. */
            const window *on = mwm_shell_parent(w);
            out[n] = (mwm_window){.id = w->id, .x = w->x, .y = w->y, .width = w->width, .height = w->height, .scale = w->scale,
                                  .inner_x = inner.x1, .inner_y = inner.y1, .inner_width = inner.x2 - inner.x1,
                                  .inner_height = inner.y2 - inner.y1, .parent = on ? on->id : 0,
                                  .offset_x = on ? x->px * on->scale : 0, .offset_y = on ? x->py * on->scale : 0,
                                  .title = x ? x->title : "", .app_id = x ? x->app_id : ""};
        }
        n++;
    }
    return out ? (n < max ? n : max) : n;
}

uint32_t mwm_server_generation(const mwm_server *s) { return s->generation; }
