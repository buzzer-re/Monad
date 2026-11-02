//
//  AuxiliaryWindow.swift — how Monad's windows other than terminals (a VM's
//  settings, Settings, Themes, the VM list, prompts) take part in Spaces.
//

import AppKit

extension NSWindow {
    /// Opens on the Space in front and stays there, a full-screen terminal's
    /// Space too, as a window over it that takes clicks. Without this, one
    /// opened over a full-screen window hung there, neither usable nor
    /// closable (2026-10-29).
    func joinsFullScreenSpaces() {
        collectionBehavior.remove([.canJoinAllSpaces, .fullScreenPrimary])
        collectionBehavior.insert([.fullScreenAuxiliary, .moveToActiveSpace])
    }
}
