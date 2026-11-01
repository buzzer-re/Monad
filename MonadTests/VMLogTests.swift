//
//  VMLogTests.swift — each VM's own log (vm.log in its folder): what Monad
//  did with it and what it answered, always on, private, bounded, read
//  back for the VM's Log page.
//

import SwiftUI
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

    /// What was added is read, and the text is what the whole log would
    /// read: after it grew, after it was rotated, and once past the trim.
    func testOnlyWhatWasAddedIsReadAndTheTextStaysTheLog() throws {
        let tmp = TempDir()
        let url = tmp.url.appendingPathComponent("vm.log")
        let model = VMLogPageModel(url: url)
        try Data("one\n".utf8).write(to: url)
        XCTAssertTrue(model.refresh())
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("two\n".utf8))
        try h.close()
        XCTAssertTrue(model.refresh())
        XCTAssertEqual(model.text, "one\ntwo\n")
        // Rotated (VMLog renames it to vm.log.1 and starts a new one).
        try FileManager.default.moveItem(at: url, to: VMLog.previous(of: url))
        try Data("three\n".utf8).write(to: url)
        XCTAssertTrue(model.refresh())
        XCTAssertEqual(model.text, VMLog.read(url))
        XCTAssertEqual(model.text, "one\ntwo\nthree\n")
        // Grown past the trim: the last 512 KB, from a line start.
        let line = String(repeating: "x", count: 99) + "\n"
        let big = try FileHandle(forWritingTo: url)
        try big.seekToEnd()
        try big.write(contentsOf: Data(String(repeating: line, count: (VMLogPageModel.trimAt / 100) + 10).utf8))
        try big.close()
        XCTAssertTrue(model.refresh())
        XCTAssertLessThanOrEqual(model.text.utf8.count, 512 << 10)
        XCTAssertTrue(model.text.hasPrefix(line), "from a line start")
    }

    /// A VM in trouble writes to its log about once a second (ssh retries,
    /// the agent coming and going) and the page shows it as it comes: each
    /// change must cost the window little, or the VM's window stops
    /// answering (reported with a VM whose kernel crashed). Measured with a
    /// log at the size the page reads (512 KB).
    func testAFullLogCostsTheWindowLittleEachTimeItGrows() throws {
        let tmp = TempDir()
        let url = tmp.url.appendingPathComponent("vm.log")
        let line = "2026-11-01 19:37:22 ssh: could not connect (try 3 of 5), trying again in 4 s, and some more words\n"
        try Data(String(repeating: line, count: (512 << 10) / line.utf8.count).utf8).write(to: url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: VMLogPage(url: url))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.display()
        // What a second costs with the page open and nothing new.
        func quietSecond() -> TimeInterval {
            let cpu = processCPUSeconds()
            RunLoop.main.run(until: Date().addingTimeInterval(1.1))
            host.layoutSubtreeIfNeeded()
            host.display()
            return processCPUSeconds() - cpu
        }
        let quiet = quietSecond()
        var worst: TimeInterval = 0
        for i in 0..<3 {
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            try h.write(contentsOf: Data("2026-11-01 19:38:0\(i) agent: disconnected after 15.8 s\n".utf8))
            try h.close()
            // The page looks once a second; what it does then is CPU spent.
            let cpu = processCPUSeconds()
            RunLoop.main.run(until: Date().addingTimeInterval(1.1))
            host.layoutSubtreeIfNeeded()
            host.display()
            worst = max(worst, processCPUSeconds() - cpu)
        }
        XCTAssertLessThan(worst - quiet, 0.05, "\(worst) s of CPU for one new line (\(quiet) s for a second with none)")
    }
}
