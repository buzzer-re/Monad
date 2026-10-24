/*
 * mnd_disk.c — raw disk image helpers.
 */
#include "mnd_disk.h"

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/clonefile.h>
#endif

#define CHUNK (1u << 20)

static bool zero_block(const uint8_t *p, size_t n) {
    for (size_t i = 0; i < n; i++)
        if (p[i]) return false;
    return true;
}

static int sparse_copy(const char *src, const char *dst) {
    int in = open(src, O_RDONLY | O_CLOEXEC);
    if (in < 0) return errno;
    struct stat st;
    if (fstat(in, &st) != 0) {
        int e = errno;
        close(in);
        return e;
    }
    int out = open(dst, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (out < 0) {
        int e = errno;
        close(in);
        return e;
    }
    uint8_t *buf = malloc(CHUNK);
    int e = buf ? 0 : ENOMEM;
    off_t off = 0;
    while (!e) {
        ssize_t r = pread(in, buf, CHUNK, off);
        if (r < 0) {
            if (errno == EINTR) continue;
            e = errno;
            break;
        }
        if (r == 0) break;
        if (!zero_block(buf, (size_t)r)) {
            ssize_t done = 0;
            while (done < r) {
                ssize_t w = pwrite(out, buf + done, (size_t)(r - done), off + done);
                if (w < 0) {
                    if (errno == EINTR) continue;
                    e = errno;
                    break;
                }
                done += w;
            }
        }
        off += r;
    }
    if (!e && ftruncate(out, st.st_size) != 0) e = errno;
    if (!e && fsync(out) != 0) e = errno;
    free(buf);
    close(in);
    if (close(out) != 0 && !e) e = errno;
    if (e) unlink(dst);
    return e;
}

int mnd_disk_clone(const char *src, const char *dst) {
    if (!src || !dst) return EINVAL;
    if (access(dst, F_OK) == 0) return EEXIST;
#if defined(__APPLE__)
    if (clonefile(src, dst, CLONE_NOFOLLOW | CLONE_NOOWNERCOPY) == 0) return 0;
    if (errno != ENOTSUP && errno != EXDEV) return errno;
#endif
    return sparse_copy(src, dst);
}

int mnd_disk_grow(const char *path, uint64_t size) {
    struct stat st;
    if (stat(path, &st) != 0) return errno;
    if ((uint64_t)st.st_size >= size) return 0;
    if (truncate(path, (off_t)size) != 0) return errno;
    return 0;
}

int mnd_disk_free_bytes(const char *path, uint64_t *out) {
    struct statvfs vfs;
    if (statvfs(path, &vfs) != 0) return errno;
    *out = (uint64_t)vfs.f_bavail * (uint64_t)vfs.f_frsize;
    return 0;
}

int mnd_disk_allocated_bytes(const char *path, uint64_t *out) {
    struct stat st;
    if (stat(path, &st) != 0) return errno;
    *out = (uint64_t)st.st_blocks * 512u;
    return 0;
}
