/*
 * test_wm_frame.c — who draws a window's title bar, and what a program
 * asks of its own window (GuestWM/mwm_shell). A program that draws a bar
 * of its own (GTK's header bars) is told apart from one that leaves the
 * frame to the Mac, with the colour its bar has, so that the Mac's title
 * bar can continue it; and a drag of that bar, or a double click on it,
 * reaches the Mac as a wish, only from the window the user is in.
 */
#include "wm_test_client.h"

enum { KDE_NONE = 0, KDE_CLIENT = 1, KDE_SERVER = 2 };

static mwm_window listed(mwm_server *s, uint32_t id) {
    mwm_window list[MWM_MAX_WINDOWS];
    int n = mwm_server_windows(s, list, MWM_MAX_WINDOWS);
    for (int i = 0; i < n; i++)
        if (list[i].id == id) return list[i];
    CHECK(!"the window is on the display");
    return (mwm_window){0};
}

static void forget(client *k) {
    mwm_msg m;
    while (mwm_conn_next(k->c, &m)) {}
}

/* A program that says nothing of its frame draws its own bar (as Wayland
 * has it); one that asks who draws it is told the Mac does. */
static void test_a_program_that_draws_its_own_bar_is_told_apart(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    window quiet = open_window(s, &a, "Quiet", "app", 0x00203040, 64, 32);
    mwm_window w = listed(s, quiet.id);
    CHECK(w.own_bar);
    /* The colour at the middle of its top edge, two pixels down: pixel 2 * 64 + 32 of the test's buffer. */
    CHECK(w.bar_color == 0x00203040 + ((2 * 64 + 32) & 0xff));

    /* xdg-decoration: the Mac draws the frame, and the program none. */
    uint32_t generation = mwm_server_generation(s);
    uint32_t manager = bind_global(&a, "zxdg_decoration_manager_v1", 1), decoration = a.next++;
    request(&a, manager, 1, 2, decoration, quiet.toplevel);
    pump(s, &a);
    forget(&a);
    CHECK(!listed(s, quiet.id).own_bar);
    CHECK(mwm_server_generation(s) != generation); /* the Mac is told */
    /* The decoration object gone, the program is on its own again. */
    request(&a, decoration, 0, 0);
    pump(s, &a);
    forget(&a);
    CHECK(listed(s, quiet.id).own_bar);

    /* It draws something else at the top: the colour follows, and the Mac is told. */
    generation = mwm_server_generation(s);
    uint32_t pool = a.next++, buffer = a.next++;
    make_buffer(&a, pool, buffer, 0x00a0b0c0, 64, 32);
    request(&a, quiet.surface, 1, 3, buffer, 0, 0);
    request(&a, quiet.surface, 2, 4, 0, 0, 64, 32);
    request(&a, quiet.surface, 6, 0);
    pump(s, &a);
    forget(&a);
    CHECK(listed(s, quiet.id).bar_color == 0x00a0b0c0 + ((2 * 64 + 32) & 0xff));
    CHECK(mwm_server_generation(s) != generation);
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

/* GTK asks through KDE's protocol: a window with a header bar says it
 * draws it (client), a plain one leaves the frame to the server. */
static void test_gtk_says_which_of_its_windows_have_a_bar(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    uint32_t manager = bind_global(&a, "org_kde_kwin_server_decoration_manager", 1);
    pump(s, &a);
    mwm_msg m = event(&a);
    CHECK(m.object == manager && m.opcode == 0 && mwm_get_uint(&m) == KDE_SERVER); /* default_mode: the Mac draws frames */
    window v = open_window(s, &a, "W", "app", 0x00112233, 64, 32);
    forget(&a);
    uint32_t decoration = a.next++;
    request(&a, manager, 0, 2, decoration, v.surface); /* create */
    pump(s, &a);
    m = event(&a);
    CHECK(m.object == decoration && m.opcode == 0 && mwm_get_uint(&m) == KDE_SERVER);
    CHECK(!listed(s, v.id).own_bar);

    request(&a, decoration, 1, 1, KDE_CLIENT); /* request_mode: it has a header bar */
    pump(s, &a);
    m = event(&a);
    CHECK(m.object == decoration && m.opcode == 0 && mwm_get_uint(&m) == KDE_CLIENT); /* granted: its bar is its own */
    CHECK(listed(s, v.id).own_bar);
    request(&a, decoration, 1, 1, KDE_SERVER);
    pump(s, &a);
    m = event(&a);
    CHECK(mwm_get_uint(&m) == KDE_SERVER && !listed(s, v.id).own_bar);
    request(&a, decoration, 1, 1, 77); /* no mode there is: nothing changes, nothing is said */
    pump(s, &a);
    CHECK(no_event(&a) && !listed(s, v.id).own_bar);
    request(&a, decoration, 0, 0); /* release */
    pump(s, &a);
    forget(&a);
    request(&a, decoration, 1, 1, KDE_CLIENT);
    uint32_t object;
    CHECK(dropped_with(s, &a, &object) == ERROR_INVALID_OBJECT);

    a = connect_client(s);
    manager = bind_global(&a, "org_kde_kwin_server_decoration_manager", 1);
    request(&a, manager, 0, 2, a.next++, a.compositor); /* of what is no surface */
    CHECK(dropped_with(s, &a, &object) == ERROR_INVALID_OBJECT);
    a = connect_client(s);
    manager = bind_global(&a, "org_kde_kwin_server_decoration_manager", 1);
    request(&a, manager, 1, 0);
    CHECK(dropped_with(s, &a, &object) == ERROR_INVALID_METHOD);
    mwm_server_free(s);
}

static uint32_t asked_window;
static int asked_what, asked_times;
static void asked(void *ctx, uint32_t id, mwm_ask what) {
    (void)ctx;
    asked_window = id;
    asked_what = (int)what;
    asked_times++;
}

/* Dragging a program's own bar, or double-clicking it, is the program
 * asking: the Mac's window moves, or zooms. Only the window the user is
 * in gets to ask. */
static void test_a_program_asks_for_its_window_to_move_and_zoom(void) {
    mwm_server *s = server();
    mwm_server_on_ask(s, asked, NULL);
    asked_times = 0;
    client a = connect_client(s), b = connect_client(s);
    uint32_t seat = bind_global(&a, "wl_seat", 5);
    pump(s, &a);
    forget(&a);
    window wa = open_window(s, &a, "A", "app.a", 0x00110000, 64, 32), wb = open_window(s, &b, "B", "app.b", 0x00001100, 64, 32);
    forget(&a);
    forget(&b);

    request(&a, wa.toplevel, 5, 2, seat, 1); /* move, with the pointer elsewhere: not the user's doing */
    request(&a, wa.toplevel, 9, 0);          /* set_maximized, likewise */
    pump(s, &a);
    CHECK(asked_times == 0);

    mwm_server_pointer(s, wa.id, 256, 256, 10);
    request(&a, wa.toplevel, 5, 2, seat, 1);
    pump(s, &a);
    CHECK(asked_times == 1 && asked_window == wa.id && asked_what == MWM_ASK_MOVE);
    request(&a, wa.toplevel, 9, 0);
    pump(s, &a);
    CHECK(asked_times == 2 && asked_what == MWM_ASK_ZOOM);
    request(&a, wa.toplevel, 10, 0); /* unset_maximized */
    pump(s, &a);
    CHECK(asked_times == 3 && asked_what == MWM_ASK_UNZOOM);
    request(&b, wb.toplevel, 13, 0); /* another program's window, which the pointer is not over */
    pump(s, &b);
    CHECK(asked_times == 3);

    /* The window in front may ask as well (a key did it): minimize. */
    mwm_server_pointer(s, 0, 0, 0, 20);
    mwm_server_focus(s, wb.id);
    request(&b, wb.toplevel, 13, 0);
    pump(s, &b);
    CHECK(asked_times == 4 && asked_window == wb.id && asked_what == MWM_ASK_MINIMIZE);

    /* What the Mac does not do for a program: its window menu, resizing by its own edge, full screen. */
    mwm_server_pointer(s, wa.id, 256, 256, 30);
    request(&a, wa.toplevel, 4, 4, seat, 1, 5, 5);
    request(&a, wa.toplevel, 6, 3, seat, 1, 8);
    request(&a, wa.toplevel, 11, 1, 0);
    request(&a, wa.toplevel, 12, 0);
    pump(s, &a);
    CHECK(asked_times == 4);
    drain(s, &a);
    uint32_t object;
    request(&a, wa.toplevel, 14, 0);
    CHECK(dropped_with(s, &a, &object) == ERROR_INVALID_METHOD);
    mwm_conn_free(b.c);
    mwm_server_free(s);
}

/* Every edge of a window meets the Mac's frame: a program told so (GTK)
 * draws square corners and no shadow, where its round ones would show
 * what is behind the window on the sheet. */
static void test_a_window_is_told_its_edges_meet_a_frame(void) {
    enum { ACTIVATED = 4, TILED_LEFT = 5, TILED_RIGHT = 6, TILED_TOP = 7, TILED_BOTTOM = 8 };
    mwm_server *s = server();
    client a = connect_client(s);
    window v = open_window(s, &a, "W", "app", 0x00112233, 64, 32);
    forget(&a);
    mwm_server_focus(s, v.id);
    drain(s, &a);
    mwm_msg m;
    bool told = false;
    while (mwm_conn_next(a.c, &m)) {
        if (m.object != v.toplevel || m.opcode != 0) continue;
        (void)mwm_get_int(&m);
        (void)mwm_get_int(&m);
        uint32_t len = 0, seen = 0;
        const uint8_t *states = mwm_get_array(&m, &len);
        CHECK(states && len % 4 == 0 && mwm_msg_done(&m));
        for (uint32_t i = 0; i < len; i += 4) {
            uint32_t state;
            memcpy(&state, states + i, 4);
            CHECK(state == ACTIVATED || (state >= TILED_LEFT && state <= TILED_BOTTOM));
            seen |= 1u << state;
        }
        CHECK(seen == (1u << ACTIVATED | 1u << TILED_LEFT | 1u << TILED_RIGHT | 1u << TILED_TOP | 1u << TILED_BOTTOM));
        told = true;
    }
    CHECK(told);
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

int main(void) {
    test_a_program_that_draws_its_own_bar_is_told_apart();
    test_gtk_says_which_of_its_windows_have_a_bar();
    test_a_program_asks_for_its_window_to_move_and_zoom();
    test_a_window_is_told_its_edges_meet_a_frame();
    printf("test_wm_frame: %d checks passed\n", checks);
    return 0;
}
