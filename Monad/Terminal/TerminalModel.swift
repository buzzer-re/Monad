//
//  TerminalModel.swift — Swift owner of an mnd_vt instance.
//
//  The model outlives individual PTY connections so a tab keeps its screen
//  and scrollback across reconnects.
//

import Foundation

final class TerminalModel {
    let vt: OpaquePointer

    /// Bytes the emulator answers to the application (DA, DSR, ...). Invoked
    /// on the thread that fed the model.
    var replyHandler: ((Data) -> Void)?
    /// UI events, delivered on the main queue.
    var onTitle: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onClipboard: ((String) -> Void)?
    var onDirectory: ((String) -> Void)?
    /// An inline image was decoded: redraw.
    var onImagesChanged: (() -> Void)?

    /// Inline images the guest sent, decoded (TerminalImages).
    let images = TerminalImages()
    /// The VM's setting (inlineImages): off for host shells and VMs that do
    /// not allow images, and never while the boot console shows. Set on the
    /// main thread.
    var imagesAllowed = false {
        didSet { applyImages() }
    }

    /// A cell in device pixels, for sizing what is decoded.
    private let pixelsLock = NSLock()
    private var cellPixels = (width: 8, height: 16)

    init?(cols: Int, rows: Int, scrollback: Int) {
        var cb = mnd_vt_callbacks()
        cb.write = { ctx, data, len in
            guard let ctx, let data else { return }
            let model = Unmanaged<TerminalModel>.fromOpaque(ctx).takeUnretainedValue()
            model.replyHandler?(Data(bytes: data, count: len))
        }
        cb.title = { ctx, title in
            guard let ctx, let title else { return }
            let model = Unmanaged<TerminalModel>.fromOpaque(ctx).takeUnretainedValue()
            let s = String(cString: title)
            DispatchQueue.main.async { model.onTitle?(s) }
        }
        cb.cwd = { ctx, url in
            guard let ctx, let url else { return }
            let model = Unmanaged<TerminalModel>.fromOpaque(ctx).takeUnretainedValue()
            let s = String(cString: url)
            DispatchQueue.main.async { model.onDirectory?(s) }
        }
        cb.bell = { ctx in
            guard let ctx else { return }
            let model = Unmanaged<TerminalModel>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { model.onBell?() }
        }
        cb.clipboard = { ctx, data, len in
            guard let ctx, let data else { return }
            let model = Unmanaged<TerminalModel>.fromOpaque(ctx).takeUnretainedValue()
            guard !model.ignoresClipboard else { return }
            let s = String(decoding: UnsafeRawBufferPointer(start: data, count: len), as: UTF8.self)
            DispatchQueue.main.async { model.onClipboard?(s) }
        }
        cb.image = { ctx, info, data, len in
            guard let ctx, let info, let data else { return }
            let model = Unmanaged<TerminalModel>.fromOpaque(ctx).takeUnretainedValue()
            let i = info.pointee
            let file = Data(bytes: data, count: len)
            let px = model.pixelsLock.withLock { model.cellPixels }
            // Never larger than its cells show.
            let maxSide = max(Int(i.cols) * px.width, Int(i.rows) * px.height)
            DispatchQueue.global(qos: .userInitiated).async {
                guard let cg = TerminalImages.decode(file, format: i.format, maxPixelSize: maxSide) else { return }
                model.images.store(TerminalImages.Image(cgImage: cg, cols: Int(i.cols), rows: Int(i.rows),
                                                        fillX: CGFloat(i.fill_x), fillY: CGFloat(i.fill_y)), id: i.id)
                DispatchQueue.main.async { model.onImagesChanged?() }
            }
        }
        guard let vt = mnd_vt_create(Int32(cols), Int32(rows), Int32(scrollback), nil) else { return nil }
        self.vt = vt
        // The context pointer only exists once self is initialized.
        cb.ctx = Unmanaged.passUnretained(self).toOpaque()
        withUnsafePointer(to: cb) { mnd_vt_set_callbacks(vt, $0) }
    }

    deinit {
        mnd_vt_destroy(vt)
    }

    func feed(_ buffer: UnsafeRawBufferPointer) {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        mnd_vt_feed(vt, base, buffer.count)
    }

    /// From the first byte of the boot console until `endConsole`: clipboard
    /// writes are dropped as they are parsed, also one the console left open
    /// for a later escape of Monad's own to finish, and images are off.
    /// Written on the main thread before any shell's output is fed.
    private var ignoresClipboard = false

    /// The VM's boot console: shown, never allowed to set the clipboard or
    /// show an image.
    func feedConsole(_ data: Data) {
        if !ignoresClipboard {
            ignoresClipboard = true
            applyImages()
        }
        data.withUnsafeBytes { feed($0) }
    }

    /// The console is done: a string it left open is cancelled (CAN) before
    /// the clipboard is listened to again and images may be on.
    func endConsole() {
        guard ignoresClipboard else { return }
        feed("\u{18}")
        ignoresClipboard = false
        applyImages()
    }

    private func applyImages() {
        mnd_vt_set_images(vt, imagesAllowed && !ignoresClipboard)
    }

    /// A cell's size in device pixels (image sizes, CSI 14 t and 16 t).
    func setCellPixels(width: Int, height: Int) {
        pixelsLock.withLock { cellPixels = (max(1, width), max(1, height)) }
        mnd_vt_set_cell_pixels(vt, Int32(width), Int32(height))
    }

    func feed(_ string: String) {
        var s = string
        s.withUTF8 { feed(UnsafeRawBufferPointer($0)) }
    }

    @discardableResult
    func resize(cols: Int, rows: Int) -> Bool {
        mnd_vt_resize(vt, Int32(cols), Int32(rows))
    }

    var size: (cols: Int, rows: Int) {
        var c: Int32 = 0, r: Int32 = 0
        mnd_vt_size(vt, &c, &r)
        return (Int(c), Int(r))
    }

    /// Run body with the terminal lock held.
    /// Rows from the cursor's row up to the first row of its line (soft
    /// wraps). `afterWriting`: the cursor ends text written on this line, so
    /// at column 0 it was pushed onto a fresh row (a re-wrap leaves it there
    /// when the text fills its last row) and that row belongs to the line.
    func rowsUpToLineStart(afterWriting: Bool) -> Int {
        withLock {
            let c = mnd_vt_cursor(vt)
            var y = Int(c.y), up = 0
            if afterWriting, c.x == 0, y > 0 {
                y -= 1
                up = 1
            }
            while y > 0, mnd_vt_view_row_wrapped(vt, Int32(y - 1)) {
                y -= 1
                up += 1
            }
            return up
        }
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        mnd_vt_lock(vt)
        defer { mnd_vt_unlock(vt) }
        return try body()
    }

    func mode(_ m: mnd_mode) -> Bool { withLock { mnd_vt_mode(vt, m) } }
    var mouseTracking: mnd_mouse_tracking { withLock { mnd_vt_mouse_tracking(vt) } }

    func setTheme(_ theme: TerminalTheme) {
        let pal = theme.palette.map { $0.hex }
        pal.withUnsafeBufferPointer { p in
            mnd_vt_set_theme(vt, p.baseAddress, theme.foreground.hex, theme.background.hex)
        }
    }

    // MARK: Encoding helpers

    func encodeKey(_ key: mnd_key, mods: UInt32) -> Data? {
        var buf = [CChar](repeating: 0, count: 64)
        let n = mnd_vt_encode_key(vt, key, mods, &buf, buf.count)
        return n > 0 ? Data(bytes: buf, count: n) : nil
    }

    func encodeChar(_ scalar: Unicode.Scalar, mods: UInt32) -> Data? {
        var buf = [CChar](repeating: 0, count: 64)
        let n = mnd_vt_encode_char(vt, scalar.value, mods, &buf, buf.count)
        return n > 0 ? Data(bytes: buf, count: n) : nil
    }

    func encodeMouse(button: Int, action: mnd_mouse_action, mods: UInt32, col: Int, row: Int) -> Data? {
        var buf = [CChar](repeating: 0, count: 64)
        let n = mnd_vt_encode_mouse(vt, Int32(button), action, mods, Int32(col), Int32(row), &buf, buf.count)
        return n > 0 ? Data(bytes: buf, count: n) : nil
    }

    func encodeFocus(_ focused: Bool) -> Data? {
        var buf = [CChar](repeating: 0, count: 8)
        let n = mnd_vt_encode_focus(vt, focused, &buf, buf.count)
        return n > 0 ? Data(bytes: buf, count: n) : nil
    }

    func encodePaste(_ text: String) -> Data? {
        var s = text
        return s.withUTF8 { utf8 -> Data? in
            var outLen = 0
            guard let base = utf8.baseAddress,
                  let p = base.withMemoryRebound(to: CChar.self, capacity: utf8.count, {
                      mnd_vt_encode_paste(vt, $0, utf8.count, &outLen)
                  })
            else { return nil }
            defer { free(p) }
            return outLen > 0 ? Data(bytes: p, count: outLen) : nil
        }
    }

    // MARK: Selection

    func copyText(from a: mnd_pos, to b: mnd_pos, block: Bool) -> String? {
        guard let p = mnd_vt_copy_text(vt, a, b, block) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
}
