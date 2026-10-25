//
//  AppDelegate.swift — application lifecycle, menus and window management.
//

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var managerWindow: NSWindow?
    private var canvasController: CanvasWindowController?
    private var settingsWindow: NSWindow?
    private var themeEditorWindow: NSWindow?
    /// One detail window per VM, by name.
    private var detailWindows: [String: NSWindow] = [:]
    /// Monitor-mode questions from the VMs' firewalls.
    private var firewallPrompts: FirewallPromptController?
    private var approvalPrompts: ApprovalPromptController?
    private var macSetupPrompts: MacSetupPromptController?
    private var vmTabMenu = NSMenu(title: "Open VM")
    private var themeMenu = NSMenu(title: "Theme")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.mainMenu = buildMainMenu()
        // Unit tests and Xcode previews run inside the app: never provision
        // VMs or open windows.
        if Self.isHeadless() { return }
        DebugLog.shared.watchSettings()
        DebugLog.shared.log("app", "Monad started (\(Bundle.main.bundleURL.path))")
        if Self.hostShellOnly {
            open(.host, asTab: false)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if !MNDVirtualMachine.isSupported() {
            let alert = NSAlert()
            alert.messageText = "Virtualization is not available"
            alert.informativeText = "This Mac does not support Virtualization.framework. Only host shell tabs are available."
            alert.runModal()
            open(.host, asTab: false)
            return
        }
        // VMs live in MonadHost (a launchd agent) and keep running when
        // Monad quits; tabs reconnect to them on the next launch.
        HostAgent.start()
        // "Start VM at boot": the marked VMs start, without opening tabs.
        Task { @MainActor in
            do {
                try await HostAgent.client.startMarkedVMs()
            } catch {
                DebugLog.shared.log("app", "start at boot: \(error.localizedDescription)")
            }
        }
        firewallPrompts = FirewallPromptController(host: HostAgent.client)
        approvalPrompts = ApprovalPromptController(host: HostAgent.client)
        macSetupPrompts = MacSetupPromptController(host: HostAgent.client)
        newWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Debug-only switch for UI tests (`-MonadHostShellOnly YES`): every new
    /// tab is a host shell, so no VM is provisioned or booted.
    static var hostShellOnly: Bool {
        #if DEBUG
            return UserDefaults.standard.bool(forKey: "MonadHostShellOnly")
        #else
            return false
        #endif
    }

    /// Target for new windows and tabs.
    private var defaultTarget: SessionTarget {
        Self.hostShellOnly ? .host : .defaultVM
    }

    /// Launched by a tool (unit tests, Xcode previews and code snippets)
    /// rather than by the user.
    nonisolated static func isHeadless(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// VMs keep running in MonadHost; closing the connection releases this
    /// app's tab sessions (ephemeral VMs are discarded by the host).
    func applicationWillTerminate(_ notification: Notification) {
        for c in TerminalWindowController.all { c.closeAllSessions() }
        if !Self.isHeadless() && !Self.hostShellOnly { HostAgent.client.stop() }
    }

    // MARK: Windows and tabs

    /// The terminal window in front, and its tab.
    private var focusedTerminal: TerminalWindowController? {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? TerminalWindowController
    }
    private var focusedTab: TabRouting.Tab? { focusedTerminal?.routingTab }

    /// The terminal windows, front to back (tabs not in front last).
    private func terminalWindows(besides new: NSWindow) -> [NSWindow] {
        let all = TerminalWindowController.all.compactMap(\.window).filter { $0 !== new }
        let ordered = NSApp.orderedWindows.filter { w in all.contains { $0 === w } }
        return ordered + all.filter { w in !ordered.contains { $0 === w } }
    }

    /// A tab on `target` (any VM, a host shell): in `owner`'s window, the
    /// one it was asked from, else the terminal window in front
    /// (TabRouting); a window of its own when `asTab` is false (⌘N) or no
    /// terminal window is open.
    @discardableResult
    func open(_ target: SessionTarget, from owner: TerminalWindowController? = nil,
              asTab: Bool = true) -> TerminalWindowController {
        let controller = TerminalWindowController(target: target)
        guard let window = controller.window else { return controller }
        let windows = terminalWindows(besides: window)
        let number = asTab ? TabRouting.window(asked: (owner ?? focusedTerminal)?.window?.windowNumber,
                                               frontToBack: windows.map(\.windowNumber)) : nil
        if let host = windows.first(where: { $0.windowNumber == number }) {
            DebugLog.shared.log("tabs", "\(target) opens as a tab in window \(host.windowNumber)")
            host.addTabbedWindow(window, ordered: .above)
        } else {
            DebugLog.shared.log("tabs", "\(target) opens a window\(asTab ? " (no terminal window open)" : "")")
            if let last = TerminalWindowController.all.dropLast().last?.window {
                window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
            } else {
                window.center()
            }
        }
        window.makeKeyAndOrderFront(nil)
        controller.start()
        // A window that now has two tabs shows its tab bar, and "…" in each tab.
        TerminalWindowController.all.forEach { $0.refreshTabMenu() }
        return controller
    }

    // MARK: Tab selection (⌘1 … ⌘9)

    /// Index of the tab selected by ⌘<number>, Terminal/Safari style: 1–8
    /// pick that tab if it exists, 9 always picks the last tab.
    nonisolated static func tabIndex(forShortcut number: Int, tabCount: Int) -> Int? {
        guard tabCount > 0, (1...9).contains(number) else { return nil }
        if number == 9 { return tabCount - 1 }
        return number <= tabCount ? number - 1 : nil
    }

    /// Select tab `number` in the tab group of `window`. Returns false if
    /// there is no such tab.
    @discardableResult
    func selectTab(number: Int, in window: NSWindow?) -> Bool {
        guard let window else { return false }
        let tabs = window.tabbedWindows ?? [window]
        guard let index = Self.tabIndex(forShortcut: number, tabCount: tabs.count) else { return false }
        let target = tabs[index]
        if let group = window.tabGroup, group.selectedWindow !== target {
            group.selectedWindow = target
        }
        target.makeKeyAndOrderFront(nil)
        return true
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        if !selectTab(number: sender.tag, in: NSApp.keyWindow ?? NSApp.mainWindow) { NSSound.beep() }
    }

    /// The standard panel, with which build this is after the version:
    /// "Version 1.0 (release, built …, FA2769A0)".
    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [.version: Flavor.currentAboutVersion])
    }

    @objc func newWindow(_ sender: Any?) {
        open(defaultTarget, asTab: false)
    }

    /// The window a "…" menu item was chosen in (nil: the Shell menu).
    private func owner(_ sender: Any?) -> TerminalWindowController? {
        let chosen = (sender as? NSMenuItem)?.representedObject
        return chosen as? TerminalWindowController ?? (chosen as? OpenVMChoice)?.owner
    }

    /// ⌘T: another tab on the VM of the tab in front, in its window (from a
    /// tab's "…", on that tab's VM, in that tab's window).
    @objc func newTab(_ sender: Any?) {
        newTab(from: owner(sender))
    }

    /// Another tab on `owner`'s VM (or the tab in front's), in its window
    /// (the tab bar's "+" too).
    func newTab(from owner: TerminalWindowController?) {
        guard let target = TabRouting.newTab(focused: (owner ?? focusedTerminal)?.routingTab, fallback: defaultTarget) else {
            NSSound.beep()
            return
        }
        open(target, from: owner)
    }

    /// A new ephemeral VM, in a new tab.
    @objc func newEphemeralTab(_ sender: Any?) {
        open(.ephemeralVM, from: owner(sender))
    }

    @objc func newHostTab(_ sender: Any?) {
        open(.host, from: owner(sender))
    }

    /// Open VM ▸ <name>: a tab on it in the window it was chosen in.
    @objc func newTabInVM(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? OpenVMChoice else { return }
        open(.vm(choice.name), from: choice.owner)
    }

    func openTab(in vm: RemoteVM) {
        open(.vm(vm.name))
    }

    /// Shell ▸ New VM…: the Virtual Machines window with its New VM sheet.
    @objc func showNewVM(_ sender: Any?) {
        NewVMRequest.shared.pending = true
        showVMManager(sender)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(showFocusedVMSettings(_:)) {
            item.title = TabRouting.settingsTitle(focused: focusedTab)
            return TabRouting.settingsVM(focused: focusedTab).flatMap { HostAgent.client.vm(named: $0) } != nil
        }
        guard item.action == #selector(newTab(_:)) else { return true }
        item.title = TabRouting.newTabTitle(focused: focusedTab, fallback: defaultTarget,
                                            defaultVM: HostAgent.client.defaultVM?.name)
        return TabRouting.newTab(focused: focusedTab, fallback: defaultTarget) != nil
    }

    /// VM › "<vm> Settings…": the settings of the VM in front.
    @objc func showFocusedVMSettings(_ sender: Any?) {
        guard let vm = TabRouting.settingsVM(focused: focusedTab).flatMap({ HostAgent.client.vm(named: $0) }) else { return }
        showDetails(of: vm)
    }

    @objc func stopAllVMs(_ sender: Any?) {
        Task { @MainActor in
            do {
                try await HostAgent.client.stopAll()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not stop the VMs"
                alert.informativeText = HostAgent.describe(error)
                alert.runModal()
            }
        }
    }

    @objc func showVMManager(_ sender: Any?) {
        if managerWindow == nil {
            let host = NSHostingController(rootView: VMManagerView(host: HostAgent.client))
            let w = NSWindow(contentViewController: host)
            w.title = "Virtual Machines"
            w.setContentSize(NSSize(width: 760, height: 420))
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.tabbingMode = .disallowed
            w.center()
            managerWindow = w
        }
        managerWindow?.makeKeyAndOrderFront(nil)
    }

    /// The VMs and networks on one map (docs/CANVAS.md).
    @objc func showCanvas(_ sender: Any?) {
        if canvasController == nil {
            let controller = CanvasWindowController()
            controller.window?.center()
            canvasController = controller
        }
        canvasController?.window?.makeKeyAndOrderFront(nil)
    }

    /// The VM's window, opened on `page` (one already open is only brought
    /// forward: it may hold unsaved edits).
    func showDetails(of vm: RemoteVM, page: VMDetailView.Page = .overview) {
        if let w = detailWindows[vm.name], w.isVisible || w.isMiniaturized {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let view = VMDetailView(vm: vm, host: HostAgent.client, page: page)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        // Sized up front: SwiftUI would otherwise size it after the first render.
        w.setContentSize(VMDetailView.size)
        w.title = vm.name
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.center()
        detailWindows[vm.name] = w
        w.makeKeyAndOrderFront(nil)
    }

    /// View ▸ Theme: this tab's own theme (nil: its VM's or the app default).
    @objc func selectTabTheme(_ sender: NSMenuItem) {
        guard let tab = (NSApp.keyWindow?.windowController as? TerminalWindowController)?.focusedSession else { return }
        tab.themeOverride = sender.representedObject as? String
    }

    @objc func showThemeEditor(_ sender: Any?) {
        if themeEditorWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ThemeEditorView(store: ThemeStore.shared)))
            // Sized up front: SwiftUI would otherwise size it after the first render.
            w.setContentSize(ThemeEditorView.size)
            w.title = "Themes"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.tabbingMode = .disallowed
            w.center()
            themeEditorWindow = w
        }
        themeEditorWindow?.makeKeyAndOrderFront(nil)
    }

    /// Settings at `pane`, with the firewall tag `tag` open there.
    func showSettings(pane: SettingsPane, tag: String? = nil) {
        showSettings(nil)
        SettingsRequest.shared.pane = pane
        // The pane appears first, then takes the tag.
        if let tag { DispatchQueue.main.async { SettingsRequest.shared.tag = tag } }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let w = Self.makeSettingsWindow()
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Settings, laid out like a VM's window: a sidebar of areas.
    static func makeSettingsWindow() -> NSWindow {
        let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        w.title = "Settings"
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        // Sized up front so the window never opens empty.
        w.setContentSize(SettingsView.size)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        return w
    }

    @objc func revealInstances(_ sender: Any?) {
        try? Paths.ensurePrivateDirectory(Paths.instances)
        NSWorkspace.shared.open(Paths.instances)
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === themeMenu {
            let tab = (NSApp.keyWindow?.windowController as? TerminalWindowController)?.focusedSession
            ThemeMenu.fill(menu, catalog: ThemeStore.shared.catalog, selected: tab?.themeOverride,
                           action: #selector(selectTabTheme(_:)))
            menu.addItem(.separator())
            menu.addItem(withTitle: "Edit Themes…", action: #selector(showThemeEditor(_:)), keyEquivalent: "")
            return
        }
        if menu.identifier == TerminalWindowController.tabMenuID {
            fillTabMenu(menu, owner: (menu as? TerminalTabMenu)?.owner)
            return
        }
        guard menu === vmTabMenu else { return }
        fillVMMenu(menu, owner: nil)
    }

    /// Open VM ▸: each VM, opened in a new tab of `owner`'s window (the
    /// "…" it is in) or of the window in front.
    private func fillVMMenu(_ menu: NSMenu, owner: TerminalWindowController?) {
        menu.removeAllItems()
        let vms = HostAgent.client.instances.filter { !$0.config.ephemeral }
        if vms.isEmpty {
            menu.addItem(withTitle: "No VMs", action: nil, keyEquivalent: "").isEnabled = false
        }
        for vm in vms {
            let item = menu.addItem(withTitle: vm.name, action: #selector(newTabInVM(_:)), keyEquivalent: "")
            item.representedObject = OpenVMChoice(name: vm.name, owner: owner)
            item.target = self
        }
    }

    /// A "…" (in a tab or the titlebar): the Shell menu's tab and VM items,
    /// a new tab on `owner`'s VM. Shortcuts stay in the Shell menu.
    private func fillTabMenu(_ menu: NSMenu, owner: TerminalWindowController?) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = owner
        }
        add(TabRouting.newTabTitle(focused: owner?.routingTab ?? focusedTab, fallback: defaultTarget,
                                   defaultVM: HostAgent.client.defaultVM?.name), #selector(newTab(_:)))
        let vms = NSMenu(title: "Open VM")
        fillVMMenu(vms, owner: owner)
        menu.addItem(withTitle: "Open VM", action: nil, keyEquivalent: "").submenu = vms
        menu.addItem(.separator())
        add("New Ephemeral VM", #selector(newEphemeralTab(_:)))
        add("New Host Shell (Unisolated)", #selector(newHostTab(_:)))
        menu.addItem(.separator())
        add("New VM…", #selector(showNewVM(_:)))
        // The front tab's VM, when it is a Mac: its desktop.
        if let name = (owner?.routingTab ?? focusedTab)?.vm,
           let vm = HostAgent.client.instances.first(where: { $0.name == name }), vm.config.guestOS == .macos {
            menu.addItem(.separator())
            let item = menu.addItem(withTitle: "Open macOS Desktop", action: vm.isRunning ? #selector(openDesktop(_:)) : nil,
                                    keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.isEnabled = vm.isRunning
        }
    }

    @objc private func openDesktop(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Task { @MainActor in
            do { try await openDesktop(of: name) } catch {
                let alert = NSAlert()
                alert.messageText = "The desktop of “\(name)” could not be opened"
                alert.informativeText = HostAgent.describe(error)
                alert.runModal()
            }
        }
    }

    /// A macOS VM's desktop, in a window MonadHost shows. The first time,
    /// where its password is, and whether Monad should fill it in.
    func openDesktop(of name: String) async throws {
        let host = HostAgent.client
        if let vm = host.instances.first(where: { $0.name == name }), vm.config.desktopAutofill == nil {
            let alert = NSAlert()
            let words = VMSettingsDraft.autofillQuestion(vm: name, user: vm.config.user)
            alert.messageText = words.title
            alert.informativeText = words.message
            alert.addButton(withTitle: "Auto-fill")
            alert.addButton(withTitle: "Don't Auto-fill")
            var c = vm.config
            c.desktopAutofill = alert.runModal() == .alertFirstButtonReturn
            try await host.update(c)
        }
        try await host.openDesktop(name)
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        // Application
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Monad", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let services = NSMenu()
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Monad", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Monad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Monad", action: nil, keyEquivalent: "").submenu = appMenu

        // Shell
        let shell = NSMenu(title: "Shell")
        shell.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        shell.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        let inVM = shell.addItem(withTitle: "Open VM", action: nil, keyEquivalent: "")
        vmTabMenu.delegate = self
        inVM.submenu = vmTabMenu
        shell.addItem(.separator())
        let eph = shell.addItem(withTitle: "New Ephemeral VM", action: #selector(newEphemeralTab(_:)), keyEquivalent: "t")
        eph.keyEquivalentModifierMask = [.command, .shift]
        let hostTab = shell.addItem(withTitle: "New Host Shell (Unisolated)", action: #selector(newHostTab(_:)), keyEquivalent: "n")
        hostTab.keyEquivalentModifierMask = [.command, .option]
        shell.addItem(.separator())
        shell.addItem(withTitle: "New VM…", action: #selector(showNewVM(_:)), keyEquivalent: "")
        shell.addItem(.separator())
        let side = shell.addItem(withTitle: "Split Side by Side", action: #selector(TerminalWindowController.splitSideBySide(_:)),
                                 keyEquivalent: "v")
        side.keyEquivalentModifierMask = [.command, .shift]
        let stacked = shell.addItem(withTitle: "Split Stacked", action: #selector(TerminalWindowController.splitStacked(_:)),
                                    keyEquivalent: "h")
        stacked.keyEquivalentModifierMask = [.command, .shift]
        shell.addItem(.separator())
        shell.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Shell", action: nil, keyEquivalent: "").submenu = shell

        // Edit
        let edit = NSMenu(title: "Edit")
        // The window's undo manager (the canvas, text fields).
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Copy", action: #selector(MonadTerminalView.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(MonadTerminalView.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Clear Scrollback", action: #selector(MonadTerminalView.clearScrollback(_:)), keyEquivalent: "k")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        // View
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Bigger", action: #selector(MonadTerminalView.biggerFont(_:)), keyEquivalent: "+")
        let bigger2 = view.addItem(withTitle: "Bigger", action: #selector(MonadTerminalView.biggerFont(_:)), keyEquivalent: "=")
        bigger2.isHidden = true
        bigger2.allowsKeyEquivalentWhenHidden = true
        view.addItem(withTitle: "Smaller", action: #selector(MonadTerminalView.smallerFont(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Default Font Size", action: #selector(MonadTerminalView.resetFontSize(_:)), keyEquivalent: "0")
        view.addItem(.separator())
        themeMenu.delegate = self
        view.addItem(withTitle: "Theme", action: nil, keyEquivalent: "").submenu = themeMenu
        view.addItem(.separator())
        let fs = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = view

        // VM
        let vmMenu = NSMenu(title: "VM")
        let mgr = vmMenu.addItem(withTitle: "Virtual Machines…", action: #selector(showVMManager(_:)), keyEquivalent: "m")
        mgr.keyEquivalentModifierMask = [.command, .shift]
        let canvas = vmMenu.addItem(withTitle: "Canvas", action: #selector(showCanvas(_:)), keyEquivalent: "k")
        canvas.keyEquivalentModifierMask = [.command, .shift]
        let settings = vmMenu.addItem(withTitle: "VM Settings…", action: #selector(showFocusedVMSettings(_:)), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command, .option]
        vmMenu.addItem(withTitle: "Show Instances Folder", action: #selector(revealInstances(_:)), keyEquivalent: "")
        vmMenu.addItem(.separator())
        // The focused tab's VM (TerminalSessionViewController answers it).
        let restart = vmMenu.addItem(withTitle: "Restart VM", action: #selector(TerminalSessionViewController.restartVM(_:)),
                                     keyEquivalent: "r")
        restart.keyEquivalentModifierMask = [.command, .shift]
        vmMenu.addItem(withTitle: "Stop All VMs", action: #selector(stopAllVMs(_:)), keyEquivalent: "")
        main.addItem(withTitle: "VM", action: nil, keyEquivalent: "").submenu = vmMenu

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        let next = window.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "}")
        next.keyEquivalentModifierMask = [.command]
        let prev = window.addItem(withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "{")
        prev.keyEquivalentModifierMask = [.command]
        window.addItem(withTitle: "Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        window.addItem(.separator())
        // Panes: ⌘ and an arrow.
        let panes: [(String, Selector, Int)] = [
            ("Select Pane on the Left", #selector(TerminalWindowController.selectPaneLeft(_:)), NSLeftArrowFunctionKey),
            ("Select Pane on the Right", #selector(TerminalWindowController.selectPaneRight(_:)), NSRightArrowFunctionKey),
            ("Select Pane Above", #selector(TerminalWindowController.selectPaneAbove(_:)), NSUpArrowFunctionKey),
            ("Select Pane Below", #selector(TerminalWindowController.selectPaneBelow(_:)), NSDownArrowFunctionKey),
        ]
        for (title, action, key) in panes {
            let item = window.addItem(withTitle: title, action: action, keyEquivalent: String(Character(UnicodeScalar(key)!)))
            item.keyEquivalentModifierMask = [.command]
        }
        // A pane's contexts: ⇧⌘ and an arrow, in the order of its Switch Context menu.
        let contexts: [(String, Selector, Int)] = [
            ("Show Previous Context", #selector(TerminalWindowController.showPreviousContext(_:)), NSLeftArrowFunctionKey),
            ("Show Next Context", #selector(TerminalWindowController.showNextContext(_:)), NSRightArrowFunctionKey),
        ]
        for (title, action, key) in contexts {
            let item = window.addItem(withTitle: title, action: action, keyEquivalent: String(Character(UnicodeScalar(key)!)))
            item.keyEquivalentModifierMask = [.command, .shift]
        }
        window.addItem(.separator())
        for n in 1...9 {
            let title = n == 9 ? "Select Last Tab" : "Select Tab \(n)"
            let item = window.addItem(withTitle: title, action: #selector(selectTabByNumber(_:)), keyEquivalent: "\(n)")
            item.tag = n
            item.target = self
        }
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window

        return main
    }
}

/// An Open VM ▸ item: the VM, and the window whose "…" it is in.
private final class OpenVMChoice: NSObject {
    let name: String
    weak var owner: TerminalWindowController?

    init(name: String, owner: TerminalWindowController?) {
        self.name = name
        self.owner = owner
    }
}
