//
//  GuestClipboard.swift — when the Mac's clipboard and a Linux VM's meet,
//  for the VM's programs shown as windows (LinuxAppWindows.swift).
//
//  The VM is not trusted with the Mac's clipboard: it never reads it by
//  itself and never sets it by itself. The two meet on the user's keys in
//  one of the VM's windows, and only then:
//
//  - ⌘V: the Mac's text is given to the VM before the key is, when the
//    Mac's clipboard is the newer of the two (something was copied on the
//    Mac since the VM last had it or set it). What was given stays in the
//    VM: it is what a paste there gives until something else is copied.
//  - ⌘C, ⌘X: what the program in front copies next is asked of the window
//    manager, and taken when it comes soon, once, while the user is still
//    in that VM's windows. Text only, and no more than a terminal may set
//    (ClipboardPolicy).
//
//  Which of the two is newer is told by the Mac's count of clipboard
//  changes, so that a picture copied in the VM (which the Mac never gets)
//  is not pasted over by the older text the Mac still holds.
//

import Foundation

struct GuestClipboard {
    /// The most text ⌘V gives a VM, in bytes (mwm_server.h's MWM_MAX_CLIPBOARD).
    static let maxPaste = 1 << 20
    /// How long after ⌘C the VM's answer is still one (the window manager waits two seconds for the program).
    static let answerTime: TimeInterval = 3

    enum Shortcut: Equatable {
        case copy, paste
    }

    /// What a key pressed with Command is to the clipboards, from what it
    /// types: V pastes (with Shift too, as terminals in the VM have it), C
    /// and X copy.
    static func shortcut(typed: String?) -> Shortcut? {
        switch typed?.lowercased() {
        case "v": return .paste
        case "c", "x": return .copy
        default: return nil
        }
    }

    enum Paste: Equatable {
        /// The VM is given this before the key.
        case send(String)
        /// The VM pastes what it has: the Mac's text already, or something copied there since.
        case keep
        /// More than a VM is given: nothing is pasted from the Mac.
        case refuse
    }

    /// The Mac's clipboard (its count of changes) as the VM last had it, or as the VM's copy made it.
    private var known: Int?
    /// When the user pressed ⌘C, until the VM answered.
    private var asked: Date?

    /// ⌘V in one of the VM's windows, with the Mac's clipboard as it is
    /// now. Its text is read only when it is to be sent.
    mutating func paste(changeCount: Int, text read: @autoclosure () -> String?) -> Paste {
        guard changeCount != known, var text = read(), !text.isEmpty else { return .keep }
        if text.contains("\0") { text = text.replacingOccurrences(of: "\0", with: "") } // no text to the window manager
        guard !text.isEmpty else { return .keep }
        guard text.utf8.count <= Self.maxPaste else { return .refuse }
        known = changeCount
        return .send(text)
    }

    /// ⌘C (or ⌘X) in one of the VM's windows.
    mutating func copyPressed(at now: Date) { asked = now }

    /// The VM says what was copied (nothing: something the Mac cannot
    /// have). True when it is to be written to the Mac's clipboard;
    /// `inFront`: one of the VM's windows still has the keys.
    mutating func copied(_ text: String, at now: Date, inFront: Bool, changeCount: Int) -> Bool {
        guard let asked else { return false }
        self.asked = nil
        let waited = now.timeIntervalSince(asked)
        guard waited >= 0, waited <= Self.answerTime, inFront else { return false }
        guard !text.isEmpty else {
            known = changeCount // the VM's clipboard is the newer one, though the Mac has none of it
            return false
        }
        return true
    }

    /// The VM's copy was written to the Mac's clipboard, which now counts this.
    mutating func wrote(changeCount: Int) { known = changeCount }
}
