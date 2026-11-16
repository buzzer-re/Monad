//
//  ProcessChannel.swift — a program run with one byte stream as its input
//  and its output: how MonadHost talks to its agent on an SSH host (ssh,
//  running the agent on the server). The agent's protocol is read from it
//  like a VM's from vsock (AgentClient): the stream is a ByteChannel.
//
//  The program gets the helpers' minimal environment (ProcessRunner), a
//  process group of its own and no terminal; closing the channel ends it,
//  and it is reaped whichever way it ends.
//

import Foundation
import os

/// Starts such programs (a seam: tests hand out socketpairs instead).
protocol ChannelSpawning: Sendable {
    /// `environment`: variables added to the helpers' minimal environment.
    func open(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> ByteChannel
}

struct ProcessChannelSpawner: ChannelSpawning {
    func open(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> ByteChannel {
        try ProcessChannel(executable, arguments, environment: environment)
    }
}

final class ProcessChannel: ByteChannel, @unchecked Sendable {
    let fileDescriptor: Int32
    let pid: pid_t
    private let closed = OSAllocatedUnfairLock(initialState: false)

    /// Children are reaped here as they exit, whether or not their channel
    /// is still around.
    private static let reaping = DispatchQueue(label: "dev.monad.channel.reap")
    private static var exits: [pid_t: DispatchSourceProcess] = [:]

    init(_ executable: String, _ arguments: [String], environment: [String: String]) throws {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw MonadError.posix(errno, "Cannot make a socket pair") }
        let null = Darwin.open("/dev/null", O_WRONLY)
        defer { if null >= 0 { Darwin.close(null) } }
        do {
            pid = try ProcessRunner.spawn(executable, arguments, environment: environment, stdin: pair[1], stdout: pair[1],
                                          stderr: null >= 0 ? null : pair[1])
        } catch {
            Darwin.close(pair[0])
            Darwin.close(pair[1])
            throw error
        }
        // Only the child keeps its end: its exit is then the stream's end.
        Darwin.close(pair[1])
        fileDescriptor = pair[0]
        // A write after the program is gone fails; it never raises SIGPIPE.
        var on: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        Self.reap(pid)
    }

    private static func reap(_ pid: pid_t) {
        reaping.async {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: reaping)
            let collect = {
                var status: Int32 = 0
                let done = waitpid(pid, &status, WNOHANG)
                guard done == pid || (done < 0 && errno == ECHILD) else { return }
                exits.removeValue(forKey: pid)?.cancel()
            }
            source.setEventHandler(handler: collect)
            exits[pid] = source
            source.resume()
            // It may have exited before the source was there.
            collect()
        }
    }

    func close() {
        guard closed.withLock({ was -> Bool in
            defer { was = true }
            return !was
        }) else { return }
        Darwin.close(fileDescriptor)
        // Its group: what it started goes with it. Only while it is not
        // reaped: after that its pid may be another program's.
        let pid = self.pid
        Self.reaping.sync { if Self.exits[pid] != nil { killpg(pid, SIGTERM) } }
    }

    deinit { close() }
}
