/*
 * mwm_internal.h — what the parts of the window manager's server share:
 * a program's objects, its surfaces and buffers, the windows on the
 * display. mwm_server.c has the core (clients, the registry, surfaces,
 * shared memory, the display); mwm_shell.c has windows as programs ask for
 * them (xdg_wm_base).
 */
#ifndef MWM_INTERNAL_H
#define MWM_INTERNAL_H

#include "mwm_server.h"
#include "mwm_wire.h"

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
} obj_type;

/* wl_display.error codes. */
enum { E_INVALID_OBJECT = 0, E_INVALID_METHOD = 1, E_NO_MEMORY = 2, E_IMPLEMENTATION = 3 };
enum { MAX_FRAMES = 16, TEXT = 128, MAX_HELD = 32 };

typedef struct client client;
typedef struct surface surface;

typedef struct {
    uint8_t type;
    /* The version of its interface the program bound, where it matters. */
    uint8_t version;
    void *data;
} object;

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
    /* The surfaces showing it. */
    int shown;
} buffer;

typedef struct {
    bool used;
    uint32_t id;
    int x, y, width, height;
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
    char title[TEXT], app_id[TEXT];
} xdg;

struct surface {
    client *owner;
    uint32_t id;
    buffer *pending;
    bool attached; /* an attach waits for the commit */
    buffer *current;
    uint32_t frames_pending[MAX_FRAMES], frames_waiting[MAX_FRAMES];
    int pending_count, waiting_count;
    xdg *xdg;
    window *window;
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

/* The display (mwm_server.c). */

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

#endif
