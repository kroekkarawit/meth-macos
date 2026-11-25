import Foundation

/// Machine-readable error codes. These strings are part of the public CLI/JSON
/// contract (see docs/CLI.md) and must stay stable.
public enum MethErrorCode: String, Codable, Sendable, CaseIterable {
    case usage = "usage"
    case unknownCommand = "unknown_command"
    case invalidDuration = "invalid_duration"
    case durationRequired = "duration_required"
    case agentUnavailable = "agent_unavailable"
    case helperUnavailable = "helper_unavailable"
    case helperRequiresApproval = "helper_requires_approval"
    case overdoseNotAllowed = "overdose_not_allowed"
    case overdoseUnsupported = "overdose_unsupported"
    case indefiniteOverdoseRequiresConfirmation = "indefinite_overdose_requires_confirmation"
    case assertionFailed = "assertion_failed"
    case privilegedOperationFailed = "privileged_operation_failed"
    case restoreConflict = "restore_conflict"
    case unauthorizedClient = "unauthorized_client"
    case processNotFound = "process_not_found"
    case notExtendable = "not_extendable"
    case batteryLow = "battery_low"
    case `internal` = "internal"

    /// Process exit status used by the CLI. Documented in docs/CLI.md.
    public var exitCode: Int32 {
        switch self {
        case .usage, .unknownCommand, .invalidDuration, .durationRequired, .processNotFound, .notExtendable: 2
        case .agentUnavailable: 3
        case .helperUnavailable, .helperRequiresApproval, .overdoseNotAllowed,
             .overdoseUnsupported, .indefiniteOverdoseRequiresConfirmation: 4
        case .assertionFailed, .privilegedOperationFailed, .restoreConflict, .batteryLow: 5
        case .unauthorizedClient: 6
        case .internal: 1
        }
    }
}

public struct MethError: Error, Codable, Equatable, Sendable, LocalizedError {
    public var code: MethErrorCode
    /// English diagnostic message. Front ends localize by `code`, not by message.
    public var message: String

    public init(_ code: MethErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}
