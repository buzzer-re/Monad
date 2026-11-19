//
//  GLSLChecker.swift — the rules of GLSL ES 1.00 that are not grammar:
//  what is declared where, which types an operator takes and gives, what
//  may be written to, what a constant expression comes to. The parser
//  (GLSLParser.swift) hands it each piece as it reads it and gets back
//  the checked piece of the tree (GLSLTypes.swift), or the error for the
//  shader's log.
//
//  The language converts nothing by itself: 1 + 1.0 is an error, and so
//  is everything else the specification does not say is allowed.
//

import Foundation

final class GLSLChecker {
    enum Symbol {
        case variable(GLSLVariable)
        case structure(GLSLStruct)
        case functions([GLSLFunction])
    }

    private struct Scope {
        var symbols: [String: Symbol] = [:]
        /// `precision … float;` was said in this scope.
        var floatPrecision = false
    }

    let stage: GLShaderStage
    let derivatives: Bool
    /// The language's own names, then the shader's globals, then a scope
    /// for each block being read.
    private var scopes: [Scope] = [Scope(), Scope()]
    private var structs: [GLSLStruct] = []
    private var globals: [GLSLVariable] = []
    private var functions: [GLSLFunction] = []
    private var builtins: [GLSLBuiltinVariable: GLSLVariable] = [:]
    private var function: GLSLFunction?
    private var nodes = 0
    private var ids = 0
    private var arrayElements = 0
    private var depthRange: GLSLStruct?
    private var depthRangeNamed = false

    init(stage: GLShaderStage, derivatives: Bool) {
        self.stage = stage
        self.derivatives = derivatives
        func builtin(_ name: String, _ type: GLSLType, _ which: GLSLBuiltinVariable, readOnly: Bool = false,
                     value: GLSLValue? = nil) {
            let variable = GLSLVariable(name: name, type: type, kind: .builtin(which), id: nextID(), line: 0)
            variable.readOnly = readOnly
            variable.value = value
            variable.isConst = value != nil
            scopes[0].symbols[name] = .variable(variable)
            if which != .constant { builtins[which] = variable }
        }
        if stage == .vertex {
            builtin("gl_Position", .vec(4), .position)
            builtin("gl_PointSize", .float, .pointSize)
        } else {
            builtin("gl_FragCoord", .vec(4), .fragCoord, readOnly: true)
            builtin("gl_FrontFacing", .bool, .frontFacing, readOnly: true)
            builtin("gl_PointCoord", .vec(2), .pointCoord, readOnly: true)
            builtin("gl_FragColor", .vec(4), .fragColor)
            builtin("gl_FragData", .array(.vec(4), 1), .fragData)
        }
        let limits: [(String, Int)] = [
            ("gl_MaxVertexAttribs", GLSLLimits.attributes),
            ("gl_MaxVertexUniformVectors", GLSLLimits.uniformVectors),
            ("gl_MaxVaryingVectors", GLSLLimits.varyingVectors),
            ("gl_MaxVertexTextureImageUnits", GLSLLimits.textureUnits),
            ("gl_MaxCombinedTextureImageUnits", GLSLLimits.textureUnits),
            ("gl_MaxTextureImageUnits", GLSLLimits.textureUnits),
            ("gl_MaxFragmentUniformVectors", GLSLLimits.uniformVectors),
            ("gl_MaxDrawBuffers", 1),
        ]
        for (name, value) in limits {
            builtin(name, .int, .constant, readOnly: true, value: .int([Int32(value)]))
        }
        // gl_DepthRange is what glDepthRangef said. Nothing tells the
        // shader here, so it is the range OpenGL starts with.
        let range = GLSLStruct(name: "gl_DepthRangeParameters", id: nextID(),
                               fields: [("near", .float), ("far", .float), ("diff", .float)])
        depthRange = range
        scopes[0].symbols[range.name] = .structure(range)
        builtin("gl_DepthRange", .structure(range), .constant, readOnly: true,
                value: .structure([.float([0]), .float([1]), .float([1])]))
        // A vertex shader's floats are highp unless it says otherwise; a
        // fragment shader has to say.
        scopes[1].floatPrecision = stage == .vertex
    }

    private func nextID() -> Int {
        ids += 1
        return ids
    }

    // MARK: Scopes and declarations

    func pushScope() {
        scopes.append(Scope())
    }

    func popScope() {
        if scopes.count > 2 { scopes.removeLast() }
    }

    private var isGlobal: Bool { scopes.count == 2 }

    func lookup(_ name: String) -> Symbol? {
        for scope in scopes.reversed() {
            if let symbol = scope.symbols[name] { return symbol }
        }
        return nil
    }

    /// The struct a name stands for here, if it stands for one.
    func structure(named name: String) -> GLSLStruct? {
        guard case .structure(let found)? = lookup(name) else { return nil }
        if found === depthRange { depthRangeNamed = true }
        return found
    }

    /// One more piece of the tree; there is a most of them.
    func count(line: Int) throws {
        nodes += 1
        guard nodes <= GLSLLimits.nodes else {
            throw GLSLError(line: line, message: "the shader has more than \(GLSLLimits.nodes) statements and expressions")
        }
    }

    private func checkName(_ name: String, line: Int) throws {
        guard !name.hasPrefix("gl_") else {
            throw GLSLError(line: line, message: "'\(name)': names that begin with gl_ are the language's own")
        }
        guard scopes[scopes.count - 1].symbols[name] == nil else {
            throw GLSLError(line: line, message: "'\(name)' is already declared in this scope")
        }
    }

    func setPrecision(_ type: GLSLType, line: Int) throws {
        switch type {
        case .float: scopes[scopes.count - 1].floatPrecision = true
        case .int, .sampler2D, .samplerCube: break
        default: throw GLSLError(line: line, message: "a default precision is for float, int or a sampler type, not \(type.name)")
        }
    }

    /// A float declared with no precision of its own needs a default one,
    /// which a fragment shader does not have until it says so.
    func requirePrecision(_ type: GLSLType, qualified: Bool, line: Int) throws {
        var element = type
        if case .array(let inner, _) = type { element = inner }
        guard !qualified, element.base == .float, !scopes.contains(where: \.floatPrecision) else { return }
        throw GLSLError(line: line, message: "no precision is given for float: a fragment shader has no default (say 'precision mediump float;')")
    }

    func declareStruct(name: String, fields: [(name: String, type: GLSLType)], line: Int) throws -> GLSLStruct {
        if !name.isEmpty { try checkName(name, line: line) }
        guard structs.count < GLSLLimits.structs else {
            throw GLSLError(line: line, message: "the shader declares more than \(GLSLLimits.structs) structs")
        }
        var seen = Set<String>()
        for field in fields {
            guard seen.insert(field.name).inserted else {
                throw GLSLError(line: line, message: "the struct has two fields named '\(field.name)'")
            }
            guard field.type != .void else { throw GLSLError(line: line, message: "field '\(field.name)' is void") }
        }
        let made = GLSLStruct(name: name, id: nextID(), fields: fields)
        guard made.depth <= GLSLLimits.structDepth else {
            throw GLSLError(line: line, message: "structs are nested deeper than \(GLSLLimits.structDepth)")
        }
        guard made.scalars <= GLSLLimits.typeScalars, made.arrayElements <= GLSLLimits.arrayElements else {
            throw GLSLError(line: line, message: "the struct is too large")
        }
        structs.append(made)
        if !name.isEmpty { scopes[scopes.count - 1].symbols[name] = .structure(made) }
        return made
    }

    /// A variable with its rules checked, not yet in any scope.
    private func makeVariable(name: String, type: GLSLType, kind: GLSLVariable.Kind, line: Int) throws -> GLSLVariable {
        var element = type
        if case .array(let inner, _) = type { element = inner }
        guard element != .void else {
            throw GLSLError(line: line, message: "'\(name)' cannot be void")
        }
        guard type.scalars <= GLSLLimits.typeScalars else {
            throw GLSLError(line: line, message: "'\(name)' is too large")
        }
        arrayElements += type.arrayElements
        guard arrayElements <= GLSLLimits.arrayElements else {
            throw GLSLError(line: line, message: "the shader's arrays have more than \(GLSLLimits.arrayElements) elements together")
        }
        try count(line: line)
        return GLSLVariable(name: name, type: type, kind: kind, id: nextID(), line: line)
    }

    func declareVariable(name: String, type: GLSLType, kind: GLSLVariable.Kind, isConst: Bool,
                         initializer: GLSLExpr?, line: Int) throws -> GLSLVariable {
        try checkName(name, line: line)
        var element = type
        if case .array(let inner, _) = type { element = inner }
        switch kind {
        case .uniform:
            break
        case .attribute:
            guard stage == .vertex else {
                throw GLSLError(line: line, message: "attribute '\(name)': only a vertex shader has attributes")
            }
            guard type.base == .float else {
                throw GLSLError(line: line, message: "attribute '\(name)' must be a float, a vector of floats or a matrix, not \(type.name)")
            }
        case .varying:
            guard element.base == .float else {
                throw GLSLError(line: line, message: "varying '\(name)' must be made of floats (float, vec, mat, or an array of them), not \(type.name)")
            }
        default:
            guard !type.hasSampler else {
                throw GLSLError(line: line, message: "'\(name)': a sampler can only be a uniform or a function's parameter")
            }
        }
        if kind == .uniform || kind == .attribute || kind == .varying {
            guard isGlobal else {
                throw GLSLError(line: line, message: "'\(name)': uniforms, attributes and varyings are declared outside functions")
            }
            guard initializer == nil else {
                throw GLSLError(line: line, message: "'\(name)' cannot be given a value where it is declared")
            }
            guard globals.count < GLSLLimits.globals else {
                throw GLSLError(line: line, message: "the shader declares more than \(GLSLLimits.globals) global variables")
            }
        }
        if let initializer {
            // An array has no value to be given, and GLSL ES 1.00 lets a
            // struct with an array in it be neither assigned nor given one.
            guard !type.hasArray else {
                throw GLSLError(line: line, message: "'\(name)' is or holds an array and cannot be given a value where it is declared")
            }
            guard initializer.type == type else {
                throw GLSLError(line: line, message: "'\(name)' is \(type.name) and cannot be given a value that is \(initializer.type.name)")
            }
            guard !(isConst || isGlobal) || initializer.constant else {
                throw GLSLError(line: line, message: "the value '\(name)' is declared with must be a constant expression")
            }
        } else if isConst {
            throw GLSLError(line: line, message: "const '\(name)' must be given a value where it is declared")
        }
        let variable = try makeVariable(name: name, type: type, kind: kind, line: line)
        variable.isConst = isConst
        variable.readOnly = isConst || kind == .uniform || kind == .attribute || (kind == .varying && stage == .fragment)
        if isConst { variable.value = initializer?.value }
        if isGlobal {
            guard globals.count < GLSLLimits.globals else {
                throw GLSLError(line: line, message: "the shader declares more than \(GLSLLimits.globals) global variables")
            }
            variable.initializer = initializer
            globals.append(variable)
        }
        scopes[scopes.count - 1].symbols[name] = .variable(variable)
        return variable
    }

    func parameter(name: String, type: GLSLType, direction: GLSLVariable.Direction, isConst: Bool, line: Int) throws -> GLSLVariable {
        guard !(isConst && direction != .input) else {
            throw GLSLError(line: line, message: "a const parameter cannot be out or inout")
        }
        guard !(type.hasSampler && direction != .input) else {
            throw GLSLError(line: line, message: "a sampler cannot be an out or inout parameter")
        }
        guard !name.hasPrefix("gl_") else {
            throw GLSLError(line: line, message: "'\(name)': names that begin with gl_ are the language's own")
        }
        let variable = try makeVariable(name: name, type: type, kind: .parameter, line: line)
        variable.direction = direction
        variable.readOnly = isConst
        return variable
    }

    /// `invariant name;`: the name must be something a stage puts out.
    func invariant(_ name: String, line: Int) throws {
        guard case .variable(let variable)? = lookup(name) else {
            throw GLSLError(line: line, message: "'\(name)' is not declared, so it cannot be made invariant")
        }
        switch variable.kind {
        case .varying, .builtin: break
        default: throw GLSLError(line: line, message: "'\(name)' is not a varying, so it cannot be made invariant")
        }
    }

    func declareFunction(name: String, result: GLSLType, parameters: [GLSLVariable], line: Int, defining: Bool) throws -> GLSLFunction {
        guard !name.hasPrefix("gl_") else {
            throw GLSLError(line: line, message: "'\(name)': names that begin with gl_ are the language's own")
        }
        guard !result.isArray, !result.hasSampler else {
            throw GLSLError(line: line, message: "function '\(name)' cannot return \(result.name)")
        }
        let types = parameters.map(\.type)
        if name == "main" {
            guard result == .void, parameters.isEmpty else {
                throw GLSLError(line: line, message: "main must be 'void main()'")
            }
        }
        if let builtin = GLSLBuiltin(rawValue: name), builtin.result(types, stage: stage, derivatives: true) != nil {
            throw GLSLError(line: line, message: "'\(name)' with these parameters is a built-in function and cannot be declared again")
        }
        var overloads: [GLSLFunction] = []
        switch scopes[1].symbols[name] {
        case .functions(let existing)?: overloads = existing
        case nil: break
        default: throw GLSLError(line: line, message: "'\(name)' is already declared and is not a function")
        }
        if let known = overloads.first(where: { $0.parameters.map(\.type) == types }) {
            guard known.result == result, known.parameters.map(\.direction) == parameters.map(\.direction) else {
                throw GLSLError(line: line, message: "function '\(name)' was declared before with another return type or other parameter qualifiers")
            }
            if defining {
                guard !known.defined else { throw GLSLError(line: line, message: "function '\(name)' already has a body") }
                known.parameters = parameters
                known.defined = true
            }
            return known
        }
        guard functions.count < GLSLLimits.functions, overloads.count < GLSLLimits.overloads else {
            throw GLSLError(line: line, message: "the shader declares too many functions")
        }
        let made = GLSLFunction(name: name, id: nextID(), result: result, parameters: parameters, line: line)
        made.defined = defining
        functions.append(made)
        overloads.append(made)
        scopes[1].symbols[name] = .functions(overloads)
        return made
    }

    /// The body of a function begins: its parameters are its first names.
    func beginFunction(_ function: GLSLFunction, line: Int) throws {
        self.function = function
        pushScope()
        for parameter in function.parameters where !parameter.name.isEmpty {
            guard scopes[scopes.count - 1].symbols[parameter.name] == nil else {
                throw GLSLError(line: line, message: "two parameters are named '\(parameter.name)'")
            }
            scopes[scopes.count - 1].symbols[parameter.name] = .variable(parameter)
        }
    }

    func endFunction() {
        popScope()
        function = nil
    }

    func checkReturn(_ value: GLSLExpr?, line: Int) throws {
        let expected = function?.result ?? .void
        let given = value?.type ?? .void
        let name = function?.name ?? ""
        // Not even the call of another void function: return takes no
        // expression in a function that returns nothing.
        guard expected != .void || value == nil else {
            throw GLSLError(line: line, message: "function '\(name)' is void and cannot return a value")
        }
        guard expected == given else {
            throw GLSLError(line: line, message: "function '\(name)' returns \(expected.name), not \(given.name)")
        }
    }

    /// The whole shader was read: what only shows then is checked, and
    /// the shader is handed over.
    func finish(line: Int) throws -> GLSLShader {
        for function in functions where function.called && !function.defined {
            throw GLSLError(line: function.line, message: "function '\(function.name)' is called but has no body")
        }
        // The language has no recursion: a function that reaches itself
        // through what it calls is an error. The walk keeps its own stack,
        // since a chain of calls is as long as a shader makes it.
        var state: [Int: Int] = [:]
        for root in functions where state[root.id] == nil {
            var stack: [(function: GLSLFunction, callees: [GLSLFunction], next: Int)] = [(root, Array(root.callees.values), 0)]
            state[root.id] = 1
            while var top = stack.popLast() {
                guard top.next < top.callees.count else {
                    state[top.function.id] = 2
                    continue
                }
                let callee = top.callees[top.next]
                top.next += 1
                stack.append(top)
                if state[callee.id] == 1 {
                    throw GLSLError(line: callee.line, message: "function '\(callee.name)' calls itself, directly or through others: recursion is not allowed")
                }
                if state[callee.id] == nil {
                    state[callee.id] = 1
                    stack.append((callee, Array(callee.callees.values), 0))
                }
            }
        }
        if let color = builtins[.fragColor], let data = builtins[.fragData], color.written, data.written {
            throw GLSLError(line: line, message: "a shader writes gl_FragColor or gl_FragData, not both")
        }
        var main: GLSLFunction?
        if case .functions(let overloads)? = scopes[1].symbols["main"] {
            main = overloads.first { $0.defined }
        }
        // The struct of gl_DepthRange is written to Metal only for a
        // shader that names it or the variable.
        if let range = depthRange, case .variable(let variable)? = scopes[0].symbols["gl_DepthRange"],
           variable.used || depthRangeNamed {
            structs.insert(range, at: 0)
        }
        return GLSLShader(stage: stage, structs: structs, globals: globals, functions: functions, main: main, builtins: builtins)
    }

    // MARK: Expressions

    private func node(_ kind: GLSLExpr.Kind, _ type: GLSLType, _ line: Int, value: GLSLValue? = nil,
                      constant: Bool = false, effects: Bool = false, _ parts: [GLSLExpr]) throws -> GLSLExpr {
        try count(line: line)
        var height = 1
        var changes = effects
        for part in parts {
            height = max(height, part.height + 1)
            changes = changes || part.effects
        }
        guard height <= GLSLLimits.nesting else {
            throw GLSLError(line: line, message: "an expression is nested deeper than \(GLSLLimits.nesting)")
        }
        return GLSLExpr(kind: kind, type: type, line: line, value: value, constant: constant || value != nil,
                        effects: changes, height: height)
    }

    func literal(_ value: GLSLValue, _ type: GLSLType, line: Int) throws -> GLSLExpr {
        try node(.literal, type, line, value: value, [])
    }

    func reference(_ name: String, line: Int) throws -> GLSLExpr {
        guard let symbol = lookup(name) else {
            throw GLSLError(line: line, message: "'\(name)' is not declared")
        }
        guard case .variable(let variable) = symbol else {
            throw GLSLError(line: line, message: "'\(name)' is not a variable")
        }
        variable.used = true
        return try node(.variable(variable), variable.type, line, value: variable.value, constant: variable.isConst, [])
    }

    func field(_ base: GLSLExpr, _ name: String, line: Int) throws -> GLSLExpr {
        if case .structure(let type) = base.type {
            guard let index = type.fields.firstIndex(where: { $0.name == name }) else {
                throw GLSLError(line: line, message: "\(type.name) has no field '\(name)'")
            }
            var value: GLSLValue?
            if case .structure(let values)? = base.value, index < values.count { value = values[index] }
            return try node(.field(base, index), type.fields[index].type, line, value: value, constant: base.constant, [base])
        }
        guard base.type.isVector, let element = base.type.base else {
            throw GLSLError(line: line, message: "\(base.type.name) has no fields (.\(name))")
        }
        // xyzw, rgba and stpq name the same four components; one swizzle
        // takes its letters from one of the sets.
        let letters = Array(name.utf8)
        var components: [Int] = []
        for set in ["xyzw", "rgba", "stpq"] {
            let positions = letters.map { Array(set.utf8).firstIndex(of: $0) }
            if !positions.contains(nil) {
                components = positions.compactMap { $0 }
                break
            }
        }
        guard !components.isEmpty, components.count == letters.count, components.count <= 4 else {
            throw GLSLError(line: line, message: "'.\(name)' does not name components of a vector (xyzw, rgba or stpq, at most four)")
        }
        guard !components.contains(where: { $0 >= base.type.size }) else {
            throw GLSLError(line: line, message: "'.\(name)' names a component \(base.type.name) does not have")
        }
        // A swizzle of a swizzle is one swizzle of the vector under both.
        var source = base
        if case .swizzle(let inner, let first) = base.kind, first.count > 1 {
            source = inner
            components = components.map { first[$0] }
        }
        return try node(.swizzle(source, components), .vector(element, components.count), line,
                        value: source.value?.picking(components), constant: source.constant, [source])
    }

    func index(_ base: GLSLExpr, _ index: GLSLExpr, line: Int) throws -> GLSLExpr {
        guard index.type == .int else {
            throw GLSLError(line: line, message: "an index must be an int, not \(index.type.name)")
        }
        let type: GLSLType
        let count: Int
        switch base.type {
        case .array(let element, let length):
            type = element
            count = length
        case .vec(let n), .ivec(let n), .bvec(let n):
            type = base.type.base ?? .float
            count = n
        case .mat(let n):
            type = .vec(n)
            count = n
        default:
            throw GLSLError(line: line, message: "\(base.type.name) cannot be indexed")
        }
        var value: GLSLValue?
        if case .int(let at)? = index.value, let position = at.first {
            guard position >= 0, Int(position) < count else {
                throw GLSLError(line: line, message: "index \(position) is outside 0…\(count - 1)")
            }
            let k = Int(position)
            if base.type.isVector {
                // An index into a swizzle is the component it picks.
                if case .swizzle(let inner, let components) = base.kind, components.count > 1 {
                    return try node(.swizzle(inner, [components[k]]), type, line, value: inner.value?.picking([components[k]]),
                                    constant: inner.constant, [inner])
                }
                value = base.value?.picking([k])
            } else if base.type.isMatrix {
                value = base.value?.picking(Array((k * count)..<(k * count + count)))
            }
        }
        return try node(.index(base, index), type, line, value: value, constant: base.constant && index.constant, [base, index])
    }

    /// The variable an expression is a part of must be one that may be
    /// written; it is marked as written.
    func requireLValue(_ expression: GLSLExpr, line: Int) throws {
        var current = expression
        while true {
            switch current.kind {
            case .variable(let variable):
                guard !variable.readOnly else {
                    let what: String
                    switch variable.kind {
                    case .uniform: what = "a uniform"
                    case .attribute: what = "an attribute"
                    case .varying: what = "a varying, which a fragment shader only reads"
                    case .builtin: what = "read-only"
                    default: what = "const"
                    }
                    throw GLSLError(line: line, message: "'\(variable.name)' cannot be written to: it is \(what)")
                }
                variable.written = true
                return
            case .field(let base, _):
                current = base
            case .index(let base, _):
                if case .swizzle = base.kind {
                    throw GLSLError(line: line, message: "a component of a swizzle picked by a variable index cannot be written to")
                }
                current = base
            case .swizzle(let base, let components):
                guard Set(components).count == components.count else {
                    throw GLSLError(line: line, message: "a swizzle that names a component twice cannot be written to")
                }
                current = base
            default:
                throw GLSLError(line: line, message: "this expression cannot be written to (it is no l-value)")
            }
        }
    }

    func requireBool(_ expression: GLSLExpr, line: Int) throws {
        guard expression.type == .bool else {
            throw GLSLError(line: line, message: "a condition must be a bool, not \(expression.type.name)")
        }
    }

    /// +x is x's value and nothing that can be written to: the same as a
    /// constructor of x's type given x.
    func plus(_ operand: GLSLExpr, line: Int) throws -> GLSLExpr {
        guard let base = operand.type.base, base != .bool else {
            throw GLSLError(line: line, message: "unary + does not take \(operand.type.name)")
        }
        return try construct(operand.type, [operand], line: line)
    }

    func negate(_ operand: GLSLExpr, line: Int) throws -> GLSLExpr {
        guard let base = operand.type.base, base != .bool else {
            throw GLSLError(line: line, message: "unary - does not take \(operand.type.name)")
        }
        var value: GLSLValue?
        switch operand.value {
        case .float(let v)?: value = .float(v.map { -$0 })
        case .int(let v)?: value = .int(v.map { 0 &- $0 })
        default: break
        }
        return try node(.negate(operand), operand.type, line, value: value, constant: operand.constant, [operand])
    }

    func not(_ operand: GLSLExpr, line: Int) throws -> GLSLExpr {
        guard operand.type == .bool else {
            throw GLSLError(line: line, message: "! takes a bool, not \(operand.type.name)")
        }
        var value: GLSLValue?
        if case .bool(let v)? = operand.value { value = .bool(v.map { !$0 }) }
        return try node(.not(operand), .bool, line, value: value, constant: operand.constant, [operand])
    }

    func step(_ operand: GLSLExpr, increment: Bool, prefix: Bool, line: Int) throws -> GLSLExpr {
        guard let base = operand.type.base, base != .bool else {
            throw GLSLError(line: line, message: "\(increment ? "++" : "--") does not take \(operand.type.name)")
        }
        try requireLValue(operand, line: line)
        return try node(.step(operand, increment: increment, prefix: prefix), operand.type, line, effects: true, [operand])
    }

    /// The type of `left op right` for + - * /, or nil when the language
    /// has no such operation. Both sides are made of the same thing (int
    /// or float); a scalar goes with anything, a vector with a vector of
    /// its size, a matrix with a matrix of its size, and * alone joins a
    /// vector and a matrix, as linear algebra does.
    private func arithmetic(_ op: GLSLBinaryOperator, _ left: GLSLType, _ right: GLSLType) -> GLSLType? {
        guard let base = left.base, base == right.base, base != .bool else { return nil }
        if left.isScalar { return right }
        if right.isScalar { return left }
        if left == right { return left }
        if op == .multiply, left.size == right.size {
            if left.isMatrix, right.isVector { return right }
            if left.isVector, right.isMatrix { return left }
        }
        return nil
    }

    private func foldArithmetic(_ op: GLSLBinaryOperator, _ left: GLSLExpr, _ right: GLSLExpr, _ type: GLSLType) -> GLSLValue? {
        guard let a = left.value, let b = right.value else { return nil }
        func pick<T>(_ list: [T], _ i: Int, _ zero: T) -> T {
            list.count == 1 ? list[0] : (i < list.count ? list[i] : zero)
        }
        if case .int(let x) = a, case .int(let y) = b {
            var out: [Int32] = []
            for i in 0..<max(x.count, y.count) {
                let p = pick(x, i, 0), q = pick(y, i, 0)
                switch op {
                case .add: out.append(p &+ q)
                case .subtract: out.append(p &- q)
                case .multiply: out.append(p &* q)
                default:
                    // What a division by zero gives is left to Metal,
                    // where it is made to give 0.
                    guard q != 0, !(p == Int32.min && q == -1) else { return nil }
                    out.append(p / q)
                }
            }
            return .int(out)
        }
        guard case .float(let x) = a, case .float(let y) = b else { return nil }
        let n = type.size
        if op == .multiply, !left.type.isScalar, !right.type.isScalar, left.type.isMatrix || right.type.isMatrix {
            guard x.count >= (left.type.isMatrix ? n * n : n), y.count >= (right.type.isMatrix ? n * n : n) else { return nil }
            var out: [Float] = []
            if left.type.isMatrix, right.type.isMatrix {
                for column in 0..<n {
                    for row in 0..<n {
                        out.append((0..<n).reduce(Float(0)) { $0 + x[$1 * n + row] * y[column * n + $1] })
                    }
                }
            } else if left.type.isMatrix {
                for row in 0..<n {
                    out.append((0..<n).reduce(Float(0)) { $0 + x[$1 * n + row] * y[$1] })
                }
            } else {
                for column in 0..<n {
                    out.append((0..<n).reduce(Float(0)) { $0 + x[$1] * y[column * n + $1] })
                }
            }
            return .float(out)
        }
        var out: [Float] = []
        for i in 0..<max(x.count, y.count) {
            let p = pick(x, i, 0), q = pick(y, i, 0)
            switch op {
            case .add: out.append(p + q)
            case .subtract: out.append(p - q)
            case .multiply: out.append(p * q)
            default: out.append(p / q)
            }
        }
        return .float(out)
    }

    func binary(_ op: GLSLBinaryOperator, _ left: GLSLExpr, _ right: GLSLExpr, line: Int) throws -> GLSLExpr {
        let constant = left.constant && right.constant
        func mismatch() -> GLSLError {
            GLSLError(line: line, message: "\(op.symbol) does not take \(left.type.name) and \(right.type.name)")
        }
        switch op {
        case .add, .subtract, .multiply, .divide:
            guard let type = arithmetic(op, left.type, right.type) else { throw mismatch() }
            return try node(.binary(op, left, right), type, line, value: foldArithmetic(op, left, right, type),
                            constant: constant, [left, right])
        case .less, .greater, .lessEqual, .greaterEqual:
            guard left.type == right.type, left.type == .int || left.type == .float else { throw mismatch() }
            var value: GLSLValue?
            if let a = left.value, let b = right.value, a.count == 1, b.count == 1 {
                let x = a.floats[0], y = b.floats[0]
                let holds: Bool
                if case .int(let p) = a, case .int(let q) = b {
                    holds = op == .less ? p[0] < q[0] : op == .greater ? p[0] > q[0] : op == .lessEqual ? p[0] <= q[0] : p[0] >= q[0]
                } else {
                    holds = op == .less ? x < y : op == .greater ? x > y : op == .lessEqual ? x <= y : x >= y
                }
                value = .bool([holds])
            }
            return try node(.binary(op, left, right), .bool, line, value: value, constant: constant, [left, right])
        case .equal, .notEqual:
            guard left.type == right.type, left.type != .void, !left.type.hasArray, !left.type.hasSampler else { throw mismatch() }
            var value: GLSLValue?
            if let a = left.value, let b = right.value { value = .bool([(a == b) == (op == .equal)]) }
            return try node(.binary(op, left, right), .bool, line, value: value, constant: constant, [left, right])
        case .and, .or, .xor:
            guard left.type == .bool, right.type == .bool else { throw mismatch() }
            var value: GLSLValue?
            if case .bool(let a)? = left.value, case .bool(let b)? = right.value, a.count == 1, b.count == 1 {
                value = .bool([op == .and ? a[0] && b[0] : op == .or ? a[0] || b[0] : a[0] != b[0]])
            }
            return try node(.binary(op, left, right), .bool, line, value: value, constant: constant, [left, right])
        }
    }

    func assign(_ op: GLSLBinaryOperator?, _ target: GLSLExpr, _ value: GLSLExpr, line: Int) throws -> GLSLExpr {
        if let op {
            guard arithmetic(op, target.type, value.type) == target.type else {
                throw GLSLError(line: line, message: "\(op.symbol)= does not take \(target.type.name) and \(value.type.name)")
            }
        } else {
            guard target.type == value.type else {
                throw GLSLError(line: line, message: "\(target.type.name) cannot be given a value that is \(value.type.name)")
            }
            guard !target.type.hasArray, !target.type.hasSampler, target.type != .void else {
                throw GLSLError(line: line, message: "\(target.type.name) cannot be assigned")
            }
        }
        try requireLValue(target, line: line)
        return try node(.assign(op, target, value), target.type, line, effects: true, [target, value])
    }

    func conditional(_ condition: GLSLExpr, _ first: GLSLExpr, _ second: GLSLExpr, line: Int) throws -> GLSLExpr {
        guard condition.type == .bool else {
            throw GLSLError(line: line, message: "the condition of ?: must be a bool, not \(condition.type.name)")
        }
        guard first.type == second.type, first.type != .void, !first.type.hasArray, !first.type.hasSampler else {
            throw GLSLError(line: line, message: "?: does not take \(first.type.name) and \(second.type.name)")
        }
        var value: GLSLValue?
        if case .bool(let chosen)? = condition.value, chosen.count == 1, let a = first.value, let b = second.value {
            value = chosen[0] ? a : b
        }
        return try node(.conditional(condition, first, second), first.type, line, value: value,
                        constant: condition.constant && first.constant && second.constant, [condition, first, second])
    }

    func sequence(_ first: GLSLExpr, _ second: GLSLExpr, line: Int) throws -> GLSLExpr {
        try node(.sequence(first, second), second.type, line, [first, second])
    }

    func construct(_ type: GLSLType, _ arguments: [GLSLExpr], line: Int) throws -> GLSLExpr {
        let constant = arguments.allSatisfy(\.constant)
        if case .structure(let made) = type {
            guard !type.hasSampler else {
                throw GLSLError(line: line, message: "\(type.name) holds a sampler and cannot be constructed")
            }
            guard arguments.count == made.fields.count else {
                throw GLSLError(line: line, message: "the constructor of \(type.name) takes \(made.fields.count) arguments, one for each field")
            }
            for (field, argument) in zip(made.fields, arguments) where field.type != argument.type {
                throw GLSLError(line: line, message: "field '\(field.name)' of \(type.name) is \(field.type.name), not \(argument.type.name)")
            }
            let values = arguments.compactMap(\.value)
            return try node(.construct(arguments), type, line, value: values.count == arguments.count ? .structure(values) : nil,
                            constant: constant, arguments)
        }
        guard let base = type.base else {
            throw GLSLError(line: line, message: "\(type.name) cannot be constructed")
        }
        guard let first = arguments.first else {
            throw GLSLError(line: line, message: "the constructor of \(type.name) needs arguments")
        }
        for argument in arguments where argument.type.base == nil {
            throw GLSLError(line: line, message: "a constructor of \(type.name) takes scalars, vectors and matrices, not \(argument.type.name)")
        }
        let needed = type.components
        let values = arguments.compactMap(\.value)
        let all: GLSLValue? = values.count == arguments.count
            ? GLSLValue.of(base, floats: []).joined(values.map { $0.converted(to: base) }) : nil
        var value: GLSLValue?
        if type.isScalar {
            guard arguments.count == 1 else {
                throw GLSLError(line: line, message: "the constructor of \(type.name) takes one argument")
            }
            value = all?.picking([0])
        } else if arguments.count == 1, first.type.isScalar {
            // One scalar: every component of a vector, the diagonal of a matrix.
            if type.isMatrix {
                let n = type.size
                value = all.map { one in .float((0..<(n * n)).map { $0 % (n + 1) == 0 ? one.floats.first ?? 0 : 0 }) }
            } else {
                value = all?.picking(Array(repeating: 0, count: needed))
            }
        } else if arguments.count == 1, type.isMatrix, first.type.isMatrix {
            // A matrix of a matrix: what both have, and the identity for
            // the rest. GLSL ES 1.00 keeps this for later versions, but
            // every implementation takes mat3(mat4), and shaders use it.
            let n = type.size, m = first.type.size
            value = all.map { from in
                let numbers = from.floats
                return .float((0..<(n * n)).map { i in
                    let column = i / n, row = i % n
                    if column < m, row < m, column * m + row < numbers.count { return numbers[column * m + row] }
                    return column == row ? 1 : 0
                })
            }
        } else {
            var have = 0
            for argument in arguments {
                guard !(type.isMatrix && argument.type.isMatrix) else {
                    throw GLSLError(line: line, message: "a matrix is not constructed of a matrix and other values")
                }
                guard have < needed else {
                    throw GLSLError(line: line, message: "the constructor of \(type.name) is given more arguments than it uses")
                }
                have += argument.type.components
            }
            guard have >= needed else {
                throw GLSLError(line: line, message: "the constructor of \(type.name) needs \(needed) components and is given \(have)")
            }
            value = all?.picking(Array(0..<needed))
        }
        return try node(.construct(arguments), type, line, value: value, constant: constant, arguments)
    }

    func call(_ name: String, _ arguments: [GLSLExpr], line: Int) throws -> GLSLExpr {
        for argument in arguments where argument.type == .void {
            throw GLSLError(line: line, message: "an argument of '\(name)' is void")
        }
        let types = arguments.map(\.type)
        switch lookup(name) {
        case .functions(let overloads)?:
            if let found = overloads.first(where: { $0.parameters.count == types.count && $0.parameters.map(\.type) == types }) {
                for (parameter, argument) in zip(found.parameters, arguments) where parameter.direction != .input {
                    try requireLValue(argument, line: line)
                }
                found.called = true
                function?.callees[found.id] = found
                return try node(.call(found, arguments), found.result, line, effects: true, arguments)
            }
        case nil:
            break
        default:
            throw GLSLError(line: line, message: "'\(name)' is not a function")
        }
        if let builtin = GLSLBuiltin(rawValue: name), let type = builtin.result(types, stage: stage, derivatives: derivatives) {
            let values = arguments.compactMap(\.value)
            return try node(.builtin(builtin, arguments), type, line,
                            value: values.count == arguments.count ? builtin.fold(values) : nil,
                            constant: builtin.isConstant && arguments.allSatisfy(\.constant), arguments)
        }
        if let builtin = GLSLBuiltin(rawValue: name), !builtin.isConstant,
           builtin.result(types, stage: .fragment, derivatives: true) != nil || builtin.result(types, stage: .vertex, derivatives: true) != nil {
            let why = builtin == .dFdx || builtin == .dFdy || builtin == .fwidth
                ? "needs '#extension GL_OES_standard_derivatives : enable' in a fragment shader"
                : "with these arguments is not for a \(stage == .vertex ? "vertex" : "fragment") shader"
            throw GLSLError(line: line, message: "'\(name)' \(why)")
        }
        throw GLSLError(line: line, message: "no function '\(name)' takes (\(types.map(\.name).joined(separator: ", ")))")
    }
}

extension GLSLValue {
    /// The components at these places, in this order.
    func picking(_ places: [Int]) -> GLSLValue? {
        guard !places.contains(where: { $0 < 0 || $0 >= count }) else { return nil }
        switch self {
        case .float(let v): return .float(places.map { v[$0] })
        case .int(let v): return .int(places.map { v[$0] })
        case .bool(let v): return .bool(places.map { v[$0] })
        case .structure: return nil
        }
    }

    /// This value's numbers followed by the others', which are of its kind.
    func joined(_ others: [GLSLValue]) -> GLSLValue {
        switch self {
        case .float(let v): return .float(others.reduce(v) { $0 + $1.floats })
        case .int(let v): return .int(others.reduce(v) { $0 + $1.ints })
        case .bool(let v): return .bool(others.reduce(v) { $0 + $1.bools })
        case .structure: return self
        }
    }
}
