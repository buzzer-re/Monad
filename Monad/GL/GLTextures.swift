//
//  GLTextures.swift — the memory a Linux program's OpenGL ES drawing
//  fills and reads (GLStream.swift): buffers, textures with their levels
//  and faces, renderbuffers, and what framebuffers have attached.
//
//  Pixels go to the GPU the way draws do, in the order the program made
//  its calls: a texture that is drawn with and then given new pixels
//  shows the old ones in the draw before and the new ones after, with no
//  waiting for the GPU in between. A buffer's bytes are read by the GPU
//  where they lie, so when bytes that draws still read are changed, the
//  buffer gets other memory and the draws keep the old.
//

import Foundation
import Metal

/// Where an image of a texture lies: a slice and level of a Metal texture.
struct GLPlace {
    let texture: MTLTexture
    let slice: Int
    let level: Int
}

extension GLStream {
    // MARK: Buffers

    private func buffer(_ context: GLContext, _ target: UInt32) -> GLBuffer?? {
        switch target {
        case GL.ARRAY_BUFFER: return .some(context.arrayBuffer)
        case GL.ELEMENT_ARRAY_BUFFER: return .some(context.elementBuffer)
        default: return nil
        }
    }

    func bindBuffer(_ context: GLContext, target: UInt32, name: UInt32) {
        guard target == GL.ARRAY_BUFFER || target == GL.ELEMENT_ARRAY_BUFFER else { return context.fail(GL.INVALID_ENUM) }
        var buffer: GLBuffer?
        if name != 0 {
            buffer = context.share.buffers[name]
            if buffer == nil {
                // A name comes to be when it is first bound.
                guard budget.objects < GLLimits.objects else { return context.fail(GL.OUT_OF_MEMORY) }
                buffer = GLBuffer(name: name, budget: budget)
                context.share.buffers[name] = buffer
            }
        }
        if target == GL.ARRAY_BUFFER {
            context.arrayBuffer = buffer
        } else {
            context.elementBuffer = buffer
        }
    }

    func deleteBuffer(_ context: GLContext, name: UInt32) {
        guard let buffer = context.share.buffers.removeValue(forKey: name) else { return }
        // Where this context has it bound, it is bound no more; another context keeps what it has bound.
        if context.arrayBuffer === buffer { context.arrayBuffer = nil }
        if context.elementBuffer === buffer { context.elementBuffer = nil }
        for index in context.arrays.indices where context.arrays[index].buffer === buffer {
            context.arrays[index].buffer = nil
        }
    }

    func bufferData(_ context: GLContext, target: UInt32, size: Int, usage: UInt32, data: UnsafeRawBufferPointer?) {
        guard let bound = buffer(context, target), [GL.STREAM_DRAW, GL.STATIC_DRAW, GL.DYNAMIC_DRAW].contains(usage) else {
            return context.fail(GL.INVALID_ENUM)
        }
        guard size >= 0 else { return context.fail(GL.INVALID_VALUE) }
        guard let buffer = bound, data == nil || data?.count == size else { return context.fail(GL.INVALID_OPERATION) }
        guard budget.bufferBytes - buffer.size + size <= GLLimits.bufferBytes else { return context.fail(GL.OUT_OF_MEMORY) }
        var memory: MTLBuffer?
        if size > 0 {
            // Metal's buffers come zeroed: without data, there is nothing of anything else in it.
            guard let fresh = device.makeBuffer(length: (size + 3) & ~3, options: .storageModeShared), fresh.length >= size else {
                return context.fail(GL.OUT_OF_MEMORY)
            }
            if let data {
                UnsafeMutableRawBufferPointer(start: fresh.contents(), count: size).copyMemory(from: data)
            }
            memory = fresh
        }
        buffer.replace(memory, size: size)
    }

    func bufferSubData(_ context: GLContext, target: UInt32, offset: Int, data: UnsafeRawBufferPointer) {
        guard let bound = buffer(context, target) else { return context.fail(GL.INVALID_ENUM) }
        guard let buffer = bound else { return context.fail(GL.INVALID_OPERATION) }
        guard offset >= 0, offset + data.count <= buffer.size else { return context.fail(GL.INVALID_VALUE) }
        guard data.count > 0, let memory = buffer.memory else { return }
        if buffer.isDrawn(offset..<offset + data.count), commands != nil {
            // Draws not yet done read these bytes. They keep them: the buffer goes on in a copy with the change,
            // unless that would be more than a command buffer may hold, in which case the draws are done first.
            // (Bytes no draw reads yet are written where they lie: a program that fills a buffer piece by piece,
            // drawing each, costs no copies.)
            if budget.retired + arena.pending + buffer.size <= GLLimits.pendingBytes,
               let fresh = device.makeBuffer(length: memory.length, options: .storageModeShared), fresh.length >= memory.length {
                fresh.contents().copyMemory(from: memory.contents(), byteCount: memory.length)
                buffer.replace(fresh, size: buffer.size)
            } else {
                flush()
            }
        }
        buffer.ranges.removeAll()
        guard let bytes = buffer.bytes else { return }
        UnsafeMutableRawBufferPointer(rebasing: bytes[offset..<offset + data.count]).copyMemory(from: data)
    }

    // MARK: Textures: their memory

    func makeTexture(_ format: MTLPixelFormat, width: Int, height: Int, levels: Int = 1, cube: Bool = false) -> MTLTexture? {
        guard (1...GLLimits.side).contains(width), (1...GLLimits.side).contains(height), (1...GLLimits.levels).contains(levels) else { return nil }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = cube ? .typeCube : .type2D
        descriptor.pixelFormat = format
        descriptor.width = width
        descriptor.height = height
        descriptor.mipmapLevelCount = levels
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// Where an image that was given lies; nil for one that was not.
    func place(_ texture: GLTexture, face: Int, level: Int) -> GLPlace? {
        guard let image = texture[face, level] else { return nil }
        if let stray = image.stray { return GLPlace(texture: stray, slice: 0, level: 0) }
        guard let storage = texture.storage, level < storage.mipmapLevelCount else { return nil }
        return GLPlace(texture: storage, slice: texture.isCube ? face : 0, level: level)
    }

    /// Whether an image of this size and format is what the texture's memory has at a level.
    private func fits(_ texture: GLTexture, level: Int, width: Int, height: Int, format: MTLPixelFormat) -> Bool {
        guard let storage = texture.storage, storage.pixelFormat == format, level < storage.mipmapLevelCount else { return false }
        return max(1, storage.width >> level) == width && max(1, storage.height >> level) == height
    }

    private func copy(_ source: MTLTexture, slice: Int, level: Int, to destination: MTLTexture, slice destinationSlice: Int, level destinationLevel: Int) {
        let width = max(1, source.width >> level), height = max(1, source.height >> level)
        guard source !== destination, source.pixelFormat == destination.pixelFormat,
              width == max(1, destination.width >> destinationLevel), height == max(1, destination.height >> destinationLevel),
              level < source.mipmapLevelCount, destinationLevel < destination.mipmapLevelCount, let blit = blitEncoder() else { return }
        blit.copy(from: source, sourceSlice: slice, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: destination, destinationSlice: destinationSlice, destinationLevel: destinationLevel, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    }

    /// Gives the texture's memory all its levels, keeping what is in it. False when there is no memory for that.
    private func grow(_ texture: GLTexture) -> Bool {
        texture.mipped = true
        guard let old = texture.storage else { return true }
        let levels = GLFormats.levels(width: old.width, height: old.height)
        guard old.mipmapLevelCount < levels else { return true }
        let bytes = GLFormats.bytes(old.pixelFormat, width: old.width, height: old.height, levels: levels, faces: texture.faces)
        guard budget.textureBytes - texture.storageBytes + bytes <= GLLimits.textureBytes,
              let fresh = makeTexture(old.pixelFormat, width: old.width, height: old.height, levels: levels, cube: texture.isCube) else { return false }
        for face in 0..<texture.faces {
            if let image = texture[face, 0], image.stray == nil { copy(old, slice: face, level: 0, to: fresh, slice: face, level: 0) }
        }
        texture.release(texture.storageBytes)
        texture.charge(bytes)
        texture.storage = fresh
        texture.storageBytes = bytes
        return true
    }

    /// Makes an image of a texture what glTexImage2D says: this size and
    /// format, its pixels not yet given. False, with the texture as it
    /// was, when there is no memory for it.
    ///
    /// The images that agree with the first (level 0 of the first face)
    /// lie in one Metal texture, which is what a complete texture is
    /// drawn with. One that does not agree has memory of its own until it
    /// does, so that the levels may come in any order, as OpenGL has it.
    func define(_ texture: GLTexture, face: Int, level: Int, width: Int, height: Int, format: UInt32) -> Bool {
        let pixel = GLFormats.texture(format)
        func stray(_ image: GLTexture.Image?) -> Int {
            guard let own = image?.stray else { return 0 }
            return GLFormats.bytes(own.pixelFormat, width: own.width, height: own.height)
        }
        let old = texture[face, level]
        if width == 0 || height == 0 {
            // No pixels: no image.
            texture.release(stray(old))
            texture[face, level] = nil
            return true
        }
        if level > 0, !texture.mipped, !grow(texture) { return false }

        if face == 0, level == 0, !fits(texture, level: 0, width: width, height: height, format: pixel) {
            // The first image sets what the texture's memory is like: other memory, and the images that were in the old
            // go where they now belong.
            let levels = texture.mipped ? GLFormats.levels(width: width, height: height) : 1
            let bytes = GLFormats.bytes(pixel, width: width, height: height, levels: levels, faces: texture.faces)
            guard budget.textureBytes - texture.storageBytes + bytes <= GLLimits.textureBytes,
                  let fresh = makeTexture(pixel, width: width, height: height, levels: levels, cube: texture.isCube) else { return false }
            let before = texture.storage, beforeBytes = texture.storageBytes
            texture.storage = fresh
            texture.storageBytes = bytes
            texture.charge(bytes)
            texture[0, 0] = GLTexture.Image(width: width, height: height, format: format, stray: nil)
            for otherFace in 0..<texture.faces {
                for otherLevel in 0..<GLLimits.levels where otherFace != 0 || otherLevel != 0 {
                    guard var image = texture[otherFace, otherLevel] else { continue }
                    let imageFormat = GLFormats.texture(image.format)
                    let agrees = fits(texture, level: otherLevel, width: image.width, height: image.height, format: imageFormat)
                    if let own = image.stray {
                        guard agrees else { continue }
                        copy(own, slice: 0, level: 0, to: fresh, slice: otherFace, level: otherLevel)
                        texture.release(stray(image))
                        image.stray = nil
                        texture[otherFace, otherLevel] = image
                    } else if let before {
                        if agrees {
                            copy(before, slice: otherFace, level: otherLevel, to: fresh, slice: otherFace, level: otherLevel)
                        } else if budget.textureBytes + GLFormats.bytes(imageFormat, width: image.width, height: image.height) <= GLLimits.textureBytes + beforeBytes,
                                  let own = makeTexture(imageFormat, width: image.width, height: image.height) {
                            copy(before, slice: otherFace, level: otherLevel, to: own, slice: 0, level: 0)
                            texture.charge(GLFormats.bytes(imageFormat, width: image.width, height: image.height))
                            image.stray = own
                            texture[otherFace, otherLevel] = image
                        } else {
                            texture[otherFace, otherLevel] = nil
                        }
                    }
                }
            }
            texture.release(beforeBytes)
            return true
        }

        var image = GLTexture.Image(width: width, height: height, format: format, stray: nil)
        if fits(texture, level: level, width: width, height: height, format: pixel) {
            texture.release(stray(old))
        } else if let own = old?.stray, own.width == width, own.height == height, own.pixelFormat == pixel {
            image.stray = own
        } else {
            let bytes = GLFormats.bytes(pixel, width: width, height: height)
            guard budget.textureBytes - stray(old) + bytes <= GLLimits.textureBytes, let own = makeTexture(pixel, width: width, height: height) else {
                return false
            }
            texture.release(stray(old))
            texture.charge(bytes)
            image.stray = own
        }
        texture[face, level] = image
        return true
    }

    /// A program's pixels into a rectangle of an image. False when there is no memory for their way there.
    private func upload(_ place: GLPlace, x: Int, y: Int, width: Int, height: Int, format: UInt32, type: UInt32, data: UnsafeRawBufferPointer) -> Bool {
        let pixels = width * height
        guard pixels > 0, let span = arena.allocate(pixels * 4) else { return false }
        let origin = MTLOrigin(x: x, y: y, z: 0), size = MTLSize(width: width, height: height, depth: 1)
        if format == GL.DEPTH_STENCIL_OES {
            guard let stencil = arena.allocate(pixels, alignment: 4) else { return false }
            GLFormats.depth(format: format, type: type, from: data, depth: span.bytes, stencil: stencil.bytes, pixels: pixels)
            guard let blit = blitEncoder() else { return false }
            blit.copy(from: span.buffer, sourceOffset: span.offset, sourceBytesPerRow: width * 4, sourceBytesPerImage: pixels * 4, sourceSize: size,
                      to: place.texture, destinationSlice: place.slice, destinationLevel: place.level, destinationOrigin: origin, options: .depthFromDepthStencil)
            blit.copy(from: stencil.buffer, sourceOffset: stencil.offset, sourceBytesPerRow: width, sourceBytesPerImage: pixels, sourceSize: size,
                      to: place.texture, destinationSlice: place.slice, destinationLevel: place.level, destinationOrigin: origin, options: .stencilFromDepthStencil)
            return true
        }
        if format == GL.DEPTH_COMPONENT {
            GLFormats.depth(format: format, type: type, from: data, depth: span.bytes, stencil: nil, pixels: pixels)
        } else {
            GLFormats.rgba(format: format, type: type, from: data, into: span.bytes, pixels: pixels)
        }
        guard let blit = blitEncoder() else { return false }
        blit.copy(from: span.buffer, sourceOffset: span.offset, sourceBytesPerRow: width * 4, sourceBytesPerImage: pixels * 4, sourceSize: size,
                  to: place.texture, destinationSlice: place.slice, destinationLevel: place.level, destinationOrigin: origin)
        return true
    }

    // MARK: Textures: the calls

    /// GL_TEXTURE_2D, or a face of a cube: what it is bound as, and which face.
    private static func imageTarget(_ target: UInt32) -> (binding: UInt32, face: Int)? {
        if target == GL.TEXTURE_2D { return (GL.TEXTURE_2D, 0) }
        if target >= GL.TEXTURE_CUBE_MAP_POSITIVE_X, target <= GL.TEXTURE_CUBE_MAP_NEGATIVE_Z {
            return (GL.TEXTURE_CUBE_MAP, Int(target - GL.TEXTURE_CUBE_MAP_POSITIVE_X))
        }
        return nil
    }

    func bindTexture(_ context: GLContext, target: UInt32, name: UInt32) {
        guard target == GL.TEXTURE_2D || target == GL.TEXTURE_CUBE_MAP else { return context.fail(GL.INVALID_ENUM) }
        var texture: GLTexture?
        if name != 0 {
            texture = context.share.textures[name]
            if texture == nil {
                guard budget.objects < GLLimits.objects else { return context.fail(GL.OUT_OF_MEMORY) }
                texture = GLTexture(name: name, budget: budget, target: target)
                context.share.textures[name] = texture
            }
            // A texture is what it was first bound as.
            guard texture?.target == target else { return context.fail(GL.INVALID_OPERATION) }
        }
        if target == GL.TEXTURE_2D {
            context.units[context.unit].flat = texture
        } else {
            context.units[context.unit].cube = texture
        }
    }

    func deleteTexture(_ context: GLContext, name: UInt32) {
        guard let texture = context.share.textures.removeValue(forKey: name) else { return }
        for index in context.units.indices {
            if context.units[index].flat === texture { context.units[index].flat = nil }
            if context.units[index].cube === texture { context.units[index].cube = nil }
        }
        context.framebuffer?.detach(texture)
    }

    func texParameter(_ context: GLContext, target: UInt32, name: UInt32, value: UInt32) {
        guard target == GL.TEXTURE_2D || target == GL.TEXTURE_CUBE_MAP else { return context.fail(GL.INVALID_ENUM) }
        let texture = context.texture(target)
        switch name {
        case GL.TEXTURE_MIN_FILTER:
            guard [GL.NEAREST, GL.LINEAR, GL.NEAREST_MIPMAP_NEAREST, GL.LINEAR_MIPMAP_NEAREST, GL.NEAREST_MIPMAP_LINEAR,
                   GL.LINEAR_MIPMAP_LINEAR].contains(value) else { return context.fail(GL.INVALID_ENUM) }
            texture.minFilter = value
        case GL.TEXTURE_MAG_FILTER:
            guard value == GL.NEAREST || value == GL.LINEAR else { return context.fail(GL.INVALID_ENUM) }
            texture.magFilter = value
        case GL.TEXTURE_WRAP_S, GL.TEXTURE_WRAP_T:
            guard [GL.REPEAT, GL.CLAMP_TO_EDGE, GL.MIRRORED_REPEAT].contains(value) else { return context.fail(GL.INVALID_ENUM) }
            if name == GL.TEXTURE_WRAP_S {
                texture.wrapS = value
            } else {
                texture.wrapT = value
            }
        default:
            context.fail(GL.INVALID_ENUM)
        }
    }

    func texImage(_ context: GLContext, target: UInt32, level: Int, internalFormat: UInt32, width: Int, height: Int, border: Int,
                  format: UInt32, type: UInt32, data: UnsafeRawBufferPointer?) {
        guard let (binding, face) = Self.imageTarget(target), GLFormats.isTextureFormat(format), GLFormats.isPixelType(type) else {
            return context.fail(GL.INVALID_ENUM)
        }
        guard GLFormats.isTextureFormat(internalFormat), (0..<GLLimits.levels).contains(level), border == 0, width >= 0, height >= 0,
              width <= GLLimits.side >> level, height <= GLLimits.side >> level, binding == GL.TEXTURE_2D || width == height else {
            return context.fail(GL.INVALID_VALUE)
        }
        // A depth texture is flat and has one level (OES_depth_texture).
        guard internalFormat == format, let each = GLFormats.bytesPerPixel(format: format, type: type),
              !GLFormats.isDepth(format) || (binding == GL.TEXTURE_2D && level == 0), data == nil || data?.count == width * height * each else {
            return context.fail(GL.INVALID_OPERATION)
        }
        let texture = context.texture(binding)
        guard define(texture, face: face, level: level, width: width, height: height, format: format) else { return context.fail(GL.OUT_OF_MEMORY) }
        guard width > 0, height > 0, let place = place(texture, face: face, level: level) else { return }
        if let data {
            if !upload(place, x: 0, y: 0, width: width, height: height, format: format, type: type, data: data) { context.fail(GL.OUT_OF_MEMORY) }
        } else {
            clear(place.texture, slice: place.slice, level: place.level, alpha: GLFormats.hasAlpha(format))
        }
    }

    func texSubImage(_ context: GLContext, target: UInt32, level: Int, xOffset: Int, yOffset: Int, width: Int, height: Int,
                     format: UInt32, type: UInt32, data: UnsafeRawBufferPointer?) {
        guard let (binding, face) = Self.imageTarget(target), GLFormats.isTextureFormat(format), GLFormats.isPixelType(type) else {
            return context.fail(GL.INVALID_ENUM)
        }
        guard (0..<GLLimits.levels).contains(level) else { return context.fail(GL.INVALID_VALUE) }
        let texture = context.texture(binding)
        guard let image = texture[face, level], let place = place(texture, face: face, level: level) else { return context.fail(GL.INVALID_OPERATION) }
        guard xOffset >= 0, yOffset >= 0, width >= 0, height >= 0, xOffset + width <= image.width, yOffset + height <= image.height else {
            return context.fail(GL.INVALID_VALUE)
        }
        guard format == image.format, let each = GLFormats.bytesPerPixel(format: format, type: type), let data, data.count == width * height * each else {
            return context.fail(GL.INVALID_OPERATION)
        }
        guard width > 0, height > 0 else { return }
        if !upload(place, x: xOffset, y: yOffset, width: width, height: height, format: format, type: type, data: data) { context.fail(GL.OUT_OF_MEMORY) }
    }

    func generateMipmap(_ context: GLContext, target: UInt32) {
        guard target == GL.TEXTURE_2D || target == GL.TEXTURE_CUBE_MAP else { return context.fail(GL.INVALID_ENUM) }
        let texture = context.texture(target)
        // Of a first level that is there, and of a cube whose faces agree. A depth texture has one level (OES_depth_texture).
        guard let base = texture[0, 0], !GLFormats.isDepth(base.format) else { return context.fail(GL.INVALID_OPERATION) }
        for face in 0..<texture.faces {
            guard let image = texture[face, 0], image.stray == nil, image.width == base.width, image.height == base.height, image.format == base.format,
                  !texture.isCube || image.width == image.height else { return context.fail(GL.INVALID_OPERATION) }
        }
        guard grow(texture) else { return context.fail(GL.OUT_OF_MEMORY) }
        guard let storage = texture.storage, storage.mipmapLevelCount > 1, let blit = blitEncoder() else { return }
        blit.generateMipmaps(for: storage)
        for face in 0..<texture.faces {
            for level in 1..<storage.mipmapLevelCount {
                if let own = texture[face, level]?.stray { texture.release(GLFormats.bytes(own.pixelFormat, width: own.width, height: own.height)) }
                texture[face, level] = GLTexture.Image(width: max(1, base.width >> level), height: max(1, base.height >> level), format: base.format, stray: nil)
            }
        }
    }

    func copyTexImage(_ context: GLContext, target: UInt32, level: Int, format: UInt32, x: Int, y: Int, width: Int, height: Int, border: Int) {
        guard let (binding, face) = Self.imageTarget(target), GLFormats.isTextureFormat(format), !GLFormats.isDepth(format) else {
            return context.fail(GL.INVALID_ENUM)
        }
        guard (0..<GLLimits.levels).contains(level), border == 0, width >= 0, height >= 0, width <= GLLimits.side >> level,
              height <= GLLimits.side >> level, binding == GL.TEXTURE_2D || width == height else { return context.fail(GL.INVALID_VALUE) }
        guard let source = readTarget(context).target else { return context.fail(GL.INVALID_FRAMEBUFFER_OPERATION) }
        // A texture cannot keep what was not drawn: alpha, of something that has none.
        guard source.color != nil, source.alpha || !GLFormats.hasAlpha(format) else { return context.fail(GL.INVALID_OPERATION) }
        let texture = context.texture(binding)
        guard define(texture, face: face, level: level, width: width, height: height, format: format) else { return context.fail(GL.OUT_OF_MEMORY) }
        // An image that is itself what is read stays as it is: Metal reads nothing while drawing to it.
        guard width > 0, height > 0, let place = place(texture, face: face, level: level), place.texture !== source.color else { return }
        clear(place.texture, slice: place.slice, level: place.level, alpha: GLFormats.hasAlpha(format))
        copy(from: source, x: x, y: y, to: place, xOffset: 0, yOffset: 0, width: width, height: height, format: format)
    }

    func copyTexSubImage(_ context: GLContext, target: UInt32, level: Int, xOffset: Int, yOffset: Int, x: Int, y: Int, width: Int, height: Int) {
        guard let (binding, face) = Self.imageTarget(target) else { return context.fail(GL.INVALID_ENUM) }
        guard (0..<GLLimits.levels).contains(level) else { return context.fail(GL.INVALID_VALUE) }
        let texture = context.texture(binding)
        guard let image = texture[face, level], let place = place(texture, face: face, level: level) else { return context.fail(GL.INVALID_OPERATION) }
        guard xOffset >= 0, yOffset >= 0, width >= 0, height >= 0, xOffset + width <= image.width, yOffset + height <= image.height else {
            return context.fail(GL.INVALID_VALUE)
        }
        guard let source = readTarget(context).target else { return context.fail(GL.INVALID_FRAMEBUFFER_OPERATION) }
        guard !GLFormats.isDepth(image.format), source.color != nil, source.alpha || !GLFormats.hasAlpha(image.format) else {
            return context.fail(GL.INVALID_OPERATION)
        }
        copy(from: source, x: x, y: y, to: place, xOffset: xOffset, yOffset: yOffset, width: width, height: height, format: image.format)
    }

    // MARK: Renderbuffers and framebuffers

    func bindRenderbuffer(_ context: GLContext, target: UInt32, name: UInt32) {
        guard target == GL.RENDERBUFFER else { return context.fail(GL.INVALID_ENUM) }
        var renderbuffer: GLRenderbuffer?
        if name != 0 {
            renderbuffer = context.share.renderbuffers[name]
            if renderbuffer == nil {
                guard budget.objects < GLLimits.objects else { return context.fail(GL.OUT_OF_MEMORY) }
                renderbuffer = GLRenderbuffer(name: name, budget: budget)
                context.share.renderbuffers[name] = renderbuffer
            }
        }
        context.renderbuffer = renderbuffer
    }

    func deleteRenderbuffer(_ context: GLContext, name: UInt32) {
        guard let renderbuffer = context.share.renderbuffers.removeValue(forKey: name) else { return }
        if context.renderbuffer === renderbuffer { context.renderbuffer = nil }
        context.framebuffer?.detach(renderbuffer)
    }

    func renderbufferStorage(_ context: GLContext, target: UInt32, format: UInt32, width: Int, height: Int) {
        guard target == GL.RENDERBUFFER, let pixel = GLFormats.renderbuffer(format) else { return context.fail(GL.INVALID_ENUM) }
        guard (0...GLLimits.side).contains(width), (0...GLLimits.side).contains(height) else { return context.fail(GL.INVALID_VALUE) }
        guard let renderbuffer = context.renderbuffer else { return context.fail(GL.INVALID_OPERATION) }
        guard width > 0, height > 0 else {
            renderbuffer.replace(nil, width: width, height: height, format: format, bytes: 0)
            return
        }
        let bytes = GLFormats.bytes(pixel, width: width, height: height)
        guard budget.textureBytes - renderbuffer.heldBytes + bytes <= GLLimits.textureBytes,
              let memory = makeTexture(pixel, width: width, height: height) else { return context.fail(GL.OUT_OF_MEMORY) }
        renderbuffer.replace(memory, width: width, height: height, format: format, bytes: bytes)
        clear(memory, slice: 0, level: 0, alpha: format != GL.RGB565 && format != GL.RGB8_OES)
    }

    func bindFramebuffer(_ context: GLContext, target: UInt32, name: UInt32) {
        guard target == GL.FRAMEBUFFER else { return context.fail(GL.INVALID_ENUM) }
        var framebuffer: GLFramebuffer?
        if name != 0 {
            framebuffer = context.framebuffers[name]
            if framebuffer == nil {
                guard budget.objects < GLLimits.objects else { return context.fail(GL.OUT_OF_MEMORY) }
                framebuffer = GLFramebuffer(name: name, budget: budget)
                context.framebuffers[name] = framebuffer
            }
        }
        context.framebuffer = framebuffer
    }

    func deleteFramebuffer(_ context: GLContext, name: UInt32) {
        guard let framebuffer = context.framebuffers.removeValue(forKey: name) else { return }
        if context.framebuffer === framebuffer { context.framebuffer = nil }
    }

    private func attach(_ context: GLContext, target: UInt32, attachment: UInt32, _ value: GLAttachment) {
        guard let framebuffer = context.framebuffer else { return context.fail(GL.INVALID_OPERATION) }
        switch attachment {
        case GL.COLOR_ATTACHMENT0: framebuffer.color = value
        case GL.DEPTH_ATTACHMENT: framebuffer.depth = value
        default: framebuffer.stencil = value
        }
    }

    func framebufferRenderbuffer(_ context: GLContext, target: UInt32, attachment: UInt32, renderbufferTarget: UInt32, name: UInt32) {
        guard target == GL.FRAMEBUFFER, [GL.COLOR_ATTACHMENT0, GL.DEPTH_ATTACHMENT, GL.STENCIL_ATTACHMENT].contains(attachment),
              name == 0 || renderbufferTarget == GL.RENDERBUFFER else { return context.fail(GL.INVALID_ENUM) }
        guard name != 0 else { return attach(context, target: target, attachment: attachment, .none) }
        guard let renderbuffer = context.share.renderbuffers[name] else { return context.fail(GL.INVALID_OPERATION) }
        attach(context, target: target, attachment: attachment, .renderbuffer(renderbuffer))
    }

    func framebufferTexture(_ context: GLContext, target: UInt32, attachment: UInt32, textureTarget: UInt32, name: UInt32, level: Int) {
        guard target == GL.FRAMEBUFFER, [GL.COLOR_ATTACHMENT0, GL.DEPTH_ATTACHMENT, GL.STENCIL_ATTACHMENT].contains(attachment) else {
            return context.fail(GL.INVALID_ENUM)
        }
        guard name != 0 else { return attach(context, target: target, attachment: attachment, .none) }
        guard let (binding, face) = Self.imageTarget(textureTarget) else { return context.fail(GL.INVALID_ENUM) }
        guard let texture = context.share.textures[name], texture.target == binding else { return context.fail(GL.INVALID_OPERATION) }
        // OpenGL ES 2.0 draws to a texture's first level only.
        guard level == 0 else { return context.fail(GL.INVALID_VALUE) }
        attach(context, target: target, attachment: attachment, .texture(texture, face: face))
    }
}
