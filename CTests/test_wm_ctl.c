/*
 * test_wm_ctl.c — the window manager's channel to MonadHost (GuestWM/
 * mwm_ctl): the windows are told as lines MonadHost can read as hostile
 * text, and the lines MonadHost sends move the pointer, press keys and
 * close windows; lines that make no sense do nothing.
 */
#include "wm_test_client.h"

#include "mnd_pixels.h"
#include "mwm_ctl.h"

#include <errno.h>
#include <signal.h>

/* MonadHost's end of the channel, and what it read and has not looked at. */
typedef struct {
    int fd;
    char text[64 << 10];
    size_t len;
    /* The pixels it was sent: how many times (and how many of those packed), and the last: whose, where in the
     * window, and the pixels. */
    int chunks, packed;
    uint32_t window;
    int px, py, pw, ph;
    uint32_t data[W * H];
    /* The windows as it was last told them, for what pixels may be sent of. */
    struct {
        uint32_t id;
        int width, height;
    } told[MWM_MAX_WINDOWS];
    int told_count;
} host;

static host attach(mwm_ctl *c) {
    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    CHECK(fcntl(sv[0], F_SETFL, O_NONBLOCK) == 0);
    mwm_ctl_attach(c, sv[1]);
    CHECK(mwm_ctl_fd(c) == sv[1]);
    return (host){.fd = sv[0]};
}

static void say(mwm_ctl *c, host *h, const char *lines) {
    CHECK(write(h->fd, lines, strlen(lines)) == (ssize_t)strlen(lines));
    mwm_ctl_service(c, true, true, 1000);
}

/* What the window manager has to say is sent as far as it goes, and read. */
static void take(mwm_ctl *c, host *h) {
    if (mwm_ctl_fd(c) >= 0) mwm_ctl_service(c, false, true, 1000);
    for (;;) {
        ssize_t n = read(h->fd, h->text + h->len, sizeof h->text - h->len);
        if (n <= 0) break;
        h->len += (size_t)n;
    }
}

/* The next line MonadHost got, without its newline; NULL when there is
 * none. A window's pixels are taken on the way (the last ones are kept in
 * `h`): never of a window it was not told, or beyond that window's size. */
static const char *line(mwm_ctl *c, host *h) {
    static char out[MWM_CTL_LINE + 1];
    for (;;) {
        take(c, h);
        char *end = memchr(h->text, '\n', h->len);
        if (!end) return NULL;
        size_t n = (size_t)(end - h->text);
        CHECK(n < MWM_CTL_LINE); /* never a longer line than it may send */
        memcpy(out, h->text, n);
        out[n] = 0;
        memmove(h->text, end + 1, h->len - n - 1);
        h->len -= n + 1;
        uint32_t id;
        int x, y, w, v;
        size_t sent;
        if (strncmp(out, "windows ", 8) == 0) h->told_count = 0;
        if (sscanf(out, "window %u %*d %*d %d %d ", &id, &w, &v) == 3) {
            h->told[h->told_count].id = id;
            h->told[h->told_count].width = w;
            h->told[h->told_count++].height = v;
        }
        if (strncmp(out, "pixels ", 7) != 0) return out;
        CHECK(sscanf(out, "pixels %u %d %d %d %d %zu", &id, &x, &y, &w, &v, &sent) == 6 && w > 0 && v > 0 && x >= 0 && y >= 0);
        bool fits = false;
        for (int i = 0; i < h->told_count; i++)
            if (h->told[i].id == id) fits = x + w <= h->told[i].width && y + v <= h->told[i].height;
        CHECK(fits);
        /* As many bytes as it says: the pixels as they are, or fewer, packed (mwm_pack.h). */
        size_t bytes = (size_t)w * (size_t)v * 4;
        CHECK(bytes <= sizeof h->data && sent >= 4 && sent <= bytes && sent <= sizeof h->text);
        for (int tries = 0; h->len < sent; tries++) { /* as fast as the socket takes them */
            CHECK(tries < 1000);
            take(c, h);
        }
        if (sent == bytes) memcpy(h->data, h->text, bytes);
        else CHECK(mnd_pixels_unpack((const uint8_t *)h->text, sent, (uint8_t *)h->data, (size_t)w * 4, w, v));
        h->packed += sent < bytes;
        memmove(h->text, h->text + sent, h->len - sent);
        h->len -= sent;
        h->chunks++;
        h->window = id;
        h->px = x;
        h->py = y;
        h->pw = w;
        h->ph = v;
    }
}

static bool line_is(mwm_ctl *c, host *h, const char *expected) {
    const char *got = line(c, h);
    if (got && strcmp(got, expected) == 0) return true;
    fprintf(stderr, "expected \"%s\", got \"%s\"\n", expected, got ? got : "(nothing)");
    return false;
}

/* MonadHost is told the sheet's size, then the windows whenever they change. */
static void test_the_windows_are_told(void) {
    mwm_server *s = server();
    mwm_ctl *c = mwm_ctl_new(s);
    CHECK(c && mwm_ctl_fd(c) == -1);
    mwm_ctl_update(c); /* with nobody connected, nothing is said and nothing is lost */
    client a = connect_client(s);
    window one = open_window(s, &a, "One", "app.one", 0x00110000, 64, 32);

    host h = attach(c);
    char expected[200];
    CHECK(line_is(c, &h, "monad-wm 1 400 200"));
    snprintf(expected, sizeof expected, "windows %u 1", mwm_server_generation(s));
    CHECK(line_is(c, &h, expected));
    /* A program that said nothing of its frame draws its own bar: the colour at its top is told with it. */
    snprintf(expected, sizeof expected, "window %u 0 0 64 32 1 0 0 64 32 0 0 0 1100a0 app.one One", one.id);
    CHECK(line_is(c, &h, expected));
    CHECK(line_is(c, &h, "end"));
    CHECK(line(c, &h) == NULL);
    mwm_ctl_update(c); /* nothing changed: nothing is said */
    CHECK(line(c, &h) == NULL);

    /* A second window, whose texts would break a line read carelessly. */
    client b = connect_client(s);
    window two = open_window(s, &b, "50% of\ttwo\nwindow 9 0 0 1 1 x y", "", 0x00220000, 100, 50);
    mwm_ctl_update(c);
    snprintf(expected, sizeof expected, "windows %u 2", mwm_server_generation(s));
    CHECK(line_is(c, &h, expected));
    snprintf(expected, sizeof expected, "window %u 0 0 64 32 1 0 0 64 32 0 0 0 1100a0 app.one One", one.id);
    CHECK(line_is(c, &h, expected));
    snprintf(expected, sizeof expected,
             "window %u %d 0 100 50 1 0 0 100 50 0 0 0 2200fa - 50%%25%%20of%%09two%%0Awindow%%209%%200%%200%%201%%201%%20x%%20y", two.id,
             64 + MWM_GAP);
    CHECK(line_is(c, &h, expected));
    CHECK(line_is(c, &h, "end"));

    /* Bytes that are no text at all, and a title as long as one may be. */
    mwm_put_begin(a.c, one.toplevel, 2); /* set_title */
    mwm_put_string(a.c, "caf\xc3\xa9 \xff\x01");
    mwm_put_end(a.c);
    pump(s, &a);
    mwm_ctl_update(c);
    CHECK(line(c, &h) != NULL);
    snprintf(expected, sizeof expected, "window %u 0 0 64 32 1 0 0 64 32 0 0 0 1100a0 app.one caf%%C3%%A9%%20%%FF%%01", one.id);
    CHECK(line_is(c, &h, expected));
    CHECK(line(c, &h) != NULL && line_is(c, &h, "end"));
    char longest[200];
    memset(longest, ' ', sizeof longest);
    longest[sizeof longest - 1] = 0;
    mwm_put_begin(a.c, one.toplevel, 2);
    mwm_put_string(a.c, longest);
    mwm_put_end(a.c);
    pump(s, &a);
    mwm_ctl_update(c);
    CHECK(line(c, &h) != NULL);
    const char *got = line(c, &h);
    CHECK(got && strlen(got) < MWM_CTL_LINE && strstr(got, "%20%20%20"));
    CHECK(line(c, &h) != NULL && line_is(c, &h, "end"));

    /* The first program ends. */
    mwm_conn_free(a.c);
    mwm_server_service(s, a.server_fd, true, false);
    mwm_ctl_update(c);
    snprintf(expected, sizeof expected, "windows %u 1", mwm_server_generation(s));
    CHECK(line_is(c, &h, expected));
    CHECK(line(c, &h) != NULL && line_is(c, &h, "end"));

    close(h.fd);
    mwm_conn_free(b.c);
    mwm_ctl_free(c);
    mwm_server_free(s);
}

/* MonadHost is sent what each window shows, in the pixels the program
 * drew: all of a window once, then what the program draws again, and
 * what waited while MonadHost was slow as one piece, the newest. */
static void test_a_windows_pixels_are_sent(void) {
    mwm_server *s = server();
    mwm_ctl *c = mwm_ctl_new(s);
    client a = connect_client(s);
    window one = open_window(s, &a, "One", "app.one", 0x00110000, 16, 8);
    static host h;
    h = attach(c);
    while (line(c, &h)) {}
    CHECK(h.chunks == 1 && h.window == one.id && h.px == 0 && h.py == 0 && h.pw == 16 && h.ph == 8);
    CHECK(h.data[0] == 0xff110000u && h.data[17] == 0xff110011u && h.data[16 * 8 - 1] == 0xff11007fu);
    mwm_ctl_update(c); /* nothing was drawn: nothing is sent */
    CHECK(line(c, &h) == NULL && h.chunks == 1);

    /* A part drawn again: that part. What the program left see-through comes as it is. */
    uint32_t drawing[16 * 8];
    for (int i = 0; i < 16 * 8; i++) drawing[i] = 0xffa0b0c0u;
    drawing[2 * 16 + 4] = 0x00000000u;
    drawing[2 * 16 + 5] = 0x80102030u;
    uint32_t pool = a.next++, buffer = a.next++;
    make_drawn(&a, pool, buffer, drawing, 16, 8);
    request(&a, one.surface, 1, 3, buffer, 0, 0);
    request(&a, one.surface, 9, 4, 4, 2, 3, 1); /* damage_buffer */
    request(&a, one.surface, 6, 0);
    pump(s, &a);
    mwm_ctl_update(c);
    CHECK(line(c, &h) == NULL && h.chunks == 2 && h.window == one.id && h.px == 4 && h.py == 2 && h.pw == 3 && h.ph == 1);
    CHECK(h.data[0] == 0x00000000u && h.data[1] == 0x80102030u && h.data[2] == 0xffa0b0c0u);

    /* A second window, larger than the socket takes at once: its pixels come whole all the same, after its line. */
    client b = connect_client(s);
    window two = open_window(s, &b, "Two", "app.two", 0x00220000, 100, 50);
    mwm_ctl_update(c);
    while (line(c, &h)) {}
    CHECK(h.chunks == 3 && h.window == two.id && h.px == 0 && h.py == 0 && h.pw == 100 && h.ph == 50);
    CHECK(h.data[0] == 0xff220000u && h.data[100 * 50 - 1] == (0xff220000u | ((100 * 50 - 1) & 0xff)));

    /* MonadHost does not read while the program draws three times: it is
     * sent what it had not taken yet, and then the newest once, not each. */
    uint32_t colors[3] = {0x00330000, 0x00440000, 0x00550000};
    for (int i = 0; i < 3; i++) {
        uint32_t p = b.next++, v = b.next++;
        make_buffer(&b, p, v, colors[i], 100, 50);
        request(&b, two.surface, 1, 3, v, 0, 0);
        request(&b, two.surface, 2, 4, 0, 0, 100, 50);
        request(&b, two.surface, 6, 0);
        pump(s, &b);
        mwm_ctl_update(c);
    }
    while (line(c, &h)) {}
    CHECK(h.chunks >= 4 && h.chunks <= 5 && h.window == two.id && h.pw == 100 && h.ph == 50 && h.data[0] == 0xff550000u);
    CHECK(mwm_ctl_fd(c) >= 0); /* pixels that wait are no reason to hang up */

    /* Each window's pixels in turn, when two draw. */
    int before = h.chunks;
    request(&a, one.surface, 9, 4, 0, 0, 1, 1);
    request(&a, one.surface, 6, 0);
    request(&b, two.surface, 2, 4, 0, 0, 1, 1);
    request(&b, two.surface, 6, 0);
    pump(s, &a);
    pump(s, &b);
    mwm_ctl_update(c);
    CHECK(line(c, &h) == NULL && h.chunks == before + 2);

    /* A window that changes size: its line first, then all of it. */
    uint32_t pool3 = a.next++, larger = a.next++;
    make_buffer(&a, pool3, larger, 0x00660000, 20, 10);
    request(&a, one.surface, 1, 3, larger, 0, 0);
    request(&a, one.surface, 9, 4, 0, 0, 1, 1); /* says less than changed */
    request(&a, one.surface, 6, 0);
    pump(s, &a);
    mwm_ctl_update(c);
    while (line(c, &h)) {} /* line() checks that the pixels fit the window as it was told */
    CHECK(h.window == one.id && h.px == 0 && h.py == 0 && h.pw == 20 && h.ph == 10 && h.data[0] == 0xff660000u);

    /* What is flat goes packed, in fewer bytes; line() made it whole again. */
    CHECK(h.packed == 0); /* the tests' windows so far are a pattern no two pixels alike in a row */
    uint32_t flat[20 * 10];
    for (int i = 0; i < 20 * 10; i++) flat[i] = 0xff303030u;
    flat[5 * 20 + 7] = 0xffffffffu;
    uint32_t pool4 = a.next++, plain = a.next++;
    make_drawn(&a, pool4, plain, flat, 20, 10);
    show_buffer(s, &a, one.surface, plain, 20, 10);
    mwm_ctl_update(c);
    while (line(c, &h)) {} /* its bar has another colour: the windows are told again first */
    CHECK(h.packed == 1 && h.pw == 20 && h.ph == 10);
    CHECK(h.data[0] == 0xff303030u && h.data[5 * 20 + 7] == 0xffffffffu && h.data[20 * 10 - 1] == 0xff303030u);

    /* Another MonadHost: it has nothing, and is sent all of both. */
    close(h.fd);
    h = attach(c);
    while (line(c, &h)) {}
    CHECK(h.chunks == 2 && h.told_count == 2);
    close(h.fd);
    mwm_conn_free(a.c);
    mwm_conn_free(b.c);
    mwm_ctl_free(c);
    mwm_server_free(s);
}

/* What the next event to an object is; -1 when there is none. */
static int next_opcode(client *k, uint32_t object) {
    mwm_msg m;
    while (mwm_conn_next(k->c, &m)) {
        int fd = mwm_get_fd(&m);
        if (fd >= 0) close(fd);
        if (m.object == object) return m.opcode;
    }
    return -1;
}

static void forget(client *k) {
    mwm_msg m;
    while (mwm_conn_next(k->c, &m)) {
        int fd = mwm_get_fd(&m);
        if (fd >= 0) close(fd);
    }
}

/* MonadHost's lines reach the program whose window they are about. */
static void test_the_macs_pointer_and_keys_arrive(void) {
    mwm_server *s = server();
    mwm_ctl *c = mwm_ctl_new(s);
    client a = connect_client(s);
    uint32_t seat = bind_global(&a, "wl_seat", 5), pointer = a.next++, keyboard = a.next++;
    request(&a, seat, 0, 1, pointer);
    request(&a, seat, 1, 1, keyboard);
    pump(s, &a);
    forget(&a);
    window one = open_window(s, &a, "One", "app.one", 0x00110000, 64, 32);
    forget(&a);
    host h = attach(c);
    char text[400];

    snprintf(text, sizeof text, "pointer %u 2560 1280\n", one.id);
    say(c, &h, text);
    drain(s, &a);
    mwm_msg m = event(&a);
    CHECK(m.object == pointer && m.opcode == 0); /* enter */
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == one.surface && mwm_get_int(&m) == 2560 && mwm_get_int(&m) == 1280);
    forget(&a);

    say(c, &h, "button 272 1\nbutton 272 0\nscroll 0 -512\n");
    drain(s, &a);
    m = event(&a);
    CHECK(m.object == pointer && m.opcode == 3); /* button */
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == 1000 && mwm_get_uint(&m) == 272 && mwm_get_uint(&m) == 1); /* at the time it arrived */
    CHECK(next_opcode(&a, pointer) == 5 && next_opcode(&a, pointer) == 3); /* frame; released */
    CHECK(next_opcode(&a, pointer) == 5 && next_opcode(&a, pointer) == 6); /* frame; the scroll's source */
    m = event(&a);
    CHECK(m.object == pointer && m.opcode == 4); /* axis */
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == 0 && mwm_get_int(&m) == -512);
    forget(&a);

    snprintf(text, sizeof text, "focus %u\nmods 1 2\nkey 30 1\nkey 30 0\n", one.id);
    say(c, &h, text);
    drain(s, &a);
    CHECK(next_opcode(&a, keyboard) == 1); /* enter */
    m = event(&a);
    CHECK(m.object == keyboard && m.opcode == 4); /* modifiers, as they were when it came in front */
    m = event(&a);
    CHECK(m.object == keyboard && m.opcode == 4);
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == 1 && mwm_get_uint(&m) == 0 && mwm_get_uint(&m) == 2);
    m = event(&a);
    CHECK(m.object == keyboard && m.opcode == 3); /* key */
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == 1000 && mwm_get_uint(&m) == 30 && mwm_get_uint(&m) == 1);
    CHECK(next_opcode(&a, keyboard) == 3);
    forget(&a);

    /* A line that comes in pieces is one line. */
    CHECK(write(h.fd, "key 3", 5) == 5);
    mwm_ctl_service(c, true, true, 2000);
    drain(s, &a);
    CHECK(no_event(&a));
    say(c, &h, "1 1\n");
    drain(s, &a);
    m = event(&a);
    CHECK(m.object == keyboard && m.opcode == 3);
    (void)mwm_get_uint(&m);
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == 31);
    forget(&a);

    /* The Mac's layout, as a table: the program gets a keymap with those keys. */
    say(c, &h, "keys 2\nk 30 1 97 65 229 197\nk 42 0 65505 0 0 0\n");
    drain(s, &a);
    m = event(&a);
    CHECK(m.object == keyboard && m.opcode == 0 && mwm_get_uint(&m) == 1); /* keymap */
    int fd = mwm_get_fd(&m);
    uint32_t size = mwm_get_uint(&m);
    CHECK(fd >= 0 && size > 0);
    char *keymap = malloc(size);
    CHECK(keymap && pread(fd, keymap, size, 0) == (ssize_t)size);
    CHECK(strstr(keymap, "key <K30> { type = \"FOUR_LEVEL_ALPHABETIC\", [ 0x61, 0x41, 0xe5, 0xc5 ] };"));
    CHECK(strstr(keymap, "modifier_map Shift { <K42> };") && !strstr(keymap, "<K31>"));
    free(keymap);
    close(fd);

    /* The Mac's window is resized, then closed: the program is asked to follow. */
    snprintf(text, sizeof text, "size %u 300 150\nclose %u\n", one.id, one.id);
    say(c, &h, text);
    drain(s, &a);
    m = event(&a);
    CHECK(m.object == one.toplevel && m.opcode == 0); /* configure */
    CHECK(mwm_get_int(&m) == 300 && mwm_get_int(&m) == 150);
    uint32_t len;
    const uint8_t *states = mwm_get_array(&m, &len);
    uint32_t state;
    CHECK(len == 20 && mwm_msg_done(&m)); /* its four edges at the Mac's frame, and: */
    memcpy(&state, states + 16, 4);
    CHECK(state == 4); /* still the window in front */
    m = event(&a);
    CHECK(m.object == one.xdg && m.opcode == 0);
    m = event(&a);
    CHECK(m.object == one.toplevel && m.opcode == 1 && mwm_msg_done(&m)); /* close */
    CHECK(no_event(&a));

    close(h.fd);
    mwm_conn_free(a.c);
    mwm_ctl_free(c);
    mwm_server_free(s);
}

/* Lines that make no sense do nothing; one that never ends ends the connection. */
static void test_lines_that_make_no_sense_do_nothing(void) {
    mwm_server *s = server();
    mwm_ctl *c = mwm_ctl_new(s);
    client a = connect_client(s);
    uint32_t seat = bind_global(&a, "wl_seat", 5), pointer = a.next++, keyboard = a.next++;
    request(&a, seat, 0, 1, pointer);
    request(&a, seat, 1, 1, keyboard);
    pump(s, &a);
    forget(&a);
    window one = open_window(s, &a, "One", "app.one", 0x00110000, 64, 32);
    forget(&a);
    host h = attach(c);
    while (line(c, &h)) {}
    char text[600];
    snprintf(text, sizeof text,
             "\n"
             "dance 1 2 3\n"                 /* a word a newer Monad may know */
             "pointer\n"                     /* too few numbers */
             "pointer %u 1 2 3\n"            /* too many */
             "pointer %u x 2\n"              /* not a number */
             "pointer %u 99999999999999 2\n" /* a number that is none here */
             "pointer %u 1 2junk\n"
             "focus -1\n"
             "focus 0x1\n"
             "key 30 2\n"                    /* neither down nor up */
             "key 30\n"
             "button 272 yes\n"
             "size %u 0 10\nsize %u 100000 10\nsize %u -5 -5\n"
             "close 77\n"                    /* no such window */
             "keys 0\nkeys 9999\nkeys 2\nk 30 0 97 0 0 0\npointer 0 0 0\n" /* a table cut short is no table */
             "k 30 0 97 0 0 0\n"             /* a key outside any table */
             "keys 1\nk 9000 0 97 0 0 0\n",  /* a table that cannot be a keyboard */
             one.id, one.id, one.id, one.id, one.id, one.id, one.id);
    say(c, &h, text);
    drain(s, &a);
    CHECK(no_event(&a));
    CHECK(mwm_ctl_fd(c) >= 0); /* still there, and still listening */
    snprintf(text, sizeof text, "focus %u\n", one.id);
    say(c, &h, text);
    drain(s, &a);
    CHECK(next_opcode(&a, keyboard) == 1);
    forget(&a);

    /* Bytes that are no text. */
    static const char binary[] = {'k', 'e', 'y', ' ', 0, 1, 2, (char)0xff, '\n', 'k', 'e', 'y', ' ', '3', '0', ' ', '1', '\n'};
    CHECK(write(h.fd, binary, sizeof binary) == (ssize_t)sizeof binary);
    mwm_ctl_service(c, true, true, 3000);
    drain(s, &a);
    CHECK(next_opcode(&a, keyboard) == 3); /* the line after is read as ever */
    forget(&a);

    /* A line that never ends. */
    char endless[MWM_CTL_LINE + 100];
    memset(endless, '7', sizeof endless);
    CHECK(write(h.fd, endless, sizeof endless) == (ssize_t)sizeof endless);
    mwm_ctl_service(c, true, true, 4000);
    CHECK(mwm_ctl_fd(c) == -1);
    char byte;
    CHECK(read(h.fd, &byte, 1) == 0 || errno == ECONNRESET); /* MonadHost sees it closed */
    close(h.fd);

    /* The program and its window are as they were, and another connection is served. */
    CHECK(mwm_server_windows(s, NULL, 0) == 1);
    h = attach(c);
    CHECK(line_is(c, &h, "monad-wm 1 400 200"));
    close(h.fd);
    mwm_ctl_service(c, true, true, 5000); /* MonadHost left */
    CHECK(mwm_ctl_fd(c) == -1);

    mwm_conn_free(a.c);
    mwm_ctl_free(c);
    mwm_server_free(s);
}

/* One MonadHost: a new connection takes the place of the old one. One
 * that is slow to read is not sent every list it missed: when it reads
 * again, it gets to the newest. */
static void test_one_monadhost_at_a_time(void) {
    mwm_server *s = server();
    mwm_ctl *c = mwm_ctl_new(s);
    host first = attach(c), second = attach(c);
    char byte;
    while (line(c, &first)) {}
    CHECK(read(first.fd, &byte, 1) == 0); /* closed */
    CHECK(line_is(c, &second, "monad-wm 1 400 200"));
    close(first.fd);

    client a = connect_client(s);
    window one = open_window(s, &a, "One", "app.one", 0x00110000, 64, 32);
    char title[100], header[40], last[MWM_CTL_LINE + 1] = "";
    while (line(c, &second)) {}
    for (int i = 0; i < 5000; i++) { /* the title changes and changes, and nobody reads */
        snprintf(title, sizeof title, "title-%d-%060d", i, i);
        mwm_put_begin(a.c, one.toplevel, 2);
        mwm_put_string(a.c, title);
        mwm_put_end(a.c);
        pump(s, &a);
        mwm_ctl_update(c);
    }
    CHECK(mwm_ctl_fd(c) >= 0);
    snprintf(header, sizeof header, "windows %u 1", mwm_server_generation(s));
    bool newest = false;
    long lines = 0;
    for (const char *got; (got = line(c, &second)) != NULL; lines++) {
        if (strncmp(got, "windows ", 8) == 0) newest = strcmp(got, header) == 0;
        if (strncmp(got, "window ", 7) == 0) snprintf(last, sizeof last, "%s", got);
    }
    CHECK(newest && strstr(last, title)); /* the last list is the windows as they are */
    CHECK(lines % 3 == 0 && lines < 3 * 5000); /* whole lists, and not one for every change */
    close(second.fd);
    mwm_conn_free(a.c);
    mwm_ctl_free(c);
    mwm_server_free(s);
}

/* The newest offer the program got from its clipboard device (0: told there is nothing; -1: told nothing). */
static int64_t selection(client *k, uint32_t device) {
    int64_t offer = -1;
    mwm_msg m;
    while (mwm_conn_next(k->c, &m)) {
        if (m.object == device && m.opcode == 5) offer = mwm_get_uint(&m); /* selection */
        int fd = mwm_get_fd(&m);
        if (fd >= 0) close(fd);
    }
    return offer;
}

/* Asks for an offer's text and reads it to its end, the server writing meanwhile. */
static const char *pasted(mwm_server *s, client *k, uint32_t offer) {
    static char text[4096];
    int fds[2];
    CHECK(pipe(fds) == 0);
    mwm_put_begin(k->c, offer, 1); /* receive */
    mwm_put_string(k->c, "text/plain;charset=utf-8");
    mwm_put_fd(k->c, fds[1]);
    mwm_put_end(k->c);
    close(fds[1]);
    pump(s, k);
    size_t len = 0;
    ssize_t n;
    while ((n = read(fds[0], text + len, sizeof text - 1 - len)) > 0) len += (size_t)n;
    CHECK(n == 0);
    close(fds[0]);
    text[len] = 0;
    return text;
}

/* The Mac's clipboard comes as `paste <bytes>` and that many bytes, whatever
 * they are; a copy the user asked for goes back as `copied <bytes>` and its
 * bytes, and one the Mac cannot have as `copied 0`. */
static void test_the_clipboards_meet_when_the_user_says(void) {
    mwm_server *s = server();
    mwm_ctl *c = mwm_ctl_new(s);
    client a = connect_client(s);
    uint32_t seat = bind_global(&a, "wl_seat", 5), manager = bind_global(&a, "wl_data_device_manager", 3), device = a.next++;
    request(&a, manager, 1, 2, device, seat); /* get_data_device */
    pump(s, &a);
    forget(&a);
    window one = open_window(s, &a, "One", "app.one", 0x00110000, 64, 32);
    forget(&a);
    host h = attach(c);
    while (line(c, &h)) {}
    char text[200];
    snprintf(text, sizeof text, "focus %u\n", one.id);
    say(c, &h, text);
    drain(s, &a);
    CHECK(selection(&a, device) == 0);

    /* The bytes are the text's, newlines and all: the line after them is read as a line. */
    say(c, &h, "paste 10\none\ntwo \xc3\xa9" "paste 3\nabc");
    drain(s, &a);
    int64_t offer = selection(&a, device);
    CHECK(offer > 0);
    CHECK(strcmp(pasted(s, &a, (uint32_t)offer), "abc") == 0); /* the second paste, so the first ended where it said */
    /* In pieces, as a stream brings it. */
    say(c, &h, "paste 1");
    say(c, &h, "0\none\ntw");
    drain(s, &a);
    CHECK(selection(&a, device) == -1); /* not until all of it came */
    say(c, &h, "o \xc3\xa9");
    drain(s, &a);
    offer = selection(&a, device);
    CHECK(offer > 0 && strcmp(pasted(s, &a, (uint32_t)offer), "one\ntwo \xc3\xa9") == 0);
    /* What is no text is not pasted, and the lines after it are read as ever. */
    say(c, &h, "paste 4\nab\xff\n" "paste 0\n");
    drain(s, &a);
    CHECK(selection(&a, device) == 0); /* only the `paste 0` did anything: nothing of the Mac's is there now */
    say(c, &h, "paste\npaste -1\npaste 1 2\npaste x\n");
    drain(s, &a);
    CHECK(no_event(&a) && mwm_ctl_fd(c) >= 0);

    /* ⌘C on the Mac, and the program copies. */
    say(c, &h, "copy\n");
    uint32_t source = a.next++;
    request(&a, manager, 0, 1, source);
    mwm_put_begin(a.c, source, 0);
    mwm_put_string(a.c, "text/plain;charset=utf-8");
    mwm_put_end(a.c);
    request(&a, device, 1, 2, source, 1);
    pump(s, &a);
    (void)mwm_conn_read(a.c); /* what comes with a descriptor comes apart from what was sent before it */
    mwm_msg m;
    int to_fill = -1;
    while (mwm_conn_next(a.c, &m))
        if (m.object == source && m.opcode == 1) to_fill = mwm_get_fd(&m); /* send */
    CHECK(to_fill >= 0);
    CHECK(write(to_fill, "for\nthe Mac", 11) == 11);
    close(to_fill);
    int fds[MWM_MAX_SOCKETS];
    bool wants[MWM_MAX_SOCKETS];
    int count = mwm_server_sockets(s, fds, wants, MWM_MAX_SOCKETS);
    for (int i = 0; i < count; i++)
        if (fds[i] != a.server_fd) mwm_server_service(s, fds[i], true, false);
    CHECK(line_is(c, &h, "copied 11"));
    CHECK(h.len == 11 && memcmp(h.text, "for\nthe Mac", 11) == 0); /* the bytes, and no newline of the channel's after them */
    h.len = 0;

    /* A copy that is no text: the Mac is told there was one, and gets nothing. */
    say(c, &h, "copy\n");
    source = a.next++;
    request(&a, manager, 0, 1, source);
    mwm_put_begin(a.c, source, 0);
    mwm_put_string(a.c, "image/png");
    mwm_put_end(a.c);
    request(&a, device, 1, 2, source, 1);
    pump(s, &a);
    CHECK(line_is(c, &h, "copied 0"));
    CHECK(line(c, &h) == NULL && h.len == 0);

    /* More than a paste may be: what follows cannot be told from its bytes, so the connection ends. */
    snprintf(text, sizeof text, "paste %d\n", MWM_MAX_CLIPBOARD + 1);
    say(c, &h, text);
    CHECK(mwm_ctl_fd(c) == -1);
    close(h.fd);
    mwm_conn_free(a.c);
    mwm_ctl_free(c);
    mwm_server_free(s);
}

/* MonadHost is told how the pointer is to look, when that changes: a
 * number it knows the shapes of. The arrow is what it takes it to be. */
static void test_the_pointers_shape_is_told(void) {
    mwm_server *s = server();
    mwm_ctl *c = mwm_ctl_new(s);
    client a = connect_client(s);
    uint32_t seat = bind_global(&a, "wl_seat", 5), pointer = a.next++;
    uint32_t shapes = bind_global(&a, "wp_cursor_shape_manager_v1", 1), device = a.next++;
    request(&a, seat, 0, 1, pointer);
    request(&a, shapes, 1, 2, device, pointer);
    pump(s, &a);
    forget(&a);
    window one = open_window(s, &a, "One", "app.one", 0x00110000, 64, 32);
    forget(&a);
    host h = attach(c);
    for (const char *got; (got = line(c, &h)) != NULL;) CHECK(strncmp(got, "cursor", 6) != 0); /* the arrow goes without saying */

    char text[100];
    snprintf(text, sizeof text, "pointer %u 256 256\n", one.id);
    say(c, &h, text);
    request(&a, device, 1, 2, 1, 9); /* text */
    pump(s, &a);
    mwm_ctl_update(c);
    CHECK(line_is(c, &h, "cursor 9"));
    request(&a, device, 1, 2, 1, 9); /* the same again: nothing to say */
    pump(s, &a);
    mwm_ctl_update(c);
    CHECK(line(c, &h) == NULL);
    request(&a, pointer, 0, 4, 1, 0, 0, 0); /* no cursor at all */
    pump(s, &a);
    mwm_ctl_update(c);
    CHECK(line_is(c, &h, "cursor 0"));
    say(c, &h, "pointer 0 0 0\n"); /* over no window: the arrow */
    CHECK(line_is(c, &h, "cursor 1"));

    /* A MonadHost that connects while the pointer looks like something is told so. */
    say(c, &h, text);
    request(&a, device, 1, 2, 1, 4);
    pump(s, &a);
    mwm_ctl_update(c);
    CHECK(line_is(c, &h, "cursor 4"));
    close(h.fd);
    h = attach(c);
    bool told = false;
    for (const char *got; (got = line(c, &h)) != NULL;) told = told || strcmp(got, "cursor 4") == 0;
    CHECK(told);

    /* A program that changes it without end, and a MonadHost that does not read: it hears the last, not each. */
    for (int i = 0; i < 20000; i++) {
        request(&a, device, 1, 2, 1, 1 + i % 30);
        pump(s, &a);
        forget(&a);
        mwm_ctl_update(c);
    }
    request(&a, device, 1, 2, 1, 33);
    pump(s, &a);
    mwm_ctl_update(c);
    CHECK(mwm_ctl_fd(c) >= 0);
    long lines = 0;
    char last[MWM_CTL_LINE + 1] = "";
    for (const char *got; (got = line(c, &h)) != NULL; lines++) snprintf(last, sizeof last, "%s", got);
    CHECK(strcmp(last, "cursor 33") == 0 && lines < 20000);
    close(h.fd);
    mwm_conn_free(a.c);
    mwm_ctl_free(c);
    mwm_server_free(s);
}

/* What a program asks of its own window (to be moved by the bar it drew,
 * zoomed, put away) is told MonadHost, which does it or not. */
static void test_what_a_program_asks_of_its_window_is_told(void) {
    mwm_server *s = server();
    mwm_ctl *c = mwm_ctl_new(s);
    client a = connect_client(s);
    uint32_t seat = bind_global(&a, "wl_seat", 5);
    pump(s, &a);
    forget(&a);
    window one = open_window(s, &a, "One", "app.one", 0x00110000, 64, 32);
    forget(&a);
    host h = attach(c);
    while (line(c, &h)) {}
    char text[100], expected[100];
    request(&a, one.toplevel, 5, 2, seat, 1); /* move, with the pointer elsewhere: not told */
    pump(s, &a);
    mwm_ctl_update(c);
    CHECK(line(c, &h) == NULL);

    snprintf(text, sizeof text, "pointer %u 256 256\n", one.id);
    say(c, &h, text);
    request(&a, one.toplevel, 5, 2, seat, 1);
    pump(s, &a);
    mwm_ctl_update(c);
    snprintf(expected, sizeof expected, "move %u", one.id);
    CHECK(line_is(c, &h, expected));
    request(&a, one.toplevel, 9, 0); /* set_maximized */
    pump(s, &a);
    mwm_ctl_update(c);
    snprintf(expected, sizeof expected, "zoom %u 1", one.id);
    CHECK(line_is(c, &h, expected));
    request(&a, one.toplevel, 10, 0); /* unset_maximized */
    pump(s, &a);
    mwm_ctl_update(c);
    snprintf(expected, sizeof expected, "zoom %u 0", one.id);
    CHECK(line_is(c, &h, expected));
    request(&a, one.toplevel, 13, 0); /* set_minimized */
    pump(s, &a);
    mwm_ctl_update(c);
    snprintf(expected, sizeof expected, "minimize %u", one.id);
    CHECK(line_is(c, &h, expected));
    CHECK(line(c, &h) == NULL);

    /* A program that asks without end, and a MonadHost that does not read: it hears the last wish, not each. */
    for (int i = 0; i < 20000; i++) {
        request(&a, one.toplevel, i % 2 ? 9 : 10, 0);
        pump(s, &a);
        forget(&a);
        mwm_ctl_update(c);
    }
    request(&a, one.toplevel, 13, 0);
    pump(s, &a);
    mwm_ctl_update(c);
    CHECK(mwm_ctl_fd(c) >= 0);
    long lines = 0;
    char last[MWM_CTL_LINE + 1] = "";
    for (const char *got; (got = line(c, &h)) != NULL; lines++) snprintf(last, sizeof last, "%s", got);
    snprintf(expected, sizeof expected, "minimize %u", one.id);
    CHECK(strcmp(last, expected) == 0 && lines < 20000);
    close(h.fd);
    mwm_conn_free(a.c);
    mwm_ctl_free(c);
    mwm_server_free(s);
}

int main(void) {
    test_a_windows_pixels_are_sent();
    signal(SIGPIPE, SIG_IGN);
    test_the_windows_are_told();
    test_the_macs_pointer_and_keys_arrive();
    test_lines_that_make_no_sense_do_nothing();
    test_one_monadhost_at_a_time();
    test_the_clipboards_meet_when_the_user_says();
    test_the_pointers_shape_is_told();
    test_what_a_program_asks_of_its_window_is_told();
    printf("test_wm_ctl: %d checks passed\n", checks);
    return 0;
}
