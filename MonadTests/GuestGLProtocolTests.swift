//
//  GuestGLProtocolTests.swift — MonadHost's end of the connection a Linux
//  VM's programs draw through (GuestGLReader): each program's bytes are
//  told apart as its stream's, and what the guest says about streams is
//  read as hostile.
//

import XCTest
@testable import Monad

final class GuestGLProtocolTests: XCTestCase {
    private func words(_ values: [UInt32]) -> Data {
        var data = Data()
        for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    private func frame(_ stream: UInt32, _ text: String) -> Data { words([stream, UInt32(text.utf8.count)]) + Data(text.utf8) }

    /// The frames as `mwm_gl.c` writes them (CTests/test_wm_gl.c has the same).
    func testEachProgramsBytesAreItsStreams() {
        var reader = GuestGLReader()
        var events = reader.feed(words([0, 8, 1, 1]) + words([0, 8, 1, 2]) + frame(2, "second") + frame(1, "first!!"))
        XCTAssertEqual(events, [.opened(1), .opened(2), .bytes(2, Data("second".utf8)), .bytes(1, Data("first!!".utf8))])
        // A frame in pieces: its bytes are handed on as they come, in order.
        events = []
        for byte in frame(1, "abc") + words([0, 8, 2, 1]) + frame(1, "late") + frame(2, "") + frame(2, "on") { events += reader.feed(Data([byte])) }
        XCTAssertEqual(events, [.bytes(1, Data("a".utf8)), .bytes(1, Data("b".utf8)), .bytes(1, Data("c".utf8)), .closed(1),
                                .bytes(2, Data("o".utf8)), .bytes(2, Data("n".utf8))], "nothing of a stream that is gone")
        XCTAssertEqual(reader.open, [2])
        XCTAssertFalse(reader.isBroken)
        // MonadHost ended a stream itself: what is still on its way is dropped, and its closing is no nonsense.
        reader.end(2)
        XCTAssertEqual(reader.feed(frame(2, "more") + words([0, 8, 2, 2]) + words([0, 8, 1, 3])), [.opened(3)])
        XCTAssertFalse(reader.isBroken)
    }

    /// What MonadHost writes: a stream's bytes as frames no longer than a
    /// frame may be, and its word that it ended a stream.
    func testAnswersGoAsFramesOfTheirStream() {
        XCTAssertEqual(GuestGLReader.frames(stream: 7, Data("reply".utf8)), words([7, 5]) + Data("reply".utf8))
        XCTAssertEqual(GuestGLReader.frames(stream: 7, Data()), Data())
        let large = Data((0..<(GuestGLReader.maxFrame + 10)).map { UInt8(truncatingIfNeeded: $0) })
        let framed = GuestGLReader.frames(stream: 3, large)
        XCTAssertEqual(framed.count, large.count + 16)
        XCTAssertEqual(framed.prefix(8), words([3, UInt32(GuestGLReader.maxFrame)]))
        XCTAssertEqual(framed.suffix(18), words([3, 10]) + large.suffix(10))
        XCTAssertEqual(GuestGLReader.ending(4), words([0, 8, 2, 4]))
    }

    /// Whatever is no frame, or no word about streams, ends the connection.
    func testWhatDoesNotFitBreaksTheConnection() {
        let hostile: [(Data, String)] = [
            (words([1, UInt32(GuestGLReader.maxFrame) + 1]), "a frame longer than any"),
            (words([0, 4, 1]), "a word about streams cut short"),
            (words([0, 12, 1, 1, 1]), "one too long"),
            (words([0, 8, 1, 0]), "stream 0 opened"),
            (words([0, 8, 9, 1]), "no such word"),
            (words([0, 8, 1, 1]) + words([0, 8, 1, 1]), "a stream opened twice"),
            ((1...33).reduce(Data()) { $0 + words([0, 8, 1, UInt32($1)]) }, "more streams than there may be"),
        ]
        for (bytes, what) in hostile {
            var reader = GuestGLReader()
            _ = reader.feed(bytes)
            XCTAssertTrue(reader.isBroken, what)
            XCTAssertEqual(reader.feed(words([0, 8, 1, 5])), [], "\(what): nothing more is read")
        }
        // Bytes for a stream that never opened are no nonsense (it may have ended here): they go nowhere.
        var reader = GuestGLReader()
        XCTAssertEqual(reader.feed(frame(9, "x") + words([0, 8, 2, 9])), [])
        XCTAssertFalse(reader.isBroken)
        // Anything at all: it ends, and never hands on more than it was fed.
        var seed: UInt64 = 0x4d4f4e4144
        for _ in 0..<2000 {
            var soup = Data()
            var fuzz = GuestGLReader()
            for _ in 0..<Int.random(in: 1...40, using: &seed) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let kind = (seed >> 33) % 4
                if kind == 0 { soup += words([0, 8, UInt32((seed >> 40) % 3), UInt32((seed >> 44) % 6)]) }
                else if kind == 1 { soup += frame(UInt32((seed >> 40) % 6), String(repeating: "z", count: Int((seed >> 44) % 9))) }
                else { soup.append(UInt8(truncatingIfNeeded: seed >> 50)) }
            }
            let handed = fuzz.feed(soup).reduce(0) { sum, event in
                if case .bytes(_, let bytes) = event { return sum + bytes.count }
                return sum
            }
            XCTAssertLessThanOrEqual(handed, soup.count)
            XCTAssertLessThanOrEqual(fuzz.open.count, GuestGLReader.maxStreams)
        }
    }
}

extension UInt64: @retroactive RandomNumberGenerator {
    public mutating func next() -> UInt64 {
        self = self &* 6364136223846793005 &+ 1442695040888963407
        return self
    }
}
