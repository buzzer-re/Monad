//
//  MacDesktop.swift — a macOS VM's desktop: a window on its display, for
//  what needs a person (the developer tools' installer, a system prompt).
//  Shown by the process that runs the VM (MonadHost, which is otherwise
//  never on screen), opened from the VM's ⋯ menu; closing the window
//  leaves the VM running.
//

import AppKit
import CoreImage
import IOSurface
import QuartzCore
import Virtualization

@MainActor
final class MacDesktop {
    static let shared = MacDesktop()

    /// The open windows, by the machine they show.
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    /// Machines Monad is typing into (recovery): their desktop only watches.
    private var driven: Set<ObjectIdentifier> = []
    private var closing: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Opens (or brings forward) the desktop of `machine`, whose queue is
    /// its own: the view reaches it through Apple's adaptor.
    func show(_ machine: VZVirtualMachine, title: String, owner: ObjectIdentifier, actions: [DesktopAction] = [],
              paste: (@MainActor (String) async -> Void)? = nil) throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        if let window = windows[owner] {
            bringForward(window)
            return
        }
        let view = DesktopView()
        view.watchOnly = driven.contains(owner)
        view.paste = paste
        if #available(macOS 27, *) {
            view.adaptor = VZVirtualMachineViewAdaptor(virtualMachine: machine)
        } else {
            throw MonadError("Opening a VM's desktop needs macOS 27 on this Mac.")
        }
        view.capturesSystemKeys = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(title) — macOS Desktop"
        window.contentView = view
        if !actions.isEmpty { window.addTitlebarAccessoryViewController(Self.buttons(actions)) }
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MonadDesktop-\(title)")
        if !window.setFrameUsingName("MonadDesktop-\(title)") { window.center() }
        windows[owner] = window
        closing[owner] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget(owner) }
        }
        bringForward(window)
    }

    /// The VM stopped: its window goes.
    func close(owner: ObjectIdentifier) {
        windows[owner]?.close()
        forget(owner)
        driven.remove(owner)
    }

    /// Monad types into this machine (recovery's steps): its desktop only
    /// watches (a key or click there would land among Monad's) and keeps
    /// the display's size (the steps' clicks are for it).
    func setDriven(_ on: Bool, owner: ObjectIdentifier) {
        if on { driven.insert(owner) } else { driven.remove(owner) }
        (windows[owner]?.contentView as? DesktopView)?.watchOnly = on
    }

    private func forget(_ owner: ObjectIdentifier) {
        windows[owner] = nil
        if let observer = closing.removeValue(forKey: owner) { NotificationCenter.default.removeObserver(observer) }
    }

    /// The actions as buttons at the right of the title bar.
    private static func buttons(_ actions: [DesktopAction]) -> NSTitlebarAccessoryViewController {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        for action in actions {
            let button = ActionButton(title: action.title, target: nil, action: nil)
            button.bezelStyle = .push
            button.controlSize = .small
            button.run = action.run
            button.target = button
            button.action = #selector(ActionButton.clicked)
            stack.addArrangedSubview(button)
        }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = stack
        accessory.layoutAttribute = .trailing
        return accessory
    }

    /// The VM's display; ⌘V brings the Mac's text in (the VM has no
    /// clipboard of the Mac's), every other key goes to the VM.
    private final class DesktopView: VZVirtualMachineView {
        var paste: (@MainActor (String) async -> Void)?
        private let cover = WatchOnlyCover()

        /// Keys and clicks kept from the VM, a banner saying why; the display
        /// not resized to the window meanwhile.
        var watchOnly = false {
            didSet {
                automaticallyReconfiguresDisplay = !watchOnly
                if watchOnly, cover.superview == nil {
                    addSubview(cover)
                    needsLayout = true
                }
                cover.isHidden = !watchOnly
                if watchOnly { window?.makeFirstResponder(cover) }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if watchOnly { window?.makeFirstResponder(cover) }
        }

        override func layout() {
            super.layout()
            cover.frame = bounds
        }

        override func keyUp(with event: NSEvent) { if !watchOnly { super.keyUp(with: event) } }
        override func flagsChanged(with event: NSEvent) { if !watchOnly { super.flagsChanged(with: event) } }

        private func isPaste(_ event: NSEvent) -> Bool {
            event.type == .keyDown && event.charactersIgnoringModifiers?.lowercased() == "v"
                && event.modifierFlags.intersection([.command, .control, .option]) == .command
        }

        private func pasteMacText() {
            guard let paste, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
            Task { @MainActor in await paste(text) }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if watchOnly { return true }
            if paste != nil, isPaste(event) {
                pasteMacText()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func keyDown(with event: NSEvent) {
            if watchOnly { return }
            if paste != nil, isPaste(event) { return pasteMacText() }
            super.keyDown(with: event)
        }
    }

    /// Over the display while Monad types: takes every key and click, and says so.
    private final class WatchOnlyCover: NSView {
        private let label: NSTextField = {
            let l = NSTextField(labelWithString: "Monad is typing in recovery. Watch only until it is done.")
            l.font = .systemFont(ofSize: 13, weight: .semibold)
            l.textColor = .white
            l.alignment = .center
            l.wantsLayer = true
            l.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
            l.layer?.cornerRadius = 8
            return l
        }()

        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(label)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layout() {
            super.layout()
            let width = min(bounds.width - 40, 460)
            label.frame = NSRect(x: (bounds.width - width) / 2, y: bounds.height - 52, width: width, height: 30)
        }

        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : self }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}
        override func mouseDragged(with event: NSEvent) {}
        override func rightMouseDown(with event: NSEvent) {}
        override func otherMouseDown(with event: NSEvent) {}
        override func scrollWheel(with event: NSEvent) {}
        override func keyDown(with event: NSEvent) {}
        override func keyUp(with event: NSEvent) {}
        override func flagsChanged(with event: NSEvent) {}
        override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
    }

    private final class ActionButton: NSButton {
        var run: (@MainActor () async -> Void)?
        @objc func clicked() {
            guard let run else { return }
            Task { @MainActor in await run() }
        }
    }

    private func bringForward(_ window: NSWindow) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// A macOS VM's display read for recovery's waits (MacRecovery.Screen):
/// a view on the machine in a window nobody sees, and the IOSurface its
/// framebuffer layer shows, sampled. Never Apple's screenshot call (it
/// kills the VM without Apple's entitlement).
@MainActor
final class MacScreenReader {
    private let window: NSWindow
    private let view: VZVirtualMachineView

    init?(machine: VZVirtualMachine) {
        guard #available(macOS 27, *) else { return nil }
        NSApplication.shared.setActivationPolicy(.accessory)
        view = VZVirtualMachineView()
        view.adaptor = VZVirtualMachineViewAdaptor(virtualMachine: machine)
        // A window macOS does not draw (fully clear, behind others, on another Space) leaves the
        // framebuffer layer as it was: so it is above other windows, on every Space, nearly clear
        // and tiny, and frames are read only while macOS says it is visible.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 8, height: 5), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.02
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = view
        window.orderFrontRegardless()
    }

    func close() { window.close() }

    /// Whether macOS draws the window (its layer then follows the display).
    var isDrawn: Bool { window.occlusionState.contains(.visible) }

    /// For the VM's log: whether it is drawn, and the framebuffers read.
    var info: String {
        let surfaces = Self.surfaces(in: view)
        guard !surfaces.isEmpty else { return "drawn \(isDrawn), no framebuffer layer" }
        let sizes = surfaces.map { "\(IOSurfaceGetWidth($0))×\(IOSurfaceGetHeight($0))" }.joined(separator: ", ")
        return "drawn \(isDrawn), \(sizes)"
    }

    /// Each framebuffer's grid, one after another (a layer left from before
    /// the display changed stays as it was; the live one still shows its
    /// changes); nil while the window is not drawn (its frames would be stale).
    func screen() -> MacRecovery.Screen? {
        guard isDrawn else { return nil }
        let grids = Self.surfaces(in: view).compactMap(Self.grid)
        return grids.isEmpty ? nil : MacRecovery.Screen(cells: grids.flatMap { $0 })
    }

    /// The live framebuffer (the largest) as a PNG; nil while not drawn.
    func picture() -> Data? {
        guard isDrawn, let surface = Self.surfaces(in: view)
                .max(by: { IOSurfaceGetWidth($0) * IOSurfaceGetHeight($0) < IOSurfaceGetWidth($1) * IOSurfaceGetHeight($1) })
        else { return nil }
        // At most 1280 wide: recovery's text stays readable, and the picture small enough for an agent.
        var image = CIImage(ioSurface: surface)
        let scale = min(1, 1280 / image.extent.width)
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let cg = CIContext().createCGImage(image, from: image.extent.integral) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// The mean brightness of each cell of the grid, from every other
    /// pixel of it (text a few pixels high still moves its cell).
    private static func grid(_ surface: IOSurfaceRef) -> [UInt8]? {
        guard IOSurfaceLock(surface, .readOnly, nil) == 0 else { return nil }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        // BGRA, 8 bits each (what the framebuffer was on the Mac); anything else is not read.
        guard IOSurfaceGetBytesPerElement(surface) == 4, width > 0, height > 0 else { return nil }
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let columns = MacRecovery.Screen.columns, rows = MacRecovery.Screen.rows
        var sums = [Int](repeating: 0, count: columns * rows)
        var counts = [Int](repeating: 0, count: columns * rows)
        for y in stride(from: 0, to: height, by: 2) {
            let row = y * rows / height
            let line = base + y * rowBytes
            for x in stride(from: 0, to: width, by: 2) {
                let p = line + x * 4
                let cell = row * columns + x * columns / width
                sums[cell] += (Int(p[2]) * 54 + Int(p[1]) * 183 + Int(p[0]) * 19) >> 8
                counts[cell] += 1
            }
        }
        return zip(sums, counts).map { UInt8($0 / max($1, 1)) }
    }

    /// Every layer under the view showing an IOSurface (the framebuffers).
    private static func surfaces(in view: NSView) -> [IOSurfaceRef] {
        var found: [IOSurfaceRef] = []
        var seen: Set<ObjectIdentifier> = []
        func collect(_ layer: CALayer?) {
            guard let layer, seen.insert(ObjectIdentifier(layer)).inserted else { return }
            if let contents = layer.contents.map({ $0 as AnyObject }), CFGetTypeID(contents) == IOSurfaceGetTypeID() {
                found.append(unsafeBitCast(contents, to: IOSurfaceRef.self))
            }
            for sub in layer.sublayers ?? [] { collect(sub) }
        }
        var views: [NSView] = [view]
        while let v = views.popLast() {
            collect(v.layer)
            views += v.subviews
        }
        return found
    }
}
