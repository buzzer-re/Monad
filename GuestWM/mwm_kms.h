/*
 * mwm_kms.h — the VM's display as Monad's window manager uses it: a block
 * of pixels of a chosen size, and a way to put a changed rectangle on the
 * display (mwm_kms.c, Linux only).
 */
#ifndef MWM_KMS_H
#define MWM_KMS_H

#include <stddef.h>
#include <stdint.h>

typedef struct mwm_kms mwm_kms;

/* Takes the display at `card` (/dev/dri/card0) and sets it to width × height
 * pixels, all black. NULL, with why in `err`, when it cannot. */
mwm_kms *mwm_kms_open(const char *card, int width, int height, char *err, size_t errlen);
void mwm_kms_close(mwm_kms *k);

/* XRGB, one word a pixel; `stride` words from a row to the next. */
uint32_t *mwm_kms_pixels(const mwm_kms *k);
int mwm_kms_stride(const mwm_kms *k);

/* The rectangle changed: it goes to the display (and so to the Mac). */
void mwm_kms_present(mwm_kms *k, int x, int y, int width, int height);

#endif
