import Foundation

// MARK: - XPC interfaces
//
// All payloads are versioned JSON blobs carried as `Data`. This keeps the Objective-C
// XPC surface to a single method per direction, which is easy to audit, and lets the
// Swift side use Codable enums with exhaustive validation.

/// Vended by the per-user agent (`MethAgent`) on `MethIdentifiers.agentMachService`.
@objc public protocol MethAgentXPC {
    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

/// Optionally exported by clients (the menu bar app) to receive state pushes.
@objc public protocol MethAgentClientXPC {
    func sessionDidChange(_ snapshot: Data)
}

/// Vended by the privileged daemon (`MethHelper`) on `MethIdentifiers.helperMachService`.
@objc public protocol MethHelperXPC {
    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

// MARK: - Agent messages

public enum AgentRequest: Codable, Equatable, Sendable {
    case status
    /// `duration == nil` means indefinite. `confirmIndefiniteOverdose` must be true to
    /// start an indefinite Overdose (only the app can send it).
    /// `whilePID`: also end the session when that process exits.
    case activate(mode: SleepMode, durationSeconds: Int?, confirmIndefiniteOverdose: Bool, whilePID: Int32? = nil)
    case sober
    /// Adds time to the running timed session (same mode, same watched process).
    case extend(seconds: Int)
    case setAllowOverdoseFromCLI(Bool)
    /// Battery rules. App only.
    case setBatteryRules(endBelowBatteryPercent: Int?, endOnBatteryPower: Bool)
    /// Lets an updated app replace an older agent binary when nothing is active.
    case restartIfIdle
}

public struct AgentEnvelope: Codable, Sendable {
    public static let currentVersion = 1
    public var protocolVersion: Int
    public var source: CommandSource
    public var request: AgentRequest

    public init(source: CommandSource, request: AgentRequest) {
        self.protocolVersion = Self.currentVersion
        self.source = source
        self.request = request
    }
}

public struct AgentResponse: Codable, Sendable {
    public var snapshot: SessionSnapshot?
    public var error: MethError?
    /// Non-fatal problems (e.g. a restore conflict that was resolved conservatively).
    public var warnings: [MethError]

    public init(snapshot: SessionSnapshot?, error: MethError? = nil, warnings: [MethError] = []) {
        self.snapshot = snapshot
        self.error = error
        self.warnings = warnings
    }
}

// MARK: - Helper messages

public enum HelperRequest: Codable, Equatable, Sendable {
    case status
    /// Disable system sleep for `sessionID`. Exactly one of `deadlineSeconds`
    /// (hard limit, ≤ 24h) or `leaseSeconds` (must be renewed) is honoured.
    case begin(sessionID: UUID, deadlineSeconds: Int?, leaseSeconds: Int?)
    case renew(sessionID: UUID)
    case end(sessionID: UUID)
}

public struct HelperEnvelope: Codable, Sendable {
    public static let currentVersion = 1
    public var protocolVersion: Int
    public var request: HelperRequest
    public init(request: HelperRequest) {
        self.protocolVersion = Self.currentVersion
        self.request = request
    }
}

public struct HelperStatus: Codable, Equatable, Sendable {
    public var active: Bool
    public var sessionID: UUID?
    public var sleepDisabledNow: Bool?
    public var originalSleepDisabled: Bool?
    public var remainingSeconds: Int?
    public var helperVersion: String
    public init(active: Bool, sessionID: UUID?, sleepDisabledNow: Bool?, originalSleepDisabled: Bool?,
                remainingSeconds: Int?, helperVersion: String) {
        self.active = active
        self.sessionID = sessionID
        self.sleepDisabledNow = sleepDisabledNow
        self.originalSleepDisabled = originalSleepDisabled
        self.remainingSeconds = remainingSeconds
        self.helperVersion = helperVersion
    }
}

public struct HelperResponse: Codable, Sendable {
    public var status: HelperStatus?
    public var error: MethError?
    public var warnings: [MethError]
    public init(status: HelperStatus?, error: MethError? = nil, warnings: [MethError] = []) {
        self.status = status
        self.error = error
        self.warnings = warnings
    }
}

// MARK: - Coding

public enum MethJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601.string(from: date))
        }
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = ISO8601.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad ISO 8601 date: \(s)")
            }
            return date
        }
        return d
    }

    public static func encode<T: Encodable>(_ value: T) -> Data {
        // Encoding our own Codable value types cannot fail; fall back to an empty object defensively.
        (try? encoder().encode(value)) ?? Data("{}".utf8)
    }
}

/// ISO 8601 UTC with whole seconds, e.g. `2026-11-25T10:00:00Z`.
public enum ISO8601 {
    public static func string(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string)
    }
}
