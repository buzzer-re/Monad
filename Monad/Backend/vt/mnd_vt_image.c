/*
 * mnd_vt_image.c — inline images: iTerm2's OSC 1337 File=...;inline=1.
 *
 * Only while images are on (a VM's setting). The file comes from the guest:
 * the core reads its header for the format and size (PNG, JPEG or GIF,
 * bounded), never decodes it, lays it out over cells from the cursor and
 * queues its bytes for the front end, which decodes them. Anything it
 * cannot vouch for is dropped whole.
 */
#include "mnd_vt_internal.h"

#include <stdlib.h>
#include <string.h>

static double dmin(double a, double b) { return a < b ? a : b; }

/* Cells for a length in pixels: rounded up, at least one. */
static int cells_for(double px, double cell) {
    double n = px / cell - 1e-9;
    int c = (int)n;
    if (c < n) c++;
    return c < 1 ? 1 : c;
}

/* ---- Header probe ------------------------------------------------------- */

static uint32_t be16(const uint8_t *p) { return (uint32_t)p[0] << 8 | p[1]; }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

/* SOF markers carry the frame size; DHT (C4), JPG (C8) and DAC (CC) do not. */
static bool jpeg_is_sof(uint8_t m) { return m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC; }

static bool probe_jpeg(const uint8_t *d, size_t len, int *w, int *h) {
    size_t i = 2;
    while (i + 4 <= len) {
        if (d[i] != 0xFF) return false;
        uint8_t m = d[i + 1];
        if (m == 0xFF) { /* fill byte */
            i++;
            continue;
        }
        if (m == 0x01 || (m >= 0xD0 && m <= 0xD7)) { /* no length */
            i += 2;
            continue;
        }
        if (m == 0xD8 || m == 0xD9 || m == 0xDA) return false; /* no frame header before the data */
        uint32_t seg = be16(d + i + 2);
        if (seg < 2 || i + 2 + seg > len) return false;
        if (jpeg_is_sof(m)) {
            if (seg < 7) return false;
            *h = (int)be16(d + i + 5);
            *w = (int)be16(d + i + 7);
            return true;
        }
        i += 2 + seg;
    }
    return false;
}

bool mnd_image_probe(const uint8_t *data, size_t len, mnd_image_format *format, int *width, int *height) {
    if (!data) return false;
    int w = 0, h = 0;
    mnd_image_format f;
    static const uint8_t png_sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
    if (len >= 8 + 8 + 13 && memcmp(data, png_sig, 8) == 0 && memcmp(data + 12, "IHDR", 4) == 0 &&
        be32(data + 8) == 13) {
        uint32_t pw = be32(data + 16), ph = be32(data + 20);
        if (pw > MND_VT_IMAGE_SIDE_MAX || ph > MND_VT_IMAGE_SIDE_MAX) return false;
        w = (int)pw;
        h = (int)ph;
        f = MND_IMAGE_PNG;
    } else if (len >= 13 && (memcmp(data, "GIF87a", 6) == 0 || memcmp(data, "GIF89a", 6) == 0)) {
        w = data[6] | data[7] << 8;
        h = data[8] | data[9] << 8;
        f = MND_IMAGE_GIF;
    } else if (len >= 4 && data[0] == 0xFF && data[1] == 0xD8) {
        if (!probe_jpeg(data, len, &w, &h)) return false;
        f = MND_IMAGE_JPEG;
    } else {
        return false;
    }
    if (w < 1 || h < 1 || w > MND_VT_IMAGE_SIDE_MAX || h > MND_VT_IMAGE_SIDE_MAX) return false;
    if ((uint64_t)w * (uint64_t)h > MND_VT_IMAGE_PIXELS_MAX) return false;
    *format = f;
    *width = w;
    *height = h;
    return true;
}

/* ---- Arguments ------------------------------------------------------------- */

typedef enum { SIZE_AUTO = 0, SIZE_CELLS, SIZE_PIXELS, SIZE_PERCENT } size_unit;

typedef struct {
    size_unit unit;
    double value;
} size_spec;

/* "N", "Npx", "N%" or "auto"; false for anything else. */
static bool parse_size(const char *s, size_t n, size_spec *out) {
    if (n == 4 && memcmp(s, "auto", 4) == 0) {
        out->unit = SIZE_AUTO;
        return true;
    }
    double v = 0;
    size_t i = 0;
    for (; i < n && s[i] >= '0' && s[i] <= '9'; i++) {
        v = v * 10 + (s[i] - '0');
        if (v > 100000) return false;
    }
    if (i == 0) return false;
    const char *unit = s + i;
    size_t un = n - i;
    if (un == 0) out->unit = SIZE_CELLS;
    else if (un == 2 && memcmp(unit, "px", 2) == 0) out->unit = SIZE_PIXELS;
    else if (un == 1 && unit[0] == '%') out->unit = SIZE_PERCENT;
    else return false;
    if (v == 0) return false;
    out->value = v;
    return true;
}

typedef struct {
    bool inline_image;
    bool keep_aspect;
    size_spec width, height;
} image_args;

/* "key=value;key=value" up to the ':' before the data. */
static bool parse_args(const char *s, size_t n, image_args *a) {
    *a = (image_args){.keep_aspect = true};
    size_t i = 0;
    while (i < n) {
        size_t end = i;
        while (end < n && s[end] != ';') end++;
        const char *kv = s + i, *eq = memchr(kv, '=', end - i);
        if (eq) {
            size_t kn = (size_t)(eq - kv), vn = end - i - kn - 1;
            const char *v = eq + 1;
            if (kn == 6 && memcmp(kv, "inline", 6) == 0) a->inline_image = vn == 1 && v[0] == '1';
            else if (kn == 19 && memcmp(kv, "preserveAspectRatio", 19) == 0) a->keep_aspect = !(vn == 1 && v[0] == '0');
            else if (kn == 5 && memcmp(kv, "width", 5) == 0) {
                if (!parse_size(v, vn, &a->width)) return false;
            } else if (kn == 6 && memcmp(kv, "height", 6) == 0) {
                if (!parse_size(v, vn, &a->height)) return false;
            }
            /* name, size and others: not needed */
        }
        i = end + 1;
    }
    return true;
}

/* ---- Layout ------------------------------------------------------------------ */

static double resolve(size_spec s, double cell, double whole) {
    switch (s.unit) {
    case SIZE_CELLS: return s.value * cell;
    case SIZE_PIXELS: return s.value;
    case SIZE_PERCENT: return s.value * whole / 100;
    case SIZE_AUTO: break;
    }
    return 0;
}

/* The image's box in cells and the share of it the image fills. */
static void layout(const mnd_vt *vt, const image_args *a, int img_w, int img_h, mnd_vt_image_info *out) {
    double cw = vt->cell_px_w, ch = vt->cell_px_h;
    double term_w = vt->cols * cw, term_h = vt->rows * ch;
    double bw = resolve(a->width, cw, term_w), bh = resolve(a->height, ch, term_h);
    double iw = img_w, ih = img_h; /* what the image itself takes */
    if (bw == 0 && bh == 0) {
        bw = iw;
        bh = ih;
    } else if (bh == 0) {
        bh = a->keep_aspect ? ih * bw / iw : ih;
        iw = bw;
        ih = bh;
    } else if (bw == 0) {
        bw = a->keep_aspect ? iw * bh / ih : iw;
        iw = bw;
        ih = bh;
    } else if (a->keep_aspect) {
        double fit = dmin(bw / iw, bh / ih);
        iw *= fit;
        ih *= fit;
    } else {
        iw = bw;
        ih = bh;
    }
    /* Never wider than the terminal, nor more cells than the cap. */
    double max_w = dmin(term_w, MND_VT_IMAGE_CELLS_MAX * cw), max_h = MND_VT_IMAGE_CELLS_MAX * ch;
    double s = dmin(1, dmin(max_w / bw, max_h / bh));
    bw *= s;
    bh *= s;
    iw *= s;
    ih *= s;
    int cols = cells_for(bw, cw), rows = cells_for(bh, ch);
    if (cols > vt->cols) cols = vt->cols;
    if (cols > MND_VT_IMAGE_CELLS_MAX) cols = MND_VT_IMAGE_CELLS_MAX;
    if (rows > MND_VT_IMAGE_CELLS_MAX) rows = MND_VT_IMAGE_CELLS_MAX;
    out->cols = cols;
    out->rows = rows;
    out->fill_x = dmin(1, iw / (cols * cw));
    out->fill_y = dmin(1, ih / (rows * ch));
}

void mnd_vt_osc_1337(mnd_vt *vt, const char *arg) {
    if (!vt->images_on || strncmp(arg, "File=", 5) != 0) return;
    if (vt->nev_images >= MND_VT_IMAGE_EVENTS) return; /* the front end could not have it */
    const char *args = arg + 5, *colon = strchr(args, ':');
    if (!colon) return;
    image_args a;
    if (!parse_args(args, (size_t)(colon - args), &a) || !a.inline_image) return;

    mnd_buf file = {0};
    mnd_image_format fmt;
    int w, h;
    if (!mnd_b64_decode(colon + 1, MND_VT_IMAGE_BYTES_MAX, &file) ||
        !mnd_image_probe((const uint8_t *)file.data, file.len, &fmt, &w, &h)) {
        mnd_buf_free(&file);
        return;
    }

    /* Ids wrap: the tiles of every older image go first. */
    if (vt->next_image_id >= MND_VT_IMAGE_ID_MAX) {
        mnd_vt_scrub_images(vt);
        vt->next_image_id = 0;
    }
    uint32_t id = ++vt->next_image_id;
    mnd_vt_image_info info = {.id = id, .format = fmt, .width = w, .height = h};
    layout(vt, &a, w, h, &info);

    /* From the cursor, or the next line's start when it does not fit. */
    if (vt->cur.wrapnext || vt->cur.x + info.cols > vt->cols) {
        if (vt->cur.x > 0 || vt->cur.wrapnext) {
            vt->cur.x = 0;
            vt->cur.wrapnext = false;
            mnd_vt_index(vt);
        }
    }
    int x0 = vt->cur.x;
    for (int r = 0; r < info.rows; r++) {
        if (r > 0) {
            mnd_vt_index(vt);
            vt->cur.x = x0;
        }
        mnd_vt_put_image_row(vt, x0, info.cols, id, r);
    }
    int x = x0 + info.cols;
    if (x >= vt->cols) {
        vt->cur.x = vt->cols - 1;
        vt->cur.wrapnext = vt->autowrap;
    } else {
        vt->cur.x = x;
        vt->cur.wrapnext = false;
    }

    vt->ev_images[vt->nev_images++] = (mnd_image_event){info, file};
}
