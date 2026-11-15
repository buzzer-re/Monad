//
//  SSHPromptPanel.swift — the questions ssh asks about an SSH host (trust
//  this host key? a password, a passphrase, a code), asked in a panel of
//  Monad's own, one at a time. A terminal tab never asks for them: what a
//  server prints in a tab cannot pass for this panel, and what is typed
//  here goes to MonadHost and on to ssh, never through a tab.
//
//  The secret is typed in a secure field (macOS turns on secure keyboard
//  entry while it has focus), and the server's words are shown as plain
//  text under "ssh says:" (SSHAskpass.shown).
//

import AppKit
import Combine
import SwiftUI

/// Shows ssh's questions one at a time, in a floating panel that takes keys.
@MainActor
final class SSHPromptController {
    private let host: HostClient
    private var observer: AnyCancellable?
    private var panel: NSPanel?
    private var shown: UUID?

    init(host: HostClient) {
        self.host = host
        observer = host.$sshPrompts.sink { [weak self] list in
            DispatchQueue.main.async { self?.refresh(list) }
        }
    }

    private func refresh(_ list: [SSHPromptRequest]) {
        guard let next = list.first else { close(); return }
        guard next.id != shown else { return }
        close()
        show(next, waiting: list.count - 1)
    }

    private func show(_ request: SSHPromptRequest, waiting: Int) {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.joinsFullScreenSpaces()
        panel.title = "Monad"
        panel.contentViewController = NSHostingController(rootView: SSHPromptView(request: request, waiting: waiting) {
            [weak self] answer, remember in self?.send(request, answer, remember)
        })
        panel.level = .floating
        panel.center()
        // The field needs the keyboard: unlike an approval, this panel is key.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        shown = request.id
    }

    private func send(_ request: SSHPromptRequest, _ answer: String?, _ remember: Bool) {
        Task { @MainActor in
            // The next event drops the question either way (answered or timed out).
            do {
                try await host.answerSSHPrompt(request.id, secret: answer, remember: remember)
            } catch {
                // ssh got the answer unless the question was gone; what is
                // left to say is why a password was not kept.
                guard answer != nil, remember else { return }
                let alert = NSAlert()
                alert.messageText = "The password was not kept"
                alert.informativeText = HostAgent.describe(error)
                alert.runModal()
            }
        }
        close()
    }

    private func close() {
        // The hosting view goes with the panel, and the typed text with it.
        panel?.contentViewController = nil
        panel?.orderOut(nil)
        panel = nil
        shown = nil
    }
}

struct SSHPromptView: View {
    let request: SSHPromptRequest
    let waiting: Int
    /// The answer (nil: cancelled), and whether to keep it in the Keychain.
    let answer: (String?, Bool) -> Void

    @State private var secret = ""
    @State private var remember = true
    @FocusState private var typing: Bool

    static func title(_ request: SSHPromptRequest) -> String {
        switch request.kind {
        case .confirm: return "Trust the SSH host “\(request.host)”?"
        case .secret: return "“\(request.host)” asks you to sign in"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(symbol: "lock.fill", color: .teal, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(request)).font(.headline)
                    Text("Monad asks this for ssh, in a panel of its own. A terminal tab never asks for it.")
                        .font(Design.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("ssh says:").font(Design.caption).foregroundStyle(.secondary)
                Text(request.prompt)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }
            if request.kind == .secret {
                SecureField("", text: $secret)
                    .textFieldStyle(.roundedBorder)
                    .focused($typing)
                    .onSubmit(submit)
                    .accessibilityLabel("Answer")
                if request.retry {
                    Text("The server did not accept the last answer.").font(Design.caption).foregroundStyle(.red)
                }
                if request.canRemember {
                    Toggle("Keep it in my Keychain", isOn: $remember)
                }
            }
            if waiting > 0 {
                Text("\(waiting) more \(waiting == 1 ? "question waits" : "questions wait") after this one.")
                    .font(Design.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { finish(nil) }.keyboardShortcut(.cancelAction)
                switch request.kind {
                case .confirm:
                    // Not the default action: Return must not trust a key.
                    Button("Trust") { finish("yes") }
                case .secret:
                    Button("Continue", action: submit).keyboardShortcut(.defaultAction).disabled(secret.isEmpty)
                }
            }
            Text("Unanswered, it is cancelled after two minutes.")
                .font(Design.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { typing = request.kind == .secret }
    }

    private func submit() {
        guard !secret.isEmpty else { return }
        finish(secret)
    }

    private func finish(_ value: String?) {
        let keep = value != nil && request.kind == .secret && request.canRemember && remember
        secret = ""
        answer(value, keep)
    }
}

#if DEBUG
#Preview("Password") {
    SSHPromptView(request: SSHPromptRequest(id: UUID(), host: "box", kind: .secret, prompt: "dev@example.com's password:",
                                            canRemember: true, retry: true, asked: Date()), waiting: 1) { _, _ in }
}

#Preview("Host key") {
    SSHPromptView(request: SSHPromptRequest(
        id: UUID(), host: "box", kind: .confirm,
        prompt: "The authenticity of host 'example.com (203.0.113.7)' can't be established.\n"
            + "ED25519 key fingerprint is SHA256:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ.\n"
            + "Are you sure you want to continue connecting (yes/no/[fingerprint])?",
        canRemember: false, retry: false, asked: Date()), waiting: 0) { _, _ in }
}
#endif
