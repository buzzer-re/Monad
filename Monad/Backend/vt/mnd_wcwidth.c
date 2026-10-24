/*
 * mnd_wcwidth.c — terminal column width of Unicode code points.
 */
#include "mnd_vt.h"
#include "mnd_wcwidth_tables.h"

static bool in_table(uint32_t cp, const mnd_range *t, size_t n) {
    if (n == 0 || cp < t[0].lo || cp > t[n - 1].hi) return false;
    size_t lo = 0, hi = n - 1;
    while (lo <= hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (cp > t[mid].hi) lo = mid + 1;
        else if (cp < t[mid].lo) {
            if (mid == 0) return false;
            hi = mid - 1;
        } else return true;
    }
    return false;
}

int mnd_wcwidth(uint32_t cp) {
    if (cp >= 0x20 && cp < 0x7F) return 1;
    if (cp == 0) return 0;
    if (cp < 0x20 || (cp >= 0x7F && cp < 0xA0)) return -1;
    if (cp > 0x10FFFF) return -1;
    if (in_table(cp, mnd_zero_width, sizeof mnd_zero_width / sizeof mnd_zero_width[0])) return 0;
    if (in_table(cp, mnd_wide, sizeof mnd_wide / sizeof mnd_wide[0])) return 2;
    return 1;
}
