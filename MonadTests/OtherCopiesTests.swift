//
//  OtherCopiesTests.swift — one copy of Monad per flavor: a newer copy asks
//  the older ones to quit, since two copies take turns replacing MonadHost
//  and every turn powers off its VMs (seen with two Debug copies, 2026-11-01).
//

import XCTest
@testable import Monad

final class OtherCopiesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testTheOlderCopiesAreAskedToQuit() {
        let copies = [RunningCopy(pid: 10, launched: t0),
                      RunningCopy(pid: 11, launched: t0.addingTimeInterval(60)),
                      RunningCopy(pid: 12, launched: t0.addingTimeInterval(120))]
        XCTAssertEqual(OtherCopies.toQuit(copies, me: 12), [10, 11], "the newest stays")
        XCTAssertEqual(OtherCopies.toQuit(copies, me: 11), [10], "a newer one quits this one, not the other way")
        XCTAssertEqual(OtherCopies.toQuit(copies, me: 10), [])
        XCTAssertEqual(OtherCopies.toQuit([RunningCopy(pid: 12, launched: t0)], me: 12), [], "alone")
    }

    /// Launched in the same instant (or no date known): the lower pid is the
    /// older one, so exactly one copy stays.
    func testATieKeepsExactlyOne() {
        let copies = [RunningCopy(pid: 20, launched: t0), RunningCopy(pid: 21, launched: t0), RunningCopy(pid: 22, launched: nil)]
        XCTAssertEqual(OtherCopies.toQuit(copies, me: 21), [20])
        XCTAssertEqual(OtherCopies.toQuit(copies, me: 20), [])
        XCTAssertEqual(OtherCopies.toQuit(copies, me: 22), [], "no date: never quits the others")
    }
}
