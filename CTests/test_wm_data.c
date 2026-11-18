/*
 * test_wm_data.c — the clipboard (GuestWM/mwm_data: wl_data_device and its
 * sources and offers): what one program copies another can paste; the
 * Mac's text is what a paste gives once the user pressed ⌘V; what a
 * program copies goes to the Mac only when the user pressed ⌘C just
 * before; and a program that is not in front neither sets the clipboard
 * nor hears what is on it.
 */
#include "wm_test_client.h"

#include <errno.h>
#include <signal.h>

enum { DEVICE_DATA_OFFER = 0, DEVICE_SELECTION = 5 };
enum { OFFER_OFFER = 0 };
enum { SOURCE_SEND = 1, SOURCE_CANCELLED = 2 };
static const char TEXT[] = "text/plain;charset=utf-8";

typedef struct {
    uint32_t seat, manager, device;
    window window;
} program;

/* A program with a window, a seat and its clipboard device. */
static program start(mwm_server *s, client *k, const char *title) {
    program p = {.seat = bind_global(k, "wl_seat", 5), .manager = bind_global(k, "wl_data_device_manager", 3), .device = k->next++};
    request(k, p.manager, 1, 2, p.device, p.seat); /* get_data_device */
    pump(s, k);
    mwm_msg m;
    while (mwm_conn_next(k->c, &m)) {}
    p.window = open_window(s, k, title, "app", 0, 32, 16);
    return p;
}

/* A source offering plain text, set as the selection. */
static uint32_t copy(client *k, const program *p) {
    uint32_t source = k->next++;
    request(k, p->manager, 0, 1, source); /* create_data_source */
    mwm_put_begin(k->c, source, 0);       /* offer */
    mwm_put_string(k->c, TEXT);
    mwm_put_end(k->c);
    mwm_put_begin(k->c, source, 0);
    mwm_put_string(k->c, "text/html");
    mwm_put_end(k->c);
    request(k, p->device, 1, 2, source, 1); /* set_selection */
    return source;
}

typedef struct {
    uint32_t offer; /* 0: the selection is nothing */
    bool announced, text, html;
} heard;

/* What the program was told of the clipboard since it last looked. */
static heard hear(client *k, const program *p) {
    heard h = {0};
    uint32_t latest = 0;
    mwm_msg m;
    while (mwm_conn_next(k->c, &m)) {
        CHECK(m.object != 1 || m.opcode != DISPLAY_ERROR);
        if (m.object == p->device && m.opcode == DEVICE_DATA_OFFER) {
            latest = mwm_get_uint(&m);
            CHECK(latest >= 0xff000000u); /* an id of the server's choosing */
            h.text = h.html = false;
        } else if (latest != 0 && m.object == latest && m.opcode == OFFER_OFFER) {
            uint32_t len;
            const char *mime = mwm_get_string(&m, &len);
            CHECK(mime != NULL);
            if (strcmp(mime, TEXT) == 0) h.text = true;
            if (strcmp(mime, "text/html") == 0) h.html = true;
        } else if (m.object == p->device && m.opcode == DEVICE_SELECTION) {
            h.offer = mwm_get_uint(&m);
            CHECK(h.offer == 0 || h.offer == latest);
            h.announced = true;
        } else {
            int fd = mwm_get_fd(&m);
            if (fd >= 0) close(fd);
        }
    }
    return h;
}

/* Asks for an offer's text: the reading end of a pipe the text is written into. */
static int receive(client *k, uint32_t offer, const char *mime) {
    int fds[2];
    CHECK(pipe(fds) == 0);
    mwm_put_begin(k->c, offer, 1); /* receive */
    mwm_put_string(k->c, mime);
    mwm_put_fd(k->c, fds[1]);
    mwm_put_end(k->c);
    close(fds[1]);
    return fds[0];
}

static const char *read_all(int fd) {
    static char text[70000];
    size_t len = 0;
    ssize_t n;
    while ((n = read(fd, text + len, sizeof text - 1 - len)) > 0) len += (size_t)n;
    CHECK(n == 0);
    text[len] = 0;
    close(fd);
    return text;
}

/* What the Mac was handed: texts, and copies it was only told of (they held nothing it takes). */
static char *copied_text;
static int copied_times, copied_empty;
static void copied(void *ctx, const char *text, size_t len) {
    (void)ctx;
    if (len == 0) {
        copied_empty++;
        return;
    }
    free(copied_text);
    copied_text = malloc(len + 1);
    memcpy(copied_text, text, len);
    copied_text[len] = 0;
    copied_times++;
}

/* What the server sent, all of it: what comes with a descriptor comes apart
 * from what was sent before it, so one read is not all there is. */
static void drain_all(mwm_server *s, client *k) {
    drain(s, k);
    (void)mwm_conn_read(k->c);
}

/* What one program copies, the program in front is offered and can paste. */
static void test_one_program_copies_and_another_pastes(void) {
    mwm_server *s = server();
    client a = connect_client(s), b = connect_client(s);
    program pa = start(s, &a, "A"), pb = start(s, &b, "B");
    mwm_server_focus(s, pa.window.id);
    drain(s, &a);
    heard h = hear(&a, &pa);
    CHECK(h.announced && h.offer == 0); /* in front: told there is nothing to paste yet */

    uint32_t source = copy(&a, &pa);
    pump(s, &a);
    h = hear(&a, &pa);
    CHECK(h.announced && h.offer != 0 && h.text && h.html); /* its own copy is what a paste would give */
    drain(s, &b);
    CHECK(no_event(&b)); /* the other program, not in front, hears nothing of it */

    mwm_server_focus(s, pb.window.id);
    drain(s, &b);
    h = hear(&b, &pb);
    CHECK(h.announced && h.offer != 0 && h.text && h.html);
    int fd = receive(&b, h.offer, TEXT);
    pump(s, &b);
    drain_all(s, &a);
    mwm_msg m;
    int to_fill = -1;
    while (mwm_conn_next(a.c, &m)) {
        if (m.object == source && m.opcode == SOURCE_SEND) {
            uint32_t len;
            const char *mime = mwm_get_string(&m, &len);
            CHECK(mime && strcmp(mime, TEXT) == 0);
            to_fill = mwm_get_fd(&m);
        }
    }
    CHECK(to_fill >= 0); /* the copier is asked for the text, into the paster's own pipe */
    CHECK(write(to_fill, "from A", 6) == 6);
    close(to_fill);
    CHECK(strcmp(read_all(fd), "from A") == 0);

    /* A kind of data the copier never offered is asked of nobody. */
    fd = receive(&b, h.offer, "image/png");
    pump(s, &b);
    drain(s, &a);
    CHECK(no_event(&a));
    CHECK(strcmp(read_all(fd), "") == 0); /* the pipe is closed, empty */

    /* The other program copies: the first is told its copy is no longer the clipboard. */
    uint32_t second = copy(&b, &pb);
    pump(s, &b);
    drain(s, &a);
    m = event(&a);
    CHECK(m.object == source && m.opcode == SOURCE_CANCELLED);
    h = hear(&b, &pb);
    CHECK(h.announced && h.offer != 0);

    /* The copier takes its copy back (or ends): there is nothing to paste. */
    request(&b, second, 1, 0); /* wl_data_source.destroy */
    pump(s, &b);
    h = hear(&b, &pb);
    CHECK(h.announced && h.offer == 0);
    mwm_conn_free(a.c);
    mwm_conn_free(b.c);
    mwm_server_free(s);
}

/* A program that is not in front does not set the clipboard. */
static void test_only_the_program_in_front_sets_the_clipboard(void) {
    mwm_server *s = server();
    client a = connect_client(s), b = connect_client(s);
    program pa = start(s, &a, "A"), pb = start(s, &b, "B");
    mwm_server_focus(s, pa.window.id);
    drain(s, &a);
    (void)hear(&a, &pa);
    uint32_t stolen = copy(&b, &pb); /* b is in the background */
    pump(s, &b);
    mwm_msg m = event(&b);
    CHECK(m.object == stolen && m.opcode == SOURCE_CANCELLED); /* told at once it is not the clipboard */
    drain(s, &a);
    CHECK(no_event(&a));
    mwm_server_focus(s, pb.window.id);
    drain(s, &b);
    heard h = hear(&b, &pb);
    CHECK(h.announced && h.offer == 0);
    mwm_conn_free(a.c);
    mwm_conn_free(b.c);
    mwm_server_free(s);
}

/* ⌘V on the Mac: the Mac's text is what a paste in the VM gives. */
static void test_the_macs_text_is_pasted(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    program pa = start(s, &a, "A");
    mwm_server_focus(s, pa.window.id);
    uint32_t own = copy(&a, &pa);
    pump(s, &a);
    (void)hear(&a, &pa);

    static const char mac[] = "from the Mac: caf\xc3\xa9";
    CHECK(mwm_server_paste(s, mac, sizeof mac - 1));
    drain(s, &a);
    mwm_msg m = event(&a);
    CHECK(m.object == own && m.opcode == SOURCE_CANCELLED); /* the program's own copy is not the clipboard now */
    heard h = hear(&a, &pa);
    CHECK(h.announced && h.offer != 0 && h.text && !h.html); /* text is all the Mac gives */
    int fd = receive(&a, h.offer, TEXT);
    pump(s, &a);
    CHECK(strcmp(read_all(fd), mac) == 0);
    fd = receive(&a, h.offer, "UTF8_STRING"); /* as programs for X ask for it */
    pump(s, &a);
    CHECK(strcmp(read_all(fd), mac) == 0);

    /* A long text arrives whole, however little a pipe holds at once. */
    static char longer[60000];
    for (size_t i = 0; i < sizeof longer - 1; i++) longer[i] = (char)('a' + i % 26);
    CHECK(mwm_server_paste(s, longer, sizeof longer - 1));
    drain(s, &a);
    h = hear(&a, &pa);
    CHECK(h.announced && h.offer != 0);
    fd = receive(&a, h.offer, TEXT);
    pump(s, &a);
    /* The pipe is read while the server still writes into it. */
    static char got[70000];
    size_t len = 0;
    for (int turns = 0; turns < 10000; turns++) {
        ssize_t n = read(fd, got + len, sizeof got - 1 - len);
        if (n == 0) break;
        if (n > 0) len += (size_t)n;
        int fds[MWM_MAX_SOCKETS];
        bool wants[MWM_MAX_SOCKETS];
        int count = mwm_server_sockets(s, fds, wants, MWM_MAX_SOCKETS);
        for (int i = 0; i < count; i++)
            if (fds[i] != a.server_fd) mwm_server_service(s, fds[i], false, true);
    }
    close(fd);
    got[len] = 0;
    CHECK(len == sizeof longer - 1 && strcmp(got, longer) == 0);

    /* What is no text, or too much of it, is not taken, and the clipboard stays. */
    CHECK(!mwm_server_paste(s, "bad \xff bytes", 11));
    CHECK(!mwm_server_paste(s, "with\0nul", 8));
    static char huge[MWM_MAX_CLIPBOARD + 2];
    memset(huge, 'x', sizeof huge - 1);
    CHECK(!mwm_server_paste(s, huge, sizeof huge - 1));
    drain(s, &a);
    CHECK(no_event(&a));
    /* No text at all: nothing of the Mac's is there to paste. */
    CHECK(mwm_server_paste(s, "", 0));
    drain(s, &a);
    h = hear(&a, &pa);
    CHECK(h.announced && h.offer == 0);
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

/* Feeds the copier's answer into the pipe the server gave it, and lets the server read it. */
static bool answer_copy(mwm_server *s, client *k, uint32_t source, const char *text, size_t len) {
    drain_all(s, k);
    mwm_msg m;
    int to_fill = -1;
    while (mwm_conn_next(k->c, &m)) {
        if (m.object == source && m.opcode == SOURCE_SEND) {
            uint32_t n;
            CHECK(strcmp(mwm_get_string(&m, &n), TEXT) == 0);
            to_fill = mwm_get_fd(&m);
        }
    }
    if (to_fill < 0) return false;
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(to_fill, text + done, len - done > 4096 ? 4096 : len - done);
        if (n < 0 && errno == EPIPE) break; /* the server took all it would */
        CHECK(n > 0);
        done += (size_t)n;
        int fds[MWM_MAX_SOCKETS];
        bool wants[MWM_MAX_SOCKETS];
        int count = mwm_server_sockets(s, fds, wants, MWM_MAX_SOCKETS);
        for (int i = 0; i < count; i++)
            if (fds[i] != k->server_fd) mwm_server_service(s, fds[i], true, false);
    }
    close(to_fill);
    int fds[MWM_MAX_SOCKETS];
    bool wants[MWM_MAX_SOCKETS];
    int count = mwm_server_sockets(s, fds, wants, MWM_MAX_SOCKETS);
    for (int i = 0; i < count; i++)
        if (fds[i] != k->server_fd) mwm_server_service(s, fds[i], true, false);
    return true;
}

/* ⌘C on the Mac: what the program in front copies next goes to the Mac,
 * once; what it copies at any other time stays in the VM. A copy the Mac
 * asked for and cannot have (no text, too much) it is still told of, with
 * nothing: its own clipboard is then the older of the two. */
static void test_what_is_copied_goes_to_the_mac_only_when_asked(void) {
    mwm_server *s = server();
    mwm_server_on_copied(s, copied, NULL);
    copied_times = copied_empty = 0;
    client a = connect_client(s);
    program pa = start(s, &a, "A");
    mwm_server_focus(s, pa.window.id);
    drain(s, &a);
    (void)hear(&a, &pa);

    /* The program copies by itself: the Mac is not told. */
    uint32_t source = copy(&a, &pa);
    pump(s, &a);
    CHECK(!answer_copy(s, &a, source, "secret", 6));
    CHECK(copied_times == 0 && copied_empty == 0);

    /* The user pressed ⌘C: the next copy is the Mac's too. */
    mwm_server_copy(s, 1000);
    source = copy(&a, &pa);
    pump(s, &a);
    CHECK(answer_copy(s, &a, source, "for the Mac", 11));
    CHECK(copied_times == 1 && strcmp(copied_text, "for the Mac") == 0);
    /* Once: the copy after it is the program's own business again. */
    source = copy(&a, &pa);
    pump(s, &a);
    CHECK(!answer_copy(s, &a, source, "again", 5));
    CHECK(copied_times == 1 && copied_empty == 0);

    /* ⌘C, and the program takes its time: after a while what it copies is no answer to that key. */
    mwm_server_copy(s, 5000);
    mwm_server_frame(s, 5000 + MWM_COPY_MS + 1);
    source = copy(&a, &pa);
    pump(s, &a);
    CHECK(!answer_copy(s, &a, source, "late", 4));
    CHECK(copied_times == 1 && copied_empty == 0);

    /* More than the Mac takes: it is told of the copy, and given none of it. */
    static char big[MWM_MAX_COPY + 4096];
    memset(big, 'y', sizeof big);
    mwm_server_copy(s, 9000);
    source = copy(&a, &pa);
    pump(s, &a);
    CHECK(answer_copy(s, &a, source, big, sizeof big));
    CHECK(copied_times == 1 && copied_empty == 1);

    /* A program that never writes what it was asked for holds nothing up, and is given up on. */
    mwm_server_copy(s, 20000);
    source = copy(&a, &pa);
    pump(s, &a);
    drain_all(s, &a);
    mwm_msg m;
    int kept = -1;
    while (mwm_conn_next(a.c, &m))
        if (m.object == source && m.opcode == SOURCE_SEND) kept = mwm_get_fd(&m);
    CHECK(kept >= 0);
    int before[MWM_MAX_SOCKETS], after[MWM_MAX_SOCKETS];
    bool wants[MWM_MAX_SOCKETS];
    int waiting = mwm_server_sockets(s, before, wants, MWM_MAX_SOCKETS);
    mwm_server_frame(s, 20000 + MWM_COPY_MS + 1);
    CHECK(mwm_server_sockets(s, after, wants, MWM_MAX_SOCKETS) == waiting - 1); /* its pipe is let go */
    close(kept);
    CHECK(copied_times == 1 && copied_empty == 2);

    /* Text that is none (bytes that are no UTF-8) is not the Mac's to have. */
    mwm_server_copy(s, 30000);
    source = copy(&a, &pa);
    pump(s, &a);
    CHECK(answer_copy(s, &a, source, "bad \xff", 5));
    CHECK(copied_times == 1 && copied_empty == 3);

    /* A copy of something that is no text at all (a picture). */
    mwm_server_copy(s, 40000);
    source = a.next++;
    request(&a, pa.manager, 0, 1, source);
    mwm_put_begin(a.c, source, 0);
    mwm_put_string(a.c, "image/png");
    mwm_put_end(a.c);
    request(&a, pa.device, 1, 2, source, 1);
    pump(s, &a);
    CHECK(!answer_copy(s, &a, source, "PNG", 3)); /* never asked for */
    CHECK(copied_times == 1 && copied_empty == 4);
    free(copied_text);
    copied_text = NULL;
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

/* What a program may not do with the clipboard's objects, and programs that go. */
static void test_the_clipboard_misused(void) {
    mwm_server *s = server();
    uint32_t object;
    client k = connect_client(s);
    program p = start(s, &k, "K");
    request(&k, p.device, 1, 2, 4242, 1); /* a selection that is no source */
    CHECK(dropped_with(s, &k, &object) == ERROR_INVALID_OBJECT);

    k = connect_client(s);
    p = start(s, &k, "K");
    request(&k, p.manager, 1, 2, k.next++, p.manager); /* a device for something that is no seat */
    CHECK(dropped_with(s, &k, &object) == ERROR_INVALID_OBJECT);

    k = connect_client(s);
    p = start(s, &k, "K");
    request(&k, 0xff000007u, 2, 0); /* an offer the server never made */
    CHECK(dropped_with(s, &k, &object) == ERROR_INVALID_OBJECT);

    /* More kinds of data than a copy may offer: the ones beyond are not offered, and nothing breaks. */
    k = connect_client(s);
    p = start(s, &k, "K");
    mwm_server_focus(s, p.window.id);
    uint32_t source = k.next++;
    request(&k, p.manager, 0, 1, source);
    for (int i = 0; i < 100; i++) {
        char mime[40];
        snprintf(mime, sizeof mime, "application/x-kind-%d", i);
        mwm_put_begin(k.c, source, 0);
        mwm_put_string(k.c, mime);
        mwm_put_end(k.c);
    }
    request(&k, p.device, 1, 2, source, 1);
    pump(s, &k);
    heard h = hear(&k, &p);
    CHECK(h.announced && h.offer != 0);

    /* The copier ends with its copy on the clipboard: the next program in front is told there is nothing. */
    client other = connect_client(s);
    program po = start(s, &other, "O");
    mwm_conn_free(k.c);
    mwm_server_service(s, k.server_fd, true, false);
    mwm_server_focus(s, po.window.id);
    drain(s, &other);
    h = hear(&other, &po);
    CHECK(h.announced && h.offer == 0);
    mwm_conn_free(other.c);
    mwm_server_free(s);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    test_one_program_copies_and_another_pastes();
    test_only_the_program_in_front_sets_the_clipboard();
    test_the_macs_text_is_pasted();
    test_what_is_copied_goes_to_the_mac_only_when_asked();
    test_the_clipboard_misused();
    printf("test_wm_data: %d checks passed\n", checks);
    return 0;
}
