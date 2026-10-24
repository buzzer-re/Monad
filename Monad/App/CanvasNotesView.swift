//
//  CanvasNotesView.swift — writing on the canvas (CanvasNotes): the tool
//  palette (select, note, label, zone, arrow, pen, and the colour), notes
//  as Markdown cards that are moved, resized and edited in place, labels as
//  chips on VMs and networks, zones with their title, and the drawing of
//  zones, arrows and ink. What an agent writes appears here as it is
//  written, growing in (docs/CANVAS.md).
//

import AppKit
import SwiftUI

/// What a click or a drag on the canvas does.
enum CanvasTool: String, CaseIterable, Identifiable {
    case select, note, label, zone, arrow, pen

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .note: return "note.text"
        case .label: return "tag"
        case .zone: return "rectangle.dashed"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        }
    }

    var help: String {
        switch self {
        case .select: return "Select, move and pan (Esc)"
        case .note: return "Note: click the canvas, or a VM or network to pin it there"
        case .label: return "Label: click a VM or a network"
        case .zone: return "Zone: drag an area, or click a network to wrap it"
        case .arrow: return "Arrow: click where it starts, then where it ends"
        case .pen: return "Pen: draw"
        }
    }
}

extension CanvasStyle {
    private static func color(_ light: UInt32, _ dark: UInt32, _ alpha: CGFloat = 1) -> Color {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: alpha)
        }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light) })
    }

    /// A tint's paper (notes), its ink (lines, text on chips) and its wash (zones).
    static func paper(_ t: CanvasNote.Tint) -> Color {
        switch t {
        case .yellow: return color(0xFFF4B8, 0x3D3618)
        case .orange: return color(0xFFE0C2, 0x42291A)
        case .red: return color(0xFFD6D3, 0x441E1E)
        case .green: return color(0xD8F2D4, 0x1C3820)
        case .blue: return color(0xD6E6FF, 0x1A2A44)
        case .purple: return color(0xE8DCFF, 0x2E2244)
        case .gray: return color(0xECEAE6, 0x2A282D)
        }
    }

    static func ink(_ t: CanvasNote.Tint) -> Color {
        switch t {
        case .yellow: return color(0xB98A00, 0xF2C94C)
        case .orange: return color(0xD9551F, 0xFF8A4C)
        case .red: return color(0xD12F2F, 0xFF6B6B)
        case .green: return color(0x2E8B47, 0x5BD17A)
        case .blue: return color(0x2F6FD6, 0x6EA8FF)
        case .purple: return color(0x7B4BD6, 0xB08CFF)
        case .gray: return color(0x6B6760, 0xB5B0A8)
        }
    }

    static func wash(_ t: CanvasNote.Tint) -> Color { ink(t).opacity(0.07) }
}

/// Who wrote it, when it was not the user.
func canvasAuthor(_ author: String) -> String? {
    switch author {
    case "you": return nil
    case "mac": return "an agent on this Mac"
    default: return "an agent in \(author.dropFirst(3))"
    }
}

// MARK: - Notes

/// A note: Markdown on its colour, edited in place (double-click), moved by
/// a drag, resized from its corner when selected.
struct CanvasNoteCard: View {
    let note: CanvasNote
    let rect: CGRect
    @ObservedObject var canvas: CanvasWindowModel
    @State private var text = ""
    @State private var dragStart: CGRect?
    @FocusState private var focused: Bool

    private var selected: Bool { canvas.selectedNote == note.id }
    private var editing: Bool { canvas.editingNote == note.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editing {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .onAppear {
                        text = note.text
                        focused = true
                    }
                    .onChange(of: focused) { _, now in if !now { canvas.finishEditing(note.id, text: text) } }
                    .onKeyPress(.escape) {
                        canvas.finishEditing(note.id, text: text)
                        return .handled
                    }
                Text("Markdown · Esc or click away when done").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text(Self.markdown(note.text))
                    .environment(\.openURL, OpenURLAction { url in
                        ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
                    })
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            }
            if !editing, note.on != nil || canvasAuthor(note.author) != nil {
                HStack(spacing: 4) {
                    if note.on != nil { Image(systemName: "pin.fill").font(.system(size: 9)) }
                    if let who = canvasAuthor(note.author) {
                        Image(systemName: "sparkles").font(.system(size: 9))
                        Text(who).font(.system(size: 10)).lineLimit(1)
                    }
                }
                .foregroundStyle(CanvasStyle.ink(note.tint))
            }
        }
        .padding(12)
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(CanvasStyle.paper(note.tint)))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10)
                .fill(CanvasStyle.ink(note.tint)).frame(height: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(selected ? CanvasStyle.ink(note.tint) : CanvasStyle.cardLine, lineWidth: selected ? 2 : 1))
        .overlay(alignment: .bottomTrailing) { if selected && !editing { resizeHandle } }
        .shadow(color: .black.opacity(selected ? 0.25 : 0.14), radius: selected ? 10 : 4, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(count: 2) {
            canvas.selectedNote = note.id
            canvas.editingNote = note.id
        }
        .onTapGesture {
            if !canvas.toolTap("note:" + note.id) { canvas.selectedNote = note.id }
        }
        .gesture(editing ? nil : DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
            .onChanged { v in
                let start = dragStart ?? rect
                if dragStart == nil { dragStart = start }
                canvas.moving[note.id] = start.offsetBy(dx: v.translation.width / canvas.zoom, dy: v.translation.height / canvas.zoom)
            }
            .onEnded { _ in place() })
        .contextMenu { CanvasNoteMenu(note: note, canvas: canvas) }
        .scaleEffect(canvas.zoom)
        .position(canvas.screen(CGPoint(x: rect.midX, y: rect.midY)))
        .transition(.scale(scale: 0.3).combined(with: .opacity))
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(CanvasStyle.ink(note.tint))
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                .onChanged { v in
                    let start = dragStart ?? rect
                    if dragStart == nil { dragStart = start }
                    canvas.moving[note.id] = CGRect(x: start.minX, y: start.minY,
                                                    width: max(120, start.width + v.translation.width / canvas.zoom),
                                                    height: max(56, start.height + v.translation.height / canvas.zoom))
                }
                .onEnded { _ in place() })
            .help("Resize")
    }

    /// Let go: the note keeps the place it was given.
    private func place() {
        dragStart = nil
        guard let r = canvas.moving.removeValue(forKey: note.id), var n = canvas.note(note.id) else { return }
        n.frame = r.integral
        canvas.save(n)
    }

    /// A note's text, with links only on the web (as the terminal's): a
    /// link to a file, an app or System Settings shows as plain words.
    static func markdown(_ text: String) -> AttributedString {
        var shown = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let elsewhere = shown.runs.filter { run in run.link.map { !["http", "https"].contains($0.scheme?.lowercased() ?? "") } ?? false }
        for range in elsewhere.map(\.range) { shown[range].link = nil }
        return shown
    }
}

/// A note's, label's, zone's, arrow's or stroke's right-click menu.
struct CanvasNoteMenu: View {
    let note: CanvasNote
    @ObservedObject var canvas: CanvasWindowModel

    var body: some View {
        if note.kind != .ink {
            Button(note.kind == .arrow ? "Edit Words" : "Edit") {
                canvas.selectedNote = note.id
                canvas.editingNote = note.id
            }
        }
        Menu("Colour") {
            ForEach(CanvasNote.Tint.allCases, id: \.self) { t in
                Button(t.rawValue.capitalized) { canvas.recolor(note.id, t) }
            }
        }
        if note.kind == .note, note.on != nil {
            Button("Unpin") {
                guard var n = canvas.note(note.id) else { return }
                n.frame = canvas.places[note.id]
                n.on = nil
                canvas.save(n)
            }
        }
        if let who = canvasAuthor(note.author) {
            Text("Written by \(who)")
        }
        Divider()
        Button("Delete", role: .destructive) { canvas.removeNote(note.id) }
    }
}

// MARK: - Labels

/// The labels on one VM or network: chips in their colours, under a VM's
/// card or along a network's top edge.
struct CanvasLabels: View {
    let target: String
    let labels: [CanvasNote]
    /// Where the row starts (canvas coordinates), its top left.
    let origin: CGPoint
    @ObservedObject var canvas: CanvasWindowModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(labels) { CanvasLabelChip(note: $0, canvas: canvas) }
        }
        .fixedSize()
        .scaleEffect(canvas.zoom, anchor: .topLeading)
        .offset(x: origin.x * canvas.zoom + canvas.pan.width, y: origin.y * canvas.zoom + canvas.pan.height)
    }
}

struct CanvasLabelChip: View {
    let note: CanvasNote
    @ObservedObject var canvas: CanvasWindowModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let selected = canvas.selectedNote == note.id
        Group {
            if canvas.editingNote == note.id {
                TextField("Label", text: $text)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 60)
                    .fixedSize()
                    .focused($focused)
                    .onAppear {
                        text = note.text
                        focused = true
                    }
                    .onSubmit { canvas.finishEditing(note.id, text: text) }
                    .onChange(of: focused) { _, now in if !now { canvas.finishEditing(note.id, text: text) } }
            } else {
                HStack(spacing: 4) {
                    if canvasAuthor(note.author) != nil { Image(systemName: "sparkles").font(.system(size: 9)) }
                    Text(note.text).lineLimit(1)
                }
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(CanvasStyle.ink(note.tint))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(CanvasStyle.paper(note.tint)))
        .overlay(Capsule().stroke(CanvasStyle.ink(note.tint).opacity(selected ? 1 : 0.35), lineWidth: selected ? 1.5 : 1))
        .contentShape(Capsule())
        .onTapGesture(count: 2) {
            canvas.selectedNote = note.id
            canvas.editingNote = note.id
        }
        .onTapGesture { canvas.selectedNote = note.id }
        .contextMenu { CanvasNoteMenu(note: note, canvas: canvas) }
        .help(canvasAuthor(note.author).map { "Written by \($0)" } ?? "")
        .transition(.scale(scale: 0.3).combined(with: .opacity))
    }
}

// MARK: - Zones

/// A zone's title: selects it, moves a drawn zone, edits on a double-click.
struct CanvasZoneTitle: View {
    let note: CanvasNote
    let rect: CGRect
    @ObservedObject var canvas: CanvasWindowModel
    @State private var text = ""
    @State private var dragStart: CGRect?
    @FocusState private var focused: Bool

    var body: some View {
        let selected = canvas.selectedNote == note.id
        Group {
            if canvas.editingNote == note.id {
                TextField("Zone", text: $text)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 120)
                    .fixedSize()
                    .focused($focused)
                    .onAppear {
                        text = note.text
                        focused = true
                    }
                    .onSubmit { canvas.finishEditing(note.id, text: text) }
                    .onChange(of: focused) { _, now in if !now { canvas.finishEditing(note.id, text: text) } }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: note.around == nil ? "rectangle.dashed" : "square.dashed.inset.filled")
                    Text(note.text.isEmpty ? "Zone" : note.text).lineLimit(1)
                    if canvasAuthor(note.author) != nil { Image(systemName: "sparkles").font(.system(size: 10)) }
                }
            }
        }
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(CanvasStyle.ink(note.tint))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(CanvasStyle.paper(note.tint).opacity(selected ? 1 : 0.85)))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture(count: 2) {
            canvas.selectedNote = note.id
            canvas.editingNote = note.id
        }
        .onTapGesture { canvas.selectedNote = note.id }
        .gesture(note.frame == nil ? nil : DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
            .onChanged { v in
                let start = dragStart ?? rect
                if dragStart == nil { dragStart = start }
                canvas.moving[note.id] = start.offsetBy(dx: v.translation.width / canvas.zoom, dy: v.translation.height / canvas.zoom)
            }
            .onEnded { _ in
                dragStart = nil
                guard let r = canvas.moving.removeValue(forKey: note.id), var n = canvas.note(note.id) else { return }
                n.frame = r.integral
                canvas.save(n)
            })
        .contextMenu { CanvasNoteMenu(note: note, canvas: canvas) }
        .help(note.around == nil ? "Drag to move the zone" : "This zone wraps \(note.around!.count) things and follows them")
        .scaleEffect(canvas.zoom, anchor: .topLeading)
        .offset(x: (rect.minX + 10) * canvas.zoom + canvas.pan.width, y: (rect.minY + 6) * canvas.zoom + canvas.pan.height)
    }
}

/// A drawn zone's corner, when selected: resizes it.
struct CanvasZoneHandle: View {
    let note: CanvasNote
    let rect: CGRect
    @ObservedObject var canvas: CanvasWindowModel
    @State private var start: CGRect?

    var body: some View {
        Circle()
            .fill(CanvasStyle.ink(note.tint))
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(CanvasStyle.card, lineWidth: 2))
            .contentShape(Circle().inset(by: -6))
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                .onChanged { v in
                    let s = start ?? rect
                    if start == nil { start = s }
                    canvas.moving[note.id] = CGRect(x: s.minX, y: s.minY,
                                                    width: max(120, s.width + v.translation.width / canvas.zoom),
                                                    height: max(80, s.height + v.translation.height / canvas.zoom))
                }
                .onEnded { _ in
                    start = nil
                    guard let r = canvas.moving.removeValue(forKey: note.id), var n = canvas.note(note.id) else { return }
                    n.frame = r.integral
                    canvas.save(n)
                })
            .help("Resize")
            .position(canvas.screen(CGPoint(x: rect.maxX, y: rect.maxY)))
    }
}

// MARK: - Arrows' words

/// An arrow's words in the middle of it: selects it, edits on a double-click.
struct CanvasArrowWords: View {
    let note: CanvasNote
    let at: CGPoint
    @ObservedObject var canvas: CanvasWindowModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let selected = canvas.selectedNote == note.id
        Group {
            if canvas.editingNote == note.id {
                TextField("Words", text: $text)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 80)
                    .fixedSize()
                    .focused($focused)
                    .onAppear {
                        text = note.text
                        focused = true
                    }
                    .onSubmit { canvas.finishEditing(note.id, text: text) }
                    .onChange(of: focused) { _, now in if !now { canvas.finishEditing(note.id, text: text) } }
            } else {
                Text(note.text).lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: 220)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(CanvasStyle.ink(note.tint))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(CanvasStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(CanvasStyle.ink(note.tint).opacity(selected ? 1 : 0.4)))
        .fixedSize()
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture(count: 2) {
            canvas.selectedNote = note.id
            canvas.editingNote = note.id
        }
        .onTapGesture { canvas.selectedNote = note.id }
        .contextMenu { CanvasNoteMenu(note: note, canvas: canvas) }
        .scaleEffect(canvas.zoom)
        .position(canvas.screen(at))
    }
}

// MARK: - Drawing

@MainActor
enum CanvasNotesDrawing {
    /// A stroke through its points, smoothed through their midpoints.
    static func smooth(_ points: [CGPoint]) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { p.addLine(to: $0) }
            return p
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            p.addQuadCurve(to: mid, control: points[i])
        }
        p.addLine(to: points[points.count - 1])
        return p
    }

    /// Zones, under the networks.
    static func zones(_ ctx: inout GraphicsContext, _ canvas: CanvasWindowModel, places: [String: CGRect], now: Date) {
        for n in canvas.notes where n.kind == .zone {
            guard let r = places[n.id] else { continue }
            let g = Double(canvas.growth("note:" + n.id, at: now))
            let shape = Path(roundedRect: r, cornerRadius: 22)
            let selected = canvas.selectedNote == n.id
            ctx.fill(shape, with: .color(CanvasStyle.wash(n.tint).opacity(g)))
            ctx.stroke(shape, with: .color(CanvasStyle.ink(n.tint).opacity((selected ? 0.9 : 0.45) * g)),
                       style: StrokeStyle(lineWidth: selected ? 2.5 : 1.6, dash: n.around == nil ? [10, 7] : [2, 6]))
        }
    }

    /// Arrows, ink, pinned notes' threads, and what is being drawn.
    static func strokes(_ ctx: inout GraphicsContext, _ canvas: CanvasWindowModel, places: [String: CGRect], now: Date) {
        let m = canvas.model
        for n in canvas.notes {
            let g = canvas.growth("note:" + n.id, at: now)
            let selected = canvas.selectedNote == n.id
            let ink = CanvasStyle.ink(n.tint)
            switch n.kind {
            case .arrow:
                guard let on = n.on, let to = n.to, let a = CanvasNotesLayout.rect(of: on, places: places, in: m),
                      let b = CanvasNotesLayout.rect(of: to, places: places, in: m) else { continue }
                let arrow = CanvasNotesLayout.arrow(from: a.insetBy(dx: -6, dy: -6), to: b.insetBy(dx: -6, dy: -6))
                arrowPath(&ctx, arrow, color: ink, width: selected ? 3 : 2, progress: g, glow: selected)
            case .ink:
                guard let pts = n.points else { continue }
                let path = smooth(pts).trimmedPath(from: 0, to: g)
                if selected { ctx.stroke(path, with: .color(ink.opacity(0.25)), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)) }
                ctx.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            case .note:
                // A pinned note moved away from what it is on: a thread to it.
                guard n.frame != nil, let on = n.on, let r = places[n.id], let t = m.rect(of: on) else { continue }
                let a = CanvasNotesLayout.edge(of: r, toward: CGPoint(x: t.midX, y: t.midY))
                let b = CanvasNotesLayout.edge(of: t, toward: CGPoint(x: r.midX, y: r.midY))
                var p = Path()
                p.move(to: a)
                p.addLine(to: b)
                ctx.stroke(p, with: .color(ink.opacity(0.6)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 4]))
                ctx.fill(Path(ellipseIn: CGRect(x: b.x - 3, y: b.y - 3, width: 6, height: 6)), with: .color(ink))
            case .label, .zone:
                break
            }
        }
        if let s = canvas.sketch {
            let ink = CanvasStyle.ink(s.tint)
            if s.kind == .ink, let pts = s.points {
                ctx.stroke(smooth(pts), with: .color(ink), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            } else if s.kind == .zone, let r = s.frame {
                let shape = Path(roundedRect: r, cornerRadius: 22)
                ctx.fill(shape, with: .color(CanvasStyle.wash(s.tint)))
                ctx.stroke(shape, with: .color(ink.opacity(0.8)), style: StrokeStyle(lineWidth: 1.6, dash: [10, 7]))
            }
        }
        if let start = canvas.arrowStart, let a = CanvasNotesLayout.rect(of: start, places: places, in: m) {
            let p = canvas.pointer
            let arrow = CanvasNotesLayout.arrow(from: a.insetBy(dx: -6, dy: -6), to: CGRect(origin: p, size: .zero))
            arrowPath(&ctx, arrow, color: CanvasStyle.ink(canvas.tint).opacity(0.7), width: 2, progress: 1, glow: false)
        }
    }

    static func arrowPath(_ ctx: inout GraphicsContext, _ a: CanvasNotesLayout.Arrow, color: Color, width: CGFloat,
                          progress: CGFloat, glow: Bool) {
        var p = Path()
        p.move(to: a.start)
        p.addQuadCurve(to: a.end, control: a.control)
        let drawn = p.trimmedPath(from: 0, to: progress)
        if glow { ctx.stroke(drawn, with: .color(color.opacity(0.25)), style: StrokeStyle(lineWidth: width + 6, lineCap: .round)) }
        ctx.stroke(drawn, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        guard progress >= 0.98 else { return }
        let h = a.heading, len: CGFloat = 11 + width
        var head = Path()
        head.move(to: a.end)
        head.addLine(to: CGPoint(x: a.end.x - len * cos(h - 0.42), y: a.end.y - len * sin(h - 0.42)))
        head.addLine(to: CGPoint(x: a.end.x - len * cos(h + 0.42), y: a.end.y - len * sin(h + 0.42)))
        head.closeSubpath()
        ctx.fill(head, with: .color(color))
    }
}

// MARK: - Palette

/// The tools and the colour, top middle.
struct CanvasToolPalette: View {
    @ObservedObject var canvas: CanvasWindowModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CanvasTool.allCases) { t in
                Button {
                    canvas.arrowStart = nil
                    canvas.sketch = nil
                    canvas.tool = t
                } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(canvas.tool == t ? CanvasStyle.ember.opacity(0.18) : .clear))
                        .foregroundStyle(canvas.tool == t ? CanvasStyle.ember : Color.primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t.help)
            }
            Divider().frame(height: 18).padding(.horizontal, 4)
            ForEach(CanvasNote.Tint.allCases, id: \.self) { t in
                let current = canvas.selectedNote.flatMap(canvas.note)?.tint ?? canvas.tint
                Button {
                    if let id = canvas.selectedNote { canvas.recolor(id, t) } else { canvas.tint = t }
                } label: {
                    Circle().fill(CanvasStyle.ink(t)).frame(width: 13, height: 13)
                        .overlay(Circle().stroke(Color.primary.opacity(current == t ? 0.8 : 0), lineWidth: 2).padding(-3))
                        .frame(width: 20, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(canvas.selectedNote == nil ? "Colour for what you write next" : "Colour of the selection")
            }
            if let id = canvas.selectedNote {
                Divider().frame(height: 18).padding(.horizontal, 4)
                Button { canvas.removeNote(id) } label: {
                    Image(systemName: "trash").font(.system(size: 12)).frame(width: 28, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete the selection")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(CanvasStyle.cardLine))
        .padding(.top, 10)
    }
}
