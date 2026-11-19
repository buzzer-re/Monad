/*
 * test_gl_lib.c — the library that stands where a Linux VM's EGL and
 * OpenGL ES would (GuestWM/mgl_*.c), driven as a program drives it,
 * through eglInitialize, glDrawArrays and the rest, with the other end of
 * its socket played by gl_test_host.h: what each call writes down for the
 * Mac, byte for byte as GuestWM/mwm_gl_wire.h has it; what it answers a
 * program without asking the Mac; and that a window manager that goes
 * away, or answers what the protocol does not have, costs the program its
 * pictures and nothing else.
 */
#include "gl_test_host.h"

#include <limits.h>

/* What stands for the program's wl_display and for a window's wl_surface: the library hands them to its Wayland side as they are. */
static int native_display, native_surface;

/* A native window as wl_egl_window_create makes one. */
#define WINDOW(name, wide, high) \
    struct wl_egl_window name = {.version = 3, .width = (wide), .height = (high), .surface = (struct wl_surface *)&native_surface}

/* A place in the buffer bound, as glVertexAttribPointer and glDrawElements take one: a number in a pointer's clothes. */
#define OFFSET(bytes) ((const void *)(uintptr_t)(bytes))

static const EGLint es2[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};

static EGLDisplay dpy;
static EGLConfig config;
static EGLContext context;
static EGLSurface surface;

/* What was written so far is sent, and the host has taken it apart. */
static void sent(void) {
    glFlush();
    host_settle();
}

/* The test has looked at every command that came. */
static void nothing_more(void) {
    sent();
    if (host.looked != host.count) fprintf(stderr, "command %u came and was not looked for\n", host.commands[host.looked].op);
    CHECK(host.looked == host.count);
}

/* Where most tests begin: a new stream, and a context current on a window of 300 × 200 that has every buffer there is
 * (alpha, depth, stencil). */
static void begin(struct wl_egl_window *window) {
    host_start(1);
    memset(&wayland, 0, sizeof wayland);
    dpy = eglGetDisplay(&native_display);
    CHECK(dpy != EGL_NO_DISPLAY && eglInitialize(dpy, NULL, NULL));
    const EGLint wanted[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8, EGL_NONE};
    EGLint n = 0;
    CHECK(eglChooseConfig(dpy, wanted, &config, 1, &n) && n == 1);
    context = eglCreateContext(dpy, config, EGL_NO_CONTEXT, es2);
    surface = eglCreateWindowSurface(dpy, config, window, NULL);
    CHECK(context != EGL_NO_CONTEXT && surface != EGL_NO_SURFACE);
    CHECK(eglMakeCurrent(dpy, surface, surface, context));
    sent();
    expect(MGL_CONTEXT_CREATE, 2, 1, 0);
    expect(MGL_SURFACE_CREATE, 6, 1, window->width, window->height, 1, 1, 1);
    expect(MGL_MAKE_CURRENT, 3, 1, 1, 1);
}

/* The program is done: nothing is current, the display is terminated, and the stream closed with it. */
static void finish(void) {
    CHECK(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT));
    CHECK(eglTerminate(dpy));
    host_stop();
}

/* A stream begins with the window manager's eight bytes. Without a window
 * manager to draw for, or with one that says something else,
 * eglInitialize fails as EGL has it and the program can go on without. */
static void test_the_stream_begins_with_the_handshake(void) {
    EGLDisplay d = eglGetDisplay(&native_display);
    CHECK(d != EGL_NO_DISPLAY && eglGetDisplay(&native_display) == d && eglGetError() == EGL_SUCCESS);
    EGLint n = 0;
    CHECK(!eglGetConfigs(d, NULL, 0, &n) && eglGetError() == EGL_NOT_INITIALIZED);
    CHECK(!eglInitialize((EGLDisplay)&n, NULL, NULL) && eglGetError() == EGL_BAD_DISPLAY);

    /* Another magic, and a stream that is none (0). */
    host_start_saying(0x12345678, 1);
    CHECK(!eglInitialize(d, NULL, NULL) && eglGetError() == EGL_NOT_INITIALIZED);
    host_stop();
    host_start_saying(MWM_GL_MAGIC, 0);
    CHECK(!eglInitialize(d, NULL, NULL) && eglGetError() == EGL_NOT_INITIALIZED);
    host_stop();
    /* A window manager that hangs up before it said anything. */
    int ends[2];
    char number[16];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, ends) == 0);
    close(ends[0]);
    snprintf(number, sizeof number, "%d", ends[1]);
    setenv("MONAD_GL_FD", number, 1);
    CHECK(!eglInitialize(d, NULL, NULL) && eglGetError() == EGL_NOT_INITIALIZED);
    setenv("MONAD_GL_FD", "none", 1);
    CHECK(!eglInitialize(d, NULL, NULL) && eglGetError() == EGL_NOT_INITIALIZED);

    /* No socket: no runtime directory at all, and one without a window manager's socket in it. */
    char dir[] = "/tmp/mgl-test-XXXXXX", path[64];
    unsetenv("MONAD_GL_FD");
    unsetenv("XDG_RUNTIME_DIR");
    CHECK(!eglInitialize(d, NULL, NULL) && eglGetError() == EGL_NOT_INITIALIZED);
    CHECK(mkdtemp(dir));
    setenv("XDG_RUNTIME_DIR", dir, 1);
    CHECK(!eglInitialize(d, NULL, NULL) && eglGetError() == EGL_NOT_INITIALIZED);

    /* The socket is there: the library dials it, and the stream's number is what a window's buffer says. */
    snprintf(path, sizeof path, "%s/%s", dir, MWM_GL_SOCKET);
    host_start_listening(path, 7);
    memset(&wayland, 0, sizeof wayland);
    EGLint major = 0, minor = 0;
    CHECK(eglInitialize(d, &major, &minor) && major == 1 && minor == 4 && eglGetError() == EGL_SUCCESS);
    CHECK(eglInitialize(d, NULL, NULL)); /* again: it is */
    CHECK(wayland.binds == 1 && wayland.display == &native_display);
    WINDOW(window, 64, 48);
    EGLConfig any;
    const EGLint es2_configs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE};
    CHECK(eglChooseConfig(d, es2_configs, &any, 1, &n) && n == 1);
    EGLContext c = eglCreateContext(d, any, EGL_NO_CONTEXT, es2);
    EGLSurface s = eglCreateWindowSurface(d, any, &window, NULL);
    CHECK(eglMakeCurrent(d, s, s, c) && eglSwapBuffers(d, s));
    CHECK(wayland.present_count == 1 && wayland.presents[0].stream == 7 && wayland.presents[0].id == 1);
    CHECK(wayland.presents[0].surface == &native_surface);
    CHECK(eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT) && eglTerminate(d));
    host_stop();
    CHECK(host.count == 7 && host.commands[3].op == MGL_SWAP);
    CHECK(unlink(path) == 0 && rmdir(dir) == 0);
    unsetenv("XDG_RUNTIME_DIR");

    /* A Wayland display whose window manager is not Monad's (no monad_gl): no windows could be shown. */
    wayland.refuses = true;
    host_start(1);
    CHECK(!eglInitialize(d, NULL, NULL) && eglGetError() == EGL_NOT_INITIALIZED);
    host_stop(); /* the stream opened for it was closed again */
    wayland.refuses = false;
}

/* Two threads take turns: what `turn` is says whose it is. */
static struct {
    pthread_mutex_t lock;
    pthread_cond_t moved;
    int turn;
} baton = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0};

static void pass_baton(void) {
    pthread_mutex_lock(&baton.lock);
    baton.turn++;
    pthread_cond_broadcast(&baton.moved);
    pthread_mutex_unlock(&baton.lock);
}

static void await_turn(int turn) {
    pthread_mutex_lock(&baton.lock);
    while (baton.turn < turn) pthread_cond_wait(&baton.moved, &baton.lock);
    pthread_mutex_unlock(&baton.lock);
}

static EGLContext second;
static EGLSurface pbuffer;

static void *draws_with_the_second_context(void *unused) {
    (void)unused;
    CHECK(eglGetCurrentContext() == EGL_NO_CONTEXT && eglGetError() == EGL_SUCCESS);
    CHECK(eglMakeCurrent(dpy, pbuffer, pbuffer, second));
    glClearStencil(3);
    pass_baton();
    await_turn(2);
    glDisable(GL_DITHER);
    pass_baton();
    await_turn(4);
    return NULL; /* with its context still current */
}

/* Contexts and surfaces have the library's names, 1 and up. A stream has
 * one current context: when a thread's call follows another thread's,
 * MakeCurrent goes before it. What is destroyed while current lives until
 * it is let go. */
static void test_contexts_and_surfaces_are_named_and_made_current(void) {
    WINDOW(window, 300, 200);
    begin(&window);
    CHECK(window.driver_private && window.resize_callback && window.destroy_window_callback);
    second = eglCreateContext(dpy, config, context, es2);
    const EGLint small[] = {EGL_WIDTH, 16, EGL_HEIGHT, 8, EGL_NONE};
    pbuffer = eglCreatePbufferSurface(dpy, config, small);
    CHECK(second != EGL_NO_CONTEXT && pbuffer != EGL_NO_SURFACE && eglGetError() == EGL_SUCCESS);
    glClear(GL_COLOR_BUFFER_BIT);

    baton.turn = 0;
    pthread_t other;
    CHECK(pthread_create(&other, NULL, draws_with_the_second_context, NULL) == 0);
    await_turn(1);
    /* What another thread has current is not this one's to take. */
    CHECK(!eglMakeCurrent(dpy, surface, surface, second) && eglGetError() == EGL_BAD_ACCESS);
    CHECK(!eglMakeCurrent(dpy, pbuffer, pbuffer, context) && eglGetError() == EGL_BAD_ACCESS);
    CHECK(eglGetCurrentContext() == context);
    glEnable(GL_BLEND);
    pass_baton();
    await_turn(3);
    glClear(GL_DEPTH_BUFFER_BIT);
    pass_baton();
    CHECK(pthread_join(other, NULL) == 0);
    sent();
    expect(MGL_CONTEXT_CREATE, 2, 2, 1); /* shares the first one's objects */
    expect(MGL_SURFACE_CREATE, 6, 2, 16, 8, 1, 1, 1);
    expect(MGL_CLEAR, 1, GL_COLOR_BUFFER_BIT);
    expect(MGL_MAKE_CURRENT, 3, 2, 2, 2);
    expect(MGL_CLEAR_STENCIL, 1, 3);
    expect(MGL_MAKE_CURRENT, 3, 1, 1, 1);
    expect(MGL_ENABLE, 1, GL_BLEND);
    expect(MGL_MAKE_CURRENT, 3, 2, 2, 2);
    expect(MGL_DISABLE, 1, GL_DITHER);
    expect(MGL_MAKE_CURRENT, 3, 1, 1, 1);
    expect(MGL_CLEAR, 1, GL_DEPTH_BUFFER_BIT);
    nothing_more();

    /* The thread ended: its context is free for this one, which sees the first one's objects through it. */
    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    CHECK(eglMakeCurrent(dpy, pbuffer, pbuffer, second));
    CHECK(eglGetCurrentContext() == second && eglGetCurrentDisplay() == dpy);
    CHECK(eglGetCurrentSurface(EGL_DRAW) == pbuffer && eglGetCurrentSurface(EGL_READ) == pbuffer);
    CHECK(eglGetCurrentSurface(0) == EGL_NO_SURFACE && eglGetError() == EGL_BAD_PARAMETER);
    CHECK(glIsTexture(texture));
    GLint box[4] = {0};
    glGetIntegerv(GL_VIEWPORT, box);
    CHECK(box[0] == 0 && box[1] == 0 && box[2] == 16 && box[3] == 8); /* its first surface's size */
    EGLint value = 0;
    CHECK(eglQuerySurface(dpy, pbuffer, EGL_WIDTH, &value) && value == 16);
    CHECK(eglQuerySurface(dpy, surface, EGL_HEIGHT, &value) && value == 200);
    CHECK(eglQueryContext(dpy, second, EGL_CONTEXT_CLIENT_VERSION, &value) && value == 2);
    CHECK(eglQueryContext(dpy, second, EGL_CONTEXT_CLIENT_TYPE, &value) && value == EGL_OPENGL_ES_API);
    CHECK(!eglQueryContext(dpy, second, EGL_WIDTH, &value) && eglGetError() == EGL_BAD_ATTRIBUTE);

    /* Destroyed while current: no handle any more, and alive until let go. */
    CHECK(eglDestroyContext(dpy, second) && eglDestroySurface(dpy, pbuffer));
    CHECK(!eglDestroyContext(dpy, second) && eglGetError() == EGL_BAD_CONTEXT);
    CHECK(!eglDestroySurface(dpy, pbuffer) && eglGetError() == EGL_BAD_SURFACE);
    glClear(GL_STENCIL_BUFFER_BIT);
    CHECK(eglMakeCurrent(dpy, surface, surface, context));
    sent();
    expect(MGL_BIND_TEXTURE, 2, GL_TEXTURE_2D, texture);
    expect(MGL_MAKE_CURRENT, 3, 2, 2, 2);
    expect(MGL_CLEAR, 1, GL_STENCIL_BUFFER_BIT);
    expect(MGL_MAKE_CURRENT, 3, 1, 1, 1);
    expect(MGL_CONTEXT_DESTROY, 1, 2);
    expect(MGL_SURFACE_DESTROY, 1, 2);
    nothing_more();

    /* Nothing current: the Mac is told, and the thread's calls go nowhere. eglReleaseThread is that too. */
    CHECK(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT) && eglGetCurrentContext() == EGL_NO_CONTEXT);
    CHECK(!eglMakeCurrent(dpy, surface, surface, EGL_NO_CONTEXT) && eglGetError() == EGL_BAD_MATCH);
    CHECK(!eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, context) && eglGetError() == EGL_BAD_MATCH);
    CHECK(eglMakeCurrent(dpy, surface, surface, context) && eglReleaseThread() && eglGetCurrentContext() == EGL_NO_CONTEXT);

    /* A display terminated with a context current: it and its surface go when they are let go, and the stream with them. */
    CHECK(eglMakeCurrent(dpy, surface, surface, context) && eglTerminate(dpy));
    CHECK(wayland.gone == 1 && wayland.unbinds == 1);
    glClear(GL_COLOR_BUFFER_BIT);
    CHECK(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT));
    host_stop();
    expect(MGL_MAKE_CURRENT, 3, 0, 0, 0);
    expect(MGL_MAKE_CURRENT, 3, 1, 1, 1);
    expect(MGL_MAKE_CURRENT, 3, 0, 0, 0);
    expect(MGL_MAKE_CURRENT, 3, 1, 1, 1);
    expect(MGL_CLEAR, 1, GL_COLOR_BUFFER_BIT);
    expect(MGL_MAKE_CURRENT, 3, 0, 0, 0);
    expect(MGL_CONTEXT_DESTROY, 1, 1);
    expect(MGL_SURFACE_DESTROY, 1, 1);
    CHECK(host.looked == host.count);
    /* The program's window is its own again. */
    CHECK(!window.driver_private && !window.resize_callback && !window.destroy_window_callback && wayland.gone == 1);
}

static void variable(body *b, uint32_t location, uint32_t type, uint32_t size, const char *name) {
    body_u32(b, location);
    body_u32(b, type);
    body_u32(b, size);
    body_text(b, name);
}

/* What LinkProgram is answered for the program of the tests: two attributes and four uniforms, one of them an array. */
static void gears_program_links(void) {
    body b = {.len = 0};
    body_u32(&b, 1);
    body_text(&b, "");
    body_u32(&b, 2);
    variable(&b, 0, GL_FLOAT_VEC3, 1, "position");
    variable(&b, 1, GL_FLOAT_VEC3, 1, "normal");
    body_u32(&b, 4);
    variable(&b, 0, GL_FLOAT_MAT4, 1, "ModelViewProjectionMatrix");
    variable(&b, 1, GL_FLOAT_VEC4, 1, "LightSourcePosition");
    variable(&b, 2, GL_FLOAT_VEC3, 4, "lights[0]");
    variable(&b, 6, GL_FLOAT_VEC4, 1, "MaterialColor");
    HOST(host.link = b);
}

/* A program of two shaders, linked as gears_program_links has it; the commands it took are looked at. */
static GLuint gears_program(void) {
    GLuint vertex = glCreateShader(GL_VERTEX_SHADER), fragment = glCreateShader(GL_FRAGMENT_SHADER), program = glCreateProgram();
    const char *text = "void main() {}";
    glShaderSource(vertex, 1, &text, NULL);
    glShaderSource(fragment, 1, &text, NULL);
    glCompileShader(vertex);
    glCompileShader(fragment);
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    gears_program_links();
    glLinkProgram(program);
    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    CHECK(linked == GL_TRUE);
    glUseProgram(program);
    sent();
    expect(MGL_CREATE_SHADER, 2, vertex, GL_VERTEX_SHADER);
    expect(MGL_CREATE_SHADER, 2, fragment, GL_FRAGMENT_SHADER);
    expect(MGL_CREATE_PROGRAM, 1, program);
    expect_data(MGL_SHADER_SOURCE, text, strlen(text), 1, vertex);
    expect_data(MGL_SHADER_SOURCE, text, strlen(text), 1, fragment);
    expect(MGL_COMPILE_SHADER, 1, vertex);
    expect(MGL_COMPILE_SHADER, 1, fragment);
    expect(MGL_ATTACH_SHADER, 2, program, vertex);
    expect(MGL_ATTACH_SHADER, 2, program, fragment);
    expect(MGL_LINK_PROGRAM, 1, program);
    expect(MGL_USE_PROGRAM, 1, program);
    return program;
}

/* A frame of a program like es2gears, from its shaders to the swap: every
 * command as the header has it, in the order of the calls, and what the
 * program asks on the way (where its uniforms are) answered from the
 * LinkProgram reply with nothing sent. */
static void test_a_frame_of_gears(void) {
    WINDOW(window, 300, 200);
    begin(&window);

    /* The shaders: their text joined, compiled on the Mac, the answer kept. */
    GLuint vertex = glCreateShader(GL_VERTEX_SHADER);
    CHECK(vertex == 1 && glIsShader(vertex) && !glIsProgram(vertex));
    const char *parts[] = {"attribute vec3 position;\n", "void main() { gl_Position = vec4(position, 1.0); }\nnot this"};
    const char *joined = "attribute vec3 position;\nvoid main() { gl_Position = vec4(position, 1.0); }\n";
    const GLint lengths[] = {-1, (GLint)strlen(parts[1]) - 8};
    glShaderSource(vertex, 2, parts, lengths);
    glCompileShader(vertex);
    GLint value = 0;
    glGetShaderiv(vertex, GL_COMPILE_STATUS, &value);
    CHECK(value == GL_TRUE);
    glGetShaderiv(vertex, GL_INFO_LOG_LENGTH, &value);
    CHECK(value == 0);
    glGetShaderiv(vertex, GL_SHADER_SOURCE_LENGTH, &value);
    CHECK(value == (GLint)strlen(joined) + 1);
    glGetShaderiv(vertex, GL_SHADER_TYPE, &value);
    CHECK(value == GL_VERTEX_SHADER);
    char text[200];
    GLsizei length = 0;
    glGetShaderSource(vertex, sizeof text, &length, text);
    CHECK(length == (GLsizei)strlen(joined) && strcmp(text, joined) == 0);
    glGetShaderSource(vertex, 10, &length, text); /* as much as there is room for */
    CHECK(length == 9 && strcmp(text, "attribute") == 0);

    /* One that does not compile says why. */
    GLuint fragment = glCreateShader(GL_FRAGMENT_SHADER);
    CHECK(fragment == 2);
    const char *broken = "void main() { gl_FragColor = nothing; }";
    glShaderSource(fragment, 1, &broken, NULL);
    HOST(host.compiled = 0; host.info = "0:1: 'nothing' is not declared");
    glCompileShader(fragment);
    glGetShaderiv(fragment, GL_COMPILE_STATUS, &value);
    CHECK(value == GL_FALSE);
    glGetShaderiv(fragment, GL_INFO_LOG_LENGTH, &value);
    CHECK(value == 31);
    glGetShaderInfoLog(fragment, sizeof text, &length, text);
    CHECK(length == 30 && strcmp(text, "0:1: 'nothing' is not declared") == 0);
    const char *mended = "void main() { gl_FragColor = vec4(1.0); }";
    glShaderSource(fragment, 1, &mended, NULL);
    HOST(host.compiled = 1; host.info = NULL);
    glCompileShader(fragment);
    glGetShaderiv(fragment, GL_COMPILE_STATUS, &value);
    CHECK(value == GL_TRUE);

    /* The program: linked on the Mac, which tells what it is made of. */
    GLuint program = glCreateProgram();
    CHECK(program == 3 && glIsProgram(program) && !glIsShader(program));
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glBindAttribLocation(program, 0, "position");
    glGetProgramiv(program, GL_LINK_STATUS, &value);
    CHECK(value == GL_FALSE);
    gears_program_links();
    glLinkProgram(program);
    glGetProgramiv(program, GL_LINK_STATUS, &value);
    CHECK(value == GL_TRUE);
    glGetProgramiv(program, GL_ATTACHED_SHADERS, &value);
    CHECK(value == 2);
    GLuint attached[2] = {0};
    glGetAttachedShaders(program, 2, &length, attached);
    CHECK(length == 2 && attached[0] == vertex && attached[1] == fragment);
    glGetProgramiv(program, GL_ACTIVE_ATTRIBUTES, &value);
    CHECK(value == 2);
    glGetProgramiv(program, GL_ACTIVE_ATTRIBUTE_MAX_LENGTH, &value);
    CHECK(value == 9);
    glGetProgramiv(program, GL_ACTIVE_UNIFORMS, &value);
    CHECK(value == 4);
    glGetProgramiv(program, GL_ACTIVE_UNIFORM_MAX_LENGTH, &value);
    CHECK(value == 26);
    glGetProgramiv(program, GL_INFO_LOG_LENGTH, &value);
    CHECK(value == 0);
    glValidateProgram(program);
    glGetProgramiv(program, GL_VALIDATE_STATUS, &value);
    CHECK(value == GL_TRUE);
    CHECK(glGetAttribLocation(program, "position") == 0 && glGetAttribLocation(program, "normal") == 1);
    CHECK(glGetAttribLocation(program, "colour") == -1);
    GLint size = 0;
    GLenum type = 0;
    glGetActiveAttrib(program, 1, sizeof text, &length, &size, &type, text);
    CHECK(length == 6 && size == 1 && type == GL_FLOAT_VEC3 && strcmp(text, "normal") == 0);
    glGetActiveUniform(program, 2, sizeof text, &length, &size, &type, text);
    CHECK(length == 9 && size == 4 && type == GL_FLOAT_VEC3 && strcmp(text, "lights[0]") == 0);
    /* Where the uniforms are: an array's elements one after the other, by "name", "name[0]" and "name[i]". */
    GLint matrix_at = glGetUniformLocation(program, "ModelViewProjectionMatrix"), light_at = glGetUniformLocation(program, "LightSourcePosition");
    GLint colour_at = glGetUniformLocation(program, "MaterialColor");
    CHECK(matrix_at == 0 && light_at == 1 && colour_at == 6);
    CHECK(glGetUniformLocation(program, "lights") == 2 && glGetUniformLocation(program, "lights[0]") == 2);
    CHECK(glGetUniformLocation(program, "lights[2]") == 4 && glGetUniformLocation(program, "lights[3]") == 5);
    CHECK(glGetUniformLocation(program, "lights[4]") == -1 && glGetUniformLocation(program, "lights[]") == -1);
    CHECK(glGetUniformLocation(program, "MaterialColor[0]") == -1 && glGetUniformLocation(program, "Material") == -1);
    CHECK(glGetUniformLocation(program, "lights[99999999999999999999]") == -1 && glGetUniformLocation(program, "") == -1);
    glUseProgram(program);
    glGetIntegerv(GL_CURRENT_PROGRAM, &value);
    CHECK(value == (GLint)program);

    /* The gear: a buffer of vertices, each a position and a normal. */
    static const GLfloat gear[] = {-1, -1, 0, 0, 0, 1, 1, -1, 0, 0, 0, 1, -1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1};
    GLuint buffer = 0;
    glGenBuffers(1, &buffer);
    CHECK(buffer == 1 && !glIsBuffer(buffer)); /* a name, and no buffer until it is bound */
    glBindBuffer(GL_ARRAY_BUFFER, buffer);
    CHECK(glIsBuffer(buffer));
    glBufferData(GL_ARRAY_BUFFER, sizeof gear, gear, GL_STATIC_DRAW);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(GLfloat), NULL);
    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(GLfloat), OFFSET(12));
    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);

    /* A frame. */
    static const GLfloat light[4] = {5, 5, 10, 1}, red[4] = {0.8f, 0.1f, 0, 1};
    static const GLfloat matrix[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0.5f, -0.25f, 0, 1};
    glViewport(0, 0, 300, 200);
    glEnable(GL_CULL_FACE);
    glEnable(GL_DEPTH_TEST);
    glClearColor(0, 0, 0, 0.5f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glUniform4fv(light_at, 1, light);
    glUniformMatrix4fv(matrix_at, 1, GL_FALSE, matrix);
    glUniform4fv(colour_at, 1, red);
    glUniform4fv(glGetUniformLocation(program, "nothing"), 1, red); /* -1: nothing to set */
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    CHECK(eglSwapBuffers(dpy, surface) && eglGetError() == EGL_SUCCESS);
    host_settle(); /* a swap sends what was written */

    expect(MGL_CREATE_SHADER, 2, 1, GL_VERTEX_SHADER);
    expect_data(MGL_SHADER_SOURCE, joined, strlen(joined), 1, 1);
    expect(MGL_COMPILE_SHADER, 1, 1);
    expect(MGL_CREATE_SHADER, 2, 2, GL_FRAGMENT_SHADER);
    expect_data(MGL_SHADER_SOURCE, broken, strlen(broken), 1, 2);
    expect(MGL_COMPILE_SHADER, 1, 2);
    expect_data(MGL_SHADER_SOURCE, mended, strlen(mended), 1, 2);
    expect(MGL_COMPILE_SHADER, 1, 2);
    expect(MGL_CREATE_PROGRAM, 1, 3);
    expect(MGL_ATTACH_SHADER, 2, 3, 1);
    expect(MGL_ATTACH_SHADER, 2, 3, 2);
    expect_data(MGL_BIND_ATTRIB_LOCATION, "position", 8, 2, 3, 0);
    expect(MGL_LINK_PROGRAM, 1, 3);
    expect(MGL_USE_PROGRAM, 1, 3);
    expect(MGL_BIND_BUFFER, 2, GL_ARRAY_BUFFER, 1);
    expect_data(MGL_BUFFER_DATA, gear, sizeof gear, 3, GL_ARRAY_BUFFER, (uint32_t)sizeof gear, GL_STATIC_DRAW);
    expect(MGL_VERTEX_ATTRIB_POINTER, 6, 0, 3, GL_FLOAT, 0, 24, 0);
    expect(MGL_VERTEX_ATTRIB_POINTER, 6, 1, 3, GL_FLOAT, 0, 24, 12);
    expect(MGL_ENABLE_VERTEX_ATTRIB_ARRAY, 1, 0);
    expect(MGL_ENABLE_VERTEX_ATTRIB_ARRAY, 1, 1);
    expect(MGL_VIEWPORT, 4, 0, 0, 300, 200);
    expect(MGL_ENABLE, 1, GL_CULL_FACE);
    expect(MGL_ENABLE, 1, GL_DEPTH_TEST);
    expect(MGL_CLEAR_COLOR, 4, f32(0), f32(0), f32(0), f32(0.5f));
    expect(MGL_CLEAR, 1, GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    expect_data(MGL_UNIFORM_4FV, light, sizeof light, 2, 1, 1);
    expect_data(MGL_UNIFORM_MATRIX_4FV, matrix, sizeof matrix, 2, 0, 1);
    expect_data(MGL_UNIFORM_4FV, red, sizeof red, 2, 6, 1);
    expect(MGL_DRAW_ARRAYS, 3, GL_TRIANGLE_STRIP, 0, 4);
    expect(MGL_SWAP, 1, 1);
    CHECK(host.looked == host.count);
    /* The window's wl_surface was committed with what it shows, and the window knows the size of it. */
    CHECK(wayland.present_count == 1 && wayland.presents[0].surface == &native_surface);
    CHECK(wayland.presents[0].stream == 1 && wayland.presents[0].id == 1 && wayland.presents[0].interval == 1);
    CHECK(wayland.presents[0].width == 300 && wayland.presents[0].height == 200);
    CHECK(window.attached_width == 300 && window.attached_height == 200);

    /* The window is resized (wl_egl_window_resize, which calls the library): the pictures after are of the new size. */
    window.width = 400;
    window.resize_callback(&window, window.driver_private);
    EGLint wide = 0, high = 0;
    CHECK(eglQuerySurface(dpy, surface, EGL_WIDTH, &wide) && eglQuerySurface(dpy, surface, EGL_HEIGHT, &high) && wide == 400 && high == 200);
    CHECK(eglSwapInterval(dpy, 0) && eglSwapBuffers(dpy, surface));
    /* A size that changed with no word of it is found at the swap, for the picture after the one swapped. */
    window.height = 250;
    CHECK(eglSwapInterval(dpy, 5) && eglSwapBuffers(dpy, surface));
    CHECK(eglQuerySurface(dpy, surface, EGL_HEIGHT, &high) && high == 250);
    sent(); /* the resize waits with the next picture's commands */
    expect(MGL_SURFACE_RESIZE, 3, 1, 400, 200);
    expect(MGL_SWAP, 1, 1);
    expect(MGL_SWAP, 1, 1);
    expect(MGL_SURFACE_RESIZE, 3, 1, 400, 250);
    CHECK(wayland.present_count == 3 && wayland.presents[1].width == 400 && wayland.presents[1].interval == 0);
    CHECK(wayland.presents[2].height == 200 && wayland.presents[2].interval == 1 && window.attached_height == 200);
    /* A window larger than anything is drawn at: the largest there is. */
    window.width = 5000;
    window.resize_callback(&window, window.driver_private);
    CHECK(eglQuerySurface(dpy, surface, EGL_WIDTH, &wide) && wide == 4096);

    /* The program destroys its window before the surface (wl_egl_window_destroy): its wl_surface is let go of, and a swap shows nothing. */
    window.destroy_window_callback(window.driver_private);
    CHECK(wayland.gone == 1 && eglSwapBuffers(dpy, surface) && wayland.present_count == 3);
    CHECK(eglDestroySurface(dpy, surface));
    host_settle();
    expect(MGL_SURFACE_RESIZE, 3, 1, 4096, 250);
    expect(MGL_SWAP, 1, 1);
    CHECK(host.looked == host.count);
    finish();
    CHECK(wayland.gone == 1);
}

/* Rows of pixels as a program has them, each beginning at a multiple of the alignment, with 0xee between them. */
static uint8_t *rows(int width, int height, int pixel, int alignment, size_t *tight_size, uint8_t **tight) {
    size_t row = (size_t)width * (size_t)pixel, stride = (row + (size_t)alignment - 1) / (size_t)alignment * (size_t)alignment;
    /* Exactly what OpenGL reads, and not the padding after the last row: ASan sees a read past it. */
    uint8_t *loose = malloc(stride * (size_t)(height - 1) + row);
    *tight = malloc(row * (size_t)height);
    CHECK(loose && *tight);
    memset(loose, 0xee, stride * (size_t)(height - 1) + row);
    for (int y = 0; y < height; y++)
        for (size_t x = 0; x < row; x++) loose[(size_t)y * stride + x] = (*tight)[(size_t)y * row + x] = (uint8_t)(1 + y * 16 + (int)x);
    *tight_size = row * (size_t)height;
    return loose;
}

/* Textures travel with their rows packed tight, whatever GL_UNPACK_ALIGNMENT
 * the program gave them with; PixelStorei itself is not sent. What OpenGL ES
 * 2.0 does not take as a picture is an error here, and nothing is sent. */
static void test_texture_rows_arrive_tight_whatever_the_alignment(void) {
    WINDOW(window, 300, 200);
    begin(&window);
    GLuint texture = 0;
    glGenTextures(1, &texture);
    CHECK(texture == 1 && !glIsTexture(texture));
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, texture);
    CHECK(glIsTexture(texture));
    sent();
    expect(MGL_ACTIVE_TEXTURE, 1, GL_TEXTURE2);
    expect(MGL_BIND_TEXTURE, 2, GL_TEXTURE_2D, 1);

    static const struct {
        GLenum format, type;
        int pixel;
    } kinds[] = {
        {GL_RGBA, GL_UNSIGNED_BYTE, 4},        {GL_RGB, GL_UNSIGNED_BYTE, 3},
        {GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, 2}, {GL_LUMINANCE, GL_UNSIGNED_BYTE, 1},
        {GL_ALPHA, GL_UNSIGNED_BYTE, 1},       {GL_RGB, GL_UNSIGNED_SHORT_5_6_5, 2},
        {GL_RGBA, GL_UNSIGNED_SHORT_4_4_4_4, 2},   {GL_RGBA, GL_UNSIGNED_SHORT_5_5_5_1, 2},
        {GL_DEPTH_COMPONENT, GL_UNSIGNED_SHORT, 2}, {GL_DEPTH_COMPONENT, GL_UNSIGNED_INT, 4},
        {GL_DEPTH_STENCIL_OES, GL_UNSIGNED_INT_24_8_OES, 4},
    };
    static const int alignments[] = {1, 2, 4, 8};
    for (size_t k = 0; k < sizeof kinds / sizeof kinds[0]; k++)
        for (int a = 0; a < 4; a++) {
            /* Widths whose rows end between the alignment's multiples. */
            int width = 3 + (int)k % 3, height = 3;
            size_t size;
            uint8_t *tight, *loose = rows(width, height, kinds[k].pixel, alignments[a], &size, &tight);
            glPixelStorei(GL_UNPACK_ALIGNMENT, alignments[a]);
            glTexImage2D(GL_TEXTURE_2D, 1, (GLint)kinds[k].format, width, height, 0, kinds[k].format, kinds[k].type, loose);
            glTexSubImage2D(GL_TEXTURE_2D, 0, 5, 6, width, height, kinds[k].format, kinds[k].type, loose);
            sent();
            expect_data(MGL_TEX_IMAGE_2D, tight, size, 8, GL_TEXTURE_2D, 1, kinds[k].format, width, height, 0, kinds[k].format, kinds[k].type);
            expect_data(MGL_TEX_SUB_IMAGE_2D, tight, size, 8, GL_TEXTURE_2D, 0, 5, 6, width, height, kinds[k].format, kinds[k].type);
            free(loose);
            free(tight);
        }

    /* No pixels yet (NULL): said so, as OpenGL allows; and a cube map's face. */
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 64, 32, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    GLuint cube = 0;
    glGenTextures(1, &cube);
    glBindTexture(GL_TEXTURE_CUBE_MAP, cube);
    static const uint8_t face[4] = {1, 2, 3, 4};
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_CUBE_MAP_NEGATIVE_Y, 0, GL_LUMINANCE, 2, 2, 0, GL_LUMINANCE, GL_UNSIGNED_BYTE, face);
    sent();
    size_t size;
    const uint8_t *args = next_command(MGL_TEX_IMAGE_2D, &size);
    uint32_t last;
    memcpy(&last, args + 32, 4);
    CHECK(size == 36 && last == MWM_GL_NONE);
    expect(MGL_BIND_TEXTURE, 2, GL_TEXTURE_CUBE_MAP, 2);
    expect_data(MGL_TEX_IMAGE_2D, face, 4, 8, GL_TEXTURE_CUBE_MAP_NEGATIVE_Y, 0, GL_LUMINANCE, 2, 2, 0, GL_LUMINANCE, GL_UNSIGNED_BYTE);

    /* What is no picture of OpenGL ES 2.0's: the error is the library's, and the Mac hears nothing. */
    static uint8_t pixels[64];
#define RAISES(call, error) do { call; CHECK(glGetError() == (error)); } while (0)
    RAISES(glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, 2, 2, 0, GL_RGB, GL_UNSIGNED_SHORT_4_4_4_4, pixels), GL_INVALID_OPERATION);
    RAISES(glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 2, 2, 0, GL_RGB, GL_UNSIGNED_BYTE, pixels), GL_INVALID_OPERATION);
    RAISES(glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 2, 2, 0, GL_RGBA, GL_FLOAT, pixels), GL_INVALID_ENUM);
    RAISES(glTexImage2D(GL_TEXTURE_2D, 0, 0x1903, 2, 2, 0, 0x1903, GL_UNSIGNED_BYTE, pixels), GL_INVALID_ENUM);
    RAISES(glTexImage2D(GL_TEXTURE, 0, GL_RGBA, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels), GL_INVALID_ENUM);
    RAISES(glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 2, 2, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixels), GL_INVALID_VALUE);
    RAISES(glTexImage2D(GL_TEXTURE_2D, -1, GL_RGBA, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels), GL_INVALID_VALUE);
    RAISES(glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 4097, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL), GL_INVALID_VALUE);
    RAISES(glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 2, -2, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL), GL_INVALID_VALUE);
    RAISES(glTexImage2D(GL_TEXTURE_CUBE_MAP_POSITIVE_X, 0, GL_RGBA, 2, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels), GL_INVALID_VALUE);
    RAISES(glTexSubImage2D(GL_TEXTURE_2D, 0, -1, 0, 2, 2, GL_RGBA, GL_UNSIGNED_BYTE, pixels), GL_INVALID_VALUE);
    RAISES(glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 2, 2, GL_ALPHA, GL_UNSIGNED_SHORT_5_6_5, pixels), GL_INVALID_OPERATION);
    RAISES(glCompressedTexImage2D(GL_TEXTURE_2D, 0, 0x83F0, 4, 4, 0, 8, pixels), GL_INVALID_ENUM);
    RAISES(glCompressedTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 4, 4, 0x83F0, 8, pixels), GL_INVALID_ENUM);
    RAISES(glBindTexture(GL_TEXTURE_2D, cube), GL_INVALID_OPERATION); /* it is a cube map, for good */
    RAISES(glBindTexture(GL_TEXTURE, 1), GL_INVALID_ENUM);
    RAISES(glActiveTexture(GL_TEXTURE0 + 16), GL_INVALID_ENUM);
    RAISES(glPixelStorei(GL_UNPACK_ALIGNMENT, 3), GL_INVALID_VALUE);
    RAISES(glPixelStorei(GL_TEXTURE_2D, 4), GL_INVALID_ENUM);
    nothing_more();
    finish();
}

/* A vertex of the tests below: where it is, and its colour. */
typedef struct {
    GLfloat x, y;
    GLubyte colour[4];
} vertex;

/* Vertices that are in the program's memory travel with the draw that
 * uses them: as many as it uses, from the first it uses, packed tight.
 * For a draw by indices those are the vertices from the smallest index to
 * the largest, found in the program's indices or in what the library kept
 * of the element buffer. */
static void test_vertices_in_the_programs_memory_travel_with_the_draw(void) {
    WINDOW(window, 300, 200);
    begin(&window);
    (void)gears_program();

    /* Ten vertices and not a byte more: ASan sees a read past the ones a draw uses. */
    enum { VERTICES = 10 };
    vertex *v = malloc(VERTICES * sizeof *v);
    CHECK(v && sizeof *v == 12);
    GLfloat places[VERTICES][2];
    GLubyte colours[VERTICES][4];
    for (int i = 0; i < VERTICES; i++) {
        v[i].x = places[i][0] = (GLfloat)i;
        v[i].y = places[i][1] = (GLfloat)-i / 2;
        for (int k = 0; k < 4; k++) v[i].colour[k] = colours[i][k] = (GLubyte)(i * 10 + k);
    }
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof *v, &v->x);
    glVertexAttribPointer(3, 4, GL_UNSIGNED_BYTE, GL_TRUE, sizeof *v, v->colour);
    glVertexAttribPointer(5, 4, GL_UNSIGNED_BYTE, GL_TRUE, 0, v); /* never enabled: never read */
    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(3);
    void *where = NULL;
    glGetVertexAttribPointerv(3, GL_VERTEX_ATTRIB_ARRAY_POINTER, &where);
    CHECK(where == v->colour);
    sent();
    /* The pointers are the library's to keep: the Mac hears of them at a draw. */
    expect(MGL_ENABLE_VERTEX_ATTRIB_ARRAY, 1, 0);
    expect(MGL_ENABLE_VERTEX_ATTRIB_ARRAY, 1, 3);
    nothing_more();

    glDrawArrays(GL_TRIANGLES, 7, 3);
    sent();
    expect_data(MGL_CLIENT_ARRAY, places[7], 3 * 8, 5, 0, 2, GL_FLOAT, 0, 7);
    expect_data(MGL_CLIENT_ARRAY, colours[7], 3 * 4, 5, 3, 4, GL_UNSIGNED_BYTE, 1, 7);
    expect(MGL_DRAW_ARRAYS, 3, GL_TRIANGLES, 7, 3);

    /* By indices of the program's: vertices 3 to 9, and the indices themselves. */
    static const GLushort shorts[] = {5, 3, 9, 3};
    glDrawElements(GL_TRIANGLE_FAN, 4, GL_UNSIGNED_SHORT, shorts);
    static const GLuint ints[] = {8, 8, 6};
    glDrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_INT, ints);
    sent();
    expect_data(MGL_CLIENT_ARRAY, places[3], 7 * 8, 5, 0, 2, GL_FLOAT, 0, 3);
    expect_data(MGL_CLIENT_ARRAY, colours[3], 7 * 4, 5, 3, 4, GL_UNSIGNED_BYTE, 1, 3);
    expect_data(MGL_DRAW_ELEMENTS_CLIENT, shorts, sizeof shorts, 3, GL_TRIANGLE_FAN, 4, GL_UNSIGNED_SHORT);
    expect_data(MGL_CLIENT_ARRAY, places[6], 3 * 8, 5, 0, 2, GL_FLOAT, 0, 6);
    expect_data(MGL_CLIENT_ARRAY, colours[6], 3 * 4, 5, 3, 4, GL_UNSIGNED_BYTE, 1, 6);
    expect_data(MGL_DRAW_ELEMENTS_CLIENT, ints, sizeof ints, 3, GL_TRIANGLES, 3, GL_UNSIGNED_INT);

    /* By indices in a buffer: the library kept what was put into it, and
     * finds the smallest and the largest of the ones drawn there. */
    GLuint elements = 0;
    static const GLubyte bytes[] = {9, 4, 6, 4, 8, 2}, mended[] = {5, 7};
    glGenBuffers(1, &elements);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, elements);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof bytes, bytes, GL_STATIC_DRAW);
    glDrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_BYTE, OFFSET(1)); /* 4 6 4 */
    glBufferSubData(GL_ELEMENT_ARRAY_BUFFER, 2, sizeof mended, mended);     /* 9 4 5 7 8 2 */
    glDrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_BYTE, OFFSET(1)); /* 4 5 7 */
    sent();
    expect(MGL_BIND_BUFFER, 2, GL_ELEMENT_ARRAY_BUFFER, elements);
    expect_data(MGL_BUFFER_DATA, bytes, sizeof bytes, 3, GL_ELEMENT_ARRAY_BUFFER, 6, GL_STATIC_DRAW);
    expect_data(MGL_CLIENT_ARRAY, places[4], 3 * 8, 5, 0, 2, GL_FLOAT, 0, 4);
    expect_data(MGL_CLIENT_ARRAY, colours[4], 3 * 4, 5, 3, 4, GL_UNSIGNED_BYTE, 1, 4);
    expect(MGL_DRAW_ELEMENTS, 4, GL_TRIANGLES, 3, GL_UNSIGNED_BYTE, 1);
    expect_data(MGL_BUFFER_SUB_DATA, mended, sizeof mended, 2, GL_ELEMENT_ARRAY_BUFFER, 2);
    expect_data(MGL_CLIENT_ARRAY, places[4], 4 * 8, 5, 0, 2, GL_FLOAT, 0, 4);
    expect_data(MGL_CLIENT_ARRAY, colours[4], 4 * 4, 5, 3, 4, GL_UNSIGNED_BYTE, 1, 4);
    expect(MGL_DRAW_ELEMENTS, 4, GL_TRIANGLES, 3, GL_UNSIGNED_BYTE, 1);
    /* Indices that are not in the buffer, and a buffer made with no data (zeros): no draw, and one of vertex 0. */
    RAISES(glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_BYTE, OFFSET(1)), GL_INVALID_OPERATION);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, 4, NULL, GL_DYNAMIC_DRAW);
    glDrawElements(GL_POINTS, 2, GL_UNSIGNED_SHORT, NULL);
    sent();
    size_t size;
    (void)next_command(MGL_BUFFER_DATA, &size);
    CHECK(size == 16);
    expect_data(MGL_CLIENT_ARRAY, places[0], 8, 5, 0, 2, GL_FLOAT, 0, 0);
    expect_data(MGL_CLIENT_ARRAY, colours[0], 4, 5, 3, 4, GL_UNSIGNED_BYTE, 1, 0);
    expect(MGL_DRAW_ELEMENTS, 4, GL_POINTS, 2, GL_UNSIGNED_SHORT, 0);

    /* A buffer filled before it was ever an element buffer: what is in it was not kept, and such a draw cannot be. */
    GLuint late = 0;
    glGenBuffers(1, &late);
    glBindBuffer(GL_ARRAY_BUFFER, late);
    glBufferData(GL_ARRAY_BUFFER, sizeof bytes, bytes, GL_STATIC_DRAW);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, late);
    RAISES(glDrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_BYTE, NULL), GL_INVALID_OPERATION);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof bytes, bytes, GL_STATIC_DRAW); /* filled again: kept now */
    glDrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_BYTE, NULL);
    sent();
    expect(MGL_BIND_BUFFER, 2, GL_ARRAY_BUFFER, late);
    expect_data(MGL_BUFFER_DATA, bytes, sizeof bytes, 3, GL_ARRAY_BUFFER, 6, GL_STATIC_DRAW);
    expect(MGL_BIND_BUFFER, 2, GL_ARRAY_BUFFER, 0);
    expect(MGL_BIND_BUFFER, 2, GL_ELEMENT_ARRAY_BUFFER, late);
    expect_data(MGL_BUFFER_DATA, bytes, sizeof bytes, 3, GL_ELEMENT_ARRAY_BUFFER, 6, GL_STATIC_DRAW);
    expect_data(MGL_CLIENT_ARRAY, places[4], 6 * 8, 5, 0, 2, GL_FLOAT, 0, 4);
    expect_data(MGL_CLIENT_ARRAY, colours[4], 6 * 4, 5, 3, 4, GL_UNSIGNED_BYTE, 1, 4);
    expect(MGL_DRAW_ELEMENTS, 4, GL_TRIANGLES, 3, GL_UNSIGNED_BYTE, 0);

    /* One array in a buffer and one in memory: the pointer into the buffer is sent when it is set, and only the other travels. */
    GLuint buffer = 0;
    glGenBuffers(1, &buffer);
    glBindBuffer(GL_ARRAY_BUFFER, buffer);
    glBufferData(GL_ARRAY_BUFFER, VERTICES * sizeof *v, NULL, GL_STREAM_DRAW);
    glBufferSubData(GL_ARRAY_BUFFER, 24, 2 * sizeof *v, v + 2);
    glVertexAttribPointer(3, 4, GL_UNSIGNED_BYTE, GL_TRUE, sizeof *v, OFFSET(8));
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
    glDrawArrays(GL_LINE_STRIP, 0, 2);
    GLint value = 0;
    glGetVertexAttribiv(3, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &value);
    CHECK(value == (GLint)buffer);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &value);
    CHECK(value == 0);
    sent();
    expect(MGL_BIND_BUFFER, 2, GL_ARRAY_BUFFER, buffer);
    (void)next_command(MGL_BUFFER_DATA, &size);
    expect_data(MGL_BUFFER_SUB_DATA, v + 2, 24, 2, GL_ARRAY_BUFFER, 24);
    expect(MGL_VERTEX_ATTRIB_POINTER, 6, 3, 4, GL_UNSIGNED_BYTE, 1, 12, 8);
    expect(MGL_BIND_BUFFER, 2, GL_ARRAY_BUFFER, 0);
    expect(MGL_BIND_BUFFER, 2, GL_ELEMENT_ARRAY_BUFFER, 0);
    expect_data(MGL_CLIENT_ARRAY, places[0], 2 * 8, 5, 0, 2, GL_FLOAT, 0, 0);
    expect(MGL_DRAW_ARRAYS, 3, GL_LINE_STRIP, 0, 2);

    /* The buffer deleted: its array has nowhere to come from, and a draw sends none for it (and reads no memory at 8). */
    glDeleteBuffers(1, &buffer);
    CHECK(!glIsBuffer(buffer));
    glGetVertexAttribiv(3, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &value);
    CHECK(value == 0);
    glDisableVertexAttribArray(0);
    glDrawArrays(GL_POINTS, 0, 1);
    /* No array in memory at all, indices in memory: the indices go, and nothing else. */
    glDrawElements(GL_LINES, 2, GL_UNSIGNED_BYTE, bytes);
    /* A draw of nothing is nothing; one that is none is an error here. */
    glDrawArrays(GL_POINTS, 0, 0);
    glDrawElements(GL_POINTS, 0, GL_UNSIGNED_BYTE, bytes);
    RAISES(glDrawArrays(7, 0, 3), GL_INVALID_ENUM);
    RAISES(glDrawArrays(GL_POINTS, -1, 3), GL_INVALID_VALUE);
    RAISES(glDrawArrays(GL_POINTS, 0, -3), GL_INVALID_VALUE);
    RAISES(glDrawElements(GL_POINTS, 1, GL_FLOAT, bytes), GL_INVALID_ENUM);
    RAISES(glDrawElements(GL_POINTS, -1, GL_UNSIGNED_BYTE, bytes), GL_INVALID_VALUE);
    RAISES(glVertexAttribPointer(16, 2, GL_FLOAT, GL_FALSE, 0, v), GL_INVALID_VALUE);
    RAISES(glVertexAttribPointer(0, 5, GL_FLOAT, GL_FALSE, 0, v), GL_INVALID_VALUE);
    RAISES(glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, -4, v), GL_INVALID_VALUE);
    RAISES(glVertexAttribPointer(0, 2, GL_UNSIGNED_INT, GL_FALSE, 0, v), GL_INVALID_ENUM);
    sent();
    expect_data(MGL_DELETE_BUFFERS, &buffer, 4, 1, 1);
    expect(MGL_DISABLE_VERTEX_ATTRIB_ARRAY, 1, 0);
    expect(MGL_DRAW_ARRAYS, 3, GL_POINTS, 0, 1);
    expect_data(MGL_DRAW_ELEMENTS_CLIENT, bytes, 2, 3, GL_LINES, 2, GL_UNSIGNED_BYTE);
    nothing_more();
    free(v);
    finish();
}

/* What a program asks of the state is answered here, from what its own
 * calls made it: every call below that sets something is one command, and
 * not one of the questions is. */
static void test_what_a_program_asks_is_answered_without_the_mac(void) {
    WINDOW(window, 300, 200);
    begin(&window);
    GLint i[4] = {77, 77, 77, 77};
    GLfloat f[4] = {0};
    GLboolean b[4] = {0};

    /* What the library is, and how much of everything there is. */
    CHECK(strcmp((const char *)glGetString(GL_VENDOR), "Monad") == 0);
    CHECK(strcmp((const char *)glGetString(GL_RENDERER), "Monad (Metal)") == 0);
    CHECK(strcmp((const char *)glGetString(GL_VERSION), "OpenGL ES 2.0 Monad") == 0);
    CHECK(strcmp((const char *)glGetString(GL_SHADING_LANGUAGE_VERSION), "OpenGL ES GLSL ES 1.00") == 0);
    CHECK(strcmp((const char *)glGetString(GL_EXTENSIONS),
                 "GL_OES_standard_derivatives GL_OES_depth24 GL_OES_packed_depth_stencil GL_OES_rgb8_rgba8 GL_OES_element_index_uint") == 0);
    static const struct {
        GLenum name;
        GLint value;
    } limits[] = {
        {GL_MAX_TEXTURE_SIZE, 4096},      {GL_MAX_CUBE_MAP_TEXTURE_SIZE, 4096},      {GL_MAX_VERTEX_ATTRIBS, 16},
        {GL_MAX_VERTEX_UNIFORM_VECTORS, 256}, {GL_MAX_FRAGMENT_UNIFORM_VECTORS, 256},   {GL_MAX_VARYING_VECTORS, 15},
        {GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS, 16}, {GL_MAX_TEXTURE_IMAGE_UNITS, 16},   {GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS, 16},
        {GL_MAX_RENDERBUFFER_SIZE, 4096}, {GL_NUM_COMPRESSED_TEXTURE_FORMATS, 0},    {GL_NUM_SHADER_BINARY_FORMATS, 0},
        {GL_DEPTH_BITS, 24},              {GL_STENCIL_BITS, 8},                      {GL_RED_BITS, 8},
        {GL_GREEN_BITS, 8},               {GL_BLUE_BITS, 8},                         {GL_ALPHA_BITS, 8},
        {GL_SAMPLES, 0},                  {GL_SAMPLE_BUFFERS, 0},                    {GL_SUBPIXEL_BITS, 4},
        {GL_IMPLEMENTATION_COLOR_READ_FORMAT, GL_RGBA}, {GL_IMPLEMENTATION_COLOR_READ_TYPE, GL_UNSIGNED_BYTE},
        {GL_SHADER_COMPILER, 1},
        /* A context's first values. */
        {GL_ACTIVE_TEXTURE, GL_TEXTURE0}, {GL_PACK_ALIGNMENT, 4},                    {GL_UNPACK_ALIGNMENT, 4},
        {GL_DEPTH_FUNC, GL_LESS},         {GL_FRONT_FACE, GL_CCW},                   {GL_CULL_FACE_MODE, GL_BACK},
        {GL_BLEND_SRC_RGB, GL_ONE},       {GL_BLEND_DST_ALPHA, GL_ZERO},             {GL_BLEND_EQUATION_RGB, GL_FUNC_ADD},
        {GL_STENCIL_FUNC, GL_ALWAYS},     {GL_STENCIL_VALUE_MASK, -1},               {GL_STENCIL_BACK_WRITEMASK, -1},
        {GL_STENCIL_FAIL, GL_KEEP},       {GL_STENCIL_BACK_PASS_DEPTH_PASS, GL_KEEP}, {GL_GENERATE_MIPMAP_HINT, GL_DONT_CARE},
        {GL_DEPTH_CLEAR_VALUE, INT_MAX},  {GL_DITHER, 1},                            {GL_DEPTH_WRITEMASK, 1},
        {GL_CURRENT_PROGRAM, 0},          {GL_ARRAY_BUFFER_BINDING, 0},              {GL_TEXTURE_BINDING_2D, 0},
    };
    for (size_t k = 0; k < sizeof limits / sizeof limits[0]; k++) {
        glGetIntegerv(limits[k].name, i);
        if (i[0] != limits[k].value) fprintf(stderr, "0x%x is %d\n", limits[k].name, i[0]);
        CHECK(i[0] == limits[k].value && i[1] == 77);
    }
    glGetIntegerv(GL_MAX_VIEWPORT_DIMS, i);
    CHECK(i[0] == 4096 && i[1] == 4096 && i[2] == 77);
    i[0] = i[1] = 77;
    glGetIntegerv(GL_COMPRESSED_TEXTURE_FORMATS, i); /* none: nothing written */
    glGetIntegerv(GL_SHADER_BINARY_FORMATS, i);
    CHECK(i[0] == 77);
    /* The viewport and the scissor box begin as the window. */
    glGetIntegerv(GL_VIEWPORT, i);
    CHECK(i[0] == 0 && i[1] == 0 && i[2] == 300 && i[3] == 200);
    glGetIntegerv(GL_SCISSOR_BOX, i);
    CHECK(i[0] == 0 && i[1] == 0 && i[2] == 300 && i[3] == 200);
    glGetFloatv(GL_ALIASED_LINE_WIDTH_RANGE, f);
    CHECK(f[0] == 1 && f[1] == 1);
    glGetFloatv(GL_DEPTH_RANGE, f);
    CHECK(f[0] == 0 && f[1] == 1);
    glGetBooleanv(GL_COLOR_WRITEMASK, b);
    CHECK(b[0] == GL_TRUE && b[1] == GL_TRUE && b[2] == GL_TRUE && b[3] == GL_TRUE);
    CHECK(glIsEnabled(GL_DITHER) && !glIsEnabled(GL_BLEND) && !glIsEnabled(GL_DEPTH_TEST) && !glIsEnabled(GL_SCISSOR_TEST));
    GLint range[2] = {0}, precision = -1;
    glGetShaderPrecisionFormat(GL_FRAGMENT_SHADER, GL_HIGH_FLOAT, range, &precision);
    CHECK(range[0] == 127 && range[1] == 127 && precision == 23);
    glGetShaderPrecisionFormat(GL_VERTEX_SHADER, GL_LOW_INT, range, &precision);
    CHECK(range[0] == 31 && range[1] == 30 && precision == 0);
    nothing_more();

    /* Set, and asked. */
    glViewport(10, 20, 30, 40);
    glScissor(1, 2, 3, 4);
    glClearColor(0.25f, 0.5f, 2, -1);
    glClearDepthf(0.5f);
    glClearStencil(7);
    glColorMask(GL_TRUE, GL_FALSE, 5, GL_FALSE);
    glDepthMask(GL_FALSE);
    glDepthFunc(GL_GEQUAL);
    glDepthRangef(0.25f, 0.75f);
    glEnable(GL_SCISSOR_TEST);
    glEnable(GL_POLYGON_OFFSET_FILL);
    glDisable(GL_DITHER);
    glCullFace(GL_FRONT_AND_BACK);
    glFrontFace(GL_CW);
    glLineWidth(2.5f);
    glPolygonOffset(1.5f, -2);
    glSampleCoverage(0.75f, GL_TRUE);
    glBlendColor(0.5f, 0.25f, 0, 1);
    glBlendEquation(GL_FUNC_SUBTRACT);
    glBlendEquationSeparate(GL_FUNC_ADD, GL_FUNC_REVERSE_SUBTRACT);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glBlendFuncSeparate(GL_SRC_ALPHA_SATURATE, GL_DST_COLOR, GL_CONSTANT_ALPHA, GL_ONE);
    glStencilFunc(GL_EQUAL, 300, 0x0f);
    glStencilFuncSeparate(GL_BACK, GL_NOTEQUAL, 2, 0xf0);
    glStencilMask(0x3c);
    glStencilMaskSeparate(GL_FRONT, 0xc3);
    glStencilOp(GL_REPLACE, GL_INCR, GL_DECR_WRAP);
    glStencilOpSeparate(GL_BACK, GL_INVERT, GL_ZERO, GL_INCR_WRAP);
    glPixelStorei(GL_PACK_ALIGNMENT, 8);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 2);
    glHint(GL_GENERATE_MIPMAP_HINT, GL_NICEST);
    glVertexAttrib1f(2, 9);
    glVertexAttrib2fv(4, (const GLfloat[]){1, 2});
    glVertexAttrib3f(5, 1, 2, 3);
    glVertexAttrib4fv(6, (const GLfloat[]){4, 3, 2, 1});
    glVertexAttrib1fv(7, (const GLfloat[]){8});
    glVertexAttrib2f(8, 7, 6);
    glVertexAttrib3fv(9, (const GLfloat[]){5, 4, 3});
    glVertexAttrib4f(10, 0.5f, 0.25f, 0.125f, 0);

    glGetIntegerv(GL_VIEWPORT, i);
    CHECK(i[0] == 10 && i[1] == 20 && i[2] == 30 && i[3] == 40);
    glGetFloatv(GL_SCISSOR_BOX, f);
    CHECK(f[0] == 1 && f[1] == 2 && f[2] == 3 && f[3] == 4);
    glGetFloatv(GL_COLOR_CLEAR_VALUE, f); /* kept between 0 and 1, as OpenGL keeps it */
    CHECK(f[0] == 0.25f && f[1] == 0.5f && f[2] == 1 && f[3] == 0);
    glGetIntegerv(GL_COLOR_CLEAR_VALUE, i); /* a colour as an integer: that part of its whole range */
    CHECK(i[0] == 536870912 && i[1] == 1073741824 && i[2] == INT_MAX && i[3] == 0);
    glGetFloatv(GL_DEPTH_CLEAR_VALUE, f);
    CHECK(f[0] == 0.5f);
    glGetIntegerv(GL_STENCIL_CLEAR_VALUE, i);
    CHECK(i[0] == 7);
    glGetBooleanv(GL_COLOR_WRITEMASK, b);
    CHECK(b[0] == GL_TRUE && b[1] == GL_FALSE && b[2] == GL_TRUE && b[3] == GL_FALSE);
    glGetBooleanv(GL_DEPTH_WRITEMASK, b);
    CHECK(b[0] == GL_FALSE);
    glGetIntegerv(GL_DEPTH_FUNC, i);
    CHECK(i[0] == GL_GEQUAL);
    glGetFloatv(GL_DEPTH_RANGE, f);
    CHECK(f[0] == 0.25f && f[1] == 0.75f);
    CHECK(glIsEnabled(GL_SCISSOR_TEST) && glIsEnabled(GL_POLYGON_OFFSET_FILL) && !glIsEnabled(GL_DITHER));
    glGetBooleanv(GL_SCISSOR_TEST, b);
    CHECK(b[0] == GL_TRUE);
    glGetIntegerv(GL_CULL_FACE_MODE, i);
    CHECK(i[0] == GL_FRONT_AND_BACK);
    glGetIntegerv(GL_FRONT_FACE, i);
    CHECK(i[0] == GL_CW);
    glGetFloatv(GL_LINE_WIDTH, f);
    CHECK(f[0] == 2.5f);
    glGetIntegerv(GL_LINE_WIDTH, i); /* a float as an integer: the nearest */
    CHECK(i[0] == 3);
    glGetFloatv(GL_POLYGON_OFFSET_FACTOR, f);
    glGetFloatv(GL_POLYGON_OFFSET_UNITS, f + 1);
    CHECK(f[0] == 1.5f && f[1] == -2);
    glGetFloatv(GL_SAMPLE_COVERAGE_VALUE, f);
    glGetBooleanv(GL_SAMPLE_COVERAGE_INVERT, b);
    CHECK(f[0] == 0.75f && b[0] == GL_TRUE);
    glGetFloatv(GL_BLEND_COLOR, f);
    CHECK(f[0] == 0.5f && f[1] == 0.25f && f[2] == 0 && f[3] == 1);
    glGetIntegerv(GL_BLEND_EQUATION_RGB, i);
    glGetIntegerv(GL_BLEND_EQUATION_ALPHA, i + 1);
    CHECK(i[0] == GL_FUNC_ADD && i[1] == GL_FUNC_REVERSE_SUBTRACT);
    glGetIntegerv(GL_BLEND_SRC_RGB, i);
    glGetIntegerv(GL_BLEND_DST_RGB, i + 1);
    glGetIntegerv(GL_BLEND_SRC_ALPHA, i + 2);
    glGetIntegerv(GL_BLEND_DST_ALPHA, i + 3);
    CHECK(i[0] == GL_SRC_ALPHA_SATURATE && i[1] == GL_DST_COLOR && i[2] == GL_CONSTANT_ALPHA && i[3] == GL_ONE);
    glGetIntegerv(GL_STENCIL_FUNC, i);
    glGetIntegerv(GL_STENCIL_REF, i + 1); /* kept to what eight bits hold */
    glGetIntegerv(GL_STENCIL_VALUE_MASK, i + 2);
    glGetIntegerv(GL_STENCIL_WRITEMASK, i + 3);
    CHECK(i[0] == GL_EQUAL && i[1] == 255 && i[2] == 0x0f && i[3] == 0xc3);
    glGetIntegerv(GL_STENCIL_BACK_FUNC, i);
    glGetIntegerv(GL_STENCIL_BACK_REF, i + 1);
    glGetIntegerv(GL_STENCIL_BACK_VALUE_MASK, i + 2);
    glGetIntegerv(GL_STENCIL_BACK_WRITEMASK, i + 3);
    CHECK(i[0] == GL_NOTEQUAL && i[1] == 2 && i[2] == 0xf0 && i[3] == 0x3c);
    glGetIntegerv(GL_STENCIL_FAIL, i);
    glGetIntegerv(GL_STENCIL_PASS_DEPTH_FAIL, i + 1);
    glGetIntegerv(GL_STENCIL_PASS_DEPTH_PASS, i + 2);
    CHECK(i[0] == GL_REPLACE && i[1] == GL_INCR && i[2] == GL_DECR_WRAP);
    glGetIntegerv(GL_STENCIL_BACK_FAIL, i);
    glGetIntegerv(GL_STENCIL_BACK_PASS_DEPTH_FAIL, i + 1);
    glGetIntegerv(GL_STENCIL_BACK_PASS_DEPTH_PASS, i + 2);
    CHECK(i[0] == GL_INVERT && i[1] == GL_ZERO && i[2] == GL_INCR_WRAP);
    glGetIntegerv(GL_PACK_ALIGNMENT, i);
    glGetIntegerv(GL_UNPACK_ALIGNMENT, i + 1);
    glGetIntegerv(GL_GENERATE_MIPMAP_HINT, i + 2);
    CHECK(i[0] == 8 && i[1] == 2 && i[2] == GL_NICEST);
    glGetVertexAttribfv(2, GL_CURRENT_VERTEX_ATTRIB, f);
    CHECK(f[0] == 9 && f[1] == 0 && f[2] == 0 && f[3] == 1);
    glGetVertexAttribfv(4, GL_CURRENT_VERTEX_ATTRIB, f);
    CHECK(f[0] == 1 && f[1] == 2 && f[2] == 0 && f[3] == 1);
    glGetVertexAttribiv(6, GL_CURRENT_VERTEX_ATTRIB, i);
    CHECK(i[0] == 4 && i[1] == 3 && i[2] == 2 && i[3] == 1);
    glGetVertexAttribfv(0, GL_CURRENT_VERTEX_ATTRIB, f);
    CHECK(f[0] == 0 && f[1] == 0 && f[2] == 0 && f[3] == 1);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_SIZE, i);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_TYPE, i + 1);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_ENABLED, i + 2);
    CHECK(i[0] == 4 && i[1] == GL_FLOAT && i[2] == 0);
    sent();
    expect(MGL_VIEWPORT, 4, 10, 20, 30, 40);
    expect(MGL_SCISSOR, 4, 1, 2, 3, 4);
    expect(MGL_CLEAR_COLOR, 4, f32(0.25f), f32(0.5f), f32(2), f32(-1)); /* as the program said it: the Mac keeps it in range too */
    expect(MGL_CLEAR_DEPTHF, 1, f32(0.5f));
    expect(MGL_CLEAR_STENCIL, 1, 7);
    expect(MGL_COLOR_MASK, 4, 1, 0, 1, 0);
    expect(MGL_DEPTH_MASK, 1, 0);
    expect(MGL_DEPTH_FUNC, 1, GL_GEQUAL);
    expect(MGL_DEPTH_RANGEF, 2, f32(0.25f), f32(0.75f));
    expect(MGL_ENABLE, 1, GL_SCISSOR_TEST);
    expect(MGL_ENABLE, 1, GL_POLYGON_OFFSET_FILL);
    expect(MGL_DISABLE, 1, GL_DITHER);
    expect(MGL_CULL_FACE, 1, GL_FRONT_AND_BACK);
    expect(MGL_FRONT_FACE, 1, GL_CW);
    expect(MGL_LINE_WIDTH, 1, f32(2.5f));
    expect(MGL_POLYGON_OFFSET, 2, f32(1.5f), f32(-2));
    expect(MGL_SAMPLE_COVERAGE, 2, f32(0.75f), 1);
    expect(MGL_BLEND_COLOR, 4, f32(0.5f), f32(0.25f), f32(0), f32(1));
    expect(MGL_BLEND_EQUATION, 1, GL_FUNC_SUBTRACT);
    expect(MGL_BLEND_EQUATION_SEPARATE, 2, GL_FUNC_ADD, GL_FUNC_REVERSE_SUBTRACT);
    expect(MGL_BLEND_FUNC, 2, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    expect(MGL_BLEND_FUNC_SEPARATE, 4, GL_SRC_ALPHA_SATURATE, GL_DST_COLOR, GL_CONSTANT_ALPHA, GL_ONE);
    expect(MGL_STENCIL_FUNC, 3, GL_EQUAL, 300, 0x0f);
    expect(MGL_STENCIL_FUNC_SEPARATE, 4, GL_BACK, GL_NOTEQUAL, 2, 0xf0);
    expect(MGL_STENCIL_MASK, 1, 0x3c);
    expect(MGL_STENCIL_MASK_SEPARATE, 2, GL_FRONT, 0xc3);
    expect(MGL_STENCIL_OP, 3, GL_REPLACE, GL_INCR, GL_DECR_WRAP);
    expect(MGL_STENCIL_OP_SEPARATE, 4, GL_BACK, GL_INVERT, GL_ZERO, GL_INCR_WRAP);
    /* glPixelStorei and glHint are the library's own. Every glVertexAttrib goes as the four floats it comes to. */
    expect(MGL_VERTEX_ATTRIB_4F, 5, 2, f32(9), f32(0), f32(0), f32(1));
    expect(MGL_VERTEX_ATTRIB_4F, 5, 4, f32(1), f32(2), f32(0), f32(1));
    expect(MGL_VERTEX_ATTRIB_4F, 5, 5, f32(1), f32(2), f32(3), f32(1));
    expect(MGL_VERTEX_ATTRIB_4F, 5, 6, f32(4), f32(3), f32(2), f32(1));
    expect(MGL_VERTEX_ATTRIB_4F, 5, 7, f32(8), f32(0), f32(0), f32(1));
    expect(MGL_VERTEX_ATTRIB_4F, 5, 8, f32(7), f32(6), f32(0), f32(1));
    expect(MGL_VERTEX_ATTRIB_4F, 5, 9, f32(5), f32(4), f32(3), f32(1));
    expect(MGL_VERTEX_ATTRIB_4F, 5, 10, f32(0.5f), f32(0.25f), f32(0.125f), f32(0));
    nothing_more();

    /* Textures: what is bound to each unit, and how each is sampled. */
    GLuint textures[2] = {0};
    glGenTextures(2, textures);
    glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, i); /* texture 0 is one too */
    CHECK(i[0] == GL_NEAREST_MIPMAP_LINEAR);
    glActiveTexture(GL_TEXTURE5);
    glBindTexture(GL_TEXTURE_2D, textures[0]);
    glBindTexture(GL_TEXTURE_CUBE_MAP, textures[1]);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteriv(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_S, (const GLint[]){GL_CLAMP_TO_EDGE});
    glTexParameterfv(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_T, (const GLfloat[]){GL_MIRRORED_REPEAT});
    glGenerateMipmap(GL_TEXTURE_2D);
    glCopyTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, 1, 2, 16, 8, 0);
    glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 3, 4, 5, 6, 7, 8);
    glGetIntegerv(GL_ACTIVE_TEXTURE, i);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, i + 1);
    glGetIntegerv(GL_TEXTURE_BINDING_CUBE_MAP, i + 2);
    CHECK(i[0] == GL_TEXTURE5 && i[1] == (GLint)textures[0] && i[2] == (GLint)textures[1]);
    glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, i);
    glGetTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, f);
    glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, i + 1);
    CHECK(i[0] == GL_LINEAR && f[0] == GL_NEAREST && i[1] == GL_REPEAT);
    glGetTexParameteriv(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_S, i);
    glGetTexParameteriv(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_T, i + 1);
    glGetTexParameteriv(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MAG_FILTER, i + 2);
    CHECK(i[0] == GL_CLAMP_TO_EDGE && i[1] == GL_MIRRORED_REPEAT && i[2] == GL_LINEAR);
    glActiveTexture(GL_TEXTURE0);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, i); /* another unit's */
    CHECK(i[0] == 0);
    sent();
    expect(MGL_ACTIVE_TEXTURE, 1, GL_TEXTURE5);
    expect(MGL_BIND_TEXTURE, 2, GL_TEXTURE_2D, textures[0]);
    expect(MGL_BIND_TEXTURE, 2, GL_TEXTURE_CUBE_MAP, textures[1]);
    expect(MGL_TEX_PARAMETERI, 3, GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    expect(MGL_TEX_PARAMETERF, 3, GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, f32(GL_NEAREST));
    expect(MGL_TEX_PARAMETERI, 3, GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    expect(MGL_TEX_PARAMETERF, 3, GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_T, f32(GL_MIRRORED_REPEAT));
    expect(MGL_GENERATE_MIPMAP, 1, GL_TEXTURE_2D);
    expect(MGL_COPY_TEX_IMAGE_2D, 8, GL_TEXTURE_2D, 0, GL_RGB, 1, 2, 16, 8, 0);
    expect(MGL_COPY_TEX_SUB_IMAGE_2D, 8, GL_TEXTURE_2D, 0, 3, 4, 5, 6, 7, 8);
    expect(MGL_ACTIVE_TEXTURE, 1, GL_TEXTURE0);
    nothing_more();

    /* Buffers. */
    GLuint buffers[2] = {0};
    glGenBuffers(2, buffers);
    CHECK(buffers[0] == 1 && buffers[1] == 2);
    glBindBuffer(GL_ARRAY_BUFFER, buffers[0]);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, buffers[1]);
    glBufferData(GL_ARRAY_BUFFER, 1000, NULL, GL_DYNAMIC_DRAW);
    glGetIntegerv(GL_ARRAY_BUFFER_BINDING, i);
    glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, i + 1);
    CHECK(i[0] == 1 && i[1] == 2);
    glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_SIZE, i);
    glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_USAGE, i + 1);
    glGetBufferParameteriv(GL_ELEMENT_ARRAY_BUFFER, GL_BUFFER_SIZE, i + 2);
    glGetBufferParameteriv(GL_ELEMENT_ARRAY_BUFFER, GL_BUFFER_USAGE, i + 3);
    CHECK(i[0] == 1000 && i[1] == GL_DYNAMIC_DRAW && i[2] == 0 && i[3] == GL_STATIC_DRAW);
    glVertexAttribPointer(1, 2, GL_SHORT, GL_TRUE, 16, OFFSET(4));
    glEnableVertexAttribArray(1);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_SIZE, i);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_TYPE, i + 1);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_STRIDE, i + 2);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, i + 3);
    CHECK(i[0] == 2 && i[1] == GL_SHORT && i[2] == 16 && i[3] == 1);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_NORMALIZED, i);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_ENABLED, i + 1);
    void *where = &i;
    glGetVertexAttribPointerv(1, GL_VERTEX_ATTRIB_ARRAY_POINTER, &where);
    CHECK(i[0] == 1 && i[1] == 1 && where == OFFSET(4));
    sent();
    expect(MGL_BIND_BUFFER, 2, GL_ARRAY_BUFFER, 1);
    expect(MGL_BIND_BUFFER, 2, GL_ELEMENT_ARRAY_BUFFER, 2);
    size_t size;
    const uint8_t *args = next_command(MGL_BUFFER_DATA, &size);
    uint32_t words[4];
    memcpy(words, args, 16);
    CHECK(size == 16 && words[0] == GL_ARRAY_BUFFER && words[1] == 1000 && words[2] == GL_DYNAMIC_DRAW && words[3] == MWM_GL_NONE);
    expect(MGL_VERTEX_ATTRIB_POINTER, 6, 1, 2, GL_SHORT, 1, 16, 4);
    expect(MGL_ENABLE_VERTEX_ATTRIB_ARRAY, 1, 1);
    nothing_more();

    /* Framebuffers and renderbuffers. */
    GLuint framebuffer = 0, renderbuffers[2] = {0};
    glGenFramebuffers(1, &framebuffer);
    glGenRenderbuffers(2, renderbuffers);
    CHECK(!glIsFramebuffer(framebuffer) && !glIsRenderbuffer(renderbuffers[0]));
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, renderbuffers[0]);
    CHECK(glIsFramebuffer(framebuffer) && glIsRenderbuffer(renderbuffers[0]) && !glIsRenderbuffer(renderbuffers[1]));
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8_OES, 128, 64);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, renderbuffers[0]);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, renderbuffers[0]);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_CUBE_MAP_POSITIVE_Z, textures[1], 0);
    HOST(host.status = GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT);
    CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT); /* the Mac's to say */
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, i);
    glGetIntegerv(GL_RENDERBUFFER_BINDING, i + 1);
    CHECK(i[0] == (GLint)framebuffer && i[1] == (GLint)renderbuffers[0]);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, i);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, i + 1);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_INTERNAL_FORMAT, i + 2);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_DEPTH_SIZE, i + 3);
    CHECK(i[0] == 128 && i[1] == 64 && i[2] == GL_DEPTH24_STENCIL8_OES && i[3] == 24);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_STENCIL_SIZE, i);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_RED_SIZE, i + 1);
    CHECK(i[0] == 8 && i[1] == 0);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, i);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, i + 1);
    CHECK(i[0] == GL_RENDERBUFFER && i[1] == (GLint)renderbuffers[0]);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, i);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, i + 1);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE, i + 2);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL, i + 3);
    CHECK(i[0] == GL_TEXTURE && i[1] == (GLint)textures[1] && i[2] == GL_TEXTURE_CUBE_MAP_POSITIVE_Z && i[3] == 0);
    /* What is deleted is bound and attached no more. */
    glDeleteTextures(2, textures);
    glDeleteRenderbuffers(1, renderbuffers);
    CHECK(!glIsTexture(textures[0]) && !glIsRenderbuffer(renderbuffers[0]));
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, i);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, i + 1);
    glGetIntegerv(GL_RENDERBUFFER_BINDING, i + 2);
    CHECK(i[0] == GL_NONE && i[1] == GL_NONE && i[2] == 0);
    glActiveTexture(GL_TEXTURE5);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, i);
    glGetIntegerv(GL_TEXTURE_BINDING_CUBE_MAP, i + 1);
    CHECK(i[0] == 0 && i[1] == 0);
    glDeleteFramebuffers(1, &framebuffer);
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, i);
    CHECK(i[0] == 0 && !glIsFramebuffer(framebuffer));
    /* A name the library gave out is not given again while it is in use; one deleted may be. */
    GLuint more[2] = {0};
    glGenRenderbuffers(2, more);
    CHECK(more[0] == 3 && more[1] == 4);
    glBindBuffer(GL_ARRAY_BUFFER, 3); /* a name of the program's own choosing */
    glGenBuffers(1, more);
    CHECK(more[0] == 4);
    sent();
    expect(MGL_BIND_FRAMEBUFFER, 2, GL_FRAMEBUFFER, framebuffer);
    expect(MGL_BIND_RENDERBUFFER, 2, GL_RENDERBUFFER, renderbuffers[0]);
    expect(MGL_RENDERBUFFER_STORAGE, 4, GL_RENDERBUFFER, GL_DEPTH24_STENCIL8_OES, 128, 64);
    expect(MGL_FRAMEBUFFER_RENDERBUFFER, 4, GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, renderbuffers[0]);
    expect(MGL_FRAMEBUFFER_RENDERBUFFER, 4, GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, renderbuffers[0]);
    expect(MGL_FRAMEBUFFER_TEXTURE_2D, 5, GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_CUBE_MAP_POSITIVE_Z, textures[1], 0);
    expect(MGL_CHECK_FRAMEBUFFER_STATUS, 1, GL_FRAMEBUFFER);
    expect_data(MGL_DELETE_TEXTURES, textures, 8, 1, 2);
    expect_data(MGL_DELETE_RENDERBUFFERS, renderbuffers, 4, 1, 1);
    expect(MGL_ACTIVE_TEXTURE, 1, GL_TEXTURE5);
    expect_data(MGL_DELETE_FRAMEBUFFERS, &framebuffer, 4, 1, 1);
    expect(MGL_BIND_BUFFER, 2, GL_ARRAY_BUFFER, 3);
    nothing_more();

    /* A program and its shaders: deleted while in use, they live until they are not. */
    GLuint program = gears_program(), shaders[2] = {0};
    GLsizei count = 0;
    glGetAttachedShaders(program, 2, &count, shaders);
    CHECK(count == 2);
    glDeleteShader(shaders[0]);
    glDeleteProgram(program);
    glDeleteProgram(program); /* said once */
    glGetShaderiv(shaders[0], GL_DELETE_STATUS, i);
    glGetProgramiv(program, GL_DELETE_STATUS, i + 1);
    CHECK(i[0] == GL_TRUE && i[1] == GL_TRUE && glIsProgram(program) && glIsShader(shaders[0]));
    glDetachShader(program, shaders[1]);
    glGetProgramiv(program, GL_ATTACHED_SHADERS, i);
    CHECK(i[0] == 1 && glIsShader(shaders[1]));
    /* Every glUniform, as the header has each. */
    glUniform1f(1, 0.5f);
    glUniform2f(2, 1, 2);
    glUniform3f(3, 1, 2, 3);
    glUniform4f(4, 1, 2, 3, 4);
    glUniform1i(5, -1);
    glUniform2i(6, 1, 2);
    glUniform3i(7, 1, 2, 3);
    glUniform4i(8, 1, 2, 3, 4);
    static const GLfloat floats[18] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18};
    static const GLint ints[8] = {1, -2, 3, -4, 5, -6, 7, -8};
    glUniform1fv(1, 3, floats);
    glUniform2fv(2, 2, floats);
    glUniform3fv(3, 2, floats);
    glUniform4fv(4, 1, floats);
    glUniform1iv(5, 2, ints);
    glUniform2iv(6, 2, ints);
    glUniform3iv(7, 2, ints);
    glUniform4iv(8, 2, ints);
    glUniformMatrix2fv(9, 2, GL_FALSE, floats);
    glUniformMatrix3fv(10, 2, GL_FALSE, floats);
    /* The value of a uniform is the Mac's to tell, as floats or as ints; the program gets it as it asks. */
    body answer = {.len = 0};
    body_u32(&answer, GL_FLOAT_VEC3);
    body_data(&answer, (const GLfloat[]){1.5f, -2.5f, 3}, 12);
    HOST(host.uniform = answer);
    f[3] = 99;
    glGetUniformfv(program, 3, f);
    CHECK(f[0] == 1.5f && f[1] == -2.5f && f[2] == 3 && f[3] == 99);
    i[3] = 77;
    glGetUniformiv(program, 3, i);
    CHECK(i[0] == 2 && i[1] == -3 && i[2] == 3 && i[3] == 77);
    answer.len = 0;
    body_u32(&answer, GL_BOOL_VEC2);
    body_data(&answer, (const GLint[]){1, 0}, 8);
    HOST(host.uniform = answer);
    glGetUniformfv(program, 5, f);
    CHECK(f[0] == 1 && f[1] == 0 && f[2] == 3);
    /* A uniform the Mac has an error for (nothing at that place): no type and data of no bytes. Nothing is written to
     * the program's memory, the stream goes on, and the error is the Mac's to tell. */
    answer.len = 0;
    body_u32(&answer, 0);
    body_data(&answer, NULL, 0);
    HOST(host.uniform = answer; host.error = GL_INVALID_OPERATION);
    f[0] = f[1] = 99;
    i[0] = i[1] = 77;
    glGetUniformfv(program, 4, f);
    glGetUniformiv(program, 4, i);
    CHECK(f[0] == 99 && f[1] == 99 && i[0] == 77 && i[1] == 77);
    CHECK(glGetError() == GL_INVALID_OPERATION && glGetError() == GL_NO_ERROR);
    glUseProgram(0);
    CHECK(!glIsProgram(program) && !glIsShader(shaders[0]) && glIsShader(shaders[1]));
    glDeleteShader(shaders[1]);
    CHECK(!glIsShader(shaders[1]));
    glFinish();
    sent();
    expect(MGL_DELETE_SHADER, 1, shaders[0]);
    expect(MGL_DELETE_PROGRAM, 1, program);
    expect(MGL_DETACH_SHADER, 2, program, shaders[1]);
    expect(MGL_UNIFORM_1F, 2, 1, f32(0.5f));
    expect(MGL_UNIFORM_2F, 3, 2, f32(1), f32(2));
    expect(MGL_UNIFORM_3F, 4, 3, f32(1), f32(2), f32(3));
    expect(MGL_UNIFORM_4F, 5, 4, f32(1), f32(2), f32(3), f32(4));
    expect(MGL_UNIFORM_1I, 2, 5, 0xffffffffu);
    expect(MGL_UNIFORM_2I, 3, 6, 1, 2);
    expect(MGL_UNIFORM_3I, 4, 7, 1, 2, 3);
    expect(MGL_UNIFORM_4I, 5, 8, 1, 2, 3, 4);
    expect_data(MGL_UNIFORM_1FV, floats, 12, 2, 1, 3);
    expect_data(MGL_UNIFORM_2FV, floats, 16, 2, 2, 2);
    expect_data(MGL_UNIFORM_3FV, floats, 24, 2, 3, 2);
    expect_data(MGL_UNIFORM_4FV, floats, 16, 2, 4, 1);
    expect_data(MGL_UNIFORM_1IV, ints, 8, 2, 5, 2);
    expect_data(MGL_UNIFORM_2IV, ints, 16, 2, 6, 2);
    expect_data(MGL_UNIFORM_3IV, ints, 24, 2, 7, 2);
    expect_data(MGL_UNIFORM_4IV, ints, 32, 2, 8, 2);
    expect_data(MGL_UNIFORM_MATRIX_2FV, floats, 32, 2, 9, 2);
    expect_data(MGL_UNIFORM_MATRIX_3FV, floats, 72, 2, 10, 2);
    expect(MGL_GET_UNIFORM, 2, program, 3);
    expect(MGL_GET_UNIFORM, 2, program, 3);
    expect(MGL_GET_UNIFORM, 2, program, 5);
    expect(MGL_GET_UNIFORM, 2, program, 4);
    expect(MGL_GET_UNIFORM, 2, program, 4);
    expect(MGL_GET_ERROR, 0);
    expect(MGL_GET_ERROR, 0);
    expect(MGL_USE_PROGRAM, 1, 0);
    expect(MGL_DELETE_SHADER, 1, shaders[1]);
    expect(MGL_FINISH, 0);
    nothing_more();
    finish();
}

/* glReadPixels asks the Mac for the pixels, tight, and puts them into the
 * program's memory in rows that begin at multiples of GL_PACK_ALIGNMENT,
 * touching nothing between or after them. A read the Mac has an error
 * for is answered with nothing, and nothing is written. */
static void test_read_pixels_honours_the_pack_alignment(void) {
    WINDOW(window, 300, 200);
    begin(&window);
    static const int alignments[] = {1, 2, 4, 8};
    for (int a = 0; a < 4; a++) {
        enum { WIDE = 3, HIGH = 2 };
        size_t row = WIDE * 4, stride = alignments[a] == 8 ? 16 : 12, size = stride * (HIGH - 1) + row;
        /* Exactly what OpenGL writes: ASan sees a write past it. */
        uint8_t *pixels = malloc(size);
        CHECK(pixels);
        memset(pixels, 0xee, size);
        glPixelStorei(GL_PACK_ALIGNMENT, alignments[a]);
        glReadPixels(5, 6, WIDE, HIGH, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
        for (size_t y = 0; y < HIGH; y++)
            for (size_t x = 0; x < stride && y * stride + x < size; x++)
                CHECK(pixels[y * stride + x] == (x < row ? pixel_byte(y * row + x) : 0xee));
        free(pixels);
        host_settle();
        expect(MGL_READ_PIXELS, 6, 5, 6, WIDE, HIGH, GL_RGBA, GL_UNSIGNED_BYTE);
    }
    /* A read the Mac could not do (it has the error): no pixels, and the program's memory as it was. */
    uint8_t untouched[16];
    memset(untouched, 0xee, sizeof untouched);
    HOST(host.no_pixels = true);
    glReadPixels(0, 0, 2, 2, GL_RGBA, GL_UNSIGNED_BYTE, untouched);
    for (size_t k = 0; k < sizeof untouched; k++) CHECK(untouched[k] == 0xee);
    host_settle();
    expect(MGL_READ_PIXELS, 6, 0, 0, 2, 2, GL_RGBA, GL_UNSIGNED_BYTE);
    /* The stream goes on after it, and the error is the Mac's to tell. */
    HOST(host.no_pixels = false; host.error = GL_INVALID_FRAMEBUFFER_OPERATION);
    CHECK(glGetError() == GL_INVALID_FRAMEBUFFER_OPERATION);
    glReadPixels(0, 0, 2, 2, GL_RGBA, GL_UNSIGNED_BYTE, untouched);
    for (size_t k = 0; k < sizeof untouched; k++) CHECK(untouched[k] == pixel_byte(k));
    memset(untouched, 0xee, sizeof untouched);
    host_settle();
    expect(MGL_GET_ERROR, 0);
    expect(MGL_READ_PIXELS, 6, 0, 0, 2, 2, GL_RGBA, GL_UNSIGNED_BYTE);
    /* Only GL_RGBA with GL_UNSIGNED_BYTE can be read, and only so much. */
    RAISES(glReadPixels(0, 0, 2, 2, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, untouched), GL_INVALID_OPERATION);
    RAISES(glReadPixels(0, 0, 2, 2, GL_LUMINANCE, GL_UNSIGNED_BYTE, untouched), GL_INVALID_ENUM);
    RAISES(glReadPixels(0, 0, -2, 2, GL_RGBA, GL_UNSIGNED_BYTE, untouched), GL_INVALID_VALUE);
    RAISES(glReadPixels(0, 0, 5000, 2, GL_RGBA, GL_UNSIGNED_BYTE, untouched), GL_INVALID_VALUE);
    glReadPixels(0, 0, 0, 2, GL_RGBA, GL_UNSIGNED_BYTE, untouched); /* nothing to read */
    nothing_more();
    finish();
}

/* An error the library finds is kept for glGetError (the first one, as
 * OpenGL has it) and the call sends nothing; with none of its own,
 * glGetError asks the Mac. With no context current, calls do nothing. */
static void test_errors_found_here_and_calls_without_a_context(void) {
    WINDOW(window, 300, 200);
    begin(&window);
    glEnable(0x1234);
    glClear(0x10000000); /* another, which is not kept */
    CHECK(glGetError() == GL_INVALID_ENUM);
    nothing_more();
    HOST(host.error = GL_INVALID_FRAMEBUFFER_OPERATION);
    CHECK(glGetError() == GL_INVALID_FRAMEBUFFER_OPERATION && glGetError() == GL_NO_ERROR);
    host_settle();
    expect(MGL_GET_ERROR, 0);
    expect(MGL_GET_ERROR, 0);

    GLuint program = gears_program(), shader = 0, unknown = 99;
    GLsizei count = 0;
    GLint value = 77;
    char text[8] = "";
    glGetAttachedShaders(program, 1, &count, &shader);
    RAISES(glDisable(GL_TEXTURE_2D), GL_INVALID_ENUM);
    RAISES((void)glIsEnabled(0), GL_INVALID_ENUM);
    RAISES(glGetIntegerv(0x1234, &value), GL_INVALID_ENUM);
    RAISES(glGetFloatv(0x1234, (GLfloat[4]){0}), GL_INVALID_ENUM);
    RAISES(glGetBooleanv(0x1234, (GLboolean[4]){0}), GL_INVALID_ENUM);
    CHECK(value == 77);
    RAISES((void)glGetString(0x1234), GL_INVALID_ENUM);
    RAISES(glViewport(0, 0, -1, 1), GL_INVALID_VALUE);
    RAISES(glScissor(0, 0, 1, -1), GL_INVALID_VALUE);
    RAISES(glLineWidth(0), GL_INVALID_VALUE);
    RAISES(glDepthFunc(GL_KEEP), GL_INVALID_ENUM);
    RAISES(glCullFace(GL_CW), GL_INVALID_ENUM);
    RAISES(glFrontFace(GL_FRONT), GL_INVALID_ENUM);
    RAISES(glBlendFunc(GL_ONE, GL_SRC_ALPHA_SATURATE), GL_INVALID_ENUM);
    RAISES(glBlendEquation(GL_ONE), GL_INVALID_ENUM);
    RAISES(glStencilOp(GL_KEEP, GL_KEEP, GL_NEVER), GL_INVALID_ENUM);
    RAISES(glStencilFuncSeparate(GL_CW, GL_ALWAYS, 0, 0), GL_INVALID_ENUM);
    RAISES(glStencilMaskSeparate(0, 1), GL_INVALID_ENUM);
    RAISES(glHint(GL_GENERATE_MIPMAP_HINT, GL_LINEAR), GL_INVALID_ENUM);
    RAISES(glBindBuffer(GL_FRAMEBUFFER, 1), GL_INVALID_ENUM);
    RAISES(glBufferData(GL_ARRAY_BUFFER, 4, NULL, GL_STATIC_DRAW), GL_INVALID_OPERATION); /* no buffer bound */
    RAISES(glBufferData(GL_ARRAY_BUFFER, 4, NULL, GL_RGBA), GL_INVALID_ENUM);
    RAISES(glBufferSubData(GL_ARRAY_BUFFER, -1, 4, text), GL_INVALID_VALUE);
    RAISES(glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_SIZE, &value), GL_INVALID_OPERATION);
    RAISES(glBindFramebuffer(GL_RENDERBUFFER, 1), GL_INVALID_ENUM);
    RAISES(glBindRenderbuffer(GL_FRAMEBUFFER, 1), GL_INVALID_ENUM);
    RAISES(glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA4, 4, 4), GL_INVALID_OPERATION); /* none bound */
    RAISES(glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA, 4, 4), GL_INVALID_ENUM);
    RAISES(glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, 0), GL_INVALID_OPERATION); /* the window's own */
    RAISES(glFramebufferTexture2D(GL_FRAMEBUFFER, 0x8CE1, GL_TEXTURE_2D, 0, 0), GL_INVALID_ENUM);
    RAISES(glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &value),
           GL_INVALID_OPERATION);
    RAISES((void)glCheckFramebufferStatus(GL_RENDERBUFFER), GL_INVALID_ENUM);
    RAISES(glGenerateMipmap(GL_TEXTURE_CUBE_MAP_POSITIVE_X), GL_INVALID_ENUM);
    RAISES(glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR_MIPMAP_LINEAR), GL_INVALID_ENUM);
    RAISES(glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, -5), GL_INVALID_ENUM);
    RAISES(glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BINDING_2D, GL_LINEAR), GL_INVALID_ENUM);
    RAISES(glGetTexParameteriv(GL_TEXTURE, GL_TEXTURE_WRAP_S, &value), GL_INVALID_ENUM);
    RAISES(glCopyTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT, 0, 0, 4, 4, 0), GL_INVALID_ENUM);
    RAISES(glCopyTexSubImage2D(GL_TEXTURE_2D, 0, -1, 0, 0, 0, 4, 4), GL_INVALID_VALUE);
    RAISES(glGenTextures(-1, &unknown), GL_INVALID_VALUE);
    RAISES(glDeleteTextures(-1, &unknown), GL_INVALID_VALUE);
    RAISES((void)glCreateShader(GL_FLOAT), GL_INVALID_ENUM);
    RAISES(glCompileShader(unknown), GL_INVALID_VALUE);
    RAISES(glCompileShader(program), GL_INVALID_OPERATION); /* a program is no shader */
    RAISES(glLinkProgram(shader), GL_INVALID_OPERATION);
    RAISES(glUseProgram(unknown), GL_INVALID_VALUE);
    RAISES(glAttachShader(program, shader), GL_INVALID_OPERATION); /* it is attached */
    RAISES(glDetachShader(program, unknown), GL_INVALID_VALUE);
    RAISES(glBindAttribLocation(program, 16, "a"), GL_INVALID_VALUE);
    RAISES(glBindAttribLocation(program, 1, "gl_Vertex"), GL_INVALID_OPERATION);
    RAISES(glShaderSource(shader, -1, NULL, NULL), GL_INVALID_VALUE);
    RAISES(glShaderBinary(1, &shader, 0, text, 1), GL_INVALID_ENUM);
    RAISES(glGetShaderiv(shader, GL_LINK_STATUS, &value), GL_INVALID_ENUM);
    RAISES(glGetProgramiv(program, GL_COMPILE_STATUS, &value), GL_INVALID_ENUM);
    RAISES(glGetProgramInfoLog(unknown, sizeof text, NULL, text), GL_INVALID_VALUE);
    RAISES(glGetShaderInfoLog(shader, -1, NULL, text), GL_INVALID_VALUE);
    RAISES(glGetActiveUniform(program, 4, sizeof text, NULL, &value, &unknown, text), GL_INVALID_VALUE);
    RAISES(glGetActiveAttrib(program, 2, sizeof text, NULL, &value, &unknown, text), GL_INVALID_VALUE);
    RAISES(glGetShaderPrecisionFormat(GL_VERTEX_SHADER, GL_FLOAT, &value, &value), GL_INVALID_ENUM);
    RAISES(glUniform1f(-2, 1), GL_INVALID_OPERATION);
    RAISES(glUniform1fv(1, -1, (const GLfloat[]){1}), GL_INVALID_VALUE);
    RAISES(glUniformMatrix4fv(0, 1, GL_TRUE, (const GLfloat[16]){1}), GL_INVALID_VALUE); /* OpenGL ES 2.0 has no transpose */
    RAISES(glGetUniformfv(program, -1, (GLfloat[4]){0}), GL_INVALID_OPERATION);
    RAISES(glVertexAttrib1f(16, 1), GL_INVALID_VALUE);
    RAISES(glEnableVertexAttribArray(16), GL_INVALID_VALUE);
    RAISES(glGetVertexAttribiv(0, GL_BUFFER_SIZE, &value), GL_INVALID_ENUM);
    RAISES(glGetVertexAttribPointerv(0, GL_BUFFER_SIZE, (void *[1]){0}), GL_INVALID_ENUM);
    glUniform1f(-1, 1); /* a uniform the program has not: nothing, and no error */
    glDeleteShader(0);
    glDeleteProgram(0);
    glDeleteBuffers(1, &unknown); /* no buffer: none to the Mac either, which is told as the program said it */
    glReleaseShaderCompiler();
    /* Without a program in use there is no uniform to set. */
    glUseProgram(0);
    RAISES(glUniform1i(0, 1), GL_INVALID_OPERATION);
    sent();
    expect_data(MGL_DELETE_BUFFERS, &unknown, 4, 1, 1);
    expect(MGL_USE_PROGRAM, 1, 0);
    nothing_more();

    /* No context: nothing happens, nothing is sent, and what is asked has the answer for nothing. */
    CHECK(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT));
    glClear(GL_COLOR_BUFFER_BIT);
    glViewport(0, 0, 1, 1);
    glFlush();
    glFinish();
    CHECK(glGetError() == GL_INVALID_OPERATION && glGetString(GL_VENDOR) == NULL);
    CHECK(glCreateShader(GL_VERTEX_SHADER) == 0 && glCreateProgram() == 0 && !glIsEnabled(GL_DITHER));
    CHECK(glGetUniformLocation(program, "MaterialColor") == -1 && glCheckFramebufferStatus(GL_FRAMEBUFFER) == 0);
    glGetIntegerv(GL_PACK_ALIGNMENT, &value);
    glGenTextures(1, &unknown);
    CHECK(value == 77 && unknown == 99);
    CHECK(eglMakeCurrent(dpy, surface, surface, context));
    glGetIntegerv(GL_PACK_ALIGNMENT, &value);
    CHECK(value == 4);
    sent();
    expect(MGL_MAKE_CURRENT, 3, 0, 0, 0);
    expect(MGL_MAKE_CURRENT, 3, 1, 1, 1);
    nothing_more();
    finish();
}

static EGLint attrib(EGLDisplay d, EGLConfig c, EGLint name) {
    EGLint value = -99;
    CHECK(eglGetConfigAttrib(d, c, name, &value));
    return value;
}

static void *asks_for_its_own_error(void *unused) {
    (void)unused;
    CHECK(eglGetError() == EGL_SUCCESS);
    return NULL;
}

/* The six configs (with alpha and without, each with depth and stencil,
 * with depth only, and with neither) come in EGL's order for what was
 * asked: those with more bits of the colours asked for first, then the
 * smaller ones, so that a program that asks for no stencil buffer finds
 * first a config without one. The rest of EGL answers as a display with
 * windows and pbuffers and OpenGL ES 2.0 only does; the default display
 * has pbuffers only. */
static void test_configs_are_chosen_in_egls_order(void) {
    WINDOW(window, 300, 200);
    begin(&window);
    EGLConfig all[8], chosen[8];
    EGLint n = 0, count = 0;
    CHECK(eglGetConfigs(dpy, NULL, 0, &n) && n == 6);
    CHECK(eglGetConfigs(dpy, all, 8, &n) && n == 6);
    CHECK(eglGetConfigs(dpy, chosen, 3, &n) && n == 3);
    static const EGLint ids[] = {1, 2, 3, 4, 5, 6}, alpha[] = {8, 8, 0, 0, 8, 0}, depth[] = {24, 0, 24, 0, 24, 24},
                        stencil[] = {8, 0, 8, 0, 0, 0};
    for (int k = 0; k < 6; k++) {
        CHECK(attrib(dpy, all[k], EGL_CONFIG_ID) == ids[k] && attrib(dpy, all[k], EGL_ALPHA_SIZE) == alpha[k]);
        CHECK(attrib(dpy, all[k], EGL_RED_SIZE) == 8 && attrib(dpy, all[k], EGL_GREEN_SIZE) == 8 && attrib(dpy, all[k], EGL_BLUE_SIZE) == 8);
        CHECK(attrib(dpy, all[k], EGL_BUFFER_SIZE) == 24 + alpha[k] && attrib(dpy, all[k], EGL_DEPTH_SIZE) == depth[k]);
        CHECK(attrib(dpy, all[k], EGL_STENCIL_SIZE) == stencil[k] && attrib(dpy, all[k], EGL_SAMPLES) == 0);
        CHECK(attrib(dpy, all[k], EGL_SURFACE_TYPE) == (EGL_WINDOW_BIT | EGL_PBUFFER_BIT));
        CHECK(attrib(dpy, all[k], EGL_RENDERABLE_TYPE) == EGL_OPENGL_ES2_BIT && attrib(dpy, all[k], EGL_CONFORMANT) == EGL_OPENGL_ES2_BIT);
        CHECK(attrib(dpy, all[k], EGL_CONFIG_CAVEAT) == EGL_NONE && attrib(dpy, all[k], EGL_COLOR_BUFFER_TYPE) == EGL_RGB_BUFFER);
        CHECK(attrib(dpy, all[k], EGL_NATIVE_VISUAL_ID) == (alpha[k] ? 0 : 1) && attrib(dpy, all[k], EGL_MAX_SWAP_INTERVAL) == 1);
    }
    CHECK(!eglGetConfigAttrib(dpy, all[0], 0x3030, &n) && eglGetError() == EGL_BAD_ATTRIBUTE);
    CHECK(!eglGetConfigAttrib(dpy, &n, EGL_RED_SIZE, &n) && eglGetError() == EGL_BAD_CONFIG);

#define CHOOSES(wanted, ...) \
    do { \
        static const EGLint want_ids[] = {__VA_ARGS__, 0}; \
        CHECK(eglChooseConfig(dpy, (wanted), chosen, 8, &count)); \
        for (int k = 0; want_ids[k] != 0 || k < count; k++) CHECK(k < count && attrib(dpy, chosen[k], EGL_CONFIG_ID) == want_ids[k]); \
    } while (0)
    /* Colours without alpha, a depth buffer: those without alpha first (as many bits of what was asked, a smaller
     * buffer), and of two alike the one without a stencil buffer. */
    static const EGLint opaque_with_depth[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                                               EGL_BLUE_SIZE, 8, EGL_DEPTH_SIZE, 16, EGL_NONE};
    CHOOSES(opaque_with_depth, 6, 3, 5, 1);
    /* Alpha asked for: those that have it, the one with no depth buffer first. */
    CHOOSES(((const EGLint[]){EGL_ALPHA_SIZE, 1, EGL_NONE}), 2, 5, 1);
    CHOOSES(((const EGLint[]){EGL_RED_SIZE, 1, EGL_ALPHA_SIZE, EGL_DONT_CARE, EGL_STENCIL_SIZE, 1, EGL_NONE}), 3, 1);
    /* What glmark2 asks when told nothing else: a bit at least of each colour, of alpha and of depth, and no
     * stencil. It asks how many there are, then which, and holds a stencil buffer it did not ask for against a
     * config: the first is the one with depth and without stencil. */
    static const EGLint as_glmark2[] = {EGL_RED_SIZE, 1, EGL_GREEN_SIZE, 1, EGL_BLUE_SIZE, 1, EGL_ALPHA_SIZE, 1, EGL_DEPTH_SIZE, 1,
                                        EGL_STENCIL_SIZE, 0, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE};
    CHECK(eglChooseConfig(dpy, as_glmark2, NULL, 0, &count) && count == 2);
    CHOOSES(as_glmark2, 5, 1);
    CHECK(attrib(dpy, chosen[0], EGL_ALPHA_SIZE) == 8 && attrib(dpy, chosen[0], EGL_DEPTH_SIZE) == 24);
    CHECK(attrib(dpy, chosen[0], EGL_STENCIL_SIZE) == 0);
    /* The same with no alpha asked for: the first has none, and no stencil either. */
    static const EGLint opaque_no_stencil[] = {EGL_RED_SIZE, 1, EGL_GREEN_SIZE, 1, EGL_BLUE_SIZE, 1, EGL_DEPTH_SIZE, 1,
                                               EGL_STENCIL_SIZE, 0, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE};
    CHECK(eglChooseConfig(dpy, opaque_no_stencil, NULL, 0, &count) && count == 4);
    CHOOSES(opaque_no_stencil, 6, 3, 5, 1);
    CHECK(attrib(dpy, chosen[0], EGL_ALPHA_SIZE) == 0 && attrib(dpy, chosen[0], EGL_DEPTH_SIZE) == 24);
    CHECK(attrib(dpy, chosen[0], EGL_STENCIL_SIZE) == 0);
    /* Nothing asked: all of them, the smallest first. */
    CHOOSES(NULL, 4, 6, 3, 2, 5, 1);
    CHOOSES(((const EGLint[]){EGL_NONE}), 4, 6, 3, 2, 5, 1);
    static const EGLint what_all_have[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PBUFFER_BIT, EGL_CONFORMANT, EGL_OPENGL_ES2_BIT,
                                           EGL_NATIVE_VISUAL_ID, 5, EGL_NONE};
    CHOOSES(what_all_have, 4, 6, 3, 2, 5, 1);
    /* An id asked for is all that counts. */
    CHOOSES(((const EGLint[]){EGL_CONFIG_ID, 2, EGL_DEPTH_SIZE, 99, EGL_NONE}), 2);
    CHOOSES(((const EGLint[]){EGL_STENCIL_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_BUFFER_SIZE, 32, EGL_NONE}), 1);
    /* What no config has. */
    static const EGLint none_has[][3] = {
        {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES_BIT, EGL_NONE}, {EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT | EGL_OPENGL_ES2_BIT, EGL_NONE},
        {EGL_SAMPLES, 4, EGL_NONE},                         {EGL_DEPTH_SIZE, 32, EGL_NONE},
        {EGL_SURFACE_TYPE, EGL_PIXMAP_BIT, EGL_NONE},       {EGL_COLOR_BUFFER_TYPE, EGL_LUMINANCE_BUFFER, EGL_NONE},
        {EGL_CONFIG_ID, 9, EGL_NONE},                       {EGL_LEVEL, 1, EGL_NONE},
    };
    for (size_t k = 0; k < sizeof none_has / sizeof none_has[0]; k++) CHECK(eglChooseConfig(dpy, none_has[k], chosen, 8, &count) && count == 0);
    /* As many as there is room for, or only how many. */
    CHECK(eglChooseConfig(dpy, NULL, chosen, 2, &count) && count == 2 && attrib(dpy, chosen[1], EGL_CONFIG_ID) == 6);
    CHECK(eglChooseConfig(dpy, NULL, NULL, 0, &count) && count == 6);
    CHECK(!eglChooseConfig(dpy, (const EGLint[]){0x3030, 1, EGL_NONE}, chosen, 8, &count) && eglGetError() == EGL_BAD_ATTRIBUTE);
    CHECK(!eglChooseConfig(dpy, (const EGLint[]){EGL_WIDTH, 1, EGL_NONE}, chosen, 8, &count) && eglGetError() == EGL_BAD_ATTRIBUTE);
    CHECK(!eglChooseConfig(dpy, NULL, chosen, 8, NULL) && eglGetError() == EGL_BAD_PARAMETER);

    /* What EGL says of itself. */
    CHECK(strcmp(eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS),
                 "EGL_EXT_client_extensions EGL_EXT_platform_base EGL_KHR_platform_wayland EGL_EXT_platform_wayland") == 0);
    CHECK(strcmp(eglQueryString(dpy, EGL_EXTENSIONS), "") == 0 && strcmp(eglQueryString(dpy, EGL_VENDOR), "Monad") == 0);
    CHECK(strcmp(eglQueryString(dpy, EGL_VERSION), "1.4") == 0 && strcmp(eglQueryString(dpy, EGL_CLIENT_APIS), "OpenGL_ES") == 0);
    CHECK(eglQueryString(dpy, EGL_WIDTH) == NULL && eglGetError() == EGL_BAD_PARAMETER);
    CHECK(eglQueryString(EGL_NO_DISPLAY, EGL_VENDOR) == NULL && eglGetError() == EGL_BAD_DISPLAY);
    CHECK(eglBindAPI(EGL_OPENGL_ES_API) && eglQueryAPI() == EGL_OPENGL_ES_API);
    CHECK(!eglBindAPI(EGL_OPENGL_API) && eglGetError() == EGL_BAD_PARAMETER);
    CHECK(eglGetError() == EGL_SUCCESS); /* asked once */
    /* An error is its thread's. */
    CHECK(!eglBindAPI(EGL_OPENVG_API));
    pthread_t other;
    CHECK(pthread_create(&other, NULL, asks_for_its_own_error, NULL) == 0 && pthread_join(other, NULL) == 0);
    CHECK(eglGetError() == EGL_BAD_PARAMETER);
    CHECK(eglWaitNative(EGL_CORE_NATIVE_ENGINE) && eglWaitClient() && eglWaitGL());
    CHECK(eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, &native_display, NULL) == dpy);
    CHECK(eglGetPlatformDisplayEXT(EGL_PLATFORM_WAYLAND_EXT, &native_display, (const EGLint[]){EGL_NONE}) == dpy);
    CHECK(eglGetPlatformDisplay(0x31D7, &native_display, NULL) == EGL_NO_DISPLAY && eglGetError() == EGL_BAD_PARAMETER);
    CHECK(eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, &native_display, (const EGLAttrib[]){1, 2, EGL_NONE}) == EGL_NO_DISPLAY);
    CHECK(eglGetError() == EGL_BAD_ATTRIBUTE);

    /* Contexts are OpenGL ES 2.0's and nothing else's. */
    CHECK(eglCreateContext(dpy, config, EGL_NO_CONTEXT, NULL) == EGL_NO_CONTEXT && eglGetError() == EGL_BAD_CONFIG);
    CHECK(eglCreateContext(dpy, config, EGL_NO_CONTEXT, (const EGLint[]){EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE}) == EGL_NO_CONTEXT);
    CHECK(eglGetError() == EGL_BAD_ATTRIBUTE);
    CHECK(eglCreateContext(dpy, config, EGL_NO_CONTEXT, (const EGLint[]){EGL_WIDTH, 3, EGL_NONE}) == EGL_NO_CONTEXT);
    CHECK(eglGetError() == EGL_BAD_ATTRIBUTE);
    CHECK(eglCreateContext(dpy, &n, EGL_NO_CONTEXT, es2) == EGL_NO_CONTEXT && eglGetError() == EGL_BAD_CONFIG);
    CHECK(eglCreateContext(dpy, config, &n, es2) == EGL_NO_CONTEXT && eglGetError() == EGL_BAD_CONTEXT);

    /* Surfaces: one a window, of a window that is one; pbuffers up to the largest; no pixmaps, nothing bound to textures. */
    WINDOW(another, 20, 10);
    WINDOW(old, 20, 10);
    memcpy(&old, &(intptr_t){2}, sizeof(intptr_t)); /* another version of the struct: not read as this one */
    CHECK(eglCreateWindowSurface(dpy, config, &window, NULL) == EGL_NO_SURFACE && eglGetError() == EGL_BAD_ALLOC);
    CHECK(eglCreateWindowSurface(dpy, config, NULL, NULL) == EGL_NO_SURFACE && eglGetError() == EGL_BAD_NATIVE_WINDOW);
    CHECK(eglCreateWindowSurface(dpy, config, &old, NULL) == EGL_NO_SURFACE && eglGetError() == EGL_BAD_NATIVE_WINDOW);
    CHECK(eglCreateWindowSurface(dpy, &n, &another, NULL) == EGL_NO_SURFACE && eglGetError() == EGL_BAD_CONFIG);
    CHECK(eglCreateWindowSurface(dpy, config, &another, (const EGLint[]){EGL_WIDTH, 5, EGL_NONE}) == EGL_NO_SURFACE);
    CHECK(eglGetError() == EGL_BAD_ATTRIBUTE && !another.driver_private);
    static const EGLAttrib back_buffer[] = {EGL_RENDER_BUFFER, EGL_BACK_BUFFER, EGL_NONE};
    EGLSurface second_window = eglCreatePlatformWindowSurface(dpy, config, &another, back_buffer);
    CHECK(second_window != EGL_NO_SURFACE && eglGetError() == EGL_SUCCESS && another.driver_private);
    CHECK(eglDestroySurface(dpy, second_window) && !another.driver_private);
    second_window = eglCreatePlatformWindowSurfaceEXT(dpy, config, &another, NULL);
    CHECK(second_window != EGL_NO_SURFACE && eglDestroySurface(dpy, second_window));
    static const EGLint too_wide[] = {EGL_WIDTH, 9000, EGL_HEIGHT, 10, EGL_LARGEST_PBUFFER, EGL_TRUE, EGL_NONE};
    EGLSurface large = eglCreatePbufferSurface(dpy, config, too_wide);
    EGLint value = 0;
    CHECK(large != EGL_NO_SURFACE && eglQuerySurface(dpy, large, EGL_WIDTH, &value) && value == 4096);
    CHECK(eglQuerySurface(dpy, large, EGL_LARGEST_PBUFFER, &value) && value == EGL_TRUE);
    CHECK(eglQuerySurface(dpy, large, EGL_TEXTURE_FORMAT, &value) && value == EGL_NO_TEXTURE);
    CHECK(eglQuerySurface(dpy, large, EGL_CONFIG_ID, &value) && value == 1);
    CHECK(eglQuerySurface(dpy, surface, EGL_RENDER_BUFFER, &value) && value == EGL_BACK_BUFFER);
    CHECK(eglQuerySurface(dpy, surface, EGL_SWAP_BEHAVIOR, &value) && value == EGL_BUFFER_DESTROYED);
    CHECK(!eglQuerySurface(dpy, surface, EGL_RED_SIZE, &value) && eglGetError() == EGL_BAD_ATTRIBUTE);
    CHECK(!eglQuerySurface(dpy, &n, EGL_WIDTH, &value) && eglGetError() == EGL_BAD_SURFACE);
    CHECK(eglCreatePbufferSurface(dpy, config, (const EGLint[]){EGL_WIDTH, 9000, EGL_NONE}) == EGL_NO_SURFACE && eglGetError() == EGL_BAD_ALLOC);
    CHECK(eglCreatePbufferSurface(dpy, config, (const EGLint[]){EGL_WIDTH, -1, EGL_NONE}) == EGL_NO_SURFACE && eglGetError() == EGL_BAD_PARAMETER);
    CHECK(eglCreatePbufferSurface(dpy, config, (const EGLint[]){EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA, EGL_NONE}) == EGL_NO_SURFACE);
    CHECK(eglGetError() == EGL_BAD_MATCH);
    CHECK(eglCreatePbufferSurface(dpy, config, (const EGLint[]){EGL_RED_SIZE, 8, EGL_NONE}) == EGL_NO_SURFACE && eglGetError() == EGL_BAD_ATTRIBUTE);
    CHECK(eglSurfaceAttrib(dpy, surface, EGL_SWAP_BEHAVIOR, EGL_BUFFER_DESTROYED) && eglSurfaceAttrib(dpy, surface, EGL_MIPMAP_LEVEL, 1));
    CHECK(!eglSurfaceAttrib(dpy, surface, EGL_SWAP_BEHAVIOR, EGL_BUFFER_PRESERVED) && eglGetError() == EGL_BAD_MATCH);
    CHECK(!eglSurfaceAttrib(dpy, surface, EGL_WIDTH, 5) && eglGetError() == EGL_BAD_ATTRIBUTE);
    CHECK(eglCreatePixmapSurface(dpy, config, NULL, NULL) == EGL_NO_SURFACE && eglGetError() == EGL_BAD_MATCH);
    CHECK(eglCreatePlatformPixmapSurface(dpy, config, NULL, NULL) == EGL_NO_SURFACE && eglGetError() == EGL_BAD_MATCH);
    CHECK(eglCreatePlatformPixmapSurfaceEXT(dpy, &n, NULL, NULL) == EGL_NO_SURFACE && eglGetError() == EGL_BAD_CONFIG);
    CHECK(eglCreatePbufferFromClientBuffer(dpy, EGL_OPENVG_IMAGE, NULL, config, NULL) == EGL_NO_SURFACE && eglGetError() == EGL_BAD_PARAMETER);
    CHECK(!eglCopyBuffers(dpy, surface, NULL) && eglGetError() == EGL_BAD_NATIVE_PIXMAP);
    CHECK(!eglBindTexImage(dpy, large, EGL_BACK_BUFFER) && eglGetError() == EGL_BAD_MATCH);
    CHECK(!eglReleaseTexImage(dpy, surface, EGL_BACK_BUFFER) && eglGetError() == EGL_BAD_SURFACE);
    /* A swap is of the surface the thread draws on; a pbuffer's shows nothing. */
    CHECK(!eglSwapBuffers(dpy, large) && eglGetError() == EGL_BAD_SURFACE);
    CHECK(eglMakeCurrent(dpy, large, large, context) && eglSwapBuffers(dpy, large) && wayland.present_count == 0);
    CHECK(eglSwapInterval(dpy, 1) && eglMakeCurrent(dpy, surface, surface, context));
    CHECK(eglDestroySurface(dpy, large));

    /* The default display: no Wayland, so no windows. It is another display on the same stream. */
    EGLDisplay plain = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    CHECK(plain != EGL_NO_DISPLAY && plain != dpy && eglInitialize(plain, NULL, NULL) && wayland.binds == 1);
    CHECK(eglChooseConfig(plain, NULL, chosen, 8, &count) && count == 0); /* EGL's default is a config for windows */
    CHECK(eglChooseConfig(plain, (const EGLint[]){EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_ALPHA_SIZE, 8, EGL_NONE}, chosen, 8, &count) && count == 3);
    CHECK(attrib(plain, chosen[0], EGL_SURFACE_TYPE) == EGL_PBUFFER_BIT);
    CHECK(eglCreateWindowSurface(plain, chosen[0], &another, NULL) == EGL_NO_SURFACE && eglGetError() == EGL_BAD_MATCH);
    EGLSurface off = eglCreatePbufferSurface(plain, chosen[0], (const EGLint[]){EGL_WIDTH, 4, EGL_HEIGHT, 4, EGL_NONE});
    EGLContext third = eglCreateContext(plain, chosen[0], EGL_NO_CONTEXT, es2);
    CHECK(off != EGL_NO_SURFACE && third != EGL_NO_CONTEXT);
    /* What is one display's is none of another's. */
    CHECK(!eglMakeCurrent(dpy, off, off, context) && eglGetError() == EGL_BAD_SURFACE);
    CHECK(!eglMakeCurrent(dpy, surface, surface, third) && eglGetError() == EGL_BAD_CONTEXT);
    CHECK(eglTerminate(plain));
    sent();
    expect(MGL_FINISH, 0); /* eglWaitClient, eglWaitGL */
    expect(MGL_FINISH, 0);
    expect(MGL_SURFACE_CREATE, 6, 2, 20, 10, 1, 1, 1);
    expect(MGL_SURFACE_DESTROY, 1, 2);
    expect(MGL_SURFACE_CREATE, 6, 3, 20, 10, 1, 1, 1);
    expect(MGL_SURFACE_DESTROY, 1, 3);
    expect(MGL_SURFACE_CREATE, 6, 4, 4096, 10, 1, 1, 1);
    expect(MGL_MAKE_CURRENT, 3, 1, 4, 4);
    expect(MGL_MAKE_CURRENT, 3, 1, 1, 1);
    expect(MGL_SURFACE_DESTROY, 1, 4);
    expect(MGL_SURFACE_CREATE, 6, 5, 4, 4, 1, 0, 0); /* the first with alpha: neither depth nor stencil */
    expect(MGL_CONTEXT_CREATE, 2, 2, 0);
    expect(MGL_SURFACE_DESTROY, 1, 5);
    expect(MGL_CONTEXT_DESTROY, 1, 2);
    nothing_more();
    finish();
}

/* What glGetIntegerv says of the framebuffer's alpha, depth and stencil bits. */
static void the_bits_are(const EGLint has[3]) {
    static const GLenum names[3] = {GL_ALPHA_BITS, GL_DEPTH_BITS, GL_STENCIL_BITS};
    for (int b = 0; b < 3; b++) {
        GLint value = 77;
        glGetIntegerv(names[b], &value);
        if (value != has[b]) fprintf(stderr, "0x%x is %d where %d was to be\n", names[b], value, has[b]);
        CHECK(value == has[b]);
    }
}

/* A surface has the buffers its config has and no others. SurfaceCreate
 * tells the Mac which of alpha, depth and stencil there are, for a window
 * and for a pbuffer of every config, and a program that asks for the
 * bits of the default framebuffer is told those of the surface it draws
 * on: a program that asked for no stencil buffer is not told of one. */
static void test_a_surface_has_the_buffers_of_its_config(void) {
    WINDOW(window, 300, 200);
    begin(&window);
    enum { CONFIGS = 6 };
    EGLConfig all[CONFIGS];
    EGLSurface pbuffers[CONFIGS];
    EGLint n = 0, has[CONFIGS][3];
    CHECK(eglGetConfigs(dpy, all, CONFIGS, &n) && n == CONFIGS);
    static const EGLint small[] = {EGL_WIDTH, 4, EGL_HEIGHT, 4, EGL_NONE};
    for (int k = 0; k < CONFIGS; k++) {
        has[k][0] = attrib(dpy, all[k], EGL_ALPHA_SIZE);
        has[k][1] = attrib(dpy, all[k], EGL_DEPTH_SIZE);
        has[k][2] = attrib(dpy, all[k], EGL_STENCIL_SIZE);
        WINDOW(another, 20, 10);
        EGLSurface of_window = eglCreateWindowSurface(dpy, all[k], &another, NULL);
        pbuffers[k] = eglCreatePbufferSurface(dpy, all[k], small);
        EGLContext its = eglCreateContext(dpy, all[k], EGL_NO_CONTEXT, es2);
        CHECK(of_window != EGL_NO_SURFACE && pbuffers[k] != EGL_NO_SURFACE && its != EGL_NO_CONTEXT);
        CHECK(eglMakeCurrent(dpy, of_window, of_window, its));
        the_bits_are(has[k]);
        CHECK(eglMakeCurrent(dpy, pbuffers[k], pbuffers[k], its));
        the_bits_are(has[k]);
        CHECK(eglMakeCurrent(dpy, surface, surface, context));
        the_bits_are(has[0]);
        CHECK(eglDestroySurface(dpy, of_window) && eglDestroyContext(dpy, its));
        sent();
        /* The names: two surfaces a config after the first window's, a context a config after the first. */
        uint32_t of = 2 + 2 * (uint32_t)k, its_name = 2 + (uint32_t)k;
        expect(MGL_SURFACE_CREATE, 6, of, 20, 10, has[k][0] != 0, has[k][1] != 0, has[k][2] != 0);
        expect(MGL_SURFACE_CREATE, 6, of + 1, 4, 4, has[k][0] != 0, has[k][1] != 0, has[k][2] != 0);
        expect(MGL_CONTEXT_CREATE, 2, its_name, 0);
        expect(MGL_MAKE_CURRENT, 3, its_name, of, of);
        expect(MGL_MAKE_CURRENT, 3, its_name, of + 1, of + 1);
        expect(MGL_MAKE_CURRENT, 3, 1, 1, 1);
        expect(MGL_SURFACE_DESTROY, 1, of);
        expect(MGL_CONTEXT_DESTROY, 1, its_name);
    }
    /* No two configs have the same three: each surface's words were its own. */
    for (int k = 0; k < CONFIGS; k++)
        for (int other = 0; other < k; other++) CHECK(memcmp(has[k], has[other], sizeof has[k]) != 0);

    /* The surface drawn on is the one asked about: not the one read from, and not what the context was made for
     * (this library lets a context draw on a surface of another config). */
    for (int k = 0; k < CONFIGS; k++) {
        CHECK(eglMakeCurrent(dpy, pbuffers[k], surface, context));
        the_bits_are(has[k]);
    }
    CHECK(eglMakeCurrent(dpy, surface, pbuffers[3], context));
    the_bits_are(has[0]);
    /* The colours are in every one of them. */
    GLint colour = 0;
    glGetIntegerv(GL_RED_BITS, &colour);
    CHECK(colour == 8);
    sent();
    for (uint32_t k = 0; k < CONFIGS; k++) expect(MGL_MAKE_CURRENT, 3, 1, 3 + 2 * k, 1);
    expect(MGL_MAKE_CURRENT, 3, 1, 1, 9);
    nothing_more();
    finish();
}

/* eglGetProcAddress has every entry point of OpenGL ES 2.0 (142 of them) and of EGL by its name. */
static void test_every_entry_point_has_an_address(void) {
    static const char *const gl[] = {
        "glActiveTexture", "glAttachShader", "glBindAttribLocation", "glBindBuffer", "glBindFramebuffer", "glBindRenderbuffer",
        "glBindTexture", "glBlendColor", "glBlendEquation", "glBlendEquationSeparate", "glBlendFunc", "glBlendFuncSeparate",
        "glBufferData", "glBufferSubData", "glCheckFramebufferStatus", "glClear", "glClearColor", "glClearDepthf", "glClearStencil",
        "glColorMask", "glCompileShader", "glCompressedTexImage2D", "glCompressedTexSubImage2D", "glCopyTexImage2D",
        "glCopyTexSubImage2D", "glCreateProgram", "glCreateShader", "glCullFace", "glDeleteBuffers", "glDeleteFramebuffers",
        "glDeleteProgram", "glDeleteRenderbuffers", "glDeleteShader", "glDeleteTextures", "glDepthFunc", "glDepthMask",
        "glDepthRangef", "glDetachShader", "glDisable", "glDisableVertexAttribArray", "glDrawArrays", "glDrawElements", "glEnable",
        "glEnableVertexAttribArray", "glFinish", "glFlush", "glFramebufferRenderbuffer", "glFramebufferTexture2D", "glFrontFace",
        "glGenBuffers", "glGenerateMipmap", "glGenFramebuffers", "glGenRenderbuffers", "glGenTextures", "glGetActiveAttrib",
        "glGetActiveUniform", "glGetAttachedShaders", "glGetAttribLocation", "glGetBooleanv", "glGetBufferParameteriv", "glGetError",
        "glGetFloatv", "glGetFramebufferAttachmentParameteriv", "glGetIntegerv", "glGetProgramiv", "glGetProgramInfoLog",
        "glGetRenderbufferParameteriv", "glGetShaderiv", "glGetShaderInfoLog", "glGetShaderPrecisionFormat", "glGetShaderSource",
        "glGetString", "glGetTexParameterfv", "glGetTexParameteriv", "glGetUniformfv", "glGetUniformiv", "glGetUniformLocation",
        "glGetVertexAttribfv", "glGetVertexAttribiv", "glGetVertexAttribPointerv", "glHint", "glIsBuffer", "glIsEnabled",
        "glIsFramebuffer", "glIsProgram", "glIsRenderbuffer", "glIsShader", "glIsTexture", "glLineWidth", "glLinkProgram",
        "glPixelStorei", "glPolygonOffset", "glReadPixels", "glReleaseShaderCompiler", "glRenderbufferStorage", "glSampleCoverage",
        "glScissor", "glShaderBinary", "glShaderSource", "glStencilFunc", "glStencilFuncSeparate", "glStencilMask",
        "glStencilMaskSeparate", "glStencilOp", "glStencilOpSeparate", "glTexImage2D", "glTexParameterf", "glTexParameterfv",
        "glTexParameteri", "glTexParameteriv", "glTexSubImage2D", "glUniform1f", "glUniform1fv", "glUniform1i", "glUniform1iv",
        "glUniform2f", "glUniform2fv", "glUniform2i", "glUniform2iv", "glUniform3f", "glUniform3fv", "glUniform3i", "glUniform3iv",
        "glUniform4f", "glUniform4fv", "glUniform4i", "glUniform4iv", "glUniformMatrix2fv", "glUniformMatrix3fv",
        "glUniformMatrix4fv", "glUseProgram", "glValidateProgram", "glVertexAttrib1f", "glVertexAttrib1fv", "glVertexAttrib2f",
        "glVertexAttrib2fv", "glVertexAttrib3f", "glVertexAttrib3fv", "glVertexAttrib4f", "glVertexAttrib4fv",
        "glVertexAttribPointer", "glViewport",
    };
    static const char *const egl[] = {
        "eglBindAPI", "eglBindTexImage", "eglChooseConfig", "eglCopyBuffers", "eglCreateContext", "eglCreatePbufferFromClientBuffer",
        "eglCreatePbufferSurface", "eglCreatePixmapSurface", "eglCreatePlatformWindowSurface", "eglCreatePlatformWindowSurfaceEXT",
        "eglCreateWindowSurface", "eglDestroyContext", "eglDestroySurface", "eglGetConfigAttrib", "eglGetConfigs",
        "eglGetCurrentContext", "eglGetCurrentDisplay", "eglGetCurrentSurface", "eglGetDisplay", "eglGetError",
        "eglGetPlatformDisplay", "eglGetPlatformDisplayEXT", "eglGetProcAddress", "eglInitialize", "eglMakeCurrent", "eglQueryAPI",
        "eglQueryContext", "eglQueryString", "eglQuerySurface", "eglReleaseTexImage", "eglReleaseThread", "eglSurfaceAttrib",
        "eglSwapBuffers", "eglSwapInterval", "eglTerminate", "eglWaitClient", "eglWaitGL", "eglWaitNative",
    };
    CHECK(sizeof gl / sizeof gl[0] == 142);
    for (size_t k = 0; k < sizeof gl / sizeof gl[0]; k++) {
        if (!eglGetProcAddress(gl[k])) fprintf(stderr, "%s has no address\n", gl[k]);
        CHECK(eglGetProcAddress(gl[k]) != NULL);
        for (size_t other = 0; other < k; other++) CHECK(eglGetProcAddress(gl[k]) != eglGetProcAddress(gl[other]));
    }
    for (size_t k = 0; k < sizeof egl / sizeof egl[0]; k++) CHECK(eglGetProcAddress(egl[k]) != NULL);
    CHECK(eglGetProcAddress("glClear") == (void (*)(void))glClear && eglGetProcAddress("glViewport") == (void (*)(void))glViewport);
    CHECK(eglGetProcAddress("eglSwapBuffers") == (void (*)(void))eglSwapBuffers);
    CHECK(!eglGetProcAddress("glBegin") && !eglGetProcAddress("glClearX") && !eglGetProcAddress("") && !eglGetProcAddress(NULL));
}

/* The stream is lost: a swap fails as EGL has it for a lost context, and every other call still returns, having done nothing on the Mac. */
static void the_stream_is_lost(void) {
    glClear(GL_COLOR_BUFFER_BIT);
    glFlush();
    glFinish();
    CHECK(glGetError() == GL_NO_ERROR && glGetError() == GL_NO_ERROR); /* a program that asks until there is none comes to an end */
    CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == 0);
    GLuint shader = glCreateShader(GL_VERTEX_SHADER), program = glCreateProgram(), texture = 0;
    GLint status = 77;
    CHECK(shader != 0 && program != 0); /* names still: a program does not fall over for want of them */
    glCompileShader(shader);
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    CHECK(status == GL_FALSE);
    glLinkProgram(program);
    glGetProgramiv(program, GL_LINK_STATUS, &status);
    CHECK(status == GL_FALSE && glGetUniformLocation(program, "x") == -1);
    CHECK(glGetError() == GL_INVALID_OPERATION); /* the library's own: a program that is not linked has no uniforms */
    glGenTextures(1, &texture);
    static uint8_t pixels[1 << 18];
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 256, 256, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels); /* more than is ever kept unsent */
    uint8_t back[4] = {0xee, 0xee, 0xee, 0xee};
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, back);
    CHECK(back[0] == 0xee && texture != 0 && glGetError() == GL_NO_ERROR);
    CHECK(!eglSwapBuffers(dpy, surface) && eglGetError() == EGL_CONTEXT_LOST && wayland.present_count == 0);
    /* The program can still take everything down. */
    CHECK(eglGetCurrentContext() == context && eglDestroySurface(dpy, surface) && eglDestroyContext(dpy, context));
    finish();
}

/* The window manager goes away, or answers what the protocol does not
 * have: nothing crashes, nothing waits for ever, nothing of an answer
 * that is no answer reaches the program's memory, and the stream is lost.
 * The next eglInitialize opens a new one. */
static void test_a_host_that_hangs_up_or_answers_nonsense_loses_the_stream(void) {
    /* Gone while nothing was being said: found when the next picture is sent, which has nowhere to go. */
    WINDOW(window, 300, 200);
    begin(&window);
    host_goes_away();
    glClear(GL_COLOR_BUFFER_BIT);
    CHECK(!eglSwapBuffers(dpy, surface) && eglGetError() == EGL_CONTEXT_LOST && wayland.present_count == 0);
    the_stream_is_lost();

    /* Gone instead of an answer, in the middle of one, and answers of no length a reply has. */
    static const int ways[] = {HANG_UP, CUT_SHORT, ODD_LENGTH, HUGE_LENGTH};
    for (int k = 0; k < 4; k++) {
        WINDOW(again, 300, 200);
        begin(&again);
        HOST(host.nonsense = ways[k]);
        if (k % 2 == 0) glFinish();
        else CHECK(glGetError() == GL_NO_ERROR);
        the_stream_is_lost();
    }

    /* Answers of a good length that are not what the command's answer is. */
    for (int k = 0;; k++) {
        body raw = {.len = 0};
        WINDOW(again, 300, 200);
        begin(&again);
        GLuint program = gears_program(), shader = glCreateShader(GL_FRAGMENT_SHADER);
        GLint value = 77, values[20];
        GLfloat floats[20];
        uint8_t pixels[16];
        memset(pixels, 0xee, sizeof pixels);
        for (int n = 0; n < 20; n++) values[n] = 77, floats[n] = 77;
        bool last = false;
        switch (k) {
        case 0: /* an error and something after it */
            body_u32(&raw, GL_INVALID_ENUM), body_u32(&raw, 0);
            HOST(host.raw = raw; host.nonsense = RAW);
            CHECK(glGetError() == GL_NO_ERROR);
            break;
        case 1: /* an error OpenGL has not */
            body_u32(&raw, 7);
            HOST(host.raw = raw; host.nonsense = RAW);
            CHECK(glGetError() == GL_NO_ERROR);
            break;
        case 2: /* no answer where a status is to be */
            HOST(host.raw = raw; host.nonsense = RAW);
            CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == 0);
            break;
        case 3: /* an answer where none is to be */
            body_u32(&raw, 1);
            HOST(host.raw = raw; host.nonsense = RAW);
            glFinish();
            break;
        case 4: /* compiled, more than yes or no */
            body_u32(&raw, 7), body_text(&raw, "");
            HOST(host.raw = raw; host.nonsense = RAW);
            glCompileShader(shader);
            glGetShaderiv(shader, GL_COMPILE_STATUS, &value);
            CHECK(value == GL_FALSE);
            break;
        case 5: /* a log longer than the answer it is in */
            body_u32(&raw, 1), body_u32(&raw, 1000), body_u32(&raw, 0);
            HOST(host.raw = raw; host.nonsense = RAW);
            glCompileShader(shader);
            glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &value);
            CHECK(value == 0);
            glGetShaderiv(shader, GL_COMPILE_STATUS, &value);
            CHECK(value == GL_FALSE);
            break;
        case 6: /* more attributes than there could be memory for */
            body_u32(&raw, 1), body_text(&raw, ""), body_u32(&raw, 0x40000000), body_u32(&raw, 0);
            HOST(host.raw = raw; host.nonsense = RAW);
            glLinkProgram(program);
            glGetProgramiv(program, GL_LINK_STATUS, &value);
            CHECK(value == GL_FALSE);
            glGetProgramiv(program, GL_ACTIVE_ATTRIBUTES, &value);
            CHECK(value == 0 && glGetAttribLocation(program, "position") == -1 && glGetError() == GL_INVALID_OPERATION);
            break;
        case 7: /* a uniform that ends before its name, after one that is whole */
            body_u32(&raw, 1), body_text(&raw, ""), body_u32(&raw, 0), body_u32(&raw, 2);
            variable(&raw, 0, GL_FLOAT, 1, "whole");
            body_u32(&raw, 1), body_u32(&raw, GL_FLOAT);
            HOST(host.raw = raw; host.nonsense = RAW);
            glLinkProgram(program);
            glGetProgramiv(program, GL_ACTIVE_UNIFORMS, &value);
            CHECK(value == 0 && glGetUniformLocation(program, "whole") == -1 && glGetError() == GL_INVALID_OPERATION);
            break;
        case 8: /* a uniform without a name at all (none, as for a NULL pointer) */
            body_u32(&raw, 1), body_text(&raw, ""), body_u32(&raw, 0), body_u32(&raw, 1);
            body_u32(&raw, 0), body_u32(&raw, GL_FLOAT), body_u32(&raw, 1), body_u32(&raw, MWM_GL_NONE);
            HOST(host.raw = raw; host.nonsense = RAW);
            glLinkProgram(program);
            glGetProgramiv(program, GL_LINK_STATUS, &value);
            CHECK(value == GL_FALSE);
            break;
        case 9: /* linked, and words after the last uniform */
            body_u32(&raw, 1), body_text(&raw, ""), body_u32(&raw, 0), body_u32(&raw, 0), body_u32(&raw, 0);
            HOST(host.raw = raw; host.nonsense = RAW);
            glLinkProgram(program);
            glGetProgramiv(program, GL_LINK_STATUS, &value);
            CHECK(value == GL_FALSE);
            break;
        case 10: /* fewer pixels than were asked for */
            body_data(&raw, pixels, 8);
            HOST(host.raw = raw; host.nonsense = RAW);
            glReadPixels(0, 0, 2, 2, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
            break;
        case 11: /* more */
            body_data(&raw, pixels, 16), body_u32(&raw, 0);
            HOST(host.raw = raw; host.nonsense = RAW);
            glReadPixels(0, 0, 2, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
            break;
        case 12: /* a vec4 of two floats */
            body_u32(&raw, GL_FLOAT_VEC4), body_data(&raw, floats, 8);
            HOST(host.raw = raw; host.nonsense = RAW);
            glGetUniformfv(program, 1, floats);
            break;
        case 13: /* a matrix of more floats than any uniform is */
            body_u32(&raw, GL_FLOAT_MAT4), body_data(&raw, floats, 80);
            HOST(host.raw = raw; host.nonsense = RAW);
            glGetUniformfv(program, 1, floats);
            break;
        case 14: /* no pixels as data of no bytes: a read that could not be done is answered with nothing at all */
            body_data(&raw, pixels, 0);
            HOST(host.raw = raw; host.nonsense = RAW);
            glReadPixels(0, 0, 2, 2, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
            break;
        case 15: /* a uniform's type and no value */
            body_u32(&raw, GL_FLOAT), body_data(&raw, floats, 0);
            HOST(host.raw = raw; host.nonsense = RAW);
            glGetUniformfv(program, 1, floats);
            break;
        case 16: /* no type, and a value all the same */
            body_u32(&raw, 0), body_data(&raw, floats, 4);
            HOST(host.raw = raw; host.nonsense = RAW);
            glGetUniformfv(program, 1, floats);
            break;
        case 17: /* no type, and none (as for a NULL pointer) where data of no bytes is to be */
            body_u32(&raw, 0), body_u32(&raw, MWM_GL_NONE);
            HOST(host.raw = raw; host.nonsense = RAW);
            glGetUniformiv(program, 1, values);
            break;
        case 18: /* nothing at all for a uniform: that is how a read of pixels says it could not be done */
            HOST(host.raw = raw; host.nonsense = RAW);
            glGetUniformiv(program, 1, values);
            break;
        default: /* a type no uniform has */
            body_u32(&raw, GL_TEXTURE_2D), body_data(&raw, values, 4);
            HOST(host.raw = raw; host.nonsense = RAW);
            glGetUniformiv(program, 1, values);
            last = true;
            break;
        }
        for (size_t n = 0; n < sizeof pixels; n++) CHECK(pixels[n] == 0xee);
        for (int n = 0; n < 20; n++) CHECK(values[n] == 77 && floats[n] == 77);
        the_stream_is_lost();
        if (last) break;
    }

    /* A Swap's answer is nothing. One that is something, or a window manager gone instead of it, is found where the
     * answer is read (before the next Swap, or before another answer), not where the picture was done; the stream
     * is lost then, and nothing waits for an answer that does not come. */
    for (int k = 0; k < 4; k++) {
        body raw = {.len = 0};
        WINDOW(again, 300, 200);
        begin(&again);
        body_u32(&raw, 0);
        HOST(host.raw = raw; host.nonsense = k < 2 ? RAW : HANG_UP);
        CHECK(eglSwapBuffers(dpy, surface) && wayland.present_count == 1);
        if (k % 2 == 0) CHECK(!eglSwapBuffers(dpy, surface) && eglGetError() == EGL_CONTEXT_LOST && wayland.present_count == 1);
        else CHECK(glGetError() == GL_NO_ERROR);
        wayland.present_count = 0;
        the_stream_is_lost();
    }

    /* A new stream after all that: the library is as it was at first. */
    WINDOW(anew, 300, 200);
    begin(&anew);
    CHECK(eglSwapBuffers(dpy, surface) && wayland.present_count == 1 && glGetError() == GL_NO_ERROR);
    finish();
}

static int swaps_held(void) {
    int n;
    HOST(n = host.swaps_held);
    return n;
}

static int times_let_go(void) {
    int n;
    HOST(n = host.let_go);
    return n;
}

/* The Mac, slow: it has drawn the picture a while after the program was
 * done with it. Long enough for a library that does not wait for it to be
 * found out; one that waits is right however long this is. */
static void *draws_after_a_while(void *unused) {
    (void)unused;
    usleep(50000);
    host_lets_go();
    return NULL;
}

/* A Swap is answered when the Mac has drawn the picture, and the library
 * reads that answer late: eglSwapBuffers returns without it, and the next
 * Swap of the stream, or the next command with an answer of its own,
 * waits for it first. So a program is one picture ahead of the Mac at
 * most, and one that lets go of everything with the answer still to come
 * waits for nothing. */
static void test_a_program_is_one_picture_ahead_of_the_mac_at_most(void) {
    WINDOW(window, 300, 200);
    begin(&window);

    /* A Mac that answers at once: each answer is read on the way, before what comes after it is. */
    for (int k = 0; k < 3; k++) {
        glClear(GL_COLOR_BUFFER_BIT);
        CHECK(eglSwapBuffers(dpy, surface));
    }
    HOST(host.error = GL_OUT_OF_MEMORY);
    CHECK(glGetError() == GL_OUT_OF_MEMORY); /* behind the third Swap's answer */
    CHECK(eglSwapBuffers(dpy, surface));
    uint8_t pixel[4] = {0};
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    for (size_t k = 0; k < sizeof pixel; k++) CHECK(pixel[k] == pixel_byte(k));
    CHECK(eglSwapBuffers(dpy, surface));
    glFinish();
    glFinish(); /* no Swap before this one: its own answer only */
    /* The answer is the stream's, whichever surface was swapped and whichever context asks next. */
    WINDOW(another, 20, 10);
    EGLSurface second_window = eglCreateWindowSurface(dpy, config, &another, NULL);
    EGLContext other = eglCreateContext(dpy, config, EGL_NO_CONTEXT, es2);
    CHECK(second_window != EGL_NO_SURFACE && other != EGL_NO_CONTEXT);
    CHECK(eglSwapBuffers(dpy, surface));
    CHECK(eglMakeCurrent(dpy, second_window, second_window, other) && eglSwapBuffers(dpy, second_window));
    HOST(host.status = GL_FRAMEBUFFER_COMPLETE);
    CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
    CHECK(eglMakeCurrent(dpy, surface, surface, context) && wayland.present_count == 7);
    sent();
    for (int k = 0; k < 3; k++) {
        expect(MGL_CLEAR, 1, GL_COLOR_BUFFER_BIT);
        expect(MGL_SWAP, 1, 1);
    }
    expect(MGL_GET_ERROR, 0);
    expect(MGL_SWAP, 1, 1);
    expect(MGL_READ_PIXELS, 6, 0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE);
    expect(MGL_SWAP, 1, 1);
    expect(MGL_FINISH, 0);
    expect(MGL_FINISH, 0);
    expect(MGL_SURFACE_CREATE, 6, 2, 20, 10, 1, 1, 1);
    expect(MGL_CONTEXT_CREATE, 2, 2, 0);
    expect(MGL_SWAP, 1, 1);
    expect(MGL_MAKE_CURRENT, 3, 2, 2, 2);
    expect(MGL_SWAP, 1, 2);
    expect(MGL_CHECK_FRAMEBUFFER_STATUS, 1, GL_FRAMEBUFFER);
    expect(MGL_MAKE_CURRENT, 3, 1, 1, 1);
    nothing_more();

    /* A Mac that takes its time. The first picture: the program goes on without it, and begins the next. Were
     * eglSwapBuffers to wait for the answer it would wait for ever: the alarm ends that. */
    HOST(host.holds_swaps = true);
    alarm(30);
    CHECK(eglSwapBuffers(dpy, surface));
    alarm(0);
    glClear(GL_DEPTH_BUFFER_BIT);
    sent();
    expect(MGL_SWAP, 1, 1);
    expect(MGL_CLEAR, 1, GL_DEPTH_BUFFER_BIT);
    CHECK(swaps_held() == 1 && times_let_go() == 0);
    /* The second picture is done before the first is drawn: its Swap waits for that, and goes then. (A Swap that
     * came while the answer before was held would fail the host.) */
    pthread_t mac;
    CHECK(pthread_create(&mac, NULL, draws_after_a_while, NULL) == 0);
    CHECK(eglSwapBuffers(dpy, surface));
    CHECK(times_let_go() == 1);
    CHECK(pthread_join(mac, NULL) == 0);
    host_settle();
    expect(MGL_SWAP, 1, 1);
    CHECK(swaps_held() == 1);
    /* A command with an answer waits for the picture too: its answer comes behind the Swap's. */
    HOST(host.error = GL_INVALID_VALUE);
    CHECK(pthread_create(&mac, NULL, draws_after_a_while, NULL) == 0);
    CHECK(glGetError() == GL_INVALID_VALUE);
    CHECK(times_let_go() == 2);
    CHECK(pthread_join(mac, NULL) == 0);
    host_settle();
    expect(MGL_GET_ERROR, 0);
    CHECK(swaps_held() == 0);
    /* No answer is unread now: the next picture waits for none. */
    alarm(30);
    CHECK(eglSwapBuffers(dpy, surface));
    alarm(0);
    host_settle();
    expect(MGL_SWAP, 1, 1);
    CHECK(swaps_held() == 1 && times_let_go() == 2 && wayland.present_count == 10);
    nothing_more();

    /* The program lets go of everything with that answer still to come (the thread of its context, the display,
     * and with it the stream): none of it waits for the answer, which goes with the stream. */
    alarm(30);
    CHECK(eglReleaseThread() && eglDestroySurface(dpy, second_window) && eglDestroyContext(dpy, other));
    finish();
    alarm(0);
    CHECK(host.swaps_held == 1 && host.let_go == 2);

    /* The next stream begins with no answer to read. */
    WINDOW(anew, 300, 200);
    begin(&anew);
    HOST(host.error = GL_INVALID_ENUM);
    CHECK(glGetError() == GL_INVALID_ENUM && eglSwapBuffers(dpy, surface));
    finish();
}

/* Commands wait in the library's buffer and go when they are more than
 * 64 KiB, however many calls that takes; a command larger than that goes
 * at once, whole. */
static void test_the_buffer_is_sent_when_it_passes_64_kib(void) {
    WINDOW(window, 300, 200);
    begin(&window);
    for (int k = 0; k < 100; k++) glClear(GL_COLOR_BUFFER_BIT);
    host_settle();
    CHECK(host.count == host.looked); /* 1200 bytes: nothing sent yet */
    for (int k = 100; k < 6000; k++) glClear(GL_COLOR_BUFFER_BIT);
    host_settle();
    /* A Clear is 12 bytes: the 5462nd made it more than 65536, and those went. The rest wait. */
    CHECK(host.count - host.looked == 5462);
    sent();
    CHECK(host.count - host.looked == 6000);
    for (int k = 0; k < 6000; k++) expect(MGL_CLEAR, 1, GL_COLOR_BUFFER_BIT);

    /* One command of 100 000 bytes, and one larger than the buffer is ever kept at: both arrive whole, and what follows too. */
    enum { LARGE = 100000, LARGER = 3 << 20 };
    uint8_t *bytes = malloc(LARGER);
    CHECK(bytes);
    for (size_t k = 0; k < LARGER; k++) bytes[k] = (uint8_t)(k * 31 + k / 255);
    GLuint buffer = 0;
    glGenBuffers(1, &buffer);
    glBindBuffer(GL_ARRAY_BUFFER, buffer);
    glBufferData(GL_ARRAY_BUFFER, LARGE, bytes, GL_STATIC_DRAW);
    host_settle();
    expect(MGL_BIND_BUFFER, 2, GL_ARRAY_BUFFER, buffer);
    expect_data(MGL_BUFFER_DATA, bytes, LARGE, 3, GL_ARRAY_BUFFER, LARGE, GL_STATIC_DRAW);
    glBufferData(GL_ARRAY_BUFFER, LARGER, bytes, GL_STREAM_DRAW);
    glClear(GL_DEPTH_BUFFER_BIT);
    host_settle();
    expect_data(MGL_BUFFER_DATA, bytes, LARGER, 3, GL_ARRAY_BUFFER, LARGER, GL_STREAM_DRAW);
    CHECK(host.count == host.looked);
    sent();
    expect(MGL_CLEAR, 1, GL_DEPTH_BUFFER_BIT);
    /* What is larger than a command may be is no command: the program is told there is no memory for it. */
    RAISES(glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)MWM_GL_COMMAND + 1, NULL, GL_STATIC_DRAW), GL_OUT_OF_MEMORY);
    GLint size = 0;
    glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_SIZE, &size);
    CHECK(size == LARGER);
    nothing_more();
    free(bytes);
    finish();
}

int main(void) {
    test_the_stream_begins_with_the_handshake();
    test_contexts_and_surfaces_are_named_and_made_current();
    test_a_frame_of_gears();
    test_texture_rows_arrive_tight_whatever_the_alignment();
    test_vertices_in_the_programs_memory_travel_with_the_draw();
    test_what_a_program_asks_is_answered_without_the_mac();
    test_read_pixels_honours_the_pack_alignment();
    test_errors_found_here_and_calls_without_a_context();
    test_configs_are_chosen_in_egls_order();
    test_a_surface_has_the_buffers_of_its_config();
    test_every_entry_point_has_an_address();
    test_a_host_that_hangs_up_or_answers_nonsense_loses_the_stream();
    test_a_program_is_one_picture_ahead_of_the_mac_at_most();
    test_the_buffer_is_sent_when_it_passes_64_kib();
    /* Every command the header has was sent by some test, and taken apart by the host. */
    for (int op = 1; op <= MGL_OP_LAST; op++) {
        if (grammar[op] && !ops_seen[op]) fprintf(stderr, "command %d was never sent\n", op);
        CHECK(!grammar[op] || ops_seen[op] > 0);
    }
    free(host.pending);
    free(host.bytes);
    free(host.commands);
    free(host.held);
    printf("test_gl_lib: %d checks passed\n", checks);
    return 0;
}
