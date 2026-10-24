//
//  SheetSubmissionTests.swift — a sheet's one action (New VM's Create,
//  Import): busy while it runs, pressed once, its error shown in the sheet
//  (an alert on the window behind a sheet waits until the sheet closes, so
//  a failed Create said nothing and a second press said "already exists").
//

import XCTest
@testable import Monad

@MainActor
final class SheetSubmissionTests: XCTestCase {
    /// Busy while the action runs, not after; no error when it works.
    func testItIsBusyWhileTheActionRuns() async {
        let s = SheetSubmission()
        var busyInside = false
        await s.submit { busyInside = s.busy }
        XCTAssertTrue(busyInside)
        XCTAssertFalse(s.busy)
        XCTAssertNil(s.error)
    }

    /// A failed action's reason stays in the sheet, in plain words.
    func testAFailureIsShownInTheSheet() async {
        let s = SheetSubmission()
        await s.submit { throw MonadError("Not enough free disk space.") }
        XCTAssertEqual(s.error, "Not enough free disk space.")
        XCTAssertFalse(s.busy)
    }

    /// A second press while the first runs does nothing.
    func testASecondPressWhileBusyIsIgnored() async {
        let s = SheetSubmission()
        var runs = 0
        let gate = AsyncStream<Void>.makeStream()
        let first = Task { await s.submit { runs += 1; for await _ in gate.stream { break } } }
        await assertEventually { s.busy }
        await s.submit { runs += 1 }
        gate.continuation.yield()
        await first.value
        XCTAssertEqual(runs, 1)
    }

    /// Trying again clears the last failure until there is a new one.
    func testTryingAgainClearsTheLastFailure() async {
        let s = SheetSubmission()
        await s.submit { throw MonadError("first") }
        var errorInside: String? = "unset"
        await s.submit { errorInside = s.error }
        XCTAssertNil(errorInside)
        XCTAssertNil(s.error)
    }
}
