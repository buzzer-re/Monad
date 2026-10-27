//
//  ConfigV2Tests.swift — instance.json v2: schema, migration from v1 and
//  validation with precise errors.
//

import XCTest
@testable import Monad

final class ConfigV2Tests: XCTestCase {
    private func decode(_ json: String) throws -> InstanceConfig {
        try InstanceConfig.decode(Data(json.utf8))
    }

    private func valid() -> InstanceConfig {
        var c = InstanceConfig.defaults(name: "unit")
        c.cpus = 2
        c.memoryGiB = 4
        c.diskGiB = 20
        return c
    }

    private func assertInvalid(_ c: InstanceConfig, _ expected: InstanceConfig.ValidationError,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try c.validate(maxCPUs: 8, maxMemoryGiB: 16), file: file, line: line) { error in
            XCTAssertEqual(error as? InstanceConfig.ValidationError, expected, file: file, line: line)
        }
    }

    // MARK: Migration from v1

    let v1JSON = """
    {
      "name" : "default", "cpus" : 4, "memoryGiB" : 6, "diskGiB" : 50,
      "network" : true, "macAddress" : "52:54:00:aa:bb:cc",
      "ephemeral" : false, "sharedDirectory" : "/Users/dev/src", "sharedReadOnly" : false,
      "user" : "dev", "image" : "Ubuntu 26.04", "createdAt" : "2026-09-28T10:00:00Z"
    }
    """

    func testV1MigratesWithSameValues() throws {
        let c = try decode(v1JSON)
        XCTAssertEqual(c.version, InstanceConfig.currentVersion)
        XCTAssertEqual(c.name, "default")
        XCTAssertEqual(c.cpus, 4)
        XCTAssertEqual(c.memoryGiB, 6)
        XCTAssertNil(c.memoryTargetGiB)
        XCTAssertEqual(c.diskGiB, 50)
        XCTAssertEqual(c.user, "dev")
        XCTAssertEqual(c.image, "Ubuntu 26.04")
        XCTAssertEqual(c.distro, "ubuntu", "v1 only knew Ubuntu")
        XCTAssertEqual(c.networks, [NetworkAttachment(network: NetworkAttachment.defaultNAT, macAddress: "52:54:00:aa:bb:cc")])
        XCTAssertEqual(c.primaryMACAddress, "52:54:00:aa:bb:cc")
        XCTAssertTrue(c.sharing.runtimeEnabled, "a v1 shared folder keeps working")
        XCTAssertEqual(c.sharing.shares, [SharedFolder(hostPath: "/Users/dev/src", guestPath: "/mnt/host", readOnly: false)])
        XCTAssertTrue(c.forwards.isEmpty)
        XCTAssertEqual(c.autoForward, AutoForwardSettings())
        XCTAssertTrue(c.profiles.isEmpty)
        XCTAssertNil(c.theme)
    }

    func testV1WithoutNetworkOrShareMigratesToOfflineAndNoSharing() throws {
        let json = v1JSON.replacingOccurrences(of: "\"network\" : true", with: "\"network\" : false")
            .replacingOccurrences(of: "\"sharedDirectory\" : \"/Users/dev/src\", ", with: "")
        let c = try decode(json)
        XCTAssertTrue(c.networks.isEmpty, "network off means no NIC at all")
        XCTAssertNil(c.primaryMACAddress)
        XCTAssertFalse(c.sharing.runtimeEnabled)
        XCTAssertTrue(c.sharing.shares.isEmpty)
    }

    func testMigratedConfigIsWrittenAsV2() throws {
        let c = try decode(v1JSON)
        let data = try c.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertNil(object["network"], "v1 keys are not written back")
        XCTAssertNil(object["sharedDirectory"])
        XCTAssertEqual(try InstanceConfig.decode(data), c)
    }

    func testUnknownFutureVersionIsRejected() {
        XCTAssertThrowsError(try decode(#"{"version": 99, "name": "x"}"#)) { error in
            XCTAssertEqual(error as? InstanceConfig.DecodingProblem, .unsupportedVersion(99))
        }
    }

    // MARK: v2 round trip and defaults

    func testV2RoundTripKeepsEverything() throws {
        var c = valid()
        c.memoryTargetGiB = 3
        c.distro = "debian"
        c.networks = [NetworkAttachment(network: "nat", macAddress: "52:54:00:00:00:01"),
                      NetworkAttachment(network: "lab", macAddress: nil)]
        c.sharing = SharingSettings(runtimeEnabled: true,
                                    shares: [SharedFolder(hostPath: "/Users/dev/src", guestPath: "/home/dev/src", readOnly: true)])
        c.forwards = [ForwardRule(kind: .local, hostPort: 8080, guestPort: 80),
                      ForwardRule(kind: .unixLocal, hostSocket: "/Users/dev/.monad/docker.sock",
                                  guestSocket: "/run/docker.sock")]
        c.autoForward = AutoForwardSettings(enabled: false, ignoredPorts: [5432])
        c.profiles = ["agentic"]
        c.theme = "Pro"
        XCTAssertEqual(try InstanceConfig.decode(c.encoded()), c)
    }

    /// "Start VM at boot": off by default, and written only when on, so
    /// existing instance.json files stay as they are.
    func testStartAtLaunchIsKeptAndOffByDefault() throws {
        var c = valid()
        XCTAssertFalse(c.startAtLaunch)
        XCTAssertFalse(String(decoding: try c.encoded(), as: UTF8.self).contains("startAtLaunch"))
        c.startAtLaunch = true
        XCTAssertTrue(String(decoding: try c.encoded(), as: UTF8.self).contains("\"startAtLaunch\" : true"))
        XCTAssertTrue(try InstanceConfig.decode(c.encoded()).startAtLaunch)
    }

    /// Images in the terminal: off by default (Monad then never decodes what
    /// the VM sends), written only when on.
    func testInlineImagesAreOffUnlessChosen() throws {
        var c = valid()
        XCTAssertFalse(c.inlineImages)
        XCTAssertFalse(String(decoding: try c.encoded(), as: UTF8.self).contains("inlineImages"))
        c.inlineImages = true
        XCTAssertTrue(String(decoding: try c.encoded(), as: UTF8.self).contains("\"inlineImages\" : true"))
        XCTAssertTrue(try InstanceConfig.decode(c.encoded()).inlineImages)
    }

    /// Every string field has a rule (F-08): `user` and the rest reach
    /// ssh_config, cloud-init and scripts, where a newline adds lines.
    func testEveryFieldIsValidated() {
        let cases: [(InstanceConfig.ValidationError, (inout InstanceConfig) -> Void)] = [
            (.user("a\n  ProxyCommand x"), { $0.user = "a\n  ProxyCommand x" }),
            (.user("Dev"), { $0.user = "Dev" }),
            (.user(""), { $0.user = "" }),
            (.user("root"), { $0.user = "root" }),
            (.distro("ubuntu\nx"), { $0.distro = "ubuntu\nx" }),
            (.release("noble x"), { $0.release = "noble x" }),
            (.image("a\nb"), { $0.image = "a\nb" }),
            (.network("bad name"), { $0.networks = [NetworkAttachment(network: "bad name", macAddress: nil)] }),
            (.macAddress("zz:00:00:00:00:00"), { $0.networks = [NetworkAttachment(network: "default", macAddress: "zz:00:00:00:00:00")] }),
            (.shareHostPath("/a\nb"), {
                $0.sharing = SharingSettings(runtimeEnabled: true,
                                             shares: [SharedFolder(hostPath: "/a\nb", guestPath: "/mnt/a", readOnly: true)])
            }),
            (.socketPath("/tmp/a\u{7}b"), {
                $0.forwards = [ForwardRule(kind: .unixLocal, hostSocket: "/tmp/a\u{7}b", guestSocket: "/run/x.sock")]
            }),
            (.profile("../x"), { $0.profiles = ["../x"] }),
        ]
        for (expected, edit) in cases {
            var c = valid()
            edit(&c)
            assertInvalid(c, expected)
        }
        var ok = valid()
        ok.user = "dev_1-a"
        ok.release = "24.04"
        ok.image = "Ubuntu 24.04 LTS (Noble Numbat)"
        ok.networks = [NetworkAttachment(network: NetworkDefinition.appleNATName, macAddress: "52:54:00:AB:cd:01")]
        ok.profiles = ["agentic"]
        XCTAssertNoThrow(try ok.validate(maxCPUs: 8, maxMemoryGiB: 16))
    }

    func testDefaultsAreSecure() {
        let c = InstanceConfig.defaults(name: "unit")
        XCTAssertEqual(c.version, 2)
        XCTAssertEqual(c.networks.map(\.network), [NetworkDefinition.defaultName], "new VMs join Monad's default network")
        XCTAssertFalse(c.networks[0].isAppleNAT)
        XCTAssertFalse(c.sharing.runtimeEnabled, "no filesystem device unless asked for")
        XCTAssertTrue(c.sharing.shares.isEmpty)
        XCTAssertTrue(c.forwards.isEmpty)
        XCTAssertTrue(c.autoForward.enabled, "auto-forwarding is on by default")
        XCTAssertEqual(c.autoForward.minimumPort, 1024)
    }

    func testForwardRuleDefaultsBindLocalhost() {
        let r = ForwardRule(kind: .local, hostPort: 3000, guestPort: 3000)
        XCTAssertEqual(r.hostAddress, "127.0.0.1")
        XCTAssertEqual(r.guestHost, "127.0.0.1")
        XCTAssertTrue(r.enabled)
    }

    // MARK: Validation

    func testValidConfigPasses() {
        XCTAssertNoThrow(try valid().validate(maxCPUs: 8, maxMemoryGiB: 16))
    }

    func testResourceLimits() {
        var c = valid(); c.cpus = 0
        assertInvalid(c, .cpus(0, max: 8))
        c = valid(); c.cpus = 9
        assertInvalid(c, .cpus(9, max: 8))
        c = valid(); c.memoryGiB = 0
        assertInvalid(c, .memory(0, max: 16))
        c = valid(); c.memoryGiB = 17
        assertInvalid(c, .memory(17, max: 16))
        c = valid(); c.memoryTargetGiB = 5
        assertInvalid(c, .memoryTarget(5, max: 4))
        c = valid(); c.diskGiB = 5
        assertInvalid(c, .disk(5))
        c = valid(); c.name = "Bad Name"
        assertInvalid(c, .name("Bad Name"))
    }

    func testShareValidation() {
        var c = valid()
        c.sharing.shares = [SharedFolder(hostPath: "/Users/dev/src", guestPath: "/src", readOnly: true)]
        assertInvalid(c, .sharingDisabled)

        c.sharing.runtimeEnabled = true
        c.sharing.shares = [SharedFolder(hostPath: "relative/src", guestPath: "/src", readOnly: true)]
        assertInvalid(c, .shareHostPath("relative/src"))

        c.sharing.shares = [SharedFolder(hostPath: "/Users/dev/src", guestPath: "src", readOnly: true)]
        assertInvalid(c, .shareGuestPath("src"))

        for reserved in ["/", "/proc/x", "/sys", "/dev/shm", "/etc", "/usr/bin", "/boot", "/run/monad"] {
            c.sharing.shares = [SharedFolder(hostPath: "/Users/dev/src", guestPath: reserved, readOnly: true)]
            assertInvalid(c, .shareGuestPath(reserved))
        }

        c.sharing.shares = [SharedFolder(hostPath: "/a", guestPath: "/mnt/x", readOnly: true),
                            SharedFolder(hostPath: "/b", guestPath: "/mnt/x/", readOnly: true)]
        assertInvalid(c, .duplicateGuestPath("/mnt/x"))

        // One folder per line in the guest's mount list.
        for bad in ["/mnt/a\nb", "/mnt/a\tb"] {
            c.sharing.shares = [SharedFolder(hostPath: "/a", guestPath: bad, readOnly: true)]
            assertInvalid(c, .shareGuestPath(bad))
        }
    }

    func testForwardValidation() {
        var c = valid()
        c.forwards = [ForwardRule(kind: .local, hostPort: 0, guestPort: 80)]
        assertInvalid(c, .port(0))
        c.forwards = [ForwardRule(kind: .local, hostPort: 8080, guestPort: 70000)]
        assertInvalid(c, .port(70000))
        c.forwards = [ForwardRule(kind: .local, hostPort: 80, guestPort: 80)]
        assertInvalid(c, .privilegedHostPort(80))
        c.forwards = [ForwardRule(kind: .local, hostPort: 8080, guestPort: 80),
                      ForwardRule(kind: .socks, hostPort: 8080)]
        assertInvalid(c, .duplicateHostBinding("127.0.0.1:8080"))
        c.forwards = [ForwardRule(kind: .local, hostPort: nil, guestPort: 80)]
        assertInvalid(c, .incompleteForward)
        c.forwards = [ForwardRule(kind: .unixLocal, hostSocket: "rel.sock", guestSocket: "/run/docker.sock")]
        assertInvalid(c, .socketPath("rel.sock"))
        c.forwards = [ForwardRule(kind: .local, hostAddress: "0.0.0.0", hostPort: 8080, guestPort: 80)]
        XCTAssertNoThrow(try c.validate(maxCPUs: 8, maxMemoryGiB: 16), "exposing on all interfaces is allowed explicitly")
        c.forwards = [ForwardRule(kind: .local, hostAddress: "example.com", hostPort: 8080, guestPort: 80)]
        assertInvalid(c, .hostAddress("example.com"))
    }

    /// A VM port or SOCKS proxy on any Mac address but the loopback can be
    /// reached by other computers: that, like a forward into the Mac, is
    /// asked for. Where a forward into the Mac connects, or a socket, is not.
    func testAForwardOpensToTheNetworkBeyondTheLoopback() {
        func local(_ a: String) -> ForwardRule { ForwardRule(kind: .local, hostAddress: a, hostPort: 8080, guestPort: 80) }
        for a in ["127.0.0.1", "127.1.2.3", "::1", "::ffff:127.0.0.1"] {
            XCTAssertFalse(local(a).opensToNetwork, a)
            XCTAssertFalse(local(a).needsConfirmation, a)
        }
        for a in ["0.0.0.0", "192.168.1.20", "::", "fe80::1"] {
            XCTAssertTrue(local(a).opensToNetwork, a)
            XCTAssertTrue(local(a).needsConfirmation, a)
        }
        XCTAssertTrue(ForwardRule(kind: .socks, hostAddress: "0.0.0.0", hostPort: 1080).opensToNetwork)
        XCTAssertFalse(ForwardRule(kind: .remote, hostAddress: "0.0.0.0", hostPort: 80, guestPort: 80).opensToNetwork,
                       "the Mac address a forward into the Mac connects to")
        XCTAssertTrue(ForwardRule(kind: .remote, hostPort: 80, guestPort: 80).needsConfirmation)
        XCTAssertFalse(ForwardRule(kind: .unixLocal, hostSocket: "/tmp/a.sock", guestSocket: "/run/a.sock").needsConfirmation)
    }

    /// A forward into the Mac is the user's own rule, confirmed when it is
    /// added: no separate per-VM switch. Files saved while there was one
    /// still load, with their forwards.
    func testAForwardIntoTheMacIsItsOwnChoice() throws {
        var c = valid()
        c.forwards = [ForwardRule(kind: .remote, hostPort: 5432, guestPort: 15432)]
        XCTAssertNoThrow(try c.validate(maxCPUs: 8, maxMemoryGiB: 16))
        let data = try c.encoded()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("allowRemoteForwards"))
        var old = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        old["allowRemoteForwards"] = true
        XCTAssertEqual(try InstanceConfig.decode(JSONSerialization.data(withJSONObject: old)).forwards, c.forwards)
    }

    /// A Lima VM's disk is used where it is (Phase 9): written only when
    /// set, its size is Lima's, and its folder is checked like any field.
    func testAnAttachedLimaDisk() throws {
        var c = valid()
        let paths = InstancePaths(name: c.name, root: URL(fileURLWithPath: "/tmp/monad"))
        XCTAssertEqual(c.disk(in: paths), paths.disk)
        XCTAssertFalse(String(decoding: try c.encoded(), as: UTF8.self).contains("attached"))
        c.attached = AttachedDisk(lima: "default", dir: "/Users/dev/.lima/default")
        XCTAssertEqual(c.disk(in: paths).path, "/Users/dev/.lima/default/diffdisk")
        XCTAssertEqual(try InstanceConfig.decode(c.encoded()), c)
        c.diskGiB = 5
        XCTAssertNoThrow(try c.validate(maxCPUs: 8, maxMemoryGiB: 16), "the size is Lima's")
        for bad in [AttachedDisk(lima: "../x", dir: "/Users/dev/.lima/../x"),
                    AttachedDisk(lima: "default", dir: "relative/default"),
                    AttachedDisk(lima: "default", dir: "/Users/dev/.lima/other"),
                    AttachedDisk(lima: "default", dir: "/Users/dev/.lima/../default"),
                    AttachedDisk(lima: "a\nb", dir: "/Users/dev/.lima/a\nb"),
                    AttachedDisk(lima: "default", dir: "/Users/dev/.lima/default", home: "home/x"),
                    AttachedDisk(lima: "default", dir: "/Users/dev/.lima/default", home: "/home/../root"),
                    AttachedDisk(lima: "default", dir: "/Users/dev/.lima/default", home: "/home/a\nb")] {
            c.attached = bad
            assertInvalid(c, .attachedDisk(bad.dir))
        }
    }

    /// A copy of a Lima VM boots its own disk, with the user and home Lima made.
    func testACopiedLimaVM() throws {
        var c = valid()
        let paths = InstancePaths(name: c.name, root: URL(fileURLWithPath: "/tmp/monad"))
        XCTAssertFalse(String(decoding: try c.encoded(), as: UTF8.self).contains("copiedFrom"))
        c.copiedFrom = AttachedDisk(lima: "default", dir: "/Users/dev/.lima/default", home: "/home/dev.guest")
        XCTAssertEqual(c.disk(in: paths), paths.disk, "its own disk")
        XCTAssertEqual(c.home, "/home/dev.guest")
        XCTAssertEqual(try InstanceConfig.decode(c.encoded()), c)
        c.diskGiB = 5
        XCTAssertNoThrow(try c.validate(maxCPUs: 8, maxMemoryGiB: 16), "the size is Lima's")
        c.attached = c.copiedFrom
        assertInvalid(c, .attachedDisk("/Users/dev/.lima/default"))
        c.attached = nil
        c.copiedFrom = AttachedDisk(lima: "default", dir: "relative/default")
        assertInvalid(c, .attachedDisk("relative/default"))
    }

    func testAutoForwardMinimumPortCannotBePrivileged() {
        var c = valid()
        c.autoForward.minimumPort = 80
        assertInvalid(c, .autoForwardMinimum(80))
    }

    func testThemeIsAnID() {
        var c = valid()
        c.theme = "../../etc/passwd"
        assertInvalid(c, .theme("../../etc/passwd"))
        c.theme = "red-sands"
        XCTAssertNoThrow(try c.validate(maxCPUs: 8, maxMemoryGiB: 16))
    }
}
