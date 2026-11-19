/*
 * test_wm_gl.c — the window manager's part in drawing by the Mac's GPU
 * (GuestWM/mwm_gl, mwm_gl_wire.h): it hands a program's drawing commands
 * on to MonadHost and MonadHost's answers back, each program's as a
 * stream of its own, holding neither side up nor growing without bound;
 * and it tells the Mac which window shows what a stream draws.
 */
#include "wm_test_client.h"

#include "mwm_ctl.h"
#include "mwm_gl.h"
#include "mwm_gl_wire.h"

#include <errno.h>

/* The other end of a socket the relay holds: what it read and has not looked at. */
typedef struct {
    int fd;
    uint8_t *bytes;
    size_t len, cap;
} end;

static end pair(int *taken) {
    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    CHECK(fcntl(sv[0], F_SETFL, O_NONBLOCK) == 0);
    *taken = sv[1];
    return (end){.fd = sv[0]};
}

/* Whether the relay hung up on that end (what it had sent before is read past). */
static bool hung_up(int fd) {
    char bytes[64];
    ssize_t n;
    while ((n = read(fd, bytes, sizeof bytes)) > 0) {}
    return n == 0;
}

/* Everything the relay has to do right now is done, and what came out of it is read. */
static void turn(mwm_gl *g, end **ends, int count) {
    for (int round = 0; round < 4; round++) {
        int fds[MWM_GL_SOCKETS];
        bool reads[MWM_GL_SOCKETS], writes[MWM_GL_SOCKETS];
        int n = mwm_gl_sockets(g, fds, reads, writes, MWM_GL_SOCKETS);
        for (int i = 0; i < n; i++) mwm_gl_service(g, fds[i], reads[i], writes[i]);
        for (int i = 0; i < count; i++) {
            end *e = ends[i];
            for (;;) {
                if (e->cap - e->len < 65536) {
                    e->cap = e->cap ? e->cap * 2 : 1 << 17;
                    e->bytes = realloc(e->bytes, e->cap);
                    CHECK(e->bytes);
                }
                ssize_t got = read(e->fd, e->bytes + e->len, e->cap - e->len);
                if (got <= 0) break;
                e->len += (size_t)got;
            }
        }
    }
}

static uint32_t word_at(const end *e, size_t at) {
    uint32_t v;
    CHECK(at + 4 <= e->len);
    memcpy(&v, e->bytes + at, 4);
    return v;
}

static void drop_front(end *e, size_t n) {
    CHECK(n <= e->len);
    memmove(e->bytes, e->bytes + n, e->len - n);
    e->len -= n;
}

/* The next frame MonadHost got: its stream, and its bytes left at the front of `payload`. */
static uint32_t frame(end *host, uint8_t *payload, uint32_t *len) {
    uint32_t stream = word_at(host, 0);
    *len = word_at(host, 4);
    CHECK(*len <= MWM_GL_FRAME && host->len >= 8 + (size_t)*len);
    memcpy(payload, host->bytes + 8, *len);
    drop_front(host, 8 + (size_t)*len);
    return stream;
}

static void say_frame(end *host, uint32_t stream, const void *bytes, uint32_t len) {
    uint32_t head[2] = {stream, len};
    CHECK(write(host->fd, head, 8) == 8);
    if (len) CHECK(write(host->fd, bytes, len) == (ssize_t)len);
}

/* A program's commands reach MonadHost as its stream's, and MonadHost's
 * answers reach the program they are for. */
static void test_each_programs_commands_are_a_stream_of_their_own(void) {
    static uint8_t payload[MWM_GL_FRAME];
    uint32_t len;
    mwm_gl *g = mwm_gl_new();
    CHECK(g && !mwm_gl_attached(g));
    int fd;
    end stray = pair(&fd);
    CHECK(!mwm_gl_add(g, fd)); /* nobody to draw: the program is turned away */
    char byte;
    CHECK(read(stray.fd, &byte, 1) == 0);
    close(stray.fd);

    end host = pair(&fd);
    mwm_gl_attach(g, fd);
    CHECK(mwm_gl_attached(g));
    end one = pair(&fd);
    CHECK(mwm_gl_add(g, fd));
    end two = pair(&fd);
    CHECK(mwm_gl_add(g, fd));
    end *all[] = {&host, &one, &two};
    turn(g, all, 3);
    /* Each is told its stream; MonadHost is told of each. */
    CHECK(one.len == 8 && word_at(&one, 0) == MWM_GL_MAGIC && word_at(&one, 4) == 1);
    CHECK(two.len == 8 && word_at(&two, 0) == MWM_GL_MAGIC && word_at(&two, 4) == 2);
    drop_front(&one, 8);
    drop_front(&two, 8);
    CHECK(frame(&host, payload, &len) == 0 && len == 8 && memcmp(payload, (uint32_t[]){MWM_GL_OPENED, 1}, 8) == 0);
    CHECK(frame(&host, payload, &len) == 0 && len == 8 && memcmp(payload, (uint32_t[]){MWM_GL_OPENED, 2}, 8) == 0);
    CHECK(host.len == 0);

    CHECK(write(two.fd, "second", 6) == 6);
    CHECK(write(one.fd, "first!!", 7) == 7);
    turn(g, all, 3);
    bool got_one = false, got_two = false;
    while (host.len > 0) {
        uint32_t stream = frame(&host, payload, &len);
        if (stream == 1) got_one = len == 7 && memcmp(payload, "first!!", 7) == 0;
        if (stream == 2) got_two = len == 6 && memcmp(payload, "second", 6) == 0;
    }
    CHECK(got_one && got_two);

    /* Answers: to the stream they name, in pieces as they come; one for a stream there is none of goes nowhere. */
    say_frame(&host, 2, "for two", 7);
    say_frame(&host, 9, "nobody's", 8);
    uint32_t head[2] = {1, 6};
    CHECK(write(host.fd, head, 8) == 8 && write(host.fd, "for", 3) == 3);
    turn(g, all, 3);
    CHECK(two.len == 7 && memcmp(two.bytes, "for two", 7) == 0 && one.len == 3);
    CHECK(write(host.fd, " 1!", 3) == 3);
    turn(g, all, 3);
    CHECK(one.len == 6 && memcmp(one.bytes, "for 1!", 6) == 0 && mwm_gl_attached(g));

    /* MonadHost ends a stream (its program said what cannot be gone on from): that program is hung up on, and
     * MonadHost hears no more of it. A word of that kind that is cut short, or of no kind, does nothing. */
    end three = pair(&fd);
    CHECK(mwm_gl_add(g, fd));
    end *with_three[] = {&host, &one, &two, &three};
    turn(g, with_three, 4);
    host.len = 0;
    say_frame(&host, 0, (uint32_t[]){MWM_GL_CLOSED, 3}, 8);
    say_frame(&host, 0, (uint32_t[]){MWM_GL_OPENED, 1}, 8);
    say_frame(&host, 0, (uint32_t[]){MWM_GL_CLOSED}, 4);
    turn(g, with_three, 4);
    CHECK(hung_up(three.fd) && host.len == 0 && mwm_gl_attached(g));
    close(three.fd);
    free(three.bytes);
    CHECK(write(one.fd, "x", 1) == 1);
    turn(g, all, 3);
    CHECK(frame(&host, payload, &len) == 1 && len == 1);

    /* A program ends: MonadHost is told, and the other goes on. */
    close(one.fd);
    end *rest[] = {&host, &two};
    turn(g, rest, 2);
    CHECK(frame(&host, payload, &len) == 0 && len == 8 && memcmp(payload, (uint32_t[]){MWM_GL_CLOSED, 1}, 8) == 0);
    CHECK(write(two.fd, "on", 2) == 2);
    turn(g, rest, 2);
    CHECK(frame(&host, payload, &len) == 2 && len == 2);

    /* MonadHost goes: so does every program's stream, and no new one is taken. */
    close(host.fd);
    end *left[] = {&two};
    turn(g, left, 1);
    CHECK(!mwm_gl_attached(g));
    CHECK(hung_up(two.fd));
    close(two.fd);
    end late = pair(&fd);
    CHECK(!mwm_gl_add(g, fd));
    close(late.fd);
    free(host.bytes);
    free(one.bytes);
    free(two.bytes);
    mwm_gl_free(g);
}

/* Megabytes each way through sockets that take a little at a time: all
 * of it arrives, in order, and the relay holds a bounded amount while a
 * side is slow. */
static void test_much_goes_through_whole_and_in_order(void) {
    enum { MUCH = 9 << 20 };
    static uint8_t payload[MWM_GL_FRAME];
    mwm_gl *g = mwm_gl_new();
    int fd;
    end host = pair(&fd);
    mwm_gl_attach(g, fd);
    end program = pair(&fd);
    CHECK(mwm_gl_add(g, fd));
    end *all[] = {&host, &program};
    turn(g, all, 2);
    drop_front(&program, 8);
    host.len = 0;

    /* The program writes more than the relay may hold: the relay stops taking it while MonadHost does not read. */
    uint8_t *sent = malloc(MUCH);
    CHECK(sent);
    for (size_t i = 0; i < MUCH; i++) sent[i] = (uint8_t)(i * 31 + (i >> 11));
    size_t written = 0, arrived = 0;
    end *nobody[1] = {&program};
    for (int round = 0; round < 400; round++) {
        ssize_t n = write(program.fd, sent + written, MUCH - written);
        if (n > 0) written += (size_t)n;
        turn(g, nobody, 0); /* MonadHost does not read */
    }
    CHECK(written < MUCH); /* the program is held up, not the relay grown */
    while (arrived < MUCH) {
        if (written < MUCH) {
            ssize_t n = write(program.fd, sent + written, MUCH - written);
            if (n > 0) written += (size_t)n;
        }
        turn(g, all, 2);
        while (host.len >= 8 && host.len >= 8 + (size_t)word_at(&host, 4)) {
            uint32_t len, stream = frame(&host, payload, &len);
            CHECK(stream == 1 && arrived + len <= MUCH && memcmp(payload, sent + arrived, len) == 0);
            arrived += len;
        }
    }

    /* And back: an answer of megabytes, to a program that reads slowly. */
    written = 0;
    size_t framed = 0;
    program.len = 0;
    while (program.len < MUCH) {
        if (written == framed && framed < MUCH) { /* the next frame's head */
            uint32_t piece = MUCH - framed < MWM_GL_FRAME ? (uint32_t)(MUCH - framed) : MWM_GL_FRAME, head[2] = {1, piece};
            ssize_t n = write(host.fd, head, 8);
            if (n == 8) framed += piece;
            else CHECK(n < 0 && errno == EAGAIN);
        }
        if (written < framed) {
            ssize_t n = write(host.fd, sent + written, framed - written);
            if (n > 0) written += (size_t)n;
        }
        turn(g, all, 2);
    }
    CHECK(program.len == MUCH && memcmp(program.bytes, sent, MUCH) == 0 && mwm_gl_attached(g));
    free(sent);
    free(host.bytes);
    free(program.bytes);
    close(host.fd);
    close(program.fd);
    mwm_gl_free(g);
}

/* What makes no sense from MonadHost's side ends its connection; more
 * programs than there may be are turned away. */
static void test_nonsense_and_too_many(void) {
    mwm_gl *g = mwm_gl_new();
    int fd;
    end host = pair(&fd);
    mwm_gl_attach(g, fd);
    end programs[MWM_GL_STREAMS + 1];
    for (int i = 0; i < MWM_GL_STREAMS; i++) {
        programs[i] = pair(&fd);
        CHECK(mwm_gl_add(g, fd));
    }
    programs[MWM_GL_STREAMS] = pair(&fd);
    CHECK(!mwm_gl_add(g, fd));
    end *all[] = {&host};
    turn(g, all, 1);
    uint32_t head[2] = {1, MWM_GL_FRAME + 1}; /* a frame longer than any */
    CHECK(write(host.fd, head, 8) == 8);
    turn(g, all, 1);
    CHECK(!mwm_gl_attached(g));
    CHECK(hung_up(programs[0].fd) && hung_up(programs[MWM_GL_STREAMS - 1].fd));
    /* A second MonadHost takes the first one's place. */
    end other = pair(&fd);
    mwm_gl_attach(g, fd);
    end third = pair(&fd);
    mwm_gl_attach(g, fd);
    CHECK(mwm_gl_attached(g) && hung_up(other.fd));
    for (int i = 0; i <= MWM_GL_STREAMS; i++) close(programs[i].fd);
    close(host.fd);
    close(other.fd);
    close(third.fd);
    free(host.bytes);
    mwm_gl_free(g);
}

/* A window whose program draws through the Mac's GPU: the buffer it
 * commits has no pixels and names the stream and the surface that are
 * drawn; the window is that buffer's size, and the Mac is told with it. */
static void test_a_window_says_what_draws_it(void) {
    mwm_server *s = server();
    mwm_ctl *c = mwm_ctl_new(s);
    client a = connect_client(s);
    uint32_t gl = bind_global(&a, "monad_gl", 1);
    window v = {.surface = a.next++, .xdg = a.next++, .toplevel = a.next++, .buffer = a.next++};
    request(&a, a.compositor, 0, 1, v.surface);
    request(&a, a.wm, 2, 2, v.xdg, v.surface);
    request(&a, v.xdg, 1, 1, v.toplevel);
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    mwm_msg m = event(&a);
    m = event(&a);
    uint32_t serial = mwm_get_uint(&m);
    request(&a, v.xdg, 4, 1, serial);
    request(&a, gl, 1, 5, v.buffer, 7, 3, 120, 80); /* create_buffer: stream 7, its surface 3 */
    request(&a, v.surface, 1, 3, v.buffer, 0, 0);
    request(&a, v.surface, 2, 4, 0, 0, 120, 80);
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    while (mwm_conn_next(a.c, &m)) CHECK(m.object != 1 || m.opcode != DISPLAY_ERROR);
    mwm_window w;
    CHECK(mwm_server_windows(s, &w, 1) == 1 && w.width == 120 && w.height == 80 && w.gl_stream == 7 && w.gl_surface == 3);
    CHECK(!w.own_bar); /* its frame is the Mac's */
    /* Nothing of it is on the sheet, and no pixels are handed out: the Mac draws it. */
    mwm_drawn d;
    CHECK(at(w.x, w.y) == 0 && at(w.x + 119, w.y + 79) == 0 && !mwm_server_take_drawn(s, w.id, W * H, &d));

    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0 && fcntl(sv[0], F_SETFL, O_NONBLOCK) == 0);
    mwm_ctl_attach(c, sv[1]);
    char text[2048], expected[200];
    ssize_t n = read(sv[0], text, sizeof text - 1);
    CHECK(n > 0);
    text[n] = 0;
    snprintf(expected, sizeof expected, "window %u 0 0 120 80 1 0 0 120 80 0 0 0 - - -\ngl %u 7 3\nend\n", w.id, w.id);
    CHECK(strstr(text, expected) != NULL && strstr(text, "pixels") == NULL);

    /* The program draws another size: a new buffer, and the window follows. */
    uint32_t generation = mwm_server_generation(s), larger = a.next++;
    request(&a, gl, 1, 5, larger, 7, 3, 200, 100);
    request(&a, v.surface, 1, 3, larger, 0, 0);
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(mwm_server_windows(s, &w, 1) == 1 && w.width == 200 && w.height == 100 && w.gl_stream == 7);
    CHECK(mwm_server_generation(s) != generation);
    /* It goes back to drawing pixels itself: an ordinary window again. */
    uint32_t pool = a.next++, plain = a.next++;
    make_buffer(&a, pool, plain, 0x00445566, 64, 32);
    show_buffer(s, &a, v.surface, plain, 64, 32);
    CHECK(mwm_server_windows(s, &w, 1) == 1 && w.width == 64 && w.gl_stream == 0 && w.gl_surface == 0);
    CHECK(at(w.x, w.y) == 0xff445566u && mwm_server_take_drawn(s, w.id, W * H, &d));
    while (mwm_conn_next(a.c, &m)) CHECK(m.object != 1 || m.opcode != DISPLAY_ERROR);

    /* Sizes no window has, and requests there are none of, drop the program. */
    request(&a, gl, 1, 5, a.next++, 7, 3, 0, 80);
    uint32_t object;
    CHECK(dropped_with(s, &a, &object) >= 0);
    a = connect_client(s);
    gl = bind_global(&a, "monad_gl", 1);
    request(&a, gl, 1, 5, a.next++, 1, 1, MWM_MAX_SIDE + 1, 10);
    CHECK(dropped_with(s, &a, &object) >= 0);
    a = connect_client(s);
    gl = bind_global(&a, "monad_gl", 1);
    request(&a, gl, 2, 0);
    CHECK(dropped_with(s, &a, &object) == ERROR_INVALID_METHOD);
    close(sv[0]);
    mwm_ctl_free(c);
    mwm_server_free(s);
}

int main(void) {
    test_each_programs_commands_are_a_stream_of_their_own();
    test_much_goes_through_whole_and_in_order();
    test_nonsense_and_too_many();
    test_a_window_says_what_draws_it();
    printf("test_wm_gl: %d checks passed\n", checks);
    return 0;
}
