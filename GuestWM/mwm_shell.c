/*
 * mwm_shell.c — windows as programs ask for them: xdg_wm_base and its
 * xdg_surface, which is a top-level window (xdg_toplevel) or a popup on
 * another window (xdg_popup: a menu, a tooltip, a list that drops down),
 * and who draws a window's frame (xdg-decoration: the Mac).
 *
 * A surface with such a role is told its size at its first commit, and is
 * a window on the sheet once it has a buffer (mwm_surface.c gives it a
 * place and draws it). A popup has a place of its own like any window: it
 * is told to the Mac with the window it is on and where it stands on it,
 * and the Mac shows it there. Where it stands is the program's choice (its
 * positioner); it is not moved to fit a screen, which only the Mac knows.
 */
#include "mwm_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { WM_ROLE = 0, WM_INVALID_POPUP_PARENT = 3, WM_INVALID_POSITIONER = 5 };
enum { XDG_INVALID_SIZE = 5 };
enum { POSITIONER_INVALID_INPUT = 0 };
enum { POPUP_CONFIGURE = 0, POPUP_DONE = 1 };
/* Edges and corners, as anchors and gravities name them. */
enum { NONE = 0, TOP, BOTTOM, LEFT, RIGHT, TOP_LEFT, BOTTOM_LEFT, TOP_RIGHT, BOTTOM_RIGHT };
/* Menus of menus, as deep as any goes. */
enum { MAX_POPUP_DEPTH = 8 };

static void copy_text(char *dst, const char *src) {
    snprintf(dst, TEXT, "%s", src ? src : "");
}

/* Within what a surface can be: sums of these stay far from overflowing. */
static int32_t near(int64_t v) {
    enum { FAR = 1 << 20 };
    return v < -FAR ? -FAR : v > FAR ? FAR : (int32_t)v;
}

/* Tells a window its size: a top-level window also whether it is in
 * front, a popup also where it stands on its parent. */
static void configure(mwm_server *s, client *c, xdg *x) {
    /* Every edge meets the Mac's frame (tiled left, right, top, bottom): a
     * program that draws its own bar then draws no round corners and no
     * shadow, which the Mac's window has. Last, when it is in front: activated. */
    static const uint32_t states[] = {5, 6, 7, 8, 4};
    if (x->toplevel) {
        mwm_put_begin(c->conn, x->toplevel, 0);
        mwm_put_int(c->conn, x->width);
        mwm_put_int(c->conn, x->height);
        mwm_put_array(c->conn, states, x->active ? sizeof states : sizeof states - sizeof states[0]);
        mwm_put_end(c->conn);
    } else {
        mwm_put_begin(c->conn, x->popup, POPUP_CONFIGURE);
        mwm_put_int(c->conn, x->px);
        mwm_put_int(c->conn, x->py);
        mwm_put_int(c->conn, x->width);
        mwm_put_int(c->conn, x->height);
        mwm_put_end(c->conn);
    }
    mwm_event_uint(c, x->id, 0, ++s->serial);
}

/* The role of a window on the sheet; NULL when it has none left. */
static xdg *role_of(const window *w) { return w && w->used && w->surface ? w->surface->xdg : NULL; }

/* The window's role, when it is a top-level one whose program can still be told things. */
static xdg *toplevel_of(mwm_server *s, uint32_t window_id) {
    window *w = mwm_window_by_id(s, window_id);
    xdg *x = role_of(w);
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
    if ((!x->toplevel && !x->popup) || x->configured) return;
    configure(s, c, x); /* its first commit */
    x->configured = true;
}

void mwm_shell_activate(mwm_server *s, window *w, bool active) {
    xdg *x = role_of(w);
    if (!x || !x->toplevel || !x->configured || x->active == active || w->surface->owner->dead) return;
    x->active = active;
    configure(s, w->surface->owner, x);
}

/* ------------------------------------------------------------------------ */
/* Popups                                                                    */

window *mwm_shell_parent(const window *w) {
    const xdg *x = role_of(w);
    return x && x->popup && x->parent && x->parent->surface ? x->parent->surface->window : NULL;
}

/* How many windows down from `top` the window is (0: it is `top`); -1 when it is not on it at all. */
static int depth_under(const window *w, const window *top) {
    int depth = 0;
    for (; w && depth <= MAX_POPUP_DEPTH; w = mwm_shell_parent(w), depth++)
        if (w == top) return depth;
    return -1;
}

window *mwm_shell_grabbing(mwm_server *s, window *top) {
    window *deepest = NULL;
    int most = 0;
    for (int i = 0; i < MWM_MAX_WINDOWS; i++) {
        window *w = &s->windows[i];
        const xdg *x = role_of(w);
        int depth = x && x->popup && x->grab && !w->going ? depth_under(w, top) : -1;
        if (depth > most) {
            most = depth;
            deepest = w;
        }
    }
    return deepest;
}

void mwm_shell_window_new(mwm_server *s, window *w) {
    const xdg *x = role_of(w);
    if (!x || !x->popup || !x->grab) return;
    /* A menu takes the keys from the window it came from, when that one had them. */
    for (window *up = mwm_shell_parent(w); up; up = mwm_shell_parent(up)) {
        if (up == s->seat.keyboard) {
            mwm_seat_keyboard(s, w);
            return;
        }
    }
}

static void popup_done(xdg *x) {
    client *c = x->surface ? x->surface->owner : NULL;
    if (x->dismissed || !x->popup) return;
    x->dismissed = true;
    if (!c || c->dead) return;
    mwm_put_begin(c->conn, x->popup, POPUP_DONE);
    mwm_put_end(c->conn);
}

void mwm_shell_window_going(mwm_server *s, window *w) {
    w->going = true;
    /* Its popups go first, each told it is done with: a popup shows on nothing. */
    for (int i = 0; i < MWM_MAX_WINDOWS; i++) {
        window *child = &s->windows[i];
        if (!child->used || child->going || mwm_shell_parent(child) != w) continue;
        popup_done(role_of(child));
        mwm_window_gone(s, child);
        i = -1; /* the list changed under us: from the start */
    }
}

void mwm_server_dismiss(mwm_server *s, uint32_t window_id) {
    window *top = mwm_window_by_id(s, window_id);
    if (!top) return;
    for (;;) { /* the one on top first, as a program expects of its menus */
        window *deepest = NULL;
        int most = -1;
        for (int i = 0; i < MWM_MAX_WINDOWS; i++) {
            window *w = &s->windows[i];
            const xdg *x = role_of(w);
            int depth = x && x->popup && !x->dismissed ? depth_under(w, top) : -1;
            if (depth > most) {
                most = depth;
                deepest = w;
            }
        }
        if (!deepest) break;
        popup_done(role_of(deepest));
    }
    mwm_flush(s);
}

void mwm_shell_role_gone(client *c, xdg *x) {
    for (uint32_t i = 0; i < c->object_cap; i++) {
        if (c->objects[i].type != T_XDG_SURFACE) continue;
        xdg *other = c->objects[i].data;
        if (other->parent == x) other->parent = NULL;
    }
}

/* Where the popup stands on its parent: the point of the anchor rectangle
 * it hangs at, the way it grows from there, and its offset. */
static void stand(xdg *x, const positioner *p) {
    bool left = p->anchor == LEFT || p->anchor == TOP_LEFT || p->anchor == BOTTOM_LEFT;
    bool right = p->anchor == RIGHT || p->anchor == TOP_RIGHT || p->anchor == BOTTOM_RIGHT;
    bool top = p->anchor == TOP || p->anchor == TOP_LEFT || p->anchor == TOP_RIGHT;
    bool bottom = p->anchor == BOTTOM || p->anchor == BOTTOM_LEFT || p->anchor == BOTTOM_RIGHT;
    int64_t at_x = (int64_t)p->ax + (left ? 0 : right ? p->aw : p->aw / 2);
    int64_t at_y = (int64_t)p->ay + (top ? 0 : bottom ? p->ah : p->ah / 2);
    left = p->gravity == LEFT || p->gravity == TOP_LEFT || p->gravity == BOTTOM_LEFT;
    right = p->gravity == RIGHT || p->gravity == TOP_RIGHT || p->gravity == BOTTOM_RIGHT;
    top = p->gravity == TOP || p->gravity == TOP_LEFT || p->gravity == TOP_RIGHT;
    bottom = p->gravity == BOTTOM || p->gravity == BOTTOM_LEFT || p->gravity == BOTTOM_RIGHT;
    x->px = near(at_x - (left ? p->width : right ? 0 : p->width / 2) + p->ox);
    x->py = near(at_y - (top ? p->height : bottom ? 0 : p->height / 2) + p->oy);
    x->width = p->width;
    x->height = p->height;
}

static void positioner_request(client *c, positioner *p, mwm_msg *m) {
    switch (m->opcode) {
    case 0: /* destroy */
        mwm_del(c, m->object);
        free(p);
        break;
    case 1: { /* set_size */
        int32_t width = mwm_get_int(m), height = mwm_get_int(m);
        if (m->bad) return;
        if (width < 1 || height < 1) {
            mwm_fail(c, m->object, POSITIONER_INVALID_INPUT, "a popup has a width and a height");
            return;
        }
        p->width = width < MWM_MAX_SIDE ? width : MWM_MAX_SIDE;
        p->height = height < MWM_MAX_SIDE ? height : MWM_MAX_SIDE;
        break;
    }
    case 2: { /* set_anchor_rect */
        int32_t x = mwm_get_int(m), y = mwm_get_int(m), width = mwm_get_int(m), height = mwm_get_int(m);
        if (m->bad) return;
        if (width < 0 || height < 0) {
            mwm_fail(c, m->object, POSITIONER_INVALID_INPUT, "a rectangle has no negative size");
            return;
        }
        p->ax = near(x);
        p->ay = near(y);
        p->aw = near(width);
        p->ah = near(height);
        break;
    }
    case 3: case 4: { /* set_anchor, set_gravity */
        uint32_t edge = mwm_get_uint(m);
        if (m->bad) return;
        if (edge > BOTTOM_RIGHT) {
            mwm_fail(c, m->object, POSITIONER_INVALID_INPUT, "no such edge or corner");
            return;
        }
        if (m->opcode == 3) p->anchor = edge;
        else p->gravity = edge;
        break;
    }
    case 6: { /* set_offset */
        int32_t x = mwm_get_int(m), y = mwm_get_int(m);
        if (m->bad) return;
        p->ox = near(x);
        p->oy = near(y);
        break;
    }
    case 5: case 7: case 8: case 9: /* how to fit a screen, which only the Mac knows; and what a newer xdg_wm_base adds */
        mwm_skip_arguments(m);
        break;
    default:
        mwm_fail(c, m->object, E_INVALID_METHOD, "xdg_positioner has no such request");
    }
}

static void get_popup(client *c, xdg *x, mwm_msg *m) {
    uint32_t id = mwm_get_uint(m), parent_id = mwm_get_uint(m), positioner_id = mwm_get_uint(m);
    if (m->bad) return;
    if (x->toplevel || x->popup) {
        mwm_fail(c, m->object, WM_ROLE, "it is a window of another kind already");
        return;
    }
    xdg *parent = mwm_find_as(c, parent_id, T_XDG_SURFACE);
    if (!parent || parent == x) {
        mwm_fail(c, m->object, WM_INVALID_POPUP_PARENT, "a popup is on another window");
        return;
    }
    const positioner *p = mwm_find_as(c, positioner_id, T_POSITIONER);
    if (!p) {
        mwm_fail(c, m->object, E_INVALID_OBJECT, "not a positioner");
        return;
    }
    if (p->width < 1 || p->height < 1) {
        mwm_fail(c, m->object, WM_INVALID_POSITIONER, "the positioner says no size");
        return;
    }
    int depth = 1;
    for (const xdg *up = parent; up; up = up->parent) {
        if (up == x || ++depth > MAX_POPUP_DEPTH) {
            mwm_fail(c, m->object, E_NO_MEMORY, "popups too deep in popups");
            return;
        }
    }
    if (!mwm_add(c, id, T_POPUP, x)) return;
    x->popup = id;
    x->parent = parent;
    x->grab = x->dismissed = false;
    stand(x, p);
}

static void popup_request(mwm_server *s, client *c, xdg *x, mwm_msg *m) {
    if (m->opcode == 0) { /* destroy: no longer a window */
        if (x->surface) mwm_window_gone(s, x->surface->window);
        x->popup = 0;
        x->parent = NULL;
        x->configured = x->grab = x->dismissed = false;
        x->width = x->height = 0;
        mwm_del(c, m->object);
    } else if (m->opcode == 1) { /* grab: it takes the keys while it is up (a menu) */
        uint32_t seat = mwm_get_uint(m);
        (void)mwm_get_uint(m);
        if (m->bad) return;
        if (!mwm_is(c, seat, T_SEAT)) {
            mwm_fail(c, m->object, E_INVALID_OBJECT, "not a seat");
            return;
        }
        x->grab = true;
    } else if (m->opcode == 2) { /* reposition, of a newer xdg_wm_base than is offered */
        mwm_skip_arguments(m);
    } else {
        mwm_fail(c, m->object, E_INVALID_METHOD, "xdg_popup has no such request");
    }
}

/* ------------------------------------------------------------------------ */
/* Requests                                                                  */

static void wm_base_request(client *c, mwm_msg *m) {
    if (m->opcode == 0) { /* destroy */
        mwm_del(c, m->object);
    } else if (m->opcode == 1) { /* create_positioner */
        uint32_t id = mwm_get_uint(m);
        if (m->bad) return;
        positioner *p = calloc(1, sizeof *p);
        if (!p) {
            mwm_fail(c, m->object, E_NO_MEMORY, "out of memory");
            return;
        }
        if (!mwm_add(c, id, T_POSITIONER, p)) free(p);
    } else if (m->opcode == 2) { /* get_xdg_surface */
        uint32_t id = mwm_get_uint(m), surface_id = mwm_get_uint(m);
        if (m->bad) return;
        surface *f = mwm_find_as(c, surface_id, T_SURFACE);
        if (!f) {
            mwm_fail(c, m->object, E_INVALID_OBJECT, "not a surface");
            return;
        }
        if (f->xdg || f->sub || f->current) {
            mwm_fail(c, m->object, WM_ROLE, "the surface has a role or a buffer already");
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
        mwm_shell_role_gone(c, x);
        if (x->toplevel) mwm_del(c, x->toplevel);
        if (x->popup) mwm_del(c, x->popup);
        mwm_del(c, m->object);
        free(x);
    } else if (m->opcode == 1) { /* get_toplevel */
        uint32_t id = mwm_get_uint(m);
        if (m->bad) return;
        if (x->toplevel || x->popup) {
            mwm_fail(c, m->object, WM_ROLE, "it is a window of another kind already");
            return;
        }
        if (mwm_add(c, id, T_TOPLEVEL, x)) x->toplevel = id;
    } else if (m->opcode == 2) {
        get_popup(c, x, m);
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
        x->decorated = false;
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
    } else if (m->opcode == 5 || m->opcode == 9 || m->opcode == 10 || m->opcode == 13) {
        /* move (the user drags the bar the program drew), set_maximized and
         * unset_maximized (a double click on it), set_minimized: the Mac's
         * window is the one to do it, so the Mac is asked, when the user is
         * at that window. */
        mwm_skip_arguments(m);
        window *w = x->surface ? x->surface->window : NULL;
        if (!w || !s->asked || (s->seat.pointer != w && s->seat.keyboard != w && s->seat.wanted != w->id)) return;
        s->asked(s->asked_ctx, w->id, m->opcode == 5 ? MWM_ASK_MOVE : m->opcode == 9 ? MWM_ASK_ZOOM
                                      : m->opcode == 10 ? MWM_ASK_UNZOOM : MWM_ASK_MINIMIZE);
    } else if (m->opcode <= 13) { /* parent, its own menu, resizing by its own edge, sizes, full screen: not the Mac's to do for it */
        mwm_skip_arguments(m);
    } else {
        mwm_fail(c, m->object, E_INVALID_METHOD, "xdg_toplevel has no such request");
    }
}

void mwm_server_on_ask(mwm_server *s, mwm_asked asked, void *ctx) {
    s->asked = asked;
    s->asked_ctx = ctx;
}

/* ------------------------------------------------------------------------ */
/* Who draws a window's title bar                                            */

enum { KDE_NONE = 0, KDE_CLIENT = 1, KDE_SERVER = 2 };

bool mwm_shell_own_bar(const window *w) {
    const xdg *x = role_of(w);
    return x && x->toplevel && !x->decorated && w->surface->kde_mode != KDE_SERVER;
}

box mwm_shell_inner(const window *w) {
    const xdg *x = role_of(w);
    box inner = {0, 0, w->width, w->height};
    if (x && x->geometry.x2 > x->geometry.x1 && x->geometry.y2 > x->geometry.y1) {
        box g = {x->geometry.x1 * w->scale, x->geometry.y1 * w->scale, x->geometry.x2 * w->scale, x->geometry.y2 * w->scale};
        if (g.x1 < 0) g.x1 = 0;
        if (g.y1 < 0) g.y1 = 0;
        if (g.x2 > w->width) g.x2 = w->width;
        if (g.y2 > w->height) g.y2 = w->height;
        if (g.x2 > g.x1 && g.y2 > g.y1) inner = g;
    }
    return inner;
}

/* The colour of the program's own bar: what it drew at the middle of the
 * window's top edge, a little down (its corners may be round). The Mac's
 * title bar above takes it, so the two read as one. */
void mwm_shell_painted(mwm_server *s, window *w) {
    box inner = mwm_shell_inner(w);
    int x = w->x + (inner.x1 + inner.x2) / 2, y = w->y + inner.y1 + 2 * w->scale;
    if (y >= w->y + inner.y2) y = w->y + inner.y2 - 1;
    if (x < 0 || y < 0 || x >= s->screen.width || y >= s->screen.height) return;
    uint32_t pixel = s->screen.pixels[(size_t)y * (size_t)s->screen.stride + (size_t)x], color = pixel & 0x00ffffff;
    if (pixel >> 24 != 0xff || color == w->bar_color) return; /* a see-through pixel is no colour: the one last seen stays */
    w->bar_color = color;
    if (mwm_shell_own_bar(w)) s->generation++;
}

/* The program's word on its frame changed: the Mac is told when its window is there. */
static void frame_changed(mwm_server *s, const surface *f) {
    if (f && f->window) s->generation++;
}

/* Who draws a window's frame (zxdg_toplevel_decoration_v1): the Mac does,
 * whatever the program would rather. Told with a configure, as the mode
 * comes with one. */
static void decorate(mwm_server *s, client *c, uint32_t id, uint32_t toplevel) {
    enum { SERVER_SIDE = 2 };
    xdg *x = mwm_find_as(c, toplevel, T_TOPLEVEL);
    if (!x) return; /* the window went before its decoration object */
    if (!x->decorated) frame_changed(s, x->surface);
    x->decorated = true;
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
        if (m->opcode == 0) { /* destroy: the program is on its own with its frame again */
            xdg *x = mwm_find_as(c, toplevel, T_TOPLEVEL);
            if (x && x->decorated) {
                x->decorated = false;
                frame_changed(s, x->surface);
            }
            mwm_del(c, m->object);
        } else if (m->opcode == 1 || m->opcode == 2) { /* set_mode, unset_mode */
            if (m->opcode == 1) (void)mwm_get_uint(m);
            if (!m->bad) decorate(s, c, m->object, toplevel);
        } else {
            mwm_fail(c, m->object, E_INVALID_METHOD, "zxdg_toplevel_decoration_v1 has no such request");
        }
        break;
    }
    /* org_kde_kwin_server_decoration: how GTK asks. A window with a header
     * bar says it draws its frame, and is let; a plain one leaves the frame
     * to the server, and then draws no title bar under the Mac's. */
    case T_KDE_DECORATION_MANAGER:
        if (m->opcode == 0) { /* create, for a surface */
            uint32_t id = mwm_get_uint(m), surface_id = mwm_get_uint(m);
            if (m->bad) return;
            if (!mwm_is(c, surface_id, T_SURFACE)) {
                mwm_fail(c, m->object, E_INVALID_OBJECT, "not a surface");
                return;
            }
            /* Kept by the surface's id, not its memory: the surface may go first.
             * Until it says otherwise, its frame is the server's, as it is told. */
            if (!mwm_add(c, id, T_KDE_DECORATION, (void *)(uintptr_t)surface_id)) return;
            surface *f = mwm_find_as(c, surface_id, T_SURFACE);
            if (f && f->kde_mode != KDE_SERVER) {
                f->kde_mode = KDE_SERVER;
                frame_changed(s, f);
            }
            mwm_event_uint(c, id, 0, KDE_SERVER);
        } else {
            mwm_fail(c, m->object, E_INVALID_METHOD, "org_kde_kwin_server_decoration_manager has no such request");
        }
        break;
    case T_KDE_DECORATION: {
        surface *f = mwm_find_as(c, (uint32_t)(uintptr_t)o->data, T_SURFACE);
        if (m->opcode == 0) { /* release */
            mwm_del(c, m->object);
        } else if (m->opcode == 1) { /* request_mode */
            uint32_t mode = mwm_get_uint(m);
            if (m->bad || mode > KDE_SERVER) return; /* no mode there is: as it was */
            if (f && f->kde_mode != mode) {
                f->kde_mode = (uint8_t)mode;
                frame_changed(s, f);
            }
            mwm_event_uint(c, m->object, 0, mode);
        } else {
            mwm_fail(c, m->object, E_INVALID_METHOD, "org_kde_kwin_server_decoration has no such request");
        }
        break;
    }
    case T_WM_BASE:
        wm_base_request(c, m);
        break;
    case T_POSITIONER:
        positioner_request(c, o->data, m);
        break;
    case T_XDG_SURFACE:
        xdg_surface_request(s, c, o->data, m);
        break;
    case T_TOPLEVEL:
        toplevel_request(s, c, o->data, m);
        break;
    case T_POPUP:
        popup_request(s, c, o->data, m);
        break;
    default:
        break;
    }
}
