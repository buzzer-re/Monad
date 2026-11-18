/*
 * mwm_pack.h — a window's pixels made small for the way to the Mac. What
 * a program draws is mostly flat (a ground, with text on it) and mostly
 * like the row above; sending it as it is costs the Mac more than
 * anything else here does (a large window drawn again 30 times a second
 * is 600 MB a second through the VM's socket). Packed, pixels are a list
 * of parts, each a word saying its kind (the low two bits) and how many
 * pixels it is (the rest, at least one), all words little-endian:
 *
 *   0  that many pixels of one colour: the colour follows, once
 *   1  that many pixels: they follow, as they are
 *   2  that many pixels as the ones a row above them (never in the first row)
 *
 * The pixels are counted row after row from the top left, as if the rows
 * were one line: a part goes on into the next row. The parts together are
 * exactly the picture, and nothing follows them. MonadHost unpacks it
 * (Monad/Backend/mnd_pixels.c) and reads all of it as hostile.
 */
#ifndef MWM_PACK_H
#define MWM_PACK_H

#include <stddef.h>
#include <stdint.h>

/* Packs width × height pixels (rows `stride` words apart) into `out`: how
 * many bytes it took. 0 when that would be more than `max`: the pixels
 * are then better sent as they are. */
size_t mwm_pack(const uint32_t *pixels, int stride, int width, int height, uint8_t *out, size_t max);

#endif
