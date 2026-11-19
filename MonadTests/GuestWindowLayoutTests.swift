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

    /// A program that opens larger than the Mac's screen has room for (Firefox
    /// keeps the size it had, whatever the screen) is asked for a size that fits.
    func testAWindowLargerThanTheScreenIsAskedToFit() {
        let room = CGSize(width: 1728, height: 1050)
        XCTAssertNil(GuestWindowLayout.sizeThatFits(CGSize(width: 800, height: 600), room: room))
        XCTAssertNil(GuestWindowLayout.sizeThatFits(CGSize(width: 1728, height: 1050), room: room))
        XCTAssertEqual(GuestWindowLayout.sizeThatFits(CGSize(width: 1884, height: 1000), room: room), CGSize(width: 1728, height: 1000))
        XCTAssertEqual(GuestWindowLayout.sizeThatFits(CGSize(width: 1884.5, height: 4000), room: room), CGSize(width: 1728, height: 1050))
        XCTAssertNil(GuestWindowLayout.sizeThatFits(CGSize(width: 800, height: 600), room: .zero)) // no screen known: as it is
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

    /// What the program drew (its picture, all of the window with any
    /// shadow around it) lies in the Mac window's content so that the
    /// window proper is what shows: counted from the content's top left,
    /// in points. The content can then change size (the user dragging its
    /// edge) without the picture moving.
    func testThePictureLiesInTheWindowSoThatItsOwnPartShows() {
        XCTAssertEqual(GuestWindowLayout.pictureFrame(window()), CGRect(x: 0, y: 0, width: 800, height: 600))
        // Where it stands on the window manager's sheet is nothing to the Mac.
        XCTAssertEqual(GuestWindowLayout.pictureFrame(window(x: 816, y: 100)), CGRect(x: 0, y: 0, width: 800, height: 600))
        // Drawn at 2: a point is two of its pixels.
        XCTAssertEqual(GuestWindowLayout.pictureFrame(window(width: 1600, height: 1200, scale: 2)), CGRect(x: 0, y: 0, width: 800, height: 600))
        // With a shadow around it: the picture begins up and left of the content by as much.
        XCTAssertEqual(GuestWindowLayout.pictureFrame(window(width: 900, height: 700, scale: 2, inner: (50, 40, 800, 600))),
                       CGRect(x: -25, y: -20, width: 450, height: 350))
        // An odd pixel at scale 2 is half a point, not a point lost.
        XCTAssertEqual(GuestWindowLayout.pictureFrame(window(width: 101, height: 99, scale: 2, inner: (17, 33, 50, 50))),
                       CGRect(x: -8.5, y: -16.5, width: 50.5, height: 49.5))
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

    /// A popup stands on its window where the program put it, in points
    /// from the window's own top left, down and right.
    func testAPopupStandsOnItsWindow() {
        var menu = window(x: 900, width: 120, height: 80, scale: 2)
        menu.parent = 7
        menu.offsetX = 20
        menu.offsetY = 88
        XCTAssertEqual(GuestWindowLayout.popupOffset(menu, on: window(width: 1600, height: 1200, scale: 2)), CGPoint(x: 10, y: 44))
        XCTAssertEqual(GuestWindowLayout.popupOffset(menu, on: window()), CGPoint(x: 20, y: 88), "its window's pixels, not its own")
        menu.offsetX = -31
        menu.offsetY = -500
        XCTAssertEqual(GuestWindowLayout.popupOffset(menu, on: window(scale: 2)), CGPoint(x: -15.5, y: -250), "it may reach outside its window")
    }

    /// A popup is shown only where it touches the window it is on: one
    /// put elsewhere on the screen would be a window with no title to say
    /// whose it is.
    func testAPopupAwayFromItsWindowIsNotShown() {
        let window = CGSize(width: 400, height: 300)
        func touches(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 100, _ h: CGFloat = 60) -> Bool {
            GuestWindowLayout.popupTouches(offset: CGPoint(x: x, y: y), size: CGSize(width: w, height: h), window: window)
        }
        XCTAssertTrue(touches(10, 44), "a menu under a button")
        XCTAssertTrue(touches(350, 280), "reaching out past the corner")
        XCTAssertTrue(touches(400, 100), "a submenu beside the window's edge")
        XCTAssertTrue(touches(100, 300), "a list that drops below the window")
        XCTAssertTrue(touches(-100, 50), "to its left")
        XCTAssertTrue(touches(100, -60), "above it")
        XCTAssertFalse(touches(420, 100), "away to the right")
        XCTAssertFalse(touches(100, 330), "away below")
        XCTAssertFalse(touches(-2000, -2000))
        XCTAssertFalse(touches(.nan, 0))
        XCTAssertFalse(touches(0, 0, 0, 10), "no size")
        XCTAssertFalse(touches(0, 0, 20000, 20000), "larger than any screen")
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

    /// The Mac's title bar takes the colour of the bar the program drew
    /// under it, and its text is light on a dark one.
    func testATitleBarIsLightOrDarkByItsColour() {
        XCTAssertFalse(GuestWindowLayout.isDark(0xfafafa))
        XCTAssertFalse(GuestWindowLayout.isDark(0xebebeb))
        XCTAssertTrue(GuestWindowLayout.isDark(0x2e2e32))
        XCTAssertTrue(GuestWindowLayout.isDark(0x000000))
        XCTAssertTrue(GuestWindowLayout.isDark(0x0000ff), "blue is dark to the eye")
        XCTAssertFalse(GuestWindowLayout.isDark(0xffff00), "yellow is light")
        XCTAssertTrue(GuestWindowLayout.isDark(0xff2e2e32), "what is above the colour's bits is not looked at")
    }

    /// A program asks for its window to be moved, zoomed or put away. It
    /// is done when it is the user's doing: the user's click or key in
    /// that window came just before. A program gets nothing moved or
    /// zoomed by asking on its own.
    func testAProgramsWishIsDoneOnlyAsTheUsersDoing() {
        let t0 = Date(timeIntervalSinceReferenceDate: 500)
        func done(_ ask: GuestWindowAsk, window: UInt32 = 3, inputIn: UInt32 = 3, after: TimeInterval?, leftDown: Bool = false) -> Bool {
            GuestWindowLayout.wishIsTheUsers(ask, window: window, lastInputWindow: inputIn, lastInputAt: after.map { t0.addingTimeInterval(-$0) },
                                             leftButtonDown: leftDown, now: t0)
        }
        // A drag: the button is down in that window.
        XCTAssertTrue(done(.move, after: 0.2, leftDown: true))
        XCTAssertFalse(done(.move, after: 0.2, leftDown: false), "no button is held: nothing to drag by")
        XCTAssertFalse(done(.move, inputIn: 4, after: 0.2, leftDown: true), "the button is down in another window")
        XCTAssertFalse(done(.move, after: nil, leftDown: true))
        XCTAssertFalse(done(.move, after: 30, leftDown: true), "held too long to be a drag just begun")
        // A double click on its bar, or a key: soon after.
        XCTAssertTrue(done(.zoom(true), after: 0.3))
        XCTAssertTrue(done(.zoom(false), after: 0.3))
        XCTAssertTrue(done(.minimize, after: 0.3))
        XCTAssertFalse(done(.zoom(true), after: 5), "long after the user touched it")
        XCTAssertFalse(done(.minimize, inputIn: 4, after: 0.3), "the user is in another window")
        XCTAssertFalse(done(.zoom(true), after: nil), "the user never touched it")
        XCTAssertFalse(done(.zoom(true), after: -1), "a clock that went back")
    }
}
