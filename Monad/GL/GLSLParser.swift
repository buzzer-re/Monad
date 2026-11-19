//
//  GLSLParser.swift — the grammar of GLSL ES 1.00: the tokens the
//  preprocessor left (GLSLLexer.swift) read as declarations, functions,
//  statements and expressions. Each piece goes to the checker as it is
//  read (GLSLChecker.swift), which is where the tree comes from: the
//  language is made to be read once, a name always declared before it is
//  used.
//
//  The text is a guest's. The parser calls itself for what is nested, so
//  it counts how deep it is and stops at `GLSLLimits.nesting`: ten
//  thousand brackets are an error in the log, not a stack that ran out.
//

import Foundation

final class GLSLParser {
    private let tokens: [GLSLToken]
    private let stage: GLShaderStage
    private let checker: GLSLChecker
    private var position = 0
    private var depth = 0
    private var loops = 0

    private static let types: [String: GLSLType] = [
        "void": .void, "bool": .bool, "int": .int, "float": .float,
        "vec2": .vec(2), "vec3": .vec(3), "vec4": .vec(4),
        "ivec2": .ivec(2), "ivec3": .ivec(3), "ivec4": .ivec(4),
        "bvec2": .bvec(2), "bvec3": .bvec(3), "bvec4": .bvec(4),
        "mat2": .mat(2), "mat3": .mat(3), "mat4": .mat(4),
        "sampler2D": .sampler2D, "samplerCube": .samplerCube,
    ]
    private static let precisions: Set<String> = ["lowp", "mediump", "highp"]
    /// Words that are never a name: the language's keywords, and the ones
    /// it keeps for later versions.
    private static let keywords: Set<String> = [
        "attribute", "const", "uniform", "varying", "break", "continue", "do", "for", "while", "if", "else",
        "in", "out", "inout", "true", "false", "lowp", "mediump", "highp", "precision", "invariant", "discard",
        "return", "struct",
        "asm", "class", "union", "enum", "typedef", "template", "this", "packed", "goto", "switch", "default",
        "inline", "noinline", "volatile", "public", "static", "extern", "external", "interface", "flat",
        "long", "short", "double", "half", "fixed", "unsigned", "superp", "input", "output",
        "hvec2", "hvec3", "hvec4", "dvec2", "dvec3", "dvec4", "fvec2", "fvec3", "fvec4",
        "sampler1D", "sampler3D", "sampler1DShadow", "sampler2DShadow", "sampler2DRect", "sampler3DRect",
        "sampler2DRectShadow", "sizeof", "cast", "namespace", "using",
    ]
    private static let operators: [String: (GLSLBinaryOperator, Int)] = [
        "*": (.multiply, 7), "/": (.divide, 7), "+": (.add, 6), "-": (.subtract, 6),
        "<": (.less, 5), ">": (.greater, 5), "<=": (.lessEqual, 5), ">=": (.greaterEqual, 5),
        "==": (.equal, 4), "!=": (.notEqual, 4), "&&": (.and, 3), "^^": (.xor, 2), "||": (.or, 1),
    ]

    /// The shader the tokens are, checked; or the first error in them.
    static func parse(_ source: GLSLSource, stage: GLShaderStage) throws -> GLSLShader {
        for token in source.tokens {
            if case .stray(let code) = token.kind {
                throw GLSLError(line: token.line, message: "a character the language does not have (code \(code))")
            }
        }
        let parser = GLSLParser(source, stage: stage)
        while parser.token.kind != .end {
            try parser.global()
        }
        return try parser.checker.finish(line: parser.token.line)
    }

    private init(_ source: GLSLSource, stage: GLShaderStage) {
        tokens = source.tokens.isEmpty ? [GLSLToken(kind: .end, line: 1)] : source.tokens
        self.stage = stage
        checker = GLSLChecker(stage: stage, derivatives: source.derivatives)
    }

    // MARK: Tokens

    private var token: GLSLToken { tokens[position] }

    private func peek() -> GLSLToken { tokens[min(position + 1, tokens.count - 1)] }

    /// The last token is the end, and nothing goes past it.
    private func advance() {
        if position < tokens.count - 1 { position += 1 }
    }

    private func isPunct(_ mark: String) -> Bool { token.kind == .punct(mark) }
    private func isWord(_ word: String) -> Bool { token.kind == .identifier(word) }

    private func accept(_ mark: String) -> Bool {
        guard isPunct(mark) else { return false }
        advance()
        return true
    }

    private func acceptWord(_ word: String) -> Bool {
        guard isWord(word) else { return false }
        advance()
        return true
    }

    private func found() -> String {
        switch token.kind {
        case .identifier(let name): return "'\(name)'"
        case .punct(let mark): return "'\(mark)'"
        case .int, .float: return "a number"
        default: return "the end of the shader"
        }
    }

    private func fail(_ message: String) -> GLSLError {
        GLSLError(line: token.line, message: message)
    }

    private func expect(_ mark: String) throws {
        guard accept(mark) else { throw fail("'\(mark)' is expected, not \(found())") }
    }

    /// A name a shader may give something.
    private func name(_ what: String) throws -> String {
        guard case .identifier(let name) = token.kind, !Self.keywords.contains(name), Self.types[name] == nil else {
            throw fail("\(what) is expected, not \(found())")
        }
        advance()
        return name
    }

    private func enter() throws {
        depth += 1
        guard depth <= GLSLLimits.nesting else {
            throw fail("the shader is nested deeper than \(GLSLLimits.nesting) (blocks, brackets and operators inside each other)")
        }
    }

    // MARK: Types and declarations

    private struct Specifier {
        var type: GLSLType
        /// lowp, mediump or highp was written before the type.
        var qualified: Bool
    }

    private func startsType() -> Bool {
        guard case .identifier(let name) = token.kind else { return false }
        return Self.types[name] != nil || name == "struct" || Self.precisions.contains(name) || checker.structure(named: name) != nil
    }

    private func type() throws -> Specifier {
        var qualified = false
        if case .identifier(let word) = token.kind, Self.precisions.contains(word) {
            qualified = true
            advance()
        }
        guard case .identifier(let word) = token.kind else { throw fail("a type is expected, not \(found())") }
        if let type = Self.types[word] {
            advance()
            return Specifier(type: type, qualified: qualified)
        }
        if word == "struct" {
            advance()
            return Specifier(type: .structure(try structure()), qualified: qualified)
        }
        if let known = checker.structure(named: word) {
            advance()
            return Specifier(type: .structure(known), qualified: qualified)
        }
        throw fail("a type is expected, not \(found())")
    }

    /// After `struct`: a name or none, and the fields in braces.
    private func structure() throws -> GLSLStruct {
        let line = token.line
        let named = isPunct("{") ? "" : try name("a struct's name")
        try expect("{")
        var fields: [(name: String, type: GLSLType)] = []
        repeat {
            guard !isWord("struct") else { throw fail("a struct is not declared inside another struct") }
            let fieldLine = token.line
            let specifier = try type()
            repeat {
                guard fields.count < GLSLLimits.fields else { throw fail("a struct has more than \(GLSLLimits.fields) fields") }
                let field = try name("a field's name")
                let fieldType = try arrayed(specifier.type)
                try checker.requirePrecision(fieldType, qualified: specifier.qualified, line: fieldLine)
                fields.append((field, fieldType))
            } while accept(",")
            try expect(";")
        } while !isPunct("}")
        advance()
        return try checker.declareStruct(name: named, fields: fields, line: line)
    }

    /// The type, or an array of it when `[size]` follows a name.
    private func arrayed(_ element: GLSLType) throws -> GLSLType {
        guard accept("[") else { return element }
        try enter()
        defer { depth -= 1 }
        let line = token.line
        let size = try conditional()
        try expect("]")
        guard size.type == .int, let count = size.value?.ints.first else {
            throw GLSLError(line: line, message: "an array's size must be a constant int expression")
        }
        guard count > 0, Int(count) <= GLSLLimits.arrayElements else {
            throw GLSLError(line: line, message: "an array's size must be from 1 to \(GLSLLimits.arrayElements), not \(count)")
        }
        return .array(element, Int(count))
    }

    /// `precision` was read: the qualifier, the type and the semicolon.
    private func precision() throws {
        let line = token.line
        guard case .identifier(let word) = token.kind, Self.precisions.contains(word) else {
            throw fail("lowp, mediump or highp is expected after 'precision', not \(found())")
        }
        advance()
        guard case .identifier(let named) = token.kind, let type = Self.types[named] else {
            throw fail("a type is expected, not \(found())")
        }
        advance()
        try checker.setPrecision(type, line: line)
        try expect(";")
    }

    /// One thing declared outside the functions, or a function.
    private func global() throws {
        if accept(";") { return }
        let line = token.line
        if acceptWord("precision") { return try precision() }
        if acceptWord("invariant"), !isWord("varying") {
            repeat {
                try checker.invariant(try name("a varying's name"), line: line)
            } while accept(",")
            return try expect(";")
        }
        var kind = GLSLVariable.Kind.global
        var isConst = false
        if acceptWord("const") {
            isConst = true
        } else if acceptWord("attribute") {
            kind = .attribute
        } else if acceptWord("uniform") {
            kind = .uniform
        } else if acceptWord("varying") {
            kind = .varying
        }
        let specifier = try type()
        // A struct declared and nothing else.
        if accept(";") { return }
        if kind == .global, !isConst, case .identifier = token.kind, peek().kind == .punct("(") {
            return try function(specifier, line: line)
        }
        var none: [GLSLStmt] = []
        try declarators(specifier, kind: kind, isConst: isConst, into: &none)
    }

    /// The names after a type, each with its array size and its value if
    /// it has them. A name is declared after its value was read: in
    /// `float x = x;` the second x is an older one.
    private func declarators(_ specifier: Specifier, kind: GLSLVariable.Kind, isConst: Bool, into statements: inout [GLSLStmt]) throws {
        repeat {
            let line = token.line
            let named = try name("a variable's name")
            let type = try arrayed(specifier.type)
            try checker.requirePrecision(type, qualified: specifier.qualified, line: line)
            var initializer: GLSLExpr?
            if accept("=") { initializer = try assignment() }
            let variable = try checker.declareVariable(name: named, type: type, kind: kind, isConst: isConst,
                                                       initializer: initializer, line: line)
            if kind == .local { statements.append(.declare(variable, initializer)) }
        } while accept(",")
        try expect(";")
    }

    private func function(_ result: Specifier, line: Int) throws {
        let named = try name("a function's name")
        try expect("(")
        try checker.requirePrecision(result.type, qualified: result.qualified, line: line)
        var parameters: [GLSLVariable] = []
        if isWord("void"), peek().kind == .punct(")") { advance() }
        if !isPunct(")") {
            repeat {
                guard parameters.count < GLSLLimits.parameters else {
                    throw fail("a function has more than \(GLSLLimits.parameters) parameters")
                }
                let parameterLine = token.line
                let isConst = acceptWord("const")
                var direction = GLSLVariable.Direction.input
                if acceptWord("out") {
                    direction = .output
                } else if acceptWord("inout") {
                    direction = .both
                } else {
                    _ = acceptWord("in")
                }
                let specifier = try type()
                var parameterName = ""
                if case .identifier = token.kind { parameterName = try name("a parameter's name") }
                let parameterType = try arrayed(specifier.type)
                try checker.requirePrecision(parameterType, qualified: specifier.qualified, line: parameterLine)
                parameters.append(try checker.parameter(name: parameterName, type: parameterType, direction: direction,
                                                        isConst: isConst, line: parameterLine))
            } while accept(",")
        }
        try expect(")")
        if accept(";") {
            _ = try checker.declareFunction(name: named, result: result.type, parameters: parameters, line: line, defining: false)
            return
        }
        guard isPunct("{") else { throw fail("';' or a function's body is expected, not \(found())") }
        let function = try checker.declareFunction(name: named, result: result.type, parameters: parameters, line: line, defining: true)
        try checker.beginFunction(function, line: line)
        advance()
        function.body = try block()
        checker.endFunction()
    }

    // MARK: Statements

    /// The statements up to the closing brace, which is read too.
    private func block() throws -> [GLSLStmt] {
        var statements: [GLSLStmt] = []
        while !accept("}") {
            guard token.kind != .end else { throw fail("a block is not closed") }
            try statement(into: &statements)
        }
        return statements
    }

    /// One statement in a scope of its own, as the body of an if or a
    /// loop is.
    private func scoped() throws -> [GLSLStmt] {
        checker.pushScope()
        defer { checker.popScope() }
        var statements: [GLSLStmt] = []
        try statement(into: &statements)
        return statements
    }

    private func statement(into statements: inout [GLSLStmt]) throws {
        try enter()
        defer { depth -= 1 }
        let line = token.line
        try checker.count(line: line)
        if accept(";") { return }
        if accept("{") {
            checker.pushScope()
            defer { checker.popScope() }
            statements.append(.block(try block()))
            return
        }
        guard case .identifier(let word) = token.kind else {
            return try expressionStatement(into: &statements)
        }
        switch word {
        case "if":
            advance()
            var branches: [(condition: GLSLExpr, body: [GLSLStmt])] = []
            var otherwise: [GLSLStmt]?
            while true {
                try expect("(")
                let condition = try expression()
                try checker.requireBool(condition, line: line)
                try expect(")")
                branches.append((condition, try scoped()))
                guard acceptWord("else") else { break }
                guard acceptWord("if") else {
                    otherwise = try scoped()
                    break
                }
                try checker.count(line: token.line)
            }
            statements.append(.branch(branches, otherwise: otherwise))
        case "for":
            advance()
            try expect("(")
            statements.append(.loop(try forLoop()))
        case "while":
            advance()
            try expect("(")
            checker.pushScope()
            defer { checker.popScope() }
            var setup: [GLSLStmt] = []
            let asked = try condition(into: &setup)
            try expect(")")
            statements.append(.loop(GLSLLoop(setup: setup, condition: asked, step: nil, body: try loopBody(), bodyFirst: false)))
        case "do":
            advance()
            let body = try loopBody()
            guard acceptWord("while") else { throw fail("'while' is expected after the body of do, not \(found())") }
            try expect("(")
            let condition = try expression()
            try checker.requireBool(condition, line: condition.line)
            try expect(")")
            try expect(";")
            statements.append(.loop(GLSLLoop(setup: [], condition: condition, step: nil, body: body, bodyFirst: true)))
        case "break", "continue":
            guard loops > 0 else { throw fail("'\(word)' is outside any loop") }
            advance()
            try expect(";")
            statements.append(word == "break" ? .breakLoop : .continueLoop)
        case "return":
            advance()
            let value = isPunct(";") ? nil : try expression()
            try expect(";")
            try checker.checkReturn(value, line: line)
            statements.append(.result(value))
        case "discard":
            guard stage == .fragment else { throw fail("'discard' is for fragment shaders only") }
            advance()
            try expect(";")
            statements.append(.discard)
        case "precision":
            advance()
            try precision()
        case "const":
            advance()
            try declarators(try type(), kind: .local, isConst: true, into: &statements)
        case "attribute", "uniform", "varying", "invariant":
            throw fail("'\(word)' is declared outside functions")
        default:
            if startsDeclaration() {
                let specifier = try type()
                if accept(";") { return }
                return try declarators(specifier, kind: .local, isConst: false, into: &statements)
            }
            try expressionStatement(into: &statements)
        }
    }

    private func expressionStatement(into statements: inout [GLSLStmt]) throws {
        let value = try expression()
        try expect(";")
        statements.append(.expression(value))
    }

    /// A declaration starts here and not an expression. A type's name
    /// before a bracket is a constructor, and so an expression:
    /// vec3(1.0).x;
    private func startsDeclaration() -> Bool {
        guard case .identifier(let word) = token.kind, startsType() else { return false }
        return word == "struct" || Self.precisions.contains(word) || peek().kind != .punct("(")
    }

    /// The body of a loop: break and continue in it are the loop's.
    private func loopBody() throws -> [GLSLStmt] {
        loops += 1
        defer { loops -= 1 }
        return try scoped()
    }

    /// What a for or a while asks before each round: a bool expression,
    /// or a bool variable declared with its value (while (bool more =
    /// next())), which is then a variable of the loop that is given the
    /// value each time it is asked.
    private func condition(into setup: inout [GLSLStmt]) throws -> GLSLExpr {
        let line = token.line
        let asked: GLSLExpr
        if startsDeclaration() {
            let specifier = try type()
            let named = try name("a variable's name")
            try expect("=")
            let value = try assignment()
            try checker.requirePrecision(specifier.type, qualified: specifier.qualified, line: line)
            let variable = try checker.declareVariable(name: named, type: specifier.type, kind: .local, isConst: false,
                                                       initializer: nil, line: line)
            setup.append(.declare(variable, nil))
            asked = try checker.assign(nil, try checker.reference(named, line: line), value, line: line)
        } else {
            asked = try expression()
        }
        try checker.requireBool(asked, line: line)
        return asked
    }

    /// `for (` was read. Any of its three parts may be left out; a for
    /// with no condition goes on until a break, or until the count that
    /// every loop is written to Metal with stops it.
    private func forLoop() throws -> GLSLLoop {
        checker.pushScope()
        defer { checker.popScope() }
        var setup: [GLSLStmt] = []
        if !accept(";") {
            if acceptWord("const") {
                try declarators(try type(), kind: .local, isConst: true, into: &setup)
            } else if startsDeclaration() {
                let specifier = try type()
                if !accept(";") { try declarators(specifier, kind: .local, isConst: false, into: &setup) }
            } else {
                try expressionStatement(into: &setup)
            }
        }
        let condition = isPunct(";") ? nil : try self.condition(into: &setup)
        try expect(";")
        let step = isPunct(")") ? nil : try expression()
        try expect(")")
        return GLSLLoop(setup: setup, condition: condition, step: step, body: try loopBody(), bodyFirst: false)
    }

    // MARK: Expressions

    private func expression() throws -> GLSLExpr {
        var left = try assignment()
        while isPunct(",") {
            let line = token.line
            advance()
            left = try checker.sequence(left, try assignment(), line: line)
        }
        return left
    }

    private func assignment() throws -> GLSLExpr {
        try enter()
        defer { depth -= 1 }
        let target = try conditional()
        guard case .punct(let mark) = token.kind else { return target }
        let op: GLSLBinaryOperator?
        switch mark {
        case "=": op = nil
        case "+=": op = .add
        case "-=": op = .subtract
        case "*=": op = .multiply
        case "/=": op = .divide
        case "%=", "<<=", ">>=", "&=", "|=", "^=": throw fail("'\(mark)' is kept for later versions of the language")
        default: return target
        }
        let line = token.line
        advance()
        return try checker.assign(op, target, try assignment(), line: line)
    }

    private func conditional() throws -> GLSLExpr {
        let condition = try binary()
        guard isPunct("?") else { return condition }
        let line = token.line
        advance()
        let first = try expression()
        try expect(":")
        return try checker.conditional(condition, first, try assignment(), line: line)
    }

    /// The operators with two sides, by their precedence. The operands
    /// and operators wait on two stacks, so that a long chain of them
    /// costs no depth of calls here.
    private func binary() throws -> GLSLExpr {
        var operands = [try unary()]
        var waiting: [(op: GLSLBinaryOperator, precedence: Int, line: Int)] = []
        func reduce() throws {
            guard let top = waiting.popLast(), operands.count >= 2 else { return }
            let right = operands.removeLast()
            let left = operands.removeLast()
            operands.append(try checker.binary(top.op, left, right, line: top.line))
        }
        while case .punct(let mark) = token.kind {
            if ["%", "<<", ">>", "&", "|", "^"].contains(mark) {
                throw fail("'\(mark)' is kept for later versions of the language")
            }
            guard let (op, precedence) = Self.operators[mark] else { break }
            let line = token.line
            advance()
            while let top = waiting.last, top.precedence >= precedence { try reduce() }
            waiting.append((op, precedence, line))
            operands.append(try unary())
        }
        while !waiting.isEmpty { try reduce() }
        return operands[0]
    }

    private func unary() throws -> GLSLExpr {
        guard case .punct(let mark) = token.kind, ["+", "-", "!", "++", "--", "~"].contains(mark) else {
            return try postfix()
        }
        try enter()
        defer { depth -= 1 }
        let line = token.line
        advance()
        let operand = try unary()
        switch mark {
        case "+": return try checker.plus(operand, line: line)
        case "-": return try checker.negate(operand, line: line)
        case "!": return try checker.not(operand, line: line)
        case "++": return try checker.step(operand, increment: true, prefix: true, line: line)
        case "--": return try checker.step(operand, increment: false, prefix: true, line: line)
        default: throw GLSLError(line: line, message: "'~' is kept for later versions of the language")
        }
    }

    private func postfix() throws -> GLSLExpr {
        var value = try primary()
        while true {
            let line = token.line
            if accept("[") {
                let index = try expression()
                try expect("]")
                value = try checker.index(value, index, line: line)
            } else if accept(".") {
                guard case .identifier(let field) = token.kind else { throw fail("a field's name is expected, not \(found())") }
                advance()
                guard !isPunct("(") else {
                    throw GLSLError(line: line, message: "'.\(field)()': GLSL ES 1.00 has no methods (an array's size is the constant it was declared with)")
                }
                value = try checker.field(value, field, line: line)
            } else if accept("++") {
                value = try checker.step(value, increment: true, prefix: false, line: line)
            } else if accept("--") {
                value = try checker.step(value, increment: false, prefix: false, line: line)
            } else {
                return value
            }
        }
    }

    private func primary() throws -> GLSLExpr {
        let line = token.line
        switch token.kind {
        case .int(let value):
            advance()
            return try checker.literal(.int([value]), .int, line: line)
        case .float(let value):
            advance()
            return try checker.literal(.float([value]), .float, line: line)
        case .punct("("):
            advance()
            let inner = try expression()
            try expect(")")
            return inner
        case .identifier(let word):
            if word == "true" || word == "false" {
                advance()
                return try checker.literal(.bool([word == "true"]), .bool, line: line)
            }
            if let type = Self.types[word] {
                advance()
                guard isPunct("(") else { throw fail("'(' is expected after \(word), not \(found())") }
                return try checker.construct(type, try arguments(), line: line)
            }
            guard !Self.keywords.contains(word) else { throw fail("an expression is expected, not \(found())") }
            advance()
            guard isPunct("(") else { return try checker.reference(word, line: line) }
            let given = try arguments()
            if let made = checker.structure(named: word) {
                return try checker.construct(.structure(made), given, line: line)
            }
            return try checker.call(word, given, line: line)
        default:
            throw fail("an expression is expected, not \(found())")
        }
    }

    /// The arguments of a call or a constructor, from its opening bracket
    /// to its closing one.
    private func arguments() throws -> [GLSLExpr] {
        try expect("(")
        var given: [GLSLExpr] = []
        if isWord("void"), peek().kind == .punct(")") { advance() }
        if !isPunct(")") {
            repeat {
                guard given.count < GLSLLimits.arguments else {
                    throw fail("a call has more than \(GLSLLimits.arguments) arguments")
                }
                given.append(try assignment())
            } while accept(",")
        }
        try expect(")")
        return given
    }
}
