import Foundation

/// A fully parsed CLI invocation.
public struct CLIInvocation: Equatable, Sendable {
    public enum Command: Equatable, Sendable {
        case help
        case version
        case status
        case sober
        case activate(SleepMode, MethDuration, whilePID: Int32?)
        case extend(seconds: Int)
    }
    public var command: Command
    public var json: Bool
    public var language: CLILanguage?

    public init(command: Command, json: Bool = false, language: CLILanguage? = nil) {
        self.command = command
        self.json = json
        self.language = language
    }
}

public enum CLIParser {
    /// Parses `arguments` (excluding argv[0]).
    ///
    /// Grammar:
    ///   meth [help|--help|-h]
    ///   meth version|--version|-V
    ///   meth status [--json]
    ///   meth sober|stop [--json]
    ///   meth bump|high [--for <duration> | --until <HH:MM>] [--while-pid <pid>] [--json]
    ///   meth overdose (--for <duration> | --until <HH:MM>) [--while-pid <pid>] [--json]
    ///   meth extend <duration> [--json]
    /// Global: --json, --lang <en|th|zh>
    ///
    /// `now` and `calendar` resolve `--until`; injectable for tests.
    public static func parse(_ arguments: [String], now: Date = Date(),
                             calendar: Calendar = .current) throws(MethError) -> CLIInvocation {
        var json = false
        var language: CLILanguage?
        var durationText: String?
        var untilText: String?
        var whilePID: Int32?
        var positionals: [String] = []

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            func value(for flag: String) throws(MethError) -> String {
                i += 1
                guard i < arguments.count, !arguments[i].hasPrefix("--") else {
                    throw MethError(.usage, "Option \(flag) requires a value.")
                }
                return arguments[i]
            }
            switch arg {
            case "--json", "-j":
                json = true
            case "--for", "-f", "-t":
                guard durationText == nil else { throw MethError(.usage, "--for given more than once.") }
                durationText = try value(for: arg)
            case "--until", "-u":
                guard untilText == nil else { throw MethError(.usage, "--until given more than once.") }
                untilText = try value(for: arg)
            case "--while-pid", "-p":
                let v = try value(for: arg)
                guard let pid = Int32(v), pid > 0 else { throw MethError(.usage, "--while-pid needs a process ID, got “\(v)”.") }
                whilePID = pid
            case "--lang":
                let v = try value(for: arg)
                guard let l = CLILanguage(code: v) else { throw MethError(.usage, "Unsupported language: \(v). Use en, th or zh.") }
                language = l
            case "--help", "-h":
                positionals.append("help")
            case "--version", "-V", "-v":
                positionals.append("version")
            default:
                if arg.hasPrefix("--for=") {
                    guard durationText == nil else { throw MethError(.usage, "--for given more than once.") }
                    durationText = String(arg.dropFirst("--for=".count))
                } else if arg.hasPrefix("--lang=") {
                    let v = String(arg.dropFirst("--lang=".count))
                    guard let l = CLILanguage(code: v) else { throw MethError(.usage, "Unsupported language: \(v). Use en, th or zh.") }
                    language = l
                } else if arg.hasPrefix("-") && arg.count > 1 {
                    throw MethError(.usage, "Unknown option: \(arg)")
                } else {
                    positionals.append(arg)
                }
            }
            i += 1
        }

        guard let word = positionals.first else {
            return CLIInvocation(command: .help, json: json, language: language)
        }
        if word.lowercased() == "extend" {
            guard positionals.count == 2 else { throw MethError(.usage, "Usage: meth extend <duration>, e.g. meth extend 30m") }
            guard durationText == nil, untilText == nil, whilePID == nil else {
                throw MethError(.usage, "extend takes only a duration.")
            }
            let text = positionals[1]
            let d: MethDuration
            do {
                d = try DurationParser.parse(text, maximumSeconds: MethDuration.maximumSeconds)
            } catch {
                throw MethError(.invalidDuration, Self.describe(error, input: text))
            }
            guard let secs = d.seconds else { throw MethError(.invalidDuration, "Extension needs a finite duration.") }
            return CLIInvocation(command: .extend(seconds: secs), json: json, language: language)
        }
        guard positionals.count == 1 else {
            throw MethError(.usage, "Unexpected argument: \(positionals[1])")
        }

        func noDuration(_ name: String) throws(MethError) {
            if durationText != nil || untilText != nil { throw MethError(.usage, "\(name) does not accept --for/--until.") }
            if whilePID != nil { throw MethError(.usage, "\(name) does not accept --while-pid.") }
        }
        if durationText != nil && untilText != nil {
            throw MethError(.usage, "Use either --for or --until, not both.")
        }

        let command: CLIInvocation.Command
        switch word.lowercased() {
        case "help":
            command = .help
        case "version":
            try noDuration("version")
            command = .version
        case "status":
            try noDuration("status")
            command = .status
        default:
            guard let mode = SleepMode(cliWord: word) else {
                throw MethError(.unknownCommand, "Unknown command: \(word). Run `meth help`.")
            }
            if mode == .sober {
                try noDuration(word)
                command = .sober
            } else {
                let maxSeconds = mode == .overdose ? MethDuration.maximumOverdoseSeconds : MethDuration.maximumSeconds
                let duration: MethDuration
                if let durationText {
                    do {
                        duration = try DurationParser.parse(durationText, maximumSeconds: maxSeconds)
                    } catch {
                        throw MethError(.invalidDuration, Self.describe(error, input: durationText))
                    }
                } else if let untilText {
                    let secs = try Self.secondsUntil(untilText, now: now, calendar: calendar)
                    guard secs <= maxSeconds else {
                        throw MethError(.invalidDuration, "“\(untilText)” is more than \(MethDuration.compact(maxSeconds)) away.")
                    }
                    duration = .seconds(secs)
                } else {
                    duration = .indefinite
                }
                if mode == .overdose && duration == .indefinite {
                    throw MethError(.durationRequired, "Overdose requires an explicit duration of at most 24h, e.g. `meth overdose --for 1h`.")
                }
                command = .activate(mode, duration, whilePID: whilePID)
            }
        }
        return CLIInvocation(command: command, json: json, language: language)
    }

    /// Seconds from `now` until the next occurrence of `HH:MM` (24-hour) in `calendar`'s time zone.
    public static func secondsUntil(_ text: String, now: Date, calendar: Calendar) throws(MethError) -> Int {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m), parts[1].count == 2 else {
            throw MethError(.invalidDuration, "Invalid time “\(text)”. Use 24-hour HH:MM, e.g. 17:30.")
        }
        guard let next = calendar.nextDate(after: now, matching: DateComponents(hour: h, minute: m, second: 0),
                                           matchingPolicy: .nextTime) else {
            throw MethError(.invalidDuration, "Invalid time “\(text)”.")
        }
        return max(1, Int(next.timeIntervalSince(now).rounded(.up)))
    }

    static func describe(_ e: DurationParseError, input: String) -> String {
        switch e {
        case .empty: "Duration is empty."
        case .malformed: "Invalid duration “\(input)”. Use forms like 30m, 2h, 1h30m, 45s or inf."
        case .zero: "Duration must be greater than zero."
        case .tooLong(let max): "Duration “\(input)” exceeds the maximum of \(MethDuration.compact(max))."
        }
    }
}

// MARK: - Output

public enum CLIOutput {
    /// Stable machine-readable status document (schemaVersion 1). Keys are always
    /// present; absent values are `null`. See docs/CLI.md.
    public static func statusJSON(_ s: SessionSnapshot, cliVersion: String, warnings: [MethError] = []) -> String {
        var obj: [(String, JSONValue)] = []
        obj.append(("schemaVersion", .int(1)))
        obj.append(("app", .string("Meth")))
        obj.append(("version", .string(cliVersion)))
        obj.append(("agentVersion", .string(s.agentVersion)))
        obj.append(("mode", .string(s.mode.rawValue)))
        obj.append(("status", .string(s.mode.isActive ? "active" : "inactive")))
        obj.append(("indefinite", .bool(s.isIndefinite)))
        obj.append(("remainingSeconds", s.remainingSeconds.map { .int($0) } ?? .null))
        obj.append(("durationSeconds", s.durationSeconds.map { .int($0) } ?? .null))
        obj.append(("startedAt", s.startedAt.map { .string(ISO8601.string(from: $0)) } ?? .null))
        obj.append(("expiresAt", s.expiresAt.map { .string(ISO8601.string(from: $0)) } ?? .null))
        obj.append(("source", s.source.map { .string($0.rawValue) } ?? .null))
        obj.append(("whileProcess", s.watchedProcess.map { .object([("pid", .int(Int($0.pid))), ("name", .string($0.name))]) } ?? .null))
        obj.append(("lastEndReason", s.lastEndReason.map { .string($0.rawValue) } ?? .null))
        obj.append(("allowOverdoseFromCLI", .bool(s.preferences.allowOverdoseFromCLI)))
        obj.append(("endBelowBatteryPercent", s.preferences.endBelowBatteryPercent.map { .int($0) } ?? .null))
        obj.append(("endOnBatteryPower", .bool(s.preferences.endOnBatteryPower)))
        obj.append(("warnings", .array(warnings.map(errorObject))))
        return JSONValue.object(obj).render()
    }

    public static func errorJSON(_ e: MethError) -> String {
        JSONValue.object([
            ("schemaVersion", .int(1)),
            ("app", .string("Meth")),
            ("error", errorObject(e)),
        ]).render()
    }

    public static func versionJSON(cliVersion: String, build: String) -> String {
        JSONValue.object([
            ("schemaVersion", .int(1)),
            ("app", .string("Meth")),
            ("version", .string(cliVersion)),
            ("build", .string(build)),
        ]).render()
    }

    static func errorObject(_ e: MethError) -> JSONValue {
        .object([("code", .string(e.code.rawValue)), ("message", .string(e.message))])
    }

    /// Human-readable status block.
    public static func statusText(_ s: SessionSnapshot, cliVersion: String, strings: CLIStrings) -> String {
        var lines = ["Meth v\(cliVersion)"]
        lines.append("\(strings.label(.mode)): \(s.mode.displayName)")
        lines.append("\(strings.label(.status)): \(strings.label(s.mode.isActive ? .active : .inactive))")
        if s.mode.isActive {
            if let r = s.remainingSeconds {
                lines.append("\(strings.label(.remaining)): \(RemainingFormatter.clock(r))")
            } else {
                lines.append("\(strings.label(.remaining)): \(strings.label(.indefinite))")
            }
            if let w = s.watchedProcess {
                lines.append("\(strings.label(.untilQuit)): \(w.name) (PID \(w.pid))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Tiny ordered JSON writer so the CLI output has a stable key order and explicit nulls.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (a: JSONValue, b: JSONValue) -> Bool { a.render() == b.render() }

    public func render() -> String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .string(let s): return Self.quote(s)
        case .array(let a): return "[" + a.map { $0.render() }.joined(separator: ",") + "]"
        case .object(let o): return "{" + o.map { Self.quote($0.0) + ":" + $0.1.render() }.joined(separator: ",") + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
