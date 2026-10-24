//
//  PTYSession.swift — a child process on a PTY, feeding a TerminalModel.
//
//  All I/O runs on a private serial queue. Output is parsed on that queue and
//  the UI is notified (coalesced) on the main queue.
//

import Foundation
import os

final class PTYSession {
    struct Command {
        var executable: String
        var arguments: [String] // argv[0] included
        var environment: [String: String]
        var directory: String?
    }

    private let model: TerminalModel
    private let queue = DispatchQueue(label: "dev.monad.pty", qos: .userInteractive)
    private var fd: Int32 = -1
    private(set) var pid: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var processSource: DispatchSourceProcess?
    private var pending = Data()
    private var updateScheduled = false
    private let updateLock = NSLock()
    private var exited = false

    /// Called on the main queue after new output was processed.
    var onOutput: (() -> Void)?
    /// Called once on the main queue with the wait(2) status.
    var onExit: ((Int32) -> Void)?

    init(model: TerminalModel) {
        self.model = model
    }

    deinit {
        readSource?.cancel()
        writeSource?.cancel()
        processSource?.cancel()
        if fd >= 0 { close(fd) }
        // Never leave a running child or a zombie behind.
        if pid > 0 && !exited {
            let pid = self.pid
            DispatchQueue.global(qos: .utility).async {
                _ = mnd_pty_signal(pid, SIGHUP)
                for _ in 0..<30 {
                    if mnd_pty_wait(pid, nil, true) != 0 { return }
                    usleep(100_000)
                }
                _ = mnd_pty_signal(pid, SIGKILL)
                _ = mnd_pty_wait(pid, nil, false)
            }
        }
    }

    var isRunning: Bool { queue.sync { fd >= 0 && !exited } }

    func start(_ command: Command, cols: Int, rows: Int) throws {
        var argv: [UnsafeMutablePointer<CChar>?] = command.arguments.map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = command.environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pty = mnd_pty()
        let err = command.executable.withCString { path in
            if let dir = command.directory {
                return dir.withCString { mnd_pty_spawn(path, &argv, &envp, $0, Int32(cols), Int32(rows), &pty) }
            }
            return mnd_pty_spawn(path, &argv, &envp, nil, Int32(cols), Int32(rows), &pty)
        }
        if err != 0 { throw MonadError.posix(err, "Cannot start \(command.executable)") }

        queue.sync {
            fd = pty.master_fd
            pid = pty.pid
            exited = false
            pending.removeAll()
        }
        model.replyHandler = { [weak self] data in self?.write(data) }
        installSources()
    }

    private func installSources() {
        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        rs.setEventHandler { [weak self] in self?.readAvailable() }
        readSource = rs
        rs.resume()

        let ps = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        ps.setEventHandler { [weak self] in self?.reap(attempt: 0) }
        processSource = ps
        ps.resume()
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var total = 0
        while total < 1 << 20 { // bound work per event to stay responsive
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buf.withUnsafeBytes { model.feed(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                total += n
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EINTR) { break }
            // EOF or EIO: the slave side is gone.
            readSource?.cancel()
            readSource = nil
            break
        }
        if total > 0 { scheduleUpdate() }
    }

    private func scheduleUpdate() {
        updateLock.lock()
        let needed = !updateScheduled
        updateScheduled = true
        updateLock.unlock()
        guard needed else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateLock.lock()
            self.updateScheduled = false
            self.updateLock.unlock()
            self.onOutput?()
        }
    }

    /// Called on NOTE_EXIT. The kernel can signal the exit a moment before
    /// the child becomes waitable, so retry briefly instead of losing it.
    private func reap(attempt: Int = 0) {
        var status: Int32 = 0
        let r = mnd_pty_wait(pid, &status, true)
        if r == 0 {
            if attempt < 500 {
                queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in self?.reap(attempt: attempt + 1) }
            } else {
                Log.term.error("child \(self.pid) signalled exit but could not be reaped")
            }
            return
        }
        // r == -1: someone else already reaped it (ECHILD). It is gone all
        // the same; the pid must never be signalled again. Its status is
        // unknown, so not a clean exit (which would close the tab).
        if r < 0 { status = -1 }
        processSource?.cancel()
        processSource = nil
        // Drain whatever is left, then close.
        if readSource != nil { readAvailable() }
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        if fd >= 0 { close(fd); fd = -1 }
        exited = true
        scheduleUpdate()
        DispatchQueue.main.async { [weak self] in self?.onExit?(status) }
    }

    // MARK: Writing

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            self.pending.append(data)
            self.flush()
        }
    }

    func write(_ string: String) { write(Data(string.utf8)) }

    private func flush() {
        while !pending.isEmpty {
            let n = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                pending.removeFirst(n)
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && errno == EAGAIN {
                if writeSource == nil {
                    let ws = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    ws.setEventHandler { [weak self] in self?.flush() }
                    writeSource = ws
                    ws.resume()
                }
                return
            }
            Log.term.error("pty write failed: \(String(cString: strerror(errno)), privacy: .public)")
            pending.removeAll()
            break
        }
        writeSource?.cancel()
        writeSource = nil
    }

    // MARK: Control

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            _ = mnd_pty_resize(self.fd, Int32(cols), Int32(rows), Int32(pixelWidth), Int32(pixelHeight))
        }
    }

    /// Hang up the session (like closing a terminal window).
    func terminate() {
        queue.async { [weak self] in
            guard let self, self.pid > 0, !self.exited else { return }
            _ = mnd_pty_signal(self.pid, SIGHUP)
            let pid = self.pid
            // Escalate if the process ignores SIGHUP.
            self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.exited, self.pid == pid else { return }
                _ = mnd_pty_signal(pid, SIGKILL)
            }
        }
    }
}
