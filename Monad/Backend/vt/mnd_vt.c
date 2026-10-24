/*
 * mnd_vt.c — lifecycle, the DEC/ANSI parser (Paul Williams' state machine,
 * https://vt100.net/emu/dec_ansi_parser) and control-function dispatch.
 */
#include "mnd_vt_internal.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static inline int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

/* ---- Small buffers --------------------------------------------------------- */

bool mnd_buf_append(mnd_buf *b, const void *data, size_t len) {
    if (len == 0) return true;
    if (b->len + len + 1 > b->cap) {
        size_t ncap = b->cap ? b->cap : 64;
        while (ncap < b->len + len + 1) ncap *= 2;
        char *p = realloc(b->data, ncap);
        if (!p) return false;
        b->data = p;
        b->cap = ncap;
    }
    memcpy(b->data + b->len, data, len);
    b->len += len;
    b->data[b->len] = '\0';
    return true;
}

void mnd_buf_free(mnd_buf *b) {
    free(b->data);
    b->data = NULL;
    b->len = b->cap = 0;
}

void mnd_vt_reply(mnd_vt *vt, const char *fmt, ...) {
    char tmp[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    if ((size_t)n >= sizeof tmp) n = (int)sizeof tmp - 1;
    mnd_buf_append(&vt->reply, tmp, (size_t)n);
}

static size_t utf8_encode(uint32_t cp, char out[4]) {
    if (cp < 0x80) {
        out[0] = (char)cp;
        return 1;
    }
    if (cp < 0x800) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = (char)(0xE0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (cp >> 18));
    out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
}

/* ---- Defaults and reset ------------------------------------------------------ */

static void default_palette(uint32_t pal[256]) {
    static const uint32_t base16[16] = {
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    };
    for (int i = 0; i < 16; i++) pal[i] = base16[i];
    static const uint8_t steps[6] = {0, 95, 135, 175, 215, 255};
    for (int i = 0; i < 216; i++) {
        uint32_t r = steps[(i / 36) % 6], g = steps[(i / 6) % 6], b = steps[i % 6];
        pal[16 + i] = (r << 16) | (g << 8) | b;
    }
    for (int i = 0; i < 24; i++) {
        uint32_t v = (uint32_t)(8 + i * 10);
        pal[232 + i] = (v << 16) | (v << 8) | v;
    }
}

static void reset_cursor_state(mnd_cursor_state *c) {
    memset(c, 0, sizeof *c);
    c->pen.fg = MND_COLOR_DEFAULT;
    c->pen.bg = MND_COLOR_DEFAULT;
}

static void reset_modes(mnd_vt *vt) {
    vt->autowrap = true;
    vt->insert = false;
    vt->lnm = false;
    vt->app_cursor = false;
    vt->app_keypad = false;
    vt->cursor_visible = true;
    vt->cursor_blink = false;
    vt->bracketed_paste = false;
    vt->focus_events = false;
    vt->sync_output = false;
    vt->reverse_video = false;
    vt->alt_scroll = true;
    vt->mouse = MND_MOUSE_OFF;
    vt->mouse_enc = MOUSE_ENC_DEFAULT;
    vt->cursor_shape = MND_CURSOR_BLOCK;
    vt->cursor_styled = false;
    vt->modify_other_keys = 0;
}

static void clear_parser(mnd_vt *vt) {
    vt->nparams = 0;
    vt->param_overflow = false;
    vt->ninter = 0;
    vt->marker = 0;
    vt->str_esc = false;
}

static void full_reset(mnd_vt *vt) {
    if (vt->in_alt) mnd_vt_leave_alt(vt, true);
    reset_cursor_state(&vt->cur);
    reset_cursor_state(&vt->saved_prim);
    reset_cursor_state(&vt->saved_alt);
    vt->saved_prim_valid = vt->saved_alt_valid = false;
    reset_modes(vt);
    vt->top = 0;
    vt->bottom = vt->rows - 1;
    mnd_vt_reset_tabs(vt);
    mnd_vt_erase_display(vt, 2);
    vt->state = ST_GROUND;
    clear_parser(vt);
    vt->view_offset = 0;
    vt->all_dirty = true;
}

static void soft_reset(mnd_vt *vt) {
    vt->cursor_visible = true;
    vt->cur.origin = false;
    vt->autowrap = true;
    vt->insert = false;
    vt->app_cursor = false;
    vt->app_keypad = false;
    vt->top = 0;
    vt->bottom = vt->rows - 1;
    vt->cur.pen = (mnd_cell){0, MND_COLOR_DEFAULT, MND_COLOR_DEFAULT, 0, 0};
    vt->cur.charset[0] = vt->cur.charset[1] = CHARSET_ASCII;
    vt->cur.gl = 0;
    reset_cursor_state(vt->in_alt ? &vt->saved_alt : &vt->saved_prim);
}

/* ---- Lifecycle ------------------------------------------------------------------ */

mnd_vt *mnd_vt_create(int cols, int rows, int scrollback, const mnd_vt_callbacks *cb) {
    if (cols < 1 || rows < 1 || cols > MND_MAX_DIM || rows > MND_MAX_DIM || scrollback < 0) return NULL;
    mnd_vt *vt = calloc(1, sizeof *vt);
    if (!vt) return NULL;
    if (pthread_mutex_init(&vt->mu, NULL) != 0) {
        free(vt);
        return NULL;
    }
    if (cb) vt->cb = *cb;
    vt->cell_px_w = 8;
    vt->cell_px_h = 16;
    vt->sb_cap = scrollback;
    if (scrollback > 0) {
        vt->sb = calloc((size_t)scrollback, sizeof(mnd_line *));
        if (!vt->sb) goto fail;
    }
    reset_cursor_state(&vt->cur);
    if (!mnd_vt_alloc_screens(vt, cols, rows)) goto fail;
    reset_modes(vt);
    default_palette(vt->palette);
    vt->theme_fg = 0xE5E5E5;
    vt->theme_bg = 0x000000;
    return vt;
fail:
    free(vt->sb);
    pthread_mutex_destroy(&vt->mu);
    free(vt);
    return NULL;
}

void mnd_vt_destroy(mnd_vt *vt) {
    if (!vt) return;
    mnd_vt_sb_clear(vt);
    free(vt->sb);
    mnd_vt_free_screens(vt);
    mnd_buf_free(&vt->osc);
    mnd_buf_free(&vt->dcs);
    mnd_buf_free(&vt->reply);
    mnd_buf_free(&vt->ev_clip);
    for (int i = 0; i < vt->nev_images; i++) mnd_buf_free(&vt->ev_images[i].data);
    free(vt->graphemes);
    for (int i = 0; i < vt->nlinks; i++) free(vt->links[i]);
    free(vt->links);
    free(vt->title);
    for (int i = 0; i < vt->title_depth; i++) free(vt->title_stack[i]);
    free(vt->ev_title);
    free(vt->ev_cwd);
    pthread_mutex_destroy(&vt->mu);
    free(vt);
}

void mnd_vt_set_callbacks(mnd_vt *vt, const mnd_vt_callbacks *cb) {
    mnd_vt_lock(vt);
    if (cb) vt->cb = *cb;
    else memset(&vt->cb, 0, sizeof vt->cb);
    mnd_vt_unlock(vt);
}

void mnd_vt_lock(mnd_vt *vt) { pthread_mutex_lock(&vt->mu); }
void mnd_vt_unlock(mnd_vt *vt) { pthread_mutex_unlock(&vt->mu); }

/* ---- Parameters ------------------------------------------------------------------ */

static int param(const mnd_vt *vt, int i, int def) {
    if (i >= vt->nparams || vt->params[i] < 0) return def;
    return vt->params[i];
}

/* Like param() but 0 also means the default (cursor counts etc.). */
static int param1(const mnd_vt *vt, int i) {
    int v = param(vt, i, 1);
    return v == 0 ? 1 : v;
}

static void param_digit(mnd_vt *vt, uint32_t cp) {
    if (vt->nparams == 0) {
        vt->nparams = 1;
        vt->params[0] = -1;
        vt->param_sub[0] = false;
    }
    int32_t *p = &vt->params[vt->nparams - 1];
    int32_t v = *p < 0 ? 0 : *p;
    v = v * 10 + (int32_t)(cp - '0');
    if (v > 65535) v = 65535;
    *p = v;
}

static void param_sep(mnd_vt *vt, uint32_t cp) {
    if (vt->nparams == 0) {
        vt->nparams = 1;
        vt->params[0] = -1;
    }
    vt->param_sub[vt->nparams - 1] = (cp == ':');
    if (vt->nparams < MND_MAX_PARAMS) {
        vt->params[vt->nparams] = -1;
        vt->param_sub[vt->nparams] = false;
        vt->nparams++;
    } else {
        vt->param_overflow = true;
    }
}

static void collect(mnd_vt *vt, uint32_t cp) {
    if (vt->ninter < MND_MAX_INTERMEDIATES) vt->inter[vt->ninter++] = (char)cp;
}

static char inter0(const mnd_vt *vt) { return vt->ninter > 0 ? vt->inter[0] : 0; }

/* ---- SGR -------------------------------------------------------------------------- */

/* Parse an extended color starting at params[*i] (the 38/48/58 selector).
 * Handles both "38;5;n" / "38;2;r;g;b" and the colon forms "38:5:n",
 * "38:2::r:g:b" and "38:2:r:g:b". Advances *i to the last consumed param. */
static bool parse_ext_color(mnd_vt *vt, int *i, uint32_t *out) {
    int k = *i;
    bool colon = vt->param_sub[k];
    if (colon) {
        int n = 0;
        int sub[8];
        int j = k;
        while (j < vt->nparams && vt->param_sub[j] && n < 8) {
            j++;
            sub[n++] = vt->params[j];
        }
        *i = j;
        if (n >= 2 && sub[0] == 5) {
            *out = MND_COLOR_INDEX(clampi(sub[1], 0, 255));
            return true;
        }
        if (sub[0] == 2 && (n == 4 || n >= 5)) {
            int o = n >= 5 ? 2 : 1; /* optional color-space id */
            int r = sub[o] < 0 ? 0 : sub[o], g = sub[o + 1] < 0 ? 0 : sub[o + 1], b = sub[o + 2] < 0 ? 0 : sub[o + 2];
            *out = MND_COLOR_RGB(clampi(r, 0, 255), clampi(g, 0, 255), clampi(b, 0, 255));
            return true;
        }
        return false;
    }
    int mode = param(vt, k + 1, -1);
    if (mode == 5) {
        *out = MND_COLOR_INDEX(clampi(param(vt, k + 2, 0), 0, 255));
        *i = k + 2;
        return true;
    }
    if (mode == 2) {
        int r = param(vt, k + 2, 0), g = param(vt, k + 3, 0), b = param(vt, k + 4, 0);
        *out = MND_COLOR_RGB(clampi(r, 0, 255), clampi(g, 0, 255), clampi(b, 0, 255));
        *i = k + 4;
        return true;
    }
    *i = k + 1;
    return false;
}

static void set_underline(mnd_cell *pen, unsigned style) {
    pen->attrs = (uint16_t)((pen->attrs & ~MND_ATTR_UNDERLINE_MASK) | ((style & 7u) << MND_ATTR_UNDERLINE_SHIFT));
}

static void sgr(mnd_vt *vt) {
    mnd_cell *pen = &vt->cur.pen;
    if (vt->nparams == 0) {
        pen->fg = pen->bg = MND_COLOR_DEFAULT;
        pen->attrs = 0;
        return;
    }
    for (int i = 0; i < vt->nparams; i++) {
        int p = vt->params[i] < 0 ? 0 : vt->params[i];
        uint32_t color;
        switch (p) {
        case 0:
            pen->fg = pen->bg = MND_COLOR_DEFAULT;
            pen->attrs = 0;
            break;
        case 1: pen->attrs |= MND_ATTR_BOLD; break;
        case 2: pen->attrs |= MND_ATTR_DIM; break;
        case 3: pen->attrs |= MND_ATTR_ITALIC; break;
        case 4:
            if (vt->param_sub[i] && i + 1 < vt->nparams) {
                i++;
                int s = vt->params[i] < 0 ? 0 : vt->params[i];
                set_underline(pen, s <= 5 ? (unsigned)s : MND_UNDERLINE_SINGLE);
                while (vt->param_sub[i] && i + 1 < vt->nparams) i++;
            } else {
                set_underline(pen, MND_UNDERLINE_SINGLE);
            }
            break;
        case 5:
        case 6: pen->attrs |= MND_ATTR_BLINK; break;
        case 7: pen->attrs |= MND_ATTR_INVERSE; break;
        case 8: pen->attrs |= MND_ATTR_HIDDEN; break;
        case 9: pen->attrs |= MND_ATTR_STRIKE; break;
        case 21: set_underline(pen, MND_UNDERLINE_DOUBLE); break;
        case 22: pen->attrs &= (uint16_t)~(MND_ATTR_BOLD | MND_ATTR_DIM); break;
        case 23: pen->attrs &= (uint16_t)~MND_ATTR_ITALIC; break;
        case 24: set_underline(pen, MND_UNDERLINE_NONE); break;
        case 25: pen->attrs &= (uint16_t)~MND_ATTR_BLINK; break;
        case 27: pen->attrs &= (uint16_t)~MND_ATTR_INVERSE; break;
        case 28: pen->attrs &= (uint16_t)~MND_ATTR_HIDDEN; break;
        case 29: pen->attrs &= (uint16_t)~MND_ATTR_STRIKE; break;
        case 38:
            if (parse_ext_color(vt, &i, &color)) pen->fg = color;
            break;
        case 39: pen->fg = MND_COLOR_DEFAULT; break;
        case 48:
            if (parse_ext_color(vt, &i, &color)) pen->bg = color;
            break;
        case 49: pen->bg = MND_COLOR_DEFAULT; break;
        case 53: pen->attrs |= MND_ATTR_OVERLINE; break;
        case 55: pen->attrs &= (uint16_t)~MND_ATTR_OVERLINE; break;
        case 58: /* underline color: parsed and ignored */
            parse_ext_color(vt, &i, &color);
            break;
        default:
            if (p >= 30 && p <= 37) pen->fg = MND_COLOR_INDEX(p - 30);
            else if (p >= 40 && p <= 47) pen->bg = MND_COLOR_INDEX(p - 40);
            else if (p >= 90 && p <= 97) pen->fg = MND_COLOR_INDEX(p - 90 + 8);
            else if (p >= 100 && p <= 107) pen->bg = MND_COLOR_INDEX(p - 100 + 8);
            /* Skip any unknown subparameters. */
            while (vt->param_sub[i] && i + 1 < vt->nparams) i++;
            break;
        }
    }
}

/* ---- Modes -------------------------------------------------------------------- */

/* Returns 1 set, 2 reset, 0 unknown (DECRQM semantics). */
static int dec_mode_state(const mnd_vt *vt, int mode) {
    switch (mode) {
    case 1: return vt->app_cursor ? 1 : 2;
    case 5: return vt->reverse_video ? 1 : 2;
    case 6: return vt->cur.origin ? 1 : 2;
    case 7: return vt->autowrap ? 1 : 2;
    case 9: return vt->mouse == MND_MOUSE_X10 ? 1 : 2;
    case 12: return vt->cursor_blink ? 1 : 2;
    case 25: return vt->cursor_visible ? 1 : 2;
    case 47:
    case 1047:
    case 1049: return vt->in_alt ? 1 : 2;
    case 66: return vt->app_keypad ? 1 : 2;
    case 1000: return vt->mouse == MND_MOUSE_NORMAL ? 1 : 2;
    case 1002: return vt->mouse == MND_MOUSE_BUTTON ? 1 : 2;
    case 1003: return vt->mouse == MND_MOUSE_ANY ? 1 : 2;
    case 1004: return vt->focus_events ? 1 : 2;
    case 1005: return vt->mouse_enc == MOUSE_ENC_UTF8 ? 1 : 2;
    case 1006: return vt->mouse_enc == MOUSE_ENC_SGR ? 1 : 2;
    case 1007: return vt->alt_scroll ? 1 : 2;
    case 1015: return vt->mouse_enc == MOUSE_ENC_URXVT ? 1 : 2;
    case 2004: return vt->bracketed_paste ? 1 : 2;
    case 2026: return vt->sync_output ? 1 : 2;
    default: return 0;
    }
}

static void set_dec_mode(mnd_vt *vt, int mode, bool on) {
    switch (mode) {
    case 1: vt->app_cursor = on; break;
    case 3: /* DECCOLM: ignored, but xterm clears the screen */ break;
    case 5:
        vt->reverse_video = on;
        vt->all_dirty = true;
        break;
    case 6:
        vt->cur.origin = on;
        mnd_vt_move_to_origin(vt, 0, 0);
        break;
    case 7:
        vt->autowrap = on;
        if (!on) vt->cur.wrapnext = false;
        break;
    case 9: vt->mouse = on ? MND_MOUSE_X10 : MND_MOUSE_OFF; break;
    case 12: vt->cursor_blink = on; break;
    case 25:
        vt->cursor_visible = on;
        mnd_vt_mark_dirty(vt, vt->cur.y);
        break;
    case 47:
        if (on) mnd_vt_enter_alt(vt, false);
        else mnd_vt_leave_alt(vt, false);
        break;
    case 1047:
        if (on) mnd_vt_enter_alt(vt, false);
        else mnd_vt_leave_alt(vt, true);
        break;
    case 1048:
        if (on) mnd_vt_save_cursor(vt);
        else mnd_vt_restore_cursor(vt);
        break;
    case 1049:
        if (on) {
            if (!vt->in_alt) {
                mnd_vt_save_cursor(vt);
                mnd_vt_enter_alt(vt, true);
            }
        } else if (vt->in_alt) {
            mnd_vt_leave_alt(vt, false);
            mnd_vt_restore_cursor(vt);
        }
        break;
    case 66: vt->app_keypad = on; break;
    case 1000: vt->mouse = on ? MND_MOUSE_NORMAL : MND_MOUSE_OFF; break;
    case 1002: vt->mouse = on ? MND_MOUSE_BUTTON : MND_MOUSE_OFF; break;
    case 1003: vt->mouse = on ? MND_MOUSE_ANY : MND_MOUSE_OFF; break;
    case 1004: vt->focus_events = on; break;
    case 1005: vt->mouse_enc = on ? MOUSE_ENC_UTF8 : MOUSE_ENC_DEFAULT; break;
    case 1006: vt->mouse_enc = on ? MOUSE_ENC_SGR : MOUSE_ENC_DEFAULT; break;
    case 1007: vt->alt_scroll = on; break;
    case 1015: vt->mouse_enc = on ? MOUSE_ENC_URXVT : MOUSE_ENC_DEFAULT; break;
    case 2004: vt->bracketed_paste = on; break;
    case 2026:
        vt->sync_output = on;
        if (!on) vt->all_dirty = true;
        break;
    default: break;
    }
}

static void set_ansi_mode(mnd_vt *vt, int mode, bool on) {
    switch (mode) {
    case 4: vt->insert = on; break;
    case 20: vt->lnm = on; break;
    default: break;
    }
}

/* ---- CSI dispatch ---------------------------------------------------------------- */

static void report_cursor(mnd_vt *vt, bool dec) {
    int y = vt->cur.y + 1, x = vt->cur.x + 1;
    if (vt->cur.origin) y -= vt->top;
    mnd_vt_reply(vt, dec ? "\x1b[?%d;%dR" : "\x1b[%d;%dR", y, x);
}

static void title_push(mnd_vt *vt) {
    if (vt->title_depth >= MND_TITLE_STACK) {
        free(vt->title_stack[0]);
        memmove(&vt->title_stack[0], &vt->title_stack[1], (MND_TITLE_STACK - 1) * sizeof(char *));
        vt->title_depth--;
    }
    vt->title_stack[vt->title_depth++] = vt->title ? strdup(vt->title) : NULL;
}

static void set_title(mnd_vt *vt, const char *t);

static void title_pop(mnd_vt *vt) {
    if (vt->title_depth == 0) return;
    char *t = vt->title_stack[--vt->title_depth];
    set_title(vt, t ? t : "");
    free(t);
}

static void csi_dispatch(mnd_vt *vt, uint32_t final) {
    char in = inter0(vt);
    char mk = vt->marker;

    if (mk == '?') {
        switch (final) {
        case 'h':
        case 'l':
            if (in) return;
            for (int i = 0; i < vt->nparams; i++)
                if (vt->params[i] >= 0) set_dec_mode(vt, vt->params[i], final == 'h');
            return;
        case 'J':
            mnd_vt_erase_display(vt, param(vt, 0, 0));
            return;
        case 'K':
            mnd_vt_erase_line(vt, param(vt, 0, 0));
            return;
        case 'n':
            if (param(vt, 0, 0) == 6) report_cursor(vt, true);
            return;
        case 'p':
            if (in == '$') {
                int m = param(vt, 0, 0);
                mnd_vt_reply(vt, "\x1b[?%d;%d$y", m, dec_mode_state(vt, m));
            }
            return;
        default:
            return; /* ?u (kitty keyboard query), ?r/?s mode save: unsupported */
        }
    }
    if (mk == '>') {
        switch (final) {
        case 'c':
            mnd_vt_reply(vt, "\x1b[>1;10;0c");
            break;
        case 'q':
            mnd_vt_reply(vt, "\x1bP>|Monad 0.1\x1b\\");
            break;
        case 'm':
            if (param(vt, 0, -1) == 4) vt->modify_other_keys = param(vt, 1, 0);
            break;
        case 'n':
            if (param(vt, 0, -1) == 4) vt->modify_other_keys = 0;
            break;
        default:
            break;
        }
        return;
    }
    if (mk) return; /* '=' and '<' sequences are not supported */

    if (in == ' ') {
        if (final == 'q') { /* DECSCUSR */
            int s = param(vt, 0, 0);
            vt->cursor_styled = s >= 1 && s <= 6;
            switch (s) {
            case 0: /* the terminal's default: the user's theme and settings */
                vt->cursor_shape = MND_CURSOR_BLOCK;
                vt->cursor_blink = false;
                break;
            case 1: vt->cursor_shape = MND_CURSOR_BLOCK; vt->cursor_blink = true; break;
            case 2: vt->cursor_shape = MND_CURSOR_BLOCK; vt->cursor_blink = false; break;
            case 3: vt->cursor_shape = MND_CURSOR_UNDERLINE; vt->cursor_blink = true; break;
            case 4: vt->cursor_shape = MND_CURSOR_UNDERLINE; vt->cursor_blink = false; break;
            case 5: vt->cursor_shape = MND_CURSOR_BAR; vt->cursor_blink = true; break;
            case 6: vt->cursor_shape = MND_CURSOR_BAR; vt->cursor_blink = false; break;
            default: break;
            }
            mnd_vt_mark_dirty(vt, vt->cur.y);
        }
        return;
    }
    if (in == '!') {
        if (final == 'p') soft_reset(vt);
        return;
    }
    if (in == '$') {
        if (final == 'p') {
            int m = param(vt, 0, 0);
            int st = 0;
            if (m == 4) st = vt->insert ? 1 : 2;
            else if (m == 20) st = vt->lnm ? 1 : 2;
            mnd_vt_reply(vt, "\x1b[%d;%d$y", m, st);
        }
        return;
    }
    if (in) return;

    switch (final) {
    case '@': mnd_vt_insert_chars(vt, param1(vt, 0)); break;
    case 'A': mnd_vt_move_rel(vt, 0, -param1(vt, 0)); break;
    case 'B':
    case 'e': mnd_vt_move_rel(vt, 0, param1(vt, 0)); break;
    case 'C':
    case 'a': mnd_vt_move_rel(vt, param1(vt, 0), 0); break;
    case 'D': mnd_vt_move_rel(vt, -param1(vt, 0), 0); break;
    case 'E':
        mnd_vt_move_rel(vt, 0, param1(vt, 0));
        vt->cur.x = 0;
        break;
    case 'F':
        mnd_vt_move_rel(vt, 0, -param1(vt, 0));
        vt->cur.x = 0;
        break;
    case 'G':
    case '`':
        vt->cur.x = clampi(param1(vt, 0) - 1, 0, vt->cols - 1);
        vt->cur.wrapnext = false;
        break;
    case 'H':
    case 'f': mnd_vt_move_to_origin(vt, param1(vt, 1) - 1, param1(vt, 0) - 1); break;
    case 'I': mnd_vt_tab(vt, param1(vt, 0)); break;
    case 'J': mnd_vt_erase_display(vt, param(vt, 0, 0)); break;
    case 'K': mnd_vt_erase_line(vt, param(vt, 0, 0)); break;
    case 'L': mnd_vt_insert_lines(vt, param1(vt, 0)); break;
    case 'M': mnd_vt_delete_lines(vt, param1(vt, 0)); break;
    case 'P': mnd_vt_delete_chars(vt, param1(vt, 0)); break;
    case 'S': {
        bool saved = vt->in_alt; /* SU does not feed scrollback */
        vt->in_alt = true;
        mnd_vt_scroll_up(vt, vt->top, vt->bottom, param1(vt, 0));
        vt->in_alt = saved;
        break;
    }
    case 'T':
        if (vt->nparams <= 1) mnd_vt_scroll_down(vt, vt->top, vt->bottom, param1(vt, 0));
        break;
    case 'X': mnd_vt_erase_chars(vt, param1(vt, 0)); break;
    case 'Z': mnd_vt_back_tab(vt, param1(vt, 0)); break;
    case 'b': /* REP */
        if (vt->last_printed) {
            int n = clampi(param1(vt, 0), 1, 65535);
            uint32_t cp = vt->last_printed;
            for (int i = 0; i < n; i++) mnd_vt_print(vt, cp);
        }
        break;
    case 'c':
        if (param(vt, 0, 0) == 0) mnd_vt_reply(vt, "\x1b[?62;22c");
        break;
    case 'd':
        mnd_vt_move_to_origin(vt, vt->cur.x, param1(vt, 0) - 1);
        break;
    case 'g': {
        int m = param(vt, 0, 0);
        if (m == 0) vt->tabs[vt->cur.x] = 0;
        else if (m == 3) memset(vt->tabs, 0, (size_t)vt->cols);
        break;
    }
    case 'h':
    case 'l':
        for (int i = 0; i < vt->nparams; i++)
            if (vt->params[i] >= 0) set_ansi_mode(vt, vt->params[i], final == 'h');
        break;
    case 'm': sgr(vt); break;
    case 'n':
        switch (param(vt, 0, 0)) {
        case 5: mnd_vt_reply(vt, "\x1b[0n"); break;
        case 6: report_cursor(vt, false); break;
        default: break;
        }
        break;
    case 'r': {
        int top = param1(vt, 0) - 1;
        int bottom = param(vt, 1, vt->rows);
        if (bottom == 0) bottom = vt->rows;
        bottom = clampi(bottom, 1, vt->rows) - 1;
        top = clampi(top, 0, vt->rows - 1);
        if (top < bottom) {
            vt->top = top;
            vt->bottom = bottom;
            mnd_vt_move_to_origin(vt, 0, 0);
        }
        break;
    }
    case 's': mnd_vt_save_cursor(vt); break;
    case 'u': mnd_vt_restore_cursor(vt); break;
    case 't':
        switch (param(vt, 0, 0)) {
        /* The text area and a cell in pixels: only while images are on
         * (programs size images with them; otherwise nobody's business). */
        case 14:
            if (vt->images_on) mnd_vt_reply(vt, "\x1b[4;%d;%dt", vt->rows * vt->cell_px_h, vt->cols * vt->cell_px_w);
            break;
        case 16:
            if (vt->images_on) mnd_vt_reply(vt, "\x1b[6;%d;%dt", vt->cell_px_h, vt->cell_px_w);
            break;
        case 18: mnd_vt_reply(vt, "\x1b[8;%d;%dt", vt->rows, vt->cols); break;
        case 22: title_push(vt); break;
        case 23: title_pop(vt); break;
        default: break;
        }
        break;
    default:
        break;
    }
}

/* ---- ESC dispatch ------------------------------------------------------------- */

static void esc_dispatch(mnd_vt *vt, uint32_t final) {
    char in = inter0(vt);
    if (in == '(' || in == ')') {
        int g = in == '(' ? 0 : 1;
        vt->cur.charset[g] = final == '0' ? CHARSET_DEC_SPECIAL : CHARSET_ASCII;
        return;
    }
    if (in == '#') {
        if (final == '8') mnd_vt_alignment_test(vt);
        return;
    }
    if (in) return;
    switch (final) {
    case '7': mnd_vt_save_cursor(vt); break;
    case '8': mnd_vt_restore_cursor(vt); break;
    case 'D': mnd_vt_index(vt); break;
    case 'E':
        mnd_vt_carriage_return(vt);
        mnd_vt_index(vt);
        break;
    case 'H': vt->tabs[vt->cur.x] = 1; break;
    case 'M': mnd_vt_reverse_index(vt); break;
    case 'c': full_reset(vt); break;
    case '=': vt->app_keypad = true; break;
    case '>': vt->app_keypad = false; break;
    default: break;
    }
}

/* ---- OSC ------------------------------------------------------------------------- */

/* Controls a title must not carry: C0, DEL and C1, and the bidirectional
 * marks, embeddings, overrides and isolates (they reorder what is shown). */
static bool title_drops(uint32_t cp) {
    return cp < 0x20 || (cp >= 0x7F && cp <= 0x9F) || cp == 0x061C || cp == 0x200E || cp == 0x200F ||
           (cp >= 0x202A && cp <= 0x202E) || (cp >= 0x2066 && cp <= 0x2069);
}

/* The title is UTF-8 the parser encoded itself (string_put), so it is well
 * formed; each code point is kept or dropped whole. */
static void set_title(mnd_vt *vt, const char *t) {
    size_t n = strlen(t);
    if (n > 1024) n = 1024;
    char *clean = malloc(n + 1);
    if (!clean) return;
    size_t j = 0;
    for (size_t i = 0; i < n;) {
        unsigned char c = (unsigned char)t[i];
        size_t len = c < 0x80 ? 1 : c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : 2;
        if (i + len > n) break; /* cut by the length limit */
        uint32_t cp = len == 1 ? c : len == 2 ? c & 0x1Fu : len == 3 ? c & 0x0Fu : c & 0x07u;
        for (size_t k = 1; k < len; k++) cp = cp << 6 | ((unsigned char)t[i + k] & 0x3Fu);
        if (!title_drops(cp)) {
            memcpy(clean + j, t + i, len);
            j += len;
        }
        i += len;
    }
    clean[j] = '\0';
    free(vt->title);
    vt->title = clean;
    free(vt->ev_title);
    vt->ev_title = strdup(clean);
}

static int b64_val(unsigned char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

bool mnd_b64_decode(const char *in, size_t max, mnd_buf *out) {
    /* Room for all of it at once: an image is megabytes. */
    size_t room = strlen(in) / 4 * 3 + 3;
    if (room > max) room = max;
    if (out->cap < room + 1) {
        char *p = realloc(out->data, room + 1);
        if (!p) return false;
        out->data = p;
        out->cap = room + 1;
        out->data[out->len] = '\0';
    }
    uint32_t acc = 0;
    int bits = 0;
    for (const unsigned char *p = (const unsigned char *)in; *p; p++) {
        if (*p == '=') break;
        int v = b64_val(*p);
        if (v < 0) {
            if (*p == '\n' || *p == '\r' || *p == ' ') continue;
            return false;
        }
        acc = (acc << 6) | (uint32_t)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (out->len >= max) return false;
            char c = (char)((acc >> bits) & 0xFF);
            if (!mnd_buf_append(out, &c, 1)) return false;
        }
    }
    return true;
}

static void reply_color(mnd_vt *vt, const char *prefix, uint32_t rgb, bool bel) {
    unsigned r = (rgb >> 16) & 0xFF, g = (rgb >> 8) & 0xFF, b = rgb & 0xFF;
    mnd_vt_reply(vt, "\x1b]%s;rgb:%02x%02x/%02x%02x/%02x%02x%s", prefix, r, r, g, g, b, b, bel ? "\a" : "\x1b\\");
}

static uint16_t intern_link(mnd_vt *vt, const char *uri) {
    size_t len = strnlen(uri, MND_VT_LINK_URI_MAX + 1);
    if (len > MND_VT_LINK_URI_MAX) return 0;
    for (uint16_t i = 0; i < vt->nlinks; i++)
        if (strcmp(vt->links[i], uri) == 0) return (uint16_t)(i + 1);
    if (vt->nlinks >= MND_LINK_MAX || vt->link_bytes + len > MND_VT_LINK_BYTES_MAX) return 0;
    if (vt->nlinks % 64 == 0) {
        char **p = realloc(vt->links, (size_t)(vt->nlinks + 64) * sizeof(char *));
        if (!p) return 0;
        vt->links = p;
    }
    char *dup = strdup(uri);
    if (!dup) return 0;
    vt->links[vt->nlinks++] = dup;
    vt->link_bytes += len;
    return vt->nlinks;
}

size_t mnd_vt_link_bytes(mnd_vt *vt) {
    mnd_vt_lock(vt);
    size_t n = vt->link_bytes;
    mnd_vt_unlock(vt);
    return n;
}

static void osc_dispatch(mnd_vt *vt, bool bel) {
    if (vt->osc_overflow || !vt->osc.data) return;
    char *s = vt->osc.data;
    char *semi = strchr(s, ';');
    int code = 0;
    for (char *p = s; *p && p != semi; p++) {
        if (*p < '0' || *p > '9') return;
        code = code * 10 + (*p - '0');
        if (code > 100000) return;
    }
    const char *arg = semi ? semi + 1 : "";

    switch (code) {
    case 0:
    case 2: set_title(vt, arg); break;
    case 4: {
        /* 4;idx;spec[;idx;spec...] — answer queries, ignore sets. */
        char *copy = strdup(arg);
        if (!copy) break;
        char *save = NULL;
        char *idx = strtok_r(copy, ";", &save);
        while (idx) {
            char *spec = strtok_r(NULL, ";", &save);
            if (!spec) break;
            int n = atoi(idx);
            if (n >= 0 && n < 256 && strcmp(spec, "?") == 0) {
                char prefix[16];
                snprintf(prefix, sizeof prefix, "4;%d", n);
                reply_color(vt, prefix, vt->palette[n], bel);
            }
            idx = strtok_r(NULL, ";", &save);
        }
        free(copy);
        break;
    }
    case 7:
        free(vt->ev_cwd);
        vt->ev_cwd = strdup(arg);
        break;
    case 8: {
        const char *uri = strchr(arg, ';');
        if (!uri) break;
        uri++;
        vt->cur.pen.link = *uri ? intern_link(vt, uri) : 0;
        break;
    }
    case 10:
        if (strcmp(arg, "?") == 0) reply_color(vt, "10", vt->theme_fg, bel);
        break;
    case 11:
        if (strcmp(arg, "?") == 0) reply_color(vt, "11", vt->theme_bg, bel);
        break;
    case 12:
        if (strcmp(arg, "?") == 0) reply_color(vt, "12", vt->theme_fg, bel);
        break;
    case 1337: mnd_vt_osc_1337(vt, arg); break;
    case 52: {
        const char *data = strchr(arg, ';');
        if (!data) break;
        data++;
        if (strcmp(data, "?") == 0) break; /* clipboard reads are denied */
        mnd_buf_free(&vt->ev_clip);
        vt->ev_clip_set = mnd_b64_decode(data, MND_OSC_MAX, &vt->ev_clip);
        if (vt->ev_clip_set && !vt->ev_clip.data) mnd_buf_append(&vt->ev_clip, "", 0);
        break;
    }
    default: break;
    }
}

/* ---- DCS ------------------------------------------------------------------------- */

static void dcs_dispatch(mnd_vt *vt) {
    char in = inter0(vt);
    const char *data = vt->dcs.data ? vt->dcs.data : "";
    if (in == '$' && vt->dcs_final == 'q') { /* DECRQSS */
        if (strcmp(data, "r") == 0) {
            mnd_vt_reply(vt, "\x1bP1$r%d;%dr\x1b\\", vt->top + 1, vt->bottom + 1);
        } else if (strcmp(data, " q") == 0) {
            int s = vt->cursor_shape == MND_CURSOR_BLOCK ? 1 : vt->cursor_shape == MND_CURSOR_UNDERLINE ? 3 : 5;
            if (!vt->cursor_blink) s++;
            mnd_vt_reply(vt, "\x1bP1$r%d q\x1b\\", s);
        } else if (strcmp(data, "m") == 0) {
            mnd_vt_reply(vt, "\x1bP1$r0m\x1b\\");
        } else {
            mnd_vt_reply(vt, "\x1bP0$r\x1b\\");
        }
    } else if (in == '+' && vt->dcs_final == 'q') {
        /* XTGETTCAP: nothing known, and nothing of the request repeated (in
         * a host shell the reply would be typed into whatever reads it). */
        mnd_vt_reply(vt, "\x1bP0+r\x1b\\");
    }
}

/* ---- State machine ----------------------------------------------------------------- */

static void execute_c0(mnd_vt *vt, uint32_t c) {
    switch (c) {
    case 0x07: vt->ev_bell++; break;
    case 0x08: mnd_vt_backspace(vt); break;
    case 0x09: mnd_vt_tab(vt, 1); break;
    case 0x0A:
    case 0x0B:
    case 0x0C: mnd_vt_linefeed(vt); break;
    case 0x0D: mnd_vt_carriage_return(vt); break;
    case 0x0E: vt->cur.gl = 1; break;
    case 0x0F: vt->cur.gl = 0; break;
    default: break;
    }
}

static bool in_string_state(const mnd_vt *vt) {
    return vt->state == ST_OSC_STRING || vt->state == ST_DCS_PASSTHROUGH || vt->state == ST_DCS_IGNORE ||
           vt->state == ST_SOS_PM_APC_STRING;
}

static void string_end(mnd_vt *vt, bool bel) {
    switch (vt->state) {
    case ST_OSC_STRING: osc_dispatch(vt, bel); break;
    case ST_DCS_PASSTHROUGH: dcs_dispatch(vt); break;
    default: break;
    }
    mnd_buf_free(&vt->osc);
    mnd_buf_free(&vt->dcs);
    vt->osc_overflow = false;
    vt->state = ST_GROUND;
}

static void enter_escape(mnd_vt *vt) {
    clear_parser(vt);
    vt->state = ST_ESCAPE;
}

static void string_put(mnd_vt *vt, mnd_buf *b, uint32_t cp) {
    if (vt->osc_overflow) return;
    char enc[4];
    size_t n = utf8_encode(cp, enc);
    size_t max = MND_OSC_MAX;
    if (b == &vt->osc && vt->images_on && b->len >= 10 && memcmp(b->data, "1337;File=", 10) == 0) max = MND_OSC_IMAGE_MAX;
    if (b->len + n > max || !mnd_buf_append(b, enc, n)) {
        vt->osc_overflow = true;
        mnd_buf_free(b);
    }
}

static void process(mnd_vt *vt, uint32_t cp) {
    /* A string was interrupted by ESC: "ESC \" is ST, anything else ends the
     * string and starts a new escape sequence. */
    if (vt->str_esc) {
        vt->str_esc = false;
        string_end(vt, false);
        if (cp == '\\') return;
        enter_escape(vt);
    }

    if (cp < 0x20 || cp == 0x7F) {
        if (cp == 0x1B) {
            if (in_string_state(vt)) vt->str_esc = true;
            else enter_escape(vt);
            return;
        }
        if (cp == 0x18 || cp == 0x1A) { /* CAN, SUB */
            if (in_string_state(vt)) {
                mnd_buf_free(&vt->osc);
                mnd_buf_free(&vt->dcs);
                vt->osc_overflow = false;
            }
            vt->state = ST_GROUND;
            return;
        }
        if (vt->state == ST_OSC_STRING) {
            if (cp == 0x07) string_end(vt, true);
            return;
        }
        if (in_string_state(vt)) return;
        if (cp != 0x7F) execute_c0(vt, cp);
        return;
    }

    switch (vt->state) {
    case ST_GROUND:
        if (cp >= 0x80 && cp < 0xA0) return; /* C1 code points are not printable */
        mnd_vt_print(vt, cp);
        return;

    case ST_ESCAPE:
        if (cp >= 0x20 && cp <= 0x2F) {
            collect(vt, cp);
            vt->state = ST_ESCAPE_INTERMEDIATE;
        } else if (cp == '[') {
            clear_parser(vt);
            vt->state = ST_CSI_ENTRY;
        } else if (cp == ']') {
            mnd_buf_free(&vt->osc);
            vt->osc_overflow = false;
            vt->state = ST_OSC_STRING;
        } else if (cp == 'P') {
            clear_parser(vt);
            vt->state = ST_DCS_ENTRY;
        } else if (cp == 'X' || cp == '^' || cp == '_') {
            vt->state = ST_SOS_PM_APC_STRING;
        } else if (cp >= 0x30 && cp <= 0x7E) {
            esc_dispatch(vt, cp);
            vt->state = ST_GROUND;
        } else {
            vt->state = ST_GROUND;
        }
        return;

    case ST_ESCAPE_INTERMEDIATE:
        if (cp >= 0x20 && cp <= 0x2F) {
            collect(vt, cp);
        } else {
            if (cp >= 0x30 && cp <= 0x7E) esc_dispatch(vt, cp);
            vt->state = ST_GROUND;
        }
        return;

    case ST_CSI_ENTRY:
    case ST_CSI_PARAM:
        if (cp >= '0' && cp <= '9') {
            param_digit(vt, cp);
            vt->state = ST_CSI_PARAM;
        } else if (cp == ';' || cp == ':') {
            param_sep(vt, cp);
            vt->state = ST_CSI_PARAM;
        } else if (cp >= 0x3C && cp <= 0x3F) {
            if (vt->state == ST_CSI_ENTRY) {
                vt->marker = (char)cp;
                vt->state = ST_CSI_PARAM;
            } else {
                vt->state = ST_CSI_IGNORE;
            }
        } else if (cp >= 0x20 && cp <= 0x2F) {
            collect(vt, cp);
            vt->state = ST_CSI_INTERMEDIATE;
        } else if (cp >= 0x40 && cp <= 0x7E) {
            if (!vt->param_overflow) csi_dispatch(vt, cp);
            vt->state = ST_GROUND;
        } else {
            vt->state = ST_GROUND;
        }
        return;

    case ST_CSI_INTERMEDIATE:
        if (cp >= 0x20 && cp <= 0x2F) {
            collect(vt, cp);
        } else if (cp >= 0x30 && cp <= 0x3F) {
            vt->state = ST_CSI_IGNORE;
        } else if (cp >= 0x40 && cp <= 0x7E) {
            if (!vt->param_overflow) csi_dispatch(vt, cp);
            vt->state = ST_GROUND;
        } else {
            vt->state = ST_GROUND;
        }
        return;

    case ST_CSI_IGNORE:
        if (cp >= 0x40 && cp <= 0x7E) vt->state = ST_GROUND;
        else if (cp >= 0x80) vt->state = ST_GROUND;
        return;

    case ST_DCS_ENTRY:
    case ST_DCS_PARAM:
    case ST_DCS_INTERMEDIATE:
        if (cp >= '0' && cp <= '9' && vt->state != ST_DCS_INTERMEDIATE) {
            param_digit(vt, cp);
            vt->state = ST_DCS_PARAM;
        } else if ((cp == ';' || cp == ':') && vt->state != ST_DCS_INTERMEDIATE) {
            param_sep(vt, cp);
            vt->state = ST_DCS_PARAM;
        } else if (cp >= 0x3C && cp <= 0x3F && vt->state == ST_DCS_ENTRY) {
            vt->marker = (char)cp;
            vt->state = ST_DCS_PARAM;
        } else if (cp >= 0x20 && cp <= 0x2F) {
            collect(vt, cp);
            vt->state = ST_DCS_INTERMEDIATE;
        } else if (cp >= 0x40 && cp <= 0x7E) {
            vt->dcs_final = (char)cp;
            mnd_buf_free(&vt->dcs);
            vt->osc_overflow = false;
            vt->state = ST_DCS_PASSTHROUGH;
        } else {
            vt->state = ST_DCS_IGNORE;
        }
        return;

    case ST_DCS_PASSTHROUGH:
        if (vt->dcs.len < 4096) string_put(vt, &vt->dcs, cp);
        return;

    case ST_OSC_STRING:
        string_put(vt, &vt->osc, cp);
        return;

    case ST_DCS_IGNORE:
    case ST_SOS_PM_APC_STRING:
        return;
    }
}

/* UTF-8 decoding in front of the state machine. Invalid sequences (overlong,
 * surrogates, out of range, truncated) yield U+FFFD. */
static void feed_byte(mnd_vt *vt, uint8_t b) {
    if (vt->u8_need > 0) {
        if ((b & 0xC0) == 0x80) {
            vt->u8_cp = (vt->u8_cp << 6) | (b & 0x3F);
            if (--vt->u8_need == 0) {
                uint32_t cp = vt->u8_cp;
                if (cp < vt->u8_min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) cp = 0xFFFD;
                process(vt, cp);
            }
            return;
        }
        vt->u8_need = 0;
        process(vt, 0xFFFD);
        /* fall through: reprocess b as a new sequence start */
    }
    if (b < 0x80) {
        process(vt, b);
    } else if ((b & 0xE0) == 0xC0) {
        vt->u8_cp = b & 0x1F;
        vt->u8_need = 1;
        vt->u8_min = 0x80;
    } else if ((b & 0xF0) == 0xE0) {
        vt->u8_cp = b & 0x0F;
        vt->u8_need = 2;
        vt->u8_min = 0x800;
    } else if ((b & 0xF8) == 0xF0) {
        vt->u8_cp = b & 0x07;
        vt->u8_need = 3;
        vt->u8_min = 0x10000;
    } else {
        process(vt, 0xFFFD);
    }
}

void mnd_vt_feed(mnd_vt *vt, const void *data, size_t len) {
    const uint8_t *p = data;
    mnd_vt_lock(vt);
    for (size_t i = 0; i < len; i++) {
        uint8_t b = p[i];
        /* Fast path for printable ASCII in the ground state. */
        if (b >= 0x20 && b < 0x7F && vt->state == ST_GROUND && vt->u8_need == 0 && !vt->str_esc) {
            mnd_vt_print(vt, b);
            continue;
        }
        feed_byte(vt, b);
    }

    /* Collect events, then deliver them without holding the lock. */
    mnd_buf reply = vt->reply;
    vt->reply = (mnd_buf){0};
    char *title = vt->ev_title;
    vt->ev_title = NULL;
    char *cwd = vt->ev_cwd;
    vt->ev_cwd = NULL;
    int bells = vt->ev_bell;
    vt->ev_bell = 0;
    mnd_buf clip = vt->ev_clip;
    bool clip_set = vt->ev_clip_set;
    vt->ev_clip = (mnd_buf){0};
    vt->ev_clip_set = false;
    mnd_image_event images[MND_VT_IMAGE_EVENTS];
    int nimages = vt->nev_images;
    memcpy(images, vt->ev_images, (size_t)nimages * sizeof images[0]);
    vt->nev_images = 0;
    mnd_vt_callbacks cbs = vt->cb;
    mnd_vt_unlock(vt);

    const mnd_vt_callbacks *cb = &cbs;
    if (reply.len && cb->write) cb->write(cb->ctx, reply.data, reply.len);
    if (title && cb->title) cb->title(cb->ctx, title);
    if (cwd && cb->cwd) cb->cwd(cb->ctx, cwd);
    if (bells && cb->bell) cb->bell(cb->ctx);
    if (clip_set && cb->clipboard) cb->clipboard(cb->ctx, clip.data ? clip.data : "", clip.len);
    for (int i = 0; i < nimages; i++) {
        if (cb->image) cb->image(cb->ctx, &images[i].info, (const uint8_t *)images[i].data.data, images[i].data.len);
        mnd_buf_free(&images[i].data);
    }
    mnd_buf_free(&reply);
    mnd_buf_free(&clip);
    free(title);
    free(cwd);
}

/* ---- Public state API ------------------------------------------------------------ */

bool mnd_vt_resize(mnd_vt *vt, int cols, int rows) {
    if (cols < 1 || rows < 1 || cols > MND_MAX_DIM || rows > MND_MAX_DIM) return false;
    mnd_vt_lock(vt);
    bool ok = true;
    if (cols != vt->cols || rows != vt->rows) ok = mnd_vt_reflow(vt, cols, rows);
    mnd_vt_unlock(vt);
    return ok;
}

void mnd_vt_size(mnd_vt *vt, int *cols, int *rows) {
    mnd_vt_lock(vt);
    if (cols) *cols = vt->cols;
    if (rows) *rows = vt->rows;
    mnd_vt_unlock(vt);
}

void mnd_vt_reset(mnd_vt *vt) {
    mnd_vt_lock(vt);
    full_reset(vt);
    mnd_vt_unlock(vt);
}

void mnd_vt_clear_scrollback(mnd_vt *vt) {
    mnd_vt_lock(vt);
    mnd_vt_sb_clear(vt);
    mnd_vt_unlock(vt);
}

void mnd_vt_set_images(mnd_vt *vt, bool on) {
    mnd_vt_lock(vt);
    vt->images_on = on;
    mnd_vt_unlock(vt);
}

void mnd_vt_set_cell_pixels(mnd_vt *vt, int width, int height) {
    if (width < 1 || height < 1 || width > 1024 || height > 1024) return;
    mnd_vt_lock(vt);
    vt->cell_px_w = width;
    vt->cell_px_h = height;
    mnd_vt_unlock(vt);
}

void mnd_vt_set_theme(mnd_vt *vt, const uint32_t palette[256], uint32_t fg, uint32_t bg) {
    mnd_vt_lock(vt);
    if (palette) memcpy(vt->palette, palette, sizeof vt->palette);
    vt->theme_fg = fg & 0xFFFFFF;
    vt->theme_bg = bg & 0xFFFFFF;
    vt->all_dirty = true;
    mnd_vt_unlock(vt);
}

const mnd_cell *mnd_vt_view_row(mnd_vt *vt, int y, int *len) {
    mnd_line *l = mnd_vt_view_line(vt, clampi(y, 0, vt->rows - 1));
    if (len) *len = l->cols;
    return l->cells;
}

bool mnd_vt_view_row_wrapped(mnd_vt *vt, int y) {
    mnd_line *l = mnd_vt_view_line(vt, clampi(y, 0, vt->rows - 1));
    return l->wrapped;
}

mnd_cursor_info mnd_vt_cursor(mnd_vt *vt) {
    mnd_cursor_info ci;
    int off = vt->in_alt ? 0 : vt->view_offset;
    ci.x = vt->cur.x;
    ci.y = vt->cur.y + off;
    ci.visible = vt->cursor_visible && ci.y < vt->rows;
    ci.blink = vt->cursor_blink;
    ci.shape = vt->cursor_shape;
    ci.styled = vt->cursor_styled;
    return ci;
}

bool mnd_vt_take_dirty(mnd_vt *vt, uint8_t *dirty, int rows) {
    bool any = false;
    int n = rows < vt->rows ? rows : vt->rows;
    for (int y = 0; y < n; y++) {
        uint8_t d = vt->all_dirty ? 1 : vt->dirty[y];
        dirty[y] = d;
        any |= d != 0;
    }
    for (int y = n; y < rows; y++) dirty[y] = 1;
    memset(vt->dirty, 0, (size_t)vt->rows);
    vt->all_dirty = false;
    return any || rows > n;
}

size_t mnd_vt_grapheme(mnd_vt *vt, uint32_t cp, uint32_t *out, size_t cap) {
    if (mnd_cp_is_image(cp)) return 0; /* drawn by the front end, no text */
    if (!(cp & MND_CP_GRAPHEME_FLAG)) {
        if (cap > 0) out[0] = cp;
        return 1;
    }
    uint32_t idx = cp & ~MND_CP_GRAPHEME_FLAG;
    if (idx >= vt->ngraphemes) return 0;
    const mnd_grapheme *g = &vt->graphemes[idx];
    for (size_t i = 0; i < g->len && i < cap; i++) out[i] = g->cps[i];
    return g->len;
}

const char *mnd_vt_link_uri(mnd_vt *vt, uint16_t link) {
    if (link == 0 || link > vt->nlinks) return NULL;
    return vt->links[link - 1];
}

bool mnd_vt_mode(mnd_vt *vt, mnd_mode mode) {
    switch (mode) {
    case MND_MODE_APP_CURSOR: return vt->app_cursor;
    case MND_MODE_APP_KEYPAD: return vt->app_keypad;
    case MND_MODE_CURSOR_VISIBLE: return vt->cursor_visible;
    case MND_MODE_CURSOR_BLINK: return vt->cursor_blink;
    case MND_MODE_ALT_SCREEN: return vt->in_alt;
    case MND_MODE_BRACKETED_PASTE: return vt->bracketed_paste;
    case MND_MODE_FOCUS_EVENTS: return vt->focus_events;
    case MND_MODE_SYNC_OUTPUT: return vt->sync_output;
    case MND_MODE_REVERSE_VIDEO: return vt->reverse_video;
    case MND_MODE_ALT_SCROLL: return vt->alt_scroll;
    default: return false;
    }
}

mnd_mouse_tracking mnd_vt_mouse_tracking(mnd_vt *vt) { return vt->mouse; }

int mnd_vt_scroll_offset(mnd_vt *vt) {
    mnd_vt_lock(vt);
    int v = vt->view_offset;
    mnd_vt_unlock(vt);
    return v;
}

int mnd_vt_scrollback_lines(mnd_vt *vt) {
    mnd_vt_lock(vt);
    int v = vt->in_alt ? 0 : vt->sb_count;
    mnd_vt_unlock(vt);
    return v;
}

int mnd_vt_scroll(mnd_vt *vt, int delta) {
    mnd_vt_lock(vt);
    if (!vt->in_alt) {
        int n = clampi(vt->view_offset + delta, 0, vt->sb_count);
        if (n != vt->view_offset) {
            vt->view_offset = n;
            vt->all_dirty = true;
        }
    }
    int v = vt->view_offset;
    mnd_vt_unlock(vt);
    return v;
}

void mnd_vt_scroll_to_bottom(mnd_vt *vt) {
    mnd_vt_lock(vt);
    if (vt->view_offset != 0) {
        vt->view_offset = 0;
        vt->all_dirty = true;
    }
    mnd_vt_unlock(vt);
}

int64_t mnd_vt_view_to_abs_locked(mnd_vt *vt, int y) {
    int off = vt->in_alt ? 0 : vt->view_offset;
    return vt->sb_dropped + vt->sb_count - off + y;
}

int64_t mnd_vt_view_to_abs(mnd_vt *vt, int y) {
    mnd_vt_lock(vt);
    int64_t abs = mnd_vt_view_to_abs_locked(vt, y);
    mnd_vt_unlock(vt);
    return abs;
}

int mnd_vt_abs_to_view_locked(mnd_vt *vt, int64_t line) {
    int off = vt->in_alt ? 0 : vt->view_offset;
    int64_t y = line - (vt->sb_dropped + vt->sb_count - off);
    if (y < 0) return INT32_MIN;
    if (y >= vt->rows) return INT32_MAX;
    return (int)y;
}
