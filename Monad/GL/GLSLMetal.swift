//
//  GLSLMetal.swift — a checked shader (GLSLTypes.swift) written in
//  Metal's language, to the conventions GLShaders.swift's first comment
//  gives. Nothing of the shader's text is copied: every word of the
//  output is made here, a number from its value, a name from a prefix of
//  ours and the letters the lexer let through.
//
//  A shader's globals, attributes and varyings become the members of a
//  struct, and each of its functions a function that is handed that
//  struct (mgl_g) and the uniform block (mgl_u) before its own
//  parameters, so that a function's body is nearly the body the shader
//  had. The entry point fills the struct, calls main and hands back what
//  main left. Every reference says where what it refers to lies (thread
//  or constant), which Metal's language asks for in all but its newest
//  versions.
//
//  What OpenGL defines and Metal does not is made defined here, because
//  the shader is a guest's: an int wraps around, a division by zero gives
//  zero, an index is held inside what it indexes, a float too large for
//  an int becomes the nearest one, and every variable starts as zeros.
//  And every loop, whatever it asks, counts its rounds and leaves after
//  65536 of them: one that never ended would keep the Mac's GPU.
//
//  Names: v<n>_name a variable, Vf<n>_name or Ff<n>_name a function,
//  VS<n>_name or FS<n>_name a struct, m_name a field or a uniform in the
//  block, and mgl_… everything that is ours. No name of the shader's can
//  be a word of Metal's or one of ours, whatever it is.
//
//

import Foundation

/// What linking worked out for one of a program's two shaders.
struct GLSLStagePlan {
    struct Uniform {
        let variable: GLSLVariable
        /// Where it lies in the uniform block.
        let offset: Int
        /// The texture and sampler index of its first sampler.
        let texture: Int
    }

    /// The uniforms this shader uses, in the block's order.
    var uniforms: [Uniform] = []
    var attributes: [(variable: GLSLVariable, location: Int)] = []
    /// The varyings that go from the vertex shader to the fragment
    /// shader, and the first of the slots each takes.
    var varyings: [(variable: GLSLVariable, slot: Int)] = []
}

final class GLSLMetalWriter {
    /// The functions of ours a shader's code may need; only the ones it
    /// does are written.
    enum Helper: Hashable {
        case integers, truncation, modulo, matrices, equality, scalarGeometry, textures, matrixFromMatrix
    }

    private let shader: GLSLShader
    private let plan: GLSLStagePlan
    /// V or F: the two shaders of a program are one Metal source.
    private let prefix: String
    private(set) var helpers = Set<Helper>()
    private var lines: [String] = []
    private var temporaries: [String] = []
    private var temporaryCount = 0
    private var comparedStructs = Set<Int>()
    private var blockStructs: [Int: String] = [:]
    private var blockStructLines: [String] = []
    private var textures: [(index: Int, cube: Bool)] = []
    private var loopCount = 0
    private var written = 0

    init(shader: GLSLShader, plan: GLSLStagePlan) {
        self.shader = shader
        self.plan = plan
        prefix = shader.stage == .vertex ? "V" : "F"
    }

    private func tooLong() -> GLSLError {
        GLSLError(line: 0, message: "the program is more than \(GLSLLimits.outputBytes) bytes in Metal's language")
    }

    private func emit(_ line: String) throws {
        written += line.utf8.count + 1
        guard written <= GLSLLimits.outputBytes else { throw tooLong() }
        lines.append(line)
    }

    // MARK: Names and types

    private func typeName(_ type: GLSLType) -> String {
        switch type {
        case .void: return "void"
        case .bool: return "bool"
        case .int: return "int"
        case .float: return "float"
        case .vec(let n): return "float\(n)"
        case .ivec(let n): return "int\(n)"
        case .bvec(let n): return "bool\(n)"
        case .mat(let n): return "float\(n)x\(n)"
        case .sampler2D: return "mgl_sampler2D"
        case .samplerCube: return "mgl_samplerCube"
        case .structure(let s): return structName(s)
        case .array(let element, let count): return "mgl_array<\(typeName(element)), \(count)>"
        }
    }

    private func structName(_ s: GLSLStruct) -> String { "\(prefix)S\(s.id)_\(s.name)" }

    /// A uniform with a bool or a sampler in it is not read from the
    /// block where it is used: a bool is an int there and a sampler is
    /// not there at all. The entry point makes a member of it.
    private func isMember(_ uniform: GLSLVariable) -> Bool {
        uniform.type.hasBool || uniform.type.hasSampler
    }

    /// What the shader declared outside its functions is a member of the
    /// stage's struct, which every function is handed as mgl_g.
    private func name(_ variable: GLSLVariable) -> String {
        switch variable.kind {
        case .builtin(let which):
            switch which {
            case .position: return "mgl_g.mgl_Position"
            case .pointSize: return "mgl_g.mgl_PointSize"
            case .fragCoord: return "mgl_g.mgl_FragCoord"
            case .frontFacing: return "mgl_g.mgl_FrontFacing"
            case .pointCoord: return "mgl_g.mgl_PointCoord"
            case .fragColor: return "mgl_g.mgl_FragColor"
            case .fragData: return "mgl_g.mgl_FragData"
            case .constant: return "0"
            }
        case .uniform:
            return isMember(variable) ? "mgl_g.\(member(variable))" : "mgl_u.m_\(variable.name)"
        case .global, .attribute, .varying:
            return "mgl_g.\(member(variable))"
        case .local, .parameter:
            return member(variable)
        }
    }

    private func member(_ variable: GLSLVariable) -> String { "v\(variable.id)_\(variable.name)" }

    private func name(_ function: GLSLFunction) -> String { "\(prefix)f\(function.id)_\(function.name)" }

    private func temporary(_ type: GLSLType) -> String {
        temporaryCount += 1
        let made = "mgl_t\(temporaryCount)"
        temporaries.append("\(typeName(type)) \(made) = {};")
        return made
    }

    // MARK: Values

    private func number(_ value: Float) -> String {
        if value.isNaN { return "NAN" }
        if value.isInfinite { return value < 0 ? "(-INFINITY)" : "INFINITY" }
        return value.sign == .minus ? "(\(value))" : "\(value)"
    }

    private func number(_ value: Int32) -> String {
        if value == Int32.min { return "(-2147483647 - 1)" }
        return value < 0 ? "(\(value))" : "\(value)"
    }

    private func literal(_ value: GLSLValue, _ type: GLSLType) -> String {
        let parts: [String]
        switch value {
        case .structure(let values):
            guard case .structure(let s) = type, values.count == s.fields.count else { return "{}" }
            return structName(s) + "{" + zip(values, s.fields).map { literal($0, $1.type) }.joined(separator: ", ") + "}"
        case .float(let numbers): parts = numbers.map { number($0) }
        case .int(let numbers): parts = numbers.map { number($0) }
        case .bool(let truths): parts = truths.map { $0 ? "true" : "false" }
        }
        guard parts.count == type.components, let first = parts.first else { return "\(typeName(type))(0)" }
        if type.isScalar { return first }
        if type.isMatrix {
            let n = type.size
            let columns = (0..<n).map { "float\(n)(" + parts[($0 * n)..<($0 * n + n)].joined(separator: ", ") + ")" }
            return typeName(type) + "(" + columns.joined(separator: ", ") + ")"
        }
        return typeName(type) + "(" + parts.joined(separator: ", ") + ")"
    }

    // MARK: Expressions

    private func group(_ text: String, _ bare: Bool) -> String { bare ? text : "(" + text + ")" }

    /// The expression in Metal's language. It stands on its own wherever
    /// it is put; `bare` leaves off the brackets around it, for where
    /// nothing is next to it.
    private func expr(_ e: GLSLExpr, bare: Bool = false) throws -> String {
        if let value = e.value { return literal(value, e.type) }
        let text: String
        switch e.kind {
        case .literal:
            text = "0"
        case .variable(let variable):
            text = name(variable)
        case .field(let base, let index):
            guard case .structure(let s) = base.type, s.fields.indices.contains(index) else { throw tooLong() }
            text = try expr(base) + ".m_" + s.fields[index].name
        case .swizzle(let base, let components):
            text = try expr(base) + "." + swizzle(components)
        case .index(let base, let index):
            text = try expr(base) + subscripted(base.type, index.value?.ints.first, try expr(index, bare: true))
        case .negate(let operand):
            if operand.type.base == .int {
                helpers.insert(.integers)
                text = "mgl_ineg(\(try expr(operand, bare: true)))"
            } else if operand.type.isMatrix {
                helpers.insert(.matrices)
                text = "mgl_mneg(\(try expr(operand, bare: true)))"
            } else {
                text = group("-" + (try expr(operand)), bare)
            }
        case .not(let operand):
            text = group("!" + (try expr(operand)), bare)
        case .step(let target, let increment, let prefix):
            text = try step(target, increment: increment, prefix: prefix, bare: bare)
        case .binary(let op, let left, let right):
            text = try binary(op, left, right, bare: bare)
        case .assign(nil, let target, let value):
            text = group(try expr(target) + " = " + (try expr(value, bare: true)), bare)
        case .assign(let op?, let target, let value):
            text = try assign(op, target, try expr(value), value.type, bare: bare)
        case .conditional(let condition, let first, let second):
            text = group(try expr(condition) + " ? " + (try expr(first)) + " : " + (try expr(second)), bare)
        case .sequence(let first, let second):
            // What changes nothing is not worth evaluating.
            text = first.effects ? "(" + (try expr(first, bare: true)) + ", " + (try expr(second, bare: true)) + ")" : try expr(second, bare: bare)
        case .construct(let arguments):
            text = try construct(e.type, arguments)
        case .call(let function, let arguments):
            text = try call(function, arguments)
        case .builtin(let function, let arguments):
            text = try builtin(function, arguments, e.type, bare: bare)
        }
        guard text.utf8.count <= GLSLLimits.outputBytes else { throw tooLong() }
        return text
    }

    private func swizzle(_ components: [Int]) -> String {
        String(components.map { ["x", "y", "z", "w"][min(max($0, 0), 3)] }.joined())
    }

    /// `[index]` after a value of this type. An array holds its index
    /// inside itself (mgl_array's operator does); for a vector or a
    /// matrix it is done here, unless the index is a constant, which the
    /// checker saw is inside.
    private func subscripted(_ type: GLSLType, _ constant: Int32?, _ index: String) -> String {
        if let constant { return "[\(constant)]" }
        if type.isArray { return "[\(index)]" }
        return "[clamp(\(index), 0, \(type.size - 1))]"
    }

    /// An expression that is written to, as text that can be used twice
    /// (read, then written): an index in it that changes something is
    /// evaluated once, before, into a temporary of the function.
    private func place(_ e: GLSLExpr) throws -> (before: [String], text: String) {
        guard e.effects else { return ([], try expr(e)) }
        switch e.kind {
        case .field(let base, let index):
            guard case .structure(let s) = base.type, s.fields.indices.contains(index) else { throw tooLong() }
            let inner = try place(base)
            return (inner.before, inner.text + ".m_" + s.fields[index].name)
        case .swizzle(let base, let components):
            let inner = try place(base)
            return (inner.before, inner.text + "." + swizzle(components))
        case .index(let base, let index):
            let inner = try place(base)
            if index.value != nil || !index.effects {
                return (inner.before, inner.text + subscripted(base.type, index.value?.ints.first, try expr(index, bare: true)))
            }
            let held = temporary(.int)
            return (inner.before + ["\(held) = \(try expr(index, bare: true))"], inner.text + subscripted(base.type, nil, held))
        default:
            return ([], try expr(e))
        }
    }

    /// + - * / of two values already written, by their types.
    private func arithmetic(_ op: GLSLBinaryOperator, _ left: String, _ leftType: GLSLType, _ right: String, _ rightType: GLSLType,
                            bare: Bool = false) -> String {
        if leftType.base == .int {
            // Metal leaves an int that overflows, and a division by
            // zero, undefined. Ours wrap and give zero.
            helpers.insert(.integers)
            let size = max(leftType.size, rightType.size)
            let a = leftType.size < size ? "int\(size)(\(left))" : left
            let b = rightType.size < size ? "int\(size)(\(right))" : right
            let function = op == .add ? "iadd" : op == .subtract ? "isub" : op == .multiply ? "imul" : "idiv"
            return "mgl_\(function)(\(a), \(b))"
        }
        if op != .multiply, leftType.isMatrix || rightType.isMatrix {
            // Metal has + and - for matrices but no /, and none of them
            // with a float: ours go column by column.
            helpers.insert(.matrices)
            let function = op == .add ? "madd" : op == .subtract ? "msub" : "mdiv"
            return "mgl_\(function)(\(left), \(right))"
        }
        return group("\(left) \(op.symbol) \(right)", bare)
    }

    private func binary(_ op: GLSLBinaryOperator, _ left: GLSLExpr, _ right: GLSLExpr, bare: Bool) throws -> String {
        let a = try expr(left), b = try expr(right)
        switch op {
        case .add, .subtract, .multiply, .divide:
            return arithmetic(op, a, left.type, b, right.type, bare: bare)
        case .less, .greater, .lessEqual, .greaterEqual, .and, .or:
            return group("\(a) \(op.symbol) \(b)", bare)
        case .xor:
            return group("\(a) != \(b)", bare)
        case .equal, .notEqual:
            if left.type.isScalar { return group("\(a) \(op.symbol) \(b)", bare) }
            // Metal compares vectors component by component; OpenGL's ==
            // is one answer for the whole value.
            helpers.insert(.equality)
            compare(left.type)
            return op == .equal ? "mgl_eq(\(a), \(b))" : group("!mgl_eq(\(a), \(b))", bare)
        }
    }

    /// A struct that is compared needs its mgl_eq, and so do the structs
    /// in it.
    private func compare(_ type: GLSLType) {
        guard case .structure(let s) = type, comparedStructs.insert(s.id).inserted else { return }
        for field in s.fields { compare(field.type) }
    }

    /// `target op= value`. Metal's own where it has it (floats and their
    /// vectors); otherwise the target is read, the operation done as it
    /// is done elsewhere, and the result written.
    private func assign(_ op: GLSLBinaryOperator, _ target: GLSLExpr, _ value: String, _ valueType: GLSLType, bare: Bool) throws -> String {
        let type = target.type
        if type.base == .float, !type.isMatrix, !valueType.isMatrix {
            return group(try expr(target) + " \(op.symbol)= " + value, bare)
        }
        let place = try place(target)
        let assignment = place.text + " = " + arithmetic(op, place.text, type, value, valueType, bare: true)
        guard !place.before.isEmpty else { return group(assignment, bare) }
        return "(" + (place.before + [assignment]).joined(separator: ", ") + ")"
    }

    /// ++ and --. After the value is taken (x++), the old value waits in
    /// a temporary while the new one is written.
    private func step(_ target: GLSLExpr, increment: Bool, prefix: Bool, bare: Bool) throws -> String {
        let op = increment ? GLSLBinaryOperator.add : .subtract
        let base = target.type.base ?? .float
        let one = base == .int ? "1" : "1.0"
        if prefix { return try assign(op, target, one, base, bare: bare) }
        let place = try place(target)
        let old = temporary(target.type)
        let parts = place.before + ["\(old) = \(place.text)",
                                    "\(place.text) = " + arithmetic(op, old, target.type, one, base, bare: true), old]
        return "(" + parts.joined(separator: ", ") + ")"
    }

    /// A value of numbers made of other numbers.
    private func convert(_ text: String, from: GLSLType, to: GLSLType, size: Int) -> String {
        if from == to { return text }
        let target = typeName(.vector(to, size))
        if to == .bool {
            let zero = from == .float ? "0.0" : "0"
            return size == 1 ? "(\(text) != \(zero))" : "(\(text) != \(typeName(.vector(from, size)))(\(zero)))"
        }
        if from == .bool {
            return size == 1 ? "\(target)(\(text))" : "select(\(target)(0), \(target)(1), \(text))"
        }
        if to == .int {
            // A float that no int holds: Metal leaves it undefined.
            helpers.insert(.truncation)
            return "mgl_ftoi(\(text))"
        }
        return "\(target)(\(text))"
    }

    /// Named alone or a constant: written twice, it is still evaluated
    /// once for all that matters.
    private func isSimple(_ e: GLSLExpr) -> Bool {
        if e.value != nil { return true }
        if case .variable = e.kind { return true }
        return false
    }

    private func construct(_ type: GLSLType, _ arguments: [GLSLExpr]) throws -> String {
        if case .structure(let s) = type {
            return structName(s) + "{" + (try arguments.map { try expr($0, bare: true) }.joined(separator: ", ")) + "}"
        }
        guard let base = type.base, let first = arguments.first, let firstBase = first.type.base else { throw tooLong() }
        if type.isScalar {
            var text = try expr(first)
            if first.type.isVector { text += ".x" } else if first.type.isMatrix { text += "[0].x" }
            return convert(text, from: firstBase, to: base, size: 1)
        }
        if arguments.count == 1, first.type.isScalar {
            // Metal too makes a vector of one number all that number,
            // and a matrix of one number that number along its diagonal.
            return typeName(type) + "(" + convert(try expr(first, bare: true), from: firstBase, to: base, size: 1) + ")"
        }
        if arguments.count == 1, type.isMatrix, first.type.isMatrix {
            if first.type == type { return try expr(first) }
            helpers.insert(.matrixFromMatrix)
            return "mgl_mat\(type.size)(\(try expr(first, bare: true)))"
        }
        // The arguments' components in order fill the vector, or the
        // matrix column after column. A piece is what one argument (or
        // one column of a matrix argument) gives to one column.
        struct Piece {
            let argument: Int
            let column: Int?
            let from: Int
            let to: Int
            let whole: Bool
        }
        let width = type.isMatrix ? type.size : type.components
        var columns: [[Piece]] = []
        var uses = [Int](repeating: 0, count: arguments.count)
        var argument = 0, unit = 0, offset = 0
        for _ in 0..<(type.isMatrix ? type.size : 1) {
            var pieces: [Piece] = []
            var need = width
            while need > 0, argument < arguments.count {
                let given = arguments[argument].type
                let unitSize = given.isMatrix ? given.size : given.components
                let take = min(need, unitSize - offset)
                guard take > 0 else { throw tooLong() }
                pieces.append(Piece(argument: argument, column: given.isMatrix ? unit : nil, from: offset, to: offset + take,
                                    whole: take == unitSize))
                uses[argument] += 1
                need -= take
                offset += take
                if offset == unitSize {
                    offset = 0
                    unit += 1
                    if unit == (given.isMatrix ? given.size : 1) {
                        unit = 0
                        argument += 1
                    }
                }
            }
            columns.append(pieces)
        }
        // An argument cut into several pieces is evaluated once, into a
        // temporary; then so is every other that changes something, to
        // keep their order.
        let holds = zip(arguments, uses).contains { $1 > 1 && !isSimple($0) }
        var before: [String] = []
        var texts: [String] = []
        for given in arguments {
            if holds, !isSimple(given) {
                let held = temporary(given.type)
                before.append("\(held) = \(try expr(given, bare: true))")
                texts.append(held)
            } else {
                texts.append(try expr(given))
            }
        }
        var made: [String] = []
        for pieces in columns {
            var parts: [String] = []
            for piece in pieces {
                let given = arguments[piece.argument].type
                var text = texts[piece.argument]
                if let column = piece.column { text += "[\(column)]" }
                if !piece.whole { text += "." + swizzle(Array(piece.from..<piece.to)) }
                parts.append(convert(text, from: given.base ?? base, to: base, size: piece.to - piece.from))
            }
            if pieces.count == 1, let only = pieces.first, only.to - only.from == width, let part = parts.first {
                made.append(part)
            } else {
                made.append(typeName(.vector(base, width)) + "(" + parts.joined(separator: ", ") + ")")
            }
        }
        var text = type.isMatrix ? typeName(type) + "(" + made.joined(separator: ", ") + ")" : (made.first ?? "0")
        if !before.isEmpty { text = "(" + (before + [text]).joined(separator: ", ") + ")" }
        return text
    }

    /// A call of one of the shader's functions. An out or inout argument
    /// is copied in and copied back, as OpenGL has it: through a
    /// temporary of the calling function, since what is written to may be
    /// a swizzle, which no reference can be to.
    private func call(_ function: GLSLFunction, _ arguments: [GLSLExpr]) throws -> String {
        var before: [String] = []
        var after: [String] = []
        var texts: [String] = []
        for (parameter, argument) in zip(function.parameters, arguments) {
            guard parameter.direction != .input else {
                texts.append(try expr(argument, bare: true))
                continue
            }
            let place = try place(argument)
            let held = temporary(parameter.type)
            before += place.before
            if parameter.direction == .both { before.append("\(held) = \(place.text)") }
            after.append("\(place.text) = \(held)")
            texts.append(held)
        }
        let call = name(function) + "(" + (["mgl_g", "mgl_u"] + texts).joined(separator: ", ") + ")"
        guard !before.isEmpty || !after.isEmpty else { return call }
        if function.result == .void { return "(" + (before + [call] + after).joined(separator: ", ") + ")" }
        let result = temporary(function.result)
        return "(" + (before + ["\(result) = \(call)"] + after + [result]).joined(separator: ", ") + ")"
    }

    private func builtin(_ function: GLSLBuiltin, _ arguments: [GLSLExpr], _ type: GLSLType, bare: Bool) throws -> String {
        let a = try arguments.map { try expr($0, bare: true) }
        guard let first = arguments.first else { throw tooLong() }
        /// A float where OpenGL takes a float for a vector's every component.
        func wide(_ index: Int) -> String {
            arguments[index].type == type ? a[index] : "\(typeName(type))(\(a[index]))"
        }
        func call(_ name: String, _ given: [String]) -> String { name + "(" + given.joined(separator: ", ") + ")" }
        // Metal's geometric functions are for vectors; OpenGL's take a
        // float too.
        func geometric(_ name: String) -> String {
            guard first.type == .float else { return call(name, a) }
            helpers.insert(.scalarGeometry)
            return call("mgl_" + name, a)
        }
        func texture(_ name: String, projected: Bool) -> String {
            helpers.insert(.textures)
            let point = projected ? "mgl_proj(\(a[1]))" : a[1]
            if a.count == 3 {
                return call("mgl_\(name)\(shader.stage == .fragment ? "Bias" : "Lod")", [a[0], point, a[2]])
            }
            // A vertex shader has no derivatives to choose a level by:
            // it reads the first.
            return shader.stage == .fragment ? call("mgl_\(name)", [a[0], point]) : call("mgl_\(name)Lod", [a[0], point, "0.0"])
        }
        switch function {
        case .radians: return group("\(try expr(first)) * 0.017453292", bare)
        case .degrees: return group("\(try expr(first)) * 57.29578", bare)
        case .sin, .cos, .tan, .asin, .acos, .pow, .exp, .log, .exp2, .log2, .sqrt, .sign, .floor, .ceil, .fract, .cross:
            return call(function.rawValue, a)
        case .atan: return call(a.count == 2 ? "atan2" : "atan", a)
        case .inversesqrt: return call("rsqrt", a)
        case .abs: return call("fabs", a)
        case .mod:
            // Metal's fmod keeps the sign of x; OpenGL's mod is x - y * floor(x / y).
            helpers.insert(.modulo)
            return call("mgl_mod", [a[0], wide(1)])
        case .min, .max: return call(function.rawValue, [a[0], wide(1)])
        case .clamp: return call("clamp", [a[0], wide(1), wide(2)])
        case .mix: return call("mix", [a[0], a[1], wide(2)])
        case .step: return call("step", [wide(0), a[1]])
        case .smoothstep: return call("smoothstep", [wide(0), wide(1), a[2]])
        case .length, .distance, .dot, .normalize, .faceforward, .reflect, .refract:
            return geometric(function.rawValue)
        case .matrixCompMult:
            helpers.insert(.matrices)
            return call("mgl_mcompmul", a)
        case .lessThan: return group("\(try expr(arguments[0])) < \(try expr(arguments[1]))", bare)
        case .lessThanEqual: return group("\(try expr(arguments[0])) <= \(try expr(arguments[1]))", bare)
        case .greaterThan: return group("\(try expr(arguments[0])) > \(try expr(arguments[1]))", bare)
        case .greaterThanEqual: return group("\(try expr(arguments[0])) >= \(try expr(arguments[1]))", bare)
        case .equal: return group("\(try expr(arguments[0])) == \(try expr(arguments[1]))", bare)
        case .notEqual: return group("\(try expr(arguments[0])) != \(try expr(arguments[1]))", bare)
        case .anyOf: return call("any", a)
        case .allOf: return call("all", a)
        case .notOf: return group("\(try expr(first)) == \(typeName(type))(false)", bare)
        case .texture2D, .texture2DLod: return texture("texture2D", projected: false)
        case .texture2DProj, .texture2DProjLod: return texture("texture2D", projected: true)
        case .textureCube, .textureCubeLod: return texture("textureCube", projected: false)
        case .dFdx: return call("dfdx", a)
        // Metal's rows are counted the other way from OpenGL's when the
        // picture is drawn as it is (the block's first float is 1).
        case .dFdy: return group("dfdy(\(a[0])) * -mgl_u.mgl_flip", bare)
        case .fwidth: return call("fwidth", a)
        }
    }

    // MARK: Statements

    private func statements(_ list: [GLSLStmt], _ indent: String) throws {
        for statement in list { try write(statement, indent) }
    }

    /// The body of an if or a loop, whose braces are written by them: a
    /// body that is one block needs no second pair. Every name in the
    /// output is its own, so the block's scope is not missed.
    private func body(_ list: [GLSLStmt], _ indent: String) throws {
        if list.count == 1, case .block(let inner) = list[0] {
            try statements(inner, indent)
        } else {
            try statements(list, indent)
        }
    }

    /// An expression whose value nobody takes, or nil when evaluating
    /// it would change nothing. The value of `i++` need not be kept.
    private func unused(_ e: GLSLExpr) throws -> String? {
        guard e.effects else { return nil }
        if case .step(let target, let increment, false) = e.kind {
            return try step(target, increment: increment, prefix: true, bare: true)
        }
        return try expr(e, bare: true)
    }

    private func write(_ statement: GLSLStmt, _ indent: String) throws {
        let deeper = indent + "    "
        switch statement {
        case .expression(let e):
            if let text = try unused(e) { try emit(indent + text + ";") }
        case .declare(let variable, let initializer):
            guard variable.value == nil else { return }
            let value = try initializer.map { try expr($0, bare: true) } ?? "{}"
            try emit("\(indent)\(typeName(variable.type)) \(name(variable)) = \(value);")
        case .block(let body):
            try emit(indent + "{")
            try statements(body, deeper)
            try emit(indent + "}")
        case .branch(let branches, let otherwise):
            for (index, branch) in branches.enumerated() {
                try emit(indent + (index == 0 ? "if (" : "} else if (") + (try expr(branch.condition, bare: true)) + ") {")
                try body(branch.body, deeper)
            }
            if let otherwise {
                try emit(indent + "} else {")
                try body(otherwise, deeper)
            }
            try emit(indent + "}")
        case .loop(let loop):
            // Every loop counts its rounds and leaves after the most a
            // loop may run: a shader's loop may be one that never ends,
            // and Metal's compiler may do anything with one of those.
            try statements(loop.setup, indent)
            loopCount += 1
            let rounds = "mgl_n\(loopCount)"
            let limit = "\(rounds) < \(GLSLLimits.loopIterations)"
            let condition = try loop.condition.map { " && (\(try expr($0, bare: true)))" } ?? ""
            if loop.bodyFirst {
                try emit("\(indent)int \(rounds) = 0;")
                try emit(indent + "do {")
                try body(loop.body, deeper)
                try emit("\(indent)} while (++\(limit)\(condition));")
            } else {
                // continue goes to the third part of Metal's for as it
                // does to OpenGL's: the count and the loop's own step.
                let step = try loop.step.flatMap { try unused($0) }.map { ", " + $0 } ?? ""
                try emit("\(indent)for (int \(rounds) = 0; \(limit)\(condition); \(rounds)++\(step)) {")
                try body(loop.body, deeper)
                try emit(indent + "}")
            }
        case .breakLoop:
            try emit(indent + "break;")
        case .continueLoop:
            try emit(indent + "continue;")
        case .discard:
            try emit(indent + "discard_fragment();")
        case .result(let value):
            try emit(indent + (try value.map { "return \(try expr($0, bare: true));" } ?? "return;"))
        }
    }

    /// One of the shader's functions. It is handed the stage's struct
    /// and the uniform block before its own parameters.
    private func write(_ function: GLSLFunction) throws -> (head: String, body: [String]) {
        lines = []
        temporaries = []
        let body = function.body ?? []
        try statements(body, "    ")
        // Running off the end of a function that returns a value is
        // undefined in Metal as in OpenGL; here it returns zeros.
        var ends = false
        if case .result? = body.last { ends = true }
        if function.result != .void, !ends { try emit("    return {};") }
        var parameters = ["thread mgl_\(prefix)S& mgl_g", "constant mgl_\(prefix)Block& mgl_u"]
        for parameter in function.parameters {
            parameters.append((parameter.direction == .input ? "" : "thread ") + typeName(parameter.type)
                + (parameter.direction == .input ? " " : "& ") + name(parameter))
        }
        let head = "\(typeName(function.result)) \(name(function))(\(parameters.joined(separator: ", ")))"
        return (head, temporaries.map { "    " + $0 } + lines)
    }

    // MARK: The uniform block

    /// The type a value has in the block: as elsewhere, but a bool is an
    /// int and a sampler is not there. nil for samplers only.
    private func blockType(_ type: GLSLType) -> String? {
        switch type {
        case .sampler2D, .samplerCube, .void: return nil
        case .bool: return "int"
        case .bvec(let n): return "int\(n)"
        case .array(let element, let count):
            return blockType(element).map { "mgl_array<\($0), \(count)>" }
        case .structure(let s):
            guard type.hasBool || type.hasSampler else { return structName(s) }
            guard type.blockLayout != nil else { return nil }
            if let known = blockStructs[s.id] { return known }
            var fields: [String] = []
            for field in s.fields {
                if let fieldType = blockType(field.type) { fields.append("    \(fieldType) m_\(field.name);") }
            }
            let made = "mgl_\(prefix)B\(s.id)"
            blockStructs[s.id] = made
            blockStructLines += ["struct \(made) {"] + fields + ["};"]
            return made
        default: return typeName(type)
        }
    }

    /// Statements that make a member of a uniform from the block and the
    /// textures: the bools from ints, the samplers from the entry
    /// point's textures, the rest copied.
    private func fill(_ target: String, _ source: String, _ type: GLSLType, texture: inout Int, depth: Int, _ indent: String) throws {
        switch type {
        case .bool:
            try emit("\(indent)\(target) = \(source) != 0;")
        case .bvec(let n):
            try emit("\(indent)\(target) = \(source) != int\(n)(0);")
        case .sampler2D, .samplerCube:
            try emit("\(indent)\(target).t = mgl_t\(texture); \(target).s = mgl_s\(texture);")
            textures.append((texture, type == .samplerCube))
            texture += 1
        case .structure(let s) where type.hasBool || type.hasSampler:
            for field in s.fields {
                try fill("\(target).m_\(field.name)", "\(source).m_\(field.name)", field.type, texture: &texture, depth: depth, indent)
            }
        case .array(let element, let count) where element.hasSampler:
            // Each sampler is a texture of its own: there are at most
            // sixteen of them, so this is short.
            for index in 0..<count {
                try fill("\(target).e[\(index)]", "\(source).e[\(index)]", element, texture: &texture, depth: depth, indent)
            }
        case .array(let element, let count) where element.hasBool:
            let index = "mgl_i\(depth)"
            try emit("\(indent)for (int \(index) = 0; \(index) < \(count); \(index)++) {")
            try fill("\(target).e[\(index)]", "\(source).e[\(index)]", element, texture: &texture, depth: depth + 1, indent + "    ")
            try emit(indent + "}")
        default:
            try emit("\(indent)\(target) = \(source);")
        }
    }

    /// A varying as the vectors that go between the stages: Metal takes
    /// no matrix and no array there.
    private func rows(_ type: GLSLType, _ access: String) -> [(access: String, type: String)] {
        switch type {
        case .mat(let n): return (0..<n).map { ("\(access)[\($0)]", "float\(n)") }
        case .array(let element, let count): return (0..<count).flatMap { rows(element, "\(access).e[\($0)]") }
        default: return [(access, typeName(type))]
        }
    }

    // MARK: The whole stage

    /// The stage in Metal's language: its types, its struct, its entry
    /// point.
    func write() throws -> String {
        let vertex = shader.stage == .vertex
        let stage = "mgl_\(prefix)S", block = "mgl_\(prefix)Block"

        // A function may be called above where its body is, as a
        // prototype lets it be in the shader: all are declared first.
        var prototypes: [String] = []
        var functions: [String] = []
        for function in shader.functions where function.body != nil {
            let written = try write(function)
            prototypes.append(written.head + ";")
            functions += [written.head + " {"] + written.body + ["}"]
        }

        // The members: what the shader declared outside its functions
        // and uses, and the language's own variables. The entry point
        // gives them the values they start with.
        var members: [String] = []
        func member(_ type: GLSLType, _ name: String) {
            members.append("    \(typeName(type)) \(name);")
        }
        lines = []
        temporaries = []
        if vertex {
            member(.vec(4), "mgl_Position")
            member(.float, "mgl_PointSize")
            try emit("    mgl_g.mgl_PointSize = 1.0;")
        } else {
            member(.vec(4), "mgl_FragCoord")
            member(.bool, "mgl_FrontFacing")
            member(.vec(2), "mgl_PointCoord")
            member(.vec(4), "mgl_FragColor")
            member(.array(.vec(4), 1), "mgl_FragData")
        }
        // A varying the fragment shader reads leaves the vertex shader
        // whether or not its code names it.
        let linked = Set(plan.varyings.map(\.variable.id))
        for global in shader.globals where (global.used || linked.contains(global.id)) && global.value == nil {
            if global.kind == .uniform, !isMember(global) { continue }
            member(global.type, self.member(global))
            if let initializer = global.initializer {
                try emit("    \(name(global)) = \(try expr(initializer, bare: true));")
            }
        }

        // The entry point's own lines, before main and after.
        var texture = 0
        var blockMembers: [String] = []
        var cursor = 16
        for uniform in plan.uniforms {
            texture = uniform.texture
            let variable = uniform.variable
            let inBlock = blockType(variable.type)
            if let inBlock, let layout = variable.type.blockLayout {
                // The block is the whole program's: what this shader does
                // not use of it is passed over.
                if uniform.offset > cursor { blockMembers.append("    uchar mgl_p\(blockMembers.count)[\(uniform.offset - cursor)];") }
                blockMembers.append("    \(inBlock) m_\(variable.name);")
                cursor = uniform.offset + layout.size
            }
            if isMember(variable) {
                try fill(name(variable), "mgl_u.m_\(variable.name)", variable.type, texture: &texture, depth: 0, "    ")
            }
        }
        var input: [String] = []
        var output: [String] = []
        if vertex {
            for attribute in plan.attributes {
                let variable = attribute.variable
                if case .mat(let n) = variable.type {
                    let columns = (0..<n).map { "mgl_in.mgl_a\(attribute.location + $0)" }
                    for column in 0..<n { input.append("    float\(n) mgl_a\(attribute.location + column) [[attribute(\(attribute.location + column))]];") }
                    try emit("    \(name(variable)) = float\(n)x\(n)(\(columns.joined(separator: ", ")));")
                } else {
                    input.append("    \(typeName(variable.type)) mgl_a\(attribute.location) [[attribute(\(attribute.location))]];")
                    try emit("    \(name(variable)) = mgl_in.mgl_a\(attribute.location);")
                }
            }
            output.append("    float4 mgl_position [[position]];")
            if shader.uses(.pointSize) { output.append("    float mgl_pointsize [[point_size]];") }
        } else {
            input.append("    float4 mgl_position [[position]];")
        }
        var after: [String] = []
        for varying in plan.varyings {
            for (index, row) in rows(varying.variable.type, name(varying.variable)).enumerated() {
                let slot = "mgl_v\(varying.slot + index)"
                if vertex {
                    output.append("    \(row.type) \(slot) [[user(\(slot))]];")
                    after.append("    mgl_out.\(slot) = \(row.access);")
                } else {
                    input.append("    \(row.type) \(slot) [[user(\(slot))]];")
                    try emit("    \(row.access) = mgl_in.\(slot);")
                }
            }
        }
        var parameters: [String] = []
        if !input.isEmpty { parameters.append("mgl_\(prefix)In mgl_in [[stage_in]]") }
        if !vertex {
            if shader.uses(.fragCoord) {
                // OpenGL counts a picture's rows from the bottom.
                try emit("    mgl_g.mgl_FragCoord = mgl_in.mgl_position;")
                try emit("    if (mgl_u.mgl_flip > 0.0) { mgl_g.mgl_FragCoord.y = mgl_u.mgl_height - mgl_g.mgl_FragCoord.y; }")
            }
            if shader.uses(.frontFacing) {
                parameters.append("bool mgl_ff [[front_facing]]")
                try emit("    mgl_g.mgl_FrontFacing = mgl_ff;")
            }
            if shader.uses(.pointCoord) {
                // A point's top is its top on the screen: turned over
                // with the picture when the picture is drawn turned over.
                parameters.append("float2 mgl_pc [[point_coord]]")
                try emit("    mgl_g.mgl_PointCoord = mgl_u.mgl_flip < 0.0 ? float2(mgl_pc.x, 1.0 - mgl_pc.y) : mgl_pc;")
            }
        }
        parameters.append("constant \(block)& mgl_u [[buffer(30)]]")
        for used in textures.sorted(by: { $0.index < $1.index }) {
            parameters.append("\(used.cube ? "texturecube" : "texture2d")<float> mgl_t\(used.index) [[texture(\(used.index))]]")
            parameters.append("sampler mgl_s\(used.index) [[sampler(\(used.index))]]")
        }
        let before = temporaries.map { "    " + $0 } + lines

        // Everything in the order Metal's compiler needs it.
        lines = []
        written = 0
        for declared in shader.structs {
            try emit("struct \(structName(declared)) {")
            for field in declared.fields { try emit("    \(typeName(field.type)) m_\(field.name);") }
            try emit("};")
            if comparedStructs.contains(declared.id) {
                let equal = declared.fields.map { "mgl_eq(a.m_\($0.name), b.m_\($0.name))" }.joined(separator: " && ")
                try emit("bool mgl_eq(\(structName(declared)) a, \(structName(declared)) b) { return \(equal); }")
            }
        }
        for line in blockStructLines { try emit(line) }
        try emit("struct \(block) {")
        try emit("    float mgl_flip;")
        try emit("    float mgl_height;")
        try emit("    float mgl_r0;")
        try emit("    float mgl_r1;")
        for line in blockMembers { try emit(line) }
        try emit("};")
        if !input.isEmpty {
            try emit("struct mgl_\(prefix)In {")
            for line in input { try emit(line) }
            try emit("};")
        }
        if vertex {
            try emit("struct mgl_VOut {")
            for line in output { try emit(line) }
            try emit("};")
        }
        try emit("struct \(stage) {")
        for line in members { try emit(line) }
        try emit("};")
        for line in prototypes { try emit(line) }
        for line in functions { try emit(line) }
        let result = vertex ? "mgl_VOut" : "float4"
        try emit("\(vertex ? "vertex" : "fragment") \(result) monad_\(vertex ? "vertex" : "fragment")(\(parameters.joined(separator: ", "))) {")
        // Every member starts as zeros: OpenGL leaves what was not
        // written undefined, and here it is not whatever was there.
        try emit("    \(stage) mgl_g = {};")
        for line in before { try emit(line) }
        if let main = shader.main { try emit("    \(name(main))(mgl_g, mgl_u);") }
        if vertex {
            try emit("    mgl_VOut mgl_out = {};")
            try emit("    mgl_out.mgl_position = mgl_g.mgl_Position;")
            // The picture is turned over when the block says so, and
            // OpenGL's depth of -w…w becomes Metal's 0…w.
            try emit("    mgl_out.mgl_position.y *= mgl_u.mgl_flip;")
            try emit("    mgl_out.mgl_position.z = (mgl_out.mgl_position.z + mgl_out.mgl_position.w) * 0.5;")
            if shader.uses(.pointSize) { try emit("    mgl_out.mgl_pointsize = mgl_g.mgl_PointSize;") }
            for line in after { try emit(line) }
            try emit("    return mgl_out;")
        } else if shader.builtins[.fragData]?.written == true {
            try emit("    return mgl_g.mgl_FragData.e[0];")
        } else {
            try emit("    return mgl_g.mgl_FragColor;")
        }
        try emit("}")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Our own functions

    /// What both stages' code stands on: the array that holds its index
    /// inside itself, a sampler with its texture, and the helpers asked
    /// for.
    static func prelude(_ helpers: Set<Helper>) -> String {
        var out = """
        #include <metal_stdlib>
        using namespace metal;
        template<typename T, int N> struct mgl_array {
            T e[N];
            thread T& operator[](int i) thread { return e[clamp(i, 0, N - 1)]; }
            const thread T& operator[](int i) const thread { return e[clamp(i, 0, N - 1)]; }
            const constant T& operator[](int i) const constant { return e[clamp(i, 0, N - 1)]; }
        };
        struct mgl_sampler2D { texture2d<float> t; sampler s; };
        struct mgl_samplerCube { texturecube<float> t; sampler s; };

        """
        let letters = ["x", "y", "z", "w"]
        func each(_ n: Int, _ body: (Int) -> String) -> String { (0..<n).map(body).joined(separator: ", ") }
        if helpers.contains(.integers) {
            for (name, op) in [("iadd", "+"), ("isub", "-"), ("imul", "*")] {
                out += "int mgl_\(name)(int a, int b) { return as_type<int>(as_type<uint>(a) \(op) as_type<uint>(b)); }\n"
                for n in 2...4 {
                    out += "int\(n) mgl_\(name)(int\(n) a, int\(n) b) { return as_type<int\(n)>(as_type<uint\(n)>(a) \(op) as_type<uint\(n)>(b)); }\n"
                }
            }
            out += "int mgl_ineg(int a) { return as_type<int>(0u - as_type<uint>(a)); }\n"
            out += "int mgl_idiv(int a, int b) { return (b == 0 || (b == -1 && a == (-2147483647 - 1))) ? 0 : a / b; }\n"
            for n in 2...4 {
                out += "int\(n) mgl_ineg(int\(n) a) { return as_type<int\(n)>(uint\(n)(0u) - as_type<uint\(n)>(a)); }\n"
                out += "int\(n) mgl_idiv(int\(n) a, int\(n) b) { return int\(n)(\(each(n) { "mgl_idiv(a.\(letters[$0]), b.\(letters[$0]))" })); }\n"
            }
        }
        if helpers.contains(.truncation) {
            out += "int mgl_ftoi(float v) { return (v >= -2147483648.0 && v < 2147483648.0) ? int(v) : (v < 0.0 ? (-2147483647 - 1) : 2147483647); }\n"
            for n in 2...4 {
                out += "int\(n) mgl_ftoi(float\(n) v) { return int\(n)(\(each(n) { "mgl_ftoi(v.\(letters[$0]))" })); }\n"
            }
        }
        if helpers.contains(.modulo) {
            out += "template<typename T> T mgl_mod(T x, T y) { return x - y * floor(x / y); }\n"
        }
        if helpers.contains(.matrices) {
            for n in 2...4 {
                let matrix = "float\(n)x\(n)"
                for (name, op) in [("madd", "+"), ("msub", "-"), ("mdiv", "/")] {
                    out += "\(matrix) mgl_\(name)(\(matrix) a, \(matrix) b) { return \(matrix)(\(each(n) { "a[\($0)] \(op) b[\($0)]" })); }\n"
                    out += "\(matrix) mgl_\(name)(\(matrix) a, float b) { return \(matrix)(\(each(n) { "a[\($0)] \(op) b" })); }\n"
                    out += "\(matrix) mgl_\(name)(float a, \(matrix) b) { return \(matrix)(\(each(n) { "a \(op) b[\($0)]" })); }\n"
                }
                out += "\(matrix) mgl_mneg(\(matrix) a) { return \(matrix)(\(each(n) { "-a[\($0)]" })); }\n"
                out += "\(matrix) mgl_mcompmul(\(matrix) a, \(matrix) b) { return \(matrix)(\(each(n) { "a[\($0)] * b[\($0)]" })); }\n"
            }
        }
        if helpers.contains(.equality) {
            for scalar in ["float", "int", "bool"] {
                out += "bool mgl_eq(\(scalar) a, \(scalar) b) { return a == b; }\n"
                for n in 2...4 { out += "bool mgl_eq(\(scalar)\(n) a, \(scalar)\(n) b) { return all(a == b); }\n" }
            }
            for n in 2...4 {
                out += "bool mgl_eq(float\(n)x\(n) a, float\(n)x\(n) b) { return \((0..<n).map { "all(a[\($0)] == b[\($0)])" }.joined(separator: " && ")); }\n"
            }
        }
        if helpers.contains(.scalarGeometry) {
            out += """
            float mgl_length(float x) { return fabs(x); }
            float mgl_distance(float a, float b) { return fabs(a - b); }
            float mgl_dot(float a, float b) { return a * b; }
            float mgl_normalize(float x) { return sign(x); }
            float mgl_faceforward(float n, float i, float r) { return r * i < 0.0 ? n : -n; }
            float mgl_reflect(float i, float n) { return i - 2.0 * n * i * n; }
            float mgl_refract(float i, float n, float eta) { float d = n * i; float k = 1.0 - eta * eta * (1.0 - d * d); return k < 0.0 ? 0.0 : eta * i - (eta * d + sqrt(k)) * n; }

            """
        }
        if helpers.contains(.textures) {
            out += """
            float2 mgl_proj(float3 p) { return p.xy / p.z; }
            float2 mgl_proj(float4 p) { return p.xy / p.w; }
            float4 mgl_texture2D(mgl_sampler2D s, float2 p) { return s.t.sample(s.s, p); }
            float4 mgl_texture2DBias(mgl_sampler2D s, float2 p, float b) { return s.t.sample(s.s, p, bias(b)); }
            float4 mgl_texture2DLod(mgl_sampler2D s, float2 p, float l) { return s.t.sample(s.s, p, level(l)); }
            float4 mgl_textureCube(mgl_samplerCube s, float3 p) { return s.t.sample(s.s, p); }
            float4 mgl_textureCubeBias(mgl_samplerCube s, float3 p, float b) { return s.t.sample(s.s, p, bias(b)); }
            float4 mgl_textureCubeLod(mgl_samplerCube s, float3 p, float l) { return s.t.sample(s.s, p, level(l)); }

            """
        }
        if helpers.contains(.matrixFromMatrix) {
            // A matrix of another: what both have, the identity elsewhere.
            out += """
            float2x2 mgl_mat2(float3x3 m) { return float2x2(m[0].xy, m[1].xy); }
            float2x2 mgl_mat2(float4x4 m) { return float2x2(m[0].xy, m[1].xy); }
            float3x3 mgl_mat3(float2x2 m) { return float3x3(float3(m[0], 0.0), float3(m[1], 0.0), float3(0.0, 0.0, 1.0)); }
            float3x3 mgl_mat3(float4x4 m) { return float3x3(m[0].xyz, m[1].xyz, m[2].xyz); }
            float4x4 mgl_mat4(float2x2 m) { return float4x4(float4(m[0], 0.0, 0.0), float4(m[1], 0.0, 0.0), float4(0.0, 0.0, 1.0, 0.0), float4(0.0, 0.0, 0.0, 1.0)); }
            float4x4 mgl_mat4(float3x3 m) { return float4x4(float4(m[0], 0.0), float4(m[1], 0.0), float4(m[2], 0.0), float4(0.0, 0.0, 0.0, 1.0)); }

            """
        }
        return out
    }
}
