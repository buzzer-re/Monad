//
//  PaneContainerTests.swift — a window's panes on screen (Phase 11): real
//  split views in a window, built from the tree. A new pane gets its share
//  of the room (AppKit resizing the panes while they are built must not
//  squeeze it out), pane views live as long as their panes, resizing keeps
//  the fractions, and only a divider the user drags changes them.
//

import AppKit
import XCTest
@testable import Monad

@MainActor
final class PaneContainerTests: XCTestCase {
    private let a = PaneID("a"), b = PaneID("b"), c = PaneID("c")

    /// A container as the content of a window that is never shown.
    private func makeContainer(width: CGFloat = 801, height: CGFloat = 501) -> (PaneContainerView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = PaneContainerView()
        window.contentView = container
        return (container, window)
    }

    /// A pane's frame in the container (y grows downwards, as in the tree).
    private func frame(_ pane: PaneID, in container: PaneContainerView) -> CGRect {
        guard let view = container.paneView(pane) else { return .zero }
        return container.convert(view.bounds, from: view)
    }

    /// Equal but for the dividers (1 pt) and rounding.
    private func assertFrame(_ got: CGRect, _ expected: CGRect, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        let pairs = [(got.minX, expected.minX), (got.minY, expected.minY), (got.width, expected.width), (got.height, expected.height)]
        for (g, e) in pairs {
            XCTAssertEqual(g, e, accuracy: 1.5, "\(got) is not \(expected) \(message)", file: file, line: line)
        }
    }

    func testAPaneFillsItsViewBelowItsHeader() {
        let pane = PaneView(id: a)
        let content = NSView()
        pane.show(content)
        pane.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        XCTAssertEqual(content.frame, NSRect(x: 0, y: 0, width: 300, height: 200), "as it resizes, not on a later layout pass")
        XCTAssertTrue(pane.header.isHidden)
        pane.showsHeader = true
        XCTAssertFalse(pane.header.isHidden)
        let below = NSRect(x: 0, y: PaneHeaderView.height, width: 300, height: 200 - PaneHeaderView.height)
        XCTAssertEqual(content.frame, below)
        let other = NSView()
        pane.show(other)
        XCTAssertNil(content.superview, "the context shown before leaves the hierarchy")
        XCTAssertEqual(other.frame, below)
    }

    /// The bug: AppKit sized the split's subviews while it was built (the
    /// new pane had no room yet), that was taken for the user's divider,
    /// and the new pane was squeezed to nothing.
    func testANewPaneGetsItsShare() {
        let (container, window) = makeContainer()
        defer { window.close() }
        var t = PaneTree(pane: a)
        // As the window does: a divider moved goes back into the tree.
        container.onFractions = { t.setFractions($0, ofSplitAt: $1) }
        container.show(t)
        assertFrame(frame(a, in: container), CGRect(x: 0, y: 0, width: 801, height: 501))
        t.split(a, .horizontal, new: b)
        container.show(t)
        XCTAssertEqual(t.fractions(ofSplitAt: []), [0.5, 0.5], "building moved no divider")
        assertFrame(frame(a, in: container), CGRect(x: 0, y: 0, width: 400, height: 501))
        assertFrame(frame(b, in: container), CGRect(x: 401, y: 0, width: 400, height: 501), "side by side")
        t.split(b, .vertical, new: c)
        container.show(t)
        XCTAssertEqual(t.fractions(ofSplitAt: []), [0.5, 0.5])
        XCTAssertEqual(t.fractions(ofSplitAt: [1]), [0.5, 0.5])
        assertFrame(frame(a, in: container), CGRect(x: 0, y: 0, width: 400, height: 501))
        assertFrame(frame(b, in: container), CGRect(x: 401, y: 0, width: 400, height: 250))
        assertFrame(frame(c, in: container), CGRect(x: 401, y: 251, width: 400, height: 250), "stacked in the right half")
    }

    /// Every size a pane's content is given while it is in the window.
    private final class SizeSpy: NSView {
        var sizes: [NSSize] = []
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if window != nil { sizes.append(newSize) }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { sizes.append(frame.size) }
        }
    }

    /// The panes are rebuilt into new split views on every change: each
    /// gets its frame before it is back in the window, never an empty one
    /// there (its terminal would reflow to nothing on the way).
    func testSplittingNeverEmptiesAPane() {
        let (container, window) = makeContainer()
        defer { window.close() }
        let spies = [a: SizeSpy(), b: SizeSpy(), c: SizeSpy()]
        container.onNewPane = { pane in spies[pane.id].map { pane.show($0) } }
        var t = PaneTree(pane: a)
        container.show(t)
        t.split(a, .horizontal, new: b)
        container.show(t)
        t.split(b, .vertical, new: c)
        container.show(t)
        for (id, spy) in spies {
            XCTAssertFalse(spy.sizes.isEmpty, "\(id) was shown")
            for size in spy.sizes {
                XCTAssertGreaterThan(size.width, 100, "\(id): \(spy.sizes)")
                XCTAssertGreaterThan(size.height, 100, "\(id): \(spy.sizes)")
            }
        }
    }

    func testPaneViewsLiveAsLongAsTheirPanes() {
        let (container, window) = makeContainer()
        defer { window.close() }
        var t = PaneTree(pane: a)
        container.show(t)
        let first = container.paneView(a)
        t.split(a, .vertical, new: b)
        container.show(t)
        XCTAssertTrue(container.paneView(a) === first, "the same view: its terminal goes on")
        assertFrame(frame(a, in: container), CGRect(x: 0, y: 0, width: 801, height: 250))
        assertFrame(frame(b, in: container), CGRect(x: 0, y: 251, width: 801, height: 250), "stacked")
        XCTAssertTrue(t.close(b))
        container.show(t)
        XCTAssertNil(container.paneView(b))
        assertFrame(frame(a, in: container), CGRect(x: 0, y: 0, width: 801, height: 501), "its room back")
    }

    func testResizingKeepsTheFractions() {
        let (container, window) = makeContainer()
        defer { window.close() }
        var reported = 0
        container.onFractions = { _, _ in reported += 1 }
        var t = PaneTree(pane: a)
        t.split(a, .horizontal, new: b)
        t.setFractions([0.25, 0.75], ofSplitAt: [])
        container.show(t)
        assertFrame(frame(a, in: container), CGRect(x: 0, y: 0, width: 200, height: 501))
        window.setContentSize(NSSize(width: 401, height: 301))
        assertFrame(frame(a, in: container), CGRect(x: 0, y: 0, width: 100, height: 301))
        assertFrame(frame(b, in: container), CGRect(x: 101, y: 0, width: 300, height: 301))
        XCTAssertEqual(reported, 0, "building and resizing are not the user moving a divider")
    }

    func testOnlyADraggedDividerChangesTheFractions() throws {
        let (container, window) = makeContainer(width: 601)
        defer { window.close() }
        var reported: [(fractions: [Double], path: [Int])] = []
        container.onFractions = { reported.append(($0, $1)) }
        var t = PaneTree(pane: a)
        t.split(a, .horizontal, new: b)
        t.split(b, .vertical, new: c)
        container.show(t)
        let split = try XCTUnwrap(container.subviews.first as? PaneSplitView)
        split.setPosition(200, ofDividerAt: 0)
        XCTAssertTrue(reported.isEmpty, "the window moving a divider is not the user")
        // AppKit drags a divider inside the split view's mouseDown.
        split.draggingDivider = true
        split.setPosition(200, ofDividerAt: 0)
        split.setPosition(150, ofDividerAt: 0)
        split.draggingDivider = false
        XCTAssertEqual(reported.last?.path, [])
        XCTAssertEqual(reported.last?.fractions.first ?? 0, 150.0 / 600.0, accuracy: 0.01)
        let count = reported.count
        window.setContentSize(NSSize(width: 301, height: 301))
        XCTAssertEqual(reported.count, count, "resizing the window is not dragging a divider")
    }
}

