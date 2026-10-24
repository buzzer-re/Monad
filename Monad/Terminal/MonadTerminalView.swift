//
//  MonadTerminalView.swift — renders a TerminalModel and turns keyboard,
//  mouse, paste and drag-and-drop into bytes for the application.
//

import AppKit
import CoreText
import UniformTypeIdentifiers
import os

/// An image the user pasted or dropped, normalized to PNG.
struct ImagePayload {
    let png: Data
    let suggestedName: String
}

@MainActor
protocol TerminalViewDelegate: AnyObject {
    /// Bytes typed/pasted by the user.
    func terminalView(_ view: MonadTerminalView, send data: Data)
    /// The grid size changed.
    func terminalView(_ view: MonadTerminalView, didResizeTo cols: Int, rows: Int, pixels: CGSize)
    /// Images were pasted or dropped. Return false to fall back to default handling.
    func terminalView(_ view: MonadTerminalView, receivedImages images: [ImagePayload]) -> Bool
    /// Non-image files were dropped. Return false to insert their host paths.
    func terminalView(_ view: MonadTerminalView, receivedFiles urls: [URL]) -> Bool
}

private enum Mod {
    static let shift: UInt32 = 1
    static let alt: UInt32 = 2
    static let ctrl: UInt32 = 4
    static let meta: UInt32 = 8
}

@MainActor
final class MonadTerminalView: NSView, @preconcurrency NSTextInputClient, NSMenuItemValidation {
    weak var delegate: TerminalViewDelegate?

    private(set) var model: TerminalModel
    private(set) var fonts: TerminalFonts
    private var theme: TerminalTheme = .dark
    /// The chosen theme; nil follows the appearance (Monad Light/Dark).
    private(set) var chosenTheme: Theme?
    /// The theme in effect (chosen, or the one for the appearance).
    private(set) var activeTheme: Theme = .monadDark
    /// False when a backdrop behind the view paints the background (images).
    var paintsBackground = true {
        didSet { if paintsBackground != oldValue { needsDisplay = true } }
    }
    private let padding = CGSize(width: 6, height: 4)

    private(set) var cols: Int
    private(set) var rows: Int
    /// The grid last told to the delegate, and whether telling it waits.
    private var reportedSize: [Int]?
    private var sizeReportPending = false

    private var dirtyScratch = [UInt8]()
    private var lastCursor = mnd_cursor_info()
    private var cursorBlinkOn = true
    private var blinkTimer: Timer?
    private var isFocused = false
    private var syncDeferrals = 0

    // Selection in absolute coordinates (stable while output scrolls).
    private struct Selection {
        enum Unit { case character, word, line }
        var anchorStart: mnd_pos
        var anchorEnd: mnd_pos
        var start: mnd_pos
        var end: mnd_pos
        var unit: Unit
        var block: Bool
    }
    private var selection: Selection?
    private var selecting = false
    private var mouseReporting = false
    private var pressedButton = -1
    private var scrollAccumulator: CGFloat = 0

    // IME
    private var markedText = NSAttributedString()
    private var keyDownHandled = false

    private let scroller = NSScroller(frame: .zero)
    private var scrollerHideWork: DispatchWorkItem?
    private let toast = NSTextField(labelWithString: "")
    private var toastHideWork: DispatchWorkItem?
    private let bellLayer = CALayer()

    init(model: TerminalModel) {
        self.model = model
        self.fonts = TerminalFonts(size: Settings.fontSize)
        let size = model.size
        cols = size.cols
        rows = size.rows
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.fileURL, .png, .tiff])
        setupScroller()
        setupToast()
        bellLayer.opacity = 0
        layer?.addSublayer(bellLayer)
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: .monadSettingsChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { paintsBackground && activeTheme.backgroundOpacity >= 1 }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    /// Window content size that fits cols x rows exactly.
    func contentSize(cols: Int, rows: Int) -> NSSize {
        NSSize(width: CGFloat(cols) * fonts.cellWidth + padding.width * 2,
               height: CGFloat(rows) * fonts.cellHeight + padding.height * 2)
    }

    var cellSize: NSSize { NSSize(width: fonts.cellWidth, height: fonts.cellHeight) }

    private func rowRect(_ y: Int) -> NSRect {
        NSRect(x: 0, y: padding.height + CGFloat(y) * fonts.cellHeight, width: bounds.width, height: fonts.cellHeight)
    }

    private func cellRect(x: Int, y: Int, width: Int = 1) -> NSRect {
        NSRect(x: padding.width + CGFloat(x) * fonts.cellWidth, y: padding.height + CGFloat(y) * fonts.cellHeight,
               width: CGFloat(width) * fonts.cellWidth, height: fonts.cellHeight)
    }

    private func cell(at point: NSPoint, clampToGrid: Bool = true) -> (col: Int, row: Int) {
        guard point.x.isFinite, point.y.isFinite else { return (0, 0) }
        var col = Int(floor((point.x - padding.width) / fonts.cellWidth))
        var row = Int(floor((point.y - padding.height) / fonts.cellHeight))
        if clampToGrid {
            col = max(0, min(cols - 1, col))
            row = max(0, min(rows - 1, row))
        }
        return (col, row)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recomputeGrid()
        layoutOverlays()
    }

    /// The grid a view of `size` holds, nil without room for one cell.
    func grid(for size: NSSize) -> (cols: Int, rows: Int)? {
        let width = size.width - padding.width * 2, height = size.height - padding.height * 2
        guard width >= fonts.cellWidth, height >= fonts.cellHeight else { return nil }
        return (max(2, Int(width / fonts.cellWidth)), max(1, Int(height / fonts.cellHeight)))
    }

    /// The grid follows the view while it is in a window and has room for a
    /// cell: out of a window or empty, it is a pane being moved between
    /// split views, and keeps its grid.
    private func recomputeGrid() {
        guard window != nil, let (c, r) = grid(for: bounds.size) else { return }
        if c != cols || r != rows {
            guard model.resize(cols: c, rows: r) else {
                Log.term.error("terminal resize to \(c)x\(r) failed")
                return
            }
            cols = c
            rows = r
            selection = nil
            needsDisplay = true
            updateScroller()
        }
        reportSizeLater()
    }

    /// Tells the delegate (the shell) the grid once the layout pass is over,
    /// and only when it changed: a shell told a size the view only passed
    /// through redraws its prompt for it, and then for the real size from
    /// the wrong line.
    private func reportSizeLater() {
        guard !sizeReportPending else { return }
        sizeReportPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            sizeReportPending = false
            let px = window?.backingScaleFactor ?? 2
            model.setCellPixels(width: Int((fonts.cellWidth * px).rounded()), height: Int((fonts.cellHeight * px).rounded()))
            guard let delegate, reportedSize != [cols, rows] else { return }
            reportedSize = [cols, rows]
            let scale = window?.backingScaleFactor ?? 2
            delegate.terminalView(self, didResizeTo: cols, rows: rows,
                                  pixels: CGSize(width: CGFloat(cols) * fonts.cellWidth * scale,
                                                 height: CGFloat(rows) * fonts.cellHeight * scale))
        }
    }

    private func layoutOverlays() {
        let w = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        scroller.frame = NSRect(x: bounds.width - w, y: 0, width: w, height: bounds.height)
        bellLayer.frame = bounds
        positionToast()
    }

    // MARK: Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    /// Use `theme` (nil: follow the appearance with Monad Light/Dark).
    func setTheme(_ theme: Theme?) {
        chosenTheme = theme
        applyTheme()
    }

    private func applyTheme() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        activeTheme = chosenTheme ?? (dark ? .monadDark : .monadLight)
        theme = activeTheme.terminalTheme
        model.setTheme(theme)
        // The view draws its own (possibly translucent) background.
        layer?.backgroundColor = nil
        layer?.isOpaque = isOpaque
        bellLayer.backgroundColor = theme.foreground.cgColor(alpha: 0.15)
        if fonts.name != activeTheme.font { setFontSize(fonts.size) }
        needsDisplay = true
    }

    /// The cursor's shape: the program's if it chose one, else the theme's.
    func effectiveCursorShape(_ info: mnd_cursor_info) -> mnd_cursor_shape {
        if info.styled { return info.shape }
        switch activeTheme.cursorStyle {
        case .underline: return MND_CURSOR_UNDERLINE
        case .bar: return MND_CURSOR_BAR
        case .block, nil: return MND_CURSOR_BLOCK
        }
    }

    @objc private func settingsChanged() {
        let size = Settings.fontSize
        if size != fonts.size { setFontSize(size) }
        updateBlinkTimer()
    }

    private func setFontSize(_ size: CGFloat) {
        fonts = TerminalFonts(size: size, name: activeTheme.font)
        if let window, let controller = window.windowController as? TerminalWindowController {
            controller.fontMetricsChanged()
        }
        recomputeGrid()
        needsDisplay = true
    }

    // MARK: Output

    /// Called when the model changed: invalidate only what is dirty.
    func refresh() {
        let sync = model.mode(MND_MODE_SYNC_OUTPUT)
        if sync && syncDeferrals < 8 {
            // Synchronized output (mode 2026): wait for the frame to complete.
            syncDeferrals += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in self?.refresh() }
            return
        }
        syncDeferrals = 0
        if dirtyScratch.count != rows { dirtyScratch = [UInt8](repeating: 0, count: rows) }
        var cursor = mnd_cursor_info()
        let any = model.withLock { () -> Bool in
            cursor = mnd_vt_cursor(model.vt)
            return mnd_vt_take_dirty(model.vt, &dirtyScratch, Int32(rows))
        }
        if any {
            for y in 0..<rows where dirtyScratch[y] != 0 { setNeedsDisplay(rowRect(y)) }
        }
        if cursor.x != lastCursor.x || cursor.y != lastCursor.y || cursor.visible != lastCursor.visible
            || cursor.shape.rawValue != lastCursor.shape.rawValue {
            invalidateCursor(lastCursor)
            invalidateCursor(cursor)
            lastCursor = cursor
            cursorBlinkOn = true
        }
        updateBlinkTimer()
        updateScroller()
        if any { noteAccessibilityChange() }
    }

    private func invalidateCursor(_ c: mnd_cursor_info) {
        guard c.y >= 0 && Int(c.y) < rows else { return }
        setNeedsDisplay(rowRect(Int(c.y)))
    }

    // MARK: Drawing

    override func draw(_ requested: NSRect) {
        // AppKit may ask for an unbounded rect (e.g. when caching the view's
        // display); converting its edges to rows would trap.
        let dirtyRect = requested.intersection(bounds)
        guard !dirtyRect.isNull, !dirtyRect.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let reverse = model.mode(MND_MODE_REVERSE_VIDEO)
        let defaultBg = reverse ? theme.foreground : theme.background
        // Not opaque: Core Animation hands us a cleared backing; clearing here
        // would also erase what views behind us drew (e.g. the backdrop image
        // when drawing into one shared context).
        if paintsBackground {
            ctx.setFillColor(defaultBg.cgColor(alpha: CGFloat(activeTheme.backgroundOpacity)))
            ctx.fill(dirtyRect)
        }

        let first = max(0, Int((dirtyRect.minY - padding.height) / fonts.cellHeight))
        let last = min(rows - 1, Int((dirtyRect.maxY - padding.height) / fonts.cellHeight))
        guard first <= last else { return }
        let scale = window?.backingScaleFactor ?? 2

        model.withLock {
            let vt = model.vt
            let cursor = mnd_vt_cursor(vt)
            let topAbs = mnd_vt_view_to_abs_locked(vt, 0)
            for y in first...last {
                var len: Int32 = 0
                guard let cells = mnd_vt_view_row(vt, Int32(y), &len) else { continue }
                drawRow(ctx, cells: cells, count: min(Int(len), cols), y: y, absLine: topAbs + Int64(y),
                        reverse: reverse, scale: scale)
            }
            if cursor.visible && markedText.length == 0,
               Self.cursorShown(blinkPhaseOn: cursorBlinkOn, programBlinks: cursor.styled && cursor.blink,
                                settingBlinks: Settings.cursorBlink, focused: isFocused),
               Int(cursor.y) >= first && Int(cursor.y) <= last {
                var len: Int32 = 0
                if let cells = mnd_vt_view_row(vt, cursor.y, &len), Int(cursor.x) < Int(len) {
                    drawCursor(ctx, cursor: cursor, cell: cells[Int(cursor.x)], reverse: reverse, scale: scale)
                }
            }
        }
        if markedText.length > 0 { drawMarkedText(ctx) }
    }

    private func isSelected(col: Int, line: Int64) -> Bool {
        guard let s = selection else { return false }
        if line < s.start.line || line > s.end.line { return false }
        if s.block {
            let lo = min(s.start.col, s.end.col), hi = max(s.start.col, s.end.col)
            return col >= lo && col <= hi
        }
        if line == s.start.line && col < s.start.col { return false }
        if line == s.end.line && col > s.end.col { return false }
        return true
    }

    private func drawRow(_ ctx: CGContext, cells: UnsafePointer<mnd_cell>, count: Int, y: Int, absLine: Int64,
                         reverse: Bool, scale: CGFloat) {
        let top = padding.height + CGFloat(y) * fonts.cellHeight
        let cw = fonts.cellWidth, ch = fonts.cellHeight
        let hasSelection = selection != nil

        // Pass 1: backgrounds, merged into runs.
        var runStart = 0
        var runColor: RGB?
        func flushBg(_ end: Int) {
            if let c = runColor, end > runStart {
                ctx.setFillColor(c.cgColor())
                let x0 = padding.width + CGFloat(runStart) * cw
                var w = CGFloat(end - runStart) * cw
                if end == cols { w = bounds.width - x0 } // extend to the right edge
                ctx.fill(CGRect(x: runStart == 0 ? 0 : x0, y: top, width: runStart == 0 ? w + x0 : w, height: ch))
            }
        }
        for x in 0..<count {
            let c = cells[x]
            let r = theme.resolve(fg: c.fg, bg: c.bg, attrs: c.attrs, reverseVideo: reverse)
            var bg: RGB? = r.bgIsDefault ? nil : r.bg
            if hasSelection && isSelected(col: x, line: absLine) { bg = theme.selection }
            if bg != runColor {
                flushBg(x)
                runStart = x
                runColor = bg
            }
        }
        flushBg(count)

        // Pass 1b: inline images, one draw per run of tiles of one image.
        drawImageTiles(ctx, cells: cells, count: count, top: top)

        // Pass 2: glyphs, batched per (font, color).
        let baseline = top + fonts.baseline
        var glyphs: [CGGlyph] = []
        var positions: [CGPoint] = []
        var batchFont: CTFont?
        var batchColor: RGB?
        glyphs.reserveCapacity(count)
        positions.reserveCapacity(count)

        func flushGlyphs() {
            guard let font = batchFont, let color = batchColor, !glyphs.isEmpty else { return }
            ctx.saveGState()
            ctx.setFillColor(color.cgColor())
            ctx.translateBy(x: 0, y: baseline)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            CTFontDrawGlyphs(font, glyphs, positions, glyphs.count, ctx)
            ctx.restoreGState()
            glyphs.removeAll(keepingCapacity: true)
            positions.removeAll(keepingCapacity: true)
        }

        for x in 0..<count {
            let c = cells[x]
            let width = (c.attrs & VTAttr.widthMask) >> VTAttr.widthShift
            if width == VTAttr.widthSpacer { continue }
            let cellsWide = width == VTAttr.widthWide ? 2 : 1
            let r = theme.resolve(fg: c.fg, bg: c.bg, attrs: c.attrs, reverseVideo: reverse)
            let x0 = padding.width + CGFloat(x) * cw

            drawDecorations(ctx, attrs: c.attrs, color: r.fg, x: x0, width: CGFloat(cellsWide) * cw, top: top)

            let cp = c.cp
            if cp == 0 || cp == 0x20 || mnd_cp_is_image(cp) { continue }
            let bold = c.attrs & VTAttr.bold != 0, italic = c.attrs & VTAttr.italic != 0

            if cp & VTAttr.graphemeFlag != 0 {
                flushGlyphs()
                drawCluster(ctx, cp: cp, x: x0, baseline: baseline, color: r.fg, bold: bold, italic: italic)
                continue
            }
            if BoxDrawing.handles(cp) {
                flushGlyphs()
                ctx.setFillColor(r.fg.cgColor())
                BoxDrawing.draw(cp, in: CGRect(x: x0, y: top, width: CGFloat(cellsWide) * cw, height: ch),
                                scale: scale, context: ctx)
                continue
            }
            guard let g = fonts.glyph(for: cp, bold: bold, italic: italic) else { continue }
            if g.font !== batchFont || r.fg != batchColor {
                flushGlyphs()
                batchFont = g.font
                batchColor = r.fg
            }
            glyphs.append(g.glyph)
            positions.append(CGPoint(x: x0, y: 0))
        }
        flushGlyphs()
    }

    /// The tiles of inline images on one row: each run of consecutive tiles
    /// of one image row is the image drawn whole, clipped to the run.
    private func drawImageTiles(_ ctx: CGContext, cells: UnsafePointer<mnd_cell>, count: Int, top: CGFloat) {
        let cw = fonts.cellWidth, ch = fonts.cellHeight
        var x = 0
        while x < count {
            let cp = cells[x].cp
            guard mnd_cp_is_image(cp) else {
                x += 1
                continue
            }
            let id = mnd_cp_image_id(cp), ty = mnd_cp_image_y(cp), tx0 = mnd_cp_image_x(cp)
            var end = x + 1
            while end < count, mnd_cp_is_image(cells[end].cp), mnd_cp_image_id(cells[end].cp) == id,
                  mnd_cp_image_y(cells[end].cp) == ty, mnd_cp_image_x(cells[end].cp) == tx0 + UInt32(end - x) {
                end += 1
            }
            if let image = model.images.image(id) {
                let run = CGRect(x: padding.width + CGFloat(x) * cw, y: top, width: CGFloat(end - x) * cw, height: ch)
                let whole = CGRect(x: run.minX - CGFloat(tx0) * cw, y: top - CGFloat(ty) * ch,
                                   width: CGFloat(image.cols) * cw * image.fillX, height: CGFloat(image.rows) * ch * image.fillY)
                ctx.saveGState()
                ctx.clip(to: run)
                // The view is flipped: draw the image upright.
                ctx.translateBy(x: whole.minX, y: whole.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .high
                ctx.draw(image.cgImage, in: CGRect(origin: .zero, size: whole.size))
                ctx.restoreGState()
            }
            x = end
        }
    }

    private func drawDecorations(_ ctx: CGContext, attrs: UInt16, color: RGB, x: CGFloat, width: CGFloat, top: CGFloat) {
        let ul = (attrs & VTAttr.underlineMask) >> VTAttr.underlineShift
        let strike = attrs & VTAttr.strike != 0, over = attrs & VTAttr.overline != 0
        guard ul != 0 || strike || over else { return }
        let t = fonts.lineThickness
        ctx.setFillColor(color.cgColor())
        let baseline = top + fonts.baseline
        if ul != 0 {
            let uy = min(baseline + fonts.underlineOffset, top + fonts.cellHeight - t)
            ctx.fill(CGRect(x: x, y: uy, width: width, height: t))
            if ul == 2 { ctx.fill(CGRect(x: x, y: max(top, uy - 2 * t), width: width, height: t)) }
        }
        if strike { ctx.fill(CGRect(x: x, y: top + fonts.cellHeight / 2, width: width, height: t)) }
        if over { ctx.fill(CGRect(x: x, y: top, width: width, height: t)) }
    }

    private func drawCluster(_ ctx: CGContext, cp: UInt32, x: CGFloat, baseline: CGFloat, color: RGB,
                             bold: Bool, italic: Bool) {
        var buf = [UInt32](repeating: 0, count: 8)
        let n = mnd_vt_grapheme(model.vt, cp, &buf, buf.count)
        guard n > 0 else { return }
        var s = ""
        for v in buf.prefix(min(Int(n), buf.count)) { if let u = Unicode.Scalar(v) { s.unicodeScalars.append(u) } }
        let attr = NSAttributedString(string: s, attributes: [
            .font: fonts.font(bold: bold, italic: italic),
            .foregroundColor: NSColor(cgColor: color.cgColor()) ?? .textColor,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.saveGState()
        ctx.translateBy(x: x, y: baseline)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private func drawCursor(_ ctx: CGContext, cursor: mnd_cursor_info, cell: mnd_cell, reverse: Bool, scale: CGFloat) {
        let wide = (cell.attrs & VTAttr.widthMask) >> VTAttr.widthShift == VTAttr.widthWide
        let rect = cellRect(x: Int(cursor.x), y: Int(cursor.y), width: wide ? 2 : 1)
        ctx.setFillColor(theme.cursor.cgColor())
        ctx.setStrokeColor(theme.cursor.cgColor())
        guard isFocused else {
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            return
        }
        switch effectiveCursorShape(cursor) {
        case MND_CURSOR_BAR:
            ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: max(1, 2 / scale * 2), height: rect.height))
        case MND_CURSOR_UNDERLINE:
            ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2))
        default:
            ctx.fill(rect)
            // Redraw the glyph under the block in the background color.
            let cp = cell.cp
            guard cp != 0 && cp != 0x20 && !mnd_cp_is_image(cp) else { return }
            let bg = reverse ? theme.foreground : theme.background
            let bold = cell.attrs & VTAttr.bold != 0, italic = cell.attrs & VTAttr.italic != 0
            let baseline = rect.minY + fonts.baseline
            if cp & VTAttr.graphemeFlag != 0 {
                drawCluster(ctx, cp: cp, x: rect.minX, baseline: baseline, color: bg, bold: bold, italic: italic)
            } else if BoxDrawing.handles(cp) {
                ctx.setFillColor(bg.cgColor())
                BoxDrawing.draw(cp, in: rect, scale: scale, context: ctx)
            } else if let g = fonts.glyph(for: cp, bold: bold, italic: italic) {
                ctx.saveGState()
                ctx.setFillColor(bg.cgColor())
                ctx.translateBy(x: rect.minX, y: baseline)
                ctx.scaleBy(x: 1, y: -1)
                ctx.textMatrix = .identity
                var glyph = g.glyph
                var pos = CGPoint.zero
                CTFontDrawGlyphs(g.font, &glyph, &pos, 1, ctx)
                ctx.restoreGState()
            }
        }
    }

    private func drawMarkedText(_ ctx: CGContext) {
        let c = lastCursor
        let origin = cellRect(x: Int(c.x), y: Int(c.y)).origin
        let attr = NSMutableAttributedString(attributedString: markedText)
        attr.addAttributes([
            .font: fonts.regular,
            .foregroundColor: NSColor(cgColor: theme.foreground.cgColor()) ?? .textColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .backgroundColor: NSColor(cgColor: theme.background.cgColor()) ?? .textBackgroundColor,
        ], range: NSRange(location: 0, length: attr.length))
        let line = CTLineCreateWithAttributedString(attr)
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y + fonts.baseline)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: Accessibility

    /// Visible screen as plain text (trailing blanks trimmed), for VoiceOver
    /// and UI tests.
    var visibleText: String {
        let top = mnd_vt_view_to_abs(model.vt, 0)
        return model.copyText(from: mnd_pos(col: 0, line: top),
                              to: mnd_pos(col: Int32(cols - 1), line: top + Int64(rows - 1)), block: false) ?? ""
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Terminal" }
    override func accessibilityIdentifier() -> String { "Terminal" }
    override func accessibilityValue() -> Any? { visibleText }
    override func isAccessibilityFocused() -> Bool { isFocused }

    private var accessibilityNotifyScheduled = false

    /// Tell assistive clients the screen changed (coalesced to 4 Hz).
    private func noteAccessibilityChange() {
        guard !accessibilityNotifyScheduled else { return }
        accessibilityNotifyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.accessibilityNotifyScheduled = false
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    // MARK: Cursor blink

    /// Whether the cursor is drawn now: it blinks when the program asks for
    /// it (DECSCUSR) or the user turned blinking on, and only in the focused tab.
    nonisolated static func cursorShown(blinkPhaseOn: Bool, programBlinks: Bool, settingBlinks: Bool,
                                        focused: Bool) -> Bool {
        blinkPhaseOn || !(programBlinks || settingBlinks) || !focused
    }

    private func updateBlinkTimer() {
        let blink = model.withLock { () -> Bool in
            let c = mnd_vt_cursor(model.vt)
            return c.styled && c.blink
        } || Settings.cursorBlink
        let want = blink && isFocused
        if want && blinkTimer == nil {
            let t = Timer(timeInterval: 0.53, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.cursorBlinkOn.toggle()
                    self.invalidateCursor(self.lastCursor)
                }
            }
            RunLoop.main.add(t, forMode: .common)
            blinkTimer = t
        } else if !want, let t = blinkTimer {
            t.invalidate()
            blinkTimer = nil
            cursorBlinkOn = true
            invalidateCursor(lastCursor)
        }
    }

    private func resetBlink() {
        if !cursorBlinkOn {
            cursorBlinkOn = true
            invalidateCursor(lastCursor)
        }
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        if let d = model.encodeFocus(true) { delegate?.terminalView(self, send: d) }
        invalidateCursor(lastCursor)
        updateBlinkTimer()
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        if let d = model.encodeFocus(false) { delegate?.terminalView(self, send: d) }
        invalidateCursor(lastCursor)
        updateBlinkTimer()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        recomputeGrid()
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged),
                                               name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged),
                                               name: NSWindow.didResignKeyNotification, object: window)
        updateTrackingAreas()
    }

    @objc private func windowKeyChanged() {
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        guard focused != isFocused else { return }
        isFocused = focused
        if let d = model.encodeFocus(focused) { delegate?.terminalView(self, send: d) }
        invalidateCursor(lastCursor)
        updateBlinkTimer()
    }

    // MARK: Keyboard

    private func send(_ data: Data?) {
        guard let data, !data.isEmpty else { return }
        delegate?.terminalView(self, send: data)
    }

    private func modifiers(_ flags: NSEvent.ModifierFlags, includeAlt: Bool) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.shift) { m |= Mod.shift }
        if flags.contains(.option) && includeAlt { m |= Mod.alt }
        if flags.contains(.control) { m |= Mod.ctrl }
        return m
    }

    private static let functionKeys: [Int: mnd_key] = {
        var m: [Int: mnd_key] = [
            NSUpArrowFunctionKey: MND_KEY_UP, NSDownArrowFunctionKey: MND_KEY_DOWN,
            NSLeftArrowFunctionKey: MND_KEY_LEFT, NSRightArrowFunctionKey: MND_KEY_RIGHT,
            NSHomeFunctionKey: MND_KEY_HOME, NSEndFunctionKey: MND_KEY_END,
            NSPageUpFunctionKey: MND_KEY_PAGE_UP, NSPageDownFunctionKey: MND_KEY_PAGE_DOWN,
            NSInsertFunctionKey: MND_KEY_INSERT, NSDeleteFunctionKey: MND_KEY_DELETE,
            NSHelpFunctionKey: MND_KEY_INSERT,
        ]
        let fkeys: [mnd_key] = [MND_KEY_F1, MND_KEY_F2, MND_KEY_F3, MND_KEY_F4, MND_KEY_F5, MND_KEY_F6, MND_KEY_F7,
                                MND_KEY_F8, MND_KEY_F9, MND_KEY_F10, MND_KEY_F11, MND_KEY_F12, MND_KEY_F13,
                                MND_KEY_F14, MND_KEY_F15, MND_KEY_F16, MND_KEY_F17, MND_KEY_F18, MND_KEY_F19,
                                MND_KEY_F20]
        for (i, k) in fkeys.enumerated() { m[NSF1FunctionKey + i] = k }
        return m
    }()

    /// Keypad keys by virtual key code (only used in application keypad mode).
    private static let keypad: [UInt16: mnd_key] = [
        82: MND_KEY_KP_0, 83: MND_KEY_KP_1, 84: MND_KEY_KP_2, 85: MND_KEY_KP_3, 86: MND_KEY_KP_4,
        87: MND_KEY_KP_5, 88: MND_KEY_KP_6, 89: MND_KEY_KP_7, 91: MND_KEY_KP_8, 92: MND_KEY_KP_9,
        65: MND_KEY_KP_DECIMAL, 75: MND_KEY_KP_DIVIDE, 67: MND_KEY_KP_MULTIPLY, 78: MND_KEY_KP_SUBTRACT,
        69: MND_KEY_KP_ADD, 76: MND_KEY_KP_ENTER, 81: MND_KEY_KP_EQUAL,
    ]

    override func keyDown(with event: NSEvent) {
        resetBlink()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        NSCursor.setHiddenUntilMouseMoves(true)

        // An IME composition in progress owns the keyboard.
        if markedText.length > 0 {
            interpretKeyEvents([event])
            return
        }

        let optionAsMeta = Settings.optionAsMeta
        let raw = event.charactersIgnoringModifiers ?? ""
        let scalar = raw.unicodeScalars.first.map { Int($0.value) } ?? 0

        if let key = Self.functionKeys[scalar] {
            scrollToBottomOnInput()
            send(model.encodeKey(key, mods: modifiers(flags, includeAlt: true)))
            return
        }
        if flags.contains(.numericPad), let key = Self.keypad[event.keyCode], model.mode(MND_MODE_APP_KEYPAD) {
            scrollToBottomOnInput()
            send(model.encodeKey(key, mods: 0))
            return
        }
        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            scrollToBottomOnInput()
            send(model.encodeKey(event.keyCode == 76 ? MND_KEY_KP_ENTER : MND_KEY_ENTER,
                                 mods: modifiers(flags, includeAlt: optionAsMeta)))
            return
        case 48: // Tab
            scrollToBottomOnInput()
            send(model.encodeKey(MND_KEY_TAB, mods: modifiers(flags, includeAlt: optionAsMeta)))
            return
        case 51: // Backspace
            scrollToBottomOnInput()
            send(model.encodeKey(MND_KEY_BACKSPACE, mods: modifiers(flags, includeAlt: optionAsMeta)))
            return
        case 53: // Escape
            scrollToBottomOnInput()
            send(model.encodeKey(MND_KEY_ESCAPE, mods: modifiers(flags, includeAlt: optionAsMeta)))
            return
        default:
            break
        }

        let useMeta = flags.contains(.option) && optionAsMeta
        if flags.contains(.control) || useMeta, let s = raw.unicodeScalars.first {
            // For Ctrl combos use the unshifted key; keep shifted symbols for Alt.
            var mods: UInt32 = 0
            if flags.contains(.control) { mods |= Mod.ctrl }
            if useMeta { mods |= Mod.alt }
            var ch = s
            if flags.contains(.shift), !flags.contains(.control),
               let shifted = (event.characters(byApplyingModifiers: .shift) ?? "").unicodeScalars.first {
                ch = shifted
            }
            scrollToBottomOnInput()
            send(model.encodeChar(ch, mods: mods))
            return
        }

        keyDownHandled = false
        interpretKeyEvents([event])
    }

    private func scrollToBottomOnInput() {
        if mnd_vt_scroll_offset(model.vt) != 0 {
            mnd_vt_scroll_to_bottom(model.vt)
            refresh()
            needsDisplay = true
        }
    }

    override func doCommand(by selector: Selector) {
        // Commands not mapped in keyDown (e.g. from the IME) are ignored.
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = NSAttributedString()
        guard !text.isEmpty else { return }
        scrollToBottomOnInput()
        send(Data(text.utf8))
        invalidateCursor(lastCursor)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let a = string as? NSAttributedString { markedText = a } else { markedText = NSAttributedString(string: (string as? String) ?? "") }
        invalidateCursor(lastCursor)
    }

    func unmarkText() {
        markedText = NSAttributedString()
        invalidateCursor(lastCursor)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let r = cellRect(x: Int(lastCursor.x), y: Int(lastCursor.y))
        guard let window else { return .zero }
        return window.convertToScreen(convert(r, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.iBeam.set() }

    private func shouldReportMouse(_ event: NSEvent) -> Bool {
        // Option bypasses mouse reporting so text can always be selected.
        model.mouseTracking != MND_MOUSE_OFF && !event.modifierFlags.contains(.option)
    }

    private func mouseMods(_ event: NSEvent) -> UInt32 {
        var m: UInt32 = 0
        if event.modifierFlags.contains(.shift) { m |= Mod.shift }
        if event.modifierFlags.contains(.control) { m |= Mod.ctrl }
        if event.modifierFlags.contains(.command) { m |= Mod.meta }
        return m
    }

    private func report(_ event: NSEvent, button: Int, action: mnd_mouse_action) {
        let p = convert(event.locationInWindow, from: nil)
        let c = cell(at: p)
        send(model.encodeMouse(button: button, action: action, mods: mouseMods(event), col: c.col, row: c.row))
    }

    private func absPos(_ point: NSPoint) -> mnd_pos {
        let c = cell(at: point)
        return mnd_pos(col: Int32(c.col), line: mnd_vt_view_to_abs(model.vt, Int32(c.row)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if shouldReportMouse(event) {
            mouseReporting = true
            pressedButton = 0
            report(event, button: 0, action: MND_MOUSE_PRESS)
            return
        }
        mouseReporting = false
        let p = convert(event.locationInWindow, from: nil)
        let pos = absPos(p)

        if event.modifierFlags.contains(.command), openLink(at: pos) { return }

        if event.modifierFlags.contains(.shift), var s = selection {
            // Extend the existing selection.
            s.start = min(s.anchorStart, pos)
            s.end = max(s.anchorEnd, pos)
            selection = s
            selecting = true
            needsDisplay = true
            return
        }
        let unit: Selection.Unit = event.clickCount >= 3 ? .line : (event.clickCount == 2 ? .word : .character)
        var start = pos, end = pos
        switch unit {
        case .word: mnd_vt_word_bounds(model.vt, pos, &start, &end)
        case .line: mnd_vt_line_bounds(model.vt, pos, &start, &end)
        case .character: break
        }
        selection = Selection(anchorStart: start, anchorEnd: end, start: start, end: end, unit: unit,
                              block: event.modifierFlags.contains(.option) && model.mouseTracking == MND_MOUSE_OFF)
        if unit == .character { selection?.end.col -= 1 } // empty until dragged
        selecting = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if mouseReporting {
            report(event, button: 0, action: MND_MOUSE_MOTION)
            return
        }
        guard selecting, var s = selection else { return }
        let p = convert(event.locationInWindow, from: nil)
        // Auto-scroll when dragging past the edges.
        if p.y < 0 { _ = mnd_vt_scroll(model.vt, 1); refresh() }
        if p.y > bounds.height { _ = mnd_vt_scroll(model.vt, -1); refresh() }
        var pos = absPos(p)
        switch s.unit {
        case .character:
            // Selecting leftwards includes the cell under the anchor.
            if pos < s.anchorStart { s.start = pos; s.end = s.anchorStart } else {
                if p.x < padding.width + (CGFloat(pos.col) + 0.5) * fonts.cellWidth { pos.col -= 1 }
                s.start = s.anchorStart
                s.end = pos
            }
        case .word:
            var ws = pos, we = pos
            mnd_vt_word_bounds(model.vt, pos, &ws, &we)
            s.start = min(s.anchorStart, ws)
            s.end = max(s.anchorEnd, we)
        case .line:
            var ls = pos, le = pos
            mnd_vt_line_bounds(model.vt, pos, &ls, &le)
            s.start = min(s.anchorStart, ls)
            s.end = max(s.anchorEnd, le)
        }
        selection = s
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if mouseReporting {
            report(event, button: 0, action: MND_MOUSE_RELEASE)
            mouseReporting = false
            pressedButton = -1
            return
        }
        selecting = false
        if let s = selection, s.end < s.start { selection = nil; needsDisplay = true }
    }

    override func mouseMoved(with event: NSEvent) {
        if model.mouseTracking == MND_MOUSE_ANY && !event.modifierFlags.contains(.option) {
            report(event, button: 3, action: MND_MOUSE_MOTION)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if shouldReportMouse(event) {
            report(event, button: 2, action: MND_MOUSE_PRESS)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if shouldReportMouse(event) { report(event, button: 2, action: MND_MOUSE_RELEASE) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if shouldReportMouse(event) { report(event, button: 2, action: MND_MOUSE_MOTION) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if shouldReportMouse(event) { report(event, button: 1, action: MND_MOUSE_PRESS) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if shouldReportMouse(event) { report(event, button: 1, action: MND_MOUSE_RELEASE) }
    }

    /// More items for the right-click menu (the pane's, from its window).
    var extraMenuItems: (() -> [NSMenuItem])?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copy.isEnabled = selection != nil
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Clear Scrollback", action: #selector(clearScrollback(_:)), keyEquivalent: "")
        if let extra = extraMenuItems?(), !extra.isEmpty {
            menu.addItem(.separator())
            extra.forEach(menu.addItem)
        }
        return menu
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / fonts.cellHeight : event.scrollingDeltaY
        scrollAccumulator += delta
        let lines = Int(scrollAccumulator)
        guard lines != 0 else { return }
        scrollAccumulator -= CGFloat(lines)

        if shouldReportMouse(event) {
            let button = lines > 0 ? 4 : 5
            for _ in 0..<min(abs(lines), 10) { report(event, button: button, action: MND_MOUSE_PRESS) }
            return
        }
        if model.mode(MND_MODE_ALT_SCREEN) {
            // Alternate screen has no scrollback: send arrow keys (less, man, vim).
            if model.mode(MND_MODE_ALT_SCROLL) {
                let key = lines > 0 ? MND_KEY_UP : MND_KEY_DOWN
                for _ in 0..<min(abs(lines), 10) { send(model.encodeKey(key, mods: 0)) }
            }
            return
        }
        _ = mnd_vt_scroll(model.vt, Int32(lines))
        refresh()
        flashScroller()
    }

    private func openLink(at pos: mnd_pos) -> Bool {
        // OSC 8 hyperlink under the pointer, else a URL-looking word.
        var uri: String?
        model.withLock {
            let row = mnd_vt_abs_to_view_locked(model.vt, pos.line)
            guard row >= 0 && row < Int32(rows) else { return }
            var len: Int32 = 0
            if let cells = mnd_vt_view_row(model.vt, row, &len), pos.col < len,
               let p = mnd_vt_link_uri(model.vt, cells[Int(pos.col)].link) {
                uri = String(cString: p)
            }
        }
        if uri == nil {
            var s = pos, e = pos
            mnd_vt_word_bounds(model.vt, pos, &s, &e)
            uri = model.copyText(from: s, to: e, block: false)?
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?\"'"))
        }
        guard let uri, let url = URL(string: uri), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    // MARK: Edit menu actions

    @objc func copy(_ sender: Any?) {
        guard let s = selection, let text = model.copyText(from: s.start, to: s.end, block: s.block) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let images = Self.images(from: pb)
        if !images.isEmpty, delegate?.terminalView(self, receivedImages: images) == true { return }
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        pasteText(text)
    }

    func pasteText(_ text: String) {
        scrollToBottomOnInput()
        send(model.encodePaste(text))
    }

    @objc override func selectAll(_ sender: Any?) {
        let top = mnd_vt_view_to_abs(model.vt, Int32(-mnd_vt_scrollback_lines(model.vt) + mnd_vt_scroll_offset(model.vt)))
        let bottom = mnd_vt_view_to_abs(model.vt, Int32(rows - 1))
        let s = mnd_pos(col: 0, line: top), e = mnd_pos(col: Int32(cols - 1), line: bottom)
        selection = Selection(anchorStart: s, anchorEnd: e, start: s, end: e, unit: .line, block: false)
        needsDisplay = true
    }

    @objc func clearScrollback(_ sender: Any?) {
        mnd_vt_clear_scrollback(model.vt)
        selection = nil
        refresh()
        needsDisplay = true
    }

    @objc func biggerFont(_ sender: Any?) { Settings.setFontSize(fonts.size + 1) }
    @objc func smallerFont(_ sender: Any?) { Settings.setFontSize(fonts.size - 1) }
    @objc func resetFontSize(_ sender: Any?) { Settings.setFontSize(13) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selection != nil }
        return true
    }

    // MARK: Images and drag & drop

    private static let imageTypes: [UTType] = [.png, .jpeg, .tiff, .gif, .heic, .webP, .bmp]

    /// Extract images from a pasteboard (screenshots copied to the clipboard,
    /// or image files copied in Finder), converting to PNG.
    static func images(from pb: NSPasteboard) -> [ImagePayload] {
        let stamp = Self.timestamp()
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let imgs = urls.compactMap { url -> ImagePayload? in
                guard let type = UTType(filenameExtension: url.pathExtension),
                      imageTypes.contains(where: { type.conforms(to: $0) }) else { return nil }
                return pngPayload(contentsOf: url)
            }
            return imgs
        }
        if let png = pb.data(forType: .png) {
            return [ImagePayload(png: png, suggestedName: "shot-\(stamp).png")]
        }
        if let tiff = pb.data(forType: .tiff), let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return [ImagePayload(png: png, suggestedName: "shot-\(stamp).png")]
        }
        return []
    }

    private static func pngPayload(contentsOf url: URL) -> ImagePayload? {
        let base = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: url) {
            return ImagePayload(png: data, suggestedName: "\(base).png")
        }
        guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return ImagePayload(png: png, suggestedName: "\(base).png")
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let images = Self.images(from: pb)
        if !images.isEmpty, images.count == max(urls.count, 1) || urls.isEmpty,
           delegate?.terminalView(self, receivedImages: images) == true {
            return true
        }
        guard !urls.isEmpty else { return false }
        if delegate?.terminalView(self, receivedFiles: urls) == true { return true }
        // Default (host shell): type the shell-quoted paths like Terminal.app.
        pasteText(urls.map { ShellQuote.quote($0.path) }.joined(separator: " ") + " ")
        return true
    }

    // MARK: Scroller

    private func setupScroller() {
        scroller.scrollerStyle = .overlay
        scroller.knobStyle = .default
        scroller.isEnabled = true
        scroller.alphaValue = 0
        scroller.target = self
        scroller.action = #selector(scrollerMoved(_:))
        addSubview(scroller)
    }

    private func updateScroller() {
        let sb = Int(mnd_vt_scrollback_lines(model.vt))
        let off = Int(mnd_vt_scroll_offset(model.vt))
        scroller.isHidden = sb == 0
        guard sb > 0 else { return }
        scroller.knobProportion = CGFloat(rows) / CGFloat(rows + sb)
        scroller.doubleValue = 1 - Double(off) / Double(sb)
    }

    private func flashScroller() {
        updateScroller()
        scroller.alphaValue = 1
        scrollerHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                self?.scroller.animator().alphaValue = 0
            }
        }
        scrollerHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    @objc private func scrollerMoved(_ sender: NSScroller) {
        let sb = Int(mnd_vt_scrollback_lines(model.vt))
        let target = Int(((1 - sender.doubleValue) * Double(sb)).rounded())
        let current = Int(mnd_vt_scroll_offset(model.vt))
        _ = mnd_vt_scroll(model.vt, Int32(target - current))
        refresh()
        flashScroller()
    }

    // MARK: Toast and bell

    private func setupToast() {
        toast.isHidden = true
        toast.wantsLayer = true
        toast.layer?.cornerRadius = 6
        toast.layer?.masksToBounds = true
        toast.font = .systemFont(ofSize: 12, weight: .medium)
        toast.textColor = .white
        toast.drawsBackground = true
        toast.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        toast.alignment = .center
        addSubview(toast)
    }

    private func positionToast() {
        toast.sizeToFit()
        let w = toast.frame.width + 20, h = toast.frame.height + 8
        toast.frame = NSRect(x: bounds.width - w - 16, y: 12, width: w, height: h)
    }

    /// Show a transient status message in the top-right corner.
    func showToast(_ message: String, duration: TimeInterval = 2.5) {
        toast.stringValue = message
        positionToast()
        toast.alphaValue = 1
        toast.isHidden = false
        toastHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self?.toast.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.toast.isHidden = true }
            })
        }
        toastHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func visualBell() {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1
        anim.toValue = 0
        anim.duration = 0.15
        bellLayer.add(anim, forKey: "bell")
    }

    func clearSelection() {
        selection = nil
        needsDisplay = true
    }
}

// MARK: - Helpers

extension mnd_pos: @retroactive Comparable {
    public static func < (a: mnd_pos, b: mnd_pos) -> Bool {
        a.line < b.line || (a.line == b.line && a.col < b.col)
    }

    public static func == (a: mnd_pos, b: mnd_pos) -> Bool { a.line == b.line && a.col == b.col }
}

enum ShellQuote {
    /// POSIX shell single-quoting (only when needed).
    static func quote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_~")
        if !s.isEmpty && s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
