//
//  MacSetupPrompt.swift — the one question a new macOS VM asks (Phase 14):
//  a panel saying in plain words what finishing its setup does, then, on
//  Continue, Monad's root step through macOS's own password prompt (the
//  same words as its prompt). The answer goes back to MonadHost.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class MacSetupPromptController {
    private let host: HostClient
    private var observer: AnyCancellable?
    private var panel: NSPanel?
    private var shown: String?
    private var running = false

    init(host: HostClient) {
        self.host = host
        // Any VM's snapshot may carry the question: follow them all.
        observer = host.$instances
            .map { vms in Publishers.MergeMany(vms.map { $0.$snapshot.map { _ in () } }).prepend(()) }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
    }

    private func refresh() {
        let waiting = host.instances.first { $0.snapshot.macSetup != nil }
        if running { return }
        guard let vm = waiting, let request = vm.snapshot.macSetup else { close(); return }
        guard vm.name != shown else { return }
        close()
        show(vm.name, request)
    }

    private func show(_ name: String, _ request: MacSetupRequest) {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Monad"
        let madeBy = host.instances.first { $0.name == name }?.config.parent
        panel.contentViewController = NSHostingController(rootView: MacSetupView(vm: name, madeBy: madeBy) { [weak self] go in
            if go { self?.run(name, request) } else { self?.answer(name, work: nil, error: "You chose not to finish setting it up.") }
        })
        panel.level = .floating
        panel.center()
        panel.orderFrontRegardless()
        NSApp.requestUserAttention(.criticalRequest)
        self.panel = panel
        shown = name
    }

    /// The root step, with macOS's password prompt; the answer either way.
    private func run(_ name: String, _ request: MacSetupRequest) {
        close()
        // Only the VM's own files, from a Monad whose bundle is intact and is
        // the code running: then root runs the script's text read here.
        if let why = MacSetup.requestProblem(request, vm: name, instances: Paths.instances) ?? MacSetup.bundleProblem() {
            answer(name, work: nil, error: why)
            return
        }
        guard let script = Bundle.main.url(forResource: "monad-macsetup", withExtension: "sh"),
              let text = try? String(contentsOf: script, encoding: .utf8), MacSetup.bundleProblem() == nil,
              (try? String(contentsOf: script, encoding: .utf8)) == text else {
            answer(name, work: nil, error: "monad-macsetup.sh is missing from Monad, or changed while it was read.")
            return
        }
        running = true
        let madeBy = host.instances.first { $0.name == name }?.config.parent
        let command = MacSetup.rootStepCommand(scriptText: text, disk: request.disk, payload: request.payload,
                                               uid: getuid(), vm: name, madeBy: madeBy)
        Task { @MainActor in
            defer {
                running = false
                refresh()
            }
            do {
                let r = try await ProcessRunner.run(command.executable, command.arguments, timeout: 30 * 60)
                if let work = MacSetup.workFolder(from: r.stdoutString) {
                    answer(name, work: work, error: nil)
                } else if r.stderrString.contains("-128") {
                    answer(name, work: nil, error: "The password prompt was cancelled, so the setup did not run.")
                } else {
                    let why = MacSetup.failure(from: r.stdoutString) ?? r.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                    answer(name, work: nil, error: "The setup could not finish: \(why.isEmpty ? "no reason given" : why)")
                }
            } catch {
                answer(name, work: nil, error: "The setup could not run: \(error.localizedDescription)")
            }
        }
    }

    private func answer(_ name: String, work: String?, error: String?) {
        close()
        Task { @MainActor in try? await host.answerMacSetup(name, work: work, error: error) }
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
        shown = nil
    }
}

struct MacSetupView: View {
    let vm: String
    var madeBy: String? = nil
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(symbol: "macbook", color: .gray, size: 36)
                Text("Finish setting up “\(vm)”").font(.headline)
            }
            Text(MacSetup.question(vm: vm, madeBy: madeBy))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not Now", role: .cancel) { done(false) }.keyboardShortcut(.cancelAction)
                Button("Continue") { done(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
