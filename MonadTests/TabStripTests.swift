//
//  TabStripTests.swift — a terminal window's tabs and their groups, as
//  Firefox has them: a group is a named, coloured run of tabs that stay
//  together, shown after its label; a collapsed group shows only its label
//  (and the tab in front, when it is one of its own); tabs and groups move
//  by drag and drop.
//

import XCTest
@testable import Monad

final class TabStripTests: XCTestCase {
    private let a = TabID("a"), b = TabID("b"), c = TabID("c"), d = TabID("d"), e = TabID("e")
    private let work = TabGroupID("work"), play = TabGroupID("play")

    private func strip(_ tabs: TabID...) -> TabStrip {
        var s = TabStrip(tab: tabs[0])
        for t in tabs.dropFirst() { s.add(t) }
        return s
    }

    private func order(_ s: TabStrip) -> [TabID] { s.tabs.map(\.id) }

    func testANewTabGoesLastAndInFront() {
        var s = TabStrip(tab: a)
        XCTAssertEqual(s.selected, a)
        s.add(b)
        s.add(c)
        XCTAssertEqual(order(s), [a, b, c])
        XCTAssertEqual(s.selected, c)
        XCTAssertEqual(s.items, [.tab(a), .tab(b), .tab(c)])
        s.add(a)
        XCTAssertEqual(order(s), [a, b, c], "a tab is in the strip once")
    }

    func testAGroupGathersItsTabsAfterItsLabel() {
        var s = strip(a, b, c, d)
        s.newGroup(work, name: "work", tabs: [d, b])
        XCTAssertEqual(order(s), [a, b, d, c], "where its first tab was, in the strip's order")
        XCTAssertEqual(s.items, [.tab(a), .group(work), .tab(b), .tab(d), .tab(c)])
        XCTAssertEqual(s.group(of: b)?.name, "work")
        XCTAssertNil(s.group(of: a))
        XCTAssertEqual(s.tabs(in: work), [b, d])
    }

    func testGroupsTakeColoursInTurn() {
        var s = strip(a, b, c)
        XCTAssertEqual(s.nextColor, TabGroupColor.allCases[0])
        s.newGroup(work, name: "work", tabs: [a])
        s.newGroup(play, name: "play", tabs: [b])
        XCTAssertEqual(s.group(work)?.color, TabGroupColor.allCases[0])
        XCTAssertEqual(s.group(play)?.color, TabGroupColor.allCases[1])
        s.setColor(.red, of: work)
        XCTAssertEqual(s.group(work)?.color, .red)
    }

    func testANameIsTrimmedAndBounded() {
        var s = strip(a)
        s.newGroup(work, name: "  work\n", tabs: [a])
        XCTAssertEqual(s.group(work)?.name, "work")
        s.rename(work, to: String(repeating: "x", count: 500))
        XCTAssertEqual(s.group(work)?.name.count, TabGroup.maxNameLength)
        s.rename(work, to: "a\u{1B}[31mb\u{07}")
        XCTAssertEqual(s.group(work)?.name, "a[31mb", "no control characters")
    }

    func testATabJoinsAGroupAtItsEndAndLeavesAfterIt() {
        var s = strip(a, b, c, d)
        s.newGroup(work, name: "work", tabs: [a, b])
        s.move(d, to: work)
        XCTAssertEqual(order(s), [a, b, d, c])
        XCTAssertEqual(s.tabs(in: work), [a, b, d])
        s.move(a, to: nil)
        XCTAssertEqual(order(s), [b, d, a, c], "out of the group, right after it")
        XCTAssertNil(s.group(of: a))
    }

    func testANewTabInAGroupGoesAtItsEnd() {
        var s = strip(a, b, c)
        s.newGroup(work, name: "work", tabs: [a, b])
        s.add(d, to: work)
        XCTAssertEqual(order(s), [a, b, d, c])
        XCTAssertEqual(s.group(of: d)?.id, work)
        XCTAssertEqual(s.selected, d)
    }

    func testAGroupLeftWithoutTabsIsGone() {
        var s = strip(a, b)
        s.newGroup(work, name: "work", tabs: [b])
        s.move(b, to: nil)
        XCTAssertNil(s.group(work))
        XCTAssertEqual(s.items, [.tab(a), .tab(b)])
        s.newGroup(work, name: "work", tabs: [b])
        XCTAssertTrue(s.close(b))
        XCTAssertNil(s.group(work))
    }

    func testUngroupingKeepsTheTabsWhereTheyAre() {
        var s = strip(a, b, c)
        s.newGroup(work, name: "work", tabs: [b, c])
        s.ungroup(work)
        XCTAssertEqual(order(s), [a, b, c])
        XCTAssertEqual(s.items, [.tab(a), .tab(b), .tab(c)])
    }

    func testACollapsedGroupShowsOnlyItsLabel() {
        var s = strip(a, b, c, d)
        s.newGroup(work, name: "work", tabs: [b, c])
        s.select(a)
        s.toggleCollapsed(work)
        XCTAssertEqual(s.items, [.tab(a), .group(work), .tab(d)])
        XCTAssertEqual(s.visibleTabs, [a, d])
        XCTAssertEqual(s.hiddenCount(in: work), 2)
        s.toggleCollapsed(work)
        XCTAssertEqual(s.items, [.tab(a), .group(work), .tab(b), .tab(c), .tab(d)])
    }

    /// As Firefox does: the tab in front stays in sight when its group
    /// collapses, so the window never shows a tab the strip does not.
    func testTheTabInFrontStaysInSightWhenItsGroupCollapses() {
        var s = strip(a, b, c)
        s.newGroup(work, name: "work", tabs: [b, c])
        s.select(c)
        s.toggleCollapsed(work)
        XCTAssertEqual(s.selected, c)
        XCTAssertEqual(s.items, [.tab(a), .group(work), .tab(c)])
        XCTAssertEqual(s.hiddenCount(in: work), 1)
        s.select(a)
        XCTAssertEqual(s.items, [.tab(a), .group(work)])
    }

    func testClosingTheTabInFrontShowsTheNextOneInSight() {
        var s = strip(a, b, c, d)
        s.newGroup(work, name: "work", tabs: [c])
        s.toggleCollapsed(work)
        s.select(b)
        XCTAssertTrue(s.close(b))
        XCTAssertEqual(s.selected, d, "not the one hidden in a collapsed group")
        XCTAssertTrue(s.close(d))
        XCTAssertEqual(s.selected, a, "none after it: the one before")
        XCTAssertTrue(s.close(a))
        XCTAssertEqual(s.selected, c, "only hidden ones are left: it shows")
        XCTAssertFalse(s.close(c), "the last tab closes its window instead")
        XCTAssertEqual(order(s), [c])
    }

    func testClosingATabNotInFrontKeepsTheOneInFront() {
        var s = strip(a, b, c)
        s.select(b)
        XCTAssertTrue(s.close(a))
        XCTAssertEqual(s.selected, b)
        XCTAssertFalse(s.close(TabID("nope")))
    }

    func testNextAndPreviousGoRoundTheTabsInSight() {
        var s = strip(a, b, c, d)
        s.newGroup(work, name: "work", tabs: [b, c])
        s.toggleCollapsed(work)
        s.select(a)
        s.selectVisible(by: 1)
        XCTAssertEqual(s.selected, d)
        s.selectVisible(by: 1)
        XCTAssertEqual(s.selected, a)
        s.selectVisible(by: -1)
        XCTAssertEqual(s.selected, d)
    }

    // MARK: Drag and drop

    func testATabDroppedOnATabGoesBesideItInItsGroup() {
        var s = strip(a, b, c, d)
        s.newGroup(work, name: "work", tabs: [b, c])
        s.drop(.tab(d), .before(.tab(c)))
        XCTAssertEqual(order(s), [a, b, d, c])
        XCTAssertEqual(s.group(of: d)?.id, work)
        s.drop(.tab(d), .after(.tab(a)))
        XCTAssertEqual(order(s), [a, d, b, c])
        XCTAssertNil(s.group(of: d), "beside a tab in no group: in none")
        s.drop(.tab(a), .end)
        XCTAssertEqual(order(s), [d, b, c, a])
        s.drop(.tab(a), .after(.tab(a)))
        XCTAssertEqual(order(s), [d, b, c, a], "onto itself: nothing")
    }

    func testATabDroppedOnALabelGoesBeforeTheGroupOrIntoIt() {
        var s = strip(a, b, c, d)
        s.newGroup(work, name: "work", tabs: [b, c])
        s.drop(.tab(d), .before(.group(work)))
        XCTAssertEqual(order(s), [a, d, b, c])
        XCTAssertNil(s.group(of: d))
        s.drop(.tab(a), .after(.group(work)))
        XCTAssertEqual(order(s), [d, a, b, c])
        XCTAssertEqual(s.group(of: a)?.id, work)
    }

    func testAGroupMovesWhole() {
        var s = strip(a, b, c, d, e)
        s.newGroup(work, name: "work", tabs: [a, b])
        s.newGroup(play, name: "play", tabs: [d, e])
        s.drop(.group(work), .after(.tab(c)))
        XCTAssertEqual(order(s), [c, a, b, d, e])
        s.drop(.group(work), .after(.tab(d)))
        XCTAssertEqual(order(s), [c, d, e, a, b], "never into another group: after it")
        XCTAssertEqual(s.tabs(in: play), [d, e])
        s.drop(.group(work), .before(.group(play)))
        XCTAssertEqual(order(s), [c, a, b, d, e])
        s.drop(.group(work), .end)
        XCTAssertEqual(order(s), [c, d, e, a, b])
        s.drop(.group(work), .before(.tab(b)))
        XCTAssertEqual(order(s), [c, d, e, a, b], "onto itself: nothing")
    }

    // MARK: A saved strip

    func testASavedStripComesBackAsItWas() throws {
        var s = strip(a, b, c)
        s.newGroup(work, name: "work", tabs: [b, c])
        s.toggleCollapsed(work)
        s.select(b)
        let back = try XCTUnwrap(TabStrip(tabs: s.tabs, groups: s.groups, selected: s.selected))
        XCTAssertEqual(back, s)
    }

    /// The file is the user's, but nothing is taken from it on trust.
    func testASavedStripThatMakesNoSenseIsPutRight() throws {
        XCTAssertNil(TabStrip(tabs: [], groups: [], selected: nil))
        let groups = [TabGroup(id: work, name: "work", color: .blue), TabGroup(id: work, name: "again", color: .red),
                      TabGroup(id: play, name: "empty", color: .green)]
        let s = try XCTUnwrap(TabStrip(tabs: [.init(id: a, group: work), .init(id: b, group: TabGroupID("gone")),
                                              .init(id: c, group: work), .init(id: a, group: nil)],
                                       groups: groups, selected: TabID("nope")))
        XCTAssertEqual(order(s), [a, c, b], "a group's tabs together, each tab once")
        XCTAssertEqual(s.groups.map(\.name), ["work"], "one group per id, none without tabs")
        XCTAssertNil(s.group(of: b))
        XCTAssertEqual(s.selected, a)
    }
}
