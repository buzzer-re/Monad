//
//  VMLogTests.swift — each VM's own log (vm.log in its folder): what Monad
//  did with it and what it answered, always on, private, bounded, read
//  back for the VM's Log page.
//

import XCTest
@testable import Monad

final class VMLogTests: XCTestCase {
    private var tmp: TempDir!
    private var url: URL { tmp.url.appendingPathComponent("vm.log") }

    override func setUp() {
        tmp = TempDir()
    }

    private func text(_ u: URL? = nil) -> String {
        (try? String(contentsOf: u ?? url, encoding: .utf8)) ?? ""
    }

    /// Each line says when; a message of several lines stays together.
    func testLinesAreStampedAndKeptPrivate() throws {
        let log = VMLog(url: url, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        log.log("state stopped → starting")
        log.log("shares: the guest answered status 0\nstdout: shares-ok")
        log.flush()
        let lines = text().split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, text())
        XCTAssertNotNil(lines[0].range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} state stopped → starting$"#,
                                       options: .regularExpression), lines[0])
        XCTAssertTrue(lines[1].hasSuffix(" shares: the guest answered status 0"), lines[1])
        XCTAssertEqual(lines[2], "    | stdout: shares-ok")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    /// Past its limit the log starts again; the one before is kept.
    func testTheLogIsBounded() throws {
        let log = VMLog(url: url, limit: 400)
        for i in 0..<40 { log.log("line \(i) of the boot") }
        log.flush()
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(size, 400)
        XCTAssertTrue(text().contains("line 39 of the boot"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: VMLog.previous(of: url).path))
    }

    /// The Log page shows the latest part: the one before first, whole
    /// lines only, at most so much.
    func testTheLatestPartIsReadForTheLogPage() {
        let log = VMLog(url: url, limit: 400)
        for i in 0..<40 { log.log("line \(i)") }
        log.flush()
        let all = VMLog.read(url)
        XCTAssertTrue(all.contains("line 39"))
        XCTAssertLessThan(all.range(of: "line 3")!.lowerBound, all.range(of: "line 39")!.lowerBound, "oldest first")
        let tail = VMLog.read(url, maxBytes: 100)
        XCTAssertLessThanOrEqual(tail.utf8.count, 100)
        XCTAssertTrue(tail.hasSuffix("line 39\n"), tail)
        XCTAssertTrue(tail.first?.isNumber ?? false, "starts at a whole line: \(tail)")
        XCTAssertNil(tail.split(separator: "\n").first { !$0.contains("line ") }, tail)
        XCTAssertEqual(VMLog.read(tmp.url.appendingPathComponent("none.log")), "")
    }
}

/// The VM's Log page: the latest part of its log, read again only when the
/// file changed (it is looked at once a second while the page shows).
@MainActor
final class VMLogPageModelTests: XCTestCase {
    func testThePageFollowsTheLog() throws {
        let tmp = TempDir()
        let url = tmp.url.appendingPathComponent("vm.log")
        let model = VMLogPageModel(url: url)
        XCTAssertFalse(model.refresh(), "no log yet")
        XCTAssertEqual(model.text, "")
        let log = VMLog(url: url)
        log.log("state stopped → starting")
        log.flush()
        XCTAssertTrue(model.refresh())
        XCTAssertTrue(model.text.hasSuffix("state stopped → starting\n"), model.text)
        XCTAssertFalse(model.refresh(), "unchanged: not read again")
        log.log("state booting → ready")
        log.flush()
        XCTAssertTrue(model.refresh())
        XCTAssertTrue(model.text.contains("state booting → ready"), model.text)
    }
}
