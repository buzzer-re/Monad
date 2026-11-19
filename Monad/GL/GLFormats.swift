//
//  GLFormats.swift — the pixels of a Linux program's OpenGL ES drawing as
//  Metal keeps them (GLStream.swift). OpenGL ES 2.0 has a handful of
//  texture formats, some of them packed into sixteen bits; here every
//  colour one becomes four bytes a pixel (RGBA8Unorm), written out the way
//  OpenGL says a sampler reads it: luminance in all three colours, no
//  alpha as 1, alpha alone over black. Depth becomes a Float32.
//
//  Every count is checked before a byte is read: the pixels are a guest's.
//

import Foundation
import Metal

enum GLFormats {
    /// The bytes of one pixel as a program sends it; nil for a pair of
    /// format and type OpenGL ES 2.0 (with its depth texture extensions)
    /// does not have.
    static func bytesPerPixel(format: UInt32, type: UInt32) -> Int? {
        switch (format, type) {
        case (GL.RGBA, GL.UNSIGNED_BYTE): return 4
        case (GL.RGB, GL.UNSIGNED_BYTE): return 3
        case (GL.LUMINANCE_ALPHA, GL.UNSIGNED_BYTE): return 2
        case (GL.LUMINANCE, GL.UNSIGNED_BYTE), (GL.ALPHA, GL.UNSIGNED_BYTE): return 1
        case (GL.RGBA, GL.UNSIGNED_SHORT_4_4_4_4), (GL.RGBA, GL.UNSIGNED_SHORT_5_5_5_1), (GL.RGB, GL.UNSIGNED_SHORT_5_6_5): return 2
        case (GL.DEPTH_COMPONENT, GL.UNSIGNED_SHORT): return 2
        case (GL.DEPTH_COMPONENT, GL.UNSIGNED_INT), (GL.DEPTH_STENCIL_OES, GL.UNSIGNED_INT_24_8_OES): return 4
        default: return nil
        }
    }

    static func isTextureFormat(_ format: UInt32) -> Bool {
        [GL.RGBA, GL.RGB, GL.LUMINANCE_ALPHA, GL.LUMINANCE, GL.ALPHA, GL.DEPTH_COMPONENT, GL.DEPTH_STENCIL_OES].contains(format)
    }

    static func isPixelType(_ type: UInt32) -> Bool {
        [GL.UNSIGNED_BYTE, GL.UNSIGNED_SHORT_4_4_4_4, GL.UNSIGNED_SHORT_5_5_5_1, GL.UNSIGNED_SHORT_5_6_5,
         GL.UNSIGNED_SHORT, GL.UNSIGNED_INT, GL.UNSIGNED_INT_24_8_OES].contains(type)
    }

    static func isDepth(_ format: UInt32) -> Bool {
        format == GL.DEPTH_COMPONENT || format == GL.DEPTH_STENCIL_OES
    }

    /// Whether a texture of this format has an alpha of its own. One that
    /// has none is kept with alpha 1, and drawing into it leaves that be.
    static func hasAlpha(_ format: UInt32) -> Bool {
        format == GL.RGBA || format == GL.LUMINANCE_ALPHA || format == GL.ALPHA
    }

    /// What Metal keeps a texture of this format as.
    static func texture(_ format: UInt32) -> MTLPixelFormat {
        switch format {
        case GL.DEPTH_COMPONENT: return .depth32Float
        case GL.DEPTH_STENCIL_OES: return .depth32Float_stencil8
        default: return .rgba8Unorm
        }
    }

    /// What Metal keeps a renderbuffer of this format as; nil for a format
    /// a renderbuffer cannot have.
    static func renderbuffer(_ format: UInt32) -> MTLPixelFormat? {
        switch format {
        case GL.RGBA4, GL.RGB5_A1, GL.RGB565, GL.RGBA8_OES, GL.RGB8_OES: return .rgba8Unorm
        case GL.DEPTH_COMPONENT16, GL.DEPTH_COMPONENT24_OES: return .depth32Float
        case GL.STENCIL_INDEX8: return .stencil8
        case GL.DEPTH24_STENCIL8_OES: return .depth32Float_stencil8
        default: return nil
        }
    }

    /// The bytes of a pixel in Metal's memory, for the bound on a stream's textures.
    static func bytes(_ format: MTLPixelFormat) -> Int {
        switch format {
        case .stencil8: return 1
        case .depth32Float_stencil8: return 8
        default: return 4
        }
    }

    /// The bytes of a width × height image and, with `levels` over one, of the smaller ones under it.
    static func bytes(_ format: MTLPixelFormat, width: Int, height: Int, levels: Int = 1, faces: Int = 1) -> Int {
        var total = 0
        for level in 0..<max(1, levels) {
            total += max(1, width >> level) * max(1, height >> level)
        }
        return total * bytes(format) * faces
    }

    /// The levels of a texture whose largest is width × height, down to 1 × 1.
    static func levels(width: Int, height: Int) -> Int {
        var levels = 1, side = max(width, height)
        while side > 1 {
            side >>= 1
            levels += 1
        }
        return levels
    }

    /// A program's colour pixels as RGBA bytes. `into` takes four bytes a
    /// pixel; nothing is written when either side is shorter than
    /// `pixels` of them (the caller checked; this is the second lock).
    static func rgba(format: UInt32, type: UInt32, from source: UnsafeRawBufferPointer, into: UnsafeMutableRawBufferPointer, pixels: Int) {
        guard let each = bytesPerPixel(format: format, type: type), pixels >= 0,
              source.count >= pixels * each, into.count >= pixels * 4 else { return }
        func put(_ i: Int, _ r: UInt32, _ g: UInt32, _ b: UInt32, _ a: UInt32) {
            into.storeBytes(of: (r | g << 8 | b << 16 | a << 24).littleEndian, toByteOffset: i * 4, as: UInt32.self)
        }
        func short(_ i: Int) -> UInt32 {
            UInt32(UInt16(littleEndian: source.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)))
        }
        switch (format, type) {
        case (GL.RGBA, GL.UNSIGNED_BYTE):
            if pixels > 0 { into.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<pixels * 4])) }
        case (GL.RGB, GL.UNSIGNED_BYTE):
            for i in 0..<pixels { put(i, UInt32(source[i * 3]), UInt32(source[i * 3 + 1]), UInt32(source[i * 3 + 2]), 255) }
        case (GL.LUMINANCE_ALPHA, GL.UNSIGNED_BYTE):
            for i in 0..<pixels {
                let l = UInt32(source[i * 2])
                put(i, l, l, l, UInt32(source[i * 2 + 1]))
            }
        case (GL.LUMINANCE, GL.UNSIGNED_BYTE):
            for i in 0..<pixels {
                let l = UInt32(source[i])
                put(i, l, l, l, 255)
            }
        case (GL.ALPHA, GL.UNSIGNED_BYTE):
            for i in 0..<pixels { put(i, 0, 0, 0, UInt32(source[i])) }
        case (GL.RGB, GL.UNSIGNED_SHORT_5_6_5):
            // Five or six bits fill eight by repeating their top ones: all ones stays all ones.
            for i in 0..<pixels {
                let v = short(i), r = v >> 11, g = v >> 5 & 0x3f, b = v & 0x1f
                put(i, r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2, 255)
            }
        case (GL.RGBA, GL.UNSIGNED_SHORT_4_4_4_4):
            for i in 0..<pixels {
                let v = short(i)
                put(i, (v >> 12) * 17, (v >> 8 & 0xf) * 17, (v >> 4 & 0xf) * 17, (v & 0xf) * 17)
            }
        case (GL.RGBA, GL.UNSIGNED_SHORT_5_5_5_1):
            for i in 0..<pixels {
                let v = short(i), r = v >> 11, g = v >> 6 & 0x1f, b = v >> 1 & 0x1f
                put(i, r << 3 | r >> 2, g << 3 | g >> 2, b << 3 | b >> 2, v & 1 == 1 ? 255 : 0)
            }
        default:
            break
        }
    }

    /// A program's depth pixels as Float32 from 0 to 1 (`depth`, four
    /// bytes a pixel) and, for a depth-stencil format, their stencil
    /// bytes (`stencil`, one a pixel).
    static func depth(format: UInt32, type: UInt32, from source: UnsafeRawBufferPointer, depth: UnsafeMutableRawBufferPointer,
                      stencil: UnsafeMutableRawBufferPointer?, pixels: Int) {
        guard let each = bytesPerPixel(format: format, type: type), pixels >= 0,
              source.count >= pixels * each, depth.count >= pixels * 4, (stencil?.count ?? pixels) >= pixels else { return }
        switch (format, type) {
        case (GL.DEPTH_COMPONENT, GL.UNSIGNED_SHORT):
            for i in 0..<pixels {
                let v = UInt16(littleEndian: source.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                depth.storeBytes(of: Float(v) / 65535, toByteOffset: i * 4, as: Float.self)
            }
        case (GL.DEPTH_COMPONENT, GL.UNSIGNED_INT):
            for i in 0..<pixels {
                let v = UInt32(littleEndian: source.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                depth.storeBytes(of: Float(Double(v) / 4294967295), toByteOffset: i * 4, as: Float.self)
            }
        case (GL.DEPTH_STENCIL_OES, GL.UNSIGNED_INT_24_8_OES):
            for i in 0..<pixels {
                let v = UInt32(littleEndian: source.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                depth.storeBytes(of: Float(Double(v >> 8) / 16777215), toByteOffset: i * 4, as: Float.self)
                stencil?[i] = UInt8(v & 0xff)
            }
        default:
            break
        }
    }

    /// One row of what was drawn, as glReadPixels gives it (RGBA bytes).
    /// A window's surface is kept as BGRA, which is what the Mac shows.
    static func read(row source: UnsafeRawBufferPointer, bgra: Bool, into: UnsafeMutableRawBufferPointer, pixels: Int) {
        guard pixels > 0, source.count >= pixels * 4, into.count >= pixels * 4 else { return }
        if !bgra {
            into.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<pixels * 4]))
            return
        }
        for i in 0..<pixels {
            let v = source.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian
            into.storeBytes(of: (v & 0xff00_ff00 | v >> 16 & 0xff | (v & 0xff) << 16).littleEndian, toByteOffset: i * 4, as: UInt32.self)
        }
    }

    // MARK: Vertices

    /// The bytes of one number of a vertex array; nil for a type OpenGL ES 2.0 has none of.
    static func componentBytes(_ type: UInt32) -> Int? {
        switch type {
        case GL.BYTE, GL.UNSIGNED_BYTE: return 1
        case GL.SHORT, GL.UNSIGNED_SHORT: return 2
        case GL.FLOAT, GL.FIXED: return 4
        default: return nil
        }
    }

    /// Metal's name for `size` numbers of a type, as a vertex shader's
    /// float attribute takes them. GL_FIXED has none: its numbers are
    /// turned into floats before Metal sees them, so it is given as floats.
    static func vertex(type: UInt32, size: Int, normalized: Bool) -> MTLVertexFormat? {
        let formats: [MTLVertexFormat]
        switch (type, normalized) {
        case (GL.BYTE, false): formats = [.char, .char2, .char3, .char4]
        case (GL.BYTE, true): formats = [.charNormalized, .char2Normalized, .char3Normalized, .char4Normalized]
        case (GL.UNSIGNED_BYTE, false): formats = [.uchar, .uchar2, .uchar3, .uchar4]
        case (GL.UNSIGNED_BYTE, true): formats = [.ucharNormalized, .uchar2Normalized, .uchar3Normalized, .uchar4Normalized]
        case (GL.SHORT, false): formats = [.short, .short2, .short3, .short4]
        case (GL.SHORT, true): formats = [.shortNormalized, .short2Normalized, .short3Normalized, .short4Normalized]
        case (GL.UNSIGNED_SHORT, false): formats = [.ushort, .ushort2, .ushort3, .ushort4]
        case (GL.UNSIGNED_SHORT, true): formats = [.ushortNormalized, .ushort2Normalized, .ushort3Normalized, .ushort4Normalized]
        case (GL.FLOAT, _), (GL.FIXED, _): formats = [.float, .float2, .float3, .float4]
        default: return nil
        }
        return (1...4).contains(size) ? formats[size - 1] : nil
    }

    // MARK: State

    static func compare(_ function: UInt32) -> MTLCompareFunction? {
        switch function {
        case GL.NEVER: return .never
        case GL.LESS: return .less
        case GL.EQUAL: return .equal
        case GL.LEQUAL: return .lessEqual
        case GL.GREATER: return .greater
        case GL.NOTEQUAL: return .notEqual
        case GL.GEQUAL: return .greaterEqual
        case GL.ALWAYS: return .always
        default: return nil
        }
    }

    static func stencil(_ operation: UInt32) -> MTLStencilOperation? {
        switch operation {
        case GL.KEEP: return .keep
        case GL.ZERO: return .zero
        case GL.REPLACE: return .replace
        case GL.INCR: return .incrementClamp
        case GL.DECR: return .decrementClamp
        case GL.INVERT: return .invert
        case GL.INCR_WRAP: return .incrementWrap
        case GL.DECR_WRAP: return .decrementWrap
        default: return nil
        }
    }

    /// `source`: GL_SRC_ALPHA_SATURATE is a factor for what is drawn only, as OpenGL ES 2.0 has it.
    static func blend(factor: UInt32, source: Bool) -> MTLBlendFactor? {
        switch factor {
        case GL.ZERO: return .zero
        case GL.ONE: return .one
        case GL.SRC_COLOR: return .sourceColor
        case GL.ONE_MINUS_SRC_COLOR: return .oneMinusSourceColor
        case GL.SRC_ALPHA: return .sourceAlpha
        case GL.ONE_MINUS_SRC_ALPHA: return .oneMinusSourceAlpha
        case GL.DST_ALPHA: return .destinationAlpha
        case GL.ONE_MINUS_DST_ALPHA: return .oneMinusDestinationAlpha
        case GL.DST_COLOR: return .destinationColor
        case GL.ONE_MINUS_DST_COLOR: return .oneMinusDestinationColor
        case GL.SRC_ALPHA_SATURATE: return source ? .sourceAlphaSaturated : nil
        case GL.CONSTANT_COLOR: return .blendColor
        case GL.ONE_MINUS_CONSTANT_COLOR: return .oneMinusBlendColor
        case GL.CONSTANT_ALPHA: return .blendAlpha
        case GL.ONE_MINUS_CONSTANT_ALPHA: return .oneMinusBlendAlpha
        default: return nil
        }
    }

    static func blend(equation: UInt32) -> MTLBlendOperation? {
        switch equation {
        case GL.FUNC_ADD: return .add
        case GL.FUNC_SUBTRACT: return .subtract
        case GL.FUNC_REVERSE_SUBTRACT: return .reverseSubtract
        default: return nil
        }
    }

    // MARK: Uniforms

    /// What a uniform's value is made of.
    struct Uniform {
        enum Kind { case float, int, bool, sampler }
        var kind: Kind
        var columns: Int
        var rows: Int
    }

    /// nil for a type no uniform has.
    static func uniform(_ type: UInt32) -> Uniform? {
        switch type {
        case GL.FLOAT: return Uniform(kind: .float, columns: 1, rows: 1)
        case GL.FLOAT_VEC2: return Uniform(kind: .float, columns: 1, rows: 2)
        case GL.FLOAT_VEC3: return Uniform(kind: .float, columns: 1, rows: 3)
        case GL.FLOAT_VEC4: return Uniform(kind: .float, columns: 1, rows: 4)
        case GL.INT: return Uniform(kind: .int, columns: 1, rows: 1)
        case GL.INT_VEC2: return Uniform(kind: .int, columns: 1, rows: 2)
        case GL.INT_VEC3: return Uniform(kind: .int, columns: 1, rows: 3)
        case GL.INT_VEC4: return Uniform(kind: .int, columns: 1, rows: 4)
        case GL.BOOL: return Uniform(kind: .bool, columns: 1, rows: 1)
        case GL.BOOL_VEC2: return Uniform(kind: .bool, columns: 1, rows: 2)
        case GL.BOOL_VEC3: return Uniform(kind: .bool, columns: 1, rows: 3)
        case GL.BOOL_VEC4: return Uniform(kind: .bool, columns: 1, rows: 4)
        case GL.FLOAT_MAT2: return Uniform(kind: .float, columns: 2, rows: 2)
        case GL.FLOAT_MAT3: return Uniform(kind: .float, columns: 3, rows: 3)
        case GL.FLOAT_MAT4: return Uniform(kind: .float, columns: 4, rows: 4)
        case GL.SAMPLER_2D, GL.SAMPLER_CUBE: return Uniform(kind: .sampler, columns: 1, rows: 1)
        default: return nil
        }
    }
}
