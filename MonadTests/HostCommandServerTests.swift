//
//  HostCommandServerTests.swift — MonadHost's side of a host command: the
//  request checked before anything runs, one run at a time with a queue,
//  the output framed with a token, every run in the exchange folder while
//  it goes, the time limit and stopping ending the whole process group.
//  Real sockets and processes, with shell scripts for programs.
//

import XCTest
@testable import Monad

final class HostCommandServerTests: XCTestCase {
    private var dir: URL!
    private var servers: [HostCommandServer] = []
    private var socketPath: String { dir.appendingPathComponent("c.sock").path }
    private var logPath: String { dir.appendingPathComponent("c.log").path }
    private var exchange: URL { dir.appendingPathComponent("exchange") }
    private let guestExchange = "/home/dev/.monad/exchange"

    override func setUpWithError() throws {
        var template = Array("/tmp/mc-XXXXXX".utf8CString)
        let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) }
        dir = URL(fileURLWithPath: String(cString: try XCTUnwrap(made)), isDirectory: true)
        try FileManager.default.createDirectory(at: exchange, withIntermediateDirectories: true)
    }

    override func tearDown() {
        servers.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: dir)
    }

    /// A program: a shell script in the test folder.
    private func script(_ body: String) throws -> String {
        let url = dir.appendingPathComponent("prog-\(servers.count).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func command(_ program: String, results: Bool = true, timeout: Int = 60,
                         environment: [String: String] = [:]) -> HostCommand {
        HostCommand(name: "probe", summary: "A test.", program: program,
                    arguments: [.init(name: "word", pattern: "^[a-z]+$", required: false, summary: "")],
                    workingDirectory: dir.path, timeoutSeconds: timeout, results: results,
                    environment: environment, guestSocket: "/run/monad/probe.sock")
    }

    @discardableResult
    private func serve(_ c: HostCommand, maxQueued: Int = 4,
                       macEnvironment: [String: String] = ["PATH": "/usr/bin:/bin", "HOME": "/tmp", "SECRET": "x"]) throws -> HostCommandServer {
        let s = HostCommandServer(command: c, socket: URL(fileURLWithPath: socketPath), log: URL(fileURLWithPath: logPath),
                                  exchange: exchange, guestExchange: guestExchange, maxQueued: maxQueued,
                                  environment: macEnvironment)
        servers.append(s)
        try s.start()
        return s
    }

    private var log: String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }

    private func runFolders() -> [URL] {
        let runs = exchange.appendingPathComponent("runs")
        return ((try? FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != "latest" }.sorted { $0.path < $1.path }
    }

    private func exitLine(_ text: String) -> [String]? {
        text.split(separator: "\n").last { $0.hasPrefix("monad-exit ") }.map { $0.split(separator: " ").map(String.init) }
    }

    /// A run: the token first, the program's output, then the exit line with
    /// the same token, the status and the run folder in the VM. stdout,
    /// stderr and run.json are in the folder; runs/latest leads to it.
    func testARunIsFramedAndKeptInTheExchangeFolder() throws {
        try serve(command(try script(#"echo "got $*"; echo "in $PWD"; echo "dir $MONAD_RUN_DIR"; echo oops >&2; exit 3"#)))
        let c = try UnixClient(socketPath)
        c.send("run hello\n")
        let out = c.read(until: { $0.contains("monad-exit ") && $0.hasSuffix("\n") })
        let lines = out.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("monad-run "), out)
        let token = String(lines[0].dropFirst("monad-run ".count))
        XCTAssertEqual(token.count, 16)
        XCTAssertTrue(lines.contains("got hello"), out)
        XCTAssertTrue(lines.contains { $0.hasPrefix("in /") && $0.hasSuffix(dir.lastPathComponent) }, "in its working folder: \(out)")
        let folder = exchange.appendingPathComponent("runs/" + (try XCTUnwrap(runFolders().first)).lastPathComponent)
        XCTAssertTrue(folder.lastPathComponent.hasSuffix("-probe"), folder.lastPathComponent)
        XCTAssertTrue(lines.contains("dir \(folder.path)"), "the program writes its own files there: \(out)")
        XCTAssertEqual(exitLine(out), ["monad-exit", token, "3", "\(guestExchange)/runs/\(folder.lastPathComponent)"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("stdout.log"), encoding: .utf8),
                       "got hello\nin \(lines.first { $0.hasPrefix("in ") }!.dropFirst(3))\ndir \(folder.path)\n")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("stderr.log"), encoding: .utf8), "oops\n")
        let run = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("run.json"))) as? [String: Any])
        XCTAssertEqual(run["command"] as? String, "probe")
        XCTAssertEqual(run["arguments"] as? [String], ["hello"])
        XCTAssertEqual(run["status"] as? Int, 3)
        XCTAssertNotNil(run["started"])
        XCTAssertNotNil(run["ended"])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: exchange.appendingPathComponent("runs/latest").path),
                       folder.lastPathComponent)
        XCTAssertTrue(log.contains("run probe hello"), log)
        XCTAssertTrue(log.contains("oops"), "stderr goes to the log too: \(log)")
    }

    /// A request that does not meet the rules is refused before anything
    /// runs, the reason said to the VM and in the log.
    func testARefusedRequestRunsNothing() throws {
        try serve(command(try script("touch ran")))
        for (request, why) in [("run HELLO\n", "word “HELLO” does not match ^[a-z]+$."),
                               ("run 'open\n", "A quote is not closed."),
                               ("rm -rf ~\n", "Say run or describe.")] {
            let c = try UnixClient(socketPath)
            c.send(request)
            XCTAssertEqual(c.read(until: { $0.hasSuffix("\n") }), "monad-refused \(why)\n")
            c.read()
            XCTAssertTrue(c.closed)
            XCTAssertTrue(log.contains("refused: \(why)"), log)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ran").path))
        XCTAssertEqual(runFolders(), [])
    }

    /// A request line that never ends is cut off at its limit.
    func testAnEndlessRequestIsCutOff() throws {
        try serve(command(try script("true")))
        let c = try UnixClient(socketPath)
        c.send(String(repeating: "a", count: HostCommand.maxRequestBytes + 10))
        XCTAssertEqual(c.read(until: { $0.hasSuffix("\n") }), "monad-refused The request is too long.\n")
    }

    func testDescribe() throws {
        try serve(command(try script("true")))
        let c = try UnixClient(socketPath)
        c.send("describe\n")
        let line = c.read(until: { $0.hasSuffix("\n") })
        XCTAssertEqual(line, command("/x").describe + "\n")
    }

    /// One run at a time: the next waits and is told its place; past the
    /// queue's length a request is refused.
    func testOneRunAtATime() throws {
        try serve(command(try script("echo start $1; sleep 0.6; echo end $1")), maxQueued: 1)
        let a = try UnixClient(socketPath)
        a.send("run a\n")
        a.read(until: { $0.contains("start a") })
        let b = try UnixClient(socketPath)
        b.send("run b\n")
        XCTAssertEqual(b.read(until: { $0.hasSuffix("\n") }), "monad-queued 1\n")
        let c = try UnixClient(socketPath)
        c.send("run c\n")
        XCTAssertEqual(c.read(until: { $0.hasSuffix("\n") }), "monad-refused Busy: 1 run is waiting already. Try again later.\n")
        let first = a.read(until: { $0.contains("monad-exit") })
        XCTAssertTrue(first.contains("end a"))
        let second = b.read(until: { $0.contains("monad-exit") }, timeout: 5)
        XCTAssertTrue(second.contains("start b\nend b\n"), second)
    }

    /// The time limit ends the program and everything it started.
    func testTheTimeLimitEndsTheProcessGroup() throws {
        let pidFile = dir.appendingPathComponent("child.pid").path
        try serve(command(try script("sleep 30 & echo $! > \(pidFile); wait"), timeout: 1))
        let c = try UnixClient(socketPath)
        c.send("run\n")
        let started = Date()
        let out = c.read(until: { $0.contains("monad-exit") }, timeout: 6)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertEqual(exitLine(out)?[2], "143", out)
        let child = pid_t(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        XCTAssertNotEqual(kill(child, 0), 0, "the background child is gone too")
        let run = try JSONSerialization.jsonObject(with: Data(contentsOf: runFolders()[0].appendingPathComponent("run.json"))) as? [String: Any]
        XCTAssertEqual(run?["timedOut"] as? Bool, true)
        XCTAssertTrue(log.contains("time limit"), log)
    }

    /// Stopping (the VM stops, the command is removed) ends the run within
    /// a second, and the waiting ones are told.
    func testStoppingEndsTheRun() throws {
        let s = try serve(command(try script("echo up; sleep 30")))
        let a = try UnixClient(socketPath)
        a.send("run\n")
        a.read(until: { $0.contains("up\n") })
        let b = try UnixClient(socketPath)
        b.send("run\n")
        b.read(until: { $0.contains("monad-queued") })
        let started = Date()
        s.stop()
        XCTAssertTrue(a.read(until: { $0.contains("monad-exit") }, timeout: 3).contains("monad-exit"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertTrue(b.read(until: { $0.contains("monad-refused") }).contains("monad-refused The host command stopped."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    /// The run folder is written while the run goes, so the VM can follow it.
    func testTheRunFolderIsWrittenAsItGoes() throws {
        try serve(command(try script("echo first; sleep 1; echo second")))
        let c = try UnixClient(socketPath)
        c.send("run\n")
        c.read(until: { $0.contains("first") })
        let folder = try XCTUnwrap(runFolders().first)
        let soFar = try String(contentsOf: folder.appendingPathComponent("stdout.log"), encoding: .utf8)
        XCTAssertEqual(soFar, "first\n")
        let run = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("run.json"))) as? [String: Any]
        XCTAssertNil(run?["ended"], "running")
        c.read(until: { $0.contains("monad-exit") })
    }

    /// Without results: no folder, "-" in the exit line, no MONAD_RUN_DIR.
    /// Either way the program gets a plain environment plus its own.
    func testWithoutResultsAndTheEnvironment() throws {
        try serve(command(try script(#"echo "dir=${MONAD_RUN_DIR-none} path=$PATH secret=${SECRET-none} home=$HOME extra=$EXTRA""#),
                          results: false, environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "EXTRA": "yes"]))
        let c = try UnixClient(socketPath)
        c.send("run\n")
        let out = c.read(until: { $0.contains("monad-exit") })
        XCTAssertTrue(out.contains("dir=none path=/opt/homebrew/bin:/usr/bin:/bin secret=none home=/tmp extra=yes"), out)
        XCTAssertEqual(exitLine(out)?.last, "-")
        XCTAssertEqual(runFolders(), [])
    }

    /// In-process callers (MCP tools) use the same queue and checks.
    /// A value that takes long to check (a nested repeat) is checked on the
    /// server's queue: the caller's actor (MonadHost's main one, for MCP
    /// calls) is free meanwhile.
    @MainActor
    func testASlowCheckDoesNotHoldTheCaller() async throws {
        var c = command(try script("echo hi"))
        c.arguments = [.init(name: "word", pattern: "^(a+)+$", required: true, summary: "")]
        let s = try serve(c)
        let slow = Task { @MainActor in
            try await s.submitChecking([String(repeating: "a", count: 64) + "!"]) { _ in }
        }
        let asked = Date()
        let tick = Task { @MainActor in Date() }
        let ran = await tick.value
        XCTAssertLessThan(ran.timeIntervalSince(asked), 0.1, "the main actor was not held by the match")
        do {
            try await slow.value
            XCTFail("refused: it took too long to check")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("too long"), error.localizedDescription)
        }
    }

    func testSubmittingInProcess() throws {
        let s = try serve(command(try script("echo hi $1")))
        let events = EventBox()
        let done = expectation(description: "exit")
        try s.submit(["there"]) { e in
            events.add(e)
            if case .exit = e { done.fulfill() }
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(events.output, "hi there\n")
        guard case .exit(let status, let timedOut, let folder)? = events.all.last else { return XCTFail("\(events.all)") }
        XCTAssertEqual(status, 0)
        XCTAssertFalse(timedOut)
        XCTAssertTrue(folder?.hasPrefix("\(guestExchange)/runs/") ?? false)
        XCTAssertThrowsError(try s.submit(["NOPE"]) { _ in })
    }
}

/// Events from a run, collected across queues.
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HostCommandServer.Event] = []
    var all: [HostCommandServer.Event] { lock.withLock { items } }
    func add(_ e: HostCommandServer.Event) { lock.withLock { items.append(e) } }
    var output: String {
        all.reduce(into: "") { s, e in if case .output(let d) = e { s += String(decoding: d, as: UTF8.self) } }
    }
}
