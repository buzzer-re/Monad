//
//  AgentClient.swift — host end of the monad-agent channel.
//
//  The host dials the guest (vsock 1024), says hello, and asks the agent to
//  watch listening ports. Output is parsed strictly (AgentProtocol.swift);
//  state is published on the main actor.
//

import Combine
import Foundation
import os

/// A connected byte stream (a vsock connection in production, a socketpair
/// in tests). The channel owns its file descriptor.
protocol ByteChannel: AnyObject, Sendable {
    var fileDescriptor: Int32 { get }
    func close()
}

@MainActor
final class AgentClient: ObservableObject {
    /// Upper bound on tracked ports; a guest cannot grow host memory unboundedly.
    static let maxTrackedPorts = 4096

    @Published private(set) var ports: Set<ListeningPort> = []
    @Published private(set) var version: Int?
    @Published private(set) var watchMode: AgentWatchMode?
    private(set) var rejectedLines = 0

    var onEvent: ((AgentMessage) -> Void)?
    var onDisconnect: (() -> Void)?

    private let channel: ByteChannel
    private let queue = DispatchQueue(label: "dev.monad.agent", qos: .utility)
    private var source: DispatchSourceRead?
    private var finished = false

    init(channel: ByteChannel) {
        self.channel = channel
    }

    func start() {
        guard source == nil, !finished else { return }
        let fd = channel.fileDescriptor
        let hello = Array("hello\nwatch-ports\n".utf8)
        let written = hello.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == hello.count else {
            finish()
            return
        }
        var reader = AgentLineReader()
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let channel = self.channel
        src.setEventHandler { [weak self, unowned src] in
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 {
                if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
                // Stop reading here and now: a source at EOF stays readable
                // and would fire in a loop until the main thread gets to it.
                src.cancel()
                DispatchQueue.main.async { self?.finish() }
                return
            }
            let droppedBefore = reader.droppedLines
            let lines = reader.feed(Data(buf[0..<n]))
            let dropped = reader.droppedLines - droppedBefore
            DispatchQueue.main.async { self?.handle(lines, droppedLines: dropped) }
        }
        src.setCancelHandler { channel.close() }
        source = src
        src.resume()
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
        ports.removeAll()
    }

    private func finish() {
        guard !finished else { return }
        stop()
        onDisconnect?()
    }

    private func handle(_ lines: [String], droppedLines: Int) {
        guard !finished else { return }
        rejectedLines += droppedLines
        for line in lines {
            guard let message = AgentMessage.parse(line) else {
                rejectedLines += 1
                continue
            }
            switch message {
            case .hello(let v):
                version = v
            case .mode(let m):
                watchMode = m
            case .opened(let p), .port(let p):
                if ports.count < Self.maxTrackedPorts { ports.insert(p) }
            case .closed(let p):
                ports.remove(p)
            case .error(let code):
                Log.vm.error("agent error: \(code, privacy: .public)")
            case .end, .ping, .prompt:
                break
            }
            onEvent?(message)
        }
    }
}
