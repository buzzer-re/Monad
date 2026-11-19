//
//  GuestGLProtocol.swift — MonadHost's end of the connection a Linux VM's
//  programs draw through (GuestWM/mwm_gl_wire.h): the VM's window manager
//  hands on what each program's OpenGL library writes, as frames of a
//  stream for each program, and MonadHost's answers go back the same way.
//  Here the frames are told apart; what a stream's bytes mean is the
//  drawing's to read (Monad/GL).
//
//  The guest is on the other end: a frame longer than any, a word about
//  streams that is none, more streams than there may be, end the
//  connection.
//

import Foundation

enum GuestGLEvent: Equatable {
    /// A program connected to draw: its stream.
    case opened(UInt32)
    /// It is gone.
    case closed(UInt32)
    /// Bytes of a stream that is open, as they came.
    case bytes(UInt32, Data)
}

struct GuestGLReader {
    /// mwm_gl_wire.h's MWM_GL_FRAME, MWM_GL_STREAMS, MWM_GL_OPENED and MWM_GL_CLOSED.
    static let maxFrame = 1 << 20
    static let maxStreams = 32
    static let opened: UInt32 = 1
    static let closed: UInt32 = 2

    private(set) var isBroken = false
    private(set) var open: Set<UInt32> = []
    private var head: [UInt8] = []
    private var stream: UInt32 = 0
    private var left = 0
    /// The window manager's own word (stream 0), as far as it came.
    private var word: [UInt8] = []

    /// Feed bytes; returns what became whole with them. Bytes of a stream
    /// are handed on as they come, a frame in as many pieces as it came in.
    mutating func feed(_ data: Data) -> [GuestGLEvent] {
        var events: [GuestGLEvent] = []
        var at = data.startIndex
        while at < data.endIndex, !isBroken {
            if left == 0 {
                let take = min(8 - head.count, data.endIndex - at)
                head.append(contentsOf: data[at..<(at + take)])
                at += take
                guard head.count == 8 else { break }
                stream = Self.word(head, 0)
                let length = Self.word(head, 4)
                head.removeAll(keepingCapacity: true)
                // No frame is longer, and none of the window manager's own is anything but its two words.
                guard length <= Self.maxFrame, stream != 0 || length == 8 else {
                    isBroken = true
                    break
                }
                left = Int(length)
                word.removeAll(keepingCapacity: true)
                continue
            }
            let take = min(left, data.endIndex - at)
            let piece = data[at..<(at + take)]
            at += take
            left -= take
            if stream != 0 {
                if open.contains(stream) { events.append(.bytes(stream, Data(piece))) } // else a stream that was ended here meanwhile
                continue
            }
            word.append(contentsOf: piece)
            guard left == 0 else { continue }
            let kind = Self.word(word, 0), named = Self.word(word, 4)
            if kind == Self.opened, named != 0, !open.contains(named), open.count < Self.maxStreams {
                open.insert(named)
                events.append(.opened(named))
            } else if kind == Self.closed, open.remove(named) != nil {
                events.append(.closed(named))
            } else if kind != Self.closed { // a stream ended here already may still be said closed there
                isBroken = true
            }
        }
        if isBroken {
            head = []
            word = []
            left = 0
        }
        return events
    }

    /// MonadHost ended that stream itself: bytes of it still on their way are no longer handed on.
    mutating func end(_ stream: UInt32) { open.remove(stream) }

    /// What MonadHost writes for a stream: its bytes as frames, none longer than a frame may be.
    static func frames(stream: UInt32, _ bytes: Data) -> Data {
        var out = Data(capacity: bytes.count + 8 * (bytes.count / maxFrame + 1))
        var at = bytes.startIndex
        while at < bytes.endIndex {
            let take = min(maxFrame, bytes.endIndex - at)
            append(stream, to: &out)
            append(UInt32(take), to: &out)
            out.append(bytes[at..<(at + take)])
            at += take
        }
        return out
    }

    /// MonadHost's word that it ended a stream: the window manager hangs up on its program.
    static func ending(_ stream: UInt32) -> Data {
        var out = Data(capacity: 16)
        for value in [0, 8, closed, stream] { append(value, to: &out) }
        return out
    }

    private static func word(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
