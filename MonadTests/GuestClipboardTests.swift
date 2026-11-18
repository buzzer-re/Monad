//
//  GuestClipboardTests.swift — when the Mac's clipboard and a Linux VM's
//  meet (GuestClipboard): only on the user's ⌘V and ⌘C in one of the VM's
//  windows, never because the VM says so.
//

import XCTest
@testable import Monad

final class GuestClipboardTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    func testWhichKeysAreTheClipboards() {
        XCTAssertEqual(GuestClipboard.shortcut(typed: "v"), .paste)
        XCTAssertEqual(GuestClipboard.shortcut(typed: "V"), .paste, "with Shift too, as terminals have it")
        XCTAssertEqual(GuestClipboard.shortcut(typed: "c"), .copy)
        XCTAssertEqual(GuestClipboard.shortcut(typed: "x"), .copy, "what is cut is copied")
        XCTAssertNil(GuestClipboard.shortcut(typed: "a"))
        XCTAssertNil(GuestClipboard.shortcut(typed: ""))
        XCTAssertNil(GuestClipboard.shortcut(typed: nil))
        XCTAssertNil(GuestClipboard.shortcut(typed: "vc"))
    }

    /// ⌘V gives the VM the Mac's text when the Mac's clipboard is the newer
    /// of the two: once for each thing copied on the Mac.
    func testTheMacsTextIsSentWhenItIsNew() {
        var clipboard = GuestClipboard()
        XCTAssertEqual(clipboard.paste(changeCount: 7, text: "from the Mac"), .send("from the Mac"))
        XCTAssertEqual(clipboard.paste(changeCount: 7, text: "from the Mac"), .keep, "the VM has it already")
        XCTAssertEqual(clipboard.paste(changeCount: 8, text: "newer"), .send("newer"))
        // Nothing on the Mac that is text (a picture, say): the VM pastes what it has.
        XCTAssertEqual(clipboard.paste(changeCount: 9, text: nil), .keep)
        XCTAssertEqual(clipboard.paste(changeCount: 9, text: ""), .keep)
        XCTAssertEqual(clipboard.paste(changeCount: 10, text: "after the picture"), .send("after the picture"))
    }

    func testAPasteIsBounded() {
        var clipboard = GuestClipboard()
        let most = String(repeating: "é", count: GuestClipboard.maxPaste / 2)
        XCTAssertEqual(clipboard.paste(changeCount: 1, text: most), .send(most))
        XCTAssertEqual(clipboard.paste(changeCount: 2, text: most + "x"), .refuse, "counted in bytes")
        XCTAssertEqual(clipboard.paste(changeCount: 2, text: most + "x"), .refuse, "and refused again, not taken as known")
        // A NUL is no text for the window manager: taken out rather than the paste lost.
        XCTAssertEqual(clipboard.paste(changeCount: 3, text: "a\0b"), .send("ab"))
        XCTAssertEqual(clipboard.paste(changeCount: 4, text: "\0"), .keep)
    }

    /// What the VM says it copied is the Mac's only as the answer to the
    /// user's ⌘C: soon after it, once, and with the user still there.
    func testACopyIsTakenOnlyAsTheAnswerToTheUsersKey() {
        var clipboard = GuestClipboard()
        XCTAssertFalse(clipboard.copied("unasked", at: t0, inFront: true, changeCount: 1), "the VM says so by itself")

        clipboard.copyPressed(at: t0)
        XCTAssertTrue(clipboard.copied("asked for", at: t0.addingTimeInterval(0.2), inFront: true, changeCount: 1))
        XCTAssertFalse(clipboard.copied("a second answer", at: t0.addingTimeInterval(0.3), inFront: true, changeCount: 1))

        clipboard.copyPressed(at: t0)
        XCTAssertFalse(clipboard.copied("late", at: t0.addingTimeInterval(GuestClipboard.answerTime + 0.1), inFront: true, changeCount: 1))
        XCTAssertFalse(clipboard.copied("after the late one", at: t0.addingTimeInterval(GuestClipboard.answerTime + 0.2), inFront: true,
                                        changeCount: 1))

        clipboard.copyPressed(at: t0)
        XCTAssertFalse(clipboard.copied("the user left", at: t0.addingTimeInterval(0.1), inFront: false, changeCount: 1),
                       "the user is in another app by now: its clipboard is not the VM's to set")
        XCTAssertFalse(clipboard.copied("again", at: t0.addingTimeInterval(0.2), inFront: true, changeCount: 1))

        clipboard.copyPressed(at: t0)
        XCTAssertFalse(clipboard.copied("from before the key", at: t0.addingTimeInterval(-1), inFront: true, changeCount: 1),
                       "a clock that went back gives the VM no answer")
    }

    /// After a copy in the VM, the VM's clipboard is the newer one: ⌘V
    /// pastes it (a picture as a picture), not the Mac's text over it.
    func testAfterACopyInTheVMTheMacsOlderTextIsNotSentOverIt() {
        var clipboard = GuestClipboard()
        // Text: it was written to the Mac's clipboard, which is the same text now.
        clipboard.copyPressed(at: t0)
        XCTAssertTrue(clipboard.copied("text", at: t0, inFront: true, changeCount: 5))
        clipboard.wrote(changeCount: 6)
        XCTAssertEqual(clipboard.paste(changeCount: 6, text: "text"), .keep)
        // A picture: the Mac got nothing, and still holds what it held.
        clipboard.copyPressed(at: t0)
        XCTAssertFalse(clipboard.copied("", at: t0, inFront: true, changeCount: 20))
        XCTAssertEqual(clipboard.paste(changeCount: 20, text: "what the Mac held before"), .keep)
        // Until the user copies something on the Mac again.
        XCTAssertEqual(clipboard.paste(changeCount: 21, text: "copied on the Mac since"), .send("copied on the Mac since"))
        // A VM that only says it copied (nobody pressed ⌘C) changes nothing.
        XCTAssertFalse(clipboard.copied("", at: t0, inFront: true, changeCount: 30))
        XCTAssertEqual(clipboard.paste(changeCount: 30, text: "the Mac's"), .send("the Mac's"))
    }
}
