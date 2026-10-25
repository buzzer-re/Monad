//
//  UITests.swift — AppKit-level behaviour: tab selection shortcuts, theme
//  resolution, pasteboard image extraction, box drawing coverage.
//

import AppKit
import XCTest
@testable import Monad

@MainActor
final class TabSelectionTests: XCTestCase {
    func testShortcutMapping() {
        XCTAssertNil(AppDelegate.tabIndex(forShortcut: 1, tabCount: 0))
        XCTAssertEqual(AppDelegate.tabIndex(forShortcut: 1, tabCount: 1), 0)
        XCTAssertEqual(AppDelegate.tabIndex(forShortcut: 3, tabCount: 5), 2)
        XCTAssertNil(AppDelegate.tabIndex(forShortcut: 6, tabCount: 5), "no such tab")
        XCTAssertEqual(AppDelegate.tabIndex(forShortcut: 8, tabCount: 8), 7)
        XCTAssertEqual(AppDelegate.tabIndex(forShortcut: 9, tabCount: 3), 2, "⌘9 is always the last tab")
        XCTAssertEqual(AppDelegate.tabIndex(forShortcut: 9, tabCount: 12), 11)
        XCTAssertNil(AppDelegate.tabIndex(forShortcut: 0, tabCount: 3))
        XCTAssertNil(AppDelegate.tabIndex(forShortcut: 10, tabCount: 12))
    }

    func testMenuHasCommandDigitItems() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        var found: [Int: NSMenuItem] = [:]
        func walk(_ m: NSMenu) {
            for item in m.items {
                if item.action == #selector(AppDelegate.selectTabByNumber(_:)) { found[item.tag] = item }
                if let sub = item.submenu { walk(sub) }
            }
        }
        walk(menu)
        XCTAssertEqual(Set(found.keys), Set(1...9))
        for (n, item) in found {
            XCTAssertEqual(item.keyEquivalent, "\(n)")
            XCTAssertEqual(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), .command)
        }
    }

    /// ⌘ and an arrow move between panes (not ⌥⌘).
    func testPanesAreSelectedWithCommandAndAnArrow() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let expected: [Selector: Int] = [
            #selector(TerminalWindowController.selectPaneLeft(_:)): NSLeftArrowFunctionKey,
            #selector(TerminalWindowController.selectPaneRight(_:)): NSRightArrowFunctionKey,
            #selector(TerminalWindowController.selectPaneAbove(_:)): NSUpArrowFunctionKey,
            #selector(TerminalWindowController.selectPaneBelow(_:)): NSDownArrowFunctionKey,
        ]
        var found: [Selector: NSMenuItem] = [:]
        func walk(_ m: NSMenu) {
            for item in m.items {
                if let action = item.action, expected[action] != nil { found[action] = item }
                if let sub = item.submenu { walk(sub) }
            }
        }
        walk(menu)
        XCTAssertEqual(Set(found.keys), Set(expected.keys))
        for (action, item) in found {
            XCTAssertEqual(item.keyEquivalent.unicodeScalars.first.map { Int($0.value) }, expected[action])
            XCTAssertEqual(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), .command, "\(action)")
        }
    }

    /// ⇧⌘ and an arrow show the focused pane's previous or next context.
    func testContextsCycleWithShiftCommandAndAnArrow() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let expected: [Selector: Int] = [
            #selector(TerminalWindowController.showPreviousContext(_:)): NSLeftArrowFunctionKey,
            #selector(TerminalWindowController.showNextContext(_:)): NSRightArrowFunctionKey,
        ]
        var found: [Selector: NSMenuItem] = [:]
        func walk(_ m: NSMenu) {
            for item in m.items {
                if let action = item.action, expected[action] != nil { found[action] = item }
                if let sub = item.submenu { walk(sub) }
            }
        }
        walk(menu)
        XCTAssertEqual(Set(found.keys), Set(expected.keys))
        for (action, item) in found {
            XCTAssertEqual(item.keyEquivalent.unicodeScalars.first.map { Int($0.value) }, expected[action])
            XCTAssertEqual(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.command, .shift], "\(action)")
        }
    }

    /// The tab bar shows its "+" only when the window's responder chain
    /// answers newWindowForTab.
    func testTheTabBarHasItsPlus() {
        XCTAssertFalse(NSWindowController.instancesRespond(to: #selector(NSResponder.newWindowForTab(_:))))
        XCTAssertTrue(TerminalWindowController.instancesRespond(to: #selector(NSResponder.newWindowForTab(_:))))
    }

    /// The "…" is only its icon (a pull-down drew its first item's title,
    /// cut to "N"), and its menu, filled as it opens, starts with the new tab.
    func testTheTabMenuButtonIsOnlyItsIcon() throws {
        let button = TabMenuButton(owner: nil)
        XCTAssertEqual(button.title, "")
        XCTAssertEqual(button.imagePosition, .imageOnly)
        XCTAssertNotNil(button.image)
        XCTAssertEqual(button.tabMenu.identifier, TerminalWindowController.tabMenuID)
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        delegate.menuNeedsUpdate(button.tabMenu)
        XCTAssertTrue(button.tabMenu.items.first?.title.hasPrefix("New") == true, "\(button.tabMenu.items.map(\.title))")
        let count = button.tabMenu.items.count
        delegate.menuNeedsUpdate(button.tabMenu)
        XCTAssertEqual(button.tabMenu.items.count, count, "filled again, not added to")
    }

    func testSelectsTabsInRealTabGroup() throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let windows = (0..<4).map { i -> NSWindow in
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.tabbingMode = .preferred
            w.tabbingIdentifier = "monad.test.tabs"
            w.title = "tab \(i + 1)"
            return w
        }
        defer { windows.forEach { $0.close() } }
        windows[0].makeKeyAndOrderFront(nil)
        for w in windows.dropFirst() { windows[0].addTabbedWindow(w, ordered: .above) }
        let tabs = try XCTUnwrap(windows[0].tabbedWindows)
        XCTAssertEqual(tabs.count, 4)

        XCTAssertTrue(delegate.selectTab(number: 2, in: tabs[0]))
        XCTAssertTrue(windows[0].tabGroup?.selectedWindow === tabs[1])
        XCTAssertTrue(delegate.selectTab(number: 9, in: tabs[1]))
        XCTAssertTrue(windows[0].tabGroup?.selectedWindow === tabs[3])
        XCTAssertTrue(delegate.selectTab(number: 1, in: tabs[3]))
        XCTAssertTrue(windows[0].tabGroup?.selectedWindow === tabs[0])
        XCTAssertFalse(delegate.selectTab(number: 5, in: tabs[0]))
        XCTAssertTrue(windows[0].tabGroup?.selectedWindow === tabs[0], "selection unchanged for a missing tab")
    }

    func testSingleWindowWithoutTabs() {
        let delegate = NSApp.delegate as? AppDelegate
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        defer { w.close() }
        XCTAssertEqual(delegate?.selectTab(number: 1, in: w), true)
        XCTAssertEqual(delegate?.selectTab(number: 2, in: w), false)
        XCTAssertEqual(delegate?.selectTab(number: 1, in: nil), false)
    }
}

final class TerminalThemeTests: XCTestCase {
    let theme = TerminalTheme.dark

    func testPaletteHas256Entries() {
        XCTAssertEqual(TerminalTheme.dark.palette.count, 256)
        XCTAssertEqual(TerminalTheme.light.palette.count, 256)
        XCTAssertEqual(theme.palette[16], RGB(0, 0, 0))
        XCTAssertEqual(theme.palette[231], RGB(255, 255, 255))
        XCTAssertEqual(theme.palette[232], RGB(8, 8, 8))
    }

    func testDefaultAndIndexedColors() {
        let r = theme.resolve(fg: 0, bg: 0, attrs: 0, reverseVideo: false)
        XCTAssertEqual(r.fg, theme.foreground)
        XCTAssertEqual(r.bg, theme.background)
        XCTAssertTrue(r.bgIsDefault)
        let i = theme.resolve(fg: VTColor.tagIndex | 1, bg: VTColor.tagIndex | 4, attrs: 0, reverseVideo: false)
        XCTAssertEqual(i.fg, theme.palette[1])
        XCTAssertEqual(i.bg, theme.palette[4])
        XCTAssertFalse(i.bgIsDefault)
    }

    func testTruecolor() {
        let r = theme.resolve(fg: VTColor.tagRGB | 0x123456, bg: 0, attrs: 0, reverseVideo: false)
        XCTAssertEqual(r.fg, RGB(0x12, 0x34, 0x56))
    }

    func testBoldBrightensBaseColors() {
        let r = theme.resolve(fg: VTColor.tagIndex | 2, bg: 0, attrs: VTAttr.bold, reverseVideo: false)
        XCTAssertEqual(r.fg, theme.palette[10])
        let high = theme.resolve(fg: VTColor.tagIndex | 100, bg: 0, attrs: VTAttr.bold, reverseVideo: false)
        XCTAssertEqual(high.fg, theme.palette[100], "only the first 8 colors brighten")
    }

    func testInverseHiddenAndReverseVideo() {
        let inv = theme.resolve(fg: 0, bg: 0, attrs: VTAttr.inverse, reverseVideo: false)
        XCTAssertEqual(inv.fg, theme.background)
        XCTAssertEqual(inv.bg, theme.foreground)
        XCTAssertFalse(inv.bgIsDefault)
        let hidden = theme.resolve(fg: VTColor.tagIndex | 1, bg: 0, attrs: VTAttr.hidden, reverseVideo: false)
        XCTAssertEqual(hidden.fg, hidden.bg)
        let rev = theme.resolve(fg: 0, bg: 0, attrs: 0, reverseVideo: true)
        XCTAssertEqual(rev.fg, theme.background)
        XCTAssertEqual(rev.bg, theme.foreground)
    }
}

@MainActor
final class PasteboardImageTests: XCTestCase {
    private var pb: NSPasteboard!

    override func setUp() async throws {
        pb = NSPasteboard(name: NSPasteboard.Name("dev.monad.tests.\(UUID().uuidString)"))
        pb.clearContents()
    }

    override func tearDown() async throws {
        pb.releaseGlobally()
    }

    private func pngData() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testPNGOnPasteboardIsUsedAsIs() throws {
        let png = try pngData()
        pb.setData(png, forType: .png)
        let images = MonadTerminalView.images(from: pb)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.png, png)
        XCTAssertTrue(images.first?.suggestedName.hasPrefix("shot-") == true)
        XCTAssertTrue(images.first?.suggestedName.hasSuffix(".png") == true)
    }

    func testTIFFIsConvertedToPNG() throws {
        let tiff = try XCTUnwrap(NSBitmapImageRep(data: try pngData())?.tiffRepresentation)
        pb.setData(tiff, forType: .tiff)
        let images = MonadTerminalView.images(from: pb)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testImageFileURLsAreRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("monad-pb-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("Screenshot 1.png")
        try pngData().write(to: png)
        let txt = dir.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: txt)
        pb.writeObjects([png as NSURL, txt as NSURL])
        let images = MonadTerminalView.images(from: pb)
        XCTAssertEqual(images.count, 1, "non-image files are ignored")
        XCTAssertEqual(images.first?.suggestedName, "Screenshot 1.png")
    }

    func testPlainTextHasNoImages() {
        pb.setString("just text", forType: .string)
        XCTAssertTrue(MonadTerminalView.images(from: pb).isEmpty)
    }
}

final class BoxDrawingTests: XCTestCase {
    func testCoverage() {
        for cp: UInt32 in [0x2500, 0x2502, 0x250C, 0x2510, 0x2514, 0x2518, 0x251C, 0x2524, 0x252C, 0x2534, 0x253C,
                           0x2501, 0x254B, 0x256D, 0x2570, 0x2580, 0x2584, 0x2588, 0x258C, 0x2590, 0x2591, 0x2593] {
            XCTAssertTrue(BoxDrawing.handles(cp), String(format: "U+%04X", cp))
        }
        for cp: UInt32 in [0x41, 0x2550, 0x2594, 0x1F600] {
            XCTAssertFalse(BoxDrawing.handles(cp), String(format: "U+%04X", cp))
        }
    }

    func testDrawingFillsCellEdgesForHorizontalLine() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 10, height: 20, bitsPerComponent: 8, bytesPerRow: 40,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        BoxDrawing.draw(0x2500, in: CGRect(x: 0, y: 0, width: 10, height: 20), scale: 1, context: ctx)
        let data = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        // Row 10 (center) must be painted from the first to the last pixel so
        // adjacent cells join without gaps.
        let row = 10 * 40
        XCTAssertGreaterThan(data[row + 3], 0, "left edge painted")
        XCTAssertGreaterThan(data[row + 9 * 4 + 3], 0, "right edge painted")
    }
}

final class CursorBlinkTests: XCTestCase {
    func testTheSettingMakesTheCursorBlink() {
        // The "off" half of a blink hides the cursor when the user asked for
        // blinking, even if the program in the terminal did not.
        XCTAssertFalse(MonadTerminalView.cursorShown(blinkPhaseOn: false, programBlinks: false, settingBlinks: true,
                                                     focused: true))
        XCTAssertTrue(MonadTerminalView.cursorShown(blinkPhaseOn: true, programBlinks: false, settingBlinks: true,
                                                    focused: true))
    }

    func testProgramRequestedBlinkStillWorks() {
        XCTAssertFalse(MonadTerminalView.cursorShown(blinkPhaseOn: false, programBlinks: true, settingBlinks: false,
                                                     focused: true))
    }

    func testSteadyCursorAndUnfocusedTabsNeverHide() {
        XCTAssertTrue(MonadTerminalView.cursorShown(blinkPhaseOn: false, programBlinks: false, settingBlinks: false,
                                                    focused: true))
        XCTAssertTrue(MonadTerminalView.cursorShown(blinkPhaseOn: false, programBlinks: true, settingBlinks: true,
                                                    focused: false))
    }
}
