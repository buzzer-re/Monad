//
//  SSHAskpassTests.swift — ssh's questions about an SSH host: which ones a
//  stored password may answer (only ssh's own password question for that
//  user and host), how a server's words are shown, and that tickets and
//  waiting questions are bounded and end by themselves.
//

import XCTest
@testable import Monad

@MainActor
final class SSHAskpassTests: XCTestCase {
    private let box = SSHHost(name: "box", host: "example.com", user: "dev", auth: .password)

    // MARK: Which prompt is the password's

    func testSshsOwnPasswordQuestionsAreRecognised() {
        XCTAssertTrue(SSHAskpass.isPasswordPrompt("dev@example.com's password: ", for: box))
        XCTAssertTrue(SSHAskpass.isPasswordPrompt("(dev@example.com) Password: ", for: box))
        XCTAssertTrue(SSHAskpass.isPasswordPrompt("dev@example.com's password:", for: box))
    }

    /// A server words its own prompts: none of them gets the stored password.
    func testALookAlikeIsNotThePasswordQuestion() {
        for prompt in ["Password:", "Password: ", "New password: ", "(dev@example.com) New password: ",
                       "(dev@example.com) Verification code: ", "ops@example.com's password: ",
                       "dev@example.org's password: ", "dev@example.com's password: \nPassword:",
                       "Enter passphrase for key '/Users/dev/.ssh/id_ed25519': ",
                       "x dev@example.com's password: ", ""] {
            XCTAssertFalse(SSHAskpass.isPasswordPrompt(prompt, for: box), prompt)
        }
    }

    /// The system's ssh prints the user and host whole; older ones printed
    /// at most 30 characters of the user and 128 of the host. Both are ssh's own.
    func testALongUserIsMatchedAsSshPrintsIt() {
        var long = box
        long.user = String(repeating: "u", count: 31)
        XCTAssertTrue(SSHAskpass.isPasswordPrompt("\(long.user)@example.com's password: ", for: long))
        XCTAssertFalse(SSHAskpass.isPasswordPrompt("(\(String(repeating: "u", count: 30))@example.com) Password: ", for: long),
                       "its keyboard-interactive prompt is never cut")
        XCTAssertTrue(SSHAskpass.isPasswordPrompt("\(String(repeating: "u", count: 30))@example.com's password: ", for: long))
    }

    // MARK: What kind of question

    func testTheKindOfAQuestion() {
        let hostKey = """
            The authenticity of host 'example.com (203.0.113.7)' can't be established.
            ED25519 key fingerprint is SHA256:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ.
            This key is not known by any other names.
            Are you sure you want to continue connecting (yes/no/[fingerprint])?
            """
        XCTAssertEqual(SSHAskpass.kind(prompt: hostKey, hint: nil), .confirm)
        XCTAssertEqual(SSHAskpass.kind(prompt: "Allow use of key?", hint: "confirm"), .confirm)
        XCTAssertEqual(SSHAskpass.kind(prompt: "dev@example.com's password: ", hint: nil), .secret)
        XCTAssertEqual(SSHAskpass.kind(prompt: "Verification code: ", hint: nil), .secret)
        XCTAssertNil(SSHAskpass.kind(prompt: "Confirm user presence for key", hint: "none"), "ssh only tells")
    }

    // MARK: What is shown

    func testAServersWordsAreShownPlainAndBounded() {
        let hostile = "Password for \u{1B}[2J\u{202E}evil\u{7}:\r\n" + String(repeating: "x", count: 500) + "\n"
            + (1...20).map { "line \($0)" }.joined(separator: "\n")
        let lines = SSHAskpass.shown(hostile).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 8)
        XCTAssertEqual(lines[0], "Password for [2Jevil:", "no escape, bell or direction override")
        XCTAssertEqual(lines[1], String(repeating: "x", count: 200) + "…")
        XCTAssertEqual(lines[7], "line 6")
        XCTAssertEqual(SSHAskpass.shown("dev@example.com's password: "), "dev@example.com's password: ")
    }

    // MARK: The environment and the answer

    func testSshIsToldToAskMonadEvenWithATerminal() {
        XCTAssertEqual(SSHAskpass.environment(ticket: "abc", helper: "/Applications/Monad.app/Contents/MacOS/MonadHost"),
                       ["SSH_ASKPASS": "/Applications/Monad.app/Contents/MacOS/MonadHost", "SSH_ASKPASS_REQUIRE": "force",
                        "MONAD_ASKPASS_TICKET": "abc"])
    }

    func testAnAnswerIsOneLineWithinSshsLimit() {
        XCTAssertTrue(SSHAskpass.isAnswerable("correct horse battery staple"))
        XCTAssertTrue(SSHAskpass.isAnswerable(String(repeating: "p", count: 1023)))
        XCTAssertFalse(SSHAskpass.isAnswerable(String(repeating: "p", count: 1024)))
        XCTAssertFalse(SSHAskpass.isAnswerable("a\nb"))
        XCTAssertFalse(SSHAskpass.isAnswerable("a\r\nb"))
        XCTAssertFalse(SSHAskpass.isAnswerable("a\rb"))
    }

    // MARK: Tickets

    func testATicketIsRandomAndNamesItsHost() {
        let tickets = SSHTickets(clock: TestClock())
        let a = tickets.issue(for: "box"), b = tickets.issue(for: "box")
        XCTAssertTrue(SSHAskpass.isTicket(a), a)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(tickets.ticket(a), SSHTickets.Ticket(host: "box"))
        XCTAssertNil(tickets.ticket(String(repeating: "0", count: 64)), "unknown")
        XCTAssertFalse(SSHAskpass.isTicket("ABCDEF" + String(repeating: "0", count: 58)))
        XCTAssertFalse(SSHAskpass.isTicket(String(repeating: "0", count: 63)))
        tickets.update(a) { $0.note(answered: "Verification code:"); $0.released.insert("box") }
        XCTAssertEqual(tickets.ticket(a)?.answered, ["Verification code:"])
        XCTAssertEqual(tickets.ticket(a)?.released, ["box"])
        XCTAssertEqual(tickets.ticket(b), SSHTickets.Ticket(host: "box"), "each connection has its own")
        tickets.forget(host: "box")
        XCTAssertNil(tickets.ticket(a))
    }

    func testATicketExpires() async {
        let clock = TestClock()
        let tickets = SSHTickets(clock: clock)
        let t = tickets.issue(for: "box")
        await clock.sleep(seconds: SSHTickets.lifetime - 1)
        XCTAssertNotNil(tickets.ticket(t))
        await clock.sleep(seconds: 2)
        XCTAssertNil(tickets.ticket(t))
    }

    func testOnlySoManyTicketsLive() {
        let tickets = SSHTickets(clock: TestClock())
        let first = tickets.issue(for: "box")
        var last = first
        for _ in 0..<SSHTickets.maxLive { last = tickets.issue(for: "box") }
        XCTAssertNil(tickets.ticket(first), "the oldest goes")
        XCTAssertNotNil(tickets.ticket(last))
    }

    // MARK: Waiting questions

    private func request(_ kind: SSHAskpass.Kind = .secret) -> SSHPromptRequest {
        SSHPromptRequest(id: UUID(), host: "box", kind: kind, prompt: "dev@example.com's password:", canRemember: true,
                         retry: false, asked: Date(timeIntervalSince1970: 1_000_000))
    }

    func testAQuestionWaitsForItsAnswer() async {
        let prompts = SSHPrompts(clock: SystemClock(), timeout: 60)
        var seen: [[SSHPromptRequest]] = []
        var asked = 0
        prompts.onChange = { seen.append($0) }
        prompts.onAsk = { asked += 1 }
        let r = request()
        let waiting = Task { @MainActor in await prompts.ask(r) }
        let listed = await eventually { prompts.pending.count == 1 }
        XCTAssertTrue(listed)
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(prompts.answer(r.id, "pw", remember: true))
        let got = await waiting.value
        XCTAssertEqual(got.answer, "pw")
        XCTAssertTrue(got.remember)
        XCTAssertEqual(seen, [[r], []])
        XCTAssertFalse(prompts.answer(r.id, "again", remember: false), "answered once")
    }

    func testAnUnansweredQuestionEndsByItself() async {
        let prompts = SSHPrompts(clock: TestClock())
        let got = await prompts.ask(request())
        XCTAssertNil(got.answer)
        XCTAssertFalse(got.remember)
        XCTAssertEqual(prompts.pending, [])
    }

    func testOnlySoManyQuestionsWait() async {
        let prompts = SSHPrompts(clock: SystemClock(), timeout: 60)
        let waiting = (0..<SSHPrompts.maxPending).map { _ in Task { @MainActor in await prompts.ask(self.request()) } }
        let full = await eventually { prompts.pending.count == SSHPrompts.maxPending }
        XCTAssertTrue(full)
        let refused = await prompts.ask(request())
        XCTAssertNil(refused.answer, "one more is not asked")
        XCTAssertEqual(prompts.pending.count, SSHPrompts.maxPending)
        for r in prompts.pending { prompts.answer(r.id, nil, remember: false) }
        for task in waiting { _ = await task.value }
    }
}
