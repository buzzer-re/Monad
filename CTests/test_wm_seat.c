/*
 * test_wm_seat.c — the window manager's pointer and keyboard (GuestWM/
 * mwm_seat): the Mac says which window the pointer is over and which one
 * has the keyboard, and the program owning that window is told, in
 * Wayland's words; nobody else is.
 */
#include "wm_test_client.h"

#include <sys/mman.h>
#include <sys/stat.h>

enum { SEAT_CAPABILITIES = 0, SEAT_NAME = 1 };
enum { POINTER_ENTER = 0, POINTER_LEAVE, POINTER_MOTION, POINTER_BUTTON, POINTER_AXIS, POINTER_FRAME };
enum { KEYBOARD_KEYMAP = 0, KEYBOARD_ENTER, KEYBOARD_LEAVE, KEYBOARD_KEY, KEYBOARD_MODIFIERS, KEYBOARD_REPEAT };
enum { BTN_LEFT = 0x110, KEY_A = 30, KEY_LEFTSHIFT = 42 };
enum { SHIFT = 1, LOCK = 2 };

typedef struct {
    uint32_t seat, pointer, keyboard;
} seat;

/* Binds the seat at `version` and reads what it says of itself. */
static uint32_t bind_seat(mwm_server *s, client *k, uint32_t version) {
    CHECK(offered(k, "wl_seat") >= 5);
    uint32_t id = bind_global(k, "wl_seat", version);
    pump(s, k);
    mwm_msg m = event(k);
    CHECK(m.object == id && m.opcode == SEAT_CAPABILITIES && mwm_get_uint(&m) == 3); /* a pointer and a keyboard */
    if (version >= 2) {
        uint32_t len;
        m = event(k);
        CHECK(m.object == id && m.opcode == SEAT_NAME && mwm_get_string(&m, &len) != NULL);
    }
    CHECK(no_event(k));
    return id;
}

/* The seat's pointer and keyboard; the keymap and what the keys repeat at are read. */
static seat take_seat(mwm_server *s, client *k, uint32_t version) {
    seat v = {.seat = bind_seat(s, k, version), .pointer = k->next++, .keyboard = k->next++};
    request(k, v.seat, 0, 1, v.pointer);  /* get_pointer */
    request(k, v.seat, 1, 1, v.keyboard); /* get_keyboard */
    pump(s, k);
    mwm_msg m = event(k);
    CHECK(m.object == v.keyboard && m.opcode == KEYBOARD_KEYMAP);
    CHECK(mwm_get_uint(&m) == 1); /* xkb_v1 */
    int fd = mwm_get_fd(&m);
    uint32_t size = mwm_get_uint(&m);
    CHECK(fd >= 0 && size > 100 && mwm_msg_done(&m));
    struct stat st;
    CHECK(fstat(fd, &st) == 0 && (uint32_t)st.st_size >= size);
    char *text = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    CHECK(text != MAP_FAILED);
    CHECK(text[size - 1] == '\0' && strncmp(text, "xkb_keymap {", 12) == 0);
    CHECK(strstr(text, "xkb_symbols") && strstr(text, "<K30>")); /* the key the tests press */
    CHECK(write(fd, "x", 1) < 0); /* one program cannot change the keys of the others */
    munmap(text, size);
    close(fd);
    if (version >= 4) {
        m = event(k);
        CHECK(m.object == v.keyboard && m.opcode == KEYBOARD_REPEAT);
        CHECK(mwm_get_int(&m) > 0 && mwm_get_int(&m) > 0 && mwm_msg_done(&m));
    }
    CHECK(no_event(k));
    return v;
}

static void expect_frame(client *k, uint32_t pointer) {
    mwm_msg m = event(k);
    CHECK(m.object == pointer && m.opcode == POINTER_FRAME && mwm_msg_done(&m));
}

/* The pointer comes over a window, moves, presses, scrolls and leaves. */
static void test_the_pointer_is_where_the_mac_says(void) {
    mwm_server *s = server();
    client a = connect_client(s), b = connect_client(s);
    seat sa = take_seat(s, &a, 5), sb = take_seat(s, &b, 5);
    window one = open_window(s, &a, "One", "app.one", 0x00110000, 64, 32);
    window two = open_window(s, &b, "Two", "app.two", 0x00220000, 64, 32);
    CHECK(one.id != 0 && two.id != 0);

    mwm_server_pointer(s, one.id, 10 << 8, (5 << 8) + 128, 100);
    drain(s, &a);
    mwm_msg m = event(&a);
    CHECK(m.object == sa.pointer && m.opcode == POINTER_ENTER);
    uint32_t entered = mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == one.surface && mwm_get_int(&m) == 10 << 8 && mwm_get_int(&m) == (5 << 8) + 128 && mwm_msg_done(&m));
    expect_frame(&a, sa.pointer);
    CHECK(no_event(&a));

    mwm_server_pointer(s, one.id, 11 << 8, 6 << 8, 116);
    drain(s, &a);
    m = event(&a);
    CHECK(m.object == sa.pointer && m.opcode == POINTER_MOTION);
    CHECK(mwm_get_uint(&m) == 116 && mwm_get_int(&m) == 11 << 8 && mwm_get_int(&m) == 6 << 8 && mwm_msg_done(&m));
    expect_frame(&a, sa.pointer);

    mwm_server_button(s, BTN_LEFT, true, 120);
    mwm_server_button(s, BTN_LEFT, false, 180);
    drain(s, &a);
    m = event(&a);
    CHECK(m.object == sa.pointer && m.opcode == POINTER_BUTTON);
    uint32_t pressed = mwm_get_uint(&m);
    CHECK(pressed != entered && mwm_get_uint(&m) == 120 && mwm_get_uint(&m) == BTN_LEFT && mwm_get_uint(&m) == 1 && mwm_msg_done(&m));
    expect_frame(&a, sa.pointer);
    m = event(&a);
    CHECK(m.object == sa.pointer && m.opcode == POINTER_BUTTON);
    CHECK(mwm_get_uint(&m) != pressed && mwm_get_uint(&m) == 180 && mwm_get_uint(&m) == BTN_LEFT && mwm_get_uint(&m) == 0);
    expect_frame(&a, sa.pointer);

    /* Scrolling: down by 12 pixels and a little to the right, as one frame. */
    mwm_server_scroll(s, 64, 12 << 8, 200);
    drain(s, &a);
    m = event(&a);
    CHECK(m.object == sa.pointer && m.opcode == 6 && mwm_get_uint(&m) == 2); /* axis_source: by pixels, not by a wheel's steps */
    m = event(&a);
    CHECK(m.object == sa.pointer && m.opcode == POINTER_AXIS);
    CHECK(mwm_get_uint(&m) == 200 && mwm_get_uint(&m) == 0 && mwm_get_int(&m) == 12 << 8 && mwm_msg_done(&m)); /* vertical */
    m = event(&a);
    CHECK(m.object == sa.pointer && m.opcode == POINTER_AXIS);
    CHECK(mwm_get_uint(&m) == 200 && mwm_get_uint(&m) == 1 && mwm_get_int(&m) == 64); /* horizontal */
    expect_frame(&a, sa.pointer);
    CHECK(no_event(&a));

    /* Over the other program's window: the first is told it left, the second that it came. */
    drain(s, &b);
    CHECK(no_event(&b)); /* nothing of the above was the second program's to know */
    mwm_server_pointer(s, two.id, 0, 0, 300);
    drain(s, &a);
    drain(s, &b);
    m = event(&a);
    CHECK(m.object == sa.pointer && m.opcode == POINTER_LEAVE);
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == one.surface && mwm_msg_done(&m));
    expect_frame(&a, sa.pointer);
    CHECK(no_event(&a));
    m = event(&b);
    CHECK(m.object == sb.pointer && m.opcode == POINTER_ENTER);
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == two.surface);
    expect_frame(&b, sb.pointer);

    /* Over no window at all. */
    mwm_server_pointer(s, 0, 0, 0, 400);
    drain(s, &b);
    m = event(&b);
    CHECK(m.object == sb.pointer && m.opcode == POINTER_LEAVE);
    expect_frame(&b, sb.pointer);
    mwm_server_button(s, BTN_LEFT, true, 410); /* a press over nothing is nobody's */
    mwm_server_scroll(s, 0, 256, 420);
    mwm_server_pointer(s, 9999, 0, 0, 430); /* nor is a window that does not exist */
    drain(s, &a);
    drain(s, &b);
    CHECK(no_event(&a) && no_event(&b));

    mwm_conn_free(a.c);
    mwm_conn_free(b.c);
    mwm_server_free(s);
}

static void expect_modifiers(client *k, uint32_t keyboard, uint32_t depressed, uint32_t locked) {
    mwm_msg m = event(k);
    CHECK(m.object == keyboard && m.opcode == KEYBOARD_MODIFIERS);
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == depressed && mwm_get_uint(&m) == 0 && mwm_get_uint(&m) == locked && mwm_get_uint(&m) == 0);
    CHECK(mwm_msg_done(&m));
}

/* xdg_toplevel.configure: whether it says the window is the one in front. */
static bool configured_active(client *k, const window *w) {
    mwm_msg m = event(k);
    CHECK(m.object == w->toplevel && m.opcode == 0);
    (void)mwm_get_int(&m);
    (void)mwm_get_int(&m);
    uint32_t len;
    const uint8_t *states = mwm_get_array(&m, &len);
    CHECK(mwm_msg_done(&m) && len % 4 == 0);
    bool active = false;
    for (uint32_t i = 0; i < len; i += 4) {
        uint32_t state;
        memcpy(&state, states + i, 4);
        if (state == 4) active = true; /* activated */
    }
    m = event(k);
    CHECK(m.object == w->xdg && m.opcode == 0); /* xdg_surface.configure ends it */
    return active;
}

/* The window that has the keyboard gets the keys; it looks active, the others do not. */
static void test_the_keyboard_follows_the_window_in_front(void) {
    mwm_server *s = server();
    client a = connect_client(s), b = connect_client(s);
    seat sa = take_seat(s, &a, 5), sb = take_seat(s, &b, 5);
    window one = open_window(s, &a, "One", "app.one", 0x00110000, 64, 32);
    window two = open_window(s, &b, "Two", "app.two", 0x00220000, 64, 32);

    mwm_server_key(s, KEY_A, true, 10); /* with no window in front, keys are nobody's */
    mwm_server_key(s, KEY_A, false, 20);
    drain(s, &a);
    drain(s, &b);
    CHECK(no_event(&a) && no_event(&b));

    mwm_server_focus(s, one.id);
    drain(s, &a);
    CHECK(configured_active(&a, &one));
    mwm_msg m = event(&a);
    CHECK(m.object == sa.keyboard && m.opcode == KEYBOARD_ENTER);
    uint32_t len, entered = mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == one.surface);
    (void)mwm_get_array(&m, &len);
    CHECK(len == 0 && mwm_msg_done(&m)); /* no key is down */
    expect_modifiers(&a, sa.keyboard, 0, 0);
    CHECK(no_event(&a));

    mwm_server_modifiers(s, SHIFT, 0);
    mwm_server_key(s, KEY_LEFTSHIFT, true, 100);
    mwm_server_key(s, KEY_A, true, 110);
    drain(s, &a);
    expect_modifiers(&a, sa.keyboard, SHIFT, 0);
    m = event(&a);
    CHECK(m.object == sa.keyboard && m.opcode == KEYBOARD_KEY);
    CHECK(mwm_get_uint(&m) != entered && mwm_get_uint(&m) == 100 && mwm_get_uint(&m) == KEY_LEFTSHIFT && mwm_get_uint(&m) == 1);
    m = event(&a);
    CHECK(m.object == sa.keyboard && m.opcode == KEYBOARD_KEY);
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == 110 && mwm_get_uint(&m) == KEY_A && mwm_get_uint(&m) == 1 && mwm_msg_done(&m));
    mwm_server_modifiers(s, SHIFT, 0); /* said again, unchanged: not passed on */
    drain(s, &a);
    CHECK(no_event(&a));

    /* The other window comes in front with both keys still down: it is told which. */
    mwm_server_focus(s, two.id);
    drain(s, &a);
    drain(s, &b);
    m = event(&a);
    CHECK(m.object == sa.keyboard && m.opcode == KEYBOARD_LEAVE);
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == one.surface && mwm_msg_done(&m));
    CHECK(!configured_active(&a, &one));
    CHECK(no_event(&a));
    CHECK(configured_active(&b, &two));
    m = event(&b);
    CHECK(m.object == sb.keyboard && m.opcode == KEYBOARD_ENTER);
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == two.surface);
    const uint8_t *held = mwm_get_array(&m, &len);
    uint32_t keys[2];
    CHECK(len == 8 && mwm_msg_done(&m));
    memcpy(keys, held, 8);
    CHECK(keys[0] == KEY_LEFTSHIFT && keys[1] == KEY_A);
    expect_modifiers(&b, sb.keyboard, SHIFT, 0);

    mwm_server_key(s, KEY_A, false, 200);
    mwm_server_key(s, KEY_A, false, 201); /* a release of a key that is not down is not a key */
    mwm_server_key(s, KEY_LEFTSHIFT, false, 210);
    mwm_server_modifiers(s, 0, LOCK);
    drain(s, &a);
    drain(s, &b);
    CHECK(no_event(&a));
    m = event(&b);
    CHECK(m.object == sb.keyboard && m.opcode == KEYBOARD_KEY);
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == 200 && mwm_get_uint(&m) == KEY_A && mwm_get_uint(&m) == 0);
    m = event(&b);
    CHECK(m.object == sb.keyboard && m.opcode == KEYBOARD_KEY);
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == 210 && mwm_get_uint(&m) == KEY_LEFTSHIFT && mwm_get_uint(&m) == 0);
    expect_modifiers(&b, sb.keyboard, 0, LOCK);
    CHECK(no_event(&b));

    /* No window in front (another Mac app is). */
    mwm_server_focus(s, 0);
    drain(s, &b);
    m = event(&b);
    CHECK(m.object == sb.keyboard && m.opcode == KEYBOARD_LEAVE);
    CHECK(!configured_active(&b, &two));
    CHECK(no_event(&b));

    mwm_conn_free(a.c);
    mwm_conn_free(b.c);
    mwm_server_free(s);
}

/* A window that goes takes the pointer and the keyboard with it: what is
 * typed next is not another program's to read. */
static void test_a_window_that_goes_has_the_keys_no_more(void) {
    mwm_server *s = server();
    client a = connect_client(s), b = connect_client(s);
    seat sa = take_seat(s, &a, 5), sb = take_seat(s, &b, 5);
    window one = open_window(s, &a, "One", "app.one", 0x00110000, 64, 32);
    window two = open_window(s, &b, "Two", "app.two", 0x00220000, 64, 32);
    (void)sb;
    (void)two;
    mwm_server_focus(s, one.id);
    mwm_server_pointer(s, one.id, 0, 0, 1);
    drain(s, &a);
    mwm_msg m;
    while (mwm_conn_next(a.c, &m)) {}

    /* The program takes its window away and keeps the surface: it is told both left. */
    request(&a, one.toplevel, 0, 0); /* xdg_toplevel.destroy */
    pump(s, &a);
    bool pointer_left = false, keyboard_left = false;
    while (mwm_conn_next(a.c, &m)) {
        if (m.object == sa.pointer && m.opcode == POINTER_LEAVE) pointer_left = true;
        if (m.object == sa.keyboard && m.opcode == KEYBOARD_LEAVE) keyboard_left = true;
    }
    CHECK(pointer_left && keyboard_left);
    mwm_server_key(s, KEY_A, true, 10);
    mwm_server_button(s, BTN_LEFT, true, 11);
    mwm_server_focus(s, one.id); /* the Mac has not heard yet: the window it names is gone */
    mwm_server_pointer(s, one.id, 0, 0, 12);
    mwm_server_key(s, KEY_A, false, 13);
    drain(s, &a);
    drain(s, &b);
    CHECK(no_event(&a) && no_event(&b));

    /* A program that ends while its window has both. */
    mwm_server_focus(s, two.id);
    mwm_server_pointer(s, two.id, 0, 0, 20);
    mwm_conn_free(b.c);
    mwm_server_service(s, b.server_fd, true, false);
    mwm_server_key(s, KEY_A, true, 30);
    mwm_server_button(s, BTN_LEFT, true, 31);
    mwm_server_scroll(s, 0, 256, 32);
    mwm_server_modifiers(s, SHIFT, 0);
    drain(s, &a);
    CHECK(no_event(&a));

    /* A surface destroyed outright: nothing is said about an object that is gone. */
    window three = open_window(s, &a, "Three", "app.one", 0x00330000, 64, 32);
    mwm_server_focus(s, three.id);
    mwm_server_pointer(s, three.id, 0, 0, 40);
    drain(s, &a);
    while (mwm_conn_next(a.c, &m)) {}
    request(&a, three.toplevel, 0, 0);
    request(&a, three.xdg, 0, 0);
    request(&a, three.surface, 0, 0);
    mwm_conn_flush(a.c);
    mwm_server_service(s, a.server_fd, true, true);
    mwm_server_key(s, KEY_A, false, 50);
    drain(s, &a);
    while (mwm_conn_next(a.c, &m)) CHECK(m.opcode != KEYBOARD_KEY || m.object != sa.keyboard);
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

/* A keyboard or pointer asked for while the program's window already has
 * it is told so at once (programs ask late, after their window is up). */
static void test_a_late_keyboard_learns_where_it_is(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    window one = open_window(s, &a, "One", "app.one", 0x00110000, 64, 32);
    mwm_server_focus(s, one.id);
    mwm_server_modifiers(s, SHIFT, 0);
    mwm_server_pointer(s, one.id, 3 << 8, 4 << 8, 5);
    drain(s, &a);
    CHECK(configured_active(&a, &one));
    CHECK(no_event(&a));
    uint32_t seat_id = bind_seat(s, &a, 5), pointer = a.next++, keyboard = a.next++;
    request(&a, seat_id, 0, 1, pointer);
    request(&a, seat_id, 1, 1, keyboard);
    pump(s, &a);
    mwm_msg m = event(&a);
    CHECK(m.object == pointer && m.opcode == POINTER_ENTER);
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == one.surface && mwm_get_int(&m) == 3 << 8 && mwm_get_int(&m) == 4 << 8);
    expect_frame(&a, pointer);
    m = event(&a);
    CHECK(m.object == keyboard && m.opcode == KEYBOARD_KEYMAP);
    close(mwm_get_fd(&m));
    m = event(&a);
    CHECK(m.object == keyboard && m.opcode == KEYBOARD_REPEAT);
    m = event(&a);
    CHECK(m.object == keyboard && m.opcode == KEYBOARD_ENTER);
    expect_modifiers(&a, keyboard, SHIFT, 0);
    CHECK(no_event(&a));

    /* Released, they hear nothing more. */
    request(&a, pointer, 1, 0);  /* wl_pointer.release */
    request(&a, keyboard, 0, 0); /* wl_keyboard.release */
    pump(s, &a);
    while (mwm_conn_next(a.c, &m)) CHECK(m.object == 1 && m.opcode == DISPLAY_DELETE_ID);
    mwm_server_key(s, KEY_A, true, 9);
    mwm_server_pointer(s, one.id, 0, 0, 10);
    drain(s, &a);
    CHECK(no_event(&a));
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

/* An older program binds an older seat: it is spoken to in what it knows. */
static void test_an_old_seat_hears_only_what_it_knows(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    seat sa = take_seat(s, &a, 1);
    window one = open_window(s, &a, "One", "app.one", 0x00110000, 64, 32);
    mwm_server_pointer(s, one.id, 0, 0, 1);
    mwm_server_scroll(s, 0, 256, 2);
    drain(s, &a);
    mwm_msg m = event(&a);
    CHECK(m.object == sa.pointer && m.opcode == POINTER_ENTER);
    m = event(&a);
    CHECK(m.object == sa.pointer && m.opcode == POINTER_AXIS); /* no source, no frame */
    CHECK(no_event(&a));
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

/* What the seat does not have, and requests it does not know. */
static void test_a_seat_misused_drops_the_program(void) {
    mwm_server *s = server();
    uint32_t object;
    client k = connect_client(s);
    uint32_t seat_id = bind_seat(s, &k, 5);
    request(&k, seat_id, 2, 1, k.next++); /* get_touch: there is no touch screen */
    CHECK(dropped_with(s, &k, &object) == 0 && object == seat_id); /* wl_seat.error.missing_capability */

    k = connect_client(s);
    seat_id = bind_seat(s, &k, 5);
    request(&k, seat_id, 9, 0);
    CHECK(dropped_with(s, &k, &object) == ERROR_INVALID_METHOD);

    k = connect_client(s);
    seat v = take_seat(s, &k, 5);
    request(&k, v.pointer, 0, 4, 1, 9999, 0, 0); /* set_cursor with a surface that does not exist */
    CHECK(dropped_with(s, &k, &object) == ERROR_INVALID_OBJECT);

    k = connect_client(s);
    v = take_seat(s, &k, 5);
    request(&k, v.keyboard, 3, 0);
    CHECK(dropped_with(s, &k, &object) == ERROR_INVALID_METHOD);

    k = connect_client(s);
    request(&k, bind_global(&k, "wl_seat", 99), 0, 1, k.next); /* a version never offered */
    CHECK(dropped_with(s, &k, &object) == ERROR_INVALID_OBJECT);
    mwm_server_free(s);
}

/* The Mac's keys, as a table: the programs get them as a keymap, at once. */
static void test_the_keys_are_what_the_mac_says(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    seat sa = take_seat(s, &a, 5);
    static const mwm_key keys[] = {
        {.code = 30, .symbols = {0x61, 0x41, 0xe5, 0xc5}, .caps = true}, /* a A å Å */
        {.code = 16, .symbols = {0x71, 0x51}, .caps = true},
        {.code = 1, .symbols = {0xff1b}},
        {.code = 42, .symbols = {0xffe1}},
    };
    CHECK(mwm_server_keymap(s, keys, 4));
    drain(s, &a);
    mwm_msg m = event(&a);
    CHECK(m.object == sa.keyboard && m.opcode == KEYBOARD_KEYMAP && mwm_get_uint(&m) == 1);
    int fd = mwm_get_fd(&m);
    uint32_t size = mwm_get_uint(&m);
    CHECK(fd >= 0 && size > 0);
    char *text = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    CHECK(text != MAP_FAILED && text[size - 1] == '\0');
    CHECK(strstr(text, "<K30> = 38;"));                              /* X's number for it: 8 more */
    CHECK(strstr(text, "key <K30> { type = \"FOUR_LEVEL_ALPHABETIC\", [ 0x61, 0x41, 0xe5, 0xc5 ] };"));
    CHECK(strstr(text, "key <K16> { type = \"ALPHABETIC\", [ 0x71, 0x51 ] };"));
    CHECK(strstr(text, "key <K1> { type = \"ONE_LEVEL\", [ 0xff1b ] };"));
    CHECK(strstr(text, "modifier_map Shift { <K42> };"));
    CHECK(!strstr(text, "<K31>")); /* a key the table does not have */
    munmap(text, size);
    close(fd);

    /* A table that cannot be a keyboard is refused, and the keys stay. */
    static const mwm_key twice[] = {{.code = 30, .symbols = {0x61}}, {.code = 30, .symbols = {0x62}}};
    static const mwm_key far[] = {{.code = 700, .symbols = {0x61}}};
    static const mwm_key empty[] = {{.code = 30}};
    CHECK(!mwm_server_keymap(s, twice, 2));
    CHECK(!mwm_server_keymap(s, far, 1));
    CHECK(!mwm_server_keymap(s, empty, 1));
    CHECK(!mwm_server_keymap(s, keys, 0));
    CHECK(!mwm_server_keymap(s, keys, MWM_MAX_KEYS + 1));
    drain(s, &a);
    CHECK(no_event(&a));
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

int main(void) {
    test_the_pointer_is_where_the_mac_says();
    test_the_keyboard_follows_the_window_in_front();
    test_a_window_that_goes_has_the_keys_no_more();
    test_a_late_keyboard_learns_where_it_is();
    test_an_old_seat_hears_only_what_it_knows();
    test_a_seat_misused_drops_the_program();
    test_the_keys_are_what_the_mac_says();
    printf("test_wm_seat: %d checks passed\n", checks);
    return 0;
}
