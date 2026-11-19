//
//  GLObjects.swift — what a Linux program's OpenGL ES drawing is made of,
//  as the Mac keeps it (GLStream.swift): buffers, textures, renderbuffers,
//  framebuffers, shaders and programs, each under the name the program's
//  side gave it, and the surfaces its windows draw on.
//
//  A program names as many as it likes and makes them as large as it
//  likes; the Mac's memory is the Mac's. So each kind counts against a
//  bound of the stream (GLBudget, GLLimits), and whatever would pass it is
//  OpenGL's GL_OUT_OF_MEMORY and stays as it was.
//

import CoreGraphics
import Foundation
import IOSurface
import Metal

/// What one stream holds of the Mac's memory, so that it stays under its
/// bounds. The objects count themselves in and out as they come and go.
final class GLBudget {
    var objects = 0
    var bufferBytes = 0
    var textureBytes = 0
    var surfaceBytes = 0
    var sourceBytes = 0
    var uniformBytes = 0
    /// The programs that are linked now, and how many ever were: each has a number no other has.
    var executables = 0
    var linked: UInt64 = 0
    /// Counts the command buffers written: what a buffer was last drawn
    /// from in is compared with it.
    var serial: UInt64 = 1
    /// Bytes let go that the command buffer being written may still draw
    /// with, and so still holds: past a bound it is sent off.
    var retired = 0
}

// MARK: Buffers

/// The lowest and highest index in a stretch of an index buffer, kept so
/// that drawing it again does not read it again.
struct GLIndexRange {
    var offset: Int
    var count: Int
    var type: UInt32
    var low: Int
    var high: Int
}

final class GLBuffer {
    let name: UInt32
    private let budget: GLBudget
    private(set) var size = 0
    /// As long as `size` rounded up to four bytes; nil for none.
    private(set) var memory: MTLBuffer?
    /// The command buffer (GLBudget.serial) that last draws from it, and the bytes of it that one's draws read.
    private var used: UInt64 = 0
    private var drawn = 0..<0
    var ranges: [GLIndexRange] = []

    init(name: UInt32, budget: GLBudget) {
        self.name = name
        self.budget = budget
        budget.objects += 1
    }

    deinit {
        budget.objects -= 1
        budget.bufferBytes -= size
        if used == budget.serial { budget.retired += size }
    }

    /// Other memory, of another size or the same: what is being drawn
    /// from the old one keeps it.
    func replace(_ memory: MTLBuffer?, size: Int) {
        if used == budget.serial { budget.retired += self.size }
        budget.bufferBytes += size - self.size
        self.memory = memory
        self.size = size
        used = 0
        ranges.removeAll()
    }

    /// A draw of the command buffer being written reads these bytes.
    func draw(from range: Range<Int>) {
        drawn = used == budget.serial ? min(drawn.lowerBound, range.lowerBound)..<max(drawn.upperBound, range.upperBound) : range
        used = budget.serial
    }

    /// Whether a draw not yet handed to the GPU reads any of these bytes: they are not to change under it.
    func isDrawn(_ range: Range<Int>) -> Bool {
        used == budget.serial && range.overlaps(drawn)
    }

    /// Its bytes, as many as OpenGL says it has.
    var bytes: UnsafeMutableRawBufferPointer? {
        guard let memory, size > 0, memory.length >= size else { return nil }
        return UnsafeMutableRawBufferPointer(start: memory.contents(), count: size)
    }
}

// MARK: Textures

final class GLTexture {
    /// One image of a texture: a level of a face.
    struct Image {
        var width: Int
        var height: Int
        /// GL.RGBA, GL.LUMINANCE, GL.DEPTH_COMPONENT…
        var format: UInt32
        /// Memory of its own, when it is not the size its level has in
        /// the texture's memory (OpenGL lets a program give the levels in
        /// any order and of any size; only a texture whose levels agree
        /// is drawn with). nil: it lies in `storage`.
        var stray: MTLTexture?
    }

    let name: UInt32
    private let budget: GLBudget
    /// GL.TEXTURE_2D or GL.TEXTURE_CUBE_MAP from its first binding on; 0 before.
    var target: UInt32 = 0
    var minFilter = GL.NEAREST_MIPMAP_LINEAR
    var magFilter = GL.LINEAR
    var wrapS = GL.REPEAT
    var wrapT = GL.REPEAT
    private var images = [Image?](repeating: nil, count: 6 * GLLimits.levels)
    /// The memory of the images that agree with level 0 (of the first
    /// face): one Metal texture, of one level until a smaller one is
    /// given or made.
    var storage: MTLTexture?
    var storageBytes = 0
    /// A level under the first was given or made once: its memory has all levels from then on.
    var mipped = false
    private(set) var bytes = 0

    init(name: UInt32, budget: GLBudget, target: UInt32 = 0) {
        self.name = name
        self.budget = budget
        self.target = target
        budget.objects += 1
    }

    deinit {
        budget.objects -= 1
        budget.textureBytes -= bytes
        budget.retired += bytes
    }

    var isCube: Bool { target == GL.TEXTURE_CUBE_MAP }
    var faces: Int { isCube ? 6 : 1 }

    subscript(face: Int, level: Int) -> Image? {
        get {
            guard (0..<6).contains(face), (0..<GLLimits.levels).contains(level) else { return nil }
            return images[face * GLLimits.levels + level]
        }
        set {
            guard (0..<6).contains(face), (0..<GLLimits.levels).contains(level) else { return }
            images[face * GLLimits.levels + level] = newValue
        }
    }

    func charge(_ count: Int) {
        bytes += count
        budget.textureBytes += count
    }

    func release(_ count: Int) {
        bytes -= count
        budget.textureBytes -= count
        budget.retired += count
    }

    var usesMipmaps: Bool { minFilter != GL.NEAREST && minFilter != GL.LINEAR }

    /// The texture a sampler reads, when OpenGL calls it complete: every
    /// image it would read is there and they agree. nil otherwise, and a
    /// sampler then reads opaque black. Sides that are no powers of two
    /// are sides like others (GL_OES_texture_npot): Metal has no trouble
    /// with them, and programs are careless about what OpenGL ES 2.0
    /// itself asks of them.
    var sampled: MTLTexture? {
        guard let storage, let base = self[0, 0], base.stray == nil else { return nil }
        if isCube, base.width != base.height { return nil }
        let levels = usesMipmaps ? GLFormats.levels(width: base.width, height: base.height) : 1
        guard levels <= storage.mipmapLevelCount else { return nil }
        for face in 0..<faces {
            for level in 0..<levels {
                guard let image = self[face, level], image.stray == nil, image.format == base.format,
                      image.width == max(1, base.width >> level), image.height == max(1, base.height >> level) else { return nil }
            }
        }
        return storage
    }
}

// MARK: Renderbuffers and framebuffers

final class GLRenderbuffer {
    let name: UInt32
    private let budget: GLBudget
    private(set) var width = 0
    private(set) var height = 0
    /// GL.RGBA4, GL.DEPTH_COMPONENT16…; 0 before glRenderbufferStorage.
    private(set) var format: UInt32 = 0
    private(set) var memory: MTLTexture?
    private var bytes = 0

    init(name: UInt32, budget: GLBudget) {
        self.name = name
        self.budget = budget
        budget.objects += 1
    }

    deinit {
        budget.objects -= 1
        budget.textureBytes -= bytes
        budget.retired += bytes
    }

    func replace(_ memory: MTLTexture?, width: Int, height: Int, format: UInt32, bytes: Int) {
        budget.retired += self.bytes
        budget.textureBytes += bytes - self.bytes
        self.memory = memory
        self.width = width
        self.height = height
        self.format = format
        self.bytes = bytes
    }

    var heldBytes: Int { bytes }
}

/// What is attached to one of a framebuffer's three places.
enum GLAttachment {
    case none
    /// A texture's level 0 (OpenGL ES 2.0 attaches no other), of a face.
    case texture(GLTexture, face: Int)
    case renderbuffer(GLRenderbuffer)
}

final class GLFramebuffer {
    let name: UInt32
    private let budget: GLBudget
    var color = GLAttachment.none
    var depth = GLAttachment.none
    var stencil = GLAttachment.none

    init(name: UInt32, budget: GLBudget) {
        self.name = name
        self.budget = budget
        budget.objects += 1
    }

    deinit {
        budget.objects -= 1
    }

    /// Lets go of a texture or renderbuffer that was deleted, wherever it is attached.
    func detach(_ object: AnyObject) {
        func cleared(_ attachment: GLAttachment) -> GLAttachment {
            switch attachment {
            case .texture(let texture, _) where texture === object: return .none
            case .renderbuffer(let renderbuffer) where renderbuffer === object: return .none
            default: return attachment
            }
        }
        color = cleared(color)
        depth = cleared(depth)
        stencil = cleared(stencil)
    }
}

// MARK: Shaders and programs

final class GLShader {
    let name: UInt32
    let stage: GLShaderStage
    private let budget: GLBudget
    private(set) var source = ""
    private var sourceBytes = 0
    /// What the translator made of it, when it compiled.
    var compiled: AnyObject?
    /// The programs it is attached to. Deleted while there are any, it
    /// stays until the last lets go of it.
    var attachments = 0
    var deleted = false

    init(name: UInt32, stage: GLShaderStage, budget: GLBudget) {
        self.name = name
        self.stage = stage
        self.budget = budget
        budget.objects += 1
    }

    deinit {
        budget.objects -= 1
        budget.sourceBytes -= sourceBytes
    }

    func set(source: String, bytes: Int) {
        budget.sourceBytes += bytes - sourceBytes
        self.source = source
        sourceBytes = bytes
    }

    var heldBytes: Int { sourceBytes }
}

/// Something of a linked program's Metal functions that a draw has to
/// give: a texture, a sampler or both, at one of Metal's indices.
struct GLTextureSlot {
    var index: Int
    var cube = false
    var vertexTexture = false
    var fragmentTexture = false
    var vertexSampler = false
    var fragmentSampler = false
    /// The sampler uniform that says which texture unit it reads, and the element of it.
    var uniform: (index: Int, element: Int)?
}

/// A program that linked: what draws.
final class GLExecutable {
    /// Its number among all the stream ever linked: what the pipelines made for it are kept under.
    let serial: UInt64
    let reflection: GLLinkedProgram
    let vertex: MTLFunction
    let fragment: MTLFunction
    /// The attribute locations the vertex function reads, as bits.
    let attributes: UInt32
    let slots: [GLTextureSlot]
    /// The uniform block as the next draw gets it. Its first 16 bytes are written for each draw.
    var block: [UInt8]
    /// For each uniform that is a sampler, the texture unit of each element.
    var units: [[Int]]
    /// Counts the changes to `block`, so that a draw after none uses the copy the one before made.
    var generation: UInt64 = 0
    private let budget: GLBudget

    init(reflection: GLLinkedProgram, vertex: MTLFunction, fragment: MTLFunction, attributes: UInt32, slots: [GLTextureSlot],
         blockBytes: Int, budget: GLBudget) {
        self.reflection = reflection
        self.vertex = vertex
        self.fragment = fragment
        self.attributes = attributes
        self.slots = slots
        block = [UInt8](repeating: 0, count: blockBytes)
        units = reflection.uniforms.map { $0.texture == nil ? [] : [Int](repeating: 0, count: $0.size) }
        self.budget = budget
        budget.uniformBytes += blockBytes
        budget.executables += 1
        budget.linked += 1
        serial = budget.linked
    }

    deinit {
        budget.uniformBytes -= block.count
        budget.executables -= 1
    }

    /// The uniform a location is in, and which element of it.
    func uniform(at location: Int) -> (index: Int, element: Int)? {
        for (index, uniform) in reflection.uniforms.enumerated() where location >= uniform.location && location - uniform.location < uniform.size {
            return (index, location - uniform.location)
        }
        return nil
    }
}

final class GLProgram {
    let name: UInt32
    private let budget: GLBudget
    var vertex: GLShader?
    var fragment: GLShader?
    /// What glBindAttribLocation asked for, for the next link. The names count as a shader's text does.
    private(set) var locations: [String: Int] = [:]
    private var locationBytes = 0
    /// nil until it links, and again when a link fails.
    var executable: GLExecutable?
    /// The contexts it is the current program of. Deleted while there
    /// are any, it stays until the last uses another.
    var users = 0
    var deleted = false

    init(name: UInt32, budget: GLBudget) {
        self.name = name
        self.budget = budget
        budget.objects += 1
    }

    deinit {
        budget.objects -= 1
        budget.sourceBytes -= locationBytes
    }

    func bind(attribute: String, bytes: Int, to location: Int) {
        if locations.updateValue(location, forKey: attribute) == nil {
            locationBytes += bytes
            budget.sourceBytes += bytes
        }
    }
}

/// The objects contexts share: a context made with another's shares its.
final class GLShareGroup {
    var buffers: [UInt32: GLBuffer] = [:]
    var textures: [UInt32: GLTexture] = [:]
    var renderbuffers: [UInt32: GLRenderbuffer] = [:]
    /// Shaders and programs are named from one set of names, as OpenGL has it.
    var shaders: [UInt32: GLShader] = [:]
    var programs: [UInt32: GLProgram] = [:]
}

// MARK: Surfaces

/// What a window (or a pbuffer) draws on: the picture being drawn, the
/// ones before it that the Mac still shows, and the depth and stencil
/// that go with them, when its EGL config has any.
///
/// A picture handed over to be shown is marked as in use by whoever
/// shows it (IOSurface's use count), for as long as it does. The next
/// picture is drawn into memory that is not in use, so that a window
/// never shows a picture half drawn again; when all there is is in use,
/// more is made, up to `pictures` of them.
final class GLSurface {
    /// The most pictures a surface has. MonadHost holds three at most (the one a window shows, the one on its way to
    /// the window, the newest waiting its turn), the Mac's window server may hold one a moment longer, and one is drawn.
    static let pictures = 5

    private struct Picture {
        let surface: IOSurface
        let texture: MTLTexture
        /// The swap that presented it last; 0 for none yet.
        var presented: UInt64 = 0
    }

    let name: UInt32
    /// Whether it has an alpha of its own, a depth and a stencil, as SurfaceCreate said: a resize keeps them.
    let alpha: Bool
    let depth: Bool
    let stencil: Bool
    private let budget: GLBudget
    private(set) var width = 0
    private(set) var height = 0
    private var memory: [Picture] = []
    /// The depth, the stencil, or the two in one, whichever it has; nil when it has neither.
    private(set) var depthStencil: MTLTexture?
    private var turn = 0
    private var swaps: UInt64 = 0
    private var bytes = 0

    init(name: UInt32, alpha: Bool, depth: Bool, stencil: Bool, budget: GLBudget) {
        self.name = name
        self.alpha = alpha
        self.depth = depth
        self.stencil = stencil
        self.budget = budget
    }

    deinit {
        budget.surfaceBytes -= bytes
        budget.retired += bytes
    }

    private var depthStencilFormat: MTLPixelFormat? {
        depth ? (stencil ? .depth32Float_stencil8 : .depth32Float) : (stencil ? .stencil8 : nil)
    }

    /// What it holds of the stream's memory, and what it would at a size when it is made or resized: one picture,
    /// and its depth and stencil. Each further picture is counted when it is made.
    var heldBytes: Int { bytes }

    func bytes(width: Int, height: Int) -> Int {
        width * height * (4 + (depthStencilFormat.map { GLFormats.bytes($0) } ?? 0))
    }

    /// The picture being drawn.
    var picture: (surface: IOSurface, texture: MTLTexture)? {
        memory.indices.contains(turn) ? (memory[turn].surface, memory[turn].texture) : nil
    }

    private static func makePicture(width: Int, height: Int, device: MTLDevice) -> Picture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        // The picture is the Mac's memory as much as the GPU's: the window shows it from there.
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
                                                   .pixelFormat: UInt32(0x4247_5241) /* 'BGRA' */]) else { return nil }
        // Programs draw for an ordinary screen: without this the Mac would take the colours for its own display's.
        if let space = CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList() {
            surface.setAttachment(space, forKey: kIOSurfaceColorSpace as String)
        }
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: unsafeBitCast(surface, to: IOSurfaceRef.self), plane: 0) else { return nil }
        return Picture(surface: surface, texture: texture)
    }

    /// Memory for width × height pixels: one picture, which is returned to be cleared, and the depth and stencil.
    /// nil, and it is as it was, when there is none. The pictures it had are let go of; what shows them keeps them.
    func resize(width: Int, height: Int, device: MTLDevice) -> MTLTexture? {
        guard let first = Self.makePicture(width: width, height: height, device: device) else { return nil }
        var fresh: MTLTexture?
        if let format = depthStencilFormat {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = .renderTarget
            descriptor.storageMode = .private
            guard let made = device.makeTexture(descriptor: descriptor) else { return nil }
            fresh = made
        }
        let count = bytes(width: width, height: height)
        budget.retired += bytes
        budget.surfaceBytes += count - bytes
        bytes = count
        memory = [first]
        depthStencil = fresh
        self.width = width
        self.height = height
        turn = 0
        return first.texture
    }

    /// The picture being drawn was handed over to be shown: the next is drawn into another. Returns the memory
    /// that was made for it, if any was, to be cleared.
    func advance(device: MTLDevice) -> MTLTexture? {
        guard memory.indices.contains(turn) else { return nil }
        swaps += 1
        memory[turn].presented = swaps
        func longestAgo(_ pictures: [Int]) -> Int? {
            pictures.min { memory[$0].presented < memory[$1].presented }
        }
        // One that nothing shows; of several, the one shown longest ago, which is the least likely to be looked at still
        // by something that does not say so.
        if let free = longestAgo(memory.indices.filter { !memory[$0].surface.isInUse }) {
            turn = free
            return nil
        }
        let count = width * height * 4
        if memory.count < Self.pictures, budget.surfaceBytes + count <= GLLimits.surfaceBytes,
           let fresh = Self.makePicture(width: width, height: height, device: device) {
            bytes += count
            budget.surfaceBytes += count
            memory.append(fresh)
            turn = memory.count - 1
            return fresh.texture
        }
        // All of them are shown, and there may be no more. The stream waits for nobody who shows pictures: it draws
        // into the one shown longest ago, which a window that keeps up has long replaced.
        turn = longestAgo(Array(memory.indices)) ?? turn
        return nil
    }
}
