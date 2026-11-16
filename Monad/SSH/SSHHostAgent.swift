//
//  SSHHostAgent.swift — Monad's agent on an SSH host: the same shell script
//  a VM runs (monad-agent.sh on Linux, monad-macos-agent.sh on macOS), put
//  in ~/.monad on the server once the user has said yes and run there over
//  MonadHost's ssh connection, as the user Monad signs in as. It only says
//  which TCP ports the server listens on, so that those from 1024 up come
//  to this Mac's localhost by themselves (ForwardPlan), as a VM's do.
//
//  Nothing is installed as root, nothing is started by the server itself,
//  and nothing of it runs once Monad is not connected. What it prints is a
//  server's word: it is read like a guest's (AgentProtocol).
//

import Foundation

enum SSHHostAgent {
    /// The systems Monad has an agent for, by what `uname -s` says.
    enum System: String, Sendable, CaseIterable {
        case linux = "Linux"
        case macos = "Darwin"

        /// From `uname -s` on the server. A login shell may print before
        /// it does (a greeting): the last line with anything on it counts.
        init?(uname output: String) {
            guard let last = Self.said(output) else { return nil }
            self.init(rawValue: last)
        }

        /// What the server said it is, as Monad shows it.
        static func said(_ output: String) -> String? {
            output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }.map { $0.plain(limit: 40) }
        }
    }

    /// The agent for `system`, from the app bundle (a VM's own).
    static func script(for system: System) -> String? {
        switch system {
        case .linux: return try? CloudInit.agentScript()
        case .macos: return try? MacSetup.agentScript()
        }
    }

    // What runs on the server. Each is one word for the account's login
    // shell, whichever it is: `uname -s` as it stands, the others as
    // `sh -c '…'` (`remote`).

    static let probe = "uname -s"

    /// Reads the script on its input into ~/.monad, readable by the user only.
    static let install = #"d="$HOME/.monad"; umask 077; mkdir -p "$d" && cat > "$d/monad-agent.sh.new" "#
        + #"&& mv -f "$d/monad-agent.sh.new" "$d/monad-agent.sh""#

    static let remove = #"rm -f "$HOME/.monad/monad-agent.sh" "$HOME/.monad/monad-agent.sh.new""#

    /// Runs the agent until its connection ends. A server is looked at
    /// every two seconds (a VM every second), and only for its ports: a
    /// macOS VM's agent also watches for password prompts on its screen.
    /// On macOS the agent is an account like any other there, to which
    /// netstat (macOS 27) shows no TCP socket: it then reads the listeners
    /// of that account's own programs from lsof.
    static func run(_ system: System) -> String {
        var settings = ["MONAD_AGENT_INTERVAL=2", "MONAD_AGENT_KEEPALIVE=5"]
        if system == .macos {
            settings += ["MONAD_PROMPTS=true", #"MONAD_LSOF="/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Ftn""#]
        }
        return settings.joined(separator: " ") + #" exec sh "$HOME/.monad/monad-agent.sh""#
    }

    /// `command` as the one word ssh hands the server's login shell.
    static func remote(_ command: String) -> String { "sh -c " + ShellQuote.quote(command) }

    /// What the sheet asks before the agent goes onto a server.
    static func question(host: String, user: String) -> (title: String, message: String) {
        ("Put Monad's agent on “\(host)”?",
         "Monad copies a small shell script to ~/.monad/monad-agent.sh on the server and runs it there as \(user), over its "
            + "ssh connection, while Monad is open or a VM runs. It only lists the TCP ports programs on the server listen on, "
            + "so that ports from 1024 up are reachable on this Mac's localhost. Nothing is installed as root, and nothing of "
            + "it runs while Monad is not connected. Turning this off stops it, and removes the script while Monad can "
            + "reach the server.")
    }
}
