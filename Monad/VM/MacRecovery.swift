//
//  MacRecovery.swift — System Integrity Protection, changed the only way
//  macOS allows: in the VM's recoveryOS. Monad boots the VM there with a
//  display, a keyboard and a pointer, and drives it blind with the steps
//  found on the Mac (docs/MACOS.md): Options in the startup picker, the
//  first language, Terminal (⇧⌘T, a root shell), csrutil, its question
//  and the account's password, then a shutdown. Each step waits for the
//  screen it leads to (changed, then still), never longer than it used to
//  wait without looking. The boot after checks `csrutil status`; that, not
//  these steps, says whether it worked.
//

import Foundation

/// Keys and clicks into a VM's display (Apple's private input API, behind
/// MNDVirtualMachine; a fake in tests).
@MainActor
protocol MacRecoveryInput: AnyObject {
    /// One key, down then up, with modifiers held around it.
    func press(keyCode: UInt16, modifiers: [UInt16]) async throws
    /// A click at a point of the display, 0…1 from its top left.
    func click(x: Double, y: Double) async throws
    /// Keys let go (whatever the Mac's keyboard left held, ⌘ for ⌘V).
    func release(keyCodes: [UInt16]) async throws
    /// What the display shows now, coarsely (nil: it cannot be seen).
    func screen() async -> MacRecovery.Screen?
    /// How the display is read, for the VM's log ("" when there is nothing to say).
    var screenInfo: String { get }
    /// The display as a PNG, kept after each wait (nil: none).
    func picture() async -> Data?
}

extension MacRecoveryInput {
    var screenInfo: String { "" }
    func picture() async -> Data? { nil }
}

/// A macOS VM's security as found at its last boot (the Security page).
struct MacSecurityReport: Codable, Equatable, Sendable {
    /// What `csrutil status` said ("enabled", "disabled", or its own words).
    var sip: String?
    /// Why SIP is not as set, after Monad tried to change it.
    var problem: String?
    /// Whether the VM's disk gives Monad's sessions full disk access.
    var fullDiskAccess: Bool?
    /// Why full disk access could not be changed.
    var accessProblem: String?
    /// What the VM does before macOS starts (recovery, its disk), while it does.
    var step: String?
}

enum MacRecovery {
    enum Step: Equatable {
        case wait(TimeInterval)
        /// Until the screen has changed from what it was as the wait began
        /// (just after the last key, so the key's own echo is not the answer)
        /// and then stayed still for `quiet`; at least `min`, at most `max`
        /// (all of it when the screen cannot be seen).
        case screen(min: TimeInterval, quiet: TimeInterval, max: TimeInterval)
        /// Until most of the screen is lit (recovery's grey, not the black
        /// boot screen, whose progress bar can stall), at most `max`.
        case lit(max: TimeInterval)
        case key(UInt16, [UInt16])
        case text(String)
        /// The VM account's password, typed, never logged.
        case password
        case click(Double, Double)
        /// What the next steps do, said to the VM's status and log.
        case note(String)
    }

    /// How SIP is, as `csrutil status` says.
    enum Status: Equatable {
        case enabled
        case disabled
        case other(String)

        var word: String {
            switch self {
            case .enabled: return "enabled"
            case .disabled: return "disabled"
            case .other(let s): return s
            }
        }
    }

    /// Mac virtual key codes (US layout).
    enum Key {
        static let a: UInt16 = 0
        static let v: UInt16 = 9
        static let t: UInt16 = 17
        static let returnKey: UInt16 = 36
        static let command: UInt16 = 55
        static let shift: UInt16 = 56
        /// Every modifier, left and right (⌘ ⇧ ⌥ ⌃, then the right ones).
        static let modifiers: [UInt16] = [55, 56, 58, 59, 54, 60, 61, 62]
        static let right: UInt16 = 124
    }

    /// The display, coarsely: the mean brightness of each cell of a grid.
    struct Screen: Equatable, Sendable {
        static let columns = 64, rows = 40
        var cells: [UInt8]

        init(cells: [UInt8]) { self.cells = cells }
        init(shade: UInt8, count: Int = Self.columns * Self.rows) { cells = Array(repeating: shade, count: count) }

        /// Most cells brighter than black: recovery's grey windows, not the
        /// startup picker or the boot screen (about 1% lit).
        var isLit: Bool {
            !cells.isEmpty && cells.filter { $0 > 12 }.count * 10 >= cells.count * 6
        }

        /// More than a cursor's worth of cells changed (Terminal's blinks in one).
        func differs(from other: Screen) -> Bool {
            guard cells.count == other.cells.count else { return true }
            var changed = 0
            for i in cells.indices where abs(Int(cells[i]) - Int(other.cells[i])) > 10 {
                changed += 1
                if changed > 3 { return true }
            }
            return false
        }
    }

    /// How often the screen is looked at while waiting.
    static let screenInterval: TimeInterval = 0.5

    /// The display recovery runs on (the clicks below are for it).
    static let displayWidth = 1920
    static let displayHeight = 1200
    static let displayPixelsPerInch = 80

    /// At most: until the startup picker shows; until recoveryOS has loaded.
    static let pickerWait: TimeInterval = 30
    static let recoveryWait: TimeInterval = 180
    /// At most, until csrutil has answered: turning SIP on asks Apple first.
    static let offWait: TimeInterval = 20
    static let onWait: TimeInterval = 90
    /// Until the VM has shut down after the steps.
    static let shutdownTimeout: TimeInterval = 180

    /// The steps that turn SIP on or off.
    static func steps(sip on: Bool) -> [Step] {
        [
            .screen(min: 5, quiet: 3, max: pickerWait),
            .note("choosing Options in the startup picker"),
            // Macintosh HD is selected by the first key, Options by the second.
            .key(Key.right, []), .key(Key.right, []), .key(Key.returnKey, []),
            .note("waiting for recovery to load"),
            .lit(max: recoveryWait),
            .screen(min: 1, quiet: 2, max: 10),
            // The language list (the Mac's language first) takes keys once clicked on its first row; English
            // is then chosen by name (its letters are where they are on every Latin layout), for a US keyboard.
            .click(0.5, 0.4525), .wait(1), .text("English"), .wait(1), .key(Key.returnKey, []),
            .screen(min: 3, quiet: 3, max: 30),
            .note("opening Terminal"),
            .key(Key.t, [Key.shift, Key.command]),
            .screen(min: 1, quiet: 2, max: 10),
            .note(on ? "running csrutil enable" : "running csrutil disable"),
            .text(on ? "csrutil enable" : "csrutil disable"), .key(Key.returnKey, []),
            .screen(min: 1, quiet: 1.5, max: 5),
            .note("confirming with the account's password"),
            .text("y"), .key(Key.returnKey, []),
            .screen(min: 1, quiet: 1.5, max: 5),
            .password, .key(Key.returnKey, []),
            .note("waiting for csrutil to answer"),
            .screen(min: 2, quiet: 3, max: on ? onWait : offWait),
            .note("shutting recovery down"),
            .text("shutdown -h now"), .key(Key.returnKey, []),
        ]
    }

    /// Starting recovery is step 1; the notes are the steps after it.
    static func stepCount(_ steps: [Step]) -> Int {
        1 + steps.filter { if case .note = $0 { return true } else { return false } }.count
    }

    /// Runs `steps`; text is checked to be typeable before anything is pressed.
    @MainActor
    static func run(_ steps: [Step], on input: MacRecoveryInput, password: String, clock: MonadClock,
                    say: (String) -> Void = { _ in }, log: (String) -> Void = { _ in },
                    keep: (String, Data) -> Void = { _, _ in }) async throws {
        for step in steps {
            let text: String
            switch step {
            case .text(let t): text = t
            case .password: text = password
            default: continue
            }
            guard keyStrokes(for: text) != nil else {
                throw MonadError("Monad cannot type “\(step == .password ? "the password" : text)” into the VM.")
            }
        }
        let total = stepCount(steps)
        var number = 1
        // Whether a key or click came before: a VM just started shows nothing (black) yet.
        var acted = false
        var waits = 0
        for step in steps {
            try Task.checkCancellation()
            switch step {
            case .note(let what):
                number += 1
                say("\(what) (step \(number) of \(total))")
            case .wait(let s): await clock.sleep(seconds: s)
            case .screen(let least, let quiet, let most):
                let w = await waitForScreen(acted: acted, min: least, quiet: quiet, max: most, on: input, clock: clock)
                var line = w.took.map { "screen: still after \(Int($0.rounded())) s (at most \(Int(most)))" }
                    ?? "screen: waited all \(Int(most)) s"
                line += w.frames == 0 ? ", no frames"
                    : ", \(w.frames) frames, \(w.changes) change\(w.changes == 1 ? "" : "s")"
                if !input.screenInfo.isEmpty { line += " (\(input.screenInfo))" }
                log(line)
                waits += 1
                if let png = await input.picture() { keep("step-\(number)-wait-\(waits)", png) }
            case .lit(let most):
                let w = await waitForLight(max: most, on: input, clock: clock)
                var line = w.took.map { "screen: lit after \(Int($0.rounded())) s (at most \(Int(most)))" }
                    ?? "screen: not lit in \(Int(most)) s"
                line += w.frames == 0 ? ", no frames" : ", \(w.frames) frames"
                if !input.screenInfo.isEmpty { line += " (\(input.screenInfo))" }
                log(line)
                waits += 1
                if let png = await input.picture() { keep("step-\(number)-wait-\(waits)", png) }
            case .key(let code, let mods):
                acted = true
                try await input.press(keyCode: code, modifiers: mods)
            case .click(let x, let y):
                acted = true
                try await input.click(x: x, y: y)
            case .text(let t):
                acted = true
                try await type(t, on: input)
            case .password:
                acted = true
                try await type(password, on: input)
            }
        }
    }

    /// Waits as `.screen` says: how long it took (nil when it waited all
    /// of `max`: nothing to see, or nothing changed and kept still), the
    /// frames seen and how often they changed.
    @MainActor
    private static func waitForScreen(acted: Bool, min least: TimeInterval, quiet: TimeInterval,
                                      max most: TimeInterval, on input: MacRecoveryInput,
                                      clock: MonadClock) async -> (took: TimeInterval?, frames: Int, changes: Int) {
        let start = clock.now()
        var frames = 0, changes = 0, changed = false
        // Told from the first frame of the wait (after the key), or from black before any key.
        var baseline: Screen?
        var last: Screen?
        var stillSince = start
        while true {
            if let seen = await input.screen() {
                frames += 1
                if baseline == nil { baseline = acted ? seen : Screen(shade: 0, count: seen.cells.count) }
                if let l = last {
                    // Small changes add up against the last change kept (a slow progress bar counts in the end).
                    if seen.differs(from: l) {
                        last = seen
                        stillSince = clock.now()
                        changes += 1
                    }
                } else {
                    last = seen
                    stillSince = clock.now()
                }
                if let b = baseline, seen.differs(from: b) { changed = true }
            } else {
                // Not seen (its view just made, or not drawn): nothing is still while unseen.
                stillSince = clock.now()
            }
            let now = clock.now(), elapsed = now.timeIntervalSince(start)
            if changed, elapsed >= least, now.timeIntervalSince(stillSince) >= quiet { return (elapsed, frames, changes) }
            if elapsed >= most { return (nil, frames, changes) }
            await clock.sleep(seconds: Swift.min(screenInterval, most - elapsed))
        }
    }

    /// Waits until the screen is lit: how long it took (nil: not in `max`) and the frames seen.
    @MainActor
    private static func waitForLight(max most: TimeInterval, on input: MacRecoveryInput,
                                     clock: MonadClock) async -> (took: TimeInterval?, frames: Int) {
        let start = clock.now()
        var frames = 0
        while true {
            if let seen = await input.screen() {
                frames += 1
                if seen.isLit { return (clock.now().timeIntervalSince(start), frames) }
            }
            let elapsed = clock.now().timeIntervalSince(start)
            if elapsed >= most { return (nil, frames) }
            await clock.sleep(seconds: Swift.min(screenInterval, most - elapsed))
        }
    }

    @MainActor
    private static func type(_ text: String, on input: MacRecoveryInput) async throws {
        for (code, shift) in keyStrokes(for: text) ?? [] {
            try await input.press(keyCode: code, modifiers: shift ? [Key.shift] : [])
        }
    }

    // MARK: US layout

    private static let plain: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, " ": 49, "`": 50,
    ]
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// The keys that type `text` (code, shifted), or nil if one has none.
    static func keyStrokes(for text: String) -> [(UInt16, Bool)]? {
        var out: [(UInt16, Bool)] = []
        for ch in text {
            if let code = plain[ch] {
                out.append((code, false))
            } else if ch.isUppercase, let lower = ch.lowercased().first, ch.isASCII, let code = plain[lower] {
                out.append((code, true))
            } else if let base = shifted[ch], let code = plain[base] {
                out.append((code, true))
            } else {
                return nil
            }
        }
        return out
    }

    /// The character a key types (tests), or nil for a key that types none.
    static func character(forKeyCode code: UInt16, shift: Bool) -> Character? {
        guard let ch = plain.first(where: { $0.value == code })?.key else { return nil }
        guard shift else { return ch }
        if ch.isLetter { return Character(ch.uppercased()) }
        return shifted.first { $0.value == ch }?.key
    }

    // MARK: Status

    /// Asked in the booted VM, as its user.
    static let statusCommand = "csrutil status"

    /// What `csrutil status` says ("System Integrity Protection status: enabled.").
    static func status(from output: String) -> Status {
        let line = output.split(separator: "\n").first { $0.contains("status:") }.map(String.init) ?? ""
        guard let r = line.range(of: "status:") else { return .other("") }
        var word = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        if word.hasSuffix(".") { word.removeLast() }
        switch word {
        case "enabled": return .enabled
        case "disabled": return .disabled
        default:
            // Root in the VM writes this: only a short plain answer is quoted.
            let plain = word.range(of: #"\A[A-Za-z0-9 ,()/-]{1,40}\z"#, options: .regularExpression) != nil
            return .other(plain ? word : "")
        }
    }
}
