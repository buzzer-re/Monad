//
//  DebugLogTests.swift — Settings › Logs: when on, the app and MonadHost
//  write what they do to ~/.monad/logs/monad_<date>.log, one file per day
//  shared by both, private, bounded, old days removed. Helper processes are
//  logged with what they were asked and what they answered.
//

import XCTest
@testable import Monad

final class DebugLogTests: XCTestCase {
    private var tmp: TempDir!
    private var logs: URL { tmp.url.appendingPathComponent("logs") }
    private var settings: URL { tmp.url.appendingPathComponent("logging.json") }
    /// 2026-10-04 10:12:33.250, local time.
    private let morning: Date = {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second, c.nanosecond) = (2026, 10, 4, 10, 12, 33, 250_000_000)
        return Calendar.current.date(from: c)!
    }()

    override func setUp() {
        tmp = TempDir()
    }

    private func makeLog(process: String = "unit", now: @escaping @Sendable () -> Date, limit: Int = 1 << 20) -> DebugLog {
        DebugLog(process: process, directory: logs, settings: settings, now: now, limit: limit)
    }

    private func text(_ name: String = "monad_2026-10-04.log") -> String {
        (try? String(contentsOf: logs.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    func testOffWritesNothing() {
        let morning = self.morning
        let log = makeLog { morning }
        XCTAssertFalse(log.isEnabled, "off until turned on in Settings")
        log.log("vm a", "state ready")
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: logs.path))
    }

    func testOnWritesTheDaysFileWithTimeProcessAndScope() throws {
        let morning = self.morning
        let log = makeLog { morning }
        log.setEnabled(true)
        log.log("vm a", "state ready")
        log.log("vm a", "two\nlines")
        log.flush()
        let lines = text().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(lines, ["2026-10-04 10:12:33.250 unit[\(pid)] log: debug logging turned on",
                               "2026-10-04 10:12:33.250 unit[\(pid)] vm a: state ready",
                               "2026-10-04 10:12:33.250 unit[\(pid)] vm a: two",
                               "    | lines", ""])
        let file = logs.appendingPathComponent("monad_2026-10-04.log")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: logs.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(log.currentFile, file)
    }

    func testTurningItOffIsSaid() {
        let morning = self.morning
        let log = makeLog { morning }
        log.setEnabled(true)
        log.setEnabled(false)
        log.log("x", "not written")
        log.flush()
        XCTAssertTrue(text().hasSuffix("log: debug logging turned off\n"), text())
    }

    func testANewDayStartsANewFile() {
        let clock = Clock(morning)
        let log = makeLog { clock.now }
        log.setEnabled(true)
        log.log("x", "today")
        clock.now = morning.addingTimeInterval(86_400)
        log.log("x", "tomorrow")
        log.flush()
        XCTAssertTrue(text().contains("x: today"))
        XCTAssertFalse(text().contains("tomorrow"))
        XCTAssertTrue(text("monad_2026-10-05.log").contains("x: tomorrow"))
    }

    /// The app and MonadHost write the same file, whole lines each.
    func testTwoProcessesShareTheDaysFile() {
        let morning = self.morning
        let app = makeLog(process: "Monad") { morning }, host = makeLog(process: "MonadHost") { morning }
        app.setEnabled(true)
        host.setEnabled(true)
        for i in 0..<200 {
            app.log("client", "request \(i)")
            host.log("host", "answer \(i)")
        }
        app.flush()
        host.flush()
        let lines = text().split(separator: "\n").filter { !$0.hasSuffix(" log: debug logging turned on") }
        XCTAssertEqual(lines.count, 400)
        XCTAssertEqual(lines.filter { $0.contains(" Monad[") && $0.contains(" client: request ") }.count, 200)
        XCTAssertEqual(lines.filter { $0.contains(" MonadHost[") && $0.contains(" host: answer ") }.count, 200)
    }

    func testADaysFileIsBounded() {
        let morning = self.morning
        let log = makeLog(now: { morning }, limit: 2_000)
        log.setEnabled(true)
        for i in 0..<200 { log.log("x", "line \(i) " + String(repeating: "y", count: 40)) }
        log.flush()
        let t = text()
        XCTAssertLessThan(t.utf8.count, 2_000 + 200)
        XCTAssertEqual(t.components(separatedBy: "The log reached its size limit for today").count, 2, "said once")
    }

    func testOldDaysAreRemovedWhenLoggingStarts() throws {
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        for name in ["monad_2026-09-01.log", "monad_2026-09-25.log", "notes.txt"] {
            FileManager.default.createFile(atPath: logs.appendingPathComponent(name).path, contents: Data())
        }
        let morning = self.morning
        let log = makeLog { morning }
        log.setEnabled(true)
        log.flush()
        let left = try FileManager.default.contentsOfDirectory(atPath: logs.path).sorted()
        XCTAssertEqual(left, ["monad_2026-09-25.log", "monad_2026-10-04.log", "notes.txt"],
                       "14 days are kept, other files are left alone")
    }

    // MARK: The setting

    /// Settings › Logs saves the switch where both processes read it, and
    /// tells them at once.
    func testTheSwitchIsSharedThroughAFileAndANotification() throws {
        let morning = self.morning
        let host = makeLog(process: "MonadHost") { morning }
        let name = "dev.monad.test.logging.\(UUID().uuidString)"
        host.watchSettings(notification: name)
        XCTAssertFalse(host.isEnabled)
        try DebugLog.save(enabled: true, settings: settings, notification: name)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? Int, 0o600)
        let on = expectation(description: "turned on")
        DispatchQueue.global().async {
            for _ in 0..<200 where !host.isEnabled { usleep(10_000) }
            on.fulfill()
        }
        wait(for: [on], timeout: 5)
        XCTAssertTrue(host.isEnabled)
        XCTAssertTrue(DebugLog.load(settings: settings))
        try DebugLog.save(enabled: false, settings: settings, notification: name)
        host.reloadSettings()
        XCTAssertFalse(host.isEnabled)
        // A process starting later reads it from the file.
        try DebugLog.save(enabled: true, settings: settings, notification: name)
        let later = makeLog(process: "Monad") { morning }
        later.reloadSettings()
        XCTAssertTrue(later.isEnabled)
    }

    // MARK: Helper processes

    func testCommandsAreLoggedWithWhatTheyAnswered() async throws {
        let morning = self.morning
        let log = makeLog { morning }
        log.setEnabled(true)
        let inner = FakeCommandRunner { call in
            if call.arguments.last == "boom" { throw MonadError("no such program") }
            return .init(status: 1, stdout: Data("shares-failed: /mnt/a\n".utf8),
                         stderr: Data(("mount: /mnt/a: special device does not exist.\n" + String(repeating: "z", count: 9_000)).utf8))
        }
        let runner = LoggingCommandRunner(inner, log: log)
        let r = try await runner.run("/usr/bin/ssh", ["-F", "/x y/ssh.config", "monad-a", "sudo -n sh -s -- monad-shares"],
                                     stdin: Data(count: 1_500), timeout: 60)
        XCTAssertEqual(r.status, 1, "answers pass through unchanged")
        do {
            _ = try await runner.run("/usr/bin/ssh", ["boom"], stdin: nil, timeout: 5)
            XCTFail("the error passes through")
        } catch {}
        log.flush()
        let t = text()
        XCTAssertTrue(t.contains("cmd: #1 /usr/bin/ssh -F '/x y/ssh.config' monad-a 'sudo -n sh -s -- monad-shares' "
                                 + "(stdin 1500 bytes, timeout 60 s)"), t)
        XCTAssertTrue(t.range(of: #"cmd: #1 exit 1 after \d+\.\d\d s"#, options: .regularExpression) != nil, t)
        XCTAssertTrue(t.contains("    | stdout: shares-failed: /mnt/a"), t)
        XCTAssertTrue(t.contains("    | stderr: mount: /mnt/a: special device does not exist."), t)
        XCTAssertTrue(t.contains("more bytes not logged)"), "long output is cut: \(t.suffix(300))")
        XCTAssertTrue(t.contains("cmd: #2 failed after"), t)
        XCTAssertTrue(t.contains("no such program"), t)
    }

    func testNothingIsFormattedWhileOff() async throws {
        let morning = self.morning
        let log = makeLog { morning }
        var formatted = false
        log.log("x", { formatted = true; return "expensive" }())
        XCTAssertFalse(formatted)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ d: Date) { value = d }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
