/*
 * mwm_pack.c — see mwm_pack.h.
 */
#include "mwm_pack.h"

#include <stdbool.h>
#include <string.h>

enum { RUN = 0, PIXELS = 1, ABOVE = 2, NONE = 3 };
/* The most pixels one part can say. */
#define MOST 0x3fffffffu

typedef struct {
    uint8_t *out;
    size_t len, max;
    /* The part being made: its kind, how many pixels it is so far, the
     * colour of a run, and where the count of pixels that follow goes. */
    int kind;
    uint32_t count, color;
    size_t count_at;
    bool full;
} packer;

static void put_word(packer *p, uint32_t v) {
    if (p->full || p->max - p->len < 4) {
        p->full = true;
        return;
    }
    memcpy(p->out + p->len, &v, 4);
    p->len += 4;
}

/* The part being made is done. */
static void end_part(packer *p) {
    if (p->kind == RUN) {
        put_word(p, p->count << 2 | RUN);
        put_word(p, p->color);
    } else if (p->kind == ABOVE) {
        put_word(p, p->count << 2 | ABOVE);
    } else if (p->kind == PIXELS && !p->full) {
        uint32_t v = p->count << 2 | PIXELS;
        memcpy(p->out + p->count_at, &v, 4);
    }
    p->kind = NONE;
    p->count = 0;
}

/* `count` more pixels of a kind: with the part being made when it is of
 * that kind (and that colour), else a new one. */
static void add(packer *p, int kind, uint32_t color, const uint32_t *pixels, uint32_t count) {
    if (p->kind != kind || (kind == RUN && p->color != color) || p->count > MOST - count) {
        end_part(p);
        p->kind = kind;
        p->color = color;
        if (kind == PIXELS) {
            p->count_at = p->len;
            put_word(p, 0);
        }
    }
    if (kind == PIXELS) {
        if (p->full || (p->max - p->len) / 4 < count) {
            p->full = true;
            return;
        }
        memcpy(p->out + p->len, pixels, (size_t)count * 4);
        p->len += (size_t)count * 4;
    }
    p->count += count;
}

size_t mwm_pack(const uint32_t *pixels, int stride, int width, int height, uint8_t *out, size_t max) {
    packer p = {.out = out, .max = max, .kind = NONE};
    for (int y = 0; y < height && !p.full; y++) {
        const uint32_t *row = pixels + (size_t)y * (size_t)stride, *up = y > 0 ? row - stride : NULL;
        for (int x = 0; x < width && !p.full;) {
            /* How far the row goes on as the one above, and how far in the colour it has here. */
            int above = 0, same = 1;
            if (up) {
                while (x + above < width && row[x + above] == up[x + above]) above++;
            }
            while (x + same < width && row[x + same] == row[x]) same++;
            /* "As above" is a word and a run is two: either is worth it from that many pixels
             * on. A part of the same kind that goes on costs nothing more. */
            if (above >= same && (above >= 2 || (above == 1 && p.kind == ABOVE))) {
                add(&p, ABOVE, 0, NULL, (uint32_t)above);
                x += above;
            } else if (same >= 3 || (p.kind == RUN && p.color == row[x])) {
                add(&p, RUN, row[x], NULL, (uint32_t)same);
                x += same;
            } else {
                add(&p, PIXELS, 0, row + x, 1);
                x++;
            }
        }
    }
    end_part(&p);
    return p.full ? 0 : p.len;
}
