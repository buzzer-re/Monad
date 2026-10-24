//
//  AgentClientTests.swift — the host end of the agent channel, driven by a
//  scripted fake agent on the other side of a socketpair.
//

import XCTest
@testable import Monad

/// A byte channel over one end of a socketpair; the test owns the other end.
final class SocketPairChannel: ByteChannel, @unchecked Sendable {
    let fileDescriptor: Int32
    let peer: Int32
    private(set) var closed = false

    init() {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        fileDescriptor = fds[0]
        peer = fds[1]
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fileDescriptor)
    }

    /// Write as the guest agent.
    func agentSays(_ text: String) {
        _ = text.withCString { Darwin.write(peer, $0, strlen($0)) }
    }

    /// What the host sent to the agent so far.
    func hostSent() -> String {
        var buf = [UInt8](repeating: 0, count: 4096)
        let flags = fcntl(peer, F_GETFL)
        _ = fcntl(peer, F_SETFL, flags | O_NONBLOCK)
        let n = read(peer, &buf, buf.count)
        _ = fcntl(peer, F_SETFL, flags)
        return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
    }

    func hangUp() { Darwin.close(peer) }
}

@MainActor
final class AgentClientTests: XCTestCase {
    private func port(_ a: String, _ p: Int) -> ListeningPort { ListeningPort(address: a, port: p) }

    func testHandshakeThenWatchesPorts() async throws {
        let ch = SocketPairChannel()
        let client = AgentClient(channel: ch)
        client.start()
        await assertEventually { ch.hostSent().contains("hello\nwatch-ports\n") || client.version != nil }
        ch.agentSays("hello monad-agent 1\n")
        await assertEventually { client.version == 1 }
    }

    func testRecordsWatchMode() async throws {
        let ch = SocketPairChannel()
        let client = AgentClient(channel: ch)
        client.start()
        XCTAssertNil(client.watchMode)
        ch.agentSays("mode events\n")
        await assertEventually { client.watchMode == .events }
    }

    func testTracksOpenedAndClosedPorts() async throws {
        let ch = SocketPairChannel()
        let client = AgentClient(channel: ch)
        client.start()
        ch.agentSays("hello monad-agent 1\nport+ tcp 0.0.0.0 8080\nport+ tcp 127.0.0.1 5432\nping\n")
        await assertEventually { client.ports == [self.port("0.0.0.0", 8080), self.port("127.0.0.1", 5432)] }
        ch.agentSays("port- tcp 0.0.0.0 8080\n")
        await assertEventually { client.ports == [self.port("127.0.0.1", 5432)] }
    }

    func testEventsAreDeliveredInOrder() async throws {
        let ch = SocketPairChannel()
        let client = AgentClient(channel: ch)
        var events: [AgentMessage] = []
        client.onEvent = { events.append($0) }
        client.start()
        ch.agentSays("port+ tcp :: 3000\nport- tcp :: 3000\nport+ tcp :: 3001\n")
        await assertEventually { events.count == 3 }
        XCTAssertEqual(events, [.opened(port("::", 3000)), .closed(port("::", 3000)), .opened(port("::", 3001))])
    }

    func testHostileOutputIsIgnored() async throws {
        let ch = SocketPairChannel()
        let client = AgentClient(channel: ch)
        client.start()
        ch.agentSays("port+ tcp 0.0.0.0 99999\nport+ tcp evil.example 80\n\u{1B}[2Jport+ tcp 0.0.0.0 81\n")
        ch.agentSays(String(repeating: "A", count: 10_000))
        ch.agentSays("\nport+ tcp 0.0.0.0 8080\n")
        await assertEventually { client.ports == [self.port("0.0.0.0", 8080)] }
        XCTAssertGreaterThanOrEqual(client.rejectedLines, 3)
    }

    func testDisconnectIsReportedAndPortsCleared() async throws {
        let ch = SocketPairChannel()
        let client = AgentClient(channel: ch)
        var disconnected = false
        client.onDisconnect = { disconnected = true }
        client.start()
        ch.agentSays("port+ tcp 0.0.0.0 8080\n")
        await assertEventually { !client.ports.isEmpty }
        ch.hangUp()
        await assertEventually { disconnected }
        XCTAssertTrue(client.ports.isEmpty, "ports from a gone agent are not trusted")
        await assertEventually { ch.closed }
    }

    func testAGoneAgentCostsNoCPUWhileTheAppIsBusy() throws {
        let ch = SocketPairChannel()
        let client = AgentClient(channel: ch)
        client.start()
        ch.hangUp()
        // The main thread is busy (layout, a modal sheet…): EOF must not spin
        // on the agent queue or pile up work for the main queue.
        let before = processCPUSeconds()
        Thread.sleep(forTimeInterval: 0.4)
        let used = processCPUSeconds() - before
        XCTAssertLessThan(used, 0.15, "the agent queue spun for \(used) s")
        XCTAssertTrue(ch.closed, "the channel is closed without waiting for the main thread")
        withExtendedLifetime(client) {}
    }

    func testStopClosesChannel() async throws {
        let ch = SocketPairChannel()
        let client = AgentClient(channel: ch)
        client.start()
        client.stop()
        // Closed by the read source's cancel handler, so no read can race a closed fd.
        await assertEventually { ch.closed }
    }
}
