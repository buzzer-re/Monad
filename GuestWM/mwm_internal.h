/*
 * mwm_internal.h — what the parts of the window manager's server share:
 * a program's objects, its surfaces and buffers, the windows on the
 * display.
 *
 *   mwm_server.c   clients, the registry, shared memory, the output
 *   mwm_surface.c  surfaces and their subsurfaces, the windows' places on
 *                  the display, and drawing them there
 *   mwm_shell.c    windows as programs ask for them (xdg_wm_base)
 *   mwm_seat.c     the pointer and the keyboard
 *   mwm_data.c     the clipboard's interface
 */
#ifndef MWM_INTERNAL_H
#define MWM_INTERNAL_H

#include "mwm_server.h"
#include "mwm_wire.h"

#include <stddef.h>

typedef enum {
    T_NONE = 0,
    T_DISPLAY,
    T_CALLBACK,
    T_REGISTRY,
    T_COMPOSITOR,
    T_SURFACE,
    T_REGION,
    T_SHM,
    T_POOL,
    T_BUFFER,
    T_OUTPUT,
    T_WM_BASE,
    T_POSITIONER,
    T_XDG_SURFACE,
    T_TOPLEVEL,
    T_SEAT,
    T_POINTER,
    T_KEYBOARD,
    T_SUBCOMPOSITOR,
    T_SUBSURFACE,
    T_DATA_MANAGER,
    T_DATA_SOURCE,
    T_DATA_DEVICE,
} obj_type;

/* wl_display.error codes. */
enum { E_INVALID_OBJECT = 0, E_INVALID_METHOD = 1, E_NO_MEMORY = 2, E_IMPLEMENTATION = 3 };
enum {
    MAX_FRAMES = 16,
    TEXT = 128,
    MAX_HELD = 32,
    /* Subsurfaces one surface may have, and how deep they may nest. */
    MAX_CHILDREN = 32,
    MAX_DEPTH = 8,
    /* A program draws at the screen's scale: 1, or 2 on a Retina screen; some ask for 3. */
    MAX_SCALE = 4,
};

typedef struct client client;
typedef struct surface surface;

typedef struct {
    uint8_t type;
    /* The version of its interface the program bound, where it matters. */
    uint8_t version;
    void *data;
} object;

/* A rectangle, from (x1, y1) up to but without (x2, y2); empty when it has no pixel. */
typedef struct {
    int32_t x1, y1, x2, y2;
} box;

/* Shared memory a program handed over; kept while any of its buffers is. */
typedef struct {
    int refs;
    int fd;
    uint8_t *map;
    size_t size;
} pool;

typedef struct {
    client *owner;
    /* 0 once the program destroyed it while a surface still shows it. */
    uint32_t id;
    pool *pool;
    int32_t offset, width, height, stride;
    /* ARGB8888: its pixels say how much of what is under them shows. */
    bool alpha;
    /* The surfaces showing it. */
    int shown;
} buffer;

/* A window's place on the display, in the display's pixels. */
typedef struct {
    bool used;
    uint32_t id;
    int x, y, width, height;
    /* Pixels to one of the program's units: what its surface is drawn at. */
    int scale;
    surface *surface;
} window;

/* A top-level window's role on a surface (xdg_surface and xdg_toplevel). */
typedef struct {
    surface *surface;
    uint32_t id, toplevel;
    bool configured;
    /* It has been told it is the window in front. */
    bool active;
    /* The size it was last asked to be; 0: any it likes. */
    int32_t width, height;
    /* The part of the surface that is the window (the rest is its shadow),
     * in the program's units; empty: all of it. */
    box geometry;
    /* What it will be at the surface's next commit. */
    box next_geometry;
    bool geometry_waits;
    char title[TEXT], app_id[TEXT];
} xdg;

/* What a commit makes take effect. */
typedef struct {
    buffer *buffer;
    bool attached; /* `buffer` is to be shown (NULL: nothing is) */
    /* What changed since the last commit: in the buffer's pixels, and in the program's units. */
    box damage, surface_damage;
    int32_t scale; /* 0: as it was */
    uint32_t frames[MAX_FRAMES];
    int frame_count;
} state;

/* A surface's role as a part of another (wl_subsurface). */
typedef struct {
    /* NULL once the surface, or its parent, was destroyed: it shows nowhere. */
    surface *surface, *parent;
    uint32_t id;
    /* Where it is on its parent, in the program's units, and where it will be at the parent's next commit. */
    int32_t x, y, next_x, next_y;
    /* Its commits wait for its parent's (the default). */
    bool sync;
    bool has_cached;
    state cached;
} subsurface;

struct surface {
    client *owner;
    uint32_t id;
    state pending;
    buffer *current;
    int32_t scale;
    /* What of it changed and is not on the display yet, in its buffer's pixels. */
    box dirty;
    uint32_t frames_waiting[MAX_FRAMES];
    int waiting_count;
    xdg *xdg;
    subsurface *sub;
    window *window;
    /* Itself and its subsurfaces, from the bottom up. */
    surface *stack[MAX_CHILDREN + 1];
    int stack_count;
};

struct client {
    mwm_server *server;
    mwm_conn *conn;
    object *objects;
    uint32_t object_cap;
    bool dead;
};

struct mwm_server {
    mwm_screen screen;
    client *clients[MWM_MAX_CLIENTS];
    window windows[MWM_MAX_WINDOWS];
    /* The windows in the order they came (indexes into `windows`). */
    int order[MWM_MAX_WINDOWS];
    int window_count;
    uint32_t next_window, serial, generation;
    /* Callbacks waiting for the next frame, over all surfaces, and when the last frame was. */
    int frames_waiting;
    uint32_t frame_time;
    /* What programs are told the screen's scale is. */
    int scale;
    /* The pointer and the keyboard (mwm_seat.c). */
    struct {
        /* The window the pointer is over, and where in it. */
        window *pointer;
        int32_t x, y;
        /* The window in front, which gets the keys. */
        window *keyboard;
        /* The keys that are down, in the order they went down. */
        uint32_t held[MAX_HELD];
        int held_count;
        uint32_t depressed, locked;
        /* The keymap, as a file programs map; read-only. */
        int keymap_fd;
        uint32_t keymap_size;
    } seat;
};

/* Objects and errors (mwm_server.c). */

/* The program broke the protocol: it is told why, once, and dropped. */
void mwm_fail(client *c, uint32_t id, uint32_t code, const char *why);
void *mwm_find_as(client *c, uint32_t id, obj_type type);
/* Whether the program has an object of that kind under that id. */
bool mwm_is(client *c, uint32_t id, obj_type type);
/* Registers an object under the id the program chose for it; false (and
 * the program failed) when it may not have that id. */
bool mwm_add(client *c, uint32_t id, obj_type type, void *data);
/* The id is free again, and the program is told it may reuse it. */
void mwm_del(client *c, uint32_t id);
void mwm_event_uint(client *c, uint32_t id, uint16_t opcode, uint32_t v);
/* For a request whose arguments mean nothing here. */
void mwm_skip_arguments(mwm_msg *m);
/* Sends what waits for every program, and drops the ones that failed. */
void mwm_flush(mwm_server *s);
/* A surface no longer shows the buffer: the program gets it back, or it is freed. */
void mwm_buffer_unshown(buffer *b);

/* Surfaces, windows and the display (mwm_surface.c). */

/* A request to wl_compositor, wl_surface, wl_region, wl_subcompositor or wl_subsurface. */
void mwm_surface_request(mwm_server *s, client *c, object *o, mwm_msg *m);
/* The surface goes, with what it shows; `tell`: its program is told the id is free. */
void mwm_surface_destroy(mwm_server *s, client *c, surface *f, bool tell);
/* The buffer is being destroyed: no commit that waits may show it. */
void mwm_surface_forget_buffer(client *c, const buffer *b);
/* The window leaves the display, and its place is cleared. */
void mwm_window_gone(mwm_server *s, window *w);
/* The window with that id; NULL when there is none. */
window *mwm_window_by_id(mwm_server *s, uint32_t id);

/* Windows as programs ask for them (mwm_shell.c). */

/* A request to xdg_wm_base or one of its objects. */
void mwm_shell_request(mwm_server *s, client *c, object *o, mwm_msg *m);
/* The surface was committed: a window not yet told its size is told. */
void mwm_shell_commit(mwm_server *s, client *c, surface *f);
/* The window is told it is the one in front, or that it no longer is. */
void mwm_shell_activate(mwm_server *s, window *w, bool active);

/* The pointer and the keyboard (mwm_seat.c). */

/* The keymap programs get until another is given; false when there is no memory for it. */
bool mwm_seat_init(mwm_server *s);
void mwm_seat_free(mwm_server *s);
/* A program bound wl_seat. */
void mwm_seat_bound(client *c, uint32_t id);
/* A request to wl_seat, wl_pointer or wl_keyboard. */
void mwm_seat_request(mwm_server *s, client *c, object *o, mwm_msg *m);
/* The window leaves the display: its program is told the pointer and the
 * keyboard left it, and neither is anybody's until the Mac says. */
void mwm_seat_window_gone(mwm_server *s, window *w);
/* The surface is being destroyed: nothing more is said about it. */
void mwm_seat_surface_gone(mwm_server *s, surface *f);

/* The clipboard's interface (mwm_data.c). */

/* A request to wl_data_device_manager, wl_data_source or wl_data_device. */
void mwm_data_request(mwm_server *s, client *c, object *o, mwm_msg *m);

#endif
