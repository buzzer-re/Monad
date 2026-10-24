//
//  Theme.swift — a terminal theme as data (*.theme.json): colors, background
//  opacity and blur, font family, cursor style and background image. The 16
//  ANSI colors are stored; the 256-color cube and grays are derived.
//

import AppKit

struct Theme: Equatable, Identifiable {
    static let currentSchema = 1

    enum CursorStyle: String, Codable, CaseIterable {
        case block, underline, bar
    }

    struct BackgroundImage: Codable, Equatable {
        enum Fill: String, Codable, CaseIterable {
            case fill, fit, stretch, center, tile
        }

        var path: String
        var fill: Fill = .fill
        /// How strongly the image shows over the background color.
        var opacity: Double = 1
    }

    struct Invalid: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    var schema = Theme.currentSchema
    /// Stable identifier, also the file name: lowercase letters, digits, dashes.
    var id: String
    var name: String
    var foreground: RGB
    var background: RGB
    /// Color of bold text in the default color (Terminal.app's "bold" color).
    var bold: RGB?
    var cursor: RGB
    var selection: RGB
    /// Black, red, green, yellow, blue, magenta, cyan, white, then bright ones.
    var ansi: [RGB]
    var backgroundOpacity: Double = 1
    var blur: Double = 0
    /// PostScript or family name; nil or not installed: the system monospaced font.
    var font: String?
    var cursorStyle: CursorStyle?
    var backgroundImage: BackgroundImage?

    init(schema: Int = Theme.currentSchema, id: String, name: String, foreground: RGB, background: RGB,
         bold: RGB? = nil, cursor: RGB, selection: RGB, ansi: [RGB], backgroundOpacity: Double = 1, blur: Double = 0,
         font: String? = nil, cursorStyle: CursorStyle? = nil, backgroundImage: BackgroundImage? = nil) {
        self.schema = schema
        self.id = id
        self.name = name
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.cursor = cursor
        self.selection = selection
        self.ansi = ansi
        self.backgroundOpacity = backgroundOpacity
        self.blur = blur
        self.font = font
        self.cursorStyle = cursorStyle
        self.backgroundImage = backgroundImage
    }

    static let idPattern = "^[a-z0-9][a-z0-9-]{0,63}$"

    func validate() throws {
        guard schema == Self.currentSchema else { throw Invalid("Theme schema \(schema) is not supported.") }
        guard id.range(of: Self.idPattern, options: .regularExpression) != nil else {
            throw Invalid("“\(id)” is not a valid theme id: use lowercase letters, digits and dashes.")
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 64 else {
            throw Invalid("A theme needs a name of at most 64 characters.")
        }
        guard ansi.count == 16 else { throw Invalid("A theme has exactly 16 ANSI colors, not \(ansi.count).") }
        guard (0...1).contains(backgroundOpacity) else { throw Invalid("Background opacity must be between 0 and 1.") }
        guard (0...1).contains(blur) else { throw Invalid("Blur must be between 0 and 1.") }
        if let image = backgroundImage {
            guard image.path.hasPrefix("/") else { throw Invalid("The background image needs an absolute path.") }
            guard (0...1).contains(image.opacity) else { throw Invalid("Image opacity must be between 0 and 1.") }
        }
    }

    // MARK: Monad's own

    /// Dark default (softer ANSI colors than Terminal.app's Pro).
    static let monadDark = Theme(from: .dark, id: "monad-dark", name: "Monad Dark")
    /// Light default (Terminal.app's Basic colors).
    static let monadLight = Theme(from: .light, id: "monad-light", name: "Monad Light")

    init(from t: TerminalTheme, id: String, name: String) {
        self.init(id: id, name: name, foreground: t.foreground, background: t.background, bold: t.bold,
                  cursor: t.cursor, selection: t.selection, ansi: Array(t.palette.prefix(16)))
    }

    // MARK: Use

    /// The colors a terminal draws with.
    var terminalTheme: TerminalTheme {
        TerminalTheme(foreground: foreground, background: background, cursor: cursor, selection: selection,
                      palette: TerminalTheme.standardPalette(ansi: ansi), bold: bold)
    }

    /// The theme's font at `size`, or the system monospaced font if it is
    /// not set or not installed.
    func resolvedFont(size: CGFloat) -> NSFont {
        if let font, let f = NSFont(name: font, size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: Files

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    static func decode(_ data: Data) throws -> Theme {
        let t = try JSONDecoder().decode(Theme.self, from: data)
        try t.validate()
        return t
    }
}

extension Theme: Codable {
    private enum Keys: String, CodingKey {
        case schema, id, name, foreground, background, bold, cursor, selection, ansi, backgroundOpacity, blur, font,
             cursorStyle, backgroundImage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(schema: try c.decode(Int.self, forKey: .schema),
                  id: try c.decode(String.self, forKey: .id),
                  name: try c.decode(String.self, forKey: .name),
                  foreground: try c.decode(RGB.self, forKey: .foreground),
                  background: try c.decode(RGB.self, forKey: .background),
                  bold: try c.decodeIfPresent(RGB.self, forKey: .bold),
                  cursor: try c.decode(RGB.self, forKey: .cursor),
                  selection: try c.decode(RGB.self, forKey: .selection),
                  ansi: try c.decode([RGB].self, forKey: .ansi),
                  backgroundOpacity: try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 1,
                  blur: try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0,
                  font: try c.decodeIfPresent(String.self, forKey: .font),
                  cursorStyle: try c.decodeIfPresent(CursorStyle.self, forKey: .cursorStyle),
                  backgroundImage: try c.decodeIfPresent(BackgroundImage.self, forKey: .backgroundImage))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(foreground, forKey: .foreground)
        try c.encode(background, forKey: .background)
        try c.encodeIfPresent(bold, forKey: .bold)
        try c.encode(cursor, forKey: .cursor)
        try c.encode(selection, forKey: .selection)
        try c.encode(ansi, forKey: .ansi)
        try c.encode(backgroundOpacity, forKey: .backgroundOpacity)
        try c.encode(blur, forKey: .blur)
        try c.encodeIfPresent(font, forKey: .font)
        try c.encodeIfPresent(cursorStyle, forKey: .cursorStyle)
        try c.encodeIfPresent(backgroundImage, forKey: .backgroundImage)
    }
}

/// Colors are "#RRGGBB" in theme files.
extension RGB: Codable {
    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard s.count == 7, s.hasPrefix("#"), let v = UInt32(s.dropFirst(), radix: 16) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "“\(s)” is not a #RRGGBB color"))
        }
        self.init(hex: v)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(String(format: "#%06X", hex))
    }
}
