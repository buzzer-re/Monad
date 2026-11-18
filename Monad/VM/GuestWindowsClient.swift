//
//  GuestWindowsClient.swift — MonadHost's connection to a Linux VM's
//  window manager (monad-wm): the host dialed the guest's vsock port, and
//  this reads the windows the guest tells (GuestWindowProtocol.swift) and
//  sends what the Mac's pointer and keyboard do.
//
//  The guest is on the other end. It can say nonsense (the connection
//  ends) and it can stop reading: nothing here waits for it. What is to
//  be sent waits in a bounded buffer, pointer moves it has not taken are
//  replaced by the newest one, and when the buffer is full the connection
//  ends rather than MonadHost growing or its main thread stopping. The
//  Mac's text for a paste may wait beyond that bound, one paste at a time.
//

import Foundation

@MainActor
final class GuestWindowsClient {
    /// Bytes that may wait for a guest that does not read.
    nonisolated static let maxPending = 256 * 1024

    var onDisplay: ((GuestDisplaySize) -> Void)?
    var onWindows: (([GuestWindow]) -> Void)?
    /// What the guest says was copied (GuestClipboard decides whether the Mac takes it).
    var onCopied: ((String) -> Void)?
    /// How the pointer is to look over the guest's windows (a number of GuestCursor's).
    var onCursor: ((Int) -> Void)?
    /// What a program asks of its window (who shows the windows decides whether it is done).
    var onAsked: ((UInt32, GuestWindowAsk) -> Void)?
    /// The guest hung up, said nonsense or stopped reading. Not called for `stop()`.
    var onDisconnect: (() -> Void)?

    private let channel: ByteChannel
    private let queue = DispatchQueue(label: "dev.monad.guest-windows", qos: .userInteractive)
    private let writer: Writer
    private var source: DispatchSourceRead?
    private var finished = false

    init(channel: ByteChannel) {
        self.channel = channel
        writer = Writer(fd: channel.fileDescriptor, queue: queue)
    }

    func start() {
        guard source == nil, !finished else { return }
        let fd = channel.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1 // a guest that hung up is an error from write, not a signal
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var reader = GuestWindowReader()
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let channel = self.channel, writer = self.writer
        src.setEventHandler { [weak self, unowned src] in
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
            let events = n > 0 ? reader.feed(Data(buf[0..<n])) : []
            if n <= 0 || reader.isBroken {
                // Stop reading here and now: a source at EOF stays readable
                // and would fire in a loop until the main thread gets to it.
                src.cancel()
                DispatchQueue.main.async { self?.finish() }
                return
            }
            if !events.isEmpty { DispatchQueue.main.async { self?.handle(events) } }
        }
        src.setCancelHandler {
            writer.close()
            channel.close()
        }
        source = src
        src.resume()
    }

    /// Says it to the window manager; never waits for it.
    func send(_ command: GuestWindowCommand) {
        guard !finished, source != nil else { return }
        let bytes = Array(command.text.utf8)
        guard !bytes.isEmpty else { return }
        var kind = Writer.Kind.line
        if case .pointer = command { kind = .move }
        if case .paste = command { kind = .paste }
        queue.async { [weak self, writer] in
            if !writer.append(bytes, kind) { DispatchQueue.main.async { self?.finish() } }
        }
    }

    func stop() {
        guard !finished else { return }
        finished = true
        if let source {
            source.cancel()
        } else {
            channel.close()
        }
        source = nil
    }

    private func finish() {
        guard !finished else { return }
        stop()
        onDisconnect?()
    }

    private func handle(_ events: [GuestWindowEvent]) {
        guard !finished else { return }
        for event in events {
            switch event {
            case .hello(let display): onDisplay?(display)
            case .windows(let windows): onWindows?(windows)
            case .copied(let text): onCopied?(text)
            case .cursor(let shape): onCursor?(shape)
            case .asked(let window, let ask): onAsked?(window, ask)
            }
        }
    }

    /// What waits to be sent; only ever touched on the client's queue.
    private final class Writer: @unchecked Sendable {
        /// A line that is said whatever waits; a pointer move, which the
        /// next one replaces while it waits; the Mac's text for a paste.
        enum Kind {
            case line, move, paste
        }

        private let fd: Int32
        private let queue: DispatchQueue
        private var pending: [UInt8] = []
        /// Where the last line begins when it is a pointer move not yet sent in part.
        private var move: Int?
        /// Where a paste that waits lies. Its bytes are not counted against
        /// the bound (the user asked for them, and they are bounded
        /// themselves), and no second paste is taken while it waits.
        private var paste: Range<Int>?
        private var retrying = false
        private var closed = false

        init(fd: Int32, queue: DispatchQueue) {
            self.fd = fd
            self.queue = queue
        }

        func close() {
            closed = true
            pending = []
            paste = nil
        }

        /// False when more waits than may: the guest does not read.
        func append(_ bytes: [UInt8], _ kind: Kind) -> Bool {
            guard !closed else { return true }
            if kind == .paste, paste != nil { return true } // left out: one waits already, with a guest that is slow
            if kind == .move, let move { pending.removeSubrange(move...) }
            move = kind == .move ? pending.count : nil
            if kind == .paste { paste = pending.count..<(pending.count + bytes.count) }
            pending += bytes
            flush()
            return pending.count - (paste?.count ?? 0) <= GuestWindowsClient.maxPending
        }

        private func flush() {
            while !pending.isEmpty, !closed {
                let n = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break } // full (or gone, which the reader hears of)
                pending.removeFirst(n)
                if let start = move { move = start >= n ? start - n : nil }
                if let range = paste { paste = range.upperBound > n ? max(0, range.lowerBound - n)..<(range.upperBound - n) : nil }
            }
            guard !pending.isEmpty, !closed, !retrying else { return }
            // The guest's buffer is full: look again shortly (no second source on the descriptor to cancel in step with the reader's).
            retrying = true
            queue.asyncAfter(deadline: .now() + .milliseconds(4)) { [weak self] in
                self?.retrying = false
                self?.flush()
            }
        }
    }
}
