//
//  FirewallViews.swift — the pieces every firewall editor shares: a VM's
//  switches, the tags it carries, and a rule list with ports typed as text
//  (used by a VM's Network page, the New VM sheet and Settings › Firewall),
//  and the monitor-mode prompt.
//

import AppKit
import Combine
import SwiftUI

/// A VM's switches and its tags, as rows of a form section.
struct FirewallSwitchRows: View {
    @Binding var firewall: VMFirewall
    /// Every tag there is (Settings › Firewall).
    let tags: [FirewallTag]
    /// The VM's group, whose tag applies as one of its own.
    var group: String? = nil

    var body: some View {
        SettingRow(symbol: "desktopcomputer", color: .orange, title: "Reach this Mac and its local network",
                   detail: "Off: the VM cannot connect to the Mac or to devices on your network.") {
            Toggle("", isOn: $firewall.allowLAN).labelsHidden().toggleStyle(.switch)
        }
        SettingRow(symbol: "checklist", color: .purple, title: "Only what the rules allow",
                   detail: "On: everything else on the internet is blocked too, name lookups included.") {
            Toggle("", isOn: $firewall.allowlist).labelsHidden().toggleStyle(.switch)
        }
        SettingRow(symbol: "questionmark.bubble", color: .blue, title: "Ask about new connections",
                   detail: "Monitor mode. Each connection or name lookup no rule decides waits for you to allow or block it.") {
            Toggle("", isOn: $firewall.monitor).labelsHidden().toggleStyle(.switch)
        }
        SettingRow(symbol: "tag", color: .teal, title: "Tags", detail: tagsDetail) {
            FirewallTagPicker(selected: $firewall.tags, tags: tags)
        }
        if let group {
            let rules = tags.first { $0.name == group }?.rules.count ?? 0
            SettingRow(symbol: "folder.fill", color: .indigo, title: "Group \(group)",
                       detail: rules == 0 ? "Its VMs share its firewall rules. It has none yet."
                           : "Its \(rules) firewall rule\(rules == 1 ? "" : "s") apply to this VM after its own and its tags'.") {
                Button("Group Rules…") {
                    let store = FirewallTagStore()
                    if (try? store.tag(named: group)) == nil { try? store.save(FirewallTag(name: group, rules: [])) }
                    (NSApp.delegate as? AppDelegate)?.showSettings(pane: .firewall, tag: group)
                }
            }
        }
    }

    private var tagsDetail: String {
        let missing = firewall.tags.filter { name in !tags.contains { $0.name == name } }
        guard !missing.isEmpty else { return "Firewall tags" }
        return "Firewall tags. Not found, so not applied: \(missing.joined(separator: ", "))."
    }
}

/// The tags a VM carries, as removable capsules, and a menu to add one.
struct FirewallTagPicker: View {
    @Binding var selected: [String]
    let tags: [FirewallTag]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(selected, id: \.self) { name in
                let known = tags.contains { $0.name == name }
                HStack(spacing: 3) {
                    Text(name)
                    Button {
                        selected.removeAll { $0 == name }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove the tag")
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill((known ? Color.teal : Color.red).opacity(0.14)))
                .foregroundStyle(known ? Color.teal : Color.red)
            }
            let available = tags.map(\.name).filter { !selected.contains($0) }
            Menu {
                ForEach(available, id: \.self) { name in
                    Button(name) { selected.append(name) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(available.isEmpty)
            .help("Add a tag")
        }
    }
}

/// Rule rows and an Add button, as rows of a form section. Every read and
/// write goes through the editor, so a row SwiftUI still draws for a rule
/// that was just removed reads a default and writes nothing.
struct FirewallRuleRows: View {
    @Binding var editor: FirewallRulesEditor

    var body: some View {
        ForEach(Array(editor.rules.indices), id: \.self) { i in
            row(i)
        }
        Button {
            editor.add()
        } label: {
            Label("Add Rule", systemImage: "plus")
        }
        .disabled(editor.rules.count >= Firewall.maxRules)
    }

    private func field<T>(_ i: Int, _ key: WritableKeyPath<FirewallRule, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { editor.rule(i)?[keyPath: key] ?? fallback },
                set: { value in editor.update(i) { $0[keyPath: key] = value } })
    }

    private func row(_ i: Int) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: field(i, \.action, .allow)) {
                Text("Allow").tag(FirewallRule.Action.allow)
                Text("Deny").tag(FirewallRule.Action.deny)
            }
            .labelsHidden()
            .fixedSize()
            Picker("", selection: field(i, \.proto, .any)) {
                ForEach(FirewallRule.Proto.allCases, id: \.self) {
                    Text($0 == .any ? "Any" : $0.rawValue.uppercased()).tag($0)
                }
            }
            .labelsHidden()
            .fixedSize()
            TextField("", text: field(i, \.target, ""), prompt: Text("github.com, *.example.com, 10.0.0.0/8"))
                .labelsHidden()
            TextField("", text: Binding(get: { editor.portsText(i) }, set: { editor.setPorts(i, $0) }),
                      prompt: Text("any port"))
                .labelsHidden()
                .frame(width: 90)
            Button { editor.remove(i) } label: { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove rule")
        }
    }
}

enum FirewallText {
    static let rulesFooter = "Rules are checked in order and the first that matches decides. A target is a domain "
        + "(google.com, which covers www.google.com too), only its subdomains (*.google.com), or addresses "
        + "(10.0.0.0/8). Domains are known from the VM's lookups through Monad's DNS. A program that finds "
        + "addresses another way is not matched by name, so to be sure, turn on Only what the rules allow. "
        + "A domain never opens this Mac or your local network. Use addresses for that."
}

// MARK: - Monitor mode prompt

/// The question on screen and what the user picked so far.
@MainActor
final class FirewallPromptState: ObservableObject {
    @Published var prompt: FirewallPrompt
    @Published var errorMessage: String?
    @Published var sending = false

    init(_ prompt: FirewallPrompt) { self.prompt = prompt }
}

/// Like LuLu's alert: who wants to connect where, what an answer covers and
/// where it is saved, and the three answers.
struct FirewallPromptView: View {
    @ObservedObject var state: FirewallPromptState
    var onAnswer: (FirewallAnswer.Decision) -> Void

    var body: some View {
        let p = state.prompt
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: "network.badge.shield.half.filled", color: .orange, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.headline).font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(p.detail).font(Design.body).foregroundStyle(.secondary)
                    if p.ask.names.count > 1 {
                        Text("Also known as \(p.ask.names.dropFirst().joined(separator: ", "))")
                            .font(Design.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Form {
                Picker("Rule for", selection: $state.prompt.target) {
                    ForEach(p.targets, id: \.self) {
                        Text(FirewallPrompt.label(for: $0, address: p.ask.address)).tag($0)
                    }
                }
                Picker("Save to", selection: $state.prompt.scope) {
                    ForEach(p.scopes, id: \.self) { Text(FirewallPrompt.label(for: $0, vm: p.vm)).tag($0) }
                }
            }
            .formStyle(.columns)
            if let problem = state.errorMessage {
                Notice(symbol: "exclamationmark.triangle.fill", color: .red, text: problem).font(Design.caption)
            }
            HStack {
                if p.waiting > 0 {
                    Text("\(p.waiting) more waiting").font(Design.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Block") { onAnswer(.block) }
                Button("Allow Until VM Stops") { onAnswer(.allowUntilStop) }
                // No default button: the prompt can appear while the user
                // types in the terminal, and a stray Return must not answer.
                Button("Allow") { onAnswer(.allow) }
            }
            .disabled(state.sending)
            Text("Allow and Block are saved as a rule. Until the VM stops is not saved.")
                .font(Design.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Shows monitor-mode questions one at a time: as a sheet on the VM's
/// terminal window when it has one, else as a floating panel.
@MainActor
final class FirewallPromptController {
    private let host: HostClient
    private var observers: [AnyCancellable] = []
    private var vmObservers: [String: AnyCancellable] = [:]
    private var panel: NSPanel?
    private var parent: NSWindow?
    private var state: FirewallPromptState?
    private var refreshScheduled = false

    init(host: HostClient) {
        self.host = host
        observers.append(host.$instances.sink { [weak self] list in
            guard let self else { return }
            self.vmObservers = Dictionary(uniqueKeysWithValues: list.map { vm in
                (vm.name, vm.$snapshot.map(\.firewallAsks).removeDuplicates().sink { [weak self] _ in self?.scheduleRefresh() })
            })
            self.scheduleRefresh()
        })
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // Published values are stored after their sinks run: look next turn.
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func refresh() {
        let tags = (try? FirewallTagStore().all()) ?? []
        let next = FirewallPrompt.next(vms: host.instances.map { ($0.config, $0.firewallAsks) }, tags: tags)
        if let next, let state, state.prompt.vm == next.vm, state.prompt.ask.id == next.ask.id {
            if state.prompt.waiting != next.waiting {
                let p = state.prompt // keeps what the user picked
                state.prompt = FirewallPrompt(vm: p.vm, ask: p.ask, waiting: next.waiting, targets: p.targets,
                                              scopes: p.scopes, target: p.target, scope: p.scope)
            }
            return
        }
        close()
        if let next { show(next) }
    }

    private func show(_ prompt: FirewallPrompt) {
        let state = FirewallPromptState(prompt)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Monad Firewall"
        panel.contentViewController = NSHostingController(rootView: FirewallPromptView(state: state) { [weak self, weak state] decision in
            guard let self, let state else { return }
            self.send(decision, state)
        })
        self.state = state
        self.panel = panel
        let terminal = TerminalWindowController.all.last { $0.allSessions.contains { $0.vm?.name == prompt.vm } }?.window
        if let terminal {
            parent = terminal
            terminal.beginSheet(panel)
            terminal.orderFront(nil)
        } else {
            panel.level = .floating
            panel.center()
            panel.orderFrontRegardless()
        }
        NSApp.requestUserAttention(.informationalRequest)
    }

    private func send(_ decision: FirewallAnswer.Decision, _ state: FirewallPromptState) {
        state.sending = true
        state.errorMessage = nil
        let p = state.prompt
        Task { @MainActor in
            do {
                try await host.answerFirewall(p.vm, p.answer(decision))
                // The VM's next snapshot drops the question: refresh moves on.
            } catch {
                state.errorMessage = HostAgent.describe(error)
            }
            state.sending = false
        }
    }

    private func close() {
        guard let panel else { return }
        if let parent { parent.endSheet(panel) } else { panel.orderOut(nil) }
        self.panel = nil
        parent = nil
        state = nil
    }
}
