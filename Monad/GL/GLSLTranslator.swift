//
//  GLSLTranslator.swift — a Linux program's GLSL ES 1.00 shaders turned
//  into Metal's language: what glCompileShader and glLinkProgram come to
//  on the Mac (GLShaders.swift says what the part that draws is handed).
//
//  Compiling reads one shader and checks it against the language
//  (GLSLLexer.swift, GLSLParser.swift, GLSLChecker.swift). Linking puts a
//  vertex and a fragment shader together: it gives the uniforms their
//  places in the block of bytes both stages read, the attributes their
//  locations, joins the varyings by name, and writes the two as one
//  Metal source (GLSLMetal.swift).
//
//  The shaders are a guest's text. Whatever it is, compiling and linking
//  end soon, with a program or with a log that says why not.
//

import Foundation

struct GLSLTranslator: GLShaderTranslating {
    func compile(_ source: String, stage: GLShaderStage) -> (shader: AnyObject?, log: String) {
        do {
            let read = try GLSLPreprocessor.run(source, stage: stage)
            let shader = try GLSLParser.parse(read, stage: stage)
            return (shader, Self.bounded(read.warnings.joined(separator: "\n")))
        } catch let error as GLSLError {
            return (nil, Self.bounded("ERROR: 0:\(error.line): \(error.message)"))
        } catch {
            return (nil, "ERROR: 0:0: the shader could not be read")
        }
    }

    func link(vertex: AnyObject, fragment: AnyObject, attributeLocations: [String: Int]) -> (program: GLLinkedProgram?, log: String) {
        guard let vertex = vertex as? GLSLShader, vertex.stage == .vertex,
              let fragment = fragment as? GLSLShader, fragment.stage == .fragment else {
            return (nil, "ERROR: a program is linked from a compiled vertex shader and a compiled fragment shader")
        }
        do {
            return (try Self.link(vertex, fragment, attributeLocations), "")
        } catch let error as GLSLError {
            return (nil, Self.bounded("ERROR: \(error.message)"))
        } catch {
            return (nil, "ERROR: the program could not be linked")
        }
    }

    /// A log names what the shader named, and the shader is a guest's.
    private static func bounded(_ log: String) -> String {
        log.utf8.count <= GLSLLimits.logBytes ? log : String(log.prefix(GLSLLimits.logBytes))
    }

    private static func link(_ vertex: GLSLShader, _ fragment: GLSLShader, _ bound: [String: Int]) throws -> GLLinkedProgram {
        func fail(_ message: String) -> GLSLError { GLSLError(line: 0, message: message) }
        guard vertex.main != nil else { throw fail("the vertex shader has no main()") }
        guard fragment.main != nil else { throw fail("the fragment shader has no main()") }

        // The uniforms of both shaders are one set: a name is one
        // uniform, and must be one type.
        struct Shared {
            let name: String
            let type: GLSLType
            var vertex: GLSLVariable?
            var fragment: GLSLVariable?
        }
        var shared: [Shared] = []
        var byName: [String: Int] = [:]
        for variable in vertex.globals where variable.kind == .uniform {
            byName[variable.name] = shared.count
            shared.append(Shared(name: variable.name, type: variable.type, vertex: variable, fragment: nil))
        }
        for variable in fragment.globals where variable.kind == .uniform {
            if let index = byName[variable.name] {
                guard shared[index].type.matches(variable.type) else {
                    throw fail("uniform '\(variable.name)' is \(shared[index].type.name) in the vertex shader and \(variable.type.name) in the fragment shader")
                }
                shared[index].fragment = variable
            } else {
                shared.append(Shared(name: variable.name, type: variable.type, vertex: nil, fragment: variable))
            }
        }
        // Only what the code names is active: the rest is not in the
        // block and is not reported.
        let active = shared.filter { $0.vertex?.used == true || $0.fragment?.used == true }
        var samplers = 0, vertexScalars = 0, fragmentScalars = 0
        for uniform in active {
            samplers += uniform.type.samplers
            if uniform.vertex?.used == true { vertexScalars += uniform.type.scalars }
            if uniform.fragment?.used == true { fragmentScalars += uniform.type.scalars }
        }
        guard samplers <= GLSLLimits.textureUnits else {
            throw fail("the program uses \(samplers) samplers, and there are \(GLSLLimits.textureUnits) texture units")
        }
        guard vertexScalars <= GLSLLimits.uniformVectors * 4, fragmentScalars <= GLSLLimits.uniformVectors * 4 else {
            throw fail("a shader uses more uniforms than \(GLSLLimits.uniformVectors) vectors hold")
        }

        var vertexPlan = GLSLStagePlan(), fragmentPlan = GLSLStagePlan()
        var uniforms: [GLUniform] = []
        var end = 16, location = 0, texture = 0
        for uniform in active {
            var offset = 0
            if let layout = uniform.type.blockLayout {
                offset = (end + layout.alignment - 1) / layout.alignment * layout.alignment
                end = offset + layout.size
            }
            let firstTexture = texture
            report(uniform.name, uniform.type, offset, into: &uniforms, location: &location, texture: &texture)
            if let variable = uniform.vertex, variable.used {
                vertexPlan.uniforms.append(.init(variable: variable, offset: offset, texture: firstTexture))
            }
            if let variable = uniform.fragment, variable.used {
                fragmentPlan.uniforms.append(.init(variable: variable, offset: offset, texture: firstTexture))
            }
        }
        // A field of a struct in a struct has all their names in its own.
        if let long = uniforms.first(where: { $0.name.utf8.count > GLSLLimits.nameBytes }) {
            throw fail("the name of uniform '\(long.name.prefix(64))…' is longer than \(GLSLLimits.nameBytes) bytes")
        }

        // The attributes the code names: first the ones the program gave
        // a location (glBindAttribLocation), then the others in the
        // lowest places left. A matrix takes a location for each column.
        var taken = [String?](repeating: nil, count: GLSLLimits.attributes)
        var locations: [Int: Int] = [:]
        let used = vertex.globals.filter { $0.kind == .attribute && $0.used }
        func width(_ variable: GLSLVariable) -> Int { variable.type.isMatrix ? variable.type.size : 1 }
        for variable in used {
            guard let asked = bound[variable.name] else { continue }
            guard asked >= 0, asked + width(variable) <= GLSLLimits.attributes else {
                throw fail("attribute '\(variable.name)' is bound to location \(asked), and there are \(GLSLLimits.attributes)")
            }
            for place in asked..<(asked + width(variable)) {
                if let other = taken[place] {
                    throw fail("attributes '\(other)' and '\(variable.name)' are bound to the same location, \(place)")
                }
                taken[place] = variable.name
            }
            locations[variable.id] = asked
        }
        for variable in used where locations[variable.id] == nil {
            let count = width(variable)
            guard let free = (0...(GLSLLimits.attributes - count)).first(where: { start in
                !(start..<(start + count)).contains { taken[$0] != nil }
            }) else {
                throw fail("the vertex shader uses more attributes than the \(GLSLLimits.attributes) locations there are")
            }
            for place in free..<(free + count) { taken[place] = variable.name }
            locations[variable.id] = free
        }
        var attributes: [GLAttribute] = []
        for variable in used {
            let place = locations[variable.id] ?? 0
            attributes.append(GLAttribute(name: variable.name, type: glType(variable.type), location: place))
            vertexPlan.attributes.append((variable, place))
        }

        // The varyings the fragment shader reads come from the vertex
        // shader, by name.
        var written: [String: GLSLVariable] = [:]
        for variable in vertex.globals where variable.kind == .varying { written[variable.name] = variable }
        var slot = 0, numbers = 0
        for variable in fragment.globals where variable.kind == .varying && variable.used {
            guard let source = written[variable.name] else {
                throw fail("varying '\(variable.name)' is read by the fragment shader and not declared by the vertex shader")
            }
            guard source.type == variable.type else {
                throw fail("varying '\(variable.name)' is \(source.type.name) in the vertex shader and \(variable.type.name) in the fragment shader")
            }
            vertexPlan.varyings.append((source, slot))
            fragmentPlan.varyings.append((variable, slot))
            // A matrix goes as its columns, an array as its elements.
            var rows = variable.type.isMatrix ? variable.type.size : 1
            if case .array(let element, let count) = variable.type { rows = count * (element.isMatrix ? element.size : 1) }
            slot += rows
            numbers += variable.type.scalars
        }
        guard numbers <= GLSLLimits.varyingVectors * 4 else {
            throw fail("the program's varyings are more than \(GLSLLimits.varyingVectors) vectors hold")
        }

        let vertexWriter = GLSLMetalWriter(shader: vertex, plan: vertexPlan)
        let fragmentWriter = GLSLMetalWriter(shader: fragment, plan: fragmentPlan)
        let vertexText = try vertexWriter.write()
        let fragmentText = try fragmentWriter.write()
        let metal = GLSLMetalWriter.prelude(vertexWriter.helpers.union(fragmentWriter.helpers)) + vertexText + fragmentText
        guard metal.utf8.count <= GLSLLimits.outputBytes else {
            throw fail("the program is more than \(GLSLLimits.outputBytes) bytes in Metal's language")
        }
        return GLLinkedProgram(metal: metal, attributes: attributes, uniforms: uniforms, uniformBytes: (end + 15) / 16 * 16)
    }

    /// A uniform as glGetActiveUniform tells it: a struct field by
    /// field, an array of structs element by element, an array of
    /// anything else as one entry named `name[0]`.
    private static func report(_ name: String, _ type: GLSLType, _ offset: Int, into uniforms: inout [GLUniform],
                               location: inout Int, texture: inout Int) {
        var element = type
        var count = 1
        switch type {
        case .structure(let s):
            for field in s.fields {
                report("\(name).\(field.name)", field.type, offset + field.offset, into: &uniforms, location: &location, texture: &texture)
            }
            return
        case .array(let inner, let length):
            if case .structure = inner {
                let stride = inner.blockLayout?.size ?? 0
                for index in 0..<length {
                    report("\(name)[\(index)]", inner, offset + index * stride, into: &uniforms, location: &location, texture: &texture)
                }
                return
            }
            element = inner
            count = length
        default:
            break
        }
        let size = element.blockLayout?.size ?? 0
        let columns = element.isMatrix ? element.size : 1
        uniforms.append(GLUniform(name: type.isArray ? name + "[0]" : name, type: glType(element), size: count, location: location,
                                  offset: element.isSampler ? 0 : offset, stride: size, columns: columns,
                                  rows: element.size, columnStride: size / columns,
                                  texture: element.isSampler ? texture : nil))
        location += count
        if element.isSampler { texture += count }
    }

    /// OpenGL's number for a type.
    private static func glType(_ type: GLSLType) -> UInt32 {
        switch type {
        case .float: return GL.FLOAT
        case .int: return GL.INT
        case .bool: return GL.BOOL
        case .vec(let n): return GL.FLOAT_VEC2 + UInt32(n - 2)
        case .ivec(let n): return GL.INT_VEC2 + UInt32(n - 2)
        case .bvec(let n): return GL.BOOL_VEC2 + UInt32(n - 2)
        case .mat(let n): return GL.FLOAT_MAT2 + UInt32(n - 2)
        case .sampler2D: return GL.SAMPLER_2D
        case .samplerCube: return GL.SAMPLER_CUBE
        default: return 0
        }
    }
}
