//
//  NewVMFormTests.swift — the distro and release choices of the New VM sheet
//  come from the distro catalog, never from code; the network and firewall
//  a new VM starts with.
//

import XCTest
@testable import Monad

final class NewVMFormTests: XCTestCase {
    private func form() throws -> NewVMForm { NewVMForm(catalog: try DistroCatalog.bundled()) }

    func testChoicesComeFromTheCatalog() throws {
        let f = try form()
        // macOS is listed in a Debug build until Phase 14 is done.
        XCTAssertEqual(Set(f.distros.map(\.id)), ["debian", "fedora", "macos", "opensuse", "ubuntu"])
        XCTAssertEqual(f.distros.map(\.name), f.distros.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertEqual(f.distro, "ubuntu", "Ubuntu stays the default")
        XCTAssertEqual(f.release, "26.04")
        XCTAssertEqual(f.releases.map(\.id), ["26.04", "24.04"])
    }

    func testChangingDistroSelectsItsDefaultRelease() throws {
        var f = try form()
        f.distro = "debian"
        XCTAssertEqual(f.release, "13")
        XCTAssertEqual(f.releases.map(\.id), ["13", "12"])
        f.release = "12"
        f.distro = "opensuse"
        XCTAssertEqual(f.release, "16.0")
    }

    func testVerificationIsExplained() throws {
        var f = try form()
        XCTAssertTrue(f.verification.contains("OpenPGP"), f.verification)
        f.distro = "debian"
        XCTAssertTrue(f.verification.contains("without an OpenPGP signature"), f.verification)
    }

    func testConfigCarriesTheChoice() throws {
        var f = try form()
        f.distro = "fedora"
        var c = f.apply(to: InstanceConfig.defaults(name: "box"))
        XCTAssertEqual(c.distro, "fedora")
        XCTAssertEqual(c.release, "44")
        f.distro = "ubuntu"
        f.release = "24.04"
        c = f.apply(to: c)
        XCTAssertEqual(c.distro, "ubuntu")
        XCTAssertEqual(c.release, "24.04")
    }

    /// Images in the terminal are the user's choice, off by default.
    func testImagesInTheTerminalAreOffUnlessChosen() throws {
        var f = try form()
        XCTAssertFalse(f.inlineImages)
        XCTAssertFalse(f.apply(to: InstanceConfig.defaults(name: "box")).inlineImages)
        f.inlineImages = true
        XCTAssertTrue(f.apply(to: InstanceConfig.defaults(name: "box")).inlineImages)
    }

    func testANewVMJoinsTheDefaultNetworkBehindTheDefaultFirewall() throws {
        let f = try form()
        XCTAssertEqual(f.network, NetworkDefinition.defaultName)
        let c = f.apply(to: InstanceConfig.defaults(name: "box"))
        XCTAssertEqual(c.networks, [NetworkAttachment(network: "default", macAddress: nil)])
        XCTAssertEqual(c.firewall, VMFirewall())
    }

    func testTheNetworkAndFirewallAreChosen() throws {
        var f = try form()
        f.setNetworks([.builtInDefault, NetworkDefinition(name: "lab", kind: .internal, subnet: "10.78.0.0/24")])
        XCTAssertEqual(f.networks.map(\.id), ["default", "lab"])
        f.network = "lab"
        f.firewall.allowLAN = true
        f.firewall.tags = ["web"]
        var c = f.apply(to: InstanceConfig.defaults(name: "box"))
        XCTAssertEqual(c.networks, [NetworkAttachment(network: "lab", macAddress: nil)])
        XCTAssertEqual(c.firewall, VMFirewall(allowLAN: true, tags: ["web"]))
        f.network = nil
        c = f.apply(to: c)
        XCTAssertEqual(c.networks, [], "no network device at all")
        // A network that went away: back to the default one.
        f.network = "lab"
        f.setNetworks([.builtInDefault])
        XCTAssertEqual(f.network, "default")
    }

    func testTheNetworkLineSaysWhatItIs() throws {
        var f = try form()
        f.setNetworks([.builtInDefault, NetworkDefinition(name: "lab", kind: .internal, subnet: "10.78.0.0/24")])
        XCTAssertEqual(f.networks.map(\.name), ["default (NAT, 10.77.0.0/24)", "lab (Internal, 10.78.0.0/24)"])
        XCTAssertTrue(f.firewallApplies)
        f.network = "lab"
        XCTAssertFalse(f.firewallApplies, "nothing leaves an internal network")
        f.network = nil
        XCTAssertFalse(f.firewallApplies)
    }

    private let aptOnly = ProfileConfig(id: "apt-only", name: "Apt Only", summary: "Debian family only.",
                                        steps: [.init(id: "p", title: "P", packages: ["apt": ["git"]])])

    func testProfilesAreChosenForTheDistro() throws {
        var f = try form()
        f.setProfiles(ProfileCatalog(builtIn: try ProfileCatalog.bundled().builtIn, custom: [aptOnly]))
        XCTAssertEqual(f.profileChoices.map(\.id), ["agentic", "server", "apt-only"])
        XCTAssertTrue(f.profileChoices.allSatisfy(\.supported), "Ubuntu uses apt")
        f.toggleProfile("agentic")
        f.toggleProfile("apt-only")
        XCTAssertEqual(f.apply(to: InstanceConfig.defaults(name: "box")).profiles, ["agentic", "apt-only"])
        // On Fedora (dnf) the apt-only profile cannot be set up: not offered, dropped if chosen.
        f.distro = "fedora"
        XCTAssertEqual(f.profileChoices.first { $0.id == "apt-only" }?.supported, false)
        XCTAssertEqual(f.apply(to: InstanceConfig.defaults(name: "box")).profiles, ["agentic"])
        f.toggleProfile("agentic")
        XCTAssertEqual(f.apply(to: InstanceConfig.defaults(name: "box")).profiles, [])
    }

    /// A profile made from the New VM sheet is chosen for the VM once saved.
    func testANewProfileIsChosenOnceSaved() throws {
        var f = try form()
        let builtIn = try ProfileCatalog.bundled().builtIn
        f.setProfiles(ProfileCatalog(builtIn: builtIn, custom: []))
        f.toggleProfile("agentic")
        f.profileCreated("apt-only", catalog: ProfileCatalog(builtIn: builtIn, custom: [aptOnly]))
        XCTAssertTrue(f.isChosen("apt-only"))
        XCTAssertEqual(f.apply(to: InstanceConfig.defaults(name: "box")).profiles, ["agentic", "apt-only"],
                       "the earlier choices stay")
        f.profileCreated("apt-only", catalog: ProfileCatalog(builtIn: builtIn, custom: [aptOnly]))
        XCTAssertEqual(f.apply(to: InstanceConfig.defaults(name: "box")).profiles, ["agentic", "apt-only"], "once")
        f.profileCreated("gone", catalog: ProfileCatalog(builtIn: builtIn, custom: [aptOnly]))
        XCTAssertFalse(f.isChosen("gone"), "only a profile that exists")
    }

    /// macOS has no release to pick but an install image: the latest from
    /// Apple (downloaded once and kept), one kept on this Mac, or an IPSW
    /// file chosen. It needs more room, and has no package manager for
    /// profiles.
    func testMacOSIsInstalledFromTheImageChosen() throws {
        var f = try form()
        let box = InstanceConfig.defaults(name: "mac")
        f.distro = "macos"
        XCTAssertTrue(f.isMac)
        XCTAssertEqual(f.minimumMemoryGiB, InstanceConfig.macMinimumMemoryGiB)
        XCTAssertEqual(f.minimumDiskGiB, InstanceConfig.macMinimumDiskGiB)
        XCTAssertEqual(f.profileChoices, [])
        XCTAssertEqual(f.restoreImages.map(\.name), ["The latest macOS for this Mac (downloaded once, about 25 GB)"])
        XCTAssertNil(f.apply(to: box).restoreImage, "the latest by default")
        let kept = "/cache/macos/UniversalMac_27.0.1_26A434_Restore.ipsw"
        f.setKeptRestoreImages([.init(path: kept, bytes: 25_400_000_000)])
        XCTAssertEqual(f.restoreImages.map(\.name).last, "UniversalMac_27.0.1_26A434_Restore.ipsw (kept on this Mac, 25 GB)")
        f.restoreImage = kept
        XCTAssertEqual(f.apply(to: box).restoreImage, kept)
        f.chooseRestoreImage(path: "/Users/dev/Downloads/macOS 27.ipsw")
        XCTAssertEqual(f.restoreImage, "/Users/dev/Downloads/macOS 27.ipsw")
        XCTAssertEqual(f.restoreImages.map(\.name).last, "macOS 27.ipsw")
        XCTAssertEqual(f.apply(to: box).restoreImage, "/Users/dev/Downloads/macOS 27.ipsw")
        // A kept image that went away: back to the latest.
        f.restoreImage = kept
        f.setKeptRestoreImages([])
        XCTAssertEqual(f.restoreImage, NewVMForm.latestRestoreImage)
        f.distro = "ubuntu"
        XCTAssertFalse(f.isMac)
        XCTAssertEqual(f.minimumMemoryGiB, 1)
        XCTAssertEqual(f.minimumDiskGiB, 10)
        f.restoreImage = kept
        XCTAssertNil(f.apply(to: box).restoreImage, "only macOS takes one")
    }

    /// A Mac VM can be made with SIP off (turned off in recovery at its
    /// first start); only a Mac VM.
    func testSIPCanBeTurnedOffForAMacVM() throws {
        var f = try form()
        let box = InstanceConfig.defaults(name: "mac")
        f.distro = "macos"
        XCTAssertFalse(f.disableSIP)
        XCTAssertTrue(f.apply(to: box).systemIntegrityProtection)
        f.disableSIP = true
        XCTAssertFalse(f.apply(to: box).systemIntegrityProtection)
        // A Mac VM's settings say so, and pass the checks they get when sent.
        var mac = f.apply(to: box)
        mac.memoryGiB = 4
        mac.diskGiB = 64
        mac.restoreImage = "/cache/macos/UniversalMac_27.0.1_26A434_Restore.ipsw"
        XCTAssertEqual(mac.guestOS, .macos)
        XCTAssertNoThrow(try mac.validate(maxCPUs: 8, maxMemoryGiB: 16))
        // Full disk access for Monad's sessions: on unless turned off.
        f.distro = "macos"
        XCTAssertTrue(f.fullDiskAccess)
        f.fullDiskAccess = false
        XCTAssertFalse(f.apply(to: box).fullDiskAccess)
        // It logs in by itself unless turned off.
        XCTAssertTrue(f.autoLogin)
        XCTAssertTrue(f.apply(to: box).autoLogin)
        f.autoLogin = false
        XCTAssertFalse(f.apply(to: box).autoLogin)
        f.distro = "ubuntu"
        XCTAssertTrue(f.apply(to: box).systemIntegrityProtection, "Linux has no SIP")
        XCTAssertTrue(f.apply(to: box).fullDiskAccess)
        XCTAssertTrue(f.apply(to: box).autoLogin)
    }

    func testUnknownSelectionsFallBackToDefaults() throws {
        var f = try form()
        f.distro = "plan9"
        XCTAssertEqual(f.distro, "ubuntu")
        f.release = "0.1"
        XCTAssertEqual(f.release, "26.04")
    }
}
