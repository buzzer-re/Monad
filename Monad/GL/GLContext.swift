//
//  GLContext.swift — an OpenGL ES 2.0 context of a Linux program, as the
//  Mac keeps it (GLStream.swift): everything a program sets once and
//  draws with many times (what is bound, the tests, the blending, the
//  vertex arrays), and the first error since it last asked. The calls
//  that only set are here, with OpenGL's checks of what they are given.
//

import Foundation
import Metal

struct GLRect: Equatable {
    var x = 0
    var y = 0
    var width = 0
    var height = 0
}

struct GLStencilFace {
    var function = GL.ALWAYS
    var reference = 0
    var valueMask: UInt32 = 0xffff_ffff
    var fail = GL.KEEP
    var depthFail = GL.KEEP
    var pass = GL.KEEP
    var writeMask: UInt32 = 0xffff_ffff
}

/// A vertex attribute's array, as glVertexAttribPointer said it, and the
/// value every vertex gets when the array is not enabled.
struct GLVertexArray {
    var enabled = false
    var size = 4
    var type = GL.FLOAT
    var normalized = false
    var stride = 0
    var offset = 0
    /// nil: the array is the program's own memory, which comes with each draw (GLClientArray).
    var buffer: GLBuffer?
    var value = SIMD4<Float>(0, 0, 0, 1)
}

/// The elements of an array in the program's memory, as they came for the one draw that follows.
struct GLClientArray {
    var buffer: MTLBuffer
    var offset: Int
    var stride: Int
    var format: MTLVertexFormat
    /// The vertex its first element is of, and how many there are.
    var first: Int
    var count: Int
    var bytes: Int
}

struct GLTextureUnit {
    /// nil: the context's own texture, which OpenGL names 0.
    var flat: GLTexture?
    var cube: GLTexture?
}

final class GLContext {
    let name: UInt32
    let share: GLShareGroup
    private(set) var error = GL.NO_ERROR
    /// What it draws on and reads from when no framebuffer is bound, as MakeCurrent said.
    var draw: GLSurface?
    var read: GLSurface?
    /// OpenGL sets the viewport and the scissor box to the surface's size the first time a context is made current.
    var sized = false
    /// Destroyed while current: it goes when another is made current.
    var destroyed = false

    var framebuffers: [UInt32: GLFramebuffer] = [:]
    var framebuffer: GLFramebuffer?
    var renderbuffer: GLRenderbuffer?
    var arrayBuffer: GLBuffer?
    var elementBuffer: GLBuffer?
    var unit = 0
    var units = [GLTextureUnit](repeating: GLTextureUnit(), count: GLLimits.units)
    let flat: GLTexture
    let cube: GLTexture
    var program: GLProgram?
    var arrays = [GLVertexArray](repeating: GLVertexArray(), count: GLLimits.attributes)
    var client = [GLClientArray?](repeating: nil, count: GLLimits.attributes)
    var clientBytes = 0

    var viewport = GLRect()
    var depthNear: Float = 0
    var depthFar: Float = 1
    var scissorTest = false
    var scissor = GLRect()
    var clearColor = SIMD4<Float>(0, 0, 0, 0)
    var clearDepth: Float = 1
    var clearStencil = 0
    var colorMask = SIMD4<UInt8>(1, 1, 1, 1)
    var depthMask = true
    var depthTest = false
    var depthFunction = GL.LESS
    var stencilTest = false
    var front = GLStencilFace()
    var back = GLStencilFace()
    var blend = false
    var sourceRGB = GL.ONE
    var destinationRGB = GL.ZERO
    var sourceAlpha = GL.ONE
    var destinationAlpha = GL.ZERO
    var equationRGB = GL.FUNC_ADD
    var equationAlpha = GL.FUNC_ADD
    var blendColor = SIMD4<Float>(0, 0, 0, 0)
    var cullFace = false
    var cullMode = GL.BACK
    var frontFace = GL.CCW
    var polygonOffsetFill = false
    var offsetFactor: Float = 0
    var offsetUnits: Float = 0

    init(name: UInt32, share: GLShareGroup, budget: GLBudget) {
        self.name = name
        self.share = share
        flat = GLTexture(name: 0, budget: budget, target: GL.TEXTURE_2D)
        cube = GLTexture(name: 0, budget: budget, target: GL.TEXTURE_CUBE_MAP)
    }

    /// OpenGL keeps the first error until it is asked for.
    func fail(_ code: UInt32) {
        if error == GL.NO_ERROR { error = code }
    }

    func takeError() -> UInt32 {
        defer { error = GL.NO_ERROR }
        return error
    }

    /// The texture bound to the active unit for GL.TEXTURE_2D or GL.TEXTURE_CUBE_MAP.
    func texture(_ binding: UInt32) -> GLTexture {
        binding == GL.TEXTURE_CUBE_MAP ? units[unit].cube ?? cube : units[unit].flat ?? flat
    }

    /// The arrays of the draw that is over: they held for it alone.
    func dropClientArrays() {
        guard clientBytes > 0 else { return }
        for index in client.indices { client[index] = nil }
        clientBytes = 0
    }

    // MARK: What only sets

    private static func unit(_ value: Float) -> Float {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }

    private static func finite(_ value: Float) -> Float {
        value.isFinite ? value : 0
    }

    func set(capability: UInt32, _ on: Bool) {
        switch capability {
        case GL.CULL_FACE: cullFace = on
        case GL.BLEND: blend = on
        // Nothing is drawn with these three: Metal does not dither, and nothing here has several samples a pixel.
        // What they are set to is the program's side's to remember (it answers glIsEnabled).
        case GL.DITHER, GL.SAMPLE_ALPHA_TO_COVERAGE, GL.SAMPLE_COVERAGE: break
        case GL.STENCIL_TEST: stencilTest = on
        case GL.DEPTH_TEST: depthTest = on
        case GL.SCISSOR_TEST: scissorTest = on
        case GL.POLYGON_OFFSET_FILL: polygonOffsetFill = on
        default: fail(GL.INVALID_ENUM)
        }
    }

    func set(blendColor red: Float, _ green: Float, _ blue: Float, _ alpha: Float) {
        blendColor = SIMD4(Self.unit(red), Self.unit(green), Self.unit(blue), Self.unit(alpha))
    }

    func blendEquation(rgb: UInt32, alpha: UInt32) {
        guard GLFormats.blend(equation: rgb) != nil, GLFormats.blend(equation: alpha) != nil else { return fail(GL.INVALID_ENUM) }
        equationRGB = rgb
        equationAlpha = alpha
    }

    func blendFunction(sourceRGB: UInt32, destinationRGB: UInt32, sourceAlpha: UInt32, destinationAlpha: UInt32) {
        guard GLFormats.blend(factor: sourceRGB, source: true) != nil, GLFormats.blend(factor: destinationRGB, source: false) != nil,
              GLFormats.blend(factor: sourceAlpha, source: true) != nil, GLFormats.blend(factor: destinationAlpha, source: false) != nil else {
            return fail(GL.INVALID_ENUM)
        }
        self.sourceRGB = sourceRGB
        self.destinationRGB = destinationRGB
        self.sourceAlpha = sourceAlpha
        self.destinationAlpha = destinationAlpha
    }

    func set(clearColor red: Float, _ green: Float, _ blue: Float, _ alpha: Float) {
        clearColor = SIMD4(Self.unit(red), Self.unit(green), Self.unit(blue), Self.unit(alpha))
    }

    func set(clearDepth depth: Float) {
        clearDepth = Self.unit(depth)
    }

    func set(colorMask red: Bool, _ green: Bool, _ blue: Bool, _ alpha: Bool) {
        colorMask = SIMD4(red ? 1 : 0, green ? 1 : 0, blue ? 1 : 0, alpha ? 1 : 0)
    }

    func set(cullFace mode: UInt32) {
        guard mode == GL.FRONT || mode == GL.BACK || mode == GL.FRONT_AND_BACK else { return fail(GL.INVALID_ENUM) }
        cullMode = mode
    }

    func set(frontFace mode: UInt32) {
        guard mode == GL.CW || mode == GL.CCW else { return fail(GL.INVALID_ENUM) }
        frontFace = mode
    }

    func set(depthFunction function: UInt32) {
        guard GLFormats.compare(function) != nil else { return fail(GL.INVALID_ENUM) }
        depthFunction = function
    }

    func depthRange(_ near: Float, _ far: Float) {
        depthNear = Self.unit(near)
        depthFar = Self.unit(far)
    }

    /// Metal's lines are one pixel wide; a width is checked as OpenGL checks it, and that is all.
    func check(lineWidth width: Float) {
        if !(width > 0) { fail(GL.INVALID_VALUE) }
    }

    func polygonOffset(factor: Float, units: Float) {
        offsetFactor = Self.finite(factor)
        offsetUnits = Self.finite(units)
    }

    func set(scissor x: Int, _ y: Int, _ width: Int, _ height: Int) {
        guard width >= 0, height >= 0 else { return fail(GL.INVALID_VALUE) }
        scissor = GLRect(x: x, y: y, width: width, height: height)
    }

    func set(viewport x: Int, _ y: Int, _ width: Int, _ height: Int) {
        guard width >= 0, height >= 0 else { return fail(GL.INVALID_VALUE) }
        viewport = GLRect(x: x, y: y, width: min(width, GLLimits.side), height: min(height, GLLimits.side))
    }

    /// Runs `change` on the faces GL.FRONT, GL.BACK or GL.FRONT_AND_BACK name.
    private func stencil(face: UInt32, _ change: (inout GLStencilFace) -> Void) {
        guard face == GL.FRONT || face == GL.BACK || face == GL.FRONT_AND_BACK else { return fail(GL.INVALID_ENUM) }
        if face != GL.BACK { change(&front) }
        if face != GL.FRONT { change(&back) }
    }

    func stencilFunction(face: UInt32, function: UInt32, reference: Int, mask: UInt32) {
        guard GLFormats.compare(function) != nil else {
            return fail(GL.INVALID_ENUM)
        }
        stencil(face: face) {
            $0.function = function
            $0.reference = reference
            $0.valueMask = mask
        }
    }

    func stencilMask(face: UInt32, mask: UInt32) {
        stencil(face: face) { $0.writeMask = mask }
    }

    func stencilOperation(face: UInt32, fail: UInt32, depthFail: UInt32, pass: UInt32) {
        guard GLFormats.stencil(fail) != nil, GLFormats.stencil(depthFail) != nil, GLFormats.stencil(pass) != nil else {
            return self.fail(GL.INVALID_ENUM)
        }
        stencil(face: face) {
            $0.fail = fail
            $0.depthFail = depthFail
            $0.pass = pass
        }
    }

    func activeTexture(_ texture: UInt32) {
        guard texture >= GL.TEXTURE0, texture - GL.TEXTURE0 < UInt32(GLLimits.units) else { return fail(GL.INVALID_ENUM) }
        unit = Int(texture - GL.TEXTURE0)
    }

    func vertexArray(_ index: UInt32, enabled: Bool) {
        guard index < UInt32(GLLimits.attributes) else { return fail(GL.INVALID_VALUE) }
        arrays[Int(index)].enabled = enabled
    }

    func vertexAttribute(_ index: UInt32, _ value: SIMD4<Float>) {
        guard index < UInt32(GLLimits.attributes) else { return fail(GL.INVALID_VALUE) }
        arrays[Int(index)].value = value
    }

    func vertexPointer(_ index: UInt32, size: Int, type: UInt32, normalized: Bool, stride: Int, offset: UInt32) {
        guard GLFormats.componentBytes(type) != nil else { return fail(GL.INVALID_ENUM) }
        guard index < UInt32(GLLimits.attributes), (1...4).contains(size), stride >= 0 else { return fail(GL.INVALID_VALUE) }
        let enabled = arrays[Int(index)].enabled, value = arrays[Int(index)].value
        arrays[Int(index)] = GLVertexArray(enabled: enabled, size: size, type: type, normalized: normalized, stride: stride,
                                           offset: Int(offset), buffer: arrayBuffer, value: value)
    }
}
