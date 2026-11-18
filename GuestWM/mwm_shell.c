/*
 * mwm_shell.c — windows as programs ask for them: xdg_wm_base, its
 * xdg_surface and xdg_toplevel. A surface given the role of a top-level
 * window is told its size at its first commit, and becomes a window on the
 * display once it has a buffer (mwm_server.c shows it).
 */
#include "mwm_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { XDG_ROLE = 0, XDG_INVALID_SIZE = 5 };

static void copy_text(char *dst, const char *src) {
    snprintf(dst, TEXT, "%s", src ? src : "");
}

/* Tells a top-level window its size and whether it is in front. */
static void configure(mwm_server *s, client *c, xdg *x) {
    static const uint32_t activated = 4;
    mwm_put_begin(c->conn, x->toplevel, 0);
    mwm_put_int(c->conn, x->width);
    mwm_put_int(c->conn, x->height);
    mwm_put_array(c->conn, &activated, x->active ? sizeof activated : 0);
    mwm_put_end(c->conn);
    mwm_event_uint(c, x->id, 0, ++s->serial);
}

/* The window's role, when its program can still be told things. */
static xdg *toplevel_of(mwm_server *s, uint32_t window_id) {
    window *w = mwm_window_by_id(s, window_id);
    xdg *x = w && w->surface ? w->surface->xdg : NULL;
    return x && x->toplevel && x->configured && !w->surface->owner->dead ? x : NULL;
}

void mwm_server_resize(mwm_server *s, uint32_t window_id, int32_t width, int32_t height) {
    xdg *x = toplevel_of(s, window_id);
    if (!x || width < 1 || height < 1 || width > MWM_MAX_SIDE || height > MWM_MAX_SIDE) return;
    if (x->width == width && x->height == height) return;
    x->width = width;
    x->height = height;
    configure(s, x->surface->owner, x);
    mwm_flush(s);
}

void mwm_server_close(mwm_server *s, uint32_t window_id) {
    xdg *x = toplevel_of(s, window_id);
    if (!x) return;
    mwm_put_begin(x->surface->owner->conn, x->toplevel, 1);
    mwm_put_end(x->surface->owner->conn);
    mwm_flush(s);
}

void mwm_shell_commit(mwm_server *s, client *c, surface *f) {
    xdg *x = f->xdg;
    if (!x) return;
    if (x->geometry_waits) {
        x->geometry_waits = false;
        if (memcmp(&x->geometry, &x->next_geometry, sizeof x->geometry) != 0) {
            x->geometry = x->next_geometry;
            if (f->window) s->generation++;
        }
    }
    if (!x->toplevel || x->configured) return;
    configure(s, c, x); /* its first commit */
    x->configured = true;
}

void mwm_shell_activate(mwm_server *s, window *w, bool active) {
    xdg *x = w->used && w->surface ? w->surface->xdg : NULL;
    if (!x || !x->toplevel || !x->configured || x->active == active || w->surface->owner->dead) return;
    x->active = active;
    configure(s, w->surface->owner, x);
}

static void wm_base_request(client *c, mwm_msg *m) {
    if (m->opcode == 0) { /* destroy */
        mwm_del(c, m->object);
    } else if (m->opcode == 1) { /* create_positioner: kept, unused until there are popups */
        uint32_t id = mwm_get_uint(m);
        if (!m->bad) (void)mwm_add(c, id, T_POSITIONER, NULL);
    } else if (m->opcode == 2) { /* get_xdg_surface */
        uint32_t id = mwm_get_uint(m), surface_id = mwm_get_uint(m);
        if (m->bad) return;
        surface *f = mwm_find_as(c, surface_id, T_SURFACE);
        if (!f) {
            mwm_fail(c, m->object, E_INVALID_OBJECT, "not a surface");
            return;
        }
        if (f->xdg || f->sub || f->current) {
            mwm_fail(c, m->object, XDG_ROLE, "the surface has a role or a buffer already");
            return;
        }
        xdg *x = calloc(1, sizeof *x);
        if (!x) {
            mwm_fail(c, m->object, E_NO_MEMORY, "out of memory");
            return;
        }
        x->surface = f;
        x->id = id;
        if (!mwm_add(c, id, T_XDG_SURFACE, x)) {
            free(x);
            return;
        }
        f->xdg = x;
    } else if (m->opcode == 3) { /* pong */
        mwm_skip_arguments(m);
    } else {
        mwm_fail(c, m->object, E_INVALID_METHOD, "xdg_wm_base has no such request");
    }
}

static void xdg_surface_request(mwm_server *s, client *c, xdg *x, mwm_msg *m) {
    if (m->opcode == 0) { /* destroy: the window goes with its role */
        if (x->surface) {
            mwm_window_gone(s, x->surface->window);
            x->surface->xdg = NULL;
        }
        if (x->toplevel) mwm_del(c, x->toplevel);
        mwm_del(c, m->object);
        free(x);
    } else if (m->opcode == 1) { /* get_toplevel */
        uint32_t id = mwm_get_uint(m);
        if (m->bad) return;
        if (x->toplevel) {
            mwm_fail(c, m->object, XDG_ROLE, "it is a top-level window already");
            return;
        }
        if (mwm_add(c, id, T_TOPLEVEL, x)) x->toplevel = id;
    } else if (m->opcode == 2) { /* get_popup */
        mwm_fail(c, m->object, E_IMPLEMENTATION, "Monad's window manager has no popups yet");
    } else if (m->opcode == 3) { /* set_window_geometry: at the surface's next commit */
        int32_t gx = mwm_get_int(m), gy = mwm_get_int(m), width = mwm_get_int(m), height = mwm_get_int(m);
        if (m->bad) return;
        if (width <= 0 || height <= 0) {
            mwm_fail(c, m->object, XDG_INVALID_SIZE, "a window has a width and a height");
            return;
        }
        /* Kept within what a surface can be: they are multiplied by its scale later. */
        if (gx < -MWM_MAX_SIDE) gx = -MWM_MAX_SIDE;
        if (gy < -MWM_MAX_SIDE) gy = -MWM_MAX_SIDE;
        if (gx > MWM_MAX_SIDE) gx = MWM_MAX_SIDE;
        if (gy > MWM_MAX_SIDE) gy = MWM_MAX_SIDE;
        if (width > MWM_MAX_SIDE) width = MWM_MAX_SIDE;
        if (height > MWM_MAX_SIDE) height = MWM_MAX_SIDE;
        x->next_geometry = (box){gx, gy, gx + width, gy + height};
        x->geometry_waits = true;
    } else if (m->opcode == 4) { /* ack_configure */
        mwm_skip_arguments(m);
    } else {
        mwm_fail(c, m->object, E_INVALID_METHOD, "xdg_surface has no such request");
    }
}

static void toplevel_request(mwm_server *s, client *c, xdg *x, mwm_msg *m) {
    uint32_t len;
    if (m->opcode == 0) { /* destroy: no longer a window */
        if (x->surface) mwm_window_gone(s, x->surface->window);
        x->toplevel = 0;
        x->configured = false;
        x->active = false;
        x->width = x->height = 0;
        mwm_del(c, m->object);
    } else if (m->opcode == 2 || m->opcode == 3) { /* set_title, set_app_id */
        const char *text = mwm_get_string(m, &len);
        if (m->bad) return;
        char *field = m->opcode == 2 ? x->title : x->app_id;
        if (strncmp(field, text ? text : "", TEXT - 1) != 0) {
            copy_text(field, text);
            if (x->surface && x->surface->window) s->generation++;
        }
    } else if (m->opcode <= 13) { /* parent, menus, moves, sizes, states: the Mac's to decide, later */
        mwm_skip_arguments(m);
    } else {
        mwm_fail(c, m->object, E_INVALID_METHOD, "xdg_toplevel has no such request");
    }
}

/* Who draws a window's frame (zxdg_toplevel_decoration_v1): the Mac does,
 * whatever the program would rather. Told with a configure, as the mode
 * comes with one. */
static void decorate(mwm_server *s, client *c, uint32_t id, uint32_t toplevel) {
    enum { SERVER_SIDE = 2 };
    xdg *x = mwm_find_as(c, toplevel, T_TOPLEVEL);
    if (!x) return; /* the window went before its decoration object */
    mwm_event_uint(c, id, 0, SERVER_SIDE);
    if (x->configured) configure(s, c, x);
}

void mwm_shell_request(mwm_server *s, client *c, object *o, mwm_msg *m) {
    switch ((obj_type)o->type) {
    case T_DECORATION_MANAGER:
        if (m->opcode == 0) {
            mwm_del(c, m->object);
        } else if (m->opcode == 1) { /* get_toplevel_decoration */
            uint32_t id = mwm_get_uint(m), toplevel = mwm_get_uint(m);
            if (m->bad) return;
            if (!mwm_is(c, toplevel, T_TOPLEVEL)) {
                mwm_fail(c, m->object, E_INVALID_OBJECT, "not a top-level window");
                return;
            }
            /* Kept by the window's id, not its memory: the window may go first. */
            if (mwm_add(c, id, T_DECORATION, (void *)(uintptr_t)toplevel)) decorate(s, c, id, toplevel);
        } else {
            mwm_fail(c, m->object, E_INVALID_METHOD, "zxdg_decoration_manager_v1 has no such request");
        }
        break;
    case T_DECORATION: {
        uint32_t toplevel = (uint32_t)(uintptr_t)o->data;
        if (m->opcode == 0) {
            mwm_del(c, m->object);
        } else if (m->opcode == 1 || m->opcode == 2) { /* set_mode, unset_mode */
            if (m->opcode == 1) (void)mwm_get_uint(m);
            if (!m->bad) decorate(s, c, m->object, toplevel);
        } else {
            mwm_fail(c, m->object, E_INVALID_METHOD, "zxdg_toplevel_decoration_v1 has no such request");
        }
        break;
    }
    case T_WM_BASE:
        wm_base_request(c, m);
        break;
    case T_POSITIONER:
        if (m->opcode == 0) mwm_del(c, m->object);
        else mwm_skip_arguments(m);
        break;
    case T_XDG_SURFACE:
        xdg_surface_request(s, c, o->data, m);
        break;
    case T_TOPLEVEL:
        toplevel_request(s, c, o->data, m);
        break;
    default:
        break;
    }
}
