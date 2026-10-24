//
//  TerminalBackdropView.swift — what sits behind a terminal: the system blur
//  (for translucent themes) and the theme's background image. Bottom to
//  top: desktop (blurred), background color at the theme's opacity, image,
//  text. Without an image the terminal view paints its own background.
//

import AppKit
import CoreImage
import ImageIO

@MainActor
final class TerminalBackdropView: NSView {
    let terminal: MonadTerminalView
    private var effect: NSVisualEffectView?
    /// Its own layer above the system blur: drawn by this view itself, the
    /// image was covered by the blur, a subview (seen on the Mac).
    private let imageView = BackdropImageView()
    private(set) var theme: Theme = .monadDark

    init(terminal: MonadTerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.isHidden = true
        addSubview(imageView)
        addSubview(terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { false }

    /// The window must let the desktop show through.
    var needsTransparentWindow: Bool { theme.backgroundOpacity < 1 || theme.blur > 0 }

    func setTheme(_ chosen: Theme?) {
        terminal.setTheme(chosen)
        theme = terminal.activeTheme
        updateBlur()
        // Blur softens the image itself, not only what shows through.
        let image = theme.backgroundImage.flatMap { BackdropImageCache.shared.image(atPath: $0.path, blur: theme.blur) }
        imageView.show(image, theme: theme)
        terminal.paintsBackground = image == nil
    }

    private func updateBlur() {
        if theme.blur > 0 {
            let v = effect ?? NSVisualEffectView(frame: bounds)
            v.autoresizingMask = [.width, .height]
            v.blendingMode = .behindWindow
            v.material = .underWindowBackground
            v.state = .active
            // Full system blur: fading the effect view in only made the
            // desktop half-visible, not blurred.
            v.alphaValue = 1
            if effect == nil {
                addSubview(v, positioned: .below, relativeTo: imageView)
                effect = v
            }
        } else {
            effect?.removeFromSuperview()
            effect = nil
        }
    }
}

/// The theme's background color, at its opacity, and its image: between
/// the desktop's blur and the text.
final class BackdropImageView: NSView {
    private var image: CGImage?
    private var theme: Theme = .monadDark

    override var isOpaque: Bool { false }

    func show(_ image: CGImage?, theme: Theme) {
        self.image = image
        self.theme = theme
        isHidden = image == nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let ctx = NSGraphicsContext.current?.cgContext,
              let settings = theme.backgroundImage else { return }
        ctx.clear(dirtyRect)
        ctx.setFillColor(theme.background.cgColor(alpha: CGFloat(theme.backgroundOpacity)))
        ctx.fill(bounds)
        ctx.saveGState()
        ctx.setAlpha(CGFloat(settings.opacity))
        ctx.interpolationQuality = .medium
        let rect = BackdropLayout.rect(settings.fill, image: CGSize(width: image.width, height: image.height), in: bounds)
        if settings.fill == .tile {
            ctx.clip(to: bounds)
            ctx.draw(image, in: rect, byTiling: true)
        } else {
            ctx.draw(image, in: rect)
        }
        ctx.restoreGState()
    }
}

/// Where the background image goes (view coordinates, origin bottom left).
enum BackdropLayout {
    static func rect(_ fill: Theme.BackgroundImage.Fill, image: CGSize, in bounds: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return bounds }
        func centered(_ size: CGSize) -> CGRect {
            CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        }
        switch fill {
        case .stretch:
            return bounds
        case .fill, .fit:
            let sx = bounds.width / image.width, sy = bounds.height / image.height
            let s = fill == .fill ? max(sx, sy) : min(sx, sy)
            return centered(CGSize(width: image.width * s, height: image.height * s))
        case .center:
            return centered(image)
        case .tile:
            return CGRect(x: bounds.minX, y: bounds.maxY - image.height, width: image.width, height: image.height)
        }
    }
}

/// Background images, decoded once at no more than `maxPixels` on the long
/// side (a 8K photo would otherwise cost ~130 MB per window), blurred once
/// per blur amount, and shared by every tab. Kept up to `costLimit` bytes,
/// the least recently used giving way; the app's cache also lets go of
/// everything when memory runs critically low.
@MainActor
final class BackdropImageCache {
    static let shared = BackdropImageCache(releasesUnderPressure: true)
    static let maxPixels = 3840
    /// Blur 1.0 is a Gaussian of this radius, in image pixels.
    static let maxBlurRadius: Double = 40

    private let costLimit: Int
    private var entries: [String: (image: CGImage, cost: Int, used: UInt64)] = [:]
    private var totalCost = 0
    private var clock: UInt64 = 0
    private var pressure: DispatchSourceMemoryPressure?
    private lazy var context = CIContext(options: [.cacheIntermediates: false])

    init(costLimit: Int = 256 << 20, releasesUnderPressure: Bool = false) {
        self.costLimit = costLimit
        guard releasesUnderPressure else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.removeAll() } }
        source.resume()
        pressure = source
    }

    func removeAll() {
        entries = [:]
        totalCost = 0
    }

    private func cached(_ key: String) -> CGImage? {
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.used = clock
        entries[key] = entry
        return entry.image
    }

    /// Kept unless it alone is over the limit; the least recently used go
    /// until the rest fits.
    private func keep(_ image: CGImage, as key: String) {
        let cost = image.bytesPerRow * image.height
        guard cost <= costLimit else { return }
        clock += 1
        if let old = entries[key] { totalCost -= old.cost }
        entries[key] = (image, cost, clock)
        totalCost += cost
        while totalCost > costLimit, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
            totalCost -= oldest.value.cost
            entries[oldest.key] = nil
        }
    }

    /// The image at `path`, blurred by `blur` (0…1).
    func image(atPath path: String, blur: Double) -> CGImage? {
        let amount = (min(max(blur, 0), 1) * 100).rounded() / 100
        guard let base = key(for: path), let sharp = image(atPath: path, key: base) else { return nil }
        guard amount > 0 else { return sharp }
        let key = "\(base)|blur \(amount)"
        if let hit = cached(key) { return hit }
        let input = CIImage(cgImage: sharp)
        // Clamped so the edges do not fade to transparent, then cropped back.
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: amount * Self.maxBlurRadius)
            .cropped(to: input.extent)
        guard let out = context.createCGImage(blurred, from: input.extent) else { return sharp }
        keep(out, as: key)
        return out
    }

    /// Path plus modification time and size: a changed file is read again.
    private func key(for path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let stamp = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(stamp)|\((attrs[.size] as? NSNumber)?.intValue ?? 0)"
    }

    private func image(atPath path: String, key: String) -> CGImage? {
        if let hit = cached(key) { return hit }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Self.maxPixels,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        keep(image, as: key)
        return image
    }
}
