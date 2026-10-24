//
//  ClipboardPolicyTests.swift — when a guest may set the Mac's clipboard
//  (OSC 52): only with the setting on, only from the frontmost tab, and
//  never more than 100 KiB (F-07).
//

import XCTest
@testable import Monad

final class ClipboardPolicyTests: XCTestCase {
    func testAWriteNeedsTheSettingTheFrontmostTabAndASmallSize() {
        XCTAssertEqual(ClipboardPolicy.maxBytes, 100 * 1024)
        XCTAssertEqual(ClipboardPolicy.verdict(enabled: true, bytes: 12, frontmost: true), .write)
        XCTAssertEqual(ClipboardPolicy.verdict(enabled: true, bytes: ClipboardPolicy.maxBytes, frontmost: true), .write)
        XCTAssertEqual(ClipboardPolicy.verdict(enabled: false, bytes: 12, frontmost: true), .ignore)
        XCTAssertEqual(ClipboardPolicy.verdict(enabled: true, bytes: ClipboardPolicy.maxBytes + 1, frontmost: true),
                       .refuse("The VM tried to copy more than 100 KB to the clipboard. Nothing was copied."))
        XCTAssertEqual(ClipboardPolicy.verdict(enabled: true, bytes: 12, frontmost: false),
                       .refuse("A tab in the background tried to copy to the clipboard. Nothing was copied."))
    }
}
