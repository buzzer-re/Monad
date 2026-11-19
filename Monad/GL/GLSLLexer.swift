//
//  GLSLLexer.swift — a shader's text as the words the parser reads
//  (GLSLParser.swift): the text is cut into tokens, and the preprocessor's
//  lines (#define, #if, #extension and the others GLSL ES 1.00 has) are
//  carried out on them, so that the parser sees no # and no macro.
//
//  The text is a guest's. It may be anything: bytes that are no
//  characters, a macro that names itself, macros that double each other
//  thirty times over. Every loop here is bounded by the text's length or
//  by `GLSLLimits`, and a token keeps nothing of the text but an
//  identifier's letters or a number's value.
//

import Foundation

struct GLSLToken {
    enum Kind: Equatable {
        case identifier(String)
        case int(Int32)
        case float(Float)
        case punct(String)
        case newline
        /// A byte that is no character of the language. An error where
        /// the parser would read it.
        case stray(UInt8)
        case end
    }

    var kind: Kind
    var line: Int
    /// Space or a comment comes before it: what tells `#define f (x)`
    /// from `#define f(x)`.
    var spaced = false
    /// A macro's own name, met inside its expansion. It stays a name and
    /// is not expanded again, which is what ends `#define a a`.
    var painted = false
}

/// What the preprocessor leaves of a shader.
struct GLSLSource {
    var tokens: [GLSLToken] = []
    var warnings: [String] = []
    /// #extension GL_OES_standard_derivatives was asked for.
    var derivatives = false
}

enum GLSLLexer {
    /// The text as tokens, a `.newline` after each line: the preprocessor
    /// needs the lines, a directive being one.
    static func scan(_ source: String) throws -> [GLSLToken] {
        guard source.utf8.count <= GLSLLimits.sourceBytes else {
            throw GLSLError(line: 0, message: "the shader is longer than \(GLSLLimits.sourceBytes) bytes")
        }
        // A backslash at a line's end joins it to the next; the lines are
        // still counted, so that an error names the line the text has.
        let bytes = Array(source.utf8)
        var text: [UInt8] = []
        var lines: [Int32] = []
        text.reserveCapacity(bytes.count)
        lines.reserveCapacity(bytes.count)
        var line: Int32 = 1
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            let next: UInt8 = i + 1 < bytes.count ? bytes[i + 1] : 0
            if c == UInt8(ascii: "\\"), next == 0x0A || next == 0x0D {
                i += (next == 0x0D && i + 2 < bytes.count && bytes[i + 2] == 0x0A) ? 3 : 2
                line += 1
            } else if c == 0x0D {
                text.append(0x0A)
                lines.append(line)
                line += 1
                i += next == 0x0A ? 2 : 1
            } else {
                text.append(c)
                lines.append(line)
                if c == 0x0A { line += 1 }
                i += 1
            }
        }

        var tokens: [GLSLToken] = []
        var spaced = false
        func at(_ k: Int) -> UInt8 { k < text.count ? text[k] : 0 }
        func add(_ kind: GLSLToken.Kind, _ line: Int) throws {
            guard tokens.count < GLSLLimits.tokens else {
                throw GLSLError(line: line, message: "the shader has more than \(GLSLLimits.tokens) tokens")
            }
            tokens.append(GLSLToken(kind: kind, line: line, spaced: spaced))
            spaced = false
        }
        i = 0
        while i < text.count {
            let c = text[i]
            let here = Int(lines[i])
            if c == 0x20 || c == 0x09 || c == 0x0B || c == 0x0C {
                spaced = true
                i += 1
            } else if c == 0x0A {
                try add(.newline, here)
                i += 1
            } else if c == UInt8(ascii: "/"), at(i + 1) == UInt8(ascii: "/") {
                while i < text.count, text[i] != 0x0A { i += 1 }
                spaced = true
            } else if c == UInt8(ascii: "/"), at(i + 1) == UInt8(ascii: "*") {
                i += 2
                while i < text.count, !(text[i] == UInt8(ascii: "*") && at(i + 1) == UInt8(ascii: "/")) { i += 1 }
                guard i < text.count else { throw GLSLError(line: here, message: "a comment is not closed") }
                i += 2
                spaced = true
            } else if isLetter(c) {
                var end = i + 1
                while end < text.count, isLetter(text[end]) || isDigit(text[end]) { end += 1 }
                guard end - i <= GLSLLimits.identifierLength else {
                    throw GLSLError(line: here, message: "a name is longer than \(GLSLLimits.identifierLength) characters")
                }
                try add(.identifier(String(decoding: text[i..<end], as: UTF8.self)), here)
                i = end
            } else if isDigit(c) || (c == UInt8(ascii: ".") && isDigit(at(i + 1))) {
                let hex = c == UInt8(ascii: "0") && (at(i + 1) | 0x20) == UInt8(ascii: "x")
                var end = i + 1
                while end < text.count {
                    let d = text[end]
                    let sign = (d == UInt8(ascii: "+") || d == UInt8(ascii: "-")) && !hex && (text[end - 1] | 0x20) == UInt8(ascii: "e")
                    guard isLetter(d) || isDigit(d) || d == UInt8(ascii: ".") || sign else { break }
                    end += 1
                }
                try add(try number(Array(text[i..<end]), line: here), here)
                i = end
            } else if let length = punctuator(c, at(i + 1), at(i + 2)) {
                try add(.punct(String(decoding: text[i..<(i + length)], as: UTF8.self)), here)
                i += length
            } else {
                // No error yet: lines an #if leaves out may hold anything.
                try add(.stray(c), here)
                i += 1
            }
        }
        try add(.newline, Int(line))
        return tokens
    }

    private static func isLetter(_ c: UInt8) -> Bool {
        (c | 0x20) >= UInt8(ascii: "a") && (c | 0x20) <= UInt8(ascii: "z") || c == UInt8(ascii: "_")
    }

    private static func isDigit(_ c: UInt8) -> Bool {
        c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")
    }

    /// How many characters the operator starting here has, the longest
    /// there is; nil when none starts here.
    private static func punctuator(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Int? {
        let equals = UInt8(ascii: "=")
        switch a {
        case UInt8(ascii: "<"), UInt8(ascii: ">"):
            if b == a { return c == equals ? 3 : 2 }
            return b == equals ? 2 : 1
        case UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "&"), UInt8(ascii: "|"), UInt8(ascii: "^"):
            return b == a || b == equals ? 2 : 1
        case UInt8(ascii: "*"), UInt8(ascii: "/"), UInt8(ascii: "%"), UInt8(ascii: "!"), equals:
            return b == equals ? 2 : 1
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
             UInt8(ascii: "."), UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: ":"), UInt8(ascii: "?"), UInt8(ascii: "~"),
             UInt8(ascii: "#"):
            return 1
        default:
            return nil
        }
    }

    /// A number as the language writes them: 10, 012, 0xA, 1.5, .5, 1e3.
    /// Only its value is kept.
    private static func number(_ s: [UInt8], line: Int) throws -> GLSLToken.Kind {
        let bad = GLSLError(line: line, message: "a number is not written as the language writes one")
        let tooLarge = GLSLError(line: line, message: "a whole number is too large for an int")
        func whole(_ digits: ArraySlice<UInt8>, radix: UInt64) throws -> GLSLToken.Kind {
            guard !digits.isEmpty else { throw bad }
            var value: UInt64 = 0
            for d in digits {
                let digit: UInt64
                if isDigit(d) {
                    digit = UInt64(d - UInt8(ascii: "0"))
                } else if (d | 0x20) >= UInt8(ascii: "a"), (d | 0x20) <= UInt8(ascii: "f") {
                    digit = UInt64((d | 0x20) - UInt8(ascii: "a")) + 10
                } else {
                    throw bad
                }
                guard digit < radix else { throw bad }
                value = value * radix + digit
                guard value <= UInt64(UInt32.max) else { throw tooLarge }
            }
            return .int(Int32(truncatingIfNeeded: value))
        }
        if s.count >= 2, s[0] == UInt8(ascii: "0"), (s[1] | 0x20) == UInt8(ascii: "x") {
            return try whole(s[2...], radix: 16)
        }
        guard s.contains(UInt8(ascii: ".")) || s.contains(where: { ($0 | 0x20) == UInt8(ascii: "e") }) else {
            return try whole(s[...], radix: s.count > 1 && s[0] == UInt8(ascii: "0") ? 8 : 10)
        }
        var k = 0
        var integer = "", fraction = "", exponent = ""
        while k < s.count, isDigit(s[k]) { integer.append(Character(UnicodeScalar(s[k]))); k += 1 }
        if k < s.count, s[k] == UInt8(ascii: ".") {
            k += 1
            while k < s.count, isDigit(s[k]) { fraction.append(Character(UnicodeScalar(s[k]))); k += 1 }
        }
        guard !integer.isEmpty || !fraction.isEmpty else { throw bad }
        if k < s.count, (s[k] | 0x20) == UInt8(ascii: "e") {
            k += 1
            if k < s.count, s[k] == UInt8(ascii: "+") || s[k] == UInt8(ascii: "-") {
                if s[k] == UInt8(ascii: "-") { exponent = "-" }
                k += 1
            }
            let start = k
            while k < s.count, isDigit(s[k]) { exponent.append(Character(UnicodeScalar(s[k]))); k += 1 }
            guard k > start else { throw bad }
        }
        // GLSL ES 1.00 has no f at a number's end, but shaders written
        // for the desktop have it and other implementations let it pass.
        if k < s.count, (s[k] | 0x20) == UInt8(ascii: "f") { k += 1 }
        guard k == s.count else { throw bad }
        let spelled = "\(integer.isEmpty ? "0" : integer).\(fraction.isEmpty ? "0" : fraction)e\(exponent.isEmpty ? "0" : exponent)"
        guard let value = Float(spelled) else { throw bad }
        return .float(value)
    }
}

/// The preprocessor: the directives carried out and the macros expanded.
struct GLSLPreprocessor {
    private struct Macro {
        var parameters: [String]?
        var body: [GLSLToken]
    }

    private struct Condition {
        /// The lines of this branch are read.
        var live: Bool
        /// A branch of this #if has been read: no later one is.
        var taken: Bool
        /// The #if itself is in lines that are read.
        var outer: Bool
        var sawElse = false
    }

    private var macros: [String: Macro] = [:]
    private var result = GLSLSource()
    /// Lines of text not yet expanded: a macro's arguments may go on over
    /// several lines, so they wait until a directive changes the macros.
    private var pending: [GLSLToken] = []
    private var budget = GLSLLimits.macroTokens
    /// What #line added to the lines counted.
    private var lineShift = 0
    private var started = false

    static func run(_ source: String, stage: GLShaderStage) throws -> GLSLSource {
        let raw = try GLSLLexer.scan(source)
        var preprocessor = GLSLPreprocessor()
        func one(_ line: Int) -> [GLSLToken] { [GLSLToken(kind: .int(1), line: line)] }
        preprocessor.macros["GL_ES"] = Macro(parameters: nil, body: one(0))
        preprocessor.macros["__VERSION__"] = Macro(parameters: nil, body: [GLSLToken(kind: .int(100), line: 0)])
        preprocessor.macros["__FILE__"] = Macro(parameters: nil, body: [GLSLToken(kind: .int(0), line: 0)])
        preprocessor.macros["__LINE__"] = Macro(parameters: nil, body: [])
        preprocessor.macros["GL_OES_standard_derivatives"] = Macro(parameters: nil, body: one(0))
        if stage == .fragment {
            preprocessor.macros["GL_FRAGMENT_PRECISION_HIGH"] = Macro(parameters: nil, body: one(0))
        }
        try preprocessor.process(raw)
        return preprocessor.result
    }

    private mutating func process(_ raw: [GLSLToken]) throws {
        var conditions: [Condition] = []
        var position = 0
        var lastLine = 1
        while position < raw.count {
            var end = position
            while end < raw.count, raw[end].kind != .newline { end += 1 }
            let line = raw[position..<end]
            position = end + 1
            guard let first = line.first else { continue }
            lastLine = first.line + lineShift
            let live = conditions.last?.live ?? true
            if first.kind == .punct("#") {
                try directive(Array(line.dropFirst()), line: lastLine, live: live, conditions: &conditions)
            } else if live {
                started = true
                for var token in line {
                    token.line += lineShift
                    pending.append(token)
                }
            }
        }
        guard conditions.isEmpty else { throw GLSLError(line: lastLine, message: "#if without its #endif") }
        try flush()
        result.tokens.append(GLSLToken(kind: .end, line: lastLine))
    }

    private mutating func flush() throws {
        guard !pending.isEmpty else { return }
        let expanded = try expand(pending, hidden: [], depth: 0)
        pending = []
        guard result.tokens.count + expanded.count < GLSLLimits.tokens else {
            throw GLSLError(line: expanded.last?.line ?? 0, message: "the shader has more than \(GLSLLimits.tokens) tokens")
        }
        result.tokens += expanded
    }

    private mutating func directive(_ tokens: [GLSLToken], line: Int, live: Bool, conditions: inout [Condition]) throws {
        guard let first = tokens.first else { return }
        guard case .identifier(let name) = first.kind else {
            if live { throw GLSLError(line: line, message: "# is not followed by a directive") }
            return
        }
        let rest = Array(tokens.dropFirst())
        switch name {
        case "if", "ifdef", "ifndef":
            guard conditions.count < GLSLLimits.nesting else {
                throw GLSLError(line: line, message: "#if is nested deeper than \(GLSLLimits.nesting)")
            }
            var value = false
            if live {
                if name == "if" {
                    value = try evaluate(rest, line: line) != 0
                } else {
                    guard rest.count == 1, case .identifier(let macro) = rest[0].kind else {
                        throw GLSLError(line: line, message: "#\(name) takes one name")
                    }
                    value = (macros[macro] != nil) == (name == "ifdef")
                }
            }
            conditions.append(Condition(live: live && value, taken: value, outer: live))
        case "elif":
            guard var top = conditions.last, !top.sawElse else { throw GLSLError(line: line, message: "#elif without its #if") }
            if top.outer, !top.taken {
                top.live = try evaluate(rest, line: line) != 0
                top.taken = top.live
            } else {
                top.live = false
            }
            conditions[conditions.count - 1] = top
        case "else":
            guard var top = conditions.last, !top.sawElse else { throw GLSLError(line: line, message: "#else without its #if") }
            top.live = top.outer && !top.taken
            top.taken = true
            top.sawElse = true
            conditions[conditions.count - 1] = top
        case "endif":
            guard !conditions.isEmpty else { throw GLSLError(line: line, message: "#endif without its #if") }
            conditions.removeLast()
        default:
            guard live else { return }
            if name != "version" { started = true }
            switch name {
            case "define": try define(rest, line: line)
            case "undef":
                guard rest.count == 1, case .identifier(let macro) = rest[0].kind else {
                    throw GLSLError(line: line, message: "#undef takes one name")
                }
                guard !isReserved(macro) else { throw GLSLError(line: line, message: "\(macro) cannot be undefined") }
                try flush()
                macros[macro] = nil
            case "error":
                var said = ""
                for token in rest.prefix(32) {
                    switch token.kind {
                    case .identifier(let word): said += " " + word
                    case .int(let value): said += " \(value)"
                    case .float(let value): said += " \(value)"
                    case .punct(let mark): said += " " + mark
                    default: break
                    }
                }
                throw GLSLError(line: line, message: "#error" + said)
            case "pragma":
                break
            case "extension": try extend(rest, line: line)
            case "version":
                guard !started else { throw GLSLError(line: line, message: "#version must come before everything else") }
                started = true
                guard rest.count == 1, rest[0].kind == .int(100) else {
                    throw GLSLError(line: line, message: "only #version 100 is supported (GLSL ES 1.00)")
                }
            case "line":
                let numbers = try expand(rest, hidden: [], depth: 0)
                var isNumbers = numbers.count == 1 || numbers.count == 2
                for token in numbers {
                    if case .int = token.kind { continue }
                    isNumbers = false
                }
                guard isNumbers, case .int(let number) = numbers[0].kind, number >= 0 else {
                    throw GLSLError(line: line, message: "#line takes a line number")
                }
                // The line after the directive is the number given plus
                // one, as GLSL ES 1.00 has it.
                lineShift += Int(number) - line
            default:
                throw GLSLError(line: line, message: "#\(name) is no directive of GLSL ES 1.00")
            }
        }
    }

    /// The language's own macros, and the names it keeps for itself.
    private func isReserved(_ name: String) -> Bool {
        name.hasPrefix("GL_") || name.hasPrefix("__") || name == "defined"
    }

    private mutating func define(_ tokens: [GLSLToken], line: Int) throws {
        guard let first = tokens.first, case .identifier(let name) = first.kind else {
            throw GLSLError(line: line, message: "#define takes a name")
        }
        guard !isReserved(name) else { throw GLSLError(line: line, message: "\(name) is a name the language keeps for itself") }
        var parameters: [String]?
        var k = 1
        if k < tokens.count, tokens[k].kind == .punct("("), !tokens[k].spaced {
            var names: [String] = []
            k += 1
            if k < tokens.count, tokens[k].kind == .punct(")") {
                k += 1
            } else {
                while true {
                    guard k + 1 < tokens.count, case .identifier(let parameter) = tokens[k].kind, !names.contains(parameter),
                          names.count < GLSLLimits.macroParameters else {
                        throw GLSLError(line: line, message: "the parameters of macro \(name) are not a list of names")
                    }
                    names.append(parameter)
                    k += 2
                    if tokens[k - 1].kind == .punct(")") { break }
                    guard tokens[k - 1].kind == .punct(",") else {
                        throw GLSLError(line: line, message: "the parameters of macro \(name) are not a list of names")
                    }
                }
            }
            parameters = names
        }
        let body = Array(tokens[k...])
        if let old = macros[name] {
            guard old.parameters == parameters, old.body.map(\.kind) == body.map(\.kind) else {
                throw GLSLError(line: line, message: "macro \(name) is defined again, differently")
            }
            return
        }
        try flush()
        macros[name] = Macro(parameters: parameters, body: body)
    }

    private mutating func extend(_ tokens: [GLSLToken], line: Int) throws {
        guard tokens.count == 3, case .identifier(let name) = tokens[0].kind, tokens[1].kind == .punct(":"),
              case .identifier(let behavior) = tokens[2].kind,
              ["require", "enable", "warn", "disable"].contains(behavior) else {
            throw GLSLError(line: line, message: "#extension takes a name, a colon and require, enable, warn or disable")
        }
        let asks = behavior == "require" || behavior == "enable"
        if name == "GL_OES_standard_derivatives" {
            result.derivatives = behavior != "disable"
        } else if name == "all" {
            guard !asks else { throw GLSLError(line: line, message: "#extension all can only be warn or disable") }
            if behavior == "disable" { result.derivatives = false }
        } else if asks {
            result.warnings.append("WARNING: 0:\(line): extension \(name) is not supported")
        }
    }

    private mutating func spend(_ count: Int, line: Int) throws {
        budget -= count
        guard budget >= 0 else {
            throw GLSLError(line: line, message: "the macros expand to more than \(GLSLLimits.macroTokens) tokens")
        }
    }

    /// The tokens with every macro in them replaced. `hidden` are the
    /// macros being expanded around this text, which are not expanded
    /// inside themselves.
    private mutating func expand(_ input: [GLSLToken], hidden: Set<String>, depth: Int) throws -> [GLSLToken] {
        guard depth <= GLSLLimits.macroDepth else {
            throw GLSLError(line: input.first?.line ?? 0, message: "macros are nested deeper than \(GLSLLimits.macroDepth)")
        }
        var out: [GLSLToken] = []
        var i = 0
        // A function-like macro's name that an expansion ended with: its
        // arguments are what follows the expansion.
        var held: GLSLToken?
        while i < input.count || held != nil {
            let token: GLSLToken
            if let name = held {
                token = name
                held = nil
            } else {
                token = input[i]
                i += 1
            }
            try spend(1, line: token.line)
            guard case .identifier(let name) = token.kind, !token.painted, let macro = macros[name] else {
                out.append(token)
                continue
            }
            if hidden.contains(name) {
                var kept = token
                kept.painted = true
                out.append(kept)
                continue
            }
            if name == "__LINE__" {
                out.append(GLSLToken(kind: .int(Int32(truncatingIfNeeded: token.line)), line: token.line))
                continue
            }
            var replaced: [GLSLToken] = []
            if let parameters = macro.parameters {
                guard i < input.count, input[i].kind == .punct("(") else {
                    out.append(token)
                    continue
                }
                var arguments: [[GLSLToken]] = [[]]
                var level = 0
                var k = i + 1
                var closed = false
                while k < input.count {
                    let next = input[k]
                    k += 1
                    if next.kind == .punct("(") {
                        level += 1
                    } else if next.kind == .punct(")") {
                        if level == 0 {
                            closed = true
                            break
                        }
                        level -= 1
                    } else if next.kind == .punct(","), level == 0 {
                        arguments.append([])
                        continue
                    }
                    arguments[arguments.count - 1].append(next)
                }
                guard closed else { throw GLSLError(line: token.line, message: "the call of macro \(name) is not closed") }
                i = k
                if parameters.isEmpty, arguments.count == 1, arguments[0].isEmpty { arguments = [] }
                guard arguments.count == parameters.count else {
                    throw GLSLError(line: token.line, message: "macro \(name) takes \(parameters.count) arguments, not \(arguments.count)")
                }
                var expanded: [[GLSLToken]] = []
                for argument in arguments {
                    expanded.append(try expand(argument, hidden: hidden, depth: depth + 1))
                }
                for part in macro.body {
                    if case .identifier(let word) = part.kind, let index = parameters.firstIndex(of: word) {
                        try spend(expanded[index].count, line: token.line)
                        replaced += expanded[index]
                    } else {
                        replaced.append(part)
                    }
                }
            } else {
                replaced = macro.body
            }
            for index in replaced.indices { replaced[index].line = token.line }
            var inner = hidden
            inner.insert(name)
            var expansion = try expand(replaced, hidden: inner, depth: depth + 1)
            if let last = expansion.last, case .identifier(let word) = last.kind, !last.painted, !hidden.contains(word),
               macros[word]?.parameters != nil, i < input.count, input[i].kind == .punct("(") {
                expansion.removeLast()
                held = last
            }
            out += expansion
        }
        return out
    }

    /// What an #if's or #elif's expression comes to.
    private mutating func evaluate(_ tokens: [GLSLToken], line: Int) throws -> Int32 {
        var prepared: [GLSLToken] = []
        var k = 0
        while k < tokens.count {
            guard tokens[k].kind == .identifier("defined") else {
                prepared.append(tokens[k])
                k += 1
                continue
            }
            let bracketed = k + 1 < tokens.count && tokens[k + 1].kind == .punct("(")
            let at = bracketed ? k + 2 : k + 1
            guard at < tokens.count, case .identifier(let name) = tokens[at].kind,
                  !bracketed || (at + 1 < tokens.count && tokens[at + 1].kind == .punct(")")) else {
                throw GLSLError(line: line, message: "defined takes a name")
            }
            prepared.append(GLSLToken(kind: .int(macros[name] != nil ? 1 : 0), line: line))
            k = at + (bracketed ? 2 : 1)
        }
        var condition = ConditionReader(tokens: try expand(prepared, hidden: [], depth: 0), line: line)
        let value = try condition.binary(1, live: true)
        guard condition.position == condition.tokens.count else {
            throw GLSLError(line: line, message: "the expression of #if is not a whole number expression")
        }
        return value
    }

    /// Reads the whole number expression of an #if. A part that && or ||
    /// makes no difference is read but not worked out, so that
    /// `defined(A) && A > 1` is no error where A is not defined.
    private struct ConditionReader {
        let tokens: [GLSLToken]
        let line: Int
        var position = 0
        var depth = 0

        private static let precedence: [String: Int] = [
            "||": 1, "&&": 2, "|": 3, "^": 4, "&": 5, "==": 6, "!=": 6, "<": 7, ">": 7, "<=": 7, ">=": 7,
            "<<": 8, ">>": 8, "+": 9, "-": 9, "*": 10, "/": 10, "%": 10,
        ]

        private func malformed() -> GLSLError {
            GLSLError(line: line, message: "the expression of #if is not a whole number expression")
        }

        mutating func binary(_ minimum: Int, live: Bool) throws -> Int32 {
            var left = try unary(live: live)
            while position < tokens.count, case .punct(let op) = tokens[position].kind,
                  let precedence = Self.precedence[op], precedence >= minimum {
                position += 1
                let needed = live && !(op == "&&" && left == 0) && !(op == "||" && left != 0)
                let right = try binary(precedence + 1, live: needed)
                guard needed else {
                    if live { left = op == "&&" ? 0 : 1 }
                    continue
                }
                switch op {
                case "||": left = (left != 0 || right != 0) ? 1 : 0
                case "&&": left = (left != 0 && right != 0) ? 1 : 0
                case "|": left |= right
                case "^": left ^= right
                case "&": left &= right
                case "==": left = left == right ? 1 : 0
                case "!=": left = left != right ? 1 : 0
                case "<": left = left < right ? 1 : 0
                case ">": left = left > right ? 1 : 0
                case "<=": left = left <= right ? 1 : 0
                case ">=": left = left >= right ? 1 : 0
                case "<<": left = left << (right & 31)
                case ">>": left = left >> (right & 31)
                case "+": left = left &+ right
                case "-": left = left &- right
                case "*": left = left &* right
                default:
                    guard right != 0 else { throw GLSLError(line: line, message: "#if divides by zero") }
                    if right == -1 {
                        left = op == "/" ? 0 &- left : 0
                    } else {
                        left = op == "/" ? left / right : left % right
                    }
                }
            }
            return left
        }

        private mutating func unary(live: Bool) throws -> Int32 {
            guard position < tokens.count else { throw malformed() }
            depth += 1
            defer { depth -= 1 }
            guard depth <= GLSLLimits.nesting else {
                throw GLSLError(line: line, message: "the expression of #if is nested deeper than \(GLSLLimits.nesting)")
            }
            let token = tokens[position]
            position += 1
            switch token.kind {
            case .int(let value):
                return value
            case .identifier(let name):
                guard !live else { throw GLSLError(line: line, message: "\(name) in #if is not a macro") }
                return 0
            case .punct("("):
                let value = try binary(1, live: live)
                guard position < tokens.count, tokens[position].kind == .punct(")") else { throw malformed() }
                position += 1
                return value
            case .punct("+"): return try unary(live: live)
            case .punct("-"): return 0 &- (try unary(live: live))
            case .punct("!"): return try unary(live: live) == 0 ? 1 : 0
            case .punct("~"): return ~(try unary(live: live))
            default: throw malformed()
            }
        }
    }
}
