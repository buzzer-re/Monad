//
//  DebugLog.swift — Settings › Logs. When on, the app and MonadHost write
//  what they do, step by step, to ~/.monad/logs/monad_<date>.log: one file a
//  day that both append to (each line is one write, so lines never mix),
//  private to the user, at most `limit` bytes a day, the last 14 days kept.
//  Off by default, and then a call costs one flag read: the message is not
//  even formatted.
//
//  The switch is a small file both processes read at start, and a Darwin
//  notification tells a running process at once when the app changes it.
//

import Foundation
import os

final class DebugLog: @unchecked Sendable {
    static let changedNotification = "dev.monad.debug-log.changed"
    /// This process's log ("Monad" or "MonadHost" in its lines).
    static let shared = DebugLog(process: ProcessInfo.processInfo.processName)
    static let keepDays = 14

    let process: String
    let directory: URL
    let settings: URL
    private let now: @Sendable () -> Date
    private let limit: Int
    private let pid = ProcessInfo.processInfo.processIdentifier
    private let enabled = OSAllocatedUnfairLock(initialState: false)
    private let queue = DispatchQueue(label: "dev.monad.debug-log")
    private let unified = Logger(subsystem: Flavor.current.logSubsystem, category: "debug")
    private var watchToken: Int32 = -1

    // Used on `queue` only.
    private var fd: Int32 = -1
    private var day = ""
    private var full = false

    init(process: String, directory: URL = Paths.logs, settings: URL = Paths.logSettings,
         now: @escaping @Sendable () -> Date = { Date() }, limit: Int = 64 << 20) {
        self.process = process
        self.directory = directory
        self.settings = settings
        self.now = now
        self.limit = limit
    }

    deinit {
        if watchToken >= 0 { notify_cancel(watchToken) }
        if fd >= 0 { close(fd) }
    }

    var isEnabled: Bool { enabled.withLock { $0 } }

    /// Today's file (where the next line goes).
    var currentFile: URL { directory.appendingPathComponent("monad_\(Self.stamp(now()).day).log") }

    func setEnabled(_ on: Bool) {
        if !on, isEnabled { log("log", "debug logging turned off") }
        let was = enabled.withLock { flag -> Bool in
            defer { flag = on }
            return flag
        }
        guard on != was else { return }
        if on {
            queue.async { self.removeOldDays() }
            log("log", "debug logging turned on")
        } else {
            queue.async { self.closeFile() }
        }
    }

    /// One line (more if `message` has newlines) about `scope` ("vm default",
    /// "host", "cmd", …).
    func log(_ scope: String, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let date = now()
        let text = message()
        unified.debug("\(scope, privacy: .public): \(text, privacy: .public)")
        queue.async { self.write(date: date, scope: scope, text: text) }
    }

    /// Waits until everything logged so far is written.
    func flush() { queue.sync {} }

    // MARK: The switch

    private struct Setting: Codable { var enabled: Bool }

    static func load(settings: URL = Paths.logSettings) -> Bool {
        (try? JSONDecoder().decode(Setting.self, from: Data(contentsOf: settings)))?.enabled ?? false
    }

    /// Saves the switch (Settings › Logs) and tells running processes.
    static func save(enabled: Bool, settings: URL = Paths.logSettings,
                     notification: String = changedNotification) throws {
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Setting(enabled: enabled)).write(to: settings, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        notify_post(notification)
    }

    func reloadSettings() { setEnabled(Self.load(settings: settings)) }

    /// Follows the switch from now on (read once now).
    func watchSettings(notification: String = changedNotification) {
        reloadSettings()
        guard watchToken < 0 else { return }
        var token: Int32 = -1
        let status = notify_register_dispatch(notification, &token, DispatchQueue.global(qos: .utility)) { [weak self] _ in
            self?.reloadSettings()
        }
        if status == NOTIFY_STATUS_OK { watchToken = token }
    }

    // MARK: Writing (on `queue`)

    private func write(date: Date, scope: String, text: String) {
        let (dayName, stamp) = Self.stamp(date)
        if dayName != day {
            closeFile()
            day = dayName
            full = false
            openFile()
        }
        guard fd >= 0, !full else { return }
        let head = "\(stamp) \(process)[\(pid)] "
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        var out = head + scope + ": " + (lines.first.map(String.init) ?? "") + "\n"
        for line in lines.dropFirst() { out += "    | " + line + "\n" }
        var st = stat()
        if fstat(fd, &st) == 0, Int(st.st_size) + out.utf8.count > limit {
            full = true
            out = head + "log: The log reached its size limit for today. Nothing more is written to it until tomorrow.\n"
        }
        // One write per line: appends from both processes never interleave.
        _ = out.utf8CString.withUnsafeBufferPointer { b in Darwin.write(fd, b.baseAddress, b.count - 1) }
    }

    private func openFile() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            unified.error("cannot make \(self.directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        let path = directory.appendingPathComponent("monad_\(day).log").path
        fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd < 0 { unified.error("cannot open \(path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)") }
    }

    private func closeFile() {
        if fd >= 0 { close(fd) }
        fd = -1
        day = ""
    }

    /// Files of days before the last `keepDays` go; other files stay.
    private func removeOldDays() {
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.keepDays, to: calendar.startOfDay(for: now())),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            guard let match = name.wholeMatch(of: #/monad_(\d{4})-(\d{2})-(\d{2})\.log/#),
                  let date = calendar.date(from: DateComponents(year: Int(match.1), month: Int(match.2), day: Int(match.3))),
                  date < cutoff else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// "2026-10-04" and "2026-10-04 10:12:33.250", local time.
    static func stamp(_ date: Date) -> (day: String, stamp: String) {
        let t = date.timeIntervalSince1970
        var seconds = time_t(t.rounded(.down))
        let ms = min(999, Int(((t - t.rounded(.down)) * 1000).rounded()))
        var parts = tm()
        localtime_r(&seconds, &parts)
        let day = String(format: "%04d-%02d-%02d", parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday)
        return (day, day + String(format: " %02d:%02d:%02d.%03d", parts.tm_hour, parts.tm_min, parts.tm_sec, ms))
    }

    /// "1 folder", "2 folders".
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// At most `limit` bytes of `text`, saying how much was left out.
    static func cut(_ text: String, limit: Int = 4_000) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > limit else { return text }
        return String(decoding: bytes.prefix(limit), as: UTF8.self) + "… (\(bytes.count - limit) more bytes not logged)"
    }

    /// A process's output, each line marked with its stream.
    static func output(_ r: ProcessRunner.Result) -> String {
        var out = ""
        for (name, data) in [("stdout", r.stdout), ("stderr", r.stderr)] where !data.isEmpty {
            for line in cut(String(decoding: data, as: UTF8.self)).split(separator: "\n") {
                out += "\n\(name): \(line)"
            }
        }
        return out
    }

    /// Seconds since `start`, "0.84 s".
    static func elapsed(since start: ContinuousClock.Instant) -> String {
        let d = ContinuousClock.now - start
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return String(format: "%.2f s", seconds)
    }
}

/// Runs helper processes through `inner` and logs each one (Settings › Logs):
/// what was run, how it ended, and what it said.
struct LoggingCommandRunner: CommandRunning {
    let inner: CommandRunning
    let log: DebugLog
    private let counter = OSAllocatedUnfairLock(initialState: 0)

    init(_ inner: CommandRunning, log: DebugLog = .shared) {
        self.inner = inner
        self.log = log
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval) async throws
        -> ProcessRunner.Result {
        guard log.isEnabled else { return try await inner.run(executable, arguments, stdin: stdin, timeout: timeout) }
        let id = begin(executable, arguments, stdin: stdin, timeout: timeout)
        let start = ContinuousClock.now
        do {
            let r = try await inner.run(executable, arguments, stdin: stdin, timeout: timeout)
            log.log("cmd", "#\(id) exit \(r.status) after \(DebugLog.elapsed(since: start))" + DebugLog.output(r))
            return r
        } catch {
            log.log("cmd", "#\(id) failed after \(DebugLog.elapsed(since: start)): \(error.localizedDescription)")
            throw error
        }
    }

    func stream(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval,
                onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessRunner.Result {
        guard log.isEnabled else {
            return try await inner.stream(executable, arguments, stdin: stdin, timeout: timeout, onLine: onLine)
        }
        let id = begin(executable, arguments, stdin: stdin, timeout: timeout)
        let start = ContinuousClock.now
        let lines = OSAllocatedUnfairLock(initialState: 0)
        do {
            let r = try await inner.stream(executable, arguments, stdin: stdin, timeout: timeout) { line in
                lines.withLock { $0 += 1 }
                onLine(line)
            }
            log.log("cmd", "#\(id) exit \(r.status) after \(DebugLog.elapsed(since: start)), "
                    + "\(DebugLog.count(lines.withLock { $0 }, "line")) of output streamed")
            return r
        } catch {
            log.log("cmd", "#\(id) failed after \(DebugLog.elapsed(since: start)): \(error.localizedDescription)")
            throw error
        }
    }

    private func begin(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval) -> Int {
        let id = counter.withLock { n -> Int in
            n += 1
            return n
        }
        let input = stdin.map { "stdin \($0.count) bytes" } ?? "no stdin"
        let limit = timeout == timeout.rounded() ? "\(Int(timeout)) s" : String(format: "%.1f s", timeout)
        log.log("cmd", "#\(id) \(([executable] + arguments).map(Self.quoted).joined(separator: " ")) (\(input), timeout \(limit))")
        return id
    }

    /// As a shell would need it, long ones cut.
    private static func quoted(_ arg: String) -> String {
        let shown = arg.count > 300 ? String(arg.prefix(300)) + "…(\(arg.count) characters)" : arg
        let safe = !shown.isEmpty && shown.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_@%+=:,./-".contains($0)) }
        return safe ? shown : "'" + shown.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
