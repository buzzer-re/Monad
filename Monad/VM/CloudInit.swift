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

    /// What the guest says about its own health (memory, disks, the
    /// kernel's OOM kills and crashes) on its health port, which Monad logs
    /// in health.log: not over ssh, which is what stops answering then
    /// (Guest/monad-health.sh).
    static func healthScript() throws -> String { try bundled("monad-health", "sh") }
    /// Formats and mounts a Linux VM's extra disks (Guest/monad-disks.sh).
    static func disksScript() throws -> String { try bundled("monad-disks", "sh") }
    static let healthPath = "/usr/local/lib/monad/health"

    /// Started by systemd at every boot, ssh or not. The OOM killer passes
    /// it over (it is what says the OOM killer ran), and it may do no more
    /// than read: CAP_SYSLOG for the kernel log, everything else read-only.
    static let healthServiceUnit = """
        [Unit]
        Description=Monad: the VM's health, for the Mac (on its own port, not over ssh)
        [Service]
        Type=simple
        ExecStart=/bin/sh \(healthPath) run
        Restart=on-failure
        RestartSec=10
        OOMScoreAdjust=-1000
        Nice=-5
        CapabilityBoundingSet=CAP_SYSLOG
        AmbientCapabilities=
        NoNewPrivileges=yes
        ProtectSystem=strict
        ProtectHome=read-only
        PrivateTmp=yes
        RuntimeDirectory=monad-health
        [Install]
        WantedBy=multi-user.target

        """

    /// Monad's SELinux module (Guest/monad.cil) and its loader, which loads
    /// it only where SELinux is on (Guest/monad-selinux.sh).
    static func selinuxModule() throws -> String { try bundled("monad", "cil") }
    static func selinuxScript() throws -> String { try bundled("monad-selinux", "sh") }
    static let selinuxModulePath = "/usr/local/lib/monad/monad.cil"
    static let selinuxScriptPath = "/usr/local/lib/monad/selinux"
    /// Puts the kernel's console on hvc0 too (kept in serial.log) through the
    /// guest's own boot loader tool, quiet or not, from the next boot
    /// (Guest/monad-console.sh).
    static func consoleScript() throws -> String { try bundled("monad-console", "sh") }
    static let consoleScriptPath = "/usr/local/lib/monad/console"
    /// img: pictures in a Monad tab (Guest/monad-img.sh), in every VM.
    static func imgScript() throws -> String { try bundled("monad-img", "sh") }
    static let imgPath = "/usr/local/bin/img"

    /// A time zone name to give a guest (TimeZone's identifiers, such as
    /// Asia/Tokyo or Etc/GMT-9): nil for anything else, so the
    /// installers' lines never carry more than a name.
    static func timeZoneName(_ name: String) -> String? {
        name.range(of: "^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$", options: .regularExpression) != nil ? name : nil
    }

    /// The installers' lines for img, after their install_file: only where
    /// no other img is, and never failing the install (the agent's).
    static func imgInstall() throws -> String {
        """
        if [ ! -e \(imgPath) ] || grep -q monad-img \(imgPath); then
            install_file \(imgPath) 0755 '\(Data(try imgScript().utf8).base64EncodedString())' || echo 'monad: img was not installed' >&2
        fi

        """
    }

    /// Sets the boot messages in a running guest, for its next boot.
    static func bootMessagesCommand(_ messages: BootMessages) -> String {
        "sudo -n sh \(consoleScriptPath) \(messages.rawValue)"
    }

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
    /// every VM runs the agent (and sshd unit) that matches this Monad version,
    /// in the Mac's time zone. A Lima VM's boot is Lima's: its kernel console
    /// and time zone are left as they are.
    static func guestInstallScript(guest: DistroConfig.GuestProfile, lima: Bool = false,
                                   bootMessages: BootMessages = .quiet,
                                   timeZone: String = TimeZone.current.identifier) throws -> String {
        func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
        let agent = try agentScript()
        let report = try reportScript()
        let health = try healthScript()
        let cil = try selinuxModule()
        let selinux = try selinuxScript()
        let consoleText = try consoleScript()
        let img = try imgInstall()
        let zone = lima ? nil : timeZoneName(timeZone)
        let clock = zone.map { "timedatectl set-timezone \($0) >/dev/null 2>&1 || true\n" } ?? ""
        let console = lima ? "" : """
            install_file \(consoleScriptPath) 0755 '\(b64(consoleText))'
            sh \(consoleScriptPath) \(bootMessages.rawValue) || true

            """
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
            before=$changed
            changed=0
            install_file \(healthPath) 0755 '\(b64(health))'
            install_file /etc/systemd/system/monad-health.service 0644 '\(b64(healthServiceUnit))'
            health_changed=$changed
            [ "$before" -eq 0 ] || changed=1
            install_file \(selinuxModulePath) 0644 '\(b64(cil))'
            install_file \(selinuxScriptPath) 0755 '\(b64(selinux))'
            install_file /etc/profile.d/monad.sh 0644 '\(b64(GuestDiscovery.profileScript))'
            \(img)[ "$changed" -eq 0 ] || systemctl daemon-reload
            sh \(selinuxScriptPath)
            systemctl enable --now monad-agent.socket >/dev/null 2>&1
            systemctl enable monad-health.service >/dev/null 2>&1 || true
            if [ "$health_changed" -eq 1 ]; then systemctl restart monad-health.service || true; else systemctl start monad-health.service || true; fi
            \(console)\(clock)echo agent-ok

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

    /// Masks each unit on its own, then stops them all. One systemctl call
    /// for every unit failed as a whole where a name is an alias (Debian
    /// 13's sshd.service, of ssh.service: systemctl will not mask an alias),
    /// and its --now stopped nothing: sshd kept TCP 22, and every new Debian
    /// VM failed its first boot. For a YAML double-quoted scalar or sh -c.
    static func maskEachAndStop(_ units: [String], runtime: Bool, sudo: Bool = false) -> String {
        let run = sudo ? "sudo -n systemctl" : "systemctl"
        let list = units.joined(separator: " ")
        return "for u in \(list); do \(run) mask \(runtime ? "--runtime " : "")\\\"$u\\\" >/dev/null 2>&1 || true; done; "
            + "\(run) stop \(list) >/dev/null 2>&1 || true"
    }

    static func enforceIsolationScript(guest: DistroConfig.GuestProfile, lima: Bool = false) -> String {
        let units = (networkSSHUnits + (lima ? ["lima-guestagent.service"] : [])).joined(separator: " ")
        let mask = lima ? "mask --runtime" : "mask"
        // ss lists listening sockets without root: the check holds where sudo
        // asks for a password, and says nothing is open only if ss answered.
        // Nothing is masked before Monad's own sshd serves vsock: masking
        // systemd's sshd-vsock.socket first would close the only way in.
        return isolationMarker
            + "if ! systemctl is-active --quiet monad-sshd.socket; then echo \(monadSSHDNotYet); exit 0; fi; "
            // Each on its own (an alias must not stop the others), then all
            // stopped; the last refusal is kept to say why a port stayed open.
            + "masked=; for u in \(units); do out=$(sudo -n systemctl \(mask) \"$u\" 2>&1) || masked=$(printf '%s' \"$out\" | tail -1); done; "
            + "sudo -n systemctl stop \(units) >/dev/null 2>&1; "
            + "sudo -n systemctl \(mask) sshd-vsock.socket >/dev/null 2>&1; "
            + "sudo -n systemctl reset-failed sshd-vsock.socket >/dev/null 2>&1; "
            + "if ! listening=$(ss -Htln 2>/dev/null); then echo listening-ports-unreadable; "
            + "elif printf '%s\\n' \"$listening\" | grep -q ':22 '; then "
            // Why it stayed open, plain and short: the masks' last word,
            // whether sudo works, and what listens there.
            + "if sudo -n true 2>/dev/null; then who=$(sudo -n ss -Htlnp 'sport = :22' 2>/dev/null | head -2); "
            + "else who='sudo needs a password'; fi; "
            + "why=$(printf '%s; %s' \"$masked\" \"$who\" | tr -cd '[:print:]' | cut -c1-200); "
            + "echo \"tcp22-open ($why)\"; else echo ok; fi"
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
    /// A copy's first boot (a new VM from a snapshot or another VM): the
    /// disk's machine-id is the original's, and with it its DHCP client id,
    /// so both would get one lease. A new one, and networkd asks again.
    static let newMachineIDCommand =
        "rm -f /etc/machine-id /var/lib/dbus/machine-id; systemd-machine-id-setup; systemctl restart systemd-networkd 2>/dev/null || true"

    static func userData(config: InstanceConfig, guest: DistroConfig.GuestProfile, publicKey: String,
                         bootMessages: BootMessages = .quiet, newIdentity: Bool = false) -> String {
        let user = config.user
        let lima = config.attached != nil
        let key = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // provision() checks that the script exists before rendering.
        let agentBase64 = Data(((try? agentScript()) ?? "").utf8).base64EncodedString()
        let reportBase64 = Data(((try? reportScript()) ?? "").utf8).base64EncodedString()
        let healthBase64 = Data(((try? healthScript()) ?? "").utf8).base64EncodedString()
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
              - [sh, -c, "\(maskEachAndStop(networkSSHUnits + ["sshd-vsock.socket", "lima-guestagent.service"], runtime: true))"]
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
              - [sh, -c, "\(maskEachAndStop(masked, runtime: false))"]
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
        // The kernel's console on hvc0 from the next boot (not in Lima's VMs).
        let consoleBase64 = Data(((try? consoleScript()) ?? "").utf8).base64EncodedString()
        let consoleFile = lima ? "" : """
              - path: \(consoleScriptPath)
                permissions: "0755"
                encoding: b64
                content: \(consoleBase64)

            """
        let consoleRun = lima ? "" : "  - [sh, \(consoleScriptPath), \(bootMessages.rawValue)]\n"
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
          - path: \(healthPath)
            permissions: "0755"
            encoding: b64
            content: \(healthBase64)
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
          - path: /etc/systemd/system/monad-health.service
            permissions: "0644"
            content: |
        \(yamlBlock(healthServiceUnit, indent: 6))
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
        \(consoleFile)runcmd:
        \(newIdentity ? "  - [sh, -c, \"\(newMachineIDCommand)\"]\n" : "")  - [systemd-tmpfiles, --create, /etc/tmpfiles.d/monad-sshd.conf]
        \(lastingMask)  - [sh, -c, "[ -e /sys/fs/selinux/enforce ] || install -D -m 0644 \(sshdReapPath) \(sshdReapDropIn)"]
          - [systemctl, daemon-reload]
          - [sh, \(selinuxScriptPath)]
          - [systemctl, enable, \(lima ? "--runtime, " : "")--now, monad-sshd.socket]
          - [systemctl, enable, --now, monad-agent.socket]
          - [systemctl, enable, --now, --no-block, monad-health.service]
        \(report)  - [install, -d, -o, \(yamlQuote(user)), -g, \(yamlQuote(user)), -m, "0755", \(yamlQuote("\(home)/.monad"))]
          - [install, -d, -o, \(yamlQuote(user)), -g, \(yamlQuote(user)), -m, "0755", \(yamlQuote("\(home)/.monad/shots"))]
          - [install, -d, -o, \(yamlQuote(user)), -g, \(yamlQuote(user)), -m, "0755", \(yamlQuote("\(home)/.monad/uploads"))]
        \(consoleRun)
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
                          runner: CommandRunning = LoggingCommandRunner(SystemCommandRunner()),
                          bootMessages: BootMessages = .quiet, newIdentity: Bool = false) async throws {
        _ = try agentScript()
        try await prepareSSH(config: config, paths: paths, runner: runner)
        let pub = try String(contentsOf: paths.publicKey, encoding: .utf8)
        let ud = Data(userData(config: config, guest: guest, publicKey: pub, bootMessages: bootMessages, newIdentity: newIdentity).utf8)
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
