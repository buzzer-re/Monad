//
//  CloudInit.swift — per-instance provisioning: SSH key, cloud-init NoCloud
//  seed (user-data/meta-data on an ISO labelled "cidata") and ssh_config.
//
//  Guest hardening applied on first boot:
//   * sshd is reachable only over virtio-vsock port 22 (socket activated);
//     the TCP ssh service is disabled so nothing listens on the NAT network.
//   * key-only authentication, no root login, password locked.
//

import Foundation

enum CloudInit {
    static let vsockSSHPort: UInt32 = 22
    /// The host dials the guest agent here (see Guest/monad-agent.sh).
    static let agentVsockPort: UInt32 = 1024

    /// The guest agent, shipped inside the app bundle.
    static func agentScript() throws -> String {
        guard let url = Bundle.main.url(forResource: "monad-agent", withExtension: "sh") else {
            throw MonadError("monad-agent.sh is missing from the app bundle")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static let agentPath = "/usr/local/lib/monad/agent"

    /// What the guest says on its console about Monad's setup (MONAD| lines,
    /// shown in the boot tab), shipped inside the app bundle.
    static func reportScript() throws -> String {
        guard let url = Bundle.main.url(forResource: "monad-report", withExtension: "sh") else {
            throw MonadError("monad-report.sh is missing from the app bundle")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static let reportPath = "/usr/local/lib/monad/report"

    /// Monad's SELinux module (Guest/monad.cil) and its loader, which loads
    /// it only where SELinux is on (Guest/monad-selinux.sh).
    static func selinuxModule() throws -> String { try bundled("monad", "cil") }
    static func selinuxScript() throws -> String { try bundled("monad-selinux", "sh") }
    static let selinuxModulePath = "/usr/local/lib/monad/monad.cil"
    static let selinuxScriptPath = "/usr/local/lib/monad/selinux"

    private static func bundled(_ name: String, _ ext: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            throw MonadError("\(name).\(ext) is missing from the app bundle")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
    /// How long the guest watches for Monad's login: the boot deadline
    /// (VMInstance.bootTimeout).
    static let reportWatchSeconds = 15 * 60

    /// sshd's errors and SELinux denials on the console at every boot, until
    /// Monad logs in (at most the boot deadline).
    static let reportServiceUnit = """
        [Unit]
        Description=Monad: tell the console what keeps Monad out, until it logs in
        After=monad-sshd.socket
        [Service]
        Type=simple
        ExecStart=/bin/sh \(reportPath) watch \(reportWatchSeconds)
        [Install]
        WantedBy=multi-user.target

        """

    static let agentSocketUnit = """
        [Unit]
        Description=Monad: guest agent (host-dialed, virtio-vsock)
        [Socket]
        ListenStream=vsock::\(agentVsockPort)
        Accept=yes
        [Install]
        WantedBy=sockets.target

        """

    /// One sandboxed agent process per host connection. It runs as uid 0
    /// because tracefs (kernel socket events) is root-owned, but with an
    /// empty capability set: no privileges beyond owning root files.
    /// ProtectKernelTunables is deliberately absent: it makes /sys read-only,
    /// which would block the agent's private tracefs instance.
    static let agentServiceUnit = """
        [Unit]
        Description=Monad: guest agent connection
        [Service]
        ExecStart=\(agentPath)
        StandardInput=socket
        StandardOutput=socket
        StandardError=journal
        CapabilityBoundingSet=
        AmbientCapabilities=
        NoNewPrivileges=yes
        ProtectSystem=strict
        ProtectHome=yes
        ProtectProc=invisible
        PrivateTmp=yes
        PrivateDevices=yes
        ProtectKernelModules=yes
        ProtectKernelLogs=yes
        ProtectControlGroups=yes
        ProtectClock=yes
        ProtectHostname=yes
        RestrictAddressFamilies=AF_UNIX
        IPAddressDeny=any
        RestrictNamespaces=yes
        RestrictRealtime=yes
        RestrictSUIDSGID=yes
        LockPersonality=yes
        MemoryDenyWriteExecute=yes
        SystemCallArchitectures=native
        SystemCallFilter=@system-service
        MemoryMax=64M
        TasksMax=16

        """

    /// Network sshd unit names across distros (Debian's and Red Hat's), all
    /// masked in every guest: one the guest does not have costs nothing.
    static let networkSSHUnits = ["ssh.service", "ssh.socket", "sshd.service", "sshd.socket"]

    /// One OpenSSH server per vsock connection (inetd mode), started by
    /// systemd itself: under SELinux that gives sshd its own domain, the one
    /// that may log users in (started through env, sshd got the catch-all
    /// service domain and every login failed).
    static func sshdServiceUnit(guest: DistroConfig.GuestProfile) -> String {
        """
        [Unit]
        Description=Monad: OpenSSH per-connection server (vsock)
        After=ssh-keygen.service
        [Service]
        ExecStartPre=/usr/bin/mkdir -p -m0755 /run/sshd
        ExecStartPre=-/usr/bin/ssh-keygen -A
        ExecStart=-\(guest.sshdPath) -i
        StandardInput=socket
        StandardError=journal

        """
    }

    /// Where the guest has no SELinux, sshd starts with SIGCHLD ignored
    /// instead: `sshd -i` forks a helper to hand its configuration over and
    /// becomes sshd-session, which never reaps it (a zombie for as long as the
    /// connection lasts); ignored, the kernel reaps it. sshd-session sets
    /// SIGCHLD back to default before it starts anything, so sessions are
    /// unaffected. Kept in Monad's folder; the guest puts it in place.
    static func sshdReapOverride(guest: DistroConfig.GuestProfile) -> String {
        "[Service]\nExecStart=\nExecStart=-/usr/bin/env --ignore-signal=CHLD \(guest.sshdPath) -i\n"
    }

    static let sshdReapPath = "/usr/local/lib/monad/sshd-reap.conf"
    static let sshdReapDropIn = "/etc/systemd/system/monad-sshd@.service.d/reap.conf"

    /// Run by the host over ssh with the installer on stdin.
    static let guestInstallCommand = "sudo -n sh -s"

    /// Idempotent installer for the guest components, pushed on every boot so
    /// every VM runs the agent (and sshd unit) that matches this Monad version.
    static func guestInstallScript(guest: DistroConfig.GuestProfile) throws -> String {
        func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
        let agent = try agentScript()
        let report = try reportScript()
        let cil = try selinuxModule()
        let selinux = try selinuxScript()
        return """
            set -eu
            changed=0
            install_file() { # DEST MODE BASE64
                tmp=$(mktemp)
                printf '%s' "$3" | base64 -d > "$tmp"
                if ! cmp -s "$tmp" "$1"; then install -D -m "$2" "$tmp" "$1"; changed=1; fi
                rm -f "$tmp"
            }
            install_file \(agentPath) 0755 '\(b64(agent))'
            install_file /etc/systemd/system/monad-agent.socket 0644 '\(b64(agentSocketUnit))'
            install_file /etc/systemd/system/monad-agent@.service 0644 '\(b64(agentServiceUnit))'
            install_file /etc/systemd/system/monad-sshd@.service 0644 '\(b64(sshdServiceUnit(guest: guest)))'
            install_file \(sshdReapPath) 0644 '\(b64(sshdReapOverride(guest: guest)))'
            reap=\(sshdReapDropIn)
            if [ -e /sys/fs/selinux/enforce ]; then
                if [ -e "$reap" ]; then rm -f "$reap"; changed=1; fi
            elif ! cmp -s \(sshdReapPath) "$reap"; then
                install -D -m 0644 \(sshdReapPath) "$reap"
                changed=1
            fi
            install_file \(reportPath) 0755 '\(b64(report))'
            install_file /etc/systemd/system/monad-report.service 0644 '\(b64(reportServiceUnit))'
            install_file \(selinuxModulePath) 0644 '\(b64(cil))'
            install_file \(selinuxScriptPath) 0755 '\(b64(selinux))'
            install_file /etc/profile.d/monad.sh 0644 '\(b64(GuestDiscovery.profileScript))'
            [ "$changed" -eq 0 ] || systemctl daemon-reload
            sh \(selinuxScriptPath)
            systemctl enable --now monad-agent.socket >/dev/null 2>&1
            echo agent-ok

            """
    }

    /// Indent a file for a YAML block scalar.
    private static func yamlBlock(_ text: String, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : pad + $0 }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    /// First command of the isolation check (a no-op), so it can be recognized.
    static let isolationMarker = ": monad-isolation-check; "

    /// Idempotent guest hardening, re-applied by the host on every boot so it
    /// also covers instances provisioned by older versions. Masks the distro's
    /// network sshd units and systemd's generated vsock socket; only Monad's
    /// sshd over vsock may remain. Prints "ok" or "tcp22-open". A Lima VM's
    /// masks last until its next boot (`--runtime`): Lima needs that sshd,
    /// and Lima's guest agent has no host to talk to under Monad.
    /// The isolation check's answer while Monad's own vsock sshd is not up
    /// yet (a first boot: systemd's sshd-vsock.socket answered first).
    static let monadSSHDNotYet = "monad-sshd-not-yet"

    static func enforceIsolationScript(guest: DistroConfig.GuestProfile, lima: Bool = false) -> String {
        let units = (networkSSHUnits + (lima ? ["lima-guestagent.service"] : [])).joined(separator: " ")
        let mask = lima ? "mask --runtime" : "mask"
        // ss lists listening sockets without root: the check holds where sudo
        // asks for a password, and says nothing is open only if ss answered.
        // Nothing is masked before Monad's own sshd serves vsock: masking
        // systemd's sshd-vsock.socket first would close the only way in.
        return isolationMarker
            + "if ! systemctl is-active --quiet monad-sshd.socket; then echo \(monadSSHDNotYet); exit 0; fi; "
            + "sudo -n systemctl \(mask) --now \(units) >/dev/null 2>&1; "
            + "sudo -n systemctl \(mask) sshd-vsock.socket >/dev/null 2>&1; "
            + "sudo -n systemctl reset-failed sshd-vsock.socket >/dev/null 2>&1; "
            + "if ! listening=$(ss -Htln 2>/dev/null); then echo listening-ports-unreadable; "
            + "elif printf '%s\\n' \"$listening\" | grep -q ':22 '; then echo tcp22-open; else echo ok; fi"
    }

    static func isIsolationCheck(_ remoteCommand: String?) -> Bool {
        remoteCommand?.hasPrefix(isolationMarker) ?? false
    }

    /// Generate the instance key pair if missing.
    static func ensureKeyPair(_ paths: InstancePaths, name: String, runner: CommandRunning) async throws {
        if FileManager.default.fileExists(atPath: paths.privateKey.path),
           FileManager.default.fileExists(atPath: paths.publicKey.path) { return }
        try? FileManager.default.removeItem(at: paths.privateKey)
        try? FileManager.default.removeItem(at: paths.publicKey)
        let r = try await runner.run("/usr/bin/ssh-keygen", [
            "-q", "-t", "ed25519", "-N", "", "-C", "monad-\(name)", "-f", paths.privateKey.path,
        ])
        guard r.status == 0 else { throw MonadError("ssh-keygen failed: \(r.stderrString)") }
    }

    /// The guest's hostname: "monad-" and the name, lowercase as host names
    /// go; a Lima VM keeps Lima's ("lima-" and the name with "." and "_"
    /// made "-", pkg/instance/hostname in Lima).
    private static func hostname(_ config: InstanceConfig) -> String {
        guard let lima = config.attached?.instance else { return "monad-\(config.name.lowercased())" }
        return "lima-" + lima.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "_", with: "-")
    }

    /// The seed. A Lima VM's disk is booted by Lima too, so its seed changes
    /// nothing Lima relies on: its user (Monad only adds a key), host keys,
    /// hostname and sshd stay, and cloud-init sets up no mounts (Lima's
    /// shared folders are Lima's). For one boot only (bootcmd runs at every
    /// boot): the network sshd and Lima's guest agent are masked, and Monad's
    /// vsock sshd runs, so under Lima systemd's own (which Lima dials) can
    /// have vsock port 22. A copy of a Lima VM ("Copy to Monad") is Monad's
    /// own: lasting masks, Lima's guest agent included, and Lima's per-boot
    /// script removed (it would look for Lima's seed at every boot).
    static func userData(config: InstanceConfig, guest: DistroConfig.GuestProfile, publicKey: String) -> String {
        let user = config.user
        let lima = config.attached != nil
        let key = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // provision() checks that the script exists before rendering.
        let agentBase64 = Data(((try? agentScript()) ?? "").utf8).base64EncodedString()
        let reportBase64 = Data(((try? reportScript()) ?? "").utf8).base64EncodedString()
        let cilBase64 = Data(((try? selinuxModule()) ?? "").utf8).base64EncodedString()
        let selinuxBase64 = Data(((try? selinuxScript()) ?? "").utf8).base64EncodedString()
        let account = lima ? "" : """
                gecos: Monad user
                shell: /bin/bash
                sudo: "ALL=(ALL) NOPASSWD:ALL"
                lock_passwd: true

            """
        // Any VM loads the vsock driver at every boot, should the kernel not
        // have; a Lima VM's seed keeps Lima working instead.
        let keepLima = !lima ? """
            bootcmd:
              - [sh, -c, "modprobe vmw_vsock_virtio_transport 2>/dev/null || true"]

            """ : """
            ssh_deletekeys: false
            mounts: []
            bootcmd:
              - [systemctl, mask, --runtime, --now, \((networkSSHUnits + ["sshd-vsock.socket", "lima-guestagent.service"]).joined(separator: ", "))]
              - [sh, -c, "! [ -e /etc/systemd/system/monad-sshd.socket ] || systemctl enable --runtime --now --no-block monad-sshd.socket"]

            """
        // sshd must never listen on the network: mask (not just disable) the
        // distro units, and systemd-ssh-generator's vsock socket, which would
        // conflict with ours on systemd >= 256.
        let copy = config.copiedFrom != nil
        let masked = networkSSHUnits + ["sshd-vsock.socket"] + (copy ? ["lima-guestagent.service"] : [])
        // The user joins whichever admin groups this guest has (sudo itself
        // comes from the sudoers rule above). User names are plain.
        let lastingMask = lima ? "" : """
              - [systemctl, mask, --now, \(masked.joined(separator: ", "))]
              - [sh, -c, "for g in wheel sudo adm; do getent group $g >/dev/null && usermod -aG $g \(user); done; true"]

            """ + (!copy ? "" : """
              - [rm, -f, /var/lib/cloud/scripts/per-boot/00-lima.boot.sh]

            """)
        let home = config.home
        // The guest's report of the setup just made, then its watch (not
        // for a Lima VM: Lima boots it too, and Monad's sshd is Lima's then).
        let report = lima ? "" : """
              - [sh, \(reportPath), setup, \(yamlQuote(user)), \(yamlQuote(guest.sshdPath))]
              - [systemctl, enable, --now, --no-block, monad-report.service]

            """
        return """
        #cloud-config
        hostname: \(hostname(config))
        manage_etc_hosts: true
        users:
          - name: \(yamlQuote(user))
        \(account)    ssh_authorized_keys:
              - \(yamlQuote(key))
        \(keepLima)ssh_pwauth: false
        disable_root: true
        growpart:
          mode: auto
          devices: ["/"]
        package_update: false
        write_files:
          - path: /etc/systemd/system/monad-sshd.socket
            permissions: "0644"
            content: |
              [Unit]
              Description=Monad: OpenSSH over virtio-vsock
              [Socket]
              ListenStream=vsock::\(vsockSSHPort)
              Accept=yes
              [Install]
              WantedBy=sockets.target
          - path: /etc/systemd/system/monad-sshd@.service
            permissions: "0644"
            content: |
        \(yamlBlock(sshdServiceUnit(guest: guest), indent: 6))
          - path: /etc/ssh/sshd_config.d/60-monad.conf
            permissions: "0644"
            content: |
              PasswordAuthentication no
              KbdInteractiveAuthentication no
              PermitRootLogin no
              AcceptEnv LANG LC_* COLORTERM TERM_PROGRAM
          - path: /etc/tmpfiles.d/monad-sshd.conf
            permissions: "0644"
            content: |
              d /run/sshd 0755 root root -
          - path: \(agentPath)
            permissions: "0755"
            encoding: b64
            content: \(agentBase64)
          - path: \(reportPath)
            permissions: "0755"
            encoding: b64
            content: \(reportBase64)
          - path: \(sshdReapPath)
            permissions: "0644"
            encoding: b64
            content: \(Data(sshdReapOverride(guest: guest).utf8).base64EncodedString())
          - path: \(selinuxModulePath)
            permissions: "0644"
            encoding: b64
            content: \(cilBase64)
          - path: \(selinuxScriptPath)
            permissions: "0755"
            encoding: b64
            content: \(selinuxBase64)
          - path: /etc/systemd/system/monad-report.service
            permissions: "0644"
            content: |
        \(yamlBlock(reportServiceUnit, indent: 6))
          - path: /etc/systemd/system/monad-agent.socket
            permissions: "0644"
            content: |
        \(yamlBlock(agentSocketUnit, indent: 6))
          - path: /etc/systemd/system/monad-agent@.service
            permissions: "0644"
            content: |
        \(yamlBlock(agentServiceUnit, indent: 6))
          - path: /etc/profile.d/monad.sh
            permissions: "0644"
            content: |
        \(yamlBlock(GuestDiscovery.profileScript, indent: 6))
        runcmd:
          - [systemd-tmpfiles, --create, /etc/tmpfiles.d/monad-sshd.conf]
        \(lastingMask)  - [sh, -c, "[ -e /sys/fs/selinux/enforce ] || install -D -m 0644 \(sshdReapPath) \(sshdReapDropIn)"]
          - [systemctl, daemon-reload]
          - [sh, \(selinuxScriptPath)]
          - [systemctl, enable, \(lima ? "--runtime, " : "")--now, monad-sshd.socket]
          - [systemctl, enable, --now, monad-agent.socket]
        \(report)  - [install, -d, -o, \(yamlQuote(user)), -g, \(yamlQuote(user)), -m, "0755", \(yamlQuote("\(home)/.monad"))]
          - [install, -d, -o, \(yamlQuote(user)), -g, \(yamlQuote(user)), -m, "0755", \(yamlQuote("\(home)/.monad/shots"))]
          - [install, -d, -o, \(yamlQuote(user)), -g, \(yamlQuote(user)), -m, "0755", \(yamlQuote("\(home)/.monad/uploads"))]

        """
    }

    static func metaData(config: InstanceConfig, instanceID: String) -> String {
        "instance-id: \(instanceID)\nlocal-hostname: \(hostname(config))\n"
    }

    static func sshConfig(config: InstanceConfig, paths: InstancePaths) -> String {
        let host = config.sshHost
        return """
        # Generated by Monad. Usable from any terminal while the VM runs:
        #   ssh -F \(q(paths.sshConfig.path)) \(host)
        Host \(host)
          HostName \(host)
          User \(config.user)
          IdentityFile \(q(paths.privateKey.path))
          IdentitiesOnly yes
          IdentityAgent none
          ForwardAgent no
          ForwardX11 no
          PasswordAuthentication no
          KbdInteractiveAuthentication no
          StrictHostKeyChecking accept-new
          UserKnownHostsFile \(q(paths.knownHosts.path))
          HostKeyAlias \(host)
          ProxyCommand /usr/bin/nc -U \(q(paths.sshSocket.path))
          ControlMaster no
          ControlPath \(q(paths.controlSocket.path))
          ServerAliveInterval 30
          ServerAliveCountMax 4
          SetEnv COLORTERM=truecolor TERM_PROGRAM=Monad
          EscapeChar none
          LogLevel ERROR

        """
    }

    /// The options of `sshConfig` for Monad's own ssh runs, on the command
    /// line: `-F none` reads no config file, since any process of the user
    /// can rewrite ssh.config (a ProxyCommand in it would run as a child of
    /// MonadHost). ControlMaster is left to each caller (ssh keeps the first
    /// value it sees). The destination is "monad-<name>".
    static func sshArguments(config: InstanceConfig, paths: InstancePaths) -> [String] {
        let host = config.sshHost
        let options = [
            "User=\(config.user)",
            "IdentityFile=\(paths.privateKey.path)",
            "IdentitiesOnly=yes",
            "IdentityAgent=none",
            "ForwardAgent=no",
            "ForwardX11=no",
            "PasswordAuthentication=no",
            "KbdInteractiveAuthentication=no",
            "StrictHostKeyChecking=accept-new",
            "UserKnownHostsFile=\(paths.knownHosts.path)",
            "HostKeyAlias=\(host)",
            "ProxyCommand=/usr/bin/nc -U \(q(paths.sshSocket.path))",
            "ControlPath=\(paths.controlSocket.path)",
            "ServerAliveInterval=30",
            "ServerAliveCountMax=4",
            "SetEnv=COLORTERM=truecolor TERM_PROGRAM=Monad",
            "EscapeChar=none",
            "LogLevel=ERROR",
        ]
        return ["-F", "none"] + options.flatMap { ["-o", $0] }
    }

    /// Write key, seed ISO and ssh config for a new instance.
    static func provision(config: InstanceConfig, guest: DistroConfig.GuestProfile, paths: InstancePaths,
                          runner: CommandRunning = LoggingCommandRunner(SystemCommandRunner())) async throws {
        _ = try agentScript()
        try await prepareSSH(config: config, paths: paths, runner: runner)
        let pub = try String(contentsOf: paths.publicKey, encoding: .utf8)
        let ud = Data(userData(config: config, guest: guest, publicKey: pub).utf8)
        let md = Data(metaData(config: config, instanceID: "monad-\(config.name)-\(UUID().uuidString.lowercased())").utf8)

        let rc: Int32 = ud.withUnsafeBytes { udp in
            md.withUnsafeBytes { mdp in
                var files = [
                    mnd_iso_file(name: nil, data: udp.baseAddress, len: udp.count),
                    mnd_iso_file(name: nil, data: mdp.baseAddress, len: mdp.count),
                ]
                return "user-data".withCString { un in
                    "meta-data".withCString { mn in
                        files[0].name = un
                        files[1].name = mn
                        return mnd_iso9660_write(paths.seed.path, "cidata", &files, files.count)
                    }
                }
            }
        }
        if rc != 0 { throw MonadError.posix(rc, "Cannot write cloud-init seed") }
    }

    /// The VM's key pair and Monad's ssh settings for it (any guest).
    static func prepareSSH(config: InstanceConfig, paths: InstancePaths, runner: CommandRunning) async throws {
        try await ensureKeyPair(paths, name: config.name, runner: runner)
        try sshConfig(config: config, paths: paths).write(to: paths.sshConfig, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: paths.knownHosts)
    }

    /// Quote a path for ssh_config.
    private static func q(_ s: String) -> String {
        s.contains(" ") ? "\"\(s)\"" : s
    }

    private static func yamlQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
