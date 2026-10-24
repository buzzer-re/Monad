//
//  TerminalSessionViewController.swift — one tab: a terminal view connected
//  to a shell inside a VM (via ssh over vsock) or, optionally, on the host.
//

import AppKit
import Combine
import SwiftUI

/// What a tab connects to. VM targets are resolved through MonadHost when
/// the tab starts (the default and ephemeral VMs may not exist yet).
enum SessionTarget: Equatable {
    case defaultVM
    case ephemeralVM
    case vm(String)
    case host
}

@MainActor
final class TerminalSessionViewController: NSViewController, TerminalViewDelegate, NSMenuItemValidation {
    enum Phase: Equatable { case waiting, connected, exited }

    let target: SessionTarget
    private let hostClient: HostClient
    /// The resolved VM, and the name this tab holds a session on.
    private(set) var vm: RemoteVM?
    private var attached: String?
    let model: TerminalModel
    let terminalView: MonadTerminalView
    /// Blur and background image behind the terminal.
    let backdrop: TerminalBackdropView
    /// Called when the window must become (non-)opaque for the theme.
    var onTransparencyChange: ((Bool) -> Void)?
    private(set) var phase: Phase = .waiting
    private var session: PTYSession?
    /// When the current ssh session started, and how many times in a row a
    /// quick failure was tried again by itself (reconnectDelay).
    private var connectedAt: Date?
    private var autoRetries = 0
    private var cancellables = Set<AnyCancellable>()
    private var serialTail: FileTail?
    private var appTitle: String?
    private var lastActivity: String?
    /// The banner over the tab while the VM's profiles are set up.
    private var banner: NSHostingView<ProfileBannerView>?
    private var bannerHide: DispatchWorkItem?
    /// A profile was being set up while this tab watched (so "set up" news is its own).
    private var sawProfileWork = false
    private var closed = false

    /// Called when the window/tab title should change.
    var onTitleChange: ((String) -> Void)?
    /// Called when the terminal's grid changes size (columns, rows).
    var onGridChange: ((Int, Int) -> Void)?
    /// Called when the shell exited cleanly (`exit`): its window closes the
    /// tab. Without it the tab offers to reconnect.
    var onFinished: (() -> Void)?
    /// Whether this is the context keystrokes go to: the focused pane's
    /// visible one (set by its window). Clipboard writes need it.
    var isFocusedContext = true

    init(target: SessionTarget, cols: Int = 100, rows: Int = 30, host: HostClient? = nil) {
        self.target = target
        hostClient = host ?? HostAgent.client
        guard let model = TerminalModel(cols: cols, rows: rows, scrollback: Settings.scrollbackLines) else {
            fatalError("Cannot allocate terminal state")
        }
        self.model = model
        self.terminalView = MonadTerminalView(model: model)
        self.backdrop = TerminalBackdropView(terminal: terminalView)
        super.init(nibName: nil, bundle: nil)
        terminalView.delegate = self
        model.onTitle = { [weak self] t in
            self?.appTitle = t.isEmpty ? nil : t
            self?.updateTitle()
        }
        model.onBell = { [weak self] in self?.terminalView.visualBell() }
        model.onImagesChanged = { [weak self] in self?.terminalView.needsDisplay = true }
        model.onClipboard = { [weak self] text in
            guard let self else { return }
            // Only the context the user works in: the key window's focused
            // pane, its visible context.
            let frontmost = NSApp.isActive && self.view.window?.isKeyWindow == true && self.isFocusedContext
            switch ClipboardPolicy.verdict(enabled: Settings.allowOSC52, bytes: text.utf8.count, frontmost: frontmost) {
            case .write:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.terminalView.showToast("Copied to clipboard by \(self.displayName)")
            case .ignore:
                break
            case .refuse(let why):
                self.debug("clipboard: \(why)")
                if frontmost { self.terminalView.showToast(why) }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() { view = backdrop }

    /// This tab's own theme id (nil: its VM's theme, else the app default).
    var themeOverride: String? {
        didSet { refreshTheme() }
    }
    private var appliedTheme: Theme??

    /// Apply the theme this tab should use now.
    func refreshTheme() {
        let store = ThemeStore.shared
        let theme = ThemeChoice.effective(tab: themeOverride, vm: vm?.config.theme, app: store.defaultThemeID,
                                          catalog: store.catalog)
        guard appliedTheme == nil || appliedTheme! != theme else { return }
        appliedTheme = .some(theme)
        apply(theme: theme)
    }

    /// Use `theme` in this tab (nil: follow the appearance).
    func apply(theme: Theme?) {
        backdrop.setTheme(theme)
        onTransparencyChange?(backdrop.needsTransparentWindow)
    }

    @objc private func themesChanged() { refreshTheme() }

    var displayName: String {
        if let vm { return vm.name }
        switch target {
        case .defaultVM: return hostClient.defaultVM?.name ?? VMManager.defaultName
        case .ephemeralVM: return "ephemeral"
        case .vm(let name): return name
        case .host: return "host"
        }
    }

    // MARK: Lifecycle

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(themesChanged), name: ThemeStore.changed,
                                               object: nil)
        refreshTheme()
        updateTitle()
        if target == .host {
            connectHost()
        } else {
            attachVM()
        }
    }

    /// Resolve the target through MonadHost, take a session on it (the host
    /// starts the VM) and follow its state.
    private func attachVM() {
        debug("attaching to the VM")
        phase = .waiting
        status("Connecting to VM \u{1B}[1m\(displayName)\u{1B}[22m…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let vm = try await self.resolveVM()
                guard !self.closed else { return }
                self.vm = vm
                self.updateTitle()
                if self.attached == nil {
                    try await self.hostClient.attach(vm.name)
                    if self.closed {
                        try? await self.hostClient.detach(vm.name)
                        return
                    }
                    self.attached = vm.name
                }
                self.cancellables.removeAll()
                vm.statePublisher
                    .sink { [weak self] state in self?.vmStateChanged(state) }
                    .store(in: &self.cancellables)
                vm.$snapshot.map(\.profileRuns).removeDuplicates()
                    .sink { [weak self] runs in DispatchQueue.main.async { self?.profilesChanged(runs ?? []) } }
                    .store(in: &self.cancellables)
                // The VM's theme can change while the tab is open.
                vm.$snapshot.map(\.config.theme).removeDuplicates()
                    .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshTheme() } }
                    .store(in: &self.cancellables)
                // Images in the terminal: the VM's setting, live.
                vm.$snapshot.map(\.config.inlineImages).removeDuplicates()
                    .sink { [weak self] on in DispatchQueue.main.async { self?.model.imagesAllowed = on } }
                    .store(in: &self.cancellables)
            } catch {
                guard !self.closed else { return }
                self.debug("could not attach: \(error.localizedDescription)")
                self.error(HostAgent.describe(error))
                self.status("Press Return to retry.")
                self.phase = .exited
            }
        }
    }

    private func resolveVM() async throws -> RemoteVM {
        if let vm { return vm }
        switch target {
        case .defaultVM: return try await hostClient.ensureDefault()
        case .ephemeralVM: return try await hostClient.createEphemeral()
        case .vm(let name): return try await hostClient.existing(name)
        case .host: throw MonadError("Host shells have no VM.")
        }
    }

    /// Tear down the session (tab closing).
    func close() {
        guard !closed else { return }
        NotificationCenter.default.removeObserver(self, name: ThemeStore.changed, object: nil)
        closed = true
        cancellables.removeAll()
        hideBanner()
        serialTail?.stop()
        serialTail = nil
        session?.terminate()
        session = nil
        if let name = attached {
            attached = nil
            let client = hostClient
            Task { @MainActor in try? await client.detach(name) }
        }
    }

    // MARK: Profile banner

    private func profilesChanged(_ runs: [ProfileRun]) {
        guard !closed, let b = ProfileBanner.of(runs) else { return hideBanner() }
        if b.kind == .working { sawProfileWork = true }
        // Old news: finished before this tab was looking.
        if b.kind == .done && !sawProfileWork { return hideBanner() }
        showBanner(b)
        bannerHide?.cancel()
        if b.kind == .done {
            let hide = DispatchWorkItem { [weak self] in self?.hideBanner() }
            bannerHide = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: hide)
        }
    }

    private func showBanner(_ b: ProfileBanner) {
        let view = ProfileBannerView(banner: b, onClose: { [weak self] in self?.hideBanner() },
                                     onStop: { [weak self] in self?.stopProfiles() },
                                     onDetails: { [weak self] in self?.showProfiles() })
        if let banner {
            banner.rootView = view
            return
        }
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 8),
            host.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -12),
            host.widthAnchor.constraint(lessThanOrEqualTo: backdrop.widthAnchor, multiplier: 0.7),
        ])
        banner = host
    }

    private func showProfiles() {
        guard let vm else { return }
        (NSApp.delegate as? AppDelegate)?.showDetails(of: vm, page: .profiles)
    }

    private func stopProfiles() {
        guard let name = vm?.name else { return }
        let client = hostClient
        Task { @MainActor [weak self] in
            do {
                try await client.stopProfiles(name)
            } catch {
                self?.error(HostAgent.describe(error))
            }
        }
    }

    private func hideBanner() {
        bannerHide?.cancel()
        bannerHide = nil
        banner?.removeFromSuperview()
        banner = nil
    }

    // MARK: Status output

    /// What the tab says while the VM boots: a first boot (Monad has no
    /// host key for the VM yet) sets the VM up and takes longer, once.
    static func bootingStatus(_ paths: InstancePaths) -> String {
        FileManager.default.fileExists(atPath: paths.knownHosts.path)
            ? "Waiting for the guest to boot…"
            : "Setting up the VM on its first boot, this may take a few minutes (only this time)…"
    }

    private func status(_ text: String) {
        model.feed("\u{1B}[0m\u{1B}[2m[monad]\u{1B}[22m \(text)\r\n")
        terminalView.refresh()
    }

    private func error(_ text: String) {
        model.feed("\u{1B}[0m\u{1B}[31;1m[monad]\u{1B}[0m \(text)\r\n")
        terminalView.refresh()
    }

    // MARK: VM sessions

    /// Settings › Logs.
    private func debug(_ message: @autoclosure () -> String) {
        DebugLog.shared.log("tab \(displayName)", message())
    }

    // MARK: Restart

    /// VM › Restart VM: this tab's VM, when it runs (or is starting).
    var canRestartVM: Bool {
        guard target != .host, attached != nil, let vm else { return false }
        return vm.isRunning && vm.state != .stopping
    }

    /// Restarts this tab's VM; the tab connects again once it is back.
    @objc func restartVM(_ sender: Any?) {
        guard canRestartVM, let vm else { return }
        debug("restart requested")
        let client = hostClient
        let name = vm.name
        Task { @MainActor [weak self] in
            do {
                try await client.restart(name)
            } catch {
                self?.debug("restart failed: \(error.localizedDescription)")
                self?.error(HostAgent.describe(error))
            }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(restartVM(_:)) else { return true }
        item.title = canRestartVM ? "Restart VM “\(vm?.name ?? "")”" : "Restart VM"
        return canRestartVM
    }

    /// The progress line rewritten in place: back up `rowsUp` rows to where
    /// the last one starts (a narrower window re-wraps it over more rows; the
    /// terminal knows how many, the text's length does not) and erase from
    /// there, since it is the last thing written.
    static func progressLine(_ text: String, rowsUp: Int) -> String {
        "\r" + (rowsUp > 0 ? "\u{1B}[\(rowsUp)A" : "") + "\u{1B}[J\u{1B}[2m[monad]\u{1B}[22m \(text)"
    }

    private func vmStateChanged(_ state: VMState) {
        guard let vm, !closed else { return }
        if !state.isPreparing { debug("the VM is \(state.debugName)") }
        switch state {
        case .preparing(let activity):
            if activity != lastActivity {
                model.feed(Self.progressLine(activity, rowsUp: model.rowsUpToLineStart(afterWriting: lastActivity != nil)))
                terminalView.refresh()
                lastActivity = activity
            }
        case .starting:
            if lastActivity != nil { model.feed("\r\n"); lastActivity = nil }
            status("Starting VM…")
        case .booting:
            if phase == .waiting && serialTail == nil {
                status(Self.bootingStatus(vm.paths))
                startSerialTail(vm)
            }
        case .ready:
            if phase != .connected { connectVM(vm) }
        case .stopping:
            status("VM is shutting down.")
        case .stopped:
            if phase == .connected || phase == .waiting {
                serialTail?.stop()
                serialTail = nil
                if phase == .waiting && session == nil {
                    status("VM stopped. Press Return to start it again.")
                    phase = .exited
                }
            }
        case .failed(let message):
            serialTail?.stop()
            serialTail = nil
            error(message)
            status("Press Return to retry.")
            phase = .exited
        }
    }

    private func startSerialTail(_ vm: RemoteVM) {
        let tail = FileTail(url: vm.paths.serialLog) { [weak self] data in
            guard let self, self.phase == .waiting else { return }
            // Render the console dimmed; normalize bare LF to CRLF.
            var out = Data("\u{1B}[2m".utf8)
            var prev: UInt8 = 0
            for b in data {
                if b == 0x0A && prev != 0x0D { out.append(0x0D) }
                out.append(b)
                prev = b
            }
            out.append(contentsOf: Array("\u{1B}[22m".utf8))
            self.model.feedConsole(out)
            self.terminalView.refresh()
        }
        tail.start()
        serialTail = tail
    }

    private func connectVM(_ vm: RemoteVM) {
        serialTail?.stop()
        serialTail = nil
        model.endConsole()
        // Clear boot noise so the shell starts on a clean screen.
        model.feed("\u{1B}[0m\u{1B}[H\u{1B}[2J\u{1B}[3J")
        let cmd = PTYSession.Command(
            executable: "/usr/bin/ssh",
            // Options from the VM's settings, never its ssh.config on disk.
            arguments: ["ssh"] + CloudInit.sshArguments(config: vm.config, paths: vm.paths) + [vm.sshHost],
            environment: Self.environment(),
            directory: Paths.home.path)
        spawn(cmd)
    }

    // MARK: Host sessions

    private func connectHost() {
        let (shell, argv0) = Self.hostShell()
        var env = Self.environment()
        #if DEBUG
            // UI tests define helper functions through the POSIX sh ENV file.
            if UserDefaults.standard.string(forKey: "MonadTestShell") != nil,
               let rc = ProcessInfo.processInfo.environment["ENV"] {
                env["ENV"] = rc
            }
        #endif
        env["SHELL"] = shell
        let cmd = PTYSession.Command(executable: shell, arguments: [argv0], environment: env,
                                     directory: Paths.home.path)
        spawn(cmd)
    }

    /// The host shell and its argv[0]: the user's login shell, as a login
    /// shell ("-zsh").
    private static func hostShell() -> (path: String, argv0: String) {
        #if DEBUG
            // UI tests: a plain shell without user rc files that rewrite titles.
            if let test = UserDefaults.standard.string(forKey: "MonadTestShell"),
               FileManager.default.isExecutableFile(atPath: test) {
                return (test, (test as NSString).lastPathComponent)
            }
        #endif
        let shell = loginShell()
        return (shell, "-" + (shell as NSString).lastPathComponent)
    }

    static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return "/bin/zsh"
    }

    static func environment() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        var out: [String: String] = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "Monad",
            "LANG": env["LANG"] ?? "en_US.UTF-8",
            "HOME": Paths.home.path,
            "PATH": env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        for key in ["USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK"] { if let v = env[key] { out[key] = v } }
        return out
    }

    // MARK: PTY

    private func spawn(_ cmd: PTYSession.Command) {
        let s = PTYSession(model: model)
        s.onOutput = { [weak self] in self?.terminalView.refresh() }
        s.onExit = { [weak self] status in self?.sessionExited(status) }
        do {
            try s.start(cmd, cols: terminalView.cols, rows: terminalView.rows)
            debug("started \(cmd.arguments.joined(separator: " "))")
            session = s
            connectedAt = Date()
            phase = .connected
            appTitle = nil
            updateTitle()
        } catch {
            debug("could not start \(cmd.executable): \(error.localizedDescription)")
            self.error(error.localizedDescription)
            phase = .exited
        }
    }

    /// Whether a shell's wait status closes its tab: only a clean exit
    /// (status 0, no signal), as Terminal does. Anything else, ssh's 255
    /// for a lost VM among them, leaves the tab to reconnect.
    nonisolated static func closesOnExit(status: Int32) -> Bool { status & 0xffff == 0 }

    /// How long to wait before connecting again by itself, or nil to ask
    /// for Return: only ssh failing (255) within seconds of connecting, as
    /// on a first boot while the guest still sets sshd up, a few times,
    /// waiting longer each time.
    nonisolated static func reconnectDelay(afterAttempt attempt: Int, status: Int32, lasted: TimeInterval) -> TimeInterval? {
        let delays: [TimeInterval] = [1, 2, 4, 8]
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
        guard code == 255, lasted < 15, delays.indices.contains(attempt) else { return nil }
        return delays[attempt]
    }

    private func sessionExited(_ status: Int32) {
        guard !closed else { return }
        session = nil
        phase = .exited
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
        debug(code >= 0 ? "the session ended with status \(code)\(code == 255 ? " (ssh could not connect or lost the connection)" : "")"
              : "the session was ended by signal \(status & 0x7f)")
        if Self.closesOnExit(status: status), let onFinished {
            onFinished()
            return
        }
        let lasted = connectedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        connectedAt = nil
        if lasted >= 15 { autoRetries = 0 }
        if let vm, let delay = Self.reconnectDelay(afterAttempt: autoRetries, status: status, lasted: lasted) {
            autoRetries += 1
            debug("ssh failed after \(String(format: "%.1f", lasted)) s: trying again in \(Int(delay)) s (attempt \(autoRetries))")
            self.status("The connection to \(vm.name) did not hold (the VM may still be setting up). Connecting again in \(Int(delay)) s…")
            terminalView.refresh()
            updateTitle()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.closed, self.phase == .exited, self.session == nil else { return }
                self.reconnect()
            }
            return
        }
        autoRetries = 0
        if let vm, code == 255 {
            error("Connection to \(vm.name) failed or was lost.")
        }
        model.feed("\r\n\u{1B}[0m\u{1B}[2m[Process completed — press Return to reconnect]\u{1B}[22m\r\n")
        terminalView.refresh()
        updateTitle()
    }

    private func reconnect() {
        if target == .host {
            connectHost()
            return
        }
        guard let vm, attached != nil else {
            attachVM()
            return
        }
        phase = .waiting
        if vm.state == .ready {
            connectVM(vm)
        } else {
            status("Starting VM \(vm.name)…")
            let client = hostClient
            Task { @MainActor [weak self] in
                do {
                    try await client.start(vm.name)
                } catch {
                    self?.error(HostAgent.describe(error))
                    self?.phase = .exited
                }
            }
        }
    }

    // MARK: Title

    private func updateTitle() {
        onTitleChange?(Self.title(name: displayName, appTitle: appTitle, exited: phase == .exited))
    }

    /// "VM: title": a title set in the VM (a shell, a code agent) never
    /// hides which VM the tab is on.
    static func title(name: String, appTitle: String?, exited: Bool) -> String {
        let set = appTitle?.trimmingCharacters(in: .whitespaces) ?? ""
        var title: String
        if set.isEmpty || set == name { title = name }
        else if set.hasPrefix("\(name): ") { title = set }
        else { title = "\(name): \(set)" }
        if exited { title += " — exited" }
        return title
    }

    // MARK: TerminalViewDelegate

    func terminalView(_ view: MonadTerminalView, send data: Data) {
        switch phase {
        case .connected:
            session?.write(data)
        case .exited:
            if data.contains(0x0D) { reconnect() }
        case .waiting:
            break
        }
    }

    func terminalView(_ view: MonadTerminalView, didResizeTo cols: Int, rows: Int, pixels: CGSize) {
        session?.resize(cols: cols, rows: rows, pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height))
        onGridChange?(cols, rows)
    }

    func terminalView(_ view: MonadTerminalView, receivedImages images: [ImagePayload]) -> Bool {
        guard target != .host else { return false }
        guard let vm, phase == .connected else {
            view.showToast("Not connected to \(displayName)")
            return true
        }
        view.showToast(images.count == 1 ? "Uploading image to \(vm.name)…" : "Uploading \(images.count) images…")
        Task { @MainActor in
            var paths: [String] = []
            for img in images {
                do {
                    paths.append(try await FileUploader.upload(img.png, name: img.suggestedName,
                                                               directory: .screenshots, to: vm.sshTarget))
                } catch {
                    view.showToast("Upload failed: \(error.localizedDescription)", duration: 5)
                    return
                }
            }
            view.pasteText(paths.map(ShellQuote.quote).joined(separator: " ") + " ")
            view.showToast(paths.count == 1 ? "Image copied into \(vm.name)" : "\(paths.count) images copied")
        }
        return true
    }

    func terminalView(_ view: MonadTerminalView, receivedFiles urls: [URL]) -> Bool {
        guard target != .host else { return false }
        guard let vm, phase == .connected else {
            view.showToast("Not connected to \(displayName)")
            return true
        }
        view.showToast("Copying \(urls.count) file(s) into \(vm.name)…")
        Task { @MainActor in
            var paths: [String] = []
            for url in urls {
                do {
                    paths.append(try await FileUploader.uploadFile(url, to: vm.sshTarget))
                } catch {
                    view.showToast("Copy failed: \(error.localizedDescription)", duration: 5)
                    return
                }
            }
            view.pasteText(paths.map(ShellQuote.quote).joined(separator: " ") + " ")
            view.showToast("Copied into \(vm.name):~/.monad/uploads")
        }
        return true
    }
}

/// Follows a growing file (the VM serial console log).
final class FileTail {
    private let url: URL
    private let handler: (Data) -> Void
    private var offset: UInt64 = 0
    private var timer: Timer?

    init(url: URL, handler: @escaping (Data) -> Void) {
        self.url = url
        self.handler = handler
    }

    func start() {
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd() else { return }
        if end < offset { offset = 0 } // truncated (new boot)
        guard end > offset else { return }
        let toRead = min(end - offset, 256 * 1024)
        try? h.seek(toOffset: offset)
        if let data = try? h.read(upToCount: Int(toRead)), !data.isEmpty {
            offset += UInt64(data.count)
            handler(data)
        }
    }
}

/// Profile progress over a VM's tab: what is being set up, done, or failed.
struct ProfileBannerView: View {
    let banner: ProfileBanner
    var onClose: () -> Void
    var onStop: () -> Void
    var onDetails: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch banner.kind {
            case .working: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.text).font(.system(size: 12, weight: .medium)).lineLimit(2)
                if let detail = banner.detail {
                    Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Button(action: onDetails) { Image(systemName: "text.alignleft") }
                .buttonStyle(.borderless)
                .help("Show the output in the VM's Profiles page")
            if banner.kind == .working {
                Button(action: onStop) { Image(systemName: "stop.circle") }
                    .buttonStyle(.borderless)
                    .help("Stop setting it up")
            }
            if banner.kind == .failed {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide. The VM's Profiles page has the details.")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
    }
}
