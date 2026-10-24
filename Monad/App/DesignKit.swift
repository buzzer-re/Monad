//
//  DesignKit.swift — the building blocks of Monad's settings windows, in
//  the style of System Settings: 14 pt text, colored icon tiles, labeled
//  sliders for sizes, and status badges.
//

import SwiftUI

enum Design {
    static let body = Font.system(size: 14)
    static let rowTitle = Font.system(size: 14, weight: .medium)
    static let caption = Font.system(size: 12)
    static let pageTitle = Font.system(size: 22, weight: .bold)
    static let value = Font.system(size: 14, weight: .semibold).monospacedDigit()
}

/// White glyph on a colored rounded square, like System Settings.
extension InstanceConfig {
    /// The symbol a VM is shown with: an hourglass while it lasts one
    /// session, Apple's mark for macOS, else a server.
    var symbol: String {
        ephemeral ? "hourglass" : guestOS == .macos ? "apple.logo" : "server.rack"
    }
}

struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(color.gradient))
            .accessibilityHidden(true)
    }
}

/// Icon, title and an optional explanation on the left; the control on the right.
struct SettingRow<Control: View>: View {
    let symbol: String
    let color: Color
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Design.rowTitle)
                if let detail {
                    Text(detail).font(Design.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.vertical, 3)
    }
}

/// A bounded whole-number quantity: slider plus exact stepper, with the
/// value and its limit spelled out ("4 GB of 14 GB").
struct QuantityRow: View {
    let symbol: String
    let color: Color
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    let unit: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(symbol: symbol, color: color, title: title, detail: detail) {
                HStack(spacing: 6) {
                    Text("\(value) \(unit)").font(Design.value)
                    Stepper("", value: clamped, in: range, step: step).labelsHidden()
                }
            }
            if range.lowerBound < range.upperBound {
                HStack(spacing: 8) {
                    Text("\(range.lowerBound)").font(Design.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(clamped.wrappedValue) },
                                          set: { clamped.wrappedValue = Int(($0 / Double(step)).rounded()) * step }),
                           in: Double(range.lowerBound)...Double(range.upperBound)) {
                        Text(title)
                    }
                    // In a grouped Form a labeled slider would sit in the value column only.
                    .labelsHidden()
                    Text("\(range.upperBound) \(unit)").font(Design.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 38)
            }
        }
    }

    /// Values from older settings may lie outside today's range.
    private var clamped: Binding<Int> {
        Binding(get: { min(max(value, range.lowerBound), range.upperBound) },
                set: { value = min(max($0, range.lowerBound), range.upperBound) })
    }
}

/// Large page header: tile, title and a line of context.
struct PageHeader: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, color: color, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Design.pageTitle)
                Text(subtitle).font(Design.body).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

/// A notice inside a form: colored symbol and text.
struct Notice: View {
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(Design.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - VM state

extension VMState {
    var tint: Color {
        switch self {
        case .ready: return .green
        case .starting, .booting, .preparing, .stopping: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    /// Short label for badges ("Running", "Stopped", …).
    var badge: String {
        switch self {
        case .ready: return "Running"
        case .starting, .booting: return "Starting"
        case .preparing: return "Preparing"
        case .stopping: return "Stopping"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
}

struct StatusBadge: View {
    let state: VMState

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(state.tint).frame(width: 7, height: 7)
            Text(state.badge).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(state.tint.opacity(0.14)))
        .foregroundStyle(state == .stopped ? Color.secondary : state.tint)
        .help(state.label)
    }
}

/// Views left to right, each whole, wrapped onto the next line when the
/// width runs out (a VM's name and its tags in a narrow window).
struct Flow: Layout {
    static let defaultLineSpacing: CGFloat = 4
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = Flow.defaultLineSpacing

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.size(of: frames(proposal.width, subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(bounds.width, subviews)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(_ width: CGFloat?, _ subviews: Subviews) -> [CGRect] {
        let width = width ?? .infinity
        let sizes = subviews.map { view -> CGSize in
            let ideal = view.sizeThatFits(.unspecified)
            return ideal.width <= width ? ideal : view.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
        return Self.frames(for: sizes, width: width, spacing: spacing, lineSpacing: lineSpacing)
    }

    /// Where each size goes: along a line while it fits, centred in its
    /// line's height; one wider than `width` is narrowed to it.
    static func frames(for sizes: [CGSize], width: CGFloat, spacing: CGFloat,
                       lineSpacing: CGFloat = defaultLineSpacing) -> [CGRect] {
        var frames: [CGRect] = []
        var line: [Int] = []
        var x: CGFloat = 0, y: CGFloat = 0
        func endLine() {
            let height = line.map { frames[$0].height }.max() ?? 0
            for i in line { frames[i].origin.y = y + (height - frames[i].height) / 2 }
            y += height + lineSpacing
            line = []
            x = 0
        }
        for size in sizes {
            let w = min(size.width, width)
            if !line.isEmpty, x + spacing + w > width { endLine() }
            if !line.isEmpty { x += spacing }
            frames.append(CGRect(x: x, y: 0, width: w, height: size.height))
            line.append(frames.count - 1)
            x += w
        }
        if !line.isEmpty { endLine() }
        return frames
    }

    /// The size the frames take.
    static func size(of frames: [CGRect]) -> CGSize {
        CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }
}

/// Small capsule tag ("ephemeral", "2 forwards").
struct TagLabel: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .fixedSize()
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }
}

extension HostCapacity {
    /// "This Mac: 10 cores · 16 GB memory (2 GB kept for macOS)".
    var summary: String {
        "This Mac: \(cores) cores · \(memoryGiB) GB memory (\(HostCapacity.reservedMemoryGiB) GB kept for macOS)"
    }
}
