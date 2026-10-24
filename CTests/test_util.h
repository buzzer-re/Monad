/* Minimal test harness for Monad's C backend. */
#ifndef TEST_UTIL_H
#define TEST_UTIL_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                              \
    do {                                                                         \
        g_checks++;                                                              \
        if (!(cond)) {                                                           \
            g_failures++;                                                        \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
        }                                                                        \
    } while (0)

#define CHECK_STR(a, b)                                                                     \
    do {                                                                                    \
        g_checks++;                                                                         \
        const char *a_ = (a), *b_ = (b);                                                    \
        if (!a_ || !b_ || strcmp(a_, b_) != 0) {                                            \
            g_failures++;                                                                   \
            fprintf(stderr, "%s:%d: expected \"%s\" got \"%s\"\n", __FILE__, __LINE__,       \
                    b_ ? b_ : "(null)", a_ ? a_ : "(null)");                                \
        }                                                                                   \
    } while (0)

#define CHECK_MEM(a, alen, b, blen)                                                        \
    do {                                                                                   \
        g_checks++;                                                                        \
        if ((alen) != (blen) || memcmp((a), (b), (blen)) != 0) {                          \
            g_failures++;                                                                  \
            fprintf(stderr, "%s:%d: byte mismatch (len %zu vs %zu)\n", __FILE__, __LINE__, \
                    (size_t)(alen), (size_t)(blen));                                       \
        }                                                                                  \
    } while (0)

#define RUN(fn)                           \
    do {                                  \
        fprintf(stderr, "  %s\n", #fn);   \
        fn();                             \
    } while (0)

#define TEST_MAIN_END()                                                        \
    do {                                                                       \
        fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);    \
        return g_failures ? 1 : 0;                                             \
    } while (0)

#endif
