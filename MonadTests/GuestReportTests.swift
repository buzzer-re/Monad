//
//  GuestReportTests.swift — what a guest says about Monad's setup on its
//  console (Guest/monad-report.sh, "MONAD| " lines), read from the serial
//  log: only this boot's, only the report's, as plain bounded text.
//

import XCTest
@testable import Monad

final class GuestReportTests: XCTestCase {
    func testOnlyTheReportsLinesAreRead() {
        var report = GuestReport()
        let console = "[    1.0] kernel says hi\r\nMONAD| selinux: enforcing\r\nmonad-x login: \r\n"
            + "\u{1B}[0mMONAD| vsock: yes\r\nMONAD| sshd: cut "
        XCTAssertEqual(report.read(Data(console.utf8)), ["selinux: enforcing", "vsock: yes"])
        XCTAssertEqual(report.read(Data("in two\r\n".utf8)), ["sshd: cut in two"], "a line cut by a read ends with the next")
        XCTAssertEqual(report.lines, ["selinux: enforcing", "vsock: yes", "sshd: cut in two"])
    }

    /// The serial log outlives boots: a boot reads only what came after it
    /// started, and starts over when the log is rotated.
    func testOnlyThisBootsLinesAreRead() throws {
        let tmp = TempDir()
        let log = tmp.url.appendingPathComponent("serial.log")
        try Data("MONAD| from the last boot\n".utf8).write(to: log)
        var report = GuestReport.starting(at: log)
        XCTAssertEqual(report.newLines(in: log), [])
        try append("noise\nMONAD| vsock: yes\n", to: log)
        XCTAssertEqual(report.newLines(in: log), ["vsock: yes"])
        XCTAssertEqual(report.newLines(in: log), [])
        try Data("MONAD| after rotation\n".utf8).write(to: log)
        XCTAssertEqual(report.newLines(in: log), ["after rotation"])
        XCTAssertEqual(GuestReport.starting(at: tmp.url.appendingPathComponent("none")).lines, [])
    }

    /// The guest is not trusted: control characters go, lines are cut,
    /// a line without an end is not kept growing, and only the last lines
    /// are kept.
    func testWhatTheGuestSaysIsPlainAndBounded() {
        var report = GuestReport()
        XCTAssertEqual(report.read(Data("MONAD| a\u{1B}]52;c;aGk=\u{07}b\n".utf8)), ["a]52;c;aGk=b"])
        let long = "MONAD| " + String(repeating: "x", count: 5000) + "\n"
        XCTAssertEqual(report.read(Data(long.utf8)).first?.count, GuestReport.maxLine)
        _ = report.read(Data(("MONAD| " + String(repeating: "y", count: 100_000)).utf8))
        XCTAssertEqual(report.read(Data("\nMONAD| next\n".utf8)), ["next"], "an endless line is dropped")
        for i in 0..<200 { _ = report.read(Data("MONAD| line \(i)\n".utf8)) }
        XCTAssertEqual(report.lines.count, GuestReport.maxKept)
        XCTAssertEqual(report.lines.last, "line 199")
        XCTAssertEqual(report.read(Data([0x4D, 0x4F, 0x4E, 0x41, 0x44, 0x7C, 0x20, 0xFF, 0xFE, 0x0A])), ["\u{FFFD}\u{FFFD}"])
    }

    private func append(_ text: String, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
    }
}
