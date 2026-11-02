//
//  MCPStdioTests.swift — `MonadHost --mcp` when the running MonadHost
//  cannot be reached: it keeps answering, every request with an error that
//  says why (with launchd's view of the job), instead of closing the
//  connection with the reason on stderr, which no MCP client shows.
//

import XCTest
@testable import Monad

@MainActor
final class MCPStdioTests: XCTestCase {
    private func object(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any])
    }

    func testEveryRequestIsAnsweredWithTheReason() throws {
        let reason = "MonadHost cannot be reached: Couldn’t communicate with a helper application."
        let call = try object(MCPStdio.unreachableAnswer(
            to: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_vms"}}"#, reason: reason))
        XCTAssertEqual(call["id"] as? Int, 7)
        let error = try XCTUnwrap(call["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String, reason)
        XCTAssertEqual(error["code"] as? Int, -32603)
        let initialize = try object(MCPStdio.unreachableAnswer(to: #"{"jsonrpc":"2.0","id":"a","method":"initialize"}"#, reason: reason))
        XCTAssertEqual(initialize["id"] as? String, "a")
        XCTAssertNil(MCPStdio.unreachableAnswer(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, reason: reason),
                     "a notification gets no answer")
        let garbage = try object(MCPStdio.unreachableAnswer(to: "not json", reason: reason))
        XCTAssertTrue(garbage["id"] is NSNull)
    }

    /// What launchd says of the job, in a few words: whether a MonadHost
    /// runs, its pid and the binary it runs (another copy of Monad's shows).
    func testLaunchdsViewIsSummed() {
        let printed = """
            gui/501/dev.monad.debug.host = {
            \tactive count = 2
            \tpath = /Users/dev/.monad-debug/launchd/dev.monad.debug.host.plist
            \ttype = LaunchAgent
            \tstate = running

            \tprogram = /Users/dev/Library/Developer/Xcode/DerivedData/Monad-abc/Build/Products/Debug/Monad.app/Contents/MacOS/MonadHost
            \tpid = 4242
            \tlast exit code = 0
            }
            """
        XCTAssertEqual(MCPStdio.launchdSummary(status: 0, printed: printed),
                       "launchd: running, pid 4242, /Users/dev/Library/Developer/Xcode/DerivedData/Monad-abc/Build/Products/Debug/Monad.app/Contents/MacOS/MonadHost")
        XCTAssertEqual(MCPStdio.launchdSummary(status: 0, printed: "\tstate = not running\n\tprogram = /x/MonadHost\n"),
                       "launchd: not running, /x/MonadHost")
        XCTAssertEqual(MCPStdio.launchdSummary(status: 113, printed: "Could not find service"), "launchd has no MonadHost job")
    }
}
