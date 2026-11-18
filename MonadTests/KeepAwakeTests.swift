//
//  KeepAwakeTests.swift — the coffee cup of a terminal window: what it
//  holds while it is on, and what the cup shows.
//

import XCTest
@testable import Monad

@MainActor
final class KeepAwakeTests: XCTestCase {
    private let preventer = FakeSleepPreventer()

    /// On: one hold on the Mac's sleep, with a reason macOS can show
    /// (`pmset -g assertions`); off: that hold ended. Never two at once,
    /// and nothing held from the start.
    func testOnHoldsTheMacAwakeUntilItIsOffAgain() {
        let awake = KeepAwake(preventer: preventer)
        XCTAssertFalse(awake.isOn, "off when Monad starts")
        XCTAssertEqual(preventer.held, 0)
        awake.toggle()
        XCTAssertTrue(awake.isOn)
        XCTAssertEqual(preventer.begun, [KeepAwake.reason])
        awake.set(true)
        XCTAssertEqual(preventer.held, 1, "one hold, however often it is asked")
        awake.toggle()
        XCTAssertFalse(awake.isOn)
        XCTAssertEqual(preventer.held, 0)
        awake.set(false)
        XCTAssertEqual(preventer.ended, 1)
        awake.toggle()
        XCTAssertEqual(preventer.begun.count, 2, "on again: a new hold")
        XCTAssertEqual(preventer.held, 1)
    }

    /// A click on the cup turns it; every window's cup shows the one
    /// switch: empty when off, full with steam when on, said to VoiceOver
    /// too.
    func testACupTurnsItAndEveryCupShowsIt() {
        let awake = KeepAwake(preventer: preventer)
        let cup = KeepAwakeButton(state: awake), other = KeepAwakeButton(state: awake)
        XCTAssertFalse(cup.showsSteam)
        XCTAssertEqual(cup.accessibilityValue() as? Int, 0)
        XCTAssertEqual(cup.accessibilityLabel(), "Keep this Mac awake")
        XCTAssertTrue(cup.accessibilityPerformPress())
        XCTAssertTrue(awake.isOn)
        XCTAssertEqual(preventer.held, 1)
        for c in [cup, other] {
            XCTAssertTrue(c.showsSteam)
            XCTAssertEqual(c.accessibilityValue() as? Int, 1)
        }
        XCTAssertNotEqual(cup.toolTip, KeepAwakeButton(state: KeepAwake(preventer: preventer)).toolTip, "the tip says which it is")
        XCTAssertTrue(other.accessibilityPerformPress())
        XCTAssertFalse(awake.isOn)
        XCTAssertFalse(cup.showsSteam)
        XCTAssertFalse(cup.steamMoves)
        XCTAssertEqual(preventer.held, 0)
    }

    /// The steam rises while it is on. With Reduce Motion it is there and
    /// stands still.
    func testTheSteamStandsStillWithReduceMotion() {
        let awake = KeepAwake(preventer: preventer)
        let moving = KeepAwakeButton(state: awake)
        let still = KeepAwakeButton(state: awake)
        still.reducesMotion = { true }
        moving.reducesMotion = { false }
        awake.set(true)
        XCTAssertTrue(moving.showsSteam)
        XCTAssertTrue(moving.steamMoves)
        XCTAssertTrue(still.showsSteam)
        XCTAssertFalse(still.steamMoves)
    }

    /// A press that ends outside the cup does nothing, as with any button.
    func testAPressLetGoOutsideDoesNothing() throws {
        let awake = KeepAwake(preventer: preventer)
        let cup = KeepAwakeButton(state: awake)
        cup.frame = NSRect(origin: .zero, size: KeepAwakeButton.size)
        XCTAssertTrue(cup.release(at: NSPoint(x: 13, y: 11), pressed: true))
        XCTAssertTrue(awake.isOn)
        XCTAssertFalse(cup.release(at: NSPoint(x: 80, y: 11), pressed: true))
        XCTAssertTrue(awake.isOn, "unchanged")
        XCTAssertFalse(cup.release(at: NSPoint(x: 13, y: 11), pressed: false))
        XCTAssertTrue(awake.isOn, "unchanged")
    }
}
