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

    public init(sessionID: UUID, mode: SleepMode, source: CommandSource, startedAt: Date,
                durationSeconds: Int?, expiresAt: Date?, deadlineContinuousNanos: UInt64?,
                bootSessionID: String) {
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

/// Persisted user preferences owned by the agent (so the CLI cannot change them).
public struct AgentPreferences: Codable, Equatable, Sendable {
    /// When false (default) the CLI may not start Overdose; only the app can.
    public var allowOverdoseFromCLI: Bool = false
    public init(allowOverdoseFromCLI: Bool = false) {
        self.allowOverdoseFromCLI = allowOverdoseFromCLI
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

    public init(mode: SleepMode, sessionID: UUID? = nil, source: CommandSource? = nil,
                startedAt: Date? = nil, expiresAt: Date? = nil, remainingSeconds: Int? = nil,
                durationSeconds: Int? = nil, agentVersion: String, preferences: AgentPreferences,
                generatedAt: Date) {
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
