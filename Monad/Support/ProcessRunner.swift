//
//  ProcessRunner.swift — run short-lived helper processes (ssh, ssh-keygen,
//  lsof, launchctl) without ever leaving anything behind:
//
//  - each helper gets its own process group; a timeout sends SIGTERM to the
//    whole group, then SIGKILL, so children die with it;
//  - output is capped (a guest can make ssh print without end); the rest is
//    read and dropped so the writer never blocks;
//  - the result does not wait for background children that keep the pipes
//    open (e.g. `ssh -f`);
//  - children start with default signal handling (Monad ignores SIGPIPE).
//

import Foundation
import os

enum ProcessRunner {
    /// Bytes kept per stream.
    static let outputLimit = 1 << 20
    /// How long to keep reading after the helper exited, for output still
    /// in flight; children holding the pipes longer are not waited for.
    static let drainGrace: TimeInterval = 0.5
    /// Between SIGTERM and SIGKILL on timeout.
    static let killGrace: TimeInterval = 2

    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data
        /// Output beyond `outputLimit` was dropped.
        var outputTruncated = false
        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// Minimal, predictable environment for helper processes.
    static var baseEnvironment: [String: String] {
        let env = ProcessInfo.processInfo.environment
        var out: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": Paths.home.path,
            "LANG": env["LANG"] ?? "en_US.UTF-8",
        ]
        if let user = env["USER"] { out["USER"] = user; out["LOGNAME"] = user }
        return out
    }

    /// Run a process to completion off the main thread, optionally feeding stdin.
    /// `onOutput` gets each chunk as it is read (0: stdout, 1: stderr), on a
    /// reader thread; the result still holds the output (up to the limit).
    static func run(_ executable: String, _ arguments: [String], stdin: Data? = nil,
                    timeout: TimeInterval = 60, onOutput: (@Sendable (Int, Data) -> Void)? = nil) async throws -> Result {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try runSync(executable, arguments, stdin: stdin, timeout: timeout,
                                                       onOutput: onOutput))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    static func runSync(_ executable: String, _ arguments: [String], stdin: Data? = nil,
                        timeout: TimeInterval = 60, onOutput: (@Sendable (Int, Data) -> Void)? = nil) throws -> Result {
        let name = (executable as NSString).lastPathComponent
        let out = try Pipe2(), err = try Pipe2()
        let input = stdin != nil ? try Pipe2() : nil
        let pid: pid_t
        do {
            pid = try spawn(executable, arguments, stdin: input?.read, stdout: out.write, stderr: err.write)
        } catch {
            [out, err, input].compactMap { $0 }.forEach { $0.closeBoth() }
            throw error
        }
        // Only the child keeps these ends.
        out.closeWrite()
        err.closeWrite()
        input?.closeRead()

        if let input, let stdin {
            let fd = input.write
            input.release()
            DispatchQueue.global(qos: .utility).async {
                stdin.withUnsafeBytes { buf in
                    var off = 0
                    while off < buf.count {
                        let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                        if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
                    }
                }
                Darwin.close(fd)
            }
        }

        let collector = OutputCollector(out: out.read, err: err.read, limit: outputLimit, onOutput: onOutput)
        out.release()
        err.release()
        let reading = DispatchGroup()
        reading.enter()
        Thread.detachNewThread {
            collector.pump()
            reading.leave()
        }

        let status = OSAllocatedUnfairLock(initialState: Int32(0))
        let exited = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var st: Int32 = 0
            while waitpid(pid, &st, 0) < 0 && errno == EINTR {}
            let final = st
            status.withLock { $0 = final }
            exited.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            Log.app.notice("\(name, privacy: .public) timed out after \(timeout) s; stopping its process group")
            killpg(pid, SIGTERM)
            if exited.wait(timeout: .now() + killGrace) == .timedOut {
                killpg(pid, SIGKILL)
                exited.wait()
            }
            // The group may outlive its leader for a moment; make sure.
            killpg(pid, SIGKILL)
            collector.stop(after: drainGrace)
            reading.wait()
            throw MonadError("\(name) timed out")
        }
        collector.stop(after: drainGrace)
        reading.wait()
        return Result(status: exitCode(status.withLock { $0 }), stdout: collector.stdout, stderr: collector.stderr,
                      outputTruncated: collector.truncated)
    }

    /// Exit status, or 128 + signal for a helper killed by a signal (like a shell).
    private static func exitCode(_ st: Int32) -> Int32 {
        let sig = st & 0x7f
        return sig == 0 ? (st >> 8) & 0xff : 128 + sig
    }

    private static func spawn(_ executable: String, _ arguments: [String], stdin: Int32?, stdout: Int32,
                              stderr: Int32) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Own process group; only the descriptors set up below are inherited;
        // default dispositions and an empty mask for every signal.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let stdin {
            posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = baseEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        guard rc == 0 else { throw MonadError.posix(rc, "Cannot run \(executable)") }
        return pid
    }
}

/// A pipe whose ends are closed exactly once.
private final class Pipe2 {
    private(set) var read: Int32
    private(set) var write: Int32

    init() throws {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw MonadError.posix(errno, "Cannot create a pipe") }
        read = fds[0]
        write = fds[1]
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    }

    func closeRead() { if read >= 0 { Darwin.close(read); read = -1 } }
    func closeWrite() { if write >= 0 { Darwin.close(write); write = -1 } }
    func closeBoth() { closeRead(); closeWrite() }
    /// Ownership of the remaining ends moved elsewhere.
    func release() { read = -1; write = -1 }

    deinit { closeBoth() }
}

/// Reads stdout and stderr on one thread, keeping at most `limit` bytes of
/// each and dropping the rest.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var fds: [Int32]
    private var buffers = [Data(), Data()]
    private var deadline: Date?
    private let limit: Int
    private let onOutput: (@Sendable (Int, Data) -> Void)?
    private(set) var truncated = false

    init(out: Int32, err: Int32, limit: Int, onOutput: (@Sendable (Int, Data) -> Void)?) {
        fds = [out, err]
        self.limit = limit
        self.onOutput = onOutput
    }

    var stdout: Data { lock.withLock { buffers[0] } }
    var stderr: Data { lock.withLock { buffers[1] } }

    /// Keep reading at most `grace` longer, then give up on the pipes.
    func stop(after grace: TimeInterval) {
        lock.withLock { deadline = Date().addingTimeInterval(grace) }
    }

    func pump() {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        var open = [true, true]
        while open.contains(true) {
            if let deadline = lock.withLock({ deadline }), Date() >= deadline { break }
            var pfds = (0..<2).filter { open[$0] }.map { pollfd(fd: fds[$0], events: Int16(POLLIN), revents: 0) }
            let r = poll(&pfds, nfds_t(pfds.count), 100)
            if r < 0 && errno != EINTR { break }
            guard r > 0 else { continue }
            for p in pfds where p.revents != 0 {
                let i = p.fd == fds[0] ? 0 : 1
                let n = Darwin.read(p.fd, &buf, buf.count)
                if n > 0 {
                    onOutput?(i, Data(buf[0..<n]))
                    lock.withLock {
                        let room = limit - buffers[i].count
                        if room > 0 { buffers[i].append(contentsOf: buf[0..<min(n, room)]) }
                        if n > room { truncated = true }
                    }
                } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                    open[i] = false
                }
            }
        }
        for fd in fds { Darwin.close(fd) }
    }
}
