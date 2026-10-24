/*
 * mnd_rotlog.h — an append-only log file that never grows past a cap.
 *
 * When a write would pass the cap, the file becomes <path>.1 (replacing any
 * previous one) and a fresh file starts, so at most 2 x cap bytes are ever
 * on disk. Used for guest console output, which a guest controls.
 * Not thread-safe: use from one queue.
 */
#ifndef MND_ROTLOG_H
#define MND_ROTLOG_H

#include <stddef.h>

typedef struct mnd_rotlog mnd_rotlog;

/* Opens (truncating) path. cap must be > 0. NULL with *err set on failure. */
mnd_rotlog *mnd_rotlog_open(const char *path, size_t cap, int *err);
/* 0 or an errno. A write larger than cap keeps only its last cap bytes. */
int mnd_rotlog_write(mnd_rotlog *l, const void *data, size_t len);
/* Start over with an empty file (e.g. a new boot); drops <path>.1. */
void mnd_rotlog_reset(mnd_rotlog *l);
void mnd_rotlog_close(mnd_rotlog *l);

#endif /* MND_ROTLOG_H */
