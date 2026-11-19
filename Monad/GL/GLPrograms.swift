//
//  GLPrograms.swift — a Linux program's shaders and programs, as the Mac
//  draws with them (GLStream.swift). The shaders are a guest's text and
//  never reach Metal as they are: the translator handed to the stream
//  (GLShaders.swift) reads them and writes Metal's language anew, and
//  what it wrote is compiled here. Uniforms are kept the way the
//  translator laid them out: one block of bytes a program, which each
//  draw gets a copy of.
//
//  The translator's answers are checked like anything else on the way
//  to Metal: a layout that would write outside the block, or a function
//  that reads what a draw does not give it, is a program that did not
//  link, with a log saying so, and nothing a draw could crash on.
//

import Foundation
import Metal

extension GLStream {
    // MARK: Names

    /// The program of this name. OpenGL's error is set when there is none: a name that is no object's, or a shader's.
    private func program(_ context: GLContext, _ name: UInt32) -> GLProgram? {
        if let program = context.share.programs[name] { return program }
        context.fail(context.share.shaders[name] == nil ? GL.INVALID_VALUE : GL.INVALID_OPERATION)
        return nil
    }

    private func shader(_ context: GLContext, _ name: UInt32) -> GLShader? {
        if let shader = context.share.shaders[name] { return shader }
        context.fail(context.share.programs[name] == nil ? GL.INVALID_VALUE : GL.INVALID_OPERATION)
        return nil
    }

    /// The program's side chooses the names; one that is taken, or none, is not a name to make something under.
    private func isFree(_ context: GLContext, _ name: UInt32) -> Bool {
        guard name != 0 else {
            context.fail(GL.INVALID_VALUE)
            return false
        }
        guard context.share.shaders[name] == nil, context.share.programs[name] == nil else {
            context.fail(GL.INVALID_OPERATION)
            return false
        }
        guard budget.objects < GLLimits.objects else {
            context.fail(GL.OUT_OF_MEMORY)
            return false
        }
        return true
    }

    func createShader(_ context: GLContext, name: UInt32, type: UInt32) {
        guard type == GL.VERTEX_SHADER || type == GL.FRAGMENT_SHADER else { return context.fail(GL.INVALID_ENUM) }
        guard isFree(context, name) else { return }
        context.share.shaders[name] = GLShader(name: name, stage: type == GL.VERTEX_SHADER ? .vertex : .fragment, budget: budget)
    }

    func createProgram(_ context: GLContext, name: UInt32) {
        guard isFree(context, name) else { return }
        context.share.programs[name] = GLProgram(name: name, budget: budget)
    }

    // MARK: Shaders

    func shaderSource(_ context: GLContext, shader name: UInt32, source: UnsafeRawBufferPointer) {
        guard let shader = shader(context, name) else { return }
        guard budget.sourceBytes - shader.heldBytes + source.count <= GLLimits.sourceBytes else { return context.fail(GL.OUT_OF_MEMORY) }
        shader.set(source: String(decoding: source, as: UTF8.self), bytes: source.count)
    }

    func compile(_ context: GLContext, shader name: UInt32) {
        var reply = GLReply()
        defer { send(&reply) }
        guard let shader = shader(context, name) else {
            reply.word(0)
            reply.text("")
            return
        }
        let (compiled, log) = translator.compile(shader.source, stage: shader.stage)
        shader.compiled = compiled
        reply.word(compiled == nil ? 0 : 1)
        reply.text(log)
    }

    func deleteShader(_ context: GLContext, name: UInt32) {
        guard name != 0, let shader = shader(context, name) else { return }
        // Attached to a program, it stays until the program lets go of it.
        if shader.attachments == 0 {
            context.share.shaders[name] = nil
        } else {
            shader.deleted = true
        }
    }

    private func detach(_ shader: GLShader, in share: GLShareGroup) {
        shader.attachments -= 1
        if shader.attachments <= 0, shader.deleted { share.shaders[shader.name] = nil }
    }

    func attach(_ context: GLContext, program programName: UInt32, shader shaderName: UInt32, detach detaching: Bool) {
        guard let program = program(context, programName), let shader = shader(context, shaderName) else { return }
        let attached = shader.stage == .vertex ? program.vertex : program.fragment
        if detaching {
            guard attached === shader else { return context.fail(GL.INVALID_OPERATION) }
            detach(shader, in: context.share)
        } else {
            // OpenGL ES 2.0 has one shader of each kind in a program.
            guard attached == nil else { return context.fail(GL.INVALID_OPERATION) }
            shader.attachments += 1
        }
        if shader.stage == .vertex {
            program.vertex = detaching ? nil : shader
        } else {
            program.fragment = detaching ? nil : shader
        }
    }

    // MARK: Programs

    func bindAttributeLocation(_ context: GLContext, program name: UInt32, index: UInt32, name attribute: UnsafeRawBufferPointer) {
        guard index < UInt32(GLLimits.attributes), attribute.count <= GLLimits.nameBytes else { return context.fail(GL.INVALID_VALUE) }
        guard let program = program(context, name) else { return }
        let text = String(decoding: attribute, as: UTF8.self)
        guard !text.hasPrefix("gl_") else { return context.fail(GL.INVALID_OPERATION) }
        guard program.locations[text] != nil || (program.locations.count < GLLimits.bindings
                                                 && budget.sourceBytes + attribute.count <= GLLimits.sourceBytes) else {
            return context.fail(GL.OUT_OF_MEMORY)
        }
        program.bind(attribute: text, bytes: attribute.count, to: Int(index))
    }

    private func destroy(_ program: GLProgram, in share: GLShareGroup) {
        share.programs[program.name] = nil
        if let vertex = program.vertex { detach(vertex, in: share) }
        if let fragment = program.fragment { detach(fragment, in: share) }
        program.vertex = nil
        program.fragment = nil
    }

    func deleteProgram(_ context: GLContext, name: UInt32) {
        guard name != 0, let program = program(context, name) else { return }
        // In use, it stays until no context draws with it.
        if program.users == 0 {
            destroy(program, in: context.share)
        } else {
            program.deleted = true
        }
    }

    /// A context draws with it no more.
    func unuse(_ program: GLProgram, in share: GLShareGroup) {
        program.users -= 1
        if program.users <= 0, program.deleted { destroy(program, in: share) }
    }

    func useProgram(_ context: GLContext, name: UInt32) {
        var next: GLProgram?
        if name != 0 {
            guard let program = program(context, name) else { return }
            guard program.executable != nil else { return context.fail(GL.INVALID_OPERATION) }
            next = program
        }
        guard next !== context.program else { return }
        let old = context.program
        context.program = next
        next?.users += 1
        if let old { unuse(old, in: context.share) }
    }

    func link(_ context: GLContext, program name: UInt32) {
        var reply = GLReply()
        defer { send(&reply) }
        guard let program = program(context, name) else {
            reply.word(0)
            reply.text("")
            reply.word(0)
            reply.word(0)
            return
        }
        let (executable, log) = build(program)
        // A program that does not link draws nothing until it does.
        program.executable = executable
        reply.word(executable == nil ? 0 : 1)
        reply.text(log)
        let reflection = executable?.reflection
        reply.word(UInt32(reflection?.attributes.count ?? 0))
        for attribute in reflection?.attributes ?? [] {
            reply.word(UInt32(truncatingIfNeeded: attribute.location))
            reply.word(attribute.type)
            reply.word(1)
            reply.text(attribute.name, limit: GLLimits.nameBytes)
        }
        reply.word(UInt32(reflection?.uniforms.count ?? 0))
        for uniform in reflection?.uniforms ?? [] {
            reply.word(UInt32(truncatingIfNeeded: uniform.location))
            reply.word(uniform.type)
            reply.word(UInt32(truncatingIfNeeded: uniform.size))
            reply.text(uniform.name, limit: GLLimits.nameBytes)
        }
    }

    private static let pastTheBound = "The program has more uniforms, or the stream more programs, than Monad draws with."

    /// What is wrong with what the translator said of a program, or nil.
    /// It is Monad's own, but what it was given is a guest's: a layout
    /// that would have a uniform written outside the block is not one to
    /// draw with.
    private static func problem(_ linked: GLLinkedProgram) -> String? {
        guard (16...GLLimits.blockBytes).contains(linked.uniformBytes) else { return "its uniforms take \(linked.uniformBytes) bytes" }
        guard linked.attributes.count <= GLLimits.attributes, linked.uniforms.count <= GLLimits.uniforms else { return "it has too many attributes or uniforms" }
        for attribute in linked.attributes {
            let columns: Int
            switch attribute.type {
            case GL.FLOAT, GL.FLOAT_VEC2, GL.FLOAT_VEC3, GL.FLOAT_VEC4: columns = 1
            case GL.FLOAT_MAT2: columns = 2
            case GL.FLOAT_MAT3: columns = 3
            case GL.FLOAT_MAT4: columns = 4
            default: return "attribute \(attribute.name.prefix(64)) has a type no attribute has"
            }
            guard attribute.location >= 0, attribute.location <= GLLimits.attributes - columns, attribute.name.utf8.count <= GLLimits.nameBytes else {
                return "attribute \(attribute.name.prefix(64)) is at no location"
            }
        }
        for uniform in linked.uniforms {
            let name = uniform.name.prefix(64)
            guard let shape = GLFormats.uniform(uniform.type), uniform.name.utf8.count <= GLLimits.nameBytes else { return "uniform \(name) has a type no uniform has" }
            guard (1...65536).contains(uniform.size), (0...0x7fff_0000).contains(uniform.location) else { return "uniform \(name) is at no location" }
            if shape.kind == .sampler {
                guard let texture = uniform.texture, texture >= 0, texture <= 16 - uniform.size else { return "sampler \(name) reads no texture a draw gives" }
                continue
            }
            guard uniform.texture == nil, uniform.columns == shape.columns, uniform.rows == shape.rows,
                  (16...linked.uniformBytes).contains(uniform.offset), (0...linked.uniformBytes).contains(uniform.stride),
                  (0...linked.uniformBytes).contains(uniform.columnStride),
                  uniform.offset + (uniform.size - 1) * uniform.stride + (uniform.columns - 1) * uniform.columnStride + uniform.rows * 4 <= linked.uniformBytes else {
                return "uniform \(name) does not lie in the uniform block"
            }
        }
        return nil
    }

    /// Links a program: the translator's Metal source of its two shaders,
    /// compiled, and looked at for what its functions read. nil and why
    /// when it does not link.
    private func build(_ program: GLProgram) -> (GLExecutable?, String) {
        guard let vertexShader = program.vertex?.compiled, let fragmentShader = program.fragment?.compiled else {
            return (nil, "A program is linked from a vertex shader and a fragment shader that both compiled.")
        }
        let (translated, log) = translator.link(vertex: vertexShader, fragment: fragmentShader, attributeLocations: program.locations)
        guard let linked = translated else { return (nil, log) }
        // Uniforms without end are the program's own doing: the bounds a stream is held to, not a translation gone wrong.
        guard linked.uniformBytes <= GLLimits.blockBytes, linked.uniforms.count <= GLLimits.uniforms else { return (nil, Self.pastTheBound) }
        // From here on a failure is Monad's own: the program's shaders were fine.
        func ours(_ what: String) -> (GLExecutable?, String) {
            (nil, "Monad could not carry these shaders over to Metal (this is Monad's fault, not the program's): " + String(what.prefix(2000)))
        }
        if let problem = Self.problem(linked) { return ours(problem) }
        let options = MTLCompileOptions()
        options.preserveInvariance = true
        // Metal's fast math, which is on unless it is turned off, lets the compiler take every float for a number. The
        // translator's shaders ask whether one is (a guest's shader divides by zero when it likes), and with fast math
        // the question is answered "always" before the shader runs.
        if #available(macOS 15.0, *) {
            options.mathMode = .safe
        } else {
            options.fastMathEnabled = false
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: linked.metal, options: options)
        } catch {
            return ours("their translation did not compile. " + error.localizedDescription)
        }
        guard let vertex = library.makeFunction(name: "monad_vertex"), vertex.functionType == .vertex,
              let fragment = library.makeFunction(name: "monad_fragment"), fragment.functionType == .fragment else {
            return ours("their translation lacks its two functions")
        }
        var attributes: UInt32 = 0
        for attribute in vertex.vertexAttributes ?? [] where attribute.isActive {
            guard (0..<GLLimits.attributes).contains(attribute.attributeIndex),
                  [.float, .float2, .float3, .float4].contains(attribute.attributeType) else {
                return ours("the vertex function reads an attribute a draw does not give")
            }
            attributes |= 1 << UInt32(attribute.attributeIndex)
        }

        // A pipeline made once here: Metal then says what the functions read, and whatever it will not have shows now
        // and not at a draw.
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0]?.pixelFormat = .rgba8Unorm
        let vertices = MTLVertexDescriptor()
        for index in 0..<GLLimits.attributes where attributes & 1 << UInt32(index) != 0 {
            guard let attribute = vertices.attributes[index], let layout = vertices.layouts[index] else { continue }
            attribute.format = .float4
            attribute.bufferIndex = index
            layout.stride = 16
            layout.stepFunction = .constant
            layout.stepRate = 0
        }
        descriptor.vertexDescriptor = vertices
        let reflection: MTLRenderPipelineReflection?
        do {
            (_, reflection) = try device.makeRenderPipelineState(descriptor: descriptor, options: [.bindingInfo, .bufferTypeInfo])
        } catch {
            return ours("Metal makes no pipeline of their translation. " + error.localizedDescription)
        }
        guard let reflection else { return ours("Metal does not say what their translation reads") }

        var slots: [Int: GLTextureSlot] = [:]
        var blockBytes = linked.uniformBytes
        for (bindings, isVertex) in [(reflection.vertexBindings, true), (reflection.fragmentBindings, false)] {
            for binding in bindings {
                let index = binding.index
                switch binding.type {
                case .buffer:
                    if index == 30 {
                        blockBytes = max(blockBytes, (binding as? MTLBufferBinding)?.bufferDataSize ?? 0)
                    } else if !(isVertex && (0..<GLLimits.attributes).contains(index) && attributes & 1 << UInt32(index) != 0) {
                        return ours("it reads a buffer a draw does not give")
                    }
                case .texture:
                    // What a draw gives: a flat texture or a cube, of numbers a sampler reads as floats.
                    guard (0..<16).contains(index), let texture = binding as? MTLTextureBinding, texture.arrayLength <= 1,
                          texture.textureType == .type2D || texture.textureType == .typeCube, !texture.isDepthTexture,
                          texture.textureDataType == .float || texture.textureDataType == .half else {
                        return ours("it reads a texture a draw does not give")
                    }
                    // A sampler of the same index may have been listed first: which kind the slot is, is the texture's to say.
                    var slot = slots[index] ?? GLTextureSlot(index: index)
                    let cube = texture.textureType == .typeCube
                    guard slot.cube == cube || !(slot.vertexTexture || slot.fragmentTexture) else {
                        return ours("its two functions read one texture as two kinds")
                    }
                    slot.cube = cube
                    if isVertex {
                        slot.vertexTexture = true
                    } else {
                        slot.fragmentTexture = true
                    }
                    slots[index] = slot
                case .sampler:
                    guard (0..<16).contains(index) else { return ours("it reads a sampler a draw does not give") }
                    var slot = slots[index] ?? GLTextureSlot(index: index)
                    if isVertex {
                        slot.vertexSampler = true
                    } else {
                        slot.fragmentSampler = true
                    }
                    slots[index] = slot
                default:
                    return ours("it reads something a draw does not give")
                }
            }
        }
        // Which sampler uniform says the texture unit each reads.
        for (index, uniform) in linked.uniforms.enumerated() {
            guard let first = uniform.texture else { continue }
            for element in 0..<uniform.size {
                guard let slot = slots[first + element], slot.cube == (uniform.type == GL.SAMPLER_CUBE) else { continue }
                slots[first + element]?.uniform = (index, element)
            }
        }
        blockBytes = (blockBytes + 15) & ~15
        guard blockBytes <= GLLimits.blockBytes, budget.uniformBytes + blockBytes <= GLLimits.uniformBytes,
              budget.executables < GLLimits.programs else {
            return (nil, Self.pastTheBound)
        }
        let executable = GLExecutable(reflection: linked, vertex: vertex, fragment: fragment, attributes: attributes,
                                      slots: slots.values.sorted { $0.index < $1.index }, blockBytes: blockBytes, budget: budget)
        return (executable, log)
    }

    // MARK: Uniforms

    /// glUniform*: `count` values of `components` numbers (a matrix:
    /// `components` columns of as many), as floats or as ints, to the
    /// uniform at a location of the program in use.
    func uniform(_ context: GLContext, location: Int, components: Int, matrix: Bool, integers: Bool, count: Int,
                 values: UnsafeRawBufferPointer, array: Bool) {
        let numbers = matrix ? components * components : components
        guard count >= 0 else { return context.fail(GL.INVALID_VALUE) }
        guard values.count / 4 / numbers == count, values.count % (4 * numbers) == 0,
              let executable = context.program?.executable else { return context.fail(GL.INVALID_OPERATION) }
        // A uniform the shaders do not use has location -1, and setting it is no error.
        if location == -1 { return }
        guard let found = executable.uniform(at: location), let shape = GLFormats.uniform(executable.reflection.uniforms[found.index].type) else {
            return context.fail(GL.INVALID_OPERATION)
        }
        let uniform = executable.reflection.uniforms[found.index]
        // OpenGL's rule: the call is of the uniform's own kind and size. A bool takes floats or ints; a sampler takes one int.
        let agrees: Bool
        if matrix {
            agrees = shape.kind == .float && shape.columns == components && shape.rows == components
        } else if shape.columns != 1 || shape.rows != components {
            agrees = false
        } else {
            switch shape.kind {
            case .float: agrees = !integers
            case .int, .sampler: agrees = integers
            case .bool: agrees = true
            }
        }
        guard agrees, count <= 1 || uniform.size > 1 else { return context.fail(GL.INVALID_OPERATION) }
        // Elements past the array's end are ignored, as OpenGL has it.
        let written = min(count, uniform.size - found.element)
        func word(_ at: Int) -> UInt32 {
            UInt32(littleEndian: values.loadUnaligned(fromByteOffset: at * 4, as: UInt32.self))
        }
        if shape.kind == .sampler {
            for element in 0..<written {
                guard Int32(bitPattern: word(element)) >= 0, word(element) < UInt32(GLLimits.units) else { return context.fail(GL.INVALID_VALUE) }
            }
            for element in 0..<written where executable.units[found.index].indices.contains(found.element + element) {
                executable.units[found.index][found.element + element] = Int(word(element))
            }
        } else {
            executable.block.withUnsafeMutableBytes { block in
                for element in 0..<written {
                    for column in 0..<shape.columns {
                        for row in 0..<shape.rows {
                            var value = word(element * numbers + column * shape.rows + row)
                            if shape.kind == .bool {
                                value = (integers ? value != 0 : Float(bitPattern: value) != 0) ? 1 : 0
                            }
                            let at = uniform.offset + (found.element + element) * uniform.stride + column * uniform.columnStride + row * 4
                            // Checked when it linked; a second lock costs nothing.
                            guard at >= 16, at + 4 <= block.count else { continue }
                            block.storeBytes(of: value, toByteOffset: at, as: UInt32.self)
                        }
                    }
                }
            }
        }
        executable.generation &+= 1
    }

    func getUniform(_ context: GLContext, program name: UInt32, location: Int) {
        var reply = GLReply()
        defer { send(&reply) }
        var type: UInt32 = 0
        var value = Data()
        defer {
            reply.word(type)
            value.withUnsafeBytes { reply.data($0) }
        }
        guard let program = program(context, name) else { return }
        guard let executable = program.executable, let found = executable.uniform(at: location),
              let shape = GLFormats.uniform(executable.reflection.uniforms[found.index].type) else { return context.fail(GL.INVALID_OPERATION) }
        let uniform = executable.reflection.uniforms[found.index]
        type = uniform.type
        func put(_ word: UInt32) {
            withUnsafeBytes(of: word.littleEndian) { value.append(contentsOf: $0) }
        }
        if shape.kind == .sampler {
            let units = executable.units[found.index]
            put(UInt32(truncatingIfNeeded: units.indices.contains(found.element) ? units[found.element] : 0))
            return
        }
        executable.block.withUnsafeBytes { block in
            for column in 0..<shape.columns {
                for row in 0..<shape.rows {
                    let at = uniform.offset + found.element * uniform.stride + column * uniform.columnStride + row * 4
                    put(at >= 16 && at + 4 <= block.count ? block.loadUnaligned(fromByteOffset: at, as: UInt32.self) : 0)
                }
            }
        }
    }
}
