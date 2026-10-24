//
//  ThemeChoiceTests.swift — which theme a tab uses: its own choice, else its
//  VM's, else the app default; "automatic" (or a theme that is gone)
//  follows the appearance. Changes apply to open tabs at once.
//

import AppKit
import XCTest
@testable import Monad

@MainActor
final class ThemeChoiceTests: XCTestCase {
    private let catalog = ThemeCatalog.load(builtIn: Bundle.main.resourceURL, user: nil)

    func testTabThenVMThenAppDefault() {
        func pick(_ tab: String?, _ vm: String?, _ app: String) -> String? {
            ThemeChoice.effective(tab: tab, vm: vm, app: app, catalog: catalog)?.id
        }
        XCTAssertEqual(pick("grass", "pro", "ocean"), "grass")
        XCTAssertEqual(pick(nil, "pro", "ocean"), "pro")
        XCTAssertEqual(pick(nil, nil, "ocean"), "ocean")
        XCTAssertNil(pick(nil, nil, ThemeCatalog.automaticID), "automatic follows the appearance")
        XCTAssertNil(pick("automatic", "pro", "ocean"), "a tab can choose to follow the appearance")
        XCTAssertNil(pick(nil, "deleted-theme", "ocean"), "a theme that is gone follows the appearance")
    }

    func testThemeMenuListsThemesAndMarksTheChoice() {
        let menu = NSMenu()
        ThemeMenu.fill(menu, catalog: catalog, selected: "pro", action: #selector(NSResponder.noResponder(for:)))
        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles.first, "Use VM or App Default")
        XCTAssertTrue(titles.contains("Automatic (Light/Dark)"))
        XCTAssertTrue(titles.contains("Pro") && titles.contains("Homebrew"))
        XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), ["Pro"])
        XCTAssertEqual(menu.items.first { $0.title == "Pro" }?.representedObject as? String, "pro")
        XCTAssertNil(menu.items.first?.representedObject, "the default entry clears the tab's choice")

        let none = NSMenu()
        ThemeMenu.fill(none, catalog: catalog, selected: nil, action: #selector(NSResponder.noResponder(for:)))
        XCTAssertEqual(none.items.filter { $0.state == .on }.map(\.title), ["Use VM or App Default"])
    }

    func testATabFollowsItsVMItsOwnChoiceAndTheAppDefault() async throws {
        let store = ThemeStore.shared
        let savedDefault = store.defaultThemeID
        defer { store.defaultThemeID = savedDefault }
        store.defaultThemeID = "ocean"

        let host = try FakeHost()
        // Real clock: a fast-forwarding one would time requests out at once.
        let client = HostClient(connect: { try host.connect() }, instanceRoot: host.fixture.root)
        client.start()
        defer { client.stop() }
        let tab = TerminalSessionViewController(target: .defaultVM, host: client)
        _ = tab.view
        tab.start()
        defer { tab.close() }
        await assertEventually(timeout: 20) { tab.vm?.state == .ready }
        await assertEventually { tab.terminalView.activeTheme.id == "ocean" }

        var config = try XCTUnwrap(tab.vm).config
        config.theme = "grass"
        try await client.update(config)
        await assertEventually("VM theme") { tab.terminalView.activeTheme.id == "grass" }

        tab.themeOverride = "homebrew"
        XCTAssertEqual(tab.terminalView.activeTheme.id, "homebrew")
        tab.themeOverride = nil
        XCTAssertEqual(tab.terminalView.activeTheme.id, "grass")

        config.theme = nil
        try await client.update(config)
        await assertEventually("back to the app default") { tab.terminalView.activeTheme.id == "ocean" }
        store.defaultThemeID = "red-sands"
        await assertEventually("app default changes apply live") { tab.terminalView.activeTheme.id == "red-sands" }
    }
}
