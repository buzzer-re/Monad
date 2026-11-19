//
//  GuestGLClientTests.swift — MonadHost's connection for a Linux VM's
//  drawing by the Mac's GPU (GuestGLClient), with the test as the VM's
//  window manager on the other end of a socketpair: each program's bytes
//  reach what carries its stream out, in order; answers go back as frames
//  of that stream; a stream that says nonsense is ended alone; and a
//  guest that hangs up lets everything go.
//

import IOSurface
import XCTest
@testable import Monad

/// Stands where the drawing is: keeps what it was fed.
private final class StreamRecorder: GuestGLDrawing, @unchecked Sendable {
    private let lock = NSLock()
    private var _fed = Data()
    private var _closed = 0
    let reply: (Data) -> Void
    /// Bytes that make `feed` say the stream cannot be gone on from.
    var poison: Data?

    init(reply: @escaping (Data) -> Void) { self.reply = reply }

    var fed: Data { lock.withLock { _fed } }
    var closed: Int { lock.withLock { _closed } }

    func feed(_ data: Data) -> Bool {
        lock.withLock { _fed.append(data) }
        if data.starts(with: Data("ask".utf8)) { reply(Data("answer to ".utf8) + data) }
        return poison.map { data.range(of: $0) == nil } ?? true
    }

    func close() { lock.withLock { _closed += 1 } }
}

@MainActor
final class GuestGLClientTests: XCTestCase {
    private func words(_ values: [UInt32]) -> Data {
        var data = Data()
        for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    private func frame(_ stream: UInt32, _ text: String) -> Data { words([stream, UInt32(text.utf8.count)]) + Data(text.utf8) }

    private func says(_ channel: SocketPairChannel, _ data: Data) {
        data.withUnsafeBytes { XCTAssertEqual(Darwin.write(channel.peer, $0.baseAddress, $0.count), $0.count) }
    }

    /// What MonadHost sent the window manager so far.
    private func sent(_ channel: SocketPairChannel) -> Data {
        var all = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        let flags = fcntl(channel.peer, F_GETFL)
        _ = fcntl(channel.peer, F_SETFL, flags | O_NONBLOCK)
        while case let n = read(channel.peer, &buf, buf.count), n > 0 { all.append(contentsOf: buf[0..<n]) }
        _ = fcntl(channel.peer, F_SETFL, flags)
        return all
    }

    func testEachStreamIsCarriedOutInOrderAndAnswered() async {
        let channel = SocketPairChannel()
        let made = NSLock()
        var drawings: [UInt32: StreamRecorder] = [:]
        let client = GuestGLClient(channel: channel) { stream, reply in
            let drawing = StreamRecorder(reply: reply)
            made.withLock { drawings[stream] = drawing }
            return drawing
        }
        client.start()
        says(channel, words([0, 8, 1, 1]) + words([0, 8, 1, 2]) + frame(1, "one, ") + frame(2, "two") + frame(1, "more"))
        await assertEventually { made.withLock { drawings[1]?.fed == Data("one, more".utf8) && drawings[2]?.fed == Data("two".utf8) } }
        // An answer goes back as a frame of the stream that asked.
        says(channel, frame(2, "ask 2"))
        var got = Data()
        await assertEventually {
            got += self.sent(channel)
            return got == self.frame(2, "answer to ask 2")
        }
        // A program ends: its drawing is let go; the other goes on.
        says(channel, words([0, 8, 2, 1]) + frame(2, "!"))
        await assertEventually { made.withLock { drawings[1]?.closed == 1 && drawings[2]?.fed.last == UInt8(ascii: "!") } }
        XCTAssertEqual(made.withLock { drawings[2]?.closed }, 0)
        client.stop()
        await assertEventually { channel.closed && made.withLock { drawings[2]?.closed == 1 } }
    }

    /// A stream whose bytes cannot be gone on from is ended alone: the
    /// window manager is told to hang up on its program, and nothing more
    /// of it is carried out.
    func testAStreamThatSaysNonsenseIsEndedAlone() async {
        let channel = SocketPairChannel()
        let made = NSLock()
        var drawings: [UInt32: StreamRecorder] = [:]
        let client = GuestGLClient(channel: channel) { stream, reply in
            let drawing = StreamRecorder(reply: reply)
            drawing.poison = Data("nonsense".utf8)
            made.withLock { drawings[stream] = drawing }
            return drawing
        }
        var disconnects = 0
        client.onDisconnect = { disconnects += 1 }
        client.start()
        says(channel, words([0, 8, 1, 1]) + words([0, 8, 1, 2]) + frame(1, "nonsense"))
        var got = Data()
        await assertEventually {
            got += self.sent(channel)
            return got == self.words([0, 8, 2, 1])
        }
        XCTAssertEqual(made.withLock { drawings[1]?.closed }, 1)
        says(channel, frame(1, "after") + frame(2, "fine") + words([0, 8, 2, 1]))
        await assertEventually { made.withLock { drawings[2]?.fed == Data("fine".utf8) } }
        XCTAssertEqual(made.withLock { drawings[1]?.fed }, Data("nonsense".utf8), "nothing after what ended it")
        XCTAssertEqual(disconnects, 0, "the connection is as it was")
        client.stop()
        await assertEventually { channel.closed }
        XCTAssertEqual(disconnects, 0, "stopping is not the guest's doing")
    }

    /// The guest hangs up, or says what is no frame: everything is let go, and that is told.
    func testAGuestThatHangsUpOrSaysNonsenseLetsEverythingGo() async {
        for nonsense in [nil, words([1, 0x7fff_ffff])] {
            let channel = SocketPairChannel()
            let made = NSLock()
            var drawings: [UInt32: StreamRecorder] = [:]
            let client = GuestGLClient(channel: channel) { stream, reply in
                let drawing = StreamRecorder(reply: reply)
                made.withLock { drawings[stream] = drawing }
                return drawing
            }
            var disconnects = 0
            client.onDisconnect = { disconnects += 1 }
            client.start()
            says(channel, words([0, 8, 1, 1]) + frame(1, "x"))
            await assertEventually { made.withLock { drawings[1]?.fed.count == 1 } }
            if let nonsense { says(channel, nonsense) } else { channel.hangUp() }
            await assertEventually { disconnects == 1 && channel.closed && made.withLock { drawings[1]?.closed == 1 } }
        }
    }

    /// A program may draw thousands of pictures a second (a benchmark does):
    /// the main thread is handed only the newest of each surface, once it
    /// has time, however many were drawn meanwhile. A picture that waits or
    /// is shown is marked as in use, so that it is not drawn into again; one
    /// that a newer took the place of is free.
    func testOnlyTheNewestPictureOfASurfaceReachesTheMainThreadAndIsHeld() throws {
        func memory() throws -> IOSurface {
            try XCTUnwrap(IOSurface(properties: [.width: 2, .height: 2, .bytesPerElement: 4, .pixelFormat: UInt32(0x4247_5241)]))
        }
        var shown: [(surface: UInt32, picture: GuestGLPicture)] = []
        let pictures = GuestGLPictures(every: 0) { shown.append(($0, $1)) }
        let old = try (0..<500).map { _ in try memory() }, newest = try memory(), other = try memory()
        // The main thread is busy here (it does not turn to its queue) while a stream draws.
        let drawn = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for picture in old { pictures.drew(1, picture) }
            pictures.drew(2, other)
            pictures.drew(1, newest)
            drawn.signal()
        }
        XCTAssertEqual(drawn.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(shown.isEmpty)
        XCTAssertTrue(newest.isInUse)
        XCTAssertTrue(other.isInUse)
        XCTAssertFalse(old.contains { $0.isInUse })
        let handed = expectation(description: "handed over")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { handed.fulfill() }
        wait(for: [handed], timeout: 5)
        XCTAssertEqual(shown.map(\.surface).sorted(), [1, 2])
        XCTAssertTrue(shown.first { $0.surface == 1 }?.picture.surface === newest)
        XCTAssertTrue(newest.isInUse) // whoever was handed it holds it
        shown = []
        XCTAssertFalse(newest.isInUse)
        XCTAssertFalse(other.isInUse)
        // The next one after that is handed over again.
        pictures.drew(1, other)
        let again = expectation(description: "handed over again")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { again.fulfill() }
        wait(for: [again], timeout: 5)
        XCTAssertTrue(shown.count == 1 && shown[0].picture.surface === other)
    }

    /// A screen shows sixty pictures a second or so: the main thread is
    /// handed pictures no more often than that, whatever a program draws
    /// (each hand-over is work for the Mac's window server too).
    func testPicturesAreHandedOverNoFasterThanAScreenShowsThem() throws {
        var shown: [GuestGLPicture] = []
        let pictures = GuestGLPictures(every: 0.5) { shown.append($1) }
        let first = try XCTUnwrap(IOSurface(properties: [.width: 2, .height: 2, .bytesPerElement: 4, .pixelFormat: UInt32(0x4247_5241)]))
        let second = try XCTUnwrap(IOSurface(properties: [.width: 2, .height: 2, .bytesPerElement: 4, .pixelFormat: UInt32(0x4247_5241)]))
        pictures.drew(1, first)
        let handed = expectation(description: "the first at once")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { handed.fulfill() }
        wait(for: [handed], timeout: 5)
        XCTAssertTrue(shown.count == 1 && shown[0].surface === first)
        pictures.drew(1, second)
        let soon = expectation(description: "a moment later")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { soon.fulfill() }
        wait(for: [soon], timeout: 5)
        XCTAssertEqual(shown.count, 1) // held back
        XCTAssertTrue(second.isInUse)
        let later = expectation(description: "the second in its time")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { later.fulfill() }
        wait(for: [later], timeout: 5)
        XCTAssertTrue(shown.count == 2 && shown[1].surface === second)
    }
}
