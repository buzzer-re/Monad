/*
 * mwm_server.h — Monad's window manager for a Linux VM's display: the
 * Wayland server programs connect to. It gives each program's window its
 * own place on the display, side by side and never overlapping (the Mac
 * shows each place as a window of its own), and copies what the program
 * drew there.
 *
 * This part knows nothing of the display's hardware or of sockets being
 * listened on: it is handed a block of pixels (mwm_screen) and connected
 * clients, so it runs in tests on the Mac and on Linux
 * (CTests/test_wm_server.c). mwm_kms.c and mwm_main.c are the Linux side.
 *
 * What it speaks so far: wl_display, wl_registry, wl_compositor,
 * wl_surface, wl_region, wl_shm (ARGB8888 and XRGB8888), wl_output, and
 * xdg_wm_base with top-level windows. No input, no popups, no clipboard
 * yet.
 */
#ifndef MWM_SERVER_H
#define MWM_SERVER_H

#include <stdbool.h>
#include <stdint.h>

/* The display's pixels (XRGB, one word each) and how to show a change. */
typedef struct {
    uint32_t *pixels;
    int width, height;
    /* Words from one row to the next. */
    int stride;
    /* The rectangle changed: put it on the display. */
    void (*present)(void *ctx, int x, int y, int width, int height);
    void *ctx;
} mwm_screen;

/* A window as it is on the display. */
typedef struct {
    uint32_t id;
    int x, y, width, height;
    /* Plain text of the program's choosing; never NULL. */
    const char *title;
    const char *app_id;
} mwm_window;

enum {
    MWM_MAX_CLIENTS = 64,
    MWM_MAX_WINDOWS = 64,
    /* Objects one client may have alive. */
    MWM_MAX_OBJECTS = 16384,
    /* Room left between two windows on the display. */
    MWM_GAP = 16,
};

typedef struct mwm_server mwm_server;

mwm_server *mwm_server_new(const mwm_screen *screen);
void mwm_server_free(mwm_server *s);

/* A program connected: its socket, taken. False (and the socket closed)
 * when there are as many as there may be. */
bool mwm_server_add_client(mwm_server *s, int fd);

/* The clients' sockets, for poll: how many were written to `fds` and
 * `wants_write` (at most `max`). */
int mwm_server_sockets(const mwm_server *s, int *fds, bool *wants_write, int max);

/* A client's socket has something to read, or room to write. */
void mwm_server_service(mwm_server *s, int fd, bool readable, bool writable);

/* A frame's time has come (about 60 times a second): programs that asked
 * to be told when to draw again are told. */
void mwm_server_frame(mwm_server *s, uint32_t time_ms);

/* The windows on the display, oldest first: how many were written. */
int mwm_server_windows(const mwm_server *s, mwm_window *out, int max);
/* Counts up whenever a window comes, goes, moves or is renamed. */
uint32_t mwm_server_generation(const mwm_server *s);

/* A program shrank the file behind memory it handed over, and reading it
 * raised SIGBUS: called from the signal's handler, it ends the copy that
 * was being made (the program is then dropped). Returns when no copy was. */
void mwm_server_bus_error(void);

#endif
