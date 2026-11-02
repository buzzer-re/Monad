//
//  TerminalWindowTests.swift — terminal windows and their tabs: a new tab
//  (⌘T) joins the window in front without changing its size or the grid
//  of the terminal already in it (seen: each ⌘T changed the window "a tiny
//  bit", 2026-11-02).
//

import XCTest
@testable import Monad

@MainActor
final class TerminalWindowTests: XCTestCase {
    private var controllers: [TerminalWindowController] = []

    override func tearDown() {
        for c in controllers { c.window?.close() }
        controllers = []
        super.tearDown()
    }

    /// A window as AppDelegate.open makes one, not started (no shell).
    private func controller() -> TerminalWindowController {
        let c = TerminalWindowController(target: .host)
        controllers.append(c)
        return c
    }

    func testANewTabKeepsTheWindowsSize() throws {
        let first = try XCTUnwrap(controller().window)
        first.makeKeyAndOrderFront(nil)
        // Where the user left it: not the size a new window starts at.
        first.setFrame(NSRect(x: 100, y: 100, width: 913, height: 577), display: true)
        let frame = first.frame
        for n in 2...4 {
            let next = controller()
            next.join(first)
            let window = try XCTUnwrap(next.window)
            window.makeKeyAndOrderFront(nil)
            XCTAssertEqual(window.frame, frame, "tab \(n): the new tab takes the window's place")
            XCTAssertEqual(window.contentResizeIncrements, NSSize(width: 1, height: 1), "tab \(n): no cell steps in a tab group")
        }
        first.tabGroup?.selectedWindow = first
        XCTAssertEqual(first.frame, frame, "back on the first tab")
    }
}
