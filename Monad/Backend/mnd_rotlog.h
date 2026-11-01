/*
 * mnd_rotlog.h — an append-only log file that never grows past a cap.
 *
 * When a write would pass the cap, the file becomes <path>.1 (replacing any
 * previous one) and a fresh file starts, so at most 2 x cap bytes are ever
 * on disk. Used for guest console and health output, which a guest
 * controls, and kept across opens: what a guest said before it froze or
 * crashed is the reason Monad keeps it.
 * Not thread-safe: use from one queue.
 */
#ifndef MND_ROTLOG_H
#define MND_ROTLOG_H

#include <stddef.h>

typedef struct mnd_rotlog mnd_rotlog;

/* Opens path, appending to what is there (a file already at its cap is
 * rotated first); never follows a link. cap must be > 0. NULL with *err set
 * on failure. */
mnd_rotlog *mnd_rotlog_open(const char *path, size_t cap, int *err);
/* 0 or an errno. A write larger than cap keeps only its last cap bytes. */
int mnd_rotlog_write(mnd_rotlog *l, const void *data, size_t len);
/* A new boot: the file, if anything is in it, becomes <path>.1 and a fresh
 * one starts, so the boot before is still there to read. */
void mnd_rotlog_rotate(mnd_rotlog *l);
void mnd_rotlog_close(mnd_rotlog *l);

#endif /* MND_ROTLOG_H */
