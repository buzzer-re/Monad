//
//  HostCommandServer.swift — MonadHost's side of a host command: a private
//  unix socket (0600, in the VM's folder; the VM reaches it through a remote
//  forward on its ssh master) taking one request per connection, and the
//  runs themselves. A request is checked against the command's rules before
//  anything runs; one run at a time, the next ones waiting in line (at most
//  `maxQueued`); the program runs without a shell in its own process group,
//  in its working folder, with a plain environment and the command's own;
//  the time limit and stopping end the whole group. With `results` each run
//  gets a folder in the VM's exchange folder (stdout.log, stderr.log,
//  run.json), written as the run goes, and runs/latest leads to it.
//
//  On the socket:
//      → run <values…> | describe
//      ← monad-queued <n>            (while waiting)
//      ← monad-run <token>           then the program's stdout as it comes
//      ← monad-exit <token> <status> <run folder in the VM, or ->
//      ← monad-refused <reason>      (and the connection closes)
//

import Foundation

/// What VMInstance and the MCP tools need of a host command's server.
protocol HostCommandServing: AnyObject {
    func start() throws
    func stop()
    /// A run of `values`, checked and queued as a socket request is.
    func submit(_ values: [String], sink: @escaping @Sendable (HostCommandServer.Event) -> Void) throws
    /// The same, without holding the caller while the values are checked.
    func submitChecking(_ values: [String], sink: @escaping @Sendable (HostCommandServer.Event) -> Void) async throws
}

extension HostCommandServing {
    func submitChecking(_ values: [String], sink: @escaping @Sendable (HostCommandServer.Event) -> Void) async throws {
        try submit(values, sink: sink)
    }
}

final class HostCommandServer: HostCommandServing, @unchecked Sendable {
    enum Event: Equatable, Sendable {
        /// Waiting, at this place in line.
        case queued(Int)
        case started(token: String, folder: String?)
        case output(Data)
        /// The status, 128 + the signal for a program ended by one; the run
        /// folder in the VM.
        case exit(status: Int32, timedOut: Bool, folder: String?)
        /// Dropped before it ran (the command stopped).
        case refused(String)
    }

    private let command: HostCommand
    private let socket: URL
    private let log: URL
    private let exchange: URL
    private let guestExchange: String
    private let maxQueued: Int
    private let environment: [String: String]
    private let maxLogBytes = 1 << 20
    /// How long a request line may take to arrive.
    private let requestTimeout: TimeInterval = 10

    private struct Job {
        let values: [String]
        let argv: [String]
        let sink: @Sendable (Event) -> Void
    }

    private final class Run {
        let job: Job
        let token: String
        let pid: pid_t
        let folder: URL?
        var stdoutLog: Int32 = -1
        var stderrLog: Int32 = -1
        var sources: [DispatchSourceProtocol] = []
        var openPipes = 2
        var exited: Int32?
        var timedOut = false
        let started = Date()
        init(job: Job, token: String, pid: pid_t, folder: URL?) {
            self.job = job
            self.token = token
            self.pid = pid
            self.folder = folder
        }
    }

    // State, only touched on `queue`.
    private let queue = DispatchQueue(label: "dev.monad.hostcommand")
    private var listener: Int32 = -1
    private var logFD: Int32 = -1
    private var accepting: DispatchSourceRead?
    private var waiting: [Job] = []
    private var running: Run?
    private var stopped = false

    init(command: HostCommand, socket: URL, log: URL, exchange: URL, guestExchange: String, maxQueued: Int = 4,
         environment: [String: String]) {
        self.command = command
        self.socket = socket
        self.log = log
        self.exchange = exchange
        self.guestExchange = guestExchange
        self.maxQueued = maxQueued
        self.environment = environment
    }

    deinit { stop() }

    // MARK: Socket

    func start() throws {
        let fd = try BridgeServer.listen(at: socket.path, what: "the host command's socket")
        let logged = open(log.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard logged >= 0 else {
            let e = errno
            close(fd)
            unlink(socket.path)
            throw MonadError.posix(e, "Cannot open the host command's log")
        }
        queue.sync {
            stopped = false
            listener = fd
            logFD = logged
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAll() }
            source.resume()
            accepting = source
        }
    }

    /// Stops listening, removes the socket, tells the waiting runs and ends
    /// the one running (its process group gets SIGTERM, then SIGKILL).
    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            accepting?.cancel()
            accepting = nil
            if listener >= 0 {
                close(listener)
                listener = -1
                unlink(socket.path)
            }
            let dropped = waiting
            waiting = []
            for job in dropped { job.sink(.refused("The host command stopped.")) }
            if let run = running {
                note("stopped: ending pid \(run.pid)")
                end(run, signal: SIGTERM)
            }
        }
    }

    private func acceptAll() {
        while listener >= 0 {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            var on: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
            _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) | O_NONBLOCK)
            readRequest(on: connection)
        }
    }

    /// Reads one line (bounded, timed), then answers it.
    private func readRequest(on fd: Int32) {
        var line = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var finished = false
        let timer = DispatchSource.makeTimerSource(queue: queue)
        func finish(_ text: String?) {
            guard !finished else { return }
            finished = true
            source.cancel()
            timer.cancel()
            guard let text else {
                close(fd)
                return
            }
            answer(text, on: fd)
        }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EAGAIN || errno == EINTR { return }
            if n <= 0 {
                finish(line.isEmpty ? nil : String(decoding: line, as: UTF8.self))
                return
            }
            line.append(contentsOf: buffer[0..<n])
            if let end = line.firstIndex(of: 0x0A) {
                finish(String(decoding: line[..<end], as: UTF8.self))
            } else if line.count > HostCommand.maxRequestBytes {
                finished = true
                source.cancel()
                timer.cancel()
                self.refuse("The request is too long.", on: fd)
            }
        }
        timer.schedule(deadline: .now() + requestTimeout)
        timer.setEventHandler { [weak self] in
            guard !finished else { return }
            finished = true
            source.cancel()
            self?.refuse("No request came.", on: fd)
        }
        source.resume()
        timer.resume()
    }

    private func answer(_ text: String, on fd: Int32) {
        let request: HostCommand.Request
        do {
            request = try HostCommand.parseRequest(text)
        } catch {
            refuse(error.localizedDescription, on: fd)
            return
        }
        switch request {
        case .describe:
            let writer = Writer(fd: fd)
            writer.write(Data((command.describe + "\n").utf8))
            writer.close()
        case .run(let values):
            let writer = Writer(fd: fd)
            do {
                try enqueue(values) { event in
                    switch event {
                    case .queued(let n): writer.write(Data("monad-queued \(n)\n".utf8))
                    case .started(let token, _): writer.write(Data("monad-run \(token)\n".utf8)); writer.token = token
                    case .output(let data): writer.write(data)
                    case .exit(let status, _, let folder):
                        writer.write(Data("monad-exit \(writer.token) \(status) \(folder ?? "-")\n".utf8))
                        writer.close()
                    case .refused(let why):
                        writer.write(Data("monad-refused \(why)\n".utf8))
                        writer.close()
                    }
                }
            } catch {
                writer.write(Data("monad-refused \(error.localizedDescription)\n".utf8))
                writer.close()
            }
        }
    }

    private func refuse(_ why: String, on fd: Int32) {
        note("refused: \(why)")
        let writer = Writer(fd: fd)
        writer.write(Data("monad-refused \(why)\n".utf8))
        writer.close()
    }

    /// Writes to a connection on its own queue, so a reader that stops
    /// reading holds up only itself (the run folder has everything).
    private final class Writer: @unchecked Sendable {
        private let fd: Int32
        private let queue = DispatchQueue(label: "dev.monad.hostcommand.writer")
        private var dead = false
        var token = "-"

        init(fd: Int32) {
            self.fd = fd
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var limit = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        }

        func write(_ data: Data) {
            queue.async { [self] in
                guard !dead else { return }
                data.withUnsafeBytes { raw in
                    var off = 0
                    while off < raw.count {
                        let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                        if n < 0, errno == EINTR { continue }
                        if n <= 0 { dead = true; return }
                        off += n
                    }
                }
            }
        }

        func close() {
            queue.async { [self] in Darwin.close(fd) }
        }
    }

    // MARK: Runs

    func submit(_ values: [String], sink: @escaping @Sendable (Event) -> Void) throws {
        try queue.sync { try enqueue(values, sink: sink) }
    }

    /// Checked on the server's queue (a pattern may take up to
    /// `HostCommand.matchSeconds`): the caller's actor is free meanwhile.
    func submitChecking(_ values: [String], sink: @escaping @Sendable (Event) -> Void) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try enqueue(values, sink: sink)
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    private func enqueue(_ values: [String], sink: @escaping @Sendable (Event) -> Void) throws {
        guard !stopped else { throw HostCommand.Refused("The host command stopped.") }
        let argv: [String]
        do {
            argv = [command.program] + (try command.arguments(for: values))
        } catch {
            note("refused: \(error.localizedDescription)")
            throw error
        }
        if running != nil {
            guard waiting.count < maxQueued else {
                let why = "Busy: \(waiting.count) run\(waiting.count == 1 ? " is" : "s are") waiting already. Try again later."
                note("refused: \(why)")
                throw HostCommand.Refused(why)
            }
            waiting.append(Job(values: values, argv: argv, sink: sink))
            sink(.queued(waiting.count))
            return
        }
        begin(Job(values: values, argv: argv, sink: sink))
    }

    private func begin(_ job: Job) {
        boundLog()
        note("run \(command.name)\(job.values.isEmpty ? "" : " " + job.values.joined(separator: " "))")
        var folder: URL?
        if command.results { folder = makeRunFolder() }
        var env = environment.filter { BridgeServer.passedVariables.contains($0.key) }
        for (k, v) in command.environment { env[k] = v }
        if let folder { env["MONAD_RUN_DIR"] = folder.path }

        var out: [Int32] = [-1, -1], err: [Int32] = [-1, -1]
        let devNull = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard pipe(&out) == 0, pipe(&err) == 0, devNull >= 0 else {
            for fd in out + err + [devNull] where fd >= 0 { close(fd) }
            fail(job, folder: folder, why: "cannot make pipes")
            return
        }
        for fd in [out[0], err[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
        let pid: pid_t
        do {
            pid = try BridgeServer.spawn(job.argv, environment: env.map { "\($0.key)=\($0.value)" }.sorted(),
                                         stdin: devNull, stdout: out[1], stderr: err[1], directory: command.workingDirectory)
        } catch {
            for fd in out + err + [devNull] { close(fd) }
            fail(job, folder: folder, why: "\(command.program) could not start: \(error.localizedDescription)")
            return
        }
        close(out[1]); close(err[1]); close(devNull)
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, bytes.count)
        let token = bytes.prefix(8).map { String(format: "%02x", $0) }.joined()
        let run = Run(job: job, token: token, pid: pid, folder: folder)
        running = run
        if let folder {
            run.stdoutLog = open(folder.appendingPathComponent("stdout.log").path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
            run.stderrLog = open(folder.appendingPathComponent("stderr.log").path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
            writeRunJSON(run)
        }
        job.sink(.started(token: token, folder: folder.map(guestPath)))

        watch(out[0], run: run) { [weak self] data in
            if run.stdoutLog >= 0 { Self.writeAll(run.stdoutLog, data) }
            run.job.sink(.output(data))
            _ = self
        }
        watch(err[0], run: run) { [weak self] data in
            if run.stderrLog >= 0 { Self.writeAll(run.stderrLog, data) }
            self?.noteRaw(data)
        }
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in self?.reap(run) }
        run.sources.append(exit)
        exit.resume()
        let limit = DispatchSource.makeTimerSource(queue: queue)
        limit.schedule(deadline: .now() + .seconds(command.timeoutSeconds))
        limit.setEventHandler { [weak self] in
            guard let self, run.exited == nil else { return }
            run.timedOut = true
            self.note("the time limit (\(self.command.timeoutSeconds) s) passed: ending pid \(run.pid)")
            self.end(run, signal: SIGTERM)
        }
        run.sources.append(limit)
        limit.resume()
        reap(run, onlyIfDone: true)
    }

    private func watch(_ fd: Int32, run: Run, _ deliver: @escaping (Data) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EAGAIN || errno == EINTR { return }
            if n <= 0 {
                source.cancel()
                return
            }
            deliver(Data(buffer[0..<n]))
            _ = self
        }
        source.setCancelHandler { [weak self] in
            close(fd)
            run.openPipes -= 1
            self?.finishIfDone(run)
        }
        run.sources.append(source)
        source.resume()
    }

    /// SIGTERM to the whole group now, SIGKILL a moment later if any is left.
    private func end(_ run: Run, signal: Int32) {
        kill(-run.pid, signal)
        queue.asyncAfter(deadline: .now() + 0.5) {
            kill(-run.pid, SIGKILL)
        }
    }

    private func reap(_ run: Run, onlyIfDone: Bool = false) {
        guard run.exited == nil else { return }
        var status: Int32 = 0
        let done = waitpid(run.pid, &status, WNOHANG)
        guard done == run.pid else { return }
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        run.exited = code
        // What it left behind goes with it; the pipes then close.
        kill(-run.pid, SIGTERM)
        queue.asyncAfter(deadline: .now() + 0.5) { kill(-run.pid, SIGKILL) }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            // Output a stray descendant still holds is not waited for.
            for case let s as DispatchSourceRead in run.sources where !s.isCancelled { s.cancel() }
            self?.finishIfDone(run)
        }
        finishIfDone(run)
        _ = onlyIfDone
    }

    private func finishIfDone(_ run: Run) {
        guard let status = run.exited, run.openPipes <= 0, running === run else { return }
        running = nil
        for s in run.sources where !s.isCancelled { s.cancel() }
        if run.stdoutLog >= 0 { close(run.stdoutLog) }
        if run.stderrLog >= 0 { close(run.stderrLog) }
        if run.folder != nil { writeRunJSON(run, ended: Date(), status: status) }
        note("ended with status \(status)\(run.timedOut ? " (time limit)" : "") after \(String(format: "%.1f", Date().timeIntervalSince(run.started))) s")
        run.job.sink(.exit(status: status, timedOut: run.timedOut, folder: run.folder.map(guestPath)))
        next()
    }

    private func fail(_ job: Job, folder: URL?, why: String) {
        note(why)
        if let folder {
            Self.writeAll(open(folder.appendingPathComponent("stderr.log").path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644),
                          Data((why + "\n").utf8), closing: true)
        }
        job.sink(.started(token: "-", folder: folder.map(guestPath)))
        job.sink(.exit(status: 127, timedOut: false, folder: folder.map(guestPath)))
        next()
    }

    private func next() {
        guard running == nil, !stopped, !waiting.isEmpty else { return }
        let job = waiting.removeFirst()
        for (i, other) in waiting.enumerated() { other.sink(.queued(i + 1)) }
        begin(job)
    }

    // MARK: Run folders

    private func guestPath(_ folder: URL) -> String { "\(guestExchange)/runs/\(folder.lastPathComponent)" }

    /// runs/<yyyymmdd-hhmmss>-<name>[-n], and runs/latest leading to it.
    private func makeRunFolder() -> URL? {
        let runs = exchange.appendingPathComponent("runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o755])
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "\(f.string(from: Date()))-\(command.name)"
        var name = stem, n = 2
        while FileManager.default.fileExists(atPath: runs.appendingPathComponent(name).path) {
            name = "\(stem)-\(n)"
            n += 1
        }
        let folder = runs.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o755])
        } catch {
            note("cannot make the run folder: \(error.localizedDescription)")
            return nil
        }
        let latest = runs.appendingPathComponent("latest").path
        unlink(latest)
        symlink(name, latest)
        return folder
    }

    private func writeRunJSON(_ run: Run, ended: Date? = nil, status: Int32? = nil) {
        guard let folder = run.folder else { return }
        let f = ISO8601DateFormatter()
        var json: [String: Any] = ["command": command.name, "arguments": run.job.values, "started": f.string(from: run.started)]
        if let ended { json["ended"] = f.string(from: ended) }
        if let status { json["status"] = Int(status); json["timedOut"] = run.timedOut }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted]) else { return }
        try? data.write(to: folder.appendingPathComponent("run.json"), options: .atomic)
    }

    private static func writeAll(_ fd: Int32, _ data: Data, closing: Bool = false) {
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { break }
                off += n
            }
        }
        if closing { close(fd) }
    }

    // MARK: Log

    private func note(_ line: String) {
        guard logFD >= 0 else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        Self.writeAll(logFD, Data("[\(stamp)] \(line)\n".utf8))
    }

    private func noteRaw(_ data: Data) {
        guard logFD >= 0 else { return }
        Self.writeAll(logFD, data)
    }

    /// The log starts again once it passes its size.
    private func boundLog() {
        var info = stat()
        guard logFD >= 0, fstat(logFD, &info) == 0, info.st_size > maxLogBytes else { return }
        _ = ftruncate(logFD, 0)
        note("the log started again (it had passed \(maxLogBytes) bytes)")
    }
}
