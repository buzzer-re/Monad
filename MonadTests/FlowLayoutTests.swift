//
//  FlowLayoutTests.swift — a VM row's name and tags: whole tags, wrapped
//  onto the next line when the row is narrow.
//

import XCTest
@testable import Monad

final class FlowLayoutTests: XCTestCase {
    /// What fits stays on one line, left to right with the spacing between.
    func testWhatFitsStaysOnOneLine() {
        let frames = Flow.frames(for: [CGSize(width: 40, height: 20), CGSize(width: 30, height: 16)], width: 100, spacing: 8)
        XCTAssertEqual(frames, [CGRect(x: 0, y: 0, width: 40, height: 20), CGRect(x: 48, y: 2, width: 30, height: 16)])
    }

    /// A tag that does not fit starts the next line, whole.
    func testATagThatDoesNotFitGoesToTheNextLine() {
        let sizes = [CGSize(width: 60, height: 20), CGSize(width: 30, height: 16), CGSize(width: 30, height: 16)]
        let frames = Flow.frames(for: sizes, width: 100, spacing: 8, lineSpacing: 4)
        XCTAssertEqual(frames[1].origin, CGPoint(x: 68, y: 2))
        XCTAssertEqual(frames[2].origin, CGPoint(x: 0, y: 24))
    }

    /// Something wider than the row gets the row's width (a long name truncates).
    func testSomethingWiderThanTheRowIsNarrowed() {
        let frames = Flow.frames(for: [CGSize(width: 300, height: 20), CGSize(width: 30, height: 16)], width: 100, spacing: 8)
        XCTAssertEqual(frames[0], CGRect(x: 0, y: 0, width: 100, height: 20))
        XCTAssertEqual(frames[1].origin.y, 20 + Flow.defaultLineSpacing)
    }

    /// The size taken: the widest line and every line's height.
    func testTheSizeTaken() {
        let sizes = [CGSize(width: 60, height: 20), CGSize(width: 50, height: 16)]
        XCTAssertEqual(Flow.size(of: Flow.frames(for: sizes, width: 100, spacing: 8, lineSpacing: 4)), CGSize(width: 60, height: 40))
    }
}
