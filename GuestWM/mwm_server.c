/*
 * mwm_server.c — see mwm_server.h.
 *
 * A program's objects are kept by the ids it gave them (small numbers it
 * reuses), each with what it is. A request names an object and an opcode;
 * anything that does not fit (an object that is not there, a request the
 * interface does not have, arguments that do not fit the message, a buffer
 * outside its memory) ends with wl_display.error and the program dropped.
 */
#include "mwm_internal.h"

#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

enum { SHM_INVALID_FORMAT = 0, SHM_INVALID_STRIDE = 1, SHM_INVALID_FD = 2 };
enum { FORMAT_ARGB8888 = 0, FORMAT_XRGB8888 = 1 };

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
};
enum { GLOBALS = sizeof globals / sizeof globals[0] };

/* ------------------------------------------------------------------------ */
/* Memory that can go away under us                                          */

/* A program can shrink the file behind its pool after handing it over;
 * reading past its end then raises SIGBUS. The copy runs between
 * sigsetjmp and here: mwm_main.c's handler calls mwm_server_bus_error. */
static sigjmp_buf bus_jump;
static volatile sig_atomic_t bus_guarded;

void mwm_server_bus_error(void) {
    if (bus_guarded) siglongjmp(bus_jump, 1);
}

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
    if (id == 0 || id >= c->object_cap || c->objects[id].type == T_NONE) return NULL;
    return &c->objects[id];
}

void *mwm_find_as(client *c, uint32_t id, obj_type type) {
    object *o = find(c, id);
    return o && o->type == type ? o->data : NULL;
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
    c->objects[id].type = (uint8_t)type;
    c->objects[id].data = data;
    return true;
}

void mwm_del(client *c, uint32_t id) {
    if (id == 0 || id >= c->object_cap) return;
    c->objects[id].type = T_NONE;
    c->objects[id].data = NULL;
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

/* ------------------------------------------------------------------------ */
/* The display                                                               */

static void present(mwm_server *s, int x, int y, int w, int h) {
    if (w > 0 && h > 0 && s->screen.present) s->screen.present(s->screen.ctx, x, y, w, h);
}

static void clear(mwm_server *s, int x, int y, int w, int h) {
    if (w <= 0 || h <= 0) return;
    for (int row = y; row < y + h; row++) memset(s->screen.pixels + (size_t)row * (size_t)s->screen.stride + x, 0, (size_t)w * 4);
    present(s, x, y, w, h);
}

/* The leftmost place `width` wide that no window but `self` is on, or -1. */
static int place(const mwm_server *s, const window *self, int width) {
    int x = 0;
    for (;;) {
        const window *hit = NULL;
        for (int i = 0; i < MWM_MAX_WINDOWS; i++) {
            const window *w = &s->windows[i];
            if (!w->used || w == self) continue;
            if (x < w->x + w->width + MWM_GAP && w->x < x + width + MWM_GAP) {
                if (!hit || w->x + w->width > hit->x + hit->width) hit = w;
            }
        }
        if (!hit) return x + width <= s->screen.width || x == 0 ? x : -1;
        x = hit->x + hit->width + MWM_GAP;
        if (x >= s->screen.width) return -1;
    }
}

/* How wide a window at `x` may be before it meets the next one or the
 * display's edge. */
static int room_at(const mwm_server *s, const window *self, int x) {
    int room = s->screen.width - x;
    for (int i = 0; i < MWM_MAX_WINDOWS; i++) {
        const window *w = &s->windows[i];
        if (!w->used || w == self || w->x + w->width <= x) continue;
        if (w->x - MWM_GAP - x < room) room = w->x - MWM_GAP - x;
    }
    return room > 0 ? room : 0;
}

void mwm_window_gone(mwm_server *s, window *w) {
    if (!w || !w->used) return;
    clear(s, w->x, w->y, w->width, w->height);
    int index = (int)(w - s->windows);
    for (int i = 0; i < s->window_count; i++) {
        if (s->order[i] != index) continue;
        memmove(&s->order[i], &s->order[i + 1], (size_t)(s->window_count - i - 1) * sizeof(int));
        s->window_count--;
        break;
    }
    if (w->surface) w->surface->window = NULL;
    memset(w, 0, sizeof *w);
    s->generation++;
}

/* Copies the buffer to the window's place, cut at the display's edges. */
static bool blit(mwm_server *s, const window *w, const buffer *b) {
    volatile bool ok = true;
    bus_guarded = 1;
    if (sigsetjmp(bus_jump, 1) == 0) {
        for (int row = 0; row < w->height; row++) {
            const uint8_t *src = b->pool->map + b->offset + (size_t)row * (size_t)b->stride;
            uint32_t *dst = s->screen.pixels + (size_t)(w->y + row) * (size_t)s->screen.stride + w->x;
            for (int col = 0; col < w->width; col++) {
                uint32_t v;
                memcpy(&v, src + (size_t)col * 4, 4);
                dst[col] = v | 0xff000000u; /* a window is opaque on the display */
            }
        }
    } else {
        ok = false; /* the memory behind the buffer went away */
    }
    bus_guarded = 0;
    return ok;
}

/* The surface's buffer changed: its window comes, changes or goes. */
static void show(mwm_server *s, surface *f) {
    buffer *b = f->current;
    if (!b || !f->xdg || !f->xdg->configured) {
        mwm_window_gone(s, f->window);
        return;
    }
    window *w = f->window;
    int width = b->width < s->screen.width ? b->width : s->screen.width;
    int height = b->height < s->screen.height ? b->height : s->screen.height;
    window before = {0};
    if (!w) {
        for (int i = 0; i < MWM_MAX_WINDOWS && !w; i++)
            if (!s->windows[i].used) w = &s->windows[i];
        if (!w) return; /* as many windows as there may be: this one is not shown */
        int x = place(s, NULL, width);
        if (x < 0) return; /* no room on the display */
        w->used = true;
        w->id = ++s->next_window;
        w->x = x;
        w->y = 0;
        w->surface = f;
        f->window = w;
        s->order[s->window_count++] = (int)(w - s->windows);
        s->generation++;
    } else {
        before = *w;
        if (width != w->width || height != w->height) {
            /* Where it stands while it fits there, else a place of its own. */
            if (width > room_at(s, w, w->x)) {
                int x = place(s, w, width);
                if (x >= 0) w->x = x;
            }
            s->generation++;
        }
    }
    /* Never onto its neighbour: with no place wide enough, cut where it stands. */
    int room = room_at(s, w, w->x);
    w->width = width < room ? width : room;
    w->height = height;
    if (before.used && (before.x != w->x || before.width > w->width || before.height > w->height)) {
        clear(s, before.x, before.y, before.width, before.height); /* what the old size left */
    }
    if (!blit(s, w, b)) {
        mwm_fail(f->owner, f->id, E_IMPLEMENTATION, "the buffer's memory is gone");
        return;
    }
    present(s, w->x, w->y, w->width, w->height);
}

/* ------------------------------------------------------------------------ */
/* Buffers and pools                                                         */

static void pool_unref(pool *p) {
    if (!p || --p->refs > 0) return;
    if (p->map) munmap(p->map, p->size);
    if (p->fd >= 0) close(p->fd);
    free(p);
}

static void buffer_unshown(buffer *b) {
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

/* ------------------------------------------------------------------------ */
/* Surfaces                                                                  */

static void surface_destroy(mwm_server *s, client *c, surface *f, bool tell) {
    mwm_window_gone(s, f->window);
    if (f->xdg) f->xdg->surface = NULL;
    buffer_unshown(f->current);
    for (int i = 0; i < f->pending_count; i++) mwm_del(c, f->frames_pending[i]);
    for (int i = 0; i < f->waiting_count; i++) mwm_del(c, f->frames_waiting[i]);
    if (tell) mwm_del(c, f->id);
    free(f);
}

static void surface_commit(mwm_server *s, client *c, surface *f) {
    /* Callbacks asked for since the last commit wait for the next frame. */
    for (int i = 0; i < f->pending_count && f->waiting_count < MAX_FRAMES; i++) {
        f->frames_waiting[f->waiting_count++] = f->frames_pending[i];
    }
    f->pending_count = 0;
    mwm_shell_commit(s, c, f);
    if (!f->attached) return;
    f->attached = false;
    buffer *old = f->current;
    f->current = f->pending;
    f->pending = NULL;
    if (f->current) f->current->shown++;
    show(s, f);
    buffer_unshown(old);
}

/* ------------------------------------------------------------------------ */
/* Requests                                                                  */

void mwm_skip_arguments(mwm_msg *m) { m->pos = (uint32_t)m->size - MWM_HEADER; }

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
    if (type == T_SHM) {
        mwm_event_uint(c, id, 0, FORMAT_ARGB8888);
        mwm_event_uint(c, id, 0, FORMAT_XRGB8888);
    } else if (type == T_OUTPUT) {
        mwm_put_begin(c->conn, id, 0); /* geometry */
        mwm_put_int(c->conn, 0);
        mwm_put_int(c->conn, 0);
        mwm_put_int(c->conn, 0);
        mwm_put_int(c->conn, 0);
        mwm_put_int(c->conn, 0);
        mwm_put_string(c->conn, "Monad");
        mwm_put_string(c->conn, "display");
        mwm_put_int(c->conn, 0);
        mwm_put_end(c->conn);
        mwm_put_begin(c->conn, id, 1); /* mode: current */
        mwm_put_uint(c->conn, 1);
        mwm_put_int(c->conn, s->screen.width);
        mwm_put_int(c->conn, s->screen.height);
        mwm_put_int(c->conn, 60000);
        mwm_put_end(c->conn);
        if (version >= 2) {
            mwm_event_uint(c, id, 3, 1); /* scale */
            mwm_put_begin(c->conn, id, 2); /* done */
            mwm_put_end(c->conn);
        }
    }
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
    b->owner = c;
    b->id = id;
    b->pool = p;
    b->offset = offset;
    b->width = width;
    b->height = height;
    b->stride = stride;
    if (!mwm_add(c, id, T_BUFFER, b)) {
        free(b);
        return;
    }
    p->refs++;
}

static void surface_request(mwm_server *s, client *c, surface *f, mwm_msg *m) {
    switch (m->opcode) {
    case 0: /* destroy */
        surface_destroy(s, c, f, true);
        break;
    case 1: { /* attach */
        uint32_t id = mwm_get_uint(m);
        (void)mwm_get_int(m);
        (void)mwm_get_int(m);
        if (m->bad) return;
        buffer *b = NULL;
        if (id != 0 && !(b = mwm_find_as(c, id, T_BUFFER))) {
            mwm_fail(c, f->id, E_INVALID_OBJECT, "not a buffer");
            return;
        }
        f->pending = b;
        f->attached = true;
        break;
    }
    case 3: { /* frame */
        uint32_t id = mwm_get_uint(m);
        if (m->bad) return;
        if (f->pending_count == MAX_FRAMES) {
            mwm_fail(c, f->id, E_NO_MEMORY, "too many frame callbacks");
            return;
        }
        if (mwm_add(c, id, T_CALLBACK, NULL)) f->frames_pending[f->pending_count++] = id;
        break;
    }
    case 6: /* commit */
        surface_commit(s, c, f);
        break;
    case 2: case 4: case 5: case 7: case 8: case 9: /* damage, regions, transform, scale: all of it is copied anyway */
        mwm_skip_arguments(m);
        break;
    default:
        mwm_fail(c, f->id, E_INVALID_METHOD, "wl_surface has no such request");
    }
}

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
        if (m->opcode == 0) { /* create_surface */
            uint32_t id = mwm_get_uint(m);
            if (m->bad) return;
            surface *f = calloc(1, sizeof *f);
            if (!f) {
                mwm_fail(c, m->object, E_NO_MEMORY, "out of memory");
                return;
            }
            f->owner = c;
            f->id = id;
            if (!mwm_add(c, id, T_SURFACE, f)) free(f);
        } else if (m->opcode == 1) { /* create_region */
            uint32_t id = mwm_get_uint(m);
            if (!m->bad) (void)mwm_add(c, id, T_REGION, NULL);
        } else {
            mwm_fail(c, m->object, E_INVALID_METHOD, "wl_compositor has no such request");
        }
        break;
    case T_SURFACE:
        surface_request(s, c, o->data, m);
        break;
    case T_CALLBACK: /* told once and gone: it takes no request */
        mwm_fail(c, m->object, E_INVALID_METHOD, "wl_callback has no requests");
        break;
    case T_REGION: /* nothing is cut by regions yet: only destroy means anything */
        if (m->opcode == 0) mwm_del(c, m->object);
        else mwm_skip_arguments(m);
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
            buffer *b = o->data;
            /* An attach that was never committed no longer names it. */
            for (uint32_t i = 0; i < c->object_cap; i++) {
                if (c->objects[i].type == T_SURFACE && ((surface *)c->objects[i].data)->pending == b) {
                    ((surface *)c->objects[i].data)->pending = NULL;
                }
            }
            buffer_destroy(c, b, true);
        } else {
            mwm_fail(c, m->object, E_INVALID_METHOD, "wl_buffer has no such request");
        }
        break;
    case T_OUTPUT:
        if (m->opcode == 0) mwm_del(c, m->object); /* release */
        else mwm_fail(c, m->object, E_INVALID_METHOD, "wl_output has no such request");
        break;
    case T_WM_BASE:
    case T_POSITIONER:
    case T_XDG_SURFACE:
    case T_TOPLEVEL:
        mwm_shell_request(s, c, o, m);
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
    /* Surfaces first (they hold buffers), then the rest. */
    for (uint32_t i = 0; i < c->object_cap; i++) {
        if (c->objects[i].type == T_SURFACE) {
            surface_destroy(s, c, c->objects[i].data, false);
            c->objects[i].type = T_NONE;
        }
    }
    for (uint32_t i = 0; i < c->object_cap; i++) {
        object *o = &c->objects[i];
        switch ((obj_type)o->type) {
        case T_BUFFER: buffer_destroy(c, o->data, false); break;
        case T_XDG_SURFACE: free(o->data); break;
        default: break;
        }
        if (o->type == T_BUFFER || o->type == T_XDG_SURFACE) o->type = T_NONE;
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
    if (s) s->screen = *screen;
    return s;
}

void mwm_server_free(mwm_server *s) {
    if (!s) return;
    for (int i = 0; i < MWM_MAX_CLIENTS; i++)
        if (s->clients[i]) client_free(s, s->clients[i]);
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
    return n;
}

static void flush_all(mwm_server *s) {
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
    for (int i = 0; i < MWM_MAX_CLIENTS; i++) {
        client *c = s->clients[i];
        if (!c || mwm_conn_fd(c->conn) != fd) continue;
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
    flush_all(s);
}

void mwm_server_frame(mwm_server *s, uint32_t time_ms) {
    for (int i = 0; i < MWM_MAX_CLIENTS; i++) {
        client *c = s->clients[i];
        if (!c || c->dead) continue;
        for (uint32_t id = 0; id < c->object_cap; id++) {
            if (c->objects[id].type != T_SURFACE) continue;
            surface *f = c->objects[id].data;
            for (int k = 0; k < f->waiting_count; k++) {
                mwm_event_uint(c, f->frames_waiting[k], 0, time_ms);
                mwm_del(c, f->frames_waiting[k]);
            }
            f->waiting_count = 0;
        }
    }
    flush_all(s);
}

int mwm_server_windows(const mwm_server *s, mwm_window *out, int max) {
    int n = 0;
    for (int i = 0; i < s->window_count; i++) {
        const window *w = &s->windows[s->order[i]];
        if (out && n < max) {
            const xdg *x = w->surface ? w->surface->xdg : NULL;
            out[n] = (mwm_window){.id = w->id, .x = w->x, .y = w->y, .width = w->width, .height = w->height,
                                  .title = x ? x->title : "", .app_id = x ? x->app_id : ""};
        }
        n++;
    }
    return out ? (n < max ? n : max) : n;
}

uint32_t mwm_server_generation(const mwm_server *s) { return s->generation; }
