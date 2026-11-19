/*
 * mwm_gl.h — the window manager's part in drawing by the Mac's GPU: the
 * way through for a program's drawing commands (mwm_gl_wire.h). A
 * program's library connects here; MonadHost, which the Mac's side dials
 * from, connects too; what a program writes goes to MonadHost as that
 * program's stream, and MonadHost's answers come back to it. The window
 * manager reads none of it.
 *
 * Neither side holds the other up for good or makes this grow: when
 * MonadHost is slow to read, programs are not read from (they wait in
 * their writes, as they would for a slow graphics card), and when a
 * program is slow to read its answers, MonadHost is not read from.
 */
#ifndef MWM_GL_H
#define MWM_GL_H

#include "mwm_gl_wire.h"

#include <stdbool.h>

/* All there is to poll at most: MonadHost and every program. */
enum { MWM_GL_SOCKETS = MWM_GL_STREAMS + 1 };

typedef struct mwm_gl mwm_gl;

mwm_gl *mwm_gl_new(void);
void mwm_gl_free(mwm_gl *g);

/* MonadHost connected for drawing: its socket, taken. The one before, if
 * any, is closed, and with it every program's stream (what they drew with
 * is gone with it). */
void mwm_gl_attach(mwm_gl *g, int fd);
/* Whether MonadHost is connected: programs can only draw this way while it is. */
bool mwm_gl_attached(const mwm_gl *g);
/* A program's library connected: its socket, taken. False (and the socket
 * closed) with no MonadHost, or with as many programs as there may be. */
bool mwm_gl_add(mwm_gl *g, int fd);

/* What there is to poll, and for what: how many were written (at most `max`). */
int mwm_gl_sockets(const mwm_gl *g, int *fds, bool *wants_read, bool *wants_write, int max);
/* One of those can be read from, or written to. */
void mwm_gl_service(mwm_gl *g, int fd, bool readable, bool writable);

#endif
