/*
 * mwm_server.h — Monad's window manager for a Linux VM's display: the
 * Wayland server programs connect to. It gives each program's window its
 * own place on the display, in rows and never overlapping (the Mac shows
 * each place as a window of its own), and draws there what the program
 * drew.
 *
 * This part knows nothing of the display's hardware or of sockets being
 * listened on: it is handed a block of pixels (mwm_screen) and connected
 * clients, so it runs in tests on the Mac and on Linux
 * (CTests/test_wm_*.c). mwm_kms.c and mwm_main.c are the Linux side.
 *
 * What it speaks so far: wl_display, wl_registry, wl_compositor,
 * wl_surface, wl_region, wl_subcompositor, wl_shm (ARGB8888 and XRGB8888),
 * wl_output, xdg_wm_base with top-level windows, wl_seat with a pointer
 * and a keyboard, and wl_data_device_manager as far as programs need it to
 * start (nothing is copied anywhere). No popups, no clipboard yet. A
 * window's own surface takes the pointer wherever it is over the window:
 * its subsurfaces are drawn, and not told of the pointer.
 */
#ifndef MWM_SERVER_H
#define MWM_SERVER_H

#include <stdbool.h>
#include <stddef.h>
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

/* Some rows of a popup, and the part of each that is there: `height`
 * rows, `width` pixels from `x` of the popup's inner part (none when 0). */
typedef struct {
    uint16_t height, x, width;
} mwm_band;

/* A window as it is on the display, in the display's pixels. */
typedef struct {
    uint32_t id;
    int x, y, width, height;
    /* Pixels to one of the program's units (1, or 2 when it draws for a
     * Retina screen): the Mac's window is that many times smaller in points. */
    int scale;
    /* The part of it that is the window proper, from the window's top
     * left: all of it, unless the program draws a shadow around its window
     * and said where the window is inside. */
    int inner_x, inner_y, inner_width, inner_height;
    /* A popup (a menu, a tooltip): the window it is on, and where its own
     * inner part stands from that window's inner top left, in that
     * window's pixels (it may reach outside it). 0 for a window of its own. */
    uint32_t parent;
    int offset_x, offset_y;
    /* The program draws the window's title bar itself (a header bar), and
     * the colour it has at its top (0x00RRGGBB): the Mac's title bar is
     * made to continue it. False: the frame is all the Mac's. */
    bool own_bar;
    uint32_t bar_color;
    /* A popup the program did not draw as a whole rectangle (round
     * corners, an arrow): its inner part from the top down, row by row.
     * None (0) when all of it is there, or its shape takes more rows
     * than are told. The server's own, until it is next called. */
    const mwm_band *bands;
    int band_count;
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
    /* The rows of a popup's shape that are told at most. */
    MWM_MAX_BANDS = 128,
    /* A key's code is the Linux kernel's; X has no place for one beyond. */
    MWM_MAX_KEYCODE = 247,
    MWM_MAX_KEYS = MWM_MAX_KEYCODE,
    /* The widest and the tallest a window can be asked to be: the largest display there is. */
    MWM_MAX_SIDE = 8192,
    /* Texts on their way through pipes at once (the clipboard's), and with
     * the programs' sockets, all there is to poll. */
    MWM_MAX_TRANSFERS = 8,
    MWM_MAX_SOCKETS = MWM_MAX_CLIENTS + MWM_MAX_TRANSFERS,
    /* The most text of the Mac's a paste in the VM gives, and the most a
     * copy in the VM gives the Mac (as much as a terminal may set, ClipboardPolicy). */
    MWM_MAX_CLIPBOARD = 1 << 20,
    MWM_MAX_COPY = 100 << 10,
    /* How long after the user's ⌘C a program's copy is still the answer to it. */
    MWM_COPY_MS = 2000,
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

/* What there is to poll: the programs' sockets, and the pipes text is on
 * its way through. How many were written to `fds` and `wants_write` (at
 * most `max`; MWM_MAX_SOCKETS holds them all). */
int mwm_server_sockets(const mwm_server *s, int *fds, bool *wants_write, int max);

/* One of those has something to read, or room to write. */
void mwm_server_service(mwm_server *s, int fd, bool readable, bool writable);

/* A frame's time has come (about 60 times a second): programs that asked
 * to be told when to draw again are told. */
void mwm_server_frame(mwm_server *s, uint32_t time_ms);
/* Whether any program waits for a frame: with none, there is nothing to
 * wake up for. */
bool mwm_server_wants_frame(const mwm_server *s);

/* The display's size. */
void mwm_server_size(const mwm_server *s, int *width, int *height);
/* The scale of the Mac's screen (1, or 2 on a Retina screen): programs are
 * told, and draw their windows with that many pixels to a unit. */
void mwm_server_scale(mwm_server *s, int scale);

/* The windows on the display, oldest first: how many were written. */
int mwm_server_windows(const mwm_server *s, mwm_window *out, int max);
/* Counts up whenever a window comes, goes, moves, is renamed, or changes
 * who draws its title bar or what colour that has. */
uint32_t mwm_server_generation(const mwm_server *s);

/* The Mac's window was resized: the program is asked to draw at that size
 * (it answers with a buffer of the size it then chooses). Sizes that no
 * window can have are not passed on. */
void mwm_server_resize(mwm_server *s, uint32_t window, int32_t width, int32_t height);
/* The Mac's window was asked to close: the program is asked to close it
 * (it may first ask whether to save). */
void mwm_server_close(mwm_server *s, uint32_t window);
/* The user clicked away from that window's popups (on another window, on
 * another app): the program is told each is done with, the one on top
 * first, and takes them down. */
void mwm_server_dismiss(mwm_server *s, uint32_t window);

/* What a program asks of its own window, which is the Mac's to do or not:
 * to be moved (the user is dragging the bar the program drew), to be as
 * large as it gets or back (a double click on that bar), to be put away.
 * Heard only from the window the pointer is over or the one in front. */
typedef enum { MWM_ASK_MOVE = 1, MWM_ASK_ZOOM, MWM_ASK_UNZOOM, MWM_ASK_MINIMIZE } mwm_ask;
typedef void (*mwm_asked)(void *ctx, uint32_t window, mwm_ask what);
void mwm_server_on_ask(mwm_server *s, mwm_asked asked, void *ctx);

/*
 * The clipboard. Programs in the VM copy and paste among themselves. The
 * Mac's clipboard and the VM's meet only when the user says so, on the
 * Mac's keyboard: ⌘V makes the Mac's text what a paste gives; after ⌘C
 * (or ⌘X), what the program in front copies next is handed out for the
 * Mac, once. A program in the VM never reads the Mac's clipboard by
 * itself, and never sets it by itself.
 */

/* The Mac's text (UTF-8, at most MWM_MAX_CLIPBOARD bytes) is what a paste
 * gives from now on; none (len 0): nothing of the Mac's is. False, and
 * nothing changed, when it is no text or too much. */
bool mwm_server_paste(mwm_server *s, const char *text, size_t len);
/* The user pressed ⌘C: what the program in front copies within MWM_COPY_MS is for the Mac. */
void mwm_server_copy(mwm_server *s, uint32_t time_ms);
/* Who is handed such a copy (UTF-8, at most MWM_MAX_COPY bytes, not NUL-terminated). */
typedef void (*mwm_copied)(void *ctx, const char *text, size_t len);
void mwm_server_on_copied(mwm_server *s, mwm_copied copied, void *ctx);

/*
 * Input. The pointer and the keyboard are the Mac's: whoever shows the
 * windows there says which window the pointer is over and which one has
 * the keyboard, and the program owning it is told. A window that does not
 * exist is no window (0).
 *
 * Positions are in the window, from its top left, in 1/256 of one of the
 * program's units (a pixel, or two when it draws for a Retina screen);
 * buttons and keys are the Linux kernel's codes (BTN_LEFT, KEY_A);
 * modifiers are X's bits (Shift 1, Lock 2, Control 4, Mod1 8, ...).
 */
void mwm_server_pointer(mwm_server *s, uint32_t window, int32_t x, int32_t y, uint32_t time_ms);
void mwm_server_button(mwm_server *s, uint32_t button, bool pressed, uint32_t time_ms);
/* How the pointer is to look where it is: the Mac draws it. What the
 * program under it asked for by name (wp_cursor_shape_device_v1's shapes,
 * 1 the arrow to MWM_CURSOR_LAST), or hidden when it asked for none. The
 * arrow over no window, and until the program under it says. */
enum { MWM_CURSOR_HIDDEN = 0, MWM_CURSOR_DEFAULT = 1, MWM_CURSOR_LAST = 36 };
int mwm_server_cursor(const mwm_server *s);
/* Scrolling by so much, in 1/256 of a unit: right and down are positive. */
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
