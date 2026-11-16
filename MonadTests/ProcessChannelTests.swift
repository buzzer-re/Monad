//
//  ProcessChannelTests.swift — a program run with one stream for its input
//  and its output (an SSH host's agent, through ssh): what is written
//  reaches it, what it prints comes back, and closing the channel ends it
//  and leaves no process behind.
//

import XCTest
@testable import Monad

@MainActor
final class ProcessChannelTests: XCTestCase {
    private func readAll(_ fd: Int32) -> String {
        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out += buf[0..<n]
        }
        return String(decoding: out, as: UTF8.self)
    }

    func testAProgramsInputAndOutputAreOneStream() throws {
        let channel = try ProcessChannelSpawner().open("/bin/cat", [], environment: [:])
        defer { channel.close() }
        let fd = channel.fileDescriptor
        XCTAssertEqual("ping\n".withCString { write(fd, $0, 5) }, 5)
        var buf = [UInt8](repeating: 0, count: 16)
        let n = read(fd, &buf, buf.count)
        XCTAssertEqual(String(decoding: buf[0..<max(n, 0)], as: UTF8.self), "ping\n")
    }

    func testTheProgramGetsTheVariablesGivenAndItsEndIsSeen() throws {
        let channel = try ProcessChannelSpawner().open("/usr/bin/env", [], environment: ["MONAD_TEST": "x"])
        defer { channel.close() }
        let printed = readAll(channel.fileDescriptor)
        XCTAssertTrue(printed.contains("MONAD_TEST=x\n"), printed)
        XCTAssertTrue(printed.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin\n"), "the helpers' environment, no more")
    }

    func testClosingTheChannelEndsTheProgramAndLeavesNoProcess() async throws {
        let channel = try XCTUnwrap(try ProcessChannelSpawner().open("/bin/sleep", ["600"], environment: [:]) as? ProcessChannel)
        let pid = channel.pid
        XCTAssertEqual(kill(pid, 0), 0)
        channel.close()
        channel.close()
        // Reaped too: a zombie would still answer.
        let gone = await eventually { kill(pid, 0) != 0 }
        XCTAssertTrue(gone)
    }

    func testAProgramThatEndsByItselfIsReaped() async throws {
        let channel = try XCTUnwrap(try ProcessChannelSpawner().open("/usr/bin/true", [], environment: [:]) as? ProcessChannel)
        let pid = channel.pid
        let gone = await eventually { kill(pid, 0) != 0 }
        XCTAssertTrue(gone)
        channel.close()
    }

    func testAProgramThatCannotRunThrows() {
        XCTAssertThrowsError(try ProcessChannelSpawner().open("/nonexistent/program", [], environment: [:]))
    }
}
