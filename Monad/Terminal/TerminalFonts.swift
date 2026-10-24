//
//  TerminalFonts.swift — font variants, cell metrics and a glyph cache with
//  fallback fonts for characters the primary font lacks.
//

import AppKit
import CoreText

final class TerminalFonts {
    let size: CGFloat
    let regular: CTFont
    let bold: CTFont
    let italic: CTFont
    let boldItalic: CTFont
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let underlineOffset: CGFloat
    let lineThickness: CGFloat

    struct Glyph {
        let font: CTFont
        let glyph: CGGlyph
    }

    private var cache: [UInt64: Glyph?] = [:]

    /// The font the theme asked for (PostScript name); nil: the system monospaced font.
    let name: String?

    init(size: CGFloat, name: String? = nil) {
        self.size = size
        let fm = NSFontManager.shared
        let named = name.flatMap { NSFont(name: $0, size: size) }
        self.name = name // as requested, even if it fell back
        let base = named ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let boldNS = named.map { fm.convert($0, toHaveTrait: .boldFontMask) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        regular = base as CTFont
        bold = boldNS as CTFont
        italic = fm.convert(base, toHaveTrait: .italicFontMask) as CTFont
        boldItalic = fm.convert(boldNS, toHaveTrait: .italicFontMask) as CTFont

        var glyph = CGGlyph(0)
        var ch: UniChar = 0x4D // "M"
        CTFontGetGlyphsForCharacters(regular, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)
        ascent = CTFontGetAscent(regular)
        descent = CTFontGetDescent(regular)
        let leading = CTFontGetLeading(regular)
        // Whole points keep cell edges on pixel boundaries (no seams between
        // adjacent background fills).
        cellWidth = max(1, advance.width.rounded())
        cellHeight = ceil(ascent + descent + max(leading, size * 0.12))
        underlineOffset = -CTFontGetUnderlinePosition(regular)
        lineThickness = max(1, CTFontGetUnderlineThickness(regular))
    }

    /// Baseline offset from the top of a cell.
    var baseline: CGFloat { ((cellHeight - (ascent + descent)) / 2 + ascent).rounded() }

    func font(bold isBold: Bool, italic isItalic: Bool) -> CTFont {
        switch (isBold, isItalic) {
        case (false, false): return regular
        case (true, false): return bold
        case (false, true): return italic
        case (true, true): return boldItalic
        }
    }

    /// Glyph for a scalar in the given style, falling back to a system font
    /// that covers it. nil if nothing can render it.
    func glyph(for scalar: UInt32, bold isBold: Bool, italic isItalic: Bool) -> Glyph? {
        let style: UInt64 = (isBold ? 1 : 0) | (isItalic ? 2 : 0)
        let key = UInt64(scalar) << 2 | style
        if let hit = cache[key] { return hit }
        let base = font(bold: isBold, italic: isItalic)
        let result = Self.lookup(scalar, in: base)
        cache[key] = result
        return result
    }

    private static func lookup(_ scalar: UInt32, in base: CTFont) -> Glyph? {
        guard let us = Unicode.Scalar(scalar) else { return nil }
        var utf16 = Array(String(Character(us)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        if CTFontGetGlyphsForCharacters(base, &utf16, &glyphs, utf16.count), glyphs[0] != 0 {
            return Glyph(font: base, glyph: glyphs[0])
        }
        let str = String(Character(us)) as CFString
        let fallback = CTFontCreateForString(base, str, CFRange(location: 0, length: CFStringGetLength(str)))
        if CTFontGetGlyphsForCharacters(fallback, &utf16, &glyphs, utf16.count), glyphs[0] != 0 {
            return Glyph(font: fallback, glyph: glyphs[0])
        }
        return nil
    }
}
