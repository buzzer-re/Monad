/*
 * mgl_state.c — what the library remembers of a context, so that a
 * program's questions (glGet*, glIs*) are answered here in the VM and
 * cost no trip to the Mac and back: OpenGL ES 2.0's state with its first
 * values, the objects by their names, what a linked program is made of
 * (from the LinkProgram reply), and the few tables both the questions and
 * the commands need.
 */
#include "mgl_internal.h"

#include <stdlib.h>
#include <string.h>

/* ---- Objects by name ---- */

static uint32_t slot(uint32_t name, uint32_t room) { return (name * 2654435761u) & (room - 1); }

/* Where the name is, or the empty place its search ends at. There is one:
 * the map is never more than half full. */
static uint32_t find(const mgl_map *m, uint32_t name) {
    uint32_t i = slot(name, m->room);
    while (m->names[i] != name && m->names[i] != 0) i = (i + 1) & (m->room - 1);
    return i;
}

void *mgl_map_get(const mgl_map *m, uint32_t name) {
    if (name == 0 || m->room == 0) return NULL;
    uint32_t i = find(m, name);
    return m->names[i] == name ? m->objects[i] : NULL;
}

static bool grow(mgl_map *m) {
    mgl_map larger = {.room = m->room ? m->room * 2 : 16, .count = m->count};
    larger.names = calloc(larger.room, sizeof *larger.names);
    larger.objects = calloc(larger.room, sizeof *larger.objects);
    if (!larger.names || !larger.objects) {
        free(larger.names);
        free(larger.objects);
        return false;
    }
    for (uint32_t i = 0; i < m->room; i++) {
        if (m->names[i] == 0) continue;
        uint32_t at = find(&larger, m->names[i]);
        larger.names[at] = m->names[i];
        larger.objects[at] = m->objects[i];
    }
    free(m->names);
    free(m->objects);
    *m = larger;
    return true;
}

void *mgl_map_make(mgl_map *m, uint32_t name, size_t size) {
    if (name == 0) return NULL;
    void *object = mgl_map_get(m, name);
    if (object) return object;
    if ((m->count + 1) * 2 > m->room && !grow(m)) return NULL;
    object = calloc(1, size);
    if (!object) return NULL;
    memcpy(object, &name, sizeof name);
    uint32_t i = find(m, name);
    m->names[i] = name;
    m->objects[i] = object;
    m->count++;
    return object;
}

void *mgl_map_take(mgl_map *m, uint32_t name) {
    if (name == 0 || m->room == 0) return NULL;
    uint32_t mask = m->room - 1, hole = find(m, name);
    if (m->names[hole] != name) return NULL;
    void *object = m->objects[hole];
    /* The names after it that were looking for a place from before the
     * hole move up into it, so that their search still finds them. */
    for (uint32_t j = (hole + 1) & mask; m->names[j] != 0; j = (j + 1) & mask) {
        uint32_t home = slot(m->names[j], m->room);
        if (((j - home) & mask) >= ((j - hole) & mask)) {
            m->names[hole] = m->names[j];
            m->objects[hole] = m->objects[j];
            hole = j;
        }
    }
    m->names[hole] = 0;
    m->objects[hole] = NULL;
    m->count--;
    return object;
}

uint32_t mgl_map_new_name(const mgl_map *m, const mgl_map *also, uint32_t *next) {
    /* A program may bind names of its own choosing: those are passed over. */
    for (;;) {
        uint32_t name = ++*next;
        if (name != 0 && !mgl_map_get(m, name) && !(also && mgl_map_get(also, name))) return name;
    }
}

/* ---- Objects ---- */

char *mgl_text(const void *bytes, size_t count) {
    char *text = malloc(count + 1);
    if (!text) return NULL;
    if (count > 0) memcpy(text, bytes, count);
    text[count] = 0;
    return text;
}

void mgl_texture_first(mgl_texture *t) {
    t->min_filter = GL_NEAREST_MIPMAP_LINEAR;
    t->mag_filter = GL_LINEAR;
    t->wrap_s = t->wrap_t = GL_REPEAT;
}

void mgl_buffer_free(mgl_buffer *b) {
    free(b->shadow);
    free(b);
}

void mgl_shader_free(mgl_shader *s) {
    free(s->source);
    free(s->info);
    free(s);
}

static void free_variables(mgl_variable *list, int count) {
    for (int i = 0; i < count; i++) free(list[i].name);
    free(list);
}

void mgl_shader_detached(mgl_share *s, uint32_t name) {
    mgl_shader *shader = mgl_map_get(&s->shaders, name);
    if (shader && --shader->attached == 0 && shader->deleted) mgl_shader_free(mgl_map_take(&s->shaders, name));
}

void mgl_program_free(mgl_share *s, mgl_program *p) {
    for (int i = 0; i < 2; i++) mgl_shader_detached(s, p->shaders[i]);
    free_variables(p->attribs, p->attrib_count);
    free_variables(p->uniforms, p->uniform_count);
    free(p->info);
    free(p);
}

void mgl_program_unused(mgl_share *s, uint32_t name) {
    mgl_program *program = mgl_map_get(&s->programs, name);
    if (program && --program->used == 0 && program->deleted) mgl_program_free(s, mgl_map_take(&s->programs, name));
}

/* ---- A linked program ---- */

static bool variables(mgl_reply *r, mgl_variable **list, int *count) {
    uint32_t n = mgl_reply_u32(r);
    /* Each takes four words at the least: more of them than the reply has
     * room for is no number to make room by. */
    if (r->bad || n > (r->len - r->at) / 16) return false;
    mgl_variable *made = calloc(n ? n : 1, sizeof *made);
    if (!made) return false;
    *list = made;
    *count = (int)n;
    for (uint32_t i = 0; i < n; i++) {
        made[i].location = (int)mgl_reply_u32(r);
        made[i].type = mgl_reply_u32(r);
        made[i].size = (int)mgl_reply_u32(r);
        size_t len;
        const uint8_t *name = mgl_reply_data(r, &len);
        if (r->bad || !name || made[i].size < 0) return false;
        made[i].name = mgl_text(name, len);
        if (!made[i].name) return false;
    }
    return true;
}

/* What a link before told is no longer so. */
static void forget(mgl_program *p) {
    free_variables(p->attribs, p->attrib_count);
    free_variables(p->uniforms, p->uniform_count);
    free(p->info);
    p->attribs = p->uniforms = NULL;
    p->attrib_count = p->uniform_count = 0;
    p->info = NULL;
    p->linked = p->validated = false;
}

bool mgl_program_reflect(mgl_program *p, mgl_reply *r) {
    forget(p);
    uint32_t linked = mgl_reply_u32(r);
    size_t len;
    const uint8_t *info = mgl_reply_data(r, &len);
    if (r->bad || linked > 1) return false;
    p->info = mgl_text(info, len);
    if (!variables(r, &p->attribs, &p->attrib_count) || !variables(r, &p->uniforms, &p->uniform_count)) {
        /* Half a list is no list: a name in it may be missing. */
        forget(p);
        return false;
    }
    p->linked = linked == 1;
    return true;
}

int mgl_attrib_location(const mgl_program *p, const char *name) {
    for (int i = 0; i < p->attrib_count; i++)
        if (strcmp(p->attribs[i].name, name) == 0) return p->attribs[i].location;
    return -1;
}

int mgl_uniform_location(const mgl_program *p, const char *name) {
    /* "name[7]": where the name ends, and the 7. */
    size_t len = strlen(name), stem = len;
    long element = -1;
    if (len >= 3 && name[len - 1] == ']') {
        size_t at = len - 1;
        while (at > 0 && name[at - 1] >= '0' && name[at - 1] <= '9') at--;
        if (at > 0 && at < len - 1 && len - 1 - at <= 9 && name[at - 1] == '[') {
            element = strtol(name + at, NULL, 10);
            stem = at - 1;
        }
    }
    for (int i = 0; i < p->uniform_count; i++) {
        const mgl_variable *u = &p->uniforms[i];
        if (strcmp(u->name, name) == 0) return u->location;
        /* An array is told once, as "name[0]": "name" is its first
         * element too, and element i is i places on. */
        size_t ulen = strlen(u->name);
        if (ulen < 3 || strcmp(u->name + ulen - 3, "[0]") != 0) continue;
        ulen -= 3;
        if (ulen == len && memcmp(u->name, name, len) == 0) return u->location;
        if (element >= 0 && element < u->size && ulen == stem && memcmp(u->name, name, stem) == 0)
            return (int)((uint32_t)u->location + (uint32_t)element);
    }
    return -1;
}

/* ---- Contexts ---- */

mgl_context *mgl_context_new(mgl_context *share) {
    mgl_context *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->share = share ? share->share : calloc(1, sizeof *c->share);
    if (!c->share) {
        free(c);
        return NULL;
    }
    c->share->contexts++;

    for (int i = 0; i < 2; i++) mgl_texture_first(&c->texture_zero[i]);
    for (int i = 0; i < MGL_ATTRIBS; i++) {
        c->attribs[i].size = 4;
        c->attribs[i].type = GL_FLOAT;
        c->attribs[i].current[3] = 1;
    }
    c->clear_depth = 1;
    c->depth_range[1] = 1;
    for (int i = 0; i < 4; i++) c->color_mask[i] = true;
    c->depth_mask = true;
    c->depth_func = GL_LESS;
    c->cull_mode = GL_BACK;
    c->front_face = GL_CCW;
    c->line_width = 1;
    c->coverage = 1;
    c->blend_rgb = c->blend_alpha = GL_FUNC_ADD;
    c->src_rgb = c->src_alpha = GL_ONE;
    c->dst_rgb = c->dst_alpha = GL_ZERO;
    for (int i = 0; i < 2; i++)
        c->stencil[i] = (mgl_stencil){.func = GL_ALWAYS, .mask = ~0u, .writemask = ~0u, .fail = GL_KEEP, .zfail = GL_KEEP, .zpass = GL_KEEP};
    c->dither = true;
    c->pack_alignment = c->unpack_alignment = 4;
    c->mipmap_hint = c->derivative_hint = GL_DONT_CARE;
    return c;
}

static void free_map(mgl_map *m) {
    free(m->names);
    free(m->objects);
    *m = (mgl_map){0};
}

void mgl_context_free(mgl_context *c) {
    mgl_share *s = c->share;
    mgl_program_unused(s, c->program);
    if (--s->contexts == 0) {
        /* Programs first: freeing one lets go of its shaders. */
        for (uint32_t i = 0; i < s->programs.room; i++)
            if (s->programs.names[i]) {
                mgl_program *p = s->programs.objects[i];
                p->shaders[0] = p->shaders[1] = 0;
                mgl_program_free(s, p);
            }
        for (uint32_t i = 0; i < s->shaders.room; i++)
            if (s->shaders.names[i]) mgl_shader_free(s->shaders.objects[i]);
        for (uint32_t i = 0; i < s->buffers.room; i++)
            if (s->buffers.names[i]) mgl_buffer_free(s->buffers.objects[i]);
        mgl_map *plain[] = {&s->textures, &s->renderbuffers, &s->framebuffers};
        for (int k = 0; k < 3; k++)
            for (uint32_t i = 0; i < plain[k]->room; i++)
                if (plain[k]->names[i]) free(plain[k]->objects[i]);
        free_map(&s->programs);
        free_map(&s->shaders);
        free_map(&s->buffers);
        free_map(&s->textures);
        free_map(&s->renderbuffers);
        free_map(&s->framebuffers);
        free(s);
    }
    free(c);
}

void mgl_context_first_surface(mgl_context *c, int width, int height) {
    c->viewport[2] = c->scissor[2] = width;
    c->viewport[3] = c->scissor[3] = height;
}

void mgl_error(mgl_context *c, uint32_t error) {
    if (c->error == GL_NO_ERROR) c->error = error;
}

/* ---- What glGet* answers ---- */

bool *mgl_capability(mgl_context *c, uint32_t cap) {
    switch (cap) {
    case GL_BLEND: return &c->blend;
    case GL_CULL_FACE: return &c->cull_face;
    case GL_DEPTH_TEST: return &c->depth_test;
    case GL_DITHER: return &c->dither;
    case GL_POLYGON_OFFSET_FILL: return &c->polygon_offset;
    case GL_SAMPLE_ALPHA_TO_COVERAGE: return &c->alpha_to_coverage;
    case GL_SAMPLE_COVERAGE: return &c->sample_coverage;
    case GL_SCISSOR_TEST: return &c->scissor_test;
    case GL_STENCIL_TEST: return &c->stencil_test;
    default: return NULL;
    }
}

static bool put(mgl_value *value, int kind, int count, double a, double b, double c, double d) {
    *value = (mgl_value){.kind = kind, .count = count, .v = {a, b, c, d}};
    return true;
}

bool mgl_get(const mgl_context *c, uint32_t pname, mgl_value *value) {
#define INT1(x) return put(value, MGL_INT, 1, (double)(int32_t)(x), 0, 0, 0)
#define BOOL1(x) return put(value, MGL_BOOL, 1, (x) ? 1 : 0, 0, 0, 0)
#define FLOAT1(x) return put(value, MGL_FLOAT, 1, (x), 0, 0, 0)
    const mgl_stencil *front = &c->stencil[0], *back = &c->stencil[1];
    switch (pname) {
    case GL_ACTIVE_TEXTURE: INT1(GL_TEXTURE0 + c->unit);
    case GL_ALIASED_LINE_WIDTH_RANGE: return put(value, MGL_FLOAT, 2, 1, 1, 0, 0);
    case GL_ALIASED_POINT_SIZE_RANGE: return put(value, MGL_FLOAT, 2, 1, 511, 0, 0);
    case GL_RED_BITS:
    case GL_GREEN_BITS:
    case GL_BLUE_BITS: INT1(8);
    /* The surface drawn on has the buffers of its config. A framebuffer
     * object's are not worked out from what is attached to it (a
     * texture's format is not kept here): the most there can be is said. */
    case GL_ALPHA_BITS: INT1(c->framebuffer ? 8 : c->alpha_bits);
    case GL_DEPTH_BITS: INT1(c->framebuffer ? 24 : c->depth_bits);
    case GL_STENCIL_BITS: INT1(c->framebuffer ? 8 : c->stencil_bits);
    case GL_SUBPIXEL_BITS: INT1(4);
    case GL_ARRAY_BUFFER_BINDING: INT1(c->array_buffer);
    case GL_ELEMENT_ARRAY_BUFFER_BINDING: INT1(c->element_buffer);
    case GL_FRAMEBUFFER_BINDING: INT1(c->framebuffer);
    case GL_RENDERBUFFER_BINDING: INT1(c->renderbuffer);
    case GL_TEXTURE_BINDING_2D: INT1(c->texture_2d[c->unit]);
    case GL_TEXTURE_BINDING_CUBE_MAP: INT1(c->texture_cube[c->unit]);
    case GL_CURRENT_PROGRAM: INT1(c->program);
    case GL_BLEND: BOOL1(c->blend);
    case GL_CULL_FACE: BOOL1(c->cull_face);
    case GL_DEPTH_TEST: BOOL1(c->depth_test);
    case GL_DITHER: BOOL1(c->dither);
    case GL_POLYGON_OFFSET_FILL: BOOL1(c->polygon_offset);
    case GL_SAMPLE_ALPHA_TO_COVERAGE: BOOL1(c->alpha_to_coverage);
    case GL_SAMPLE_COVERAGE: BOOL1(c->sample_coverage);
    case GL_SCISSOR_TEST: BOOL1(c->scissor_test);
    case GL_STENCIL_TEST: BOOL1(c->stencil_test);
    case GL_BLEND_COLOR:
        return put(value, MGL_UNIT, 4, c->blend_color[0], c->blend_color[1], c->blend_color[2], c->blend_color[3]);
    case GL_BLEND_EQUATION_RGB: INT1(c->blend_rgb);
    case GL_BLEND_EQUATION_ALPHA: INT1(c->blend_alpha);
    case GL_BLEND_SRC_RGB: INT1(c->src_rgb);
    case GL_BLEND_DST_RGB: INT1(c->dst_rgb);
    case GL_BLEND_SRC_ALPHA: INT1(c->src_alpha);
    case GL_BLEND_DST_ALPHA: INT1(c->dst_alpha);
    case GL_COLOR_CLEAR_VALUE:
        return put(value, MGL_UNIT, 4, c->clear_color[0], c->clear_color[1], c->clear_color[2], c->clear_color[3]);
    case GL_COLOR_WRITEMASK:
        return put(value, MGL_BOOL, 4, c->color_mask[0], c->color_mask[1], c->color_mask[2], c->color_mask[3]);
    case GL_CULL_FACE_MODE: INT1(c->cull_mode);
    case GL_FRONT_FACE: INT1(c->front_face);
    case GL_DEPTH_CLEAR_VALUE: return put(value, MGL_UNIT, 1, c->clear_depth, 0, 0, 0);
    case GL_DEPTH_FUNC: INT1(c->depth_func);
    case GL_DEPTH_RANGE: return put(value, MGL_UNIT, 2, c->depth_range[0], c->depth_range[1], 0, 0);
    case GL_DEPTH_WRITEMASK: BOOL1(c->depth_mask);
    case GL_LINE_WIDTH: FLOAT1(c->line_width);
    case GL_POLYGON_OFFSET_FACTOR: FLOAT1(c->polygon_factor);
    case GL_POLYGON_OFFSET_UNITS: FLOAT1(c->polygon_units);
    case GL_SAMPLE_COVERAGE_VALUE: FLOAT1(c->coverage);
    case GL_SAMPLE_COVERAGE_INVERT: BOOL1(c->coverage_invert);
    case GL_SAMPLE_BUFFERS:
    case GL_SAMPLES: INT1(0);
    case GL_SCISSOR_BOX: return put(value, MGL_INT, 4, c->scissor[0], c->scissor[1], c->scissor[2], c->scissor[3]);
    case GL_VIEWPORT: return put(value, MGL_INT, 4, c->viewport[0], c->viewport[1], c->viewport[2], c->viewport[3]);
    case GL_STENCIL_CLEAR_VALUE: INT1(c->clear_stencil);
    case GL_STENCIL_FUNC: INT1(front->func);
    case GL_STENCIL_REF: INT1(front->ref);
    case GL_STENCIL_VALUE_MASK: INT1(front->mask);
    case GL_STENCIL_WRITEMASK: INT1(front->writemask);
    case GL_STENCIL_FAIL: INT1(front->fail);
    case GL_STENCIL_PASS_DEPTH_FAIL: INT1(front->zfail);
    case GL_STENCIL_PASS_DEPTH_PASS: INT1(front->zpass);
    case GL_STENCIL_BACK_FUNC: INT1(back->func);
    case GL_STENCIL_BACK_REF: INT1(back->ref);
    case GL_STENCIL_BACK_VALUE_MASK: INT1(back->mask);
    case GL_STENCIL_BACK_WRITEMASK: INT1(back->writemask);
    case GL_STENCIL_BACK_FAIL: INT1(back->fail);
    case GL_STENCIL_BACK_PASS_DEPTH_FAIL: INT1(back->zfail);
    case GL_STENCIL_BACK_PASS_DEPTH_PASS: INT1(back->zpass);
    case GL_PACK_ALIGNMENT: INT1(c->pack_alignment);
    case GL_UNPACK_ALIGNMENT: INT1(c->unpack_alignment);
    case GL_GENERATE_MIPMAP_HINT: INT1(c->mipmap_hint);
    case GL_FRAGMENT_SHADER_DERIVATIVE_HINT_OES: INT1(c->derivative_hint);
    case GL_IMPLEMENTATION_COLOR_READ_FORMAT: INT1(GL_RGBA);
    case GL_IMPLEMENTATION_COLOR_READ_TYPE: INT1(GL_UNSIGNED_BYTE);
    case GL_SHADER_COMPILER: BOOL1(true);
    case GL_MAX_TEXTURE_SIZE:
    case GL_MAX_CUBE_MAP_TEXTURE_SIZE:
    case GL_MAX_RENDERBUFFER_SIZE: INT1(MGL_MAX_SIZE);
    case GL_MAX_VIEWPORT_DIMS: return put(value, MGL_INT, 2, MGL_MAX_SIZE, MGL_MAX_SIZE, 0, 0);
    case GL_MAX_VERTEX_ATTRIBS: INT1(MGL_ATTRIBS);
    case GL_MAX_VERTEX_UNIFORM_VECTORS:
    case GL_MAX_FRAGMENT_UNIFORM_VECTORS: INT1(256);
    case GL_MAX_VARYING_VECTORS: INT1(15);
    case GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS:
    case GL_MAX_TEXTURE_IMAGE_UNITS:
    case GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS: INT1(MGL_UNITS);
    case GL_NUM_COMPRESSED_TEXTURE_FORMATS:
    case GL_NUM_SHADER_BINARY_FORMATS: INT1(0);
    /* None of either: nothing is written for these. */
    case GL_COMPRESSED_TEXTURE_FORMATS:
    case GL_SHADER_BINARY_FORMATS: return put(value, MGL_INT, 0, 0, 0, 0, 0);
    default: return false;
    }
#undef INT1
#undef BOOL1
#undef FLOAT1
}

/* ---- Tables ---- */

int mgl_pixel_bytes(uint32_t format, uint32_t type) {
    switch (type) {
    case GL_UNSIGNED_BYTE:
    case GL_UNSIGNED_SHORT_5_6_5:
    case GL_UNSIGNED_SHORT_4_4_4_4:
    case GL_UNSIGNED_SHORT_5_5_5_1:
    case GL_UNSIGNED_SHORT:
    case GL_UNSIGNED_INT:
    case GL_UNSIGNED_INT_24_8_OES: break;
    default: return -1;
    }
    switch (format) {
    case GL_RGBA: return type == GL_UNSIGNED_BYTE ? 4 : type == GL_UNSIGNED_SHORT_4_4_4_4 || type == GL_UNSIGNED_SHORT_5_5_5_1 ? 2 : 0;
    case GL_RGB: return type == GL_UNSIGNED_BYTE ? 3 : type == GL_UNSIGNED_SHORT_5_6_5 ? 2 : 0;
    case GL_LUMINANCE_ALPHA: return type == GL_UNSIGNED_BYTE ? 2 : 0;
    case GL_LUMINANCE:
    case GL_ALPHA: return type == GL_UNSIGNED_BYTE ? 1 : 0;
    case GL_DEPTH_COMPONENT: return type == GL_UNSIGNED_SHORT ? 2 : type == GL_UNSIGNED_INT ? 4 : 0;
    case GL_DEPTH_STENCIL_OES: return type == GL_UNSIGNED_INT_24_8_OES ? 4 : 0;
    default: return -1;
    }
}

int mgl_type_bytes(uint32_t type) {
    switch (type) {
    case GL_BYTE:
    case GL_UNSIGNED_BYTE: return 1;
    case GL_SHORT:
    case GL_UNSIGNED_SHORT: return 2;
    case GL_INT:
    case GL_UNSIGNED_INT:
    case GL_FLOAT:
    case GL_FIXED: return 4;
    default: return 0;
    }
}

int mgl_uniform_numbers(uint32_t type, bool *floats) {
    *floats = type == GL_FLOAT || (type >= GL_FLOAT_VEC2 && type <= GL_FLOAT_VEC4) || (type >= GL_FLOAT_MAT2 && type <= GL_FLOAT_MAT4);
    switch (type) {
    case GL_FLOAT:
    case GL_INT:
    case GL_BOOL:
    case GL_SAMPLER_2D:
    case GL_SAMPLER_CUBE: return 1;
    case GL_FLOAT_VEC2:
    case GL_INT_VEC2:
    case GL_BOOL_VEC2: return 2;
    case GL_FLOAT_VEC3:
    case GL_INT_VEC3:
    case GL_BOOL_VEC3: return 3;
    case GL_FLOAT_VEC4:
    case GL_INT_VEC4:
    case GL_BOOL_VEC4:
    case GL_FLOAT_MAT2: return 4;
    case GL_FLOAT_MAT3: return 9;
    case GL_FLOAT_MAT4: return 16;
    default: return 0;
    }
}
