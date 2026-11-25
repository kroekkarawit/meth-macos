import Foundation

/// Who requested a transition. Used for authorization (e.g. Overdose from the CLI)
/// and reported in status output.
public enum CommandSource: String, Codable, Sendable {
    case app
    case cli
    case system
}

/// The durable record of the active session, persisted by the agent so a crash,
/// logout or restart can be recovered from.
public struct SessionRecord: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var mode: SleepMode
    public var source: CommandSource
    public var startedAt: Date
    /// `nil` means indefinite.
    public var durationSeconds: Int?
    /// Absolute wall-clock deadline, used across restarts and for display.
    public var expiresAt: Date?
    /// Deadline on the continuous (sleep-inclusive, clock-change-immune) clock.
    /// Only meaningful while `bootSessionID` matches the current boot.
    public var deadlineContinuousNanos: UInt64?
    public var bootSessionID: String
    /// Session also ends when this process exits ("while app is running").
    public var watchedProcess: WatchedProcess?

    public init(sessionID: UUID, mode: SleepMode, source: CommandSource, startedAt: Date,
                durationSeconds: Int?, expiresAt: Date?, deadlineContinuousNanos: UInt64?,
                bootSessionID: String, watchedProcess: WatchedProcess? = nil) {
        self.watchedProcess = watchedProcess
        self.sessionID = sessionID
        self.mode = mode
        self.source = source
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.expiresAt = expiresAt
        self.deadlineContinuousNanos = deadlineContinuousNanos
        self.bootSessionID = bootSessionID
    }
}

/// A process a session is tied to. `startTime` guards against PID reuse.
public struct WatchedProcess: Codable, Equatable, Sendable {
    public var pid: Int32
    public var name: String
    /// Process start time (microseconds since 1970), from `proc_pidinfo`.
    public var startTime: UInt64
    public init(pid: Int32, name: String, startTime: UInt64) {
        self.pid = pid
        self.name = name
        self.startTime = startTime
    }
}

/// Why the last session ended. Shown by the app and in `meth status --json`.
public enum SessionEndReason: String, Codable, Sendable {
    case manual            // Sober chosen (app, CLI, hotkey, rule)
    case expired           // timer ran out
    case processExited     // the watched app/process quit
    case lowBattery        // battery fell to the configured limit
    case onBatteryPower    // power adapter disconnected
    case helperRestored    // the privileged helper ended Overdose on its own
}

/// Persisted user preferences owned by the agent (so the CLI cannot change them).
public struct AgentPreferences: Codable, Equatable, Sendable {
    /// When false (default) the CLI may not start Overdose; only the app can.
    public var allowOverdoseFromCLI: Bool
    /// End any session when running on battery at or below this percentage. `nil` = off.
    public var endBelowBatteryPercent: Int?
    /// End any session when the power adapter is disconnected.
    public var endOnBatteryPower: Bool

    public static let defaultBatteryLimit = 10
    public static let allowedBatteryLimits = [5, 10, 20, 30]

    public init(allowOverdoseFromCLI: Bool = false,
                endBelowBatteryPercent: Int? = AgentPreferences.defaultBatteryLimit,
                endOnBatteryPower: Bool = false) {
        self.allowOverdoseFromCLI = allowOverdoseFromCLI
        self.endBelowBatteryPercent = endBelowBatteryPercent
        self.endOnBatteryPower = endOnBatteryPower
    }

    private enum CodingKeys: String, CodingKey { case allowOverdoseFromCLI, endBelowBatteryPercent, endOnBatteryPower, batteryLimitSet }

    // Older files lack the newer keys; fall back to defaults instead of failing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowOverdoseFromCLI = try c.decodeIfPresent(Bool.self, forKey: .allowOverdoseFromCLI) ?? false
        if try c.decodeIfPresent(Bool.self, forKey: .batteryLimitSet) == true {
            endBelowBatteryPercent = try c.decodeIfPresent(Int.self, forKey: .endBelowBatteryPercent)
        } else {
            endBelowBatteryPercent = Self.defaultBatteryLimit
        }
        endOnBatteryPower = try c.decodeIfPresent(Bool.self, forKey: .endOnBatteryPower) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(allowOverdoseFromCLI, forKey: .allowOverdoseFromCLI)
        try c.encode(true, forKey: .batteryLimitSet) // distinguishes "off" (null) from "never set"
        try c.encode(endBelowBatteryPercent, forKey: .endBelowBatteryPercent)
        try c.encode(endOnBatteryPower, forKey: .endOnBatteryPower)
    }
}

/// What every client sees. Produced by the agent on demand and on every change.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var mode: SleepMode
    public var sessionID: UUID?
    public var source: CommandSource?
    public var startedAt: Date?
    public var expiresAt: Date?
    public var remainingSeconds: Int?
    public var durationSeconds: Int?
    public var agentVersion: String
    public var preferences: AgentPreferences
    public var generatedAt: Date
    public var watchedProcess: WatchedProcess?
    public var lastEndReason: SessionEndReason?
    public var lastEndedAt: Date?

    public init(mode: SleepMode, sessionID: UUID? = nil, source: CommandSource? = nil,
                startedAt: Date? = nil, expiresAt: Date? = nil, remainingSeconds: Int? = nil,
                durationSeconds: Int? = nil, agentVersion: String, preferences: AgentPreferences,
                generatedAt: Date, watchedProcess: WatchedProcess? = nil,
                lastEndReason: SessionEndReason? = nil, lastEndedAt: Date? = nil) {
        self.watchedProcess = watchedProcess
        self.lastEndReason = lastEndReason
        self.lastEndedAt = lastEndedAt
        self.mode = mode
        self.sessionID = sessionID
        self.source = source
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.remainingSeconds = remainingSeconds
        self.durationSeconds = durationSeconds
        self.agentVersion = agentVersion
        self.preferences = preferences
        self.generatedAt = generatedAt
    }

    public var isIndefinite: Bool { mode.isActive && durationSeconds == nil }

    public static func sober(version: String, preferences: AgentPreferences = .init(), now: Date = Date()) -> SessionSnapshot {
        SessionSnapshot(mode: .sober, agentVersion: version, preferences: preferences, generatedAt: now)
    }
}
