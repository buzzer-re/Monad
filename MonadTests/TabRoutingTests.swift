//
//  TabRoutingTests.swift — tabs and the VMs they open on (Phase 10): what
//  ⌘T, the "+" and the "…" menu open from the tab in front, how the menu
//  names it, and which window a new tab joins (the one it was asked from,
//  any VM's, never a new window while one is open).
//

import XCTest
@testable import Monad

final class TabRoutingTests: XCTestCase {
    private typealias Tab = TabRouting.Tab

    /// Every terminal window can take any tab: one group for all.
    func testEveryTerminalWindowSharesOneGroup() {
        XCTAssertEqual(TabRouting.group, "dev.monad.terminal")
    }

    /// ⌘T opens another tab on the VM of the tab in front.
    func testANewTabOpensOnTheFocusedTabsVM() {
        func newTab(_ focused: Tab?, fallback: SessionTarget = .defaultVM) -> SessionTarget? {
            TabRouting.newTab(focused: focused, fallback: fallback)
        }
        XCTAssertEqual(newTab(Tab(target: .vm("web"), vm: "web")), .vm("web"))
        XCTAssertEqual(newTab(Tab(target: .defaultVM, vm: "default")), .vm("default"),
                       "the same VM, even once another one is the default")
        XCTAssertEqual(newTab(Tab(target: .defaultVM, vm: nil)), .defaultVM, "not resolved yet")
        XCTAssertEqual(newTab(Tab(target: .host, vm: nil)), .host)
        XCTAssertEqual(newTab(Tab(target: .ephemeralVM, vm: "tmp-1a2b3c")), .vm("tmp-1a2b3c"),
                       "the same ephemeral VM, not a new one")
        XCTAssertNil(newTab(Tab(target: .ephemeralVM, vm: nil)), "not made yet")
        XCTAssertEqual(newTab(nil), .defaultVM, "no tab in front")
        XCTAssertEqual(newTab(nil, fallback: .host), .host)
    }

    /// A new tab, on any VM, joins the window it was asked from (its "…" or
    /// "+"), else the frontmost terminal window; a window of its own only
    /// when none is open.
    func testANewTabJoinsTheWindowItWasAskedFrom() {
        XCTAssertEqual(TabRouting.window(asked: 7, frontToBack: [3, 7]), 7)
        XCTAssertEqual(TabRouting.window(asked: nil, frontToBack: [3, 7]), 3, "the frontmost")
        XCTAssertEqual(TabRouting.window(asked: 9, frontToBack: [3, 7]), 3, "the window asked from is gone")
        XCTAssertNil(TabRouting.window(asked: nil, frontToBack: []), "none open: a new window")
    }

    /// The titlebar's "…" shows only in a window with no tab bar, and never
    /// in full screen: changing the titlebar there brings it down over the
    /// tab bar and the terminal, where it stayed until the mouse came by.
    func testTheTitlebarMenuShowsOnlyWithoutATabBarOutOfFullScreen() {
        XCTAssertFalse(TabRouting.hidesTitlebarMenu(tabBarVisible: false, fullScreen: false))
        XCTAssertTrue(TabRouting.hidesTitlebarMenu(tabBarVisible: true, fullScreen: false), "each tab has its own")
        XCTAssertTrue(TabRouting.hidesTitlebarMenu(tabBarVisible: false, fullScreen: true))
        XCTAssertTrue(TabRouting.hidesTitlebarMenu(tabBarVisible: true, fullScreen: true))
    }

    /// VM › "<vm> Settings…" opens the settings of the VM in front, without
    /// the Virtual Machines window; none for a host shell.
    func testTheVMMenuOpensTheSettingsOfTheVMInFront() {
        XCTAssertEqual(TabRouting.settingsVM(focused: Tab(target: .vm("web"), vm: "web")), "web")
        XCTAssertEqual(TabRouting.settingsVM(focused: Tab(target: .defaultVM, vm: "default")), "default")
        XCTAssertNil(TabRouting.settingsVM(focused: Tab(target: .ephemeralVM, vm: nil)), "not made yet")
        XCTAssertNil(TabRouting.settingsVM(focused: Tab(target: .host, vm: nil)))
        XCTAssertNil(TabRouting.settingsVM(focused: nil))
        XCTAssertEqual(TabRouting.settingsTitle(focused: Tab(target: .vm("web"), vm: "web")), "“web” Settings…")
        XCTAssertEqual(TabRouting.settingsTitle(focused: nil), "VM Settings…")
    }

    /// The menu names the VM a new tab opens on: with no tab in front, the
    /// default VM (the top of the Virtual Machines list).
    func testTheMenuSaysWhereANewTabOpens() {
        func title(_ focused: Tab?, defaultVM: String? = nil) -> String {
            TabRouting.newTabTitle(focused: focused, fallback: .defaultVM, defaultVM: defaultVM)
        }
        XCTAssertEqual(title(Tab(target: .vm("web"), vm: "web")), "New Tab in web")
        XCTAssertEqual(title(Tab(target: .defaultVM, vm: nil)), "New Tab in default")
        XCTAssertEqual(title(Tab(target: .ephemeralVM, vm: "tmp-1a2b3c")), "New Tab in tmp-1a2b3c")
        XCTAssertEqual(title(Tab(target: .ephemeralVM, vm: nil)), "New Tab")
        XCTAssertEqual(title(Tab(target: .host, vm: nil)), "New Host Shell Tab")
        XCTAssertEqual(title(nil), "New Tab in default")
        XCTAssertEqual(title(nil, defaultVM: "web"), "New Tab in web")
    }
}
