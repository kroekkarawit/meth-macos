import Foundation

/// A session length: a positive number of whole seconds, or indefinite.
public enum MethDuration: Equatable, Hashable, Sendable, Codable {
    case seconds(Int)
    case indefinite

    /// Longest accepted finite duration for Bump/High (30 days).
    public static let maximumSeconds = 30 * 24 * 3600
    /// Longest accepted finite duration for Overdose (24 hours).
    public static let maximumOverdoseSeconds = 24 * 3600

    public var seconds: Int? {
        if case .seconds(let s) = self { return s }
        return nil
    }

    public var isIndefinite: Bool { self == .indefinite }

    /// Presets shown in the popover's duration selector.
    public static let presets: [MethDuration] = [.seconds(30 * 60), .seconds(3600), .seconds(4 * 3600), .indefinite]
    public static let defaultPreset: MethDuration = .seconds(3600)

    /// Short label used by the segmented control and CLI ("30m", "1h", "4h", "∞").
    public var shortLabel: String {
        switch self {
        case .indefinite: return "∞"
        case .seconds(let s): return MethDuration.compact(s)
        }
    }

    public static func compact(_ total: Int) -> String {
        var rest = total
        var out = ""
        let d = rest / 86400; rest %= 86400
        let h = rest / 3600; rest %= 3600
        let m = rest / 60; rest %= 60
        if d > 0 { out += "\(d)d" }
        if h > 0 { out += "\(h)h" }
        if m > 0 { out += "\(m)m" }
        if rest > 0 || out.isEmpty { out += "\(rest)s" }
        return out
    }
}

public enum DurationParseError: Error, Equatable, Sendable {
    case empty
    case malformed(String)
    case zero
    case tooLong(maximumSeconds: Int)
}

public enum DurationParser {
    /// Parses `15m`, `90m`, `2h`, `1h30m`, `45s`, `1d`, `inf`, `infinite`, `forever`, `∞`.
    /// Units are mandatory; bare numbers are rejected so scripts cannot silently
    /// confuse minutes with seconds. Negative and zero values are rejected.
    public static func parse(_ raw: String, maximumSeconds: Int = MethDuration.maximumSeconds) throws(DurationParseError) -> MethDuration {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { throw .empty }
        if ["inf", "infinite", "infinity", "forever", "∞", "indefinite"].contains(text) {
            return .indefinite
        }

        var total = 0
        var number = ""
        var sawUnit = false
        var usedUnits = Set<Character>()
        let order: [Character] = ["d", "h", "m", "s"]
        var lastUnitIndex = -1

        for ch in text {
            if ch.isASCII && ch.isNumber {
                number.append(ch)
                // Guard against absurd inputs before multiplying.
                if number.count > 7 { throw .malformed(raw) }
            } else if let idx = order.firstIndex(of: ch) {
                guard !number.isEmpty, !usedUnits.contains(ch), idx > lastUnitIndex,
                      let value = Int(number) else { throw .malformed(raw) }
                let factor = [86400, 3600, 60, 1][idx]
                total += value * factor
                usedUnits.insert(ch)
                lastUnitIndex = idx
                number = ""
                sawUnit = true
            } else {
                throw .malformed(raw)
            }
        }
        guard number.isEmpty, sawUnit else { throw .malformed(raw) }
        guard total > 0 else { throw .zero }
        guard total <= maximumSeconds else { throw .tooLong(maximumSeconds: maximumSeconds) }
        return .seconds(total)
    }
}

public enum RemainingFormatter {
    /// `HH:MM:SS` (hours may exceed 24).
    public static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// Compact form for the popover header: `1:42:15` or `42:15`.
    public static func compactClock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
