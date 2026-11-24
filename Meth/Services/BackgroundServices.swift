import Foundation
import ServiceManagement
import MethCore

/// Wraps ServiceManagement (SMAppService, macOS 13+) for the three things Meth registers:
/// the per-user agent, the privileged Overdose helper, and the optional login item.
@MainActor
enum BackgroundServices {
    static var agent: SMAppService { .agent(plistName: MethIdentifiers.agentPlistName) }
    static var helper: SMAppService { .daemon(plistName: MethIdentifiers.helperPlistName) }

    /// Registers the agent if needed. Registering a LaunchAgent does not need admin
    /// rights; macOS shows a "background item added" notification once.
    @discardableResult
    static func ensureAgentRegistered() -> SMAppService.Status {
        let service = agent
        if service.status != .enabled {
            do {
                try service.register()
            } catch {
                appLog.error("Agent registration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return service.status
    }

    /// Unregisters and re-registers the agent. Used when the agent cannot be reached,
    /// e.g. launchd refuses to spawn it because the registered binary changed.
    static func reregisterAgent() async {
        let service = agent
        try? await service.unregister()
        do { try service.register() } catch {
            appLog.error("Agent re-registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Overdose helper

    enum HelperState: Equatable {
        case enabled, requiresApproval, notRegistered, notFound
    }

    static var helperState: HelperState {
        switch helper.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notFound
        }
    }

    /// Registers the privileged helper. The user must then approve it in System Settings
    /// › General › Login Items; macOS enforces that, Meth cannot bypass it.
    static func registerHelper() throws -> HelperState {
        do {
            try helper.register()
        } catch let error as NSError where error.code == Int(kSMErrorLaunchDeniedByUser) {
            // Registered but awaiting approval.
        }
        return helperState
    }

    static func unregisterHelper() async throws {
        try await helper.unregister()
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Launch at login (opt-in only)

    static var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
