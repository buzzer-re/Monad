//
//  GuestWindowLayoutTests.swift — where a Linux program's window is on the
//  Mac (GuestWindowLayout): its size in points, where the VM's display
//  lies behind it so that its own part shows, and what the Mac's pointer,
//  buttons and scrolling are in the program's terms.
//

import XCTest
@testable import Monad

final class GuestWindowLayoutTests: XCTestCase {
    private let display = GuestDisplaySize(width: 3840, height: 2160)

    private func window(x: Int = 0, y: Int = 0, width: Int = 800, height: Int = 600, scale: Int = 1,
                        inner: (Int, Int, Int, Int)? = nil, app: String = "foot", title: String = "foot") -> GuestWindow {
        let i = inner ?? (0, 0, width, height)
        return GuestWindow(id: 7, x: x, y: y, width: width, height: height, scale: scale,
                           innerX: i.0, innerY: i.1, innerWidth: i.2, innerHeight: i.3, appID: app, title: title)
    }

    /// The Mac's window is the program's window in points: its pixels by the scale it drew at.
    func testAWindowIsItsPixelsByItsScale() {
        XCTAssertEqual(GuestWindowLayout.contentSize(window()), CGSize(width: 800, height: 600))
        XCTAssertEqual(GuestWindowLayout.contentSize(window(width: 1600, height: 1200, scale: 2)), CGSize(width: 800, height: 600))
        XCTAssertEqual(GuestWindowLayout.contentSize(window(width: 801, height: 601, scale: 2)), CGSize(width: 400.5, height: 300.5))
        // A program that draws a shadow around its window: the window proper is what the Mac shows.
        XCTAssertEqual(GuestWindowLayout.contentSize(window(width: 900, height: 700, scale: 2, inner: (50, 40, 800, 600))),
                       CGSize(width: 400, height: 300))
    }

    /// The whole display lies behind the window, moved so that the
    /// window's own part is what shows through. Counted from the content's
    /// top left, as the display is: the content can then change size (the
    /// user dragging its edge) without the display behind it moving.
    func testTheDisplayLiesBehindTheWindow() {
        // A window at the display's top left: the display's top left corner is the content's.
        var frame = GuestWindowLayout.displayFrame(window(), display: display)
        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 3840, height: 2160))
        // Further right and down: the display moves left and up by as much.
        frame = GuestWindowLayout.displayFrame(window(x: 816, y: 100), display: display)
        XCTAssertEqual(frame, CGRect(x: -816, y: -100, width: 3840, height: 2160))
        // Drawn at 2: a point is two of the display's pixels.
        frame = GuestWindowLayout.displayFrame(window(x: 816, y: 100, width: 1600, height: 1200, scale: 2), display: display)
        XCTAssertEqual(frame, CGRect(x: -408, y: -50, width: 1920, height: 1080))
        // With a shadow around it: the window proper starts further in.
        frame = GuestWindowLayout.displayFrame(window(x: 816, y: 100, width: 900, height: 700, scale: 2, inner: (50, 40, 800, 600)),
                                               display: display)
        XCTAssertEqual(frame, CGRect(x: -433, y: -70, width: 1920, height: 1080))
        // An odd pixel at scale 2 is half a point, not a point lost.
        frame = GuestWindowLayout.displayFrame(window(x: 17, y: 33, width: 100, height: 100, scale: 2), display: display)
        XCTAssertEqual(frame.origin, CGPoint(x: -8.5, y: -16.5))
    }

    /// The pointer, from the content's top left in points, in the program's
    /// units from its surface's top left, in 256ths.
    func testThePointerIsInTheProgramsUnits() {
        XCTAssertTrue(GuestWindowLayout.pointer(CGPoint(x: 10, y: 5.5), in: window()) == (2560, 1408))
        XCTAssertTrue(GuestWindowLayout.pointer(CGPoint(x: 10, y: 5.5), in: window(width: 1600, height: 1200, scale: 2)) == (2560, 1408),
                      "a point is a unit at any scale")
        XCTAssertTrue(GuestWindowLayout.pointer(CGPoint(x: 10, y: 5), in: window(width: 900, height: 700, scale: 2, inner: (50, 40, 800, 600)))
                        == ((10 + 25) * 256, (5 + 20) * 256), "past the shadow the program drew")
        XCTAssertTrue(GuestWindowLayout.pointer(CGPoint(x: -3, y: -1), in: window()) == (-768, -256), "dragged outside the window")
        XCTAssertTrue(GuestWindowLayout.pointer(CGPoint(x: 1e12, y: -.infinity), in: window()) == (Int32.max, Int32.min))
        XCTAssertTrue(GuestWindowLayout.pointer(CGPoint(x: CGFloat.nan, y: 0), in: window()) == (0, 0))
    }

    func testButtonsAndScrolling() {
        XCTAssertEqual(GuestWindowLayout.button(0), 0x110, "left")
        XCTAssertEqual(GuestWindowLayout.button(1), 0x111, "right")
        XCTAssertEqual(GuestWindowLayout.button(2), 0x112, "middle")
        XCTAssertEqual(GuestWindowLayout.button(3), 0x113)
        XCTAssertEqual(GuestWindowLayout.button(4), 0x114)
        XCTAssertNil(GuestWindowLayout.button(5))
        XCTAssertNil(GuestWindowLayout.button(-1))
        // A trackpad scrolls by points; the content follows the fingers, so the program's "down" is the Mac's "up".
        XCTAssertTrue(GuestWindowLayout.scroll(deltaX: 2, deltaY: -10.5, precise: true) == (-512, 2688))
        // A mouse wheel scrolls by lines: 15 points each.
        XCTAssertTrue(GuestWindowLayout.scroll(deltaX: 0, deltaY: 1, precise: false) == (0, -15 * 256))
        XCTAssertTrue(GuestWindowLayout.scroll(deltaX: .infinity, deltaY: .nan, precise: true) == (Int32.min, 0))
    }

    /// What the Mac's title bar says: the program's title, and always whose window it is.
    func testATitleSaysWhoseWindowItIs() {
        XCTAssertEqual(GuestWindowLayout.title(window(title: "notes.txt"), vm: "dev"), "notes.txt — dev")
        XCTAssertEqual(GuestWindowLayout.title(window(app: "org.gnome.Calculator", title: ""), vm: "dev"), "org.gnome.Calculator — dev")
        XCTAssertEqual(GuestWindowLayout.title(window(app: "", title: ""), vm: "dev"), "Linux program — dev")
        let long = String(repeating: "x", count: 500)
        XCTAssertTrue(GuestWindowLayout.title(window(title: long), vm: "dev").hasSuffix(" — dev"), "a long title never pushes the VM's name out")
    }

    /// What changed from one list to the next.
    func testWhatChangedBetweenTwoLists() {
        let a = window(x: 0, title: "A"), a2 = window(x: 0, title: "A, changed")
        let b = GuestWindow(id: 8, x: 900, y: 0, width: 100, height: 100, scale: 1, innerX: 0, innerY: 0, innerWidth: 100, innerHeight: 100,
                            appID: "b", title: "B")
        var changes = GuestWindowLayout.changes(from: [], to: [a, b])
        XCTAssertEqual(changes.opened, [a, b])
        XCTAssertTrue(changes.changed.isEmpty && changes.closed.isEmpty)
        changes = GuestWindowLayout.changes(from: [a, b], to: [a2, b])
        XCTAssertEqual(changes.changed, [a2])
        XCTAssertTrue(changes.opened.isEmpty && changes.closed.isEmpty)
        changes = GuestWindowLayout.changes(from: [a, b], to: [b])
        XCTAssertEqual(changes.closed, [7])
        XCTAssertTrue(changes.opened.isEmpty && changes.changed.isEmpty)
        changes = GuestWindowLayout.changes(from: [a], to: [])
        XCTAssertEqual(changes.closed, [7])
    }
}
