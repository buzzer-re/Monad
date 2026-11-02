//
//  TerminalFonts.swift — font variants, cell metrics and a glyph cache with
//  fallback fonts for characters the primary font lacks. Nerd Font icons
//  (Private Use Area codepoints no macOS font has, where CoreText's fallback
//  is LastResort's boxes) come from the bundled Symbols Nerd Font Mono
//  (Monad/Terminal/Fonts, MIT; its icon sets' licenses beside it), sized to
//  a cell, unless the terminal's own font has them.
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

    /// The Nerd Font icons, one em wide, so sized to a cell and centered in it.
    let symbols: CTFont?
    /// The same for an icon before a blank cell: up to two cells wide and a
    /// cell high, centered across both (as prompts lay out "icon name").
    let roomySymbols: CTFont?
    /// Powerline's separators: the cell's height, squeezed to its width, so
    /// the colored segments they join meet without a gap.
    let separators: CTFont?

    private static let symbolsDescriptor: CTFontDescriptor? = {
        guard let url = Bundle.main.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf"),
              let all = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return nil }
        return all.first
    }()

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

        // Its icons fill the em from 0.2 below the baseline to 0.8 above:
        // their middle goes to the cell's.
        let cellMiddle = ((cellHeight - (ascent + descent)) / 2 + ascent).rounded() - cellHeight / 2
        func symbolsFont(size: CGFloat, width: CGFloat) -> CTFont? {
            var place = CGAffineTransform(translationX: (width - size) / 2, y: cellMiddle - 0.3 * size)
            return Self.symbolsDescriptor.map { CTFontCreateWithFontDescriptor($0, size, &place) }
        }
        symbols = symbolsFont(size: cellWidth, width: cellWidth)
        roomySymbols = symbolsFont(size: min(2 * cellWidth, cellHeight), width: 2 * cellWidth)
        // A separator's em runs from the font's descent to its ascent.
        let rowHeight = cellHeight, columnWidth = cellWidth
        let cellBottom = cellMiddle - cellHeight / 2
        separators = Self.symbolsDescriptor.map { d in
            let below = CTFontGetDescent(CTFontCreateWithFontDescriptor(d, rowHeight, nil))
            var squeeze = CGAffineTransform(a: columnWidth / rowHeight, b: 0, c: 0, d: 1, tx: 0, ty: cellBottom + below)
            return CTFontCreateWithFontDescriptor(d, rowHeight, &squeeze)
        }
    }

    /// `g` drawn with the next cell's room too: larger when it is an icon,
    /// except Powerline's separators, which join their cell to the next.
    func roomy(_ g: Glyph, scalar: UInt32) -> Glyph {
        guard let symbols, let roomySymbols, g.font === symbols, !Self.isPowerlineSeparator(scalar) else { return g }
        return Glyph(font: roomySymbols, glyph: g.glyph)
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
        let result = lookup(scalar, in: base)
        cache[key] = result
        return result
    }

    /// The terminal's font; for an icon codepoint the symbols font; then
    /// what CoreText falls back to, unless that is only LastResort's box and
    /// the symbols font has it.
    private func lookup(_ scalar: UInt32, in base: CTFont) -> Glyph? {
        if let g = Self.glyph(scalar, in: base) { return g }
        if Self.isPowerlineSeparator(scalar), let separators, let g = Self.glyph(scalar, in: separators) { return g }
        if Self.isPrivateUse(scalar), let symbols, let g = Self.glyph(scalar, in: symbols) { return g }
        guard let us = Unicode.Scalar(scalar) else { return nil }
        let str = String(Character(us)) as CFString
        let fallback = CTFontCreateForString(base, str, CFRange(location: 0, length: CFStringGetLength(str)))
        let found = Self.glyph(scalar, in: fallback)
        if found == nil || CTFontCopyPostScriptName(fallback) as String == "LastResort",
           let symbols, let g = Self.glyph(scalar, in: symbols) {
            return g
        }
        return found
    }

    private static func glyph(_ scalar: UInt32, in font: CTFont) -> Glyph? {
        guard let us = Unicode.Scalar(scalar) else { return nil }
        var utf16 = Array(String(Character(us)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count), glyphs[0] != 0 else { return nil }
        return Glyph(font: font, glyph: glyphs[0])
    }

    static func isPowerlineSeparator(_ scalar: UInt32) -> Bool { (0xE0B0...0xE0D7).contains(scalar) }

    static func isPrivateUse(_ scalar: UInt32) -> Bool {
        (0xE000...0xF8FF).contains(scalar) || (0xF0000...0xFFFFD).contains(scalar) || (0x100000...0x10FFFD).contains(scalar)
    }
}
