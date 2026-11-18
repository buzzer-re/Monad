/*
 * test_wm_server.c — the window manager's Wayland server (GuestWM/mwm_server)
 * against a client that speaks the wire format by hand: a window gets its
 * place on the display and its pixels are copied there; a client that
 * breaks the protocol is told and dropped, and takes nothing with it.
 */
#include "wm_test_client.h"

/* A window is copied to its place; a second one stands beside it; when the
 * first goes, its place is cleared and the other stays where it is. */
static void test_windows_stand_side_by_side(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    window one = open_window(s, &a, "One", "app.one", 0x00112200, 64, 32);
    CHECK(no_event(&a));
    mwm_window list[4];
    CHECK(mwm_server_windows(s, list, 4) == 1);
    CHECK(list[0].x == 0 && list[0].y == 0 && list[0].width == 64 && list[0].height == 32);
    CHECK(strcmp(list[0].title, "One") == 0 && strcmp(list[0].app_id, "app.one") == 0);
    CHECK(at(0, 0) == 0xff112200 && at(1, 0) == 0xff112201 && at(63, 31) == (0xff112200u | ((63 + 31 * 64) & 0xff)));
    CHECK(at(64, 0) == 0 && at(0, 32) == 0); /* nothing beside or under it */
    CHECK(presented >= 1 && last_x == 0 && last_y == 0 && last_w == 64 && last_h == 32);
    uint32_t generation = mwm_server_generation(s);

    client b = connect_client(s);
    window two = open_window(s, &b, "Two", "app.two", 0x00330000, 100, 50);
    CHECK(mwm_server_windows(s, list, 4) == 2);
    CHECK(list[1].x == 64 + MWM_GAP && list[1].y == 0 && list[1].width == 100 && list[1].height == 50);
    CHECK(at(64 + MWM_GAP, 0) == 0xff330000 && at(64 + MWM_GAP + 99, 49) == (0xff330000u | ((99 + 49 * 100) & 0xff)));
    CHECK(at(0, 0) == 0xff112200); /* the first is as it was */
    CHECK(mwm_server_generation(s) != generation);
    CHECK(list[0].id != list[1].id);
    (void)two;

    /* The first window's program asks when to draw again, and is told at the next frame. */
    uint32_t callback = a.next++;
    request(&a, one.surface, 3, 1, callback); /* frame */
    request(&a, one.surface, 6, 0);
    pump(s, &a);
    CHECK(no_event(&a));
    mwm_server_frame(s, 1234);
    pump(s, &a);
    mwm_msg m = event(&a);
    CHECK(m.object == callback && m.opcode == 0 && mwm_get_uint(&m) == 1234);
    m = event(&a);
    CHECK(m.object == 1 && m.opcode == DISPLAY_DELETE_ID && mwm_get_uint(&m) == callback);

    /* The first program ends: its window's place is empty again. */
    mwm_conn_free(a.c);
    mwm_server_service(s, a.server_fd, true, false);
    CHECK(mwm_server_windows(s, list, 4) == 1);
    CHECK(strcmp(list[0].title, "Two") == 0 && list[0].x == 64 + MWM_GAP);
    CHECK(at(0, 0) == 0 && at(63, 31) == 0);
    CHECK(at(64 + MWM_GAP, 0) == 0xff330000);
    int fds[4];
    bool wants[4];
    CHECK(mwm_server_sockets(s, fds, wants, 4) == 1 && fds[0] == b.server_fd);
    mwm_conn_free(b.c);
    mwm_server_free(s);
}

/* A new buffer replaces the old one, which the program gets back. */
static void test_a_new_buffer_releases_the_old_one(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    window v = open_window(s, &a, "W", "app", 0x00445500, 20, 10);
    uint32_t second = a.next++;
    request(&a, v.pool, 0, 6, second, 0, 10, 10, 40, 1); /* the left half of the same pixels, as a buffer of its own */
    request(&a, v.surface, 1, 3, second, 0, 0);
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    mwm_msg m = event(&a);
    CHECK(m.object == v.buffer && m.opcode == 0); /* wl_buffer.release */
    mwm_window list[2];
    CHECK(mwm_server_windows(s, list, 2) == 1 && list[0].width == 10 && list[0].height == 10);
    CHECK(at(9, 9) != 0 && at(10, 0) == 0); /* what the larger one left is cleared */
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

/* What a broken or hostile program gets: an error and the door. */
static void test_a_client_that_breaks_the_protocol_is_dropped(void) {
    uint32_t object;
    mwm_server *s = server();

    client k = connect_client(s);
    request(&k, 999, 0, 0); /* an object that does not exist */
    CHECK(dropped_with(s, &k, &object) == ERROR_INVALID_OBJECT && object == 999);

    k = connect_client(s);
    request(&k, k.compositor, 77, 0); /* a request the interface does not have */
    CHECK(dropped_with(s, &k, &object) == ERROR_INVALID_METHOD && object == k.compositor);

    k = connect_client(s);
    request(&k, k.compositor, 0, 1, k.compositor); /* a new object under an id in use */
    CHECK(dropped_with(s, &k, &object) == ERROR_INVALID_OBJECT);

    k = connect_client(s);
    request(&k, k.compositor, 0, 1, 0x7fffffff); /* an id far beyond what a client may have */
    CHECK(dropped_with(s, &k, &object) == ERROR_NO_MEMORY);

    k = connect_client(s);
    request(&k, k.compositor, 0, 0); /* create_surface without its argument */
    CHECK(dropped_with(s, &k, &object) == ERROR_INVALID_METHOD);

    k = connect_client(s);
    request(&k, k.wm, 2, 2, k.next, k.shm); /* get_xdg_surface of something that is no surface */
    CHECK(dropped_with(s, &k, &object) == ERROR_INVALID_OBJECT);

    /* A pool said to be larger than its file: reading it would kill the window manager. */
    k = connect_client(s);
    int fd = pixel_file(0, 16);
    mwm_put_begin(k.c, k.shm, 0);
    mwm_put_uint(k.c, k.next++);
    mwm_put_fd(k.c, fd);
    mwm_put_int(k.c, 1 << 20);
    mwm_put_end(k.c);
    close(fd);
    CHECK(dropped_with(s, &k, &object) >= 0);

    /* A buffer that reaches past its pool, each way. */
    static const int32_t bad[][5] = {
        {0, 64, 64, 256, 1},           /* more rows than the pool has */
        {-4, 4, 4, 16, 1},             /* before its start */
        {0, 4, 4, 8, 1},               /* rows shorter than their pixels */
        {0, 0x7fffffff, 2, 0x7ffffffc, 1}, /* sizes that overflow */
        {0, 4, 4, 16, 0x34325258},     /* a format never offered */
        {0, 0, 4, 16, 1},              /* no width */
    };
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        k = connect_client(s);
        fd = pixel_file(0, 16);
        uint32_t pool = k.next++;
        mwm_put_begin(k.c, k.shm, 0);
        mwm_put_uint(k.c, pool);
        mwm_put_fd(k.c, fd);
        mwm_put_int(k.c, 64);
        mwm_put_end(k.c);
        close(fd);
        request(&k, pool, 0, 6, k.next++, (uint32_t)bad[i][0], (uint32_t)bad[i][1], (uint32_t)bad[i][2], (uint32_t)bad[i][3],
                (uint32_t)bad[i][4]);
        CHECK(dropped_with(s, &k, &object) >= 0);
    }

    CHECK(mwm_server_windows(s, NULL, 0) == 0);
    bool clean = true;
    for (int i = 0; i < W * H; i++) clean = clean && pixels[i] == 0;
    CHECK(clean); /* nothing of theirs on the display */
    mwm_server_free(s);
}

/* A window larger than what is left of the display is cut at its edge. */
static void test_a_window_too_large_is_cut_at_the_edge(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    (void)open_window(s, &a, "Wide", "app", 0x00777700, 500, 250);
    mwm_window list[2];
    CHECK(mwm_server_windows(s, list, 2) == 1);
    CHECK(list[0].width == W && list[0].height == H); /* what of it is on the display */
    CHECK(at(W - 1, H - 1) != 0);
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

/* No more programs than there may be. */
static void test_clients_are_bounded(void) {
    mwm_server *s = server();
    int kept[MWM_MAX_CLIENTS + 1][2];
    for (int i = 0; i <= MWM_MAX_CLIENTS; i++) {
        CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, kept[i]) == 0);
        bool ok = mwm_server_add_client(s, kept[i][1]);
        CHECK(ok == (i < MWM_MAX_CLIENTS));
    }
    for (int i = 0; i <= MWM_MAX_CLIENTS; i++) close(kept[i][0]);
    mwm_server_free(s);
}

/* A program that asks who draws its window's frame is told the Mac does
 * (it then draws no title bar of its own), whatever it would rather. */
static void test_the_frame_is_the_macs_to_draw(void) {
    enum { CLIENT_SIDE = 1, SERVER_SIDE = 2 };
    mwm_server *s = server();
    client a = connect_client(s);
    uint32_t manager = bind_global(&a, "zxdg_decoration_manager_v1", 1);
    window v = open_window(s, &a, "W", "app", 0x00110000, 64, 32);
    uint32_t decoration = a.next++;
    request(&a, manager, 1, 2, decoration, v.toplevel); /* get_toplevel_decoration */
    pump(s, &a);
    mwm_msg m = event(&a);
    CHECK(m.object == decoration && m.opcode == 0 && mwm_get_uint(&m) == SERVER_SIDE && mwm_msg_done(&m));
    m = event(&a);
    CHECK(m.object == v.toplevel && m.opcode == 0); /* and a configure, which the mode comes with */
    m = event(&a);
    CHECK(m.object == v.xdg && m.opcode == 0);
    CHECK(no_event(&a));
    request(&a, decoration, 1, 1, CLIENT_SIDE); /* set_mode: it would rather draw its own */
    pump(s, &a);
    m = event(&a);
    CHECK(m.object == decoration && m.opcode == 0 && mwm_get_uint(&m) == SERVER_SIDE);
    m = event(&a);
    CHECK(m.object == v.toplevel && m.opcode == 0);
    m = event(&a);
    CHECK(m.object == v.xdg && m.opcode == 0);
    request(&a, decoration, 2, 0); /* unset_mode */
    pump(s, &a);
    m = event(&a);
    CHECK(m.object == decoration && m.opcode == 0 && mwm_get_uint(&m) == SERVER_SIDE);
    while (mwm_conn_next(a.c, &m)) {}

    /* The window goes before its decoration object: what is asked of it then goes nowhere, and breaks nothing. */
    request(&a, v.toplevel, 0, 0);
    request(&a, decoration, 1, 1, SERVER_SIDE);
    request(&a, decoration, 0, 0);
    request(&a, manager, 0, 0);
    pump(s, &a);
    while (mwm_conn_next(a.c, &m)) CHECK(m.object == 1 && m.opcode == DISPLAY_DELETE_ID);

    uint32_t object;
    manager = bind_global(&a, "zxdg_decoration_manager_v1", 1);
    request(&a, manager, 1, 2, a.next++, v.surface); /* of something that is no window */
    CHECK(dropped_with(s, &a, &object) == ERROR_INVALID_OBJECT && object == manager);
    mwm_server_free(s);
}

int main(void) {
    test_windows_stand_side_by_side();
    test_a_new_buffer_releases_the_old_one();
    test_a_client_that_breaks_the_protocol_is_dropped();
    test_a_window_too_large_is_cut_at_the_edge();
    test_clients_are_bounded();
    test_the_frame_is_the_macs_to_draw();
    printf("test_wm_server: %d checks passed\n", checks);
    return 0;
}
