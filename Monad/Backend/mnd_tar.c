/*
 * mnd_tar.c — single-member tar extraction. See mnd_tar.h.
 *
 * Every member, sparse or not, is reduced to a list of data runs
 * (offset, length) over a file of `realsize` bytes; the runs' data follows in
 * the archive in order. A plain member is one run covering the whole file.
 */
#include "mnd_tar.h"

#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum {
    BLOCK = 512,
    MAX_LONGNAME = 64 * 1024,
    MAX_PAX = 1024 * 1024,
    MAX_RUNS = 1 << 22,
    ZERO_WINDOW = 4096,
};

static _Thread_local char g_err[256];

static int set_err(int code, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_err, sizeof g_err, fmt, ap);
    va_end(ap);
    return code;
}

const char *mnd_tar_last_error(void) { return g_err; }

ssize_t mnd_tar_fd_reader(void *ctx, void *buf, size_t n) {
    int fd = *(int *)ctx;
    ssize_t r;
    do r = read(fd, buf, n);
    while (r < 0 && errno == EINTR);
    return r;
}

/* ------------------------------------------------------------------------ */
/* Buffered source                                                           */

typedef struct {
    mnd_tar_read_fn read;
    void *ctx;
    uint8_t buf[1 << 16];
    size_t pos, len;
    bool eof;
} source;

static int src_fill(source *s) {
    if (s->pos < s->len || s->eof) return 0;
    ssize_t r = s->read(s->ctx, s->buf, sizeof s->buf);
    if (r < 0) return set_err(EIO, "reading the archive failed");
    s->pos = 0;
    s->len = (size_t)r;
    if (r == 0) s->eof = true;
    return 0;
}

/* Up to `max` contiguous buffered bytes; *avail 0 means end of input. */
static int src_peek(source *s, size_t max, const uint8_t **p, size_t *avail) {
    int e = src_fill(s);
    if (e) return e;
    size_t n = s->len - s->pos;
    *p = s->buf + s->pos;
    *avail = n < max ? n : max;
    return 0;
}

static int src_read(source *s, void *out, size_t n) {
    uint8_t *o = out;
    while (n > 0) {
        const uint8_t *p;
        size_t got;
        int e = src_peek(s, n, &p, &got);
        if (e) return e;
        if (got == 0) return set_err(EINVAL, "unexpected end of archive");
        memcpy(o, p, got);
        s->pos += got;
        o += got;
        n -= got;
    }
    return 0;
}

static int src_skip(source *s, uint64_t n) {
    while (n > 0) {
        const uint8_t *p;
        size_t got;
        int e = src_peek(s, n > SIZE_MAX ? SIZE_MAX : (size_t)n, &p, &got);
        if (e) return e;
        if (got == 0) return set_err(EINVAL, "unexpected end of archive");
        s->pos += got;
        n -= got;
    }
    return 0;
}

static uint64_t padded(uint64_t n) { return (n + BLOCK - 1) / BLOCK * BLOCK; }

/* ------------------------------------------------------------------------ */
/* Header fields                                                             */

static bool parse_number(const uint8_t *f, size_t width, uint64_t *out) {
    uint64_t v = 0;
    if (f[0] & 0x80) { /* base-256 (GNU), big-endian; negative values rejected */
        if (f[0] == 0xFF) return false;
        v = f[0] & 0x7F;
        for (size_t i = 1; i < width; i++) {
            if (v > (UINT64_MAX >> 8)) return false;
            v = (v << 8) | f[i];
        }
        *out = v;
        return true;
    }
    size_t i = 0;
    while (i < width && f[i] == ' ') i++;
    for (; i < width && f[i] >= '0' && f[i] <= '7'; i++) {
        if (v > (UINT64_MAX >> 3)) return false;
        v = v * 8 + (uint64_t)(f[i] - '0');
    }
    for (; i < width; i++)
        if (f[i] != ' ' && f[i] != '\0') return false;
    *out = v;
    return true;
}

static bool checksum_ok(const uint8_t *h) {
    uint64_t stored;
    if (!parse_number(h + 148, 8, &stored)) return false;
    uint64_t usum = 0;
    int64_t ssum = 0;
    for (int i = 0; i < BLOCK; i++) {
        uint8_t b = (i >= 148 && i < 156) ? ' ' : h[i];
        usum += b;
        ssum += (int8_t)b;
    }
    return stored == usum || (int64_t)stored == ssum;
}

static bool all_zero(const uint8_t *p, size_t n) {
    for (size_t i = 0; i < n; i++)
        if (p[i]) return false;
    return true;
}

/* Copy a fixed-width, possibly unterminated name field. */
static void field_string(char *dst, const uint8_t *f, size_t width) {
    size_t n = 0;
    while (n < width && f[n]) n++;
    memcpy(dst, f, n);
    dst[n] = '\0';
}

/* ------------------------------------------------------------------------ */
/* Runs                                                                      */

typedef struct {
    uint64_t offset, length;
} run;

typedef struct {
    run *v;
    size_t n, cap;
} runs;

static int runs_add(runs *r, uint64_t offset, uint64_t length) {
    if (r->n == MAX_RUNS) return set_err(EINVAL, "sparse map has too many entries");
    if (r->n == r->cap) {
        size_t cap = r->cap ? r->cap * 2 : 16;
        run *v = realloc(r->v, cap * sizeof *v);
        if (!v) return set_err(ENOMEM, "out of memory for the sparse map");
        r->v = v;
        r->cap = cap;
    }
    r->v[r->n++] = (run){offset, length};
    return 0;
}

/* Runs must be ordered, non-overlapping, inside realsize, and hold exactly
 * `stored` bytes of data. */
static int runs_validate(const runs *r, uint64_t realsize, uint64_t stored) {
    uint64_t end = 0, sum = 0;
    for (size_t i = 0; i < r->n; i++) {
        const run *x = &r->v[i];
        if (x->offset < end) return set_err(EINVAL, "sparse map entries overlap or are out of order");
        if (x->length > realsize || x->offset > realsize - x->length)
            return set_err(EINVAL, "sparse map entry beyond the end of the file");
        end = x->offset + x->length;
        sum += x->length;
    }
    if (sum != stored) return set_err(EINVAL, "sparse map describes %llu bytes, archive stores %llu",
                                      (unsigned long long)sum, (unsigned long long)stored);
    return 0;
}

/* Old GNU sparse map: 4 entries in the header, then extension blocks. */
static int gnu_sparse_map(source *s, const uint8_t *h, runs *r, uint64_t *realsize) {
    if (!parse_number(h + 483, 12, realsize)) return set_err(EINVAL, "bad sparse real size");
    const uint8_t *entries = h + 386;
    int count = 4;
    bool extended = h[482] != 0;
    uint8_t ext[BLOCK];
    for (;;) {
        for (int i = 0; i < count; i++) {
            const uint8_t *e = entries + 24 * i;
            if (e[0] == '\0') break;
            uint64_t off, len;
            if (!parse_number(e, 12, &off) || !parse_number(e + 12, 12, &len))
                return set_err(EINVAL, "bad sparse map entry");
            int err = runs_add(r, off, len);
            if (err) return err;
        }
        if (!extended) return 0;
        int err = src_read(s, ext, BLOCK);
        if (err) return err;
        entries = ext;
        count = 21;
        extended = ext[504] != 0;
    }
}

/* pax 1.0 sparse map: decimal lines at the start of the data, padded to a
 * block. Returns the bytes consumed in *map_bytes. */
static int pax_sparse_map(source *s, runs *r, uint64_t data_size, uint64_t *map_bytes) {
    uint64_t numbers_needed = 1, numbers_read = 0, value = 0, count = 0, offset = 0;
    unsigned digits = 0;
    uint8_t block[BLOCK];
    *map_bytes = 0;
    while (numbers_read < numbers_needed) {
        if (*map_bytes + BLOCK > data_size) return set_err(EINVAL, "truncated sparse map");
        int err = src_read(s, block, BLOCK);
        if (err) return err;
        *map_bytes += BLOCK;
        for (int i = 0; i < BLOCK && numbers_read < numbers_needed; i++) {
            uint8_t c = block[i];
            if (c >= '0' && c <= '9') {
                if (++digits > 20 || value > (UINT64_MAX - 9) / 10) return set_err(EINVAL, "bad sparse map number");
                value = value * 10 + (uint64_t)(c - '0');
                continue;
            }
            if (c != '\n' || digits == 0) return set_err(EINVAL, "bad sparse map");
            if (numbers_read == 0) {
                if (value > MAX_RUNS) return set_err(EINVAL, "sparse map has too many entries");
                count = value;
                numbers_needed = 1 + 2 * count;
            } else if (numbers_read % 2 == 1) {
                offset = value;
            } else {
                err = runs_add(r, offset, value);
                if (err) return err;
            }
            numbers_read++;
            value = 0;
            digits = 0;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------------ */
/* Output                                                                    */

typedef struct {
    int fd;
    uint64_t realsize, done;
    mnd_tar_progress progress;
    void *progress_ctx;
} sink;

/* Write data at `offset`, leaving all-zero windows as holes. */
static int sink_write(sink *k, const uint8_t *p, size_t n, uint64_t offset) {
    size_t i = 0;
    while (i < n) {
        size_t w = n - i < ZERO_WINDOW ? n - i : ZERO_WINDOW;
        if (all_zero(p + i, w)) {
            i += w;
            continue;
        }
        /* Extend over following non-zero windows to write in one call. */
        size_t j = i + w;
        while (j < n) {
            size_t w2 = n - j < ZERO_WINDOW ? n - j : ZERO_WINDOW;
            if (all_zero(p + j, w2)) break;
            j += w2;
        }
        size_t off = 0;
        while (off < j - i) {
            ssize_t r = pwrite(k->fd, p + i + off, j - i - off, (off_t)(offset + i + off));
            if (r < 0) {
                if (errno == EINTR) continue;
                return set_err(errno, "writing the extracted file: %s", strerror(errno));
            }
            off += (size_t)r;
        }
        i = j;
    }
    return 0;
}

static int copy_runs(source *s, sink *k, const runs *r) {
    for (size_t i = 0; i < r->n; i++) {
        uint64_t left = r->v[i].length, pos = r->v[i].offset;
        while (left > 0) {
            const uint8_t *p;
            size_t got;
            int err = src_peek(s, left > (1 << 16) ? (1 << 16) : (size_t)left, &p, &got);
            if (err) return err;
            if (got == 0) return set_err(EINVAL, "unexpected end of archive");
            err = sink_write(k, p, got, pos);
            if (err) return err;
            s->pos += got;
            pos += got;
            left -= got;
            k->done = pos;
            if (k->progress && !k->progress(k->progress_ctx, k->done, k->realsize))
                return set_err(ECANCELED, "cancelled");
        }
    }
    return 0;
}

/* ------------------------------------------------------------------------ */
/* Archive walk                                                              */

typedef struct {
    char *name;        /* from a GNU long name ('L') */
    char *path;        /* pax path */
    bool has_size;     /* pax size */
    uint64_t size;
    int sparse_major, sparse_minor;
    char *sparse_name;
    bool has_realsize;
    uint64_t realsize;
    bool unsupported_sparse;
} pending;

static void pending_clear(pending *p) {
    free(p->name);
    free(p->path);
    free(p->sparse_name);
    memset(p, 0, sizeof *p);
    p->sparse_major = p->sparse_minor = -1;
}

static bool parse_decimal(const char *s, size_t n, uint64_t *out) {
    uint64_t v = 0;
    if (n == 0 || n > 20) return false;
    for (size_t i = 0; i < n; i++) {
        if (s[i] < '0' || s[i] > '9' || v > (UINT64_MAX - 9) / 10) return false;
        v = v * 10 + (uint64_t)(s[i] - '0');
    }
    *out = v;
    return true;
}

static char *dup_n(const char *s, size_t n) {
    char *d = malloc(n + 1);
    if (d) {
        memcpy(d, s, n);
        d[n] = '\0';
    }
    return d;
}

static int parse_pax(const char *data, size_t n, pending *p) {
    size_t i = 0;
    while (i < n) {
        size_t j = i, len = 0;
        while (j < n && data[j] >= '0' && data[j] <= '9' && j - i < 10) len = len * 10 + (size_t)(data[j++] - '0');
        if (j == i || j >= n || data[j] != ' ' || len <= j - i + 1 || len > n - i || data[i + len - 1] != '\n')
            return set_err(EINVAL, "malformed pax header");
        const char *key = data + j + 1, *end = data + i + len - 1;
        const char *eq = memchr(key, '=', (size_t)(end - key));
        if (!eq) return set_err(EINVAL, "malformed pax record");
        size_t klen = (size_t)(eq - key), vlen = (size_t)(end - eq - 1);
        const char *val = eq + 1;
#define KEY(k) (klen == sizeof(k) - 1 && memcmp(key, k, klen) == 0)
        uint64_t num;
        if (KEY("path")) {
            free(p->path);
            p->path = dup_n(val, vlen);
        } else if (KEY("size")) {
            if (!parse_decimal(val, vlen, &p->size)) return set_err(EINVAL, "bad pax size");
            p->has_size = true;
        } else if (KEY("GNU.sparse.major")) {
            if (!parse_decimal(val, vlen, &num) || num > 9) return set_err(EINVAL, "bad sparse version");
            p->sparse_major = (int)num;
        } else if (KEY("GNU.sparse.minor")) {
            if (!parse_decimal(val, vlen, &num) || num > 9) return set_err(EINVAL, "bad sparse version");
            p->sparse_minor = (int)num;
        } else if (KEY("GNU.sparse.name")) {
            free(p->sparse_name);
            p->sparse_name = dup_n(val, vlen);
        } else if (KEY("GNU.sparse.realsize") || KEY("GNU.sparse.size")) {
            if (!parse_decimal(val, vlen, &p->realsize)) return set_err(EINVAL, "bad sparse size");
            p->has_realsize = true;
        } else if (KEY("GNU.sparse.map") || KEY("GNU.sparse.offset") || KEY("GNU.sparse.numblocks")) {
            p->unsupported_sparse = true; /* pax sparse 0.0 / 0.1 */
        }
#undef KEY
        i += len;
    }
    return 0;
}

static const char *strip_dot_slash(const char *name) {
    while (name[0] == '.' && name[1] == '/') {
        name += 2;
        while (*name == '/') name++;
    }
    return name;
}

/* Extract the member whose header is h (after metadata in p). */
static int extract_member(source *s, const uint8_t *h, uint64_t size, pending *p, const char *dst,
                          mnd_tar_progress progress, void *pctx, uint64_t *out_size) {
    runs r = {0};
    uint64_t realsize = size, stored = size, map_bytes = 0;
    int err = 0;
    if (h[156] == 'S') {
        err = gnu_sparse_map(s, h, &r, &realsize);
    } else if (p->sparse_major == 1 && p->sparse_minor == 0) {
        if (!p->has_realsize) err = set_err(EINVAL, "pax sparse member without a real size");
        else {
            realsize = p->realsize;
            err = pax_sparse_map(s, &r, size, &map_bytes);
            stored = size - map_bytes;
        }
    } else if (p->unsupported_sparse || p->sparse_major >= 0) {
        err = set_err(ENOTSUP, "unsupported sparse format %d.%d", p->sparse_major, p->sparse_minor);
    } else {
        err = runs_add(&r, 0, size);
    }
    if (!err) err = runs_validate(&r, realsize, stored);
    if (err) {
        free(r.v);
        return err;
    }

    unlink(dst);
    int fd = open(dst, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) {
        free(r.v);
        return set_err(errno, "creating %s: %s", dst, strerror(errno));
    }
    sink k = {fd, realsize, 0, progress, pctx};
    err = copy_runs(s, &k, &r);
    free(r.v);
    if (!err && ftruncate(fd, (off_t)realsize) != 0) err = set_err(errno, "sizing the file: %s", strerror(errno));
    if (!err) err = src_skip(s, padded(size) - size);
    if (close(fd) != 0 && !err) err = set_err(errno, "closing the file: %s", strerror(errno));
    if (err) {
        unlink(dst);
        return err;
    }
    *out_size = realsize;
    return 0;
}

int mnd_tar_extract(mnd_tar_read_fn read, void *read_ctx, const char *pattern, const char *dst,
                    mnd_tar_progress progress, void *progress_ctx, uint64_t *size) {
    source *s = calloc(1, sizeof *s);
    if (!s) return set_err(ENOMEM, "out of memory");
    s->read = read;
    s->ctx = read_ctx;
    g_err[0] = '\0';
    pending p;
    memset(&p, 0, sizeof p);
    pending_clear(&p);
    uint8_t h[BLOCK];
    char *name = malloc(MAX_LONGNAME + 256);
    char *meta = NULL;
    int err = 0;
    bool found = false;
    if (!name) {
        err = set_err(ENOMEM, "out of memory");
        goto out;
    }

    for (;;) {
        /* A header, or a clean end of input at a block boundary. */
        const uint8_t *peek;
        size_t avail;
        if ((err = src_peek(s, 1, &peek, &avail))) break;
        if (avail == 0) break;
        if ((err = src_read(s, h, BLOCK))) break;
        if (all_zero(h, BLOCK)) break; /* end-of-archive marker */
        if (!checksum_ok(h)) {
            err = set_err(EINVAL, "header checksum mismatch");
            break;
        }
        uint64_t hsize;
        if (!parse_number(h + 124, 12, &hsize)) {
            err = set_err(EINVAL, "bad size field");
            break;
        }
        char type = (char)h[156];

        if (type == 'L' || type == 'x' || type == 'g') {
            size_t cap = type == 'L' ? MAX_LONGNAME : MAX_PAX;
            if (hsize > cap) {
                err = set_err(EINVAL, "metadata member too large");
                break;
            }
            free(meta);
            meta = malloc((size_t)hsize + 1);
            if (!meta) {
                err = set_err(ENOMEM, "out of memory");
                break;
            }
            if ((err = src_read(s, meta, (size_t)hsize))) break;
            meta[hsize] = '\0';
            if ((err = src_skip(s, padded(hsize) - hsize))) break;
            if (type == 'L') {
                free(p.name);
                p.name = dup_n(meta, strlen(meta));
            } else if (type == 'x') {
                if ((err = parse_pax(meta, (size_t)hsize, &p))) break;
            }
            continue;
        }

        /* Effective name and size. */
        if (p.sparse_name) snprintf(name, MAX_LONGNAME + 256, "%s", p.sparse_name);
        else if (p.path) snprintf(name, MAX_LONGNAME + 256, "%s", p.path);
        else if (p.name) snprintf(name, MAX_LONGNAME + 256, "%s", p.name);
        else {
            char base[101], prefix[156];
            field_string(base, h, 100);
            bool posix = memcmp(h + 257, "ustar\0", 6) == 0;
            if (posix && h[345]) {
                field_string(prefix, h + 345, 155);
                snprintf(name, MAX_LONGNAME + 256, "%s/%s", prefix, base);
            } else {
                snprintf(name, MAX_LONGNAME + 256, "%s", base);
            }
        }
        uint64_t size_here = p.has_size ? p.size : hsize;
        bool regular = type == '0' || type == '\0' || type == '7' || type == 'S';

        if (regular && fnmatch(pattern, strip_dot_slash(name), 0) == 0) {
            err = extract_member(s, h, size_here, &p, dst, progress, progress_ctx, size);
            if (!err) found = true;
            break;
        }
        /* Skip this member's data (links and directories carry none). */
        uint64_t skip = (type == '1' || type == '2' || type == '5') ? 0 : size_here;
        if ((err = src_skip(s, padded(skip)))) break;
        pending_clear(&p);
    }
    if (!err && !found) err = set_err(ENOENT, "no member matches %s", pattern);

out:
    pending_clear(&p);
    free(meta);
    free(name);
    free(s);
    return err;
}
