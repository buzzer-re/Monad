//
//  ThemeEditorTests.swift — the logic behind the theme editor: duplicating,
//  exporting, color conversion, the font list and the preview text.
//

import AppKit
import XCTest
@testable import Monad

@MainActor
final class ThemeEditorTests: XCTestCase {
    private var tmp: TempDir!
    private var store: ThemeStore!

    override func setUp() {
        tmp = TempDir()
        store = ThemeStore(catalog: .load(builtIn: Bundle.main.resourceURL, user: tmp.url))
    }

    func testDuplicatingMakesAnEditableCopy() throws {
        let pro = try XCTUnwrap(store.catalog.theme("pro"))
        let copy = ThemeEditing.duplicate(pro, in: store.catalog)
        XCTAssertEqual(copy.name, "Pro Copy")
        XCTAssertEqual(copy.id, "pro-copy")
        XCTAssertEqual(copy.ansi, pro.ansi)
        try store.save(copy)
        XCTAssertFalse(store.catalog.isBuiltIn(copy.id))
        let again = ThemeEditing.duplicate(pro, in: store.catalog)
        XCTAssertEqual(again.id, "pro-copy-2", "never overwrites an existing theme")
        XCTAssertEqual(again.name, "Pro Copy 2")
    }

    func testOnlyUserThemesAreEditable() throws {
        XCTAssertFalse(ThemeEditing.canEdit("pro", in: store.catalog))
        let copy = ThemeEditing.duplicate(try XCTUnwrap(store.catalog.theme("pro")), in: store.catalog)
        try store.save(copy)
        XCTAssertTrue(ThemeEditing.canEdit(copy.id, in: store.catalog))
    }

    func testExportFormats() throws {
        let theme = try XCTUnwrap(store.catalog.theme("homebrew"))
        for format in ThemeEditing.ExportFormat.allCases {
            let data = try ThemeEditing.export(theme, as: format)
            let url = tmp.url.appendingPathComponent("x.\(format.fileExtension)")
            try data.write(to: url)
            if format == .monad {
                XCTAssertEqual(try Theme.decode(data), theme)
            } else {
                let back = try ThemeImport.file(url, catalog: store.catalog)
                XCTAssertEqual(back.ansi, theme.ansi, format.fileExtension)
                XCTAssertEqual(back.background, theme.background)
            }
        }
    }

    func testColorsSurviveTheColorPicker() {
        for v in stride(from: 0, through: 255, by: 5) {
            let rgb = RGB(UInt8(v), UInt8(255 - v), UInt8(v / 2))
            XCTAssertEqual(RGB(nsColor: rgb.nsColor), rgb)
        }
        let p3 = NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(RGB(nsColor: p3).r, 255, "colors from other spaces are converted to sRGB")
    }

    func testFontListHasOnlyMonospacedFonts() {
        let fonts = ThemeEditing.monospacedFonts()
        XCTAssertTrue(fonts.contains { $0.postScriptName == "Menlo-Regular" })
        XCTAssertFalse(fonts.contains { $0.postScriptName == "Helvetica" })
        XCTAssertEqual(fonts.map(\.displayName), fonts.map(\.displayName).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
    }

    func testPreviewShowsEveryColor() {
        let sample = ThemeEditing.previewSample
        for i in 0..<8 {
            XCTAssertTrue(sample.contains("\u{1B}[3\(i)m"), "normal \(i)")
            XCTAssertTrue(sample.contains("\u{1B}[9\(i)m"), "bright \(i)")
        }
        XCTAssertTrue(sample.contains("\u{1B}[1m"), "bold")
        XCTAssertTrue(sample.contains("\u{1B}[7m"), "selection-like inverse")
    }
}
