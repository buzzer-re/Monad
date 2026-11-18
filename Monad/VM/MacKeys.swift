//
//  MacKeys.swift — the Mac's keyboard for a Linux VM's programs
//  (LinuxAppWindows.swift sends what this makes over GuestWindowProtocol).
//
//  A key press goes to the VM as the Linux kernel's code for that key, and
//  what the key types comes from a table made here from the Mac's own
//  layout (UCKeyTranslate), which the VM's window manager hands to
//  programs as their keymap. So a key types in a Linux window what it
//  types on the Mac, on any layout, with no layout to pick in the VM.
//
//  What the modifiers become:
//    Shift, Control, Caps Lock   themselves
//    Command                     Control: ⌘C, ⌘V, ⌘S, ⌘Q do in a Linux
//                                program what they do on the Mac
//    the left Option             Alt (shortcuts and menus)
//    the right Option            the third level: the characters Option
//                                types on the Mac's layout
//

import AppKit
import Carbon.HIToolbox

enum MacKeys {
    /// What is held with a key when the layout is asked what it types.
    enum Level: CaseIterable {
        case plain, shift, option, shiftOption, capsLock
    }

    /// What a key types at a level.
    enum Output: Equatable {
        case nothing
        case text(String)
        /// A key that waits for a letter to put an accent on: the accent by itself.
        case dead(String)
    }

    /// The Linux modifier bits (X's): what is held, and what is locked.
    struct Modifiers: Equatable {
        var held: UInt32
        var locked: UInt32
    }

    private static let shiftBit: UInt32 = 1, lockBit: UInt32 = 2, controlBit: UInt32 = 4, altBit: UInt32 = 8, thirdLevelBit: UInt32 = 0x80

    /// The side of a modifier, in an event's flags (IOKit's NX_DEVICE… bits).
    private enum Side {
        static let leftControl: UInt = 0x1, leftShift: UInt = 0x2, rightShift: UInt = 0x4, leftCommand: UInt = 0x8
        static let rightCommand: UInt = 0x10, leftOption: UInt = 0x20, rightOption: UInt = 0x40, rightControl: UInt = 0x2000
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Modifiers {
        var held: UInt32 = 0
        if flags.contains(.shift) { held |= shiftBit }
        if flags.contains(.control) || flags.contains(.command) { held |= controlBit }
        if flags.contains(.option) {
            let right = flags.rawValue & Side.rightOption != 0, left = flags.rawValue & Side.leftOption != 0
            if right { held |= thirdLevelBit }
            if left || !right { held |= altBit }
        }
        return Modifiers(held: held, locked: flags.contains(.capsLock) ? lockBit : 0)
    }

    /// Whether the modifier key `keyCode` is down, from the flags of the
    /// event that said it changed; nil when it is no modifier key the VM gets.
    static func modifierIsDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool? {
        let raw = flags.rawValue
        switch Int(keyCode) {
        case kVK_Shift: return raw & Side.leftShift != 0
        case kVK_RightShift: return raw & Side.rightShift != 0
        case kVK_Control: return raw & Side.leftControl != 0
        case kVK_RightControl: return raw & Side.rightControl != 0
        case kVK_Option: return raw & Side.leftOption != 0
        case kVK_RightOption: return raw & Side.rightOption != 0
        case kVK_Command: return raw & Side.leftCommand != 0
        case kVK_RightCommand: return raw & Side.rightCommand != 0
        case kVK_CapsLock: return flags.contains(.capsLock)
        default: return nil
        }
    }

    // MARK: Keys

    /// The Linux kernel's code for each Mac key (the Mac's virtual key
    /// codes are positions on the keyboard, as Linux's are).
    static let linuxCodes: [UInt16: UInt32] = {
        var codes: [Int: UInt32] = [
            kVK_ANSI_A: 30, kVK_ANSI_S: 31, kVK_ANSI_D: 32, kVK_ANSI_F: 33, kVK_ANSI_H: 35, kVK_ANSI_G: 34, kVK_ANSI_Z: 44,
            kVK_ANSI_X: 45, kVK_ANSI_C: 46, kVK_ANSI_V: 47, kVK_ISO_Section: 86, kVK_ANSI_B: 48, kVK_ANSI_Q: 16, kVK_ANSI_W: 17,
            kVK_ANSI_E: 18, kVK_ANSI_R: 19, kVK_ANSI_Y: 21, kVK_ANSI_T: 20, kVK_ANSI_1: 2, kVK_ANSI_2: 3, kVK_ANSI_3: 4,
            kVK_ANSI_4: 5, kVK_ANSI_6: 7, kVK_ANSI_5: 6, kVK_ANSI_Equal: 13, kVK_ANSI_9: 10, kVK_ANSI_7: 8, kVK_ANSI_Minus: 12,
            kVK_ANSI_8: 9, kVK_ANSI_0: 11, kVK_ANSI_RightBracket: 27, kVK_ANSI_O: 24, kVK_ANSI_U: 22, kVK_ANSI_LeftBracket: 26,
            kVK_ANSI_I: 23, kVK_ANSI_P: 25, kVK_ANSI_L: 38, kVK_ANSI_J: 36, kVK_ANSI_Quote: 40, kVK_ANSI_K: 37,
            kVK_ANSI_Semicolon: 39, kVK_ANSI_Backslash: 43, kVK_ANSI_Comma: 51, kVK_ANSI_Slash: 53, kVK_ANSI_N: 49, kVK_ANSI_M: 50,
            kVK_ANSI_Period: 52, kVK_ANSI_Grave: 41, kVK_JIS_Yen: 124, kVK_JIS_Underscore: 89, kVK_Space: 57,
        ]
        for (key, entry) in fixed { codes[key] = entry.code }
        return Dictionary(uniqueKeysWithValues: codes.map { (UInt16($0.key), $0.value) })
    }()

    static func linuxCode(_ keyCode: UInt16) -> UInt32? { linuxCodes[keyCode] }

    /// Keys that are the same on every layout: the Linux code, and the
    /// symbols (X's) they type.
    private static let fixed: [Int: (code: UInt32, symbols: [UInt32])] = [
        kVK_Return: (28, [0xFF0D]), kVK_Tab: (15, [0xFF09, 0xFE20]), kVK_Delete: (14, [0xFF08]), kVK_Escape: (1, [0xFF1B]),
        kVK_ForwardDelete: (111, [0xFFFF]), kVK_Help: (110, [0xFF63]), kVK_Home: (102, [0xFF50]), kVK_End: (107, [0xFF57]),
        kVK_PageUp: (104, [0xFF55]), kVK_PageDown: (109, [0xFF56]), kVK_LeftArrow: (105, [0xFF51]), kVK_RightArrow: (106, [0xFF53]),
        kVK_UpArrow: (103, [0xFF52]), kVK_DownArrow: (108, [0xFF54]),
        kVK_F1: (59, [0xFFBE]), kVK_F2: (60, [0xFFBF]), kVK_F3: (61, [0xFFC0]), kVK_F4: (62, [0xFFC1]), kVK_F5: (63, [0xFFC2]),
        kVK_F6: (64, [0xFFC3]), kVK_F7: (65, [0xFFC4]), kVK_F8: (66, [0xFFC5]), kVK_F9: (67, [0xFFC6]), kVK_F10: (68, [0xFFC7]),
        kVK_F11: (87, [0xFFC8]), kVK_F12: (88, [0xFFC9]), kVK_F13: (183, [0xFFCA]), kVK_F14: (184, [0xFFCB]),
        kVK_F15: (185, [0xFFCC]), kVK_F16: (186, [0xFFCD]), kVK_F17: (187, [0xFFCE]), kVK_F18: (188, [0xFFCF]),
        kVK_F19: (189, [0xFFD0]), kVK_F20: (190, [0xFFD1]),
        // The keypad types its digits: a Mac has no Num Lock.
        kVK_ANSI_Keypad0: (82, [0xFFB0]), kVK_ANSI_Keypad1: (79, [0xFFB1]), kVK_ANSI_Keypad2: (80, [0xFFB2]),
        kVK_ANSI_Keypad3: (81, [0xFFB3]), kVK_ANSI_Keypad4: (75, [0xFFB4]), kVK_ANSI_Keypad5: (76, [0xFFB5]),
        kVK_ANSI_Keypad6: (77, [0xFFB6]), kVK_ANSI_Keypad7: (71, [0xFFB7]), kVK_ANSI_Keypad8: (72, [0xFFB8]),
        kVK_ANSI_Keypad9: (73, [0xFFB9]), kVK_ANSI_KeypadDecimal: (83, [0xFFAE]), kVK_ANSI_KeypadMultiply: (55, [0xFFAA]),
        kVK_ANSI_KeypadPlus: (78, [0xFFAB]), kVK_ANSI_KeypadMinus: (74, [0xFFAD]), kVK_ANSI_KeypadDivide: (98, [0xFFAF]),
        kVK_ANSI_KeypadEnter: (96, [0xFF8D]), kVK_ANSI_KeypadEquals: (117, [0xFFBD]), kVK_ANSI_KeypadClear: (69, [0xFF0B]),
        kVK_JIS_KeypadComma: (121, [0xFFAC]),
        // The modifiers (the comment at the top says why these).
        kVK_Shift: (42, [0xFFE1]), kVK_RightShift: (54, [0xFFE2]), kVK_Control: (29, [0xFFE3]), kVK_RightControl: (97, [0xFFE4]),
        kVK_Command: (125, [0xFFE3]), kVK_RightCommand: (126, [0xFFE4]), kVK_Option: (56, [0xFFE9]),
        kVK_RightOption: (100, [0xFE03]), kVK_CapsLock: (58, [0xFFE5]),
    ]

    /// X's symbol for an accent that waits for its letter, by the accent as the Mac shows it alone.
    private static let deadSymbols: [Unicode.Scalar: UInt32] = [
        "`": 0xFE50, "´": 0xFE51, "'": 0xFE51, "^": 0xFE52, "ˆ": 0xFE52, "~": 0xFE53, "˜": 0xFE53, "¯": 0xFE54, "˘": 0xFE55,
        "˙": 0xFE56, "¨": 0xFE57, "\"": 0xFE57, "˚": 0xFE58, "˝": 0xFE59, "ˇ": 0xFE5A, "¸": 0xFE5B, "˛": 0xFE5C,
    ]

    /// X's symbol for what a key types; 0 when it is nothing one key can
    /// type there (several characters, a control character, a code of the
    /// Mac's own).
    private static func symbol(_ output: Output) -> UInt32 {
        switch output {
        case .nothing:
            return 0
        case .dead(let accent):
            guard accent.unicodeScalars.count == 1, let scalar = accent.unicodeScalars.first else { return 0 }
            return deadSymbols[scalar] ?? 0
        case .text(let text):
            guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return 0 }
            switch scalar.value {
            case 0x20...0x7E, 0xA0...0xFF: return scalar.value                 // Latin-1: the symbol is the character
            case 0x100...0xD7FF, 0xF900...0x10FFFF: return 0x0100_0000 + scalar.value
            default: return 0                                                   // control characters, private use
            }
        }
    }

    /// The table of every key: the fixed ones, and what `layout` says each
    /// of the others types. A key that types nothing is left out.
    static func table(_ layout: (UInt16, Level) -> Output) -> [GuestKey] {
        var keys: [GuestKey] = fixed.values.map { GuestKey(code: $0.code, caps: false, symbols: $0.symbols) }
        for (keyCode, code) in linuxCodes where fixed[Int(keyCode)] == nil {
            var symbols = [Level.plain, .shift, .option, .shiftOption].map { symbol(layout(keyCode, $0)) }
            while symbols.last == 0 { symbols.removeLast() }
            guard let plain = symbols.first, plain != 0 else { continue }
            let shifted = symbols.count > 1 ? symbols[1] : 0
            let caps = shifted != 0 && shifted != plain && symbol(layout(keyCode, .capsLock)) == shifted
            keys.append(GuestKey(code: code, caps: caps, symbols: symbols))
        }
        return keys.sorted { $0.code < $1.code }
    }

    // MARK: This Mac's layout

    /// What each key types on the layout this Mac has now; nil when the
    /// input source has no key layout (an input method does not).
    static func currentLayout() -> ((UInt16, Level) -> Output)? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let keyboard = UInt32(LMGetKbdType())
        return { keyCode, level in
            data.withUnsafeBytes { bytes -> Output in
                guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return .nothing }
                // UCKeyTranslate takes Carbon's modifiers, shifted down a byte.
                let carbon: Int
                switch level {
                case .plain: carbon = 0
                case .shift: carbon = shiftKey
                case .option: carbon = optionKey
                case .shiftOption: carbon = shiftKey | optionKey
                case .capsLock: carbon = alphaLock
                }
                func press(_ key: UInt16, _ modifiers: UInt32, _ dead: inout UInt32) -> String? {
                    var units = [UniChar](repeating: 0, count: 8)
                    var count = 0
                    let status = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown), modifiers, keyboard, 0, &dead, units.count, &count, &units)
                    return status == noErr ? String(utf16CodeUnits: units, count: count) : nil
                }
                var dead: UInt32 = 0
                guard let text = press(keyCode, UInt32(carbon >> 8) & 0xFF, &dead) else { return .nothing }
                if dead != 0 {
                    // It waits for a letter: a space after it gives the accent alone.
                    guard let accent = press(UInt16(kVK_Space), 0, &dead), !accent.isEmpty else { return .nothing }
                    return .dead(accent)
                }
                return text.isEmpty ? .nothing : .text(text)
            }
        }
    }
}
