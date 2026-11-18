/*
 * mnd_pixels.c — see mnd_pixels.h.
 */
#include "mnd_pixels.h"

#include <string.h>

enum { RUN = 0, PIXELS = 1, ABOVE = 2 };

bool mnd_pixels_unpack(const uint8_t *in, size_t len, uint8_t *out, size_t stride, int width, int height) {
    if (width < 1 || height < 1 || stride / 4 < (size_t)width) return false;
    size_t wide = (size_t)width, total = wide * (size_t)height, done = 0, at = 0;
    while (done < total) {
        uint32_t word;
        if (len - at < 4) return false;
        memcpy(&word, in + at, 4);
        at += 4;
        size_t count = word >> 2;
        int kind = (int)(word & 3);
        if (count == 0 || count > total - done) return false;
        uint32_t color = 0;
        if (kind == RUN) {
            if (len - at < 4) return false;
            memcpy(&color, in + at, 4);
            at += 4;
        } else if (kind == PIXELS) {
            if ((len - at) / 4 < count) return false;
        } else if (kind != ABOVE || done < wide) {
            return false; /* no such kind, or nothing above the first row */
        }
        /* Row by row: a part may go on into the next rows. */
        while (count > 0) {
            size_t x = done % wide, y = done / wide, n = wide - x < count ? wide - x : count;
            uint8_t *to = out + y * stride + x * 4;
            if (kind == RUN) {
                for (size_t i = 0; i < n; i++) memcpy(to + i * 4, &color, 4);
            } else if (kind == PIXELS) {
                memcpy(to, in + at, n * 4);
                at += n * 4;
            } else {
                memcpy(to, to - stride, n * 4); /* the row above is done already: rows that repeat follow from one another */
            }
            done += n;
            count -= n;
        }
    }
    return at == len;
}
