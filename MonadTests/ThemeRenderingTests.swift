//
//  ThemeRenderingTests.swift — what a theme does on screen: translucent
//  default background with opaque explicit colors, the theme's font and
//  cursor, blur, and background images (placement, and downsampled once).
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Monad

@MainActor
final class ThemeRenderingTests: XCTestCase {
    private func theme(_ edit: (inout Theme) -> Void = { _ in }) -> Theme {
        var t = Theme.monadDark
        t.id = "test"
        edit(&t)
        return t
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Color at a point in view coordinates (top-left origin, like the terminal).
    private func pixel(_ rep: NSBitmapImageRep, _ p: CGPoint, in view: NSView) -> (r: Int, g: Int, b: Int, a: Int) {
        let sx = CGFloat(rep.pixelsWide) / view.bounds.width, sy = CGFloat(rep.pixelsHigh) / view.bounds.height
        let c = rep.colorAt(x: Int(p.x * sx), y: Int(p.y * sy))?.usingColorSpace(.sRGB) ?? .clear
        func i(_ v: CGFloat) -> Int { Int((v * 255).rounded()) }
        return (i(c.redComponent), i(c.greenComponent), i(c.blueComponent), i(c.alphaComponent))
    }

    func testTranslucentDefaultBackgroundAndOpaqueCellColors() throws {
        let model = try XCTUnwrap(TerminalModel(cols: 20, rows: 4, scrollback: 0))
        let view = MonadTerminalView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        view.setTheme(theme {
            $0.background = RGB(hex: 0x000080)
            $0.backgroundOpacity = 0.5
            $0.ansi[1] = RGB(hex: 0xFF0000)
        })
        model.feed("\u{1B}[41m  \u{1B}[0m")
        view.refresh()
        XCTAssertFalse(view.isOpaque)
        let rep = try render(view)
        let cell = view.cellSize
        let red = pixel(rep, CGPoint(x: 6 + cell.width * 0.5, y: 4 + cell.height * 0.5), in: view)
        XCTAssertEqual(red.a, 255, "explicit colors stay opaque")
        XCTAssertEqual(red.r, 255)
        let empty = pixel(rep, CGPoint(x: 300, y: 90), in: view)
        XCTAssertEqual(Double(empty.a), 128, accuracy: 3, "the default background is translucent")
    }

    /// See-through themes: macOS 27 no longer paints the titlebar of a clear
    /// window, so Monad does, with the theme's colour (never so faint the
    /// title is lost over the desktop) and the system blur; its text is dark
    /// or light for the colour. Opaque themes keep the system's titlebar.
    func testSeeThroughThemesGetTheirOwnTitlebar() {
        XCTAssertNil(TitlebarStyle.of(theme()), "opaque: the system's own")
        XCTAssertNil(TitlebarStyle.of(nil))
        let navy = TitlebarStyle.of(theme {
            $0.background = RGB(hex: 0x000080)
            $0.backgroundOpacity = 0.3
        })
        XCTAssertEqual(navy?.color, RGB(hex: 0x000080))
        XCTAssertEqual(navy?.opacity ?? 0, TitlebarStyle.minimumOpacity, accuracy: 0.001, "readable over any desktop")
        XCTAssertEqual(navy?.dark, true)
        let paper = TitlebarStyle.of(theme {
            $0.background = RGB(hex: 0xF4F1E8)
            $0.backgroundOpacity = 0.9
            $0.blur = 0.5
        })
        XCTAssertEqual(paper?.opacity ?? 0, 0.9, accuracy: 0.001)
        XCTAssertEqual(paper?.dark, false)
    }

    func testTheTitlebarStripPaintsTheThemeColour() throws {
        let strip = TitlebarBackdropView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        strip.style = TitlebarStyle(color: RGB(hex: 0x102030), opacity: 1, dark: true)
        let rep = try render(strip)
        let p = pixel(rep, CGPoint(x: 100, y: 14), in: strip)
        XCTAssertEqual(p.a, 255)
        XCTAssertEqual(p.r, 0x10, accuracy: 2)
        XCTAssertEqual(p.b, 0x30, accuracy: 2)
    }

    /// With a painted titlebar the terminal sits below it, the strip fills
    /// the titlebar, and an opaque theme puts things back as they were.
    func testTheWindowLaysOutUnderItsTitlebar() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        let terminals = NSView()
        let content = TerminalWindowContentView(terminals: terminals)
        window.contentView = content
        content.apply(TitlebarStyle(color: RGB(hex: 0x000080), opacity: 0.8, dark: true), to: window)
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        let inner = content.convert(window.contentLayoutRect, from: nil)
        XCTAssertEqual(terminals.frame, inner, "below the titlebar")
        XCTAssertFalse(content.strip.isHidden)
        XCTAssertEqual(content.strip.frame.minY, inner.maxY, accuracy: 0.5)
        XCTAssertEqual(content.strip.frame.maxY, content.bounds.maxY, accuracy: 0.5)
        XCTAssertGreaterThan(content.strip.frame.height, 0)
        XCTAssertEqual(window.appearance?.name, .darkAqua)

        content.apply(nil, to: window)
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertTrue(content.strip.isHidden)
        XCTAssertEqual(terminals.frame, content.bounds)
        XCTAssertNil(window.appearance)
    }

    func testOpaqueThemesStayOpaque() throws {
        let model = try XCTUnwrap(TerminalModel(cols: 20, rows: 4, scrollback: 0))
        let view = MonadTerminalView(model: model)
        view.setTheme(theme())
        XCTAssertTrue(view.isOpaque)
    }

    func testThemeFontAndCursorStyle() throws {
        let model = try XCTUnwrap(TerminalModel(cols: 20, rows: 4, scrollback: 0))
        let view = MonadTerminalView(model: model)
        view.setTheme(theme {
            $0.font = "Menlo-Regular"
            $0.cursorStyle = .underline
        })
        XCTAssertEqual(CTFontCopyPostScriptName(view.fonts.regular) as String, "Menlo-Regular")
        XCTAssertEqual(view.fonts.size, Settings.fontSize, "the size stays the user's setting")
        XCTAssertEqual(view.effectiveCursorShape(mnd_vt_cursor(model.vt)), MND_CURSOR_UNDERLINE)
        model.feed("\u{1B}[2 q") // the program asks for a steady block
        XCTAssertEqual(view.effectiveCursorShape(mnd_vt_cursor(model.vt)), MND_CURSOR_BLOCK)
    }

    func testBlurAndImageLiveInTheBackdrop() throws {
        let model = try XCTUnwrap(TerminalModel(cols: 20, rows: 4, scrollback: 0))
        let backdrop = TerminalBackdropView(terminal: MonadTerminalView(model: model))
        backdrop.setTheme(theme { $0.blur = 0.3 })
        let effect = backdrop.subviews.compactMap { $0 as? NSVisualEffectView }.first
        XCTAssertNotNil(effect)
        XCTAssertEqual(effect?.alphaValue ?? 0, 1, "the desktop behind is fully blurred, not faded in")
        XCTAssertTrue(backdrop.needsTransparentWindow)
        backdrop.setTheme(theme())
        XCTAssertFalse(backdrop.subviews.contains { $0 is NSVisualEffectView })
        XCTAssertFalse(backdrop.needsTransparentWindow)
    }

    func testTheImageShowsBehindTheText() throws {
        let tmp = TempDir()
        let url = tmp.url.appendingPathComponent("green.png")
        try writePNG(url, width: 64, height: 64, color: CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        let model = try XCTUnwrap(TerminalModel(cols: 20, rows: 4, scrollback: 0))
        let backdrop = TerminalBackdropView(terminal: MonadTerminalView(model: model))
        backdrop.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        backdrop.setTheme(theme { $0.backgroundImage = .init(path: url.path, fill: .stretch, opacity: 1) })
        XCTAssertFalse(backdrop.terminal.paintsBackground, "the backdrop paints color and image")
        let rep = try render(backdrop)
        let p = pixel(rep, CGPoint(x: 300, y: 90), in: backdrop)
        XCTAssertGreaterThan(p.g, 240, "the image is green (color management may shift it slightly)")
        XCTAssertLessThan(p.r, 16)
    }

    /// With blur the image still shows, blurred: it sits above the system
    /// blur, which used to cover it (seen on the Mac 2026-10-10).
    func testTheImageShowsWithBlurToo() throws {
        let tmp = TempDir()
        let url = tmp.url.appendingPathComponent("green.png")
        try writePNG(url, width: 64, height: 64, color: CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        let model = try XCTUnwrap(TerminalModel(cols: 20, rows: 4, scrollback: 0))
        let backdrop = TerminalBackdropView(terminal: MonadTerminalView(model: model))
        backdrop.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        backdrop.setTheme(theme {
            $0.blur = 0.2
            $0.backgroundImage = .init(path: url.path, fill: .stretch, opacity: 1)
        })
        let effect = try XCTUnwrap(backdrop.subviews.firstIndex { $0 is NSVisualEffectView })
        let image = try XCTUnwrap(backdrop.subviews.firstIndex { $0 is BackdropImageView })
        let text = try XCTUnwrap(backdrop.subviews.firstIndex { $0 === backdrop.terminal })
        XCTAssertLessThan(effect, image, "the desktop's blur below the image")
        XCTAssertLessThan(image, text, "the text above it")
        let p = pixel(try render(backdrop), CGPoint(x: 300, y: 90), in: backdrop)
        XCTAssertGreaterThan(p.g, 200, "the image shows: \(p)")
        XCTAssertLessThan(p.r, 40)
    }

    private func writePNG(_ url: URL, width: Int, height: Int, color: CGColor) throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    func testBlurBlursTheBackgroundImageItself() throws {
        let tmp = TempDir()
        let url = tmp.url.appendingPathComponent("edge.png")
        // Left half black, right half white: a sharp edge in the middle.
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 200, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 20))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 0, width: 100, height: 20))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        func gray(_ image: CGImage, x: Int) -> Int {
            let rep = NSBitmapImageRep(cgImage: image)
            let c = rep.colorAt(x: x, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB) ?? .clear
            return Int((c.redComponent * 255).rounded())
        }
        let cache = BackdropImageCache()
        let sharp = try XCTUnwrap(cache.image(atPath: url.path, blur: 0))
        XCTAssertEqual(gray(sharp, x: 98), 0)
        let blurred = try XCTUnwrap(cache.image(atPath: url.path, blur: 0.5))
        XCTAssertEqual(blurred.width, sharp.width, "same size: the edges are not eaten")
        XCTAssertGreaterThan(gray(blurred, x: 98), 40, "the edge is soft")
        XCTAssertLessThan(gray(blurred, x: 98), 215)
        XCTAssertTrue(blurred === cache.image(atPath: url.path, blur: 0.5), "blurred once, shared")
    }

    func testImagePlacement() {
        let image = CGSize(width: 200, height: 100), bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        XCTAssertEqual(BackdropLayout.rect(.fill, image: image, in: bounds), CGRect(x: -200, y: 0, width: 800, height: 400))
        XCTAssertEqual(BackdropLayout.rect(.fit, image: image, in: bounds), CGRect(x: 0, y: 100, width: 400, height: 200))
        XCTAssertEqual(BackdropLayout.rect(.stretch, image: image, in: bounds), bounds)
        XCTAssertEqual(BackdropLayout.rect(.center, image: image, in: bounds), CGRect(x: 100, y: 150, width: 200, height: 100))
        XCTAssertEqual(BackdropLayout.rect(.tile, image: image, in: bounds), CGRect(x: 0, y: 300, width: 200, height: 100),
                       "tiles start at the top left")
    }

    func testImagesAreDownsampledOnceAndShared() throws {
        let tmp = TempDir()
        let url = tmp.url.appendingPathComponent("wide.png")
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 6000, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 6000, height: 40))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let cache = BackdropImageCache()
        let a = try XCTUnwrap(cache.image(atPath: url.path, blur: 0))
        XCTAssertEqual(a.width, BackdropImageCache.maxPixels)
        let b = try XCTUnwrap(cache.image(atPath: url.path, blur: 0))
        XCTAssertTrue(a === b, "decoded once, shared by every tab")
        XCTAssertNil(cache.image(atPath: tmp.url.appendingPathComponent("missing.png").path, blur: 0))
    }

    /// The cache keeps what fits its limit, the least recently used giving
    /// way, and nothing else empties it (NSCache did, under memory pressure,
    /// so the tests above failed now and then in a full run).
    func testTheCacheKeepsTheMostRecentlyUsedWithinItsLimit() throws {
        let tmp = TempDir()
        func png(_ name: String) throws -> String {
            let url = tmp.url.appendingPathComponent(name)
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            return url.path
        }
        let (p1, p2, p3) = (try png("1.png"), try png("2.png"), try png("3.png"))
        let probe = try XCTUnwrap(BackdropImageCache().image(atPath: p1, blur: 0))
        let cache = BackdropImageCache(costLimit: probe.bytesPerRow * probe.height * 5 / 2) // two fit
        let a = try XCTUnwrap(cache.image(atPath: p1, blur: 0))
        let b = try XCTUnwrap(cache.image(atPath: p2, blur: 0))
        XCTAssertTrue(cache.image(atPath: p1, blur: 0) === a, "a used again")
        let c = try XCTUnwrap(cache.image(atPath: p3, blur: 0))
        XCTAssertTrue(cache.image(atPath: p1, blur: 0) === a)
        XCTAssertTrue(cache.image(atPath: p3, blur: 0) === c)
        XCTAssertFalse(cache.image(atPath: p2, blur: 0) === b, "the least recently used gave way")
    }
}
