/*
 * mgl_gles.c — OpenGL ES 2.0's entry points. A call that changes
 * something is checked as far as the library can tell (an error found
 * here is kept for glGetError and the call goes nowhere), noted in the
 * context's state (mgl_state.c) and written down as a command for the Mac
 * (mwm_gl_wire.h). A call that asks is answered from that state. Only the
 * few commands the wire header gives an answer wait for the Mac.
 *
 * With no context current a call does nothing, as in the drivers programs
 * are used to.
 */
#include "mgl_internal.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

static void leave(mgl_context **c) {
    if (*c) mgl_leave();
}
/* The calling thread's context as `c`, under the lock until the function
 * returns, whichever way; returns at once (the value given) without one. */
#define CONTEXT(...) \
    mgl_context *c __attribute__((cleanup(leave))) = mgl_enter(); \
    if (!c) return __VA_ARGS__
#define ERROR(error, ...) \
    do { \
        mgl_error(c, (error)); \
        return __VA_ARGS__; \
    } while (0)

/* ---- Writing commands ---- */

static uint32_t bits(float f) {
    uint32_t u;
    memcpy(&u, &f, 4);
    return u;
}
#define F(x) bits(x)

/* A command of this context: after MakeCurrent when the stream's last command was another's. */
static void begin(mgl_context *c, uint32_t op) {
    mgl_make_current(c->id, c->draw, c->rd);
    mgl_begin(op);
}

static void end(mgl_context *c) {
    if (!mgl_end()) mgl_error(c, GL_OUT_OF_MEMORY);
}

static void words(mgl_context *c, uint32_t op, const uint32_t *w, size_t count) {
    begin(c, op);
    for (size_t i = 0; i < count; i++) mgl_u32(w[i]);
    end(c);
}
/* A command whose arguments are all words. A float goes through F(): as
 * it is here it would be turned into the integer nearest to it. */
#define SEND(op, ...) words(c, (op), (const uint32_t[]){__VA_ARGS__}, sizeof((const uint32_t[]){__VA_ARGS__}) / sizeof(uint32_t))

/* Ends the command just written and waits for its answer. */
static bool answer(mgl_context *c, mgl_reply *r) {
    if (!mgl_end()) {
        mgl_error(c, GL_OUT_OF_MEMORY);
        return false;
    }
    return mgl_reply_read(r);
}

/* ---- What is asked of several calls ---- */

static float unit(float f) { return f > 1 ? 1 : f > 0 ? f : 0; /* and 0 for what is no number */ }

static GLint as_int(const mgl_value *v, int i) {
    double x = v->v[i];
    if (x != x) return 0;
    if (v->kind == MGL_UNIT) x *= 2147483647.0;
    if (v->kind == MGL_UNIT || v->kind == MGL_FLOAT) x += x < 0 ? -0.5 : 0.5;
    return x >= 2147483647.0 ? INT_MAX : x <= -2147483648.0 ? INT_MIN : (GLint)x;
}

/* A string into a program's memory: as much as there is room for with its 0, and how much that was. */
static void copy_text(const char *text, GLsizei room, GLsizei *length, GLchar *out) {
    size_t len = text ? strlen(text) : 0;
    if (length) *length = 0;
    if (room <= 0 || !out) return;
    if (len > (size_t)room - 1) len = (size_t)room - 1;
    if (len > 0) memcpy(out, text, len);
    out[len] = 0;
    if (length) *length = (GLsizei)len;
}

/* The program of that name; without one, the error OpenGL ES has for the name. */
static mgl_program *program_named(mgl_context *c, GLuint name) {
    mgl_program *p = mgl_map_get(&c->share->programs, name);
    if (!p) mgl_error(c, mgl_map_get(&c->share->shaders, name) ? GL_INVALID_OPERATION : GL_INVALID_VALUE);
    return p;
}

static mgl_shader *shader_named(mgl_context *c, GLuint name) {
    mgl_shader *s = mgl_map_get(&c->share->shaders, name);
    if (!s) mgl_error(c, mgl_map_get(&c->share->programs, name) ? GL_INVALID_OPERATION : GL_INVALID_VALUE);
    return s;
}

static uint32_t *buffer_binding(mgl_context *c, GLenum target) {
    if (target == GL_ARRAY_BUFFER) return &c->array_buffer;
    if (target == GL_ELEMENT_ARRAY_BUFFER) return &c->element_buffer;
    mgl_error(c, GL_INVALID_ENUM);
    return NULL;
}

/* The buffer bound to that target, for a call that needs one. */
static mgl_buffer *bound_buffer(mgl_context *c, GLenum target) {
    uint32_t *binding = buffer_binding(c, target);
    if (!binding) return NULL;
    mgl_buffer *b = mgl_map_get(&c->share->buffers, *binding);
    if (!b) mgl_error(c, GL_INVALID_OPERATION);
    return b;
}

/* The texture a call on that target is about: the one bound to the unit, or the context's texture 0. */
static mgl_texture *bound_texture(mgl_context *c, GLenum target) {
    if (target != GL_TEXTURE_2D && target != GL_TEXTURE_CUBE_MAP) {
        mgl_error(c, GL_INVALID_ENUM);
        return NULL;
    }
    int cube = target == GL_TEXTURE_CUBE_MAP;
    mgl_texture *t = mgl_map_get(&c->share->textures, (cube ? c->texture_cube : c->texture_2d)[c->unit]);
    return t ? t : &c->texture_zero[cube];
}

static bool image_target(GLenum target) {
    return target == GL_TEXTURE_2D || (target >= GL_TEXTURE_CUBE_MAP_POSITIVE_X && target <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z);
}

/* An attachment point of the framebuffer bound. */
static mgl_attachment *attachment(mgl_context *c, GLenum target, GLenum point) {
    int k = point == GL_COLOR_ATTACHMENT0 ? 0 : point == GL_DEPTH_ATTACHMENT ? 1 : point == GL_STENCIL_ATTACHMENT ? 2 : -1;
    if (target != GL_FRAMEBUFFER || k < 0) {
        mgl_error(c, GL_INVALID_ENUM);
        return NULL;
    }
    /* The window's own framebuffer has no attachments to set or to ask about. */
    mgl_framebuffer *f = mgl_map_get(&c->share->framebuffers, c->framebuffer);
    if (!f) {
        mgl_error(c, GL_INVALID_OPERATION);
        return NULL;
    }
    return &f->attachments[k];
}

/* An object deleted is no longer attached to the framebuffer bound. */
static void detach(mgl_context *c, uint32_t type, uint32_t name) {
    mgl_framebuffer *f = mgl_map_get(&c->share->framebuffers, c->framebuffer);
    if (!f) return;
    for (int k = 0; k < 3; k++)
        if (f->attachments[k].type == type && f->attachments[k].name == name) f->attachments[k] = (mgl_attachment){0};
}

static bool compare_func(GLenum func) { return func >= GL_NEVER && func <= GL_ALWAYS; }

static bool blend_equation(GLenum mode) {
    return mode == GL_FUNC_ADD || mode == GL_FUNC_SUBTRACT || mode == GL_FUNC_REVERSE_SUBTRACT;
}

static bool blend_factor(GLenum factor, bool source) {
    return factor == GL_ZERO || factor == GL_ONE || (factor >= GL_SRC_COLOR && factor <= GL_ONE_MINUS_DST_COLOR) ||
           (factor >= GL_CONSTANT_COLOR && factor <= GL_ONE_MINUS_CONSTANT_ALPHA) || (source && factor == GL_SRC_ALPHA_SATURATE);
}

static bool stencil_op(GLenum op) {
    return op == GL_ZERO || op == GL_INVERT || (op >= GL_KEEP && op <= GL_DECR) || op == GL_INCR_WRAP || op == GL_DECR_WRAP;
}

static bool a_face(GLenum face) { return face == GL_FRONT || face == GL_BACK || face == GL_FRONT_AND_BACK; }
/* The stencil state (0 front, 1 back) a face names. */
#define EACH_FACE(face, k) \
    for (int k = 0; k < 2; k++) \
        if ((face) == GL_FRONT_AND_BACK || (face) == (k == 0 ? GL_FRONT : GL_BACK))

/* ---- The entry points, in the order of the specification's list ---- */

MGL_API void glActiveTexture(GLenum texture) {
    CONTEXT();
    if (texture < GL_TEXTURE0 || texture >= GL_TEXTURE0 + MGL_UNITS) ERROR(GL_INVALID_ENUM);
    c->unit = texture - GL_TEXTURE0;
    SEND(MGL_ACTIVE_TEXTURE, texture);
}

MGL_API void glAttachShader(GLuint program, GLuint shader) {
    CONTEXT();
    mgl_program *p = program_named(c, program);
    mgl_shader *s = p ? shader_named(c, shader) : NULL;
    if (!s) return;
    /* One vertex shader and one fragment shader, and no more. */
    int k = s->type == GL_FRAGMENT_SHADER;
    if (p->shaders[k] != 0) ERROR(GL_INVALID_OPERATION);
    p->shaders[k] = shader;
    s->attached++;
    SEND(MGL_ATTACH_SHADER, program, shader);
}

MGL_API void glBindAttribLocation(GLuint program, GLuint indx, const GLchar *name) {
    CONTEXT();
    if (indx >= MGL_ATTRIBS) ERROR(GL_INVALID_VALUE);
    if (!program_named(c, program) || !name) return;
    if (strncmp(name, "gl_", 3) == 0) ERROR(GL_INVALID_OPERATION);
    begin(c, MGL_BIND_ATTRIB_LOCATION);
    mgl_u32(program);
    mgl_u32(indx);
    mgl_data(name, strlen(name));
    end(c);
}

MGL_API void glBindBuffer(GLenum target, GLuint buffer) {
    CONTEXT();
    uint32_t *binding = buffer_binding(c, target);
    if (!binding) return;
    if (buffer != 0) {
        mgl_buffer *b = mgl_map_make(&c->share->buffers, buffer, sizeof *b);
        if (!b) ERROR(GL_OUT_OF_MEMORY);
        b->live = true;
        if (target == GL_ELEMENT_ARRAY_BUFFER && !b->indices) {
            /* From here on what is put into it is kept; what was put before is not known. */
            b->indices = true;
            b->known = b->size == 0;
        }
    }
    *binding = buffer;
    SEND(MGL_BIND_BUFFER, target, buffer);
}

MGL_API void glBindFramebuffer(GLenum target, GLuint framebuffer) {
    CONTEXT();
    if (target != GL_FRAMEBUFFER) ERROR(GL_INVALID_ENUM);
    if (framebuffer != 0) {
        mgl_framebuffer *f = mgl_map_make(&c->share->framebuffers, framebuffer, sizeof *f);
        if (!f) ERROR(GL_OUT_OF_MEMORY);
        f->live = true;
    }
    c->framebuffer = framebuffer;
    SEND(MGL_BIND_FRAMEBUFFER, target, framebuffer);
}

MGL_API void glBindRenderbuffer(GLenum target, GLuint renderbuffer) {
    CONTEXT();
    if (target != GL_RENDERBUFFER) ERROR(GL_INVALID_ENUM);
    if (renderbuffer != 0) {
        mgl_renderbuffer *b = mgl_map_make(&c->share->renderbuffers, renderbuffer, sizeof *b);
        if (!b) ERROR(GL_OUT_OF_MEMORY);
        b->live = true;
    }
    c->renderbuffer = renderbuffer;
    SEND(MGL_BIND_RENDERBUFFER, target, renderbuffer);
}

MGL_API void glBindTexture(GLenum target, GLuint texture) {
    CONTEXT();
    if (target != GL_TEXTURE_2D && target != GL_TEXTURE_CUBE_MAP) ERROR(GL_INVALID_ENUM);
    if (texture != 0) {
        mgl_texture *t = mgl_map_make(&c->share->textures, texture, sizeof *t);
        if (!t) ERROR(GL_OUT_OF_MEMORY);
        /* A texture is of the target it was first bound to, for good. */
        if (t->target == 0) {
            t->target = target;
            mgl_texture_first(t);
        } else if (t->target != target) {
            ERROR(GL_INVALID_OPERATION);
        }
    }
    (target == GL_TEXTURE_2D ? c->texture_2d : c->texture_cube)[c->unit] = texture;
    SEND(MGL_BIND_TEXTURE, target, texture);
}

MGL_API void glBlendColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    CONTEXT();
    c->blend_color[0] = unit(red);
    c->blend_color[1] = unit(green);
    c->blend_color[2] = unit(blue);
    c->blend_color[3] = unit(alpha);
    SEND(MGL_BLEND_COLOR, F(red), F(green), F(blue), F(alpha));
}

MGL_API void glBlendEquation(GLenum mode) {
    CONTEXT();
    if (!blend_equation(mode)) ERROR(GL_INVALID_ENUM);
    c->blend_rgb = c->blend_alpha = mode;
    SEND(MGL_BLEND_EQUATION, mode);
}

MGL_API void glBlendEquationSeparate(GLenum modeRGB, GLenum modeAlpha) {
    CONTEXT();
    if (!blend_equation(modeRGB) || !blend_equation(modeAlpha)) ERROR(GL_INVALID_ENUM);
    c->blend_rgb = modeRGB;
    c->blend_alpha = modeAlpha;
    SEND(MGL_BLEND_EQUATION_SEPARATE, modeRGB, modeAlpha);
}

MGL_API void glBlendFunc(GLenum sfactor, GLenum dfactor) {
    CONTEXT();
    if (!blend_factor(sfactor, true) || !blend_factor(dfactor, false)) ERROR(GL_INVALID_ENUM);
    c->src_rgb = c->src_alpha = sfactor;
    c->dst_rgb = c->dst_alpha = dfactor;
    SEND(MGL_BLEND_FUNC, sfactor, dfactor);
}

MGL_API void glBlendFuncSeparate(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha) {
    CONTEXT();
    if (!blend_factor(srcRGB, true) || !blend_factor(dstRGB, false) || !blend_factor(srcAlpha, true) || !blend_factor(dstAlpha, false))
        ERROR(GL_INVALID_ENUM);
    c->src_rgb = srcRGB;
    c->dst_rgb = dstRGB;
    c->src_alpha = srcAlpha;
    c->dst_alpha = dstAlpha;
    SEND(MGL_BLEND_FUNC_SEPARATE, srcRGB, dstRGB, srcAlpha, dstAlpha);
}

MGL_API void glBufferData(GLenum target, GLsizeiptr size, const void *data, GLenum usage) {
    CONTEXT();
    if (!buffer_binding(c, target)) return;
    if (usage != GL_STREAM_DRAW && usage != GL_STATIC_DRAW && usage != GL_DYNAMIC_DRAW) ERROR(GL_INVALID_ENUM);
    if (size < 0) ERROR(GL_INVALID_VALUE);
    mgl_buffer *b = bound_buffer(c, target);
    if (!b) return;
    /* No buffer is larger than a command can fill. */
    if ((size_t)size > MWM_GL_COMMAND) ERROR(GL_OUT_OF_MEMORY);
    begin(c, MGL_BUFFER_DATA);
    mgl_u32(target);
    mgl_u32((uint32_t)size);
    mgl_u32(usage);
    if (data) mgl_data(data, (size_t)size);
    else mgl_none();
    if (!mgl_end()) ERROR(GL_OUT_OF_MEMORY);
    b->size = (size_t)size;
    b->usage = usage;
    if (b->indices) {
        free(b->shadow);
        b->shadow = calloc(1, b->size ? b->size : 1);
        b->known = b->shadow != NULL;
        if (b->shadow && data) memcpy(b->shadow, data, b->size);
    }
}

MGL_API void glBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void *data) {
    CONTEXT();
    if (!buffer_binding(c, target)) return;
    if (offset < 0 || size < 0) ERROR(GL_INVALID_VALUE);
    mgl_buffer *b = bound_buffer(c, target);
    if (!b) return;
    if ((size_t)offset > b->size || (size_t)size > b->size - (size_t)offset) ERROR(GL_INVALID_VALUE);
    if (size == 0 || !data) return;
    begin(c, MGL_BUFFER_SUB_DATA);
    mgl_u32(target);
    mgl_u32((uint32_t)offset);
    mgl_data(data, (size_t)size);
    if (!mgl_end()) ERROR(GL_OUT_OF_MEMORY);
    if (b->known && b->shadow) memcpy(b->shadow + offset, data, (size_t)size);
}

MGL_API GLenum glCheckFramebufferStatus(GLenum target) {
    CONTEXT(0);
    if (target != GL_FRAMEBUFFER) ERROR(GL_INVALID_ENUM, 0);
    begin(c, MGL_CHECK_FRAMEBUFFER_STATUS);
    mgl_u32(target);
    mgl_reply r;
    if (!answer(c, &r)) return 0;
    GLenum status = mgl_reply_u32(&r);
    return mgl_reply_end(&r) ? status : 0;
}

MGL_API void glClear(GLbitfield mask) {
    CONTEXT();
    if (mask & ~(GLbitfield)(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT)) ERROR(GL_INVALID_VALUE);
    SEND(MGL_CLEAR, mask);
}

MGL_API void glClearColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    CONTEXT();
    c->clear_color[0] = unit(red);
    c->clear_color[1] = unit(green);
    c->clear_color[2] = unit(blue);
    c->clear_color[3] = unit(alpha);
    SEND(MGL_CLEAR_COLOR, F(red), F(green), F(blue), F(alpha));
}

MGL_API void glClearDepthf(GLfloat depth) {
    CONTEXT();
    c->clear_depth = unit(depth);
    SEND(MGL_CLEAR_DEPTHF, F(depth));
}

MGL_API void glClearStencil(GLint s) {
    CONTEXT();
    c->clear_stencil = s;
    SEND(MGL_CLEAR_STENCIL, s);
}

MGL_API void glColorMask(GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha) {
    CONTEXT();
    c->color_mask[0] = red != 0;
    c->color_mask[1] = green != 0;
    c->color_mask[2] = blue != 0;
    c->color_mask[3] = alpha != 0;
    SEND(MGL_COLOR_MASK, red != 0, green != 0, blue != 0, alpha != 0);
}

MGL_API void glCompileShader(GLuint shader) {
    CONTEXT();
    mgl_shader *s = shader_named(c, shader);
    if (!s) return;
    free(s->info);
    s->info = NULL;
    s->compiled = false;
    begin(c, MGL_COMPILE_SHADER);
    mgl_u32(shader);
    mgl_reply r;
    if (!answer(c, &r)) return;
    uint32_t compiled = mgl_reply_u32(&r);
    size_t len;
    const uint8_t *text = mgl_reply_data(&r, &len);
    char *info = mgl_text(text, len);
    if (compiled > 1) r.bad = true;
    if (mgl_reply_end(&r)) {
        s->compiled = compiled == 1;
        s->info = info;
    } else {
        free(info);
    }
}

/* No compressed format is offered (GL_NUM_COMPRESSED_TEXTURE_FORMATS is 0): whichever is named is none. */
MGL_API void glCompressedTexImage2D(GLenum target, GLint level, GLenum internalformat, GLsizei width, GLsizei height, GLint border,
                                    GLsizei imageSize, const void *data) {
    (void)target, (void)level, (void)internalformat, (void)width, (void)height, (void)border, (void)imageSize, (void)data;
    CONTEXT();
    ERROR(GL_INVALID_ENUM);
}

MGL_API void glCompressedTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height,
                                       GLenum format, GLsizei imageSize, const void *data) {
    (void)target, (void)level, (void)xoffset, (void)yoffset, (void)width, (void)height, (void)format, (void)imageSize, (void)data;
    CONTEXT();
    ERROR(GL_INVALID_ENUM);
}

MGL_API void glCopyTexImage2D(GLenum target, GLint level, GLenum internalformat, GLint x, GLint y, GLsizei width, GLsizei height,
                              GLint border) {
    CONTEXT();
    if (!image_target(target)) ERROR(GL_INVALID_ENUM);
    if (internalformat != GL_ALPHA && internalformat != GL_LUMINANCE && internalformat != GL_LUMINANCE_ALPHA && internalformat != GL_RGB &&
        internalformat != GL_RGBA)
        ERROR(GL_INVALID_ENUM);
    if (level < 0 || level > MGL_MAX_LEVEL || width < 0 || height < 0 || width > MGL_MAX_SIZE || height > MGL_MAX_SIZE || border != 0)
        ERROR(GL_INVALID_VALUE);
    SEND(MGL_COPY_TEX_IMAGE_2D, target, level, internalformat, x, y, width, height, border);
}

MGL_API void glCopyTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint x, GLint y, GLsizei width,
                                 GLsizei height) {
    CONTEXT();
    if (!image_target(target)) ERROR(GL_INVALID_ENUM);
    if (level < 0 || level > MGL_MAX_LEVEL || xoffset < 0 || yoffset < 0 || width < 0 || height < 0) ERROR(GL_INVALID_VALUE);
    SEND(MGL_COPY_TEX_SUB_IMAGE_2D, target, level, xoffset, yoffset, x, y, width, height);
}

MGL_API GLuint glCreateProgram(void) {
    CONTEXT(0);
    mgl_share *s = c->share;
    uint32_t name = mgl_map_new_name(&s->programs, &s->shaders, &s->next_shader);
    if (!mgl_map_make(&s->programs, name, sizeof(mgl_program))) ERROR(GL_OUT_OF_MEMORY, 0);
    SEND(MGL_CREATE_PROGRAM, name);
    return name;
}

MGL_API GLuint glCreateShader(GLenum type) {
    CONTEXT(0);
    if (type != GL_VERTEX_SHADER && type != GL_FRAGMENT_SHADER) ERROR(GL_INVALID_ENUM, 0);
    mgl_share *s = c->share;
    uint32_t name = mgl_map_new_name(&s->shaders, &s->programs, &s->next_shader);
    mgl_shader *shader = mgl_map_make(&s->shaders, name, sizeof *shader);
    if (!shader) ERROR(GL_OUT_OF_MEMORY, 0);
    shader->type = type;
    SEND(MGL_CREATE_SHADER, name, type);
    return name;
}

MGL_API void glCullFace(GLenum mode) {
    CONTEXT();
    if (!a_face(mode)) ERROR(GL_INVALID_ENUM);
    c->cull_mode = mode;
    SEND(MGL_CULL_FACE, mode);
}

/* What glDeleteBuffers and its like send: the names as they were given
 * (one that is no object is none to the Mac either). False: nothing was
 * said, and nothing is to be forgotten. */
static bool delete_names(mgl_context *c, uint32_t op, GLsizei n, const GLuint *names) {
    if (n < 0) mgl_error(c, GL_INVALID_VALUE);
    if (n <= 0 || !names) return false;
    begin(c, op);
    mgl_u32((uint32_t)n);
    mgl_data(names, (size_t)n * 4);
    if (mgl_end()) return true;
    mgl_error(c, GL_OUT_OF_MEMORY);
    return false;
}

MGL_API void glDeleteBuffers(GLsizei n, const GLuint *buffers) {
    CONTEXT();
    if (!delete_names(c, MGL_DELETE_BUFFERS, n, buffers)) return;
    for (GLsizei i = 0; i < n; i++) {
        mgl_buffer *b = mgl_map_take(&c->share->buffers, buffers[i]);
        if (!b) continue;
        if (c->array_buffer == b->name) c->array_buffer = 0;
        if (c->element_buffer == b->name) c->element_buffer = 0;
        for (int k = 0; k < MGL_ATTRIBS; k++)
            if (c->attribs[k].buffer == b->name) {
                /* What was an offset into the buffer is no place in the
                 * program's memory: such an array is not read at a draw. */
                c->attribs[k].buffer = 0;
                c->attribs[k].pointer = NULL;
            }
        mgl_buffer_free(b);
    }
}

MGL_API void glDeleteFramebuffers(GLsizei n, const GLuint *framebuffers) {
    CONTEXT();
    if (!delete_names(c, MGL_DELETE_FRAMEBUFFERS, n, framebuffers)) return;
    for (GLsizei i = 0; i < n; i++) {
        mgl_framebuffer *f = mgl_map_take(&c->share->framebuffers, framebuffers[i]);
        if (!f) continue;
        if (c->framebuffer == f->name) c->framebuffer = 0;
        free(f);
    }
}

MGL_API void glDeleteProgram(GLuint program) {
    CONTEXT();
    if (program == 0) return;
    mgl_program *p = program_named(c, program);
    if (!p) return;
    if (!p->deleted) SEND(MGL_DELETE_PROGRAM, program);
    /* One in use lives on until no context uses it; the Mac holds to the same rule. */
    if (p->used > 0) p->deleted = true;
    else mgl_program_free(c->share, mgl_map_take(&c->share->programs, program));
}

MGL_API void glDeleteRenderbuffers(GLsizei n, const GLuint *renderbuffers) {
    CONTEXT();
    if (!delete_names(c, MGL_DELETE_RENDERBUFFERS, n, renderbuffers)) return;
    for (GLsizei i = 0; i < n; i++) {
        mgl_renderbuffer *b = mgl_map_take(&c->share->renderbuffers, renderbuffers[i]);
        if (!b) continue;
        if (c->renderbuffer == b->name) c->renderbuffer = 0;
        detach(c, GL_RENDERBUFFER, b->name);
        free(b);
    }
}

MGL_API void glDeleteShader(GLuint shader) {
    CONTEXT();
    if (shader == 0) return;
    mgl_shader *s = shader_named(c, shader);
    if (!s) return;
    if (!s->deleted) SEND(MGL_DELETE_SHADER, shader);
    if (s->attached > 0) s->deleted = true;
    else mgl_shader_free(mgl_map_take(&c->share->shaders, shader));
}

MGL_API void glDeleteTextures(GLsizei n, const GLuint *textures) {
    CONTEXT();
    if (!delete_names(c, MGL_DELETE_TEXTURES, n, textures)) return;
    for (GLsizei i = 0; i < n; i++) {
        mgl_texture *t = mgl_map_take(&c->share->textures, textures[i]);
        if (!t) continue;
        for (int k = 0; k < MGL_UNITS; k++) {
            if (c->texture_2d[k] == t->name) c->texture_2d[k] = 0;
            if (c->texture_cube[k] == t->name) c->texture_cube[k] = 0;
        }
        detach(c, GL_TEXTURE, t->name);
        free(t);
    }
}

MGL_API void glDepthFunc(GLenum func) {
    CONTEXT();
    if (!compare_func(func)) ERROR(GL_INVALID_ENUM);
    c->depth_func = func;
    SEND(MGL_DEPTH_FUNC, func);
}

MGL_API void glDepthMask(GLboolean flag) {
    CONTEXT();
    c->depth_mask = flag != 0;
    SEND(MGL_DEPTH_MASK, flag != 0);
}

MGL_API void glDepthRangef(GLfloat zNear, GLfloat zFar) {
    CONTEXT();
    c->depth_range[0] = unit(zNear);
    c->depth_range[1] = unit(zFar);
    SEND(MGL_DEPTH_RANGEF, F(zNear), F(zFar));
}

MGL_API void glDetachShader(GLuint program, GLuint shader) {
    CONTEXT();
    mgl_program *p = program_named(c, program);
    mgl_shader *s = p ? shader_named(c, shader) : NULL;
    if (!s) return;
    int k = s->type == GL_FRAGMENT_SHADER;
    if (p->shaders[k] != shader) ERROR(GL_INVALID_OPERATION);
    p->shaders[k] = 0;
    SEND(MGL_DETACH_SHADER, program, shader);
    mgl_shader_detached(c->share, shader);
}

MGL_API void glDisable(GLenum cap) {
    CONTEXT();
    bool *flag = mgl_capability(c, cap);
    if (!flag) ERROR(GL_INVALID_ENUM);
    *flag = false;
    SEND(MGL_DISABLE, cap);
}

MGL_API void glDisableVertexAttribArray(GLuint indx) {
    CONTEXT();
    if (indx >= MGL_ATTRIBS) ERROR(GL_INVALID_VALUE);
    c->attribs[indx].enabled = false;
    SEND(MGL_DISABLE_VERTEX_ATTRIB_ARRAY, indx);
}

/* Whether a draw takes vertices from the program's memory. */
static bool client_arrays(const mgl_context *c) {
    for (int i = 0; i < MGL_ATTRIBS; i++)
        if (c->attribs[i].enabled && c->attribs[i].buffer == 0 && c->attribs[i].pointer) return true;
    return false;
}

/* Vertices `first` and the `count - 1` after it of every enabled array
 * that is in the program's memory, as ClientArray commands for the draw
 * that follows. False: they could not all be written, and there is no
 * draw to send. */
static bool send_client_arrays(mgl_context *c, size_t first, size_t count) {
    for (uint32_t i = 0; i < MGL_ATTRIBS; i++) {
        const mgl_attrib *a = &c->attribs[i];
        if (!a->enabled || a->buffer != 0 || !a->pointer) continue;
        size_t element = (size_t)a->size * (size_t)mgl_type_bytes(a->type), stride = a->stride ? (size_t)a->stride : element;
        if (count > MWM_GL_COMMAND / element) {
            mgl_error(c, GL_OUT_OF_MEMORY);
            return false;
        }
        begin(c, MGL_CLIENT_ARRAY);
        mgl_u32(i);
        mgl_u32((uint32_t)a->size);
        mgl_u32(a->type);
        mgl_u32(a->normalized);
        mgl_u32((uint32_t)first);
        uint8_t *to = mgl_data_room(count * element);
        if (to) {
            const uint8_t *from = (const uint8_t *)a->pointer + first * stride;
            if (stride == element) memcpy(to, from, count * element);
            else
                for (size_t k = 0; k < count; k++) memcpy(to + k * element, from + k * stride, element);
        }
        if (!mgl_end()) {
            mgl_error(c, GL_OUT_OF_MEMORY);
            return false;
        }
    }
    return true;
}

MGL_API void glDrawArrays(GLenum mode, GLint first, GLsizei count) {
    CONTEXT();
    if (mode > GL_TRIANGLE_FAN) ERROR(GL_INVALID_ENUM);
    if (first < 0 || count < 0) ERROR(GL_INVALID_VALUE);
    if (count == 0) return;
    if (client_arrays(c) && !send_client_arrays(c, (size_t)first, (size_t)count)) return;
    SEND(MGL_DRAW_ARRAYS, mode, first, count);
}

/* The smallest and the largest of `count` indices (one at the least). */
static void index_range(const uint8_t *indices, GLenum type, size_t count, uint32_t *low, uint32_t *high) {
    *low = UINT32_MAX;
    *high = 0;
    for (size_t i = 0; i < count; i++) {
        uint32_t v;
        if (type == GL_UNSIGNED_BYTE) {
            v = indices[i];
        } else if (type == GL_UNSIGNED_SHORT) {
            uint16_t s;
            memcpy(&s, indices + i * 2, 2);
            v = s;
        } else {
            memcpy(&v, indices + i * 4, 4);
        }
        if (v < *low) *low = v;
        if (v > *high) *high = v;
    }
}

MGL_API void glDrawElements(GLenum mode, GLsizei count, GLenum type, const void *indices) {
    CONTEXT();
    if (mode > GL_TRIANGLE_FAN || (type != GL_UNSIGNED_BYTE && type != GL_UNSIGNED_SHORT && type != GL_UNSIGNED_INT)) ERROR(GL_INVALID_ENUM);
    if (count < 0) ERROR(GL_INVALID_VALUE);
    if (count == 0) return;
    size_t bytes = (size_t)count * (size_t)mgl_type_bytes(type), offset = (uintptr_t)indices;
    mgl_buffer *b = NULL;
    if (c->element_buffer != 0) {
        /* `indices` is an offset into the buffer. */
        b = mgl_map_get(&c->share->buffers, c->element_buffer);
        if (!b) ERROR(GL_INVALID_OPERATION);
        if (offset > UINT32_MAX) ERROR(GL_INVALID_VALUE);
    } else if (!indices) {
        return;
    }
    if (client_arrays(c)) {
        /* The vertices to send are the ones the indices name: from the
         * program's indices, or from what the library kept of the buffer. */
        const uint8_t *from = indices;
        if (b) {
            if (!b->known || offset > b->size || bytes > b->size - offset) ERROR(GL_INVALID_OPERATION);
            from = b->shadow + offset;
        }
        uint32_t low, high;
        index_range(from, type, (size_t)count, &low, &high);
        if (!send_client_arrays(c, low, (size_t)(high - low) + 1)) return;
    }
    if (b) {
        SEND(MGL_DRAW_ELEMENTS, mode, count, type, (uint32_t)offset);
    } else {
        begin(c, MGL_DRAW_ELEMENTS_CLIENT);
        mgl_u32(mode);
        mgl_u32((uint32_t)count);
        mgl_u32(type);
        mgl_data(indices, bytes);
        end(c);
    }
}

MGL_API void glEnable(GLenum cap) {
    CONTEXT();
    bool *flag = mgl_capability(c, cap);
    if (!flag) ERROR(GL_INVALID_ENUM);
    *flag = true;
    SEND(MGL_ENABLE, cap);
}

MGL_API void glEnableVertexAttribArray(GLuint indx) {
    CONTEXT();
    if (indx >= MGL_ATTRIBS) ERROR(GL_INVALID_VALUE);
    c->attribs[indx].enabled = true;
    SEND(MGL_ENABLE_VERTEX_ATTRIB_ARRAY, indx);
}

MGL_API void glFinish(void) {
    CONTEXT();
    begin(c, MGL_FINISH);
    mgl_reply r;
    if (answer(c, &r)) (void)mgl_reply_end(&r);
}

MGL_API void glFlush(void) {
    CONTEXT();
    (void)mgl_flush();
}

MGL_API void glFramebufferRenderbuffer(GLenum target, GLenum point, GLenum renderbuffertarget, GLuint renderbuffer) {
    CONTEXT();
    mgl_attachment *a = attachment(c, target, point);
    if (!a) return;
    if (renderbuffertarget != GL_RENDERBUFFER) ERROR(GL_INVALID_ENUM);
    if (renderbuffer != 0 && !mgl_map_get(&c->share->renderbuffers, renderbuffer)) ERROR(GL_INVALID_OPERATION);
    *a = (mgl_attachment){.type = renderbuffer ? GL_RENDERBUFFER : GL_NONE, .name = renderbuffer};
    SEND(MGL_FRAMEBUFFER_RENDERBUFFER, target, point, renderbuffertarget, renderbuffer);
}

MGL_API void glFramebufferTexture2D(GLenum target, GLenum point, GLenum textarget, GLuint texture, GLint level) {
    CONTEXT();
    mgl_attachment *a = attachment(c, target, point);
    if (!a) return;
    if (texture != 0) {
        if (!image_target(textarget)) ERROR(GL_INVALID_ENUM);
        if (level != 0) ERROR(GL_INVALID_VALUE);
        mgl_texture *t = mgl_map_get(&c->share->textures, texture);
        if (!t || (t->target == GL_TEXTURE_2D) != (textarget == GL_TEXTURE_2D)) ERROR(GL_INVALID_OPERATION);
    }
    GLenum face = texture && textarget != GL_TEXTURE_2D ? textarget : 0;
    *a = (mgl_attachment){.type = texture ? GL_TEXTURE : GL_NONE, .name = texture, .face = face};
    SEND(MGL_FRAMEBUFFER_TEXTURE_2D, target, point, textarget, texture, level);
}

MGL_API void glFrontFace(GLenum mode) {
    CONTEXT();
    if (mode != GL_CW && mode != GL_CCW) ERROR(GL_INVALID_ENUM);
    c->front_face = mode;
    SEND(MGL_FRONT_FACE, mode);
}

/* Names for glGen*: the library's own, and nothing said to the Mac, where
 * a name comes to be when it is first bound. */
static void new_names(mgl_context *c, mgl_map *m, uint32_t *next, size_t size, GLsizei n, GLuint *names) {
    if (n < 0) mgl_error(c, GL_INVALID_VALUE);
    if (n <= 0 || !names) return;
    for (GLsizei i = 0; i < n; i++) {
        uint32_t name = mgl_map_new_name(m, NULL, next);
        if (!mgl_map_make(m, name, size)) {
            mgl_error(c, GL_OUT_OF_MEMORY);
            name = 0;
        }
        names[i] = name;
    }
}

MGL_API void glGenBuffers(GLsizei n, GLuint *buffers) {
    CONTEXT();
    new_names(c, &c->share->buffers, &c->share->next_buffer, sizeof(mgl_buffer), n, buffers);
}

MGL_API void glGenerateMipmap(GLenum target) {
    CONTEXT();
    if (target != GL_TEXTURE_2D && target != GL_TEXTURE_CUBE_MAP) ERROR(GL_INVALID_ENUM);
    SEND(MGL_GENERATE_MIPMAP, target);
}

MGL_API void glGenFramebuffers(GLsizei n, GLuint *framebuffers) {
    CONTEXT();
    new_names(c, &c->share->framebuffers, &c->share->next_framebuffer, sizeof(mgl_framebuffer), n, framebuffers);
}

MGL_API void glGenRenderbuffers(GLsizei n, GLuint *renderbuffers) {
    CONTEXT();
    new_names(c, &c->share->renderbuffers, &c->share->next_renderbuffer, sizeof(mgl_renderbuffer), n, renderbuffers);
}

MGL_API void glGenTextures(GLsizei n, GLuint *textures) {
    CONTEXT();
    new_names(c, &c->share->textures, &c->share->next_texture, sizeof(mgl_texture), n, textures);
}

static void active_variable(mgl_context *c, const mgl_variable *list, int count, GLuint indx, GLsizei bufSize, GLsizei *length,
                            GLint *size, GLenum *type, GLchar *name) {
    if (bufSize < 0 || indx >= (GLuint)count) {
        mgl_error(c, GL_INVALID_VALUE);
        return;
    }
    copy_text(list[indx].name, bufSize, length, name);
    if (size) *size = list[indx].size;
    if (type) *type = list[indx].type;
}

MGL_API void glGetActiveAttrib(GLuint program, GLuint indx, GLsizei bufSize, GLsizei *length, GLint *size, GLenum *type, GLchar *name) {
    CONTEXT();
    mgl_program *p = program_named(c, program);
    if (p) active_variable(c, p->attribs, p->attrib_count, indx, bufSize, length, size, type, name);
}

MGL_API void glGetActiveUniform(GLuint program, GLuint indx, GLsizei bufSize, GLsizei *length, GLint *size, GLenum *type, GLchar *name) {
    CONTEXT();
    mgl_program *p = program_named(c, program);
    if (p) active_variable(c, p->uniforms, p->uniform_count, indx, bufSize, length, size, type, name);
}

MGL_API void glGetAttachedShaders(GLuint program, GLsizei maxCount, GLsizei *count, GLuint *shaders) {
    CONTEXT();
    mgl_program *p = program_named(c, program);
    if (!p) return;
    if (maxCount < 0) ERROR(GL_INVALID_VALUE);
    GLsizei n = 0;
    for (int k = 0; k < 2 && shaders; k++)
        if (p->shaders[k] != 0 && n < maxCount) shaders[n++] = p->shaders[k];
    if (count) *count = n;
}

MGL_API GLint glGetAttribLocation(GLuint program, const GLchar *name) {
    CONTEXT(-1);
    mgl_program *p = program_named(c, program);
    if (!p) return -1;
    if (!p->linked) ERROR(GL_INVALID_OPERATION, -1);
    return name ? mgl_attrib_location(p, name) : -1;
}

MGL_API void glGetBooleanv(GLenum pname, GLboolean *params) {
    CONTEXT();
    mgl_value v;
    if (!mgl_get(c, pname, &v)) ERROR(GL_INVALID_ENUM);
    for (int i = 0; i < v.count && params; i++) params[i] = v.v[i] != 0;
}

MGL_API void glGetBufferParameteriv(GLenum target, GLenum pname, GLint *params) {
    CONTEXT();
    if (!buffer_binding(c, target)) return;
    if (pname != GL_BUFFER_SIZE && pname != GL_BUFFER_USAGE) ERROR(GL_INVALID_ENUM);
    mgl_buffer *b = bound_buffer(c, target);
    if (!b || !params) return;
    *params = pname == GL_BUFFER_SIZE ? (GLint)b->size : b->usage ? (GLint)b->usage : GL_STATIC_DRAW;
}

MGL_API GLenum glGetError(void) {
    CONTEXT(GL_INVALID_OPERATION);
    GLenum error = c->error;
    c->error = GL_NO_ERROR;
    /* None found here: the Mac may have found one. A lost stream has none
     * to tell, and a program that asks until there is none must come to an end. */
    if (error != GL_NO_ERROR || mgl_conn_lost()) return error;
    begin(c, MGL_GET_ERROR);
    mgl_reply r;
    if (!answer(c, &r)) return GL_NO_ERROR;
    error = mgl_reply_u32(&r);
    if (error != GL_NO_ERROR && error != GL_OUT_OF_MEMORY && error != GL_INVALID_FRAMEBUFFER_OPERATION &&
        (error < GL_INVALID_ENUM || error > GL_INVALID_OPERATION))
        r.bad = true;
    return mgl_reply_end(&r) ? error : GL_NO_ERROR;
}

MGL_API void glGetFloatv(GLenum pname, GLfloat *params) {
    CONTEXT();
    mgl_value v;
    if (!mgl_get(c, pname, &v)) ERROR(GL_INVALID_ENUM);
    for (int i = 0; i < v.count && params; i++) params[i] = (GLfloat)v.v[i];
}

MGL_API void glGetFramebufferAttachmentParameteriv(GLenum target, GLenum point, GLenum pname, GLint *params) {
    CONTEXT();
    const mgl_attachment *a = attachment(c, target, point);
    if (!a) return;
    GLint value;
    if (pname == GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE) value = (GLint)a->type;
    else if (pname == GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME && a->type != GL_NONE) value = (GLint)a->name;
    else if (pname == GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL && a->type == GL_TEXTURE) value = a->level;
    else if (pname == GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE && a->type == GL_TEXTURE) value = (GLint)a->face;
    else ERROR(GL_INVALID_ENUM);
    if (params) *params = value;
}

MGL_API void glGetIntegerv(GLenum pname, GLint *params) {
    CONTEXT();
    mgl_value v;
    if (!mgl_get(c, pname, &v)) ERROR(GL_INVALID_ENUM);
    for (int i = 0; i < v.count && params; i++) params[i] = as_int(&v, i);
}

/* The room the longest name of a list takes, with its 0; 0 for no names. */
static GLint longest(const mgl_variable *list, int count) {
    size_t most = 0;
    for (int i = 0; i < count; i++)
        if (strlen(list[i].name) + 1 > most) most = strlen(list[i].name) + 1;
    return (GLint)most;
}

MGL_API void glGetProgramiv(GLuint program, GLenum pname, GLint *params) {
    CONTEXT();
    mgl_program *p = program_named(c, program);
    if (!p) return;
    GLint value;
    switch (pname) {
    case GL_DELETE_STATUS: value = p->deleted; break;
    case GL_LINK_STATUS: value = p->linked; break;
    case GL_VALIDATE_STATUS: value = p->validated; break;
    case GL_INFO_LOG_LENGTH: value = p->info && *p->info ? (GLint)strlen(p->info) + 1 : 0; break;
    case GL_ATTACHED_SHADERS: value = (p->shaders[0] != 0) + (p->shaders[1] != 0); break;
    case GL_ACTIVE_ATTRIBUTES: value = p->attrib_count; break;
    case GL_ACTIVE_ATTRIBUTE_MAX_LENGTH: value = longest(p->attribs, p->attrib_count); break;
    case GL_ACTIVE_UNIFORMS: value = p->uniform_count; break;
    case GL_ACTIVE_UNIFORM_MAX_LENGTH: value = longest(p->uniforms, p->uniform_count); break;
    default: ERROR(GL_INVALID_ENUM);
    }
    if (params) *params = value;
}

MGL_API void glGetProgramInfoLog(GLuint program, GLsizei bufSize, GLsizei *length, GLchar *infoLog) {
    CONTEXT();
    mgl_program *p = program_named(c, program);
    if (!p) return;
    if (bufSize < 0) ERROR(GL_INVALID_VALUE);
    copy_text(p->info, bufSize, length, infoLog);
}

MGL_API void glGetRenderbufferParameteriv(GLenum target, GLenum pname, GLint *params) {
    CONTEXT();
    if (target != GL_RENDERBUFFER) ERROR(GL_INVALID_ENUM);
    const mgl_renderbuffer *b = mgl_map_get(&c->share->renderbuffers, c->renderbuffer);
    if (!b) ERROR(GL_INVALID_OPERATION);
    /* Red, green, blue, alpha, depth, stencil. */
    int size[6] = {0};
    switch (b->format) {
    case GL_RGBA4: size[0] = size[1] = size[2] = size[3] = 4; break;
    case GL_RGB5_A1: size[0] = size[1] = size[2] = 5, size[3] = 1; break;
    case GL_RGB565: size[0] = size[2] = 5, size[1] = 6; break;
    case GL_RGB8_OES: size[0] = size[1] = size[2] = 8; break;
    case GL_RGBA8_OES: size[0] = size[1] = size[2] = size[3] = 8; break;
    case GL_DEPTH_COMPONENT16: size[4] = 16; break;
    case GL_DEPTH_COMPONENT24_OES: size[4] = 24; break;
    case GL_STENCIL_INDEX8: size[5] = 8; break;
    case GL_DEPTH24_STENCIL8_OES: size[4] = 24, size[5] = 8; break;
    default: break;
    }
    GLint value;
    if (pname == GL_RENDERBUFFER_WIDTH) value = b->width;
    else if (pname == GL_RENDERBUFFER_HEIGHT) value = b->height;
    else if (pname == GL_RENDERBUFFER_INTERNAL_FORMAT) value = b->format ? (GLint)b->format : GL_RGBA4;
    else if (pname >= GL_RENDERBUFFER_RED_SIZE && pname <= GL_RENDERBUFFER_STENCIL_SIZE) value = size[pname - GL_RENDERBUFFER_RED_SIZE];
    else ERROR(GL_INVALID_ENUM);
    if (params) *params = value;
}

MGL_API void glGetShaderiv(GLuint shader, GLenum pname, GLint *params) {
    CONTEXT();
    mgl_shader *s = shader_named(c, shader);
    if (!s) return;
    GLint value;
    switch (pname) {
    case GL_SHADER_TYPE: value = (GLint)s->type; break;
    case GL_DELETE_STATUS: value = s->deleted; break;
    case GL_COMPILE_STATUS: value = s->compiled; break;
    case GL_INFO_LOG_LENGTH: value = s->info && *s->info ? (GLint)strlen(s->info) + 1 : 0; break;
    case GL_SHADER_SOURCE_LENGTH: value = s->source_len ? (GLint)s->source_len + 1 : 0; break;
    default: ERROR(GL_INVALID_ENUM);
    }
    if (params) *params = value;
}

MGL_API void glGetShaderInfoLog(GLuint shader, GLsizei bufSize, GLsizei *length, GLchar *infoLog) {
    CONTEXT();
    mgl_shader *s = shader_named(c, shader);
    if (!s) return;
    if (bufSize < 0) ERROR(GL_INVALID_VALUE);
    copy_text(s->info, bufSize, length, infoLog);
}

/* Every float is Metal's 32-bit one and every int its 32-bit one, whichever precision a shader asks. */
MGL_API void glGetShaderPrecisionFormat(GLenum shadertype, GLenum precisiontype, GLint *range, GLint *precision) {
    CONTEXT();
    if ((shadertype != GL_VERTEX_SHADER && shadertype != GL_FRAGMENT_SHADER) || precisiontype < GL_LOW_FLOAT || precisiontype > GL_HIGH_INT)
        ERROR(GL_INVALID_ENUM);
    bool floats = precisiontype <= GL_HIGH_FLOAT;
    if (range) {
        range[0] = floats ? 127 : 31;
        range[1] = floats ? 127 : 30;
    }
    if (precision) *precision = floats ? 23 : 0;
}

MGL_API void glGetShaderSource(GLuint shader, GLsizei bufSize, GLsizei *length, GLchar *source) {
    CONTEXT();
    mgl_shader *s = shader_named(c, shader);
    if (!s) return;
    if (bufSize < 0) ERROR(GL_INVALID_VALUE);
    copy_text(s->source, bufSize, length, source);
}

MGL_API const GLubyte *glGetString(GLenum name) {
    CONTEXT(NULL);
    switch (name) {
    case GL_VENDOR: return (const GLubyte *)"Monad";
    case GL_RENDERER: return (const GLubyte *)"Monad (Metal)";
    case GL_VERSION: return (const GLubyte *)"OpenGL ES 2.0 Monad";
    case GL_SHADING_LANGUAGE_VERSION: return (const GLubyte *)"OpenGL ES GLSL ES 1.00";
    case GL_EXTENSIONS:
        return (const GLubyte *)"GL_OES_standard_derivatives GL_OES_depth24 GL_OES_packed_depth_stencil GL_OES_rgb8_rgba8 "
                                "GL_OES_element_index_uint";
    default: ERROR(GL_INVALID_ENUM, NULL);
    }
}

static uint32_t *texture_parameter(mgl_context *c, GLenum target, GLenum pname) {
    mgl_texture *t = bound_texture(c, target);
    if (!t) return NULL;
    switch (pname) {
    case GL_TEXTURE_MIN_FILTER: return &t->min_filter;
    case GL_TEXTURE_MAG_FILTER: return &t->mag_filter;
    case GL_TEXTURE_WRAP_S: return &t->wrap_s;
    case GL_TEXTURE_WRAP_T: return &t->wrap_t;
    default:
        mgl_error(c, GL_INVALID_ENUM);
        return NULL;
    }
}

MGL_API void glGetTexParameterfv(GLenum target, GLenum pname, GLfloat *params) {
    CONTEXT();
    const uint32_t *value = texture_parameter(c, target, pname);
    if (value && params) *params = (GLfloat)*value;
}

MGL_API void glGetTexParameteriv(GLenum target, GLenum pname, GLint *params) {
    CONTEXT();
    const uint32_t *value = texture_parameter(c, target, pname);
    if (value && params) *params = (GLint)*value;
}

/* glGetUniformfv and glGetUniformiv: the value is the Mac's to tell, as
 * floats or as ints, whichever the uniform is; the program gets it as it asked. */
static void get_uniform(GLuint program, GLint location, GLfloat *floats, GLint *ints) {
    CONTEXT();
    mgl_program *p = program_named(c, program);
    if (!p) return;
    if (!p->linked || location < 0) ERROR(GL_INVALID_OPERATION);
    begin(c, MGL_GET_UNIFORM);
    mgl_u32(program);
    mgl_u32((uint32_t)location);
    mgl_reply r;
    if (!answer(c, &r)) return;
    uint32_t type = mgl_reply_u32(&r);
    size_t len;
    const uint8_t *data = mgl_reply_data(&r, &len);
    bool is_float;
    int numbers = mgl_uniform_numbers(type, &is_float);
    uint32_t raw[16] = {0};
    /* No type and data of no bytes: the Mac has an error for it (there
     * is no uniform at that place), and nothing is written. A type
     * without its value, or no data at all, is no answer. */
    if (type == 0 && data && len == 0) numbers = 0;
    else if (numbers == 0 || len != (size_t)numbers * 4) r.bad = true;
    else memcpy(raw, data, len);
    if (!mgl_reply_end(&r)) return;
    for (int i = 0; i < numbers; i++) {
        float f;
        int32_t n;
        memcpy(&f, &raw[i], 4);
        memcpy(&n, &raw[i], 4);
        if (floats) floats[i] = is_float ? f : (GLfloat)n;
        if (ints) ints[i] = is_float ? as_int(&(mgl_value){.kind = MGL_FLOAT, .v = {f}}, 0) : n;
    }
}

MGL_API void glGetUniformfv(GLuint program, GLint location, GLfloat *params) {
    if (params) get_uniform(program, location, params, NULL);
}

MGL_API void glGetUniformiv(GLuint program, GLint location, GLint *params) {
    if (params) get_uniform(program, location, NULL, params);
}

MGL_API GLint glGetUniformLocation(GLuint program, const GLchar *name) {
    CONTEXT(-1);
    mgl_program *p = program_named(c, program);
    if (!p) return -1;
    if (!p->linked) ERROR(GL_INVALID_OPERATION, -1);
    return name ? mgl_uniform_location(p, name) : -1;
}

static bool attrib_value(mgl_context *c, GLuint indx, GLenum pname, mgl_value *v) {
    if (indx >= MGL_ATTRIBS) {
        mgl_error(c, GL_INVALID_VALUE);
        return false;
    }
    const mgl_attrib *a = &c->attribs[indx];
    *v = (mgl_value){.kind = MGL_INT, .count = 1};
    switch (pname) {
    case GL_VERTEX_ATTRIB_ARRAY_ENABLED: v->v[0] = a->enabled; break;
    case GL_VERTEX_ATTRIB_ARRAY_SIZE: v->v[0] = a->size; break;
    case GL_VERTEX_ATTRIB_ARRAY_STRIDE: v->v[0] = a->stride; break;
    case GL_VERTEX_ATTRIB_ARRAY_TYPE: v->v[0] = a->type; break;
    case GL_VERTEX_ATTRIB_ARRAY_NORMALIZED: v->v[0] = a->normalized; break;
    case GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING: v->v[0] = a->buffer; break;
    case GL_CURRENT_VERTEX_ATTRIB:
        *v = (mgl_value){.kind = MGL_FLOAT, .count = 4, .v = {a->current[0], a->current[1], a->current[2], a->current[3]}};
        break;
    default:
        mgl_error(c, GL_INVALID_ENUM);
        return false;
    }
    return true;
}

MGL_API void glGetVertexAttribfv(GLuint indx, GLenum pname, GLfloat *params) {
    CONTEXT();
    mgl_value v;
    if (!attrib_value(c, indx, pname, &v)) return;
    for (int i = 0; i < v.count && params; i++) params[i] = (GLfloat)v.v[i];
}

MGL_API void glGetVertexAttribiv(GLuint indx, GLenum pname, GLint *params) {
    CONTEXT();
    mgl_value v;
    if (!attrib_value(c, indx, pname, &v)) return;
    for (int i = 0; i < v.count && params; i++) params[i] = as_int(&v, i);
}

MGL_API void glGetVertexAttribPointerv(GLuint indx, GLenum pname, void **pointer) {
    CONTEXT();
    if (indx >= MGL_ATTRIBS) ERROR(GL_INVALID_VALUE);
    if (pname != GL_VERTEX_ATTRIB_ARRAY_POINTER) ERROR(GL_INVALID_ENUM);
    if (pointer) *pointer = (void *)(uintptr_t)c->attribs[indx].pointer;
}

MGL_API void glHint(GLenum target, GLenum mode) {
    CONTEXT();
    if (mode != GL_DONT_CARE && mode != GL_FASTEST && mode != GL_NICEST) ERROR(GL_INVALID_ENUM);
    if (target == GL_GENERATE_MIPMAP_HINT) c->mipmap_hint = mode;
    else if (target == GL_FRAGMENT_SHADER_DERIVATIVE_HINT_OES) c->derivative_hint = mode;
    else ERROR(GL_INVALID_ENUM);
}

MGL_API GLboolean glIsBuffer(GLuint buffer) {
    CONTEXT(GL_FALSE);
    const mgl_buffer *b = mgl_map_get(&c->share->buffers, buffer);
    return b && b->live;
}

MGL_API GLboolean glIsEnabled(GLenum cap) {
    CONTEXT(GL_FALSE);
    const bool *flag = mgl_capability(c, cap);
    if (!flag) ERROR(GL_INVALID_ENUM, GL_FALSE);
    return *flag;
}

MGL_API GLboolean glIsFramebuffer(GLuint framebuffer) {
    CONTEXT(GL_FALSE);
    const mgl_framebuffer *f = mgl_map_get(&c->share->framebuffers, framebuffer);
    return f && f->live;
}

MGL_API GLboolean glIsProgram(GLuint program) {
    CONTEXT(GL_FALSE);
    return mgl_map_get(&c->share->programs, program) != NULL;
}

MGL_API GLboolean glIsRenderbuffer(GLuint renderbuffer) {
    CONTEXT(GL_FALSE);
    const mgl_renderbuffer *b = mgl_map_get(&c->share->renderbuffers, renderbuffer);
    return b && b->live;
}

MGL_API GLboolean glIsShader(GLuint shader) {
    CONTEXT(GL_FALSE);
    return mgl_map_get(&c->share->shaders, shader) != NULL;
}

MGL_API GLboolean glIsTexture(GLuint texture) {
    CONTEXT(GL_FALSE);
    const mgl_texture *t = mgl_map_get(&c->share->textures, texture);
    return t && t->target != 0;
}

MGL_API void glLineWidth(GLfloat width) {
    CONTEXT();
    if (!(width > 0)) ERROR(GL_INVALID_VALUE);
    c->line_width = width;
    SEND(MGL_LINE_WIDTH, F(width));
}

MGL_API void glLinkProgram(GLuint program) {
    CONTEXT();
    mgl_program *p = program_named(c, program);
    if (!p) return;
    begin(c, MGL_LINK_PROGRAM);
    mgl_u32(program);
    mgl_reply r;
    if (!answer(c, &r)) {
        p->linked = false;
        return;
    }
    if (!mgl_program_reflect(p, &r)) r.bad = true;
    if (!mgl_reply_end(&r)) p->linked = false;
}

MGL_API void glPixelStorei(GLenum pname, GLint param) {
    CONTEXT();
    if (pname != GL_PACK_ALIGNMENT && pname != GL_UNPACK_ALIGNMENT) ERROR(GL_INVALID_ENUM);
    if (param != 1 && param != 2 && param != 4 && param != 8) ERROR(GL_INVALID_VALUE);
    *(pname == GL_PACK_ALIGNMENT ? &c->pack_alignment : &c->unpack_alignment) = param;
}

MGL_API void glPolygonOffset(GLfloat factor, GLfloat units) {
    CONTEXT();
    c->polygon_factor = factor;
    c->polygon_units = units;
    SEND(MGL_POLYGON_OFFSET, F(factor), F(units));
}

MGL_API void glReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void *pixels) {
    CONTEXT();
    if ((format != GL_ALPHA && format != GL_RGB && format != GL_RGBA) ||
        (type != GL_UNSIGNED_BYTE && type != GL_UNSIGNED_SHORT_5_6_5 && type != GL_UNSIGNED_SHORT_4_4_4_4 &&
         type != GL_UNSIGNED_SHORT_5_5_5_1))
        ERROR(GL_INVALID_ENUM);
    /* Nothing drawn on is larger than the largest viewport. */
    if (width < 0 || height < 0 || width > MGL_MAX_SIZE || height > MGL_MAX_SIZE) ERROR(GL_INVALID_VALUE);
    if (format != GL_RGBA || type != GL_UNSIGNED_BYTE) ERROR(GL_INVALID_OPERATION);
    if (width == 0 || height == 0 || !pixels) return;
    begin(c, MGL_READ_PIXELS);
    mgl_u32((uint32_t)x);
    mgl_u32((uint32_t)y);
    mgl_u32((uint32_t)width);
    mgl_u32((uint32_t)height);
    mgl_u32(format);
    mgl_u32(type);
    mgl_reply r;
    if (!answer(c, &r)) return;
    /* An answer of no length: the Mac has an error for this read, and the
     * program's memory stays as it is. Any other is all the pixels asked for. */
    if (r.len > 0) {
        size_t len, row = (size_t)width * 4, align = (size_t)c->pack_alignment, stride = (row + align - 1) & ~(align - 1);
        const uint8_t *from = mgl_reply_data(&r, &len);
        if (len == row * (size_t)height)
            for (size_t line = 0; line < (size_t)height; line++) memcpy((uint8_t *)pixels + line * stride, from + line * row, row);
        else r.bad = true;
    }
    (void)mgl_reply_end(&r);
}

/* Nothing to release: the compiler is the Mac's. */
MGL_API void glReleaseShaderCompiler(void) {}

MGL_API void glRenderbufferStorage(GLenum target, GLenum internalformat, GLsizei width, GLsizei height) {
    CONTEXT();
    if (target != GL_RENDERBUFFER) ERROR(GL_INVALID_ENUM);
    switch (internalformat) {
    case GL_RGBA4:
    case GL_RGB5_A1:
    case GL_RGB565:
    case GL_RGB8_OES:
    case GL_RGBA8_OES:
    case GL_DEPTH_COMPONENT16:
    case GL_DEPTH_COMPONENT24_OES:
    case GL_STENCIL_INDEX8:
    case GL_DEPTH24_STENCIL8_OES: break;
    default: ERROR(GL_INVALID_ENUM);
    }
    if (width < 0 || height < 0 || width > MGL_MAX_SIZE || height > MGL_MAX_SIZE) ERROR(GL_INVALID_VALUE);
    mgl_renderbuffer *b = mgl_map_get(&c->share->renderbuffers, c->renderbuffer);
    if (!b) ERROR(GL_INVALID_OPERATION);
    b->format = internalformat;
    b->width = width;
    b->height = height;
    SEND(MGL_RENDERBUFFER_STORAGE, target, internalformat, width, height);
}

MGL_API void glSampleCoverage(GLfloat value, GLboolean invert) {
    CONTEXT();
    c->coverage = unit(value);
    c->coverage_invert = invert != 0;
    SEND(MGL_SAMPLE_COVERAGE, F(value), invert != 0);
}

MGL_API void glScissor(GLint x, GLint y, GLsizei width, GLsizei height) {
    CONTEXT();
    if (width < 0 || height < 0) ERROR(GL_INVALID_VALUE);
    c->scissor[0] = x;
    c->scissor[1] = y;
    c->scissor[2] = width;
    c->scissor[3] = height;
    SEND(MGL_SCISSOR, x, y, width, height);
}

/* No binary format is offered (GL_NUM_SHADER_BINARY_FORMATS is 0). */
MGL_API void glShaderBinary(GLsizei n, const GLuint *shaders, GLenum binaryformat, const void *binary, GLsizei length) {
    (void)n, (void)shaders, (void)binaryformat, (void)binary, (void)length;
    CONTEXT();
    ERROR(GL_INVALID_ENUM);
}

MGL_API void glShaderSource(GLuint shader, GLsizei count, const GLchar *const *string, const GLint *length) {
    CONTEXT();
    mgl_shader *s = shader_named(c, shader);
    if (!s) return;
    if (count < 0) ERROR(GL_INVALID_VALUE);
    /* The strings joined: twice over them, for the room and for the text. */
    size_t total = 0;
    char *source = NULL;
    for (int pass = 0; pass < 2; pass++) {
        size_t at = 0;
        for (GLsizei i = 0; i < count && string; i++) {
            if (!string[i]) continue;
            size_t len = length && length[i] >= 0 ? (size_t)length[i] : strlen(string[i]);
            if (source) memcpy(source + at, string[i], len);
            at += len;
        }
        if (pass == 1) break;
        total = at;
        if (total > MWM_GL_COMMAND || !(source = malloc(total + 1))) ERROR(GL_OUT_OF_MEMORY);
    }
    source[total] = 0;
    begin(c, MGL_SHADER_SOURCE);
    mgl_u32(shader);
    mgl_data(source, total);
    if (!mgl_end()) {
        free(source);
        ERROR(GL_OUT_OF_MEMORY);
    }
    free(s->source);
    s->source = source;
    s->source_len = total;
}

static int stencil_ref(GLint ref) { return ref < 0 ? 0 : ref > 255 ? 255 : ref; }

MGL_API void glStencilFunc(GLenum func, GLint ref, GLuint mask) {
    CONTEXT();
    if (!compare_func(func)) ERROR(GL_INVALID_ENUM);
    for (int k = 0; k < 2; k++) {
        c->stencil[k].func = func;
        c->stencil[k].ref = stencil_ref(ref);
        c->stencil[k].mask = mask;
    }
    SEND(MGL_STENCIL_FUNC, func, ref, mask);
}

MGL_API void glStencilFuncSeparate(GLenum face, GLenum func, GLint ref, GLuint mask) {
    CONTEXT();
    if (!a_face(face) || !compare_func(func)) ERROR(GL_INVALID_ENUM);
    EACH_FACE(face, k) {
        c->stencil[k].func = func;
        c->stencil[k].ref = stencil_ref(ref);
        c->stencil[k].mask = mask;
    }
    SEND(MGL_STENCIL_FUNC_SEPARATE, face, func, ref, mask);
}

MGL_API void glStencilMask(GLuint mask) {
    CONTEXT();
    c->stencil[0].writemask = c->stencil[1].writemask = mask;
    SEND(MGL_STENCIL_MASK, mask);
}

MGL_API void glStencilMaskSeparate(GLenum face, GLuint mask) {
    CONTEXT();
    if (!a_face(face)) ERROR(GL_INVALID_ENUM);
    EACH_FACE(face, k) c->stencil[k].writemask = mask;
    SEND(MGL_STENCIL_MASK_SEPARATE, face, mask);
}

MGL_API void glStencilOp(GLenum fail, GLenum zfail, GLenum zpass) {
    CONTEXT();
    if (!stencil_op(fail) || !stencil_op(zfail) || !stencil_op(zpass)) ERROR(GL_INVALID_ENUM);
    for (int k = 0; k < 2; k++) {
        c->stencil[k].fail = fail;
        c->stencil[k].zfail = zfail;
        c->stencil[k].zpass = zpass;
    }
    SEND(MGL_STENCIL_OP, fail, zfail, zpass);
}

MGL_API void glStencilOpSeparate(GLenum face, GLenum fail, GLenum zfail, GLenum zpass) {
    CONTEXT();
    if (!a_face(face) || !stencil_op(fail) || !stencil_op(zfail) || !stencil_op(zpass)) ERROR(GL_INVALID_ENUM);
    EACH_FACE(face, k) {
        c->stencil[k].fail = fail;
        c->stencil[k].zfail = zfail;
        c->stencil[k].zpass = zpass;
    }
    SEND(MGL_STENCIL_OP_SEPARATE, face, fail, zfail, zpass);
}

/* A data argument of width × height pixels: the program's rows, which
 * begin at multiples of its GL_UNPACK_ALIGNMENT, one after the other with
 * nothing between them. */
static void put_pixels(const mgl_context *c, const void *pixels, size_t width, size_t height, size_t pixel) {
    size_t row = width * pixel, align = (size_t)c->unpack_alignment, stride = (row + align - 1) & ~(align - 1);
    uint8_t *to = mgl_data_room(row * height);
    if (!to) return;
    if (stride == row) memcpy(to, pixels, row * height);
    else
        for (size_t line = 0; line < height; line++) memcpy(to + line * row, (const uint8_t *)pixels + line * stride, row);
}

MGL_API void glTexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format,
                          GLenum type, const void *pixels) {
    CONTEXT();
    int pixel = mgl_pixel_bytes(format, type);
    if (!image_target(target) || pixel < 0) ERROR(GL_INVALID_ENUM);
    if (level < 0 || level > MGL_MAX_LEVEL || width < 0 || height < 0 || width > MGL_MAX_SIZE || height > MGL_MAX_SIZE || border != 0)
        ERROR(GL_INVALID_VALUE);
    /* A cube map's faces are squares. */
    if (target != GL_TEXTURE_2D && width != height) ERROR(GL_INVALID_VALUE);
    if (pixel == 0 || (GLenum)internalformat != format) ERROR(GL_INVALID_OPERATION);
    begin(c, MGL_TEX_IMAGE_2D);
    mgl_u32(target);
    mgl_u32((uint32_t)level);
    mgl_u32((uint32_t)internalformat);
    mgl_u32((uint32_t)width);
    mgl_u32((uint32_t)height);
    mgl_u32((uint32_t)border);
    mgl_u32(format);
    mgl_u32(type);
    if (pixels) put_pixels(c, pixels, (size_t)width, (size_t)height, (size_t)pixel);
    else mgl_none();
    end(c);
}

/* A filter or a wrap mode for the texture bound. False: it is none (the error is set). */
static bool set_texture_parameter(mgl_context *c, GLenum target, GLenum pname, GLenum value) {
    uint32_t *parameter = texture_parameter(c, target, pname);
    if (!parameter) return false;
    bool good;
    if (pname == GL_TEXTURE_MAG_FILTER) good = value == GL_NEAREST || value == GL_LINEAR;
    else if (pname == GL_TEXTURE_MIN_FILTER)
        good = value == GL_NEAREST || value == GL_LINEAR || (value >= GL_NEAREST_MIPMAP_NEAREST && value <= GL_LINEAR_MIPMAP_LINEAR);
    else good = value == GL_REPEAT || value == GL_CLAMP_TO_EDGE || value == GL_MIRRORED_REPEAT;
    if (!good) {
        mgl_error(c, GL_INVALID_ENUM);
        return false;
    }
    *parameter = value;
    return true;
}

MGL_API void glTexParameterf(GLenum target, GLenum pname, GLfloat param) {
    CONTEXT();
    GLenum value = param >= 0 && param < 65536 ? (GLenum)param : 0;
    if (set_texture_parameter(c, target, pname, value)) SEND(MGL_TEX_PARAMETERF, target, pname, F(param));
}

MGL_API void glTexParameterfv(GLenum target, GLenum pname, const GLfloat *params) {
    if (params) glTexParameterf(target, pname, params[0]);
}

MGL_API void glTexParameteri(GLenum target, GLenum pname, GLint param) {
    CONTEXT();
    if (set_texture_parameter(c, target, pname, (GLenum)param)) SEND(MGL_TEX_PARAMETERI, target, pname, param);
}

MGL_API void glTexParameteriv(GLenum target, GLenum pname, const GLint *params) {
    if (params) glTexParameteri(target, pname, params[0]);
}

MGL_API void glTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format,
                             GLenum type, const void *pixels) {
    CONTEXT();
    int pixel = mgl_pixel_bytes(format, type);
    if (!image_target(target) || pixel < 0) ERROR(GL_INVALID_ENUM);
    if (level < 0 || level > MGL_MAX_LEVEL || xoffset < 0 || yoffset < 0 || width < 0 || height < 0 || width > MGL_MAX_SIZE ||
        height > MGL_MAX_SIZE)
        ERROR(GL_INVALID_VALUE);
    if (pixel == 0) ERROR(GL_INVALID_OPERATION);
    if (width == 0 || height == 0 || !pixels) return;
    begin(c, MGL_TEX_SUB_IMAGE_2D);
    mgl_u32(target);
    mgl_u32((uint32_t)level);
    mgl_u32((uint32_t)xoffset);
    mgl_u32((uint32_t)yoffset);
    mgl_u32((uint32_t)width);
    mgl_u32((uint32_t)height);
    mgl_u32(format);
    mgl_u32(type);
    put_pixels(c, pixels, (size_t)width, (size_t)height, (size_t)pixel);
    end(c);
}

/* Whether a glUniform* call is one to send: a program is in use, and the
 * place is one (-1 is the place of a uniform the program has not, and
 * setting it is nothing). */
static bool a_uniform(mgl_context *c, GLint location) {
    if (c->program == 0 || location < -1) {
        mgl_error(c, GL_INVALID_OPERATION);
        return false;
    }
    return location != -1;
}

static void uniform(GLint location, uint32_t op, const uint32_t *values, int count) {
    CONTEXT();
    if (!a_uniform(c, location)) return;
    begin(c, op);
    mgl_u32((uint32_t)location);
    for (int i = 0; i < count; i++) mgl_u32(values[i]);
    end(c);
}

/* `count` values of `numbers` floats or ints each. */
static void uniforms(GLint location, uint32_t op, GLsizei count, size_t numbers, bool transpose, const void *values) {
    CONTEXT();
    /* OpenGL ES 2.0 has matrices one way only. */
    if (count < 0 || transpose) ERROR(GL_INVALID_VALUE);
    if (!a_uniform(c, location) || count == 0 || !values) return;
    begin(c, op);
    mgl_u32((uint32_t)location);
    mgl_u32((uint32_t)count);
    mgl_data(values, (size_t)count * numbers * 4);
    end(c);
}

MGL_API void glUniform1f(GLint location, GLfloat x) { uniform(location, MGL_UNIFORM_1F, (uint32_t[]){F(x)}, 1); }
MGL_API void glUniform1fv(GLint location, GLsizei count, const GLfloat *v) { uniforms(location, MGL_UNIFORM_1FV, count, 1, false, v); }
MGL_API void glUniform1i(GLint location, GLint x) { uniform(location, MGL_UNIFORM_1I, (uint32_t[]){(uint32_t)x}, 1); }
MGL_API void glUniform1iv(GLint location, GLsizei count, const GLint *v) { uniforms(location, MGL_UNIFORM_1IV, count, 1, false, v); }
MGL_API void glUniform2f(GLint location, GLfloat x, GLfloat y) { uniform(location, MGL_UNIFORM_2F, (uint32_t[]){F(x), F(y)}, 2); }
MGL_API void glUniform2fv(GLint location, GLsizei count, const GLfloat *v) { uniforms(location, MGL_UNIFORM_2FV, count, 2, false, v); }
MGL_API void glUniform2i(GLint location, GLint x, GLint y) { uniform(location, MGL_UNIFORM_2I, (uint32_t[]){(uint32_t)x, (uint32_t)y}, 2); }
MGL_API void glUniform2iv(GLint location, GLsizei count, const GLint *v) { uniforms(location, MGL_UNIFORM_2IV, count, 2, false, v); }
MGL_API void glUniform3f(GLint location, GLfloat x, GLfloat y, GLfloat z) {
    uniform(location, MGL_UNIFORM_3F, (uint32_t[]){F(x), F(y), F(z)}, 3);
}
MGL_API void glUniform3fv(GLint location, GLsizei count, const GLfloat *v) { uniforms(location, MGL_UNIFORM_3FV, count, 3, false, v); }
MGL_API void glUniform3i(GLint location, GLint x, GLint y, GLint z) {
    uniform(location, MGL_UNIFORM_3I, (uint32_t[]){(uint32_t)x, (uint32_t)y, (uint32_t)z}, 3);
}
MGL_API void glUniform3iv(GLint location, GLsizei count, const GLint *v) { uniforms(location, MGL_UNIFORM_3IV, count, 3, false, v); }
MGL_API void glUniform4f(GLint location, GLfloat x, GLfloat y, GLfloat z, GLfloat w) {
    uniform(location, MGL_UNIFORM_4F, (uint32_t[]){F(x), F(y), F(z), F(w)}, 4);
}
MGL_API void glUniform4fv(GLint location, GLsizei count, const GLfloat *v) { uniforms(location, MGL_UNIFORM_4FV, count, 4, false, v); }
MGL_API void glUniform4i(GLint location, GLint x, GLint y, GLint z, GLint w) {
    uniform(location, MGL_UNIFORM_4I, (uint32_t[]){(uint32_t)x, (uint32_t)y, (uint32_t)z, (uint32_t)w}, 4);
}
MGL_API void glUniform4iv(GLint location, GLsizei count, const GLint *v) { uniforms(location, MGL_UNIFORM_4IV, count, 4, false, v); }
MGL_API void glUniformMatrix2fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat *value) {
    uniforms(location, MGL_UNIFORM_MATRIX_2FV, count, 4, transpose != 0, value);
}
MGL_API void glUniformMatrix3fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat *value) {
    uniforms(location, MGL_UNIFORM_MATRIX_3FV, count, 9, transpose != 0, value);
}
MGL_API void glUniformMatrix4fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat *value) {
    uniforms(location, MGL_UNIFORM_MATRIX_4FV, count, 16, transpose != 0, value);
}

MGL_API void glUseProgram(GLuint program) {
    CONTEXT();
    if (program != 0) {
        mgl_program *p = program_named(c, program);
        if (!p) return;
        if (!p->linked) ERROR(GL_INVALID_OPERATION);
        p->used++;
    }
    uint32_t before = c->program;
    c->program = program;
    SEND(MGL_USE_PROGRAM, program);
    mgl_program_unused(c->share, before);
}

/* The Mac draws with whatever links: a program that linked is one to draw with. */
MGL_API void glValidateProgram(GLuint program) {
    CONTEXT();
    mgl_program *p = program_named(c, program);
    if (p) p->validated = p->linked;
}

/* glVertexAttrib1f to 4fv all come to this: what is not given is 0, 0, 0, 1. */
static void vertex_attrib(GLuint indx, GLfloat x, GLfloat y, GLfloat z, GLfloat w) {
    CONTEXT();
    if (indx >= MGL_ATTRIBS) ERROR(GL_INVALID_VALUE);
    float *current = c->attribs[indx].current;
    current[0] = x;
    current[1] = y;
    current[2] = z;
    current[3] = w;
    SEND(MGL_VERTEX_ATTRIB_4F, indx, F(x), F(y), F(z), F(w));
}

MGL_API void glVertexAttrib1f(GLuint indx, GLfloat x) { vertex_attrib(indx, x, 0, 0, 1); }
MGL_API void glVertexAttrib1fv(GLuint indx, const GLfloat *values) {
    if (values) vertex_attrib(indx, values[0], 0, 0, 1);
}
MGL_API void glVertexAttrib2f(GLuint indx, GLfloat x, GLfloat y) { vertex_attrib(indx, x, y, 0, 1); }
MGL_API void glVertexAttrib2fv(GLuint indx, const GLfloat *values) {
    if (values) vertex_attrib(indx, values[0], values[1], 0, 1);
}
MGL_API void glVertexAttrib3f(GLuint indx, GLfloat x, GLfloat y, GLfloat z) { vertex_attrib(indx, x, y, z, 1); }
MGL_API void glVertexAttrib3fv(GLuint indx, const GLfloat *values) {
    if (values) vertex_attrib(indx, values[0], values[1], values[2], 1);
}
MGL_API void glVertexAttrib4f(GLuint indx, GLfloat x, GLfloat y, GLfloat z, GLfloat w) { vertex_attrib(indx, x, y, z, w); }
MGL_API void glVertexAttrib4fv(GLuint indx, const GLfloat *values) {
    if (values) vertex_attrib(indx, values[0], values[1], values[2], values[3]);
}

MGL_API void glVertexAttribPointer(GLuint indx, GLint size, GLenum type, GLboolean normalized, GLsizei stride, const void *pointer) {
    CONTEXT();
    if (type != GL_BYTE && type != GL_UNSIGNED_BYTE && type != GL_SHORT && type != GL_UNSIGNED_SHORT && type != GL_FIXED && type != GL_FLOAT)
        ERROR(GL_INVALID_ENUM);
    if (indx >= MGL_ATTRIBS || size < 1 || size > 4 || stride < 0) ERROR(GL_INVALID_VALUE);
    if (c->array_buffer != 0 && (uintptr_t)pointer > UINT32_MAX) ERROR(GL_INVALID_VALUE);
    mgl_attrib *a = &c->attribs[indx];
    a->size = size;
    a->type = type;
    a->normalized = normalized != 0;
    a->stride = stride;
    a->pointer = pointer;
    a->buffer = c->array_buffer;
    /* With no buffer bound it is the program's memory, which is read when
     * a draw says how much of it (ClientArray). */
    if (a->buffer != 0) SEND(MGL_VERTEX_ATTRIB_POINTER, indx, size, type, normalized != 0, stride, (uint32_t)(uintptr_t)pointer);
}

MGL_API void glViewport(GLint x, GLint y, GLsizei width, GLsizei height) {
    CONTEXT();
    if (width < 0 || height < 0) ERROR(GL_INVALID_VALUE);
    c->viewport[0] = x;
    c->viewport[1] = y;
    c->viewport[2] = width > MGL_MAX_SIZE ? MGL_MAX_SIZE : width;
    c->viewport[3] = height > MGL_MAX_SIZE ? MGL_MAX_SIZE : height;
    SEND(MGL_VIEWPORT, x, y, width, height);
}
