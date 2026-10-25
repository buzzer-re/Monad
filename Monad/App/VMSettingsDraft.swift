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
    static let inlineImagesDetail = "Programs in the VM can show pictures in its tabs, as neofetch, fastfetch and imgcat do (iTerm2's inline images: PNG, JPEG or GIF). Off: Monad never decodes image data the VM sends."

    // MARK: Forwards

    /// One line per rule, in words: whose port or socket it is, and where
    /// it is reached.
    static func describe(_ rule: ForwardRule) -> String {
        func at(_ address: String, _ port: Int?) -> String {
            let a = address.contains(":") ? "[\(address)]" : address
            return "\(a):\(port.map(String.init) ?? "?")"
        }
        let host = at(rule.hostAddress, rule.hostPort), guest = at(rule.guestHost, rule.guestPort)
        let hostPort = rule.hostPort.map(String.init) ?? "?", guestPort = rule.guestPort.map(String.init) ?? "?"
        let hostSocket = rule.hostSocket ?? "?", guestSocket = rule.guestSocket ?? "?"
        switch rule.kind {
        case .remote: return "Mac port \(hostPort), in the VM at \(guest)"
        case .local: return "VM port \(guestPort), on the Mac at \(host)"
        case .socks: return "SOCKS proxy on the Mac at \(host)"
        case .unixLocal: return "VM socket \(guestSocket), on the Mac at \(hostSocket)"
        case .unixRemote: return "Mac socket \(hostSocket), in the VM at \(guestSocket)"
        }
    }

    /// A port forward as typed: `intoVM`, a port of this Mac reached from
    /// the VM (at the same port when `vmPort` is empty); else a port of the
    /// VM reached on the Mac. nil until the ports are numbers.
    static func portForward(macPort: String, vmPort: String, intoVM: Bool) -> ForwardRule? {
        let mac = Int(macPort.trimmingCharacters(in: .whitespaces))
        let typed = vmPort.trimmingCharacters(in: .whitespaces)
        let vm = typed.isEmpty && intoVM ? mac : Int(typed)
        guard let mac, let vm else { return nil }
        return ForwardRule(kind: intoVM ? .remote : .local, hostPort: mac, guestPort: vm)
    }

    /// The same forward the other way round (a Mac port into the VM, or a
    /// VM port onto the Mac); SOCKS and sockets stay as they are.
    static func turnedAround(_ rule: ForwardRule) -> ForwardRule {
        var r = rule
        switch rule.kind {
        case .local: r.kind = .remote
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

    /// What to confirm before adding a forward into the Mac (the VM reaches
    /// something on it); nil for forwards that only reach the VM.
    static func confirmation(for rule: ForwardRule) -> String? {
        switch rule.kind {
        case .remote: return "The VM will be able to connect to port \(rule.hostPort.map(String.init) ?? "?") on this Mac."
        case .unixRemote: return "The VM will be able to connect to \(rule.hostSocket ?? "?") on this Mac."
        case .local, .socks, .unixLocal: return nil
        }
    }

    /// What MonadHost reports for a configured rule, if it is set up.
    static func status(of rule: ForwardRule, in statuses: [ForwardStatus]) -> ForwardStatus? {
        let spec = SSHMux.spec(rule)
        return statuses.first { $0.flag == spec.flag && $0.spec == spec.value }
    }

    private static func text(_ ports: [Int]) -> String {
        ports.map(String.init).joined(separator: ", ")
    }

    private static func ports(_ text: String) throws -> [Int] {
        try text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { token in
            guard let p = Int(token), (1...65535).contains(p) else {
                throw MonadError("“\(token)” is not a port number (1–65535).")
            }
            return p
        }
    }
}
