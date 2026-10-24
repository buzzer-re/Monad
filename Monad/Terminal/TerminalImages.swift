//
//  TerminalImages.swift — inline images a guest sent (OSC 1337), decoded on
//  the Mac for drawing. The core has checked the file's header (PNG, JPEG or
//  GIF, bounded) and laid it out over cells; here ImageIO decodes only a
//  complete file of that very format, never larger than its cells show, and
//  a bounded number is kept. Only while the VM's setting allows images.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class TerminalImages: @unchecked Sendable {
    struct Image {
        let cgImage: CGImage
        /// The cells it covers and the share of them it fills from the top left.
        let cols: Int
        let rows: Int
        let fillX: CGFloat
        let fillY: CGFloat
    }

    /// Images kept per tab: older ones are drawn no more.
    static let maxImages = 64
    /// The largest side an image is decoded at, in pixels.
    static let maxPixelSide = 4096

    private let lock = NSLock()
    private var images: [UInt32: Image] = [:]
    private var order: [UInt32] = []

    func image(_ id: UInt32) -> Image? {
        lock.withLock { images[id] }
    }

    func store(_ image: Image, id: UInt32) {
        lock.withLock {
            if images.updateValue(image, forKey: id) != nil { order.removeAll { $0 == id } }
            order.append(id)
            while order.count > Self.maxImages { images[order.removeFirst()] = nil }
        }
    }

    func removeAll() {
        lock.withLock {
            images.removeAll()
            order.removeAll()
        }
    }

    private static func type(_ format: mnd_image_format) -> UTType? {
        switch format {
        case MND_IMAGE_PNG: return .png
        case MND_IMAGE_JPEG: return .jpeg
        case MND_IMAGE_GIF: return .gif
        default: return nil
        }
    }

    /// The file decoded at most `maxPixelSize` on its longer side (never
    /// scaled up), or nil unless it is a complete file of `format`.
    static func decode(_ data: Data, format: mnd_image_format, maxPixelSize: Int) -> CGImage? {
        guard data.count <= Int(MND_VT_IMAGE_BYTES_MAX), let type = type(format) else { return nil }
        let options = [kCGImageSourceTypeIdentifierHint: type.identifier, kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetType(source) as String? == type.identifier,
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) >= 1,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        let thumbnail = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixelSize, maxPixelSide)),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail) else { return nil }
        // ImageIO scales a thumbnail up to the size asked: never larger than the file.
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
           image.width > w || image.height > h {
            let whole = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            return CGImageSourceCreateImageAtIndex(source, 0, whole)
        }
        return image
    }
}
