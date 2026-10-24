//
//  ConnectionsView.swift — the VM window's Connections page (Phase 13):
//  where the VM connects through its Monad network, what its firewall
//  decided and why, bytes and last seen, read every 2 seconds while the
//  page shows. Allow and Block put a rule for that destination first in the
//  VM's own firewall (ConnectionsModel).
//

import SwiftUI

struct ConnectionsPage: View {
    @ObservedObject var vm: RemoteVM
    /// A rule was put first and saved (the window adds it to unsaved edits).
    var onRule: (FirewallRule) -> Void

    @StateObject private var model: ConnectionsModel
    @State private var networks: [NetworkDefinition] = []
    @State private var tags: [FirewallTag] = []
    @State private var deciding = false

    init(vm: RemoteVM, host: HostClient, onRule: @escaping (FirewallRule) -> Void) {
        self.vm = vm
        self.onRule = onRule
        _model = StateObject(wrappedValue: ConnectionsModel(vm: vm.name, fetch: { [host] name in
            try await host.connections(name)
        }, update: { [host] config in
            try await host.update(config)
        }))
    }

    private var unavailable: String? {
        ConnectionsModel.unavailable(config: vm.config, networks: networks, running: vm.isRunning)
    }

    var body: some View {
        Form {
            Section {
                PageHeader(symbol: "point.3.connected.trianglepath.dotted", color: .orange, title: "Connections",
                           subtitle: "Where this VM connects through its network, and what its firewall decided.")
            }
            if let why = unavailable {
                Section { Notice(symbol: "info.circle.fill", color: .secondary, text: why) }
            } else {
                Section {
                    HStack(spacing: 10) {
                        Picker("", selection: $model.filter) {
                            ForEach(ConnectionsModel.Filter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        TextField("", text: $model.search, prompt: Text("Name, address or port"))
                            .textFieldStyle(.roundedBorder)
                    }
                    if model.shown.isEmpty {
                        Text(!model.loaded ? "Reading…" : model.rows.isEmpty ? "No connections yet." : "Nothing matches.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.shown) { row in
                        ConnectionRowView(row: row, deciding: deciding) { allow in decide(row, allow: allow) }
                    }
                } footer: {
                    Text("Allow and Block put a rule for that destination first in this VM's firewall, on its Network page. "
                         + "Names are the ones the VM looked up.")
                        .font(Design.caption).foregroundStyle(.secondary)
                }
                if let problem = model.errorMessage {
                    Section { Notice(symbol: "exclamationmark.triangle.fill", color: .red, text: problem) }
                }
            }
        }
        .task(id: vm.isRunning) {
            networks = (try? NetworkStore().all()) ?? []
            tags = (try? FirewallTagStore().all()) ?? []
            while !Task.isCancelled {
                if unavailable == nil { await model.refresh(config: vm.config, tags: tags) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func decide(_ row: ConnectionRow, allow: Bool) {
        deciding = true
        Task {
            if let rule = await model.decide(row, allow: allow, config: vm.config) { onRule(rule) }
            await model.refresh(config: vm.config, tags: tags)
            deciding = false
        }
    }
}

/// One destination: what it is, what decided and why, bytes, counts and
/// when last seen, with Allow and Block.
private struct ConnectionRowView: View {
    let row: ConnectionRow
    let deciding: Bool
    var onDecide: (Bool) -> Void

    private var c: NetConnection { row.connection }

    private var color: Color {
        switch row.status {
        case .open: return .green
        case .allowed: return .secondary
        case .blocked: return .red
        case .asked: return .orange
        }
    }

    private var statusText: String {
        switch row.status {
        case .open(let n): return n == 1 ? "open" : "\(n) open"
        case .allowed: return "allowed"
        case .blocked: return "blocked"
        case .asked: return "waiting for your answer"
        }
    }

    private var counts: String {
        var parts: [String] = []
        if c.opened > 0 { parts.append("\(c.opened) opened") }
        if c.refused > 0 { parts.append("\(c.refused) refused") }
        if c.asked > 0 { parts.append("asked \(c.asked)×") }
        return parts.joined(separator: ", ")
    }

    private func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(Design.rowTitle).lineLimit(1).truncationMode(.middle)
                    Text(statusText).font(Design.caption).foregroundStyle(color)
                }
                Text(row.detail).font(Design.caption).foregroundStyle(.secondary)
                Text(row.why).font(Design.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(bytes(c.bytesOut)) out, \(bytes(c.bytesIn)) in").font(Design.caption).monospacedDigit()
                if !counts.isEmpty { Text(counts).font(Design.caption).foregroundStyle(.secondary) }
                Text(ConnectionsModel.ago(c.lastSeen)).font(Design.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Button("Allow") { onDecide(true) }
                    .help("A rule first in this VM's firewall that allows \(row.title)")
                Button("Block") { onDecide(false) }
                    .help("A rule first in this VM's firewall that blocks \(row.title)")
            }
            .controlSize(.small)
            .disabled(deciding)
        }
        .padding(.vertical, 2)
    }
}
