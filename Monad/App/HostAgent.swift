//
//  HostAgent.swift — the app's side of MonadHost: launchd registration of
//  the agent (SMAppService) and the one HostClient every window shares.
//

import Foundation
import ServiceManagement
import os

@MainActor
enum HostAgent {
    static let plistName = "dev.monad.host.plist"

    /// Why the agent could not be enabled, shown in tabs that cannot connect.
    private(set) static var registrationProblem: String?

    /// Build of the MonadHost inside this app, and the one last registered
    /// with launchd. launchd records a launch constraint for the agent binary
    /// at registration; a rebuilt or updated binary (new code hash, ad-hoc
    /// signed in development) is killed at launch until it is re-registered.
    private static let embeddedBuild = Bundle.main.url(forAuxiliaryExecutable: "MonadHost").flatMap(HostBuild.uuid(ofExecutableAt:))
    private static let registeredBuildKey = "registeredHostBuild"

    static let client: HostClient = {
        let requirement = HostXPCSecurity.peerRequirement()
        let embedded = embeddedBuild
        let client = HostClient(connect: {
            // Fail closed: without our own signature we cannot pin the host's.
            guard let requirement else {
                throw MonadError("Monad has no readable code signature, so it does not connect to MonadHost.")
            }
            return XPCHostTransport(peerRequirement: requirement)
        }, expectedHostBuild: embedded)
        client.prepareHostLaunch = { await refreshRegistration() }
        return client
    }()

    /// Ad-hoc signed builds load the agent with launchctl (see LaunchctlAgent),
    /// and Debug builds always: the SMAppService plist carries the release label.
    private static let usesLaunchctl = Flavor.isDebug || HostXPCSecurity.teamIdentifier() == nil

    private static var launchctl: LaunchctlAgent? {
        guard let program = Bundle.main.url(forAuxiliaryExecutable: "MonadHost") else { return nil }
        return LaunchctlAgent(program: program, directory: Paths.root.appendingPathComponent("launchd", isDirectory: true),
                              uid: getuid(), runner: LoggingCommandRunner(SystemCommandRunner()))
    }

    /// Point launchd at this build's MonadHost if it was set up for another
    /// build, or load it again if launchd lost it. Only called when no host is
    /// serving (HostClient.prepareHostLaunch), so running VMs are never disturbed.
    static func refreshRegistration() async {
        guard let embedded = embeddedBuild else { return }
        if UserDefaults.standard.string(forKey: registeredBuildKey) == embedded {
            guard usesLaunchctl, let agent = launchctl else { return }
            do {
                try await agent.ensureLoaded()
                registrationProblem = nil
            } catch {
                Log.app.error("loading MonadHost failed: \(error.localizedDescription, privacy: .public)")
                registrationProblem = error.localizedDescription
            }
            return
        }
        Log.app.notice("pointing launchd at MonadHost build \(embedded, privacy: .public)")
        do {
            if usesLaunchctl {
                guard let agent = launchctl else { throw MonadError("MonadHost is missing from the app bundle.") }
                try await agent.reload()
            } else {
                let service = SMAppService.agent(plistName: plistName)
                try? await service.unregister()
                try service.register()
            }
            UserDefaults.standard.set(embedded, forKey: registeredBuildKey)
            registrationProblem = nil
        } catch {
            Log.app.error("setting up MonadHost failed: \(error.localizedDescription, privacy: .public)")
            registrationProblem = error.localizedDescription
        }
    }

    /// Set up the agent and start the connection.
    static func start() {
        if usesLaunchctl {
            Task { @MainActor in
                // An SMAppService registration from earlier builds would own
                // the same label; drop it once (a Debug build has none).
                let service = SMAppService.agent(plistName: plistName)
                if !Flavor.isDebug, service.status != .notRegistered && service.status != .notFound {
                    try? await service.unregister()
                }
                do {
                    guard let agent = launchctl else { throw MonadError("MonadHost is missing from the app bundle.") }
                    try await agent.ensureLoaded()
                } catch {
                    Log.app.error("loading MonadHost failed: \(error.localizedDescription, privacy: .public)")
                    registrationProblem = error.localizedDescription
                }
                client.start()
            }
            return
        }
        let service = SMAppService.agent(plistName: plistName)
        if service.status != .enabled {
            do {
                try service.register()
                if let embeddedBuild { UserDefaults.standard.set(embeddedBuild, forKey: registeredBuildKey) }
            } catch {
                Log.app.error("registering MonadHost failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        switch service.status {
        case .enabled:
            registrationProblem = nil
        case .requiresApproval:
            registrationProblem = "Allow Monad in System Settings › General › Login Items to run its VM service."
            SMAppService.openSystemSettingsLoginItems()
        default:
            registrationProblem = "The MonadHost service could not be registered with launchd."
        }
        client.start()
    }

    /// Explain a failed request, adding the registration problem if any.
    static func describe(_ error: Error) -> String {
        if let e = error as? HostClientError, e == .unavailable, let problem = registrationProblem {
            return "\(e.localizedDescription) \(problem)"
        }
        return error.localizedDescription
    }
}
