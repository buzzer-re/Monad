//
//  GuestWindowsClientTests.swift — MonadHost's connection to a Linux VM's
//  window manager (GuestWindowsClient), with the test as the window
//  manager on the other end of a socketpair: what it says of its windows
//  arrives, what the Mac's pointer and keys do is sent, and a guest that
//  says nonsense or stops reading neither holds MonadHost up nor grows it.
//

import XCTest
@testable import Monad

@MainActor
final class GuestWindowsClientTests: XCTestCase {
    private func window(_ id: UInt32, x: Int) -> GuestWindow {
        GuestWindow(id: id, x: x, y: 0, width: 100, height: 50, scale: 1, innerX: 0, innerY: 0, innerWidth: 100, innerHeight: 50,
                    appID: "app", title: "Window \(id)")
    }

    func testTheWindowsArrive() async {
        let channel = SocketPairChannel()
        let client = GuestWindowsClient(channel: channel)
        var displays: [GuestDisplaySize] = [], lists: [[GuestWindow]] = []
        client.onDisplay = { displays.append($0) }
        client.onWindows = { lists.append($0) }
        client.start()
        channel.agentSays("monad-wm 1 1920 1200\nwindows 1 1\nwindow 1 0 0 100 50 1 0 0 100 50 0 0 0 app Window%201\nend\n")
        await assertEventually { lists.count == 1 }
        XCTAssertEqual(displays, [GuestDisplaySize(width: 1920, height: 1200)])
        XCTAssertEqual(lists.last, [window(1, x: 0)])
        channel.agentSays("windows 2 2\nwindow 1 0 0 100 50 1 0 0 100 50 0 0 0 app Window%201\nwindow 2 116 0 100 50 1 0 0 100 50 0 0 0 app Window%202\nend\n")
        await assertEventually { lists.count == 2 }
        XCTAssertEqual(lists.last, [window(1, x: 0), window(2, x: 116)])
        client.stop()
        await assertEventually { channel.closed }
    }

    func testWhatTheMacDoesIsSentInOrder() async {
        let channel = SocketPairChannel()
        let client = GuestWindowsClient(channel: channel)
        client.start()
        client.send(.scale(2))
        client.send(.focus(window: 1))
        client.send(.pointer(window: 1, x: 256, y: 512))
        client.send(.button(code: 272, down: true))
        client.send(.button(code: 272, down: false))
        client.send(.key(code: 30, down: true))
        var sent = ""
        await assertEventually {
            sent += channel.hostSent()
            return sent.hasSuffix("key 30 1\n")
        }
        XCTAssertEqual(sent, "scale 2\nfocus 1\npointer 1 256 512\nbutton 272 1\nbutton 272 0\nkey 30 1\n")
        client.stop()
    }

    /// Nonsense from the guest ends the connection: nothing of it is shown,
    /// and whoever holds the client is told, once.
    func testNonsenseEndsTheConnection() async {
        let channel = SocketPairChannel()
        let client = GuestWindowsClient(channel: channel)
        var lists = 0, ended = 0
        client.onWindows = { _ in lists += 1 }
        client.onDisconnect = { ended += 1 }
        client.start()
        channel.agentSays("monad-wm 1 1920 1200\nwindows 1 1\nwindow 1 5000 0 100 50 1 0 0 100 50 0 0 0 app off-the-display\nend\nwindows 2 0\nend\n")
        await assertEventually { ended == 1 }
        XCTAssertEqual(lists, 0)
        await assertEventually { channel.closed }
        client.send(.focus(window: 1)) // said to nobody, and nothing breaks
        client.stop()
        XCTAssertEqual(ended, 1)
    }

    func testTheGuestHangingUpIsTold() async {
        let channel = SocketPairChannel()
        let client = GuestWindowsClient(channel: channel)
        var ended = 0
        client.onDisconnect = { ended += 1 }
        client.start()
        channel.hangUp()
        await assertEventually { ended == 1 }
        await assertEventually { channel.closed }
    }

    /// A window manager that stops reading: MonadHost's main thread never
    /// waits for it, pointer moves it has not taken are replaced by the
    /// newest, and what waits for it is bounded (beyond, the connection ends).
    func testAGuestThatDoesNotReadHoldsNothingUp() async {
        let channel = SocketPairChannel()
        let client = GuestWindowsClient(channel: channel)
        var ended = 0
        client.onDisconnect = { ended += 1 }
        client.start()
        let started = Date()
        for i in 0..<200_000 { client.send(.pointer(window: 1, x: Int32(i), y: 0)) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "sending never waits for the guest")
        client.send(.key(code: 30, down: true))
        // The guest reads again: it gets far fewer moves than were made, the newest one last, then the key.
        var sent = ""
        await assertEventually(timeout: 10) {
            sent += channel.hostSent()
            return sent.hasSuffix("key 30 1\n")
        }
        let lines = sent.split(separator: "\n")
        XCTAssertLessThan(lines.count, 100_000)
        XCTAssertEqual(lines.suffix(2), ["pointer 1 199999 0", "key 30 1"])
        XCTAssertEqual(ended, 0)

        // Keys are never dropped: with nobody reading, they add up to the bound, and the connection ends.
        for _ in 0..<200_000 where ended == 0 {
            client.send(.key(code: 30, down: true))
            client.send(.key(code: 30, down: false))
            if ended == 0 { await Task.yield() }
        }
        await assertEventually { ended == 1 }
        await assertEventually { channel.closed }
    }

    /// What the user copied in the VM arrives as text.
    func testACopyArrives() async {
        let channel = SocketPairChannel()
        let client = GuestWindowsClient(channel: channel)
        var copies: [String] = []
        client.onCopied = { copies.append($0) }
        client.start()
        channel.agentSays("monad-wm 1 1920 1200\ncopied 11\nfor\nthe Mac")
        await assertEventually { copies == ["for\nthe Mac"] }
        client.stop()
    }

    /// The Mac's text for a paste may be more than otherwise waits for a
    /// guest: it waits whole, with what was said before and after it in
    /// order. One paste at a time: with a guest that does not read, a
    /// second is left out rather than added to what MonadHost holds.
    func testAPasteWaitsWholeForAGuestThatIsSlow() async {
        let channel = SocketPairChannel()
        let client = GuestWindowsClient(channel: channel)
        var ended = 0
        client.onDisconnect = { ended += 1 }
        client.start()
        let first = String(repeating: "a", count: GuestClipboard.maxPaste), second = String(repeating: "b", count: GuestClipboard.maxPaste)
        client.send(.focus(window: 1))
        client.send(.paste(first))
        client.send(.key(code: 47, down: true))
        client.send(.paste(second))
        client.send(.key(code: 47, down: false))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(ended, 0, "the user's paste is no guest that stopped reading")
        var sent = ""
        await assertEventually(timeout: 10) {
            sent += channel.hostSent()
            return sent.hasSuffix("key 47 0\n")
        }
        XCTAssertEqual(sent.count, "focus 1\npaste \(first.utf8.count)\n".count + first.count + "key 47 1\nkey 47 0\n".count)
        XCTAssertTrue(sent.hasPrefix("focus 1\npaste \(first.utf8.count)\naaaa"))
        XCTAssertTrue(sent.hasSuffix("aaaakey 47 1\nkey 47 0\n"))
        XCTAssertFalse(sent.contains("b"))
        XCTAssertEqual(ended, 0)

        // Lines still add up to the bound behind a paste nobody reads, and the connection ends.
        client.send(.paste(first))
        for _ in 0..<200_000 where ended == 0 {
            client.send(.key(code: 30, down: true))
            client.send(.key(code: 30, down: false))
            if ended == 0 { await Task.yield() }
        }
        await assertEventually { ended == 1 }
    }
}
