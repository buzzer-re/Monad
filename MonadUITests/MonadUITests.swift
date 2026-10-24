//
//  MonadUITests.swift — launch smoke test.
//
//  The app is launched with -MonadHostShellOnly (Debug builds) so UI tests
//  never provision or boot virtual machines.
//

import AppKit
import XCTest

final class MonadUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var app: XCUIApplication!
    private var tools: URL!

    override func tearDownWithError() throws {
        app?.terminate()
        if let tools { try? FileManager.default.removeItem(at: tools) }
    }

    /// Helper functions for the shell under test, loaded through $ENV (a file
    /// the sandboxed test runner writes is quarantined and cannot be executed,
    /// but it can be read). Tests type only letters, digits and spaces:
    /// XCUITest synthesizes symbols as if on a US layout, so on other layouts
    /// (e.g. JIS) quotes, braces and backslashes change.
    private func makeTools() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("monad-uitest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        # settitle NAME: set the window title (OSC 2) and print a marker.
        settitle() { printf '\\033]2;%s\\007' "$1"; echo "named $1"; }
        """.write(to: dir.appendingPathComponent("shrc"), atomically: true, encoding: .utf8)
        return dir
    }

    /// Launch with host-shell tabs running a plain /bin/sh (no VM, no rc files).
    private func launch() throws {
        tools = try makeTools()
        app = XCUIApplication()
        app.launchArguments = ["-MonadHostShellOnly", "YES", "-MonadTestShell", "/bin/sh"]
        app.launchEnvironment["ENV"] = tools.appendingPathComponent("shrc").path
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    /// The terminal of the front tab, exposed to Accessibility as a text area.
    private var terminal: XCUIElement { app.windows.firstMatch.textViews["Terminal"] }

    private var screenText: String { (terminal.value as? String) ?? "<no terminal value>" }

    private func waitForScreen(containing text: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: terminal)
        let result = XCTWaiter().wait(for: [exp], timeout: 5)
        XCTAssertEqual(result, .completed, "screen does not show '\(text)':\n\(screenText)", file: file, line: line)
    }

    /// Name the current tab through the terminal's own title sequence (OSC 2).
    private func nameCurrentTab(_ name: String) {
        app.typeText("settitle \(name)\r")
        waitForScreen(containing: "named \(name)")
        waitForFrontTitle(prefix: name)
    }

    /// The tabs here are host tabs: a title set in one shows after "host: ".
    private func waitForFrontTitle(prefix title: String, file: StaticString = #filePath, line: UInt = #line) {
        let prefix = "host: \(title)"
        let window = app.windows.firstMatch
        let predicate = NSPredicate(format: "title BEGINSWITH %@", prefix)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: window)
        let result = XCTWaiter().wait(for: [exp], timeout: 5)
        XCTAssertEqual(result, .completed,
                       "front window title is '\(window.title)', expected '\(prefix)…'. Screen:\n\(screenText)",
                       file: file, line: line)
    }

    @MainActor
    func testCommandDigitsSelectTabs() throws {
        try launch()
        nameCurrentTab("tab1")
        app.typeKey("t", modifierFlags: .command)
        nameCurrentTab("tab2")
        app.typeKey("t", modifierFlags: .command)
        nameCurrentTab("tab3")

        app.typeKey("1", modifierFlags: .command)
        waitForFrontTitle(prefix: "tab1")
        app.typeKey("2", modifierFlags: .command)
        waitForFrontTitle(prefix: "tab2")
        app.typeKey("9", modifierFlags: .command)
        waitForFrontTitle(prefix: "tab3")
        // ⌘5 does not exist: nothing changes.
        app.typeKey("5", modifierFlags: .command)
        waitForFrontTitle(prefix: "tab3")
    }

    @MainActor
    func testLaunchShowsAWorkingTerminal() throws {
        try launch()
        XCTAssertTrue(terminal.waitForExistence(timeout: 5), "terminal is exposed to Accessibility")
        app.typeText("seq 40 42\r")
        waitForScreen(containing: "41")
    }

    @MainActor
    func testProgramsCanSetTheWindowTitle() throws {
        try launch()
        nameCurrentTab("alive")
    }

    /// View ▸ Theme ▸ <name> for the front tab.
    private func chooseTheme(_ name: String) {
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Theme"].hover()
        let item = app.menuBars.menuItems[name]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "no theme \(name) in View ▸ Theme")
        item.click()
    }

    /// Average brightness (0…1) of the empty lower right of the terminal.
    private func terminalBrightness() -> Double {
        let image = terminal.screenshot().image
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return -1 }
        let rep = NSBitmapImageRep(cgImage: cg)
        var total = 0.0, n = 0.0
        for fx in stride(from: 0.75, through: 0.95, by: 0.05) {
            for fy in stride(from: 0.75, through: 0.95, by: 0.05) {
                guard let c = rep.colorAt(x: Int(Double(rep.pixelsWide) * fx), y: Int(Double(rep.pixelsHigh) * fy))?
                    .usingColorSpace(.sRGB) else { continue }
                total += Double(c.redComponent + c.greenComponent + c.blueComponent) / 3
                n += 1
            }
        }
        return n > 0 ? total / n : -1
    }

    @MainActor
    func testAThemeChosenForATabIsShownAtOnce() throws {
        try launch()
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        chooseTheme("Basic")      // white background
        let light = expectation(for: NSPredicate { _, _ in self.terminalBrightness() > 0.8 }, evaluatedWith: nil)
        wait(for: [light], timeout: 5)
        chooseTheme("Homebrew")   // black background
        let dark = expectation(for: NSPredicate { _, _ in self.terminalBrightness() < 0.2 }, evaluatedWith: nil)
        wait(for: [dark], timeout: 5)
    }
}
