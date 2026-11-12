//
//  TabStripLayoutTests.swift — where the tab strip puts its labels, tabs
//  and buttons, what is under the pointer, and where a drag lets go.
//

import XCTest
@testable import Monad

final class TabStripLayoutTests: XCTestCase {
    private let a = TabID("a"), b = TabID("b"), c = TabID("c")
    private let work = TabGroupID("work")

    func testAFewTabsAreAsWideAsATabGetsAndTheButtonsFollow() throws {
        let l = TabStripLayout(items: [.tab(a), .tab(b)], chipWidths: [:], width: 1000)
        XCTAssertEqual(l.slots.map(\.item), [.tab(a), .tab(b)])
        XCTAssertEqual(l.slots.map(\.frame.width), [TabStripLayout.tabWidths.upperBound, TabStripLayout.tabWidths.upperBound])
        XCTAssertLessThan(l.slots[0].frame.maxX, l.slots[1].frame.minX)
        XCTAssertGreaterThan(l.plus.minX, l.slots[1].frame.maxX, "the + after the last tab")
        XCTAssertLessThan(l.plus.minX, l.slots[1].frame.maxX + 20)
        XCTAssertGreaterThan(l.menu.minX, 1000 - 50, "the … at the far end")
        XCTAssertLessThanOrEqual(l.menu.maxX, 1000)
    }

    func testManyTabsShareTheRoom() {
        let items = (0..<10).map { TabStrip.Item.tab(TabID("\($0)")) }
        let l = TabStripLayout(items: items, chipWidths: [:], width: 700)
        let widths = Set(l.slots.map { ($0.frame.width * 100).rounded() })
        XCTAssertEqual(widths.count, 1, "all the same")
        XCTAssertLessThan(l.slots[0].frame.width, TabStripLayout.tabWidths.upperBound)
        XCTAssertLessThanOrEqual(l.plus.maxX, l.menu.minX, "the + never under the …")
        XCTAssertLessThanOrEqual(l.slots[9].frame.maxX, l.plus.minX)
        let tight = TabStripLayout(items: items, chipWidths: [:], width: 100)
        XCTAssertEqual(tight.slots[0].frame.width, TabStripLayout.tabWidths.lowerBound, "never narrower than this")
    }

    func testALabelKeepsItsWidthWithinLimits() {
        let l = TabStripLayout(items: [.group(work), .tab(a)], chipWidths: [work: 61], width: 600)
        XCTAssertEqual(l.slots[0].frame.width, 61)
        let wide = TabStripLayout(items: [.group(work), .tab(a)], chipWidths: [work: 5000], width: 600)
        XCTAssertEqual(wide.slots[0].frame.width, TabStripLayout.chipWidths.upperBound)
        let none = TabStripLayout(items: [.group(work), .tab(a)], chipWidths: [:], width: 600)
        XCTAssertEqual(none.slots[0].frame.width, TabStripLayout.chipWidths.lowerBound)
    }

    func testWhatIsUnderThePointer() throws {
        let l = TabStripLayout(items: [.group(work), .tab(a), .tab(b)], chipWidths: [work: 50], width: 800)
        let chip = l.slots[0].frame, tab = l.slots[2].frame
        XCTAssertEqual(l.slot(at: CGPoint(x: chip.midX, y: chip.midY))?.item, .group(work))
        XCTAssertEqual(l.slot(at: CGPoint(x: tab.midX, y: tab.midY))?.item, .tab(b))
        XCTAssertNil(l.slot(at: CGPoint(x: 790, y: tab.midY)))
        XCTAssertTrue(tab.contains(TabStripLayout.closeBox(in: tab)))
    }

    func testADragLetsGoBeforeOrAfterWhatIsUnderIt() {
        let l = TabStripLayout(items: [.tab(a), .group(work), .tab(b), .tab(c)], chipWidths: [work: 50], width: 900)
        let ta = l.slots[0].frame, chip = l.slots[1].frame, tc = l.slots[3].frame
        XCTAssertEqual(l.drop(at: ta.minX + 2), .before(.tab(a)))
        XCTAssertEqual(l.drop(at: ta.maxX - 2), .after(.tab(a)))
        XCTAssertEqual(l.drop(at: chip.minX + 2), .before(.group(work)))
        XCTAssertEqual(l.drop(at: chip.maxX - 2), .after(.group(work)))
        XCTAssertEqual(l.drop(at: tc.maxX - 2), .after(.tab(c)))
        XCTAssertEqual(l.drop(at: tc.maxX + 80), .end)
        XCTAssertEqual(l.drop(at: -10), .before(.tab(a)))
        XCTAssertEqual(l.drop(at: ta.maxX + 1), .after(.tab(a)), "in a gap: after what is before it")
    }
}
