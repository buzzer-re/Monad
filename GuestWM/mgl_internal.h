/*
 * mgl_internal.h — what the files of Monad's EGL and OpenGL ES library
 * share (mgl_api.h says what the library is, mwm_gl_wire.h what it
 * writes): the connection and its command buffer (mgl_conn.c), the state
 * the library keeps of each context so that it can answer what a program
 * asks without asking the Mac (mgl_state.c), and the Wayland side of a
 * window's surface (mgl_wayland.c, which the tests replace).
 *
 * One lock (mgl_lock) guards all of it: the command buffer is one for the
 * process, and contexts that share objects share their state. Every entry
 * point takes it for as long as it runs, but for the wait for a frame in
 * eglSwapBuffers. A wait for an answer of the Mac's is under it: the
 * socket is one, and its answers come in one order.
 */
#ifndef MGL_INTERNAL_H
#define MGL_INTERNAL_H

#include "mgl_api.h"
#include "mwm_gl_wire.h"

#include <stdbool.h>
#include <stddef.h>

#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "the wire format is little-endian, and this code writes words as they are in memory"
#endif

enum {
    /* What glGet* answers as the limits, and what the library holds a program to. */
    MGL_ATTRIBS = 16,
    MGL_UNITS = 16,
    MGL_MAX_SIZE = 4096,
    MGL_MAX_LEVEL = 12,
    /* The commands written are sent when they are more than this. */
    MGL_FLUSH = 64 << 10,
};

/* ---- The connection (mgl_conn.c). All of it under the lock. ---- */

void mgl_lock(void);
void mgl_unlock(void);

/* Opens the process's stream (the socket, the eight bytes). False when
 * there is no window manager to draw for. */
bool mgl_conn_open(void);
void mgl_conn_close(void);
uint32_t mgl_conn_stream(void);
/* The other end is gone, or said what the protocol does not: from then on
 * nothing is written and nothing is read. */
bool mgl_conn_lost(void);
void mgl_conn_fail(void);

/* A command: begin, its arguments in order, end. End is false when the
 * command was not written (it is larger than a command may be, or there
 * is no memory for it): nothing of it is sent. */
void mgl_begin(uint32_t op);
void mgl_u32(uint32_t v);
void mgl_data(const void *bytes, size_t count);
/* A data argument of `count` bytes for the caller to fill; NULL when there is no room for it. */
uint8_t *mgl_data_room(size_t count);
/* The data argument that stands for a NULL pointer. */
void mgl_none(void);
bool mgl_end(void);

/* The commands after this are that context's: writes MakeCurrent when the
 * stream's last one was for another context or other surfaces. */
void mgl_make_current(uint32_t context, uint32_t draw, uint32_t rd);
/* The context of the stream's last MakeCurrent. */
uint32_t mgl_conn_context(void);

/* Sends what is written. False when the stream is lost. */
bool mgl_flush(void);

/* Swap: the picture on that surface is done. Sent at once with all that
 * is written, and answered when the Mac has drawn the picture. The answer
 * is not waited for here but read late: before the next Swap is sent
 * (this waits for it then) and before any other answer is read. So a
 * program draws on while the Mac draws, and is one picture ahead of it at
 * most. False when the stream is lost. */
bool mgl_swap(uint32_t surface);

/* The answer to the command just written, after the answer of a Swap
 * before it that has not been read. Reading past its end gives zeros and
 * makes it bad; mgl_reply_end frees it and says whether it was read to
 * its end exactly (if not, the stream is lost). */
typedef struct {
    uint8_t *bytes;
    size_t len, at;
    bool bad;
} mgl_reply;
bool mgl_reply_read(mgl_reply *r);
uint32_t mgl_reply_u32(mgl_reply *r);
/* A data argument: its bytes (inside the reply) and how many. NULL and 0 for none. */
const uint8_t *mgl_reply_data(mgl_reply *r, size_t *count);
bool mgl_reply_end(mgl_reply *r);

/* ---- The state (mgl_state.c) ---- */

/* Objects by name: buffers, textures, shaders and so on. */
typedef struct {
    uint32_t *names;
    void **objects;
    uint32_t room, count;
} mgl_map;
void *mgl_map_get(const mgl_map *m, uint32_t name);
/* The object of that name, made (`size` bytes of zeros, beginning with
 * its name) when there is none. NULL: no memory. */
void *mgl_map_make(mgl_map *m, uint32_t name, size_t size);
/* Takes it out of the map; the caller frees it. */
void *mgl_map_take(mgl_map *m, uint32_t name);
/* A name no object has, for glGen* and glCreate*. */
uint32_t mgl_map_new_name(const mgl_map *m, const mgl_map *also, uint32_t *next);

typedef struct {
    uint32_t name;
    /* It was bound: until then it is a name and no buffer (glIsBuffer). */
    bool live;
    size_t size;
    uint32_t usage;
    /* It was bound to GL_ELEMENT_ARRAY_BUFFER at some time: from then on
     * the library keeps what is put into it, to find the smallest and the
     * largest index of a draw whose vertices are in the program's memory.
     * `known`: `shadow` holds all `size` bytes. */
    bool indices, known;
    uint8_t *shadow;
} mgl_buffer;

typedef struct {
    uint32_t name;
    /* GL_TEXTURE_2D or GL_TEXTURE_CUBE_MAP once bound; 0 before. */
    uint32_t target;
    uint32_t min_filter, mag_filter, wrap_s, wrap_t;
} mgl_texture;

typedef struct {
    uint32_t name;
    bool live;
    int width, height;
    uint32_t format;
} mgl_renderbuffer;

typedef struct {
    /* GL_NONE, GL_RENDERBUFFER or GL_TEXTURE. */
    uint32_t type, name;
    int level;
    /* The face of a cube map, or 0. */
    uint32_t face;
} mgl_attachment;

typedef struct {
    uint32_t name;
    bool live;
    /* Colour, depth, stencil. */
    mgl_attachment attachments[3];
} mgl_framebuffer;

typedef struct {
    uint32_t name;
    uint32_t type;
    char *source;
    size_t source_len;
    bool compiled;
    char *info;
    /* glDeleteShader was called while a program had it attached. */
    bool deleted;
    int attached;
} mgl_shader;

/* An attribute or a uniform of a linked program, as the LinkProgram reply told it. */
typedef struct {
    int location;
    uint32_t type;
    int size;
    char *name;
} mgl_variable;

typedef struct {
    uint32_t name;
    /* The vertex shader and the fragment shader attached, or 0. */
    uint32_t shaders[2];
    bool linked, validated;
    char *info;
    mgl_variable *attribs, *uniforms;
    int attrib_count, uniform_count;
    /* glDeleteProgram was called while a context had it in use. */
    bool deleted;
    int used;
} mgl_program;

/* The objects contexts share (eglCreateContext's share_context), and the
 * names given out. Shaders and programs have one run of names. */
typedef struct {
    int contexts;
    mgl_map buffers, textures, renderbuffers, framebuffers, shaders, programs;
    uint32_t next_buffer, next_texture, next_renderbuffer, next_framebuffer, next_shader;
} mgl_share;

typedef struct {
    bool enabled, normalized;
    int size, stride;
    uint32_t type;
    /* The buffer bound to GL_ARRAY_BUFFER when glVertexAttribPointer was
     * called, and then `pointer` is an offset into it; 0: `pointer` is
     * the program's memory. */
    uint32_t buffer;
    const void *pointer;
    float current[4];
} mgl_attrib;

typedef struct {
    uint32_t func;
    int ref;
    uint32_t mask, writemask, fail, zfail, zpass;
} mgl_stencil;

typedef struct mgl_context {
    /* EGL's side (mgl_egl.c): the name on the wire, the display and the
     * config it was made for, the surfaces' names while it is current,
     * and how many bits of alpha, depth and stencil the one drawn on has
     * (its config's, which need not be the context's). */
    struct mgl_context *next;
    uint32_t id;
    void *display;
    int config;
    uint32_t draw, rd;
    int alpha_bits, depth_bits, stencil_bits;
    bool current, was_current, destroyed;

    mgl_share *share;
    /* The first error the library itself found since glGetError. */
    uint32_t error;

    uint32_t unit;
    uint32_t texture_2d[MGL_UNITS], texture_cube[MGL_UNITS];
    /* Texture 0 of each target: an object like the others, of the context's own. */
    mgl_texture texture_zero[2];
    uint32_t array_buffer, element_buffer, framebuffer, renderbuffer, program;
    mgl_attrib attribs[MGL_ATTRIBS];

    int viewport[4], scissor[4];
    float clear_color[4], clear_depth, depth_range[2];
    int clear_stencil;
    bool color_mask[4], depth_mask;
    uint32_t depth_func, cull_mode, front_face;
    float line_width, polygon_factor, polygon_units, coverage;
    bool coverage_invert;
    float blend_color[4];
    uint32_t blend_rgb, blend_alpha, src_rgb, dst_rgb, src_alpha, dst_alpha;
    /* Front, back. */
    mgl_stencil stencil[2];
    bool blend, cull_face, depth_test, dither, polygon_offset, alpha_to_coverage, sample_coverage, scissor_test,
        stencil_test;
    int pack_alignment, unpack_alignment;
    uint32_t mipmap_hint, derivative_hint;
} mgl_context;

/* A context with OpenGL ES's first values, sharing `share`'s objects when given. NULL: no memory. */
mgl_context *mgl_context_new(mgl_context *share);
void mgl_context_free(mgl_context *c);
/* The viewport and the scissor box are the surface's size the first time a context is current. */
void mgl_context_first_surface(mgl_context *c, int width, int height);
void mgl_error(mgl_context *c, uint32_t error);

void mgl_texture_first(mgl_texture *t);
void mgl_buffer_free(mgl_buffer *b);
void mgl_shader_free(mgl_shader *s);
/* Frees it; its shaders are attached to one program fewer (and freed when
 * glDeleteShader was waiting for that). */
void mgl_program_free(mgl_share *s, mgl_program *p);
/* One program fewer has the shader of that name attached. */
void mgl_shader_detached(mgl_share *s, uint32_t name);
/* One context fewer uses the program of that name. */
void mgl_program_unused(mgl_share *s, uint32_t name);
/* A copy of `count` bytes with a 0 after them. */
char *mgl_text(const void *bytes, size_t count);

/* What the LinkProgram reply says (after its first word), kept in the
 * program. False when it is not as the wire header has it. */
bool mgl_program_reflect(mgl_program *p, mgl_reply *r);
int mgl_attrib_location(const mgl_program *p, const char *name);
int mgl_uniform_location(const mgl_program *p, const char *name);

/* What glGetIntegerv, glGetFloatv and glGetBooleanv answer from. A unit
 * value is a colour or a depth: 0 to 1, which as an integer is that part
 * of an integer's whole range. */
typedef struct {
    enum { MGL_INT, MGL_BOOL, MGL_FLOAT, MGL_UNIT } kind;
    int count;
    double v[4];
} mgl_value;
/* False: OpenGL ES 2.0 has no such name. */
bool mgl_get(const mgl_context *c, uint32_t pname, mgl_value *value);
bool *mgl_capability(mgl_context *c, uint32_t cap);

/* The bytes of a pixel of that format and type. 0: OpenGL ES has both but
 * not together; -1: it has not one of them. */
int mgl_pixel_bytes(uint32_t format, uint32_t type);
/* The bytes of a vertex attribute's or an index's type; 0 when it is none. */
int mgl_type_bytes(uint32_t type);
/* How many numbers a uniform of that type is, and whether they are floats; 0 when it is no type. */
int mgl_uniform_numbers(uint32_t type, bool *floats);

/* ---- EGL's side (mgl_egl.c) ---- */

/* The calling thread's context, with the lock taken; NULL (and no lock)
 * when it has none. */
mgl_context *mgl_enter(void);
void mgl_leave(void);

/* A native window: libwayland-egl's struct, whose layout is its ABI with
 * EGL libraries (wayland-egl-backend.h, version 3). The program makes it
 * (wl_egl_window_create) and the library fills in the callbacks. */
struct wl_egl_window {
    const intptr_t version;
    int width, height;
    int dx, dy;
    int attached_width, attached_height;
    void *driver_private;
    void (*resize_callback)(struct wl_egl_window *, void *);
    void (*destroy_window_callback)(void *);
    struct wl_surface *surface;
};

/* ---- Wayland (mgl_wayland.c; the tests have their own) ---- */

/* A display's monad_gl, and a window's wl_surface with the buffer that
 * says what it shows. */
typedef struct mgl_wl mgl_wl;
typedef struct mgl_wl_surface mgl_wl_surface;

/* Finds monad_gl on a program's wl_display. NULL when it is no Wayland
 * display, or the window manager there is not Monad's. */
mgl_wl *mgl_wl_bind(void *display);
void mgl_wl_unbind(mgl_wl *wl);
/* For a window's wl_surface. NULL: no memory. */
mgl_wl_surface *mgl_wl_surface_new(mgl_wl *wl, void *surface);
/* The picture stream `stream` drew on its surface `surface` is done: says
 * so on the wl_surface (a buffer of that size, a commit), after the frame
 * before was shown unless `interval` is 0. Called without the lock: it
 * may wait. False when the Wayland connection is gone. */
bool mgl_wl_present(mgl_wl_surface *s, uint32_t stream, uint32_t surface, int width, int height, int interval);
/* The EGL surface is destroyed, or the program destroyed the window. */
void mgl_wl_surface_gone(mgl_wl_surface *s);

#endif
