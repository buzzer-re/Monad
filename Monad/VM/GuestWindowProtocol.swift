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
//  mislead on screen is taken out. The one thing that is not a line is
//  a copy the user asked for with ⌘C: as many bytes as its line says,
//  bounded, which must be text (GuestClipboard decides what becomes of it).
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
    /// A popup (a menu, a tooltip): the window it is on, and where its
    /// inner part stands from that window's inner top left, in that
    /// window's pixels (it may reach outside it). 0 for a window of its own.
    var parent: UInt32 = 0
    var offsetX = 0, offsetY = 0

    var isPopup: Bool { parent != 0 }
}

enum GuestWindowEvent: Equatable, Sendable {
    /// Said once, first.
    case hello(display: GuestDisplaySize)
    /// All the windows there are now, oldest first.
    case windows([GuestWindow])
    /// What the program in front copied after the user's ⌘C; empty when
    /// it was something the Mac cannot have (a picture, too much). The
    /// guest may say it unasked: who takes it decides (GuestClipboard).
    case copied(String)
    /// How the pointer is to look over the window it is in: a number of
    /// GuestCursor's (0: not at all), never a picture.
    case cursor(Int)
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
    /// The user clicked away from that window's popups.
    case dismiss(window: UInt32)
    /// The user pressed ⌘V: the Mac's text, which a paste in the VM gives from now on.
    case paste(String)
    /// The user pressed ⌘C (or ⌘X): what the program in front copies next is for the Mac.
    case copy

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
        case .dismiss(let window): return "dismiss \(window)\n"
        case .paste(let text):
            // Its bytes follow as they are, counted: more than the window manager takes would end the connection.
            guard text.utf8.count <= GuestClipboard.maxPaste else { return "" }
            return "paste \(text.utf8.count)\n" + text
        case .copy: return "copy\n"
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
    /// Menus of menus, as deep as any goes (the window manager allows no more).
    static let maxPopupDepth = 8
    /// How far from its window a popup may say it stands, in pixels: more
    /// than the window manager lets a program ask.
    static let maxOffset = 1 << 23
    /// The most a copy may be, in bytes: mwm_server.h's MWM_MAX_COPY, as
    /// much as a terminal may set (ClipboardPolicy).
    static let maxCopyBytes = 100 * 1024

    private(set) var isBroken = false
    private(set) var display: GuestDisplaySize?
    private var line: [UInt8] = []
    /// A list being read: how many windows it said, and those read so far.
    private var expected: Int?
    private var list: [GuestWindow] = []
    /// A copy being read: its bytes so far, and how many are still to come.
    private var copy: [UInt8] = []
    private var copyLeft = 0

    /// Feed bytes; returns what became whole with them.
    mutating func feed(_ data: Data) -> [GuestWindowEvent] {
        var events: [GuestWindowEvent] = []
        for byte in data {
            if isBroken { break }
            if copyLeft > 0 {
                copy.append(byte)
                copyLeft -= 1
                if copyLeft == 0, let event = copied() { events.append(event) }
            } else if byte == 0x0A {
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
            copy = []
            copyLeft = 0
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
            guard let count = expected, list.count == count, words.count == 1, Self.popupsHold(list) else { return broken() }
            let whole = list
            expected = nil
            list = []
            return .windows(whole)
        case "copied":
            guard display != nil, expected == nil, words.count == 2, let count = Self.number(words[1], 0...Self.maxCopyBytes)
            else { return broken() }
            guard count > 0 else { return .copied("") }
            copyLeft = count
            copy = []
            copy.reserveCapacity(count)
            return nil
        case "cursor":
            guard display != nil, expected == nil, words.count == 2, let shape = Self.number(words[1], 0...GuestCursor.lastShape)
            else { return broken() }
            return .cursor(shape)
        default:
            return nil // a word a newer window manager may say
        }
    }

    private mutating func broken() -> GuestWindowEvent? {
        isBroken = true
        return nil
    }

    /// The bytes of a copy came whole: text, or the connection is broken.
    /// What is no letter (but tabs and line ends) is taken out, so that
    /// nothing in it does anything where the user pastes it: an escape
    /// sequence would, in a terminal.
    private mutating func copied() -> GuestWindowEvent? {
        defer { copy = [] }
        guard !copy.contains(0), let text = String(bytes: copy, encoding: .utf8) else { return broken() }
        let kept = text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D: return true
            case 0..<0x20, 0x7F..<0xA0: return false
            default: return true
            }
        }
        return .copied(String(String.UnicodeScalarView(kept)))
    }

    /// Every popup is on a window of the list, by way of no more popups than may be, and never of itself.
    private static func popupsHold(_ list: [GuestWindow]) -> Bool {
        let parents = Dictionary(list.map { ($0.id, $0.parent) }, uniquingKeysWith: { first, _ in first })
        return list.allSatisfy { window in
            var up = window.parent, depth = 0
            while up != 0 {
                depth += 1
                guard depth <= maxPopupDepth, let next = parents[up] else { return false }
                up = next
            }
            return true
        }
    }

    private func window(_ words: [Substring]) -> GuestWindow? {
        guard let display, words.count == 16,
              let id = Self.number(words[1], 1...Int(UInt32.max)),
              let width = Self.number(words[4], 1...display.width), let height = Self.number(words[5], 1...display.height),
              let x = Self.number(words[2], 0...(display.width - width)), let y = Self.number(words[3], 0...(display.height - height)),
              let scale = Self.number(words[6], 1...Self.maxScale),
              let innerWidth = Self.number(words[9], 1...width), let innerHeight = Self.number(words[10], 1...height),
              let innerX = Self.number(words[7], 0...(width - innerWidth)), let innerY = Self.number(words[8], 0...(height - innerHeight)),
              let parent = Self.number(words[11], 0...Int(UInt32.max)), parent != id,
              let offsetX = Self.signed(words[12], Self.maxOffset), let offsetY = Self.signed(words[13], Self.maxOffset),
              parent != 0 || (offsetX == 0 && offsetY == 0),
              let appID = Self.text(words[14]), let title = Self.text(words[15]) else { return nil }
        return GuestWindow(id: UInt32(id), x: x, y: y, width: width, height: height, scale: scale,
                           innerX: innerX, innerY: innerY, innerWidth: innerWidth, innerHeight: innerHeight, appID: appID, title: title,
                           parent: UInt32(parent), offsetX: offsetX, offsetY: offsetY)
    }

    /// A strict decimal that may be negative ("-5"; never "-0" or "+5"), within ±`bound`.
    private static func signed(_ word: Substring, _ bound: Int) -> Int? {
        guard word.first == "-" else { return number(word, 0...bound) }
        return number(word.dropFirst(), 1...bound).map { -$0 }
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
