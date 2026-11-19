//
//  GLStreamTests.swift — a Linux program's OpenGL ES 2.0 commands carried
//  out with Metal (GLStream): streams written here the way the guest's
//  library writes them (GuestWM/mwm_gl_wire.h), drawn by this Mac's GPU,
//  and what came of them read back as pixels and answers. The shaders are
//  Metal source written here by hand, handed over by a translator that
//  only looks them up, so that nothing but the drawing is tested.
//
//  The stream is a guest's: the last tests feed it what no library would
//  send. They are to be run with Metal's own checks on (MTL_DEBUG_LAYER=1),
//  under which anything handed to Metal that it would not have is a crash.
//

import IOSurface
import Metal
import XCTest
@testable import Monad

/// The commands' numbers, written down from mwm_gl_wire.h a second time:
/// a number wrong in GLStream is a test that fails.
private enum Op {
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
    static let uniform1f: UInt32 = 85, uniform2f: UInt32 = 86, uniform3f: UInt32 = 87, uniform4f: UInt32 = 88
    static let uniform1i: UInt32 = 89, uniform2i: UInt32 = 90, uniform3i: UInt32 = 91, uniform4i: UInt32 = 92
    static let uniform1fv: UInt32 = 93, uniform2fv: UInt32 = 94, uniform3fv: UInt32 = 95, uniform4fv: UInt32 = 96
    static let uniform1iv: UInt32 = 97, uniform2iv: UInt32 = 98, uniform3iv: UInt32 = 99, uniform4iv: UInt32 = 100
    static let uniformMatrix2fv: UInt32 = 101, uniformMatrix3fv: UInt32 = 102, uniformMatrix4fv: UInt32 = 103
    static let useProgram: UInt32 = 104, vertexAttrib4f: UInt32 = 105, vertexAttribPointer: UInt32 = 106, viewport: UInt32 = 107

    static let answered: Set<UInt32> = [swap, checkFramebufferStatus, compileShader, finish, getError, getUniform, linkProgram, readPixels]
}

/// One argument of a command: a word, or `data` (nil: MWM_GL_NONE).
private enum Arg: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    case word(UInt32)
    case data(Data?)

    init(integerLiteral value: Int) {
        self = .word(UInt32(truncatingIfNeeded: value))
    }

    init(floatLiteral value: Double) {
        self = .word(Float(value).bitPattern)
    }

    static func u(_ value: UInt32) -> Arg { .word(value) }
    static func i(_ value: Int) -> Arg { .word(UInt32(truncatingIfNeeded: value)) }
    static func f(_ value: Float) -> Arg { .word(value.bitPattern) }
    static func text(_ value: String) -> Arg { .data(Data(value.utf8)) }
    static func floats(_ values: [Float]) -> Arg { .data(bytes(values)) }
    static func ints(_ values: [Int32]) -> Arg { .data(bytes(values)) }
    static func names(_ values: [UInt32]) -> Arg { .data(bytes(values)) }
}

private func bytes<T>(_ values: [T]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
}

private func word(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

/// A command as the header has it: the op, the size of all of it, the arguments.
private func command(_ op: UInt32, _ arguments: [Arg]) -> Data {
    var body = Data()
    for argument in arguments {
        switch argument {
        case .word(let value):
            body.append(word(value))
        case .data(nil):
            body.append(word(0xffff_ffff))
        case .data(let data?):
            body.append(word(UInt32(data.count)))
            body.append(data)
            body.append(Data(count: (4 - data.count % 4) % 4))
        }
    }
    return word(op) + word(UInt32(8 + body.count)) + body
}

/// Reads an answer: its words and `data`.
private struct Answer {
    var bytes: Data
    var at = 0

    mutating func word() -> UInt32 {
        guard at + 4 <= bytes.count else {
            XCTFail("the answer ends before a word")
            return 0
        }
        defer { at += 4 }
        return bytes.subdata(in: at..<at + 4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    mutating func data() -> Data {
        let count = Int(word())
        guard at + count <= bytes.count else {
            XCTFail("the answer ends before its data")
            return Data()
        }
        defer { at += (count + 3) & ~3 }
        return bytes.subdata(in: at..<at + count)
    }

    mutating func text() -> String {
        String(decoding: data(), as: UTF8.self)
    }
}

// MARK: Shaders written by hand

/// What a test's shaders are in Metal's language, holding to what
/// GLShaders.swift says of a translator's.
private enum Programs {
    static let prelude = """
    #include <metal_stdlib>
    using namespace metal;

    """
    /// gl_Position as Metal takes it: y by the block's first float, z from -w…w to 0…w.
    static let position = "float4(p.x, p.y * block.flip, (p.z + p.w) * 0.5, p.w)"

    /// One colour for everything, from a uniform (vec4 color, location 0).
    static let flat = GLLinkedProgram(metal: prelude + """
    struct Block { float flip; float height; float pad[2]; float4 color; };
    struct In { float4 position [[attribute(0)]]; };
    struct Out { float4 position [[position]]; float size [[point_size]]; };
    vertex Out monad_vertex(In in [[stage_in]], constant Block &block [[buffer(30)]]) {
        float4 p = in.position;
        Out out;
        out.position = \(position);
        out.size = 1.0;
        return out;
    }
    fragment float4 monad_fragment(constant Block &block [[buffer(30)]]) {
        return block.color;
    }
    """, attributes: [GLAttribute(name: "position", type: GL.FLOAT_VEC4, location: 0)],
    uniforms: [GLUniform(name: "color", type: GL.FLOAT_VEC4, size: 1, location: 0, offset: 16, stride: 16, columns: 1, rows: 4, columnStride: 16, texture: nil)],
    uniformBytes: 32)

    /// A colour for each vertex.
    static let color = GLLinkedProgram(metal: prelude + """
    struct Block { float flip; float height; };
    struct In { float4 position [[attribute(0)]]; float4 color [[attribute(1)]]; };
    struct Out { float4 position [[position]]; float4 color; };
    vertex Out monad_vertex(In in [[stage_in]], constant Block &block [[buffer(30)]]) {
        float4 p = in.position;
        Out out;
        out.position = \(position);
        out.color = in.color;
        return out;
    }
    fragment float4 monad_fragment(Out in [[stage_in]]) {
        return in.color;
    }
    """, attributes: [GLAttribute(name: "position", type: GL.FLOAT_VEC4, location: 0), GLAttribute(name: "color", type: GL.FLOAT_VEC4, location: 1)],
    uniforms: [], uniformBytes: 16)

    /// A texture (sampler2D tex, location 0, Metal's texture 0) at each vertex's coordinates.
    static let texture = GLLinkedProgram(metal: prelude + """
    struct Block { float flip; float height; };
    struct In { float4 position [[attribute(0)]]; float2 uv [[attribute(1)]]; };
    struct Out { float4 position [[position]]; float2 uv; };
    vertex Out monad_vertex(In in [[stage_in]], constant Block &block [[buffer(30)]]) {
        float4 p = in.position;
        Out out;
        out.position = \(position);
        out.uv = in.uv;
        return out;
    }
    fragment float4 monad_fragment(Out in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
        return tex.sample(smp, in.uv);
    }
    """, attributes: [GLAttribute(name: "position", type: GL.FLOAT_VEC4, location: 0), GLAttribute(name: "uv", type: GL.FLOAT_VEC2, location: 1)],
    uniforms: [GLUniform(name: "tex", type: GL.SAMPLER_2D, size: 1, location: 0, offset: 0, stride: 0, columns: 1, rows: 1, columnStride: 0, texture: 0)],
    uniformBytes: 16)

    /// A cube texture (samplerCube tex) in the direction each vertex gives.
    static let cube = GLLinkedProgram(metal: prelude + """
    struct Block { float flip; float height; };
    struct In { float4 position [[attribute(0)]]; float3 direction [[attribute(1)]]; };
    struct Out { float4 position [[position]]; float3 direction; };
    vertex Out monad_vertex(In in [[stage_in]], constant Block &block [[buffer(30)]]) {
        float4 p = in.position;
        Out out;
        out.position = \(position);
        out.direction = in.direction;
        return out;
    }
    fragment float4 monad_fragment(Out in [[stage_in]], texturecube<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
        return tex.sample(smp, in.direction);
    }
    """, attributes: [GLAttribute(name: "position", type: GL.FLOAT_VEC4, location: 0), GLAttribute(name: "direction", type: GL.FLOAT_VEC3, location: 1)],
    uniforms: [GLUniform(name: "tex", type: GL.SAMPLER_CUBE, size: 1, location: 0, offset: 0, stride: 0, columns: 1, rows: 1, columnStride: 0, texture: 0)],
    uniformBytes: 16)

    /// Green where gl_FrontFacing, red where not; blue is gl_FragCoord.y over the height, as GLShaders.swift says to work it out.
    static let facing = GLLinkedProgram(metal: prelude + """
    struct Block { float flip; float height; };
    struct In { float4 position [[attribute(0)]]; };
    struct Out { float4 position [[position]]; };
    vertex Out monad_vertex(In in [[stage_in]], constant Block &block [[buffer(30)]]) {
        float4 p = in.position;
        Out out;
        out.position = \(position);
        return out;
    }
    fragment float4 monad_fragment(Out in [[stage_in]], bool front [[front_facing]], constant Block &block [[buffer(30)]]) {
        float y = block.flip > 0.0 ? block.height - in.position.y : in.position.y;
        return float4(front ? 0.0 : 1.0, front ? 1.0 : 0.0, y / block.height, 1.0);
    }
    """, attributes: [GLAttribute(name: "position", type: GL.FLOAT_VEC4, location: 0)], uniforms: [], uniformBytes: 16)

    /// A uniform of every type; `pick` says which of them is the colour.
    static let uniforms: GLLinkedProgram = {
        func one(_ name: String, _ type: UInt32, _ location: Int, _ offset: Int, columns: Int = 1, rows: Int, columnStride: Int = 0,
                 size: Int = 1, stride: Int = 0) -> GLUniform {
            GLUniform(name: name, type: type, size: size, location: location, offset: offset, stride: stride, columns: columns, rows: rows,
                      columnStride: columnStride, texture: nil)
        }
        return GLLinkedProgram(metal: prelude + """
        struct Block {
            float flip; float height; float pad[2];
            float f; int pick; float2 v2; float3 v3; float4 v4;
            int i1; int2 i2; int3 i3; int4 i4;
            int b1; int2 b2; int3 b3; int4 b4;
            float2x2 m2; float3x3 m3; float4x4 m4;
            float4 arr[3];
        };
        struct In { float4 position [[attribute(0)]]; };
        struct Out { float4 position [[position]]; };
        vertex Out monad_vertex(In in [[stage_in]], constant Block &block [[buffer(30)]]) {
            float4 p = in.position;
            Out out;
            out.position = \(position);
            return out;
        }
        fragment float4 monad_fragment(constant Block &block [[buffer(30)]]) {
            switch (block.pick) {
            case 0: return float4(block.f, block.v2, 1.0);
            case 1: return float4(block.v3, 1.0);
            case 2: return block.v4;
            case 3: return float4(block.i1, block.i2.x, block.i2.y, 255) / 255.0;
            case 4: return float4(block.i3.x, block.i3.y, block.i3.z, 255) / 255.0;
            case 5: return float4(block.i4) / 255.0;
            case 6: return float4(block.b1, block.b2.x, block.b2.y, 1);
            case 7: return float4(block.b3.x, block.b3.y, block.b3.z, 1);
            case 8: return float4(block.b4);
            case 9: return float4(block.m2[0], block.m2[1]);
            case 10: return float4(block.m3[0], 1.0);
            case 11: return float4(block.m3[1], 1.0);
            case 12: return float4(block.m3[2], 1.0);
            case 13: return block.m4[0];
            case 14: return block.m4[1];
            case 15: return block.m4[2];
            case 16: return block.m4[3];
            case 17: return block.arr[0];
            case 18: return block.arr[1];
            default: return block.arr[2];
            }
        }
        """, attributes: [GLAttribute(name: "position", type: GL.FLOAT_VEC4, location: 0)],
        uniforms: [
            one("f", GL.FLOAT, 0, 16, rows: 1), one("pick", GL.INT, 1, 20, rows: 1), one("v2", GL.FLOAT_VEC2, 2, 24, rows: 2),
            one("v3", GL.FLOAT_VEC3, 3, 32, rows: 3), one("v4", GL.FLOAT_VEC4, 4, 48, rows: 4),
            one("i1", GL.INT, 5, 64, rows: 1), one("i2", GL.INT_VEC2, 6, 72, rows: 2), one("i3", GL.INT_VEC3, 7, 80, rows: 3),
            one("i4", GL.INT_VEC4, 8, 96, rows: 4),
            one("b1", GL.BOOL, 9, 112, rows: 1), one("b2", GL.BOOL_VEC2, 10, 120, rows: 2), one("b3", GL.BOOL_VEC3, 11, 128, rows: 3),
            one("b4", GL.BOOL_VEC4, 12, 144, rows: 4),
            one("m2", GL.FLOAT_MAT2, 13, 160, columns: 2, rows: 2, columnStride: 8),
            one("m3", GL.FLOAT_MAT3, 14, 176, columns: 3, rows: 3, columnStride: 16),
            one("m4", GL.FLOAT_MAT4, 15, 224, columns: 4, rows: 4, columnStride: 16),
            one("arr[0]", GL.FLOAT_VEC4, 16, 288, rows: 4, size: 3, stride: 16),
        ], uniformBytes: 336)
    }()

    /// What a translator gone wrong might hand over: none of these may be drawn with, and none may crash anything.
    static let notMetal = GLLinkedProgram(metal: "this is no Metal", attributes: [], uniforms: [], uniformBytes: 16)
    static let outsideBlock: GLLinkedProgram = {
        var program = flat
        program.uniforms[0].offset = 24
        return program
    }()
    static let otherBuffer = GLLinkedProgram(metal: flat.metal.replacingOccurrences(of: "monad_fragment(constant Block &block [[buffer(30)]])",
                                                                                   with: "monad_fragment(constant Block &block [[buffer(3)]])"),
                                             attributes: flat.attributes, uniforms: flat.uniforms, uniformBytes: 32)
    /// Says its uniforms take less than its Metal struct does.
    static let shortBlock: GLLinkedProgram = {
        var program = uniforms
        program.uniforms = Array(program.uniforms.prefix(2))
        program.uniformBytes = 24
        return program
    }()
    static let noFunctions = GLLinkedProgram(metal: prelude + "float4 helper() { return float4(0.0); }", attributes: [], uniforms: [], uniformBytes: 16)
    static let farAttribute = GLLinkedProgram(metal: flat.metal.replacingOccurrences(of: "[[attribute(0)]]", with: "[[attribute(20)]]"),
                                              attributes: flat.attributes, uniforms: flat.uniforms, uniformBytes: 32)
    static let solidTexture = GLLinkedProgram(metal: texture.metal.replacingOccurrences(of: "texture2d<float> tex", with: "texture3d<float> tex")
                                                .replacingOccurrences(of: "tex.sample(smp, in.uv)", with: "tex.sample(smp, float3(in.uv, 0.0))"),
                                              attributes: texture.attributes, uniforms: texture.uniforms, uniformBytes: 16)

    /// A texture read by the vertex function, which hands its colour on.
    static let vertexTexture = GLLinkedProgram(metal: prelude + """
    struct Block { float flip; float height; };
    struct In { float4 position [[attribute(0)]]; };
    struct Out { float4 position [[position]]; float4 color; };
    vertex Out monad_vertex(In in [[stage_in]], constant Block &block [[buffer(30)]], texture2d<float> tex [[texture(2)]], sampler smp [[sampler(2)]]) {
        float4 p = in.position;
        Out out;
        out.position = \(position);
        out.color = tex.sample(smp, float2(0.5, 0.5), level(0.0));
        return out;
    }
    fragment float4 monad_fragment(Out in [[stage_in]]) {
        return in.color;
    }
    """, attributes: [GLAttribute(name: "position", type: GL.FLOAT_VEC4, location: 0)],
    uniforms: [GLUniform(name: "tex", type: GL.SAMPLER_2D, size: 1, location: 0, offset: 0, stride: 0, columns: 1, rows: 1, columnStride: 0, texture: 2)],
    uniformBytes: 16)

    /// As the translator lays a program out: a block struct for each function, padded so that what both have lies at one
    /// place; an array of samplers (sampler2D tex[2], Metal's textures 3 and 4) whose uniform has no place in the block
    /// at all; and no point size, which only a shader that names gl_PointSize has.
    static let stages = GLLinkedProgram(metal: prelude + """
    struct VertexBlock { float flip; float height; float pad[2]; float4 shift; };
    struct FragmentBlock { float flip; float height; float pad[2]; float4 vertexOnly; float4 tint; };
    struct In { float4 position [[attribute(0)]]; };
    struct Out { float4 position [[position]]; };
    vertex Out monad_vertex(In in [[stage_in]], constant VertexBlock &block [[buffer(30)]]) {
        float4 p = in.position + block.shift;
        Out out;
        out.position = \(position);
        return out;
    }
    fragment float4 monad_fragment(constant FragmentBlock &block [[buffer(30)]],
                                   texture2d<float> first [[texture(3)]], sampler firstSampler [[sampler(3)]],
                                   texture2d<float> second [[texture(4)]], sampler secondSampler [[sampler(4)]]) {
        return (first.sample(firstSampler, float2(0.5, 0.5)) + second.sample(secondSampler, float2(0.5, 0.5))) * block.tint;
    }
    """, attributes: [GLAttribute(name: "position", type: GL.FLOAT_VEC4, location: 0)],
    uniforms: [
        GLUniform(name: "shift", type: GL.FLOAT_VEC4, size: 1, location: 0, offset: 16, stride: 0, columns: 1, rows: 4, columnStride: 0, texture: nil),
        GLUniform(name: "tint", type: GL.FLOAT_VEC4, size: 1, location: 1, offset: 32, stride: 0, columns: 1, rows: 4, columnStride: 0, texture: nil),
        GLUniform(name: "tex[0]", type: GL.SAMPLER_2D, size: 2, location: 2, offset: 0, stride: 0, columns: 1, rows: 1, columnStride: 0, texture: 3),
    ], uniformBytes: 48)

    /// Green where its uniform (float f, location 0) is no number, red where it is one: a question Metal's compiler
    /// answers "never" before the shader runs, when it is allowed to take every float for a number.
    static let notANumber = GLLinkedProgram(metal: prelude + """
    struct Block { float flip; float height; float pad[2]; float f; };
    struct In { float4 position [[attribute(0)]]; };
    struct Out { float4 position [[position]]; };
    vertex Out monad_vertex(In in [[stage_in]], constant Block &block [[buffer(30)]]) {
        float4 p = in.position;
        Out out;
        out.position = \(position);
        return out;
    }
    fragment float4 monad_fragment(constant Block &block [[buffer(30)]]) {
        return block.f != block.f ? float4(0.0, 1.0, 0.0, 1.0) : float4(1.0, 0.0, 0.0, 1.0);
    }
    """, attributes: [GLAttribute(name: "position", type: GL.FLOAT_VEC4, location: 0)],
    uniforms: [GLUniform(name: "f", type: GL.FLOAT, size: 1, location: 0, offset: 16, stride: 0, columns: 1, rows: 1, columnStride: 0, texture: nil)],
    uniformBytes: 20)

    /// Says its uniforms take the most one program's may, and sixteen bytes more than that.
    static let wide: GLLinkedProgram = {
        var program = flat
        program.uniformBytes = GLLimits.blockBytes
        return program
    }()
    static let tooWide: GLLinkedProgram = {
        var program = flat
        program.uniformBytes = GLLimits.blockBytes + 16
        return program
    }()

    static let all: [String: GLLinkedProgram] = [
        "flat": flat, "color": color, "texture": texture, "cube": cube, "facing": facing, "uniforms": uniforms, "vertexTexture": vertexTexture,
        "notMetal": notMetal, "outsideBlock": outsideBlock, "otherBuffer": otherBuffer, "shortBlock": shortBlock,
        "noFunctions": noFunctions, "farAttribute": farAttribute, "solidTexture": solidTexture,
        "stages": stages, "notANumber": notANumber, "wide": wide, "tooWide": tooWide,
    ]
}

/// Stands in for the shader translator: a shader's text is the name of
/// one of the programs above, and one that starts "bad" does not compile.
private final class Translator: GLShaderTranslating, @unchecked Sendable {
    final class Shader {
        let source: String
        let stage: GLShaderStage
        init(source: String, stage: GLShaderStage) {
            self.source = source
            self.stage = stage
        }
    }

    private let lock = NSLock()
    private var asked: [String: Int] = [:]

    /// What glBindAttribLocation had asked for when the last program was linked.
    var locations: [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    func compile(_ source: String, stage: GLShaderStage) -> (shader: AnyObject?, log: String) {
        if source.hasPrefix("bad") { return (nil, "ERROR: 0:1: '\(source)' : syntax error") }
        return (Shader(source: source, stage: stage), source.hasPrefix("warn") ? "WARNING: unused" : "")
    }

    func link(vertex: AnyObject, fragment: AnyObject, attributeLocations: [String: Int]) -> (program: GLLinkedProgram?, log: String) {
        lock.lock()
        asked = attributeLocations
        lock.unlock()
        guard let vertex = vertex as? Shader, let fragment = fragment as? Shader, vertex.stage == .vertex, fragment.stage == .fragment,
              vertex.source == fragment.source, let program = Programs.all[vertex.source] else {
            return (nil, "ERROR: the shaders do not go together")
        }
        return (program, "")
    }
}

// MARK: A stream under test

/// What a stream under test said: its answers and the pictures it presented.
private final class Heard {
    var answers: [Data] = []
    var presented: [(surface: UInt32, picture: IOSurface, width: Int, height: Int)] = []
    /// The pixel in the middle of each picture as it was when it was presented, and how many answers had come by then.
    var middles: [[UInt8]] = []
    var answersAtPresent: [Int] = []
    /// How many of the newest pictures are marked as in use, the way MonadHost marks the ones its windows show
    /// (IOSurface's use count); the older ones are let go of. 0: none is.
    var keeps = 0
    private var kept: [IOSurface] = []

    deinit {
        for picture in kept { picture.decrementUseCount() }
    }

    func present(_ surface: UInt32, _ picture: IOSurface, _ width: Int, _ height: Int) {
        presented.append((surface, picture, width, height))
        middles.append(Rig.pixel(picture, width / 2, height / 2))
        answersAtPresent.append(answers.count)
        guard keeps > 0 else { return }
        picture.incrementUseCount()
        kept.append(picture)
        while kept.count > keeps { kept.removeFirst().decrementUseCount() }
    }
}

private final class Rig {
    static let device = MTLCreateSystemDefaultDevice()

    let translator = Translator()
    let stream: GLStream
    private let heard = Heard()
    private var names: UInt32 = 100

    var answers: [Data] { heard.answers }
    var presented: [(surface: UInt32, picture: IOSurface, width: Int, height: Int)] { heard.presented }
    var middles: [[UInt8]] { heard.middles }
    var answersAtPresent: [Int] { heard.answersAtPresent }
    var keeps: Int {
        get { heard.keeps }
        set { heard.keeps = newValue }
    }

    /// With `size`, a context (1) made current on a surface (1) of that size, with the buffers said.
    init(size: Int? = 16, alpha: Bool = true, depth: Bool = true, stencil: Bool = true) throws {
        let device = try XCTUnwrap(Self.device, "these tests draw with a Metal device")
        let heard = heard
        stream = GLStream(device: device, translator: translator, reply: { heard.answers.append($0) },
                          present: { heard.present($0, $1, $2, $3) })
        if let size {
            send(Op.contextCreate, 1, 0)
            send(Op.surfaceCreate, 1, .i(size), .i(size), alpha ? 1 : 0, depth ? 1 : 0, stencil ? 1 : 0)
            send(Op.makeCurrent, 1, 1, 1)
        }
    }

    func name() -> UInt32 {
        names += 1
        return names
    }

    func feed(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(stream.feed(data), "the stream goes on", file: file, line: line)
    }

    func send(_ op: UInt32, _ arguments: Arg..., file: StaticString = #filePath, line: UInt = #line) {
        feed(command(op, arguments), file: file, line: line)
    }

    /// Sends a command that is answered, and gives its answer: what follows the length, which is checked.
    func ask(_ op: UInt32, _ arguments: Arg..., file: StaticString = #filePath, line: UInt = #line) -> Answer {
        let before = answers.count
        feed(command(op, arguments), file: file, line: line)
        guard answers.count == before + 1, let answer = answers.last, answer.count >= 4 else {
            XCTFail("one answer to one command, not \(answers.count - before)", file: file, line: line)
            return Answer(bytes: Data())
        }
        var whole = Answer(bytes: answer)
        let length = Int(whole.word())
        XCTAssertEqual(length, answer.count - 4, "an answer's length is that of what follows it", file: file, line: line)
        XCTAssertEqual(length % 4, 0, "an answer's length is a multiple of four", file: file, line: line)
        return Answer(bytes: answer.subdata(in: 4..<answer.count))
    }

    /// The last answer as it was sent, its length included.
    var lastAnswer: Data { answers.last ?? Data() }

    func error(file: StaticString = #filePath, line: UInt = #line) -> UInt32 {
        var answer = ask(Op.getError, file: file, line: line)
        return answer.word()
    }

    func expectNoError(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(error(file: file, line: line), GL.NO_ERROR, "no OpenGL error", file: file, line: line)
    }

    // What a program does over and over.

    func shader(_ type: UInt32, _ source: String) -> UInt32 {
        let shader = name()
        send(Op.createShader, .u(shader), .u(type))
        send(Op.shaderSource, .u(shader), .text(source))
        _ = ask(Op.compileShader, .u(shader))
        return shader
    }

    /// A program of the two shaders named `source`, linked and in use.
    @discardableResult
    func program(_ source: String, file: StaticString = #filePath, line: UInt = #line) -> UInt32 {
        let program = name()
        send(Op.createProgram, .u(program))
        send(Op.attachShader, .u(program), .u(shader(GL.VERTEX_SHADER, source)))
        send(Op.attachShader, .u(program), .u(shader(GL.FRAGMENT_SHADER, source)))
        var answer = ask(Op.linkProgram, .u(program))
        let linked = answer.word(), log = answer.text()
        XCTAssertEqual(linked, 1, "the program links: \(log)", file: file, line: line)
        send(Op.useProgram, .u(program))
        return program
    }

    @discardableResult
    func buffer(_ target: UInt32 = GL.ARRAY_BUFFER, _ data: Data) -> UInt32 {
        let buffer = name()
        send(Op.bindBuffer, .u(target), .u(buffer))
        send(Op.bufferData, .u(target), .i(data.count), .u(GL.STATIC_DRAW), .data(data))
        return buffer
    }

    /// An array of `size` floats a vertex for attribute `index`, from a new buffer.
    @discardableResult
    func array(_ index: UInt32, size: Int, _ values: [Float]) -> UInt32 {
        let buffer = buffer(GL.ARRAY_BUFFER, bytes(values))
        send(Op.vertexAttribPointer, .u(index), .i(size), .u(GL.FLOAT), 0, 0, 0)
        send(Op.enableVertexAttribArray, .u(index))
        return buffer
    }

    static let whole: [Float] = [-1, -1, 1, -1, -1, 1, 1, 1]

    /// A rectangle from (x0, y0) to (x1, y1) in OpenGL's -1…1, at depth z, in one colour, with the program "flat" (which is to be in use).
    func rectangle(_ x0: Float = -1, _ y0: Float = -1, _ x1: Float = 1, _ y1: Float = 1, z: Float = 0, color: [Float], clockwise: Bool = false) {
        var corners: [Float] = [x0, y0, z, x1, y0, z, x0, y1, z, x1, y1, z]
        if clockwise { corners = [x0, y0, z, x0, y1, z, x1, y0, z, x1, y1, z] }
        let buffer = array(0, size: 3, corners)
        send(Op.uniform4f, 0, .f(color[0]), .f(color[1]), .f(color[2]), .f(color[3]))
        send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        send(Op.deleteBuffers, 1, .names([buffer]))
    }

    /// A texture of width × height, bound, with these pixels, read as it lies (no smoothing, no repeating).
    @discardableResult
    func texture(width: Int, height: Int, format: UInt32 = GL.RGBA, type: UInt32 = GL.UNSIGNED_BYTE, _ pixels: Data?) -> UInt32 {
        let texture = name()
        send(Op.bindTexture, .u(GL.TEXTURE_2D), .u(texture))
        send(Op.texImage2D, .u(GL.TEXTURE_2D), 0, .u(format), .i(width), .i(height), 0, .u(format), .u(type), .data(pixels))
        for (parameter, value) in [(GL.TEXTURE_MIN_FILTER, GL.NEAREST), (GL.TEXTURE_MAG_FILTER, GL.NEAREST),
                                   (GL.TEXTURE_WRAP_S, GL.CLAMP_TO_EDGE), (GL.TEXTURE_WRAP_T, GL.CLAMP_TO_EDGE)] {
            send(Op.texParameteri, .u(GL.TEXTURE_2D), .u(parameter), .u(value))
        }
        return texture
    }

    /// Draws the bound texture over everything with the program "texture" (which is to be in use); `repeats` of it each way.
    func textured(repeats: Float = 1) {
        let positions = array(0, size: 2, Self.whole)
        let coordinates = array(1, size: 2, [0, 0, repeats, 0, 0, repeats, repeats, repeats])
        send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        send(Op.deleteBuffers, 2, .names([positions, coordinates]))
        send(Op.disableVertexAttribArray, 1)
    }

    /// glReadPixels: the pixels as rows from the bottom, each [r, g, b, a].
    func read(_ x: Int = 0, _ y: Int = 0, _ width: Int = 16, _ height: Int = 16, file: StaticString = #filePath, line: UInt = #line) -> [[[UInt8]]] {
        var answer = ask(Op.readPixels, .i(x), .i(y), .i(width), .i(height), .u(GL.RGBA), .u(GL.UNSIGNED_BYTE), file: file, line: line)
        let pixels = [UInt8](answer.data())
        guard pixels.count == width * height * 4 else {
            XCTFail("\(pixels.count) bytes for \(width) × \(height) pixels", file: file, line: line)
            return [[[UInt8]]](repeating: [[UInt8]](repeating: [0, 0, 0, 0], count: width), count: height)
        }
        return (0..<height).map { row in (0..<width).map { Array(pixels[(row * width + $0) * 4..<(row * width + $0) * 4 + 4]) } }
    }

    /// The pixel at (x, y), counted from the bottom left as OpenGL counts.
    func pixel(_ x: Int, _ y: Int, file: StaticString = #filePath, line: UInt = #line) -> [UInt8] {
        read(x, y, 1, 1, file: file, line: line)[0][0]
    }

    /// Swaps surface 1 and gives the picture that was presented: rows from the top, each pixel [r, g, b, a].
    func swap(_ surface: UInt32 = 1, file: StaticString = #filePath, line: UInt = #line) -> [[[UInt8]]] {
        let before = presented.count
        _ = ask(Op.swap, .u(surface), file: file, line: line)
        XCTAssertEqual(lastAnswer, word(0), "a swap is answered with nothing", file: file, line: line)
        guard presented.count == before + 1, let shown = presented.last else {
            XCTFail("a swap presents one picture", file: file, line: line)
            return []
        }
        return Self.pixels(shown.picture)
    }

    static func pixels(_ picture: IOSurface) -> [[[UInt8]]] {
        picture.lock(options: .readOnly, seed: nil)
        defer { picture.unlock(options: .readOnly, seed: nil) }
        return (0..<picture.height).map { row in
            (0..<picture.width).map { column in
                let bgra = (picture.baseAddress + row * picture.bytesPerRow + column * 4).loadUnaligned(as: UInt32.self).littleEndian
                return [UInt8(bgra >> 16 & 0xff), UInt8(bgra >> 8 & 0xff), UInt8(bgra & 0xff), UInt8(bgra >> 24)]
            }
        }
    }

    /// One pixel of a picture as it lies in its memory now: [r, g, b, a], x from the left and y from the top.
    static func pixel(_ picture: IOSurface, _ x: Int, _ y: Int) -> [UInt8] {
        picture.lock(options: .readOnly, seed: nil)
        defer { picture.unlock(options: .readOnly, seed: nil) }
        guard x >= 0, y >= 0, x < picture.width, y < picture.height else { return [] }
        let bgra = (picture.baseAddress + y * picture.bytesPerRow + x * 4).loadUnaligned(as: UInt32.self).littleEndian
        return [UInt8(bgra >> 16 & 0xff), UInt8(bgra >> 8 & 0xff), UInt8(bgra & 0xff), UInt8(bgra >> 24)]
    }
}

private func assertNear(_ pixel: [UInt8], _ expected: [UInt8], _ tolerance: Int = 2, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard pixel.count == expected.count else { return XCTFail("\(pixel) is no pixel. \(message)", file: file, line: line) }
    for (got, want) in zip(pixel, expected) where abs(Int(got) - Int(want)) > tolerance {
        return XCTFail("\(pixel) is not \(expected). \(message)", file: file, line: line)
    }
}

private let red: [UInt8] = [255, 0, 0, 255], green: [UInt8] = [0, 255, 0, 255], blue: [UInt8] = [0, 0, 255, 255]
private let black: [UInt8] = [0, 0, 0, 255], white: [UInt8] = [255, 255, 255, 255], nothing: [UInt8] = [0, 0, 0, 0]

/// Every command of the header, each as the header says it is, in an
/// order a program could send them in: state set, a program made and its
/// uniforms given, a texture, buffers, three draws, a framebuffer read
/// from, and all of it let go again.
private let everyCommand: [(op: UInt32, arguments: [Arg])] = {
    var list: [(op: UInt32, arguments: [Arg])] = []
    func add(_ op: UInt32, _ arguments: Arg...) {
        list.append((op, arguments))
    }
    func ones(_ count: Int) -> Arg { .floats([Float](repeating: 1, count: count)) }
    func ints(_ count: Int) -> Arg { .ints([Int32](repeating: 1, count: count)) }
    let rgba = Arg.u(GL.RGBA), byte = Arg.u(GL.UNSIGNED_BYTE), flat = Arg.u(GL.TEXTURE_2D), strip = Arg.u(GL.TRIANGLE_STRIP)
    let array = Arg.u(GL.ARRAY_BUFFER), elements = Arg.u(GL.ELEMENT_ARRAY_BUFFER), still = Arg.u(GL.STATIC_DRAW)
    let framebuffer = Arg.u(GL.FRAMEBUFFER), renderbuffer = Arg.u(GL.RENDERBUFFER), color = Arg.u(GL.COLOR_ATTACHMENT0)
    let front = Arg.u(GL.FRONT), keep = Arg.u(GL.KEEP), always = Arg.u(GL.ALWAYS), plus = Arg.u(GL.FUNC_ADD)

    add(Op.contextCreate, 1, 0)
    add(Op.surfaceCreate, 1, 8, 8, 1, 1, 1)
    add(Op.makeCurrent, 1, 1, 1)
    add(Op.surfaceResize, 1, 16, 16)
    add(Op.viewport, 0, 0, 16, 16)
    add(Op.scissor, 0, 0, 16, 16)
    add(Op.enable, .u(GL.SCISSOR_TEST))
    add(Op.disable, .u(GL.SCISSOR_TEST))
    add(Op.clearColor, 0.0, 0.0, 0.0, 1.0)
    add(Op.clearDepthf, 1.0)
    add(Op.clearStencil, 0)
    add(Op.colorMask, 1, 1, 1, 1)
    add(Op.depthMask, 1)
    add(Op.depthFunc, .u(GL.LEQUAL))
    add(Op.depthRangef, 0.0, 1.0)
    add(Op.cullFace, .u(GL.BACK))
    add(Op.frontFace, .u(GL.CCW))
    add(Op.lineWidth, 1.0)
    add(Op.polygonOffset, 1.0, 1.0)
    add(Op.sampleCoverage, 1.0, 0)
    add(Op.blendColor, 0.0, 0.0, 0.0, 0.0)
    add(Op.blendEquation, plus)
    add(Op.blendEquationSeparate, plus, .u(GL.FUNC_SUBTRACT))
    add(Op.blendFunc, .u(GL.SRC_ALPHA), .u(GL.ONE_MINUS_SRC_ALPHA))
    add(Op.blendFuncSeparate, .u(GL.ONE), .u(GL.ZERO), .u(GL.ONE), .u(GL.ZERO))
    add(Op.stencilFunc, always, 0, 0xff)
    add(Op.stencilFuncSeparate, front, always, 0, 0xff)
    add(Op.stencilMask, 0xff)
    add(Op.stencilMaskSeparate, front, 0xff)
    add(Op.stencilOp, keep, keep, keep)
    add(Op.stencilOpSeparate, front, keep, keep, keep)
    add(Op.clear, .u(GL.COLOR_BUFFER_BIT | GL.DEPTH_BUFFER_BIT | GL.STENCIL_BUFFER_BIT))

    // The program "uniforms": a uniform of every type, at the locations Programs.uniforms gives them.
    add(Op.createShader, 10, .u(GL.VERTEX_SHADER))
    add(Op.createShader, 11, .u(GL.FRAGMENT_SHADER))
    add(Op.shaderSource, 10, .text("uniforms"))
    add(Op.shaderSource, 11, .text("uniforms"))
    add(Op.compileShader, 10)
    add(Op.compileShader, 11)
    add(Op.createProgram, 12)
    add(Op.attachShader, 12, 10)
    add(Op.attachShader, 12, 11)
    add(Op.bindAttribLocation, 12, 0, .text("position"))
    add(Op.linkProgram, 12)
    add(Op.useProgram, 12)
    add(Op.uniform1f, 0, 1.0)
    add(Op.uniform2f, 2, 1.0, 1.0)
    add(Op.uniform3f, 3, 1.0, 1.0, 1.0)
    add(Op.uniform4f, 4, 1.0, 1.0, 1.0, 1.0)
    // The int that picks what the fragment shader gives: 2 is the vec4 just set.
    add(Op.uniform1i, 1, 2)
    add(Op.uniform2i, 6, 1, 1)
    add(Op.uniform3i, 7, 1, 1, 1)
    add(Op.uniform4i, 8, 1, 1, 1, 1)
    add(Op.uniform1fv, 0, 1, ones(1))
    add(Op.uniform2fv, 2, 1, ones(2))
    add(Op.uniform3fv, 3, 1, ones(3))
    add(Op.uniform4fv, 16, 3, ones(12))
    add(Op.uniform1iv, 5, 1, ints(1))
    add(Op.uniform2iv, 6, 1, ints(2))
    add(Op.uniform3iv, 7, 1, ints(3))
    add(Op.uniform4iv, 8, 1, ints(4))
    add(Op.uniformMatrix2fv, 13, 1, ones(4))
    add(Op.uniformMatrix3fv, 14, 1, ones(9))
    add(Op.uniformMatrix4fv, 15, 1, ones(16))
    add(Op.getUniform, 12, 4)

    add(Op.activeTexture, .u(GL.TEXTURE0))
    add(Op.bindTexture, flat, 20)
    add(Op.texImage2D, flat, 0, rgba, 4, 4, 0, rgba, byte, .data(Data(count: 64)))
    add(Op.texSubImage2D, flat, 0, 1, 1, 2, 2, rgba, byte, .data(Data(count: 16)))
    add(Op.texParameteri, flat, .u(GL.TEXTURE_MIN_FILTER), .u(GL.NEAREST))
    add(Op.texParameterf, flat, .u(GL.TEXTURE_MAG_FILTER), .f(Float(GL.NEAREST)))
    add(Op.generateMipmap, flat)
    add(Op.copyTexImage2D, flat, 0, rgba, 0, 0, 4, 4, 0)
    add(Op.copyTexSubImage2D, flat, 0, 0, 0, 0, 0, 2, 2)

    add(Op.bindBuffer, array, 30)
    add(Op.bufferData, array, 32, still, .data(nil))
    add(Op.bufferSubData, array, 0, .floats(Rig.whole))
    add(Op.vertexAttribPointer, 0, 2, .u(GL.FLOAT), 0, 0, 0)
    add(Op.enableVertexAttribArray, 0)
    add(Op.vertexAttrib4f, 1, 0.0, 0.0, 0.0, 1.0)
    add(Op.drawArrays, strip, 0, 4)
    add(Op.bindBuffer, elements, 31)
    add(Op.bufferData, elements, 8, still, .data(bytes([UInt16]([0, 1, 2, 3]))))
    add(Op.drawElements, strip, 4, .u(GL.UNSIGNED_SHORT), 0)
    add(Op.clientArray, 0, 2, .u(GL.FLOAT), 0, 0, .floats(Rig.whole))
    add(Op.drawElementsClient, strip, 4, .u(GL.UNSIGNED_BYTE), .data(Data([0, 1, 2, 3])))
    add(Op.disableVertexAttribArray, 0)

    add(Op.bindRenderbuffer, renderbuffer, 40)
    add(Op.renderbufferStorage, renderbuffer, .u(GL.RGBA4), 4, 4)
    add(Op.bindFramebuffer, framebuffer, 41)
    add(Op.framebufferRenderbuffer, framebuffer, color, renderbuffer, 40)
    add(Op.framebufferTexture2D, framebuffer, color, flat, 20, 0)
    add(Op.checkFramebufferStatus, framebuffer)
    add(Op.readPixels, 0, 0, 2, 2, rgba, byte)
    add(Op.finish)
    add(Op.getError)

    add(Op.detachShader, 12, 11)
    add(Op.deleteShader, 10)
    add(Op.deleteShader, 11)
    add(Op.deleteProgram, 12)
    add(Op.deleteBuffers, 2, .names([30, 31]))
    add(Op.deleteTextures, 1, .names([20]))
    add(Op.deleteRenderbuffers, 1, .names([40]))
    add(Op.deleteFramebuffers, 1, .names([41]))
    add(Op.swap, 1)
    add(Op.surfaceDestroy, 1)
    add(Op.contextDestroy, 1)
    return list
}()

final class GLStreamTests: XCTestCase {
    // MARK: Clearing and drawing

    /// glClear fills what is drawn to with the clear colour: glReadPixels
    /// reads it, and the picture a swap presents has it, as BGRA.
    func testAClearFillsThePictureWithTheClearColour() throws {
        let rig = try Rig()
        rig.send(Op.clearColor, 0.2, 0.4, 0.6, 1.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        XCTAssertEqual(rig.pixel(0, 0), [51, 102, 153, 255])
        XCTAssertEqual(rig.pixel(15, 15), [51, 102, 153, 255])
        let picture = rig.swap()
        XCTAssertEqual(picture.count, 16)
        XCTAssertEqual(picture[0][0], [51, 102, 153, 255])
        XCTAssertEqual(picture[15][15], [51, 102, 153, 255])
        XCTAssertEqual(rig.presented.last?.width, 16)
        XCTAssertEqual(rig.presented.last?.height, 16)
        rig.expectNoError()
    }

    /// A triangle whose corners have colours of their own, from a buffer:
    /// each corner of the picture has the colour of the corner drawn
    /// there. What is drawn low in OpenGL is in the first rows glReadPixels
    /// gives and in the last rows of the picture presented, which is
    /// upright.
    func testATriangleIsUprightInThePictureAndBottomFirstInReadPixels() throws {
        let rig = try Rig()
        rig.program("color")
        // Red at the bottom left, green at the bottom right, blue at the top.
        rig.buffer(GL.ARRAY_BUFFER, bytes([Float](
            [-1, -1, 1, 0, 0, 1,
             1, -1, 0, 1, 0, 1,
             0, 1, 0, 0, 1, 1])))
        rig.send(Op.vertexAttribPointer, 0, 2, .u(GL.FLOAT), 0, 24, 0)
        rig.send(Op.vertexAttribPointer, 1, 4, .u(GL.FLOAT), 0, 24, 8)
        rig.send(Op.enableVertexAttribArray, 0)
        rig.send(Op.enableVertexAttribArray, 1)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.send(Op.drawArrays, .u(GL.TRIANGLES), 0, 3)
        rig.expectNoError()
        let read = rig.read()
        XCTAssertGreaterThan(read[0][1][0], 200, "red low on the left: \(read[0][1])")
        XCTAssertGreaterThan(read[0][14][1], 200, "green low on the right: \(read[0][14])")
        XCTAssertGreaterThan(read[14][8][2], 200, "blue at the top: \(read[14][8])")
        XCTAssertEqual(read[15][0], nothing, "nothing beside the triangle's top")
        let picture = rig.swap()
        XCTAssertGreaterThan(picture[15][1][0], 200, "red in the last row, on the left: \(picture[15][1])")
        XCTAssertGreaterThan(picture[15][14][1], 200, "green in the last row, on the right: \(picture[15][14])")
        XCTAssertGreaterThan(picture[1][8][2], 200, "blue in the first rows: \(picture[1][8])")
        XCTAssertEqual(picture[0][0], nothing)
    }

    /// glDrawElements draws the vertices its indices name, of bytes, of
    /// shorts and of ints, from where in the index buffer it says.
    func testIndexedDrawingDrawsTheVerticesTheIndicesName() throws {
        for (type, each) in [(GL.UNSIGNED_BYTE, 1), (GL.UNSIGNED_SHORT, 2), (GL.UNSIGNED_INT, 4)] {
            let rig = try Rig()
            rig.program("flat")
            rig.send(Op.uniform4f, 0, 1.0, 0.0, 0.0, 1.0)
            // Four corners of the left half, then four of the right half.
            rig.array(0, size: 2, [-1, -1, 0, -1, -1, 1, 0, 1, 0, -1, 1, -1, 0, 1, 1, 1])
            let indices: [UInt32] = [0, 1, 2, 2, 1, 3, 4, 5, 6, 6, 5, 7]
            var data = Data()
            for index in indices {
                data.append(word(index).prefix(each))
            }
            rig.buffer(GL.ELEMENT_ARRAY_BUFFER, data)
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            // The second six: the right half alone.
            rig.send(Op.drawElements, .u(GL.TRIANGLES), 6, .u(type), .i(6 * each))
            rig.expectNoError()
            XCTAssertEqual(rig.pixel(12, 8), red, "indices of \(each) bytes")
            XCTAssertEqual(rig.pixel(3, 8), nothing, "indices of \(each) bytes")
            rig.send(Op.drawElements, .u(GL.TRIANGLES), 6, .u(type), 0)
            XCTAssertEqual(rig.pixel(3, 8), red, "indices of \(each) bytes")
            // The same indices again, which are not read again; and after the buffer changed, which are.
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            rig.send(Op.drawElements, .u(GL.TRIANGLES), 6, .u(type), 0)
            XCTAssertEqual(rig.pixel(3, 8), red, "indices of \(each) bytes, drawn again")
            rig.send(Op.bufferSubData, .u(GL.ELEMENT_ARRAY_BUFFER), 0, .data(data.suffix(6 * each)))
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            rig.send(Op.drawElements, .u(GL.TRIANGLES), 6, .u(type), 0)
            rig.expectNoError()
            XCTAssertEqual(rig.pixel(3, 8), nothing, "indices of \(each) bytes, after they changed")
            XCTAssertEqual(rig.pixel(12, 8), red, "indices of \(each) bytes, after they changed")
        }
    }

    /// A vertex numbered 65535 is a vertex like any other in OpenGL ES 2.0,
    /// which Metal would take for "the strip starts anew".
    func testAnIndexOfAllOnesIsAVertex() throws {
        let rig = try Rig()
        rig.program("flat")
        rig.send(Op.uniform4f, 0, 0.0, 1.0, 0.0, 1.0)
        // 65536 vertices, all but the last four at one point; the last four are the corners.
        var vertices = [Float](repeating: -1, count: 65536 * 2)
        vertices.replaceSubrange((65532 * 2)..., with: Rig.whole)
        rig.array(0, size: 2, vertices)
        rig.buffer(GL.ELEMENT_ARRAY_BUFFER, bytes([UInt16]([65532, 65533, 65534, 65535])))
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.send(Op.drawElements, .u(GL.TRIANGLE_STRIP), 4, .u(GL.UNSIGNED_SHORT), 0)
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(12, 12), green, "the triangle whose corner is vertex 65535")
        XCTAssertEqual(rig.pixel(3, 3), green)
    }

    /// A triangle fan and a line loop, which Metal has not, are drawn as
    /// OpenGL draws them: the fan's triangles all share its first vertex,
    /// the loop's last vertex is joined to its first.
    func testATriangleFanAndALineLoopAreDrawn() throws {
        let rig = try Rig()
        rig.program("flat")
        rig.send(Op.uniform4f, 0, 1.0, 0.0, 0.0, 1.0)
        // A fan around the middle of the left edge: the four corners in turn. It covers everything.
        rig.array(0, size: 2, [-1, 0, -1, -1, 1, -1, 1, 1, -1, 1])
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_FAN), 0, 5)
        rig.expectNoError()
        for (x, y) in [(1, 1), (14, 1), (14, 14), (1, 14), (8, 8)] {
            XCTAssertEqual(rig.pixel(x, y), red, "the fan covers (\(x), \(y))")
        }
        // The same fan through indices, of the first four vertices only: the top left stays empty.
        rig.buffer(GL.ELEMENT_ARRAY_BUFFER, bytes([UInt16]([0, 1, 2, 3])))
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.send(Op.drawElements, .u(GL.TRIANGLE_FAN), 4, .u(GL.UNSIGNED_SHORT), 0)
        XCTAssertEqual(rig.pixel(12, 3), red)
        XCTAssertEqual(rig.pixel(2, 13), nothing, "no triangle of four vertices' fan reaches the top left")

        // A loop round the picture, half a pixel in, so that each line lies in the middle of a row or column of pixels.
        let edge: Float = 1 - 1 / 16
        rig.array(0, size: 2, [-edge, -edge, edge, -edge, edge, edge, -edge, edge])
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.send(Op.drawArrays, .u(GL.LINE_LOOP), 0, 4)
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 0), red, "the bottom line")
        XCTAssertEqual(rig.pixel(15, 8), red, "the right line")
        XCTAssertEqual(rig.pixel(8, 15), red, "the top line")
        XCTAssertEqual(rig.pixel(0, 8), red, "the line that closes the loop")
        XCTAssertEqual(rig.pixel(8, 8), nothing, "nothing inside it")
    }

    /// Points and lines are drawn where OpenGL puts them.
    func testPointsAndLinesAreDrawn() throws {
        let rig = try Rig()
        rig.program("flat")
        rig.send(Op.uniform4f, 0, 0.0, 0.0, 1.0, 1.0)
        // The middles of the pixels (2, 3) and (12, 9).
        rig.array(0, size: 2, [(2.5 / 8) - 1, (3.5 / 8) - 1, (12.5 / 8) - 1, (9.5 / 8) - 1])
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.send(Op.drawArrays, .u(GL.POINTS), 0, 2)
        XCTAssertEqual(rig.pixel(2, 3), blue)
        XCTAssertEqual(rig.pixel(12, 9), blue)
        XCTAssertEqual(rig.pixel(3, 3), nothing)
        // A line along the middle of row 5.
        rig.array(0, size: 2, [-1, (5.5 / 8) - 1, 1, (5.5 / 8) - 1, -1, 1, 1, 1])
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.send(Op.drawArrays, .u(GL.LINES), 0, 2)
        XCTAssertEqual(rig.pixel(8, 5), blue)
        XCTAssertEqual(rig.pixel(8, 6), nothing)
        rig.send(Op.drawArrays, .u(GL.LINE_STRIP), 0, 3)
        rig.expectNoError()
    }

    /// Arrays in the program's own memory come with the draw (ClientArray)
    /// and hold for that draw alone; so do indices (DrawElementsClient).
    func testArraysAndIndicesThatComeWithTheDrawAreDrawn() throws {
        let rig = try Rig()
        rig.program("color")
        rig.send(Op.enableVertexAttribArray, 0)
        rig.send(Op.enableVertexAttribArray, 1)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        // Positions as floats, colours as bytes to be normalised: three bytes a vertex, which is no multiple of four.
        rig.send(Op.clientArray, 0, 2, .u(GL.FLOAT), 0, 0, .floats(Rig.whole))
        rig.send(Op.clientArray, 1, 3, .u(GL.UNSIGNED_BYTE), 1, 0, .data(Data([255, 128, 0, 255, 128, 0, 255, 128, 0, 255, 128, 0])))
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        rig.expectNoError()
        assertNear(rig.pixel(8, 8), [255, 128, 0, 255])

        // The arrays held for that draw: the next one has none, and an enabled array with nothing behind it draws nothing.
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
        XCTAssertEqual(rig.pixel(8, 8), nothing)

        // Indices with the draw; the arrays begin at vertex 2, as the library sends no more than the draw uses.
        rig.send(Op.clientArray, 0, 2, .u(GL.FLOAT), 0, 2, .floats(Rig.whole))
        rig.send(Op.clientArray, 1, 4, .u(GL.FLOAT), 0, 2, .floats([0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1]))
        rig.send(Op.drawElementsClient, .u(GL.TRIANGLES), 6, .u(GL.UNSIGNED_BYTE), .data(Data([2, 3, 4, 4, 3, 5])))
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), green)
        // GL_FIXED with the draw: sixteen bits after the point.
        rig.send(Op.clientArray, 0, 2, .u(GL.FIXED), 0, 0, .ints(Rig.whole.map { Int32($0 * 65536) }))
        rig.send(Op.clientArray, 1, 4, .u(GL.FIXED), 0, 0, .ints([Int32](repeating: 65536, count: 16)))
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), white)

        // Arrays that do not cover the vertices drawn: nothing is drawn.
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.send(Op.clientArray, 0, 2, .u(GL.FLOAT), 0, 0, .floats(Rig.whole))
        rig.send(Op.clientArray, 1, 4, .u(GL.FLOAT), 0, 0, .floats([0, 1, 0, 1]))
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
        XCTAssertEqual(rig.pixel(8, 8), nothing)
    }

    /// Every type glVertexAttribPointer has reaches the shader as OpenGL
    /// says: normalised or as the number it is, GL_FIXED as sixteen bits
    /// after the point, and with strides Metal would not take as they are.
    func testEveryVertexTypeReachesTheShader() throws {
        let rig = try Rig()
        rig.program("color")
        rig.array(0, size: 2, Rig.whole)
        rig.send(Op.enableVertexAttribArray, 1)
        func draw(_ data: Data, size: Int, type: UInt32, normalized: Bool, stride: Int, offset: Int = 0) -> [UInt8] {
            rig.buffer(GL.ARRAY_BUFFER, data)
            rig.send(Op.vertexAttribPointer, 1, .i(size), .u(type), normalized ? 1 : 0, .i(stride), .i(offset))
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
            rig.expectNoError()
            return rig.pixel(8, 8)
        }
        func four<T>(_ vertex: [T]) -> Data { bytes(vertex + vertex + vertex + vertex) }
        assertNear(draw(four([UInt8]([255, 0, 128, 255])), size: 4, type: GL.UNSIGNED_BYTE, normalized: true, stride: 0), [255, 0, 128, 255])
        assertNear(draw(four([UInt8]([1, 0, 1, 1])), size: 4, type: GL.UNSIGNED_BYTE, normalized: false, stride: 4), [255, 0, 255, 255])
        assertNear(draw(four([Int8]([127, 0, 64, 127])), size: 4, type: GL.BYTE, normalized: true, stride: 0), [255, 0, 128, 255], 3)
        assertNear(draw(four([UInt16]([65535, 32768, 0, 65535])), size: 4, type: GL.UNSIGNED_SHORT, normalized: true, stride: 0), [255, 128, 0, 255])
        assertNear(draw(four([Int16]([0, 32767, 0, 32767])), size: 4, type: GL.SHORT, normalized: true, stride: 0), [0, 255, 0, 255])
        assertNear(draw(four([Int16]([1, 0, 0, 1])), size: 4, type: GL.SHORT, normalized: false, stride: 8), [255, 0, 0, 255])
        assertNear(draw(four([Int32]([65536, 32768, 0, 65536])), size: 4, type: GL.FIXED, normalized: false, stride: 0), [255, 128, 0, 255])
        // Three numbers a vertex: the fourth is 1, as OpenGL fills it in.
        assertNear(draw(four([Float]([0, 0.5, 1])), size: 3, type: GL.FLOAT, normalized: false, stride: 0), [0, 128, 255, 255])
        // Three bytes a vertex and nothing between them; then five, starting at the second byte.
        assertNear(draw(four([UInt8]([0, 255, 255])), size: 3, type: GL.UNSIGNED_BYTE, normalized: true, stride: 3), [0, 255, 255, 255])
        assertNear(draw(Data([9]) + four([UInt8]([255, 255, 0, 9, 9])), size: 3, type: GL.UNSIGNED_BYTE, normalized: true, stride: 5, offset: 1), [255, 255, 0, 255])
        // Shorts that begin at an odd byte.
        assertNear(draw(Data([9]) + four([UInt16]([0, 65535, 0, 65535])), size: 4, type: GL.UNSIGNED_SHORT, normalized: true, stride: 8, offset: 1), [0, 255, 0, 255])
        // Vertices far apart: as far as Metal reads them where they lie, and farther, where it is given a copy.
        for stride in [2040, 2044, 4096] {
            var far = Data(count: stride * 3 + 4)
            for vertex in 0..<4 { far.replaceSubrange(vertex * stride..<vertex * stride + 4, with: [0, 0, 255, 255]) }
            assertNear(draw(far, size: 4, type: GL.UNSIGNED_BYTE, normalized: true, stride: stride), [0, 0, 255, 255], 2, "a stride of \(stride)")
        }
        // Not enabled: glVertexAttrib4f's value for every vertex.
        rig.send(Op.disableVertexAttribArray, 1)
        rig.send(Op.vertexAttrib4f, 1, 0.0, 0.0, 1.0, 1.0)
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        XCTAssertEqual(rig.pixel(8, 8), blue)
    }

    /// The last vertex of a buffer is drawn like any other: where its
    /// attribute lies in the second half of a stride that ends with the
    /// buffer, and where the buffer ends with the attribute and not with a
    /// whole stride, which OpenGL allows and Metal does not read.
    func testTheLastVertexOfABufferIsDrawn() throws {
        let rig = try Rig()
        rig.program("flat")
        rig.send(Op.uniform4f, 0, 1.0, 0.0, 0.0, 1.0)
        rig.send(Op.enableVertexAttribArray, 0)
        /// The middle of pixel (x, y).
        func middle(_ x: Float, _ y: Float) -> [Float] { [(x + 0.5) / 8 - 1, (y + 0.5) / 8 - 1] }
        // Two vertices of sixteen bytes, the position in the second half of each.
        rig.buffer(GL.ARRAY_BUFFER, bytes([Float]([9, 9] + middle(2, 2) + [9, 9] + middle(5, 9))))
        rig.send(Op.vertexAttribPointer, 0, 2, .u(GL.FLOAT), 0, 16, 8)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.send(Op.drawArrays, .u(GL.POINTS), 1, 1)
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(5, 9), red)
        XCTAssertEqual(rig.pixel(2, 2), nothing)
        // The position first, and the buffer cut off after the last one.
        rig.buffer(GL.ARRAY_BUFFER, bytes([Float](middle(2, 2) + [9, 9] + middle(12, 3))))
        rig.send(Op.vertexAttribPointer, 0, 2, .u(GL.FLOAT), 0, 16, 0)
        rig.send(Op.drawArrays, .u(GL.POINTS), 1, 1)
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(12, 3), red)
        // The same through an index.
        rig.buffer(GL.ELEMENT_ARRAY_BUFFER, bytes([UInt16]([1])))
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.send(Op.drawElements, .u(GL.POINTS), 1, .u(GL.UNSIGNED_SHORT), 0)
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(12, 3), red)
        XCTAssertEqual(rig.pixel(2, 2), nothing)
        // A position that begins past the first stride.
        rig.buffer(GL.ARRAY_BUFFER, bytes([Float]([9, 9, 9, 9, 9] + middle(7, 7) + [9, 9] + middle(1, 14))))
        rig.send(Op.vertexAttribPointer, 0, 2, .u(GL.FLOAT), 0, 16, 20)
        rig.send(Op.drawArrays, .u(GL.POINTS), 0, 2)
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(7, 7), red)
        XCTAssertEqual(rig.pixel(1, 14), red)
    }

    // MARK: Textures

    /// A texture drawn over everything shows its pixels where OpenGL puts
    /// them: the first row given is the bottom one. Each format a program
    /// may give them in is read as OpenGL says a sampler reads it.
    func testATextureOfEachFormatIsDrawnAsOpenGLReadsIt() throws {
        let rig = try Rig()
        rig.program("texture")
        // Two by two; the pixel at the bottom left is the one to tell apart, the others are told from it.
        let cases: [(String, UInt32, UInt32, Data, [UInt8], [UInt8])] = [
            ("RGBA bytes", GL.RGBA, GL.UNSIGNED_BYTE, Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 10, 20, 30, 40]), red, [10, 20, 30, 40]),
            ("RGB bytes", GL.RGB, GL.UNSIGNED_BYTE, Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 10, 20, 30]), red, [10, 20, 30, 255]),
            ("luminance", GL.LUMINANCE, GL.UNSIGNED_BYTE, Data([200, 0, 0, 50]), [200, 200, 200, 255], [50, 50, 50, 255]),
            ("luminance and alpha", GL.LUMINANCE_ALPHA, GL.UNSIGNED_BYTE, Data([200, 100, 0, 0, 0, 0, 50, 25]), [200, 200, 200, 100], [50, 50, 50, 25]),
            ("alpha", GL.ALPHA, GL.UNSIGNED_BYTE, Data([200, 0, 0, 50]), [0, 0, 0, 200], [0, 0, 0, 50]),
            ("565", GL.RGB, GL.UNSIGNED_SHORT_5_6_5, bytes([UInt16]([0xf800, 0, 0, 0x07ff])), red, [0, 255, 255, 255]),
            ("4444", GL.RGBA, GL.UNSIGNED_SHORT_4_4_4_4, bytes([UInt16]([0xf00f, 0, 0, 0x0f08])), red, [0, 255, 0, 136]),
            ("5551", GL.RGBA, GL.UNSIGNED_SHORT_5_5_5_1, bytes([UInt16]([0xf801, 0, 0, 0x003e])), red, [0, 0, 255, 0]),
        ]
        for (name, format, type, pixels, bottomLeft, topRight) in cases {
            rig.texture(width: 2, height: 2, format: format, type: type, pixels)
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            rig.textured()
            rig.expectNoError()
            XCTAssertEqual(rig.pixel(3, 3), bottomLeft, "\(name): the first pixel given is at the bottom left")
            XCTAssertEqual(rig.pixel(12, 12), topRight, "\(name): the last pixel given is at the top right")
        }
        // In the picture presented, the first row given is the last.
        rig.texture(width: 2, height: 2, cases[0].3)
        rig.textured()
        let picture = rig.swap()
        XCTAssertEqual(picture[12][3], red)
        XCTAssertEqual(picture[3][3], blue)
    }

    /// GL_NEAREST reads one pixel of a texture, GL_LINEAR mixes the ones
    /// around; GL_REPEAT, GL_MIRRORED_REPEAT and GL_CLAMP_TO_EDGE say what
    /// lies outside it.
    func testFiltersAndWrapsAreTheTexturesOwn() throws {
        let rig = try Rig()
        rig.program("texture")
        // Black on the left, white on the right.
        rig.texture(width: 2, height: 1, Data([0, 0, 0, 255, 255, 255, 255, 255]))
        rig.textured()
        XCTAssertEqual(rig.pixel(7, 8), black, "the nearest pixel, left of the middle")
        XCTAssertEqual(rig.pixel(8, 8), white, "the nearest pixel, right of the middle")
        rig.send(Op.texParameteri, .u(GL.TEXTURE_2D), .u(GL.TEXTURE_MAG_FILTER), .u(GL.LINEAR))
        rig.textured()
        assertNear(rig.pixel(7, 8), [112, 112, 112, 255], 4, "between the two, a mix of them")
        assertNear(rig.pixel(8, 8), [143, 143, 143, 255], 4)
        XCTAssertEqual(rig.pixel(0, 8), black, "at the edge, the edge's own")

        // Twice across. Repeated: black, white, black, white. Mirrored: black, white, white, black. Clamped: black, white, white, white.
        rig.send(Op.texParameteri, .u(GL.TEXTURE_2D), .u(GL.TEXTURE_MAG_FILTER), .u(GL.NEAREST))
        for (wrap, expected) in [(GL.REPEAT, [black, white, black, white]), (GL.MIRRORED_REPEAT, [black, white, white, black]),
                                 (GL.CLAMP_TO_EDGE, [black, white, white, white])] {
            rig.send(Op.texParameteri, .u(GL.TEXTURE_2D), .u(GL.TEXTURE_WRAP_S), .u(wrap))
            rig.textured(repeats: 2)
            XCTAssertEqual([2, 6, 10, 14].map { rig.pixel($0, 8) }, expected, "wrap \(String(wrap, radix: 16))")
        }
        rig.expectNoError()
    }

    /// A texture OpenGL calls incomplete is read as opaque black: one with
    /// no pixels, one that asks for smaller levels it has not. Sides that
    /// are no powers of two make it no less complete (GL_OES_texture_npot).
    func testAnIncompleteTextureIsReadAsOpaqueBlack() throws {
        let rig = try Rig()
        rig.program("texture")
        rig.send(Op.clearColor, 1.0, 1.0, 1.0, 1.0)
        func drawn() -> [UInt8] {
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            rig.textured()
            return rig.pixel(8, 8)
        }
        XCTAssertEqual(drawn(), black, "no texture bound: the context's own, which has no pixels")
        let texture = rig.name()
        rig.send(Op.bindTexture, .u(GL.TEXTURE_2D), .u(texture))
        rig.send(Op.texImage2D, .u(GL.TEXTURE_2D), 0, .u(GL.RGBA), 2, 2, 0, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE), .data(Data(repeating: 200, count: 16)))
        XCTAssertEqual(drawn(), black, "a new texture asks for smaller levels (GL_NEAREST_MIPMAP_LINEAR), and has none")
        rig.send(Op.texParameteri, .u(GL.TEXTURE_2D), .u(GL.TEXTURE_MIN_FILTER), .u(GL.LINEAR))
        XCTAssertEqual(drawn(), [200, 200, 200, 200], "asked for none, it is complete")
        rig.send(Op.texImage2D, .u(GL.TEXTURE_2D), 0, .u(GL.RGBA), 3, 2, 0, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE), .data(Data(repeating: 200, count: 24)))
        XCTAssertEqual(drawn(), [200, 200, 200, 200], "three pixels wide and repeating")
        rig.send(Op.texParameteri, .u(GL.TEXTURE_2D), .u(GL.TEXTURE_MIN_FILTER), .u(GL.LINEAR_MIPMAP_LINEAR))
        XCTAssertEqual(drawn(), black, "three pixels wide, asking for smaller levels it has not")
        rig.send(Op.generateMipmap, .u(GL.TEXTURE_2D))
        XCTAssertEqual(drawn(), [200, 200, 200, 200], "and having them")
        rig.expectNoError()
    }

    /// glTexSubImage2D replaces a part, and what was drawn before it shows
    /// what the texture was then: the pixels go to the GPU in the order
    /// of the calls.
    func testAPartOfATextureIsReplacedInTheOrderOfTheCalls() throws {
        let rig = try Rig()
        rig.program("texture")
        rig.texture(width: 2, height: 2, Data(repeating: 255, count: 16))
        // Drawn white on the left half, then the texture's first row turns red, then drawn on the right half.
        rig.send(Op.enable, .u(GL.SCISSOR_TEST))
        rig.send(Op.scissor, 0, 0, 8, 16)
        rig.textured()
        rig.send(Op.texSubImage2D, .u(GL.TEXTURE_2D), 0, 0, 0, 2, 1, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE), .data(Data([255, 0, 0, 255, 255, 0, 0, 255])))
        rig.send(Op.scissor, 8, 0, 8, 16)
        rig.textured()
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(3, 3), white, "drawn before the change")
        XCTAssertEqual(rig.pixel(12, 3), red, "drawn after it: the first row is the bottom one")
        XCTAssertEqual(rig.pixel(12, 12), white, "the row that was not replaced")
    }

    /// Smaller levels given one by one, in any order, make a texture that
    /// is read at the level its size on the screen asks for; so does
    /// glGenerateMipmap.
    func testSmallerLevelsAreGivenOrGenerated() throws {
        let rig = try Rig()
        rig.program("texture")
        let texture = rig.name()
        rig.send(Op.bindTexture, .u(GL.TEXTURE_2D), .u(texture))
        rig.send(Op.texParameteri, .u(GL.TEXTURE_2D), .u(GL.TEXTURE_MIN_FILTER), .u(GL.NEAREST_MIPMAP_NEAREST))
        func level(_ level: Int, _ side: Int, _ color: [UInt8]) {
            var pixels = Data()
            for _ in 0..<side * side { pixels.append(contentsOf: color) }
            rig.send(Op.texImage2D, .u(GL.TEXTURE_2D), .i(level), .u(GL.RGBA), .i(side), .i(side), 0, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE), .data(pixels))
        }
        // 64 pixels a side on 16: the level of 16 a side is the one read, which is level 2. The smallest come first.
        level(6, 1, white)
        level(5, 2, white)
        level(4, 4, white)
        level(3, 8, white)
        level(2, 16, green)
        level(1, 32, blue)
        rig.textured()
        XCTAssertEqual(rig.pixel(8, 8), black, "not complete until the first level is there")
        level(0, 64, red)
        rig.textured()
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), green, "the level whose pixels are the screen's size")
        // A level of the wrong size: incomplete again, and complete once it is put right.
        level(3, 4, white)
        rig.textured()
        XCTAssertEqual(rig.pixel(8, 8), black)
        level(3, 8, white)
        rig.textured()
        XCTAssertEqual(rig.pixel(8, 8), green)

        // Generated: every level is the first one made smaller, here all red.
        rig.send(Op.generateMipmap, .u(GL.TEXTURE_2D))
        rig.textured()
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), red)
        // There are none to generate of a depth texture, nor of a texture with no pixels.
        rig.texture(width: 4, height: 4, format: GL.DEPTH_COMPONENT, type: GL.UNSIGNED_SHORT, nil)
        rig.send(Op.generateMipmap, .u(GL.TEXTURE_2D))
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
        rig.send(Op.bindTexture, .u(GL.TEXTURE_2D), .u(rig.name()))
        rig.send(Op.generateMipmap, .u(GL.TEXTURE_2D))
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
    }

    /// A cube texture is read in the direction asked: each face has the pixels it was given.
    func testACubeTextureIsReadByDirection() throws {
        let rig = try Rig()
        rig.program("cube")
        let texture = rig.name()
        rig.send(Op.bindTexture, .u(GL.TEXTURE_CUBE_MAP), .u(texture))
        rig.send(Op.texParameteri, .u(GL.TEXTURE_CUBE_MAP), .u(GL.TEXTURE_MIN_FILTER), .u(GL.NEAREST))
        let colors: [[UInt8]] = [red, green, blue, white, [255, 255, 0, 255], [0, 255, 255, 255]]
        let directions: [[Float]] = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]
        func draw(_ direction: [Float]) -> [UInt8] {
            let positions = rig.array(0, size: 2, Rig.whole)
            let directions = rig.array(1, size: 3, direction + direction + direction + direction)
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
            rig.send(Op.deleteBuffers, 2, .names([positions, directions]))
            return rig.pixel(8, 8)
        }
        for face in 0..<5 {
            rig.send(Op.texImage2D, .u(GL.TEXTURE_CUBE_MAP_POSITIVE_X + UInt32(face)), 0, .u(GL.RGBA), 1, 1, 0, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE), .data(Data(colors[face])))
        }
        XCTAssertEqual(draw(directions[0]), black, "five faces are no cube")
        rig.send(Op.texImage2D, .u(GL.TEXTURE_CUBE_MAP_NEGATIVE_Z), 0, .u(GL.RGBA), 1, 1, 0, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE), .data(Data(colors[5])))
        for face in 0..<6 {
            XCTAssertEqual(draw(directions[face]), colors[face], "face \(face)")
        }
        // A face of another size: no cube. Width and height that differ: no face.
        rig.send(Op.texImage2D, .u(GL.TEXTURE_CUBE_MAP_POSITIVE_Y), 0, .u(GL.RGBA), 2, 2, 0, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE), .data(Data(count: 16)))
        XCTAssertEqual(draw(directions[0]), black)
        rig.expectNoError()
        rig.send(Op.texImage2D, .u(GL.TEXTURE_CUBE_MAP_POSITIVE_Y), 0, .u(GL.RGBA), 2, 1, 0, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE), .data(Data(count: 8)))
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE)
    }

    /// A face of a cube texture is drawn into through a framebuffer, and
    /// is then what is read in that face's direction; so are its smaller
    /// levels, once generated.
    func testAFaceOfACubeIsDrawnInto() throws {
        let rig = try Rig()
        let texture = rig.name()
        rig.send(Op.bindTexture, .u(GL.TEXTURE_CUBE_MAP), .u(texture))
        rig.send(Op.texParameteri, .u(GL.TEXTURE_CUBE_MAP), .u(GL.TEXTURE_MIN_FILTER), .u(GL.NEAREST))
        for face in 0..<6 {
            rig.send(Op.texImage2D, .u(GL.TEXTURE_CUBE_MAP_POSITIVE_X + UInt32(face)), 0, .u(GL.RGBA), 4, 4, 0, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE), .data(nil))
        }
        let framebuffer = rig.name()
        rig.send(Op.bindFramebuffer, .u(GL.FRAMEBUFFER), .u(framebuffer))
        rig.send(Op.framebufferTexture2D, .u(GL.FRAMEBUFFER), .u(GL.COLOR_ATTACHMENT0), .u(GL.TEXTURE_CUBE_MAP_NEGATIVE_Y), .u(texture), 0)
        var status = rig.ask(Op.checkFramebufferStatus, .u(GL.FRAMEBUFFER))
        XCTAssertEqual(status.word(), GL.FRAMEBUFFER_COMPLETE)
        rig.program("flat")
        rig.send(Op.viewport, 0, 0, 4, 4)
        rig.rectangle(color: [0, 1, 0, 1])
        rig.send(Op.framebufferTexture2D, .u(GL.FRAMEBUFFER), .u(GL.COLOR_ATTACHMENT0), .u(GL.TEXTURE_2D), .u(texture), 0)
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION, "a cube is attached by a face")
        rig.send(Op.bindFramebuffer, .u(GL.FRAMEBUFFER), 0)
        rig.send(Op.viewport, 0, 0, 16, 16)
        rig.program("cube")
        func read(_ direction: [Float]) -> [UInt8] {
            let positions = rig.array(0, size: 2, Rig.whole)
            let directions = rig.array(1, size: 3, direction + direction + direction + direction)
            rig.send(Op.clearColor, 1.0, 1.0, 1.0, 1.0)
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
            rig.send(Op.deleteBuffers, 2, .names([positions, directions]))
            return rig.pixel(8, 8)
        }
        XCTAssertEqual(read([0, -1, 0]), green, "the face drawn into")
        XCTAssertEqual(read([0, 1, 0]), nothing, "a face given no pixels has none")
        rig.send(Op.texParameteri, .u(GL.TEXTURE_CUBE_MAP), .u(GL.TEXTURE_MIN_FILTER), .u(GL.NEAREST_MIPMAP_NEAREST))
        XCTAssertEqual(read([0, -1, 0]), black, "asked for smaller levels, it has none")
        rig.send(Op.generateMipmap, .u(GL.TEXTURE_CUBE_MAP))
        XCTAssertEqual(read([0, -1, 0]), green)
        rig.expectNoError()
    }

    /// A sampler uniform says which texture unit is read (glUniform1i).
    func testASamplerReadsTheUnitItsUniformNames() throws {
        let rig = try Rig()
        rig.program("texture")
        rig.texture(width: 1, height: 1, Data(red))
        rig.send(Op.activeTexture, .u(GL.TEXTURE0 + 5))
        rig.texture(width: 1, height: 1, Data(green))
        rig.textured()
        XCTAssertEqual(rig.pixel(8, 8), red, "unit 0 until told otherwise")
        rig.send(Op.uniform1i, 0, 5)
        rig.textured()
        XCTAssertEqual(rig.pixel(8, 8), green)
        rig.expectNoError()
        rig.send(Op.uniform1i, 0, 32)
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE, "no such unit")
        rig.send(Op.uniform1f, 0, 1.0)
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION, "a sampler is set with glUniform1i")
    }

    /// glCopyTexImage2D and glCopyTexSubImage2D copy what was drawn into a
    /// texture, the bottom row to the bottom row, from a surface as from
    /// a texture.
    func testWhatWasDrawnIsCopiedIntoATexture() throws {
        let rig = try Rig()
        rig.program("flat")
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.rectangle(-1, -1, 1, 0, color: [1, 0, 0, 1])
        rig.rectangle(-1, 0, 1, 1, color: [0, 0, 1, 1])
        // The bottom-left quarter and the top-left quarter of the surface, side by side.
        let texture = rig.name()
        rig.send(Op.bindTexture, .u(GL.TEXTURE_2D), .u(texture))
        rig.send(Op.texParameteri, .u(GL.TEXTURE_2D), .u(GL.TEXTURE_MIN_FILTER), .u(GL.NEAREST))
        rig.send(Op.copyTexImage2D, .u(GL.TEXTURE_2D), 0, .u(GL.RGB), 0, 4, 16, 8, 0)
        rig.send(Op.copyTexSubImage2D, .u(GL.TEXTURE_2D), 0, 8, 4, 0, 0, 8, 4)
        rig.expectNoError()
        rig.program("texture")
        rig.send(Op.clearColor, 1.0, 1.0, 1.0, 1.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.textured()
        // The texture is 16 × 8: rows 4…11 of the surface, so red below and blue above; then its top right quarter became
        // the surface's bottom left, which is red.
        XCTAssertEqual(rig.pixel(3, 2), red, "the surface's row 4 is the texture's bottom row")
        XCTAssertEqual(rig.pixel(3, 13), blue)
        XCTAssertEqual(rig.pixel(12, 2), red)
        XCTAssertEqual(rig.pixel(12, 13), red, "the part copied afterwards")
        // A texture with alpha cannot be copied from what has none.
        let target = rig.texture(width: 4, height: 4, format: GL.RGB, nil)
        let framebuffer = rig.name()
        rig.send(Op.bindFramebuffer, .u(GL.FRAMEBUFFER), .u(framebuffer))
        rig.send(Op.framebufferTexture2D, .u(GL.FRAMEBUFFER), .u(GL.COLOR_ATTACHMENT0), .u(GL.TEXTURE_2D), .u(target), 0)
        rig.send(Op.bindTexture, .u(GL.TEXTURE_2D), .u(texture))
        rig.send(Op.copyTexImage2D, .u(GL.TEXTURE_2D), 0, .u(GL.RGBA), 0, 0, 4, 4, 0)
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
        rig.send(Op.copyTexImage2D, .u(GL.TEXTURE_2D), 0, .u(GL.LUMINANCE), 0, 0, 4, 4, 0)
        rig.expectNoError()
    }

    // MARK: Framebuffers

    /// What is drawn into a texture through a framebuffer is in the
    /// texture the way OpenGL has it (low is the first row), and drawing
    /// with that texture then shows it the same way up.
    func testDrawingIntoATextureAndThenWithIt() throws {
        let rig = try Rig()
        rig.program("flat")
        let target = rig.texture(width: 16, height: 16, nil)
        let framebuffer = rig.name()
        rig.send(Op.bindFramebuffer, .u(GL.FRAMEBUFFER), .u(framebuffer))
        rig.send(Op.framebufferTexture2D, .u(GL.FRAMEBUFFER), .u(GL.COLOR_ATTACHMENT0), .u(GL.TEXTURE_2D), .u(target), 0)
        var status = rig.ask(Op.checkFramebufferStatus, .u(GL.FRAMEBUFFER))
        XCTAssertEqual(status.word(), GL.FRAMEBUFFER_COMPLETE)
        XCTAssertEqual(rig.pixel(8, 8), nothing, "a texture given no pixels has none of anything else's")
        rig.send(Op.clearColor, 0.0, 0.0, 1.0, 1.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.rectangle(-1, -1, 1, 0, color: [1, 0, 0, 1])
        rig.expectNoError()
        let inTexture = rig.read()
        XCTAssertEqual(inTexture[3][8], red, "low in OpenGL is the first rows of what glReadPixels gives")
        XCTAssertEqual(inTexture[12][8], blue)

        rig.send(Op.bindFramebuffer, .u(GL.FRAMEBUFFER), 0)
        rig.program("texture")
        rig.send(Op.clearColor, 0.0, 0.0, 0.0, 0.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.textured()
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 3), red, "what was drawn low is low")
        XCTAssertEqual(rig.pixel(8, 12), blue)
        let picture = rig.swap()
        XCTAssertEqual(picture[12][8], red, "and low in the picture presented")
        XCTAssertEqual(picture[3][8], blue)
    }

    /// glCheckFramebufferStatus says what OpenGL says of what is attached.
    func testFramebufferStatusFollowsTheCompletenessRules() throws {
        let rig = try Rig()
        func status() -> UInt32 {
            var answer = rig.ask(Op.checkFramebufferStatus, .u(GL.FRAMEBUFFER))
            return answer.word()
        }
        XCTAssertEqual(status(), GL.FRAMEBUFFER_COMPLETE, "a window's surface")
        let framebuffer = rig.name()
        rig.send(Op.bindFramebuffer, .u(GL.FRAMEBUFFER), .u(framebuffer))
        XCTAssertEqual(status(), GL.FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT, "nothing attached")
        func renderbuffer(_ format: UInt32, _ width: Int, _ height: Int) -> UInt32 {
            let renderbuffer = rig.name()
            rig.send(Op.bindRenderbuffer, .u(GL.RENDERBUFFER), .u(renderbuffer))
            rig.send(Op.renderbufferStorage, .u(GL.RENDERBUFFER), .u(format), .i(width), .i(height))
            return renderbuffer
        }
        func attach(_ attachment: UInt32, _ renderbuffer: UInt32) {
            rig.send(Op.framebufferRenderbuffer, .u(GL.FRAMEBUFFER), .u(attachment), .u(GL.RENDERBUFFER), .u(renderbuffer))
        }
        let color = renderbuffer(GL.RGB565, 8, 8)
        attach(GL.COLOR_ATTACHMENT0, color)
        XCTAssertEqual(status(), GL.FRAMEBUFFER_COMPLETE, "a colour renderbuffer")
        attach(GL.DEPTH_ATTACHMENT, renderbuffer(GL.DEPTH_COMPONENT16, 8, 8))
        attach(GL.STENCIL_ATTACHMENT, renderbuffer(GL.STENCIL_INDEX8, 8, 8))
        XCTAssertEqual(status(), GL.FRAMEBUFFER_COMPLETE, "with depth and stencil of their own")
        let packed = renderbuffer(GL.DEPTH24_STENCIL8_OES, 8, 8)
        attach(GL.DEPTH_ATTACHMENT, packed)
        XCTAssertEqual(status(), GL.FRAMEBUFFER_UNSUPPORTED, "depth of a packed renderbuffer with another's stencil")
        attach(GL.STENCIL_ATTACHMENT, packed)
        XCTAssertEqual(status(), GL.FRAMEBUFFER_COMPLETE, "depth and stencil of one packed renderbuffer")
        attach(GL.DEPTH_ATTACHMENT, renderbuffer(GL.DEPTH_COMPONENT24_OES, 8, 4))
        attach(GL.STENCIL_ATTACHMENT, 0)
        XCTAssertEqual(status(), GL.FRAMEBUFFER_INCOMPLETE_DIMENSIONS, "sizes that differ")
        attach(GL.DEPTH_ATTACHMENT, color)
        XCTAssertEqual(status(), GL.FRAMEBUFFER_INCOMPLETE_ATTACHMENT, "a colour where depth goes")
        attach(GL.DEPTH_ATTACHMENT, 0)
        attach(GL.COLOR_ATTACHMENT0, renderbuffer(GL.RGBA4, 0, 0))
        XCTAssertEqual(status(), GL.FRAMEBUFFER_INCOMPLETE_ATTACHMENT, "a renderbuffer of no size")
        // Textures: one of a format that can be drawn to, one that cannot, one with no pixels.
        func attach(texture: UInt32) {
            rig.send(Op.framebufferTexture2D, .u(GL.FRAMEBUFFER), .u(GL.COLOR_ATTACHMENT0), .u(GL.TEXTURE_2D), .u(texture), 0)
        }
        attach(texture: rig.texture(width: 4, height: 4, format: GL.RGB, type: GL.UNSIGNED_SHORT_5_6_5, nil))
        XCTAssertEqual(status(), GL.FRAMEBUFFER_COMPLETE)
        attach(texture: rig.texture(width: 4, height: 4, format: GL.LUMINANCE, nil))
        XCTAssertEqual(status(), GL.FRAMEBUFFER_INCOMPLETE_ATTACHMENT, "luminance is not drawn to")
        let empty = rig.name()
        rig.send(Op.bindTexture, .u(GL.TEXTURE_2D), .u(empty))
        attach(texture: empty)
        XCTAssertEqual(status(), GL.FRAMEBUFFER_INCOMPLETE_ATTACHMENT, "a texture with no pixels")
        rig.expectNoError()

        // Drawing to, clearing and reading what is not complete is OpenGL's own error.
        rig.program("flat")
        rig.rectangle(color: [1, 1, 1, 1])
        XCTAssertEqual(rig.error(), GL.INVALID_FRAMEBUFFER_OPERATION)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        XCTAssertEqual(rig.error(), GL.INVALID_FRAMEBUFFER_OPERATION)
        _ = rig.ask(Op.readPixels, 0, 0, 1, 1, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE))
        XCTAssertEqual(rig.lastAnswer, word(0))
        XCTAssertEqual(rig.error(), GL.INVALID_FRAMEBUFFER_OPERATION)
        // The texture deleted, the framebuffer bound has it attached no more.
        let doomed = rig.texture(width: 4, height: 4, nil)
        attach(texture: doomed)
        XCTAssertEqual(status(), GL.FRAMEBUFFER_COMPLETE)
        rig.send(Op.deleteTextures, 1, .names([doomed]))
        XCTAssertEqual(status(), GL.FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT)
        var wrong = rig.ask(Op.checkFramebufferStatus, .u(GL.RENDERBUFFER))
        XCTAssertEqual(wrong.word(), 0)
        XCTAssertEqual(rig.error(), GL.INVALID_ENUM)
        // The framebuffer deleted while bound: the surface is drawn to again.
        rig.send(Op.deleteFramebuffers, 1, .names([framebuffer]))
        XCTAssertEqual(status(), GL.FRAMEBUFFER_COMPLETE)
        rig.send(Op.framebufferRenderbuffer, .u(GL.FRAMEBUFFER), .u(GL.COLOR_ATTACHMENT0), .u(GL.RENDERBUFFER), .u(color))
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
    }

    /// A renderbuffer with no alpha (GL_RGB565) reads alpha 1 whatever is
    /// drawn, and a depth texture can be drawn to and then read by a sampler.
    func testRenderbuffersAndDepthTexturesAreDrawnTo() throws {
        let rig = try Rig()
        rig.program("flat")
        let framebuffer = rig.name(), color = rig.name()
        rig.send(Op.bindFramebuffer, .u(GL.FRAMEBUFFER), .u(framebuffer))
        rig.send(Op.bindRenderbuffer, .u(GL.RENDERBUFFER), .u(color))
        rig.send(Op.renderbufferStorage, .u(GL.RENDERBUFFER), .u(GL.RGB565), 16, 16)
        rig.send(Op.framebufferRenderbuffer, .u(GL.FRAMEBUFFER), .u(GL.COLOR_ATTACHMENT0), .u(GL.RENDERBUFFER), .u(color))
        XCTAssertEqual(rig.pixel(8, 8), black, "new, it is black, with the alpha a colour without alpha has")
        rig.send(Op.clearColor, 0.0, 1.0, 0.0, 0.25)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        XCTAssertEqual(rig.pixel(8, 8), green)
        rig.rectangle(color: [1, 0, 0, 0.5])
        XCTAssertEqual(rig.pixel(8, 8), red)

        // Depth drawn into a texture: 0.25 on the left (z -0.5), 0.75 on the right (z 0.5).
        let depth = rig.texture(width: 16, height: 16, format: GL.DEPTH_COMPONENT, type: GL.UNSIGNED_INT, nil)
        rig.send(Op.framebufferTexture2D, .u(GL.FRAMEBUFFER), .u(GL.DEPTH_ATTACHMENT), .u(GL.TEXTURE_2D), .u(depth), 0)
        var status = rig.ask(Op.checkFramebufferStatus, .u(GL.FRAMEBUFFER))
        XCTAssertEqual(status.word(), GL.FRAMEBUFFER_COMPLETE)
        rig.send(Op.enable, .u(GL.DEPTH_TEST))
        rig.send(Op.depthFunc, .u(GL.ALWAYS))
        rig.send(Op.clear, .u(GL.DEPTH_BUFFER_BIT))
        rig.rectangle(-1, -1, 0, 1, z: -0.5, color: [1, 1, 1, 1])
        rig.rectangle(0, -1, 1, 1, z: 0.5, color: [1, 1, 1, 1])
        rig.send(Op.disable, .u(GL.DEPTH_TEST))
        rig.send(Op.bindFramebuffer, .u(GL.FRAMEBUFFER), 0)
        rig.program("texture")
        rig.textured()
        rig.expectNoError()
        assertNear(rig.pixel(3, 8), [64, 64, 64, 255], 2, "a depth texture is read as luminance, as OES_depth_texture has it")
        assertNear(rig.pixel(12, 8), [191, 191, 191, 255], 2)

        // Depth given as pixels: sixteen bits, and twenty-four with eight of stencil.
        rig.texture(width: 1, height: 1, format: GL.DEPTH_COMPONENT, type: GL.UNSIGNED_SHORT, bytes([UInt16]([0x8000])))
        rig.textured()
        assertNear(rig.pixel(8, 8), [128, 128, 128, 255])
        rig.texture(width: 1, height: 1, format: GL.DEPTH_STENCIL_OES, type: GL.UNSIGNED_INT_24_8_OES, bytes([UInt32]([0x4000_00ff])))
        rig.textured()
        assertNear(rig.pixel(8, 8), [64, 64, 64, 255])
        rig.expectNoError()
        // A depth texture has one level.
        rig.send(Op.texImage2D, .u(GL.TEXTURE_2D), 1, .u(GL.DEPTH_COMPONENT), 1, 1, 0, .u(GL.DEPTH_COMPONENT), .u(GL.UNSIGNED_SHORT), .data(nil))
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
    }

    // MARK: The tests and the masks

    /// The depth test keeps what is nearer, and glDepthMask(false) draws
    /// without leaving its depth behind.
    func testTheDepthTestAndTheDepthMask() throws {
        let rig = try Rig()
        rig.program("flat")
        rig.send(Op.enable, .u(GL.DEPTH_TEST))
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT | GL.DEPTH_BUFFER_BIT))
        rig.rectangle(z: 0, color: [1, 0, 0, 1])
        rig.rectangle(z: 0.5, color: [0, 1, 0, 1])
        XCTAssertEqual(rig.pixel(8, 8), red, "what lies behind is not drawn")
        rig.send(Op.depthMask, 0)
        rig.rectangle(z: -0.5, color: [0, 1, 0, 1])
        XCTAssertEqual(rig.pixel(8, 8), green, "what lies in front is")
        rig.send(Op.depthMask, 1)
        rig.rectangle(z: -0.2, color: [0, 0, 1, 1])
        XCTAssertEqual(rig.pixel(8, 8), blue, "the masked draw left the depth as it was: behind it, in front of the first")
        rig.send(Op.depthFunc, .u(GL.GREATER))
        rig.rectangle(z: 0.9, color: [1, 1, 1, 1])
        XCTAssertEqual(rig.pixel(8, 8), white, "GL_GREATER keeps what is farther")
        // glDepthRangef squeezes the depths drawn: everything lands at 0.9…1, behind a clear to 0.5.
        rig.send(Op.depthFunc, .u(GL.LESS))
        rig.send(Op.clearDepthf, 0.5)
        rig.send(Op.clear, .u(GL.DEPTH_BUFFER_BIT))
        rig.send(Op.depthRangef, 0.9, 1.0)
        rig.rectangle(z: -1, color: [1, 0, 0, 1])
        XCTAssertEqual(rig.pixel(8, 8), white)
        // Polygon offset pulls a triangle towards the eye: drawn again at the same depth, it now passes GL_LESS.
        rig.send(Op.depthRangef, 0.0, 1.0)
        rig.send(Op.clearDepthf, 1.0)
        rig.send(Op.clear, .u(GL.DEPTH_BUFFER_BIT))
        rig.rectangle(z: 0, color: [1, 0, 0, 1])
        rig.rectangle(z: 0, color: [0, 1, 0, 1])
        XCTAssertEqual(rig.pixel(8, 8), red, "the same depth is not less")
        rig.send(Op.enable, .u(GL.POLYGON_OFFSET_FILL))
        rig.send(Op.polygonOffset, -1.0, -4.0)
        rig.rectangle(z: 0, color: [0, 1, 0, 1])
        XCTAssertEqual(rig.pixel(8, 8), green)
        rig.expectNoError()
    }

    /// The stencil test, with what it writes and what it compares, for
    /// both faces and for each alone.
    func testTheStencilTest() throws {
        let rig = try Rig()
        rig.program("flat")
        rig.send(Op.enable, .u(GL.STENCIL_TEST))
        rig.send(Op.clearStencil, 0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT | GL.STENCIL_BUFFER_BIT))
        // The left half's stencil becomes 1, with nothing of it seen.
        rig.send(Op.stencilFunc, .u(GL.ALWAYS), 1, 0xff)
        rig.send(Op.stencilOp, .u(GL.KEEP), .u(GL.KEEP), .u(GL.REPLACE))
        rig.send(Op.colorMask, 0, 0, 0, 0)
        rig.rectangle(-1, -1, 0, 1, color: [1, 1, 1, 1])
        rig.send(Op.colorMask, 1, 1, 1, 1)
        rig.send(Op.stencilOp, .u(GL.KEEP), .u(GL.KEEP), .u(GL.KEEP))
        rig.send(Op.stencilFunc, .u(GL.EQUAL), 1, 0xff)
        rig.rectangle(color: [1, 0, 0, 1])
        rig.send(Op.stencilFunc, .u(GL.NOTEQUAL), 1, 0xff)
        rig.rectangle(color: [0, 1, 0, 1])
        XCTAssertEqual(rig.pixel(3, 8), red, "where the stencil is 1")
        XCTAssertEqual(rig.pixel(12, 8), green, "where it is not")
        // The mask the comparison is made under: 1 and 3 are equal under 1.
        rig.send(Op.stencilFunc, .u(GL.EQUAL), 3, 1)
        rig.rectangle(color: [0, 0, 1, 1])
        XCTAssertEqual(rig.pixel(3, 8), blue)
        XCTAssertEqual(rig.pixel(12, 8), green)
        // The mask of what is written: with the low bit masked out, a replace by 3 leaves 1 as 3 and 0 as 2.
        rig.send(Op.stencilMask, 2)
        rig.send(Op.stencilFunc, .u(GL.ALWAYS), 3, 0xff)
        rig.send(Op.stencilOp, .u(GL.KEEP), .u(GL.KEEP), .u(GL.REPLACE))
        rig.rectangle(color: [0, 0, 0, 1])
        rig.send(Op.stencilMask, 0xff)
        rig.send(Op.stencilOp, .u(GL.KEEP), .u(GL.KEEP), .u(GL.KEEP))
        rig.send(Op.stencilFunc, .u(GL.EQUAL), 2, 0xff)
        rig.rectangle(color: [1, 1, 1, 1])
        XCTAssertEqual(rig.pixel(3, 8), black)
        XCTAssertEqual(rig.pixel(12, 8), white)
        // Each face its own: the front never passes, the back always.
        rig.send(Op.stencilFuncSeparate, .u(GL.FRONT), .u(GL.NEVER), 0, 0xff)
        rig.send(Op.stencilFuncSeparate, .u(GL.BACK), .u(GL.ALWAYS), 0, 0xff)
        rig.rectangle(color: [1, 0, 0, 1])
        XCTAssertEqual(rig.pixel(12, 8), white, "a triangle seen from the front")
        rig.rectangle(color: [1, 0, 0, 1], clockwise: true)
        XCTAssertEqual(rig.pixel(12, 8), red, "a triangle seen from the back")
        // A clear of the stencil under a mask is a clear of those bits.
        rig.send(Op.stencilMask, 1)
        rig.send(Op.clearStencil, 0xff)
        rig.send(Op.clear, .u(GL.STENCIL_BUFFER_BIT))
        rig.send(Op.stencilMask, 0xff)
        rig.send(Op.stencilFunc, .u(GL.EQUAL), 3, 0xff)
        rig.rectangle(color: [0, 0, 1, 1])
        XCTAssertEqual(rig.pixel(3, 8), blue, "3 stays 3, 2 becomes 3")
        XCTAssertEqual(rig.pixel(12, 8), blue)
        rig.expectNoError()
    }

    /// Blending mixes what is drawn with what is there, by the functions
    /// and the equation set.
    func testBlendingByAFewFunctionPairs() throws {
        let rig = try Rig()
        rig.program("flat")
        rig.send(Op.enable, .u(GL.BLEND))
        rig.send(Op.clearColor, 0.0, 0.0, 1.0, 1.0)
        rig.send(Op.blendColor, 0.5, 0.5, 0.5, 0.5)
        // Red of half alpha over opaque blue.
        let cases: [(UInt32, UInt32, UInt32, [UInt8])] = [
            (GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA, GL.FUNC_ADD, [128, 0, 128, 191]),
            (GL.ONE, GL.ONE, GL.FUNC_ADD, [255, 0, 255, 255]),
            (GL.DST_COLOR, GL.ZERO, GL.FUNC_ADD, [0, 0, 0, 128]),
            (GL.CONSTANT_COLOR, GL.ZERO, GL.FUNC_ADD, [128, 0, 0, 64]),
            (GL.ONE, GL.ONE_MINUS_CONSTANT_ALPHA, GL.FUNC_ADD, [255, 0, 128, 255]),
            (GL.ONE, GL.ONE, GL.FUNC_SUBTRACT, [255, 0, 0, 0]),
            (GL.ONE, GL.ONE, GL.FUNC_REVERSE_SUBTRACT, [0, 0, 255, 128]),
            (GL.ZERO, GL.SRC_COLOR, GL.FUNC_ADD, [0, 0, 0, 128]),
            (GL.SRC_ALPHA_SATURATE, GL.ONE, GL.FUNC_ADD, [0, 0, 255, 255]),
        ]
        for (source, destination, equation, expected) in cases {
            rig.send(Op.blendFunc, .u(source), .u(destination))
            rig.send(Op.blendEquation, .u(equation))
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            rig.rectangle(color: [1, 0, 0, 0.5])
            assertNear(rig.pixel(8, 8), expected, 2, "\(String(source, radix: 16)), \(String(destination, radix: 16)), \(String(equation, radix: 16))")
        }
        // Colour and alpha each their own way.
        rig.send(Op.blendFuncSeparate, .u(GL.ONE), .u(GL.ZERO), .u(GL.ZERO), .u(GL.ONE))
        rig.send(Op.blendEquationSeparate, .u(GL.FUNC_ADD), .u(GL.FUNC_ADD))
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.rectangle(color: [1, 0, 0, 0.5])
        assertNear(rig.pixel(8, 8), red)
        rig.expectNoError()
    }

    /// The scissor box bounds a clear and a draw, counted from the bottom
    /// left as OpenGL counts, in a surface and in a texture alike.
    func testTheScissorBoxBoundsClearsAndDraws() throws {
        let rig = try Rig()
        rig.program("flat")
        func check(_ inside: [UInt8], _ outside: [UInt8], _ what: String) {
            let read = rig.read()
            for (x, y) in [(4, 2), (11, 2), (4, 7), (11, 7)] { XCTAssertEqual(read[y][x], inside, "\(what): (\(x), \(y)) is inside") }
            for (x, y) in [(3, 2), (12, 7), (4, 1), (11, 8), (0, 0), (15, 15)] { XCTAssertEqual(read[y][x], outside, "\(what): (\(x), \(y)) is outside") }
        }
        for target in ["a surface", "a texture"] {
            if target == "a texture" {
                let texture = rig.texture(width: 16, height: 16, nil), framebuffer = rig.name()
                rig.send(Op.bindFramebuffer, .u(GL.FRAMEBUFFER), .u(framebuffer))
                rig.send(Op.framebufferTexture2D, .u(GL.FRAMEBUFFER), .u(GL.COLOR_ATTACHMENT0), .u(GL.TEXTURE_2D), .u(texture), 0)
            }
            rig.send(Op.disable, .u(GL.SCISSOR_TEST))
            rig.send(Op.clearColor, 0.0, 0.0, 0.0, 0.0)
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            rig.send(Op.enable, .u(GL.SCISSOR_TEST))
            rig.send(Op.scissor, 4, 2, 8, 6)
            rig.send(Op.clearColor, 1.0, 0.0, 0.0, 1.0)
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            check(red, nothing, "a clear in \(target)")
            rig.rectangle(color: [0, 1, 0, 1])
            check(green, nothing, "a draw in \(target)")
            // A box that reaches outside is cut to what is drawn to; one wholly outside leaves nothing to draw.
            rig.send(Op.scissor, -100, -100, 108, 104)
            rig.rectangle(color: [0, 0, 1, 1])
            XCTAssertEqual(rig.pixel(7, 3), blue)
            XCTAssertEqual(rig.pixel(8, 3), green)
            rig.send(Op.scissor, 100, 100, 5, 5)
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            rig.rectangle(color: [1, 1, 1, 1])
            XCTAssertEqual(rig.pixel(8, 3), green)
            rig.expectNoError()
        }
        rig.send(Op.bindFramebuffer, .u(GL.FRAMEBUFFER), 0)
        rig.send(Op.scissor, 4, 2, 8, 6)
        rig.send(Op.clearColor, 1.0, 1.0, 1.0, 1.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        let picture = rig.swap()
        XCTAssertEqual(picture[13][4], white, "row 2 from the bottom is row 13 from the top")
        XCTAssertEqual(picture[8][11], white)
        XCTAssertNotEqual(picture[14][4], white)
        XCTAssertNotEqual(picture[7][11], white)
    }

    /// The viewport places what is drawn: OpenGL's -1…1 is its rectangle.
    func testTheViewportPlacesWhatIsDrawn() throws {
        let rig = try Rig()
        rig.program("flat")
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.send(Op.viewport, 8, 0, 8, 4)
        rig.rectangle(color: [1, 0, 0, 1])
        let read = rig.read()
        XCTAssertEqual(read[0][8], red)
        XCTAssertEqual(read[3][15], red)
        XCTAssertEqual(read[4][8], nothing)
        XCTAssertEqual(read[0][7], nothing)
        XCTAssertEqual(rig.swap()[15][8], red, "low on the right, in the picture's last row")
        // A viewport that reaches outside what is drawn to shows the part of it that is inside.
        rig.send(Op.viewport, -8, -8, 32, 32)
        rig.rectangle(0, 0, 1, 1, color: [0, 1, 0, 1])
        XCTAssertEqual(rig.pixel(8, 8), green)
        XCTAssertEqual(rig.pixel(7, 7), nothing)
        rig.send(Op.viewport, 0, 0, -1, 4)
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE)
    }

    /// glColorMask keeps channels as they are, in a clear and in a draw.
    func testTheColourMaskKeepsChannels() throws {
        let rig = try Rig()
        rig.program("flat")
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.send(Op.colorMask, 1, 0, 1, 0)
        rig.send(Op.clearColor, 1.0, 1.0, 1.0, 1.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        XCTAssertEqual(rig.pixel(8, 8), [255, 0, 255, 0], "a clear of red and blue")
        rig.send(Op.colorMask, 0, 1, 0, 0)
        rig.rectangle(color: [0, 0.5, 0, 1])
        assertNear(rig.pixel(8, 8), [255, 128, 255, 0], 2, "a draw of green alone")
        rig.send(Op.colorMask, 0, 0, 0, 0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        assertNear(rig.pixel(8, 8), [255, 128, 255, 0], 2, "a clear of nothing")
        rig.expectNoError()
    }

    /// Culling drops the triangles seen from the side glCullFace names,
    /// which glFrontFace says how to tell; gl_FrontFacing agrees. In a
    /// surface as in a texture, where everything is drawn turned over.
    func testCullingKnowsFrontFromBackInASurfaceAndInATexture() throws {
        let rig = try Rig()
        for target in ["a surface", "a texture"] {
            if target == "a texture" {
                let texture = rig.texture(width: 16, height: 16, nil), framebuffer = rig.name()
                rig.send(Op.bindFramebuffer, .u(GL.FRAMEBUFFER), .u(framebuffer))
                rig.send(Op.framebufferTexture2D, .u(GL.FRAMEBUFFER), .u(GL.COLOR_ATTACHMENT0), .u(GL.TEXTURE_2D), .u(texture), 0)
            }
            rig.program("flat")
            rig.send(Op.frontFace, .u(GL.CCW))
            rig.send(Op.cullFace, .u(GL.BACK))
            rig.send(Op.enable, .u(GL.CULL_FACE))
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            rig.rectangle(color: [1, 0, 0, 1])
            XCTAssertEqual(rig.pixel(8, 8), red, "\(target): counterclockwise is the front, and is drawn")
            rig.rectangle(color: [0, 1, 0, 1], clockwise: true)
            XCTAssertEqual(rig.pixel(8, 8), red, "\(target): clockwise is the back, and is not")
            rig.send(Op.cullFace, .u(GL.FRONT))
            rig.rectangle(color: [0, 0, 1, 1], clockwise: true)
            XCTAssertEqual(rig.pixel(8, 8), blue, "\(target): with the front culled, the back is drawn")
            rig.send(Op.frontFace, .u(GL.CW))
            rig.rectangle(color: [1, 1, 1, 1], clockwise: true)
            XCTAssertEqual(rig.pixel(8, 8), blue, "\(target): clockwise made the front, it is culled")
            rig.send(Op.cullFace, .u(GL.FRONT_AND_BACK))
            rig.rectangle(color: [1, 1, 1, 1])
            XCTAssertEqual(rig.pixel(8, 8), blue, "\(target): both culled, no triangle is drawn")
            rig.send(Op.disable, .u(GL.CULL_FACE))
            rig.send(Op.frontFace, .u(GL.CCW))

            // gl_FrontFacing as green or red, and gl_FragCoord.y, counted from the bottom, as blue.
            rig.program("facing")
            let positions = rig.array(0, size: 2, Rig.whole)
            rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
            assertNear(rig.pixel(8, 3), [0, 255, Int(3.5 / 16 * 255), 255].map { UInt8($0) }, 2, "\(target): the front, low")
            assertNear(rig.pixel(8, 12), [0, 255, Int(12.5 / 16 * 255), 255].map { UInt8($0) }, 2, "\(target): the front, high")
            rig.send(Op.frontFace, .u(GL.CW))
            rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
            XCTAssertEqual(rig.pixel(8, 3)[0], 255, "\(target): the back")
            rig.send(Op.deleteBuffers, 1, .names([positions]))
            rig.expectNoError()
        }
    }

    // MARK: Uniforms

    /// A uniform of every type reaches the shader where the translator
    /// said it lies in the block, and glGetUniform reads it back.
    func testUniformsOfEveryTypeReachTheShaderAndAreReadBack() throws {
        let rig = try Rig()
        let program = rig.program("uniforms")
        rig.array(0, size: 2, Rig.whole)
        func drawn(_ pick: Int) -> [UInt8] {
            rig.send(Op.uniform1i, 1, .i(pick))
            rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
            return rig.pixel(8, 8)
        }
        func get(_ location: Int) -> (type: UInt32, floats: [Float], ints: [Int32]) {
            var answer = rig.ask(Op.getUniform, .u(program), .i(location))
            let type = answer.word(), data = answer.data()
            return (type, data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }, data.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) })
        }
        rig.send(Op.uniform1f, 0, 0.2)
        rig.send(Op.uniform2f, 2, 0.4, 0.6)
        assertNear(drawn(0), [51, 102, 153, 255], 1, "float and vec2")
        XCTAssertEqual(get(0).type, GL.FLOAT)
        XCTAssertEqual(get(0).floats, [0.2])
        XCTAssertEqual(get(2).floats, [0.4, 0.6])
        rig.send(Op.uniform3f, 3, 1.0, 0.0, 0.2)
        assertNear(drawn(1), [255, 0, 51, 255], 1, "vec3")
        XCTAssertEqual(get(3).floats, [1, 0, 0.2])
        rig.send(Op.uniform4fv, 4, 1, .floats([0.2, 0.4, 0.6, 0.8]))
        assertNear(drawn(2), [51, 102, 153, 204], 1, "vec4, as an array of one")
        XCTAssertEqual(get(4).type, GL.FLOAT_VEC4)
        rig.send(Op.uniform1i, 5, 10)
        rig.send(Op.uniform2i, 6, 20, 30)
        assertNear(drawn(3), [10, 20, 30, 255], 1, "int and ivec2")
        XCTAssertEqual(get(6).ints, [20, 30])
        XCTAssertEqual(get(6).type, GL.INT_VEC2)
        rig.send(Op.uniform3iv, 7, 1, .ints([40, 50, 60]))
        assertNear(drawn(4), [40, 50, 60, 255], 1, "ivec3")
        rig.send(Op.uniform4i, 8, 70, 80, 90, 100)
        assertNear(drawn(5), [70, 80, 90, 100], 1, "ivec4")
        XCTAssertEqual(get(8).ints, [70, 80, 90, 100])
        // A bool takes floats or ints, and is 1 for anything but zero.
        rig.send(Op.uniform1f, 9, 0.25)
        rig.send(Op.uniform2i, 10, 0, 7)
        assertNear(drawn(6), [255, 0, 255, 255], 1, "bool and bvec2")
        XCTAssertEqual(get(9).ints, [1])
        XCTAssertEqual(get(10).ints, [0, 1])
        XCTAssertEqual(get(10).type, GL.BOOL_VEC2)
        rig.send(Op.uniform3f, 11, 0.0, -1.0, 0.0)
        assertNear(drawn(7), [0, 255, 0, 255], 1, "bvec3")
        rig.send(Op.uniform4iv, 12, 1, .ints([1, 0, 0, 1]))
        assertNear(drawn(8), [255, 0, 0, 255], 1, "bvec4")
        // Matrices come a column after another.
        rig.send(Op.uniformMatrix2fv, 13, 1, .floats([0.2, 0.4, 0.6, 0.8]))
        assertNear(drawn(9), [51, 102, 153, 204], 1, "mat2")
        XCTAssertEqual(get(13).floats, [0.2, 0.4, 0.6, 0.8])
        rig.send(Op.uniformMatrix3fv, 14, 1, .floats([0.2, 0.4, 0.6, 1, 0, 0, 0, 1, 0.2]))
        assertNear(drawn(10), [51, 102, 153, 255], 1, "mat3, its first column")
        assertNear(drawn(11), [255, 0, 0, 255], 1, "mat3, its second column")
        assertNear(drawn(12), [0, 255, 51, 255], 1, "mat3, its third column")
        XCTAssertEqual(get(14).floats, [0.2, 0.4, 0.6, 1, 0, 0, 0, 1, 0.2])
        rig.send(Op.uniformMatrix4fv, 15, 1, .floats([0.2, 0.4, 0.6, 0.8, 1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 1, 0.2]))
        assertNear(drawn(13), [51, 102, 153, 204], 1, "mat4, its first column")
        assertNear(drawn(14), [255, 0, 0, 255], 1)
        assertNear(drawn(15), [0, 255, 0, 255], 1)
        assertNear(drawn(16), [0, 0, 255, 51], 1, "mat4, its last column")
        XCTAssertEqual(get(15).type, GL.FLOAT_MAT4)
        XCTAssertEqual(get(15).floats.count, 16)
        // An array: all of it from its first location, or from an element on; what passes its end is dropped.
        rig.send(Op.uniform4fv, 16, 3, .floats([1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 1, 1]))
        assertNear(drawn(17), red, 1, "arr[0]")
        assertNear(drawn(18), green, 1, "arr[1]")
        assertNear(drawn(19), blue, 1, "arr[2]")
        rig.send(Op.uniform4fv, 17, 3, .floats([1, 1, 1, 1, 0, 0, 0, 1, 0.5, 0.5, 0.5, 0.5]))
        rig.expectNoError()
        assertNear(drawn(17), red, 1)
        assertNear(drawn(18), white, 1, "arr[1], set from its own location")
        assertNear(drawn(19), black, 1)
        XCTAssertEqual(get(18).floats, [0, 0, 0, 1])
        XCTAssertEqual(get(1).ints, [19], "the int that picks")
        rig.expectNoError()

        // OpenGL's type rules.
        let wrong: [(String, UInt32, [Arg])] = [
            ("floats for an int", Op.uniform1f, [5, 1.0]),
            ("ints for a float", Op.uniform1i, [0, 1]),
            ("two for a vec3", Op.uniform2f, [3, 1.0, 1.0]),
            ("a vector for a matrix", Op.uniform4f, [13, 1.0, 1.0, 1.0, 1.0]),
            ("a matrix for a vector", Op.uniformMatrix2fv, [4, 1, .floats([1, 1, 1, 1])]),
            ("a mat3 for a mat2", Op.uniformMatrix3fv, [13, 1, .floats([Float](repeating: 1, count: 9))]),
            ("two values for what is no array", Op.uniform1fv, [0, 2, .floats([1, 1])]),
            ("no such location", Op.uniform1f, [19, 1.0]),
            ("fewer values than said", Op.uniform4fv, [16, 3, .floats([1, 1, 1, 1])]),
        ]
        for (what, op, arguments) in wrong {
            rig.feed(command(op, arguments))
            XCTAssertEqual(rig.error(), GL.INVALID_OPERATION, what)
        }
        rig.send(Op.uniform1fv, 0, -1, .floats([]))
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE, "a count below zero")
        rig.send(Op.uniform1f, -1, 1.0)
        rig.expectNoError()
        XCTAssertEqual(get(0).floats, [0.2], "nothing of all that was written")
        XCTAssertEqual(get(77).type, 0)
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
        var noProgram = rig.ask(Op.getUniform, 9999, 0)
        XCTAssertEqual(noProgram.word(), 0)
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE)
        rig.send(Op.useProgram, 0)
        rig.send(Op.uniform1f, 0, 1.0)
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION, "no program in use")
    }

    /// A uniform changed between two draws is each draw's own: the first
    /// keeps the value it was drawn with.
    func testEachDrawHasTheUniformsItWasDrawnWith() throws {
        let rig = try Rig()
        rig.program("flat")
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.rectangle(-1, -1, 0, 1, color: [1, 0, 0, 1])
        rig.rectangle(0, -1, 1, 1, color: [0, 1, 0, 1])
        let read = rig.read()
        XCTAssertEqual(read[8][3], red)
        XCTAssertEqual(read[8][12], green)
    }

    /// A buffer changed between two draws is each draw's own too
    /// (glBufferSubData), and so is one given anew (glBufferData).
    func testEachDrawHasTheBufferItWasDrawnWith() throws {
        let rig = try Rig()
        rig.program("flat")
        rig.send(Op.uniform4f, 0, 1.0, 1.0, 1.0, 1.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        // The bottom left quarter, then the same buffer's vertices moved to the top right, then given anew at the top left.
        rig.array(0, size: 2, [-1, -1, 0, -1, -1, 0, 0, 0])
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        rig.send(Op.bufferSubData, .u(GL.ARRAY_BUFFER), 0, .floats([0, 0, 1, 0, 0, 1, 1, 1]))
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        rig.send(Op.bufferData, .u(GL.ARRAY_BUFFER), 32, .u(GL.DYNAMIC_DRAW), .floats([-1, 0, 0, 0, -1, 1, 0, 1]))
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        rig.expectNoError()
        let read = rig.read()
        XCTAssertEqual(read[3][3], white, "the first draw, with the vertices it had")
        XCTAssertEqual(read[12][12], white, "the second, after glBufferSubData")
        XCTAssertEqual(read[12][3], white, "the third, after glBufferData")
        XCTAssertEqual(read[3][12], nothing)
        // A part of a buffer outside it is OpenGL's error, and a buffer with no data has zeros.
        rig.send(Op.bufferSubData, .u(GL.ARRAY_BUFFER), 28, .floats([1, 1]))
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE)
        rig.send(Op.bufferData, .u(GL.ARRAY_BUFFER), 32, .u(GL.STATIC_DRAW), .data(nil))
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), nothing, "four vertices at one point")
        // A buffer filled piece by piece, each piece drawn before the next is given: no draw's bytes change under it,
        // and the buffer stays where it is (nothing of it is let go for a copy).
        rig.send(Op.bufferData, .u(GL.ARRAY_BUFFER), 64, .u(GL.STREAM_DRAW), .data(nil))
        let held = rig.stream.budget.retired
        rig.send(Op.bufferSubData, .u(GL.ARRAY_BUFFER), 0, .floats([-1, -1, 0, -1, -1, 0, 0, 0]))
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        rig.send(Op.bufferSubData, .u(GL.ARRAY_BUFFER), 32, .floats([0, 0, 1, 0, 0, 1, 1, 1]))
        rig.send(Op.vertexAttribPointer, 0, 2, .u(GL.FLOAT), 0, 0, 32)
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        XCTAssertEqual(rig.stream.budget.retired, held)
        let pieces = rig.read()
        XCTAssertEqual(pieces[3][3], white)
        XCTAssertEqual(pieces[12][12], white)
        XCTAssertEqual(pieces[12][3], nothing)
        rig.expectNoError()
    }

    // MARK: Contexts and surfaces

    /// A context made to share another's objects draws with the other's
    /// texture; one that shares with none has no such texture.
    func testTwoContextsShareATexture() throws {
        let rig = try Rig()
        let texture = rig.texture(width: 1, height: 1, Data(green))
        rig.send(Op.contextCreate, 2, 1)
        rig.send(Op.contextCreate, 3, 0)
        rig.send(Op.surfaceCreate, 2, 16, 16, 1, 1, 1)
        for (context, expected) in [(UInt32(2), green), (UInt32(3), black)] {
            rig.send(Op.makeCurrent, .u(context), 2, 2)
            rig.program("texture")
            rig.send(Op.bindTexture, .u(GL.TEXTURE_2D), .u(texture))
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            rig.textured()
            rig.expectNoError()
            XCTAssertEqual(rig.pixel(8, 8), expected, "context \(context)")
        }
        // Each context has its own state and its own error.
        rig.send(Op.makeCurrent, 2, 2, 2)
        rig.send(Op.enable, 0xbad)
        rig.send(Op.makeCurrent, 1, 1, 1)
        rig.expectNoError()
        rig.send(Op.makeCurrent, 2, 2, 2)
        XCTAssertEqual(rig.error(), GL.INVALID_ENUM)
        // Deleted in one, it is gone for both once it is bound nowhere.
        rig.send(Op.deleteTextures, 1, .names([texture]))
        rig.send(Op.makeCurrent, 1, 1, 1)
        rig.program("texture")
        rig.send(Op.bindTexture, .u(GL.TEXTURE_2D), .u(texture))
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.textured()
        XCTAssertEqual(rig.pixel(8, 8), black, "the name is a new texture's")
        // A context destroyed while current lives until another is made current; with none current, nothing is drawn and answers still come.
        rig.send(Op.contextDestroy, 1)
        rig.expectNoError()
        rig.send(Op.makeCurrent, 0, 0, 0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        XCTAssertEqual(rig.error(), GL.NO_ERROR)
        _ = rig.ask(Op.readPixels, 0, 0, 1, 1, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE))
        XCTAssertEqual(rig.lastAnswer, word(0))
        rig.send(Op.makeCurrent, 1, 1, 1)
        XCTAssertEqual(rig.ask(Op.finish).bytes.count, 0, "context 1 is gone: none is current, and glFinish is answered all the same")
    }

    /// A surface resized is drawn at its new size and presented at it; a
    /// size past the bound is GL_INVALID_VALUE and the surface stays.
    func testASurfaceIsResized() throws {
        let rig = try Rig()
        rig.send(Op.surfaceResize, 1, 32, 8)
        rig.send(Op.viewport, 0, 0, 32, 8)
        rig.send(Op.clearColor, 1.0, 0.0, 0.0, 1.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.expectNoError()
        XCTAssertEqual(rig.read(0, 0, 32, 8)[7][31], red)
        XCTAssertEqual(rig.pixel(32, 0), nothing, "past its edge there is nothing")
        let picture = rig.swap()
        XCTAssertEqual(picture.count, 8)
        XCTAssertEqual(picture.first?.count, 32)
        XCTAssertEqual(picture[7][31], red)
        XCTAssertEqual(rig.presented.last?.width, 32)
        XCTAssertEqual(rig.presented.last?.height, 8)
        for (width, height) in [(4097, 8), (8, 4097), (0, 8), (-1, 8), (0x7fff_ffff, 0x7fff_ffff)] {
            rig.send(Op.surfaceResize, 1, .i(width), .i(height))
            XCTAssertEqual(rig.error(), GL.INVALID_VALUE, "\(width) × \(height)")
        }
        rig.send(Op.surfaceCreate, 9, 4097, 1, 1, 1, 1)
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        _ = rig.swap()
        XCTAssertEqual(rig.presented.last?.width, 32, "it stays as it was")
        rig.send(Op.swap, 9)
        XCTAssertEqual(rig.presented.count, 2, "a surface that was not made presents nothing")
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
        // A surface destroyed is drawn on until the context is told of another, and then no more.
        rig.send(Op.surfaceDestroy, 1)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.expectNoError()
        rig.send(Op.makeCurrent, 1, 1, 1)
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION, "it is no surface any more")
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        XCTAssertEqual(rig.error(), GL.INVALID_FRAMEBUFFER_OPERATION)
    }

    /// A picture that was presented and is in use (a window shows it) is
    /// not drawn into again while it is: the next is drawn into one that
    /// is not, and another is made when there is none. So what a window
    /// shows is never a picture half drawn again. Each is whole when it
    /// is presented, and no more are made than are in use at once.
    func testAPictureInUseIsNotDrawnIntoAgain() throws {
        let rig = try Rig()
        rig.keeps = 3
        var shown: [(picture: IOSurface, color: [UInt8])] = []
        for frame in 0..<40 {
            let color: [UInt8] = [UInt8(frame * 6), UInt8(255 - frame * 6), UInt8(frame), 255]
            rig.send(Op.clearColor, .f(Float(color[0]) / 255), .f(Float(color[1]) / 255), .f(Float(color[2]) / 255), 1.0)
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            _ = rig.swap()
            shown.append((try XCTUnwrap(rig.presented.last?.picture), color))
            assertNear(try XCTUnwrap(rig.middles.last), color, 1, "frame \(frame) was whole when it was presented")
            // The three newest are in use: each still shows what it was presented with.
            for held in shown.suffix(3) {
                XCTAssertTrue(held.picture.isInUse)
                assertNear(Rig.pixel(held.picture, 8, 8), held.color, 1, "after frame \(frame)")
            }
        }
        XCTAssertEqual(rig.presented.map(\.surface), [UInt32](repeating: 1, count: 40))
        XCTAssertEqual(Set(shown.map { ObjectIdentifier($0.picture) }).count, 4, "three in use and one to draw into")
        XCTAssertEqual(rig.stream.budget.surfaceBytes, 16 * 16 * (4 * 4 + 8), "and that many count against the stream's memory")
        // Resized, the surface has new memory; what is shown still is what it was.
        rig.send(Op.surfaceResize, 1, 32, 8)
        rig.send(Op.clearColor, 1.0, 1.0, 1.0, 1.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.expectNoError()
        XCTAssertEqual(rig.stream.budget.surfaceBytes, 32 * 8 * (4 + 8))
        for held in shown.suffix(3) { assertNear(Rig.pixel(held.picture, 8, 8), held.color, 1) }
    }

    /// When as many pictures as a surface may have are all in use, the
    /// next is drawn into the one presented longest ago: the stream waits
    /// for nobody but the GPU, and makes no memory without end for a
    /// window that lets go of nothing.
    func testWhenEveryPictureIsInUseTheOneShownLongestAgoIsDrawnInto() throws {
        let rig = try Rig()
        rig.keeps = 100
        var pictures: [IOSurface] = []
        for _ in 0..<12 {
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            _ = rig.swap()
            pictures.append(try XCTUnwrap(rig.presented.last?.picture))
        }
        XCTAssertEqual(GLSurface.pictures, 5)
        XCTAssertEqual(Set(pictures.prefix(5).map { ObjectIdentifier($0) }).count, 5, "five pictures a surface, each made when the others were in use")
        for index in 5..<12 { XCTAssertTrue(pictures[index] === pictures[index - 5], "picture \(index) is drawn where the one five before it was") }
        XCTAssertEqual(rig.stream.budget.surfaceBytes, 16 * 16 * (4 * 5 + 8))
    }

    /// A picture nobody uses is drawn into again: a surface whose
    /// pictures are looked at and let go of at once (or never shown, as a
    /// pbuffer's) has one. Depth is the surface's, not a picture's, and
    /// is there after a swap.
    func testAPictureNobodyUsesIsDrawnIntoAgain() throws {
        let rig = try Rig()
        var pictures: [IOSurface] = []
        let colors: [[Float]] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1], [1, 1, 1, 1]]
        for color in colors {
            rig.send(Op.clearColor, .f(color[0]), .f(color[1]), .f(color[2]), .f(color[3]))
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            _ = rig.swap()
            pictures.append(try XCTUnwrap(rig.presented.last?.picture))
            XCTAssertFalse(pictures[0].isInUse, "memory Metal draws into is not in use for that")
        }
        XCTAssertEqual(rig.middles, [red, green, blue, white])
        XCTAssertEqual(Set(pictures.map { ObjectIdentifier($0) }).count, 1)
        XCTAssertEqual(rig.stream.budget.surfaceBytes, 16 * 16 * (4 + 8))
        rig.program("flat")
        rig.send(Op.enable, .u(GL.DEPTH_TEST))
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT | GL.DEPTH_BUFFER_BIT))
        rig.rectangle(z: 0, color: [1, 0, 0, 1])
        _ = rig.swap()
        rig.send(Op.clearColor, 0.0, 0.0, 0.0, 0.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.rectangle(z: 0.5, color: [0, 1, 0, 1])
        XCTAssertEqual(rig.pixel(8, 8), nothing)
    }

    /// A surface made without alpha (its EGL config has none) is opaque:
    /// every pixel's alpha is 1 whatever is cleared or drawn, when it is
    /// read back, when it is blended with, when it is cleared in part,
    /// and in the picture presented. A resize keeps it so.
    func testASurfaceWithoutAlphaIsOpaque() throws {
        let rig = try Rig(alpha: false)
        let flat = Arg.u(GL.TEXTURE_2D)
        XCTAssertEqual(rig.pixel(8, 8), black, "from the first")
        rig.send(Op.clearColor, 0.0, 0.0, 0.0, 0.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        XCTAssertEqual(rig.pixel(8, 8), black, "cleared to an alpha of 0")
        XCTAssertEqual(rig.swap()[8][8], black, "and so it is shown")
        rig.program("flat")
        rig.rectangle(color: [1, 0, 0, 0.25])
        XCTAssertEqual(rig.pixel(8, 8), red, "drawn with an alpha of a quarter")
        // A clear of a part, which is drawn.
        rig.send(Op.enable, .u(GL.SCISSOR_TEST))
        rig.send(Op.scissor, 0, 0, 8, 16)
        rig.send(Op.clearColor, 0.0, 1.0, 0.0, 0.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.send(Op.disable, .u(GL.SCISSOR_TEST))
        XCTAssertEqual(rig.pixel(3, 8), green)
        XCTAssertEqual(rig.pixel(12, 8), red)
        // Blended with what is there, whose alpha is 1: all of what is drawn by GL_DST_ALPHA, none of it by one less that.
        rig.send(Op.enable, .u(GL.BLEND))
        rig.send(Op.blendFunc, .u(GL.DST_ALPHA), .u(GL.ZERO))
        rig.rectangle(color: [0, 0, 1, 0])
        XCTAssertEqual(rig.pixel(8, 8), blue)
        rig.send(Op.blendFunc, .u(GL.ONE_MINUS_DST_ALPHA), .u(GL.ONE))
        rig.rectangle(color: [1, 1, 1, 1])
        XCTAssertEqual(rig.pixel(8, 8), blue)
        rig.send(Op.disable, .u(GL.BLEND))
        XCTAssertEqual(rig.swap()[8][8], blue)
        // What has no alpha is not copied into a texture that keeps one.
        rig.send(Op.bindTexture, flat, .u(rig.name()))
        rig.send(Op.copyTexImage2D, flat, 0, .u(GL.RGBA), 0, 0, 4, 4, 0)
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
        rig.send(Op.copyTexImage2D, flat, 0, .u(GL.RGB), 0, 0, 4, 4, 0)
        rig.expectNoError()
        rig.send(Op.surfaceResize, 1, 8, 8)
        XCTAssertEqual(rig.pixel(4, 4), black, "resized, its new memory is opaque")
        rig.send(Op.clearColor, 0.0, 0.0, 0.0, 0.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        XCTAssertEqual(rig.swap()[4][4], black)
        rig.expectNoError()

        // A surface with alpha keeps the alpha that is drawn.
        let other = try Rig()
        XCTAssertEqual(other.pixel(8, 8), nothing)
        other.program("flat")
        other.rectangle(color: [1, 0, 0, 0.25])
        assertNear(other.pixel(8, 8), [255, 0, 0, 64], 1)
    }

    /// A surface has the depth and the stencil its EGL config has. Where
    /// it has none of one, that test passes and nothing is written, as
    /// OpenGL has it for a framebuffer with no such buffer; and only what
    /// it has counts against the stream's memory. A resize keeps it so.
    func testASurfaceHasTheDepthAndTheStencilItWasMadeWith() throws {
        for (depth, stencil, bytes) in [(true, true, 8), (true, false, 4), (false, true, 1), (false, false, 0)] {
            let what = "depth \(depth), stencil \(stencil)"
            let rig = try Rig(depth: depth, stencil: stencil)
            XCTAssertEqual(rig.stream.budget.surfaceBytes, 16 * 16 * (4 + bytes), what)
            rig.send(Op.surfaceResize, 1, 32, 32)
            XCTAssertEqual(rig.stream.budget.surfaceBytes, 32 * 32 * (4 + bytes), what)
            rig.send(Op.viewport, 0, 0, 32, 32)
            rig.program("flat")
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT | GL.DEPTH_BUFFER_BIT | GL.STENCIL_BUFFER_BIT))
            // Green behind red: seen only where there is no depth to say it is behind.
            rig.send(Op.enable, .u(GL.DEPTH_TEST))
            rig.rectangle(z: 0, color: [1, 0, 0, 1])
            rig.rectangle(z: 0.5, color: [0, 1, 0, 1])
            let behind = depth ? red : green
            XCTAssertEqual(rig.pixel(16, 16), behind, what)
            rig.send(Op.disable, .u(GL.DEPTH_TEST))
            // Blue where the stencil is 5, which it is nowhere: seen only where there is no stencil to say so.
            rig.send(Op.enable, .u(GL.STENCIL_TEST))
            rig.send(Op.stencilFunc, .u(GL.EQUAL), 5, 0xff)
            rig.rectangle(color: [0, 0, 1, 1])
            let masked = stencil ? behind : blue
            XCTAssertEqual(rig.pixel(16, 16), masked, what)
            // The left half's stencil cleared to 5, by a clear that is drawn: white there, and all over without a stencil.
            rig.send(Op.enable, .u(GL.SCISSOR_TEST))
            rig.send(Op.scissor, 0, 0, 16, 32)
            rig.send(Op.clearStencil, 5)
            rig.send(Op.clearDepthf, 0.0)
            rig.send(Op.clear, .u(GL.DEPTH_BUFFER_BIT | GL.STENCIL_BUFFER_BIT))
            rig.send(Op.disable, .u(GL.SCISSOR_TEST))
            rig.rectangle(color: [1, 1, 1, 1])
            XCTAssertEqual(rig.pixel(4, 16), white, what)
            XCTAssertEqual(rig.pixel(28, 16), stencil ? masked : white, what)
            rig.expectNoError()
            XCTAssertEqual(rig.swap()[16][4], white, what)
        }
    }

    // MARK: Answers

    /// glCompileShader's answer is, byte for byte, what the header says:
    /// whether it compiled, and the log as data.
    func testTheCompileAnswerIsAsTheHeaderSays() throws {
        let rig = try Rig()
        let shader = rig.name()
        rig.send(Op.createShader, .u(shader), .u(GL.FRAGMENT_SHADER))
        rig.send(Op.shaderSource, .u(shader), .text("bad one"))
        _ = rig.ask(Op.compileShader, .u(shader))
        let log = "ERROR: 0:1: 'bad one' : syntax error"
        XCTAssertEqual(log.utf8.count % 4, 0, "this log needs no padding")
        XCTAssertEqual(rig.lastAnswer, word(UInt32(8 + log.utf8.count)) + word(0) + word(UInt32(log.utf8.count)) + Data(log.utf8))
        rig.send(Op.shaderSource, .u(shader), .text("warned"))
        _ = rig.ask(Op.compileShader, .u(shader))
        // Fifteen bytes of log, and a zero to make them sixteen.
        XCTAssertEqual(rig.lastAnswer, word(24) + word(1) + word(15) + Data("WARNING: unused".utf8) + Data([0]))
        rig.send(Op.shaderSource, .u(shader), .text("fine"))
        _ = rig.ask(Op.compileShader, .u(shader))
        XCTAssertEqual(rig.lastAnswer, word(8) + word(1) + word(0))
        rig.expectNoError()
        // No such shader: an answer all the same, and OpenGL's error.
        _ = rig.ask(Op.compileShader, 4242)
        XCTAssertEqual(rig.lastAnswer, word(8) + word(0) + word(0))
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE)
    }

    /// glLinkProgram's answer is, byte for byte, what the header says: the
    /// attributes and the uniforms the translator reported, each with its
    /// location, type, size and name.
    func testTheLinkAnswerIsAsTheHeaderSays() throws {
        let rig = try Rig()
        func name(_ text: String) -> Data {
            word(UInt32(text.utf8.count)) + Data(text.utf8) + Data(count: (4 - text.utf8.count % 4) % 4)
        }
        let program = rig.name()
        rig.send(Op.createProgram, .u(program))
        rig.send(Op.attachShader, .u(program), .u(rig.shader(GL.VERTEX_SHADER, "flat")))
        rig.send(Op.attachShader, .u(program), .u(rig.shader(GL.FRAGMENT_SHADER, "flat")))
        rig.send(Op.bindAttribLocation, .u(program), 3, .text("position"))
        _ = rig.ask(Op.linkProgram, .u(program))
        var expected = word(1) + name("")
        expected += word(1) + word(0) + word(GL.FLOAT_VEC4) + word(1) + name("position")
        expected += word(1) + word(0) + word(GL.FLOAT_VEC4) + word(1) + name("color")
        XCTAssertEqual(rig.lastAnswer, word(UInt32(expected.count)) + expected)
        XCTAssertEqual(rig.translator.locations, ["position": 3], "the translator is told what glBindAttribLocation asked for")

        let uniforms = rig.name()
        rig.send(Op.createProgram, .u(uniforms))
        rig.send(Op.attachShader, .u(uniforms), .u(rig.shader(GL.VERTEX_SHADER, "uniforms")))
        rig.send(Op.attachShader, .u(uniforms), .u(rig.shader(GL.FRAGMENT_SHADER, "uniforms")))
        var answer = rig.ask(Op.linkProgram, .u(uniforms))
        XCTAssertEqual(answer.word(), 1)
        XCTAssertEqual(answer.text(), "")
        XCTAssertEqual(answer.word(), 1)
        XCTAssertEqual([answer.word(), answer.word(), answer.word()], [0, GL.FLOAT_VEC4, 1])
        XCTAssertEqual(answer.text(), "position")
        XCTAssertEqual(answer.word(), 17)
        var listed: [String] = []
        for index in 0..<17 {
            let location = answer.word(), type = answer.word(), size = answer.word(), text = answer.text()
            listed.append(text)
            XCTAssertEqual(location, UInt32(index))
            XCTAssertEqual(type, Programs.uniforms.uniforms[index].type)
            XCTAssertEqual(size, index == 16 ? 3 : 1)
        }
        XCTAssertEqual(listed.last, "arr[0]")
        XCTAssertEqual(answer.at, answer.bytes.count, "and nothing after them")

        // A program that does not link: 0, the log, no attributes, no uniforms.
        let unlinked = rig.name()
        rig.send(Op.createProgram, .u(unlinked))
        _ = rig.ask(Op.linkProgram, .u(unlinked))
        let log = "A program is linked from a vertex shader and a fragment shader that both compiled."
        XCTAssertEqual(rig.lastAnswer, word(UInt32(8 + name(log).count + 4)) + word(0) + name(log) + word(0) + word(0))
        rig.send(Op.attachShader, .u(unlinked), .u(rig.shader(GL.VERTEX_SHADER, "flat")))
        rig.send(Op.attachShader, .u(unlinked), .u(rig.shader(GL.FRAGMENT_SHADER, "color")))
        var mismatched = rig.ask(Op.linkProgram, .u(unlinked))
        XCTAssertEqual(mismatched.word(), 0)
        XCTAssertEqual(mismatched.text(), "ERROR: the shaders do not go together", "the translator's own log")
        rig.expectNoError()
        rig.send(Op.useProgram, .u(unlinked))
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION, "a program that did not link is not used")
        _ = rig.ask(Op.linkProgram, 4242)
        XCTAssertEqual(rig.lastAnswer, word(16) + word(0) + word(0) + word(0) + word(0))
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE)
    }

    /// What a translator gone wrong hands over is a program that does not
    /// link, with a log that says whose fault it is; nothing is drawn
    /// with it and nothing crashes.
    func testATranslationMetalWillNotHaveIsALinkFailure() throws {
        let rig = try Rig()
        rig.program("flat")
        for source in ["notMetal", "outsideBlock", "otherBuffer", "noFunctions", "farAttribute", "solidTexture"] {
            let program = rig.name()
            rig.send(Op.createProgram, .u(program))
            rig.send(Op.attachShader, .u(program), .u(rig.shader(GL.VERTEX_SHADER, source)))
            rig.send(Op.attachShader, .u(program), .u(rig.shader(GL.FRAGMENT_SHADER, source)))
            var answer = rig.ask(Op.linkProgram, .u(program))
            XCTAssertEqual(answer.word(), 0, source)
            let log = answer.text()
            XCTAssertTrue(log.contains("Monad's fault, not the program's"), "\(source): \(log)")
            XCTAssertEqual([answer.word(), answer.word()], [0, 0])
            rig.send(Op.useProgram, .u(program))
            XCTAssertEqual(rig.error(), GL.INVALID_OPERATION, source)
        }
        // A block said to be shorter than the Metal struct is: it links, and the draw is given all the struct's bytes.
        rig.program("shortBlock")
        rig.array(0, size: 2, Rig.whole)
        rig.send(Op.uniform1f, 0, 1.0)
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        rig.expectNoError()
        assertNear(rig.pixel(8, 8), [255, 0, 0, 255])
    }

    /// Shaders and programs deleted while something still uses them stay
    /// until it lets go, as OpenGL has it.
    func testDeletedShadersAndProgramsLiveWhileInUse() throws {
        let rig = try Rig()
        let program = rig.name(), vertex = rig.shader(GL.VERTEX_SHADER, "flat"), fragment = rig.shader(GL.FRAGMENT_SHADER, "flat")
        rig.send(Op.createProgram, .u(program))
        rig.send(Op.attachShader, .u(program), .u(vertex))
        rig.send(Op.attachShader, .u(program), .u(fragment))
        rig.send(Op.attachShader, .u(program), .u(vertex))
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION, "attached twice")
        rig.send(Op.deleteShader, .u(vertex))
        rig.send(Op.deleteShader, .u(fragment))
        var linked = rig.ask(Op.linkProgram, .u(program))
        XCTAssertEqual(linked.word(), 1, "its shaders are deleted and still attached")
        rig.send(Op.useProgram, .u(program))
        rig.send(Op.deleteProgram, .u(program))
        rig.rectangle(color: [1, 0, 0, 1])
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), red, "deleted and in use, it draws")
        rig.send(Op.useProgram, 0)
        rig.send(Op.useProgram, .u(program))
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE, "out of use, it is gone")
        // A shader detached is one the program is not linked from.
        let other = rig.program("flat")
        let detached = rig.shader(GL.FRAGMENT_SHADER, "flat")
        rig.send(Op.detachShader, .u(other), .u(detached))
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION, "not the one attached")
        // The fragment shader the program was made with: the second name after the program's own.
        rig.send(Op.detachShader, .u(other), .u(other + 2))
        rig.expectNoError()
        var unlinked = rig.ask(Op.linkProgram, .u(other))
        XCTAssertEqual(unlinked.word(), 0)
        rig.send(Op.attachShader, .u(other), .u(detached))
        var relinked = rig.ask(Op.linkProgram, .u(other))
        XCTAssertEqual(relinked.word(), 1)
        rig.send(Op.shaderSource, .u(vertex), .text("flat"))
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE, "and its shaders with it")
        // The names are the library's: one that is taken is not given again, and a shader's is not a program's.
        let shader = rig.shader(GL.VERTEX_SHADER, "flat")
        rig.send(Op.createProgram, .u(shader))
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
        rig.send(Op.useProgram, .u(shader))
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
        rig.send(Op.detachShader, .u(rig.program("flat")), .u(shader))
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION, "not attached")
        rig.send(Op.createShader, .u(rig.name()), 0x1234)
        XCTAssertEqual(rig.error(), GL.INVALID_ENUM)
        rig.send(Op.bindAttribLocation, .u(rig.program("flat")), 16, .text("position"))
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE)
        rig.send(Op.bindAttribLocation, .u(rig.program("flat")), 1, .text("gl_Position"))
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
    }

    /// Calls OpenGL would not have are its errors, the first of which is
    /// kept until asked for; the call itself changes nothing.
    func testInvalidCallsAreOpenGLsErrors() throws {
        let rig = try Rig()
        rig.program("flat")
        let texture = rig.texture(width: 4, height: 4, nil)
        rig.buffer(GL.ARRAY_BUFFER, Data(count: 16))
        let rgba = Arg.u(GL.RGBA), byte = Arg.u(GL.UNSIGNED_BYTE), flat = Arg.u(GL.TEXTURE_2D)
        let calls: [(String, UInt32, [Arg], UInt32)] = [
            ("enable of no capability", Op.enable, [0x1234], GL.INVALID_ENUM),
            ("blend function", Op.blendFunc, [.u(GL.ONE), .u(GL.SRC_ALPHA_SATURATE)], GL.INVALID_ENUM),
            ("blend equation", Op.blendEquation, [.u(GL.ONE)], GL.INVALID_ENUM),
            ("depth function", Op.depthFunc, [.u(GL.KEEP)], GL.INVALID_ENUM),
            ("stencil function", Op.stencilFunc, [.u(GL.KEEP), 0, 0], GL.INVALID_ENUM),
            ("stencil face", Op.stencilMaskSeparate, [.u(GL.CW), 0], GL.INVALID_ENUM),
            ("stencil operation", Op.stencilOp, [.u(GL.KEEP), .u(GL.LESS), .u(GL.KEEP)], GL.INVALID_ENUM),
            ("cull face", Op.cullFace, [.u(GL.CCW)], GL.INVALID_ENUM),
            ("front face", Op.frontFace, [.u(GL.BACK)], GL.INVALID_ENUM),
            ("texture unit", Op.activeTexture, [.u(GL.TEXTURE0 + 32)], GL.INVALID_ENUM),
            ("line width", Op.lineWidth, [0.0], GL.INVALID_VALUE),
            ("scissor", Op.scissor, [0, 0, -1, 1], GL.INVALID_VALUE),
            ("clear mask", Op.clear, [0x8000_0000], GL.INVALID_VALUE),
            ("buffer target", Op.bindBuffer, [.u(GL.TEXTURE_2D), 1], GL.INVALID_ENUM),
            ("buffer usage", Op.bufferData, [.u(GL.ARRAY_BUFFER), 4, 0, .data(Data(count: 4))], GL.INVALID_ENUM),
            ("buffer size", Op.bufferData, [.u(GL.ARRAY_BUFFER), -4, .u(GL.STATIC_DRAW), .data(nil)], GL.INVALID_VALUE),
            ("no buffer bound", Op.bufferData, [.u(GL.ELEMENT_ARRAY_BUFFER), 4, .u(GL.STATIC_DRAW), .data(nil)], GL.INVALID_OPERATION),
            ("buffer data of another size", Op.bufferData, [.u(GL.ARRAY_BUFFER), 8, .u(GL.STATIC_DRAW), .data(Data(count: 4))], GL.INVALID_OPERATION),
            ("texture target", Op.bindTexture, [.u(GL.ARRAY_BUFFER), 1], GL.INVALID_ENUM),
            ("a flat texture as a cube", Op.bindTexture, [.u(GL.TEXTURE_CUBE_MAP), .u(texture)], GL.INVALID_OPERATION),
            ("texture parameter", Op.texParameteri, [flat, .u(GL.TEXTURE_MAG_FILTER), .u(GL.LINEAR_MIPMAP_LINEAR)], GL.INVALID_ENUM),
            ("texture parameter name", Op.texParameterf, [flat, .u(GL.TEXTURE), 1.0], GL.INVALID_ENUM),
            ("image target", Op.texImage2D, [.u(GL.TEXTURE_CUBE_MAP), 0, rgba, 1, 1, 0, rgba, byte, .data(nil)], GL.INVALID_ENUM),
            ("image type", Op.texImage2D, [flat, 0, rgba, 1, 1, 0, rgba, .u(GL.FLOAT), .data(nil)], GL.INVALID_ENUM),
            ("image border", Op.texImage2D, [flat, 0, rgba, 1, 1, 1, rgba, byte, .data(nil)], GL.INVALID_VALUE),
            ("image level", Op.texImage2D, [flat, 13, rgba, 1, 1, 0, rgba, byte, .data(nil)], GL.INVALID_VALUE),
            ("image too large for its level", Op.texImage2D, [flat, 1, rgba, 4096, 1, 0, rgba, byte, .data(nil)], GL.INVALID_VALUE),
            ("image size", Op.texImage2D, [flat, 0, rgba, -1, 1, 0, rgba, byte, .data(nil)], GL.INVALID_VALUE),
            ("formats that differ", Op.texImage2D, [flat, 0, rgba, 1, 1, 0, .u(GL.RGB), byte, .data(nil)], GL.INVALID_OPERATION),
            ("a type its format has not", Op.texImage2D, [flat, 0, rgba, 1, 1, 0, rgba, .u(GL.UNSIGNED_SHORT_5_6_5), .data(nil)], GL.INVALID_OPERATION),
            ("pixels of another count", Op.texImage2D, [flat, 0, rgba, 2, 2, 0, rgba, byte, .data(Data(count: 15))], GL.INVALID_OPERATION),
            ("a part of an image that is not", Op.texSubImage2D, [flat, 1, 0, 0, 1, 1, rgba, byte, .data(Data(count: 4))], GL.INVALID_OPERATION),
            ("a part outside its image", Op.texSubImage2D, [flat, 0, 3, 3, 2, 2, rgba, byte, .data(Data(count: 16))], GL.INVALID_VALUE),
            ("a part of another format", Op.texSubImage2D, [flat, 0, 0, 0, 1, 1, .u(GL.RGB), byte, .data(Data(count: 3))], GL.INVALID_OPERATION),
            ("a part with no pixels", Op.texSubImage2D, [flat, 0, 0, 0, 1, 1, rgba, byte, .data(nil)], GL.INVALID_OPERATION),
            ("mipmaps of no target", Op.generateMipmap, [.u(GL.TEXTURE)], GL.INVALID_ENUM),
            ("a copy as depth", Op.copyTexImage2D, [flat, 0, .u(GL.DEPTH_COMPONENT), 0, 0, 1, 1, 0], GL.INVALID_ENUM),
            ("a copy with a border", Op.copyTexImage2D, [flat, 0, rgba, 0, 0, 1, 1, 1], GL.INVALID_VALUE),
            ("a copy of 2^31 - 1 pixels a side", Op.copyTexImage2D, [flat, 0, rgba, 0, 0, 0x7fff_ffff, 0x7fff_ffff, 0], GL.INVALID_VALUE),
            ("a copy into an image that is not", Op.copyTexSubImage2D, [flat, 1, 0, 0, 0, 0, 1, 1], GL.INVALID_OPERATION),
            ("a copy into a part outside its image", Op.copyTexSubImage2D, [flat, 0, 3, 3, 0, 0, 2, 2], GL.INVALID_VALUE),
            ("a copy to no target", Op.copyTexSubImage2D, [.u(GL.TEXTURE), 0, 0, 0, 0, 0, 1, 1], GL.INVALID_ENUM),
            ("framebuffer target", Op.bindFramebuffer, [.u(GL.RENDERBUFFER), 1], GL.INVALID_ENUM),
            ("renderbuffer format", Op.renderbufferStorage, [.u(GL.RENDERBUFFER), rgba, 1, 1], GL.INVALID_ENUM),
            ("no renderbuffer bound", Op.renderbufferStorage, [.u(GL.RENDERBUFFER), .u(GL.RGBA4), 1, 1], GL.INVALID_OPERATION),
            ("renderbuffer size", Op.renderbufferStorage, [.u(GL.RENDERBUFFER), .u(GL.RGBA4), 4097, 1], GL.INVALID_VALUE),
            ("attaching to the surface", Op.framebufferTexture2D, [.u(GL.FRAMEBUFFER), .u(GL.COLOR_ATTACHMENT0), flat, .u(texture), 0], GL.INVALID_OPERATION),
            ("attachment point", Op.framebufferRenderbuffer, [.u(GL.FRAMEBUFFER), .u(GL.COLOR_ATTACHMENT0 + 1), .u(GL.RENDERBUFFER), 0], GL.INVALID_ENUM),
            ("vertex attribute", Op.enableVertexAttribArray, [16], GL.INVALID_VALUE),
            ("vertex size", Op.vertexAttribPointer, [0, 5, .u(GL.FLOAT), 0, 0, 0], GL.INVALID_VALUE),
            ("vertex type", Op.vertexAttribPointer, [0, 4, .u(GL.UNSIGNED_INT), 0, 0, 0], GL.INVALID_ENUM),
            ("vertex stride", Op.vertexAttribPointer, [0, 4, .u(GL.FLOAT), 0, -4, 0], GL.INVALID_VALUE),
            ("draw mode", Op.drawArrays, [7, 0, 3], GL.INVALID_ENUM),
            ("draw count", Op.drawArrays, [.u(GL.TRIANGLES), 0, -3], GL.INVALID_VALUE),
            ("draw first", Op.drawArrays, [.u(GL.TRIANGLES), -1, 3], GL.INVALID_VALUE),
            ("index type", Op.drawElements, [.u(GL.TRIANGLES), 3, .u(GL.FLOAT), 0], GL.INVALID_ENUM),
            ("no index buffer", Op.drawElements, [.u(GL.TRIANGLES), 3, .u(GL.UNSIGNED_SHORT), 0], GL.INVALID_OPERATION),
            ("deleting a count below zero", Op.deleteBuffers, [-1, .names([])], GL.INVALID_VALUE),
            ("a program that is none", Op.useProgram, [4242], GL.INVALID_VALUE),
            ("shader source of none", Op.shaderSource, [4242, .text("x")], GL.INVALID_VALUE),
            ("a program of name 0", Op.createProgram, [0], GL.INVALID_VALUE),
        ]
        for (what, op, arguments, expected) in calls {
            rig.feed(command(op, arguments))
            XCTAssertEqual(rig.error(), expected, what)
            XCTAssertEqual(rig.error(), GL.NO_ERROR, "\(what): asked for, the error is no more")
        }
        // The first error is the one kept.
        rig.send(Op.enable, 0x1234)
        rig.send(Op.lineWidth, -1.0)
        rig.send(Op.drawElements, .u(GL.TRIANGLES), 3, .u(GL.UNSIGNED_SHORT), 0)
        XCTAssertEqual(rig.error(), GL.INVALID_ENUM)
        rig.expectNoError()
        // glReadPixels reads one format; an answer comes whatever is asked, of no length when there is nothing to read.
        for (format, type, expected) in [(GL.RGB, GL.UNSIGNED_BYTE, GL.INVALID_OPERATION), (GL.RGBA, GL.FLOAT, GL.INVALID_ENUM), (GL.DEPTH_COMPONENT, GL.UNSIGNED_BYTE, GL.INVALID_ENUM)] {
            _ = rig.ask(Op.readPixels, 0, 0, 1, 1, .u(format), .u(type))
            XCTAssertEqual(rig.lastAnswer, word(0))
            XCTAssertEqual(rig.error(), expected)
        }
        _ = rig.ask(Op.readPixels, 0, 0, -1, 1, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE))
        XCTAssertEqual(rig.lastAnswer, word(0))
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE)
        // Nothing of all that drew or changed anything: the texture is as it was, and a draw draws.
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.rectangle(color: [0, 1, 0, 1])
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), green)
    }

    // MARK: A hostile stream

    /// A command that is not as the header describes (cut short, with
    /// words too many, with data that says it is longer than the command)
    /// is GL_INVALID_OPERATION and the stream goes on with the next; an
    /// answered one is answered all the same.
    func testCommandsNotAsTheHeaderSaysAreSkipped() throws {
        let rig = try Rig()
        rig.program("flat")
        func raw(_ op: UInt32, _ words: [UInt32]) -> Data {
            word(op) + word(UInt32(8 + words.count * 4)) + bytes(words)
        }
        let malformed: [(String, Data)] = [
            ("a viewport of three words", raw(Op.viewport, [0, 0, 16])),
            ("a viewport of five words", raw(Op.viewport, [0, 0, 16, 16, 16])),
            ("a clear with no mask", raw(Op.clear, [])),
            ("data that says it passes the command's end", raw(Op.shaderSource, [1, 5, 0x6161_6161])),
            ("data of 0xffffffff bytes where none stands for NULL and NULL is not taken", raw(Op.shaderSource, [1, 0xffff_ffff])),
            ("data of 0xfffffffe bytes", raw(Op.bufferSubData, [GL.ARRAY_BUFFER, 0, 0xffff_fffe, 0])),
            ("data of 0x80000000 bytes", raw(Op.texImage2D, [GL.TEXTURE_2D, 0, GL.RGBA, 1, 1, 0, GL.RGBA, GL.UNSIGNED_BYTE, 0x8000_0000, 0])),
            ("data longer by a byte than what is left", word(Op.shaderSource) + word(20) + word(1) + word(5) + Data([97, 98, 99, 100])),
            ("words after the data", raw(Op.shaderSource, [1, 4, 0x6161_6161, 7])),
            ("names fewer than counted", raw(Op.deleteBuffers, [3, 8, 1, 2])),
            ("a count of names of 0x7fffffff", raw(Op.deleteTextures, [0x7fff_ffff, 4, 1])),
            ("uniform values fewer than counted", raw(Op.uniform4fv, [0, 0x7fff_ffff, 16, 0, 0, 0, 0])),
            ("indices fewer than counted", raw(Op.drawElementsClient, [GL.TRIANGLES, 0x00ff_ffff, GL.UNSIGNED_SHORT, 6, 0, 0])),
            ("an op that is none", raw(999, [1, 2, 3])),
            ("an op that is none, in EGL's numbers", raw(9, [])),
            ("the op after the last", raw(Op.viewport + 1, [0, 0, 1, 1])),
            ("a swap with nothing", raw(Op.swap, [])),
            ("a context made from too many words", raw(Op.contextCreate, [7, 0, 0])),
        ]
        for (what, data) in malformed {
            rig.feed(data)
            XCTAssertEqual(rig.error(), GL.INVALID_OPERATION, what)
        }
        // Every command that is answered is, also when it is not what the header says.
        for op in Op.answered.sorted() {
            let before = rig.answers.count
            rig.feed(raw(op, [1, 2, 3, 4, 5, 6, 7, 8, 9]))
            rig.feed(raw(op, []))
            XCTAssertEqual(rig.answers.count, before + 2, "op \(op) is answered, also with words too many")
            _ = rig.error()
        }
        XCTAssertNil(rig.stream.contexts[7], "the context of the command that was not one was not made")
        // The stream is as it was: it draws.
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.rectangle(color: [1, 0, 0, 1])
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), red)
    }

    /// Only a size that is none ends the stream: under a header's own,
    /// no multiple of four, or past the largest command. `feed` says so
    /// and takes nothing after it.
    func testASizeThatIsNoneEndsTheStream() throws {
        let sizes: [UInt32] = [0, 4, 7, 9, 10, 11, 13, UInt32((64 << 20) + 4100), 0x7fff_fffc, 0xffff_fffc, 0xffff_ffff]
        for size in sizes {
            let rig = try Rig()
            XCTAssertFalse(rig.stream.feed(word(Op.clear) + word(size) + Data(count: 16)), "a size of \(size)")
            XCTAssertFalse(rig.stream.feed(command(Op.getError, [])), "ended, it stays ended")
            XCTAssertEqual(rig.answers.count, 0)
        }
        // The largest command there is is one, though this one's arguments are not a clear's.
        let rig = try Rig()
        let largest = (64 << 20) + 4096
        XCTAssertTrue(rig.stream.feed(word(Op.clear) + word(UInt32(largest)) + Data(count: 1 << 20)))
        XCTAssertTrue(rig.stream.feed(Data(count: largest - 8 - (1 << 20))))
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
        // A header alone is a command still to come, and its end ends nothing.
        XCTAssertTrue(rig.stream.feed(word(Op.getError)))
        XCTAssertTrue(rig.stream.feed(word(8).prefix(3)))
        XCTAssertEqual(rig.answers.count, 1)
        XCTAssertTrue(rig.stream.feed(word(8).suffix(1)))
        XCTAssertEqual(rig.answers.count, 2)
        // A size that is none in a header that came in two parts.
        let late = try Rig()
        XCTAssertTrue(late.stream.feed(word(Op.clear) + word(7).prefix(2)))
        XCTAssertFalse(late.stream.feed(word(7).suffix(2) + word(GL.COLOR_BUFFER_BIT)))
        // Closed, it takes nothing more.
        rig.stream.close()
        XCTAssertFalse(rig.stream.feed(command(Op.getError, [])))
        rig.stream.close()
    }

    /// The same stream draws the same picture and gives the same answers
    /// however it is split: whole, at every byte, and in pieces of every
    /// length from two bytes to thirty.
    func testAStreamSplitAnywhereIsTheSameStream() throws {
        // A stream with a bit of everything, written once.
        var stream = Data()
        let recorder = try Rig(size: nil)
        func add(_ op: UInt32, _ arguments: Arg...) {
            stream.append(command(op, arguments))
        }
        add(Op.contextCreate, 1, 0)
        add(Op.surfaceCreate, 1, 8, 8, 1, 1, 1)
        add(Op.makeCurrent, 1, 1, 1)
        for (shader, type) in [(UInt32(1), GL.VERTEX_SHADER), (UInt32(2), GL.FRAGMENT_SHADER)] {
            add(Op.createShader, .u(shader), .u(type))
            add(Op.shaderSource, .u(shader), .text("texture"))
            add(Op.compileShader, .u(shader))
        }
        add(Op.createProgram, 3)
        add(Op.attachShader, 3, 1)
        add(Op.attachShader, 3, 2)
        add(Op.linkProgram, 3)
        add(Op.useProgram, 3)
        add(Op.bindTexture, .u(GL.TEXTURE_2D), 4)
        add(Op.texImage2D, .u(GL.TEXTURE_2D), 0, .u(GL.RGB), 1, 1, 0, .u(GL.RGB), .u(GL.UNSIGNED_BYTE), .data(Data([10, 200, 30])))
        add(Op.texParameteri, .u(GL.TEXTURE_2D), .u(GL.TEXTURE_MIN_FILTER), .u(GL.NEAREST))
        add(Op.enableVertexAttribArray, 0)
        add(Op.enableVertexAttribArray, 1)
        add(Op.clientArray, 0, 2, .u(GL.FLOAT), 0, 0, .floats(Rig.whole))
        add(Op.clientArray, 1, 2, .u(GL.BYTE), 0, 0, .data(Data([0, 0, 1, 0, 0, 1, 1, 1])))
        add(Op.drawElementsClient, .u(GL.TRIANGLE_STRIP), 4, .u(GL.UNSIGNED_BYTE), .data(Data([0, 1, 2, 3])))
        add(Op.enable, 0xbad)
        add(Op.getError)
        add(Op.readPixels, 2, 2, 3, 3, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE))
        add(Op.finish)
        add(Op.swap, 1)
        XCTAssertTrue(recorder.stream.feed(stream))
        let answers = recorder.answers
        XCTAssertEqual(answers.count, 7)
        XCTAssertEqual(answers.last, word(0), "the swap's")
        XCTAssertEqual(answers[3], word(4) + word(GL.INVALID_ENUM))
        XCTAssertEqual(answers[4], word(40) + word(36) + Data((0..<9).flatMap { _ in [UInt8(10), 200, 30, 255] }))
        let picture = Rig.pixels(try XCTUnwrap(recorder.presented.last?.picture))
        XCTAssertEqual(picture[4][4], [10, 200, 30, 255])

        for piece in 1...30 {
            let rig = try Rig(size: nil)
            var at = 0
            while at < stream.count {
                let end = min(at + piece, stream.count)
                XCTAssertTrue(rig.stream.feed(stream.subdata(in: at..<end)))
                at = end
            }
            XCTAssertEqual(rig.answers, answers, "in pieces of \(piece)")
            XCTAssertEqual(Rig.pixels(try XCTUnwrap(rig.presented.last?.picture)), picture, "in pieces of \(piece)")
        }
    }

    /// Draws that would have Metal read past a buffer's end are
    /// GL_INVALID_OPERATION and draw nothing: vertices past the array's
    /// buffer, indices past the index buffer, indices that name vertices
    /// past the arrays, an array that begins past its buffer.
    func testDrawsThatReachPastTheirBuffersAreNotDrawn() throws {
        let rig = try Rig()
        rig.program("flat")
        rig.send(Op.uniform4f, 0, 1.0, 0.0, 0.0, 1.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        let vertices = rig.array(0, size: 2, Rig.whole)
        let elements = rig.buffer(GL.ELEMENT_ARRAY_BUFFER, bytes([UInt16]([0, 1, 2, 3, 4, 65535])))
        let ushort = Arg.u(GL.UNSIGNED_SHORT), strip = Arg.u(GL.TRIANGLE_STRIP), float = Arg.u(GL.FLOAT)
        let draws: [(String, [(UInt32, [Arg])])] = [
            ("a fifth vertex of four", [(Op.drawArrays, [strip, 0, 5])]),
            ("four vertices from the second on", [(Op.drawArrays, [strip, 1, 4])]),
            ("a first vertex of 2^31 - 1", [(Op.drawArrays, [strip, 0x7fff_ffff, 4])]),
            ("2^31 - 1 vertices", [(Op.drawArrays, [strip, 0, 0x7fff_ffff])]),
            ("a seventh index of six", [(Op.drawElements, [strip, 7, ushort, 0])]),
            ("six indices from the second on", [(Op.drawElements, [strip, 6, ushort, 2])]),
            ("indices from 4 GiB on", [(Op.drawElements, [strip, 1, ushort, 0xffff_fffe])]),
            ("an index that names a fifth vertex", [(Op.drawElements, [strip, 5, ushort, 0])]),
            ("an index of 65535", [(Op.drawElements, [strip, 3, ushort, 6])]),
            ("indices of four bytes read from a buffer of twelve", [(Op.drawElements, [strip, 4, .u(GL.UNSIGNED_INT), 0])]),
            ("an array that begins past its buffer", [(Op.vertexAttribPointer, [0, 2, float, 0, 0, 0xffff_fff0]), (Op.drawArrays, [strip, 0, 4])]),
            ("an array whose last vertex ends past its buffer", [(Op.vertexAttribPointer, [0, 2, float, 0, 0, 4]), (Op.drawArrays, [strip, 0, 4])]),
            ("an array of four numbers a vertex in a buffer of two", [(Op.vertexAttribPointer, [0, 4, float, 0, 8, 0]), (Op.drawArrays, [strip, 0, 4])]),
            ("a stride that carries the last vertex out", [(Op.vertexAttribPointer, [0, 2, float, 0, 12, 0]), (Op.drawArrays, [strip, 0, 4])]),
            ("a stride of 2^31 - 1", [(Op.vertexAttribPointer, [0, 2, float, 0, 0x7fff_ffff, 0]), (Op.drawArrays, [strip, 0, 4])]),
            ("a stride of 2^31 - 1 through indices", [(Op.vertexAttribPointer, [0, 2, float, 0, 0x7fff_ffff, 0]), (Op.drawElements, [strip, 4, ushort, 0])]),
            ("GL_FIXED past its buffer", [(Op.vertexAttribPointer, [0, 3, .u(GL.FIXED), 0, 0, 0]), (Op.drawArrays, [strip, 0, 4])]),
            ("an odd stride past its buffer", [(Op.vertexAttribPointer, [0, 2, float, 0, 9, 3]), (Op.drawArrays, [strip, 0, 4])]),
            ("indices with the draw that name a fifth vertex", [(Op.drawElementsClient, [strip, 4, .u(GL.UNSIGNED_BYTE), .data(Data([0, 1, 2, 4]))])]),
            ("indices with the draw of 2^32 - 1", [(Op.drawElementsClient, [strip, 3, .u(GL.UNSIGNED_INT), .names([0, 1, 0xffff_ffff])])]),
            ("fewer indices with the draw than counted", [(Op.drawElementsClient, [strip, 4, ushort, .data(Data(count: 6))])]),
            ("an array with the draw that ends before the last vertex", [(Op.clientArray, [0, 2, float, 0, 0, .floats([0, 0, 1, 1])]), (Op.drawArrays, [strip, 0, 4])]),
            ("an array with the draw that begins after the first vertex", [(Op.clientArray, [0, 2, float, 0, 2, .floats(Rig.whole)]), (Op.drawArrays, [strip, 0, 4])]),
            ("an array with the draw that is no whole number of vertices", [(Op.clientArray, [0, 3, float, 0, 0, .floats(Rig.whole)])]),
        ]
        for (what, commands) in draws {
            rig.send(Op.vertexAttribPointer, 0, 2, float, 0, 0, 0)
            for (op, arguments) in commands { rig.feed(command(op, arguments)) }
            let error = rig.error()
            XCTAssertTrue(error == GL.INVALID_OPERATION || (what == "2^31 - 1 vertices" && error == GL.OUT_OF_MEMORY), "\(what): \(String(error, radix: 16))")
        }
        XCTAssertEqual(rig.pixel(8, 8), nothing, "none of them drew")
        // A buffer deleted is bound no more: the array has nothing behind it.
        rig.send(Op.deleteBuffers, 1, .names([elements]))
        rig.send(Op.drawArrays, strip, 0, 4)
        rig.expectNoError()
        rig.send(Op.deleteBuffers, 1, .names([vertices]))
        rig.send(Op.drawArrays, strip, 0, 4)
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
        // And one that is all there draws, after all that.
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.array(0, size: 2, Rig.whole)
        rig.send(Op.drawArrays, strip, 0, 4)
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), red)
    }

    /// What a stream can have the Mac keep is bounded: buffers at 256 MiB
    /// in all, textures and renderbuffers at 512 MiB and 4096 a side.
    /// Past the bound is GL_OUT_OF_MEMORY and nothing changes.
    func testBuffersAndTexturesPastTheBoundsAreOutOfMemory() throws {
        let rig = try Rig()
        // Buffers of 64 MiB with no data: four fit, a fifth does not.
        for index in 0..<5 {
            rig.send(Op.bindBuffer, .u(GL.ARRAY_BUFFER), .i(index + 1))
            rig.send(Op.bufferData, .u(GL.ARRAY_BUFFER), .i(64 << 20), .u(GL.STATIC_DRAW), .data(nil))
            XCTAssertEqual(rig.error(), index < 4 ? GL.NO_ERROR : GL.OUT_OF_MEMORY, "buffer \(index)")
        }
        XCTAssertEqual(rig.stream.budget.bufferBytes, 256 << 20)
        rig.send(Op.bufferData, .u(GL.ARRAY_BUFFER), 0x7fff_ffff, .u(GL.STATIC_DRAW), .data(nil))
        XCTAssertEqual(rig.error(), GL.OUT_OF_MEMORY)
        // One made smaller makes room; deleted, they give back what they held.
        rig.send(Op.bindBuffer, .u(GL.ARRAY_BUFFER), 1)
        rig.send(Op.bufferData, .u(GL.ARRAY_BUFFER), 16, .u(GL.STATIC_DRAW), .data(nil))
        rig.send(Op.bindBuffer, .u(GL.ARRAY_BUFFER), 5)
        rig.send(Op.bufferData, .u(GL.ARRAY_BUFFER), .i(32 << 20), .u(GL.STATIC_DRAW), .data(nil))
        rig.expectNoError()
        rig.send(Op.deleteBuffers, 5, .names([1, 2, 3, 4, 5]))
        XCTAssertEqual(rig.stream.budget.bufferBytes, 0)

        // Textures of 4096 × 4096 with no pixels, 64 MiB each: eight fit.
        let flat = Arg.u(GL.TEXTURE_2D), rgba = Arg.u(GL.RGBA), byte = Arg.u(GL.UNSIGNED_BYTE)
        for index in 0..<9 {
            rig.send(Op.bindTexture, flat, .i(index + 1))
            rig.send(Op.texImage2D, flat, 0, rgba, 4096, 4096, 0, rgba, byte, .data(nil))
            XCTAssertEqual(rig.error(), index < 8 ? GL.NO_ERROR : GL.OUT_OF_MEMORY, "texture \(index)")
        }
        XCTAssertEqual(rig.stream.budget.textureBytes, 512 << 20)
        // Smaller levels are memory too: there is none left for them.
        rig.send(Op.bindTexture, flat, 1)
        rig.send(Op.generateMipmap, flat)
        XCTAssertEqual(rig.error(), GL.OUT_OF_MEMORY)
        rig.send(Op.bindRenderbuffer, .u(GL.RENDERBUFFER), 1)
        rig.send(Op.renderbufferStorage, .u(GL.RENDERBUFFER), .u(GL.RGBA4), 16, 16)
        XCTAssertEqual(rig.error(), GL.OUT_OF_MEMORY, "a renderbuffer is a texture's kind of memory")
        for (width, height) in [(4097, 1), (1, 4097), (0x7fff_ffff, 0x7fff_ffff), (65536, 65536)] {
            rig.send(Op.texImage2D, flat, 0, rgba, .i(width), .i(height), 0, rgba, byte, .data(nil))
            XCTAssertEqual(rig.error(), GL.INVALID_VALUE, "\(width) × \(height)")
        }
        // A texture given again at another size gives back what it held.
        rig.send(Op.texImage2D, flat, 0, rgba, 16, 16, 0, rgba, byte, .data(nil))
        rig.send(Op.renderbufferStorage, .u(GL.RENDERBUFFER), .u(GL.RGBA4), 16, 16)
        rig.expectNoError()
        rig.send(Op.deleteTextures, 9, .names((1...9).map { UInt32($0) }))
        rig.send(Op.deleteRenderbuffers, 1, .names([1]))
        XCTAssertEqual(rig.stream.budget.textureBytes, 0)

        // Surfaces: 1 GiB in all. One of 4096 × 4096 with depth and stencil is 192 MiB while it has one picture: five fit.
        for index in 0..<6 {
            rig.send(Op.surfaceCreate, .i(index + 10), 4096, 4096, 1, 1, 1)
            XCTAssertEqual(rig.error(), index < 5 ? GL.NO_ERROR : GL.OUT_OF_MEMORY, "surface \(index)")
        }
        XCTAssertEqual(rig.stream.budget.surfaceBytes, 5 * (192 << 20) + 16 * 16 * (4 + 8))
        // A second picture of one of them is 64 MiB more than there is: its picture is drawn into again though it is in use.
        rig.keeps = 1
        rig.send(Op.swap, 10)
        rig.send(Op.swap, 10)
        rig.expectNoError()
        XCTAssertEqual(rig.presented.count, 2)
        XCTAssertTrue(rig.presented[0].picture === rig.presented[1].picture)
        XCTAssertEqual(rig.stream.budget.surfaceBytes, 5 * (192 << 20) + 16 * 16 * (4 + 8))
        // With room for it, it has another.
        rig.send(Op.surfaceDestroy, 14)
        rig.send(Op.swap, 10)
        rig.send(Op.swap, 10)
        XCTAssertFalse(rig.presented[3].picture === rig.presented[2].picture)
        XCTAssertEqual(rig.stream.budget.surfaceBytes, 4 * (192 << 20) + (64 << 20) + 16 * 16 * (4 + 8))
        for index in 0..<6 { rig.send(Op.surfaceDestroy, .i(index + 10)) }
        XCTAssertEqual(rig.stream.budget.surfaceBytes, 16 * 16 * (4 + 8))
        // Shaders' texts: 16 MiB in all.
        let shader = rig.name()
        rig.send(Op.createShader, .u(shader), .u(GL.VERTEX_SHADER))
        rig.send(Op.shaderSource, .u(shader), .data(Data(repeating: 32, count: 16 << 20)))
        rig.expectNoError()
        rig.send(Op.shaderSource, .u(shader), .data(Data(repeating: 32, count: (16 << 20) + 1)))
        XCTAssertEqual(rig.error(), GL.OUT_OF_MEMORY)
        rig.send(Op.deleteShader, .u(shader))
        XCTAssertEqual(rig.stream.budget.sourceBytes, 0)
    }

    /// A million names bound make no million objects: past the bound a
    /// name is GL_OUT_OF_MEMORY, and names deleted make room again.
    func testAMillionNamesAreBounded() throws {
        let rig = try Rig()
        var stream = Data()
        for name in 1...1_000_000 {
            switch name % 4 {
            case 0: stream.append(command(Op.bindBuffer, [.u(GL.ARRAY_BUFFER), .i(name)]))
            case 1: stream.append(command(Op.bindTexture, [.u(GL.TEXTURE_2D), .i(name)]))
            case 2: stream.append(command(Op.bindFramebuffer, [.u(GL.FRAMEBUFFER), .i(name)]))
            default: stream.append(command(Op.createShader, [.i(name), .u(GL.VERTEX_SHADER)]))
            }
        }
        rig.feed(stream)
        XCTAssertEqual(rig.error(), GL.OUT_OF_MEMORY)
        XCTAssertEqual(rig.stream.budget.objects, GLLimits.objects)
        rig.send(Op.deleteBuffers, 4, .names([4, 8, 12, 16]))
        rig.send(Op.bindRenderbuffer, .u(GL.RENDERBUFFER), 7)
        rig.send(Op.createProgram, 2_000_000)
        rig.expectNoError()
        // Contexts and surfaces are bounded too.
        for name in 2...200 {
            rig.send(Op.contextCreate, .i(name), 0)
            rig.send(Op.surfaceCreate, .i(name), 1, 1, 1, 1, 1)
        }
        XCTAssertEqual(rig.stream.contexts.count, GLLimits.contexts)
        XCTAssertEqual(rig.stream.surfaces.count, GLLimits.surfaces)
        rig.stream.close()
        XCTAssertEqual(rig.stream.budget.objects, 0, "closed, everything is let go")
        XCTAssertEqual(rig.stream.budget.surfaceBytes, 0)
    }

    /// A program that draws on and on without a swap does not have the
    /// Mac hold all of it: what the draws need is let go as they are done.
    func testDrawingWithoutEndIsDoneAsItComes() throws {
        let rig = try Rig()
        rig.program("color")
        rig.send(Op.enableVertexAttribArray, 0)
        rig.send(Op.enableVertexAttribArray, 1)
        // 1 MiB of colours a draw, three hundred times: far more than a command buffer may hold on to.
        let colors = Data(repeating: 255, count: 1 << 20), count = (1 << 20) / 4
        var positions = [Float](repeating: -1, count: count * 2)
        positions.replaceSubrange(0..<8, with: Rig.whole)
        var stream = Data(), highest = 0
        for _ in 0..<300 {
            stream.append(command(Op.clientArray, [0, 2, .u(GL.FLOAT), 0, 0, .floats(positions)]))
            stream.append(command(Op.clientArray, [1, 4, .u(GL.UNSIGNED_BYTE), 1, 0, .data(colors)]))
            stream.append(command(Op.drawArrays, [.u(GL.TRIANGLE_STRIP), 0, .i(count)]))
            rig.feed(stream)
            stream.removeAll(keepingCapacity: true)
            highest = max(highest, rig.stream.arena.pending)
        }
        XCTAssertLessThanOrEqual(highest, GLLimits.pendingBytes + (8 << 20))
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), white)
    }

    /// A few thousand streams of commands made up at random, from a seed:
    /// whole commands with arguments drawn from what OpenGL has and from
    /// what it has not, and now and then one cut short or padded. `feed`
    /// returns, every answered command is answered, nothing crashes.
    /// MONAD_GL_SOUP_SEED in the environment makes another soup, to look
    /// further than this one does; a soup that crashed is made again from
    /// its seed.
    func testARandomSoupOfCommandsCrashesNothing() throws {
        let seed = ProcessInfo.processInfo.environment["MONAD_GL_SOUP_SEED"].flatMap { UInt64($0) } ?? 0x6d6f_6e61_6467_6c31
        var random = Soup(seed: seed)
        for stream in 0..<3000 {
            let rig = try Rig(size: nil)
            // The pictures a stream shows are let go of at once, or held as a window holds them, or all of them for good.
            rig.keeps = [0, 1, 3, 100][stream % 4]
            var expected = 0
            // Every fourth stream has programs to draw with, so that draws get as far as Metal.
            var bytes = Soup.opening(programs: stream % 4 == 0, answers: &expected)
            for _ in 0..<(stream % 4 == 0 ? 150 : 40) {
                bytes.append(random.call(answers: &expected))
            }
            bytes.append(command(Op.finish, []))
            expected += 1
            XCTAssertTrue(rig.stream.feed(bytes), "stream \(stream) goes on")
            XCTAssertEqual(rig.answers.count, expected, "stream \(stream): an answer for every command that has one")
            for answer in rig.answers {
                XCTAssertEqual(answer.count % 4, 0)
                XCTAssertEqual(answer.prefix(4), word(UInt32(answer.count - 4)))
            }
            rig.stream.close()
            XCTAssertEqual(rig.stream.budget.objects, 0, "stream \(stream)")
            XCTAssertEqual(rig.stream.budget.bufferBytes, 0, "stream \(stream)")
            XCTAssertEqual(rig.stream.budget.textureBytes, 0, "stream \(stream)")
            XCTAssertEqual(rig.stream.budget.surfaceBytes, 0, "stream \(stream)")
        }
    }

    /// Bytes made up at random, no commands at all: `feed` returns, and
    /// once it has said the stream is over it goes on saying so.
    func testRandomBytesEndTheStreamAndNothingElse() throws {
        var random = Soup(seed: 42)
        for _ in 0..<300 {
            let rig = try Rig()
            var over = false
            for _ in 0..<20 {
                var bytes = Data((0..<Int(random.next() % 64)).map { _ in UInt8(truncatingIfNeeded: random.next()) })
                // Now and then a header that could be one, so that what follows is read as its arguments.
                if random.next() % 3 == 0 { bytes = word(UInt32(random.next() % 110)) + word(UInt32(8 + 4 * (random.next() % 12))) + bytes }
                let goesOn = rig.stream.feed(bytes)
                XCTAssertFalse(over && goesOn)
                over = !goesOn
            }
        }
    }

    // MARK: More of what a program may do

    /// A texture whose first level is given anew keeps its other levels:
    /// those that no longer agree make it incomplete, and when the first
    /// level agrees with them again they are what they were.
    func testATextureGivenAnewKeepsItsOtherLevels() throws {
        let rig = try Rig()
        rig.program("texture")
        let texture = rig.name()
        rig.send(Op.bindTexture, .u(GL.TEXTURE_2D), .u(texture))
        rig.send(Op.texParameteri, .u(GL.TEXTURE_2D), .u(GL.TEXTURE_MIN_FILTER), .u(GL.NEAREST_MIPMAP_NEAREST))
        func level(_ level: Int, _ width: Int, _ height: Int, _ color: [UInt8]) {
            var pixels = Data()
            for _ in 0..<width * height { pixels.append(contentsOf: color) }
            rig.send(Op.texImage2D, .u(GL.TEXTURE_2D), .i(level), .u(GL.RGBA), .i(width), .i(height), 0, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE), .data(pixels))
        }
        /// Drawn at half its size, so that its second level is the one read.
        func half(_ width: Int, _ height: Int) -> [UInt8] {
            rig.send(Op.viewport, 0, 0, .i(width / 2), .i(height / 2))
            rig.textured()
            return rig.pixel(0, 0)
        }
        level(0, 4, 4, red)
        level(1, 2, 2, green)
        level(2, 1, 1, blue)
        XCTAssertEqual(half(4, 4), green)
        level(0, 8, 8, white)
        XCTAssertEqual(half(8, 8), black, "a second level of 2 × 2 is not one of a first of 8 × 8")
        level(0, 4, 4, red)
        XCTAssertEqual(half(4, 4), green, "it is one of 4 × 4, and still green")
        // A first level twice as wide whose smaller levels are the same sizes as before: 1 × 4 has 1 × 2 and 1 × 1, and so has 2 × 4.
        let narrow = rig.name()
        rig.send(Op.bindTexture, .u(GL.TEXTURE_2D), .u(narrow))
        rig.send(Op.texParameteri, .u(GL.TEXTURE_2D), .u(GL.TEXTURE_MIN_FILTER), .u(GL.NEAREST_MIPMAP_NEAREST))
        level(0, 1, 4, red)
        level(1, 1, 2, green)
        level(2, 1, 1, blue)
        level(0, 2, 4, white)
        XCTAssertEqual(half(2, 4), green, "the levels that still agree are the texture's still")
        // No pixels at all: no first level, and nothing to read.
        level(0, 0, 0, white)
        rig.expectNoError()
        XCTAssertEqual(half(2, 4), black)
    }

    /// A vertex function reads a texture too, at the Metal index its sampler uniform has.
    func testAVertexFunctionReadsATexture() throws {
        let rig = try Rig()
        rig.program("vertexTexture")
        rig.texture(width: 1, height: 1, Data([0, 255, 255, 255]))
        rig.array(0, size: 2, Rig.whole)
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), [0, 255, 255, 255])
        rig.send(Op.bindTexture, .u(GL.TEXTURE_2D), 0)
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        XCTAssertEqual(rig.pixel(8, 8), black, "no texture: opaque black")
    }

    /// Depth and stencil renderbuffers in every arrangement OpenGL ES 2.0
    /// has: each its own, the two as one, one without the other, and
    /// neither. The tests test against what there is, and pass where
    /// there is nothing.
    func testDepthAndStencilRenderbuffersInEveryArrangement() throws {
        let rig = try Rig()
        rig.program("flat")
        func renderbuffer(_ format: UInt32) -> UInt32 {
            let renderbuffer = rig.name()
            rig.send(Op.bindRenderbuffer, .u(GL.RENDERBUFFER), .u(renderbuffer))
            rig.send(Op.renderbufferStorage, .u(GL.RENDERBUFFER), .u(format), 16, 16)
            return renderbuffer
        }
        let color = renderbuffer(GL.RGBA8_OES), depth = renderbuffer(GL.DEPTH_COMPONENT24_OES), stencil = renderbuffer(GL.STENCIL_INDEX8)
        let packed = renderbuffer(GL.DEPTH24_STENCIL8_OES)
        let framebuffer = rig.name()
        rig.send(Op.bindFramebuffer, .u(GL.FRAMEBUFFER), .u(framebuffer))
        rig.send(Op.enable, .u(GL.DEPTH_TEST))
        rig.send(Op.enable, .u(GL.STENCIL_TEST))
        rig.send(Op.stencilOp, .u(GL.KEEP), .u(GL.KEEP), .u(GL.REPLACE))
        let arrangements: [(String, UInt32, UInt32, UInt32, Bool, Bool)] = [
            ("each its own", color, depth, stencil, true, true), ("the two as one", color, packed, packed, true, true),
            ("depth alone", color, depth, 0, true, false), ("stencil alone", color, 0, stencil, false, true),
            ("the depth of the two as one", color, packed, 0, true, false), ("the stencil of the two as one", color, 0, packed, false, true),
            ("neither", color, 0, 0, false, false), ("no colour", 0, depth, stencil, true, true),
        ]
        for (what, colorName, depthName, stencilName, hasDepth, hasStencil) in arrangements {
            for (attachment, name) in [(GL.COLOR_ATTACHMENT0, colorName), (GL.DEPTH_ATTACHMENT, depthName), (GL.STENCIL_ATTACHMENT, stencilName)] {
                rig.send(Op.framebufferRenderbuffer, .u(GL.FRAMEBUFFER), .u(attachment), .u(GL.RENDERBUFFER), .u(name))
            }
            var status = rig.ask(Op.checkFramebufferStatus, .u(GL.FRAMEBUFFER))
            XCTAssertEqual(status.word(), GL.FRAMEBUFFER_COMPLETE, what)
            rig.send(Op.disable, .u(GL.SCISSOR_TEST))
            rig.send(Op.clearColor, 0.0, 0.0, 0.0, 1.0)
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT | GL.DEPTH_BUFFER_BIT | GL.STENCIL_BUFFER_BIT))
            // A clear of a part, which is drawn: the left half's depth becomes 0, its stencil 5.
            rig.send(Op.enable, .u(GL.SCISSOR_TEST))
            rig.send(Op.scissor, 0, 0, 8, 16)
            rig.send(Op.clearDepthf, 0.0)
            rig.send(Op.clearStencil, 5)
            rig.send(Op.clear, .u(GL.DEPTH_BUFFER_BIT | GL.STENCIL_BUFFER_BIT))
            rig.send(Op.clearDepthf, 1.0)
            rig.send(Op.clearStencil, 0)
            rig.send(Op.disable, .u(GL.SCISSOR_TEST))
            // Red where the depth lets it, with the stencil left as it is: on the left it lies behind the depth cleared
            // to 0, if there is depth.
            rig.send(Op.stencilFunc, .u(GL.ALWAYS), 0, 0xff)
            rig.send(Op.stencilMask, 0)
            rig.rectangle(z: 0, color: [1, 0, 0, 1])
            if colorName != 0 {
                XCTAssertEqual(rig.pixel(3, 8), hasDepth ? black : red, "\(what): the depth test, left")
                XCTAssertEqual(rig.pixel(12, 8), red, "\(what): the depth test, right")
            }
            // Then green where the stencil is 5: on the left, and on the right too if there is no stencil to say otherwise.
            rig.send(Op.stencilMask, 0xff)
            rig.send(Op.stencilFunc, .u(GL.EQUAL), 5, 0xff)
            rig.send(Op.depthFunc, .u(GL.ALWAYS))
            rig.rectangle(z: 0, color: [0, 1, 0, 1])
            rig.send(Op.depthFunc, .u(GL.LESS))
            rig.expectNoError()
            guard colorName != 0 else {
                _ = rig.ask(Op.readPixels, 0, 0, 1, 1, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE))
                XCTAssertEqual(rig.lastAnswer, word(0))
                XCTAssertEqual(rig.error(), GL.INVALID_OPERATION, "nothing to read where there is no colour")
                continue
            }
            XCTAssertEqual(rig.pixel(3, 8), green, "\(what): the stencil test, left")
            XCTAssertEqual(rig.pixel(12, 8), hasStencil ? red : green, "\(what): the stencil test, right")
        }
    }

    /// A buffer too large to be kept twice is not copied when it is
    /// changed while draws still read it: the draws are done first, and
    /// each still shows what the buffer was when it was drawn.
    func testALargeBufferChangedBetweenDrawsIsDrawnFirst() throws {
        let rig = try Rig()
        rig.program("flat")
        rig.send(Op.uniform4f, 0, 1.0, 1.0, 1.0, 1.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        let buffer = rig.name()
        rig.send(Op.bindBuffer, .u(GL.ARRAY_BUFFER), .u(buffer))
        rig.send(Op.bufferData, .u(GL.ARRAY_BUFFER), .i(65 << 20), .u(GL.DYNAMIC_DRAW), .data(nil))
        rig.send(Op.vertexAttribPointer, 0, 2, .u(GL.FLOAT), 0, 0, 0)
        rig.send(Op.enableVertexAttribArray, 0)
        rig.send(Op.bufferSubData, .u(GL.ARRAY_BUFFER), 0, .floats([-1, -1, 0, -1, -1, 0, 0, 0]))
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        rig.send(Op.bufferSubData, .u(GL.ARRAY_BUFFER), 0, .floats([0, 0, 1, 0, 0, 1, 1, 1]))
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        rig.expectNoError()
        XCTAssertEqual(rig.stream.budget.bufferBytes, 65 << 20, "one buffer, not two")
        let read = rig.read()
        XCTAssertEqual(read[3][3], white)
        XCTAssertEqual(read[12][12], white)
        XCTAssertEqual(read[3][12], nothing)
    }

    /// Passes and draws without number and without a swap are sent to
    /// the GPU in parts, and waited for: the Mac does not keep them all
    /// until the program swaps, and Metal is never handed more passes at
    /// once than it takes. (It takes some 25,000 in a command buffer; one
    /// with more fails, and after it every command buffer of the process
    /// does: were this to fail, the tests after it would too.)
    func testPassesAndDrawsWithoutNumberAreSentOffInParts() throws {
        let rig = try Rig()
        rig.program("flat")
        rig.send(Op.uniform4f, 0, 0.0, 1.0, 0.0, 1.0)
        rig.array(0, size: 2, Rig.whole)
        let draw = command(Op.drawArrays, [.u(GL.TRIANGLE_STRIP), 0, 4]), clear = command(Op.clear, [.u(GL.COLOR_BUFFER_BIT)])
        /// Feeds `count` commands in pieces, to look in between, and gives the most passes and draws that waited at once.
        func feed(_ count: Int, _ next: (Int) -> Data) -> (passes: Int, draws: Int) {
            var stream = Data(), highest = (passes: 0, draws: 0)
            for index in 0..<count {
                stream.append(next(index))
                if stream.count >= 1 << 12 || index == count - 1 {
                    XCTAssertTrue(rig.stream.feed(stream))
                    stream.removeAll(keepingCapacity: true)
                    highest = (max(highest.passes, rig.stream.passes), max(highest.draws, rig.stream.encoded))
                }
            }
            return highest
        }
        // A clear of everything begins a pass: 40,000 passes, each with a draw.
        let passes = feed(80_000) { $0 % 2 == 0 ? clear : draw }
        XCTAssertLessThanOrEqual(passes.passes, GLLimits.passes + 4)
        XCTAssertGreaterThan(passes.passes, GLLimits.passes / 2, "and no fewer at once than there may be")
        XCTAssertEqual(rig.pixel(8, 8), green)
        // 200,000 draws in one pass.
        let draws = feed(200_000) { _ in draw }
        XCTAssertLessThanOrEqual(draws.draws, GLLimits.draws + 4)
        XCTAssertGreaterThan(draws.draws, GLLimits.draws / 2)
        XCTAssertEqual(rig.pixel(8, 8), green)
        // Textures made and thrown away: each is a pass of its own, which clears it.
        let textures = feed(40_000) {
            command($0 % 2 == 0 ? Op.bindTexture : Op.texImage2D,
                    $0 % 2 == 0 ? [.u(GL.TEXTURE_2D), .i(1 + $0 % 16)] : [.u(GL.TEXTURE_2D), 0, .u(GL.RGBA), .i(1 + $0 % 7), 2, 0, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE), .data(nil)])
        }
        XCTAssertLessThanOrEqual(textures.passes, GLLimits.passes + 4)
        rig.expectNoError()
        XCTAssertTrue(rig.stream.feed(command(Op.finish, [])), "the GPU did all of it")
    }

    /// The names glBindAttribLocation gives a program are bounded in
    /// number and in length, and count against the bound on shaders' text.
    func testAttributeNamesAreBounded() throws {
        let rig = try Rig()
        let program = rig.program("flat")
        for index in 0..<300 {
            rig.send(Op.bindAttribLocation, .u(program), .i(index % 16), .text("attribute\(index)"))
        }
        XCTAssertEqual(rig.error(), GL.OUT_OF_MEMORY)
        rig.send(Op.bindAttribLocation, .u(program), 1, .text("attribute7"))
        rig.expectNoError()
        rig.send(Op.bindAttribLocation, .u(program), 1, .text(String(repeating: "a", count: 1025)))
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE)
        XCTAssertGreaterThan(rig.stream.budget.sourceBytes, 0)
        rig.send(Op.useProgram, 0)
        rig.send(Op.deleteProgram, .u(program))
        rig.send(Op.deleteShader, .u(program + 1))
        rig.send(Op.deleteShader, .u(program + 2))
        XCTAssertEqual(rig.stream.budget.sourceBytes, 0)
        XCTAssertEqual(rig.stream.budget.executables, 0)
    }

    // MARK: What the library and the translator hold to

    /// The wire header, found from this file's own path.
    private static var wireHeader: URL {
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("GuestWM/mwm_gl_wire.h")
    }

    /// Every command the header has is carried out when it is as the
    /// header says: the stream goes on, OpenGL has no error, the ones
    /// marked answered are answered once and the others not at all. The
    /// header itself is read, so a command added to it and not to
    /// GLStream, or not to this walk, is a test that fails.
    func testEveryCommandOfTheHeaderIsCarriedOut() throws {
        let header = try String(contentsOf: Self.wireHeader, encoding: .utf8)
        // A command's mark begins "answered" and may say more ("answered, read late: see above").
        let line = try NSRegularExpression(pattern: #"MGL_[A-Z0-9_]+ = ([0-9]+),( /\* answered[^*]*\*/)?"#)
        var ops = Set<UInt32>(), answered = Set<UInt32>()
        for match in line.matches(in: header, range: NSRange(header.startIndex..., in: header)) {
            guard let digits = Range(match.range(at: 1), in: header), let op = UInt32(header[digits]) else { continue }
            ops.insert(op)
            if match.range(at: 2).location != NSNotFound { answered.insert(op) }
        }
        XCTAssertGreaterThan(ops.count, 90, "the header's commands were found")
        XCTAssertEqual(ops.max(), Op.viewport, "MGL_OP_LAST")
        XCTAssertEqual(answered, Op.answered, "the commands the header marks as answered")
        XCTAssertEqual(Set(everyCommand.map(\.op)), ops, "the walk has every command of the header and no other")

        let rig = try Rig(size: nil)
        for (op, arguments) in everyCommand {
            let before = rig.answers.count
            XCTAssertTrue(rig.stream.feed(command(op, arguments)), "op \(op): the stream goes on")
            XCTAssertEqual(rig.answers.count - before, answered.contains(op) ? 1 : 0, "op \(op) is answered when the header says so, and only then")
            if rig.stream.current != nil { XCTAssertEqual(rig.error(), GL.NO_ERROR, "op \(op) is no error") }
        }
        // And they did what they say: the picture drawn was shown, white from the uniform that was set, and all is let go.
        XCTAssertEqual(rig.presented.count, 1)
        XCTAssertEqual(rig.presented.last?.width, 16, "the surface was resized")
        XCTAssertEqual(try Rig.pixels(XCTUnwrap(rig.presented.last?.picture))[8][8], white)
        XCTAssertTrue(rig.stream.contexts.isEmpty)
        XCTAssertTrue(rig.stream.surfaces.isEmpty)
        XCTAssertEqual(rig.stream.budget.bufferBytes, 0)
        XCTAssertEqual(rig.stream.budget.textureBytes, 0)
    }

    /// MakeCurrent(0, 0, 0) is the library letting go of the stream's
    /// context. With none current, OpenGL's calls do nothing, whether
    /// they are as the header says or not, and those that are answered
    /// are answered with nothing: no error, no status, not compiled, not
    /// linked, no pixels, no value. The context is as it was when it is
    /// current again.
    func testWithNoContextCurrentCallsDoNothingAndAreAnsweredWithNothing() throws {
        let rig = try Rig()
        rig.program("flat")
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        let objects = rig.stream.budget.objects, source = rig.stream.budget.sourceBytes
        rig.send(Op.makeCurrent, 0, 0, 0)
        XCTAssertNil(rig.stream.current)
        rig.send(Op.makeCurrent, 0, 0, 0)
        let empty: [UInt32: Data] = [
            Op.getError: word(4) + word(GL.NO_ERROR), Op.checkFramebufferStatus: word(4) + word(0), Op.finish: word(0),
            Op.compileShader: word(8) + word(0) + word(0), Op.linkProgram: word(16) + word(0) + word(0) + word(0) + word(0),
            Op.readPixels: word(0), Op.getUniform: word(8) + word(0) + word(0),
        ]
        for (op, arguments) in everyCommand where op >= Op.activeTexture {
            // As the header says, with a word too many, and with its last argument missing.
            for data in [command(op, arguments), command(op, arguments + [7]), command(op, Array(arguments.dropLast()))] {
                let before = rig.answers.count
                XCTAssertTrue(rig.stream.feed(data), "op \(op): the stream goes on")
                XCTAssertEqual(Array(rig.answers[before...]), empty[op].map { [$0] } ?? [], "op \(op)")
            }
        }
        XCTAssertEqual(rig.stream.budget.objects, objects, "nothing was made")
        XCTAssertEqual(rig.stream.budget.sourceBytes, source)
        XCTAssertEqual(rig.stream.budget.bufferBytes, 0)
        XCTAssertEqual(rig.stream.budget.textureBytes, 0)
        // A swap is not the context's: the surface's picture is shown as it is.
        XCTAssertEqual(rig.swap()[8][8], nothing)
        rig.send(Op.makeCurrent, 1, 1, 1)
        rig.expectNoError()
        rig.rectangle(color: [0, 1, 0, 1])
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), green, "current again, it draws with the program it had")
    }

    /// glReadPixels and glGetUniform answer with exactly the bytes that
    /// were asked for, or, when OpenGL has an error instead, in the one
    /// way the header has for that: glReadPixels with an answer of no
    /// length at all, glGetUniform with the type 0 and data of no bytes.
    /// The library takes those for "the Mac has the error" and
    /// any other count for a stream gone wrong, which it then drops.
    func testReadPixelsAndGetUniformAnswerInFullOrNotAtAll() throws {
        let rig = try Rig()
        let rgba = Arg.u(GL.RGBA), byte = Arg.u(GL.UNSIGNED_BYTE)
        rig.send(Op.clearColor, 1.0, 0.0, 0.0, 1.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        // In full: inside what was drawn to, across its edges, and nowhere near it.
        let rectangles = [(0, 0, 16, 16), (-5, -5, 7, 3), (14, 14, 5, 9), (100, 100, 2, 2), (-100, -100, 3, 1), (0, 0, 1, 4096),
                          (0x7fff_ffff, 0x7fff_ffff, 2, 2), (-0x8000_0000, -0x8000_0000, 1, 1)]
        for (x, y, width, height) in rectangles {
            var answer = rig.ask(Op.readPixels, .i(x), .i(y), .i(width), .i(height), rgba, byte)
            XCTAssertEqual(answer.data().count, width * height * 4, "\(width) × \(height) at \(x), \(y)")
            XCTAssertEqual(answer.at, answer.bytes.count, "and nothing after the pixels")
            rig.expectNoError()
        }
        // The most there is to ask for is the largest answer there is.
        var largest = rig.ask(Op.readPixels, 0, 0, 4096, 4096, rgba, byte)
        let pixels = largest.data()
        XCTAssertEqual(pixels.count, 64 << 20)
        XCTAssertLessThanOrEqual(rig.lastAnswer.count - 4, GLLimits.reply)
        XCTAssertEqual(Array(pixels[(15 * 4096 + 15) * 4..<(15 * 4096 + 16) * 4]), red)
        XCTAssertEqual(Array(pixels[(15 * 4096 + 16) * 4..<(15 * 4096 + 17) * 4]), nothing)
        XCTAssertEqual(Array(pixels.suffix(4)), nothing)
        rig.expectNoError()

        // Not at all: an answer of length 0, with nothing after its length.
        let framebuffer = rig.name()
        let refused: [(String, [(UInt32, [Arg])], [Arg], UInt32)] = [
            ("a format that is none", [], [0, 0, 1, 1, .u(GL.DEPTH_COMPONENT), byte], GL.INVALID_ENUM),
            ("a width below zero", [], [0, 0, -1, 1, rgba, byte], GL.INVALID_VALUE),
            ("a width past the largest", [], [0, 0, 4097, 1, rgba, byte], GL.INVALID_VALUE),
            ("a format that is not read", [], [0, 0, 1, 1, .u(GL.RGB), byte], GL.INVALID_OPERATION),
            ("no surface to read", [(Op.makeCurrent, [1, 1, 0])], [0, 0, 1, 1, rgba, byte], GL.INVALID_FRAMEBUFFER_OPERATION),
            ("a framebuffer with nothing attached", [(Op.bindFramebuffer, [.u(GL.FRAMEBUFFER), .u(framebuffer)])], [0, 0, 1, 1, rgba, byte],
             GL.INVALID_FRAMEBUFFER_OPERATION),
        ]
        for (what, before, arguments, expected) in refused {
            for (op, arguments) in before { rig.feed(command(op, arguments)) }
            rig.expectNoError()
            let answers = rig.answers.count
            rig.feed(command(Op.readPixels, arguments))
            XCTAssertEqual(Array(rig.answers[answers...]), [word(0)], what)
            XCTAssertEqual(rig.error(), expected, what)
        }
        rig.send(Op.bindFramebuffer, .u(GL.FRAMEBUFFER), 0)
        rig.send(Op.makeCurrent, 1, 1, 1)

        // A uniform's value is as many numbers as its type has, each four bytes.
        let program = rig.program("uniforms")
        for uniform in Programs.uniforms.uniforms {
            for element in 0..<uniform.size {
                var answer = rig.ask(Op.getUniform, .u(program), .i(uniform.location + element))
                XCTAssertEqual(answer.word(), uniform.type, uniform.name)
                XCTAssertEqual(answer.data().count, uniform.columns * uniform.rows * 4, uniform.name)
                XCTAssertEqual(answer.at, answer.bytes.count, "and nothing after the value")
            }
        }
        let sampler = rig.program("texture")
        _ = rig.ask(Op.getUniform, .u(sampler), 0)
        XCTAssertEqual(rig.lastAnswer, word(12) + word(GL.SAMPLER_2D) + word(4) + word(0), "a sampler's value is its texture unit, one int")
        rig.expectNoError()
        let unlinked = rig.name()
        rig.send(Op.createProgram, .u(unlinked))
        let none: [(String, UInt32, Int, UInt32)] = [
            ("a location past an array's end", program, 19, GL.INVALID_OPERATION), ("location -1", program, -1, GL.INVALID_OPERATION),
            ("a location of 2^31 - 1", program, 0x7fff_ffff, GL.INVALID_OPERATION), ("a program that did not link", unlinked, 0, GL.INVALID_OPERATION),
            ("a shader's name", program + 1, 0, GL.INVALID_OPERATION), ("no program's name", 4242, 0, GL.INVALID_VALUE),
            ("the name 0", 0, 0, GL.INVALID_VALUE),
        ]
        for (what, name, location, expected) in none {
            _ = rig.ask(Op.getUniform, .u(name), .i(location))
            XCTAssertEqual(rig.lastAnswer, word(8) + word(0) + word(0), what)
            XCTAssertEqual(rig.error(), expected, what)
        }
        // The same two answers when the command itself is not as the header says.
        _ = rig.ask(Op.readPixels, 0, 0, 1, 1, rgba)
        XCTAssertEqual(rig.lastAnswer, word(0), "glReadPixels with an argument missing")
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
        _ = rig.ask(Op.readPixels, 0, 0, 1, 1, rgba, byte, 7)
        XCTAssertEqual(rig.lastAnswer, word(0), "glReadPixels with an argument too many")
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
        _ = rig.ask(Op.getUniform, .u(program))
        XCTAssertEqual(rig.lastAnswer, word(8) + word(0) + word(0), "glGetUniform with an argument missing")
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
    }

    /// glGetError answers one of OpenGL's six values and no other,
    /// whatever came before it, and glCompileShader and glLinkProgram
    /// begin their answers with 0 or 1: the library takes anything else
    /// for a stream gone wrong. Asked after every command of a soup of
    /// them, made up from a seed.
    func testErrorsAreOpenGLsSixAndCompiledAndLinkedAreZeroOrOne() throws {
        let errors: Set<UInt32> = [GL.NO_ERROR, GL.INVALID_ENUM, GL.INVALID_VALUE, GL.INVALID_OPERATION, GL.OUT_OF_MEMORY,
                                   GL.INVALID_FRAMEBUFFER_OPERATION]
        func first(_ data: Data) -> UInt32 {
            data.prefix(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }
        var random = Soup(seed: 0x6572_726f_7273), seen = Set<UInt32>(), flags = Set<UInt32>()
        for stream in 0..<200 {
            let rig = try Rig(size: nil)
            var ignored = 0
            rig.feed(Soup.opening(programs: stream % 2 == 0, answers: &ignored))
            for _ in 0..<100 {
                let call = random.call(answers: &ignored), op = first(call), before = rig.answers.count
                rig.feed(call)
                if op == Op.compileShader || op == Op.linkProgram {
                    XCTAssertEqual(rig.answers.count, before + 1)
                    flags.insert(first(rig.lastAnswer.dropFirst(4)))
                }
                seen.insert(rig.error())
            }
            rig.stream.close()
        }
        XCTAssertTrue(seen.isSubset(of: errors), "\(seen.subtracting(errors).map { String($0, radix: 16) })")
        XCTAssertTrue(seen.isSuperset(of: [GL.INVALID_ENUM, GL.INVALID_VALUE, GL.INVALID_OPERATION, GL.INVALID_FRAMEBUFFER_OPERATION]),
                      "the soup met the errors there are to meet")
        XCTAssertEqual(flags, [0, 1])
    }

    /// A shader's text and an attribute's name come as their bytes with
    /// no zero after them: a text whose length is a multiple of four is
    /// the end of its command. A zero the program put there itself is a
    /// byte of the text like another.
    func testTextsComeWithNoZeroAtTheirEnd() throws {
        let rig = try Rig()
        let vertex = rig.name(), fragment = rig.name(), program = rig.name()
        rig.send(Op.createShader, .u(vertex), .u(GL.VERTEX_SHADER))
        rig.send(Op.createShader, .u(fragment), .u(GL.FRAGMENT_SHADER))
        rig.send(Op.createProgram, .u(program))
        rig.send(Op.attachShader, .u(program), .u(vertex))
        rig.send(Op.attachShader, .u(program), .u(fragment))
        func links() -> Bool {
            for shader in [vertex, fragment] {
                var compiled = rig.ask(Op.compileShader, .u(shader))
                XCTAssertEqual(compiled.word(), 1)
            }
            var linked = rig.ask(Op.linkProgram, .u(program))
            return linked.word() == 1
        }
        let source = command(Op.shaderSource, [.u(vertex), .text("flat")])
        XCTAssertEqual(source.suffix(4), Data("flat".utf8), "four bytes of text, and the command ends with them")
        rig.feed(source)
        rig.send(Op.shaderSource, .u(fragment), .text("flat"))
        rig.send(Op.bindAttribLocation, .u(program), 5, .text("position"))
        rig.send(Op.bindAttribLocation, .u(program), 6, .text("uv"))
        XCTAssertTrue(links(), "the translator is given the text as it came")
        XCTAssertEqual(rig.translator.locations, ["position": 5, "uv": 6])
        rig.send(Op.shaderSource, .u(vertex), .data(Data("flat".utf8) + Data([0])))
        rig.send(Op.bindAttribLocation, .u(program), 7, .data(Data("uv".utf8) + Data([0, 0])))
        XCTAssertFalse(links(), "a text with a zero at its end is another text")
        XCTAssertEqual(rig.translator.locations, ["position": 5, "uv": 6, "uv\0\0": 7])
        rig.expectNoError()
    }

    /// glDelete* of the name 0 and of names that are nothing's is ignored
    /// without an error, as OpenGL has it, also among names that are
    /// something's and in a list that has a name twice. glDeleteProgram
    /// and glDeleteShader take 0 the same way; a name that is no
    /// program's or shader's is their GL_INVALID_VALUE. One that comes a
    /// second time for a program still in use changes nothing.
    func testDeletingNoneAndWhatIsNotIsIgnored() throws {
        let rig = try Rig()
        let program = rig.program("flat")
        let lists = [Op.deleteBuffers, Op.deleteTextures, Op.deleteFramebuffers, Op.deleteRenderbuffers]
        let objects = rig.stream.budget.objects
        for op in lists {
            rig.send(op, 4, .names([0, 4242, 0xffff_ffff, 0]))
            rig.send(op, 0, .names([]))
        }
        rig.send(Op.deleteProgram, 0)
        rig.send(Op.deleteShader, 0)
        rig.expectNoError()
        XCTAssertEqual(rig.stream.budget.objects, objects, "nothing was deleted")
        // One of each kind, deleted among names that are none and twice over.
        rig.send(Op.bindBuffer, .u(GL.ARRAY_BUFFER), 7)
        rig.send(Op.bindTexture, .u(GL.TEXTURE_2D), 7)
        rig.send(Op.bindFramebuffer, .u(GL.FRAMEBUFFER), 7)
        rig.send(Op.bindRenderbuffer, .u(GL.RENDERBUFFER), 7)
        XCTAssertEqual(rig.stream.budget.objects, objects + 4)
        for op in lists { rig.send(op, 5, .names([0, 7, 4242, 7, 0])) }
        rig.expectNoError()
        XCTAssertEqual(rig.stream.budget.objects, objects)
        rig.send(Op.deleteProgram, 4242)
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE)
        rig.send(Op.deleteShader, 4242)
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE)
        // In use and deleted twice, it is deleted once: when it is used no more.
        rig.send(Op.deleteProgram, .u(program))
        rig.send(Op.deleteProgram, .u(program))
        rig.send(Op.deleteShader, .u(program + 1))
        rig.send(Op.deleteShader, .u(program + 1))
        rig.rectangle(color: [1, 0, 0, 1])
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), red)
        rig.send(Op.useProgram, 0)
        rig.expectNoError()
        rig.send(Op.deleteProgram, .u(program))
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE, "it is gone")
        rig.send(Op.deleteShader, .u(program + 1))
        XCTAssertEqual(rig.error(), GL.INVALID_VALUE, "and the shader that was deleted went with it")
        rig.send(Op.deleteShader, .u(program + 2))
        rig.expectNoError()
        XCTAssertEqual(rig.stream.budget.objects, objects - 3)
    }

    /// What the library never sends and a guest could: a draw of no
    /// vertices, or of fewer than make one point, line or triangle, in
    /// every mode and every form; a uniform at location -1 by every call
    /// there is; glUseProgram of a program that did not link. None draws,
    /// and only the last is an error.
    func testDrawsOfNothingAndUniformsNowhereAreNoErrors() throws {
        let rig = try Rig()
        let program = rig.program("flat")
        rig.send(Op.uniform4f, 0, 1.0, 0.0, 0.0, 1.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.array(0, size: 2, Rig.whole)
        rig.buffer(GL.ELEMENT_ARRAY_BUFFER, bytes([UInt16]([0, 1, 2, 3])))
        let ushort = Arg.u(GL.UNSIGNED_SHORT)
        for mode in GL.POINTS...GL.TRIANGLE_FAN {
            // One vertex is no line, two are no triangle; one is a point, so of points there are none.
            for count in [0, mode == GL.POINTS ? 0 : 1, mode >= GL.TRIANGLES ? 2 : 0] {
                rig.send(Op.drawArrays, .u(mode), 0, .i(count))
                rig.send(Op.drawArrays, .u(mode), 3, .i(count))
                rig.send(Op.drawElements, .u(mode), .i(count), ushort, 0)
                rig.send(Op.drawElementsClient, .u(mode), .i(count), ushort, .data(Data(count: count * 2)))
                rig.send(Op.clientArray, 0, 2, .u(GL.FLOAT), 0, 0, .floats([Float](repeating: 0, count: count * 2)))
                rig.send(Op.drawArrays, .u(mode), 0, .i(count))
            }
            // No indices from a place past the buffer's end are no indices read.
            rig.send(Op.drawElements, .u(mode), 0, ushort, 0xffff_fff0)
        }
        rig.expectNoError()
        XCTAssertEqual(rig.read().flatMap { $0 }.filter { $0 != nothing }.count, 0, "none of them drew a pixel")

        // Location -1 is where a uniform the shaders do not use is: every call sets nothing there, and says nothing.
        for components in 1...4 {
            let floats = [Arg](repeating: 1.0, count: components), ints = [Arg](repeating: 1, count: components)
            rig.feed(command(Op.uniform1f + UInt32(components - 1), [-1] + floats))
            rig.feed(command(Op.uniform1i + UInt32(components - 1), [-1] + ints))
            for count in 0...2 {
                rig.feed(command(Op.uniform1fv + UInt32(components - 1), [-1, .i(count), .data(Data(count: count * components * 4))]))
                rig.feed(command(Op.uniform1iv + UInt32(components - 1), [-1, .i(count), .data(Data(count: count * components * 4))]))
            }
        }
        for side in 2...4 {
            for count in 0...2 {
                rig.feed(command(Op.uniformMatrix2fv + UInt32(side - 2), [-1, .i(count), .data(Data(count: count * side * side * 4))]))
            }
        }
        rig.expectNoError()
        // No values for a uniform that is there are no change to it.
        rig.send(Op.uniform4fv, 0, 0, .floats([]))
        rig.expectNoError()
        // Any other location that is no uniform's is OpenGL's error.
        for location in [-2, 1, 0x7fff_ffff, -0x8000_0000] {
            rig.send(Op.uniform4f, .i(location), 0.0, 1.0, 0.0, 1.0)
            XCTAssertEqual(rig.error(), GL.INVALID_OPERATION, "location \(location)")
        }

        // A program that did not link is not used, and the one in use stays in use.
        let unlinked = rig.name()
        rig.send(Op.createProgram, .u(unlinked))
        rig.send(Op.useProgram, .u(unlinked))
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), red, "red, as the uniform was before all of that")
        // One that linked, is in use, and then does not link again draws nothing until it does.
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.send(Op.detachShader, .u(program), .u(program + 2))
        var relinked = rig.ask(Op.linkProgram, .u(program))
        XCTAssertEqual(relinked.word(), 0)
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), nothing)
    }

    /// A program laid out the way the translator lays one out is drawn
    /// with: each function has a block struct of its own, the samplers
    /// are an array and their uniform has no place in the block (offset
    /// and stride 0), and points are drawn though the shader gives them
    /// no size.
    func testAProgramAsTheTranslatorLaysItOutIsDrawnWith() throws {
        let rig = try Rig()
        let program = rig.program("stages")
        for (unit, pixel) in [(UInt32(1), [UInt8]([200, 0, 0, 255])), (UInt32(2), [UInt8]([0, 100, 0, 0]))] {
            rig.send(Op.activeTexture, .u(GL.TEXTURE0 + unit))
            rig.texture(width: 1, height: 1, Data(pixel))
        }
        rig.array(0, size: 2, Rig.whole)
        func drawn() -> [UInt8] {
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
            rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
            return rig.pixel(8, 8)
        }
        func unit(at location: Int) -> Data {
            var answer = rig.ask(Op.getUniform, .u(program), .i(location))
            XCTAssertEqual(answer.word(), GL.SAMPLER_2D)
            return answer.data()
        }
        rig.send(Op.uniform4f, 1, 1.0, 1.0, 1.0, 1.0)
        rig.send(Op.uniform1iv, 2, 2, .ints([1, 2]))
        assertNear(drawn(), [200, 100, 0, 255], 1, "both samplers of the array, and the fragment function's own uniform")
        XCTAssertEqual([unit(at: 2), unit(at: 3)], [bytes([Int32(1)]), bytes([Int32(2)])])
        // The second element alone, at its own location; and three for an array of two, the third of which is dropped.
        rig.send(Op.uniform1i, 3, 1)
        assertNear(drawn(), [255, 0, 0, 255], 1)
        rig.send(Op.uniform1iv, 2, 3, .ints([2, 2, 2]))
        assertNear(drawn(), [0, 200, 0, 0], 1)
        rig.expectNoError()
        // A sampler takes one int, the number of a texture unit there is.
        let wrong: [(UInt32, [Arg], UInt32)] = [
            (Op.uniform1f, [2, 1.0], GL.INVALID_OPERATION), (Op.uniform2i, [2, 1, 1], GL.INVALID_OPERATION),
            (Op.uniform1i, [2, 32], GL.INVALID_VALUE), (Op.uniform1i, [3, -1], GL.INVALID_VALUE),
        ]
        for (op, arguments, expected) in wrong {
            rig.feed(command(op, arguments))
            XCTAssertEqual(rig.error(), expected)
        }
        XCTAssertEqual([unit(at: 2), unit(at: 3)], [bytes([Int32(2)]), bytes([Int32(2)])], "none of which changed it")
        // The vertex function's own uniform: moved two to the right, nothing of the rectangle is left to see.
        rig.send(Op.uniform4f, 0, 2.0, 0.0, 0.0, 0.0)
        XCTAssertEqual(drawn(), nothing)
        // Points from a program that gives them no size: how large they are neither OpenGL nor Metal says. Drawn or not, no more comes of it.
        rig.send(Op.uniform4f, 0, 0.0, 0.0, 0.0, 0.0)
        rig.send(Op.drawArrays, .u(GL.POINTS), 0, 4)
        rig.expectNoError()
        _ = rig.pixel(8, 8)
    }

    /// A program's Metal source is compiled with Metal's fast math off.
    /// The translator guards against floats that are no numbers, and with
    /// fast math on Metal's compiler takes there to be none and drops
    /// the guards.
    func testShadersAreCompiledWithFastMathOff() throws {
        let rig = try Rig()
        rig.program("notANumber")
        rig.array(0, size: 2, Rig.whole)
        rig.send(Op.uniform1f, 0, .f(.nan))
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), green, "what is no number is none to the shader")
        rig.send(Op.uniform1f, 0, 1.0)
        rig.send(Op.drawArrays, .u(GL.TRIANGLE_STRIP), 0, 4)
        XCTAssertEqual(rig.pixel(8, 8), red)
    }

    // MARK: More of a hostile stream

    /// EGL's commands that cannot be carried out are refused with an
    /// OpenGL error of the context that is current, and change nothing: a
    /// name that is 0 or taken, a context that shares with one that is
    /// not, a size that is none, more contexts or surfaces than a stream
    /// may have, a swap of what is no surface. Destroying what is not is
    /// ignored, as deleting is. MakeCurrent with a surface that is not
    /// leaves the context with nothing to draw on; with a context that is
    /// not, none is current.
    func testContextsAndSurfacesThatCannotBeAreRefused() throws {
        let rig = try Rig()
        let refused: [(String, UInt32, [Arg], UInt32)] = [
            ("a context named 0", Op.contextCreate, [0, 0], GL.INVALID_OPERATION),
            ("a context under a name that is taken", Op.contextCreate, [1, 0], GL.INVALID_OPERATION),
            ("a context that shares with one that is not", Op.contextCreate, [2, 77], GL.INVALID_OPERATION),
            ("a surface named 0", Op.surfaceCreate, [0, 8, 8, 1, 1, 1], GL.INVALID_OPERATION),
            ("a surface under a name that is taken", Op.surfaceCreate, [1, 8, 8, 1, 1, 1], GL.INVALID_OPERATION),
            ("a surface that is not, resized", Op.surfaceResize, [9, 8, 8], GL.INVALID_OPERATION),
            ("a surface of no width", Op.surfaceCreate, [9, 0, 8, 1, 1, 1], GL.INVALID_VALUE),
            ("a surface of a height below zero", Op.surfaceCreate, [9, 8, -1, 1, 1, 1], GL.INVALID_VALUE),
            ("a surface past the largest side", Op.surfaceCreate, [9, 8, 4097, 1, 1, 1], GL.INVALID_VALUE),
            ("a surface that does not say what buffers it has", Op.surfaceCreate, [9, 8, 8], GL.INVALID_OPERATION),
            ("a surface that says two of its three", Op.surfaceCreate, [9, 8, 8, 1, 1], GL.INVALID_OPERATION),
            ("a surface with a word after its three", Op.surfaceCreate, [9, 8, 8, 1, 1, 1, 1], GL.INVALID_OPERATION),
            ("an alpha that is neither there nor not", Op.surfaceCreate, [9, 8, 8, 2, 1, 1], GL.INVALID_OPERATION),
            ("a depth that is neither", Op.surfaceCreate, [9, 8, 8, 1, 0xffff_ffff, 1], GL.INVALID_OPERATION),
            ("a stencil that is neither", Op.surfaceCreate, [9, 8, 8, 1, 1, 0x100], GL.INVALID_OPERATION),
            ("a resize that says buffers", Op.surfaceResize, [1, 8, 8, 1, 1, 1], GL.INVALID_OPERATION),
            ("a swap of what is no surface", Op.swap, [9], GL.INVALID_OPERATION),
            ("a swap of none", Op.swap, [0], GL.INVALID_OPERATION),
        ]
        for (what, op, arguments, expected) in refused {
            rig.feed(command(op, arguments))
            XCTAssertEqual(rig.error(), expected, what)
        }
        XCTAssertEqual(Array(rig.stream.contexts.keys), [1])
        XCTAssertEqual(Array(rig.stream.surfaces.keys), [1])
        XCTAssertEqual(rig.presented.count, 0)
        rig.send(Op.contextDestroy, 77)
        rig.send(Op.surfaceDestroy, 77)
        rig.send(Op.contextDestroy, 0)
        rig.send(Op.surfaceDestroy, 0)
        rig.expectNoError()

        rig.send(Op.makeCurrent, 1, 9, 1)
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION, "a surface that is not")
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        XCTAssertEqual(rig.error(), GL.INVALID_FRAMEBUFFER_OPERATION, "nothing to draw on")
        XCTAssertEqual(rig.pixel(0, 0), nothing, "and the surface that is, to read")
        rig.send(Op.makeCurrent, 77, 1, 1)
        XCTAssertNil(rig.stream.current, "a context that is not")
        rig.expectNoError()
        rig.send(Op.makeCurrent, 1, 1, 1)
        rig.send(Op.clearColor, 0.0, 0.0, 1.0, 1.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(0, 0), blue)

        // 64 contexts and 64 surfaces a stream; one more of either is out of memory.
        for name in 2...GLLimits.contexts {
            rig.send(Op.contextCreate, .i(name), 1)
            rig.send(Op.surfaceCreate, .i(name), 1, 1, 0, 0, 0)
        }
        rig.expectNoError()
        rig.send(Op.contextCreate, 1000, 0)
        XCTAssertEqual(rig.error(), GL.OUT_OF_MEMORY)
        rig.send(Op.surfaceCreate, 1000, 1, 1, 1, 1, 1)
        XCTAssertEqual(rig.error(), GL.OUT_OF_MEMORY)
        XCTAssertEqual(rig.stream.contexts.count, GLLimits.contexts)
        XCTAssertEqual(rig.stream.surfaces.count, GLLimits.surfaces)
        rig.send(Op.contextDestroy, 2)
        rig.send(Op.surfaceDestroy, 2)
        rig.send(Op.contextCreate, 1000, 0)
        rig.send(Op.surfaceCreate, 1000, 1, 1, 1, 1, 1)
        rig.expectNoError()
    }

    /// A swap is answered with nothing (a reply of length 0) once its
    /// picture is drawn and handed over, so that a program is never more
    /// than a picture ahead of the Mac. It is answered once whatever is
    /// wrong with it (no such surface, no arguments or too many, no
    /// context current): the library waits for that answer. Answers come
    /// in the order of their commands.
    func testASwapIsAnsweredOnceThePictureIsDrawnWhateverIsWrongWithIt() throws {
        let rig = try Rig()
        rig.send(Op.clearColor, 1.0, 0.0, 0.0, 1.0)
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        var before = rig.answers.count
        rig.send(Op.swap, 1)
        XCTAssertEqual(Array(rig.answers[before...]), [word(0)])
        XCTAssertEqual(rig.middles.last, red, "the picture was drawn")
        XCTAssertEqual(rig.answersAtPresent.last, before, "and handed over before the answer was sent")

        before = rig.answers.count
        rig.feed(command(Op.enable, [0xbad]) + command(Op.getError, []) + command(Op.swap, [1]) + command(Op.finish, [])
                 + command(Op.swap, [1]) + command(Op.getError, []))
        XCTAssertEqual(Array(rig.answers[before...]), [word(4) + word(GL.INVALID_ENUM), word(0), word(0), word(0), word(4) + word(GL.NO_ERROR)])
        XCTAssertEqual(rig.presented.count, 3)

        let wrong: [(String, [Arg])] = [("a surface that is not", [9]), ("no surface", [0]), ("no argument", []), ("two arguments", [1, 1])]
        for (what, arguments) in wrong {
            before = rig.answers.count
            rig.feed(command(Op.swap, arguments))
            XCTAssertEqual(Array(rig.answers[before...]), [word(0)], what)
            XCTAssertEqual(rig.error(), GL.INVALID_OPERATION, what)
        }
        rig.send(Op.surfaceDestroy, 1)
        before = rig.answers.count
        rig.send(Op.swap, 1)
        XCTAssertEqual(Array(rig.answers[before...]), [word(0)], "a surface that was destroyed")
        XCTAssertEqual(rig.error(), GL.INVALID_OPERATION)
        XCTAssertEqual(rig.presented.count, 3, "none of those presented anything")

        // With no context current a swap is a swap still, and what is wrong with one has no error to be.
        rig.send(Op.surfaceCreate, 2, 8, 8, 1, 1, 1)
        rig.send(Op.makeCurrent, 0, 0, 0)
        for (arguments, presents) in [([2] as [Arg], 1), ([9], 0), ([], 0), ([2, 2], 0)] {
            before = rig.answers.count
            let pictures = rig.presented.count
            rig.feed(command(Op.swap, arguments))
            XCTAssertEqual(Array(rig.answers[before...]), [word(0)])
            XCTAssertEqual(rig.presented.count - pictures, presents)
        }
    }

    /// A stream that ends in the middle of a command (its program died,
    /// the VM went) has done all that came whole and nothing of the
    /// command that did not: half a command is no reason to drop the
    /// stream, is not carried out, is not answered, and is let go of
    /// with the stream.
    func testAStreamThatEndsInTheMiddleOfACommandDoesNothingOfIt() throws {
        let whole = command(Op.bufferData, [.u(GL.ARRAY_BUFFER), 4096, .u(GL.STATIC_DRAW), .data(Data(count: 4096))])
        for cut in [1, 4, 7, 8, 9, 12, 20, 21, whole.count - 1] {
            let rig = try Rig()
            rig.send(Op.bindBuffer, .u(GL.ARRAY_BUFFER), 1)
            XCTAssertTrue(rig.stream.feed(whole.prefix(cut)), "\(cut) bytes of a command")
            XCTAssertEqual(rig.stream.budget.bufferBytes, 0, "\(cut) bytes of a command")
            rig.stream.close()
            XCTAssertFalse(rig.stream.feed(whole.suffix(from: cut)), "closed, the rest of it is nothing's")
            XCTAssertEqual(rig.stream.budget.bufferBytes, 0)
            XCTAssertEqual(rig.stream.budget.objects, 0)
            XCTAssertEqual(rig.answers.count, 0)
        }
        // A command that is answered is answered when its last byte came, not before; and never, if that never comes.
        let rig = try Rig()
        let asked = command(Op.readPixels, [0, 0, 1, 1, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE)])
        XCTAssertTrue(rig.stream.feed(asked.prefix(asked.count - 1)))
        XCTAssertEqual(rig.answers.count, 0)
        XCTAssertTrue(rig.stream.feed(asked.suffix(1)))
        XCTAssertEqual(rig.answers.count, 1)
        XCTAssertTrue(rig.stream.feed(asked.prefix(asked.count - 1)))
        XCTAssertTrue(rig.stream.feed(Data()), "no bytes at all are no end of anything")
        XCTAssertEqual(rig.answers.count, 1)
    }

    /// The arrays that come for a draw (ClientArray) are bounded
    /// together, at 128 MiB: one past that is GL_OUT_OF_MEMORY. The draw
    /// lets go of them all, and so does the context being current no more.
    func testArraysThatComeForADrawAreBounded() throws {
        let rig = try Rig()
        rig.program("flat")
        let context = try XCTUnwrap(rig.stream.current)
        // 16 MiB each: eight fit.
        for index in 0..<9 {
            rig.feed(command(Op.clientArray, [.i(index), 4, .u(GL.FLOAT), 0, 0, .data(Data(count: 16 << 20))]))
            XCTAssertEqual(rig.error(), index < 8 ? GL.NO_ERROR : GL.OUT_OF_MEMORY, "array \(index)")
        }
        XCTAssertEqual(context.clientBytes, GLLimits.clientBytes)
        // One that comes again gives back what the one before it held.
        rig.send(Op.clientArray, 0, 4, .u(GL.FLOAT), 0, 0, .data(Data(count: 48)))
        rig.expectNoError()
        XCTAssertEqual(context.clientBytes, GLLimits.clientBytes - (16 << 20) + 48)
        rig.send(Op.drawArrays, .u(GL.TRIANGLES), 0, 3)
        rig.expectNoError()
        XCTAssertEqual(context.clientBytes, 0, "they held for that draw")
        rig.send(Op.clientArray, 0, 4, .u(GL.FLOAT), 0, 0, .data(Data(count: 48)))
        rig.send(Op.makeCurrent, 0, 0, 0)
        XCTAssertEqual(context.clientBytes, 0, "and for no other context's")
    }

    /// The uniform blocks of a stream's programs are bounded: 1 MiB a
    /// program and 64 MiB in all. A program past either does not link,
    /// and its log says that it is the bound's doing.
    func testUniformBlocksAreBounded() throws {
        let rig = try Rig()
        let bound = "The program has more uniforms, or the stream more programs, than Monad draws with."
        func link(_ source: String) -> (name: UInt32, linked: UInt32, log: String) {
            let program = rig.name()
            rig.send(Op.createProgram, .u(program))
            rig.send(Op.attachShader, .u(program), .u(rig.shader(GL.VERTEX_SHADER, source)))
            rig.send(Op.attachShader, .u(program), .u(rig.shader(GL.FRAGMENT_SHADER, source)))
            var answer = rig.ask(Op.linkProgram, .u(program))
            return (program, answer.word(), answer.text())
        }
        let tooWide = link("tooWide")
        XCTAssertEqual(tooWide.linked, 0)
        XCTAssertEqual(tooWide.log, bound)
        var first: UInt32 = 0
        for index in 0..<65 {
            let wide = link("wide")
            XCTAssertEqual(wide.linked, index < 64 ? 1 : 0, "program \(index): \(wide.log)")
            if index == 0 { first = wide.name }
            if index == 64 { XCTAssertEqual(wide.log, bound) }
        }
        XCTAssertEqual(rig.stream.budget.uniformBytes, GLLimits.uniformBytes)
        // One deleted makes room for one; and a megabyte of uniforms is drawn with.
        rig.send(Op.deleteProgram, .u(first))
        let again = link("wide")
        XCTAssertEqual(again.linked, 1, again.log)
        rig.send(Op.useProgram, .u(again.name))
        rig.rectangle(color: [0, 1, 0, 1])
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), green)
    }

    /// A viewport is cut to the largest side there is, and wherever it
    /// lies it is drawn through; a scissor box of any size and place is
    /// cut to what is drawn to. Neither is an error.
    func testAViewportOrAScissorBoxOfAnySizeAndPlaceIsDrawnThrough() throws {
        let rig = try Rig()
        rig.program("flat")
        rig.send(Op.viewport, 0, 0, 0x7fff_ffff, 0x7fff_ffff)
        XCTAssertEqual(rig.stream.current?.viewport, GLRect(x: 0, y: 0, width: 4096, height: 4096))
        rig.rectangle(color: [1, 0, 0, 1])
        XCTAssertEqual(rig.pixel(8, 8), red, "the lower left of something larger")
        rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        for (x, y) in [(0x7fff_ffff, 0x7fff_ffff), (-0x8000_0000, -0x8000_0000), (-0x8000_0000, 0x7fff_ffff), (4096, 0), (-4096, -4096)] {
            rig.send(Op.viewport, .i(x), .i(y), 4096, 4096)
            rig.rectangle(color: [1, 0, 0, 1])
        }
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), nothing, "nothing of those lies in the picture")
        rig.send(Op.viewport, 0, 0, 16, 16)
        rig.send(Op.enable, .u(GL.SCISSOR_TEST))
        for (x, y, width, height) in [(-0x8000_0000, -0x8000_0000, 0x7fff_ffff, 0x7fff_ffff), (0x7fff_ffff, 0x7fff_ffff, 0x7fff_ffff, 0x7fff_ffff), (16, 0, 16, 16), (0, 0, 0, 0)] {
            rig.send(Op.scissor, .i(x), .i(y), .i(width), .i(height))
            rig.rectangle(color: [1, 0, 0, 1])
            rig.send(Op.clearColor, 1.0, 1.0, 1.0, 1.0)
            rig.send(Op.clear, .u(GL.COLOR_BUFFER_BIT))
        }
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), nothing, "nothing of those either")
        rig.send(Op.scissor, -5, -5, 0x7fff_ffff, 0x7fff_ffff)
        rig.rectangle(color: [0, 1, 0, 1])
        rig.expectNoError()
        XCTAssertEqual(rig.pixel(8, 8), green, "all of the picture lies in this one")
    }

    // MARK: The conversions

    /// The pixels a program gives become four bytes each the way OpenGL
    /// says each format is read; too few bytes on either side write nothing.
    func testPixelsAreUnpackedAsOpenGLReadsThem() {
        func unpack(_ format: UInt32, _ type: UInt32, _ source: [UInt8], pixels: Int, room: Int? = nil) -> [UInt8] {
            var out = [UInt8](repeating: 7, count: room ?? pixels * 4)
            source.withUnsafeBytes { from in
                out.withUnsafeMutableBytes { GLFormats.rgba(format: format, type: type, from: from, into: $0, pixels: pixels) }
            }
            return out
        }
        XCTAssertEqual(unpack(GL.RGB, GL.UNSIGNED_BYTE, [1, 2, 3, 4, 5, 6], pixels: 2), [1, 2, 3, 255, 4, 5, 6, 255])
        XCTAssertEqual(unpack(GL.LUMINANCE_ALPHA, GL.UNSIGNED_BYTE, [9, 8], pixels: 1), [9, 9, 9, 8])
        XCTAssertEqual(unpack(GL.RGB, GL.UNSIGNED_SHORT_5_6_5, [0xff, 0xff, 0x00, 0x00, 0x10, 0x84], pixels: 3), [255, 255, 255, 255, 0, 0, 0, 255, 132, 130, 132, 255])
        XCTAssertEqual(unpack(GL.RGBA, GL.UNSIGNED_SHORT_4_4_4_4, [0x48, 0x12], pixels: 1), [0x11, 0x22, 0x44, 0x88])
        XCTAssertEqual(unpack(GL.RGBA, GL.UNSIGNED_SHORT_5_5_5_1, [0xff, 0xff, 0xfe, 0xff], pixels: 2), [255, 255, 255, 255, 255, 255, 255, 0])
        XCTAssertEqual(unpack(GL.RGB, GL.UNSIGNED_BYTE, [1, 2, 3, 4, 5], pixels: 2), [UInt8](repeating: 7, count: 8), "five bytes are not two pixels")
        XCTAssertEqual(unpack(GL.RGBA, GL.UNSIGNED_BYTE, [1, 2, 3, 4, 5, 6, 7, 8], pixels: 2, room: 7), [UInt8](repeating: 7, count: 7), "seven bytes do not hold two")
        XCTAssertEqual(unpack(GL.RGBA, GL.FLOAT, [1, 2, 3, 4], pixels: 1), [7, 7, 7, 7], "no such pixels")
        XCTAssertNil(GLFormats.bytesPerPixel(format: GL.RGB, type: GL.UNSIGNED_SHORT_4_4_4_4))
        XCTAssertEqual(GLFormats.bytesPerPixel(format: GL.DEPTH_STENCIL_OES, type: GL.UNSIGNED_INT_24_8_OES), 4)
        XCTAssertEqual(GLFormats.levels(width: 4096, height: 1), 13)
        XCTAssertEqual(GLFormats.levels(width: 5, height: 3), 3)
        XCTAssertEqual(GLFormats.bytes(.rgba8Unorm, width: 4, height: 4, levels: 3), (16 + 4 + 1) * 4)
    }
}

// MARK: The soup

/// Commands made up at random from a seed: each has the arguments its
/// call has, drawn from small sets of what OpenGL takes, what it refuses
/// and what no call should be given.
private struct Soup {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        // SplitMix64: the same numbers from the same seed, on any Mac.
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    private mutating func pick<T>(_ values: [T]) -> T {
        values[Int(next() % UInt64(values.count))]
    }

    private static let enums: [UInt32] = [
        0, 1, GL.TEXTURE_2D, GL.TEXTURE_CUBE_MAP, GL.TEXTURE_CUBE_MAP_POSITIVE_X, GL.TEXTURE_CUBE_MAP_NEGATIVE_Z, GL.ARRAY_BUFFER, GL.ELEMENT_ARRAY_BUFFER,
        GL.FRAMEBUFFER, GL.RENDERBUFFER, GL.COLOR_ATTACHMENT0, GL.DEPTH_ATTACHMENT, GL.STENCIL_ATTACHMENT, GL.RGBA, GL.RGB, GL.LUMINANCE, GL.ALPHA,
        GL.LUMINANCE_ALPHA, GL.DEPTH_COMPONENT, GL.DEPTH_STENCIL_OES, GL.UNSIGNED_BYTE, GL.UNSIGNED_SHORT, GL.UNSIGNED_INT, GL.UNSIGNED_SHORT_5_6_5,
        GL.UNSIGNED_SHORT_4_4_4_4, GL.UNSIGNED_INT_24_8_OES, GL.FLOAT, GL.FIXED, GL.BYTE, GL.SHORT, GL.RGBA4, GL.RGB565, GL.DEPTH_COMPONENT16,
        GL.STENCIL_INDEX8, GL.DEPTH24_STENCIL8_OES, GL.NEAREST, GL.LINEAR, GL.LINEAR_MIPMAP_LINEAR, GL.REPEAT, GL.CLAMP_TO_EDGE, GL.MIRRORED_REPEAT,
        GL.TEXTURE_MIN_FILTER, GL.TEXTURE_MAG_FILTER, GL.TEXTURE_WRAP_S, GL.TEXTURE_WRAP_T, GL.BLEND, GL.DEPTH_TEST, GL.STENCIL_TEST, GL.SCISSOR_TEST,
        GL.CULL_FACE, GL.POLYGON_OFFSET_FILL, GL.DITHER, GL.FRONT, GL.BACK, GL.FRONT_AND_BACK, GL.CW, GL.CCW, GL.NEVER, GL.LESS, GL.EQUAL, GL.ALWAYS,
        GL.KEEP, GL.REPLACE, GL.INCR, GL.INVERT, GL.INCR_WRAP, GL.ZERO, GL.ONE, GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA, GL.DST_COLOR, GL.CONSTANT_COLOR,
        GL.SRC_ALPHA_SATURATE, GL.FUNC_ADD, GL.FUNC_SUBTRACT, GL.FUNC_REVERSE_SUBTRACT, GL.STATIC_DRAW, GL.DYNAMIC_DRAW, GL.VERTEX_SHADER,
        GL.FRAGMENT_SHADER, GL.TEXTURE0, GL.TEXTURE0 + 3, GL.TEXTURE0 + 31, GL.POINTS, GL.LINES, GL.LINE_LOOP, GL.LINE_STRIP, GL.TRIANGLES,
        GL.TRIANGLE_STRIP, GL.TRIANGLE_FAN, GL.COLOR_BUFFER_BIT, GL.DEPTH_BUFFER_BIT | GL.STENCIL_BUFFER_BIT | GL.COLOR_BUFFER_BIT, 0xdead, 0xffff_ffff,
    ]
    /// The enums each call takes, so that most calls are ones OpenGL carries out; now and then one is drawn from all of them.
    private static let likely: [UInt32: [UInt32]] = {
        let textures = [GL.TEXTURE_2D, GL.TEXTURE_2D, GL.TEXTURE_CUBE_MAP]
        let functions = [GL.NEVER, GL.LESS, GL.EQUAL, GL.LEQUAL, GL.GREATER, GL.NOTEQUAL, GL.GEQUAL, GL.ALWAYS]
        let operations = [GL.KEEP, GL.ZERO, GL.REPLACE, GL.INCR, GL.DECR, GL.INVERT, GL.INCR_WRAP, GL.DECR_WRAP]
        let factors = [GL.ZERO, GL.ONE, GL.SRC_COLOR, GL.ONE_MINUS_SRC_COLOR, GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA, GL.DST_ALPHA, GL.ONE_MINUS_DST_ALPHA,
                       GL.DST_COLOR, GL.ONE_MINUS_DST_COLOR, GL.CONSTANT_COLOR, GL.ONE_MINUS_CONSTANT_ALPHA]
        let equations = [GL.FUNC_ADD, GL.FUNC_SUBTRACT, GL.FUNC_REVERSE_SUBTRACT]
        let capabilities = [GL.BLEND, GL.DEPTH_TEST, GL.STENCIL_TEST, GL.SCISSOR_TEST, GL.CULL_FACE, GL.POLYGON_OFFSET_FILL, GL.DITHER]
        let faces = [GL.FRONT, GL.BACK, GL.FRONT_AND_BACK]
        let masks = [GL.COLOR_BUFFER_BIT, GL.DEPTH_BUFFER_BIT, GL.STENCIL_BUFFER_BIT, GL.COLOR_BUFFER_BIT | GL.DEPTH_BUFFER_BIT | GL.STENCIL_BUFFER_BIT]
        return [
            Op.activeTexture: [GL.TEXTURE0, GL.TEXTURE0, GL.TEXTURE0 + 1, GL.TEXTURE0 + 31], Op.bindBuffer: [GL.ARRAY_BUFFER, GL.ELEMENT_ARRAY_BUFFER],
            Op.bindFramebuffer: [GL.FRAMEBUFFER], Op.bindRenderbuffer: [GL.RENDERBUFFER], Op.bindTexture: textures, Op.blendEquation: equations,
            Op.blendEquationSeparate: equations, Op.blendFunc: factors, Op.blendFuncSeparate: factors, Op.checkFramebufferStatus: [GL.FRAMEBUFFER],
            Op.clear: masks, Op.createShader: [GL.VERTEX_SHADER, GL.FRAGMENT_SHADER], Op.cullFace: faces, Op.depthFunc: functions,
            Op.disable: capabilities, Op.enable: capabilities, Op.frontFace: [GL.CW, GL.CCW], Op.generateMipmap: textures,
            Op.stencilFunc: functions, Op.stencilFuncSeparate: faces + functions, Op.stencilMaskSeparate: faces, Op.stencilOp: operations,
            Op.stencilOpSeparate: faces + operations + operations, Op.copyTexSubImage2D: [GL.TEXTURE_2D],
            Op.texParameteri: [GL.TEXTURE_2D, GL.TEXTURE_2D, GL.TEXTURE_CUBE_MAP, GL.TEXTURE_MIN_FILTER, GL.TEXTURE_MIN_FILTER, GL.TEXTURE_MAG_FILTER,
                               GL.TEXTURE_WRAP_S, GL.TEXTURE_WRAP_T, GL.NEAREST, GL.LINEAR, GL.LINEAR_MIPMAP_LINEAR, GL.NEAREST_MIPMAP_NEAREST,
                               GL.REPEAT, GL.CLAMP_TO_EDGE, GL.MIRRORED_REPEAT],
        ]
    }()
    private static let numbers: [UInt32] = [0, 0, 1, 1, 2, 3, 4, 5, 7, 8, 16, 17, 64, 255, 4096, 4097, 0xffff, 0x10000, 0x7fff_ffff, 0x8000_0000, 0xffff_fffe, 0xffff_ffff]
    private static let floats: [Float] = [0, 0, 0.25, 0.5, 1, 1, -1, 2, 1e30, -1e30, .infinity, -.infinity, .nan, .leastNonzeroMagnitude]
    /// The names a stream uses: few, so that calls meet the objects other calls made.
    private static let names: [UInt32] = [0, 1, 1, 2, 2, 3, 4, 5, 6, 7, 8, 9]

    /// What each call's arguments are: n a name, e an enum, i a number, f a float, d data, s a short number that is a size.
    private static let calls: [(UInt32, String)] = [
        (Op.contextCreate, "nn"), (Op.contextDestroy, "n"), (Op.surfaceCreate, "nssbbb"), (Op.surfaceResize, "nss"), (Op.surfaceDestroy, "n"),
        (Op.makeCurrent, "nnn"), (Op.makeCurrent, "nnn"), (Op.swap, "n"), (Op.swap, "n"),
        (Op.activeTexture, "e"), (Op.attachShader, "nn"), (Op.bindAttribLocation, "nid"), (Op.bindBuffer, "en"), (Op.bindFramebuffer, "en"),
        (Op.bindFramebuffer, "en"), (Op.bindRenderbuffer, "en"), (Op.bindTexture, "en"), (Op.bindTexture, "en"), (Op.blendColor, "ffff"),
        (Op.blendEquation, "e"), (Op.blendEquationSeparate, "ee"), (Op.blendFunc, "ee"), (Op.blendFuncSeparate, "eeee"), (Op.bufferData, "eied"),
        (Op.bufferSubData, "eid"), (Op.checkFramebufferStatus, "e"), (Op.clear, "e"), (Op.clear, "e"), (Op.clearColor, "ffff"), (Op.clearDepthf, "f"),
        (Op.clearStencil, "i"), (Op.colorMask, "iiii"), (Op.compileShader, "n"), (Op.copyTexImage2D, "eiessssi"), (Op.copyTexSubImage2D, "eissssss"),
        (Op.createProgram, "n"), (Op.createShader, "ne"), (Op.cullFace, "e"), (Op.deleteBuffers, "id"), (Op.deleteFramebuffers, "id"),
        (Op.deleteProgram, "n"), (Op.deleteRenderbuffers, "id"), (Op.deleteShader, "n"), (Op.deleteTextures, "id"), (Op.depthFunc, "e"),
        (Op.depthMask, "i"), (Op.depthRangef, "ff"), (Op.detachShader, "nn"), (Op.disable, "e"), (Op.disableVertexAttribArray, "s"),
        (Op.drawArrays, "ess"), (Op.drawArrays, "ess"), (Op.drawElements, "esei"), (Op.drawElements, "esei"), (Op.drawElementsClient, "esed"),
        (Op.clientArray, "sseisd"), (Op.enable, "e"), (Op.enable, "e"), (Op.enableVertexAttribArray, "s"), (Op.finish, ""),
        (Op.framebufferRenderbuffer, "eeen"), (Op.framebufferTexture2D, "eeeni"), (Op.frontFace, "e"), (Op.generateMipmap, "e"), (Op.getError, ""),
        (Op.getUniform, "ni"), (Op.lineWidth, "f"), (Op.linkProgram, "n"), (Op.polygonOffset, "ff"), (Op.readPixels, "ssssee"),
        (Op.renderbufferStorage, "eess"), (Op.sampleCoverage, "fi"), (Op.scissor, "ssss"), (Op.shaderSource, "nd"), (Op.stencilFunc, "eii"),
        (Op.stencilFuncSeparate, "eeii"), (Op.stencilMask, "i"), (Op.stencilMaskSeparate, "ei"), (Op.stencilOp, "eee"), (Op.stencilOpSeparate, "eeee"),
        (Op.texImage2D, "eiessieed"), (Op.texParameterf, "eef"), (Op.texParameteri, "eee"), (Op.texSubImage2D, "eissssed"),
        (Op.uniform1f, "if"), (Op.uniform2f, "iff"), (Op.uniform3f, "ifff"), (Op.uniform4f, "iffff"), (Op.uniform1i, "ii"), (Op.uniform2i, "iii"),
        (Op.uniform3i, "iiii"), (Op.uniform4i, "iiiii"), (Op.uniform1fv, "iid"), (Op.uniform2fv, "iid"), (Op.uniform3fv, "iid"), (Op.uniform4fv, "iid"),
        (Op.uniform1iv, "iid"), (Op.uniform2iv, "iid"), (Op.uniform3iv, "iid"), (Op.uniform4iv, "iid"), (Op.uniformMatrix2fv, "iid"),
        (Op.uniformMatrix3fv, "iid"), (Op.uniformMatrix4fv, "iid"), (Op.useProgram, "n"), (Op.vertexAttrib4f, "sffff"),
        (Op.vertexAttribPointer, "ssiisi"), (Op.viewport, "ssss"),
    ]

    /// A stream's beginning: contexts 1 and 2 (sharing), a surface, and with `programs` two programs linked, with buffers and a texture to draw with.
    static func opening(programs: Bool, answers: inout Int) -> Data {
        var bytes = Data()
        func add(_ op: UInt32, _ arguments: Arg...) {
            bytes.append(command(op, arguments))
        }
        add(Op.contextCreate, 1, 0)
        add(Op.contextCreate, 2, 1)
        add(Op.surfaceCreate, 1, 8, 8, 1, 1, 1)
        add(Op.makeCurrent, 1, 1, 1)
        guard programs else { return bytes }
        for (index, source) in ["texture", "color"].enumerated() {
            let vertex = UInt32(10 + index * 3), fragment = vertex + 1, program = UInt32(index == 0 ? 1 : 2)
            add(Op.createShader, .u(vertex), .u(GL.VERTEX_SHADER))
            add(Op.createShader, .u(fragment), .u(GL.FRAGMENT_SHADER))
            add(Op.shaderSource, .u(vertex), .text(source))
            add(Op.shaderSource, .u(fragment), .text(source))
            add(Op.compileShader, .u(vertex))
            add(Op.compileShader, .u(fragment))
            add(Op.createProgram, .u(program))
            add(Op.attachShader, .u(program), .u(vertex))
            add(Op.attachShader, .u(program), .u(fragment))
            add(Op.linkProgram, .u(program))
            answers += 3
        }
        add(Op.useProgram, 1)
        add(Op.bindBuffer, .u(GL.ARRAY_BUFFER), 1)
        add(Op.bufferData, .u(GL.ARRAY_BUFFER), 64, .u(GL.STATIC_DRAW), .floats([Float](repeating: 0.5, count: 16)))
        add(Op.vertexAttribPointer, 0, 2, .u(GL.FLOAT), 0, 0, 0)
        add(Op.vertexAttribPointer, 1, 2, .u(GL.FLOAT), 0, 0, 0)
        add(Op.enableVertexAttribArray, 0)
        add(Op.bindBuffer, .u(GL.ELEMENT_ARRAY_BUFFER), 2)
        add(Op.bufferData, .u(GL.ELEMENT_ARRAY_BUFFER), 16, .u(GL.STATIC_DRAW), .data(Data([0, 0, 1, 0, 2, 0, 3, 0, 7, 0, 8, 0, 255, 255, 0, 0])))
        add(Op.bindTexture, .u(GL.TEXTURE_2D), 1)
        add(Op.texImage2D, .u(GL.TEXTURE_2D), 0, .u(GL.RGBA), 2, 2, 0, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE), .data(Data(count: 16)))
        return bytes
    }

    private mutating func data() -> Data? {
        let roll = next() % 16
        if roll == 0 { return nil }
        let count = pick([0, 0, 1, 2, 3, 4, 4, 8, 8, 12, 16, 16, 24, 32, 48, 64, 64, 256, 1024, 4096])
        // Small numbers, so that as indices and names they mean something.
        return Data((0..<count).map { _ in UInt8(truncatingIfNeeded: next() % 5 == 0 ? next() : next() % 4) })
    }

    mutating func call(answers: inout Int) -> Data {
        let (op, signature) = pick(Self.calls)
        if Op.answered.contains(op) { answers += 1 }
        var arguments: [Arg] = []
        for kind in signature {
            switch kind {
            case "n": arguments.append(.u(pick(Self.names)))
            case "e": arguments.append(.u(next() % 5 == 0 ? pick(Self.enums) : pick(Self.likely[op] ?? Self.enums)))
            case "f": arguments.append(.f(pick(Self.floats)))
            case "s": arguments.append(.u(pick([0, 0, 0, 1, 1, 2, 2, 3, 4, 4, 5, 8, 8, 16, 0xffff_ffff, 4096])))
            case "b": arguments.append(.u(pick([0, 1, 1, 1, 0, 1, 1, 2, 0xffff_ffff])))
            case "d": arguments.append(.data(data()))
            default: arguments.append(.u(next() % 4 == 0 ? pick(Self.numbers) : UInt32(next() % 6)))
            }
        }
        // The calls whose data has to be of a length their other arguments give, as a library sends them more often than not.
        if next() % 4 != 0 {
            switch op {
            case Op.texImage2D:
                let formats: [(UInt32, UInt32, Int)] = [
                    (GL.RGBA, GL.UNSIGNED_BYTE, 4), (GL.RGBA, GL.UNSIGNED_BYTE, 4), (GL.RGB, GL.UNSIGNED_BYTE, 3), (GL.LUMINANCE, GL.UNSIGNED_BYTE, 1),
                    (GL.ALPHA, GL.UNSIGNED_BYTE, 1), (GL.LUMINANCE_ALPHA, GL.UNSIGNED_BYTE, 2), (GL.RGB, GL.UNSIGNED_SHORT_5_6_5, 2),
                    (GL.DEPTH_COMPONENT, GL.UNSIGNED_SHORT, 2), (GL.DEPTH_COMPONENT, GL.UNSIGNED_INT, 4), (GL.DEPTH_STENCIL_OES, GL.UNSIGNED_INT_24_8_OES, 4),
                ]
                let (format, type, each) = pick(formats), level = Int(next() % 3)
                // A side that is the level's of a texture of 8 a side as often as not, so that textures with all their levels come to be.
                let side = next() % 2 == 0 ? 8 >> level : pick([0, 1, 2, 4, 8, 3, 16])
                let target = pick([GL.TEXTURE_2D, GL.TEXTURE_2D, GL.TEXTURE_2D, GL.TEXTURE_CUBE_MAP_POSITIVE_X, GL.TEXTURE_CUBE_MAP_NEGATIVE_Y])
                arguments = [.u(target), .i(level), .u(format), .i(side), .i(side), 0, .u(format), .u(type),
                             .data(next() % 3 == 0 ? nil : Data(count: side * side * each))]
            case Op.texSubImage2D:
                arguments = [.u(GL.TEXTURE_2D), 0, .u(UInt32(next() % 2)), .u(UInt32(next() % 2)), 1, 1, .u(GL.RGBA), .u(GL.UNSIGNED_BYTE), .data(Data(count: 4))]
            case Op.deleteBuffers, Op.deleteTextures, Op.deleteFramebuffers, Op.deleteRenderbuffers:
                let doomed = (0..<Int(next() % 3)).map { _ in pick(Self.names) }
                arguments = [.i(doomed.count), .names(doomed)]
            case Op.uniform1fv...Op.uniformMatrix4fv:
                let numbers = [1, 2, 3, 4, 1, 2, 3, 4, 4, 9, 16][Int(op - Op.uniform1fv)]
                arguments = [.i(Int(next() % 4) - 1), 1, .data(Data(count: numbers * 4))]
            case Op.bufferData:
                let size = pick([0, 4, 8, 16, 64, 256])
                arguments = [.u(pick([GL.ARRAY_BUFFER, GL.ELEMENT_ARRAY_BUFFER])), .i(size), .u(GL.STATIC_DRAW), .data(Data((0..<size).map { _ in UInt8(next() % 4) }))]
            case Op.bufferSubData:
                arguments = [.u(pick([GL.ARRAY_BUFFER, GL.ELEMENT_ARRAY_BUFFER])), .u(UInt32(next() % 8)), .data(Data(count: 8))]
            case Op.drawArrays:
                arguments = [.u(UInt32(next() % 7)), .u(UInt32(next() % 3)), .u(UInt32(next() % 9))]
            case Op.drawElements:
                arguments = [.u(UInt32(next() % 7)), .u(UInt32(next() % 9)), .u(pick([GL.UNSIGNED_BYTE, GL.UNSIGNED_SHORT, GL.UNSIGNED_INT])), .u(UInt32(next() % 6))]
            case Op.drawElementsClient:
                let count = Int(next() % 8)
                arguments = [.u(UInt32(next() % 7)), .i(count), .u(GL.UNSIGNED_SHORT), .data(Data((0..<count * 2).map { $0 % 2 == 0 ? UInt8(next() % 8) : 0 }))]
            case Op.clientArray:
                let size = Int(next() % 4) + 1
                arguments = [.u(UInt32(next() % 3)), .i(size), .u(GL.FLOAT), 0, .u(UInt32(next() % 2)), .data(Data(count: size * 4 * Int(next() % 8)))]
            case Op.vertexAttribPointer:
                arguments = [.u(UInt32(next() % 3)), .u(UInt32(next() % 4) + 1), .u(pick([GL.FLOAT, GL.UNSIGNED_BYTE, GL.SHORT, GL.FIXED])), .u(UInt32(next() % 2)),
                             .u(pick([0, 0, 4, 8, 3, 16])), .u(UInt32(next() % 12))]
            case Op.renderbufferStorage:
                arguments = [.u(GL.RENDERBUFFER), .u(pick([GL.RGBA4, GL.RGB565, GL.DEPTH_COMPONENT16, GL.STENCIL_INDEX8, GL.DEPTH24_STENCIL8_OES])), .u(pick([0, 4, 8])), .u(pick([4, 8]))]
            case Op.framebufferRenderbuffer:
                arguments = [.u(GL.FRAMEBUFFER), .u(pick([GL.COLOR_ATTACHMENT0, GL.DEPTH_ATTACHMENT, GL.STENCIL_ATTACHMENT])), .u(GL.RENDERBUFFER), .u(pick(Self.names))]
            case Op.framebufferTexture2D:
                arguments = [.u(GL.FRAMEBUFFER), .u(pick([GL.COLOR_ATTACHMENT0, GL.DEPTH_ATTACHMENT, GL.STENCIL_ATTACHMENT])),
                             .u(pick([GL.TEXTURE_2D, GL.TEXTURE_2D, GL.TEXTURE_CUBE_MAP_POSITIVE_X])), .u(pick(Self.names)), 0]
            case Op.readPixels:
                arguments = [.i(Int(next() % 12) - 2), .i(Int(next() % 12) - 2), .u(UInt32(next() % 12)), .u(UInt32(next() % 12)), .u(GL.RGBA), .u(GL.UNSIGNED_BYTE)]
            case Op.copyTexImage2D:
                arguments = [.u(GL.TEXTURE_2D), 0, .u(pick([GL.RGBA, GL.RGB, GL.LUMINANCE])), .i(Int(next() % 6) - 2), .i(Int(next() % 6) - 2), .u(pick([1, 4, 8])), .u(pick([1, 4, 8])), 0]
            case Op.shaderSource:
                arguments = [.u(pick(Self.names)), .text(pick(["texture", "color", "flat", "bad", "notMetal", "outsideBlock"]))]
            case Op.surfaceCreate:
                arguments = [.u(pick([1, 1, 2, 3])), .u(pick([1, 4, 8, 16])), .u(pick([1, 4, 8, 16])), .u(UInt32(next() % 2)), .u(UInt32(next() % 2)),
                             .u(UInt32(next() % 2))]
            case Op.surfaceResize:
                arguments = [.u(pick([1, 1, 2, 3])), .u(pick([1, 4, 8, 16])), .u(pick([1, 4, 8, 16]))]
            default:
                break
            }
        }
        var bytes = command(op, arguments)
        // Now and then, not what the header says: cut short by a word, a word too many, or a size that does not cover it.
        switch next() % 40 {
        case 0 where bytes.count >= 12:
            bytes = resized(bytes.prefix(bytes.count - 4))
        case 1:
            bytes = resized(bytes + word(UInt32(truncatingIfNeeded: next())))
        case 2:
            bytes = resized(bytes + Data(count: 4 * Int(next() % 4)))
        default:
            break
        }
        return bytes
    }
}

/// The command with its size put right for the bytes it now has.
private func resized(_ bytes: Data) -> Data {
    var out = Data(bytes)
    out.replaceSubrange(4..<8, with: word(UInt32(out.count)))
    return out
}
