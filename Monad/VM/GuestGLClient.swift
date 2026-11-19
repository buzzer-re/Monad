//
//  GuestGLClient.swift — MonadHost's connection for a Linux VM's drawing
//  by the Mac's GPU: the host dialed the port the VM's window manager
//  hands programs' OpenGL commands on through (GuestWM/mwm_gl_wire.h),
//  and this gives each program's stream to something that carries it out
//  (GLStream) and sends its answers back.
//
//  The guest is on the other end. What it says about streams is read as
//  hostile (GuestGLProtocol.swift), and it can send as fast as it likes
//  or stop reading: each stream is carried out on a queue of its own, off
//  the main thread; when more of the streams' bytes wait than may,
//  reading stops until the drawing has caught up; and answers that wait
//  for a guest that does not read are bounded, beyond which the
//  connection ends.
//

import Foundation
import IOSurface

/// What carries out one stream's drawing commands. The tests put a recorder in its place.
protocol GuestGLDrawing: AnyObject {
    /// The stream's bytes as they arrive. False: it said something that cannot be gone on from.
    func feed(_ data: Data) -> Bool
    /// The program is gone.
    func close()
}

final class GuestGLClient: @unchecked Sendable {
    /// Bytes of drawing commands that may wait to be carried out before reading stops.
    static let maxWaiting = 64 << 20
    /// Bytes of answers that may wait for a guest that does not read them.
    static let maxAnswers = 160 << 20

    /// Makes what carries out a new stream; `reply` sends that stream an answer. Called off the main thread.
    typealias Maker = (_ stream: UInt32, _ reply: @escaping (Data) -> Void) -> GuestGLDrawing

    /// The guest hung up, said nonsense or stopped reading. Not called for `stop()`. On the main thread.
    var onDisconnect: (@MainActor () -> Void)?

    private let channel: ByteChannel
    private let make: Maker
    /// Reading, writing and everything below: only ever on this queue.
    private let queue = DispatchQueue(label: "dev.monad.guest-gl", qos: .userInteractive)
    private var source: DispatchSourceRead?
    private var paused = false
    private var ended = false
    private var reader = GuestGLReader()
    private var streams: [UInt32: Stream] = [:]
    private var waiting = 0
    private var answers = Data()
    private var retrying = false

    /// One program's drawing, carried out in order on a queue of its own.
    private final class Stream {
        let drawing: GuestGLDrawing
        let queue: DispatchQueue
        init(_ drawing: GuestGLDrawing, _ id: UInt32) {
            self.drawing = drawing
            queue = DispatchQueue(label: "dev.monad.guest-gl.stream-\(id)", qos: .userInteractive)
        }
    }

    init(channel: ByteChannel, make: @escaping Maker) {
        self.channel = channel
        self.make = make
    }

    func start() {
        queue.async { [self] in
            guard source == nil, !ended else { return }
            let fd = channel.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var on: Int32 = 1 // a guest that hung up is an error from write, not a signal
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in
                guard let self, let base = buffer.baseAddress else { return }
                let n = Darwin.read(fd, base, buffer.count)
                if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
                guard n > 0 else { return self.end(told: true) }
                self.took(self.reader.feed(Data(bytesNoCopy: base, count: n, deallocator: .none)))
                if self.reader.isBroken { self.end(told: true) }
            }
            let channel = self.channel
            src.setCancelHandler {
                channel.close()
                buffer.deallocate()
            }
            source = src
            src.resume()
        }
    }

    /// Ends it: every stream's drawing is let go.
    func stop() {
        queue.async { [self] in end(told: false) }
    }

    private func took(_ events: [GuestGLEvent]) {
        for event in events {
            switch event {
            case .opened(let id):
                let drawing = make(id) { [weak self] answer in
                    self?.queue.async { self?.answer(GuestGLReader.frames(stream: id, answer)) }
                }
                streams[id] = Stream(drawing, id)
            case .closed(let id):
                guard let stream = streams.removeValue(forKey: id) else { continue }
                stream.queue.async { stream.drawing.close() }
            case .bytes(let id, let bytes):
                guard let stream = streams[id] else { continue }
                waiting += bytes.count
                if waiting > Self.maxWaiting, !paused, let source {
                    paused = true
                    source.suspend()
                }
                stream.queue.async { [weak self] in
                    let ok = stream.drawing.feed(bytes)
                    self?.queue.async { self?.carriedOut(bytes.count, of: id, stream, ok: ok) }
                }
            }
        }
    }

    private func carriedOut(_ count: Int, of id: UInt32, _ stream: Stream, ok: Bool) {
        waiting -= count
        if paused, waiting <= Self.maxWaiting / 2, let source {
            paused = false
            source.resume()
        }
        // It said what cannot be gone on from: its drawing is let go, and the window manager hangs up on its program.
        guard !ok, streams[id] === stream else { return }
        streams[id] = nil
        reader.end(id)
        stream.queue.async { stream.drawing.close() }
        answer(GuestGLReader.ending(id))
    }

    private func answer(_ bytes: Data) {
        guard !ended, !bytes.isEmpty else { return }
        answers.append(bytes)
        flush()
        if answers.count > Self.maxAnswers { end(told: true) } // the guest does not read
    }

    private func flush() {
        while !answers.isEmpty, !ended {
            let n = answers.withUnsafeBytes { Darwin.write(channel.fileDescriptor, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break } // full (or gone, which the reading hears of)
            answers.removeFirst(n)
        }
        guard !answers.isEmpty, !ended, !retrying else { return }
        retrying = true
        queue.asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in
            self?.retrying = false
            self?.flush()
        }
    }

    private func end(told: Bool) {
        guard !ended else { return }
        ended = true
        for stream in streams.values { stream.queue.async { stream.drawing.close() } }
        streams = [:]
        answers = Data()
        if let source {
            if paused { source.resume() } // a source that is stopped cannot be cancelled
            paused = false
            source.cancel()
        } else {
            channel.close()
        }
        source = nil
        if told, let onDisconnect { DispatchQueue.main.async { MainActor.assumeIsolated { onDisconnect() } } }
    }
}

/// A picture the Mac's GPU drew for a program, held: for as long as
/// anything keeps this, the memory is marked as in use, and what draws the
/// program's pictures (GLStream) does not draw the next one into it. So
/// what a window shows is never a picture half drawn again.
final class GuestGLPicture: @unchecked Sendable {
    let surface: IOSurface

    init(_ surface: IOSurface) {
        self.surface = surface
        surface.incrementUseCount()
    }

    deinit {
        surface.decrementUseCount()
    }
}

/// The way of a stream's pictures to the main thread, which shows them. A
/// program may draw far more of them than a screen shows (a benchmark
/// draws thousands a second, and nothing of a guest's is to keep the main
/// thread from its work): only the newest picture of each surface waits,
/// and the main thread takes what waits once, when it has time, and no
/// more often than a screen shows pictures (each one handed over is work
/// for the Mac's window server as well).
final class GuestGLPictures: @unchecked Sendable {
    private let lock = NSLock()
    private var newest: [UInt32: GuestGLPicture] = [:]
    private var handing = false
    private var handed: DispatchTime?
    private let every: TimeInterval
    private let show: @MainActor (UInt32, GuestGLPicture) -> Void

    /// `every`: the least time between two hand-overs (a sixtieth of a
    /// second: the rate the VM's window manager gives programs frames at).
    init(every: TimeInterval = 1.0 / 60, show: @escaping @MainActor (_ surface: UInt32, _ picture: GuestGLPicture) -> Void) {
        self.every = every
        self.show = show
    }

    /// A surface's picture is done. From any thread; the picture is held before this returns.
    func drew(_ surface: UInt32, _ picture: IOSurface) {
        let held = GuestGLPicture(picture)
        let due: DispatchTime? = lock.withLock {
            newest[surface] = held
            defer { handing = true }
            return handing ? nil : max(.now(), handed.map { $0 + every } ?? .now())
        }
        guard let due else { return }
        DispatchQueue.main.asyncAfter(deadline: due) { [self] in
            let waiting: [UInt32: GuestGLPicture] = lock.withLock {
                defer { newest = [:] }
                handing = false
                handed = .now()
                return newest
            }
            MainActor.assumeIsolated {
                for (surface, picture) in waiting { show(surface, picture) }
            }
        }
    }
}
