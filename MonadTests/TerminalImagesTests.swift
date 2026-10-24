//
//  TerminalImagesTests.swift — inline images a guest sends, decoded on the
//  Mac: only complete files of the format the core read from the header,
//  never larger than their cells show, a bounded number kept.
//

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Monad

final class TerminalImagesTests: XCTestCase {
    /// An image file of w x h pixels in the given type.
    static func file(width: Int, height: Int, type: UTType = .png) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    func testAnImageIsDecodedNoLargerThanItsCells() throws {
        let png = Self.file(width: 400, height: 200)
        let image = try XCTUnwrap(TerminalImages.decode(png, format: MND_IMAGE_PNG, maxPixelSize: 100))
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 50)
        let whole = try XCTUnwrap(TerminalImages.decode(png, format: MND_IMAGE_PNG, maxPixelSize: 4000))
        XCTAssertEqual(whole.width, 400, "never scaled up")
        XCTAssertNotNil(TerminalImages.decode(Self.file(width: 40, height: 20, type: .jpeg), format: MND_IMAGE_JPEG,
                                              maxPixelSize: 100))
        XCTAssertNotNil(TerminalImages.decode(Self.file(width: 40, height: 20, type: .gif), format: MND_IMAGE_GIF,
                                              maxPixelSize: 100))
    }

    /// A file of another type than the header said, a cut one or none at
    /// all is not decoded.
    func testOnlyACompleteFileOfTheFormatTheHeaderSaidIsDecoded() {
        let png = Self.file(width: 40, height: 20)
        XCTAssertNil(TerminalImages.decode(png, format: MND_IMAGE_JPEG, maxPixelSize: 100))
        XCTAssertNil(TerminalImages.decode(Self.file(width: 40, height: 20, type: .tiff), format: MND_IMAGE_PNG,
                                           maxPixelSize: 100))
        XCTAssertNil(TerminalImages.decode(Data("not an image".utf8), format: MND_IMAGE_PNG, maxPixelSize: 100))
        XCTAssertNil(TerminalImages.decode(png.prefix(png.count / 2), format: MND_IMAGE_PNG, maxPixelSize: 100),
                     "cut in its image data")
    }

    func testTheStoreKeepsABoundedNumber() throws {
        let cg = try XCTUnwrap(TerminalImages.decode(Self.file(width: 4, height: 4), format: MND_IMAGE_PNG, maxPixelSize: 4))
        let store = TerminalImages()
        for id in 1...UInt32(TerminalImages.maxImages + 1) {
            store.store(TerminalImages.Image(cgImage: cg, cols: 1, rows: 1, fillX: 1, fillY: 1), id: id)
        }
        XCTAssertNil(store.image(1), "the oldest goes")
        XCTAssertNotNil(store.image(2))
        XCTAssertNotNil(store.image(UInt32(TerminalImages.maxImages + 1)))
        store.removeAll()
        XCTAssertNil(store.image(2))
    }
}
