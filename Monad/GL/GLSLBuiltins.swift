//
//  GLSLBuiltins.swift — the functions GLSL ES 1.00 has built in: which
//  arguments each takes and what it gives (the checker asks,
//  GLSLChecker.swift), and what a call with constant arguments comes to,
//  where that is worked out here so that it can size an array. How each
//  is written in Metal's language is in GLSLMetal.swift.
//

import Foundation

enum GLSLBuiltin: String {
    case radians, degrees, sin, cos, tan, asin, acos, atan
    case pow, exp, log, exp2, log2, sqrt, inversesqrt
    case abs, sign, floor, ceil, fract, mod, min, max, clamp, mix, step, smoothstep
    case length, distance, dot, cross, normalize, faceforward, reflect, refract
    case matrixCompMult
    case lessThan, lessThanEqual, greaterThan, greaterThanEqual, equal, notEqual
    case anyOf = "any", allOf = "all", notOf = "not"
    case texture2D, texture2DProj, texture2DLod, texture2DProjLod, textureCube, textureCubeLod
    case dFdx, dFdy, fwidth

    /// A call of it can be a constant expression: all but the texture
    /// lookups and the derivatives, which have no value before drawing.
    var isConstant: Bool {
        switch self {
        case .texture2D, .texture2DProj, .texture2DLod, .texture2DProjLod, .textureCube, .textureCubeLod,
             .dFdx, .dFdy, .fwidth:
            return false
        default:
            return true
        }
    }

    /// What a call with arguments of these types gives; nil when the
    /// function takes no such arguments in this shader. The texture
    /// lookups with a bias are the fragment shader's, the ones with a
    /// level of detail the vertex shader's, and the derivatives need
    /// their extension.
    func result(_ a: [GLSLType], stage: GLShaderStage, derivatives: Bool) -> GLSLType? {
        let n = a.count
        func all(_ count: Int, _ holds: Bool) -> Bool { n == count && holds }
        switch self {
        case .radians, .degrees, .sin, .cos, .tan, .asin, .acos, .exp, .log, .exp2, .log2, .sqrt, .inversesqrt,
             .abs, .sign, .floor, .ceil, .fract, .normalize:
            return n == 1 && a[0].isGenType ? a[0] : nil
        case .atan:
            return (n == 1 || n == 2) && a[0].isGenType && a[n - 1] == a[0] ? a[0] : nil
        case .pow, .reflect:
            return n == 2 && a[0].isGenType && a[1] == a[0] ? a[0] : nil
        case .mod, .min, .max:
            return n == 2 && a[0].isGenType && (a[1] == a[0] || a[1] == .float) ? a[0] : nil
        case .clamp:
            guard n == 3, a[0].isGenType else { return nil }
            return (a[1] == a[0] && a[2] == a[0]) || (a[1] == .float && a[2] == .float) ? a[0] : nil
        case .mix:
            return n == 3 && a[0].isGenType && a[1] == a[0] && (a[2] == a[0] || a[2] == .float) ? a[0] : nil
        case .step:
            return n == 2 && a[1].isGenType && (a[0] == a[1] || a[0] == .float) ? a[1] : nil
        case .smoothstep:
            guard n == 3, a[2].isGenType else { return nil }
            return (a[0] == a[2] && a[1] == a[2]) || (a[0] == .float && a[1] == .float) ? a[2] : nil
        case .length:
            return n == 1 && a[0].isGenType ? .float : nil
        case .distance, .dot:
            return n == 2 && a[0].isGenType && a[1] == a[0] ? .float : nil
        case .cross:
            return n == 2 && a[0] == .vec(3) && a[1] == .vec(3) ? .vec(3) : nil
        case .faceforward:
            return n == 3 && a[0].isGenType && a[1] == a[0] && a[2] == a[0] ? a[0] : nil
        case .refract:
            return n == 3 && a[0].isGenType && a[1] == a[0] && a[2] == .float ? a[0] : nil
        case .matrixCompMult:
            return n == 2 && a[0].isMatrix && a[1] == a[0] ? a[0] : nil
        case .lessThan, .lessThanEqual, .greaterThan, .greaterThanEqual:
            guard n == 2, a[0] == a[1], a[0].isVector, a[0].base != .bool else { return nil }
            return .bvec(a[0].size)
        case .equal, .notEqual:
            return n == 2 && a[0] == a[1] && a[0].isVector ? .bvec(a[0].size) : nil
        case .anyOf, .allOf:
            return n == 1 && a[0].isVector && a[0].base == .bool ? .bool : nil
        case .notOf:
            return n == 1 && a[0].isVector && a[0].base == .bool ? a[0] : nil
        case .texture2D:
            guard n >= 2, a[0] == .sampler2D, a[1] == .vec(2) else { return nil }
            return n == 2 || (n == 3 && stage == .fragment && a[2] == .float) ? .vec(4) : nil
        case .texture2DProj:
            guard n >= 2, a[0] == .sampler2D, a[1] == .vec(3) || a[1] == .vec(4) else { return nil }
            return n == 2 || (n == 3 && stage == .fragment && a[2] == .float) ? .vec(4) : nil
        case .texture2DLod:
            return all(3, stage == .vertex) && a[0] == .sampler2D && a[1] == .vec(2) && a[2] == .float ? .vec(4) : nil
        case .texture2DProjLod:
            guard all(3, stage == .vertex), a[0] == .sampler2D, a[2] == .float else { return nil }
            return a[1] == .vec(3) || a[1] == .vec(4) ? .vec(4) : nil
        case .textureCube:
            guard n >= 2, a[0] == .samplerCube, a[1] == .vec(3) else { return nil }
            return n == 2 || (n == 3 && stage == .fragment && a[2] == .float) ? .vec(4) : nil
        case .textureCubeLod:
            return all(3, stage == .vertex) && a[0] == .samplerCube && a[1] == .vec(3) && a[2] == .float ? .vec(4) : nil
        case .dFdx, .dFdy, .fwidth:
            return all(1, derivatives && stage == .fragment) && a[0].isGenType ? a[0] : nil
        }
    }

    /// The value of a call whose arguments are these constants, for the
    /// functions it is worked out for; the others are left to Metal.
    func fold(_ values: [GLSLValue]) -> GLSLValue? {
        glslFold(self, values)
    }
}

/// Outside the enum, where sin is the Mac's and not a case of it.
private func glslFold(_ function: GLSLBuiltin, _ values: [GLSLValue]) -> GLSLValue? {
    let a = values.map(\.floats)
    guard let first = a.first, !first.isEmpty, !a.contains(where: \.isEmpty) else { return nil }
    let width = a.map(\.count).max() ?? 1
    // A float where the others are vectors stands for a vector of it.
    func at(_ argument: Int, _ i: Int) -> Float {
        let list = a[argument]
        return list.count == 1 ? list[0] : (i < list.count ? list[i] : 0)
    }
    func each(_ body: (Int) -> Float) -> GLSLValue { .float((0..<width).map(body)) }
    func one(_ body: (Float) -> Float) -> GLSLValue { each { body(at(0, $0)) } }
    func two(_ body: (Float, Float) -> Float) -> GLSLValue? {
        a.count == 2 ? each { body(at(0, $0), at(1, $0)) } : nil
    }
    func three(_ body: (Float, Float, Float) -> Float) -> GLSLValue? {
        a.count == 3 ? each { body(at(0, $0), at(1, $0), at(2, $0)) } : nil
    }
    func dot(_ x: [Float], _ y: [Float]) -> Float { zip(x, y).reduce(0) { $0 + $1.0 * $1.1 } }
    func compare(_ floats: (Float, Float) -> Bool, _ ints: (Int32, Int32) -> Bool) -> GLSLValue? {
        guard values.count == 2 else { return nil }
        if case .int(let x) = values[0], case .int(let y) = values[1] { return .bool(zip(x, y).map(ints)) }
        return .bool(zip(a[0], a[1]).map(floats))
    }

    switch function {
    case .radians: return one { $0 * (Float.pi / 180) }
    case .degrees: return one { $0 * (180 / Float.pi) }
    case .sin: return one { sin($0) }
    case .cos: return one { cos($0) }
    case .tan: return one { tan($0) }
    case .asin: return one { asin($0) }
    case .acos: return one { acos($0) }
    case .atan: return a.count == 1 ? one { atan($0) } : two { atan2($0, $1) }
    case .pow: return two { pow($0, $1) }
    case .exp: return one { exp($0) }
    case .log: return one { log($0) }
    case .exp2: return one { exp2($0) }
    case .log2: return one { log2($0) }
    case .sqrt: return one { $0.squareRoot() }
    case .inversesqrt: return one { 1 / $0.squareRoot() }
    case .abs: return one { $0.magnitude }
    case .sign: return one { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) }
    case .floor: return one { $0.rounded(.down) }
    case .ceil: return one { $0.rounded(.up) }
    case .fract: return one { $0 - $0.rounded(.down) }
    case .mod: return two { $0 - $1 * ($0 / $1).rounded(.down) }
    case .min: return two { $1 < $0 ? $1 : $0 }
    case .max: return two { $0 < $1 ? $1 : $0 }
    case .clamp: return three { x, low, high in Swift.min(Swift.max(x, low), high) }
    case .mix: return three { x, y, t in x * (1 - t) + y * t }
    case .step: return two { edge, x in x < edge ? 0 : 1 }
    case .smoothstep:
        return three { low, high, x in
            let t = Swift.min(Swift.max((x - low) / (high - low), 0), 1)
            return t * t * (3 - 2 * t)
        }
    case .length: return .float([dot(first, first).squareRoot()])
    case .distance:
        guard a.count == 2, a[1].count == first.count else { return nil }
        let difference = zip(first, a[1]).map { $0 - $1 }
        return .float([dot(difference, difference).squareRoot()])
    case .dot:
        guard a.count == 2, a[1].count == first.count else { return nil }
        return .float([dot(first, a[1])])
    case .cross:
        guard a.count == 2, first.count == 3, a[1].count == 3 else { return nil }
        let x = first, y = a[1]
        return .float([x[1] * y[2] - y[1] * x[2], x[2] * y[0] - y[2] * x[0], x[0] * y[1] - y[0] * x[1]])
    case .normalize:
        let length = dot(first, first).squareRoot()
        return .float(first.map { $0 / length })
    case .matrixCompMult: return two { $0 * $1 }
    case .lessThan: return compare({ $0 < $1 }, { $0 < $1 })
    case .lessThanEqual: return compare({ $0 <= $1 }, { $0 <= $1 })
    case .greaterThan: return compare({ $0 > $1 }, { $0 > $1 })
    case .greaterThanEqual: return compare({ $0 >= $1 }, { $0 >= $1 })
    case .equal: return compare({ $0 == $1 }, { $0 == $1 })
    case .notEqual: return compare({ $0 != $1 }, { $0 != $1 })
    case .anyOf: return .bool([values[0].bools.contains(true)])
    case .allOf: return .bool([!values[0].bools.contains(false)])
    case .notOf: return .bool(values[0].bools.map { !$0 })
    default: return nil
    }
}
