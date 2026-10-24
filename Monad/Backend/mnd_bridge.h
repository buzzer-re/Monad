/*
 * mnd_bridge.h — expose a byte-stream service (e.g. a VM's vsock port) on a
 * private unix-domain socket. Every accepted client gets its own upstream
 * connection and a splice thread copying bytes in both directions.
 */
#ifndef MND_BRIDGE_H
#define MND_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mnd_bridge mnd_bridge;

typedef struct {
    void *ctx;
    /* Open an upstream connection; may block. Returns an fd or -1. Called on
     * a bridge worker thread. */
    int (*connect)(void *ctx);
    /* Release an upstream fd obtained from connect (must close it). */
    void (*release)(void *ctx, int fd);
} mnd_bridge_upstream;

/* Listen on socket_path (created 0600; an existing socket file is replaced).
 * Returns NULL and sets *err (errno) on failure. */
mnd_bridge *mnd_bridge_start(const char *socket_path, mnd_bridge_upstream upstream, int *err);

/* Stop listening, tear down all active connections, wait for worker threads
 * and unlink the socket. Safe to call once. */
void mnd_bridge_stop(mnd_bridge *b);

/* Number of live client connections. */
int mnd_bridge_active(mnd_bridge *b);

#ifdef __cplusplus
}
#endif

#endif
