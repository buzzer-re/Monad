/* Unit tests for mnd_vt. */
#include "../Monad/Backend/vt/mnd_vt.h"
#include "test_util.h"

#include <stdint.h>

/* ---- helpers ---- */

typedef struct {
    char reply[4096];
    size_t reply_len;
    char title[256];
    char clip[256];
    size_t clip_len;
    int bells;
} capture;

static void cap_write(void *ctx, const char *d, size_t n) {
    capture *c = ctx;
    if (c->reply_len + n < sizeof c->reply) {
        memcpy(c->reply + c->reply_len, d, n);
        c->reply_len += n;
        c->reply[c->reply_len] = 0;
    }
}
static void cap_title(void *ctx, const char *t) { snprintf(((capture *)ctx)->title, 256, "%s", t); }
static void cap_bell(void *ctx) { ((capture *)ctx)->bells++; }
static void cap_clip(void *ctx, const char *d, size_t n) {
    capture *c = ctx;
    if (n < sizeof c->clip) {
        memcpy(c->clip, d, n);
        c->clip[n] = 0;
        c->clip_len = n;
    }
}

static capture g_cap;

static mnd_vt *mk(int cols, int rows, int sb) {
    memset(&g_cap, 0, sizeof g_cap);
    mnd_vt_callbacks cb = {&g_cap, cap_write, cap_title, NULL, cap_bell, cap_clip, NULL};
    return mnd_vt_create(cols, rows, sb, &cb);
}

static void feed(mnd_vt *vt, const char *s) { mnd_vt_feed(vt, s, strlen(s)); }

/* Viewport row as UTF-8 with trailing blanks trimmed (empty cells = ' '). */
static const char *row(mnd_vt *vt, int y) {
    static char buf[4096];
    size_t n = 0;
    mnd_vt_lock(vt);
    int len;
    const mnd_cell *c = mnd_vt_view_row(vt, y, &len);
    for (int x = 0; x < len; x++) {
        if (mnd_cell_width(&c[x]) == MND_WIDTH_SPACER) continue;
        uint32_t cps[8];
        size_t k = c[x].cp ? mnd_vt_grapheme(vt, c[x].cp, cps, 8) : 0;
        if (k == 0) {
            buf[n++] = ' ';
            continue;
        }
        for (size_t i = 0; i < k; i++) {
            uint32_t cp = cps[i];
            if (cp < 0x80) buf[n++] = (char)cp;
            else if (cp < 0x800) {
                buf[n++] = (char)(0xC0 | (cp >> 6));
                buf[n++] = (char)(0x80 | (cp & 0x3F));
            } else if (cp < 0x10000) {
                buf[n++] = (char)(0xE0 | (cp >> 12));
                buf[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                buf[n++] = (char)(0x80 | (cp & 0x3F));
            } else {
                buf[n++] = (char)(0xF0 | (cp >> 18));
                buf[n++] = (char)(0x80 | ((cp >> 12) & 0x3F));
                buf[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                buf[n++] = (char)(0x80 | (cp & 0x3F));
            }
        }
    }
    mnd_vt_unlock(vt);
    while (n > 0 && buf[n - 1] == ' ') n--;
    buf[n] = 0;
    return buf;
}

static mnd_cursor_info cursor(mnd_vt *vt) {
    mnd_vt_lock(vt);
    mnd_cursor_info c = mnd_vt_cursor(vt);
    mnd_vt_unlock(vt);
    return c;
}

static mnd_cell cell(mnd_vt *vt, int x, int y) {
    mnd_vt_lock(vt);
    int len;
    mnd_cell c = mnd_vt_view_row(vt, y, &len)[x];
    mnd_vt_unlock(vt);
    return c;
}

/* Every half has its other half: a wide cell is followed by its spacer,
 * and a spacer follows a wide cell. */
static bool wide_cells_pair(mnd_vt *vt) {
    int cols, rows;
    mnd_vt_size(vt, &cols, &rows);
    bool ok = true;
    mnd_vt_lock(vt);
    for (int y = 0; y < rows && ok; y++) {
        int len;
        const mnd_cell *c = mnd_vt_view_row(vt, y, &len);
        for (int x = 0; x < len && ok; x++) {
            unsigned w = mnd_cell_width(&c[x]);
            if (w == MND_WIDTH_WIDE && x + 1 < len && mnd_cell_width(&c[x + 1]) != MND_WIDTH_SPACER) ok = false;
            if (w == MND_WIDTH_SPACER && (x == 0 || mnd_cell_width(&c[x - 1]) != MND_WIDTH_WIDE)) ok = false;
        }
    }
    mnd_vt_unlock(vt);
    return ok;
}

/* ---- tests ---- */

/* Reflowed to one column, a wide glyph cannot fit: it goes with its spacer
 * (the spacer was left alone at the start of a row, and a glyph
 * printed next to it later lost its own spacer). */
static void test_wide_glyph_survives_a_one_column_reflow(void) {
    mnd_vt *vt = mk(7, 1, 100);
    feed(vt, "ab\xe6\x97\xa5");
    CHECK(mnd_vt_resize(vt, 1, 1));
    CHECK(wide_cells_pair(vt));
    CHECK(mnd_vt_resize(vt, 7, 1));
    CHECK(wide_cells_pair(vt));
    feed(vt, "\rx\xe6\x97\xa5/");
    CHECK(strcmp(row(vt, 0), "x\xe6\x97\xa5/") == 0);
    CHECK(mnd_cell_width((mnd_cell[]){cell(vt, 1, 0)}) == MND_WIDTH_WIDE);
    CHECK(mnd_cell_width((mnd_cell[]){cell(vt, 2, 0)}) == MND_WIDTH_SPACER);
    CHECK(wide_cells_pair(vt));
    mnd_vt_destroy(vt);
}

static void test_print_and_wrap(void) {
    mnd_vt *vt = mk(10, 3, 100);
    feed(vt, "hello");
    CHECK_STR(row(vt, 0), "hello");
    CHECK(cursor(vt).x == 5);
    feed(vt, "\r\nabcdefghijKL");
    CHECK_STR(row(vt, 1), "abcdefghij");
    CHECK_STR(row(vt, 2), "KL");
    mnd_vt_lock(vt);
    CHECK(mnd_vt_view_row_wrapped(vt, 1));
    CHECK(!mnd_vt_view_row_wrapped(vt, 2));
    mnd_vt_unlock(vt);
    /* Pending wrap: exactly 10 chars leaves the cursor on the last column. */
    feed(vt, "\x1b[H0123456789");
    CHECK(cursor(vt).x == 9 && cursor(vt).y == 0);
    feed(vt, "\r");
    CHECK(cursor(vt).x == 0 && cursor(vt).y == 0);
    mnd_vt_destroy(vt);
}

static void test_cursor_and_erase(void) {
    mnd_vt *vt = mk(10, 5, 0);
    feed(vt, "AAAAAAAAAA\r\nBBBBBBBBBB\r\nCCCCCCCCCC");
    feed(vt, "\x1b[2;3H");
    CHECK(cursor(vt).x == 2 && cursor(vt).y == 1);
    feed(vt, "\x1b[K");
    CHECK_STR(row(vt, 1), "BB");
    feed(vt, "\x1b[1K");
    CHECK_STR(row(vt, 1), "");
    feed(vt, "\x1b[1;5H\x1b[2P");
    CHECK_STR(row(vt, 0), "AAAAAAAA");
    feed(vt, "\x1b[2@");
    CHECK_STR(row(vt, 0), "AAAA  AAAA");
    feed(vt, "\x1b[3X");
    CHECK_STR(row(vt, 0), "AAAA   AAA");
    feed(vt, "\x1b[J");
    CHECK_STR(row(vt, 0), "AAAA");
    CHECK_STR(row(vt, 2), "");
    feed(vt, "\x1b[10;10H");
    CHECK(cursor(vt).x == 9 && cursor(vt).y == 4);
    feed(vt, "\x1b[3A\x1b[2D");
    CHECK(cursor(vt).x == 7 && cursor(vt).y == 1);
    mnd_vt_destroy(vt);
}

static void test_sgr(void) {
    mnd_vt *vt = mk(20, 2, 0);
    feed(vt, "\x1b[1;3;31;44mA\x1b[0mB\x1b[38;5;200;48;2;1;2;3mC\x1b[38:2::10:20:30;4:3mD\x1b[91;22mE");
    mnd_cell a = cell(vt, 0, 0), b = cell(vt, 1, 0), c = cell(vt, 2, 0), d = cell(vt, 3, 0), e = cell(vt, 4, 0);
    CHECK((a.attrs & MND_ATTR_BOLD) && (a.attrs & MND_ATTR_ITALIC));
    CHECK(a.fg == MND_COLOR_INDEX(1) && a.bg == MND_COLOR_INDEX(4));
    CHECK(b.fg == MND_COLOR_DEFAULT && b.attrs == 0);
    CHECK(c.fg == MND_COLOR_INDEX(200) && c.bg == MND_COLOR_RGB(1, 2, 3));
    CHECK(d.fg == MND_COLOR_RGB(10, 20, 30));
    CHECK(mnd_cell_underline(&d) == MND_UNDERLINE_CURLY);
    CHECK(e.fg == MND_COLOR_INDEX(9) && !(e.attrs & MND_ATTR_BOLD));
    mnd_vt_destroy(vt);
}

static void test_scroll_region_and_scrollback(void) {
    mnd_vt *vt = mk(5, 3, 10);
    feed(vt, "1\r\n2\r\n3\r\n4\r\n5");
    CHECK_STR(row(vt, 0), "3");
    CHECK_STR(row(vt, 2), "5");
    CHECK(mnd_vt_scrollback_lines(vt) == 2);
    mnd_vt_scroll(vt, 2);
    CHECK_STR(row(vt, 0), "1");
    CHECK_STR(row(vt, 2), "3");
    CHECK(!cursor(vt).visible);
    mnd_vt_scroll_to_bottom(vt);
    /* Region 2-3: scrolling inside it must not touch row 1 or scrollback. */
    feed(vt, "\x1b[2;3r\x1b[3;1H\n\n");
    CHECK_STR(row(vt, 0), "3");
    CHECK_STR(row(vt, 1), "");
    CHECK(mnd_vt_scrollback_lines(vt) == 2);
    feed(vt, "\x1b[r");
    /* Reverse index at the top scrolls down. */
    feed(vt, "\x1b[1;1H\x1bM");
    CHECK_STR(row(vt, 0), "");
    CHECK_STR(row(vt, 1), "3");
    mnd_vt_destroy(vt);
}

static void test_alt_screen(void) {
    mnd_vt *vt = mk(10, 3, 10);
    feed(vt, "primary\r\nline2");
    feed(vt, "\x1b[?1049h");
    CHECK_STR(row(vt, 0), "");
    feed(vt, "\x1b[Halt");
    CHECK_STR(row(vt, 0), "alt");
    mnd_vt_lock(vt);
    CHECK(mnd_vt_mode(vt, MND_MODE_ALT_SCREEN));
    mnd_vt_unlock(vt);
    feed(vt, "\x1b[?1049l");
    CHECK_STR(row(vt, 0), "primary");
    CHECK(cursor(vt).x == 5 && cursor(vt).y == 1);
    mnd_vt_destroy(vt);
}

/* Inserting blanks (ICH, or typing in insert mode) where a wide glyph
 * starts moves the glyph whole; inside one, both halves go (fuzz_vt found
 * a glyph moved without its second half). */
static void test_inserting_moves_a_wide_glyph_whole(void) {
    mnd_vt *vt = mk(10, 2, 0);
    feed(vt, "\xe4\xb8\xad" "b\x1b[1;1H\x1b[@"); /* 中b, then insert one at 中 */
    CHECK_STR(row(vt, 0), " \xe4\xb8\xad" "b");
    CHECK(mnd_cell_width(&(mnd_cell){0, 0, 0, cell(vt, 1, 0).attrs, 0}) == MND_WIDTH_WIDE);
    CHECK(mnd_cell_width(&(mnd_cell){0, 0, 0, cell(vt, 2, 0).attrs, 0}) == MND_WIDTH_SPACER);
    feed(vt, "\x1b[1;3H\x1b[@"); /* inside it */
    CHECK_STR(row(vt, 0), "    b");
    for (int x = 0; x < 10; x++) CHECK(mnd_cell_width(&(mnd_cell){0, 0, 0, cell(vt, x, 0).attrs, 0}) == MND_WIDTH_NORMAL);
    feed(vt, "\x1b[2;1H\xe4\xb8\xad\x1b[2;1H\x1b[4hx"); /* insert mode */
    CHECK_STR(row(vt, 1), "x\xe4\xb8\xad");
    CHECK(mnd_cell_width(&(mnd_cell){0, 0, 0, cell(vt, 1, 1).attrs, 0}) == MND_WIDTH_WIDE);
    CHECK(mnd_cell_width(&(mnd_cell){0, 0, 0, cell(vt, 2, 1).attrs, 0}) == MND_WIDTH_SPACER);
    mnd_vt_destroy(vt);
}

/* Deleting characters (DCH) before a wide glyph moves it whole; a glyph
 * the deletion cuts goes (fuzz_vt again). */
static void test_deleting_moves_a_wide_glyph_whole(void) {
    mnd_vt *vt = mk(10, 2, 0);
    feed(vt, "a\xe4\xb8\xad" "b\x1b[1;1H\x1b[P"); /* a中b, delete the a */
    CHECK_STR(row(vt, 0), "\xe4\xb8\xad" "b");
    CHECK(mnd_cell_width(&(mnd_cell){0, 0, 0, cell(vt, 0, 0).attrs, 0}) == MND_WIDTH_WIDE);
    CHECK(mnd_cell_width(&(mnd_cell){0, 0, 0, cell(vt, 1, 0).attrs, 0}) == MND_WIDTH_SPACER);
    feed(vt, "\x1b[1;2H\x1b[P"); /* from its second half */
    CHECK_STR(row(vt, 0), " b");
    feed(vt, "\x1b[2;1H\xe4\xb8\xad" "b\x1b[2;1H\x1b[P"); /* its first half */
    CHECK_STR(row(vt, 1), " b");
    for (int y = 0; y < 2; y++)
        for (int x = 0; x < 10; x++) CHECK(mnd_cell_width(&(mnd_cell){0, 0, 0, cell(vt, x, y).attrs, 0}) == MND_WIDTH_NORMAL);
    mnd_vt_destroy(vt);
}

static void test_wide_and_combining(void) {
    mnd_vt *vt = mk(5, 2, 0);
    feed(vt, "a\xe4\xb8\xad" "b"); /* a 中 b */
    CHECK_STR(row(vt, 0), "a\xe4\xb8\xad" "b");
    CHECK(cursor(vt).x == 4);
    CHECK(mnd_cell_width(&(mnd_cell){cell(vt, 1, 0).cp, 0, 0, cell(vt, 1, 0).attrs, 0}) == MND_WIDTH_WIDE);
    /* Wide char at the last column wraps as a whole. */
    feed(vt, "\xe4\xb8\xad");
    CHECK_STR(row(vt, 1), "\xe4\xb8\xad");
    /* Overwriting half of a wide glyph clears the other half. */
    feed(vt, "\x1b[2;2Hx");
    CHECK_STR(row(vt, 1), " x");
    /* Combining acute accent attaches to the previous cell. */
    feed(vt, "\x1b[1;1He\xcc\x81");
    CHECK_STR(row(vt, 0), "e\xcc\x81\xe4\xb8\xad" "b");
    mnd_vt_destroy(vt);
}

static void test_utf8_invalid(void) {
    mnd_vt *vt = mk(10, 1, 0);
    feed(vt, "a\xff" "b\xc0\xaf" "c\xed\xa0\x80");
    /* 0xFF, overlong '/', and a surrogate each become U+FFFD (the surrogate's
     * three bytes decode to one invalid scalar). */
    CHECK_STR(row(vt, 0), "a\xef\xbf\xbd" "b\xef\xbf\xbd" "c\xef\xbf\xbd");
    mnd_vt_destroy(vt);
}

static void test_replies(void) {
    mnd_vt *vt = mk(80, 24, 0);
    feed(vt, "\x1b[c");
    CHECK_STR(g_cap.reply, "\x1b[?62;22c");
    g_cap.reply_len = 0;
    g_cap.reply[0] = 0;
    feed(vt, "\x1b[5;10H\x1b[6n");
    CHECK_STR(g_cap.reply, "\x1b[5;10R");
    g_cap.reply_len = 0;
    feed(vt, "\x1b[?2004$p");
    CHECK_STR(g_cap.reply, "\x1b[?2004;2$y");
    g_cap.reply_len = 0;
    feed(vt, "\x1b]11;?\x07");
    CHECK_STR(g_cap.reply, "\x1b]11;rgb:0000/0000/0000\x07");
    g_cap.reply_len = 0;
    feed(vt, "\x1b[18t");
    CHECK_STR(g_cap.reply, "\x1b[8;24;80t");
    mnd_vt_destroy(vt);
}

/* A guest's title cannot carry C1 or direction controls (they could reorder
 * or fake what the tab shows), and XTGETTCAP answers without repeating
 * what the guest sent (F-18). */
static void test_titles_and_replies_carry_nothing_the_guest_chose(void) {
    mnd_vt *vt = mk(20, 2, 0);
    feed(vt, "\x1b]2;a\xc2\x9b" "b\xe2\x80\xae" "c\xe2\x81\xa6" "d\xd8\x9c" "e\xe2\x80\x8f" "f\x1b\\");
    CHECK_STR(g_cap.title, "abcdef");
    feed(vt, "\x1b]2;caf\xc3\xa9 \xe2\x9c\x93 \xe6\x97\xa5\x07");
    CHECK_STR(g_cap.title, "caf\xc3\xa9 \xe2\x9c\x93 \xe6\x97\xa5");
    g_cap.reply_len = 0;
    g_cap.reply[0] = 0;
    feed(vt, "\x1bP+q72;6d20\x1b\\");
    CHECK_STR(g_cap.reply, "\x1bP0+r\x1b\\");
    mnd_vt_destroy(vt);
}

static void test_osc(void) {
    mnd_vt *vt = mk(20, 2, 0);
    feed(vt, "\x1b]0;my title\x07");
    CHECK_STR(g_cap.title, "my title");
    feed(vt, "\x1b]2;other\x1b\\after");
    CHECK_STR(g_cap.title, "other");
    CHECK_STR(row(vt, 0), "after");
    feed(vt, "\x1b]52;c;aGVsbG8=\x07");
    CHECK_STR(g_cap.clip, "hello");
    feed(vt, "\x1b]52;c;?\x07");
    CHECK(g_cap.reply_len == 0);
    feed(vt, "\x07");
    CHECK(g_cap.bells == 1);
    /* OSC split across feeds. */
    feed(vt, "\x1b]2;sp");
    feed(vt, "lit\x07");
    CHECK_STR(g_cap.title, "split");
    /* Hyperlinks. */
    feed(vt, "\r\x1b]8;;https://x.test\x1b\\L\x1b]8;;\x1b\\N");
    mnd_cell l = cell(vt, 0, 0), n = cell(vt, 1, 0);
    mnd_vt_lock(vt);
    CHECK(l.link != 0 && mnd_vt_link_uri(vt, l.link) && strcmp(mnd_vt_link_uri(vt, l.link), "https://x.test") == 0);
    mnd_vt_unlock(vt);
    CHECK(n.link == 0);
    mnd_vt_destroy(vt);
}

/* A guest cannot grow the link table without bound (F-05): an over-long
 * URI makes no link, and all links together stay under a byte cap. */
static void test_links_are_bounded(void) {
    mnd_vt *vt = mk(20, 2, 0);
    size_t big = MND_VT_LINK_URI_MAX + 100;
    char *seq = malloc(big + 64);
    int n = snprintf(seq, 64, "\x1b]8;;https://x.test/");
    memset(seq + n, 'a', big);
    strcpy(seq + n + big, "\x1b\\L\x1b]8;;\x1b\\");
    feed(vt, seq);
    CHECK(cell(vt, 0, 0).link == 0);
    CHECK(mnd_vt_link_bytes(vt) == 0);
    /* As many distinct links of the longest allowed length as fit. */
    size_t len = MND_VT_LINK_URI_MAX - 32;
    for (int i = 0; i < 4096; i++) {
        n = snprintf(seq, 64, "\r\x1b]8;;https://x.test/%d/", i);
        memset(seq + n, 'b', len);
        strcpy(seq + n + len, "\x1b\\x\x1b]8;;\x1b\\");
        feed(vt, seq);
    }
    CHECK(mnd_vt_link_bytes(vt) <= MND_VT_LINK_BYTES_MAX);
    CHECK(mnd_vt_link_bytes(vt) > MND_VT_LINK_BYTES_MAX / 2);
    free(seq);
    mnd_vt_destroy(vt);
}

static void test_reflow(void) {
    mnd_vt *vt = mk(10, 4, 100);
    feed(vt, "abcdefghijklmno\r\n$ ");
    CHECK_STR(row(vt, 0), "abcdefghij");
    CHECK_STR(row(vt, 1), "klmno");
    CHECK_STR(row(vt, 2), "$");
    CHECK(mnd_vt_resize(vt, 20, 4));
    CHECK_STR(row(vt, 0), "abcdefghijklmno");
    CHECK_STR(row(vt, 1), "$");
    CHECK(cursor(vt).x == 2 && cursor(vt).y == 1);
    CHECK(mnd_vt_resize(vt, 5, 4));
    CHECK_STR(row(vt, 0), "abcde");
    CHECK_STR(row(vt, 2), "klmno");
    CHECK_STR(row(vt, 3), "$");
    CHECK(cursor(vt).x == 2 && cursor(vt).y == 3);
    /* Shrinking rows pushes into scrollback, growing pulls it back. */
    CHECK(mnd_vt_resize(vt, 5, 2));
    CHECK_STR(row(vt, 1), "$");
    CHECK(mnd_vt_scrollback_lines(vt) == 2);
    CHECK(mnd_vt_resize(vt, 20, 6));
    CHECK_STR(row(vt, 0), "abcdefghijklmno");
    CHECK(mnd_vt_scrollback_lines(vt) == 0);
    CHECK(cursor(vt).y == 1);
    mnd_vt_destroy(vt);
}

static void test_copy_and_words(void) {
    mnd_vt *vt = mk(10, 3, 10);
    feed(vt, "hello worldwide\r\nnext  ");
    int64_t top = mnd_vt_view_to_abs(vt, 0);
    char *t = mnd_vt_copy_text(vt, (mnd_pos){0, top}, (mnd_pos){9, top + 2}, false);
    CHECK_STR(t, "hello worldwide\nnext");
    free(t);
    mnd_pos s, e;
    mnd_vt_word_bounds(vt, (mnd_pos){7, top}, &s, &e);
    CHECK(s.col == 6 && s.line == top && e.col == 4 && e.line == top + 1);
    t = mnd_vt_copy_text(vt, s, e, false);
    CHECK_STR(t, "worldwide");
    free(t);
    mnd_vt_line_bounds(vt, (mnd_pos){2, top + 1}, &s, &e);
    CHECK(s.line == top && e.line == top + 1);
    mnd_vt_destroy(vt);
}

static void test_keys_and_mouse(void) {
    mnd_vt *vt = mk(80, 24, 0);
    char b[32];
    size_t n;
    n = mnd_vt_encode_key(vt, MND_KEY_UP, 0, b, sizeof b);
    CHECK_MEM(b, n, "\x1b[A", 3);
    feed(vt, "\x1b[?1h");
    n = mnd_vt_encode_key(vt, MND_KEY_UP, 0, b, sizeof b);
    CHECK_MEM(b, n, "\x1bOA", 3);
    n = mnd_vt_encode_key(vt, MND_KEY_LEFT, MND_MOD_CTRL, b, sizeof b);
    CHECK_MEM(b, n, "\x1b[1;5D", 6);
    n = mnd_vt_encode_key(vt, MND_KEY_F5, MND_MOD_SHIFT, b, sizeof b);
    CHECK_MEM(b, n, "\x1b[15;2~", 7);
    n = mnd_vt_encode_key(vt, MND_KEY_F1, 0, b, sizeof b);
    CHECK_MEM(b, n, "\x1bOP", 3);
    n = mnd_vt_encode_key(vt, MND_KEY_TAB, MND_MOD_SHIFT, b, sizeof b);
    CHECK_MEM(b, n, "\x1b[Z", 3);
    n = mnd_vt_encode_key(vt, MND_KEY_BACKSPACE, 0, b, sizeof b);
    CHECK_MEM(b, n, "\x7f", 1);
    n = mnd_vt_encode_char(vt, 'c', MND_MOD_CTRL, b, sizeof b);
    CHECK_MEM(b, n, "\x03", 1);
    n = mnd_vt_encode_char(vt, 'x', MND_MOD_ALT, b, sizeof b);
    CHECK_MEM(b, n, "\x1bx", 2);
    n = mnd_vt_encode_char(vt, ' ', MND_MOD_CTRL, b, sizeof b);
    CHECK_MEM(b, n, "\x00", 1);

    n = mnd_vt_encode_mouse(vt, 0, MND_MOUSE_PRESS, 0, 4, 2, b, sizeof b);
    CHECK(n == 0);
    feed(vt, "\x1b[?1000h\x1b[?1006h");
    n = mnd_vt_encode_mouse(vt, 0, MND_MOUSE_PRESS, 0, 4, 2, b, sizeof b);
    CHECK_MEM(b, n, "\x1b[<0;5;3M", 9);
    n = mnd_vt_encode_mouse(vt, 0, MND_MOUSE_RELEASE, 0, 4, 2, b, sizeof b);
    CHECK_MEM(b, n, "\x1b[<0;5;3m", 9);
    n = mnd_vt_encode_mouse(vt, 3, MND_MOUSE_MOTION, 0, 4, 2, b, sizeof b);
    CHECK(n == 0);
    n = mnd_vt_encode_mouse(vt, 4, MND_MOUSE_PRESS, MND_MOD_CTRL, 0, 0, b, sizeof b);
    CHECK_MEM(b, n, "\x1b[<80;1;1M", 10);
    feed(vt, "\x1b[?1006l");
    n = mnd_vt_encode_mouse(vt, 2, MND_MOUSE_PRESS, 0, 0, 0, b, sizeof b);
    CHECK_MEM(b, n, "\x1b[M\x22!!", 6);
    mnd_vt_destroy(vt);
}

static void test_paste(void) {
    mnd_vt *vt = mk(80, 24, 0);
    size_t n;
    char *p = mnd_vt_encode_paste(vt, "a\nb\r\nc\x1b[201~evil\x03", 17, &n);
    CHECK_STR(p, "a\rb\rc[201~evil");
    free(p);
    feed(vt, "\x1b[?2004h");
    p = mnd_vt_encode_paste(vt, "x\x1b[201~y", 9, &n);
    CHECK_STR(p, "\x1b[200~x[201~y\x1b[201~");
    free(p);
    mnd_vt_destroy(vt);
}

static void test_dec_graphics_and_modes(void) {
    mnd_vt *vt = mk(10, 2, 0);
    feed(vt, "\x1b(0qx\x1b(Bq");
    CHECK_STR(row(vt, 0), "\xe2\x94\x80\xe2\x94\x82q");
    feed(vt, "\x1b[?25l");
    CHECK(!cursor(vt).visible);
    feed(vt, "\x1b[6 q");
    CHECK(cursor(vt).shape == MND_CURSOR_BAR && !cursor(vt).blink);
    feed(vt, "\x1b" "c");
    CHECK(cursor(vt).visible && cursor(vt).x == 0);
    CHECK_STR(row(vt, 0), "");
    mnd_vt_destroy(vt);
}

static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint32_t rnd(void) {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return (uint32_t)rng;
}

static void test_fuzz(void) {
    mnd_vt *vt = mk(40, 12, 200);
    static const char *frags[] = {"\x1b[", "\x1b]", "\x1bP", ";", ":", "?", "1049h", "1049l", "\x1b\\", "\x07",
                                  "\r\n", "\xe4\xb8\xad", "\xcc\x81", "m", "H", "J", "K", "r", "L", "M", "@", "P",
                                  "38;2;", "\x1b(0", "\xf0\x9f\x98\x80", "\t", "\x1b" "7", "\x1b" "8", "\x1b" "c"};
    char buf[512];
    for (int iter = 0; iter < 20000; iter++) {
        size_t n = 0;
        while (n < sizeof buf - 16) {
            uint32_t r = rnd();
            if (r % 3 == 0) {
                const char *f = frags[rnd() % (sizeof frags / sizeof *frags)];
                size_t fl = strlen(f);
                memcpy(buf + n, f, fl);
                n += fl;
            } else if (r % 3 == 1) {
                buf[n++] = (char)('0' + rnd() % 10);
            } else {
                buf[n++] = (char)rnd();
            }
            if (rnd() % 40 == 0) break;
        }
        mnd_vt_feed(vt, buf, n);
        if (iter % 97 == 0) mnd_vt_resize(vt, 1 + (int)(rnd() % 80), 1 + (int)(rnd() % 30));
        if (iter % 211 == 0) mnd_vt_scroll(vt, (int)(rnd() % 50) - 25);
        int cols, rows;
        mnd_vt_size(vt, &cols, &rows);
        mnd_cursor_info c = cursor(vt);
        CHECK(c.x >= 0 && c.x < cols && c.y >= 0);
        CHECK(wide_cells_pair(vt));
        if (iter % 503 == 0) {
            int64_t a = mnd_vt_view_to_abs(vt, 0);
            char *t = mnd_vt_copy_text(vt, (mnd_pos){0, a - 5}, (mnd_pos){cols - 1, a + rows}, iter % 2);
            free(t);
        }
    }
    mnd_vt_destroy(vt);
}

/* Scrollback lines are stored at the full terminal width: a line budget
 * alone lets one wide tab use hundreds of MB. History is capped in cells. */
static void test_scrollback_memory_is_bounded(void) {
    mnd_vt *vt = mnd_vt_create(1000, 10, 200000, NULL);
    CHECK(vt != NULL);
    if (!vt) return;
    for (int i = 0; i < 6000; i++) feed(vt, "line\r\n");
    int per_1000 = (4 << 20) / 1000;
    CHECK(mnd_vt_scrollback_lines(vt) == per_1000);

    /* Narrower: more lines fit the budget, but what was dropped is gone. */
    CHECK(mnd_vt_resize(vt, 100, 10));
    CHECK(mnd_vt_scrollback_lines(vt) <= (4 << 20) / 100);
    for (int i = 0; i < 50000; i++) feed(vt, "line\r\n");
    CHECK(mnd_vt_scrollback_lines(vt) == (4 << 20) / 100);

    /* Wider again: history shrinks to the budget at once. */
    CHECK(mnd_vt_resize(vt, 2000, 10));
    CHECK(mnd_vt_scrollback_lines(vt) <= (4 << 20) / 2000);
    for (int i = 0; i < 100; i++) feed(vt, "line\r\n");
    CHECK(mnd_vt_scrollback_lines(vt) <= (4 << 20) / 2000);

    /* A small configured scrollback still wins. */
    mnd_vt *small = mnd_vt_create(80, 10, 100, NULL);
    for (int i = 0; i < 500; i++) feed(small, "x\r\n");
    CHECK(mnd_vt_scrollback_lines(small) == 100);
    mnd_vt_destroy(small);
    mnd_vt_destroy(vt);
}

/* Programs may choose a cursor style (DECSCUSR 1-6); 0 and a reset hand it
 * back to the user's theme and settings. */
static void test_cursor_style_ownership(void) {
    mnd_vt *vt = mnd_vt_create(20, 5, 0, NULL);
    CHECK(!mnd_vt_cursor(vt).styled);
    feed(vt, "\x1b[4 q");
    mnd_cursor_info c = mnd_vt_cursor(vt);
    CHECK(c.styled && c.shape == MND_CURSOR_UNDERLINE && !c.blink);
    feed(vt, "\x1b[5 q");
    c = mnd_vt_cursor(vt);
    CHECK(c.styled && c.shape == MND_CURSOR_BAR && c.blink);
    feed(vt, "\x1b[0 q");
    c = mnd_vt_cursor(vt);
    CHECK(!c.styled && !c.blink);
    feed(vt, "\x1b[2 q\x1b" "c"); /* RIS */
    CHECK(!mnd_vt_cursor(vt).styled);
    mnd_vt_destroy(vt);
}

int main(void) {
    fprintf(stderr, "mnd_vt tests\n");
    RUN(test_cursor_style_ownership);
    RUN(test_scrollback_memory_is_bounded);
    RUN(test_print_and_wrap);
    RUN(test_cursor_and_erase);
    RUN(test_sgr);
    RUN(test_scroll_region_and_scrollback);
    RUN(test_alt_screen);
    RUN(test_wide_and_combining);
    RUN(test_inserting_moves_a_wide_glyph_whole);
    RUN(test_deleting_moves_a_wide_glyph_whole);
    RUN(test_wide_glyph_survives_a_one_column_reflow);
    RUN(test_utf8_invalid);
    RUN(test_replies);
    RUN(test_osc);
    RUN(test_titles_and_replies_carry_nothing_the_guest_chose);
    RUN(test_links_are_bounded);
    RUN(test_reflow);
    RUN(test_copy_and_words);
    RUN(test_keys_and_mouse);
    RUN(test_paste);
    RUN(test_dec_graphics_and_modes);
    RUN(test_fuzz);
    TEST_MAIN_END();
}
