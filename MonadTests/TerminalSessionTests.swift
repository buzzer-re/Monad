//
//  TerminalSessionTests.swift — a VM tab following its VM through its whole
//  life (provisioning, boot, ready, shutdown) stays idle whenever nothing
//  happens. Regression test for app copies that spun at ~95% CPU with a tab
//  stuck in the VM-state subscription (2026-09-29).
//

import AppKit
import XCTest
@testable import Monad

@MainActor
final class TerminalSessionTests: XCTestCase {
    private func assertIdle(_ what: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = processCPUSeconds()
        try await Task.sleep(nanoseconds: 500_000_000)
        let used = processCPUSeconds() - before
        XCTAssertLessThan(used, 0.2, "\(what): \(used) s of CPU in 0.5 s", file: file, line: line)
    }

    /// VM › Restart VM restarts the focused tab's VM, and the tab connects
    /// again once it is back. Host tabs have no VM to restart.
    func testATabRestartsItsVM() async throws {
        let host = try FakeHost()
        let client = HostClient(connect: { try host.connect() }, clock: TestClock(realDelay: 0.001),
                                instanceRoot: host.fixture.root)
        client.start()
        defer { client.stop() }
        let tab = TerminalSessionViewController(target: .defaultVM, host: client)
        _ = tab.view
        tab.start()
        defer { tab.close() }
        await assertEventually("tab phase \(tab.phase)", timeout: 20) { tab.vm?.state == .ready }
        XCTAssertTrue(tab.canRestartVM)
        let item = NSMenuItem(title: "", action: #selector(TerminalSessionViewController.restartVM(_:)), keyEquivalent: "")
        XCTAssertTrue(tab.validateMenuItem(item))
        XCTAssertEqual(item.title, "Restart VM “default”")

        let starts = host.fixture.factory.machine.started
        tab.restartVM(nil)
        await assertEventually("machine started \(host.fixture.factory.machine.started) times", timeout: 20) {
            host.fixture.factory.machine.started == starts + 1
        }
        await assertEventually("state \(String(describing: tab.vm?.state))", timeout: 20) { tab.vm?.state == .ready }

        let shell = TerminalSessionViewController(target: .host, host: client)
        XCTAssertFalse(shell.canRestartVM)
        XCTAssertFalse(shell.validateMenuItem(item))
        XCTAssertEqual(item.title, "Restart VM")
    }

    /// The directory a shell reports (OSC 7, file://host/path) is where a
    /// split of its pane starts: an absolute path, percent-decoded where it
    /// can be, and nothing a guest could make odd.
    func testTheDirectoryAShellReportsIsReadFromItsURL() {
        typealias T = TerminalSessionViewController
        XCTAssertEqual(T.directory(fromURL: "file://monad-web/home/dev/horizon"), "/home/dev/horizon")
        XCTAssertEqual(T.directory(fromURL: "file:///home/dev/my%20project"), "/home/dev/my project")
        XCTAssertEqual(T.directory(fromURL: "file://web/home/dev/100%"), "/home/dev/100%", "no escape: as written")
        XCTAssertNil(T.directory(fromURL: "http://web/home/dev"))
        XCTAssertNil(T.directory(fromURL: "file://web"))
        XCTAssertNil(T.directory(fromURL: "file://web/home/dev/a%0Ab"), "no control characters")
        XCTAssertNil(T.directory(fromURL: "file://web/" + String(repeating: "a", count: 5000)))
    }

    /// A split's ssh runs a command in a terminal: into that directory (in
    /// the home folder if it is gone), then the user's login shell.
    func testASplitsSSHStartsInItsDirectory() {
        typealias T = TerminalSessionViewController
        XCTAssertEqual(T.sshCommand(options: ["-F", "none"], host: "web", startIn: nil), ["ssh", "-F", "none", "web"])
        XCTAssertEqual(T.sshCommand(options: ["-F", "none"], host: "web", startIn: "/home/dev/it's here"),
                       ["ssh", "-F", "none", "-t", "web", "cd '/home/dev/it'\\''s here' 2>/dev/null; exec \"$SHELL\" -l"])
    }

    /// A title set by a program in the VM (a shell, a code agent) always
    /// comes after the VM's name, so a tab never loses which VM it is on.
    func testTheTitleAlwaysStartsWithTheVM() {
        typealias T = TerminalSessionViewController
        XCTAssertEqual(T.title(name: "box", appTitle: "macos-vm-setup-phase-14", exited: false),
                       "box: macos-vm-setup-phase-14")
        XCTAssertEqual(T.title(name: "box", appTitle: nil, exited: false), "box")
        XCTAssertEqual(T.title(name: "box", appTitle: "  ", exited: false), "box")
        XCTAssertEqual(T.title(name: "box", appTitle: "box", exited: false), "box", "not box: box")
        XCTAssertEqual(T.title(name: "box", appTitle: "box: vim", exited: false), "box: vim", "named already")
        XCTAssertEqual(T.title(name: "box", appTitle: "vim", exited: true), "box: vim — exited")
        XCTAssertEqual(T.title(name: "host", appTitle: "~", exited: false), "host: ~")
    }

    func testFollowingAVMThroughItsLifeStaysIdle() async throws {
        let host = try FakeHost()
        let client = HostClient(connect: { try host.connect() }, clock: TestClock(realDelay: 0.001),
                                instanceRoot: host.fixture.root)
        client.start()
        defer { client.stop() }
        let tab = TerminalSessionViewController(target: .defaultVM, host: client)
        _ = tab.view
        tab.start()
        defer { tab.close() }

        // Provisioned, booted and connected (the ssh it starts fails fast:
        // the fixture VM has no guest behind its socket).
        await assertEventually("tab phase \(tab.phase)", timeout: 20) { tab.vm?.state == .ready }
        await assertEventually("tab phase \(tab.phase)", timeout: 20) { tab.phase != .waiting }
        try await assertIdle("tab after the VM became ready")

        try await client.stop("default")
        await assertEventually { tab.vm?.state == .stopped }
        try await assertIdle("tab after the VM stopped")
    }

    /// ssh failing within seconds of connecting (exit 255), as on a first
    /// boot while the guest still sets sshd up (seen on the Mac with an
    /// imported VM): the tab connects again by itself, a few times, waiting
    /// longer each time, before it asks for Return. A session that held, or
    /// any other end, is not retried.
    func testAQuickSSHFailureIsRetriedByItself() {
        let ssh = Int32(255 << 8)
        func delay(_ attempt: Int, _ status: Int32 = 255 << 8, lasted: TimeInterval = 0.5) -> TimeInterval? {
            TerminalSessionViewController.reconnectDelay(afterAttempt: attempt, status: status, lasted: lasted)
        }
        XCTAssertEqual(delay(0), 1)
        XCTAssertEqual(delay(1), 2)
        XCTAssertEqual(delay(2), 4)
        XCTAssertEqual(delay(3), 8)
        XCTAssertNil(delay(4), "then Return")
        XCTAssertNil(delay(0, ssh, lasted: 60), "a session that held and was lost: Return")
        XCTAssertNil(delay(0, 1 << 8), "the shell's own exit status")
        XCTAssertNil(delay(0, SIGKILL), "killed")
    }

    /// `exit` closes the tab, as Terminal does when the shell exits
    /// cleanly; a failure, a lost connection (ssh's 255) or a signal keeps
    /// it open with "press Return to reconnect".
    func testOnlyACleanExitClosesTheTab() {
        XCTAssertTrue(TerminalSessionViewController.closesOnExit(status: 0))
        XCTAssertFalse(TerminalSessionViewController.closesOnExit(status: 1 << 8), "exit 1")
        XCTAssertFalse(TerminalSessionViewController.closesOnExit(status: 255 << 8), "ssh lost the VM")
        XCTAssertFalse(TerminalSessionViewController.closesOnExit(status: SIGKILL), "killed")
        XCTAssertFalse(TerminalSessionViewController.closesOnExit(status: SIGHUP | 0x80), "killed, core dumped")
    }

    // MARK: The progress line

    private func screenText(_ m: TerminalModel) -> String {
        m.copyText(from: mnd_pos(col: 0, line: mnd_vt_view_to_abs(m.vt, 0)),
                   to: mnd_pos(col: Int32(m.size.cols - 1), line: mnd_vt_view_to_abs(m.vt, Int32(m.size.rows - 1))),
                   block: false) ?? ""
    }

    /// A download's progress is one line rewritten in place. Narrowing the
    /// window wraps it over two rows: the next update still replaces all of
    /// it (it went back only to the start of the last row, and every update
    /// left another piece behind).
    func testTheProgressLineIsReplacedWholeAfterTheWindowNarrows() throws {
        let m = try XCTUnwrap(TerminalModel(cols: 70, rows: 8, scrollback: 50))
        m.feed("[monad] Connecting to VM susetest…\r\n")
        let first = "Downloading openSUSE Leap 16.0 — 41% (120 of 290 MB)"
        m.feed(TerminalSessionViewController.progressLine(first, rowsUp: m.rowsUpToLineStart(afterWriting: false)))
        XCTAssertTrue(m.resize(cols: 30, rows: 8))
        let second = "Downloading openSUSE Leap 16.0 — 79% (229 of 290 MB)"
        m.feed(TerminalSessionViewController.progressLine(second, rowsUp: m.rowsUpToLineStart(afterWriting: true)))
        let third = "Downloading openSUSE Leap 16.0 — 96%"
        m.feed(TerminalSessionViewController.progressLine(third, rowsUp: m.rowsUpToLineStart(afterWriting: true)))
        let text = screenText(m)
        XCTAssertFalse(text.contains("41%") || text.contains("79%"), text)
        XCTAssertEqual(text.components(separatedBy: "Downloading").count, 2, text)
        XCTAssertTrue(text.contains("Connecting to VM susetest"), text)
        XCTAssertTrue(m.resize(cols: 70, rows: 8))
        m.feed(TerminalSessionViewController.progressLine("Generating keys", rowsUp: m.rowsUpToLineStart(afterWriting: true)))
        let wide = screenText(m)
        XCTAssertFalse(wide.contains("Downloading"), wide)
        XCTAssertTrue(wide.contains("[monad] Generating keys"), wide)
        XCTAssertTrue(wide.contains("Connecting to VM susetest"), wide)
    }

    /// A first boot (Monad has never reached the VM, so it has no host key
    /// for it yet) says it takes longer, and only this once.
    func testTheFirstBootSaysItTakesAFewMinutesOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = InstancePaths(name: "dev", root: dir)
        try FileManager.default.createDirectory(at: paths.dir, withIntermediateDirectories: true)

        let first = TerminalSessionViewController.bootingStatus(paths)
        XCTAssertTrue(first.contains("first boot"), first)
        XCTAssertTrue(first.contains("a few minutes"), first)
        XCTAssertTrue(first.contains("only this time"), first)

        try Data("monad-dev ssh-ed25519 AAAA\n".utf8).write(to: paths.knownHosts)
        let later = TerminalSessionViewController.bootingStatus(paths)
        XCTAssertFalse(later.contains("first boot"), later)
        XCTAssertTrue(later.contains("Waiting for the guest to boot"), later)
    }
}
