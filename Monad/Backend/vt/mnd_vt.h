/*
 * mnd_vt.h — Monad terminal emulator core.
 *
 * A self-contained xterm-compatible (TERM=xterm-256color) terminal state
 * machine: byte stream in, screen model out. No platform dependencies beyond
 * libc and pthreads, so it can be unit-tested anywhere.
 *
 * Threading: every function not documented otherwise takes the terminal lock
 * internally and may be called from any thread. Functions marked "LOCKED"
 * must be called between mnd_vt_lock() and mnd_vt_unlock(); pointers they
 * return are valid only until the lock is released. Callbacks are invoked
 * without the lock held, on the thread that called mnd_vt_feed().
 */
#ifndef MND_VT_H
#define MND_VT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mnd_vt mnd_vt;

/* ---- Colors -------------------------------------------------------------
 * A color is a tagged 32-bit value: default, palette index (0-255), or RGB.
 */
#define MND_COLOR_DEFAULT 0u
#define MND_COLOR_TAG_INDEX 0x01000000u
#define MND_COLOR_TAG_RGB 0x02000000u
#define MND_COLOR_TAG_MASK 0xFF000000u
#define MND_COLOR_INDEX(i) (MND_COLOR_TAG_INDEX | ((uint32_t)(i) & 0xFFu))
#define MND_COLOR_RGB(r, g, b) \
    (MND_COLOR_TAG_RGB | (((uint32_t)(r) & 0xFFu) << 16) | (((uint32_t)(g) & 0xFFu) << 8) | ((uint32_t)(b) & 0xFFu))

/* ---- Cell attributes ---------------------------------------------------- */
enum {
    MND_ATTR_BOLD = 1u << 0,
    MND_ATTR_DIM = 1u << 1,
    MND_ATTR_ITALIC = 1u << 2,
    MND_ATTR_BLINK = 1u << 3,
    MND_ATTR_INVERSE = 1u << 4,
    MND_ATTR_HIDDEN = 1u << 5,
    MND_ATTR_STRIKE = 1u << 6,
    MND_ATTR_OVERLINE = 1u << 7,
    /* Underline style occupies bits 8-10 (see MND_UNDERLINE_*). */
    MND_ATTR_UNDERLINE_SHIFT = 8,
    MND_ATTR_UNDERLINE_MASK = 7u << 8,
    /* Cell width occupies bits 11-12 (see MND_WIDTH_*). */
    MND_ATTR_WIDTH_SHIFT = 11,
    MND_ATTR_WIDTH_MASK = 3u << 11,
};

enum {
    MND_UNDERLINE_NONE = 0,
    MND_UNDERLINE_SINGLE = 1,
    MND_UNDERLINE_DOUBLE = 2,
    MND_UNDERLINE_CURLY = 3,
    MND_UNDERLINE_DOTTED = 4,
    MND_UNDERLINE_DASHED = 5,
};

enum {
    MND_WIDTH_NORMAL = 0, /* occupies one column */
    MND_WIDTH_WIDE = 1,   /* first half of a double-width glyph */
    MND_WIDTH_SPACER = 2, /* second half of a double-width glyph; draw nothing */
};

/* If cp has this bit set, the low bits index a grapheme cluster (base +
 * combining marks) retrievable with mnd_vt_grapheme(). */
#define MND_CP_GRAPHEME_FLAG 0x80000000u

/* A cell showing a tile of an inline image: bits 16-29 hold the image id,
 * bits 8-15 the tile's row and bits 0-7 its column within the image. Such
 * a cell is drawn by the front end, copies as a blank and is no word. */
#define MND_CP_IMAGE_FLAG 0x40000000u
static inline bool mnd_cp_is_image(uint32_t cp) { return (cp & 0xC0000000u) == MND_CP_IMAGE_FLAG; }
static inline uint32_t mnd_cp_image_id(uint32_t cp) { return (cp >> 16) & 0x3FFFu; }
static inline unsigned mnd_cp_image_x(uint32_t cp) { return cp & 0xFFu; }
static inline unsigned mnd_cp_image_y(uint32_t cp) { return (cp >> 8) & 0xFFu; }

typedef struct {
    uint32_t cp;    /* Unicode scalar, 0 for an empty cell, or grapheme ref */
    uint32_t fg;    /* MND_COLOR_* */
    uint32_t bg;    /* MND_COLOR_* */
    uint16_t attrs; /* MND_ATTR_* */
    uint16_t link;  /* OSC 8 hyperlink id, 0 if none */
} mnd_cell;

static inline unsigned mnd_cell_width(const mnd_cell *c) {
    return (c->attrs & MND_ATTR_WIDTH_MASK) >> MND_ATTR_WIDTH_SHIFT;
}
static inline unsigned mnd_cell_underline(const mnd_cell *c) {
    return (c->attrs & MND_ATTR_UNDERLINE_MASK) >> MND_ATTR_UNDERLINE_SHIFT;
}

/* ---- Modes queried by the front end ------------------------------------ */
typedef enum {
    MND_MODE_APP_CURSOR = 0,   /* DECCKM */
    MND_MODE_APP_KEYPAD,       /* DECKPAM / DECNKM */
    MND_MODE_CURSOR_VISIBLE,   /* DECTCEM */
    MND_MODE_CURSOR_BLINK,     /* ?12 / DECSCUSR */
    MND_MODE_ALT_SCREEN,       /* ?47/?1047/?1049 active */
    MND_MODE_BRACKETED_PASTE,  /* ?2004 */
    MND_MODE_FOCUS_EVENTS,     /* ?1004 */
    MND_MODE_SYNC_OUTPUT,      /* ?2026 */
    MND_MODE_REVERSE_VIDEO,    /* DECSCNM */
    MND_MODE_ALT_SCROLL,       /* ?1007: wheel sends arrows on alt screen */
    MND_MODE_COUNT_
} mnd_mode;

typedef enum {
    MND_MOUSE_OFF = 0,
    MND_MOUSE_X10,    /* ?9: press only */
    MND_MOUSE_NORMAL, /* ?1000: press/release */
    MND_MOUSE_BUTTON, /* ?1002: + motion while pressed */
    MND_MOUSE_ANY,    /* ?1003: + all motion */
} mnd_mouse_tracking;

typedef enum {
    MND_CURSOR_BLOCK = 0,
    MND_CURSOR_UNDERLINE,
    MND_CURSOR_BAR,
} mnd_cursor_shape;

typedef struct {
    int x, y;              /* position on the live screen (0-based) */
    bool visible;          /* DECTCEM and not scrolled away from the bottom */
    bool blink;
    mnd_cursor_shape shape;
    bool styled;           /* the program chose shape/blink (DECSCUSR 1-6);
                              otherwise the user's theme and settings apply */
} mnd_cursor_info;

/* ---- Inline images ------------------------------------------------------
 * iTerm2's OSC 1337 File=...;inline=1 (neofetch, fastfetch, imgcat). Off
 * unless turned on (a VM's setting): a guest's image is not even parsed
 * otherwise. The core never decodes one: it reads the file's header for its
 * format and size, lays it out over cells (MND_CP_IMAGE_FLAG) and hands the
 * bytes to the front end, which decodes them. */
#define MND_VT_IMAGE_BYTES_MAX (4u << 20) /* the file */
#define MND_VT_IMAGE_SIDE_MAX 8192        /* pixels, either way */
#define MND_VT_IMAGE_PIXELS_MAX (32u << 20)
#define MND_VT_IMAGE_CELLS_MAX 255        /* columns or rows it covers */
#define MND_VT_IMAGE_EVENTS 8             /* images one mnd_vt_feed hands over */
#define MND_VT_IMAGE_ID_MAX 0x3FFF        /* ids wrap after this; old tiles go first */

typedef enum {
    MND_IMAGE_PNG = 1,
    MND_IMAGE_JPEG,
    MND_IMAGE_GIF,
} mnd_image_format;

typedef struct {
    uint32_t id;
    mnd_image_format format;
    int width, height;     /* the file's pixels */
    int cols, rows;        /* the cells it covers */
    double fill_x, fill_y; /* the share of those cells it fills, from the top left */
} mnd_vt_image_info;

/* Pure: the format and size of an image file from its header, or false. */
bool mnd_image_probe(const uint8_t *data, size_t len, mnd_image_format *format, int *width, int *height);

/* ---- Callbacks ---------------------------------------------------------- */
typedef struct {
    void *ctx;
    /* Bytes the terminal must send back to the application (DA, DSR, ...). */
    void (*write)(void *ctx, const char *data, size_t len);
    /* Window/icon title changed (UTF-8, NUL-terminated). */
    void (*title)(void *ctx, const char *title);
    /* OSC 7 working directory URL. */
    void (*cwd)(void *ctx, const char *url);
    /* BEL received. */
    void (*bell)(void *ctx);
    /* OSC 52 clipboard write (already base64-decoded). Reads are refused. */
    void (*clipboard)(void *ctx, const char *data, size_t len);
    /* An inline image laid out over cells: the file's bytes (checked as
     * above, not decoded), only while images are on. */
    void (*image)(void *ctx, const mnd_vt_image_info *info, const uint8_t *data, size_t len);
} mnd_vt_callbacks;

/* ---- Lifecycle ---------------------------------------------------------- */
/* Returns NULL on allocation failure or invalid size. scrollback may be 0. */
mnd_vt *mnd_vt_create(int cols, int rows, int scrollback, const mnd_vt_callbacks *cb);
void mnd_vt_destroy(mnd_vt *vt);
/* Replace the callback table (e.g. once the owner's context pointer exists). */
void mnd_vt_set_callbacks(mnd_vt *vt, const mnd_vt_callbacks *cb);

/* Process output from the application. */
void mnd_vt_feed(mnd_vt *vt, const void *data, size_t len);

/* Resize; the primary screen is reflowed. Returns false on bad size/OOM. */
bool mnd_vt_resize(mnd_vt *vt, int cols, int rows);
void mnd_vt_size(mnd_vt *vt, int *cols, int *rows);

/* Full reset (RIS) and scrollback clear. */
void mnd_vt_reset(mnd_vt *vt);
void mnd_vt_clear_scrollback(mnd_vt *vt);

/* Inline images on or off (off when created). */
void mnd_vt_set_images(mnd_vt *vt, bool on);
/* A cell's size in device pixels: image sizes in pixels, and the answers
 * to CSI 14 t and CSI 16 t while images are on. */
void mnd_vt_set_cell_pixels(mnd_vt *vt, int width, int height);

/* Palette used to answer OSC 4/10/11 color queries (the renderer's theme).
 * colors: 256 RGB values 0xRRGGBB, fg/bg: 0xRRGGBB. */
void mnd_vt_set_theme(mnd_vt *vt, const uint32_t palette[256], uint32_t fg, uint32_t bg);

/* ---- Reading state ------------------------------------------------------ */
void mnd_vt_lock(mnd_vt *vt);
void mnd_vt_unlock(mnd_vt *vt);

/* LOCKED. Row y of the current viewport (0 = top), accounting for scrollback
 * offset. Writes the row length (== cols) to *len. Never NULL for valid y. */
const mnd_cell *mnd_vt_view_row(mnd_vt *vt, int y, int *len);
/* LOCKED. Whether the viewport row y ends in a soft wrap. */
bool mnd_vt_view_row_wrapped(mnd_vt *vt, int y);
/* LOCKED. Cursor state for the viewport. */
mnd_cursor_info mnd_vt_cursor(mnd_vt *vt);
/* LOCKED. Fill dirty[rows] with 1 for viewport rows that changed since the
 * last call, then clear the dirty state. Returns true if anything was dirty. */
bool mnd_vt_take_dirty(mnd_vt *vt, uint8_t *dirty, int rows);
/* LOCKED. UTF-32 sequence of a grapheme ref cell. Returns count, fills up to cap. */
size_t mnd_vt_grapheme(mnd_vt *vt, uint32_t cp, uint32_t *out, size_t cap);
/* LOCKED. URI of a hyperlink id, or NULL. */
const char *mnd_vt_link_uri(mnd_vt *vt, uint16_t link);

/* Hyperlinks a guest can make are bounded: a longer URI makes no link,
 * and the table of URIs stops growing past the byte cap. */
#define MND_VT_LINK_URI_MAX 2048
#define MND_VT_LINK_BYTES_MAX (1u << 20)
/* Bytes held by the link table (its URIs). Takes the lock. */
size_t mnd_vt_link_bytes(mnd_vt *vt);
/* LOCKED. Mode flags. */
bool mnd_vt_mode(mnd_vt *vt, mnd_mode mode);
mnd_mouse_tracking mnd_vt_mouse_tracking(mnd_vt *vt);

/* ---- Scrollback viewport ------------------------------------------------- */
/* Lines scrolled back from the bottom (0 = following output). */
int mnd_vt_scroll_offset(mnd_vt *vt);
/* Number of scrollback lines available. */
int mnd_vt_scrollback_lines(mnd_vt *vt);
/* Scroll by delta lines (positive = back in history). Returns new offset. */
int mnd_vt_scroll(mnd_vt *vt, int delta);
void mnd_vt_scroll_to_bottom(mnd_vt *vt);

/* ---- Selection ------------------------------------------------------------
 * Positions are (column, absolute line). Absolute lines are stable while
 * output scrolls: mnd_vt_view_to_abs() converts a viewport row. */
typedef struct {
    int col;
    int64_t line;
} mnd_pos;

int64_t mnd_vt_view_to_abs(mnd_vt *vt, int y);
/* LOCKED variant of mnd_vt_view_to_abs. */
int64_t mnd_vt_view_to_abs_locked(mnd_vt *vt, int y);
/* LOCKED. Viewport row of an absolute line, or INT32_MIN/INT32_MAX if above/below. */
int mnd_vt_abs_to_view_locked(mnd_vt *vt, int64_t line);
/* Text between two positions (inclusive, any order) as malloc'd UTF-8.
 * block selects a rectangle. Soft-wrapped lines are joined; trailing blanks
 * trimmed. Caller frees. Returns NULL if empty. */
char *mnd_vt_copy_text(mnd_vt *vt, mnd_pos a, mnd_pos b, bool block);
/* Expand pos to the word around it. */
void mnd_vt_word_bounds(mnd_vt *vt, mnd_pos pos, mnd_pos *start, mnd_pos *end);
/* Expand to the logical (unwrapped) line around pos. */
void mnd_vt_line_bounds(mnd_vt *vt, mnd_pos pos, mnd_pos *start, mnd_pos *end);

/* ---- Input encoding --------------------------------------------------------
 * All encoders write at most cap bytes and return the number written (0 if
 * nothing should be sent). 32 bytes is always enough for keys and mouse. */
enum {
    MND_MOD_SHIFT = 1,
    MND_MOD_ALT = 2,
    MND_MOD_CTRL = 4,
    MND_MOD_META = 8,
};

typedef enum {
    MND_KEY_NONE = 0,
    MND_KEY_UP, MND_KEY_DOWN, MND_KEY_RIGHT, MND_KEY_LEFT,
    MND_KEY_HOME, MND_KEY_END, MND_KEY_INSERT, MND_KEY_DELETE,
    MND_KEY_PAGE_UP, MND_KEY_PAGE_DOWN,
    MND_KEY_BACKSPACE, MND_KEY_TAB, MND_KEY_ENTER, MND_KEY_ESCAPE,
    MND_KEY_F1, MND_KEY_F2, MND_KEY_F3, MND_KEY_F4, MND_KEY_F5, MND_KEY_F6,
    MND_KEY_F7, MND_KEY_F8, MND_KEY_F9, MND_KEY_F10, MND_KEY_F11, MND_KEY_F12,
    MND_KEY_F13, MND_KEY_F14, MND_KEY_F15, MND_KEY_F16, MND_KEY_F17,
    MND_KEY_F18, MND_KEY_F19, MND_KEY_F20,
    MND_KEY_KP_0, MND_KEY_KP_1, MND_KEY_KP_2, MND_KEY_KP_3, MND_KEY_KP_4,
    MND_KEY_KP_5, MND_KEY_KP_6, MND_KEY_KP_7, MND_KEY_KP_8, MND_KEY_KP_9,
    MND_KEY_KP_DECIMAL, MND_KEY_KP_DIVIDE, MND_KEY_KP_MULTIPLY,
    MND_KEY_KP_SUBTRACT, MND_KEY_KP_ADD, MND_KEY_KP_ENTER, MND_KEY_KP_EQUAL,
    MND_KEY_COUNT_
} mnd_key;

size_t mnd_vt_encode_key(mnd_vt *vt, mnd_key key, unsigned mods, char *out, size_t cap);
/* A character typed with modifiers (Ctrl/Alt handling). cp is the unshifted
 * character for Ctrl combos (e.g. 'c'). Plain text should be sent as UTF-8. */
size_t mnd_vt_encode_char(mnd_vt *vt, uint32_t cp, unsigned mods, char *out, size_t cap);

typedef enum {
    MND_MOUSE_PRESS = 0,
    MND_MOUSE_RELEASE,
    MND_MOUSE_MOTION,
} mnd_mouse_action;

/* button: 0 left, 1 middle, 2 right, 3 none (motion), 4/5 wheel up/down,
 * 6/7 wheel left/right. col/row are 0-based viewport cells. */
size_t mnd_vt_encode_mouse(mnd_vt *vt, int button, mnd_mouse_action action, unsigned mods, int col,
                           int row, char *out, size_t cap);
size_t mnd_vt_encode_focus(mnd_vt *vt, bool focused, char *out, size_t cap);
/* Sanitize pasted UTF-8 (strip control characters except TAB/CR, convert LF
 * and CRLF to CR, and drop ESC so a paste cannot end bracketed mode) and wrap
 * in bracketed-paste markers when enabled. Returns malloc'd buffer; caller frees. */
char *mnd_vt_encode_paste(mnd_vt *vt, const char *text, size_t len, size_t *out_len);

/* ---- Utilities ------------------------------------------------------------ */
/* Display width of a code point: 0 (combining), 1 or 2; -1 for control characters. */
int mnd_wcwidth(uint32_t cp);

#ifdef __cplusplus
}
#endif

#endif /* MND_VT_H */
