//
//  TerminalTitlebar.swift — the titlebar of a terminal window whose theme
//  lets the desktop show through. Such a window is clear, and macOS 27 no
//  longer paints the titlebar of a clear window: it was see-through, the
//  title over whatever was behind. So the window's content runs under the
//  titlebar (the terminal itself stays below it) and Monad paints the
//  titlebar with the theme's colour over the system blur. Opaque themes
//  keep the system's titlebar as it is. The window's tab strip
//  (TabStripView) sits right under the titlebar, on the same paint.
//

import AppKit

/// How a see-through theme's titlebar is painted.
struct TitlebarStyle: Equatable {
    /// Never fainter than this: the title must stay readable over any desktop.
    static let minimumOpacity = 0.75

    var color: RGB
    var opacity: Double
    /// Light title text on it.
    var dark: Bool

    /// nil: an opaque theme, the system's titlebar.
    static func of(_ theme: Theme?) -> TitlebarStyle? {
        guard let t = theme, t.backgroundOpacity < 1 || t.blur > 0 else { return nil }
        let c = t.background
        // Relative luminance (sRGB weights), enough to pick the title's colour.
        let luminance = (0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)) / 255
        return TitlebarStyle(color: c, opacity: max(t.backgroundOpacity, minimumOpacity), dark: luminance < 0.5)
    }
}

/// The painted titlebar: the system blur, the theme's colour over it.
final class TitlebarBackdropView: NSView {
    private let blur = NSVisualEffectView()
    private let tint = NSView()

    var style: TitlebarStyle? {
        didSet { refresh() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        blur.frame = bounds
        blur.autoresizingMask = [.width, .height]
        blur.blendingMode = .behindWindow
        blur.material = .titlebar
        blur.state = .active
        tint.frame = bounds
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        addSubview(blur)
        addSubview(tint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { false }

    private func refresh() {
        guard let style else { return }
        tint.layer?.backgroundColor = style.color.cgColor(alpha: CGFloat(style.opacity))
        blur.appearance = NSAppearance(named: style.dark ? .darkAqua : .aqua)
    }
}

/// A terminal window's content: the tab strip once it shows, the panes of
/// the tab in front below it, and under a painted titlebar the backdrop
/// that paints it (the tab strip's room too: they read as one bar).
final class TerminalWindowContentView: NSView {
    /// Holds the panes of the tab in front.
    let terminals = NSView(frame: .zero)
    let tabStrip: NSView
    let strip = TitlebarBackdropView(frame: .zero)
    private(set) var painted = false
    private var layoutObserver: NSKeyValueObservation?

    /// The tab strip shows (a window with one tab and no group has none).
    var showsTabStrip = false {
        didSet {
            guard showsTabStrip != oldValue else { return }
            tabStrip.isHidden = !showsTabStrip
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    init(tabStrip: NSView, frame: NSRect) {
        self.tabStrip = tabStrip
        super.init(frame: frame)
        strip.isHidden = true
        tabStrip.isHidden = true
        addSubview(terminals)
        addSubview(strip)
        addSubview(tabStrip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { false }

    /// The panes of the tab in front, in place of the ones before.
    func show(_ panes: NSView) {
        guard panes.superview !== terminals else { return }
        terminals.subviews.forEach { $0.removeFromSuperview() }
        panes.frame = terminals.bounds
        panes.autoresizingMask = [.width, .height]
        terminals.addSubview(panes)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Full screen and the toolbar moving change the titlebar's edge.
        layoutObserver = window?.observe(\.contentLayoutRect) { [weak self] _, _ in
            DispatchQueue.main.async { self?.needsLayout = true }
        }
    }

    /// A see-through theme's titlebar (nil: the system's).
    func apply(_ style: TitlebarStyle?, to window: NSWindow) {
        painted = style != nil
        if window.styleMask.contains(.fullSizeContentView) != painted {
            if painted { window.styleMask.insert(.fullSizeContentView) } else { window.styleMask.remove(.fullSizeContentView) }
        }
        window.titlebarAppearsTransparent = painted
        window.appearance = style.map { NSAppearance(named: $0.dark ? .darkAqua : .aqua) } ?? nil
        strip.style = style
        strip.isHidden = !painted
        needsLayout = true
    }

    /// How much taller the window is than its terminal area while painted.
    var titlebarHeight: CGFloat {
        guard painted, let window else { return 0 }
        return max(0, window.frame.height - window.contentLayoutRect.height)
    }

    override func layout() {
        super.layout()
        var inner = bounds
        if painted, let window { inner = convert(window.contentLayoutRect, from: nil) }
        let bar = showsTabStrip ? min(TabStripLayout.height, inner.height) : 0
        tabStrip.frame = NSRect(x: inner.minX, y: inner.maxY - bar, width: inner.width, height: bar)
        terminals.frame = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height - bar)
        strip.frame = NSRect(x: bounds.minX, y: inner.maxY - bar, width: bounds.width, height: max(0, bounds.maxY - inner.maxY + bar))
    }
}
