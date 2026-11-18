/*
 * mwm_surface.c — surfaces, and the windows made of them on the display.
 *
 * A window is one surface with the role of a window (mwm_shell.c) and the
 * subsurfaces on it, drawn in their order at the window's place. A place
 * is the size of the window's own surface; no two overlap, with a gap
 * between them, so the Mac can show each as a window of its own. What a
 * program drew stays in its buffers: the display is drawn from them
 * whenever something changes, and only where it changed.
 *
 * Memory a program handed over can go away under us (it can shrink the
 * file behind its pool): reading past its end raises SIGBUS. Drawing runs
 * between sigsetjmp and mwm_server_bus_error, which mwm_main.c's handler
 * calls, and a program whose memory went is dropped.
 */
#include "mwm_internal.h"

#include <setjmp.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>

enum { SURFACE_INVALID_SCALE = 0, SUBCOMPOSITOR_BAD_SURFACE = 0, SUBSURFACE_BAD_SURFACE = 0 };
/* Beyond any buffer there can be: sizes a program gives are cut to it before they are added up. */
enum { FAR = 1 << 20 };

static sigjmp_buf bus_jump;
static volatile sig_atomic_t bus_guarded;

void mwm_server_bus_error(void) {
    if (bus_guarded) siglongjmp(bus_jump, 1);
}

/* ------------------------------------------------------------------------ */
/* Rectangles                                                                */

static bool empty(box b) { return b.x2 <= b.x1 || b.y2 <= b.y1; }

static box both(box a, box b) {
    if (empty(a)) return b;
    if (empty(b)) return a;
    return (box){a.x1 < b.x1 ? a.x1 : b.x1, a.y1 < b.y1 ? a.y1 : b.y1, a.x2 > b.x2 ? a.x2 : b.x2, a.y2 > b.y2 ? a.y2 : b.y2};
}

static box common(box a, box b) {
    return (box){a.x1 > b.x1 ? a.x1 : b.x1, a.y1 > b.y1 ? a.y1 : b.y1, a.x2 < b.x2 ? a.x2 : b.x2, a.y2 < b.y2 ? a.y2 : b.y2};
}

static int32_t near(int64_t v) { return v < -FAR ? -FAR : v > FAR ? FAR : (int32_t)v; }

/* The rectangle a program gave as x, y, width, height. */
static box given(int32_t x, int32_t y, int32_t width, int32_t height) {
    return (box){near(x), near(y), near((int64_t)x + width), near((int64_t)y + height)};
}

/* ------------------------------------------------------------------------ */
/* The tree                                                                  */

/* The surface this one is, in the end, a part of; itself when it is none. */
static surface *root_of(surface *f) {
    for (int depth = 0; f->sub && f->sub->parent && depth < MAX_DEPTH; depth++) f = f->sub->parent;
    return f;
}

/* How many surfaces up `f` is a part of. */
static int depth_of(const surface *f) {
    int depth = 0;
    while (f->sub && f->sub->parent && depth <= MAX_DEPTH) {
        f = f->sub->parent;
        depth++;
    }
    return depth;
}

/* Whether its commits wait for a parent's: it, or a surface it is a part of, is synchronized. */
static bool waits(const surface *f) {
    for (int depth = 0; f->sub && depth <= MAX_DEPTH; depth++) {
        if (f->sub->sync) return true;
        if (!f->sub->parent) return false;
        f = f->sub->parent;
    }
    return false;
}

static int index_in(const surface *parent, const surface *f) {
    for (int i = 0; i < parent->stack_count; i++)
        if (parent->stack[i] == f) return i;
    return -1;
}

static void unstack(surface *parent, const surface *f) {
    int at = index_in(parent, f);
    if (at < 0) return;
    memmove(&parent->stack[at], &parent->stack[at + 1], (size_t)(parent->stack_count - at - 1) * sizeof parent->stack[0]);
    parent->stack_count--;
}

/* ------------------------------------------------------------------------ */
/* Drawing                                                                   */

static void present(mwm_server *s, int x, int y, int w, int h) {
    if (w > 0 && h > 0 && s->screen.present) s->screen.present(s->screen.ctx, x, y, w, h);
}

static void clear(mwm_server *s, int x, int y, int w, int h) {
    if (w <= 0 || h <= 0) return;
    for (int row = y; row < y + h; row++) memset(s->screen.pixels + (size_t)row * (size_t)s->screen.stride + x, 0, (size_t)w * 4);
    present(s, x, y, w, h);
}

/* One color over another, both with their own share already taken
 * (premultiplied). A program can give a color more than its share: no
 * part of the result is let past full. */
static uint32_t over(uint32_t src, uint32_t dst) {
    uint32_t rest = 255 - (src >> 24);
    uint32_t r = ((src >> 16) & 0xff) + (((dst >> 16) & 0xff) * rest + 127) / 255;
    uint32_t g = ((src >> 8) & 0xff) + (((dst >> 8) & 0xff) * rest + 127) / 255;
    uint32_t b = (src & 0xff) + ((dst & 0xff) * rest + 127) / 255;
    return 0xff000000u | (r > 255 ? 255 : r) << 16 | (g > 255 ? 255 : g) << 8 | (b > 255 ? 255 : b);
}

/* What shows where the window's own surface is see-through. */
typedef enum {
    /* Black: the window is all there on the display. */
    OPEN_BLACK,
    /* The colour of the program's own bar, which the Mac's window has behind it. */
    OPEN_BAR,
    /* Nothing: a popup, which the Mac shows in its shape (shape()). Its
     * edges, half there, are shown in their own colour: mixed with black
     * they would be a dark line around it. */
    OPEN_CUT,
} opening;

typedef struct {
    mwm_server *s;
    const window *w;
    /* What is being drawn again, in the window's pixels. */
    box area;
    /* The window's own surface is at the bottom: it can be copied as it is. */
    bool plain;
    opening open;
    /* What is under the window, for OPEN_BAR. */
    uint32_t under;
} painter;

/* Half and more of a pixel is of a popup's shape. */
enum { THERE = 128 };

/* A color with its share taken (premultiplied), whole. */
static uint32_t whole(uint32_t v) {
    uint32_t a = v >> 24;
    uint32_t r = (((v >> 16) & 0xff) * 255 + a / 2) / a, g = (((v >> 8) & 0xff) * 255 + a / 2) / a, b = ((v & 0xff) * 255 + a / 2) / a;
    return 0xff000000u | (r > 255 ? 255 : r) << 16 | (g > 255 ? 255 : g) << 8 | (b > 255 ? 255 : b);
}

/* One surface's buffer, its top left at (ox, oy) of the window. */
static void draw(const painter *p, const surface *f, int ox, int oy, bool bottom) {
    const buffer *b = f->current;
    if (!b) return;
    int scale = p->w->scale;
    int64_t width = (int64_t)b->width * scale / f->scale, height = (int64_t)b->height * scale / f->scale;
    box r = common(p->area, (box){near(ox), near(oy), near(ox + width), near(oy + height)});
    if (empty(r)) return;
    const uint8_t *pixels = b->pool->map + b->offset;
    bool mix = b->alpha && !bottom;
    opening open = b->alpha ? p->open : OPEN_BLACK;
    for (int y = r.y1; y < r.y2; y++) {
        uint32_t *dst = p->s->screen.pixels + (size_t)(p->w->y + y) * (size_t)p->s->screen.stride + p->w->x + r.x1;
        int sy = (int)((int64_t)(y - oy) * f->scale / scale);
        if (sy >= b->height) sy = b->height - 1;
        const uint8_t *row = pixels + (size_t)sy * (size_t)b->stride;
        for (int x = r.x1; x < r.x2; x++, dst++) {
            int sx = f->scale == scale ? x - ox : (int)((int64_t)(x - ox) * f->scale / scale);
            if (sx >= b->width) sx = b->width - 1;
            uint32_t v;
            memcpy(&v, row + (size_t)sx * 4, 4);
            if (mix) {
                if (v >> 24 == 0xff) *dst = v;
                else if (v >> 24 != 0) *dst = over(v, *dst);
            } else if (v >> 24 == 0xff || open == OPEN_BLACK) {
                *dst = v | 0xff000000u; /* a window is all there on the display */
            } else if (open == OPEN_BAR) {
                *dst = over(v, p->under);
            } else {
                *dst = v >> 24 >= THERE ? whole(v) : 0xff000000u;
            }
        }
    }
}

static void draw_tree(const painter *p, const surface *f, int ox, int oy, int depth) {
    if (depth > MAX_DEPTH) return;
    for (int i = 0; i < f->stack_count; i++) {
        const surface *e = f->stack[i];
        if (e == f) {
            draw(p, f, ox, oy, depth == 0 && p->plain);
        } else if (e->sub) {
            draw_tree(p, e, near((int64_t)ox + (int64_t)e->sub->x * p->w->scale), near((int64_t)oy + (int64_t)e->sub->y * p->w->scale),
                      depth + 1);
        }
    }
}

/* A popup's shape: of each row of its inner part, from where to where
 * the program drew something (half there and more). The Mac's window is
 * cut to it, so a menu's round corners and its arrow show what is behind
 * the menu. A whole rectangle, or a shape of more rows than are told,
 * is none. Reads the program's memory: inside paint()'s guard. */
static void shape(mwm_server *s, window *w) {
    mwm_band found[MWM_MAX_BANDS];
    int count = 0;
    const buffer *b = w->surface->current;
    if (b && b->alpha && w->surface->scale == w->scale && mwm_shell_parent(w)) {
        box inner = mwm_shell_inner(w);
        const uint8_t *pixels = b->pool->map + b->offset;
        for (int y = inner.y1; y < inner.y2; y++) {
            const uint8_t *row = pixels + (size_t)y * (size_t)b->stride;
            int x1 = inner.x1, x2 = inner.x2;
            uint32_t v;
            for (; x1 < x2; x1++) {
                memcpy(&v, row + (size_t)x1 * 4, 4);
                if (v >> 24 >= THERE) break;
            }
            for (; x2 > x1; x2--) {
                memcpy(&v, row + (size_t)(x2 - 1) * 4, 4);
                if (v >> 24 >= THERE) break;
            }
            mwm_band band = {1, (uint16_t)(x2 > x1 ? x1 - inner.x1 : 0), (uint16_t)(x2 - x1)};
            if (count > 0 && found[count - 1].x == band.x && found[count - 1].width == band.width) {
                found[count - 1].height++;
            } else if (count < MWM_MAX_BANDS) {
                found[count++] = band;
            } else {
                count = 0;
                break;
            }
        }
        if (count == 1 && found[0].width == inner.x2 - inner.x1) count = 0;
    }
    if (count == w->band_count && memcmp(found, w->bands, (size_t)count * sizeof found[0]) == 0) return;
    memcpy(w->bands, found, (size_t)count * sizeof found[0]);
    w->band_count = count;
    s->generation++;
}

/* Draws that part of the window again. False when the program's memory was gone. */
static bool paint(mwm_server *s, window *w, box area) {
    area = common(area, (box){0, 0, w->width, w->height});
    if (empty(area)) return true;
    painter p = {.s = s, .w = w, .area = area, .plain = w->surface->stack[0] == w->surface,
                 .open = mwm_shell_own_bar(w) ? OPEN_BAR : mwm_shell_parent(w) ? OPEN_CUT : OPEN_BLACK};
    p.under = p.open == OPEN_BAR ? 0xff000000u | w->bar_color : 0xff000000u;
    volatile bool ok = true;
    bus_guarded = 1;
    if (sigsetjmp(bus_jump, 1) == 0) {
        if (!p.plain) { /* something is under the window's own surface: start from what is under them all */
            for (int y = area.y1; y < area.y2; y++) {
                uint32_t *dst = s->screen.pixels + (size_t)(w->y + y) * (size_t)s->screen.stride + w->x + area.x1;
                for (int x = area.x1; x < area.x2; x++) *dst++ = p.under;
            }
        }
        draw_tree(&p, w->surface, 0, 0, 0);
        shape(s, w);
    } else {
        ok = false;
    }
    bus_guarded = 0;
    present(s, w->x + area.x1, w->y + area.y1, area.x2 - area.x1, area.y2 - area.y1);
    return ok;
}

/* ------------------------------------------------------------------------ */
/* Windows and their places                                                  */

window *mwm_window_by_id(mwm_server *s, uint32_t id) {
    for (int i = 0; id != 0 && i < MWM_MAX_WINDOWS; i++)
        if (s->windows[i].used && s->windows[i].id == id) return &s->windows[i];
    return NULL;
}

/* Whether a window of that size can stand there: on the display, and a gap away from every other. */
static bool is_free(const mwm_server *s, const window *self, int x, int y, int width, int height) {
    if (x < 0 || y < 0 || x + width > s->screen.width || y + height > s->screen.height) return false;
    for (int i = 0; i < MWM_MAX_WINDOWS; i++) {
        const window *o = &s->windows[i];
        if (!o->used || o == self) continue;
        if (x < o->x + o->width + MWM_GAP && o->x < x + width + MWM_GAP && y < o->y + o->height + MWM_GAP && o->y < y + height + MWM_GAP) {
            return false;
        }
    }
    return true;
}

/* The first free place for a window of that size, row by row from the top
 * left: beside or under the windows there are. False when there is none. */
static bool place(const mwm_server *s, const window *self, int width, int height, int *px, int *py) {
    bool found = false;
    for (int i = -1; i < MWM_MAX_WINDOWS; i++) {
        if (i >= 0 && (!s->windows[i].used || &s->windows[i] == self)) continue;
        int y = i < 0 ? 0 : s->windows[i].y + s->windows[i].height + MWM_GAP;
        if (found && y >= *py) continue;
        for (int k = -1; k < MWM_MAX_WINDOWS; k++) {
            if (k >= 0 && (!s->windows[k].used || &s->windows[k] == self)) continue;
            int x = k < 0 ? 0 : s->windows[k].x + s->windows[k].width + MWM_GAP;
            if (found && y == *py && x >= *px) continue;
            if (!is_free(s, self, x, y, width, height)) continue;
            if (!found || y < *py || (y == *py && x < *px)) {
                *px = x;
                *py = y;
                found = true;
            }
        }
    }
    return found;
}

void mwm_window_gone(mwm_server *s, window *w) {
    if (!w || !w->used) return;
    mwm_shell_window_going(s, w); /* its popups first */
    mwm_seat_window_gone(s, w);
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

/* The window comes, changes or goes with what its surface shows now.
 * True when all of it is to be drawn again (it is new, moved or changed size). */
static bool window_follows(mwm_server *s, surface *f) {
    buffer *b = f->current;
    const xdg *role = f->xdg;
    /* A window of a kind, told its size; a popup also on a window that is there. */
    bool shows = b && role && role->configured
                 && (role->toplevel || (role->popup && role->parent && role->parent->surface && role->parent->surface->window));
    if (!shows) {
        mwm_window_gone(s, f->window);
        return false;
    }
    window *w = f->window;
    int width = b->width < s->screen.width ? b->width : s->screen.width;
    int height = b->height < s->screen.height ? b->height : s->screen.height;
    if (!w) {
        int x, y;
        for (int i = 0; i < MWM_MAX_WINDOWS && !w; i++)
            if (!s->windows[i].used) w = &s->windows[i];
        if (!w || !place(s, NULL, width, height, &x, &y)) return false; /* as many as there may be, or no room: not shown */
        *w = (window){.used = true, .id = ++s->next_window, .x = x, .y = y, .width = width, .height = height, .scale = f->scale, .surface = f};
        f->window = w;
        s->order[s->window_count++] = (int)(w - s->windows);
        mwm_shell_window_new(s, w);
        s->generation++;
        return true;
    }
    if (width == w->width && height == w->height && f->scale == w->scale) return false;
    window before = *w;
    if (width != w->width || height != w->height) {
        /* Where it stands while it fits there, else a place of its own; with
         * none, what of it fits where it stands (never onto a neighbour). */
        int x, y;
        if (is_free(s, w, w->x, w->y, width, height)) {
            w->width = width;
            w->height = height;
        } else if (place(s, w, width, height, &x, &y)) {
            *w = (window){.used = true, .id = w->id, .x = x, .y = y, .width = width, .height = height, .surface = f};
        } else {
            w->width = width < w->width ? width : w->width;
            w->height = height < w->height ? height : w->height;
        }
    }
    w->scale = f->scale;
    if (before.x != w->x || before.y != w->y || before.width > w->width || before.height > w->height) {
        clear(s, before.x, before.y, before.width, before.height); /* what the old place or size left */
    }
    s->generation++;
    return true;
}

/* ------------------------------------------------------------------------ */
/* Commits                                                                   */

/* A frame callback that waits for the next frame, or is answered at once when no more can wait. */
static void frame_waits(mwm_server *s, client *c, surface *f, uint32_t id) {
    if (f->waiting_count < MAX_FRAMES) {
        f->frames_waiting[f->waiting_count++] = id;
        s->frames_waiting++;
    } else {
        mwm_event_uint(c, id, 0, s->frame_time);
        mwm_del(c, id);
    }
}

/* Makes a commit's state the surface's, and that of the parts waiting for
 * it. *all: the whole window is to be drawn again, not only what changed. */
static void apply(mwm_server *s, client *c, surface *f, state *st, bool *all, int depth) {
    for (int i = 0; i < st->frame_count; i++) frame_waits(s, c, f, st->frames[i]);
    if (st->scale != 0 && st->scale != f->scale) {
        f->scale = st->scale;
        *all = true;
    }
    if (st->attached) {
        buffer *old = f->current, *new = st->buffer;
        if (!old || !new || old->width != new->width || old->height != new->height) *all = true;
        f->current = new;
        if (new) new->shown++;
        mwm_buffer_unshown(old);
    }
    box units = st->surface_damage;
    if (!empty(units)) units = (box){units.x1 * f->scale, units.y1 * f->scale, units.x2 * f->scale, units.y2 * f->scale};
    f->dirty = both(f->dirty, both(st->damage, units));
    memset(st, 0, sizeof *st);
    if (depth >= MAX_DEPTH) return;
    for (int i = 0; i < f->stack_count; i++) {
        surface *e = f->stack[i];
        if (e == f || !e->sub) continue;
        if (e->sub->x != e->sub->next_x || e->sub->y != e->sub->next_y) {
            e->sub->x = e->sub->next_x;
            e->sub->y = e->sub->next_y;
            *all = true;
        }
        if (e->sub->has_cached) {
            e->sub->has_cached = false;
            apply(s, c, e, &e->sub->cached, all, depth + 1);
        }
    }
}

/* What changed in the tree and is not on the display yet, in the window's
 * pixels; the surfaces are then up to date. */
static box take_dirty(const window *w, surface *f, int ox, int oy, int depth) {
    box all = {0, 0, 0, 0};
    if (f->current && !empty(f->dirty)) {
        box d = common(f->dirty, (box){0, 0, f->current->width, f->current->height});
        if (!empty(d)) {
            /* Outward, when the window is drawn at another scale than this part. */
            all = (box){ox + (int32_t)((int64_t)d.x1 * w->scale / f->scale), oy + (int32_t)((int64_t)d.y1 * w->scale / f->scale),
                        ox + (int32_t)(((int64_t)d.x2 * w->scale + f->scale - 1) / f->scale),
                        oy + (int32_t)(((int64_t)d.y2 * w->scale + f->scale - 1) / f->scale)};
        }
    }
    f->dirty = (box){0, 0, 0, 0};
    for (int i = 0; depth < MAX_DEPTH && i < f->stack_count; i++) {
        surface *e = f->stack[i];
        if (e == f || !e->sub) continue;
        all = both(all, take_dirty(w, e, near((int64_t)ox + (int64_t)e->sub->x * w->scale), near((int64_t)oy + (int64_t)e->sub->y * w->scale),
                                   depth + 1));
    }
    return all;
}

/* The tree `f` is in changed: its window follows, and what changed is drawn. */
static void changed(mwm_server *s, surface *f, bool all) {
    surface *root = root_of(f);
    if (window_follows(s, root)) all = true;
    window *w = root->window;
    if (!w) return;
    box area = take_dirty(w, root, 0, 0, 0);
    if (all) area = (box){0, 0, w->width, w->height};
    bool ok = paint(s, w, area);
    /* Its bar changed colour: what it leaves open shows the new one (once; the colour is next looked at when it next draws). */
    if (ok && mwm_shell_painted(s, w) && root->current && root->current->alpha) ok = paint(s, w, (box){0, 0, w->width, w->height});
    if (!ok) mwm_fail(root->owner, root->id, E_IMPLEMENTATION, "the buffer's memory is gone");
}

/* A part's commit waits for its parent's: what it holds is added to what waits already. */
static void keep(mwm_server *s, client *c, surface *f) {
    state *from = &f->pending, *to = &f->sub->cached;
    if (from->attached) {
        to->buffer = from->buffer;
        to->attached = true;
    }
    to->damage = both(to->damage, from->damage);
    to->surface_damage = both(to->surface_damage, from->surface_damage);
    if (from->scale != 0) to->scale = from->scale;
    for (int i = 0; i < from->frame_count; i++) {
        if (to->frame_count < MAX_FRAMES) {
            to->frames[to->frame_count++] = from->frames[i];
        } else { /* more than can wait: answered at once rather than never */
            mwm_event_uint(c, from->frames[i], 0, s->frame_time);
            mwm_del(c, from->frames[i]);
        }
    }
    memset(from, 0, sizeof *from);
    f->sub->has_cached = true;
}

static void commit(mwm_server *s, client *c, surface *f) {
    mwm_shell_commit(s, c, f);
    if (f->sub && waits(f)) {
        keep(s, c, f);
        return;
    }
    bool all = false;
    apply(s, c, f, &f->pending, &all, depth_of(f));
    changed(s, f, all);
}

/* ------------------------------------------------------------------------ */
/* Surfaces that go                                                          */

static void forget_frames(client *c, state *st) {
    for (int i = 0; i < st->frame_count; i++) mwm_del(c, st->frames[i]);
    st->frame_count = 0;
}

/* The surface is no part of its parent any more, which is drawn without it. */
static void detach(mwm_server *s, surface *f) {
    subsurface *sub = f->sub;
    if (!sub) return;
    surface *parent = sub->parent;
    forget_frames(f->owner, &sub->cached);
    sub->surface = NULL;
    sub->parent = NULL;
    f->sub = NULL;
    if (!parent) return;
    unstack(parent, f);
    changed(s, parent, true);
}

void mwm_surface_destroy(mwm_server *s, client *c, surface *f, bool tell) {
    mwm_seat_surface_gone(s, f);
    mwm_window_gone(s, f->window);
    if (f->xdg) f->xdg->surface = NULL;
    /* Its parts show nowhere from now on. */
    for (int i = 0; i < f->stack_count; i++) {
        if (f->stack[i] != f && f->stack[i]->sub) f->stack[i]->sub->parent = NULL;
    }
    f->stack_count = 0;
    detach(s, f);
    mwm_buffer_unshown(f->current);
    forget_frames(c, &f->pending);
    for (int i = 0; i < f->waiting_count; i++) mwm_del(c, f->frames_waiting[i]);
    s->frames_waiting -= f->waiting_count;
    if (tell) mwm_del(c, f->id);
    free(f);
}

void mwm_surface_forget_buffer(client *c, const buffer *b) {
    for (uint32_t i = 0; i < c->object_cap; i++) {
        if (c->objects[i].type != T_SURFACE) continue;
        surface *f = c->objects[i].data;
        if (f->pending.buffer == b) f->pending.buffer = NULL;
        if (f->sub && f->sub->cached.buffer == b) f->sub->cached.buffer = NULL;
    }
}

/* ------------------------------------------------------------------------ */
/* Requests                                                                  */

static void surface_request(mwm_server *s, client *c, surface *f, mwm_msg *m) {
    switch (m->opcode) {
    case 0: /* destroy */
        mwm_surface_destroy(s, c, f, true);
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
        f->pending.buffer = b;
        f->pending.attached = true;
        break;
    }
    case 2: case 9: { /* damage (in the program's units), damage_buffer (in pixels) */
        int32_t x = mwm_get_int(m), y = mwm_get_int(m), width = mwm_get_int(m), height = mwm_get_int(m);
        if (m->bad) return;
        box *damage = m->opcode == 2 ? &f->pending.surface_damage : &f->pending.damage;
        if (width > 0 && height > 0) *damage = both(*damage, given(x, y, width, height));
        break;
    }
    case 3: { /* frame */
        uint32_t id = mwm_get_uint(m);
        if (m->bad) return;
        if (f->pending.frame_count == MAX_FRAMES) {
            mwm_fail(c, f->id, E_NO_MEMORY, "too many frame callbacks");
            return;
        }
        if (mwm_add(c, id, T_CALLBACK, NULL)) f->pending.frames[f->pending.frame_count++] = id;
        break;
    }
    case 6: /* commit */
        commit(s, c, f);
        break;
    case 8: { /* set_buffer_scale */
        int32_t scale = mwm_get_int(m);
        if (m->bad) return;
        if (scale < 1 || scale > MAX_SCALE) {
            mwm_fail(c, f->id, SURFACE_INVALID_SCALE, "no such scale");
            return;
        }
        f->pending.scale = scale;
        break;
    }
    case 4: case 5: case 7: /* regions (a window is all there, and all of it takes the pointer), transform */
        mwm_skip_arguments(m);
        break;
    default:
        mwm_fail(c, f->id, E_INVALID_METHOD, "wl_surface has no such request");
    }
}

static void get_subsurface(client *c, mwm_msg *m) {
    uint32_t id = mwm_get_uint(m), surface_id = mwm_get_uint(m), parent_id = mwm_get_uint(m);
    if (m->bad) return;
    surface *f = mwm_find_as(c, surface_id, T_SURFACE), *parent = mwm_find_as(c, parent_id, T_SURFACE);
    if (!f || !parent) {
        mwm_fail(c, m->object, E_INVALID_OBJECT, "not a surface");
        return;
    }
    if (f == parent || f->xdg || f->sub || root_of(parent) == f) {
        mwm_fail(c, m->object, SUBCOMPOSITOR_BAD_SURFACE, "the surface has a role already, or would be a part of itself");
        return;
    }
    if (depth_of(parent) + 1 >= MAX_DEPTH || parent->stack_count > MAX_CHILDREN) {
        mwm_fail(c, m->object, E_NO_MEMORY, "too many parts on a surface, or parts too deep in parts");
        return;
    }
    subsurface *sub = calloc(1, sizeof *sub);
    if (!sub) {
        mwm_fail(c, m->object, E_NO_MEMORY, "out of memory");
        return;
    }
    *sub = (subsurface){.surface = f, .parent = parent, .id = id, .sync = true};
    if (!mwm_add(c, id, T_SUBSURFACE, sub)) {
        free(sub);
        return;
    }
    f->sub = sub;
    parent->stack[parent->stack_count++] = f; /* on top; it shows at the parent's next commit */
}

static void subsurface_request(mwm_server *s, client *c, subsurface *sub, mwm_msg *m) {
    surface *f = sub->surface;
    switch (m->opcode) {
    case 0: /* destroy: the surface is a part of nothing, at once */
        if (f) detach(s, f);
        mwm_del(c, m->object);
        free(sub);
        break;
    case 1: { /* set_position: at the parent's next commit */
        int32_t x = mwm_get_int(m), y = mwm_get_int(m);
        if (m->bad) return;
        sub->next_x = near(x);
        sub->next_y = near(y);
        break;
    }
    case 2: case 3: { /* place_above, place_below: a sibling, or the parent itself */
        uint32_t id = mwm_get_uint(m);
        if (m->bad) return;
        surface *other = mwm_find_as(c, id, T_SURFACE);
        if (!f || !sub->parent) return; /* it shows nowhere: nothing to order */
        surface *parent = sub->parent;
        if (!other || other == f || index_in(parent, other) < 0) {
            mwm_fail(c, m->object, SUBSURFACE_BAD_SURFACE, "neither a sibling nor the parent");
            return;
        }
        unstack(parent, f);
        int at = index_in(parent, other) + (m->opcode == 2 ? 1 : 0);
        memmove(&parent->stack[at + 1], &parent->stack[at], (size_t)(parent->stack_count - at) * sizeof parent->stack[0]);
        parent->stack[at] = f;
        parent->stack_count++;
        parent->dirty = both(parent->dirty, (box){0, 0, FAR, FAR}); /* drawn again at the parent's next commit */
        break;
    }
    case 4: /* set_sync */
        sub->sync = true;
        break;
    case 5: /* set_desync: what waited for the parent takes effect, unless a parent of its own still waits */
        sub->sync = false;
        if (f && sub->has_cached && !waits(f)) {
            bool all = false;
            sub->has_cached = false;
            apply(s, c, f, &sub->cached, &all, depth_of(f));
            changed(s, f, all);
        }
        break;
    default:
        mwm_fail(c, m->object, E_INVALID_METHOD, "wl_subsurface has no such request");
    }
}

void mwm_surface_request(mwm_server *s, client *c, object *o, mwm_msg *m) {
    switch ((obj_type)o->type) {
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
            f->scale = 1;
            f->stack[0] = f;
            f->stack_count = 1;
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
    case T_REGION: /* nothing is cut by regions: only destroy means anything */
        if (m->opcode == 0) mwm_del(c, m->object);
        else if (m->opcode <= 2) mwm_skip_arguments(m);
        else mwm_fail(c, m->object, E_INVALID_METHOD, "wl_region has no such request");
        break;
    case T_SUBCOMPOSITOR:
        if (m->opcode == 0) mwm_del(c, m->object);
        else if (m->opcode == 1) get_subsurface(c, m);
        else mwm_fail(c, m->object, E_INVALID_METHOD, "wl_subcompositor has no such request");
        break;
    case T_SUBSURFACE:
        subsurface_request(s, c, o->data, m);
        break;
    default:
        break;
    }
}
