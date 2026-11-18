/*
 * mnd_pixels.h — the pixels of a Linux program's window as the VM's
 * window manager packs them for the way to the Mac (GuestWM/mwm_pack.h
 * says how), made whole again. A guest sends them: what does not make
 * exactly the picture it is said to be is refused, and no byte is ever
 * written outside that picture.
 */
#ifndef MND_PIXELS_H
#define MND_PIXELS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Unpacks `len` bytes into a picture of width × height pixels at `out`,
 * its rows `stride` bytes apart (at least width × 4). True when they were
 * exactly that picture. False otherwise: some of the picture may have been
 * written by then, and nothing else. */
bool mnd_pixels_unpack(const uint8_t *in, size_t len, uint8_t *out, size_t stride, int width, int height);

#endif
