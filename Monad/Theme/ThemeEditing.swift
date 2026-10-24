//
//  ThemeEditing.swift — what the theme editor needs besides its views:
//  duplicating, exporting, color conversion, the monospaced font list and
//  the preview text.
//

import AppKit

enum ThemeEditing {
    enum ExportFormat: String, CaseIterable, Identifiable {
        case terminal, iterm, monad
        var id: String { rawValue }

        var title: String {
            switch self {
            case .terminal: return "Terminal Profile (.terminal)"
            case .iterm: return "iTerm2 Colors (.itermcolors)"
            case .monad: return "Monad Theme (.json)"
            }
        }

        var fileExtension: String {
            switch self {
            case .terminal: return "terminal"
            case .iterm: return "itermcolors"
            case .monad: return "json"
            }
        }
    }

    struct FontChoice: Hashable, Identifiable {
        let postScriptName: String
        let displayName: String
        var id: String { postScriptName }
    }

    /// Only the user's themes can be edited; built-ins are duplicated first.
    static func canEdit(_ id: String, in catalog: ThemeCatalog) -> Bool {
        !catalog.isBuiltIn(id) && catalog.theme(id) != nil
    }

    /// An editable copy named "<name> Copy" (or "… Copy 2", …).
    static func duplicate(_ theme: Theme, in catalog: ThemeCatalog) -> Theme {
        let names = Set(catalog.themes.map(\.name))
        let base = "\(theme.name) Copy"
        var name = base, n = 2
        while names.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        var copy = theme
        copy.name = String(name.prefix(64))
        copy.id = catalog.newID(for: copy.name)
        return copy
    }

    static func export(_ theme: Theme, as format: ExportFormat) throws -> Data {
        switch format {
        case .terminal: return try ThemeExport.terminalProfile(theme)
        case .iterm: return try ThemeExport.itermColors(theme)
        case .monad: return try theme.encoded()
        }
    }

    /// Installed fixed-pitch fonts, by display name.
    static func monospacedFonts() -> [FontChoice] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        return names.filter { !$0.hasPrefix(".") }.compactMap { name in
            NSFont(name: name, size: 12).map { FontChoice(postScriptName: name, displayName: $0.displayName ?? name) }
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// What the preview terminal shows: a prompt, bold, a selection-like
    /// inverse run, and every ANSI color.
    static let previewSample: String = {
        var s = "\u{1B}[1muser@monad\u{1B}[0m:\u{1B}[34m~/project\u{1B}[0m$ ls --color\r\n"
        s += "\u{1B}[1mbold\u{1B}[0m  normal  \u{1B}[2mdim\u{1B}[0m  \u{1B}[3mitalic\u{1B}[0m  \u{1B}[7m selected \u{1B}[0m\r\n"
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        for (i, n) in names.enumerated() {
            s += "\u{1B}[3\(i)m\(n.padding(toLength: 8, withPad: " ", startingAt: 0))\u{1B}[0m "
            s += "\u{1B}[9\(i)m\(("bright " + n).padding(toLength: 15, withPad: " ", startingAt: 0))\u{1B}[0m"
            s += i % 2 == 1 ? "\r\n" : "  "
        }
        return s + "\u{1B}[1muser@monad\u{1B}[0m:\u{1B}[34m~/project\u{1B}[0m$ "
    }()
}

extension RGB {
    /// From a color well (any color space; converted to sRGB).
    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? .black
        func b(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(b(c.redComponent), b(c.greenComponent), b(c.blueComponent))
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}
