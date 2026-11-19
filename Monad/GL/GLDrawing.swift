//
//  GLDrawing.swift — where a Linux VM program's drawing commands meet
//  this Mac's GPU: what MonadHost's connection for drawing (GuestGLClient)
//  is handed to carry a stream out with, made of the part that reads the
//  commands and draws with Metal (GLStream) and the part that turns the
//  program's shaders into Metal's language (GLSLTranslator).
//

import Foundation
import IOSurface
import Metal

extension GLStream: GuestGLDrawing {}

enum GLDrawing {
    /// What carries out one stream. On a Mac with no Metal device (there is
    /// none such that runs Monad) every stream is ended at its first byte.
    static func make(present: @escaping (UInt32, IOSurface) -> Void, reply: @escaping (Data) -> Void) -> GuestGLDrawing {
        guard let device = MTLCreateSystemDefaultDevice() else { return Refusing() }
        return GLStream(device: device, translator: GLSLTranslator(), reply: reply) { surface, picture, _, _ in present(surface, picture) }
    }

    private final class Refusing: GuestGLDrawing {
        func feed(_ data: Data) -> Bool { false }
        func close() {}
    }
}
