//
//  AgentViews.swift — agents in Monad's windows (agents phase): the
//  question an agent's risky call puts to the user, and Settings › Agents
//  (how agents on this Mac reach Monad, the VMs with a role, the "always
//  allow" answers and the latest calls).
//

import AppKit
import Combine
import SwiftUI

/// Shows agents' questions one at a time, in a floating panel.
@MainActor
final class ApprovalPromptController {
    private let host: HostClient
    private var observer: AnyCancellable?
    private var panel: NSPanel?
    private var shown: UUID?

    init(host: HostClient) {
        self.host = host
        observer = host.$approvals.sink { [weak self] list in
            DispatchQueue.main.async { self?.refresh(list) }
        }
    }

    private func refresh(_ list: [ApprovalRequest]) {
        guard let next = list.first else { close(); return }
        guard next.id != shown else { return }
        close()
        show(next, waiting: list.count - 1)
    }

    private func show(_ request: ApprovalRequest, waiting: Int) {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Monad"
        panel.contentViewController = NSHostingController(rootView: ApprovalView(request: request, waiting: waiting) {
            [weak self] answer in self?.send(request, answer)
        })
        panel.level = .floating
        panel.center()
        panel.orderFrontRegardless()
        NSApp.requestUserAttention(.criticalRequest)
        self.panel = panel
        shown = request.id
    }

    private func send(_ request: ApprovalRequest, _ answer: ApprovalAnswer) {
        Task { @MainActor in
            // The next event drops the question either way (answered or timed out).
            try? await host.answerApproval(request.id, answer)
        }
        close()
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
        shown = nil
    }
}

struct ApprovalView: View {
    let request: ApprovalRequest
    let waiting: Int
    let answer: (ApprovalAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(symbol: "sparkles", color: .purple, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(request.callerLabel) wants to use \(request.tool)").font(.headline)
                    Text("An agent asked Monad to do this through its MCP server.")
                        .font(Design.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(request.detail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            if waiting > 0 {
                Text("\(waiting) more \(waiting == 1 ? "question waits" : "questions wait") after this one.")
                    .font(Design.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Always Allow Everything") { answer(.alwaysAll) }
                    .help(request.caller == "mac" ? "Every tool, for agents on this Mac, from now on"
                          : "Every tool, for this VM, from now on")
                Button("Always Allow \(request.tool)") { answer(.alwaysTool) }
                Spacer()
                Button("Deny", role: .cancel) { answer(.deny) }.keyboardShortcut(.cancelAction)
                Button("Allow Once") { answer(.once) }.keyboardShortcut(.defaultAction)
            }
            Text("Unanswered, it is refused after two minutes. Settings › Agents takes an “always” back.")
                .font(Design.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 600)
    }
}

/// Settings › Agents.
struct AgentsSettingsPane: View {
    @ObservedObject private var host = HostAgent.client
    @State private var grants: [MCPGrants.Grant] = []
    @State private var audit: [String] = []
    @State private var problem: String?
    @State private var adding = false

    /// What an agent on this Mac runs to reach Monad.
    static var macCommand: String {
        let hostBinary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MonadHost").path
        return "claude mcp add monad -- \(hostBinary) --mcp"
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Agents on this Mac (Claude Code, Codex) reach Monad's MCP server through MonadHost:")
                    HStack {
                        Text(Self.macCommand)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .lineLimit(2).truncationMode(.middle)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.macCommand, forType: .string)
                        }
                    }
                    Text("For Codex: codex mcp add monad -- the same path and --mcp. Changes that reach this Mac or cannot be undone ask you first.")
                        .font(Design.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("This Mac")
            }
            Section {
                let withRole = host.instances.filter { $0.config.agents != nil }
                if withRole.isEmpty {
                    Text("No VM has access to Monad.").foregroundStyle(.secondary)
                }
                ForEach(withRole, id: \.name) { vm in
                    HStack {
                        IconTile(symbol: vm.config.agents?.role == .orchestrator ? "point.3.connected.trianglepath.dotted" : "hammer",
                                 color: .purple, size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.name).font(Design.rowTitle)
                            Text((vm.config.agents?.role == .orchestrator ? "Orchestrator" : "Host commands")
                                 + " · 127.0.0.1:\(vm.config.agents?.guestPort ?? AgentAccess.defaultPort) in the VM")
                                .font(Design.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { setRole(nil, on: vm) }
                    }
                }
                Button { adding = true } label: { Label("Add to VM…", systemImage: "plus") }
                    .disabled(host.instances.filter { !$0.config.ephemeral && $0.config.agents == nil }.isEmpty)
            } header: {
                Text("VMs")
            } footer: {
                Text("A VM with a role reaches Monad's MCP server at its own 127.0.0.1, with a token only it has. Monad registers itself with Claude Code and Codex in the VM when they are installed (the Agentic profile installs them).")
                    .font(Design.caption).foregroundStyle(.secondary)
            }
            Section {
                if grants.isEmpty {
                    Text("No “always allow” answers.").foregroundStyle(.secondary)
                }
                ForEach(grants, id: \.self) { g in
                    HStack {
                        Text(g.caller == "mac" ? "Agents on this Mac" : "VM \(g.caller.dropFirst(3))")
                        Text(g.tool ?? "every tool").foregroundStyle(.secondary)
                        Spacer()
                        Button("Revoke") { revoke(g) }
                    }
                }
            } header: {
                Text("Always Allowed")
            }
            Section {
                if audit.isEmpty {
                    Text("No calls yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(audit.suffix(20).reversed().enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.caption2, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                }
            } header: {
                Text("Latest Calls")
            }
            if let problem {
                Section { Notice(symbol: "exclamationmark.triangle.fill", color: .orange, text: problem) }
            }
        }
        .formStyle(.grouped)
        .font(Design.body)
        .task {
            // Calls come in while the pane shows: keep the list current.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onChange(of: host.approvals) { Task { await load() } }
        .sheet(isPresented: $adding) {
            AddAgentSheet(vms: host.instances.filter { !$0.config.ephemeral && $0.config.agents == nil }.map(\.name)) { name, access in
                adding = false
                if let vm = host.vm(named: name) { setRole(access, on: vm) }
            } onCancel: { adding = false }
        }
    }

    private func setRole(_ access: AgentAccess?, on vm: RemoteVM) {
        var c = vm.config
        c.agents = access
        Task {
            do {
                try await host.update(c)
                problem = nil
            } catch {
                problem = HostAgent.describe(error)
            }
        }
    }

    private func load() async {
        do {
            (grants, audit) = try await host.agentStatus()
            problem = nil
        } catch {
            problem = HostAgent.describe(error)
        }
    }

    private func revoke(_ g: MCPGrants.Grant) {
        Task {
            do { grants = try await host.revokeGrant(g) } catch { problem = HostAgent.describe(error) }
        }
    }
}

/// Settings › Agents › Add to VM…: a VM, its role and an orchestrator's
/// limits, and what that allows, said before it is given.
private struct AddAgentSheet: View {
    let vms: [String]
    var onAdd: (String, AgentAccess) -> Void
    var onCancel: () -> Void

    @State private var vm = ""
    @State private var role = AgentAccess.Role.orchestrator
    @State private var port = String(AgentAccess.defaultPort)
    @State private var maxChildren = 4

    private var access: AgentAccess? {
        guard let p = Int(port), (1024...65535).contains(p), vms.contains(vm) else { return nil }
        return AgentAccess(role: role, guestPort: p, maxChildren: maxChildren)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "sparkles", color: .purple, title: "Add Monad to a VM",
                       subtitle: "Agents in the VM reach Monad's MCP server, as the role allows.")
                .padding(.horizontal, 24).padding(.top, 18)
            Form {
                Picker("VM", selection: $vm) {
                    ForEach(vms, id: \.self) { Text($0).tag($0) }
                }
                Picker("Role", selection: $role) {
                    Text("Orchestrator").tag(AgentAccess.Role.orchestrator)
                    Text("Host commands").tag(AgentAccess.Role.hostCommands)
                }
                .pickerStyle(.segmented)
                if role == .orchestrator {
                    Stepper("VMs of its own: \(maxChildren)", value: $maxChildren, in: 1...AgentAccess.maxChildrenLimit)
                }
                TextField("Port in the VM", text: $port, prompt: Text("7766"))
                if let access {
                    Notice(symbol: "exclamationmark.shield", color: .orange, text: access.summary)
                        .font(Design.caption)
                }
            }
            .formStyle(.grouped)
            .font(Design.body)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Button("Add") { if let access { onAdd(vm, access) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(access == nil)
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 520, height: 430)
        .onAppear { vm = vms.first ?? "" }
    }
}
