/*
 * mgl_wayland.c — the Wayland side of a window's surface: the window
 * manager's monad_gl (mwm_gl_wire.h), through which a buffer without
 * pixels says "this window shows what stream S draws on its surface N",
 * attached to the program's own wl_surface and committed at each
 * eglSwapBuffers, with a frame callback so that pictures are made no
 * faster than they are shown.
 *
 * The VM that builds this may have no Wayland headers, and a program that
 * draws to pbuffers only may have no libwayland at all: what is used of
 * libwayland-client is declared here from its ABI, which is stable, and
 * found with dlopen when a display is first initialized. The requests are
 * written with the opcodes of the core protocol (wl_display.get_registry
 * 1, wl_registry.bind 0, wl_surface.attach 1, damage 2, frame 3, commit
 * 6, wl_buffer.destroy 0).
 *
 * The program's events are its own: everything here is on queues of the
 * library's (one a surface, so that a thread waiting for its window's
 * frame takes no other window's), and the program's wl_surface is used
 * through a wrapper that is on that queue.
 */
#include "mgl_internal.h"

#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

struct wl_display;
struct wl_event_queue;
struct wl_proxy;
struct wl_interface;

struct wl_message {
    const char *name;
    const char *signature;
    const struct wl_interface **types;
};

struct wl_interface {
    const char *name;
    int version;
    int method_count;
    const struct wl_message *methods;
    int event_count;
    const struct wl_message *events;
};

/* wl_proxy_marshal_flags' flag: the request destroys the object. */
enum { DESTROY = 1 };

/* libwayland-client, as much as is used of it. */
static struct {
    void *lib;
    struct wl_proxy *(*proxy_marshal_flags)(struct wl_proxy *, uint32_t opcode, const struct wl_interface *, uint32_t version,
                                            uint32_t flags, ...);
    int (*proxy_add_listener)(struct wl_proxy *, void (**implementation)(void), void *data);
    uint32_t (*proxy_get_version)(struct wl_proxy *);
    void *(*proxy_create_wrapper)(void *proxy);
    void (*proxy_wrapper_destroy)(void *wrapper);
    void (*proxy_set_queue)(struct wl_proxy *, struct wl_event_queue *);
    void (*proxy_destroy)(struct wl_proxy *);
    struct wl_event_queue *(*display_create_queue)(struct wl_display *);
    int (*display_dispatch_queue)(struct wl_display *, struct wl_event_queue *);
    int (*display_dispatch_queue_pending)(struct wl_display *, struct wl_event_queue *);
    int (*display_roundtrip_queue)(struct wl_display *, struct wl_event_queue *);
    int (*display_flush)(struct wl_display *);
    void (*event_queue_destroy)(struct wl_event_queue *);
    const struct wl_interface *display_interface, *registry_interface, *buffer_interface, *callback_interface;
} wl;

/* monad_gl, version 1: destroy, and create_buffer(new wl_buffer, stream,
 * surface, width, height). The new object's interface is libwayland's
 * own wl_buffer_interface, known once the library is loaded. */
static const struct wl_interface *create_buffer_types[5];
static const struct wl_message monad_gl_requests[] = {
    {"destroy", "", create_buffer_types + 1},
    {"create_buffer", "nuuii", create_buffer_types},
};
static const struct wl_interface monad_gl_interface = {"monad_gl", 1, 2, monad_gl_requests, 0, NULL};

struct mgl_wl {
    struct wl_display *display;
    struct wl_event_queue *queue;
    struct wl_proxy *gl;
    /* What the registry called monad_gl; 0: it has none. */
    uint32_t name;
};

struct mgl_wl_surface {
    mgl_wl *wl;
    struct wl_event_queue *queue;
    /* The program's wl_surface, as a wrapper on `queue`. */
    struct wl_proxy *surface;
    /* The buffer attached, and what it says. */
    struct wl_proxy *buffer;
    uint32_t stream, id;
    int width, height;
    /* The frame callback of the last commit, until it comes. */
    struct wl_proxy *frame;
};

static bool load(void) {
    if (wl.lib) return true;
    void *lib = dlopen("libwayland-client.so.0", RTLD_LAZY);
    if (!lib) return false;
    bool all = true;
#define FIND(field, symbol) all = (wl.field = dlsym(lib, symbol)) != NULL && all
    FIND(proxy_marshal_flags, "wl_proxy_marshal_flags");
    FIND(proxy_add_listener, "wl_proxy_add_listener");
    FIND(proxy_get_version, "wl_proxy_get_version");
    FIND(proxy_create_wrapper, "wl_proxy_create_wrapper");
    FIND(proxy_wrapper_destroy, "wl_proxy_wrapper_destroy");
    FIND(proxy_set_queue, "wl_proxy_set_queue");
    FIND(proxy_destroy, "wl_proxy_destroy");
    FIND(display_create_queue, "wl_display_create_queue");
    FIND(display_dispatch_queue, "wl_display_dispatch_queue");
    FIND(display_dispatch_queue_pending, "wl_display_dispatch_queue_pending");
    FIND(display_roundtrip_queue, "wl_display_roundtrip_queue");
    FIND(display_flush, "wl_display_flush");
    FIND(event_queue_destroy, "wl_event_queue_destroy");
    FIND(display_interface, "wl_display_interface");
    FIND(registry_interface, "wl_registry_interface");
    FIND(buffer_interface, "wl_buffer_interface");
    FIND(callback_interface, "wl_callback_interface");
#undef FIND
    if (!all) {
        /* A libwayland older than wl_proxy_marshal_flags (1.20). */
        dlclose(lib);
        return false;
    }
    create_buffer_types[0] = wl.buffer_interface;
    wl.lib = lib;
    return true;
}

static void registry_global(void *data, struct wl_proxy *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)registry, (void)version;
    mgl_wl *w = data;
    if (strcmp(interface, monad_gl_interface.name) == 0) w->name = name;
}

static void registry_global_remove(void *data, struct wl_proxy *registry, uint32_t name) { (void)data, (void)registry, (void)name; }

static void (*registry_listener[])(void) = {(void (*)(void))registry_global, (void (*)(void))registry_global_remove};

mgl_wl *mgl_wl_bind(void *display) {
    /* A wl_display begins with its interface, as every proxy does: a
     * display that does not is another window system's (a program that
     * gave eglGetDisplay an X11 Display), and none to speak Wayland to. */
    if (!load() || *(const struct wl_interface *const *)display != wl.display_interface) return NULL;
    mgl_wl *w = calloc(1, sizeof *w);
    if (!w) return NULL;
    w->display = display;
    w->queue = wl.display_create_queue(display);
    struct wl_proxy *wrapper = w->queue ? wl.proxy_create_wrapper(display) : NULL, *registry = NULL;
    if (wrapper) {
        wl.proxy_set_queue(wrapper, w->queue);
        registry = wl.proxy_marshal_flags(wrapper, 1, wl.registry_interface, wl.proxy_get_version(wrapper), 0, NULL);
        wl.proxy_wrapper_destroy(wrapper);
    }
    if (registry) {
        wl.proxy_add_listener(registry, registry_listener, w);
        if (wl.display_roundtrip_queue(display, w->queue) >= 0 && w->name != 0)
            w->gl = wl.proxy_marshal_flags(registry, 0, &monad_gl_interface, 1, 0, w->name, monad_gl_interface.name, 1, NULL);
        /* Nothing more is asked of the registry, and its events are not to pile up on a queue nobody reads. */
        wl.proxy_destroy(registry);
    }
    if (!w->gl) {
        mgl_wl_unbind(w);
        return NULL;
    }
    return w;
}

void mgl_wl_unbind(mgl_wl *w) {
    if (w->gl) wl.proxy_marshal_flags(w->gl, 0, NULL, wl.proxy_get_version(w->gl), DESTROY);
    if (w->queue) wl.event_queue_destroy(w->queue);
    (void)wl.display_flush(w->display);
    free(w);
}

mgl_wl_surface *mgl_wl_surface_new(mgl_wl *w, void *surface) {
    mgl_wl_surface *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    s->wl = w;
    s->queue = wl.display_create_queue(w->display);
    s->surface = s->queue ? wl.proxy_create_wrapper(surface) : NULL;
    if (!s->surface) {
        if (s->queue) wl.event_queue_destroy(s->queue);
        free(s);
        return NULL;
    }
    wl.proxy_set_queue(s->surface, s->queue);
    return s;
}

static void frame_done(void *data, struct wl_proxy *callback, uint32_t time) {
    (void)time;
    mgl_wl_surface *s = data;
    if (s->frame == callback) s->frame = NULL;
    wl.proxy_destroy(callback);
}

static void (*frame_listener[])(void) = {(void (*)(void))frame_done};

bool mgl_wl_present(mgl_wl_surface *s, uint32_t stream, uint32_t surface, int width, int height, int interval) {
    mgl_wl *w = s->wl;
    /* The picture before this one is not shown yet: the program waits here, as with any driver. */
    while (interval != 0 && s->frame)
        if (wl.display_dispatch_queue(w->display, s->queue) < 0) return false;
    if (wl.display_dispatch_queue_pending(w->display, s->queue) < 0) return false;

    if (!s->buffer || s->stream != stream || s->id != surface || s->width != width || s->height != height) {
        if (s->buffer) wl.proxy_marshal_flags(s->buffer, 0, NULL, wl.proxy_get_version(s->buffer), DESTROY);
        s->buffer = wl.proxy_marshal_flags(w->gl, 1, wl.buffer_interface, wl.proxy_get_version(w->gl), 0, NULL, stream, surface, (int32_t)width,
                                           (int32_t)height);
        if (!s->buffer) return false;
        /* What the window manager says of the buffer (its release) is read where the surface's frames are. */
        wl.proxy_set_queue(s->buffer, s->queue);
        s->stream = stream;
        s->id = surface;
        s->width = width;
        s->height = height;
    }
    uint32_t version = wl.proxy_get_version(s->surface);
    if (s->frame) {
        /* With interval 0 the callback before was not waited for; only the newest is kept. */
        wl.proxy_destroy(s->frame);
        s->frame = NULL;
    }
    s->frame = wl.proxy_marshal_flags(s->surface, 3, wl.callback_interface, version, 0, NULL);
    if (s->frame) wl.proxy_add_listener(s->frame, frame_listener, s);
    wl.proxy_marshal_flags(s->surface, 1, NULL, version, 0, s->buffer, (int32_t)0, (int32_t)0);
    wl.proxy_marshal_flags(s->surface, 2, NULL, version, 0, (int32_t)0, (int32_t)0, (int32_t)INT32_MAX, (int32_t)INT32_MAX);
    wl.proxy_marshal_flags(s->surface, 6, NULL, version, 0);
    return wl.display_flush(w->display) >= 0 || errno == EAGAIN;
}

void mgl_wl_surface_gone(mgl_wl_surface *s) {
    if (s->frame) wl.proxy_destroy(s->frame);
    if (s->buffer) wl.proxy_marshal_flags(s->buffer, 0, NULL, wl.proxy_get_version(s->buffer), DESTROY);
    wl.proxy_wrapper_destroy(s->surface);
    wl.event_queue_destroy(s->queue);
    (void)wl.display_flush(s->wl->display);
    free(s);
}
