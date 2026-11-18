//
//  KeepAwakeButton.swift — the coffee cup at the far end of a terminal
//  window's titlebar and tab strip: a click turns keeping this Mac awake
//  (KeepAwake) on or off. Off, an empty cup. On, a full one, a little
//  lower, with steam over it: three thin lines that rise and fade in
//  turn. The steam is Core Animation's own, so nothing of Monad runs
//  while it moves; with Reduce Motion it is there and stands still.
//

import AppKit
import Combine

@MainActor
final class KeepAwakeButton: NSView {
    static let size = NSSize(width: 26, height: 22)
    private static let symbolPoints: CGFloat = 12
    /// The room over the cup the steam rises in.
    private static let steamHeight: CGFloat = 6
    /// One wisp's way up, and how long before the next one follows.
    private static let riseSeconds: CFTimeInterval = 2.7
    private static let riseKey = "rise"

    private let state: KeepAwake
    /// The cup and its steam, moved as one.
    private let art = NSView()
    private let cup = NSImageView()
    private let steam = CALayer()
    private var wisps: [CAShapeLayer] = []
    private let highlight = CALayer()
    private var watching: AnyCancellable?
    private var motion: AnyCancellable?
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { refreshHighlight() } }
    private var pressed = false { didSet { refreshHighlight() } }

    /// Steam shows over the cup (it is on).
    private(set) var showsSteam = false
    /// The steam is rising, not standing still.
    var steamMoves: Bool { wisps.contains { $0.animation(forKey: Self.riseKey) != nil } }
    /// Reduce Motion, asked each time the steam starts.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// `state`: the app's one switch unless a test gives its own.
    init(state: KeepAwake? = nil) {
        let state = state ?? .shared
        self.state = state
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        highlight.cornerRadius = 6
        layer?.addSublayer(highlight)
        art.wantsLayer = true
        cup.imageScaling = .scaleNone
        art.addSubview(cup)
        addSubview(art)
        for _ in 0..<3 {
            let wisp = CAShapeLayer()
            wisp.fillColor = nil
            wisp.lineWidth = 1
            wisp.lineCap = .round
            wisp.opacity = 0
            steam.addSublayer(wisp)
            wisps.append(wisp)
        }
        steam.opacity = 0
        art.layer?.addSublayer(steam)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilitySubrole(.toggle)
        setAccessibilityLabel("Keep this Mac awake")
        show(state.isOn, animated: false)
        // dropFirst: what it is now was just shown.
        watching = state.$isOn.dropFirst().sink { [weak self] on in self?.show(on, animated: true) }
        // Reduce Motion turned on or off while the steam shows.
        motion = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshSteam() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: What it shows

    private func show(_ on: Bool, animated: Bool) {
        showsSteam = on
        let image = NSImage(systemSymbolName: on ? "cup.and.saucer.fill" : "cup.and.saucer", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.symbolPoints, weight: .regular))
        if animated, window != nil, let image {
            cup.setSymbolImage(image, contentTransition: .replace)
        } else {
            cup.image = image
        }
        cup.contentTintColor = on ? .labelColor : .secondaryLabelColor
        toolTip = on ? "This Mac is kept awake while Monad is open: its display stays on and it does not sleep or lock by itself. Click to let it sleep again."
            : "Keep this Mac awake: its display stays on and it does not sleep or lock by itself"
        setAccessibilityValue(on ? 1 : 0)
        if animated, window != nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                placeArt()
            }
        } else {
            placeArt()
        }
        refreshSteam()
    }

    /// The cup in the middle while it is alone; with steam, the two
    /// together in the middle.
    private func placeArt() {
        let cupSize = cup.image?.size ?? NSSize(width: 16, height: 13)
        let width = ceil(cupSize.width), cupHeight = ceil(cupSize.height)
        cup.frame = NSRect(x: 0, y: 0, width: width, height: cupHeight)
        let lowered = showsSteam ? Self.steamHeight / 2 : 0
        art.frame = NSRect(x: ((bounds.width - width) / 2).rounded(),
                           y: ((bounds.height - cupHeight) / 2 - lowered).rounded(),
                           width: width, height: cupHeight + Self.steamHeight)
        // Over the cup itself: its handle makes the picture wider on the right.
        steam.frame = NSRect(x: 0, y: cupHeight - 1, width: width - 3, height: Self.steamHeight)
        let h = Self.steamHeight - 1
        for (i, wisp) in wisps.enumerated() {
            let x = steam.bounds.midX + CGFloat(i - 1) * 3.2
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: 0))
            path.addCurve(to: CGPoint(x: x, y: h), control1: CGPoint(x: x + 1.5, y: h * 0.35), control2: CGPoint(x: x - 1.5, y: h * 0.65))
            wisp.frame = steam.bounds
            wisp.path = path
        }
    }

    override func layout() {
        super.layout()
        highlight.frame = bounds.insetBy(dx: 1, dy: 1)
        placeArt()
    }

    /// The steam as it should be now: rising, standing still, or gone.
    private func refreshSteam() {
        let color = resolved(.labelColor)
        steam.opacity = showsSteam ? 1 : 0
        let still = reducesMotion()
        for (i, wisp) in wisps.enumerated() {
            wisp.strokeColor = color
            guard showsSteam, !still else {
                wisp.removeAnimation(forKey: Self.riseKey)
                wisp.opacity = showsSteam ? 0.55 : 0
                continue
            }
            // Seen only while it rises.
            wisp.opacity = 0
            guard wisp.animation(forKey: Self.riseKey) == nil else { continue }
            wisp.add(Self.rise(startingAt: Double(i) / Double(wisps.count)), forKey: Self.riseKey)
        }
    }

    /// One wisp's way up, again and again: it is drawn from the cup
    /// upward, drifts a little higher and thins out from below as it
    /// fades. `startingAt`: how far along it begins (0–1), so the three
    /// follow each other.
    private static func rise(startingAt phase: Double) -> CAAnimation {
        let head = CAKeyframeAnimation(keyPath: "strokeEnd")
        head.values = [0, 1, 1]
        head.keyTimes = [0, 0.5, 1]
        let tail = CAKeyframeAnimation(keyPath: "strokeStart")
        tail.values = [0, 0, 0.85]
        tail.keyTimes = [0, 0.45, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.7, 0.7, 0]
        fade.keyTimes = [0, 0.2, 0.6, 1]
        let lift = CABasicAnimation(keyPath: "transform.translation.y")
        lift.fromValue = 0
        lift.toValue = 1.5
        let group = CAAnimationGroup()
        group.animations = [head, tail, fade, lift]
        group.duration = riseSeconds
        group.timeOffset = riseSeconds * phase
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Slow, small strokes: nothing is gained from the display's full rate.
        group.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        return group
    }

    private func resolved(_ color: NSColor) -> CGColor {
        var out = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { out = color.cgColor }
        return out
    }

    private func refreshHighlight() {
        let strength: CGFloat = pressed ? 0.16 : hovered ? 0.1 : 0
        highlight.backgroundColor = strength == 0 ? nil : resolved(NSColor.labelColor.withAlphaComponent(strength))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSteam()
        refreshHighlight()
    }

    /// Core Animation drops what was moving in a view taken out of its
    /// window or hidden: started again when it is back.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refreshSteam() }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshSteam()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        let was = pressed
        pressed = false
        release(at: convert(event.locationInWindow, from: nil), pressed: was)
    }

    /// The mouse let go at `point`: a click when the press began here and
    /// ends inside. True when it turned the switch.
    @discardableResult
    func release(at point: NSPoint, pressed: Bool) -> Bool {
        guard pressed, bounds.contains(point) else { return false }
        state.toggle()
        return true
    }

    override func accessibilityPerformPress() -> Bool {
        state.toggle()
        return true
    }
}
