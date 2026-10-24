//
//  BoxDrawing.swift — pixel-exact rendering of box-drawing and block
//  characters so TUI borders connect without gaps between cells.
//

import CoreGraphics

enum BoxDrawing {
    /// Line weights (0 none, 1 light, 2 heavy) toward up, down, left, right.
    private struct Lines {
        var u: UInt8, d: UInt8, l: UInt8, r: UInt8
    }

    private static let lines: [UInt32: Lines] = {
        var t: [UInt32: Lines] = [:]
        func add(_ cp: UInt32, _ u: UInt8, _ d: UInt8, _ l: UInt8, _ r: UInt8) { t[cp] = Lines(u: u, d: d, l: l, r: r) }
        add(0x2500, 0, 0, 1, 1); add(0x2501, 0, 0, 2, 2)
        add(0x2502, 1, 1, 0, 0); add(0x2503, 2, 2, 0, 0)
        add(0x250C, 0, 1, 0, 1); add(0x250F, 0, 2, 0, 2)
        add(0x2510, 0, 1, 1, 0); add(0x2513, 0, 2, 2, 0)
        add(0x2514, 1, 0, 0, 1); add(0x2517, 2, 0, 0, 2)
        add(0x2518, 1, 0, 1, 0); add(0x251B, 2, 0, 2, 0)
        add(0x251C, 1, 1, 0, 1); add(0x2523, 2, 2, 0, 2)
        add(0x2524, 1, 1, 1, 0); add(0x252B, 2, 2, 2, 0)
        add(0x252C, 0, 1, 1, 1); add(0x2533, 0, 2, 2, 2)
        add(0x2534, 1, 0, 1, 1); add(0x253B, 2, 0, 2, 2)
        add(0x253C, 1, 1, 1, 1); add(0x254B, 2, 2, 2, 2)
        add(0x2574, 0, 0, 1, 0); add(0x2575, 1, 0, 0, 0); add(0x2576, 0, 0, 0, 1); add(0x2577, 0, 1, 0, 0)
        add(0x2578, 0, 0, 2, 0); add(0x2579, 2, 0, 0, 0); add(0x257A, 0, 0, 0, 2); add(0x257B, 0, 2, 0, 0)
        // Rounded corners are drawn square; they still connect cleanly.
        add(0x256D, 0, 1, 0, 1); add(0x256E, 0, 1, 1, 0); add(0x256F, 1, 0, 1, 0); add(0x2570, 1, 0, 0, 1)
        return t
    }()

    static func handles(_ cp: UInt32) -> Bool {
        lines[cp] != nil || (0x2580...0x2593).contains(cp)
    }

    /// Draw cp into rect (a cell, or two for wide cells) using the current fill color.
    static func draw(_ cp: UInt32, in rect: CGRect, scale: CGFloat, context ctx: CGContext) {
        if let l = lines[cp] {
            let px = 1 / max(scale, 1)
            let cellW = rect.width > rect.height ? rect.width / 2 : rect.width
            let light = max(px, (cellW / 8 * scale).rounded() / scale)
            func thickness(_ w: UInt8) -> CGFloat { w == 2 ? light * 2 : light }
            let cx = (rect.midX * scale).rounded() / scale
            let cy = (rect.midY * scale).rounded() / scale
            // Horizontal/vertical strokes extend to the cell edges and overlap
            // at the center so joins are solid.
            let hw = max(thickness(l.u), thickness(l.d))
            let hh = max(thickness(l.l), thickness(l.r))
            if l.l > 0 {
                let t = thickness(l.l)
                ctx.fill(CGRect(x: rect.minX, y: cy - t / 2, width: cx - rect.minX + hw / 2, height: t))
            }
            if l.r > 0 {
                let t = thickness(l.r)
                ctx.fill(CGRect(x: cx - hw / 2, y: cy - t / 2, width: rect.maxX - cx + hw / 2, height: t))
            }
            if l.u > 0 {
                let t = thickness(l.u)
                ctx.fill(CGRect(x: cx - t / 2, y: rect.minY, width: t, height: cy - rect.minY + hh / 2))
            }
            if l.d > 0 {
                let t = thickness(l.d)
                ctx.fill(CGRect(x: cx - t / 2, y: cy - hh / 2, width: t, height: rect.maxY - cy + hh / 2))
            }
            return
        }
        // Block elements (view is flipped: minY is the top).
        let w = rect.width, h = rect.height
        switch cp {
        case 0x2580: ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: w, height: h / 2))
        case 0x2581...0x2588:
            let eighths = CGFloat(cp - 0x2580)
            ctx.fill(CGRect(x: rect.minX, y: rect.maxY - h * eighths / 8, width: w, height: h * eighths / 8))
        case 0x2589...0x258F:
            let eighths = CGFloat(8 - (cp - 0x2588))
            ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: w * eighths / 8, height: h))
        case 0x2590: ctx.fill(CGRect(x: rect.midX, y: rect.minY, width: w / 2, height: h))
        case 0x2591, 0x2592, 0x2593:
            ctx.saveGState()
            ctx.setAlpha(CGFloat(cp - 0x2590) * 0.25)
            ctx.fill(rect)
            ctx.restoreGState()
        default: break
        }
    }
}
