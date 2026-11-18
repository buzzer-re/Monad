/*
 * test_wm_pack.c — a window's pixels made small for the way to the Mac
 * (GuestWM/mwm_pack, in the guest) and made whole again there
 * (Monad/Backend/mnd_pixels, in MonadHost): what goes in comes out, flat
 * parts and repeated rows take next to nothing, and bytes that are no
 * pixels of that size are refused without a byte written outside the
 * picture. The Mac's side reads what a guest sends: hostile.
 */
#include "mnd_pixels.h"
#include "mwm_pack.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)

static uint64_t rng_state = 0x4d4f4e4144;
static uint32_t rnd(void) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return (uint32_t)(rng_state >> 16);
}

/* Packs w × h pixels (rows `stride` words apart) and unpacks them into a
 * picture with rows of another length: the same pixels; how many bytes
 * they took on the way (0: more than they are as they are). */
static size_t there_and_back(const uint32_t *pixels, int stride, int w, int h) {
    size_t raw = (size_t)w * (size_t)h * 4, row = (size_t)(w + 3) * 4;
    uint8_t *packed = malloc(raw), *out = malloc(row * (size_t)h + 8);
    CHECK(packed && out);
    size_t n = mwm_pack(pixels, stride, w, h, packed, raw);
    CHECK(n <= raw);
    if (n > 0) {
        memset(out, 0xee, row * (size_t)h + 8);
        /* Exactly the bytes it made: ASan sees a read past them. */
        uint8_t *exact = malloc(n);
        CHECK(exact);
        memcpy(exact, packed, n);
        CHECK(mnd_pixels_unpack(exact, n, out, row, w, h));
        free(exact);
        for (int y = 0; y < h; y++) {
            CHECK(memcmp(out + (size_t)y * row, pixels + (size_t)y * (size_t)stride, (size_t)w * 4) == 0);
            for (int k = 0; k < 12; k++) CHECK(out[(size_t)y * row + (size_t)w * 4 + (size_t)k] == 0xee); /* nothing beside the picture */
        }
        for (int k = 0; k < 8; k++) CHECK(out[row * (size_t)h + (size_t)k] == 0xee); /* nothing after it */
    }
    free(packed);
    free(out);
    return n;
}

/* What a program's window is mostly made of takes next to nothing. */
static void test_flat_parts_and_repeated_rows_are_small(void) {
    enum { WIDE = 300, HIGH = 200 };
    static uint32_t p[WIDE * HIGH];
    for (int i = 0; i < WIDE * HIGH; i++) p[i] = 0xff202020u;
    size_t n = there_and_back(p, WIDE, WIDE, HIGH);
    CHECK(n > 0 && n <= 16); /* one colour: said once */

    /* Text on a flat ground: a few pixels of another colour in some rows. */
    for (int y = 20; y < 180; y += 3)
        for (int x = 10; x < 290; x += 7) p[y * WIDE + x] = 0xffe0e0e0u + (uint32_t)(x % 5);
    n = there_and_back(p, WIDE, WIDE, HIGH);
    CHECK(n > 0 && n < WIDE * HIGH * 4 / 4);

    /* Rows that repeat (a gradient across, the same all the way down): one row, and "as above". */
    for (int y = 0; y < HIGH; y++)
        for (int x = 0; x < WIDE; x++) p[y * WIDE + x] = 0xff000000u | (uint32_t)(x * 65793);
    n = there_and_back(p, WIDE, WIDE, HIGH);
    CHECK(n > 0 && n <= WIDE * 4 + 16);

    /* Noise is not made smaller: it is said so (0), and goes as it is. */
    for (int i = 0; i < WIDE * HIGH; i++) p[i] = rnd();
    CHECK(there_and_back(p, WIDE, WIDE, HIGH) == 0);
}

/* Whatever the pixels and the size, they come back the same. */
static void test_any_pixels_come_back(void) {
    enum { MOST = 40 };
    static uint32_t p[(MOST + 5) * MOST];
    for (int round = 0; round < 4000; round++) {
        int w = 1 + (int)(rnd() % MOST), h = 1 + (int)(rnd() % MOST), stride = w + (int)(rnd() % 5);
        uint32_t palette[4] = {rnd(), rnd(), rnd(), rnd()};
        int kind = (int)(rnd() % 5);
        for (int y = 0; y < h; y++)
            for (int x = 0; x < stride; x++) {
                uint32_t v;
                switch (kind) {
                case 0: v = palette[0]; break;                                   /* flat */
                case 1: v = palette[rnd() % 2]; break;                           /* two colours, mixed */
                case 2: v = palette[(x / (1 + (int)(palette[3] % 6))) % 4]; break; /* stripes down: rows repeat */
                case 3: v = rnd() % 8 ? palette[(y / 3) % 4] : rnd(); break;     /* bands across with specks */
                default: v = rnd(); break;                                       /* noise */
                }
                p[y * stride + x] = v;
            }
        (void)there_and_back(p, stride, w, h);
    }
    /* The smallest there is, and a row and a column. */
    uint32_t one = 0x12345678u;
    (void)there_and_back(&one, 1, 1, 1);
    (void)there_and_back(p, 1, 1, MOST);
    (void)there_and_back(p, MOST, MOST, 1);
    /* No room for it at all: said so, nothing written. */
    uint8_t small[8] = {0};
    CHECK(mwm_pack(p, MOST, MOST, MOST, small, 0) == 0);
    CHECK(mwm_pack(p, MOST, MOST, MOST, small, 3) == 0 && small[0] == 0);
}

static void word(uint8_t *at, uint32_t v) { memcpy(at, &v, 4); }

/* Bytes that are no pixels of that size are refused, and nothing is
 * written outside the picture whatever they say. */
static void test_what_is_no_picture_is_refused(void) {
    enum { RUN = 0, PIXELS = 1, ABOVE = 2 };
    uint8_t in[64], out[4 * 4 * 4 + 16];
    memset(out, 0xee, sizeof out);
#define CTL(kind, count) (((uint32_t)(count) << 2) | (kind))
    /* 4 × 4: a run of 16. */
    word(in, CTL(RUN, 16));
    word(in + 4, 0xff010203u);
    CHECK(mnd_pixels_unpack(in, 8, out, 16, 4, 4));
    CHECK(out[0] == 0x03 && out[63] == 0xff && out[64] == 0xee);
    CHECK(!mnd_pixels_unpack(in, 7, out, 16, 4, 4));  /* its colour cut short */
    CHECK(!mnd_pixels_unpack(in, 3, out, 16, 4, 4));  /* not even a count */
    CHECK(!mnd_pixels_unpack(in, 0, out, 16, 4, 4));  /* nothing */
    CHECK(!mnd_pixels_unpack(in, 12, out, 16, 4, 4)); /* more bytes than the picture takes */
    word(in, CTL(RUN, 17));
    CHECK(!mnd_pixels_unpack(in, 8, out, 16, 4, 4)); /* more pixels than there are */
    word(in, CTL(RUN, 15));
    CHECK(!mnd_pixels_unpack(in, 8, out, 16, 4, 4)); /* fewer */
    word(in, CTL(RUN, 0));
    CHECK(!mnd_pixels_unpack(in, 8, out, 16, 4, 4)); /* none at all */
    word(in, CTL(RUN, 0x3fffffff));
    CHECK(!mnd_pixels_unpack(in, 8, out, 16, 4, 4)); /* as many as a count can say */
    word(in, CTL(3, 16));
    CHECK(!mnd_pixels_unpack(in, 8, out, 16, 4, 4)); /* a kind there is none of */
    /* "As above" in the first row has nothing above it. */
    word(in, CTL(ABOVE, 16));
    CHECK(!mnd_pixels_unpack(in, 4, out, 16, 4, 4));
    word(in, CTL(PIXELS, 3));
    word(in + 16, CTL(ABOVE, 13));
    CHECK(!mnd_pixels_unpack(in, 20, out, 16, 4, 4)); /* begins one short of the second row */
    /* A row, then "as above" for all the rest: the row all the way down. */
    word(in, CTL(PIXELS, 4));
    for (int i = 0; i < 4; i++) word(in + 4 + i * 4, 0xff000000u + (uint32_t)i);
    word(in + 20, CTL(ABOVE, 12));
    memset(out, 0xee, sizeof out);
    CHECK(mnd_pixels_unpack(in, 24, out, 16, 4, 4));
    CHECK(out[12 * 4] == 0 && out[13 * 4] == 1 && out[15 * 4] == 3 && out[64] == 0xee);
    word(in, CTL(PIXELS, 5));
    CHECK(!mnd_pixels_unpack(in, 24, out, 16, 4, 4)); /* pixels it says, and does not bring */
    /* Sizes no picture has. */
    word(in, CTL(RUN, 16));
    CHECK(!mnd_pixels_unpack(in, 8, out, 16, 0, 4) && !mnd_pixels_unpack(in, 8, out, 16, 4, -1));
    CHECK(!mnd_pixels_unpack(in, 8, out, 12, 4, 4)); /* rows shorter than the pixels in them */
#undef CTL

    /* Anything at all: refused or taken, and never a byte outside. */
    enum { WIDE = 9, HIGH = 7, ROW = (WIDE + 2) * 4 };
    static uint8_t noise[400], picture[ROW * HIGH + 16];
    int taken = 0;
    for (int round = 0; round < 200000; round++) {
        size_t len = rnd() % sizeof noise;
        for (size_t i = 0; i < len; i++) noise[i] = (uint8_t)rnd();
        /* Often a count that fits, so that more than the first word is read. */
        for (size_t i = 0; i + 4 <= len && rnd() % 4; i += 4 + (rnd() % 3) * 4) word(noise + i, (((rnd() % 70) << 2) | (rnd() % 3)));
        memset(picture, 0xee, sizeof picture);
        uint8_t *exact = malloc(len ? len : 1);
        CHECK(exact);
        memcpy(exact, noise, len);
        if (mnd_pixels_unpack(exact, len, picture, ROW, WIDE, HIGH)) taken++;
        free(exact);
        for (int y = 0; y < HIGH; y++)
            for (int k = WIDE * 4; k < ROW; k++) CHECK(picture[y * ROW + k] == 0xee);
        for (int k = 0; k < 16; k++) CHECK(picture[ROW * HIGH + k] == 0xee);
    }
    CHECK(taken > 0); /* some of it was a picture: the reading went all the way */
}

int main(void) {
    test_flat_parts_and_repeated_rows_are_small();
    test_any_pixels_come_back();
    test_what_is_no_picture_is_refused();
    printf("test_wm_pack: %d checks passed\n", checks);
    return 0;
}
