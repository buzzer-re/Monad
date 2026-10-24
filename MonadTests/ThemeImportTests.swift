//
//  ThemeImportTests.swift — Terminal.app profiles (.terminal) and iTerm2
//  color presets (.itermcolors) in and out. Imported files are untrusted.
//

import AppKit
import XCTest
@testable import Monad

final class ThemeImportTests: XCTestCase {
    static let terminalProfiles = URL(fileURLWithPath:
        "/System/Applications/Utilities/Terminal.app/Contents/Resources/Initial Settings")

    private func sample() -> Theme {
        var t = ThemeModelTests.sample()
        t.backgroundImage = nil // .terminal stores images as bookmarks; not exported
        t.font = "Menlo-Regular" // profiles store PostScript names
        return t
    }

    // MARK: .terminal

    func testTerminalProfileRoundTrip() throws {
        let t = sample()
        let data = try ThemeExport.terminalProfile(t)
        var back = try ThemeImport.terminalProfile(data, id: t.id)
        XCTAssertEqual(back.name, t.name)
        back.id = t.id
        XCTAssertEqual(back, t)
    }

    func testMissingColorsUseTerminalAppDefaults() throws {
        let plist: [String: Any] = ["name": "Bare", "type": "Window Settings"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let t = try ThemeImport.terminalProfile(data, id: "bare")
        XCTAssertEqual(t.foreground, RGB(hex: 0x000000))
        XCTAssertEqual(t.background, RGB(hex: 0xFFFFFF))
        XCTAssertEqual(t.ansi, ThemeImport.terminalAppANSI)
        XCTAssertEqual(t.backgroundOpacity, 1)
        XCTAssertNil(t.font)
    }

    func testImportsTerminalAppsOwnProfiles() throws {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.terminalProfiles, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "terminal" } ?? []
        try XCTSkipIf(files.isEmpty, "Terminal.app's profiles are not on this machine")
        XCTAssertEqual(files.count, 12)
        for url in files {
            let t = try ThemeImport.terminalProfile(Data(contentsOf: url), id: "x")
            XCTAssertEqual(t.name, url.deletingPathExtension().lastPathComponent)
            XCTAssertNoThrow(try t.validate(), t.name)
        }
        let clear = try ThemeImport.terminalProfile(Data(contentsOf: Self.terminalProfiles
            .appendingPathComponent("Clear Dark.terminal")), id: "x")
        XCTAssertLessThan(clear.backgroundOpacity, 1, "Clear Dark is translucent")
        XCTAssertGreaterThan(clear.blur, 0)
        let basic = try ThemeImport.terminalProfile(Data(contentsOf: Self.terminalProfiles
            .appendingPathComponent("Basic.terminal")), id: "x")
        XCTAssertEqual(basic.background, RGB(hex: 0xFFFFFF))
        XCTAssertEqual(basic.foreground, RGB(hex: 0x000000))
        XCTAssertNil(basic.font, "Terminal's system font means our system monospaced font, not the UI font")
    }

    func testHostileProfilesAreRejected() throws {
        XCTAssertThrowsError(try ThemeImport.terminalProfile(Data("garbage".utf8), id: "x"))
        XCTAssertThrowsError(try ThemeImport.terminalProfile(Data(count: ThemeImport.maxFileSize + 1), id: "x"))
        // A color key holding an archived object of another class.
        let wrong = try NSKeyedArchiver.archivedData(withRootObject: NSString("not a color"), requiringSecureCoding: true)
        let plist: [String: Any] = ["name": "Evil", "TextColor": wrong]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        XCTAssertThrowsError(try ThemeImport.terminalProfile(data, id: "x"))
        // Not a dictionary at all.
        let array = try PropertyListSerialization.data(fromPropertyList: [1, 2], format: .binary, options: 0)
        XCTAssertThrowsError(try ThemeImport.terminalProfile(array, id: "x"))
    }

    // MARK: .itermcolors

    func testITermColorsRoundTrip() throws {
        var t = sample()
        t.font = nil          // .itermcolors carries colors only
        t.blur = 0
        t.cursorStyle = nil
        let data = try ThemeExport.itermColors(t)
        var back = try ThemeImport.itermColors(data, name: t.name, id: t.id)
        back.id = t.id
        XCTAssertEqual(back, t)
    }

    func testITermColorsInOtherColorSpacesAreConverted() throws {
        func color(_ r: Double, _ g: Double, _ b: Double, space: String) -> [String: Any] {
            ["Red Component": r, "Green Component": g, "Blue Component": b, "Color Space": space]
        }
        var plist: [String: Any] = [:]
        for i in 0..<16 { plist["Ansi \(i) Color"] = color(0, 0, 0, space: "sRGB") }
        plist["Foreground Color"] = color(1, 1, 1, space: "sRGB")
        plist["Background Color"] = color(0.5, 0.5, 0.5, space: "Calibrated")
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let t = try ThemeImport.itermColors(data, name: "Calibrated", id: "cal")
        XCTAssertEqual(t.foreground, RGB(hex: 0xFFFFFF))
        let expected = NSColor(calibratedRed: 0.5, green: 0.5, blue: 0.5, alpha: 1).usingColorSpace(.sRGB)!
        XCTAssertEqual(Int(t.background.r), Int((expected.redComponent * 255).rounded()))
        XCTAssertEqual(t.cursor, ThemeImport.defaultCursor, "missing entries get defaults")
    }

    func testITermColorsNeedAllSixteenANSIColors() throws {
        let plist: [String: Any] = ["Ansi 0 Color": ["Red Component": 0.0, "Green Component": 0.0, "Blue Component": 0.0]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertThrowsError(try ThemeImport.itermColors(data, name: "Partial", id: "p"))
    }

    // MARK: Files

    func testImportFromAFileNamesTheThemeAndPicksAFreeID() throws {
        let tmp = TempDir()
        let url = tmp.url.appendingPathComponent("Deep Sea.itermcolors")
        var t = sample()
        t.font = nil
        t.blur = 0
        t.cursorStyle = nil
        try ThemeExport.itermColors(t).write(to: url)
        let catalog = ThemeCatalog.load(builtIn: nil, user: nil)
        let imported = try ThemeImport.file(url, catalog: catalog)
        XCTAssertEqual(imported.name, "Deep Sea")
        XCTAssertEqual(imported.id, "deep-sea")
        XCTAssertThrowsError(try ThemeImport.file(tmp.url.appendingPathComponent("x.txt"), catalog: catalog))
    }
}
