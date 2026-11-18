/*
 * mwm_seat.c — the pointer and the keyboard, as programs hear of them
 * (wl_seat, wl_pointer, wl_keyboard).
 *
 * Neither is read from the VM's own devices: the Mac has them, and says
 * which window the pointer is over and which one is in front
 * (mwm_server_pointer, mwm_server_focus, ...). Only the program owning
 * that window is told anything, so what is typed into one window is not
 * another program's to read.
 */
#include "mwm_internal.h"

#include "mwm_keymap.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { SEAT_MISSING_CAPABILITY = 0 };
enum { CAPABILITY_POINTER = 1, CAPABILITY_KEYBOARD = 2 };
enum { POINTER_ENTER = 0, POINTER_LEAVE, POINTER_MOTION, POINTER_BUTTON, POINTER_AXIS, POINTER_FRAME, POINTER_AXIS_SOURCE };
enum { KEYBOARD_KEYMAP = 0, KEYBOARD_ENTER, KEYBOARD_LEAVE, KEYBOARD_KEY, KEYBOARD_MODIFIERS, KEYBOARD_REPEAT };
enum { AXIS_VERTICAL = 0, AXIS_HORIZONTAL = 1, SOURCE_CONTINUOUS = 2 };
/* Keys repeat as on a Mac left as it came: 30 a second, after 400 ms. */
enum { REPEAT_RATE = 30, REPEAT_DELAY = 400 };

/* The program a window is of, when it can still be told things. */
static client *owner(const window *w) {
    if (!w || !w->used || !w->surface) return NULL;
    client *c = w->surface->owner;
    return c->dead ? NULL : c;
}

/* The program's next object of that kind after `id`; 0 when there is none. */
static uint32_t next_of(const client *c, obj_type type, uint32_t id) {
    for (id++; id < c->object_cap; id++)
        if (c->objects[id].type == type) return id;
    return 0;
}

/* ------------------------------------------------------------------------ */
/* The pointer                                                               */

static void pointer_frame(client *c, uint32_t id) {
    if (c->objects[id].version < 5) return;
    mwm_put_begin(c->conn, id, POINTER_FRAME);
    mwm_put_end(c->conn);
}

static void pointer_enter(mwm_server *s, client *c, uint32_t id, uint32_t serial) {
    mwm_put_begin(c->conn, id, POINTER_ENTER);
    mwm_put_uint(c->conn, serial);
    mwm_put_uint(c->conn, s->seat.pointer->surface->id);
    mwm_put_int(c->conn, s->seat.x);
    mwm_put_int(c->conn, s->seat.y);
    mwm_put_end(c->conn);
    pointer_frame(c, id);
}

/* The pointer is over no window now; its program is told when `tell`. */
static void pointer_leave(mwm_server *s, bool tell) {
    client *c = owner(s->seat.pointer);
    if (c && tell) {
        uint32_t serial = ++s->serial;
        for (uint32_t id = 0; (id = next_of(c, T_POINTER, id)) != 0;) {
            mwm_put_begin(c->conn, id, POINTER_LEAVE);
            mwm_put_uint(c->conn, serial);
            mwm_put_uint(c->conn, s->seat.pointer->surface->id);
            mwm_put_end(c->conn);
            pointer_frame(c, id);
        }
    }
    s->seat.pointer = NULL;
    s->seat.cursor = MWM_CURSOR_DEFAULT; /* over nothing, and over the next window until its program says */
}

void mwm_server_pointer(mwm_server *s, uint32_t window_id, int32_t x, int32_t y, uint32_t time_ms) {
    window *w = mwm_window_by_id(s, window_id);
    if (w != s->seat.pointer) {
        pointer_leave(s, true);
        s->seat.pointer = w;
        s->seat.x = x;
        s->seat.y = y;
        client *c = owner(w);
        if (c) {
            uint32_t serial = ++s->serial;
            for (uint32_t id = 0; (id = next_of(c, T_POINTER, id)) != 0;) pointer_enter(s, c, id, serial);
        }
    } else if (w) {
        s->seat.x = x;
        s->seat.y = y;
        client *c = owner(w);
        for (uint32_t id = 0; c && (id = next_of(c, T_POINTER, id)) != 0;) {
            mwm_put_begin(c->conn, id, POINTER_MOTION);
            mwm_put_uint(c->conn, time_ms);
            mwm_put_int(c->conn, x);
            mwm_put_int(c->conn, y);
            mwm_put_end(c->conn);
            pointer_frame(c, id);
        }
    }
    mwm_flush(s);
}

void mwm_server_button(mwm_server *s, uint32_t button, bool pressed, uint32_t time_ms) {
    client *c = owner(s->seat.pointer);
    if (!c) return;
    uint32_t serial = ++s->serial;
    for (uint32_t id = 0; (id = next_of(c, T_POINTER, id)) != 0;) {
        mwm_put_begin(c->conn, id, POINTER_BUTTON);
        mwm_put_uint(c->conn, serial);
        mwm_put_uint(c->conn, time_ms);
        mwm_put_uint(c->conn, button);
        mwm_put_uint(c->conn, pressed ? 1 : 0);
        mwm_put_end(c->conn);
        pointer_frame(c, id);
    }
    mwm_flush(s);
}

static void pointer_axis(client *c, uint32_t id, uint32_t time_ms, uint32_t axis, int32_t value) {
    if (value == 0) return;
    mwm_put_begin(c->conn, id, POINTER_AXIS);
    mwm_put_uint(c->conn, time_ms);
    mwm_put_uint(c->conn, axis);
    mwm_put_int(c->conn, value);
    mwm_put_end(c->conn);
}

void mwm_server_scroll(mwm_server *s, int32_t dx, int32_t dy, uint32_t time_ms) {
    client *c = owner(s->seat.pointer);
    if (!c || (dx == 0 && dy == 0)) return;
    for (uint32_t id = 0; (id = next_of(c, T_POINTER, id)) != 0;) {
        /* The Mac scrolls by pixels, and goes on by itself after the fingers left. */
        if (c->objects[id].version >= 5) mwm_event_uint(c, id, POINTER_AXIS_SOURCE, SOURCE_CONTINUOUS);
        pointer_axis(c, id, time_ms, AXIS_VERTICAL, dy);
        pointer_axis(c, id, time_ms, AXIS_HORIZONTAL, dx);
        pointer_frame(c, id);
    }
    mwm_flush(s);
}

/* ------------------------------------------------------------------------ */
/* The keyboard                                                              */

static void keyboard_modifiers(mwm_server *s, client *c, uint32_t id, uint32_t serial) {
    mwm_put_begin(c->conn, id, KEYBOARD_MODIFIERS);
    mwm_put_uint(c->conn, serial);
    mwm_put_uint(c->conn, s->seat.depressed);
    mwm_put_uint(c->conn, 0); /* latched: the Mac has no such keys */
    mwm_put_uint(c->conn, s->seat.locked);
    mwm_put_uint(c->conn, 0); /* one layout: the Mac's */
    mwm_put_end(c->conn);
}

static void keyboard_enter(mwm_server *s, client *c, uint32_t id, uint32_t serial) {
    mwm_put_begin(c->conn, id, KEYBOARD_ENTER);
    mwm_put_uint(c->conn, serial);
    mwm_put_uint(c->conn, s->seat.keyboard->surface->id);
    mwm_put_array(c->conn, s->seat.held, (uint32_t)s->seat.held_count * 4);
    mwm_put_end(c->conn);
    keyboard_modifiers(s, c, id, serial);
}

static void keyboard_keymap(mwm_server *s, client *c, uint32_t id) {
    mwm_put_begin(c->conn, id, KEYBOARD_KEYMAP);
    mwm_put_uint(c->conn, 1); /* xkb_v1 */
    mwm_put_fd(c->conn, s->seat.keymap_fd);
    mwm_put_uint(c->conn, s->seat.keymap_size);
    mwm_put_end(c->conn);
}

/* No window is in front now; the program of the one that was is told when `tell`. */
static void keyboard_leave(mwm_server *s, bool tell) {
    window *w = s->seat.keyboard;
    client *c = owner(w);
    if (c && tell) {
        uint32_t serial = ++s->serial;
        for (uint32_t id = 0; (id = next_of(c, T_KEYBOARD, id)) != 0;) {
            mwm_put_begin(c->conn, id, KEYBOARD_LEAVE);
            mwm_put_uint(c->conn, serial);
            mwm_put_uint(c->conn, w->surface->id);
            mwm_put_end(c->conn);
        }
    }
    s->seat.keyboard = NULL;
}

void mwm_seat_keyboard(mwm_server *s, window *w) {
    if (w == s->seat.keyboard) return;
    keyboard_leave(s, true);
    s->seat.keyboard = w;
    client *c = owner(w);
    if (!c) return;
    mwm_data_focus(s, c); /* what a paste would give it, before the keys are its own (as Wayland has it) */
    uint32_t serial = ++s->serial;
    for (uint32_t id = 0; (id = next_of(c, T_KEYBOARD, id)) != 0;) keyboard_enter(s, c, id, serial);
}

void mwm_server_focus(mwm_server *s, uint32_t window_id) {
    window *w = mwm_window_by_id(s, window_id);
    /* A popup is no window to be in front: the window it is on is. */
    for (window *up; w && (up = mwm_shell_parent(w)) != NULL;) w = up;
    uint32_t id = w ? w->id : 0;
    if (id == s->seat.wanted) return;
    window *old = mwm_window_by_id(s, s->seat.wanted);
    keyboard_leave(s, true);
    if (old) mwm_shell_activate(s, old, false);
    s->seat.wanted = id;
    if (w) {
        mwm_shell_activate(s, w, true);
        /* A menu of its that took the keys still has them. */
        window *menu = mwm_shell_grabbing(s, w);
        mwm_seat_keyboard(s, menu ? menu : w);
    }
    mwm_flush(s);
}

void mwm_server_key(mwm_server *s, uint32_t key, bool pressed, uint32_t time_ms) {
    int at = -1;
    for (int i = 0; i < s->seat.held_count; i++)
        if (s->seat.held[i] == key) at = i;
    /* A key goes down once and comes up once; one more than can be held is not a key. */
    if (pressed ? (at >= 0 || s->seat.held_count == MAX_HELD) : at < 0) return;
    if (pressed) {
        s->seat.held[s->seat.held_count++] = key;
    } else {
        memmove(&s->seat.held[at], &s->seat.held[at + 1], (size_t)(s->seat.held_count - at - 1) * sizeof(uint32_t));
        s->seat.held_count--;
    }
    client *c = owner(s->seat.keyboard);
    if (!c) return;
    uint32_t serial = ++s->serial;
    for (uint32_t id = 0; (id = next_of(c, T_KEYBOARD, id)) != 0;) {
        mwm_put_begin(c->conn, id, KEYBOARD_KEY);
        mwm_put_uint(c->conn, serial);
        mwm_put_uint(c->conn, time_ms);
        mwm_put_uint(c->conn, key);
        mwm_put_uint(c->conn, pressed ? 1 : 0);
        mwm_put_end(c->conn);
    }
    mwm_flush(s);
}

void mwm_server_modifiers(mwm_server *s, uint32_t depressed, uint32_t locked) {
    if (depressed == s->seat.depressed && locked == s->seat.locked) return;
    s->seat.depressed = depressed;
    s->seat.locked = locked;
    client *c = owner(s->seat.keyboard);
    if (!c) return;
    uint32_t serial = ++s->serial;
    for (uint32_t id = 0; (id = next_of(c, T_KEYBOARD, id)) != 0;) keyboard_modifiers(s, c, id, serial);
    mwm_flush(s);
}

/* ------------------------------------------------------------------------ */
/* The keymap                                                                */

/* The text as a file to hand out: opened for reading only, so that no
 * program can write what the others then read as their keyboard. */
static int keymap_file(const char *text, size_t size) {
    const char *dir = getenv("XDG_RUNTIME_DIR");
    char path[256];
    if (snprintf(path, sizeof path, "%s/monad-wm-keymap-XXXXXX", dir && dir[0] == '/' ? dir : "/tmp") >= (int)sizeof path) return -1;
    int fd = mkstemp(path);
    if (fd < 0) return -1;
    int reading = open(path, O_RDONLY | O_CLOEXEC);
    unlink(path);
    size_t done = 0;
    while (reading >= 0 && done < size) {
        ssize_t n = write(fd, text + done, size - done);
        if (n <= 0) {
            close(reading);
            reading = -1;
        } else {
            done += (size_t)n;
        }
    }
    close(fd);
    return reading;
}

bool mwm_server_keymap(mwm_server *s, const mwm_key *keys, int count) {
    size_t size;
    char *text = mwm_keymap_text(keys, count, &size);
    if (!text) return false;
    int fd = keymap_file(text, size);
    free(text);
    if (fd < 0) return false;
    if (s->seat.keymap_fd >= 0) close(s->seat.keymap_fd);
    s->seat.keymap_fd = fd;
    s->seat.keymap_size = (uint32_t)size;
    for (int i = 0; i < MWM_MAX_CLIENTS; i++) {
        client *c = s->clients[i];
        if (!c || c->dead) continue;
        for (uint32_t id = 0; (id = next_of(c, T_KEYBOARD, id)) != 0;) keyboard_keymap(s, c, id);
    }
    mwm_flush(s);
    return true;
}

bool mwm_seat_init(mwm_server *s) {
    int count;
    const mwm_key *keys = mwm_keymap_us(&count);
    s->seat.keymap_fd = -1;
    s->seat.cursor = MWM_CURSOR_DEFAULT;
    return mwm_server_keymap(s, keys, count);
}

void mwm_seat_free(mwm_server *s) {
    if (s->seat.keymap_fd >= 0) close(s->seat.keymap_fd);
    s->seat.keymap_fd = -1;
}

/* ------------------------------------------------------------------------ */
/* Requests                                                                  */

void mwm_seat_bound(client *c, uint32_t id) {
    mwm_event_uint(c, id, 0, CAPABILITY_POINTER | CAPABILITY_KEYBOARD);
    if (c->objects[id].version >= 2) {
        mwm_put_begin(c->conn, id, 1); /* name */
        mwm_put_string(c->conn, "seat0");
        mwm_put_end(c->conn);
    }
}

static void seat_request(mwm_server *s, client *c, object *o, mwm_msg *m) {
    uint8_t version = o->version; /* `o` may move when an object is added */
    if (m->opcode == 0 || m->opcode == 1) { /* get_pointer, get_keyboard */
        uint32_t id = mwm_get_uint(m);
        if (m->bad || !mwm_add(c, id, m->opcode == 0 ? T_POINTER : T_KEYBOARD, NULL)) return;
        c->objects[id].version = version;
        if (m->opcode == 0) {
            if (owner(s->seat.pointer) == c) pointer_enter(s, c, id, ++s->serial);
            return;
        }
        keyboard_keymap(s, c, id);
        if (version >= 4) {
            mwm_put_begin(c->conn, id, KEYBOARD_REPEAT);
            mwm_put_int(c->conn, REPEAT_RATE);
            mwm_put_int(c->conn, REPEAT_DELAY);
            mwm_put_end(c->conn);
        }
        if (owner(s->seat.keyboard) == c) keyboard_enter(s, c, id, ++s->serial);
    } else if (m->opcode == 2) { /* get_touch */
        mwm_fail(c, m->object, SEAT_MISSING_CAPABILITY, "the seat has no touch screen");
    } else if (m->opcode == 3 && version >= 5) { /* release */
        mwm_del(c, m->object);
    } else {
        mwm_fail(c, m->object, E_INVALID_METHOD, "wl_seat has no such request");
    }
}

void mwm_seat_request(mwm_server *s, client *c, object *o, mwm_msg *m) {
    switch ((obj_type)o->type) {
    case T_SEAT:
        seat_request(s, c, o, m);
        break;
    case T_POINTER:
        if (m->opcode == 0) { /* set_cursor: no surface hides the pointer; a picture of the program's own the Mac does not draw */
            (void)mwm_get_uint(m);
            uint32_t surface_id = mwm_get_uint(m);
            (void)mwm_get_int(m);
            (void)mwm_get_int(m);
            if (m->bad) return;
            if (surface_id != 0 && !mwm_find_as(c, surface_id, T_SURFACE)) {
                mwm_fail(c, m->object, E_INVALID_OBJECT, "not a surface");
            } else if (owner(s->seat.pointer) == c) {
                s->seat.cursor = surface_id == 0 ? MWM_CURSOR_HIDDEN : MWM_CURSOR_DEFAULT;
            }
        } else if (m->opcode == 1 && o->version >= 3) { /* release */
            mwm_del(c, m->object);
        } else {
            mwm_fail(c, m->object, E_INVALID_METHOD, "wl_pointer has no such request");
        }
        break;
    case T_KEYBOARD:
        if (m->opcode == 0 && o->version >= 3) mwm_del(c, m->object); /* release */
        else mwm_fail(c, m->object, E_INVALID_METHOD, "wl_keyboard has no such request");
        break;
    case T_SHAPE_MANAGER: /* wp_cursor_shape_manager_v1 */
        if (m->opcode == 0) {
            mwm_del(c, m->object);
        } else if (m->opcode == 1) { /* get_pointer */
            uint32_t id = mwm_get_uint(m), pointer = mwm_get_uint(m);
            uint8_t version = o->version; /* read now: a new object may move them all */
            if (m->bad) return;
            if (!mwm_is(c, pointer, T_POINTER)) {
                mwm_fail(c, m->object, E_INVALID_OBJECT, "not a pointer");
            } else if (mwm_add(c, id, T_SHAPE_DEVICE, NULL)) {
                c->objects[id].version = version;
            }
        } else { /* a tablet's pen: there is none */
            mwm_fail(c, m->object, E_INVALID_METHOD, "wp_cursor_shape_manager_v1 has no such request");
        }
        break;
    case T_SHAPE_DEVICE: /* wp_cursor_shape_device_v1 */
        if (m->opcode == 0) {
            mwm_del(c, m->object);
        } else if (m->opcode == 1) { /* set_shape: how the pointer is to look, by name */
            (void)mwm_get_uint(m);
            uint32_t shape = mwm_get_uint(m);
            if (m->bad) return;
            /* The first list of shapes ends at zoom_out (34); the second has two more. */
            if (shape < MWM_CURSOR_DEFAULT || shape > (o->version >= 2 ? MWM_CURSOR_LAST : 34)) {
                mwm_fail(c, m->object, 1, "no such cursor shape");
            } else if (owner(s->seat.pointer) == c) { /* only where the pointer is over a window of its own */
                s->seat.cursor = (int)shape;
            }
        } else {
            mwm_fail(c, m->object, E_INVALID_METHOD, "wp_cursor_shape_device_v1 has no such request");
        }
        break;
    default:
        break;
    }
}

/* ------------------------------------------------------------------------ */
/* Windows and surfaces that go                                              */

void mwm_seat_window_gone(mwm_server *s, window *w) {
    if (s->seat.pointer == w) pointer_leave(s, true);
    bool had = s->seat.keyboard == w;
    if (had) keyboard_leave(s, true);
    if (s->seat.wanted == w->id) { /* the window in front went: none is, until the Mac says */
        s->seat.wanted = 0;
        if (w->surface && w->surface->xdg) w->surface->xdg->active = false;
    } else if (had) {
        /* A menu went: the keys go back to what had them before it, the menu under it or its window. */
        for (window *up = mwm_shell_parent(w); up; up = mwm_shell_parent(up)) {
            const xdg *x = up->surface ? up->surface->xdg : NULL;
            if (up->going || !x || !(x->popup ? x->grab : up->id == s->seat.wanted)) continue;
            mwm_seat_keyboard(s, up);
            break;
        }
    }
}

void mwm_seat_surface_gone(mwm_server *s, surface *f) {
    if (s->seat.pointer && s->seat.pointer->surface == f) pointer_leave(s, false);
    if (s->seat.keyboard && s->seat.keyboard->surface == f) keyboard_leave(s, false);
}

int mwm_server_cursor(const mwm_server *s) { return s->seat.cursor; }
