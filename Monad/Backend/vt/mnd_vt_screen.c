/*
 * mnd_vt_screen.c — screen buffers, scrollback, cursor motion, editing
 * operations and reflow. Every function requires the terminal lock.
 */
#include "mnd_vt_internal.h"

#include <stdlib.h>
#include <string.h>

static inline int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

/* ---- Lines -------------------------------------------------------------- */

mnd_line *mnd_line_new(int cols, mnd_cell blank) {
    mnd_line *l = malloc(sizeof(mnd_line) + (size_t)cols * sizeof(mnd_cell));
    if (!l) return NULL;
    l->cols = cols;
    l->wrapped = false;
    for (int i = 0; i < cols; i++) l->cells[i] = blank;
    return l;
}

void mnd_line_fill(mnd_line *l, int from, int to, mnd_cell blank) {
    from = clampi(from, 0, l->cols);
    to = clampi(to, 0, l->cols);
    for (int i = from; i < to; i++) l->cells[i] = blank;
}

static inline unsigned cell_w(const mnd_cell *c) { return mnd_cell_width(c); }

static inline void cell_set_width(mnd_cell *c, unsigned w) {
    c->attrs = (uint16_t)((c->attrs & ~MND_ATTR_WIDTH_MASK) | (w << MND_ATTR_WIDTH_SHIFT));
}

static const mnd_cell kEmptyCell = {0, MND_COLOR_DEFAULT, MND_COLOR_DEFAULT, 0, 0};

mnd_cell mnd_vt_blank(const mnd_vt *vt) {
    mnd_cell c = kEmptyCell;
    c.bg = vt->cur.pen.bg; /* background color erase */
    return c;
}

/* Before overwriting cell x, break any wide glyph it belongs to: its other
 * half goes, and only if it really is that glyph's other half. */
static void fix_wide(mnd_vt *vt, mnd_line *l, int x) {
    if (x < 0 || x >= l->cols) return;
    mnd_cell blank = mnd_vt_blank(vt);
    unsigned w = cell_w(&l->cells[x]);
    if (w == MND_WIDTH_SPACER && x > 0 && cell_w(&l->cells[x - 1]) == MND_WIDTH_WIDE) {
        l->cells[x - 1] = blank;
    } else if (w == MND_WIDTH_WIDE && x + 1 < l->cols && cell_w(&l->cells[x + 1]) == MND_WIDTH_SPACER) {
        l->cells[x + 1] = blank;
    }
}

/* ---- Allocation --------------------------------------------------------- */

static void free_lines(mnd_line **lines, int n) {
    if (!lines) return;
    for (int i = 0; i < n; i++) free(lines[i]);
    free(lines);
}

static mnd_line **alloc_lines(int cols, int rows) {
    mnd_line **lines = calloc((size_t)rows, sizeof(mnd_line *));
    if (!lines) return NULL;
    for (int i = 0; i < rows; i++) {
        lines[i] = mnd_line_new(cols, kEmptyCell);
        if (!lines[i]) {
            free_lines(lines, i);
            return NULL;
        }
    }
    return lines;
}

bool mnd_vt_alloc_screens(mnd_vt *vt, int cols, int rows) {
    mnd_line **prim = alloc_lines(cols, rows);
    mnd_line **alt = alloc_lines(cols, rows);
    uint8_t *tabs = calloc((size_t)cols, 1);
    uint8_t *dirty = calloc((size_t)rows, 1);
    if (!prim || !alt || !tabs || !dirty) {
        free_lines(prim, prim ? rows : 0);
        free_lines(alt, alt ? rows : 0);
        free(tabs);
        free(dirty);
        return false;
    }
    vt->prim = prim;
    vt->alt = alt;
    vt->screen = vt->in_alt ? alt : prim;
    vt->tabs = tabs;
    vt->dirty = dirty;
    vt->cols = cols;
    vt->rows = rows;
    vt->top = 0;
    vt->bottom = rows - 1;
    mnd_vt_reset_tabs(vt);
    vt->all_dirty = true;
    return true;
}

void mnd_vt_free_screens(mnd_vt *vt) {
    free_lines(vt->prim, vt->rows);
    free_lines(vt->alt, vt->rows);
    vt->prim = vt->alt = vt->screen = NULL;
    free(vt->tabs);
    vt->tabs = NULL;
    free(vt->dirty);
    vt->dirty = NULL;
}

void mnd_vt_reset_tabs(mnd_vt *vt) {
    for (int i = 0; i < vt->cols; i++) vt->tabs[i] = (i % 8 == 0 && i != 0) ? 1 : 0;
}

/* ---- Dirty tracking ------------------------------------------------------ */

void mnd_vt_mark_dirty(mnd_vt *vt, int y) {
    if (vt->view_offset != 0) {
        vt->all_dirty = true;
        return;
    }
    if (y >= 0 && y < vt->rows) vt->dirty[y] = 1;
}

void mnd_vt_mark_all_dirty(mnd_vt *vt) { vt->all_dirty = true; }

static void mark_range(mnd_vt *vt, int y0, int y1) {
    for (int y = y0; y <= y1; y++) mnd_vt_mark_dirty(vt, y);
}

/* ---- Scrollback ------------------------------------------------------------ */

static mnd_line *sb_at(const mnd_vt *vt, int i) {
    return vt->sb[(vt->sb_head + i) % vt->sb_cap];
}

/* Takes ownership of l. Returns a recycled line of the same width (or NULL)
 * that the caller may reuse. */
static mnd_line *sb_push(mnd_vt *vt, mnd_line *l) {
    if (vt->sb_cap == 0) return l;
    int limit = mnd_vt_sb_limit(vt->sb_cap, vt->cols);
    mnd_line *evicted = NULL;
    if (vt->sb_count >= limit) {
        /* Drop the oldest line(s); the first one is handed back for reuse. */
        while (vt->sb_count >= limit) {
            mnd_line *old = vt->sb[vt->sb_head];
            vt->sb[vt->sb_head] = NULL;
            vt->sb_head = (vt->sb_head + 1) % vt->sb_cap;
            vt->sb_count--;
            vt->sb_dropped++;
            if (evicted) free(old);
            else evicted = old;
        }
        vt->sb[(vt->sb_head + vt->sb_count) % vt->sb_cap] = l;
        vt->sb_count++;
    } else {
        vt->sb[(vt->sb_head + vt->sb_count) % vt->sb_cap] = l;
        vt->sb_count++;
        if (vt->view_offset > 0) vt->view_offset++;
    }
    if (vt->view_offset > vt->sb_count) vt->view_offset = vt->sb_count;
    return evicted;
}

void mnd_vt_sb_clear(mnd_vt *vt) {
    for (int i = 0; i < vt->sb_count; i++) free(sb_at(vt, i));
    vt->sb_dropped += vt->sb_count;
    vt->sb_count = 0;
    vt->sb_head = 0;
    vt->view_offset = 0;
    vt->all_dirty = true;
}

mnd_line *mnd_vt_abs_line(mnd_vt *vt, int64_t abs) {
    int64_t rel = abs - vt->sb_dropped;
    if (vt->in_alt) {
        rel -= vt->sb_count;
        if (rel < 0 || rel >= vt->rows) return NULL;
        return vt->screen[rel];
    }
    if (rel < 0) return NULL;
    if (rel < vt->sb_count) return sb_at(vt, (int)rel);
    rel -= vt->sb_count;
    if (rel >= vt->rows) return NULL;
    return vt->screen[rel];
}

mnd_line *mnd_vt_view_line(mnd_vt *vt, int y) {
    if (y < 0 || y >= vt->rows) return NULL;
    if (vt->view_offset == 0 || vt->in_alt) return vt->screen[y];
    int idx = vt->sb_count - vt->view_offset + y;
    if (idx < vt->sb_count) return sb_at(vt, idx);
    return vt->screen[idx - vt->sb_count];
}

/* ---- Scrolling ------------------------------------------------------------- */

void mnd_vt_scroll_up(mnd_vt *vt, int top, int bottom, int n) {
    if (top < 0 || bottom >= vt->rows || top > bottom) return;
    int height = bottom - top + 1;
    n = clampi(n, 0, height);
    if (n == 0) return;
    mnd_cell blank = mnd_vt_blank(vt);
    bool to_sb = !vt->in_alt && top == 0 && vt->sb_cap > 0;
    mnd_line **s = vt->screen;
    for (int i = 0; i < n; i++) {
        mnd_line *gone = s[top];
        memmove(&s[top], &s[top + 1], (size_t)(height - 1) * sizeof(mnd_line *));
        mnd_line *fresh = gone;
        if (to_sb) {
            if (vt->sb_count >= mnd_vt_sb_limit(vt->sb_cap, vt->cols)) {
                /* History full: the evicted line is recycled (all lines
                 * share the terminal width, reflow guarantees it). */
                fresh = sb_push(vt, gone);
            } else {
                mnd_line *spare = mnd_line_new(vt->cols, blank);
                if (spare) {
                    sb_push(vt, gone);
                    fresh = spare;
                } /* else OOM: drop this line from history, reuse it */
            }
        }
        mnd_line_fill(fresh, 0, fresh->cols, blank);
        fresh->wrapped = false;
        s[bottom] = fresh;
    }
    if (vt->view_offset > 0) vt->all_dirty = true;
    mark_range(vt, top, bottom);
}

void mnd_vt_scroll_down(mnd_vt *vt, int top, int bottom, int n) {
    if (top < 0 || bottom >= vt->rows || top > bottom) return;
    int height = bottom - top + 1;
    n = clampi(n, 0, height);
    if (n == 0) return;
    mnd_cell blank = mnd_vt_blank(vt);
    mnd_line **s = vt->screen;
    for (int i = 0; i < n; i++) {
        mnd_line *l = s[bottom];
        memmove(&s[top + 1], &s[top], (size_t)(height - 1) * sizeof(mnd_line *));
        mnd_line_fill(l, 0, l->cols, blank);
        l->wrapped = false;
        s[top] = l;
    }
    mark_range(vt, top, bottom);
}

/* ---- Cursor motion ------------------------------------------------------- */

void mnd_vt_linefeed(mnd_vt *vt) {
    mnd_vt_index(vt);
    if (vt->lnm) vt->cur.x = 0;
}

void mnd_vt_index(mnd_vt *vt) {
    vt->cur.wrapnext = false;
    if (vt->cur.y == vt->bottom) {
        mnd_vt_scroll_up(vt, vt->top, vt->bottom, 1);
    } else if (vt->cur.y < vt->rows - 1) {
        vt->cur.y++;
    }
}

void mnd_vt_reverse_index(mnd_vt *vt) {
    vt->cur.wrapnext = false;
    if (vt->cur.y == vt->top) {
        mnd_vt_scroll_down(vt, vt->top, vt->bottom, 1);
    } else if (vt->cur.y > 0) {
        vt->cur.y--;
    }
}

void mnd_vt_carriage_return(mnd_vt *vt) {
    vt->cur.x = 0;
    vt->cur.wrapnext = false;
}

void mnd_vt_backspace(mnd_vt *vt) {
    if (vt->cur.wrapnext) {
        vt->cur.wrapnext = false;
        return;
    }
    if (vt->cur.x > 0) vt->cur.x--;
}

void mnd_vt_tab(mnd_vt *vt, int n) {
    vt->cur.wrapnext = false;
    while (n-- > 0 && vt->cur.x < vt->cols - 1) {
        int x = vt->cur.x + 1;
        while (x < vt->cols - 1 && !vt->tabs[x]) x++;
        vt->cur.x = x;
    }
}

void mnd_vt_back_tab(mnd_vt *vt, int n) {
    vt->cur.wrapnext = false;
    while (n-- > 0 && vt->cur.x > 0) {
        int x = vt->cur.x - 1;
        while (x > 0 && !vt->tabs[x]) x--;
        vt->cur.x = x;
    }
}

void mnd_vt_move_to(mnd_vt *vt, int x, int y) {
    vt->cur.x = clampi(x, 0, vt->cols - 1);
    vt->cur.y = clampi(y, 0, vt->rows - 1);
    vt->cur.wrapnext = false;
}

void mnd_vt_move_to_origin(mnd_vt *vt, int x, int y) {
    if (vt->cur.origin) {
        vt->cur.x = clampi(x, 0, vt->cols - 1);
        vt->cur.y = clampi(y + vt->top, vt->top, vt->bottom);
        vt->cur.wrapnext = false;
    } else {
        mnd_vt_move_to(vt, x, y);
    }
}

void mnd_vt_move_rel(mnd_vt *vt, int dx, int dy) {
    int x = vt->cur.x + dx;
    int y = vt->cur.y;
    if (dy != 0) {
        /* Vertical motion stops at the scroll margins when starting inside. */
        int lo = (y >= vt->top) ? vt->top : 0;
        int hi = (y <= vt->bottom) ? vt->bottom : vt->rows - 1;
        y = clampi(y + dy, lo, hi);
    }
    vt->cur.x = clampi(x, 0, vt->cols - 1);
    vt->cur.y = y;
    vt->cur.wrapnext = false;
}

/* ---- Printing ---------------------------------------------------------------- */

static const uint16_t kDecSpecial[32] = {
    /* 0x5f */ 0x00A0,
    /* 0x60 */ 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, 0x00B1,
    /* 0x68 */ 0x2424, 0x240B, 0x2518, 0x2510, 0x250C, 0x2514, 0x253C, 0x23BA,
    /* 0x70 */ 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534, 0x252C,
    /* 0x78 */ 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7,
};

static void attach_combining(mnd_vt *vt, uint32_t cp) {
    int x = vt->cur.wrapnext ? vt->cur.x : vt->cur.x - 1;
    if (x < 0) return;
    mnd_line *l = vt->screen[vt->cur.y];
    if (cell_w(&l->cells[x]) == MND_WIDTH_SPACER && x > 0) x--;
    mnd_cell *c = &l->cells[x];
    if (c->cp == 0 || mnd_cp_is_image(c->cp)) return;
    uint32_t ref = mnd_vt_grapheme_add(vt, c->cp, cp);
    if (ref) c->cp = ref;
    mnd_vt_mark_dirty(vt, vt->cur.y);
}

void mnd_vt_print(mnd_vt *vt, uint32_t cp) {
    uint8_t cs = vt->cur.charset[vt->cur.gl & 1];
    if (cs == CHARSET_DEC_SPECIAL && cp >= 0x5f && cp <= 0x7e) cp = kDecSpecial[cp - 0x5f];

    int w = mnd_wcwidth(cp);
    if (w == 0) {
        attach_combining(vt, cp);
        return;
    }
    if (w < 0) return;

    if (vt->cur.wrapnext && vt->autowrap) {
        vt->screen[vt->cur.y]->wrapped = true;
        vt->cur.x = 0;
        vt->cur.wrapnext = false;
        mnd_vt_index(vt);
    }

    if (w == 2 && vt->cur.x == vt->cols - 1) {
        if (vt->cols < 2) return;
        if (vt->autowrap) {
            mnd_line *l = vt->screen[vt->cur.y];
            fix_wide(vt, l, vt->cur.x);
            l->cells[vt->cur.x] = mnd_vt_blank(vt);
            l->wrapped = true;
            vt->cur.x = 0;
            mnd_vt_index(vt);
        } else {
            vt->cur.x = vt->cols - 2;
        }
    }

    if (vt->insert) mnd_vt_insert_chars(vt, w);

    mnd_line *l = vt->screen[vt->cur.y];
    int x = vt->cur.x;
    fix_wide(vt, l, x);
    if (w == 2) fix_wide(vt, l, x + 1);

    mnd_cell c = vt->cur.pen;
    c.cp = cp;
    cell_set_width(&c, w == 2 ? MND_WIDTH_WIDE : MND_WIDTH_NORMAL);
    l->cells[x] = c;
    if (w == 2) {
        mnd_cell sp = vt->cur.pen;
        sp.cp = 0;
        cell_set_width(&sp, MND_WIDTH_SPACER);
        l->cells[x + 1] = sp;
    }
    mnd_vt_mark_dirty(vt, vt->cur.y);
    vt->last_printed = cp;

    x += w;
    if (x >= vt->cols) {
        vt->cur.x = vt->cols - 1;
        vt->cur.wrapnext = vt->autowrap;
    } else {
        vt->cur.x = x;
    }
}

void mnd_vt_put_image_row(mnd_vt *vt, int x0, int ncols, uint32_t id, int ty) {
    mnd_line *l = vt->screen[vt->cur.y];
    int x1 = clampi(x0 + ncols, 0, vt->cols);
    x0 = clampi(x0, 0, vt->cols);
    if (x0 >= x1) return;
    fix_wide(vt, l, x0);
    fix_wide(vt, l, x1 - 1);
    for (int x = x0; x < x1; x++) {
        mnd_cell c = kEmptyCell;
        c.cp = MND_CP_IMAGE_FLAG | (id & 0x3FFFu) << 16 | ((uint32_t)ty & 0xFFu) << 8 | ((uint32_t)(x - x0) & 0xFFu);
        l->cells[x] = c;
    }
    mnd_vt_mark_dirty(vt, vt->cur.y);
}

static void scrub_line(mnd_line *l) {
    if (!l) return;
    for (int x = 0; x < l->cols; x++)
        if (mnd_cp_is_image(l->cells[x].cp)) l->cells[x] = kEmptyCell;
}

void mnd_vt_scrub_images(mnd_vt *vt) {
    for (int i = 0; i < vt->sb_count; i++) scrub_line(sb_at(vt, i));
    for (int y = 0; y < vt->rows; y++) {
        scrub_line(vt->prim[y]);
        scrub_line(vt->alt[y]);
    }
    vt->all_dirty = true;
}

/* ---- Erasing and editing -------------------------------------------------- */

static void erase_cells(mnd_vt *vt, int y, int from, int to) {
    mnd_line *l = vt->screen[y];
    from = clampi(from, 0, vt->cols);
    to = clampi(to, 0, vt->cols);
    if (from >= to) return;
    fix_wide(vt, l, from);
    fix_wide(vt, l, to - 1);
    mnd_line_fill(l, from, to, mnd_vt_blank(vt));
    mnd_vt_mark_dirty(vt, y);
}

void mnd_vt_erase_display(mnd_vt *vt, int mode) {
    vt->cur.wrapnext = false;
    switch (mode) {
    case 0:
        erase_cells(vt, vt->cur.y, vt->cur.x, vt->cols);
        vt->screen[vt->cur.y]->wrapped = false;
        for (int y = vt->cur.y + 1; y < vt->rows; y++) {
            erase_cells(vt, y, 0, vt->cols);
            vt->screen[y]->wrapped = false;
        }
        break;
    case 1:
        for (int y = 0; y < vt->cur.y; y++) {
            erase_cells(vt, y, 0, vt->cols);
            vt->screen[y]->wrapped = false;
        }
        erase_cells(vt, vt->cur.y, 0, vt->cur.x + 1);
        break;
    case 2:
        for (int y = 0; y < vt->rows; y++) {
            erase_cells(vt, y, 0, vt->cols);
            vt->screen[y]->wrapped = false;
        }
        break;
    case 3:
        if (!vt->in_alt) mnd_vt_sb_clear(vt);
        break;
    default:
        break;
    }
}

void mnd_vt_erase_line(mnd_vt *vt, int mode) {
    vt->cur.wrapnext = false;
    switch (mode) {
    case 0:
        erase_cells(vt, vt->cur.y, vt->cur.x, vt->cols);
        vt->screen[vt->cur.y]->wrapped = false;
        break;
    case 1:
        erase_cells(vt, vt->cur.y, 0, vt->cur.x + 1);
        break;
    case 2:
        erase_cells(vt, vt->cur.y, 0, vt->cols);
        vt->screen[vt->cur.y]->wrapped = false;
        break;
    default:
        break;
    }
}

void mnd_vt_erase_chars(mnd_vt *vt, int n) {
    n = clampi(n, 1, vt->cols);
    vt->cur.wrapnext = false;
    erase_cells(vt, vt->cur.y, vt->cur.x, vt->cur.x + n);
}

void mnd_vt_insert_chars(mnd_vt *vt, int n) {
    mnd_line *l = vt->screen[vt->cur.y];
    int x = vt->cur.x;
    n = clampi(n, 1, vt->cols - x);
    /* A wide glyph starting at x moves whole; one cut in two goes. */
    if (cell_w(&l->cells[x]) == MND_WIDTH_SPACER && x > 0) {
        if (cell_w(&l->cells[x - 1]) == MND_WIDTH_WIDE) l->cells[x - 1] = mnd_vt_blank(vt);
        l->cells[x] = mnd_vt_blank(vt);
    }
    /* A wide glyph that would be split at the right edge is dropped. */
    if (vt->cols - n - 1 >= x) fix_wide(vt, l, vt->cols - n - 1);
    memmove(&l->cells[x + n], &l->cells[x], (size_t)(vt->cols - x - n) * sizeof(mnd_cell));
    mnd_line_fill(l, x, x + n, mnd_vt_blank(vt));
    if (cell_w(&l->cells[vt->cols - 1]) == MND_WIDTH_WIDE) l->cells[vt->cols - 1] = mnd_vt_blank(vt);
    l->wrapped = false;
    vt->cur.wrapnext = false;
    mnd_vt_mark_dirty(vt, vt->cur.y);
}

void mnd_vt_delete_chars(mnd_vt *vt, int n) {
    mnd_line *l = vt->screen[vt->cur.y];
    int x = vt->cur.x;
    n = clampi(n, 1, vt->cols - x);
    /* A wide glyph the deletion cuts goes: its first half before x, its
     * second half at x + n. One starting at x + n moves whole. */
    if (cell_w(&l->cells[x]) == MND_WIDTH_SPACER && x > 0 && cell_w(&l->cells[x - 1]) == MND_WIDTH_WIDE)
        l->cells[x - 1] = mnd_vt_blank(vt);
    if (x + n < vt->cols && cell_w(&l->cells[x + n]) == MND_WIDTH_SPACER) l->cells[x + n] = mnd_vt_blank(vt);
    memmove(&l->cells[x], &l->cells[x + n], (size_t)(vt->cols - x - n) * sizeof(mnd_cell));
    mnd_line_fill(l, vt->cols - n, vt->cols, mnd_vt_blank(vt));
    l->wrapped = false;
    vt->cur.wrapnext = false;
    mnd_vt_mark_dirty(vt, vt->cur.y);
}

void mnd_vt_insert_lines(mnd_vt *vt, int n) {
    if (vt->cur.y < vt->top || vt->cur.y > vt->bottom) return;
    mnd_vt_scroll_down(vt, vt->cur.y, vt->bottom, n < 1 ? 1 : n);
    vt->cur.x = 0;
    vt->cur.wrapnext = false;
}

void mnd_vt_delete_lines(mnd_vt *vt, int n) {
    if (vt->cur.y < vt->top || vt->cur.y > vt->bottom) return;
    /* Deleting lines never feeds the scrollback. */
    bool saved = vt->in_alt;
    vt->in_alt = true;
    mnd_vt_scroll_up(vt, vt->cur.y, vt->bottom, n < 1 ? 1 : n);
    vt->in_alt = saved;
    vt->cur.x = 0;
    vt->cur.wrapnext = false;
}

void mnd_vt_alignment_test(mnd_vt *vt) {
    mnd_cell c = kEmptyCell;
    c.cp = 'E';
    for (int y = 0; y < vt->rows; y++) {
        mnd_line *l = vt->screen[y];
        for (int x = 0; x < vt->cols; x++) l->cells[x] = c;
        l->wrapped = false;
    }
    vt->top = 0;
    vt->bottom = vt->rows - 1;
    mnd_vt_move_to(vt, 0, 0);
    vt->all_dirty = true;
}

/* ---- Alternate screen and cursor save -------------------------------------- */

void mnd_vt_save_cursor(mnd_vt *vt) {
    if (vt->in_alt) {
        vt->saved_alt = vt->cur;
        vt->saved_alt_valid = true;
    } else {
        vt->saved_prim = vt->cur;
        vt->saved_prim_valid = true;
    }
}

void mnd_vt_restore_cursor(mnd_vt *vt) {
    bool valid = vt->in_alt ? vt->saved_alt_valid : vt->saved_prim_valid;
    if (valid) {
        vt->cur = vt->in_alt ? vt->saved_alt : vt->saved_prim;
    } else {
        /* xterm: restoring without a save homes the cursor and resets SGR. */
        vt->cur.x = vt->cur.y = 0;
        vt->cur.pen = kEmptyCell;
        vt->cur.origin = false;
        vt->cur.charset[0] = vt->cur.charset[1] = CHARSET_ASCII;
        vt->cur.gl = 0;
    }
    vt->cur.x = clampi(vt->cur.x, 0, vt->cols - 1);
    vt->cur.y = clampi(vt->cur.y, 0, vt->rows - 1);
    vt->cur.wrapnext = vt->cur.wrapnext && vt->cur.x == vt->cols - 1;
}

static void clear_screen_lines(mnd_vt *vt, mnd_line **lines) {
    mnd_cell blank = mnd_vt_blank(vt);
    for (int y = 0; y < vt->rows; y++) {
        mnd_line_fill(lines[y], 0, vt->cols, blank);
        lines[y]->wrapped = false;
    }
}

void mnd_vt_enter_alt(mnd_vt *vt, bool clear) {
    if (vt->in_alt) {
        if (clear) clear_screen_lines(vt, vt->alt);
        vt->all_dirty = true;
        return;
    }
    vt->in_alt = true;
    vt->screen = vt->alt;
    vt->view_offset = 0;
    if (clear) clear_screen_lines(vt, vt->alt);
    vt->all_dirty = true;
}

void mnd_vt_leave_alt(mnd_vt *vt, bool clear) {
    if (!vt->in_alt) return;
    if (clear) clear_screen_lines(vt, vt->alt);
    vt->in_alt = false;
    vt->screen = vt->prim;
    vt->all_dirty = true;
}

/* ---- Grapheme clusters ------------------------------------------------------- */

uint32_t mnd_vt_grapheme_add(mnd_vt *vt, uint32_t base, uint32_t mark) {
    mnd_grapheme g = {0};
    if (base & MND_CP_GRAPHEME_FLAG) {
        uint32_t idx = base & ~MND_CP_GRAPHEME_FLAG;
        if (idx >= vt->ngraphemes) return 0;
        g = vt->graphemes[idx];
    } else {
        g.len = 1;
        g.cps[0] = base;
    }
    if (g.len >= MND_GRAPHEME_MAX_CPS) return 0;
    g.cps[g.len++] = mark;

    /* Reuse an identical cluster seen recently (common for repeated output). */
    uint32_t scan = vt->ngraphemes < 64 ? vt->ngraphemes : 64;
    for (uint32_t i = 0; i < scan; i++) {
        uint32_t idx = vt->ngraphemes - 1 - i;
        const mnd_grapheme *e = &vt->graphemes[idx];
        if (e->len == g.len && memcmp(e->cps, g.cps, g.len * sizeof(uint32_t)) == 0)
            return MND_CP_GRAPHEME_FLAG | idx;
    }
    if (vt->ngraphemes >= MND_GRAPHEME_MAX) return 0;
    if (vt->ngraphemes == vt->graphemes_cap) {
        uint32_t ncap = vt->graphemes_cap ? vt->graphemes_cap * 2 : 64;
        mnd_grapheme *n = realloc(vt->graphemes, ncap * sizeof(mnd_grapheme));
        if (!n) return 0;
        vt->graphemes = n;
        vt->graphemes_cap = ncap;
    }
    vt->graphemes[vt->ngraphemes] = g;
    return MND_CP_GRAPHEME_FLAG | vt->ngraphemes++;
}

/* ---- Reflow ------------------------------------------------------------------- */

typedef struct {
    mnd_cell *cells;
    int len, cap;
} cellvec;

static bool cv_push(cellvec *v, const mnd_cell *c, int n) {
    if (n <= 0) return true;
    if (v->len + n > v->cap) {
        int ncap = v->cap ? v->cap : 256;
        while (ncap < v->len + n) ncap *= 2;
        mnd_cell *p = realloc(v->cells, (size_t)ncap * sizeof(mnd_cell));
        if (!p) return false;
        v->cells = p;
        v->cap = ncap;
    }
    memcpy(&v->cells[v->len], c, (size_t)n * sizeof(mnd_cell));
    v->len += n;
    return true;
}

typedef struct {
    mnd_line **lines;
    int len, cap;
} linevec;

static bool lv_push(linevec *v, mnd_line *l) {
    if (v->len == v->cap) {
        int ncap = v->cap ? v->cap * 2 : 256;
        mnd_line **p = realloc(v->lines, (size_t)ncap * sizeof(mnd_line *));
        if (!p) return false;
        v->lines = p;
        v->cap = ncap;
    }
    v->lines[v->len++] = l;
    return true;
}

static bool cell_is_blank(const mnd_cell *c) {
    return c->cp == 0 && c->bg == MND_COLOR_DEFAULT && (c->attrs & ~MND_ATTR_WIDTH_MASK) == 0 &&
           cell_w(c) != MND_WIDTH_SPACER && c->link == 0;
}

static bool line_is_blank(const mnd_line *l) {
    for (int i = 0; i < l->cols; i++)
        if (!cell_is_blank(&l->cells[i])) return false;
    return !l->wrapped;
}

/* Re-wrap one logical line into rows of width cols. When cursor_off >= 0 it
 * is the cursor offset inside the line; its row/col are reported. */
static bool rewrap(const cellvec *lv, int cols, linevec *out, int cursor_off, int *cur_row, int *cur_col) {
    int pos = 0;
    int n = lv->len;
    do {
        mnd_line *l = mnd_line_new(cols, kEmptyCell);
        if (!l) return false;
        int take = n - pos < cols ? n - pos : cols;
        if (take == cols && take > 0 && pos + take < n &&
            cell_w(&lv->cells[pos + take - 1]) == MND_WIDTH_WIDE)
            take--; /* do not split a wide glyph */
        if (take > 0) memcpy(l->cells, &lv->cells[pos], (size_t)take * sizeof(mnd_cell));
        /* One column: a wide glyph fits nowhere and goes, its spacer with it
         * (a spacer alone would start the next row). */
        int advance = take > 0 ? take : cols;
        if (take == 0 && pos + 1 < n && cell_w(&lv->cells[pos + 1]) == MND_WIDTH_SPACER) advance = 2;
        /* The caller pads the line so the cursor offset is always < n. */
        if (cursor_off >= pos && cursor_off < pos + advance && *cur_row < 0) {
            *cur_row = out->len;
            *cur_col = clampi(cursor_off - pos, 0, cols - 1);
        }
        pos += advance;
        l->wrapped = pos < n;
        if (!lv_push(out, l)) {
            free(l);
            return false;
        }
    } while (pos < n);
    return true;
}

static void free_linevec(linevec *v) {
    for (int i = 0; i < v->len; i++) free(v->lines[i]);
    free(v->lines);
    v->lines = NULL;
    v->len = v->cap = 0;
}

/* Reflow primary buffer + scrollback to cols x rows. (*cx, *cy) is the cursor to
 * track (updated). Produces new screen lines and scrollback. */
static bool reflow_primary(mnd_vt *vt, int cols, int rows, int *cx, int *cy, mnd_line ***out_screen,
                           mnd_line ***out_sb, int *out_sb_count) {
    linevec rowsv = {0};
    cellvec logical = {0};
    bool ok = true;
    int cur_row = -1, cur_col = 0;

    int last = vt->rows - 1;
    while (last > *cy && line_is_blank(vt->prim[last])) last--;

    int total_in = vt->sb_count + last + 1;
    int cursor_line = vt->sb_count + *cy;
    int cursor_off = -1;

    /* Only re-wrap history that can survive: every logical line yields at
     * least one row, so older lines than the newest (kept history + screen)
     * logical lines are dropped anyway. Re-wrapping them all first would
     * briefly need the whole history at the new width (GBs for wide tabs). */
    int need = mnd_vt_sb_limit(vt->sb_cap, cols) + rows + 1;
    int first_in = 0, starts = 0;
    for (int i = total_in - 1; i > 0; i--) {
        mnd_line *prev = i - 1 < vt->sb_count ? sb_at(vt, i - 1) : vt->prim[i - 1 - vt->sb_count];
        if (!prev->wrapped && ++starts >= need) {
            first_in = i;
            break;
        }
    }
    /* Never skip into the screen, and start at the beginning of a logical line. */
    if (first_in > vt->sb_count) first_in = vt->sb_count;
    while (first_in > 0 && sb_at(vt, first_in - 1)->wrapped) first_in--;

    for (int i = first_in; i < total_in && ok; i++) {
        mnd_line *l = i < vt->sb_count ? sb_at(vt, i) : vt->prim[i - vt->sb_count];
        int start = logical.len;
        int keep = l->cols;
        if (!l->wrapped) {
            while (keep > 0 && cell_is_blank(&l->cells[keep - 1])) keep--;
        }
        ok = cv_push(&logical, l->cells, keep);
        if (!ok) break;
        if (i == cursor_line) {
            cursor_off = start + *cx;
            mnd_cell blank = kEmptyCell;
            while (ok && logical.len <= cursor_off) ok = cv_push(&logical, &blank, 1);
        }
        if (!l->wrapped || i == total_in - 1) {
            int off = cursor_off >= 0 && cur_row < 0 ? cursor_off : -1;
            ok = ok && rewrap(&logical, cols, &rowsv, off, &cur_row, &cur_col);
            if (off >= 0) cursor_off = -2; /* consumed */
            logical.len = 0;
        }
    }
    free(logical.cells);
    if (!ok) {
        free_linevec(&rowsv);
        return false;
    }

    if (cur_row < 0) {
        cur_row = rowsv.len > 0 ? rowsv.len - 1 : 0;
        cur_col = 0;
    }
    int start = rowsv.len > rows ? rowsv.len - rows : 0;
    if (cur_row < start) start = cur_row;

    mnd_line **screen = calloc((size_t)rows, sizeof(mnd_line *));
    int sb_cap = vt->sb_cap;
    mnd_line **sb = sb_cap > 0 ? calloc((size_t)sb_cap, sizeof(mnd_line *)) : NULL;
    if (!screen || (sb_cap > 0 && !sb)) {
        free(screen);
        free(sb);
        free_linevec(&rowsv);
        return false;
    }
    for (int y = 0; y < rows; y++) {
        int src = start + y;
        if (src < rowsv.len) {
            screen[y] = rowsv.lines[src];
            rowsv.lines[src] = NULL;
        } else {
            screen[y] = mnd_line_new(cols, kEmptyCell);
            if (!screen[y]) ok = false;
        }
    }
    int sb_count = 0;
    int keep = mnd_vt_sb_limit(sb_cap, cols);
    int sb_first = start > keep ? start - keep : 0;
    for (int i = sb_first; i < start; i++) {
        sb[sb_count++] = rowsv.lines[i];
        rowsv.lines[i] = NULL;
    }
    free_linevec(&rowsv); /* frees anything not moved (dropped history / tail) */
    if (!ok) {
        for (int y = 0; y < rows; y++) free(screen[y]);
        for (int i = 0; i < sb_count; i++) free(sb[i]);
        free(screen);
        free(sb);
        return false;
    }
    /* The last screen row can never continue onto a non-existent line. */
    *cx = cur_col;
    *cy = cur_row - start;
    *out_screen = screen;
    *out_sb = sb;
    *out_sb_count = sb_count;
    return true;
}

static mnd_line **resize_plain(mnd_line **old, int old_cols, int old_rows, int cols, int rows, int keep_from) {
    mnd_line **n = calloc((size_t)rows, sizeof(mnd_line *));
    if (!n) return NULL;
    for (int y = 0; y < rows; y++) {
        n[y] = mnd_line_new(cols, kEmptyCell);
        if (!n[y]) {
            for (int i = 0; i < y; i++) free(n[i]);
            free(n);
            return NULL;
        }
        int src = keep_from + y;
        if (src >= 0 && src < old_rows) {
            int w = old_cols < cols ? old_cols : cols;
            memcpy(n[y]->cells, old[src]->cells, (size_t)w * sizeof(mnd_cell));
            if (w > 0 && cell_w(&n[y]->cells[w - 1]) == MND_WIDTH_WIDE) n[y]->cells[w - 1] = kEmptyCell;
        }
    }
    return n;
}

bool mnd_vt_reflow(mnd_vt *vt, int cols, int rows) {
    /* Cursor to track in the primary buffer. */
    mnd_cursor_state *pc = vt->in_alt ? &vt->saved_prim : &vt->cur;
    int pcx = clampi(pc->x, 0, vt->cols - 1), pcy = clampi(pc->y, 0, vt->rows - 1);
    if (vt->in_alt && !vt->saved_prim_valid) pcx = pcy = 0;

    mnd_line **nscreen = NULL, **nsb = NULL;
    int nsb_count = 0;
    if (!reflow_primary(vt, cols, rows, &pcx, &pcy, &nscreen, &nsb, &nsb_count)) return false;

    /* Alternate screen: keep the bottom rows anchored to the cursor. */
    int alt_from = 0;
    if (vt->in_alt && vt->cur.y >= rows) alt_from = vt->cur.y - rows + 1;
    mnd_line **nalt = resize_plain(vt->alt, vt->cols, vt->rows, cols, rows, alt_from);
    uint8_t *tabs = calloc((size_t)cols, 1);
    uint8_t *dirty = calloc((size_t)rows, 1);
    if (!nalt || !tabs || !dirty) {
        for (int y = 0; y < rows; y++) free(nscreen[y]);
        free(nscreen);
        for (int i = 0; i < nsb_count; i++) free(nsb[i]);
        free(nsb);
        if (nalt) {
            for (int y = 0; y < rows; y++) free(nalt[y]);
            free(nalt);
        }
        free(tabs);
        free(dirty);
        return false;
    }

    /* Commit. */
    for (int i = 0; i < vt->sb_count; i++) free(sb_at(vt, i));
    free(vt->sb);
    /* Absolute line ids are not preserved across a reflow; front ends drop
     * their selection on resize. Advance the base so stale ids never alias. */
    vt->sb_dropped += vt->sb_count + vt->rows;
    vt->sb = nsb;
    vt->sb_head = 0;
    vt->sb_count = nsb_count;
    vt->view_offset = 0;

    free_lines(vt->prim, vt->rows);
    free_lines(vt->alt, vt->rows);
    vt->prim = nscreen;
    vt->alt = nalt;
    vt->screen = vt->in_alt ? nalt : nscreen;
    free(vt->tabs);
    vt->tabs = tabs;
    free(vt->dirty);
    vt->dirty = dirty;

    vt->cols = cols;
    vt->rows = rows;
    mnd_vt_reset_tabs(vt);
    vt->top = 0;
    vt->bottom = rows - 1;

    pc->x = pcx;
    pc->y = pcy;
    pc->wrapnext = false;
    if (vt->in_alt) {
        vt->cur.y = clampi(vt->cur.y - alt_from, 0, rows - 1);
        vt->cur.x = clampi(vt->cur.x, 0, cols - 1);
        vt->cur.wrapnext = false;
        vt->saved_alt.x = clampi(vt->saved_alt.x, 0, cols - 1);
        vt->saved_alt.y = clampi(vt->saved_alt.y, 0, rows - 1);
    } else {
        vt->saved_prim.x = clampi(vt->saved_prim.x, 0, cols - 1);
        vt->saved_prim.y = clampi(vt->saved_prim.y, 0, rows - 1);
        vt->saved_alt.x = clampi(vt->saved_alt.x, 0, cols - 1);
        vt->saved_alt.y = clampi(vt->saved_alt.y, 0, rows - 1);
    }
    vt->all_dirty = true;
    return true;
}
