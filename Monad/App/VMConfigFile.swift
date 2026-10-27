//
//  VMConfigFile.swift — a VM's settings as a file, like libvirt's domain
//  XML: the VM window's Configuration page shows and exports them (a
//  backup), the Virtual Machines window imports one as a new VM (a script
//  can write them too). The format is instance.json's own, documented field
//  by field in docs/CONFIG.md.
//
//  An imported file is untrusted. It is checked as the New VM sheet's
//  settings are, made to fit this Mac (each change said), and what reaches
//  into the Mac (shared folders, bridges, forwards into the Mac, the Mac
//  and its network reachable, images it sends decoded on the Mac) stays out
//  unless the user keeps it. A folder
//  that needs the user's word is never brought in: the VM's settings ask.
//

import Foundation

enum VMConfigFile {
    /// Far more than any VM's settings (a few KB).
    static let maxBytes = 256 << 10

    /// The VM's settings as saved (instance.json: pretty, sorted keys).
    static func export(_ config: InstanceConfig) throws -> Data {
        try config.encoded()
    }

    static func fileName(for config: InstanceConfig) -> String { "\(config.name).monad.json" }

    /// What this Mac has, for fitting a file to it.
    struct Mac {
        /// VM names in use (any case: the disk does not tell them apart).
        var takenNames: Set<String>
        var networks: Set<String>
        var distros: Set<String>
        var maxCPUs: Int
        var maxMemoryGiB: Int
        var places: SharePolicy.Places

        /// This Mac, with the VMs `taken` already has.
        static func current(taken: [String]) -> Mac {
            let capacity = HostCapacity.current
            return Mac(takenNames: Set(taken), networks: Set(((try? NetworkStore().all()) ?? []).map(\.name)),
                       distros: Set(DistroCatalog.live?.distros.map(\.id) ?? []), maxCPUs: capacity.maxCPUs,
                       maxMemoryGiB: capacity.maxMemoryGiB, places: .mac)
        }
    }

    /// Why the import sheet cannot make a VM called `name`, if it cannot.
    static func nameProblem(_ name: String, taken: Set<String>) -> String? {
        guard InstanceConfig.isValidName(name) else { return "Use letters, digits and dashes (at most 32)." }
        guard !taken.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            return "A VM named “\(name)” exists."
        }
        return nil
    }

    /// The file at `url`, read only if it is small enough to be a VM's
    /// settings.
    static func load(_ url: URL, on mac: Mac) throws -> Imported {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else {
            throw MonadError("The file is too large to be a VM's settings (more than \(maxBytes >> 10) KB).")
        }
        return try read(Data(contentsOf: url), on: mac)
    }

    /// What reaches into this Mac, kept only when the user says so.
    struct MacAccess: Equatable {
        var shares: [SharedFolder] = []
        var bridges: [CommandBridge] = []
        var hostCommands: [HostCommand] = []
        /// What the VM may do with Monad itself.
        var agents: AgentAccess?
        /// Forwards that let the VM reach the Mac.
        var forwards: [ForwardRule] = []
        /// The Mac and its local network reachable without a rule.
        var allowLAN = false
        /// Images the VM sends decoded on the Mac (inlineImages).
        var images = false
        /// Allow rules by address: they may open the Mac and its network
        /// without allowLAN (an address the user typed may).
        var firewallRules: [FirewallRule] = []

        var isEmpty: Bool {
            shares.isEmpty && bridges.isEmpty && hostCommands.isEmpty && agents == nil && forwards.isEmpty && !allowLAN && !images
                && firewallRules.isEmpty
        }

        /// One line each, in the VM window's words.
        var lines: [String] {
            shares.map { "Shared folder \($0.hostPath) at \($0.guestPath) in the VM, \($0.readOnly ? "read-only" : "read and write")" }
                + bridges.map { "Bridge \($0.name): \($0.command.joined(separator: " ")) at \($0.guestEndpoint) in the VM" }
                + hostCommands.map {
                    "Host command \($0.name): \(([$0.program] + $0.fixedArguments).joined(separator: " "))"
                        + $0.arguments.map { " ‹\($0.name) \($0.pattern)›" }.joined() + " in \($0.workingDirectory), at \($0.guestEndpoint) in the VM"
                }
                + (agents.map { ["Monad access (\($0.role.rawValue)): \($0.summary)"] } ?? [])
                + forwards.map(VMSettingsDraft.describe)
                + (allowLAN ? ["The Mac and its local network are reachable from the VM"] : [])
                + (images ? ["Images the VM sends are decoded on this Mac and shown in its tabs"] : [])
                + firewallRules.map { "The firewall allows the VM " + ConnectionsModel.describe($0).dropFirst("Allow ".count) }
        }
    }

    struct Imported: Equatable {
        /// The settings to make, without what reaches into the Mac (or lets
        /// other computers reach the VM).
        var config: InstanceConfig
        var macAccess: MacAccess
        /// What changed to make the file a new VM on this Mac.
        var notes: [String]
        /// The file's forwards, in its order.
        fileprivate var forwards: [ForwardRule]
        /// The file's firewall rules, in their order.
        fileprivate var rules: [FirewallRule]

        /// The VM to make: named `name`, with what reaches into the Mac when
        /// the user keeps it.
        func config(named name: String, keepingMacAccess keep: Bool) -> InstanceConfig {
            var c = config
            c.name = name
            guard keep else { return c }
            c.sharing.shares = macAccess.shares
            if !macAccess.shares.isEmpty { c.sharing.runtimeEnabled = true }
            c.bridges = macAccess.bridges
            c.hostCommands = macAccess.hostCommands
            c.agents = macAccess.agents
            c.forwards = forwards
            c.firewall.allowLAN = macAccess.allowLAN
            c.inlineImages = macAccess.images
            c.firewall.rules = rules
            return c
        }
    }

    /// The settings in `data` as a new VM on `mac`, or why they cannot be one.
    static func read(_ data: Data, on mac: Mac) throws -> Imported {
        guard data.count <= maxBytes else {
            throw MonadError("The file is too large to be a VM's settings (more than \(maxBytes >> 10) KB).")
        }
        var c: InstanceConfig
        do {
            c = try InstanceConfig.decode(data)
        } catch let newer as InstanceConfig.DecodingProblem {
            throw newer
        } catch {
            throw MonadError("This file is not a Monad VM's settings: it needs at least \"version\": 2, a \"name\" "
                + "and a \"distro\". docs/CONFIG.md describes them.")
        }
        var notes: [String] = []

        // A new VM, made now from a fresh image.
        if !InstanceConfig.isValidName(c.name) {
            notes.append("“\(c.name)” is not a VM name (letters, digits and dashes, at most 32).")
            c.name = "imported"
        }
        let free = unique(c.name, taken: Set(mac.takenNames.map { $0.lowercased() }))
        if free != c.name {
            notes.append("A VM named “\(c.name)” exists. This one is “\(free)”.")
            c.name = free
        }
        c.ephemeral = false
        c.createdAt = InstanceConfig.now()
        c.image = ""
        if let lima = c.attached ?? c.copiedFrom {
            notes.append("The file is for the Lima VM “\(lima.instance)”. This VM is made from a fresh image instead: the Lima VM's disk is not in the file.")
            c.attached = nil
            c.copiedFrom = nil
            c.diskGiB = max(c.diskGiB, 10)
        }
        guard mac.distros.contains(c.distro) else {
            throw MonadError("This Monad does not know the distribution “\(c.distro)”.")
        }

        // Fitted to this Mac.
        if c.networks.contains(where: { $0.macAddress != nil }) {
            notes.append("Its network cards get new MAC addresses, so it never takes another VM's.")
        }
        for i in c.networks.indices {
            c.networks[i].macAddress = nil
            let n = c.networks[i].network
            if !mac.networks.contains(n) && n != NetworkDefinition.appleNATName && n != NetworkAttachment.defaultNAT {
                notes.append("This Mac has no network “\(n)”. The VM joins “\(NetworkDefinition.defaultName)”.")
                c.networks[i].network = NetworkDefinition.defaultName
            }
        }
        if c.cpus > mac.maxCPUs {
            notes.append("\(c.cpus) CPUs is more than this Mac gives a VM: it gets \(mac.maxCPUs).")
            c.cpus = mac.maxCPUs
        }
        if c.memoryGiB > mac.maxMemoryGiB {
            notes.append("\(c.memoryGiB) GB of memory is more than this Mac gives a VM: it gets \(mac.maxMemoryGiB) GB.")
            c.memoryGiB = mac.maxMemoryGiB
        }
        if let t = c.memoryTargetGiB, t > c.memoryGiB { c.memoryTargetGiB = c.memoryGiB }

        // Checked as the New VM sheet's settings, all of them (a file that
        // lists shared folders means sharing on).
        var checked = c
        if !checked.sharing.shares.isEmpty { checked.sharing.runtimeEnabled = true }
        try checked.validate(maxCPUs: mac.maxCPUs, maxMemoryGiB: mac.maxMemoryGiB)

        // What reaches into the Mac, set apart.
        var access = MacAccess(bridges: c.bridges, hostCommands: c.hostCommands, agents: c.agents,
                               forwards: c.forwards.filter(\.needsConfirmation),
                               allowLAN: c.firewall.allowLAN, images: c.inlineImages,
                               firewallRules: c.firewall.rules.filter(\.opensByAddress))
        if c.desktopAutofill != nil {
            notes.append("Auto-fill is asked again when the VM's desktop is first opened.")
            c.desktopAutofill = nil
        }
        for var share in c.sharing.shares {
            share.confirmed = nil
            switch SharePolicy.verdict(SharePolicy.resolve(share.hostPath), readOnly: share.readOnly, places: mac.places) {
            case .fine:
                access.shares.append(share)
            case .needsConfirmation:
                notes.append("The shared folder \(share.hostPath) is left out. Add it in the VM's settings, which ask you first.")
            case .refused(let why):
                notes.append("The shared folder \(share.hostPath) is left out. \(why)")
            }
        }
        let forwards = c.forwards
        let rules = c.firewall.rules
        c.firewall.rules.removeAll(where: \.opensByAddress)
        c.sharing.shares = []
        c.bridges = []
        c.hostCommands = []
        c.agents = nil
        // A VM made from a file is nobody's child.
        c.parent = nil
        c.forwards.removeAll(where: \.needsConfirmation)
        c.firewall.allowLAN = false
        c.inlineImages = false
        return Imported(config: c, macAccess: access, notes: notes, forwards: forwards, rules: rules)
    }

    // MARK: - Editing (the VM window's Configuration page)

    /// Something wrong in edited settings, at a key path ("forwards[0].kind";
    /// empty for the whole file).
    struct Problem: Equatable {
        var path: String
        var message: String
    }

    /// Edited settings, checked as they are typed.
    struct Check: Equatable {
        var problems: [Problem] = []
        /// The settings to save, when there is no problem.
        var config: InstanceConfig?
        /// What saving would change, by display name.
        var changes: [String] = []
        /// What the edit newly lets reach into this Mac: confirmed before saving.
        var reachesIntoMac: [String] = []

        var canApply: Bool { problems.isEmpty && config != nil && !changes.isEmpty }
    }

    /// The keys a VM's settings hold, by where they are (list items share
    /// their list's path). docs/CONFIG.md describes each.
    private static let keys: [String: Set<String>] = [
        "": ["version", "name", "distro", "release", "image", "user", "cpus", "memoryGiB", "memoryTargetGiB", "diskGiB",
             "networks", "firewall", "sharing", "forwards", "autoForward", "profiles", "theme", "ephemeral", "createdAt", "guestOS",
             "startAtLaunch", "inlineImages", "attached", "copiedFrom", "bridges", "hostCommands", "agents", "parent",
             "systemIntegrityProtection", "fullDiskAccess", "autoLogin", "desktopAutofill", "bootToRecovery"],
        "agents": ["role", "guestPort", "maxChildren", "childCPUs", "childMemoryGiB"],
        "networks": ["network", "macAddress"],
        "firewall": ["allowlist", "allowLAN", "monitor", "rules", "tags"],
        "firewall.rules": ["action", "proto", "target", "ports"],
        "sharing": ["runtimeEnabled", "shares"],
        "sharing.shares": ["hostPath", "guestPath", "readOnly", "confirmed"],
        "forwards": ["id", "kind", "hostAddress", "hostPort", "guestHost", "guestPort", "hostSocket", "guestSocket", "enabled"],
        "bridges": ["id", "name", "command", "guestPort", "guestSocket", "enabled"],
        "hostCommands": ["id", "name", "summary", "program", "fixedArguments", "arguments", "workingDirectory",
                         "timeoutSeconds", "results", "environment", "guestPort", "guestSocket", "enabled"],
        "hostCommands.arguments": ["name", "pattern", "required", "summary"],
        "autoForward": ["enabled", "minimumPort", "ignoredPorts"],
        "attached": ["kind", "instance", "dir", "home"],
        "copiedFrom": ["kind", "instance", "dir", "home"],
    ]

    /// Keys Monad does not know (a typo would otherwise be dropped without a
    /// word), each with the one probably meant.
    static func unknownKeys(in object: [String: Any]) -> [Problem] {
        var out: [Problem] = []
        func walk(_ value: Any, schema: String, path: String) {
            if let dict = value as? [String: Any], let known = keys[schema] {
                for key in dict.keys.sorted() {
                    let at = path.isEmpty ? key : path + "." + key
                    guard known.contains(key) else {
                        out.append(Problem(path: at, message: unknownKeyMessage(key, known: known)))
                        continue
                    }
                    walk(dict[key]!, schema: schema.isEmpty ? key : schema + "." + key, path: at)
                }
            } else if let list = value as? [Any] {
                for (i, item) in list.enumerated() { walk(item, schema: schema, path: "\(path)[\(i)]") }
            }
        }
        walk(object, schema: "", path: "")
        return out
    }

    private static func unknownKeyMessage(_ key: String, known: Set<String>) -> String {
        func distance(_ a: String, _ b: String) -> Int {
            let a = Array(a.lowercased()), b = Array(b.lowercased())
            var row = Array(0...b.count)
            for i in 1...max(a.count, 1) where !a.isEmpty {
                var next = [i] + Array(repeating: 0, count: b.count)
                for j in 1...max(b.count, 1) where !b.isEmpty {
                    next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                }
                row = next
            }
            return row[b.count]
        }
        let best = known.map { ($0, distance(key, $0)) }.min { ($0.1, $0.0) < ($1.1, $1.0) }
        if let best, best.1 <= 2 { return "Monad does not know “\(key)”. Did you mean “\(best.0)”?" }
        return "Monad does not know “\(key)”. docs/CONFIG.md lists the keys."
    }

    /// A decoding error, where it is and in words.
    private static func problem(_ error: Error) -> Problem {
        func path(_ keys: [CodingKey]) -> String {
            keys.reduce("") { p, k in
                if let i = k.intValue { return p + "[\(i)]" }
                return p.isEmpty ? k.stringValue : p + "." + k.stringValue
            }
        }
        func describe(_ type: Any.Type) -> String {
            let name = String(describing: type)
            if type == Int.self || type == Double.self { return "a number" }
            if type == String.self { return "text in quotes" }
            if type == Bool.self { return "true or false" }
            if type == Date.self { return "a date like 2026-10-10T12:00:00Z" }
            if name.hasPrefix("Array") { return "a list in [ ]" }
            return "an object in { }"
        }
        switch error as? DecodingError {
        case .typeMismatch(let type, let context)?:
            return Problem(path: path(context.codingPath), message: "Expected \(describe(type)) here.")
        case .valueNotFound(let type, let context)?:
            return Problem(path: path(context.codingPath), message: "Needs \(describe(type)).")
        case .keyNotFound(let key, let context)?:
            return Problem(path: path(context.codingPath + [key]), message: "This key is needed.")
        case .dataCorrupted(let context)?:
            return Problem(path: path(context.codingPath), message: context.debugDescription)
        default:
            return Problem(path: "", message: error.localizedDescription)
        }
    }

    /// Where a validation error is.
    private static func path(of error: Error) -> String {
        switch error as? InstanceConfig.ValidationError {
        case .name?: return "name"
        case .cpus?: return "cpus"
        case .memory?: return "memoryGiB"
        case .memoryTarget?: return "memoryTargetGiB"
        case .disk?: return "diskGiB"
        case .macResources?: return "memoryGiB"
        case .restoreImage?: return "restoreImage"
        case .systemIntegrityProtection?: return "systemIntegrityProtection"
        case .fullDiskAccess?: return "fullDiskAccess"
        case .macOSOnly?: return "autoLogin"
        case .attachedDisk?: return "attached"
        case .sharingDisabled?: return "sharing.runtimeEnabled"
        case .shareHostPath?, .shareGuestPath?, .duplicateGuestPath?: return "sharing.shares"
        case .port?, .privilegedHostPort?, .duplicateHostBinding?, .incompleteForward?, .socketPath?, .hostAddress?:
            return "forwards"
        case .autoForwardMinimum?: return "autoForward.minimumPort"
        case .theme?: return "theme"
        case .user?: return "user"
        case .distro?: return "distro"
        case .release?: return "release"
        case .image?: return "image"
        case .network?, .macAddress?: return "networks"
        case .profile?: return "profiles"
        case .bridgeName?, .bridgeCommand?, .bridgeEndpoint?, .tooManyBridges?, .duplicateGuestEndpoint?: return "bridges"
        case .hostCommand?: return "hostCommands"
        case .agents?: return "agents"
        case .parent?: return "parent"
        case .group?: return "group"
        case nil: return error is Firewall.ValidationError ? "firewall" : ""
        }
    }

    /// Set when the VM was made (ConfigChange.fixed), by key.
    private static let fixedKeys: [(String, (InstanceConfig, InstanceConfig) -> Bool)] = [
        ("name", { $0.name == $1.name }), ("distro", { $0.distro == $1.distro }), ("release", { $0.release == $1.release }),
        ("image", { $0.image == $1.image }), ("user", { $0.user == $1.user }), ("diskGiB", { $0.diskGiB == $1.diskGiB }),
        ("attached", { $0.attached == $1.attached }), ("copiedFrom", { $0.copiedFrom == $1.copiedFrom }),
        ("ephemeral", { $0.ephemeral == $1.ephemeral }), ("createdAt", { $0.createdAt == $1.createdAt }),
        ("parent", { $0.parent == $1.parent }), ("guestOS", { $0.guestOS == $1.guestOS }),
    ]

    /// `text` as the new settings of the VM saved as `saved`: JSON, known
    /// keys, types, values (as on save), nothing fixed changed, and what it
    /// newly lets reach into the Mac.
    static func check(_ text: String, against saved: InstanceConfig, on mac: Mac) -> Check {
        var check = Check()
        let data = Data(text.utf8)
        guard data.count <= maxBytes else {
            check.problems = [Problem(path: "", message: "More than \(maxBytes >> 10) KB: not a VM's settings.")]
            return check
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            let why = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            check.problems = [Problem(path: "", message: "Not valid JSON: \(why)")]
            return check
        }
        guard let object = parsed as? [String: Any] else {
            check.problems = [Problem(path: "", message: "The settings are one object in { }.")]
            return check
        }
        check.problems = unknownKeys(in: object)
        guard let version = object["version"] as? Int, version == InstanceConfig.currentVersion else {
            check.problems.append(Problem(path: "version", message: "Needs \"version\": \(InstanceConfig.currentVersion)."))
            return check
        }
        var new: InstanceConfig
        do {
            new = try InstanceConfig.decode(data)
        } catch {
            check.problems.append(problem(error))
            return check
        }
        for (key, same) in fixedKeys where !same(saved, new) {
            check.problems.append(Problem(path: key, message: "Set when the VM was made: it cannot change."))
        }
        do {
            try new.validate(maxCPUs: mac.maxCPUs, maxMemoryGiB: mac.maxMemoryGiB)
        } catch {
            check.problems.append(Problem(path: path(of: error), message: error.localizedDescription))
        }

        // What newly reaches into the Mac. A new folder that needs the
        // user's word gets it with the confirmation of the whole edit.
        var access = MacAccess()
        let savedShares = Set(saved.sharing.shares.map(\.hostPath))
        for (i, share) in new.sharing.shares.enumerated() where !savedShares.contains(share.hostPath) {
            switch SharePolicy.verdict(SharePolicy.resolve(share.hostPath), readOnly: share.readOnly, places: mac.places) {
            case .refused(let why):
                check.problems.append(Problem(path: "sharing.shares[\(i)].hostPath", message: why))
            case .needsConfirmation:
                new.sharing.shares[i].confirmed = true
                access.shares.append(share)
            case .fine:
                new.sharing.shares[i].confirmed = nil
                access.shares.append(share)
            }
        }
        func bridgeKey(_ b: CommandBridge) -> String { b.command.joined(separator: "\u{0}") + "\u{1}" + b.guestEndpoint }
        let savedBridges = Set(saved.bridges.map(bridgeKey))
        access.bridges = new.bridges.filter { !savedBridges.contains(bridgeKey($0)) }
        // A host command new or changed in anything but being on or off.
        func commandKey(_ c: HostCommand) -> HostCommand { var c = c; c.enabled = true; return c }
        let savedCommands = Set(saved.hostCommands.map(commandKey))
        access.hostCommands = new.hostCommands.filter { !savedCommands.contains(commandKey($0)) }
        access.agents = new.agents != saved.agents ? new.agents : nil
        func forwardKey(_ f: ForwardRule) -> String {
            "\(f.kind.rawValue) \(f.hostAddress) \(f.hostPort ?? 0) \(f.guestHost) \(f.guestPort ?? 0) \(f.hostSocket ?? "") \(f.guestSocket ?? "")"
        }
        let savedForwards = Set(saved.forwards.filter(\.needsConfirmation).map(forwardKey))
        access.forwards = new.forwards.filter { $0.needsConfirmation && !savedForwards.contains(forwardKey($0)) }
        access.allowLAN = new.firewall.allowLAN && !saved.firewall.allowLAN
        access.images = new.inlineImages && !saved.inlineImages
        let savedRules = Set(saved.firewall.rules.filter(\.opensByAddress))
        access.firewallRules = new.firewall.rules.filter { $0.opensByAddress && !savedRules.contains($0) }

        guard check.problems.isEmpty else { return check }
        check.config = new
        check.changes = ConfigChange.all(from: saved, to: new)
        check.reachesIntoMac = access.lines
        return check
    }

    /// Where `problem` is in `text`, for the editor to select: the last key
    /// of its path, found key by key (a list's n-th item is its n-th
    /// object), or the line a JSON error names. nil when neither is found.
    static func range(of problem: Problem, in text: String) -> NSRange? {
        let ns = text as NSString
        var found: NSRange?
        var from = 0
        for segment in problem.path.split(separator: ".") {
            let name = segment.prefix { $0 != "[" }
            if !name.isEmpty {
                let r = ns.range(of: "\"\(name)\"", range: NSRange(location: from, length: ns.length - from))
                guard r.location != NSNotFound else { break }
                found = r
                from = NSMaxRange(r)
            }
            var rest = segment.dropFirst(name.count)
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]"), let n = Int(rest[rest.index(after: rest.startIndex)..<close]) {
                rest = rest[rest.index(after: close)...]
                for _ in 0...n {
                    let r = ns.range(of: "{", range: NSRange(location: from, length: ns.length - from))
                    guard r.location != NSNotFound else { return found }
                    from = NSMaxRange(r)
                }
            }
        }
        if let found { return found }
        guard let at = problem.message.range(of: #"line \d+"#, options: .regularExpression),
              let line = Int(problem.message[at].dropFirst(5)), line >= 1 else { return nil }
        var start = 0
        for _ in 1..<line {
            let nl = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            guard nl.location != NSNotFound else { return nil }
            start = NSMaxRange(nl)
        }
        let end = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
        return NSRange(location: start, length: (end.location == NSNotFound ? ns.length : end.location) - start)
    }

    /// Valid JSON laid out as instance.json is (sorted keys, two spaces);
    /// nil when it is not valid.
    static func format(_ text: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys,
                                                                                       .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// `name`, or the first of name-2, name-3… not taken (lowercased).
    private static func unique(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name.lowercased()) else { return name }
        var n = 2
        while true {
            let suffix = "-\(n)"
            let candidate = String(name.prefix(32 - suffix.count)) + suffix
            if !taken.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }
}
