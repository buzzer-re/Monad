//
//  SSHHost.swift — a remote server a tab can open on, and that ports are
//  carried to and from (SSHForward): its settings, its folder under
//  ~/.monad/ssh-hosts/<name>/, and the one place that builds the options of
//  every ssh Monad runs to it.
//
//  Monad reads no ssh config file for these runs either (`-F none`, as for
//  VMs): host, port, user, key and the host to connect through are fields
//  here. Secrets are never in this file: a password lives in the Keychain
//  (SSHSecrets), and every question ssh asks goes through SSHAskpass.
//

import Foundation
import os

struct SSHHost: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// How Monad signs in: a password (Keychain), a private key the user
    /// has (ssh's default keys and agent, or one file), or a key pair Monad
    /// made for this server only (installed with ssh-copy-id).
    enum Auth: String, Codable, CaseIterable, Sendable { case password, key, generated }

    static let currentVersion = 1
    static let maxHosts = 64

    var version = SSHHost.currentVersion
    /// As a VM's name: it names the folder and the Keychain item.
    var name: String
    /// DNS name or IP literal.
    var host: String
    var port: Int = 22
    var user: String
    var auth: Auth
    /// `.key` only; nil: ssh's default keys and ssh-agent.
    var keyPath: String?
    /// Another SSH host's name, to connect through.
    var jump: String?
    /// `.generated`: MonadHost saw the server accept Monad's key.
    var keyInstalled = false

    var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case version, name, host, port, user, auth, keyPath, jump, keyInstalled
    }

    enum DecodingProblem: Error, Equatable, LocalizedError {
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v): return "This SSH host was saved by a newer Monad (version \(v))."
            }
        }
    }

    enum ValidationError: Error, Equatable, LocalizedError {
        case name(String)
        case host(String)
        case port(Int)
        case user(String)
        case keyWithoutKeySignIn
        case keyPath
        case jump(String)
        case selfJump

        var errorDescription: String? {
            switch self {
            case .name(let n): return "“\(n)” is not a valid name: use letters, digits and dashes (max 32)."
            case .host(let h): return "“\(h)” is not a host name or address."
            case .port(let p): return "\(p) is not a valid port (1–65535)."
            case .user(let u): return "“\(u)” is not a user name: letters, digits, . _ @ and -, up to 64."
            case .keyWithoutKeySignIn: return "A key file is only for signing in with a private key."
            case .keyPath: return "A key file is given by its full path."
            case .jump(let j): return "“\(j)” is not an SSH host's name."
            case .selfJump: return "An SSH host cannot jump through itself."
            }
        }
    }

    /// A VM's name pattern, the whole text (a regular expression's `$` also
    /// matches before a last newline).
    static func isValidName(_ name: String) -> Bool {
        InstanceConfig.isValidName(name) && !hasControl(name)
    }

    private static func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    func validate() throws {
        guard Self.isValidName(name) else { throw ValidationError.name(name) }
        guard InstanceConfig.isHostName(host) || InstanceConfig.isIPLiteral(host), host.count <= 253,
              !Self.hasControl(host) else { throw ValidationError.host(host) }
        guard (1...65535).contains(port) else { throw ValidationError.port(port) }
        guard user.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.@-]{0,63}$", options: .regularExpression) != nil,
              !Self.hasControl(user) else { throw ValidationError.user(user) }
        if let keyPath {
            guard auth == .key else { throw ValidationError.keyWithoutKeySignIn }
            guard keyPath.hasPrefix("/"), keyPath.utf8.count <= 1024, !Self.hasControl(keyPath) else {
                throw ValidationError.keyPath
            }
        }
        if let jump {
            guard Self.isValidName(jump) else { throw ValidationError.jump(jump) }
            guard jump != name else { throw ValidationError.selfJump }
        }
    }
}

extension SSHHost {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? SSHHost.currentVersion
        guard version <= SSHHost.currentVersion else { throw DecodingProblem.unsupportedVersion(version) }
        self.init(version: version, name: try c.decode(String.self, forKey: .name),
                  host: try c.decode(String.self, forKey: .host),
                  port: try c.decodeIfPresent(Int.self, forKey: .port) ?? 22,
                  user: try c.decode(String.self, forKey: .user), auth: try c.decode(Auth.self, forKey: .auth),
                  keyPath: try c.decodeIfPresent(String.self, forKey: .keyPath),
                  jump: try c.decodeIfPresent(String.self, forKey: .jump),
                  keyInstalled: try c.decodeIfPresent(Bool.self, forKey: .keyInstalled) ?? false)
    }
}

/// An SSH host as the app shows it: its settings, whether the Keychain has
/// its password (never the password), and the ports carried through it.
struct SSHHostSnapshot: Codable, Equatable, Sendable, Identifiable {
    var config: SSHHost
    var hasPassword: Bool
    /// Absent when there are none.
    var forwards: [ForwardStatus]?

    var id: String { config.name }
}

// MARK: ssh options

/// What an ssh run to an SSH host is for: a session (a tab, a forward's
/// master, an upload) signs in the way the host says; installing Monad's
/// key signs in with whatever this Mac already has.
enum SSHHostPurpose { case session, install }

extension SSHHost {
    /// The known hosts file of every SSH host: keys accepted in Monad's panel.
    static func knownHosts(root: URL = Paths.sshHosts) -> URL { root.appendingPathComponent("known_hosts") }

    /// The options of every ssh Monad runs to this host, on the command
    /// line. `-F none`: no config file is read (see CloudInit.sshArguments).
    /// ControlPath, ControlMaster and BatchMode are left to each caller; the
    /// destination is `host`. `jump`: the host to connect through, itself
    /// reached directly.
    static func sshArguments(_ host: SSHHost, root: URL = Paths.sshHosts, home: URL = Paths.home, jump: SSHHost? = nil,
                             purpose: SSHHostPurpose = .session) -> [String] {
        // Monad's file first: new keys are written there, and the keys the
        // user already trusts are honoured.
        let known = [knownHosts(root: root), home.appendingPathComponent(".ssh/known_hosts")]
        var options = [
            "User=\(host.user)",
            "Port=\(host.port)",
            "StrictHostKeyChecking=ask",
            "UserKnownHostsFile=" + known.map { optionValue(path: $0.path) }.joined(separator: " "),
            "ForwardAgent=no",
            "ForwardX11=no",
            "ServerAliveInterval=30",
            "ServerAliveCountMax=4",
            "ConnectTimeout=15",
            "StreamLocalBindUnlink=yes",
            "SetEnv=COLORTERM=truecolor TERM_PROGRAM=Monad",
            "EscapeChar=none",
            "LogLevel=ERROR",
        ]
        switch (purpose, host.auth) {
        case (.install, _):
            // ssh's default keys, the agent, password and keyboard-interactive
            // all stay available: this is how ssh-copy-id gets in.
            break
        case (.session, .password):
            options += ["PubkeyAuthentication=no", "IdentityAgent=none",
                        "PreferredAuthentications=password,keyboard-interactive"]
        case (.session, .key):
            if let key = host.keyPath { options += ["IdentityFile=" + optionValue(path: key), "IdentitiesOnly=yes"] }
            options.append("PreferredAuthentications=publickey,keyboard-interactive")
        case (.session, .generated):
            options += ["IdentityFile=" + optionValue(path: InstancePaths(name: host.name, root: root).privateKey.path),
                        "IdentitiesOnly=yes", "IdentityAgent=none",
                        "PreferredAuthentications=publickey,keyboard-interactive"]
        }
        if let jump {
            // ssh expands % in a ProxyCommand before the shell splits it.
            let inner = (sshArguments(jump, root: root, home: home, jump: nil, purpose: .session)
                         + ["-o", "ControlPath=none"]).map { $0.replacingOccurrences(of: "%", with: "%%") }
            let words = inner + ["-W", "[%h]:%p", jump.host]
            options.append("ProxyCommand=/usr/bin/ssh " + words.map(ShellQuote.quote).joined(separator: " "))
        }
        return ["-F", "none"] + options.flatMap { ["-o", $0] }
    }

    /// A path as an ssh option's value (IdentityFile, ControlPath, …): ssh
    /// splits the value into words and expands % in file names.
    static func optionValue(path s: String) -> String {
        let p = s.replacingOccurrences(of: "%", with: "%%")
        guard p.contains(" ") || p.contains("\"") || p.contains("'") || p.contains("\\") else { return p }
        return "\"" + p.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: Files

/// The SSH hosts on disk: a folder each (`InstancePaths(name:root:)`), with
/// its settings in host.json, readable only by the user.
struct SSHHostStore {
    static let maxFileBytes = 64 << 10
    let root: URL

    init(root: URL = Paths.sshHosts) {
        self.root = root
    }

    func paths(_ name: String) -> InstancePaths { InstancePaths(name: name, root: root) }

    /// Every valid host, by name (at most `SSHHost.maxHosts`).
    func all() -> [SSHHost] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let hosts = folders.compactMap { url -> SSHHost? in
            let name = url.lastPathComponent
            guard SSHHost.isValidName(name), (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                return nil
            }
            let file = paths(name).sshHost
            guard let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size <= Self.maxFileBytes,
                  let data = try? Data(contentsOf: file), let host = try? JSONDecoder().decode(SSHHost.self, from: data),
                  host.name == name, (try? host.validate()) != nil else {
                Log.host.error("Ignoring the SSH host folder \(name, privacy: .public): host.json is unreadable or invalid")
                return nil
            }
            return host
        }
        return Array(hosts.sorted { $0.name < $1.name }.prefix(SSHHost.maxHosts))
    }

    func save(_ host: SSHHost) throws {
        try host.validate()
        let paths = paths(host.name)
        try Paths.ensurePrivateDirectory(paths.dir)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(host).write(to: paths.sshHost, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.sshHost.path)
    }

    func delete(_ name: String) throws {
        guard SSHHost.isValidName(name) else { return }
        try FileManager.default.removeTree(at: paths(name).dir)
    }
}
