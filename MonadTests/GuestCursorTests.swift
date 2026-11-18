//
//  GuestCursorTests.swift — how the Mac's pointer looks over a Linux
//  program's window (GuestCursor): one of the Mac's own cursors, picked by
//  the number the VM's window manager says, never a picture from the VM.
//

import AppKit
import XCTest
@testable import Monad

final class GuestCursorTests: XCTestCase {
    /// The numbers are wp_cursor_shape_device_v1's shapes; 0 is no pointer at all.
    func testAShapeIsOneOfTheMacsCursors() {
        XCTAssertEqual(GuestCursor(shape: 0), .hidden)
        XCTAssertEqual(GuestCursor(shape: 1), .arrow)
        XCTAssertEqual(GuestCursor(shape: 2), .contextMenu)
        XCTAssertEqual(GuestCursor(shape: 4), .pointingHand)
        XCTAssertEqual(GuestCursor(shape: 8), .crosshair)
        XCTAssertEqual(GuestCursor(shape: 9), .text)
        XCTAssertEqual(GuestCursor(shape: 10), .verticalText)
        XCTAssertEqual(GuestCursor(shape: 12), .copy)
        XCTAssertEqual(GuestCursor(shape: 15), .notAllowed)
        XCTAssertEqual(GuestCursor(shape: 16), .openHand)
        XCTAssertEqual(GuestCursor(shape: 17), .closedHand)
        XCTAssertEqual(GuestCursor(shape: 18), .resize(.right))
        XCTAssertEqual(GuestCursor(shape: 21), .resize(.topLeft))
        XCTAssertEqual(GuestCursor(shape: 26), .resize(.leftRight))
        XCTAssertEqual(GuestCursor(shape: 27), .resize(.upDown))
        XCTAssertEqual(GuestCursor(shape: 30), .resize(.column))
        XCTAssertEqual(GuestCursor(shape: 33), .zoomIn)
        // Shapes the Mac has no cursor of its own for, and numbers that are no shape: the arrow.
        for shape in [3, 5, 6, 35, 37, -1, 1000, Int.max, Int.min] {
            XCTAssertEqual(GuestCursor(shape: shape), .arrow, "\(shape)")
        }
    }

    @MainActor
    func testEveryShapeHasACursor() {
        for shape in 0...GuestCursor.lastShape {
            let cursor = GuestCursor(shape: shape).mac
            XCTAssertGreaterThan(cursor.image.size.width, 0, "\(shape)")
        }
        XCTAssertTrue(GuestCursor.text.mac === NSCursor.iBeam)
        XCTAssertTrue(GuestCursor.pointingHand.mac === NSCursor.pointingHand)
        XCTAssertTrue(GuestCursor.arrow.mac === NSCursor.arrow)
        XCTAssertFalse(GuestCursor.hidden.mac === NSCursor.arrow)
        XCTAssertTrue(GuestCursor.hidden.mac === GuestCursor.hidden.mac, "one cursor, not a new one each time the pointer moves")
    }
}
