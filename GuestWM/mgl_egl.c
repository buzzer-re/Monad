/*
 * mgl_egl.c — EGL 1.4's entry points: displays (a program's Wayland
 * display, or none, and then there are pbuffers only), the few configs
 * offered, surfaces and contexts with the names they have on the wire
 * (mwm_gl_wire.h), which context a thread has current, and
 * eglSwapBuffers, where a picture is done: the Mac is told (Swap) and the
 * window's wl_surface is committed with the buffer that says what it
 * shows (mgl_wayland.c).
 *
 * The process's stream is opened at the first eglInitialize and closed
 * when the last display is terminated and nothing of it is current any
 * more.
 */
#include "mgl_internal.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* The configs, by EGL_CONFIG_ID - 1: with alpha and without, each with a
 * depth and a stencil buffer, with neither, and with a depth buffer only
 * (a program that asks for depth and no stencil, as glmark2 does, may
 * hold a stencil buffer it did not ask for against a config). All else
 * about them is the same. A config keeps its id: new ones go at the end. */
static const struct {
    EGLint alpha, depth, stencil;
} configs[] = {{8, 24, 8}, {8, 0, 0}, {0, 24, 8}, {0, 0, 0}, {8, 24, 0}, {0, 24, 0}};
enum { CONFIGS = sizeof configs / sizeof configs[0], DISPLAYS = 16 };

/* A display is for good once asked for (eglGetDisplay gives the same one
 * for the same Wayland display); `native` NULL is EGL_DEFAULT_DISPLAY. */
typedef struct {
    bool used, initialized;
    void *native;
    mgl_wl *wl;
} display;
static display displays[DISPLAYS];

typedef struct surface {
    struct surface *next;
    display *dpy;
    int config;
    /* Its name on the wire. */
    uint32_t id;
    int width, height, interval;
    bool is_window, largest;
    /* A window surface's native window, until the program destroys it. */
    struct wl_egl_window *window;
    mgl_wl_surface *wl;
    /* How many times it is current (as the surface drawn on, as the one
     * read from). eglDestroySurface on one that is waits for 0. */
    int bound;
    bool destroyed;
} surface;

static surface *surfaces;
static mgl_context *contexts;
static uint32_t last_surface, last_context;

/* What is the calling thread's own: its context and its last EGL error (0: EGL_SUCCESS). */
static _Thread_local struct {
    mgl_context *context;
    EGLint error;
} thread;

static void unlock(int *held) {
    (void)held;
    mgl_unlock();
}
/* The lock, until the function returns, whichever way. */
#define LOCKED int held __attribute__((cleanup(unlock), unused)) = (mgl_lock(), 1)

static EGLBoolean fail(EGLint error) {
    thread.error = error;
    return EGL_FALSE;
}

static EGLBoolean done(void) {
    thread.error = EGL_SUCCESS;
    return EGL_TRUE;
}

mgl_context *mgl_enter(void) {
    if (!thread.context) return NULL;
    mgl_lock();
    return thread.context;
}

void mgl_leave(void) { mgl_unlock(); }

/* ---- What a handle is ---- */

static display *a_display(EGLDisplay dpy) {
    for (int i = 0; i < DISPLAYS; i++)
        if (displays[i].used && dpy == (EGLDisplay)&displays[i]) return &displays[i];
    return NULL;
}

/* An initialized display, or the error for what it is not. */
static display *ready(EGLDisplay dpy) {
    display *d = a_display(dpy);
    if (!d) fail(EGL_BAD_DISPLAY);
    else if (!d->initialized) fail(EGL_NOT_INITIALIZED);
    return d && d->initialized ? d : NULL;
}

/* A config's place in `configs`, or -1. */
static int a_config(EGLConfig config) {
    for (int i = 0; i < CONFIGS; i++)
        if (config == (EGLConfig)&configs[i]) return i;
    return -1;
}

static surface *a_surface(const display *d, EGLSurface handle) {
    for (surface *s = surfaces; s; s = s->next)
        if ((EGLSurface)s == handle && s->dpy == d && !s->destroyed) return s;
    return NULL;
}

static mgl_context *a_context(const display *d, EGLContext handle) {
    for (mgl_context *c = contexts; c; c = c->next)
        if ((EGLContext)c == handle && c->display == d && !c->destroyed) return c;
    return NULL;
}

/* The surface of that name on the wire: one a context is current on, destroyed or not. */
static surface *surface_named(uint32_t id) {
    for (surface *s = surfaces; s && id != 0; s = s->next)
        if (s->id == id) return s;
    return NULL;
}

/* An attribute list's item: EGLint for EGL 1.4's calls, EGLAttrib for EGL 1.5's. */
static intptr_t item(const void *list, bool wide, int i) { return wide ? ((const EGLAttrib *)list)[i] : ((const EGLint *)list)[i]; }

/* ---- The stream's life, surfaces, contexts ---- */

static void close_when_idle(void) {
    for (int i = 0; i < DISPLAYS; i++)
        if (displays[i].initialized) return;
    if (surfaces || contexts) return;
    mgl_conn_close();
    /* The next stream is a new one, and its names begin anew. */
    last_surface = last_context = 0;
}

static void command(uint32_t op, const uint32_t *w, int count) {
    mgl_begin(op);
    for (int i = 0; i < count; i++) mgl_u32(w[i]);
    (void)mgl_end();
}
#define SEND(op, ...) command((op), (const uint32_t[]){__VA_ARGS__}, sizeof((const uint32_t[]){__VA_ARGS__}) / sizeof(uint32_t))

/* SurfaceCreate: what the surface is drawn on has the buffers its config
 * has and no others, so that the Mac draws as the program was told it would. */
static void surface_created(const surface *s) {
    SEND(MGL_SURFACE_CREATE, s->id, (uint32_t)s->width, (uint32_t)s->height, configs[s->config].alpha != 0, configs[s->config].depth != 0,
         configs[s->config].stencil != 0);
}

/* The surface draws at the size its window has now. */
static void follow_window(surface *s) {
    const struct wl_egl_window *w = s->window;
    if (!w || w->width <= 0 || w->height <= 0) return;
    int width = w->width > MGL_MAX_SIZE ? MGL_MAX_SIZE : w->width, height = w->height > MGL_MAX_SIZE ? MGL_MAX_SIZE : w->height;
    if (width == s->width && height == s->height) return;
    s->width = width;
    s->height = height;
    SEND(MGL_SURFACE_RESIZE, s->id, (uint32_t)width, (uint32_t)height);
}

static surface *window_surface(const struct wl_egl_window *w, void *data) {
    for (surface *s = surfaces; s; s = s->next)
        if (s == data && s->window && (!w || s->window == w)) return s;
    return NULL;
}

/* wl_egl_window_resize: the pictures from here on are of the new size. */
static void window_resized(struct wl_egl_window *w, void *data) {
    LOCKED;
    surface *s = window_surface(w, data);
    if (s) follow_window(s);
}

/* wl_egl_window_destroy: the window and its wl_surface are not to be touched again. */
static void window_destroyed(void *data) {
    LOCKED;
    surface *s = window_surface(NULL, data);
    if (!s) return;
    s->window = NULL;
    if (s->wl) mgl_wl_surface_gone(s->wl);
    s->wl = NULL;
}

static void free_surface(surface *s) {
    for (surface **at = &surfaces; *at; at = &(*at)->next)
        if (*at == s) {
            *at = s->next;
            break;
        }
    SEND(MGL_SURFACE_DESTROY, s->id);
    if (s->wl) mgl_wl_surface_gone(s->wl);
    if (s->window) {
        s->window->driver_private = NULL;
        s->window->resize_callback = NULL;
        s->window->destroy_window_callback = NULL;
    }
    free(s);
}

static void free_context(mgl_context *c) {
    for (mgl_context **at = &contexts; *at; at = &(*at)->next)
        if (*at == c) {
            *at = c->next;
            break;
        }
    SEND(MGL_CONTEXT_DESTROY, c->id);
    mgl_context_free(c);
}

/* What is current somewhere lives on until it is not (as EGL has it); its handle is none from now. */
static void destroy_surface(surface *s) {
    s->destroyed = true;
    if (s->bound == 0) free_surface(s);
}

static void destroy_context(mgl_context *c) {
    c->destroyed = true;
    if (!c->current) free_context(c);
}

/* A thread's current context becomes `c` on `draw` and `rd`, or none: all
 * of eglMakeCurrent but the thread's own note of it. */
static void make_current(mgl_context *before, mgl_context *c, surface *draw, surface *rd) {
    surface *old_draw = NULL, *old_rd = NULL;
    if (before) {
        old_draw = surface_named(before->draw);
        old_rd = surface_named(before->rd);
        before->current = false;
        before->draw = before->rd = 0;
        if (old_draw) old_draw->bound--;
        if (old_rd) old_rd->bound--;
    }
    if (c) {
        c->current = true;
        c->draw = draw->id;
        c->rd = rd->id;
        draw->bound++;
        rd->bound++;
        c->alpha_bits = configs[draw->config].alpha;
        c->depth_bits = configs[draw->config].depth;
        c->stencil_bits = configs[draw->config].stencil;
        if (!c->was_current) {
            c->was_current = true;
            mgl_context_first_surface(c, draw->width, draw->height);
        }
        mgl_make_current(c->id, c->draw, c->rd);
    } else if (before && mgl_conn_context() == before->id) {
        /* The Mac is not left with a context current that may be destroyed next. */
        mgl_make_current(0, 0, 0);
    }
    if (before && before->destroyed && !before->current) free_context(before);
    if (old_draw && old_draw->destroyed && old_draw->bound == 0) free_surface(old_draw);
    if (old_rd && old_rd != old_draw && old_rd->destroyed && old_rd->bound == 0) free_surface(old_rd);
    close_when_idle();
}

/* A thread that ends with a context current lets go of it, so that
 * another thread can have it, or it can be destroyed. The context is the
 * key's value: the thread's own variables may be gone by now. */
static pthread_key_t thread_key;
static pthread_once_t thread_key_once = PTHREAD_ONCE_INIT;

static void thread_ended(void *context) {
    LOCKED;
    for (mgl_context *c = contexts; c; c = c->next)
        if (c == context && c->current) {
            make_current(c, NULL, NULL, NULL);
            break;
        }
}

static void make_thread_key(void) { (void)pthread_key_create(&thread_key, thread_ended); }

static void set_thread_context(mgl_context *c) {
    thread.context = c;
    (void)pthread_once(&thread_key_once, make_thread_key);
    (void)pthread_setspecific(thread_key, c);
}

/* ---- Displays ---- */

static EGLDisplay get_display(void *native) {
    LOCKED;
    display *spare = NULL;
    for (int i = 0; i < DISPLAYS; i++) {
        if (displays[i].used && displays[i].native == native) return &displays[i];
        if (!displays[i].used && !spare) spare = &displays[i];
    }
    if (!spare) return EGL_NO_DISPLAY;
    spare->used = true;
    spare->native = native;
    return spare;
}

MGL_API EGLDisplay eglGetDisplay(EGLNativeDisplayType display_id) {
    thread.error = EGL_SUCCESS;
    return get_display(display_id);
}

static EGLDisplay get_platform_display(EGLenum platform, void *native, bool attribs) {
    if (platform != EGL_PLATFORM_WAYLAND_KHR) {
        fail(EGL_BAD_PARAMETER);
        return EGL_NO_DISPLAY;
    }
    if (attribs) {
        fail(EGL_BAD_ATTRIBUTE);
        return EGL_NO_DISPLAY;
    }
    thread.error = EGL_SUCCESS;
    return get_display(native);
}

MGL_API EGLDisplay eglGetPlatformDisplay(EGLenum platform, void *native_display, const EGLAttrib *attrib_list) {
    return get_platform_display(platform, native_display, attrib_list && attrib_list[0] != EGL_NONE);
}

MGL_API EGLDisplay eglGetPlatformDisplayEXT(EGLenum platform, void *native_display, const EGLint *attrib_list) {
    return get_platform_display(platform, native_display, attrib_list && attrib_list[0] != EGL_NONE);
}

MGL_API EGLBoolean eglInitialize(EGLDisplay dpy, EGLint *major, EGLint *minor) {
    LOCKED;
    display *d = a_display(dpy);
    if (!d) return fail(EGL_BAD_DISPLAY);
    if (!d->initialized) {
        /* No window manager to draw for (GPU drawing is off for this VM), or not Monad's. */
        if (!mgl_conn_open()) return fail(EGL_NOT_INITIALIZED);
        if (d->native && !(d->wl = mgl_wl_bind(d->native))) {
            close_when_idle();
            return fail(EGL_NOT_INITIALIZED);
        }
        d->initialized = true;
    }
    if (major) *major = 1;
    if (minor) *minor = 4;
    return done();
}

MGL_API EGLBoolean eglTerminate(EGLDisplay dpy) {
    LOCKED;
    display *d = a_display(dpy);
    if (!d) return fail(EGL_BAD_DISPLAY);
    if (!d->initialized) return done();
    for (surface *s = surfaces, *next; s; s = next) {
        next = s->next;
        if (s->dpy == d && !s->destroyed) destroy_surface(s);
    }
    for (mgl_context *c = contexts, *next; c; c = next) {
        next = c->next;
        if (c->display == d && !c->destroyed) destroy_context(c);
    }
    /* A surface still current somewhere lives on, without its Wayland side: that goes with the display's. */
    for (surface *s = surfaces; s; s = s->next)
        if (s->dpy == d && s->wl) {
            mgl_wl_surface_gone(s->wl);
            s->wl = NULL;
        }
    if (d->wl) mgl_wl_unbind(d->wl);
    d->wl = NULL;
    d->initialized = false;
    close_when_idle();
    return done();
}

MGL_API const char *eglQueryString(EGLDisplay dpy, EGLint name) {
    LOCKED;
    if (dpy == EGL_NO_DISPLAY && name == EGL_EXTENSIONS) {
        thread.error = EGL_SUCCESS;
        return "EGL_EXT_client_extensions EGL_EXT_platform_base EGL_KHR_platform_wayland EGL_EXT_platform_wayland";
    }
    if (!ready(dpy)) return NULL;
    thread.error = EGL_SUCCESS;
    switch (name) {
    case EGL_VENDOR: return "Monad";
    case EGL_VERSION: return "1.4";
    case EGL_EXTENSIONS: return "";
    case EGL_CLIENT_APIS: return "OpenGL_ES";
    default:
        fail(EGL_BAD_PARAMETER);
        return NULL;
    }
}

/* ---- Configs ---- */

/* What a config has for an attribute. False: EGL has no such attribute. */
static bool config_attrib(const display *d, int k, EGLint attribute, EGLint *value) {
    switch (attribute) {
    case EGL_BUFFER_SIZE: *value = 24 + configs[k].alpha; break;
    case EGL_RED_SIZE:
    case EGL_GREEN_SIZE:
    case EGL_BLUE_SIZE: *value = 8; break;
    case EGL_ALPHA_SIZE: *value = configs[k].alpha; break;
    case EGL_DEPTH_SIZE: *value = configs[k].depth; break;
    case EGL_STENCIL_SIZE: *value = configs[k].stencil; break;
    case EGL_CONFIG_ID: *value = k + 1; break;
    case EGL_CONFIG_CAVEAT:
    case EGL_NATIVE_VISUAL_TYPE:
    case EGL_TRANSPARENT_TYPE: *value = EGL_NONE; break;
    case EGL_COLOR_BUFFER_TYPE: *value = EGL_RGB_BUFFER; break;
    case EGL_RENDERABLE_TYPE:
    case EGL_CONFORMANT: *value = EGL_OPENGL_ES2_BIT; break;
    /* Windows only on a Wayland display. */
    case EGL_SURFACE_TYPE: *value = EGL_PBUFFER_BIT | (d->native ? EGL_WINDOW_BIT : 0); break;
    case EGL_MAX_PBUFFER_WIDTH:
    case EGL_MAX_PBUFFER_HEIGHT: *value = MGL_MAX_SIZE; break;
    case EGL_MAX_PBUFFER_PIXELS: *value = MGL_MAX_SIZE * MGL_MAX_SIZE; break;
    case EGL_MAX_SWAP_INTERVAL: *value = 1; break;
    /* The wl_shm format a window of it would have: ARGB8888 (0) or XRGB8888 (1). */
    case EGL_NATIVE_VISUAL_ID: *value = configs[k].alpha ? 0 : 1; break;
    case EGL_MIN_SWAP_INTERVAL:
    case EGL_LEVEL:
    case EGL_SAMPLES:
    case EGL_SAMPLE_BUFFERS:
    case EGL_LUMINANCE_SIZE:
    case EGL_ALPHA_MASK_SIZE:
    case EGL_BIND_TO_TEXTURE_RGB:
    case EGL_BIND_TO_TEXTURE_RGBA:
    case EGL_NATIVE_RENDERABLE:
    case EGL_TRANSPARENT_RED_VALUE:
    case EGL_TRANSPARENT_GREEN_VALUE:
    case EGL_TRANSPARENT_BLUE_VALUE: *value = 0; break;
    default: return false;
    }
    return true;
}

MGL_API EGLBoolean eglGetConfigAttrib(EGLDisplay dpy, EGLConfig config, EGLint attribute, EGLint *value) {
    LOCKED;
    const display *d = ready(dpy);
    if (!d) return EGL_FALSE;
    int k = a_config(config);
    if (k < 0) return fail(EGL_BAD_CONFIG);
    EGLint v;
    if (!config_attrib(d, k, attribute, &v)) return fail(EGL_BAD_ATTRIBUTE);
    if (!value) return fail(EGL_BAD_PARAMETER);
    *value = v;
    return done();
}

MGL_API EGLBoolean eglGetConfigs(EGLDisplay dpy, EGLConfig *list, EGLint config_size, EGLint *num_config) {
    LOCKED;
    if (!ready(dpy)) return EGL_FALSE;
    if (!num_config) return fail(EGL_BAD_PARAMETER);
    EGLint n = 0;
    for (int k = 0; k < CONFIGS && (!list || n < config_size); k++, n++)
        if (list) list[n] = (EGLConfig)&configs[k];
    *num_config = n;
    return done();
}

/* How eglChooseConfig holds a config's attribute against what was asked. */
enum { AT_LEAST, EXACT, MASK, IGNORED, UNKNOWN };
static int rule(EGLint attribute) {
    switch (attribute) {
    case EGL_BUFFER_SIZE:
    case EGL_RED_SIZE:
    case EGL_GREEN_SIZE:
    case EGL_BLUE_SIZE:
    case EGL_ALPHA_SIZE:
    case EGL_LUMINANCE_SIZE:
    case EGL_ALPHA_MASK_SIZE:
    case EGL_DEPTH_SIZE:
    case EGL_STENCIL_SIZE:
    case EGL_SAMPLES:
    case EGL_SAMPLE_BUFFERS: return AT_LEAST;
    case EGL_SURFACE_TYPE:
    case EGL_RENDERABLE_TYPE:
    case EGL_CONFORMANT: return MASK;
    case EGL_BIND_TO_TEXTURE_RGB:
    case EGL_BIND_TO_TEXTURE_RGBA:
    case EGL_COLOR_BUFFER_TYPE:
    case EGL_CONFIG_CAVEAT:
    case EGL_CONFIG_ID:
    case EGL_LEVEL:
    case EGL_MAX_SWAP_INTERVAL:
    case EGL_MIN_SWAP_INTERVAL:
    case EGL_NATIVE_RENDERABLE:
    case EGL_NATIVE_VISUAL_TYPE:
    case EGL_TRANSPARENT_TYPE: return EXACT;
    /* Asked for with a transparent type only, and there is none. */
    case EGL_TRANSPARENT_RED_VALUE:
    case EGL_TRANSPARENT_GREEN_VALUE:
    case EGL_TRANSPARENT_BLUE_VALUE:
    case EGL_MAX_PBUFFER_WIDTH:
    case EGL_MAX_PBUFFER_HEIGHT:
    case EGL_MAX_PBUFFER_PIXELS:
    case EGL_NATIVE_VISUAL_ID:
    case EGL_MATCH_NATIVE_PIXMAP: return IGNORED;
    default: return UNKNOWN;
    }
}

enum { FIRST = EGL_BUFFER_SIZE, ATTRIBUTES = EGL_CONFORMANT - EGL_BUFFER_SIZE + 1 };

/* EGL 1.4's order (3.4.1.2) for the configs there are: more bits of the
 * colours asked for first, then the smaller colour buffer, the smaller
 * depth buffer, the smaller stencil buffer, the smaller id. */
static bool sorts_before(const EGLint *want, int a, int b) {
    int bits_a = 0, bits_b = 0;
    static const EGLint colours[] = {EGL_RED_SIZE, EGL_GREEN_SIZE, EGL_BLUE_SIZE, EGL_ALPHA_SIZE};
    for (int i = 0; i < 4; i++)
        if (want[colours[i] - FIRST] > 0) {
            bits_a += colours[i] == EGL_ALPHA_SIZE ? configs[a].alpha : 8;
            bits_b += colours[i] == EGL_ALPHA_SIZE ? configs[b].alpha : 8;
        }
    if (bits_a != bits_b) return bits_a > bits_b;
    if (configs[a].alpha != configs[b].alpha) return configs[a].alpha < configs[b].alpha;
    if (configs[a].depth != configs[b].depth) return configs[a].depth < configs[b].depth;
    if (configs[a].stencil != configs[b].stencil) return configs[a].stencil < configs[b].stencil;
    return a < b;
}

MGL_API EGLBoolean eglChooseConfig(EGLDisplay dpy, const EGLint *attrib_list, EGLConfig *list, EGLint config_size, EGLint *num_config) {
    LOCKED;
    const display *d = ready(dpy);
    if (!d) return EGL_FALSE;
    if (!num_config) return fail(EGL_BAD_PARAMETER);

    /* What is asked, by attribute; what is not asked has EGL's default. */
    EGLint want[ATTRIBUTES];
    for (int i = 0; i < ATTRIBUTES; i++) want[i] = rule(FIRST + i) == AT_LEAST ? 0 : EGL_DONT_CARE;
    want[EGL_COLOR_BUFFER_TYPE - FIRST] = EGL_RGB_BUFFER;
    want[EGL_LEVEL - FIRST] = 0;
    want[EGL_SURFACE_TYPE - FIRST] = EGL_WINDOW_BIT;
    want[EGL_TRANSPARENT_TYPE - FIRST] = EGL_NONE;
    /* EGL's default for EGL_RENDERABLE_TYPE is OpenGL ES 1, which no
     * config here has: a program that does not say gets the configs
     * there are, and finds out at eglCreateContext what they are for. */
    for (int i = 0; attrib_list && attrib_list[i] != EGL_NONE; i += 2) {
        if (attrib_list[i] < FIRST || attrib_list[i] >= FIRST + ATTRIBUTES || rule(attrib_list[i]) == UNKNOWN) return fail(EGL_BAD_ATTRIBUTE);
        want[attrib_list[i] - FIRST] = attrib_list[i + 1];
    }

    int chosen[CONFIGS], n = 0;
    for (int k = 0; k < CONFIGS; k++) {
        bool match = true;
        for (int i = 0; i < ATTRIBUTES && match; i++) {
            EGLint asked = want[i], has = 0;
            int how = rule(FIRST + i);
            /* An id asked for is all that is looked at. */
            if (want[EGL_CONFIG_ID - FIRST] != EGL_DONT_CARE && FIRST + i != EGL_CONFIG_ID) continue;
            if (asked == EGL_DONT_CARE || how == IGNORED || how == UNKNOWN) continue;
            (void)config_attrib(d, k, FIRST + i, &has);
            match = how == AT_LEAST ? has >= asked : how == MASK ? (has & asked) == asked : has == asked;
        }
        if (!match) continue;
        /* Into its place among the ones chosen so far. */
        int at = n++;
        for (; at > 0 && sorts_before(want, k, chosen[at - 1]); at--) chosen[at] = chosen[at - 1];
        chosen[at] = k;
    }
    if (list) {
        if (n > config_size) n = config_size < 0 ? 0 : config_size;
        for (int i = 0; i < n; i++) list[i] = (EGLConfig)&configs[chosen[i]];
    }
    *num_config = n;
    return done();
}

/* ---- Surfaces ---- */

static surface *new_surface(display *d, int config, int width, int height) {
    surface *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    s->dpy = d;
    s->config = config;
    s->id = ++last_surface;
    s->width = width;
    s->height = height;
    s->interval = 1;
    s->next = surfaces;
    surfaces = s;
    return s;
}

static EGLSurface create_window_surface(EGLDisplay dpy, EGLConfig config, void *native, const void *attribs, bool wide) {
    LOCKED;
    display *d = ready(dpy);
    if (!d) return EGL_NO_SURFACE;
    int k = a_config(config);
    EGLint error = EGL_SUCCESS;
    struct wl_egl_window *w = native;
    if (k < 0) error = EGL_BAD_CONFIG;
    /* The default display has no windows: none of its configs is for one. */
    else if (!d->wl) error = EGL_BAD_MATCH;
    else if (!w || w->version != 3 || !w->surface || w->width <= 0 || w->height <= 0) error = EGL_BAD_NATIVE_WINDOW;
    for (int i = 0; error == EGL_SUCCESS && attribs && item(attribs, wide, i) != EGL_NONE; i += 2) {
        /* Which buffer is drawn to is not the program's to choose (always the back one); the rest is OpenVG's. */
        intptr_t name = item(attribs, wide, i);
        if (name != EGL_RENDER_BUFFER && name != EGL_VG_COLORSPACE && name != EGL_VG_ALPHA_FORMAT) error = EGL_BAD_ATTRIBUTE;
    }
    /* One surface a window. */
    for (surface *s = surfaces; s && error == EGL_SUCCESS; s = s->next)
        if (s->window == w) error = EGL_BAD_ALLOC;
    if (error != EGL_SUCCESS) {
        fail(error);
        return EGL_NO_SURFACE;
    }
    int width = w->width > MGL_MAX_SIZE ? MGL_MAX_SIZE : w->width, height = w->height > MGL_MAX_SIZE ? MGL_MAX_SIZE : w->height;
    mgl_wl_surface *wl = mgl_wl_surface_new(d->wl, w->surface);
    surface *s = wl ? new_surface(d, k, width, height) : NULL;
    if (!s) {
        if (wl) mgl_wl_surface_gone(wl);
        fail(EGL_BAD_ALLOC);
        return EGL_NO_SURFACE;
    }
    s->is_window = true;
    s->window = w;
    s->wl = wl;
    w->driver_private = s;
    w->resize_callback = window_resized;
    w->destroy_window_callback = window_destroyed;
    surface_created(s);
    thread.error = EGL_SUCCESS;
    return s;
}

MGL_API EGLSurface eglCreateWindowSurface(EGLDisplay dpy, EGLConfig config, EGLNativeWindowType win, const EGLint *attrib_list) {
    return create_window_surface(dpy, config, win, attrib_list, false);
}

MGL_API EGLSurface eglCreatePlatformWindowSurface(EGLDisplay dpy, EGLConfig config, void *native_window, const EGLAttrib *attrib_list) {
    return create_window_surface(dpy, config, native_window, attrib_list, true);
}

MGL_API EGLSurface eglCreatePlatformWindowSurfaceEXT(EGLDisplay dpy, EGLConfig config, void *native_window, const EGLint *attrib_list) {
    return create_window_surface(dpy, config, native_window, attrib_list, false);
}

MGL_API EGLSurface eglCreatePbufferSurface(EGLDisplay dpy, EGLConfig config, const EGLint *attrib_list) {
    LOCKED;
    display *d = ready(dpy);
    if (!d) return EGL_NO_SURFACE;
    int k = a_config(config);
    EGLint error = k < 0 ? EGL_BAD_CONFIG : EGL_SUCCESS, width = 0, height = 0;
    bool largest = false;
    for (int i = 0; error == EGL_SUCCESS && attrib_list && attrib_list[i] != EGL_NONE; i += 2) {
        EGLint value = attrib_list[i + 1];
        switch (attrib_list[i]) {
        case EGL_WIDTH: width = value; break;
        case EGL_HEIGHT: height = value; break;
        case EGL_LARGEST_PBUFFER: largest = value != EGL_FALSE; break;
        /* No config here can be bound to a texture. */
        case EGL_TEXTURE_FORMAT:
        case EGL_TEXTURE_TARGET:
            if (value != EGL_NO_TEXTURE) error = EGL_BAD_MATCH;
            break;
        case EGL_MIPMAP_TEXTURE:
        case EGL_VG_COLORSPACE:
        case EGL_VG_ALPHA_FORMAT: break;
        default: error = EGL_BAD_ATTRIBUTE;
        }
    }
    if (error == EGL_SUCCESS && (width < 0 || height < 0)) error = EGL_BAD_PARAMETER;
    if (error == EGL_SUCCESS && largest) {
        if (width > MGL_MAX_SIZE) width = MGL_MAX_SIZE;
        if (height > MGL_MAX_SIZE) height = MGL_MAX_SIZE;
    }
    if (error == EGL_SUCCESS && (width > MGL_MAX_SIZE || height > MGL_MAX_SIZE)) error = EGL_BAD_ALLOC;
    surface *s = error == EGL_SUCCESS ? new_surface(d, k, width, height) : NULL;
    if (!s) {
        fail(error == EGL_SUCCESS ? EGL_BAD_ALLOC : error);
        return EGL_NO_SURFACE;
    }
    s->largest = largest;
    surface_created(s);
    thread.error = EGL_SUCCESS;
    return s;
}

/* There are no pixmaps, and nothing of OpenVG's to make a pbuffer from: these only fail, each as EGL has it. */
static EGLSurface no_pixmap_surface(EGLDisplay dpy, EGLConfig config) {
    LOCKED;
    if (ready(dpy)) fail(a_config(config) < 0 ? EGL_BAD_CONFIG : EGL_BAD_MATCH);
    return EGL_NO_SURFACE;
}

MGL_API EGLSurface eglCreatePixmapSurface(EGLDisplay dpy, EGLConfig config, EGLNativePixmapType pixmap, const EGLint *attrib_list) {
    (void)pixmap, (void)attrib_list;
    return no_pixmap_surface(dpy, config);
}

MGL_API EGLSurface eglCreatePlatformPixmapSurface(EGLDisplay dpy, EGLConfig config, void *native_pixmap, const EGLAttrib *attrib_list) {
    (void)native_pixmap, (void)attrib_list;
    return no_pixmap_surface(dpy, config);
}

MGL_API EGLSurface eglCreatePlatformPixmapSurfaceEXT(EGLDisplay dpy, EGLConfig config, void *native_pixmap, const EGLint *attrib_list) {
    (void)native_pixmap, (void)attrib_list;
    return no_pixmap_surface(dpy, config);
}

MGL_API EGLSurface eglCreatePbufferFromClientBuffer(EGLDisplay dpy, EGLenum buftype, EGLClientBuffer buffer, EGLConfig config,
                                                    const EGLint *attrib_list) {
    (void)buftype, (void)buffer, (void)attrib_list;
    LOCKED;
    if (ready(dpy)) fail(a_config(config) < 0 ? EGL_BAD_CONFIG : EGL_BAD_PARAMETER);
    return EGL_NO_SURFACE;
}

MGL_API EGLBoolean eglCopyBuffers(EGLDisplay dpy, EGLSurface handle, EGLNativePixmapType target) {
    (void)target;
    LOCKED;
    const display *d = ready(dpy);
    if (!d) return EGL_FALSE;
    return fail(a_surface(d, handle) ? EGL_BAD_NATIVE_PIXMAP : EGL_BAD_SURFACE);
}

/* No surface is a texture's picture: a pbuffer's EGL_TEXTURE_FORMAT is always EGL_NO_TEXTURE. */
static EGLBoolean no_texture_image(EGLDisplay dpy, EGLSurface handle) {
    LOCKED;
    const display *d = ready(dpy);
    if (!d) return EGL_FALSE;
    const surface *s = a_surface(d, handle);
    return fail(s && !s->is_window ? EGL_BAD_MATCH : EGL_BAD_SURFACE);
}

MGL_API EGLBoolean eglBindTexImage(EGLDisplay dpy, EGLSurface handle, EGLint buffer) {
    (void)buffer;
    return no_texture_image(dpy, handle);
}

MGL_API EGLBoolean eglReleaseTexImage(EGLDisplay dpy, EGLSurface handle, EGLint buffer) {
    (void)buffer;
    return no_texture_image(dpy, handle);
}

MGL_API EGLBoolean eglDestroySurface(EGLDisplay dpy, EGLSurface handle) {
    LOCKED;
    const display *d = ready(dpy);
    if (!d) return EGL_FALSE;
    surface *s = a_surface(d, handle);
    if (!s) return fail(EGL_BAD_SURFACE);
    destroy_surface(s);
    return done();
}

MGL_API EGLBoolean eglQuerySurface(EGLDisplay dpy, EGLSurface handle, EGLint attribute, EGLint *value) {
    LOCKED;
    const display *d = ready(dpy);
    if (!d) return EGL_FALSE;
    const surface *s = a_surface(d, handle);
    if (!s) return fail(EGL_BAD_SURFACE);
    EGLint v;
    switch (attribute) {
    case EGL_WIDTH: v = s->width; break;
    case EGL_HEIGHT: v = s->height; break;
    case EGL_CONFIG_ID: v = s->config + 1; break;
    case EGL_RENDER_BUFFER: v = EGL_BACK_BUFFER; break;
    case EGL_SWAP_BEHAVIOR: v = EGL_BUFFER_DESTROYED; break;
    case EGL_MULTISAMPLE_RESOLVE: v = EGL_MULTISAMPLE_RESOLVE_DEFAULT; break;
    case EGL_LARGEST_PBUFFER: v = s->largest; break;
    case EGL_TEXTURE_FORMAT:
    case EGL_TEXTURE_TARGET: v = EGL_NO_TEXTURE; break;
    case EGL_MIPMAP_TEXTURE:
    case EGL_MIPMAP_LEVEL: v = 0; break;
    case EGL_HORIZONTAL_RESOLUTION:
    case EGL_VERTICAL_RESOLUTION:
    case EGL_PIXEL_ASPECT_RATIO: v = EGL_UNKNOWN; break;
    case EGL_VG_COLORSPACE: v = EGL_VG_COLORSPACE_sRGB; break;
    case EGL_VG_ALPHA_FORMAT: v = EGL_VG_ALPHA_FORMAT_NONPRE; break;
    default: return fail(EGL_BAD_ATTRIBUTE);
    }
    if (value) *value = v;
    return done();
}

MGL_API EGLBoolean eglSurfaceAttrib(EGLDisplay dpy, EGLSurface handle, EGLint attribute, EGLint value) {
    LOCKED;
    const display *d = ready(dpy);
    if (!d) return EGL_FALSE;
    if (!a_surface(d, handle)) return fail(EGL_BAD_SURFACE);
    switch (attribute) {
    case EGL_MIPMAP_LEVEL: return done();
    /* What is drawn is gone after a swap, samples are resolved one way, and no config says otherwise. */
    case EGL_SWAP_BEHAVIOR:
        if (value == EGL_BUFFER_DESTROYED) return done();
        return fail(value == EGL_BUFFER_PRESERVED ? EGL_BAD_MATCH : EGL_BAD_PARAMETER);
    case EGL_MULTISAMPLE_RESOLVE:
        if (value == EGL_MULTISAMPLE_RESOLVE_DEFAULT) return done();
        return fail(value == EGL_MULTISAMPLE_RESOLVE_BOX ? EGL_BAD_MATCH : EGL_BAD_PARAMETER);
    default: return fail(EGL_BAD_ATTRIBUTE);
    }
}

/* ---- Contexts ---- */

MGL_API EGLBoolean eglBindAPI(EGLenum api) { return api == EGL_OPENGL_ES_API ? done() : fail(EGL_BAD_PARAMETER); }

MGL_API EGLenum eglQueryAPI(void) { return EGL_OPENGL_ES_API; }

MGL_API EGLContext eglCreateContext(EGLDisplay dpy, EGLConfig config, EGLContext share_context, const EGLint *attrib_list) {
    LOCKED;
    display *d = ready(dpy);
    if (!d) return EGL_NO_CONTEXT;
    int k = a_config(config);
    mgl_context *share = a_context(d, share_context);
    /* EGL's default is OpenGL ES 1, which is not offered. */
    EGLint error = k < 0 ? EGL_BAD_CONFIG : share_context != EGL_NO_CONTEXT && !share ? EGL_BAD_CONTEXT : EGL_SUCCESS, version = 1;
    for (int i = 0; error == EGL_SUCCESS && attrib_list && attrib_list[i] != EGL_NONE; i += 2) {
        if (attrib_list[i] == EGL_CONTEXT_CLIENT_VERSION) version = attrib_list[i + 1];
        else error = EGL_BAD_ATTRIBUTE;
    }
    if (error == EGL_SUCCESS && version != 2) error = version == 1 ? EGL_BAD_CONFIG : EGL_BAD_ATTRIBUTE;
    mgl_context *c = error == EGL_SUCCESS ? mgl_context_new(share) : NULL;
    if (!c) {
        fail(error == EGL_SUCCESS ? EGL_BAD_ALLOC : error);
        return EGL_NO_CONTEXT;
    }
    c->id = ++last_context;
    c->display = d;
    c->config = k;
    c->next = contexts;
    contexts = c;
    SEND(MGL_CONTEXT_CREATE, c->id, share ? share->id : 0);
    thread.error = EGL_SUCCESS;
    return c;
}

MGL_API EGLBoolean eglDestroyContext(EGLDisplay dpy, EGLContext ctx) {
    LOCKED;
    const display *d = ready(dpy);
    if (!d) return EGL_FALSE;
    mgl_context *c = a_context(d, ctx);
    if (!c) return fail(EGL_BAD_CONTEXT);
    destroy_context(c);
    return done();
}

MGL_API EGLBoolean eglMakeCurrent(EGLDisplay dpy, EGLSurface draw, EGLSurface rd, EGLContext ctx) {
    LOCKED;
    const display *d = a_display(dpy);
    mgl_context *c = NULL;
    surface *to_draw = NULL, *to_read = NULL;
    if (ctx == EGL_NO_CONTEXT && draw == EGL_NO_SURFACE && rd == EGL_NO_SURFACE) {
        /* Letting go asks nothing of the display, which may be terminated by now. */
        if (!d && dpy != EGL_NO_DISPLAY) return fail(EGL_BAD_DISPLAY);
    } else {
        if (!(d = ready(dpy))) return EGL_FALSE;
        if (ctx == EGL_NO_CONTEXT || draw == EGL_NO_SURFACE || rd == EGL_NO_SURFACE) return fail(EGL_BAD_MATCH);
        if (!(c = a_context(d, ctx))) return fail(EGL_BAD_CONTEXT);
        to_draw = a_surface(d, draw);
        to_read = a_surface(d, rd);
        if (!to_draw || !to_read) return fail(EGL_BAD_SURFACE);
        /* A context and a surface are one thread's at a time. */
        const mgl_context *mine = thread.context;
        if (c->current && c != mine) return fail(EGL_BAD_ACCESS);
        if ((to_draw->bound > 0 && !(mine && (mine->draw == to_draw->id || mine->rd == to_draw->id))) ||
            (to_read->bound > 0 && !(mine && (mine->draw == to_read->id || mine->rd == to_read->id))))
            return fail(EGL_BAD_ACCESS);
    }
    mgl_context *old = thread.context;
    set_thread_context(c);
    make_current(old, c, to_draw, to_read);
    return done();
}

MGL_API EGLBoolean eglReleaseThread(void) {
    LOCKED;
    mgl_context *old = thread.context;
    if (old) {
        set_thread_context(NULL);
        make_current(old, NULL, NULL, NULL);
    }
    return done();
}

MGL_API EGLContext eglGetCurrentContext(void) { return thread.context; }

MGL_API EGLDisplay eglGetCurrentDisplay(void) { return thread.context ? thread.context->display : EGL_NO_DISPLAY; }

MGL_API EGLSurface eglGetCurrentSurface(EGLint readdraw) {
    LOCKED;
    if (readdraw != EGL_DRAW && readdraw != EGL_READ) {
        fail(EGL_BAD_PARAMETER);
        return EGL_NO_SURFACE;
    }
    const mgl_context *c = thread.context;
    thread.error = EGL_SUCCESS;
    return c ? surface_named(readdraw == EGL_DRAW ? c->draw : c->rd) : EGL_NO_SURFACE;
}

MGL_API EGLBoolean eglQueryContext(EGLDisplay dpy, EGLContext ctx, EGLint attribute, EGLint *value) {
    LOCKED;
    const display *d = ready(dpy);
    if (!d) return EGL_FALSE;
    const mgl_context *c = a_context(d, ctx);
    if (!c) return fail(EGL_BAD_CONTEXT);
    EGLint v;
    switch (attribute) {
    case EGL_CONFIG_ID: v = c->config + 1; break;
    case EGL_CONTEXT_CLIENT_TYPE: v = EGL_OPENGL_ES_API; break;
    case EGL_CONTEXT_CLIENT_VERSION: v = 2; break;
    case EGL_RENDER_BUFFER: v = c->current ? EGL_BACK_BUFFER : EGL_NONE; break;
    default: return fail(EGL_BAD_ATTRIBUTE);
    }
    if (value) *value = v;
    return done();
}

MGL_API EGLint eglGetError(void) {
    EGLint error = thread.error ? thread.error : EGL_SUCCESS;
    thread.error = EGL_SUCCESS;
    return error;
}

/* ---- A picture is done ---- */

MGL_API EGLBoolean eglSwapBuffers(EGLDisplay dpy, EGLSurface handle) {
    mgl_lock();
    const display *d = ready(dpy);
    surface *s = d ? a_surface(d, handle) : NULL;
    const mgl_context *c = thread.context;
    EGLint error = EGL_SUCCESS;
    if (!d) error = thread.error;
    /* The surface swapped is the one the thread draws on. */
    else if (!s || !c || c->draw != s->id) error = EGL_BAD_SURFACE;
    else if (mgl_conn_lost()) error = EGL_CONTEXT_LOST;
    else if (s->is_window) {
        /* Waits for the Mac to have drawn the picture before this one, not this one. */
        if (!mgl_swap(s->id)) error = EGL_CONTEXT_LOST;
    } else {
        /* A pbuffer shows nothing; what was drawn to it is sent all the same. */
        if (!mgl_flush()) error = EGL_CONTEXT_LOST;
        mgl_unlock();
        return error == EGL_SUCCESS ? done() : fail(error);
    }
    if (error != EGL_SUCCESS) {
        mgl_unlock();
        return fail(error);
    }
    mgl_wl_surface *wl = s->wl;
    uint32_t stream = mgl_conn_stream(), id = s->id;
    int width = s->width, height = s->height, interval = s->interval;
    if (s->window) {
        s->window->attached_width = width;
        s->window->attached_height = height;
    }
    mgl_unlock();

    /* Without the lock: this waits for the frame before to be shown, and
     * other threads draw meanwhile. The surface stays: it is current here. */
    bool shown = wl ? mgl_wl_present(wl, stream, id, width, height, interval) : true;

    mgl_lock();
    follow_window(s);
    mgl_unlock();
    return shown ? done() : fail(EGL_BAD_NATIVE_WINDOW);
}

MGL_API EGLBoolean eglSwapInterval(EGLDisplay dpy, EGLint interval) {
    LOCKED;
    if (!ready(dpy)) return EGL_FALSE;
    const mgl_context *c = thread.context;
    if (!c) return fail(EGL_BAD_CONTEXT);
    surface *s = surface_named(c->draw);
    if (!s) return fail(EGL_BAD_SURFACE);
    /* EGL_MIN_SWAP_INTERVAL to EGL_MAX_SWAP_INTERVAL. */
    s->interval = interval < 0 ? 0 : interval > 1 ? 1 : interval;
    return done();
}

MGL_API EGLBoolean eglWaitClient(void) {
    glFinish();
    return done();
}

MGL_API EGLBoolean eglWaitGL(void) { return eglWaitClient(); }

MGL_API EGLBoolean eglWaitNative(EGLint engine) { return engine == EGL_CORE_NATIVE_ENGINE ? done() : fail(EGL_BAD_PARAMETER); }

/* ---- Entry points by name ---- */

#define GL_NAMES(X) \
    X(glActiveTexture) X(glAttachShader) X(glBindAttribLocation) X(glBindBuffer) X(glBindFramebuffer) X(glBindRenderbuffer) \
    X(glBindTexture) X(glBlendColor) X(glBlendEquation) X(glBlendEquationSeparate) X(glBlendFunc) X(glBlendFuncSeparate) \
    X(glBufferData) X(glBufferSubData) X(glCheckFramebufferStatus) X(glClear) X(glClearColor) X(glClearDepthf) X(glClearStencil) \
    X(glColorMask) X(glCompileShader) X(glCompressedTexImage2D) X(glCompressedTexSubImage2D) X(glCopyTexImage2D) \
    X(glCopyTexSubImage2D) X(glCreateProgram) X(glCreateShader) X(glCullFace) X(glDeleteBuffers) X(glDeleteFramebuffers) \
    X(glDeleteProgram) X(glDeleteRenderbuffers) X(glDeleteShader) X(glDeleteTextures) X(glDepthFunc) X(glDepthMask) \
    X(glDepthRangef) X(glDetachShader) X(glDisable) X(glDisableVertexAttribArray) X(glDrawArrays) X(glDrawElements) X(glEnable) \
    X(glEnableVertexAttribArray) X(glFinish) X(glFlush) X(glFramebufferRenderbuffer) X(glFramebufferTexture2D) X(glFrontFace) \
    X(glGenBuffers) X(glGenerateMipmap) X(glGenFramebuffers) X(glGenRenderbuffers) X(glGenTextures) X(glGetActiveAttrib) \
    X(glGetActiveUniform) X(glGetAttachedShaders) X(glGetAttribLocation) X(glGetBooleanv) X(glGetBufferParameteriv) X(glGetError) \
    X(glGetFloatv) X(glGetFramebufferAttachmentParameteriv) X(glGetIntegerv) X(glGetProgramiv) X(glGetProgramInfoLog) \
    X(glGetRenderbufferParameteriv) X(glGetShaderiv) X(glGetShaderInfoLog) X(glGetShaderPrecisionFormat) X(glGetShaderSource) \
    X(glGetString) X(glGetTexParameterfv) X(glGetTexParameteriv) X(glGetUniformfv) X(glGetUniformiv) X(glGetUniformLocation) \
    X(glGetVertexAttribfv) X(glGetVertexAttribiv) X(glGetVertexAttribPointerv) X(glHint) X(glIsBuffer) X(glIsEnabled) \
    X(glIsFramebuffer) X(glIsProgram) X(glIsRenderbuffer) X(glIsShader) X(glIsTexture) X(glLineWidth) X(glLinkProgram) \
    X(glPixelStorei) X(glPolygonOffset) X(glReadPixels) X(glReleaseShaderCompiler) X(glRenderbufferStorage) X(glSampleCoverage) \
    X(glScissor) X(glShaderBinary) X(glShaderSource) X(glStencilFunc) X(glStencilFuncSeparate) X(glStencilMask) \
    X(glStencilMaskSeparate) X(glStencilOp) X(glStencilOpSeparate) X(glTexImage2D) X(glTexParameterf) X(glTexParameterfv) \
    X(glTexParameteri) X(glTexParameteriv) X(glTexSubImage2D) X(glUniform1f) X(glUniform1fv) X(glUniform1i) X(glUniform1iv) \
    X(glUniform2f) X(glUniform2fv) X(glUniform2i) X(glUniform2iv) X(glUniform3f) X(glUniform3fv) X(glUniform3i) X(glUniform3iv) \
    X(glUniform4f) X(glUniform4fv) X(glUniform4i) X(glUniform4iv) X(glUniformMatrix2fv) X(glUniformMatrix3fv) \
    X(glUniformMatrix4fv) X(glUseProgram) X(glValidateProgram) X(glVertexAttrib1f) X(glVertexAttrib1fv) X(glVertexAttrib2f) \
    X(glVertexAttrib2fv) X(glVertexAttrib3f) X(glVertexAttrib3fv) X(glVertexAttrib4f) X(glVertexAttrib4fv) \
    X(glVertexAttribPointer) X(glViewport)

#define EGL_NAMES(X) \
    X(eglBindAPI) X(eglBindTexImage) X(eglChooseConfig) X(eglCopyBuffers) X(eglCreateContext) \
    X(eglCreatePbufferFromClientBuffer) X(eglCreatePbufferSurface) X(eglCreatePixmapSurface) X(eglCreatePlatformPixmapSurface) \
    X(eglCreatePlatformPixmapSurfaceEXT) X(eglCreatePlatformWindowSurface) X(eglCreatePlatformWindowSurfaceEXT) \
    X(eglCreateWindowSurface) X(eglDestroyContext) X(eglDestroySurface) X(eglGetConfigAttrib) X(eglGetConfigs) \
    X(eglGetCurrentContext) X(eglGetCurrentDisplay) X(eglGetCurrentSurface) X(eglGetDisplay) X(eglGetError) \
    X(eglGetPlatformDisplay) X(eglGetPlatformDisplayEXT) X(eglGetProcAddress) X(eglInitialize) X(eglMakeCurrent) X(eglQueryAPI) \
    X(eglQueryContext) X(eglQueryString) X(eglQuerySurface) X(eglReleaseTexImage) X(eglReleaseThread) X(eglSurfaceAttrib) \
    X(eglSwapBuffers) X(eglSwapInterval) X(eglTerminate) X(eglWaitClient) X(eglWaitGL) X(eglWaitNative)

MGL_API void (*eglGetProcAddress(const char *procname))(void) {
    static const struct {
        const char *name;
        void (*address)(void);
    } procs[] = {
#define PROC(name) {#name, (void (*)(void))name},
        GL_NAMES(PROC) EGL_NAMES(PROC)
#undef PROC
    };
    for (size_t i = 0; procname && i < sizeof procs / sizeof procs[0]; i++)
        if (strcmp(procs[i].name, procname) == 0) return procs[i].address;
    return NULL;
}
