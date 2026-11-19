/*
 * mgl_api.h — EGL 1.4 and OpenGL ES 2.0 as Monad's library offers them
 * (mgl_*.c, built in a Linux VM as libEGL.so.1 and libGLESv2.so.2): the
 * types, the numbers and the entry points, written from the two
 * specifications. A VM that builds the library has a C compiler and
 * libc's headers and may have nothing else, so nothing here comes from
 * the system's EGL, OpenGL ES or Wayland headers. A program is compiled
 * against its distribution's headers and meets this library only when it
 * runs: the types below are the sizes and the names the Linux ABI gives
 * them.
 */
#ifndef MGL_API_H
#define MGL_API_H

#include <stdint.h>

/* An entry point: one of the few names the library shows (it is built
 * with -fvisibility=hidden). */
#define MGL_API __attribute__((visibility("default")))

/* OpenGL ES 2.0. */
typedef void GLvoid;
typedef char GLchar;
typedef unsigned int GLenum;
typedef unsigned char GLboolean;
typedef unsigned int GLbitfield;
typedef signed char GLbyte;
typedef short GLshort;
typedef int GLint;
typedef int GLsizei;
typedef unsigned char GLubyte;
typedef unsigned short GLushort;
typedef unsigned int GLuint;
typedef float GLfloat;
typedef float GLclampf;
typedef int32_t GLfixed;
typedef intptr_t GLintptr;
typedef intptr_t GLsizeiptr;

#define GL_ES_VERSION_2_0 1
#define GL_DEPTH_BUFFER_BIT 0x00000100
#define GL_STENCIL_BUFFER_BIT 0x00000400
#define GL_COLOR_BUFFER_BIT 0x00004000
#define GL_FALSE 0
#define GL_TRUE 1
#define GL_POINTS 0x0000
#define GL_LINES 0x0001
#define GL_LINE_LOOP 0x0002
#define GL_LINE_STRIP 0x0003
#define GL_TRIANGLES 0x0004
#define GL_TRIANGLE_STRIP 0x0005
#define GL_TRIANGLE_FAN 0x0006
#define GL_ZERO 0
#define GL_ONE 1
#define GL_SRC_COLOR 0x0300
#define GL_ONE_MINUS_SRC_COLOR 0x0301
#define GL_SRC_ALPHA 0x0302
#define GL_ONE_MINUS_SRC_ALPHA 0x0303
#define GL_DST_ALPHA 0x0304
#define GL_ONE_MINUS_DST_ALPHA 0x0305
#define GL_DST_COLOR 0x0306
#define GL_ONE_MINUS_DST_COLOR 0x0307
#define GL_SRC_ALPHA_SATURATE 0x0308
#define GL_FUNC_ADD 0x8006
#define GL_BLEND_EQUATION 0x8009
#define GL_BLEND_EQUATION_RGB 0x8009
#define GL_BLEND_EQUATION_ALPHA 0x883D
#define GL_FUNC_SUBTRACT 0x800A
#define GL_FUNC_REVERSE_SUBTRACT 0x800B
#define GL_BLEND_DST_RGB 0x80C8
#define GL_BLEND_SRC_RGB 0x80C9
#define GL_BLEND_DST_ALPHA 0x80CA
#define GL_BLEND_SRC_ALPHA 0x80CB
#define GL_CONSTANT_COLOR 0x8001
#define GL_ONE_MINUS_CONSTANT_COLOR 0x8002
#define GL_CONSTANT_ALPHA 0x8003
#define GL_ONE_MINUS_CONSTANT_ALPHA 0x8004
#define GL_BLEND_COLOR 0x8005
#define GL_ARRAY_BUFFER 0x8892
#define GL_ELEMENT_ARRAY_BUFFER 0x8893
#define GL_ARRAY_BUFFER_BINDING 0x8894
#define GL_ELEMENT_ARRAY_BUFFER_BINDING 0x8895
#define GL_STREAM_DRAW 0x88E0
#define GL_STATIC_DRAW 0x88E4
#define GL_DYNAMIC_DRAW 0x88E8
#define GL_BUFFER_SIZE 0x8764
#define GL_BUFFER_USAGE 0x8765
#define GL_CURRENT_VERTEX_ATTRIB 0x8626
#define GL_FRONT 0x0404
#define GL_BACK 0x0405
#define GL_FRONT_AND_BACK 0x0408
#define GL_TEXTURE_2D 0x0DE1
#define GL_CULL_FACE 0x0B44
#define GL_BLEND 0x0BE2
#define GL_DITHER 0x0BD0
#define GL_STENCIL_TEST 0x0B90
#define GL_DEPTH_TEST 0x0B71
#define GL_SCISSOR_TEST 0x0C11
#define GL_POLYGON_OFFSET_FILL 0x8037
#define GL_SAMPLE_ALPHA_TO_COVERAGE 0x809E
#define GL_SAMPLE_COVERAGE 0x80A0
#define GL_NO_ERROR 0
#define GL_INVALID_ENUM 0x0500
#define GL_INVALID_VALUE 0x0501
#define GL_INVALID_OPERATION 0x0502
#define GL_OUT_OF_MEMORY 0x0505
#define GL_INVALID_FRAMEBUFFER_OPERATION 0x0506
#define GL_CW 0x0900
#define GL_CCW 0x0901
#define GL_LINE_WIDTH 0x0B21
#define GL_ALIASED_POINT_SIZE_RANGE 0x846D
#define GL_ALIASED_LINE_WIDTH_RANGE 0x846E
#define GL_CULL_FACE_MODE 0x0B45
#define GL_FRONT_FACE 0x0B46
#define GL_DEPTH_RANGE 0x0B70
#define GL_DEPTH_WRITEMASK 0x0B72
#define GL_DEPTH_CLEAR_VALUE 0x0B73
#define GL_DEPTH_FUNC 0x0B74
#define GL_STENCIL_CLEAR_VALUE 0x0B91
#define GL_STENCIL_FUNC 0x0B92
#define GL_STENCIL_FAIL 0x0B94
#define GL_STENCIL_PASS_DEPTH_FAIL 0x0B95
#define GL_STENCIL_PASS_DEPTH_PASS 0x0B96
#define GL_STENCIL_REF 0x0B97
#define GL_STENCIL_VALUE_MASK 0x0B93
#define GL_STENCIL_WRITEMASK 0x0B98
#define GL_STENCIL_BACK_FUNC 0x8800
#define GL_STENCIL_BACK_FAIL 0x8801
#define GL_STENCIL_BACK_PASS_DEPTH_FAIL 0x8802
#define GL_STENCIL_BACK_PASS_DEPTH_PASS 0x8803
#define GL_STENCIL_BACK_REF 0x8CA3
#define GL_STENCIL_BACK_VALUE_MASK 0x8CA4
#define GL_STENCIL_BACK_WRITEMASK 0x8CA5
#define GL_VIEWPORT 0x0BA2
#define GL_SCISSOR_BOX 0x0C10
#define GL_COLOR_CLEAR_VALUE 0x0C22
#define GL_COLOR_WRITEMASK 0x0C23
#define GL_UNPACK_ALIGNMENT 0x0CF5
#define GL_PACK_ALIGNMENT 0x0D05
#define GL_MAX_TEXTURE_SIZE 0x0D33
#define GL_MAX_VIEWPORT_DIMS 0x0D3A
#define GL_SUBPIXEL_BITS 0x0D50
#define GL_RED_BITS 0x0D52
#define GL_GREEN_BITS 0x0D53
#define GL_BLUE_BITS 0x0D54
#define GL_ALPHA_BITS 0x0D55
#define GL_DEPTH_BITS 0x0D56
#define GL_STENCIL_BITS 0x0D57
#define GL_POLYGON_OFFSET_UNITS 0x2A00
#define GL_POLYGON_OFFSET_FACTOR 0x8038
#define GL_TEXTURE_BINDING_2D 0x8069
#define GL_SAMPLE_BUFFERS 0x80A8
#define GL_SAMPLES 0x80A9
#define GL_SAMPLE_COVERAGE_VALUE 0x80AA
#define GL_SAMPLE_COVERAGE_INVERT 0x80AB
#define GL_NUM_COMPRESSED_TEXTURE_FORMATS 0x86A2
#define GL_COMPRESSED_TEXTURE_FORMATS 0x86A3
#define GL_DONT_CARE 0x1100
#define GL_FASTEST 0x1101
#define GL_NICEST 0x1102
#define GL_GENERATE_MIPMAP_HINT 0x8192
#define GL_FRAGMENT_SHADER_DERIVATIVE_HINT_OES 0x8B8B
#define GL_BYTE 0x1400
#define GL_UNSIGNED_BYTE 0x1401
#define GL_SHORT 0x1402
#define GL_UNSIGNED_SHORT 0x1403
#define GL_INT 0x1404
#define GL_UNSIGNED_INT 0x1405
#define GL_FLOAT 0x1406
#define GL_FIXED 0x140C
#define GL_DEPTH_COMPONENT 0x1902
#define GL_ALPHA 0x1906
#define GL_RGB 0x1907
#define GL_RGBA 0x1908
#define GL_LUMINANCE 0x1909
#define GL_LUMINANCE_ALPHA 0x190A
#define GL_UNSIGNED_SHORT_4_4_4_4 0x8033
#define GL_UNSIGNED_SHORT_5_5_5_1 0x8034
#define GL_UNSIGNED_SHORT_5_6_5 0x8363
#define GL_FRAGMENT_SHADER 0x8B30
#define GL_VERTEX_SHADER 0x8B31
#define GL_MAX_VERTEX_ATTRIBS 0x8869
#define GL_MAX_VERTEX_UNIFORM_VECTORS 0x8DFB
#define GL_MAX_VARYING_VECTORS 0x8DFC
#define GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS 0x8B4D
#define GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS 0x8B4C
#define GL_MAX_TEXTURE_IMAGE_UNITS 0x8872
#define GL_MAX_FRAGMENT_UNIFORM_VECTORS 0x8DFD
#define GL_SHADER_TYPE 0x8B4F
#define GL_DELETE_STATUS 0x8B80
#define GL_LINK_STATUS 0x8B82
#define GL_VALIDATE_STATUS 0x8B83
#define GL_ATTACHED_SHADERS 0x8B85
#define GL_ACTIVE_UNIFORMS 0x8B86
#define GL_ACTIVE_UNIFORM_MAX_LENGTH 0x8B87
#define GL_ACTIVE_ATTRIBUTES 0x8B89
#define GL_ACTIVE_ATTRIBUTE_MAX_LENGTH 0x8B8A
#define GL_SHADING_LANGUAGE_VERSION 0x8B8C
#define GL_CURRENT_PROGRAM 0x8B8D
#define GL_NEVER 0x0200
#define GL_LESS 0x0201
#define GL_EQUAL 0x0202
#define GL_LEQUAL 0x0203
#define GL_GREATER 0x0204
#define GL_NOTEQUAL 0x0205
#define GL_GEQUAL 0x0206
#define GL_ALWAYS 0x0207
#define GL_KEEP 0x1E00
#define GL_REPLACE 0x1E01
#define GL_INCR 0x1E02
#define GL_DECR 0x1E03
#define GL_INVERT 0x150A
#define GL_INCR_WRAP 0x8507
#define GL_DECR_WRAP 0x8508
#define GL_VENDOR 0x1F00
#define GL_RENDERER 0x1F01
#define GL_VERSION 0x1F02
#define GL_EXTENSIONS 0x1F03
#define GL_NEAREST 0x2600
#define GL_LINEAR 0x2601
#define GL_NEAREST_MIPMAP_NEAREST 0x2700
#define GL_LINEAR_MIPMAP_NEAREST 0x2701
#define GL_NEAREST_MIPMAP_LINEAR 0x2702
#define GL_LINEAR_MIPMAP_LINEAR 0x2703
#define GL_TEXTURE_MAG_FILTER 0x2800
#define GL_TEXTURE_MIN_FILTER 0x2801
#define GL_TEXTURE_WRAP_S 0x2802
#define GL_TEXTURE_WRAP_T 0x2803
#define GL_TEXTURE 0x1702
#define GL_TEXTURE_CUBE_MAP 0x8513
#define GL_TEXTURE_BINDING_CUBE_MAP 0x8514
#define GL_TEXTURE_CUBE_MAP_POSITIVE_X 0x8515
#define GL_TEXTURE_CUBE_MAP_NEGATIVE_X 0x8516
#define GL_TEXTURE_CUBE_MAP_POSITIVE_Y 0x8517
#define GL_TEXTURE_CUBE_MAP_NEGATIVE_Y 0x8518
#define GL_TEXTURE_CUBE_MAP_POSITIVE_Z 0x8519
#define GL_TEXTURE_CUBE_MAP_NEGATIVE_Z 0x851A
#define GL_MAX_CUBE_MAP_TEXTURE_SIZE 0x851C
#define GL_TEXTURE0 0x84C0
#define GL_TEXTURE1 0x84C1
#define GL_TEXTURE2 0x84C2
#define GL_TEXTURE3 0x84C3
#define GL_TEXTURE4 0x84C4
#define GL_TEXTURE5 0x84C5
#define GL_TEXTURE6 0x84C6
#define GL_TEXTURE7 0x84C7
#define GL_TEXTURE8 0x84C8
#define GL_TEXTURE9 0x84C9
#define GL_TEXTURE10 0x84CA
#define GL_TEXTURE11 0x84CB
#define GL_TEXTURE12 0x84CC
#define GL_TEXTURE13 0x84CD
#define GL_TEXTURE14 0x84CE
#define GL_TEXTURE15 0x84CF
#define GL_TEXTURE16 0x84D0
#define GL_TEXTURE17 0x84D1
#define GL_TEXTURE18 0x84D2
#define GL_TEXTURE19 0x84D3
#define GL_TEXTURE20 0x84D4
#define GL_TEXTURE21 0x84D5
#define GL_TEXTURE22 0x84D6
#define GL_TEXTURE23 0x84D7
#define GL_TEXTURE24 0x84D8
#define GL_TEXTURE25 0x84D9
#define GL_TEXTURE26 0x84DA
#define GL_TEXTURE27 0x84DB
#define GL_TEXTURE28 0x84DC
#define GL_TEXTURE29 0x84DD
#define GL_TEXTURE30 0x84DE
#define GL_TEXTURE31 0x84DF
#define GL_ACTIVE_TEXTURE 0x84E0
#define GL_REPEAT 0x2901
#define GL_CLAMP_TO_EDGE 0x812F
#define GL_MIRRORED_REPEAT 0x8370
#define GL_FLOAT_VEC2 0x8B50
#define GL_FLOAT_VEC3 0x8B51
#define GL_FLOAT_VEC4 0x8B52
#define GL_INT_VEC2 0x8B53
#define GL_INT_VEC3 0x8B54
#define GL_INT_VEC4 0x8B55
#define GL_BOOL 0x8B56
#define GL_BOOL_VEC2 0x8B57
#define GL_BOOL_VEC3 0x8B58
#define GL_BOOL_VEC4 0x8B59
#define GL_FLOAT_MAT2 0x8B5A
#define GL_FLOAT_MAT3 0x8B5B
#define GL_FLOAT_MAT4 0x8B5C
#define GL_SAMPLER_2D 0x8B5E
#define GL_SAMPLER_CUBE 0x8B60
#define GL_VERTEX_ATTRIB_ARRAY_ENABLED 0x8622
#define GL_VERTEX_ATTRIB_ARRAY_SIZE 0x8623
#define GL_VERTEX_ATTRIB_ARRAY_STRIDE 0x8624
#define GL_VERTEX_ATTRIB_ARRAY_TYPE 0x8625
#define GL_VERTEX_ATTRIB_ARRAY_NORMALIZED 0x886A
#define GL_VERTEX_ATTRIB_ARRAY_POINTER 0x8645
#define GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING 0x889F
#define GL_IMPLEMENTATION_COLOR_READ_TYPE 0x8B9A
#define GL_IMPLEMENTATION_COLOR_READ_FORMAT 0x8B9B
#define GL_COMPILE_STATUS 0x8B81
#define GL_INFO_LOG_LENGTH 0x8B84
#define GL_SHADER_SOURCE_LENGTH 0x8B88
#define GL_SHADER_COMPILER 0x8DFA
#define GL_SHADER_BINARY_FORMATS 0x8DF8
#define GL_NUM_SHADER_BINARY_FORMATS 0x8DF9
#define GL_LOW_FLOAT 0x8DF0
#define GL_MEDIUM_FLOAT 0x8DF1
#define GL_HIGH_FLOAT 0x8DF2
#define GL_LOW_INT 0x8DF3
#define GL_MEDIUM_INT 0x8DF4
#define GL_HIGH_INT 0x8DF5
#define GL_FRAMEBUFFER 0x8D40
#define GL_RENDERBUFFER 0x8D41
#define GL_RGBA4 0x8056
#define GL_RGB5_A1 0x8057
#define GL_RGB565 0x8D62
#define GL_DEPTH_COMPONENT16 0x81A5
#define GL_STENCIL_INDEX8 0x8D48
#define GL_RENDERBUFFER_WIDTH 0x8D42
#define GL_RENDERBUFFER_HEIGHT 0x8D43
#define GL_RENDERBUFFER_INTERNAL_FORMAT 0x8D44
#define GL_RENDERBUFFER_RED_SIZE 0x8D50
#define GL_RENDERBUFFER_GREEN_SIZE 0x8D51
#define GL_RENDERBUFFER_BLUE_SIZE 0x8D52
#define GL_RENDERBUFFER_ALPHA_SIZE 0x8D53
#define GL_RENDERBUFFER_DEPTH_SIZE 0x8D54
#define GL_RENDERBUFFER_STENCIL_SIZE 0x8D55
#define GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE 0x8CD0
#define GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME 0x8CD1
#define GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL 0x8CD2
#define GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE 0x8CD3
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_DEPTH_ATTACHMENT 0x8D00
#define GL_STENCIL_ATTACHMENT 0x8D20
#define GL_NONE 0
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT 0x8CD6
#define GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT 0x8CD7
#define GL_FRAMEBUFFER_INCOMPLETE_DIMENSIONS 0x8CD9
#define GL_FRAMEBUFFER_UNSUPPORTED 0x8CDD
#define GL_FRAMEBUFFER_BINDING 0x8CA6
#define GL_RENDERBUFFER_BINDING 0x8CA7
#define GL_MAX_RENDERBUFFER_SIZE 0x84E8
/* Of the extensions glGetString names. */
#define GL_DEPTH_COMPONENT24_OES 0x81A6
#define GL_DEPTH_STENCIL_OES 0x84F9
#define GL_UNSIGNED_INT_24_8_OES 0x84FA
#define GL_DEPTH24_STENCIL8_OES 0x88F0
#define GL_RGB8_OES 0x8051
#define GL_RGBA8_OES 0x8058

MGL_API void glActiveTexture(GLenum texture);
MGL_API void glAttachShader(GLuint program, GLuint shader);
MGL_API void glBindAttribLocation(GLuint program, GLuint indx, const GLchar *name);
MGL_API void glBindBuffer(GLenum target, GLuint buffer);
MGL_API void glBindFramebuffer(GLenum target, GLuint framebuffer);
MGL_API void glBindRenderbuffer(GLenum target, GLuint renderbuffer);
MGL_API void glBindTexture(GLenum target, GLuint texture);
MGL_API void glBlendColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha);
MGL_API void glBlendEquation(GLenum mode);
MGL_API void glBlendEquationSeparate(GLenum modeRGB, GLenum modeAlpha);
MGL_API void glBlendFunc(GLenum sfactor, GLenum dfactor);
MGL_API void glBlendFuncSeparate(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha);
MGL_API void glBufferData(GLenum target, GLsizeiptr size, const void *data, GLenum usage);
MGL_API void glBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void *data);
MGL_API GLenum glCheckFramebufferStatus(GLenum target);
MGL_API void glClear(GLbitfield mask);
MGL_API void glClearColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha);
MGL_API void glClearDepthf(GLfloat depth);
MGL_API void glClearStencil(GLint s);
MGL_API void glColorMask(GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha);
MGL_API void glCompileShader(GLuint shader);
MGL_API void glCompressedTexImage2D(GLenum target, GLint level, GLenum internalformat, GLsizei width, GLsizei height, GLint border, GLsizei imageSize, const void *data);
MGL_API void glCompressedTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLsizei imageSize, const void *data);
MGL_API void glCopyTexImage2D(GLenum target, GLint level, GLenum internalformat, GLint x, GLint y, GLsizei width, GLsizei height, GLint border);
MGL_API void glCopyTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint x, GLint y, GLsizei width, GLsizei height);
MGL_API GLuint glCreateProgram(void);
MGL_API GLuint glCreateShader(GLenum type);
MGL_API void glCullFace(GLenum mode);
MGL_API void glDeleteBuffers(GLsizei n, const GLuint *buffers);
MGL_API void glDeleteFramebuffers(GLsizei n, const GLuint *framebuffers);
MGL_API void glDeleteProgram(GLuint program);
MGL_API void glDeleteRenderbuffers(GLsizei n, const GLuint *renderbuffers);
MGL_API void glDeleteShader(GLuint shader);
MGL_API void glDeleteTextures(GLsizei n, const GLuint *textures);
MGL_API void glDepthFunc(GLenum func);
MGL_API void glDepthMask(GLboolean flag);
MGL_API void glDepthRangef(GLfloat zNear, GLfloat zFar);
MGL_API void glDetachShader(GLuint program, GLuint shader);
MGL_API void glDisable(GLenum cap);
MGL_API void glDisableVertexAttribArray(GLuint indx);
MGL_API void glDrawArrays(GLenum mode, GLint first, GLsizei count);
MGL_API void glDrawElements(GLenum mode, GLsizei count, GLenum type, const void *indices);
MGL_API void glEnable(GLenum cap);
MGL_API void glEnableVertexAttribArray(GLuint indx);
MGL_API void glFinish(void);
MGL_API void glFlush(void);
MGL_API void glFramebufferRenderbuffer(GLenum target, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer);
MGL_API void glFramebufferTexture2D(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level);
MGL_API void glFrontFace(GLenum mode);
MGL_API void glGenBuffers(GLsizei n, GLuint *buffers);
MGL_API void glGenerateMipmap(GLenum target);
MGL_API void glGenFramebuffers(GLsizei n, GLuint *framebuffers);
MGL_API void glGenRenderbuffers(GLsizei n, GLuint *renderbuffers);
MGL_API void glGenTextures(GLsizei n, GLuint *textures);
MGL_API void glGetActiveAttrib(GLuint program, GLuint indx, GLsizei bufSize, GLsizei *length, GLint *size, GLenum *type, GLchar *name);
MGL_API void glGetActiveUniform(GLuint program, GLuint indx, GLsizei bufSize, GLsizei *length, GLint *size, GLenum *type, GLchar *name);
MGL_API void glGetAttachedShaders(GLuint program, GLsizei maxCount, GLsizei *count, GLuint *shaders);
MGL_API GLint glGetAttribLocation(GLuint program, const GLchar *name);
MGL_API void glGetBooleanv(GLenum pname, GLboolean *params);
MGL_API void glGetBufferParameteriv(GLenum target, GLenum pname, GLint *params);
MGL_API GLenum glGetError(void);
MGL_API void glGetFloatv(GLenum pname, GLfloat *params);
MGL_API void glGetFramebufferAttachmentParameteriv(GLenum target, GLenum attachment, GLenum pname, GLint *params);
MGL_API void glGetIntegerv(GLenum pname, GLint *params);
MGL_API void glGetProgramiv(GLuint program, GLenum pname, GLint *params);
MGL_API void glGetProgramInfoLog(GLuint program, GLsizei bufSize, GLsizei *length, GLchar *infoLog);
MGL_API void glGetRenderbufferParameteriv(GLenum target, GLenum pname, GLint *params);
MGL_API void glGetShaderiv(GLuint shader, GLenum pname, GLint *params);
MGL_API void glGetShaderInfoLog(GLuint shader, GLsizei bufSize, GLsizei *length, GLchar *infoLog);
MGL_API void glGetShaderPrecisionFormat(GLenum shadertype, GLenum precisiontype, GLint *range, GLint *precision);
MGL_API void glGetShaderSource(GLuint shader, GLsizei bufSize, GLsizei *length, GLchar *source);
MGL_API const GLubyte *glGetString(GLenum name);
MGL_API void glGetTexParameterfv(GLenum target, GLenum pname, GLfloat *params);
MGL_API void glGetTexParameteriv(GLenum target, GLenum pname, GLint *params);
MGL_API void glGetUniformfv(GLuint program, GLint location, GLfloat *params);
MGL_API void glGetUniformiv(GLuint program, GLint location, GLint *params);
MGL_API GLint glGetUniformLocation(GLuint program, const GLchar *name);
MGL_API void glGetVertexAttribfv(GLuint indx, GLenum pname, GLfloat *params);
MGL_API void glGetVertexAttribiv(GLuint indx, GLenum pname, GLint *params);
MGL_API void glGetVertexAttribPointerv(GLuint indx, GLenum pname, void **pointer);
MGL_API void glHint(GLenum target, GLenum mode);
MGL_API GLboolean glIsBuffer(GLuint buffer);
MGL_API GLboolean glIsEnabled(GLenum cap);
MGL_API GLboolean glIsFramebuffer(GLuint framebuffer);
MGL_API GLboolean glIsProgram(GLuint program);
MGL_API GLboolean glIsRenderbuffer(GLuint renderbuffer);
MGL_API GLboolean glIsShader(GLuint shader);
MGL_API GLboolean glIsTexture(GLuint texture);
MGL_API void glLineWidth(GLfloat width);
MGL_API void glLinkProgram(GLuint program);
MGL_API void glPixelStorei(GLenum pname, GLint param);
MGL_API void glPolygonOffset(GLfloat factor, GLfloat units);
MGL_API void glReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void *pixels);
MGL_API void glReleaseShaderCompiler(void);
MGL_API void glRenderbufferStorage(GLenum target, GLenum internalformat, GLsizei width, GLsizei height);
MGL_API void glSampleCoverage(GLfloat value, GLboolean invert);
MGL_API void glScissor(GLint x, GLint y, GLsizei width, GLsizei height);
MGL_API void glShaderBinary(GLsizei n, const GLuint *shaders, GLenum binaryformat, const void *binary, GLsizei length);
MGL_API void glShaderSource(GLuint shader, GLsizei count, const GLchar *const *string, const GLint *length);
MGL_API void glStencilFunc(GLenum func, GLint ref, GLuint mask);
MGL_API void glStencilFuncSeparate(GLenum face, GLenum func, GLint ref, GLuint mask);
MGL_API void glStencilMask(GLuint mask);
MGL_API void glStencilMaskSeparate(GLenum face, GLuint mask);
MGL_API void glStencilOp(GLenum fail, GLenum zfail, GLenum zpass);
MGL_API void glStencilOpSeparate(GLenum face, GLenum fail, GLenum zfail, GLenum zpass);
MGL_API void glTexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const void *pixels);
MGL_API void glTexParameterf(GLenum target, GLenum pname, GLfloat param);
MGL_API void glTexParameterfv(GLenum target, GLenum pname, const GLfloat *params);
MGL_API void glTexParameteri(GLenum target, GLenum pname, GLint param);
MGL_API void glTexParameteriv(GLenum target, GLenum pname, const GLint *params);
MGL_API void glTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, const void *pixels);
MGL_API void glUniform1f(GLint location, GLfloat x);
MGL_API void glUniform1fv(GLint location, GLsizei count, const GLfloat *v);
MGL_API void glUniform1i(GLint location, GLint x);
MGL_API void glUniform1iv(GLint location, GLsizei count, const GLint *v);
MGL_API void glUniform2f(GLint location, GLfloat x, GLfloat y);
MGL_API void glUniform2fv(GLint location, GLsizei count, const GLfloat *v);
MGL_API void glUniform2i(GLint location, GLint x, GLint y);
MGL_API void glUniform2iv(GLint location, GLsizei count, const GLint *v);
MGL_API void glUniform3f(GLint location, GLfloat x, GLfloat y, GLfloat z);
MGL_API void glUniform3fv(GLint location, GLsizei count, const GLfloat *v);
MGL_API void glUniform3i(GLint location, GLint x, GLint y, GLint z);
MGL_API void glUniform3iv(GLint location, GLsizei count, const GLint *v);
MGL_API void glUniform4f(GLint location, GLfloat x, GLfloat y, GLfloat z, GLfloat w);
MGL_API void glUniform4fv(GLint location, GLsizei count, const GLfloat *v);
MGL_API void glUniform4i(GLint location, GLint x, GLint y, GLint z, GLint w);
MGL_API void glUniform4iv(GLint location, GLsizei count, const GLint *v);
MGL_API void glUniformMatrix2fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
MGL_API void glUniformMatrix3fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
MGL_API void glUniformMatrix4fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
MGL_API void glUseProgram(GLuint program);
MGL_API void glValidateProgram(GLuint program);
MGL_API void glVertexAttrib1f(GLuint indx, GLfloat x);
MGL_API void glVertexAttrib1fv(GLuint indx, const GLfloat *values);
MGL_API void glVertexAttrib2f(GLuint indx, GLfloat x, GLfloat y);
MGL_API void glVertexAttrib2fv(GLuint indx, const GLfloat *values);
MGL_API void glVertexAttrib3f(GLuint indx, GLfloat x, GLfloat y, GLfloat z);
MGL_API void glVertexAttrib3fv(GLuint indx, const GLfloat *values);
MGL_API void glVertexAttrib4f(GLuint indx, GLfloat x, GLfloat y, GLfloat z, GLfloat w);
MGL_API void glVertexAttrib4fv(GLuint indx, const GLfloat *values);
MGL_API void glVertexAttribPointer(GLuint indx, GLint size, GLenum type, GLboolean normalized, GLsizei stride, const void *pointer);
MGL_API void glViewport(GLint x, GLint y, GLsizei width, GLsizei height);

/* EGL 1.4, with the two ways of naming a platform's display (EGL 1.5's
 * and EGL_EXT_platform_base's) that programs for Wayland use. A native
 * display is a struct wl_display *, a native window a struct
 * wl_egl_window *; there are no pixmaps. */
typedef unsigned int EGLBoolean;
typedef unsigned int EGLenum;
typedef int32_t EGLint;
typedef intptr_t EGLAttrib;
typedef void *EGLConfig;
typedef void *EGLContext;
typedef void *EGLDisplay;
typedef void *EGLSurface;
typedef void *EGLClientBuffer;
typedef void *EGLNativeDisplayType;
typedef void *EGLNativeWindowType;
typedef void *EGLNativePixmapType;

#define EGL_FALSE 0
#define EGL_TRUE 1
#define EGL_DEFAULT_DISPLAY ((EGLNativeDisplayType)0)
#define EGL_NO_CONTEXT ((EGLContext)0)
#define EGL_NO_DISPLAY ((EGLDisplay)0)
#define EGL_NO_SURFACE ((EGLSurface)0)
#define EGL_DONT_CARE ((EGLint)-1)
#define EGL_UNKNOWN ((EGLint)-1)
#define EGL_SUCCESS 0x3000
#define EGL_NOT_INITIALIZED 0x3001
#define EGL_BAD_ACCESS 0x3002
#define EGL_BAD_ALLOC 0x3003
#define EGL_BAD_ATTRIBUTE 0x3004
#define EGL_BAD_CONFIG 0x3005
#define EGL_BAD_CONTEXT 0x3006
#define EGL_BAD_CURRENT_SURFACE 0x3007
#define EGL_BAD_DISPLAY 0x3008
#define EGL_BAD_MATCH 0x3009
#define EGL_BAD_NATIVE_PIXMAP 0x300A
#define EGL_BAD_NATIVE_WINDOW 0x300B
#define EGL_BAD_PARAMETER 0x300C
#define EGL_BAD_SURFACE 0x300D
#define EGL_CONTEXT_LOST 0x300E
#define EGL_BUFFER_SIZE 0x3020
#define EGL_ALPHA_SIZE 0x3021
#define EGL_BLUE_SIZE 0x3022
#define EGL_GREEN_SIZE 0x3023
#define EGL_RED_SIZE 0x3024
#define EGL_DEPTH_SIZE 0x3025
#define EGL_STENCIL_SIZE 0x3026
#define EGL_CONFIG_CAVEAT 0x3027
#define EGL_CONFIG_ID 0x3028
#define EGL_LEVEL 0x3029
#define EGL_MAX_PBUFFER_HEIGHT 0x302A
#define EGL_MAX_PBUFFER_PIXELS 0x302B
#define EGL_MAX_PBUFFER_WIDTH 0x302C
#define EGL_NATIVE_RENDERABLE 0x302D
#define EGL_NATIVE_VISUAL_ID 0x302E
#define EGL_NATIVE_VISUAL_TYPE 0x302F
#define EGL_SAMPLES 0x3031
#define EGL_SAMPLE_BUFFERS 0x3032
#define EGL_SURFACE_TYPE 0x3033
#define EGL_TRANSPARENT_TYPE 0x3034
#define EGL_TRANSPARENT_BLUE_VALUE 0x3035
#define EGL_TRANSPARENT_GREEN_VALUE 0x3036
#define EGL_TRANSPARENT_RED_VALUE 0x3037
#define EGL_NONE 0x3038
#define EGL_BIND_TO_TEXTURE_RGB 0x3039
#define EGL_BIND_TO_TEXTURE_RGBA 0x303A
#define EGL_MIN_SWAP_INTERVAL 0x303B
#define EGL_MAX_SWAP_INTERVAL 0x303C
#define EGL_LUMINANCE_SIZE 0x303D
#define EGL_ALPHA_MASK_SIZE 0x303E
#define EGL_COLOR_BUFFER_TYPE 0x303F
#define EGL_RENDERABLE_TYPE 0x3040
#define EGL_MATCH_NATIVE_PIXMAP 0x3041
#define EGL_CONFORMANT 0x3042
#define EGL_SLOW_CONFIG 0x3050
#define EGL_NON_CONFORMANT_CONFIG 0x3051
#define EGL_TRANSPARENT_RGB 0x3052
#define EGL_VENDOR 0x3053
#define EGL_VERSION 0x3054
#define EGL_EXTENSIONS 0x3055
#define EGL_HEIGHT 0x3056
#define EGL_WIDTH 0x3057
#define EGL_LARGEST_PBUFFER 0x3058
#define EGL_DRAW 0x3059
#define EGL_READ 0x305A
#define EGL_CORE_NATIVE_ENGINE 0x305B
#define EGL_NO_TEXTURE 0x305C
#define EGL_TEXTURE_RGB 0x305D
#define EGL_TEXTURE_RGBA 0x305E
#define EGL_TEXTURE_2D 0x305F
#define EGL_TEXTURE_FORMAT 0x3080
#define EGL_TEXTURE_TARGET 0x3081
#define EGL_MIPMAP_TEXTURE 0x3082
#define EGL_MIPMAP_LEVEL 0x3083
#define EGL_BACK_BUFFER 0x3084
#define EGL_SINGLE_BUFFER 0x3085
#define EGL_RENDER_BUFFER 0x3086
#define EGL_VG_COLORSPACE 0x3087
#define EGL_VG_ALPHA_FORMAT 0x3088
#define EGL_VG_COLORSPACE_sRGB 0x3089
#define EGL_VG_COLORSPACE_LINEAR 0x308A
#define EGL_VG_ALPHA_FORMAT_NONPRE 0x308B
#define EGL_VG_ALPHA_FORMAT_PRE 0x308C
#define EGL_CLIENT_APIS 0x308D
#define EGL_RGB_BUFFER 0x308E
#define EGL_LUMINANCE_BUFFER 0x308F
#define EGL_HORIZONTAL_RESOLUTION 0x3090
#define EGL_VERTICAL_RESOLUTION 0x3091
#define EGL_PIXEL_ASPECT_RATIO 0x3092
#define EGL_SWAP_BEHAVIOR 0x3093
#define EGL_BUFFER_PRESERVED 0x3094
#define EGL_BUFFER_DESTROYED 0x3095
#define EGL_OPENVG_IMAGE 0x3096
#define EGL_CONTEXT_CLIENT_TYPE 0x3097
#define EGL_CONTEXT_CLIENT_VERSION 0x3098
#define EGL_MULTISAMPLE_RESOLVE 0x3099
#define EGL_MULTISAMPLE_RESOLVE_DEFAULT 0x309A
#define EGL_MULTISAMPLE_RESOLVE_BOX 0x309B
#define EGL_OPENGL_ES_API 0x30A0
#define EGL_OPENVG_API 0x30A1
#define EGL_OPENGL_API 0x30A2
#define EGL_PBUFFER_BIT 0x0001
#define EGL_PIXMAP_BIT 0x0002
#define EGL_WINDOW_BIT 0x0004
#define EGL_VG_COLORSPACE_LINEAR_BIT 0x0020
#define EGL_VG_ALPHA_FORMAT_PRE_BIT 0x0040
#define EGL_MULTISAMPLE_RESOLVE_BOX_BIT 0x0200
#define EGL_SWAP_BEHAVIOR_PRESERVED_BIT 0x0400
#define EGL_OPENGL_ES_BIT 0x0001
#define EGL_OPENVG_BIT 0x0002
#define EGL_OPENGL_ES2_BIT 0x0004
#define EGL_OPENGL_BIT 0x0008
#define EGL_DISPLAY_SCALING 10000
#define EGL_PLATFORM_WAYLAND_KHR 0x31D8
#define EGL_PLATFORM_WAYLAND_EXT 0x31D8

MGL_API EGLBoolean eglBindAPI(EGLenum api);
MGL_API EGLBoolean eglBindTexImage(EGLDisplay dpy, EGLSurface surface, EGLint buffer);
MGL_API EGLBoolean eglChooseConfig(EGLDisplay dpy, const EGLint *attrib_list, EGLConfig *configs, EGLint config_size, EGLint *num_config);
MGL_API EGLBoolean eglCopyBuffers(EGLDisplay dpy, EGLSurface surface, EGLNativePixmapType target);
MGL_API EGLContext eglCreateContext(EGLDisplay dpy, EGLConfig config, EGLContext share_context, const EGLint *attrib_list);
MGL_API EGLSurface eglCreatePbufferFromClientBuffer(EGLDisplay dpy, EGLenum buftype, EGLClientBuffer buffer, EGLConfig config, const EGLint *attrib_list);
MGL_API EGLSurface eglCreatePbufferSurface(EGLDisplay dpy, EGLConfig config, const EGLint *attrib_list);
MGL_API EGLSurface eglCreatePixmapSurface(EGLDisplay dpy, EGLConfig config, EGLNativePixmapType pixmap, const EGLint *attrib_list);
MGL_API EGLSurface eglCreatePlatformPixmapSurface(EGLDisplay dpy, EGLConfig config, void *native_pixmap, const EGLAttrib *attrib_list);
MGL_API EGLSurface eglCreatePlatformPixmapSurfaceEXT(EGLDisplay dpy, EGLConfig config, void *native_pixmap, const EGLint *attrib_list);
MGL_API EGLSurface eglCreatePlatformWindowSurface(EGLDisplay dpy, EGLConfig config, void *native_window, const EGLAttrib *attrib_list);
MGL_API EGLSurface eglCreatePlatformWindowSurfaceEXT(EGLDisplay dpy, EGLConfig config, void *native_window, const EGLint *attrib_list);
MGL_API EGLSurface eglCreateWindowSurface(EGLDisplay dpy, EGLConfig config, EGLNativeWindowType win, const EGLint *attrib_list);
MGL_API EGLBoolean eglDestroyContext(EGLDisplay dpy, EGLContext ctx);
MGL_API EGLBoolean eglDestroySurface(EGLDisplay dpy, EGLSurface surface);
MGL_API EGLBoolean eglGetConfigAttrib(EGLDisplay dpy, EGLConfig config, EGLint attribute, EGLint *value);
MGL_API EGLBoolean eglGetConfigs(EGLDisplay dpy, EGLConfig *configs, EGLint config_size, EGLint *num_config);
MGL_API EGLContext eglGetCurrentContext(void);
MGL_API EGLDisplay eglGetCurrentDisplay(void);
MGL_API EGLSurface eglGetCurrentSurface(EGLint readdraw);
MGL_API EGLDisplay eglGetDisplay(EGLNativeDisplayType display_id);
MGL_API EGLint eglGetError(void);
MGL_API EGLDisplay eglGetPlatformDisplay(EGLenum platform, void *native_display, const EGLAttrib *attrib_list);
MGL_API EGLDisplay eglGetPlatformDisplayEXT(EGLenum platform, void *native_display, const EGLint *attrib_list);
MGL_API void (*eglGetProcAddress(const char *procname))(void);
MGL_API EGLBoolean eglInitialize(EGLDisplay dpy, EGLint *major, EGLint *minor);
MGL_API EGLBoolean eglMakeCurrent(EGLDisplay dpy, EGLSurface draw, EGLSurface rd, EGLContext ctx);
MGL_API EGLenum eglQueryAPI(void);
MGL_API EGLBoolean eglQueryContext(EGLDisplay dpy, EGLContext ctx, EGLint attribute, EGLint *value);
MGL_API const char *eglQueryString(EGLDisplay dpy, EGLint name);
MGL_API EGLBoolean eglQuerySurface(EGLDisplay dpy, EGLSurface surface, EGLint attribute, EGLint *value);
MGL_API EGLBoolean eglReleaseTexImage(EGLDisplay dpy, EGLSurface surface, EGLint buffer);
MGL_API EGLBoolean eglReleaseThread(void);
MGL_API EGLBoolean eglSurfaceAttrib(EGLDisplay dpy, EGLSurface surface, EGLint attribute, EGLint value);
MGL_API EGLBoolean eglSwapBuffers(EGLDisplay dpy, EGLSurface surface);
MGL_API EGLBoolean eglSwapInterval(EGLDisplay dpy, EGLint interval);
MGL_API EGLBoolean eglTerminate(EGLDisplay dpy);
MGL_API EGLBoolean eglWaitClient(void);
MGL_API EGLBoolean eglWaitGL(void);
MGL_API EGLBoolean eglWaitNative(EGLint engine);

#endif
