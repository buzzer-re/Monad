/*
 * mnd_loop.h — a small level-triggered event loop for monad-netd: kqueue on
 * macOS, epoll on Linux (where the tests run).
 *
 * A callback may watch, change or unwatch any descriptor, including its own
 * and ones with events still pending in the same batch: an event for a
 * descriptor unwatched (or watched again) after it was collected is not
 * delivered.
 */
#ifndef MND_LOOP_H
#define MND_LOOP_H

#include <stdint.h>

#define MND_LOOP_READ 1u
#define MND_LOOP_WRITE 2u
#define MND_LOOP_MAX_FDS 8192 /* descriptors must be below this */

typedef struct mnd_loop mnd_loop;
typedef void (*mnd_loop_fn)(void *ctx, int fd, unsigned events);

mnd_loop *mnd_loop_create(void);
void mnd_loop_destroy(mnd_loop *loop); /* does not close watched descriptors */

/* Watch fd for `events` (READ and/or WRITE), replacing what was watched;
 * events 0 stops watching. Returns 0, or -1. */
int mnd_loop_watch(mnd_loop *loop, int fd, unsigned events, mnd_loop_fn fn, void *ctx);

/* Waits for events until `deadline` (mnd_loop_now clock; UINT64_MAX: no
 * limit), dispatches them, and returns how many callbacks ran (0 at the
 * deadline), or -1 on error. */
int mnd_loop_run_once(mnd_loop *loop, uint64_t deadline);

/* Monotonic milliseconds. */
uint64_t mnd_loop_now(void);

#endif /* MND_LOOP_H */
