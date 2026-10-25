//
//  HostProtocolTests.swift — the wire format between Monad.app and MonadHost.
//  Both sides may be different builds (an updated app talking to a host that
//  is still running), so the JSON is pinned byte for byte.
//

import XCTest
@testable import Monad

final class HostProtocolTests: XCTestCase {
    private let config = InstanceConfig(
        name: "dev", distro: "ubuntu", image: "Ubuntu 26.04", user: "dev", cpus: 2, memoryGiB: 4,
        memoryTargetGiB: nil, diskGiB: 20,
        networks: [NetworkAttachment(network: "nat", macAddress: "52:54:00:00:00:01")],
        sharing: SharingSettings(), forwards: [],
        autoForward: AutoForwardSettings(), profiles: [], theme: nil, ephemeral: false,
        createdAt: Date(timeIntervalSince1970: 1_790_000_000))

    private let configJSON = #"{"autoForward":{"enabled":true,"ignoredPorts":[],"minimumPort":1024},"cpus":2,"createdAt":"2026-09-21T14:13:20Z","diskGiB":20,"distro":"ubuntu","ephemeral":false,"forwards":[],"image":"Ubuntu 26.04","memoryGiB":4,"name":"dev","networks":[{"macAddress":"52:54:00:00:00:01","network":"nat"}],"profiles":[],"sharing":{"runtimeEnabled":false,"shares":[]},"user":"dev","version":2}"#

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try HostProtocol.encode(value), as: UTF8.self)
    }

    private func assertGolden<T: Codable & Equatable>(_ value: T, _ expected: String,
                                                      file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try json(value), expected, file: file, line: line)
        XCTAssertEqual(try HostProtocol.decode(T.self, from: Data(expected.utf8)), value, file: file, line: line)
    }

    // MARK: Golden JSON

    func testRequests() throws {
        try assertGolden(HostRequest(id: 1, op: .hello, version: 1), #"{"id":1,"op":"hello","version":1}"#)
        try assertGolden(HostRequest(id: 2, op: .list), #"{"id":2,"op":"list"}"#)
        try assertGolden(HostRequest(id: 3, op: .start, name: "default"), #"{"id":3,"name":"default","op":"start"}"#)
        try assertGolden(HostRequest(id: 4, op: .stop, name: "dev", force: true),
                         #"{"force":true,"id":4,"name":"dev","op":"stop"}"#)
        try assertGolden(HostRequest(id: 5, op: .attach, name: "dev"), #"{"id":5,"name":"dev","op":"attach"}"#)
        try assertGolden(HostRequest(id: 6, op: .detach, name: "dev"), #"{"id":6,"name":"dev","op":"detach"}"#)
        try assertGolden(HostRequest(id: 7, op: .delete, name: "dev"), #"{"id":7,"name":"dev","op":"delete"}"#)
        try assertGolden(HostRequest(id: 8, op: .ensureDefault), #"{"id":8,"op":"ensureDefault"}"#)
        try assertGolden(HostRequest(id: 9, op: .createEphemeral), #"{"id":9,"op":"createEphemeral"}"#)
        try assertGolden(HostRequest(id: 10, op: .create, config: config), #"{"config":\#(configJSON),"id":10,"op":"create"}"#)
        try assertGolden(HostRequest(id: 11, op: .update, config: config), #"{"config":\#(configJSON),"id":11,"op":"update"}"#)
        try assertGolden(HostRequest(id: 12, op: .stopAll), #"{"id":12,"op":"stopAll"}"#)
        try assertGolden(HostRequest(id: 13, op: .restart, name: "dev"), #"{"id":13,"name":"dev","op":"restart"}"#)
        try assertGolden(HostRequest(id: 14, op: .connections, name: "dev"), #"{"id":14,"name":"dev","op":"connections"}"#)
    }

    /// A VM's connection log (Phase 13).
    func testConnections() throws {
        let c = NetConnection(proto: .tcp, address: "140.82.112.3", port: 443, verdict: .allowed, reason: .rule, rule: 2,
                              opened: 7, refused: 1, asked: 0, active: 2, bytesOut: 1234, bytesIn: 56789, firstSeen: 120,
                              lastSeen: 60, name: "github.com")
        let cJSON = #"{"active":2,"address":"140.82.112.3","asked":0,"bytesIn":56789,"bytesOut":1234,"firstSeen":120,"lastSeen":60,"name":"github.com","opened":7,"port":443,"proto":"tcp","reason":"rule","refused":1,"rule":2,"verdict":"allowed"}"#
        try assertGolden(c, cJSON)
        let d = NetConnection(proto: .udp, address: "9.9.9.9", port: 53, verdict: .denied, reason: .byDefault, rule: nil,
                              opened: 0, refused: 1, asked: 0, active: 0, bytesOut: 0, bytesIn: 0, firstSeen: 5, lastSeen: 5,
                              name: nil)
        let dJSON = #"{"active":0,"address":"9.9.9.9","asked":0,"bytesIn":0,"bytesOut":0,"firstSeen":5,"lastSeen":5,"opened":0,"port":53,"proto":"udp","reason":"default","refused":1,"verdict":"denied"}"#
        try assertGolden(d, dJSON)
        var r = HostResponse(id: 9)
        r.connections = [c, d]
        try assertGolden(r, #"{"connections":[\#(cJSON),\#(dJSON)],"id":9,"ok":true}"#)
        XCTAssertNoThrow(try HostRequest(id: 1, op: .connections, name: "dev").validate())
        XCTAssertThrowsError(try HostRequest(id: 1, op: .connections).validate())
        XCTAssertThrowsError(try HostRequest(id: 1, op: .connections, name: "../x").validate())
    }

    /// The VMs' order (the top one is the default VM): set with reorder,
    /// sent with the list and to every app when it changes.
    func testTheVMOrder() throws {
        try assertGolden(HostRequest(id: 15, op: .reorder, names: ["web", "default"]),
                         #"{"id":15,"names":["web","default"],"op":"reorder"}"#)
        var r = HostResponse(id: 2, instances: [])
        r.order = ["web", "default"]
        try assertGolden(r, #"{"id":2,"instances":[],"ok":true,"order":["web","default"]}"#)
        try assertGolden(HostEvent.order(["web", "default"]), #"{"event":"order","names":["web","default"]}"#)
        XCTAssertNoThrow(try HostRequest(id: 1, op: .reorder, names: ["web"]).validate())
        XCTAssertThrowsError(try HostRequest(id: 1, op: .reorder).validate())
        XCTAssertThrowsError(try HostRequest(id: 1, op: .reorder, names: []).validate())
        XCTAssertThrowsError(try HostRequest(id: 1, op: .reorder, names: ["web", "../x"]).validate())
        XCTAssertThrowsError(try HostRequest(id: 1, op: .reorder,
                                             names: (0...VMOrder.maxVMs).map { "vm\($0)" }).validate())
    }

    func testTraffic() throws {
        let t = VMTraffic(network: "lab", from: "a", to: "b", frames: 12, bytes: 720, lastSeen: 5)
        let tJSON = #"{"bytes":720,"frames":12,"from":"a","lastSeen":5,"network":"lab","to":"b"}"#
        try assertGolden(t, tJSON)
        var r = HostResponse(id: 9)
        r.traffic = [t]
        try assertGolden(r, #"{"id":9,"ok":true,"traffic":[\#(tJSON)]}"#)
        XCTAssertNoThrow(try HostRequest(id: 1, op: .traffic).validate())
    }

    func testResponses() throws {
        try assertGolden(HostResponse(id: 1, version: 1), #"{"id":1,"ok":true,"version":1}"#)
        try assertGolden(HostResponse(id: 3, error: "No VM named x."), #"{"error":"No VM named x.","id":3,"ok":false}"#)
        let snap = VMSnapshot(name: "dev", config: config, state: .ready, agent: true,
                              ports: [ListeningPort(address: "0.0.0.0", port: 8000)], sessions: 1)
        let snapJSON = #"{"agent":true,"config":\#(configJSON),"name":"dev","ports":[{"address":"0.0.0.0","port":8000}],"sessions":1,"state":{"phase":"ready"}}"#
        try assertGolden(snap, snapJSON)
        try assertGolden(HostResponse(id: 2, instances: [snap]), #"{"id":2,"instances":[\#(snapJSON)],"ok":true}"#)
        try assertGolden(HostResponse(id: 8, instance: snap), #"{"id":8,"instance":\#(snapJSON),"ok":true}"#)
    }

    func testSnapshotWithForwards() throws {
        var snap = VMSnapshot(name: "dev", config: config, state: .ready, agent: true, ports: [], sessions: 0)
        snap.forwards = [
            ForwardStatus(flag: "-L", spec: "127.0.0.1:8000:127.0.0.1:8000", origin: .auto, state: .active),
            ForwardStatus(flag: "-D", spec: "127.0.0.1:1080", origin: .configured, state: .failed("Port forwarding failed.")),
        ]
        try assertGolden(snap, #"{"agent":true,"config":\#(configJSON),"forwards":[{"flag":"-L","origin":"auto","spec":"127.0.0.1:8000:127.0.0.1:8000","state":{"state":"active"}},{"flag":"-D","origin":"configured","spec":"127.0.0.1:1080","state":{"reason":"Port forwarding failed.","state":"failed"}}],"name":"dev","ports":[],"sessions":0,"state":{"phase":"ready"}}"#)
    }

    func testSnapshotWithPortsOverTheLimit() throws {
        var snap = VMSnapshot(name: "dev", config: config, state: .ready, agent: true, ports: [], sessions: 0)
        snap.portsOverLimit = 8
        try assertGolden(snap, #"{"agent":true,"config":\#(configJSON),"name":"dev","ports":[],"portsOverLimit":8,"sessions":0,"state":{"phase":"ready"}}"#)
    }

    func testSnapshotWithPendingRestart() throws {
        var snap = VMSnapshot(name: "dev", config: config, state: .ready, agent: false, ports: [], sessions: 1)
        snap.pendingRestart = ["CPUs", "memory"]
        try assertGolden(snap, #"{"agent":false,"config":\#(configJSON),"name":"dev","pendingRestart":["CPUs","memory"],"ports":[],"sessions":1,"state":{"phase":"ready"}}"#)
    }

    func testSnapshotWithSharesError() throws {
        var snap = VMSnapshot(name: "dev", config: config, state: .ready, agent: true, ports: [], sessions: 0)
        snap.sharesError = "Could not mount in the guest: /mnt/x."
        try assertGolden(snap, #"{"agent":true,"config":\#(configJSON),"name":"dev","ports":[],"sessions":0,"sharesError":"Could not mount in the guest: /mnt/x.","state":{"phase":"ready"}}"#)
    }

    func testSnapshotWithFirewallQuestions() throws {
        var snap = VMSnapshot(name: "dev", config: config, state: .ready, agent: true, ports: [], sessions: 0)
        snap.firewallAsks = [FirewallAsk(id: 4, proto: .tcp, address: "1.2.3.4", port: 443, names: ["example.com"])]
        try assertGolden(snap, #"{"agent":true,"config":\#(configJSON),"firewallAsks":[{"address":"1.2.3.4","id":4,"names":["example.com"],"port":443,"proto":"tcp"}],"name":"dev","ports":[],"sessions":0,"state":{"phase":"ready"}}"#)
        snap.firewallAsks = [.lookup(id: 5, name: "api.example.com")]
        try assertGolden(snap, #"{"agent":true,"config":\#(configJSON),"firewallAsks":[{"address":"","id":5,"lookup":true,"names":["api.example.com"],"port":53,"proto":"udp"}],"name":"dev","ports":[],"sessions":0,"state":{"phase":"ready"}}"#)
    }

    func testAnswersToFirewallQuestions() throws {
        let answer = FirewallAnswer(askID: 4, decision: .allowUntilStop, target: .name("example.com"), scope: .tag("Web"))
        let r = HostRequest(id: 3, op: .answerFirewall, name: "dev", firewallAnswer: answer)
        XCTAssertNoThrow(try r.validate())
        let back = try HostProtocol.decode(HostRequest.self, from: try HostProtocol.encode(r))
        XCTAssertEqual(back, r)
        XCTAssertThrowsError(try HostRequest(id: 3, op: .answerFirewall, name: "dev").validate())
        XCTAssertThrowsError(try HostRequest(id: 3, op: .answerFirewall, firewallAnswer: answer).validate())
        var badTag = answer
        badTag.scope = .tag("../x")
        XCTAssertThrowsError(try HostRequest(id: 3, op: .answerFirewall, name: "dev", firewallAnswer: badTag).validate())
        var badName = answer
        badName.target = .name("not a name")
        XCTAssertThrowsError(try HostRequest(id: 3, op: .answerFirewall, name: "dev", firewallAnswer: badName).validate())
    }

    func testRunningProfiles() throws {
        let r = HostRequest(id: 5, op: .runProfiles, name: "dev", profiles: ["agentic", "server"])
        XCTAssertNoThrow(try r.validate())
        XCTAssertEqual(try HostProtocol.decode(HostRequest.self, from: HostProtocol.encode(r)), r)
        XCTAssertThrowsError(try HostRequest(id: 5, op: .runProfiles, name: "dev").validate())
        XCTAssertThrowsError(try HostRequest(id: 5, op: .runProfiles, name: "dev", profiles: []).validate())
        XCTAssertThrowsError(try HostRequest(id: 5, op: .runProfiles, name: "dev", profiles: ["../x"]).validate())
        XCTAssertThrowsError(try HostRequest(id: 5, op: .runProfiles, profiles: ["agentic"]).validate())
        XCTAssertNoThrow(try HostRequest(id: 6, op: .stopProfiles, name: "dev").validate())
        XCTAssertThrowsError(try HostRequest(id: 6, op: .stopProfiles).validate())
        var snap = VMSnapshot(name: "dev", config: config, state: .ready, agent: true, ports: [], sessions: 0)
        var run = ProfileRun(profile: ProfileConfig(id: "agentic", name: "Agentic", summary: "",
                                                    steps: [.init(id: "node", title: "Node.js LTS", runtime: "nodejs")]))
        run.apply("@@monad step node start")
        snap.profileRuns = [run]
        XCTAssertEqual(try HostProtocol.decode(VMSnapshot.self, from: HostProtocol.encode(snap)), snap)
    }

    func testEvents() throws {
        let snap = VMSnapshot(name: "dev", config: config, state: .stopped, agent: false, ports: [], sessions: 0)
        try assertGolden(HostEvent.instance(snap),
                         #"{"event":"instance","instance":{"agent":false,"config":\#(configJSON),"name":"dev","ports":[],"sessions":0,"state":{"phase":"stopped"}}}"#)
        try assertGolden(HostEvent.removed("tmp-abc123"), #"{"event":"removed","name":"tmp-abc123"}"#)
    }

    /// Canvas notes: asked for, set and removed by the app, pushed to every
    /// app when they change.
    func testCanvasNotes() throws {
        let label = CanvasNote(id: "a1", kind: .label, text: "C2", tint: .red, on: "vm:web")
        try assertGolden(HostEvent.notes([label]),
                         #"{"event":"notes","notes":[{"author":"you","id":"a1","kind":"label","on":"vm:web","text":"C2","tint":"red"}]}"#)
        var set = HostRequest(id: 3, op: .setNote)
        XCTAssertThrowsError(try set.validate(), "setNote needs a note")
        set.note = label
        XCTAssertNoThrow(try set.validate())
        set.note?.on = "vm:Bad Name"
        XCTAssertThrowsError(try set.validate(), "a note is checked on the way in")
        var remove = HostRequest(id: 4, op: .removeNote)
        remove.noteID = "../x"
        XCTAssertThrowsError(try remove.validate())
        remove.noteID = "a1"
        XCTAssertNoThrow(try remove.validate())
        XCTAssertNoThrow(try HostRequest(id: 5, op: .notes).validate())
        var reply = HostResponse(id: 5)
        reply.notes = [label]
        XCTAssertEqual(try HostProtocol.decode(HostResponse.self, from: HostProtocol.encode(reply)), reply)
    }

    /// A macOS VM's setup question rides in its snapshot; the answer is a
    /// work folder or why not.
    func testTheMacOSSetupQuestion() throws {
        var snap = VMSnapshot(name: "mac", config: config, state: .preparing("Waiting"), agent: false, ports: [], sessions: 0)
        snap.macSetup = MacSetupRequest(disk: "/vms/mac/disk.raw", payload: "/vms/mac/mac-setup")
        XCTAssertEqual(try HostProtocol.decode(VMSnapshot.self, from: HostProtocol.encode(snap)), snap)
        var a = HostRequest(id: 1, op: .answerMacSetup, name: "mac")
        XCTAssertThrowsError(try a.validate(), "an answer says something")
        a.macSetupWork = "/private/tmp/monad-macsetup.AbC123"
        XCTAssertNoThrow(try a.validate())
        a.macSetupError = "no"
        XCTAssertThrowsError(try a.validate(), "one or the other")
        a.macSetupWork = nil
        XCTAssertNoThrow(try a.validate())
    }

    func testTheDefaultVM() throws {
        try assertGolden(HostEvent.defaultVM("db"), #"{"event":"defaultVM","name":"db"}"#)
        XCTAssertThrowsError(try HostRequest(id: 1, op: .setDefault).validate())
        XCTAssertNoThrow(try HostRequest(id: 1, op: .setDefault, name: "db").validate())
    }

    func testBuildIdentityAndShutdown() throws {
        var hello = HostResponse(id: 1, version: 1)
        hello.build = "5F3C1E2A-0000-4000-8000-000000000001"
        try assertGolden(hello, #"{"build":"5F3C1E2A-0000-4000-8000-000000000001","id":1,"ok":true,"version":1}"#)
        try assertGolden(HostRequest(id: 13, op: .shutdown), #"{"id":13,"op":"shutdown"}"#)
        XCTAssertNoThrow(try HostRequest(id: 13, op: .shutdown).validate())
    }

    func testEveryStateHasAStableEncoding() throws {
        try assertGolden(VMState.preparing("Creating disk…"), #"{"detail":"Creating disk…","phase":"preparing"}"#)
        try assertGolden(VMState.stopped, #"{"phase":"stopped"}"#)
        try assertGolden(VMState.starting, #"{"phase":"starting"}"#)
        try assertGolden(VMState.booting, #"{"phase":"booting"}"#)
        try assertGolden(VMState.ready, #"{"phase":"ready"}"#)
        try assertGolden(VMState.stopping, #"{"phase":"stopping"}"#)
        try assertGolden(VMState.failed("boom"), #"{"detail":"boom","phase":"failed"}"#)
    }

    // MARK: Hostile or broken input

    func testOversizedMessagesAreRejectedBeforeParsing() {
        let big = Data(repeating: 0x20, count: HostProtocol.maxMessageBytes + 1)
        XCTAssertThrowsError(try HostProtocol.decode(HostRequest.self, from: big)) { error in
            XCTAssertEqual(error as? HostProtocolError, .tooLarge(HostProtocol.maxMessageBytes + 1))
        }
    }

    func testUnknownValuesAreRejected() {
        for bad in [#"{"id":1,"op":"format-disk"}"#, #"{"id":1}"#, #"{"op":"list"}"#, "[]", "",
                    #"{"event":"exploded"}"#, #"{"phase":"melting"}"#] {
            XCTAssertThrowsError(try HostProtocol.decode(HostRequest.self, from: Data(bad.utf8)), bad)
        }
        XCTAssertThrowsError(try HostProtocol.decode(HostEvent.self, from: Data(#"{"event":"exploded"}"#.utf8)))
        XCTAssertThrowsError(try HostProtocol.decode(VMState.self, from: Data(#"{"phase":"melting"}"#.utf8)))
        XCTAssertThrowsError(try HostProtocol.decode(HostEvent.self, from: Data(#"{"event":"removed"}"#.utf8)),
                             "removed needs a name")
    }

    func testRequestValidation() {
        func invalid(_ r: HostRequest, _ line: UInt = #line) {
            XCTAssertThrowsError(try r.validate(), line: line) { error in
                guard case .invalid = error as? HostProtocolError else {
                    return XCTFail("expected .invalid, got \(error)", line: line)
                }
            }
        }
        invalid(HostRequest(id: 1, op: .hello))
        invalid(HostRequest(id: 1, op: .start))
        invalid(HostRequest(id: 1, op: .start, name: "../etc"))
        invalid(HostRequest(id: 1, op: .restart))
        invalid(HostRequest(id: 1, op: .delete, name: "Bad Name"))
        invalid(HostRequest(id: 1, op: .create))
        invalid(HostRequest(id: 1, op: .update))
        var bad = config
        bad.name = "../../x"
        invalid(HostRequest(id: 1, op: .create, config: bad))
        invalid(HostRequest(id: 1, op: .clone, config: config))
        invalid(HostRequest(id: 1, op: .clone, name: "../etc", config: config))
        invalid(HostRequest(id: 1, op: .clone, name: "dev", config: bad))
        invalid(HostRequest(id: 1, op: .repairDisk))
        invalid(HostRequest(id: 1, op: .repairDisk, name: "../etc"))

        XCTAssertNoThrow(try HostRequest(id: 1, op: .hello, version: 1).validate())
        XCTAssertNoThrow(try HostRequest(id: 1, op: .list).validate())
        XCTAssertNoThrow(try HostRequest(id: 1, op: .stop, name: "dev").validate())
        XCTAssertNoThrow(try HostRequest(id: 1, op: .create, config: config).validate())
        XCTAssertNoThrow(try HostRequest(id: 1, op: .clone, name: "dev", config: config).validate())
        XCTAssertNoThrow(try HostRequest(id: 1, op: .repairDisk, name: "dev").validate())
    }

    func testStopDefaultsToGraceful() {
        XCTAssertFalse(HostRequest(id: 1, op: .stop, name: "dev").isForced)
        XCTAssertTrue(HostRequest(id: 1, op: .stop, name: "dev", force: true).isForced)
    }
}
