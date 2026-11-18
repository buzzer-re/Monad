/*
 * test_wm_wire.c — the window manager's Wayland wire format (GuestWM/mwm_wire):
 * messages and descriptors across a socket, and what a client that breaks
 * the format or does not read gets.
 */
#include "mwm_wire.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)

static void pair(mwm_conn **a, mwm_conn **b, int raw[2]) {
    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    if (raw) {
        raw[0] = sv[0];
        raw[1] = sv[1];
    }
    if (a) *a = mwm_conn_new(sv[0]);
    if (b) *b = mwm_conn_new(sv[1]);
}

/* Every kind of argument crosses, a descriptor beside them. */
static void test_a_message_crosses(void) {
    mwm_conn *a, *b;
    pair(&a, &b, NULL);
    int p[2];
    CHECK(pipe(p) == 0);
    CHECK(write(p[1], "through", 7) == 7);
    static const uint8_t bytes[5] = {1, 2, 3, 4, 5};

    mwm_put_begin(a, 7, 3);
    mwm_put_uint(a, 42);
    mwm_put_int(a, -5);
    mwm_put_string(a, "h\xc3\xa9llo");
    mwm_put_array(a, bytes, sizeof bytes);
    mwm_put_fd(a, p[0]);
    mwm_put_string(a, NULL);
    mwm_put_string(a, "");
    mwm_put_end(a);
    CHECK(mwm_conn_flush(a) == 1);
    CHECK(!mwm_conn_wants_write(a));
    close(p[0]); /* the receiver has its own */

    CHECK(mwm_conn_read(b) == 1);
    mwm_msg m;
    CHECK(mwm_conn_next(b, &m));
    CHECK(m.object == 7 && m.opcode == 3);
    CHECK(m.size == 8 + 4 + 4 + (4 + 8) + (4 + 8) + 4 + (4 + 4));
    CHECK(mwm_get_uint(&m) == 42);
    CHECK(mwm_get_int(&m) == -5);
    uint32_t len = 99;
    const char *s = mwm_get_string(&m, &len);
    CHECK(s && strcmp(s, "h\xc3\xa9llo") == 0 && len == 6);
    const uint8_t *arr = mwm_get_array(&m, &len);
    CHECK(arr && len == 5 && memcmp(arr, bytes, 5) == 0);
    int fd = mwm_get_fd(&m);
    CHECK(fd >= 0);
    char got[8] = {0};
    CHECK(read(fd, got, 7) == 7 && memcmp(got, "through", 7) == 0);
    close(fd);
    CHECK(mwm_get_string(&m, &len) == NULL && !m.bad && len == 0); /* a null string is not a bad one */
    s = mwm_get_string(&m, &len);
    CHECK(s && s[0] == 0 && len == 0);
    CHECK(mwm_msg_done(&m));
    CHECK(!mwm_conn_next(b, &m));
    CHECK(mwm_conn_read(b) == 0); /* nothing more, and still there */
    close(p[1]);
    mwm_conn_free(a);
    CHECK(mwm_conn_read(b) == -1); /* the other end is gone */
    mwm_conn_free(b);
}

/* Messages come as the socket gives them: two at once, one in two parts. */
static void test_messages_are_whole(void) {
    mwm_conn *b;
    int raw[2];
    pair(NULL, &b, raw);
    uint32_t two[] = {1, (12u << 16) | 4, 0xaabbccdd, 2, (8u << 16) | 9};
    CHECK(write(raw[0], two, sizeof two) == (ssize_t)sizeof two);
    CHECK(mwm_conn_read(b) == 1);
    mwm_msg m;
    CHECK(mwm_conn_next(b, &m) && m.object == 1 && m.opcode == 4 && mwm_get_uint(&m) == 0xaabbccdd && mwm_msg_done(&m));
    CHECK(mwm_conn_next(b, &m) && m.object == 2 && m.opcode == 9 && m.size == 8 && mwm_msg_done(&m));
    CHECK(!mwm_conn_next(b, &m));

    uint32_t one[] = {3, (16u << 16) | 1, 10, 20};
    CHECK(write(raw[0], one, 6) == 6);
    CHECK(mwm_conn_read(b) == 1);
    CHECK(!mwm_conn_next(b, &m)); /* not even a header yet */
    CHECK(write(raw[0], (const uint8_t *)one + 6, 6) == 6);
    CHECK(mwm_conn_read(b) == 1);
    CHECK(!mwm_conn_next(b, &m)); /* a header, not its arguments */
    CHECK(write(raw[0], (const uint8_t *)one + 12, 4) == 4);
    CHECK(mwm_conn_read(b) == 1);
    CHECK(mwm_conn_next(b, &m) && m.object == 3 && mwm_get_uint(&m) == 10 && mwm_get_uint(&m) == 20 && mwm_msg_done(&m));
    CHECK(!mwm_conn_failed(b));
    close(raw[0]);
    mwm_conn_free(b);
}

static mwm_conn *fed(const void *bytes, size_t n, int *writer) {
    mwm_conn *b;
    int raw[2];
    pair(NULL, &b, raw);
    CHECK(write(raw[0], bytes, n) == (ssize_t)n);
    CHECK(mwm_conn_read(b) == 1);
    *writer = raw[0];
    return b;
}

/* A header that cannot be one drops the client. */
static void test_a_bad_header_drops_the_client(void) {
    uint32_t cases[][2] = {
        {1, (4u << 16) | 0},    /* shorter than its header */
        {1, (10u << 16) | 0},   /* not whole words */
        {1, (4100u << 16) | 0}, /* longer than a message may be */
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        int w;
        mwm_conn *b = fed(cases[i], sizeof cases[i], &w);
        mwm_msg m;
        CHECK(!mwm_conn_next(b, &m));
        CHECK(mwm_conn_failed(b));
        CHECK(mwm_conn_read(b) == -1);
        close(w);
        mwm_conn_free(b);
    }
}

/* Arguments that do not fit their message read as nothing, and say so. */
static void test_arguments_stay_inside_their_message(void) {
    mwm_msg m;
    int w;
    uint32_t len;

    uint32_t past[] = {1, (12u << 16) | 0, 5};
    mwm_conn *b = fed(past, sizeof past, &w);
    CHECK(mwm_conn_next(b, &m));
    CHECK(mwm_get_uint(&m) == 5 && !m.bad);
    CHECK(mwm_get_uint(&m) == 0 && m.bad); /* past the end */
    CHECK(!mwm_msg_done(&m));
    close(w);
    mwm_conn_free(b);

    uint32_t longstr[] = {1, (16u << 16) | 0, 100, 0x41414141}; /* a string said to be 100 bytes in a 16-byte message */
    b = fed(longstr, sizeof longstr, &w);
    CHECK(mwm_conn_next(b, &m));
    CHECK(mwm_get_string(&m, &len) == NULL && m.bad);
    close(w);
    mwm_conn_free(b);

    uint32_t unterminated[] = {1, (16u << 16) | 0, 4, 0x41414141}; /* 4 bytes, none of them NUL */
    b = fed(unterminated, sizeof unterminated, &w);
    CHECK(mwm_conn_next(b, &m));
    CHECK(mwm_get_string(&m, &len) == NULL && m.bad);
    close(w);
    mwm_conn_free(b);

    uint32_t wrap[] = {1, (16u << 16) | 0, 0xfffffffd, 0}; /* a length that wraps when padded */
    b = fed(wrap, sizeof wrap, &w);
    CHECK(mwm_conn_next(b, &m));
    CHECK(mwm_get_array(&m, &len) == NULL && m.bad && len == 0);
    close(w);
    mwm_conn_free(b);

    uint32_t leftover[] = {1, (16u << 16) | 0, 1, 2};
    b = fed(leftover, sizeof leftover, &w);
    CHECK(mwm_conn_next(b, &m));
    CHECK(mwm_get_uint(&m) == 1);
    CHECK(!mwm_msg_done(&m)); /* more than its arguments */
    CHECK(mwm_get_fd(&m) == -1 && m.bad); /* a descriptor that was never sent */
    close(w);
    mwm_conn_free(b);
}

/* A client cannot pile up descriptors, nor leave them behind. */
static void test_descriptors_are_bounded(void) {
    mwm_conn *a, *b;
    pair(&a, &b, NULL);
    int p[2];
    CHECK(pipe(p) == 0);
    for (int i = 0; i < MWM_MAX_FDS + 8 && !mwm_conn_failed(b); i++) {
        mwm_put_begin(a, 1, 0);
        mwm_put_fd(a, p[0]);
        mwm_put_end(a);
        CHECK(mwm_conn_flush(a) == 1);
        (void)mwm_conn_read(b); /* never taken out of the connection */
    }
    CHECK(mwm_conn_failed(b));
    mwm_conn_free(b); /* closes the ones it held: checked below */
    mwm_conn_free(a);
    close(p[0]);
    /* Every copy of the read end is closed: a write now fails. */
    signal(SIGPIPE, SIG_IGN);
    CHECK(write(p[1], "x", 1) == -1 && errno == EPIPE);
    close(p[1]);
}

/* What waits for a client that never reads is bounded: it is dropped. */
static void test_a_client_that_does_not_read_is_dropped(void) {
    mwm_conn *a, *b;
    pair(&a, &b, NULL);
    static const uint8_t block[2048];
    int sent = 0;
    while (!mwm_conn_failed(a) && sent < 100000) {
        mwm_put_begin(a, 1, 0);
        mwm_put_array(a, block, sizeof block);
        mwm_put_end(a);
        (void)mwm_conn_flush(a);
        sent++;
    }
    CHECK(mwm_conn_failed(a));
    CHECK(sent < 2000); /* about the socket's buffer and MWM_MAX_OUT, not forever */
    CHECK(mwm_conn_flush(a) == -1);
    mwm_conn_free(a);
    mwm_conn_free(b);
}

/* A message that would be longer than Wayland allows is not sent in part. */
static void test_a_message_too_long_fails_the_writer(void) {
    mwm_conn *a, *b;
    pair(&a, &b, NULL);
    static const uint8_t big[5000];
    mwm_put_begin(a, 1, 0);
    mwm_put_array(a, big, sizeof big);
    mwm_put_end(a);
    CHECK(mwm_conn_failed(a));
    mwm_conn_free(a);
    CHECK(mwm_conn_read(b) == -1); /* nothing of it came */
    mwm_conn_free(b);
}

int main(void) {
    test_a_message_crosses();
    test_messages_are_whole();
    test_a_bad_header_drops_the_client();
    test_arguments_stay_inside_their_message();
    test_descriptors_are_bounded();
    test_a_client_that_does_not_read_is_dropped();
    test_a_message_too_long_fails_the_writer();
    printf("test_wm_wire: %d checks passed\n", checks);
    return 0;
}
