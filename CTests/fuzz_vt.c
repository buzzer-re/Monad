/*
 * fuzz_vt.c — fuzz target for the terminal emulator (F-19).
 *
 * The input is a script of operations on one mnd_vt: raw bytes, escape
 * sequence fragments built from the input (CSI, OSC 0/2/4/7/8/52, DCS,
 * SGR, wide and combining text, inline images with made-up and broken
 * headers, half the runs with images on), resizes, scrolling, reset, selection and
 * copy, word and line bounds, key/mouse/paste encoding, and reading every
 * row, grapheme and link. Invariants are checked after every step: the size
 * is what was asked, every cell has a valid width, a wide cell is followed
 * by its spacer, every link resolves to a bounded URI, the link table stays
 * under its cap, the scroll offset stays within the scrollback, and replies
 * to the guest are bounded. An image handed over is one the header probe
 * agrees with, within the caps, over cells that name a valid image.
 *
 * Built with -fsanitize=fuzzer (clang), LLVMFuzzerTestOneInput is the
 * target. Otherwise main() is a deterministic driver: `fuzz_vt [iterations]
 * [seed]`, default a short run.
 */
#include "../Monad/Backend/vt/mnd_vt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fail(const char *what) {
    fprintf(stderr, "fuzz_vt: invariant broken: %s\n", what);
    abort();
}

/* What the terminal sent back during one feed. */
static size_t replied;

static void on_write(void *ctx, const char *d, size_t n) {
    (void)ctx;
    (void)d;
    replied += n;
}
static void on_title(void *ctx, const char *t) {
    (void)ctx;
    for (const unsigned char *p = (const unsigned char *)t; *p; p++)
        if (*p < 0x20 || *p == 0x7f) fail("a control character in the title");
}
static void on_cwd(void *ctx, const char *u) {
    (void)ctx;
    (void)u;
}
static void on_bell(void *ctx) { (void)ctx; }
static void on_clip(void *ctx, const char *d, size_t n) {
    (void)ctx;
    (void)d;
    if (n > (1u << 20)) fail("a clipboard write larger than an OSC can carry");
}

/* Whether images are on in the current script; images handed over in all. */
static bool images_on;
static long images_seen;

static void on_image(void *ctx, const mnd_vt_image_info *info, const uint8_t *d, size_t n) {
    (void)ctx;
    if (!images_on) fail("an image while images are off");
    if (n > MND_VT_IMAGE_BYTES_MAX) fail("an image file over the cap");
    mnd_image_format f;
    int w, h;
    if (!mnd_image_probe(d, n, &f, &w, &h) || f != info->format || w != info->width || h != info->height)
        fail("an image the header probe does not agree with");
    if (info->id < 1 || info->id > MND_VT_IMAGE_ID_MAX) fail("an image id out of range");
    if (info->cols < 1 || info->rows < 1 || info->cols > MND_VT_IMAGE_CELLS_MAX || info->rows > MND_VT_IMAGE_CELLS_MAX)
        fail("an image over too many cells");
    if (!(info->fill_x > 0 && info->fill_x <= 1 && info->fill_y > 0 && info->fill_y <= 1))
        fail("an image filling more than its cells");
    images_seen++;
}

static const char kB64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

typedef struct {
    const uint8_t *p;
    size_t n;
} cursor;

static unsigned take(cursor *c) {
    if (!c->n) return 0;
    c->n--;
    return *c->p++;
}

static unsigned take16(cursor *c) { return take(c) << 8 | take(c); }

static void feed(mnd_vt *vt, const void *d, size_t n) {
    replied = 0;
    mnd_vt_feed(vt, d, n);
    /* Replies answer requests in the input: never more than a small multiple. */
    if (replied > 64 + 64 * n) fail("replies out of proportion to the input");
}

/* An escape sequence fragment with numbers and text from the input. */
static void feed_sequence(mnd_vt *vt, cursor *c) {
    char s[4096];
    size_t at = 0;
    unsigned kind = take(c) % 13;
    static const char finals[] = "@ABCDEFGHIJKLMPSTXZ`abcdefghilmnpqrstuxz{|}~";
    static const char *const oscs[] = {"0", "2", "4", "7", "8", "10", "11", "12", "52", "104", "112", "1337"};
#define PUT(...) at += (size_t)snprintf(s + at, sizeof s - at, __VA_ARGS__)
    switch (kind) {
    case 0: /* CSI with parameters, maybe private, maybe intermediate */
        PUT("\x1b[%s", take(c) % 3 == 0 ? "?" : take(c) % 5 == 0 ? ">" : "");
        for (unsigned i = 0, k = take(c) % 6; i < k; i++) PUT("%s%u", i ? (take(c) % 7 ? ";" : ":") : "", take16(c) % 2100);
        if (take(c) % 6 == 0) PUT("%c", " !\"$'"[take(c) % 5]);
        PUT("%c", finals[take(c) % (sizeof finals - 1)]);
        break;
    case 1: { /* OSC with text */
        PUT("\x1b]%s;", oscs[take(c) % (sizeof oscs / sizeof oscs[0])]);
        unsigned len = take(c) % 200;
        for (unsigned i = 0; i < len && at < sizeof s - 8; i++) {
            unsigned ch = take(c);
            s[at++] = (char)(ch == 0x07 || ch == 0x1b ? 'x' : ch);
        }
        PUT("%s", take(c) % 2 ? "\x07" : "\x1b\\");
        break;
    }
    case 2: { /* OSC 8 hyperlink around some text, sometimes huge */
        unsigned len = take(c) % 4 == 0 ? 2000 + take16(c) % 1000 : take(c) % 60;
        PUT("\x1b]8;id=%u;https://h.test/", take(c));
        for (unsigned i = 0; i < len && at < sizeof s - 32; i++) s[at++] = (char)('a' + take(c) % 26);
        PUT("\x1b\\link\x1b]8;;\x1b\\");
        break;
    }
    case 3: /* SGR, including colors */
        PUT("\x1b[%u;%u;5;%u;48;2;%u;%u;%um", take(c) % 110, take(c) % 2 ? 38 : 58, take(c), take(c), take(c), take(c));
        break;
    case 4: /* DCS requests */
        PUT("\x1bP%s", take(c) % 2 ? "$q" : "+q");
        for (unsigned i = 0, k = take(c) % 40; i < k; i++) s[at++] = "0123456789abcdef;mr q\x7f"[take(c) % 22];
        PUT("\x1b\\");
        break;
    case 5: /* wide, combining and ZWJ text */
        PUT("%s", (const char *[]){"\xe6\x97\xa5", "e\xcc\x81", "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9",
                                   "\xef\xbc\xa1", "\xe2\x80\x8b", "\xf0\x9f\x87\xaf\xf0\x9f\x87\xb5"}[take(c) % 6]);
        break;
    case 6: /* margins and origin */
        PUT("\x1b[%u;%ur\x1b[?6%c\x1b[%u;%us", take(c) % 40, take(c) % 40, take(c) % 2 ? 'h' : 'l', take(c) % 90,
            take(c) % 90);
        break;
    case 7: /* modes */
        PUT("\x1b[?%u%c", (unsigned[]){1, 6, 7, 25, 47, 1000, 1002, 1003, 1004, 1006, 1007, 1047, 1049, 2004,
                                       2026}[take(c) % 15],
            take(c) % 2 ? 'h' : 'l');
        break;
    case 8: /* title stack */
        PUT("\x1b[%u;%ut", take(c) % 2 ? 22 : 23, take(c) % 3);
        break;
    case 9: /* charsets and plain escapes */
        PUT("\x1b%c", "()*+78=>DEHMNOZc"[take(c) % 16]);
        if (take(c) % 2) PUT("%c", "0AB<"[take(c) % 4]);
        break;
    case 10: /* C1 controls as UTF-8, CAN and SUB in the middle of things */
        PUT("\x1b]2;a\xc2%cb%c", 0x80 + take(c) % 32, take(c) % 2 ? 0x18 : 0x1a);
        break;
    case 11: { /* an inline image: a made-up header, sometimes broken, and arguments */
        uint8_t f[64];
        size_t n;
        unsigned w = take16(c) % 9000, h = take16(c) % 9000;
        switch (take(c) % 4) {
        case 0:
            memcpy(f, "\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR", 16);
            f[16] = 0, f[17] = 0, f[18] = (uint8_t)(w >> 8), f[19] = (uint8_t)w;
            f[20] = 0, f[21] = 0, f[22] = (uint8_t)(h >> 8), f[23] = (uint8_t)h;
            memset(f + 24, 0, 9);
            n = 33;
            break;
        case 1:
            memcpy(f, "GIF89a", 6);
            f[6] = (uint8_t)w, f[7] = (uint8_t)(w >> 8), f[8] = (uint8_t)h, f[9] = (uint8_t)(h >> 8);
            memset(f + 10, 0, 3);
            n = 13;
            break;
        case 2: {
            static const uint8_t j[] = {0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 0, 0, 0xFF, 0xC0, 0, 11, 8};
            memcpy(f, j, sizeof j);
            f[13] = (uint8_t)(h >> 8), f[14] = (uint8_t)h, f[15] = (uint8_t)(w >> 8), f[16] = (uint8_t)w;
            memset(f + 17, 1, 4);
            n = 21;
            break;
        }
        default:
            n = take(c) % 40;
            for (size_t i = 0; i < n; i++) f[i] = (uint8_t)take(c);
            break;
        }
        for (unsigned i = 0, k = take(c) % 3; i < k && n; i++) f[take(c) % n] = (uint8_t)take(c); /* broken */
        if (take(c) % 4 == 0) n = take(c) % (n + 1);                                                  /* cut short */
        static const char *const sizes[] = {"", ";width=3", ";height=50%", ";width=200px;height=7", ";width=auto",
                                            ";width=0", ";height=999999px", ";width=x", ";preserveAspectRatio=0;width=9"};
        PUT("\x1b]1337;File=name=eA==;inline=%u%s:", take(c) % 5 ? 1 : 0, sizes[take(c) % 9]);
        for (size_t i = 0; i < n; i += 3) {
            uint32_t v = (uint32_t)f[i] << 16 | (i + 1 < n ? (uint32_t)f[i + 1] << 8 : 0) | (i + 2 < n ? f[i + 2] : 0);
            PUT("%c%c%c%c", kB64[v >> 18 & 63], kB64[v >> 12 & 63], i + 1 < n ? kB64[v >> 6 & 63] : '=',
                i + 2 < n ? kB64[v & 63] : '=');
        }
        PUT("%s", take(c) % 8 ? "\x07" : "");
        break;
    }
    default: /* a fragment cut short */
        PUT("\x1b%c%u", "[]P^_X"[take(c) % 6], take(c));
        break;
    }
#undef PUT
    if (at > sizeof s) at = sizeof s;
    feed(vt, s, at);
}

static void check(mnd_vt *vt, int cols, int rows, int scrollback) {
    int c, r;
    mnd_vt_size(vt, &c, &r);
    if (c != cols || r != rows) fail("the size is not what was asked");
    if (mnd_vt_link_bytes(vt) > MND_VT_LINK_BYTES_MAX) fail("the link table grew past its cap");
    int off = mnd_vt_scroll_offset(vt), sb = mnd_vt_scrollback_lines(vt);
    if (off < 0 || off > sb || sb > scrollback) fail("scrolled outside the scrollback");
    mnd_vt_lock(vt);
    for (int y = 0; y < rows; y++) {
        int len;
        const mnd_cell *row = mnd_vt_view_row(vt, y, &len);
        if (!row || len != cols) fail("a row of the wrong length");
        for (int x = 0; x < len; x++) {
            unsigned w = mnd_cell_width(&row[x]);
            if (w > MND_WIDTH_SPACER) fail("an unknown cell width");
            if (w == MND_WIDTH_WIDE && x + 1 < len && mnd_cell_width(&row[x + 1]) != MND_WIDTH_SPACER)
                fail("a wide cell without its spacer");
            if (w == MND_WIDTH_SPACER && (x == 0 || mnd_cell_width(&row[x - 1]) != MND_WIDTH_WIDE))
                fail("a spacer without its wide cell");
            if (mnd_cp_is_image(row[x].cp)) {
                uint32_t id = mnd_cp_image_id(row[x].cp);
                if (id < 1 || id > MND_VT_IMAGE_ID_MAX) fail("a tile of no image");
                uint32_t none[2];
                if (mnd_vt_grapheme(vt, row[x].cp, none, 2) != 0) fail("an image tile with text");
            }
            if (row[x].cp & MND_CP_GRAPHEME_FLAG) {
                uint32_t cps[32];
                size_t k = mnd_vt_grapheme(vt, row[x].cp, cps, 32);
                if (k == 0) fail("a grapheme reference that resolves to nothing");
            }
            if (row[x].link) {
                const char *uri = mnd_vt_link_uri(vt, row[x].link);
                if (!uri) fail("a cell links to nothing");
                if (strlen(uri) > MND_VT_LINK_URI_MAX) fail("a link longer than the cap");
            }
        }
        (void)mnd_vt_view_row_wrapped(vt, y);
    }
    mnd_cursor_info cur = mnd_vt_cursor(vt);
    /* Scrolled back, the cursor's row is below the viewport and not shown. */
    if (cur.x < 0 || cur.x > cols || cur.y < 0 || (cur.visible && cur.y >= rows)) {
        fprintf(stderr, "cursor %d,%d visible %d on %dx%d\n", cur.x, cur.y, cur.visible, cols, rows);
        fail("the cursor is off the screen");
    }
    uint8_t dirty[512];
    (void)mnd_vt_take_dirty(vt, dirty, rows);
    mnd_vt_unlock(vt);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    cursor c = {data, size};
    mnd_vt_callbacks cb = {NULL, on_write, on_title, on_cwd, on_bell, on_clip, on_image};
    int cols = 1 + (int)(take(&c) % 120), rows = 1 + (int)(take(&c) % 50), scrollback = (int)(take(&c) % 3) * 100;
    mnd_vt *vt = mnd_vt_create(cols, rows, scrollback, &cb);
    if (!vt) fail("no terminal for a valid size");
    images_on = take(&c) % 2;
    mnd_vt_set_images(vt, images_on);
    mnd_vt_set_cell_pixels(vt, 1 + (int)(take(&c) % 40), 1 + (int)(take(&c) % 80));
    while (c.n) {
        unsigned op = take(&c) % 16;
        switch (op) {
        case 0: case 1: case 2: case 3: { /* raw bytes */
            size_t n = take(&c) % 128;
            if (n > c.n) n = c.n;
            feed(vt, c.p, n);
            c.p += n;
            c.n -= n;
            break;
        }
        case 4: case 5: case 6:
            feed_sequence(vt, &c);
            break;
        case 7: { /* resize: always refused below 1x1, kept otherwise */
            int nc = (int)(take(&c) % 300), nr = (int)(take(&c) % 100);
            if (mnd_vt_resize(vt, nc, nr)) {
                cols = nc;
                rows = nr;
            } else if (nc >= 1 && nr >= 1) {
                fail("a valid size was refused");
            }
            break;
        }
        case 8:
            mnd_vt_scroll(vt, (int)(take(&c) % 64) - 32);
            break;
        case 9:
            if (take(&c) % 4 == 0) mnd_vt_reset(vt);
            else if (take(&c) % 2) mnd_vt_clear_scrollback(vt);
            else mnd_vt_scroll_to_bottom(vt);
            break;
        case 10: { /* select and copy */
            int y1 = (int)(take(&c) % (unsigned)rows), y2 = (int)(take(&c) % (unsigned)rows);
            mnd_pos a = {(int)(take(&c) % (unsigned)(cols + 2)) - 1, mnd_vt_view_to_abs(vt, y1)};
            mnd_pos b = {(int)(take(&c) % (unsigned)(cols + 2)) - 1, mnd_vt_view_to_abs(vt, y2)};
            char *text = mnd_vt_copy_text(vt, a, b, take(&c) % 2);
            free(text);
            mnd_pos s, e;
            mnd_vt_word_bounds(vt, a, &s, &e);
            mnd_vt_line_bounds(vt, b, &s, &e);
            break;
        }
        case 11: { /* input encoding */
            char out[64];
            unsigned mods = take(&c) % 16;
            (void)mnd_vt_encode_key(vt, (mnd_key)(take(&c) % MND_KEY_COUNT_), mods, out, sizeof out);
            (void)mnd_vt_encode_char(vt, take16(&c), mods, out, sizeof out);
            (void)mnd_vt_encode_mouse(vt, (int)(take(&c) % 8), (mnd_mouse_action)(take(&c) % 3), mods,
                                      (int)(take(&c) % (unsigned)cols), (int)(take(&c) % (unsigned)rows), out, sizeof out);
            (void)mnd_vt_encode_focus(vt, take(&c) % 2, out, sizeof out);
            break;
        }
        case 13: { /* the header probe on raw bytes */
            size_t n = take(&c) % 64;
            if (n > c.n) n = c.n;
            mnd_image_format f;
            int w, h;
            if (mnd_image_probe(c.p, n, &f, &w, &h) &&
                (w < 1 || h < 1 || w > MND_VT_IMAGE_SIDE_MAX || h > MND_VT_IMAGE_SIDE_MAX ||
                 (uint64_t)w * (uint64_t)h > MND_VT_IMAGE_PIXELS_MAX))
                fail("the probe passed a size over the caps");
            c.p += n;
            c.n -= n;
            break;
        }
        case 12: { /* paste: never an ESC out of bracketed mode */
            size_t n = take(&c) % 64, out_len = 0;
            if (n > c.n) n = c.n;
            char *p = mnd_vt_encode_paste(vt, (const char *)c.p, n, &out_len);
            if (p) {
                bool bracketed = out_len >= 12 && memcmp(p, "\x1b[200~", 6) == 0;
                for (size_t i = bracketed ? 6 : 0; i < out_len - (bracketed ? 6 : 0); i++)
                    if (p[i] == 0x1b) fail("an escape inside a paste");
                free(p);
            }
            c.p += n;
            c.n -= n;
            break;
        }
        default: /* text with newlines, to scroll */
        {
            static const char text[] = "line\r\nnext \xe6\x97\xa5\r\n";
            feed(vt, text, sizeof text - 1);
        }
            break;
        }
        check(vt, cols, rows, scrollback);
    }
    mnd_vt_destroy(vt);
    return 0;
}

#ifndef MND_LIBFUZZER
/* ---- The built-in driver: random scripts ------------------------------------ */

static uint64_t rng_state;

static uint32_t rnd(void) {
    rng_state = rng_state * 6364136223846793005ull + 1442695040888963407ull;
    return (uint32_t)(rng_state >> 33);
}

/* A number, or the fallback (make passes the build folder as the first argument). */
static long number(const char *s, long fallback) {
    char *end;
    long v = s && *s ? strtol(s, &end, 0) : 0;
    return s && *s && !*end ? v : fallback;
}

int main(int argc, char **argv) {
    long iterations = number(argc > 1 ? argv[1] : NULL, number(getenv("FUZZ_ITERS"), 2000));
    rng_state = (uint64_t)number(argc > 2 ? argv[2] : getenv("FUZZ_SEED"), 0x4d4f4e4144);
    static uint8_t input[8192];
    for (long it = 0; it < iterations; it++) {
        size_t len = 8 + rnd() % (sizeof input - 8);
        for (size_t i = 0; i < len; i++) input[i] = (uint8_t)rnd();
        LLVMFuzzerTestOneInput(input, len);
    }
    fprintf(stderr, "fuzz_vt: %ld scripts (%ld images handed over), no invariant broken\n", iterations, images_seen);
    return 0;
}
#endif
