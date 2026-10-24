//
//  PTYSessionTests.swift — real child processes on a PTY feeding a model.
//

import XCTest
@testable import Monad

final class PTYSessionTests: XCTestCase {
    private let env = ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]

    private func screenText(_ m: TerminalModel) -> String {
        let text = m.copyText(from: mnd_pos(col: 0, line: mnd_vt_view_to_abs(m.vt, 0)),
                              to: mnd_pos(col: Int32(m.size.cols - 1),
                                          line: mnd_vt_view_to_abs(m.vt, Int32(m.size.rows - 1))),
                              block: false)
        return text ?? ""
    }

    func testOutputReachesModelAndExitIsReported() throws {
        let model = try XCTUnwrap(TerminalModel(cols: 80, rows: 10, scrollback: 0))
        let session = PTYSession(model: model)
        let exited = expectation(description: "exit")
        var status: Int32 = -1
        session.onExit = { s in
            status = s
            exited.fulfill()
        }
        try session.start(.init(executable: "/bin/sh",
                                arguments: ["sh", "-c", "stty size; printf 'from-pty\\n'; exit 3"],
                                environment: env, directory: "/"),
                          cols: 80, rows: 10)
        wait(for: [exited], timeout: 10)
        XCTAssertEqual((status >> 8) & 0xff, 3)
        let text = screenText(model)
        XCTAssertTrue(text.contains("10 80"), text)
        XCTAssertTrue(text.contains("from-pty"), text)
    }

    /// Regression: a child that exits before the exit watcher is installed
    /// must still be reported (and reaped).
    func testInstantExitsAreAlwaysReported() throws {
        var sessions: [PTYSession] = []
        var exps: [XCTestExpectation] = []
        for i in 0..<40 {
            let model = try XCTUnwrap(TerminalModel(cols: 20, rows: 5, scrollback: 0))
            let session = PTYSession(model: model)
            let exp = expectation(description: "exit \(i)")
            session.onExit = { _ in exp.fulfill() }
            try session.start(.init(executable: "/usr/bin/true", arguments: ["true"], environment: env, directory: nil),
                              cols: 20, rows: 5)
            sessions.append(session)
            exps.append(exp)
        }
        wait(for: exps, timeout: 15)
        _ = sessions
    }

    func testAChildReapedElsewhereStillEndsTheSession() throws {
        // Something else in the process waits for the child first (the race
        // is real: whoever calls waitpid first gets the status).
        let model = try XCTUnwrap(TerminalModel(cols: 20, rows: 5, scrollback: 0))
        let session = PTYSession(model: model)
        let exited = expectation(description: "exit reported")
        session.onExit = { _ in exited.fulfill() }
        try session.start(.init(executable: "/bin/sleep", arguments: ["sleep", "30"], environment: env, directory: nil),
                          cols: 20, rows: 5)
        let pid = session.pid
        kill(pid, SIGKILL)
        var st: Int32 = 0
        _ = waitpid(pid, &st, 0)
        wait(for: [exited], timeout: 10)
        XCTAssertFalse(session.isRunning, "never signal a pid that may now belong to another process")
    }

    func testInputIsWrittenToChild() throws {
        let model = try XCTUnwrap(TerminalModel(cols: 80, rows: 10, scrollback: 0))
        let session = PTYSession(model: model)
        let exited = expectation(description: "exit")
        session.onExit = { _ in exited.fulfill() }
        try session.start(.init(executable: "/bin/sh",
                                arguments: ["sh", "-c", "read line; echo \"got:$line\""],
                                environment: env, directory: nil),
                          cols: 80, rows: 10)
        session.write("ping\r")
        wait(for: [exited], timeout: 10)
        XCTAssertTrue(screenText(model).contains("got:ping"))
    }

    func testTerminateHangsUpTheChild() throws {
        let model = try XCTUnwrap(TerminalModel(cols: 80, rows: 10, scrollback: 0))
        let session = PTYSession(model: model)
        let exited = expectation(description: "exit")
        var status: Int32 = 0
        session.onExit = { s in
            status = s
            exited.fulfill()
        }
        try session.start(.init(executable: "/bin/sleep", arguments: ["sleep", "60"], environment: env, directory: nil),
                          cols: 80, rows: 10)
        XCTAssertTrue(session.isRunning)
        session.terminate()
        wait(for: [exited], timeout: 10)
        XCTAssertEqual(status & 0x7f, SIGHUP, "child should die from SIGHUP")
    }

    func testStartFailureIsReported() throws {
        let model = try XCTUnwrap(TerminalModel(cols: 80, rows: 10, scrollback: 0))
        let session = PTYSession(model: model)
        XCTAssertThrowsError(try session.start(.init(executable: "/nonexistent/tool", arguments: ["tool"],
                                                     environment: env, directory: nil),
                                               cols: 80, rows: 10))
    }
}
