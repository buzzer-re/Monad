/*
 * fuzz_wm.c — fuzz target for Monad's window manager (GuestWM/mwm_server).
 *
 * The input is a script for up to three programs connected to one server
 * with a small sheet: raw bytes on a socket, requests built from the
 * input (any object, any opcode, numbers small, large and negative,
 * strings, descriptors of a file that may be shorter than said), the whole
 * exchange that opens a window with sizes from the input and takes the
 * pointer and the keyboard, what programs do with the clipboard (copies of
 * any kind, pastes into pipes that are read or left alone) and say of the
 * pointer's shape (shapes there are and are none of), frames, what
 * the Mac says of the pointer and the keys (any window, any position, any
 * key, any table of keys) and of its clipboard (text, bytes that are none,
 * more than a pipe holds), what MonadHost says on its channel (lines well
 * formed or not, and bytes), and programs leaving. After every step: every
 * window is inside the sheet and has a size, no two windows share a
 * pixel, there are no more windows, programs or pipes than there may be, a
 * pixel outside every window is black, and what MonadHost was told is
 * lines of plain printable ASCII no longer than they may be, whatever the
 * programs called their windows, but for a copy the Mac asked for, which
 * is as many bytes as its line says, no more than a copy may be, and text.
 * The sanitizers check the rest.
 *
 * Built with -fsanitize=fuzzer (clang), LLVMFuzzerTestOneInput is the
 * target. Otherwise main() is a deterministic driver: `fuzz_wm [iterations]
 * [seed]`, default a short run.
 */
#include "mwm_ctl.h"
#include "mwm_server.h"
#include "mwm_wire.h"

#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

enum { W = 256, H = 128, PROGRAMS = 3, FILE_BYTES = 64 << 10 };

static void fail(const char *what) {
    fprintf(stderr, "fuzz_wm: invariant broken: %s\n", what);
    abort();
}

static uint32_t pixels[W * H];
static int shared_file = -1;
static long windows_seen;

typedef struct {
    const uint8_t *data;
    size_t len, pos;
} input;

static uint8_t byte(input *in) { return in->pos < in->len ? in->data[in->pos++] : 0; }

static uint32_t number(input *in) {
    switch (byte(in) % 8) {
    case 0: return 0;
    case 1: return byte(in) % 32;
    case 2: return byte(in);
    case 3: return (uint32_t)-(int32_t)(byte(in) % 16);
    case 4: return 0x7fffffff - byte(in) % 4;
    case 5: return 0xffffffff - byte(in) % 4;
    case 6: return (uint32_t)byte(in) << 8 | byte(in);
    default: return (uint32_t)byte(in) << 24 | (uint32_t)byte(in) << 16 | (uint32_t)byte(in) << 8 | byte(in);
    }
}

typedef struct {
    mwm_conn *conn; /* the program's end; NULL once it left */
    int server_fd;
    uint32_t next;
    /* Its clipboard objects, once it has a window with them (0: none). */
    uint32_t manager, device;
    /* Its pointer, and what it says the pointer's shape with (0: none). */
    uint32_t pointer, shape;
} program;

static void check(const mwm_server *s) {
    mwm_window list[MWM_MAX_WINDOWS + 1];
    int n = mwm_server_windows(s, list, MWM_MAX_WINDOWS + 1);
    if (n > MWM_MAX_WINDOWS) fail("more windows than there may be");
    static uint8_t covered[W * H];
    memset(covered, 0, sizeof covered);
    for (int i = 0; i < n; i++) {
        const mwm_window *w = &list[i];
        if (w->width <= 0 || w->height <= 0) fail("a window without a size");
        if (w->x < 0 || w->y < 0 || w->x + w->width > W || w->y + w->height > H) fail("a window outside the display");
        if (!w->title || !w->app_id || strlen(w->title) >= 128 || strlen(w->app_id) >= 128) fail("a title longer than it may be");
        /* What was drawn of it, taken now and then (in pieces, or all): inside the window, its pixels on the sheet. */
        mwm_drawn d;
        static unsigned looks;
        if (looks++ % 3 == 0 && mwm_server_take_drawn((mwm_server *)s, w->id, 1 + (int)(looks * 7919u % (W * H)), &d)) {
            if (d.width <= 0 || d.height <= 0 || d.x < 0 || d.y < 0 || d.x + d.width > w->width || d.y + d.height > w->height) {
                fail("what was drawn lies outside its window");
            }
            if (d.stride != W || d.pixels != &pixels[(w->y + d.y) * W + w->x + d.x]) fail("what was drawn is not where the window is");
        }
        for (int y = w->y; y < w->y + w->height; y++)
            for (int x = w->x; x < w->x + w->width; x++) {
                if (covered[y * W + x]) fail("two windows on one pixel");
                covered[y * W + x] = 1;
            }
    }
    for (int i = 0; i < W * H; i++)
        if (!covered[i] && pixels[i] != 0) fail("something drawn where no window is");
    int fds[MWM_MAX_SOCKETS + 1];
    bool wants[MWM_MAX_SOCKETS + 1];
    if (mwm_server_sockets(s, fds, wants, MWM_MAX_SOCKETS + 1) > PROGRAMS + MWM_MAX_TRANSFERS) fail("more programs and pipes than there may be");
    (void)mwm_server_wants_frame(s);
    if (mwm_server_cursor(s) < MWM_CURSOR_HIDDEN || mwm_server_cursor(s) > MWM_CURSOR_LAST) fail("a pointer shape there is none of");
    windows_seen += n;
}

/* Pipes a program asked to have the clipboard written into, and reads or does not. */
enum { KEPT = 6 };
static int kept[KEPT] = {-1, -1, -1, -1, -1, -1};
static unsigned turn;

static void keep(int fd) {
    int *slot = &kept[turn++ % KEPT];
    if (*slot >= 0) close(*slot);
    *slot = fd;
    if (fd >= 0 && fcntl(fd, F_SETFL, O_NONBLOCK) != 0) fail("a pipe that cannot be set up");
}

/* What the server sent is read and dropped: a program that reads. A
 * descriptor is the keymap's file, or a pipe the program is to write its
 * copy into: it writes something there (text, or bytes that are none, or
 * nothing), which the keymap's file refuses. */
static void drain(program *p) {
    if (!p->conn) return;
    mwm_msg m;
    while (mwm_conn_read(p->conn) > 0)
        while (mwm_conn_next(p->conn, &m)) {
            int fd = mwm_get_fd(&m);
            if (fd < 0) continue;
            static const char *const answers[] = {"copied text", "caf\xc3\xa9\nand a line", "", "bad \xff bytes", "nul\0inside"};
            static const size_t lengths[] = {11, 16, 0, 9, 10};
            unsigned which = turn++ % 6;
            if (which < 5 && write(fd, answers[which], lengths[which]) < 0) { /* the keymap: not to be written */ }
            if (which == 5) keep(fd); /* asked, and never answers */
            else close(fd);
        }
}

/* What MonadHost's end is in the middle of: a line (how far into it, and
 * how it began), or the bytes of a copy or of a window's pixels (how many
 * are still to come). */
static size_t said, copy_left, pixels_left;
static char said_line[64];

/* What MonadHost was sent: read, and looked at as MonadHost may rely on it. */
static void check_said(int host) {
    char text[4096];
    ssize_t n;
    while (host >= 0 && (n = read(host, text, sizeof text)) > 0) {
        for (ssize_t i = 0; i < n; i++) {
            if (pixels_left > 0) {
                pixels_left--; /* any bytes at all */
            } else if (copy_left > 0) {
                if (text[i] == 0) fail("MonadHost was sent a copy that is no text");
                copy_left--;
            } else if (text[i] == '\n') {
                said_line[said < sizeof said_line ? said : sizeof said_line - 1] = 0;
                unsigned long bytes;
                char after;
                if (strncmp(said_line, "copied ", 7) == 0) {
                    if (sscanf(said_line + 7, "%lu%c", &bytes, &after) != 1 || bytes > MWM_MAX_COPY) fail("a copy larger than MonadHost takes");
                    copy_left = bytes;
                }
                if (strncmp(said_line, "pixels ", 7) == 0) {
                    unsigned id;
                    int x, y, w, h;
                    if (sscanf(said_line + 7, "%u %d %d %d %d %lu%c", &id, &x, &y, &w, &h, &bytes, &after) != 6 || id == 0 || x < 0 || y < 0
                        || w < 1 || h < 1 || x + w > W || y + h > H || bytes < 4 || bytes > (unsigned long)w * (unsigned long)h * 4) {
                        fail("pixels that are of no window on the sheet");
                    }
                    pixels_left = bytes;
                }
                said = 0;
            } else if (text[i] < 0x20 || text[i] > 0x7e || said + 1 >= MWM_CTL_LINE) {
                fail("MonadHost was sent something that is not a line of plain text");
            } else {
                if (said < sizeof said_line - 1) said_line[said] = text[i];
                said++;
            }
        }
    }
}

static void request(program *p, input *in, uint32_t object, uint16_t opcode) {
    mwm_put_begin(p->conn, object, opcode);
    int args = byte(in) % 8;
    for (int i = 0; i < args; i++) {
        switch (byte(in) % 6) {
        case 0: {
            char text[40];
            int n = byte(in) % (int)sizeof text;
            for (int k = 0; k < n; k++) text[k] = (char)(byte(in) | 1);
            text[n < (int)sizeof text ? n : (int)sizeof text - 1] = 0;
            mwm_put_string(p->conn, byte(in) % 8 ? text : NULL);
            break;
        }
        case 1: mwm_put_fd(p->conn, shared_file); break;
        case 2: mwm_put_uint(p->conn, 1 + byte(in) % 24); break; /* an id that may exist */
        default: mwm_put_uint(p->conn, number(in)); break;
        }
    }
    mwm_put_end(p->conn);
}

static void words(program *p, uint32_t object, uint16_t opcode, int count, const uint32_t *args) {
    mwm_put_begin(p->conn, object, opcode);
    for (int i = 0; i < count; i++) mwm_put_uint(p->conn, args[i]);
    mwm_put_end(p->conn);
}

/* Kinds of data a copy is offered in and a paste asks for: text, what is none, and no name at all. */
static const char *const kinds[] = {"text/plain;charset=utf-8", "UTF8_STRING", "image/png", "text/html", ""};

/* A paste: the program asks for an offer it may have been made, in some kind, into a pipe it reads later or never. */
static void paste(program *p, input *in) {
    int ends[2];
    if (pipe(ends) != 0) fail("no pipe");
    mwm_put_begin(p->conn, 0xff000000u + byte(in) % 4, 1); /* receive */
    mwm_put_string(p->conn, kinds[byte(in) % 5]);
    mwm_put_fd(p->conn, ends[1]);
    mwm_put_end(p->conn);
    close(ends[1]);
    keep(ends[0]);
}

/* A copy: a source offered in some kinds (more than may be, sometimes), set as the clipboard, or the clipboard taken back. */
static void copy(program *p, input *in) {
    uint32_t source = p->next++;
    words(p, p->manager, 0, 1, &source);
    for (int offers = byte(in) % 20; offers > 0; offers--) {
        mwm_put_begin(p->conn, source, 0);
        mwm_put_string(p->conn, kinds[byte(in) % 5]);
        mwm_put_end(p->conn);
    }
    words(p, p->device, 1, 2, (uint32_t[]){byte(in) % 4 ? source : 0, 1});
    if (byte(in) % 4 == 0) words(p, source, 1, 0, NULL); /* and gone again */
}

/* The exchange that opens a window, its sizes from the input, with a part
 * on it (a subsurface) somewhere, in some order, at some scale, a menu (a
 * popup, with one of its own) that may take the keyboard, and a copy of
 * some kinds set as the clipboard. */
static void open_window(program *p, input *in) {
    uint32_t registry = p->next++, compositor = p->next++, shm = p->next++, wm = p->next++, surface = p->next++, xdg = p->next++,
             toplevel = p->next++, pool = p->next++, buffer = p->next++, seat = p->next++;
    words(p, 1, 1, 1, &registry);
    mwm_put_begin(p->conn, registry, 0);
    mwm_put_uint(p->conn, 5);
    mwm_put_string(p->conn, "wl_seat");
    mwm_put_uint(p->conn, 1 + byte(in) % 5);
    mwm_put_uint(p->conn, seat);
    mwm_put_end(p->conn);
    p->pointer = p->next++;
    words(p, seat, 0, 1, &p->pointer); /* get_pointer */
    if (byte(in) % 2) { /* and a way to say how the pointer is to look */
        uint32_t shapes = p->next++;
        p->shape = p->next++;
        mwm_put_begin(p->conn, registry, 0);
        mwm_put_uint(p->conn, 9);
        mwm_put_string(p->conn, "wp_cursor_shape_manager_v1");
        mwm_put_uint(p->conn, 1 + byte(in) % 2);
        mwm_put_uint(p->conn, shapes);
        mwm_put_end(p->conn);
        words(p, shapes, 1, 2, (uint32_t[]){p->shape, p->pointer});
    }
    words(p, seat, 1, 1, (uint32_t[]){p->next++}); /* get_keyboard */
    static const char *names[] = {"wl_compositor", "wl_shm", "xdg_wm_base"};
    uint32_t ids[] = {compositor, shm, wm};
    for (uint32_t i = 0; i < 3; i++) {
        mwm_put_begin(p->conn, registry, 0);
        mwm_put_uint(p->conn, i + 1);
        mwm_put_string(p->conn, names[i]);
        mwm_put_uint(p->conn, 1);
        mwm_put_uint(p->conn, ids[i]);
        mwm_put_end(p->conn);
    }
    words(p, compositor, 0, 1, &surface);
    words(p, wm, 2, 2, (uint32_t[]){xdg, surface});
    words(p, xdg, 1, 1, &toplevel);
    if (byte(in) % 3 == 0) { /* its frame, as GTK says it: its own bar, the server's, or a mode there is none of */
        uint32_t frames = p->next++, frame = p->next++;
        mwm_put_begin(p->conn, registry, 0);
        mwm_put_uint(p->conn, 10);
        mwm_put_string(p->conn, "org_kde_kwin_server_decoration_manager");
        mwm_put_uint(p->conn, 1);
        mwm_put_uint(p->conn, frames);
        mwm_put_end(p->conn);
        words(p, frames, 0, 2, (uint32_t[]){frame, byte(in) % 4 ? surface : number(in)});
        words(p, frame, 1, 1, (uint32_t[]){byte(in) % 4});
        if (byte(in) % 4 == 0) words(p, frame, 0, 0, NULL);
    }
    if (byte(in) % 3 == 0) words(p, toplevel, (uint16_t)(4 + byte(in) % 10), 2, (uint32_t[]){seat, number(in)}); /* a wish, or what is none */
    char title[40];
    int length = byte(in) % (int)sizeof title;
    for (int i = 0; i < length; i++) title[i] = (char)(byte(in) | 1);
    title[length] = 0;
    mwm_put_begin(p->conn, toplevel, 2);
    mwm_put_string(p->conn, title);
    mwm_put_end(p->conn);
    words(p, surface, 6, 0, NULL);
    uint32_t width = 1 + number(in) % 400, height = 1 + number(in) % 200, stride = width * 4 + (byte(in) % 4) * 4;
    mwm_put_begin(p->conn, shm, 0);
    mwm_put_uint(p->conn, pool);
    mwm_put_fd(p->conn, shared_file);
    mwm_put_uint(p->conn, byte(in) % 16 ? FILE_BYTES : number(in));
    mwm_put_end(p->conn);
    words(p, pool, 0, 6, (uint32_t[]){buffer, byte(in) % 8 ? 0 : number(in), width, height, stride, byte(in) % 2});
    words(p, surface, 1, 3, (uint32_t[]){buffer, 0, 0});
    if (byte(in) % 4 == 0) words(p, surface, 8, 1, (uint32_t[]){byte(in) % 6}); /* set_buffer_scale, 0 and 5 being none */
    words(p, surface, 6, 0, NULL);
    if (byte(in) % 2) {
        uint32_t subcompositor = p->next++, part = p->next++, role = p->next++;
        mwm_put_begin(p->conn, registry, 0);
        mwm_put_uint(p->conn, 6);
        mwm_put_string(p->conn, "wl_subcompositor");
        mwm_put_uint(p->conn, 1);
        mwm_put_uint(p->conn, subcompositor);
        mwm_put_end(p->conn);
        words(p, compositor, 0, 1, &part);
        words(p, subcompositor, 1, 3, (uint32_t[]){role, part, surface});
        words(p, role, 1, 2, (uint32_t[]){number(in) % 600 - 100, number(in) % 300 - 50}); /* set_position, also off the window */
        if (byte(in) % 3 == 0) words(p, role, 5, 0, NULL);                                  /* set_desync */
        if (byte(in) % 3 == 0) words(p, role, 3, 1, &surface);                              /* place_below its parent */
        if (byte(in) % 4 == 0) words(p, part, 8, 1, (uint32_t[]){1 + byte(in) % 4});
        words(p, part, 1, 3, (uint32_t[]){buffer, 0, 0});
        words(p, part, 9, 4, (uint32_t[]){number(in), number(in), number(in), number(in)}); /* damage_buffer, anywhere */
        words(p, part, 6, 0, NULL);
        words(p, surface, 2, 4, (uint32_t[]){number(in), number(in), number(in), number(in)}); /* damage */
        words(p, surface, 6, 0, NULL);
    }
    uint32_t parent = xdg;
    for (int menus = byte(in) % 3; menus > 0; menus--) {
        uint32_t place = p->next++, menu = p->next++, role = p->next++, popup = p->next++;
        words(p, wm, 1, 1, &place);                                                           /* create_positioner */
        words(p, place, 1, 2, (uint32_t[]){1 + number(in) % 300, 1 + number(in) % 150});      /* set_size */
        words(p, place, 2, 4, (uint32_t[]){number(in) % 200, number(in) % 100, byte(in), byte(in)});
        words(p, place, 3, 1, (uint32_t[]){byte(in) % 10});                                   /* set_anchor, 9 being none */
        words(p, place, 4, 1, (uint32_t[]){byte(in) % 9});
        words(p, place, 6, 2, (uint32_t[]){number(in), number(in)});                          /* set_offset, anywhere */
        words(p, compositor, 0, 1, &menu);
        words(p, wm, 2, 2, (uint32_t[]){role, menu});
        words(p, role, 2, 3, (uint32_t[]){popup, parent, place});                             /* get_popup */
        if (byte(in) % 2) words(p, popup, 1, 2, (uint32_t[]){seat, 1});                       /* grab */
        words(p, menu, 6, 0, NULL);
        words(p, menu, 1, 3, (uint32_t[]){buffer, 0, 0});
        words(p, menu, 6, 0, NULL);
        parent = role;
    }
    if (byte(in) % 2) { /* the clipboard: a copy of some kinds, and at once a paste of what it may have been offered */
        p->manager = p->next++;
        p->device = p->next++;
        mwm_put_begin(p->conn, registry, 0);
        mwm_put_uint(p->conn, 7);
        mwm_put_string(p->conn, "wl_data_device_manager");
        mwm_put_uint(p->conn, 1 + byte(in) % 3);
        mwm_put_uint(p->conn, p->manager);
        mwm_put_end(p->conn);
        words(p, p->manager, 1, 2, (uint32_t[]){p->device, seat});
        copy(p, in);
        for (int pastes = byte(in) % 3; pastes > 0; pastes--) paste(p, in);
    }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (shared_file < 0) {
        signal(SIGPIPE, SIG_IGN); /* bytes written to a program the server dropped */
        char path[] = "/tmp/monad-fuzz-wm-XXXXXX";
        shared_file = mkstemp(path);
        if (shared_file < 0) fail("no file for the programs' pixels");
        unlink(path);
        static uint8_t fill[FILE_BYTES];
        memset(fill, 0x5a, sizeof fill);
        if (write(shared_file, fill, sizeof fill) != (ssize_t)sizeof fill) fail("the pixel file could not be written");
    }
    memset(pixels, 0, sizeof pixels);
    mwm_screen screen = {.pixels = pixels, .width = W, .height = H, .stride = W};
    mwm_server *s = mwm_server_new(&screen);
    if (!s) fail("no server");
    program programs[PROGRAMS];
    memset(programs, 0, sizeof programs);
    input in = {.data = data, .len = size};
    uint32_t time = 0;
    mwm_ctl *ctl = mwm_ctl_new(s);
    int host = -1;
    if (!ctl) fail("no channel");
    while (in.pos < in.len) {
        program *p = &programs[byte(&in) % PROGRAMS];
        if (!p->conn) {
            int sv[2];
            if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) fail("no socket pair");
            p->conn = mwm_conn_new(sv[0]);
            p->server_fd = sv[1];
            p->next = 2;
            p->manager = p->device = p->pointer = p->shape = 0;
            if (!p->conn || !mwm_server_add_client(s, sv[1])) fail("a program could not connect");
        }
        if (mwm_ctl_fd(ctl) < 0) { /* MonadHost connects, again when it was dropped */
            int sv[2];
            if (host >= 0) close(host);
            if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0 || fcntl(sv[0], F_SETFL, O_NONBLOCK) != 0) fail("no socket pair");
            host = sv[0];
            said = copy_left = pixels_left = 0;
            mwm_ctl_attach(ctl, sv[1]);
        }
        switch (byte(&in) % 13) {
        case 0: { /* bytes as they are */
            uint8_t raw[64];
            size_t n = byte(&in) % sizeof raw;
            for (size_t i = 0; i < n; i++) raw[i] = byte(&in);
            (void)mwm_conn_flush(p->conn);
            if (n && write(mwm_conn_fd(p->conn), raw, n) < 0) { /* the server left first */ }
            break;
        }
        case 1: case 2: case 3:
            request(p, &in, 1 + byte(&in) % 24, byte(&in) % 16);
            break;
        case 4: case 5:
            open_window(p, &in);
            break;
        case 6: /* time passes: a frame, or long enough for a copy that was asked for to be given up on */
            mwm_server_frame(s, time += byte(&in) % 8 ? 16 : 3000);
            break;
        case 7: case 8: { /* what the Mac says of the pointer and the keys */
            uint32_t window = byte(&in) % 12;
            switch (byte(&in) % 9) {
            case 0: mwm_server_pointer(s, window, (int32_t)number(&in), (int32_t)number(&in), time); break;
            case 1: mwm_server_button(s, 0x110 + byte(&in) % 3, byte(&in) % 2, time); break;
            case 2: mwm_server_scroll(s, (int32_t)number(&in), (int32_t)number(&in), time); break;
            case 3: mwm_server_focus(s, window); break;
            case 4: mwm_server_key(s, number(&in) % 300, byte(&in) % 2, time); break;
            case 5: mwm_server_modifiers(s, number(&in), number(&in)); break;
            case 6: { /* ⌘V: the Mac's text, or what is none, or more than a pipe holds at once */
                static char text[200 << 10];
                size_t n = byte(&in) % 4 == 0 ? sizeof text : byte(&in) % 64;
                bool plain = byte(&in) % 4 != 0;
                for (size_t i = 0; i < n; i++) text[i] = n > 64 ? (char)('a' + i % 26) : plain ? (char)(0x20 + byte(&in) % 0x5f) : (char)byte(&in);
                (void)mwm_server_paste(s, text, n);
                break;
            }
            case 7: mwm_server_copy(s, time); break;
            default: {
                mwm_key keys[4];
                int count = byte(&in) % 5;
                for (int i = 0; i < count; i++) {
                    keys[i] = (mwm_key){.code = number(&in) % 300, .caps = byte(&in) % 2};
                    for (int level = 0; level < 4; level++) keys[i].symbols[level] = byte(&in) % 3 ? number(&in) : 0;
                }
                (void)mwm_server_keymap(s, keys, count);
            }
            }
            break;
        }
        case 9: case 10: { /* what MonadHost says, well formed or not */
            static const char *const names[] = {"pointer", "button", "scroll", "focus", "key", "mods", "keys", "k", "size", "close", "dismiss", "scale", "paste", "copy", "dance", ""};
            char text[256];
            size_t n = 0;
            if (byte(&in) % 4 == 0) {
                n = byte(&in) % 200;
                for (size_t i = 0; i < n; i++) text[i] = (char)byte(&in);
            } else {
                n = (size_t)snprintf(text, sizeof text, "%s", names[byte(&in) % 16]);
                for (int args = byte(&in) % 8; args > 0; args--) {
                    long long v = byte(&in) % 2 ? (long long)(byte(&in) % 16) : (long long)(int32_t)number(&in) * (byte(&in) % 3);
                    n += (size_t)snprintf(text + n, sizeof text - n, " %lld", v);
                }
                text[n++] = '\n';
            }
            if (n && write(host, text, n) < 0) { /* the window manager hung up first */ }
            mwm_ctl_service(ctl, true, true, time);
            break;
        }
        case 11: /* a window in front and under the pointer, and its program copies, pastes what it was offered, lets an offer go, or says how the pointer is to look */
            if (byte(&in) % 2) mwm_server_focus(s, 1 + byte(&in) % 6);
            if (byte(&in) % 2) mwm_server_pointer(s, 1 + byte(&in) % 6, 256, 256, time);
            switch (byte(&in) % 6) {
            case 0: if (p->device) copy(p, &in); break;
            case 1: words(p, 0xff000000u + byte(&in) % 4, 2, 0, NULL); break;
            case 2: if (p->shape) words(p, p->shape, 1, 2, (uint32_t[]){number(&in), byte(&in) % 40}); break; /* shapes there are, and are none of */
            case 3: if (p->pointer) words(p, p->pointer, 0, 4, (uint32_t[]){number(&in), byte(&in) % 2 ? 0 : 1 + byte(&in) % 24, 0, 0}); break;
            default: paste(p, &in); break;
            }
            break;
        default: /* the program leaves */
            mwm_conn_free(p->conn);
            p->conn = NULL;
            mwm_server_service(s, p->server_fd, true, false);
            check(s);
            continue;
        }
        if (mwm_conn_failed(p->conn)) { /* a message the writer itself refuses: start over as a new program */
            mwm_conn_free(p->conn);
            p->conn = NULL;
            mwm_server_service(s, p->server_fd, true, false);
        } else {
            (void)mwm_conn_flush(p->conn);
            mwm_server_service(s, p->server_fd, true, true);
            drain(p);
        }
        check(s);
        { /* the clipboard's pipes: what programs wrote is read, what they read is written on */
            int fds[MWM_MAX_SOCKETS];
            bool wants[MWM_MAX_SOCKETS];
            int count = mwm_server_sockets(s, fds, wants, MWM_MAX_SOCKETS);
            for (int i = 0; i < count; i++) {
                bool a_program = false;
                for (int k = 0; k < PROGRAMS; k++) a_program = a_program || (programs[k].conn && programs[k].server_fd == fds[i]);
                if (!a_program) mwm_server_service(s, fds[i], true, true);
            }
            char taken[4096];
            int reader = kept[byte(&in) % KEPT];
            if (reader >= 0 && read(reader, taken, sizeof taken) < 0) { /* nothing there now, or the writing end of nothing */ }
        }
        check(s);
        mwm_ctl_update(ctl);
        check_said(host);
    }
    for (int i = 0; i < KEPT; i++) {
        if (kept[i] >= 0) close(kept[i]);
        kept[i] = -1;
    }
    for (int i = 0; i < PROGRAMS; i++)
        if (programs[i].conn) mwm_conn_free(programs[i].conn);
    mwm_ctl_free(ctl);
    if (host >= 0) close(host);
    mwm_server_free(s);
    return 0;
}

#ifndef FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION
static uint64_t rng_state;
static uint32_t rnd(void) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return (uint32_t)(rng_state >> 16);
}

static long parse(const char *s, long fallback) {
    if (!s || !*s) return fallback;
    char *end;
    long v = strtol(s, &end, 0);
    return *end ? fallback : v;
}

int main(int argc, char **argv) {
    long iterations = parse(argc > 1 ? argv[1] : NULL, parse(getenv("FUZZ_ITERS"), 2000));
    rng_state = (uint64_t)parse(argc > 2 ? argv[2] : getenv("FUZZ_SEED"), 0x4d4f4e4144);
    if (rng_state == 0) rng_state = 1;
    static uint8_t script[2048];
    for (long it = 0; it < iterations; it++) {
        size_t len = 8 + rnd() % (sizeof script - 8);
        for (size_t i = 0; i < len; i++) script[i] = (uint8_t)rnd();
        LLVMFuzzerTestOneInput(script, len);
    }
    fprintf(stderr, "fuzz_wm: %ld scripts (%ld windows looked at), no invariant broken\n", iterations, windows_seen);
    return 0;
}
#endif
