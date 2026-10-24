//
//  HostCommandDraftTests.swift — Add Host Command…: the form's fields make
//  the command, each problem said, and what the VM can then do is asked
//  before it is added.
//

import XCTest
@testable import Monad

final class HostCommandDraftTests: XCTestCase {
    private let share = SharedFolder(hostPath: "/Users/someone/src", guestPath: "/home/dev/src", readOnly: false)

    func testTheFormMakesTheCommand() throws {
        var d = HostCommandDraft(shares: [share])
        XCTAssertEqual(d.workingDirectory, "/Users/someone/src", "working in the VM's first shared folder")
        d.name = "app-make"
        d.summary = "Build the app."
        d.program = "make"
        d.fixedArguments = "-C app"
        d.arguments = [.init(name: "target", pattern: "^(build|test)$", required: true, summary: "The target.")]
        d.timeoutMinutes = 30
        d.environment = "PATH=/opt/homebrew/bin:/usr/bin:/bin\n\nCC=clang\n"
        d.guestPort = "9100"
        let (command, problem) = d.command(shares: [share], searchPath: "/usr/bin:/bin")
        XCTAssertNil(problem)
        let c = try XCTUnwrap(command)
        XCTAssertEqual(c.program, "/usr/bin/make")
        XCTAssertEqual(c.fixedArguments, ["-C", "app"])
        XCTAssertEqual(c.timeoutSeconds, 1800)
        XCTAssertEqual(c.environment, ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "CC": "clang"])
        XCTAssertEqual(c.guestEndpoint, "127.0.0.1:9100")
        XCTAssertEqual(c.arguments.map(\.name), ["target"])
    }

    func testEachProblemIsSaid() {
        var d = HostCommandDraft(shares: [share])
        XCTAssertEqual(d.command(shares: [share]).1, "Give it a name: the tool's name for agents.")
        d.name = "x"
        XCTAssertEqual(d.command(shares: [share]).1, "Which program?")
        d.program = "no-such-program-here"
        XCTAssertEqual(d.command(shares: [share], searchPath: "/usr/bin").1, "No program by that name.")
        d.program = "/bin/echo"
        d.environment = "JUSTANAME"
        XCTAssertEqual(d.command(shares: [share]).1, "“JUSTANAME” is not NAME=value.")
        d.environment = ""
        XCTAssertEqual(d.command(shares: [share]).1, "In the VM: a port from 1024 to 65535, or a socket's full path.")
        d.guestPort = "9100"
        d.workingDirectory = "/Users/someone"
        XCTAssertEqual(d.command(shares: [share]).1, "The working folder must be inside a folder this VM shares.")
    }

    /// What the user agrees to: the program, where, the values and their
    /// patterns, the time limit, and what lets anything through.
    func testTheConfirmationSaysWhatTheVMCanDo() {
        var c = buildCommand(in: "/Users/someone/src/app")
        c.arguments = Array(c.arguments.prefix(1))
        XCTAssertEqual(HostCommandDraft.confirmation(for: c),
                       "The VM will be able to run “/usr/bin/make” on this Mac, as you, in /Users/someone/src/app, "
                       + "adding target (^(build|test|benchmark)$). One run at a time, ended after 1 hour.")
        c.arguments[0].pattern = "^.*$"
        c.timeoutSeconds = 90
        XCTAssertTrue(HostCommandDraft.confirmation(for: c).hasSuffix(
            "ended after 90 seconds. target takes anything (.*): the program gets whatever the VM sends."))
    }
}
