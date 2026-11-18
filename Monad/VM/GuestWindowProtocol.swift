//
//  GuestWindowProtocol.swift — MonadHost's end of the channel to a Linux
//  VM's window manager (monad-wm; GuestWM/mwm_ctl.h says every line).
//
//  The window manager tells where each program's window is on the VM's
//  display, and MonadHost shows each as a window on the Mac. Every byte it
//  sends is the guest's, which we treat as hostile: lines are bounded,
//  plain printable ASCII, and must match an exact grammar; a window must
//  lie on the display it was said to have. Anything else ends the
//  connection, and nothing of it is shown. What programs call their
//  windows is text to show and nothing more: it is cut, and what would
//  mislead on screen is taken out.
//

import Foundation

/// The size of a VM's display, in its pixels.
struct GuestDisplaySize: Equatable, Sendable {
    let width: Int
    let height: Int
}

/// A program's window as it is on the VM's display.
struct GuestWindow: Equatable, Sendable, Identifiable {
    let id: UInt32
    /// Its place on the display, in the display's pixels, from the top left.
    let x: Int, y: Int, width: Int, height: Int
    /// Pixels to a point: the Mac's window is that many times smaller.
    let scale: Int
    /// The part that is the window proper (the rest is a shadow the
    /// program draws around it), from the window's top left.
    let innerX: Int, innerY: Int, innerWidth: Int, innerHeight: Int
    let appID: String
    let title: String
}

enum GuestWindowEvent: Equatable, Sendable {
    /// Said once, first.
    case hello(display: GuestDisplaySize)
    /// All the windows there are now, oldest first.
    case windows([GuestWindow])
}

/// A key of the Mac's keyboard for the VM: the Linux kernel's code for it,
/// and the symbols (X's numbers) it types plain, with Shift, with the
/// third-level key, and with both. `caps`: Caps Lock does what Shift does.
struct GuestKey: Equatable, Sendable {
    let code: UInt32
    let caps: Bool
    let symbols: [UInt32]
}

/// What MonadHost tells the window manager. Windows are named by id; 0 is
/// no window. Positions and scrolling are in 1/256 of a point.
enum GuestWindowCommand: Equatable, Sendable {
    case scale(Int)
    case pointer(window: UInt32, x: Int32, y: Int32)
    case button(code: UInt32, down: Bool)
    case scroll(dx: Int32, dy: Int32)
    case focus(window: UInt32)
    case key(code: UInt32, down: Bool)
    case modifiers(held: UInt32, locked: UInt32)
    case keys([GuestKey])
    case size(window: UInt32, width: Int, height: Int)
    case close(window: UInt32)

    /// The lines, as mwm_ctl.c reads them.
    var text: String {
        switch self {
        case .scale(let scale): return "scale \(scale)\n"
        case .pointer(let window, let x, let y): return "pointer \(window) \(x) \(y)\n"
        case .button(let code, let down): return "button \(code) \(down ? 1 : 0)\n"
        case .scroll(let dx, let dy): return "scroll \(dx) \(dy)\n"
        case .focus(let window): return "focus \(window)\n"
        case .key(let code, let down): return "key \(code) \(down ? 1 : 0)\n"
        case .modifiers(let held, let locked): return "mods \(held) \(locked)\n"
        case .keys(let keys):
            guard !keys.isEmpty else { return "" }
            return "keys \(keys.count)\n" + keys.map { key in
                let symbols = (0..<4).map { $0 < key.symbols.count ? key.symbols[$0] : 0 }
                return "k \(key.code) \(key.caps ? 1 : 0) " + symbols.map(String.init).joined(separator: " ") + "\n"
            }.joined()
        case .size(let window, let width, let height): return "size \(window) \(width) \(height)\n"
        case .close(let window): return "close \(window)\n"
        }
    }
}

/// Reads what the window manager sends, with bounded memory. Once
/// something did not fit, it is broken and reads nothing more: the
/// connection is to be closed.
struct GuestWindowReader {
    static let version = 1
    /// mwm_ctl.h's MWM_CTL_LINE.
    static let maxLineLength = 1024
    static let maxWindows = 64
    /// The largest display Virtualization gives, each way.
    static let maxSide = 8192
    static let maxScale = 4
    /// A title's bytes at most (the window manager cuts at 127).
    static let maxTextBytes = 128

    private(set) var isBroken = false
    private(set) var display: GuestDisplaySize?
    private var line: [UInt8] = []
    /// A list being read: how many windows it said, and those read so far.
    private var expected: Int?
    private var list: [GuestWindow] = []

    /// Feed bytes; returns what became whole with them.
    mutating func feed(_ data: Data) -> [GuestWindowEvent] {
        var events: [GuestWindowEvent] = []
        for byte in data {
            if isBroken { break }
            if byte == 0x0A {
                if let event = read(line) { events.append(event) }
                line.removeAll(keepingCapacity: true)
            } else if byte < 0x20 || byte > 0x7E || line.count >= Self.maxLineLength {
                isBroken = true
            } else {
                line.append(byte)
            }
        }
        if isBroken {
            line = []
            list = []
            expected = nil
        }
        return events
    }

    private mutating func read(_ bytes: [UInt8]) -> GuestWindowEvent? {
        let words = String(decoding: bytes, as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false)
        guard let first = words.first, !first.isEmpty else { return nil }
        guard !words.contains(where: \.isEmpty) else { return broken() }
        switch first {
        case "monad-wm":
            guard display == nil, words.count == 4, Self.number(words[1], 1...Self.version) != nil,
                  let width = Self.number(words[2], 1...Self.maxSide), let height = Self.number(words[3], 1...Self.maxSide)
            else { return broken() }
            let size = GuestDisplaySize(width: width, height: height)
            display = size
            return .hello(display: size)
        case "windows":
            guard display != nil, expected == nil, words.count == 3, Self.number(words[1], 0...Int(UInt32.max)) != nil,
                  let count = Self.number(words[2], 0...Self.maxWindows) else { return broken() }
            expected = count
            list = []
            return nil
        case "window":
            guard let expected, list.count < expected, let window = window(words), !list.contains(where: { $0.id == window.id })
            else { return broken() }
            list.append(window)
            return nil
        case "end":
            guard let count = expected, list.count == count, words.count == 1 else { return broken() }
            let whole = list
            expected = nil
            list = []
            return .windows(whole)
        default:
            return nil // a word a newer window manager may say
        }
    }

    private mutating func broken() -> GuestWindowEvent? {
        isBroken = true
        return nil
    }

    private func window(_ words: [Substring]) -> GuestWindow? {
        guard let display, words.count == 13,
              let id = Self.number(words[1], 1...Int(UInt32.max)),
              let width = Self.number(words[4], 1...display.width), let height = Self.number(words[5], 1...display.height),
              let x = Self.number(words[2], 0...(display.width - width)), let y = Self.number(words[3], 0...(display.height - height)),
              let scale = Self.number(words[6], 1...Self.maxScale),
              let innerWidth = Self.number(words[9], 1...width), let innerHeight = Self.number(words[10], 1...height),
              let innerX = Self.number(words[7], 0...(width - innerWidth)), let innerY = Self.number(words[8], 0...(height - innerHeight)),
              let appID = Self.text(words[11]), let title = Self.text(words[12]) else { return nil }
        return GuestWindow(id: UInt32(id), x: x, y: y, width: width, height: height, scale: scale,
                           innerX: innerX, innerY: innerY, innerWidth: innerWidth, innerHeight: innerHeight, appID: appID, title: title)
    }

    /// Strict decimal within `range`: digits only, no sign, no leading zero.
    private static func number(_ word: Substring, _ range: ClosedRange<Int>) -> Int? {
        guard !word.isEmpty, word.utf8.count <= 10, word.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              word == "0" || word.first != "0", let value = Int(word), range.contains(value) else { return nil }
        return value
    }

    /// A program's text from the word it was written as: %XX for every
    /// byte but plain ASCII, "-" for none. Then made fit to show: bytes
    /// that are no text become U+FFFD, and control characters and the
    /// characters that turn the reading order around are taken out.
    private static func text(_ word: Substring) -> String? {
        if word == "-" { return "" }
        var bytes: [UInt8] = []
        var rest = word.utf8[...]
        while let byte = rest.first {
            rest = rest.dropFirst()
            if byte == UInt8(ascii: "%") {
                guard rest.count >= 2, let high = hex(rest[rest.startIndex]), let low = hex(rest[rest.index(after: rest.startIndex)])
                else { return nil }
                bytes.append(high << 4 | low)
                rest = rest.dropFirst(2)
            } else {
                bytes.append(byte)
            }
            guard bytes.count <= maxTextBytes else { return nil }
        }
        let shown = String(decoding: bytes, as: UTF8.self).unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0..<0x20, 0x7F..<0xA0: return false               // control characters
            case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return false // reading order
            case 0x2028, 0x2029: return false                      // line and paragraph ends
            default: return true
            }
        }
        return String(String.UnicodeScalarView(shown))
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil // the window manager writes capitals
        }
    }
}
