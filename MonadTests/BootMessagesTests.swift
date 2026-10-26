//
//  BootMessagesTests.swift — Settings › Virtual Machines › Full boot
//  messages: quiet until chosen, shared with MonadHost through a file and a
//  notification.
//

import XCTest
@testable import Monad

@MainActor
final class BootMessagesTests: XCTestCase {
    func testQuietUntilFullIsChosenAndTheChoiceIsShared() async throws {
        let tmp = TempDir()
        let settings = tmp.url.appendingPathComponent("boot-messages.json")
        XCTAssertEqual(BootMessages.load(settings: settings), .quiet)

        let name = "dev.monad.test.boot-messages.\(UUID().uuidString)"
        let told = expectation(description: "MonadHost told")
        told.assertForOverFulfill = false
        let token = BootMessages.watch(notification: name) { told.fulfill() }
        defer { token.map { _ = notify_cancel($0) } }
        try BootMessages.save(.full, settings: settings, notification: name)
        await fulfillment(of: [told], timeout: 5)
        XCTAssertEqual(BootMessages.load(settings: settings), .full)

        try BootMessages.save(.quiet, settings: settings, notification: name)
        XCTAssertEqual(BootMessages.load(settings: settings), .quiet)
        try Data("not json".utf8).write(to: settings)
        XCTAssertEqual(BootMessages.load(settings: settings), .quiet, "anything else is quiet")
    }

    func testEachFlavorHasItsOwnNotification() {
        XCTAssertNotEqual(BootMessages.notification(debug: true), BootMessages.notification(debug: false))
    }
}
