//
//  SSHHostAgentTests.swift — Monad's agent on an SSH host: which servers
//  it runs on (by what they say they are), what Monad runs there to put it
//  in ~/.monad, to run it and to take it away, and what the user is asked
//  before it goes there.
//

import XCTest
@testable import Monad

final class SSHHostAgentTests: XCTestCase {
    /// `uname -s` on the server, after whatever its login shell printed.
    func testTheServersSystemIsWhatUnameSaysLast() {
        XCTAssertEqual(SSHHostAgent.System(uname: "Linux\n"), .linux)
        XCTAssertEqual(SSHHostAgent.System(uname: "Darwin\r\n"), .macos)
        XCTAssertEqual(SSHHostAgent.System(uname: "Welcome to box!\nLast login: today\n\n  Linux  \n\n"), .linux)
        XCTAssertNil(SSHHostAgent.System(uname: "FreeBSD\n"))
        XCTAssertNil(SSHHostAgent.System(uname: "Linux\nbash: fortune: command not found\n"), "only the last line is uname's")
        XCTAssertNil(SSHHostAgent.System(uname: ""))
        // What a server says is shown as plain text, and not at length.
        XCTAssertEqual(SSHHostAgent.System.said("\u{1B}[31mSunOS\u{1B}[0m\n"), "[31mSunOS[0m")
        XCTAssertEqual(SSHHostAgent.System.said(String(repeating: "x", count: 500))?.count, 41)
        XCTAssertNil(SSHHostAgent.System.said(" \n\n"))
    }

    /// The same scripts a VM runs, from the app bundle.
    func testEachSystemHasItsAgent() throws {
        XCTAssertEqual(SSHHostAgent.script(for: .linux), try CloudInit.agentScript())
        XCTAssertEqual(SSHHostAgent.script(for: .macos), try MacSetup.agentScript())
        XCTAssertNotEqual(SSHHostAgent.script(for: .linux), SSHHostAgent.script(for: .macos))
    }

    /// What runs on the server is fixed text, one word for whatever login
    /// shell the account has: nothing a server said is ever part of it.
    func testWhatRunsOnTheServer() {
        XCTAssertEqual(SSHHostAgent.probe, "uname -s")
        XCTAssertEqual(SSHHostAgent.remote(SSHHostAgent.remove),
                       #"sh -c 'rm -f "$HOME/.monad/monad-agent.sh" "$HOME/.monad/monad-agent.sh.new"'"#)
        XCTAssertEqual(SSHHostAgent.install,
                       #"d="$HOME/.monad"; umask 077; mkdir -p "$d" && cat > "$d/monad-agent.sh.new" && mv -f "$d/monad-agent.sh.new" "$d/monad-agent.sh""#)
        XCTAssertEqual(SSHHostAgent.run(.linux),
                       #"MONAD_AGENT_INTERVAL=2 MONAD_AGENT_KEEPALIVE=5 exec sh "$HOME/.monad/monad-agent.sh""#)
        // On macOS: no watching for password prompts (a guest's), and the
        // account's own listeners from lsof where netstat shows it none.
        XCTAssertEqual(SSHHostAgent.run(.macos),
                       #"MONAD_AGENT_INTERVAL=2 MONAD_AGENT_KEEPALIVE=5 MONAD_PROMPTS=true "#
                           + #"MONAD_LSOF="/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Ftn" exec sh "$HOME/.monad/monad-agent.sh""#)
        for command in [SSHHostAgent.install, SSHHostAgent.remove, SSHHostAgent.run(.linux), SSHHostAgent.run(.macos)] {
            XCTAssertFalse(command.contains("'"), "single-quoted whole for the login shell")
        }
    }

    func testTheQuestionSaysWhatGoesOntoTheServer() {
        let q = SSHHostAgent.question(host: "box", user: "dev")
        XCTAssertEqual(q.title, "Put Monad's agent on “box”?")
        for said in ["~/.monad/monad-agent.sh", "as dev", "Nothing is installed as root", "from 1024 up"] {
            XCTAssertTrue(q.message.contains(said), said)
        }
    }
}
