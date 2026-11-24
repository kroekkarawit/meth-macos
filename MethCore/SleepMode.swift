import Foundation

/// The four Meth states. Raw values are the stable, lowercase machine identifiers
/// used by the CLI, JSON output and persistence. Never rename them.
public enum SleepMode: String, Codable, CaseIterable, Sendable, Comparable {
    /// Not preventing sleep.
    case sober
    /// Prevent idle *system* sleep; the display may still sleep. (`caffeinate -i`)
    case bump
    /// Prevent idle system sleep *and* idle display sleep. (`caffeinate -di`)
    case high
    /// High + system-wide `disablesleep` via the privileged helper.
    case overdose

    public var isActive: Bool { self != .sober }

    /// Intensity order, used for icon selection and comparisons.
    public var level: Int {
        switch self {
        case .sober: 0
        case .bump: 1
        case .high: 2
        case .overdose: 3
        }
    }

    public static func < (lhs: SleepMode, rhs: SleepMode) -> Bool { lhs.level < rhs.level }

    /// English display name. The mode names are product terms and are not translated.
    public var displayName: String {
        switch self {
        case .sober: "Sober"
        case .bump: "Bump"
        case .high: "High"
        case .overdose: "Overdose"
        }
    }

    /// Power assertions that implement this mode.
    public var assertionKinds: [PowerAssertionKind] {
        switch self {
        case .sober: []
        case .bump: [.preventUserIdleSystemSleep]
        case .high: [.preventUserIdleSystemSleep, .preventUserIdleDisplaySleep]
        case .overdose: [.preventUserIdleSystemSleep, .preventUserIdleDisplaySleep, .preventSystemSleep]
        }
    }

    public var requiresPrivilegedHelper: Bool { self == .overdose }

    /// Parses CLI words. Accepts the canonical identifiers plus `stop`/`off` for sober.
    public init?(cliWord: String) {
        switch cliWord.lowercased() {
        case "sober", "stop", "off": self = .sober
        case "bump": self = .bump
        case "high": self = .high
        case "overdose": self = .overdose
        default: return nil
        }
    }
}

/// IOKit power assertion types used by Meth.
public enum PowerAssertionKind: String, Codable, Sendable, CaseIterable {
    case preventUserIdleSystemSleep = "PreventUserIdleSystemSleep"
    case preventUserIdleDisplaySleep = "PreventUserIdleDisplaySleep"
    case preventSystemSleep = "PreventSystemSleep"
}
