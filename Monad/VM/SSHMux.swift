//
//  SSHMux.swift — forwards as ssh understands them, and the commands that
//  manage them on a VM's ControlMaster (ssh -O forward / cancel / check /
//  exit). The master is owned by MonadHost and persists until the VM stops,
//  so forwards outlive tabs and the app. Rule fields are validated by
//  InstanceConfig.validate (no ":" or whitespace can reshape a spec).
//

import Foundation

struct SSHMux {
    struct Spec: Equatable, Hashable {
        let flag: String   // -L, -R or -D
        let value: String
    }

    let paths: InstancePaths
    let host: String
    /// The VM's ssh options (`CloudInit.sshArguments`): never its ssh.config.
    let options: [String]

    /// "[addr]" for IPv6 literals, the address otherwise.
    static func address(_ a: String) -> String { a.contains(":") ? "[\(a)]" : a }

    static func spec(_ r: ForwardRule) -> Spec {
        let hp = r.hostPort.map(String.init) ?? "0"
        let gp = r.guestPort.map(String.init) ?? "0"
        switch r.kind {
        case .local:
            return Spec(flag: "-L", value: "\(address(r.hostAddress)):\(hp):\(address(r.guestHost)):\(gp)")
        case .remote:
            return Spec(flag: "-R", value: "\(address(r.guestHost)):\(gp):\(address(r.hostAddress)):\(hp)")
        case .socks:
            return Spec(flag: "-D", value: "\(address(r.hostAddress)):\(hp)")
        case .unixLocal:
            return Spec(flag: "-L", value: "\(r.hostSocket ?? ""):\(r.guestSocket ?? "")")
        case .unixRemote:
            return Spec(flag: "-R", value: "\(r.guestSocket ?? ""):\(r.hostSocket ?? "")")
        }
    }

    private var config: [String] { options }

    var check: [String] { config + ["-O", "check", host] }
    var exit: [String] { config + ["-O", "exit", host] }
    func add(_ rule: ForwardRule) -> [String] { add(Self.spec(rule)) }
    func cancel(_ rule: ForwardRule) -> [String] { cancel(Self.spec(rule)) }
    func add(_ s: Spec) -> [String] { config + ["-O", "forward", s.flag, s.value, host] }
    func cancel(_ s: Spec) -> [String] { config + ["-O", "cancel", s.flag, s.value, host] }

    var masterLog: URL { paths.dir.appendingPathComponent("ssh-master.log") }

    /// Start a persistent master in the background. ssh forks after
    /// authentication but keeps its stdio, so sh first points it at
    /// /dev/null: the caller's pipes close when the parent exits.
    var startMaster: (executable: String, arguments: [String]) {
        ("/bin/sh", ["-c", "exec \"$@\" </dev/null >/dev/null 2>&1", "sh", "/usr/bin/ssh"] + config
            + ["-o", "ControlMaster=yes", "-o", "ControlPersist=yes", "-o", "BatchMode=yes",
               "-E", masterLog.path, "-f", "-N", host])
    }

    /// PID from "Master running (pid=N)".
    static func masterPID(fromCheckOutput s: String) -> pid_t? {
        guard let r = s.range(of: "(pid=") else { return nil }
        let digits = s[r.upperBound...].prefix { $0.isNumber }
        guard let n = Int32(digits), n > 0 else { return nil }
        return n
    }
}
