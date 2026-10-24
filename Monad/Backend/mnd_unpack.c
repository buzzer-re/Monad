/*
 * mnd_unpack.c — .xz / .gz disk images into sparse files.
 */
#include "mnd_unpack.h"
#include "mnd_xz.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#define OUT_CHUNK (1u << 20)
#define IN_CHUNK (256u << 10)
#define HOLE_BLOCK (64u << 10)
#define MAX_OUT ((uint64_t)1 << 40)

static _Thread_local char g_err[256];

const char *mnd_unpack_last_error(void) { return g_err; }

static int fail(int code, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_err, sizeof g_err, fmt, ap);
    va_end(ap);
    return code;
}

typedef struct {
    int fd;
    uint64_t off;
} out_t;

static bool all_zero(const unsigned char *p, size_t n) {
    for (size_t i = 0; i < n; i++)
        if (p[i]) return false;
    return true;
}

/* Append n bytes; zero blocks become holes (the size is set at the end). */
static int put(out_t *o, const unsigned char *p, size_t n) {
    if (o->off + n > MAX_OUT) return fail(EFBIG, "the image decompresses to more than 1 TiB");
    while (n > 0) {
        size_t k = n < HOLE_BLOCK ? n : HOLE_BLOCK;
        if (!all_zero(p, k)) {
            size_t w = 0;
            while (w < k) {
                ssize_t r = pwrite(o->fd, p + w, k - w, (off_t)(o->off + w));
                if (r < 0) {
                    if (errno == EINTR) continue;
                    return fail(errno, "writing the disk: %s", strerror(errno));
                }
                w += (size_t)r;
            }
        }
        o->off += k;
        p += k;
        n -= k;
    }
    return 0;
}

static int unxz(int in, out_t *o, uint64_t memlimit, uint64_t total, mnd_unpack_progress progress, void *ctx,
                unsigned char *buf) {
    mnd_xz_file *f = mnd_xz_file_open(in, memlimit);
    if (!f) return fail(ENOMEM, "out of memory");
    int rc = 0;
    for (;;) {
        ssize_t r = mnd_xz_file_read(f, buf, OUT_CHUNK);
        if (r == 0) break;
        if (r < 0) {
            int code = r == MND_XZ_ENOMEM ? ENOMEM : r == MND_XZ_EIO ? EIO : EINVAL;
            rc = fail(code, "not a valid .xz file: %s", mnd_xz_file_error(f));
            break;
        }
        if ((rc = put(o, buf, (size_t)r)) != 0) break;
        if (progress && !progress(ctx, mnd_xz_file_position(f), total)) {
            rc = fail(ECANCELED, "cancelled");
            break;
        }
    }
    mnd_xz_file_close(f);
    return rc;
}

static int gunzip(int in, out_t *o, uint64_t total, mnd_unpack_progress progress, void *ctx, unsigned char *buf) {
    unsigned char magic[2];
    if (pread(in, magic, 2, 0) != 2 || magic[0] != 0x1f || magic[1] != 0x8b) {
        return fail(EINVAL, "not a gzip file");
    }
    unsigned char *inbuf = malloc(IN_CHUNK);
    if (!inbuf) return fail(ENOMEM, "out of memory");
    z_stream s;
    memset(&s, 0, sizeof s);
    if (inflateInit2(&s, 16 + MAX_WBITS) != Z_OK) {
        free(inbuf);
        return fail(ENOMEM, "out of memory");
    }
    int rc = 0;
    uint64_t consumed = 0;
    bool in_member = true, eof = false, padding = false;
    for (;;) {
        if (s.avail_in == 0 && !eof) {
            ssize_t r = read(in, inbuf, IN_CHUNK);
            if (r < 0) {
                if (errno == EINTR) continue;
                rc = fail(EIO, "reading the image: %s", strerror(errno));
                break;
            }
            if (r == 0) {
                eof = true;
            } else {
                s.next_in = inbuf;
                s.avail_in = (uInt)r;
            }
        }
        if (s.avail_in == 0 && eof) {
            if (in_member) rc = fail(EINVAL, "the gzip file is truncated");
            break;
        }
        if (!in_member) {
            /* Another member, or zero padding up to the end. */
            if (*s.next_in == 0) {
                padding = true;
                s.next_in++;
                s.avail_in--;
                consumed++;
                continue;
            }
            if (padding) {
                rc = fail(EINVAL, "data after the end of the gzip stream");
                break;
            }
            inflateReset(&s);
            in_member = true;
        }
        s.next_out = buf;
        s.avail_out = OUT_CHUNK;
        uInt before = s.avail_in;
        int zr = inflate(&s, Z_NO_FLUSH);
        consumed += before - s.avail_in;
        if ((rc = put(o, buf, OUT_CHUNK - s.avail_out)) != 0) break;
        if (zr == Z_STREAM_END) {
            in_member = false;
        } else if (zr == Z_BUF_ERROR && s.avail_in == 0) {
            /* needs more input */
        } else if (zr != Z_OK) {
            rc = fail(EINVAL, "not a valid gzip file: %s", s.msg ? s.msg : "corrupt data");
            break;
        }
        if (progress && !progress(ctx, consumed, total)) {
            rc = fail(ECANCELED, "cancelled");
            break;
        }
    }
    inflateEnd(&s);
    free(inbuf);
    return rc;
}

int mnd_unpack(const char *src, const char *dst, int kind, uint64_t memlimit, mnd_unpack_progress progress,
               void *ctx) {
    g_err[0] = 0;
    if (!src || !dst || (kind != MND_UNPACK_XZ && kind != MND_UNPACK_GZIP)) {
        return fail(EINVAL, "unknown compression");
    }
    int in = open(src, O_RDONLY | O_CLOEXEC);
    if (in < 0) return fail(errno, "%s: %s", src, strerror(errno));
    struct stat st;
    if (fstat(in, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(in);
        return fail(EINVAL, "%s is not a file", src);
    }
    /* Never through a link someone left at dst. */
    if (unlink(dst) != 0 && errno != ENOENT) {
        int e = errno;
        close(in);
        return fail(e, "%s: %s", dst, strerror(e));
    }
    out_t o = {open(dst, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600), 0};
    if (o.fd < 0) {
        int e = errno;
        close(in);
        return fail(e, "%s: %s", dst, strerror(e));
    }
    unsigned char *buf = malloc(OUT_CHUNK);
    int rc = buf ? 0 : fail(ENOMEM, "out of memory");
    if (rc == 0) {
        rc = kind == MND_UNPACK_XZ ? unxz(in, &o, memlimit, (uint64_t)st.st_size, progress, ctx, buf)
                                   : gunzip(in, &o, (uint64_t)st.st_size, progress, ctx, buf);
    }
    if (rc == 0 && ftruncate(o.fd, (off_t)o.off) != 0) rc = fail(errno, "sizing the disk: %s", strerror(errno));
    free(buf);
    close(in);
    if (close(o.fd) != 0 && rc == 0) rc = fail(errno, "writing the disk: %s", strerror(errno));
    if (rc != 0) unlink(dst);
    return rc;
}
