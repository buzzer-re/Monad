/*
 * test_wm_surface.c — what a window is made of (GuestWM/mwm_surface):
 * a surface and the subsurfaces on it, drawn where they stand and in their
 * order; only what the program says changed is copied; a program that
 * draws at twice the size says so; and where windows go on the display.
 */
#include "wm_test_client.h"

enum { XRGB = 1, ARGB = 0 };

/* A buffer of w × h pixels all of one color, in a pool of its own; the
 * file behind it is returned, to change what it holds. */
static int solid(client *k, uint32_t *buffer, uint32_t color, int w, int h, uint32_t format) {
    char path[] = "/tmp/monad-wm-test-XXXXXX";
    int fd = mkstemp(path);
    CHECK(fd >= 0);
    unlink(path);
    for (int i = 0; i < w * h; i++) CHECK(write(fd, &color, 4) == 4);
    uint32_t pool = k->next++;
    *buffer = k->next++;
    mwm_put_begin(k->c, k->shm, 0); /* create_pool */
    mwm_put_uint(k->c, pool);
    mwm_put_fd(k->c, fd);
    mwm_put_int(k->c, w * h * 4);
    mwm_put_end(k->c);
    request(k, pool, 0, 6, *buffer, 0, (uint32_t)w, (uint32_t)h, (uint32_t)w * 4, format);
    return fd;
}

static void show(client *k, uint32_t surface, uint32_t buffer, int w, int h) {
    request(k, surface, 1, 3, buffer, 0, 0);                    /* attach */
    request(k, surface, 2, 4, 0, 0, (uint32_t)w, (uint32_t)h);  /* damage */
    request(k, surface, 6, 0);                                  /* commit */
}

typedef struct {
    uint32_t surface, role, buffer;
} part;

/* A surface made a part of `parent`, at (x, y) on it. */
static part add_part(client *k, uint32_t subcompositor, uint32_t parent, int x, int y) {
    part p = {.surface = k->next++, .role = k->next++};
    request(k, k->compositor, 0, 1, p.surface);              /* create_surface */
    request(k, subcompositor, 1, 3, p.role, p.surface, parent); /* get_subsurface */
    request(k, p.role, 1, 2, (uint32_t)x, (uint32_t)y);      /* set_position */
    return p;
}

/* What open_window's pattern shows at (x, y) of a window `w` wide. */
static uint32_t pattern(uint32_t color, int x, int y, int w) { return 0xff000000u | (color + (uint32_t)((x + y * w) & 0xff)); }

/* A subsurface is drawn over its parent where it stands, once the parent
 * commits; it moves when the parent commits again; and goes at once. */
static void test_a_subsurface_is_drawn_on_its_parent(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    uint32_t sub = bind_global(&a, "wl_subcompositor", 1);
    window v = open_window(s, &a, "W", "app", 0x00101000, 64, 32);
    part p = add_part(&a, sub, v.surface, 10, 5);
    close(solid(&a, &p.buffer, 0x00ff0000, 8, 4, XRGB));
    show(&a, p.surface, p.buffer, 8, 4);
    pump(s, &a);
    CHECK(at(10, 5) == pattern(0x00101000, 10, 5, 64)); /* its commit waits for its parent's */
    presented = 0;
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(at(10, 5) == 0xffff0000 && at(17, 8) == 0xffff0000);
    CHECK(at(9, 5) == pattern(0x00101000, 9, 5, 64) && at(18, 5) == pattern(0x00101000, 18, 5, 64));
    CHECK(at(10, 4) == pattern(0x00101000, 10, 4, 64) && at(10, 9) == pattern(0x00101000, 10, 9, 64));
    CHECK(presented >= 1);
    mwm_window list[2];
    CHECK(mwm_server_windows(s, list, 2) == 1 && list[0].width == 64 && list[0].height == 32); /* still one window, its size */

    request(&a, p.role, 1, 2, 20, 6); /* set_position: at the parent's next commit */
    pump(s, &a);
    CHECK(at(10, 5) == 0xffff0000);
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(at(10, 5) == pattern(0x00101000, 10, 5, 64) && at(20, 6) == 0xffff0000 && at(27, 9) == 0xffff0000);

    /* On its own (desync), what it commits shows at once. */
    uint32_t green;
    request(&a, p.role, 5, 0); /* set_desync */
    close(solid(&a, &green, 0x0000ff00, 8, 4, XRGB));
    show(&a, p.surface, green, 8, 4);
    pump(s, &a);
    CHECK(at(20, 6) == 0xff00ff00);

    /* A part that lets what is under it show through: half of it, here. */
    uint32_t veil;
    close(solid(&a, &veil, 0x80400000, 8, 4, ARGB)); /* half there, red 0x40 of it */
    show(&a, p.surface, veil, 8, 4);
    pump(s, &a);
    uint32_t mixed = at(20, 6);
    CHECK(mixed >> 24 == 0xff);                 /* the window is all there */
    CHECK(((mixed >> 16) & 0xff) == 0x40 + 8);  /* its red, and half the 0x10 under it */
    CHECK(((mixed >> 8) & 0xff) == 8);          /* half the green under it */
    uint32_t clear;
    close(solid(&a, &clear, 0x00000000, 8, 4, ARGB)); /* nothing of it there */
    show(&a, p.surface, clear, 8, 4);
    pump(s, &a);
    CHECK(at(20, 6) == pattern(0x00101000, 20, 6, 64));

    /* Destroyed, it is gone at once and its parent shows again. */
    show(&a, p.surface, green, 8, 4);
    pump(s, &a);
    CHECK(at(20, 6) == 0xff00ff00);
    request(&a, p.role, 0, 0); /* wl_subsurface.destroy */
    pump(s, &a);
    CHECK(at(20, 6) == pattern(0x00101000, 20, 6, 64));
    request(&a, p.surface, 6, 0); /* the surface is no part of anything now */
    pump(s, &a);
    CHECK(at(20, 6) == pattern(0x00101000, 20, 6, 64));
    mwm_msg m;
    while (mwm_conn_next(a.c, &m)) CHECK(m.object != 1 || m.opcode != DISPLAY_ERROR);
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

/* The parts are drawn in their order, which the program can change; one
 * put under its parent does not show through it. */
static void test_parts_are_drawn_in_their_order(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    uint32_t sub = bind_global(&a, "wl_subcompositor", 1);
    window v = open_window(s, &a, "W", "app", 0x00101000, 64, 32);
    part red = add_part(&a, sub, v.surface, 10, 10), blue = add_part(&a, sub, v.surface, 14, 10);
    close(solid(&a, &red.buffer, 0x00ff0000, 8, 8, XRGB));
    close(solid(&a, &blue.buffer, 0x000000ff, 8, 8, XRGB));
    show(&a, red.surface, red.buffer, 8, 8);
    show(&a, blue.surface, blue.buffer, 8, 8);
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(at(12, 12) == 0xffff0000 && at(15, 12) == 0xff0000ff && at(20, 12) == 0xff0000ff); /* the later one on top */

    request(&a, red.role, 2, 1, blue.surface); /* place_above */
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(at(15, 12) == 0xffff0000 && at(20, 12) == 0xff0000ff);
    request(&a, red.role, 3, 1, blue.surface); /* place_below */
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(at(15, 12) == 0xff0000ff && at(12, 12) == 0xffff0000);

    request(&a, red.role, 3, 1, v.surface); /* under the parent itself */
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(at(12, 12) == pattern(0x00101000, 12, 12, 64) && at(15, 12) == 0xff0000ff);

    /* A part reaching past its parent's edge is cut there: a window is its surface's size. */
    part wide = add_part(&a, sub, v.surface, 60, 28);
    close(solid(&a, &wide.buffer, 0x0000ff00, 16, 16, XRGB));
    show(&a, wide.surface, wide.buffer, 16, 16);
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(at(63, 31) == 0xff00ff00 && at(64, 31) == 0 && at(63, 32) == 0);
    mwm_window list[2];
    CHECK(mwm_server_windows(s, list, 2) == 1 && list[0].width == 64 && list[0].height == 32);

    /* The parent's surface goes: its parts show nowhere, and say nothing wrong. */
    request(&a, v.toplevel, 0, 0);
    request(&a, v.xdg, 0, 0);
    request(&a, v.surface, 0, 0);
    request(&a, blue.surface, 6, 0);
    request(&a, blue.role, 1, 2, 1, 1);
    request(&a, blue.role, 0, 0);
    pump(s, &a);
    mwm_msg m;
    while (mwm_conn_next(a.c, &m)) CHECK(m.object != 1 || m.opcode != DISPLAY_ERROR);
    CHECK(mwm_server_windows(s, NULL, 0) == 0);
    bool clean = true;
    for (int i = 0; i < W * H; i++) clean = clean && pixels[i] == 0;
    CHECK(clean);
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

/* Only what the program says changed is copied to the display. */
static void test_only_what_changed_is_copied(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    window v = {.surface = a.next++, .xdg = a.next++, .toplevel = a.next++};
    request(&a, a.compositor, 0, 1, v.surface);
    request(&a, a.wm, 2, 2, v.xdg, v.surface);
    request(&a, v.xdg, 1, 1, v.toplevel);
    request(&a, v.surface, 6, 0);
    int fd = solid(&a, &v.buffer, 0x00111111, 64, 32, XRGB);
    show(&a, v.surface, v.buffer, 64, 32);
    pump(s, &a);
    CHECK(at(0, 0) == 0xff111111 && at(63, 31) == 0xff111111);
    CHECK(last_x == 0 && last_y == 0 && last_w == 64 && last_h == 32);

    /* The program paints its whole buffer anew and says a small part changed. */
    uint32_t white = 0x00ffffff;
    for (int i = 0; i < 64 * 32; i++) CHECK(pwrite(fd, &white, 4, i * 4) == 4);
    presented = 0;
    request(&a, v.surface, 1, 3, v.buffer, 0, 0);
    request(&a, v.surface, 9, 4, 4, 6, 8, 2); /* damage_buffer */
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(at(4, 6) == 0xffffffff && at(11, 7) == 0xffffffff);
    CHECK(at(3, 6) == 0xff111111 && at(12, 6) == 0xff111111 && at(4, 5) == 0xff111111 && at(4, 8) == 0xff111111);
    CHECK(presented == 1 && last_x == 4 && last_y == 6 && last_w == 8 && last_h == 2);

    /* Several parts in one commit: what holds them all. */
    request(&a, v.surface, 9, 4, 0, 0, 2, 2);
    request(&a, v.surface, 2, 4, 20, 10, 2, 2); /* damage, in the program's units: the same as pixels here */
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(last_x == 0 && last_y == 0 && last_w == 22 && last_h == 12);
    CHECK(at(21, 11) == 0xffffffff && at(22, 11) == 0xff111111);

    /* A commit that says nothing changed copies nothing; one that says more than there is copies what there is. */
    presented = 0;
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(presented == 0 && at(40, 20) == 0xff111111);
    request(&a, v.surface, 9, 4, (uint32_t)-50, (uint32_t)-50, 0x7fffffff, 0x7fffffff);
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(presented == 1 && last_x == 0 && last_y == 0 && last_w == 64 && last_h == 32 && at(40, 20) == 0xffffffff);
    request(&a, v.surface, 9, 4, 1000, 1000, 5, 5); /* outside it altogether */
    request(&a, v.surface, 2, 4, 5, 5, (uint32_t)-3, 0);
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(presented == 1);
    mwm_msg m;
    while (mwm_conn_next(a.c, &m)) CHECK(m.object != 1 || m.opcode != DISPLAY_ERROR);
    close(fd);
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

/* A program on a Retina screen draws twice the pixels and says so: the
 * window is told as such, and the program's units are half pixels. */
static void test_a_program_draws_at_the_screens_scale(void) {
    mwm_server *s = server();
    mwm_server_scale(s, 2);
    client a = connect_client(s);
    uint32_t output = bind_global(&a, "wl_output", 2), sub = bind_global(&a, "wl_subcompositor", 1);
    pump(s, &a);
    bool told = false;
    mwm_msg m;
    while (mwm_conn_next(a.c, &m)) {
        if (m.object == output && m.opcode == 3) told = mwm_get_int(&m) == 2; /* wl_output.scale */
    }
    CHECK(told);
    window v = open_window(s, &a, "W", "app", 0x00101000, 64, 32);
    mwm_window list[2];
    CHECK(mwm_server_windows(s, list, 2) == 1 && list[0].scale == 1);
    uint32_t generation = mwm_server_generation(s);
    request(&a, v.surface, 8, 1, 2); /* set_buffer_scale */
    request(&a, v.surface, 2, 4, 2, 3, 4, 1); /* damage: in units, twice that in pixels */
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(mwm_server_windows(s, list, 2) == 1 && list[0].scale == 2 && list[0].width == 64 && list[0].height == 32);
    CHECK(mwm_server_generation(s) != generation);
    request(&a, v.surface, 2, 4, 2, 3, 4, 1);
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(last_x == 4 && last_y == 6 && last_w == 8 && last_h == 2);

    /* A part drawn at 1 on a window drawn at 2 is shown twice as large, where its units put it. */
    part p = add_part(&a, sub, v.surface, 5, 3);
    close(solid(&a, &p.buffer, 0x00ff0000, 3, 2, XRGB));
    show(&a, p.surface, p.buffer, 3, 2);
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(at(10, 6) == 0xffff0000 && at(15, 9) == 0xffff0000);
    CHECK(at(9, 6) != 0xffff0000 && at(16, 6) != 0xffff0000 && at(10, 5) != 0xffff0000 && at(10, 10) != 0xffff0000);

    /* The screen's scale changes (the window went to another screen): the programs are told. */
    mwm_server_scale(s, 1);
    mwm_server_scale(s, 0);  /* no scale at all: not passed on */
    mwm_server_scale(s, 99);
    drain(s, &a);
    int scales = 0, last = 0;
    while (mwm_conn_next(a.c, &m)) {
        CHECK(m.object != 1 || m.opcode != DISPLAY_ERROR);
        if (m.object == output && m.opcode == 3) {
            scales++;
            last = mwm_get_int(&m);
        }
    }
    CHECK(scales == 1 && last == 1);

    uint32_t object;
    request(&a, v.surface, 8, 1, 0); /* a scale that is none */
    CHECK(dropped_with(s, &a, &object) >= 0 && object == v.surface);
    mwm_server_free(s);
}

/* What a program may not make of its surfaces. */
static void test_surfaces_misused_drop_the_program(void) {
    mwm_server *s = server();
    uint32_t object;

    client k = connect_client(s);
    uint32_t sub = bind_global(&k, "wl_subcompositor", 1), one = k.next++, two = k.next++;
    request(&k, k.compositor, 0, 1, one);
    request(&k, sub, 1, 3, k.next++, one, one); /* a part of itself */
    CHECK(dropped_with(s, &k, &object) >= 0 && object == sub);

    k = connect_client(s);
    sub = bind_global(&k, "wl_subcompositor", 1);
    window v = open_window(s, &k, "W", "app", 0, 8, 8);
    one = k.next++;
    request(&k, k.compositor, 0, 1, one);
    request(&k, sub, 1, 3, k.next++, v.surface, one); /* a window made a part of something */
    CHECK(dropped_with(s, &k, &object) >= 0);

    k = connect_client(s);
    sub = bind_global(&k, "wl_subcompositor", 1);
    one = k.next++;
    two = k.next++;
    request(&k, k.compositor, 0, 1, one);
    request(&k, k.compositor, 0, 1, two);
    request(&k, sub, 1, 3, k.next++, one, two);
    request(&k, sub, 1, 3, k.next++, two, one); /* each a part of the other */
    CHECK(dropped_with(s, &k, &object) >= 0);

    k = connect_client(s);
    sub = bind_global(&k, "wl_subcompositor", 1);
    one = k.next++;
    request(&k, k.compositor, 0, 1, one);
    request(&k, sub, 1, 3, k.next++, one, 4242); /* a part of nothing */
    CHECK(dropped_with(s, &k, &object) == ERROR_INVALID_OBJECT);

    /* Parts of parts, deeper than is drawn. */
    k = connect_client(s);
    sub = bind_global(&k, "wl_subcompositor", 1);
    uint32_t parent = k.next++;
    request(&k, k.compositor, 0, 1, parent);
    for (int i = 0; i < 12; i++) {
        uint32_t child = k.next++;
        request(&k, k.compositor, 0, 1, child);
        request(&k, sub, 1, 3, k.next++, child, parent);
        parent = child;
    }
    CHECK(dropped_with(s, &k, &object) >= 0);

    /* More parts on one surface than one may have. */
    k = connect_client(s);
    sub = bind_global(&k, "wl_subcompositor", 1);
    parent = k.next++;
    request(&k, k.compositor, 0, 1, parent);
    for (int i = 0; i < 40; i++) {
        uint32_t child = k.next++;
        request(&k, k.compositor, 0, 1, child);
        request(&k, sub, 1, 3, k.next++, child, parent);
    }
    CHECK(dropped_with(s, &k, &object) >= 0);

    k = connect_client(s);
    sub = bind_global(&k, "wl_subcompositor", 1);
    v = open_window(s, &k, "W", "app", 0, 8, 8);
    part p = add_part(&k, sub, v.surface, 0, 0);
    request(&k, p.role, 2, 1, p.surface); /* above itself */
    CHECK(dropped_with(s, &k, &object) >= 0 && object == p.role);

    k = connect_client(s);
    sub = bind_global(&k, "wl_subcompositor", 1);
    request(&k, sub, 7, 0);
    CHECK(dropped_with(s, &k, &object) == ERROR_INVALID_METHOD);

    CHECK(mwm_server_windows(s, NULL, 0) == 0);
    mwm_server_free(s);
}

/* The part of its surface a program says is the window (the rest is the
 * shadow it draws around it) is told with the window. */
static void test_the_window_inside_its_shadow_is_told(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    window v = open_window(s, &a, "W", "app", 0, 64, 32);
    mwm_window list[2];
    CHECK(mwm_server_windows(s, list, 2) == 1);
    CHECK(list[0].inner_x == 0 && list[0].inner_y == 0 && list[0].inner_width == 64 && list[0].inner_height == 32);
    uint32_t generation = mwm_server_generation(s);
    request(&a, v.xdg, 3, 4, 4, 6, 50, 20); /* set_window_geometry */
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(mwm_server_windows(s, list, 2) == 1 && mwm_server_generation(s) != generation);
    CHECK(list[0].inner_x == 4 && list[0].inner_y == 6 && list[0].inner_width == 50 && list[0].inner_height == 20);
    request(&a, v.xdg, 3, 4, 40, 6, 500, 500); /* said larger than the surface: what of it there is */
    request(&a, v.surface, 6, 0);
    pump(s, &a);
    CHECK(mwm_server_windows(s, list, 2) == 1);
    CHECK(list[0].inner_x == 40 && list[0].inner_y == 6 && list[0].inner_width == 24 && list[0].inner_height == 26);
    uint32_t object;
    request(&a, v.xdg, 3, 4, 0, 0, 0, 10); /* no width: no window */
    CHECK(dropped_with(s, &a, &object) >= 0 && object == v.xdg);
    mwm_server_free(s);
}

/* Windows fill the display row by row; one that grows into its neighbour
 * moves to where there is room; one with no room at all is not shown. */
static void test_windows_are_placed_in_rows(void) {
    mwm_server *s = server();
    client a = connect_client(s);
    window one = open_window(s, &a, "One", "app", 0x00110000, 300, 90);
    window two = open_window(s, &a, "Two", "app", 0x00220000, 300, 90);
    mwm_window list[4];
    CHECK(mwm_server_windows(s, list, 4) == 2);
    CHECK(list[0].x == 0 && list[0].y == 0);
    CHECK(list[1].x == 0 && list[1].y == 90 + MWM_GAP); /* no room beside the first: under it */
    CHECK(at(0, 90 + MWM_GAP) == pattern(0x00220000, 0, 0, 300) && at(0, 90) == 0);
    window three = open_window(s, &a, "Three", "app", 0x00330000, 300, 90);
    CHECK(three.id == 0 && mwm_server_windows(s, list, 4) == 2); /* nowhere to put it */
    window small = open_window(s, &a, "Small", "app", 0x00440000, 50, 50);
    CHECK(mwm_server_windows(s, list, 4) == 3 && list[2].x == 300 + MWM_GAP && list[2].y == 0); /* beside the first */
    (void)two;

    /* The small one grows: where it stands while it fits, elsewhere when it would touch a neighbour. */
    uint32_t larger, largest;
    close(solid(&a, &larger, 0x00555555, 84, 90, XRGB));
    show(&a, small.surface, larger, 84, 90);
    pump(s, &a);
    CHECK(mwm_server_windows(s, list, 4) == 3 && list[2].x == 300 + MWM_GAP && list[2].y == 0 && list[2].width == 84);
    request(&a, one.toplevel, 0, 0); /* the first window goes: its place is free */
    pump(s, &a);
    CHECK(mwm_server_windows(s, list, 4) == 2 && at(0, 0) == 0);
    close(solid(&a, &largest, 0x00666666, 200, 90, XRGB));
    show(&a, small.surface, largest, 200, 90);
    pump(s, &a);
    CHECK(mwm_server_windows(s, list, 4) == 2);
    CHECK(list[1].id == small.id && list[1].x == 0 && list[1].y == 0 && list[1].width == 200); /* moved to the first free place */
    CHECK(at(0, 0) == 0xff666666 && at(300 + MWM_GAP, 0) == 0);                             /* and its old place is empty */
    mwm_msg m;
    while (mwm_conn_next(a.c, &m)) CHECK(m.object != 1 || m.opcode != DISPLAY_ERROR);
    mwm_conn_free(a.c);
    mwm_server_free(s);
}

int main(void) {
    test_a_subsurface_is_drawn_on_its_parent();
    test_parts_are_drawn_in_their_order();
    test_only_what_changed_is_copied();
    test_a_program_draws_at_the_screens_scale();
    test_surfaces_misused_drop_the_program();
    test_the_window_inside_its_shadow_is_told();
    test_windows_are_placed_in_rows();
    printf("test_wm_surface: %d checks passed\n", checks);
    return 0;
}
