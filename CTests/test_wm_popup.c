/*
 * test_wm_popup.c — menus and other popups (GuestWM/mwm_shell: xdg_popup
 * and xdg_positioner): a popup is a window of its own on the sheet, told
 * with the window it belongs to and where it stands on it; it takes the
 * keyboard when it asks to, gives it back when it goes, and goes when the
 * Mac says the user clicked elsewhere.
 */
#include "wm_test_client.h"

#include "mwm_ctl.h"

enum { ANCHOR_NONE = 0, TOP, BOTTOM, LEFT, RIGHT, TOP_LEFT, BOTTOM_LEFT, TOP_RIGHT, BOTTOM_RIGHT };
enum { POPUP_CONFIGURE = 0, POPUP_DONE = 1 };
enum { KEYBOARD_ENTER = 1, KEYBOARD_LEAVE = 2, KEYBOARD_KEY = 3 };

typedef struct {
    uint32_t surface, xdg, popup, positioner, buffer;
    /* Where the server said it stands on its parent, and how large. */
    int32_t x, y, width, height;
    uint32_t id;
} popup;

/* A positioner: a popup of w × h at the anchor rectangle's `anchor`, growing towards `gravity`, moved by the offset. */
static uint32_t positioner(client *k, int w, int h, int ax, int ay, int aw, int ah, uint32_t anchor, uint32_t gravity, int ox, int oy) {
    uint32_t id = k->next++;
    request(k, k->wm, 1, 1, id);                                                      /* create_positioner */
    request(k, id, 1, 2, (uint32_t)w, (uint32_t)h);                                   /* set_size */
    request(k, id, 2, 4, (uint32_t)ax, (uint32_t)ay, (uint32_t)aw, (uint32_t)ah);     /* set_anchor_rect */
    request(k, id, 3, 1, anchor);                                                     /* set_anchor */
    request(k, id, 4, 1, gravity);                                                    /* set_gravity */
    request(k, id, 6, 2, (uint32_t)ox, (uint32_t)oy);                                 /* set_offset */
    return id;
}

/* A popup on `parent`, as far as its first configure: where and how large it is to be. */
static popup ask_popup(mwm_server *s, client *k, uint32_t parent_xdg, uint32_t positioner_id, uint32_t grab_seat) {
    popup p = {.surface = k->next++, .xdg = k->next++, .popup = k->next++, .positioner = positioner_id};
    request(k, k->compositor, 0, 1, p.surface);
    request(k, k->wm, 2, 2, p.xdg, p.surface);                    /* get_xdg_surface */
    request(k, p.xdg, 2, 3, p.popup, parent_xdg, positioner_id);  /* get_popup */
    if (grab_seat) request(k, p.popup, 1, 2, grab_seat, 1);       /* grab */
    request(k, p.surface, 6, 0);                                  /* commit: asks for its configure */
    pump(s, k);
    mwm_msg m;
    bool configured = false;
    while (mwm_conn_next(k->c, &m)) {
        CHECK(m.object != 1 || m.opcode != DISPLAY_ERROR);
        if (m.object == p.popup && m.opcode == POPUP_CONFIGURE) {
            p.x = mwm_get_int(&m);
            p.y = mwm_get_int(&m);
            p.width = mwm_get_int(&m);
            p.height = mwm_get_int(&m);
            CHECK(mwm_msg_done(&m));
            configured = true;
        } else {
            int fd = mwm_get_fd(&m); /* a keymap's file, when a keyboard was asked for */
            if (fd >= 0) close(fd);
        }
    }
    CHECK(configured);
    return p;
}

/* The popup draws: it is on the sheet from then on. */
static void map_popup(mwm_server *s, client *k, popup *p, uint32_t color) {
    int before = mwm_server_windows(s, NULL, 0);
    uint32_t pool = k->next++;
    p->buffer = k->next++;
    make_buffer(k, pool, p->buffer, color, p->width, p->height);
    request(k, p->surface, 1, 3, p->buffer, 0, 0);
    request(k, p->surface, 2, 4, 0, 0, (uint32_t)p->width, (uint32_t)p->height);
    request(k, p->surface, 6, 0);
    pump(s, k);
    mwm_window list[MWM_MAX_WINDOWS];
    int n = mwm_server_windows(s, list, MWM_MAX_WINDOWS);
    CHECK(n == before + 1);
    p->id = list[n - 1].id;
}

static mwm_window find_window(mwm_server *s, uint32_t id) {
    mwm_window list[MWM_MAX_WINDOWS];
    int n = mwm_server_windows(s, list, MWM_MAX_WINDOWS);
    for (int i = 0; i < n; i++)
        if (list[i].id == id) return list[i];
    CHECK(!"the window is on the display");
    return list[0];
}

static void forget(client *k) {
    mwm_msg m;
    while (mwm_conn_next(k->c, &m)) {
        int fd = mwm_get_fd(&m);
        if (fd >= 0) close(fd);
        CHECK(m.object != 1 || m.opcode != DISPLAY_ERROR);
    }
}

/* A menu under a button: the popup is told where it stands on its window,
 * gets a place of its own on the sheet, and is told to the Mac with the
 * window it belongs to. */
static void test_a_popup_is_a_window_on_its_parent(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    window v = open_window(s, &a, "W", "app", 0x00101000, 120, 60);
    /* A button at (10, 20), 80 wide and 24 high: the menu hangs from its bottom left corner, down and to the right. */
    popup p = ask_popup(s, &a, v.xdg, positioner(&a, 60, 40, 10, 20, 80, 24, BOTTOM_LEFT, BOTTOM_RIGHT, 0, 0), 0);
    CHECK(p.x == 10 && p.y == 44 && p.width == 60 && p.height == 40);
    CHECK(mwm_server_windows(s, NULL, 0) == 1); /* nothing of it to show before it drew */
    map_popup(s, &a, &p, 0x00aa0000);
    mwm_window w = find_window(s, p.id), parent = find_window(s, v.id);
    CHECK(w.parent == v.id && w.offset_x == 10 && w.offset_y == 44 && w.width == 60 && w.height == 40);
    CHECK(parent.parent == 0 && parent.offset_x == 0 && parent.offset_y == 0);
    /* A place of its own: not on its parent's pixels, which are as they were. */
    CHECK(w.x >= parent.x + parent.width + MWM_GAP || w.y >= parent.y + parent.height + MWM_GAP);
    CHECK((at(w.x, w.y) & 0x00ffff00) == 0x00aa0000 && at(parent.x + 10, parent.y + 44) == (0xff101000u | ((10 + 44 * 120) & 0xff)));

    /* The pointer over the popup is the popup's. */
    uint32_t seat = bind_global(&a, "wl_seat", 5), pointer = a.next++;
    request(&a, seat, 0, 1, pointer);
    pump(s, &a);
    forget(&a);
    mwm_server_pointer(s, p.id, 5 << 8, 6 << 8, 10);
    drain(s, &a);
    mwm_msg m = event(&a);
    CHECK(m.object == pointer && m.opcode == 0); /* enter */
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == p.surface && mwm_get_int(&m) == 5 << 8 && mwm_get_int(&m) == 6 << 8);
    forget(&a);

    /* The popup goes: its place is empty, its window is told gone. */
    uint32_t generation = mwm_server_generation(s);
    request(&a, p.popup, 0, 0);
    request(&a, p.xdg, 0, 0);
    request(&a, p.surface, 0, 0);
    pump(s, &a);
    forget(&a);
    CHECK(mwm_server_windows(s, NULL, 0) == 1 && mwm_server_generation(s) != generation);
    CHECK(at(w.x, w.y) == 0);
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

/* Where a popup stands, for each way a program can ask. */
static void test_a_popup_stands_where_its_positioner_says(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    window v = open_window(s, &a, "W", "app", 0, 120, 60);
    static const struct {
        uint32_t anchor, gravity;
        int ox, oy, x, y;
    } cases[] = {
        /* The anchor rectangle is (40, 20) 20 × 10; the popup is 30 × 16. */
        {ANCHOR_NONE, ANCHOR_NONE, 0, 0, 50 - 15, 25 - 8}, /* centre on centre */
        {BOTTOM_LEFT, BOTTOM_RIGHT, 0, 0, 40, 30},         /* a menu under a button */
        {BOTTOM_RIGHT, BOTTOM_LEFT, 0, 0, 60 - 30, 30},    /* the same, from the right */
        {TOP_RIGHT, BOTTOM_RIGHT, 0, 0, 60, 20},           /* a submenu beside its item */
        {TOP_LEFT, BOTTOM_LEFT, 0, 0, 40 - 30, 20},        /* a submenu on the left */
        {TOP, TOP, 0, 0, 50 - 15, 20 - 16},                /* a tooltip above */
        {BOTTOM, BOTTOM, 0, 0, 50 - 15, 30},               /* a tooltip below */
        {LEFT, LEFT, 0, 0, 40 - 30, 25 - 8},
        {RIGHT, RIGHT, 0, 0, 60, 25 - 8},
        {TOP_LEFT, TOP_LEFT, 0, 0, 40 - 30, 20 - 16},
        {BOTTOM_RIGHT, BOTTOM_RIGHT, 3, -2, 63, 28},       /* moved by its offset */
        {TOP_LEFT, BOTTOM_RIGHT, -500, -500, 40 - 500, 20 - 500}, /* off the window, where it asked */
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        popup p = ask_popup(s, &a, v.xdg, positioner(&a, 30, 16, 40, 20, 20, 10, cases[i].anchor, cases[i].gravity, cases[i].ox, cases[i].oy), 0);
        if (p.x != cases[i].x || p.y != cases[i].y) fprintf(stderr, "case %zu: at %d,%d, expected %d,%d\n", i, p.x, p.y, cases[i].x, cases[i].y);
        CHECK(p.x == cases[i].x && p.y == cases[i].y && p.width == 30 && p.height == 16);
        request(&a, p.popup, 0, 0);
        request(&a, p.xdg, 0, 0);
        request(&a, p.surface, 0, 0);
        request(&a, p.positioner, 0, 0);
    }
    pump(s, &a);
    forget(&a);

    /* On a window drawn at 2 (and with a shadow the program draws around it): the Mac is told in pixels from the window proper. */
    request(&a, v.surface, 8, 1, 2);            /* set_buffer_scale */
    request(&a, v.xdg, 3, 4, 4, 2, 50, 26);     /* set_window_geometry */
    request(&a, v.surface, 6, 0);
    popup p = ask_popup(s, &a, v.xdg, positioner(&a, 20, 10, 10, 5, 8, 4, BOTTOM_LEFT, BOTTOM_RIGHT, 0, 0), 0);
    CHECK(p.x == 10 && p.y == 9);
    request(&a, p.surface, 8, 1, 2);
    p.width *= 2; /* it draws 2 pixels to a unit, as its window does */
    p.height *= 2;
    map_popup(s, &a, &p, 0x00bb0000);
    mwm_window w = find_window(s, p.id);
    CHECK(w.scale == 2 && w.width == 40 && w.height == 20 && w.offset_x == 20 && w.offset_y == 18);
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

/* A menu takes the keyboard while it is up (its program asked to grab),
 * and the window it belongs to has it back when the menu goes. A popup of
 * a popup works the same way. */
static void test_a_menu_has_the_keyboard_while_it_is_up(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    uint32_t seat = bind_global(&a, "wl_seat", 5), keyboard = a.next++;
    request(&a, seat, 1, 1, keyboard);
    pump(s, &a);
    forget(&a);
    window v = open_window(s, &a, "W", "app", 0, 120, 60);
    mwm_server_focus(s, v.id);
    drain(s, &a);
    forget(&a);

    popup menu = ask_popup(s, &a, v.xdg, positioner(&a, 60, 40, 0, 0, 10, 10, BOTTOM_LEFT, BOTTOM_RIGHT, 0, 0), seat);
    map_popup(s, &a, &menu, 0x00aa0000);
    mwm_msg m = event(&a);
    CHECK(m.object == keyboard && m.opcode == KEYBOARD_LEAVE);
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == v.surface);
    m = event(&a);
    CHECK(m.object == keyboard && m.opcode == KEYBOARD_ENTER);
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == menu.surface);
    forget(&a); /* the modifiers, and nothing telling the window it is no longer in front */
    mwm_server_key(s, 108, true, 5); /* Down, in the menu */
    drain(s, &a);
    m = event(&a);
    CHECK(m.object == keyboard && m.opcode == KEYBOARD_KEY);
    mwm_server_key(s, 108, false, 6);
    drain(s, &a);
    forget(&a);

    /* A submenu, from the menu. */
    popup sub = ask_popup(s, &a, menu.xdg, positioner(&a, 30, 20, 50, 0, 10, 10, TOP_RIGHT, BOTTOM_RIGHT, 0, 0), seat);
    map_popup(s, &a, &sub, 0x00bb0000);
    CHECK(find_window(s, sub.id).parent == menu.id);
    m = event(&a);
    CHECK(m.object == keyboard && m.opcode == KEYBOARD_LEAVE);
    m = event(&a);
    CHECK(m.object == keyboard && m.opcode == KEYBOARD_ENTER);
    (void)mwm_get_uint(&m);
    CHECK(mwm_get_uint(&m) == sub.surface);
    forget(&a);

    /* The submenu goes: the menu has the keyboard. Then the menu: the window. */
    request(&a, sub.popup, 0, 0);
    pump(s, &a);
    bool entered = false;
    while (mwm_conn_next(a.c, &m)) {
        if (m.object == keyboard && m.opcode == KEYBOARD_ENTER) {
            (void)mwm_get_uint(&m);
            entered = mwm_get_uint(&m) == menu.surface;
        }
    }
    CHECK(entered);
    request(&a, menu.popup, 0, 0);
    pump(s, &a);
    entered = false;
    while (mwm_conn_next(a.c, &m)) {
        if (m.object == keyboard && m.opcode == KEYBOARD_ENTER) {
            (void)mwm_get_uint(&m);
            entered = mwm_get_uint(&m) == v.surface;
        }
    }
    CHECK(entered);
    mwm_server_key(s, 30, true, 9);
    drain(s, &a);
    m = event(&a);
    CHECK(m.object == keyboard && m.opcode == KEYBOARD_KEY); /* typing reaches the window again */
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

/* The Mac says the user clicked elsewhere: the program is told its popup is
 * done with, the one on top first; and a window that goes takes its popups. */
static void test_popups_are_dismissed(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    window v = open_window(s, &a, "W", "app", 0, 120, 60);
    popup menu = ask_popup(s, &a, v.xdg, positioner(&a, 60, 40, 0, 0, 10, 10, BOTTOM_LEFT, BOTTOM_RIGHT, 0, 0), 0);
    map_popup(s, &a, &menu, 0x00aa0000);
    popup sub = ask_popup(s, &a, menu.xdg, positioner(&a, 30, 20, 50, 0, 10, 10, TOP_RIGHT, BOTTOM_RIGHT, 0, 0), 0);
    map_popup(s, &a, &sub, 0x00bb0000);
    forget(&a);

    mwm_server_dismiss(s, v.id); /* every popup of that window */
    drain(s, &a);
    mwm_msg m = event(&a);
    CHECK(m.object == sub.popup && m.opcode == POPUP_DONE && mwm_msg_done(&m)); /* the one on top first */
    m = event(&a);
    CHECK(m.object == menu.popup && m.opcode == POPUP_DONE);
    CHECK(no_event(&a));
    mwm_server_dismiss(s, 9999); /* a window that is none */
    mwm_server_dismiss(s, 0);
    drain(s, &a);
    CHECK(no_event(&a));

    /* The window goes with its popups still up (a program that ends that way): nothing of them stays. */
    request(&a, v.toplevel, 0, 0);
    pump(s, &a);
    forget(&a);
    CHECK(mwm_server_windows(s, NULL, 0) == 0);
    bool clean = true;
    for (int i = 0; i < W * H; i++) clean = clean && pixels[i] == 0;
    CHECK(clean);
    /* What the program still says to them goes nowhere. */
    request(&a, sub.surface, 6, 0);
    request(&a, menu.popup, 0, 0);
    request(&a, sub.popup, 0, 0);
    pump(s, &a);
    forget(&a);
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

/* What a program may not ask of popups. */
static void test_popups_misused_drop_the_program(void) {
    mwm_server *s = server();
    uint32_t object;

    client k = connect_client(s);
    window v = open_window(s, &k, "W", "app", 0, 120, 60);
    uint32_t empty = k.next++, surface = k.next++, xdg = k.next++;
    request(&k, k.wm, 1, 1, empty); /* a positioner that says no size */
    request(&k, k.compositor, 0, 1, surface);
    request(&k, k.wm, 2, 2, xdg, surface);
    request(&k, xdg, 2, 3, k.next++, v.xdg, empty);
    CHECK(dropped_with(s, &k, &object) >= 0);

    k = connect_client(s);
    v = open_window(s, &k, "W", "app", 0, 120, 60);
    surface = k.next++;
    xdg = k.next++;
    request(&k, k.compositor, 0, 1, surface);
    request(&k, k.wm, 2, 2, xdg, surface);
    request(&k, xdg, 2, 3, k.next++, v.xdg, 4242); /* no positioner at all */
    CHECK(dropped_with(s, &k, &object) == ERROR_INVALID_OBJECT);

    k = connect_client(s);
    v = open_window(s, &k, "W", "app", 0, 120, 60);
    request(&k, v.xdg, 2, 3, k.next++, v.xdg, positioner(&k, 10, 10, 0, 0, 1, 1, 0, 0, 0, 0)); /* a window made its own popup */
    CHECK(dropped_with(s, &k, &object) >= 0);

    k = connect_client(s);
    uint32_t p = k.next++;
    request(&k, k.wm, 1, 1, p);
    request(&k, p, 1, 2, 0, 10); /* a size that is none */
    CHECK(dropped_with(s, &k, &object) >= 0 && object == p);

    k = connect_client(s);
    p = k.next++;
    request(&k, k.wm, 1, 1, p);
    request(&k, p, 3, 1, 99); /* an anchor that is none */
    CHECK(dropped_with(s, &k, &object) >= 0 && object == p);

    /* Popups of popups, deeper than any menu goes. */
    k = connect_client(s);
    v = open_window(s, &k, "W", "app", 0, 120, 60);
    uint32_t parent = v.xdg;
    for (int i = 0; i < 40; i++) {
        surface = k.next++;
        xdg = k.next++;
        request(&k, k.compositor, 0, 1, surface);
        request(&k, k.wm, 2, 2, xdg, surface);
        request(&k, xdg, 2, 3, k.next++, parent, positioner(&k, 4, 4, 0, 0, 1, 1, 0, 0, 0, 0));
        parent = xdg;
    }
    CHECK(dropped_with(s, &k, &object) >= 0);
    CHECK(mwm_server_windows(s, NULL, 0) == 0);
    mwm_server_free(s);
}

/* MonadHost is told a popup with the window it is on, and says when the user clicked away. */
static void test_the_mac_is_told_popups_and_dismisses_them(void) {
    mwm_server *s = server();
    mwm_ctl *c = mwm_ctl_new(s);
    client a = connect_client(s);
    window v = open_window(s, &a, "W", "app", 0, 120, 60);
    popup menu = ask_popup(s, &a, v.xdg, positioner(&a, 60, 40, 10, 20, 80, 24, BOTTOM_LEFT, BOTTOM_RIGHT, 0, -3), 0);
    map_popup(s, &a, &menu, 0x00aa0000);
    forget(&a);
    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0 && fcntl(sv[0], F_SETFL, O_NONBLOCK) == 0);
    mwm_ctl_attach(c, sv[1]);
    char text[2048], expected[200];
    ssize_t n = read(sv[0], text, sizeof text - 1);
    CHECK(n > 0);
    text[n] = 0;
    mwm_window w = find_window(s, menu.id);
    snprintf(expected, sizeof expected, "window %u %d %d 60 40 1 0 0 60 40 %u 10 41 - - -\n", menu.id, w.x, w.y, v.id);
    CHECK(strstr(text, expected) != NULL); /* a popup has no bar of its own to speak of */
    snprintf(expected, sizeof expected, "window %u 0 0 120 60 1 0 0 120 60 0 0 0 00002c app W\n", v.id);
    CHECK(strstr(text, expected) != NULL);

    snprintf(text, sizeof text, "dismiss %u\n", v.id);
    CHECK(write(sv[0], text, strlen(text)) == (ssize_t)strlen(text));
    mwm_ctl_service(c, true, true, 0);
    drain(s, &a);
    mwm_msg m = event(&a);
    CHECK(m.object == menu.popup && m.opcode == POPUP_DONE);
    close(sv[0]);
    mwm_conn_free(a.c);
    mwm_ctl_free(c);
    mwm_server_free(s);
}

int main(void) {
    test_a_popup_is_a_window_on_its_parent();
    test_a_popup_stands_where_its_positioner_says();
    test_a_menu_has_the_keyboard_while_it_is_up();
    test_popups_are_dismissed();
    test_popups_misused_drop_the_program();
    test_the_mac_is_told_popups_and_dismisses_them();
    printf("test_wm_popup: %d checks passed\n", checks);
    return 0;
}
