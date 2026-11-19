//
//  GLSLTypes.swift — what a GLSL ES 1.00 shader is once it has been read
//  and checked: its types, the values of its constants, and the tree of
//  its functions, statements and expressions that the Metal source is
//  written from (GLSLMetal.swift). The tree is made by the parser
//  (GLSLParser.swift) through the checker (GLSLChecker.swift), which lets
//  nothing into it that the language does not allow.
//
//  A shader is a guest's text. Every size here has a bound, so that no
//  text makes the Mac work long or write much: `GLSLLimits`.
//

import Foundation

/// The most of everything a shader may have. Past one of them it does not
/// compile, and its log says which.
enum GLSLLimits {
    static let sourceBytes = 256 * 1024
    static let tokens = 1 << 18
    static let identifierLength = 256
    /// Macros inside macros, and the tokens all expansions may make.
    static let macroDepth = 64
    static let macroTokens = 1 << 19
    static let macroParameters = 64
    /// Blocks inside blocks and expressions inside expressions. Metal's
    /// compiler takes 256 brackets inside each other, and an expression
    /// here becomes at most two of them for each level.
    static let nesting = 64
    static let nodes = 1 << 18
    /// The elements of all arrays a shader declares, together.
    static let arrayElements = 65536
    /// The numbers one variable or struct may hold.
    static let typeScalars = 1 << 20
    /// The rounds any one loop runs before it is made to stop: a shader
    /// may loop for as long as it likes, and the Mac's GPU may not.
    static let loopIterations = 65536
    static let functions = 1024
    static let overloads = 64
    static let parameters = 64
    static let arguments = 256
    static let structs = 256
    static let structDepth = 8
    static let fields = 256
    static let globals = 1024
    static let outputBytes = 4 << 20
    static let logBytes = 8192
    /// A uniform's whole name, as a program is told it.
    static let nameBytes = 1024
    /// What OpenGL ES 2.0 is asked about a program's shaders (the gl_Max
    /// constants say the same to the shader).
    static let attributes = 16
    static let textureUnits = 16
    static let uniformVectors = 256
    static let varyingVectors = 15
}

/// Why a shader did not compile, and on which line of it.
struct GLSLError: Error {
    let line: Int
    let message: String
}

/// A struct a shader declared. Two with the same name are different types;
/// what follows from the fields is worked out once, since a struct of
/// structs of structs would cost its whole size to walk each time.
final class GLSLStruct {
    struct Field {
        let name: String
        let type: GLSLType
        /// Where the field lies in the uniform block; nothing for a sampler.
        let offset: Int
    }

    let name: String
    let id: Int
    let fields: [Field]
    let depth: Int
    let scalars: Int
    let samplers: Int
    let arrayElements: Int
    let hasBool: Bool
    let hasArray: Bool
    let hasFloat: Bool
    /// In the uniform block, by Metal's rules for a struct: each field at
    /// the next multiple of its alignment, the size a multiple of the
    /// largest. A sampler takes no room.
    let blockSize: Int
    let blockAlignment: Int

    init(name: String, id: Int, fields: [(name: String, type: GLSLType)]) {
        self.name = name
        self.id = id
        var depth = 1, scalars = 0, samplers = 0, elements = 0
        var hasBool = false, hasArray = false, hasFloat = false
        var end = 0, alignment = 1
        var placed: [Field] = []
        placed.reserveCapacity(fields.count)
        for field in fields {
            let type = field.type
            depth = max(depth, type.structDepth + 1)
            scalars += type.scalars
            samplers += type.samplers
            elements += type.arrayElements
            hasBool = hasBool || type.hasBool
            hasArray = hasArray || type.hasArray
            hasFloat = hasFloat || type.hasFloat
            var offset = 0
            if let layout = type.blockLayout {
                offset = (end + layout.alignment - 1) / layout.alignment * layout.alignment
                end = offset + layout.size
                alignment = max(alignment, layout.alignment)
            }
            placed.append(Field(name: field.name, type: type, offset: offset))
        }
        self.fields = placed
        self.depth = depth
        self.scalars = scalars
        self.samplers = samplers
        self.arrayElements = elements
        self.hasBool = hasBool
        self.hasArray = hasArray
        self.hasFloat = hasFloat
        blockSize = (end + alignment - 1) / alignment * alignment
        blockAlignment = alignment
    }
}

indirect enum GLSLType: Equatable {
    case void, bool, int, float
    case vec(Int), ivec(Int), bvec(Int), mat(Int)
    case sampler2D, samplerCube
    case structure(GLSLStruct)
    /// There are no arrays of arrays in GLSL ES 1.00.
    case array(GLSLType, Int)

    static func == (a: GLSLType, b: GLSLType) -> Bool {
        switch (a, b) {
        case (.void, .void), (.bool, .bool), (.int, .int), (.float, .float),
             (.sampler2D, .sampler2D), (.samplerCube, .samplerCube):
            return true
        case let (.vec(x), .vec(y)), let (.ivec(x), .ivec(y)), let (.bvec(x), .bvec(y)), let (.mat(x), .mat(y)):
            return x == y
        case let (.structure(x), .structure(y)):
            return x === y
        case let (.array(x, n), .array(y, m)):
            return n == m && x == y
        default:
            return false
        }
    }

    /// float, int or bool: what a scalar, vector or matrix is made of.
    var base: GLSLType? {
        switch self {
        case .float, .vec, .mat: return .float
        case .int, .ivec: return .int
        case .bool, .bvec: return .bool
        default: return nil
        }
    }

    var isScalar: Bool { self == .float || self == .int || self == .bool }
    var isVector: Bool {
        switch self {
        case .vec, .ivec, .bvec: return true
        default: return false
        }
    }
    var isMatrix: Bool {
        if case .mat = self { return true }
        return false
    }
    var isSampler: Bool { self == .sampler2D || self == .samplerCube }
    var isArray: Bool {
        if case .array = self { return true }
        return false
    }
    /// float and the float vectors: what most built-in functions take.
    var isGenType: Bool {
        if case .vec = self { return true }
        return self == .float
    }

    /// How long a vector is, or a matrix's column; 1 for a scalar.
    var size: Int {
        switch self {
        case .vec(let n), .ivec(let n), .bvec(let n), .mat(let n): return n
        default: return 1
        }
    }

    /// How many numbers a scalar, vector or matrix has; 0 for anything else.
    var components: Int {
        switch self {
        case .float, .int, .bool: return 1
        case .vec(let n), .ivec(let n), .bvec(let n): return n
        case .mat(let n): return n * n
        default: return 0
        }
    }

    static func vector(_ base: GLSLType, _ size: Int) -> GLSLType {
        guard size > 1 else { return base }
        switch base {
        case .int: return .ivec(size)
        case .bool: return .bvec(size)
        default: return .vec(size)
        }
    }

    var structDepth: Int {
        switch self {
        case .structure(let s): return s.depth
        case .array(let element, _): return element.structDepth
        default: return 0
        }
    }

    var scalars: Int {
        switch self {
        case .structure(let s): return s.scalars
        case .array(let element, let count): return element.scalars * count
        default: return components
        }
    }

    var samplers: Int {
        switch self {
        case .sampler2D, .samplerCube: return 1
        case .structure(let s): return s.samplers
        case .array(let element, let count): return element.samplers * count
        default: return 0
        }
    }

    var arrayElements: Int {
        switch self {
        case .structure(let s): return s.arrayElements
        case .array(let element, let count): return max(1, element.arrayElements) * count
        default: return 0
        }
    }

    var hasBool: Bool {
        switch self {
        case .bool, .bvec: return true
        case .structure(let s): return s.hasBool
        case .array(let element, _): return element.hasBool
        default: return false
        }
    }

    var hasSampler: Bool { samplers > 0 }

    var hasArray: Bool {
        switch self {
        case .array: return true
        case .structure(let s): return s.hasArray
        default: return false
        }
    }

    var hasFloat: Bool {
        switch self {
        case .float, .vec, .mat: return true
        case .structure(let s): return s.hasFloat
        case .array(let element, _): return element.hasFloat
        default: return false
        }
    }

    /// The size and alignment of a value in the uniform block, as Metal
    /// lays out the type it is there: a bool is an int, a vector of three
    /// is as wide as one of four, a matrix is its columns. Nothing for a
    /// type that is samplers only.
    var blockLayout: (size: Int, alignment: Int)? {
        switch self {
        case .void, .sampler2D, .samplerCube: return nil
        case .bool, .int, .float: return (4, 4)
        case .vec(let n), .ivec(let n), .bvec(let n): return n == 2 ? (8, 8) : (16, 16)
        case .mat(let n): return n == 2 ? (16, 8) : (16 * n, 16)
        case .structure(let s): return s.blockSize > 0 ? (s.blockSize, s.blockAlignment) : nil
        case .array(let element, let count):
            guard let layout = element.blockLayout else { return nil }
            return (layout.size * count, layout.alignment)
        }
    }

    /// As a shader spells it, for the log.
    var name: String {
        switch self {
        case .void: return "void"
        case .bool: return "bool"
        case .int: return "int"
        case .float: return "float"
        case .vec(let n): return "vec\(n)"
        case .ivec(let n): return "ivec\(n)"
        case .bvec(let n): return "bvec\(n)"
        case .mat(let n): return "mat\(n)"
        case .sampler2D: return "sampler2D"
        case .samplerCube: return "samplerCube"
        case .structure(let s): return s.name.isEmpty ? "struct" : "struct \(s.name)"
        case .array(let element, let count): return "\(element.name)[\(count)]"
        }
    }

    /// The same type in another shader: structs are compared by what they
    /// are named and made of, since each shader declares its own.
    func matches(_ other: GLSLType) -> Bool {
        switch (self, other) {
        case let (.structure(a), .structure(b)):
            guard a.name == b.name, a.fields.count == b.fields.count else { return false }
            for (x, y) in zip(a.fields, b.fields) where x.name != y.name || !x.type.matches(y.type) { return false }
            return true
        case let (.array(a, n), .array(b, m)):
            return n == m && a.matches(b)
        default:
            return self == other
        }
    }
}

/// The value of a constant expression: the numbers of a scalar, vector or
/// matrix (a matrix column after column), or a struct's fields. There are
/// no constant arrays, GLSL ES 1.00 having no way to write one.
enum GLSLValue: Equatable {
    case float([Float])
    case int([Int32])
    case bool([Bool])
    case structure([GLSLValue])

    var count: Int {
        switch self {
        case .float(let v): return v.count
        case .int(let v): return v.count
        case .bool(let v): return v.count
        case .structure(let v): return v.count
        }
    }

    /// The numbers as floats, ints or bools, turned the way a constructor
    /// turns them.
    var floats: [Float] {
        switch self {
        case .float(let v): return v
        case .int(let v): return v.map { Float($0) }
        case .bool(let v): return v.map { $0 ? 1 : 0 }
        case .structure: return []
        }
    }

    var ints: [Int32] {
        switch self {
        case .float(let v): return v.map(GLSLValue.truncate)
        case .int(let v): return v
        case .bool(let v): return v.map { $0 ? 1 : 0 }
        case .structure: return []
        }
    }

    var bools: [Bool] {
        switch self {
        case .float(let v): return v.map { $0 != 0 }
        case .int(let v): return v.map { $0 != 0 }
        case .bool(let v): return v
        case .structure: return []
        }
    }

    /// A float as an int, where any float has an answer (Swift's own
    /// conversion stops the program on one that is too large).
    static func truncate(_ value: Float) -> Int32 {
        guard value == value else { return 0 }
        if value >= 2147483648 { return Int32.max }
        if value <= -2147483648 { return Int32.min }
        return Int32(value)
    }

    func converted(to base: GLSLType) -> GLSLValue {
        switch base {
        case .int: return .int(ints)
        case .bool: return .bool(bools)
        default: return .float(floats)
        }
    }

    static func of(_ base: GLSLType, floats: [Float]) -> GLSLValue {
        GLSLValue.float(floats).converted(to: base)
    }
}

/// The variables the language itself declares.
enum GLSLBuiltinVariable {
    case position, pointSize, fragCoord, frontFacing, pointCoord, fragColor, fragData, constant
}

final class GLSLVariable {
    enum Kind: Equatable {
        case global, local, parameter, uniform, attribute, varying
        case builtin(GLSLBuiltinVariable)
    }
    enum Direction { case input, output, both }

    let name: String
    let type: GLSLType
    let kind: Kind
    let id: Int
    let line: Int
    /// A const, a uniform, an attribute, a varying in a fragment shader.
    var readOnly = false
    /// Declared const: naming it is a constant expression.
    var isConst = false
    /// A const's value, where it could be worked out. Such a variable is
    /// never written to Metal: its value is, wherever it is used.
    var value: GLSLValue?
    var direction = Direction.input
    /// A global's initializer whose value could not be worked out here.
    var initializer: GLSLExpr?
    /// Named anywhere in the shader's code: what makes a uniform or an
    /// attribute active.
    var used = false
    var written = false

    init(name: String, type: GLSLType, kind: Kind, id: Int, line: Int) {
        self.name = name
        self.type = type
        self.kind = kind
        self.id = id
        self.line = line
    }
}

final class GLSLFunction {
    let name: String
    let id: Int
    let result: GLSLType
    let line: Int
    /// Of the definition once there is one, of the prototype until then.
    var parameters: [GLSLVariable]
    var body: [GLSLStmt]?
    /// Its body has begun: `body` is there once it has ended.
    var defined = false
    /// The functions its body calls, by their ids.
    var callees: [Int: GLSLFunction] = [:]
    var called = false

    init(name: String, id: Int, result: GLSLType, parameters: [GLSLVariable], line: Int) {
        self.name = name
        self.id = id
        self.result = result
        self.parameters = parameters
        self.line = line
    }
}

enum GLSLBinaryOperator {
    case add, subtract, multiply, divide
    case less, greater, lessEqual, greaterEqual, equal, notEqual
    case and, or, xor

    var symbol: String {
        switch self {
        case .add: return "+"
        case .subtract: return "-"
        case .multiply: return "*"
        case .divide: return "/"
        case .less: return "<"
        case .greater: return ">"
        case .lessEqual: return "<="
        case .greaterEqual: return ">="
        case .equal: return "=="
        case .notEqual: return "!="
        case .and: return "&&"
        case .or: return "||"
        case .xor: return "^^"
        }
    }
}

/// A checked expression. Its type is known and right; `value` is there
/// when it is a constant expression whose value could be worked out, and
/// then that value is what goes to Metal, not the expression.
final class GLSLExpr {
    indirect enum Kind {
        case literal
        case variable(GLSLVariable)
        case field(GLSLExpr, Int)
        /// Components of a vector, each 0…3; one of them gives a scalar.
        case swizzle(GLSLExpr, [Int])
        case index(GLSLExpr, GLSLExpr)
        case negate(GLSLExpr)
        case not(GLSLExpr)
        /// ++ and --: by +1 or -1, before the value is taken or after.
        case step(GLSLExpr, increment: Bool, prefix: Bool)
        case binary(GLSLBinaryOperator, GLSLExpr, GLSLExpr)
        /// = when there is no operator, otherwise += and its kind.
        case assign(GLSLBinaryOperator?, GLSLExpr, GLSLExpr)
        case conditional(GLSLExpr, GLSLExpr, GLSLExpr)
        case sequence(GLSLExpr, GLSLExpr)
        /// A constructor of the expression's type.
        case construct([GLSLExpr])
        case call(GLSLFunction, [GLSLExpr])
        case builtin(GLSLBuiltin, [GLSLExpr])
    }

    let kind: Kind
    let type: GLSLType
    let line: Int
    let value: GLSLValue?
    /// A constant expression as the language defines one, whether or not
    /// its value was worked out.
    let constant: Bool
    /// Evaluating it changes something: it must happen once and in order.
    let effects: Bool
    /// How many expressions deep it is.
    let height: Int

    init(kind: Kind, type: GLSLType, line: Int, value: GLSLValue?, constant: Bool, effects: Bool, height: Int) {
        self.kind = kind
        self.type = type
        self.line = line
        self.value = value
        self.constant = constant
        self.effects = effects
        self.height = height
    }
}

/// A loop: a for, a while or a do … while. Any of them may go on for
/// ever as far as the language goes; what is written to Metal counts its
/// rounds and leaves after `GLSLLimits.loopIterations`.
struct GLSLLoop {
    /// What a for declares or does before its first round, and the
    /// variable a condition declares.
    let setup: [GLSLStmt]
    /// Asked before each round; nil for a for that has none.
    let condition: GLSLExpr?
    /// A for's third part, done after each round, after a continue too.
    let step: GLSLExpr?
    let body: [GLSLStmt]
    /// do … while: the body runs once before the condition is asked.
    let bodyFirst: Bool
}

indirect enum GLSLStmt {
    case expression(GLSLExpr)
    case declare(GLSLVariable, GLSLExpr?)
    case block([GLSLStmt])
    /// if, else if, …, else: a chain is kept flat, so that a long one is
    /// not deep.
    case branch([(condition: GLSLExpr, body: [GLSLStmt])], otherwise: [GLSLStmt]?)
    case loop(GLSLLoop)
    case breakLoop, continueLoop, discard
    case result(GLSLExpr?)
}

/// A shader that compiled: what `GLSLTranslator.compile` hands back, and
/// `link` takes two of.
final class GLSLShader {
    let stage: GLShaderStage
    /// In the order they were declared.
    let structs: [GLSLStruct]
    let globals: [GLSLVariable]
    let functions: [GLSLFunction]
    let main: GLSLFunction?
    let builtins: [GLSLBuiltinVariable: GLSLVariable]

    init(stage: GLShaderStage, structs: [GLSLStruct], globals: [GLSLVariable], functions: [GLSLFunction],
         main: GLSLFunction?, builtins: [GLSLBuiltinVariable: GLSLVariable]) {
        self.stage = stage
        self.structs = structs
        self.globals = globals
        self.functions = functions
        self.main = main
        self.builtins = builtins
    }

    func uses(_ builtin: GLSLBuiltinVariable) -> Bool {
        builtins[builtin]?.used ?? false
    }
}
