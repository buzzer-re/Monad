//
//  BuiltInThemeTests.swift — the themes shipped with Monad: Terminal.app's
//  twelve (generated from its own profiles, which the test re-reads when
//  they are on this Mac) and Monad's light and dark defaults.
//

import XCTest
@testable import Monad

final class BuiltInThemeTests: XCTestCase {
    private let catalog = ThemeCatalog.load(builtIn: Bundle.main.resourceURL, user: nil)

    static let terminalApp: [(id: String, name: String)] = [
        ("basic", "Basic"), ("clear-dark", "Clear Dark"), ("clear-light", "Clear Light"), ("grass", "Grass"),
        ("homebrew", "Homebrew"), ("man-page", "Man Page"), ("novel", "Novel"), ("ocean", "Ocean"), ("pro", "Pro"),
        ("red-sands", "Red Sands"), ("silver-aerogel", "Silver Aerogel"), ("solid-colors", "Solid Colors"),
    ]

    func testEveryBuiltInIsShipped() {
        XCTAssertTrue(catalog.problems.isEmpty, "\(catalog.problems)")
        let ids = Set(catalog.themes.map(\.id))
        for t in Self.terminalApp { XCTAssertTrue(ids.contains(t.id), t.id) }
        XCTAssertTrue(ids.contains("monad-dark") && ids.contains("monad-light"))
        XCTAssertEqual(catalog.themes.count, 14)
        XCTAssertTrue(catalog.themes.allSatisfy { catalog.isBuiltIn($0.id) })
    }

    func testTerminalAppThemesMatchTerminalAppsProfiles() throws {
        let dir = ThemeImportTests.terminalProfiles
        try XCTSkipIf(!FileManager.default.fileExists(atPath: dir.path), "Terminal.app's profiles are not on this Mac")
        for t in Self.terminalApp {
            let data = try Data(contentsOf: dir.appendingPathComponent("\(t.name).terminal"))
            let fromTerminal = try ThemeImport.terminalProfile(data, id: t.id)
            XCTAssertEqual(catalog.theme(t.id), fromTerminal, t.name)
        }
    }

    func testMonadDefaultsKeepTodaysColors() throws {
        let dark = try XCTUnwrap(catalog.theme("monad-dark")).terminalTheme
        let light = try XCTUnwrap(catalog.theme("monad-light")).terminalTheme
        XCTAssertEqual(dark, TerminalTheme.dark)
        XCTAssertEqual(light, TerminalTheme.light)
    }

    func testAutomaticFollowsTheAppearance() throws {
        XCTAssertEqual(catalog.resolve(ThemeCatalog.automaticID, dark: true).id, "monad-dark")
        XCTAssertEqual(catalog.resolve(ThemeCatalog.automaticID, dark: false).id, "monad-light")
        XCTAssertEqual(catalog.resolve("pro", dark: false).id, "pro")
        XCTAssertEqual(catalog.resolve("deleted-theme", dark: true).id, "monad-dark", "a missing theme falls back")
    }
}
