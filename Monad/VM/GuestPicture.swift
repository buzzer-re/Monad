//
//  GuestPicture.swift — what a Linux program's window shows on the Mac:
//  the pixels its program drew, as the VM's window manager sent them
//  (GuestWindowProtocol.swift), kept in memory the Mac's screen is drawn
//  from directly (an IOSurface, which a window's layer shows without a
//  copy). There are two of them, taking turns: a part is put into the
//  one the screen is not showing, which the screen then shows.
//
//  The guest says where each part goes. Nothing of it is kept that is not
//  inside the picture and as many bytes as it says; what the pixels are
//  is the guest's to choose, as what a program draws always is.
//

import CoreGraphics
import Foundation
import IOSurface

final class GuestPicture {
    let width: Int, height: Int
    /// What the screen shows now. Another one after each `put`.
    private(set) var surface: IOSurface
    /// The one the next part is put into, while the screen shows the
    /// other: the screen never shows a part half written. It lacks the
    /// part put last, which is copied over first.
    private var next: IOSurface
    private var last: (x: Int, y: Int, width: Int, height: Int)?
    /// All of it came: its last rows did, across its whole width. The
    /// window manager sends a window that is new, or of a new size, whole
    /// from the top, so until then it is partly empty.
    private(set) var isWhole = false

    /// nil for a size no window has, or when there is no memory for it.
    init?(width: Int, height: Int) {
        guard (1...GuestWindowReader.maxSide).contains(width), (1...GuestWindowReader.maxSide).contains(height),
              let one = Self.memory(width, height), let other = Self.memory(width, height) else { return nil }
        self.width = width
        self.height = height
        surface = one
        next = other
    }

    /// Memory for width × height pixels, all nothing.
    private static func memory(_ width: Int, _ height: Int) -> IOSurface? {
        guard let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
                                                   .pixelFormat: UInt32(0x4247_5241) /* 'BGRA' */]) else { return nil }
        // Programs draw for an ordinary screen: without this the Mac would take the colours for its own display's.
        if let space = CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList() {
            surface.setAttachment(space, forKey: kIOSurfaceColorSpace as String)
        }
        return surface
    }

    /// Puts a part where the window manager said: `surface` is then the
    /// picture with it. False, and nothing changed, when it is not inside
    /// the picture, or its bytes are neither its pixels as they are nor
    /// those pixels packed.
    @discardableResult
    func put(_ part: GuestPixels) -> Bool {
        let raw = part.width * part.height * 4
        guard part.width >= 1, part.height >= 1, part.x >= 0, part.y >= 0, part.x <= width - part.width, part.y <= height - part.height,
              part.data.count == raw || (4..<raw).contains(part.data.count) else { return false }
        next.lock(options: [], seed: nil)
        surface.lock(options: .readOnly, seed: nil)
        let stride = next.bytesPerRow, base = next.baseAddress, shown = surface.baseAddress, shownStride = surface.bytesPerRow
        /// Gives the memory being written what the one on the screen has there.
        func catchUp(x: Int, y: Int, width: Int, height: Int) {
            for row in y..<(y + height) { memcpy(base + row * stride + x * 4, shown + row * shownStride + x * 4, width * 4) }
        }
        if let last { catchUp(x: last.x, y: last.y, width: last.width, height: last.height) }
        let to = base + part.y * stride + part.x * 4
        let ok = part.data.withUnsafeBytes { bytes -> Bool in
            guard let from = bytes.baseAddress else { return false }
            if bytes.count == raw {
                let row = part.width * 4
                for y in 0..<part.height { memcpy(to + y * stride, from + y * row, row) }
                return true
            }
            return mnd_pixels_unpack(from.assumingMemoryBound(to: UInt8.self), bytes.count, to.assumingMemoryBound(to: UInt8.self), stride,
                                     Int32(part.width), Int32(part.height))
        }
        // Bytes that were no such pixels may have written some of the part: it is as the screen has it again.
        if !ok { catchUp(x: part.x, y: part.y, width: part.width, height: part.height) }
        surface.unlock(options: .readOnly, seed: nil)
        next.unlock(options: [], seed: nil)
        guard ok else {
            last = nil // both hold the same now
            return false
        }
        swap(&surface, &next)
        last = (part.x, part.y, part.width, part.height)
        if part.x == 0, part.width == width, part.y + part.height == height { isWhole = true }
        return true
    }

    /// One pixel as the program drew it (0xAARRGGBB); nil outside the picture.
    func pixel(x: Int, y: Int) -> UInt32? {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        return UInt32(littleEndian: (surface.baseAddress + y * surface.bytesPerRow + x * 4).loadUnaligned(as: UInt32.self))
    }
}
