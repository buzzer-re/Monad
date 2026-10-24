/*
 * mnd_rotlog.c — size-capped log file with one rotated predecessor.
 */
#include "mnd_rotlog.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct mnd_rotlog {
    char *path;
    char *old_path;
    size_t cap;
    size_t size;
    int fd;
};

static int open_fresh(mnd_rotlog *l) {
    int fd = open(l->path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return errno;
    if (l->fd >= 0) close(l->fd);
    l->fd = fd;
    l->size = 0;
    return 0;
}

mnd_rotlog *mnd_rotlog_open(const char *path, size_t cap, int *err) {
    int e = EINVAL;
    mnd_rotlog *l = NULL;
    if (!path || cap == 0) goto fail;
    e = ENOMEM;
    l = calloc(1, sizeof *l);
    if (!l) goto fail;
    l->fd = -1;
    l->cap = cap;
    l->path = strdup(path);
    size_t n = strlen(path) + 3;
    l->old_path = malloc(n);
    if (!l->path || !l->old_path) goto fail;
    snprintf(l->old_path, n, "%s.1", path);
    e = open_fresh(l);
    if (e) goto fail;
    return l;
fail:
    if (l) {
        free(l->path);
        free(l->old_path);
        free(l);
    }
    if (err) *err = e;
    return NULL;
}

static int write_all(int fd, const unsigned char *p, size_t len) {
    while (len > 0) {
        ssize_t w = write(fd, p, len);
        if (w < 0) {
            if (errno == EINTR) continue;
            return errno;
        }
        p += w;
        len -= (size_t)w;
    }
    return 0;
}

int mnd_rotlog_write(mnd_rotlog *l, const void *data, size_t len) {
    if (!l || l->fd < 0) return EBADF;
    const unsigned char *p = data;
    if (len > l->cap) { /* only the tail can be kept */
        p += len - l->cap;
        len = l->cap;
    }
    if (l->size + len > l->cap) {
        if (rename(l->path, l->old_path) != 0) return errno;
        int e = open_fresh(l);
        if (e) return e;
    }
    int e = write_all(l->fd, p, len);
    if (!e) l->size += len;
    return e;
}

void mnd_rotlog_reset(mnd_rotlog *l) {
    if (!l) return;
    unlink(l->old_path);
    open_fresh(l);
}

void mnd_rotlog_close(mnd_rotlog *l) {
    if (!l) return;
    if (l->fd >= 0) close(l->fd);
    free(l->path);
    free(l->old_path);
    free(l);
}
