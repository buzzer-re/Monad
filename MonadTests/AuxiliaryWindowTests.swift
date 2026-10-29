//
//  AuxiliaryWindowTests.swift — Monad's windows other than terminals (a VM's
//  settings, Settings, Themes, the VM list, prompts) open on the Space in
//  front, a full-screen one too, as windows that take clicks: one opened over
//  a full-screen terminal could neither be used nor closed (2026-10-29).
//

import AppKit
import XCTest
@testable import Monad

@MainActor
final class AuxiliaryWindowTests: XCTestCase {
    func testItJoinsTheSpaceInFrontFullScreenToo() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered,
                         defer: true)
        w.collectionBehavior = [.managed]
        w.joinsFullScreenSpaces()
        XCTAssertTrue(w.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(w.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(w.collectionBehavior.contains(.managed), "what it had stays")
        XCTAssertFalse(w.collectionBehavior.contains(.canJoinAllSpaces), "not on every Space at once")
        XCTAssertFalse(w.collectionBehavior.contains(.fullScreenPrimary), "never a full-screen window of its own")
    }
}
