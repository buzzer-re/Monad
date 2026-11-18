//
//  VMSettingsDraft.swift — the settings a VM detail window edits: a copy of
//  the saved config, validated before it goes to MonadHost, with a preview
//  of what only takes effect after a restart.
//

import Foundation

struct VMSettingsDraft {
    /// The config as MonadHost last reported it.
    private(set) var original: InstanceConfig
    var config: InstanceConfig
    /// Auto-forward ports to skip, as typed ("5432, 6379").
    var ignoredPortsText: String
    /// The firewall's own rules, with their ports as typed; the switches and
    /// tags are edited in `config.firewall`.
    var firewallRules: FirewallRulesEditor
    /// The App windows profile was ticked by turning Display on, not by the user.
    private var displayAddedProfile = false

    init(_ config: InstanceConfig) {
        original = config
        self.config = config
        ignoredPortsText = Self.text(config.autoForward.ignoredPorts)
        firewallRules = FirewallRulesEditor(rules: config.firewall.rules)
    }

    var isDirty: Bool {
        var c = config
        c.firewall.rules = original.firewall.rules
        return c != original || ignoredPortsText != Self.text(original.autoForward.ignoredPorts)
            || firewallRules.differs(from: original.firewall.rules)
    }

    /// Edits a running VM only picks up when it restarts.
    var appliesAfterRestart: [String] { ConfigChange.restartOnly(from: original, to: config) }

    /// Turning the network back on restores the VM's own NIC (and MAC).
    var networkEnabled: Bool {
        get { !config.networks.isEmpty }
        set {
            guard newValue != networkEnabled else { return }
            if !newValue {
                config.networks = []
            } else if original.networks.isEmpty {
                config.networks = [NetworkAttachment(network: NetworkDefinition.defaultName, macAddress: nil)]
            } else {
                config.networks = original.networks
            }
        }
    }

    /// The network the VM's NIC is on (a Monad network, or "nat" for Apple's
    /// NAT on VMs made before Monad networks); nil: no network device. The VM
    /// keeps its MAC whichever network it joins.
    var networkName: String? {
        get { config.networks.first?.network }
        set {
            guard newValue != networkName else { return }
            guard let name = newValue else {
                config.networks = []
                return
            }
            let mac = config.networks.first?.macAddress ?? original.networks.first?.macAddress
            config.networks = [NetworkAttachment(network: name, macAddress: mac)]
        }
    }

    /// Chooses a profile for the VM (kept in the order chosen); a running VM
    /// sets up a newly chosen one as soon as the settings are saved.
    mutating func setProfile(_ id: String, on: Bool) {
        if on {
            if !config.profiles.contains(id) { config.profiles.append(id) }
        } else {
            config.profiles.removeAll { $0 == id }
        }
    }

    /// Display, on or off (it applies at the next start). A display with
    /// nothing set up to show on it shows nothing, so the Desktop profile
    /// is chosen with it where it can be set up (`offered`: the profiles
    /// there are for this VM's distribution), and taken back with it.
    mutating func setDisplay(_ on: Bool, offered: [String]) {
        config.display = on
        displayAddedProfile = Self.displayChanged(to: on, profiles: &config.profiles, offered: offered, addedBefore: displayAddedProfile)
    }

    /// What the settings say under Display.
    var displayNote: String? { Self.displayNote(display: config.display, profiles: config.profiles, added: displayAddedProfile) }

    /// Share a Mac folder read-only in the user's home in the guest.
    /// `confirmed`: the user agreed to a folder SharePolicy guards.
    mutating func addShare(hostPath: String, confirmed: Bool = false) {
        let name = URL(fileURLWithPath: hostPath).lastPathComponent
        config.sharing.runtimeEnabled = true
        var share = SharedFolder(hostPath: hostPath, guestPath: "\(config.home)/\(name)", readOnly: true)
        if confirmed { share.confirmed = true }
        config.sharing.shares.append(share)
    }

    /// What SharePolicy says about sharing this folder (read-only, as added),
    /// judged by where it really leads (a link in the home folder may point
    /// anywhere).
    static func shareVerdict(_ hostPath: String, places: SharePolicy.Places = .mac) -> SharePolicy.Verdict {
        SharePolicy.verdict(SharePolicy.resolve(hostPath), readOnly: true, places: places)
    }

    /// Folders outside the user's home, the whole home, and keys are only
    /// shared after the user confirms.
    static func needsConfirmation(share hostPath: String, home: String) -> Bool {
        shareVerdict(hostPath, places: .init(home: home, monad: home + "/.monad")) != .fine
    }

    /// Repair Disk's confirmation: what it does and leaves.
    static let repairDiskText = "Monad starts a temporary VM of the same distribution, attaches this VM's disk to it "
        + "once it runs, and checks each filesystem with the distribution's own tools (e2fsck, fsck.vfat, xfs_repair, "
        + "btrfs), repairing what they can. A copy of the disk as it is now is kept first, as disk.before-repair.raw in "
        + "the VM's folder. It takes a few minutes and needs the distribution's image, downloaded if Monad no longer has "
        + "it. The VM's log has every step."

    static let confirmShareText = "This folder is outside your home folder, is your whole home folder, or holds keys "
        + "and app data (~/.ssh, ~/Library). The VM will be able to read it, and to change it if you turn off Read-only. "
        + "Your whole home folder reaches the VM as its visible folders only: no hidden folders (~/.ssh, Monad's own), "
        + "no Library, no loose files."

    /// The config to send, or the reason it cannot be sent. `tags`: the
    /// firewall tags there are, whose rules count towards netd's limit.
    func build(maxCPUs: Int, maxMemoryGiB: Int, tags: [FirewallTag] = []) throws -> InstanceConfig {
        var c = config
        c.autoForward.ignoredPorts = try Self.ports(ignoredPortsText)
        c.firewall.rules = try firewallRules.validatedRules()
        try c.validate(maxCPUs: maxCPUs, maxMemoryGiB: maxMemoryGiB)
        try Firewall.checkSize(c.firewall, tags: tags)
        return c
    }

    /// MonadHost reported a new config: take it unless there are unsaved edits.
    mutating func refresh(from latest: InstanceConfig) {
        guard latest != original else { return }
        if isDirty {
            original = latest
        } else {
            self = VMSettingsDraft(latest)
        }
    }

    /// The draft was sent and accepted.
    mutating func saved(_ config: InstanceConfig) {
        self = VMSettingsDraft(config)
    }

    // MARK: Restart

    /// What to ask after saving when a running VM needs a restart for some of it.
    static func restartPrompt(vm: String, pending: [String], isRunning: Bool) -> (title: String, message: String)? {
        guard isRunning, !pending.isEmpty else { return nil }
        let list: String
        switch pending.count {
        case 1: list = pending[0]
        default: list = pending.dropLast().joined(separator: ", ") + " and " + pending.last!
        }
        let noun = pending.count == 1 ? "setting is" : "settings are"
        return ("Restart “\(vm)” now?",
                "The new \(list) \(noun) applied when the VM restarts. Programs running in the VM will be stopped.")
    }

    // MARK: Security (macOS)

    /// Asked when SIP is switched off (the Security page, the New VM sheet).
    static func disableSIPConfirmation(vm: String, newVM: Bool) -> (title: String, message: String) {
        let when = newVM ? "Once “\(vm)” is made, it starts" : "At its next start, “\(vm)” starts"
        return ("Disable System Integrity Protection?",
                "\(when) in macOS recovery by itself, turns System Integrity Protection off there, and restarts into "
                    + "macOS. It takes a few minutes, and you don't need to do anything. Turning it back on later needs "
                    + "the internet in the VM.")
    }

    /// SIP, in the New VM sheet and on the Security page.
    static let sipDetail = "Keeps macOS's own files and processes safe, even from root. Off, tools that change the "
        + "system work in this VM: kernel extensions, DTrace, edits to system files."

    /// Full disk access, in the New VM sheet and on the Security page.
    static let fullDiskAccessDetail = "Monad's sessions (its tabs, and exec and files for agents) can read protected "
        + "folders such as Documents and Desktop, as Remote Login's \u{201C}Allow full disk access\u{201D} does."

    /// Asked the first time a macOS VM's desktop is opened.
    static func autofillQuestion(vm: String, user: String) -> (title: String, message: String) {
        ("Fill in the password on “\(vm)”?",
         "Its account “\(user)” has a password Monad made; Show on the VM's Overview reveals it. With auto-fill, "
            + "Monad types it whenever the desktop asks for it (an installer, System Settings, the lock screen). "
            + "You can change this on the VM's Security page.")
    }

    static let bootToRecoveryDetail = "The next start opens macOS Recovery and its desktop, for Disk Utility, Terminal "
        + "or Startup Security. Restarting or shutting down there starts macOS as usual."
    static let autoLoginDetail = "Starts at its desktop, without the login window. Applies at the next start."
    static let autofillDetail = "Monad types the account's password whenever the desktop asks for it "
        + "(an installer, System Settings, the lock screen)."

    /// The tag in the Virtual Machines list: SIP as the VM said at its last
    /// start (`csrutil status`), so it changes only once a change took.
    static func sipTag(_ report: MacSecurityReport?) -> String? {
        switch report?.sip {
        case "enabled": return "SIP: On"
        case "disabled": return "SIP: Off"
        default: return nil
        }
    }

    /// How SIP was found, in words.
    static func sipFound(_ report: MacSecurityReport?) -> String {
        switch report?.sip {
        case nil: return "Not known yet: it is read each time the VM starts."
        case "enabled": return "On, as found when the VM last started."
        case "disabled": return "Off, as found when the VM last started."
        case ""?: return "macOS answered something Monad does not understand."
        case let other?: return "macOS says: \(other)."
        }
    }

    /// Images in the terminal (inlineImages), in the New VM sheet and the
    /// VM's settings.
    static let inlineImagesDetail = "Programs in the VM can show pictures in its tabs, as img (in every VM), neofetch, fastfetch and imgcat do (iTerm2's inline images: PNG, JPEG or GIF). Off: Monad never decodes image data the VM sends."

    /// A Linux VM's display (display), in the New VM sheet and the VM's
    /// settings.
    static let displayDetail = "A display, a keyboard and a pointer for the VM, for a desktop: its ⋯ menu's Open Desktop shows it in a window on this Mac. What is on it is drawn by the VM's CPUs (Apple passes no GPU to a Linux VM). Off: the VM has none of the three devices. Programs as windows of their own need none of them. Applies at the next start."

    /// The profile that puts something on a Linux VM's display: a desktop,
    /// in one window. (The VM's programs as windows of their own, the App
    /// windows profile, need no display.)
    static let displayProfile = "desktop"

    static let displayProfileAdded = "The Desktop profile was added with it: the VM then has a desktop, which its ⋯ menu's Open Desktop shows in a window on this Mac. Programs as windows of their own (the App windows profile) need no display."
    static let displayNeedsProfile = "Nothing is set up to show on the display. The Desktop profile gives the VM a desktop (for distributions with apt). Programs as windows of their own (the App windows profile) need no display."

    /// A display without the profile shows nothing.
    static func displayLacksProfile(display: Bool, profiles: [String]) -> Bool {
        display && !profiles.contains(displayProfile)
    }

    /// Display was turned on or off. On, with nothing chosen to show on
    /// it: the Desktop profile is added where it can be set up
    /// (`offered`), and true says so. Off: what was added for it
    /// (`addedBefore`) goes again; what the user chose stays.
    static func displayChanged(to on: Bool, profiles: inout [String], offered: [String], addedBefore: Bool) -> Bool {
        if on {
            guard displayLacksProfile(display: true, profiles: profiles), offered.contains(displayProfile) else { return false }
            profiles.append(displayProfile)
            return true
        }
        if addedBefore { profiles.removeAll { $0 == displayProfile } }
        return false
    }

    /// What to say under Display: that a profile was added with it, or
    /// that nothing is set up to show on it; nil when there is nothing to say.
    static func displayNote(display: Bool, profiles: [String], added: Bool) -> String? {
        guard display else { return nil }
        if displayLacksProfile(display: true, profiles: profiles) { return displayNeedsProfile }
        return added ? displayProfileAdded : nil
    }

    // MARK: Forwards

    /// Whose a forward's far end is: a VM's, or an SSH host's own (the
    /// same rules, with the server in the VM's place).
    enum ForwardSide {
        case vm, server

        /// "VM port", "Server port".
        var noun: String { self == .vm ? "VM" : "Server" }
        /// Where its end is: "in the VM", "on the server".
        var inside: String { self == .vm ? "in the VM" : "on the server" }
        var name: String { self == .vm ? "the VM" : "the server" }
    }

    /// One line per rule, in words: whose port or socket it is, and where
    /// it is reached.
    static func describe(_ rule: ForwardRule, side: ForwardSide = .vm) -> String {
        func at(_ address: String, _ port: Int?) -> String {
            let a = address.contains(":") ? "[\(address)]" : address
            return "\(a):\(port.map(String.init) ?? "?")"
        }
        let host = at(rule.hostAddress, rule.hostPort), guest = at(rule.guestHost, rule.guestPort)
        let hostPort = rule.hostPort.map(String.init) ?? "?", guestPort = rule.guestPort.map(String.init) ?? "?"
        let hostSocket = rule.hostSocket ?? "?", guestSocket = rule.guestSocket ?? "?"
        let open = rule.opensToNetwork ? ", open to other computers" : ""
        switch rule.kind {
        case .remote: return "Mac port \(hostPort), \(side.inside) at \(guest)"
        case .local: return "\(side.noun) port \(guestPort), on the Mac at \(host)\(open)"
        case .socks: return "SOCKS proxy on the Mac at \(host)\(open)"
        case .unixLocal: return "\(side.noun) socket \(guestSocket), on the Mac at \(hostSocket)"
        case .unixRemote: return "Mac socket \(hostSocket), \(side.inside) at \(guestSocket)"
        }
    }

    /// An address "The server reaches" offers, in a VM's forward through an SSH host.
    struct ReachChoice: Equatable {
        var title: String
        var address: String
    }

    /// What the server `server` may be told to reach without typing an
    /// address: itself, then the other SSH hosts by name, at the address
    /// Monad has for them.
    static func reachChoices(through server: String, hosts: [SSHHost]) -> [ReachChoice] {
        [ReachChoice(title: "The server itself (127.0.0.1)", address: "127.0.0.1")]
            + hosts.filter { $0.name != server }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { ReachChoice(title: "\($0.name) (\($0.host))", address: $0.host) }
    }

    /// A port forward as typed: `intoVM`, a port of this Mac reached from
    /// the VM (at the same port when `vmPort` is empty); else a port of the
    /// VM reached on the Mac, listening on `address` (the loopback when
    /// empty). nil until the ports are numbers and the address an IP address.
    static func portForward(macPort: String, vmPort: String, intoVM: Bool, address: String = "") -> ForwardRule? {
        let mac = Int(macPort.trimmingCharacters(in: .whitespaces))
        let typed = vmPort.trimmingCharacters(in: .whitespaces)
        let vm = typed.isEmpty && intoVM ? mac : Int(typed)
        guard let mac, let vm else { return nil }
        if intoVM { return ForwardRule(kind: .remote, hostPort: mac, guestPort: vm) }
        guard let listen = listenAddress(address) else { return nil }
        return ForwardRule(kind: .local, hostAddress: listen, hostPort: mac, guestPort: vm)
    }

    /// A SOCKS proxy on the Mac's port, listening on `address` as above.
    static func socksForward(macPort: String, address: String) -> ForwardRule? {
        guard let port = Int(macPort.trimmingCharacters(in: .whitespaces)), let listen = listenAddress(address) else { return nil }
        return ForwardRule(kind: .socks, hostAddress: listen, hostPort: port)
    }

    /// The Mac address typed for a listener: the loopback when empty.
    private static func listenAddress(_ typed: String) -> String? {
        let a = typed.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return "127.0.0.1" }
        return InstanceConfig.isIPLiteral(a) ? a : nil
    }

    /// The same forward the other way round (a Mac port into the VM, at the
    /// Mac's loopback, or a VM port onto the Mac); SOCKS and sockets stay as
    /// they are.
    static func turnedAround(_ rule: ForwardRule) -> ForwardRule {
        var r = rule
        switch rule.kind {
        case .local:
            r.kind = .remote
            r.hostAddress = "127.0.0.1"
        case .remote: r.kind = .local
        case .socks, .unixLocal, .unixRemote: break
        }
        return r
    }

    /// The words for deleting a VM, from its menu to the confirmation.
    struct Removal: Equatable {
        var menu: String
        var title: String
        var button: String
        var message: String
    }

    /// A Lima VM is only removed from Monad: VMManager.delete removes
    /// Monad's folder for it, never Lima's.
    static func removal(for config: InstanceConfig) -> Removal {
        guard let lima = config.attached?.instance else {
            return Removal(menu: "Delete…", title: "Delete “\(config.name)”?", button: "Delete VM and Disk",
                           message: "The VM is stopped and its disk and keys are permanently removed.")
        }
        return Removal(menu: "Remove from Monad…", title: "Remove “\(config.name)” from Monad?", button: "Remove from Monad",
                       message: "The VM is stopped and Monad forgets it. The Lima VM “\(lima)” and its disk stay as they are.")
    }

    /// What a Lima VM's window says about the disk it shares with Lima.
    /// Monad cannot stop Lima from starting it, so the warning matters.
    static func limaNotes(for config: InstanceConfig) -> (shared: String, warning: String)? {
        guard let lima = config.attached?.instance else { return nil }
        return ("Shared with the Lima VM “\(lima)”. Monad boots its disk where it is, and Lima can use it again whenever Monad does not run it.",
                "Do not start “\(lima)” in Lima while Monad runs it. Both would write to the same disk.")
    }

    // MARK: Bridges (Phase 12)

    /// A bridge's program as typed: a full path as it is, a bare name found
    /// on `path` (":"-separated folders); it must be a program that runs.
    /// MonadHost runs it by that path, never through a shell.
    static func resolveProgram(_ typed: String, path: String,
                               isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        let name = typed.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if name.hasPrefix("/") { return isExecutable(name) ? name : nil }
        guard !name.contains("/") else { return nil }
        return path.split(separator: ":").map { "\($0)/\(name)" }.first(where: isExecutable)
    }

    /// A bridge's arguments as typed: separated by spaces, no quoting.
    static func arguments(_ typed: String) -> [String] {
        typed.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// What adding a bridge lets the VM do, asked before it is added.
    static func confirmation(for bridge: CommandBridge) -> String {
        "The VM will be able to run “\(bridge.command.joined(separator: " "))” on this Mac, as you. "
            + "Each connection to \(bridge.guestEndpoint) in the VM runs it once, with what the VM sends as its input."
    }

    /// A bridge's state while the VM runs: that of its remote forward (nil
    /// when it is not serving).
    static func status(of bridge: CommandBridge, in forwards: [ForwardStatus], paths: InstancePaths) -> ForwardStatus.State? {
        let spec = bridge.spec(in: paths)
        return forwards.first { $0.origin == .bridge && $0.flag == spec.flag && $0.spec == spec.value }?.state
    }

    mutating func addBridge(_ bridge: CommandBridge) {
        config.bridges.append(bridge)
    }

    /// What a copy of a Lima VM's window says about where it came from.
    static func copyNote(for config: InstanceConfig) -> String? {
        config.copiedFrom.map {
            "Copied from the Lima VM “\($0.instance)”. This VM has a disk of its own: changes do not reach Lima, and Lima's do not reach it."
        }
    }

    /// Shown under a share the VM can write: what it can do there (F-14,
    /// docs/SECURITY.md). Read-only shares need no note.
    static func note(for share: SharedFolder) -> String? {
        share.readOnly ? nil
            : "The VM can change and replace files here, including with links that Mac programs will follow."
    }

    /// What to confirm before adding a forward into the Mac (the VM, or
    /// whoever is on the server, reaches something on it) or one open to
    /// other computers; nil for the rest.
    static func confirmation(for rule: ForwardRule, side: ForwardSide = .vm) -> String? {
        let hostPort = rule.hostPort.map(String.init) ?? "?"
        let reach = "Computers that reach this Mac at \(rule.hostAddress) will be able to"
        // A server's end is on the server's loopback: every account there reaches it.
        let who = side == .vm ? "The VM" : "Whoever is on the server"
        switch rule.kind {
        case .remote: return "\(who) will be able to connect to port \(hostPort) on this Mac."
        case .unixRemote: return "\(who) will be able to connect to \(rule.hostSocket ?? "?") on this Mac."
        case .local where rule.opensToNetwork:
            return "\(reach) connect to port \(rule.guestPort.map(String.init) ?? "?") \(side.inside), through port \(hostPort)."
        case .socks where rule.opensToNetwork:
            return "\(reach) use port \(hostPort) as a proxy that leaves from \(side.name)."
        case .local, .socks, .unixLocal: return nil
        }
    }

    /// The question confirmation(for:) answers.
    static func confirmationTitle(for rule: ForwardRule, side: ForwardSide = .vm) -> String {
        rule.reachesIntoHost ? "Let \(side.name) reach this Mac?" : "Open this port to other computers?"
    }

    /// What MonadHost reports for a configured rule, if it is set up.
    static func status(of rule: ForwardRule, in statuses: [ForwardStatus]) -> ForwardStatus? {
        let spec = SSHMux.spec(rule)
        return statuses.first { $0.flag == spec.flag && $0.spec == spec.value }
    }

    // MARK: Forwards through SSH hosts (Monad/SSH)

    /// One line per forward, in words.
    static func describe(_ f: SSHForward) -> String {
        let remote = "\(SSHMux.address(f.remoteHost)):\(f.remotePort)"
        switch f.direction {
        case .intoVM: return "\(remote) through the SSH host \(f.sshHost), in the VM at 127.0.0.1:\(f.guestPort)"
        case .ontoHost: return "VM port \(f.guestPort), on the SSH host \(f.sshHost) at \(remote)"
        }
    }

    /// A forward through `host` as typed: nil until both ports are numbers
    /// and it can be one. An empty `vmPort` for a server port brought into
    /// the VM means the same port; an empty `remoteHost` means 127.0.0.1.
    static func sshForward(host: String, direction: SSHForward.Direction, vmPort: String, remoteHost: String,
                           remotePort: String) -> SSHForward? {
        let remote = Int(remotePort.trimmingCharacters(in: .whitespaces))
        let typed = vmPort.trimmingCharacters(in: .whitespaces)
        let vm = typed.isEmpty && direction == .intoVM ? remote : Int(typed)
        guard let remote, let vm else { return nil }
        let address = remoteHost.trimmingCharacters(in: .whitespaces)
        let forward = SSHForward(sshHost: host, direction: direction, guestPort: vm,
                                 remoteHost: address.isEmpty ? "127.0.0.1" : address, remotePort: remote)
        return forward.problem == nil ? forward : nil
    }

    /// What adding a forward through an SSH host lets happen, asked before
    /// each is added: it passes the VM's firewall, signed in as the user.
    static func confirmation(for f: SSHForward) -> String {
        let remote = "\(SSHMux.address(f.remoteHost)):\(f.remotePort)"
        switch f.direction {
        case .intoVM:
            return "The VM will be able to connect to \(remote) as the SSH host “\(f.sshHost)” reaches it, "
                + "signed in as you there, past the VM's firewall."
        case .ontoHost:
            return "Whoever reaches \(remote) on the SSH host “\(f.sshHost)” will be able to connect to port \(f.guestPort) in the VM."
        }
    }

    static let sshForwardConfirmationTitle = "Connect the VM and the SSH host?"

    /// A forward's state while the VM runs: both its halves. nil when the
    /// VM's half is not set up (the VM is not running it); the VM's half
    /// failed, that; else the SSH host's half, as its master reports it.
    static func status(of f: SSHForward, in forwards: [ForwardStatus], hosts: [SSHHostSnapshot],
                       paths: InstancePaths) -> ForwardStatus.State? {
        let vm = f.vmSpec(in: paths)
        guard let own = forwards.first(where: { $0.origin == .bridge && $0.flag == vm.flag && $0.spec == vm.value })?.state else {
            return nil
        }
        if case .failed = own { return own }
        guard let host = hosts.first(where: { $0.config.name == f.sshHost }) else {
            return .failed("There is no SSH host named \(f.sshHost).")
        }
        let far = f.hostSpec(in: paths)
        return (host.forwards ?? []).first { $0.flag == far.flag && $0.spec == far.value }?.state ?? .failed("Not set up yet.")
    }

    /// Ports as a field shows them ("5432, 6379"), and as typed there.
    static func text(_ ports: [Int]) -> String {
        ports.map(String.init).joined(separator: ", ")
    }

    static func ports(_ text: String) throws -> [Int] {
        try text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { token in
            guard let p = Int(token), (1...65535).contains(p) else {
                throw MonadError("“\(token)” is not a port number (1–65535).")
            }
            return p
        }
    }
}
