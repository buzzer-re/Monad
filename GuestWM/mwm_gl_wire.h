/*
 * mwm_gl_wire.h — drawing by the Mac's GPU: how a program's OpenGL ES 2.0
 * calls travel from a Linux VM to the Mac. Apple passes no GPU to a Linux
 * guest, so a library of Monad's own stands in the guest where the
 * system's EGL and OpenGL ES libraries would (mgl_*.c, built as
 * libEGL.so.1 and libGLESv2.so.2), writes each call down as a command, and
 * MonadHost carries the commands out with Metal (Monad/GL). The window
 * manager is in the middle (mwm_gl.c): the Mac dials the guest, never the
 * other way, so the library connects to the window manager and the window
 * manager hands on what it says.
 *
 * Three stretches, all little-endian:
 *
 * 1. Library to window manager: a unix socket, MWM_GL_SOCKET in
 *    $XDG_RUNTIME_DIR, there only while MonadHost is connected for
 *    drawing (a VM whose owner did not turn GPU drawing on has no such
 *    socket, and programs then use the system's own libraries). The
 *    window manager first writes eight bytes: MWM_GL_MAGIC and the
 *    stream's number (1 and up, one stream a process). After that the
 *    socket carries commands one way and replies the other, as below.
 *
 * 2. Window manager to MonadHost: one connection (a vsock port only the
 *    Mac can dial) for all streams. Each way, frames:
 *
 *        u32 stream, u32 length, then `length` bytes of that stream
 *
 *    Stream 0 is no program's: its bytes are one u32 MWM_GL_OPENED or
 *    MWM_GL_CLOSED and one u32 stream number. The window manager says
 *    when a program connected and when it went; MonadHost says CLOSED
 *    when it ends a stream itself (its program said something that
 *    cannot be gone on from), and the window manager then hangs up on
 *    that program. A frame's length is at most MWM_GL_FRAME; a command
 *    may span frames.
 *
 * 3. Wayland, between the library and the window manager, for what a
 *    surface shows: the global "monad_gl" (version 1) with
 *
 *        request 0  destroy
 *        request 1  create_buffer(new_id wl_buffer, uint stream,
 *                                 uint surface, int width, int height)
 *
 *    The buffer has no pixels. Attached to a window's own wl_surface and
 *    committed, it says: this window is width × height pixels and shows
 *    what stream `stream` draws on its surface `surface`. The window
 *    manager tells MonadHost so with the window (mwm_ctl.h), and the Mac's
 *    window shows the pictures MonadHost draws. A commit with that buffer
 *    is otherwise a commit like another (frame callbacks, the window's
 *    geometry).
 *
 * Commands (library to MonadHost). Each is
 *
 *        u32 op, u32 size, then its arguments
 *
 * where `size` is the bytes of the whole command, these eight included, a
 * multiple of four, at most MWM_GL_COMMAND. Arguments are words: every
 * number of the call (an enum, an int, a float as its bits, a boolean as
 * 0 or 1, an offset) is one u32, in the order of the C prototype. Where a
 * call takes memory (pixels, vertices, a shader's text) the argument is
 * "data": a u32 count of bytes, then the bytes, then zeros up to a
 * multiple of four. A count of MWM_GL_NONE and no bytes stands for a NULL
 * pointer where OpenGL allows one.
 *
 * Unless said otherwise below, a command for an OpenGL ES 2.0 call has
 * the call's own arguments and nothing else. The exceptions:
 *
 *   - Names are the library's to choose: glGen* send nothing (a name
 *     comes to be when it is first bound, as in OpenGL), and
 *     CreateShader and CreateProgram carry the name the library chose:
 *     CreateShader(name, type), CreateProgram(name).
 *   - ShaderSource(shader, data): the strings joined.
 *   - BindAttribLocation(program, index, data name).
 *   - BufferData(target, size, usage, data): data of `size` bytes, or
 *     none. BufferSubData(target, offset, data).
 *   - TexImage2D(target, level, internalformat, width, height, border,
 *     format, type, data) and TexSubImage2D(target, level, xoffset,
 *     yoffset, width, height, format, type, data): the rows packed tight
 *     (as with GL_UNPACK_ALIGNMENT 1), first row first. The library
 *     applies the program's alignment; PixelStorei is not sent.
 *   - Uniform1f..4f, Uniform1i..4i: location and the values.
 *     Uniform1fv..4fv, Uniform1iv..4iv: (location, count, data).
 *     UniformMatrix2fv..4fv: (location, count, data); transpose is always
 *     false in OpenGL ES 2.0 and is not sent.
 *   - VertexAttrib1f..4f and their v forms all go as
 *     VertexAttrib4f(index, x, y, z, w).
 *   - VertexAttribPointer(index, size, type, normalized, stride, offset)
 *     is sent when a buffer is bound to GL_ARRAY_BUFFER (MonadHost takes
 *     the buffer bound then, as OpenGL does). With none bound the pointer
 *     is the program's memory: the library keeps it, and before each draw
 *     sends, for every such array that is enabled,
 *     ClientArray(index, size, type, normalized, first, data): the
 *     elements of vertices `first` and up, packed tight, as many as the
 *     draw uses. It holds for that one draw.
 *   - DrawElements(mode, count, type, offset) with a buffer bound to
 *     GL_ELEMENT_ARRAY_BUFFER; else DrawElementsClient(mode, count, type,
 *     data) with the indices themselves.
 *   - DeleteBuffers, DeleteTextures, DeleteFramebuffers,
 *     DeleteRenderbuffers: (count, data of count names).
 *   - Calls that only ask (glGet*, glIs*, glGetString), glHint,
 *     glPixelStorei, glReleaseShaderCompiler, glValidateProgram and
 *     glFlush are the library's own and are never sent; glShaderBinary and
 *     the compressed texture calls are errors there (no format is offered).
 *
 * Commands with an answer. The library sends everything it has written,
 * then reads one reply: u32 length (a multiple of four), then that many
 * bytes:
 *
 *   GetError()                 -> u32 error
 *   Finish()                   -> nothing (length 0)
 *   CheckFramebufferStatus(target) -> u32 status
 *   CompileShader(shader)      -> u32 compiled (0 or 1), data log
 *   LinkProgram(program)       -> u32 linked (0 or 1), data log,
 *                                 u32 attributes, then for each:
 *                                   u32 location, u32 type, u32 size, data name
 *                                 u32 uniforms, then for each:
 *                                   u32 location, u32 type, u32 size, data name
 *                                 (a uniform array's name ends "[0]" and its
 *                                 element i is at location + i; what the
 *                                 library answers glGetActive*, glGet*Location
 *                                 and glGetProgramiv from)
 *   ReadPixels(x, y, width, height, format, type)
 *                              -> data: the rows packed tight, bottom row
 *                                 first; GL_RGBA with GL_UNSIGNED_BYTE only
 *   GetUniform(program, location) -> u32 type, data (its floats or ints)
 *
 * A ReadPixels or GetUniform that MonadHost has an OpenGL error for
 * instead answers with no data (ReadPixels: length 0; GetUniform: type
 * 0, data of no bytes): the library writes nothing to the program's
 * memory, and the error is there for glGetError. An answer of any other
 * size than the one asked for ends the stream. A string in a command (a
 * shader's text, a name) has no 0 at its end.
 *
 * Commands of the library's own (EGL's side of things). Contexts and
 * surfaces are named by the library, 1 and up; 0 is none:
 *
 *   ContextCreate(context, share)     share: a context whose objects it shares, or 0
 *   ContextDestroy(context)
 *   SurfaceCreate(surface, width, height, alpha, depth, stencil)
 *                                     what a window or a pbuffer draws on, as
 *                                     its EGL config has it: each of the three
 *                                     is 1 when the surface has such a buffer
 *                                     and 0 when not. Without alpha every
 *                                     pixel's alpha is 1 whatever is drawn
 *                                     (read back, blended with, and shown: the
 *                                     window is opaque); without depth or
 *                                     stencil that test passes and nothing is
 *                                     written, as OpenGL has it
 *   SurfaceResize(surface, width, height)
 *   SurfaceDestroy(surface)
 *   MakeCurrent(context, draw, read)  the calls after it are that context's;
 *                                     (0, 0, 0): no context is current (the
 *                                     thread that had it let go of it)
 *   Swap(surface)                     the picture is done: MonadHost shows it.
 *                                     Answered with nothing (length 0) once
 *                                     the Mac's GPU has drawn it. The library
 *                                     goes on without reading that answer, and
 *                                     reads it before it sends the next Swap
 *                                     or reads any other answer: so a program
 *                                     is never more than one picture ahead of
 *                                     the Mac, however fast it draws (a driver
 *                                     that queued without end would let a
 *                                     benchmark count pictures nobody drew)
 *
 * A stream has one current context at a time: the library, whose callers
 * may be several threads with a context each, sends MakeCurrent whenever
 * the next call is another context's than the last one's.
 *
 * MonadHost reads all of this as hostile: a command that is not as
 * described sets GL_INVALID_OPERATION or ends the stream; nothing a
 * stream says can touch another VM's drawing or anything outside the
 * pictures it draws.
 */
#ifndef MWM_GL_WIRE_H
#define MWM_GL_WIRE_H

#include <stdint.h>

#define MWM_GL_SOCKET "monad-gl"
#define MWM_GL_MAGIC 0x314c474du /* "MGL1" */
#define MWM_GL_NONE 0xffffffffu

enum {
    /* The largest frame between the window manager and MonadHost. */
    MWM_GL_FRAME = 1 << 20,
    /* The largest command: a texture of 4096 × 4096 pixels and its words. */
    MWM_GL_COMMAND = (64 << 20) + 4096,
    /* The largest reply. */
    MWM_GL_REPLY = (64 << 20) + 4096,
    /* Streams at once (programs drawing), in one VM. */
    MWM_GL_STREAMS = 32,
    MWM_GL_OPENED = 1,
    MWM_GL_CLOSED = 2,
};

/* The commands. The numbers are the protocol: never changed, only added to. */
enum {
    MGL_CONTEXT_CREATE = 1,
    MGL_CONTEXT_DESTROY = 2,
    MGL_SURFACE_CREATE = 3,
    MGL_SURFACE_RESIZE = 4,
    MGL_SURFACE_DESTROY = 5,
    MGL_MAKE_CURRENT = 6,
    MGL_SWAP = 7, /* answered, read late: see above */

    MGL_ACTIVE_TEXTURE = 16,
    MGL_ATTACH_SHADER = 17,
    MGL_BIND_ATTRIB_LOCATION = 18,
    MGL_BIND_BUFFER = 19,
    MGL_BIND_FRAMEBUFFER = 20,
    MGL_BIND_RENDERBUFFER = 21,
    MGL_BIND_TEXTURE = 22,
    MGL_BLEND_COLOR = 23,
    MGL_BLEND_EQUATION = 24,
    MGL_BLEND_EQUATION_SEPARATE = 25,
    MGL_BLEND_FUNC = 26,
    MGL_BLEND_FUNC_SEPARATE = 27,
    MGL_BUFFER_DATA = 28,
    MGL_BUFFER_SUB_DATA = 29,
    MGL_CHECK_FRAMEBUFFER_STATUS = 30, /* answered */
    MGL_CLEAR = 31,
    MGL_CLEAR_COLOR = 32,
    MGL_CLEAR_DEPTHF = 33,
    MGL_CLEAR_STENCIL = 34,
    MGL_COLOR_MASK = 35,
    MGL_COMPILE_SHADER = 36, /* answered */
    MGL_COPY_TEX_IMAGE_2D = 37,
    MGL_COPY_TEX_SUB_IMAGE_2D = 38,
    MGL_CREATE_PROGRAM = 39,
    MGL_CREATE_SHADER = 40,
    MGL_CULL_FACE = 41,
    MGL_DELETE_BUFFERS = 42,
    MGL_DELETE_FRAMEBUFFERS = 43,
    MGL_DELETE_PROGRAM = 44,
    MGL_DELETE_RENDERBUFFERS = 45,
    MGL_DELETE_SHADER = 46,
    MGL_DELETE_TEXTURES = 47,
    MGL_DEPTH_FUNC = 48,
    MGL_DEPTH_MASK = 49,
    MGL_DEPTH_RANGEF = 50,
    MGL_DETACH_SHADER = 51,
    MGL_DISABLE = 52,
    MGL_DISABLE_VERTEX_ATTRIB_ARRAY = 53,
    MGL_DRAW_ARRAYS = 54,
    MGL_DRAW_ELEMENTS = 55,
    MGL_DRAW_ELEMENTS_CLIENT = 56,
    MGL_CLIENT_ARRAY = 57,
    MGL_ENABLE = 58,
    MGL_ENABLE_VERTEX_ATTRIB_ARRAY = 59,
    MGL_FINISH = 60, /* answered */
    MGL_FRAMEBUFFER_RENDERBUFFER = 61,
    MGL_FRAMEBUFFER_TEXTURE_2D = 62,
    MGL_FRONT_FACE = 63,
    MGL_GENERATE_MIPMAP = 64,
    MGL_GET_ERROR = 65, /* answered */
    MGL_GET_UNIFORM = 66, /* answered */
    MGL_LINE_WIDTH = 67,
    MGL_LINK_PROGRAM = 68, /* answered */
    MGL_POLYGON_OFFSET = 69,
    MGL_READ_PIXELS = 70, /* answered */
    MGL_RENDERBUFFER_STORAGE = 71,
    MGL_SAMPLE_COVERAGE = 72,
    MGL_SCISSOR = 73,
    MGL_SHADER_SOURCE = 74,
    MGL_STENCIL_FUNC = 75,
    MGL_STENCIL_FUNC_SEPARATE = 76,
    MGL_STENCIL_MASK = 77,
    MGL_STENCIL_MASK_SEPARATE = 78,
    MGL_STENCIL_OP = 79,
    MGL_STENCIL_OP_SEPARATE = 80,
    MGL_TEX_IMAGE_2D = 81,
    MGL_TEX_PARAMETERF = 82,
    MGL_TEX_PARAMETERI = 83,
    MGL_TEX_SUB_IMAGE_2D = 84,
    MGL_UNIFORM_1F = 85,
    MGL_UNIFORM_2F = 86,
    MGL_UNIFORM_3F = 87,
    MGL_UNIFORM_4F = 88,
    MGL_UNIFORM_1I = 89,
    MGL_UNIFORM_2I = 90,
    MGL_UNIFORM_3I = 91,
    MGL_UNIFORM_4I = 92,
    MGL_UNIFORM_1FV = 93,
    MGL_UNIFORM_2FV = 94,
    MGL_UNIFORM_3FV = 95,
    MGL_UNIFORM_4FV = 96,
    MGL_UNIFORM_1IV = 97,
    MGL_UNIFORM_2IV = 98,
    MGL_UNIFORM_3IV = 99,
    MGL_UNIFORM_4IV = 100,
    MGL_UNIFORM_MATRIX_2FV = 101,
    MGL_UNIFORM_MATRIX_3FV = 102,
    MGL_UNIFORM_MATRIX_4FV = 103,
    MGL_USE_PROGRAM = 104,
    MGL_VERTEX_ATTRIB_4F = 105,
    MGL_VERTEX_ATTRIB_POINTER = 106,
    MGL_VIEWPORT = 107,
    MGL_OP_LAST = MGL_VIEWPORT,
};

#endif
