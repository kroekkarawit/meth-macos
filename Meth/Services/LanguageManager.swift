import AppKit

/// In-app language override (English, Thai, Simplified Chinese). Uses the standard
/// per-app `AppleLanguages` default — the same mechanism as System Settings › Language &
/// Region › Applications — so it also applies to system-provided UI. The CLI reads the
/// same value so both speak the same language.
@MainActor
enum LanguageManager {
    enum Choice: String, CaseIterable, Identifiable {
        case system, en, th, zhHans = "zh-Hans"
        var id: String { rawValue }

        /// Language names are shown in their own language, as macOS does.
        var title: String {
            switch self {
            case .system: String(localized: "System Default")
            case .en: "English"
            case .th: "ไทย"
            case .zhHans: "简体中文"
            }
        }
    }

    private static let key = "AppleLanguages"

    static var current: Choice {
        guard let langs = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String],
              let first = langs.first else { return .system }
        return Choice(rawValue: first) ?? .system
    }

    static func set(_ choice: Choice) {
        if choice == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([choice.rawValue], forKey: key)
        }
        UserDefaults.standard.synchronize()
    }

    /// Relaunches Meth so the new language takes effect everywhere.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", path, "--args", "--relaunched"]
        try? p.run()
        NSApp.terminate(nil)
    }
}
