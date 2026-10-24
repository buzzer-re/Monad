//
//  ClipboardPolicy.swift — when a guest may set the Mac's clipboard (OSC 52):
//  only with Settings › allowOSC52 on, only from the frontmost tab (what the
//  user is looking at), and at most 100 KiB. The boot console never may
//  (TerminalModel.feedConsole). Clipboard reads are refused in mnd_vt.
//

import Foundation

enum ClipboardPolicy {
    static let maxBytes = 100 * 1024

    enum Verdict: Equatable {
        case write
        /// The setting is off: nothing to say.
        case ignore
        /// Refused, and why (for the tab's toast and the debug log).
        case refuse(String)
    }

    static func verdict(enabled: Bool, bytes: Int, frontmost: Bool) -> Verdict {
        guard enabled else { return .ignore }
        guard bytes <= maxBytes else {
            return .refuse("The VM tried to copy more than 100 KB to the clipboard. Nothing was copied.")
        }
        guard frontmost else { return .refuse("A tab in the background tried to copy to the clipboard. Nothing was copied.") }
        return .write
    }
}
