//
//  main.swift — MonadHost, the launchd agent that owns Monad's VMs.
//
//  launchd starts it on the first connection to its Mach service; it serves
//  Monad.app over XPC (HostXPC.swift), keeps VMs running while the app is
//  closed, and exits once idle (HostLifetime.swift).
//

import AppKit
import Foundation
import os

// monad-netd: this same binary, started by MonadHost with the control channel
// as descriptor 3 (mnd_netd_spawn). It goes straight into the C network
// process, which sandboxes itself before reading a command.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--netd" {
    exit(mnd_netd_main())
}
#if DEBUG
// Tests: enter netd's sandbox and report what it allows.
if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--netd-sandbox-check",
   let udp = UInt16(CommandLine.arguments[2]), let tcp = UInt16(CommandLine.arguments[3]) {
    exit(mnd_netd_sandbox_check(udp, tcp, CommandLine.arguments[4]))
}
#endif

// monad-guestd: this same binary inside a macOS guest (Phase 14), started
// by launchd there. It serves ssh and Monad's agent on vsock and does
// nothing else (mnd_guestd.c).
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--guestd" {
    exit(mnd_guestd_main())
}

// An agent on the Mac: Monad's MCP server over stdio, relayed to the running
// MonadHost (MCPStdio.swift). It never runs VMs itself.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--mcp" {
    signal(SIGPIPE, SIG_IGN)
    MainActor.assumeIsolated {
        guard let requirement = HostXPCSecurity.peerRequirement() else {
            FileHandle.standardError.write(Data("monad mcp: this MonadHost has no readable code signature\n".utf8))
            exit(EX_CONFIG)
        }
        MCPStdio.run(requirement: requirement)
    }
}

// Writes to a closed socket must fail with EPIPE, not kill the host.
signal(SIGPIPE, SIG_IGN)
// SIGTERM (logout, unload) is handled below to shut VMs down cleanly.
signal(SIGTERM, SIG_IGN)

MainActor.assumeIsolated {
    guard HostXPCSecurity.peerRequirement() != nil, HostXPCSecurity.clientRequirement() != nil else {
        // Fail closed: without our own signature we cannot tell who connects.
        Log.host.fault("MonadHost has no readable code signature; refusing to serve")
        exit(EX_CONFIG)
    }
    VMDefaults.register()
    DebugLog.shared.watchSettings()
    DebugLog.shared.log("host", "MonadHost started (protocol \(HostProtocol.version), build \(HostBuild.current ?? "unknown"))")
    let manager = VMManager.shared
    manager.load()
    let service = HostService(manager: manager)
    service.openApp = HostService.openMonad
    // Clients are pinned to Monad's binaries as installed, read for each connection.
    let listener = HostXPCListener(listener: NSXPCListener(machServiceName: HostXPCSecurity.machServiceName),
                                   service: service, requirement: { HostXPCSecurity.clientRequirement() })
    let lifetime = HostLifetime(service: service, grace: 30) {
        manager.flushLogs()
        exit(EXIT_SUCCESS)
    }
    // An app with a newer embedded host asked us to make way (only when idle).
    service.onShutdown = {
        listener.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            manager.flushLogs()
            exit(EXIT_SUCCESS)
        }
    }

    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler {
        Task { @MainActor in
            Log.host.notice("SIGTERM: stopping VMs")
            await manager.stopAll(because: "MonadHost is quitting (launchd asked it to: a logout, a restart or an unload)")
            manager.flushLogs()
            exit(EXIT_SUCCESS)
        }
    }
    term.resume()

    listener.resume()
    lifetime.start()
    Log.host.notice("MonadHost \(HostProtocol.version) listening on \(HostXPCSecurity.machServiceName, privacy: .public)")
    // AppKit's loop (it runs the main queue too): a macOS VM's desktop is a
    // window here (MacDesktop). Nothing shows until one is opened.
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    withExtendedLifetime((listener, lifetime, term)) {
        app.run()
    }
}
