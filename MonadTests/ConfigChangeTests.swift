//
//  ConfigChangeTests.swift — what editing a VM's settings means while it
//  runs: applied live, applied at the next boot, or not changeable at all.
//

import XCTest
@testable import Monad

final class ConfigChangeTests: XCTestCase {
    private let base: InstanceConfig = {
        var c = InstanceConfig.defaults(name: "dev")
        c.distro = "ubuntu"
        c.release = "noble"
        c.image = "Ubuntu 24.04"
        return c
    }()

    private func edited(_ edit: (inout InstanceConfig) -> Void) -> InstanceConfig {
        var c = base
        edit(&c)
        return c
    }

    /// The debug log names what an edit changed.
    func testEveryChangeIsNamed() {
        let new = edited {
            $0.cpus += 1
            $0.firewall.allowLAN.toggle()
            $0.sharing.shares = [SharedFolder(hostPath: "/a", guestPath: "/mnt/a", readOnly: true)]
            $0.forwards = [ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)]
            $0.memoryTargetGiB = 1
            $0.theme = "Ocean"
        }
        XCTAssertEqual(ConfigChange.all(from: base, to: new),
                       ["CPUs", "memory target", "firewall", "shared folders", "forwards", "theme"])
        XCTAssertEqual(ConfigChange.all(from: base, to: base), [])
    }

    func testLiveSettingsNeedNoRestart() {
        let new = edited {
            $0.forwards = [ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)]
            $0.autoForward.enabled = false
            $0.memoryTargetGiB = 1
            $0.theme = "Ocean"
            $0.profiles = ["agentic"]
            $0.startAtLaunch = true
            $0.inlineImages = true
        }
        XCTAssertEqual(ConfigChange.restartOnly(from: base, to: new), [])
        XCTAssertTrue(ConfigChange.all(from: base, to: new).contains("start at boot"))
        XCTAssertTrue(ConfigChange.all(from: base, to: new).contains("inline images"))
        XCTAssertEqual(ConfigChange.fixed(from: base, to: new), [])
    }

    func testHardwareChangesWaitForTheNextBoot() {
        let new = edited {
            $0.cpus += 1
            $0.memoryGiB += 1
            $0.networks = []
            $0.sharing.runtimeEnabled.toggle()
        }
        XCTAssertEqual(ConfigChange.restartOnly(from: base, to: new), ["CPUs", "memory", "network", "folder sharing"])
    }

    func testSharesAreLiveOnceTheSharingDeviceExists() {
        var shared = base
        shared.sharing.runtimeEnabled = true
        var new = shared
        new.sharing.shares = [SharedFolder(hostPath: "/Users/x/src", guestPath: "/mnt/src", readOnly: true)]
        XCTAssertEqual(ConfigChange.restartOnly(from: shared, to: new), [])
        XCTAssertEqual(ConfigChange.restartOnly(from: base, to: new), ["folder sharing"])
    }

    func testProvisionedSettingsAreFixed() {
        let new = edited {
            $0.distro = "debian"
            $0.release = "trixie"
            $0.image = "other"
            $0.user = "root"
            $0.diskGiB += 10
            $0.attached = AttachedDisk(lima: "default", dir: "/Users/dev/.lima/default")
            $0.copiedFrom = AttachedDisk(lima: "default", dir: "/Users/dev/.lima/default")
            $0.ephemeral.toggle()
        }
        XCTAssertEqual(ConfigChange.fixed(from: base, to: new),
                       ["distribution", "release", "base image", "user", "disk size", "Lima VM", "copied from Lima", "ephemeral"])
    }
}
