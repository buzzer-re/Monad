//
//  ThemeIO.swift — importing and exporting themes as Terminal.app profiles
//  (.terminal: a property list of archived NSColor/NSFont values) and iTerm2
//  color presets (.itermcolors: a property list of color components).
//  Imported files are untrusted: size-capped, and only NSColor and NSFont
//  are unarchived, with secure coding.
//

import AppKit

enum ThemeImport {
    static let maxFileSize = 1 << 20

    /// Terminal.app's standard ANSI colors (used when a profile has none).
    static let terminalAppANSI: [RGB] = [
        0x000000, 0xC23621, 0x25BC24, 0xADAD27, 0x492EE1, 0xD338D3, 0x33BBC8, 0xCBCCCD,
        0x818383, 0xFC391F, 0x31E722, 0xEAEC23, 0x5833FF, 0xF935F8, 0x14F0F0, 0xE9EBEB,
    ].map { RGB(hex: $0) }
    static let defaultForeground = RGB(hex: 0x000000)
    static let defaultBackground = RGB(hex: 0xFFFFFF)
    static let defaultCursor = RGB(hex: 0x929292)
    static let defaultSelection = RGB(hex: 0xB4D5FE)

    static let ansiNames = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
    /// ANSIBlackColor … ANSIWhiteColor, then ANSIBrightBlackColor … ANSIBrightWhiteColor.
    static var terminalANSIKeys: [String] {
        ansiNames.map { "ANSI\($0)Color" } + ansiNames.map { "ANSIBright\($0)Color" }
    }

    // MARK: .terminal

    static func terminalProfile(_ data: Data, id: String) throws -> Theme {
        let plist = try dictionary(data)
        func color(_ key: String) throws -> NSColor? {
            guard let archived = plist[key] else { return nil }
            guard let bytes = archived as? Data,
                  let c = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: bytes) else {
                throw Theme.Invalid("\(key) is not a color.")
            }
            return c
        }
        func rgb(_ key: String, _ fallback: RGB) throws -> RGB { try color(key).map(srgb) ?? fallback }

        let background = try color("BackgroundColor")
        var ansi: [RGB] = []
        for (i, key) in terminalANSIKeys.enumerated() { ansi.append(try rgb(key, terminalAppANSI[i])) }
        var font: String?
        if let archived = plist["Font"] as? Data,
           let f = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: archived) {
            // Private system fonts (".AppleSystemUIFont…") stand for the
            // system font: ours is the monospaced one.
            font = f.fontName.hasPrefix(".") ? nil : f.fontName
        }
        let cursorStyle: Theme.CursorStyle? = (plist["CursorType"] as? Int).flatMap {
            switch $0 {
            case 0: return .block
            case 1: return .underline
            case 2: return .bar
            default: return nil
            }
        }
        let theme = Theme(
            id: id, name: (plist["name"] as? String).map(clean) ?? "Imported",
            foreground: try rgb("TextColor", defaultForeground),
            background: try background.map(srgb) ?? defaultBackground,
            bold: try color("TextBoldColor").map(srgb),
            cursor: try rgb("CursorColor", defaultCursor),
            selection: try rgb("SelectionColor", defaultSelection),
            ansi: ansi,
            backgroundOpacity: background.map { round3(alpha($0)) } ?? 1,
            blur: round3(min(max((plist["BackgroundBlur"] as? Double) ?? 0, 0), 1)),
            font: font, cursorStyle: cursorStyle)
        try theme.validate()
        return theme
    }

    // MARK: .itermcolors

    static func itermColors(_ data: Data, name: String, id: String) throws -> Theme {
        let plist = try dictionary(data)
        func color(_ key: String) throws -> (RGB, Double)? {
            guard let entry = plist[key] else { return nil }
            guard let d = entry as? [String: Any],
                  let r = d["Red Component"] as? Double, let g = d["Green Component"] as? Double,
                  let b = d["Blue Component"] as? Double else {
                throw Theme.Invalid("\(key) is not a color.")
            }
            let a = (d["Alpha Component"] as? Double) ?? 1
            let ns: NSColor
            switch d["Color Space"] as? String {
            case "sRGB": ns = NSColor(srgbRed: r, green: g, blue: b, alpha: a)
            case "P3": ns = NSColor(displayP3Red: r, green: g, blue: b, alpha: a)
            default: ns = NSColor(calibratedRed: r, green: g, blue: b, alpha: a) // older presets
            }
            return (try srgb(ns), a)
        }
        var ansi: [RGB] = []
        for i in 0..<16 {
            guard let c = try color("Ansi \(i) Color") else { throw Theme.Invalid("Ansi \(i) Color is missing.") }
            ansi.append(c.0)
        }
        let background = try color("Background Color")
        let theme = Theme(
            id: id, name: clean(name),
            foreground: try color("Foreground Color")?.0 ?? defaultForeground,
            background: background?.0 ?? defaultBackground,
            bold: try color("Bold Color")?.0,
            cursor: try color("Cursor Color")?.0 ?? defaultCursor,
            selection: try color("Selection Color")?.0 ?? defaultSelection,
            ansi: ansi,
            backgroundOpacity: round3(min(max(background?.1 ?? 1, 0), 1)))
        try theme.validate()
        return theme
    }

    // MARK: Files

    /// Import a .terminal or .itermcolors file under a free id.
    static func file(_ url: URL, catalog: ThemeCatalog) throws -> Theme {
        let data = try read(url)
        switch url.pathExtension.lowercased() {
        case "terminal":
            let t = try terminalProfile(data, id: "import")
            return with(t, id: catalog.newID(for: t.name))
        case "itermcolors":
            let name = url.deletingPathExtension().lastPathComponent
            return try itermColors(data, name: name, id: catalog.newID(for: name))
        default:
            throw Theme.Invalid("Monad imports Terminal profiles (.terminal) and iTerm2 color presets (.itermcolors).")
        }
    }

    private static func read(_ url: URL) throws -> Data {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxFileSize else { throw Theme.Invalid("\(url.lastPathComponent) is too large for a theme.") }
        return try Data(contentsOf: url)
    }

    private static func with(_ t: Theme, id: String) -> Theme {
        var t = t
        t.id = id
        return t
    }

    // MARK: Helpers

    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard data.count <= maxFileSize else { throw Theme.Invalid("The file is too large for a theme.") }
        guard let d = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Theme.Invalid("The file is not a theme.")
        }
        return d
    }

    static func srgb(_ c: NSColor) throws -> RGB {
        guard let s = c.usingColorSpace(.sRGB) else { throw Theme.Invalid("A color cannot be shown in sRGB.") }
        func b(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        return RGB(b(s.redComponent), b(s.greenComponent), b(s.blueComponent))
    }

    private static func alpha(_ c: NSColor) -> Double { Double(c.usingColorSpace(.sRGB)?.alphaComponent ?? 1) }

    private static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    /// Names shown in menus: printable, one line, at most 64 characters.
    private static func clean(_ name: String) -> String {
        let printable = name.unicodeScalars.filter { $0.properties.generalCategory != .control }
        let s = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Imported" : String(s.prefix(64))
    }
}

enum ThemeExport {
    static func terminalProfile(_ theme: Theme) throws -> Data {
        func archive(_ rgb: RGB, alpha: Double = 1) throws -> Data {
            let c = NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255,
                            alpha: alpha)
            return try NSKeyedArchiver.archivedData(withRootObject: c, requiringSecureCoding: true)
        }
        var plist: [String: Any] = [
            "name": theme.name,
            "type": "Window Settings",
            "ProfileCurrentVersion": 2.07,
            "TextColor": try archive(theme.foreground),
            "BackgroundColor": try archive(theme.background, alpha: theme.backgroundOpacity),
            "CursorColor": try archive(theme.cursor),
            "SelectionColor": try archive(theme.selection),
            "BackgroundBlur": theme.blur,
        ]
        if let bold = theme.bold { plist["TextBoldColor"] = try archive(bold) }
        for (i, key) in ThemeImport.terminalANSIKeys.enumerated() { plist[key] = try archive(theme.ansi[i]) }
        if let name = theme.font, let f = NSFont(name: name, size: 12) {
            plist["Font"] = try NSKeyedArchiver.archivedData(withRootObject: f, requiringSecureCoding: true)
        }
        if let style = theme.cursorStyle {
            plist["CursorType"] = [Theme.CursorStyle.block: 0, .underline: 1, .bar: 2][style]
        }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    static func itermColors(_ theme: Theme) throws -> Data {
        func entry(_ rgb: RGB, alpha: Double = 1) -> [String: Any] {
            ["Red Component": Double(rgb.r) / 255, "Green Component": Double(rgb.g) / 255,
             "Blue Component": Double(rgb.b) / 255, "Alpha Component": alpha, "Color Space": "sRGB"]
        }
        var plist: [String: Any] = [
            "Foreground Color": entry(theme.foreground),
            "Background Color": entry(theme.background, alpha: theme.backgroundOpacity),
            "Cursor Color": entry(theme.cursor),
            "Selection Color": entry(theme.selection),
        ]
        if let bold = theme.bold { plist["Bold Color"] = entry(bold) }
        for i in 0..<16 { plist["Ansi \(i) Color"] = entry(theme.ansi[i]) }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
