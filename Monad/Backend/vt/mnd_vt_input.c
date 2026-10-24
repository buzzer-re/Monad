/*
 * mnd_vt_input.c — keyboard, mouse, focus and paste encoding (xterm rules).
 */
#include "mnd_vt_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char *p;
    size_t len, cap;
} out_t;

static void put(out_t *o, const char *s, size_t n) {
    if (o->len + n > o->cap) {
        o->len = o->cap + 1; /* mark overflow */
        return;
    }
    memcpy(o->p + o->len, s, n);
    o->len += n;
}

static void puts_(out_t *o, const char *s) { put(o, s, strlen(s)); }

static void putf(out_t *o, const char *fmt, int a, int b, int c) {
    char tmp[48];
    int n = snprintf(tmp, sizeof tmp, fmt, a, b, c);
    if (n > 0 && (size_t)n < sizeof tmp) put(o, tmp, (size_t)n);
}

static size_t finish(out_t *o) { return o->len > o->cap ? 0 : o->len; }

static size_t utf8_put(out_t *o, uint32_t cp) {
    char b[4];
    size_t n;
    if (cp < 0x80) {
        b[0] = (char)cp;
        n = 1;
    } else if (cp < 0x800) {
        b[0] = (char)(0xC0 | (cp >> 6));
        b[1] = (char)(0x80 | (cp & 0x3F));
        n = 2;
    } else if (cp < 0x10000) {
        b[0] = (char)(0xE0 | (cp >> 12));
        b[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        b[2] = (char)(0x80 | (cp & 0x3F));
        n = 3;
    } else {
        b[0] = (char)(0xF0 | (cp >> 18));
        b[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        b[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
        b[3] = (char)(0x80 | (cp & 0x3F));
        n = 4;
    }
    put(o, b, n);
    return n;
}

static int mod_param(unsigned mods) {
    return 1 + ((mods & MND_MOD_SHIFT) ? 1 : 0) + ((mods & MND_MOD_ALT) ? 2 : 0) + ((mods & MND_MOD_CTRL) ? 4 : 0) +
           ((mods & MND_MOD_META) ? 8 : 0);
}

/* ---- Keys -------------------------------------------------------------------- */

static void cursor_key(mnd_vt *vt, out_t *o, char letter, unsigned mods) {
    if (mods) putf(o, "\x1b[1;%d%c", mod_param(mods), letter, 0);
    else if (vt->app_cursor) putf(o, "\x1bO%c", letter, 0, 0);
    else putf(o, "\x1b[%c", letter, 0, 0);
}

static void tilde_key(out_t *o, int code, unsigned mods) {
    if (mods) putf(o, "\x1b[%d;%d~", code, mod_param(mods), 0);
    else putf(o, "\x1b[%d~", code, 0, 0);
}

static void ss3_fkey(out_t *o, char letter, unsigned mods) {
    if (mods) putf(o, "\x1b[1;%d%c", mod_param(mods), letter, 0);
    else putf(o, "\x1bO%c", letter, 0, 0);
}

size_t mnd_vt_encode_key(mnd_vt *vt, mnd_key key, unsigned mods, char *outp, size_t cap) {
    out_t o = {outp, 0, cap};
    mnd_vt_lock(vt);
    mods &= (MND_MOD_SHIFT | MND_MOD_ALT | MND_MOD_CTRL | MND_MOD_META);
    static const int fcodes[] = {15, 17, 18, 19, 20, 21, 23, 24, 25, 26, 28, 29, 31, 32, 33, 34};

    switch (key) {
    case MND_KEY_UP: cursor_key(vt, &o, 'A', mods); break;
    case MND_KEY_DOWN: cursor_key(vt, &o, 'B', mods); break;
    case MND_KEY_RIGHT: cursor_key(vt, &o, 'C', mods); break;
    case MND_KEY_LEFT: cursor_key(vt, &o, 'D', mods); break;
    case MND_KEY_HOME: cursor_key(vt, &o, 'H', mods); break;
    case MND_KEY_END: cursor_key(vt, &o, 'F', mods); break;
    case MND_KEY_INSERT: tilde_key(&o, 2, mods); break;
    case MND_KEY_DELETE: tilde_key(&o, 3, mods); break;
    case MND_KEY_PAGE_UP: tilde_key(&o, 5, mods); break;
    case MND_KEY_PAGE_DOWN: tilde_key(&o, 6, mods); break;
    case MND_KEY_F1: ss3_fkey(&o, 'P', mods); break;
    case MND_KEY_F2: ss3_fkey(&o, 'Q', mods); break;
    case MND_KEY_F3: ss3_fkey(&o, 'R', mods); break;
    case MND_KEY_F4: ss3_fkey(&o, 'S', mods); break;
    case MND_KEY_BACKSPACE:
        if (mods & MND_MOD_ALT) puts_(&o, "\x1b");
        puts_(&o, (mods & MND_MOD_CTRL) ? "\x08" : "\x7f");
        break;
    case MND_KEY_TAB:
        if ((mods & MND_MOD_SHIFT) && !(mods & (MND_MOD_CTRL | MND_MOD_ALT))) {
            puts_(&o, "\x1b[Z");
        } else if (vt->modify_other_keys >= 2 && (mods & ~MND_MOD_ALT)) {
            putf(&o, "\x1b[27;%d;%d~", mod_param(mods), 9, 0);
        } else {
            if (mods & MND_MOD_ALT) puts_(&o, "\x1b");
            puts_(&o, "\t");
        }
        break;
    case MND_KEY_ENTER:
    case MND_KEY_KP_ENTER:
        if (key == MND_KEY_KP_ENTER && vt->app_keypad && !mods) {
            puts_(&o, "\x1bOM");
        } else if (vt->modify_other_keys >= 2 && (mods & ~MND_MOD_ALT)) {
            putf(&o, "\x1b[27;%d;%d~", mod_param(mods), 13, 0);
        } else {
            if (mods & MND_MOD_ALT) puts_(&o, "\x1b");
            puts_(&o, vt->lnm ? "\r\n" : "\r");
        }
        break;
    case MND_KEY_ESCAPE:
        if (mods & MND_MOD_ALT) puts_(&o, "\x1b");
        puts_(&o, "\x1b");
        break;
    default:
        if (key >= MND_KEY_F5 && key <= MND_KEY_F20) {
            tilde_key(&o, fcodes[key - MND_KEY_F5], mods);
        } else if (key >= MND_KEY_KP_0 && key <= MND_KEY_KP_EQUAL) {
            static const char app[] = "pqrstuvwxynojmkMX"; /* 0-9 . / * - + enter = */
            static const char num[] = "0123456789./*-+\r=";
            int i = (int)(key - MND_KEY_KP_0);
            if (key == MND_KEY_KP_EQUAL) i = 16;
            if (vt->app_keypad && !mods) {
                putf(&o, "\x1bO%c", app[i], 0, 0);
            } else {
                if (mods & MND_MOD_ALT) puts_(&o, "\x1b");
                put(&o, &num[i], 1);
            }
        }
        break;
    }
    mnd_vt_unlock(vt);
    return finish(&o);
}

/* Legacy control code for Ctrl+cp, or -1. */
static int ctrl_code(uint32_t cp) {
    if (cp >= 'a' && cp <= 'z') return (int)(cp - 'a' + 1);
    if (cp >= 'A' && cp <= 'Z') return (int)(cp - 'A' + 1);
    switch (cp) {
    case '@': case ' ': case '2': return 0;
    case '[': case '3': return 0x1b;
    case '\\': case '4': return 0x1c;
    case ']': case '5': return 0x1d;
    case '^': case '6': case '~': return 0x1e;
    case '_': case '7': case '/': case '-': return 0x1f;
    case '8': case '?': return 0x7f;
    default: return -1;
    }
}

size_t mnd_vt_encode_char(mnd_vt *vt, uint32_t cp, unsigned mods, char *outp, size_t cap) {
    out_t o = {outp, 0, cap};
    if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return 0;
    mnd_vt_lock(vt);
    int mok = vt->modify_other_keys;
    mnd_vt_unlock(vt);

    bool ctrl = mods & MND_MOD_CTRL, alt = mods & MND_MOD_ALT;
    if (ctrl) {
        int code = ctrl_code(cp);
        if (mok >= 2 || (code < 0 && mok == 1)) {
            putf(&o, "\x1b[27;%d;%d~", mod_param(mods & ~MND_MOD_SHIFT), (int)cp, 0);
            return finish(&o);
        }
        if (code >= 0) {
            if (alt) puts_(&o, "\x1b");
            char c = (char)code;
            put(&o, &c, 1);
            return finish(&o);
        }
    }
    if (alt) {
        if (mok >= 2) {
            putf(&o, "\x1b[27;%d;%d~", mod_param(mods & ~MND_MOD_SHIFT), (int)cp, 0);
            return finish(&o);
        }
        puts_(&o, "\x1b");
    }
    utf8_put(&o, cp);
    return finish(&o);
}

/* ---- Mouse ----------------------------------------------------------------------- */

size_t mnd_vt_encode_mouse(mnd_vt *vt, int button, mnd_mouse_action action, unsigned mods, int col, int row,
                           char *outp, size_t cap) {
    out_t o = {outp, 0, cap};
    mnd_vt_lock(vt);
    mnd_mouse_tracking mode = vt->mouse;
    mnd_mouse_encoding enc = vt->mouse_enc;
    mnd_vt_unlock(vt);

    if (mode == MND_MOUSE_OFF || col < 0 || row < 0) return 0;
    bool wheel = button >= 4 && button <= 7;
    if (action == MND_MOUSE_MOTION) {
        if (mode == MND_MOUSE_ANY) {
            /* all motion reported */
        } else if (mode == MND_MOUSE_BUTTON) {
            if (button == 3) return 0;
        } else {
            return 0;
        }
    }
    if (mode == MND_MOUSE_X10 && action != MND_MOUSE_PRESS) return 0;
    if (wheel && action == MND_MOUSE_RELEASE) return 0;

    int cb;
    if (wheel) cb = 64 + (button - 4);
    else if (button >= 0 && button <= 2) cb = button;
    else cb = 3;
    if (action == MND_MOUSE_RELEASE && enc != MOUSE_ENC_SGR) cb = 3;
    if (action == MND_MOUSE_MOTION) cb += 32;
    if (mode != MND_MOUSE_X10) {
        if (mods & MND_MOD_SHIFT) cb += 4;
        if (mods & (MND_MOD_ALT | MND_MOD_META)) cb += 8;
        if (mods & MND_MOD_CTRL) cb += 16;
    }
    int x = col + 1, y = row + 1;

    switch (enc) {
    case MOUSE_ENC_SGR:
        putf(&o, "\x1b[<%d;%d;%d", cb, x, y);
        puts_(&o, action == MND_MOUSE_RELEASE ? "m" : "M");
        break;
    case MOUSE_ENC_URXVT:
        putf(&o, "\x1b[%d;%d;%dM", cb + 32, x, y);
        break;
    case MOUSE_ENC_UTF8:
        if (x > 2015 || y > 2015) return 0;
        puts_(&o, "\x1b[M");
        utf8_put(&o, (uint32_t)(cb + 32));
        utf8_put(&o, (uint32_t)(x + 32));
        utf8_put(&o, (uint32_t)(y + 32));
        break;
    case MOUSE_ENC_DEFAULT:
    default: {
        if (x + 32 > 255 || y + 32 > 255) return 0;
        char b[6] = {'\x1b', '[', 'M', (char)(cb + 32), (char)(x + 32), (char)(y + 32)};
        put(&o, b, 6);
        break;
    }
    }
    return finish(&o);
}

size_t mnd_vt_encode_focus(mnd_vt *vt, bool focused, char *outp, size_t cap) {
    mnd_vt_lock(vt);
    bool on = vt->focus_events;
    mnd_vt_unlock(vt);
    if (!on || cap < 3) return 0;
    memcpy(outp, focused ? "\x1b[I" : "\x1b[O", 3);
    return 3;
}

/* ---- Paste ------------------------------------------------------------------------ */

char *mnd_vt_encode_paste(mnd_vt *vt, const char *text, size_t len, size_t *out_len) {
    mnd_vt_lock(vt);
    bool bracketed = vt->bracketed_paste;
    mnd_vt_unlock(vt);

    size_t cap = len + 13;
    char *out = malloc(cap);
    if (!out) return NULL;
    size_t n = 0;
    if (bracketed) {
        memcpy(out, "\x1b[200~", 6);
        n = 6;
    }
    const unsigned char *s = (const unsigned char *)text;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = s[i];
        if (c == '\r') {
            if (i + 1 < len && s[i + 1] == '\n') i++;
            out[n++] = '\r';
        } else if (c == '\n') {
            out[n++] = '\r';
        } else if (c == '\t' || (c >= 0x20 && c != 0x7F)) {
            /* Drop C1 controls encoded as UTF-8 (U+0080..U+009F = C2 80..C2 9F). */
            if (c == 0xC2 && i + 1 < len && s[i + 1] >= 0x80 && s[i + 1] <= 0x9F) {
                i++;
                continue;
            }
            out[n++] = (char)c;
        }
        /* all other C0 controls, including ESC, are removed */
    }
    if (bracketed) {
        memcpy(out + n, "\x1b[201~", 6);
        n += 6;
    }
    out[n] = '\0';
    *out_len = n;
    return out;
}
