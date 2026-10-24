//
//  SettingsWindowTests.swift — the Settings window is laid out like a VM's
//  window: a sidebar of areas with colored icons, the chosen one beside it,
//  with room for every area's controls.
//

import AppKit
import SwiftUI
import XCTest
@testable import Monad

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testSettingsHasASidebarForEachArea() throws {
        XCTAssertEqual(SettingsPane.allCases.map(\.title),
                       ["Terminal", "Privacy", "Virtual Machines", "Distributions", "Networks", "Firewall", "Profiles", "Agents",
                        "Logs"])
        for pane in SettingsPane.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil), pane.title)
        }
        XCTAssertEqual(Set(SettingsPane.allCases.map(\.symbol)).count, SettingsPane.allCases.count, "each its own icon")
        let window = AppDelegate.makeSettingsWindow()
        defer { window.close() }
        XCTAssertTrue(window.contentViewController is NSHostingController<SettingsView>, "a sidebar, not toolbar tabs")
        XCTAssertTrue(window.styleMask.contains(.resizable))
    }

    /// The widest areas (a list beside an editor) fit beside the sidebar,
    /// and the window never opens empty.
    func testEveryAreaHasRoomForItsControls() throws {
        XCTAssertGreaterThanOrEqual(SettingsView.minSize.width - SettingsView.sidebarWidth, 760)
        XCTAssertGreaterThanOrEqual(SettingsView.minSize.height, 520)
        let window = AppDelegate.makeSettingsWindow()
        defer { window.close() }
        window.layoutIfNeeded()
        let content = try XCTUnwrap(window.contentView).frame.size
        XCTAssertGreaterThanOrEqual(content.width, SettingsView.minSize.width)
        XCTAssertGreaterThanOrEqual(content.height, SettingsView.minSize.height, "never opens empty")
    }
}

final class LaunchModeTests: XCTestCase {
    func testToolsHostingTheAppDoNotStartVMs() {
        XCTAssertTrue(AppDelegate.isHeadless(["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
        XCTAssertTrue(AppDelegate.isHeadless(["XCODE_RUNNING_FOR_PREVIEWS": "1"]), "Xcode previews and code snippets")
        XCTAssertFalse(AppDelegate.isHeadless(["XCODE_RUNNING_FOR_PREVIEWS": "0"]))
        XCTAssertFalse(AppDelegate.isHeadless([:]))
    }
}
