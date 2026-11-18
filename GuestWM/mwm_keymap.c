/*
 * mwm_keymap.c — see mwm_keymap.h.
 *
 * Keys are named by their number (<K30>: the kernel's code 30, which X and
 * XKB count 8 higher) and symbols are written as numbers, so the text
 * needs nothing of the VM's own keyboard files to be read.
 */
#include "mwm_keymap.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char *text;
    size_t len, cap;
    bool full;
} out;

static void put(out *o, const char *format, ...) {
    if (o->full) return;
    va_list ap;
    va_start(ap, format);
    int n = vsnprintf(o->text + o->len, o->cap - o->len, format, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= o->cap - o->len) o->full = true;
    else o->len += (size_t)n;
}

/* How many of a key's four levels say something. */
static int levels(const mwm_key *k) {
    int n = 0;
    for (int i = 0; i < 4; i++)
        if (k->symbols[i] != 0) n = i + 1;
    return n;
}

/* The modifier a key is, by what it types; NULL when it is none. */
static const char *modifier(uint32_t symbol) {
    switch (symbol) {
    case 0xffe1: case 0xffe2: return "Shift";
    case 0xffe5: return "Lock";
    case 0xffe3: case 0xffe4: return "Control";
    case 0xffe7: case 0xffe8: case 0xffe9: case 0xffea: return "Mod1"; /* Meta and Alt */
    case 0xff7f: return "Mod2";                                       /* Num Lock */
    case 0xffeb: case 0xffec: return "Mod4";                          /* Super */
    case 0xfe03: return "Mod5";                                       /* the third level */
    default: return NULL;
    }
}

char *mwm_keymap_text(const mwm_key *keys, int count, size_t *size) {
    if (!keys || count <= 0 || count > MWM_MAX_KEYS) return NULL;
    bool seen[MWM_MAX_KEYCODE + 1] = {false};
    for (int i = 0; i < count; i++) {
        if (keys[i].code == 0 || keys[i].code > MWM_MAX_KEYCODE || seen[keys[i].code] || keys[i].symbols[0] == 0) return NULL;
        seen[keys[i].code] = true;
    }
    out o = {.cap = 4096 + (size_t)count * 256};
    o.text = malloc(o.cap);
    if (!o.text) return NULL;

    put(&o, "xkb_keymap {\nxkb_keycodes \"monad\" {\nminimum = 8;\nmaximum = 255;\n");
    for (int i = 0; i < count; i++) put(&o, "<K%u> = %u;\n", keys[i].code, keys[i].code + 8);
    put(&o, "};\n"
            "xkb_types \"monad\" {\n"
            "type \"ONE_LEVEL\" { modifiers = None; map[None] = Level1; level_name[Level1] = \"Any\"; };\n"
            "type \"TWO_LEVEL\" { modifiers = Shift; map[Shift] = Level2;"
            " level_name[Level1] = \"Base\"; level_name[Level2] = \"Shift\"; };\n"
            /* Caps Lock as the Mac has it: Shift for the keys it applies to, with or without Shift. */
            "type \"ALPHABETIC\" { modifiers = Shift+Lock; map[Shift] = Level2; map[Lock] = Level2; map[Shift+Lock] = Level2;"
            " level_name[Level1] = \"Base\"; level_name[Level2] = \"Caps\"; };\n"
            "type \"FOUR_LEVEL\" { modifiers = Shift+Mod5; map[Shift] = Level2; map[Mod5] = Level3; map[Shift+Mod5] = Level4;"
            " level_name[Level1] = \"Base\"; level_name[Level2] = \"Shift\"; level_name[Level3] = \"Third\";"
            " level_name[Level4] = \"Shift Third\"; };\n"
            "type \"FOUR_LEVEL_ALPHABETIC\" { modifiers = Shift+Lock+Mod5; map[Shift] = Level2; map[Lock] = Level2;"
            " map[Shift+Lock] = Level2; map[Mod5] = Level3; map[Shift+Mod5] = Level4; map[Lock+Mod5] = Level4;"
            " map[Shift+Lock+Mod5] = Level4; level_name[Level1] = \"Base\"; level_name[Level2] = \"Shift\";"
            " level_name[Level3] = \"Third\"; level_name[Level4] = \"Shift Third\"; };\n"
            "};\n"
            "xkb_compatibility \"monad\" {\n"
            "interpret Caps_Lock+AnyOfOrNone(all) { action = LockMods(modifiers=Lock); };\n"
            "interpret Any+AnyOf(all) { action = SetMods(modifiers=modMapMods,clearLocks); };\n"
            "};\n"
            "xkb_symbols \"monad\" {\n");
    for (int i = 0; i < count; i++) {
        const mwm_key *k = &keys[i];
        int n = levels(k);
        const char *type = n == 1 ? "ONE_LEVEL" : n == 2 ? (k->caps ? "ALPHABETIC" : "TWO_LEVEL")
                                                         : (k->caps ? "FOUR_LEVEL_ALPHABETIC" : "FOUR_LEVEL");
        if (n == 3) n = 4;
        put(&o, "key <K%u> { type = \"%s\", [ ", k->code, type);
        for (int level = 0; level < n; level++) {
            if (level > 0) put(&o, ", ");
            if (k->symbols[level] != 0) put(&o, "0x%x", k->symbols[level]);
            else put(&o, "NoSymbol");
        }
        put(&o, " ] };\n");
    }
    for (int i = 0; i < count; i++) {
        const char *mod = modifier(keys[i].symbols[0]);
        if (mod) put(&o, "modifier_map %s { <K%u> };\n", mod, keys[i].code);
    }
    put(&o, "};\n};\n");
    if (o.full) {
        free(o.text);
        return NULL;
    }
    *size = o.len + 1;
    return o.text;
}

/* Letters: what the key types, and with Shift or Caps Lock its capital. */
#define LETTER(code, c) {(code), {(c), (c) - 32, 0, 0}, true}
#define PAIR(code, plain, shifted) {(code), {(plain), (shifted), 0, 0}, false}
#define ONE(code, symbol) {(code), {(symbol), 0, 0, 0}, false}

static const mwm_key us[] = {
    ONE(1, 0xff1b), /* Escape */
    PAIR(2, '1', '!'), PAIR(3, '2', '@'), PAIR(4, '3', '#'), PAIR(5, '4', '$'), PAIR(6, '5', '%'),
    PAIR(7, '6', '^'), PAIR(8, '7', '&'), PAIR(9, '8', '*'), PAIR(10, '9', '('), PAIR(11, '0', ')'),
    PAIR(12, '-', '_'), PAIR(13, '=', '+'),
    ONE(14, 0xff08), /* BackSpace */
    PAIR(15, 0xff09, 0xfe20), /* Tab, and back with Shift */
    LETTER(16, 'q'), LETTER(17, 'w'), LETTER(18, 'e'), LETTER(19, 'r'), LETTER(20, 't'), LETTER(21, 'y'),
    LETTER(22, 'u'), LETTER(23, 'i'), LETTER(24, 'o'), LETTER(25, 'p'),
    PAIR(26, '[', '{'), PAIR(27, ']', '}'),
    ONE(28, 0xff0d), /* Return */
    ONE(29, 0xffe3), /* Control_L */
    LETTER(30, 'a'), LETTER(31, 's'), LETTER(32, 'd'), LETTER(33, 'f'), LETTER(34, 'g'), LETTER(35, 'h'),
    LETTER(36, 'j'), LETTER(37, 'k'), LETTER(38, 'l'),
    PAIR(39, ';', ':'), PAIR(40, '\'', '"'), PAIR(41, '`', '~'),
    ONE(42, 0xffe1), /* Shift_L */
    PAIR(43, '\\', '|'),
    LETTER(44, 'z'), LETTER(45, 'x'), LETTER(46, 'c'), LETTER(47, 'v'), LETTER(48, 'b'), LETTER(49, 'n'),
    LETTER(50, 'm'),
    PAIR(51, ',', '<'), PAIR(52, '.', '>'), PAIR(53, '/', '?'),
    ONE(54, 0xffe2), /* Shift_R */
    ONE(55, 0xffaa), /* KP_Multiply */
    ONE(56, 0xffe9), /* Alt_L */
    ONE(57, ' '),
    ONE(58, 0xffe5), /* Caps_Lock */
    ONE(59, 0xffbe), ONE(60, 0xffbf), ONE(61, 0xffc0), ONE(62, 0xffc1), ONE(63, 0xffc2), /* F1 to F5 */
    ONE(64, 0xffc3), ONE(65, 0xffc4), ONE(66, 0xffc5), ONE(67, 0xffc6), ONE(68, 0xffc7), /* F6 to F10 */
    /* The keypad types its digits: a Mac has no Num Lock. */
    ONE(71, 0xffb7), ONE(72, 0xffb8), ONE(73, 0xffb9), ONE(74, 0xffad), ONE(75, 0xffb4), ONE(76, 0xffb5),
    ONE(77, 0xffb6), ONE(78, 0xffab), ONE(79, 0xffb1), ONE(80, 0xffb2), ONE(81, 0xffb3), ONE(82, 0xffb0),
    ONE(83, 0xffae),
    PAIR(86, 0xa7, 0xb1), /* the key beside the left Shift on ISO keyboards */
    ONE(87, 0xffc8), ONE(88, 0xffc9), /* F11, F12 */
    ONE(96, 0xff8d), /* KP_Enter */
    ONE(97, 0xffe4), /* Control_R */
    ONE(98, 0xffaf), /* KP_Divide */
    ONE(100, 0xfe03), /* the right Option key: the third level */
    ONE(102, 0xff50), ONE(103, 0xff52), ONE(104, 0xff55), ONE(105, 0xff51), /* Home, Up, Prior, Left */
    ONE(106, 0xff53), ONE(107, 0xff57), ONE(108, 0xff54), ONE(109, 0xff56), /* Right, End, Down, Next */
    ONE(110, 0xff63), ONE(111, 0xffff), /* Insert, Delete */
    ONE(117, 0xffbd), /* KP_Equal */
    ONE(125, 0xffeb), ONE(126, 0xffec), /* Super_L, Super_R */
    ONE(183, 0xffca), ONE(184, 0xffcb), ONE(185, 0xffcc), ONE(186, 0xffcd), /* F13 to F16 */
    ONE(187, 0xffce), ONE(188, 0xffcf), ONE(189, 0xffd0), ONE(190, 0xffd1), /* F17 to F20 */
};

const mwm_key *mwm_keymap_us(int *count) {
    *count = (int)(sizeof us / sizeof us[0]);
    return us;
}
