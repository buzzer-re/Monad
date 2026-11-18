/*
 * mwm_wire.h — the Wayland wire format for Monad's window manager (the
 * program that hands a Linux VM's windows to the Mac, GuestWM/): one
 * client's socket, the messages read from it and written to it, and the
 * file descriptors that travel beside them.
 *
 * A message is an object id, then size and opcode in one word, then its
 * arguments, each in 32-bit words: numbers, object ids, strings and arrays
 * (a length, the bytes, padding), and file descriptors, which are not in
 * the bytes at all (SCM_RIGHTS, in order). Everything a client sends is
 * read with its bounds checked: a program in the VM can be anything.
 *
 * Plain C and POSIX sockets, so it is tested on the Mac and on Linux
 * (CTests/test_wm_wire.c).
 */
#ifndef MWM_WIRE_H
#define MWM_WIRE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum {
    MWM_HEADER = 8,
    /* Wayland's own limit on one message. */
    MWM_MAX_MESSAGE = 4096,
    /* Descriptors a client may have sent and not yet used. */
    MWM_MAX_FDS = 32,
    /* Bytes waiting for a client that does not read: beyond, it is dropped. */
    MWM_MAX_OUT = 1 << 20,
};

typedef struct mwm_conn mwm_conn;

/* A message being read: its arguments are taken in order. */
typedef struct {
    uint32_t object;
    uint16_t opcode;
    uint16_t size; /* with the header */
    const uint8_t *body;
    uint32_t pos;
    mwm_conn *conn;
    /* An argument did not fit the message: everything read after is 0. */
    bool bad;
} mwm_msg;

/* Takes the socket (closed by mwm_conn_free); it is made non-blocking. */
mwm_conn *mwm_conn_new(int fd);
void mwm_conn_free(mwm_conn *c);
int mwm_conn_fd(const mwm_conn *c);

/* The client broke the format, sent too much, or does not read: drop it. */
bool mwm_conn_failed(const mwm_conn *c);

/* Reads what the socket has. 1: something came; 0: nothing now; -1: the
 * client is gone or failed. */
int mwm_conn_read(mwm_conn *c);

/* The next whole message, or false when none is complete (or the client
 * failed). The message is valid until the next call on this connection. */
bool mwm_conn_next(mwm_conn *c, mwm_msg *m);

uint32_t mwm_get_uint(mwm_msg *m);
int32_t mwm_get_int(mwm_msg *m);
/* NUL-terminated, inside the message; NULL for a null string or a bad one
 * (m->bad says which). *len: its length without the NUL. */
const char *mwm_get_string(mwm_msg *m, uint32_t *len);
const uint8_t *mwm_get_array(mwm_msg *m, uint32_t *len);
/* The next descriptor the client sent, now the caller's to close; -1 (and
 * the message bad) when there is none. */
int mwm_get_fd(mwm_msg *m);
/* Every argument fitted and nothing is left over. */
bool mwm_msg_done(const mwm_msg *m);

/* Writing one message: begin, its arguments, end. */
void mwm_put_begin(mwm_conn *c, uint32_t object, uint16_t opcode);
void mwm_put_uint(mwm_conn *c, uint32_t v);
void mwm_put_int(mwm_conn *c, int32_t v);
/* NULL: a null string. */
void mwm_put_string(mwm_conn *c, const char *s);
void mwm_put_array(mwm_conn *c, const void *data, uint32_t len);
/* Sent with the message; still the caller's to close. */
void mwm_put_fd(mwm_conn *c, int fd);
void mwm_put_end(mwm_conn *c);

/* Sends what is waiting. 1: all of it; 0: some is left (the socket is
 * full); -1: the client is gone or failed. */
int mwm_conn_flush(mwm_conn *c);
bool mwm_conn_wants_write(const mwm_conn *c);

#endif
