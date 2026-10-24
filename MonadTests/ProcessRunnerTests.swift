//
//  ProcessRunnerTests.swift — helper processes (ssh, ssh-keygen, lsof,
//  launchctl) never leave anything behind: bounded output, the whole process
//  group killed on timeout, no waiting on background children.
//

import os
import XCTest
@testable import Monad

final class ProcessRunnerTests: XCTestCase {
    private var tmp: TempDir!

    override func setUp() { tmp = TempDir() }

    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    func testOutputAndStdin() throws {
        let r = try ProcessRunner.runSync("/bin/cat", [], stdin: Data("hello".utf8), timeout: 10)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.stdoutString, "hello")
        XCTAssertFalse(r.outputTruncated)
        let e = try ProcessRunner.runSync("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], timeout: 10)
        XCTAssertEqual(e.status, 3)
        XCTAssertEqual(e.stdoutString, "out\n")
        XCTAssertEqual(e.stderrString, "err\n")
    }

    /// Output reaches the caller while the process still runs (profiles show
    /// their progress live), split into lines, stdout and stderr alike.
    func testOutputIsStreamedAsItComes() async throws {
        let seen = OSAllocatedUnfairLock(initialState: [(String, Date)]())
        let started = Date()
        let r = try await SystemCommandRunner().stream("/bin/sh", ["-c", "echo one; echo oops >&2; sleep 1; printf 'two\\nthree'"],
                                                       stdin: nil, timeout: 10) { line in
            seen.withLock { $0.append((line, Date())) }
        }
        XCTAssertEqual(r.status, 0)
        let lines = seen.withLock { $0 }
        XCTAssertEqual(Set(lines.map(\.0)), ["one", "oops", "two", "three"])
        let one = try XCTUnwrap(lines.first { $0.0 == "one" })
        XCTAssertLessThan(one.1.timeIntervalSince(started), 0.8, "before the process ended")
        XCTAssertEqual(lines.last?.0, "three", "an unfinished last line still comes")
    }

    func testTheDefaultStreamFeedsTheOutputAfterwards() async throws {
        let fake = FakeCommandRunner { _ in .ok("a\nb\n") }
        let seen = OSAllocatedUnfairLock(initialState: [String]())
        _ = try await fake.stream("/bin/x", [], stdin: nil, timeout: 1) { line in seen.withLock { $0.append(line) } }
        XCTAssertEqual(seen.withLock { $0 }, ["a", "b"])
    }

    func testLinesAreSplitAcrossChunksAndBounded() {
        var s = LineSplitter(maxLine: 8)
        var out: [String] = []
        s.feed(Data("ab".utf8)) { out.append($0) }
        s.feed(Data("c\nde\r\nf".utf8)) { out.append($0) }
        s.feed(Data((String(repeating: "x", count: 20) + "\n").utf8)) { out.append($0) }
        s.finish { out.append($0) }
        // A line longer than the bound is cut, the rest of it dropped.
        XCTAssertEqual(out, ["abc", "de", "fxxxxxxx"])
        var t = LineSplitter(maxLine: 8)
        out = []
        t.feed(Data("tail".utf8)) { out.append($0) }
        t.finish { out.append($0) }
        XCTAssertEqual(out, ["tail"])
    }

    func testOutputIsCapped() throws {
        let start = Date()
        let r = try ProcessRunner.runSync("/bin/sh", ["-c", "head -c 20000000 /dev/zero; echo done >&2"], timeout: 30)
        XCTAssertEqual(r.status, 0, "the rest is read and dropped, so the writer is never stuck")
        XCTAssertEqual(r.stdout.count, ProcessRunner.outputLimit)
        XCTAssertTrue(r.outputTruncated)
        XCTAssertEqual(r.stderrString, "done\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testTimeoutKillsTheWholeProcessGroup() throws {
        let pids = tmp.url.appendingPathComponent("pids")
        let start = Date()
        // The shell ignores SIGTERM; its child is a separate process.
        XCTAssertThrowsError(try ProcessRunner.runSync("/bin/sh", ["-c",
            "trap '' TERM; sleep 30 & echo $$ $! > '\(pids.path)'; wait"], timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
        let ids = try String(contentsOf: pids, encoding: .utf8).split(separator: " ")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        XCTAssertEqual(ids.count, 2)
        for pid in ids {
            XCTAssertFalse(alive(pid), "pid \(pid) outlived the timeout")
        }
    }

    func testBackgroundChildrenDoNotHoldUpTheResult() throws {
        let start = Date()
        let r = try ProcessRunner.runSync("/bin/sh", ["-c", "sleep 5 & echo started"], timeout: 30)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.stdoutString, "started\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "the result does not wait for a child holding the pipes")
    }

    func testChildrenGetDefaultSignalHandling() throws {
        // Monad ignores SIGPIPE; helpers must not inherit that.
        let r = try ProcessRunner.runSync("/bin/sh", ["-c", "kill -PIPE $$; echo survived"], timeout: 10)
        XCTAssertEqual(r.stdoutString, "")
        XCTAssertEqual(r.status, 128 + SIGPIPE)
    }

    func testRemovingAFolderToleratesFilesThatVanish() throws {
        let dir = tmp.url.appendingPathComponent("vm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("ctl.sock"))
        try FileManager.default.removeTree(at: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertNoThrow(try FileManager.default.removeTree(at: dir), "already gone is fine")
    }

    func testMissingExecutableIsAnError() {
        XCTAssertThrowsError(try ProcessRunner.runSync("/nonexistent/tool", [], timeout: 5))
    }
}
