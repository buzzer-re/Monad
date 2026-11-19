//
//  GLShaders.swift — what a program's GLSL ES shaders become for Metal,
//  as the part that turns them into Metal's language hands it to the part
//  that draws (a Linux program's OpenGL ES calls, carried out on the Mac:
//  GuestWM/mwm_gl_wire.h). The shaders are a guest's text: nothing of it
//  reaches Metal's compiler as it is. It is read, checked and written
//  anew in Metal's language here on the Mac.
//
//  What the Metal source is like, which both parts hold to:
//
//  - Two functions: `monad_vertex` and `monad_fragment`.
//  - The uniforms are one block of bytes, bound as buffer 30 in both
//    stages. Its first 16 bytes are the drawing's own: a Float32 at 0
//    that gl_Position.y is multiplied by, and a Float32 at 4, the height
//    in pixels of what is drawn to. Metal's y points up as OpenGL's does,
//    but its rows are counted from the top: drawn as it is (the float is
//    1), a picture's row 0 is its top, which is how a window's surface is
//    shown; drawn turned over (-1), row 0 is OpenGL's bottom row, which
//    is how a texture's memory lies (glTexImage2D gives the bottom row
//    first), so drawing into a texture or a renderbuffer is turned over.
//    gl_FragCoord.y, which OpenGL counts from the bottom, is the height
//    less Metal's y when the float is 1, and Metal's y as it is when the
//    float is -1. gl_FrontFacing is Metal's front_facing as it is: the
//    drawing part sets the winding for what it draws to, so that Metal's
//    front is OpenGL's. The program's uniforms follow from byte 16, where
//    `GLUniform` says.
//  - gl_Position's z is brought from OpenGL's -w…w to Metal's 0…w.
//  - A vertex attribute comes in as `attribute(location)`; a matrix takes
//    a location for each column.
//  - A sampler uniform is `texture(n)` with `sampler(n)`, the same n, in
//    whichever stage uses it; n is below 16.
//  - The fragment function returns one colour.
//

import Foundation

enum GLShaderStage: Equatable, Sendable {
    case vertex, fragment
}

/// A vertex attribute a linked program takes.
struct GLAttribute: Equatable, Sendable {
    var name: String
    /// GL.FLOAT, GL.FLOAT_VEC2…4, GL.FLOAT_MAT2…4.
    var type: UInt32
    var location: Int
}

/// A uniform a linked program has, as glGetActiveUniform tells it.
struct GLUniform: Equatable, Sendable {
    /// "color", "lights[0]" (an array), "material.shininess" (a struct's member).
    var name: String
    /// GL.FLOAT … GL.FLOAT_MAT4, GL.INT…, GL.BOOL…, GL.SAMPLER_2D, GL.SAMPLER_CUBE.
    var type: UInt32
    /// How many elements (1 when it is no array).
    var size: Int
    /// Of element 0; element i is at location + i.
    var location: Int
    /// Where element 0's value lies in the uniform block, and how many
    /// bytes on the next element's does. Nothing to do with a sampler.
    var offset: Int
    var stride: Int
    /// A value is `columns` columns of `rows` numbers (Float32, or Int32
    /// for the int and bool types: a bool is 0 or 1), each column
    /// `columnStride` bytes after the one before.
    var columns: Int
    var rows: Int
    var columnStride: Int
    /// A sampler: the Metal texture and sampler index of element 0
    /// (element i takes the next); nil for any other uniform.
    var texture: Int?
}

/// A program that linked: its Metal source and what it takes.
struct GLLinkedProgram: Equatable, Sendable {
    var metal: String
    var attributes: [GLAttribute]
    var uniforms: [GLUniform]
    /// The size of the uniform block, the first 16 bytes included.
    var uniformBytes: Int
}

/// Turns GLSL ES 1.00 into Metal's language. The drawing part is handed
/// one, so that its tests can draw with Metal source of their own.
protocol GLShaderTranslating: Sendable {
    /// A shader that compiled (to hand to `link`), or nil; and what
    /// glGetShaderInfoLog says, empty when there is nothing to say.
    func compile(_ source: String, stage: GLShaderStage) -> (shader: AnyObject?, log: String)
    /// The two shaders as one program, or nil and why. `attributeLocations`:
    /// what glBindAttribLocation asked for; the others are given the free ones.
    func link(vertex: AnyObject, fragment: AnyObject, attributeLocations: [String: Int]) -> (program: GLLinkedProgram?, log: String)
}
