//
//  GLStream.swift — a Linux program's OpenGL ES 2.0 drawing, carried out
//  by this Mac's GPU. Apple passes no GPU to a Linux guest, so a library
//  of Monad's own in the guest writes each OpenGL call down as a command
//  (GuestWM/mwm_gl_wire.h says how), and here the commands of one program
//  are read and done with Metal: this file reads them, GLContext.swift and
//  GLObjects.swift keep what OpenGL keeps, GLTextures.swift, GLPrograms.swift
//  and GLDraw.swift do the work (GLFormats.swift says what OpenGL's formats
//  are to Metal), and what a window's surface shows is handed on as the
//  memory it was drawn into.
//
//  The stream is a guest's and is read as hostile. A command says how long
//  it is, and nothing of it is read past that; what it asks for is checked
//  as OpenGL checks it, and again against what Metal can be handed
//  without reading or writing outside anything; everything it can make
//  the Mac keep has a bound (GLLimits). A command that is not as the
//  header describes is OpenGL's GL_INVALID_OPERATION and the stream goes
//  on with the next; only a length that is none ends it.
//

import Foundation
import IOSurface
import Metal

/// The bounds one stream is held to.
enum GLLimits {
    /// MWM_GL_COMMAND and MWM_GL_REPLY: the largest command and the largest answer.
    static let command = (64 << 20) + 4096
    static let reply = (64 << 20) + 4096
    /// A side of a surface, a texture, a renderbuffer or the viewport.
    static let side = 4096
    /// The levels a texture of that side has.
    static let levels = 13
    static let attributes = 16
    static let units = 32
    /// A stream's buffers, its textures with its renderbuffers, and its surfaces, in bytes.
    static let bufferBytes = 256 << 20
    static let textureBytes = 512 << 20
    static let surfaceBytes = 1 << 30
    /// Its shaders' texts and its programs' uniform blocks, in bytes; one program's block.
    static let sourceBytes = 16 << 20
    static let uniformBytes = 64 << 20
    static let blockBytes = 1 << 20
    /// The buffers, textures, renderbuffers, framebuffers, shaders and programs it names.
    static let objects = 1 << 16
    static let contexts = 64
    static let surfaces = 64
    /// What a command buffer may hold on to before it is sent off: the
    /// copies made for its draws, and what was let go while it could
    /// still draw with it.
    static let pendingBytes = 64 << 20
    /// The arrays that came for the next draw (ClientArray), in bytes.
    static let clientBytes = 128 << 20
    /// The vertices of one draw.
    static let drawVertices = 1 << 24
    static let logBytes = 1 << 16
    static let nameBytes = 1024
    /// The names glBindAttribLocation gave one program, and the uniforms one has.
    static let bindings = 256
    static let uniforms = 4096
    /// The programs linked at one time, and the pipelines and the depth and stencil states kept for drawing again: past
    /// it a program does not link, and the states are made anew.
    static let programs = 4096
    static let pipelines = 1024
    static let states = 256
    /// The passes and the draws of one command buffer, which is then sent off and waited for. Metal keeps every one of
    /// them until it is, and it takes no more than some 25,000 passes in one: past that the command buffer fails, and
    /// with it every one this process makes afterwards, for every VM. This is far below.
    static let passes = 512
    static let draws = 1 << 16
}

/// The commands' numbers, as mwm_gl_wire.h has them.
enum GLOp {
    static let contextCreate: UInt32 = 1, contextDestroy: UInt32 = 2, surfaceCreate: UInt32 = 3, surfaceResize: UInt32 = 4
    static let surfaceDestroy: UInt32 = 5, makeCurrent: UInt32 = 6, swap: UInt32 = 7
    static let activeTexture: UInt32 = 16, attachShader: UInt32 = 17, bindAttribLocation: UInt32 = 18, bindBuffer: UInt32 = 19
    static let bindFramebuffer: UInt32 = 20, bindRenderbuffer: UInt32 = 21, bindTexture: UInt32 = 22, blendColor: UInt32 = 23
    static let blendEquation: UInt32 = 24, blendEquationSeparate: UInt32 = 25, blendFunc: UInt32 = 26, blendFuncSeparate: UInt32 = 27
    static let bufferData: UInt32 = 28, bufferSubData: UInt32 = 29, checkFramebufferStatus: UInt32 = 30, clear: UInt32 = 31
    static let clearColor: UInt32 = 32, clearDepthf: UInt32 = 33, clearStencil: UInt32 = 34, colorMask: UInt32 = 35
    static let compileShader: UInt32 = 36, copyTexImage2D: UInt32 = 37, copyTexSubImage2D: UInt32 = 38, createProgram: UInt32 = 39
    static let createShader: UInt32 = 40, cullFace: UInt32 = 41, deleteBuffers: UInt32 = 42, deleteFramebuffers: UInt32 = 43
    static let deleteProgram: UInt32 = 44, deleteRenderbuffers: UInt32 = 45, deleteShader: UInt32 = 46, deleteTextures: UInt32 = 47
    static let depthFunc: UInt32 = 48, depthMask: UInt32 = 49, depthRangef: UInt32 = 50, detachShader: UInt32 = 51
    static let disable: UInt32 = 52, disableVertexAttribArray: UInt32 = 53, drawArrays: UInt32 = 54, drawElements: UInt32 = 55
    static let drawElementsClient: UInt32 = 56, clientArray: UInt32 = 57, enable: UInt32 = 58, enableVertexAttribArray: UInt32 = 59
    static let finish: UInt32 = 60, framebufferRenderbuffer: UInt32 = 61, framebufferTexture2D: UInt32 = 62, frontFace: UInt32 = 63
    static let generateMipmap: UInt32 = 64, getError: UInt32 = 65, getUniform: UInt32 = 66, lineWidth: UInt32 = 67
    static let linkProgram: UInt32 = 68, polygonOffset: UInt32 = 69, readPixels: UInt32 = 70, renderbufferStorage: UInt32 = 71
    static let sampleCoverage: UInt32 = 72, scissor: UInt32 = 73, shaderSource: UInt32 = 74, stencilFunc: UInt32 = 75
    static let stencilFuncSeparate: UInt32 = 76, stencilMask: UInt32 = 77, stencilMaskSeparate: UInt32 = 78, stencilOp: UInt32 = 79
    static let stencilOpSeparate: UInt32 = 80, texImage2D: UInt32 = 81, texParameterf: UInt32 = 82, texParameteri: UInt32 = 83
    static let texSubImage2D: UInt32 = 84
    /// Uniform1f…4f, 1i…4i, 1fv…4fv, 1iv…4iv and UniformMatrix2fv…4fv follow one another from here.
    static let uniform1f: UInt32 = 85, uniform1i: UInt32 = 89, uniform1fv: UInt32 = 93, uniform1iv: UInt32 = 97
    static let uniformMatrix2fv: UInt32 = 101, uniformMatrix4fv: UInt32 = 103
    static let useProgram: UInt32 = 104, vertexAttrib4f: UInt32 = 105, vertexAttribPointer: UInt32 = 106, viewport: UInt32 = 107

    /// MWM_GL_NONE: the count of a `data` argument that stands for a NULL pointer.
    static let none: UInt32 = 0xffff_ffff

    /// The commands the program's side waits for an answer to. It gets
    /// one whatever became of the command, or it would wait for ever.
    /// (A swap's it reads late, before its next swap: that is what keeps
    /// a program from being more than a picture ahead of the Mac.)
    static func isAnswered(_ op: UInt32) -> Bool {
        [swap, checkFramebufferStatus, compileShader, finish, getError, getUniform, linkProgram, readPixels].contains(op)
    }
}

/// A command's arguments were not what the header says the command has.
struct GLMalformed: Error {}

/// Reads a command's arguments: words, and `data` (a count of bytes, the
/// bytes, zeros up to a multiple of four). Nothing is read that the
/// command's own length does not cover.
struct GLArguments {
    private let bytes: UnsafeRawBufferPointer
    private var at = 0

    init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    mutating func word() throws -> UInt32 {
        guard bytes.count - at >= 4 else { throw GLMalformed() }
        defer { at += 4 }
        return UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
    }

    mutating func int() throws -> Int {
        Int(Int32(bitPattern: try word()))
    }

    mutating func float() throws -> Float {
        Float(bitPattern: try word())
    }

    mutating func flag() throws -> Bool {
        try word() != 0
    }

    /// A word the header says is 0 or 1 and nothing else.
    mutating func bit() throws -> Bool {
        let value = try word()
        guard value <= 1 else { throw GLMalformed() }
        return value == 1
    }

    /// `count` words as they lie in the command.
    mutating func words(_ count: Int) throws -> UnsafeRawBufferPointer {
        guard count >= 0, count <= (bytes.count - at) / 4 else { throw GLMalformed() }
        defer { at += count * 4 }
        return UnsafeRawBufferPointer(rebasing: bytes[at..<at + count * 4])
    }

    /// nil for MWM_GL_NONE, which stands for a NULL pointer.
    mutating func data() throws -> UnsafeRawBufferPointer? {
        let count = try word()
        if count == GLOp.none { return nil }
        // What is left is under MWM_GL_COMMAND and a multiple of four, so the padded count neither overflows nor passes it.
        guard UInt64(count) <= UInt64(bytes.count - at) else { throw GLMalformed() }
        let length = Int(count)
        defer { at += (length + 3) & ~3 }
        return UnsafeRawBufferPointer(rebasing: bytes[at..<at + length])
    }

    /// `data` where the call takes no NULL.
    mutating func bytesGiven() throws -> UnsafeRawBufferPointer {
        guard let data = try data() else { throw GLMalformed() }
        return data
    }

    /// A command has its arguments and nothing after them.
    func end() throws {
        guard at == bytes.count else { throw GLMalformed() }
    }
}

/// An answer: words and `data`, with the u32 length the program's side reads first.
struct GLReply {
    private(set) var bytes = Data(count: 4)

    mutating func word(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func data(_ data: UnsafeRawBufferPointer) {
        self.data(count: data.count) { $0.copyMemory(from: data) }
    }

    /// `data` of `count` bytes, zeros until `fill` writes them where they will be sent from.
    mutating func data(count: Int, _ fill: (UnsafeMutableRawBufferPointer) -> Void) {
        word(UInt32(truncatingIfNeeded: count))
        let start = bytes.count
        bytes.count = start + ((count + 3) & ~3)
        if count > 0 {
            bytes.withUnsafeMutableBytes { fill(UnsafeMutableRawBufferPointer(rebasing: $0[start..<start + count])) }
        }
    }

    /// A text, cut to `limit` bytes: what a translator says about a guest's shader is as long as the shader likes.
    mutating func text(_ text: String, limit: Int = GLLimits.logBytes) {
        Data(text.utf8.prefix(limit)).withUnsafeBytes { data($0) }
    }

    /// The bytes to send: the length, then what was written.
    mutating func sealed() -> Data {
        let length = UInt32(truncatingIfNeeded: bytes.count - 4).littleEndian
        withUnsafeBytes(of: length) { bytes.replaceSubrange(0..<4, with: $0) }
        return bytes
    }
}

/// One program's drawing: the commands of one stream, carried out with Metal.
final class GLStream {
    let device: MTLDevice
    let translator: GLShaderTranslating
    private let reply: (Data) -> Void
    private let present: (UInt32, IOSurface, Int, Int) -> Void
    let queue: MTLCommandQueue?
    let budget = GLBudget()

    var contexts: [UInt32: GLContext] = [:]
    var surfaces: [UInt32: GLSurface] = [:]
    var current: GLContext?
    /// A command that came in part: its bytes so far, at most MWM_GL_COMMAND of them.
    private var partial: [UInt8] = []
    /// Over: it said something that cannot be gone on from, was closed, or the GPU gave up on what it drew.
    var ended = false

    // What GLDraw.swift draws with.
    var commands: MTLCommandBuffer?
    var pass: GLPass?
    var blit: MTLBlitCommandEncoder?
    var arena: GLArena
    var samplers: [GLSamplerKey: MTLSamplerState] = [:]
    var depthStencils: [GLDepthStencilKey: MTLDepthStencilState] = [:]
    var pipelines: [GLPipelineKey: MTLRenderPipelineState?] = [:]
    /// The passes begun and the draws and copies written in `commands` so far.
    var passes = 0
    var encoded = 0
    var quads: GLQuads?
    var black: (flat: MTLTexture, cube: MTLTexture)?

    /// `reply`: the bytes of an answer, to send back on the stream as they are (the u32 length included).
    /// `present`: a surface's picture is done (Swap): the memory it is in, upright (row 0 is the top), BGRA
    /// premultiplied (every alpha 1 when the surface was made without alpha), and its size. Its rules:
    /// - It is called when the picture is whole: the GPU has finished the commands that drew it, not merely been
    ///   handed them. It may be called from any thread (as things are, by the thread that feeds the stream, from
    ///   within `feed`), a surface's pictures in the order they were swapped.
    /// - Whoever is handed a picture marks it as in use before `present` returns (IOSurface.incrementUseCount) for as
    ///   long as it shows it, and lets go (decrementUseCount) when it shows a newer one.
    /// - The surface's next picture is drawn only into memory that is not in use. When there is none, more is made,
    ///   up to GLSurface.pictures a surface and the stream's bound on its surfaces' bytes; when that many are all in
    ///   use, the one presented longest ago is drawn into again.
    /// - A swap waits for the GPU and for nothing else: never for the main thread, the display, or whoever shows
    ///   the pictures. Its answer (`reply`, of no length) is sent after `present` has returned.
    init(device: MTLDevice, translator: GLShaderTranslating,
         reply: @escaping (Data) -> Void,
         present: @escaping (_ surface: UInt32, _ picture: IOSurface, _ width: Int, _ height: Int) -> Void) {
        self.device = device
        self.translator = translator
        self.reply = reply
        self.present = present
        // Metal hands its objects out by way of the autorelease pool, and whoever calls this may drain one rarely, or
        // never while the stream lives. Nothing of a stream is to live on in a pool: each is drained here.
        queue = autoreleasepool { device.makeCommandQueue() }
        arena = GLArena(device: device)
    }

    deinit {
        close()
    }

    /// The stream's bytes as they arrive, split anywhere. False: the stream said something that
    /// cannot be gone on from (a size that is none, a command larger than MWM_GL_COMMAND) and is to be closed.
    func feed(_ data: Data) -> Bool {
        guard !ended else { return false }
        // Data may lie in several pieces; each is read where it is.
        for region in data.regions where !ended {
            region.withUnsafeBytes { read($0) }
        }
        return !ended
    }

    /// The program is gone: everything of it is let go.
    func close() {
        ended = true
        partial = []
        autoreleasepool {
            // Metal wants an encoder ended before it is let go of. What was drawn and not yet handed to the GPU goes
            // with the stream.
            pass?.encoder?.endEncoding()
            pass = nil
            blit?.endEncoding()
            blit = nil
            commands = nil
            current = nil
            contexts = [:]
            surfaces = [:]
            arena.reset(recycle: false)
        }
    }

    // MARK: Reading

    /// The length a command's header gives, or nil when it is none: under
    /// the header's own, no multiple of four, or past MWM_GL_COMMAND.
    private static func size(_ header: UnsafeRawBufferPointer) -> Int? {
        guard header.count >= 8 else { return nil }
        let size = UInt32(littleEndian: header.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        guard size >= 8, size % 4 == 0, size <= UInt32(GLLimits.command) else { return nil }
        return Int(size)
    }

    /// Carries out the whole commands in `input`, with what was left of
    /// the one before, and keeps what is left of the last.
    private func read(_ input: UnsafeRawBufferPointer) {
        var at = 0
        while at < input.count, !ended {
            if partial.isEmpty, input.count - at >= 8 {
                // The usual case: the command lies whole in what came, and is read where it is.
                guard let size = Self.size(UnsafeRawBufferPointer(rebasing: input[at..<at + 8])) else {
                    ended = true
                    return
                }
                if size <= input.count - at {
                    execute(UnsafeRawBufferPointer(rebasing: input[at..<at + size]))
                    at += size
                    continue
                }
            }
            // Its header first, which says how much more belongs to it; never more than that is kept.
            var wanted = 8
            if partial.count >= 8 {
                guard let size = partial.withUnsafeBytes({ Self.size($0) }) else {
                    ended = true
                    return
                }
                wanted = size
                if partial.capacity < size { partial.reserveCapacity(size) }
            }
            let take = min(wanted - partial.count, input.count - at)
            partial.append(contentsOf: UnsafeRawBufferPointer(rebasing: input[at..<at + take]))
            at += take
            guard partial.count >= 8 else { continue }
            guard let size = partial.withUnsafeBytes({ Self.size($0) }) else {
                ended = true
                return
            }
            if partial.count == size {
                partial.withUnsafeBytes { execute($0) }
                partial = []
            }
        }
    }

    /// One whole command: its header and its arguments.
    private func execute(_ command: UnsafeRawBufferPointer) {
        guard command.count >= 8 else { return }
        autoreleasepool { carryOut(command) }
    }

    private func carryOut(_ command: UnsafeRawBufferPointer) {
        // What the draws so far hold on to has a bound: past it they are sent off and waited for.
        if budget.retired + arena.pending > GLLimits.pendingBytes || passes >= GLLimits.passes || encoded >= GLLimits.draws { flush() }
        let op = UInt32(littleEndian: command.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        var arguments = GLArguments(UnsafeRawBufferPointer(rebasing: command[8...]))
        do {
            if op < GLOp.activeTexture {
                try own(op, &arguments)
            } else if let context = current {
                try call(op, &arguments, context)
            } else if GLOp.isAnswered(op) {
                // No context is current: OpenGL does nothing, and an answer is owed all the same.
                unanswered(op, nil)
            }
        } catch {
            current?.fail(GL.INVALID_OPERATION)
            // Arrays that came for a draw hold for that draw alone, also when it is not as the header says.
            if [GLOp.drawArrays, GLOp.drawElements, GLOp.drawElementsClient].contains(op) { current?.dropClientArrays() }
            if GLOp.isAnswered(op) { unanswered(op, current) }
        }
    }

    func send(_ reply: inout GLReply) {
        self.reply(reply.sealed())
    }

    /// The answer to a command that could not be carried out: what the
    /// header says the answer has, saying nothing. The program's side
    /// takes any other shape for a stream gone wrong.
    private func unanswered(_ op: UInt32, _ context: GLContext?) {
        var reply = GLReply()
        switch op {
        case GLOp.getError, GLOp.checkFramebufferStatus:
            reply.word(op == GLOp.getError ? context?.takeError() ?? GL.NO_ERROR : 0)
        case GLOp.compileShader:
            reply.word(0)
            reply.text("")
        case GLOp.linkProgram:
            reply.word(0)
            reply.text("")
            reply.word(0)
            reply.word(0)
        case GLOp.readPixels:
            // No pixels is an answer of no length, not one of data that is empty.
            break
        case GLOp.getUniform:
            reply.word(0)
            reply.text("")
        default:
            break
        }
        send(&reply)
    }

    // MARK: Contexts and surfaces (EGL's side)

    /// EGL has no error that travels: what cannot be carried out here is an OpenGL error of the context that is
    /// current, if there is one. Destroying what is not there is ignored, as OpenGL's deleting is.
    private func own(_ op: UInt32, _ arguments: inout GLArguments) throws {
        switch op {
        case GLOp.contextCreate:
            let name = try arguments.word(), share = try arguments.word()
            try arguments.end()
            // No name, a name that is taken, or objects to share that are no context's: not as the header describes.
            guard name != 0, contexts[name] == nil, share == 0 || contexts[share] != nil else { throw GLMalformed() }
            guard contexts.count < GLLimits.contexts else {
                current?.fail(GL.OUT_OF_MEMORY)
                return
            }
            contexts[name] = GLContext(name: name, share: contexts[share]?.share ?? GLShareGroup(), budget: budget)
        case GLOp.contextDestroy:
            let name = try arguments.word()
            try arguments.end()
            guard let context = contexts.removeValue(forKey: name) else { return }
            // As EGL has it, the current one lives on until another is made current.
            if context === current {
                context.destroyed = true
            } else {
                retire(context)
            }
        case GLOp.surfaceCreate:
            let name = try arguments.word(), width = try arguments.int(), height = try arguments.int()
            let alpha = try arguments.bit(), depth = try arguments.bit(), stencil = try arguments.bit()
            try arguments.end()
            // A surface is made once, under a name.
            guard name != 0, surfaces[name] == nil else { throw GLMalformed() }
            guard surfaces.count < GLLimits.surfaces else {
                current?.fail(GL.OUT_OF_MEMORY)
                return
            }
            size(GLSurface(name: name, alpha: alpha, depth: depth, stencil: stencil, budget: budget), width: width, height: height)
        case GLOp.surfaceResize:
            let name = try arguments.word(), width = try arguments.int(), height = try arguments.int()
            try arguments.end()
            guard let surface = surfaces[name] else { throw GLMalformed() }
            size(surface, width: width, height: height)
        case GLOp.surfaceDestroy:
            let name = try arguments.word()
            try arguments.end()
            // A context it is current to draws on it until it is told of another, as EGL has it.
            surfaces[name] = nil
        case GLOp.makeCurrent:
            let name = try arguments.word(), draw = try arguments.word(), read = try arguments.word()
            try arguments.end()
            // A name that is no context's leaves none current, and what follows does nothing: better than having it
            // done to the context that was current, which it was not meant for.
            makeCurrent(contexts[name], draw: surfaces[draw], read: surfaces[read])
            // A name that is no surface's leaves the context with nothing there to draw on or to read.
            if (draw != 0 && surfaces[draw] == nil) || (read != 0 && surfaces[read] == nil) { throw GLMalformed() }
        case GLOp.swap:
            let name = try arguments.word()
            try arguments.end()
            guard surfaces[name] != nil else { throw GLMalformed() }
            swap(name)
        default:
            throw GLMalformed()
        }
    }

    /// Gives a surface, new or not, memory of a size. It keeps the buffers it was made with.
    private func size(_ surface: GLSurface, width: Int, height: Int) {
        guard (1...GLLimits.side).contains(width), (1...GLLimits.side).contains(height) else {
            current?.fail(GL.INVALID_VALUE)
            return
        }
        if surface.width == width, surface.height == height { return }
        // What is being drawn to it is drawn to the memory it has now.
        endEncoders()
        guard budget.surfaceBytes - surface.heldBytes + surface.bytes(width: width, height: height) <= GLLimits.surfaceBytes,
              let picture = surface.resize(width: width, height: height, device: device) else {
            current?.fail(GL.OUT_OF_MEMORY)
            return
        }
        surfaces[surface.name] = surface
        // Fresh memory shows nothing of anything that was in it before.
        clear(picture, slice: 0, level: 0, alpha: surface.alpha)
        if let depthStencil = surface.depthStencil {
            clear(depthStencil, slice: 0, level: 0, alpha: true)
        }
    }

    private func makeCurrent(_ context: GLContext?, draw: GLSurface?, read: GLSurface?) {
        if let old = current, old !== context {
            // Arrays that came for a draw that did not: they were for the next call, which is another context's.
            old.dropClientArrays()
            old.draw = nil
            old.read = nil
            if old.destroyed { retire(old) }
        }
        current = context
        guard let context else { return }
        context.draw = draw
        context.read = read
        if !context.sized, let draw {
            context.sized = true
            context.viewport = GLRect(x: 0, y: 0, width: draw.width, height: draw.height)
            context.scissor = context.viewport
        }
    }

    /// A context is gone: the program it was using is used by one less.
    private func retire(_ context: GLContext) {
        if let program = context.program {
            context.program = nil
            unuse(program, in: context.share)
        }
    }

    /// The picture a surface was being drawn is done: it is handed over to be shown, and the next is drawn into
    /// memory that nothing shows.
    private func swap(_ name: UInt32) {
        // The answer says the picture is drawn, and the program draws no other until it has it: sent last of all.
        defer {
            var reply = GLReply()
            send(&reply)
        }
        guard let surface = surfaces[name], let picture = surface.picture else { return }
        if picture.texture.storageMode == .managed {
            blitEncoder()?.synchronize(resource: picture.texture)
        }
        // The GPU has drawn all of the picture when this returns: it is whole when it is handed over.
        flush()
        // A picture the GPU gave up on is not one to show.
        guard !ended else { return }
        present(name, picture.surface, surface.width, surface.height)
        // Whoever shows it has marked it as in use by now.
        if let fresh = surface.advance(device: device) {
            clear(fresh, slice: 0, level: 0, alpha: surface.alpha)
        }
    }

    // MARK: OpenGL's calls

    private func call(_ op: UInt32, _ a: inout GLArguments, _ context: GLContext) throws {
        switch op {
        case GLOp.activeTexture:
            let texture = try a.word()
            try a.end()
            context.activeTexture(texture)
        case GLOp.attachShader, GLOp.detachShader:
            let program = try a.word(), shader = try a.word()
            try a.end()
            attach(context, program: program, shader: shader, detach: op == GLOp.detachShader)
        case GLOp.bindAttribLocation:
            let program = try a.word(), index = try a.word(), name = try a.bytesGiven()
            try a.end()
            bindAttributeLocation(context, program: program, index: index, name: name)
        case GLOp.bindBuffer:
            let target = try a.word(), name = try a.word()
            try a.end()
            bindBuffer(context, target: target, name: name)
        case GLOp.bindFramebuffer:
            let target = try a.word(), name = try a.word()
            try a.end()
            bindFramebuffer(context, target: target, name: name)
        case GLOp.bindRenderbuffer:
            let target = try a.word(), name = try a.word()
            try a.end()
            bindRenderbuffer(context, target: target, name: name)
        case GLOp.bindTexture:
            let target = try a.word(), name = try a.word()
            try a.end()
            bindTexture(context, target: target, name: name)
        case GLOp.blendColor:
            let red = try a.float(), green = try a.float(), blue = try a.float(), alpha = try a.float()
            try a.end()
            context.set(blendColor: red, green, blue, alpha)
        case GLOp.blendEquation:
            let mode = try a.word()
            try a.end()
            context.blendEquation(rgb: mode, alpha: mode)
        case GLOp.blendEquationSeparate:
            let rgb = try a.word(), alpha = try a.word()
            try a.end()
            context.blendEquation(rgb: rgb, alpha: alpha)
        case GLOp.blendFunc:
            let source = try a.word(), destination = try a.word()
            try a.end()
            context.blendFunction(sourceRGB: source, destinationRGB: destination, sourceAlpha: source, destinationAlpha: destination)
        case GLOp.blendFuncSeparate:
            let sourceRGB = try a.word(), destinationRGB = try a.word(), sourceAlpha = try a.word(), destinationAlpha = try a.word()
            try a.end()
            context.blendFunction(sourceRGB: sourceRGB, destinationRGB: destinationRGB, sourceAlpha: sourceAlpha, destinationAlpha: destinationAlpha)
        case GLOp.bufferData:
            let target = try a.word(), size = try a.int(), usage = try a.word(), data = try a.data()
            try a.end()
            bufferData(context, target: target, size: size, usage: usage, data: data)
        case GLOp.bufferSubData:
            let target = try a.word(), offset = try a.int(), data = try a.bytesGiven()
            try a.end()
            bufferSubData(context, target: target, offset: offset, data: data)
        case GLOp.checkFramebufferStatus:
            let target = try a.word()
            try a.end()
            var reply = GLReply()
            if target == GL.FRAMEBUFFER {
                reply.word(framebufferStatus(context).status)
            } else {
                context.fail(GL.INVALID_ENUM)
                reply.word(0)
            }
            send(&reply)
        case GLOp.clear:
            let mask = try a.word()
            try a.end()
            clear(context, mask: mask)
        case GLOp.clearColor:
            let red = try a.float(), green = try a.float(), blue = try a.float(), alpha = try a.float()
            try a.end()
            context.set(clearColor: red, green, blue, alpha)
        case GLOp.clearDepthf:
            let depth = try a.float()
            try a.end()
            context.set(clearDepth: depth)
        case GLOp.clearStencil:
            let stencil = try a.int()
            try a.end()
            context.clearStencil = stencil
        case GLOp.colorMask:
            let red = try a.flag(), green = try a.flag(), blue = try a.flag(), alpha = try a.flag()
            try a.end()
            context.set(colorMask: red, green, blue, alpha)
        case GLOp.compileShader:
            let shader = try a.word()
            try a.end()
            compile(context, shader: shader)
        case GLOp.copyTexImage2D:
            let target = try a.word(), level = try a.int(), format = try a.word(), x = try a.int(), y = try a.int()
            let width = try a.int(), height = try a.int(), border = try a.int()
            try a.end()
            copyTexImage(context, target: target, level: level, format: format, x: x, y: y, width: width, height: height, border: border)
        case GLOp.copyTexSubImage2D:
            let target = try a.word(), level = try a.int(), xOffset = try a.int(), yOffset = try a.int()
            let x = try a.int(), y = try a.int(), width = try a.int(), height = try a.int()
            try a.end()
            copyTexSubImage(context, target: target, level: level, xOffset: xOffset, yOffset: yOffset, x: x, y: y, width: width, height: height)
        case GLOp.createProgram:
            let name = try a.word()
            try a.end()
            createProgram(context, name: name)
        case GLOp.createShader:
            let name = try a.word(), type = try a.word()
            try a.end()
            createShader(context, name: name, type: type)
        case GLOp.cullFace:
            let mode = try a.word()
            try a.end()
            context.set(cullFace: mode)
        case GLOp.deleteBuffers, GLOp.deleteFramebuffers, GLOp.deleteRenderbuffers, GLOp.deleteTextures:
            let count = try a.int(), names = try a.bytesGiven()
            try a.end()
            guard count >= 0 else { return context.fail(GL.INVALID_VALUE) }
            guard names.count / 4 == count, names.count % 4 == 0 else { throw GLMalformed() }
            for index in 0..<count {
                let name = UInt32(littleEndian: names.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
                guard name != 0 else { continue }
                switch op {
                case GLOp.deleteBuffers: deleteBuffer(context, name: name)
                case GLOp.deleteFramebuffers: deleteFramebuffer(context, name: name)
                case GLOp.deleteRenderbuffers: deleteRenderbuffer(context, name: name)
                default: deleteTexture(context, name: name)
                }
            }
        case GLOp.deleteProgram:
            let name = try a.word()
            try a.end()
            deleteProgram(context, name: name)
        case GLOp.deleteShader:
            let name = try a.word()
            try a.end()
            deleteShader(context, name: name)
        case GLOp.depthFunc:
            let function = try a.word()
            try a.end()
            context.set(depthFunction: function)
        case GLOp.depthMask:
            let flag = try a.flag()
            try a.end()
            context.depthMask = flag
        case GLOp.depthRangef:
            let near = try a.float(), far = try a.float()
            try a.end()
            context.depthRange(near, far)
        case GLOp.disable, GLOp.enable:
            let capability = try a.word()
            try a.end()
            context.set(capability: capability, op == GLOp.enable)
        case GLOp.disableVertexAttribArray, GLOp.enableVertexAttribArray:
            let index = try a.word()
            try a.end()
            context.vertexArray(index, enabled: op == GLOp.enableVertexAttribArray)
        case GLOp.drawArrays:
            let mode = try a.word(), first = try a.int(), count = try a.int()
            try a.end()
            draw(context, mode: mode, .arrays(first: first, count: count))
        case GLOp.drawElements:
            let mode = try a.word(), count = try a.int(), type = try a.word(), offset = try a.word()
            try a.end()
            draw(context, mode: mode, .elements(count: count, type: type, offset: Int(offset)))
        case GLOp.drawElementsClient:
            let mode = try a.word(), count = try a.int(), type = try a.word(), indices = try a.bytesGiven()
            try a.end()
            draw(context, mode: mode, .client(count: count, type: type, indices: indices))
        case GLOp.clientArray:
            let index = try a.word(), size = try a.int(), type = try a.word(), normalized = try a.flag(), first = try a.int()
            let data = try a.bytesGiven()
            try a.end()
            clientArray(context, index: index, size: size, type: type, normalized: normalized, first: first, data: data)
        case GLOp.finish:
            try a.end()
            flush()
            var reply = GLReply()
            send(&reply)
        case GLOp.framebufferRenderbuffer:
            let target = try a.word(), attachment = try a.word(), renderbufferTarget = try a.word(), name = try a.word()
            try a.end()
            framebufferRenderbuffer(context, target: target, attachment: attachment, renderbufferTarget: renderbufferTarget, name: name)
        case GLOp.framebufferTexture2D:
            let target = try a.word(), attachment = try a.word(), textureTarget = try a.word(), name = try a.word(), level = try a.int()
            try a.end()
            framebufferTexture(context, target: target, attachment: attachment, textureTarget: textureTarget, name: name, level: level)
        case GLOp.frontFace:
            let mode = try a.word()
            try a.end()
            context.set(frontFace: mode)
        case GLOp.generateMipmap:
            let target = try a.word()
            try a.end()
            generateMipmap(context, target: target)
        case GLOp.getError:
            try a.end()
            var reply = GLReply()
            reply.word(context.takeError())
            send(&reply)
        case GLOp.getUniform:
            let program = try a.word(), location = try a.int()
            try a.end()
            getUniform(context, program: program, location: location)
        case GLOp.lineWidth:
            let width = try a.float()
            try a.end()
            context.check(lineWidth: width)
        case GLOp.linkProgram:
            let program = try a.word()
            try a.end()
            link(context, program: program)
        case GLOp.polygonOffset:
            let factor = try a.float(), units = try a.float()
            try a.end()
            context.polygonOffset(factor: factor, units: units)
        case GLOp.readPixels:
            let x = try a.int(), y = try a.int(), width = try a.int(), height = try a.int(), format = try a.word(), type = try a.word()
            try a.end()
            readPixels(context, x: x, y: y, width: width, height: height, format: format, type: type)
        case GLOp.renderbufferStorage:
            let target = try a.word(), format = try a.word(), width = try a.int(), height = try a.int()
            try a.end()
            renderbufferStorage(context, target: target, format: format, width: width, height: height)
        case GLOp.sampleCoverage:
            // Nothing here has several samples a pixel for a coverage to be of.
            _ = (try a.float(), try a.flag())
            try a.end()
        case GLOp.scissor:
            let x = try a.int(), y = try a.int(), width = try a.int(), height = try a.int()
            try a.end()
            context.set(scissor: x, y, width, height)
        case GLOp.shaderSource:
            let shader = try a.word(), source = try a.bytesGiven()
            try a.end()
            shaderSource(context, shader: shader, source: source)
        case GLOp.stencilFunc, GLOp.stencilFuncSeparate:
            let face = op == GLOp.stencilFunc ? GL.FRONT_AND_BACK : try a.word()
            let function = try a.word(), reference = try a.int(), mask = try a.word()
            try a.end()
            context.stencilFunction(face: face, function: function, reference: reference, mask: mask)
        case GLOp.stencilMask, GLOp.stencilMaskSeparate:
            let face = op == GLOp.stencilMask ? GL.FRONT_AND_BACK : try a.word()
            let mask = try a.word()
            try a.end()
            context.stencilMask(face: face, mask: mask)
        case GLOp.stencilOp, GLOp.stencilOpSeparate:
            let face = op == GLOp.stencilOp ? GL.FRONT_AND_BACK : try a.word()
            let fail = try a.word(), depthFail = try a.word(), pass = try a.word()
            try a.end()
            context.stencilOperation(face: face, fail: fail, depthFail: depthFail, pass: pass)
        case GLOp.texImage2D:
            let target = try a.word(), level = try a.int(), internalFormat = try a.word(), width = try a.int(), height = try a.int()
            let border = try a.int(), format = try a.word(), type = try a.word(), data = try a.data()
            try a.end()
            texImage(context, target: target, level: level, internalFormat: internalFormat, width: width, height: height,
                     border: border, format: format, type: type, data: data)
        case GLOp.texParameterf:
            let target = try a.word(), name = try a.word(), value = try a.float()
            try a.end()
            // The parameters OpenGL ES 2.0 has are all enums; as a float, one is its number.
            let number = value >= 0 && value < 65536 ? UInt32(value) : GLOp.none
            texParameter(context, target: target, name: name, value: Float(number) == value ? number : GLOp.none)
        case GLOp.texParameteri:
            let target = try a.word(), name = try a.word(), value = try a.word()
            try a.end()
            texParameter(context, target: target, name: name, value: value)
        case GLOp.texSubImage2D:
            let target = try a.word(), level = try a.int(), xOffset = try a.int(), yOffset = try a.int()
            let width = try a.int(), height = try a.int(), format = try a.word(), type = try a.word(), data = try a.data()
            try a.end()
            texSubImage(context, target: target, level: level, xOffset: xOffset, yOffset: yOffset, width: width, height: height,
                        format: format, type: type, data: data)
        case GLOp.uniform1f..<GLOp.uniform1fv:
            // Uniform1f…4f and Uniform1i…4i: the location and that many values.
            let integers = op >= GLOp.uniform1i, components = Int(op - (integers ? GLOp.uniform1i : GLOp.uniform1f)) + 1
            let location = try a.int(), values = try a.words(components)
            try a.end()
            uniform(context, location: location, components: components, matrix: false, integers: integers, count: 1, values: values, array: false)
        case GLOp.uniform1fv..<GLOp.uniformMatrix2fv:
            let integers = op >= GLOp.uniform1iv, components = Int(op - (integers ? GLOp.uniform1iv : GLOp.uniform1fv)) + 1
            let location = try a.int(), count = try a.int(), values = try a.bytesGiven()
            try a.end()
            uniform(context, location: location, components: components, matrix: false, integers: integers, count: count, values: values, array: true)
        case GLOp.uniformMatrix2fv...GLOp.uniformMatrix4fv:
            let side = Int(op - GLOp.uniformMatrix2fv) + 2
            let location = try a.int(), count = try a.int(), values = try a.bytesGiven()
            try a.end()
            uniform(context, location: location, components: side, matrix: true, integers: false, count: count, values: values, array: true)
        case GLOp.useProgram:
            let program = try a.word()
            try a.end()
            useProgram(context, name: program)
        case GLOp.vertexAttrib4f:
            let index = try a.word(), x = try a.float(), y = try a.float(), z = try a.float(), w = try a.float()
            try a.end()
            context.vertexAttribute(index, SIMD4(x, y, z, w))
        case GLOp.vertexAttribPointer:
            let index = try a.word(), size = try a.int(), type = try a.word(), normalized = try a.flag(), stride = try a.int(), offset = try a.word()
            try a.end()
            context.vertexPointer(index, size: size, type: type, normalized: normalized, stride: stride, offset: offset)
        case GLOp.viewport:
            let x = try a.int(), y = try a.int(), width = try a.int(), height = try a.int()
            try a.end()
            context.set(viewport: x, y, width, height)
        default:
            throw GLMalformed()
        }
    }
}
