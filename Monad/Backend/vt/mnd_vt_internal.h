/*
 * mnd_vt_internal.h — private state shared by the mnd_vt translation units.
 * All functions here require the terminal lock to be held.
 */
#ifndef MND_VT_INTERNAL_H
#define MND_VT_INTERNAL_H

#include "mnd_vt.h"

#include <pthread.h>

#define MND_MAX_PARAMS 32
#define MND_MAX_INTERMEDIATES 4
#define MND_OSC_MAX (1u << 20)      /* 1 MiB: large enough for OSC 52 payloads */
/* An inline image's OSC (only while images are on): its file in base64. */
#define MND_OSC_IMAGE_MAX ((MND_VT_IMAGE_BYTES_MAX / 3 + 1) * 4 + 4096)
#define MND_GRAPHEME_MAX_CPS 8
#define MND_GRAPHEME_MAX 65536
#define MND_LINK_MAX 4096
#define MND_TITLE_STACK 10
#define MND_MAX_DIM 4096
/* Scrollback lines are stored at the terminal width; history is capped in
 * cells as well as in lines: 4 Mi cells x 16 bytes = 64 MiB per terminal. */
#define MND_SB_MAX_CELLS (4 << 20)

/* A screen or scrollback line. cols always equals the terminal width. */
typedef struct mnd_line {
    int cols;
    bool wrapped; /* line continues on the next one (soft wrap) */
    mnd_cell cells[];
} mnd_line;

typedef enum {
    CHARSET_ASCII = 0,
    CHARSET_DEC_SPECIAL,
} mnd_charset;

typedef struct {
    int x, y;
    bool wrapnext;       /* pending wrap: cursor sits past the right margin */
    mnd_cell pen;        /* fg/bg/attrs/link applied to printed cells */
    bool origin;         /* DECOM */
    uint8_t charset[2];  /* G0, G1 designations */
    uint8_t gl;          /* 0 = G0 invoked into GL, 1 = G1 */
} mnd_cursor_state;

typedef enum {
    ST_GROUND = 0,
    ST_ESCAPE,
    ST_ESCAPE_INTERMEDIATE,
    ST_CSI_ENTRY,
    ST_CSI_PARAM,
    ST_CSI_INTERMEDIATE,
    ST_CSI_IGNORE,
    ST_DCS_ENTRY,
    ST_DCS_PARAM,
    ST_DCS_INTERMEDIATE,
    ST_DCS_PASSTHROUGH,
    ST_DCS_IGNORE,
    ST_OSC_STRING,
    ST_SOS_PM_APC_STRING,
} mnd_parse_state;

typedef enum {
    MOUSE_ENC_DEFAULT = 0,
    MOUSE_ENC_UTF8,
    MOUSE_ENC_SGR,
    MOUSE_ENC_URXVT,
} mnd_mouse_encoding;

typedef struct {
    uint32_t len;
    uint32_t cps[MND_GRAPHEME_MAX_CPS];
} mnd_grapheme;

typedef struct {
    char *data;
    size_t len, cap;
} mnd_buf;

/* An image laid out in this feed, handed to the front end after unlocking. */
typedef struct {
    mnd_vt_image_info info;
    mnd_buf data;
} mnd_image_event;

struct mnd_vt {
    pthread_mutex_t mu;
    mnd_vt_callbacks cb;

    int cols, rows;

    /* Buffers. `screen` aliases `prim` or `alt`. */
    mnd_line **prim;
    mnd_line **alt;
    mnd_line **screen;
    bool in_alt;

    /* Scrollback ring (primary buffer only). */
    mnd_line **sb;
    int sb_cap;
    int sb_head;  /* index of the oldest line */
    int sb_count;
    int64_t sb_dropped; /* lines ever evicted: keeps absolute line ids stable */
    int view_offset;

    mnd_cursor_state cur;
    mnd_cursor_state saved_prim; /* DECSC on primary */
    mnd_cursor_state saved_alt;  /* DECSC on alternate */
    bool saved_prim_valid, saved_alt_valid;

    int top, bottom; /* scroll region, inclusive */
    uint8_t *tabs;   /* cols entries, 1 = tab stop */

    /* Modes */
    bool autowrap, insert, lnm;
    bool app_cursor, app_keypad;
    bool cursor_visible, cursor_blink;
    bool bracketed_paste, focus_events, sync_output, reverse_video, alt_scroll;
    mnd_mouse_tracking mouse;
    mnd_mouse_encoding mouse_enc;
    mnd_cursor_shape cursor_shape;
    bool cursor_styled;
    int modify_other_keys;

    uint32_t last_printed; /* for REP */

    /* Parser */
    mnd_parse_state state;
    int32_t params[MND_MAX_PARAMS];
    bool param_sub[MND_MAX_PARAMS]; /* param i is followed by ':' */
    int nparams;
    bool param_overflow;
    char inter[MND_MAX_INTERMEDIATES];
    int ninter;
    char marker; /* private marker '?', '>', '<', '=' or 0 */
    mnd_buf osc;
    bool osc_overflow;
    bool str_esc; /* saw ESC inside a string; waiting for '\' */
    mnd_buf dcs;
    char dcs_final;
    /* UTF-8 decoder */
    uint32_t u8_cp;
    int u8_need;
    uint32_t u8_min;

    /* Grapheme clusters */
    mnd_grapheme *graphemes;
    uint32_t ngraphemes, graphemes_cap;

    /* Hyperlinks (OSC 8): links[i] is the URI of id i+1 */
    char **links;
    uint16_t nlinks;
    size_t link_bytes; /* sum of the URIs' lengths */

    /* Dirty tracking for viewport rows */
    uint8_t *dirty;
    bool all_dirty;

    /* Theme for color queries */
    uint32_t palette[256];
    uint32_t theme_fg, theme_bg;

    /* Title stack (CSI 22/23 t) */
    char *title;
    char *title_stack[MND_TITLE_STACK];
    int title_depth;

    /* Events collected under the lock and delivered after unlocking */
    mnd_buf reply;
    char *ev_title;
    char *ev_cwd;
    int ev_bell;
    mnd_buf ev_clip;
    bool ev_clip_set;

    /* Inline images */
    bool images_on;
    int cell_px_w, cell_px_h;
    uint32_t next_image_id; /* 0 before the first image */
    mnd_image_event ev_images[MND_VT_IMAGE_EVENTS];
    int nev_images;
};

/* ---- buffer helpers (mnd_vt.c) ---- */
bool mnd_buf_append(mnd_buf *b, const void *data, size_t len);
void mnd_buf_free(mnd_buf *b);
/* Base64 (newlines and spaces skipped) into out, at most max bytes. */
bool mnd_b64_decode(const char *in, size_t max, mnd_buf *out);

/* ---- inline images (mnd_vt_image.c) ---- */
/* OSC 1337: arg is what follows "1337;". */
void mnd_vt_osc_1337(mnd_vt *vt, const char *arg);
/* Blank every image tile, in history and on both screens (mnd_vt_screen.c). */
void mnd_vt_scrub_images(mnd_vt *vt);
void mnd_vt_reply(mnd_vt *vt, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

/* ---- screen operations (mnd_vt_screen.c) ---- */
mnd_line *mnd_line_new(int cols, mnd_cell blank);
void mnd_line_fill(mnd_line *l, int from, int to, mnd_cell blank); /* [from, to) */
mnd_cell mnd_vt_blank(const mnd_vt *vt);  /* erase cell honoring BCE */
bool mnd_vt_alloc_screens(mnd_vt *vt, int cols, int rows);
void mnd_vt_free_screens(mnd_vt *vt);
void mnd_vt_mark_dirty(mnd_vt *vt, int y);
void mnd_vt_mark_all_dirty(mnd_vt *vt);
void mnd_vt_reset_tabs(mnd_vt *vt);

void mnd_vt_print(mnd_vt *vt, uint32_t cp);
/* ncols tiles of image id's row ty, from column x0 of the cursor's row. */
void mnd_vt_put_image_row(mnd_vt *vt, int x0, int ncols, uint32_t id, int ty);
void mnd_vt_linefeed(mnd_vt *vt);
void mnd_vt_index(mnd_vt *vt);
void mnd_vt_reverse_index(mnd_vt *vt);
void mnd_vt_carriage_return(mnd_vt *vt);
void mnd_vt_backspace(mnd_vt *vt);
void mnd_vt_tab(mnd_vt *vt, int n);
void mnd_vt_back_tab(mnd_vt *vt, int n);
void mnd_vt_move_to(mnd_vt *vt, int x, int y);          /* absolute, clamped */
void mnd_vt_move_to_origin(mnd_vt *vt, int x, int y);   /* honors DECOM */
void mnd_vt_move_rel(mnd_vt *vt, int dx, int dy);       /* stops at margins */
void mnd_vt_scroll_up(mnd_vt *vt, int top, int bottom, int n);
void mnd_vt_scroll_down(mnd_vt *vt, int top, int bottom, int n);
void mnd_vt_erase_display(mnd_vt *vt, int mode);
void mnd_vt_erase_line(mnd_vt *vt, int mode);
void mnd_vt_erase_chars(mnd_vt *vt, int n);
void mnd_vt_insert_chars(mnd_vt *vt, int n);
void mnd_vt_delete_chars(mnd_vt *vt, int n);
void mnd_vt_insert_lines(mnd_vt *vt, int n);
void mnd_vt_delete_lines(mnd_vt *vt, int n);
void mnd_vt_alignment_test(mnd_vt *vt);
void mnd_vt_enter_alt(mnd_vt *vt, bool clear);
void mnd_vt_leave_alt(mnd_vt *vt, bool clear);
void mnd_vt_save_cursor(mnd_vt *vt);
void mnd_vt_restore_cursor(mnd_vt *vt);
void mnd_vt_sb_clear(mnd_vt *vt);
bool mnd_vt_reflow(mnd_vt *vt, int cols, int rows);
/* Scrollback lines kept at width `cols`: the configured count, within the
 * cell budget. */
static inline int mnd_vt_sb_limit(int sb_cap, int cols) {
    int by_cells = MND_SB_MAX_CELLS / (cols > 0 ? cols : 1);
    return by_cells < sb_cap ? by_cells : sb_cap;
}

mnd_line *mnd_vt_abs_line(mnd_vt *vt, int64_t abs);
mnd_line *mnd_vt_view_line(mnd_vt *vt, int y);
uint32_t mnd_vt_grapheme_add(mnd_vt *vt, uint32_t base, uint32_t mark);

#endif /* MND_VT_INTERNAL_H */
