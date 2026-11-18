//
//  GuestWindowProtocolTests.swift — MonadHost's end of the channel to a
//  Linux VM's window manager (GuestWM/mwm_ctl.h): what the guest says of
//  its windows is read as hostile, and what MonadHost says is exactly the
//  lines the window manager reads.
//

import XCTest
@testable import Monad

final class GuestWindowProtocolTests: XCTestCase {
    private func read(_ text: String, into reader: inout GuestWindowReader) -> [GuestWindowEvent] {
        reader.feed(Data(text.utf8))
    }

    /// The lines as `mwm_ctl.c` writes them (CTests/test_wm_ctl.c has the same text).
    func testTheWindowsAreRead() {
        var reader = GuestWindowReader()
        var events = read("monad-wm 1 3840 2160\nwindows 7 2\n", into: &reader)
        XCTAssertEqual(events, [.hello(display: GuestDisplaySize(width: 3840, height: 2160))])
        events = read("window 1 0 0 696 468 1 0 0 696 468 0 0 0 foot foot\n" +
                      "window 2 712 0 1600 1200 2 52 46 1496 1108 0 0 0 org.gnome.Calculator 50%25%20of%20caf%C3%A9\n", into: &reader)
        XCTAssertEqual(events, [], "a list is told once it is whole")
        events = read("end\n", into: &reader)
        let foot = GuestWindow(id: 1, x: 0, y: 0, width: 696, height: 468, scale: 1,
                               innerX: 0, innerY: 0, innerWidth: 696, innerHeight: 468, appID: "foot", title: "foot")
        let calculator = GuestWindow(id: 2, x: 712, y: 0, width: 1600, height: 1200, scale: 2,
                                     innerX: 52, innerY: 46, innerWidth: 1496, innerHeight: 1108,
                                     appID: "org.gnome.Calculator", title: "50% of café")
        XCTAssertEqual(events, [.windows([foot, calculator])])
        XCTAssertFalse(reader.isBroken)
        XCTAssertEqual(read("windows 8 0\nend\n", into: &reader), [.windows([])])
        XCTAssertEqual(read("windows 9 1\nwindow 3 0 0 10 10 1 0 0 10 10 0 0 0 - -\nend\n", into: &reader),
                       [.windows([GuestWindow(id: 3, x: 0, y: 0, width: 10, height: 10, scale: 1,
                                              innerX: 0, innerY: 0, innerWidth: 10, innerHeight: 10, appID: "", title: "")])])
    }

    /// Bytes arrive as they like: a line cut anywhere is still one line.
    func testALineInPiecesIsOneLine() {
        var reader = GuestWindowReader()
        let text = "monad-wm 1 1920 1200\nwindows 1 1\nwindow 5 16 32 100 50 1 0 0 100 50 0 0 0 app Title\nend\n"
        var events: [GuestWindowEvent] = []
        for byte in text.utf8 { events += reader.feed(Data([byte])) }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last, .windows([GuestWindow(id: 5, x: 16, y: 32, width: 100, height: 50, scale: 1,
                                                          innerX: 0, innerY: 0, innerWidth: 100, innerHeight: 50,
                                                          appID: "app", title: "Title")]))
    }

    /// A word the window manager of a newer Monad may say is skipped.
    func testALineItDoesNotKnowIsSkipped() {
        var reader = GuestWindowReader()
        XCTAssertEqual(read("monad-wm 1 1920 1200\ncursor text\nwindows 1 0\nend\n", into: &reader),
                       [.hello(display: GuestDisplaySize(width: 1920, height: 1200)), .windows([])])
        XCTAssertFalse(reader.isBroken)
    }

    /// Whatever does not fit ends the connection: nothing of it is shown,
    /// and nothing that comes after is read.
    func testWhatDoesNotFitBreaksTheConnection() {
        let hello = "monad-wm 1 1920 1200\n"
        let broken: [(String, String)] = [
            ("windows 1 0\nend\n", "windows before the hello"),
            (hello + hello, "a second hello"),
            ("monad-wm 2 1920 1200\n", "a version this Monad does not speak"),
            ("monad-wm 1 0 1200\n", "a display with no width"),
            ("monad-wm 1 99999 1200\n", "a display wider than any"),
            (hello + "windows 1 65\n", "more windows than there may be"),
            (hello + "windows 1 1\nend\n", "fewer windows than said"),
            (hello + "windows 1 0\nwindow 1 0 0 10 10 1 0 0 10 10 0 0 0 a b\nend\n", "more windows than said"),
            (hello + "window 1 0 0 10 10 1 0 0 10 10 0 0 0 a b\n", "a window outside a list"),
            (hello + "end\n", "an end with no list"),
            (hello + "windows 1 1\nwindows 2 0\n", "a list inside a list"),
            (hello + "windows 1 2\nwindow 1 0 0 10 10 1 0 0 10 10 0 0 0 a b\nwindow 1 20 0 10 10 1 0 0 10 10 0 0 0 a b\nend\n", "an id twice"),
            (hello + "windows 1 1\nwindow 0 0 0 10 10 1 0 0 10 10 0 0 0 a b\nend\n", "the id that means no window"),
            (hello + "windows 1 1\nwindow 1 0 0 0 10 1 0 0 10 10 0 0 0 a b\nend\n", "no width"),
            (hello + "windows 1 1\nwindow 1 1900 0 100 10 1 0 0 100 10 0 0 0 a b\nend\n", "past the display's edge"),
            (hello + "windows 1 1\nwindow 1 -5 0 10 10 1 0 0 10 10 0 0 0 a b\nend\n", "a negative place"),
            (hello + "windows 1 1\nwindow 1 0 0 10 10 0 0 0 10 10 0 0 0 a b\nend\n", "no scale"),
            (hello + "windows 1 1\nwindow 1 0 0 10 10 9 0 0 10 10 0 0 0 a b\nend\n", "a scale no screen has"),
            (hello + "windows 1 1\nwindow 1 0 0 10 10 1 5 5 10 10 0 0 0 a b\nend\n", "an inner part reaching outside"),
            (hello + "windows 1 1\nwindow 1 0 0 10 10 1 0 0 0 10 0 0 0 a b\nend\n", "an inner part with no width"),
            (hello + "windows 1 1\nwindow 1 0 0 10 10 1 0 0 10 10 0 0 0 a\nend\n", "a word missing"),
            (hello + "windows 1 1\nwindow 1 0 0 10 10 1 0 0 10 10 0 0 0 a b c\nend\n", "a word too many"),
            (hello + "windows 1 1\nwindow 1 0 0 10 10 1 0 0 10 10 0 0 0 a  b\nend\n", "an empty word"),
            (hello + "windows 1 1\nwindow 1 0 0 0x10 10 1 0 0 10 10 0 0 0 a b\nend\n", "a number that is not decimal"),
            (hello + "windows 1 1\nwindow 1 0 0 010 10 1 0 0 10 10 0 0 0 a b\nend\n", "a number with a leading zero"),
            (hello + "windows 1 1\nwindow 99999999999 0 0 10 10 1 0 0 10 10 0 0 0 a b\nend\n", "a number too large"),
            (hello + "windows 1 1\nwindow 1 0 0 10 10 1 0 0 10 10 0 0 0 a %ZZ\nend\n", "a %XX that is none"),
            (hello + "windows 1 1\nwindow 1 0 0 10 10 1 0 0 10 10 0 0 0 a %4\nend\n", "a %XX cut short"),
            (hello + "windows 1 1\nwindow 1 0 0 10 10 1 0 0 10 10 0 0 0 a caf\u{e9}\nend\n", "bytes that are not plain text"),
            (hello + "windows 1 1\nwindow 1 0 0 10 10 1 0 0 10 10 0 0 0 a b\tc\nend\n", "a control character"),
            (hello + "windows 1 1\nwindow 1 0 0 10 10 1 0 0 10 10 0 0 0 a " + String(repeating: "%41", count: 129) + "\nend\n",
             "a title longer than one may be"),
            (hello + String(repeating: "x", count: GuestWindowReader.maxLineLength + 1), "a line that never ends"),
            (hello + "windows 1 1\nwindow 1 0 0 10 10 1 0 0 10 10 1 0 0 a b\nend\n", "a popup on itself"),
            (hello + "windows 1 1\nwindow 1 0 0 10 10 1 0 0 10 10 7 0 0 a b\nend\n", "a popup on a window that is not told"),
            (hello + "windows 1 2\nwindow 1 0 0 10 10 1 0 0 10 10 2 0 0 a b\nwindow 2 20 0 10 10 1 0 0 10 10 1 0 0 a b\nend\n",
             "two popups on each other"),
            (hello + "windows 1 1\nwindow 1 0 0 10 10 1 0 0 10 10 0 5 0 a b\nend\n", "a window of its own that says where it stands on another"),
            (hello + "windows 1 2\nwindow 1 0 0 10 10 1 0 0 10 10 0 0 0 a b\nwindow 2 20 0 10 10 1 0 0 10 10 1 99999999 0 a b\nend\n",
             "a popup further from its window than any screen is wide"),
            (hello + "windows 1 2\nwindow 1 0 0 10 10 1 0 0 10 10 0 0 0 a b\nwindow 2 20 0 10 10 1 0 0 10 10 1 +5 0 a b\nend\n",
             "a number with a plus"),
            (hello + "windows 1 2\nwindow 1 0 0 10 10 1 0 0 10 10 0 0 0 a b\nwindow 2 20 0 10 10 1 0 0 10 10 1 -0 0 a b\nend\n",
             "a minus nothing"),
        ]
        for (text, what) in broken {
            var reader = GuestWindowReader()
            let events = read(text, into: &reader)
            XCTAssertTrue(reader.isBroken, what)
            XCTAssertFalse(events.contains { if case .windows = $0 { return true } else { return false } }, what)
            XCTAssertEqual(read("windows 5 0\nend\n", into: &reader), [], "\(what): nothing more is read")
        }
    }

    /// A popup (a menu) is told with the window it is on and where it
    /// stands on it; it may reach outside it, and menus have menus.
    func testPopupsAreToldWithTheirWindow() {
        var reader = GuestWindowReader()
        _ = read("monad-wm 1 1920 1200\n", into: &reader)
        let events = read("windows 4 3\n" +
                          "window 1 0 0 400 300 2 0 0 400 300 0 0 0 app Window\n" +
                          "window 2 416 0 120 80 2 4 4 112 72 1 20 88 - -\n" +
                          "window 3 552 0 60 40 2 0 0 60 40 2 -30 -500 - -\n" +
                          "end\n", into: &reader)
        guard case .windows(let windows)? = events.first, windows.count == 3 else { return XCTFail("no list: \(events), broken \(reader.isBroken)") }
        XCTAssertEqual(windows[0].parent, 0)
        XCTAssertEqual([windows[1].parent, UInt32(windows[1].offsetX), UInt32(windows[1].offsetY)], [1, 20, 88])
        XCTAssertEqual(windows[2].parent, 2)
        XCTAssertEqual([windows[2].offsetX, windows[2].offsetY], [-30, -500])
        // Popups too deep in popups: no menu goes that far.
        var deep = "windows 5 10\nwindow 1 0 0 10 10 1 0 0 10 10 0 0 0 a b\n"
        for id in 2...10 { deep += "window \(id) \(id * 20) 0 10 10 1 0 0 10 10 \(id - 1) 0 0 a b\n" }
        XCTAssertEqual(read(deep + "end\n", into: &reader), [])
        XCTAssertTrue(reader.isBroken)
    }

    /// A title is the program's: what would mislead on the Mac's screen is
    /// taken out (control characters, text that turns the reading order
    /// around), and bytes that are no text become the mark for that.
    func testATitleIsMadeFitToShow() {
        var reader = GuestWindowReader()
        _ = read("monad-wm 1 1920 1200\n", into: &reader)
        let events = read("windows 1 3\n" +
                          "window 1 0 0 10 10 1 0 0 10 10 0 0 0 a one%0Atwo%09three%00%1B[31m\n" +
                          "window 2 20 0 10 10 1 0 0 10 10 0 0 0 a%7F safe%E2%80%AEexe.txt\n" +
                          "window 3 40 0 10 10 1 0 0 10 10 0 0 0 %2D %FF%FEtitle\n" +
                          "end\n", into: &reader)
        guard case .windows(let windows)? = events.first, windows.count == 3 else { return XCTFail("no list: \(events)") }
        XCTAssertEqual(windows[0].title, "onetwothree[31m")
        XCTAssertEqual(windows[1].title, "safeexe.txt")
        XCTAssertEqual(windows[1].appID, "a")
        XCTAssertEqual(windows[2].title, "\u{FFFD}\u{FFFD}title")
        XCTAssertEqual(windows[2].appID, "-", "a program may call itself that")
    }

    /// What MonadHost says, letter for letter what mwm_ctl.c reads.
    func testTheCommandsAreTheLinesTheWindowManagerReads() {
        XCTAssertEqual(GuestWindowCommand.scale(2).text, "scale 2\n")
        XCTAssertEqual(GuestWindowCommand.pointer(window: 3, x: 2560, y: -128).text, "pointer 3 2560 -128\n")
        XCTAssertEqual(GuestWindowCommand.pointer(window: 0, x: 0, y: 0).text, "pointer 0 0 0\n")
        XCTAssertEqual(GuestWindowCommand.button(code: 272, down: true).text, "button 272 1\n")
        XCTAssertEqual(GuestWindowCommand.button(code: 273, down: false).text, "button 273 0\n")
        XCTAssertEqual(GuestWindowCommand.scroll(dx: 0, dy: -512).text, "scroll 0 -512\n")
        XCTAssertEqual(GuestWindowCommand.focus(window: 4294967295).text, "focus 4294967295\n")
        XCTAssertEqual(GuestWindowCommand.key(code: 30, down: true).text, "key 30 1\n")
        XCTAssertEqual(GuestWindowCommand.modifiers(held: 5, locked: 2).text, "mods 5 2\n")
        XCTAssertEqual(GuestWindowCommand.size(window: 2, width: 800, height: 600).text, "size 2 800 600\n")
        XCTAssertEqual(GuestWindowCommand.close(window: 2).text, "close 2\n")
        XCTAssertEqual(GuestWindowCommand.dismiss(window: 2).text, "dismiss 2\n")
        let keys = [GuestKey(code: 30, caps: true, symbols: [97, 65, 229, 197]), GuestKey(code: 42, caps: false, symbols: [65505])]
        XCTAssertEqual(GuestWindowCommand.keys(keys).text, "keys 2\nk 30 1 97 65 229 197\nk 42 0 65505 0 0 0\n")
        XCTAssertEqual(GuestWindowCommand.keys([]).text, "", "no table is not said at all")
    }
}
