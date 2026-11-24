import Foundation
import Observation
import Sparkle

/// Sparkle 2 integration. Updates are EdDSA-signed and served over HTTPS from GitHub
/// Pages (appcast) and GitHub Releases (archives). Sparkle's standard UI shows release
/// notes and handles download, verification, installation and relaunch.
@MainActor
@Observable
final class UpdateManager {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?

    /// False for local builds that were not configured with a real Sparkle public key.
    let isConfigured: Bool

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = key.count == 44 && !key.contains("REPLACE")
        if isConfigured {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        } else {
            controller = nil
        }
    }

    /// Read when the settings menu is built; false while a check is already running.
    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
