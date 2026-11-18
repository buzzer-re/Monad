/*
 * mwm_keymap.h — the keyboard as programs are told it: an XKB keymap, as
 * text, written from a table of keys. The table says what each key types
 * (plain, with Shift, with the third-level key, with both), so the Mac's
 * own layout can be handed over as it is, with no layout of that name
 * needed in the VM.
 */
#ifndef MWM_KEYMAP_H
#define MWM_KEYMAP_H

#include "mwm_server.h"

#include <stddef.h>

/* The keymap for the table, NUL-terminated and the caller's to free; *size
 * counts the NUL. NULL when the table cannot be a keyboard: no keys or too
 * many, a key twice, one outside 1...MWM_MAX_KEYCODE, or one that types
 * nothing. */
char *mwm_keymap_text(const mwm_key *keys, int count, size_t *size);

/* A US keyboard, for when nobody has said what the keys are. */
const mwm_key *mwm_keymap_us(int *count);

#endif
