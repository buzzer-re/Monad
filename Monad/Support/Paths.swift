//
//  Paths.swift — on-disk layout (Lima-style, under ~/.monad; a Debug build's
//  under ~/.monad-debug, see Flavor).
//
//  ~/.monad/_cache/images/        downloaded cloud images and converted bases
//  ~/.monad/instances/<name>/     one directory per VM
//  ~/.monad/instances/order.json  the VMs' order, the top one is the default VM (VMOrder)
//  ~/.monad/networks/<name>.json  Monad networks
//  ~/.monad/firewall-tags/<name>.json  firewall rule lists VMs can carry
//  ~/.monad/profiles/<id>.profile.json  the user's own profiles
//

import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var root: URL { home.appendingPathComponent(Flavor.current.dataFolder, isDirectory: true) }
    static var imageCache: URL { root.appendingPathComponent("_cache/images", isDirectory: true) }
    static var instances: URL { root.appendingPathComponent("instances", isDirectory: true) }
    /// The user's own terminal themes (*.theme.json).
    static var themes: URL { root.appendingPathComponent("themes", isDirectory: true) }
    /// Monad networks (<name>.json).
    static var networks: URL { root.appendingPathComponent("networks", isDirectory: true) }
    /// Firewall tags (<name>.json).
    static var firewallTags: URL { root.appendingPathComponent("firewall-tags", isDirectory: true) }
    /// Distributions the user added (<id>.distro.json), next to Monad's own.
    static var distros: URL { root.appendingPathComponent("distros", isDirectory: true) }
    /// The user's own profiles (<id>.profile.json).
    static var profiles: URL { root.appendingPathComponent("profiles", isDirectory: true) }
    /// Debug logs (Settings › Logs), one file a day.
    static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    /// Whether debug logging is on, read by the app and MonadHost.
    static var logSettings: URL { root.appendingPathComponent("logging.json") }

    static func instance(_ name: String) -> URL {
        instances.appendingPathComponent(name, isDirectory: true)
    }

    /// Create a directory (and parents) readable only by the user.
    static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

/// Files that make up one instance directory.
struct InstancePaths {
    let dir: URL

    init(name: String, root: URL = Paths.instances) {
        dir = root.appendingPathComponent(name, isDirectory: true)
    }

    var config: URL { dir.appendingPathComponent("instance.json") }
    var disk: URL { dir.appendingPathComponent("disk.raw") }
    var seed: URL { dir.appendingPathComponent("cidata.iso") }
    var efiVars: URL { dir.appendingPathComponent("efi-vars.fd") }
    var machineID: URL { dir.appendingPathComponent("machine-id.bin") }
    /// macOS guests (Phase 14): what Apple's installer leaves beside the disk.
    var auxStorage: URL { dir.appendingPathComponent("aux.img") }
    var hardwareModel: URL { dir.appendingPathComponent("hardware-model.bin") }
    var macMachineID: URL { dir.appendingPathComponent("mac-machine-id.bin") }
    /// Written once the VM's account and Monad's way in are on its disk.
    var macSetupDone: URL { dir.appendingPathComponent("mac-setup-done") }
    /// What the setup's root step copies into the disk (gone once done).
    var macSetupPayload: URL { dir.appendingPathComponent("mac-setup", isDirectory: true) }
    /// The VM account's password, for the user (0600).
    var macPassword: URL { dir.appendingPathComponent("mac-password") }
    /// How System Integrity Protection was found at the last boot (`csrutil status`).
    var macSIPStatus: URL { dir.appendingPathComponent("sip-status") }
    /// Whether the VM's disk gives Monad's sessions full disk access ("on" or "off").
    var macFullDiskAccess: URL { dir.appendingPathComponent("full-disk-access") }
    /// The SIP change last made in recovery ("on" or "off") while it has not taken.
    var macSIPAttempt: URL { dir.appendingPathComponent("sip-attempt") }
    /// The screen as each of recovery's waits ended, from its last run (PNGs).
    var recoveryScreens: URL { dir.appendingPathComponent("recovery-screens", isDirectory: true) }
    var serialLog: URL { dir.appendingPathComponent("serial.log") }
    /// What Monad did with the VM, for its Log page (VMLog).
    var vmLog: URL { dir.appendingPathComponent("vm.log") }
    /// There while the VM's machine runs (when it started); one left behind
    /// means MonadHost ended without seeing the machine stop.
    var runningMark: URL { dir.appendingPathComponent("running") }
    /// Profiles set up in the VM (not run again at boot).
    var appliedProfiles: URL { dir.appendingPathComponent("profiles.json") }
    /// The whole output of a profile's latest run (`id` is a profile id).
    func profileLog(_ id: String) -> URL { dir.appendingPathComponent("profile-\(id).log") }
    var privateKey: URL { dir.appendingPathComponent("id_ed25519") }
    var publicKey: URL { dir.appendingPathComponent("id_ed25519.pub") }
    var sshConfig: URL { dir.appendingPathComponent("ssh.config") }
    var knownHosts: URL { dir.appendingPathComponent("known_hosts") }
    var sshSocket: URL { dir.appendingPathComponent("ssh.sock") }
    var controlSocket: URL { dir.appendingPathComponent("ctl.sock") }
    /// Where the Mac hands files to the VM (host command runs), read-only in
    /// the guest at ~/.monad/exchange.
    var exchange: URL { dir.appendingPathComponent("exchange", isDirectory: true) }
    /// Monad's MCP endpoint for this VM (agents phase), and its token.
    var mcpSocket: URL { dir.appendingPathComponent("mcp.sock") }
    var mcpToken: URL { dir.appendingPathComponent("mcp-token") }
}

extension FileManager {
    /// Remove a folder even if files in it vanish meanwhile (an ssh control
    /// socket going away as its master exits); a folder already gone is fine.
    func removeTree(at url: URL) throws {
        for attempt in 1...3 {
            do {
                try removeItem(at: url)
                return
            } catch {
                if !fileExists(atPath: url.path) { return }
                if attempt == 3 { throw error }
            }
        }
    }
}
