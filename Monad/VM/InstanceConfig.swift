//
//  InstanceConfig.swift — persisted description of a VM (instance.json).
//
//  Version 2 schema. Version 1 files (no "version" key) are migrated on
//  load and written back as v2 on the next save.
//

import Foundation

/// One virtual NIC and the network it is attached to.
struct NetworkAttachment: Codable, Equatable, Hashable {
    /// Apple's NAT, as configs from before Monad networks call it (they keep it).
    static let defaultNAT = "nat"

    var network: String
    /// "xx:xx:xx:xx:xx:xx"; generated on first boot when nil.
    var macAddress: String?

    /// Apple's NAT (and "nat", its name before Monad networks) rather than a
    /// Monad network through monad-netd.
    var isAppleNAT: Bool { network == NetworkDefinition.appleNATName || network == Self.defaultNAT }

    /// A random locally administered unicast address, never in monad-netd's
    /// gateway range (02:4d:4e:47:00:xx).
    static func randomMAC() -> String {
        while true {
            var b = (0..<6).map { _ in UInt8.random(in: 0...255) }
            b[0] = b[0] & 0xfc | 0x02
            let mac = b.map { String(format: "%02x", $0) }.joined(separator: ":")
            if !mac.hasPrefix("02:4d:4e:47:00:") { return mac }
        }
    }
}

/// A host folder exposed to the guest at runtime (virtio-fs).
/// A disk another tool owns that the VM boots where it is (Phase 9: a Lima
/// VM's). Fixed when the VM is created; Monad never copies, grows or
/// deletes it.
struct AttachedDisk: Codable, Equatable, Hashable {
    enum Kind: String, Codable { case lima }

    var kind: Kind = .lima
    /// The Lima instance's name.
    var instance: String
    /// Its folder (<LIMA_HOME>/<instance>).
    var dir: String
    /// The guest user's home as Lima made it (/home/<user>.linux); nil: Lima's default.
    var home: String?

    init(lima instance: String, dir: String, home: String? = nil) {
        self.instance = instance
        self.dir = dir
        self.home = home
    }

    /// Lima's disk for vz instances (LimaDisk.diskFile).
    var disk: URL { LimaDisk.diskFile(in: URL(fileURLWithPath: dir, isDirectory: true)) }

    /// A Lima name, an absolute, plain folder named after it, and a plain
    /// absolute home if one is given.
    var isValid: Bool {
        func plain(_ path: String) -> Bool {
            path.hasPrefix("/") && !path.unicodeScalars.contains { $0.properties.generalCategory == .control }
                && URL(fileURLWithPath: path).standardizedFileURL.path == path
        }
        let name = !instance.isEmpty && instance.count <= 64 && instance != "." && instance != ".."
            && instance.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
        return name && plain(dir) && (dir as NSString).lastPathComponent == instance && (home.map(plain) ?? true)
    }
}

struct SharedFolder: Codable, Equatable, Hashable {
    var hostPath: String
    var guestPath: String
    var readOnly: Bool
    /// Set by Monad's window once the user agreed to share a folder that
    /// needs it (SharePolicy); absent otherwise.
    var confirmed: Bool? = nil

    /// Directory name inside the virtio-fs share, derived from the guest
    /// path: "/home/dev/src" → "home-dev-src". Only [A-Za-z0-9._-] survive.
    var shareName: String {
        let parts = guestPath.split(separator: "/").map { part in
            String(part.unicodeScalars.map { c -> Character in
                switch c {
                case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-": Character(c)
                default: "_"
                }
            })
        }
        let name = parts.joined(separator: "-")
        return name.isEmpty ? "root" : name
    }
}

struct SharingSettings: Codable, Equatable {
    /// The VM gets a virtio-fs device only when this is on (needs a reboot to change).
    var runtimeEnabled: Bool = false
    var shares: [SharedFolder] = []

    /// The VM's exchange folder as a share: from its folder on the Mac,
    /// read-only, at ~/.monad/exchange in the guest. Its name on the device
    /// comes from that path like any share's, and no share may be under
    /// ~/.monad, so it is its own.
    static func exchange(_ paths: InstancePaths, home: String) -> SharedFolder {
        SharedFolder(hostPath: paths.exchange.path, guestPath: home + "/.monad/exchange", readOnly: true)
    }

    /// Each share with its directory name inside the virtio-fs share;
    /// colliding names get -2, -3, … The host and the guest both use this.
    static func named(_ shares: [SharedFolder]) -> [(name: String, share: SharedFolder)] {
        var used = Set<String>()
        return shares.map { share in
            var name = share.shareName, n = 2
            while used.contains(name) {
                name = "\(share.shareName)-\(n)"
                n += 1
            }
            used.insert(name)
            return (name, share)
        }
    }
}

/// A port, socket or SOCKS forward between the Mac and the guest.
/// A stdio bridge (Phase 12): a Mac command a VM can use, socat-style.
/// Each connection the VM makes runs the command on the Mac, as the user,
/// with the connection as its stdin and stdout (stderr goes to the
/// bridge's log). On the Mac it listens on a private unix socket in the
/// VM's folder, never a TCP port; the VM reaches it on a port of its
/// loopback or a unix socket, through a remote forward on its ssh master.
struct CommandBridge: Codable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var command: [String]
    var guestPort: Int?
    var guestSocket: String?
    var enabled: Bool = true

    init(id: UUID = UUID(), name: String, command: [String], guestPort: Int? = nil, guestSocket: String? = nil,
         enabled: Bool = true) {
        self.id = id
        self.name = name
        self.command = command
        self.guestPort = guestPort
        self.guestSocket = guestSocket
        self.enabled = enabled
    }

    static let maxPerVM = 8
    /// The program and its arguments.
    static let maxCommandParts = 32
    static let maxPartBytes = 1024

    /// Where the VM reaches it: "127.0.0.1:<port>" or the socket's path.
    var guestEndpoint: String { guestPort.map { "127.0.0.1:\($0)" } ?? guestSocket ?? "" }

    /// Short, for the 104 bytes of a unix socket path.
    private var fileStem: String { "bridge-" + id.uuidString.prefix(8).lowercased() }

    func socket(in paths: InstancePaths) -> URL { paths.dir.appendingPathComponent(fileStem + ".sock") }
    func log(in paths: InstancePaths) -> URL { paths.dir.appendingPathComponent(fileStem + ".log") }

    /// The remote forward that takes the VM's connections to the socket.
    func spec(in paths: InstancePaths) -> SSHMux.Spec {
        SSHMux.Spec(flag: "-R", value: "\(guestPort.map { "127.0.0.1:\($0)" } ?? guestSocket ?? ""):\(socket(in: paths).path)")
    }

    var isValidName: Bool {
        (1...32).contains(name.count) && name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " ._-".unicodeScalars.contains($0))
        }
    }

    /// The program by its full path (as it is: no "." or ".."), and plain
    /// arguments: no shell ever reads them.
    var isValidCommand: Bool {
        guard let program = command.first, command.count <= Self.maxCommandParts, program.hasPrefix("/"),
              URL(fileURLWithPath: program).standardizedFileURL.path == program else { return false }
        return command.allSatisfy { part in
            part.utf8.count <= Self.maxPartBytes && !part.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
    }

    /// One place in the VM: an unprivileged port, or an absolute socket path
    /// ssh can take (no ":" or whitespace).
    var isValidEndpoint: Bool {
        switch (guestPort, guestSocket) {
        case (let port?, nil):
            return (1024...65535).contains(port)
        case (nil, let path?):
            return path.hasPrefix("/") && !path.contains(":") && !path.contains(where: \.isWhitespace)
                && !path.unicodeScalars.contains { $0.properties.generalCategory == .control }
        default:
            return false
        }
    }
}

struct ForwardRule: Codable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case local       // host port → guest port
        case remote      // guest port → host port (reaches into the host: opt-in)
        case socks       // host SOCKS5 port, traffic leaves from the guest
        case unixLocal   // host unix socket → guest unix socket
        case unixRemote  // guest unix socket → host unix socket (opt-in)
    }

    var id: UUID = UUID()
    var kind: Kind
    var hostAddress: String = "127.0.0.1"
    var hostPort: Int?
    var guestHost: String = "127.0.0.1"
    var guestPort: Int?
    var hostSocket: String?
    var guestSocket: String?
    var enabled: Bool = true

    init(kind: Kind, hostAddress: String = "127.0.0.1", hostPort: Int? = nil, guestHost: String = "127.0.0.1",
         guestPort: Int? = nil, hostSocket: String? = nil, guestSocket: String? = nil, enabled: Bool = true) {
        self.kind = kind
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.guestHost = guestHost
        self.guestPort = guestPort
        self.hostSocket = hostSocket
        self.guestSocket = guestSocket
        self.enabled = enabled
    }

    /// Whether this rule binds a listener on the Mac.
    var bindsOnHost: Bool { kind == .local || kind == .socks || kind == .unixLocal }
    /// Whether this rule lets the guest reach something on the Mac.
    var reachesIntoHost: Bool { kind == .remote || kind == .unixRemote }
    /// Whether other computers can connect: a VM port or a SOCKS proxy on a
    /// Mac address other than the loopback.
    var opensToNetwork: Bool { (kind == .local || kind == .socks) && !Self.isLoopback(hostAddress) }
    /// Whether the user's word is needed for it: it reaches into the Mac, or
    /// other computers reach it.
    var needsConfirmation: Bool { reachesIntoHost || opensToNetwork }

    /// 127.0.0.0/8, ::1, and the loopback as an IPv4-mapped address.
    static func isLoopback(_ address: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, address, &v4) == 1 { return UInt32(bigEndian: v4.s_addr) >> 24 == 127 }
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
        return b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff && b[12] == 127
    }
}

/// Lima-style automatic forwarding of ports the guest listens on.
struct AutoForwardSettings: Codable, Equatable {
    var enabled: Bool = true
    /// Ports below this are never auto-forwarded (privileged range).
    var minimumPort: Int = 1024
    var ignoredPorts: [Int] = []
}

struct InstanceConfig: Equatable {
    static let currentVersion = 2

    var version: Int = InstanceConfig.currentVersion
    var name: String
    /// Distribution id (e.g. "ubuntu", "debian", "fedora", "opensuse").
    var distro: String
    /// Release of the distro (nil: its default release, recorded at provisioning).
    var release: String? = nil
    /// Human-readable base image the disk was created from.
    var image: String
    /// Login user inside the guest.
    var user: String
    var cpus: Int
    /// Memory the VM boots with (upper bound).
    var memoryGiB: Int
    /// Live target via the balloon; nil means `memoryGiB`.
    var memoryTargetGiB: Int?
    var diskGiB: Int
    /// NICs in order; empty means no network device at all.
    var networks: [NetworkAttachment]
    /// Where the VM may connect through a Monad NAT network.
    var firewall = VMFirewall()
    var sharing: SharingSettings
    /// Forwards into the Mac (remote ones) are rules the user added and
    /// confirmed in Monad's window; files from when a per-VM switch also had
    /// to be on ("allowRemoteForwards") still load, the key is ignored.
    var forwards: [ForwardRule]
    var autoForward: AutoForwardSettings
    var profiles: [String]
    var theme: String?
    /// Deleted automatically when its last tab closes.
    var ephemeral: Bool
    var createdAt: Date
    /// "Start VM at boot": started when Monad opens.
    var startAtLaunch = false
    /// Programs in the VM may show images in its tabs (OSC 1337). Off: Monad
    /// never decodes image data the VM sends.
    var inlineImages = false
    /// The Lima VM whose disk this VM boots in place; nil for Monad's own disk.
    var attached: AttachedDisk? = nil
    /// The Lima VM whose disk this VM's own was copied from ("Copy to
    /// Monad"); nil for VMs made from an image.
    var copiedFrom: AttachedDisk? = nil
    var bridges: [CommandBridge] = []
    /// Mac commands the VM may run with arguments it varies under the
    /// user's patterns (agents phase).
    var hostCommands: [HostCommand] = []
    /// What the VM may do with Monad itself (agents phase); nil: nothing.
    var agents: AgentAccess? = nil
    /// The orchestrator VM that made this one; fixed once made.
    var parent: String? = nil
    /// What runs in it: Linux, or macOS (Phase 14). Fixed once made.
    var guestOS: GuestOS = .linux
    /// The IPSW file a macOS VM is installed from when one was chosen (nil:
    /// the latest from Apple). Kept only until the VM is made.
    var restoreImage: String? = nil
    /// macOS: System Integrity Protection (on unless turned off). A change
    /// is made in the VM's recoveryOS at its next start (MacRecovery).
    var systemIntegrityProtection = true
    /// macOS: Monad's sessions may read protected folders (Documents, …):
    /// a TCC row in the VM's disk, written while it is stopped.
    var fullDiskAccess = true
    /// macOS: it logs in by itself at boot (no login window on its desktop).
    var autoLogin = true
    /// macOS: the next start opens recovery and its desktop, for the user;
    /// turned off as it does (once).
    var bootToRecovery = false
    /// macOS: Monad types the account's password into the prompts on its
    /// desktop; nil until asked (when the desktop is first opened).
    var desktopAutofill: Bool? = nil

    /// macOS needs this much at least (Apple's installer and a usable system).
    static let macMinimumMemoryGiB = 4
    static let macMinimumDiskGiB = 40

    /// The group it is listed in (Virtual Machines); the group's firewall
    /// tag, if there is one, applies to it as a tag would.
    var group: String? = nil

    /// The firewall netd enforces: the VM's own, with its group's tag.
    var effectiveFirewall: VMFirewall {
        var f = firewall
        f.group = group
        return f
    }

    /// The guest user's home: Lima's for a Lima VM or a copy of one, else
    /// the one cloud-init makes.
    var home: String {
        if guestOS == .macos { return "/Users/\(user)" }
        guard let lima = attached ?? copiedFrom else { return "/home/\(user)" }
        return lima.home ?? "/home/\(user).linux"
    }

    /// What the sharing device holds: the user's shares, then the exchange
    /// folder. Nothing without the device.
    /// The folders the VM's sharing device holds. A share of the Mac's home
    /// folder (the one holding Monad's own) is its visible folders, so
    /// ~/.monad, the other dot folders and ~/Library never reach the VM.
    func deviceShares(paths: InstancePaths) -> [SharedFolder] {
        guard sharing.runtimeEnabled else { return [] }
        let macHome = Self.macHome(paths)
        return sharing.shares.flatMap { SharePolicy.resolve($0.hostPath) == macHome ? SharePolicy.homeFolders($0, home: macHome) : [$0] }
            + [SharingSettings.exchange(paths, home: home)]
    }

    /// The Mac's home folder, the one holding Monad's own folder: from a VM's
    /// folder, instances/<vm> → instances → Monad's folder → the home folder
    /// (the same as `SharePolicy.Places.mac.home` for both builds' folders).
    static func macHome(_ paths: InstancePaths) -> String {
        SharePolicy.resolve(paths.dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path)
    }

    /// The disk the VM boots: its own, or the attached one where it is.
    func disk(in paths: InstancePaths) -> URL { attached?.disk ?? paths.disk }

    var primaryMACAddress: String? { networks.first?.macAddress }

    /// The VM's name for ssh (its Host, HostKeyAlias and destination),
    /// lowercase: ssh lowercases the host it is given before it matches
    /// Host lines.
    var sshHost: String { "monad-\(name.lowercased())" }

    /// Letters (either case), digits and dashes. Two names that differ in
    /// case only are one VM: the Mac's disk does not tell their folders apart
    /// (VMManager.isNameTaken).
    static let namePattern = "^[A-Za-z0-9][A-Za-z0-9-]{0,31}$"

    static func isValidName(_ name: String) -> Bool {
        name.range(of: namePattern, options: .regularExpression) != nil
    }

    static func defaults(name: String, ephemeral: Bool = false) -> InstanceConfig {
        InstanceConfig(name: name, distro: DistroCatalog.live?.defaultDistro?.id ?? "", image: "",
                       user: guestUserName(), cpus: VMDefaults.cpus, memoryGiB: VMDefaults.memoryGiB,
                       memoryTargetGiB: nil, diskGiB: VMDefaults.diskGiB,
                       networks: [NetworkAttachment(network: NetworkDefinition.defaultName, macAddress: nil)],
                       sharing: SharingSettings(), forwards: [],
                       autoForward: AutoForwardSettings(), profiles: [], theme: nil, ephemeral: ephemeral,
                       createdAt: Self.now())
    }

    /// Current time at whole-second precision, so it survives JSON exactly.
    static func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    /// Host short name mapped to a valid Linux user name.
    static func guestUserName() -> String {
        let raw = NSUserName().lowercased()
        var out = ""
        for ch in raw.unicodeScalars {
            if CharacterSet.lowercaseLetters.contains(ch) && ch.isASCII || (CharacterSet.decimalDigits.contains(ch) && ch.isASCII)
                || ch == "_" || ch == "-" {
                out.unicodeScalars.append(ch)
            }
        }
        let reserved: Set<String> = ["root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news",
                                     "uucp", "proxy", "www-data", "backup", "list", "irc", "nobody", "ubuntu", "admin"]
        if out.isEmpty || !(out.first?.isLetter ?? false) || reserved.contains(out) { out = "dev" }
        return String(out.prefix(32))
    }

    // MARK: Persistence

    enum DecodingProblem: Error, Equatable, LocalizedError {
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                return "This VM was created by a newer Monad (config version \(v)). Update Monad to use it."
            }
        }
    }

    /// ISO 8601; dates are kept at whole seconds (see `now()`), older files may carry fractions.
    private static func dateFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }

    static func decode(_ data: Data) throws -> InstanceConfig {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom(decodeDate)
        return try dec.decode(InstanceConfig.self, from: data)
    }

    /// Date coding shared by instance.json and the host protocol.
    static func decodeDate(from decoder: Decoder) throws -> Date {
        let text = try decoder.singleValueContainer().decode(String.self)
        // Accept both whole and fractional seconds.
        if let d = dateFormatter(fractional: true).date(from: text) ?? dateFormatter(fractional: false).date(from: text) {
            return d
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
    }

    static func encodeDate(_ date: Date, to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(dateFormatter(fractional: false).string(from: date))
    }

    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .custom(Self.encodeDate)
        return try enc.encode(self)
    }

    func save(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> InstanceConfig {
        try decode(Data(contentsOf: url))
    }
}

extension InstanceConfig: Codable {
    private enum Keys: String, CodingKey {
        case version, name, distro, release, image, user, cpus, memoryGiB, memoryTargetGiB, diskGiB, networks, firewall
        case sharing
        case forwards, autoForward, profiles, theme, ephemeral, createdAt, startAtLaunch, attached
        case copiedFrom, bridges, inlineImages, hostCommands, agents, parent, group, guestOS, restoreImage
        case systemIntegrityProtection, fullDiskAccess, autoLogin, desktopAutofill, bootToRecovery
        // v1 only
        case network, macAddress, sharedDirectory, sharedReadOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= InstanceConfig.currentVersion else { throw DecodingProblem.unsupportedVersion(version) }

        self.version = InstanceConfig.currentVersion
        name = try c.decode(String.self, forKey: .name)
        // Monad writes every key. A file written by hand or a script may
        // leave out what the New VM sheet starts with (docs/CONFIG.md);
        // whatever it holds is validated as on create.
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? InstanceConfig.guestUserName()
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? VMDefaults.cpus
        memoryGiB = try c.decodeIfPresent(Int.self, forKey: .memoryGiB) ?? VMDefaults.memoryGiB
        diskGiB = try c.decodeIfPresent(Int.self, forKey: .diskGiB) ?? VMDefaults.diskGiB
        ephemeral = try c.decodeIfPresent(Bool.self, forKey: .ephemeral) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? InstanceConfig.now()
        // Older configs have none: the default (the Mac and its LAN blocked).
        firewall = try c.decodeIfPresent(VMFirewall.self, forKey: .firewall) ?? VMFirewall()
        startAtLaunch = try c.decodeIfPresent(Bool.self, forKey: .startAtLaunch) ?? false
        inlineImages = try c.decodeIfPresent(Bool.self, forKey: .inlineImages) ?? false
        attached = try c.decodeIfPresent(AttachedDisk.self, forKey: .attached)
        copiedFrom = try c.decodeIfPresent(AttachedDisk.self, forKey: .copiedFrom)
        bridges = try c.decodeIfPresent([CommandBridge].self, forKey: .bridges) ?? []
        hostCommands = try c.decodeIfPresent([HostCommand].self, forKey: .hostCommands) ?? []
        agents = try c.decodeIfPresent(AgentAccess.self, forKey: .agents)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        guestOS = try c.decodeIfPresent(GuestOS.self, forKey: .guestOS) ?? .linux
        restoreImage = try c.decodeIfPresent(String.self, forKey: .restoreImage)
        systemIntegrityProtection = try c.decodeIfPresent(Bool.self, forKey: .systemIntegrityProtection) ?? true
        fullDiskAccess = try c.decodeIfPresent(Bool.self, forKey: .fullDiskAccess) ?? true
        autoLogin = try c.decodeIfPresent(Bool.self, forKey: .autoLogin) ?? true
        bootToRecovery = try c.decodeIfPresent(Bool.self, forKey: .bootToRecovery) ?? false
        desktopAutofill = try c.decodeIfPresent(Bool.self, forKey: .desktopAutofill)

        if version == 1 {
            // v1 only knew Ubuntu, one optional NAT NIC and one boot-time share.
            distro = "ubuntu"
            memoryTargetGiB = nil
            let hasNetwork = try c.decode(Bool.self, forKey: .network)
            let mac = try c.decodeIfPresent(String.self, forKey: .macAddress)
            networks = hasNetwork ? [NetworkAttachment(network: NetworkAttachment.defaultNAT, macAddress: mac)] : []
            if let dir = try c.decodeIfPresent(String.self, forKey: .sharedDirectory), !dir.isEmpty {
                let readOnly = try c.decodeIfPresent(Bool.self, forKey: .sharedReadOnly) ?? true
                sharing = SharingSettings(runtimeEnabled: true,
                                          shares: [SharedFolder(hostPath: dir, guestPath: "/mnt/host", readOnly: readOnly)])
            } else {
                sharing = SharingSettings()
            }
            forwards = []
            autoForward = AutoForwardSettings()
            profiles = []
            theme = nil
        } else {
            distro = try c.decode(String.self, forKey: .distro)
            release = try c.decodeIfPresent(String.self, forKey: .release)
            memoryTargetGiB = try c.decodeIfPresent(Int.self, forKey: .memoryTargetGiB)
            networks = try c.decodeIfPresent([NetworkAttachment].self, forKey: .networks)
                ?? [NetworkAttachment(network: NetworkDefinition.defaultName, macAddress: nil)]
            sharing = try c.decodeIfPresent(SharingSettings.self, forKey: .sharing) ?? SharingSettings()
            forwards = try c.decodeIfPresent([ForwardRule].self, forKey: .forwards) ?? []
            autoForward = try c.decodeIfPresent(AutoForwardSettings.self, forKey: .autoForward) ?? AutoForwardSettings()
            profiles = try c.decodeIfPresent([String].self, forKey: .profiles) ?? []
            theme = try c.decodeIfPresent(String.self, forKey: .theme)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(version, forKey: .version)
        try c.encode(name, forKey: .name)
        try c.encode(distro, forKey: .distro)
        try c.encodeIfPresent(release, forKey: .release)
        try c.encode(image, forKey: .image)
        try c.encode(user, forKey: .user)
        try c.encode(cpus, forKey: .cpus)
        try c.encode(memoryGiB, forKey: .memoryGiB)
        try c.encodeIfPresent(memoryTargetGiB, forKey: .memoryTargetGiB)
        try c.encode(diskGiB, forKey: .diskGiB)
        try c.encode(networks, forKey: .networks)
        // Only when set, so configs without one stay as they were.
        if firewall != VMFirewall() { try c.encode(firewall, forKey: .firewall) }
        try c.encode(sharing, forKey: .sharing)
        try c.encode(forwards, forKey: .forwards)
        try c.encodeIfPresent(attached, forKey: .attached)
        try c.encodeIfPresent(copiedFrom, forKey: .copiedFrom)
        if !bridges.isEmpty { try c.encode(bridges, forKey: .bridges) }
        if !hostCommands.isEmpty { try c.encode(hostCommands, forKey: .hostCommands) }
        try c.encodeIfPresent(agents, forKey: .agents)
        try c.encodeIfPresent(parent, forKey: .parent)
        try c.encodeIfPresent(group, forKey: .group)
        if guestOS != .linux { try c.encode(guestOS, forKey: .guestOS) }
        try c.encodeIfPresent(restoreImage, forKey: .restoreImage)
        // Only when off, so configs stay as they were.
        if !systemIntegrityProtection { try c.encode(systemIntegrityProtection, forKey: .systemIntegrityProtection) }
        if !fullDiskAccess { try c.encode(fullDiskAccess, forKey: .fullDiskAccess) }
        if !autoLogin { try c.encode(autoLogin, forKey: .autoLogin) }
        if bootToRecovery { try c.encode(bootToRecovery, forKey: .bootToRecovery) }
        try c.encodeIfPresent(desktopAutofill, forKey: .desktopAutofill)
        try c.encode(autoForward, forKey: .autoForward)
        try c.encode(profiles, forKey: .profiles)
        try c.encodeIfPresent(theme, forKey: .theme)
        try c.encode(ephemeral, forKey: .ephemeral)
        try c.encode(createdAt, forKey: .createdAt)
        // Only when on, so configs without them stay as they were.
        if startAtLaunch { try c.encode(startAtLaunch, forKey: .startAtLaunch) }
        if inlineImages { try c.encode(inlineImages, forKey: .inlineImages) }
    }
}

// MARK: - Defaults for keys a file leaves out

// Monad writes every key; a file written by hand or a script may leave
// these out (docs/CONFIG.md). The safe choice where there is one.

extension SharedFolder {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostPath = try c.decode(String.self, forKey: .hostPath)
        guestPath = try c.decode(String.self, forKey: .guestPath)
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? true
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed)
    }
}

extension SharingSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runtimeEnabled = try c.decodeIfPresent(Bool.self, forKey: .runtimeEnabled) ?? false
        shares = try c.decodeIfPresent([SharedFolder].self, forKey: .shares) ?? []
    }
}

extension ForwardRule {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        hostAddress = try c.decodeIfPresent(String.self, forKey: .hostAddress) ?? "127.0.0.1"
        hostPort = try c.decodeIfPresent(Int.self, forKey: .hostPort)
        guestHost = try c.decodeIfPresent(String.self, forKey: .guestHost) ?? "127.0.0.1"
        guestPort = try c.decodeIfPresent(Int.self, forKey: .guestPort)
        hostSocket = try c.decodeIfPresent(String.self, forKey: .hostSocket)
        guestSocket = try c.decodeIfPresent(String.self, forKey: .guestSocket)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

extension CommandBridge {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode([String].self, forKey: .command)
        guestPort = try c.decodeIfPresent(Int.self, forKey: .guestPort)
        guestSocket = try c.decodeIfPresent(String.self, forKey: .guestSocket)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

extension AutoForwardSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        minimumPort = try c.decodeIfPresent(Int.self, forKey: .minimumPort) ?? 1024
        ignoredPorts = try c.decodeIfPresent([Int].self, forKey: .ignoredPorts) ?? []
    }
}

// MARK: - Validation

extension InstanceConfig {
    enum ValidationError: Error, Equatable, LocalizedError {
        case name(String)
        case cpus(Int, max: Int)
        case memory(Int, max: Int)
        case memoryTarget(Int, max: Int)
        case disk(Int)
        case macResources(String)
        case restoreImage(String)
        case systemIntegrityProtection
        case fullDiskAccess
        case macOSOnly(String)
        case attachedDisk(String)
        case sharingDisabled
        case shareHostPath(String)
        case shareGuestPath(String)
        case duplicateGuestPath(String)
        case port(Int)
        case privilegedHostPort(Int)
        case duplicateHostBinding(String)
        case incompleteForward
        case socketPath(String)
        case hostAddress(String)
        case autoForwardMinimum(Int)
        case theme(String)
        case user(String)
        case distro(String)
        case release(String)
        case image(String)
        case network(String)
        case macAddress(String)
        case profile(String)
        case bridgeName(String)
        case bridgeCommand(String)
        case bridgeEndpoint(String)
        case tooManyBridges
        case hostCommand(String, String)
        case agents(String)
        case parent(String)
        case group(String)
        case duplicateGuestEndpoint(String)

        var errorDescription: String? {
            switch self {
            case .name(let n): return "“\(n)” is not a valid name: use letters, digits and dashes (max 32)."
            case .cpus(let n, let max): return "\(n) CPUs is out of range (1–\(max))."
            case .memory(let n, let max): return "\(n) GB of memory is out of range (1–\(max) GB)."
            case .memoryTarget(let n, let max): return "The live memory target (\(n) GB) cannot exceed the boot memory (\(max) GB)."
            case .disk(let n): return "\(n) GB is too small for a disk (minimum 10 GB)."
            case .macResources(let why): return why
            case .restoreImage(let p): return "“\(p)” is not a macOS restore image (an .ipsw file, by its full path)."
            case .systemIntegrityProtection: return "System Integrity Protection is a macOS setting: only a macOS VM can turn it off."
            case .fullDiskAccess: return "Full disk access is a macOS setting: only a macOS VM can turn it off."
            case .macOSOnly(let what): return "\(what) is a macOS setting."
            case .attachedDisk(let d): return "“\(d)” is not a Lima VM's folder."
            case .sharingDisabled: return "Turn on runtime sharing for this VM before adding shared folders."
            case .shareHostPath(let p): return "The Mac folder must be an absolute path: \(p)"
            case .shareGuestPath(let p): return "“\(p)” cannot be used as a mount point in the guest."
            case .duplicateGuestPath(let p): return "Two shared folders use the same guest path: \(p)"
            case .port(let p): return "\(p) is not a valid port (1–65535)."
            case .privilegedHostPort(let p): return "Port \(p) is privileged on the Mac. Use 1024 or above."
            case .duplicateHostBinding(let b): return "Two forwards listen on \(b)."
            case .incompleteForward: return "A forward is missing its ports or socket paths."
            case .socketPath(let p): return "Socket paths must be absolute: \(p)"
            case .hostAddress(let a): return "“\(a)” is not an IP address to listen on."
            case .autoForwardMinimum(let p): return "Auto-forwarding cannot start below port 1024 (got \(p))."
            case .theme(let t): return "“\(t)” is not a theme id."
            case .user(let u): return "“\(u)” is not a guest user name: use lowercase letters, digits, - and _ (max 32), not root."
            case .distro(let d): return "“\(d)” is not a distribution id."
            case .release(let r): return "“\(r)” is not a release name."
            case .image(let i): return "“\(i)” is not an image name."
            case .network(let n): return "“\(n)” is not a network name."
            case .macAddress(let m): return "“\(m)” is not a MAC address."
            case .profile(let p): return "“\(p)” is not a profile id."
            case .bridgeName(let n):
                return "“\(n)” is not a bridge name: up to 32 letters, digits, spaces, dots, dashes or underscores."
            case .bridgeCommand(let c):
                return "“\(c)” cannot be a bridge's command. Give the program's full path and up to 31 plain arguments."
            case .bridgeEndpoint(let n):
                return "The bridge “\(n)” needs one place in the VM: a port from 1024 to 65535, or an absolute socket path."
            case .tooManyBridges: return "A VM can have at most \(CommandBridge.maxPerVM) bridges and host commands."
            case .hostCommand(let name, let why): return "\(name): \(why)"
            case .agents(let why): return why
            case .parent(let p): return "“\(p)” is not a VM name."
            case .group(let g): return "“\(g)” is not a group name: letters, digits, - and _, up to 32."
            case .duplicateGuestEndpoint(let e): return "\(e) in the VM is already used by another bridge or forward."
            }
        }
    }

    /// Guest locations that must never be replaced by a share.
    private static let reservedGuestPrefixes = ["/proc", "/sys", "/dev", "/etc", "/usr", "/boot", "/bin", "/sbin",
                                                "/lib", "/lib64", "/run", "/var/lib", "/root"]

    static func normalizedGuestPath(_ p: String) -> String {
        var s = p
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Bridges: at most maxPerVM, each well formed, and no two things in the
    /// VM (bridges, forwards into the Mac) on the same port or socket.
    private func validateBridges() throws {
        guard bridges.count + hostCommands.count <= CommandBridge.maxPerVM else { throw ValidationError.tooManyBridges }
        var taken = Set<String>()
        for rule in forwards {
            switch rule.kind {
            case .remote: if let p = rule.guestPort { taken.insert("tcp \(p)") }
            case .unixRemote: if let s = rule.guestSocket { taken.insert(s) }
            case .local, .socks, .unixLocal: break
            }
        }
        for bridge in bridges {
            guard bridge.isValidName else { throw ValidationError.bridgeName(bridge.name) }
            guard bridge.isValidCommand else { throw ValidationError.bridgeCommand(bridge.command.first ?? "") }
            guard bridge.isValidEndpoint else { throw ValidationError.bridgeEndpoint(bridge.name) }
            let key = bridge.guestPort.map { "tcp \($0)" } ?? bridge.guestEndpoint
            guard taken.insert(key).inserted else { throw ValidationError.duplicateGuestEndpoint(bridge.guestEndpoint) }
        }
        var names = Set<String>()
        for command in hostCommands {
            if let why = command.problem(shares: sharing.shares) { throw ValidationError.hostCommand(command.name, why) }
            guard names.insert(command.name).inserted else {
                throw ValidationError.hostCommand(command.name, "Another host command has this name.")
            }
            let key = command.guestPort.map { "tcp \($0)" } ?? command.guestEndpoint
            guard taken.insert(key).inserted else { throw ValidationError.duplicateGuestEndpoint(command.guestEndpoint) }
        }
        if let agents {
            guard taken.insert("tcp \(agents.guestPort)").inserted else {
                throw ValidationError.duplicateGuestEndpoint("127.0.0.1:\(agents.guestPort)")
            }
        }
    }

    /// Where a shared folder may be mounted in the guest: an absolute path,
    /// not a system folder, without control characters (the guest keeps one
    /// folder per line in its mount list).
    static func isValidGuestPath(_ p: String) -> Bool {
        guard p.hasPrefix("/") else { return false }
        let g = normalizedGuestPath(p)
        return !isReservedGuestPath(g) && !g.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    private static func isReservedGuestPath(_ p: String) -> Bool {
        if p == "/" { return true }
        if p.split(separator: "/").contains("..") { return true }
        return reservedGuestPrefixes.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    static func isIPLiteral(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    /// A plain DNS name: letters, digits, dots and dashes.
    static func isHostName(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9]([A-Za-z0-9-]{0,62})(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}))*$", options: .regularExpression) != nil
    }

    /// A Linux user name for the guest (not root): written into ssh_config,
    /// cloud-init and scripts.
    static func isValidUser(_ user: String) -> Bool {
        user != "root" && user.range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil
    }

    private static func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    func validate(maxCPUs: Int, maxMemoryGiB: Int) throws {
        guard Self.isValidName(name) else { throw ValidationError.name(name) }
        // Every string that reaches a file or a script has a rule.
        guard Self.isValidUser(user) else { throw ValidationError.user(user) }
        guard distro.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil else {
            throw ValidationError.distro(distro)
        }
        if let r = release, r.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) == nil {
            throw ValidationError.release(r)
        }
        guard image.count <= 256, !Self.hasControl(image) else { throw ValidationError.image(image) }
        for n in networks {
            guard NetworkDefinition.isValidName(n.network) || n.network == NetworkDefinition.appleNATName else {
                throw ValidationError.network(n.network)
            }
            if let mac = n.macAddress,
               mac.range(of: "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", options: .regularExpression) == nil {
                throw ValidationError.macAddress(mac)
            }
        }
        for p in profiles where !ProfileConfig.isID(p) { throw ValidationError.profile(p) }
        if let parent, !Self.isValidName(parent) { throw ValidationError.parent(parent) }
        if let group, !FirewallTag.isValidName(group) { throw ValidationError.group(group) }
        if let agents, let why = agents.problem(maxCPUs: maxCPUs, maxMemoryGiB: maxMemoryGiB) { throw ValidationError.agents(why) }
        guard (1...max(1, maxCPUs)).contains(cpus) else { throw ValidationError.cpus(cpus, max: maxCPUs) }
        guard (1...max(1, maxMemoryGiB)).contains(memoryGiB) else { throw ValidationError.memory(memoryGiB, max: maxMemoryGiB) }
        if let t = memoryTargetGiB, t < 1 || t > memoryGiB { throw ValidationError.memoryTarget(t, max: memoryGiB) }
        if let restoreImage {
            guard guestOS == .macos, restoreImage.hasPrefix("/"), restoreImage.lowercased().hasSuffix(".ipsw") else {
                throw ValidationError.restoreImage(restoreImage)
            }
        }
        if !systemIntegrityProtection, guestOS != .macos { throw ValidationError.systemIntegrityProtection }
        if !fullDiskAccess, guestOS != .macos { throw ValidationError.fullDiskAccess }
        if !autoLogin, guestOS != .macos { throw ValidationError.macOSOnly("Logging in automatically") }
        if bootToRecovery, guestOS != .macos { throw ValidationError.macOSOnly("Booting to recovery") }
        if desktopAutofill != nil, guestOS != .macos { throw ValidationError.macOSOnly("Auto-fill") }
        if guestOS == .macos {
            guard memoryGiB >= Self.macMinimumMemoryGiB else {
                throw ValidationError.macResources("macOS needs at least \(Self.macMinimumMemoryGiB) GB of memory.")
            }
            guard diskGiB >= Self.macMinimumDiskGiB else {
                throw ValidationError.macResources("macOS needs a disk of at least \(Self.macMinimumDiskGiB) GB.")
            }
        }
        // A VM boots a Lima VM's disk or a copy of it, not both; either way
        // the size is Lima's.
        if let attached, copiedFrom != nil { throw ValidationError.attachedDisk(attached.dir) }
        if let lima = attached ?? copiedFrom {
            guard lima.isValid else { throw ValidationError.attachedDisk(lima.dir) }
        } else {
            guard diskGiB >= 10 else { throw ValidationError.disk(diskGiB) }
        }
        try firewall.validate()

        if !sharing.shares.isEmpty && !sharing.runtimeEnabled { throw ValidationError.sharingDisabled }
        var guestPaths = Set<String>()
        for share in sharing.shares {
            guard share.hostPath.hasPrefix("/"), !Self.hasControl(share.hostPath) else {
                throw ValidationError.shareHostPath(share.hostPath)
            }
            guard Self.isValidGuestPath(share.guestPath) else { throw ValidationError.shareGuestPath(share.guestPath) }
            let g = Self.normalizedGuestPath(share.guestPath)
            // Monad's own folder in the guest (shots, uploads, the exchange).
            guard g != home + "/.monad", !g.hasPrefix(home + "/.monad/") else { throw ValidationError.shareGuestPath(share.guestPath) }
            guard guestPaths.insert(g).inserted else { throw ValidationError.duplicateGuestPath(g) }
        }

        var bindings = Set<String>()
        for rule in forwards {
            switch rule.kind {
            case .local, .remote, .socks:
                guard let hp = rule.hostPort, rule.kind == .socks || rule.guestPort != nil else {
                    throw ValidationError.incompleteForward
                }
                for p in [hp, rule.guestPort].compactMap({ $0 }) where !(1...65535).contains(p) {
                    throw ValidationError.port(p)
                }
                guard Self.isIPLiteral(rule.hostAddress) else { throw ValidationError.hostAddress(rule.hostAddress) }
                if rule.kind != .socks {
                    guard Self.isIPLiteral(rule.guestHost) || Self.isHostName(rule.guestHost) else {
                        throw ValidationError.hostAddress(rule.guestHost)
                    }
                }
                if rule.bindsOnHost {
                    guard hp >= 1024 else { throw ValidationError.privilegedHostPort(hp) }
                    let key = "\(rule.hostAddress):\(hp)"
                    guard bindings.insert(key).inserted else { throw ValidationError.duplicateHostBinding(key) }
                }
            case .unixLocal, .unixRemote:
                guard let hs = rule.hostSocket, let gs = rule.guestSocket else { throw ValidationError.incompleteForward }
                for p in [hs, gs] where !p.hasPrefix("/") || p.contains(":") || p.contains(where: \.isWhitespace)
                    || Self.hasControl(p) {
                    throw ValidationError.socketPath(p)
                }
                if rule.bindsOnHost {
                    guard bindings.insert(hs).inserted else { throw ValidationError.duplicateHostBinding(hs) }
                }
            }
        }

        try validateBridges()

        guard autoForward.minimumPort >= 1024 else { throw ValidationError.autoForwardMinimum(autoForward.minimumPort) }
        // Theme ids (themes themselves are the app's business, not MonadHost's).
        if let t = theme, t.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) == nil {
            throw ValidationError.theme(t)
        }
    }
}

// MARK: - Changes

/// What editing a VM's settings means: most apply live, hardware applies at
/// the next boot, and what the disk was provisioned with cannot change.
enum ConfigChange {
    /// Settings the running VM keeps until it restarts, by display name.
    static func restartOnly(from old: InstanceConfig, to new: InstanceConfig) -> [String] {
        differences(old, new, [
            ("CPUs", { $0.cpus == $1.cpus }),
            ("memory", { $0.memoryGiB == $1.memoryGiB }),
            ("network", { $0.networks == $1.networks }),
            ("folder sharing", { $0.sharing.runtimeEnabled == $1.sharing.runtimeEnabled }),
            ("System Integrity Protection", { $0.systemIntegrityProtection == $1.systemIntegrityProtection }),
            ("full disk access", { $0.fullDiskAccess == $1.fullDiskAccess }),
            ("automatic login", { $0.autoLogin == $1.autoLogin }),
            ("boot to recovery", { $0.bootToRecovery == $1.bootToRecovery }),
        ])
    }

    /// Settings fixed when the VM is created, by display name.
    static func fixed(from old: InstanceConfig, to new: InstanceConfig) -> [String] {
        differences(old, new, [
            ("name", { $0.name == $1.name }),
            ("distribution", { $0.distro == $1.distro }),
            ("release", { $0.release == $1.release }),
            ("base image", { $0.image == $1.image }),
            ("user", { $0.user == $1.user }),
            ("disk size", { $0.diskGiB == $1.diskGiB }),
            ("Lima VM", { $0.attached == $1.attached }),
            ("copied from Lima", { $0.copiedFrom == $1.copiedFrom }),
            ("ephemeral", { $0.ephemeral == $1.ephemeral }),
            ("creation date", { $0.createdAt == $1.createdAt }),
            ("parent", { $0.parent == $1.parent }),
            ("guest OS", { $0.guestOS == $1.guestOS }),
        ])
    }

    /// Every setting an edit changed, by display name (for the debug log).
    static func all(from old: InstanceConfig, to new: InstanceConfig) -> [String] {
        differences(old, new, [
            ("name", { $0.name == $1.name }),
            ("distribution", { $0.distro == $1.distro }),
            ("release", { $0.release == $1.release }),
            ("base image", { $0.image == $1.image }),
            ("user", { $0.user == $1.user }),
            ("CPUs", { $0.cpus == $1.cpus }),
            ("memory", { $0.memoryGiB == $1.memoryGiB }),
            ("memory target", { $0.memoryTargetGiB == $1.memoryTargetGiB }),
            ("disk size", { $0.diskGiB == $1.diskGiB }),
            ("network", { $0.networks == $1.networks }),
            ("firewall", { $0.firewall == $1.firewall }),
            ("folder sharing", { $0.sharing.runtimeEnabled == $1.sharing.runtimeEnabled }),
            ("shared folders", { $0.sharing.shares == $1.sharing.shares }),
            ("forwards", { $0.forwards == $1.forwards }),
            ("bridges", { $0.bridges == $1.bridges }),
            ("host commands", { $0.hostCommands == $1.hostCommands }),
            ("agent access", { $0.agents == $1.agents }),
            ("parent", { $0.parent == $1.parent }),
            ("group", { $0.group == $1.group }),
            ("auto-forward", { $0.autoForward == $1.autoForward }),
            ("profiles", { $0.profiles == $1.profiles }),
            ("theme", { $0.theme == $1.theme }),
            ("start at boot", { $0.startAtLaunch == $1.startAtLaunch }),
            ("inline images", { $0.inlineImages == $1.inlineImages }),
            ("System Integrity Protection", { $0.systemIntegrityProtection == $1.systemIntegrityProtection }),
            ("full disk access", { $0.fullDiskAccess == $1.fullDiskAccess }),
            ("automatic login", { $0.autoLogin == $1.autoLogin }),
            ("boot to recovery", { $0.bootToRecovery == $1.bootToRecovery }),
            ("auto-fill", { $0.desktopAutofill == $1.desktopAutofill }),
            ("Lima VM", { $0.attached == $1.attached }),
            ("copied from Lima", { $0.copiedFrom == $1.copiedFrom }),
            ("ephemeral", { $0.ephemeral == $1.ephemeral }),
            ("creation date", { $0.createdAt == $1.createdAt }),
        ])
    }

    private static func differences(_ old: InstanceConfig, _ new: InstanceConfig,
                                    _ checks: [(String, (InstanceConfig, InstanceConfig) -> Bool)]) -> [String] {
        checks.filter { !$0.1(old, new) }.map(\.0)
    }
}

// MARK: - Copies

extension InstanceConfig {
    /// A copy's settings: the same, but for what was allowed for this VM
    /// alone (shared folders, bridges, host commands, forwards into the
    /// Mac or open to other computers, an agent role), which is left out and
    /// named. Its network cards
    /// get new addresses; it does not start with Monad.
    func copy(named name: String) -> (config: InstanceConfig, left: [String]) {
        var c = self
        c.name = name
        var left: [String] = []
        if !c.sharing.shares.isEmpty { left.append("shared folders") }
        if !c.bridges.isEmpty { left.append("bridges") }
        if !c.hostCommands.isEmpty { left.append("host commands") }
        if c.forwards.contains(where: \.reachesIntoHost) { left.append("forwards into the Mac") }
        if c.forwards.contains(where: \.opensToNetwork) { left.append("forwards open to other computers") }
        if c.agents != nil { left.append("its agent role") }
        c.sharing.shares = []
        c.bridges = []
        c.hostCommands = []
        c.forwards.removeAll(where: \.needsConfirmation)
        c.agents = nil
        c.parent = nil
        c.ephemeral = false
        c.startAtLaunch = false
        for i in c.networks.indices { c.networks[i].macAddress = nil }
        return (c, left)
    }

    /// The first free name for a copy of `name`: name-2, name-3… (shortened
    /// to stay a valid name). `taken` is compared in any case, as the Mac's disk does.
    static func copyName(of name: String, taken: [String]) -> String {
        let used = Set(taken.map { $0.lowercased() })
        var n = 2
        while true {
            let suffix = "-\(n)"
            let candidate = String(name.prefix(32 - suffix.count)) + suffix
            if !used.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }
}
