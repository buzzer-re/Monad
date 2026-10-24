//
//  TerminalModelTests.swift — the Swift wrapper around mnd_vt, end to end
//  through the real C emulator (the pure-C behaviour is covered in CTests).
//

import XCTest
@testable import Monad

final class TerminalModelTests: XCTestCase {
    private func makeModel(cols: Int = 20, rows: Int = 5, scrollback: Int = 100) throws -> TerminalModel {
        try XCTUnwrap(TerminalModel(cols: cols, rows: rows, scrollback: scrollback))
    }

    /// Text of a viewport row with trailing blanks trimmed.
    private func row(_ m: TerminalModel, _ y: Int) -> String {
        m.withLock {
            var len: Int32 = 0
            guard let cells = mnd_vt_view_row(m.vt, Int32(y), &len) else { return "" }
            var s = ""
            for x in 0..<Int(len) {
                let c = cells[x]
                if (c.attrs & VTAttr.widthMask) >> VTAttr.widthShift == VTAttr.widthSpacer { continue }
                s.unicodeScalars.append(c.cp == 0 ? " " : Unicode.Scalar(c.cp) ?? "?")
            }
            while s.hasSuffix(" ") { s.removeLast() }
            return s
        }
    }

    func testCreationRejectsInvalidSizes() {
        XCTAssertNil(TerminalModel(cols: 0, rows: 5, scrollback: 0))
        XCTAssertNil(TerminalModel(cols: 5, rows: 0, scrollback: 0))
        XCTAssertNotNil(TerminalModel(cols: 1, rows: 1, scrollback: 0))
    }

    func testFeedAndReadBack() throws {
        let m = try makeModel()
        m.feed("hello\r\nworld")
        XCTAssertEqual(row(m, 0), "hello")
        XCTAssertEqual(row(m, 1), "world")
        let cursor = m.withLock { mnd_vt_cursor(m.vt) }
        XCTAssertEqual(cursor.x, 5)
        XCTAssertEqual(cursor.y, 1)
    }

    func testUTF8SplitAcrossFeeds() throws {
        let m = try makeModel()
        let bytes = Array("é中".utf8)
        for b in bytes { [b].withUnsafeBytes { m.feed($0) } }
        XCTAssertEqual(row(m, 0), "é中")
    }

    func testResizeReportsNewSizeAndReflows() throws {
        let m = try makeModel(cols: 10, rows: 3)
        m.feed("abcdefghijklmno")
        XCTAssertEqual(row(m, 0), "abcdefghij")
        XCTAssertTrue(m.resize(cols: 20, rows: 3))
        XCTAssertEqual(m.size.cols, 20)
        XCTAssertEqual(row(m, 0), "abcdefghijklmno")
    }

    func testRepliesGoToReplyHandler() throws {
        let m = try makeModel()
        var reply = Data()
        m.replyHandler = { reply.append($0) }
        m.feed("\u{1B}[c")
        XCTAssertEqual(String(decoding: reply, as: UTF8.self), "\u{1B}[?62;22c")
    }

    func testTitleCallbackArrivesOnMainQueue() throws {
        let m = try makeModel()
        let exp = expectation(description: "title")
        m.onTitle = { title in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(title, "build: ok")
            exp.fulfill()
        }
        m.feed("\u{1B}]2;build: ok\u{07}")
        wait(for: [exp], timeout: 2)
    }

    func testClipboardCallbackDecodesOSC52() throws {
        let m = try makeModel()
        let exp = expectation(description: "clipboard")
        m.onClipboard = { text in
            XCTAssertEqual(text, "yanked text")
            exp.fulfill()
        }
        m.feed("\u{1B}]52;c;\(Data("yanked text".utf8).base64EncodedString())\u{07}")
        wait(for: [exp], timeout: 2)
    }

    /// The boot console is fed to the same emulator before any shell exists:
    /// it never sets the clipboard, not even with a sequence it leaves open
    /// for Monad's own escapes to finish (F-07).
    func testTheBootConsoleNeverSetsTheClipboard() throws {
        let m = try makeModel()
        var got: [String] = []
        m.onClipboard = { got.append($0) }
        m.feedConsole(Data("\u{1B}]52;c;\(Data("from boot".utf8).base64EncodedString())\u{07}".utf8))
        m.feedConsole(Data("\u{1B}]52;c;\(Data("left open".utf8).base64EncodedString())".utf8))
        m.endConsole()
        m.feed("\u{1B}[0m\u{1B}[H\u{1B}[2J")
        m.feed("\u{1B}]52;c;\(Data("from the shell".utf8).base64EncodedString())\u{07}")
        let exp = expectation(description: "main queue")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(got, ["from the shell"])
    }

    /// Images a guest sends (OSC 1337) are only parsed when its VM allows
    /// them, never from the boot console; they are decoded off the main
    /// thread and kept for drawing.
    func testImagesNeedTheVMsSettingAndNeverComeFromTheBootConsole() throws {
        let m = try makeModel()
        m.setCellPixels(width: 10, height: 20)
        let file = TerminalImagesTests.file(width: 40, height: 40)
        let seq = "\u{1B}]1337;File=inline=1:\(file.base64EncodedString())\u{07}"
        func imageCells() -> Int {
            m.withLock {
                var n = 0
                for y in 0..<5 {
                    var len: Int32 = 0
                    guard let cells = mnd_vt_view_row(m.vt, Int32(y), &len) else { continue }
                    for x in 0..<Int(len) where mnd_cp_is_image(cells[x].cp) { n += 1 }
                }
                return n
            }
        }
        m.feed(seq)
        XCTAssertEqual(imageCells(), 0, "off unless the VM allows them")
        m.imagesAllowed = true
        m.feedConsole(Data(seq.utf8))
        XCTAssertEqual(imageCells(), 0, "never from the boot console")
        m.endConsole()
        let decoded = expectation(description: "decoded")
        m.onImagesChanged = { decoded.fulfill() }
        m.feed(seq)
        XCTAssertEqual(imageCells(), 8, "4 x 2 cells of 10 x 20 pixels")
        wait(for: [decoded], timeout: 5)
        let image = try XCTUnwrap(m.images.image(1))
        XCTAssertEqual([image.cols, image.rows], [4, 2])
        XCTAssertEqual(image.cgImage.width, 40)
        m.imagesAllowed = false
        m.feed(seq)
        XCTAssertEqual(imageCells(), 8, "turned off: no new image")
    }

    func testKeyEncodingFollowsCursorKeyMode() throws {
        let m = try makeModel()
        XCTAssertEqual(m.encodeKey(MND_KEY_UP, mods: 0), Data("\u{1B}[A".utf8))
        m.feed("\u{1B}[?1h")
        XCTAssertEqual(m.encodeKey(MND_KEY_UP, mods: 0), Data("\u{1B}OA".utf8))
        XCTAssertEqual(m.encodeKey(MND_KEY_LEFT, mods: 4), Data("\u{1B}[1;5D".utf8))
        XCTAssertEqual(m.encodeChar("c", mods: 4), Data([0x03]))
        XCTAssertEqual(m.encodeChar("b", mods: 2), Data("\u{1B}b".utf8))
    }

    func testPasteIsSanitizedAndBracketed() throws {
        let m = try makeModel()
        XCTAssertEqual(m.encodePaste("a\nb\u{1B}[201~c"), Data("a\rb[201~c".utf8))
        m.feed("\u{1B}[?2004h")
        XCTAssertEqual(m.encodePaste("x"), Data("\u{1B}[200~x\u{1B}[201~".utf8))
    }

    func testMouseEncodingOnlyWhenTrackingEnabled() throws {
        let m = try makeModel()
        XCTAssertNil(m.encodeMouse(button: 0, action: MND_MOUSE_PRESS, mods: 0, col: 1, row: 1))
        m.feed("\u{1B}[?1000h\u{1B}[?1006h")
        XCTAssertEqual(m.mouseTracking, MND_MOUSE_NORMAL)
        XCTAssertEqual(m.encodeMouse(button: 0, action: MND_MOUSE_PRESS, mods: 0, col: 1, row: 1),
                       Data("\u{1B}[<0;2;2M".utf8))
    }

    func testFocusEventsOnlyWhenRequested() throws {
        let m = try makeModel()
        XCTAssertNil(m.encodeFocus(true))
        m.feed("\u{1B}[?1004h")
        XCTAssertEqual(m.encodeFocus(true), Data("\u{1B}[I".utf8))
        XCTAssertEqual(m.encodeFocus(false), Data("\u{1B}[O".utf8))
    }

    func testCopyTextJoinsSoftWrappedLines() throws {
        let m = try makeModel(cols: 5, rows: 3)
        m.feed("abcdefgh\r\nxy")
        let top = mnd_vt_view_to_abs(m.vt, 0)
        let text = m.copyText(from: mnd_pos(col: 0, line: top), to: mnd_pos(col: 4, line: top + 2), block: false)
        XCTAssertEqual(text, "abcdefgh\nxy")
    }

    func testScrollbackViewport() throws {
        let m = try makeModel(cols: 10, rows: 2, scrollback: 10)
        m.feed("1\r\n2\r\n3\r\n4")
        XCTAssertEqual(mnd_vt_scrollback_lines(m.vt), 2)
        XCTAssertEqual(mnd_vt_scroll(m.vt, 5), 2) // clamped
        XCTAssertEqual(row(m, 0), "1")
        mnd_vt_scroll_to_bottom(m.vt)
        XCTAssertEqual(row(m, 0), "3")
    }
}
