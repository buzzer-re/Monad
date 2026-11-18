//
//  MacKeysTests.swift — the Mac's keyboard as a Linux VM's programs get it
//  (MacKeys.swift): which Linux key each Mac key is, what the modifiers
//  become, and the table of what each key types, made from the Mac's own
//  layout.
//

import AppKit
import XCTest
@testable import Monad

final class MacKeysTests: XCTestCase {
    /// A US layout, as far as the tests press keys: letters, digits and a few signs.
    private func us(_ key: UInt16, _ level: MacKeys.Level) -> MacKeys.Output {
        let plain: [UInt16: (String, String)] = [0x00: ("a", "A"), 0x0C: ("q", "Q"), 0x12: ("1", "!"), 0x2B: (",", "<"), 0x31: (" ", " ")]
        guard let pair = plain[key] else { return .nothing }
        switch level {
        case .plain: return .text(pair.0)
        case .shift: return .text(pair.1)
        case .capsLock: return .text(key == 0x12 || key == 0x2B ? pair.0 : pair.1)
        case .option: return key == 0x00 ? .text("å") : key == 0x0C ? .text("œ") : key == 0x12 ? .text("¡") : .nothing
        case .shiftOption: return key == 0x00 ? .text("Å") : key == 0x0C ? .text("Œ") : key == 0x12 ? .text("⁄") : .nothing
        }
    }

    /// Every Mac key has a Linux key of its own, one X has a place for.
    func testEachMacKeyIsALinuxKeyOfItsOwn() {
        let codes = MacKeys.linuxCodes
        XCTAssertEqual(Set(codes.values).count, codes.count, "no two Mac keys are the same Linux key")
        XCTAssertTrue(codes.values.allSatisfy { (1...247).contains($0) })
        XCTAssertEqual(MacKeys.linuxCode(0x00), 30, "A")
        XCTAssertEqual(MacKeys.linuxCode(0x24), 28, "Return")
        XCTAssertEqual(MacKeys.linuxCode(0x33), 14, "Delete is Linux's Backspace")
        XCTAssertEqual(MacKeys.linuxCode(0x75), 111, "Forward Delete is Linux's Delete")
        XCTAssertEqual(MacKeys.linuxCode(0x7E), 103, "Up")
        XCTAssertEqual(MacKeys.linuxCode(0x38), 42, "Shift")
        XCTAssertEqual(MacKeys.linuxCode(0x3D), 100, "the right Option key")
        XCTAssertNil(MacKeys.linuxCode(0x3F), "fn is the Mac's own")
        XCTAssertNil(MacKeys.linuxCode(0xFFFF))
    }

    /// The table says what each key types on this Mac's layout, at each level.
    func testTheTableIsTheMacsLayout() {
        let keys = MacKeys.table(us)
        func key(_ code: UInt32) -> GuestKey? { keys.first { $0.code == code } }
        XCTAssertEqual(Set(keys.map(\.code)).count, keys.count)
        XCTAssertLessThanOrEqual(keys.count, 247)
        XCTAssertEqual(key(30), GuestKey(code: 30, caps: true, symbols: [0x61, 0x41, 0xE5, 0xC5]), "a A å Å, and Caps Lock gives the capital")
        XCTAssertEqual(key(16), GuestKey(code: 16, caps: true, symbols: [0x71, 0x51, 0x1000153, 0x1000152]), "œ and Œ are beyond Latin-1")
        XCTAssertEqual(key(2), GuestKey(code: 2, caps: false, symbols: [0x31, 0x21, 0xA1, 0x1002044]), "Caps Lock leaves digits alone")
        XCTAssertEqual(key(51), GuestKey(code: 51, caps: false, symbols: [0x2C, 0x3C]), "nothing with Option: two levels")
        XCTAssertEqual(key(57)?.symbols.first, 0x20)
        XCTAssertNil(key(31), "a key the layout types nothing with is left out")
        // Keys that are the same on every layout.
        XCTAssertEqual(key(28)?.symbols, [0xFF0D], "Return")
        XCTAssertEqual(key(14)?.symbols, [0xFF08], "Backspace")
        XCTAssertEqual(key(15)?.symbols, [0xFF09, 0xFE20], "Tab, and back with Shift")
        XCTAssertEqual(key(1)?.symbols, [0xFF1B], "Escape")
        XCTAssertEqual(key(105)?.symbols, [0xFF51], "Left")
        XCTAssertEqual(key(59)?.symbols, [0xFFBE], "F1")
        XCTAssertEqual(key(82)?.symbols, [0xFFB0], "the keypad's 0")
        // The modifiers: Command does what Control does in a Linux program.
        XCTAssertEqual(key(42)?.symbols, [0xFFE1], "Shift")
        XCTAssertEqual(key(29)?.symbols, [0xFFE3], "Control")
        XCTAssertEqual(key(125)?.symbols, [0xFFE3], "Command")
        XCTAssertEqual(key(126)?.symbols, [0xFFE4], "the right Command")
        XCTAssertEqual(key(56)?.symbols, [0xFFE9], "the left Option is Alt")
        XCTAssertEqual(key(100)?.symbols, [0xFE03], "the right Option types the third level")
        XCTAssertEqual(key(58)?.symbols, [0xFFE5], "Caps Lock")
    }

    /// A key that only puts an accent on the next letter is told as such.
    func testDeadKeysStayDead() {
        let keys = MacKeys.table { key, level in
            switch (key, level) {
            case (0x0E, .plain): return .text("e")
            case (0x0E, .shift), (0x0E, .capsLock): return .text("E")
            case (0x0E, .option): return .dead("´")
            case (0x27, .plain): return .dead("'")
            case (0x27, .shift): return .dead("\"")
            case (0x32, .plain): return .dead("`")
            case (0x32, .shift): return .dead("~")
            case (0x16, .shift): return .dead("^")
            case (0x16, .plain): return .text("6")
            case (0x20, .option): return .dead("¨")
            case (0x20, .plain): return .text("u")
            case (0x2D, .option): return .dead("˜")
            case (0x2D, .plain): return .text("n")
            case (0x08, .option): return .dead("☃")
            case (0x08, .plain): return .text("c")
            default: return .nothing
            }
        }
        func symbols(_ code: UInt32) -> [UInt32] { keys.first { $0.code == code }?.symbols ?? [] }
        XCTAssertEqual(symbols(18), [0x65, 0x45, 0xFE51], "Option-e: the acute accent, waiting for its letter")
        XCTAssertEqual(symbols(40), [0xFE51, 0xFE57], "' and \" on a layout where they are accents")
        XCTAssertEqual(symbols(41), [0xFE50, 0xFE53], "grave and tilde")
        XCTAssertEqual(symbols(7), [0x36, 0xFE52], "circumflex")
        XCTAssertEqual(symbols(22), [0x75, 0, 0xFE57], "Option-u: the diaeresis")
        XCTAssertEqual(symbols(49), [0x6E, 0, 0xFE53], "Option-n: the tilde")
        XCTAssertEqual(symbols(46), [0x63], "an accent X has no key for is not typed")
    }

    /// What a key types is one character Linux has a symbol for.
    func testOnlyWhatLinuxCanTypeIsInTheTable() {
        let keys = MacKeys.table { key, level in
            guard level == .plain else { return .nothing }
            switch key {
            case 0x00: return .text("ab")          // two characters: not a key's symbol
            case 0x01: return .text("\u{7}")       // a control character
            case 0x02: return .text("\u{1F600}")   // beyond the first plane: still a symbol
            case 0x03: return .text("é")
            case 0x05: return .text("")
            case 0x04: return .text("\u{F704}")    // the Mac's own code for a function key
            default: return .nothing
            }
        }
        XCTAssertNil(keys.first { $0.code == 30 })
        XCTAssertNil(keys.first { $0.code == 31 })
        XCTAssertEqual(keys.first { $0.code == 32 }?.symbols, [0x0101F600])
        XCTAssertEqual(keys.first { $0.code == 33 }?.symbols, [0xE9])
        XCTAssertNil(keys.first { $0.code == 34 })
        XCTAssertNil(keys.first { $0.code == 35 })
    }

    /// The Mac's modifiers as a Linux program hears them.
    func testModifiersBecomeLinuxOnes() {
        typealias Flags = NSEvent.ModifierFlags
        let leftOption = Flags(rawValue: Flags.option.rawValue | 0x20), rightOption = Flags(rawValue: Flags.option.rawValue | 0x40)
        XCTAssertEqual(MacKeys.modifiers([]), MacKeys.Modifiers(held: 0, locked: 0))
        XCTAssertEqual(MacKeys.modifiers(.shift).held, 1)
        XCTAssertEqual(MacKeys.modifiers(.control).held, 4)
        XCTAssertEqual(MacKeys.modifiers(.command).held, 4, "Command is the Control of a Linux program")
        XCTAssertEqual(MacKeys.modifiers([.command, .control, .shift]).held, 5)
        XCTAssertEqual(MacKeys.modifiers(leftOption).held, 8, "the left Option is Alt")
        XCTAssertEqual(MacKeys.modifiers(rightOption).held, 0x80, "the right Option is the third level")
        XCTAssertEqual(MacKeys.modifiers(Flags(rawValue: Flags.option.rawValue | 0x60)).held, 0x88, "both")
        XCTAssertEqual(MacKeys.modifiers(.option).held, 8, "an Option of no side is the left one")
        XCTAssertEqual(MacKeys.modifiers(.capsLock), MacKeys.Modifiers(held: 0, locked: 2))
        XCTAssertEqual(MacKeys.modifiers([.capsLock, .shift, .function, .numericPad]), MacKeys.Modifiers(held: 1, locked: 2))
    }

    /// A modifier key going down or up, from the flags after it did.
    func testAModifierKeyIsDownWhileItsFlagIsSet() {
        typealias Flags = NSEvent.ModifierFlags
        XCTAssertEqual(MacKeys.modifierIsDown(keyCode: 0x38, flags: Flags(rawValue: Flags.shift.rawValue | 0x02)), true, "left Shift")
        XCTAssertEqual(MacKeys.modifierIsDown(keyCode: 0x38, flags: Flags(rawValue: Flags.shift.rawValue | 0x04)), false,
                       "left Shift came up while the right one is held")
        XCTAssertEqual(MacKeys.modifierIsDown(keyCode: 0x3C, flags: Flags(rawValue: Flags.shift.rawValue | 0x04)), true, "right Shift")
        XCTAssertEqual(MacKeys.modifierIsDown(keyCode: 0x37, flags: Flags(rawValue: Flags.command.rawValue | 0x08)), true, "left Command")
        XCTAssertEqual(MacKeys.modifierIsDown(keyCode: 0x36, flags: Flags(rawValue: Flags.command.rawValue | 0x10)), true, "right Command")
        XCTAssertEqual(MacKeys.modifierIsDown(keyCode: 0x3A, flags: []), false, "left Option")
        XCTAssertEqual(MacKeys.modifierIsDown(keyCode: 0x3D, flags: Flags(rawValue: Flags.option.rawValue | 0x40)), true, "right Option")
        XCTAssertEqual(MacKeys.modifierIsDown(keyCode: 0x3B, flags: Flags(rawValue: Flags.control.rawValue | 0x01)), true, "left Control")
        XCTAssertEqual(MacKeys.modifierIsDown(keyCode: 0x3E, flags: Flags(rawValue: Flags.control.rawValue | 0x2000)), true, "right Control")
        XCTAssertEqual(MacKeys.modifierIsDown(keyCode: 0x39, flags: .capsLock), true, "Caps Lock, while its light is on")
        XCTAssertNil(MacKeys.modifierIsDown(keyCode: 0x00, flags: .shift), "A is no modifier")
        XCTAssertNil(MacKeys.modifierIsDown(keyCode: 0x3F, flags: .function), "fn is the Mac's own")
    }

    /// The layout this Mac has now gives a table monad-wm takes: a key for
    /// each letter at least, each key once.
    func testThisMacsLayoutMakesATable() throws {
        guard let layout = MacKeys.currentLayout() else { throw XCTSkip("this Mac's input source has no key layout (an input method)") }
        let keys = MacKeys.table(layout)
        XCTAssertGreaterThan(keys.count, 80)
        XCTAssertLessThanOrEqual(keys.count, 247)
        XCTAssertEqual(Set(keys.map(\.code)).count, keys.count)
        XCTAssertTrue(keys.allSatisfy { $0.symbols.first ?? 0 != 0 && $0.symbols.count <= 4 })
        XCTAssertEqual(keys.first { $0.code == 57 }?.symbols.first, 0x20, "the space bar types a space")
    }
}
