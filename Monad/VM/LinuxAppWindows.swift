//
//  LinuxAppWindows.swift — a Linux VM's programs as windows on the Mac:
//  one Mac window for each window the VM's window manager tells
//  (GuestWindowProtocol.swift), shown by the process that runs the VM
//  (MonadHost), like the VM's desktop (MacDesktop.swift).
//
//  The VM has one display, on which every window has a place of its own.
//  Each Mac window holds a view of that display, as large as the display
//  and moved behind the window so that only the window's place is inside
//  it (GuestWindowLayout.swift): the pixels go from the VM to the screen
//  as they do for the desktop, with no copy made here. That view takes no
//  keys and no clicks, and never resizes the display: the pointer and the
//  keys go to the window manager over Monad's channel, as the window they
//  are for.
//
//  The guest decides which windows there are and what they are called, so:
//  a title always ends with the VM's name; a new window comes in front and
//  takes the keys only when the user is in Monad already (one of these
//  windows, or the app), and otherwise opens without them; and the number
//  of windows is the protocol's bound. The Mac's clipboard is the VM's to
//  read or set only on the user's ⌘V and ⌘C here (GuestClipboard.swift).
//

import AppKit
import Carbon.HIToolbox
import Virtualization

/// What shows a Linux VM's program windows, and says what the Mac's
/// pointer and keys do in them. The tests put a recorder in its place.
@MainActor
protocol GuestWindowPresenting: AnyObject {
    /// What to tell the window manager.
    var onCommand: ((GuestWindowCommand) -> Void)? { get set }
    /// The window manager answered: it is told the screen's scale and the keys.
    func connected(display: GuestDisplaySize)
    /// All the windows there are now.
    func show(_ windows: [GuestWindow])
    /// The window manager says what was copied in the VM (nothing: something the Mac cannot have).
    func copied(_ text: String)
    /// How the pointer is to look over these windows (a number of GuestCursor's).
    func cursor(_ shape: Int)
    /// The program of a window asks something of it (to be moved, zoomed, put away).
    func asked(window: UInt32, _ ask: GuestWindowAsk)
    /// The window manager is gone: so are its windows.
    func disconnected()
}

/// The Mac's clipboard as these windows read and set it. The Debug tools
/// put one of their own in its place, so that working on Monad never
/// reads or replaces what the user copied.
struct MacClipboard {
    /// The Mac's count of what was put on it.
    var changeCount: () -> Int
    var text: () -> String?
    var set: (String) -> Void
    var standsIn = false

    static let general = MacClipboard(
        changeCount: { NSPasteboard.general.changeCount },
        text: { NSPasteboard.general.string(forType: .string) },
        set: { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        })

    /// One that is nobody's but its holder's, with `text` on it, put
    /// there after what `count` counted (the Mac's count never goes back).
    static func standIn(holding text: String, after count: Int) -> MacClipboard {
        final class Held {
            var count: Int
            var text: String
            init(_ text: String, _ count: Int) {
                self.text = text
                self.count = count
            }
        }
        let held = Held(text, count + 1)
        return MacClipboard(changeCount: { held.count }, text: { held.text }, set: { text in
            held.text = text
            held.count += 1
        }, standsIn: true)
    }
}

/// The VM's display behind the window of one of its programs: to look at,
/// and nothing else. Apple's view takes the pointer for the guest's own
/// pointing device and hides the Mac's pointer while it is over the view
/// (-[VZVirtualMachineView mouseEntered:] ends in +[NSCursor hide] when
/// the guest shows no cursor of its own, and Monad's window manager shows
/// none). Here the pointer and the keys are Monad's to pass on, as the
/// window they are for, and the pointer stays the Mac's: this view watches
/// no pointer and takes no keys.
final class GuestDisplayView: VZVirtualMachineView {
    override var acceptsFirstResponder: Bool { false }
    override func addTrackingArea(_ trackingArea: NSTrackingArea) {}
    override func mouseEntered(with event: NSEvent) {}
    override func mouseExited(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {}
}

@MainActor
final class LinuxAppWindows: NSObject, GuestWindowPresenting, NSWindowDelegate {
    var onCommand: ((GuestWindowCommand) -> Void)?

    private let machine: VZVirtualMachine
    private let vmName: String
    private var display = GuestDisplaySize(width: 1, height: 1)
    private var windows: [GuestWindow] = []
    private var shown: [UInt32: Shown] = [:]
    private var keyMonitor: Any?
    private var layoutObserver: NSObjectProtocol?
    /// What the window manager was last told, to say only what changes.
    private var saidScale = 0
    private var saidModifiers = MacKeys.Modifiers(held: 0, locked: 0)
    private var saidFocus: UInt32 = 0
    private var saidPointer: UInt32 = 0
    private var keysDown: Set<UInt32> = []
    private var buttonsDown: Set<UInt32> = []
    /// The window the user last clicked or typed in, and when: what a
    /// program asks of its window is done only as the user's doing.
    private var lastInput: (window: UInt32, at: Date)?
    /// The press that may turn out to begin a drag of the window, by the bar its program drew.
    private var lastPress: NSEvent?
    /// Where the next new window goes.
    private var cascade = NSPoint.zero
    private var clipboard = GuestClipboard()
    private var board = MacClipboard.general
    /// How the pointer looks over these windows: the word of the program it is over.
    fileprivate var pointerCursor = GuestCursor.arrow

    private struct Shown {
        let window: NSWindow
        let content: Content
        let display: NSView
        /// A menu or another popup: a window of no frame, on the window it belongs to.
        var isPopup = false
        /// The size it is being given here, not by the user: not to be said back.
        var applying = false
        /// A popup's shape as its window is cut now.
        var shape: [GuestWindowBand] = []
    }

    /// A popup's window: it never takes the keys from the window it is on.
    private final class PopupWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    init(machine: VZVirtualMachine, vmName: String) {
        self.machine = machine
        self.vmName = vmName
    }

    // MARK: From the window manager

    func connected(display: GuestDisplaySize) {
        self.display = display
        saidScale = 0
        saidModifiers = MacKeys.Modifiers(held: 0, locked: 0)
        saidFocus = 0
        saidPointer = 0
        keysDown = []
        buttonsDown = []
        clipboard = GuestClipboard() // a window manager that just started holds nothing of the Mac's
        pointerCursor = .arrow
        sayScale()
        sayKeys()
        if layoutObserver == nil {
            // The user picked another keyboard layout: the keys type something else.
            layoutObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.sayKeys() }
            }
        }
    }

    func show(_ list: [GuestWindow]) {
        let changes = GuestWindowLayout.changes(from: windows, to: list)
        windows = list
        for id in changes.closed { close(id) }
        for window in changes.changed { update(window) }
        for window in changes.opened { open(window) }
        if shown.isEmpty { stopKeys() }
    }

    /// Taken as the Mac's clipboard only as the answer to the user's ⌘C in
    /// one of these windows, which the user is still in (GuestClipboard).
    func copied(_ text: String) {
        guard clipboard.copied(text, at: Date(), inFront: saidFocus != 0, changeCount: board.changeCount()) else { return }
        board.set(text)
        clipboard.wrote(changeCount: board.changeCount())
    }

    /// One of the Mac's own cursors, by the program's word for it; set at
    /// once when the Mac's pointer is over the window the program has it in.
    func cursor(_ shape: Int) {
        let cursor = GuestCursor(shape: shape)
        guard cursor != pointerCursor else { return }
        pointerCursor = cursor
        if pointerIsOverItsWindow { cursor.mac.set() }
    }

    /// A program asks for its window to be moved (the user drags the bar
    /// the program drew), zoomed (a double click on it) or put away: done
    /// with the Mac's own window, when the user's hand is on it.
    func asked(window id: UInt32, _ ask: GuestWindowAsk) {
        guard let entry = shown[id], !entry.isPopup,
              GuestWindowLayout.wishIsTheUsers(ask, window: id, lastInputWindow: lastInput?.window ?? 0, lastInputAt: lastInput?.at,
                                               leftButtonDown: buttonsDown.contains(0x110), now: Date()) else { return }
        switch ask {
        case .move:
            guard let press = lastPress, press.window === entry.window else { return }
            // The Mac takes the drag from here: for the program the pointer has left, as Wayland has it.
            buttonsDown = []
            saidPointer = 0
            lastPress = nil
            onCommand?(.pointer(window: 0, x: 0, y: 0))
            entry.window.performDrag(with: press)
        case .zoom:
            // The program is never told its window is as large as it gets (on the Mac that is a
            // size like another), so each double click asks for it again: it goes there and back.
            lastInput = nil
            entry.window.zoom(nil)
        case .minimize:
            entry.window.miniaturize(nil)
        }
    }

    /// A program that draws its own title bar under the Mac's: the Mac's
    /// takes its colour, so that the two read as one bar. Otherwise the
    /// Mac's title bar is as any window's.
    private func applyBar(_ guest: GuestWindow, to window: NSWindow) {
        if let color = guest.ownBar {
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(srgbRed: CGFloat((color >> 16) & 0xff) / 255, green: CGFloat((color >> 8) & 0xff) / 255,
                                             blue: CGFloat(color & 0xff) / 255, alpha: 1)
            window.appearance = NSAppearance(named: GuestWindowLayout.isDark(color) ? .darkAqua : .aqua)
        } else {
            window.titlebarAppearsTransparent = false
            window.backgroundColor = .windowBackgroundColor
            window.appearance = nil
        }
    }

    func disconnected() {
        if pointerIsOverItsWindow, pointerCursor != .arrow { NSCursor.arrow.set() }
        pointerCursor = .arrow
        windows = []
        for id in Array(shown.keys) { close(id) }
        stopKeys()
        if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver) }
        layoutObserver = nil
    }

    private func sayScale() {
        let screens = shown.values.compactMap { $0.window.screen } + [NSScreen.main].compactMap { $0 }
        let scale = Int((screens.map(\.backingScaleFactor).max() ?? 1).rounded())
        guard scale != saidScale else { return }
        saidScale = scale
        onCommand?(.scale(scale))
    }

    private func sayKeys() {
        guard let layout = MacKeys.currentLayout() else { return } // an input method: the keys stay as they were
        onCommand?(.keys(MacKeys.table(layout)))
    }

    // MARK: Windows

    private func open(_ guest: GuestWindow) {
        guard #available(macOS 27, *), shown[guest.id] == nil else { return }
        if guest.isPopup { return openPopup(guest) }
        NSApplication.shared.setActivationPolicy(.accessory)
        let view = GuestDisplayView()
        view.adaptor = VZVirtualMachineViewAdaptor(virtualMachine: machine)
        view.automaticallyReconfiguresDisplay = false // the display is the window manager's to size
        view.capturesSystemKeys = false
        let content = Content(id: guest.id, owner: self)
        content.addSubview(view)
        let size = GuestWindowLayout.contentSize(guest)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        window.title = GuestWindowLayout.title(guest, vm: vmName)
        applyBar(guest, to: window)
        if cascade == .zero, let visible = NSScreen.main?.visibleFrame { cascade = NSPoint(x: visible.minX + 40, y: visible.maxY - 40) }
        cascade = window.cascadeTopLeft(from: cascade)
        shown[guest.id] = Shown(window: window, content: content, display: view)
        view.frame = GuestWindowLayout.displayFrame(guest, display: display)
        startKeys()
        // In front and with the keys only when the user is in Monad already: a
        // program in a VM does not get to take the keys from another app.
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if NSApplication.shared.isActive || frontmost == Flavor.current.appIdentifier {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
        sayScale()
    }

    /// A menu, a tooltip, a list that drops down: a window with no frame,
    /// where the program put it on the window it belongs to, moving with it.
    private func openPopup(_ guest: GuestWindow) {
        guard #available(macOS 27, *), shown[guest.parent] != nil else { return }
        let view = GuestDisplayView()
        view.adaptor = VZVirtualMachineViewAdaptor(virtualMachine: machine)
        view.automaticallyReconfiguresDisplay = false
        view.capturesSystemKeys = false
        let content = Content(id: guest.id, owner: self, popup: true)
        content.addSubview(view)
        let window = PopupWindow(contentRect: NSRect(origin: .zero, size: GuestWindowLayout.contentSize(guest)),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // What the program left open (a menu's round corners, around its
        // arrow) shows what is behind the menu: the window is see-through
        // there, and its shadow follows what is left. The content is in a
        // view counted from the bottom left, as the layer that cuts it is.
        let holder = NSView(frame: NSRect(origin: .zero, size: GuestWindowLayout.contentSize(guest)))
        holder.wantsLayer = true
        content.frame = holder.bounds
        content.autoresizingMask = [.width, .height]
        holder.addSubview(content)
        window.contentView = holder
        window.isOpaque = false
        window.backgroundColor = .clear
        window.acceptsMouseMovedEvents = true
        window.hasShadow = true
        shown[guest.id] = Shown(window: window, content: content, display: view, isPopup: true)
        view.frame = GuestWindowLayout.displayFrame(guest, display: display)
        placePopup(guest)
        cut(guest)
    }

    /// Cuts a popup's window to the shape the program drew.
    private func cut(_ guest: GuestWindow) {
        guard var entry = shown[guest.id], entry.isPopup, let layer = entry.content.superview?.layer else { return }
        guard entry.shape != guest.shape || (layer.mask == nil) != guest.shape.isEmpty else { return }
        if let rects = GuestWindowLayout.shape(guest) {
            let height = GuestWindowLayout.contentSize(guest).height
            let path = CGMutablePath()
            for rect in rects { path.addRect(CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)) }
            let mask = CAShapeLayer()
            mask.path = path
            layer.mask = mask
        } else {
            layer.mask = nil
        }
        entry.shape = guest.shape
        shown[guest.id] = entry
        entry.window.invalidateShadow()
    }

    /// Puts a popup where the program said, from the top left of the window
    /// it is on; one that would not touch that window is not shown (it has
    /// no title to say whose it is).
    private func placePopup(_ guest: GuestWindow) {
        guard let entry = shown[guest.id], entry.isPopup, let parent = shown[guest.parent], let on = self.guest(guest.parent) else { return }
        let offset = GuestWindowLayout.popupOffset(guest, on: on), size = GuestWindowLayout.contentSize(guest)
        guard GuestWindowLayout.popupTouches(offset: offset, size: size, window: parent.content.bounds.size) else {
            entry.window.parent?.removeChildWindow(entry.window)
            entry.window.orderOut(nil)
            return
        }
        // The content is counted from its top left; the screen from its bottom left.
        let corner = parent.window.convertPoint(toScreen: parent.content.convert(NSPoint(x: offset.x, y: offset.y), to: nil))
        entry.window.setFrame(NSRect(x: corner.x, y: corner.y - size.height, width: size.width, height: size.height), display: true)
        if entry.window.parent == nil { parent.window.addChildWindow(entry.window, ordered: .above) }
    }

    /// The popups on a window (and theirs) go where it now is.
    private func placePopups(on id: UInt32) {
        for guest in windows where guest.parent == id {
            placePopup(guest)
            placePopups(on: guest.id)
        }
    }

    private func update(_ guest: GuestWindow) {
        guard var entry = shown[guest.id] else { return }
        entry.display.frame = GuestWindowLayout.displayFrame(guest, display: display)
        if entry.isPopup {
            placePopup(guest)
            cut(guest)
        } else {
            entry.window.title = GuestWindowLayout.title(guest, vm: vmName)
            applyBar(guest, to: entry.window)
            // While the user drags its edge the Mac's window is the user's; it takes the program's size when they let go.
            if !entry.window.inLiveResize { fit(&entry, to: guest) }
            shown[guest.id] = entry
        }
        placePopups(on: guest.id)
    }

    /// Gives the Mac's window the program's size, its top left staying where it is.
    private func fit(_ entry: inout Shown, to guest: GuestWindow) {
        let size = GuestWindowLayout.contentSize(guest)
        guard let content = entry.window.contentView, abs(content.frame.width - size.width) > 0.01 || abs(content.frame.height - size.height) > 0.01
        else { return }
        let old = entry.window.frame
        var frame = entry.window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        entry.applying = true
        shown[guest.id] = entry
        entry.window.setFrame(frame, display: true)
        entry.applying = false
    }

    private func close(_ id: UInt32) {
        // The window under the pointer goes, and with it how the pointer looked there.
        if saidPointer == id, pointerCursor != .arrow, pointerIsOverItsWindow { NSCursor.arrow.set() }
        guard let entry = shown.removeValue(forKey: id) else { return }
        entry.window.delegate = nil
        entry.window.parent?.removeChildWindow(entry.window)
        entry.window.close()
        if saidFocus == id { saidFocus = 0 }
        if saidPointer == id { saidPointer = 0 }
    }

    private func id(of window: NSWindow?) -> UInt32? {
        guard let window else { return nil }
        return shown.first { $0.value.window === window }?.key
    }

    private func guest(_ id: UInt32) -> GuestWindow? { windows.first { $0.id == id } }

    // MARK: NSWindowDelegate

    /// The red button asks the program to close its window; the window goes when the program's does.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let id = id(of: sender) { onCommand?(.close(window: id)) }
        return false
    }

    /// The user turned to something else (the window's frame, another
    /// window, another app): a menu left up is done with, as on the Mac.
    private func dismissPopups(of window: NSWindow?) {
        guard let id = id(of: window), windows.contains(where: { $0.parent == id }) else { return }
        onCommand?(.dismiss(window: id))
    }

    func windowWillMove(_ notification: Notification) { dismissPopups(of: notification.object as? NSWindow) }
    func windowWillStartLiveResize(_ notification: Notification) { dismissPopups(of: notification.object as? NSWindow) }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = id(of: window), let entry = shown[id], !entry.isPopup else { return }
        placePopups(on: id)
        guard !entry.applying, let size = window.contentView?.frame.size else { return }
        onCommand?(.size(window: id, width: max(1, Int(size.width.rounded())), height: max(1, Int(size.height.rounded()))))
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = id(of: window), var entry = shown[id], let guest = guest(id) else { return }
        fit(&entry, to: guest)
        shown[id] = entry
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let id = id(of: notification.object as? NSWindow) else { return }
        say(NSEvent.modifierFlags)
        sayFocus(id)
    }

    private func sayFocus(_ id: UInt32) {
        guard saidFocus != id else { return }
        saidFocus = id
        onCommand?(.focus(window: id))
    }

    func windowDidResignKey(_ notification: Notification) {
        dismissPopups(of: notification.object as? NSWindow)
        // What is held stays with the window that had it: for the VM, every key comes up.
        releaseKeys()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.id(of: NSApplication.shared.keyWindow) == nil, self.saidFocus != 0 else { return }
            self.saidFocus = 0
            self.onCommand?(.focus(window: 0))
        }
    }

    func windowDidChangeBackingProperties(_ notification: Notification) { sayScale() }
    func windowDidChangeScreen(_ notification: Notification) { sayScale() }

    // MARK: Keys

    private func startKeys() {
        guard keyMonitor == nil else { return }
        // Every key of these windows, before AppKit makes anything of it: a key
        // held with Command never comes up otherwise, and keys with Command
        // would go looking for a menu.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.key(event) ?? false } ? nil : event
        }
    }

    private func stopKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// True when the event was one of these windows' and is dealt with.
    private func key(_ event: NSEvent) -> Bool {
        guard let window = event.window, id(of: window) != nil, window.isKeyWindow else { return false }
        return key(event, in: window)
    }

    private func key(_ event: NSEvent, in window: NSWindow) -> Bool {
        switch event.type {
        case .flagsChanged:
            say(event.modifierFlags)
            if let down = MacKeys.modifierIsDown(keyCode: event.keyCode, flags: event.modifierFlags), event.keyCode != UInt16(kVK_CapsLock),
               let code = MacKeys.linuxCode(event.keyCode) {
                sayKey(code, down: down)
            }
        case .keyDown:
            if event.modifierFlags.contains(.command), let own = ownShortcut(event, window) {
                own()
                return true
            }
            say(event.modifierFlags)
            if !event.isARepeat, let code = MacKeys.linuxCode(event.keyCode) {
                if event.modifierFlags.contains(.command) { meetClipboards(event) } // before the program hears the key
                if let id = id(of: window) { lastInput = (id, Date()) }
                sayKey(code, down: true)
            }
        case .keyUp:
            if let code = MacKeys.linuxCode(event.keyCode) { sayKey(code, down: false) }
        default:
            return false
        }
        return true
    }

    /// ⌘V: the VM is given the Mac's text when that is the newer of the
    /// two clipboards. ⌘C, ⌘X: the window manager is asked for what the
    /// program copies next. Nothing else brings the two together.
    private func meetClipboards(_ event: NSEvent) {
        let typed = [event.characters, event.charactersIgnoringModifiers].compactMap { $0 }.first { !$0.isEmpty }
        switch GuestClipboard.shortcut(typed: typed) {
        case .paste:
            switch clipboard.paste(changeCount: board.changeCount(), text: board.text()) {
            case .send(let text): onCommand?(.paste(text))
            case .refuse: NSSound.beep()
            case .keep: break
            }
        case .copy:
            clipboard.copyPressed(at: Date())
            onCommand?(.copy)
        case nil:
            break
        }
    }

    /// The shortcuts that are the Mac's about a window, not the program's:
    /// ⌘M, ⌘H and ⌘` (MonadHost has no menus to hold them).
    private func ownShortcut(_ event: NSEvent, _ window: NSWindow) -> (() -> Void)? {
        switch Int(event.keyCode) {
        case kVK_ANSI_M: return { window.miniaturize(nil) }
        case kVK_ANSI_H: return { NSApplication.shared.hide(nil) }
        case kVK_ANSI_Grave:
            return { [weak self] in
                guard let self else { return }
                let order = NSApplication.shared.orderedWindows.filter { self.id(of: $0) != nil && $0.isVisible }
                (order.last(where: { $0 !== window }))?.makeKeyAndOrderFront(nil)
            }
        default: return nil
        }
    }

    private func say(_ flags: NSEvent.ModifierFlags) {
        let modifiers = MacKeys.modifiers(flags)
        guard modifiers != saidModifiers else { return }
        saidModifiers = modifiers
        onCommand?(.modifiers(held: modifiers.held, locked: modifiers.locked))
    }

    private func sayKey(_ code: UInt32, down: Bool) {
        guard down ? keysDown.insert(code).inserted : keysDown.remove(code) != nil else { return }
        onCommand?(.key(code: code, down: down))
    }

    private func releaseKeys() {
        for code in keysDown.sorted() { onCommand?(.key(code: code, down: false)) }
        keysDown = []
    }

    // MARK: Pointer (from a window's content)

    fileprivate func pointer(_ id: UInt32, at point: NSPoint) {
        guard let guest = guest(id) else { return }
        let position = GuestWindowLayout.pointer(point, in: guest)
        saidPointer = id
        onCommand?(.pointer(window: id, x: position.x, y: position.y))
    }

    fileprivate func pointerLeft(_ id: UInt32) {
        // While a button is down the window keeps the pointer, wherever it is dragged.
        guard buttonsDown.isEmpty, saidPointer == id else { return }
        saidPointer = 0
        if pointerCursor != .arrow { NSCursor.arrow.set() } // what it looked like in the window it does not outside it
        onCommand?(.pointer(window: 0, x: 0, y: 0))
    }

    /// Whether the Mac's pointer is over the content of the window the VM was told it is in.
    private var pointerIsOverItsWindow: Bool {
        guard let entry = shown[saidPointer] else { return false }
        return entry.content.bounds.contains(entry.content.convert(entry.window.mouseLocationOutsideOfEventStream, from: nil))
    }

    fileprivate func button(_ id: UInt32, number: Int, down: Bool, at point: NSPoint, inside: Bool, flags: NSEvent.ModifierFlags,
                            event: NSEvent? = nil) {
        guard let code = GuestWindowLayout.button(number) else { return }
        guard down ? buttonsDown.insert(code).inserted : buttonsDown.remove(code) != nil else { return }
        if down {
            lastInput = (id, Date())
            if number == 0 { lastPress = event }
        }
        say(flags)
        pointer(id, at: point)
        onCommand?(.button(code: code, down: down))
        if !down, !inside { pointerLeft(id) } // let go outside the window it was dragged from
    }

    fileprivate func scroll(_ id: UInt32, event: NSEvent, at point: NSPoint) {
        let delta = GuestWindowLayout.scroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
        guard delta.dx != 0 || delta.dy != 0 else { return }
        if saidPointer != id { pointer(id, at: point) }
        onCommand?(.scroll(dx: delta.dx, dy: delta.dy))
    }

    /// A window's content: the display behind it, and the pointer over it.
    /// Counted from its top left, as the display is.
    private final class Content: NSView {
        private let id: UInt32
        private let popup: Bool
        private weak var owner: LinuxAppWindows?
        private var tracking: NSTrackingArea?

        init(id: UInt32, owner: LinuxAppWindows, popup: Bool = false) {
            self.id = id
            self.popup = popup
            self.owner = owner
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.backgroundColor = NSColor.black.cgColor
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        /// A menu's first click is a choice, not a way to bring its window forward.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { popup }
        /// The display's view is to look at: the pointer is this view's.
        override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            // A popup's window is never the key window: the pointer over it counts all the same.
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                                             popup ? .activeAlways : .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        /// The pointer came over the window: it looks as the program under it said.
        override func cursorUpdate(with event: NSEvent) { (owner?.pointerCursor ?? .arrow).mac.set() }

        private func here(_ event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }

        private func press(_ event: NSEvent, down: Bool) {
            let point = here(event)
            owner?.button(id, number: event.buttonNumber, down: down, at: point, inside: bounds.contains(point), flags: event.modifierFlags,
                          event: event)
        }

        override func mouseEntered(with event: NSEvent) { owner?.pointer(id, at: here(event)) }
        override func mouseExited(with event: NSEvent) { owner?.pointerLeft(id) }
        override func mouseMoved(with event: NSEvent) { owner?.pointer(id, at: here(event)) }
        override func mouseDragged(with event: NSEvent) { owner?.pointer(id, at: here(event)) }
        override func rightMouseDragged(with event: NSEvent) { owner?.pointer(id, at: here(event)) }
        override func otherMouseDragged(with event: NSEvent) { owner?.pointer(id, at: here(event)) }
        override func mouseDown(with event: NSEvent) { press(event, down: true) }
        override func mouseUp(with event: NSEvent) { press(event, down: false) }
        override func rightMouseDown(with event: NSEvent) { press(event, down: true) }
        override func rightMouseUp(with event: NSEvent) { press(event, down: false) }
        override func otherMouseDown(with event: NSEvent) { press(event, down: true) }
        override func otherMouseUp(with event: NSEvent) { press(event, down: false) }
        override func scrollWheel(with event: NSEvent) { owner?.scroll(id, event: event, at: here(event)) }
    }
}

#if DEBUG
/// For working on Monad (the read_windows and drive_window tools): what
/// the windows are and hold, and what a click or a key in one of them
/// becomes, without the screen being looked at or the user's keys taken.
extension LinuxAppWindows {
    /// Each window: its id, title, frame, and where the display lies behind it.
    var debugText: String {
        guard !shown.isEmpty else { return "No windows." }
        return shown.keys.sorted().compactMap { id -> String? in
            guard let entry = shown[id] else { return nil }
            let frame = entry.window.frame, content = entry.content.frame.size, display = entry.display.frame
            let surfaces = MacScreenReader.surfaces(in: entry.display).map { "\(IOSurfaceGetWidth($0))×\(IOSurfaceGetHeight($0))" }
            let bar = guest(id)?.ownBar.map { String(format: "the program's, #%06x", $0) } ?? "the Mac's"
            return "window \(id) “\(entry.window.title)” at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))"
                + ", content \(content.width)×\(content.height), display behind it at \(display.minX),\(display.minY) \(display.width)×\(display.height)"
                + ", visible \(entry.window.isVisible), drawn \(entry.window.occlusionState.contains(.visible)), key \(entry.window.isKeyWindow)"
                + ", scale \(entry.window.backingScaleFactor), framebuffers \(surfaces.isEmpty ? "none" : surfaces.joined(separator: ", "))"
                + (entry.isPopup ? "" : ", title bar \(bar), zoomed \(entry.window.isZoomed), put away \(entry.window.isMiniaturized)")
        }.joined(separator: "\n") + "\npointer: \(pointerCursor)"
            + (board.standsIn ? "\nclipboard (a stand-in for the Mac's): “\(board.text() ?? "")”" : "")
    }

    /// The window's own frame as AppKit draws it (title bar, buttons), with
    /// the content left as its background: what the Mac adds around the
    /// program's picture, without the screen being looked at.
    func debugFramePicture(window id: UInt32) -> Data? {
        guard let entry = shown[id] else { return nil }
        if entry.isPopup { return debugCutPicture(entry) }
        guard let frame = entry.window.contentView?.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// A popup's window as it is cut: black where the display shows, clear where the window is open.
    private func debugCutPicture(_ entry: Shown) -> Data? {
        guard let holder = entry.content.superview, let layer = holder.layer else { return nil }
        let scale = entry.window.backingScaleFactor
        let width = Int(holder.bounds.width * scale), height = Int(holder.bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return context.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }

    /// What a window's view of the display holds, cut to what the window
    /// shows of it: the framebuffer its layer has now, not the screen.
    func debugPicture(window id: UInt32) -> Data? {
        guard let entry = shown[id],
              let surface = MacScreenReader.surfaces(in: entry.display)
                .max(by: { IOSurfaceGetWidth($0) * IOSurfaceGetHeight($0) < IOSurfaceGetWidth($1) * IOSurfaceGetHeight($1) })
        else { return nil }
        let display = entry.display.frame, content = entry.content.bounds
        guard display.width > 0, display.height > 0 else { return nil }
        var image = CIImage(ioSurface: surface)
        let sx = image.extent.width / display.width, sy = image.extent.height / display.height
        // The content's rectangle in the framebuffer, whose rows Core Image counts from the bottom.
        let left = (content.minX - display.minX) * sx, top = (content.minY - display.minY) * sy
        let crop = CGRect(x: left, y: image.extent.height - top - content.height * sy, width: content.width * sx, height: content.height * sy)
        image = image.settingAlphaOne(in: image.extent).cropped(to: crop.intersection(image.extent))
        guard !image.extent.isEmpty, let cg = CIContext().createCGImage(image, from: image.extent.integral) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// Does in a window what the user could: "focus", "move" and "click"
    /// (at x, y from the content's top left), "scroll" (by x, y), "type"
    /// (text, through this Mac's layout), "key" (a Mac key code, with
    /// "command", "shift", "option" or "control"), "resize" (to x by y) and
    /// "close". The Mac's own pointer and keyboard are left alone, and no
    /// other app loses the keys. "clipboard" puts a clipboard holding
    /// `text` in the place of the Mac's for these windows, until the VM
    /// stops: ⌘V and ⌘C are then tried without what the user copied being
    /// read or replaced.
    func debugDrive(window id: UInt32, action: String, x: Double, y: Double, text: String, keyCode: Int) throws {
        guard let entry = shown[id] else { throw MonadError("There is no window \(id).") }
        let point = NSPoint(x: x, y: y)
        switch action {
        case "focus":
            sayFocus(id) // as if it were the key window, without taking the keys from the app the user is in
        case "move":
            pointer(id, at: point)
        case "click":
            button(id, number: 0, down: true, at: point, inside: true, flags: [])
            button(id, number: 0, down: false, at: point, inside: true, flags: [])
        case "scroll":
            let delta = GuestWindowLayout.scroll(deltaX: x, deltaY: y, precise: true)
            onCommand?(.scroll(dx: delta.dx, dy: delta.dy))
        case "type":
            guard let layout = MacKeys.currentLayout() else { throw MonadError("This Mac's input source has no key layout.") }
            for character in text {
                let wanted = MacKeys.Output.text(character == "\n" ? "\r" : String(character))
                var found: (UInt16, NSEvent.ModifierFlags)?
                for (key, _) in MacKeys.linuxCodes.sorted(by: { $0.key < $1.key }) where found == nil {
                    if layout(key, .plain) == wanted { found = (key, []) }
                    else if layout(key, .shift) == wanted { found = (key, NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2)) }
                    else if layout(key, .option) == wanted { found = (key, NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)) }
                }
                if character == "\n" { found = (UInt16(kVK_Return), []) }
                guard let (key, flags) = found else { throw MonadError("This Mac's layout has no key for “\(character)”.") }
                try debugPress(key, flags, in: entry.window)
            }
        case "key":
            var flags: NSEvent.ModifierFlags = []
            if text.contains("command") { flags.formUnion(NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x8)) }
            if text.contains("shift") { flags.formUnion(NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2)) }
            if text.contains("option") { flags.formUnion(NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)) }
            if text.contains("control") { flags.formUnion(NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.control.rawValue | 0x1)) }
            try debugPress(UInt16(clamping: keyCode), flags, in: entry.window)
        case "resize":
            entry.window.setContentSize(NSSize(width: x, height: y))
        case "close":
            entry.window.performClose(nil)
        case "clipboard":
            board = .standIn(holding: text, after: board.changeCount())
        default:
            throw MonadError("There is no action “\(action)”.")
        }
    }

    /// A key going down and up with those modifiers held, as the keyboard's events would say it.
    private func debugPress(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, in window: NSWindow) throws {
        // What the key types plain, as the keyboard's events say it (⌘V is told from it).
        var typed = ""
        if case .text(let text)? = MacKeys.currentLayout()?(keyCode, .plain) { typed = text }
        func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: typed, charactersIgnoringModifiers: typed,
                                               isARepeat: false, keyCode: keyCode) else { throw MonadError("No key event could be made.") }
            return event
        }
        say(flags)
        _ = key(try event(.keyDown, flags), in: window)
        _ = key(try event(.keyUp, flags), in: window)
        say([])
    }
}
#endif
