//
//  MacRecoveryTests.swift — System Integrity Protection is changed in the
//  VM's recoveryOS, which Monad drives with keys and clicks (found on the
//  Mac, docs/MACOS.md): Options, the first language, Terminal, csrutil,
//  its question and the account's password, then a shutdown. Nothing is
//  seen; the boot after says how SIP is.
//

import XCTest
@testable import Monad

/// Records what is pressed and clicked.
@MainActor
final class FakeRecoveryInput: MacRecoveryInput {
    enum Event: Equatable {
        case key(UInt16, [UInt16])
        case click(Double, Double)
    }

    private(set) var events: [Event] = []
    var error: Error?
    /// What the display shows (nil: it cannot be seen).
    var showing: () -> MacRecovery.Screen? = { nil }

    func screen() async -> MacRecovery.Screen? { showing() }

    /// The picture the display shows (nil: none).
    var pictureData: Data?
    func picture() async -> Data? { pictureData }

    func press(keyCode: UInt16, modifiers: [UInt16]) async throws {
        if let error { throw error }
        events.append(.key(keyCode, modifiers))
    }

    func release(keyCodes: [UInt16]) async throws {}

    func click(x: Double, y: Double) async throws {
        if let error { throw error }
        events.append(.click(x, y))
    }

    /// The text typed, from the key events (US layout, shift for capitals).
    var typed: String {
        var out = ""
        for case .key(let code, let mods) in events {
            guard let ch = MacRecovery.character(forKeyCode: code, shift: mods.contains(MacRecovery.Key.shift)) else {
                out += "⏎"
                continue
            }
            out.append(ch)
        }
        return out
    }
}

@MainActor
final class MacRecoveryTests: XCTestCase {
    /// Off: Options in the startup picker, the first language, Terminal,
    /// `csrutil disable`, yes, the password, then the VM shuts down.
    func testTurningSIPOffIsTypedInRecovery() throws {
        let steps = MacRecovery.steps(sip: false)
        let typed = steps.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
        XCTAssertEqual(typed, ["English", "csrutil disable", "y", "shutdown -h now"],
                       "English chosen by name in the language list, whatever the Mac's language puts first")
        let acts = steps.filter { if case .note = $0 { return false } else { return true } }
        XCTAssertEqual(acts.prefix(5), [.screen(min: 5, quiet: 3, max: MacRecovery.pickerWait), .key(MacRecovery.Key.right, []),
                                        .key(MacRecovery.Key.right, []), .key(MacRecovery.Key.returnKey, []),
                                        .lit(max: MacRecovery.recoveryWait)])
        XCTAssertTrue(steps.contains(.key(MacRecovery.Key.t, [MacRecovery.Key.shift, MacRecovery.Key.command])), "⇧⌘T: Terminal")
        let password = try XCTUnwrap(steps.firstIndex(of: .password))
        XCTAssertLessThan(steps.firstIndex(of: .text("y"))!, password)
        XCTAssertLessThan(password, steps.firstIndex(of: .text("shutdown -h now"))!)
        XCTAssertEqual(steps.last, .key(MacRecovery.Key.returnKey, []))
        // The language list takes no keys until clicked.
        XCTAssertTrue(steps.contains { if case .click = $0 { return true } else { return false } })
    }

    /// The steps say what they do as they go, in order, for the VM's
    /// status and log (nothing is seen, so this is all there is to show).
    func testTheStepsSayWhatTheyDo() async throws {
        let steps = MacRecovery.steps(sip: false)
        let notes = steps.compactMap { if case .note(let n) = $0 { return n } else { return nil } }
        XCTAssertEqual(notes, ["choosing Options in the startup picker", "waiting for recovery to load",
                               "opening Terminal", "running csrutil disable", "confirming with the account's password",
                               "waiting for csrutil to answer", "shutting recovery down"])
        var said: [String] = []
        try await MacRecovery.run(steps, on: FakeRecoveryInput(), password: "pw", clock: TestClock(),
                                  say: { said.append($0) })
        XCTAssertEqual(said, notes.enumerated().map { "\($0.element) (step \($0.offset + 2) of \(notes.count + 1))" },
                       "step 1 is starting recovery")
    }

    /// On: `csrutil enable`, which asks Apple over the network, so its
    /// answer is waited for longer.
    func testTurningSIPOnWaitsForApple() {
        let on = MacRecovery.steps(sip: true), off = MacRecovery.steps(sip: false)
        XCTAssertTrue(on.contains(.text("csrutil enable")))
        XCTAssertFalse(on.contains(.text("csrutil disable")))
        func waitAfterPassword(_ s: [MacRecovery.Step]) -> TimeInterval {
            let i = s.firstIndex(of: .password)!
            return s[i...].compactMap { if case .screen(_, _, let w) = $0 { return w } else { return nil } }.first ?? 0
        }
        XCTAssertGreaterThan(waitAfterPassword(on), waitAfterPassword(off))
    }

    /// Text is typed key by key on a US layout; a character it has no key
    /// for is refused before anything is pressed.
    func testTextIsTypedKeyByKey() async throws {
        let input = FakeRecoveryInput()
        let clock = TestClock()
        try await MacRecovery.run([.text("csrutil disable"), .key(MacRecovery.Key.returnKey, []), .password,
                                   .wait(5), .click(0.5, 0.45)],
                                  on: input, password: "Ab3xY", clock: clock)
        XCTAssertEqual(input.typed, "csrutil disable⏎Ab3xY")
        XCTAssertEqual(input.events.last, .click(0.5, 0.45))
        XCTAssertGreaterThanOrEqual(clock.totalSlept, 5)
        XCTAssertTrue(input.events.contains(.key(MacRecovery.Key.a, [MacRecovery.Key.shift])), "a capital is shifted")
        let refused = FakeRecoveryInput()
        do {
            try await MacRecovery.run([.text("y"), .text("é")], on: refused, password: "", clock: clock)
            XCTFail("é has no key here")
        } catch {}
        XCTAssertEqual(refused.events, [], "nothing pressed")
    }

    // MARK: Waiting for the screen

    /// A screen of one shade, or with a cursor (one cell) on it.
    private func screen(_ shade: UInt8, cursor: Bool = false) -> MacRecovery.Screen {
        var s = MacRecovery.Screen(shade: shade)
        if cursor { s.cells[100] = 255 - shade }
        return s
    }

    /// The screen is waited for, not a fixed time: once it has changed since
    /// the last key and then stayed still, the steps go on.
    func testTheNextScreenIsWaitedFor() async throws {
        let clock = TestClock(), input = FakeRecoveryInput()
        let start = clock.now()
        // The key's answer shows 6 s after it.
        input.showing = { clock.now().timeIntervalSince(start) < 6 ? self.screen(0) : self.screen(200) }
        try await MacRecovery.run([.key(MacRecovery.Key.returnKey, []), .screen(min: 1, quiet: 2, max: 100)],
                                  on: input, password: "", clock: clock)
        XCTAssertGreaterThanOrEqual(clock.totalSlept, 8, "6 s until it changes, then 2 s still")
        XCTAssertLessThan(clock.totalSlept, 10, "not the 100 s it used to wait")
    }

    /// A cursor blinking in Terminal is not a change, nor does it keep the
    /// screen from being still.
    func testABlinkingCursorIsNotAChange() async throws {
        let clock = TestClock(), input = FakeRecoveryInput()
        let start = clock.now()
        input.showing = {
            let t = clock.now().timeIntervalSince(start)
            return self.screen(t < 3 ? 0 : 200, cursor: Int(t * 2) % 2 == 0)
        }
        try await MacRecovery.run([.key(MacRecovery.Key.returnKey, []), .screen(min: 0, quiet: 2, max: 60)],
                                  on: input, password: "", clock: clock)
        XCTAssertLessThan(clock.totalSlept, 7)
        let still = FakeRecoveryInput()
        let begun = clock.now()
        still.showing = { self.screen(0, cursor: Int(clock.now().timeIntervalSince(begun) * 2) % 2 == 0) }
        let before = clock.totalSlept
        try await MacRecovery.run([.key(MacRecovery.Key.returnKey, []), .screen(min: 0, quiet: 2, max: 30)],
                                  on: still, password: "", clock: clock)
        XCTAssertEqual(clock.totalSlept - before, 30, accuracy: 0.6, "only a cursor: nothing happened yet, so the whole wait")
    }

    /// A screen that cannot be seen, or that does not change, gets the whole
    /// wait (as before), and a quick answer still waits the least.
    func testWithoutAChangeTheWholeWait() async throws {
        let clock = TestClock()
        try await MacRecovery.run([.key(MacRecovery.Key.returnKey, []), .screen(min: 1, quiet: 2, max: 30)],
                                  on: FakeRecoveryInput(), password: "", clock: clock)
        XCTAssertEqual(clock.totalSlept, 30, accuracy: 0.01, "nothing to see")
        let quick = FakeRecoveryInput(), start = clock.now()
        quick.showing = { clock.now().timeIntervalSince(start) < 0.1 ? self.screen(0) : self.screen(200) }
        let before = clock.totalSlept
        try await MacRecovery.run([.key(MacRecovery.Key.returnKey, []), .screen(min: 5, quiet: 1, max: 30)],
                                  on: quick, password: "", clock: clock)
        XCTAssertGreaterThanOrEqual(clock.totalSlept - before, 5, "at least the least")
        XCTAssertLessThan(clock.totalSlept - before, 7)
    }

    /// The display can be unreadable for a while (its view is just made, or
    /// not drawn): the wait keeps looking, and stillness counts only while
    /// it is seen. The first screen is told from a black one (a VM that has
    /// just started shows nothing yet).
    func testFramesThatComeLateAreWaitedFor() async throws {
        let clock = TestClock(), input = FakeRecoveryInput(), start = clock.now()
        input.showing = {
            let t = clock.now().timeIntervalSince(start)
            return t < 3 ? nil : self.screen(200)
        }
        try await MacRecovery.run([.screen(min: 1, quiet: 2, max: 30)], on: input, password: "", clock: clock)
        XCTAssertGreaterThanOrEqual(clock.totalSlept, 5, "seen from 3 s, still 2 s")
        XCTAssertLessThan(clock.totalSlept, 7)
        // Seen, then not: no stillness is taken from the frames that were seen.
        let blind = FakeRecoveryInput(), begun = clock.now(), before = clock.totalSlept
        blind.showing = { clock.now().timeIntervalSince(begun) < 1 ? self.screen(200) : nil }
        try await MacRecovery.run([.key(MacRecovery.Key.returnKey, []), .screen(min: 0, quiet: 2, max: 20)],
                                  on: blind, password: "", clock: clock)
        XCTAssertEqual(clock.totalSlept - before, 20, accuracy: 0.6)
    }

    /// Recovery has loaded once its screen is lit (the language list's grey
    /// over the whole display): the black boot screen, however long its
    /// progress bar stalls, is not it.
    func testRecoveryHasLoadedOnceTheScreenIsLit() async throws {
        let clock = TestClock(), input = FakeRecoveryInput(), start = clock.now()
        input.showing = {
            let t = clock.now().timeIntervalSince(start)
            var boot = self.screen(0)
            boot.cells[100] = 255 // the Apple logo and a stalled bar, the same for a minute
            return t < 60 ? boot : self.screen(30)
        }
        var lines: [String] = []
        try await MacRecovery.run([.key(MacRecovery.Key.returnKey, []), .lit(max: 100)], on: input, password: "", clock: clock,
                                  log: { lines.append($0) })
        XCTAssertEqual(clock.now().timeIntervalSince(start), 60, accuracy: 1)
        XCTAssertTrue(lines.first?.hasPrefix("screen: lit after 60 s (at most 100)") ?? false, "\(lines)")
        lines = []
        let dark = FakeRecoveryInput()
        dark.showing = { self.screen(0) }
        try await MacRecovery.run([.lit(max: 20)], on: dark, password: "", clock: clock, log: { lines.append($0) })
        XCTAssertTrue(lines.first?.hasPrefix("screen: not lit in 20 s") ?? false, "\(lines)")
    }

    /// Each wait's log line says how it went (for tuning from the VM's log):
    /// how long, how many frames, how many changes.
    func testEachWaitIsLogged() async throws {
        let clock = TestClock(), input = FakeRecoveryInput(), start = clock.now()
        input.showing = { clock.now().timeIntervalSince(start) < 2 ? self.screen(0) : self.screen(200) }
        var lines: [String] = []
        try await MacRecovery.run([.key(MacRecovery.Key.returnKey, []), .screen(min: 1, quiet: 2, max: 30)],
                                  on: input, password: "", clock: clock, log: { lines.append($0) })
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("screen: still after 4 s (at most 30), "), lines[0])
        XCTAssertTrue(lines[0].contains("1 change"), lines[0])
        lines = []
        try await MacRecovery.run([.screen(min: 1, quiet: 2, max: 5)], on: FakeRecoveryInput(), password: "", clock: clock,
                                  log: { lines.append($0) })
        XCTAssertEqual(lines, ["screen: waited all 5 s, no frames"])
    }

    /// The display as each wait ended is kept, named by its step, so a
    /// failed run can be looked at afterwards.
    func testEachWaitKeepsThePicture() async throws {
        let clock = TestClock(), input = FakeRecoveryInput()
        input.pictureData = Data([1, 2, 3])
        var kept: [(String, Data)] = []
        try await MacRecovery.run([.screen(min: 0, quiet: 0, max: 1), .note("opening Terminal"),
                                   .key(MacRecovery.Key.returnKey, []), .screen(min: 0, quiet: 0, max: 1)],
                                  on: input, password: "", clock: clock, keep: { kept.append(($0, $1)) })
        XCTAssertEqual(kept.map(\.0), ["step-1-wait-1", "step-2-wait-2"])
        XCTAssertEqual(kept.map(\.1), [Data([1, 2, 3]), Data([1, 2, 3])])
        kept = []
        input.pictureData = nil
        try await MacRecovery.run([.screen(min: 0, quiet: 0, max: 1)], on: input, password: "", clock: clock,
                                  keep: { kept.append(($0, $1)) })
        XCTAssertTrue(kept.isEmpty)
    }

    /// Recovery's long waits are screens now, at most as long as before.
    func testRecoveryWaitsForItsScreens() {
        for on in [false, true] {
            let steps = MacRecovery.steps(sip: on)
            let maxima = steps.compactMap { step -> TimeInterval? in
                switch step {
                case .screen(_, _, let max), .lit(let max): return max
                default: return nil
                }
            }
            XCTAssertTrue(maxima.contains(MacRecovery.pickerWait))
            XCTAssertTrue(maxima.contains(MacRecovery.recoveryWait))
            XCTAssertTrue(maxima.contains(on ? MacRecovery.onWait : MacRecovery.offWait))
            let fixed = steps.compactMap { if case .wait(let w) = $0 { return w } else { return nil } }
            XCTAssertLessThanOrEqual(fixed.reduce(0, +), 3, "only short pauses left: \(fixed)")
        }
    }

    /// Every character of a VM account's password can be typed.
    func testEveryPasswordCanBeTyped() {
        for _ in 0..<20 {
            let pw = MacSetup.newPassword()
            XCTAssertNotNil(MacRecovery.keyStrokes(for: pw), pw)
        }
    }

    /// How SIP is, from `csrutil status` in the booted VM.
    func testTheStatusIsReadFromCsrutil() {
        XCTAssertEqual(MacRecovery.status(from: "System Integrity Protection status: enabled.\n"), .enabled)
        XCTAssertEqual(MacRecovery.status(from: "System Integrity Protection status: disabled.\n"), .disabled)
        XCTAssertEqual(MacRecovery.status(from: "System Integrity Protection status: unknown (Custom Configuration).\n"),
                       .other("unknown (Custom Configuration)"))
        XCTAssertEqual(MacRecovery.status(from: ""), .other(""))
        // Root in the VM writes what it says: anything but a short plain answer is not quoted.
        XCTAssertEqual(MacRecovery.status(from: "status: " + String(repeating: "x", count: 5000)), .other(""))
        XCTAssertEqual(MacRecovery.status(from: "status: off\u{1b}[2J\u{202E}"), .other(""))
    }
}
