//
//  TerminalResizeTests.swift — a terminal's size as its view resizes: the
//  grid follows the view while it is in a window and has room for a cell,
//  and the shell (the PTY) hears only the size a layout pass settles on.
//  The bug: splitting a pane took its terminal through a zero frame, the
//  shell was told 2x1 and redrew its prompt for two columns, and back at
//  full width it moved the cursor up into the lines above.
//

import AppKit
import XCTest
@testable import Monad

@MainActor
final class TerminalResizeTests: XCTestCase {
    private final class Spy: TerminalViewDelegate {
        var sizes: [[Int]] = []
        func terminalView(_ view: MonadTerminalView, send data: Data) {}
        func terminalView(_ view: MonadTerminalView, didResizeTo cols: Int, rows: Int, pixels: CGSize) {
            sizes.append([cols, rows])
        }
        func terminalView(_ view: MonadTerminalView, receivedImages images: [ImagePayload]) -> Bool { false }
        func terminalView(_ view: MonadTerminalView, receivedFiles urls: [URL]) -> Bool { false }
    }

    private var window: NSWindow?

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    /// A terminal view in a window that is never shown, at 640x400.
    private func makeView(_ spy: Spy) throws -> MonadTerminalView {
        let model = try XCTUnwrap(TerminalModel(cols: 80, rows: 24, scrollback: 100))
        let view = MonadTerminalView(model: model)
        view.delegate = spy
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        w.contentView?.addSubview(view)
        window = w
        settle()
        return view
    }

    /// The grid a view of `size` holds (6 and 4 points of padding).
    private func grid(_ view: MonadTerminalView, _ width: CGFloat, _ height: CGFloat) -> [Int] {
        [max(2, Int((width - 12) / view.cellSize.width)), max(1, Int((height - 8) / view.cellSize.height))]
    }

    /// Lets the main queue run what the layout pass left for later.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testTheShellHearsOnlyTheSizeTheLayoutSettlesOn() throws {
        let spy = Spy()
        let view = try makeView(spy)
        XCTAssertEqual(spy.sizes, [grid(view, 640, 400)], "told once as it enters the window")
        spy.sizes = []
        view.frame.size = NSSize(width: 300, height: 400)
        view.frame.size = NSSize(width: 0, height: 0)
        view.frame.size = NSSize(width: 320, height: 200)
        XCTAssertEqual(spy.sizes, [], "not while the layout pass goes on")
        XCTAssertEqual([view.cols, view.rows], grid(view, 320, 200), "the grid follows at once, for drawing")
        settle()
        XCTAssertEqual(spy.sizes, [grid(view, 320, 200)], "once, the size it settled on")
        view.frame.size = NSSize(width: 330, height: 200)
        view.frame.size = NSSize(width: 320, height: 200)
        settle()
        XCTAssertEqual(spy.sizes.count, 1, "back where it was: nothing new to tell")
    }

    func testAViewWithNoRoomOrNoWindowKeepsItsGrid() throws {
        let spy = Spy()
        let view = try makeView(spy)
        let before = [view.cols, view.rows]
        view.frame.size = .zero
        XCTAssertEqual([view.cols, view.rows], before, "a zero frame is a pane being rebuilt, not 2x1")
        XCTAssertEqual([view.model.size.cols, view.model.size.rows], before)
        view.frame.size = NSSize(width: 4, height: 400)
        XCTAssertEqual([view.cols, view.rows], before, "no room for a cell")
        let superview = view.superview
        view.removeFromSuperview()
        view.frame.size = NSSize(width: 200, height: 100)
        XCTAssertEqual([view.cols, view.rows], before, "out of a window: moved between split views")
        superview?.addSubview(view)
        XCTAssertEqual([view.cols, view.rows], grid(view, 200, 100), "back in a window: its size now")
        settle()
        XCTAssertEqual(spy.sizes.last, grid(view, 200, 100))
        XCTAssertFalse(spy.sizes.contains([2, 1]), "never 2x1")
    }
}
