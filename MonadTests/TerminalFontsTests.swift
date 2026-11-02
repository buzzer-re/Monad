//
//  TerminalFontsTests.swift — glyphs and their fallbacks. Nerd Font icons
//  (Private Use Area codepoints, which no macOS font has) come from the
//  bundled Symbols Nerd Font Mono instead of macOS's last-resort boxes (seen
//  as "?" boxes in a prompt's icons, 2026-11-02).
//

import CoreText
import XCTest
@testable import Monad

final class TerminalFontsTests: XCTestCase {
    private func name(_ g: TerminalFonts.Glyph?) -> String {
        g.map { CTFontCopyPostScriptName($0.font) as String } ?? "none"
    }

    func testNerdFontIconsComeFromTheBundledSymbolsFont() {
        let fonts = TerminalFonts(size: 13)
        // Powerline branch, Font Awesome folder, Seti folder, Linux logo,
        // Codicon, and a Material Design icon past the BMP.
        for scalar: UInt32 in [0xE0A0, 0xE0B0, 0xF07B, 0xE5FF, 0xF31B, 0xEA60, 0xF0001] {
            let g = fonts.glyph(for: scalar, bold: false, italic: false)
            XCTAssertTrue(name(g).hasPrefix("SymbolsNFM"), String(scalar, radix: 16) + ": " + name(g))
        }
        let bold = fonts.glyph(for: 0xF07B, bold: true, italic: false)
        XCTAssertTrue(name(bold).hasPrefix("SymbolsNFM"), "bold too: " + name(bold))
    }

    func testIconsFitInACell() throws {
        let fonts = TerminalFonts(size: 13)
        let g = try XCTUnwrap(fonts.glyph(for: 0xF07B, bold: false, italic: false))
        let font = g.font
        var glyph = g.glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        XCTAssertEqual(CTFontGetSize(font), fonts.cellWidth, accuracy: 0.01, "one em is one cell")
        XCTAssertLessThanOrEqual(advance.width, fonts.cellWidth + 0.5)
    }

    /// As in prompts ("icon space name"): an icon before a blank cell is
    /// drawn up to two cells wide and a cell high; text is never widened.
    func testAnIconWithRoomGrowsIntoTheNextCell() throws {
        let fonts = TerminalFonts(size: 13)
        let icon = try XCTUnwrap(fonts.glyph(for: 0xF07B, bold: false, italic: false))
        let roomy = fonts.roomy(icon, scalar: 0xF07B)
        XCTAssertEqual(CTFontGetSize(roomy.font), min(2 * fonts.cellWidth, fonts.cellHeight), accuracy: 0.01)
        XCTAssertGreaterThan(CTFontGetSize(roomy.font), CTFontGetSize(icon.font))
        XCTAssertEqual(roomy.glyph, icon.glyph)
        let letter = try XCTUnwrap(fonts.glyph(for: 0x41, bold: false, italic: false))
        XCTAssertTrue(fonts.roomy(letter, scalar: 0x41).font === letter.font, "text keeps its size")
        // Powerline's separators fill exactly their cell, joined to the next.
        let arrow = try XCTUnwrap(fonts.glyph(for: 0xE0B0, bold: false, italic: false))
        XCTAssertTrue(fonts.roomy(arrow, scalar: 0xE0B0).font === arrow.font, "a separator keeps its cell")
    }

    /// Powerline's separators span the whole cell, top to bottom, so the
    /// colored segments they join meet without a gap.
    func testPowerlineSeparatorsFillTheirCell() throws {
        let fonts = TerminalFonts(size: 13)
        for scalar: UInt32 in [0xE0B0, 0xE0B2, 0xE0B4, 0xE0BC] {
            let g = try XCTUnwrap(fonts.glyph(for: scalar, bold: false, italic: false))
            XCTAssertEqual(CTFontGetSize(g.font), fonts.cellHeight, accuracy: 0.01, String(scalar, radix: 16))
            var glyph = g.glyph
            let box = CTFontGetBoundingRectsForGlyphs(g.font, .horizontal, &glyph, nil, 1)
            XCTAssertLessThanOrEqual(box.maxX, fonts.cellWidth + 0.5, String(scalar, radix: 16))
        }
    }

    func testTextStillComesFromTheTerminalsFont() {
        let fonts = TerminalFonts(size: 13)
        let regular = CTFontCopyPostScriptName(fonts.regular) as String
        XCTAssertEqual(name(fonts.glyph(for: 0x41, bold: false, italic: false)), regular)
        // Box drawing and symbols macOS has keep their usual fonts.
        XCTAssertFalse(name(fonts.glyph(for: 0x2713, bold: false, italic: false)).hasPrefix("SymbolsNFM"))
    }

    func testTheSymbolsFontShipsWithItsLicense() throws {
        let font = try XCTUnwrap(Bundle.main.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf"))
        XCTAssertGreaterThan(try Data(contentsOf: font).count, 1_000_000)
        let license = try XCTUnwrap(Bundle.main.url(forResource: "SymbolsNerdFont-LICENSE", withExtension: "txt"))
        XCTAssertTrue(try String(contentsOf: license, encoding: .utf8).contains("MIT License"))
    }
}
