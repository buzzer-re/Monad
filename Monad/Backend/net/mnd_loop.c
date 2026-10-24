/*
 * mnd_loop.c — see mnd_loop.h. kqueue on macOS, epoll on Linux.
 *
 * Every descriptor has a slot with its callback and a generation that
 * changes whenever its watch changes. Events are collected, their
 * generations noted, and then dispatched one callback per descriptor; an
 * event whose slot changed in the meantime is dropped.
 */
#include "mnd_loop.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#ifdef __APPLE__
#include <sys/event.h>
#else
#include <sys/epoll.h>
#endif

#define BATCH 256

typedef struct {
    mnd_loop_fn fn;
    void *ctx;
    unsigned events;
    uint32_t gen;
} slot;

struct mnd_loop {
    int kfd;
    slot slots[MND_LOOP_MAX_FDS];
};

uint64_t mnd_loop_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

mnd_loop *mnd_loop_create(void) {
    mnd_loop *loop = calloc(1, sizeof *loop);
    if (!loop) return NULL;
#ifdef __APPLE__
    loop->kfd = kqueue();
#else
    loop->kfd = epoll_create1(EPOLL_CLOEXEC);
#endif
    if (loop->kfd < 0) {
        free(loop);
        return NULL;
    }
    return loop;
}

void mnd_loop_destroy(mnd_loop *loop) {
    if (!loop) return;
    close(loop->kfd);
    free(loop);
}

#ifdef __APPLE__
static int apply(mnd_loop *loop, int fd, unsigned old, unsigned events) {
    struct kevent ch[2];
    int n = 0;
    if ((old ^ events) & MND_LOOP_READ) {
        EV_SET(&ch[n], (uintptr_t)fd, EVFILT_READ, (events & MND_LOOP_READ) ? EV_ADD : EV_DELETE, 0, 0, NULL);
        n++;
    }
    if ((old ^ events) & MND_LOOP_WRITE) {
        EV_SET(&ch[n], (uintptr_t)fd, EVFILT_WRITE, (events & MND_LOOP_WRITE) ? EV_ADD : EV_DELETE, 0, 0, NULL);
        n++;
    }
    if (!n) return 0;
    /* A descriptor closed before it was unwatched is already gone from the queue. */
    if (kevent(loop->kfd, ch, n, NULL, 0, NULL) < 0 && !(events == 0 && (errno == ENOENT || errno == EBADF)))
        return -1;
    return 0;
}
#else
static int apply(mnd_loop *loop, int fd, unsigned old, unsigned events) {
    struct epoll_event ev = {0};
    ev.data.fd = fd;
    if (events & MND_LOOP_READ) ev.events |= EPOLLIN;
    if (events & MND_LOOP_WRITE) ev.events |= EPOLLOUT;
    int op = !old ? EPOLL_CTL_ADD : !events ? EPOLL_CTL_DEL : EPOLL_CTL_MOD;
    if (epoll_ctl(loop->kfd, op, fd, &ev) < 0 && !(op == EPOLL_CTL_DEL && (errno == ENOENT || errno == EBADF)))
        return -1;
    return 0;
}
#endif

int mnd_loop_watch(mnd_loop *loop, int fd, unsigned events, mnd_loop_fn fn, void *ctx) {
    if (!loop || fd < 0 || fd >= MND_LOOP_MAX_FDS) return -1;
    events &= MND_LOOP_READ | MND_LOOP_WRITE;
    if (events && !fn) return -1;
    slot *s = &loop->slots[fd];
    if (apply(loop, fd, s->events, events) != 0) return -1;
    s->events = events;
    s->fn = events ? fn : NULL;
    s->ctx = events ? ctx : NULL;
    s->gen++;
    return 0;
}

int mnd_loop_run_once(mnd_loop *loop, uint64_t deadline) {
    if (!loop) return -1;
    uint64_t now = mnd_loop_now();
    int timeout_ms = -1;
    if (deadline != UINT64_MAX) {
        uint64_t wait = deadline > now ? deadline - now : 0;
        timeout_ms = wait > 60000 ? 60000 : (int)wait; /* long waits wake up once a minute */
    }
    int fds[BATCH];
    unsigned what[BATCH];
    uint32_t gens[BATCH];
    int count = 0;
#ifdef __APPLE__
    struct kevent evs[BATCH];
    struct timespec ts = {timeout_ms / 1000, (long)(timeout_ms % 1000) * 1000000};
    int n = kevent(loop->kfd, NULL, 0, evs, BATCH, timeout_ms < 0 ? NULL : &ts);
    if (n < 0) return errno == EINTR ? 0 : -1;
    for (int i = 0; i < n; i++) {
        int fd = (int)evs[i].ident;
        unsigned e = evs[i].filter == EVFILT_READ ? MND_LOOP_READ : MND_LOOP_WRITE;
        int k = 0;
        while (k < count && fds[k] != fd) k++;
        if (k == count) {
            fds[count] = fd;
            what[count] = 0;
            count++;
        }
        what[k] |= e;
    }
#else
    struct epoll_event evs[BATCH];
    int n = epoll_wait(loop->kfd, evs, BATCH, timeout_ms);
    if (n < 0) return errno == EINTR ? 0 : -1;
    for (int i = 0; i < n; i++) {
        unsigned e = 0;
        if (evs[i].events & EPOLLIN) e |= MND_LOOP_READ;
        if (evs[i].events & EPOLLOUT) e |= MND_LOOP_WRITE;
        /* Errors and hang-ups: report what is watched; the I/O tells the rest. */
        if (evs[i].events & (EPOLLERR | EPOLLHUP)) e |= MND_LOOP_READ | MND_LOOP_WRITE;
        fds[count] = evs[i].data.fd;
        what[count] = e;
        count++;
    }
#endif
    for (int i = 0; i < count; i++) gens[i] = loop->slots[fds[i]].gen;
    int ran = 0;
    for (int i = 0; i < count; i++) {
        slot *s = &loop->slots[fds[i]];
        unsigned e = what[i] & s->events;
        if (!e || s->gen != gens[i] || !s->fn) continue;
        s->fn(s->ctx, fds[i], e);
        ran++;
    }
    return ran;
}
