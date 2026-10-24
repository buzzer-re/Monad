/*
 * mnd_vt_select.c — selection helpers: text extraction and word/line bounds.
 */
#include "mnd_vt_internal.h"

#include <stdlib.h>
#include <string.h>

static void order(mnd_pos *a, mnd_pos *b) {
    if (a->line > b->line || (a->line == b->line && a->col > b->col)) {
        mnd_pos t = *a;
        *a = *b;
        *b = t;
    }
}

static bool append_cp(mnd_buf *b, uint32_t cp) {
    char enc[4];
    size_t n;
    if (cp < 0x80) {
        enc[0] = (char)cp;
        n = 1;
    } else if (cp < 0x800) {
        enc[0] = (char)(0xC0 | (cp >> 6));
        enc[1] = (char)(0x80 | (cp & 0x3F));
        n = 2;
    } else if (cp < 0x10000) {
        enc[0] = (char)(0xE0 | (cp >> 12));
        enc[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        enc[2] = (char)(0x80 | (cp & 0x3F));
        n = 3;
    } else {
        enc[0] = (char)(0xF0 | (cp >> 18));
        enc[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        enc[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
        enc[3] = (char)(0x80 | (cp & 0x3F));
        n = 4;
    }
    return mnd_buf_append(b, enc, n);
}

static bool append_cell(mnd_vt *vt, mnd_buf *b, const mnd_cell *c) {
    if (mnd_cell_width(c) == MND_WIDTH_SPACER) return true;
    if (c->cp == 0 || mnd_cp_is_image(c->cp)) return mnd_buf_append(b, " ", 1);
    uint32_t cps[MND_GRAPHEME_MAX_CPS];
    size_t n = mnd_vt_grapheme(vt, c->cp, cps, MND_GRAPHEME_MAX_CPS);
    for (size_t i = 0; i < n && i < MND_GRAPHEME_MAX_CPS; i++)
        if (!append_cp(b, cps[i])) return false;
    return true;
}

static void trim_trailing_spaces(mnd_buf *b, size_t floor) {
    while (b->len > floor && b->data[b->len - 1] == ' ') b->len--;
    if (b->data) b->data[b->len] = '\0';
}

char *mnd_vt_copy_text(mnd_vt *vt, mnd_pos a, mnd_pos b, bool block) {
    order(&a, &b);
    mnd_buf out = {0};
    mnd_vt_lock(vt);
    int c0 = a.col < b.col ? a.col : b.col;
    int c1 = a.col < b.col ? b.col : a.col;
    for (int64_t line = a.line; line <= b.line; line++) {
        mnd_line *l = mnd_vt_abs_line(vt, line);
        if (!l) continue;
        int from, to;
        if (block) {
            from = c0;
            to = c1;
        } else {
            from = line == a.line ? a.col : 0;
            to = line == b.line ? b.col : l->cols - 1;
        }
        if (from < 0) from = 0;
        if (to >= l->cols) to = l->cols - 1;
        size_t floor = out.len;
        for (int x = from; x <= to; x++)
            if (!append_cell(vt, &out, &l->cells[x])) goto oom;
        bool joined = !block && l->wrapped && to == l->cols - 1 && line != b.line;
        if (!joined) {
            trim_trailing_spaces(&out, floor);
            if (line != b.line && !mnd_buf_append(&out, "\n", 1)) goto oom;
        }
    }
    mnd_vt_unlock(vt);
    if (out.len == 0) {
        mnd_buf_free(&out);
        return NULL;
    }
    return out.data;
oom:
    mnd_vt_unlock(vt);
    mnd_buf_free(&out);
    return NULL;
}

static bool is_word_cell(mnd_vt *vt, const mnd_cell *c) {
    if (c->cp == 0) return mnd_cell_width(c) == MND_WIDTH_SPACER;
    if (mnd_cp_is_image(c->cp)) return false;
    uint32_t cp = c->cp;
    if (cp & MND_CP_GRAPHEME_FLAG) {
        uint32_t first;
        if (mnd_vt_grapheme(vt, cp, &first, 1) == 0) return false;
        cp = first;
    }
    if (cp == ' ' || cp == '\t') return false;
    if (cp < 0x80 && strchr("'\"`()[]{}<>|,;", (int)cp)) return false;
    return true;
}

void mnd_vt_word_bounds(mnd_vt *vt, mnd_pos pos, mnd_pos *start, mnd_pos *end) {
    *start = *end = pos;
    mnd_vt_lock(vt);
    mnd_line *l = mnd_vt_abs_line(vt, pos.line);
    if (!l || pos.col < 0 || pos.col >= l->cols) {
        mnd_vt_unlock(vt);
        return;
    }
    bool word = is_word_cell(vt, &l->cells[pos.col]);
    /* Walk backwards, crossing soft wraps. */
    mnd_pos s = pos;
    for (;;) {
        mnd_line *cl = mnd_vt_abs_line(vt, s.line);
        if (s.col > 0) {
            if (is_word_cell(vt, &cl->cells[s.col - 1]) != word) break;
            s.col--;
        } else {
            mnd_line *prev = mnd_vt_abs_line(vt, s.line - 1);
            if (!prev || !prev->wrapped || is_word_cell(vt, &prev->cells[prev->cols - 1]) != word) break;
            s.line--;
            s.col = prev->cols - 1;
        }
    }
    mnd_pos e = pos;
    for (;;) {
        mnd_line *cl = mnd_vt_abs_line(vt, e.line);
        if (e.col < cl->cols - 1) {
            if (is_word_cell(vt, &cl->cells[e.col + 1]) != word) break;
            e.col++;
        } else {
            mnd_line *next = cl->wrapped ? mnd_vt_abs_line(vt, e.line + 1) : NULL;
            if (!next || is_word_cell(vt, &next->cells[0]) != word) break;
            e.line++;
            e.col = 0;
        }
    }
    mnd_vt_unlock(vt);
    *start = s;
    *end = e;
}

void mnd_vt_line_bounds(mnd_vt *vt, mnd_pos pos, mnd_pos *start, mnd_pos *end) {
    mnd_vt_lock(vt);
    int64_t s = pos.line, e = pos.line;
    for (;;) {
        mnd_line *prev = mnd_vt_abs_line(vt, s - 1);
        if (!prev || !prev->wrapped) break;
        s--;
    }
    for (;;) {
        mnd_line *cur = mnd_vt_abs_line(vt, e);
        if (!cur || !cur->wrapped || !mnd_vt_abs_line(vt, e + 1)) break;
        e++;
    }
    int cols = vt->cols;
    mnd_vt_unlock(vt);
    start->line = s;
    start->col = 0;
    end->line = e;
    end->col = cols - 1;
}
