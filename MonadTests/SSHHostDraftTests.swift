//
//  SSHHostDraftTests.swift — the New SSH Host sheet's fields: what they
//  make of what was typed, what they refuse, and how a host's row reads.
//

import XCTest
@testable import Monad

final class SSHHostDraftTests: XCTestCase {
    private func message(_ body: () throws -> SSHHost) -> String? {
        do {
            _ = try body()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func testANewHostStartsWithThisMacsUserAndPort22() throws {
        var draft = SSHHostDraft(nil, user: "dev")
        XCTAssertTrue(draft.isNew)
        XCTAssertEqual(draft.user, "dev")
        XCTAssertEqual(draft.auth, .password)
        draft.name = " box "
        draft.host = " example.com "
        XCTAssertEqual(try draft.build(), SSHHost(name: "box", host: "example.com", user: "dev", auth: .password),
                       "an empty port is 22, and spaces around a field are not part of it")
        draft.port = "2222"
        XCTAssertEqual(try draft.build().port, 2222)
    }

    func testWhatWasTypedIsChecked() {
        var draft = SSHHostDraft(nil, user: "dev")
        draft.name = "box"
        draft.host = "example.com"
        draft.port = "ssh"
        XCTAssertEqual(message { try draft.build() }, "“ssh” is not a port number.")
        draft.port = "70000"
        XCTAssertEqual(message { try draft.build() }, "70000 is not a valid port (1–65535).")
        draft.port = ""
        draft.host = "example.com -oProxyCommand=x"
        XCTAssertEqual(message { try draft.build() }, "“example.com -oProxyCommand=x” is not a host name or address.")
        draft.host = "example.com"
        draft.user = ""
        XCTAssertEqual(message { try draft.build() }, "“” is not a user name: letters, digits, . _ @ and -, up to 64.")
        draft.user = "dev"
        XCTAssertEqual(message { try draft.build(taken: ["Box", "other"]) }, "An SSH host named Box exists already.")
        XCTAssertNil(message { try draft.build(taken: ["other"]) })
    }

    func testAKeyFileIsGivenByItsFullPath() throws {
        var draft = SSHHostDraft(nil, user: "dev")
        draft.name = "box"
        draft.host = "example.com"
        draft.auth = .key
        XCTAssertNil(try draft.build().keyPath, "ssh's own keys and agent")
        draft.usesKeyFile = true
        XCTAssertEqual(message { try draft.build() }, "Choose a key file, or use ssh's own keys and agent.")
        draft.keyPath = "~/.ssh/id_work"
        XCTAssertEqual(try draft.build(home: "/Users/dev").keyPath, "/Users/dev/.ssh/id_work")
        draft.keyPath = "keys/id_work"
        XCTAssertEqual(message { try draft.build() }, "A key file is given by its full path.")
        // A path left in the field does not follow another way of signing in.
        draft.keyPath = "/Users/dev/.ssh/id_work"
        draft.auth = .generated
        XCTAssertNil(try draft.build().keyPath)
        draft.auth = .key
        draft.usesKeyFile = false
        XCTAssertNil(try draft.build().keyPath)
    }

    func testAHostBeingChangedFillsTheFieldsAndKeepsItsName() throws {
        var host = SSHHost(name: "box", host: "192.0.2.7", port: 2222, user: "ops", auth: .key)
        host.keyPath = "/Users/dev/.ssh/id_work"
        host.jump = "bastion"
        let draft = SSHHostDraft(host)
        XCTAssertFalse(draft.isNew)
        XCTAssertEqual(draft.port, "2222")
        XCTAssertTrue(draft.usesKeyFile)
        XCTAssertEqual(try draft.build(taken: ["box", "bastion"]), host, "its own name is not in its way")
        XCTAssertEqual(SSHHostDraft(SSHHost(name: "b", host: "example.com", user: "dev", auth: .password)).port, "")
    }

    func testARowSaysWhereAndHowTheHostSignsIn() {
        var host = SSHHost(name: "box", host: "example.com", user: "dev", auth: .password)
        XCTAssertEqual(SSHHostDraft.summary(SSHHostSnapshot(config: host, hasPassword: false)), "dev@example.com")
        XCTAssertEqual(SSHHostDraft.signIn(SSHHostSnapshot(config: host, hasPassword: false)), "Password asked each time")
        XCTAssertEqual(SSHHostDraft.signIn(SSHHostSnapshot(config: host, hasPassword: true)), "Password in Keychain")
        host.port = 2222
        host.jump = "bastion"
        host.auth = .generated
        XCTAssertEqual(SSHHostDraft.summary(SSHHostSnapshot(config: host, hasPassword: false)),
                       "dev@example.com:2222 through bastion")
        XCTAssertEqual(SSHHostDraft.signIn(SSHHostSnapshot(config: host, hasPassword: false)), "Monad's key, not installed yet")
        host.keyInstalled = true
        XCTAssertEqual(SSHHostDraft.signIn(SSHHostSnapshot(config: host, hasPassword: false)), "Monad's key")
        host.host = "2001:db8::1"
        host.jump = nil
        XCTAssertEqual(SSHHostDraft.summary(SSHHostSnapshot(config: host, hasPassword: false)), "dev@[2001:db8::1]:2222")
        host.auth = .key
        XCTAssertEqual(SSHHostDraft.signIn(SSHHostSnapshot(config: host, hasPassword: false)), "Private key")

        let forwards = [
            ForwardStatus(flag: "-L", spec: "/vms/web/sshfwd-aaaaaaaa.sock:127.0.0.1:5432", origin: .bridge, state: .active),
            ForwardStatus(flag: "-R", spec: "127.0.0.1:8080:/vms/web/sshfwd-bbbbbbbb.sock", origin: .bridge,
                          state: .failed("remote port forwarding failed")),
        ]
        XCTAssertEqual(SSHHostDraft.failedForwards(SSHHostSnapshot(config: host, hasPassword: false, forwards: forwards)), 1)
        XCTAssertEqual(SSHHostDraft.failedForwards(SSHHostSnapshot(config: host, hasPassword: false)), 0)
    }
}
