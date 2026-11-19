//
//  GLSLTranslatorTests.swift — a Linux program's GLSL ES 1.00 shaders
//  turned into Metal's language (Monad/GL/GLSL*.swift). What comes out is
//  given to the real Metal compiler, and where it can be, drawn with: a
//  translation that compiles and computes something else is still wrong.
//  The shaders are a guest's text, so the hostile cases are here too.
//

import Metal
import XCTest
@testable import Monad

final class GLSLTranslatorTests: XCTestCase {
    private let translator = GLSLTranslator()
    private static let device = MTLCreateSystemDefaultDevice()

    // MARK: Helpers

    private func shader(_ source: String, _ stage: GLShaderStage, file: StaticString = #filePath, line: UInt = #line) throws -> AnyObject {
        let compiled = translator.compile(source, stage: stage)
        return try XCTUnwrap(compiled.shader, "did not compile: \(compiled.log)", file: file, line: line)
    }

    private func program(_ vertex: String, _ fragment: String, locations: [String: Int] = [:],
                         file: StaticString = #filePath, line: UInt = #line) throws -> GLLinkedProgram {
        let linked = translator.link(vertex: try shader(vertex, .vertex, file: file, line: line),
                                     fragment: try shader(fragment, .fragment, file: file, line: line),
                                     attributeLocations: locations)
        return try XCTUnwrap(linked.program, "did not link: \(linked.log)", file: file, line: line)
    }

    /// The log of a shader that must not compile.
    private func refusal(_ source: String, _ stage: GLShaderStage, file: StaticString = #filePath, line: UInt = #line) -> String {
        let compiled = translator.compile(source, stage: stage)
        XCTAssertNil(compiled.shader, "compiled, and should not have", file: file, line: line)
        XCTAssertTrue(compiled.log.hasPrefix("ERROR: 0:"), "the log is \(compiled.log)", file: file, line: line)
        return compiled.log
    }

    /// The log of two shaders that compile and must not link.
    private func linkRefusal(_ vertex: String, _ fragment: String, locations: [String: Int] = [:],
                             file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let linked = translator.link(vertex: try shader(vertex, .vertex, file: file, line: line),
                                     fragment: try shader(fragment, .fragment, file: file, line: line),
                                     attributeLocations: locations)
        XCTAssertNil(linked.program, "linked, and should not have", file: file, line: line)
        XCTAssertTrue(linked.log.hasPrefix("ERROR: "), "the log is \(linked.log)", file: file, line: line)
        return linked.log
    }

    /// The Metal compiler's word on a program, in the newest version of
    /// its language and in an old one: Monad runs on macOS 14 too, whose
    /// Metal is stricter about references.
    @discardableResult
    private func metal(_ program: GLLinkedProgram, file: StaticString = #filePath, line: UInt = #line) throws -> MTLLibrary {
        let device = try XCTUnwrap(Self.device)
        let old = MTLCompileOptions()
        old.languageVersion = .version2_4
        for options in [old, nil] {
            do {
                let library = try device.makeLibrary(source: program.metal, options: options)
                XCTAssertEqual(Set(library.functionNames), ["monad_vertex", "monad_fragment"], file: file, line: line)
                if options == nil { return library }
            } catch {
                XCTFail("Metal does not take it: \(String("\(error)".prefix(1500)))\n\(program.metal)", file: file, line: line)
                throw error
            }
        }
        throw XCTSkip("unreachable")
    }

    /// One thing to draw: a program, its uniforms and attributes by name,
    /// into a square of `side` pixels of four floats each.
    private struct Scene {
        var vertex = GLSLTranslatorTests.wholePicture
        var fragment: String
        var floats: [String: [Float]] = [:]
        var ints: [String: [Int32]] = [:]
        /// A value for each vertex; a_position has the triangle that
        /// covers the picture unless said otherwise.
        var attributes: [String: [[Float]]] = [:]
        var textures: [String: MTLTexture] = [:]
        var locations: [String: Int] = [:]
        var flip: Float = 1
        var side = 4
        var points = false
        var vertexCount = 3
        /// A uniform given here that the program does not have is passed over.
        var lenient = false
    }

    /// A vertex shader for a triangle that covers the picture, handing
    /// the fragment shader where it is (-1…1, y up as OpenGL has it).
    private static let wholePicture = """
    attribute vec2 a_position;
    varying vec2 v_position;
    void main() {
        v_position = a_position;
        gl_Position = vec4(a_position, 0.0, 1.0);
    }
    """
    private static let triangle: [[Float]] = [[-1, -1], [3, -1], [-1, 3]]

    /// The picture a scene draws: its pixels row after row from the top,
    /// as Metal keeps them.
    private func draw(_ scene: Scene, file: StaticString = #filePath, line: UInt = #line) throws -> [SIMD4<Float>] {
        let device = try XCTUnwrap(Self.device)
        let program = try self.program(scene.vertex, scene.fragment, locations: scene.locations, file: file, line: line)
        let library = try metal(program, file: file, line: line)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "monad_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "monad_fragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba32Float
        let layout = MTLVertexDescriptor()
        var buffers: [(index: Int, buffer: MTLBuffer)] = []
        for attribute in program.attributes {
            let values = scene.attributes[attribute.name] ?? Self.triangle
            let shape: (columns: Int, rows: Int)
            switch attribute.type {
            case GL.FLOAT: shape = (1, 1)
            case GL.FLOAT_VEC2: shape = (1, 2)
            case GL.FLOAT_VEC3: shape = (1, 3)
            case GL.FLOAT_VEC4: shape = (1, 4)
            case GL.FLOAT_MAT2: shape = (2, 2)
            case GL.FLOAT_MAT3: shape = (3, 3)
            default: shape = (4, 4)
            }
            for column in 0..<shape.columns {
                let location = attribute.location + column
                layout.attributes[location].format = [.float, .float2, .float3, .float4][shape.rows - 1]
                layout.attributes[location].bufferIndex = location
                layout.attributes[location].offset = 0
                layout.layouts[location].stride = shape.rows * 4
                var data: [Float] = []
                for value in values { data += value[(column * shape.rows)..<((column + 1) * shape.rows)] }
                buffers.append((location, try XCTUnwrap(device.makeBuffer(bytes: data, length: data.count * 4))))
            }
        }
        descriptor.vertexDescriptor = layout
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        // The uniform block as the drawing part would fill it: its own
        // two floats, then each value where the program says it lies.
        var block = [UInt8](repeating: 0, count: program.uniformBytes)
        func uniform(_ name: String) throws -> GLUniform {
            try XCTUnwrap(program.uniforms.first { $0.name == name }, "no uniform \(name) in \(program.uniforms.map(\.name))", file: file, line: line)
        }
        try block.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: scene.flip, toByteOffset: 0, as: Float.self)
            raw.storeBytes(of: Float(scene.side), toByteOffset: 4, as: Float.self)
            func places(_ uniform: GLUniform) -> [Int] {
                var all: [Int] = []
                for element in 0..<uniform.size {
                    for column in 0..<uniform.columns {
                        for row in 0..<uniform.rows {
                            all.append(uniform.offset + element * uniform.stride + column * uniform.columnStride + row * 4)
                        }
                    }
                }
                return all
            }
            for (name, values) in scene.floats {
                if scene.lenient, !program.uniforms.contains(where: { $0.name == name }) { continue }
                for (place, value) in zip(places(try uniform(name)), values) { raw.storeBytes(of: value, toByteOffset: place, as: Float.self) }
            }
            for (name, values) in scene.ints {
                if scene.lenient, !program.uniforms.contains(where: { $0.name == name }) { continue }
                for (place, value) in zip(places(try uniform(name)), values) { raw.storeBytes(of: value, toByteOffset: place, as: Int32.self) }
            }
        }

        let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: scene.side, height: scene.side, mipmapped: false)
        target.usage = [.renderTarget, .shaderRead]
        target.storageMode = .shared
        let picture = try XCTUnwrap(device.makeTexture(descriptor: target))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = picture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        let commands = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        // OpenGL's front is counter-clockwise; setting that is the
        // drawing part's to do, and here the test's.
        encoder.setFrontFacing(.counterClockwise)
        for (index, buffer) in buffers { encoder.setVertexBuffer(buffer, offset: 0, index: index) }
        let uniforms = try XCTUnwrap(device.makeBuffer(bytes: block, length: block.count))
        encoder.setVertexBuffer(uniforms, offset: 0, index: 30)
        encoder.setFragmentBuffer(uniforms, offset: 0, index: 30)
        let nearest = try XCTUnwrap(device.makeSamplerState(descriptor: MTLSamplerDescriptor()))
        for (name, texture) in scene.textures {
            // An element of an array of samplers takes the texture after
            // the one before it.
            var found = program.uniforms.first { $0.name == name }?.texture
            if found == nil, let open = name.lastIndex(of: "["), let element = Int(name[name.index(after: open)...].dropLast()) {
                found = (try uniform(String(name[..<open]) + "[0]").texture).map { $0 + element }
            }
            let index = try XCTUnwrap(found, "no sampler \(name)", file: file, line: line)
            encoder.setVertexTexture(texture, index: index)
            encoder.setVertexSamplerState(nearest, index: index)
            encoder.setFragmentTexture(texture, index: index)
            encoder.setFragmentSamplerState(nearest, index: index)
        }
        encoder.drawPrimitives(type: scene.points ? .point : .triangle, vertexStart: 0, vertexCount: scene.vertexCount)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertNil(commands.error, file: file, line: line)
        var pixels = [Float](repeating: 0, count: scene.side * scene.side * 4)
        picture.getBytes(&pixels, bytesPerRow: scene.side * 16, from: MTLRegionMake2D(0, 0, scene.side, scene.side), mipmapLevel: 0)
        return (0..<(scene.side * scene.side)).map { SIMD4(pixels[$0 * 4], pixels[$0 * 4 + 1], pixels[$0 * 4 + 2], pixels[$0 * 4 + 3]) }
    }

    /// A texture of two by two pixels: red and green in its first row,
    /// blue and white in its second.
    private func fourColors(cube: Bool = false) throws -> MTLTexture {
        let device = try XCTUnwrap(Self.device)
        let descriptor = cube
            ? MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba8Unorm, size: 2, mipmapped: false)
            : MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
        for face in 0..<(cube ? 6 : 1) {
            texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, slice: face, withBytes: pixels, bytesPerRow: 8, bytesPerImage: 16)
        }
        return texture
    }

    /// The first line two texts differ in, or nil when they are the same.
    private func difference(_ one: String, _ other: String) -> String? {
        let first = one.split(separator: "\n", omittingEmptySubsequences: false)
        let second = other.split(separator: "\n", omittingEmptySubsequences: false)
        for (a, b) in zip(first, second) where a != b { return "\(a)\nand\n\(b)" }
        return first.count == second.count ? nil : "one is \(first.count) lines and the other \(second.count)"
    }

    /// A fragment shader whose colour has a bit for each condition that
    /// holds.
    private static func conditions(_ conditions: [String], declarations: String, constants: Bool) -> String {
        var source = "precision highp float;\n"
        if constants {
            source += "const float one = 1.0; const float two = 2.0; const float three = 3.0;\n"
            source += "const int ione = 1; const int itwo = 2; const bool yes = true;\n"
        } else {
            source += "uniform float one; uniform float two; uniform float three;\n"
            source += "uniform int ione; uniform int itwo; uniform bool yes;\n"
        }
        source += declarations + "\nvoid main() {\n    vec4 bits = vec4(0.0);\n"
        for (index, condition) in conditions.enumerated() {
            source += "    if (\(condition)) bits[\(index / 20)] += \(Float(1 << (index % 20)));\n"
        }
        return source + "    gl_FragColor = bits;\n}\n"
    }

    /// Which of some GLSL conditions do not hold when a fragment shader
    /// works them out: one bit of the pixel's colour for each. `one`,
    /// `two`, `three` (floats), `ione`, `itwo` (ints) and `yes` (a bool)
    /// are there for them to use: uniforms, so that Metal does the work,
    /// or constants, so that the translator's own arithmetic does.
    private func failing(_ conditions: [String], declarations: String = "", constants: Bool, floats: [String: [Float]] = [:],
                         ints: [String: [Int32]] = [:], textures: [String: MTLTexture] = [:],
                         file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        XCTAssertLessThanOrEqual(conditions.count, 80)
        let source = Self.conditions(conditions, declarations: declarations, constants: constants)
        var scene = Scene(fragment: source, side: 1)
        // Those no condition names are not active, and have no place.
        scene.lenient = true
        scene.floats = floats.merging(["one": [1], "two": [2], "three": [3]]) { first, _ in first }
        scene.ints = ints.merging(["ione": [1], "itwo": [2], "yes": [1]]) { first, _ in first }
        scene.textures = textures
        let pixel = try draw(scene, file: file, line: line)[0]
        return conditions.enumerated().filter { index, _ in
            Int(pixel[index / 20]) & (1 << (index % 20)) == 0
        }.map(\.element)
    }

    // MARK: A corpus of shaders

    private static let flatColor = (
        vertex: """
        attribute vec4 a_position;
        uniform mat4 u_mvp;
        void main() {
            gl_Position = u_mvp * a_position;
        }
        """,
        fragment: """
        precision mediump float;
        uniform vec4 u_color;
        void main() {
            gl_FragColor = u_color;
        }
        """)

    /// The lighting a gears demo does in its vertex shader.
    private static let gears = (
        vertex: """
        attribute vec3 position;
        attribute vec3 normal;

        uniform mat4 ModelViewProjectionMatrix;
        uniform mat4 NormalMatrix;
        uniform mat3 NormalMatrix3;
        uniform vec4 LightSourcePosition;
        uniform vec4 MaterialColor;

        varying vec4 Color;

        void main(void)
        {
            // Transform the normal to eye coordinates
            vec3 N = normalize(vec3(NormalMatrix * vec4(normal, 1.0)));
            N += normalize(NormalMatrix3 * normal);

            /* The LightSourcePosition is actually its direction for directional light */
            vec3 L = normalize(LightSourcePosition.xyz);

            // Multiply the diffuse value by the vertex color (which is fixed in this case)
            // to get the actual color that we will use to draw this vertex with
            float diffuse = max(dot(N, L), 0.0);
            Color = diffuse * MaterialColor;

            // Transform the position to clip coordinates
            gl_Position = ModelViewProjectionMatrix * vec4(position, 1.0);
        }
        """,
        fragment: """
        precision mediump float;
        varying vec4 Color;

        void main(void)
        {
            gl_FragColor = Color;
        }
        """)

    private static let texturedQuad = (
        vertex: """
        attribute vec2 a_position;
        attribute vec2 a_texcoord;
        varying vec2 v_texcoord;
        void main() {
            v_texcoord = a_texcoord;
            gl_Position = vec4(a_position, 0.0, 1.0);
        }
        """,
        fragment: """
        precision mediump float;
        varying vec2 v_texcoord;
        uniform sampler2D u_texture;
        uniform float u_alpha;
        void main() {
            vec4 texel = texture2D(u_texture, v_texcoord);
            gl_FragColor = vec4(texel.rgb, texel.a * u_alpha);
        }
        """)

    private static let phong = (
        vertex: """
        attribute vec3 a_position;
        attribute vec3 a_normal;
        uniform mat4 u_modelView;
        uniform mat4 u_projection;
        uniform mat3 u_normalMatrix;
        varying vec3 v_normal;
        varying vec3 v_eye;
        void main() {
            vec4 eye = u_modelView * vec4(a_position, 1.0);
            v_eye = eye.xyz;
            v_normal = u_normalMatrix * a_normal;
            gl_Position = u_projection * eye;
        }
        """,
        fragment: """
        precision mediump float;
        struct Material {
            vec3 ambient;
            vec3 diffuse;
            vec3 specular;
            float shininess;
        };
        struct Light {
            vec3 position;
            vec3 color;
            float attenuation;
        };
        const int LIGHTS = 4;
        uniform Material u_material;
        uniform Light u_lights[LIGHTS];
        uniform int u_lightCount;
        varying vec3 v_normal;
        varying vec3 v_eye;

        vec3 shade(Light light, vec3 n, vec3 v) {
            vec3 toLight = light.position - v_eye;
            float distance = length(toLight);
            vec3 l = toLight / distance;
            vec3 h = normalize(l + v);
            float diffuse = max(dot(n, l), 0.0);
            float specular = diffuse > 0.0 ? pow(max(dot(n, h), 0.0), u_material.shininess) : 0.0;
            float fade = 1.0 / (1.0 + light.attenuation * distance * distance);
            return fade * light.color * (u_material.diffuse * diffuse + u_material.specular * specular);
        }

        void main() {
            vec3 n = normalize(v_normal);
            vec3 v = normalize(-v_eye);
            vec3 color = u_material.ambient;
            for (int i = 0; i < LIGHTS; i++) {
                if (i >= u_lightCount) break;
                color += shade(u_lights[i], n, v);
            }
            gl_FragColor = vec4(color, 1.0);
        }
        """)

    private static let functions = (
        vertex: wholePicture,
        fragment: """
        precision highp float;
        varying vec2 v_position;
        uniform float u_time;

        float hash(float n);
        float hash(vec2 p) { return hash(dot(p, vec2(12.9898, 78.233))); }
        float hash(float n) { return fract(sin(n) * 43758.5453); }

        void polar(in vec2 p, out float radius, out float angle) {
            radius = length(p);
            angle = atan(p.y, p.x);
        }
        void rotate(inout vec2 p, const in float by) {
            float c = cos(by), s = sin(by);
            p = mat2(c, s, -s, c) * p;
        }
        vec3 tint(vec3 color, float amount) { return color * amount; }
        vec4 tint(vec4 color, float amount) { return vec4(tint(color.rgb, amount), color.a); }
        bool inside(vec2 p, float radius) { return dot(p, p) < radius * radius; }

        void main() {
            vec2 p = v_position;
            rotate(p, u_time);
            float radius, angle;
            polar(p, radius, angle);
            vec4 color = vec4(hash(p), hash(radius), angle, 1.0);
            rotate(color.xy, angle);
            if (!inside(p, 0.5)) color = tint(color, 0.25);
            gl_FragColor = color;
        }
        """)

    private static let builtinVariables = (
        vertex: """
        attribute vec4 a_position;
        attribute float a_size;
        void main() {
            gl_Position = a_position;
            gl_PointSize = a_size * 2.0;
        }
        """,
        fragment: """
        precision mediump float;
        uniform vec2 u_resolution;
        void main() {
            vec2 where = gl_FragCoord.xy / u_resolution;
            vec2 spot = gl_PointCoord - vec2(0.5);
            if (dot(spot, spot) > 0.25) discard;
            float depth = gl_FragCoord.z / gl_FragCoord.w;
            gl_FragColor = gl_FrontFacing ? vec4(where, depth, 1.0) : vec4(0.0, 0.0, 0.0, 1.0);
        }
        """)

    private static let macros = (
        vertex: """
        #version 100
        #define POSITION(p) vec4(p, 0.0, 1.0)
        #ifdef GL_ES
        precision highp float;
        #endif
        attribute vec2 a_position;
        varying vec2 v_uv;
        void main() {
            v_uv = a_position * 0.5 + 0.5;
            gl_Position = POSITION(a_position);
        }
        """,
        fragment: #"""
        #version 100
        #ifdef GL_ES
        #  ifdef GL_FRAGMENT_PRECISION_HIGH
        precision highp float;
        #  else
        precision mediump float;
        #  endif
        #endif
        #define PI 3.14159265
        #define TAU (2.0 * PI)
        #define SQUARE(x) ((x) * (x))
        #define MIX3(a, b, t) mix(a, \
                                  b, t)
        #define STRIPES 4
        #if STRIPES > 2 && defined(PI) && !defined(NO_STRIPES)
        #define STRIPED 1
        #elif STRIPES == 2
        #error two stripes are not enough
        #else
        #define STRIPED 0
        #endif
        #pragma optimize(on)
        #extension GL_OES_standard_derivatives : enable
        varying vec2 v_uv;
        void main() {
            float wave = sin(v_uv.x * TAU * float(STRIPES));
        #if STRIPED
            float edge = fwidth(wave);
        #else
            float edge = 0.0;
        #endif
            vec3 color = MIX3(vec3(SQUARE(v_uv.x)), vec3(1.0, 0.5, 0.0), smoothstep(-edge, edge, wave));
            gl_FragColor = vec4(color, float(__VERSION__) / 100.0 * float(GL_ES));
        }
        """#)

    private static let uniformArray = (
        vertex: wholePicture,
        fragment: """
        precision mediump float;
        const int TAPS = 5;
        uniform float u_weights[TAPS];
        uniform vec2 u_offsets[TAPS];
        uniform sampler2D u_source;
        varying vec2 v_position;
        void main() {
            vec4 sum = vec4(0.0);
            for (int i = 0; i < TAPS; ++i) {
                sum += texture2D(u_source, v_position * 0.5 + 0.5 + u_offsets[i]) * u_weights[i];
            }
            gl_FragColor = sum;
        }
        """)

    private static let mathFunctions = (
        vertex: wholePicture,
        fragment: """
        precision mediump float;
        varying vec2 v_position;
        uniform samplerCube u_sky;
        uniform mat3 u_basis;
        uniform float u_ior;
        void main() {
            vec3 eye = normalize(vec3(v_position, -1.0));
            vec3 normal = normalize(matrixCompMult(u_basis, u_basis) * vec3(0.0, 0.0, 1.0));
            vec3 mirrored = reflect(eye, normal);
            vec3 bent = refract(eye, normal, u_ior);
            float angle = atan(v_position.y, v_position.x) + atan(v_position.y / 2.0);
            float band = mod(angle, 0.5) * 2.0;
            bvec3 dark = lessThan(mirrored, vec3(0.0));
            vec3 sky = mix(textureCube(u_sky, mirrored).rgb, textureCube(u_sky, bent, 1.0).rgb, step(0.5, band));
            if (any(dark)) sky *= smoothstep(0.0, 1.0, band);
            gl_FragColor = vec4(sky, 1.0);
        }
        """)

    private static let matrixAttribute = (
        vertex: """
        attribute vec3 a_position;
        attribute mat3 a_basis;
        attribute mat2 a_spin;
        uniform mat4 u_mvp;
        varying vec3 v_color;
        varying mat2 v_spin;
        void main() {
            v_color = a_basis[1] + a_basis * a_position;
            v_spin = a_spin;
            gl_Position = u_mvp * vec4(a_basis * a_position, 1.0);
        }
        """,
        fragment: """
        precision mediump float;
        varying vec3 v_color;
        varying mat2 v_spin;
        void main() {
            gl_FragColor = vec4(v_color.xy * v_spin, v_color.z, 1.0);
        }
        """)

    /// What a realistic program's shaders become is Metal source that
    /// Metal's own compiler takes, with both entry points in it.
    func testRealisticShadersBecomeMetalThatCompiles() throws {
        let corpus = [Self.flatColor, Self.gears, Self.texturedQuad, Self.phong, Self.functions, Self.builtinVariables,
                      Self.macros, Self.uniformArray, Self.mathFunctions, Self.matrixAttribute]
        for (index, pair) in corpus.enumerated() {
            let linked = try program(pair.vertex, pair.fragment)
            XCTAssertNoThrow(try metal(linked), "pair \(index)")
            XCTAssertTrue(linked.metal.contains("monad_vertex(") && linked.metal.contains("monad_fragment("))
            XCTAssertTrue(linked.metal.contains("[[buffer(30)]]"))
        }
    }

    /// A shader that compiles with nothing to remark has an empty log.
    func testAShaderThatCompilesHasAnEmptyLog() {
        let compiled = translator.compile(Self.gears.vertex, stage: .vertex)
        XCTAssertNotNil(compiled.shader)
        XCTAssertEqual(compiled.log, "")
    }

    // MARK: What is drawn

    /// The uniform a flat-colour program is given is the colour of every
    /// pixel it draws.
    func testAFlatColourFillsThePicture() throws {
        let pixels = try draw(Scene(
            fragment: "precision mediump float; uniform vec4 u_color; void main() { gl_FragColor = u_color; }",
            floats: ["u_color": [0.25, 0.5, 0.75, 1]]))
        XCTAssertEqual(pixels.count, 16)
        for pixel in pixels { XCTAssertEqual(pixel, SIMD4(0.25, 0.5, 0.75, 1)) }
    }

    /// The first float of the uniform block is what gl_Position.y is
    /// multiplied by: 1 leaves the top of OpenGL's picture in Metal's
    /// first row, -1 puts its bottom there.
    func testTheFirstFloatOfTheBlockTurnsThePictureOver() throws {
        var scene = Scene(fragment: """
        precision mediump float;
        varying vec2 v_position;
        void main() { gl_FragColor = vec4(v_position.y > 0.0 ? 1.0 : 0.0, v_position.x > 0.0 ? 1.0 : 0.0, 0.0, 1.0); }
        """)
        let upright = try draw(scene)
        XCTAssertEqual(upright[0], SIMD4(1, 0, 0, 1), "the first row is the top")
        XCTAssertEqual(upright[3], SIMD4(1, 1, 0, 1))
        XCTAssertEqual(upright[12], SIMD4(0, 0, 0, 1))
        scene.flip = -1
        let turned = try draw(scene)
        XCTAssertEqual(turned[0], SIMD4(0, 0, 0, 1), "the first row is OpenGL's bottom row")
        XCTAssertEqual(turned[3], SIMD4(0, 1, 0, 1))
        XCTAssertEqual(turned[12], SIMD4(1, 0, 0, 1))
    }

    /// gl_FragCoord counts rows from the bottom of OpenGL's picture: the
    /// height less Metal's y when the picture is drawn as it is, Metal's
    /// y when it is drawn turned over. Its z is the depth, 0…1, of a
    /// gl_Position.z of -w…w, and its w is 1/w.
    func testFragCoordIsOpenGLs() throws {
        var scene = Scene(
            vertex: "attribute vec2 a_position; void main() { gl_Position = vec4(a_position * 2.0, -1.0, 2.0); }",
            fragment: "precision highp float; void main() { gl_FragColor = gl_FragCoord; }")
        let upright = try draw(scene)
        XCTAssertEqual(upright[0], SIMD4(0.5, 3.5, 0.25, 0.5), "top left: x 0.5, y a half below the height")
        XCTAssertEqual(upright[15], SIMD4(3.5, 0.5, 0.25, 0.5))
        scene.flip = -1
        let turned = try draw(scene)
        XCTAssertEqual(turned[0], SIMD4(0.5, 0.5, 0.25, 0.5), "Metal's first row is OpenGL's row 0")
        XCTAssertEqual(turned[15], SIMD4(3.5, 3.5, 0.25, 0.5))
    }

    /// OpenGL's depth runs from -w to w and Metal's from 0 to w: the
    /// nearest gl_Position.z is depth 0 and the farthest depth 1.
    func testDepthGoesFromOpenGLsRangeToMetals() throws {
        for (z, depth) in [(Float(-1), Float(0)), (0, 0.5), (1, 1)] {
            let pixels = try draw(Scene(
                vertex: "attribute vec2 a_position; uniform float u_z; void main() { gl_Position = vec4(a_position, u_z, 1.0); }",
                fragment: "precision highp float; void main() { gl_FragColor = vec4(gl_FragCoord.z); }",
                floats: ["u_z": [z]]))
            XCTAssertEqual(pixels[5].x, depth, accuracy: 1e-6)
        }
    }

    /// gl_FrontFacing is Metal's front_facing as it is: a triangle drawn
    /// counter-clockwise is the front when the drawing part says counter-
    /// clockwise is, whichever way up the picture is.
    func testFrontFacingIsMetals() throws {
        var scene = Scene(fragment: "precision mediump float; void main() { gl_FragColor = vec4(gl_FrontFacing ? 1.0 : 0.25); }")
        XCTAssertEqual(try draw(scene)[0].x, 1)
        scene.attributes["a_position"] = [[-1, -1], [-1, 3], [3, -1]]
        XCTAssertEqual(try draw(scene)[0].x, 0.25, "clockwise is the back")
    }

    /// A point is as large as gl_PointSize says, and gl_PointCoord runs
    /// over it from its top left as it is seen: when the picture is drawn
    /// turned over, the point's top is in Metal's last row.
    func testAPointHasItsSizeAndItsCoordinates() throws {
        var scene = Scene(
            vertex: "uniform float u_size; void main() { gl_Position = vec4(0.0, 0.0, 0.0, 1.0); gl_PointSize = u_size; }",
            fragment: "precision highp float; void main() { gl_FragColor = vec4(gl_PointCoord, 1.0, 1.0); }",
            floats: ["u_size": [2]], points: true, vertexCount: 1)
        var pixels = try draw(scene)
        XCTAssertEqual(pixels[0], SIMD4(0, 0, 0, 0), "a point of 2 pixels leaves the corner alone")
        XCTAssertEqual(pixels[5], SIMD4(0.25, 0.25, 1, 1))
        XCTAssertEqual(pixels[10], SIMD4(0.75, 0.75, 1, 1))
        scene.floats["u_size"] = [4]
        pixels = try draw(scene)
        XCTAssertEqual(pixels[0], SIMD4(0.125, 0.125, 1, 1))
        XCTAssertEqual(pixels[15], SIMD4(0.875, 0.875, 1, 1))
        scene.flip = -1
        pixels = try draw(scene)
        XCTAssertEqual(pixels[0], SIMD4(0.125, 0.875, 1, 1))
        XCTAssertEqual(pixels[15], SIMD4(0.875, 0.125, 1, 1))
    }

    /// The derivatives are OpenGL's too: gl_FragCoord.y grows by one from
    /// a row to the one above it, whichever way up the picture is drawn.
    func testDerivativesFollowOpenGLsRows() throws {
        var scene = Scene(fragment: """
        #extension GL_OES_standard_derivatives : require
        precision highp float;
        void main() { gl_FragColor = vec4(dFdx(gl_FragCoord.x), dFdy(gl_FragCoord.y), fwidth(gl_FragCoord.x * 2.0), dFdy(gl_FragCoord.x)); }
        """)
        XCTAssertEqual(try draw(scene)[5], SIMD4(1, 1, 2, 0))
        scene.flip = -1
        XCTAssertEqual(try draw(scene)[5], SIMD4(1, 1, 2, 0))
    }

    /// A texture is read where the varying texture coordinates say:
    /// (0, 0) is the first pixel of the texture's memory.
    func testATexturedQuadShowsItsTexture() throws {
        let pixels = try draw(Scene(
            vertex: Self.texturedQuad.vertex, fragment: Self.texturedQuad.fragment,
            floats: ["u_alpha": [0.5]],
            attributes: ["a_texcoord": [[0, 0], [2, 0], [0, 2]]],
            textures: ["u_texture": try fourColors()]))
        // The picture's bottom left is texture coordinate (0, 0).
        XCTAssertEqual(pixels[12], SIMD4(1, 0, 0, 0.5))
        XCTAssertEqual(pixels[15], SIMD4(0, 1, 0, 0.5))
        XCTAssertEqual(pixels[0], SIMD4(0, 0, 1, 0.5))
        XCTAssertEqual(pixels[3], SIMD4(1, 1, 1, 0.5))
    }

    /// The texture lookups a vertex shader has, with a level of detail
    /// and without, and the projective ones, read the texture too.
    func testAVertexShaderReadsATexture() throws {
        let pixels = try draw(Scene(
            vertex: """
            attribute vec2 a_position;
            uniform sampler2D u_texture;
            uniform samplerCube u_cube;
            varying vec4 v_color;
            void main() {
                v_color = texture2DLod(u_texture, vec2(0.25, 0.25), 0.0) + texture2D(u_texture, vec2(0.75, 0.25))
                    + texture2DProjLod(u_texture, vec3(0.5, 1.5, 2.0), 0.0) + textureCubeLod(u_cube, vec3(1.0, 0.0, 0.0), 0.0) * 0.0;
                gl_Position = vec4(a_position, 0.0, 1.0);
            }
            """,
            fragment: "precision mediump float; varying vec4 v_color; void main() { gl_FragColor = v_color; }",
            textures: ["u_texture": try fourColors(), "u_cube": try fourColors(cube: true)]))
        XCTAssertEqual(pixels[0], SIMD4(1, 1, 1, 3), "red and green and blue")
    }

    /// A struct uniform, an array of structs and an array in a struct lie
    /// in the block where the program's uniforms say, by Metal's rules: a
    /// vec3 is 16 bytes wide, a struct as wide as a multiple of 16.
    func testStructUniformsLieWhereTheProgramSays() throws {
        let pixels = try draw(Scene(
            fragment: """
            precision mediump float;
            struct Light { vec3 color; float k[2]; bool on; };
            struct Material { float shininess; vec3 tint; mat3 basis; ivec2 cell; };
            uniform Light u_lights[3];
            uniform Material u_material;
            uniform float u_last;
            void main() {
                vec3 color = vec3(0.0);
                for (int i = 0; i < 3; i++) {
                    if (u_lights[i].on) color += u_lights[i].color * u_lights[i].k[1];
                }
                gl_FragColor = vec4(color + u_material.basis * u_material.tint,
                                    u_material.shininess + float(u_material.cell.y) + u_last);
            }
            """,
            floats: [
                "u_lights[0].color": [100, 100, 100], "u_lights[0].k[0]": [5, 1],
                "u_lights[1].color": [1, 2, 3], "u_lights[1].k[0]": [9, 2],
                "u_lights[2].color": [10, 20, 30], "u_lights[2].k[0]": [9, 0.5],
                "u_material.shininess": [8], "u_material.tint": [1, 1, 2],
                "u_material.basis": [1, 0, 0, 0, 1, 0, 100, 200, 300], "u_last": [0.25],
            ],
            ints: ["u_lights[0].on": [0], "u_lights[1].on": [1], "u_lights[2].on": [7], "u_material.cell": [3, 4]]))
        XCTAssertEqual(pixels[0], SIMD4(2 + 5 + 201, 4 + 10 + 401, 6 + 15 + 600, 12.25))
    }

    /// A matrix times a vector, a vector times a matrix and a matrix
    /// times a matrix are OpenGL's, with matrices given column by column.
    func testMatricesMultiplyAsOpenGLs() throws {
        let pixels = try draw(Scene(
            fragment: """
            precision highp float;
            uniform mat3 u_m;
            uniform vec3 u_v;
            uniform mat2 u_a;
            uniform mat2 u_b;
            varying vec2 v_position;
            void main() {
                vec3 result = v_position.x < 0.0 ? u_m * u_v : u_v * u_m;
                gl_FragColor = v_position.y > 0.0 ? vec4(result, 1.0) : vec4((u_a * u_b)[0], (u_a * u_b)[1]);
            }
            """,
            floats: ["u_m": [1, 2, 3, 4, 5, 6, 7, 8, 9], "u_v": [1, 10, 100], "u_a": [1, 2, 3, 4], "u_b": [5, 6, 7, 8]]))
        XCTAssertEqual(pixels[0], SIMD4(741, 852, 963, 1), "m * v: the columns of m by the numbers of v")
        XCTAssertEqual(pixels[3], SIMD4(321, 654, 987, 1), "v * m: v by each column of m")
        XCTAssertEqual(pixels[12], SIMD4(23, 34, 31, 46))
    }

    /// A mat3 attribute comes in as three vectors, a column at each of
    /// three locations one after the other.
    func testAMatrixAttributeTakesALocationForEachColumn() throws {
        let matrix: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        let pixels = try draw(Scene(
            vertex: """
            attribute vec2 a_position;
            attribute mat3 a_matrix;
            varying vec3 v_color;
            void main() {
                v_color = a_matrix * vec3(1.0, 10.0, 100.0) + a_matrix[2];
                gl_Position = vec4(a_position, 0.0, 1.0);
            }
            """,
            fragment: "precision highp float; varying vec3 v_color; void main() { gl_FragColor = vec4(v_color, 1.0); }",
            attributes: ["a_matrix": [matrix, matrix, matrix]],
            locations: ["a_matrix": 5]))
        XCTAssertEqual(pixels[0], SIMD4(748, 860, 972, 1))
    }

    /// A varying that is a matrix, or an array, reaches the fragment
    /// shader whole.
    func testMatrixAndArrayVaryingsArrive() throws {
        let pixels = try draw(Scene(
            vertex: """
            attribute vec2 a_position;
            varying mat3 v_matrix;
            varying float v_list[3];
            varying vec2 v_pairs[2];
            void main() {
                v_matrix = mat3(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0);
                v_list[0] = 10.0; v_list[1] = 20.0; v_list[2] = 30.0;
                v_pairs[0] = vec2(0.5); v_pairs[1] = vec2(0.25, 0.125);
                gl_Position = vec4(a_position, 0.0, 1.0);
            }
            """,
            fragment: """
            precision highp float;
            varying mat3 v_matrix;
            varying float v_list[3];
            varying vec2 v_pairs[2];
            void main() { gl_FragColor = vec4(v_matrix[2].y + v_list[1], v_matrix[0].z + v_list[2], v_pairs[1].y, v_pairs[0].x); }
            """))
        XCTAssertEqual(pixels[0], SIMD4(28, 33, 0.125, 0.5))
    }

    /// gl_FragData[0] is the colour as gl_FragColor is.
    func testFragDataIsTheColour() throws {
        let pixels = try draw(Scene(fragment: "precision mediump float; void main() { gl_FragData[0] = vec4(0.5, 0.25, 0.0, 1.0); }"))
        XCTAssertEqual(pixels[0], SIMD4(0.5, 0.25, 0, 1))
    }

    /// discard leaves the pixel as it was.
    func testDiscardLeavesThePixel() throws {
        let pixels = try draw(Scene(fragment: """
        precision mediump float;
        varying vec2 v_position;
        void main() { if (v_position.x < 0.0) discard; gl_FragColor = vec4(1.0); }
        """))
        XCTAssertEqual(pixels[0], SIMD4(0, 0, 0, 0))
        XCTAssertEqual(pixels[3], SIMD4(1, 1, 1, 1))
    }

    /// A bool or an int uniform is a 32-bit int in the block, a bool
    /// true when it is not zero; so are their vectors and arrays.
    func testBoolAndIntUniformsAreIntsInTheBlock() throws {
        let pixels = try draw(Scene(
            fragment: """
            precision highp float;
            uniform bool u_flags[3];
            uniform ivec3 u_cell;
            uniform bvec2 u_pair;
            uniform int u_counts[2];
            uniform bool u_single;
            void main() {
                float flags = 0.0, bit = 1.0;
                for (int i = 0; i < 3; i++) { if (u_flags[i]) flags += bit; bit *= 2.0; }
                gl_FragColor = vec4(flags, float(u_cell.x * 100 + u_cell.y * 10 + u_cell.z), float(u_pair.x) + 2.0 * float(u_pair.y),
                                    float(u_counts[1] - u_counts[0]) + (u_single ? 0.5 : 0.0));
            }
            """,
            ints: ["u_flags[0]": [1, 0, -1], "u_cell": [1, 2, 3], "u_pair": [0, 1], "u_counts[0]": [3, 10], "u_single": [1]], side: 1))
        XCTAssertEqual(pixels[0], SIMD4(5, 123, 2, 7.5))
    }

    /// A sampler in a struct, in an array of structs and in an array is
    /// a texture of its own, and can be handed to a function.
    func testSamplersInStructsAndArraysAreTextures() throws {
        let device = try XCTUnwrap(Self.device)
        func solid(_ color: [UInt8]) throws -> MTLTexture {
            let texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: color, bytesPerRow: 4)
            return texture
        }
        let pixels = try draw(Scene(
            fragment: """
            precision highp float;
            struct Layer { sampler2D map; float weight; };
            uniform Layer u_layers[2];
            uniform sampler2D u_maps[2];
            uniform samplerCube u_cube;
            vec4 read(sampler2D map, vec2 at) { return texture2D(map, at); }
            vec4 weigh(Layer layer, vec2 at) { return read(layer.map, at) * layer.weight; }
            void main() {
                gl_FragColor = weigh(u_layers[0], vec2(0.5)) + weigh(u_layers[1], vec2(0.5)) + read(u_maps[1], vec2(0.5))
                    + textureCube(u_cube, vec3(1.0, 0.0, 0.0)) * 0.0;
            }
            """,
            floats: ["u_layers[0].weight": [0.5], "u_layers[1].weight": [0.25]],
            textures: ["u_layers[0].map": try solid([255, 0, 0, 255]), "u_layers[1].map": try solid([0, 255, 0, 255]),
                       "u_maps[0]": try solid([255, 255, 255, 255]), "u_maps[1]": try solid([0, 0, 255, 255]),
                       "u_cube": try fourColors(cube: true)],
            side: 1))
        XCTAssertEqual(pixels[0], SIMD4(0.5, 0.25, 1, 1.75))
    }

    /// Every texture lookup the two kinds of shader have, with a bias,
    /// with a level of detail and projected, is something Metal takes.
    func testEveryTextureLookupCompiles() throws {
        let linked = try program("""
        attribute vec4 p;
        uniform sampler2D s;
        uniform samplerCube c;
        varying vec4 v;
        void main() {
            v = texture2D(s, p.xy) + texture2DLod(s, p.xy, 1.0) + texture2DProj(s, p.xyz) + texture2DProj(s, p)
                + texture2DProjLod(s, p.xyz, 0.0) + texture2DProjLod(s, p, 0.0) + textureCube(c, p.xyz) + textureCubeLod(c, p.xyz, 2.0);
            gl_Position = p;
        }
        """, """
        precision mediump float;
        uniform sampler2D s;
        uniform samplerCube c;
        varying vec4 v;
        void main() {
            gl_FragColor = texture2D(s, v.xy) + texture2D(s, v.xy, 1.0) + texture2DProj(s, v.xyz) + texture2DProj(s, v.xyz, 1.0)
                + texture2DProj(s, v) + texture2DProj(s, v, -1.0) + textureCube(c, v.xyz) + textureCube(c, v.xyz, 0.5);
        }
        """)
        XCTAssertEqual(linked.uniforms.map(\.texture), [0, 1])
        XCTAssertNoThrow(try metal(linked))
    }

    /// Precision qualifiers, precision statements and invariant are read
    /// wherever the language has them, and change nothing.
    func testQualifiersAreReadAndChangeNothing() throws {
        let linked = try program("""
        invariant gl_Position;
        attribute highp vec4 a_position;
        uniform mediump mat4 u_matrix;
        varying lowp vec4 v_color;
        invariant varying mediump vec2 v_uv;
        invariant v_color;
        precision lowp int;
        precision mediump sampler2D;
        highp float scale(const in mediump float x, lowp int n);
        highp float scale(const in mediump float x, lowp int n) { precision highp float; float y = x; return y * float(n); }
        void main() { v_color = vec4(scale(0.5, 2)); v_uv = a_position.xy; gl_Position = u_matrix * a_position; }
        """, """
        varying lowp vec4 v_color;
        varying mediump vec2 v_uv;
        uniform lowp sampler2D u_map;
        struct Tone { mediump float gain; lowp vec3 tint; };
        uniform Tone u_tone;
        void main() {
            mediump float gain = u_tone.gain;
            { precision highp float; float local = gain; gain = local; }
            gl_FragColor = v_color * texture2D(u_map, v_uv) * gain + vec4(u_tone.tint, 0.0);
        }
        """)
        XCTAssertNoThrow(try metal(linked))
        XCTAssertTrue(refusal("invariant nothing;\nvoid main() {}", .vertex).contains("'nothing' is not declared"))
    }

    private static let corners = """
        precision highp float;
        uniform float u;
        uniform int n;
        varying vec2 v_position;
        struct Inner { vec2 at; float weights[3]; };
        struct Outer { Inner inner; mat3 basis; bvec2 flags; ivec3 cell; };
        struct Plain { vec2 at; ivec2 cell; bool on; };
        const Plain ORIGIN = Plain(vec2(0.0, 1.0), ivec2(2, 3), true);
        float g_table[4];
        Outer g_outer;
        struct { float x; vec2 y; } g_anonymous;
        Plain g_plain = Plain(vec2(1.0), ivec2(0), false);
        const float g_bent = refract(0.5, 1.0, 0.75);
        Outer build(Inner inner, const mat3 basis) { return Outer(inner, basis, bvec2(true, false), ivec3(1, 2, 3)); }
        void bump(inout Outer o, out float total) {
            total = 0.0;
            for (int i = 0; i < 3; ++i) { o.inner.weights[i] += float(i); total += o.inner.weights[i]; }
            o.basis[1].yz = o.inner.at;
        }
        float pick(float table[4], int which) { return table[which]; }
        float unused(float) { return 1.0; }
        void main() {
            Inner inner;
            inner.at = v_position;
            inner.weights[0] = u; inner.weights[1] = u * 2.0; inner.weights[2] = -u;
            float total;
            bump(g_outer, total);
            g_outer.inner.at = build(inner, mat3(u)).inner.at;
            g_table[n] = total;
            g_table[3 - 1] += pick(g_table, n + 1) + pick(g_table, 3);
            g_anonymous.y = ORIGIN.at + vec2(ORIGIN.cell) * float(ORIGIN.on);
            struct Local { float a; } local;
            local.a = g_anonymous.y.x + g_bent;
            Plain plain = g_plain;
            plain = n > 0 ? ORIGIN : plain;
            mat4 m = mat4(u);
            m[n][n + 1] += 1.0;
            m[2].wx = vec2(m[n].y, local.a);
            vec4 q = vec4(0.0);
            q[n] = 1.0;
            q.yz = q.zy + m[3].xw * 0.5;
            ivec4 cells = ivec4(n, -n, n * 2, n / 2);
            cells.xw += ivec2(1) * cells.yz;
            cells = -cells;
            bvec4 mask = bvec4(cells.x > 0, q.x != 0.0, g_outer.flags);
            bool every = all(mask) || (any(mask) && !mask.z) ^^ (mask == bvec4(true));
            float r = every ? q.x : (n > 2 ? float(cells.y) : m[1][1]);
            r += (g_outer.flags.x, q.y) + float(g_outer.cell == ivec3(1, 2, 3)) + float(plain == ORIGIN);
            r += build(inner, mat3(u)).basis[2][n] + float(build(inner, mat3(u)).cell[n]) + +r;
            ;
            {}
            if (r > 0.0) ; else r = -r;
            float endless = 1.0 / 0.0, nothing = 0.0 / 0.0, least = -1.0 / 0.0, tiny = 1e-45, huge = 3.4e38, minus = -0.0;
            r += min(endless, 1.0) + max(least, 0.0) + (nothing == nothing ? 1.0 : 0.0) + tiny + huge * 0.0 + minus;
            int lowest = -2147483648, wrapped = 2147483647 + 1, none = 1 / 0;
            r += float(lowest - wrapped + none);
            gl_DepthRangeParameters range = gl_DepthRange;
            r += range.far - gl_DepthRange.near;
            gl_FragColor = vec4(r, total, g_table[2], local.a);
        }
        """

    /// Shaders that use the corners of the language (structs in structs
    /// with arrays, a struct with no name, a struct declared in a
    /// function, indexes that are not constants, swizzles written to,
    /// empty statements) are still Metal that Metal takes.
    func testTheCornersOfTheLanguageBecomeMetal() throws {
        XCTAssertNoThrow(try metal(try program(Self.wholePicture, Self.corners)))
    }

    /// A function of the shader's may have a built-in function's name
    /// with other parameters, and is then the one called for them.
    func testABuiltInFunctionCanBeOverloaded() throws {
        let pixel = try draw(Scene(fragment: """
        precision highp float;
        float sin(int x) { return float(x) * 10.0; }
        vec2 max(vec2 a, vec2 b, vec2 c) { return max(max(a, b), c); }
        void main() { gl_FragColor = vec4(sin(2), sin(0.0), max(vec2(1.0, 5.0), vec2(2.0), vec2(3.0, 0.0))); }
        """, side: 1))[0]
        XCTAssertEqual(pixel, SIMD4(20, 0, 3, 5))
    }

    private static let expressions = [
        // mod is x - y * floor(x / y), not C's fmod.
        "mod(-one, three) == 2.0",
        "mod(vec2(-one, 5.0), three) == vec2(2.0, 2.0)",
        "mod(vec2(5.0, 7.0), vec2(three, two)) == vec2(2.0, 1.0)",
        // atan with two arguments is atan2(y, x).
        "abs(atan(one, -one) - 2.3561945) < 0.0001",
        "abs(atan(one) - 0.7853982) < 0.0001",
        "abs(inversesqrt(two * two) - 0.5) < 0.0001",
        "matrixCompMult(mat2(one, two, three, 4.0), mat2(two)) == mat2(2.0, 0.0, 0.0, 8.0)",
        "mat2(one, two, three, 4.0) * vec2(one, two) == vec2(7.0, 10.0)",
        "vec2(one, two) * mat2(one, two, three, 4.0) == vec2(5.0, 11.0)",
        "mat2(one, two, three, 4.0) * mat2(two) == mat2(2.0, 4.0, 6.0, 8.0)",
        "mat2(one, two, three, 4.0) * two == mat2(2.0, 4.0, 6.0, 8.0)",
        "(mat2(one, two, three, 4.0) + one) == mat2(2.0, 3.0, 4.0, 5.0)",
        "(mat2(two, 4.0, 6.0, 8.0) / two) == mat2(1.0, 2.0, 3.0, 4.0)",
        "(two - mat2(one)) == mat2(1.0, 2.0, 2.0, 1.0)",
        "(mat2(one) - mat2(two, one, one, two)) == mat2(-1.0, -1.0, -1.0, -1.0)",
        "-mat2(one) == mat2(-1.0, 0.0, 0.0, -1.0)",
        "mat2(one) != mat2(one, 0.0, 0.5, one)",
        // A matrix of a matrix keeps what both have, the identity elsewhere.
        "mat3(mat4(two))[2] == vec3(0.0, 0.0, 2.0)",
        "mat4(mat2(two))[3] == vec4(0.0, 0.0, 0.0, 1.0)",
        "mat4(mat2(two))[1] == vec4(0.0, 2.0, 0.0, 0.0)",
        "mat2(mat3(three)) == mat2(3.0)",
        "mat2(vec4(one, two, three, 4.0))[1] == vec2(3.0, 4.0)",
        "vec4(mat2(one, two, three, 4.0)) == vec4(1.0, 2.0, 3.0, 4.0)",
        "mat2(vec3(one, two, three), 4.0)[1] == vec2(3.0, 4.0)",
        "vec3(mat2(one, two, three, 4.0)) == vec3(1.0, 2.0, 3.0)",
        "vec3(two).y == 2.0",
        "mat3(two)[1][1] == 2.0 && mat3(two)[1][0] == 0.0",
        "vec4(vec2(one, two), vec2(three, 4.0)).zy == vec2(3.0, 2.0)",
        "vec2(vec4(one, two, three, 4.0)) == vec2(1.0, 2.0)",
        "lessThan(vec3(one, two, three), vec3(two)) == bvec3(true, false, false)",
        "lessThanEqual(vec3(one, two, three), vec3(two)) == bvec3(true, true, false)",
        "greaterThan(ivec2(ione, itwo), ivec2(1)) == bvec2(false, true)",
        "all(greaterThanEqual(ivec2(ione, itwo), ivec2(1, 2)))",
        "any(equal(vec2(one), vec2(two, one)))",
        "!all(equal(vec2(one), vec2(two, one)))",
        "not(bvec2(yes, false)) == bvec2(false, true)",
        "notEqual(ivec2(ione), ivec2(itwo, ione)) == bvec2(true, false)",
        "mix(one, three, 0.5) == 2.0",
        "mix(vec2(one), vec2(three), 0.5) == vec2(2.0)",
        "mix(vec2(one), vec2(three), vec2(0.0, one)) == vec2(1.0, 3.0)",
        "step(two, vec2(one, three)) == vec2(0.0, 1.0)",
        "step(vec2(two), vec2(one, three)) == vec2(0.0, 1.0)",
        "abs(smoothstep(one, three, two) - 0.5) < 0.0001",
        "smoothstep(one, three, vec2(0.0, 5.0)) == vec2(0.0, 1.0)",
        "clamp(vec2(-one, 5.0), one, two) == vec2(1.0, 2.0)",
        "clamp(three, one, two) == 2.0",
        "min(vec2(one, three), two) == vec2(1.0, 2.0)",
        "max(vec2(one, three), vec2(two)) == vec2(2.0, 3.0)",
        "reflect(vec2(one, -one), vec2(0.0, one)) == vec2(1.0, 1.0)",
        "abs(refract(vec2(0.0, -one), vec2(0.0, one), 0.5).y + 1.0) < 0.0001",
        "faceforward(vec2(0.0, one), vec2(0.0, one), vec2(0.0, one)) == vec2(0.0, -1.0)",
        // The geometric functions take a float too, which Metal's do not.
        "length(-two) == 2.0 && distance(one, three) == 2.0 && dot(two, three) == 6.0",
        "normalize(-two) == -1.0 && reflect(one, one) == -1.0 && faceforward(one, one, -one) == 1.0",
        "abs(length(vec2(three, 4.0)) - 5.0) < 0.0001 && abs(distance(vec2(one), vec2(4.0, 5.0)) - 5.0) < 0.0001",
        "cross(vec3(one, 0.0, 0.0), vec3(0.0, one, 0.0)) == vec3(0.0, 0.0, 1.0)",
        "abs(normalize(vec2(three, 4.0)).x - 0.6) < 0.0001",
        "sign(-two) == -1.0 && floor(-1.5 * one) == -2.0 && ceil(1.5 * one) == 2.0 && fract(1.25 * one) == 0.25",
        "abs(radians(180.0 * one) - 3.1415927) < 0.0001 && abs(degrees(3.1415927 * one) - 180.0) < 0.001",
        "abs(pow(two, three) - 8.0) < 0.0001 && abs(exp2(three) - 8.0) < 0.0001 && abs(log2(8.0 * one) - 3.0) < 0.0001 && sqrt(4.0 * one) == 2.0",
        "abs(sin(one) - 0.84147098) < 0.0001 && abs(cos(one) - 0.54030231) < 0.0001 && abs(exp(one) - 2.7182818) < 0.0001",
        "abs(two) == 2.0 && abs(-vec2(two)) == vec2(2.0)",
        // An int divides towards zero, and no int becomes a float by itself.
        "itwo / ione == 2 && 7 * ione / itwo == 3 && -7 * ione / itwo == -3",
        "ione - itwo == -1 && -itwo == -2",
        "ivec2(ione, itwo) * itwo == ivec2(2, 4)",
        "itwo * ivec2(ione) + ivec2(ione) == ivec2(3)",
        "ivec2(7, 9) / ivec2(itwo, 3) == ivec2(3, 3)",
        "int(2.7 * one) == 2 && int(-2.7 * one) == -2",
        "float(itwo) == 2.0 && float(yes) == 1.0 && int(yes) == 1",
        "bool(two) && !bool(ione - 1) && bool(itwo)",
        "ivec2(vec2(1.5, 2.5) * one) == ivec2(1, 2)",
        "vec2(ivec2(ione, itwo)) == vec2(1.0, 2.0)",
        "bvec2(vec2(one, 0.0)) == bvec2(true, false) && bvec2(ivec2(0, itwo)) == bvec2(false, true)",
        "vec2(bvec2(yes, false)) == vec2(1.0, 0.0) && ivec2(bvec2(yes, false)) == ivec2(1, 0)",
        "float(vec3(two, one, one)) == 2.0 && int(vec2(three)) == 3 && float(mat2(two)) == 2.0",
        "vec4(one, two, three, 4.0).wzyx == vec4(4.0, 3.0, 2.0, 1.0)",
        "vec4(one, two, three, 4.0).stpq.q == 4.0 && vec4(one, two, three, 4.0).rgba.bg == vec2(3.0, 2.0)",
        "vec3(one, two, three).zyx.xy == vec2(3.0, 2.0) && vec2(one, two).xxyy == vec4(1.0, 1.0, 2.0, 2.0)",
        "vec3(one, two, three)[itwo] == 3.0 && vec3(one, two, three).zyx[0] == 3.0",
        "(yes ? one : two) == 1.0 && (yes ^^ false) && !(yes ^^ yes) && (yes || false) && !(yes && false)",
        "vec2(one, two) != vec2(one, one) && vec2(one, two) == vec2(one, two) && one < two && two >= two",
    ]

    /// The tests below ask a shader which conditions hold. One that does
    /// not is told apart, whether Metal or the translator works it out.
    func testAConditionThatDoesNotHoldIsSeen() throws {
        let conditions = ["one == 1.0", "one == two", "itwo * itwo == 4", "mod(-one, three) == -1.0"]
        XCTAssertEqual(try failing(conditions, constants: false), ["one == two", "mod(-one, three) == -1.0"])
        XCTAssertEqual(try failing(conditions, constants: true), ["one == two", "mod(-one, three) == -1.0"])
    }

    /// The operators and built-in functions give OpenGL's answers when
    /// Metal works them out, where Metal's own differ (mod, atan with two
    /// arguments, a matrix by a float, a comparison of vectors).
    func testExpressionsGiveOpenGLsAnswersInMetal() throws {
        XCTAssertEqual(try failing(Self.expressions, constants: false), [])
    }

    /// And the same answers when their operands are constants, which the
    /// translator works out itself.
    func testConstantExpressionsGiveTheSameAnswers() throws {
        XCTAssertEqual(try failing(Self.expressions, constants: true), [])
    }

    private static let statementDeclarations = """
    struct Pair { float a; vec2 b; };
    struct Deep { Pair p; int n; };
    float g_scale = 2.0;
    const float g_three = 3.0;
    vec2 g_pair;
    int g_calls;

    void halve(inout float x) { x /= 2.0; }
    void set(out vec2 v, float a) { v = vec2(a); }
    float twice(float x) { return x * 2.0; }
    vec2 twice(vec2 x) { return x * 2.0; }
    int twice(int x) { return x * 2; }
    float later(float x);
    float sum(float a[3]) { a[0] = 10.0; return a[0] + a[1] + a[2]; }
    int next() { g_calls++; return g_calls; }
    float both(inout float x, out float y) { y = x; x = 7.0; return x + y; }

    bool outs() {
        vec4 v = vec4(8.0);
        halve(v.x);
        set(v.zw, 3.0);
        float f = 4.0;
        halve(f);
        float y;
        float r = both(f, y);
        return v == vec4(4.0, 8.0, 3.0, 3.0) && f == 7.0 && y == 2.0 && r == 9.0;
    }
    bool swizzles() {
        vec4 v = vec4(0.0);
        v.zx = vec2(one, two);
        v.yw += two;
        v.xy *= two;
        v.wzyx.x -= one;
        return v == vec4(4.0, 4.0, 1.0, 1.0);
    }
    bool steps() {
        float f = one; float g = f++; float h = ++f;
        int i = ione; int j = i--; int k = --i;
        vec2 v = vec2(one); vec2 w = v++; --v;
        ivec2 c = ivec2(ione); c++; ivec2 d = c--;
        mat2 m = mat2(one); m++; mat2 n = m--;
        return f == 3.0 && g == 1.0 && h == 3.0 && i == -1 && j == 1 && k == -1 && w == vec2(1.0) && v == vec2(1.0)
            && c == ivec2(1) && d == ivec2(2) && m == mat2(1.0) && n == mat2(2.0, 1.0, 1.0, 2.0);
    }
    bool structs() {
        Pair p = Pair(one, vec2(two));
        Pair q = p;
        q.b.y = three;
        Deep d = Deep(q, 2);
        return p != q && p == Pair(1.0, vec2(2.0)) && d.p.b == vec2(2.0, 3.0) && d == Deep(q, itwo) && d != Deep(p, itwo);
    }
    bool arrays() {
        float a[3];
        a[0] = one; a[1] = two; a[2] = three;
        float before = sum(a);
        Pair pairs[2];
        pairs[1].b = vec2(5.0);
        pairs[ione].b.x += one;
        int n = ione;
        a[n++] += 10.0;
        return before == 15.0 && a[0] == 1.0 && a[1] == 12.0 && n == 2 && pairs[1].b == vec2(6.0, 5.0) && pairs[0].a == 0.0;
    }
    bool matrices() {
        mat3 m = mat3(one);
        m[1] = vec3(two);
        m[2][0] = three;
        m *= two;
        m += one;
        mat2 r = mat2(one, two, three, 4.0);
        r *= mat2(0.0, one, one, 0.0);
        vec2 v = vec2(one, two);
        v *= mat2(one, two, three, 4.0);
        return m[1] == vec3(5.0) && m[2].x == 7.0 && m[0] == vec3(3.0, 1.0, 1.0) && r == mat2(3.0, 4.0, 1.0, 2.0) && v == vec2(5.0, 11.0);
    }
    bool loops() {
        float s = 0.0;
        for (int i = 0; i < 4; i++) { if (i == 2) continue; s += float(i); }
        for (float f = 0.0; f < 1.0; f += 0.25) s += one;
        for (int k = 10; k >= 0; k -= 5) { if (k == 0) break; s += 10.0; }
        for (int a = 0; a != 3; ++a) for (int b = 0; b < 2; b++) s += 100.0;
        for (int never = 0; never > 5; never++) s = -1.0;
        return s == 628.0;
    }
    bool scopes() {
        float x = one;
        {
            float x = x + one;
            if (x != 2.0) return false;
        }
        for (int x = 0; x < 2; x++) { float one = 5.0; if (one != 5.0) return false; }
        return x == 1.0;
    }
    bool overloads() { return twice(two) == 4.0 && twice(vec2(one)) == vec2(2.0) && twice(itwo) == 4 && later(two) == 5.0; }
    bool globals() {
        g_pair = vec2(g_scale, g_three);
        g_scale += one;
        return g_pair == vec2(2.0, 3.0) && g_scale == 3.0;
    }
    bool order() {
        g_calls = 0;
        int c = 0;
        int d = (c++, c++, c);
        float a[3];
        a[0] = 0.0; a[1] = 0.0; a[2] = 0.0;
        a[next()] += 5.0;
        vec2 v = vec2(0.0);
        halve(a[next() - 1]);
        bool skipped = false && next() > 0;
        bool taken = yes || next() > 0;
        int ia[3];
        ia[0] = 0; ia[1] = 0; ia[2] = 0;
        int k = 0;
        ia[k++] += 5;
        ia[k++]++;
        ivec2 iv = ivec2(1, 2);
        iv[k - 1] *= 3;
        return d == 2 && a[1] == 2.5 && g_calls == 2 && !skipped && taken && ia[0] == 5 && ia[1] == 1 && k == 2 && iv == ivec2(1, 6);
    }
    void make(out Pair p, float a) { p.a = a; p.b = vec2(a); }
    void fill(out float a[3], float v) { for (int i = 0; i < 3; i++) a[i] = v; }
    void grow(inout Deep d) { d.n++; d.p.a *= 2.0; }
    bool aggregates() {
        Pair p;
        make(p, two);
        float a[3];
        fill(a, three);
        Deep d = Deep(p, 1);
        grow(d);
        Pair pairs[2];
        make(pairs[1], one);
        Pair chosen = yes ? p : pairs[1];
        return p == Pair(2.0, vec2(2.0)) && a[0] + a[1] + a[2] == 9.0 && d.n == 2 && d.p.a == 4.0 && pairs[1].a == 1.0 && chosen == p;
    }
    float later(float x) { return x + g_three; }
    """

    /// Statements do what OpenGL says: out and inout arguments are copied
    /// back (also into a swizzle), ++ and -- give the right value, structs
    /// and arrays are copied when assigned or passed, a block's names are
    /// its own, and what has an effect happens once and in order.
    func testStatementsDoWhatOpenGLSays() throws {
        let conditions = ["outs()", "swizzles()", "steps()", "structs()", "arrays()", "matrices()", "loops()", "scopes()",
                          "overloads()", "globals()", "order()", "aggregates()"]
        XCTAssertEqual(try failing(conditions, declarations: Self.statementDeclarations, constants: false), [])
        XCTAssertEqual(try failing(conditions, declarations: Self.statementDeclarations, constants: true), [])
    }

    private static let valueDeclarations = """
    struct Light { vec3 color; float power; };
    uniform Light u_light;
    uniform Light u_lights[2];
    uniform float u_weights[3];
    uniform mat2 u_m;
    uniform sampler2D u_maps[2];

    void halve(inout float x) { x /= 2.0; }
    void set(out vec2 v, float a) { v = vec2(a); }
    void bump(inout int i) { i++; }
    float sum(float w[3]) { return w[0] + w[1] + w[2]; }
    float power(Light l) { return l.power; }
    vec4 read(sampler2D maps[2], int which) { return texture2D(maps[which], vec2(0.5)); }
    Light dim(Light l) { l.power *= 0.5; return l; }

    bool elements() {
        mat3 m = mat3(8.0);
        vec3 v = vec3(8.0);
        halve(m[1][1]);
        set(m[0].yz, 3.0);
        int n = itwo;
        halve(v[n]);
        halve(m[n][n]);
        int ia[3];
        ia[0] = 0; ia[1] = 0; ia[2] = 0;
        int k = 0;
        bump(ia[k++]);
        bump(k);
        return m[1][1] == 4.0 && m[0] == vec3(8.0, 3.0, 3.0) && v == vec3(8.0, 8.0, 4.0) && m[2][2] == 4.0 && ia[0] == 1 && k == 2;
    }
    bool uniforms() {
        Light l = u_light;
        Light dimmed = dim(u_lights[1]);
        Light copy;
        copy = u_lights[1];
        return l == u_light && l != u_lights[1] && l.color == vec3(1.0, 2.0, 3.0) && power(u_light) == 2.0 && dimmed.power == 0.25
            && copy.color.z == 6.0 && sum(u_weights) == 6.0 && u_m == mat2(1.0, 2.0, 3.0, 4.0) && u_m != mat2(1.0) && dim(l).color == l.color;
    }
    bool integers() {
        ivec3 iv = ivec3(ione, itwo, 3);
        iv *= 2;
        iv = 10 - iv;
        iv /= ivec3(itwo);
        iv = -iv;
        iv += 1;
        iv++;
        int i = ione;
        int j = i++;
        j += ++i;
        return iv == ivec3(-2, -1, 0) && j == 4 && i == 3 && iv.x * iv.y - iv.z == 2;
    }
    bool constructors() {
        vec3 v = vec3(1.5, -2.5, 0.0) * one;
        ivec3 iv = ivec3(v);
        bvec3 bv = bvec3(iv);
        mat3 m = mat3(v, vec3(iv), vec3(bv));
        mat4 big = mat4(vec4(one), vec2(two), vec2(three), 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0);
        mat3 fromTwo = mat3(mat2(one, two, three, 4.0));
        vec4 mixed = vec4(ivec2(ione, itwo), bvec2(yes, false));
        ivec4 whole = ivec4(2.9 * one, vec2(-1.9, 0.5) * one, yes);
        return iv == ivec3(1, -2, 0) && bv == bvec3(true, true, false) && m[1] == vec3(1.0, -2.0, 0.0) && m[2] == vec3(1.0, 1.0, 0.0)
            && big[1] == vec4(2.0, 2.0, 3.0, 3.0) && big[3] == vec4(8.0, 9.0, 10.0, 11.0) && fromTwo[1] == vec3(3.0, 4.0, 0.0)
            && fromTwo[2] == vec3(0.0, 0.0, 1.0) && mixed == vec4(1.0, 2.0, 1.0, 0.0) && whole == ivec4(2, -1, 0, 1)
            && vec2(m) == vec2(1.5, -2.5) && bool(vec4(0.0, one, one, one)) == false && int(m[0]) == 1;
    }
    bool arraysOf() {
        mat3 ms[2];
        ms[1][2].x = one;
        ms[ione][0] = vec3(two);
        vec4 vs[3];
        vs[0] = vec4(one, two, three, 4.0);
        int n = ione;
        vs[n].zw = vs[n - 1].xy;
        vs[n + 1] = vs[n].wzyx;
        return ms[1][2] == vec3(1.0, 0.0, 0.0) && ms[1][0].y == 2.0 && ms[0] == mat3(0.0) && vs[1] == vec4(0.0, 0.0, 1.0, 2.0)
            && vs[2] == vec4(2.0, 1.0, 0.0, 0.0);
    }
    bool precedence() {
        float a = one, b = two, c = three;
        return a + b * c - c / b == 5.5 && -a * b == -2.0 && a - -b == 3.0 && a - (b - c) == 2.0 && (a < b) == (b < c) && a - b - c == -4.0
            && a / b / b == 0.25 && -(-a) == 1.0 && - -a == 1.0 && !(a > b) && (a > b ? a : b > c ? b : c) == 3.0 && (a, b, c) == 3.0
            && 2.0 * (a + b) * c == 18.0 && +a == 1.0 && a - +b == -1.0;
    }
    bool samplers() { return read(u_maps, 1) == vec4(0.0, 0.0, 1.0, 1.0) && read(u_maps, 7).b == 1.0 && read(u_maps, 0).r == 1.0; }
    """

    /// Values are converted by constructors, copied out of the uniform
    /// block whole, handed to functions (an element of a matrix as an
    /// out argument, an array of samplers), and operators bind, all as
    /// OpenGL says.
    func testValuesAreConvertedCopiedAndPassedAsOpenGLSays() throws {
        let device = try XCTUnwrap(Self.device)
        func solid(_ color: [UInt8]) throws -> MTLTexture {
            let texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: color, bytesPerRow: 4)
            return texture
        }
        let conditions = ["elements()", "uniforms()", "integers()", "constructors()", "arraysOf()", "precedence()", "samplers()"]
        let floats: [String: [Float]] = [
            "u_light.color": [1, 2, 3], "u_light.power": [2], "u_lights[0].color": [9, 9, 9], "u_lights[0].power": [9],
            "u_lights[1].color": [4, 5, 6], "u_lights[1].power": [0.5], "u_weights[0]": [1, 2, 3], "u_m": [1, 2, 3, 4],
        ]
        let textures = ["u_maps[0]": try solid([255, 0, 0, 255]), "u_maps[1]": try solid([0, 0, 255, 255])]
        for constants in [false, true] {
            XCTAssertEqual(try failing(conditions, declarations: Self.valueDeclarations, constants: constants, floats: floats, textures: textures), [])
        }
    }

    /// What OpenGL leaves undefined and Metal's compiler would too is
    /// defined in what the translator writes, since the shader is a
    /// guest's: an index is held inside its array, vector or matrix, an
    /// int wraps around, a division by zero gives zero, a float too
    /// large for an int becomes the largest int, and a variable that was
    /// given no value is zero.
    func testWhatOpenGLLeavesUndefinedIsDefined() throws {
        let declarations = """
        uniform int big;
        bool indexes() {
            float a[3];
            a[0] = one; a[1] = two; a[2] = three;
            vec3 v = vec3(4.0, 5.0, 6.0);
            mat2 m = mat2(7.0, 8.0, 9.0, 10.0);
            int far = 5 * ione;
            a[far] += 10.0;
            v[far] += 10.0;
            return a[far] == 13.0 && a[-far] == 1.0 && v[far] == 16.0 && v[-far] == 4.0 && m[far] == vec2(9.0, 10.0) && m[far][far] == 10.0;
        }
        bool ints() {
            int zero = ione - 1;
            return ione / zero == 0 && ivec2(itwo) / ivec2(zero, 1) == ivec2(0, 2) && big + ione == -big - 1
                && big * itwo == -2 && (-big - 1) / (zero - 1) == 0 && -(-big - 1) == -big - 1;
        }
        bool floats() {
            return int(1e20 * one) == big && int(-1e20 * one) == -big - 1 && ivec2(vec2(3e9, -3e9) * one) == ivec2(big, -big - 1);
        }
        bool zeros() {
            float f; vec3 v; mat2 m; int i; bool b; float a[4];
            struct S { float x; ivec2 y; } s;
            return f == 0.0 && v == vec3(0.0) && m == mat2(0.0) && i == 0 && !b && a[3] == 0.0 && s.x == 0.0 && s.y == ivec2(0);
        }
        float missing(float x) { if (x > 5.0) return x; }
        """
        var source = "precision highp float;\nuniform float one; uniform float two; uniform float three; uniform int ione; uniform int itwo;\n" + declarations
        source += "void main() { gl_FragColor = vec4(float(indexes()), float(ints()), float(floats()), float(zeros()) + missing(one)); }"
        let pixel = try draw(Scene(fragment: source, floats: ["one": [1], "two": [2], "three": [3]],
                                   ints: ["ione": [1], "itwo": [2], "big": [Int32.max]], side: 1))[0]
        XCTAssertEqual(pixel, SIMD4(1, 1, 1, 1))
    }

    private static let loopDeclarations = """
    uniform int u_rounds;
    uniform float u_limit;
    int g_asked;
    bool more() { g_asked++; return g_asked < 4; }

    bool uniformBound() {
        int sum = 0;
        for (int i = 0; i < u_rounds; i++) sum += i;
        float steps = 0.0;
        for (float f = 0.0; f < u_limit; f += one) steps += 1.0;
        return sum == 10 && steps == 3.0;
    }
    bool whiles() {
        int i = 0, sum = 0;
        while (i < u_rounds) { i++; if (i == 2) continue; sum += i; }
        int never = 0;
        while (i < 0) never++;
        g_asked = 0;
        int asked = 0;
        while (more()) asked++;
        return sum == 13 && i == 5 && never == 0 && asked == 3 && g_asked == 4;
    }
    bool doWhiles() {
        int i = 0, sum = 0;
        do { i++; if (i == 3) continue; sum += i; } while (i < u_rounds);
        int once = 0;
        do once++; while (false);
        int broken = 0;
        do { broken++; if (broken == 2) break; } while (true);
        return sum == 12 && once == 1 && broken == 2;
    }
    bool freeFors() {
        int i = 0, count = 0;
        for (;;) { if (i >= u_rounds) break; i += 2; count++; }
        int j;
        for (j = 10; j > 0; ) j -= 4;
        int skipped = 0;
        for (int k = 0; k < 6; k++) { if (k == 1) { k = 4; continue; } skipped += k; }
        int a = 0, b = 0;
        for (int x = 0, y = 10; x < y; x += 3, y--) { a = x; b = y; }
        float total = 0.0;
        for (int n = itwo; n > 0; n--) for (int m = 0; m < n; ++m) total += 1.0;
        return count == 3 && i == 6 && j == -2 && skipped == 5 && a == 6 && b == 8 && total == 3.0;
    }
    bool declared() {
        g_asked = 0;
        int rounds = 0;
        while (bool again = more()) { if (again) rounds++; }
        for (int i = 0; bool small = i < 2; i++) { if (small) rounds += 10; }
        return rounds == 23;
    }
    """

    /// A loop need not be of the one form Appendix A of the language
    /// gives: its bound may be a uniform, its index may be changed in
    /// its body, any part of a for may be left out, a condition may
    /// declare a variable, and while and do … while are loops too. break
    /// and continue do in each what OpenGL says.
    func testLoopsOfEveryFormRun() throws {
        let conditions = ["uniformBound()", "whiles()", "doWhiles()", "freeFors()", "declared()"]
        for constants in [false, true] {
            XCTAssertEqual(try failing(conditions, declarations: Self.loopDeclarations, constants: constants,
                                       floats: ["u_limit": [2.5]], ints: ["u_rounds": [5]]), [])
        }
    }

    /// A loop that would never end, or would run more than 65536 rounds,
    /// leaves after 65536 of them, whatever its form: the shader still
    /// gives its colour, and the Mac's GPU is not kept for ever.
    func testALoopThatNeverEndsStopsAfter65536Rounds() throws {
        let pixel = try draw(Scene(fragment: """
        precision highp float;
        uniform bool u_yes;
        void main() {
            float whiles = 0.0, fors = 0.0, dos = 0.0, stuck = 0.0, many = 0.0;
            while (u_yes) whiles += 1.0;
            for (;;) { fors += 1.0; continue; }
            do { dos += 1.0; } while (true);
            for (float f = 16777216.0; f < 16777220.0; f += 1.0) stuck += 1.0;
            for (int i = 0; i < 100000; i++) many += 1.0;
            gl_FragColor = vec4(whiles, fors, dos, stuck + many);
        }
        """, ints: ["u_yes": [1]], side: 1))[0]
        XCTAssertEqual(pixel, SIMD4(65536, 65536, 65536, 131072), "16777216 + 1 is 16777216 to a float: that loop never ends either")
    }

    // MARK: What a program takes

    /// The active uniforms are told as glGetActiveUniform tells them: a
    /// struct field by field, an array as name[0] with its size, an array
    /// of structs element by element; locations from 0 with one for each
    /// element; and each lies in the block where Metal's layout puts it.
    func testUniformsAreReportedWithNamesTypesLocationsAndOffsets() throws {
        let linked = try program("""
        attribute vec4 a_position;
        uniform mat4 u_mvp;
        uniform mat3 u_normal;
        uniform vec3 u_light;
        uniform float u_scale;
        uniform float u_vertexUnused;
        void main() { gl_Position = u_mvp * a_position * u_scale + vec4(u_normal * u_light, 0.0); }
        """, """
        precision mediump float;
        struct Material { vec3 color; float shininess; sampler2D map; };
        struct Light { vec3 position; float k[2]; };
        uniform vec3 u_light;
        uniform bool u_on;
        uniform int u_count;
        uniform vec2 u_offsets[3];
        uniform Material u_material;
        uniform Light u_lights[2];
        uniform sampler2D u_textures[2];
        uniform samplerCube u_sky;
        uniform float u_unused;
        uniform bvec3 u_mask;
        uniform mat2 u_spin;
        void main() {
            vec4 color = texture2D(u_material.map, u_offsets[1]) + texture2D(u_textures[1], u_offsets[2]) + textureCube(u_sky, u_light);
            if (u_on && u_mask.y) color.rgb += u_material.color * u_material.shininess * float(u_count);
            color.rg *= u_spin;
            gl_FragColor = color + vec4(u_lights[1].position, u_lights[0].k[1]);
        }
        """)
        func uniform(_ name: String, _ type: UInt32, _ size: Int, _ location: Int, _ offset: Int, _ stride: Int,
                     _ columns: Int = 1, _ rows: Int = 1, _ columnStride: Int? = nil, texture: Int? = nil) -> GLUniform {
            GLUniform(name: name, type: type, size: size, location: location, offset: offset, stride: stride,
                      columns: columns, rows: rows, columnStride: columnStride ?? stride, texture: texture)
        }
        XCTAssertEqual(linked.uniforms, [
            uniform("u_mvp", GL.FLOAT_MAT4, 1, 0, 16, 64, 4, 4, 16),
            uniform("u_normal", GL.FLOAT_MAT3, 1, 1, 80, 48, 3, 3, 16),
            uniform("u_light", GL.FLOAT_VEC3, 1, 2, 128, 16, 1, 3),
            uniform("u_scale", GL.FLOAT, 1, 3, 144, 4),
            uniform("u_on", GL.BOOL, 1, 4, 148, 4),
            uniform("u_count", GL.INT, 1, 5, 152, 4),
            uniform("u_offsets[0]", GL.FLOAT_VEC2, 3, 6, 160, 8, 1, 2),
            uniform("u_material.color", GL.FLOAT_VEC3, 1, 9, 192, 16, 1, 3),
            uniform("u_material.shininess", GL.FLOAT, 1, 10, 208, 4),
            uniform("u_material.map", GL.SAMPLER_2D, 1, 11, 0, 0, texture: 0),
            uniform("u_lights[0].position", GL.FLOAT_VEC3, 1, 12, 224, 16, 1, 3),
            uniform("u_lights[0].k[0]", GL.FLOAT, 2, 13, 240, 4),
            uniform("u_lights[1].position", GL.FLOAT_VEC3, 1, 15, 256, 16, 1, 3),
            uniform("u_lights[1].k[0]", GL.FLOAT, 2, 16, 272, 4),
            uniform("u_textures[0]", GL.SAMPLER_2D, 2, 18, 0, 0, texture: 1),
            uniform("u_sky", GL.SAMPLER_CUBE, 1, 20, 0, 0, texture: 3),
            uniform("u_mask", GL.BOOL_VEC3, 1, 21, 288, 16, 1, 3),
            uniform("u_spin", GL.FLOAT_MAT2, 1, 22, 304, 16, 2, 2, 8),
        ])
        XCTAssertEqual(linked.uniformBytes, 320)
        XCTAssertNoThrow(try metal(linked))
        // A sampler is texture(n) with sampler(n) in the stage that uses it.
        for index in 0..<4 {
            XCTAssertTrue(linked.metal.contains("[[texture(\(index))]]") && linked.metal.contains("[[sampler(\(index))]]"))
        }
        XCTAssertFalse(linked.metal.contains("[[texture(4)]]"))
    }

    /// A uniform or attribute that no code names is not active: it is not
    /// reported and takes no place.
    func testWhatIsNotUsedIsNotReported() throws {
        let linked = try program("""
        attribute vec4 a_position;
        attribute vec3 a_unused;
        uniform mat4 u_unused;
        void main() { gl_Position = a_position; }
        """, """
        precision mediump float;
        uniform vec4 u_color;
        uniform sampler2D u_unusedTexture;
        uniform struct { float a; } u_unusedStruct;
        void main() { gl_FragColor = u_color; }
        """)
        XCTAssertEqual(linked.uniforms.map(\.name), ["u_color"])
        XCTAssertEqual(linked.uniforms[0].offset, 16)
        XCTAssertEqual(linked.uniformBytes, 32)
        XCTAssertEqual(linked.attributes, [GLAttribute(name: "a_position", type: GL.FLOAT_VEC4, location: 0)])
    }

    /// With no uniforms the block is still the 16 bytes that are the
    /// drawing part's own.
    func testTheBlockOfAProgramWithNoUniformsIsItsFirst16Bytes() throws {
        let linked = try program("attribute vec4 p; void main() { gl_Position = p; }",
                                 "void main() { gl_FragColor = vec4(1.0); }")
        XCTAssertEqual(linked.uniforms, [])
        XCTAssertEqual(linked.uniformBytes, 16)
        XCTAssertNoThrow(try metal(linked))
    }

    /// The locations glBindAttribLocation asked for are the attributes';
    /// the others get the lowest that are free, a matrix as many in a row
    /// as it has columns.
    func testAttributeLocationsAreHonouredAndTheRestFilledIn() throws {
        let vertex = """
        attribute vec4 a_position;
        attribute mat3 a_basis;
        attribute vec2 a_texcoord;
        attribute float a_weight;
        attribute mat2 a_spin;
        varying vec3 v;
        void main() { v = a_basis * vec3(a_texcoord * a_spin, a_weight); gl_Position = a_position; }
        """
        let fragment = "precision mediump float; varying vec3 v; void main() { gl_FragColor = vec4(v, 1.0); }"
        var linked = try program(vertex, fragment)
        XCTAssertEqual(linked.attributes, [
            GLAttribute(name: "a_position", type: GL.FLOAT_VEC4, location: 0),
            GLAttribute(name: "a_basis", type: GL.FLOAT_MAT3, location: 1),
            GLAttribute(name: "a_texcoord", type: GL.FLOAT_VEC2, location: 4),
            GLAttribute(name: "a_weight", type: GL.FLOAT, location: 5),
            GLAttribute(name: "a_spin", type: GL.FLOAT_MAT2, location: 6),
        ])
        linked = try program(vertex, fragment, locations: ["a_texcoord": 1, "a_weight": 3, "a_spin": 14, "a_notThere": 0])
        XCTAssertEqual(linked.attributes, [
            GLAttribute(name: "a_position", type: GL.FLOAT_VEC4, location: 0),
            GLAttribute(name: "a_basis", type: GL.FLOAT_MAT3, location: 4),
            GLAttribute(name: "a_texcoord", type: GL.FLOAT_VEC2, location: 1),
            GLAttribute(name: "a_weight", type: GL.FLOAT, location: 3),
            GLAttribute(name: "a_spin", type: GL.FLOAT_MAT2, location: 14),
        ])
        for location in [0, 1, 3, 4, 5, 6, 14, 15] { XCTAssertTrue(linked.metal.contains("[[attribute(\(location))]]")) }
        XCTAssertFalse(linked.metal.contains("[[attribute(2)]]"))
        XCTAssertNoThrow(try metal(linked))
    }

    /// A uniform both shaders use is one uniform, at one place.
    func testAUniformOfBothShadersIsOne() throws {
        let linked = try program("""
        attribute vec4 p;
        uniform vec4 u_tint;
        uniform float u_only;
        varying vec4 v;
        void main() { v = u_tint * u_only; gl_Position = p; }
        """, """
        precision mediump float;
        uniform float u_fragmentOnly;
        uniform vec4 u_tint;
        varying vec4 v;
        void main() { gl_FragColor = v + u_tint * u_fragmentOnly; }
        """)
        XCTAssertEqual(linked.uniforms.map(\.name), ["u_tint", "u_only", "u_fragmentOnly"])
        XCTAssertEqual(linked.uniforms.map(\.offset), [16, 32, 36])
        XCTAssertNoThrow(try metal(linked))
    }

    // MARK: Shaders that are wrong

    /// A shader the language does not allow fails to compile, and its log
    /// names the line and says what is wrong.
    func testAShaderThatDoesNotCompileSaysWhyAndWhere() {
        let fragment = "precision mediump float;\n"
        let cases: [(source: String, stage: GLShaderStage, line: Int, says: String)] = [
            (fragment + "void main() {\n float x = 1;\n}", .fragment, 3, "float"),
            (fragment + "void main() {\n float x = 1 + 1.0;\n}", .fragment, 3, "+ does not take int and float"),
            (fragment + "void main() {\n vec3 v = vec3(1.0) * mat2(1.0);\n}", .fragment, 3, "* does not take vec3 and mat2"),
            (fragment + "void main() {\n gl_FragColor = vec4(missing);\n}", .fragment, 3, "'missing' is not declared"),
            (fragment + "void main() {\n gl_FragColor = lost(1.0);\n}", .fragment, 3, "no function 'lost'"),
            ("void main() {\n float x = 1.0;\n}", .fragment, 2, "no precision"),
            ("varying vec2 v;\nvoid main() {}", .fragment, 1, "no precision"),
            (fragment + "float f(float x);\nfloat g(float x) { return f(x); }\nfloat f(float x) {\n return g(x);\n}\nvoid main() {}", .fragment, 2, "recursion"),
            (fragment + "float f(float x) {\n return f(x);\n}\nvoid main() {}", .fragment, 2, "recursion"),
            (fragment + "void main() {\n while (1) { }\n}", .fragment, 3, "must be a bool"),
            (fragment + "void main() {\n for (int i = 0; i; i++) { }\n}", .fragment, 3, "must be a bool"),
            (fragment + "void main() {\n do { } while (1.0);\n}", .fragment, 3, "must be a bool"),
            (fragment + "void main() {\n while (float x = 1.0) { }\n}", .fragment, 3, "must be a bool"),
            (fragment + "void main() {\n do { } while (true)\n}", .fragment, 4, "';' is expected"),
            (fragment + "void main() {\n do { }\n}", .fragment, 4, "'while' is expected"),
            (fragment + "void main() {\n for (int i = 0; i < 3) { }\n}", .fragment, 3, "';' is expected"),
            (fragment + "void main() {\n while (true) { }\n continue;\n}", .fragment, 4, "outside any loop"),
            (fragment + "void main() {\n for (int i = 0; i < 3; i++) { }\n i = 1;\n}", .fragment, 4, "'i' is not declared"),
            (fragment + "uniform float u;\nvoid main() {\n u = 1.0;\n}", .fragment, 4, "it is a uniform"),
            ("attribute vec4 a;\nvoid main() {\n a.x = 1.0;\n}", .vertex, 3, "it is an attribute"),
            (fragment + "const float c = 1.0;\nvoid main() {\n c += 1.0;\n}", .fragment, 4, "it is const"),
            (fragment + "varying vec2 v;\nvoid main() {\n v = vec2(0.0);\n}", .fragment, 4, "it is a varying"),
            (fragment + "void main() {\n gl_FragCoord.x = 1.0;\n}", .fragment, 3, "read-only"),
            (fragment + "void f(const float x) {\n x = 2.0;\n}\nvoid main() {}", .fragment, 3, "const"),
            (fragment + "float f() {\n return 1;\n}\nvoid main() {}", .fragment, 3, "returns float, not int"),
            (fragment + "float f() {\n return;\n}\nvoid main() {}", .fragment, 3, "returns float, not void"),
            (fragment + "void main() {\n return 1.0;\n}", .fragment, 3, "is void"),
            (fragment + "void f() {}\nvoid main() {\n return f();\n}", .fragment, 4, "is void"),
            ("void main() {\n discard;\n}", .vertex, 2, "'discard' is for fragment shaders only"),
            (fragment + "void main() {\n vec2 v = vec2(1.0);\n v.xx = vec2(2.0);\n}", .fragment, 4, "twice"),
            (fragment + "void main() {\n vec2 v = vec2(1.0).xyz;\n}", .fragment, 3, "does not have"),
            (fragment + "void main() {\n float a[3];\n a[3] = 1.0;\n}", .fragment, 4, "index 3 is outside 0…2"),
            (fragment + "void main() {\n vec3 v;\n v[-1] = 1.0;\n}", .fragment, 4, "outside"),
            (fragment + "void main() {\n float a[0];\n}", .fragment, 3, "size"),
            (fragment + "uniform int n;\nvoid main() {\n float a[n];\n}", .fragment, 4, "constant"),
            (fragment + "void main() {\n float a[2];\n float b[2];\n a = b;\n}", .fragment, 5, "cannot be assigned"),
            (fragment + "void main() {\n float a[2];\n int n = a.length();\n}", .fragment, 4, "no methods"),
            (fragment + "void main() {\n if (1.0) { }\n}", .fragment, 3, "must be a bool"),
            (fragment + "void main() {\n vec4 v = vec4(1.0, 2.0);\n}", .fragment, 3, "needs 4 components"),
            (fragment + "void main() {\n vec2 v = vec2(1.0, 2.0, 3.0);\n}", .fragment, 3, "more arguments"),
            (fragment + "void main() {\n float x = 1.0 % 2.0;\n}", .fragment, 3, "later versions"),
            (fragment + "void main() {\n int x = 1 << 2;\n}", .fragment, 3, "later versions"),
            (fragment + "void main() {\n float x;\n float x;\n}", .fragment, 4, "already declared"),
            (fragment + "void main() {\n float gl_Mine;\n}", .fragment, 3, "gl_"),
            (fragment + "void main() {\n int switch = 1;\n}", .fragment, 3, "'switch'"),
            (fragment + "attribute vec4 a;\nvoid main() {}", .fragment, 2, "only a vertex shader"),
            (fragment + "void main() {\n sampler2D s;\n}", .fragment, 3, "sampler"),
            (fragment + "void main() {\n const float c;\n}", .fragment, 3, "must be given a value"),
            (fragment + "uniform float u;\nvoid main() {\n const float c = u;\n}", .fragment, 4, "constant expression"),
            (fragment + "void main() {\n break;\n}", .fragment, 3, "outside any loop"),
            (fragment + "void main() {\n float x = dFdx(1.0);\n}", .fragment, 3, "GL_OES_standard_derivatives"),
            ("uniform sampler2D s;\nvoid main() {\n gl_Position = texture2D(s, vec2(0.0), 1.0);\n}", .vertex, 3, "not for a vertex shader"),
            (fragment + "uniform sampler2D s;\nvoid main() {\n gl_FragColor = texture2DLod(s, vec2(0.0), 1.0);\n}", .fragment, 4, "not for a fragment shader"),
            (fragment + "float sin(float x) { return x; }\nvoid main() {}", .fragment, 2, "built-in"),
            (fragment + "void main() {\n gl_FragColor = vec4(1.0);\n gl_FragData[0] = vec4(1.0);\n}", .fragment, 5, "not both"),
            (fragment + "void main(int x) {}", .fragment, 2, "void main()"),
            (fragment + "void main() {\n float x = 1.0\n}", .fragment, 4, "';' is expected"),
            (fragment + "void main() {\n float x = (1.0;\n}", .fragment, 3, "')' is expected"),
            (fragment + "void main() {", .fragment, 2, "not closed"),
            (fragment + "struct S { float x; };\nvoid main() {\n S s = S(1.0, 2.0);\n}", .fragment, 4, "one for each field"),
            (fragment + "struct S { float x; };\nvoid main() {\n S s = S(1.0);\n float y = s.z;\n}", .fragment, 5, "no field 'z'"),
            (fragment + "float f(float x);\nvoid main() {\n float y = f(1.0);\n}", .fragment, 2, "has no body"),
            (fragment + "void main() {\n float x = 1.0f + 2.0q;\n}", .fragment, 3, "number"),
            (fragment + "void main() {\n float x = 08;\n}", .fragment, 3, "number"),
            (fragment + "void main() {\n int x = 99999999999;\n}", .fragment, 3, "too large"),
            (fragment + "void main() {\n float x = `1.0`;\n}", .fragment, 3, "character"),
            ("#version 300 es\nvoid main() {}", .vertex, 1, "#version 100"),
            ("void main() {}\n#version 100", .vertex, 2, "before everything"),
            ("#if 1\nvoid main() {}", .vertex, 2, "#endif"),
            ("#endif\nvoid main() {}", .vertex, 1, "#endif"),
            ("#define A(x x\nvoid main() {}", .vertex, 1, "parameters"),
            ("#define A(x) x\nvoid main() { A(1; }", .vertex, 2, "not closed"),
            ("#define A(x) x\nfloat y = A(1.0, 2.0);\nvoid main() {}", .vertex, 2, "takes 1 arguments"),
            ("#if UNKNOWN\n#endif\nvoid main() {}", .vertex, 1, "not a macro"),
            ("#if 1 / 0\n#endif\nvoid main() {}", .vertex, 1, "divides by zero"),
            ("#error this is wrong\nvoid main() {}", .vertex, 1, "#error this is wrong"),
            ("#include <stdio.h>\nvoid main() {}", .vertex, 1, "no directive"),
            ("#define GL_MINE 1\nvoid main() {}", .vertex, 1, "keeps for itself"),
            ("#line 40\nvoid main() {\n float x = 1;\n}", .vertex, 42, "float"),
            ("/* a comment\n that goes on\n*/ void main() {\n float x = 1; // here\n}", .vertex, 4, "float"),
            ("void main() {\r\n float x = 1;\r\n}", .vertex, 2, "float"),
            ("void main() {\r float x = 1;\r}", .vertex, 2, "float"),
            ("#define ONE \\\n 1\nvoid main() {\n float x = ONE;\n}", .vertex, 4, "float"),
            ("void main() {}\n/* never closed", .vertex, 2, "comment is not closed"),
        ]
        for (source, stage, line, says) in cases {
            let log = refusal(source, stage)
            XCTAssertTrue(log.hasPrefix("ERROR: 0:\(line): "), "\(log) should name line \(line) of:\n\(source)")
            XCTAssertTrue(log.contains(says), "\(log) should say '\(says)' of:\n\(source)")
        }
    }

    /// What the preprocessor does with macros and conditions is the
    /// language's: a macro in a macro, arguments, a macro that is taken
    /// back, a branch that is not read at all.
    func testThePreprocessorExpandsAndChooses() throws {
        let source = #"""
        precision highp float;
        const float SELF = 10.0;
        const float lines = float(__LINE__);
        #define ONE 1.0
        #define ADD(a, b) ((a) + (b))
        #define TWICE(x) ADD(x, x)
        #define APPLY(f, x) f(x)
        #define NOTHING
        #define EMPTY()
        #define f(x) (x + ONE)
        #define SELF SELF + 1.0
        #define CALL f
        #if 0
        this is not GLSL at all $ @ ` #define ONE 5.0
        #elif defined(ONE) && (__VERSION__ == 100) && GL_ES && !defined NOTHERE && (3 * 4 - 2 > 9) == 1 || 0
        const float chosen = 1.0;
        #else
        const float chosen = 2.0;
        #endif
        #ifndef NOTHERE
        #undef ONE
        #endif
        #define ONE 100.0
        uniform float u;
        void main() {
            float a = TWICE(2.0) NOTHING EMPTY();
            float b = APPLY(TWICE, u);
            float c = CALL(1.0) + f (2.0);
            float d = SELF;
            float e = ADD(
                1.0,
                ADD(2.0, 3.0));
            gl_FragColor = vec4(a + b, c, d + e, chosen + lines);
        }
        """#
        let pixel = try draw(Scene(fragment: source, floats: ["u": [0.25]], side: 1))[0]
        XCTAssertEqual(pixel, SIMD4(4.5, 203, 17, 4))
    }

    /// An extension the Mac has no answer for is a warning in the log of
    /// a shader that still compiles; the derivatives' one turns them on.
    func testAnUnknownExtensionIsAWarning() {
        let compiled = translator.compile("""
        #extension GL_OES_texture_3D : require
        #extension GL_OES_standard_derivatives : enable
        #extension all : warn
        precision mediump float;
        void main() { gl_FragColor = vec4(fwidth(gl_FragCoord.x)); }
        """, stage: .fragment)
        XCTAssertNotNil(compiled.shader)
        XCTAssertEqual(compiled.log, "WARNING: 0:1: extension GL_OES_texture_3D is not supported")
        XCTAssertTrue(refusal("#extension all : require\nvoid main() {}", .vertex).contains("warn or disable"))
        XCTAssertTrue(refusal("""
        #extension GL_OES_standard_derivatives : enable
        #extension GL_OES_standard_derivatives : disable
        precision mediump float;
        void main() { gl_FragColor = vec4(dFdx(1.0)); }
        """, .fragment).contains("GL_OES_standard_derivatives"))
    }

    /// The language's own constants are there, and are constants: one can
    /// size an array.
    func testTheBuiltInConstantsAreThere() throws {
        let pixel = try draw(Scene(fragment: """
        precision highp float;
        float units[gl_MaxTextureImageUnits];
        void main() {
            gl_FragColor = vec4(float(gl_MaxVertexAttribs), float(gl_MaxVertexUniformVectors + gl_MaxFragmentUniformVectors),
                                float(gl_MaxVaryingVectors + gl_MaxDrawBuffers),
                                float(gl_MaxVertexTextureImageUnits + gl_MaxCombinedTextureImageUnits) + gl_DepthRange.far + gl_DepthRange.diff);
        }
        """, side: 1))[0]
        XCTAssertEqual(pixel, SIMD4(16, 512, 16, 34))
    }

    /// Two shaders that each compile but do not fit each other do not
    /// link, and the log says which name is the trouble.
    func testShadersThatDoNotFitDoNotLink() throws {
        let vertex = "attribute vec4 p; varying vec3 v; uniform vec3 u; void main() { v = u; gl_Position = p; }"
        let precision = "precision mediump float; "
        var log = try linkRefusal(vertex, precision + "varying vec2 v; void main() { gl_FragColor = vec4(v, 0.0, 1.0); }")
        XCTAssertTrue(log.contains("varying 'v' is vec3 in the vertex shader and vec2 in the fragment shader"), log)
        log = try linkRefusal(vertex, precision + "varying vec3 w; void main() { gl_FragColor = vec4(w, 1.0); }")
        XCTAssertTrue(log.contains("varying 'w' is read by the fragment shader and not declared by the vertex shader"), log)
        log = try linkRefusal(vertex, precision + "uniform vec4 u; void main() { gl_FragColor = u; }")
        XCTAssertTrue(log.contains("uniform 'u' is vec3 in the vertex shader and vec4 in the fragment shader"), log)
        log = try linkRefusal("struct S { float a; }; uniform S s; void main() { gl_Position = vec4(s.a); }",
                              precision + "struct S { float b; }; uniform S s; void main() { gl_FragColor = vec4(s.b); }")
        XCTAssertTrue(log.contains("uniform 's'"), log)
        log = try linkRefusal("attribute vec4 p; void helper() {}", precision + "void main() { gl_FragColor = vec4(1.0); }")
        XCTAssertTrue(log.contains("the vertex shader has no main()"), log)
        log = try linkRefusal(vertex, precision + "void other() {}")
        XCTAssertTrue(log.contains("the fragment shader has no main()"), log)
        // A varying the fragment shader declares and does not read needs
        // no match.
        XCTAssertNoThrow(try program(vertex, precision + "varying vec2 v; varying float w; void main() { gl_FragColor = vec4(1.0); }"))
    }

    /// A vertex shader may use sixteen attribute locations and no more,
    /// and two attributes cannot be bound to one.
    func testTooManyAttributesDoNotLink() throws {
        func vertex(_ count: Int) -> String {
            var source = ""
            for index in 0..<count { source += "attribute vec4 a\(index);\n" }
            source += "void main() { gl_Position = " + (0..<count).map { "a\($0)" }.joined(separator: " + ") + "; }"
            return source
        }
        let fragment = "void main() { gl_FragColor = vec4(1.0); }"
        XCTAssertEqual(try program(vertex(16), fragment).attributes.map(\.location), Array(0..<16))
        XCTAssertTrue(try linkRefusal(vertex(17), fragment).contains("more attributes than the 16"))
        let matrices = "attribute mat4 a; attribute mat4 b; attribute mat4 c; attribute mat4 d; attribute float e;\n"
            + "void main() { gl_Position = (a * b * c * d)[0] * e; }"
        XCTAssertTrue(try linkRefusal(matrices, fragment).contains("more attributes than the 16"))
        XCTAssertTrue(try linkRefusal(vertex(2), fragment, locations: ["a0": 3, "a1": 3]).contains("the same location, 3"))
        XCTAssertTrue(try linkRefusal(vertex(2), fragment, locations: ["a0": 16]).contains("location 16"))
        XCTAssertTrue(try linkRefusal(vertex(2), fragment, locations: ["a1": -1]).contains("location -1"))
        XCTAssertTrue(try linkRefusal("attribute mat3 m; void main() { gl_Position = vec4(m[0], 1.0); }", fragment,
                                      locations: ["m": 14]).contains("location 14"))
    }

    /// A program has sixteen texture units, 256 vectors of uniforms in a
    /// shader and 15 vectors of varyings; more does not link.
    func testMoreThanTheLimitsDoesNotLink() throws {
        let vertex = "attribute vec4 p; void main() { gl_Position = p; }"
        XCTAssertNoThrow(try program(vertex, "uniform sampler2D s[16]; void main() { gl_FragColor = texture2D(s[3], vec2(0.0)); }"))
        var log = try linkRefusal(vertex, "uniform sampler2D s[16]; uniform samplerCube c;\n"
            + "void main() { gl_FragColor = texture2D(s[3], vec2(0.0)) + textureCube(c, vec3(0.0)); }")
        XCTAssertTrue(log.contains("17 samplers"), log)
        XCTAssertNoThrow(try program(vertex, "precision mediump float; uniform vec4 u[256]; void main() { gl_FragColor = u[9]; }"))
        log = try linkRefusal(vertex, "precision mediump float; uniform vec4 u[256]; uniform float one; void main() { gl_FragColor = u[9] * one; }")
        XCTAssertTrue(log.contains("more uniforms than 256 vectors"), log)
        log = try linkRefusal("attribute vec4 p; varying vec4 v[16]; void main() { gl_Position = p; }",
                              "precision mediump float; varying vec4 v[16]; void main() { gl_FragColor = v[2]; }")
        XCTAssertTrue(log.contains("more than 15 vectors"), log)
        // A field deep in structs is named by all of them: such a name
        // has a most too.
        let long = String(repeating: "n", count: 250)
        var nested = "precision mediump float;\nstruct S0 { float \(long); };\n"
        for level in 1...5 { nested += "struct S\(level) { S\(level - 1) \(long); };\n" }
        log = try linkRefusal(vertex, nested + "uniform S5 u;\nvoid main() { gl_FragColor = vec4(u\(String(repeating: "." + long, count: 6))); }")
        XCTAssertTrue(log.contains("longer than 1024 bytes"), log)
        XCTAssertNoThrow(try metal(try program("attribute vec4 p; varying vec4 v[15]; void main() { v[14] = p; gl_Position = p; }",
                                               "precision mediump float; varying vec4 v[15]; void main() { gl_FragColor = v[14]; }")))
    }

    /// Linking takes what compile handed back and nothing else.
    func testLinkingTakesOnlyCompiledShadersOfTheRightStages() throws {
        let vertex = try shader("void main() { gl_Position = vec4(0.0); }", .vertex)
        let fragment = try shader("void main() { gl_FragColor = vec4(0.0); }", .fragment)
        XCTAssertNil(translator.link(vertex: fragment, fragment: vertex, attributeLocations: [:]).program)
        XCTAssertNil(translator.link(vertex: vertex, fragment: NSObject(), attributeLocations: [:]).program)
        XCTAssertNotNil(translator.link(vertex: vertex, fragment: fragment, attributeLocations: [:]).program)
    }

    // MARK: Hostile shaders

    /// However a name of the shader's is spelled, it reaches Metal only
    /// inside a name of the translator's making: translating with the
    /// name `float4` or `kernel` gives the text that translating with a
    /// harmless name gives, but for those made names.
    func testNoNameOfTheShadersReachesMetalAsItIs() throws {
        func translated(_ name: String) throws -> GLLinkedProgram {
            try program("""
            attribute vec2 \(name);
            varying vec2 v;
            void main() { v = \(name); gl_Position = vec4(\(name), 0.0, 1.0); }
            """, """
            precision mediump float;
            varying vec2 v;
            struct Holder { float \(name); };
            uniform Holder holder;
            uniform vec4 \(name);
            float take(float \(name)) { return \(name) * 2.0; }
            vec4 other(vec2 p) {
                struct \(name) { float x; };
                \(name) local = \(name)(p.x);
                return vec4(local.x);
            }
            float third() {
                float \(name) = 0.5;
                { float \(name)\(name) = \(name); \(name) += \(name)\(name); }
                return \(name);
            }
            void main() { gl_FragColor = \(name) * take(holder.\(name)) + other(v) + third(); }
            """)
        }
        func calling(_ name: String) throws -> GLLinkedProgram {
            try program("void main() { gl_Position = vec4(0.0); }", """
            precision mediump float;
            float \(name)(float x) { return x; }
            vec2 \(name)(vec2 x) { return x; }
            void main() { gl_FragColor = vec4(\(name)(1.0), \(name)(vec2(2.0)), 1.0); }
            """)
        }
        let harmless = "q0", made = #"(?<=\b(v|Vf|Ff|VS|FS)\d{1,9}_|\bm_)"#
        let plain = try translated(harmless).metal, plainCall = try calling(harmless).metal
        let names = ["float4", "kernel", "main0", "discard_fragment", "sampler", "vertex", "fragment", "thread", "constant",
                     "mgl_g", "mgl_u", "mgl_array", "mgl_t1", "metal", "as_type", "texture2d", "uint", "access", "stage_in",
                     "INFINITY", "NAN", "M_PI_F", "e", "t", "s", "main0x", "monad_fragment", "clamp", "select", "level",
                     "bias", "device", "__asm", "_Bool", "char", "auto", "register", "new", "delete", "nullptr", "operator",
                     "typename", "friend", "virtual", "private", "signed", "restrict", "alignas", "size_t", "ushort", "half3"]
        for name in names {
            // The name doubled is one of the shader's names too.
            func unmade(_ name: String) throws -> NSRegularExpression {
                try NSRegularExpression(pattern: made + NSRegularExpression.escapedPattern(for: name) + #"\b"#)
            }
            let twice = try unmade(name + name), once = try unmade(name)
            func neutral(_ text: String) -> String {
                let first = twice.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: harmless + harmless)
                return once.stringByReplacingMatches(in: first, range: NSRange(first.startIndex..., in: first), withTemplate: harmless)
            }
            XCTAssertNil(difference(neutral(try translated(name).metal), plain), "the name \(name) changed more than the names made of it")
            XCTAssertNil(difference(neutral(try calling(name).metal), plainCall), "the function name \(name) changed more than the names made of it")
        }
        // And what Metal's compiler makes of the worst of them.
        for name in ["float4", "kernel", "main0", "discard_fragment", "sampler", "mgl_g", "thread"] {
            XCTAssertNoThrow(try metal(try translated(name)))
            XCTAssertNoThrow(try metal(try calling(name)))
        }
    }

    /// No comment, and no number as the shader spelled it, is in the
    /// Metal source: a number is written again from its value.
    func testNothingOfTheTextIsCopied() throws {
        let linked = try program("void main() { gl_Position = vec4(0.0); }", """
        precision mediump float;
        // COMMENT_ONE */ } injected
        /* COMMENT_TWO
           #include <metal_stdlib> */
        uniform float u;
        void main() { gl_FragColor = vec4(float(0x10), 1.50000e+0, float(000012), .5e1) * u; }
        """)
        XCTAssertFalse(linked.metal.contains("COMMENT"))
        XCTAssertFalse(linked.metal.contains("0x10") || linked.metal.contains("1.50000e+0") || linked.metal.contains("000012"))
        XCTAssertTrue(linked.metal.contains("float4(16.0, 1.5, 10.0, 5.0)"), linked.metal)
    }

    /// A shader over one of the bounds is refused with a sentence in its
    /// log, soon, whatever the bound: its length, its nesting, what its
    /// macros expand to, its arrays, its structs.
    func testAShaderOverABoundIsRefusedSoon() {
        let started = Date()
        func refused(_ source: String, _ says: String, file: StaticString = #filePath, line: UInt = #line) {
            let log = refusal(source, .fragment, file: file, line: line)
            XCTAssertTrue(log.contains(says), "the log is \(log.prefix(300))", file: file, line: line)
        }
        let precision = "precision mediump float;\n"
        // Length: 256 KiB is taken, a byte more is not.
        let tail = "\nvoid main() { gl_Position = vec4(0.0); }"
        let filler = "//" + String(repeating: "x", count: 256 * 1024 - 2 - tail.utf8.count)
        XCTAssertNotNil(translator.compile(filler + tail, stage: .vertex).shader)
        refused(filler + "x" + tail, "longer than 262144 bytes")
        refused(String(repeating: "\u{1F600}", count: 100_000), "longer than")
        // 256 KiB of nonsense, and of one character.
        refused(String(repeating: "nonsense ", count: 29127), "nonsense")
        refused(String(repeating: "(", count: 200_000), "'('")
        refused(String(repeating: "x", count: 1000) + ";", "longer than 256 characters")
        refused(String(repeating: "a;", count: 131072), "tokens")
        // Nesting: brackets, blocks, operators, ifs, calls, indexes.
        refused(precision + "void main() { float x = " + String(repeating: "(", count: 10000) + "1.0" + String(repeating: ")", count: 10000) + "; }", "nested deeper than 64")
        refused(precision + "void main() " + String(repeating: "{", count: 10000) + String(repeating: "}", count: 10000), "nested deeper than 64")
        refused(precision + "void main() { float x = " + String(repeating: "- ", count: 10000) + "1.0; }", "nested deeper than 64")
        refused(precision + "void main() { bool x = " + String(repeating: "!", count: 100) + "true; }", "nested deeper than 64")
        refused(precision + "void main() { float x = 1.0" + String(repeating: " + 1.0", count: 10000) + "; }", "nested deeper than 64")
        refused(precision + "void main() { float x; " + String(repeating: "if (true) ", count: 10000) + "x = 1.0; }", "nested deeper than 64")
        refused(precision + "void main() { float x = " + String(repeating: "sin(", count: 10000) + "1.0" + String(repeating: ")", count: 10000) + "; }", "nested deeper than 64")
        refused(precision + "void main() { float x = true ? 1.0 : " + String(repeating: "true ? 1.0 : ", count: 10000) + "2.0; }", "nested deeper than 64")
        refused(precision + "void main() { float x; x = " + String(repeating: "x = ", count: 10000) + "2.0; }", "nested deeper than 64")
        refused(precision + "void main() { int a[2]; int x = " + String(repeating: "a[", count: 10000) + "0" + String(repeating: "]", count: 10000) + "; }", "nested deeper than 64")
        refused("#if " + String(repeating: "(", count: 10000) + "1" + String(repeating: ")", count: 10000) + "\n#endif\nvoid main() {}", "nested deeper than 64")
        refused(String(repeating: "#if 1\n", count: 100) + "void main() {}", "nested deeper than 64")
        var structs = precision + "struct S0 { float x; };\n"
        for level in 1...20 { structs += "struct S\(level) { S\(level - 1) a; S\(level - 1) b; };\n" }
        refused(structs + "void main() {}", "structs are nested deeper than 8")
        // Macros: one that names itself ends; ones that double do not go on.
        refused("#define a a\n" + precision + "float a = 1.0 void main() {}", "'void'")
        refused("#define a b\n#define b c\n#define c a\nvoid main() { c = 1; }", "'c' is not declared")
        var doubling = "#define M0 1.0 +\n"
        for level in 1...40 { doubling += "#define M\(level) M\(level - 1) M\(level - 1)\n" }
        refused(doubling + precision + "void main() { float x = M40 1.0; }", "expand to more than")
        var chain = "#define C0 1.0\n"
        for level in 1...100 { chain += "#define C\(level) C\(level - 1)\n" }
        refused(chain + precision + "void main() { float x = C100; }", "macros are nested deeper than 64")
        refused("#define F(x) x x x x x x x x x x x x x x x x\n" + precision + "void main() { float y = F(F(F(F(F(F(1.0 +)))))) 1.0; }", "expand to more than")
        // Arrays and sizes.
        refused(precision + "void main() { float a[1000000000]; }", "from 1 to 65536")
        refused(precision + "float a[65536]; float b[1];\nvoid main() {}", "more than 65536 elements together")
        refused(precision + "struct S { float a[300]; }; S b[300];\nvoid main() {}", "more than 65536 elements together")
        refused(precision + "struct S { mat4 a[300]; }; struct T { S s[300]; };\nvoid main() {}", "too large")
        refused(precision + (0..<1100).map { "void f\($0)() {}\n" }.joined() + "void main() {}", "too many functions")
        refused(precision + (0..<70).map { "void f(float a[\($0 + 1)]) {}\n" }.joined() + "void main() {}", "too many functions")
        refused(precision + (0..<1100).map { "uniform float u\($0);\n" }.joined() + "void main() {}", "more than 1024 global variables")
        refused((0..<300).map { "struct S\($0) { int x; };\n" }.joined() + "void main() {}", "more than 256 structs")
        refused("void f(" + (0..<70).map { "int a\($0)" }.joined(separator: ", ") + ") {}\nvoid main() {}", "more than 64 parameters")
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
    }

    /// What a program becomes in Metal's language has a most too: a
    /// shader that names a large constant four thousand times does not
    /// link, and says so soon.
    func testAProgramTooLongInMetalDoesNotLink() throws {
        let fields = (0..<200).map { "float f\($0);" }.joined(separator: " ")
        let values = (0..<200).map { "\($0).5" }.joined(separator: ", ")
        let source = "precision highp float;\nstruct Big { \(fields) };\nconst Big BIG = Big(\(values));\nvoid main() {\n Big b;\n"
            + String(repeating: " b = BIG;\n", count: 4000) + " gl_FragColor = vec4(b.f7);\n}"
        let started = Date()
        let log = try linkRefusal("void main() { gl_Position = vec4(0.0); }", source)
        XCTAssertTrue(log.contains("more than 4194304 bytes in Metal's language"), log)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// Translates on a thread of its own, whose stack is as small as the
    /// test makes it.
    private final class Worker: Thread {
        let translator: GLSLTranslator
        let sources: [String]
        let done = DispatchSemaphore(value: 0)
        var results: [(program: GLLinkedProgram?, log: String)] = []

        init(translator: GLSLTranslator, sources: [String]) {
            self.translator = translator
            self.sources = sources
        }

        override func main() {
            for source in sources {
                let fragment = translator.compile(source, stage: .fragment)
                let vertex = translator.compile("void main() { gl_Position = vec4(0.0); }", stage: .vertex)
                if let compiled = fragment.shader, let other = vertex.shader {
                    results.append(translator.link(vertex: other, fragment: compiled, attributeLocations: [:]))
                } else {
                    results.append((nil, fragment.log))
                }
            }
            done.signal()
        }
    }

    /// What is as deep as the bounds allow is translated on a small
    /// stack too, such as a thread that is not the main one has, and what
    /// is deeper is refused there without running out of it.
    func testTheDeepestShaderFitsASmallStack() throws {
        let depth = 60
        let open = String(repeating: "(", count: depth), close = String(repeating: ")", count: depth)
        let blocks = String(repeating: "{ if (b) ", count: depth / 2), ends = String(repeating: "}", count: depth / 2)
        let sources = [
            "precision highp float; uniform float u; void main() { float x = \(open)u\(close); gl_FragColor = vec4(x); }",
            "precision highp float; uniform bool b; void main() { float x = 0.0; \(blocks) x = 1.0; \(ends) gl_FragColor = vec4(x); }",
            "precision highp float; uniform float u; void main() { float x = \(String(repeating: "- ", count: depth))u; gl_FragColor = vec4(x); }",
            "precision highp float; uniform float u; void main() { float x = u\(String(repeating: " + u", count: depth)); gl_FragColor = vec4(x); }",
            "precision highp float; uniform int u; void main() { int x = u\(String(repeating: " * u", count: depth)); gl_FragColor = vec4(float(x)); }",
            "precision highp float; uniform int u; uniform vec3 v; void main() { float x = v[\(String(repeating: "int(v[", count: 30))u\(String(repeating: "])", count: 30))]; gl_FragColor = vec4(x); }",
            "precision highp float; uniform float u; void main() { float x = \(String(repeating: "u > 0.5 ? u : ", count: depth - 2))u; gl_FragColor = vec4(x); }",
            "precision highp float; float f(float x, out float y) { y = x; return x; } uniform float u; void main() { float y; float x = \(String(repeating: "f(", count: depth - 2))u\(String(repeating: ", y)", count: depth - 2)); gl_FragColor = vec4(x); }",
            "precision highp float; uniform int u; void main() { float x = 0.0; \(String(repeating: "for (int i = 0; i < u; i++) ", count: depth)) x += 1.0; gl_FragColor = vec4(x); }",
            "precision highp float; uniform int u; void main() { float x = 0.0; int i = 0; \(String(repeating: "while (i < u) { do ", count: depth / 3)) x += 1.0; \(String(repeating: "while (i++ < u); }", count: depth / 3)) gl_FragColor = vec4(x); }",
            "precision highp float; void main() { float x = \(String(repeating: "(", count: 10000))1.0\(String(repeating: ")", count: 10000)); }",
            "precision highp float; void main() \(String(repeating: "{", count: 10000))",
        ]
        let worker = Worker(translator: translator, sources: sources)
        worker.stackSize = 512 * 1024
        worker.start()
        XCTAssertEqual(worker.done.wait(timeout: .now() + 60), .success)
        let results = worker.results
        XCTAssertEqual(results.count, sources.count)
        for (index, result) in results.enumerated() {
            if index < sources.count - 2 {
                // Metal's compiler takes brackets 256 deep; the deepest
                // the translator lets through stays under that.
                XCTAssertNoThrow(try metal(try XCTUnwrap(result.program, "source \(index): \(result.log)")), "source \(index)")
            } else {
                XCTAssertNil(result.program)
                XCTAssertTrue(result.log.contains("nested deeper"), result.log)
            }
        }
    }

    /// A generator of numbers that gives the same ones each run.
    private struct Numbers {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(max(bound, 1))) }
    }

    private static let words = [
        "void", "float", "int", "bool", "vec2", "vec3", "vec4", "ivec2", "ivec3", "bvec4", "mat2", "mat3", "mat4", "sampler2D",
        "samplerCube", "struct", "uniform", "attribute", "varying", "const", "precision", "highp", "mediump", "lowp", "invariant",
        "in", "out", "inout", "if", "else", "for", "while", "do", "break", "continue", "return", "discard", "true", "false",
        "main", "a", "b", "c", "x", "f", "S", "gl_Position", "gl_FragColor", "gl_FragCoord", "gl_FragData", "gl_PointSize",
        "gl_MaxDrawBuffers", "texture2D", "textureCube", "sin", "mod", "mix", "dot", "length", "normalize", "lessThan", "any",
        "0", "1", "2", "3", "65536", "2147483647", "0x7fffffff", "1.0", "0.5", "1e38", "1e-45", ".5", "3.", "00", "1e", "0x",
        "(", ")", "[", "]", "{", "}", ".", ",", ";", ":", "?", "=", "+", "-", "*", "/", "<", ">", "<=", ">=", "==", "!=", "&&",
        "||", "^^", "!", "++", "--", "+=", "-=", "*=", "/=", "%", "<<", ">>", "&", "|", "^", "~", "#", "\\", "\n", "\n", "\n",
        "#define", "#undef", "#if", "#ifdef", "#ifndef", "#elif", "#else", "#endif", "#extension", "#version", "#line", "#pragma",
        "#error", "defined", "GL_ES", "__LINE__", "__VERSION__", "GL_OES_standard_derivatives", "enable", "100", ".x", ".xyz",
        ".rgba", ".stpq", "$", "@", "`", "\"", "'", "\u{00e9}", "\u{0}", "\t", "//", "/*", "*/",
    ]

    /// A few thousand shaders made of random tokens: each is answered
    /// soon, with a shader or a log, and none stops the program.
    func testRandomTokenSoupIsAnsweredAndNeverCrashes() {
        var numbers = Numbers(state: 0x6C73_6C00)
        var compiled = 0
        let started = Date()
        for round in 0..<3000 {
            var source = round % 3 == 0 ? "precision mediump float;\n" : ""
            for _ in 0..<(1 + numbers.below(120)) {
                source += Self.words[numbers.below(Self.words.count)]
                source += numbers.below(8) == 0 ? "" : " "
            }
            let stage: GLShaderStage = round % 2 == 0 ? .vertex : .fragment
            let result = translator.compile(source, stage: stage)
            if result.shader == nil {
                XCTAssertTrue(result.log.hasPrefix("ERROR: 0:"), "\(result.log) for \(source)")
                XCTAssertLessThanOrEqual(result.log.utf8.count, 8192)
            } else {
                compiled += 1
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 60)
        // Soup is almost never a shader, but nothing says it never is.
        XCTAssertLessThan(compiled, 3000)
    }

    /// A shader as its words, numbers, spaces and marks, to damage.
    private static func pieces(_ source: String) -> [String] {
        var pieces: [String] = []
        var word = ""
        for character in source {
            if character.isLetter || character.isNumber || character == "_" || (character == "." && word.last?.isNumber == true) {
                word.append(character)
            } else {
                if !word.isEmpty { pieces.append(word) }
                word = ""
                pieces.append(String(character))
            }
        }
        if !word.isEmpty { pieces.append(word) }
        return pieces
    }

    /// 0 a name, 1 a number, 2 space, 3 anything else.
    private static func kind(_ piece: String) -> Int {
        guard let first = piece.first else { return 2 }
        if first.isNumber { return 1 }
        if first.isLetter || first == "_" { return 0 }
        return first.isWhitespace ? 2 : 3
    }

    /// Real shaders with words left out, doubled, moved and replaced:
    /// closer to a shader than soup is, so they reach further in. Each is
    /// answered soon; and what still compiles and links is still Metal
    /// that Metal's compiler takes.
    func testDamagedShadersAreAnsweredAndWhatSurvivesIsStillMetal() throws {
        // MONAD_GLSL_FUZZ_ROUNDS=n in the environment makes a long run of
        // it, with MONAD_GLSL_FUZZ_SEED to have other damage each time.
        let environment = ProcessInfo.processInfo.environment
        let long = environment["MONAD_GLSL_FUZZ_ROUNDS"] != nil
        let rounds = environment["MONAD_GLSL_FUZZ_ROUNDS"].flatMap { Int($0) } ?? 2500
        var numbers = Numbers(state: environment["MONAD_GLSL_FUZZ_SEED"].flatMap { UInt64($0) } ?? 0x4D4F_4E41_44)
        let corpus = [Self.gears, Self.phong, Self.functions, Self.builtinVariables, Self.macros, Self.uniformArray,
                      Self.mathFunctions, Self.matrixAttribute,
                      (vertex: Self.wholePicture, fragment: Self.conditions(["outs()", "steps()", "arrays()", "order()", "aggregates()"],
                                                                             declarations: Self.statementDeclarations, constants: false)),
                      (vertex: Self.wholePicture, fragment: Self.conditions(Self.expressions, declarations: "", constants: false)),
                      (vertex: Self.wholePicture, fragment: Self.corners),
                      (vertex: Self.wholePicture, fragment: Self.conditions(["uniformBound()", "whiles()", "doWhiles()", "freeFors()", "declared()"],
                                                                             declarations: Self.loopDeclarations, constants: false))]
        let started = Date()
        var survivors = 0, checked = 0
        for round in 0..<rounds {
            let pair = corpus[round % corpus.count]
            let damageVertex = round % 4 == 0
            // Damage a word at a time: a word left out, said twice, moved,
            // or another in its place, most often one of the shader's own
            // (another variable, another number, another operator).
            var pieces = Self.pieces(damageVertex ? pair.vertex : pair.fragment)
            for _ in 0..<(1 + numbers.below(2)) {
                let at = numbers.below(pieces.count)
                switch numbers.below(8) {
                case 0: pieces.remove(at: at)
                case 1: pieces.insert(pieces[at], at: at)
                case 2: pieces.swapAt(at, numbers.below(pieces.count))
                case 3: pieces[at] = Self.words[numbers.below(Self.words.count)]
                case 4: pieces.insert(Self.words[numbers.below(Self.words.count)] + " ", at: at)
                default:
                    let kind = Self.kind(pieces[at])
                    let alike = pieces.filter { Self.kind($0) == kind }
                    pieces[at] = alike[numbers.below(alike.count)]
                }
                if pieces.isEmpty { pieces = [" "] }
            }
            let damaged = pieces.joined()
            let vertex = translator.compile(damageVertex ? damaged : pair.vertex, stage: .vertex)
            let fragment = translator.compile(damageVertex ? pair.fragment : damaged, stage: .fragment)
            guard let first = vertex.shader, let second = fragment.shader else {
                let log = vertex.shader == nil ? vertex.log : fragment.log
                XCTAssertTrue(log.hasPrefix("ERROR: 0:"), "\(log) for \(damaged)")
                continue
            }
            let linked = translator.link(vertex: first, fragment: second, attributeLocations: [:])
            guard let program = linked.program else {
                XCTAssertTrue(linked.log.hasPrefix("ERROR: "), linked.log)
                continue
            }
            survivors += 1
            // Metal's compiler is slow next to the translator: it sees a
            // part of them, or all in a long run.
            if long || survivors % 8 == 0 {
                checked += 1
                XCTAssertNoThrow(try metal(program), "what came of:\n\(damaged)")
            }
        }
        if !long { XCTAssertLessThan(Date().timeIntervalSince(started), 240) }
        XCTAssertGreaterThan(checked, 10, "the damage should leave some shaders standing")
    }
}
