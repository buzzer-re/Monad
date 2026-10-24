//
//  TerminalTheme.swift — color palette and resolution of mnd_vt colors.
//

import AppKit

/// Swift mirrors of the C color macros (function-like macros are not imported).
enum VTColor {
    static let tagMask: UInt32 = 0xFF00_0000
    static let tagIndex: UInt32 = 0x0100_0000
    static let tagRGB: UInt32 = 0x0200_0000
}

/// Mirrors of MND_ATTR_* (anonymous C enums import untyped).
enum VTAttr {
    static let bold: UInt16 = 1 << 0
    static let dim: UInt16 = 1 << 1
    static let italic: UInt16 = 1 << 2
    static let blink: UInt16 = 1 << 3
    static let inverse: UInt16 = 1 << 4
    static let hidden: UInt16 = 1 << 5
    static let strike: UInt16 = 1 << 6
    static let overline: UInt16 = 1 << 7
    static let underlineShift: UInt16 = 8
    static let underlineMask: UInt16 = 7 << 8
    static let widthShift: UInt16 = 11
    static let widthMask: UInt16 = 3 << 11

    static let widthWide: UInt16 = 1
    static let widthSpacer: UInt16 = 2

    static let graphemeFlag: UInt32 = 0x8000_0000
}

struct RGB: Equatable, Hashable {
    var r: UInt8, g: UInt8, b: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    init(hex: UInt32) {
        self.init(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
    }

    var hex: UInt32 { UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b) }

    func cgColor(alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: alpha)
    }

    func mixed(with o: RGB, _ t: CGFloat) -> RGB {
        func m(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8(max(0, min(255, (CGFloat(a) * (1 - t) + CGFloat(b) * t).rounded()))) }
        return RGB(m(r, o.r), m(g, o.g), m(b, o.b))
    }
}

struct TerminalTheme: Equatable {
    var foreground: RGB
    var background: RGB
    var cursor: RGB
    var selection: RGB
    var palette: [RGB] // 256 entries
    /// Bold text in the default color uses this (nil: bold brightens only).
    var bold: RGB? = nil

    static func standardPalette(ansi: [RGB]) -> [RGB] {
        var p = ansi
        let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
        for i in 0..<216 { p.append(RGB(steps[(i / 36) % 6], steps[(i / 6) % 6], steps[i % 6])) }
        for i in 0..<24 { let v = UInt8(8 + i * 10); p.append(RGB(v, v, v)) }
        return p
    }

    /// Dark theme inspired by Terminal.app "Pro" with softer ANSI colors.
    static let dark = TerminalTheme(
        foreground: RGB(hex: 0xE6E6E6), background: RGB(hex: 0x1C1C1E), cursor: RGB(hex: 0xC8C8C8),
        selection: RGB(hex: 0x3A4A66),
        palette: standardPalette(ansi: [
            0x000000, 0xE0564E, 0x5BC25B, 0xD6B84A, 0x4E8EE6, 0xC06FD0, 0x4FB8C7, 0xC7C7C7,
            0x686868, 0xFF6E67, 0x6FE06F, 0xFFE061, 0x6FA8FF, 0xE38BF2, 0x67E0EE, 0xFFFFFF,
        ].map { RGB(hex: $0) }))

    /// Light theme inspired by Terminal.app "Basic".
    static let light = TerminalTheme(
        foreground: RGB(hex: 0x1D1D1F), background: RGB(hex: 0xFFFFFF), cursor: RGB(hex: 0x7F7F7F),
        selection: RGB(hex: 0xB4D5FE),
        palette: standardPalette(ansi: [
            0x000000, 0xC23621, 0x25BC24, 0xADAD27, 0x492EE1, 0xD338D3, 0x33BBC8, 0xCBCCCD,
            0x818383, 0xFC391F, 0x31E722, 0xEAEC23, 0x5833FF, 0xF935F8, 0x14F0F0, 0xE9EBEB,
        ].map { RGB(hex: $0) }))

    static func forAppearance(_ appearance: NSAppearance) -> TerminalTheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    /// Resolve a cell's foreground/background, honoring bold-as-bright,
    /// inverse, dim, hidden and DECSCNM reverse video.
    func resolve(fg: UInt32, bg: UInt32, attrs: UInt16, reverseVideo: Bool) -> (fg: RGB, bg: RGB, bgIsDefault: Bool) {
        let bold = attrs & VTAttr.bold != 0
        var f = color(fg, isForeground: true, bold: bold, reverseVideo: reverseVideo)
        var b = color(bg, isForeground: false, bold: false, reverseVideo: reverseVideo)
        var bgDefault = bg == 0
        if attrs & VTAttr.inverse != 0 {
            swap(&f, &b)
            bgDefault = false
        }
        if attrs & VTAttr.dim != 0 { f = f.mixed(with: b, 0.45) }
        if attrs & VTAttr.hidden != 0 { f = b }
        return (f, b, bgDefault)
    }

    private func color(_ c: UInt32, isForeground: Bool, bold: Bool, reverseVideo: Bool) -> RGB {
        switch c & VTColor.tagMask {
        case VTColor.tagIndex:
            var i = Int(c & 0xFF)
            if bold && isForeground && i < 8 { i += 8 }
            return palette[i]
        case VTColor.tagRGB:
            return RGB(hex: c & 0xFF_FFFF)
        default:
            let useFg = isForeground != reverseVideo
            if useFg, bold, isForeground, let boldColor = self.bold { return boldColor }
            return useFg ? foreground : background
        }
    }
}
