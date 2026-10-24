/* Inline images (iTerm2's OSC 1337 File=...;inline=1): off unless the VM
 * allows them, checked and bounded, laid out over cells that scroll and
 * clear like text. The core never decodes an image: it reads the file's
 * header for its format and size and hands the bytes to the front end. */
#include "../Monad/Backend/vt/mnd_vt.h"
#include "test_util.h"

#include <stdint.h>

/* ---- helpers ---- */

typedef struct {
    int count;
    mnd_vt_image_info last;
    uint8_t data[1024];
    size_t len;
    char reply[256];
    size_t reply_len;
} capture;

static capture g_cap;

static void cap_image(void *ctx, const mnd_vt_image_info *info, const uint8_t *data, size_t len) {
    capture *c = ctx;
    c->count++;
    c->last = *info;
    c->len = len;
    if (len <= sizeof c->data) memcpy(c->data, data, len);
}

static void cap_write(void *ctx, const char *d, size_t n) {
    capture *c = ctx;
    if (c->reply_len + n < sizeof c->reply) {
        memcpy(c->reply + c->reply_len, d, n);
        c->reply_len += n;
        c->reply[c->reply_len] = 0;
    }
}

/* A terminal with 10x20-pixel cells. */
static mnd_vt *mk(int cols, int rows, int sb, bool images) {
    memset(&g_cap, 0, sizeof g_cap);
    mnd_vt_callbacks cb = {&g_cap, cap_write, NULL, NULL, NULL, NULL, cap_image};
    mnd_vt *vt = mnd_vt_create(cols, rows, sb, &cb);
    mnd_vt_set_cell_pixels(vt, 10, 20);
    mnd_vt_set_images(vt, images);
    return vt;
}

static void feed(mnd_vt *vt, const char *s) { mnd_vt_feed(vt, s, strlen(s)); }

static const char kB64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* malloc'd base64 of data. */
static char *b64(const uint8_t *data, size_t len) {
    char *out = malloc((len + 2) / 3 * 4 + 1);
    size_t o = 0;
    for (size_t i = 0; i < len; i += 3) {
        uint32_t v = (uint32_t)data[i] << 16;
        if (i + 1 < len) v |= (uint32_t)data[i + 1] << 8;
        if (i + 2 < len) v |= data[i + 2];
        out[o++] = kB64[(v >> 18) & 63];
        out[o++] = kB64[(v >> 12) & 63];
        out[o++] = i + 1 < len ? kB64[(v >> 6) & 63] : '=';
        out[o++] = i + 2 < len ? kB64[v & 63] : '=';
    }
    out[o] = 0;
    return out;
}

/* The header of a PNG file of w x h pixels (all the core reads). */
static size_t png(uint8_t *out, uint32_t w, uint32_t h) {
    static const uint8_t head[] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n', 0, 0, 0, 13, 'I', 'H', 'D', 'R'};
    memcpy(out, head, sizeof head);
    uint8_t *p = out + sizeof head;
    p[0] = (uint8_t)(w >> 24), p[1] = (uint8_t)(w >> 16), p[2] = (uint8_t)(w >> 8), p[3] = (uint8_t)w;
    p[4] = (uint8_t)(h >> 24), p[5] = (uint8_t)(h >> 16), p[6] = (uint8_t)(h >> 8), p[7] = (uint8_t)h;
    memcpy(p + 8, "\x08\x06\x00\x00\x00", 5); /* depth, color type, compression, filter, interlace */
    memset(p + 13, 0, 4);                    /* CRC (not checked by the core) */
    return sizeof head + 17;
}

static size_t gif(uint8_t *out, uint16_t w, uint16_t h) {
    memcpy(out, "GIF89a", 6);
    out[6] = (uint8_t)w, out[7] = (uint8_t)(w >> 8), out[8] = (uint8_t)h, out[9] = (uint8_t)(h >> 8);
    memset(out + 10, 0, 3);
    return 13;
}

/* SOI, an APP0 segment, then a baseline frame header. */
static size_t jpeg(uint8_t *out, uint16_t w, uint16_t h) {
    static const uint8_t app0[] = {0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0};
    memcpy(out, app0, sizeof app0);
    uint8_t *p = out + sizeof app0;
    uint8_t sof[] = {0xFF, 0xC0, 0, 11, 8, (uint8_t)(h >> 8), (uint8_t)h, (uint8_t)(w >> 8), (uint8_t)w, 1, 1, 0x11, 0};
    memcpy(p, sof, sizeof sof);
    return sizeof app0 + sizeof sof;
}

/* OSC 1337 for an image file, with the given arguments. */
static void send_image(mnd_vt *vt, const char *args, const uint8_t *file, size_t len) {
    char *data = b64(file, len);
    size_t n = strlen(args) + strlen(data) + 32;
    char *seq = malloc(n);
    snprintf(seq, n, "\x1b]1337;File=%s:%s\a", args, data);
    feed(vt, seq);
    free(seq);
    free(data);
}

static mnd_cell cell(mnd_vt *vt, int x, int y) {
    mnd_vt_lock(vt);
    int len;
    mnd_cell c = mnd_vt_view_row(vt, y, &len)[x];
    mnd_vt_unlock(vt);
    return c;
}

static mnd_cursor_info cursor(mnd_vt *vt) {
    mnd_vt_lock(vt);
    mnd_cursor_info c = mnd_vt_cursor(vt);
    mnd_vt_unlock(vt);
    return c;
}

/* Whether cell (x, y) shows tile (tx, ty) of image id. */
static bool tile(mnd_vt *vt, int x, int y, uint32_t id, unsigned tx, unsigned ty) {
    uint32_t cp = cell(vt, x, y).cp;
    return mnd_cp_is_image(cp) && mnd_cp_image_id(cp) == id && mnd_cp_image_x(cp) == tx && mnd_cp_image_y(cp) == ty;
}

static int image_cells(mnd_vt *vt, int y) {
    int n = 0, cols, rows;
    mnd_vt_size(vt, &cols, &rows);
    for (int x = 0; x < cols; x++) n += mnd_cp_is_image(cell(vt, x, y).cp);
    return n;
}

static bool near(double a, double b) { return a > b - 0.001 && a < b + 0.001; }

/* ---- tests ---- */

/* A VM's images are not even parsed unless its settings allow them, and
 * the window's size in pixels is not told either. */
static void test_images_are_off_by_default(void) {
    uint8_t f[64];
    size_t n = png(f, 40, 40);
    mnd_vt *vt = mk(20, 10, 0, false);
    send_image(vt, "inline=1", f, n);
    feed(vt, "ok");
    CHECK(g_cap.count == 0);
    CHECK(image_cells(vt, 0) == 0);
    CHECK(cell(vt, 0, 0).cp == 'o');
    feed(vt, "\x1b[14t\x1b[16t");
    CHECK(g_cap.reply_len == 0);
    mnd_vt_destroy(vt);
}

/* An image covers the cells its pixels need, from the cursor, and the
 * cursor ends after it on its last row. */
static void test_an_image_covers_cells_and_moves_the_cursor(void) {
    uint8_t f[64];
    size_t n = png(f, 40, 40);
    mnd_vt *vt = mk(20, 10, 0, true);
    feed(vt, "ab");
    send_image(vt, "name=bG9nby5wbmc=;size=33;inline=1", f, n);
    CHECK(g_cap.count == 1);
    CHECK(g_cap.last.id == 1);
    CHECK(g_cap.last.format == MND_IMAGE_PNG);
    CHECK(g_cap.last.width == 40 && g_cap.last.height == 40);
    CHECK(g_cap.last.cols == 4 && g_cap.last.rows == 2);
    CHECK(near(g_cap.last.fill_x, 1) && near(g_cap.last.fill_y, 1));
    CHECK_MEM(g_cap.data, g_cap.len, f, n);
    for (unsigned ty = 0; ty < 2; ty++)
        for (unsigned tx = 0; tx < 4; tx++) CHECK(tile(vt, 2 + (int)tx, (int)ty, 1, tx, ty));
    CHECK(!mnd_cp_is_image(cell(vt, 6, 0).cp));
    CHECK(cursor(vt).x == 6 && cursor(vt).y == 1);
    feed(vt, "\r\nnext");
    CHECK(cell(vt, 0, 2).cp == 'n');
    mnd_vt_destroy(vt);
}

/* width and height as cells, pixels, a share of the terminal or the
 * image's own; the aspect ratio kept unless told otherwise; never wider
 * than the terminal. */
static void test_image_sizes(void) {
    uint8_t f[64];
    size_t n = png(f, 40, 40);
    struct {
        const char *args;
        int cols, rows;
        double fx, fy;
    } cases[] = {
        {"inline=1;width=2", 2, 1, 1, 1},
        {"inline=1;width=50%", 10, 5, 1, 1},
        {"inline=1;height=60px", 6, 3, 1, 1},
        {"inline=1;width=100px;height=20px", 10, 1, 0.2, 1},
        {"inline=1;width=100px;height=20px;preserveAspectRatio=0", 10, 1, 1, 1},
        {"inline=1;width=auto;height=auto", 4, 2, 1, 1},
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        mnd_vt *vt = mk(20, 10, 0, true);
        send_image(vt, cases[i].args, f, n);
        CHECK(g_cap.count == 1);
        if (g_cap.last.cols != cases[i].cols || g_cap.last.rows != cases[i].rows)
            fprintf(stderr, "    %s: %dx%d\n", cases[i].args, g_cap.last.cols, g_cap.last.rows);
        CHECK(g_cap.last.cols == cases[i].cols && g_cap.last.rows == cases[i].rows);
        CHECK(near(g_cap.last.fill_x, cases[i].fx) && near(g_cap.last.fill_y, cases[i].fy));
        mnd_vt_destroy(vt);
    }

    /* 1000x100 pixels on a 200-pixel-wide terminal: scaled to fit. */
    n = png(f, 1000, 100);
    mnd_vt *vt = mk(20, 10, 0, true);
    send_image(vt, "inline=1", f, n);
    CHECK(g_cap.last.cols == 20 && g_cap.last.rows == 1);
    CHECK(image_cells(vt, 0) == 20);
    mnd_vt_destroy(vt);

    /* Never more than MND_VT_IMAGE_CELLS_MAX cells either way. */
    n = png(f, 4000, 10);
    vt = mk(300, 10, 0, true);
    send_image(vt, "inline=1", f, n);
    CHECK(g_cap.last.cols == MND_VT_IMAGE_CELLS_MAX);
    mnd_vt_destroy(vt);

    /* Past the right edge: the image starts on the next line. */
    n = png(f, 40, 20);
    vt = mk(20, 10, 0, true);
    feed(vt, "\x1b[1;18H");
    send_image(vt, "inline=1", f, n);
    CHECK(tile(vt, 0, 1, 1, 0, 0));
    CHECK(image_cells(vt, 0) == 0);
    mnd_vt_destroy(vt);
}

/* What the core cannot vouch for is dropped whole, and the stream goes on. */
static void test_bad_images_are_ignored(void) {
    uint8_t f[64];
    size_t n = png(f, 40, 40);
    mnd_vt *vt = mk(20, 10, 0, true);
    send_image(vt, "inline=0", f, n); /* a download, not shown */
    send_image(vt, "", f, n);
    feed(vt, "\x1b]1337;File=inline=1:!!!not base64!!!\a");
    send_image(vt, "inline=1", (const uint8_t *)"hello, not an image", 19);
    n = png(f, 0, 40);
    send_image(vt, "inline=1", f, n);
    n = png(f, MND_VT_IMAGE_SIDE_MAX + 1, 1);
    send_image(vt, "inline=1", f, n);
    n = png(f, 8000, 8000); /* 64 M pixels */
    send_image(vt, "inline=1", f, n);
    n = png(f, 40, 40);
    send_image(vt, "inline=1", f, 20); /* cut short */
    feed(vt, "\x1b]1337;File=inline=1:"); /* never finished, then CAN */
    feed(vt, "\x18");
    CHECK(g_cap.count == 0);
    CHECK(image_cells(vt, 0) == 0);
    feed(vt, "ok");
    CHECK(cell(vt, 0, 0).cp == 'o' && cell(vt, 1, 0).cp == 'k');

    /* More than MND_VT_IMAGE_BYTES_MAX: dropped, never kept. */
    size_t big = MND_VT_IMAGE_BYTES_MAX + 1;
    uint8_t *huge = calloc(1, big);
    png(huge, 40, 40);
    send_image(vt, "inline=1", huge, big);
    free(huge);
    CHECK(g_cap.count == 0);
    feed(vt, "!");
    CHECK(cell(vt, 2, 0).cp == '!');
    mnd_vt_destroy(vt);
}

static void test_formats_are_read_from_the_header(void) {
    uint8_t f[64];
    mnd_image_format fmt;
    int w, h;
    size_t n = png(f, 300, 200);
    CHECK(mnd_image_probe(f, n, &fmt, &w, &h) && fmt == MND_IMAGE_PNG && w == 300 && h == 200);
    n = gif(f, 32, 16);
    CHECK(mnd_image_probe(f, n, &fmt, &w, &h) && fmt == MND_IMAGE_GIF && w == 32 && h == 16);
    n = jpeg(f, 640, 480);
    CHECK(mnd_image_probe(f, n, &fmt, &w, &h) && fmt == MND_IMAGE_JPEG && w == 640 && h == 480);
    for (size_t cut = 0; cut < n; cut++) CHECK(!mnd_image_probe(f, cut, &fmt, &w, &h));
    /* A JPEG segment length that runs past the end, or points back. */
    uint8_t bad[] = {0xFF, 0xD8, 0xFF, 0xE0, 0xFF, 0xFF, 0, 0};
    CHECK(!mnd_image_probe(bad, sizeof bad, &fmt, &w, &h));
    uint8_t zero[] = {0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0xFF, 0xC0};
    CHECK(!mnd_image_probe(zero, sizeof zero, &fmt, &w, &h));
    CHECK(!mnd_image_probe((const uint8_t *)"BM", 2, &fmt, &w, &h));
    CHECK(!mnd_image_probe(NULL, 0, &fmt, &w, &h));

    /* Each format reaches the front end with its name. */
    mnd_vt *vt = mk(20, 10, 0, true);
    n = gif(f, 10, 20);
    send_image(vt, "inline=1", f, n);
    CHECK(g_cap.count == 1 && g_cap.last.format == MND_IMAGE_GIF);
    n = jpeg(f, 10, 20);
    send_image(vt, "inline=1", f, n);
    CHECK(g_cap.count == 2 && g_cap.last.format == MND_IMAGE_JPEG);
    mnd_vt_destroy(vt);
}

/* Image cells are cells: they scroll into history, are cleared and
 * overwritten like text, copy as blanks and are no word. */
static void test_images_scroll_and_clear_like_text(void) {
    uint8_t f[64];
    size_t n = png(f, 20, 40);
    mnd_vt *vt = mk(10, 4, 100, true);
    send_image(vt, "inline=1", f, n);
    CHECK(tile(vt, 0, 0, 1, 0, 0) && tile(vt, 1, 1, 1, 1, 1));
    feed(vt, "\r\n\r\n\r\n\r\n");
    CHECK(image_cells(vt, 0) == 0);
    mnd_vt_scroll(vt, 3);
    CHECK(tile(vt, 0, 0, 1, 0, 0) && tile(vt, 0, 1, 1, 0, 1));
    mnd_vt_scroll_to_bottom(vt);

    char *text = mnd_vt_copy_text(vt, (mnd_pos){0, 0}, (mnd_pos){9, 1}, false);
    CHECK(!text || strspn(text, " \n") == strlen(text));
    free(text);

    feed(vt, "\x1b[H\x1b[2J\x1b[3J");
    mnd_vt_scroll(vt, 10);
    CHECK(image_cells(vt, 0) == 0 && image_cells(vt, 1) == 0);
    mnd_vt_scroll_to_bottom(vt);

    send_image(vt, "inline=1", f, n);
    feed(vt, "\x1b[1;1HX");
    CHECK(cell(vt, 0, 0).cp == 'X' && tile(vt, 1, 0, 2, 1, 0));
    feed(vt, "\x1b[1;3H\xcc\x81"); /* a combining mark after a tile */
    CHECK(tile(vt, 1, 0, 2, 1, 0));
    mnd_pos a, b;
    mnd_vt_word_bounds(vt, (mnd_pos){0, mnd_vt_view_to_abs(vt, 0)}, &a, &b);
    CHECK(a.col == 0 && b.col == 0); /* "X" alone: the image is no part of a word */
    mnd_vt_destroy(vt);
}

/* With images on, programs can learn the size of the text area and of a
 * cell in pixels (CSI 14 t, CSI 16 t), which is how neofetch sizes them. */
static void test_window_size_in_pixels_only_with_images(void) {
    mnd_vt *vt = mk(20, 10, 0, true);
    feed(vt, "\x1b[14t");
    CHECK_STR(g_cap.reply, "\x1b[4;200;200t");
    g_cap.reply_len = 0;
    g_cap.reply[0] = 0;
    feed(vt, "\x1b[16t");
    CHECK_STR(g_cap.reply, "\x1b[6;20;10t");
    mnd_vt_destroy(vt);
}

/* One feed hands at most MND_VT_IMAGE_EVENTS images to the front end; an
 * image it could not hand over is not laid out either. */
static void test_images_per_feed_are_bounded(void) {
    uint8_t f[64];
    size_t n = png(f, 10, 20);
    char *data = b64(f, n);
    size_t one = strlen(data) + 32, total = one * 12 + 1;
    char *all = malloc(total);
    all[0] = 0;
    for (int i = 0; i < 12; i++) {
        char seq[256];
        snprintf(seq, sizeof seq, "\x1b]1337;File=inline=1:%s\a", data);
        strcat(all, seq);
    }
    mnd_vt *vt = mk(20, 10, 0, true);
    feed(vt, all);
    CHECK(g_cap.count == MND_VT_IMAGE_EVENTS);
    CHECK(image_cells(vt, 0) == MND_VT_IMAGE_EVENTS);
    free(all);
    free(data);
    mnd_vt_destroy(vt);
}

/* Ids are reused after MND_VT_IMAGE_ID_MAX images: the old tiles go first,
 * so a cell never shows another image than its own. */
static void test_ids_wrap_without_showing_an_old_image(void) {
    uint8_t f[64];
    size_t n = png(f, 10, 20);
    mnd_vt *vt = mk(10, 4, 1000, true);
    for (int i = 0; i < MND_VT_IMAGE_ID_MAX; i++) send_image(vt, "inline=1", f, n);
    CHECK(g_cap.last.id == MND_VT_IMAGE_ID_MAX);
    feed(vt, "\r\n");
    send_image(vt, "inline=1", f, n);
    CHECK(g_cap.last.id == 1);
    /* Every line once: history from the top of the viewport, then the screen. */
    int ids1 = 0, images = 0;
    for (int off = mnd_vt_scrollback_lines(vt); off >= 0; off--) {
        mnd_vt_scroll_to_bottom(vt);
        mnd_vt_scroll(vt, off);
        for (int y = 0; y < (off == 0 ? 4 : 1); y++)
            for (int x = 0; x < 10; x++) {
                uint32_t cp = cell(vt, x, y).cp;
                if (!mnd_cp_is_image(cp)) continue;
                images++;
                ids1 += mnd_cp_image_id(cp) == 1;
            }
    }
    CHECK(images == 1 && ids1 == 1);
    mnd_vt_destroy(vt);
}

int main(void) {
    fprintf(stderr, "mnd_vt inline images\n");
    RUN(test_images_are_off_by_default);
    RUN(test_an_image_covers_cells_and_moves_the_cursor);
    RUN(test_image_sizes);
    RUN(test_bad_images_are_ignored);
    RUN(test_formats_are_read_from_the_header);
    RUN(test_images_scroll_and_clear_like_text);
    RUN(test_window_size_in_pixels_only_with_images);
    RUN(test_images_per_feed_are_bounded);
    RUN(test_ids_wrap_without_showing_an_old_image);
    TEST_MAIN_END();
}
