//
//  GuestDiscovery.swift — what programs in a VM find without being told
//  (agents phase): ~/.monad/bridges.json (each bridge and
//  host command, where it is in the VM, and a host command's `describe`),
//  and, when the VM has a role, ~/.monad/mcp.env (Monad's MCP endpoint and
//  the VM's token, 0600) with Monad registered in the agents installed
//  there (Claude Code, Codex). Written over ssh as the VM's user whenever
//  the VM is ready and whenever these settings change; /etc/profile.d/
//  monad.sh exports the rest.
//

import Foundation

enum GuestDiscovery {
    /// /etc/profile.d/monad.sh.
    static let profileScript = """
        # Monad: where things are for programs in this VM.
        # Screenshots and files pasted/dropped in Monad land here.
        export MONAD_SHOTS="$HOME/.monad/shots"
        # Files the Mac hands over (host command runs), read-only.
        export MONAD_EXCHANGE="$HOME/.monad/exchange"
        # This VM's bridges and host commands.
        export MONAD_BRIDGES="$HOME/.monad/bridges.json"
        # Monad's MCP server, when this VM has a role (Settings › Agents).
        if [ -r "$HOME/.monad/mcp.env" ]; then . "$HOME/.monad/mcp.env"; fi

        """

    /// macOS (no /etc/profile.d): the line ~/.zprofile sources the exports by.
    static let zprofileLine = "[ -r \"$HOME/.monad/profile.sh\" ] && . \"$HOME/.monad/profile.sh\" # Monad"

    /// Run as the VM's user, the script on stdin.
    static let command = "sh -s -- monad-discovery"

    /// The MCP endpoint's address in the VM.
    static func url(_ access: AgentAccess) -> String { "http://127.0.0.1:\(access.guestPort)/mcp" }

    struct Entry: Encodable {
        let name: String
        let kind: String
        let endpoint: String
        let summary: String?
        let arguments: [HostCommand.Argument]?
    }

    static func bridgesJSON(_ config: InstanceConfig) -> String {
        let entries = config.bridges.filter(\.enabled).map {
            Entry(name: $0.name, kind: "bridge", endpoint: $0.guestEndpoint, summary: nil, arguments: nil)
        } + config.hostCommands.filter(\.enabled).map {
            Entry(name: $0.name, kind: "hostCommand", endpoint: $0.guestEndpoint, summary: $0.summary, arguments: $0.arguments)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var text = String(decoding: (try? enc.encode(entries)) ?? Data("[]".utf8), as: UTF8.self)
        if config.agents != nil {
            text = "{\n\"mcp\": \"\(url(config.agents!))\",\n\"bridges\": \(text)\n}"
        } else {
            text = "{\n\"bridges\": \(text)\n}"
        }
        return text + "\n"
    }

    /// The script: bridges.json always; with a role, mcp.env and the
    /// agents' registrations; without one, both taken away. Prints
    /// `discovery-ok`, and `registered <agent>` for each agent it set up.
    static func script(_ config: InstanceConfig, token: String?) -> String {
        var s = """
            set -u
            umask 077
            mkdir -p "$HOME/.monad"
            export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/bin:/usr/local/bin:$PATH"
            cat > "$HOME/.monad/bridges.json.new" <<'MONAD_BRIDGES'
            \(bridgesJSON(config))MONAD_BRIDGES
            mv "$HOME/.monad/bridges.json.new" "$HOME/.monad/bridges.json"

            """
        if config.guestOS == .macos {
            // macOS: the exports in ~/.monad/profile.sh, sourced from ~/.zprofile.
            s += """
                cat > "$HOME/.monad/profile.sh" <<'MONAD_PROFILE'
                \(profileScript)MONAD_PROFILE
                chmod 644 "$HOME/.monad/profile.sh"
                touch "$HOME/.zprofile"
                grep -qxF '\(zprofileLine)' "$HOME/.zprofile" || printf '%s\\n' '\(zprofileLine)' >> "$HOME/.zprofile"

                """
        }
        if let access = config.agents, let token, token.allSatisfy(\.isHexDigit) {
            s += """
                cat > "$HOME/.monad/mcp.env" <<'MONAD_MCP'
                export MONAD_MCP_URL='\(url(access))'
                export MONAD_MCP_TOKEN='\(token)'
                MONAD_MCP
                . "$HOME/.monad/mcp.env"
                if command -v claude >/dev/null 2>&1; then
                    claude mcp remove --scope user monad >/dev/null 2>&1 || true
                    if claude mcp add --scope user --transport http monad "$MONAD_MCP_URL" \\
                        --header "Authorization: Bearer $MONAD_MCP_TOKEN" >/dev/null 2>&1; then
                        echo "registered claude"
                    fi
                fi
                if command -v codex >/dev/null 2>&1; then
                    codex mcp remove monad >/dev/null 2>&1 || true
                    if codex mcp add monad --url "$MONAD_MCP_URL" --bearer-token-env-var MONAD_MCP_TOKEN >/dev/null 2>&1; then
                        echo "registered codex"
                    fi
                fi

                """
        } else {
            s += """
                if [ -e "$HOME/.monad/mcp.env" ]; then
                    rm -f "$HOME/.monad/mcp.env"
                    if command -v claude >/dev/null 2>&1; then claude mcp remove --scope user monad >/dev/null 2>&1 || true; fi
                    if command -v codex >/dev/null 2>&1; then codex mcp remove monad >/dev/null 2>&1 || true; fi
                fi

                """
        }
        return s + "echo discovery-ok\n"
    }

    /// The agents the script registered Monad with.
    static func registered(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { $0.hasPrefix("registered ") ? String($0.dropFirst(11)) : nil }
    }
}
