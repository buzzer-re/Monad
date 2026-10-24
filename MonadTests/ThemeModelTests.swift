//
//  ThemeModelTests.swift — themes as data: JSON, validation, the palette a
//  terminal gets, fonts that may not be installed, and the catalog of
//  built-in and user themes.
//

import AppKit
import XCTest
@testable import Monad

final class ThemeModelTests: XCTestCase {
    static func sample(id: String = "ocean-breeze", name: String = "Ocean Breeze") -> Theme {
        Theme(id: id, name: name,
              foreground: RGB(hex: 0xFFFFFF), background: RGB(hex: 0x224FBC), bold: RGB(hex: 0xFFFFFF),
              cursor: RGB(hex: 0x7F7F7F), selection: RGB(hex: 0x216DFF),
              ansi: (0..<16).map { RGB(hex: UInt32($0) * 0x111111) },
              backgroundOpacity: 0.9, blur: 0.5, font: "Menlo", cursorStyle: .underline,
              backgroundImage: .init(path: "/Users/x/Pictures/sea.jpg", fill: .fill, opacity: 0.4))
    }

    func testJSONRoundTrip() throws {
        let theme = Self.sample()
        let data = try theme.encoded()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"background\" : \"#224FBC\""), text)
        XCTAssertTrue(text.contains("\"schema\" : 1"), text)
        XCTAssertEqual(try Theme.decode(data), theme)
    }

    func testMinimalThemeGetsDefaults() throws {
        let json = """
        {"schema":1,"id":"plain","name":"Plain","foreground":"#000000","background":"#ffffff",
         "cursor":"#7f7f7f","selection":"#b4d5fe","ansi":[\((0..<16).map { _ in "\"#000000\"" }.joined(separator: ","))]}
        """
        let t = try Theme.decode(Data(json.utf8))
        XCTAssertEqual(t.backgroundOpacity, 1)
        XCTAssertEqual(t.blur, 0)
        XCTAssertNil(t.bold)
        XCTAssertNil(t.font)
        XCTAssertNil(t.backgroundImage)
        XCTAssertEqual(t.background, RGB(hex: 0xFFFFFF), "hex is case-insensitive")
    }

    func testInvalidThemesAreRejected() {
        func invalid(_ edit: (inout Theme) -> Void, line: UInt = #line) {
            var t = Self.sample()
            edit(&t)
            XCTAssertThrowsError(try t.validate(), line: line)
            XCTAssertThrowsError(try Theme.decode(try t.encoded()), "decoding validates too", line: line)
        }
        invalid { $0.backgroundOpacity = 1.5 }
        invalid { $0.backgroundOpacity = -0.1 }
        invalid { $0.blur = 2 }
        invalid { $0.ansi.removeLast() }
        invalid { $0.id = "Bad Id" }
        invalid { $0.id = "" }
        invalid { $0.name = "" }
        invalid { $0.name = String(repeating: "x", count: 65) }
        invalid { $0.backgroundImage?.path = "relative.png" }
        invalid { $0.backgroundImage?.opacity = 3 }
        invalid { $0.schema = 2 }
        XCTAssertNoThrow(try Self.sample().validate())
    }

    func testColorsMustBeHex() {
        for bad in ["red", "#12345", "#1234567", "224FBC", "#GG0000"] {
            let json = #"{"c":"\#(bad)"}"#
            struct Box: Decodable { let c: RGB }
            XCTAssertThrowsError(try JSONDecoder().decode(Box.self, from: Data(json.utf8)), bad)
        }
    }

    func testTerminalPaletteComesFromTheTheme() {
        let t = Self.sample()
        let palette = t.terminalTheme
        XCTAssertEqual(palette.palette.count, 256)
        XCTAssertEqual(Array(palette.palette.prefix(16)), t.ansi)
        XCTAssertEqual(palette.palette[16], RGB(0, 0, 0), "the color cube is standard")
        XCTAssertEqual(palette.palette[231], RGB(255, 255, 255))
        XCTAssertEqual(palette.palette[255], RGB(238, 238, 238))
        XCTAssertEqual(palette.background, t.background)
        XCTAssertEqual(palette.bold, t.bold)
    }

    func testBoldTextInTheDefaultColorUsesTheBoldColor() {
        var t = Self.sample()
        t.bold = RGB(hex: 0xFFCC00)
        let r = t.terminalTheme.resolve(fg: 0, bg: 0, attrs: VTAttr.bold, reverseVideo: false)
        XCTAssertEqual(r.fg, RGB(hex: 0xFFCC00))
        let plain = t.terminalTheme.resolve(fg: 0, bg: 0, attrs: 0, reverseVideo: false)
        XCTAssertEqual(plain.fg, t.foreground)
        let red = t.terminalTheme.resolve(fg: VTColor.tagIndex | 1, bg: 0, attrs: VTAttr.bold, reverseVideo: false)
        XCTAssertEqual(red.fg, t.ansi[9], "bold ANSI colors still brighten")
    }

    func testFontsThatAreNotInstalledFallBackToTheSystemFont() {
        var t = Self.sample()
        XCTAssertEqual(t.resolvedFont(size: 13).familyName, "Menlo")
        t.font = "NoSuchFont-Regular-XYZ"
        let fallback = t.resolvedFont(size: 13)
        XCTAssertEqual(fallback.fontName, NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName)
        t.font = nil
        XCTAssertEqual(t.resolvedFont(size: 11).pointSize, 11)
    }
}

final class ThemeCatalogTests: XCTestCase {
    private var tmp: TempDir!
    private var builtIn: URL!
    private var user: URL!

    override func setUpWithError() throws {
        tmp = TempDir()
        builtIn = tmp.url.appendingPathComponent("builtin")
        user = tmp.url.appendingPathComponent("user")
        for d in [builtIn!, user!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    private func write(_ theme: Theme, to dir: URL, file: String? = nil) throws {
        try theme.encoded().write(to: dir.appendingPathComponent(file ?? "\(theme.id).theme.json"))
    }

    func testBuiltInAndUserThemes() throws {
        try write(ThemeModelTests.sample(id: "pro", name: "Pro"), to: builtIn)
        try write(ThemeModelTests.sample(id: "basic", name: "Basic"), to: builtIn)
        try write(ThemeModelTests.sample(id: "mine", name: "Mine"), to: user)
        let c = ThemeCatalog.load(builtIn: builtIn, user: user)
        XCTAssertEqual(c.themes.map(\.id), ["basic", "pro", "mine"], "built-ins first, each group by name")
        XCTAssertTrue(c.isBuiltIn("pro"))
        XCTAssertFalse(c.isBuiltIn("mine"))
        XCTAssertEqual(c.theme("mine")?.name, "Mine")
        XCTAssertTrue(c.problems.isEmpty)
    }

    func testBrokenOrShadowingUserThemesAreSkippedAndReported() throws {
        try write(ThemeModelTests.sample(id: "pro", name: "Pro"), to: builtIn)
        try write(ThemeModelTests.sample(id: "pro", name: "Fake Pro"), to: user)
        try Data("{not json".utf8).write(to: user.appendingPathComponent("broken.theme.json"))
        try Data("ignored".utf8).write(to: user.appendingPathComponent("notes.txt"))
        let c = ThemeCatalog.load(builtIn: builtIn, user: user)
        XCTAssertEqual(c.themes.map(\.name), ["Pro"])
        XCTAssertEqual(c.problems.count, 2)
    }

    func testSavingAndDeletingUserThemes() throws {
        try write(ThemeModelTests.sample(id: "pro", name: "Pro"), to: builtIn)
        var c = ThemeCatalog.load(builtIn: builtIn, user: user)
        let mine = ThemeModelTests.sample(id: "mine", name: "Mine")
        try c.save(mine)
        XCTAssertEqual(ThemeCatalog.load(builtIn: builtIn, user: user).theme("mine"), mine)
        XCTAssertThrowsError(try c.save(ThemeModelTests.sample(id: "pro", name: "Pro")), "built-ins are read-only")
        try c.delete("mine")
        XCTAssertNil(ThemeCatalog.load(builtIn: builtIn, user: user).theme("mine"))
        XCTAssertThrowsError(try c.delete("pro"))
    }

    func testNewIDsAreUniqueAndValid() throws {
        try write(ThemeModelTests.sample(id: "my-theme", name: "My Theme"), to: user)
        let c = ThemeCatalog.load(builtIn: builtIn, user: user)
        XCTAssertEqual(c.newID(for: "My Theme"), "my-theme-2")
        XCTAssertEqual(c.newID(for: "Red Sands (copy)"), "red-sands-copy")
        XCTAssertEqual(c.newID(for: "!!!"), "theme")
    }
}
