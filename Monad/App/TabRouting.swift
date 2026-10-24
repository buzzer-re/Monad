//
//  TabRouting.swift — tabs and the VMs they open on (Phase 10). Every
//  terminal window takes tabs on any VM: a new tab joins the window it was
//  asked from (its "…" or "+"), else the frontmost one, and only ⌘N or no
//  open window makes a new window. ⌘T and "+" open another tab on the VM
//  of the tab in front; the "…" menu and the Shell menu say which VM.
//

import Foundation

enum TabRouting {
    /// A terminal tab: what it was opened on, and the VM that turned out to
    /// be (nil for host shells and VMs not resolved yet).
    struct Tab: Equatable {
        var target: SessionTarget
        var vm: String?
    }

    /// The tabbing identifier of every terminal window: one group, so any
    /// tab can join (or be dragged to) any window.
    static let group = "dev.monad.terminal"

    /// ⌘T: what another tab on the VM of the tab in front opens, or
    /// `fallback` when no terminal tab is in front. A tab opened on the
    /// default VM gives its VM by name (the default can change since). nil
    /// while the tab in front waits for its ephemeral VM, which has no name
    /// to open yet.
    static func newTab(focused: Tab?, fallback: SessionTarget) -> SessionTarget? {
        guard let focused else { return fallback }
        switch focused.target {
        case .ephemeralVM: return focused.vm.map { .vm($0) }
        case .defaultVM: return focused.vm.map { .vm($0) } ?? .defaultVM
        case .vm, .host: return focused.target
        }
    }

    /// The window (by number) a new tab joins: `asked`, the one it was asked
    /// from, while it is open, else the frontmost of `frontToBack`; nil when
    /// no terminal window is open (a new window).
    static func window(asked: Int?, frontToBack: [Int]) -> Int? {
        if let asked, frontToBack.contains(asked) { return asked }
        return frontToBack.first
    }

    /// Whether the titlebar's "…" hides: each tab has its own once the tab
    /// bar shows, and in full screen the titlebar is out of sight (changing
    /// it there brings it down over the tab bar and the terminal).
    static func hidesTitlebarMenu(tabBarVisible: Bool, fullScreen: Bool) -> Bool {
        tabBarVisible || fullScreen
    }

    /// The VM whose settings VM › "<vm> Settings…" opens: the one of the
    /// tab in front, none for a host shell or a VM not made yet.
    static func settingsVM(focused: Tab?) -> String? {
        guard let focused, focused.target != .host else { return nil }
        return focused.vm
    }

    static func settingsTitle(focused: Tab?) -> String {
        settingsVM(focused: focused).map { "“\($0)” Settings…" } ?? "VM Settings…"
    }

    /// The menu item for ⌘T. `defaultVM`: the one chosen with Make Default,
    /// else the top of the Virtual Machines list; nil when there is none yet
    /// ("default" is made then).
    static func newTabTitle(focused: Tab?, fallback: SessionTarget, defaultVM: String?) -> String {
        switch focused?.target ?? fallback {
        case .host: return "New Host Shell Tab"
        case .defaultVM: return "New Tab in \(focused?.vm ?? defaultVM ?? VMManager.defaultName)"
        case .vm(let name): return "New Tab in \(name)"
        case .ephemeralVM: return focused?.vm.map { "New Tab in \($0)" } ?? "New Tab"
        }
    }
}
