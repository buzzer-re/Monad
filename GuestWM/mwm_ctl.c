/*
 * mwm_ctl.c — see mwm_ctl.h.
 */
#include "mwm_ctl.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

struct mwm_ctl {
    mwm_server *server;
    int fd;
    char in[MWM_CTL_LINE];
    size_t in_len;
    char *out;
    size_t out_len, out_cap;
    /* The windows as MonadHost was last told them. */
    uint32_t told;
    bool told_any;
    /* A table of keys being read: how many are still to come. */
    mwm_key keys[MWM_MAX_KEYS];
    int key_count, keys_expected;
};

mwm_ctl *mwm_ctl_new(mwm_server *server) {
    mwm_ctl *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->server = server;
    c->fd = -1;
    return c;
}

static void drop(mwm_ctl *c) {
    if (c->fd >= 0) close(c->fd);
    c->fd = -1;
    c->in_len = 0;
    c->out_len = 0;
    c->keys_expected = 0;
}

void mwm_ctl_free(mwm_ctl *c) {
    if (!c) return;
    drop(c);
    free(c->out);
    free(c);
}

int mwm_ctl_fd(const mwm_ctl *c) { return c->fd; }
bool mwm_ctl_wants_write(const mwm_ctl *c) { return c->fd >= 0 && c->out_len > 0; }

/* ------------------------------------------------------------------------ */
/* To MonadHost                                                              */

static void say(mwm_ctl *c, const char *format, ...) {
    if (c->fd < 0) return;
    char line[MWM_CTL_LINE];
    va_list ap;
    va_start(ap, format);
    int n = vsnprintf(line, sizeof line, format, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= sizeof line || c->out_len + (size_t)n > MWM_CTL_OUT) {
        drop(c); /* a line that cannot be said, or a MonadHost that does not read */
        return;
    }
    if (c->out_len + (size_t)n > c->out_cap) {
        size_t cap = c->out_cap ? c->out_cap : 4096;
        while (cap < c->out_len + (size_t)n) cap *= 2;
        char *grown = realloc(c->out, cap);
        if (!grown) {
            drop(c);
            return;
        }
        c->out = grown;
        c->out_cap = cap;
    }
    memcpy(c->out + c->out_len, line, (size_t)n);
    c->out_len += (size_t)n;
}

static void flush(mwm_ctl *c) {
    while (c->fd >= 0 && c->out_len > 0) {
        ssize_t n = send(c->fd, c->out, c->out_len, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        if (n <= 0) {
            drop(c);
            return;
        }
        memmove(c->out, c->out + n, c->out_len - (size_t)n);
        c->out_len -= (size_t)n;
    }
}

/* A program's text as one word: every byte but plain printable ASCII as
 * %XX, "-" for none. `dst` holds three bytes for each of `src`, and one. */
static void word(char *dst, const char *src) {
    static const char hex[] = "0123456789ABCDEF";
    if (!src[0]) {
        strcpy(dst, "-");
        return;
    }
    bool dash = strcmp(src, "-") == 0; /* said plainly it would read as no text */
    for (const unsigned char *p = (const unsigned char *)src; *p; p++) {
        if (*p > 0x20 && *p < 0x7f && *p != '%' && !dash) {
            *dst++ = (char)*p;
        } else {
            *dst++ = '%';
            *dst++ = hex[*p >> 4];
            *dst++ = hex[*p & 15];
        }
    }
    *dst = 0;
}

/* The whole list, when it changed and MonadHost has read what was said
 * before: a MonadHost that is slow hears the newest list, not every one. */
static void tell_windows(mwm_ctl *c) {
    uint32_t generation = mwm_server_generation(c->server);
    if (c->fd < 0 || c->out_len > 0 || (c->told_any && c->told == generation)) return;
    mwm_window list[MWM_MAX_WINDOWS];
    int n = mwm_server_windows(c->server, list, MWM_MAX_WINDOWS);
    say(c, "windows %u %d\n", generation, n);
    for (int i = 0; i < n; i++) {
        char app[3 * 128 + 1], title[3 * 128 + 1];
        if (strlen(list[i].app_id) > 127 || strlen(list[i].title) > 127) continue; /* never: the server cuts them */
        word(app, list[i].app_id);
        word(title, list[i].title);
        say(c, "window %u %d %d %d %d %d %d %d %d %d %u %d %d %s %s\n", list[i].id, list[i].x, list[i].y, list[i].width, list[i].height,
            list[i].scale, list[i].inner_x, list[i].inner_y, list[i].inner_width, list[i].inner_height, list[i].parent,
            list[i].offset_x, list[i].offset_y, app, title);
    }
    say(c, "end\n");
    c->told = generation;
    c->told_any = true;
}

void mwm_ctl_update(mwm_ctl *c) {
    tell_windows(c);
    flush(c);
}

void mwm_ctl_attach(mwm_ctl *c, int fd) {
    drop(c);
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(fd);
        return;
    }
#ifdef SO_NOSIGPIPE
    int on = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
#endif
    c->fd = fd;
    c->told_any = false;
    int width, height;
    mwm_server_size(c->server, &width, &height);
    say(c, "monad-wm %d %d %d\n", MWM_CTL_VERSION, width, height);
    flush(c);
    mwm_ctl_update(c);
}

/* ------------------------------------------------------------------------ */
/* From MonadHost                                                            */

/* The line's numbers after its first word: exactly `count` of them, plain
 * decimal, each within 32 bits; false otherwise. */
static bool numbers(char *rest, int count, int64_t *out) {
    for (int i = 0; i < count; i++) {
        if (*rest != ' ') return false;
        rest++;
        bool negative = *rest == '-';
        if (negative) rest++;
        if (*rest < '0' || *rest > '9') return false;
        int64_t v = 0;
        while (*rest >= '0' && *rest <= '9') {
            v = v * 10 + (*rest++ - '0');
            if (v > UINT32_MAX) return false;
        }
        out[i] = negative ? -v : v;
    }
    return *rest == 0;
}

static bool is_uint(int64_t v) { return v >= 0 && v <= UINT32_MAX; }
static bool is_int(int64_t v) { return v >= INT32_MIN && v <= INT32_MAX; }
static bool is_flag(int64_t v) { return v == 0 || v == 1; }

static void command(mwm_ctl *c, char *text, uint32_t time_ms) {
    mwm_server *s = c->server;
    int64_t n[6];
    char *rest = strchr(text, ' ');
    size_t name = rest ? (size_t)(rest - text) : strlen(text);
    if (!rest) rest = text + name;
#define IS(word) (name == sizeof(word) - 1 && memcmp(text, word, name) == 0)
    if (c->keys_expected > 0) {
        /* Inside a table only its keys may come: anything else ends it, unused. */
        if (IS("k") && numbers(rest, 6, n) && is_uint(n[0]) && is_flag(n[1]) && is_uint(n[2]) && is_uint(n[3]) && is_uint(n[4])
            && is_uint(n[5])) {
            c->keys[c->key_count++] = (mwm_key){.code = (uint32_t)n[0], .caps = n[1] == 1,
                                                .symbols = {(uint32_t)n[2], (uint32_t)n[3], (uint32_t)n[4], (uint32_t)n[5]}};
            if (--c->keys_expected == 0) (void)mwm_server_keymap(s, c->keys, c->key_count);
            return;
        }
        c->keys_expected = 0;
    }
    if (IS("pointer")) {
        if (numbers(rest, 3, n) && is_uint(n[0]) && is_int(n[1]) && is_int(n[2])) {
            mwm_server_pointer(s, (uint32_t)n[0], (int32_t)n[1], (int32_t)n[2], time_ms);
        }
    } else if (IS("button")) {
        if (numbers(rest, 2, n) && is_uint(n[0]) && is_flag(n[1])) mwm_server_button(s, (uint32_t)n[0], n[1] == 1, time_ms);
    } else if (IS("scale")) {
        if (numbers(rest, 1, n) && is_int(n[0])) mwm_server_scale(s, (int)n[0]);
    } else if (IS("scroll")) {
        if (numbers(rest, 2, n) && is_int(n[0]) && is_int(n[1])) mwm_server_scroll(s, (int32_t)n[0], (int32_t)n[1], time_ms);
    } else if (IS("focus")) {
        if (numbers(rest, 1, n) && is_uint(n[0])) mwm_server_focus(s, (uint32_t)n[0]);
    } else if (IS("key")) {
        if (numbers(rest, 2, n) && is_uint(n[0]) && is_flag(n[1])) mwm_server_key(s, (uint32_t)n[0], n[1] == 1, time_ms);
    } else if (IS("mods")) {
        if (numbers(rest, 2, n) && is_uint(n[0]) && is_uint(n[1])) mwm_server_modifiers(s, (uint32_t)n[0], (uint32_t)n[1]);
    } else if (IS("keys")) {
        if (numbers(rest, 1, n) && n[0] >= 1 && n[0] <= MWM_MAX_KEYS) {
            c->keys_expected = (int)n[0];
            c->key_count = 0;
        }
    } else if (IS("size")) {
        if (numbers(rest, 3, n) && is_uint(n[0]) && is_int(n[1]) && is_int(n[2])) {
            mwm_server_resize(s, (uint32_t)n[0], (int32_t)n[1], (int32_t)n[2]);
        }
    } else if (IS("close")) {
        if (numbers(rest, 1, n) && is_uint(n[0])) mwm_server_close(s, (uint32_t)n[0]);
    } else if (IS("dismiss")) {
        if (numbers(rest, 1, n) && is_uint(n[0])) mwm_server_dismiss(s, (uint32_t)n[0]);
    }
#undef IS
}

void mwm_ctl_service(mwm_ctl *c, bool readable, bool writable, uint32_t time_ms) {
    (void)writable; /* what waits is sent below */
    while (readable && c->fd >= 0) {
        ssize_t got = recv(c->fd, c->in + c->in_len, sizeof c->in - c->in_len, 0);
        if (got < 0 && errno == EINTR) continue;
        if (got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        if (got <= 0) {
            drop(c); /* MonadHost left */
            break;
        }
        c->in_len += (size_t)got;
        char *start = c->in, *end = c->in + c->in_len, *newline;
        while ((newline = memchr(start, '\n', (size_t)(end - start))) != NULL) {
            *newline = 0; /* a line with a NUL inside reads as its beginning, which is no command */
            command(c, start, time_ms);
            start = newline + 1;
        }
        c->in_len = (size_t)(end - start);
        memmove(c->in, start, c->in_len);
        if (c->in_len == sizeof c->in) drop(c); /* a line that never ends */
    }
    mwm_ctl_update(c);
}
