//
//  GLDraw.swift — the drawing of a Linux program's OpenGL ES 2.0 calls
//  with Metal (GLStream.swift): what is drawn to, the passes the draws are
//  gathered into, the clears, and a draw itself, from OpenGL's vertex
//  arrays and state to a Metal pipeline, its buffers and its textures.
//
//  Metal's own checks are a debug build's crash, and without them Metal
//  reads what it is told to, so nothing is handed to it that was not
//  checked here first: a draw whose vertices or indices would reach past
//  a buffer is OpenGL's GL_INVALID_OPERATION and is not drawn, a scissor
//  box is cut to what is drawn to, a pipeline is made for exactly the
//  attachments the pass has.
//
//  Which way up: Metal's y points up as OpenGL's does, but its rows are
//  counted from the top. A window's surface is drawn as it is, so its row
//  0 is the top, which is how it is shown. A texture or renderbuffer is
//  drawn turned over, so its row 0 is OpenGL's bottom row, which is how a
//  texture's memory lies. GLShaders.swift says what the shaders are told.
//

import Foundation
import Metal

/// A stretch of a buffer the next draws read from, written here: a copy
/// of a uniform block, an array that came with the draw, indices made
/// for a triangle fan.
struct GLSpan {
    let buffer: MTLBuffer
    let offset: Int
    let bytes: UnsafeMutableRawBufferPointer
}

/// Where those stretches come from: buffers filled one stretch after
/// another, kept by the command buffer being written until it is done.
struct GLArena {
    /// The largest stretch: a texture of 4096 × 4096 pixels on its way to the GPU.
    static let largest = 64 << 20
    private static let chunk = 1 << 20
    private static let spares = 8

    private let device: MTLDevice
    private var chunks: [MTLBuffer] = []
    private var spare: [MTLBuffer] = []
    private var at = 0
    /// The bytes of the buffers in use.
    private(set) var pending = 0

    init(device: MTLDevice) {
        self.device = device
    }

    /// nil when there is no memory for it. `alignment` is a power of two.
    mutating func allocate(_ count: Int, alignment: Int = 16) -> GLSpan? {
        guard count > 0, count <= Self.largest else { return nil }
        let start = (at + alignment - 1) & ~(alignment - 1)
        if let last = chunks.last, start + count <= last.length {
            at = start + count
            return GLSpan(buffer: last, offset: start, bytes: UnsafeMutableRawBufferPointer(start: last.contents() + start, count: count))
        }
        let fresh = count <= Self.chunk ? spare.popLast() ?? device.makeBuffer(length: Self.chunk, options: .storageModeShared)
                                        : device.makeBuffer(length: count, options: .storageModeShared)
        guard let fresh, fresh.length >= count else { return nil }
        chunks.append(fresh)
        pending += fresh.length
        at = count
        return GLSpan(buffer: fresh, offset: 0, bytes: UnsafeMutableRawBufferPointer(start: fresh.contents(), count: count))
    }

    /// The command buffer that read them is done. `recycle`: nothing else
    /// reads them either, so the next one's stretches may lie in the same memory.
    mutating func reset(recycle: Bool) {
        if recycle {
            for chunk in chunks where chunk.length == Self.chunk && spare.count < Self.spares { spare.append(chunk) }
        }
        chunks = []
        at = 0
        pending = 0
    }
}

/// What is drawn to: a window's surface, or what a framebuffer has attached.
struct GLTarget {
    var color: MTLTexture?
    var colorSlice = 0
    var depth: MTLTexture?
    var stencil: MTLTexture?
    var width = 0
    var height = 0
    /// A window's surface: its row 0 is the top one. Otherwise row 0 is OpenGL's bottom one.
    var surface = false
    /// Whether the colour has an alpha of its own. Where it has none it is kept 1.
    var alpha = true

    func isSame(_ other: GLTarget) -> Bool {
        color === other.color && colorSlice == other.colorSlice && depth === other.depth && stencil === other.stencil
    }

    func uses(_ texture: MTLTexture) -> Bool {
        texture === color || texture === depth || texture === stencil
    }
}

/// The culling and the depth offset a draw is rasterised with.
struct GLRaster: Equatable {
    var cull = MTLCullMode.none
    var winding = MTLWinding.counterClockwise
    var bias: Float = 0
    var slope: Float = 0
}

/// A render pass on one target: the draws that follow one another to it.
struct GLPass {
    let target: GLTarget
    /// nil while it is only decided on: a clear of everything waits here
    /// to be the pass's load action, which costs nothing, and the pass
    /// begins with the first draw.
    var encoder: MTLRenderCommandEncoder?
    var clearColor: MTLClearColor?
    var clearDepth: Double?
    var clearStencil: UInt32?
    // What the encoder was last told, so that it is told only what changes.
    // They are held, not just told apart: one let go of could have another take its place in memory and be taken for it.
    var pipeline: MTLRenderPipelineState?
    var depthStencil: MTLDepthStencilState?
    var viewport: GLRect?
    var depthRange: SIMD2<Float>?
    var scissor: GLRect?
    var raster: GLRaster?
    var blendColor: SIMD4<Float>?
    var references: SIMD2<UInt32>?
    var block: GLExecutable?
    var generation: UInt64 = 0

    init(target: GLTarget) {
        self.target = target
    }

    /// Something else drew with the encoder: it is told everything anew.
    mutating func forget() {
        pipeline = nil
        depthStencil = nil
        viewport = nil
        depthRange = nil
        scissor = nil
        raster = nil
        blendColor = nil
        references = nil
        block = nil
    }
}

struct GLSamplerKey: Hashable {
    var minFilter: UInt32
    var magFilter: UInt32
    var wrapS: UInt32
    var wrapT: UInt32
}

struct GLStencilKey: Hashable {
    var compare = MTLCompareFunction.always
    var fail = MTLStencilOperation.keep
    var depthFail = MTLStencilOperation.keep
    var pass = MTLStencilOperation.keep
    var readMask: UInt32 = 0xff
    var writeMask: UInt32 = 0xff
}

struct GLDepthStencilKey: Hashable {
    var compare = MTLCompareFunction.always
    var write = false
    var front: GLStencilKey?
    var back: GLStencilKey?
}

struct GLBlendKey: Hashable {
    var sourceRGB: MTLBlendFactor
    var destinationRGB: MTLBlendFactor
    var sourceAlpha: MTLBlendFactor
    var destinationAlpha: MTLBlendFactor
    var rgb: MTLBlendOperation
    var alpha: MTLBlendOperation
}

/// Everything a Metal pipeline is made for, besides the program.
struct GLPipelineKey: Hashable {
    /// GLExecutable.serial.
    var program: UInt64 = 0
    /// For each attribute location: Metal's format, the stride, and whether it is one value for all vertices.
    var arrays = SIMD16<UInt32>()
    var color = MTLPixelFormat.invalid
    var depth = MTLPixelFormat.invalid
    var stencil = MTLPixelFormat.invalid
    var blend: GLBlendKey?
    var mask: UInt = 0
}

/// Where a vertex attribute's values come from, for one draw.
struct GLBoundArray {
    var buffer: MTLBuffer
    /// Where the first vertex drawn begins in the buffer, and where in a vertex the attribute lies.
    var offset: Int
    var within = 0
    var format: MTLVertexFormat
    var stride: Int
    var constant = false

    /// Strides and what lies within them are under 2048, Metal's formats under 512.
    var key: UInt32 {
        UInt32(truncatingIfNeeded: format.rawValue) << 23 | UInt32(truncatingIfNeeded: stride) << 12 | UInt32(truncatingIfNeeded: within) << 1
            | (constant ? 1 : 0)
    }
}

enum GLDrawSource {
    case arrays(first: Int, count: Int)
    case elements(count: Int, type: UInt32, offset: Int)
    case client(count: Int, type: UInt32, indices: UnsafeRawBufferPointer)
}

/// The two things drawn that are no program's: a rectangle of one colour
/// (a clear that is not of everything) and a rectangle of what was drawn
/// (glCopyTexImage2D).
final class GLQuads {
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct MonadQuad { float4 color; float4x4 mix; float4 add; float depth; int dx; int dy; int flip; };
    struct MonadQuadOut { float4 position [[position]]; };
    vertex MonadQuadOut monad_quad_vertex(uint id [[vertex_id]], constant MonadQuad &quad [[buffer(0)]]) {
        MonadQuadOut out;
        out.position = float4((id & 1) != 0 ? 1.0 : -1.0, (id & 2) != 0 ? 1.0 : -1.0, quad.depth, 1.0);
        return out;
    }
    fragment float4 monad_quad_clear(constant MonadQuad &quad [[buffer(0)]]) {
        return quad.color;
    }
    fragment float4 monad_quad_copy(MonadQuadOut in [[stage_in]], constant MonadQuad &quad [[buffer(0)]], texture2d<float> source [[texture(0)]]) {
        int2 at = int2(in.position.xy);
        int y = quad.flip != 0 ? quad.dy - at.y : at.y + quad.dy;
        return quad.mix * source.read(uint2(uint(at.x + quad.dx), uint(y))) + quad.add;
    }
    """
    /// The bytes of MonadQuad.
    static let bytes = 112

    private struct Key: Hashable {
        var copy: Bool
        var color: MTLPixelFormat
        var depth: MTLPixelFormat
        var stencil: MTLPixelFormat
        var mask: UInt
    }

    private let device: MTLDevice
    private let vertex: MTLFunction
    private let clear: MTLFunction
    private let copy: MTLFunction
    private var pipelines: [Key: MTLRenderPipelineState] = [:]

    init?(device: MTLDevice) {
        guard let library = try? device.makeLibrary(source: Self.source, options: nil),
              let vertex = library.makeFunction(name: "monad_quad_vertex"),
              let clear = library.makeFunction(name: "monad_quad_clear"),
              let copy = library.makeFunction(name: "monad_quad_copy") else { return nil }
        self.device = device
        self.vertex = vertex
        self.clear = clear
        self.copy = copy
    }

    func pipeline(copy: Bool, target: GLTarget, mask: MTLColorWriteMask) -> MTLRenderPipelineState? {
        let key = Key(copy: copy, color: target.color?.pixelFormat ?? .invalid, depth: target.depth?.pixelFormat ?? .invalid,
                      stencil: target.stencil?.pixelFormat ?? .invalid, mask: mask.rawValue)
        if let known = pipelines[key] { return known }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = copy ? self.copy : clear
        descriptor.colorAttachments[0].pixelFormat = key.color
        descriptor.colorAttachments[0].writeMask = mask
        descriptor.depthAttachmentPixelFormat = key.depth
        descriptor.stencilAttachmentPixelFormat = key.stencil
        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        pipelines[key] = state
        return state
    }

    /// MonadQuad's bytes. `mix` is four columns.
    static func write(_ span: GLSpan, color: SIMD4<Float> = .zero, mix: [SIMD4<Float>] = [], add: SIMD4<Float> = .zero,
                      depth: Float = 0, dx: Int = 0, dy: Int = 0, flip: Bool = false) {
        guard span.bytes.count >= bytes else { return }
        func put(_ vector: SIMD4<Float>, _ offset: Int) {
            for i in 0..<4 { span.bytes.storeBytes(of: vector[i], toByteOffset: offset + i * 4, as: Float.self) }
        }
        put(color, 0)
        for column in 0..<4 { put(column < mix.count ? mix[column] : .zero, 16 + column * 16) }
        put(add, 80)
        span.bytes.storeBytes(of: depth, toByteOffset: 96, as: Float.self)
        span.bytes.storeBytes(of: Int32(truncatingIfNeeded: dx), toByteOffset: 100, as: Int32.self)
        span.bytes.storeBytes(of: Int32(truncatingIfNeeded: dy), toByteOffset: 104, as: Int32.self)
        span.bytes.storeBytes(of: Int32(flip ? 1 : 0), toByteOffset: 108, as: Int32.self)
    }
}

extension GLStream {
    // MARK: Command buffers and passes

    func commandBuffer() -> MTLCommandBuffer? {
        if commands == nil { commands = queue?.makeCommandBuffer() }
        return commands
    }

    /// Everything drawn so far is done by the GPU when this returns.
    /// Waiting keeps a program from having the Mac hold more than a
    /// bound's worth of its drawing, and lets what was drawn be read.
    func flush() {
        endEncoders()
        if let commands {
            commands.commit()
            commands.waitUntilCompleted()
            // The GPU gave up on it (out of memory, too long): what the stream draws from here on is not to be relied
            // on, and whatever made it give up would do so again. The stream is over.
            if commands.status == .error { ended = true }
        }
        commands = nil
        budget.serial += 1
        budget.retired = 0
        passes = 0
        encoded = 0
        // Arrays that came for a draw still to come lie in the arena too, and are still to be read.
        arena.reset(recycle: (current?.clientBytes ?? 0) == 0)
    }

    func endEncoders() {
        endPass()
        blit?.endEncoding()
        blit = nil
    }

    /// The pass is over. One that was only decided on is begun and ended, for the clears waiting in it.
    func endPass() {
        guard var ending = pass else { return }
        pass = nil
        if ending.encoder == nil, ending.clearColor != nil || ending.clearDepth != nil || ending.clearStencil != nil {
            begin(&ending)
        }
        ending.encoder?.endEncoding()
    }

    /// An encoder for copies. What was being drawn is drawn first.
    func blitEncoder() -> MTLBlitCommandEncoder? {
        endPass()
        if blit == nil {
            blit = commandBuffer()?.makeBlitCommandEncoder()
            passes += 1
        }
        encoded += 1
        return blit
    }

    private func begin(_ pass: inout GLPass) {
        blit?.endEncoding()
        blit = nil
        guard let commands = commandBuffer() else { return }
        let descriptor = MTLRenderPassDescriptor(), target = pass.target
        if let color = target.color, let attachment = descriptor.colorAttachments[0] {
            attachment.texture = color
            attachment.slice = target.colorSlice
            attachment.storeAction = .store
            attachment.loadAction = pass.clearColor == nil ? .load : .clear
            if let clear = pass.clearColor { attachment.clearColor = clear }
        }
        if let depth = target.depth, let attachment = descriptor.depthAttachment {
            attachment.texture = depth
            attachment.storeAction = .store
            attachment.loadAction = pass.clearDepth == nil ? .load : .clear
            if let clear = pass.clearDepth { attachment.clearDepth = clear }
        }
        if let stencil = target.stencil, let attachment = descriptor.stencilAttachment {
            attachment.texture = stencil
            attachment.storeAction = .store
            attachment.loadAction = pass.clearStencil == nil ? .load : .clear
            if let clear = pass.clearStencil { attachment.clearStencil = clear }
        }
        pass.encoder = commands.makeRenderCommandEncoder(descriptor: descriptor)
        passes += 1
        pass.clearColor = nil
        pass.clearDepth = nil
        pass.clearStencil = nil
        pass.forget()
    }

    /// The encoder of the pass on `target`, begun: the one there is, while what is drawn to stays the same.
    private func encoder(_ target: GLTarget) -> MTLRenderCommandEncoder? {
        if let pass, !pass.target.isSame(target) { endPass() }
        var drawing = pass ?? GLPass(target: target)
        if drawing.encoder == nil { begin(&drawing) }
        pass = drawing.encoder == nil ? nil : drawing
        return drawing.encoder
    }

    /// Memory that was just made shows nothing: a program that reads it
    /// before drawing to it reads zeros, not what the memory held before.
    /// `alpha` false: a colour with no alpha of its own, which is kept 1.
    func clear(_ texture: MTLTexture, slice: Int, level: Int, alpha: Bool) {
        endEncoders()
        guard let commands = commandBuffer() else { return }
        passes += 1
        let descriptor = MTLRenderPassDescriptor()
        let format = texture.pixelFormat
        if format == .depth32Float || format == .depth32Float_stencil8, let attachment = descriptor.depthAttachment {
            attachment.texture = texture
            attachment.slice = slice
            attachment.level = level
            attachment.loadAction = .clear
            attachment.storeAction = .store
            attachment.clearDepth = 0
        }
        if format == .stencil8 || format == .depth32Float_stencil8, let attachment = descriptor.stencilAttachment {
            attachment.texture = texture
            attachment.slice = slice
            attachment.level = level
            attachment.loadAction = .clear
            attachment.storeAction = .store
            attachment.clearStencil = 0
        }
        if format == .rgba8Unorm || format == .bgra8Unorm, let attachment = descriptor.colorAttachments[0] {
            attachment.texture = texture
            attachment.slice = slice
            attachment.level = level
            attachment.loadAction = .clear
            attachment.storeAction = .store
            attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: alpha ? 0 : 1)
        }
        commands.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
    }

    // MARK: What is drawn to

    /// What an attachment gives a framebuffer, or nil when it has no
    /// memory. `kind`: 0 a colour that can be drawn to, 1 depth, 2
    /// stencil, 3 depth and stencil in one, 4 something that cannot be
    /// drawn to.
    private func resolve(_ attachment: GLAttachment) -> (memory: MTLTexture, slice: Int, width: Int, height: Int, kind: Int, alpha: Bool)? {
        switch attachment {
        case .none:
            return nil
        case .texture(let texture, let face):
            guard let image = texture[face, 0], let place = place(texture, face: face, level: 0), place.level == 0 else { return nil }
            let kind: Int
            switch image.format {
            case GL.RGBA, GL.RGB: kind = 0
            case GL.DEPTH_COMPONENT: kind = 1
            case GL.DEPTH_STENCIL_OES: kind = 3
            default: kind = 4
            }
            return (place.texture, place.slice, image.width, image.height, kind, image.format == GL.RGBA)
        case .renderbuffer(let renderbuffer):
            guard let memory = renderbuffer.memory else { return nil }
            let kind: Int
            switch renderbuffer.format {
            case GL.DEPTH_COMPONENT16, GL.DEPTH_COMPONENT24_OES: kind = 1
            case GL.STENCIL_INDEX8: kind = 2
            case GL.DEPTH24_STENCIL8_OES: kind = 3
            default: kind = 0
            }
            let alpha = renderbuffer.format != GL.RGB565 && renderbuffer.format != GL.RGB8_OES
            return (memory, 0, renderbuffer.width, renderbuffer.height, kind, alpha)
        }
    }

    /// What glCheckFramebufferStatus says of what the context draws to,
    /// and, when that is GL_FRAMEBUFFER_COMPLETE, what it is.
    func framebufferStatus(_ context: GLContext) -> (status: UInt32, target: GLTarget?) {
        guard let framebuffer = context.framebuffer else {
            return surfaceTarget(context.draw)
        }
        var target = GLTarget()
        var attached = 0, agree = true
        func take(_ attachment: GLAttachment, kinds: [Int]) -> (MTLTexture, Int, Bool)?? {
            if case .none = attachment { return .some(nil) }
            guard let found = resolve(attachment), kinds.contains(found.kind) else { return nil }
            if attached > 0, found.width != target.width || found.height != target.height { agree = false }
            attached += 1
            target.width = found.width
            target.height = found.height
            return (found.memory, found.slice, found.alpha)
        }
        guard let color = take(framebuffer.color, kinds: [0]), let depth = take(framebuffer.depth, kinds: [1, 3]),
              let stencil = take(framebuffer.stencil, kinds: [2, 3]) else {
            return (GL.FRAMEBUFFER_INCOMPLETE_ATTACHMENT, nil)
        }
        guard attached > 0 else { return (GL.FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT, nil) }
        guard agree else { return (GL.FRAMEBUFFER_INCOMPLETE_DIMENSIONS, nil) }
        if let color {
            target.color = color.0
            target.colorSlice = color.1
            target.alpha = color.2
        }
        target.depth = depth?.0
        target.stencil = stencil?.0
        // Metal keeps depth and stencil that were made as one in one texture: it cannot take the half of one with another's.
        if let depth = target.depth, let stencil = target.stencil, depth !== stencil,
           depth.pixelFormat == .depth32Float_stencil8 || stencil.pixelFormat == .depth32Float_stencil8 {
            return (GL.FRAMEBUFFER_UNSUPPORTED, nil)
        }
        return (GL.FRAMEBUFFER_COMPLETE, target)
    }

    private func surfaceTarget(_ surface: GLSurface?) -> (status: UInt32, target: GLTarget?) {
        // A context made current with no surface has nothing to draw to.
        guard let surface, let picture = surface.picture else { return (GL.FRAMEBUFFER_UNSUPPORTED, nil) }
        // A surface has the depth and the stencil it was made with, in one texture when it has both; without alpha, its
        // colour's alpha is kept 1.
        return (GL.FRAMEBUFFER_COMPLETE, GLTarget(color: picture.texture, depth: surface.depth ? surface.depthStencil : nil,
                                                  stencil: surface.stencil ? surface.depthStencil : nil,
                                                  width: surface.width, height: surface.height, surface: true, alpha: surface.alpha))
    }

    /// What glReadPixels and glCopyTexImage2D read: the framebuffer that is bound, or the surface MakeCurrent said to read.
    func readTarget(_ context: GLContext) -> (status: UInt32, target: GLTarget?) {
        context.framebuffer == nil ? surfaceTarget(context.read) : framebufferStatus(context)
    }

    /// OpenGL's rectangle (its y counted from the bottom) in the rows of
    /// what is drawn to, cut to it. Empty: width or height 0.
    private func rows(_ box: GLRect, of target: GLTarget) -> GLRect {
        let left = max(box.x, 0), right = min(box.x + box.width, target.width)
        let bottom = max(box.y, 0), top = min(box.y + box.height, target.height)
        guard right > left, top > bottom else { return GLRect() }
        return GLRect(x: left, y: target.surface ? target.height - top : bottom, width: right - left, height: top - bottom)
    }

    /// The part of what is drawn to that the scissor test leaves, in its rows.
    private func scissorBox(_ context: GLContext, _ target: GLTarget) -> GLRect {
        context.scissorTest ? rows(context.scissor, of: target) : GLRect(x: 0, y: 0, width: target.width, height: target.height)
    }

    /// The channels a draw writes: OpenGL's colour mask, and never the alpha of a colour that has none of its own.
    private func writeMask(_ context: GLContext, _ target: GLTarget) -> MTLColorWriteMask {
        var mask: MTLColorWriteMask = []
        if context.colorMask[0] != 0 { mask.insert(.red) }
        if context.colorMask[1] != 0 { mask.insert(.green) }
        if context.colorMask[2] != 0 { mask.insert(.blue) }
        if context.colorMask[3] != 0, target.alpha { mask.insert(.alpha) }
        return mask
    }

    func depthStencilState(_ key: GLDepthStencilKey) -> MTLDepthStencilState? {
        if let known = depthStencils[key] { return known }
        if depthStencils.count >= GLLimits.states { depthStencils.removeAll() }
        func face(_ key: GLStencilKey?) -> MTLStencilDescriptor? {
            guard let key else { return nil }
            let descriptor = MTLStencilDescriptor()
            descriptor.stencilCompareFunction = key.compare
            descriptor.stencilFailureOperation = key.fail
            descriptor.depthFailureOperation = key.depthFail
            descriptor.depthStencilPassOperation = key.pass
            descriptor.readMask = key.readMask
            descriptor.writeMask = key.writeMask
            return descriptor
        }
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = key.compare
        descriptor.isDepthWriteEnabled = key.write
        descriptor.frontFaceStencil = face(key.front)
        descriptor.backFaceStencil = face(key.back)
        guard let state = device.makeDepthStencilState(descriptor: descriptor) else { return nil }
        depthStencils[key] = state
        return state
    }

    private func quadShaders() -> GLQuads? {
        if quads == nil { quads = GLQuads(device: device) }
        return quads
    }

    // MARK: Clear

    func clear(_ context: GLContext, mask: UInt32) {
        guard mask & ~(GL.COLOR_BUFFER_BIT | GL.DEPTH_BUFFER_BIT | GL.STENCIL_BUFFER_BIT) == 0 else { return context.fail(GL.INVALID_VALUE) }
        guard let target = framebufferStatus(context).target else { return context.fail(GL.INVALID_FRAMEBUFFER_OPERATION) }
        // What there is to clear: what was asked for, is there, and is not masked out altogether.
        let writes = writeMask(context, target)
        let all: MTLColorWriteMask = target.alpha ? .all : [.red, .green, .blue]
        let color = mask & GL.COLOR_BUFFER_BIT != 0 && target.color != nil && !writes.isEmpty
        let depth = mask & GL.DEPTH_BUFFER_BIT != 0 && target.depth != nil && context.depthMask
        let stencilMask = context.front.writeMask & 0xff
        let stencil = mask & GL.STENCIL_BUFFER_BIT != 0 && target.stencil != nil && stencilMask != 0
        let box = scissorBox(context, target)
        guard color || depth || stencil, box.width > 0, box.height > 0 else { return }
        let value = SIMD4<Float>(context.clearColor[0], context.clearColor[1], context.clearColor[2], target.alpha ? context.clearColor[3] : 1)
        let stencilValue = UInt32(truncatingIfNeeded: context.clearStencil) & 0xff

        if box == GLRect(x: 0, y: 0, width: target.width, height: target.height), !color || writes == all, !stencil || stencilMask == 0xff {
            // All of it: the pass that comes begins with it cleared, which costs no drawing.
            if let pass, pass.target.isSame(target), pass.encoder == nil {} else {
                endPass()
                pass = GLPass(target: target)
            }
            if color { pass?.clearColor = MTLClearColor(red: Double(value[0]), green: Double(value[1]), blue: Double(value[2]), alpha: Double(value[3])) }
            if depth { pass?.clearDepth = Double(context.clearDepth) }
            if stencil { pass?.clearStencil = stencilValue }
            return
        }

        // A part of it, or some channels of it: a rectangle drawn over it, as the masks and the scissor box let it.
        var key = GLDepthStencilKey()
        key.write = depth
        if stencil {
            let face = GLStencilKey(compare: .always, fail: .replace, depthFail: .replace, pass: .replace, readMask: 0xff, writeMask: stencilMask)
            key.front = face
            key.back = face
        }
        guard let shaders = quadShaders(), let pipeline = shaders.pipeline(copy: false, target: target, mask: color ? writes : []),
              let state = depthStencilState(key), let span = arena.allocate(GLQuads.bytes, alignment: 256),
              let encoder = encoder(target) else { return }
        GLQuads.write(span, color: value, depth: context.clearDepth)
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(state)
        encoder.setStencilReferenceValue(stencilValue)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(target.width), height: Double(target.height), znear: 0, zfar: 1))
        encoder.setScissorRect(MTLScissorRect(x: box.x, y: box.y, width: box.width, height: box.height))
        encoder.setCullMode(.none)
        encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
        encoder.setVertexBuffer(span.buffer, offset: span.offset, index: 0)
        encoder.setFragmentBuffer(span.buffer, offset: span.offset, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        pass?.forget()
        encoded += 1
    }

    // MARK: Reading what was drawn

    func readPixels(_ context: GLContext, x: Int, y: Int, width: Int, height: Int, format: UInt32, type: UInt32) {
        var reply = GLReply()
        defer { send(&reply) }
        // An answer is owed whatever is asked. When what is asked cannot be, it is one of no length: the header's way of
        // saying that OpenGL has an error instead, and that nothing is to be written to the program's memory.
        guard let (target, color) = readable(context, width: width, height: height, format: format, type: type) else { return }
        // What lies outside what was drawn to is undefined in OpenGL; here it is zeros.
        let left = max(x, 0), right = min(x + width, target.width), bottom = max(y, 0), top = min(y + height, target.height)
        let columns = max(0, right - left), lines = max(0, top - bottom)
        var span: GLSpan?
        if columns > 0, lines > 0 {
            guard let room = arena.allocate(columns * lines * 4), let blit = blitEncoder() else { return context.fail(GL.OUT_OF_MEMORY) }
            blit.copy(from: color, sourceSlice: target.colorSlice, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: left, y: target.surface ? target.height - top : bottom, z: 0),
                      sourceSize: MTLSize(width: columns, height: lines, depth: 1),
                      to: room.buffer, destinationOffset: room.offset, destinationBytesPerRow: columns * 4, destinationBytesPerImage: columns * lines * 4)
            span = room
            // The GPU has drawn all of it, and copied it, when this returns.
            flush()
        }
        reply.data(count: width * height * 4) { out in
            guard let span else { return }
            let source = UnsafeRawBufferPointer(span.bytes), bgra = color.pixelFormat == .bgra8Unorm
            for line in 0..<lines {
                // The answer's rows go from the bottom up; a surface's memory goes from the top down.
                let from = (target.surface ? lines - 1 - line : line) * columns * 4
                let to = ((bottom - y + line) * width + (left - x)) * 4
                GLFormats.read(row: UnsafeRawBufferPointer(rebasing: source[from..<from + columns * 4]), bgra: bgra,
                               into: UnsafeMutableRawBufferPointer(rebasing: out[to..<to + columns * 4]), pixels: columns)
            }
        }
    }

    /// What glReadPixels reads, when it is asked for something it can give; nil, with OpenGL's error set, when not.
    private func readable(_ context: GLContext, width: Int, height: Int, format: UInt32, type: UInt32) -> (GLTarget, MTLTexture)? {
        guard [GL.ALPHA, GL.RGB, GL.RGBA].contains(format),
              [GL.UNSIGNED_BYTE, GL.UNSIGNED_SHORT_5_6_5, GL.UNSIGNED_SHORT_4_4_4_4, GL.UNSIGNED_SHORT_5_5_5_1].contains(type) else {
            context.fail(GL.INVALID_ENUM)
            return nil
        }
        guard width >= 0, height >= 0, width <= GLLimits.side, height <= GLLimits.side else {
            context.fail(GL.INVALID_VALUE)
            return nil
        }
        // The one pair every OpenGL ES 2.0 reads, and the one the program's side asks for.
        guard format == GL.RGBA, type == GL.UNSIGNED_BYTE else {
            context.fail(GL.INVALID_OPERATION)
            return nil
        }
        guard let target = readTarget(context).target else {
            context.fail(GL.INVALID_FRAMEBUFFER_OPERATION)
            return nil
        }
        guard let color = target.color else {
            context.fail(GL.INVALID_OPERATION)
            return nil
        }
        return (target, color)
    }

    /// Draws a rectangle of what the context reads (glCopyTexImage2D,
    /// glCopyTexSubImage2D) into an image of a texture: `width` × `height`
    /// pixels from (x, y) there to (xOffset, yOffset) here, both counted
    /// as OpenGL counts. What lies outside the source is left as it is.
    func copy(from source: GLTarget, x: Int, y: Int, to place: GLPlace, xOffset: Int, yOffset: Int, width: Int, height: Int, format: UInt32) {
        guard let color = source.color, color !== place.texture else { return }
        let left = max(0, -x), right = min(width, source.width - x), bottom = max(0, -y), top = min(height, source.height - y)
        guard right > left, top > bottom else { return }
        var destination = GLTarget(color: place.texture, colorSlice: place.slice, width: max(1, place.texture.width >> place.level),
                                   height: max(1, place.texture.height >> place.level))
        destination.alpha = true
        endEncoders()
        guard let shaders = quadShaders(), let pipeline = shaders.pipeline(copy: true, target: destination, mask: .all),
              let state = depthStencilState(GLDepthStencilKey()), let span = arena.allocate(GLQuads.bytes, alignment: 256),
              let commands = commandBuffer() else { return }
        // What a texture of each format keeps of a colour: a sampler reads luminance in all three, and 1 where there is no alpha.
        let red = SIMD4<Float>(1, 0, 0, 0), green = SIMD4<Float>(0, 1, 0, 0), blue = SIMD4<Float>(0, 0, 1, 0)
        let alpha = SIMD4<Float>(0, 0, 0, 1), gray = SIMD4<Float>(1, 1, 1, 0), none = SIMD4<Float>.zero
        let mix: [SIMD4<Float>], add: SIMD4<Float>
        switch format {
        case GL.RGB: (mix, add) = ([red, green, blue, none], alpha)
        case GL.LUMINANCE: (mix, add) = ([gray, none, none, none], alpha)
        case GL.LUMINANCE_ALPHA: (mix, add) = ([gray, none, none, alpha], none)
        case GL.ALPHA: (mix, add) = ([none, none, none, alpha], none)
        default: (mix, add) = ([red, green, blue, alpha], none)
        }
        // A texture's rows are OpenGL's from the bottom, a surface's from the top.
        let dx = x - xOffset, dy = y - yOffset
        GLQuads.write(span, mix: mix, add: add, dx: dx, dy: source.surface ? source.height - 1 - dy : dy, flip: source.surface)
        let descriptor = MTLRenderPassDescriptor()
        guard let attachment = descriptor.colorAttachments[0] else { return }
        attachment.texture = place.texture
        attachment.slice = place.slice
        attachment.level = place.level
        attachment.loadAction = .load
        attachment.storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(state)
        encoder.setViewport(MTLViewport(originX: Double(xOffset + left), originY: Double(yOffset + bottom), width: Double(right - left),
                                        height: Double(top - bottom), znear: 0, zfar: 1))
        encoder.setScissorRect(MTLScissorRect(x: xOffset + left, y: yOffset + bottom, width: right - left, height: top - bottom))
        encoder.setVertexBuffer(span.buffer, offset: span.offset, index: 0)
        encoder.setFragmentBuffer(span.buffer, offset: span.offset, index: 0)
        encoder.setFragmentTexture(color, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        passes += 1
    }

    // MARK: Vertex arrays

    /// An array in the program's own memory: its elements for the draw that follows.
    func clientArray(_ context: GLContext, index: UInt32, size: Int, type: UInt32, normalized: Bool, first: Int, data: UnsafeRawBufferPointer) {
        guard let component = GLFormats.componentBytes(type) else { return context.fail(GL.INVALID_ENUM) }
        guard index < UInt32(GLLimits.attributes), (1...4).contains(size), first >= 0,
              let format = GLFormats.vertex(type: type, size: size, normalized: normalized) else { return context.fail(GL.INVALID_VALUE) }
        let each = component * size, count = data.count / each
        guard data.count % each == 0 else { return context.fail(GL.INVALID_OPERATION) }
        let slot = Int(index)
        if let old = context.client[slot] {
            context.clientBytes -= old.bytes
            context.client[slot] = nil
        }
        guard count > 0 else { return }
        guard context.clientBytes + data.count <= GLLimits.clientBytes, let span = arena.allocate(data.count) else {
            return context.fail(GL.OUT_OF_MEMORY)
        }
        if type == GL.FIXED {
            Self.floats(fromFixed: data, into: span.bytes)
        } else {
            span.bytes.copyMemory(from: data)
        }
        context.client[slot] = GLClientArray(buffer: span.buffer, offset: span.offset, stride: each, format: format,
                                             first: first, count: count, bytes: data.count)
        context.clientBytes += data.count
    }

    /// GL_FIXED's numbers (sixteen bits before the point, sixteen after) as the floats Metal reads. Both are four bytes a number.
    private static func floats(fromFixed source: UnsafeRawBufferPointer, into: UnsafeMutableRawBufferPointer) {
        for index in 0..<min(source.count, into.count) / 4 {
            let fixed = Int32(littleEndian: source.loadUnaligned(fromByteOffset: index * 4, as: Int32.self))
            into.storeBytes(of: Float(fixed) / 65536, toByteOffset: index * 4, as: Float.self)
        }
    }

    /// Where each attribute the program reads gets its values for the
    /// vertices `low` to `high`, as Metal is to be told; nil when a vertex
    /// would lie outside what there is, with OpenGL's error set. Vertex
    /// `low` is the first in each: the draw counts from there.
    private func arrays(_ context: GLContext, _ executable: GLExecutable, low: Int, high: Int) -> [GLBoundArray?]? {
        var bound = [GLBoundArray?](repeating: nil, count: GLLimits.attributes)
        var constants: GLSpan?
        for index in 0..<GLLimits.attributes where executable.attributes & 1 << UInt32(index) != 0 {
            let array = context.arrays[index]
            if let client = context.client[index] {
                // The program's own memory, sent for this draw: it has to cover the vertices drawn.
                guard client.first <= low, high - client.first < client.count else {
                    context.fail(GL.INVALID_OPERATION)
                    return nil
                }
                bound[index] = GLBoundArray(buffer: client.buffer, offset: client.offset + (low - client.first) * client.stride,
                                            format: client.format, stride: client.stride)
            } else if array.enabled {
                guard let buffer = array.buffer, let memory = buffer.memory, let bytes = buffer.bytes,
                      let component = GLFormats.componentBytes(array.type),
                      let format = GLFormats.vertex(type: array.type, size: array.size, normalized: array.normalized) else {
                    context.fail(GL.INVALID_OPERATION)
                    return nil
                }
                let each = component * array.size, stride = array.stride == 0 ? each : array.stride
                // The last vertex's last byte lies in the buffer, or nothing is drawn. Worked out by dividing: an index
                // times a stride can be a number no Int holds.
                let room = bytes.count - array.offset - each
                guard room >= 0, high <= room / stride else {
                    context.fail(GL.INVALID_OPERATION)
                    return nil
                }
                // Metal reads it where it lies when it can. It wants a whole stride of the buffer from where a vertex
                // begins, also for the last vertex of a buffer, whose stride OpenGL lets end with the attribute: so
                // a vertex begins at a multiple of the stride where that leaves the attribute inside it, as vertices of
                // several attributes lie.
                let within = array.offset % stride + each <= stride ? array.offset % stride : 0
                let start = array.offset - within + low * stride
                if array.type != GL.FIXED, stride >= each, stride <= 2040, stride % component == 0, array.offset % component == 0,
                   start + stride <= memory.length {
                    buffer.draw(from: array.offset + low * stride..<array.offset + high * stride + each)
                    bound[index] = GLBoundArray(buffer: memory, offset: start, within: within, format: format, stride: stride)
                } else {
                    // It cannot (GL_FIXED, numbers that straddle their alignment, vertices that overlap, a last vertex
                    // cut short): a copy it can read, of the vertices drawn.
                    let count = high - low + 1, packed = (each + 3) & ~3
                    guard count * packed <= GLArena.largest, let span = arena.allocate(count * packed) else {
                        context.fail(GL.OUT_OF_MEMORY)
                        return nil
                    }
                    let source = UnsafeRawBufferPointer(bytes)
                    for vertex in 0..<count {
                        let from = array.offset + (low + vertex) * stride
                        let element = UnsafeRawBufferPointer(rebasing: source[from..<from + each])
                        let into = UnsafeMutableRawBufferPointer(rebasing: span.bytes[vertex * packed..<vertex * packed + each])
                        if array.type == GL.FIXED {
                            Self.floats(fromFixed: element, into: into)
                        } else {
                            into.copyMemory(from: element)
                        }
                    }
                    bound[index] = GLBoundArray(buffer: span.buffer, offset: span.offset, format: format, stride: packed)
                }
            } else {
                // No array: glVertexAttrib's value, the same for every vertex.
                if constants == nil { constants = arena.allocate(GLLimits.attributes * 16) }
                guard let constants else {
                    context.fail(GL.OUT_OF_MEMORY)
                    return nil
                }
                for i in 0..<4 { constants.bytes.storeBytes(of: array.value[i], toByteOffset: index * 16 + i * 4, as: Float.self) }
                bound[index] = GLBoundArray(buffer: constants.buffer, offset: constants.offset + index * 16, format: .float4, stride: 16, constant: true)
            }
        }
        return bound
    }

    // MARK: Indices

    private static func indexBytes(_ type: UInt32) -> Int? {
        switch type {
        case GL.UNSIGNED_BYTE: return 1
        case GL.UNSIGNED_SHORT: return 2
        // OES_element_index_uint.
        case GL.UNSIGNED_INT: return 4
        default: return nil
        }
    }

    private static func index(_ bytes: UnsafeRawBufferPointer, _ each: Int, _ at: Int) -> Int {
        switch each {
        case 1: return Int(bytes[at])
        case 2: return Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: at * 2, as: UInt16.self)))
        default: return Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: at * 4, as: UInt32.self)))
        }
    }

    /// The lowest and the highest of `count` indices (at least one).
    private static func range(_ bytes: UnsafeRawBufferPointer, each: Int, count: Int) -> (low: Int, high: Int) {
        var low = Int.max, high = 0
        for at in 0..<count {
            let value = index(bytes, each, at)
            low = min(low, value)
            high = max(high, value)
        }
        return (low, high)
    }

    // MARK: Draw

    private func pipeline(_ executable: GLExecutable, _ key: GLPipelineKey, _ bound: [GLBoundArray?]) -> MTLRenderPipelineState? {
        if let known = pipelines[key] { return known }
        if pipelines.count >= GLLimits.pipelines { pipelines.removeAll() }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = executable.vertex
        descriptor.fragmentFunction = executable.fragment
        let vertices = MTLVertexDescriptor()
        for (index, array) in bound.enumerated() {
            guard let array, let attribute = vertices.attributes[index], let layout = vertices.layouts[index] else { continue }
            attribute.format = array.format
            attribute.offset = array.within
            attribute.bufferIndex = index
            layout.stride = array.stride
            if array.constant {
                layout.stepFunction = .constant
                layout.stepRate = 0
            }
        }
        descriptor.vertexDescriptor = vertices
        if key.color != .invalid, let color = descriptor.colorAttachments[0] {
            color.pixelFormat = key.color
            color.writeMask = MTLColorWriteMask(rawValue: key.mask)
            if let blend = key.blend {
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = blend.sourceRGB
                color.destinationRGBBlendFactor = blend.destinationRGB
                color.sourceAlphaBlendFactor = blend.sourceAlpha
                color.destinationAlphaBlendFactor = blend.destinationAlpha
                color.rgbBlendOperation = blend.rgb
                color.alphaBlendOperation = blend.alpha
            }
        }
        descriptor.depthAttachmentPixelFormat = key.depth
        descriptor.stencilAttachmentPixelFormat = key.stencil
        // A pipeline Metal will not make is remembered as none, not tried again at every draw.
        let state = try? device.makeRenderPipelineState(descriptor: descriptor)
        pipelines.updateValue(state, forKey: key)
        return state
    }

    func samplerState(_ key: GLSamplerKey) -> MTLSamplerState? {
        if let known = samplers[key] { return known }
        if samplers.count >= GLLimits.states { samplers.removeAll() }
        func address(_ wrap: UInt32) -> MTLSamplerAddressMode {
            wrap == GL.REPEAT ? .repeat : wrap == GL.MIRRORED_REPEAT ? .mirrorRepeat : .clampToEdge
        }
        let descriptor = MTLSamplerDescriptor()
        descriptor.magFilter = key.magFilter == GL.LINEAR ? .linear : .nearest
        switch key.minFilter {
        case GL.NEAREST: (descriptor.minFilter, descriptor.mipFilter) = (.nearest, .notMipmapped)
        case GL.LINEAR: (descriptor.minFilter, descriptor.mipFilter) = (.linear, .notMipmapped)
        case GL.NEAREST_MIPMAP_NEAREST: (descriptor.minFilter, descriptor.mipFilter) = (.nearest, .nearest)
        case GL.LINEAR_MIPMAP_NEAREST: (descriptor.minFilter, descriptor.mipFilter) = (.linear, .nearest)
        case GL.NEAREST_MIPMAP_LINEAR: (descriptor.minFilter, descriptor.mipFilter) = (.nearest, .linear)
        default: (descriptor.minFilter, descriptor.mipFilter) = (.linear, .linear)
        }
        descriptor.sAddressMode = address(key.wrapS)
        descriptor.tAddressMode = address(key.wrapT)
        guard let state = device.makeSamplerState(descriptor: descriptor) else { return nil }
        samplers[key] = state
        return state
    }

    /// What a sampler reads when its texture is not complete, as OpenGL says: black, with alpha 1.
    private func blackTextures() -> (flat: MTLTexture, cube: MTLTexture)? {
        if let black { return black }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let flat = device.makeTexture(descriptor: descriptor) else { return nil }
        descriptor.textureType = .typeCube
        guard let cube = device.makeTexture(descriptor: descriptor) else { return nil }
        let pixel: [UInt8] = [0, 0, 0, 255], region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: 1, height: 1, depth: 1))
        flat.replace(region: region, mipmapLevel: 0, slice: 0, withBytes: pixel, bytesPerRow: 4, bytesPerImage: 4)
        for face in 0..<6 {
            cube.replace(region: region, mipmapLevel: 0, slice: face, withBytes: pixel, bytesPerRow: 4, bytesPerImage: 4)
        }
        black = (flat, cube)
        return black
    }

    func draw(_ context: GLContext, mode: UInt32, _ source: GLDrawSource) {
        // The arrays that came for this draw hold for it alone, whatever becomes of it.
        defer { context.dropClientArrays() }
        guard mode <= GL.TRIANGLE_FAN else { return context.fail(GL.INVALID_ENUM) }
        var first = 0, count = 0, each = 0
        switch source {
        case .arrays(let start, let vertices):
            guard start >= 0, vertices >= 0 else { return context.fail(GL.INVALID_VALUE) }
            (first, count) = (start, vertices)
        case .elements(let indices, let type, _), .client(let indices, let type, _):
            guard let bytes = Self.indexBytes(type) else { return context.fail(GL.INVALID_ENUM) }
            guard indices >= 0 else { return context.fail(GL.INVALID_VALUE) }
            (count, each) = (indices, bytes)
        }
        guard let target = framebufferStatus(context).target else { return context.fail(GL.INVALID_FRAMEBUFFER_OPERATION) }
        guard count <= GLLimits.drawVertices else { return context.fail(GL.OUT_OF_MEMORY) }
        // The indices, where they lie: in the buffer bound for them, or in the command.
        var indices: UnsafeRawBufferPointer?
        var elements: (buffer: GLBuffer, offset: Int)?
        switch source {
        case .arrays:
            break
        case .elements(_, _, let offset):
            guard let buffer = context.elementBuffer else { return context.fail(GL.INVALID_OPERATION) }
            guard count > 0 else { break }
            guard let bytes = buffer.bytes, offset + count * each <= bytes.count else { return context.fail(GL.INVALID_OPERATION) }
            indices = UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + count * each])
            elements = (buffer, offset)
        case .client(_, _, let data):
            guard data.count == count * each else { return context.fail(GL.INVALID_OPERATION) }
            indices = data
        }

        // From here on nothing is an error of the call: what cannot be seen is not drawn.
        guard let executable = context.program?.executable, let black = blackTextures() else { return }
        let triangles = mode >= GL.TRIANGLES
        guard count >= (triangles ? 3 : mode == GL.POINTS ? 1 : 2) else { return }
        let box = scissorBox(context, target), view = context.viewport
        guard box.width > 0, box.height > 0, view.width > 0, view.height > 0 else { return }
        if triangles, context.cullFace, context.cullMode == GL.FRONT_AND_BACK { return }

        // The vertices the draw reads: `low` to `high`.
        var low = first, high = first + count - 1
        if let indices {
            if let elements, let known = elements.buffer.ranges.first(where: { $0.offset == elements.offset && $0.count == count && $0.type == UInt32(each) }) {
                (low, high) = (known.low, known.high)
            } else {
                (low, high) = Self.range(indices, each: each, count: count)
                if let elements {
                    if elements.buffer.ranges.count >= 16 { elements.buffer.ranges.removeAll() }
                    elements.buffer.ranges.append(GLIndexRange(offset: elements.offset, count: count, type: UInt32(each), low: low, high: high))
                }
            }
        }
        guard let bound = arrays(context, executable, low: low, high: high) else { return }
        // Metal reads an index of all ones as "the strip starts anew". OpenGL ES 2.0 has no such thing, and no array has
        // a vertex of that number (the arrays just said so); with no array at all, a vertex is as good as not drawn.
        guard high < 0xffff_ffff else { return }

        // The indices as Metal draws them. A triangle fan and a line loop, which Metal has not, are drawn
        // as triangles and as a line strip through indices made here.
        var primitive = MTLPrimitiveType.point
        switch mode {
        case GL.POINTS: primitive = .point
        case GL.LINES: primitive = .line
        case GL.LINE_STRIP, GL.LINE_LOOP: primitive = .lineStrip
        case GL.TRIANGLE_STRIP: primitive = .triangleStrip
        default: primitive = .triangle
        }
        var indexed: (buffer: MTLBuffer, offset: Int, type: MTLIndexType, count: Int)?
        func made(_ total: Int, _ value: (Int) -> Int) -> Bool {
            // Four bytes an index: a vertex numbered 0xffff is then no "start anew" either.
            guard total * 4 <= GLArena.largest, let span = arena.allocate(total * 4) else {
                context.fail(GL.OUT_OF_MEMORY)
                return false
            }
            for at in 0..<total {
                span.bytes.storeBytes(of: UInt32(truncatingIfNeeded: value(at)), toByteOffset: at * 4, as: UInt32.self)
            }
            indexed = (span.buffer, span.offset, .uint32, total)
            return true
        }
        func vertex(_ at: Int) -> Int {
            if let indices { return Self.index(indices, each, at) }
            return at
        }
        if mode == GL.TRIANGLE_FAN {
            guard made((count - 2) * 3, { $0 % 3 == 0 ? vertex(0) : vertex($0 / 3 + $0 % 3) }) else { return }
        } else if mode == GL.LINE_LOOP {
            guard made(count + 1, { vertex($0 == count ? 0 : $0) }) else { return }
        } else if let indices {
            if let elements, let memory = elements.buffer.memory, each > 1, elements.offset % each == 0, each == 4 || high < 0xffff {
                elements.buffer.draw(from: elements.offset..<elements.offset + count * each)
                indexed = (memory, elements.offset, each == 2 ? .uint16 : .uint32, count)
            } else if each == 2 || each == 1, high < 0xffff {
                // Bytes, which Metal has no indices of, or indices that came with the draw: sixteen bits each.
                guard let span = arena.allocate(count * 2) else { return context.fail(GL.OUT_OF_MEMORY) }
                for at in 0..<count {
                    span.bytes.storeBytes(of: UInt16(truncatingIfNeeded: Self.index(indices, each, at)), toByteOffset: at * 2, as: UInt16.self)
                }
                indexed = (span.buffer, span.offset, .uint16, count)
            } else {
                guard made(count, { vertex($0) }) else { return }
            }
        }

        // The pipeline: the program for these arrays, this target and this blending.
        var key = GLPipelineKey()
        key.program = executable.serial
        for (index, array) in bound.enumerated() {
            if let array { key.arrays[index] = array.key }
        }
        key.color = target.color?.pixelFormat ?? .invalid
        key.depth = target.depth?.pixelFormat ?? .invalid
        key.stencil = target.stencil?.pixelFormat ?? .invalid
        key.mask = writeMask(context, target).rawValue
        if context.blend, key.color != .invalid,
           let sourceRGB = GLFormats.blend(factor: context.sourceRGB, source: true),
           let destinationRGB = GLFormats.blend(factor: context.destinationRGB, source: false),
           let sourceAlpha = GLFormats.blend(factor: context.sourceAlpha, source: true),
           let destinationAlpha = GLFormats.blend(factor: context.destinationAlpha, source: false),
           let rgb = GLFormats.blend(equation: context.equationRGB), let alpha = GLFormats.blend(equation: context.equationAlpha) {
            key.blend = GLBlendKey(sourceRGB: sourceRGB, destinationRGB: destinationRGB, sourceAlpha: sourceAlpha,
                                   destinationAlpha: destinationAlpha, rgb: rgb, alpha: alpha)
        }
        guard let pipeline = pipeline(executable, key, bound) else { return context.fail(GL.INVALID_OPERATION) }

        // The tests. Where there is no depth or no stencil to test against, OpenGL has the test pass.
        func face(_ face: GLStencilFace) -> GLStencilKey {
            GLStencilKey(compare: GLFormats.compare(face.function) ?? .always, fail: GLFormats.stencil(face.fail) ?? .keep,
                         depthFail: GLFormats.stencil(face.depthFail) ?? .keep, pass: GLFormats.stencil(face.pass) ?? .keep,
                         readMask: face.valueMask & 0xff, writeMask: face.writeMask & 0xff)
        }
        var tests = GLDepthStencilKey()
        if context.depthTest, target.depth != nil {
            tests.compare = GLFormats.compare(context.depthFunction) ?? .always
            tests.write = context.depthMask
        }
        if context.stencilTest, target.stencil != nil {
            tests.front = face(context.front)
            tests.back = face(context.back)
        }
        guard let depthStencil = depthStencilState(tests) else { return }

        // The uniform block as this draw sees it, with which way up and how high what is drawn to is.
        var block: GLSpan?
        if pass?.block !== executable || pass?.generation != executable.generation || pass?.encoder == nil
            || pass?.target.isSame(target) != true {
            guard executable.block.count >= 16, let span = arena.allocate(executable.block.count, alignment: 256) else {
                return context.fail(GL.OUT_OF_MEMORY)
            }
            executable.block.withUnsafeMutableBytes {
                $0.storeBytes(of: target.surface ? Float(1) : Float(-1), toByteOffset: 0, as: Float.self)
                $0.storeBytes(of: Float(target.height), toByteOffset: 4, as: Float.self)
                span.bytes.copyMemory(from: UnsafeRawBufferPointer($0))
            }
            block = span
        }

        guard let encoder = encoder(target), var drawing = pass else { return }
        // A draw of many vertices counts for many draws: what the GPU is handed at once is bounded in both.
        encoded += 1 + count / 256
        if drawing.pipeline !== pipeline {
            encoder.setRenderPipelineState(pipeline)
            drawing.pipeline = pipeline
        }
        if drawing.depthStencil !== depthStencil {
            encoder.setDepthStencilState(depthStencil)
            drawing.depthStencil = depthStencil
        }
        let depthRange = SIMD2(context.depthNear, context.depthFar)
        if drawing.viewport != view || drawing.depthRange != depthRange {
            encoder.setViewport(MTLViewport(originX: Double(view.x), originY: Double(target.surface ? target.height - view.y - view.height : view.y),
                                            width: Double(view.width), height: Double(view.height),
                                            znear: Double(context.depthNear), zfar: Double(context.depthFar)))
            drawing.viewport = view
            drawing.depthRange = depthRange
        }
        if drawing.scissor != box {
            encoder.setScissorRect(MTLScissorRect(x: box.x, y: box.y, width: box.width, height: box.height))
            drawing.scissor = box
        }
        // Turned over, a triangle's vertices go round the other way: the winding that is the front is the other one.
        var raster = GLRaster()
        raster.winding = (context.frontFace == GL.CCW) == target.surface ? .counterClockwise : .clockwise
        if context.cullFace { raster.cull = context.cullMode == GL.FRONT ? .front : .back }
        if context.polygonOffsetFill, triangles { (raster.bias, raster.slope) = (context.offsetUnits, context.offsetFactor) }
        if drawing.raster != raster {
            encoder.setFrontFacing(raster.winding)
            encoder.setCullMode(raster.cull)
            encoder.setDepthBias(raster.bias, slopeScale: raster.slope, clamp: 0)
            drawing.raster = raster
        }
        if drawing.blendColor != context.blendColor {
            encoder.setBlendColor(red: context.blendColor[0], green: context.blendColor[1], blue: context.blendColor[2], alpha: context.blendColor[3])
            drawing.blendColor = context.blendColor
        }
        let references = SIMD2(UInt32(min(max(context.front.reference, 0), 255)), UInt32(min(max(context.back.reference, 0), 255)))
        if drawing.references != references {
            encoder.setStencilReferenceValues(front: references[0], back: references[1])
            drawing.references = references
        }
        if let block {
            encoder.setVertexBuffer(block.buffer, offset: block.offset, index: 30)
            encoder.setFragmentBuffer(block.buffer, offset: block.offset, index: 30)
            drawing.block = executable
            drawing.generation = executable.generation
        }
        pass = drawing
        for (index, array) in bound.enumerated() {
            if let array { encoder.setVertexBuffer(array.buffer, offset: array.offset, index: index) }
        }
        let fallback = samplerState(GLSamplerKey(minFilter: GL.NEAREST, magFilter: GL.NEAREST, wrapS: GL.CLAMP_TO_EDGE, wrapT: GL.CLAMP_TO_EDGE))
        for slot in executable.slots {
            var texture = slot.cube ? black.cube : black.flat, sampler = fallback
            if let uniform = slot.uniform, executable.units.indices.contains(uniform.index),
               executable.units[uniform.index].indices.contains(uniform.element) {
                let unit = executable.units[uniform.index][uniform.element]
                if context.units.indices.contains(unit) {
                    let named = slot.cube ? context.units[unit].cube ?? context.cube : context.units[unit].flat ?? context.flat
                    // Complete, and not what is being drawn to (which OpenGL leaves undefined and Metal forbids): else black.
                    if let memory = named.sampled, !target.uses(memory) {
                        texture = memory
                        sampler = samplerState(GLSamplerKey(minFilter: named.minFilter, magFilter: named.magFilter,
                                                            wrapS: named.wrapS, wrapT: named.wrapT)) ?? fallback
                    }
                }
            }
            if slot.vertexTexture { encoder.setVertexTexture(texture, index: slot.index) }
            if slot.fragmentTexture { encoder.setFragmentTexture(texture, index: slot.index) }
            if slot.vertexSampler { encoder.setVertexSamplerState(sampler, index: slot.index) }
            if slot.fragmentSampler { encoder.setFragmentSamplerState(sampler, index: slot.index) }
        }
        // Every buffer was bound from vertex `low` on: the draw counts its vertices from 0.
        if let indexed {
            encoder.drawIndexedPrimitives(type: primitive, indexCount: indexed.count, indexType: indexed.type, indexBuffer: indexed.buffer,
                                          indexBufferOffset: indexed.offset, instanceCount: 1, baseVertex: indices == nil ? 0 : -low, baseInstance: 0)
        } else {
            encoder.drawPrimitives(type: primitive, vertexStart: 0, vertexCount: count)
        }
    }
}
