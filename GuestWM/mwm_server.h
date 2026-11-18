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
 * wl_surface, wl_region, wl_shm (ARGB8888 and XRGB8888), wl_output,
 * xdg_wm_base with top-level windows, and wl_seat with a pointer and a
 * keyboard. No popups, no clipboard yet.
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
    /* A key's code is the Linux kernel's; X has no place for one beyond. */
    MWM_MAX_KEYCODE = 247,
    MWM_MAX_KEYS = MWM_MAX_KEYCODE,
};

/* A key of the keyboard: its code, and the symbol (X's number for it) it
 * types plain, with Shift, with the third-level key, and with both; 0 for
 * none. `caps`: Caps Lock does to it what Shift does. */
typedef struct {
    uint32_t code;
    uint32_t symbols[4];
    bool caps;
} mwm_key;

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

/*
 * Input. The pointer and the keyboard are the Mac's: whoever shows the
 * windows there says which window the pointer is over and which one has
 * the keyboard, and the program owning it is told. A window that does not
 * exist is no window (0).
 *
 * Positions are in the window, from its top left, in 1/256 of a pixel;
 * buttons and keys are the Linux kernel's codes (BTN_LEFT, KEY_A);
 * modifiers are X's bits (Shift 1, Lock 2, Control 4, Mod1 8, ...).
 */
void mwm_server_pointer(mwm_server *s, uint32_t window, int32_t x, int32_t y, uint32_t time_ms);
void mwm_server_button(mwm_server *s, uint32_t button, bool pressed, uint32_t time_ms);
/* Scrolling by so much, in 1/256 of a pixel: right and down are positive. */
void mwm_server_scroll(mwm_server *s, int32_t dx, int32_t dy, uint32_t time_ms);
/* The window in front, which gets the keys; 0 when none is. */
void mwm_server_focus(mwm_server *s, uint32_t window);
void mwm_server_key(mwm_server *s, uint32_t key, bool pressed, uint32_t time_ms);
/* The modifiers held down and the ones locked (Caps Lock). */
void mwm_server_modifiers(mwm_server *s, uint32_t depressed, uint32_t locked);
/* What the keys type from now on (a US keyboard until this is said).
 * False, and nothing changed, when the table cannot be a keyboard. */
bool mwm_server_keymap(mwm_server *s, const mwm_key *keys, int count);

/* A program shrank the file behind memory it handed over, and reading it
 * raised SIGBUS: called from the signal's handler, it ends the copy that
 * was being made (the program is then dropped). Returns when no copy was. */
void mwm_server_bus_error(void);

#endif
